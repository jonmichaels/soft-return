/// Driver-specific printed-mode fidelity for LJ6DTP (Robert J. Sawyer's HP LaserJet
/// Printer Description File for WordStar 6.0/7.0) plus the cp437-graphics-as-vectors path
/// every printed document can use. Port of `pdf.py`'s `_COLOUR_GRAY_LJ6DTP`, `_LJ_SUBST`/
/// `_LJ_SUBST_UNIVERS`/`_lj_substitute`, `BOX_ARMS`/`SHADE_GRAY`/`PART_BLOCKS`/
/// `GRAPHIC_CHARS`/`_graphic_ops`/`_split_graphics`, and `_face_tz`.

/// LJ6DTP's colour palette as PDF fill grays (`g`: 0 black, 1 white). The indices are
/// DRIVER-DEFINED — this table was recovered from the LJ6DTP printer description file's
/// own string table and confirmed against the document's sample rows: 1-7 are
/// 85/75/50/25/15/5/2% ink, 9-14 are HP fill patterns (approximated mid-gray — texture is
/// not expressible without pattern objects), 15 is White, the knockout. Index 8 is
/// ambiguous in the source and left black (no entry -> caller's own 0.0 default).
/// Applied ONLY when the document declares driver LJ6DTP; any other driver's indices
/// stay opaque, unrendered.
let colourGrayLJ6DTP: [Int: Double] = [
    1: 0.15, 2: 0.25, 3: 0.50, 4: 0.75, 5: 0.85, 6: 0.95, 7: 0.98,
    9: 0.5, 10: 0.5, 11: 0.5, 12: 0.5, 13: 0.5, 14: 0.5,
    15: 1.0,
]

/// LJ6DTP's character substitutions — the driver patches PC-8 slots so that typing `_`
/// PRINTS an em dash, `«»` print curly doubles, ☻ prints ©, and so on. Face rules from
/// the same chart: fixed-pitch faces (Courier, Letter Gothic, LinePrinter) are NOT
/// patched, and the rounded box corners exist in Univers only (drawn here as square
/// corners via the vector path — the shape is approximated, the position is exact).
private let ljSubst: [Character: Character] = [
    "\u{263B}": "\u{00A9}",   // ☻ -> ©
    "\u{263C}": "\u{2026}",   // ☼ -> …
    "'": "\u{2019}",          // ' -> '
    "_": "\u{2014}",          // _ -> — (em dash)
    "`": "\u{2018}",          // ` -> '
    "\u{00AB}": "\u{201C}",   // « -> "
    "\u{00BB}": "\u{201D}",   // » -> "
    "\u{2261}": "\u{2013}",   // ≡ -> – (en dash)
]
private let ljSubstUnivers: [Character: Character] = [
    "\u{2665}": "\u{250C}",   // ♥ -> ┌
    "\u{2666}": "\u{2510}",   // ♦ -> ┐
    "\u{2663}": "\u{2514}",   // ♣ -> └
    "\u{2660}": "\u{2518}",   // ♠ -> ┘
]

/// Apply the LJ6DTP print-time substitutions to one line's segments. Port of
/// `_lj_substitute`.
func ljSubstitute(_ segs: [LineSegment]) -> [LineSegment] {
    segs.map { seg in
        guard let entry = seg.entry, entry.proportional else { return seg }
        var text = String(seg.text.map { ljSubst[$0] ?? $0 })
        if (entry.typestyleName ?? "").hasPrefix("Univers") {
            text = String(text.map { ljSubstUnivers[$0] ?? $0 })
        }
        var out = seg
        out.text = text
        return out
    }
}

// ------------------------------------------------- cp437 graphics as vectors
//
// Latin-1/cp1252 has none of cp437's line-drawing repertoire, so the text path degrades
// every box/shade/block glyph to '?'. But these glyphs ARE geometry: a full block is a
// filled cell, a shade is a lighter fill, and each box-drawing character is up to four
// half-arms (up/down/left/right), single or double, meeting at the cell's center.
// Drawing them as rectangles is not an approximation of the printed page — it is what
// the printer's own glyphs put on paper, minus the dot pitch. Only spans WITH a font
// block take this path (a fontless byte is never changed).

/// Arms per glyph: (up, down, left, right); 0 none, 1 single, 2 double.
let boxArms: [Character: (up: Int, down: Int, left: Int, right: Int)] = [
    "\u{2500}": (0, 0, 1, 1), "\u{2502}": (1, 1, 0, 0),
    "\u{250C}": (0, 1, 0, 1), "\u{2510}": (0, 1, 1, 0),
    "\u{2514}": (1, 0, 0, 1), "\u{2518}": (1, 0, 1, 0),
    "\u{251C}": (1, 1, 0, 1), "\u{2524}": (1, 1, 1, 0),
    "\u{252C}": (0, 1, 1, 1), "\u{2534}": (1, 0, 1, 1), "\u{253C}": (1, 1, 1, 1),
    "\u{2550}": (0, 0, 2, 2), "\u{2551}": (2, 2, 0, 0),
    "\u{2554}": (0, 2, 0, 2), "\u{2557}": (0, 2, 2, 0),
    "\u{255A}": (2, 0, 0, 2), "\u{255D}": (2, 0, 2, 0),
    "\u{2560}": (2, 2, 0, 2), "\u{2563}": (2, 2, 2, 0),
    "\u{2566}": (0, 2, 2, 2), "\u{2569}": (2, 0, 2, 2), "\u{256C}": (2, 2, 2, 2),
    "\u{2552}": (0, 1, 0, 2), "\u{2553}": (0, 2, 0, 1),
    "\u{2555}": (0, 1, 2, 0), "\u{2556}": (0, 2, 1, 0),
    "\u{2558}": (1, 0, 0, 2), "\u{2559}": (2, 0, 0, 1),
    "\u{255B}": (1, 0, 2, 0), "\u{255C}": (2, 0, 1, 0),
    "\u{255E}": (1, 1, 0, 2), "\u{255F}": (2, 2, 0, 1),
    "\u{2561}": (1, 1, 2, 0), "\u{2562}": (2, 2, 1, 0),
    "\u{2564}": (0, 1, 2, 2), "\u{2565}": (0, 2, 1, 1),
    "\u{2567}": (1, 0, 2, 2), "\u{2568}": (2, 0, 1, 1),
    "\u{256A}": (1, 1, 2, 2), "\u{256B}": (2, 2, 1, 1),
]
/// Shades: ink coverage -> PDF fill gray (1 = white paper).
let shadeGray: [Character: Double] = [
    "\u{2591}": 0.75, "\u{2592}": 0.50, "\u{2593}": 0.25,
]
/// Partial blocks: (x-frac, y-frac, w-frac, h-frac) of the cell.
let partBlocks: [Character: (x: Double, y: Double, w: Double, h: Double)] = [
    "\u{2580}": (0, 0.5, 1, 0.5), "\u{2584}": (0, 0, 1, 0.5),
    "\u{258C}": (0, 0, 0.5, 1), "\u{2590}": (0.5, 0, 0.5, 1),
]
let fullBlock: Character = "\u{2588}"
let graphicChars: Set<Character> =
    Set([fullBlock]).union(boxArms.keys).union(shadeGray.keys).union(partBlocks.keys)

/// Vector ops for one all-graphics span (spaces advance, draw nothing). Port of
/// `_graphic_ops`.
func graphicOps(_ text: String, x: Double, y: Double, pitch: Double, pt: Int) -> [[UInt8]] {
    var ops: [[UInt8]] = []
    let yb = y - 0.25 * Double(pt)
    let h = 1.1 * Double(pt)
    let my = yb + h / 2.0
    let t = max(0.5, Double(pt) / 12.0)          // line weight
    let d = Double(pt) / 10.0                    // double-line half-gap
    func rect(_ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) {
        ops.append(Array("\(fixedOneDecimalDouble(rx)) \(fixedOneDecimalDouble(ry)) "
            .utf8) + Array("\(fixedOneDecimalDouble(rw)) \(fixedOneDecimalDouble(rh)) re f".utf8))
    }
    for (n, ch) in text.enumerated() {
        let x0 = x + Double(n) * pitch
        if ch == " " { continue }
        if ch == fullBlock {
            rect(x0, yb, pitch, h)
        } else if let gray = shadeGray[ch] {
            ops.append(Array("q \(fixedTwoDecimals(gray)) g".utf8))
            rect(x0, yb, pitch, h)
            ops.append(Array("Q".utf8))
        } else if let frac = partBlocks[ch] {
            rect(x0 + frac.x * pitch, yb + frac.y * h, frac.w * pitch, frac.h * h)
        } else if let arms = boxArms[ch] {
            let mx = x0 + pitch / 2.0
            for (weight, xa, xb) in [(arms.left, x0, mx), (arms.right, mx, x0 + pitch)] {
                if weight == 1 {
                    rect(xa, my - t / 2, xb - xa, t)
                } else if weight == 2 {
                    rect(xa, my + d - t / 2, xb - xa, t)
                    rect(xa, my - d - t / 2, xb - xa, t)
                }
            }
            for (weight, ya, yc) in [(arms.up, my, yb + h), (arms.down, yb, my)] {
                if weight == 1 {
                    rect(mx - t / 2, ya, t, yc - ya)
                } else if weight == 2 {
                    rect(mx - d - t / 2, ya, t, yc - ya)
                    rect(mx + d - t / 2, ya, t, yc - ya)
                }
            }
        }
    }
    return ops
}

/// Maximal runs starting and ending at a graphic character, possibly with spaces (or
/// more graphics) in between — Python's `_GRAPHIC_RUN` regex (`[G](?:[G ]*[G])?`),
/// reproduced by hand since this module has no regex engine. Returns non-overlapping
/// index ranges into `chars`.
func graphicRunRanges(_ chars: [Character]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var i = 0
    let n = chars.count
    while i < n {
        if graphicChars.contains(chars[i]) {
            var j = i
            var lastGraphic = i
            while j < n, graphicChars.contains(chars[j]) || chars[j] == " " {
                if graphicChars.contains(chars[j]) { lastGraphic = j }
                j += 1
            }
            ranges.append(i..<(lastGraphic + 1))
            i = lastGraphic + 1
        } else {
            i += 1
        }
    }
    return ranges
}

/// Break mixed text/graphics segments so each piece is all-one-kind. Segments without a
/// font block pass through whole (they never take the vector path), as do segments with
/// no graphic character at all. Port of `_split_graphics`.
func splitGraphics(_ segs: [LineSegment]) -> [LineSegment] {
    var out: [LineSegment] = []
    for seg in segs {
        guard seg.entry != nil else {
            out.append(seg)
            continue
        }
        let chars = Array(seg.text)
        guard chars.contains(where: { graphicChars.contains($0) }) else {
            out.append(seg)
            continue
        }
        var pos = 0
        for range in graphicRunRanges(chars) {
            if range.lowerBound > pos {
                out.append(seg.withText(String(chars[pos..<range.lowerBound])))
            }
            out.append(seg.withText(String(chars[range])))
            pos = range.upperBound
        }
        if pos < chars.count {
            out.append(seg.withText(String(chars[pos...])))
        }
    }
    return out
}

/// Face-constant `Tz`: one horizontal scale per (face, HMI pitch, size), chosen so the
/// face's AVERAGE character lands on the document's grid. Per-span scaling (the earlier
/// model) forced every span to end exactly on the grid, which crushed any short span
/// whose glyphs are wider than average, and let a PDF viewer's substitute metrics
/// accumulate error over a whole span before the next absolutely-placed span collided
/// with it. A constant per-face scale keeps every glyph's true proportions while words
/// are re-anchored to the grid at every space run (see `lineOpsPrinted`). Port of
/// `_face_tz` (without its memoization cache — a pure function is simpler to reason
/// about than shared mutable state in a `@Sendable` emitter, and the reference string is
/// short enough that recomputing it is not a real cost).
private let tzReference = "abcdefghijklmnopqrstuvwxyz "

func faceTz(_ basefont: String, _ pitch: Double, _ pt: Int) -> Double {
    let avg = stringWidthPt(tzReference, basefont, pt) / Double(tzReference.count)
    guard avg > 0 else { return tzDefault }
    // `round(x, 2)`, round-half-to-even, via the same hundredths-as-integer technique
    // `PDFFonts.swift`'s `tzScale` uses (`Formatting.swift`'s `hundredths`).
    let tz = Double(hundredths(pitch / avg * 100.0)) / 100.0
    return min(tzMax, max(tzMin, tz))
}
