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
public struct PageLine: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
                        ExpressibleByArrayLiteral, Hashable, Sendable {
    public var spans: [Span]
    public var lead: Double?
    /// Bare-CR `^PM` Overprint Line: the NEXT `PageLine` prints at THIS one's own
    /// baseline. `false` by construction for every line this emitter MAKES (footnote
    /// areas, wrapped Modern text, blank fillers) — only a printed-mode body line
    /// carries WordStar's own flag.
    public var overprint: Bool

    public init() {
        spans = []
        lead = nil
        overprint = false
    }

    public init(_ spans: [Span], lead: Double? = nil, overprint: Bool = false) {
        self.spans = spans
        self.lead = lead
        self.overprint = overprint
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

/// One paginated page: a collection of `PageLine`s, plus the running head and foot IN
/// FORCE when this page printed (replayed from `Document.hfEvents`). Port of Python's
/// `Page(list)`.
///
/// A struct that behaves as a collection of `PageLine` for the same reason `PageLine`
/// itself is one: every existing consumer iterates a page as a sequence of lines and
/// keeps working untouched, while new code can ask for `.headers`/`.footers`.
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

    public init() {
        lines = []
        headers = [:]
        footers = [:]
    }

    public init(_ lines: [PageLine], headers: [Int: String] = [:], footers: [Int: String] = [:]) {
        self.lines = lines
        self.headers = headers
        self.footers = footers
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
func keepSpanOnPageline(_ span: Span, refNotes: [Note]) -> Bool {
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
/// THE FONT RUN IS PART OF THE MERGE TEST, added with printed-mode base-14 fonts
/// (`PDFFonts.swift`): two adjacent spans set in different faces are not the same run, and
/// merging them would set the second one in the first one's font. Python gets this free —
/// its font index rides in the same `frozenset` as the style codes, so its `styles ==
/// styles` covers both — and this comparison is that equality written out. A document with
/// no font runs has `nil` on every span and is unaffected, which is why no fontless byte
/// changed.
public func coalesce(_ line: PageLine) -> PageLine {
    var out = PageLine([], lead: line.lead)     // the merge changes segments, never the lead
    for span in line {
        if let last = out.last, last.styles == span.styles, last.font == span.font,
           last.colour == span.colour, last.pctlHMI == span.pctlHMI {
            out[out.count - 1].text += span.text
        } else {
            out.append(span)
        }
    }
    return out
}

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
/// - Returns: at least one page, possibly a single empty one.
public func docToPagelines(_ doc: Document, printed: Bool) -> [Page] {
    let isPrintStream = doc.detection?.variant == .printstream
    if printed {
        if hasPlaceableNotes(doc) {
            return finalizePages(layoutPrintedPages(doc), printed: true,
                                 isPrintStream: isPrintStream)
        }
        return finalizePages(layoutPrintedPagesPlain(doc), printed: true,
                             isPrintStream: isPrintStream)
    }
    return finalizePages(layoutModernPages(doc), printed: false, isPrintStream: isPrintStream)
}

/// Modern mode: unchanged from the original Python-parity port. Reflows every line to
/// `maxCols` and collects footnotes at
/// the very end under one 20-dash rule using the flattened `doc.footnotes` view — the
/// shape this project shipped before the period-authentic Printed layout existed, and
/// which Printed mode below no longer shares.
private func layoutModernPages(_ doc: Document) -> [Page] {
    enum LayoutItem {
        case line(PageLine)
        case pageBreak
        /// `.cp n` — resolved by the page-filling loop below, the only thing that knows
        /// how full the page is.
        case condPage(Int)
    }

    let refNotes = inlineReferenceNotes(doc)
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
            let extra = (block.heading != 0 ? Style.bold : []).union(block.styleAttrs)
            let spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes) }
                .map { extra.isEmpty ? $0 : Span(text: $0.text, styles: $0.styles.union(extra),
                                                 font: $0.font) }
            items.append(contentsOf: wrapLine(spans, width: PDFMetrics.maxCols)
                .map(LayoutItem.line))
        }
        if !block.lines.isEmpty {
            items.append(.line([]))                           // blank line between paragraphs
        }
    }

    // Footnotes collect at the end under a 20-dash rule, numbered to match the `fnref`
    // spans in the text.
    if !doc.footnotes.isEmpty {
        items.append(.line([]))
        items.append(.line([Span(text: String(repeating: "-", count: 20))]))
        items.append(.line([]))
        for (i, note) in doc.footnotes.enumerated() {
            let text = "[\(i + 1)] " + note.map(\.text).joined()
            items.append(contentsOf: wrapLine([Span(text: text)], width: PDFMetrics.maxCols)
                .map(LayoutItem.line))
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
private func finalizePages(_ rawPages: [Page], printed: Bool, isPrintStream: Bool) -> [Page] {
    var pages = rawPages
    if pages.isEmpty {
        return [[]]                                           // Python's `pages or [[]]`
    }

    func leading(_ page: Page) -> Int {
        var n = 0
        while n < page.count, isBlank(page[n]) {
            n += 1
        }
        return n
    }

    if printed, isPrintStream {
        // `min` runs over pages 2+, falling back to page 1's own count when there is no
        // page 2: Python's `if len(pages) > 1 else`.
        let machine = pages.dropFirst().map(leading).min() ?? leading(pages[0])
        for i in pages.indices {
            pages[i].removeFirst(min(machine, leading(pages[i])))
        }
    } else if !printed {
        for i in pages.indices {
            pages[i].removeFirst(leading(pages[i]))
        }
    }
    // else (printed, a DOCUMENT not a print stream): keep every leading blank -- it is
    // authorial, not the machine's -- and fall straight through to the trailing strip.
    for i in pages.indices {
        while let last = pages[i].last, isBlank(last) {
            pages[i].removeLast()
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
    while pages.count > 1, pages[pages.count - 1].isEmpty {
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
    case line(PageLine, due: [Note])
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

/// The marker text a `fnref` span (or a footer/endnote entry) displays for one note.
///
/// Delegates to `noteLabel` and must keep doing so. This used to reimplement the same
/// rule and drifted from it: where `noteLabel` falls back to the note's position when
/// `Note.number` is nil (a real outcome — the tag word's high bit means the file never
/// resolved a number), this used `?? 0`, so EVERY unnumbered note of a kind rendered with
/// the SAME marker. Two different footnotes both showed "1", inline and in the footer.
/// The flat emitters were correct; only this lane was wrong, and no vector caught it
/// because none exercises a nil number in printed mode.
private func noteMarker(_ note: Note, doc: Document) -> String {
    noteLabel(note, doc: doc)
}

/// The footer entry for one footnote/annotation, wrapped to `width` — factory-default
/// marks: `1.` (trailing period) for a footnote, the bare tag for an annotation.
private func footerEntryLines(_ note: Note, doc: Document, width: Int) -> [PageLine] {
    let text: String
    switch note.kind {
    case .footnote: text = "\(noteMarker(note, doc: doc)). \(note.text)"
    case .annotation: text = "\(noteMarker(note, doc: doc)) \(note.text)"
    default: text = note.text                 // unreached: endnotes/comments never queue here
    }
    return wrapLine([Span(text: text)], width: width)
}

/// The true-end-of-document entry for one endnote — factory-default mark `(1)`.
private func endnoteEntryLines(_ note: Note, doc: Document, width: Int) -> [PageLine] {
    wrapLine([Span(text: "(\(noteMarker(note, doc: doc))) \(note.text)")], width: width)
}

/// Blocks -> printed body items, fixing up every `fnref` span's displayed text along the
/// way. The parser numbers EVERY `fnref` sentinel (footnote, endnote, and annotation alike,
/// in document order — comments never get one) with one shared counter, so a span's raw
/// text is only a position, not a display value: the n-th `fnref` span corresponds to the
/// n-th non-comment `Note`, and that correspondence — not the span's own text — is what
/// decides what actually prints. A `fnref` with no corresponding note (more sentinels than
/// notes — malformed input, or a stray control byte the parser mistook for one) is left as
/// found rather than crashing or dropping it; `stray_sentinel` is exactly this case.
private func resolvePrintedBody(_ doc: Document) -> [PrintedBodyItem] {
    // ALL kinds are numbered by the parser's shared counter since M9 (comments
    // included), so the cursor walks all of `doc.notes`; a comment consumes its
    // position and renders NOTHING — never printed: no ink, no ref.
    let referenced = inlineReferenceNotes(doc)
    var cursor = 0
    var items: [PrintedBodyItem] = []

    for block in doc.blocks {
        // An explicit `.pa` is honored verbatim in a facsimile. WordStar's own 0x0B
        // end-of-page marks are NOT breaks -- see `Line.softpage`.
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        for line in block.lines {
            let extra = (block.heading != 0 ? Style.bold : []).union(block.styleAttrs)
            let baseSpans = extra.isEmpty
                ? line.spans
                : line.spans.map { Span(text: $0.text, styles: $0.styles.union(extra),
                                        font: $0.font) }

            var outSpans: [Span] = []
            var due: [Note] = []
            for span in baseSpans {
                guard span.styles.contains(.fnref), cursor < referenced.count else {
                    outSpans.append(span)
                    continue
                }
                let note = referenced[cursor]
                cursor += 1
                if note.kind == .comment {
                    continue                     // never printed: no ink, no ref (M9)
                }
                outSpans.append(Span(text: noteMarker(note, doc: doc), styles: span.styles,
                                     font: span.font))
                if note.kind == .footnote || note.kind == .annotation {
                    due.append(note)
                }
            }
            // A PageLine, not a bare list of spans, so the line's own `.lh` survives the
            // footnote paginator too — body lines keep their lead whether or not the
            // document has notes.
            items.append(.line(PageLine(outSpans, lead: leadPt(line.lead48),
                                        overprint: line.overprint), due: due))
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
private let footnoteFloor = 3

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
func roundHalfToEven(_ x: Double) -> Int {
    let whole = Int(x)
    let fraction = x - Double(whole)
    if fraction < 0.5 { return whole }
    if fraction > 0.5 { return whole + 1 }
    return whole % 2 == 0 ? whole : whole + 1
}

/// Resolved page height, in points, for THIS document — the general form of Python's
/// `_resolved_page_height(doc, printed)` (pdf.py:42-53). `PDFWriter.swift`'s `emitPDF` needs
/// this too (the MediaBox and the content stream's Y-origin must agree with the capacity
/// this same figure drives, or a custom-geometry page paginates correctly but still gets
/// drawn on/labeled as a Letter-size sheet) so this is `internal`, not `private`.
///
/// Modern mode always renders at the fixed US Letter height regardless of file geometry —
/// Printed is the faithfulness mode; Modern's whole point is a page that's simply pleasant
/// to read, not a facsimile of the original's paper size.
func resolvedPageHeight(_ doc: Document, printed: Bool) -> Int {
    printed ? resolvedPrintedPageHeight(doc) : PDFMetrics.pageHeight
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
    let heightIn = doc.page?.heightIn ?? 11.0
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

/// Top-of-text offset in points for printed mode. Port of Python's `_printed_top` (pdf.py,
/// ctrl-kd 1.3.0). WS documents start where `.mt` says (lines at 6 LPI -> 12pt each; the
/// default `.mt 3` is the 36pt this emitter always used, so every existing document's output
/// is unaffected). Print streams (no `page` meta) keep the fixed 36pt — their own top-margin
/// blanks are in the data (minus the machine-margin strip in `docToPagelines`). Clamped
/// inside the page so garbage `.mt` from a misdetected binary degrades to an ugly page,
/// never an absurd coordinate space. Deliberately measured against the FIXED `PDFMetrics.lead`
/// (not `printedLead(doc)`) — this is a page-geometry clamp, not a line-spacing one.
func printedTop(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.topPrinted }
    let pageHeight = resolvedPrintedPageHeight(doc)
    return max(0, min(roundHalfToEven(page.mtLines * 12), pageHeight - PDFMetrics.lead))
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

/// Type size in points for printed mode, from `.cw`: character width in 1/120in units,
/// and Courier advances 0.6em, so a pitch of cw/120in per character IS a
/// `(cw*72/120)/0.6 = cw*1.0` point font. The default `.cw 12` (10 CPI pica) IS the 12pt
/// this emitter always used; `.cw 10` is 12 CPI elite at 10pt. Rounded to whole points
/// (the `Tf` operator is written as an integer, as it always has been), floored at 1.
/// Print streams keep the fixed `SIZE`. Port of Python's `_printed_size` (pdf.py, ctrl-kd
/// 2.0.0).
func printedSize(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.size }
    let cw = page.cw120
    return cw > 0 ? max(1, roundHalfToEven(cw)) : PDFMetrics.size
}

/// Left edge of text in points for printed mode, from `.po`: "the number of print
/// columns from the left edge of the paper to the left margin of text. The current
/// setting of character width (.CW) determines the actual amount of indentation" — so
/// the offset is `po` columns at this document's own advance (0.6em of `size`). The
/// default `.po 8` (the WS7 manual's ".8 inch" at 10 CPI) lands at 57.6pt — NOT the old
/// fixed 72pt `MARGIN`, which was this emitter's guess, not WordStar's. Print streams
/// keep `MARGIN`: their offset spaces, where a driver emitted them, are in-band. Clamped
/// inside the page for garbage `.po` from misdetected binaries. Port of Python's
/// `_printed_left` (pdf.py, ctrl-kd 2.0.0).
func printedLeft(_ doc: Document, size: Int) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.margin) }
    let left = page.poCols * Double(size) * 0.6
    return max(0.0, min(left, Double(PDFMetrics.pageWidth) - Double(size) * 0.6))
}

/// How many lines the WHOLE queue would need if nothing were split — the figure the body
/// loop checks before it's allowed to stop growing the page past the 3-line floor. Overhead
/// is 2 lines (a blank, then the 20-dash rule) when something precedes the footer on the
/// page, or just the rule when the footer opens a page of its own (the top-of-page case).
private func footerFullSize(_ queue: [QueuedNote], leadingBlank: Bool) -> Int {
    guard !queue.isEmpty else { return 0 }
    let overhead = leadingBlank ? 2 : 1
    return overhead + queue.reduce(0) { $0 + 1 + $1.remaining.count }   // +1 blank per note
}

/// Fit as much of `queue` as `room` lines allow, mutating it to hold only what's left.
///
/// `leadingBlank` is `false` exactly for the top-of-a-fresh-page placement (rule 5): nothing
/// precedes the footer there, so the "one blank line above the separator" has nothing to
/// separate FROM and is dropped; every other call passes `true`.
///
/// The hang this guards against (see the job brief's "a hang the Python version shipped
/// with"): splitting a note costs the NEXT page one line for `...Continued...`, so a split
/// only makes net progress when at least 2 lines fit — at exactly 1, the Python version
/// admitted one line and immediately owed a `...Continued...` back, forever, on a page small
/// enough to reach it. The fix: split only when room for the note is >= 2; when it is not
/// AND the footer area on this page is still completely empty (nothing queued has printed
/// here yet), force through `min(remaining.count, 2)` lines anyway — the page overflows by a
/// line or two, which is preferable to a hang or to losing the text outright. Once the area
/// has printed something, there is no need to force: the page has already made progress, and
/// the rest gets a fresh, fully-sized attempt on the next page.
internal func fitFooter(queue: inout [QueuedNote], room: Int, leadingBlank: Bool) -> [PageLine] {
    guard !queue.isEmpty else { return [] }

    let overhead: [PageLine] = leadingBlank
        ? [[], [Span(text: String(repeating: "-", count: 20))]]
        : [[Span(text: String(repeating: "-", count: 20))]]

    // Bottom-of-page: if not even the separator fits, defer the whole queue to the next
    // page's bottom footer rather than print a headerless orphan. (Never done for the
    // top-of-page case: there is no "next page's bottom footer" to defer to there without
    // repeating the same shortfall forever — see the forcing branch below instead.)
    if leadingBlank, room < overhead.count {
        return []
    }

    var out = overhead
    var budget = room - overhead.count            // may go negative only via the forced path

    while !queue.isEmpty {
        var chunk: [PageLine] = []
        if queue[0].needsContinuedMarker {
            chunk.append([Span(text: footerContinuedLine)])
        }
        chunk.append(contentsOf: queue[0].remaining)
        let needed = 1 + chunk.count               // +1 for the blank line ahead of the note

        if needed <= budget {
            out.append([])
            out.append(contentsOf: chunk)
            budget -= needed
            queue.removeFirst()
            continue
        }

        let avail = budget - 1                     // room for content once that blank is paid
        let areaStillEmpty = out.count == overhead.count   // nothing queued has printed yet

        let take: Int
        if avail >= 2 {
            take = avail
        } else if areaStillEmpty {
            take = min(chunk.count, 2)              // the hang fix: force progress
        } else {
            break                                   // already made progress; defer the rest
        }

        out.append([])
        out.append(contentsOf: chunk.prefix(take))
        // However many of `take` came from the synthetic `...Continued...` line (at most
        // one, always first) don't count against the note's own remaining text.
        let markerTaken = (queue[0].needsContinuedMarker && take > 0) ? 1 : 0
        queue[0].remaining.removeFirst(min(take - markerTaken, queue[0].remaining.count))
        if queue[0].remaining.isEmpty {
            queue.removeFirst()
        } else {
            queue[0].needsContinuedMarker = true
        }
        break                                        // one split (forced or not) ends the page
    }

    return out
}

/// IR -> pages, WordStar's own way: verbatim body lines, a page-bottom footer for footnotes
/// and annotations that grows to fit (splitting across pages when it can't, per
/// `fitFooter`), and endnotes collected with no heading at the very end. See the section
/// comment above for the rule numbering this follows.
private func layoutPrintedPages(_ doc: Document) -> [Page] {
    let items = resolvePrintedBody(doc)
    let width = PDFMetrics.maxCols
    let capacity = printedCap(doc)

    var queue: [QueuedNote] = []
    var pages: [Page] = []
    var idx = 0

    while idx < items.count {
        var body: [PageLine] = []
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
                if capacity - body.count < n, !body.isEmpty {
                    break bodyLoop
                }
            case .line(let line, let due):
                let additions = due.map {
                    QueuedNote(remaining: footerEntryLines($0, doc: doc, width: width),
                               needsContinuedMarker: false)
                }
                let projected = queue + additions
                let footerFull = footerFullSize(projected, leadingBlank: true)
                // Rule 3: the first three lines of body are unconditional; past that, a
                // line is only added while it (plus everything the footer would need in
                // full) still fits the page.
                if body.count < 3 || body.count + 1 + footerFull <= capacity {
                    body.append(line)
                    queue.append(contentsOf: additions)
                    idx += 1
                } else {
                    break bodyLoop
                }
            }
        }

        let remaining = max(0, capacity - body.count)
        let footer = fitFooter(queue: &queue, room: remaining, leadingBlank: true)
        // This paginator never replays `hfEvents` (unchanged since before this port,
        // matching Python's dedicated `_paginate_printed_notes`, also untouched): every
        // page instead carries the document's FINAL-state headers/footers, the same
        // fallback `runningOps` applies when a page's own dict is empty.
        pages.append(Page(body + footer, headers: doc.headers, footers: doc.footers))
    }

    // Rule 5: whatever the last body page's bottom footer couldn't hold prints at the TOP
    // of its own fresh page(s) instead of waiting for a "next page" that doesn't exist.
    //
    // PROGRESS GUARD. This loop's termination used to depend entirely on `fitFooter`
    // consuming at least one queued line per call, with nothing checking that it did. On
    // 2026-07-31 a regression in `fitFooter` made it consume nothing at `capacity == 3`;
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
        let page = fitFooter(queue: &queue, room: capacity, leadingBlank: false)
        let linesAfter = queue.reduce(0) { $0 + $1.remaining.count }

        if linesAfter >= linesBefore {
            // No progress. Emit the page we just built, then flush the rest verbatim so
            // nothing is lost, and leave the loop.
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
            break
        }
        pages.append(Page(page, headers: doc.headers, footers: doc.footers))
    }

    // Endnotes: the true end of the document, no heading, no separator — plain pagination,
    // one blank line between entries (the same vertical rhythm as the footer area), nothing
    // before the first.
    let endnotes = doc.notes.filter { $0.kind == .endnote }
    if !endnotes.isEmpty {
        var lines: [PageLine] = []
        for (i, note) in endnotes.enumerated() {
            if i > 0 { lines.append([]) }
            lines.append(contentsOf: endnoteEntryLines(note, doc: doc, width: width))
        }
        var page = Page([], headers: doc.headers, footers: doc.footers)
        for line in lines {
            if page.count >= capacity {
                pages.append(page)
                page = Page([], headers: doc.headers, footers: doc.footers)
            }
            page.append(line)
        }
        if !page.isEmpty {
            pages.append(page)
        }
    }

    return pages
}

/// One body item for the PLAIN (no placeable notes) printed paginator.
private enum PlainBodyItem {
    case pageBreak
    /// `.cp n` — resolved by the pagination loop below, the only thing that knows how
    /// full the page is.
    case condPage(Int)
    case line(PageLine)
    /// A `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, replayed at the block it precedes.
    case hf(kind: HFKind, line: Int, text: String)
}

/// Blocks -> plain body items, with `doc.hfEvents` replayed at the block each one
/// precedes. Port of the printed-mode half of Python's `_doc_to_pagelines` block walk —
/// used only when `hasPlaceableNotes(doc)` is false (the notes-aware paginator above
/// handles the other case, and never replays `hfEvents` — see `Page`).
private func resolvePlainBody(_ doc: Document) -> [PlainBodyItem] {
    let refNotes = inlineReferenceNotes(doc)
    var hfByBlock: [Int: [(HFKind, Int, String)]] = [:]
    for event in doc.hfEvents {
        hfByBlock[event.blockAnchor, default: []].append((event.kind, event.line, event.text))
    }
    var items: [PlainBodyItem] = []
    for (bi, block) in doc.blocks.enumerated() {
        for (kind, line, text) in hfByBlock[bi] ?? [] {
            items.append(.hf(kind: kind, line: line, text: text))
        }
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        // Printed mode renders PHYSICAL lines verbatim — a soft return broke the line
        // on paper, so it stays broken here.
        let extra = (block.heading != 0 ? Style.bold : []).union(block.styleAttrs)
        for line in block.lines {
            let spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes) }
                .map {
                    extra.isEmpty ? $0
                        : Span(text: $0.text, styles: $0.styles.union(extra), font: $0.font,
                               colour: $0.colour, pctlHMI: $0.pctlHMI)
                }
            items.append(.line(PageLine(spans, lead: leadPt(line.lead48),
                                        overprint: line.overprint)))
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
/// `(cap - 1)` leads at the document default — the first line sits at the top, each
/// following line spends its own lead — which makes a uniform-lead document paginate
/// EXACTLY as the old line-count did, so no fontless byte moves. Overprint lines spend
/// no lead at all, on paper and here.
///
/// The running head/foot IN FORCE on a page is replayed from `doc.hfEvents` rather than
/// read from the document's final state: WordStar applies a running head from the page
/// where it is defined — on that page itself only if no text has printed there yet,
/// else from the next page.
private func layoutPrintedPagesPlain(_ doc: Document) -> [Page] {
    let items = resolvePlainBody(doc)
    let capacity = printedCap(doc)
    let defaultLead = printedLead(doc)
    let budget = Double(capacity - 1) * defaultLead

    var pages: [Page] = []
    var page: [PageLine] = []
    var spent = 0.0
    var curHeaders: [Int: String] = [:]
    var curFooters: [Int: String] = [:]
    var pageHeaders: [Int: String] = [:]     // state at the OPEN page's start
    var pageFooters: [Int: String] = [:]

    func cost(_ line: PageLine) -> Double {
        guard let last = page.last else { return 0.0 }     // first line on page is free
        if last.overprint { return 0.0 }                   // this line shares a baseline
        return line.lead ?? defaultLead
    }
    func closePage() {
        pages.append(Page(page,
                          headers: pageHeaders.filter { !$0.value.isEmpty },
                          footers: pageFooters.filter { !$0.value.isEmpty }))
    }
    func openNewPage() {
        page = []
        spent = 0.0
        pageHeaders = curHeaders
        pageFooters = curFooters
    }

    for item in items {
        switch item {
        case .hf(let kind, let line, let text):
            if kind == .header { curHeaders[line] = text } else { curFooters[line] = text }
            if page.isEmpty {          // nothing printed on this page yet
                pageHeaders = curHeaders
                pageFooters = curFooters
            }
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            let room = (budget - spent) / defaultLead
            if room < Double(n), !page.isEmpty {
                closePage()
                openNewPage()
            }
        case .pageBreak:
            // Always closes -- even an empty page, which IS a blank sheet (`.pa .pa`).
            closePage()
            openNewPage()
        case .line(let line):
            let full = spent + cost(line) > budget + 1e-6
            if full, !page.isEmpty {
                closePage()
                openNewPage()
            }
            spent += cost(line)
            page.append(line)
        }
    }
    if !page.isEmpty {
        closePage()
    }
    return pages
}

/// Whether a page line has nothing on it — no segments, or only whitespace.
private func isBlank(_ line: PageLine) -> Bool {
    !line.contains { $0.text.contains { !$0.isWhitespace } }
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
