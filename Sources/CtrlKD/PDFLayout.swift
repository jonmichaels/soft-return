/// The PDF emitter's layout half: IR -> pages of styled, wrapped lines. Port of `pdf.py`'s
/// `_wrap_line`, `_coalesce` and `_doc_to_pagelines` (pdf.py:18-30, 36-122).
///
/// This file holds the entry point (`docToPagelines`), Modern's pagination, the shared
/// finishing pass and line wrapping. The rest of the layout lives by job:
/// `PageModel` (the `Page`/`PageLine` types), `PrintedBody` (the one body walk both Printed
/// paginators read), `PrintedPagination` (the plain paginator), `PrintedNotes` (the
/// note-bearing paginator), `LineLeading`, `HeadFootReplay`, `Columns`, `PrintReformat`
/// (`.pf on`) and `PrintedPageGeometry` (sheet, capacity, numbering).
///
/// Everything here is pure and independent of PDF syntax — it decides what goes on which
/// page and where the line breaks fall, in characters and line counts, not points. The byte
/// writer (`_page_stream`, `emit_pdf`) attaches to the `[Page]` this produces and is the
/// only part that needs to know what a PDF looks like.
///
/// A WordStar document rendered as the typescript it was: Courier at 10 CPI and 6 LPI on
/// US Letter, which is why a 65-column line is exactly the 6.5 inches between the margins.

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
/// budget. `resolvePrintedBody`'s own block loops guarantee (by
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
    let pageNumbers = resolvePageNumbers(doc.pnTimeline(), pages)
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

// The bare-0x09 expansion this file's Printed pageline construction calls
// (`expandBareTabsForPrintedLayout`) moved to `EmitterRules.swift` by planning #264
// item 1 (packet row B3), where Printed RTF and the fixed-pitch HTML block call the
// same one. Same rule, same doc comment, same column-tracking semantics — see it there.

/// IR -> pages of laid-out lines. Port of `_doc_to_pagelines` (pdf.py:57-112) for Modern
/// mode; Printed mode is this project's own addition (job — period-authentic footnote
/// layout), since Python's `pdf.py` never modeled WordStar's real page-bottom footnote
/// area — it ran the same "collect at the end" logic in both modes. See
/// `layoutPrintedPages` (PrintedPagination.swift) for that half.
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
    // the pages it would not have built. One case where something does, which simply
    // paginates in full and slices at the end (correct, just not faster), and one that is
    // budgeted for:
    //
    //   a print stream   `finalizePages`' machine-margin strip is a MINIMUM over pages
    //                    2..n of the whole document. Fewer pages can only raise that
    //                    minimum, which would strip leading blanks off page 1 that a
    //                    full run keeps.
    //   columns          NOT excluded, but budgeted for: `applyColumns` folds n
    //                    sub-pages into one sheet, so the sub-page cap is n times the
    //                    caller's page count. `n` is the deepest `.co` the document
    //                    declares anywhere, which is an over-estimate and is meant to be.
    //
    // Plus one spare sub-page in every case, so the page the caller wants is never the
    // array's last and never meets `finalizePages`' own tail rules early.
    var rawPageCap: Int? = nil
    if let maxPages, maxPages > 0, printed, !isPrintStream {
        let widest = doc.blocks.compactMap { $0.columns }.max() ?? 1
        rawPageCap = maxPages * max(1, widest) + 1
    }
    func capped(_ pages: [Page]) -> [Page] {
        guard let maxPages, maxPages > 0, pages.count > maxPages else { return pages }
        return Array(pages.prefix(maxPages))
    }
    // Planning #250: resolved once, for the `printed` branch below (the
    // "zero real pages" fallback -- GALLEYS.DOT/ADVANCE.DOT) -- see
    // `parityResolvedFallbackHeadFoot`'s own doc comment.
    let fallback = parityResolvedFallbackHeadFoot(doc)
    if printed {
        var plainPages = applyColumns(doc,
            finalizePages(layoutPrintedPages(doc, pixResults: pixResults,
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
        attachGraphicCellsPrinted(doc, &plainPages, size: attachSize)
        attachDriverPiecesPrinted(doc, &plainPages, size: attachSize)
        attachLineNumbersPrinted(doc, &plainPages, size: attachSize)
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
/// Per-page numbers come from `resolvePageNumbers`/`pnTimeline` (register b31-dot-
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
    let pageNumbers = resolvePageNumbers(doc.pnTimeline(), pages)
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
    // both halves carry it -- see `resolvePrintedBody`, which carries it.
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
                                    separateSpans: false, printed: false)
                : footerEntryLines(note, doc: doc, index: i, width: PDFMetrics.maxCols,
                                   separateSpans: false, printed: false)
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
/// below — the "this document produced literally zero pages" case (`layoutPrintedPages`
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
    // `poTimeline`/`parityPoTimeline`/`leftForParity` machinery `closePage`
    // calls, at block 0 (the only anchor a document with no blocks can have).
    let bi = 0
    let docPo = doc.poTimeline().at(bi)
    let poe = doc.parityPoTimeline(dotName: "POE").atIfAny(bi)
    let poo = doc.parityPoTimeline(dotName: "POO").atIfAny(bi)
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
        while n < page.count, isBlankPageLine(page[n]) {
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
    // A last page made only of the document's own trailing blank lines is a page, not
    // padding: it prints its number (WS7 report 14.3, runs pg55b, pa3). It has no body line
    // left for the number to be looked up from once the blanks are dropped, so it is marked
    // like the empty page a trailing `.pa` opens (`explicitBreak`, which the trailing-page
    // pop below leaves alone). A DOCUMENT only -- a print stream's trailing blanks are the
    // machine's.
    let eofBlankBI: Int? = (stripBlanks && printed && !isPrintStream
                            && !pages[pages.count - 1].isEmpty
                            && pages[pages.count - 1].allSatisfy(isBlankPageLine))
        ? pages[pages.count - 1].eofBlankBI : nil
    if stripBlanks {
        for i in pages.indices {
            while let last = pages[i].last, isBlankPageLine(last) {
                pages[i].removeLast()
            }
        }
    }
    if let eofBlankBI {
        pages[pages.count - 1].explicitBreak = true
        pages[pages.count - 1].explicitBreakBI = eofBlankBI
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
    // `layoutPrintedPages`) is real WS7 output -- its footer/page
    // number prints even with no body -- and is exempt from this pop.
    while pages.count > 1, pages[pages.count - 1].isEmpty, !pages[pages.count - 1].explicitBreak {
        pages.removeLast()
    }
    return pages
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
