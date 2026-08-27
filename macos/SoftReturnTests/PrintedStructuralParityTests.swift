import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 201 (b10 leg 3): the PERMANENT structural-parity gate between the app's native Printed
/// renderer (`DocumentRenderer`, AppKit/`NSTextView`) and the engine's real PDF output
/// (`emitPDF`, `CtrlKD`) — Jon's ruling that the native renderer stays native forever, and that
/// parity with the engine is enforced by a harness instead of hand-hunting divergences.
///
/// ## Field evidence this exists to reproduce (OLDTIMES.WS, b9)
/// - The app shows NO page-2 running head at all.
/// - Centered/bold blocks (title, author, awards) sit visibly LEFT of the engine's placement.
/// - The top line's position differs.
///
/// ## Extraction design — what "engine truth" means here, and why no engine commit was needed
///
/// The brief anticipated needing to widen CtrlKD's `internal` surface (`runningOps`,
/// `pageStream`, `spanPitch`, `tzScale` are all `internal`) and, since this worker session has
/// no push credentials for the separate `soft-return` engine repo (confirmed job 187/193, see
/// `soft-return-engine-repo-no-push-creds`), to commit a minimal public exposure LOCALLY and
/// vendor a thin copy here for the gap until it transports.
///
/// That turned out to be unnecessary. Reading `PDFLayout.swift`/`PDFWriter.swift` at the pinned
/// engine commit (`c01470a`, fetched fresh from `origin/main` this job — see report) shows the
/// surface actually needed is ALREADY public:
/// - `docToPagelines(doc, printed: true) -> [Page]` — the exact pagelines `emitPDF` draws.
/// - `Page.lines`/`Page.headers`/`Page.footers` — text content and running-head/foot
///   classification, keyed exactly as `runningOps` reads them.
/// - `coalesce(_ line: PageLine) -> PageLine` — the same run-merging `pageStream` applies, used
///   here only to match its own "does this line draw anything" gate
///   (`if span.text.isEmpty { continue }`).
/// - `emitPDF(_ doc:mode:options:) -> [UInt8]` — the real PDF bytes, byte for byte what a
///   viewer/QL/CLI draws (already the load-bearing call in job 200's parity gate).
/// - `PageLine.lead`/`.overprint`, `printedMetrics(doc)` — enough to reproduce `pageStream`'s
///   own Y-advance loop (`PDFWriter.swift:593-604`) as PURE ARITHMETIC (start value, subtract
///   lead unless overprint), not a re-derivation of any layout JUDGMENT call.
///
/// So rather than re-deriving `spanPitch`/`tzScale`'s HMI-grid math a second time (exactly the
/// "two derivations that can silently drift apart" failure mode `PrintedGeometry.swift`'s own
/// doc comment warns about), `EngineTruth` below gets X POSITIONS by parsing the real,
/// already-public `emitPDF` output's content-stream text-showing operators directly — the
/// literal bytes a PDF viewer paints, not a second guess at what they should be. TEXT content
/// and header/footer CLASSIFICATION come from the public `Page`/`docToPagelines` data, which
/// `emitPDF` itself builds its streams from (`PDFWriter.swift:682`) — true for every driver
/// EXCEPT LJ6DTP's own character substitution (job 401's Class 3 diagnosis): `ljSubstitute`
/// runs later, inside `lineOpsPrinted` (`PDFWriter.swift:509`), directly on the segments about
/// to draw — a step that never writes back into `Page.lines`, so `docToPagelines`'s own text
/// is PRE-substitution for an LJ6DTP document. `EngineTruth.structuralPages`'s body-line text
/// below corrects for this the same "parallel port, not a re-derivation" way
/// `printedLJ6DTPColourGray` already does for colour — see that call site's own citation.
///
/// The one piece of engine-internal KNOWLEDGE this harness depends on without a public API is
/// the exact byte format of `pageStream`'s text-showing operators
/// (`"\(x) \(y) Td (\(escaped)) Tj"`, `PDFWriter.swift:519-526` and `:548-556`) and of
/// `runningOps`'s (`PDFWriter.swift:206-213`, byte-identical shape). Both are cited here by line
/// number, same discipline as job 200's CLI-path reconstruction — a vendored PARSER of real
/// output, not a vendored REIMPLEMENTATION of layout math.
///
/// ## Scope, restated (job 240, b13 — MAC VIEWING RULING, decision register 2026-08-11;
/// skill registry #25)
///
/// This gate pins STRUCTURE: pagination, line breaks, margins, the POSITIONS of lines,
/// presence of content. It does NOT pin font identity, glyph repertoire, or encoding floors
/// — the native viewer renders through the Mac's own font mapping now (job 240 Part 1), not
/// a base-14 PDF clamp, and a WS5+ proportional run lays out at its Mac font's own natural
/// advance (job 240 Part 2), not an AFM/Tz-scaled reproduction of the engine's PDF grid.
/// Divergence CLASSES below are split accordingly:
/// - HARD, permanent (asserted directly, no `withKnownIssue`): header/footer PRESENCE (class
///   1), content text (class 3 — the actual characters must always match; job 240 changed
///   HOW they're drawn, never WHAT they say), font SIZE per run (class 5, closed job 405),
///   knockout colour (class 6, closed job 399), and the vector-op layer (class 7, closed job
///   404) — a declared point size, a driver colour, and a box/shade/block fill are facts
///   about the document, not a font-identity choice, so once the harness itself measured them
///   correctly (see each class's own closure citation below) they hold with zero exceptions
///   across all 16 `ws7Fixtures`. Vertical origin / y-position (class 4, job 410) joins this
///   list BOUNDED rather than zero-exception, `withKnownIssue` removed: Jon's ruling
///   (2026-08-19, verbatim) — "A is fine as long as it's limited to that 1 pt. Anything more
///   must be flagged as a failure." — accepts the AppKit sub-pixel/content-class rounding noise
///   jobs 201/202/225/227/408 already measured (`BOXES.WS`'s constant -1.0pt, `OLDTIMES.WS`'s
///   sub-point steps) while hard-failing anything worse. NOT closed as of job 410's own sweep:
///   `DARKNESS.WS`, `LJ6DTP.WS`, `OLDTIMES.WS` (page 1 only), `WARPRAYR.WS` exceed the bound
///   today (`LJ6DTP.WS` badly, up to ~15.8pt on pages 1-8) — real, disclosed gate-red, not
///   silently re-hidden; see `structuralParity`'s own Class 4 comment and job 410's report.
///   Job 245's DISCRETE-JUMP shape (a whole ordinary lead landing at one `.lh` transition —
///   FORMFEED.WS, job 232 class b) was closed earlier and stays closed under the same bound.
/// - FONT-IDENTITY, PERMANENTLY expected (`withKnownIssue`, but now an accepted divergence,
///   not a to-do): horizontal placement of a proportional run (class 2) — a Mac font's own
///   natural word/glyph advances will never match the engine's base-14/HMI-grid PDF
///   positions bit-for-bit, and per the ruling that is the correct, intended outcome, not a
///   gap to close.
///
/// Job 240 Part 3 also confirmed (screenshots, `ZZScreenshotJob240.swift.unused`) two
/// PIXEL-level defects this STRUCTURAL harness cannot see at all, because the text content
/// and its container position are both correct — only what paints inside the fragment is
/// wrong: a fragment-clip-height class (LJ6DTP.WS p5/p6/p7 heading tops) and an
/// overprint-punchout class (LJ6DTP.WS p6 "PRETTY NEAT, HUH?"). Both are `PixelOracleKit`'s
/// domain, not this file's; see the job report for the evidence and why no safe fix landed
/// this pass.
enum EngineTruth {
    struct StructuralLine: Equatable {
        enum Kind: Equatable { case header, footer, body }
        var text: String
        /// X of the first non-blank text-showing operator on this line — where visible ink
        /// starts, not where a leading-indent run (if any) starts. This is the metric the field
        /// evidence's "sits visibly left of" symptom is about: a leading-space indent run and
        /// the word after it are frequently two separate `Tj` operators (WS5+ proportional runs
        /// split their indent from their text onto the document's OWN column grid —
        /// `PDFWriter.swift`'s `splitIndent`, cited in this job's report), so the position of
        /// operator 0 alone (always `metrics.left`, indent or not) cannot distinguish "centered
        /// correctly" from "centered on the wrong grid."
        let x: Double
        /// Baseline, measured DOWN from the paper's top edge — the app's own convention
        /// (`GeometryOracleTests.swift`'s `Line.baseline`), so the two sides compare directly.
        /// PDF's own `Td` y is UP from the bottom; converted via `pageHeight - pdfY`.
        let yFromTop: Double
        let kind: Kind
        /// Job 210 (b11 leg 3): the `Tf` point size in force for this line's first
        /// text-showing operator — `PDFWriter.swift:525`/`:554`'s `"BT /\(font) \(pt) Tf"`,
        /// the literal size LJ6DTP's banner-to-body font runs are set at (72pt down to 8pt
        /// per the job brief). 0 for a line the parser never saw an explicit `Tf` before
        /// (should not happen for any real op — every text-showing op is inside its own
        /// `BT ... Tf ... ET`, `PDFWriter.swift:554`).
        var size: Double = 0
        /// Job 210: the fill-gray graphics state (`g` operator, `PDFWriter.swift:489`) in
        /// force at this line — 0.0 (black) unless a driver colour map changed it. LJ6DTP's
        /// knockout (white text over a black bar) is `gray == 1.0` here — see
        /// `colourGrayLJ6DTP`, `PDFDriverLJ6DTP.swift:15-19`, index 15 "White, the knockout."
        var gray: Double = 0.0
    }

    /// One page's structural model: running lines (unordered wrt body), and body lines KEYED
    /// BY `PageLine` INDEX (0-based within `Page.lines`, the SAME array `DocumentRenderer`
    /// pads with blanks to `capacity` — see `AppOutput`). A missing key means that `PageLine`
    /// drew nothing at all (a true blank, or — `BOX.WS`/`LJ6DTP.WS` — a line whose only content
    /// is cp437 box/shade/block glyphs, which draw as VECTOR fills, never a text-showing op).
    /// Keying by index rather than building two independently-filtered flat lists is what
    /// keeps a blank/graphics-only line on ONE side from silently shifting every comparison
    /// after it on the other — the bug this harness's own first draft had.
    struct Page {
        var running: [StructuralLine] = []
        var body: [Int: StructuralLine] = [:]
        /// Job 210: every vector fill op (`re f`, `PDFDriverLJ6DTP.swift`'s `graphicOps` —
        /// box-drawing arms, shades, part blocks, full blocks) this page's stream drew, in
        /// stream order. `DocumentRenderer` draws none of these yet (the class this job's
        /// brief names "the vector-op layer"), so `AppOutput`'s side starts empty.
        var vectors: [GraphicBox] = []
        /// Job 429 (tier-A margins gate, `NativeVsEngineGeometryTests`): this page's own
        /// top/left margin, top-down/left-origin (same convention as `StructuralLine
        /// .yFromTop`/`.x`) — `top` already resolved through a per-page `.mt`/`.mb` override
        /// when this page has one (the SAME `pageTop` local below), `left` is the document's
        /// own `.po`-derived left margin (`metrics.left` — no per-page override mechanism
        /// exists for the left margin in this engine, confirmed by `CtrlKD.Page` carrying
        /// `mtLines`/`mbLines` only, no `poChars`/left-margin equivalent).
        var top: Double = 0
        var left: Double = 0
    }

    /// One `re f` fill rect, in the app's own top-down coordinate convention (matching
    /// `StructuralLine.yFromTop`) — `top` is the rect's TOP edge distance from the paper's
    /// top, since PDF's `re` gives the BOTTOM-left corner in bottom-up `y`.
    struct GraphicBox: Equatable {
        let x: Double
        let top: Double
        let width: Double
        let height: Double
        let gray: Double
    }

    /// One content-stream token: a number, an operator keyword, or a parenthesised string
    /// (bytes already de-escaped the same minimal way the old `textOps` parser did — a
    /// backslash drops and the following byte is kept literally, which is enough to tell
    /// whitespace-only strings from real content without a full PDF string-escape decoder).
    private enum Token {
        case num(Double)
        case op(String)
        case str([UInt8])
    }

    /// Tokenize one content stream. PDF content streams are whitespace-separated tokens
    /// with three shapes this emitter ever writes: bare numbers, bare operator keywords
    /// (`g`, `q`, `Q`, `Tf`, `Ts`, `Td`, `Tj`, `re`, `f`, `BT`, `ET`, `Tz`), and
    /// parenthesised strings. `/Name` resource references (font names before `Tf`) are
    /// skipped — the SIZE this harness needs is the numeric operand, never the name.
    private static func tokenize(_ stream: [UInt8]) -> [Token] {
        var toks: [Token] = []
        var i = 0
        let n = stream.count
        while i < n {
            let c = stream[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1; continue }
            if c == 0x28 {   // '('
                var j = i + 1
                var bytes: [UInt8] = []
                while j < n, stream[j] != 0x29 {
                    if stream[j] == 0x5C, j + 1 < n { bytes.append(stream[j + 1]); j += 2; continue }
                    bytes.append(stream[j]); j += 1
                }
                toks.append(.str(bytes))
                i = j + 1
                continue
            }
            if c == 0x2F {   // '/' — resource name, not needed as a token
                var j = i + 1
                while j < n, stream[j] != 0x20, stream[j] != 0x0A, stream[j] != 0x0D { j += 1 }
                i = j
                continue
            }
            var j = i
            while j < n, stream[j] != 0x20, stream[j] != 0x0A, stream[j] != 0x0D { j += 1 }
            let word = String(decoding: stream[i..<j], as: UTF8.self)
            if let d = Double(word) { toks.append(.num(d)) }
            else if !word.isEmpty { toks.append(.op(word)) }
            i = j
        }
        return toks
    }

    /// One text-showing operator parsed out of a content stream, in stream order, now
    /// carrying the `Tf` size and `g` gray in force when it was drawn (job 210).
    private struct TextOp {
        let x: Double
        let y: Double
        let size: Double
        let gray: Double
        let isWhitespaceOnly: Bool
    }

    /// One `re f` vector fill op, in PDF's own bottom-up coordinates (converted to
    /// `GraphicBox`'s top-down `top` by the caller, which alone knows `pageHeight`).
    private struct RawRect {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let gray: Double
    }

    /// Single sequential pass over one content stream's tokens, replaying the SAME graphics
    /// state this emitter's own byte format carries — `g` (fill gray, `PDFWriter.swift:489`)
    /// and `q`/`Q` (state save/restore, wrapping a shaded `re f` in `graphicOps`,
    /// `PDFDriverLJ6DTP.swift`'s own `rect`/shade branch) — and the text state `Tf` sets
    /// (`PDFWriter.swift:525`/`:554`). Text and vector ops interleave in one document-order
    /// scan rather than two independent regex passes because both need this SAME running
    /// state, and state is inherently sequential (a `g` five ops back is still in force).
    ///
    /// Job 402: also replays `m`/`l`/`c` path construction — `symbolShapes`' `.disc`/`.poly`
    /// sub-shapes (`PDFDriverLJ6DTP.swift`'s own `graphicOps`, `disc`/`symbolShape`'s `.poly`
    /// case) fill a BEZIER/straight-edged PATH, not a `re` rect, so a scan that only recognized
    /// `re`/`f` pairs undercounted every symbol glyph's vector ops to zero (job 401's own
    /// diagnosis, cited at `structuralParity`'s Class 7 assertion). No other emitter in this
    /// codebase writes a bare `m`/`l`/`c` token (confirmed against the pinned engine source —
    /// every other path in `PDFWriter.swift`/`PDFDriverLJ6DTP.swift` uses `re`/`f` exclusively),
    /// so recognizing them here cannot misparse an unrelated op as a path fill. A `disc`'s four
    /// `c` arcs land their ON-CURVE endpoint exactly at the circle's own cardinal points
    /// (`PDFDriverLJ6DTP.swift`'s own `k = 0.5523 * r < r`, so a Bezier control point never
    /// exceeds the endpoint's own radius) — recording each `c`'s endpoint alone (not its two
    /// control points) is therefore an EXACT bounding box, not an approximation. `h` (closepath,
    /// a poly's own `h f`) carries no operand and needs no dedicated case — the shared
    /// `default: nums.removeAll()` branch already does the one thing it needs (clear any
    /// leftover numeric operands) without disturbing the open path.
    private static func scanOps(_ stream: [UInt8]) -> (text: [TextOp], rects: [RawRect]) {
        let toks = tokenize(stream)
        var text: [TextOp] = []
        var rects: [RawRect] = []
        var nums: [Double] = []
        var gray = 0.0
        var grayStack: [Double] = []
        var curSize = 0.0
        var pendingTd: (x: Double, y: Double)?
        var pendingStr: [UInt8]?
        var pendingRect: (x: Double, y: Double, w: Double, h: Double)?
        var pathOpen = false
        var pathPoints: [(x: Double, y: Double)] = []
        for tok in toks {
            switch tok {
            case .num(let d):
                nums.append(d)
            case .str(let bytes):
                pendingStr = bytes
            case .op(let o):
                switch o {
                case "g":
                    if let v = nums.last { gray = v }
                    nums.removeAll()
                case "q":
                    grayStack.append(gray)
                    nums.removeAll()
                case "Q":
                    gray = grayStack.popLast() ?? gray
                    nums.removeAll()
                case "Tf":
                    if let v = nums.last { curSize = v }
                    nums.removeAll()
                case "Td":
                    if nums.count >= 2 { pendingTd = (nums[nums.count - 2], nums[nums.count - 1]) }
                    nums.removeAll()
                case "Tj":
                    if let td = pendingTd, let bytes = pendingStr {
                        let isWS = bytes.isEmpty || bytes.allSatisfy { $0 == 0x20 }
                        text.append(TextOp(x: td.x, y: td.y, size: curSize, gray: gray,
                                           isWhitespaceOnly: isWS))
                    }
                    pendingStr = nil
                    nums.removeAll()
                case "re":
                    if nums.count >= 4 {
                        let c = Array(nums.suffix(4))
                        pendingRect = (c[0], c[1], c[2], c[3])
                    }
                    nums.removeAll()
                case "m":
                    if nums.count >= 2 {
                        pathPoints = [(nums[nums.count - 2], nums[nums.count - 1])]
                        pathOpen = true
                    }
                    nums.removeAll()
                case "l":
                    if pathOpen, nums.count >= 2 {
                        pathPoints.append((nums[nums.count - 2], nums[nums.count - 1]))
                    }
                    nums.removeAll()
                case "c":
                    if pathOpen, nums.count >= 6 {
                        pathPoints.append((nums[nums.count - 2], nums[nums.count - 1]))
                    }
                    nums.removeAll()
                case "f":
                    if let r = pendingRect {
                        rects.append(RawRect(x: r.x, y: r.y, w: r.w, h: r.h, gray: gray))
                        pendingRect = nil
                    } else if pathOpen, pathPoints.count >= 2 {
                        let xs = pathPoints.map(\.x), ys = pathPoints.map(\.y)
                        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
                        rects.append(RawRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY, gray: gray))
                    }
                    pathOpen = false
                    pathPoints = []
                    nums.removeAll()
                default:
                    nums.removeAll()
                }
            }
        }
        return (text, rects)
    }

    /// Split `emitPDF`'s output into its per-page content streams, in page order.
    ///
    /// Job 491: font objects are bare dictionaries with no `stream`/`endstream` pair
    /// (`PDFWriter.swift:743-750`) — but LJ6DTP's own HP1-HP6 tiling patterns
    /// (`lj6dtpHPPatterns`, register C3, `PDFWriter.swift`'s own `patternObjs`) ALSO carry a
    /// `stream`/`endstream` pair, one object per pattern colour (9-14), allocated at LOWER
    /// object numbers than any page (patterns are numbered right after fonts, before
    /// `pageNums`/`contentNums` exist at all) and therefore sorted BEFORE every page object
    /// in the final byte-sorted-by-number output (`PDFWriter.swift`'s own "Python sorts
    /// (num, bytes) tuples... by number" comment). This function's own prior doc comment
    /// ("only page-content objects ever carry a stream/endstream pair") was true only for
    /// fixtures with no LJ6DTP pattern colour in use — LJ6DTP.WS itself declares driver
    /// LJ6DTP and does, so its real PDF carries 6 EXTRA stream objects before its 8 real
    /// page streams, which this function used to count as if they were pages 1-6,
    /// shifting every later page's own content 6 slots early (confirmed directly: dumping
    /// all raw streams found exactly 6 tiny `m ... l ... S` hatch-cell bodies, size/shape
    /// matching `lj6dtpHPPatterns`' own tiling-pattern content, ahead of 8 much larger
    /// bodies whose own first text op is a real running head/body line) — the root cause of
    /// job-489/490/491's own "page 7/8" divergence chase, which was reading pages 1/2's
    /// real content mislabeled as pages 7/8.
    ///
    /// Fixed by reading each stream's own OWN object dictionary (between its `"N 0 obj\n"`
    /// header, `PDFWriter.swift:1493`, and its own `"stream\n"`) and skipping any object
    /// whose dictionary declares `/Type /Pattern` — the only other stream-bearing object
    /// type this emitter ever writes (Image XObjects declare `/Type /XObject`, which this
    /// codebase's `NativeImagePlacementTests` fixtures don't combine with LJ6DTP patterns in
    /// the current corpus, but the check is scoped to `/Type /Pattern` specifically, not
    /// "not a page," so an Image XObject stream would still (correctly) count here as it
    /// did before this fix).
    private static func contentStreams(_ pdf: [UInt8]) -> [[UInt8]] {
        let streamMarker = Array("stream\n".utf8)
        let endMarker = Array("\nendstream".utf8)
        let objMarker = Array(" 0 obj\n".utf8)
        let patternTypeMarker = Array("/Type /Pattern".utf8)
        var blocks: [[UInt8]] = []
        var i = 0
        while let s = pdf.range(of: streamMarker, from: i) {
            let contentStart = s.upperBound
            guard let e = pdf.range(of: endMarker, from: contentStart) else { break }
            // The LAST "N 0 obj\n" at or before this stream's own start is THIS object's
            // own header — objects with no stream of their own (fonts, the page dict, the
            // Catalog/Pages dicts) may appear in between since this scan only ever stops at
            // "stream\n" occurrences.
            var objStart = i
            var search = i
            while let o = pdf.range(of: objMarker, from: search), o.upperBound <= s.lowerBound {
                objStart = o.upperBound
                search = o.upperBound
            }
            let dict = Array(pdf[objStart..<s.lowerBound])
            let isPattern = dict.range(of: patternTypeMarker, from: 0) != nil
            if !isPattern {
                blocks.append(Array(pdf[contentStart..<e.lowerBound]))
            }
            i = e.upperBound
        }
        return blocks
    }

    /// The structural model `emitPDF(doc, mode: .printed)` actually draws, per page, in the
    /// app's own top-down coordinate convention.
    static func structuralPages(for doc: Document) -> [Page] {
        let pdf = emitPDF(doc, mode: .printed)
        let pagelines = docToPagelines(doc, printed: true)
        let streams = contentStreams(pdf)
        // `resolvedPageHeight`/`resolvedPrintedPageHeight` (PDFLayout.swift) are `internal`;
        // `printedMetrics` (PrintedGeometry.swift) is the public façade over the SAME figure
        // (its own doc comment: "a FAÇADE ... it only calls the existing helpers"), so this is
        // the identical value with no re-derivation.
        let metrics = printedMetrics(doc)
        let pageHeight = metrics.pageHeight
        let startNo = doc.page?.pnStart ?? 1

        var result: [Page] = []
        for (i, pageLines) in pagelines.enumerated() {
            guard i < streams.count else { result.append(Page()); continue }
            let (scanned, rawRects) = scanOps(streams[i])
            var ops = scanned
            var page = Page()
            page.vectors = rawRects.map {
                GraphicBox(x: $0.x, top: Double(pageHeight) - ($0.y + $0.h), width: $0.w,
                          height: $0.h, gray: $0.gray)
            }

            // Job 491: whether THIS page's own header/footer line `n` reaches the page at
            // all — the engine's own `runningOps` (`PDFWriter.swift`) `guard y >= 0 else {
            // continue }` skips emitting a `Tj` ENTIRELY once a running line's baseline
            // would land past the bottom of the sheet; it is not "an invisible one". Without
            // this, `consumeRunning` below (which only ever checked "is the dict entry
            // non-empty and is `ops` non-empty," never whether the REAL emission actually
            // happened) blindly pops whatever op comes next — a body-text op, mislabeled as
            // this running line — whenever the real emission was suppressed. Confirmed
            // exactly this way on LJ6DTP.WS: its own `.f1` (footer, two raw 0x0F bytes, no
            // font block of its own) has a NEGATIVE real baseline on every one of its 8
            // pages (`.lh`/`.mb` combination), so the real engine's footer op count is 0
            // EVERYWHERE — the old unconditional pop instead grabbed a different, unrelated
            // body op on each page, which is exactly the "page 7/8 disagree" pattern job
            // 489/490 chased under this file's OWN prior `contentStreams` bug (see that
            // function's own citation).
            //
            // Re-derived as pure arithmetic from PUBLIC fields only (`printedMetrics`,
            // `doc.page`, `PDFMetrics.lead`, `pageLines.mtLines`/`.mbLines`) — no layout
            // judgment, the same class of "safe to duplicate" arithmetic `pageTop`'s own
            // per-page `.mt`/`.mb` swap just below already is (same citation), and the exact
            // formula `DocumentRenderer.runningLines` (`DocumentRenderer.swift`) already
            // ports for its own production rendering.
            var pageMt = doc.page?.mtLines ?? 3.0
            var pageMtSource = doc.page?.mtSource
            var pageMb = doc.page?.mbLines ?? 8.0
            if let mt = pageLines.mtLines { pageMt = mt; pageMtSource = .file }
            if let mb = pageLines.mbLines { pageMb = mb }
            let hm = pageMtSource == .file ? (doc.page?.hmLines ?? 2.0) : 0.0
            let topHead = Double(pageLines.headers.keys.max() ?? 1)
            let headBase = max(0.0, pageMt - hm - topHead)
            let plLines = doc.page?.plLines ?? 66.0
            let fmLines = doc.page?.fmLines ?? 2.0
            let footLine = plLines - pageMb + fmLines
            func runningLineFits(base: Double, lead: Double, n: Int) -> Bool {
                Double(pageHeight) - (base + Double(n - 1)) * lead - Double(metrics.size) >= 0
            }

            // Running ops come FIRST in the stream (`pageStream`'s `ops = running`,
            // `PDFWriter.swift:590`), headers then footers, each sorted by line number
            // ascending (`runningOps`'s two `for n in ...keys.sorted()` loops,
            // `PDFWriter.swift:229`/`234`). `#` is substituted with the real page number
            // (`runningOps`'s `render(_:)`, `PDFWriter.swift:198-205`).
            func consumeRunning(_ dict: [Int: String], kind: StructuralLine.Kind) {
                let lead = kind == .header ? Double(PDFMetrics.lead) : metrics.lead
                let base = kind == .header ? headBase : footLine
                for n in dict.keys.sorted() {
                    guard let text = dict[n], !text.isEmpty, !ops.isEmpty else { continue }
                    guard runningLineFits(base: base, lead: lead, n: n) else { continue }
                    let op = ops.removeFirst()
                    let rendered = text.replacingOccurrences(of: "#", with: String(startNo + i))
                    page.running.append(StructuralLine(text: rendered, x: op.x,
                                                       yFromTop: pageHeight - op.y, kind: kind,
                                                       size: op.size, gray: op.gray))
                }
            }
            consumeRunning(pageLines.headers, kind: .header)
            consumeRunning(pageLines.footers, kind: .footer)

            // Job 426: a page whose OWN `.mt`/`.mb` differs from the document's global pair
            // (`Page.mtLines`/`mbLines`, non-nil — "Finding 3", b26-print-fidelity-2, the
            // SAME per-page-margin-override mechanism `emitPDF`'s own per-page loop applies,
            // `PDFWriter.swift:1082-1091`) needs ITS OWN `top`, not the document-global
            // `metrics.top` computed once above — `printedTop` (the `internal` function that
            // actually reads `Page.mtLines`) isn't public, so this mirrors `emitPDF`'s own
            // "swap `.page` on a local `Document` copy, scoped to just this call" idiom
            // (same citation) through the PUBLIC `printedMetrics` façade instead — no
            // re-derivation of the margin arithmetic itself, only the identical plumbing
            // trick `emitPDF` already uses to reach it.
            let pageTop: Double
            if (pageLines.mtLines != nil || pageLines.mbLines != nil), var eff = doc.page {
                if let mt = pageLines.mtLines { eff.mtLines = mt; eff.mtSource = .file }
                if let mb = pageLines.mbLines { eff.mbLines = mb; eff.mbSource = .file }
                var pageDoc = doc
                pageDoc.page = eff
                pageTop = printedMetrics(pageDoc).top
            } else {
                pageTop = metrics.top
            }
            page.top = pageTop
            page.left = metrics.left

            // Group the remaining (body) ops by contiguous identical Y — one group per
            // drawing line, in stream order (`PDFWriter.swift:600-604`'s own per-line loop
            // never changes `y` mid-line).
            var groups: [(y: Double, ops: [TextOp])] = []
            for op in ops {
                if let last = groups.indices.last, groups[last].y == op.y {
                    groups[last].ops.append(op)
                } else {
                    groups.append((op.y, [op]))
                }
            }

            // Each PageLine's Y, reproduced by the SAME loop `pageStream` runs
            // (`PDFWriter.swift:880-892`) — `y` starts at `pageHeight - top - firstLead`,
            // where `firstLead` is the PAGE'S OWN FIRST LINE's `lead` (b26 wave-2, "the first
            // line of a page takes its position from `top` and ITS OWN lead, not a flat
            // `size`" — job 425's fix, `PDFWriter.swift:858-869`), and steps back by each
            // line's own `lead` (or the document default) for every line except one
            // immediately following an `overprint` line, which shares its baseline. Every
            // input here (`PageLine.lead`/`.overprint`, `metrics.*`) is public; this is
            // arithmetic, not layout judgment, so it carries none of `spanPitch`/`tzScale`'s
            // re-derivation risk this file's own doc comment warns against.
            //
            // Job 426: this harness's OWN copy of the first-line formula was STILL the flat
            // pre-b26 `pageHeight - top - size` — a FOURTH occurrence of the exact stale
            // formula job 425 already found and fixed in `DocumentRenderer.renderPrinted`,
            // `GeometryOracleTests`, and `PageSettingsPickerTests` (job 425's own report:
            // "THREE independent app-side blast-radius points"), missed there because this
            // file's own Class checks only compare indices BOTH sides key
            // (`PrintedStructuralParityTests.divergences`'s own "only indices BOTH sides
            // agree drew something are comparable" scope note) — a wrong first-line Y offsets
            // EVERY later line on the page by the same constant, so EVERY group-match on
            // EVERY page of a fixture whose first line's lead differs from the document's flat
            // `size` (LJ6DTP.WS's 72pt banner-vs-12pt-body opener, confirmed against the real
            // `emitPDF` bytes: page 1's real first Td lands at y=699.0, not the stale
            // formula's value) silently fails from line 0 onward — `page.body` comes out
            // EMPTY for the WHOLE page, not just the target knockout line, so every downstream
            // Class 3/4/5/6 check for that fixture was vacuously comparing nothing. Root cause
            // of the knockout vacuity guard's own failure: the group holding the real
            // knockout text was never even reached, not `contentOp` picking a wrong sub-op —
            // the "black shadow-copy run at identical Y" the job brief hypothesized does not
            // occur in the real bytes at this position.
            //
            // A PageLine with no matching group at its Y drew NOTHING (true blank, or
            // graphics-only — see `Page`'s own doc comment) and is simply absent from
            // `page.body`, which is how a graphics-heavy fixture (`BOX.WS`, `LJ6DTP.WS`) stays
            // comparable for its TEXT lines.
            let firstLead = pageLines.first?.lead ?? metrics.lead
            var y = pageHeight - pageTop - firstLead
            var prevOverprint = false
            var groupIdx = 0
            // Job 426: the raw index an `.overprint` chain's content gets KEYED AT — the
            // chain's own BASE (first) line, matching `AppOutput.remapToRawIndices`'s own
            // convention (`raw` is the running total BEFORE this fragment, i.e. the chain's
            // first raw `PageLine`; see that function's own doc comment, "every real
            // fragment's own raw span is `1 + overprintPasses[...].count`"). Reset whenever
            // a line does NOT share the previous line's Y (the same `!prevOverprint`
            // condition that already resets `y` above) — every ordinary (non-chain) line is
            // its own base, so `chainStart == n` there and nothing changes for it.
            var chainStart = 0
            for (n, line) in pageLines.enumerated() {
                if n > 0, !prevOverprint {
                    y -= line.lead ?? metrics.lead
                    chainStart = n
                }
                prevOverprint = line.overprint

                // Job 401 (Class 3 diagnosis): `docToPagelines`'s own `PageLine.text` is
                // PRE-substitution — the engine's LJ6DTP driver patches PC-8 slots
                // (`_`->em dash, `'`->curly, etc.) later, inside `lineOpsPrinted`
                // (`PDFWriter.swift:509`'s `ljSubstitute`), directly on the segments about
                // to draw, a step that never writes back into `Page.lines`. Applying the
                // SAME substitution here (`DocumentRenderer.printedLJ6DTPSubstitute`,
                // widened to `internal` this job, byte-identical to the engine's own
                // `ljSubst`/`ljSubstUnivers` tables — confirmed against
                // `PDFDriverLJ6DTP.swift:26-41` fresh this job) is reusing the app's own
                // already-verified port, not a second re-derivation, so "engine text"
                // matches what the real PDF (and the app) actually show.
                let lj = doc.printerDriver == "LJ6DTP"
                let text = coalesce(line).map { span -> String in
                    // Job 403: the SAME "PageLine.text is PRE-emission" gap this file's own
                    // LJ6DTP-substitution citation above already named, found on a second,
                    // driver-independent mechanism: a 0x0F user-print-control span's own
                    // `pctlHMI` (`Span.pctlHMI` non-nil) carries `docToPagelines`'s decoded,
                    // HUMAN-READABLE display string (`"Empty |00.300\"hx..."`) — but
                    // `PDFWriter.lineOpsPrinted` (`PDFWriter.swift:466-475`) never draws
                    // that string on paper, only advances by the block's own declared HMI
                    // width (`DocumentRenderer.appendSpan`'s own M10/job-371 citation,
                    // ported from the identical engine rule). Reading it straight compared
                    // the app's CORRECT blank render against text the real PDF bytes never
                    // draw either — LJ6DTP.WS's 6 "reads back as a single U+FFFC" Class 3
                    // residuals (job 401's #2/#3) are this, not a text-attribute gap: the
                    // widened, job-403 UNTRUNCATED preview above is what made the actual
                    // (identical-past-40-chars) difference legible enough to trace at all.
                    guard span.pctlHMI == nil else { return "" }
                    guard lj else { return span.text }
                    let entry = span.font.flatMap { doc.fonts.indices.contains($0) ? doc.fonts[$0] : nil }
                    return printedLJ6DTPSubstitute(span.text, entry: entry)
                }.joined()

                // Job 405 (task #62, Class 3/5 closure): a PageLine whose own text is
                // entirely whitespace and/or `graphicChars` glyphs (a decorative bar, with
                // or without its own leading indent) owns NO real text-showing operator —
                // `lineOpsPrinted`'s graphics branch (`PDFWriter.swift:545`) emits fill ops
                // only, and even a real INDENT `Tj` it emits for a leading-space run
                // (`splitIndent`'s own carve-out) is pure whitespace. `contentOp` below picks
                // the group's FIRST NON-WHITESPACE op with no notion of which raw PageLine
                // actually authored it — harmless for an ordinary line (its own group has
                // nothing else in it), but when this line is the BASE (or an interior member)
                // of an `.overprint` chain whose LATER member owns the shared group's only
                // real content (LJ6DTP.WS's own bar-then-caption convention: page 1 body line
                // 9's "████...█" bar shares its baseline with body line 11's "Manual
                // Copyright..." caption; same construct on page 6 lines 22/30/39/50), leaving
                // this line eligible to consume the group steals the CAPTION's own font size/
                // x/gray — `text` above (sourced straight from this line's OWN spans, never
                // the group) still correctly names this line's own bar, so the resulting
                // `StructuralLine` ends up describing two different PageLines at once (proven
                // via `docToPagelines`/`Oracle.layOut` probe: page 1 body line 9's matched op
                // is verbatim body line 11's "Manual Copyright " word, 14pt Antique Olive —
                // this file's own report has the full per-line arithmetic for all 5 occurrences,
                // pages 1 and 6). Skipping the match here is the SAME "true blank" treatment
                // this loop already gives an ordinary empty line, and leaves the group for
                // whichever LATER chain member (identical Y, `!prevOverprint` keeps it so)
                // actually authored the real content — exactly the search this loop already
                // performs for every other still-unconsumed group. `LAYOUT.WS`/every other
                // fixture's ordinary prose lines are untouched (their own text always contains
                // a real character).
                let ownsRealText = text.contains { !$0.isWhitespace && !graphicChars.contains($0) }

                if ownsRealText, groupIdx < groups.count, abs(groups[groupIdx].y - y) < 0.15 {
                    let group = groups[groupIdx]
                    groupIdx += 1
                    let contentOp = group.ops.first(where: { !$0.isWhitespaceOnly }) ?? group.ops[0]
                    // Job 426 (knockout vacuity, continuing job 425's diagnosis): keyed at
                    // `chainStart`, NOT `n` — `AppOutput.remapToRawIndices` (the app-side
                    // equivalent of this table) keys an `.overprint` chain's real content at
                    // the chain's own BASE raw index (its real AppKit fragment collapses the
                    // whole chain to one fragment, stored at the running `raw` total BEFORE
                    // that fragment), never at whichever raw line happens to own the visible
                    // text. Keying this side at `n` instead — the line that "ownsRealText" —
                    // was a raw-index MISMATCH between the two sides for every chain whose
                    // caption isn't its own base line: `PrintedStructuralParityTests
                    // .divergences`'s own "only indices BOTH sides agree drew something are
                    // comparable" scope note silently absorbed the gap for the general
                    // structural-parity checks, but `knockoutRunsClassifyTheSameWayTheEngine
                    // Does`'s vacuity guard has no such tolerance: engine keyed LJ6DTP.WS's 4
                    // real knockout captions at 11/23/32/41 (each chain's LAST line) while the
                    // app keyed the SAME 4 chains' content at 9/22/30/39 (each chain's FIRST
                    // line) — disjoint key sets, so `app[pageIndex].body[k]` was always nil for
                    // every real knockout `k` the engine reported, regardless of colour. No
                    // "black shadow-copy run at identical Y" (the job brief's hypothesis) was
                    // found in the real bytes at any of the 4 positions — confirmed by direct
                    // inspection of `emitPDF`'s own content stream (this job's report).
                    page.body[chainStart] = StructuralLine(text: text, x: contentOp.x,
                                                  yFromTop: pageHeight - y, kind: .body,
                                                  size: contentOp.size, gray: contentOp.gray)
                }
            }
            result.append(page)
        }
        return result
    }
}

private extension Array where Element == UInt8 {
    /// First occurrence of `needle` at or after `from`, byte-exact — `Foundation`'s
    /// `firstRange(of:)` on `[UInt8]` needs `Collection` conformance games this avoids.
    func range(of needle: [UInt8], from: Int) -> Range<Int>? {
        guard !needle.isEmpty, from <= count - needle.count else { return nil }
        var i = from
        while i <= count - needle.count {
            if Array(self[i..<i + needle.count]) == needle { return i..<(i + needle.count) }
            i += 1
        }
        return nil
    }
}

/// The app's real Printed-style output, in the SAME shape as `EngineTruth`, so the two can diff
/// directly. Reuses `Oracle` (`GeometryOracleTests.swift`, same target) for the real
/// `NSTextView`/`NSLayoutManager` drive rather than a second one.
extension Oracle {
    /// Every rendered line fragment on a page, KEYED BY ORDINAL (0-based, blanks included) —
    /// the same indexing `DocumentRenderer.renderPrinted` pads `Page.lines` to `capacity`
    /// with, so ordinal `n` here and `EngineTruth.Page.body[n]` describe the SAME `PageLine`.
    /// Measured the same way `EngineTruth` measures a body line: the baseline, and the x of
    /// the first VISIBLE (non-whitespace) glyph — not glyph 0, which is always the container's
    /// left edge regardless of leading spaces and so cannot show a centering divergence (see
    /// this file's own top doc comment).
    @MainActor
    static func structuralBodyLines(of page: LaidOutPage, textFrame: CGRect) -> [Int: EngineTruth.StructuralLine] {
        var result: [Int: EngineTruth.StructuralLine] = [:]
        guard page.glyphs.length > 0 else { return result }
        let text = page.textView.string as NSString
        var index = page.glyphs.location
        let end = page.glyphs.location + page.glyphs.length
        var ordinal = 0
        while index < end {
            var effective = NSRange(location: 0, length: 0)
            let fragment = page.manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let used = page.manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            if used.width > 0 {
                let chars = page.manager.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
                let lineText = text.substring(with: chars)

                var contentX: CGFloat?
                var g = effective.location
                while g < effective.location + effective.length {
                    let ch = page.manager.characterIndexForGlyph(at: g)
                    if ch < text.length {
                        let scalarValue = text.character(at: ch)
                        if let scalar = Unicode.Scalar(scalarValue), !CharacterSet.whitespaces.contains(scalar) {
                            let loc = page.manager.location(forGlyphAt: g)
                            contentX = textFrame.origin.x + fragment.origin.x + loc.x
                            break
                        }
                    }
                    g += 1
                }
                // No non-whitespace glyph on this fragment: either the DocumentRenderer
                // padding/blank-line placeholder (a single synthetic space —
                // `DocumentRenderer.attributedLine`'s own doc comment) or an author's
                // all-space line. Either way there is no visible ink to compare, matching
                // `EngineTruth`'s own "no group at this Y" skip for the same PageLine index —
                // leave this ordinal unset rather than recording a meaningless position.
                if let contentX {
                    let baseLoc = page.manager.location(forGlyphAt: effective.location)
                    let baseline = textFrame.origin.y + fragment.origin.y + baseLoc.y
                    // Job 210: the font size and foreground-color gray in force at the
                    // FIRST VISIBLE glyph — the same glyph `contentX` measured — read from
                    // `NSTextStorage`'s real attributes, not re-derived, so a divergence
                    // here can only be `DocumentRenderer`'s own choice of font/color, never
                    // this harness's own arithmetic.
                    let firstVisibleChar = page.manager.characterIndexForGlyph(at: g)
                    let attrs = page.textView.textStorage?.attributes(at: firstVisibleChar, effectiveRange: nil) ?? [:]
                    let size = Double((attrs[.font] as? NSFont)?.pointSize ?? 0)
                    let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceGray)
                    let gray = Double(color?.whiteComponent ?? 0)
                    result[ordinal] = EngineTruth.StructuralLine(
                        text: lineText, x: Double(contentX), yFromTop: Double(baseline), kind: .body,
                        size: size, gray: gray)
                }
            }
            guard effective.length > 0 else { break }
            index = effective.location + effective.length
            ordinal += 1
        }
        return result
    }
}

enum AppOutput {
    /// Job 399 (Class 6 gate-debt): the GRAY actually painted for one real fragment ordinal,
    /// read straight off the pass content `DocumentRenderer` drew there — needed because
    /// `Oracle.structuralBodyLines` (below) can only measure `page.textView.textStorage`,
    /// which `renderPrinted` deliberately leaves BLANK for a fragment whose true content
    /// draws through a pass instead (`DocumentRenderer.renderPrinted`'s own `let content =
    /// oversized ? PageLine([], soft: base.soft) : base`): an oversized banner line
    /// (`oversizedSelfPasses`) or an `.overprint` chain's own base line, whose real ink is
    /// its LAST pass, not its blank fragment (`PageTextView.drawOverprintPasses`'s own doc
    /// comment: "the knockout text — always last in the chain — draws on top of both").
    /// Reading straight off the attributed string's own attributes needs no real AppKit
    /// layout — font/colour are attributes, not a geometry decision — so this stays exactly
    /// the "ask the real render path, don't re-derive" discipline this file's top doc comment
    /// requires, just against a DIFFERENT piece of the same real render than
    /// `structuralBodyLines` reads. `nil` when the pass has no visible ink at all (should not
    /// happen for a real pass — every self-pass/overprint-pass exists precisely because there
    /// IS content to draw).
    private struct PassInk { let text: String; let size: Double; let gray: Double }

    private static func firstVisibleInk(_ source: NSAttributedString) -> PassInk? {
        guard source.length > 0 else { return nil }
        let string = source.string as NSString
        var index = 0
        while index < source.length {
            let scalar = Unicode.Scalar(string.character(at: index))
            if let scalar, !CharacterSet.whitespaces.contains(scalar) {
                let attrs = source.attributes(at: index, effectiveRange: nil)
                let size = Double((attrs[.font] as? NSFont)?.pointSize ?? 0)
                let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceGray)
                return PassInk(text: source.string, size: size, gray: Double(color?.whiteComponent ?? 0))
            }
            index += 1
        }
        return nil
    }

    /// Job 240 (b13, Part 3): `body`'s keys, from per-real-fragment ordinal to per-raw-
    /// `PageLine` index — see the call site's own doc comment for why. `overprintCounts[ord]`
    /// is real fragment `ord`'s own captured chain-continuation count (0 for an ordinary
    /// line); the raw index a real fragment occupies is 1 (itself) plus every earlier real
    /// fragment's own `1 + count`.
    static func remapToRawIndices(
        _ body: [Int: EngineTruth.StructuralLine], overprintCounts: [Int],
        overprintPasses: [[NSAttributedString]] = [], oversizedSelfPasses: [NSAttributedString?] = []
    ) -> [Int: EngineTruth.StructuralLine] {
        var raw = 0
        var out: [Int: EngineTruth.StructuralLine] = [:]
        for ord in overprintCounts.indices {
            if var line = body[ord] {
                let chainPasses = overprintPasses.indices.contains(ord) ? overprintPasses[ord] : []
                let selfPass = oversizedSelfPasses.indices.contains(ord) ? oversizedSelfPasses[ord] : nil
                if let chainInk = chainPasses.last.flatMap(firstVisibleInk) {
                    // Job 429 (LJ6DTP.WS Class 3/5 regression, re-diagnosed): this branch
                    // used to leave text/size as whatever `body[ord]` measured off the
                    // chain's BASE fragment unconditionally, on the theory that the base
                    // always carries its own real content and only the painted COLOUR
                    // changes when the chain's LAST pass paints over it. True for a chain
                    // like FORMFEED.WS's (two independently-real columns overprinted on one
                    // line — the base's own text is genuine and IS what `EngineTruth` keys
                    // `chainStart` to, since its own `ownsRealText` gate lets the base consume
                    // the group first). FALSE for a chain like LJ6DTP.WS's (a graphics-only
                    // decorative bar overprinted by a real caption) — there `ownsRealText` is
                    // false for the base, so `EngineTruth` skips it and keys `chainStart` to
                    // the LATER real-text member instead (that job's own citation), which job
                    // 426 additionally re-pointed at this function's own `raw` convention so
                    // the knockout-vacuity guard could compare it at all — silently redefining
                    // what "the content at this raw index" means for the base-has-no-real-text
                    // case specifically, invisible before 426 because the two sides' keys
                    // never overlapped there in the first place. Mirror `EngineTruth`'s own
                    // `ownsRealText` gate here: only borrow the chain's LAST pass for text/
                    // size when the base's own text has none of its own (the same "ask the
                    // real render path" discipline the `selfInk` branch below already uses) —
                    // otherwise the base's own measured text/size (already correct) stays.
                    let baseOwnsRealText = line.text.contains { !$0.isWhitespace && !graphicChars.contains($0) }
                    if !baseOwnsRealText {
                        line.text = chainInk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        line.size = chainInk.size
                    }
                    line.gray = chainInk.gray
                } else if let selfInk = selfPass.flatMap(firstVisibleInk) {
                    // Job 401 (Class 3/5 diagnosis): an oversized banner/heading line's REAL
                    // fragment is a blank placeholder (`DocumentRenderer.renderPrinted`'s own
                    // `let content = oversized ? PageLine([], soft: base.soft) : base` —
                    // `attributedLine`'s single-space filler for an empty `PageLine`), so
                    // `body[ord]` here is the PLACEHOLDER's own text ("")/size (the document
                    // default, not the banner's real size) — job 399 only taught this call
                    // site to correct GRAY off the self-pass; TEXT and SIZE need the exact
                    // same "ask the real render path" correction, or every oversized
                    // title/heading (LJ6DTP.WS's "LJ6DTP" banner, "Features"/"Files" H1s, ...)
                    // permanently reads as a blank 12pt line instead of its real content.
                    line.text = selfInk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    line.size = selfInk.size
                    line.gray = selfInk.gray
                }
                out[raw] = line
            }
            raw += 1 + overprintCounts[ord]
        }
        return out
    }

    /// Job 403: vector fills for ONE oversized-self-pass or overprint-chain-continuation
    /// pass, in the SAME page-absolute (well, `textFrame`-relative — the caller adds
    /// `textFrame.origin`, same convention `structuralPages`' base-fragment vectors already
    /// use) coordinate space as `structuralPages`' own `vectors`. Reuses `isolatedLineLayout`/
    /// `graphicCells` — the exact production functions `PagedDocumentView
    /// .drawOversizedSelfPasses`/`drawOverprintPasses` call to PAINT this same content — and
    /// replicates their own baseline-translation formula (`fragment.origin.y +
    /// baselineOffset` vs. the isolated layout's own baseline) exactly, so a divergence here
    /// can only mean those functions' own geometry disagrees, never a second independent
    /// derivation drifting apart (this file's own top doc comment's "one derivation, not
    /// two" discipline).
    ///
    /// Closes the residual `structuralParity`'s Class 3/5/7 comments name: an oversized or
    /// `.overprint`-chain line's REAL AppKit fragment is `DocumentRenderer.renderPrinted`'s
    /// blank placeholder — this walk's caller previously only ever visited that blank real
    /// fragment, so a graphics-only oversized/chain line (LJ6DTP.WS's "█" bars) counted zero
    /// vector ops no matter what actually painted through the self-pass/chain overlay.
    @MainActor
    private static func passVectors(
        _ pass: NSAttributedString, containerWidth: CGFloat, fragmentOrigin: CGPoint, baselineOffset: CGFloat,
        pclPrograms: [[UInt8]] = []
    ) -> [EngineTruth.GraphicBox] {
        guard let isolated = isolatedLineLayout(pass, width: containerWidth) else { return [] }
        let targetBaseline = fragmentOrigin.y + baselineOffset
        let isolatedBaseline = isolated.fragmentRect.origin.y
            + isolated.manager.location(forGlyphAt: isolated.glyphRange.location).y
        let offset = CGPoint(x: fragmentOrigin.x - isolated.fragmentRect.origin.x,
                              y: targetBaseline - isolatedBaseline)
        let cells = graphicCells(manager: isolated.manager, storage: isolated.storage,
                                 glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect)
        var boxes = cells.flatMap { cell in
            cell.fills.map { fill in
                let frame = fill.frame.offsetBy(dx: offset.x, dy: offset.y)
                return EngineTruth.GraphicBox(x: Double(frame.origin.x), top: Double(frame.origin.y),
                                              width: Double(frame.width), height: Double(frame.height),
                                              gray: Double(fill.gray))
            }
        }
        // Job 495: this pass's OWN PCL control (LJ6DTP's border on its 4 oversized page-open
        // lines) — mirrors `PagedDocumentView.drawOversizedSelfPasses`'s own identical
        // replay; see `pclRectsInIsolatedPass`'s own doc comment for the mechanism.
        for fill in pclRectsInIsolatedPass(
            manager: isolated.manager, storage: isolated.storage, glyphRange: isolated.glyphRange,
            fragment: isolated.fragmentRect, offset: offset, containerWidth: containerWidth,
            pclPrograms: pclPrograms) {
            let r = fill.frame
            boxes.append(EngineTruth.GraphicBox(x: Double(r.origin.x), top: Double(r.origin.y),
                                                width: Double(r.width), height: Double(r.height),
                                                gray: Double(fill.gray)))
        }
        return boxes
    }

    /// The app's real Printed rendering. Running lines come straight from
    /// `RenderedDocument.runningLines` — the SAME values `PagedDocumentView` actually draws
    /// (`DocumentRenderer.runningLines`/`PagedDocumentView.drawRunningLines`), not re-measured
    /// via `NSLayoutManager`: a running line is point-drawn (`NSAttributedString.draw(at:)`),
    /// not laid out, so there is no AppKit layout DECISION to ask about — the formula and the
    /// draw position are the same value by construction, unlike body text (which genuinely
    /// needs `Oracle`'s "ask the layout manager what it did" discipline).
    @MainActor
    static func structuralPages(for state: DocumentState) -> [(running: [EngineTruth.StructuralLine], body: [Int: EngineTruth.StructuralLine], vectors: [EngineTruth.GraphicBox])] {
        let (rendered, _, pages) = Oracle.layOut(state)
        return pages.enumerated().map { pageIndex, laidOutPage in
            let running: [EngineTruth.StructuralLine] = rendered.runningLines.indices.contains(pageIndex)
                ? rendered.runningLines[pageIndex].map {
                    let attrs = $0.text.length > 0 ? $0.text.attributes(at: 0, effectiveRange: nil) : [:]
                    let size = Double((attrs[.font] as? NSFont)?.pointSize ?? 0)
                    let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceGray)
                    let gray = Double(color?.whiteComponent ?? 0)
                    return EngineTruth.StructuralLine(
                        text: $0.text.string,
                        x: Double(rendered.textFrame.origin.x) + $0.leadingOffset,
                        yFromTop: $0.baselineFromTop,
                        kind: $0.kind == .header ? .header : .footer,
                        size: size, gray: gray)
                }
                : []
            // Job 211: vector graphics ops (box/shade/block geometry), read via the SAME
            // `graphicCells` function `PageTextView.draw(_:)` paints from — not a
            // `RenderedDocument`-side field (job 210's own scoping note on why: it would
            // re-derive the isolated-vs-embedded measurement disagreement job 202
            // documented). `graphicCells`' rects are CONTAINER-LOCAL (its own top doc
            // comment), same reason `Oracle.structuralBodyLines` measures in container-local
            // glyph coordinates — `textFrame.origin` converts to the page-absolute frame
            // `EngineTruth.GraphicBox` expects, same as that function's own baseline/x.
            // Job 427: this REAL page's own container-to-paper anchor
            // (`rendered.perPageTextTop[pageIndex]`), not the single flat
            // `rendered.textFrame.origin.y` — `PagedDocumentView.layout()`/`textTop(atPage:)`
            // now position this page's own container there (see
            // `RenderedDocument.perPageTextTop`'s own doc comment), so converting this
            // page's CONTAINER-LOCAL glyph geometry back to page-absolute coordinates has to
            // use the SAME per-page anchor or a page whose own `.mt`/`.mb` differs from the
            // document's global pair (SCRIPT.WS's figure-listing pages) compares against the
            // wrong baseline here, in the TEST HARNESS only — not a production defect; see
            // `AppOutput.remapToRawIndices`'s own call site below.
            let pageTextFrame = CGRect(
                x: rendered.textFrame.origin.x,
                y: rendered.perPageTextTop.indices.contains(pageIndex)
                    ? CGFloat(rendered.perPageTextTop[pageIndex]) : rendered.textFrame.origin.y,
                width: rendered.textFrame.width, height: rendered.textFrame.height)
            var vectors: [EngineTruth.GraphicBox] = []
            // Job 403: this page's own self-pass/chain-continuation content — see
            // `passVectors`' own doc comment. Same per-real-fragment-ordinal indexing
            // `remapToRawIndices` below already relies on (`oversizedSelfPasses`/
            // `overprintPasses`, one entry per real AppKit fragment).
            let selfPasses = rendered.oversizedSelfPasses.indices.contains(pageIndex)
                ? rendered.oversizedSelfPasses[pageIndex] : []
            let chainPasses = rendered.overprintPasses.indices.contains(pageIndex)
                ? rendered.overprintPasses[pageIndex] : []
            let containerWidth = laidOutPage.container.size.width
            if let storage = laidOutPage.textView.textStorage, laidOutPage.glyphs.length > 0 {
                var index = laidOutPage.glyphs.location
                let end = laidOutPage.glyphs.location + laidOutPage.glyphs.length
                var ord = 0
                while index < end {
                    var effective = NSRange(location: 0, length: 0)
                    let fragment = laidOutPage.manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
                    let cells = graphicCells(manager: laidOutPage.manager, storage: storage,
                                             glyphRange: effective, fragment: fragment)
                    for cell in cells {
                        for fill in cell.fills {
                            vectors.append(EngineTruth.GraphicBox(
                                x: Double(pageTextFrame.origin.x + fill.frame.origin.x),
                                top: Double(pageTextFrame.origin.y + fill.frame.origin.y),
                                width: Double(fill.frame.width), height: Double(fill.frame.height),
                                gray: Double(fill.gray)))
                        }
                    }
                    // Job 403: this ordinal's REAL fragment is a blank placeholder whenever
                    // its base line is oversized or the base of an `.overprint` chain — its
                    // true content (including graphics) paints through
                    // `oversizedSelfPasses`/`overprintPasses` instead
                    // (`DocumentRenderer.renderPrinted`'s own `let content = oversized ?
                    // PageLine([], soft:) : base`). Mirrors `PagedDocumentView
                    // .drawOversizedSelfPasses`/`drawOverprintPasses`'s own branch exactly:
                    // an oversized self-pass ALSO carries its own chain continuation (if
                    // any); a non-oversized fragment's chain (if any) draws directly.
                    let extraPasses: [NSAttributedString]
                    if let selfPass = selfPasses.indices.contains(ord) ? selfPasses[ord] : nil {
                        extraPasses = [selfPass] + (chainPasses.indices.contains(ord) ? chainPasses[ord] : [])
                    } else {
                        extraPasses = chainPasses.indices.contains(ord) ? chainPasses[ord] : []
                    }
                    for pass in extraPasses {
                        for box in Self.passVectors(pass, containerWidth: containerWidth,
                                                     fragmentOrigin: fragment.origin,
                                                     baselineOffset: rendered.baselineOffset,
                                                     pclPrograms: rendered.pclPrograms) {
                            vectors.append(EngineTruth.GraphicBox(
                                x: Double(pageTextFrame.origin.x) + box.x,
                                top: Double(pageTextFrame.origin.y) + box.top,
                                width: box.width, height: box.height, gray: box.gray))
                        }
                    }
                    ord += 1
                    guard effective.length > 0 else { break }
                    index = effective.location + effective.length
                }
            }
            // Job 495 (Class 7 residual, re-diagnosed): LJ6DTP's page-border PCL execution
            // (`PrintedPCLGraphics.swift`, job 490) draws OUTSIDE any `PageTextView`'s own
            // glyph walk — `PagedDocumentView.drawPCLGraphics` is called at the PAGE level,
            // alongside `drawRunningLines`, precisely because the border bleeds past the
            // text container's own margins (that function's own doc comment). The vector
            // walk just above only ever visits `laidOutPage.manager`'s OWN glyph fragments
            // (box-drawing cp437 fills, self-pass/overprint-pass content) — it never asked
            // whether any of those fragments also carried a `.printedPCLProgram` attachment,
            // so this harness's own `vectors` count silently omitted every border rect the
            // app was ALREADY drawing on screen, undercounting the app's real count by
            // exactly 4 (one page-border's top/left/bottom/right rule fills) on every
            // LJ6DTP.WS page carrying an absolute-only PCL program — mistaking a harness
            // blind spot for an app rendering gap (job 494's own Class 7 table: pages 1, 2,
            // 5, 6, 7, 8 each divergent by exactly +4, engine over app). Mirrors
            // `PageTextView.drawPCLGraphics`'s own walk exactly — same attribute key, same
            // anchor arithmetic (`pageTextFrame.origin` here plays `textTop(atPage:)`'s own
            // role) — so this measures what PRODUCTION actually draws. Defaults
            // `includeAbsolute`/`includeRelative` both true: unlike production (split across
            // `drawPCLGraphics`/`drawPCLGraphicsOverlay` purely for their own z-order reasons,
            // `pclRectsInIsolatedPass`'s own doc comment), this harness has no view hierarchy
            // to layer — it counts everything the app really paints, from either call site, in
            // one pass. Page 4's checkerboard (relative-addressed) counts here too now that
            // job 495 closed it (`drawPCLGraphicsOverlay`'s own citation for the mechanism).
            if !rendered.pclPrograms.isEmpty, let storage = laidOutPage.textView.textStorage,
               laidOutPage.glyphs.length > 0 {
                let glyphRange = laidOutPage.glyphs
                laidOutPage.manager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, effectiveGlyphRange, _ in
                    for fill in pclRectsInIsolatedPass(
                        manager: laidOutPage.manager, storage: storage, glyphRange: effectiveGlyphRange,
                        fragment: rect, offset: pageTextFrame.origin, containerWidth: containerWidth,
                        pclPrograms: rendered.pclPrograms) {
                        let r = fill.frame
                        vectors.append(EngineTruth.GraphicBox(
                            x: Double(r.origin.x), top: Double(r.origin.y),
                            width: Double(r.width), height: Double(r.height),
                            gray: Double(fill.gray)))
                    }
                }
            }
            // Job 240 (b13, Part 3): re-key `structuralBodyLines`'s per-REAL-FRAGMENT
            // ordinal onto the same per-RAW-PageLine index `EngineTruth.structuralPages`'s
            // `n` uses. The two disagreed whenever a page opened with (or contained before
            // its first divergence) an `.overprint` chain: job 224 collapses a whole chain
            // into ONE real AppKit fragment (`DocumentRenderer.renderPrinted`'s own `i = j +
            // 1` loop), so `structuralBodyLines`'s `ordinal` undercounts by
            // `chainLength - 1` for every fragment after the chain, while `EngineTruth`
            // still walks `docToPagelines`'s raw (uncollapsed) `PageLine` array — every body
            // line AFTER a chain compared the wrong pair of lines, surfacing as bogus
            // "text"/"y" divergences with no code defect behind them (traced via
            // `ZZProbeJob240Formfeed`, FORMFEED.WS page 1: its opening overprint pair, byline
            // + right-flush word count, shifted every later comparison by one). Every real
            // fragment's own raw span is `1 + overprintPasses[pageIndex][ord].count` (itself
            // plus its captured chain continuations, `RenderedDocument.overprintPasses`'s own
            // doc comment) — walking that gives each real fragment's TRUE raw index.
            let rawBody = AppOutput.remapToRawIndices(
                Oracle.structuralBodyLines(of: laidOutPage, textFrame: pageTextFrame),
                overprintCounts: rendered.overprintPasses.indices.contains(pageIndex)
                    ? rendered.overprintPasses[pageIndex].map(\.count) : [],
                overprintPasses: rendered.overprintPasses.indices.contains(pageIndex)
                    ? rendered.overprintPasses[pageIndex] : [],
                oversizedSelfPasses: rendered.oversizedSelfPasses.indices.contains(pageIndex)
                    ? rendered.oversizedSelfPasses[pageIndex] : [])
            return (running: running, body: rawBody, vectors: vectors)
        }
    }
}

// MARK: - The gate

@Suite struct PrintedStructuralParityTests {
    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateCorpusSupport.ws7Directory.path)) ?? []
        return names.filter { $0.uppercased().hasSuffix(".WS") }.sorted()
    }

    struct Divergence: CustomStringConvertible {
        let fixture: String
        let page: Int
        let detail: String
        /// Signed magnitude (app minus engine) for the checks that carry one — currently only
        /// the `y:` (Class 4) check, job 410's bounded hard-fail. `nil` for every other check
        /// (text/x/size/gray/counts), which has no single-number ruling to bound against.
        var magnitude: Double? = nil
        var description: String { "\(fixture) page \(page): \(detail)" }
    }

    /// Structural divergence for one fixture, both renderers' pages diffed with tolerances:
    /// - text: EXACT (trimmed of surrounding whitespace/newlines only — leading/trailing
    ///   spaces are the indent/pad mechanism itself, already captured by `x`, not the content).
    /// - x/y: 0.5pt, the same tolerance `GeometryOracleTests.swift` already uses throughout —
    ///   below the smallest real WordStar grid unit (a 0.6pt/char Courier advance) so it
    ///   catches genuine placement bugs without flagging floating-point noise.
    @MainActor
    static func divergences(fixtureName: String) throws -> [Divergence] {
        let url = PrivateCorpusSupport.ws7Directory.appendingPathComponent(fixtureName)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "PrintedStructuralParity.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        state.style.setManually(.printed)

        // Same `Document` value both sides render — `state.document`, not a separate `parse`
        // call, so a variant-detection difference between the two can never masquerade as a
        // structural divergence.
        let engine = EngineTruth.structuralPages(for: state.document)
        let app = AppOutput.structuralPages(for: state)

        var out: [Divergence] = []
        let tol = 0.5

        for (i, enginePage) in engine.enumerated() {
            let appPage = i < app.count ? app[i] : (running: [], body: [:], vectors: [])
            let engineHeaders = enginePage.running.filter { $0.kind == .header }
            let engineFooters = enginePage.running.filter { $0.kind == .footer }
            let appHeaders = appPage.running.filter { $0.kind == .header }
            let appFooters = appPage.running.filter { $0.kind == .footer }
            if engineHeaders.count != appHeaders.count {
                out.append(Divergence(fixture: fixtureName, page: i + 1,
                    detail: "header count: engine \(engineHeaders.count) (\(engineHeaders.map(\.text))), app \(appHeaders.count)"))
            }
            if engineFooters.count != appFooters.count {
                out.append(Divergence(fixture: fixtureName, page: i + 1,
                    detail: "footer count: engine \(engineFooters.count) (\(engineFooters.map(\.text))), app \(appFooters.count)"))
            }

            // Only indices BOTH sides agree drew something are comparable — an index present
            // on only one side is a pagination/content disagreement, already covered by
            // `GeometryOracleTests.theAppPaginatesExactlyLikeTheLibrary`, not this gate's job.
            for k in enginePage.body.keys.sorted() {
                guard let e = enginePage.body[k], let a = appPage.body[k] else { continue }
                // Job 403: also strip U+FFFC (object replacement character) — `NSTextStorage`'s
                // OWN string representation of an `NSTextAttachment` (`DocumentRenderer
                // .pctlAdvanceAttachment`'s zero-drawing pctl spacer, `.pixAttachmentString`'s
                // real inline image), a real character position in `NSAttributedString.string`
                // for something that paints nothing (or paints an IMAGE, never comparable as
                // TEXT either way — image content has its own `PixelOracleKit` coverage). The
                // engine's own text never produces this codepoint at all (its "text" is either
                // real characters or, since the pctl-span fix above, nothing), so comparing it
                // literally would fail every pctl-suppressed/PIX line on the U+FFFC alone, with
                // no text-content divergence actually behind it.
                let eText = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                let aText = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                if eText != aText {
                    // Job 403: UNTRUNCATED — a 40-char preview here previously hid the ACTUAL
                    // difference on two LJ6DTP.WS lines entirely (Class 3's own comment,
                    // "past the divergence table's own 40-char preview truncation"): both
                    // sides' first 40 characters were identical, so the printed table showed
                    // no visible discrepancy at all even though the untruncated `#expect`
                    // above still (correctly) failed. The compare itself was never truncated
                    // — only the TABLE's own preview was — so this widens evidence, not the
                    // gate's own strictness.
                    out.append(Divergence(fixture: fixtureName, page: i + 1,
                        detail: "body line \(k) text: engine \(eText.debugDescription), app \(aText.debugDescription)"))
                }
                if abs(e.x - a.x) > tol {
                    out.append(Divergence(fixture: fixtureName, page: i + 1,
                        detail: "body line \(k) x: engine \(e.x), app \(a.x) (Δ\(a.x - e.x)) — \(eText.prefix(24).debugDescription)"))
                }
                if abs(e.yFromTop - a.yFromTop) > tol {
                    out.append(Divergence(fixture: fixtureName, page: i + 1,
                        detail: "body line \(k) y: engine \(e.yFromTop), app \(a.yFromTop) (Δ\(a.yFromTop - e.yFromTop))",
                        magnitude: a.yFromTop - e.yFromTop))
                }
                // Job 210: font SIZE per run — LJ6DTP's banner-to-body-text size range
                // (72pt down to 8pt, per the job brief) is exactly what this catches.
                // 0.5pt tolerance, same as x/y — `entry.points.rounded()` (`resolvedFont`)
                // already rounds to a whole point, so anything bigger than float noise here
                // is a real divergence.
                if abs(e.size - a.size) > tol {
                    out.append(Divergence(fixture: fixtureName, page: i + 1,
                        detail: "body line \(k) size: engine \(e.size), app \(a.size) — \(eText.prefix(24).debugDescription)"))
                }
                // Job 210: fill-gray state — LJ6DTP's knockout (white text, gray 1.0, over
                // a black bar) vs. `DocumentRenderer`'s unconditional `.foregroundColor:
                // NSColor.black` (`attributedRun`). 0.05 tolerance (device-gray round-trip
                // noise), not the 0.5pt geometry tolerance — this is a colour, not a length.
                if abs(e.gray - a.gray) > 0.05 {
                    out.append(Divergence(fixture: fixtureName, page: i + 1,
                        detail: "body line \(k) gray: engine \(e.gray), app \(a.gray) — \(eText.prefix(24).debugDescription)"))
                }
            }

            // Job 210: vector-op layer (box/shade/block/full-block fills). Coarse COUNT
            // comparison — `DocumentRenderer` draws none of these pre-port, so the "before"
            // table shows every graphics-bearing page's true engine count against an app
            // count of 0. Kept as a count rather than a geometry match because the two
            // sides' rects are not independently indexed the way body lines are (no
            // `PageLine`-index key to match on) — a real geometry diff is the follow-up a
            // green count enables, not this harness's job to invent unprompted.
            if enginePage.vectors.count != appPage.vectors.count {
                out.append(Divergence(fixture: fixtureName, page: i + 1,
                    detail: "vector-op count: engine \(enginePage.vectors.count), app \(appPage.vectors.count)"))
            }
        }
        return out
    }

    /// THE DIVERGENCE TABLE — the evidence this job's brief asked for instead of hand-hunting.
    /// Printed unconditionally (visible in test output on every run, pass or fail) and also
    /// asserted: known divergence CLASSES are wrapped in `withKnownIssue` with a citation to
    /// the fix each is waiting on; anything NEW fails the suite outright, so this gate can only
    /// ever get stricter by accident-proofing, never quietly regress further.
    @Test(arguments: ws7Fixtures) @MainActor func structuralParity(fixtureName: String) throws {
        let found = try Self.divergences(fixtureName: fixtureName)
        if !found.isEmpty {
            print("### Structural divergence table — \(fixtureName) ###")
            for d in found { print(d.description) }
        }

        let headerFooterCount = found.filter { $0.detail.hasPrefix("header count") || $0.detail.hasPrefix("footer count") }
        let placementCount = found.filter { $0.detail.contains(" x: ") }
        let verticalCount = found.filter { $0.detail.contains(" y: ") }
        let textCount = found.filter { $0.detail.contains(" text: ") }
        let sizeCount = found.filter { $0.detail.contains(" size: ") }
        let grayCount = found.filter { $0.detail.contains(" gray: ") }
        let vectorCount = found.filter { $0.detail.hasPrefix("vector-op count") }

        // Class 1 — running heads/footers never rendered (DocumentRenderer has no header/
        // footer model at all; see `EngineTruth.Page`'s own doc comment). FIXED in this job —
        // see `DocumentRenderer.renderPrinted`'s header/footer block, added after this harness
        // first ran and found every one of these.
        #expect(headerFooterCount.isEmpty,
                "header/footer divergences (should be fixed): \(headerFooterCount.map(\.description))")

        // Class 3 — body line text content. Job 201 found it diverging on `LJ6DTP.WS`/
        // `YOURWAY.WS` (page 2+ showing a constant per-page content SHIFT — `DocumentRenderer`
        // rendered every line at one uniform document-default lead while `docToPagelines`
        // paginates against a POINTS budget built from each line's REAL advance). Job 202
        // ported the real per-line advance (`DocumentRenderer.swift`'s `advanceLead`, citing
        // `PDFWriter.swift:602-607`) and fixed `YOURWAY.WS` completely. `LJ6DTP.WS`'s own
        // PAGE-COUNT-CAUSED shift (job 202/223/224's isolated-vs-embedded probe residual,
        // app=9 vs engine=8 pages) is FIXED as of job 225 (`PagedDocumentView
        // .buildExplicitPages` sizes each page's container from a probe of the real embedded
        // flow, not an isolated one — `pageCountMatchesEngine` in
        // `OverprintCompositingTests.swift` is the permanent regression coverage).
        //
        // Job 401 (task #62 diagnosis): the residual left after job 225 was NOT one bug —
        // `LJ6DTP.WS` alone dropped 83 -> 8, `OLDTIMES.WS`/`PREVIEW.WS` closed to 0, from two
        // fixes landed this job:
        // 1. This harness's OWN blind spot, not an app defect: `docToPagelines`'s `PageLine
        //    .text` is PRE-substitution for an LJ6DTP document — the driver's character
        //    substitution (`_`->em dash, curly quotes, etc.) runs later, inside
        //    `lineOpsPrinted` (`PDFWriter.swift:509`'s `ljSubstitute`), directly on the
        //    segments about to draw, a step that never writes back into `Page.lines`. Fixed
        //    by applying the SAME substitution (`DocumentRenderer.printedLJ6DTPSubstitute`,
        //    widened `private` -> `internal` this job, confirmed byte-identical against
        //    `PDFDriverLJ6DTP.swift:26-41` fresh this job) when building `EngineTruth`'s own
        //    body-line text — see that call site's own citation.
        // 2. A real app gap: an oversized banner/heading line's REAL AppKit fragment is a
        //    blank single-space placeholder (`DocumentRenderer.renderPrinted`'s own `let
        //    content = oversized ? PageLine([], soft: base.soft) : base`) — job 399 taught
        //    `AppOutput` to read the correct GRAY off the self-pass `DocumentRenderer` drew
        //    instead (Class 6), but never TEXT/SIZE, so every oversized title/H1 read back as
        //    a blank 12pt line. Fixed by extending `AppOutput.remapToRawIndices`/
        //    `firstVisibleInk` to also carry text/size off the self-pass — see that call
        //    site's own citation.
        //
        // Job 403 (task #62, re-measurement): 8 residuals remain, all on `LJ6DTP.WS`,
        // UNCHANGED in count by this job's own vector-op fix (expected — see Class 7 below,
        // whose fix targets `AppOutput`'s vector WALK, never `EngineTruth`'s TEXT). Widening
        // the divergence table's own text preview past 40 chars (this file's own
        // `structuralParity` text-compare, `Divergence`'s own doc comment above) — the SAME
        // change that made job 401's "past-40-char, needs a wider probe" residual #3 legible
        // at all — revealed it and residual #2 are the SAME mechanism, collapsing what job
        // 401/402 tracked as THREE residuals into TWO, both now fully diagnosed:
        // - Graphics-only oversized lines (`LJ6DTP.WS` p1 body line 9, p6 body line 50: a
        //   full-block "█" bar) still read back blank — 2 of the 8. `Oracle
        //   .structuralBodyLines`/`AppOutput`'s "ask the real render path" discipline is
        //   attribute-based (`NSTextStorage` font/colour), but a pure cp437-graphics line
        //   paints ONLY through `PageTextView.drawVectorGraphics`'s `NSRect.fill()` calls
        //   (`PagedDocumentView.swift`) — a SEPARATE painted layer with no text attribute to
        //   read at all, the same class of gap job 211's own doc comment
        //   (`PrintedVectorGraphics.swift` top) already names. STILL not fixed — needs its
        //   own mechanism, not an extension of `firstVisibleInk`, and out of this job's own
        //   scope (item 1 was the VECTOR-op walk, not TEXT-attribute reading).
        // - A 0x0F user-print-control span's decoded display string (`Span.pctlHMI` non-nil
        //   — `"Empty  ┌00.300\"hx00.300\"v ─07.900\" │10.400\" EMPTY   3-dot-wide lines”"`
        //   etc.) — 6 of the 8 (`LJ6DTP.WS` p2 line 4, p3 line 13, p4 line 1, p5/p6/p7 line
        //   0). FIXED this job, and it was never an app defect at all: `PDFWriter
        //   .lineOpsPrinted` (`PDFWriter.swift:466-475`) never draws a pctl span's decoded
        //   text on paper, only advances by its declared HMI width
        //   (`DocumentRenderer.appendSpan`'s own M10/job-371 citation) — the app's blank
        //   `NSTextAttachment` spacer (reading back as U+FFFC) is CORRECT. The divergence was
        //   `EngineTruth`'s own text still being built from `docToPagelines`'s PRE-emission
        //   `PageLine.text`, which still carries the parser's decoded payload string — the
        //   SAME "PageLine.text isn't what the real PDF bytes draw" harness class job 401's
        //   LJ6DTP-substitution fix (above) already named, just a second, driver-independent
        //   instance of it. Fixed the same way: `EngineTruth.structuralPages`'s own text
        //   builder now returns `""` for a `pctlHMI`-carrying span — see that call site's own
        //   citation.
        //
        // Job 404 (task #62, item 3 re-measurement): UNCHANGED at 2 (`LJ6DTP.WS` only) —
        // expected, this job's fix (deleting `.printedGraphicsEligible`, Class 7 below)
        // touches `graphicCells`' FILL decision, never `EngineTruth`/`AppOutput`'s TEXT
        // reading (`firstVisibleInk`/`remapToRawIndices`, untouched this job).
        //
        // Job 405 (task #62, CLOSED): the "graphics-only oversized line has no text
        // attribute to read" citation above was WRONG — re-diagnosed individually
        // (`LJ6DTP.WS` p1 body line 9, p6 body line 50), both are `.overprint`-chain
        // BASES, not attribute-less orphans. Both share their baseline with a LATER chain
        // member that owns the group's only real text (`Oracle.layOut`/`docToPagelines`
        // probe, this job's own report has the full per-line dump): p1 line 9's
        // "█████████████████████" bar chains into line 10 (a second, offset bar) THEN
        // line 11, "     Manual Copyright ☻ 1990 and 1997 by Robert J. Sawyer" — a
        // caption sharing the bar's baseline via a leading-space indent, WordStar's own
        // "print a decorative bar, then overprint a caption beside it" idiom (p6 line 50's
        // "████████████" bar -> line 51 "Black Text on a Gray Background" is the same
        // construct). `EngineTruth.structuralPages`'s group-to-PageLine matching (this
        // file, above) had no notion of which raw `PageLine` actually AUTHORED an op once
        // merged into a shared-Y group — a graphics-only bar produces zero text ops of its
        // own (`PDFWriter.lineOpsPrinted`'s graphics branch is fill-ops only), so the walk
        // handed `contentOp` (the group's first NON-whitespace op) to the BASE line's own
        // raw index purely because it was numerically first, silently dropping the
        // caption's own raw index (11/51) from `page.body` entirely — `text` (built
        // straight from the base's OWN spans) still correctly named the bar, so the
        // resulting `StructuralLine` described two different `PageLine`s at once: the
        // bar's own text, paired with the caption's own size/x/gray. The APP's real
        // fragment for an oversized base is `DocumentRenderer.renderPrinted`'s blank
        // placeholder (`AppOutput.remapToRawIndices`'s own self-pass branch is what fixes
        // that — see its own citation), so `app` read blank/12pt: correct against ITS OWN
        // (fixed) model, wrong only against the engine side's own mixed-up value. FIXED at
        // the actual fault: a `PageLine` whose own text is entirely whitespace and/or
        // `graphicChars` (the app's own byte-verified port, job 404, `@testable import
        // SoftReturn` already relied on for `graphicCells` in `passVectors` above) now
        // skips the group match ENTIRELY — the SAME "true blank" treatment this loop
        // already gives an ordinary empty line — leaving the group for whichever LATER
        // chain member actually owns it. Re-measured: 0 across the FULL 16-fixture
        // matrix — every `ws7Fixtures` entry's body-line text now matches the engine's
        // exactly. CLOSED — flipped to a hard assertion (was `withKnownIssue`, 2 divergent
        // (fixture, line) pairs before this job, both this SAME mechanism).
        #expect(textCount.isEmpty, "text-content divergences: \(textCount.map(\.description))")

        // Class 2 — horizontal placement of WS5+ proportional-font blocks. RECLASSIFIED job
        // 240 (b13, Part 2; MAC VIEWING RULING): this is no longer "not yet ported" — job 229's
        // per-word AFM x Tz corrective-kern port (`PrintedWordAnchor.swift`, the mechanism this
        // class used to describe closing) was REMOVED, on purpose. A proportional run now lays
        // out at its resolved Mac font's own NATURAL advance; that advance will never
        // bit-for-bit match the engine's base-14/HMI-grid PDF positions, and per the ruling it
        // is not supposed to — font-identity divergence is explicitly OUT of this gate's scope
        // (this file's own top doc comment). This class stays a `withKnownIssue` for
        // MECHANICAL reasons only (the assertion needs somewhere to record real per-fixture
        // divergences without failing the suite), not because it is still open work.
        // `isIntermittent: true` — not every fixture HAS a placement divergence (plain
        // Courier-only fixtures already match), and `withKnownIssue` itself fails a fixture
        // where the wrapped expectation never actually fails ("known issue was not recorded")
        // unless told the issue is intermittent, not universal.
        withKnownIssue("""
            \(fixtureName): WS5+ proportional-font BODY TEXT placement diverges from the \
            engine's PDF grid by design (\(placementCount.count) found) — job 240, b13 Part 2, \
            MAC VIEWING RULING (decision register 2026-08-11; skill registry #25): natural \
            Mac-font advance, not an AFM/Tz-scaled reproduction of it. PERMANENTLY expected, \
            not a gap to close.
            """, isIntermittent: true) {
            #expect(placementCount.isEmpty, "x-placement divergences: \(placementCount.map(\.description))")
        }

        // Class 4 — vertical (y) position. GEOMETRY per the ruling (this file's own top doc
        // comment) — the TARGET is hard-fail, unlike class 2. The DISCRETE-JUMP shape (a whole
        // extra/missing ordinary lead landing at one specific line) is FIXED as of job 245:
        // `advanceLead` was charging a fragment's height from the NEXT line's lead
        // (`page[i+1].lead`) rather than its own (`page[i].lead`) — invisible on any
        // uniform-lead page (both reads agree there), and wrong by exactly one ordinary lead
        // at a `.lh` transition, because a fragment's baseline sits at an offset from its own
        // top that itself depends on that fragment's own pinned height (proof: `firstBaseline
        // Offset`'s own doc comment above, on why that figure can't be derived by hand either).
        // Reading `page[i].lead` — matching `pageStream`'s own `line[n].lead` exactly
        // (`PDFWriter.swift:602-607`) — fixed FORMFEED.WS's all-8-pages residual (job 232 class
        // b) with no regression on any other fixture. Still open, UNCHANGED by this job: the
        // GRADUALLY ACCUMULATING sub-pixel drift jobs 201/202/225/227 already documented
        // ("AppKit line-height pinning isn't bit-exact") — a different shape entirely (grows a
        // fraction of a point per fragment, not a whole lead at one line), reproducible on
        // plain Courier fixtures like BOXES.WS that have no `.lh` transition at all, so it
        // cannot be the same defect.
        //
        // Job 403 (task #62, item 3 — the one remaining slice after this job's Class 3/5/7
        // work): measured with numbers, across all 16 `ws7Fixtures` (this file's own count —
        // not 14; see this job's own report). 1,362 total divergent (fixture, line) pairs
        // across 9 fixtures: `BOXES.WS` 87, `DARKNESS.WS` 5, `FORMFEED.WS` 119, `LJ6DTP.WS`
        // 217, `OLDTIMES.WS` 499, `PREVIEW.WS` 2, `SCRIPT.WS` 80, `WARPRAYR.WS` 4,
        // `WORDSTAR.WS` 349; 7 fixtures (`BOX.WS`, `CONVERT.WS`, `LAYOUT.WS`, `POWERUSE.WS`,
        // `STRENGTH.WS`, `VERSIONS.WS`, `YOURWAY.WS`) are already 0. Per-line magnitude
        // confirmed still the documented ACCUMULATING shape, not a new discrete-jump defect:
        // `OLDTIMES.WS` page 1 grows line over line (0.59pt at body line 8) then PLATEAUS at a
        // constant 1.49pt offset for the rest of the page — consistent with a fixed per-
        // fragment sub-pixel remainder, not unbounded drift. The largest magnitudes in the
        // whole matrix (41 lines at 10-16pt, ALL on `LJ6DTP.WS`'s two most heavily `.overprint`
        // -chained pages, 1 and 6 — job 401's own "one 3-deep chain... four more on page 6")
        // still GROW CONTINUOUSLY line over line rather than jumping discretely at one line
        // (checked directly: page 6's own sequence climbs 10.1pt -> 15.8pt smoothly across
        // body lines 24-50) — the same rounding-noise shape at a higher chain density, not the
        // job-245 discrete-jump defect returning. Kept as `withKnownIssue` for that residual
        // only.
        //
        // Job 404 (task #62, item 3 re-measurement): UNCHANGED — same 9 fixtures, same 1,362
        // total, same per-fixture counts job 403 recorded above. Expected: this job's fix
        // (deleting `.printedGraphicsEligible`, Class 7 below) only changes WHICH characters
        // paint as vector fills, never any fragment's Y origin.
        //
        // Job 408 (task #62, item 3 — DIAGNOSIS, no fix landed; see the job's own report for
        // the full arithmetic): the "gradually accumulating" framing above does not survive
        // per-line measurement. Read directly off `Oracle.lines`' own `fragment.origin.y`/
        // `location(forGlyphAt:).y` against `EngineTruth`'s analytic y: `BOXES.WS`'s real
        // fragment TOPS step by EXACTLY 12.0pt every line (bit-exact — no AppKit rounding in
        // the fragment height at all); its divergence is a CONSTANT -1.0pt present from the
        // fixture's first comparable text line onward, never growing. `OLDTIMES.WS` page 1
        // shows the same shape at a different scale: discrete +0.348pt/-0.652pt STEPS at
        // specific lines, interleaved with long runs of bit-exact 12.0pt steps — not a smooth
        // per-line accumulation either.
        //
        // Root trigger, isolated by comparing each real fragment's own baseline-minus-top
        // offset (`location(forGlyphAt:).y` relative to `fragment.origin.y`): `BOXES.WS`
        // toggles between 9.0pt — every blank-filler `PageLine` AND every graphics-only
        // box-border `PageLine` (both render an all-whitespace `NSTextStorage` run; the real
        // ink is a vector overlay, `PrintedVectorGraphics.swift`) — and 8.0pt — every
        // `PageLine` with real printable-character content — under the IDENTICAL pinned
        // `minimumLineHeight == maximumLineHeight` paragraph style. The fixture's own first
        // line (a graphics-only box-top border) lands EXACTLY on the engine's own Y at its
        // 9.0pt offset, proving 9.0 — not 8.0 — is the value the engine's model implicitly
        // assumes; every real-text line's 8.0pt offset is the actual 1pt shortfall. This does
        // NOT reproduce in an isolated single-line `NSLayoutManager` probe (identical font/
        // size/pinned style; " "/"X"/"M"/a box-drawing char all measured 9.0pt alone) — it
        // only appears inside the real multi-paragraph, multi-page `PagedDocumentView`
        // container chain, not as a per-glyph font-metrics fact reproducible in a minimal
        // repro. `attributedLine`'s own blank-line space-filler doc comment ("one space...
        // gives the layout manager a real glyph to place normally, so a blank line's baseline
        // sits on the same grid a line of text would") is WRONG as written: measured
        // directly, the filler's 9.0pt offset does NOT match real text's 8.0pt — it matches
        // the ENGINE's assumption instead, coincidentally, not because a real glyph places
        // "normally." See that comment's own correction (`DocumentRenderer.swift`).
        //
        // Not fixed: no isolated repro exists to validate a change against safely, and no
        // candidate lever inspected only touches the actual defect (swapping the blank-line
        // filler character only moves the SIDE OF THE GAP THAT ALREADY MATCHES the engine;
        // the real-text lines are what sit 1pt off, and nothing here explains WHY the full
        // container-chain context shifts their offset when an isolated probe does not).
        // Decision brief for Jon was this job's own report — pin every line's Y explicitly
        // from the engine's own per-line data (the `resolveFont`/job-393/396-style direction)
        // vs. accept a documented, MEASURED, bounded (never unbounded — every fixture's own
        // delta sequence plateaus) view-vs-print tolerance.
        //
        // Job 410 (Jon's ruling, 2026-08-19, verbatim): "A is fine as long as it's limited to
        // that 1 pt. Anything more must be flagged as a failure." Option (b) of job 408's
        // brief, chosen — CONVERTED to a HARD, BOUNDED assertion, `withKnownIssue` removed
        // entirely. Every comparable line's y delta must sit at or under 1.0pt absolute; job
        // 408's own measured inventory (`BOXES.WS`'s constant -1.0pt, `OLDTIMES.WS`'s
        // sub-point +0.348/-0.652 steps) sits inside the bound with room to spare. No
        // per-fixture exception, no `isIntermittent` carve-out — a fixture with zero vertical
        // divergences simply passes trivially, same mechanics as Class 3/5/6/7 above.
        //
        // NOT closed as of job 410's own full-16-fixture sweep (real, disclosed gate-red,
        // bound not widened to hide it): `DARKNESS.WS` (2 lines), `OLDTIMES.WS` (34 lines,
        // p1 only), `WARPRAYR.WS` (1 line), `LJ6DTP.WS` badly (~190 lines, all 8 pages, up to
        // Δ15.8 on p3).
        //
        // Job 411 (task #62, ROOT-CAUSED, all 4 — no fix landed, see this job's own report
        // for the full per-line arithmetic): every single one of these 202 violating lines is
        // the SAME mechanism job 408 already isolated for `BOXES.WS`/`OLDTIMES.WS` at
        // sub-bound scale, now proven — by direct measurement of `fragment.origin.y +
        // location(forGlyphAt:).y` against `AppOutput`'s own `textFrame.origin.y` — to be a
        // single unbounded root cause, not four separate defects:
        //
        // Under `paragraphStyle(lead:)`'s pinned `minimumLineHeight == maximumLineHeight`,
        // AppKit does NOT place a fragment's baseline at a fixed offset from its own top —
        // that offset (`K = fragment.height - (baseline - fragment.top)`, the "headroom"
        // AppKit reserves above the baseline inside the pinned box) is a near-constant
        // PER FONT/STYLE, empirically: plain Courier real text measures K≈4.0, a blank/
        // graphics-only filler K≈3.0 (job 408's own BOXES.WS figures, confirmed unchanged),
        // a proportional heading font on `LJ6DTP.WS`'s title stack K≈4.35, a DIFFERENT
        // proportional run inside an `.overprint` chain K≈3.325, `DARKNESS.WS`'s bold
        // all-caps title K≈7.0 — five distinct real values measured this job, all under the
        // IDENTICAL pinned lead. Because AppKit stacks fragment N's TOP at fragment (N-1)'s
        // own top plus (N-1)'s own pinned HEIGHT (a real, always-correct invariant — the
        // pinned heights themselves, `advanceLead`/`fragmentLead`, are never wrong), while
        // the BASELINE inside each fragment lands at `top + K(this fragment's own content)`,
        // a run of same-K neighbours advances in perfect lockstep with the engine's own
        // `y -= line.lead` formula (K cancels — this is why `DARKNESS.WS`/`WARPRAYR.WS`'s
        // ~50-line bodies of PLAIN prose sit at a constant, in-bound -1.0pt exactly like
        // `BOXES.WS`) — but every TRANSITION between two DIFFERENT-K neighbours leaves a
        // permanent, uncorrected `ΔK` gap that every LATER fragment on the page inherits
        // (AppKit never re-centers a later fragment to compensate for an earlier one's own
        // offset). `DARKNESS.WS`/`WARPRAYR.WS` each hit this ONCE (a single styled title or
        // stray larger-font character early on the page, K≈7 or similar vs the surrounding
        // K≈4, a one-time -4.0ish pt jump that never grows further because every line after
        // it is uniform prose again) — isolated, low-multiplicity, barely over the bound.
        // `OLDTIMES.WS` p1's title block packs a DOZEN such transitions into 25 lines
        // (title/blank/author/blank/copyright-block/blank/award-blocks/blank/finalist-block,
        // each its own font-or-blank K) — the 34 violating lines are every line from the
        // block's own first transition onward, each carrying the FULL accumulated sum of
        // every `ΔK` before it, not 34 independent defects. `LJ6DTP.WS` is the same
        // mechanism at its worst: its title stack, several `.overprint` chains (job 224) and
        // oversized self-passes (job 227/269) each introduce their OWN `ΔK` (an
        // oversized/chain-base line's REAL fragment is the BLANK placeholder,
        // `DocumentRenderer.renderPrinted`'s own `content = oversized ? PageLine([], ...) :
        // base` — K≈3.0, the "blank" figure, regardless of how large or styled the VISIBLE
        // self-pass content actually is), and a heavily `.overprint`-chained page like p3/p6
        // stacks a dozen-plus such transitions in a few dozen lines, compounding to the
        // measured Δ15.8 exactly the same arithmetic way. Verified line-by-line for all 4
        // fixtures this job (a temporary probe, `ZZProbeJob411.swift.unused`, dumped every
        // real fragment's `fragTop`/`baseOff`/computed `K`/absolute baseline against
        // `EngineTruth`'s own `yFromTop`): the `gap(n-1→n) = H(n) + K(n-1) - K(n)` formula
        // reproduces every measured delta exactly (e.g. `OLDTIMES.WS` raw line 8's real
        // 11.0pt gap = its own pinned 12.0pt height + blank K 3.0 - text K 4.0), and the
        // violation COUNT this job's sweep found — 165/34/2/1 (of an estimated ~190/34/2/1;
        // the 165 undercounts `LJ6DTP.WS` only because the probe's own line cap, not because
        // any violation traces to a different cause) — accounts for the ENTIRE job 410
        // inventory with zero residue.
        //
        // NOT FIXED: `job 396`'s headroom reservation and `job 395`'s verse-lead multiple —
        // this job's brief's two other suspects — are BOTH RULED OUT directly: `headroom`
        // only offsets `PagedDocumentView`'s on-screen SCROLL CANVAS (`PagedDocumentView
        // .headroom(atPage:)`'s own doc comment), never `RenderedDocument.textFrame`, which
        // is the only figure this test (or any real AppKit fragment position) reads; no verse
        // content appears in any of the 4 fixtures' violating lines. `firstBaselineOffset`
        // (the SAME single-glyph-in-isolation measurement `RenderedDocument.textFrame`'s own
        // container-top math depends on) does not predict a real in-context fragment's own K
        // either — job 408 already proved this for plain Courier text (isolated K 9.0 vs
        // in-context 8.0/9.0 by content class); this job confirms the SAME non-reproducibility
        // for every OTHER font/style measured, which is why no isolated per-font correction
        // table can be built without literally re-running the full multi-page layout once to
        // discover it — i.e. job 408's own option (a) ("pin every line's Y explicitly from
        // the engine's own per-line data, overriding AppKit's own baseline placement per
        // fragment"), not a bounded local fix. Per this job's own brief ("anything unbounded
        // gets a precise decision brief, do NOT widen the bound or re-wrap in
        // withKnownIssue"): the bound stays exactly as job 410 landed it, hard-failing these
        // 4 fixtures honestly. Jon's own choice remains open between job 408's (a) (a real,
        // possibly substantial rendering-architecture change) and living with these 4
        // fixtures permanently red under this bound.
        let class4OverBound = verticalCount.filter { ($0.magnitude.map(abs) ?? .infinity) > 1.0 }
        #expect(class4OverBound.isEmpty, """
            vertical origin divergences exceeding the 1.0pt bound (job 410, Jon's ruling \
            2026-08-19, verbatim: "A is fine as long as it's limited to that 1 pt. Anything \
            more must be flagged as a failure."): \(class4OverBound.map(\.description))
            """)

        // Class 5 — font SIZE per run (job 210, b11 leg 3). Jon's directive: LJ6DTP's
        // banner-to-body-text size range (72pt down to 8pt) was never checked page by
        // page against the engine before this job. `resolvedFont` already reads
        // `entry.points`, so this class exists to PROVE that wiring is actually correct
        // under the fixed per-line-height paragraph style `renderPrinted` uses, not to
        // assume it from reading the code.
        //
        // Job 401 (task #62 diagnosis): every real divergence found was the SAME oversized-
        // line self-pass gap Class 3 above cites (the blank placeholder's own size is the
        // document default, 12pt, never the banner/H1's real size) — `LJ6DTP.WS` alone
        // dropped 16 -> 5, `OLDTIMES.WS`/`PREVIEW.WS` closed to 0, from that one fix. No
        // separate font-resolution defect (`resolvedFont`) was ever the cause. The remaining
        // 5 are the graphics-only-oversized-line residual Class 3 also names (the "█" bar,
        // which has no attribute-based size to read at all). Job 403 (task #62,
        // re-measurement): UNCHANGED at 5 — expected, this job's own fixes (the Class 7
        // vector-op walk; the Class 3 pctl-span text fix) never touch SIZE reading
        // (`AppOutput.remapToRawIndices`/`firstVisibleInk`), only vector-fill counting and
        // `EngineTruth`'s text builder respectively. Job 404 (task #62, item 3
        // re-measurement): UNCHANGED at 5 — same reasoning, this job's fix only touches
        // `graphicCells`' FILL decision.
        //
        // Job 405 (task #62, CLOSED): job 401's "graphics-only-oversized-line, no
        // attribute to read" citation was WRONG for 3 of the 5 — `LJ6DTP.WS` p6 body
        // lines 22/30/39 are ORDINARY (non-oversized) `.overprint`-chain bases, each a
        // "bar, then a caption beside it" pair like Class 3's p1/p6 residuals above
        // (line 22's bar chains into line 23 "White Text on a Black Background — Wow!";
        // line 30 -> line 32 "WordStar for DOS is a perfect..."; line 39 -> line 40 (a
        // second bar) -> line 41 "PRETTY NEAT, HUH?"). Their own real AppKit fragments
        // are NOT blank placeholders (not oversized), so `body[ord]` already measured
        // their OWN bar's genuinely correct size (14/13/12pt, matching each bar's own
        // declared font block exactly — confirmed via the same `docToPagelines` probe
        // Class 3 cites) — the divergence was `EngineTruth`'s size (12/10/16pt), which,
        // per that same group-to-PageLine mismatch, was actually the CAPTION's own
        // declared size (Optima 12pt / Garamond 10pt / Aachen 16pt respectively), stolen
        // by the walk's "first non-whitespace op wins, whichever raw index asks first"
        // rule. The other 2 (p1 line 9, p6 line 50) are the SAME oversized+chain-base
        // double fault Class 3 above closed. All 5 fixed by that ONE `EngineTruth`
        // group-matching correction (Class 3's own citation) — no separate change needed
        // here; `AppOutput.remapToRawIndices`/`firstVisibleInk` (the size-READING half)
        // were never wrong for the 3 non-oversized cases, only the number being compared
        // against was. Re-measured: 0 across the FULL 16-fixture matrix. CLOSED —
        // flipped to a hard assertion (was `withKnownIssue`, 5 divergent (fixture, line)
        // pairs before this job).
        #expect(sizeCount.isEmpty, "size divergences: \(sizeCount.map(\.description))")

        // Class 6 — knockout text (white-on-black groups, job 210) — CLOSED, job 399.
        // `DocumentRenderer.attributedRun` already ported the colour decision (job 210's
        // `driverColour`/`printedLJ6DTPColourGray`, byte-identical to `colourGrayLJ6DTP`,
        // `PDFDriverLJ6DTP.swift:15-19`) — it was never hardcoding black by the time this
        // job ran (that finding, job 382's audit, was stale). The real remaining blockers,
        // both fixed this job:
        // - `DARKNESS.WS`: `attributedRun`'s own `.fnref` footnote-marker tint
        //   (`NSColor.darkGray`) stomped a run's real colour unconditionally — the engine
        //   never colours an `.fnref` span at all (no `CtrlKD` emitter branches on it for
        //   colour), so the tint was a pure app decoration with no engine counterpart.
        //   Removed — see `attributedRun`'s own doc comment at the call site.
        // - `LJ6DTP.WS`: the harness's OWN measurement gap, not a rendering bug.
        //   `DocumentRenderer.renderPrinted` deliberately leaves an oversized banner line's
        //   (or an `.overprint` chain's base line's) REAL AppKit fragment BLANK and draws
        //   its true content through a separate pass (`oversizedSelfPasses`/
        //   `overprintPasses`) `Oracle.structuralBodyLines` never reads (it only sees
        //   `page.textView.textStorage`). `AppOutput.bestKnownGray` (this file) now reads
        //   colour straight off that pass's own attributed string when the real fragment is
        //   the blank placeholder — no real AppKit layout needed for a COLOUR attribute,
        //   same "ask the real render path" discipline `structuralBodyLines` already uses
        //   for geometry. Preferring the chain's LAST pass matches the engine's own
        //   painter's-model compositing (`PDFWriter.swift`'s content stream: later ops paint
        //   over earlier ones) and `PageTextView.drawOverprintPasses`'s own documented
        //   invariant that the knockout text is always last in the chain.
        // See also `knockoutTextPaintsVisibleInkOverItsFill`/
        // `knockoutRunsClassifyTheSameWayTheEngineDoes` below — the dedicated pixel-contrast
        // and engine-verdict-class regression coverage this closure needed.
        #expect(grayCount.isEmpty, "gray/colour divergences: \(grayCount.map(\.description))")

        // Class 7 — the vector-op layer (box-drawing arms, shades, part blocks, full
        // blocks, and — job 402 — `symbolShapes`' disc/polygon sub-shapes —
        // `PDFDriverLJ6DTP.swift`'s `graphicOps`). FIXED in job 211
        // (`PageTextView.drawVectorGraphics`/`graphicCells`, `PrintedVectorGraphics.swift`):
        // BOXES.WS (3481 ops), FORMFEED.WS (1280), OLDTIMES.WS (20), SCRIPT.WS (88), and
        // WORDSTAR.WS (20) all match the engine's own count exactly, page by page.
        //
        // Job 401 (task #62 diagnosis) root-caused SOME of the residual to `graphicChars`
        // (`PrintedVectorGraphics.swift`) never porting the engine's own fifth set,
        // `symbolShapes` (`PDFDriverLJ6DTP.swift:131-173` — card suits ♥♦♣♠, ☻/☼ smiley/sun,
        // ≡ triple bar) — and guessed the SAME cause explained the small residual counts on
        // `BOX.WS`/`BOXES.WS`/`CONVERT.WS`/`POWERUSE.WS`/`STRENGTH.WS`/`VERSIONS.WS`. Job 402
        // ported `symbolShapes` (`GraphicShape` enum — `.rect`/`.disc`/`.poly` —
        // `PrintedVectorGraphics.swift`, wired at all three `PagedDocumentView.swift` call
        // sites job 401 cited, plus widened `EngineTruth.scanOps` — this file — to replay
        // `m`/`l`/`c` path ops so a disc/poly fill counts as a vector op on the ENGINE side
        // too, not just the app's) and re-measured every fixture job 401 named:
        // - `LJ6DTP.WS` pages 3 and 7 (the two pages job 401's own diagnosis matches exactly —
        //   both exercise the card-suit/smiley/sun/bar substitution tables) now match the
        //   engine's count EXACTLY — CLOSED by this port.
        // - `LJ6DTP.WS` pages 1 and 6 diverged, by the SAME count both before and after this
        //   port (162/130 and 125/66) — proving `symbolShapes` was never the cause there.
        //   Direct evidence: the divergent ops on both pages land on the SAME `.overprint`-
        //   chain-base bar lines Class 3/5's own comments diagnose (page 1 body line 9,
        //   page 6 body lines 22/30/39/50 — full-block bars, job 405 traced the exact
        //   mechanism). CLOSED in job 403 (task #62, item 1): `AppOutput.structuralPages`'s
        //   vector walk (this file) previously only walked `laidOutPage.glyphs`/`manager
        //   .lineFragmentRect` — the REAL base text-container fragments — but an oversized
        //   line's REAL fragment is `DocumentRenderer.renderPrinted`'s blank single-space
        //   placeholder; its true cp437 content paints through a SEPARATE self-pass/
        //   overprint-pass overlay this walk never visited. Fixed on BOTH sides of the same
        //   gap: `AppOutput.structuralPages`'s vector walk (this file) now also replays
        //   `oversizedSelfPasses`/`overprintPasses` per real-fragment ordinal (`passVectors`,
        //   this file's own citation) for MEASUREMENT; separately, and independently, a REAL
        //   production drawing gap in the SAME mechanism (`PagedDocumentView
        //   .drawOversizedSelfPasses` drew an oversized self-pass's own GLYPHS but never its
        //   `graphicCells` FILLS — unlike its own chain-continuation passes, which always
        //   did) meant an oversized graphics-only line's true content never painted on
        //   SCREEN either, not just in this harness's count — fixed at that call site, cited
        //   there. `LJ6DTP.WS` pages 1/6 now match the engine's own count EXACTLY, closing
        //   both of job 401's two originally-cited pages (3/7 by job 402, 1/6 by this job) —
        //   confirmed via a git-stash A/B against the pre-403 baseline (same technique job
        //   402 used): both pages' counts moved from a nonzero divergence to 0, and all six
        //   fixtures below moved by exactly ZERO (not a regression).
        // - `BOX.WS`/`BOXES.WS`/`CONVERT.WS`/`POWERUSE.WS`/`STRENGTH.WS`/`VERSIONS.WS`: job
        //   401's `symbolShapes` attribution was WRONG (job 402 already confirmed this — none
        //   contains a `symbolShapes` character). Job 403 (task #62, item 2 re-measurement)
        //   DIAGNOSED the real cause, complete with mechanism: every divergent line's own
        //   graphic-bearing `Span` has `span.font == nil` — a FONTLESS run (no WS5+ font
        //   block in force, `BOX.WS`/`CONVERT.WS`/`POWERUSE.WS`/`STRENGTH.WS`/`VERSIONS.WS`
        //   are plain WS4 files with `doc.fonts.isEmpty`; `BOXES.WS` is WS5+ but its own
        //   FIRST box, lines 0-6, sits BEFORE the document's first font change). Job 403
        //   attributed the app's own then-existing `.printedGraphicsEligible` gate
        //   (`PrintedVectorGraphics.swift`) to a PORT of `PDFDriverLJ6DTP.swift`'s
        //   `splitGraphics`'s `seg.entry != nil` guard — CORRECTED by job 404 (task #62,
        //   item 1): that guard never existed. `splitGraphics` (`PDFDriverLJ6DTP.swift:
        //   315-336`) and `lineOpsPrinted` (`PDFWriter.swift:545`, the actual op-emitting
        //   gate) both test ONLY `seg.text.contains(where: { graphicChars.contains($0) })`
        //   — `seg.entry` is read later in the SAME branch purely to pick a pitch
        //   (proportional vs `spanPitch`), never to exclude a fontless span from the vector
        //   path. CP437 decoding is UNIVERSAL (`CP437.swift`'s own top doc comment)
        //   regardless of any font block, so there was never a real ambiguity for a
        //   font-block flag to resolve. Fixed by deleting `.printedGraphicsEligible`
        //   entirely — `graphicCells` (`PrintedVectorGraphics.swift`) now mirrors the
        //   engine's own single-condition gate (character-set membership, already checked
        //   one line above the deleted guard) exactly, with no font-derived exclusion at
        //   all. Quantitatively exact on `BOX.WS`/`BOXES.WS` before the fix: `BOX.WS`'s
        //   entire fixture IS that fontless 7-line box (engine 112, app 0); `BOXES.WS`
        //   repeats the IDENTICAL box verbatim as its own first 7 lines (fontless) plus two
        //   more copies AFTER its first font change (font-eligible, already matching) —
        //   `BOXES.WS`'s residual (616 - 504 = 112) equalled `BOX.WS`'s own total exactly.
        //
        // Re-measured after the fix (job 404): 0 across the FULL 16-fixture matrix — every
        // fixture this comment named, plus every other `ws7Fixtures` entry, now matches the
        // engine's vector-op count exactly, page by page. CLOSED — flipped to a hard
        // assertion (was `withKnownIssue`, 8 divergent (fixture, page) pairs before this
        // job, all on the fontless-span mechanism above).
        #expect(vectorCount.isEmpty, "vector-op divergences: \(vectorCount.map(\.description))")
    }

    // MARK: - Class 6 closure evidence (job 399)

    /// Rendered-ink check: a knockout run's glyphs must be VISIBLE against their own fill,
    /// not merely correctly ATTRIBUTED — every check above (including `grayCount`) compares
    /// colour ATTRIBUTES on `NSTextStorage`, never actual painted pixels, so a compositing
    /// z-order bug (fill drawn on top of text, or vice versa in the wrong place) could pass
    /// every one of them while still shipping invisible ink. Captures the real render path
    /// (`PixelOracleAppEngine.renderApp` — the same `cacheDisplay` capture
    /// `PixelOracleAppEngineTests` already trusts app-vs-engine pixel comparisons to) and
    /// samples over the knockout bar's own real geometry (`AppOutput.structuralPages`'s
    /// `.vectors`, the SAME `graphicCells` fill rects `PageTextView.draw(_:)` paints from —
    /// job 211's "one derivation, not two" discipline, so this probe can't disagree with
    /// what actually painted about WHERE the bar is).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func knockoutTextPaintsVisibleInkOverItsFill() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("LJ6DTP.WS")
        let state = try Oracle.state(for: url)
        let structural = AppOutput.structuralPages(for: state)

        // LJ6DTP's driver fill bands (colour indices 9-14, `printedLJ6DTPColourGray`'s own
        // table) render as a mid-gray, distinct from white paper (1.0) and plain black body
        // text (0.0) — the punch-out bar under "Manual Copyright..." (page 1) is built from
        // these.
        let fillBoxes = structural[0].vectors.filter { $0.gray > 0.3 && $0.gray < 0.7 }
        #expect(!fillBoxes.isEmpty,
                "vacuity guard: LJ6DTP.WS page 1 produced no driver-fill vector boxes to probe")
        guard !fillBoxes.isEmpty else { return }
        let minX = fillBoxes.map(\.x).min()!
        let maxX = fillBoxes.map { $0.x + $0.width }.max()!
        let minTop = fillBoxes.map(\.top).min()!
        let maxTop = fillBoxes.map { $0.top + $0.height }.max()!
        let barRect = CGRect(x: minX, y: minTop, width: maxX - minX, height: maxTop - minTop)

        let images = try PixelOracleAppEngine.renderApp(fixtureURL: url)
        let page = try #require(images.first, "no rendered app page to sample")
        let bitmap = page.bitmap
        let scaleX = CGFloat(bitmap.pixelsWide) / page.pointSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / page.pointSize.height

        var minGray = 1.0
        var maxGray = 0.0
        let stepsY = 24
        let stepsX = 96
        for sy in 0...stepsY {
            let pt = barRect.minY + (CGFloat(sy) / CGFloat(stepsY)) * barRect.height
            guard pt >= 0, pt < page.pointSize.height else { continue }
            let py = min(bitmap.pixelsHigh - 1, max(0, Int(pt * scaleY)))
            for sx in 0...stepsX {
                let ptx = barRect.minX + (CGFloat(sx) / CGFloat(stepsX)) * barRect.width
                guard ptx >= 0, ptx < page.pointSize.width else { continue }
                let px = min(bitmap.pixelsWide - 1, max(0, Int(ptx * scaleX)))
                guard let gray = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceGray)?.whiteComponent
                else { continue }
                minGray = min(minGray, Double(gray))
                maxGray = max(maxGray, Double(gray))
            }
        }

        #expect(minGray < 0.75, """
            no dark fill pixel found inside the knockout bar's own region (min=\(minGray)) \
            — the bar itself did not paint
            """)
        #expect(maxGray - minGray > 0.2, """
            no visible contrast inside the knockout bar (min=\(minGray), max=\(maxGray)) \
            — the knockout text is not visible against its fill
            """)
    }

    /// Engine-verdict parity: for every run the ENGINE's own real PDF bytes classify as WHITE
    /// (knockout, gray > 0.95 — `EngineTruth`, unchanged by this job), the APP's own real
    /// rendered attribute (`AppOutput`, this job's `bestKnownGray` fix) must classify the
    /// SAME way for the SAME raw `PageLine` index. A colour CLASS (near-white), not a
    /// bit-exact float compare — coarser and more robust than `structuralParity`'s own
    /// `grayCount`, so a future retuning of that harness's tolerance can't silently stop
    /// catching a real knockout regression here. "Consume its verdict, don't re-derive": this
    /// asks the engine what it decided, then asks the app the identical question about the
    /// identical run, rather than re-computing either side's colour from `printerDriver`/
    /// palette tables by hand.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func knockoutRunsClassifyTheSameWayTheEngineDoes() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("LJ6DTP.WS")
        let state = try Oracle.state(for: url)
        let engine = EngineTruth.structuralPages(for: state.document)
        let app = AppOutput.structuralPages(for: state)

        var sawKnockout = false
        for (pageIndex, enginePage) in engine.enumerated() {
            for (k, e) in enginePage.body where e.gray > 0.95 {
                guard let a = app[pageIndex].body[k] else { continue }
                sawKnockout = true
                #expect(a.gray > 0.9, """
                    raw index \(k) on page \(pageIndex + 1): engine classifies this run WHITE \
                    (knockout, gray \(e.gray)) but the app renders it at gray \(a.gray) — \
                    \(e.text.debugDescription)
                    """)
            }
        }
        #expect(sawKnockout, """
            vacuity guard: LJ6DTP.WS produced no engine-classified white/knockout run to check \
            — the fixture no longer exercises this class
            """)
    }

    // MARK: - Class 7 closure evidence (job 402: symbolShapes port)

    /// Geometry law: every `symbolShapes` character produces the SAME NUMBER of `GraphicCell`
    /// fills as its own table entry (`PrintedVectorGraphics.swift`'s `symbolShapes`), each one
    /// a real, non-degenerate shape — not the placeholder every one of the seven fell through
    /// to before job 402 (this file's own Class 7 comment, job 401: "still fall through to the
    /// ordinary (missing-glyph) text path instead of drawing as vectors at all"). Runs
    /// `graphicCells` directly against an isolated single-character line
    /// (`isolatedLineLayout`, the SAME technique `PageTextView.drawOverprintPasses` uses for a
    /// real overprint pass) rather than a full fixture — this is a unit law about the DATA
    /// MODEL, independent of any one document's layout.
    @Test @MainActor func symbolShapesProduceRealGeometryNotAPlaceholder() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        for (ch, shapes) in symbolShapes {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.black,
            ]
            let text = NSAttributedString(string: String(ch), attributes: attrs)
            let isolated = try #require(isolatedLineLayout(text, width: 100),
                                         "\(ch): no isolated layout produced")
            let cells = graphicCells(manager: isolated.manager, storage: isolated.storage,
                                      glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect)
            let cell = try #require(cells.first, "\(ch): produced no GraphicCell at all")
            #expect(cell.fills.count == shapes.count, """
                \(ch): expected \(shapes.count) sub-shape fill(s) (one per `symbolShapes` \
                table entry), got \(cell.fills.count)
                """)
            for fill in cell.fills {
                switch fill.shape {
                case .rect(let r):
                    #expect(r.width > 0 && r.height > 0, "\(ch): zero-area rect fill")
                case .disc(_, let radius):
                    #expect(radius > 0, "\(ch): zero-radius disc fill")
                case .poly(let points):
                    #expect(points.count >= 3, "\(ch): degenerate polygon (\(points.count) point(s))")
                    // Shoelace formula: zero means every point is collinear (or duplicated) —
                    // a "polygon" with no actual area, the same placeholder shape this law
                    // guards against.
                    var area = 0.0
                    for i in points.indices {
                        let p1 = points[i], p2 = points[(i + 1) % points.count]
                        area += p1.x * p2.y - p2.x * p1.y
                    }
                    #expect(abs(area) > 0.01, "\(ch): degenerate (zero-area) polygon \(points)")
                }
            }
        }
    }

    /// Pixel-ink law: painting a `symbolShapes` cell (the SAME erase-then-fill sequence
    /// `PageTextView.drawVectorGraphics`/`drawOverprintPasses` use, job 211/402) must leave
    /// real dark ink on the canvas — proof that the DRAWING side (`GraphicShape.fill()`,
    /// `PrintedVectorGraphics.swift`) actually paints the geometry the law above proves exists,
    /// not just that the data model produces non-empty numbers. Draws directly into a bitmap
    /// rather than through a full `PagedDocumentView`/`PixelOracleAppEngine` page render — a
    /// unit-level proof of the compositing call, same scoping reasoning as the geometry law
    /// above.
    @Test @MainActor func symbolShapesPaintVisibleInkNotAPlaceholder() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        for ch in symbolShapes.keys.sorted() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.black,
            ]
            let text = NSAttributedString(string: String(ch), attributes: attrs)
            let isolated = try #require(isolatedLineLayout(text, width: 100),
                                         "\(ch): no isolated layout produced")
            let cells = graphicCells(manager: isolated.manager, storage: isolated.storage,
                                      glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect)
            let cell = try #require(cells.first, "\(ch): produced no GraphicCell at all")

            let bounds = cell.eraseFrame.insetBy(dx: -4, dy: -4)
            let scale: CGFloat = 4
            let pixelsWide = max(1, Int((bounds.width * scale).rounded()))
            let pixelsHigh = max(1, Int((bounds.height * scale).rounded()))
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                "\(ch): could not build a bitmap")
            bitmap.size = NSSize(width: bounds.width, height: bounds.height)

            NSGraphicsContext.saveGraphicsState()
            let ctx = try #require(NSGraphicsContext(bitmapImageRep: bitmap), "\(ch): no graphics context")
            NSGraphicsContext.current = ctx
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height).fill()
            // Same paint sequence `PageTextView.drawVectorGraphics` uses: erase the
            // placeholder, then every fill in order — translated so this cell's own origin
            // lands inside the small canvas above.
            cell.eraseFrame.offsetBy(dx: -bounds.minX, dy: -bounds.minY).fill()
            for fill in cell.fills {
                NSColor(white: fill.gray, alpha: 1).setFill()
                fill.offsetBy(dx: -bounds.minX, dy: -bounds.minY).fill()
            }
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            var minGray = 1.0
            for py in 0..<bitmap.pixelsHigh {
                for px in 0..<bitmap.pixelsWide {
                    guard let gray = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceGray)?.whiteComponent
                    else { continue }
                    minGray = min(minGray, Double(gray))
                }
            }
            #expect(minGray < 0.5, """
                \(ch): no dark ink painted anywhere in its own cell (min gray \(minGray)) — \
                geometry was produced but nothing visibly drew, the compositing-side failure \
                the geometry law above cannot see
                """)
        }
    }

}
