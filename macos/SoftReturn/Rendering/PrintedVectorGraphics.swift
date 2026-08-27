import AppKit

/// job-489 (C1): the `Int` LJ6DTP HP1-HP6 pattern-colour index (9-14) a span's
/// `.foregroundColor` resolved to, set alongside it by `DocumentRenderer.attributedRun` so
/// `graphicCells` below can recover which of the six hatches a colour-driven glyph fill wants
/// without decoding it back out of the `NSColor` itself. Absent for plain black/gray text.
extension NSAttributedString.Key {
    static let lj6dtpPatternIndex = NSAttributedString.Key("SoftReturn.lj6dtpPatternIndex")
    /// Register b31 (job 506, E2): `true` when a span's `.foregroundColor` resolved from a
    /// driver colour1-7 index (`DocumentRenderer.driverColourAttributes`) — the same
    /// `(1...7).contains(colour)` gate the engine's own `lineOpsPrinted` uses to decide
    /// `wantDarken` (`PDFWriter.swift`, b31 register E2: colour1-7 fills composite with
    /// Darken so an overprinted gray shadow never lightens black ink already on the page;
    /// colour15/white knockouts and plain colourless black text never get it). Absent for
    /// those, exactly like `.lj6dtpPatternIndex` above is absent for plain text.
    static let lj6dtpDarkenColour = NSAttributedString.Key("SoftReturn.lj6dtpDarkenColour")
}

/// Job 211 (b11 leg 3b): cp437 box/shade/block glyphs drawn as vector fills — the visible
/// core of Jon's "massively screwed up" LJ6DTP field report. Job 210's own before-table: the
/// engine draws these as `re f` PDF ops (LJ6DTP.WS page 7 alone: 4208 of them); the app drew
/// none. Also affects BOXES.WS/FORMFEED.WS/OLDTIMES.WS/SCRIPT.WS/WORDSTAR.WS.
///
/// Port of `graphicOps`'s GEOMETRY (`PDFDriverLJ6DTP.swift:120-165`), not its PDF byte
/// emission — same "parallel port, not a call" discipline as `DocumentRenderer`'s
/// `printedLJ6DTPColourGray`/`resolvedFont` (both `internal` to `CtrlKD`, so this app target
/// cannot call them directly).
///
/// Positioned against THIS PAGE'S REAL AppKit line-fragment/glyph geometry
/// (`NSLayoutManager.location(forGlyphAt:)` — the SAME technique
/// `PrintedStructuralParityTests`' own `Oracle.structuralBodyLines` already uses and proves
/// accurate to 0.5pt against the engine) rather than a `DocumentRenderer`-side precomputed Y.
/// Job 210's own scoping note on why: a precomputed Y would re-derive the isolated-vs-
/// embedded measurement disagreement job 202 documented (`DocumentRenderer.swift`'s
/// `measuredHeight` doc comment). `PageTextView.draw(_:)` calls `graphicCells` to paint; the
/// structural-parity harness calls the SAME function (via `Oracle`'s real laid-out pages) to
/// count — one derivation, not two that can silently drift apart, exactly the failure mode
/// `PrintedStructuralParityTests.swift`'s own top doc comment warns against.
///
/// No horizontal pitch/HMI math is ported at all: `spanPitch`/`hmiPerPoint` are both
/// `internal` to `CtrlKD`, and the app already has something better than a second guess at
/// what they'd compute — AppKit's own real glyph advance for the exact font it already chose
/// (`DocumentRenderer.resolvedFont`), which by construction can never disagree with what this
/// page's other glyphs are doing.

/// One vector fill's exact silhouette, in the app's container-local coordinate system (the
/// same space `usedRect`/`softLineFlags` already draw in). Port of `graphicOps`'s two draw
/// primitives, `rect`/`disc` (`PDFDriverLJ6DTP.swift:188-204`), plus a straight-edged closed
/// path for `symbolShapes`' `.poly` sub-shape (`m`/`l`/`h f`, `PDFDriverLJ6DTP.swift:227-233`
/// — no curve data to port there, every polygon vertex is a straight line to the next).
/// Job 402: was `CGRect` alone until `symbolShapes`' disc/polygon sub-shapes needed a real
/// non-rectangular fill — every existing `boxArms`/`shadeGray`/`partBlocks`/`fullBlock` caller
/// still produces exactly the `.rect` case it always did.
enum GraphicShape {
    case rect(CGRect)
    case disc(center: CGPoint, radius: CGFloat)
    case poly([CGPoint])

    /// The smallest rect enclosing this shape — every caller that only needs "where did this
    /// land," not "what shape" (erase framing, the harness's own vector-op bounding boxes),
    /// used a plain `CGRect` exclusively before job 402 and still can.
    var boundingBox: CGRect {
        switch self {
        case .rect(let r): return r
        case .disc(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .poly(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> GraphicShape {
        switch self {
        case .rect(let r): return .rect(r.offsetBy(dx: dx, dy: dy))
        case .disc(let center, let radius):
            return .disc(center: CGPoint(x: center.x + dx, y: center.y + dy), radius: radius)
        case .poly(let points):
            return .poly(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        }
    }

    /// Fills this shape's own silhouette into the current graphics context.
    func fill() {
        switch self {
        case .rect(let r):
            r.fill()
        case .disc(let center, let radius):
            let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            NSBezierPath(ovalIn: box).fill()
        case .poly(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            path.close()
            path.fill()
        }
    }
}

/// One vector fill, in the app's container-local coordinate system (the same space
/// `usedRect`/`softLineFlags` already draw in — no further offset math needed to paint it).
struct GraphicRect {
    let shape: GraphicShape
    /// Fill gray: 0 black, 1 white — see `colourGrayLJ6DTP`, `PDFDriverLJ6DTP.swift:15-19`.
    let gray: CGFloat
    /// job-489 (C1): the LJ6DTP HP1-HP6 tiling-pattern colour index (9-14, `driverColour`'s
    /// own doc comment) this fill's colour resolved to, or `nil` for an ordinary flat-gray
    /// fill. When set, `fill()` paints `LJ6DTPPattern.tileImage(for:)` instead of `gray` —
    /// see that type's own doc comment for why a real tiled hatch, not another flat
    /// approximation, is what this index means.
    var pattern: Int? = nil

    /// Bounding box — every caller before job 402 read `.frame` directly as the fill's own
    /// geometry (always true for `boxArms`/`shadeGray`/`partBlocks`/`fullBlock`, still a plain
    /// `.rect` case); kept as the SAME accessor so those callers (and the harness's own
    /// count-comparison geometry) need no changes.
    var frame: CGRect { shape.boundingBox }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> GraphicRect {
        GraphicRect(shape: shape.offsetBy(dx: dx, dy: dy), gray: gray, pattern: pattern)
    }

    /// Sets its own fill colour (flat gray, or a tiled HP pattern) rather than trusting the
    /// caller to have set one first — job-489 centralised this here so every one of this
    /// file's several draw call sites (`PagedDocumentView.swift`) automatically gets pattern
    /// support with no per-call-site branching.
    func fill() {
        if let pattern {
            NSColor(patternImage: LJ6DTPPattern.tileImage(for: pattern)).setFill()
        } else {
            NSColor(white: gray, alpha: 1).setFill()
        }
        shape.fill()
    }
}

/// job-489 (C1 — "Pattern fills are FLATTENED TO GREY"): the LJ6DTP driver's HP1-HP6 tiling
/// patterns, rendered as real hatch geometry instead of `printedLJ6DTPColourGray`'s flat
/// approximation. Port of the engine's `lj6dtpHPPatterns`
/// (`CtrlKD/PDFDriverLJ6DTP.swift:43-50`) — same six directional strokes (horizontal,
/// vertical, two diagonals, crosshatch, dense X), hand-transcribed rather than run through a
/// PDF-content-stream mini-interpreter (six entries, not worth a parser this file has never
/// needed elsewhere). The engine builds a real PDF `/Pattern` object; AppKit has no such
/// primitive, so this builds an `NSImage` tile of the SAME cell size and strokes and hands it
/// to `NSColor(patternImage:)`, which tiles it exactly the way a PDF tiling pattern would —
/// same mechanism, different host API. `NSImage`'s own default coordinate system (via
/// `lockFocus`) is y-up, matching the PDF pattern-space authoring below — but every call site
/// that paints one of these (`PagedDocumentView.swift`) draws into a view with `isFlipped ==
/// true`, and AppKit ties an `NSColor(patternImage:)` fill to the destination's UNFLIPPED base
/// space rather than the current (flipped) one, so the tile paints back mirrored top-to-bottom.
/// Job 505: `tileImage(for:)` below pre-flips each line's own y (within its own tile height) to
/// cancel that out. Symmetric strokes (HP1 horizontal, HP2 vertical, HP5's +, HP6's X) are
/// invisibly affected either way; HP3/HP4's diagonals were the one pair a top-to-bottom mirror
/// actually swaps ("/" <-> "\") — exactly the field report (LJ6DTP.WS page 5: engine HP3 is
/// "/", app rendered it "\", and vice versa for HP4).
enum LJ6DTPPattern {
    private struct Spec {
        let w: CGFloat
        let h: CGFloat
        let lines: [(from: CGPoint, to: CGPoint, width: CGFloat)]
    }
    // Port of `lj6dtpHPPatterns`' six `(w, h, content)` entries — content ops transcribed
    // directly (`m`/`l`/`S` -> a stroked line segment, `w` -> its line width).
    private static let specs: [Int: Spec] = [
        9:  Spec(w: 300, h: 4,   lines: [(CGPoint(x: 0, y: 0.5), CGPoint(x: 300, y: 0.5), 1)]),        // HP1 horizontal
        10: Spec(w: 3,   h: 300, lines: [(CGPoint(x: 1.5, y: 0), CGPoint(x: 1.5, y: 300), 1)]),        // HP2 vertical
        11: Spec(w: 6,   h: 6,   lines: [(CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 6), 0.8)]),             // HP3 diagonal /
        12: Spec(w: 6,   h: 6,   lines: [(CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 0), 0.8)]),             // HP4 diagonal \
        13: Spec(w: 6,   h: 6,   lines: [(CGPoint(x: 0, y: 3), CGPoint(x: 6, y: 3), 0.8),
                                          (CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 6), 0.8)]),             // HP5 crosshatch +
        14: Spec(w: 4,   h: 4,   lines: [(CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 4), 0.7),
                                          (CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 0), 0.7)]),             // HP6 dense X
    ]
    nonisolated(unsafe) private static var cache: [Int: NSImage] = [:]

    static func tileImage(for index: Int) -> NSImage {
        if let cached = cache[index] { return cached }
        let spec = specs[index] ?? Spec(w: 1, h: 1, lines: [])
        let image = NSImage(size: CGSize(width: spec.w, height: spec.h))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: spec.w, height: spec.h).fill()
        NSColor.black.setStroke()
        for line in spec.lines {
            let path = NSBezierPath()
            path.lineWidth = line.width
            // Pre-flip y (within this tile's own height) — see this type's doc comment:
            // cancels the top-to-bottom mirror `NSColor(patternImage:)` applies when painted
            // into a flipped view, which every call site here is.
            path.move(to: CGPoint(x: line.from.x, y: spec.h - line.from.y))
            path.line(to: CGPoint(x: line.to.x, y: spec.h - line.to.y))
            path.stroke()
        }
        image.unlockFocus()
        cache[index] = image
        return image
    }
}

/// One graphic character's footprint. `eraseFrame` blanks the placeholder glyph AppKit
/// already drew there — no base-14 font carries a `─`/`█` glyph, so the ordinary text path
/// degrades every one of these to a missing-glyph box (this file's own top doc comment on
/// `graphicChars` below cites the same fact on the engine side). `fills` are the actual
/// vector ops for that character, drawn on top of the erasure.
struct GraphicCell {
    let eraseFrame: CGRect
    let fills: [GraphicRect]
}

// Job 211 (b11 leg 3b) shipped a `.printedGraphicsEligible` `NSAttributedString.Key`
// here, gating `graphicCells` below on whether a run's underlying `Span` carried a WS5+
// font block (`span.font` resolves against `doc.fonts`) — believing that was the SAME
// gate the engine's own `splitGraphics` applies (`PDFDriverLJ6DTP.swift`'s own `guard
// seg.entry != nil else`). Job 404 (task #62, Class 7 fontless residual): that guard
// does not exist. `splitGraphics` (`PDFDriverLJ6DTP.swift:315-336`) and `lineOpsPrinted`
// (`PDFWriter.swift:545`, the actual op-emitting gate: `if seg.text.contains(where: {
// graphicChars.contains($0) })`) both test ONLY character-set membership — `seg.entry`
// is read later, in the SAME branch, purely to pick a pitch (`spanPitch(seg.entry, pt)`
// vs. the proportional `Double(pt)`), never to exclude a fontless span from drawing as a
// vector fill at all. CP437 decoding is UNIVERSAL (`CP437.swift`'s own top doc comment)
// regardless of any font block being in force, so there was never an ambiguity for a
// font-block flag to resolve: every `graphicChars` character the parser hands back,
// fontless or not, is graphics. The flag (and the fontless spans it wrongly excluded —
// diagnosed exact on `BOX.WS`/`BOXES.WS`, job 403) is removed; `graphicCells` below now
// mirrors the engine's own single-condition gate exactly.

/// Arms per glyph: (up, down, left, right); 0 none, 1 single, 2 double. Port of `boxArms`
/// (`PDFDriverLJ6DTP.swift:83-103`).
private let boxArms: [Character: (up: Int, down: Int, left: Int, right: Int)] = [
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
/// Shades: ink coverage -> fill gray (1 = white paper). Port of `shadeGray`
/// (`PDFDriverLJ6DTP.swift:105-107`) — applied regardless of driver, same as the engine's own
/// unconditional `q gray g ... Q` wrap around a shade rect (`graphicOps`'s own `rect` calls).
private let shadeGray: [Character: Double] = [
    "\u{2591}": 0.75, "\u{2592}": 0.50, "\u{2593}": 0.25,
]
/// Partial blocks: (x-frac, y-frac, w-frac, h-frac) of the cell, y measured from the cell's
/// OWN bottom upward (PDF convention) — see `graphicCells`' conversion to this file's
/// top-down cell math. Port of `partBlocks` (`PDFDriverLJ6DTP.swift:109-115`).
// Was `private` — widened the same way `graphicChars` below already was (job 229's own
// comment on this file), so `SquareBulletPortTests` can compare these fractions directly
// against `CtrlKD`'s own `partBlocks`/`squarePartBlocks` instead of only through rendered
// pixel geometry.
let partBlocks: [Character: (x: Double, y: Double, w: Double, h: Double)] = [
    "\u{2580}": (0, 0.5, 1, 0.5), "\u{2584}": (0, 0, 1, 0.5),
    "\u{258C}": (0, 0, 0.5, 1), "\u{2590}": (0.5, 0, 0.5, 1),
    // cp437 0xFE, the PC-8 black square (Sawyer's -README list markers): a TRUE square
    // (fw == fh), meaningful now that `squarePartBlocks` scales both axes by the same
    // `sq = min(pitch, cellHeight)` reference. Port of engine commit 9a4dff2 (b24 round 20,
    // slate item 8) — the old (0.12, 0.18, 0.72, 0.55) pair was tuned by eye against the
    // un-squared (pitch-for-x, cellHeight-for-y independently) rendering and came out
    // visibly taller than wide.
    "\u{25A0}": (0.175, 0.175, 0.65, 0.65),
]
/// ▀▄▌▐ are genuinely CELL-shaped — only ■ is authored to look like a regular, roughly-square
/// dot, so only it gets the square-cell correction `symbolShapes` already applies. Port of
/// engine's `SQUARE_PART_BLOCKS` (commit 9a4dff2).
let squarePartBlocks: Set<Character> = ["\u{25A0}"]
private let fullBlockChar: Character = "\u{2588}"

/// cp437 control-position symbol glyphs (card suits, smiley, sun, triple bar). Port of
/// `SYMBOL_SHAPES`/`SymbolSubShape` (`PDFDriverLJ6DTP.swift:131-173`, Jon's ruling,
/// 2026-08-11: "the card suits, etc. show up everywhere"). Latin-1 has none of them, so the
/// text path degraded all seven to '?'; like the box set, they are geometry — each entry is a
/// list of filled sub-shapes in CELL FRACTIONS (x up-right, y up from the cell's own bottom,
/// PDF convention, matching the engine's own authoring). `.white` wraps a sub-shape drawn
/// paper-white (knockout). Job 211 (b11 leg 3b, job 402 follow-up): this table was the ONE
/// `graphicChars` set the app never ported — see this file's top doc comment and
/// `PrintedStructuralParityTests.swift`'s Class 7 citation for the field evidence
/// (LJ6DTP.WS pages 3/6/7's own symbol-substitution tables).
indirect enum SymbolSubShape: Sendable {
    case poly([(x: Double, y: Double)])
    case disc(x: Double, y: Double, r: Double)
    case rect(x: Double, y: Double, w: Double, h: Double)
    case white(SymbolSubShape)
}
let symbolShapes: [Character: [SymbolSubShape]] = [
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

/// Port of `graphicChars` (`PDFDriverLJ6DTP.swift:117-118`/`:175-177`). Was `internal` rather
/// than `private` so job 229's now-removed `printedWordAnchoredRun` (job 240, b13 Part 2: AFM
/// word-anchoring is gone — MAC VIEWING RULING) could exclude these cp437 graphic glyphs
/// from its corrective-kern pass; left at its current access level rather than narrowed,
/// since narrowing it is unrelated cleanup outside this job's scope.
let graphicChars: Set<Character> =
    Set([fullBlockChar]).union(boxArms.keys).union(shadeGray.keys).union(partBlocks.keys)
        .union(symbolShapes.keys)

/// Vector fills for every eligible cp437 glyph in `glyphRange`, one line fragment's worth.
///
/// `fragment` is that fragment's own `CGRect` (`NSLayoutManager.lineFragmentRect(forGlyphAt
/// :effectiveRange:)`, or the first parameter `enumerateLineFragments` already hands its
/// block) — NOT `usedRect`. This matches the established, harness-proven convention
/// `PrintedStructuralParityTests`' own `Oracle.structuralBodyLines`/`EngineTruth` extraction
/// already uses for body-line X/baseline (`fragment.origin.x/.y` + `location(forGlyphAt:)`),
/// which that harness independently confirms lands within 0.5pt of the engine's real PDF
/// bytes — reusing it here means this geometry inherits that same proof instead of needing
/// its own.
@MainActor
func graphicCells(
    manager: NSLayoutManager, storage: NSTextStorage, glyphRange: NSRange, fragment: CGRect
) -> [GraphicCell] {
    guard glyphRange.length > 0 else { return [] }
    var cells: [GraphicCell] = []
    let text = storage.string as NSString
    let lineEnd = glyphRange.location + glyphRange.length
    var g = glyphRange.location
    while g < lineEnd {
        defer { g += 1 }
        let charIndex = manager.characterIndexForGlyph(at: g)
        guard charIndex < text.length else { continue }
        guard let scalar = Unicode.Scalar(text.character(at: charIndex)) else { continue }
        let ch = Character(scalar)
        guard graphicChars.contains(ch) else { continue }

        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)

        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        let pt = Double(font.pointSize)
        let loc = manager.location(forGlyphAt: g)
        let x0 = fragment.origin.x + loc.x
        let baselineY = fragment.origin.y + loc.y
        let pitch = Double(graphicAdvance(manager: manager, glyphIndex: g, lineEnd: lineEnd,
                                          fallback: font.maximumAdvancement.width))
        // job-489 (C1): the driver-colour index this run's `.foregroundColor` resolved to,
        // when it's one of the HP1-HP6 pattern indices (`DocumentRenderer.driverColour`'s own
        // doc comment) — `.foregroundColor` alone can't be decoded back into which of the six
        // hatches it is (`NSColor(patternImage:)` carries no such metadata), so the index
        // travels alongside it as its own attribute instead.
        let patternIndex = attrs[.lj6dtpPatternIndex] as? Int
        // A pattern `NSColor(patternImage:)` has no `.deviceGray` conversion (`usingColorSpace`
        // returns nil for it), so `color` falls back to a nominal 0.5 for one of these runs —
        // this is ONLY the `GraphicRect.gray` fallback `.fill()` would use if `pattern` were
        // ever nil (never true for one of these fills; `pattern` always drives the real paint),
        // kept meaningful anyway because other harnesses (`PrintedStructuralParityTests`'
        // `knockoutTextPaintsVisibleInkOverItsFill`, job 399) probe `GraphicRect.gray` directly
        // as a "is this a driver-fill box" signal — the SAME flat value `printedLJ6DTPColourGray`
        // used for these indices before this job, so that probe's own range check is unaffected.
        let color = patternIndex != nil ? 0.5 : ((attrs[.foregroundColor] as? NSColor)?
            .usingColorSpace(.deviceGray)?.whiteComponent ?? 0)

        // The cp437 cell, in this view's top-down (flipped) local coordinates. `graphicOps`
        // builds its cell in PDF bottom-up coordinates from the glyph's baseline `y`:
        // `yb = y - 0.25*pt` (cell bottom, BELOW baseline), `h = 1.1*pt` (cell height),
        // `my = yb + h/2` (vertical center). Flipping to top-down negates every offset
        // FROM the baseline (above-baseline becomes smaller y, not larger), so the cell's
        // top sits `0.85*pt` ABOVE `baselineY` (`h - 0.25*pt`, i.e. `-yb-h` flipped), its
        // bottom `0.25*pt` BELOW it (`-yb` flipped), and its center `0.3*pt` above it
        // (`-my` flipped, i.e. `h/2 - 0.25*pt`).
        let cellTop = baselineY - 0.85 * pt
        let cellMidY = baselineY - 0.3 * pt
        let cellBottom = baselineY + 0.25 * pt
        let cellHeight = 1.1 * pt
        let t = max(0.5, pt / 12)                   // line weight, port of graphicOps' `t`
        let d = pt / 10                              // double-line half-gap, port of `d`

        var fills: [GraphicRect] = []
        func addRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, gray: Double, pattern: Int? = nil) {
            fills.append(GraphicRect(
                shape: .rect(CGRect(x: x, y: y, width: w, height: h)), gray: CGFloat(gray), pattern: pattern))
        }
        // job-489 (C1): `color`-driven fills (the driver-colour foreground, not the
        // char-intrinsic `shadeGray`/knockout-white values) carry `patternIndex` through;
        // `pattern` stays nil for those so this closure is a drop-in default everywhere else.
        let colorPattern = patternIndex

        if let shapes = symbolShapes[ch] {
            // `sq`: the SAME single square scale `graphicOps`' own `symbolShape` uses for
            // every sub-shape kind (`PDFDriverLJ6DTP.swift:219`'s `sq = min(pitch, h)`, b24
            // round 20/slate item 8) — a symbol glyph is authored to look REGULAR (a round
            // dot, a true diamond, a circular sun), not squashed to the cell's own pitch/height
            // aspect the way a box-drawing arm or half-block legitimately is.
            let sq = min(pitch, cellHeight)
            let cx = x0 + pitch / 2
            // Fraction (fx, fy) is PDF-convention (`fy` up from the cell's own bottom, same as
            // `graphicOps`' authoring) around the cell CENTER — `cellMidY` is this view's own
            // flipped-coordinate stand-in for `graphicOps`' `my`/`cy` (both `yb + h/2`, this
            // file's own top-of-loop doc comment on why `cellMidY` already equals that,
            // flipped). Mapping a fraction the flipped way SUBTRACTS its center-relative
            // offset instead of adding it (this view's y grows DOWN the page; PDF's grows UP),
            // matching the existing `boxArms` branch's own up/down cellTop/cellBottom split
            // just below.
            func addSymbolShape(_ shape: SymbolSubShape, gray: Double, pattern: Int? = nil) {
                switch shape {
                case .white(let sub):
                    addSymbolShape(sub, gray: 1.0)
                case .poly(let points):
                    let mapped = points.map {
                        CGPoint(x: cx + ($0.x - 0.5) * sq, y: cellMidY - ($0.y - 0.5) * sq)
                    }
                    fills.append(GraphicRect(shape: .poly(mapped), gray: CGFloat(gray), pattern: pattern))
                case .disc(let fx, let fy, let fr):
                    let center = CGPoint(x: cx + (fx - 0.5) * sq, y: cellMidY - (fy - 0.5) * sq)
                    fills.append(GraphicRect(
                        shape: .disc(center: center, radius: fr * sq), gray: CGFloat(gray), pattern: pattern))
                case .rect(let fx, let fy, let fw, let fh):
                    // `(fx, fy)` is the sub-rect's own bottom-left corner in PDF convention
                    // (`graphicOps`' `rect` draws upward from `ry`), so its TOP (this view's
                    // smaller-y edge) sits at `fy + fh`, not `fy` alone.
                    let origin = CGPoint(x: cx + (fx - 0.5) * sq, y: cellMidY - (fy + fh - 0.5) * sq)
                    let size = CGSize(width: fw * sq, height: fh * sq)
                    fills.append(GraphicRect(
                        shape: .rect(CGRect(origin: origin, size: size)), gray: CGFloat(gray), pattern: pattern))
                }
            }
            for shape in shapes { addSymbolShape(shape, gray: color, pattern: colorPattern) }
        } else if ch == fullBlockChar {
            addRect(x0, cellTop, pitch, cellHeight, gray: color, pattern: colorPattern)
        } else if let gray = shadeGray[ch] {
            addRect(x0, cellTop, pitch, cellHeight, gray: gray)
        } else if let frac = partBlocks[ch] {
            if squarePartBlocks.contains(ch) {
                // Same cell-center-relative, single-scale mapping as the `symbolShapes` rect
                // case above (`sq = min(pitch, cellHeight)`), so ■ is a true square instead of
                // being stretched independently to the cell's pitch (x) and height (y).
                let sq = min(pitch, cellHeight)
                let cx = x0 + pitch / 2
                let originX = cx + (frac.x - 0.5) * sq
                let originY = cellMidY - (frac.y + frac.h - 0.5) * sq
                addRect(originX, originY, frac.w * sq, frac.h * sq, gray: color, pattern: colorPattern)
            } else {
                let originY = baselineY + 0.25 * pt - (frac.y + frac.h) * 1.1 * pt
                addRect(x0 + frac.x * pitch, originY, frac.w * pitch, frac.h * 1.1 * pt, gray: color, pattern: colorPattern)
            }
        } else if let arms = boxArms[ch] {
            let mx = x0 + pitch / 2
            for (weight, xa, xb) in [(arms.left, x0, mx), (arms.right, mx, x0 + pitch)] {
                if weight == 1 {
                    addRect(xa, cellMidY - t / 2, xb - xa, t, gray: color, pattern: colorPattern)
                } else if weight == 2 {
                    addRect(xa, cellMidY - d - t / 2, xb - xa, t, gray: color, pattern: colorPattern)
                    addRect(xa, cellMidY + d - t / 2, xb - xa, t, gray: color, pattern: colorPattern)
                }
            }
            for (weight, ya, yc) in [(arms.up, cellTop, cellMidY), (arms.down, cellMidY, cellBottom)] {
                if weight == 1 {
                    addRect(mx - t / 2, ya, t, yc - ya, gray: color, pattern: colorPattern)
                } else if weight == 2 {
                    addRect(mx - d - t / 2, ya, t, yc - ya, gray: color, pattern: colorPattern)
                    addRect(mx + d - t / 2, ya, t, yc - ya, gray: color, pattern: colorPattern)
                }
            }
        }

        // Job 269 (p6-punchout): THIS GLYPH's own `cellTop`/`cellHeight`, not the caller's
        // `fragment.origin.y`/`fragment.height` — the fragment figure is the WHOLE line
        // fragment's height, which on a uniform-font line happens to be close to one
        // glyph's own cell (why this shipped fine for years), but on a MIXED-size line —
        // LJ6DTP.WS's "PRETTY NEAT, HUH?" `.overprint` pass chains an unshrunk 12pt leading-
        // space span against its own `.sup`-flagged block-char span shrunk to 8pt
        // (`DocumentRenderer.attributedRun`'s job 246 fix: a graphic `.sup` run shrinks in
        // place, on the shared baseline, never rises) — `fragment.height` there is the
        // UNSHRUNK sibling's 14pt natural line height, erasing a taller white rectangle than
        // the shrunk glyph's own ~8.8pt fill re-covers and carving a white gap straight
        // through whatever solid fill an EARLIER-drawn layer (the chain's own base bar)
        // already painted at that same X. `cellTop`/`cellHeight` are this glyph's own
        // baseline-relative box — already sized generously enough to cover AppKit's missing-
        // glyph placeholder for a font of this exact size (every other cp437 fill on this
        // page uses the identical figure), so erase and fill now always agree by
        // construction, for every char kind, not just the ones this fixture exercises.
        let eraseFrame = CGRect(x: x0, y: cellTop, width: pitch, height: cellHeight)
        cells.append(GraphicCell(eraseFrame: eraseFrame, fills: fills))
    }
    return cells
}

/// This glyph's own horizontal advance: the delta to the next glyph on the SAME line, when
/// that glyph is really shown (skips a line-final control glyph — e.g. the newline
/// terminator every `DocumentRenderer` line ends with — whose own location is not a real
/// character cell and would under-measure the last visible glyph's width). Falls back to
/// `NSFont.maximumAdvancement`, exact for the monospace faces cp437 box art always uses
/// (`printedFontFamily`'s `printedMonoFamilies` gate, `DocumentRenderer.swift`).
private func graphicAdvance(
    manager: NSLayoutManager, glyphIndex: Int, lineEnd: Int, fallback: CGFloat
) -> CGFloat {
    let next = glyphIndex + 1
    guard next < lineEnd, !manager.notShownAttribute(forGlyphAt: next) else { return fallback }
    let delta = manager.location(forGlyphAt: next).x - manager.location(forGlyphAt: glyphIndex).x
    return delta > 0.01 ? delta : fallback
}

// MARK: - Isolated single-line layout (job 224: overprint compositing)

/// One line, laid out on its own — same technique `DocumentRenderer.measuredHeight` already
/// uses (an unbounded, freshly-built `NSLayoutManager`), reused here so an `.overprint` pass
/// (never inserted into the real document flow — see `RenderedDocument.overprintPasses`) can
/// still be measured and drawn with real AppKit glyph geometry, including its own cp437
/// vector-graphics cells (`graphicCells`, above), rather than a hand-rolled second guess at
/// either.
struct IsolatedLineLayout {
    let manager: NSLayoutManager
    let storage: NSTextStorage
    let glyphRange: NSRange
    /// This line's own fragment rect, in the ISOLATED container's local coordinates — not
    /// the destination the caller will actually draw it at. `PageTextView
    /// .drawOverprintPasses` translates by the delta between this and the REAL base
    /// fragment's rect so the pass lands exactly on the baseline it shares.
    let fragmentRect: CGRect
}

/// `nil` for an empty line — nothing to lay out, and nothing for a caller to draw.
func isolatedLineLayout(_ text: NSAttributedString, width: CGFloat) -> IsolatedLineLayout? {
    let storage = NSTextStorage(attributedString: text)
    let manager = NSLayoutManager()
    manager.allowsNonContiguousLayout = false
    let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let glyphRange = manager.glyphRange(for: container)
    guard glyphRange.length > 0 else { return nil }
    let fragmentRect = manager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    return IsolatedLineLayout(manager: manager, storage: storage, glyphRange: glyphRange, fragmentRect: fragmentRect)
}
