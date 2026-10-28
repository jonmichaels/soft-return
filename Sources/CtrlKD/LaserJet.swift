// LaserJet.swift
//
// WS7's LASERJET driver: which of its fonts a document's font prints in, and where it puts
// each word of a proportional one. Port of ctrl-kd's `laserjet.py`; the tables are
// `LaserJetTables.swift`.
//
// WS7 places every word itself (an `&a#H` move before each one; a space is never sent) at the
// running sum of the driver's own character widths, in whole printer dots, and splits a word
// where a kerning pair tucks its letters together (WS7 teardown,
// `wordstar-dos/11-print-engine.md` 11.17, rules M1, W1, W2, K1, S1, P1):
//
// - M1: a font record (width, height, typestyle) prints in the driver font `match` picks: an
//   exact match first, then the closest by a fixed order of tests.
// - W1: a character is `width x size x unit x num / (em x den)` dots, rounded half up, each on
//   its own (a TrueType face rounds pixels per em first); the size is in twips, floored to a
//   quarter point.
// - K1: a kerning pair moves the pen `amount / 128` of the size in dots at 72 to the inch,
//   truncated toward zero.
// - S1: a sub/superscript is set at the block's own script scale.
// - P1: a piece is moved to `floor(x x 720 / unit)` decipoints.
//
// Two drivers run by these rules: LASERJET, and Robert J. Sawyer's LJ6DTP (WS7 teardown,
// `wordstar-dos/17-lj6dtp.md`), whose tables are `LJ6DTPTables.swift`. Every function takes
// the `driver` whose tables it reads, LASERJET by default.
//
// Every division here is Python's `//` (rounded toward minus infinity), and the arithmetic is
// the Python twin's, term for term.

enum LaserJet {
    typealias Block = LaserJetTables.Block

    /// One printed piece: its text, its x from the start of the text and its advance, in dots.
    typealias Piece = (text: String, x: Int, width: Int)

    /// The driver whose tables a document's fonts are matched against. Port of `DRIVERS`.
    enum Driver: Hashable, Sendable {
        case laserjet, lj6dtp

        var fonts: [LaserJetTables.Font] {
            switch self {
            case .laserjet: return LaserJetTables.fonts
            case .lj6dtp: return LJ6DTPTables.fonts
            }
        }

        var blocks: [String: Block] {
            switch self {
            case .laserjet: return LaserJetTables.blocks
            case .lj6dtp: return LJ6DTPTables.blocks
            }
        }
    }

    /// Python's `//`.
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func rhu(_ n: Int, _ d: Int) -> Int {
        floorDiv(n + floorDiv(d, 2), d)
    }

    /// M1: the index in the driver's `fonts` of the font a document's font record (width `w`
    /// in 1/1800 inch, height `h` in twips, typestyle word `k`) prints in. An exact match of
    /// all three first, with the request's 0200h bit forced to each font's; then each font
    /// against the best so far, the first test that tells them apart deciding, a later font
    /// winning a complete tie.
    static func match(_ w: Int, _ h: Int, _ k: Int, driver: Driver = .laserjet) -> Int? {
        let fonts = driver.fonts
        var req = [w, h, k]
        for (i, f) in fonts.enumerated() {
            req[2] ^= (f.key ^ req[2]) & 0x200
            if req[0] == f.width && req[1] == f.height && req[2] == f.key { return i }
        }
        var best = (w: 0xFFFF, h: 0xFFFF, k: 0xFFFF)
        var pick: Int? = nil
        for (i, f) in fonts.enumerated() {
            var fw = f.width
            var fh = f.height
            if fh == 0 {
                fh = req[1]
                fw = floorDiv(fw * req[1] * 8, 65536)
            }
            let dw = abs(req[0] - fw)
            let dh = abs(req[1] - fh)
            var dk = req[2] ^ f.key
            if (dk & 0x3000) == 0x3000 {
                dk &= 0xEFFF
            } else if (dk & 0x3000) == 0x1000 && (req[2] & 0x3000) == 0x3000 {
                dk ^= 0x3000
            }
            let (bw, bh, bk) = best
            let take: Bool
            let bkdk = bk ^ dk
            if (bk & 0x3000) != 0x3000 && (bkdk & 0x3000) != 0 && (bkdk & 0x3000) != 0x1000 {
                take = dk <= 0x1000
            } else if (bw > 25 || dw > 25) && bw != dw {
                take = bw > dw
            } else if bkdk & 0x8000 != 0 {
                take = dk & 0x8000 == 0
            } else if bkdk & 0x4000 != 0 {
                take = dk & 0x4000 == 0
            } else if bkdk & 0x0C00 != 0 {
                take = dk & 0x0C00 == 0
            } else if (bh > 30 || dh > 30) && bh != dh {
                take = bh > dh
            } else if (bw > 15 || dw > 15) && bw != dw {
                take = bw > dw
            } else if bkdk & 0x3000 != 0 {
                take = dk & 0x3000 == 0
            } else if bkdk & 0xFF != 0 {
                take = dk & 0xFF == 0
            } else if bw != dw {
                take = bw > dw
            } else {
                take = bh >= dh
            }
            if take {
                best = (dw, dh, dk)
                pick = i
            }
        }
        return pick
    }

    /// The driver's font entry a document font record prints in.
    static func font(for entry: FontChange, driver: Driver = .laserjet) -> LaserJetTables.Font? {
        match(entry.width1800, entry.height1440, entry.typestyle, driver: driver)
            .map { driver.fonts[$0] }
    }

    /// The proportional driver block a document font entry prints with in this variant, or nil
    /// when the driver prints it in a fixed-pitch font.
    static func block(for entry: FontChange, bold: Bool, italic: Bool,
                      driver: Driver = .laserjet) -> Block? {
        guard let font = font(for: entry, driver: driver) else { return nil }
        return driver.blocks[font.blocks[(bold ? 2 : 0) + (italic ? 1 : 0)]]
    }

    /// The pitch, in 1/1800 inch, of the fixed-pitch font the driver prints this entry in, or
    /// nil when it prints it in a proportional one. A scalable fixed font's cell is
    /// `width / 8192` em at the record's height floored to a quarter point, rounded to whole
    /// dots (WS7 teardown 11.17, W1); a bitmap's is its own width field. Port of
    /// `fixed_pitch_1800`.
    static func fixedPitch1800(_ entry: FontChange, driver: Driver = .laserjet) -> Int? {
        guard let font = font(for: entry, driver: driver), font.key & 0x8000 == 0,
              driver.blocks[font.blocks[0]] == nil else { return nil }
        if font.height != 0 { return font.width }
        let tw = entry.height1440 - entry.height1440 % 5
        return rhu(tw * font.width * 300, 1800 * 8192) * 6
    }

    /// Whether the driver prints this entry in a bitmap font (a height of its own, like
    /// LJ6DTP's COURIER PC 10 and 12): no scaled sub/superscript size, so a script keeps the
    /// line's size (teardown 17.8).
    static func isBitmap(_ entry: FontChange, driver: Driver = .laserjet) -> Bool {
        guard let font = font(for: entry, driver: driver) else { return false }
        return font.height != 0
    }

    /// The size the driver measures at, in twips: S1's script scale for a sub/superscript,
    /// floored to a quarter point. `pt` is the span's declared size.
    static func twips(_ block: Block, _ pt: Double, script: Bool = false) -> Int {
        var tw = roundHalfToEven(pt * 20)
        if script && block.script != 0 {
            tw = floorDiv(tw * block.script, 256)
        }
        return tw - ((tw % 5) + 5) % 5
    }

    /// The IBM PC glyphs at the control codes (01h-1Fh, 7Fh), which `encodeCP437` maps to the
    /// control characters instead.
    private static let graphicCodes: [Unicode.Scalar: Int] = {
        var out: [Unicode.Scalar: Int] = [:]
        for (code, glyph) in cp437Graphics where code != 0 {
            out[glyph.unicodeScalars.first!] = Int(code)
        }
        return out
    }()

    /// The printer character code (PC-8) of `ch`; 0, the table's default width, for a character
    /// it has none for. The euro is the document's 9E, which the patched drivers print as the
    /// euro (`euro-swap`).
    static func code(_ ch: Unicode.Scalar) -> Int {
        if ch == "€" { return 0x9E }
        if let graphic = graphicCodes[ch] { return graphic }
        return encodeCP437(ch).map(Int.init) ?? 0
    }

    static func charDots(_ block: Block, _ tw: Int, _ code: Int) -> Int {
        let w = block.widths[code]
        if block.ppemFirst {
            return rhu(w * rhu(block.num * tw * block.unit, 20 * block.den), block.em)
        }
        return rhu(w * block.num * tw * block.unit, 20 * block.em * block.den)
    }

    static func kernDots(_ block: Block, _ tw: Int, _ first: Int, _ second: Int) -> Int {
        let k = block.kern[first]?[second] ?? 0
        if k == 0 { return 0 }
        let d = floorDiv(abs(k) * floorDiv(tw * block.unit, 1440), 128)
        return k < 0 ? -d : d
    }

    static func dotsToPt(_ block: Block, _ dots: Int) -> Double {
        Double(dots) * 72.0 / Double(block.unit)
    }

    /// `text` as the driver prints it: `[(piece, xDots, widthDots)]`, x from the start of
    /// `text`. A run of blanks is one piece; a word is split where a kerning pair applies
    /// (with `kerning`, the `.KR` state), so each piece starts where WS7 moved to.
    static func pieces(_ text: String, _ block: Block, _ tw: Int, kerning: Bool = true) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        func slice(_ a: Int, _ b: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[a..<b])
            return String(s)
        }
        var out: [Piece] = []
        var x = 0
        var start = 0
        var pieceX = 0
        var prev: Int? = nil
        for (i, ch) in scalars.enumerated() {
            let c = code(ch)
            if ch == " " {
                if i > start && prev != nil {
                    out.append((slice(start, i), pieceX, x - pieceX))
                    start = i
                    pieceX = x
                }
                prev = nil
            } else {
                let k = (kerning && prev != nil) ? kernDots(block, tw, prev!, c) : 0
                if i > start && (prev == nil || k != 0) {
                    out.append((slice(start, i), pieceX, x - pieceX))
                    x += k
                    start = i
                    pieceX = x
                }
                prev = c
            }
            x += charDots(block, tw, c)
        }
        if start < scalars.count {
            out.append((slice(start, scalars.count), pieceX, x - pieceX))
        }
        return out
    }

    /// The advance of `text`, kerning included.
    static func widthDots(_ text: String, _ block: Block, _ tw: Int, kerning: Bool = true) -> Int {
        guard let last = pieces(text, block, tw, kerning: kerning).last else { return 0 }
        return last.x + last.width
    }
}
