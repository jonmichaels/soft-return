/// The PDF emitter's layout half: IR -> pages of styled, wrapped lines. Port of `pdf.py`'s
/// `_wrap_line`, `_coalesce` and `_doc_to_pagelines` (pdf.py:18-30, 36-122).
///
/// Everything here is pure and independent of PDF syntax — it decides what goes on which
/// page and where the line breaks fall, in characters and line counts, not points. The byte
/// writer (`_page_stream`, `emit_pdf`) attaches to the `[Page]` this produces and is the
/// only part that needs to know what a PDF looks like.
///
/// A WordStar document rendered as the typescript it was: Courier at 10 CPI and 6 LPI on
/// US Letter, which is why a 65-column line is exactly the 6.5 inches between the margins.

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
    /// `layoutPrintedPagesPlain`'s own use of this flag for why it matters: a blank
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
    /// `resolvePlainBody` only on a line inside an `.oj on`/`align == .justify` block
    /// that is NOT that block's own last physical line (see `lineOpsPrinted`'s own doc
    /// comment for the measured rule). Consumed by `lineOpsPrinted`; a PageLine this
    /// emitter MAKES rather than reads (furniture) leaves it `nil`, the same convention
    /// `left`/`roll` already follow. Port of Python's `PageLine.justify_right_x`
    /// (ctrl-kd aeb34ad).
    public var justifyRightX: Double?

    /// `parityLeft` (planning #231, `.poe`/`.poo` even/odd page offset): `(evenPt,
    /// oddPt)` -- this line's own resolved left origin for EACH page parity, or `nil`
    /// for a line no `.poe`/`.poo` ever governs. `resolvePlainBody`/`resolvePrintedBody`
    /// cannot resolve which of the two applies at BUILD time (that depends on which
    /// page this line lands on, a pagination question); `left` stays `nil` until the
    /// page-filling loop's own `closePage` (`layoutPrintedPagesPlain` -- the one place
    /// that actually knows this line's page's parity) picks the right member of the
    /// pair and overwrites it. Port of ctrl-kd's `PageLine.parity_left`.
    ///
    /// NOT resolved by the notes-aware paginator (`layoutPrintedPages`, used when
    /// `hasPlaceableNotes(doc)`) -- same as ctrl-kd's own `_paginate_printed_notes` --
    /// a documented, evidence-based scope limit: zero corpus documents combine a real
    /// footnote/endnote/annotation with `.poe`/`.poo` (checked directly against the 41
    /// real documents this feature's answer-key re-record touched), so there is
    /// nothing to verify a resolution against; left unresolved in BOTH engines rather
    /// than risk one engine "fixing" a path the other cannot verify, which would break
    /// `AnswerKeyParityTests`' sr == ctrl-kd cell-for-cell contract for the first real
    /// document that combines them.
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
    /// draws from this field (still gated by its own `lineNoCheckpoints != nil`
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

/// One `.lh` value (1/48in units) as points: a point is 1/72in, so `lh * 1.5`. `nil` or
/// non-positive -> `nil`, meaning "no answer here, use the document's default". Port of
/// `pdf._lead_pt`.
func leadPt(_ lh48: Double?) -> Double? {
    guard let lh48, lh48 > 0 else { return nil }
    return lh48 * 1.5
}

/// Mechanism T (ctrl-kd `tools/PCL-DIVERGENCE-TRIAGE.md`, 21e6d94): the factor
/// `styleLeadPt`'s "auto" (vmi == -2) branch, its too-small-explicit-vmi fallback, and
/// `fontLeadPt`'s WS5+ font-block formula all multiply a governing font size by, for
/// STOCK WordStar 7's single-spacing leading.
///
/// Every prior measurement of this factor (1.2, "19.2pt on a 16pt style", etc. — see this
/// file's own git history and `StyleLeadingTests.swift` before this fix) was taken from
/// `ws7-prints/v1`/`v2`, both captured through Robert J. Sawyer's own WSCHANGE-customized
/// `WS.EXE` — the SAME install mechanism S already found responsible for the `.po`
/// contamination (column 7 vs the manual's/stock's column 8). WSCHANGE's own settings
/// chart (`Installing and Customizing (WordStar 7)`, the "Changing WordStar Settings in
/// WSCHANGE" appendix) lists this exact feature by name, twice (once under the
/// alphabetical chart, once under its own "Leading" cluster alongside "Leading (line
/// height)" BCJ/240):
///
///     Automatic leading, 120% of text size        BCL     OFF
///
/// i.e. "120% of text size" (1.2x) is a WSCHANGE-toggleable setting whose FACTORY DEFAULT
/// IS OFF. Confirmed directly against a `PRISTINE.EXE` (factory, no WSCHANGE) recapture of
/// the same 4 documents whose leading this file already modelled from Sawyer's install
/// (`ws7-prints/v3`): every baseline gap driven by this formula scales by EXACTLY 1/1.2 of
/// the v1 figure, zero exceptions — LYING/WARPRAYR's Title(16pt)->Author gap: 19.2pt (v1,
/// Sawyer) -> 16.0pt (v3, pristine); -SCREEN/PREVIEW's font-block gaps: 14.4pt (v1) ->
/// 12.0pt (v3), and every `fontLeadPt`-governed gap in PREVIEW likewise at exactly 1/1.2.
/// Every OTHER transition this file measures (explicit vmi that already fits its own
/// font, `.lh`-governed lines, a blank line's own RAW lead) is IDENTICAL between v1 and
/// v3 — confirming this factor is the ONLY thing that moved between the two installs.
///
/// So: 1.0 (plain single-spacing, no auto-leading padding) is STOCK WordStar 7's real
/// behaviour; 1.2 was Sawyer's own personalization, exactly like `.po` column 7 and
/// page-numbering-off before it. The engine models stock. Swift-convention counterpart of
/// Python's `pdf.AUTO_LEAD_FACTOR` (same value, same call sites) — NOT `modernLine`
/// (`PDFModernLayout.swift`), which is Modern's own, deliberate, Word-convention 1.2x
/// single-spacing and stays 1.2 regardless of this constant (CLAUDE.md: "Modern diverges
/// from paper BY DESIGN").
let autoLeadFactor = 1.0

/// `fontLeadPt`'s governing-size ceiling (planning #233, ERROR.WS, 2026-09-09): a WS5+
/// FONT-BLOCK document's oversized DECORATIVE title-card sizes (72pt/42pt) do NOT carry
/// the auto-lead scaling the way PREVIEW.WS's 24pt font blocks do (the mechanism-T oracle
/// above, still the largest size with real WS7 evidence of scaling). Measured directly
/// against `sawyer/FONTS/PS/ERROR.WS`'s real WS7 capture (`tools/pcl_text.py` on
/// `ws7-prints/v4/sawyer__FONTS__PS__ERROR_EXT_WS.pcl`, a real LaserJet PCL5 capture,
/// gpcl6-rendered PNG confirms the visual): "ERROR!" (72pt) to "Must Sterilize!" (42pt) is
/// a clean 5-line-feed run (`\r\n` x5 in the source bytes) covering exactly 60.0pt —
/// 12.0pt/line-feed, the document's own flat `.lh` default (`lh48=8.0`), NOT 72.0pt/line
/// as the ungated governing-size formula computes. "Must Sterilize!" (42pt) to "No new
/// WORDSTAR.PS produced" (20pt) is a 10-line-feed run covering exactly 120.0pt — again
/// 12.0pt/line, not 42.0pt. Both gaps decompose to ONE clean constant with zero residual.
/// PREVIEW.WS's own three 24pt transitions (Times->Univers, Univers->Aachen,
/// Aachen->Courier) are clean 2-line-feed runs at exactly 24.0pt/line-feed each
/// (`ws7-prints/v3/PREVIEW.pcl`) — governing-size scaling IS real, just not above whatever
/// ceiling separates 24pt (scales) from 42pt (doesn't). No corpus document exercises this
/// un-`.lh`'d auto-lead path at an intermediate size (every other big-font document found —
/// LJ6DTP.WS, PRINTER.PS, fontcrib.ws, WINGDING.CHT, SYMBOL.CHT — sets its own explicit
/// `.lh` around its decorative text, routing around this formula entirely per its own
/// guard below). Rather than guess a number between the two measured points, the ceiling
/// is set at the largest size real WS7 evidence actually confirms scales, 24.0pt: at or
/// under it, a proportional font's own declared size governs (unchanged behaviour); over
/// it, it degrades to the SAME "reset the carried state, fall back to the document
/// default" treatment a fixed-pitch font already gets (see `fontLeadPt`'s own doc comment)
/// — an oversized decorative font's own line, and every blank line after it, prints at the
/// plain document-default lead, not its own huge size. Swift-convention counterpart of
/// Python's `pdf.FONT_LEAD_CAP_PT`.
let fontLeadCapPt = 24.0

/// The baseline-to-baseline leading a WS7 paragraph STYLE dictates for every physical
/// line in `block` (`Block.lineHeightVMI`/`styleFontPt`, set from the style record's own
/// font/line-height fields — `parseWS`'s style-selection parse). `nil` when no style
/// governs this block, or the style set no line height of its own: the caller falls back
/// to the pre-existing `.lh`/document-default leading UNCHANGED, so a WS4 or otherwise
/// styleless document never shifts.
///
/// vmi == -2 ("auto" — the ONLY value seen on every style in the measured oracle,
/// LYING.WS/LYING.pcl): real WS7 leading is `autoLeadFactor`x the style's own font size,
/// not the document's fixed default — originally measured 2026-08-20 from PCL decipoint
/// baseline gaps against `ws7-prints/v1` (Sawyer's WSCHANGE-customized install): Title/
/// Author (16pt style) 192 decipoints (19.2pt) apart, Body (12pt) 144 decipoints (14.4pt)
/// apart, and a blank line between a 16pt block and the next 12pt block contributing its
/// OWN 19.2pt of the two lines' combined 336-decipoint (33.6pt) gap — a blank line
/// advances at ITS block's leading, which `styleFontPt` already gives it (block-level,
/// not read off the line's own spans, precisely because a blank line carries no
/// spans/font tag of its own — see `Block.styleFontPt`). Falls back to the document's own
/// printed SIZE (`printedSize`) if the style declared no font of its own (an all-zero/
/// recordless font triple).
///
/// UPDATE (mechanism T, `autoLeadFactor`'s own doc comment): the 1.2x/19.2pt/14.4pt/
/// 33.6pt figures above were measured against Sawyer's `ws7-prints/v1` install. A
/// `PRISTINE.EXE` (factory, no WSCHANGE) recapture of the SAME documents
/// (`ws7-prints/v3`) shows every one of these gaps at exactly 1/1.2 of the number above
/// (Title/Author 19.2pt -> 16.0pt, Body-to-Body 14.4pt -> 12.0pt, the blank-line-spanning
/// 33.6pt -> 28.0pt) — stock WordStar 7's real auto-leading factor is 1.0, not 1.2; see
/// `autoLeadFactor`'s own doc comment for the manual citation and the full v1-vs-v3
/// evidence table. Left the rest of this doc comment's OLD (Sawyer-measured) numbers as
/// written below — still an accurate record of what was measured and when — rather than
/// editing every instance; only the LIVE factor (`autoLeadFactor`) changed.
///
/// vmi > 0: an EXPLICIT count, in the same 1/1440in VMI unit WSFORMAT.WS documents for a
/// font's own height word ("Font height in VMIs (1/1440ths)") — so vmi/20.0 is points,
/// the identical conversion a font's height word already gets. Evidenced from the format
/// spec's own text, not guessed.
///
/// UPDATE 2026-08-20 (b26 round 26 wave 3, ctrl-kd's `fidelity_gate.py` Unit A): a WS7
/// oracle for a vmi>0 style now DOES exist — WARPRAYR.pcl (ws7-prints/v1), which this
/// docstring previously (wrongly) said was never printed on real WS7. WARPRAYR carries
/// vmi=240 on both its byline (16pt) and its entire body (12pt). The vmi/20.0=12pt formula
/// above is CONFIRMED, not contradicted, for the body: WARPRAYR.pcl's own baseline_gaps_pt
/// run 12.0pt for ~20 consecutive body-paragraph lines, exactly vmi/20 at 12pt font, with
/// zero drift. The ONE anomaly is the byline's OWN baseline, 19.2pt below the title's
/// (78.9 -> 98.1), not the 12pt vmi/20 (or the document default, also 12pt) predicts.
///
/// An EARLIER version of this comment special-cased vmi==240 to behave like -2/auto
/// everywhere (reasoning from the byline anomaly alone, plus 240 being suspiciously
/// identical to WSCHANGE's own "VMI units for line height" factory default, Installing
/// and Customizing p.2-47, DBA2H). That over-generalised: applied to the BODY it made
/// every body line 14.4pt instead of the CONFIRMED 12pt, which does get WARPRAYR to the
/// WS7 page count (3) but at the cost of a much larger positional residual within the
/// page (median jumped from ~2.5pt to 24pt) — fitting the one number the task asked for
/// by breaking twenty it didn't. Reverted, and a margin-COLLAPSING hypothesis (the
/// byline's OWN entry gap borrows the outgoing title block's larger lead, CSS-style) was
/// reported instead of acted on — correctly: it isn't margin collapsing.
///
/// FIX B (b26-print-fidelity-2), the evidence-backed resolution: the byline's vmi
/// (240 = 12pt) is simply too SMALL for its own 16pt font — 12pt leading on 16pt type
/// overlaps ascender-to-descender, so WS7 falls back to the SAME auto formula (1.2x the
/// style's own size, 19.2pt) an unset vmi already gets. The body's vmi=240 on its OWN
/// 12pt font is the negative case that PROVES this doesn't regress: 240/20 = 12.0 >=
/// 12.0, no fallback, the already-CONFIRMED 12.0pt stands untouched. Cross-checked
/// against every OTHER styled document in the corpus before landing: LYING's four
/// styles are all vmi=-2/auto (never reach this branch); OCAPTAIN/TWAINLET carry no
/// paragraph styles at all.
///
/// RESOLVED by Fix C's full block-transition inventory (below, and `enteringLeadPt`):
/// this doc comment's own UPDATE section originally read the byline's 19.2pt as a
/// property of the WHOLE Author block (so this fallback was applied uniformly, per
/// block, to every line). That was ALSO wrong, just less visibly — Author's own
/// trailing BLANK line (the one line inside it besides the byline itself) measures its
/// OWN space at 12.0pt, the UNFALLEN-BACK vmi/20, not 19.2pt. The fallback protects
/// against a REAL line's ascender/descender clipping into the line above — a blank line
/// has no glyphs to clip, so it never needs it: `raw: true` (every BLANK line, and the
/// value a block hands to `enteringLeadPt` as the NEXT block's "outgoing" reference)
/// always returns the unfallen-back vmi/20, regardless of position in the block.
/// `raw: false` (the default, every REAL line, first or not — every EXISTING call site
/// before Fix C only ever rendered a block's OWN first line through this function, so
/// this is the identical behaviour there) keeps the fallback.
///
/// RESOLVED (planning #256, sawyer/REF/-HOW-TO.RJS): this function used to return `nil`
/// outright for ANY document that ever used a real `.lh` dot command (`doc.page?.lhSource
/// == .file`), on the stated reasoning that "no corpus evidence exists for how real WS7
/// arbitrates a style's vmi against an ACTIVE `.lh`". -HOW-TO.RJS IS that evidence: its
/// ONE `.lh14/72"` (14pt) sits immediately before a `.pa` page break's heading paragraph,
/// which — like the numbered list that follows it — carries the SAME real paragraph
/// style ("Editing Defaults", vmi=240 = 12pt on its own font). Measured against the real
/// WS7 v4 PCL capture: the heading (14pt Univers) prints at a 14pt lead (vmi/20 = 12pt is
/// SMALLER than its own 14pt font — the too-small-vmi fallback below, `size *
/// autoLeadFactor`, already gives exactly this), and every 10pt-font list-item line
/// prints at the style's own EXPLICIT 12pt (vmi/20, no fallback needed — 12 >= 10). The
/// stale, document-global `.lh14/72"` value (14pt) is what a bare `.lh`-wins-
/// unconditionally reading was producing for the list items instead — wrong by 2pt per
/// line, compounding across the whole page. The style's own vmi now governs whenever a
/// block carries one — exactly the intent this doc comment already stated a few
/// paragraphs up ("a style's own leading... governs OVER the generic `.lh`/document
/// default") but a defensive, unevidenced document-wide veto silently contradicted (see
/// each call site's own comment for the other half of this fix: `ownLead` must let
/// `styleLead` win outright, not only when a line's own carried `.lh` happens to be
/// unset). Port of Python's `pdf._style_lead_pt`.
func styleLeadPt(_ block: Block, _ doc: Document, raw: Bool = false) -> Double? {
    guard let vmi = block.lineHeightVMI else { return nil }
    if vmi == -2 {
        // Python: `if not size: size = _printed_size(doc)` -- falsy catches both `None`
        // and a literal 0.0, not just the sentinel's absence.
        var size = block.styleFontPt ?? 0
        if size == 0 { size = Double(printedSize(doc)) }
        return size * autoLeadFactor
    }
    if vmi > 0 {
        // Finding B (b26-print-fidelity-2): an explicit vmi too SMALL for the style's
        // own font falls back to the SAME auto formula (autoLeadFactor x the style's
        // own size) an unset vmi already gets — WARPRAYR's Author style (vmi=240=12pt
        // on a 16pt font; 12pt lead on 16pt type would overlap ascender-to-descender)
        // measures 16.0pt (stock, autoLeadFactor x 16 — see mechanism T /
        // `autoLeadFactor`'s own doc comment for the v1-Sawyer-vs-v3-pristine
        // measurement this factor is now taken from; was 19.2pt/1.2x16 under Sawyer's
        // install). The Body style's vmi=240 on its OWN 12pt font is the negative case
        // PROVING vmi/20 remains correct when it fits (240/20 = 12.0 >= 12.0, no
        // fallback) — the already-CONFIRMED 12.0pt body leading (~20 consecutive
        // lines, zero drift), unmoved by this fix.
        //
        // `raw` (Fix C, b26-print-fidelity-2): the fallback above protects a REAL
        // line's ascender/descender from clipping into the line above — a BLANK line
        // has no glyphs to clip, so it never needs it. `raw: true` skips the fallback
        // and returns the unfallen-back vmi/20 always — see `enteringLeadPt`, which is
        // the ONLY caller that ever passes `raw: true` (for the block being LEFT, never
        // the one being entered), and the direct blank-line call sites in
        // `resolvePlainBody`/`resolvePrintedBody`. `raw: false` (the default) is every
        // EXISTING call site's own behaviour, unchanged.
        let pt = Double(vmi) / 20.0
        if let size = block.styleFontPt, !raw, size > 0, pt < size {
            return size * autoLeadFactor
        }
        return pt
    }
    return nil
}

/// A block's own FIRST REAL (non-blank) physical line's lead: `styleLeadPt`'s
/// font-relative fallback (Finding B), floored against the block being ENTERED's own
/// natural minimum — Fix C (b26-print-fidelity-2, WARPRAYR.WS). An EXPLICIT (vmi>0)
/// style's first line never sits CLOSER to the preceding content than that content's
/// own RAW lead was — i.e. entering an explicitly, tightly-leaded block never crowds
/// whatever was above it.
///
/// Full block-transition inventory (WARPRAYR.pcl, WS7 frame, blank-line +
/// entering-line combined gaps — a blank line carries no glyph, so only the PAIR is
/// independently measurable; stock/v3 numbers, 1.2x/v1-Sawyer numbers alongside where
/// they differ — mechanism T, `autoLeadFactor`'s own doc comment):
///     Author(fallback,16.0; was 19.2) -> Body(vmi 240=12, fits)  24.0 = 12.0 + 12.0 (UNCHANGED — all-raw/fitting)
///     Body(vmi 240=12)    -> Quote(auto,12.0; was 14.4)  x2      24.0 = 12.0 + 12.0 (was 26.4 = 12.0 + 14.4)
///     Quote(auto,12.0; was 14.4)    -> Body(vmi 240=12)  x2      24.0 = 12.0 + 12.0 (was 28.8 = 14.4 + 14.4)
/// Only the Quote -> Body pairs need MORE than `styleLeadPt` alone gives (Body's own
/// 12.0 entering gap) — WS7 floors Body's own entering gap at Quote's own 12.0 instead
/// (a no-op at stock's factor, since Quote's own and Body's own both land on 12.0
/// already; the floor's EXISTENCE is still proven by the Sawyer/v1 numbers, where
/// 12.0 < 14.4 and the floor visibly engages). Author -> Body does NOT need this floor
/// once Finding B's fallback is correctly scoped to REAL lines only (`raw: true` for
/// Author's OWN blank line, above): Author's raw/exported lead is 12.0 (not its
/// fallback value, whatever the live factor makes that), so Body's own entering gap
/// (12.0) is ALREADY >= it, no floor needed — matching the measured 24.0 exactly with
/// no special case, at either factor.
///
/// Cross-checked against LYING.WS, which is entirely auto styles (no vmi>0 block
/// exists there to test the floor itself) but DOES cover the discriminating case this
/// floor must NOT fire for: Author(auto, 16.0; was 19.2) -> Subtitle(auto, 12.0; was
/// 14.4) measures 28.0 (was 33.6) = 16.0 + 12.0 — Subtitle's OWN entering gap, NOT
/// floored up to Author's outgoing 16.0 (which would give 32.0, wrong). The floor
/// therefore only applies when the block being ENTERED has an EXPLICIT vmi (this
/// function's own `vmi > 0` guard below) — a genuinely auto style already computes
/// generously relative to its own font and needs no protection against the block
/// before it; this is the ONE rule shape that fits every transition in both measured
/// styled documents, in both directions, with no unexplained gap, at either factor.
///
/// NOT independently confirmed: a SECOND real (non-blank) line inside a too-small-vmi
/// style also getting the fallback rather than the raw value — no such line exists in
/// the corpus (WARPRAYR's Author block has exactly one real line). Reasoned from the
/// SAME clipping rationale Finding B's own fallback rests on (a real line's
/// ascender/descender doesn't stop clipping just because it isn't the block's first),
/// not from a second measurement.
///
/// UPDATE 2026-09-08 (#236, INTERVU.WS/WORDSTAR.WS title blocks): the LYING.WS
/// cross-check above and the "auto never needs the floor" conclusion it supported only
/// ever exercised a transition with a BLANK line between the two blocks (Author's own
/// trailing blank separates it from Subtitle) — the blank line already provides real
/// separation, at ITS OWN (outgoing) block's lead, before Subtitle's first real line is
/// even reached, so no extra floor is needed there. INTERVU.WS's title block is the
/// discriminating case that reading never covered: three single-line AUTO-style
/// paragraphs stacked with NO blank line between them at all (H1 "Why I Still Use
/// WordStar:" directly followed by H2 "An Interview...", no intervening blank).
/// Measured directly against WS7's own capture: H1(18pt)->H2(16pt) advances 18.0pt
/// (H1's OWN outgoing size, not H2's entering 16.0), and H2->H3(14pt) advances 16.0pt
/// (H2's own outgoing size) — the identical floor this function already applies for an
/// explicit vmi, engaging for auto too, but ONLY when the line above is REAL (no blank
/// line already did the job). The floor therefore applies whenever the block being
/// ENTERED has an EXPLICIT vmi (unconditionally, as before), OR an auto (-2) vmi AND
/// the previous block's own LAST line still carries real content (no blank line
/// intervening) — a genuinely auto style needs no protection when a blank line already
/// separated it from what came before, but does need it butted directly against
/// another real line, for the same ascender/descender-clipping reason Finding B's own
/// fallback exists. Port of Python's `pdf._entering_lead_pt`.
func enteringLeadPt(_ block: Block, _ doc: Document, prevBlock: Block?) -> Double? {
    guard let own = styleLeadPt(block, doc, raw: false) else { return nil }
    guard let prevBlock else { return own }
    let vmi = block.lineHeightVMI
    let explicit = (vmi ?? 0) > 0
    let autoAdjacent = vmi == -2 && (prevBlock.lines.last?.spans.isEmpty == false)
    guard explicit || autoAdjacent else { return own }
    guard let prevRaw = styleLeadPt(prevBlock, doc, raw: true) else { return own }
    return max(own, prevRaw)
}

/// This physical line's own baseline-to-baseline lead in points, for a WS5+ FONT-BLOCK
/// document with no paragraph style governing the line (`styleLeadPt` returns `nil` for
/// every line here — PREVIEW.WS, the oracle behind this rule, carries no styles at all).
///
/// CALLER'S GATE, not this function's: only consulted (own lead stays `nil` otherwise)
/// when `doc.fonts` contains at least one PROPORTIONAL entry — a document-WIDE mode switch,
/// not a per-line one. -README.WS is the negative oracle for this: it carries exactly one
/// font-block record, a 12pt FIXED-PITCH Courier entry (likely the installation's own
/// default-face declaration, not an author's deliberate `.fp` insertion), and its WS7
/// capture prints flat 12pt leading throughout (baseline_gaps_pt: 12.0 between consecutive
/// body lines) — NOT the 14.4 (1.2x12) this function would compute if consulted for every
/// one of its Courier-tagged lines. PREVIEW.WS's own 12pt sections (its 3-line Courier
/// intro, BEFORE any font tag has even appeared in the stream) measure 14.4 despite being
/// just as fontless-looking at that exact point — the only document-level difference is
/// that PREVIEW contains real proportional font blocks (Times/Univers/Aachen) elsewhere and
/// -README never does. So a document with no proportional font block anywhere — SAWYER,
/// VERSIONS, TWAINLET, OCAPTAIN, every fontless doc in the corpus, AND -README's
/// single-fixed-font case — must stay on the byte-identical 12pt grid throughout, full stop.
///
/// UPDATE (mechanism T, `autoLeadFactor`'s own doc comment): every "1.2x"/absolute point
/// value in this doc comment (14.4, 24.0, …) was measured against Sawyer's `ws7-prints/v1`
/// install; re-measured 2026-09-07 against the same document's `ws7-prints/v3`
/// PRISTINE.EXE recapture, which shows the identical shape at exactly 1/1.2 of every v1
/// number. Stock's real formula is `autoLeadFactor`x, not 1.2x — see `autoLeadFactor`'s
/// own doc comment for the full evidence table.
///
/// `state` is `inout`, owned and threaded by the CALLER across every physical line of the
/// document in source order (mirrors `pendingSa`'s cross-block carry): a blank line (no
/// font tag of its own) inherits whatever `state` already holds, exactly as a real
/// printer's VMI-select state would survive an empty line with no command bytes to change
/// it.
///
/// RULE (measured 2026-08-20 against PREVIEW.WS/PREVIEW.pcl, `fidelity_gate.py` Finding B —
/// every gap on the page decomposes to 0.3pt residual under it): `autoLeadFactor`x the
/// largest PROPORTIONAL font size (`FontChange.proportional == true`) active anywhere on
/// the line, carried forward through blank lines. A FIXED-PITCH font block (Courier, any
/// declared point size) NEVER raises the governing size above the document default and, as
/// the LAST font tag active on a line, RESETS the carried state — WS5+ Courier font blocks
/// change PITCH (historically elite/pica variants of the one typewriter face), not real
/// vertical measure, so a 20pt Courier block's own line and every blank line after it print
/// at the plain `autoLeadFactor`x12 = 12.0pt (stock) default, not `autoLeadFactor`x20.
/// Confirmed on PREVIEW's OWN 12pt intro (no font tag at all yet — 12.0pt gaps, 14.4pt
/// under Sawyer's install) and its trailing Courier-20pt block (6 blank continuation
/// lines, all 12.0pt, not 20.0pt) alike — both land on the SAME formula via `state`, not a
/// special case. A line whose OWN leading spaces still carry the OUTGOING tag before a
/// mid-line font change (WordStar's own encoding: the change lands after the characters it
/// precedes, not at line start) takes the LARGER of every proportional size found on the
/// line, matching a real printer sizing the line to its tallest glyph.
///
/// NOT APPLIED when the document ever used a real `.lh` (guarded by the same
/// `lhSource == .file` check `styleLeadPt` uses) — no corpus evidence exists for how real
/// WS7 arbitrates a font block's own size against an ACTIVE `.lh`, so that combination is
/// left to the pre-existing `.lh`-based mechanism, unconditionally, same doctrine as
/// `styleLeadPt`'s own guard.
///
/// CEILING (planning #233, `fontLeadCapPt` — see its own doc comment for the full
/// ERROR.WS/PREVIEW.WS evidence): a proportional font block whose OWN declared size
/// exceeds `fontLeadCapPt` never governs — it is treated exactly like a FIXED-PITCH block
/// for this function's purposes (does not raise `propSizesHere`, RESETS the carried
/// `state` the same way a Courier tag does). A 72pt or 42pt decorative title-card font's
/// own line, and every blank line after it, therefore prints at the plain document-default
/// lead, matching real WS7 — only sizes at or under the cap (the largest real WS7 evidence
/// confirms scales, 24pt) get the governing-size treatment described above.
///
/// ORDERING, and the VIRGIN/ESTABLISHED distinction in `state`, both planning #233 (second
/// half of the same evidence — ERROR.WS's residual 8.0pt after the ceiling alone): a
/// line's OWN font tag governs the ENTERING advance of the line AFTER it, generally never
/// its own — WordStar's byte encoding puts a font-change record right before the text it
/// applies to, AFTER that text's own leading `\r\n`, so the vertical move that PLACES a
/// line usually happens before that line's own tag has even been read. ERROR.WS's "No new
/// WORDSTAR.PS produced" proves this directly: it carries its own 20pt Triumvirate tag
/// (within the ceiling), but its real entering advance is the SAME flat 12.0pt as the nine
/// purely-blank lines before it, not 20.0pt — because `state` was already ESTABLISHED at
/// the document default by "Must Sterilize!"'s 42pt tag exceeding the ceiling immediately
/// before this run, and an established `state` always wins over a line's own tag.
///
/// But `state` starting VIRGIN (nothing has ever governed — the very first proportional
/// tag in the whole document) is different, and PREVIEW.WS's own Times-Roman heading (its
/// FIRST proportional tag) is the oracle that tells the two apart: `ParseWS`'s own parse
/// gives this engine only 4 blank `Line` records between the document's plain-12pt intro
/// and the Times heading, one fewer than the capture's real 6-line-feed gap (720
/// decipoints/72.0pt) — the parse folds a `.oc off` dot-command's line into the record
/// that follows it, a parse-level detail invisible to WS7's own byte-for-byte vertical
/// motion. Crediting the Times heading's OWN 24pt tag to ITS OWN entering advance (4 blank
/// x 12 + 1 x 24 = 72) reproduces the real 72.0pt exactly; forcing it through `state`
/// (still nil, "fall back to base" once VIRGIN state is read literally as "no size") would
/// under-shoot by exactly one line (60, not 72) — the residual this distinction fixes.
/// Once ANY tag has been seen, real or reset, `state` becomes ESTABLISHED (see below) and
/// every later line, including one with its own in-range tag (Univers/Aachen in PREVIEW,
/// "No new..." in ERROR.WS), is governed by `state` alone.
///
/// So: `state` is `nil` ONLY before the first font tag of the whole document; every reset
/// (`fontLeadCapPt` exceeded, or a fixed-pitch tag) sets it to `baseSize` itself — an
/// ESTABLISHED real number, not `nil` — specifically so a LATER in-range tag can never
/// again fall back to governing its own line the way a virgin `nil` would. The scan below
/// still folds every proportional size found ON a line into what `state` becomes for the
/// NEXT line (still `max()` of them, for a mid-line font change's padding — see the
/// paragraph above); only which value THIS line's own return uses — `state` if already
/// established, else this line's own scan — is new. Port of Python's `_font_lead_pt`.
func fontLeadPt(_ line: Line, fonts: [FontChange], baseSize: Double, state: inout Double?)
    -> Double
{
    func entry(_ span: Span) -> FontChange? {
        guard let fidx = span.font, fidx >= 0, fidx < fonts.count else { return nil }
        let e = fonts[fidx]
        return e.points > 0 ? e : nil
    }
    var governing = (state ?? 0) > 0 ? state! : baseSize
    for span in line.spans {
        if let e = entry(span), e.points > governing { governing = e.points }
    }
    if let last = line.spans.last {
        let e = entry(last)
        state = (e?.proportional ?? false) ? e!.points : baseSize
    }
    return governing * autoLeadFactor
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
    /// (the notes-aware paginator's pages, the column merge, the wrapped bare lists) --
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
    /// mid-document (see `mtMbCheckpoints`). Threading the SAME resolved pair from
    /// pagination-time (which already had to know it, to size the page's own capacity)
    /// through to render-time (`emitPDF`'s per-page loop) keeps the two in agreement by
    /// construction, rather than re-deriving the same answer twice from
    /// `Document.dotPositions`. Set only by `layoutPrintedPagesPlain` — the
    /// footnote/annotation/endnote-aware paginator (`layoutPrintedPages`) never touches
    /// these, matching Python's `_paginate_printed_notes` (unchanged by Finding 3).
    public var mtLines: Double?
    public var mbLines: Double?
    /// `.pl` in force when this page's own pagination started (register b31-dot-command-
    /// sweep, `plCheckpoints`) -- `nil` for "the document's global (first-occurrence)
    /// value", the same contract as `mtLines`/`mbLines` above.
    public var plLines: Double?
    /// `.hm`/`.fm` in force when this page's own pagination started (register b31-dot-
    /// command-sweep, `hmFmCheckpoints`) -- same `nil`/"document global" contract again.
    public var hmLines: Double?
    public var fmLines: Double?
    /// `.po` (page offset) in force when this page's own pagination started (mechanism O,
    /// `poCheckpoints`) -- same `nil`/"document global" contract again. Feeds `runningOps`'s
    /// own header/footer LEFT edge only -- body text already carries a per-LINE `.po`
    /// override (`Line.poCols`, applied in `resolvePlainBody`/`resolvePrintedBody`), this is
    /// the page-granularity twin that mechanism was missing. Port of Python's `Page.po_cols`.
    public var poCols: Double?
    /// M31: the `.pr or=` in force when this page's own pagination started -- `nil` for
    /// "the document's own orientation", the same contract as everything above it. Unlike
    /// every other value here it reaches the SHEET: the page's MediaBox, the height its
    /// content stream is drawn through, and its running head/foot row. See
    /// `orCheckpoints` for the measured WS7 timing rule that decides which page a
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
    /// replayed from `doc.hfEventsPcl` exactly as `headers`/`footers` are replayed from
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

/// Whether the document has any note that gets a PLACE on the printed page (a footnote
/// or annotation footer entry, or an endnote's end-of-document entry) — comments never
/// print. Port of Python's `_has_placeable_notes`. Documents with none of these go
/// through the plain points-based paginator (`layoutPrintedPagesPlain`); documents WITH
/// them keep the dedicated footnote/annotation-area paginator (`layoutPrintedPages`,
/// unchanged by this port) that grows a page-bottom area and floors body at 3 lines —
/// exactly the split Python's own `_doc_to_pagelines` makes.
func hasPlaceableNotes(_ doc: Document) -> Bool {
    doc.notes.contains { $0.kind == .footnote || $0.kind == .endnote || $0.kind == .annotation }
}

/// A comment's reference mark is POSITION, not ink — it renders nowhere on this path
/// (printed facsimile, or the plain line layer). Port of `_doc_to_pagelines`'s
/// `_keep_span` (ruling 2026-08-06 M9).
///
/// `printed`: a ^ONI index ENTRY (`Span.indexEntry`) is the index file's text, not the
/// page's — real WS7 spends the row and prints nothing on it (MEASURED, ws7-prints/v4
/// `sawyer/REF/-INDEX.HOW`; see `symmetricBlocks`' cmd 0x0E branch). PRINTED only: every
/// other emitter, Modern included, keeps the phrase exactly as it always did.
func keepSpanOnPageline(_ span: Span, refNotes: [Note], printed: Bool = false) -> Bool {
    if printed, span.indexEntry { return false }
    if span.styles.contains(.fnref), let k = Int(span.text),
       k >= 1, k <= refNotes.count, refNotes[k - 1].kind == .comment {
        return false
    }
    return true
}

/// Wrap one IR line's spans to `width` columns, preserving styles. Port of `_wrap_line`
/// (pdf.py:36-55).
///
/// Greedy first-fit over words and space-runs, which is what a typewriter would have done.
/// A word longer than `width` overflows rather than being broken — `col &&` in the Python
/// guard means a token placed at column 0 is always placed.
///
/// Returns at least one line, empty if the input was: a blank IR line is a blank page line,
/// not nothing at all, and `docToPagelines` counts on that for its paragraph spacing.
public func wrapLine(_ spans: [Span], width: Int) -> [PageLine] {
    // Words and space-runs, each carrying the styles of the span it came from. Python splits
    // on `( +)` — a capture group, so the separators are kept — and drops the empty strings
    // that fall out at the edges.
    var tokens: [Span] = []
    for span in spans {
        for piece in splitKeepingSpaceRuns(span.text) {
            tokens.append(Span(text: piece, styles: span.styles, font: span.font))
        }
    }

    var lines: [PageLine] = []
    var line: PageLine = []
    var col = 0
    for token in tokens {
        if !isSpaceRun(token.text), col > 0, col + token.text.width > width {
            while let last = line.last, isSpaceRun(last.text) {   // no trailing spaces
                col -= last.text.width
                line.removeLast()
            }
            lines.append(line)
            line = []
            col = 0
        }
        line.append(token)
        col += token.text.width
    }
    while let last = line.last, isSpaceRun(last.text) {
        line.removeLast()
    }
    if !line.isEmpty || lines.isEmpty {
        lines.append(line)
    }
    return lines
}

/// Merge adjacent same-style segments into single text runs. Port of `_coalesce`
/// (pdf.py:114-122).
///
/// The wrapper leaves one segment per word and one per space-run; the byte writer emits a
/// text-showing operator per segment. Merging first is the difference between a page of a
/// few hundred operators and a page of a few thousand, and changes nothing on paper because
/// Courier's advance width is the same either way.
///
/// THE FONT RUN IS INCLUDED IN THE MERGE TEST, added with printed-mode base-14 fonts
/// (`PDFFonts.swift`): two adjacent spans set in different faces are not the same run, and
/// merging them would set the second one in the first one's font. Python gets this free —
/// its font index rides in the same `frozenset` as the style codes, so its `styles ==
/// styles` covers both — and this comparison is that equality written out. A document with
/// no font runs has `nil` on every span and is unaffected, which is why no fontless byte
/// changed.
public func coalesce(_ line: PageLine) -> PageLine {
    var out = PageLine([], lead: line.lead)     // the merge changes segments, never the lead
    for span in line {
        // `pix` is part of the merge test for the same reason the font run is: Python's
        // `pix<N>` tag rides in the styles frozenset, so its `styles == styles` keeps a
        // pix placeholder its own span (layout byte parity, 2026-08-18).
        // `pcl` joins the test for the same reason (register C2): Python tags a print
        // control's raw-PCL payload as its own `pcl<N>` style string, so two ADJACENT
        // controls -- LJ6DTP's checkerboard row is a long run of them, every one
        // declaring the same 0 HMI width -- never merge into a single span there. Merged
        // here, the second control's program was silently lost and the page border
        // stopped drawing on the pages where two controls sit side by side.
        // `tabHMI`/`tabLeader` likewise (the tab-positioning fix): Python's
        // `tabhmi<N>`/`tableader<N>` tags are unique to a tab's own padding span, so
        // `_coalesce` there never merges it with the real text before or after it. That
        // uniqueness is what lets the PDF layer see a tab as a span of its own -- pad
        // equals 0 or the whole length, never a mixed split.
        if let last = out.last, last.styles == span.styles, last.font == span.font,
           last.colour == span.colour, last.pctlHMI == span.pctlHMI, last.pix == span.pix,
           last.pcl == span.pcl, last.tabHMI == span.tabHMI,
           last.tabLeader == span.tabLeader {
            out[out.count - 1].text += span.text
        } else {
            out.append(span)
        }
    }
    return out
}

/// Planning #227 (research/2026-09-08_columns-rule.md), port of ctrl-kd's own
/// `_apply_columns`: regroup a finished, ordinary single-column `pages` list into real
/// `.co n` newspaper-column pages -- a POST-PASS over pagination's own output, not a
/// change to the pagination budget loop itself.
///
/// Why a post-pass works at all: a column is never vertically shorter than the page it's
/// on (measured: every `.co`-bearing document in the corpus), so the ordinary
/// single-column pagination loop, run unmodified, already produces exactly the right
/// BREAK POINTS for a columnar region's content -- each "page" it closes is precisely one
/// column's worth of material, because column height and page height are the same
/// budget. `resolvePlainBody`/`resolvePrintedBody`'s own block loops guarantee (by
/// forcing a break on every LEAVING `columns` state change, research §7) that a real page
/// coming out of that loop is either wholly non-columnar or wholly one columnar region's
/// own single N/gutter pair -- never a mix, EXCEPT for the one shape research §7 also
/// documents: a non-columnar prefix (a title/ruler line) sharing a page with the START of
/// its `.co` region, no break between them (SYMBOL.CHT/WINGDING.CHT/the FONTCRIB family).
/// That page is classified by the FIRST columnar block referenced ANYWHERE on it, not
/// just its first line's -- the prefix lines simply stay wherever the ordinary pass
/// already put them, becoming column 0's own leading lines unshifted (column 0's own x IS
/// the page's ordinary left origin).
///
/// Column geometry (research §3): a column's own width is the block's `.rm` minus `.po`
/// -- the SAME number that already defines an ordinary single-column line's own right
/// edge, NOT the page width divided by n. Column i's left edge is therefore
/// `baseLeft + i * (columnWidthPt + gutterPt)`, where `baseLeft` is whatever this line's
/// own left origin already resolved to.
///
/// No balancing (research §5): a trailing group of fewer than n columnar pages is merged
/// into one physical page using only the columns actually present -- the remaining column
/// slots are simply never drawn into.
/// The FIRST block of the contiguous `.co n>1` region block `bi` belongs to -- planning
/// #227 follow-up (2026-09-12), the block whose `.rm`/`.co` pair the author wrote
/// together and which therefore fixes the whole region's column grid.
///
/// A REGION'S COLUMN WIDTH IS SET ONCE, BY THE `.co` THAT OPENED IT. `.rm` is stateful
/// and a document may move it INSIDE a live region: `sawyer/MICKEE/MICKEE.WS`
/// alternates `.rm 0.7"` (the little box-drawing figures its `.co2` sets in columns)
/// with `.rm 6.5"` (full-measure prose) all through both of its columnar regions, and
/// `sawyer/PRINTERS/fontcrib.ws` and `sawyer/PRINTER.PS` restate `.rm 6.9i` at the top
/// of every sheet after the first, before restating `.rm .88"` and `.co5`. Reading the
/// width off whichever columnar block a SHEET happens to open with then hands that
/// sheet a completely different column pitch from the one before it -- measured on
/// fontcrib.ws, `.rm 6.9i` gives a 496.8pt column against the region's real 63.36pt
/// one, walking columns 2-5 out to x = 572/1123/1674/2225pt, right off an 8.5in sheet,
/// where real WS7 keeps all five columns in the same place on both sheets. MICKEE.WS's
/// own two columns overprinted for the same reason. A later `.rm` inside a region still
/// moves ordinary lines' right edge, exactly as `.rm` always does; it just no longer
/// re-cuts the column grid.
///
/// SENTINEL BLOCKS ARE SKIPPED, not treated as the region's edge -- `pagebreak`/
/// `colbreak`/`condpage`/`condcolumn` blocks carry no columns state at all (`columns`
/// reads 1 on every one of them), and the corpus's columnar documents are full of them:
/// fontcrib.ws's own region is broken by a `.pa` every 51 blocks, the author's manual
/// column-simulation convention the paginator absorbs. This is the same "real ('para')
/// blocks only" rule the paginator's own `prevCols` tracker already follows. Port of
/// Python's `pdf._region_first_bi`.
func regionFirstBI(_ doc: Document, _ bi: Int) -> Int {
    guard bi >= 0, bi < doc.blocks.count else { return bi }
    var first = bi
    var k = bi - 1
    while k >= 0 {
        let b = doc.blocks[k]
        if b.kind != .para {
            k -= 1
            continue
        }
        if (b.columns ?? 1) <= 1 { break }
        first = k
        k -= 1
    }
    return first
}

// MARK: - MailMerge page-number variables (planning #270 item 40)
//
// Jon's ruling 2026-09-13 (triage Q7): "I guess we can adopt... page numbers seems
// reasonable." WordStar's MailMerge substitutes the page-number variable `&#&` at
// PRINT time with the number of the page the variable lands on, and real WS7 does
// exactly that in both corpus documents that print one:
//
//   sawyer/REF/TOCTRICK.WS       prints `2` on page 2, twice, where the author typed
//                                `&#/r&`
//   sawyer/ARTICLES/POWERUSE.WS  prints `CNT=8` and `8 is a new...` on page 8, where
//                                the author typed `CNT=&#&` and `&#&`
//
// MICKEE.WS (20 occurrences) and RTF-RJS/NOVEL.WS (6) carry the same reference many
// times over, but every one of theirs sits on a `.tc` table-of-contents line, which
// never puts ink on the page — so neither prints one today and neither prints one
// after this change.
//
// SCOPE, from the same ruling's MAIL MERGE paragraph: this is the ONLY merge variable
// that is ever substituted. "A merge letter opens and exports as the letter itself,
// variables shown as-is (not substituted, not stripped), except the page-number
// variables per item 40." Every other `&NAME&` stays visible exactly as typed, in
// every view and every export — which is what keying this to the literal `#` name
// guarantees. WordStar's own trailing `/x` modifiers (`&#/r&`) are accepted and
// ignored: real WS7 prints the plain arabic number for `&#/r&` on TOCTRICK's page 2,
// not a roman numeral. Port of ctrl-kd's `_substitute_merge_page_numbers_printed`.

/// Does `text` carry the two characters `&#`, adjacent, anywhere? The cheap pre-filter
/// in front of the per-character scan below.
///
/// Written as an index walk ON PURPOSE. `String.contains(_:)` taking another STRING is
/// the Swift 5.7 stdlib `Collection` overload and is `@available(macOS 13.0, *)`; this
/// package's floor is macOS 10.15 (Package.swift `platforms:`), so it compiles happily
/// on a modern toolchain and then fails the Mac floor build. `range(of:)` is the
/// Foundation answer, and this module deliberately imports nothing (see
/// `SymmetricBlocks.swift`'s own note on the same constraint). The single-CHARACTER
/// `contains(_:)` other call sites in this module use is the `Sequence` overload and is
/// available at any floor — only the String-argument form is the trap.
func containsMergePageNumberOpener(_ text: String) -> Bool {
    var i = text.startIndex
    while let amp = text[i...].firstIndex(of: "&") {
        let next = text.index(after: amp)
        if next == text.endIndex { return false }
        if text[next] == "#" { return true }
        i = next
    }
    return false
}

/// `&#&` / `&#/r&` — the MailMerge page-number variable, and nothing else. Written as
/// a hand scan rather than a regular expression so the accepted shape is exactly the
/// one this comment describes: `&`, `#`, optionally `/` plus one or more ASCII
/// letters, `&`.
func mergePageNumberRange(_ chars: [Character], from start: Int) -> Int? {
    guard start + 2 < chars.count, chars[start] == "&", chars[start + 1] == "#" else {
        return nil
    }
    var i = start + 2
    if chars[i] == "/" {
        i += 1
        let modifierStart = i
        while i < chars.count, chars[i].isASCII, chars[i].isLetter { i += 1 }
        if i == modifierStart { return nil }          // `&#/&` is not a variable
    }
    guard i < chars.count, chars[i] == "&" else { return nil }
    return i + 1
}

/// Replace every MailMerge page-number variable in a printed page's own body lines
/// with that page's resolved page number, in place.
///
/// Runs as a `docToPagelines` post-pagination pass, BEFORE
/// `attachJustifyWordXPrinted`/`attachGraphicCellsPrinted`, so every per-word x those
/// passes compute is measured on the text that actually prints. Printed physical lines
/// are never re-wrapped, so a substitution that shortens a line cannot move anything
/// onto another page — which is why this can safely run after pagination rather than
/// before it.
///
/// The page number is `resolvePageNumbers`' own answer — the same `.pn`/`.pg`
/// checkpoint walk the running head's `#` and the automatic page number already use,
/// never the page's index — so a document that restarts its numbering substitutes the
/// number WordStar would have printed.
func substituteMergePageNumbersPrinted(_ doc: Document, _ pages: inout [Page]) {
    let pageNumbers = resolvePageNumbers(pnCheckpoints(doc), pages)
    for pageIndex in pages.indices {
        let shown = String(pageNumbers[pageIndex])
        for lineIndex in pages[pageIndex].lines.indices {
            for spanIndex in pages[pageIndex].lines[lineIndex].spans.indices {
                let text = pages[pageIndex].lines[lineIndex].spans[spanIndex].text
                guard containsMergePageNumberOpener(text) else { continue }
                let chars = Array(text)
                var out = ""
                var i = 0
                while i < chars.count {
                    if let end = mergePageNumberRange(chars, from: i) {
                        out += shown
                        i = end
                    } else {
                        out.append(chars[i])
                        i += 1
                    }
                }
                pages[pageIndex].lines[lineIndex].spans[spanIndex].text = out
            }
        }
    }
}

func applyColumns(_ doc: Document, _ pages: [Page]) -> [Page] {
    if pages.isEmpty { return pages }
    let size = printedSize(doc)
    var out: [Page] = []
    var i = 0
    let nPages = pages.count
    while i < nPages {
        let pg = pages[i]
        // A page's own columnar-ness is decided by the FIRST columnar block referenced
        // anywhere on it (see this function's own doc comment for why NOT just the
        // first line's).
        let firstColBI = pg.lines.first { pl in
            guard let bi = pl.bi, bi >= 0, bi < doc.blocks.count else { return false }
            return (doc.blocks[bi].columns ?? 1) > 1
        }?.bi
        let cols = firstColBI.map { doc.blocks[$0].columns ?? 1 } ?? 1
        if pg.isEmpty || cols <= 1 {
            out.append(pg)
            i += 1
            continue
        }
        let blk = doc.blocks[regionFirstBI(doc, firstColBI!)]
        let gutterCols = blk.columnGutter ?? 0.0
        let rmCols = blk.rightMargin ?? 65.0
        let gutterPt = gutterCols * pdfPtPerCol
        let rmPt = rmCols * pdfPtPerCol
        var merged = Page([])
        // Group metadata (headers/footers/margins/geometry) comes from the FIRST
        // sub-page in the group -- "page just started" state, exactly what an ordinary
        // page's own metadata already means.
        merged.headers = pg.headers
        merged.footers = pg.footers
        merged.footerInUse = pg.footerInUse
        // cause 10: the running head's own print controls travel with its text through
        // the merge, same passthrough as `headers`/`footers`.
        merged.headerPcl = pg.headerPcl
        merged.footerPcl = pg.footerPcl
        // planning #250: carry the source page's own parity font/tab override through
        // the merge, same passthrough as headers/footers just above.
        merged.headHfOverride = pg.headHfOverride
        merged.footHfOverride = pg.footHfOverride
        merged.mtLines = pg.mtLines
        merged.mbLines = pg.mbLines
        merged.plLines = pg.plLines
        merged.orientation = pg.orientation
        merged.hmLines = pg.hmLines
        merged.fmLines = pg.fmLines
        merged.poCols = pg.poCols
        merged.poParity = pg.poParity
        merged.autoPagenoPo = pg.autoPagenoPo
        merged.explicitBreak = pg.explicitBreak
        merged.explicitBreakBI = pg.explicitBreakBI
        // planning #227 follow-up (2026-09-09): this page's own column geometry,
        // recorded once here rather than re-derived per line by every consumer --
        // `emitLayout` and Soft Return.app's Native view both need it to draw column
        // boundaries/reset the vertical flow at each column change (see `PageLine.col`'s
        // own doc comment). `columnWidthPt` is captured from the FIRST real line below
        // (whichever column it's in -- the formula is the same for all of them), not
        // re-derived from `printedLeft` here, so it agrees exactly with the per-line
        // `left` values this same loop sets.
        merged.columns = cols
        merged.columnGutterPt = gutterPt
        // planning #227 follow-up (2026-09-12): A COLUMN GROUP SHARES ONE TOP. Every
        // column of this sheet begins where the COLUMNAR REGION begins on it, not at
        // the sheet's own first text line -- so a sheet that opened with a
        // non-columnar prefix (`REF/WINGDING.CHT` and `REF/SYMBOL.CHT`: a title line
        // and its blank, ahead of the `.co5`; `PRINTERS/fontcrib.ws` and `PRINTER.PS`:
        // the same shape) pushes columns 1..n-1 down by exactly that prefix's height.
        // MEASURED against real WS7 (`ws7-prints/v4`, PRISTINE.EXE):
        //   REF/WINGDING.CHT  WS7 columns 2-5 open at 153.2pt, which is `.mt 1.6"`
        //                     (115.2) + 12 + 12 + their own 14pt lead -- NOT the
        //                     sheet's own 129.2pt first line. Same 45 lines as column
        //                     1's columnar part; this engine gave them 46.
        //   REF/SYMBOL.CHT    WS7 124.4pt, 47 lines (engine: 100.4pt, 48).
        //   fontcrib.ws, PRINTER.PS   WS7 66.8pt, 51 lines (engine: 42.8pt, 52).
        // Summed from the prefix lines' OWN leads, the same quantity the paginator
        // charged against each column's budget (`colOffsetPt`) -- derived twice from
        // the same leads rather than threaded. Port of Python's `_apply_columns`.
        var prefixPt = 0.0
        for pl0 in pages[i].lines {
            if let bi0 = pl0.bi, bi0 >= 0, bi0 < doc.blocks.count,
               (doc.blocks[bi0].columns ?? 1) > 1 { break }
            prefixPt += pl0.lead ?? printedLead(doc)
        }
        merged.columnTopOffsetPt = prefixPt
        let groupEnd = Swift.min(i + cols, nPages)
        // A later sub-page belonging to a DIFFERENT columns/gutter pair (a new `.co`
        // restatement) or a non-columnar page ends the group early -- the forced break
        // on state-change (research §7) means this should only ever happen exactly at
        // `i + cols`, never inside it, but the check is cheap insurance.
        var colIdx = 0
        for j in i..<groupEnd {
            let sub = pages[j]
            let subColBI = sub.lines.first { pl in
                guard let bi = pl.bi, bi >= 0, bi < doc.blocks.count else { return false }
                return (doc.blocks[bi].columns ?? 1) > 1
            }?.bi
            let subRegionBlk = subColBI.map { doc.blocks[regionFirstBI(doc, $0)] }
            let subCols = subRegionBlk.map { $0.columns ?? 1 } ?? 1
            let subGutter = subRegionBlk.map { $0.columnGutter ?? 0.0 } ?? 0.0
            if subCols != cols || subGutter != gutterCols { break }
            for var pl in sub.lines {
                let baseLeft = pl.left ?? printedLeft(doc, size: size)
                // `.rm` IS the column's own width. WordStar measures `.rm` from the
                // `.po` origin, not from the paper's left edge -- the same reading
                // `printedHfRight` already uses for an ordinary line's right edge --
                // so there is nothing to subtract.
                //
                // This used to read `rmPt - baseLeft`, and planning #227's own
                // research validated that against `sawyer/REF/SYMBOL.CHT`, whose
                // `.po .0"` is ZERO: the two formulas are identical when `.po` is 0,
                // which is why the subtraction survived. Every OTHER `.co` document in
                // the corpus has a non-zero `.po`, and all of them landed their columns
                // `.po` points per column too far left, overprinting column 1
                // (`sawyer/REVIEW.DOC` page 1 was unreadable for it). MEASURED against
                // real WS7 (ws7-prints/v4, PRISTINE.EXE), column origins in points:
                //   REF/WINGDING.CHT `.po .3"` `.rm .88"` gutter .75"
                //       WS7: 21.6 / 138.9 / 256.3 / 373.6 / 491.0
                //       this formula: 21.6 + i*(63.36 + 54) -- exact
                //       old formula: 21.6 + i*(41.76 + 54)  -- 21.6pt/col short
                //   REVIEW.DOC `.rm 3.13"` gutter .25": WS7 57.6 / 300.9
                //   REF/SYMBOL.CHT `.po .0"` -- unchanged either way.
                // Port of Python's `pdf._apply_columns`.
                let columnWidthPt = rmPt
                if merged.columnWidthPt == nil { merged.columnWidthPt = columnWidthPt }
                pl.left = baseLeft + Double(colIdx) * (columnWidthPt + gutterPt)
                // planning #227 follow-up: the unambiguous "which column, RESET Y"
                // signal -- see `PageLine.col`'s own doc comment. Every real line this
                // loop touches belongs to a column (0 for the page's own non-columnar
                // prefix lines too, per this function's own doc comment: column 0's x
                // IS the page's ordinary left origin).
                pl.col = colIdx
                merged.lines.append(pl)
            }
            colIdx += 1
        }
        out.append(merged)
        i += colIdx > 0 ? colIdx : 1
    }
    return out
}

// The bare-0x09 expansion this file's Printed pageline construction calls
// (`expandBareTabsForPrintedLayout`) moved to `EmitterRules.swift` by planning #264
// item 1 (packet row B3), where Printed RTF and the fixed-pitch HTML block call the
// same one. Same rule, same doc comment, same column-tracking semantics — see it there.

/// IR -> pages of laid-out lines. Port of `_doc_to_pagelines` (pdf.py:57-112) for Modern
/// mode; Printed mode is this project's own addition (job — period-authentic footnote
/// layout), since Python's `pdf.py` never modeled WordStar's real page-bottom footnote
/// area — it ran the same "collect at the end" logic in both modes. See
/// `layoutPrintedPages` below for that half.
///
/// - Parameters:
///   - doc: the parsed document.
///   - printed: line-for-line facsimile (`true`) or reflowed to the text column (`false`).
///     The emitter decides this from the mode and `isPrinted(doc)`; it is a parameter here
///     so the layout can be tested both ways against one document.
///   - sentenceSpacing: N9 (b33 field notes), pre-resolved bool (`true` = 'single') —
///     `false` is the correct default for every internal re-pagination caller
///     (`tocPageNumbers`), since Printed's physical lines never wrap, so collapsing an
///     interior double space never changes line/page counts and this parameter cannot
///     affect where anything lands; only the real render call (`emitPDF`) needs to pass
///     the resolved value through.
/// - Returns: at least one page, possibly a single empty one.
public func docToPagelines(
    _ doc: Document, printed: Bool, pixResults: [PixResult] = [],
    pictures: EmitOptions.PixMode = .off, sentenceSpacing: Bool = false,
    maxPages: Int? = nil
) -> [Page] {
    let isPrintStream = doc.detection?.variant == .printstream
    // planning #271 M10. `maxPages: 1` must return EXACTLY the full call's `pages[0]`,
    // byte for byte -- a thumbnail that disagrees with the document is worse than a slow
    // one -- so the prefix is only taken where nothing downstream of pagination reads
    // the pages it would not have built. Three cases where something does, and all three
    // simply paginate in full and slice at the end (correct, just not faster):
    //
    //   a print stream   `finalizePages`' machine-margin strip is a MINIMUM over pages
    //                    2..n of the whole document. Fewer pages can only raise that
    //                    minimum, which would strip leading blanks off page 1 that a
    //                    full run keeps.
    //   placeable notes  the notes paginator reserves a page's bottom area from the
    //                    notes its own body references, and that reservation is decided
    //                    while walking the document, not page by page -- so a prefix is
    //                    not obviously the same prefix. Measured, not assumed, is the
    //                    only way this one gets opened up.
    //   columns          NOT excluded, but budgeted for: `applyColumns` folds n
    //                    sub-pages into one sheet, so the sub-page cap is n times the
    //                    caller's page count. `n` is the deepest `.co` the document
    //                    declares anywhere, which is an over-estimate and is meant to be.
    //
    // Plus one spare sub-page in every case, so the page the caller wants is never the
    // array's last and never meets `finalizePages`' own tail rules early.
    var rawPageCap: Int? = nil
    if let maxPages, maxPages > 0, printed, !isPrintStream, !hasPlaceableNotes(doc) {
        let widest = doc.blocks.compactMap { $0.columns }.max() ?? 1
        rawPageCap = maxPages * max(1, widest) + 1
    }
    func capped(_ pages: [Page]) -> [Page] {
        guard let maxPages, maxPages > 0, pages.count > maxPages else { return pages }
        return Array(pages.prefix(maxPages))
    }
    // Planning #250: resolved once, shared by both `printed` branches below (the
    // "zero real pages" fallback -- GALLEYS.DOT/ADVANCE.DOT) -- see
    // `parityResolvedFallbackHeadFoot`'s own doc comment.
    let fallback = parityResolvedFallbackHeadFoot(doc)
    if printed {
        if hasPlaceableNotes(doc) {
            // b24 round 19 (RULINGS-LEDGER PIX row) left this path as a documented
            // scope cut; round 22 closed it — the notes-aware paginator embeds too,
            // through the same shared substitution/sizing helpers.
            //
            // `stripBlanks: false` (layout byte parity, 2026-08-18): Python's notes
            // path returns its pages RAW — `_doc_to_pagelines` pops trailing EMPTY
            // pages but never strips a page's own leading/trailing blank lines on
            // this branch, so a notes-path page ending in an authorial blank keeps
            // it. The blank paints nothing, so PDF ink is identical either way.
            var notesPages = applyColumns(doc,
                finalizePages(layoutPrintedPages(doc, pixResults: pixResults,
                                                 pictures: pictures,
                                                 sentenceSpacing: sentenceSpacing),
                             printed: true, isPrintStream: isPrintStream,
                             stripBlanks: false,
                             fallbackHeaders: fallback.headers, fallbackFooters: fallback.footers,
                             fallbackHeadOverride: fallback.headOverride,
                             fallbackFootOverride: fallback.footOverride,
                             fallbackPoCols: fallback.poCols, fallbackPoParity: fallback.poParity))
            // planning #251(b)/(c)/(d): the same three model-build-time attach
            // passes as the plain path below -- see each function's own doc
            // comment. Both `docToPagelines` branches converge here so `emitPDF`
            // and `emitLayout` (which both call `docToPagelines` independently)
            // see identical model data regardless of which pagination path a
            // given document takes.
            let attachSize = printedSize(doc)
            substituteMergePageNumbersPrinted(doc, &notesPages)
            attachJustifyWordXPrinted(doc, &notesPages, size: attachSize)
            attachLineNumbersPrinted(doc, &notesPages, size: attachSize)
            attachGraphicCellsPrinted(doc, &notesPages, size: attachSize)
            attachHeadFootLinesPrinted(doc, &notesPages, size: attachSize, isNotesPath: true)
            return capped(notesPages)
        }
        var plainPages = applyColumns(doc,
            finalizePages(layoutPrintedPagesPlain(doc, pixResults: pixResults,
                                                  pictures: pictures,
                                                  sentenceSpacing: sentenceSpacing,
                                                  rawPageCap: rawPageCap),
                         printed: true, isPrintStream: isPrintStream,
                         fallbackHeaders: fallback.headers, fallbackFooters: fallback.footers,
                         fallbackHeadOverride: fallback.headOverride,
                         fallbackFootOverride: fallback.footOverride,
                         fallbackPoCols: fallback.poCols, fallbackPoParity: fallback.poParity))
        let attachSize = printedSize(doc)
        substituteMergePageNumbersPrinted(doc, &plainPages)
        attachJustifyWordXPrinted(doc, &plainPages, size: attachSize)
        attachLineNumbersPrinted(doc, &plainPages, size: attachSize)
        attachGraphicCellsPrinted(doc, &plainPages, size: attachSize)
        attachHeadFootLinesPrinted(doc, &plainPages, size: attachSize)
        return capped(plainPages)
    }
    // Modern PDF's own real pipeline is `modernStreams` (PDFModernLayout.swift), which
    // embeds since round 22; this legacy Modern layout is not an emitter path for it,
    // so `pixResults`/`pictures` are simply unused on this branch. Modern never calls
    // `runningOps` (`printed` guard), so a fallback header/footer here would be inert —
    // omitted rather than passed for no reason.
    return capped(finalizePages(layoutModernPages(doc), printed: false,
                                isPrintStream: isPrintStream))
}

/// `{blockIndex: pageNumber}` — the REAL paginator's own answer for which page each
/// block's FIRST printed line landed on (b24 round 18, RULINGS-LEDGER row 4). `startNo`
/// matches whatever page number actually prints in the corner (`emitPDF`'s own
/// convention). A `.tc`/`.ix` entry whose own block never reached a printed page (a stray
/// or malformed dot line, or an empty block) simply gets no entry here — `compileTOC`/
/// `compileIndex` treat a missing key as "no page number available", not a crash.
/// Re-runs the SAME `docToPagelines` pass `emitPDF`'s own printed branch uses — one extra
/// pagination pass, paid once per TOC/Index-enabled conversion, not per entry. Port of
/// `_toc_page_numbers`.
///
/// Per-page numbers come from `resolvePageNumbers`/`pnCheckpoints` (register b31-dot-
/// command-sweep) rather than a flat `startNo + pageIndex` -- a document whose `.pn`
/// re-anchors mid-document would otherwise give a TOC entry the WRONG page number past
/// that point.
public func tocPageNumbers(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off
) -> [Int: Int] {
    // b24 round 19 (RULINGS-LEDGER PIX row): threaded through so an embedded picture's
    // own vertical footprint shifts these page numbers exactly the way it shifts the
    // real render -- without this, TOC page numbers could disagree with where the real
    // PDF put things.
    let pages = docToPagelines(doc, printed: true, pixResults: pixResults, pictures: pictures)
    let pageNumbers = resolvePageNumbers(pnCheckpoints(doc), pages)
    var resolved: [Int: Int] = [:]
    for (pageIndex, page) in pages.enumerated() {
        for line in page.lines {
            if let bi = line.bi, resolved[bi] == nil {
                resolved[bi] = pageNumbers[pageIndex]
            }
        }
    }
    return resolved
}

/// Plain PageLines for the compiled TOC/Index section — TOC before Index (b24 round 18,
/// RULINGS-LEDGER row 4), each clearly headed, a TOC entry indented two columns per level
/// (`.tc`/`.tc1`-`.tc9`, WSFORMAT's own outline levels). Port of `_toc_index_pagelines`.
func tocIndexPagelines(_ doc: Document, pageNumbers: [Int: Int]?) -> [PageLine] {
    var lines: [PageLine] = []
    let toc = compileTOC(doc, pageNumbers: pageNumbers)
    if !toc.isEmpty {
        lines.append(PageLine([Span(text: "TABLE OF CONTENTS", styles: .bold)]))
        lines.append(PageLine([]))
        for entry in toc {
            lines.append(PageLine([Span(text: String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text)]))
        }
        lines.append(PageLine([]))
    }
    let idx = compileIndex(doc, pageNumbers: pageNumbers)
    if !idx.isEmpty {
        lines.append(PageLine([Span(text: "INDEX", styles: .bold)]))
        lines.append(PageLine([]))
        for text in idx {
            lines.append(PageLine([Span(text: text)]))
        }
    }
    return lines
}

/// Modern mode: otherwise unchanged from the original Python-parity port (b26 notes wave,
/// port of ctrl-kd 5da154b, touched only the trailing note-list's per-kind labels — see
/// below). Reflows every line to `maxCols` and collects footnotes/endnotes/annotations at
/// the very end under one 20-dash rule — the shape this project shipped before the
/// period-authentic Printed layout existed, and which Printed mode below no longer shares.
private func layoutModernPages(_ doc: Document) -> [Page] {
    enum LayoutItem {
        case line(PageLine)
        case pageBreak
        /// `.cp n` — resolved by the page-filling loop below, the only thing that knows
        /// how full the page is.
        case condPage(Int)
    }

    let refNotes = inlineReferenceNotes(doc)
    // planning #266: this document's own driver-keyed cp437-158 rule, resolved once. The
    // rule is on the SHARED block walk in ctrl-kd's `_doc_to_pagelines`, which serves both
    // its printed and its (legacy) Modern branch; this port splits that walk in two, so
    // both halves carry it -- see `resolvePlainBody`'s own copy.
    let euro = pesetaMeansEuro(doc)
    var items: [LayoutItem] = []
    for block in doc.blocks {
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        // Reflowed: logical lines, soft wraps joined back (`mergedLines`, ctrl-kd 2.0.0) —
        // Modern mode wraps to `maxCols` anyway, so a soft break here is redundant with the
        // wrapper's own decision, not a break the reader should see twice.
        for line in mergedLines(block) {
            // The module docstring's "headings bold" promise, unimplemented until Python
            // 1.1.5 (found by this port, job-011). Bold is added to EVERY span in a heading
            // block, not substituted: a span already italic stays italic and becomes
            // bold-italic, which is why this is a union and not an assignment. The active
            // paragraph style's own attributes merge the same way.
            let spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes) }
                .map { sp -> Span in
                    let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                    let colour = effectiveSpanColour(sp, block: block)       // register C5
                    let text = euroText(sp.text, euro)                       // planning #266
                    return styles == sp.styles && colour == sp.colour && text == sp.text ? sp
                        : Span(text: text, styles: styles, font: sp.font, colour: colour)
                }
            items.append(contentsOf: wrapLine(spans, width: PDFMetrics.maxCols)
                .map { LayoutItem.line(PageLine($0.spans, soft: line.soft)) })
        }
        if !block.lines.isEmpty {
            items.append(.line([]))                           // blank line between paragraphs
        }
    }

    // Footnotes/endnotes/annotations collect at the end under a 20-dash rule. b26 notes
    // wave (port of ctrl-kd 5da154b): this dump used to renumber every kept note through
    // ONE shared sequential index regardless of kind (`doc.footnotes` is the flattened,
    // kind-blind view the module doc above describes), so a footnote #1 and an endnote #1
    // both printed "[1]"/"[2]" -- silently disagreeing with the one label every real
    // emitter (and this same file's own Printed-mode area, `footerEntryLines`/
    // `endnoteEntryLines`) agrees on. Per-kind now, reusing those exact helpers: "1." for
    // footnotes/annotations, "(1)" for endnotes -- oracle-verified (-SCREEN.WS: "1.
    // Footnote" / "(1)  Endnote").
    let placeable = doc.notes.enumerated().filter {
        $0.element.kind == .footnote || $0.element.kind == .endnote
            || $0.element.kind == .annotation
    }
    if !placeable.isEmpty {
        items.append(.line([]))
        items.append(.line([Span(text: String(repeating: "-", count: 20))]))
        items.append(.line([]))
        for (i, note) in placeable {
            // planning #202 residuals round: this legacy dump's own real Python
            // equivalent (pdf.py:3389) pre-joins `marker + note_text` into ONE span,
            // unlike the real Printed area/endnote listing's `_note_wrap` (separate
            // spans) -- `separateSpans: false` keeps this call site matching THAT
            // pre-joined shape, byte-identical to before `separateSpans` existed.
            let entryLines = note.kind == .endnote
                ? endnoteEntryLines(note, doc: doc, index: i, width: PDFMetrics.maxCols,
                                    separateSpans: false)
                : footerEntryLines(note, doc: doc, index: i, width: PDFMetrics.maxCols,
                                   separateSpans: false)
            items.append(contentsOf: entryLines.map(LayoutItem.line))
        }
    }

    var pages: [Page] = []
    var page: Page = []
    for item in items {
        switch item {
        case .pageBreak:
            pages.append(page)
            page = []
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            if PDFMetrics.linesModern - page.count < n, !page.isEmpty {
                pages.append(page)
                page = []
            }
        case .line(let line):
            if page.count >= PDFMetrics.linesModern {
                pages.append(page)
                page = []
            }
            page.append(line)
        }
    }
    if !page.isEmpty {
        pages.append(page)
    }
    return pages
}

/// We supply the paper margins, so WordStar's own margin blanks in a print stream would
/// double up. But deliberate spacing (a chapter-drop on page 1) must survive: the MACHINE
/// margin is uniform on every page, so strip only the minimum leading-blank count seen on
/// pages 2+ — anything beyond it on any page is the author's layout. Trailing blanks are
/// always machine.
///
/// ...but ONLY for a PRINT STREAM (`isPrintStream`). This repair was written for
/// print-to-disk output, where WordStar physically emitted its top margin as blank
/// lines. A WS4/WS5+ DOCUMENT has no machine margin in it at all — `.mt` is a dot
/// command the emitter applies as paper margin — so every leading blank in one is the
/// author's. Running the stripper on a document deletes an author's chapter drop
/// outright, and on any SINGLE-page document it deletes every leading blank, because the
/// `len(pages) > 1` fallback measures the only page against itself.
///
/// Shared by both modes' page-building functions; Modern's own layout (`!printed`) always
/// strips each page's own leading blanks (it never faithfulness-matches machine margin at
/// all), matching Python's own three-way branch in `_doc_to_pagelines` exactly.
///
/// `fallbackHeaders`/`fallbackFooters` are ONLY consulted for the `pages.isEmpty` branch
/// below — the "this document produced literally zero pages" case (`layoutPrintedPagesPlain`
/// never appended a single `PageLine`, e.g. a content-free template like REF/ADVANCE.DOT).
/// Python's `pages or [[]]` there substitutes a bare LIST, which has no `.headers`
/// attribute at all, so `_running_ops`'s `getattr(pl, 'headers', None)` returns `None` and
/// falls back to `doc.headers`/`doc.footers` (the document's own final running-head
/// state) — the ONLY per-document geometry that would otherwise show up on a page with no
/// body text at all (its position is still driven by the document's own `.mt`/`.mb`/`.fm`,
/// see `runningOps`'s `footLine`). `Page.headers`/`.footers` are a concrete (non-optional)
/// `[Int: String]`, so there is no `nil` to fall back FROM at the call site — passing the
/// document's final state directly here reproduces the same end state Python reaches via
/// its attribute trick, without needing an `Optional`/sentinel of our own. A page that DID
/// go through real pagination (`closePage()`) always supplies its own concrete (possibly
/// legitimately empty, e.g. before the document's first `.h1`) headers/footers instead —
/// this parameter never overrides those, only the synthetic empty-document fallback below.
/// Planning #250: the `finalizePages` "zero pages" fallback (below) bakes `doc.headers`/
/// `doc.footers` directly into a concrete `Page.headers`/`.footers` at CALL time, unlike
/// every other page (whose header/footer text a real `closePage()` resolves against its
/// OWN parity, once pagination knows it) -- so a content-free template that ALSO uses
/// `.h1e`/`.h1o`/`.f1e`/`.f1o` (GALLEYS.DOT/ADVANCE.DOT: real corpus documents, zero
/// body blocks at all) would otherwise show the flat last-in-source-order-wins text
/// regardless of page parity. The synthetic fallback page IS the document's own first
/// (and only) page, whose number is `doc.page?.pnStart` (default 1, WordStar's own
/// `.pn` -- a document that renumbers its own start still gets the RIGHT parity here,
/// not a hardcoded "page 1 is odd" assumption). Port of ctrl-kd's own `_resolve_head_
/// foot_lines` `headers_flat`/`headersFlat` branch (pdf.py, planning #250).
private func parityResolvedFallbackHeadFoot(_ doc: Document) -> (
    headers: [Int: String], footers: [Int: String],
    headOverride: [Int: HFOverride]?, footOverride: [Int: HFOverride]?,
    poCols: Double?, poParity: Bool
) {
    let pageNo = doc.page?.pnStart ?? 1
    let isEven = pageNo % 2 == 0
    let parity: HFParity = isEven ? .even : .odd
    var headers = doc.headers
    var headOverride: [Int: HFOverride]? = nil
    if let variant = doc.headersParity[1]?[parity] {
        headers[1] = variant
        headOverride = [1: HFOverride(fontIdx: doc.headerFontsParity[1]?[parity],
                                      tab: doc.headerTabsParity[1]?[parity],
                                      align: doc.headerAlignParity[1]?[parity],
                                      styleAttrs: doc.headerStyleAttrsParity[1]?[parity] ?? [])]
    }
    var footers = doc.footers
    var footOverride: [Int: HFOverride]? = nil
    if let variant = doc.footersParity[1]?[parity] {
        footers[1] = variant
        footOverride = [1: HFOverride(fontIdx: doc.footerFontsParity[1]?[parity],
                                      tab: doc.footerTabsParity[1]?[parity],
                                      align: doc.footerAlignParity[1]?[parity],
                                      styleAttrs: doc.footerStyleAttrsParity[1]?[parity] ?? [])]
    }
    // Planning #255: a content-free template (GALLEYS.DOT/ADVANCE.DOT) never runs
    // `closePage`'s own `.poe`/`.poo` resolution either (that loop never starts --
    // there is no block to open a page at) -- this fallback page's own LEFT origin
    // needs the SAME resolution `closePage` gives every real page, or a style-sheet
    // right/center alignment (this function's own caller's caller) would measure its
    // right edge from the WRONG (flat default) left origin. Reuses the SAME
    // `poCheckpoints`/`poeOrPooCheckpoints`/`leftForParity` machinery `closePage`
    // calls, at block 0 (the only anchor a document with no blocks can have).
    let bi = 0
    let docPo = poAt(poCheckpoints(doc), bi)
    let poeCp = poeOrPooCheckpoints(doc, dotName: "POE")
    let pooCp = poeOrPooCheckpoints(doc, dotName: "POO")
    let poe: Double? = poeCp.isEmpty ? nil : poAt(poeCp, bi)
    let poo: Double? = pooCp.isEmpty ? nil : poAt(pooCp, bi)
    let parityPo = leftForParity(docPo, poe, poo, isEven: isEven)
    let poCols: Double? = parityPo != docPo ? parityPo : nil
    let poParity = poe != nil || poo != nil
    return (headers, footers, headOverride, footOverride, poCols, poParity)
}

private func finalizePages(_ rawPages: [Page], printed: Bool, isPrintStream: Bool,
                           stripBlanks: Bool = true, fallbackHeaders: [Int: String] = [:],
                           fallbackFooters: [Int: String] = [:],
                           fallbackHeadOverride: [Int: HFOverride]? = nil,
                           fallbackFootOverride: [Int: HFOverride]? = nil,
                           fallbackPoCols: Double? = nil,
                           fallbackPoParity: Bool = false) -> [Page] {
    var pages = rawPages
    if pages.isEmpty {
        // Python's `pages or [[]]`, with the running-head fallback ported alongside it —
        // see this function's own doc comment.
        var pg = Page([], headers: fallbackHeaders, footers: fallbackFooters)
        pg.isSynthesizedFallback = true
        pg.headHfOverride = fallbackHeadOverride
        pg.footHfOverride = fallbackFootOverride
        // Planning #255: this fallback page's own `.poe`/`.poo`-resolved left origin
        // -- see `parityResolvedFallbackHeadFoot`'s own doc comment.
        if let fallbackPoCols { pg.poCols = fallbackPoCols }
        pg.poParity = fallbackPoParity
        // ...and its automatic page number's own offset, which for a page with no
        // lines at all can only be that same block-0 answer -- `closePage`'s
        // page-close reading needs a last line to read. GALLEYS.DOT/ADVANCE.DOT
        // declare `.poe`/`.poo` before any block would ever open, so block 0 is not
        // an approximation here, it is the answer. A document with no parity
        // override leaves this `nil` and `autoPageNumberXPt` reads the document
        // default, exactly as before.
        if fallbackPoParity { pg.autoPagenoPo = fallbackPoCols }
        return [pg]
    }

    func leading(_ page: Page) -> Int {
        var n = 0
        while n < page.count, isBlank(page[n]) {
            n += 1
        }
        return n
    }

    if stripBlanks, printed, isPrintStream {
        // `min` runs over pages 2+, falling back to page 1's own count when there is no
        // page 2: Python's `if len(pages) > 1 else`.
        let machine = pages.dropFirst().map(leading).min() ?? leading(pages[0])
        for i in pages.indices {
            pages[i].removeFirst(min(machine, leading(pages[i])))
        }
    } else if stripBlanks, !printed {
        for i in pages.indices {
            pages[i].removeFirst(leading(pages[i]))
        }
    }
    // else (printed, a DOCUMENT not a print stream): keep every leading blank -- it is
    // authorial, not the machine's -- and fall straight through to the trailing strip.
    if stripBlanks {
        for i in pages.indices {
            while let last = pages[i].last, isBlank(last) {
                pages[i].removeLast()
            }
        }
    }

    // A trailing empty page is a blank sheet. Two things can produce one: content that
    // exactly fills a page pushes the next page's structural blank out of the loop above, and
    // a trailing `.pa .pa` appends a page with nothing in it.
    //
    // This pop must run AFTER the stripping loop, because stripping is what empties the first
    // kind: a final page holding nothing but blank lines has a positive line count until the
    // strip hollows it out, so a pop placed earlier looks at a non-empty page and skips it.
    // Python 1.1.5 popped before stripping and the blank sheet survived — found by this port
    // in job-012 and fixed in 1.1.6 (pdf.py:115-120), which is the position reproduced here.
    //
    // Explicit interior blanks from `.pa .pa` between content are preserved: only the LAST
    // page is popped, and only while there is more than one.
    //
    // #228 (research/2026-09-08_trailing-pa-rule.md, planning #228): an empty page
    // reached via the confirmed trailing-`.pa`-plus-saved-blank-paragraph shape
    // (`explicitBreak`, set only where a trailing `.pa` opens one — see
    // `layoutPrintedPagesPlain`/`endnotePages`) is real WS7 output -- its footer/page
    // number prints even with no body -- and is exempt from this pop.
    while pages.count > 1, pages[pages.count - 1].isEmpty, !pages[pages.count - 1].explicitBreak {
        pages.removeLast()
    }
    return pages
}

// MARK: - Printed mode: the period-authentic footnote/endnote/annotation layout
//
// The WordStar 5 manual, verbatim: "Footnotes are separated from the text by a line of 20
// dashes. If a footnote doesn't fit at the bottom of the page, the continued text is
// printed in the footnote area at the bottom of the next page (except after the last page
// of regular text, where footnotes are printed at the top of the page). A minimum of three
// lines of regular text are printed on a page regardless of the size of the footnote area
// except on the last page of the document."
//
// Rules this implements, in the same numbering the job brief used:
// 1. The reference never moves — a `Note` is never reserved-and-pushed; it renders exactly
//    where `resolvePrintedBody` finds its `fnref` span, and the footer for it appears
//    whenever the PAGE holding that reference closes.
// 2. The footer area grows to hold what's due, eating into the page's body allotment.
// 3. Floor: the first three lines of body on a page are placed unconditionally, before the
//    footer's size is ever allowed to compete for room.
// 4. Overflow splits across pages; a continuation chunk is preceded by one literal
//    `...Continued...` line.
// 5. On the true last page of body text, the floor no longer matters (there is no next body
//    page to defer to) and any footer overflow prints at the TOP of a fresh page instead of
//    the bottom of one.
//
// Annotations share the footnote area (their `tag` is the marker); endnotes never appear
// there at all — they collect at the true end of the document with no heading, per the
// spec. Comments never print. Footnote/endnote numbering is independent, driven by
// `doc.footnoteNumberStart`/`endnoteNumberStart` (default 1) plus each `Note.number`
// (0-based).

/// One body item, printed-mode's own shape: an explicit break, or a verbatim line plus the
/// footnote/annotation notes whose `fnref` reference falls on it (endnotes are collected
/// separately below — they never compete for page-bottom room).
private enum PrintedBodyItem {
    case pageBreak
    /// `due` pairs each note with its index in `doc.notes` — the identity `noteLabel`
    /// needs (Python threads the precomputed label itself through its stream refs).
    case line(PageLine, due: [(note: Note, index: Int)])
    /// `.cp n` — resolved in `layoutPrintedPages`, the only place that knows how full the
    /// page is.
    case condPage(Int)
}

/// A footnote/annotation waiting in the page-bottom queue. `remaining` shrinks as pages
/// consume it; `needsContinuedMarker` is set the moment a page takes only part of it, so the
/// NEXT page that resumes it prepends the literal continuation line first.
internal struct QueuedNote {   // internal: the progress invariant is unit-tested
    var remaining: [PageLine]
    var needsContinuedMarker: Bool
}

private let footerContinuedLine = "...Continued..."

/// Reserved marker-field width, in character columns, for this document's
/// footnote/endnote/annotation area — Finding 4 (b26 visual pass, a real WS7 capture
/// pairing a "1." footnote with a "(1)" endnote on the same page). WS7's own capture
/// hangs a note's text to a COMMON column when the document's own markers are not all
/// the same width: both entries' TEXT starts at the identical x — measured 864
/// decipoints, column 5 from the note area's own left margin (504 decipoints): the
/// widest marker's own natural width ("(1)", 3 columns) plus 2 columns of padding.
/// Every other note-bearing document measured so far uses markers of ONE width
/// throughout (a single-footnote document: "1.Did", ONE space, no hang), so this
/// returns `nil` there — meaning "leave `footerEntryLines`/`endnoteEntryLines`'s plain
/// single-space join alone", exactly the previous behaviour, byte-identical.
///
/// Computed DOCUMENT-WIDE, not per page or per note-kind: a short document's footnotes
/// and endnotes can land on the very SAME rendered page (`layoutPrintedPages`
/// continuing the footnote/annotation area's last page into the endnote section when
/// there's room), so one document-global number is what lets both agree without new
/// cross-call plumbing — this port already folds both sections into ONE function, so a
/// single local computation covers both call sites. A comment's reference has no
/// note-area entry of its own (`keepSpanOnPageline`) and never reaches here. Port of
/// Python's `_notes_marker_pad_cols`.
///
/// 2026-09-12 (`sawyer/REF/NOTES.TST`): a note that carries its OWN tab
/// (`Note.textIndents`, a nested type-9 block in the note's own text stream) states
/// where its text goes and is left out of this vote entirely — WS7 obeys the document,
/// not a hang column derived from the other notes. The two documents this finding was
/// measured on turn out to tab BOTH their notes to column 5, exactly the number this
/// function returned for them, so they render identically either way; NOTES.TST tabs
/// its footnotes to 3 and its endnotes to 5, and only its (untabbed) annotations still
/// ask this question — of one marker width, so the answer is `nil` and their own
/// single-space join stands, which is what WS7 prints.
private func notesMarkerPadCols(_ doc: Document) -> Int? {
    var widths = Set<Int>()
    for (i, note) in doc.notes.enumerated() {
        if note.textIndents.contains(where: { $0 != 0 }) { continue }
        switch note.kind {
        case .footnote: widths.insert("\(noteLabel(note, doc: doc, index: i))." .width)
        case .endnote: widths.insert("(\(noteLabel(note, doc: doc, index: i)))".width)
        case .annotation: widths.insert(noteLabel(note, doc: doc, index: i).width)
        case .comment: continue
        }
    }
    if widths.count <= 1 { return nil }
    return (widths.max() ?? 0) + 2
}

/// `base` left-justified to `padCols` columns when given (matching Python's
/// `str.ljust` — a `base` already at or past that width is returned unchanged, never
/// truncated), or `base` plus a single trailing space when `padCols` is `nil` — the
/// pre-Finding-4 behaviour every single-marker-width document still gets. Port of the
/// shared tail of Python's `_note_marker`/`_endnote_marker`.
private func padMarker(_ base: String, padCols: Int?) -> String {
    guard let padCols else { return base + " " }
    let n = base.width
    guard n < padCols else { return base }
    return base + String(repeating: " ", count: padCols - n)
}

/// The marker text a `fnref` span (or a footer/endnote entry) displays for one note.
///
/// Delegates to `noteLabel` and must keep doing so. This used to reimplement the same
/// rule and drifted from it: where `noteLabel` falls back to the note's position when
/// `Note.number` is nil (a real outcome — the tag word's high bit means the file never
/// resolved a number), this used `?? 0`, so EVERY unnumbered note of a kind rendered with
/// the SAME marker. Two different footnotes both showed "1", inline and in the footer.
/// The flat emitters were correct; only this lane was wrong, and no vector caught it
/// because none exercises a nil number in printed mode.
private func noteMarker(_ note: Note, doc: Document, index: Int) -> String {
    noteLabel(note, doc: doc, index: index)
}

/// The footer entry for one footnote/annotation, wrapped to `width` — factory-default
/// marks: `1.` (trailing period) for a footnote, the bare tag for an annotation.
///
/// `padCols` (Finding 4, b26 visual pass): see `notesMarkerPadCols`. `nil` for a
/// FOOTNOTE (the overwhelming common case -- any document whose notes all share one
/// marker width) means WS7's own capture carries NO padding and NO separating space at
/// all between the marker and the note text -- measured directly (planning #202
/// residuals round, ctrl-kd 1017391, LYING.pcl's own single footnote: `"1.Did"`, ONE
/// literal chunk, zero characters between the period and the capital D). A prior round's
/// own comment here read that exact same measurement as "ONE space" and left the join
/// unchanged rather than acting on it; it was misread -- the PCL evidence has never had
/// a space in it. Every OTHER footnote-bearing document measured so far also uses
/// markers of ONE width throughout, so this is the path they all take too; none of them
/// has its own WS7 capture to confirm or contradict the join, so the single confirmed
/// reading (no separator) is what now governs all of them, not a guess independent of
/// it. ANNOTATIONS keep the original space: their marker is a free-text tag with no
/// trailing punctuation of its own (unlike a footnote's period), and no corpus capture
/// has ever measured one -- widening the fix to a kind with no evidence either way is
/// exactly the guess this fix itself replaces.
///
/// `separateSpans` (planning #202 residuals round, ctrl-kd 1017391): the REAL Printed
/// footer/endnote area wraps the marker and the note's own text as TWO SEPARATE spans
/// (Python's `_note_wrap(marker, text, width)`, called `_wrap_line([(marker, ...),
/// (text, ...)], width)` -- each span is word-tokenized on its OWN, before the two
/// token streams are concatenated, so the marker's own last token and the note text's
/// own first word stay separate SEGMENTS even with zero characters between them, same
/// as before this fix's marker join lost its trailing space). This call site's own
/// legacy Modern notes-dump caller (`docToPagelines(doc, printed: false)`, ctrl-kd
/// pdf.py:3389) pre-joins `marker + note_text` into ONE span instead -- unaffected by
/// this fix, and the only caller that still wants `false` here: at THAT joint, `false`
/// keeps this call byte-identical to before this parameter existed. Invisible to a
/// flattened text/PDF comparison either way (a PDF Tj string carries no segment
/// boundaries), so this only matters where the segment STRUCTURE is itself observed --
/// `layout.json`'s `printed.pages[].lines[].segments` (planning #202 residuals round,
/// AnswerKeyParityTests' `LYING.WS.layout.*` divergence, LYING's own "1.Did" case).
/// One note's own PHYSICAL text lines (`Note.textLines`), with the sentence-spacing and
/// euro-table passes already applied -- what the page-bottom and endnote areas actually
/// print.
///
/// WordStar stores a note as the author typed it and prints it the same way: a hard
/// return inside the note text is a hard return on paper. MEASURED (ws7-prints/v4,
/// PRISTINE.EXE): each of the 19 TAGS/ annotations in the Sawyer archive stores a
/// LEADING EMPTY line, and real WS7 prints the tag alone on the note area's first line
/// with the text on the next -- `sawyer/TAGS/WHY` puts "[Why?]" at 672.0pt and "Why?"
/// at 684.0pt. Flowing the note's lines into one string put both on a single line and
/// lifted the whole (bottom-anchored) area a line.
///
/// A note with no `textLines` at all -- a dot-line comment, a synthetic fixture built by
/// hand -- falls back to its flowed `text` as one line, byte-identical to this
/// function's predecessor. Port of Python's `pdf._note_texts`.
private func noteTexts(_ note: Note, doc: Document, sentenceSpacing: Bool) -> [String] {
    let raw = note.textLines.isEmpty ? [note.text] : note.textLines
    let spaced = sentenceSpacing ? sentenceSpacingTexts(raw) : raw
    let euro = pesetaMeansEuro(doc)
    return spaced.map { euroText($0, euro) }
}

/// One note's rendered lines, the marker joining the line it is STORED on. Port of
/// Python's `pdf._note_wrap(marker, texts, width, tag_line)`.
///
/// `indents` (`Note.textIndents`, 2026-09-12) is the note's own TAB per physical line —
/// an ABSOLUTE column from the note area's left margin, 0 for a line that tabs nothing.
/// A tab MOVES RIGHT only: WordStar cannot pull text back over a marker already
/// printed, so a column at or left of where the line already stands is spent and leaves
/// no gap (the same reading a body tab gets). MEASURED against real WS7 (ws7-prints/v4,
/// PRISTINE.EXE) on `sawyer/REF/NOTES.TST`: footnote marker "1." at 57.6pt with its
/// text tabbed to HMI 540 prints "Footnote One." at 79.2pt (column 3); endnote "(1)"
/// with HMI 900 prints "Endnote one." at 93.6pt (column 5).
func noteWrapLines(marker: String, texts: [String], width: Int,
                           tagLine: Int, separateSpans: Bool,
                           indents: [Int] = []) -> [PageLine] {
    let texts = texts.isEmpty ? [""] : texts
    let tagLine = Swift.min(Swift.max(0, tagLine), texts.count - 1)
    var out: [PageLine] = []
    for (n, line) in texts.enumerated() {
        let col = n < indents.count ? indents[n] : 0
        if n == tagLine {
            let head = col > marker.width
                ? marker + String(repeating: " ", count: col - marker.width)
                : marker
            out.append(contentsOf: separateSpans
                ? wrapLine([Span(text: head), Span(text: line)], width: width)
                : wrapLine([Span(text: "\(head)\(line)")], width: width))
        } else if col > 0 {
            let pad = String(repeating: " ", count: col)
            out.append(contentsOf: separateSpans
                ? wrapLine([Span(text: pad), Span(text: line)], width: width)
                : wrapLine([Span(text: "\(pad)\(line)")], width: width))
        } else {
            out.append(contentsOf: wrapLine([Span(text: line)], width: width))
        }
    }
    return out
}

private func footerEntryLines(_ note: Note, doc: Document, index: Int,
                              width: Int, padCols: Int? = nil,
                              sentenceSpacing: Bool = false,
                              separateSpans: Bool = true) -> [PageLine] {
    // N9 (b33 field notes): applied to the note's own text before the marker is
    // prepended -- the marker itself (a bare number/tag) carries no sentence-ending
    // punctuation of its own to interact with.
    // planning #266: the driver-keyed cp437-158 rule (`pesetaMeansEuro`) -- a note is part
    // of the document, and this path reads `note.text` straight off it.
    let noteTextLines = noteTexts(note, doc: doc, sentenceSpacing: sentenceSpacing)
    let marker: String
    switch note.kind {
    case .footnote:
        let base = "\(noteMarker(note, doc: doc, index: index))."
        marker = padCols != nil ? padMarker(base, padCols: padCols) : base
    case .annotation:
        marker = padMarker(noteMarker(note, doc: doc, index: index), padCols: padCols)
    default:
        // unreached: endnotes/comments never queue here
        return wrapLine([Span(text: noteTextLines.joined(separator: " "))], width: width)
    }
    return noteWrapLines(marker: marker, texts: noteTextLines, width: width,
                         tagLine: note.tagLine, separateSpans: separateSpans,
                         indents: note.textIndents)
}

/// The true-end-of-document entry for one endnote — factory-default mark `(1)`.
/// `padCols`/`separateSpans`: see `footerEntryLines` (Python's own true-end-of-document
/// listing, pdf.py:2765, is the SAME `_note_wrap(marker, text, width)` shape).
private func endnoteEntryLines(_ note: Note, doc: Document, index: Int,
                               width: Int, padCols: Int? = nil,
                               sentenceSpacing: Bool = false,
                               separateSpans: Bool = true) -> [PageLine] {
    let marker = padMarker("(\(noteMarker(note, doc: doc, index: index)))", padCols: padCols)
    // planning #266: see `footerEntryLines`.
    return noteWrapLines(marker: marker,
                         texts: noteTexts(note, doc: doc, sentenceSpacing: sentenceSpacing),
                         width: width, tagLine: note.tagLine, separateSpans: separateSpans,
                         indents: note.textIndents)
}

/// Blocks -> printed body items, fixing up every `fnref` span's displayed text along the
/// way. The parser numbers EVERY `fnref` sentinel (footnote, endnote, and annotation alike,
/// in document order — comments never get one) with one shared counter, so a span's raw
/// text is only a position, not a display value: the n-th `fnref` span corresponds to the
/// n-th non-comment `Note`, and that correspondence — not the span's own text — is what
/// decides what actually prints. A `fnref` with no corresponding note (more sentinels than
/// notes — malformed input, or a stray control byte the parser mistook for one) is left as
/// found rather than crashing or dropping it; `stray_sentinel` is exactly this case.
///
/// `pixResults`/`pictures` (b24 round 22, closing round 19's documented scope cut): the
/// same single-pix-placeholder substitution `resolvePlainBody` performs on the plain
/// path — a physical line whose only real content is one resolved, decoded pix tag
/// becomes an image PageLine (empty segments, `.image` set, `.lead` = the RESERVED
/// PLACEHOLDER block's height — round 26 wave 3, `pixReservedAdvance` — not the raster's
/// own continuous pixel height). Port of the round-22 half of Python's `_body_stream_printed`,
/// updated for round 26 wave 3 (`fidelity_gate.py` Findings A/B).
private func resolvePrintedBody(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [PrintedBodyItem] {
    // ALL kinds are numbered by the parser's shared counter since M9 (comments
    // included), so a mark's own number indexes all of `doc.notes`; a comment
    // holds its position and renders NOTHING — never printed: no ink, no ref.
    let referenced = inlineReferenceNotes(doc)
    // planning #266: this document's own driver-keyed cp437-158 rule, resolved once.
    let euro = pesetaMeansEuro(doc)
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    let textWidthPt = embedImages ? printedTextWidthPt(doc) : 0.0
    let defaultLeadPt = printedLead(doc)
    // Register b31: this line's own `.po` override needs the printed type size for the
    // same edge-of-page clamp `printedLeft` already applies (`resolveLeftPt`).
    let sizeForLeft = printedSize(doc)
    // round 26 wave 3 (fidelity_gate.py Finding B): same carried-governing-size mechanism
    // as `resolvePlainBody` — see `fontLeadPt`.
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.blocks.contains { $0.lhAuto } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    var items: [PrintedBodyItem] = []
    // Planning #245 (closing the scope gap this comment used to document at planning
    // #227): `.cb`/`.cc` now get the SAME sentinel treatment `resolvePlainBody` already
    // gives them -- ctrl-kd's own `_body_stream_printed`/`_paginate_printed_notes` picked
    // up the identical fix first (planning #245), verified there to be a content-safe
    // no-op for sawyer/DEFAULT/PRINT.TST (the only corpus document this path and `.co`
    // both apply to): the natural height-driven column breaks this paginator already
    // computes land at the SAME points `.cb`/`.cc` would force, so making them live
    // moves nothing for this specific document -- it closes the architectural gap
    // (matching `resolvePlainBody`'s own behaviour, and `.cp`'s own pre-existing
    // handling one paragraph below) without the cross-engine divergence the previous
    // note here was written to avoid. `.colbreak` reuses `.pageBreak`'s own sentinel
    // exactly the way `.pagebreak` does (both engines' ordinary paths already do this);
    // `.condcolumn` reuses `.condPage`'s, exactly the way `.cp`'s pre-existing handling
    // already does -- "room remaining in the current column" and "room remaining in the
    // current page" are the same question whenever a column's own height equals a
    // page's (research §4: always, in this engine).
    var prevCols = 1
    for (bi, block) in doc.blocks.enumerated() {
        // An explicit `.pa` is honored verbatim in a facsimile. WordStar's own 0x0B
        // end-of-page marks are NOT breaks -- see `Line.softpage`.
        if block.kind == .pagebreak, prevCols > 1 {
            // Planning #227 (corrected, see `resolvePlainBody`'s identical gate): a
            // bare `.pa` inside an active `.co n>1` region is absorbed. `.cb` never
            // gets this absorption (handled unconditionally just below).
            continue
        }
        if block.kind == .pagebreak || block.kind == .colbreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage || block.kind == .condcolumn {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        if block.kind == .para {
            let curCols = block.columns ?? 1
            var lastIsBreak = false
            if case .pageBreak? = items.last { lastIsBreak = true }
            if prevCols > 1, curCols != prevCols, !items.isEmpty, !lastIsBreak {
                items.append(.pageBreak)
            }
            prevCols = curCols
        }
        if block.origin == .fi {
            // #241: `.fi` (file insert) on a target this engine cannot resolve
            // fabricates a visible `[insert: NAME]` placeholder paragraph
            // (ParseWS.swift's `parseCollectDot`, origin `.fi`) -- useful in
            // Modern (an editorial note about what the source asked for), but
            // WS7's real behaviour on an unresolvable `.fi` target is to print
            // NOTHING: measured directly (sawyer/RTF-RJS's own `.fi C:\WS\
            // RTF-RJS\LINKS.MRG` probes, a target that exists nowhere in the
            // corpus) -- WS7's capture goes straight from the line before
            // `.fi` to the document's own next real text, no gap, no
            // placeholder line at all. This function (Printed's own
            // WS7-emulation surface) skips the block entirely -- zero lines,
            // zero page-advance -- matching WS7; Modern is untouched (still
            // shows the placeholder, per Jon's ruling: "report what Modern
            // does and leave it"). Port of Python's `pdf.py` `.fi` skip.
            continue
        }
        // Fix C (b26-print-fidelity-2): same per-block lookup as `resolvePlainBody` —
        // see its own comment and `enteringLeadPt`.
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        var firstLineOfBlock = true
        // Indexed (not a plain `for`) so an embedded pix substitution below can look
        // ahead and CONSUME the blank placeholder lines WordStar reserved for it — see
        // `pixReservedAdvance`.
        // planning #270 item 37: the same `.pf on` print-time re-wrap
        // `resolvePlainBody` applies -- this function is its sibling for a document
        // with placeable notes, and the two must not disagree about what the physical
        // lines of a realigning paragraph are.
        let blkLines = pfRewrappedLines(doc, block)
        var li = 0
        while li < blkLines.count {
            // planning #238 scope gap: same pre-increment index `resolvePlainBody`
            // uses to spot a block's own last line.
            let lineIdx = li
            let line = blkLines[li]
            li += 1
            let baseSpans = line.spans.map { sp -> Span in
                let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                // `pix` rides along even when the styles changed (round 22 — the
                // substitution below needs it); Python's tag-based styles carry it
                // implicitly. `pcl` likewise (register C2): a HEADING block is exactly
                // where `effectiveSpanStyles` DOES change the styles (headingBold), and
                // LJ6DTP puts the page-border print control on a heading line on four of
                // its eight pages -- dropping the field there stopped the border drawing
                // on precisely those pages. Other structural fields keep this path's
                // existing shape.
                let colour = effectiveSpanColour(sp, block: block)       // register C5
                return styles == sp.styles && colour == sp.colour ? sp
                    : Span(text: sp.text, styles: styles, font: sp.font, colour: colour,
                           pix: sp.pix, pcl: sp.pcl, tabHMI: sp.tabHMI,
                           tabLeader: sp.tabLeader)
            }

            var outSpans: [Span] = []
            var due: [(note: Note, index: Int)] = []
            for span in baseSpans {
                // a ^ONI index ENTRY is the index file's text, not the page's — see
                // `keepSpanOnPageline`, which applies the same rule on the plain
                // (note-free) printed path
                if span.indexEntry { continue }
                // The mark's OWN text is the reference — `symmetricBlocks` numbers every
                // note kind through one counter in document order, and that number is
                // what the span carries. This used to walk `referenced` with a running
                // cursor instead, one step per `fnref` span seen, which agrees with the
                // text only while EVERY mark reaches this loop: `pfRewrappedLines` now
                // takes a comment's mark off the line before anything printed sees it
                // (`dropCommentMarks`), and a cursor then resolved every later mark to
                // the wrong note. ctrl-kd's `_body_stream_printed` has always read the
                // text (`k = int(s.text)`); this is that, ported.
                guard span.styles.contains(.fnref), let k = Int(span.text),
                      k >= 1, k <= referenced.count else {
                    // planning #266: the driver-keyed cp437-158 rule (`pesetaMeansEuro`).
                    // This path reads the document's own spans directly and never passes
                    // through `modernSemanticFlow`, so it applies the rule itself.
                    var converted = span
                    converted.text = euroText(span.text, euro)
                    outSpans.append(converted)
                    continue
                }
                let noteIndex = k - 1
                let note = referenced[noteIndex]
                if note.kind == .comment {
                    continue                     // never printed: no ink, no ref (M9)
                }
                outSpans.append(Span(text: noteMarker(note, doc: doc, index: noteIndex),
                                     styles: span.styles, font: span.font))
                if note.kind == .footnote || note.kind == .annotation {
                    due.append((note: note, index: noteIndex))
                }
            }
            // Same style-over-default precedence as the plain path (`resolvePlainBody`) —
            // see `styleLeadPt`. Computed BEFORE the pix check (round 26, Finding A) since
            // the image's own reserved-placeholder advance now needs it too.
            var ownLead = leadPt(line.lead48)
            // Register b31: this line's own `.po` override, same "absolute here, `nil`
            // means agrees with the document default" contract `line.lead48` above
            // already has (`ParseWS.swift`'s back-dating pass).
            let ownLeft = line.poCols.map { resolveLeftPt($0, size: sizeForLeft) }
            // Planning #231 (.poe/.poo even/odd page offset): see
            // `resolvePlainBody`'s own identical comment -- duplicated here for the
            // same reason every other quantity in this sibling function is (different
            // local names for the same thing). See `PageLine.parityLeft`'s own doc
            // comment for why this candidate, unlike `resolvePlainBody`'s, is never
            // actually resolved on this (notes-aware) path.
            var ownParityLeft: ParityLeft?
            if line.poeCols != nil || line.pooCols != nil {
                let fallbackPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                ownParityLeft = ParityLeft(
                    even: line.poeCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt,
                    odd: line.pooCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt)
            }
            // Fix C (b26-print-fidelity-2): same blank/entering-line split as
            // `resolvePlainBody` — see its own comment, `styleLeadPt`'s `raw` parameter,
            // and `enteringLeadPt`.
            let isBlank = !outSpans.contains { $0.text.contains { !$0.isWhitespace } }
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            if !isBlank {
                firstLineOfBlock = false
            }
            // planning #256: a block's own paragraph-style leading, when it
            // has one, governs OUTRIGHT -- no longer gated on whether this
            // line's own carried `.lh` happens to be unset/default (see
            // `styleLeadPt`'s own doc comment for the -HOW-TO.RJS evidence: a
            // stale, document-wide `.lh` must never outrank the style its own
            // block actually carries).
            if let styleLead {
                ownLead = styleLead
            }
            // round 26 wave 3 (fidelity_gate.py Finding B): a WS5+ FONT-BLOCK document
            // with no style governing this line (ownLead still nil) gets its lead from
            // the font block actually in force. See `fontLeadPt`.
            if ownLead == nil, fontLeadOk, block.lhAuto {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            // Round 22: exactly one resolved pix tag, no other real text on this
            // physical line -> an image PageLine (same substitution, sizing and
            // never-drop-text rule as `resolvePlainBody`). `due` still travels: a
            // comment reference sharing the line contributes no text and queues
            // nothing, so nothing is lost; a footnote/annotation reference leaves its
            // marker text behind, which blocks the substitution — anchors are never
            // silently dropped. `.lead` is the RESERVED PLACEHOLDER block's height
            // (round 26, Finding A/C — `pixReservedAdvance`), not the raster's own
            // continuous pixel height.
            if embedImages,
               let sub = spansPixSubstitution(outSpans.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                let (reserved, nBlank) = pixReservedAdvance(
                    blkLines, startIdx: li, ownLeadPt: ownLead ?? defaultLeadPt)
                li += nBlank
                items.append(.line(PageLine([], soft: line.soft, lead: reserved,
                                            overprint: line.overprint, bi: bi,
                                            image: .init(pixIndex: sub.pixIndex,
                                                         widthPt: sub.wPt, heightPt: sub.hPt),
                                            left: ownLeft, poCols: line.poCols),
                                   due: due))
                continue
            }
            // N9 (b33 field notes): applied to the FINAL body spans -- markers and
            // prose alike, since they render adjacently on the same physical line --
            // AFTER the pix-substitution check above, which needs the raw, untouched
            // text to match its structural placeholder.
            if sentenceSpacing { outSpans = sentenceSpacingSpans(outSpans) }
            // Planning #251 (2026-09-09): model-build-time bare-tab expansion, same
            // point ctrl-kd's own `_body_stream_printed` sibling applies it (right
            // before this function's own PageLine construction) — see
            // `expandBareTabsForPrintedLayout`'s own doc comment (`EmitterRules.swift`).
            outSpans = expandBareTabsForPrintedLayout(outSpans)
            // A PageLine, not a bare list of spans, so the line's own `.lh` survives the
            // footnote paginator too — body lines keep their lead whether or not the
            // document has notes.
            //
            // Planning #238 scope gap (ctrl-kd `_body_stream_printed`, same commit):
            // this function is `resolvePlainBody`'s own sibling for a document with
            // placeable footnotes/endnotes (`layoutPrintedPages`/`hasPlaceableNotes`
            // routes here instead of `resolvePlainBody` whenever any real note
            // exists), but it never set `justifyRightX` -- a `.oj on` paragraph in a
            // document that ALSO carries a real footnote anywhere lost justification
            // on every line, not just a line bearing the reference itself. Same rule,
            // same measured exception (a block's own last physical line stays
            // ragged) -- see `resolvePlainBody`'s own comment for the captures this
            // was measured against; duplicated rather than shared since the two
            // functions' loops read from different local names for otherwise-
            // identical quantities.
            // A `.oc on` line's own centring tab is the EDITOR's arithmetic; the
            // printer re-centres on the ink alone (see recentredCentreTabSpans).
            outSpans = recentredCentreTabSpans(outSpans, block: block, doc: doc)
            var justifyRightX: Double? = nil
            // planning #270 item 37: under `.pf on` the PARAGRAPH is the unit, and
            // WordStar never justifies a paragraph's LAST line -- which is exactly
            // what `line.soft` says after the re-wrap. Without `.pf` the block remains
            // the unit, unchanged.
            let lastInUnit = block.printReformat == "on"
                ? !line.soft : lineIdx >= blkLines.count - 1
            if block.align == .justify, !lastInUnit {
                let poOriginPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                let rmCols = block.rightMargin ?? 65.0
                justifyRightX = poOriginPt + rmCols * pdfPtPerCol
            }
            items.append(.line(PageLine(outSpans, soft: line.soft, lead: ownLead,
                                        overprint: line.overprint, bi: bi,
                                        kerning: line.kerning, left: ownLeft,
                                        justifyRightX: justifyRightX,
                                        parityLeft: ownParityLeft,
                                        poCols: line.poCols), due: due))
        }
    }
    return items
}

/// WordStar's minimum-body-line guarantee (pdf.py's `FOOTNOTE_FLOOR`): "a minimum of three
/// lines of regular text are printed on a page regardless of the size of the footnote
/// area." Used here only for the same floor Python applies to the page height and capacity
/// themselves, before any footnote ever enters the picture — see `_resolved_page_height`/
/// `_printed_cap` (pdf.py:37-60). The unrelated literal `3` a little further down (the
/// "first three lines of body are unconditional" rule in `layoutPrintedPages`) is the same
/// WordStar constant but is left as-is here to keep this fix's diff to the actual bug.
///
/// `internal` since M18 (2026-09-15): `modernSheetH` applies the same floor to Modern's
/// own sheet, for the same reason, and must read the same constant rather than a second
/// copy of it.
let footnoteFloor = 3

/// Port of Python's `round()` (round-half-to-even / banker's rounding), which differs from
/// Swift's `FloatingPoint.rounded()` default (round-half-away-from-zero) — and `.rounded()`
/// itself needs libm symbols this Foundation-free Linux build can't link. `x` is always
/// non-negative here (a resolved page height in points), so `Int(x)` (truncation, which
/// equals floor for non-negatives) plus plain comparison reproduces `round()` exactly,
/// including its `.5` tie case, with no floating-point library call at all. Same technique
/// as `SymmetricBlocks.swift`'s `roundHalfToEven`, which works in pure integer arithmetic;
/// this one takes a `Double` because a page height in inches isn't always a whole number of
/// `.pl` lines (custom/converted geometry), unlike that function's HMI fields.
///
/// Not `private`: `PDFWriter.swift`'s `pageStream` needs the same banker's-rounding (ctrl-kd
/// 2.0.0's `supSize = round(size * 2 / 3)`, mirroring Python's `round()` exactly).
public func roundHalfToEven(_ x: Double) -> Int {
    let whole = Int(x)
    let fraction = x - Double(whole)
    if fraction < 0.5 { return whole }
    if fraction > 0.5 { return whole + 1 }
    return whole % 2 == 0 ? whole : whole + 1
}

/// A copy of `page` with `heightIn`/`pwIn` SWAPPED — `.pr or=l` (b24 round 17,
/// RULINGS-LEDGER row 2, register C18, Paged-surface doctrine point 2: "honor .pr or=l
/// landscape in all paged surfaces"). Port of Python's `_landscape_page`. Swapping at this
/// single source lets every existing `heightIn`/`pwIn` consumer (pagination capacity, top
/// margin, the MediaBox itself, RTF's `\paperh`/`\paperw`) cascade correctly with no
/// per-site change — a landscape page is genuinely SHORTER top-to-bottom (fewer text
/// lines fit) as well as wider, exactly what real landscape printing does. `.mt`/`.mb`/
/// `.po`-derived margins are left untouched — still top/bottom/left relative to the text,
/// same as WordStar's own driver-level rotation never re-interpreted them either.
///
/// planning #256 (sawyer/REF/-HOW-TO.RJS + the HP-ENV.LST/HP-ENVMM.LST mailing-label
/// pair): a plain swap of `page.heightIn`/`pwIn` (`resolvePageSize`'s PORTRAIT-convention
/// resolution, which Modern's own page box ALSO reads directly and unswapped — "the page
/// is the document's declared size", ruled 2026-08-06) only works when the document's
/// `.pl` already snapped to a NAMED portrait height. A `.pl` that instead matches a named
/// size's WIDTH column (every real landscape template measured: `.pl 8.5(i|")`/`8.33"`,
/// none a portrait height) resolves to a bare, un-landscape-aware SQUARE Custom fallback
/// there, and swapping two equal numbers changes nothing. Recomputes the pair fresh,
/// orientation-aware, from `page.plLines` alone — never from the cached, Modern-shared
/// portrait pair — so this correction stays scoped to Printed's own PDF/RTF geometry and
/// never touches `doc.page` (and therefore Modern's own page box) at all.
func landscapePage(_ page: PageGeometry) -> PageGeometry {
    let (heightIn, _, pwIn) = resolvePageSize(page.plLines, orientation: "landscape")
    var eff = page
    eff.heightIn = pwIn
    eff.pwIn = heightIn
    return eff
}

/// `[(blockIndex, lineIndex, orientation), ...]` in ascending order -- the `.pr or=`
/// orientation IN FORCE from that position onward. Port of Python's `_or_checkpoints`
/// (M31). Same `dotPositions` anchor and the same "block 0 is WordStar's own hardcoded
/// default" contract as `plCheckpoints`, but with the LINE index kept, which
/// `.pl`/`.po`/`.mt` discard.
///
/// WHAT WAS WRONG. `.pr or=` was captured once, at parse time, into
/// `doc.formatting.orientation` -- whatever value the file happened to set LAST. That is
/// the same defect class `poCols`/`lead48` are already excluded from the document-level
/// formatting record for; it simply never reached `.pr`. A file that asks for landscape on
/// one page and portrait on the rest printed every page portrait, and the landscape page's
/// content ran off the right edge of a sheet too narrow to hold it -- silently, because a
/// viewer clips at the MediaBox without complaining.
///
/// THE TIMING RULE IS MEASURED, not assumed (real WS7 under DOSBox-X, LASERJET driver ->
/// PCL5, 2026-09-17):
///
///   * A `.pr or=` at the TOP of a page -- immediately after `.pa`, before any of that
///     page's text -- applies to THAT page. WS7 wrote `ESC&l1O` immediately after the form
///     feed that ended page 1 and before page 2's text, then `ESC&l0O` immediately after
///     page 2's form feed.
///   * A `.pr or=` in the MIDDLE of a page does NOT touch that page; it takes effect at the
///     NEXT one. With `.pr or=l` typed between page 1's second and third lines, all three
///     of page 1's lines printed under the portrait escape at its top, and the landscape
///     escape appeared one byte AFTER page 1's form feed. WS7 never emits an orientation
///     escape mid-page at all -- it queues the change to the next page boundary.
///
/// WHY THE LINE INDEX IS KEPT, when every sibling here throws it away: a `.pr` typed
/// between two lines of a paragraph sits in the SAME block the page opened at, so a
/// block-only comparison reads it a page early and gives page 1 the sheet real WS7 gave
/// page 2. The paginator already keeps the number that settles it (`readTally[bi]`, how
/// many lines of that block earlier pages consumed, still the pre-line value where the
/// geometry recompute runs). `.pl`/`.po`/`.mt` keep their block granularity: their own
/// oracles were measured against it, and none of them reaches the MediaBox.
func orCheckpoints(_ doc: Document) -> [(blockIndex: Int, lineIndex: Int,
                                         orientation: Orientation)] {
    var checkpoints: [(blockIndex: Int, lineIndex: Int, orientation: Orientation)] =
        [(0, 0, .portrait)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PR" else { continue }
        // The SAME acceptance the parser itself applies (`applyFormatDot`'s `"PR"` case,
        // Formatting2.swift): the argument must literally begin `or=` and its fourth
        // character decides. Anything looser here would invent a checkpoint for a command
        // the parser ignored.
        let a = arg.map(asciiUppercased)
        guard a.count > 3, a[0] == 0x4F, a[1] == 0x52, a[2] == 0x3D else { continue }  // "OR="
        let resolved: Orientation
        if a[3] == 0x4C { resolved = .landscape }        // 'l'
        else if a[3] == 0x50 { resolved = .portrait }    // 'p'
        else { continue }
        if resolved != checkpoints[checkpoints.count - 1].orientation {
            checkpoints.append((dp.blockIndex, dp.lineIndex, resolved))
        }
    }
    return checkpoints
}

/// The orientation in force for a page opening at block `bi`, per `checkpoints`
/// (ascending, from `orCheckpoints`). Port of Python's `_or_at`.
///
/// `consumed` is how many lines of block `bi` EARLIER pages already took -- the
/// paginator's own `readTally[bi]`. With it, a checkpoint counts when it sits at or before
/// this page's opening position, so a `.pr` further into the block than this page reached
/// belongs to a later page. Without it (`nil`) the comparison is block-granular: every
/// checkpoint in block `bi` counts. RTF's section spine uses that form, having already
/// resolved each change to the paragraph boundary it can actually break at.
func orAt(_ checkpoints: [(blockIndex: Int, lineIndex: Int, orientation: Orientation)],
          _ bi: Int, _ consumed: Int? = nil) -> Orientation {
    var orientation = checkpoints[0].orientation
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        if cp.blockIndex == bi, let consumed, cp.lineIndex > consumed { break }
        orientation = cp.orientation
    }
    return orientation
}

/// `page` as THIS SHEET's orientation wants it (M31). Port of Python's
/// `_page_dict_for_orientation`.
///
/// `landscapePage` is idempotent by construction -- it recomputes the height/width pair
/// fresh from the page's own `.pl` rather than swapping whatever pair it is handed -- so
/// `.landscape` can be applied to a geometry that has already been swapped, or to one that
/// has not, with the same answer. `.portrait` is the other direction and needs the same
/// treatment: `resolvePageSize`'s own PORTRAIT-convention resolution of this page's `.pl`,
/// recomputed fresh, so a page that must be put BACK from a document-wide landscape swap
/// lands exactly where a portrait document's own geometry would have.
public func pageGeometryFor(_ page: PageGeometry, orientation: Orientation) -> PageGeometry {
    if orientation == .landscape { return landscapePage(page) }
    let (heightIn, _, pwIn) = resolvePageSize(page.plLines)
    var eff = page
    eff.heightIn = heightIn
    eff.pwIn = pwIn
    return eff
}

/// The document an emitter actually lays out: `options.pageSettings` folded in, then
/// Printed's `.pr or=l` rotation on top of it, in that order. THE one place that order is
/// written down.
///
/// `options.pageSettings` is replacement geometry for everything the document does not
/// declare itself (a field is overridden only when its own resolved value is still this
/// project's built-in default — a document's own dot commands always win), because
/// WordStar's stock defaults are not what a given machine printed: WSCHANGE patches them
/// per installation. Applied to a COPY — `Document` is a value type, so there is nothing to
/// restore afterward, unlike Python's save/try/finally dance around a shared mutable
/// `doc.meta['page']`. The CLI applies the same thing once per document (`Run.swift`) via
/// the same `effectivePage` (EmitOptions.swift).
///
/// The rotation lands AFTER `pageSettings` — matching ctrl-kd: page-settings replacement
/// geometry, then orientation swap on top of it. It was PRINTED-ONLY (b24 round 17,
/// RULINGS-LEDGER row 2) until Jon's ruling 2026-09-15 ("Yes. Fix it.") took `.pr or=l`
/// to Modern as well: the paged-surface doctrine's own point 2 ("honor .pr or=l landscape
/// in ALL paged surfaces", 2026-08-17) reaching the last paged surface that ignored it,
/// and the 2026-08-05 ruling that Modern PDF is the printed form of the Modern RTF.
/// `printed` therefore no longer selects anything here; the parameter stays because this
/// function is the one place mode-specific page geometry belongs, and because
/// `printedDocument` is the public façade that says which mode it is asking about.
///
/// WHY IT IS A FUNCTION (planning #271 M2). Both steps used to be written inline at the top
/// of `emitPDF`, and the public façade the app draws its on-screen Printed page from
/// (`printedMetrics`, PrintedGeometry.swift) did NEITHER: a landscape document measured a
/// 612-wide portrait page on screen while the exported PDF used the rotated 792x612 and
/// anchored its running content, note area and first baseline to that — the same document
/// two ways, which is the exact failure that file exists to prevent. `printedDocument` is
/// the public form of this call; nothing outside re-derives the order.
///
/// `printed` is the caller's own already-resolved mode flag (`mode == .printed ||
/// isPrinted(doc)`), not re-derived here, so a caller that already knows which page it is
/// asking about (the façade: always Printed) does not have to fake a `Document` to say so.
func resolvedGeometryDocument(_ doc: Document, printed: Bool, options: EmitOptions) -> Document {
    var out = doc
    if let pageSettings = options.pageSettings, let page = out.page {
        out.page = effectivePage(page, settings: pageSettings)
    }
    if out.formatting.orientation == .landscape, let page = out.page {
        out.page = landscapePage(page)
    }
    return out
}

/// Resolved page height, in points, for THIS document — the general form of Python's
/// `_resolved_page_height(doc, printed)` (pdf.py:42-53). `PDFWriter.swift`'s `emitPDF` needs
/// this too (the MediaBox and the content stream's Y-origin must agree with the capacity
/// this same figure drives, or a custom-geometry page paginates correctly but still gets
/// drawn on/labeled as a Letter-size sheet) so this is `internal`, not `private`.
///
/// Modern renders on the document's declared sheet (Letter/Legal/A4 -- ruled
/// 2026-08-06); silence is Letter, exactly as before.
///
/// M18 (2026-09-15): Modern has its own answer now, `modernSheetH`, and `emitPDF`'s
/// Modern branch calls THAT — the same number `modernStreams` composes on, with `.pl 0`
/// and the footnote floor handled the way Printed handles them. The `printed == false`
/// branch below is the shape of this function's contract, never a live Modern render.
/// True when NOT ONE line on any page carries a block index — a document with no body at
/// all. The corpus's examples are galley and manuscript TEMPLATES, one page each, nothing
/// but dot commands and a pair of `.h1o`/`.h1e` running heads. See
/// `pgnumForBodilessPage`. Port of `_pgnum_is_bodiless`.
func pgnumIsBodiless(_ pages: [Page]) -> Bool {
    !pages.contains { $0.contains { $0.bi != nil } }
}

/// Whether WordStar numbers a page that carries no `.bi` of its own. Port of
/// `_pgnum_for_bodiless_page`.
///
/// `explicitBreakBI` (planning #228) is the `.pa` block's own index and stands in for
/// "wherever the document's own state was when this page opened" on a confirmed
/// trailing-`.pa` page, which DOES need a number (WS7 stamps one). That case is unchanged.
///
/// A page with NEITHER used to answer a hard `false`, which is not a fallback but a
/// different rule. Planning #274 (2026-09-15): a document that is ALL HEAD AND NO BODY got
/// no number on its one page even though nothing in it ever asked for `.op`, while real
/// WS7 stamps one at the exact row this engine already computes. For such a document the
/// opening state IS the page's state: there is no later block whose `.op`/`.pn`/`.pg`
/// could have been read, so checkpoint 0 is not an approximation, it is the answer.
///
/// THAT IS WHY `bodilessDoc` IS A WHOLE-DOCUMENT TEST and not a per-page one. A page that
/// merely came out EMPTY inside a document that does have blocks — a run of blank lines,
/// `finalizePages` having stripped them — is a different thing: answering it from
/// checkpoint 0 would ignore every command read since, which is exactly the misnumbering
/// the 2026-09-15 research note names. Those pages keep the previous answer.
func pgnumForBodilessPage(_ checkpoints: [PgnumCheckpoint], fallbackBi: Int?,
                          bodilessDoc: Bool) -> Bool {
    if let fallbackBi { return pgnumAt(checkpoints, fallbackBi) }
    return bodilessDoc ? pgnumAt(checkpoints, 0) : false
}

/// The baseline y (points) of WordStar's automatic page-number row — the SAME row a
/// `.fo` line 1 rides, `pl - mb + fm` — or nil when the sheet has no such row at all.
/// Port of `_auto_pageno_row_y`.
///
/// ONE DEFINITION, two readers. Printed DRAWS at this y (`resolveHeadFootLines`). Modern
/// only asks whether it is nil, because "the Modern view shows WordStar's automatic page
/// number wherever Printed does" (Jon's ruling M15, 2026-09-15) is a question about
/// WHETHER WordStar numbers this page, never about where Modern then puts it — Modern
/// places it in its own margin model. Deriving that answer twice is how the two views
/// would come to disagree about the same document.
///
/// THE STEP IS A WORDSTAR PAGE LINE, 1/6 IN, NEVER THE DOCUMENT'S `.lh` (planning #274,
/// 2026-09-15). `.pl`/`.mb`/`.fm` count PAGE lines — the fixed 6-LPI grid WordStar
/// measures a sheet in — and this arithmetic used to multiply that count by
/// `printedLead(doc)`, the document's own body leading. The two are the same number for
/// every document that leaves `.lh` alone (the default 8/48in IS 12pt), which is why it
/// went unnoticed; a document that sets `.lh` higher pushed the row down by
/// (lh - 12) x ~60 lines and off the paper entirely, and the number simply vanished.
/// MEASURED against all 212 WS7 captures that print an automatic number: the 1/6in step
/// agrees with 211 of them, the `.lh` step with 200. The one disagreement under either
/// rule is the corpus's own `.pl 0` document, whose behaviour WordStar leaves undefined
/// and which Jon removed from all further work on 2026-09-10 (planning #261).
///
/// THE COUNTS ARE REAL PAGE LINES, never truncated: `.mb 1.8`/`.fm 1.14` are ordinary
/// corpus values and rounding them moves the row by most of an inch.
///
/// nil IS THE `.mb 0` RULE (research 2026-09-15, rule 3: "no bottom margin — there is no
/// footer line on the sheet at all, so there is nowhere to put a number"; in this corpus,
/// label stock, Rolodex cards and mail-merge format files — 24 captures, not one of them
/// numbered). It is TESTED FOR, since 2026-09-15. It used to fall out of the arithmetic
/// instead — MAILLIST/LABELA is `.pl 6 .mb 0 .fm 0` on a 72pt sheet, so the row landed at
/// y = -12 and a blanket "must be on the paper" guard dropped it — and that guard was
/// wrong about the OTHER class it caught. Real WS7 does not clamp the row to the sheet:
/// with `.mb 1.8 .fm 2` on a 66-line page it commands the number 806.4pt from the top of
/// a 792pt sheet, 14.4pt PAST the bottom edge. So the row is returned wherever the
/// arithmetic puts it and the page clips it exactly as the printer does; only a document
/// with NO bottom margin has no row at all.
func autoPagenoRowY(pageHeight: Int, pl: Double, mb: Double, fm: Double,
                    size: Int) -> Double? {
    if mb <= 0 { return nil }
    return Double(pageHeight) - (pl - mb + fm) * Double(PDFMetrics.lead) - Double(size)
}

func resolvedPageHeight(_ doc: Document, printed: Bool) -> Int {
    printed ? resolvedPrintedPageHeight(doc)
        : roundHalfToEven((doc.page?.heightIn ?? 11.0) * 72.0)
}

/// Resolved PRINTED-page height, in points. Port of `_resolved_page_height(doc, printed:
/// True)` (pdf.py:42-53) — the printed-mode branch of `resolvedPageHeight` above.
///
/// Honours the file's own `.pl`-derived `heightIn` where the document has one (every
/// `parseWS` document does, resolved with a default when the file never set `.pl`);
/// defaults to 11in (`doc.meta.get('page', {}).get('height_in', 11.0)` in Python) for a bare
/// print-stream capture, which carries no dot commands to resolve page geometry from at
/// all. Clamped to at least `LEAD * (footnoteFloor + 1)` points so a degenerate tiny/absent
/// page can never send the capacity below the floor `_printed_cap` itself also enforces.
private func resolvedPrintedPageHeight(_ doc: Document) -> Int {
    guard let page = doc.page else { return printedPageHeightPt(nil) }
    return printedPageHeightPt(page)
}

/// One PAGE GEOMETRY's own printed height in points -- the arithmetic
/// `resolvedPrintedPageHeight` has always done, split out (M31) so a caller holding a
/// single page's resolved sheet (per-page orientation, the layout JSON's `size`) gets the
/// same answer without a whole `Document`. `nil` is the bare print-stream capture's own
/// 11in default. Port of Python's `_page_height_pt_for`.
public func printedPageHeightPt(_ page: PageGeometry?) -> Int {
    let heightIn = page?.heightIn ?? 11.0
    if heightIn == 0 {
        // `.pl 0` = page breaks off (bug 12284; see `textLinesPerPage`). The text model
        // already never breaks; the PDF page box itself falls back to Letter — a truly
        // unbounded page is not expressible in PDF.
        return PDFMetrics.pageHeight
    }
    let floorPoints = PDFMetrics.lead * (footnoteFloor + 1)
    return max(floorPoints, roundHalfToEven(heightIn * 72))
}

/// Printed-mode page capacity, in lines. Port of Python's `_printed_cap` (pdf.py, ctrl-kd
/// 1.3.0) — WordStar's own vertical model, not the fixed-margin arithmetic this used before:
///
/// WS documents (`doc.page` non-nil) get WordStar's own vertical model
/// (`textLinesPerPage`/Python's `_text_lines_per_page`: `.pl - .mt - .mb` at the `.lh` line
/// height — 55 for WordStar's own defaults, NOT the 60 a naive 1in-margin computation gave
/// before this fix). Print streams (`ParsePrintstream.swift`'s `parsePrintstream` — no `page`
/// meta at all) get the SAME model, from WordStar's documented defaults — see the body for
/// why the previous "their margin blanks travel in-band, so give them the full 66" reasoning
/// was retracted.
///
/// Clamped to at least `footnoteFloor + 1` lines either way, so a degenerate/tiny page can
/// never divide the page-bottom math by, or loop over, too little room.
///
/// SECOND KNOWN LIMIT, added with stateful `.lh` (2026-08-05). Capacity is computed at the
/// DOCUMENT-DEFAULT line height — `textLinesPerPage` on `page.lh48`, the file's first `.lh`.
/// A document that changes leading mid-page therefore paginates at a fixed lines-per-page
/// while its lines advance at their own leads, so a page of tightly-led text ends early and a
/// page of banners can run long. Whether WordStar RECOMPUTED lines-per-page as `.lh` changed
/// is UNMEASURED — register open question #15 — and the honest options (recompute per line,
/// or accumulate points until the text height is used up) are different answers to a question
/// no manual page settles. Guessing here would silently repaginate every multi-`.lh` document
/// on an assumption; leaving capacity where the evidence is keeps the change to what was
/// ruled: leads, not pagination.
func printedCap(_ doc: Document) -> Int {
    if let page = doc.page {
        return max(footnoteFloor + 1, page.textLines)
    }
    // PRINT STREAMS GET THE SAME MODEL. Corrected 2026-08-03 (Jon's ruling: "print
    // streams need to follow WordStar standards, not our falsely invented ones").
    // This used to hand a print stream the FULL page height — 66 lines on Letter —
    // justified by the claim that "their margin blanks travel in-band". That claim
    // was checked against raw bytes and is FALSE for real print-to-disk output: such
    // a stream carries no form feeds, and no top margin after its first page. It is
    // not a stack of whole physical pages; it is a run of printed lines. Paginating
    // it at 66 invented a page size WordStar does not document and no evidence
    // supports.
    //
    // So a stream with no page metadata falls back to WordStar's documented defaults,
    // the same as a document that declares none: .pl 66 - .mt 3 - .mb 8 = 55 lines.
    // That is what WordStar 4 itself produces when run (its live output shows 11-line
    // inter-page gaps = .mb 8 + .mt 3, on a 66-line pitch), and it makes the three
    // renderings of one document — the WS4 source, its print stream, and the live
    // program — finally agree at 9 pages, which none of them did before.
    //
    // KNOWN LIMIT, recorded rather than papered over: a print stream that DOES carry
    // its margins in band (WordStar 4's live output does) now gets margin on top of
    // margin. Distinguishing the two cases needs evidence we do not have, and
    // inventing a detector is exactly what this change undoes.
    return max(footnoteFloor + 1,
               textLinesPerPage(pl: defaultPlLines, mt: defaultMtLines,
                                mb: defaultMbLines, lh48: defaultLh48))
}

/// `printedCap`, but for an EXPLICIT (mt, mb) pair instead of the document's global
/// first-occurrence values — Finding 3 (b26-print-fidelity-2)'s per-page capacity; see
/// `mtMbCheckpoints`. Port of Python's `_printed_cap_for`.
///
/// `doc.page?.textLines` is a value CACHED at parse time from the document's global
/// mt/mb (`ParseWS.swift`'s own `textLinesPerPage` call) — calling that same function
/// directly here, rather than reading the cache, is what makes a page whose (mt, mb)
/// MATCHES the global pair come out byte-identical (same formula, same inputs) while a
/// page that changes them gets its own true capacity.
///
/// NEVER BELOW the document's own global capacity (b26-mtmb-general, LJ6DTP.WS): a
/// mid-document margin change may LOOSEN a page (more room than the document's own
/// declared default) but WS7 does not let one TIGHTEN it. Reconciled from two real WS7
/// captures whose mid-document `.mt`/`.mb` changes point opposite directions:
///   SCRIPT.WS block 64 (`.mt1`/`.mb0`, Figure 1's own tiny margins): local cap 65 >
///     global cap 53 (pl 66 - mt 7 - mb 6, its own `.MT 7`/`.MB 6`) — HONORED. WS7 fits
///     the whole figure on one page (measured: SCRIPT.pcl page count 11, matching only
///     when this local cap is used).
///   LJ6DTP.WS block 12 (`.mt1"`/`.mb1"`, right after the SAME kind of `.pa`-then-
///     margin-restate SCRIPT's own figures use): local cap 46 (pl 66 - mt 6.0 - mb 6.0)
///     < global cap 48 (pl 66 - mt 6.6 - mb 3.0, its own `.mt 1.1"`/`.mb .5"`) — NOT
///     honored. WS7's "Proportional Spacing Tables" section (measured: LJ6DTP.pcl, page
///     7 of 8) prints on ONE page; using the tighter local cap splits it across two, one
///     page too many (9 engine vs WS7's 8).
/// Both obey `cap = max(local, global)` with no exception — the ONE rule shape that
/// fits both real captures pointing opposite ways. Applying the SAME clamp per-field
/// (e.g. only to `.mb`, treating `.mt` differently) was considered and rejected:
/// LJ6DTP's own `.mt` change (6.6 -> 6.0, negligible) can't discriminate between "mb
/// never applies mid-document" and "mb is clamped" from this evidence alone, but "mb
/// never applies" independently FAILS SCRIPT (whose `.mb0` must be honored) while the
/// whole-cap max does not — so the max is the narrower, non-file-specific reading of
/// what's actually measured. The RENDERED override (`Page.mtLines`/`mbLines`, used for
/// the per-page printed-top/running-ops geometry swap) is untouched — only pagination
/// CAPACITY clamps; a document's own declared margin still renders where it says.
/// `plLines` (register b31-dot-command-sweep, `plCheckpoints`): `.pl` is STATEFUL exactly
/// like `.mt`/`.mb` -- measured against real WS7 (PL_PROBE, dosbox-x): a document holding
/// `.mt`/`.mb` fixed and setting `.pl 20` then `.pl 40` mid-document printed 18 lines on
/// page 1 (cap = 20-1-1) and 38 on page 2 (cap = 40-1-1) -- the SECOND value, not the
/// first, governs the page that follows it. `nil` means "no page-specific override", i.e.
/// use the document's own global first-occurrence `.pl` (every document that never
/// repeats `.pl` mid-document). Port of Python's `_printed_cap_for`.
func printedCapFor(_ doc: Document, mtLines: Double, mbLines: Double, plLines: Double? = nil) -> Int {
    let pl = plLines ?? (doc.page?.plLines ?? defaultPlLines)
    let lh = doc.page?.lh48 ?? defaultLh48
    let local = max(footnoteFloor + 1, textLinesPerPage(pl: pl, mt: mtLines, mb: mbLines, lh48: lh))
    return max(local, printedCap(doc))
}

/// A printed page's own vertical budget IN POINTS -- the real text height
/// `.pl - .mt - .mb` measures on paper, at the 6 LPI grid those three commands are
/// counted on (`PDFMetrics.lead`, 12pt a line), NOT that height re-quantized to a whole
/// number of DEFAULT leads. Port of Python's `pdf._printed_budget_pt`.
///
/// `printedCap` answers a different question -- "how many default-lead lines fit" -- and
/// answering it requires a FLOOR (`textLinesPerPage`'s own `Int(usable * 8 / lh48)`).
/// Spending the floored count back out as `cap * defaultLead` throws away the page's own
/// fractional remainder: up to one default lead of real paper that WordStar does put
/// lines on whenever the lines that land there are SHORTER than the default. Measured
/// against real WS7 (`ws7-prints/v4`, PRISTINE.EXE), on the four documents that pair a
/// fractional-inch `.mt` with an explicit `.lh 14pt` and open with two 12pt lines before
/// that `.lh` takes effect:
///
///   | Doc | `.mt`/`.mb` | usable | cap x 14pt | WS7 | old | new |
///   |---|---|---:|---:|---:|---:|---:|
///   | REF/WINGDING.CHT | 1.6"/.3" | 655.2pt | 644 | 2 + 45 | 2 + 44 | 2 + 45 |
///   | REF/SYMBOL.CHT | 1.2"/.3" | 684.0pt | 672 | 2 + 47 | 2 + 46 | 2 + 47 |
///   | PRINTERS/fontcrib.ws | .4"/.3" | 741.6pt | 728 | 2 + 51 | 2 + 50 | 2 + 51 |
///   | PRINTER.PS | .4"/.3" | 741.6pt | 728 | 2 + 51 | 2 + 50 | 2 + 51 |
///
/// Every one lost EXACTLY one line per page, on every column of every page.
///
/// BYTE-IDENTICAL WHEREVER THE LEAD IS UNIFORM, which is the whole corpus outside those
/// documents: with every line on a page carrying the same lead `L`, `n` lines fit iff
/// `n * L <= usablePt`, i.e. `n <= floor(usablePt / L)` -- and when `L` is the document
/// default that floor IS `cap`, so the answer does not move. The remainder can only ever
/// be spent by a line whose own lead is SMALLER than the default, which is exactly the
/// mixed-`.lh` page this corrects (register open question #15's second half, now
/// measured rather than guessed).
///
/// NEVER BELOW `cap * defaultLead`: `printedCap`/`printedCapFor` carry two rulings that
/// RAISE the line count above what this page's own `.pl/.mt/.mb` would give -- the
/// `footnoteFloor + 1` floor, and b26-mtmb-general's `max(local, global)` (a mid-document
/// margin change may loosen a page, never tighten it). Both are expressed in lines, so
/// they are re-applied here as `cap * defaultLead` and win when they are the larger
/// number; a `.pl 0` document (capacity 10^9, page breaks off) falls out of the same max
/// with no special case.
func printedBudgetPt(_ doc: Document, capacity: Int, defaultLead: Double,
                     mtLines: Double? = nil, mbLines: Double? = nil,
                     plLines: Double? = nil) -> Double {
    let pl = plLines ?? (doc.page?.plLines ?? defaultPlLines)
    let mt = mtLines ?? (doc.page?.mtLines ?? defaultMtLines)
    let mb = mbLines ?? (doc.page?.mbLines ?? defaultMbLines)
    let ruledFloor = Double(capacity) * defaultLead
    let usablePt = (pl - mt - mb) * Double(PDFMetrics.lead)
    if !usablePt.isFinite { return ruledFloor }
    return max(ruledFloor, usablePt)
}

/// `[(blockIndex, mtLines, mbLines), ...]` in ascending block order — the `.mt`/`.mb`
/// pair IN FORCE from that block onward, at BLOCK granularity (the coarsest anchor
/// `Document.dotPositions` gives — the same mechanism Soft Return.app's Show Invisibles
/// and `tocPageNumbers`/`AnnotatedLayout.swift` already read). Mirrors how `.lh` already
/// tracks per-LINE state (`Line.lead48`/`styleLeadPt`) — one level coarser, because
/// `.mt`/`.mb` only take visible effect at the next page start, never mid-line. Port of
/// Python's `_mt_mb_checkpoints`.
///
/// The FIRST checkpoint (block 0) is the document's own global mtLines/mbLines
/// (`ParseWS.swift`'s "first occurrence wins" page dict) — a document that never
/// touches `.mt`/`.mb` again after its own opening geometry gets exactly ONE checkpoint,
/// so every page's lookup returns the SAME pair the document-global functions already
/// gave it: no behaviour change for any document but the ones this exists for.
///
/// Finding 3: SCRIPT.WS changes both mid-document, around its embedded worked-example
/// figures — measured (ARTICLES/SCRIPT.WS's own dot-command bytes, via
/// `doc.dotPositions`): block 64 sets `.mt1`/`.mb0` (Figure 1's near-zero margins),
/// block 75 sets `.mt1"`/`.mb1"` (Figure 2's own, different margins).
func mtMbCheckpoints(_ doc: Document) -> [(blockIndex: Int, mt: Double, mb: Double)] {
    var mt = doc.page?.mtLines ?? defaultMtLines
    var mb = doc.page?.mbLines ?? defaultMbLines
    var checkpoints: [(blockIndex: Int, mt: Double, mb: Double)] = [(0, mt, mb)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "MT" || upperName == "MB" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if upperName == "MT" { mt = resolved } else { mb = resolved }
        if mt != checkpoints[checkpoints.count - 1].mt
            || mb != checkpoints[checkpoints.count - 1].mb {
            checkpoints.append((dp.blockIndex, mt, mb))
        }
    }
    return checkpoints
}

/// `(mtLines, mbLines)` in force at block index `bi`, per `checkpoints` (ascending, from
/// `mtMbCheckpoints`) — the LAST checkpoint at or before `bi`. Port of Python's
/// `_mt_mb_at`.
func mtMbAt(_ checkpoints: [(blockIndex: Int, mt: Double, mb: Double)], _ bi: Int) -> (mt: Double, mb: Double) {
    var mt = checkpoints[0].mt
    var mb = checkpoints[0].mb
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        mt = cp.mt
        mb = cp.mb
    }
    return (mt, mb)
}

/// `[(blockIndex, plLines), ...]` in ascending block order -- the `.pl` IN FORCE from that
/// block onward. Mirrors `mtMbCheckpoints`'s mechanism (same `dotPositions` anchor) but NOT
/// its block-0 seed: kept as its OWN function/list rather than folded in because `.pl` was
/// found and fixed separately (register b31-dot-command-sweep), on its own oracle evidence.
/// Port of Python's `_pl_checkpoints`.
///
/// Real WS7 evidence (PL_PROBE, dosbox-x): a document that holds `.mt`/`.mb` fixed at 1
/// line each and sets `.pl 20` then, after exactly one page's worth of body, `.pl 40`,
/// printed 18 lines on page 1 (cap = pl 20 - mt 1 - mb 1) and 38 on page 2 (cap = pl 40 -
/// mt 1 - mb 1) -- the page AFTER the second `.pl` uses ITS value, not the document's
/// first.
///
/// Seeded at WordStar's own HARDCODED default (`defaultPlLines`), NEVER at
/// `doc.page?.plLines` (`ParseWS.swift`'s first-occurrence reading) -- those are the SAME
/// number for a document that declares `.pl` right at its own start (the overwhelming
/// common case), but NOT for one whose only `.pl` sits mid-document with nothing before
/// it: `ParseWS.swift`'s "first occurrence wins" would read THAT single occurrence as the
/// document's global default and hand it back for block 0 too, retroactively applying the
/// mid-document value to pages that printed before the command was ever reached (caught
/// building `hmFmCheckpoints` below against a probe whose only `.hm`/`.fm` are
/// mid-document -- `.pl` shares the exact same construction, fixed here too).
///
/// If `dotPositions` carries no `.pl` entry AT ALL, the hardcoded seed is replaced with
/// `doc.page?.plLines` after the walk -- a document with no dot-command evidence for `.pl`
/// anywhere (every hand-built `Document(..., page:)` fixture that sets page geometry
/// directly rather than through `parseWS`, plus any real document that truly never sets
/// `.pl`) has no mid-document-only-occurrence to protect against, so its own declared page
/// value is trusted as-is -- exactly `mtMbCheckpoints`'s own seed. A document WITH at
/// least one `.pl` occurrence anywhere (mid-document or at its own true start, register
/// b31's actual target) is untouched by this fallback.
func plCheckpoints(_ doc: Document) -> [(blockIndex: Int, pl: Double)] {
    var pl = defaultPlLines
    var checkpoints: [(blockIndex: Int, pl: Double)] = [(0, pl)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PL" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if resolved != checkpoints[checkpoints.count - 1].pl {
            pl = resolved
            checkpoints.append((dp.blockIndex, pl))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].pl = doc.page?.plLines ?? defaultPlLines
    }
    return checkpoints
}

/// `plLines` in force at block index `bi`, per `checkpoints` (ascending, from
/// `plCheckpoints`) -- the LAST checkpoint at or before `bi`. Port of Python's `_pl_at`.
func plAt(_ checkpoints: [(blockIndex: Int, pl: Double)], _ bi: Int) -> Double {
    var pl = checkpoints[0].pl
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        pl = cp.pl
    }
    return pl
}

/// `[(blockIndex, hmLines, fmLines), ...]` in ascending block order -- the `.hm`/`.fm` pair
/// IN FORCE from that block onward. Mirrors `mtMbCheckpoints` (same anchor, same "pair"
/// shape) -- kept as its own pair/function rather than folded into `mtMbCheckpoints`
/// because `.hm`/`.fm` were found and fixed together, sharing one dot-command regex,
/// months after the mt/mb mechanism shipped. `runningOps`'s own `headBase` no longer
/// gates `hm`'s participation on `mtSource` at all (mechanism W, PCL-DIVERGENCE-
/// TRIAGE.md) -- it reads whatever `hmLines` this checkpoint pair resolves to for the
/// page unconditionally. Port of Python's `_hm_fm_checkpoints`.
///
/// Real WS7 evidence (HMFM_PROBE, dosbox-x, register b31-dot-command-sweep): a document
/// that never touches `.mt` (stays at the factory default throughout) but sets `.hm 6`/
/// `.fm 6` mid-document (factory default is `.hm 2`/`.fm 2`) printed its header/footer at
/// TWO different PCL rows -- 35.7pt/75.6pt on the pages before the change, 12.0pt/80.4pt on
/// the pages after it -- even though `.mt` itself never moved.
///
/// Seeded at WordStar's own hardcoded defaults (2.0/2.0, WSFORMAT's own `.hm`/`.fm`
/// defaults), NOT `doc.page?.hmLines`/`fmLines` (`ParseWS.swift`'s first-occurrence
/// reading) -- HMFM_PROBE is exactly the degenerate case that distinguishes them: its
/// `.hm`/`.fm` appear only ONCE, mid-document, so "first occurrence wins" reads that single
/// occurrence as the document's global default and would otherwise hand it back for block 0
/// too, retroactively applying the mid-document value to the pages that printed before the
/// command was ever reached. See `plCheckpoints`'s doc comment -- same fix, same reason.
///
/// Same hand-built-fixture fallback as `plCheckpoints`: no `.hm`/`.fm` entry anywhere in
/// `dotPositions` reseeds from `doc.page?.hmLines`/`fmLines` after the walk.
func hmFmCheckpoints(_ doc: Document) -> [(blockIndex: Int, hm: Double, fm: Double)] {
    var hm = 2.0    // WSFORMAT's own hardcoded default: ".HM ... Default is 2."
    var fm = 2.0    // WSFORMAT's own hardcoded default: ".FM ... Default is 2."
    var checkpoints: [(blockIndex: Int, hm: Double, fm: Double)] = [(0, hm, fm)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "HM" || upperName == "FM" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if upperName == "HM" { hm = resolved } else { fm = resolved }
        if hm != checkpoints[checkpoints.count - 1].hm || fm != checkpoints[checkpoints.count - 1].fm {
            checkpoints.append((dp.blockIndex, hm, fm))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].hm = doc.page?.hmLines ?? 2.0
        checkpoints[0].fm = doc.page?.fmLines ?? 2.0
    }
    return checkpoints
}

/// `(hmLines, fmLines)` in force at block index `bi`, per `checkpoints` (ascending, from
/// `hmFmCheckpoints`) -- the LAST checkpoint at or before `bi`. Port of Python's
/// `_hm_fm_at`.
func hmFmAt(_ checkpoints: [(blockIndex: Int, hm: Double, fm: Double)], _ bi: Int) -> (hm: Double, fm: Double) {
    var hm = checkpoints[0].hm
    var fm = checkpoints[0].fm
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        hm = cp.hm
        fm = cp.fm
    }
    return (hm, fm)
}

/// `[(blockIndex, poCols), ...]` in ascending block order -- the `.po` (page offset) IN
/// FORCE from that block onward. Mirrors `plCheckpoints` exactly (same `dotPositions`
/// anchor, same "block 0 is the document's own global first-occurrence value" contract,
/// same hand-built-fixture fallback) -- see `plCheckpoints`'s doc comment. Port of Python's
/// `_po_checkpoints`.
///
/// Body text already carries a mid-document `.po` change correctly: `ParseWS.swift` stamps
/// `Line.poCols` on every physical line (state carried forward exactly like `.lh`), and
/// `resolvePlainBody`/`resolvePrintedBody` override their own `left` per line whenever a
/// line's `poCols` differs from the document default (`resolveLeftPt(line.poCols, ...)`).
/// `runningOps` (the header/footer row) had NO equivalent -- it always rendered at the
/// document's global `left`, regardless of which page it was on.
///
/// SCRIPT.WS (sawyer archive) is the oracle (mechanism O, ctrl-kd 55d2b52): its own
/// worked-example figures reset `.po` to `.5"` (5 columns) around block 64 and again around
/// block 75/84, alongside the `.mt`/`.hm` changes `mtMbCheckpoints`/`hmFmCheckpoints` already
/// track for the SAME figures. WS7's own capture (`ws7-prints/v1/SCRIPT.pcl`) prints the
/// running head "PROFILES MONTH '88 SCRIPT.001..." on the figure pages starting at x=36.0pt
/// (column 5, the figure's own local `.po .5"`) -- this engine, reading only the document's
/// global `.po` default (8 columns, 57.6pt), rendered it 21.6pt (3 columns) too far right.
func poCheckpoints(_ doc: Document) -> [(blockIndex: Int, po: Double)] {
    var po = 8.0    // WS7 manual, "Page Layout": "The default page offset is 8 columns."
    var checkpoints: [(blockIndex: Int, po: Double)] = [(0, po)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PO" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveColsArg(value, unit)
        if resolved != checkpoints[checkpoints.count - 1].po {
            po = resolved
            checkpoints.append((dp.blockIndex, po))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].po = doc.page?.poCols ?? 8.0
    }
    return checkpoints
}

/// `poCols` in force at block index `bi`, per `checkpoints` (ascending, from
/// `poCheckpoints`) -- the LAST checkpoint at or before `bi`. Port of Python's `_po_at`.
func poAt(_ checkpoints: [(blockIndex: Int, po: Double)], _ bi: Int) -> Double {
    var po = checkpoints[0].po
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        po = cp.po
    }
    return po
}

/// Planning #231: `.poe`/`.poo` (even/odd page-offset) checkpoints, keyed by `dotName`
/// ("POE"/"POO") -- EMPTY if the document never uses that command (unlike
/// `poCheckpoints` above, NO block-0 seed: WordStar has no hardcoded default for a
/// parity-specific offset, "never set" genuinely means "no override," resolved by
/// falling back to whichever of `.po`/the other parity governs instead -- see
/// `leftForParity`). Port of ctrl-kd's `_poe_poo_checkpoints`.
func poeOrPooCheckpoints(_ doc: Document, dotName: String) -> [(blockIndex: Int, po: Double)] {
    var checkpoints: [(blockIndex: Int, po: Double)] = []
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == dotName else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveColsArg(value, unit)
        if checkpoints.isEmpty || resolved != checkpoints[checkpoints.count - 1].po {
            checkpoints.append((dp.blockIndex, resolved))
        }
    }
    return checkpoints
}

/// The resolved `poCols` for a page of the given parity (planning #231): its OWN
/// parity override if one is in force (`poe`/`poo`, each already `poAt`-resolved or
/// `nil` -- see `poeOrPooCheckpoints`), else whatever plain `.po` governs. Brief's own
/// rule: "odd pages use .poo (or .po), even pages .poe (or .po)." Port of ctrl-kd's
/// `_left_for_parity`.
func leftForParity(_ po: Double, _ poe: Double?, _ poo: Double?, isEven: Bool) -> Double {
    isEven ? (poe ?? po) : (poo ?? po)
}

/// `[(blockIndex, pnValue), ...]` in ascending block order -- a `.pn` RE-ANCHORS the
/// automatic page-number sequence starting on the page it appears on (WSFORMAT: ".PN ...
/// Sets the starting page number"), it does not merely set the document's own opening
/// number once. Port of Python's `_pn_checkpoints`.
///
/// Real WS7 evidence (PN_PROBE, dosbox-x, register b31-dot-command-sweep): printed page 1
/// as "10", page 2 as "11" (a `.pn 10` up front, incrementing normally), then page 3 as
/// "500" and page 4 as "501" once a mid-document `.pn 500` was reached -- the SECOND value
/// re-anchors the count from the page it lands on, exactly like the first.
///
/// Seeded at 1 (WordStar's own hardcoded starting number), same reason `plCheckpoints`/
/// `hmFmCheckpoints` seed at the hardcoded default rather than `doc.page?.pnStart` -- see
/// their doc comments. Same hand-built-fixture fallback too: no `.pn` entry anywhere in
/// `dotPositions` reseeds from `doc.page?.pnStart`.
/// 2026-09-12: a `.pn` is a real checkpoint even when its VALUE repeats one already
/// seen. The old guard compared against the last checkpoint's number rather than
/// against the number this page would otherwise have taken, and so threw away every
/// restart-to-a-number-already-used. MEASURED against real WS7 (ws7-prints/v4,
/// PRISTINE.EXE) on `sawyer/REF/CTRL-K.H1`, whose mid-document `.pn1` follows five
/// pages numbered 1-5: WS7 numbers its remaining sheets 6, 7, 8, 9 as pages 1, 2, 3, 4
/// -- which is also the parity its own `^K` even-page header rule reads
/// (`ctrlKEvenPage`). Two `.pn` inside the SAME block keep the last; a `.pn` in block 0
/// replaces the seed rather than doubling it.
func pnCheckpoints(_ doc: Document) -> [PNCheckpoint] {
    var checkpoints: [PNCheckpoint] = [PNCheckpoint(blockIndex: 0, lineIndex: 0, pn: 1)]
    var sawPN = false
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PN" else { continue }
        guard let (value, _) = parseDotNumber(arg) else { continue }
        let intValue = Int(value)
        sawPN = true
        // Two `.pn` commands at the SAME position keep the last one (the later command
        // wins, as for any other stateful dot command); a `.pn` at the seed's own
        // position replaces the seed rather than doubling it. POSITION, not block
        // (triage Q12): a block can hold two `.pn` commands sixty lines apart --
        // `-HOLYMAC.WS`'s front matter is one such block -- and merging them by block
        // index alone threw away the first and moved the second's page.
        let last = checkpoints[checkpoints.count - 1]
        if last.blockIndex == dp.blockIndex && last.lineIndex == dp.lineIndex {
            checkpoints[checkpoints.count - 1] = PNCheckpoint(
                blockIndex: dp.blockIndex, lineIndex: dp.lineIndex, pn: intValue)
        } else {
            checkpoints.append(PNCheckpoint(blockIndex: dp.blockIndex,
                                            lineIndex: dp.lineIndex, pn: intValue))
        }
    }
    if !sawPN {
        checkpoints[0].pn = doc.page?.pnStart ?? 1
    }
    return checkpoints
}

/// One `.pn` re-anchor, with the position it was read at.
///
/// THE LINE INDEX (triage Q12, probes 2026-09-14) is `dotPositions`' own second field:
/// how many of that block's lines came BEFORE the command. A block index alone is too
/// coarse for the same reason it was too coarse for a running head (triage Q9,
/// `Document.hfEventsWithin`) -- WordStar stores a `.pn` typed mid-paragraph between two
/// of that paragraph's own physical lines, and `-HOLYMAC.WS` does exactly that: its
/// second `.pn0` sits immediately after "Charles Maher", the last line page 1 has room
/// for. Read at block granularity it re-anchored the numbering ON page 1, which printed
/// a `0` real WS7 does not print.
struct PNCheckpoint {
    var blockIndex: Int
    var lineIndex: Int
    var pn: Int
}

/// One `.pn`/`.pg`/`.op` toggle of the automatic number, with the position it was read at
/// — the same anchor `PNCheckpoint` carries, for the same reason.
struct PgnumCheckpoint {
    var blockIndex: Int
    var lineIndex: Int
    var on: Bool
}

/// For each page, the index of the LAST checkpoint READ on or before it — the one shared
/// walk `resolvePageNumbers` and the automatic-number toggle (`pgnumByPage`) both need,
/// so the two cannot disagree about where a `.pn` was read.
///
/// A checkpoint has been read by the end of a page when the paginator, ON that page, had
/// got past its position. THE POSITION IS THE PAGE'S OWN `readPos` — `(block, how many
/// lines of that block this page had read)` when it closed — and NOT a count taken off
/// the finished pages, because `finalizePages` strips a page's trailing blanks: a page of
/// nothing but blank lines ends up empty, with no `bi` on it at all, which is precisely
/// the shape a leading blank run makes. A page that never got one (a synthetic or
/// degenerate page) inherits the last real position rather than resetting the walk.
///
/// A PAGE WITH NO POSITION AT ALL — not even an inherited one, because no earlier page
/// had one either — FALLS BACK TO THE BLOCK-RANGE RULE, the granularity this walk
/// replaced on 2026-09-14: the last checkpoint whose block index is at or before the
/// highest block index this page carries. Leaving it on the seeded checkpoint 0 instead
/// silently answered "the document's opening default" for a page that plainly reads
/// further in, and the document's own `.op` was never consulted: `LYING.WS` numbered all
/// three of its pages where real WordStar 7 numbers none of them, because the footnote
/// paginator set no `readPos` and LYING's `.op` is checkpoint 1 (research: "Why real WS7
/// prints no page number on some documents", 2026-09-15). Never moves BACKWARD — the
/// walk's consumers (`resolvePageNumbers`' re-anchor test) read a falling index as a new
/// anchor.
///
/// Checkpoints are ascending, so the first one this page has not reached stops the walk:
/// nothing after it can have been reached either. Port of `_checkpoints_by_page`.
func checkpointsByPage(_ positions: [(blockIndex: Int, lineIndex: Int)],
                       _ pages: [Page]) -> [Int] {
    var out: [Int] = []
    var last = 0
    var pos: PageReadPos?
    for pg in pages {
        if let p = pg.readPos { pos = p }
        if let pos {
            var idx = last + 1
            while idx < positions.count {
                let cp = positions[idx]
                if !(cp.blockIndex < pos.bi
                     || (cp.blockIndex == pos.bi && cp.lineIndex < pos.count)) { break }
                last = idx
                idx += 1
            }
        } else {
            last = max(last, checkpointByBlock(positions, pg))
        }
        out.append(last)
    }
    return out
}

/// The BLOCK-RANGE answer for one page: the index of the last checkpoint whose block
/// index is at or before the highest block index the page carries — `pgnumAt`/`plAt`'s own
/// "last checkpoint at or before this block wins" contract, as an index rather than a
/// value so the positional walk above can keep using it as a floor.
///
/// A page carrying no `bi` at all (nothing but emitter-made lines — a footnote-area-only
/// page, a blank page whose trailing blanks were stripped) has no block range to test, so
/// it keeps whatever the walk already had. Port of `_checkpoint_by_block`.
func checkpointByBlock(_ positions: [(blockIndex: Int, lineIndex: Int)],
                       _ pg: Page) -> Int {
    var top: Int?
    for ln in pg {
        if let bi = ln.bi, top == nil || bi > top! { top = bi }
    }
    guard let top else { return 0 }
    var last = 0
    var idx = 1
    while idx < positions.count {
        if positions[idx].blockIndex > top { break }
        last = idx
        idx += 1
    }
    return last
}

/// `[pageNumber, ...]`, one per `pages` (ascending, from `docToPagelines`) -- walks the
/// pages in order, re-anchoring to a `.pn` checkpoint's own value on whichever page its
/// block index first lands on (WordStar's own "sets the number of the page it appears
/// on"), otherwise continuing the previous page's number by one. A page with no
/// `bi`-carrying line at all (should not happen for real content, but a synthetic/
/// degenerate page is handled rather than crashed on) just continues the count. Port of
/// Python's `_resolve_page_numbers`.
///
/// A checkpoint is consumed (matched to a page) at most once, by the FIRST page whose own
/// block range reaches it -- `appliedBi` tracks the highest checkpoint block index already
/// used, so a checkpoint sitting mid-page is applied to THAT page (not the next one) and
/// never re-applied to a later page that also happens to satisfy `cp.blockIndex <=
/// pageMaxBi`.
func resolvePageNumbers(_ checkpoints: [PNCheckpoint], _ pages: [Page]) -> [Int] {
    var numbers: [Int] = []
    var current: Int?
    var previous = -1
    let byPage = checkpointsByPage(
        checkpoints.map { (blockIndex: $0.blockIndex, lineIndex: $0.lineIndex) }, pages)
    for idx in byPage {
        if current == nil || idx > previous {
            current = checkpoints[idx].pn      // re-anchored on this page
        } else {
            current! += 1
        }
        previous = idx
        numbers.append(current!)
    }
    return numbers
}

/// `[(blockIndex, enabled), ...]` ascending -- whether WordStar's AUTOMATIC page number
/// (the one `.pc` positions; WSFORMAT.WS's own text: ".PC ... active only when the
/// footers are not in use and page numbering is turned on") is ON from that block
/// onward. Mirrors `pnCheckpoints`'s shape exactly (same `dotPositions` anchor, "last
/// checkpoint at or before this block wins" contract, via `pgnumAt` below). Port of
/// ctrl-kd's `_pgnum_checkpoints` (pdf.py, register b31, E3 item 2, 2026-08-25).
///
/// Seeded ON -- WordStar 7's stock factory default state (WSCHANGE ships the
/// automatic page number ON, centered at the bottom margin, unless `.op` turns it
/// off). REVERSED 2026-09-07, ported from ctrl-kd `pdf.py`'s `_pgnum_checkpoints`
/// (commit b6d5d03): ws7-prints/v3 (the PRISTINE.EXE recapture), finding #2 --
/// documents that never touch `.pn`/`.pg`/`.op`/`.pc` at all print a stock
/// bottom-of-page automatic number under a genuinely stock WS7 install, confirmed
/// at the raw PCL byte level across BOXES/SAWYER/VERSIONS/-README plus several
/// private-corpus documents. Previously seeded OFF, MEASURED (dosbox-x, 16 probes) against Robert J.
/// Sawyer's own WSCHANGE-customized install -- the same install-contamination
/// family as ctrl-kd's `.po` column 7 vs 8 bug (mechanism S, already ported/
/// reverted here too): Sawyer's WSCHANGE profile turned the automatic number OFF
/// by default, stock WS7 does not.
///
/// `.pn` (ANY occurrence -- WSFORMAT: "sets the starting page number"; measured: a
/// bare `.pn 5` with no header/footer/`.pg` at all still printed a bottom-of-page
/// number) and `.pg` (WSFORMAT's own documented re-enable after `.op`) both turn it
/// ON (a no-op against this new default, since it is already ON); `.op` turns it
/// OFF -- unaffected by this change, still the only way a document reaches "no
/// number". Genuinely stateful mid-document (measured: page 1 under `.op` silent,
/// pages after a mid-document `.pg` numbered, no `.pn` anywhere in that probe at
/// all -- `.pg` alone activates it).
///
/// This is the engine for `EmitOptions.PageNumberMode.auto` (the default): the
/// document's own dot commands decide, byte-identical to every existing capture/oracle
/// for the overwhelming majority of documents that never touch any of these four
/// commands (they now get the stock automatic number instead of none). `.on`/`.off`
/// bypass this entirely -- see `emitPDF`'s own call site (PDFWriter.swift).
func pgnumCheckpoints(_ doc: Document) -> [PgnumCheckpoint] {
    var checkpoints: [PgnumCheckpoint] = [PgnumCheckpoint(blockIndex: 0, lineIndex: 0,
                                                          on: true)]
    for dp in doc.dotPositions {
        // No word-boundary check: a real WS7 file overwhelmingly writes `.pn0`/`.pn22`/
        // `.pg` with NO space before a following digit, and `dotCommandNameAndArg`'s own
        // 1-3-ASCII-letter scan (the same one every other checkpoint walk in this file
        // uses) already stops at the first non-letter, so `.PN0` correctly yields name
        // "PN" -- no `\b`-style trap to avoid here the way ctrl-kd's regex port had to
        // name explicitly.
        guard let (name, _) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        let value: Bool
        if upperName == "PN" || upperName == "PG" {
            value = true
        } else if upperName == "OP" {
            value = false
        } else {
            continue
        }
        let last = checkpoints[checkpoints.count - 1]
        if value != last.on {
            checkpoints.append(PgnumCheckpoint(blockIndex: dp.blockIndex,
                                               lineIndex: dp.lineIndex, on: value))
        } else if last.blockIndex == dp.blockIndex && last.lineIndex == dp.lineIndex {
            checkpoints[checkpoints.count - 1] = PgnumCheckpoint(
                blockIndex: dp.blockIndex, lineIndex: dp.lineIndex, on: value)
        }
    }
    return checkpoints
}

/// Whether the automatic page number is ON, per page — the positional twin of `pgnumAt`
/// (triage Q12, probes 2026-09-14). `.pn`/`.pg` turn it on and `.op` turns it off, and
/// WHERE each one is read is the same question `resolvePageNumbers` asks, so it is the
/// same walk: `checkpointsByPage`. Read at block granularity, `-HOLYMAC.WS`'s second
/// `.pn0` — which sits immediately after "Charles Maher", the last line page 1 has room
/// for — turned numbering back on ON page 1 and printed a `0` real WS7 does not print.
func pgnumByPage(_ checkpoints: [PgnumCheckpoint], _ pages: [Page]) -> [Bool] {
    checkpointsByPage(checkpoints.map { (blockIndex: $0.blockIndex, lineIndex: $0.lineIndex) },
                      pages).map { checkpoints[$0].on }
}

/// Whether the automatic page number is ON at block index `bi`, per `checkpoints`
/// (ascending, from `pgnumCheckpoints`) -- the LAST checkpoint at or before `bi`,
/// mirroring `plAt`/`hmFmAt`. Port of ctrl-kd's `_pgnum_at`.
func pgnumAt(_ checkpoints: [PgnumCheckpoint], _ bi: Int) -> Bool {
    var on = checkpoints[0].on
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        on = cp.on
    }
    return on
}

/// Measured (dosbox-x, register b31, E3 item 2, 2026-08-25): the automatic page
/// number's LEFT edge sits at column `(poCols + pcCol - 1)` in the SAME 10-CPI frame
/// `.po`/`.lm`/`.rm`/`.pm` share (`pdfPtPerCol`), regardless of how many digits the
/// number itself has (a 3-digit number landed at the IDENTICAL x as a 1-digit one at
/// the same `.pc`/`.po` pair -- LEFT-anchored, not right-anchored or centred on the
/// string itself). Confirmed relative to `.po`, not absolute from the page edge: two
/// independent `.po` values both fit the SAME formula exactly once `.po` is added in; a
/// plain `N * 7.2pt` (ignoring `.po`) does not.
///
/// `.pc 0` (WSFORMAT.WS's own text: "If the column specified is 0, then the page
/// number is centered between the margins in effect") and `.pc` NEVER DECLARED AT ALL
/// produced the IDENTICAL position in every probe -- "unset" and "0" are the SAME
/// internal state. But the manual's own "centered between the margins" claim does NOT
/// hold in this install/driver as measured: `.rm 40` with `.pc 0` landed at the
/// IDENTICAL x as `.pc 0` at this install's own default `.rm` -- no dependency on `.rm`
/// at all, twice confirmed. Measured bytes beat manual prose (`printedLeft`'s own
/// precedent, same doctrine): the "0/unset" case resolves to this FIXED measured
/// column instead of a dynamically computed lm/rm midpoint. Fit from two independent
/// `.po` values (7.0 exactly, 20.0 exactly) with zero decipoint residual either way --
/// not a guess, and not (yet) traced to a WSCHANGE factory constant, so it may be THIS
/// install's own customisation the same way its `.po` 7.0 (vs the manual's 8.0) is;
/// flagged, not hidden. Port of ctrl-kd's `_AUTO_PAGENO_DEFAULT_COL`.
let autoPagenoDefaultCol = 33.5

/// Left edge (points) of the automatic page number's text, from `.po`/`.pc` -- see
/// `autoPagenoDefaultCol`'s doc comment for the formula's own measurement. `pcCol` 0 or
/// unset (both measured identical) uses the fixed default; an explicit non-zero `.pc N`
/// overrides it.
///
/// `poCols` IS THIS PAGE'S OWN PRINT OFFSET, and the document's default is only the
/// fallback for a caller with no page in hand. The number rides the running foot's own
/// left origin -- the same `.po`/`.poe`/`.poo` state `emitPDF`'s per-page `pageLeft`
/// resolves -- never the document's opening `.po`. Reading the document default here put
/// the number at the WRONG COLUMN on every page whose own offset differs, which this
/// corpus produces three separate ways, all measured against real WS7:
///
///   * `.poe`/`.poo` (an even/odd offset pair). `sawyer/REF/ADVANCE.DOT` `.poo 5.6"` ->
///     637.2pt, `GALLEYS.DOT` `.poo 5.8125"` -> 652.3pt (predicted 652.5, a 2-decipoint
///     driver residual -- its own running head carries the same 0.2pt),
///     `REF/BOOKLET.HOW` 644.4pt odd / 248.4pt even, `REF/BOOKLET.RJS` and its
///     byte-identical twin `REF/-HOW-TO.RJS` 651.6pt odd / 255.6pt even -- every one
///     EXACTLY `(po + pc - 1) * 7.2` once the page's own parity offset is used. This
///     engine drew all five at 291.6pt, the Letter-portrait `.po 8` default. All five
///     are also `.pr or=l` landscape, which is a coincidence of who in this corpus uses
///     `.poe`/`.poo` and NOT part of the rule: the number is not centred on the sheet,
///     and nothing about it reads the sheet's width.
///   * a MID-DOCUMENT `.po`. `sawyer/REF/FONTS.REF` alternates `.po.2i`/`.po.7i`: WS7
///     numbers its pages 248.4 / 284.4 / 248.4 / 284.4... page by page, while the
///     document default (`.po.2i`) alone gives 248.4 throughout.
///   * a `.po` the document's OPENING state never sees at all. `sawyer/REF/REFORM.DOT`'s
///     own `.po 1i` lands past block 0, so the document default stays at WordStar's
///     `.po 8`; WS7 numbers its one page at 306.0pt, which is `.po 1i` = 10 columns.
///
/// Port of ctrl-kd's `_auto_pageno_x_pt`.
func autoPageNumberXPt(_ doc: Document, poCols: Double? = nil) -> Double {
    let po = poCols ?? doc.page?.poCols ?? 8.0  // WS7 manual's own default page offset --
                                        // `ParseWS.swift`'s `defaultPoCols`, private there
    let pcRaw = doc.page?.pcCol
    let pc = (pcRaw != nil && pcRaw != 0) ? Double(pcRaw!) : autoPagenoDefaultCol
    return (po + pc - 1) * pdfPtPerCol
}

/// Top-of-text offset in points for printed mode: the bottom edge of WS7's reserved
/// TOP-MARGIN zone (`.mt`, lines at 6 LPI -> 12pt each; the default `.mt 3` = 36pt). Print
/// streams (no `page` meta) keep the fixed 36pt — their own top-margin blanks are in the
/// data (minus the machine-margin strip in `docToPagelines`). Clamped inside the page so
/// garbage `.mt` from a misdetected binary degrades to an ugly page, never an absurd
/// coordinate space. Deliberately measured against the FIXED `PDFMetrics.lead` (not
/// `printedLead(doc)`) — this is a page-geometry clamp, not a
/// line-spacing one.
///
/// Mechanism U (ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round,
/// commit 26169cd): `.hm` is NEVER added on top of `.mt`, matching the WS7 manual's own
/// dot-command reference (already quoted in this codebase for the symmetric `.mb`/`.fm`
/// case). This function used to add `.hm` (2 lines, 24pt) whenever `.mt` was left at its
/// document default — see the "INCLUDES `.hm`" history below, all of it measured ONLY
/// against `ws7-prints/v1`/`v2`, both captured through Robert J. Sawyer's own
/// WSCHANGE-customized `WS.EXE` (the SAME install mechanisms S and T already found
/// responsible for the `.po` and auto-leading contaminations). A `PRISTINE.EXE` (factory,
/// no WSCHANGE) recapture of 5 default-`.mt` documents (OCAPTAIN/BOXES/SAWYER/LYING/
/// WARPRAYR) settles it: every one measures its first real content line at EXACTLY `.mt`
/// alone (36pt) + that line's own entering lead, zero residual — 36 (`.mt` alone) + 12
/// (OCAPTAIN/BOXES/SAWYER's own 12pt entering lead) = 48.0pt exactly; 36 + 16 (LYING/
/// WARPRAYR's 16pt Title style, at `AUTO_LEAD_FACTOR` 1.0) = 52.0pt exactly. `ws7-prints/v1`'s
/// uniform ~24-27pt EXTRA gap on the SAME 5 documents is Sawyer's own `.hm`-adds-to-`.mt`
/// customization, not stock WS7's — invisible to this codebase's own `pcl` tier verdicts
/// because it is a UNIFORM per-page offset that a per-page median-dy calibration silently
/// absorbs, the same masking mechanism already named for `.po`, now confirmed on the
/// vertical axis too.
///
/// ---- history below, superseded by the above ----
///
/// NO LONGER SPECIAL-CASED FOR HEADERED DOCUMENTS (round 26 wave 3, ctrl-kd's
/// `fidelity_gate.py` Finding A — reversing the headerless scoping this function used to
/// carry). A genuine WS7 capture WITH a real `.h1` header (-README, ws7-prints/v1) contradicts
/// the WS4-era reading this function's SCOPED TO HEADERLESS DOCUMENTS reasoning rested on:
/// -README's OWN header prints starting page 2 (page 1 has none — WordStar suppresses a
/// running head on the document's first page) at PCL baseline y=35.7pt (`.mt` alone, matching
/// `runningOps`'s OWN placement, unaffected by this function), but the BODY text on those SAME
/// headered pages starts at y=71.7pt — byte-for-byte the SAME offset the headerless corpus
/// measures ((.mt 3 + .hm 2)*12 + 12pt baseline = 72pt, 0.3pt residual). Mechanism U (above)
/// now confirms the ORIGINAL WS4-era reading was right about STOCK WS7 all along — `.hm` is
/// always within `.mt`, headered document or not — and -README's own body-vs-header split
/// (used at the time to argue the opposite) was itself measuring the Sawyer-install `.hm`
/// contamination on the BODY side while its header (`runningOps`, a separate computation)
/// happened to stay correct.
///
/// PREVIEW.WS (ws7-prints/v1) is unaffected by this change either way: it declares its OWN
/// `.mt` explicitly (`mtSource == .file`, 4.98 lines — a WSFORMAT-style non-integer `.mt`,
/// likely typed as a decimal inch value), and both its `ws7-prints/v1` and `v3` captures
/// already match `.mt` ALONE (round(4.98*12)=60, +12+12 for this headerless document's own
/// two leading blank lines at `AUTO_LEAD_FACTOR` 1.0 = 84pt vs the `v3` measured 83.7pt,
/// 0.3pt residual — the same decipoint-rounding gap every other oracle here shows).
///
/// WSCHANGE's factory-defaults table (Installing and Customizing, WS7 manual, p.2-46/2-45)
/// independently confirms the `.mt` default used here: "Top margin ... 0.50"". Port of
/// Python's `_printed_top` (pdf.py, ctrl-kd 2.0.0/round 26 wave 3, refined same day on
/// PREVIEW.WS evidence, and again by mechanism U, commit 26169cd).
func printedTop(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.topPrinted }
    let pageHeight = resolvedPrintedPageHeight(doc)
    let reserve = page.mtLines
    return max(0, min(roundHalfToEven(reserve * 12), pageHeight - PDFMetrics.lead))
}

/// Bottom-of-page reserve for `layoutPrintedPages`'s FOOTNOTE area (never the endnote
/// continuation — endnotes are never queued through this function's own pagination, they
/// simply continue this area's sequential flow and inherit its position for free), in
/// points — Finding 2 (b26-print-fidelity-2). Port of Python's `_printed_notes_reserve_pt`.
///
/// The area used to be flow-appended right after the body (whatever y the body happened to
/// end at), correct only when the body already fills the page (LYING.WS, every page) — on a
/// short page (-SCREEN.WS, a 1-page doc whose body ends mid-page) that put the area
/// mid-page, colliding with the WORDSTAR.PIX image; real WS7 prints it at the physical
/// bottom.
///
/// Originally measured against TWO WS7 captures (ws7-prints/v1), both at every
/// page-geometry default (`.mb` 8 lines): -SCREEN.pcl's footnote line "1. Footnote" at
/// y=708pt (dash rule at 684pt) and LYING.pcl's "1.Did not take the prize." also at y=708pt
/// (dash rule also 684pt — LYING's page is full, so its flow-appended position and this
/// anchor coincide). Both landed on 84pt = (`.mb` - 1) * 12 = 7 lines, alongside a
/// (since-fixed) 3-line header model (`areaSize`/`renderArea`) that inserted an extra
/// leading blank neither real capture ever printed.
///
/// Mechanism U (ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round,
/// commit 26169cd, same install already found responsible for the `.po`/leading/top-margin
/// contaminations — mechanisms S, T, and this function's own sibling `printedTop`).
/// Re-deriving BOTH real captures from scratch with the header-count fix landed (2 lines:
/// rule then blank, not 3):
///
/// -SCREEN (`ws7-prints/v1`, Sawyer): a genuinely SHORT page, so this anchor's own reserve
/// governs directly. Solving with the 2-line header: reserve = 96.0pt = `.mb * 12` EXACTLY
/// (8 lines, no adjustment at all) — zero residual. The old `-1` was compensating for the
/// wrong (3-line) header model, not a real per-install customization.
///
/// LYING (`ws7-prints/v3`, pristine): a FULL page, so this document's own natural
/// (un-anchored) flow places it — once `printedTop`'s fix lands, the body's last real
/// content line plus the 2-line header's 24pt plus the text's own 12pt entering lead
/// matches pristine's real measurement with ZERO residual via PURE SEQUENTIAL FLOW; this
/// document's own oracle only bounds the reserve from BELOW (`reserve >= 120`, its own
/// 3-line area).
///
/// So: `-SCREEN` (Sawyer) needs EXACTLY 96pt (`.mb * 12`); `LYING` (pristine) needs AT
/// LEAST 120pt (`(.mb + 2) * 12`) to avoid wrongly overriding its own already-correct
/// natural position — but see the 2026-09-07 correction below: that `>= 120` bound itself
/// carried a 12pt derivation error, and the real value is 108pt.
///
/// 2026-09-07 correction (ctrl-kd commit 135a14a, `-SCREEN` recapture): the reasoning
/// above compared `target_first` against `natural_y` (648, LYING's own last BODY CONTENT
/// line) instead of the code's actual comparison point, `bodyY` (`648 + 12 = 660`, the
/// position of the NEXT line after the body — what `layoutPrintedPages`'s own override
/// arithmetic uses). That is a 12pt/one-line error in the DERIVATION, not in the code's
/// own arithmetic, and it inflated the reserve requirement to `>= 120` when the code's
/// real gate only requires `>= 108`.
///
/// The error was invisible until now because -SCREEN's own footnote/endnote block was
/// believed genuinely ABSENT from the `ws7-prints/v3` PRISTINE.EXE capture (that corpus's
/// own README finding #3) — it was actually just TRUNCATED at the document's embedded
/// Inset picture (corpus commit 2be7569, 2026-09-06), so -SCREEN could never corroborate
/// or refute this constant either way until the recapture. The complete capture measures:
/// dash rule at V=660.0pt, footnote line ("1." then, tab-separated, "Footnote") at
/// V=684.0pt, endnote line ("(1)" then "Endnote") at V=708.0pt. -SCREEN's body ends at
/// V=434.1pt — nowhere near the anchor — so, being a genuinely short page, this anchor
/// governs the reserve DIRECTLY (not just a lower bound, unlike LYING): solving
/// `792 - reserve - (areaLen-1)*12 = 660` with `areaLen=3` (rule, blank, text) gives
/// `reserve = 108.0pt = (.mb + 1) * 12`, not `120pt = (.mb + defaultHmLines) * 12`.
///
/// Re-checked against LYING with `reserve = 108`: `override = targetFirst - bodyY =
/// (792 - 108 - 24) - 660 = 0`, and the code's own gate is `if override > 0`, so `0`
/// still does NOT engage the anchor — LYING's already-correct pure-sequential-flow
/// position (684.0pt, matching pristine with zero residual) is completely undisturbed.
/// So `108` is not a compromise between two installs' needs; it is the exact value both
/// real stock captures independently agree on: `-SCREEN` governs it directly (short
/// page), LYING is consistent with it as a boundary case (full page, override lands at
/// exactly 0 rather than needing to stay strictly negative).
///
/// CONFIRMED under stock, n=2 (`-SCREEN` direct + `LYING` boundary-consistent),
/// superseding the prior n=1 judgment call: `108pt = (.mb + 1) * 12`, not
/// `(.mb + defaultHmLines) * 12`. The `.hm`-symmetry reading that motivated `+2` doesn't
/// hold; the footnote area's real cushion above the physical bottom margin is one line,
/// not `defaultHmLines` lines — `printedTop`'s own `.hm` finding (top of page) and this
/// reserve (bottom of page) are NOT mirror images after all, contra the earlier note here.
/// Port of Python's `_printed_notes_reserve_pt` (ctrl-kd commit 135a14a).
func printedNotesReservePt(_ doc: Document) -> Double {
    guard let page = doc.page else { return 108.0 }  // print streams: no `.mb` to read;
                                                      // the measured default constant
    return max(0.0, (page.mbLines + 1) * 12.0)
}

/// Baseline-to-baseline distance in points for printed mode. Port of Python's
/// `_printed_lead` (pdf.py, ctrl-kd 1.3.0): `.lh` is 1/48in units, a point is 1/72in ->
/// `lh48 * 1.5`. Default `.lh 8` IS the 12pt lead this emitter always used. Print streams
/// (no `page` meta) keep the fixed lead.
/// Only the DEFAULT: `.lh` is stateful and a line that was set at a different leading carries
/// its own (`Line.lead48` -> `PageLine.lead`), which `pageStream` honours per line. This is
/// what a line WITHOUT one falls back to, and what page CAPACITY is still computed at (see
/// `printedCap`).
func printedLead(_ doc: Document) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.lead) }
    return leadPt(page.lh48) ?? Double(PDFMetrics.lead)
}

/// `[block index in doc.blocks: lead48]` for every printed content block (`.para` kind,
/// headings included — `.pagebreak`/`.condpage` sentinels carry no lines and are
/// skipped), giving RTF's own per-paragraph `\sl` (`rtfBlockLead48`) the SAME resolved
/// leading this file's own PDF page-building already uses per PHYSICAL line
/// (`docToPagelines`'s printed branch: `.lh` override, else a paragraph STYLE's own
/// `lineHeightVMI`-derived leading via `styleLeadPt`/`enteringLeadPt`, else a WS5+
/// font-block's own proportional size via `fontLeadPt`, else the document default).
/// Ruling 2026-08-26 (mirrored from ctrl-kd ebc2939, register row, b33 field notes N2):
/// Printed/Native RTF previously emitted ONE flat `\sl` for the whole document — a 16pt
/// Title/Author style (WS7 style vmi -2/auto, real leading 1.2x16=19.2pt) was squeezed
/// onto the document's plain 12pt body lead, clipping in Word/TextEdit. This ports the
/// READ side of that same per-line algorithm to block granularity — RTF's `\sl` is a
/// PARAGRAPH property with no per-line control word, so a block collapses to its own
/// FIRST REAL (non-blank) physical line's resolved value, exactly the "ceiling of what
/// RTF can express per paragraph" `rtfBlockLead48`'s own doc comment already named (a
/// `.lh` change strictly mid-paragraph was already out of scope there, unchanged here).
/// `fontLeadState` is still threaded across EVERY physical line of the WHOLE document in
/// source order, blank lines and non-first real lines included, even though only one
/// resolved value per block is kept — an inline font-block change inside a later line
/// must still update the carried state exactly as `docToPagelines` computes it, or a
/// LATER block's own first line would resolve against a stale governing size. No
/// existing PDF consumer of `leadPt`/`styleLeadPt`/`enteringLeadPt`/`fontLeadPt` is
/// touched — this only calls them, read-only, in the same per-line order and under the
/// same gates they already use. Port of `pdf.resolved_printed_leads_48`.
func resolvedPrintedLeads48(_ doc: Document) -> [Int: Double] {
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.blocks.contains { $0.lhAuto } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    let defaultLeadPt = printedLead(doc)
    var out: [Int: Double] = [:]
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak || block.kind == .condpage { continue }
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        var firstLineOfBlock = true
        var resolvedPt: Double? = nil
        for line in block.lines {
            let isBlank = !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
            var ownLead = leadPt(line.lead48)
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            if !isBlank { firstLineOfBlock = false }
            // planning #256: a block's own paragraph-style leading, when it
            // has one, governs OUTRIGHT -- no longer gated on whether this
            // line's own carried `.lh` happens to be unset/default (see
            // `styleLeadPt`'s own doc comment for the -HOW-TO.RJS evidence: a
            // stale, document-wide `.lh` must never outrank the style its own
            // block actually carries).
            if let styleLead {
                ownLead = styleLead
            }
            if ownLead == nil, fontLeadOk, block.lhAuto {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            if resolvedPt == nil, !isBlank {
                resolvedPt = ownLead ?? defaultLeadPt
            }
        }
        if resolvedPt == nil {
            // every line in this block is blank (a pure spacer block) — no REAL line
            // ever set resolvedPt above. Fall back to the block's own first line, raw
            // (no entering-floor: there is no real glyph here to protect from clipping
            // into whatever came before), same `raw: true` doctrine as a blank line
            // mid-block.
            if let line = block.lines.first {
                var ownLead = leadPt(line.lead48)
                let styleLead = styleLeadPt(block, doc, raw: true)
                // planning #256: a block's own paragraph-style leading, when it
                // has one, governs OUTRIGHT -- no longer gated on whether this
                // line's own carried `.lh` happens to be unset/default (see
                // `styleLeadPt`'s own doc comment for the -HOW-TO.RJS evidence: a
                // stale, document-wide `.lh` must never outrank the style its own
                // block actually carries).
                if let styleLead {
                    ownLead = styleLead
                }
                if ownLead == nil, fontLeadOk, block.lhAuto {
                    ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                         state: &fontLeadState)
                }
                resolvedPt = ownLead ?? defaultLeadPt
            } else {
                resolvedPt = defaultLeadPt
            }
        }
        out[bi] = resolvedPt! / 1.5      // points -> 1/48in, inverse of leadPt
    }
    return out
}

/// The `.sr` sub/superscript roll for printed mode, in points — ONE document-wide value
/// (b24 round 17, RULINGS-LEDGER row 3, register C22). Port of Python's `_printed_roll_pt`.
/// Not stateful per-line like `.lh`: `.sr` re-selects mid-document have no evidence behind
/// per-position tracking the way `.lh`'s own archive banner example does — the ruling
/// itself only asks that the file's OWN roll finally be read at all (previously byte-
/// identical across `.sr 0`/`.sr 40`/absent). Default 3 (WSFORMAT's own stated `.sr`
/// default, 3/48in) whenever the file never sets it, converted the same way every other
/// 1/48in value is (round 6: 1/48in = 1.5pt).
func printedRollPt(_ doc: Document) -> Double {
    (doc.formatting.subSuperRoll48 ?? 3.0) * 1.5
}

/// Print columns (10 CPI) -> points: 72pt/in / 10 col/in = 7.2pt/col — the SAME unit
/// `.lm`/`.rm`/`.pm`/`.po` all share, and the exact value `MAX_COLS`'s own line-wrap math
/// already derives from (size 12 * 0.6 == 7.2 at the default size).
let pdfPtPerCol = 7.2

/// planning #257 (sawyer/REF/-HOW-TO.RJS pages 10-12): a typed leading-space run
/// before proportional text with NO `.pm` backing it (`lineOpsPrinted`'s own
/// `pmActive`/`columnIndent`) still needs its OWN width — not `pdfPtPerCol` (that
/// branch is for a `.pm`-governed run, WARPRAYR), and not this Base14 Helvetica
/// substitute's own AFM space glyph either (0.278em — correct for an ORDINARY
/// inter-word space inside running text, measured: "PRINTING UNBOUND"'s own single
/// space landed within 0.1pt of it — but too narrow for a run of many consecutive
/// typed ones). MEASURED directly against two independent blocks of the same real
/// WS7 capture (ws7-prints/v4/sawyer__REF__-HOW-TO_EXT_RJS.pcl, both Univers/Helv
/// 10pt, `.pm 0"` in force): the banner heading's 20/22/18/30-space lines (left
/// 21.6pt, WS7 x 88.8/95.5/82.0/122.4) and the later `IfException` block's 12-space
/// lines (left 417.6pt, WS7 x 457.9) both solve to the SAME flat 0.336em/pt ratio to
/// within 0.1pt (decipoint rounding) — e.g. 21.6 + 20*3.36 = 88.8 exactly, 417.6 +
/// 12*3.36 = 457.92 vs 457.9. Applied UNSCALED (no `faceTz` factor: that scale lands
/// the face's AVERAGE character on its own HMI grid, and a space is not average —
/// scaling it the same amount overshot every one of these lines). Untested outside
/// a Helv/Univers substitution — no other proportional face types a literal indent
/// with no `.pm` anywhere in the current corpus. Port of ctrl-kd's
/// `_TYPED_INDENT_SPACE_EM`.
///
/// `public` so a consumer that must reproduce this measure — Soft Return.app's own Printed
/// facsimile, whose leading-indent run has to land where this puts it — reads the number
/// rather than keeping a second copy of it, the same reason `graphicChars` and
/// `symbolReverse` are public.
public let typedIndentSpaceEM = 0.336

/// First-line indent in points from `.pm` — b24 round 17 (RULINGS-LEDGER row 5/7), mirrors
/// `rtfPMFiTwips` (round 6), relative to li=0: Printed PDF has no per-block `.lm`/`.rm`
/// margin of its own yet (that gap is Printed RTF's own ledger row 8, a SEPARATE item),
/// so the baseline this indent sits against is the document's own left edge — the same
/// li=0 an unstyled/WS4 Printed RTF paragraph already gets from the SAME round 6 code.
/// `nil` when the block never set `.pm`. Port of Python's `_printed_pm_fi_pt`.
///
/// The rule itself — `.pm`'s absolute column, reduced by whatever the author already
/// typed, clamped at zero — is `pmFirstLineIndentCols` (EmitterRules.swift), where
/// planning #264 item 2 moved it so Printed RTF asks the same question. Its doc comment
/// carries the WARPRAYR.WS (planning #202) and -HOW-TO.RJS (planning #257) evidence.
/// This function is only that answer in points.
///
/// `.pf` GATE (planning #270 item 39 / triage Q6, 2026-09-14; port of ctrl-kd). A
/// paragraph margin reaches the PRINTED page only through print-time realignment.
/// MicroPro's own file-format reference says so in one sentence — `.PF`: "When OFF,
/// paragraphs are not realigned... Paragraphs are aligned using the left, right, and
/// paragraph margins currently in effect" — and the corpus agrees: with realignment off
/// WordStar prints the stored physical lines verbatim, whatever indentation the author
/// typed included, and `.lm`/`.rm`/`.pm` are EDIT-time state that already spent itself
/// at typing time (which is exactly why this module has never applied `.lm` to a
/// printed line either).
///
/// MEASURED, `sawyer/MACROS/HOLYMAC/-HOLYMAC.WS` (v4 PRISTINE capture, no `.pf`
/// anywhere in the file, `.pm4` in force): its pages 223, 258 and 293 each open with a
/// line real WS7 prints at the plain left edge (x 72.0pt, and 77.5pt for the page-293
/// footnote's own superscript) while this engine indented all three by `.pm`'s 3
/// columns, +21.60pt, 16 divergences. Every other `.pm`-bearing block in the HOLYMAC
/// set (`7MAC1`/`7MAC2`/`7MAC3`, clean) opens on a BLANK line, so the indent never
/// showed and none of them was evidence either way. No document in the corpus prints a
/// `.pm` first-line indent with `.pf` off. `dis` is treated as not-on: it realigns only
/// when merge data is substituted, which never happens here.
// MARK: - `.pf on`: print-time re-wrap
//
// Planning #270 item 37 (Jon's ruling 2026-09-13, triage Q5: "Yes, support it."),
// MicroPro's own definition (WSFORMAT.TXT, the `.PF` row): "Paragraph realignment while
// printing... When ON, subsequent paragraphs are realigned as they are printed... using
// the left, right, and paragraph margins currently in effect."
//
// WHY A DOCUMENT NEEDS THIS AT ALL. WordStar's EDITOR is a character screen: it wraps at
// a COLUMN COUNT whatever face the text is set in, and stores the break it chose. The
// PRINTER is not: it wraps at the real measure, in the real fonts, at print time. With
// `.pf on` the two can disagree, and the paper is the one that wins. Two measured cases,
// both from the v4 PRISTINE captures:
//
//   `sawyer/REF/REFORM.DOT` — Courier, `.rm 6.5"` at print time but `.rm 5.0"` in the
//   editor (its own `.if 1=0` block, true while editing and false while printing). The
//   file stores "...in editing, but" + soft return + "another to occur during printing";
//   real WS7 prints ONE 63-character line ending "...another to occur". 65 columns is the
//   measure; "during" needs 7 more.
//
//   `sawyer/PRINT.TST` — the OPPOSITE case, and the regression test that matters: all 94
//   of its soft-wrapped lines print EXACTLY as stored ("custom-"/"ized", "de-"/"fault",
//   "docu-"/"ment", "professional-"/"looking"), because nothing changed between edit time
//   and print time.
//
// ONE MEASURE for both: the sum of each span's own printed advance, `spanPitch` —
// WordStar's own HMI for a WS5+ font block, the `.cw`-derived cell otherwise — so a
// Courier paragraph measures in 7.2pt columns and an 11pt Helv one in 5.52pt cells, from
// one formula. (Real per-glyph widths are what the PRINTER used, and decide both captured
// cases identically; `spanPitch` is chosen because it is what this module then DRAWS
// with, so a re-wrapped line can never overflow the right edge its own justification pins
// to.)
//
// SCOPE, deliberately narrow, every bound measurable: only `.pf on` (`off`/`dis`/absent
// keep the stored lines, and ZERO archive documents say `dis`); only a paragraph WordStar
// ITSELF broke — two or more physical lines joined by soft returns, a single stored line
// is never re-broken; only `left`/`justify` blocks with word wrap on (`.aw on`); and never
// a paragraph carrying a tab, a print control, a picture placeholder or an index entry,
// because those spans encode a POSITION. A note reference is deliberately NOT in that
// list: it travels with the word it follows.
//
// A paragraph ends at a HARD return. Soft returns inside it are re-flowable, and an
// ACTIVE SOFT HYPHEN at one of them is discretionary (`Line.softHyphen`): it disappears
// with the break it was made for and is printed again when the break is still needed. A
// TYPED hyphen is text — also a break point, and it survives the break.
//
// Port of ctrl-kd's `pdf.pf_rewrapped_lines`, byte-identical.

/// The 1-based reference indices (an `fnref` span's own text) that point at a COMMENT.
///
/// `symmetricBlocks` numbers every note kind through ONE counter in document order and
/// `refPairs` keeps that order, so the index a mark carries IS the position in
/// `doc.notes`. Port of `pdf._comment_mark_indices`.
func commentMarkIndices(_ doc: Document) -> Set<Int> {
    var out: Set<Int> = []
    for (i, n) in doc.notes.enumerated() where n.kind == .comment { out.insert(i + 1) }
    return out
}

/// `lines` with every COMMENT reference mark removed.
///
/// A WordStar comment PRINTS NOTHING — not the comment, not a number standing in for it.
/// `..` (and its `.IG` spelling) is a non-printing comment LINE: MicroPro's own reference
/// gives it no paper presence at all, and real WS7 confirms it — `sawyer/REF/REFORM.DOT`
/// carries three `..` lines and the v4 PRISTINE capture has no mark, no digit and no
/// shift where they sit. The ^ON comment BLOCK is a different construct and is equally
/// silent on paper (ruling 2026-08-06: "printed ALWAYS silent"), so both origins are
/// dropped here by the same rule.
///
/// The mark is still IR: Modern anchors RTF's `\*\annotation` and HTML's backlink at
/// exactly this position, and Show Invisibles needs somewhere to draw the comment icon.
/// Only the PRINTED surfaces lose it — and they lose it HERE, before anything measures or
/// re-wraps, rather than at the drawing step: a mark that survives into the measure is
/// three columns of width WordStar never spent, and under `.pf on` its characters fuse
/// with the neighbouring text into a word ("123") that then gets printed.
///
/// The identical array back when the document has no comment at all, which is nearly
/// every document, so nothing else can move. Port of `pdf._drop_comment_marks`.
func dropCommentMarks(_ doc: Document, _ lines: [Line]) -> [Line] {
    guard doc.notes.contains(where: { $0.kind == .comment }) else { return lines }
    let marks = commentMarkIndices(doc)
    if marks.isEmpty { return lines }
    func keep(_ s: Span) -> Bool {
        guard s.styles.contains(.fnref), let k = Int(s.text) else { return true }
        return !marks.contains(k)
    }
    var touched = false
    for line in lines where line.spans.contains(where: { !keep($0) }) {
        touched = true
        break
    }
    if !touched { return lines }
    return lines.map { line -> Line in
        let kept = line.spans.filter(keep)
        if kept.count == line.spans.count { return line }
        var copy = line
        copy.spans = kept
        return copy
    }
}

/// True when this span PLACES something rather than merely carrying text — the one
/// reason `.pf on` leaves a paragraph exactly as WordStar stored it.
func pfPositional(_ span: Span) -> Bool {
    span.tabHMI != nil || span.pctlHMI != nil || span.pix != nil || span.pcl != nil
        || span.indexEntry || span.text.contains("\t" as Character)
}

/// The leading run of pure whitespace of one stored physical line, split out of the
/// first span if it only STARTS with one, and the rest. WordStar re-stamps `.lm`/`.pm`
/// as real spaces on every line it writes, so this IS the paragraph's indent, read off
/// the file rather than recomputed from the dot commands.
private func pfLeadingIndent(_ line: Line) -> (indent: [Span], rest: [Span]) {
    var head: [Span] = []
    var rest = line.spans
    while let first = rest.first, first.text.trimmed().isEmpty {
        head.append(first)
        rest.removeFirst()
    }
    if var first = rest.first {
        let stripped = String(first.text.drop(while: { $0 == " " }))
        if stripped.count != first.text.count {
            var lead = first
            lead.text = String(first.text.prefix(first.text.count - stripped.count))
            head.append(lead)
            first.text = stripped
            rest[0] = first
        }
    }
    return (head, rest)
}

/// One character of the paragraph being re-wrapped: the character itself and the span it
/// came out of (its text ignored), so the re-wrapped rows can be rebuilt with every
/// attribute intact and coalesced back to runs.
private struct PFCell {
    var ch: Character
    var span: Span
    /// Which span of the paragraph this character came out of, or `nil` when the span is
    /// ordinary text. The re-wrap works a character at a time, and two REFERENCE MARKS
    /// that end up side by side must not fuse back into one span the way two runs of
    /// plain text legitimately do — the text of a mark is a pointer, not letters
    /// (`coalesceSpans` states the same rule; here the marks have already been reduced to
    /// characters, so the source index is what tells two of them apart).
    var source: Int?
}

private func pfSameAttrs(_ a: Span, _ b: Span) -> Bool {
    a.styles == b.styles && a.font == b.font && a.colour == b.colour
        && a.pctlHMI == b.pctlHMI && a.pix == b.pix && a.pcl == b.pcl
        && a.tabHMI == b.tabHMI && a.tabLeader == b.tabLeader
        && a.indexEntry == b.indexEntry
}

/// One paragraph's physical lines, re-wrapped to `measure` points. `nil` when the
/// paragraph is one this mechanism leaves alone (see the SCOPE note above) — the caller
/// then keeps the stored lines.
private func pfRewrapParagraph(_ para: [Line], measure: Double, fonts: [FontChange],
                               size: Int, cache: inout [Int?: Double]) -> [Line]? {
    guard para.count >= 2 else { return nil }
    for line in para where line.spans.contains(where: pfPositional) { return nil }

    func pitch(_ span: Span) -> Double {
        if let w = cache[span.font] { return w }
        let w = spanPitch(spanFontEntry(span.font, fonts), size)
        cache[span.font] = w
        return w
    }
    func width(_ cells: [PFCell]) -> Double {
        cells.reduce(0.0) { $0 + pitch($1.span) }
    }
    var markSeq = 0
    func cells(_ spans: [Span]) -> [PFCell] {
        spans.flatMap { sp -> [PFCell] in
            var src: Int?
            if sp.styles.contains(.fnref) { markSeq += 1; src = markSeq }
            return sp.text.map { PFCell(ch: $0, span: sp, source: src) }
        }
    }

    let firstIndent = pfLeadingIndent(para[0]).indent
    let contIndent = pfLeadingIndent(para[1]).indent
    let firstW = width(cells(firstIndent))
    let contW = width(cells(contIndent))
    guard measure - max(firstW, contW) > 0 else { return nil }

    // The paragraph's text as one run, joined the way `mergedLines` joins a soft-wrapped
    // run. `dis` collects the DISCRETIONARY hyphen positions: a break there prints a '-'
    // and no break there prints nothing, which is why the character itself is not in the
    // run.
    var chars: [PFCell] = []
    var dis: Set<Int> = []
    for (k, line) in para.enumerated() {
        var run = cells(pfLeadingIndent(line).rest)
        if k < para.count - 1 {
            if line.softHyphen, run.last?.ch == "-" {
                run.removeLast()
                dis.insert(chars.count + run.count)
            } else if let last = run.last, last.ch != " ", last.ch != "-" {
                run.append(PFCell(ch: " ", span: last.span, source: nil))
            }
        }
        chars.append(contentsOf: run)
    }
    guard !chars.isEmpty else { return nil }

    // TOKENS: (leading spaces, body, what ends it). A break may be taken between any two
    // tokens; the spaces that separate them stay on the line that is finished, exactly
    // where WordStar itself stores them.
    enum PFEnd { case plain, typed, discretionary }
    var tokens: [(gap: [PFCell], body: [PFCell], end: PFEnd)] = []
    var i = 0
    while i < chars.count {
        var gap: [PFCell] = []
        while i < chars.count, chars[i].ch == " " { gap.append(chars[i]); i += 1 }
        var body: [PFCell] = []
        var end = PFEnd.plain
        while i < chars.count {
            if dis.contains(i), !body.isEmpty { end = .discretionary; break }
            if chars[i].ch == " " { break }
            body.append(chars[i])
            i += 1
            if body[body.count - 1].ch == "-" { end = .typed; break }   // TYPED hyphen
        }
        tokens.append((gap, body, end))
    }

    let hyphW = pitch(chars[chars.count - 1].span)
    var rows: [[PFCell]] = []
    var cur: [PFCell] = []
    var curW = firstW
    var prevEnd = PFEnd.plain
    for token in tokens {
        let gw = width(token.gap), bw = width(token.body)
        // a token a break may follow with a PRINTED hyphen has to leave room for it
        let need = gw + bw + (token.end == .discretionary ? hyphW : 0.0)
        if !cur.isEmpty, curW + need > measure + 1e-6 {
            if prevEnd == .discretionary {
                cur.append(PFCell(ch: "-", span: cur[cur.count - 1].span, source: nil))
            }
            cur.append(contentsOf: token.gap)
            rows.append(cur)
            cur = token.body
            curW = contW + bw
        } else {
            cur.append(contentsOf: token.gap)
            cur.append(contentsOf: token.body)
            curW += gw + bw
        }
        prevEnd = token.end
    }
    if !cur.isEmpty { rows.append(cur) }

    var out: [Line] = []
    for (k, row) in rows.enumerated() {
        var spans: [Span] = []
        var prevSource: Int?
        for cell in row {
            if let last = spans.last, pfSameAttrs(last, cell.span), cell.source == prevSource {
                spans[spans.count - 1].text.append(cell.ch)
            } else {
                var fresh = cell.span
                fresh.text = String(cell.ch)
                spans.append(fresh)
            }
            prevSource = cell.source
        }
        let src = k == 0 ? para[0] : para[1]
        out.append(Line(spans: coalesceSpans((k == 0 ? firstIndent : contIndent) + spans),
                        soft: k < rows.count - 1 || para[para.count - 1].soft,
                        lead48: src.lead48, kerning: src.kerning, poCols: src.poCols,
                        roll48: src.roll48, poeCols: src.poeCols, pooCols: src.pooCols))
    }
    return out
}

/// `block.lines` as WordStar PRINTS them: unchanged unless the block is under `.pf on`,
/// in which case every paragraph WordStar itself broke is re-joined and re-wrapped to the
/// margins and fonts in force. See the note above for the rule, the two measured
/// documents and the scope.
///
/// Returns the block's OWN array when this pass re-decided nothing, so a caller can
/// assert "nothing moved" identically for a `.pf on` block WordStar left alone and for
/// every block in every other document.
public func pfRewrappedLines(_ doc: Document, _ block: Block) -> [Line] {
    let base = dropCommentMarks(doc, block.lines)
    guard block.printReformat == "on", block.kind == .para, block.wrap,
          block.align == .left || block.align == .justify else { return base }
    let measure = (block.rightMargin ?? 65.0) * pdfPtPerCol
    let size = printedSize(doc)
    var cache: [Int?: Double] = [:]
    var out: [Line] = []
    var moved = false
    var i = 0
    let lines = base
    while i < lines.count {
        var j = i
        while j < lines.count - 1, lines[j].soft, !lines[j].spans.isEmpty { j += 1 }
        let para = Array(lines[i...j])
        i = j + 1
        let rewrapped = para.allSatisfy { !$0.spans.isEmpty }
            ? pfRewrapParagraph(para, measure: measure, fonts: doc.fonts, size: size,
                                cache: &cache)
            : nil
        if let rewrapped {
            moved = true
            out.append(contentsOf: rewrapped)
        } else {
            out.append(contentsOf: para)
        }
    }
    return moved ? out : base
}

func printedPMFiPt(_ block: Block) -> Double? {
    guard block.printReformat == "on" else { return nil }
    guard let cols = pmFirstLineIndentCols(block) else { return nil }
    return cols * pdfPtPerCol
}

/// `(sb, sa)` in points from WordTsar's own `.psa`/`.psb` extensions — b24 round 17
/// (RULINGS-LEDGER row 5/7), mirrors `rtfDocSpacingTwips` (round 6) exactly, converted to
/// points via the document's own DEFAULT leading (the same quantity `PageLine.lead`
/// already carries) instead of twips. `(nil, nil)` when neither command was ever seen.
/// Port of Python's `_printed_doc_spacing_pt`.
func printedDocSpacingPt(_ doc: Document) -> (sb: Double?, sa: Double?) {
    guard doc.spaceBeforeLines != nil || doc.spaceAfterLines != nil else { return (nil, nil) }
    let leadPt = printedLead(doc)
    let sb = doc.spaceBeforeLines.map { $0 * leadPt }
    let sa = doc.spaceAfterLines.map { $0 * leadPt }
    return (sb, sa)
}

/// Type size in points for printed mode, from `.cw`: character width in 1/120in units,
/// and Courier advances 0.6em, so a pitch of cw/120in per character IS a
/// `(cw*72/120)/0.6 = cw*1.0` point font. The default `.cw 12` (10 CPI pica) IS the 12pt
/// this emitter always used; `.cw 10` is 12 CPI elite at 10pt. Rounded to whole points
/// (the `Tf` operator is written as an integer, as it always has been), floored at 1.
/// Print streams keep the fixed `SIZE`. Port of Python's `_printed_size` (pdf.py, ctrl-kd
/// 2.0.0).
public func printedSize(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.size }
    let cw = page.cw120
    return cw > 0 ? max(1, roundHalfToEven(cw)) : PDFMetrics.size
}

/// Left edge of text in points for printed mode, from `.po`: "the number of print
/// columns from the left edge of the paper to the left margin of text. The current
/// setting of character width (.CW) determines the actual amount of indentation" — but
/// real WS7 output contradicts that clause: PCL captures keep `.po` at a FIXED
/// 7.2pt/column at BOTH 10cpi and 12cpi (dx experiment 2026-08-20: ESC&aH = 576dp for
/// `.po 8` at either pitch), matching `pdfPtPerCol` exactly as `.lm`/`.rm`/`.pm` already
/// do. Measured bytes beat manual prose. The default `.po 8` (the WS7 manual's ".8 inch"
/// at 10 CPI) lands at 57.6pt — NOT the old fixed 72pt `MARGIN`, which was this emitter's
/// guess, not WordStar's. Print streams keep `MARGIN`: their offset spaces, where a
/// driver emitted them, are in-band. Clamped inside the page for garbage `.po` from
/// misdetected binaries. Port of Python's `_printed_left` (pdf.py, ctrl-kd 2.0.0).
///
/// This is the DOCUMENT DEFAULT — the file's first `.po`, exactly like `printedLead`'s
/// document default. A line whose own `.po` differs (`Line.poCols`, register b31 —
/// LJ6DTP.WS moves `.po` to 2.5" for its page-4 checkerboard) overrides this at layout
/// time in `resolvePrintedBody`/`resolvePlainBody` (`PageLine.left`), the same `.lh`-
/// stateful shape `PageLine.lead` already carries.
func printedLeft(_ doc: Document, size: Int) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.margin) }
    return resolveLeftPt(page.poCols, size: size)
}

/// `.po` print columns -> left edge in points, clamped inside the page — the conversion
/// `printedLeft` (the document DEFAULT) and a line's own override (`Line.poCols`, stateful
/// like `.lh`; register b31) both need, factored out so a line that never overrides `.po`
/// resolves IDENTICALLY to the document default it would otherwise have inherited. Port of
/// Python's `_resolve_left_pt`.
func resolveLeftPt(_ poCols: Double, size: Int) -> Double {
    let left = poCols * pdfPtPerCol
    return max(0.0, min(left, Double(PDFMetrics.pageWidth) - Double(size) * 0.6))
}

/// Total lines the footnote area occupies FOR PAGE-CAPACITY PURPOSES (how many body lines
/// this paginator admits onto a page before the footnote area needs room, and this area's
/// own share of `footnoteCeiling`'s budget): the fixed 3-line header (blank / 20-dash
/// separator / blank — VMI 240 = one blank line at 6 LPI) plus each entry's own lines plus
/// one blank line between entries (VMI 240 "between notes"). 0 when there's nothing to
/// show at all. Port of Python's `_area_size`.
///
/// DELIBERATELY NOT the same count `renderArea` visually draws (mechanism U, ctrl-kd
/// `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round, commit 26169cd) — see
/// that function's own doc comment for why the RENDERED area is 2 lines, not 3. Reducing
/// this function to 2 as well breaks LYING's own page break (real WS7, both installs, ends
/// page 1 at the same line this engine already does at every count from 3 up; reducing to
/// 2 lets one MORE body line fit before the cap, which real WS7 does not do) — so the
/// capacity/pagination budget for this header is 3 lines even though only 2 of them are
/// literally drawn. Empirically necessary, not fully explained.
private func areaSize(_ entries: [[PageLine]]) -> Int {
    guard !entries.isEmpty else { return 0 }
    return 3 + entries.reduce(0) { $0 + $1.count } + (entries.count - 1)
}

/// The admitted area as page lines: separator / blank, then the entries with one blank
/// between. Port of Python's `_render_area`.
///
/// UPDATED (mechanism U, ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE
/// round, commit 26169cd): the separator directly follows the body's own last line, with
/// NO leading blank — confirmed on `ws7-prints/v1`/-SCREEN.pcl and `ws7-prints/v3`/LYING.pcl,
/// both landing the rule exactly one lead after the body's own last line, not two. The
/// header this function draws is now 2 lines, not 3 — but `areaSize`'s own page-CAPACITY
/// cost stays 3 (see that function's own doc comment): the rendered and budgeted line
/// counts DELIBERATELY diverge.
private func renderArea(_ entries: [[PageLine]]) -> [PageLine] {
    guard !entries.isEmpty else { return [] }
    var out: [PageLine] = [[Span(text: String(repeating: "-", count: 20))], []]
    for (k, e) in entries.enumerated() {
        if k > 0 { out.append([]) }
        out.append(contentsOf: e)
    }
    return out
}

/// Max lines the footnote area may occupy on a page where `bodyLen` line units are already
/// committed. Always bounded by the room actually left on the page (`cap - bodyLen`) —
/// entries can never push the total past cap. Additionally bounded by
/// `cap - footnoteFloor` on every page EXCEPT the one holding the document's last line of
/// regular text, where the floor's protection lifts (the WS5 manual's stated exception).
///
/// `bodyLen` (b26 round 26 wave 3, ctrl-kd's `fidelity_gate.py` Unit A) can now be
/// FRACTIONAL — a styled body line costs its own lead as a fraction of the document
/// default, see `layoutPrintedPages`'s `lineCost` — but the footnote AREA itself is still
/// whole LINES (its own text carries no per-style leading; `areaSize`/`admitFootnotes`
/// count it that way). Floored, never rounded, so a fractional line of room already spent
/// by the body never gets credited as a whole line the footnote area can use. The tiny
/// epsilon guards against float accumulation (many fractional per-line costs summed)
/// landing just under a whole number that should round up, not down. Port of Python's
/// `_footnote_ceiling`.
private func footnoteCeiling(cap: Int, bodyLen: Double, isTerminal: Bool) -> Int {
    let room = Int(Double(cap) - bodyLen + 1e-9)
    return isTerminal ? room : min(room, cap - footnoteFloor)
}

/// Move whole/partial note-chunks from the FRONT of `queue` into `entries` (mutating both)
/// until the footnote area would exceed `ceiling` lines. A chunk that only partly fits is
/// split: the part that fits joins `entries`, and the remainder stays queued behind a
/// `...Continued...` marker, ready to resume on a later page's area — this is the only
/// place a note's text is ever cut. Port of Python's `_admit_footnotes`, including its
/// hang guard: splitting costs the NEXT page one `...Continued...` line, so a split only
/// makes net progress when at least 2 lines fit; when the page cannot even manage that AND
/// the area is still empty, two lines are forced through — a page that overflows slightly
/// beats a hang or lost text.
// internal (not private): the progress invariant is unit-tested.
internal func admitFootnotes(
    _ entries: inout [[PageLine]], _ queue: inout [QueuedNote], ceiling: Int
) {
    while !queue.isEmpty {
        var chunk: [PageLine] = []
        if queue[0].needsContinuedMarker {
            chunk.append([Span(text: footerContinuedLine)])
        }
        chunk.append(contentsOf: queue[0].remaining)
        let overhead = entries.isEmpty ? 3 : 1      // inter-note blank, or the area's
                                                    // header if it's empty so far
        let room = ceiling - areaSize(entries) - overhead
        if room >= chunk.count {
            entries.append(chunk)
            queue.removeFirst()
            continue
        }
        let split: Int
        if room >= 2 {
            split = room
        } else if entries.isEmpty {
            split = min(chunk.count, 2)             // forced progress, per the doc above
        } else {
            break                                   // defer: next page starts empty
        }
        entries.append(Array(chunk.prefix(split)))
        // However many of `split` came from the synthetic `...Continued...` line (at most
        // one, always first) don't count against the note's own remaining text.
        let markerTaken = queue[0].needsContinuedMarker ? min(split, 1) : 0
        queue[0].remaining.removeFirst(min(split - markerTaken, queue[0].remaining.count))
        if queue[0].remaining.isEmpty {
            queue.removeFirst()
        } else {
            queue[0].needsContinuedMarker = true
        }
        break
    }
}

/// IR -> pages, WordStar's own way: verbatim body lines, a page-bottom footer for footnotes
/// and annotations that grows to fit (splitting across pages when it can't, per
/// `admitFootnotes`), and endnotes collected with no heading at the very end. See the
/// section comment above for the rule numbering this follows.
private func layoutPrintedPages(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [Page] {
    let items = resolvePrintedBody(doc, pixResults: pixResults, pictures: pictures,
                                   sentenceSpacing: sentenceSpacing)
    let width = PDFMetrics.maxCols
    let capacity = printedCap(doc)
    // b24 round 22 (closing round 19's documented scope cut): an embedded image
    // PageLine (built by `resolvePrintedBody`) costs its own height in
    // default-lead-sized lines against this paginator's line-count budget — the
    // image's vertical footprint enters the page-capacity model the same way `.lh`
    // does in `resolvePlainBody`'s points model, just quantised to this algorithm's
    // own line unit. Port of Python's `_line_cost` (ceil(h_pt / default_lead)).
    //
    // This algorithm's whole budget (`capacity`, `areaSize`, the footnote ceiling) is
    // denominated in LINE units at the document's DEFAULT lead — correct for the
    // footnote area itself (its own text carries no per-style leading), wrong for BODY
    // text once a WS7 paragraph STYLE governs a line's real leading (b26 round 26 wave
    // 3, ctrl-kd's `fidelity_gate.py` Unit A). A body line now costs its OWN lead as a
    // FRACTION of the default lead — 1.0 for a line at the document default
    // (byte-identical pagination for every document that never varies leading, which is
    // every document this algorithm's fixed-`1` cost was ever measured against), more
    // or less than 1.0 for a line whose style set a bigger or smaller lead — the same
    // `own_lead / default_lead` conversion `resolvePlainBody`'s already point-based main
    // loop uses (its points budget is the identical quantity in points; this keeps that
    // page's true physical capacity while staying in this function's existing line
    // unit, so `areaSize`/`admitFootnotes`/`footnoteCeiling` need no change of their
    // own). MEASURED against LYING.pcl: this document undercounted every page (55
    // nominal lines actually spending 777.6pt of a 648pt budget — 129.6pt, 10.8
    // default-lead lines, of real overflow per page) before this fix; the gate went
    // from 3 engine pages (WS7: 4) to matching.
    //
    // An image PageLine's `.lead` (round 26 wave 3, fidelity_gate.py Finding A/C) is
    // ALREADY the RESERVED PLACEHOLDER block's height in points — `pixReservedAdvance`,
    // computed once at `resolvePrintedBody` build time — not the raster's own continuous
    // pixel height, so it takes the identical `ownLead / defaultLead` conversion every
    // other line here does; a prior version of this function re-derived a cost from the
    // raster's raw height directly (`ceil(heightPt / defaultLead)`), double-guessing a
    // number `resolvePrintedBody` had already resolved correctly and, for a pix tag with
    // few or no reserved blank lines, wildly OVER-costing the page-capacity budget
    // relative to what `pageStream` actually spends drawing it — the leading suspect
    // behind -SCREEN's spurious page-2 overflow before this fix.
    let defaultLead = printedLead(doc)
    func lineCost(_ line: PageLine) -> Double {
        let ownLead = line.lead ?? defaultLead
        return ownLead / defaultLead
    }
    // Finding 2 bottom-anchor geometry (see `printedNotesReservePt`): constant for the
    // whole document, computed once.
    let notesTop = Double(printedTop(doc))
    let notesPageH = Double(resolvedPageHeight(doc, printed: true))
    let notesReserve = printedNotesReservePt(doc)
    // Finding 4 (b26 visual pass): see `notesMarkerPadCols` — computed ONCE for the
    // footnote/annotation area below AND the endnote section at the end of this
    // function, so a document whose footnotes and endnotes land on the same page
    // agree on one shared column.
    let padCols = notesMarkerPadCols(doc)

    var queue: [QueuedNote] = []
    var pages: [Page] = []
    var idx = 0
    // round 26 wave 3 (fidelity_gate.py Finding C): the LAST page built below, and how
    // many `capacity`-units of it are already spent — Python's `_paginate_printed_notes`
    // return value, threaded here instead since this port folds that helper and
    // `_endnote_pages` into one function. Consulted only by the endnote section at the
    // very end; every page-append site below keeps it current. Initialised to `capacity`
    // (Python's `last_page_cost = cap`) so an empty `items` stream (no `pages` at all)
    // reports "no room", matching `pages.last == nil` deciding the same thing either way.
    var lastPageCost = Double(capacity)
    // round 27 (b28 note 6): whether the LAST page appended below ends with a footnote
    // AREA or with plain BODY text. The endnote section at the end needs the distinction
    // to decide whether a blank line precedes the first endnote — see its own comment for
    // the WS7 measurements. Python's `_paginate_printed_notes` third return value.
    var lastPageHasArea = false

    // planning #227 follow-up (2026-09-12): A COLUMN GROUP SHARES ONE TOP, and this
    // paginator has to know it too. `docToPagelines`'s own main loop already charges a
    // columnar group's shared non-columnar PREFIX against every column of the group
    // except the first (its `colCut()`); this function — the paginator every
    // NOTE-BEARING document takes instead — had no such notion, so a later column kept
    // a whole page's capacity while starting BELOW the page top, and ran off the sheet.
    //
    // MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/PRINT.TST`
    // page 2 — `.co3, .20"` under a "Paragraph Styles" prefix. WS7 opens all three
    // columns at 288.0pt and, with a text bottom of 720.0pt (`.mt 1"`/`.mb 1"`/
    // `.pl 11"`) at a 12pt lead, gives each 36 rows: column 1 holds 15 and ends on its
    // own `.cb`, column 2 holds 21 and ends on `.cc 19` (12 rows left, fewer than the
    // 19 asked for), column 3 holds 23. This engine gave column 2 the full 54-row page,
    // never reached the `.cc` at all, and placed 51 lines from y 286 down to y 884 —
    // past the text bottom, past the sheet (792), through the page number at 756 —
    // leaving column 3 empty.
    //
    // `colCapacity()` is this function's own capacity in its own LINE units: the page's
    // `capacity` for column 0 (which pays the prefix line by line out of the same
    // budget) and `capacity - prefix` for every column after it, which starts below
    // that prefix. That is exactly `(text bottom - column top) / lead`, per column.
    var colGroupCols = 1             // `.co n` of the region the open page is in
    var colGroupIndex = 0            // which column of the group the open page is
    var colOffset = 0.0              // the group's shared prefix, in line units
    func itemCols(_ line: PageLine) -> Int? {
        guard let bi = line.bi, bi >= 0, bi < doc.blocks.count else { return nil }
        return doc.blocks[bi].columns ?? 1
    }
    func colCapacity() -> Double {
        Double(capacity) - (colGroupIndex > 0 ? colOffset : 0.0)
    }
    func advanceColumn() {
        guard colGroupCols > 1 else { return }
        colGroupIndex += 1
        if colGroupIndex >= colGroupCols {
            colGroupCols = 1
            colGroupIndex = 0
            colOffset = 0.0
        }
    }

    // The same running per-block line tally `docToPagelines`' paginator keeps, for the
    // same consumer: `checkpointsByPage` asks each page HOW FAR INTO THE DOCUMENT it had
    // read when it closed, and a page built here never answered — so a document with
    // footnotes lost its own `.op`/`.pn`/`.pg` and took the seeded "numbering ON"
    // default. `LYING.WS` numbered all three pages where real WS7 numbers none (research:
    // "Why real WS7 prints no page number on some documents", 2026-09-15). Counted off
    // the BODY only: a footnote area's lines are the emitter's own, and the reference
    // that pulled them down here was already counted on the body line carrying it.
    var readTally: [Int: Int] = [:]
    var readPos: PageReadPos?

    // Python's `last_idx`: the last stream item carrying real ink (an image, or any
    // non-blank text). The page that admits it holds the document's last line of regular
    // text, so `footnoteCeiling`'s floor protection lifts there (the WS5 manual's stated
    // exception) and the area may grow to the whole remaining page.
    var lastIdx = -1
    for (i, item) in items.enumerated() {
        if case .line(let line, _) = item,
           line.image != nil
               || line.spans.contains(where: { !$0.text.allSatisfy { $0 == " " || $0 == "\t" } }) {
            lastIdx = i
        }
    }

    while idx < items.count {
        var body: [PageLine] = []
        var bodyLen = 0.0                        // in line units, images may cost > 1;
                                                  // a styled body line may cost a fraction
        var entries: [[PageLine]] = []           // note chunks ADMITTED to this page's area
        var isTerminal = false
        // Carry-over first: whatever a previous page's area couldn't hold gets this
        // page's area before any new reference queues behind it.
        admitFootnotes(&entries, &queue,
                       ceiling: footnoteCeiling(cap: capacity, bodyLen: bodyLen,
                                                isTerminal: isTerminal))
        bodyLoop: while idx < items.count {
            switch items[idx] {
            case .pageBreak:
                idx += 1
                break bodyLoop
            case .condPage(let n):
                // `.cp n` — break ONLY if fewer than n lines remain. Measured on WordStar 4
                // (2026-08-03): exactly n remaining is enough room and does NOT break, so
                // the test is strictly `remaining < n`. An empty page never breaks: that
                // would emit a blank sheet, which is what `.cp` exists to avoid.
                idx += 1
                if colCapacity() - bodyLen < Double(n), !body.isEmpty {
                    break bodyLoop
                }
            case .line(let line, let due):
                if let lc = itemCols(line), lc > 1, colGroupCols == 1 {
                    // the group starts HERE: whatever this page has already spent is
                    // the prefix every column of it shares
                    colGroupCols = lc
                    colGroupIndex = 0
                    colOffset = bodyLen
                } else if itemCols(line) == 1, colGroupCols > 1 {
                    // a line LEAVING the region releases the shared prefix
                    colGroupCols = 1
                    colGroupIndex = 0
                    colOffset = 0.0
                }
                let cost = lineCost(line)
                // Port of Python's `if body and body_len + cost + _area_size(entries) >
                // cap` admission: a body line is admitted while it fits ABOVE the area
                // already committed — which `admitFootnotes` grew incrementally, splitting
                // notes when they couldn't finish, so a reference line whose notes only
                // PARTLY fit is still admitted and its overflow continues on the next
                // page's area (rule 4). The old projected-full-footer check here demanded
                // the whole outstanding queue fit unsplit and pushed such a line to the
                // next page — its first counterexample was a 20-annotation document
                // (2026-08-18). The 3-line body floor needs no arm of its own: the
                // non-terminal ceiling caps the area at `capacity - footnoteFloor`, so the
                // first three line units always fit. The `body.isEmpty` arm is round 22's
                // over-tall admit guard: an image taller than the whole page must still be
                // admitted somewhere or this loop would never advance — a slightly
                // overflowing page beats a hang or lost content (the same doctrine
                // `fitFooter` documents).
                if !body.isEmpty, bodyLen + cost + Double(areaSize(entries)) > colCapacity() {
                    break bodyLoop
                }
                body.append(line)
                if let bi = line.bi {
                    readTally[bi, default: 0] += 1
                    readPos = PageReadPos(bi: bi, count: readTally[bi]!)
                }
                bodyLen += cost
                if idx == lastIdx { isTerminal = true }
                idx += 1
                for ref in due {
                    queue.append(QueuedNote(
                        remaining: footerEntryLines(ref.note, doc: doc, index: ref.index,
                                                    width: width, padCols: padCols,
                                                    sentenceSpacing: sentenceSpacing),
                        needsContinuedMarker: false))
                }
                admitFootnotes(&entries, &queue,
                               ceiling: footnoteCeiling(cap: capacity, bodyLen: bodyLen,
                                                        isTerminal: isTerminal))
            }
        }

        // This paginator never replays `hfEvents` (unchanged since before this port,
        // matching Python's dedicated `_paginate_printed_notes`, also untouched): every
        // page instead carries the document's FINAL-state headers/footers, the same
        // fallback `runningOps` applies when a page's own dict is empty.
        var area = renderArea(entries)
        if !entries.isEmpty {
            // Bottom-anchor (Finding 2): the area's FIRST line (the 3-line header's
            // leading blank) gets an overridden `.lead` that lands it exactly
            // `notesReserve` above the page bottom, counting up through the area's own
            // remaining lines — rather than wherever the body's sequential flow happened
            // to leave off. `bodyY` is the body's own last baseline (top-down points):
            // `lineCost` makes `ownLead / defaultLead` exact, so `bodyLen * defaultLead`
            // is the TRUE point advance the body already spent, not an approximation.
            // APPLIED whenever it pushes the area DOWN AT ALL (`override > 0`) -- NOT
            // gated on exceeding one whole `defaultLead` gap (planning #202 residuals
            // round, ctrl-kd 1017391): that gate's own rationale -- "a full page
            // (LYING.WS) already lands within a line of the target on its own, so this
            // is a no-op there, byte-identical" -- assumed the flow path's own ordinary
            // single-blank-line gap could only ever UNDERSHOOT the target when
            // `override` came out under one lead. LYING is a full page and its own real
            // WS7 capture (LYING.pcl) measures its footnote line at y=708pt, but the
            // flow path's plain `defaultLead` gap OVERSHOOTS the anchor by 4.8pt
            // (natural 676.8pt vs the anchor's own 672.0pt target, `override` a genuine
            // 7.2pt -- less than one 12pt lead, so the old `> defaultLead` gate skipped
            // it and left the 4.8pt overshoot standing) -- the assumption held for every
            // oracle it was checked against, but was never actually correct for a SMALL
            // positive override, only ever coincidentally close enough not to be caught.
            // A negative or zero override (the body's own flow already reached or passed
            // the target) is still left alone -- "never move backward into the body" is
            // unchanged.
            let bodyY = notesTop + bodyLen * defaultLead
            let targetFirst = notesPageH - notesReserve - Double(area.count - 1) * defaultLead
            let override = targetFirst - bodyY
            if override > 0 {
                area[0].lead = override
            }
        }
        var closed = Page(body + area, headers: doc.headers, footers: doc.footers)
        closed.readPos = readPos
        pages.append(closed)
        advanceColumn()
        lastPageCost = bodyLen + Double(areaSize(entries))
        lastPageHasArea = !entries.isEmpty
    }

    // Rule 5: whatever the last body page's bottom footer couldn't hold prints at the TOP
    // of its own fresh page(s) instead of waiting for a "next page" that doesn't exist.
    // Rendered through the SAME `admitFootnotes`/`renderArea` pair as the in-page area
    // (Python renders every area through `_render_area`), so the header here is the same
    // 3 lines — blank / 20-dash rule / blank — not the 1-line separator the retired
    // `fitFooter(leadingBlank: false)` path used to emit (shape divergence from the
    // oracle, closed 2026-08-18). The ceiling is the whole page: bodyLen 0, and terminal
    // — these pages ARE the manual's stated exception.
    //
    // PROGRESS GUARD. This loop's termination used to depend entirely on its helper
    // consuming at least one queued line per call, with nothing checking that it did. On
    // 2026-07-31 a regression in the helper made it consume nothing at `capacity == 3`;
    // this loop then appended a page per pass forever, reached 15.7 GB, and stalled the
    // whole machine for 2h40m -- no crash, no OOM kill, just unbounded growth.
    //
    // A layout loop whose exit depends on a helper making progress must verify that the
    // progress happened. Two invariants, in priority order: no text is ever lost, and the
    // layout always terminates. So when a pass consumes nothing, flush everything still
    // queued onto one page and stop -- that page overflows, which is strictly better than
    // dropping text or hanging.
    while !queue.isEmpty {
        let linesBefore = queue.reduce(0) { $0 + $1.remaining.count }
        var entries: [[PageLine]] = []
        admitFootnotes(&entries, &queue,
                       ceiling: footnoteCeiling(cap: capacity, bodyLen: 0, isTerminal: true))
        let page = renderArea(entries)
        let linesAfter = queue.reduce(0) { $0 + $1.remaining.count }

        if linesAfter >= linesBefore {
            // No progress. Emit the page we just built, then flush the rest verbatim so
            // nothing is lost, and leave the loop. No Python oracle covers this
            // Swift-only safety branch (see the PROGRESS GUARD comment above); treating
            // it as "no room" (`lastPageCost = capacity`) is a deliberate, conservative
            // judgment call so endnotes never try to continue onto a page that just
            // absorbed a raw overflow dump.
            if !page.isEmpty { pages.append(Page(page, headers: doc.headers, footers: doc.footers)) }
            var flushed: [PageLine] = []
            for entry in queue {
                if !flushed.isEmpty { flushed.append([]) }
                flushed.append(contentsOf: entry.remaining)
            }
            queue.removeAll()
            if !flushed.isEmpty {
                pages.append(Page(flushed, headers: doc.headers, footers: doc.footers))
            }
            lastPageCost = Double(capacity)
            lastPageHasArea = true
            break
        }
        pages.append(Page(page, headers: doc.headers, footers: doc.footers))
        lastPageCost = Double(areaSize(entries))
        lastPageHasArea = true
    }

    // Endnotes: the true end of the document, no heading, no separator — plain pagination,
    // one blank line between entries (the same vertical rhythm as the footer area), nothing
    // before the first.
    //
    // CONTINUES the last body/footnote page when it has room (round 26 wave 3,
    // fidelity_gate.py Finding C), instead of always forcing a fresh one — not a fresh
    // 3-line area header, since this is one more entry in the SAME note area, not a new
    // section. The previous unconditional-fresh-page version put "(1) Endnote" alone on an
    // otherwise-near-empty page 2, the actual cause of -SCREEN's 2-page overflow (WS7: 1).
    // A page with NO room left (`lastPageCost >= capacity`, the overwhelmingly common
    // multi-page case) is untouched: endnotes start fresh exactly as before.
    //
    // `lastPageHasArea` (round 27, b28 note 6) decides whether a blank line precedes the
    // FIRST endnote, and it is NOT unconditional. WS7's note face is 12-point, so ONE note
    // line advances 120 decipoints — the 2026-08-20 measurement that put a blank line here
    // read the natural 240dp two-line advance as "24pt, one blank line" and generalised it.
    // Re-measured 2026-08-23 against both WS7 captures (jon_vault WordStar/ws7-prints/v1/):
    //
    //   -SCREEN.pcl  "1. Footnote" V=7080 -> "(1) Endnote"  V=7320 = 240dp
    //                = ONE BLANK LINE, endnotes joining a FOOTNOTE AREA.
    //   TESTING.pcl  last body line     V=3765 -> "(1)This..." V=3885 = 120dp
    //                = NO BLANK LINE, endnotes following BODY TEXT.
    //   TESTING.pcl  endnote (1) V=3885 -> (2) V=4125 = 240dp = one blank line BETWEEN
    //                entries (the `if i > 0` gap below, unchanged).
    //
    // So the leading gap belongs only when the last page ends with a footnote area — it is
    // one more entry joining that area. Following plain body text the endnotes butt
    // straight up against it, which is what Jon reported in the b27 review. Port of
    // Python's `_endnote_pages` plus its `_doc_to_pagelines` call site (which page this
    // replaces vs. appends).
    // #228 (research/2026-09-08_trailing-pa-rule.md): a trailing `.pa` -- the
    // document's own LAST block -- closes the current page (WordStar's own
    // "force a new page" signal) even when nothing real follows it before
    // EOF and no visible extra page ever opens (`doc.paEofBlankAfter` false,
    // the ordinary case). Forcing `lastPageCost` to `capacity` here makes
    // `canContinue` below correctly refuse to merge the document's endnotes
    // onto page 1's remaining room, matching WordStar's own documented
    // default endnote placement (WSFORMAT.TXT: no `.PE` -> "endnotes will be
    // printed at the very end of the document ... starting a new page if
    // they don't fit what's left"). Confirmed against sawyer/DISPLAY.WS and
    // sawyer/REF/NOTES.TST: both end in a bare `.pa` (nothing after) and
    // both need their real endnote content on ITS OWN fresh page, not
    // merged with the footnote already on page 1.
    if doc.blocks.last?.kind == .pagebreak {
        lastPageCost = Double(capacity)
    }
    let endnotes = doc.notes.enumerated().filter { $0.element.kind == .endnote }
    if !endnotes.isEmpty {
        var lines: [PageLine] = []
        for (i, entry) in endnotes.enumerated() {
            if i > 0 { lines.append([]) }
            lines.append(contentsOf: endnoteEntryLines(entry.element, doc: doc,
                                                       index: entry.offset, width: width,
                                                       padCols: padCols,
                                                       sentenceSpacing: sentenceSpacing))
        }
        // Python's `last_page and last_page_cost < cap`: `last_page` must be a REAL,
        // non-empty page (an empty Python list is falsy) as well as under-capacity.
        let canContinue = lastPageCost < Double(capacity)
            && (pages.last.map { !$0.isEmpty } ?? false)
        // #228: a FRESH endnote page (not a continuation of the body's own
        // last page) has no `.bi`-carrying line of its own -- every line
        // here comes from `endnoteEntryLines`, never a `.bi`-tagged
        // PageLine -- so the auto-page-number lookup at render time has
        // nothing to resolve against. `explicitBreakBI` (the document's
        // own highest block index -- "wherever the document's own state
        // was by its own end") stands in, the same fallback the trailing-
        // `.pa` blank page (`layoutPrintedPagesPlain`) already uses.
        // Confirmed against sawyer/DISPLAY.WS: WS7's own page 2 (the
        // endnote, on its own page once the trailing-`.pa` continuation
        // fix above stops it merging with page 1) carries the automatic
        // page number "2".
        let lastBI = doc.blocks.count - 1
        var page: Page
        var room: Double
        if canContinue, let last = pages.last {
            page = last
            room = Double(capacity) - lastPageCost
            if lastPageHasArea {            // see the WS7 measurements above
                lines = [[]] + lines
            }
        } else {
            page = Page([], headers: doc.headers, footers: doc.footers, explicitBreakBI: lastBI)
            room = Double(capacity)
        }
        var endPages: [Page] = []
        for line in lines {
            if room < 1 {
                endPages.append(page)
                page = Page([], headers: doc.headers, footers: doc.footers, explicitBreakBI: lastBI)
                room = Double(capacity)
            }
            page.append(line)
            room -= 1
        }
        if !page.isEmpty {
            endPages.append(page)
        }
        if canContinue, !endPages.isEmpty {
            pages.removeLast()
            pages.append(contentsOf: endPages)
        } else {
            pages.append(contentsOf: endPages)
        }
    }

    return pages
}

/// An embedded pix image's `(widthPt, heightPt)` — the ONE sizing rule every PDF path
/// shares (b24 round 22 factored it out of `resolvePlainBody` so the Modern and
/// notes-pagination paths size identically to the plain Printed path): the print-options
/// record's physical size when the `.PIX` file carries one, else fit-to-text-measure at
/// the source aspect ratio; either way capped at `maxWPt` (the requesting path's own
/// text measure). Port of Python's `_pix_dims_pt`.
func pixDimsPt(_ r: PixResult, maxWPt: Double) -> (w: Double, h: Double) {
    var wPt: Double
    var hPt: Double
    if let widthIn = r.widthIn, let heightIn = r.heightIn, widthIn != 0, heightIn != 0 {
        wPt = widthIn * 72.0
        hPt = heightIn * 72.0
    } else {
        wPt = maxWPt
        hPt = r.gcols.map { $0 != 0 ? wPt * (Double(r.grows ?? 0) / Double($0)) : 0.0 } ?? 0.0
    }
    if wPt > maxWPt, wPt > 0 {
        let scale = maxWPt / wPt
        wPt *= scale
        hPt *= scale
    }
    return (wPt, hPt)
}

/// `(reservedLeadPt, nBlankConsumed)` for an embedded pix tag whose own physical line
/// already ended at `blkLines[startIdx - 1]`.
///
/// WordStar's own INSET convention: the author reserves the picture's print-time footprint
/// as blank PHYSICAL LINES in the source (the tag's own line plus however many blank lines
/// follow it, contiguously, in the same block) — print time overlays the picture on exactly
/// that reserved block, which is why the block's LINE COUNT governs the vertical advance,
/// not the picture's own continuous pixel height (the two rarely match to the point;
/// INSET's editor-time placeholder was drawn by eye).
///
/// Measured 2026-08-20 against -README.WS/-README.pcl (`fidelity_gate.py` Finding A): the
/// `.PIX` tag is followed by 7 contiguous blank lines before "COMPLETE WORDSTAR..." — 8
/// lines * 12pt = 96pt reserved. WS7's own first-body baseline (167.7pt) matches
/// `printedTop`'s 60pt + 96pt + this line's own 12pt lead to a 0.3pt residual, the same
/// decipoint-rounding-sized gap as the rest of the confirmed corpus. Using the raster's raw
/// height instead (73.9pt, from the print-options record) under-reserves by >20pt here and
/// cascades into every following line's position. The SAME `ceil(hPt/lead)` raw-height cost
/// also fed the notes paginator's page-capacity budget before this fix (round 26, Finding
/// A/C) — `layoutPrintedPages`'s `lineCost` now reads this same reserved `.lead` instead.
/// Port of Python's `_pix_reserved_advance`.
func pixReservedAdvance(_ blkLines: [Line], startIdx: Int, ownLeadPt: Double)
    -> (reserved: Double, nBlank: Int)
{
    var n = 0
    while startIdx + n < blkLines.count, blkLines[startIdx + n].text().trimmed().isEmpty {
        n += 1
    }
    return (Double(1 + n) * ownLeadPt, n)
}

/// `(pixIndex, wPt, hPt)` when `spans` is exactly ONE resolved, decoded pix placeholder
/// and nothing else with real text — the round-19 substitution rule, shared verbatim by
/// every PDF path since b24 round 22: text content is never silently dropped, so a
/// (hypothetical) pix tag sharing its line with other prose renders as the ordinary
/// placeholder text instead. `nil` when no substitution applies (off / miss / shared
/// line); the caller keeps the placeholder text unchanged. Port of Python's
/// `_spans_pix_substitution` (which reads the `pixN` style tag; the Swift IR carries the
/// same value structurally as `Span.pix`/`SemanticRun.pix`, hence the tuple shape here).
func spansPixSubstitution(_ spans: [(text: String, pix: Int?)],
                          pixMap: [Int: PixResult], maxWPt: Double)
    -> (pixIndex: Int, wPt: Double, hPt: Double)?
{
    var pixIdx: Int?
    for sp in spans {
        if let tag = sp.pix {
            if pixIdx != nil { return nil }        // >1 tag on one line: bail
            pixIdx = tag
        } else if !sp.text.trimmed().isEmpty {
            return nil                             // real prose shares the line
        }
    }
    guard let pixIdx, let r = pixMap[pixIdx], r.ok else { return nil }
    let (wPt, hPt) = pixDimsPt(r, maxWPt: maxWPt)
    return (pixIdx, wPt, hPt)
}

/// The Printed text measure in points, for pix fit/cap sizing: Printed PDF has no
/// per-block `.rm` resolved in points anywhere in this emitter (physical lines are
/// pre-wrapped by the parser at authoring time), so the right inset is mirrored from the
/// left one — a disclosed approximation (round 19), same class as RTF's borrowed TOC
/// page numbers. Port of Python's `_printed_text_width_pt` (round 22 factored it out,
/// shared with the notes-pagination path).
func printedTextWidthPt(_ doc: Document) -> Double {
    let size = printedSize(doc)
    let left = printedLeft(doc, size: size)
    let pageWPt = (doc.page?.pwIn ?? 8.5) * 72.0
    return max(72.0, pageWPt - 2 * left)
}

/// A physical `Line` with no non-whitespace span text — the same test
/// `resolvePlainBody`'s own per-line loop already applies inline (its `isBlank`),
/// factored out here so `ws4SpacingBlankIndices` can classify a whole block's lines
/// before that loop runs. Port of Python's `_is_blank_line`.
private func isBlankLine(_ line: Line) -> Bool {
    !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
}

/// Finding 1 (b26 visual pass, a private WS4 paper corpus, never entering this repo):
/// `[blockIndex: Set(line indices into that block's own .lines)]` — every blank
/// `Line` that is this document's OWN double-spacing idiom, not authored content.
/// ONLY CALLED for a `variant == .ws4` document — see the call site's own comment for
/// why this never even runs for anything else.
///
/// WordStar's OWN manual gives this a physical story, already quoted elsewhere in
/// this module (`ParseWS.swift`'s `defaultLs`/`enteringLeadPt`): "when you use line
/// spacing, the blank lines become part of the file" (WS7 manual, "Line Spacing") —
/// `.LS`'s blank lines are not computed at print time, they are literal `Line`s the
/// file itself carries. A classified blank stays exactly that: a literal `Line`, its
/// own ordinary `PageLine` at its own natural (single) lead — `resolvePlainBody` does
/// NOT fold it into a neighbour's lead. An early version of this fix DID fold
/// (collapsing a double-spaced pair into one `PageLine` at 2x lead) and it broke on
/// irregular paragraph lengths: real WS7's own page-top baseline cycles through THREE
/// distinct phases 12pt apart (measured: a WS4 source with long, regular paragraphs
/// holds one phase for every interior page, 71.7pt; a WS4 source built mostly from
/// short dialogue paragraphs cycles 71.7/83.7/95.7pt depending on whether the page
/// break happened to land on odd or even raw-line parity) — collapsing every pair
/// into a single 2x-lead unit can only ever reproduce ONE of those phases, because it
/// throws away exactly the raw single-line parity information a page break's real
/// position depends on. Classifying which blanks are spacing (this function) but
/// leaving them as literal RAW `PageLine`s preserves that parity; only their
/// ELIGIBILITY to force a page break changes (`layoutPrintedPagesPlain`'s own
/// pagination loop, via each `PageLine`'s own `ws4Spacing` flag).
///
/// Classified PER BLOCK first (a block is WordStar's own paragraph unit), because a
/// WS4 fiction manuscript mixes double-spaced narrative with single-spaced inserts
/// (verse quoted verbatim, a bibliography) at exactly that granularity, not
/// document-wide — a block whose own lines are `T,T,...` (two real lines with no
/// blank between them) or start with a leading blank never counts, regardless of
/// anything nearby. Neither measured WS4 source sets `.LS` at all (checked their own
/// raw dot-command bytes directly): WS4 predates `.LS` even being a documented dot
/// command, so there is usually no stateful signal to key off and this has to read
/// the rhythm off the pattern itself — `lsConfirmed` (true only when the file's own
/// `.LS` dot-command positively declares spacing > 1, `doc.page?.lsSource == .file`)
/// trusts direct file evidence over the inferred pattern when it exists.
///
/// A block whose shape is a clean alternation (T,B,T,B,... with no two adjacent
/// same-kind lines, ignoring a possible TRAILING blank run at its very end — see
/// below) is COMPATIBLE with the rhythm; one that also has >= threshold interior
/// blanks (an interior blank is real text on BOTH sides, within the same block) on
/// its own is CONFIRMED. `threshold` is 1 under `lsConfirmed`, else 2 — 2 because a
/// real document can carry a single, genuinely authored blank line in the middle of
/// an ordinary paragraph (measured: a real corpus document's own block, one isolated
/// interior blank, never repeated anywhere else in that block) — that is authored
/// spacing, not a rhythm, and one occurrence alone must never count it. (That
/// document is `ws5+`, so the WS4 gate alone already keeps it untouched — the
/// threshold is the SECOND independent reason, for a future WS4 capture that turns
/// out to carry the same kind of aside.)
///
/// STATE, carried across blocks in document order like any other WordStar
/// dot-command state: a CONFIRMED block turns spacing mode on; a
/// COMPATIBLE-but-unconfirmed block counts too WHILE mode is already on (this is
/// what a lone short line of dialogue — too short to confirm 2 interior repeats by
/// itself — needs: measured against a real WS4 source, several consecutive short
/// dialogue paragraphs sit between longer confirmed ones, and their own 24pt gaps to
/// their neighbours check out against that source's own baselines exactly like the
/// confirmed ones'). An INCOMPATIBLE block (leading blank, or two real lines back to
/// back) turns the mode back OFF — the one hard stop, so a verse quotation or a
/// bibliography section breaks the chain exactly where the document's own shape says
/// it should, not where a document-wide guess would. A COMPATIBLE-but-unconfirmed
/// block seen BEFORE the first CONFIRMED one (mode still off) is left alone — there
/// is no evidence yet to count it against.
///
/// TRAILING RUN: a block that counts at all (confirmed, or compatible while mode is
/// on) counts its OWN trailing blanks too — from its last real line to its own end —
/// even though a trailing run is never "interior" (there is no following real line
/// left within THIS block for it to sit between). WordStar's "blank lines become
/// part of the file" is a property of `.LS`, not of which physical line happens to
/// be a paragraph's last — measured: a WS4 source's paragraph boundaries carry a 2-3
/// blank RUN, not the single blank its own within-paragraph rhythm uses (the
/// paragraph's last line still owes its own spacing filler; the author's own
/// blank-line gap between paragraphs, typed under the same `.LS`, owes its own
/// filler too), and the resulting larger gap (measured: 48pt across a 3-blank
/// boundary, exactly 2x a normal 24pt gap) checks out against the source's own
/// baselines too.
///
/// SCOPING RULING (Jon, b26 visual pass): an earlier version of this fix collapsed
/// spacing pairs and was scoped only by block-level pattern; it un-matched -README
/// and VERSIONS (both `ws5+`, both previously matching their own WS7 captures
/// EXACTLY) to fix two WS4 sources — "a rule that un-matches exact documents to fix
/// others is not WS7's real rule... fix the broken thing without breaking anything
/// else." Rebuilt gated on the POSITIVELY DETECTED `variant == .ws4` condition per
/// Jon's follow-up mandate, and every WS4 capture behind this fix (the two sources
/// it was built from, plus three out-of-sample captures checked afterward) is
/// modelled with the SAME rule as every other WS4 document — no per-source carve-out.
/// Port of Python's `_ws4_spacing_blank_indices`.
private func ws4SpacingBlankIndices(_ doc: Document, lsConfirmed: Bool) -> [Int: Set<Int>] {
    let threshold = lsConfirmed ? 1 : 2
    var spacingMap: [Int: Set<Int>] = [:]
    var spacingMode = false
    for (bi, b) in doc.blocks.enumerated() {
        guard b.kind == .para else { continue }     // sentinels never reset the state
        let flags = b.lines.map { !isBlankLine($0) }
        guard let first = flags.first, first else {
            spacingMode = false                      // empty, or opens on a blank
            continue
        }
        let lastReal = flags.lastIndex(of: true)!
        let core = Array(flags[0...lastReal])
        let compatible = core.count < 2
            || (0..<(core.count - 1)).allSatisfy { core[$0] != core[$0 + 1] }
        if !compatible {
            spacingMode = false
            continue
        }
        let interior: [Int] = flags.count > 2
            ? (1..<(flags.count - 1)).filter { flags[$0 - 1] && !flags[$0] && flags[$0 + 1] }
            : []
        let confirmed = interior.count >= threshold
        if confirmed || spacingMode {
            var spacing = Set(interior)
            if lastReal + 1 < flags.count {
                spacing.formUnion((lastReal + 1)..<flags.count)
            }
            spacingMap[bi] = spacing
            spacingMode = true
        }
        // else: compatible, but neither confirmed itself nor inheriting an already-on
        // mode -- no evidence yet; leave uncounted, mode stays off
    }
    return spacingMap
}

/// One body item for the PLAIN (no placeable notes) printed paginator.
private enum PlainBodyItem {
    case pageBreak
    /// `.cp n` — resolved by the pagination loop below, the only thing that knows how
    /// full the page is.
    case condPage(Int)
    case line(PageLine)
    /// A `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, replayed at the block it precedes.
    /// `parity` (planning #250) is `nil` for a plain `.h1`/`.he`/`.f1`/`.fo`, else
    /// `.even`/`.odd` for `.h1e`/`.h1o`/`.f1e`/`.f1o`.
    case hf(kind: HFKind, line: Int, text: String, parity: HFParity?,
            pcl: [HFPrintControl])
}

/// A centred line's own centring tab, recomputed for the PRINTER.
///
/// WordStar 5+ centres a `.oc on` line at EDITOR time and stores the result as an
/// absolute tab mark (`Span.tabHMI`, a type-9 block) on the line's own leading padding
/// span. That stored number is the EDITOR's arithmetic, and the editor counted the
/// line's TRAILING BLANKS as part of the text it was centring. Real WS7 does not: it
/// re-centres the line on the ink, with trailing blanks off.
///
/// MEASURED against ws7-prints/v4/sawyer__PLAYBILL_EXT_DOC (a `.oc on` playbill, every
/// line a centring tab of its own). Of its 12 centred lines, 9 carry a stored tab that
/// already equals the re-centred value and 3 do not — and those 3 are exactly the 3
/// lines whose stored text ends in blanks (one, one, and two). WS7 prints all 12 at
/// `(rm - inkCols) / 2`: `A gala opening night with the ` at column 18 where the file
/// stores 17.5, `City ... special season ` at 4.5 where the file stores 4, `for Theatre
/// in the Park.  ` at 20.5 where the file stores 19.5. All 12 land on WS7's own
/// decipoint.
///
/// ONLY a line whose every span is FIXED-PITCH is recomputed. A proportionally-set
/// centred line's stored tab is the editor's own measurement of a font WE DO NOT HAVE
/// (LYING's and WARPRAYR's title pages store fractional-column tabs for exactly that
/// reason, and both are clean against WS7 today); recomputing those from a substituted
/// face's metrics would replace a real measurement with a guess. Their stored tab is
/// left exactly as WordStar wrote it.
func recentredCentreTabSpans(_ spans: [Span], block: Block, doc: Document) -> [Span] {
    guard block.align == .center, let head = spans.first, head.tabHMI != nil else {
        return spans
    }
    for span in spans {
        if let f = span.font, f >= 0, f < doc.fonts.count, doc.fonts[f].proportional {
            return spans
        }
    }
    var inkChars = Array(spans.map(\.text).joined())
    while let f = inkChars.first, f == " " { inkChars.removeFirst() }
    while let l = inkChars.last, l == " " { inkChars.removeLast() }
    if inkChars.isEmpty { return spans }
    let lm = block.leftMargin ?? 0.0
    let rm = block.rightMargin ?? 65.0
    var cols = lm + (rm - lm - Double(inkChars.count)) / 2.0
    if cols < lm { cols = lm }
    let want = roundHalfToEven(cols * Double(tabHMIPerCol))
    if want == head.tabHMI { return spans }
    var out = spans
    out[0].tabHMI = want
    return out
}

/// Blocks -> plain body items, with `doc.hfEvents` replayed at the block each one
/// precedes. Port of the printed-mode half of Python's `_doc_to_pagelines` block walk —
/// used only when `hasPlaceableNotes(doc)` is false (the notes-aware paginator above
/// handles the other case, and never replays `hfEvents` — see `Page`).
private func resolvePlainBody(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [PlainBodyItem] {
    let refNotes = inlineReferenceNotes(doc)
    // planning #266: this document's own driver-keyed cp437-158 rule, resolved once.
    let euro = pesetaMeansEuro(doc)
    var hfByBlock: [Int: [(HFKind, Int, String, HFParity?, [HFPrintControl])]] = [:]
    // planning #250: `doc.hfEventsParity` is index-aligned with `doc.hfEvents` itself
    // — see `Document.hfEventsParity`'s own doc comment. 2026-09-12 (cause 10):
    // `doc.hfEventsPcl` is index-aligned the same way, and empty for every document
    // whose running heads carry no 0x0F user print control.
    let hfParityByIndex = doc.hfEventsParity
    let hfPclByIndex = doc.hfEventsPcl
    // triage Q9: an event read INSIDE a block carries its own line position
    // (`doc.hfEventsWithin`) and is emitted THERE, between that block's own lines,
    // instead of at the block boundary `blockAnchor` names. This is the PRINTED body;
    // Modern re-groups a block's lines and draws no running head to time.
    var hfMid: [HFWithin: [(HFKind, Int, String, HFParity?, [HFPrintControl])]] = [:]
    let hfWithinByIndex = doc.hfEventsWithin
    for (i, event) in doc.hfEvents.enumerated() {
        let parity = i < hfParityByIndex.count ? hfParityByIndex[i] : nil
        let pcl = i < hfPclByIndex.count ? hfPclByIndex[i] : []
        let within = i < hfWithinByIndex.count ? hfWithinByIndex[i] : nil
        if let within {
            hfMid[within, default: []].append(
                (event.kind, event.line, event.text, parity, pcl))
        } else {
            hfByBlock[event.blockAnchor, default: []].append(
                (event.kind, event.line, event.text, parity, pcl))
        }
    }
    // b24 round 19 (RULINGS-LEDGER PIX row); round 22 closed the round-19 scope cuts --
    // `layoutPrintedPages` (the notes-aware paginator) and Modern's `modernStreams`
    // substitute too, through the same shared helpers.
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    // "Fit to text measure" (ruled fallback/cap) sizing lives in
    // `pixDimsPt`/`printedTextWidthPt` (round 22 factored them out, shared with the
    // notes-pagination and Modern paths).
    let textWidthPt = embedImages ? printedTextWidthPt(doc) : 0.0
    // b24 round 17 (RULINGS-LEDGER row 5/7): `.pm`/`.psa`/`.psb` extend round 6's RTF
    // vertical-space model to Printed PDF, same relative-computation rules. `pendingSa`
    // carries a block's own `sa` forward to whatever PageLine gets appended NEXT (which
    // may be several items away across an intervening `.hf`/pagebreak/condpage entry) —
    // applied the moment a real PageLine is built, regardless of source. Port of
    // Python's own `_doc_to_pagelines` block walk (this same function, its Printed half).
    let (docSb, docSa) = printedDocSpacingPt(doc)
    var pendingSa: Double? = nil
    let defaultLeadPt = printedLead(doc)
    // Register b31: this line's own `.po` override needs the printed type size for the
    // same edge-of-page clamp `printedLeft` already applies (`resolveLeftPt`).
    let sizeForLeft = printedSize(doc)
    // round 26 wave 3 (fidelity_gate.py Finding B): `fontLeadPt`'s carried-governing-size
    // state, threaded across every physical line of the document in source order, same
    // cross-block carry as `pendingSa`. `lhSource == .file` guard mirrors `styleLeadPt`'s
    // own — see `fontLeadPt`'s docstring.
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.blocks.contains { $0.lhAuto } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    // Finding 1 (b26 visual pass): scoped, per Jon's binding ruling, to a
    // POSITIVELY-DETECTED condition -- `variant == .ws4` -- rather than trusting the
    // block-pattern detector alone to stay harmless everywhere else. `-README`/
    // `VERSIONS` (both `ws5+`) picked up real cross-page drift the FIRST time this
    // fix shipped scoped only by pattern -- both had matched their own WS7 captures
    // EXACTLY before that, so "a rule that un-matches exact documents to fix others
    // is not WS7's real rule" (Jon). `ws4Spacing` being `false` makes `spacingMap`
    // the literal empty dictionary below for every non-WS4 document --
    // `ws4SpacingBlankIndices` is never even CALLED -- so every non-WS4 document's
    // own code path is identical to before this fix, by construction, not by
    // trusting the pattern to happen not to fire. Widening this gate past `ws4`
    // needs its own oracle evidence, not an assumption that the mechanism
    // generalises.
    let ws4Spacing = doc.detection?.variant == .ws4
    // Prefer the file's OWN `.LS` dot-state when it exists (WS7 manual, "Line
    // Spacing": see `ws4SpacingBlankIndices`); neither WS4 source measured for this
    // finding sets `.LS` at all (WS4 predates the dot command), so this is `false`
    // for them and the structural fallback in `ws4SpacingBlankIndices` carries the
    // detection instead -- but a future WS4 capture that DOES carry an explicit
    // `.LS 2`+ should be trusted over the pattern, not re-inferred from it.
    let lsConfirmed = ws4Spacing && doc.page?.lsSource == .file && (doc.page?.ls ?? 1) > 1
    let spacingMap = ws4Spacing ? ws4SpacingBlankIndices(doc, lsConfirmed: lsConfirmed) : [:]
    var items: [PlainBodyItem] = []
    // Planning #227 (columns-rule research §7, corrected): only LEAVING a `.co n>1`
    // region forces a page break -- confirmed against sawyer/DEFAULT/PRINT.TST's own
    // `.co` off transition. ENTERING one does NOT: sawyer/REF/SYMBOL.CHT's own title
    // line sits on the SAME page as its chart's columnar content in the real WS7
    // capture (1 page total). `prevCols` tracks the columns state of the most recently
    // processed REAL (`.para`) block; sentinel blocks never change it.
    var prevCols = 1
    for (bi, block) in doc.blocks.enumerated() {
        // Finding 1: see `ws4Spacing`'s own comment above -- `spacingMap` is the
        // literal empty dictionary for every non-WS4 document, so this lookup always
        // returns the empty set there and nothing below can touch one.
        let spacingBlanks = spacingMap[bi] ?? []
        for (kind, line, text, parity, pcl) in hfByBlock[bi] ?? [] {
            items.append(.hf(kind: kind, line: line, text: text, parity: parity, pcl: pcl))
        }
        if block.kind == .pagebreak && prevCols > 1 {
            // Planning #227 (corrected): a bare `.pa` occurring INSIDE an active
            // `.co n>1` region is ABSORBED, not honoured. Measured against
            // sawyer/REF/WINGDING.CHT's own real WS7 capture: its source carries
            // `.pa` markers the author placed between chart-entry groups (a manual
            // column-simulation convention predating, or kept alongside, the real
            // `.co5` that now governs the same content) -- honouring them fragmented
            // one real ~47-line column into a 44-line page plus an orphaned 3-line
            // page, inflating WINGDING.CHT to 2 engine pages against WS7's real 1.
            // Columns fill by height alone once `.co n>1` is active (research §4);
            // only `.cb` forces an early break inside one (handled below,
            // unconditionally, regardless of this gate).
            continue
        }
        if block.kind == .pagebreak || block.kind == .colbreak {
            // Planning #227: `.cb` (unconditional column break) maps onto the SAME
            // forced-break sentinel `.pa` uses OUTSIDE a columnar region (or always,
            // for `.cb` itself -- it never gets the absorption above). Inside an
            // active `.co n>1` region, the column-grouping post-pass (`applyColumns`)
            // turns every Nth forced break into a real page break and the others into
            // a column advance -- exactly what a column break means.
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage || block.kind == .condcolumn {
            // `.cc n` (planning #227) shares `.cp`'s own sentinel for the identical
            // reason `.cb` shares `.pa`'s above: "room remaining in the current
            // column" and "room remaining in the current page" are the SAME question
            // whenever a column's height equals a page's (always, in this engine).
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        if block.kind == .para {
            let curCols = block.columns ?? 1
            var lastIsBreak = false
            if case .pageBreak? = items.last { lastIsBreak = true }
            if prevCols > 1, curCols != prevCols, !items.isEmpty, !lastIsBreak {
                items.append(.pageBreak)
            }
            prevCols = curCols
        }
        if block.origin == .fi {
            // #241: see `resolvePrintedBody`'s own identical check for the
            // full citation -- WS7 prints nothing for an unresolvable `.fi`
            // target; this function is Printed-only, so the block is
            // skipped unconditionally (Modern routes through a different
            // function entirely and is untouched).
            continue
        }
        let fiPt = printedPMFiPt(block)
        // planning #257: see `PageLine.pmActive`'s own doc comment -- the RAW `.pm`
        // state, not `fiPt` (already reduced to 0 in both the "no `.pm` at all" and
        // the "typed indent already satisfies a nonzero one" cases).
        let pmActive = (block.paraMargin ?? 0) != 0
        var firstLineOfBlock = true
        // Fix C (b26-print-fidelity-2): the nearest earlier REAL (`.para`) block,
        // skipping pagebreak/condpage sentinels — `enteringLeadPt`'s own "outgoing"
        // reference for this block's first line, computed once per block since it
        // never changes within one.
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        // Printed mode renders PHYSICAL lines verbatim — a soft return broke the line on
        // paper, so it stays broken here. Indexed (not a plain `for`) so an embedded pix
        // substitution below can look ahead and CONSUME the blank placeholder lines
        // WordStar reserved for it — see `pixReservedAdvance`.
        // planning #270 item 37: `.pf on` re-wraps a paragraph at PRINT time
        // (`pfRewrappedLines`; every other block hands back `block.lines` itself, same
        // array, so nothing else in the corpus can move).
        let blkLines = pfRewrappedLines(doc, block)
        var li = 0
        while li < blkLines.count {
            for ev in hfMid[HFWithin(block: bi, linesBefore: li)] ?? [] {   // triage Q9
                items.append(.hf(kind: ev.0, line: ev.1, text: ev.2,
                                 parity: ev.3, pcl: ev.4))
            }
            let lineIdx = li
            let line = blkLines[li]
            li += 1
            var spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes, printed: true) }
                .map { sp -> Span in
                    let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                    // Register C5: the block's own paragraph-style colour is a default
                    // for every span it governs, so it can move a span that carries no
                    // attribute change at all -- the styles-unchanged fast path has to
                    // ask about it too.
                    let colour = effectiveSpanColour(sp, block: block)
                    // planning #266: the driver-keyed cp437-158 rule (`pesetaMeansEuro`).
                    // This path reads the document's own spans directly and never passes
                    // through `modernSemanticFlow`, so it applies the rule itself.
                    let text = euroText(sp.text, euro)
                    return styles == sp.styles && colour == sp.colour && text == sp.text ? sp
                        : Span(text: text, styles: styles, font: sp.font,
                               colour: colour, pctlHMI: sp.pctlHMI, pix: sp.pix,
                               pcl: sp.pcl, tabHMI: sp.tabHMI, tabLeader: sp.tabLeader)
                }
            var ownLead = leadPt(line.lead48)
            // Register b31: this line's own `.po` override, same "absolute here, `nil`
            // means agrees with the document default" contract `line.lead48` above
            // already has (`ParseWS.swift`'s back-dating pass).
            let ownLeft = line.poCols.map { resolveLeftPt($0, size: sizeForLeft) }
            // Planning #231 (.poe/.poo even/odd page offset): which of the two ever
            // governs a given line depends on the PARITY of the page it lands on --
            // not known at this build stage (pagination is a later, separate pass) --
            // so this only ever records a CANDIDATE `(even, odd)` pair; `closePage`
            // (the one place page parity is actually known) picks the real one once
            // pagination assigns this line to a page. `nil` (the overwhelming common
            // case: a document that never uses `.poe`/`.poo`) costs nothing.
            var ownParityLeft: ParityLeft?
            if line.poeCols != nil || line.pooCols != nil {
                let fallbackPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                ownParityLeft = ParityLeft(
                    even: line.poeCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt,
                    odd: line.pooCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt)
            }
            // Register b32-N10 (mirrored from ctrl-kd b48148c): this line's own `.sr`
            // roll, already resolved — `Line.roll48` is never `nil` on a real parsed line
            // (its own doc comment), so this is simply the 1/48in -> points conversion
            // `printedRollPt` already uses for the document-wide fallback, applied per
            // line.
            let ownRoll = line.roll48.map { $0 * 1.5 }
            // A WS7 paragraph STYLE's own line height (`Block.lineHeightVMI`) governs
            // OVER the generic `.lh`/document default — same precedence `newBlock` already
            // gives a style's align/margins/wrap over the running dot-command state.
            // `styleLeadPt` itself withholds an answer (`nil`) for any document that ever
            // used a real `.lh` at all (its own doc comment), so this line's own `lead48`
            // only matters as a belt-and-braces check for a genuinely per-line override.
            //
            // Fix C (b26-print-fidelity-2): a BLANK line (no real text — nothing to
            // clip, so Finding B's fallback never applies to it, see `styleLeadPt`'s
            // `raw` parameter) always gets the raw, unfallen-back value. A block's own
            // FIRST REAL line is the one `enteringLeadPt` may floor against the
            // PRECEDING block's own raw lead (its own doc comment); any other real line
            // keeps the plain fallback-eligible value, unchanged from every call site
            // before this fix.
            let isBlank = !spans.contains { $0.text.contains { !$0.isWhitespace } }
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            // planning #256: a block's own paragraph-style leading, when it
            // has one, governs OUTRIGHT -- no longer gated on whether this
            // line's own carried `.lh` happens to be unset/default (see
            // `styleLeadPt`'s own doc comment for the -HOW-TO.RJS evidence: a
            // stale, document-wide `.lh` must never outrank the style its own
            // block actually carries).
            if let styleLead {
                ownLead = styleLead
            }
            // round 26 wave 3 (fidelity_gate.py Finding B): a WS5+ FONT-BLOCK document
            // with no style governing this line (ownLead still nil) gets its lead from
            // the font block actually in force. See `fontLeadPt`.
            if ownLead == nil, fontLeadOk, block.lhAuto {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            // Finding 1: this blank IS the block's own double-spacing (see
            // `ws4SpacingBlankIndices`) -- it still becomes its own literal PageLine,
            // at its own natural (unextended) lead, EXACTLY as any other blank always
            // has; only its `ws4Spacing` flag differs, which the pagination loop
            // below reads to decide whether this blank alone may force a page break
            // (see that loop's own comment for why collapsing it into a neighbour's
            // lead, an earlier version of this fix, broke on irregular paragraph
            // lengths).
            let ws4SpacingLine = isBlank && spacingBlanks.contains(lineIdx)
            var extra = 0.0
            if let sa = pendingSa {
                extra += sa
                pendingSa = nil
            }
            // no space-before on the document's own opening paragraph — nothing above
            // it to space away from.
            if firstLineOfBlock, let sb = docSb, bi > 0 {
                extra += sb
            }
            if extra != 0.0 {
                ownLead = (ownLead ?? defaultLeadPt) + extra
            }
            // b24 round 19 (RULINGS-LEDGER PIX row): exactly one pix tag, no other real
            // text on this physical line (the confirmed real-corpus shape: every
            // acceptance document's picture reference stands alone on its own
            // paragraph) -> an image PageLine instead of a text one. If a hypothetical
            // pix tag ever shares a line with OTHER real text, this deliberately does
            // NOT substitute -- text content is never silently dropped. (Round 22: the
            // detection/sizing rule is `spansPixSubstitution`, shared with the notes
            // and Modern paths.) `.lead` is the RESERVED PLACEHOLDER block's height
            // (round 26, Finding A/C — `pixReservedAdvance`), not the raster's own
            // continuous pixel height, + whatever `.psb`/`.psa` extra was already
            // computed above.
            var substituted = false
            if embedImages,
               let sub = spansPixSubstitution(spans.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                let (reserved, nBlank) = pixReservedAdvance(
                    blkLines, startIdx: li, ownLeadPt: ownLead ?? defaultLeadPt)
                li += nBlank
                items.append(.line(PageLine([], soft: line.soft, lead: reserved + extra,
                                            overprint: line.overprint, bi: bi,
                                            image: .init(pixIndex: sub.pixIndex,
                                                         widthPt: sub.wPt, heightPt: sub.hPt),
                                            left: ownLeft, poCols: line.poCols)))
                firstLineOfBlock = false
                substituted = true
            }
            if !substituted {
                // N9 (b33 field notes): applied to the FINAL body spans, AFTER the
                // pix-substitution check above (which needs the raw, untouched text to
                // match its structural placeholder) -- state carries across every span
                // on this physical line, matching ctrl-kd's own `_doc_to_pagelines`
                // choke point exactly.
                if sentenceSpacing { spans = sentenceSpacingSpans(spans) }
                // Planning #251 (2026-09-09): model-build-time bare-tab expansion, same
                // point ctrl-kd's own `_doc_to_pagelines` plain path applies it (right
                // before this function's own PageLine construction) — see
                // `expandBareTabsForPrintedLayout`'s own doc comment (`EmitterRules.swift`).
                spans = expandBareTabsForPrintedLayout(spans)
                // Planning #238 (.oj on full justification, research/
                // 2026-09-08_justification-rule.md, ctrl-kd aeb34ad): every line of an
                // `align == .justify` block EXCEPT ITS OWN LAST is stretched to the
                // block's resolved right margin -- measured directly against WS7
                // (sawyer/LSRBOX/LSRBOX.WS): the paragraph's final physical line sits
                // short of the margin, ragged, while every line above it reaches the
                // margin exactly. `rightMargin` is `.rm` in print columns, measured
                // from the SAME `.po` origin as the left edge (confirmed against two
                // independent captures: LSRBOX's own explicit `.po .7"/.rm 6.5"` and
                // CTRL-K.H1's all-defaults line, both landing on their real WS7 right
                // edge as poOrigin + rmCols*7.2pt, never rm alone) -- 65.0 is
                // WordStar's own factory default (WSFORMAT.TXT gives no numeric
                // default; confirmed instead against CTRL-K_EXT_H1.pcl's real
                // flush-right edge, 525.6pt = the same default .po 8 cols (57.6pt) +
                // 65 cols (468pt)). This function is Printed-only (see its own doc
                // comment), so there is no `printed` guard here — ctrl-kd's own
                // equivalent gate is `printed and b.align == 'justify' and ...`.
                // A `.oc on` line's own centring tab is the EDITOR's arithmetic; the
                // printer re-centres on the ink alone (see recentredCentreTabSpans).
                spans = recentredCentreTabSpans(spans, block: block, doc: doc)
                var justifyRightX: Double? = nil
                // planning #270 item 37: under `.pf on` the PARAGRAPH is the unit --
                // `line.soft` after the re-wrap. See the notes-bearing sibling's own
                // comment for the rule and the captures behind it.
                let lastInUnit = block.printReformat == "on"
                    ? !line.soft : lineIdx >= blkLines.count - 1
                if block.align == .justify, !lastInUnit {
                    let poOriginPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                    let rmCols = block.rightMargin ?? 65.0
                    justifyRightX = poOriginPt + rmCols * pdfPtPerCol
                }
                items.append(.line(PageLine(spans, soft: line.soft, lead: ownLead,
                                            overprint: line.overprint,
                                            fi: firstLineOfBlock ? fiPt : nil,
                                            pmActive: pmActive, bi: bi,
                                            ws4Spacing: ws4SpacingLine,
                                            kerning: line.kerning, left: ownLeft, roll: ownRoll,
                                            justifyRightX: justifyRightX,
                                            parityLeft: ownParityLeft,
                                            poCols: line.poCols)))
                firstLineOfBlock = false
            }
        }
        // triage Q9: any event whose recorded line index is at or past this block's own
        // line count belongs at the block's END — the same place the block-boundary
        // anchor would have put it. `blkLines` is not always `block.lines` (`.pf on`
        // re-wraps), so this is a scan, not an equality: an event must never be dropped
        // for landing past it.
        for key in hfMid.keys.filter({ $0.block == bi && $0.linesBefore >= blkLines.count })
                             .sorted(by: { $0.linesBefore < $1.linesBefore }) {
            for ev in hfMid[key] ?? [] {
                items.append(.hf(kind: ev.0, line: ev.1, text: ev.2,
                                 parity: ev.3, pcl: ev.4))
            }
        }
        // `!firstLineOfBlock`: this block actually appended at least one real PageLine
        // (an empty-text block leaves it true, nothing to space away from). Carried to
        // whatever PageLine comes next, however many items away that is.
        if let sa = docSa, !block.lines.isEmpty, !firstLineOfBlock {
            pendingSa = sa
        }
    }
    return items
}

/// Points-based printed pagination for documents with NO placeable notes — the plain
/// half of Python's `_doc_to_pagelines`. Port of ctrl-kd 17e4ea0/8b902ff.
///
/// Paper is physical: WordStar advances each line by the `.lh` in force and starts a
/// new page when the next advance would leave the text area, so a document that varies
/// its leading fits more or fewer lines than the default-lead COUNT says. The budget is
/// the page's own text HEIGHT (`printedBudgetPt`) and EVERY line — the first one
/// included — spends its own lead out of it, which is exactly where each line's
/// baseline lands on paper (`pageStream`: the first line sits at `top` plus its OWN
/// lead, each later one a further lead down). A uniform-lead page therefore paginates
/// EXACTLY as the old line count did (n leads fit iff n <= floor(height / lead) == cap),
/// so no fontless byte moves; only a page that MIXES leads can now reach into the
/// fractional remainder `cap`'s own floor discarded — see `printedBudgetPt`, which
/// measures that against real WS7. Overprint lines spend no lead at all, on paper and
/// here.
///
/// The running head/foot IN FORCE on a page is replayed from `doc.hfEvents` rather than
/// read from the document's final state: WordStar applies a running head from the page
/// where it is defined — on that page itself only if no text has printed there yet,
/// else from the next page.
// NOT private (job 255, additive): `AnnotatedLayout.swift`'s natural page-break
// detection needs the real paginator, not a re-derived guess — "the engine is the
// single source of truth." Pure visibility widening, zero behavior change: every
// call site, every line of the body, is untouched.
func layoutPrintedPagesPlain(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false, rawPageCap: Int? = nil
) -> [Page] {
    let items = resolvePlainBody(doc, pixResults: pixResults, pictures: pictures,
                                 sentenceSpacing: sentenceSpacing)
    var capacity = printedCap(doc)
    let defaultLead = printedLead(doc)
    var budget = printedBudgetPt(doc, capacity: capacity, defaultLead: defaultLead)
    // b24 round 17b (RULINGS-LEDGER row 5/6, register C8): `.sb` suppresses blank lines
    // specifically at the TOP of a page — WordStar's own pagination concern, not a
    // text-content one, so it belongs in THIS loop (the only place that knows a page
    // just started) rather than `resolvePlainBody`'s line-building pass above.
    let suppressBlanks = doc.formatting.suppressBlanks ?? false
    // Finding 3 (b26-print-fidelity-2): a fresh page picks up whatever `.mt`/`.mb` was
    // in force at its OWN first block, not the document's global first-occurrence pair
    // — see `mtMbCheckpoints`. `globalMt`/`globalMb` are what `printedCap(doc)` itself
    // already used above; a page whose own checkpoint matches them leaves
    // `Page.mtLines`/`mbLines` at their `nil` default (render side: "use the document
    // global", untouched).
    let mtMbCheckpointsList = mtMbCheckpoints(doc)
    let globalMt = mtMbCheckpointsList[0].mt
    let globalMb = mtMbCheckpointsList[0].mb
    var curMt = globalMt
    var curMb = globalMb
    // register b31-dot-command-sweep: `.pl`/`.hm`/`.fm` are stateful too, same mechanism
    // as `.mt`/`.mb` above -- see `plCheckpoints`/`hmFmCheckpoints`. `plAt(.., 0)`/
    // `hmFmAt(.., 0)`, NOT a raw index-0 read: block 0's seed is WordStar's hardcoded
    // default, which a document that declares `.pl`/`.hm`/`.fm` right at its own start
    // immediately supersedes with another (bi=0) checkpoint -- the `At` helpers resolve
    // that correctly, a raw index-0 read would not.
    let plCheckpointsList = plCheckpoints(doc)
    let globalPl = plAt(plCheckpointsList, 0)
    var curPl = globalPl
    let hmFmCheckpointsList = hmFmCheckpoints(doc)
    let (globalHm, globalFm) = hmFmAt(hmFmCheckpointsList, 0)
    var curHm = globalHm
    var curFm = globalFm
    // mechanism O (ctrl-kd 55d2b52): `.po` too -- see `poCheckpoints`. Feeds `runningOps`'s
    // own header/footer LEFT edge only (body text's per-LINE `.po` already works,
    // `Line.poCols`) -- still ride the SAME per-page-start recompute so `Page.poCols` is
    // known by the time a page closes, exactly like `plLines`/`hmLines`/`fmLines`.
    let poCheckpointsList = poCheckpoints(doc)
    let globalPo = poAt(poCheckpointsList, 0)
    var curPo = globalPo
    // Planning #231: `.poe`/`.poo` -- see `poeOrPooCheckpoints`. No block-0 seed
    // (unlike `poCheckpointsList` above): "never used" is a real, different answer
    // from "used at the document default," and `leftForParity` already treats a `nil`
    // value as "fall back to `curPo`" -- exactly what a document that never writes
    // `.poe`/`.poo` needs, byte-identical to before this feature existed.
    let poeCheckpointsList = poeOrPooCheckpoints(doc, dotName: "POE")
    let pooCheckpointsList = poeOrPooCheckpoints(doc, dotName: "POO")
    var curPoe: Double? = poeCheckpointsList.isEmpty ? nil : poAt(poeCheckpointsList, 0)
    var curPoo: Double? = pooCheckpointsList.isEmpty ? nil : poAt(pooCheckpointsList, 0)
    // `closePage`'s "does this page need its own render-time override" test can NOT
    // compare against `globalPl`/`globalHm`/`globalFm`/`globalPo` above: those are seeded at
    // WordStar's hardcoded default (correct for BEFORE any real occurrence), but the
    // render loop's fallback ("Page.* left nil means use doc.page AS IS") reads
    // `ParseWS.swift`'s own first-occurrence value, which -- in the exact degenerate case
    // the seed fix above exists for (a command whose ONLY occurrence sits mid-document) --
    // is that SAME later value, wrongly, for every page. Comparing against the RAW
    // `doc.page` reading instead makes a page whose resolved value happens to DIFFER from
    // it get its own override even when that resolved value equals the (correct)
    // checkpoint global, which is exactly the pages BEFORE such a command's first real
    // occurrence.
    let docPl = doc.page?.plLines ?? defaultPlLines
    let docHm = doc.page?.hmLines ?? 2.0    // WSFORMAT's own hardcoded ".HM" default
    let docFm = doc.page?.fmLines ?? 2.0    // WSFORMAT's own hardcoded ".FM" default
    let docPo = doc.page?.poCols ?? 8.0     // WS7 manual's own default page offset
    // triage Q12: how far into the document this page has READ, kept as a running
    // per-block line tally. `checkpointsByPage` needs it because `finalizePages` strips
    // a page's trailing blanks -- a page of nothing but blank lines ends up EMPTY, with
    // no `bi` left on it at all, and the leading blank run a `.pn` sits inside is
    // exactly that shape. Counted here, before anything is stripped.
    var readTally: [Int: Int] = [:]
    // M31: the `.pr or=` checkpoints, and the document-level value a page is compared
    // AGAINST before it stamps one of its own -- `doc.formatting.orientation`, the
    // document-wide last-write-wins reading every non-printed surface still uses.
    let orCheckpointsList = orCheckpoints(doc)
    let docOr = doc.formatting.orientation ?? .portrait
    var curOr = orAt(orCheckpointsList, 0, 0)
    /// (mt, mb, pl, hm, fm, po, poe, poo, orientation) in force at block `bi`, for the page about to start there --
    /// shared by BOTH places a fresh page begins: the explicit-break path below (`page`
    /// already empty by the time the next `.line` case's top-of-switch check runs), and
    /// the ORGANIC-overflow close (where `page` is NOT yet empty at the top of THIS
    /// iteration -- the line that overflows IS the new page's own first line, and must use
    /// ITS block's geometry, not the closing page's). Missed until register b31-dot-
    /// command-sweep: `.pl`'s own oracle (PL_PROBE) has no explicit break at all -- an
    /// ordinary organic page break -- and real WS7 still used the new `.pl` starting the
    /// very next page, which only the organic-close recompute site can reproduce. This
    /// also strengthens `.mt`/`.mb` for organic breaks (previously recomputed only at the
    /// explicit-break site).
    func recomputeGeom(_ bi: Int) -> (mt: Double, mb: Double, pl: Double, hm: Double, fm: Double,
                                      po: Double, poe: Double?, poo: Double?,
                                      orientation: Orientation) {
        let (mt, mb) = mtMbAt(mtMbCheckpointsList, bi)
        let pl = plAt(plCheckpointsList, bi)
        let (hm, fm) = hmFmAt(hmFmCheckpointsList, bi)
        let po = poAt(poCheckpointsList, bi)
        let poe: Double? = poeCheckpointsList.isEmpty ? nil : poAt(poeCheckpointsList, bi)
        let poo: Double? = pooCheckpointsList.isEmpty ? nil : poAt(pooCheckpointsList, bi)
        // M31: the line-exact form -- `readTally[bi]` is how many lines of this block
        // earlier pages consumed, i.e. where this page opens INSIDE the block, and it is
        // still the pre-line value here (the tally advances at the bottom of the loop
        // body). See `orAt`.
        let orientation = orAt(orCheckpointsList, bi, readTally[bi] ?? 0)
        return (mt, mb, pl, hm, fm, po, poe, poo, orientation)
    }

    var pages: [Page] = []
    var page: [PageLine] = []
    var readPos: PageReadPos?
    var spent = 0.0
    var curHeaders: [Int: String] = [:]
    var curFooters: [Int: String] = [:]
    var pageHeaders: [Int: String] = [:]     // state at the OPEN page's start
    // cause 10: the 0x0F print-control siblings of `curHeaders`/`pageHeaders`,
    // snapshotted at exactly the same moments -- see `Page.headerPcl`.
    var curHeadersPcl: [Int: [HFPrintControl]] = [:]
    var curFootersPcl: [Int: [HFPrintControl]] = [:]
    var pageHeadersPcl: [Int: [HFPrintControl]] = [:]
    var pageFootersPcl: [Int: [HFPrintControl]] = [:]
    var pageFooters: [Int: String] = [:]
    // Planning #250: the SAME flat/snapshot machinery as `curHeaders`/`pageHeaders`
    // above, one independent pair per parity — `.h1e`/`.f1e` write only `curHeadersE`/
    // `curFootersE`, `.h1o`/`.f1o` only `curHeadersO`/`curFootersO`; a plain `.h1`/
    // `.fo` never clears either (the same "each command in this family is
    // independently stateful" rule `.poe`/`.poo` already established). Resolved
    // against the real page parity only in `closePage`, the one place that knows it.
    var curHeadersE: [Int: String] = [:]
    var curHeadersO: [Int: String] = [:]
    var curFootersE: [Int: String] = [:]
    var curFootersO: [Int: String] = [:]
    var pageHeadersE: [Int: String] = [:]
    var pageHeadersO: [Int: String] = [:]
    var pageFootersE: [Int: String] = [:]
    var pageFootersO: [Int: String] = [:]

    // Planning #227 follow-up (2026-09-12): A COLUMN GROUP SHARES ONE TOP.
    // `applyColumns` folds every N consecutive sub-"pages" of a `.co n` region into one
    // physical sheet, side by side -- so those N sub-pages are N COLUMNS OF THE SAME
    // SHEET, and on paper they all begin at the SAME vertical position: wherever the
    // columnar region itself began on that sheet, BELOW any non-columnar prefix (a
    // title line and its blank) the sheet opened with. Each column therefore has that
    // much LESS room than a whole page, not a whole page's worth.
    //
    // Measured against real WS7 (`ws7-prints/v4`, PRISTINE.EXE) -- every column of
    // every one of these begins at the region's own top, and every column holds the
    // same number of lines as column 1's own columnar part, never more:
    //   REF/WINGDING.CHT   prefix 2 lines (24pt): WS7 columns 2-5 start at 153.2pt and
    //                      hold 45 lines; this engine started them at the sheet's own
    //                      first text line (129.2pt) and gave them 46.
    //   REF/SYMBOL.CHT     prefix 2 lines (24pt): WS7 124.4pt / 47 lines; engine
    //                      100.4pt / 48.
    //   PRINTERS/fontcrib.ws, PRINTER.PS   prefix 2 lines (24pt): WS7 66.8pt / 51
    //                      lines; engine 42.8pt / 52.
    // `colOffsetPt` is that prefix's own height in points, captured from `spent` at the
    // moment the group's FIRST columnar line is admitted -- the same quantity
    // `applyColumns` re-derives per merged sheet for the DRAW side
    // (`Page.columnTopOffsetPt`), from the same lines' own leads. It is charged against
    // `budget` for every column of the group EXCEPT the first (which pays the prefix
    // itself, out of the same budget, line by line), and released when the group wraps
    // onto a fresh sheet or the region ends. Port of Python's `_doc_to_pagelines`.
    var colGroupCols = 1            // `.co n` of the region the open page is in
    var colGroupIndex = 0           // which column of the group the open page is
    var colOffsetPt = 0.0           // the group's shared prefix height, in points
    func lineCols(_ line: PageLine) -> Int? {
        guard let bi = line.bi, bi >= 0, bi < doc.blocks.count else { return nil }
        return doc.blocks[bi].columns ?? 1
    }
    /// How much of `budget` the OPEN page must leave to the group's shared prefix:
    /// nothing for column 0, which pays that prefix line by line out of the same
    /// budget, and the prefix's own height for every column after it, which starts
    /// BELOW it.
    func colCut() -> Double { colGroupIndex > 0 ? colOffsetPt : 0.0 }

    /// This line's own vertical advance, in points -- what it spends out of `budget`
    /// (the page's real text height, `printedBudgetPt`).
    ///
    /// EVERY line spends its own lead, the page's first one included: `pageStream`
    /// places that first baseline at `top` plus its OWN lead, so on paper it has
    /// already consumed exactly that much of the text height. This used to credit the
    /// first line as free against a budget one default lead short
    /// (`(cap - 1) * defaultLead`), which is the same arithmetic whenever that line's
    /// lead is at or above the document default -- but a page opening on a line
    /// SHORTER than the default (sawyer/REF/WINGDING.CHT's own 12pt title under its
    /// `.lh 14pt`) was charged the full default for it and lost the difference. See
    /// `printedBudgetPt` for the measurements.
    ///
    /// b26-mtmb-general (pictures-mode pagination, -README.WS) and planning #236
    /// (sawyer/INTERVU.WS) both fall straight out of this rule rather than needing
    /// their own credits: an embedded image's `.lead` is a RESERVED-BAND total
    /// (`pixReservedAdvance` -- the pix tag's own line plus its contiguous following
    /// blanks), and charging it in full is precisely what the `pictures = .off` path
    /// spends on the same band as ordinary per-line advances, so the two modes break in
    /// the same place wherever the band lands; and a page whose first body line runs at
    /// a STYLE's own larger VMI (INTERVU.WS's 24pt "MS Body Copy" against an unset 12pt
    /// `.lh`) no longer pockets phantom room it never had.
    ///
    /// An OVERPRINT line shares the previous line's baseline and spends nothing, on
    /// paper and here. Port of Python's `_doc_to_pagelines`'s own `_cost`.
    func cost(_ line: PageLine) -> Double {
        let lead = line.lead ?? defaultLead
        if let last = page.last, last.overprint { return 0.0 }
        return lead
    }
    func closePage(explicit: Bool = false, breakBI: Int? = nil) {
        var pg = Page(page,
                      headers: pageHeaders.filter { !$0.value.isEmpty },
                      footers: pageFooters.filter { !$0.value.isEmpty })
        // cause 10: kept even when the text dicts above drop the slot -- a header line
        // whose whole content was one print control has EMPTY text and a real control
        // to draw, which is exactly LSRBOX.WS's own `.h1`.
        pg.headerPcl = pageHeadersPcl.filter { !$0.value.isEmpty }
        pg.footerPcl = pageFootersPcl.filter { !$0.value.isEmpty }
        pg.footerInUse = !pageFooters.isEmpty
        // #228: only ever true from the post-loop trailing-`.pa` branch below,
        // and only when `page` (this closing page's own body) is empty -- a
        // page WITH content already carries real `.bi`-bearing lines, so it
        // needs no fallback and stays exempt from `finalizePages`'s empty-
        // trailing-page cleanup on its own (that cleanup only pops truly-
        // empty pages to begin with).
        if explicit, page.isEmpty {
            pg.explicitBreak = true
            pg.explicitBreakBI = breakBI
        }
        if curMt != globalMt || curMb != globalMb {
            pg.mtLines = curMt
            pg.mbLines = curMb
        }
        // M31: this page's own sheet, stamped only when it differs from the document's
        // -- same `nil`/"document global" contract as everything else here, so every page
        // of every document with at most one column-1 `.pr or=` is byte-identical.
        if curOr != docOr {
            pg.orientation = curOr
        }
        if curPl != docPl {
            pg.plLines = curPl
        }
        if curHm != docHm || curFm != docFm {
            pg.hmLines = curHm
            pg.fmLines = curFm
        }
        // Planning #231: this page's own PARITY -- `pages.count` is exactly the count
        // of pages already closed, so the page closing right now is page number
        // `pages.count + 1`, known for the FIRST time here (nothing upstream of
        // pagination can know it). `leftForParity` falls back to `curPo` whenever
        // neither `.poe` nor `.poo` is in force, so a document that never uses either
        // resolves to `curPo` on every page, byte-identical to before this feature
        // existed.
        let isEvenPage = (pages.count + 1) % 2 == 0
        let parityPo = leftForParity(curPo, curPoe, curPoo, isEven: isEvenPage)
        if parityPo != docPo {
            pg.poCols = parityPo
            // #241 follow-up: mark that this override is a live `.poe`/`.poo` parity
            // decision (not a plain mid-document `.po` excursion) so the running
            // head/foot's own `pageGeomChanged` gate (`PDFWriter.swift`) -- correctly
            // built to exclude a HOLYMAC-style transient `.po` -- lets it through
            // regardless. See `Page.poParity`.
            pg.poParity = curPoe != nil || curPoo != nil
        }
        // THE AUTOMATIC NUMBER IS STAMPED WHERE THE PAGE ENDS, not where it began -- so
        // its `.po` is the one in force at this page's LAST line, and `curPo` (the
        // page-OPEN snapshot every other field here carries) is the wrong question to
        // ask for it. The oracle is `sawyer/REF/REFORM.DOT`: its `.po 1i` lands two
        // lines before the page's own `.pa`, WS7 prints the LAST body line at 72.0pt
        // (10 columns -- the new offset, live) and that same page's number at 306.0pt,
        // `(10 + 33.5 - 1) * 7.2`. Reading the page's opening `.po 8` instead put the
        // number at 291.6pt. `sawyer/REF/FONTS.REF` (alternating `.po.2i`/`.po.7i`, ten
        // numbered pages at 248.4 / 284.4 page by page) agrees under both readings and
        // so does not separate them; REFORM does.
        //
        // Read off `PageLine.poCols` -- the parser's own `.if`-aware per-line state --
        // and NEVER `poCheckpoints`, which lists a `.po` inside a FALSE `.if` block like
        // any other and would answer `REF/REFORM.DOT` and `FONTS/PS/ERROR.WS` with the
        // `.po .7i` WordStar never executes (WS7 numbers both at 306.0pt, the `.po 1i`
        // before the conditional; the checkpoint scan says 284.4).
        //
        // NO CHECKPOINT FALLBACK either. `PageLine.poCols` `nil` on every line of the
        // page means what it means everywhere else here -- "this page agrees with the
        // document's own default" -- and `autoPageNumberXPt` reads that default itself
        // when handed `nil`. `FONTS/PS/ERROR.WS` is `.po 1i` + `.if 1=0`/`.po .7i`/`.ei`
        // and NOTHING else, so no line ever carries an override, the document default is
        // the correct 10 columns, and the checkpoint scan's own answer is the dead 7.
        //
        // PARITY STILL WINS, resolved at the same block: `.poe`/`.poo` are the page's
        // own even/odd offsets whatever `.po` says (planning #231).
        let pageBIs = pg.lines.compactMap { $0.bi }
        if let endBI = pageBIs.max() {
            let endPo = pg.lines.reversed().compactMap { $0.poCols }.first
            let endPoe: Double? = poeCheckpointsList.isEmpty
                ? nil : poAt(poeCheckpointsList, endBI)
            let endPoo: Double? = pooCheckpointsList.isEmpty
                ? nil : poAt(pooCheckpointsList, endBI)
            if endPo != nil || endPoe != nil || endPoo != nil {
                pg.autoPagenoPo = leftForParity(endPo ?? docPo, endPoe, endPoo,
                                                isEven: isEvenPage)
            }
        }
        // Planning #250: `.h1e`/`.h1o`/`.f1e`/`.f1o` -- this page's own PARITY
        // (`isEvenPage`, just resolved above) picks its real line-1 text the same way
        // `.poe`/`.poo` picks its own left origin: its OWN parity variant if the
        // document ever set one FOR THIS PARITY, else whatever plain `.h1`/`.he`/
        // `.f1`/`.fo` governs (`pageHeaders`/`pageFooters`, already the page's own
        // snapshot, unchanged). `pageHeadersE`/`O`/`pageFootersE`/`O` all empty (no
        // document that never uses the family) means `parityHF` returns `nil` every
        // time below -- `pg.headers`/`pg.footers` stay byte-identical to before this
        // feature existed.
        //
        // "Only one of the pair set" (no corpus document exercises it): the un-set
        // parity has no override of its own here and falls through to `pageHeaders`/
        // `pageFooters` -- the flat dict every `.h#`/`.f#` command ALSO writes
        // (`parseHeadFoot`, unconditionally, parity or not), the SAME last-in-source-
        // order-wins projection Modern/RTF/plain-text already read. Port of ctrl-kd's
        // own `_parity_hf` (pdf.py, planning #250) -- see its own doc comment for why
        // the flat fallback is NOT necessarily "the plain `.h1`'s own text" (a parity-
        // specific override is independently stateful, same as `.poe`/`.poo`).
        func parityHF(evenMap: [Int: String], oddMap: [Int: String],
                     fontsParity: [Int: [HFParity: Int]], tabsParity: [Int: [HFParity: HFTabMark]],
                     alignParity: [Int: [HFParity: Alignment]],
                     styleAttrsParity: [Int: [HFParity: Style]])
            -> (text: String, override: HFOverride)? {
            guard evenMap[1] != nil || oddMap[1] != nil else { return nil }
            let letter: HFParity
            let text: String
            if isEvenPage, let t = evenMap[1] {
                letter = .even; text = t
            } else if !isEvenPage, let t = oddMap[1] {
                letter = .odd; text = t
            } else {
                return nil
            }
            // Planning #255: this page's own resolved style-sheet alignment/span attrs,
            // the SAME parity slot fontIdx/tab just above already read.
            let override = HFOverride(fontIdx: fontsParity[1]?[letter], tab: tabsParity[1]?[letter],
                                      align: alignParity[1]?[letter],
                                      styleAttrs: styleAttrsParity[1]?[letter] ?? [])
            return (text, override)
        }
        if let (text, override) = parityHF(evenMap: pageHeadersE, oddMap: pageHeadersO,
                                           fontsParity: doc.headerFontsParity,
                                           tabsParity: doc.headerTabsParity,
                                           alignParity: doc.headerAlignParity,
                                           styleAttrsParity: doc.headerStyleAttrsParity) {
            if text.isEmpty { pg.headers.removeValue(forKey: 1) } else { pg.headers[1] = text }
            pg.headHfOverride = [1: override]
        }
        if let (text, override) = parityHF(evenMap: pageFootersE, oddMap: pageFootersO,
                                           fontsParity: doc.footerFontsParity,
                                           tabsParity: doc.footerTabsParity,
                                           alignParity: doc.footerAlignParity,
                                           styleAttrsParity: doc.footerStyleAttrsParity) {
            if text.isEmpty { pg.footers.removeValue(forKey: 1) } else { pg.footers[1] = text }
            pg.footHfOverride = [1: override]
        }
        // Body text: `resolvePlainBody` could not resolve a `.poe`/`.poo`-governed
        // line's own left origin at BUILD time (which page, and therefore which
        // parity, a line lands on is a pagination question, not a parse-order one) --
        // it left a `(even, odd)` candidate pair on `.parityLeft` instead. Resolved
        // now, in place, the one moment this loop actually knows this page's parity.
        for i in pg.lines.indices {
            if let parityLeft = pg.lines[i].parityLeft {
                pg.lines[i].left = isEvenPage ? parityLeft.even : parityLeft.odd
            }
        }
        // triage Q12 -- see `Page.readPos`'s own comment.
        pg.readPos = readPos
        pages.append(pg)
    }
    func openNewPage() {
        // One sub-page just closed: the NEXT one is the next column of this group,
        // until the group wraps onto a fresh physical sheet (where there is no prefix
        // above the region any more). Port of Python's `_advance_column`.
        if colGroupCols > 1 {
            colGroupIndex += 1
            if colGroupIndex >= colGroupCols {
                colGroupIndex = 0
                colOffsetPt = 0.0
            }
        }
        page = []
        spent = 0.0
        pageHeaders = curHeaders
        pageFooters = curFooters
        pageHeadersPcl = curHeadersPcl
        pageFootersPcl = curFootersPcl
        pageHeadersE = curHeadersE
        pageHeadersO = curHeadersO
        pageFootersE = curFootersE
        pageFootersO = curFootersO
    }

    /// Triage Q9: WordStar closes a page the MOMENT it is full; this engine breaks
    /// lazily, when the next line turns out not to fit. True when the next real line on
    /// this page cannot fit — i.e. the break has, in WordStar's own reckoning, already
    /// happened, so a dot command read here belongs to the next page. An EXPLICIT break
    /// ahead is not this case: the command still belongs to the page it was read on.
    func pageAlreadyFull(_ fromIndex: Int) -> Bool {
        if page.isEmpty { return false }
        for peek in items[(fromIndex + 1)...] {
            switch peek {
            case .pageBreak: return false
            case .line(let pl): return spent + cost(pl) > budget - colCut() + 1e-6
            default: continue
            }
        }
        return false
    }

    // planning #271 M10 (the QuickLook thumbnail): stop paginating once the caller's
    // prefix is on the shelf. `rawPageCap` is already the SUB-page budget -- one column
    // of a `.co n` region is a sub-page here, and `applyColumns` folds n of them into
    // one sheet afterwards -- with one spare on top, so the page the caller asked for is
    // never the array's LAST page and never meets a tail rule it would not meet in a
    // full run. `docToPagelines` computes it; nothing else calls this with a cap.
    var stoppedEarly = false
    for (itemIndex, item) in items.enumerated() {
        if let cap = rawPageCap, pages.count >= cap {
            stoppedEarly = true
            break
        }
        switch item {
        case .hf(let kind, let line, let text, let parity, let pcl):
            if parity == .even {
                if kind == .header { curHeadersE[line] = text } else { curFootersE[line] = text }
            } else if parity == .odd {
                if kind == .header { curHeadersO[line] = text } else { curFootersO[line] = text }
            }
            if kind == .header { curHeaders[line] = text } else { curFooters[line] = text }
            // cause 10: this event's own print controls travel with its text.
            if kind == .header { curHeadersPcl[line] = pcl } else { curFootersPcl[line] = pcl }
            // A HEADER is emitted at the TOP of a page, so a `.he`/`.h#` read after
            // the page's first line cannot reach it -- that is the `page.isEmpty`
            // gate, and it is right. A FOOTER is emitted at the BOTTOM, so a
            // `.fo`/`.f#` read ANYWHERE before the page ends still governs that page.
            // Both used to take the header's rule, which put every footer change one
            // page late.
            //
            // MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on
            // `sawyer/MACROS/HOLYMAC/8MAC`, which sets `.fo<31 blanks>#` after a blank
            // line (so page 1 has already begun) and clears it with a bare `.fo`
            // immediately AFTER its first page break. WS7 prints "286" at 280.8pt --
            // column 31, exactly where the `#` sits -- at the foot of page 1 and NO
            // footer on pages 2-10; and, from the same commands, NO header on page 1
            // and "HOLY MACRO!  #" on 2-10. This engine printed the automatic page
            // number on page 1 (centred, 291.6pt) and the footer on page 2.
            //
            // AND (triage Q9) WordStar closes a page the MOMENT it is full; this engine
            // breaks lazily, when the next line turns out not to fit. A dot command
            // sitting exactly on that boundary is therefore read on the OLD page here and
            // on the NEW page in WordStar. `8MAC`'s page 1 fills exactly (its last body
            // line at 7200 decipoints, the last the page has) and its bare `.fo` sits
            // immediately after it: real WS7 keeps `286` at the foot of page 1, so that
            // `.fo` was read on page 2.
            if kind == .footer && !pageAlreadyFull(itemIndex) {
                pageFooters = curFooters
                pageFootersPcl = curFootersPcl
                pageFootersE = curFootersE
                pageFootersO = curFootersO
            } else if kind == .header && page.isEmpty {   // nothing printed on this page yet
                pageHeaders = curHeaders
                pageHeadersPcl = curHeadersPcl
                pageHeadersE = curHeadersE
                pageHeadersO = curHeadersO
            }
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            // planning #236 remainder (sawyer/INTERVU.WS): the same style-vs-
            // document-default gap `cost`'s first-line credit above was just
            // fixed for. A flat `n * defaultLead` room estimate prices the
            // upcoming reserved lines at `n * defaultLead` points when they
            // may actually cost more (a style's own bigger VMI, or a
            // stateful `.lh` override) — measured directly against
            // INTERVU.WS's WS7 capture: a `.cp2` sitting right after a Q&A
            // paragraph break measured room in default-lead units as
            // sufficient when only 36pt of real room was left and both
            // reserved lines (each a real 24pt "MS Body Copy" style line)
            // together need 48pt. Real WS7 pushes the WHOLE paragraph to a
            // fresh page instead of splitting it. Look ahead at the REAL
            // cost of the next `n` PageLines (skipping sentinels) instead of
            // assuming each one is exactly `defaultLead` tall — confirmed
            // necessary and not merely redundant with the `cost` fix: without
            // this lookahead too, the same document still mispaginates.
            // Port of Python's identical `pdf._doc_to_pagelines` fix.
            var needed = 0.0
            var seen = 0
            peekLoop: for peekIndex in (itemIndex + 1)..<items.count {
                switch items[peekIndex] {
                case .pageBreak:
                    break peekLoop
                case .hf, .condPage:
                    continue peekLoop
                case .line(let peekLine):
                    needed += peekLine.lead ?? defaultLead
                    seen += 1
                    if seen >= n { break peekLoop }
                }
            }
            let room = budget - colCut() - spent
            if room < needed - 1e-6, !page.isEmpty {
                closePage()
                openNewPage()
            }
        case .pageBreak:
            // Always closes -- even an empty page, which IS a blank sheet (`.pa .pa`).
            closePage()
            openNewPage()
        case .line(let line):
            // Finding 3: a line about to start a FRESH page picks up the `.mt`/`.mb`
            // in force at ITS OWN block — recomputing `capacity`/`budget` for THIS
            // page only, so a page whose geometry never changes never recomputes to a
            // different number (see `printedCapFor`'s docstring).
            if page.isEmpty, let bi = line.bi {
                let (mt, mb, pl, hm, fm, po, poe, poo, orient) = recomputeGeom(bi)
                curMt = mt
                curMb = mb
                curPl = pl
                curHm = hm
                curFm = fm
                curPo = po
                curPoe = poe
                curPoo = poo
                curOr = orient
                capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                budget = printedBudgetPt(doc, capacity: capacity, defaultLead: defaultLead,
                                         mtLines: mt, mbLines: mb, plLines: pl)
            }
            // A line LEAVING the columnar region releases the group's shared prefix
            // before this page's own room is judged -- the break that carried us here
            // was forced by that same state change (`resolvePlainBody`'s own `prevCols`
            // gate), so the page it opens is an ordinary whole one again.
            if colGroupCols > 1, lineCols(line) == 1 {
                colGroupCols = 1
                colGroupIndex = 0
                colOffsetPt = 0.0
            }
            let overflow = spent + cost(line) > budget - colCut() + 1e-6
            // Finding 1 (b26 visual pass): the FIRST `ws4Spacing` blank (see
            // `ws4SpacingBlankIndices`) to overflow a page's budget never triggers
            // the break by itself -- a physical blank-line paper advance right at
            // the bottom margin doesn't need a fresh sheet, and giving it its OWN
            // page-break decision was this finding's original bug (a page break
            // landing mid text/blank pair silently spent one line of the NEXT
            // page's budget on ink-free paper, growing a cumulative real-line
            // deficit every other page). ONLY a PageLine `ws4SpacingBlankIndices`
            // positively classified gets this exemption -- an ordinary blank
            // (every non-WS4 document's blanks, and a WS4 document's own authored
            // ones, chapter-drops included) still forces the break exactly as
            // before this fix, since `ws4Spacing` defaults `false` and nothing here
            // changes that default. `alreadyOver` denies the exemption to a SECOND
            // consecutive over-budget spacing blank (a paragraph boundary's own 2-3
            // blank run): forgiving every blank in a run over-admits a whole extra
            // real line one measured source's own WS7 capture didn't have.
            let alreadyOver = spent > budget - colCut() + 1e-6
            let full = overflow && !(line.ws4Spacing && !alreadyOver)
            if full, !page.isEmpty {
                closePage()
                openNewPage()
                // organic overflow (see `recomputeGeom`'s doc comment): `line` itself is
                // the new page's first line and never reaches the top-of-case
                // `page.isEmpty` gate above, since `page` is not empty until closePage/
                // openNewPage runs right here, mid-iteration.
                if let bi = line.bi {
                    let (mt, mb, pl, hm, fm, po, poe, poo, orient) = recomputeGeom(bi)
                    curMt = mt
                    curMb = mb
                    curPl = pl
                    curHm = hm
                    curFm = fm
                    curPo = po
                    curPoe = poe
                    curPoo = poo
                    curOr = orient
                    capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                    budget = printedBudgetPt(doc, capacity: capacity, defaultLead: defaultLead,
                                             mtLines: mt, mbLines: mb, plLines: pl)
                }
            }
            // `.sb`: a blank line at the top of a page doesn't print.
            if suppressBlanks, page.isEmpty, isBlank(line) {
                continue
            }
            if let lc = lineCols(line), lc > 1, colGroupCols == 1 {
                // The group starts HERE: whatever this page has already spent is the
                // prefix every column of it shares.
                colGroupCols = lc
                colGroupIndex = 0
                colOffsetPt = spent
            }
            spent += cost(line)
            if let bi = line.bi {
                readTally[bi, default: 0] += 1
                readPos = PageReadPos(bi: bi, count: readTally[bi]!)
            }
            page.append(line)
        }
    }
    if stoppedEarly {
        // The open page is a partial page of content we deliberately stopped reading;
        // closing it would append a page that a full run would have filled further.
        // Everything below this line is end-of-document reasoning, and this is not the
        // end of the document.
        return pages
    }
    if !page.isEmpty {
        closePage()
    } else if case .pageBreak = items.last, doc.paEofBlankAfter {
        // #228 (research/2026-09-08_trailing-pa-rule.md, planning #228):
        // "WS7 opens the page after a forced `.pa` break ONLY when at
        // least one more real content paragraph -- even an entirely
        // blank one -- follows that `.pa` before end-of-file." The
        // document's last item was an explicit `.pa`, `page` is empty
        // by construction (reset when that pagebreak was processed
        // above, never touched since), and `doc.paEofBlankAfter`
        // (computed once at parse time from the file's own saved-
        // trailer bytes -- `trailingPaHasContentAfter` in ParseWS.swift)
        // confirms this specific document really did save a blank
        // paragraph after that `.pa`, not just a bare unconditional
        // pagebreak (the overwhelming majority of `.pa`-terminated
        // documents, which open no extra page at all).
        closePage(explicit: true, breakBI: doc.blocks.count - 1)
    }
    return pages
}

/// Whether a page line has nothing on it — no segments, or only whitespace. b24 round
/// 19 (RULINGS-LEDGER PIX row): an image PageLine has no text segments (`[]`, by
/// construction — see `resolvePlainBody`'s substitution), so `.image` must be checked
/// FIRST or an embedded picture sitting last in a short document (the real-corpus
/// shape: every acceptance document's own pix tag is its own final content) reads as a
/// trailing machine blank and gets silently popped off the page it was just placed on
/// (the PREVIEW.WS root-cause fix). Port of `_is_blank`.
private func isBlank(_ line: PageLine) -> Bool {
    line.image == nil && !line.contains { $0.text.contains { !$0.isWhitespace } }
}

/// Python's `str.isspace()`: non-empty and entirely whitespace. Note this is broader than
/// the split below, which is spaces only — a lone tab is a token the wrapper treats as
/// trailing whitespace but never split on. That asymmetry is Python's and is preserved.
private func isSpaceRun(_ text: String) -> Bool {
    // Swift's `Character.isWhitespace` follows Unicode White_Space, which EXCLUDES the
    // ASCII information separators 0x1C-0x1F; Python's `str.isspace()` includes them, and
    // they can reach a span via the 0x1B extended-character escape. Use the shared
    // Python-equivalent test so `_wrap_line`'s trailing-token pop trims the same tokens
    // Python's does.
    !text.isEmpty && text.isPythonSpaceOnly
}

/// Split into alternating runs of spaces and non-spaces, keeping both. Python's
/// `re.split(r'( +)', text)` minus the empty strings its edges produce.
///
/// Literal spaces only, matching the regex: a tab is part of the word it sits in, and gets
/// counted as one column like every other character.
func splitKeepingSpaceRuns(_ text: String) -> [String] {
    var pieces: [String] = []
    var run = ""
    var runIsSpace = false
    for char in text {
        let isSpace = char == " "
        if run.isEmpty {
            run.append(char)
            runIsSpace = isSpace
        } else if isSpace == runIsSpace {
            run.append(char)
        } else {
            pieces.append(run)
            run = String(char)
            runIsSpace = isSpace
        }
    }
    if !run.isEmpty {
        pieces.append(run)
    }
    return pieces
}

extension String {
    /// Column count for layout: Unicode scalars, which is what Python's `len` counts on the
    /// `str` this text was decoded into. Not `count` (grapheme clusters) — the two agree for
    /// everything CP437 can produce, and where they wouldn't, Python's answer is the one the
    /// vectors were generated with.
    ///
    /// Shared with the writer, which needs the same count for its x-advance (`len(text) *
    /// size * 0.6`, pdf.py:145). Python uses one `len` for both jobs and so should this —
    /// a wrapper that counted columns differently from the advance would lay out text to one
    /// width and paint it at another.
    var width: Int {
        unicodeScalars.count
    }
}
