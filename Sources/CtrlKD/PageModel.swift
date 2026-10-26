/// The printed page model: the metrics, the `PageLine` a paginator hands the writer, and the
/// `Page` that collects them with its running heads, number and geometry overrides.

/// The page metrics, in PostScript points. Taken verbatim from the Python constants.
///
/// `linesModern` and `maxCols` are DERIVED in Python (pdf.py:23-25) and literal here, per
/// the job spec. `MAX_COLS` is the reason: it reads `int((612 - 144) / (12 * 0.6))`, which
/// is `int(468 / 7.199999999999999)` = `int(65.0000…)` = 65 — the answer survives the float
/// only because the truncation lands on the right side of it. Recomputing that in Swift
/// would be reproducing an accident, so the accident's result is written down instead and
/// the vectors pin it. (Printed mode's own equivalent, `LINES_PRINTED`, existed at Python
/// 1.2.0 but was deleted in 1.3.0 along with the fixed-margin assumption it was derived
/// from — see `printedCap` below.)
public enum PDFMetrics {
    /// US Letter, points.
    public static let pageWidth = 612
    public static let pageHeight = 792
    /// 1 inch.
    public static let margin = 72
    /// 12pt type on 12pt leading — 10 CPI pica by 6 LPI, the dot-matrix standard.
    public static let size = 12
    public static let lead = 12
    /// Top margin. A print stream carries its own top-margin blanks, so it gets the smaller
    /// one and its blanks supply the rest (see the machine-margin rule in `docToPagelines`).
    /// `topPrinted` is also the FIXED fallback `printedTop(_:)` uses for a document with no
    /// page geometry (a bare print-stream capture) — a real WS document's printed top comes
    /// from its own `.mt` instead (default `.mt 3` resolves to exactly this same 36pt).
    public static let topModern = 72
    public static let topPrinted = 36
    /// Lines per page: `(pageHeight - 2 * top) / lead`.
    public static let linesModern = 54
    /// `.l#` line-numbering gutter (planning #247): right edge of the printed label,
    /// ABSOLUTE from the true page edge (x=0) -- WordStar column 4, 0.4in -- never
    /// relative to the document's own `.po`/left margin. Measured against real WS7
    /// (ws7-prints/v4/sawyer__PRINT_EXT_TST.pcl, dosbox-x): the document's `.po .8"`
    /// (column 8, 57.6pt) puts body text at x=576 decipoints while a single-digit label
    /// sits at x=216..288 decipoints and a two-digit one at x=144..288 -- the SAME right
    /// edge (288 decipoints = 28.8pt) either way, confirming right-alignment to a fixed
    /// column, not a `.po`-relative one. WSFORMAT.TXT's own internal-format section (the
    /// 0Ch "Page offset" printer-driver record) calls this field an "Absolute HMI spot
    /// for line number", the same reading. One oracle value only (both real `.l#`
    /// occurrences in the Sawyer archive share the same `.po .8"`) -- a document with a
    /// narrower `.po` than this could in principle overlap its own body text; not
    /// observed, not guarded against. Port of Python's `LINE_NO_RIGHT_PT`.
    public static let lineNoRightPt = 28.8
    // Printed-mode capacity is per-document now (`printedCap`, ctrl-kd 1.3.0): WordStar's
    // own vertical model, `.pl - .mt - .mb` at the `.lh` line height — 55 for WordStar's own
    // defaults, not a fixed line count. Python deleted the equivalent `LINES_PRINTED`
    // constant (pdf.py) for the same reason: a single number can no longer stand in for
    // every document's printed page, since the model now reads `.mt`/`.mb`/`.lh` from the
    // file instead of assuming a fixed 72pt printed-mode margin.
    /// Text-column width in characters — WordStar's own margin, arrived at independently.
    public static let maxCols = 65
}

/// One laid-out line: styled segments, wrapped and ready to place, plus the line's own LEAD.
///
/// Spans are the IR's text-plus-styles pair and are exactly what a segment is, so the
/// segments ARE `Span`s and not a second type — the difference is only that a `PageLine`'s
/// spans have been through the wrapper and never contain a line break. This was a plain
/// `[Span]` until the stateful-`.lh` work; it is a collection OF spans now, for the same
/// reason Python's `PageLine` is a `list` subclass rather than a list: the line needs one
/// attribute of its own and every existing use of it is still a use of the sequence.
///
/// `lead` (2026-08-05) is this line's baseline-to-baseline advance in POINTS, or `nil` for
/// "the document's default". It is `Line.lead48` — the `.lh` in force where the line sat —
/// converted once, at the layout boundary, so the writer's loop never has to know about
/// 48ths. Lines this emitter MAKES rather than reads (footnote areas, wrapped Modern text,
/// blank fillers) leave it `nil` by construction: they are the emitter's own furniture and
/// belong on the document's default lead.
/// Planning #231: a line's own candidate left origin for EACH page parity -- a named
/// `Hashable` struct rather than a bare tuple (Swift tuples don't conform to
/// `Hashable`/`Equatable`, which `PageLine`/`Page` both need for their own collection
/// conformances). Port of ctrl-kd's `PageLine.parity_left` `(even_pt, odd_pt)` pair.
public struct ParityLeft: Hashable, Sendable {
    public var even: Double
    public var odd: Double
    public init(even: Double, odd: Double) {
        self.even = even
        self.odd = odd
    }
}

public struct PageLine: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
                        ExpressibleByArrayLiteral, Hashable, Sendable {
    public var spans: [Span]
    public var lead: Double?
    /// Bare-CR `^PM` Overprint Line: the NEXT `PageLine` prints at THIS one's own
    /// baseline. `false` by construction for every line this emitter MAKES (footnote
    /// areas, wrapped Modern text, blank fillers) — only a printed-mode body line
    /// carries WordStar's own flag.
    public var overprint: Bool
    /// `Line.soft` carried into the paginated representation (Python `PageLine.soft`,
    /// added 2026-08-03 there; closed here with the layout facade): a soft return is
    /// WordStar's own word wrap — or the filler `.ls > 1` materialises — where a hard
    /// one is the author pressing Return. What Soft Return.app's Show Invisibles needs,
    /// and part of the `layout` JSON contract.
    public var soft: Bool
    /// b24 round 17 (RULINGS-LEDGER row 5/7): this line's own first-line-indent
    /// override in POINTS, or `nil` — `.pm`'s effect (mirrors RTF's `\fi`, round 6), set
    /// ONLY on a `.para` block's own first content line. `.psa`/`.psb` reuse `lead`
    /// itself rather than a new field — WordTsar's space-before/after is exactly one
    /// MORE baseline-to-baseline distance to spend before a line prints, the same
    /// quantity `lead` already carries.
    public var fi: Double?

    /// planning #257 (ctrl-kd's own `PageLine.pm_active`): whether this line's own
    /// BLOCK has a real, nonzero `.pm` in force — the missing half of `splitIndent`'s
    /// `indent` flag. `indent` alone only says "this segment is the line's own leading
    /// run of literal spaces before proportional text" — it does NOT say the leading
    /// run is `.pm`'s own document-column convention (WARPRAYR.WS, measured) rather
    /// than plain hand-typed centering with no margin mechanism behind it at all
    /// (sawyer/REF/-HOW-TO.RJS pages 10-12, measured: `.pm 0"` in force). `fi` cannot
    /// stand in for this — it is already 0/`nil` both when the block never set `.pm`
    /// AND when a typed indent already satisfies a nonzero one (`printedPMFiPt`'s own
    /// `max(0, pmCols - alreadyTypedCols)`), the very two cases this field tells
    /// apart. `false` by construction for every line this emitter MAKES rather than
    /// reads, the same "furniture" convention `fi`/`bi` follow. See `lineOpsPrinted`'s
    /// own `pmActive` parameter for how it's consumed.
    public var pmActive: Bool

    /// b24 round 18 (RULINGS-LEDGER row 4): the source Block's own index in
    /// `doc.blocks`, for `tocPageNumbers` to resolve which page a `.tc`/`.ix` entry's
    /// own block landed on — the REAL paginator's answer, not an estimate. `nil` for a
    /// line this emitter MAKES rather than reads (matches `lead`'s own "furniture"
    /// convention). Port of Python's `PageLine.bi`.
    public var bi: Int?

    /// `PageLine.image`'s payload — a named struct rather than a bare tuple because
    /// `PageLine` is `Hashable` and Swift tuples are not.
    public struct ImageRef: Hashable, Sendable {
        public var pixIndex: Int
        public var widthPt: Double
        public var heightPt: Double
        public init(pixIndex: Int, widthPt: Double, heightPt: Double) {
            self.pixIndex = pixIndex
            self.widthPt = widthPt
            self.heightPt = heightPt
        }
    }

    /// b24 round 19 (RULINGS-LEDGER PIX row): set when this PageLine IS a resolved,
    /// embedded picture rather than text — `spans` is empty by construction and
    /// `pageStream` draws the XObject instead of running text ops. `lead` is set to
    /// `heightPt` (+ any `.psb`/`.psa` spacing, same as an ordinary line) so the
    /// existing budget/cost model accounts for the image's vertical footprint with no
    /// change of its own — reusing exactly the mechanism round 17 built for
    /// `.psa`/`.psb`. Port of Python's `PageLine.image`.
    public var image: ImageRef?

    /// `true` for a blank `PageLine` that `ws4SpacingBlankIndices` classified as this
    /// WS4 document's OWN double-spacing idiom rather than authored content — Finding
    /// 1 (b26 visual pass). See that function's doc comment, and
    /// `layoutPrintedPages`'s own use of this flag for why it matters: a blank
    /// flagged this way never forces a page break BY ITSELF; an authored blank (flag
    /// `false`, every non-WS4 document's blanks included) is untouched, exactly the
    /// previous behaviour. `false` by construction for every line this emitter MAKES
    /// (footnote areas, wrapped Modern text, blank fillers, matching `lead`'s "furniture"
    /// convention) — only a plain-path printed body line ever sets it. Port of Python's
    /// `PageLine.ws4_spacing`.
    public var ws4Spacing: Bool

    /// `Line.kerning`, the `.KR` state in force where this line sat — `true` (WordStar's
    /// own default) for every line this emitter MAKES rather than reads, the same
    /// "furniture" convention `lead`/`bi` follow. Consumed by `ljSubstitute`. Register C7.
    public var kerning: Bool

    /// `left` (register b31): this line's own left-edge override in POINTS, already
    /// resolved (`resolveLeftPt`), or `nil` for "the document's default" — `Line.poCols`
    /// carried through the same `.lh`-shaped stateful contract `lead` above documents for
    /// `.lh`, just for `.po`. Converted here (not at render time) for the same reason
    /// `lead` is: `pageStream`'s layout loop never has to know about print columns. `nil`
    /// by construction for every line this emitter MAKES rather than reads (footnote
    /// areas, wrapped Modern text, blank fillers), the same "furniture" convention `lead`/
    /// `bi` follow.
    public var left: Double?

    /// `roll` (register b32-N10, mirrored from ctrl-kd b48148c): this line's own `.sr`
    /// sub/superscript roll in POINTS, already resolved, or `nil` for "the document's
    /// default" — `Line.roll48` carried through the SAME `.lh`-shaped stateful contract
    /// `lead`/`left` above document, just for `.sr`. Unlike `lead`/`left`, `Line.roll48`
    /// is never itself `nil` (see its own doc comment: no style/font precedence chain to
    /// defer to), so `roll` is `nil` only for a PageLine this emitter MAKES rather than
    /// reads — `pageStream` falls back to the document-wide `rollPt` parameter for those,
    /// exactly as it already does for `left`.
    public var roll: Double?

    /// `justifyRightX` (planning #238, `.oj on` full justification): this line's own
    /// right text-margin in ABSOLUTE points, or `nil` for an unjustified line — set by
    /// `resolvePrintedBody` only on a line inside an `.oj on`/`align == .justify` block
    /// that is NOT that block's own last physical line (see `lineOpsPrinted`'s own doc
    /// comment for the measured rule). Consumed by `lineOpsPrinted`; a PageLine this
    /// emitter MAKES rather than reads (furniture) leaves it `nil`, the same convention
    /// `left`/`roll` already follow. Port of Python's `PageLine.justify_right_x`
    /// (ctrl-kd aeb34ad).
    public var justifyRightX: Double?

    /// `parityLeft` (planning #231, `.poe`/`.poo` even/odd page offset): `(evenPt,
    /// oddPt)` -- this line's own resolved left origin for EACH page parity, or `nil`
    /// for a line no `.poe`/`.poo` ever governs. `resolvePrintedBody`
    /// cannot resolve which of the two applies at BUILD time (that depends on which
    /// page this line lands on, a pagination question); `left` stays `nil` until the
    /// page-filling loop's own `closePage` (`layoutPrintedPages` -- the one place
    /// that actually knows this line's page's parity) picks the right member of the
    /// pair and overwrites it. Port of ctrl-kd's `PageLine.parity_left`.
    public var parityLeft: ParityLeft?

    /// `col` (planning #227 follow-up, 2026-09-09): this line's own 0-based column index
    /// within an active `.co n>1` region, or `nil` for every ordinary (non-columnar) line
    /// -- same "furniture"/"document default" convention as `left`/`bi`. Set ONLY by
    /// `applyColumns`, at the same site that already resolves this line's own `left` for
    /// its column -- `left` alone cannot tell a consumer THIS IS A NEW COLUMN, RESET Y
    /// apart from an ordinary mid-document `.po`/`.poe`/`.poo` left-edge change (which
    /// must NOT reset the vertical flow); `col` is the unambiguous signal `emitLayout`
    /// and Soft Return.app's Native view both need for that distinction. A page's own
    /// column COUNT/geometry lives on `Page` (`columns`/`columnGutterPt`/`columnWidthPt`)
    /// rather than repeated on every line. Port of Python's `PageLine.col`.
    public var col: Int?

    /// One piece of a justified line's own PRECOMPUTED word/gap split -- see
    /// `justifyWordX`'s own doc comment. A named struct, not a bare tuple, for the same
    /// reason `ImageRef` is: `PageLine` is `Hashable` and Swift tuples are not.
    public struct JustifyWordPiece: Hashable, Sendable {
        public var text: String
        public var x: Double
        public var width: Double
        public init(text: String, x: Double, width: Double) {
            self.text = text
            self.x = x
            self.width = width
        }
    }

    /// planning #251(b): this line's own PRECOMPUTED `justifyPiecesPrinted` result --
    /// covering the whole line left to right -- or `nil`. Set by
    /// `attachJustifyWordXPrinted` ONLY when this is a `justifyRightX`-carrying line
    /// that resolves (after the SAME `splitIndent`/`splitSymbolFallback`/
    /// `splitGraphics`/`ljSubstitute` pipeline `lineOpsPrinted` itself runs) to exactly
    /// one FIXED-PITCH, untagged span with a real gap to stretch -- every other
    /// justified line (styled/mixed, proportional, a pctl/tab span, or one with no
    /// slack to distribute) leaves this `nil`, and `lineOpsPrinted` falls back to
    /// computing it fresh at render time, unchanged from before this field existed.
    /// Port of ctrl-kd's `PageLine.justify_word_x`.
    public var justifyWordX: [JustifyWordPiece]?

    /// This line's own `.l#` gutter label and ABSOLUTE x -- see `lineNo`'s own doc
    /// comment. A named struct for the same `Hashable` reason as `JustifyWordPiece`.
    public struct LineNumberLabel: Hashable, Sendable {
        public var text: String
        public var x: Double
        public init(text: String, x: Double) {
            self.text = text
            self.x = x
        }
    }

    /// planning #251(d): this line's own `.l#` gutter label and ABSOLUTE x, or `nil`
    /// for a line no active `.l#` interval numbers -- moved off `pageStream`'s own
    /// render-time `lineNoState` counter (which reset every PAGE, per planning #247's
    /// own oracle) onto the model by `attachLineNumbersPrinted`. `pageStream` now only
    /// draws from this field (still gated by its own `lineNoTimeline != nil`
    /// parameter, which is how `--line-numbers off` keeps suppressing the draw even
    /// though the model carries the label unconditionally -- same "model states it, a
    /// flag may still tell the WRITER not to draw it" shape `headers`/`footers` already
    /// use). Port of ctrl-kd's `PageLine.line_no`.
    public var lineNo: LineNumberLabel?

    /// One cp437 graphic character's own model-side placement -- see `graphicCells`'s
    /// own doc comment. A named struct for the same `Hashable` reason as
    /// `JustifyWordPiece`.
    public struct GraphicCellPlacement: Hashable, Sendable {
        public var char: Character
        public var x: Double
        public var width: Double
        /// JSON-parity bookkeeping ONLY (planning #251(c)) -- `true` when this cell's
        /// `width` came from a PROPORTIONAL run's own pitch (`pdf.py`'s
        /// `pitch = pt if entry.get('proportional') else spanPitch(...)`, the TRUE
        /// branch): ctrl-kd's own `pt` is a bare Python `int` there, so
        /// `json.dumps` writes that `width` with no decimal point (`13`, not
        /// `13.0`) -- `emitLayout` must reproduce that exact byte shape, not just
        /// the numeric value, for cross-engine byte parity (`AnswerKeyParityTests`).
        /// `false` (the `spanPitch`/`supSubSpanPitch` branch) is always a Python
        /// `float` there, serialized with a decimal point same as every other
        /// point measurement in this JSON. Never meaningful for anything but this
        /// one serialization decision -- the PDF writer's own point math is
        /// unaffected either way (`fixedOneDecimalDouble` et al. always emit a
        /// decimal).
        public var widthIsWholePointPitch: Bool
        /// planning #251 follow-up (2026-09-10): the 1-based PDF page this cell landed
        /// on, or `nil` -- Printed's own placements never set it (a `PageLine` is
        /// already nested inside its own page in the `layout` JSON's `printed.pages`
        /// array, so the page is implicit there); Modern's `attachGraphicCellsModern`
        /// always sets it (`modern.items` is a FLAT, unpaginated array, so a cell has
        /// no other way to say which of Modern PDF's own pages it is drawn on).
        public var page: Int?
        public init(char: Character, x: Double, width: Double,
                   widthIsWholePointPitch: Bool = false, page: Int? = nil) {
            self.char = char
            self.x = x
            self.width = width
            self.page = page
            self.widthIsWholePointPitch = widthIsWholePointPitch
        }
    }

    /// planning #251(c): every cp437 box-drawing/graphic character this line draws as
    /// a vector, in document order, or `nil` for a line with no graphic character at
    /// all. Set by `attachGraphicCellsPrinted` from a real (throwaway-state) call to
    /// `lineOpsPrinted` itself -- see that function's own `recordGraphicCells`
    /// parameter -- so the values are exactly what the writer draws, not a parallel
    /// re-derivation. Port of ctrl-kd's `PageLine.graphic_cells`.
    public var graphicCells: [GraphicCellPlacement]?

    /// This line's own `.po` in PRINT COLUMNS -- the same value `left` above is the
    /// (clamped, points) rendering of, kept unrounded and unclamped because `closePage`
    /// positions the automatic page number in columns from it (`autoPageNumberXPt`). It
    /// comes from core's own per-line `.po` state (`Line.poCols`), which is why it is the
    /// right source and a dot-command scan is not: the parser EVALUATES `.if`/`.ei`, so a
    /// `.po` inside a false conditional (`sawyer/REF/REFORM.DOT`, `sawyer/FONTS/PS/
    /// ERROR.WS`: `.po 1i` then `.if 1=0` / `.po .7i` / `.ei`) never reaches a line, while
    /// `Document.dotPositions` lists it like any other. `nil` for a line built outside the
    /// body path (TOC/index, wrapped overflow) -- "no opinion". Port of ctrl-kd's
    /// `PageLine.po_cols`.
    public var poCols: Double?

    public init() {
        spans = []
        lead = nil
        overprint = false
        soft = false
        fi = nil
        pmActive = false
        bi = nil
        image = nil
        ws4Spacing = false
        kerning = true
        left = nil
        roll = nil
        justifyRightX = nil
        parityLeft = nil
        col = nil
        justifyWordX = nil
        lineNo = nil
        graphicCells = nil
        poCols = nil
    }

    public init(_ spans: [Span], soft: Bool = false, lead: Double? = nil,
                overprint: Bool = false, fi: Double? = nil, pmActive: Bool = false,
                bi: Int? = nil,
                image: ImageRef? = nil, ws4Spacing: Bool = false, kerning: Bool = true,
                left: Double? = nil, roll: Double? = nil, justifyRightX: Double? = nil,
                parityLeft: ParityLeft? = nil, col: Int? = nil,
                justifyWordX: [JustifyWordPiece]? = nil, lineNo: LineNumberLabel? = nil,
                graphicCells: [GraphicCellPlacement]? = nil, poCols: Double? = nil) {
        self.spans = spans
        self.soft = soft
        self.lead = lead
        self.overprint = overprint
        self.fi = fi
        self.pmActive = pmActive
        self.bi = bi
        self.image = image
        self.ws4Spacing = ws4Spacing
        self.kerning = kerning
        self.left = left
        self.roll = roll
        self.justifyRightX = justifyRightX
        self.parityLeft = parityLeft
        self.col = col
        self.justifyWordX = justifyWordX
        self.lineNo = lineNo
        self.graphicCells = graphicCells
        self.poCols = poCols
    }

    public init(arrayLiteral elements: Span...) {
        self.init(elements)
    }

    public var startIndex: Int { spans.startIndex }
    public var endIndex: Int { spans.endIndex }

    public subscript(position: Int) -> Span {
        get { spans[position] }
        set { spans[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection>(
        _ subrange: Range<Int>, with newElements: C
    ) where C.Element == Span {
        spans.replaceSubrange(subrange, with: newElements)
    }
}

/// One RESOLVED running head/footer LINE (planning #251(d)) -- `text` already carries
/// both the `#` page-number substitution and (a fontless line with its own right-align
/// tab only) the baked realignment spacing, but keeps WordStar's own inline style
/// TOGGLE BYTES intact, same as the raw `headers`/`footers` dict. `font` is the index
/// into `Document.fonts`, or `nil` for the fontless/Courier default. Port of Python's
/// `{'text': str, 'x': float, 'y': float, 'font': int|None}` dict shape.
public struct HeadFootLine: Hashable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var font: Int?
    /// The SELECTED STYLE's own baseline span attrs for this line -- the exact value
    /// `hfLineOps` ORs into every run's own toggle-byte styles before drawing (planning
    /// #255), with this page's `.h1e`/`.h1o` parity variant already applied. Empty when
    /// the line selects no style, which is almost every line in the corpus.
    ///
    /// THIS IS WHAT THE LINE IS, not how one emitter happens to draw it. A
    /// running head can be BOLD with no toggle byte anywhere in its text -- the weight
    /// coming from the `.h#` argument's own 0x11 style select --  and `font` cannot say
    /// so: it names the style's FACE. `sawyer/REF/BOOKLET.WS`'s two heads are exactly
    /// that, and every consumer drawing the printed page from this model drew them
    /// light. `layout` JSON version 11 publishes it as `style`, a sorted tag list.
    public var styleAttrs: Style
    /// THIS ROW IS NOT ON THE PAPER -- DO NOT DRAW IT.
    ///
    /// E11 (Jon's ruling 2026-09-17, `layout` JSON version 12's `off_sheet`): WordStar
    /// commands a head/foot/page-number row wherever `pl - mb + fm` puts it and lets the
    /// printer clip it, so the PDF still draws at `y` and the page edge does the
    /// clipping -- see `hfOffSheet` for the WS7 captures. A consumer drawing from this
    /// MODEL has no paper to clip with, and drew a `FORMFEED.WS` page-5 number the PDF
    /// shows nowhere. False for every ordinary row.
    public var offSheet: Bool

    public init(text: String, x: Double, y: Double, font: Int?,
                styleAttrs: Style = [], offSheet: Bool = false) {
        self.text = text
        self.x = x
        self.y = y
        self.font = font
        self.styleAttrs = styleAttrs
        self.offSheet = offSheet
    }
}

/// WordStar's own resolved AUTOMATIC page number (the one `.pc` positions) for one page
/// -- present exactly when `resolveHeadFootLines`'s `showAutoNum` gate lets it through.
/// Port of Python's `(text, x, y)` tuple.
public struct AutoPageNumber: Hashable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    /// THIS NUMBER IS NOT ON THE PAPER -- DO NOT DRAW IT. See
    /// `HeadFootLine.offSheet`, `hfOffSheet`, and `layout` JSON version 12's
    /// `off_sheet`. `sawyer/ARTICLES/FORMFEED.WS` page 5 is the case.
    public var offSheet: Bool

    public init(text: String, x: Double, y: Double, offSheet: Bool = false) {
        self.text = text
        self.x = x
        self.y = y
        self.offSheet = offSheet
    }
}

/// One paginated page: a collection of `PageLine`s, plus the running head and foot IN
/// FORCE when this page printed (replayed from `Document.hfEvents`). Port of Python's
/// `Page(list)`.
///
/// A struct that behaves as a collection of `PageLine` for the same reason `PageLine`
/// itself is one: every existing consumer iterates a page as a sequence of lines and
/// keeps working untouched, while new code can ask for `.headers`/`.footers`.
/// How far into the document a page had read when it closed — `bi` is the block its
/// last line belonged to and `count` is how many lines of THAT block the document has
/// printed in total up to here. Triage Q12; see `Page.readPos`.
public struct PageReadPos: Hashable, Sendable {
    public var bi: Int
    public var count: Int
    public init(bi: Int, count: Int) {
        self.bi = bi
        self.count = count
    }
}

public struct Page: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
                    ExpressibleByArrayLiteral, Hashable, Sendable {
    public var lines: [PageLine]
    /// Running head/foot text by line number (1-5), IN FORCE when this page printed —
    /// only non-empty entries (an empty string CLEARS a line, so it never renders).
    /// Empty on every page from a layout path that doesn't replay `hfEvents` (the
    /// footnote/annotation/endnote-aware paginator, unchanged since before this port):
    /// those pages carry the DOCUMENT'S final-state `headers`/`footers` instead, which
    /// is the fallback `runningOps` applies when a page's own dict is empty — matching
    /// Python's `getattr(pl, 'headers', None)` on a plain list (no attribute at all).
    public var headers: [Int: String]
    public var footers: [Int: String]
    /// Whether this page has a running FOOTER at all, INCLUDING a `.fo` whose text is
    /// empty. `footers` above drops empty slots (nothing to draw), but "is a footer in
    /// use" is a different question from "is there footer text to draw": a bare `.fo`
    /// draws nothing and still silences WordStar's automatic bottom-of-page number.
    /// See `resolveHeadFootLines`'s own `footerInUse` comment for the measurement.
    /// `false` for every document that never writes `.fo`.
    ///
    /// DEFAULTS to `!footers.isEmpty` for every `Page` built anywhere but `closePage`
    /// (the column merge, the synthesized fallback page) --
    /// those carry `doc.footers`, whose empty slots were never filtered out, so
    /// deriving it is exactly right there AND is what Python's own call sites do for
    /// the plain LISTS it uses in the same places (`getattr(pl, 'footer_in_use', None)`
    /// -> "no opinion, derive from `footers`"). Only `closePage` knows more than the
    /// dict does, and only `closePage` overrides it. Port of Python's
    /// `pdf.Page.footer_in_use`.
    public var footerInUse: Bool
    /// `(block index, how many lines of that block this page had read)` at the moment
    /// the page closed — the position the paginator had reached, recorded BEFORE
    /// `finalizePages` strips a page's trailing blanks (triage Q12). A page of nothing
    /// but blank lines ends up EMPTY otherwise, with no `bi` left to read, and a leading
    /// blank run is exactly where a `.pn` needs placing. See `checkpointsByPage`.
    public var readPos: PageReadPos?
    /// The `.mt`/`.mb` IN FORCE when this page's own pagination started (Finding 3,
    /// b26-print-fidelity-2) — `nil` for "the document's global (first-occurrence)
    /// value", which is every page of every document that never changes `.mt`/`.mb`
    /// mid-document (see `mtMbTimeline`). Threading the SAME resolved pair from
    /// pagination-time (which already had to know it, to size the page's own capacity)
    /// through to render-time (`emitPDF`'s per-page loop) keeps the two in agreement by
    /// construction, rather than re-deriving the same answer twice from
    /// `Document.dotPositions`. Set only by `layoutPrintedPages`, for every printed
    /// document alike, notes or none.
    public var mtLines: Double?
    public var mbLines: Double?
    /// `.pl` in force when this page's own pagination started (register b31-dot-command-
    /// sweep, `plTimeline`) -- `nil` for "the document's global (first-occurrence)
    /// value", the same contract as `mtLines`/`mbLines` above.
    public var plLines: Double?
    /// `.hm`/`.fm` in force when this page's own pagination started (register b31-dot-
    /// command-sweep, `hmFmTimeline`) -- same `nil`/"document global" contract again.
    public var hmLines: Double?
    public var fmLines: Double?
    /// `.po` (page offset) in force when this page's own pagination started (mechanism O,
    /// `poTimeline`) -- same `nil`/"document global" contract again. Feeds `runningOps`'s
    /// own header/footer LEFT edge only -- body text already carries a per-LINE `.po`
    /// override (`Line.poCols`, applied in `resolvePrintedBody`), this is
    /// the page-granularity twin that mechanism was missing. Port of Python's `Page.po_cols`.
    public var poCols: Double?
    /// M31: the `.pr or=` in force when this page's own pagination started -- `nil` for
    /// "the document's own orientation", the same contract as everything above it. Unlike
    /// every other value here it reaches the SHEET: the page's MediaBox, the height its
    /// content stream is drawn through, and its running head/foot row. See
    /// `orTimeline` for the measured WS7 timing rule that decides which page a
    /// `.pr or=` belongs to.
    public var orientation: Orientation?
    /// planning #231/#241 follow-up (2026-09-08): whether `poCols` above came from an
    /// ACTIVE `.poe`/`.poo` parity override, as opposed to a plain mid-document `.po`
    /// reset. #241's `pageGeomChanged` gate (`PDFWriter.swift`) exists to keep a
    /// HOLYMAC-style transient `.po` (a local body-margin excursion, no real page-layout
    /// change) from leaking into the running head/foot -- but `.poe`/`.poo` ARE
    /// themselves a page-layout decision by definition (WSFORMAT.WS: "specify even or
    /// odd number page offsets"), so they must bypass that gate rather than be silently
    /// caught by it. Measured: sawyer/MAILLIST/PHONE.LST (`.poo .20"`/`.poe .20"`, no
    /// plain `.po`) -- its own running head rendered at the document default 57.6pt
    /// instead of the declared 14.4pt. Port of Python's `Page.po_parity`.
    public var poParity: Bool
    /// The `.po` in force where WordStar STAMPS this page's automatic page number --
    /// the page's own LAST line, not its first. `nil` for "no page-specific answer, use
    /// the document's" (every page of every document that never moves `.po`/`.poe`/
    /// `.poo`). See `autoPageNumberXPt` for the captures behind the rule, and
    /// `closePage` for where this is resolved. Port of ctrl-kd's `Page.auto_pageno_po`.
    public var autoPagenoPo: Double?
    /// #228 (research/2026-09-08_trailing-pa-rule.md, planning #228): a trailing `.pa`
    /// followed by at least one more real content paragraph -- even a blank one --
    /// before EOF opens a final page with no body; real WS7 still stamps its running
    /// footer/page number there. `explicitBreak` marks a page force-closed by exactly
    /// that condition (never popped by `finalizePages`'s empty-trailing-page cleanup);
    /// `explicitBreakBI` is the block index of the `.pa` itself (or, for a fresh
    /// endnote-only page with no `.bi`-carrying line of its own, the document's own
    /// highest block index), so the auto-page-number lookup has something to resolve
    /// against on a page with no lines at all. Both stay at their default (`false`/
    /// `nil`) for every ordinary page.
    public var explicitBreak: Bool
    public var explicitBreakBI: Int?
    /// `columns`/`columnGutterPt`/`columnWidthPt` (planning #227 follow-up, 2026-09-09):
    /// this page's own `.co n` geometry, set ONLY by `applyColumns` on a page it actually
    /// merged from a columnar group -- `nil`/`nil`/`nil` for every ordinary page, the same
    /// "no opinion" convention `poCols` etc. already use. One page-level record rather
    /// than repeating gutter/width on every `PageLine` (`PageLine.col` carries the
    /// per-line column INDEX; this is the shared geometry every index on this page
    /// resolves against). `columnWidthPt` is one column's own width -- the block's `.rm`
    /// minus `.po`, exactly as `applyColumns`'s own doc comment derives it, NOT the page
    /// width divided by n. Port of Python's `Page.columns`/`column_gutter_pt`/
    /// `column_width_pt`.
    public var columns: Int?
    public var columnGutterPt: Double?
    public var columnWidthPt: Double?
    /// `columnTopOffsetPt` (planning #227 follow-up, 2026-09-12): how far BELOW this
    /// sheet's own first text line every column of the group begins -- the height of
    /// the non-columnar prefix (a title and its blank) the sheet opened with, in
    /// points, `0.0` when the region owns the sheet from its first line. Column 0's
    /// own lines are drawn straight down from the top and simply pass through the
    /// prefix; columns 1..n-1 restart at this offset, which is where real WS7 puts
    /// them (see `applyColumns`). `nil` on every non-columnar page, the same "no
    /// opinion" convention as the three above. Port of Python's
    /// `Page.column_top_offset_pt`.
    public var columnTopOffsetPt: Double?
    /// `headerPcl`/`footerPcl` (2026-09-12, cause 10 of the ws7-prints/v4 triage): the
    /// 0x0F user print controls IN FORCE on this page's own running head/foot,
    /// replayed from each `HFEvent.pcl` exactly as `headers`/`footers` are replayed from
    /// `doc.hfEvents`, because a document may restate `.h1` with a different control on
    /// different pages (`sawyer/LSRBOX/LSRBOX.WS` does, three times). Empty on every
    /// page of every document whose running heads carry none.
    public var headerPcl: [Int: [HFPrintControl]] = [:]
    public var footerPcl: [Int: [HFPrintControl]] = [:]
    /// True ONLY for the one page `finalizePages` synthesizes when pagination produced
    /// none at all (Python's `pages or [[]]`). In ctrl-kd that fallback is a BARE LIST,
    /// not a `Page`, and every model-attach pass and every layout-JSON field that reads a
    /// resolved attribute off a page skips it for that reason alone
    /// (`isinstance(pg, Page)`, `getattr(page, ..., None)`). Swift has one type, so the
    /// distinction has to be carried as data.
    ///
    /// `page.isEmpty` used to stand in for it and cannot: `sawyer/REF/CODES` is a REAL
    /// paginated page that happens to carry no lines -- a document that is all dot
    /// commands and running heads -- and planning #274 gives such a page a real automatic
    /// number, which the proxy silently dropped from the layout JSON while ctrl-kd kept
    /// it. Found via `AnswerKeyParityTests`.
    public var isSynthesizedFallback: Bool = false
    /// `headerLines`/`footerLines`/`autoPageno` (planning #251(d), 2026-09-10): this
    /// page's own RESOLVED running head/foot -- `#` substituted, fontless right-tab
    /// realignment baked, `y`/`x`/`font` attached -- set ONLY by
    /// `attachHeadFootLinesPrinted` (`docToPagelines`'s own post-pagination pass), from
    /// `resolveHeadFootLines` (the SAME function `runningOps`, the PDF writer, calls to
    /// render). `nil` (not `[]`) for "not yet resolved" -- every page until that attach
    /// function runs. Port of Python's `Page.header_lines`/`footer_lines`/`auto_pageno`.
    public var headerLines: [HeadFootLine]?
    public var footerLines: [HeadFootLine]?
    public var autoPageno: AutoPageNumber?
    /// Planning #250: `{1: HFOverride}` — set ONLY when THIS page's line 1 came from a
    /// `.h1e`/`.h1o`/`.f1e`/`.f1o` parity variant (not a plain `.h1`/`.fo`), by
    /// `closePage`'s own parity resolver. `nil` (the "no opinion, read `Document.
    /// headerFonts`/`headerTabs` as before" default) for every page of every document
    /// that never uses the family — same convention as `poCols`/`poParity` above. Port
    /// of Python's `Page.head_hf_override`/`foot_hf_override`.
    public var headHfOverride: [Int: HFOverride]?
    public var footHfOverride: [Int: HFOverride]?

    public init() {
        lines = []
        headers = [:]
        footers = [:]
        mtLines = nil
        mbLines = nil
        plLines = nil
        hmLines = nil
        fmLines = nil
        poCols = nil
        poParity = false
        autoPagenoPo = nil
        explicitBreak = false
        explicitBreakBI = nil
        columns = nil
        columnGutterPt = nil
        columnWidthPt = nil
        columnTopOffsetPt = nil
        headerLines = nil
        footerLines = nil
        autoPageno = nil
        headHfOverride = nil
        footHfOverride = nil
        footerInUse = false
        orientation = nil
    }

    public init(_ lines: [PageLine], headers: [Int: String] = [:], footers: [Int: String] = [:],
               mtLines: Double? = nil, mbLines: Double? = nil, plLines: Double? = nil,
               hmLines: Double? = nil, fmLines: Double? = nil, poCols: Double? = nil,
               poParity: Bool = false, orientation: Orientation? = nil,
               explicitBreak: Bool = false, explicitBreakBI: Int? = nil,
               columns: Int? = nil, columnGutterPt: Double? = nil,
               columnWidthPt: Double? = nil) {
        self.lines = lines
        self.headers = headers
        self.footers = footers
        self.footerInUse = !footers.isEmpty
        self.readPos = nil
        self.mtLines = mtLines
        self.mbLines = mbLines
        self.plLines = plLines
        self.hmLines = hmLines
        self.fmLines = fmLines
        self.poCols = poCols
        self.poParity = poParity
        self.orientation = orientation
        self.autoPagenoPo = nil
        self.explicitBreak = explicitBreak
        self.explicitBreakBI = explicitBreakBI
        self.columns = columns
        self.columnGutterPt = columnGutterPt
        self.columnWidthPt = columnWidthPt
        self.columnTopOffsetPt = nil
        self.headerLines = nil
        self.footerLines = nil
        self.headHfOverride = nil
        self.footHfOverride = nil
        self.autoPageno = nil
    }

    public init(arrayLiteral elements: PageLine...) {
        self.init(elements)
    }

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }

    public subscript(position: Int) -> PageLine {
        get { lines[position] }
        set { lines[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection>(
        _ subrange: Range<Int>, with newElements: C
    ) where C.Element == PageLine {
        lines.replaceSubrange(subrange, with: newElements)
    }
}
