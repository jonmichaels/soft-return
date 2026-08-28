/// Driver-specific printed-mode fidelity for LJ6DTP (Robert J. Sawyer's HP LaserJet
/// Printer Description File for WordStar 6.0/7.0) plus the cp437-graphics-as-vectors path
/// every printed document can use. Port of `pdf.py`'s `_COLOUR_GRAY_LJ6DTP`, `_LJ_SUBST`/
/// `_LJ_SUBST_UNIVERS`/`_lj_substitute`, `BOX_ARMS`/`SHADE_GRAY`/`PART_BLOCKS`/
/// `GRAPHIC_CHARS`/`_graphic_ops`/`_split_graphics`, and `_face_tz`.

/// LJ6DTP's colour palette as PDF fill grays (`g`: 0 black, 1 white). The indices are
/// DRIVER-DEFINED — this table was recovered from the LJ6DTP printer description file's
/// own string table and confirmed against the document's sample rows: 1-7 are
/// 85/75/50/25/15/5/2% ink, 15 is White, the knockout. Index 8 is ambiguous in the source
/// and left black (no entry -> caller's own 0.0 default). Applied ONLY when the document
/// declares driver LJ6DTP; any other driver's indices stay opaque, unrendered.
///
/// 9-14 (HP1-HP6) LEFT this table for `lj6dtpHPPatterns` below — they are fill PATTERNS,
/// and collapsing all six to one flat mid-gray (this table's own admitted approximation)
/// made page 5's whole point, six visually distinct textures, read as one swatch repeated
/// six times.
///
/// 1-7 stay FLAT gray rather than real halftone dot screens, deliberately (register C3
/// asked for the call, not just for 9-14): real WS7 puts an actual halftone screen on
/// PAPER, but this table's whole job is a SCREEN-reading facsimile, and a flat
/// 15%/25%/.../98% gray is already visually DISTINCT row to row at the swatch's own size
/// (confirmed against ws7-prints/gpcl6-renders/LJ6DTP-p5.png) — exactly the property the
/// HP patterns were missing. A real dot screen would also risk moire against a PDF
/// viewer's own rasterizer at arbitrary zoom, for a page whose readable point is "seven
/// distinguishable densities".
let colourGrayLJ6DTP: [Int: Double] = [
    1: 0.15, 2: 0.25, 3: 0.50, 4: 0.75, 5: 0.85, 6: 0.95, 7: 0.98,
    15: 1.0,
]

/// HP1-HP6 (colour indices 9-14, confirmed by walking LJ6DTP.WS's own colour-change
/// records against its page-5 sample rows: colour9 sits on the "HP1" line, colour10 on
/// "HP2", ... colour14 on "HP6") as real PDF tiling patterns (`/PatternType 1 /PaintType
/// 1`: colored, painted with plain black strokes against the transparent cell, which
/// reveals white paper between strokes exactly like the driver's own fill patterns do).
/// Each entry is (cell width, cell height, content-stream ops) in PATTERN SPACE; no
/// /Matrix is set, so pattern space ties to the PAGE's default coordinate system (PDF's
/// own rule for an omitted Matrix), not to wherever a given glyph's CTM happens to sit —
/// fine here, every swatch is its own isolated fill. Direction and relative density are
/// what the reference page distinguishes (horizontal / vertical / two diagonals / two
/// crosshatch weaves); exact PCL dot pitch is not reproduced.
let lj6dtpHPPatterns: [Int: (w: Int, h: Int, content: String)] = [
    9:  (300, 4, "1 w 0 0.5 m 300 0.5 l S"),               // HP1 horizontal
    10: (3, 300, "1 w 1.5 0 m 1.5 300 l S"),               // HP2 vertical
    11: (6, 6, "0.8 w 0 0 m 6 6 l S"),                     // HP3 diagonal /
    12: (6, 6, "0.8 w 0 6 m 6 0 l S"),                     // HP4 diagonal \
    13: (6, 6, "0.8 w 0 3 m 6 3 l S 3 0 m 3 6 l S"),       // HP5 crosshatch +
    14: (4, 4, "0.7 w 0 0 m 4 4 l S 0 4 m 4 0 l S"),       // HP6 dense X
]

/// The Printed page's current FILL selection — PDF graphics state, reset per page. One
/// value, either a plain DeviceGray level or one of the HP tiling patterns above (port of
/// Python's `col_state` tuple, `('g', gray)` / `('p', index)`, which grew from a bare
/// float for exactly this reason).
enum PDFFill: Equatable {
    case gray(Double)
    case pattern(Int)
}

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
/// Register C7: these four map to the ARC_CORNERS glyphs (rounded join), NOT to plain
/// ┌┐└┘ -- see `arcCorners`'s own comment for why a distinct character set matters here.
private let ljSubstUnivers: [Character: Character] = [
    "\u{2665}": "\u{256D}",   // ♥ -> ╭
    "\u{2666}": "\u{256E}",   // ♦ -> ╮
    "\u{2663}": "\u{2570}",   // ♣ -> ╰
    "\u{2660}": "\u{256F}",   // ♠ -> ╯
]

/// The SEMANTIC flow's Univers corners. Port of `layout.LJ_SUBST_UNIVERS`, which is
/// deliberately NOT `pdf._LJ_SUBST_UNIVERS`: the arc glyphs above exist so the PDF vector
/// path can draw a quarter-circle JOIN that no font is asked to supply. A layout/RTF/HTML
/// consumer has no vector path and no arc-corner table -- it gets a CHARACTER, and the
/// character WordStar's own chart names for these slots is the plain box corner. Emitting
/// ╭╮╰╯ there hands a downstream renderer a glyph its face may not carry at all.
private let ljSubstUniversSemantic: [Character: Character] = [
    "\u{2665}": "\u{250C}",   // ♥ -> ┌
    "\u{2666}": "\u{2510}",   // ♦ -> ┐
    "\u{2663}": "\u{2514}",   // ♣ -> └
    "\u{2660}": "\u{2518}",   // ♠ -> ┘
]

/// The LJ6DTP substitutions for one run of TEXT in a given font entry — the shared core
/// `ljSubstitute` applies per printed segment, exposed separately because Modern applies
/// the same rule at the token level (ruling 2026-08-06 M7: the driver's patched slots are
/// CONTENT — an em dash is an em dash in any century — while its page art stays
/// print-time). Proportional faces only, Univers corners only, per the driver's own chart.
func ljSubstituteText(_ text: String, entry: FontChange) -> String {
    guard entry.proportional else { return text }
    var out = String(text.map { ljSubst[$0] ?? $0 })
    if (entry.typestyleName ?? "").hasPrefix("Univers") {
        out = String(out.map { ljSubstUniversSemantic[$0] ?? $0 })
    }
    return out
}

/// Apply the LJ6DTP print-time substitutions to one line's segments. Port of
/// `_lj_substitute`.
///
/// `kerning` is `PageLine.kerning` -- the `.KR` state in force where the line sat
/// (default `true`, WordStar's own default). Two of the substituted pairs are only SINGLE
/// curly quotes (backtick -> single open, typed apostrophe -> single close): doubling them
/// ("``"/"''") is how the document fakes a proper curly DOUBLE quote without the DeskTop
/// symbol set actually carrying one -- its own prose: "we've also added these two pairs to
/// the PDF kerning tables" so the pair prints TUCKED TOGETHER, reading as one double-quote
/// glyph, only when kerning is on (register C7). Page 2 demonstrates exactly this: the
/// identical characters typed once under `.kr off` and once under `.kr on`, immediately
/// above each other, specifically so the difference shows. Kerning off is genuinely just
/// the two single quotes at their ordinary advance (loose) -- no change from plain
/// substitution. Rather than compute an arbitrary sub-glyph kern amount, collapsing the
/// kerned pair to the real double curly quote character reproduces the same look the
/// tucked pair makes on paper (measured against LJ6DTP-p2.png).
/// Python's `str.replace(cc, C)` for a doubled character: left to right, NON-overlapping,
/// so a run of three collapses to one replacement plus one leftover. Hand-rolled because
/// this module's own `replacingAll` takes a single Character needle.
private func collapsingDoubled(_ text: String, _ ch: Character, to replacement: Character) -> String {
    let chars = Array(text)
    guard chars.contains(ch) else { return text }
    var out = ""
    var i = 0
    while i < chars.count {
        if chars[i] == ch, i + 1 < chars.count, chars[i + 1] == ch {
            out.append(replacement)
            i += 2
        } else {
            out.append(chars[i])
            i += 1
        }
    }
    return out
}

func ljSubstitute(_ segs: [LineSegment], kerning: Bool = true) -> [LineSegment] {
    segs.map { seg in
        guard let entry = seg.entry, entry.proportional else { return seg }
        var text = String(seg.text.map { ljSubst[$0] ?? $0 })
        if kerning {
            text = collapsingDoubled(text, "\u{2018}", to: "\u{201C}")
            text = collapsingDoubled(text, "\u{2019}", to: "\u{201D}")
        }
        if (entry.typestyleName ?? "").hasPrefix("Univers") {
            text = String(text.map { ljSubstUnivers[$0] ?? $0 })
        }
        var out = seg
        out.text = text
        return out
    }
}

/// Register C7: LJ6DTP's own Univers-only rounded box corners -- the driver substitutes
/// ♥♦♣♠ (0x03-0x06) to these in Univers ONLY (`ljSubstUnivers`), never to plain ┌┐└┘.
/// WS7 (LJ6DTP-p3.png) draws a quarter-circle JOIN, not `boxArms`'s sharp right angle --
/// real box borders elsewhere in the document (page 4's checkerboard, page 5's table) are
/// typed as the ORDINARY box-drawing bytes and never touch this table, so keeping these as
/// their own characters (rather than reusing ┌┐└┘ themselves) can never round a real box's
/// corner by accident. Each entry: (vertical arm direction, horizontal arm direction) --
/// the SAME sense `boxArms`'s own up/down/left/right already uses for the square glyphs
/// these replace.
enum ArcDirection { case up, down, left, right }
let arcCorners: [Character: (vertical: ArcDirection, horizontal: ArcDirection)] = [
    "\u{256D}": (.down, .right),   // was ┌ -- upper-left rounded box corner
    "\u{256E}": (.down, .left),    // was ┐ -- upper-right
    "\u{2570}": (.up, .right),     // was └ -- lower-left
    "\u{256F}": (.up, .left),      // was ┘ -- lower-right
]

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
    // cp437 0xFE: the PC-8 black square, WordStar-era bullet of choice (Sawyer's
    // -README list markers). Centered small block, per the IBM glyph -- a TRUE
    // square (fw == fh), meaningful now that `squarePartBlocks` scales both axes by
    // the same `sq = min(pitch, h)` reference (b24 round 20, slate item 8). The old
    // (0.12, 0.18, 0.72, 0.55) pair was tuned by eye against the un-squared
    // rendering (pitch for x, h for y independently) and came out 5.2x7.3pt on a
    // 12pt Courier cell -- visibly taller than wide, the "squashed" defect
    // reported. 0.65 keeps the same rough visual weight ("centered small block")
    // as a real square. (M11)
    "\u{25A0}": (0.175, 0.175, 0.65, 0.65),
]
let fullBlock: Character = "\u{2588}"

/// ▀▄▌▐ are genuinely CELL-shaped (a "half block" means half the actual advance-
/// width/line-height cell, whatever its aspect) — only ■ is authored to look like a
/// regular, roughly-square dot, so only it gets the square-cell correction
/// `graphicOps` applies to `symbolShapes`. Port of `SQUARE_PART_BLOCKS`.
let squarePartBlocks: Set<Character> = ["\u{25A0}"]

/// cp437 control-position symbol glyphs (card suits, smiley, sun, triple bar). Port of
/// `SYMBOL_SHAPES` (Jon's ruling, 2026-08-11, extending the box ruling: "the card suits,
/// etc. show up everywhere"). LJ6DTP p3's "Shows on screen as" column is literal bytes
/// 02-06/0F/F0 -- on the era's screen: ☻ ♥ ♦ ♣ ♠ ☼ ≡. Latin-1 has none of them, so the text
/// path degraded all seven to '?'. Like the box set, they are geometry: each entry is a
/// list of filled sub-shapes in cell fractions (x up-right, y up from cell bottom).
/// `.white` wraps a sub-shape drawn paper-white (knockout). Scope is exactly the ruled
/// seven; the rest of cp437's graphics repertoire (arrows, music notes...) still degrades
/// until a document surfaces them.
indirect enum SymbolSubShape {
    case poly([(x: Double, y: Double)])
    case disc(x: Double, y: Double, r: Double)
    case rect(x: Double, y: Double, w: Double, h: Double)
    case white(SymbolSubShape)
}
let symbolShapes: [Character: [SymbolSubShape]] = [
    // b24 round 20 (slate item 8): symmetric span (0.8 both axes -- was
    // 0.76w/0.84h, a minor pre-existing asymmetry harmless before the pitch/h
    // aspect fix made shape authoring finally square-meaningful).
    "\u{2666}": [.poly([(0.50, 0.90), (0.90, 0.50), (0.50, 0.10), (0.10, 0.50)])],
    "\u{2665}": [.disc(x: 0.32, y: 0.62, r: 0.21), .disc(x: 0.68, y: 0.62, r: 0.21),
                 .poly([(0.09, 0.56), (0.91, 0.56), (0.50, 0.08)])],
    "\u{2660}": [.poly([(0.50, 0.94), (0.22, 0.52), (0.78, 0.52)]),
                 .disc(x: 0.32, y: 0.42, r: 0.21), .disc(x: 0.68, y: 0.42, r: 0.21),
                 .poly([(0.44, 0.36), (0.56, 0.36), (0.62, 0.08), (0.38, 0.08)])],
    "\u{2663}": [.disc(x: 0.50, y: 0.68, r: 0.24), .disc(x: 0.29, y: 0.42, r: 0.24),
                 .disc(x: 0.71, y: 0.42, r: 0.24),
                 .poly([(0.44, 0.34), (0.56, 0.34), (0.62, 0.06), (0.38, 0.06)])],
    "\u{263B}": [.disc(x: 0.50, y: 0.50, r: 0.44),
                 .white(.disc(x: 0.34, y: 0.64, r: 0.09)),
                 .white(.disc(x: 0.66, y: 0.64, r: 0.09)),
                 .white(.rect(x: 0.28, y: 0.28, w: 0.44, h: 0.09)),
                 .white(.rect(x: 0.24, y: 0.34, w: 0.08, h: 0.08)),
                 .white(.rect(x: 0.68, y: 0.34, w: 0.08, h: 0.08))],
    "\u{263C}": [.disc(x: 0.50, y: 0.50, r: 0.22),
                 .white(.disc(x: 0.50, y: 0.50, r: 0.11)),
                 .rect(x: 0.45, y: 0.78, w: 0.10, h: 0.16), .rect(x: 0.45, y: 0.06, w: 0.10, h: 0.16),
                 .rect(x: 0.06, y: 0.45, w: 0.16, h: 0.10), .rect(x: 0.78, y: 0.45, w: 0.16, h: 0.10),
                 .rect(x: 0.17, y: 0.71, w: 0.12, h: 0.12), .rect(x: 0.71, y: 0.71, w: 0.12, h: 0.12),
                 .rect(x: 0.17, y: 0.17, w: 0.12, h: 0.12), .rect(x: 0.71, y: 0.17, w: 0.12, h: 0.12)],
    "\u{2261}": [.rect(x: 0.10, y: 0.62, w: 0.80, h: 0.09), .rect(x: 0.10, y: 0.42, w: 0.80, h: 0.09),
                 .rect(x: 0.10, y: 0.22, w: 0.80, h: 0.09)],
]

let graphicChars: Set<Character> =
    Set([fullBlock]).union(boxArms.keys).union(shadeGray.keys).union(partBlocks.keys)
        .union(symbolShapes.keys).union(arcCorners.keys)

/// Vector ops for one all-graphics span (spaces advance, draw nothing).
///
/// `leadFactor * pt` is the glyph's own CELL height -- a box-drawing arm's vertical
/// stroke spans the full cell, top to bottom (the `boxArms` branch below), so
/// consecutive PHYSICAL lines' cells only chain into one continuous rule if this cell
/// is at least as tall as the actual line-to-line advance. Printed's default (1.1)
/// leaves deliberate slack against its own LEAD (12pt default, matching a 12pt font:
/// 1.1*12=13.2 > 12, a harmless sub-point overlap, invisible on paper/PDF) because
/// Printed's per-line leading can vary block to block (`.lh`) independently of any
/// fixed relationship to `pt`.
///
/// Modern has no such slack: its own line advance is EXACTLY `modernLine * pt`
/// (`PDFModernLayout`'s own uniform per-vline `h`), so the default 1.1 factor left a
/// real gap -- register b32, BOX.WS/BOXES.WS's box sides rendering as broken dashes
/// in Modern PDF (1.1*14=15.4pt cell vs 1.2*14=16.8pt actual advance, a 1.4pt gap
/// every line). Modern's own call site passes `modernLine` here so the cell height
/// matches its own advance exactly -- cells touch with zero gap AND zero overlap, for
/// any uniformly-sized run of lines (the ordinary case for ASCII box art). Port of
/// `_graphic_ops`.
func graphicOps(_ text: String, x: Double, y: Double, pitch: Double, pt: Int,
                leadFactor: Double = 1.1) -> [[UInt8]] {
    var ops: [[UInt8]] = []
    let yb = y - 0.25 * Double(pt)
    let h = leadFactor * Double(pt)
    let my = yb + h / 2.0
    let t = max(0.5, Double(pt) / 12.0)          // line weight
    // Register C12: a double-weight box-drawing rule (═, ║, and the table junction
    // characters built from them) is two hairlines with a hairline GAP between them, not
    // two hairlines a whole extra stroke-width apart. `d` used to be an unmeasured guess
    // (a bare pt/10, no citation); pixel-sampled against LJ6DTP-p7.png's own
    // proportional-spacing table at 300dpi (10.05pt Courier, page 7's own PC-8/font-family
    // grid, the BEST-matching page in the document but for this): real WS7's double rule
    // is two ~3px strokes with a ~3px gap between them -- stroke and gap the SAME size,
    // i.e. d == t, not pt/10 (which measured a visibly wider ~5px gap, "possibly doubled"
    // reading heavier as a unit even though the single-weight stroke elsewhere on the same
    // page already matched at 3px either way).
    let d = t                                    // double-line half-gap
    func rect(_ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double) {
        ops.append(Array("\(fixedOneDecimalDouble(rx)) \(fixedOneDecimalDouble(ry)) "
            .utf8) + Array("\(fixedOneDecimalDouble(rw)) \(fixedOneDecimalDouble(rh)) re f".utf8))
    }
    let K = 0.5523                               // Bezier circle constant
    func pair(_ a: Double, _ b: Double) -> String {
        "\(fixedOneDecimalDouble(a)) \(fixedOneDecimalDouble(b))"
    }
    func disc(_ cx: Double, _ cy: Double, _ r: Double) {
        let k = K * r
        ops.append(Array("\(pair(cx + r, cy)) m".utf8))
        ops.append(Array("\(pair(cx + r, cy + k)) \(pair(cx + k, cy + r)) \(pair(cx, cy + r)) c".utf8))
        ops.append(Array("\(pair(cx - k, cy + r)) \(pair(cx - r, cy + k)) \(pair(cx - r, cy)) c".utf8))
        ops.append(Array("\(pair(cx - r, cy - k)) \(pair(cx - k, cy - r)) \(pair(cx, cy - r)) c".utf8))
        ops.append(Array("\(pair(cx + k, cy - r)) \(pair(cx + r, cy - k)) \(pair(cx + r, cy)) c".utf8))
        ops.append(Array("f".utf8))
    }
    // b24 round 20 (slate item 8): a symbol glyph's fractional coordinates are
    // authored to look REGULAR (a round dot, a true diamond, a circular sun) --
    // not cell-shaped like a box-drawing arm or a half-block. Scaling x by `pitch`
    // and y by `h` independently only reproduces that intent when the two happen
    // to be equal; a real printed cell never is (12pt Courier: pitch 7.2pt
    // advance, h 13.2pt) -- `disc`'s own radius already used `min(pitch, h)`
    // (bisected against a pre-round-9 commit on CONVERT.WS: BYTE-IDENTICAL, so
    // this was never a regression -- the mismatch has always been there, just
    // never applied to poly/rect). `sq` and cell-CENTER-relative offsets make
    // every shape kind use the same single, consistent scale: a strict
    // generalization that reproduces the exact prior output whenever
    // `pitch == h` (the poly/rect formulas below reduce algebraically to
    // `x0 + fx*pitch, yb + fy*h` in that case) and only corrects the aspect when
    // it doesn't. Port of `_graphic_ops`'s own `sq = min(pitch, h)`.
    let sq = min(pitch, h)
    func symbolShape(_ shape: SymbolSubShape, _ x0: Double) {
        let cx = x0 + pitch / 2.0, cy = yb + h / 2.0
        switch shape {
        case .white(let sub):
            ops.append(Array("q 1 g".utf8))
            symbolShape(sub, x0)
            ops.append(Array("Q".utf8))
        case .poly(let pts):
            let mapped = pts.map { (cx + ($0.x - 0.5) * sq, cy + ($0.y - 0.5) * sq) }
            ops.append(Array("\(pair(mapped[0].0, mapped[0].1)) m".utf8))
            for p in mapped.dropFirst() {
                ops.append(Array("\(pair(p.0, p.1)) l".utf8))
            }
            ops.append(Array("h f".utf8))
        case .disc(let fx, let fy, let fr):
            disc(cx + (fx - 0.5) * sq, cy + (fy - 0.5) * sq, fr * sq)
        case .rect(let fx, let fy, let fw, let fh):
            rect(cx + (fx - 0.5) * sq, cy + (fy - 0.5) * sq, fw * sq, fh * sq)
        }
    }
    for (n, ch) in text.enumerated() {
        let x0 = x + Double(n) * pitch
        if ch == " " { continue }
        if let shapes = symbolShapes[ch] {
            for shape in shapes { symbolShape(shape, x0) }
        } else if ch == fullBlock {
            rect(x0, yb, pitch, h)
        } else if let gray = shadeGray[ch] {
            ops.append(Array("q \(fixedTwoDecimals(gray)) g".utf8))
            rect(x0, yb, pitch, h)
            ops.append(Array("Q".utf8))
        } else if let frac = partBlocks[ch] {
            if squarePartBlocks.contains(ch) {
                let cx = x0 + pitch / 2.0, cy = yb + h / 2.0
                rect(cx + (frac.x - 0.5) * sq, cy + (frac.y - 0.5) * sq, frac.w * sq, frac.h * sq)
            } else {
                rect(x0 + frac.x * pitch, yb + frac.y * h, frac.w * pitch, frac.h * h)
            }
        } else if let arc = arcCorners[ch] {
            // Register C7: one vertical stub + one horizontal stub (same extent as the
            // matching `boxArms` glyph: cell-center to cell edge), joined by a
            // quarter-circle instead of meeting square at the center. sh/sv pick which
            // cell edge each stub reaches (+1 = right/up, -1 = left/down) and, together,
            // the arc's own center C = (mx + sh*rc, my + sv*rc); A and B (the stub ends ON
            // the arc) sit exactly `rc` from C along the axes, so the standard 4-point
            // cubic-bezier quarter-circle (K, the same constant `disc` uses above) joins
            // them exactly.
            let mx = x0 + pitch / 2.0
            let sv = arc.vertical == .up ? 1.0 : -1.0
            let sh = arc.horizontal == .right ? 1.0 : -1.0
            let rc = 0.42 * min(pitch, h)
            let ax = mx, ay = my + sv * rc                     // vertical stub's end,
            let bx = mx + sh * rc, by = my                     // horiz stub's end --
                                                                // both ON the arc
            let c1x = ax, c1y = my + sv * rc * (1 - K)
            let c2x = mx + sh * rc * (1 - K), c2y = by
            let vFar = arc.vertical == .down ? yb : yb + h
            let hFar = arc.horizontal == .right ? x0 + pitch : x0
            ops.append(Array("\(fixedTwoDecimals(t)) w".utf8))
            ops.append(Array("\(pair(mx, vFar)) m".utf8))
            ops.append(Array("\(pair(ax, ay)) l".utf8))
            ops.append(Array("\(pair(c1x, c1y)) \(pair(c2x, c2y)) \(pair(bx, by)) c".utf8))
            ops.append(Array("\(pair(hFar, my)) l".utf8))
            ops.append(Array("S".utf8))
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

/// Break mixed text/graphics segments so each piece is all-one-kind. Segments with no
/// graphic character at all pass through whole. A font block is NOT required (2026-08-10,
/// job 187): a cp437 box/block glyph is geometry regardless of whether the run that carries
/// it has a WS5+ font block — Modern already draws a fontless graphic glyph at the em
/// advance (`modernTokenWidth`'s FONTLESS branch, `PDFModernLayout.swift`) for exactly this
/// reason ("'?' is nobody's take -- the geometry IS the glyph"), and Printed's own text path
/// has no cp1252 slot for these code points either, so a fontless run used to fall through
/// to `?`. Printed now takes the SAME vector path Modern already proved, for both fontless
/// and font-blocked runs — one implementation, not two. Port of `_split_graphics`.
func splitGraphics(_ segs: [LineSegment]) -> [LineSegment] {
    var out: [LineSegment] = []
    for seg in segs {
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

// ------------------------------------------------- cp437 Greek/math fallback
//
// cp1252 (Printed PDF's declared `/WinAnsiEncoding`, `esc`) carries none of the
// Greek/math repertoire cp437 puts at 0xE0-0xEE -- real WS7 prints this fine (measured:
// the -SCREEN.pcl + .measurements.json reference capture, the "αßΓπ..." line), because the driver
// routed those bytes through the Symbol PostScript font, not through the body face's own
// encoding. `pdfFamily` already recognises a WHOLE span's font block as `.symbol` (a real
// `.symbol`-typestyle font); this is the same face-bypass for the common case, PLAIN
// COURIER PROSE that happens to carry a handful of cp437 Greek/math bytes with no font
// block declaring Symbol at all. A character cp1252 cannot carry but `symbolReverse` can
// (the same Adobe Symbol repertoire the real `.math` path already writes) gets its own
// segment, face switched to Symbol and untransliterated to the face's own byte code --
// everything else in the run (including cp1252-representable look-alikes like micro sign
// / sharp-s, which are NOT this bug) stays on its own declared face untouched. Mirrors
// `splitGraphics`'s declared-font bypass for box glyphs exactly.
private func cp1252OK(_ ch: Character) -> Bool {
    guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
    return cp1252Byte(for: scalar) != nil
}

private func isSymbolFallbackChar(_ ch: Character) -> Bool {
    guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
    return symbolReverse[scalar.value] != nil
}

/// Break a `splitGraphics`-already-split segment further so any character cp1252 cannot
/// carry but Adobe Symbol can gets its own segment, face switched to Symbol and
/// untransliterated to that face's own byte code. Port of `_split_symbol_fallback`.
func splitSymbolFallback(_ segs: [LineSegment]) -> [LineSegment] {
    var out: [LineSegment] = []
    for seg in segs {
        if seg.family == .symbol || seg.family == .zapfDingbats || seg.text.isEmpty {
            // already on the real Symbol/Dingbats face (untransliterated face codes, not
            // Unicode -- nothing here could ever match), or empty -- nothing to split.
            out.append(seg)
            continue
        }
        let chars = Array(seg.text)
        if chars.allSatisfy(cp1252OK) {
            out.append(seg)                     // fast path: no fallback needed
            continue
        }
        func emit(_ piece: ArraySlice<Character>, isSymbol: Bool) {
            if isSymbol {
                out.append(LineSegment(text: untransliterate(String(piece), .math),
                                       styles: seg.styles, family: .symbol, size: seg.size,
                                       entry: seg.entry, indent: seg.indent,
                                       colour: seg.colour, pctlHMI: seg.pctlHMI,
                                       pcl: seg.pcl, tabHMI: seg.tabHMI,
                                       tabLeader: seg.tabLeader))
            } else {
                out.append(seg.withText(String(piece)))
            }
        }
        var runIsSymbol: Bool? = nil
        var bufStart = 0
        for (i, ch) in chars.enumerated() {
            let isSymbol = !cp1252OK(ch) && isSymbolFallbackChar(ch)
            if runIsSymbol == nil {
                runIsSymbol = isSymbol
            } else if isSymbol != runIsSymbol {
                emit(chars[bufStart..<i], isSymbol: runIsSymbol!)
                bufStart = i
                runIsSymbol = isSymbol
            }
        }
        emit(chars[bufStart...], isSymbol: runIsSymbol ?? false)
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

// ---- LJ6DTP parity C2: embedded PCL rectangles ------------------------------
//
// A 0x0F user print control's raw printer payload (`Document.pclPrograms`, indexed by a
// span's own `pcl`) is real PCL, not decoration. LJ6DTP.WS draws its page border (all 8
// pages) and page 4's checkerboard entirely this way; our engine drew neither, because
// the pctl branch in `lineOpsPrinted` only ever advanced `x` by the control's declared
// (zero) width and threw the bytes away. Scanning the whole file byte-for-byte found
// exactly four PCL forms in use — cursor push/pop, cursor position (absolute or relative
// per axis), and rectangle fill (solid, or a 4-parameter shaded form the initial
// inventory missed: `ESC*c<w>a<h>b<pct>g2P` draws the checkerboard's 15%/100% gray
// squares, not the plain `f=0` solid form the border uses). Nothing else appears;
// anything else is recorded as ignored rather than guessed at or failed on — this is NOT
// a general PCL interpreter.
//
// Position command grammar (HP PCL5): unsigned value = ABSOLUTE (from the printer's own
// page origin); a leading +/- = RELATIVE (added to wherever the cursor already is).
// `ESC*p<x>x<y>Y` sets both axes; `ESC*p<y>Y` (no `x` group) sets only the vertical —
// LJ6DTP's checkerboard uses both shapes in the same control. Ported from `pdf.py`'s
// `_parse_pcl_program`/`_pcl_rect_ops`, hand-rolled rather than regex-driven since this
// module deliberately imports nothing.

/// One tokenized PCL operation. Port of `_parse_pcl_program`'s own op tuples.
enum PCLOp: Hashable, Sendable {
    case push
    case pop
    /// A horizontal cursor move. `relative` mirrors Python's leading-sign test on the
    /// raw digits (`raw[:1] in (b'+', b'-')`), which is what separates PCL's absolute
    /// addressing from its relative form.
    case moveX(value: Int, relative: Bool)
    case moveY(value: Int, relative: Bool)
    /// A rectangle fill: size in PCL units (1/300in), plus the PDF fill gray it paints.
    case fill(w: Int, h: Int, gray: Double)
    /// An escape sequence matching none of the four recognised forms — recorded rather
    /// than raised or silently dropped, exactly the gap the original byte inventory fell
    /// into (it missed the shaded fill form entirely, having scanned only `b<f>P`).
    case ignored([UInt8])
}

/// HP LaserJet's own logical-page registration (measured against gpcl6's render of the
/// genuine WS7 PCL output at 300dpi — 1 PCL unit per pixel there): absolute PCL x=2 lands
/// at pixel column 77 (2+75), x=2369 at 2444 (2369+75) — a flat +75-unit (0.25in) offset
/// on X across both the left and right border rules. Y needs NONE: PCL y=85 lands at
/// pixel row 85 exactly, and y=3202 at row 3202. This is the printer's own
/// unprintable-area registration, not a WordStar margin — raw PCL bypasses WordStar's own
/// cursor/margin machinery and addresses the physical page directly.
let pclAbsXOffsetUnits = 75
let pclAbsYOffsetUnits = 0
/// PCL unit (1/300in) -> point, exact.
let pclUnitPt = 72.0 / 300.0

/// Digits at `i`, with an optional leading sign. `nil` when there is no digit there.
private func pclSignedInt(_ data: [UInt8], _ i: Int) -> (value: Int, relative: Bool, end: Int)? {
    var j = i
    var relative = false
    var negative = false
    if j < data.count, data[j] == UInt8(ascii: "+") || data[j] == UInt8(ascii: "-") {
        relative = true
        negative = data[j] == UInt8(ascii: "-")
        j += 1
    }
    let digitsStart = j
    var value = 0
    while j < data.count, data[j] >= 0x30, data[j] <= 0x39 {
        value = value * 10 + Int(data[j] - 0x30)
        j += 1
    }
    guard j > digitsStart else { return nil }
    return (negative ? -value : value, relative, j)
}

/// Tokenize one 0x0F control's raw printer payload into the small, explicit op list this
/// document's PCL actually uses. Port of `_parse_pcl_program`.
func parsePCLProgram(_ data: [UInt8]) -> [PCLOp] {
    var ops: [PCLOp] = []
    var i = 0
    let n = data.count
    func lit(_ at: Int, _ s: String) -> Bool {
        let want = Array(s.utf8)
        guard at + want.count <= n else { return false }
        for (k, b) in want.enumerated() where data[at + k] != b { return false }
        return true
    }
    while i < n {
        if lit(i, "\u{1B}&f0S") { ops.append(.push); i += 5; continue }
        if lit(i, "\u{1B}&f1S") { ops.append(.pop); i += 5; continue }
        if lit(i, "\u{1B}*p") {
            // `(?:([+-]?\d+)x)?([+-]?\d+)Y` — the x group first, backtracking to the
            // vertical-only form when the digits at this position are not followed by
            // a lowercase 'x', exactly as the regex does.
            var j = i + 3
            var xPart: (value: Int, relative: Bool)? = nil
            if let first = pclSignedInt(data, j), first.end < n,
               data[first.end] == UInt8(ascii: "x") {
                xPart = (first.value, first.relative)
                j = first.end + 1
            }
            if let second = pclSignedInt(data, j), second.end < n,
               data[second.end] == UInt8(ascii: "Y") {
                if let x = xPart { ops.append(.moveX(value: x.value, relative: x.relative)) }
                ops.append(.moveY(value: second.value, relative: second.relative))
                i = second.end + 1
                continue
            }
        }
        if lit(i, "\u{1B}*c") {
            // `(\d+)a(\d+)b(\d+)(?:g(\d+))?P` — UNSIGNED throughout.
            var j = i + 3
            var fields: [Int] = []
            var ok = true
            for terminator in [UInt8(ascii: "a"), UInt8(ascii: "b")] {
                guard let f = pclSignedInt(data, j), !f.relative, f.end < n,
                      data[f.end] == terminator else { ok = false; break }
                fields.append(f.value)
                j = f.end + 1
            }
            if ok, let f = pclSignedInt(data, j), !f.relative, f.end < n {
                fields.append(f.value)
                j = f.end
                var shade: Int? = nil
                if data[j] == UInt8(ascii: "g"), let g = pclSignedInt(data, j + 1),
                   !g.relative, g.end < n, data[g.end] == UInt8(ascii: "P") {
                    shade = g.value
                    j = g.end
                }
                if data[j] == UInt8(ascii: "P") {
                    let w = fields[0], h = fields[1], f0 = fields[2]
                    if shade != nil {
                        // Shading pattern: `f` here is the ink PERCENTAGE (0-100), not a
                        // fill-type code — 100% reads as solid black, same as fill type 0.
                        ops.append(.fill(w: w, h: h, gray: 1.0 - Double(f0) / 100.0))
                    } else if f0 == 0 {
                        // Solid black — the only plain fill type this document ever sends.
                        ops.append(.fill(w: w, h: h, gray: 0.0))
                    } else {
                        ops.append(.ignored(Array(data[i...j])))
                    }
                    i = j + 1
                    continue
                }
            }
        }
        if data[i] == 0x1B {
            var j = i + 1
            while j < n, data[j] != 0x1B { j += 1 }
            ops.append(.ignored(Array(data[i..<j])))
            i = j
        } else {
            i += 1
        }
    }
    return ops
}

/// Execute one parsed PCL program, anchored at `(anchorX, anchorY)` — the PDF page
/// position (points, PDF's own bottom-up frame) wherever the running text cursor already
/// is. Returns PDF content-stream ops for every fill, restoring `restoreGray` afterward
/// so later text on the same line is unaffected. Port of `_pcl_rect_ops`.
///
/// The cursor is tracked in POINTS throughout (the PCL-unit -> point factor, 72/300 =
/// 0.24, is exact, so there is no precision cost to converting each move immediately
/// rather than accumulating in PCL units).
///
/// An ABSOLUTE move (unsigned) jumps to this document's own PCL page origin — the anchor
/// is irrelevant to it, exactly as real absolute cursor addressing ignores wherever the
/// print head happens to be. This is the page BORDER's whole program: it never reads the
/// anchor at all. A RELATIVE move (signed) adds to whatever position is already current —
/// which for a program that opens with a push (LJ6DTP's checkerboard controls) IS the
/// anchor: the print position the control sits at inline in the running text, since its
/// own HMI word is 0 (zero character advance) -- ALREADY CORRECTED into this printer's
/// own raw-PCL frame by the caller (register b31): `lineOpsPrinted` hands this function
/// `x + pclAbsXOffsetUnits * pclUnitPt` (and the Y equivalent), the SAME registration
/// constant the absolute branch below applies, since a relative program's raw PCL
/// addresses the physical page exactly as an absolute one does -- only the STARTING
/// point differs. Passing a raw, uncorrected anchor here would land every relative fill
/// 0.25in left of where gpcl6 actually draws it (measured against LJ6DTP-p4.png's
/// checkerboard, board left/centre 2.750in/4.123in).
func pclRectOps(_ progOps: [PCLOp], anchorX: Double, anchorY: Double,
                pageHeight: Double, restoreGray: Double) -> [[UInt8]] {
    var ops: [[UInt8]] = []
    var curX = anchorX
    var curY = anchorY
    var stack: [(Double, Double)] = []
    var gray = restoreGray

    func setGray(_ g: Double) {
        if g != gray {
            ops.append(Array("\(fixedTwoDecimals(g)) g".utf8))
            gray = g
        }
    }

    for op in progOps {
        switch op {
        case .push:
            stack.append((curX, curY))
        case .pop:
            if let top = stack.popLast() { curX = top.0; curY = top.1 }
        case .moveX(let value, let relative):
            if relative {
                curX += Double(value) * pclUnitPt
            } else {
                curX = Double(value + pclAbsXOffsetUnits) * pclUnitPt
            }
        case .moveY(let value, let relative):
            if relative {
                curY -= Double(value) * pclUnitPt
            } else {
                curY = pageHeight - Double(value + pclAbsYOffsetUnits) * pclUnitPt
            }
        case .fill(let wUnits, let hUnits, let fillGray):
            // A 0-size fill draws nothing on a real printer either.
            if wUnits != 0, hUnits != 0 {
                let wPt = Double(wUnits) * pclUnitPt
                let hPt = Double(hUnits) * pclUnitPt
                setGray(fillGray)
                ops.append(Array(("\(fixedTwoDecimals(curX)) \(fixedTwoDecimals(curY - hPt)) "
                                + "\(fixedTwoDecimals(wPt)) \(fixedTwoDecimals(hPt)) re f").utf8))
            }
        case .ignored:
            break                            // nothing to draw, cursor unchanged
        }
    }
    setGray(restoreGray)
    return ops
}
