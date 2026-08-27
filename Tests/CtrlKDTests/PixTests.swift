import Testing
@testable import CtrlKD

/// b24 engine wave, round 19 (PIX decode) — mirrors ctrl-kd's tests/test_pix.py.
/// Synthetic-only fixtures (no corpus content ships in this repo), built with the same
/// vertical-RLE wire encoding real Inset files use, so the decoder is tested against the
/// real format, not a shortcut. Port of `build_pix_bytes`/`build_tile_bytes`/
/// `encode_plane_rows`.

// MARK: - fixture builders
//
// le16/le32 come from Fixtures.swift (shared with the style-library/font-block fixtures).

/// Vertical RLE encode: row 0 raw; later rows carry a changed-byte bitmask against the
/// previous row. Port of `encode_plane_rows`.
func encodePlaneRows(_ rows: [[UInt8]], rowBytes: Int) -> [UInt8] {
    var out: [UInt8] = []
    var prev = [UInt8](repeating: 0, count: rowBytes)
    let compBytesNeeded = (rowBytes + 7) / 8
    for (i, rawRow) in rows.enumerated() {
        var row = rawRow
        if row.count < rowBytes { row += [UInt8](repeating: 0, count: rowBytes - row.count) }
        row = Array(row.prefix(rowBytes))
        if i == 0 {
            out += row
        } else {
            var mask = [UInt8](repeating: 0, count: compBytesNeeded)
            var changed: [UInt8] = []
            for bytei in 0..<rowBytes where row[bytei] != prev[bytei] {
                mask[bytei / 8] |= (1 << (7 - (bytei % 8)))
                changed.append(row[bytei])
            }
            out += mask
            out += changed
        }
        prev = row
    }
    return out
}

/// Port of `build_tile_bytes`.
func buildTileBytes(_ indexRows: [[UInt8]], pageRows: Int, pageCols: Int,
                            gfore: Int, nRowsHere: Int) -> [UInt8] {
    let rowBytes = pageCols / 8
    var out: [UInt8] = []
    for p in 0..<gfore {
        var planeRows: [[UInt8]] = []
        for ry in 0..<nRowsHere {
            let row = indexRows[ry]
            var packed = [UInt8](repeating: 0, count: rowBytes)
            for cx in 0..<pageCols {
                let bit = (row[cx] >> p) & 1
                if bit != 0 { packed[cx >> 3] |= (1 << (7 - (cx & 7))) }
            }
            planeRows.append(packed)
        }
        out += encodePlaneRows(planeRows, rowBytes: rowBytes)
    }
    return out
}

/// Port of `build_prt_options`.
func buildPrtOptions(rowDp: Int = 0, colDp: Int = 0, pWid: Int = 0, siz: Int = 0) -> [UInt8] {
    var out: [UInt8] = []
    let fields = [100, 0, 0, 0, 0, pWid, siz, 0, 0, 0, 0, 0, rowDp, colDp, 0]
    for f in fields { out += le16(f & 0xFFFF) }
    out += Array(0..<16).map { UInt8($0) }     // ink_tab
    return out
}

/// Port of `build_pix_bytes`.
func buildPixBytes(gcols: Int, grows: Int, gfore: Int, pageRows: Int, pageCols: Int,
                           stpRows: Int, stpCols: Int, indexImg: [[UInt8]],
                           paletteRaw: [UInt8]? = nil, htype: Int = 1,
                           prtOptionsRaw: [UInt8]? = nil) -> [UInt8] {
    let palette = paletteRaw ?? [UInt8](repeating: 0, count: 4 * 16)

    var modeBlob = [UInt8](repeating: 0, count: 29)
    modeBlob[1] = UInt8(htype)
    let gc = le16(gcols), gr = le16(grows)
    modeBlob[18] = gc[0]; modeBlob[19] = gc[1]
    modeBlob[20] = gr[0]; modeBlob[21] = gr[1]
    modeBlob[22] = UInt8(gfore)

    let tileInfoBlob = le16(pageRows) + le16(pageCols) + le16(stpRows) + le16(stpCols)

    let fullW = pageCols * stpCols, fullH = pageRows * stpRows
    var padded = indexImg.map { row -> [UInt8] in
        row + [UInt8](repeating: 0, count: max(0, fullW - row.count))
    }
    while padded.count < fullH { padded.append([UInt8](repeating: 0, count: fullW)) }

    var tiles: [[UInt8]] = []
    for trow in 0..<stpRows {
        for tcol in 0..<stpCols {
            let nRowsHere = max(0, min(pageRows, grows - trow * pageRows))
            let baseY = trow * pageRows, baseX = tcol * pageCols
            let tileRows = (0..<nRowsHere).map { ry -> [UInt8] in
                Array(padded[baseY + ry][baseX..<(baseX + pageCols)])
            }
            tiles.append(buildTileBytes(tileRows, pageRows: pageRows, pageCols: pageCols,
                                        gfore: gfore, nRowsHere: nRowsHere))
        }
    }

    var items: [(did: Int, blob: [UInt8])] = [(0, modeBlob), (1, palette), (2, tileInfoBlob)]
    if let prtOptionsRaw { items.append((0x11, prtOptionsRaw)) }
    items += tiles.enumerated().map { (0x8000 + $0.offset, $0.element) }

    let header = le16(3) + le16(items.count)
    var indexEntries: [UInt8] = []
    var blobs: [UInt8] = []
    var cur = 4 + 8 * items.count
    for (did, blob) in items {
        indexEntries += le16(did) + le16(blob.count) + le32(cur)
        blobs += blob
        cur += blob.count
    }
    return header + indexEntries + blobs
}

func irgbPaletteRaw(_ codes: [Int]) -> [UInt8] {
    var raw = [UInt8](repeating: 0, count: 4 * 16)
    for (i, c) in codes.enumerated() {
        raw[i * 4] = UInt8((c >> 3) & 1)
        raw[i * 4 + 1] = UInt8((c >> 2) & 1)
        raw[i * 4 + 2] = UInt8((c >> 1) & 1)
        raw[i * 4 + 3] = UInt8(c & 1)
    }
    return raw
}

func solidRows(gcols: Int, grows: Int, value: UInt8) -> [[UInt8]] {
    Array(repeating: [UInt8](repeating: value, count: gcols), count: grows)
}

// MARK: - mono

@Test func decodeMonoInkOnWhite() throws {
    let rows: [[UInt8]] = [[1, 1, 1, 1, 0, 0, 0, 0], [0, 0, 0, 0, 1, 1, 1, 1]]
    let data = buildPixBytes(gcols: 8, grows: 2, gfore: 1, pageRows: 2, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows)
    let (w, h, rgb) = try pixDecode(data)
    #expect(w == 8 && h == 2)
    let white: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
    let black: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
    #expect(rgb[0].map { $0.r } == [black, black, black, black, white, white, white, white].map { $0.r })
    #expect(rgb[1].map { $0.r } == [white, white, white, white, black, black, black, black].map { $0.r })
}

@Test func decodeMonoMultiRowRLECopy() throws {
    let rows: [[UInt8]] = [[UInt8](repeating: 1, count: 8), [UInt8](repeating: 0, count: 8),
                           [UInt8](repeating: 0, count: 8), [UInt8](repeating: 1, count: 8)]
    let data = buildPixBytes(gcols: 8, grows: 4, gfore: 1, pageRows: 4, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows)
    let (_, _, rgb) = try pixDecode(data)
    #expect(rgb[0].allSatisfy { $0.r == 0 })
    #expect(rgb[1].allSatisfy { $0.r == 255 })
    #expect(rgb[2].allSatisfy { $0.r == 255 })
    #expect(rgb[3].allSatisfy { $0.r == 0 })
}

// MARK: - CGA

@Test func decodeCGACanonicalPalette() throws {
    let codes = [0, 2, 4, 6]     // PAL0_LOW: black, green, red, brown -- no duplicates
    let rows: [[UInt8]] = [[0, 1, 2, 3, 0, 1, 2, 3]]
    let data = buildPixBytes(gcols: 8, grows: 1, gfore: 2, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows,
                             paletteRaw: irgbPaletteRaw(codes))
    let (_, _, rgb) = try pixDecode(data)
    let expected = codes.map { canonical16[$0] }
    for (i, e) in expected.enumerated() {
        #expect(rgb[0][i].r == e.r && rgb[0][i].g == e.g && rgb[0][i].b == e.b)
    }
}

@Test func decodeCGADuplicateSlotRepair() throws {
    // TEST.PIX's real shape: 0, 11, 0, 15 -- slot 2 is a corrupt duplicate of slot 0.
    // Repair must complete it to 13 (PAL1_HIGH's missing member).
    let codes = [0, 11, 0, 15]
    let rows: [[UInt8]] = [[0, 1, 2, 3]]
    let data = buildPixBytes(gcols: 8, grows: 1, gfore: 2, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows,
                             paletteRaw: irgbPaletteRaw(codes))
    let (_, _, rgb) = try pixDecode(data)
    let expected = [0, 11, 13, 15].map { canonical16[$0] }
    for (i, e) in expected.enumerated() {
        #expect(rgb[0][i].r == e.r && rgb[0][i].g == e.g && rgb[0][i].b == e.b)
    }
}

@Test func decodeCGADegenerateFallsBackToPal0Low() throws {
    let codes = [0, 0, 1, 2]     // SPORTS.PIX's real shape: fully degenerate
    let rows: [[UInt8]] = [[0, 1, 2, 3]]
    let data = buildPixBytes(gcols: 8, grows: 1, gfore: 2, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows,
                             paletteRaw: irgbPaletteRaw(codes))
    let (_, _, rgb) = try pixDecode(data)
    let expected = [0, 2, 4, 6].map { canonical16[$0] }   // PAL0_LOW
    for (i, e) in expected.enumerated() {
        #expect(rgb[0][i].r == e.r && rgb[0][i].g == e.g && rgb[0][i].b == e.b)
    }
}

// MARK: - EGA

@Test func decodeEGAAsymmetricDAC() throws {
    // Ground-truth-confirmed formula: bit0 worth 170, bit1 worth 85 -- raw 0->0, 1->170,
    // 2->85, 3->255, NOT a uniform value*85 ramp.
    var paletteRaw = [UInt8](repeating: 0, count: 4 * 16)
    for (i, rawval) in [0, 1, 2, 3].enumerated() {
        paletteRaw[i * 4 + 1] = UInt8(rawval)    // red channel only
    }
    let rows: [[UInt8]] = [[0, 1, 2, 3]]
    let data = buildPixBytes(gcols: 8, grows: 1, gfore: 4, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows, paletteRaw: paletteRaw)
    let (_, _, rgb) = try pixDecode(data)
    let reds = rgb[0].prefix(4).map(\.r)
    #expect(reds == [0, 170, 85, 255])
    #expect(rgb[0].prefix(4).allSatisfy { $0.g == 0 && $0.b == 0 })
}

@Test func decodeEGAMultiTileGrid() throws {
    // 2x2 tile grid, EGA depth -- exercises tile-grid reassembly and a
    // grows-not-multiple-of-page_rows band.
    let gcols = 12, grows = 5
    let pageRows = 3, pageCols = 8
    let stpRows = 2, stpCols = 2
    let rows = solidRows(gcols: gcols, grows: grows, value: 3)
    var paletteRaw = [UInt8](repeating: 0, count: 4 * 16)
    paletteRaw[3 * 4 + 1] = 3; paletteRaw[3 * 4 + 2] = 3; paletteRaw[3 * 4 + 3] = 3
    let data = buildPixBytes(gcols: gcols, grows: grows, gfore: 4, pageRows: pageRows,
                             pageCols: pageCols, stpRows: stpRows, stpCols: stpCols,
                             indexImg: rows, paletteRaw: paletteRaw)
    let (w, h, rgb) = try pixDecode(data)
    #expect(w == gcols && h == grows)
    for row in rgb {
        #expect(row.allSatisfy { $0.r == 255 && $0.g == 255 && $0.b == 255 })
    }
}

// MARK: - PNG

private func be32(_ b: ArraySlice<UInt8>) -> UInt32 {
    let a = Array(b)
    return (UInt32(a[0]) << 24) | (UInt32(a[1]) << 16) | (UInt32(a[2]) << 8) | UInt32(a[3])
}

/// Every `(tag, payload)` chunk in a PNG byte stream, skipping the 8-byte signature.
private func iterPNGChunks(_ png: [UInt8]) -> [(tag: String, payload: [UInt8])] {
    var out: [(String, [UInt8])] = []
    var i = 8
    while i + 8 <= png.count {
        let len = Int(be32(png[i..<(i + 4)]))
        let tag = String(bytes: png[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
        let payloadStart = i + 8
        guard payloadStart + len + 4 <= png.count else { break }
        let payload = Array(png[payloadStart..<(payloadStart + len)])
        out.append((tag, payload))
        i = payloadStart + len + 4
    }
    return out
}

private func readIHDR(_ png: [UInt8]) -> (width: Int, height: Int, bitDepth: Int, colorType: Int)? {
    for (tag, payload) in iterPNGChunks(png) where tag == "IHDR" {
        let w = Int(be32(payload[0..<4])), h = Int(be32(payload[4..<8]))
        return (w, h, Int(payload[8]), Int(payload[9]))
    }
    return nil
}

/// Pure-Swift verifier for OUR OWN "stored blocks only" zlib format (Deflate.swift):
/// strips the 2-byte header, reassembles the stored-block payload, and checks it
/// against the trailing Adler-32 -- a real correctness check on the actual bytes,
/// not just "we wrote something", since a byte-flow bug (wrong LEN/NLEN, dropped
/// block) would fail this exactly the way a real zlib reader would reject it.
private func inflateStoredOnly(_ zlibBytes: [UInt8]) -> [UInt8]? {
    guard zlibBytes.count >= 6 else { return nil }
    var pos = 2       // skip CMF/FLG
    var out: [UInt8] = []
    while true {
        guard pos < zlibBytes.count else { return nil }
        let header = zlibBytes[pos]; pos += 1
        let bfinal = header & 0x01
        let btype = (header >> 1) & 0x03
        guard btype == 0 else { return nil }     // only stored blocks are ours to verify
        guard pos + 4 <= zlibBytes.count else { return nil }
        let len = Int(zlibBytes[pos]) | (Int(zlibBytes[pos + 1]) << 8)
        pos += 4      // LEN + NLEN
        guard pos + len <= zlibBytes.count else { return nil }
        out.append(contentsOf: zlibBytes[pos..<(pos + len)])
        pos += len
        if bfinal == 1 { break }
    }
    guard pos + 4 <= zlibBytes.count else { return nil }
    let trailerAdler = be32(zlibBytes[pos..<(pos + 4)])
    guard trailerAdler == adler32(out) else { return nil }
    return out
}

private func readRGB8Pixels(_ png: [UInt8], width: Int, height: Int) -> [[(r: UInt8, g: UInt8, b: UInt8)]]? {
    var idat: [UInt8] = []
    for (tag, payload) in iterPNGChunks(png) where tag == "IDAT" { idat += payload }
    let stride = 1 + width * 3
    // b24 round 21b: pixToPNG's own IDAT is now real (Huffman-coded) zlib output --
    // inflateStoredOnly (this file's hand-rolled reader) can only parse stored
    // blocks, so real inflate (via `c_uncompress`, Deflate.swift's own
    // `@_extern(c:)`-bound declaration) is what verifies it.
    guard let raw = realZlibInflate(idat, expectedSize: stride * height) else { return nil }
    var out: [[(r: UInt8, g: UInt8, b: UInt8)]] = []
    for y in 0..<height {
        let rowStart = y * stride + 1
        var row: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for x in 0..<width {
            let o = rowStart + x * 3
            row.append((raw[o], raw[o + 1], raw[o + 2]))
        }
        out.append(row)
    }
    return out
}

@Test func toPNGMonoIsValid1BitPNG() throws {
    let rows: [[UInt8]] = [[1, 0, 1, 0, 1, 0, 1, 0], [0, 1, 0, 1, 0, 1, 0, 1]]
    let data = buildPixBytes(gcols: 8, grows: 2, gfore: 1, pageRows: 2, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows)
    let png = try pixToPNG(data)
    #expect(png.prefix(8) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let ihdr = readIHDR(png)
    #expect(ihdr?.width == 8 && ihdr?.height == 2 && ihdr?.bitDepth == 1 && ihdr?.colorType == 0)
}

@Test func toPNGRGBRoundtripsPixelsAndInflatesCleanly() throws {
    let codes = [0, 2, 4, 6]
    let rows: [[UInt8]] = [[0, 1, 2, 3]]
    let data = buildPixBytes(gcols: 4, grows: 1, gfore: 2, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: rows,
                             paletteRaw: irgbPaletteRaw(codes))
    let png = try pixToPNG(data)
    let ihdr = readIHDR(png)
    #expect(ihdr?.width == 4 && ihdr?.height == 1 && ihdr?.bitDepth == 8 && ihdr?.colorType == 2)
    let pixels = readRGB8Pixels(png, width: 4, height: 1)
    let expected = codes.map { canonical16[$0] }
    #expect(pixels != nil)
    if let pixels {
        for (i, e) in expected.enumerated() {
            #expect(pixels[0][i].r == e.r && pixels[0][i].g == e.g && pixels[0][i].b == e.b)
        }
    }
}

// MARK: - errors

@Test func decodeTextModeRaisesSpecificError() throws {
    let data = buildPixBytes(gcols: 8, grows: 1, gfore: 1, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: [[UInt8](repeating: 0, count: 8)],
                             htype: 0)    // bit0 clear -> alphanumeric/text mode
    let error = #expect(throws: PixError.self) {
        _ = try pixDecode(data)
    }
    guard case .textModeUnsupported = error else {
        Issue.record("expected .textModeUnsupported, got \(String(describing: error))")
        return
    }
}

@Test func decodeTruncatedHeaderRaisesFormatError() throws {
    #expect(throws: PixError.self) { _ = try pixDecode([0x03, 0x00]) }
}

@Test func decodeTruncatedIndexTableRaisesFormatError() throws {
    // claims 5 items, has 0
    #expect(throws: PixError.self) { _ = try pixDecode(le16(3) + le16(5) + [0, 0, 0, 0]) }
}

@Test func decodeMissingImageInfoRaisesFormatError() throws {
    #expect(throws: PixError.self) { _ = try pixDecode(le16(3) + le16(0)) }
}

@Test func decodeZeroDimensionRaisesFormatError() throws {
    let data = buildPixBytes(gcols: 0, grows: 1, gfore: 1, pageRows: 1, pageCols: 8,
                             stpRows: 1, stpCols: 1, indexImg: [[UInt8](repeating: 0, count: 8)])
    #expect(throws: PixError.self) { _ = try pixDecode(data) }
}

// MARK: - print-options sizing

func tinyMonoPix(_ prtOptionsRaw: [UInt8]? = nil) -> [UInt8] {
    buildPixBytes(gcols: 8, grows: 1, gfore: 1, pageRows: 1, pageCols: 8, stpRows: 1,
                 stpCols: 1, indexImg: [[UInt8](repeating: 0, count: 8)],
                 prtOptionsRaw: prtOptionsRaw)
}

@Test func physicalSizeInReadsRowDpColDp() throws {
    // 720 decipoints/inch -- 4680 dp = 6.5in (width, from col_dp), 1440 dp = 2.0in
    // (height, from row_dp).
    let data = tinyMonoPix(buildPrtOptions(rowDp: 1440, colDp: 4680))
    let size = pixPhysicalSizeIn(data)
    #expect(size != nil)
    if let size {
        #expect(abs(size.widthIn - 6.5) < 0.001)
        #expect(abs(size.heightIn - 2.0) < 0.001)
    }
}

@Test func physicalSizeInNoneWhenNoPrintOptionsItem() throws {
    #expect(pixPhysicalSizeIn(tinyMonoPix()) == nil)
}

@Test func physicalSizeInNoneWhenZeroSize() throws {
    let data = tinyMonoPix(buildPrtOptions(rowDp: 0, colDp: 0))
    #expect(pixPhysicalSizeIn(data) == nil)
}

@Test func physicalSizeInNoneWhenNegative() throws {
    // row_dp/col_dp are signed shorts -- a negative reading is the reachable
    // "implausible" case, guarded by the same <=0 check as an all-zero record.
    let data = tinyMonoPix(buildPrtOptions(rowDp: 1440, colDp: -100))
    #expect(pixPhysicalSizeIn(data) == nil)
}

@Test func physicalSizeInNoneOnMalformedData() throws {
    #expect(pixPhysicalSizeIn(bytes("not a pix file")) == nil)
    #expect(pixPhysicalSizeIn([]) == nil)
}

@Test func physicalSizeInIgnoresPWidAndSiz() throws {
    // p_wid/siz are documented "not required"/"not used" -- a record that sets ONLY
    // those, with row_dp/col_dp still zero, must still read as absent-size (nil).
    let data = tinyMonoPix(buildPrtOptions(pWid: 80, siz: 42))
    #expect(pixPhysicalSizeIn(data) == nil)
}

// MARK: - Deflate/zlib self-check (Deflate.swift; PIX/PDF-image compression backing)
//
// b24 round 21b: `zlibCompress` links the REAL system zlib (byte-exact DEFLATE parity
// with Python's own `zlib.compress`); `zlibCompressStored` is the pure-Swift, no-
// dependency fallback this project shipped before that round, kept as a working,
// tested alternative. The two are tested separately below -- `inflateStoredOnly`
// (this file's own hand-rolled verifier) understands ONLY stored (BTYPE=00) blocks,
// so it is `zlibCompressStored`'s own test, not `zlibCompress`'s.

@Test func zlibCompressStoredRoundTripsViaStoredBlocks() throws {
    let payload = Array("Hello, PIX embedding world! ".utf8)
        + [UInt8](repeating: 0x42, count: 200)
    let compressed = zlibCompressStored(payload)
    #expect(compressed[0] == 0x78 && compressed[1] == 0x01)
    let recovered = inflateStoredOnly(compressed)
    #expect(recovered == payload)
}

@Test func zlibCompressStoredHandlesEmptyInput() throws {
    let compressed = zlibCompressStored([])
    let recovered = inflateStoredOnly(compressed)
    #expect(recovered == [])
}

/// Real zlib INFLATE (via `c_uncompress`, `Deflate.swift`'s own `@_extern(c:)`-bound
/// declaration for `libz`'s `uncompress` -- b24 round 21d/21e, no module/shim at
/// all), for verifying `zlibCompress`'s own (real-compression) output round-trips --
/// `inflateStoredOnly` above cannot read it (it uses genuine Huffman-coded blocks, not
/// stored ones).
private func realZlibInflate(_ compressed: [UInt8], expectedSize: Int) -> [UInt8]? {
    var destLen = UInt(max(1, expectedSize))     // a real, non-null buffer even for 0
    var dest = [UInt8](repeating: 0, count: Int(destLen))
    let compressedOrPlaceholder = compressed.isEmpty ? [0] : compressed
    let result = dest.withUnsafeMutableBufferPointer { destBuf -> Int32 in
        compressedOrPlaceholder.withUnsafeBufferPointer { srcBuf -> Int32 in
            c_uncompress(destBuf.baseAddress!, &destLen, srcBuf.baseAddress!, UInt(compressed.count))
        }
    }
    guard result == 0, Int(destLen) == expectedSize else { return nil }
    return Array(dest[0..<expectedSize])
}

@Test func zlibCompressRoundTripsViaRealInflate() throws {
    let payload = Array("Hello, PIX embedding world! ".utf8)
        + [UInt8](repeating: 0x42, count: 200)
    let compressed = zlibCompress(payload, level: 6)
    #expect(compressed[0] == 0x78)   // a real zlib header's CMF byte (CM=8, CINFO<=7)
    let recovered = realZlibInflate(compressed, expectedSize: payload.count)
    #expect(recovered == payload)
}

@Test func zlibCompressHandlesEmptyInput() throws {
    let compressed = zlibCompress([], level: 6)
    let recovered = realZlibInflate(compressed, expectedSize: 0)
    #expect(recovered == [])
}

@Test func zlibCompressMatchesPythonZlibByteExactly() throws {
    // The actual parity proof (b24 round 21b): Python's `zlib.compress(payload, N)`
    // for this exact payload, computed once via the installed Python `zlib` module
    // (same underlying libz on this machine) and pinned here as hex. A byte-exact
    // match proves `zlibCompress` reproduces ctrl-kd's own compressed OUTPUT, not
    // merely a valid decode of it.
    let payload = Array("Hello, PIX embedding world! ".utf8)
        + [UInt8](repeating: 0x42, count: 200)
    let expectedLevel6Hex =
        "789cf348cdc9c9d75108f08c5048cd4d4a4d49c9cc4b5728cf2fca495154701a26000030993d0a"
    let expectedLevel9Hex =
        "78daf348cdc9c9d75108f08c5048cd4d4a4d49c9cc4b5728cf2fca495154701a26000030993d0a"
    #expect(zlibCompress(payload, level: 6) == bytesFromHexString(expectedLevel6Hex))
    #expect(zlibCompress(payload, level: 9) == bytesFromHexString(expectedLevel9Hex))
}

private func bytesFromHexString(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    let chars = Array(hex)
    var i = 0
    while i + 1 < chars.count {
        let hi = UInt8(String(chars[i]), radix: 16) ?? 0
        let lo = UInt8(String(chars[i + 1]), radix: 16) ?? 0
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

// MARK: - Base64 (Base64.swift; HTML `--pictures embed` data URI backing)

@Test func base64EncodeMatchesKnownVectors() throws {
    #expect(base64Encode(bytes("")) == "")
    #expect(base64Encode(bytes("f")) == "Zg==")
    #expect(base64Encode(bytes("fo")) == "Zm8=")
    #expect(base64Encode(bytes("foo")) == "Zm9v")
    #expect(base64Encode(bytes("foob")) == "Zm9vYg==")
    #expect(base64Encode(bytes("fooba")) == "Zm9vYmE=")
    #expect(base64Encode(bytes("foobar")) == "Zm9vYmFy")
    #expect(base64Encode(bytes("Hello, World!")) == "SGVsbG8sIFdvcmxkIQ==")
}

@Test func zlibCompressStoredSplitsAcrossMultipleStoredBlocks() throws {
    // Larger than one stored block's 65535-byte cap -- exercises the multi-block path.
    let payload = [UInt8](repeating: 0x7A, count: 70_000)
    let compressed = zlibCompressStored(payload)
    let recovered = inflateStoredOnly(compressed)
    #expect(recovered == payload)
}

@Test func zlibCompressLargePayloadRoundTripsViaRealInflate() throws {
    // Exercises real zlib's own multi-block/window behavior on a payload well past
    // the 32K window this format uses.
    let payload = (0..<70_000).map { UInt8(($0 * 37) & 0xFF) }
    let compressed = zlibCompress(payload, level: 6)
    let recovered = realZlibInflate(compressed, expectedSize: payload.count)
    #expect(recovered == payload)
}
