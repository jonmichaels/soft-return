// HPLJET.swift
//
// Where WS4's HPLJET driver puts each character of a body line. Port of ctrl-kd's
// `hpljet.py`.
//
// WordStar 4 prints through a code module in WSPRINT.OVR; on a LaserJet that is HPLJET,
// which places every word with an absolute move and spreads a justified line itself (WS4
// teardown, `wordstar4-dos/4-formatting-printing.md` 15, rules M1-M14 of its model
// `tools/p_mj_model.py`, with the module's code addresses). This is that model, run on a
// parsed line instead of raw bytes:
//
// - A line is measured only when `.UJ` is on (WS4's factory "dis" is on for HPLJET), it
//   ends in a soft return, and it holds more than two letters (M1, M2, M8).
// - Its justified region starts at the first word holding a letter stored with bit 7,
//   WS4's word-end flag (`Line.hibit`); text before it prints at its natural widths (M4).
// - The slack is the line's nominal width, `.CW` per cell, less its device width, the
//   font's own widths; an editor soft space (A0h) has no device width, so the driver
//   re-spreads the editor's padding (M5, M7). A soft hyphen is measured as `?` and printed
//   as `-` (M6).
// - Letter spacing takes whole 1/120" units when the slack per blank is over THR, at most
//   MAXL of them; the rest goes to the blanks, each taking the pool left over the blanks
//   left, quantised to 1/120" under `.PS` (M9, M11).
// - Under `.PS` a character advances by its proportional table width (1/600"); at fixed
//   pitch by the font's cell. An x is sent as `x * 720 // den` decipoints, truncated.
//
// A negative slack (M10) is the module's code, not run by any capture. Tabs, print
// controls and `^P@` are not modelled: such a line gets nil and is drawn at its natural
// widths.

enum HPLJET {
    /// `.CW` for `^PA`: the factory alternate pitch, 10/120" (WS4 teardown 4 §15.4,
    /// drv-hpljet: `ESC(s12H ESC&k10H`).
    static let altCW = 10
    /// [1821] in the module image, the blank-shrink factor (M10).
    private static let shrink1821 = 0x50

    /// Python's `//`: the quotient rounded toward minus infinity.
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// `(record, extra)` for a character at `.CW` `cw` (0x0F8D). Under `.PS` a map entry
    /// with 0x40/0x80 set has its italic and bold records after it. Port of `font_for`.
    static func fontFor(_ cw: Int, ps: Bool, bold: Bool = false,
                        italic: Bool = false) -> (record: Int, extra: Int) {
        var (rec, extra) = (ps ? HPLJETTables.fontmapPS : HPLJETTables.fontmapFixed)[
            Swift.min(Swift.max(cw, 0), 30)]
        if ps && rec & 0xC0 != 0 {
            rec = (rec & 0x3F) + (bold ? 2 : italic ? 1 : 0)
        }
        return (rec & 0x3F, extra)
    }

    /// `(device width, extra)` of printer character `c` in 1/den inch (0x14CF): a fixed
    /// font's cell, or a proportional table's width (A0h as 20h). Port of `width`.
    static func width(_ rec: Int, _ extra: Int, _ c: Int) -> (width: Int, extra: Int) {
        let font = HPLJETTables.fonts[rec]
        guard let table = font.table, let widths = HPLJETTables.ps[table] else {
            return (font.w, extra)
        }
        let code = c == 0xA0 ? 0x20 : c
        return (widths[code] * (font.flags & 0x100 != 0 ? 2 : 1), 0)
    }

    /// The printer character for CP437 `c` (COMPOS, first byte). Port of `compos`.
    static func compos(_ c: Int) -> Int {
        HPLJETTables.compos[c].first
    }

    /// One character of a line: the code the printer receives, after COMPOS (A0h for an
    /// editor soft space), whether it was stored with bit 7, and the font it is set in.
    /// `measureAs` is the CP437 code the driver measures it by when that differs: a soft
    /// hyphen, printed `-`, is measured as COMPOS[1Fh], `?` (M6). Port of `Char`.
    struct Char {
        var code: Int
        var hib = false
        var cw = 12
        var bold = false
        var italic = false
        var measureAs: Int? = nil

        var blank: Bool { code == 0x20 || code == 0xA0 }
    }

    /// `[(x, advance)]` for every character of one body line, x in decipoints from the
    /// logical page's left edge and the advance in decipoints, or nil when the line uses
    /// something this model does not cover. Port of `place_line`.
    ///
    /// `po` is the page offset in cells, `poCW` the `.CW` in force when `.PO` was read (x
    /// starts at `po * poCW` 1/120", WS4 teardown 4 §15.3), `ps` `.PS`, `uj` `.UJ` ("on",
    /// "off", "dis"), `soft` whether the line ends in a soft return.
    static func placeLine(_ chars: [Char], po: Int, poCW: Int, ps: Bool, uj: String,
                          soft: Bool) -> [(x: Int, advance: Double)]? {
        let n = chars.count
        if n == 0 { return [] }
        let fonts = chars.map { fontFor($0.cw, ps: ps, bold: $0.bold, italic: $0.italic) }
        let dens = Set(fonts.map { HPLJETTables.fonts[$0.record].den })
        guard dens.count == 1, let denFont = dens.first else { return nil }
        let q2000 = HPLJETTables.fonts[fonts[0].record].flags & 0x2000 != 0
        let wUnit = HPLJETTables.fonts[fonts[0].record].w

        // ---- measurement (0x054D-0x0697)
        var on = (uj == "on" || uj == "dis") && soft
        var prefix = 0, blanks = 0, blankish = 0, letters = 0, poolB = 0, poolL = 0
        var neg = false
        if on {
            var latch = false
            var pre = 0, nom = 0, dev = 0, ltr = 0, blk = 0, bl2 = 0
            var i = 0
            while i < n {
                if !chars[i].blank {
                    var ch = 0, dx = 0, dv = 0
                    while i < n && !chars[i].blank {
                        let c = chars[i]
                        latch = latch || c.hib
                        let (rec, extra) = fonts[i]
                        let code = c.measureAs.map { compos($0) } ?? c.code
                        let (dw, ex) = width(rec, extra, code)
                        ch += 1
                        dv += dw + ex
                        dx += c.cw
                        i += 1
                    }
                    if latch {
                        nom += dx
                        dev += dv
                        ltr = (ltr + ch) & 0xFF
                    } else {
                        pre = (pre + ch) & 0xFF
                    }
                } else {
                    var cb = 0, ca = 0, dx = 0, dv = 0
                    while i < n && chars[i].blank {
                        let c = chars[i]
                        let (rec, extra) = fonts[i]
                        if c.code == 0x20 {
                            cb += 1
                            let (dw, ex) = width(rec, extra, compos(0x20))
                            dv += dw + ex
                        } else {
                            ca += 1
                        }
                        dx += c.cw
                        i += 1
                    }
                    if i >= n { break }                    // trailing blanks dropped
                    if cb == 0 {                           // 0x0741: one A0 is the blank
                        cb = 1
                        ca -= 1
                    }
                    if latch {
                        nom += dx
                        dev += dv
                        blk = (blk + cb) & 0xFF
                        bl2 = (bl2 + cb + ca) & 0xFF
                    } else {
                        pre = (pre + cb + ca) & 0xFF
                    }
                }
            }
            (prefix, blanks, blankish, letters) = (pre, blk, bl2, ltr)
            var s = nom - floorDiv(dev * 120, denFont)
            s = ((s + 0x8000) & 0xFFFF) - 0x8000
            if letters <= 2 {                              // M8
                on = false
                (prefix, blanks, blankish, letters) = (0, 0, 0, 0)
            } else {
                letters = (letters - 1) & 0xFF
                if s < 0 {                                 // M10
                    neg = true
                    s = -s
                    let (bw, ex) = width(fonts[0].record, fonts[0].extra, 0x20)
                    let cap = ((floorDiv((bw + ex) * shrink1821, denFont) & 0xFF) * blanks)
                        & 0xFFFF
                    s = Swift.min(s, cap)
                } else {                                   // M9
                    var per = 0
                    while per < HPLJETTables.maxLetterUnits {
                        if (s >> 8) < blanks && blanks != 0
                            && floorDiv(s, blanks) & 0xFF <= HPLJETTables.blankThreshold {
                            break
                        }
                        if s < letters { break }
                        s -= letters
                        poolL += letters
                        per += 1
                    }
                }
                poolB = s
            }
        }
        if !on {
            (prefix, blanks, blankish, letters, poolB, poolL) = (0, 0, 0, 0, 0, 0)
        }

        // ---- printing (0x0812-0x08D9, 0x0CD4-0x0D6E)
        guard let firstP = chars.firstIndex(where: { !$0.blank }) else {
            return Array(repeating: (x: 0, advance: 0.0), count: n)
        }
        var den = 120
        var x = po * poCW
        var cell = po * poCW
        var snap = false
        var loaded = false
        var prev = 0
        var out: [(x: Int, advance: Double)] = []
        out.reserveCapacity(n)

        func setden(_ new: Int) {
            if new != den {
                x = floorDiv(x * new, den)
                poolB = floorDiv(poolB * new, den)
                poolL = floorDiv(poolL * new, den)
                den = new
            }
        }

        for (k, c) in chars.enumerated() {
            let blank = c.blank
            if snap {
                snap = false
                x = floorDiv(cell * den, 120)
            }
            if blank && ps && k < firstP {                 // M13
                setden(120)
                let x0 = x
                x += c.cw
                prefix = (prefix - 1) & 0xFF
                if prefix == 0 { snap = true }
                loaded = false
                cell += c.cw
                out.append((x: floorDiv(x0 * 720, den), advance: Double(c.cw) * 6.0))
                continue
            }
            if !loaded {
                setden(denFont)
                loaded = true
            }
            let (rec, extra) = fonts[k]
            let (dw, deviceExtra) = width(rec, extra, c.code)
            var ex = deviceExtra
            var wid: Int
            var share: Int
            if prefix != 0 {
                prefix = (prefix - 1) & 0xFF
                if prefix == 0 { snap = ps }
                share = 0
                wid = dw
            } else if blank {
                wid = dw
                if blankish == 0 {
                    prev = c.code
                    share = 0
                } else {
                    blankish -= 1
                    let zero: Bool
                    if c.code == 0x20 {
                        let old = prev
                        prev = c.code
                        zero = old == 0xA0
                    } else {
                        zero = prev == 0x20 || prev == 0xA0
                        if !zero { prev = c.code }
                    }
                    if zero {
                        (wid, share, ex) = (0, 0, 0)
                    } else {
                        let cl = blanks
                        blanks = (blanks - 1) & 0xFF
                        var q = poolB != 0 && cl != 0 ? floorDiv(poolB, cl) : 0
                        if q2000 { q = floorDiv(q, wUnit) * wUnit }
                        poolB -= q
                        share = neg ? -q : q
                    }
                }
            } else {
                prev = c.code
                let cl = letters
                if cl != 0 { letters -= 1 }
                var q = poolL != 0 && cl != 0 ? floorDiv(poolL, cl) : 0
                if q2000 { q = floorDiv(q, wUnit) * wUnit }
                poolL -= q
                share = neg ? -q : q
                wid = dw
            }
            let adv = wid + share + ex
            out.append((x: floorDiv(x * 720, den), advance: Double(adv) * 720.0 / Double(den)))
            x += adv
            cell += c.cw
        }
        return out
    }
}
