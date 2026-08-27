/// Decode Inset Systems .PIX files (WordStar 5.0+'s bundled "Inset" graphics program) to
/// RGB pixels / PNG. Direct port of `pix.py`.
///
/// STATUS: reverse-engineered from a secondary source (the EGFF / fileformat.info
/// write-up of the Inset PIX format) and validated empirically against real
/// WordStar-7-archive sample files, then against Inset's own on-screen rendering under
/// dosbox-x ground truth. Jon's ruling after that validation (2026-08-17): "our PIX
/// conversion is excellent." See `pix.py`'s own module docstring (ctrl-kd) for the full
/// validation account (byte-exact vertical-RLE consumption, the CGA-family palette
/// repair, the asymmetric EGA DAC formula) — reproduced in the relevant functions below
/// rather than restated wholesale here.
///
/// KNOWN GOOD / NOT FULLY VALIDATED: identical to the Python module's own accounting —
/// text-mode (alphanumeric) PIX files are detected but not decoded (no local sample);
/// multi-vertical-tile-strip images were exercised by inspection, not an independent
/// tool; plane-to-color-index bit order is a reasonable, ground-truth-consistent guess.

/// A malformed .PIX file, or a structurally valid one this decoder does not support (a
/// shape with no local validated sample).
public enum PixError: Error, Sendable {
    case formatError(String)
    case textModeUnsupported(String)
}

/// `(DataID, DataLength, DataLocation)` index-table entries, keyed by DataID.
private struct PixItem {
    let length: Int
    let location: Int
}

private func parseIndexTable(_ data: [UInt8]) throws -> (revision: Int, items: [Int: PixItem]) {
    guard data.count >= 4 else { throw PixError.formatError("file too short for PIX header") }
    let rev = Int(data[0]) | (Int(data[1]) << 8)
    let nitems = Int(data[2]) | (Int(data[3]) << 8)
    var items: [Int: PixItem] = [:]
    var off = 4
    for _ in 0..<nitems {
        guard off + 8 <= data.count else { throw PixError.formatError("index table truncated") }
        let did = Int(data[off]) | (Int(data[off + 1]) << 8)
        let dlen = Int(data[off + 2]) | (Int(data[off + 3]) << 8)
        let dloc = Int(data[off + 4]) | (Int(data[off + 5]) << 8)
            | (Int(data[off + 6]) << 16) | (Int(data[off + 7]) << 24)
        items[did] = PixItem(length: dlen, location: dloc)
        off += 8
    }
    return (rev, items)
}

/// A slice of `data` at `[loc, loc+len)`, clamped to `data`'s own bounds (mirrors
/// Python's `bytes` slicing, which silently truncates rather than raising).
private func pixSlice(_ data: [UInt8], _ item: PixItem) -> [UInt8] {
    guard item.location >= 0, item.location < data.count else { return [] }
    let end = Swift.min(item.location + item.length, data.count)
    guard end > item.location else { return [] }
    return Array(data[item.location..<end])
}

private struct ModeData {
    let isBitmap: Bool
    let gcols: Int
    let grows: Int
    let gfore: Int
}

private func parseModeData(_ data: [UInt8], _ items: [Int: PixItem]) throws -> ModeData {
    guard let item = items[0] else { throw PixError.formatError("no image-info (DataID 0) data item") }
    let md = pixSlice(data, item)
    guard md.count >= 29 else { throw PixError.formatError("image-info data item too short") }
    let htype = md[1]
    let gcols = Int(md[18]) | (Int(md[19]) << 8)
    let grows = Int(md[20]) | (Int(md[21]) << 8)
    let gfore = Int(md[22])
    return ModeData(isBitmap: (htype & 1) != 0, gcols: gcols, grows: grows, gfore: gfore)
}

private func parseTileData(_ data: [UInt8], _ items: [Int: PixItem])
    throws -> (pageRows: Int, pageCols: Int, stpRows: Int, stpCols: Int) {
    guard let item = items[2] else { throw PixError.formatError("no tile-info (DataID 2) data item") }
    let td = pixSlice(data, item)
    guard td.count >= 8 else { throw PixError.formatError("tile-info data item too short") }
    func word(_ off: Int) -> Int { Int(td[off]) | (Int(td[off + 1]) << 8) }
    return (word(0), word(2), word(4), word(6))
}

private func parsePalette(_ data: [UInt8], _ items: [Int: PixItem]) -> [UInt8] {
    guard let item = items[1] else { return [UInt8](repeating: 0, count: 4 * 16) }
    return pixSlice(data, item)
}

/// DataID 0x11 print-options record: 15 signed 16-bit fields (little-endian) followed by
/// a 16-byte ink table. Struct per the EGFF (fileformat.info) secondary source, VALIDATED
/// against the one real sample this integration targets (WORDSTAR.PIX, referenced by all
/// 5 real corpus documents): its own ecol/erow exactly match gcols-1/grows-1 from the
/// image-info record, and its row_dp/col_dp (decipoints, 1/720in) work out to 1.027in x
/// 6.498in — matching the pixel count at 300dpi (1.027in x 6.497in) to within a rounding
/// hair. Per fileformat.info's own field descriptions, `p_wid`/`siz` are documented "not
/// required"/"not used" despite their names; `row_dp`/`col_dp` ("Height/Width of image in
/// decipoints") are the real size carriers, confirmed above.
private let decipointsPerInch = 720.0

private func parsePrintOptionsSize(_ data: [UInt8], _ items: [Int: PixItem]) -> (rowDp: Int, colDp: Int)? {
    guard let item = items[0x11] else { return nil }
    let blob = pixSlice(data, item)
    guard blob.count >= 30 else { return nil }
    // Fields, in order: pitch, scol, ecol, srow, erow, p_wid, siz, rotat, do_sw, res_1,
    // res_2, pcolor, row_dp, col_dp, flags -- only indices 12/13 (row_dp/col_dp) are
    // read; the rest exist only to document the struct's own field layout precisely.
    func signed16(_ index: Int) -> Int {
        let off = index * 2
        let raw = Int(blob[off]) | (Int(blob[off + 1]) << 8)
        return raw >= 0x8000 ? raw - 0x10000 : raw
    }
    return (rowDp: signed16(12), colDp: signed16(13))
}

/// `(widthIn, heightIn)` from the print-options record's row_dp/col_dp, or `nil` when
/// the record is absent, too short, or its size fields are zero or implausible (<=0 or
/// >100in — guards a garbage/misaligned read on a struct validated against only one real
/// sample). Callers fall back to fit-to-text-measure sizing when this returns `nil`.
/// Port of `physical_size_in`.
public func pixPhysicalSizeIn(_ data: [UInt8]) -> (widthIn: Double, heightIn: Double)? {
    guard let (_, items) = try? parseIndexTable(data),
          let size = parsePrintOptionsSize(data, items) else { return nil }
    let w = Double(size.colDp) / decipointsPerInch
    let h = Double(size.rowDp) / decipointsPerInch
    guard w > 0, h > 0, w <= 100, h <= 100 else { return nil }
    return (w, h)
}

/// Decode one bitplane's vertically-RLE-compressed rows starting at byte offset `pos` in
/// `buf`. Returns `(rows, newPos)`. Rows are `[UInt8]` of length `rowBytes`; bit 7 of
/// byte 0 is the leftmost pixel.
///
/// `nRows` MUST be the true number of encoded rows for THIS plane in THIS tile (see
/// `decodePix` for why that is not always `pageRows`). `padTo` pads the returned row
/// list with blank rows up to that count, for tiles whose nominal `pageRows` is taller
/// than the real content.
private func decodePlane(_ buf: [UInt8], pos: Int, nRows: Int, rowBytes: Int, padTo: Int)
    -> (rows: [[UInt8]], newPos: Int) {
    var rows: [[UInt8]] = []
    var prev = [UInt8](repeating: 0, count: rowBytes)
    let compBytesNeeded = (rowBytes + 7) / 8
    var pos = pos
    for _ in 0..<nRows {
        let firstRow = rows.isEmpty
        if pos + (firstRow ? rowBytes : compBytesNeeded) > buf.count { break }
        var row: [UInt8]
        if firstRow {
            row = Array(buf[pos..<(pos + rowBytes)])
            pos += rowBytes
        } else {
            let mask = Array(buf[pos..<(pos + compBytesNeeded)])
            pos += compBytesNeeded
            row = prev
            var ok = true
            for bytei in 0..<rowBytes {
                if mask[bytei / 8] & (1 << (7 - (bytei % 8))) != 0 {
                    if pos >= buf.count { ok = false; break }
                    row[bytei] = buf[pos]
                    pos += 1
                }
            }
            if !ok { break }
        }
        rows.append(row)
        prev = row
    }
    while rows.count < padTo {
        rows.append([UInt8](repeating: 0, count: rowBytes))
    }
    return (rows, pos)
}

private struct DecodedPix {
    let gcols: Int
    let grows: Int
    /// Row-major palette-INDEX bitmap; `decode()`/`pixToPNG()` turn this into true RGB.
    let indexImg: [[UInt8]]
    let rgbPalette: [(r: UInt8, g: UInt8, b: UInt8)]
    let gfore: Int
}

private func decodePixInternal(_ data: [UInt8]) throws -> DecodedPix {
    let (_, items) = try parseIndexTable(data)
    let info = try parseModeData(data, items)
    guard info.isBitmap else {
        throw PixError.textModeUnsupported(
            "this .PIX is a text-mode (alphanumeric) capture; decoding that variant is "
                + "not implemented (no local sample to validate against)")
    }
    let gcols = info.gcols, grows = info.grows, gfore = info.gfore
    guard gcols != 0, grows != 0 else { throw PixError.formatError("zero-sized image (gcols/grows == 0)") }
    guard gfore != 0 else { throw PixError.formatError("zero bitplanes (gfore == 0)") }

    let (pageRows, pageCols, stpRows, stpCols) = try parseTileData(data, items)
    guard pageRows != 0, pageCols != 0, stpRows != 0, stpCols != 0 else {
        throw PixError.formatError("degenerate tile geometry (zero rows/cols/tiles)")
    }
    let rowBytes = pageCols / 8
    guard rowBytes != 0 else { throw PixError.formatError("page_cols < 8, can't compute row byte width") }

    let fullW = pageCols * stpCols
    let fullH = pageRows * stpRows
    var indexImg = [[UInt8]](repeating: [UInt8](repeating: 0, count: fullW), count: fullH)

    for trow in 0..<stpRows {
        for tcol in 0..<stpCols {
            let tidx = trow * stpCols + tcol
            let did = 0x8000 + tidx
            guard let tileItem = items[did] else {
                throw PixError.formatError(
                    "missing tile data item \(tidx) (0x\(String(did, radix: 16)))")
            }
            let buf = pixSlice(data, tileItem)
            var pos = 0
            var planes: [[[UInt8]]] = []
            // THE TILE-ROW-BAND FIX: the bottom row-band, when grows isn't a multiple of
            // page_rows, only has REAL encoded data for the rows that truly exist
            // (nRowsHere) -- asking the plane decoder for more corrupts every subsequent
            // plane in the tile. See pix.py's own account for the full story.
            let nRowsHere = Swift.min(pageRows, grows - trow * pageRows)
            for _ in 0..<gfore {
                let (rows, newPos) = decodePlane(buf, pos: pos, nRows: nRowsHere,
                                                 rowBytes: rowBytes, padTo: pageRows)
                planes.append(rows)
                pos = newPos
            }

            let baseY = trow * pageRows
            let baseX = tcol * pageCols
            for ry in 0..<pageRows {
                var outRow = indexImg[baseY + ry]
                for cx in 0..<pageCols {
                    let byteI = cx >> 3
                    let bitI = 7 - (cx & 7)
                    var val: UInt8 = 0
                    for p in 0..<gfore {
                        let bit = (planes[p][ry][byteI] >> bitI) & 1
                        val |= (bit << p)
                    }
                    outRow[baseX + cx] = val
                }
                indexImg[baseY + ry] = outRow
            }
        }
    }

    // crop to true (unpadded) dimensions
    indexImg = indexImg[0..<grows].map { Array($0[0..<gcols]) }

    let palRaw = parsePalette(data, items)
    let numUsed = Swift.min(16, 1 << gfore)
    let rgbPalette = buildRGBPalette(palRaw, numUsed: numUsed)

    return DecodedPix(gcols: gcols, grows: grows, indexImg: indexImg,
                      rgbPalette: rgbPalette, gfore: gfore)
}

/// Canonical IBM CGA/EGA/VGA default 16-color hardware palette — public, well-documented
/// hardware fact (not Inset-specific). Index is the classic 4-bit IRGB code (bit3 =
/// intensity, bit2 = red, bit1 = green, bit0 = blue). Note the color-6 "brown" special
/// case (170,85,0) instead of the "expected" (170,170,0) — a genuine CGA hardware quirk.
let canonical16: [(r: UInt8, g: UInt8, b: UInt8)] = [
    (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
    (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
    (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
    (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255),
]

/// The four standard CGA hardware palettes, as their IRGB codes (indices into
/// `canonical16`) in ASCENDING order — which is also the order real Inset files present
/// them in slot 0..3.
private let pal0Low = [0, 2, 4, 6]        // black, green, red, brown
private let pal0High = [0, 10, 12, 14]    // black, light green, light red, yellow
private let pal1Low = [0, 3, 5, 7]        // black, cyan, magenta, light gray
private let pal1High = [0, 11, 13, 15]    // black, light cyan, light magenta, white
private let cgaFamilies = [pal0Low, pal0High, pal1Low, pal1High]

/// Turn the raw {intensity,red,green,blue} palette bytes into RGB. Two regimes,
/// distinguished by how many distinct entries this image's own bitplane count actually
/// indexes into (`numUsed`). Both regimes and the CGA-family repair rule are ground-
/// truth-validated against real Inset (WordStar 7) renders under dosbox-x — see pix.py's
/// own extensive docstring for the full account (this port reproduces the RULE, not the
/// narrative evidence, which is Python-side documentation this module cites rather than
/// duplicates in full).
private func buildRGBPalette(_ palRaw: [UInt8], numUsed: Int) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let useBitMode = numUsed <= 4
    var entries: [(inten: Int, r: Int, g: Int, b: Int)] = []
    for i in 0..<16 {
        let off = i * 4
        if off + 4 <= palRaw.count {
            entries.append((Int(palRaw[off]), Int(palRaw[off + 1]), Int(palRaw[off + 2]), Int(palRaw[off + 3])))
        } else {
            entries.append((0, 0, 0, 0))
        }
    }

    if useBitMode {
        var codes: [Int] = []
        for i in 0..<numUsed {
            let e = entries[i]
            let idx = ((e.inten & 1) << 3) | ((e.r & 1) << 2) | ((e.g & 1) << 1) | (e.b & 1)
            codes.append(idx)
        }
        if Set(codes).count < codes.count {
            let distinct = Set(codes)
            let matches = cgaFamilies.filter { fam in distinct.isSubset(of: Set(fam)) }
            let family = matches.count == 1 ? matches[0] : pal0Low
            codes = Array(family.prefix(numUsed))
        }
        var palette = codes.map { canonical16[$0] }
        while palette.count < 16 { palette.append(canonical16[0]) }
        return palette
    }

    return entries.map { e in
        func chan(_ v: Int) -> UInt8 {
            UInt8(Swift.min(255, 170 * (v & 1) + 85 * ((v >> 1) & 1)))
        }
        return (chan(e.r), chan(e.g), chan(e.b))
    }
}

/// Decode a .PIX file's bytes to `(width, height, rgbRows)`. `rgbRows` is `height` rows,
/// each `width` `(r, g, b)` triples — always true RGB regardless of source bit depth.
/// Monochrome (gfore == 1) images render as plain black-ink-on-white (index 0 =
/// background/white, index 1 = ink/black) — ground-truth confirmed, bypasses the palette
/// machinery entirely (unvalidated/unneeded for the 1-bitplane case). Port of `decode`.
public func pixDecode(_ data: [UInt8]) throws -> (width: Int, height: Int, rgbRows: [[(r: UInt8, g: UInt8, b: UInt8)]]) {
    let d = try decodePixInternal(data)
    let rows: [[(r: UInt8, g: UInt8, b: UInt8)]]
    if d.gfore == 1 {
        let monoRGB: [(r: UInt8, g: UInt8, b: UInt8)] = [(255, 255, 255), (0, 0, 0)]
        rows = d.indexImg.map { row in row.map { monoRGB[Int($0)] } }
    } else {
        rows = d.indexImg.map { row in row.map { d.rgbPalette[Int($0)] } }
    }
    return (d.gcols, d.grows, rows)
}

// ---- minimal PNG writer (Deflate.swift's zlibCompress -- real libz, b24 round 21b) ----

private func pngChunk(_ tag: [UInt8], _ payload: [UInt8]) -> [UInt8] {
    let content = tag + payload
    let crc = crc32(content)
    var out: [UInt8] = []
    out.append(contentsOf: be32(UInt32(payload.count)))
    out.append(contentsOf: content)
    out.append(contentsOf: be32(crc))
    return out
}

private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

/// CRC-32 (ISO 3309 / PNG's own checksum), the standard reflected polynomial 0xEDB88320
/// table-driven implementation. Independent of `Adler32` (Deflate.swift's own checksum,
/// zlib's rather than PNG's) — PNG chunks need this one specifically.
private let crc32Table: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }
}()

private func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for byte in data {
        c = crc32Table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
    }
    return c ^ 0xFFFFFFFF
}

private func pngBytes(ihdr: [UInt8], idat: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    out.append(contentsOf: pngChunk(Array("IHDR".utf8), ihdr))
    out.append(contentsOf: pngChunk(Array("IDAT".utf8), idat))
    out.append(contentsOf: pngChunk(Array("IEND".utf8), []))
    return out
}

/// 1-bit grayscale PNG. `indexImg` rows: a truthy (non-zero) value means "ink"/
/// foreground; PNG sample 0 renders black, so bits are inverted on the way out.
private func writePNGGrayscale1(width: Int, height: Int, indexImg: [[UInt8]]) -> [UInt8] {
    let rowBytesNeeded = (width + 7) / 8
    var raw: [UInt8] = []
    raw.reserveCapacity((rowBytesNeeded + 1) * height)
    for row in indexImg.prefix(height) {
        var packed = [UInt8](repeating: 0, count: rowBytesNeeded)
        for (x, v) in row.enumerated() where v != 0 {
            packed[x >> 3] |= (1 << (7 - (x & 7)))
        }
        raw.append(0)                                  // filter: none
        raw.append(contentsOf: packed.map { ~$0 })
    }
    // level 9: matches Python's own `zlib.compress(bytes(raw), 9)` in pix.py's
    // to_png -- b24 round 21b, byte-exact DEFLATE parity.
    let compressed = zlibCompress(raw, level: 9)
    let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [1, 0, 0, 0, 0]
    return pngBytes(ihdr: ihdr, idat: compressed)
}

private func writePNGRGB8(width: Int, height: Int, indexImg: [[UInt8]],
                          palette: [(r: UInt8, g: UInt8, b: UInt8)]) -> [UInt8] {
    var raw: [UInt8] = []
    raw.reserveCapacity((width * 3 + 1) * height)
    for y in 0..<height {
        raw.append(0)                                  // filter: none
        let row = indexImg[y]
        for x in 0..<width {
            let c = palette[Int(row[x])]
            raw.append(c.r); raw.append(c.g); raw.append(c.b)
        }
    }
    // level 9: matches Python's own `zlib.compress(bytes(raw), 9)`.
    let compressed = zlibCompress(raw, level: 9)
    let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [8, 2, 0, 0, 0]
    return pngBytes(ihdr: ihdr, idat: compressed)
}

/// Decode a .PIX file's bytes to PNG-encoded bytes. Monochrome (gfore == 1) images are
/// written as 1-bit grayscale (smaller, matches `pixDecode`'s own black-ink-on-white
/// treatment); everything else as 8-bit RGB. Port of `to_png`.
public func pixToPNG(_ data: [UInt8]) throws -> [UInt8] {
    let d = try decodePixInternal(data)
    if d.gfore == 1 {
        return writePNGGrayscale1(width: d.gcols, height: d.grows, indexImg: d.indexImg)
    }
    return writePNGRGB8(width: d.gcols, height: d.grows, indexImg: d.indexImg, palette: d.rgbPalette)
}
