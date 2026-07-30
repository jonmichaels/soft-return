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
/// `linesModern`, `linesPrinted` and `maxCols` are DERIVED in Python (pdf.py:23-25) and
/// literal here, per the job spec. `MAX_COLS` is the reason: it reads
/// `int((612 - 144) / (12 * 0.6))`, which is `int(468 / 7.199999999999999)` = `int(65.0000…)`
/// = 65 — the answer survives the float only because the truncation lands on the right side
/// of it. Recomputing that in Swift would be reproducing an accident, so the accident's
/// result is written down instead and the vectors pin it.
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
    public static let topModern = 72
    public static let topPrinted = 36
    /// Lines per page: `(pageHeight - 2 * top) / lead`.
    public static let linesModern = 54
    public static let linesPrinted = 60
    /// Text-column width in characters — WordStar's own margin, arrived at independently.
    public static let maxCols = 65
}

/// One laid-out line: styled segments, wrapped and ready to place. Spans are the IR's
/// text-plus-styles pair and are exactly what a segment is, so this is that type and not a
/// second one — the difference is only that a `PageLine`'s spans have been through the
/// wrapper and never contain a line break.
public typealias PageLine = [Span]

/// One page of laid-out lines, top to bottom.
public typealias Page = [PageLine]

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
            tokens.append(Span(text: piece, styles: span.styles))
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
public func coalesce(_ line: PageLine) -> PageLine {
    var out: PageLine = []
    for span in line {
        if let last = out.last, last.styles == span.styles {
            out[out.count - 1].text += span.text
        } else {
            out.append(span)
        }
    }
    return out
}

/// IR -> pages of laid-out lines. Port of `_doc_to_pagelines` (pdf.py:57-112).
///
/// - Parameters:
///   - doc: the parsed document.
///   - printed: line-for-line facsimile (`true`) or reflowed to the text column (`false`).
///     The emitter decides this from the mode and `isPrinted(doc)`; it is a parameter here
///     so the layout can be tested both ways against one document.
/// - Returns: at least one page, possibly a single empty one.
public func docToPagelines(_ doc: Document, printed: Bool) -> [Page] {
    /// A line, or the instruction to start a new page. Python threads this through a single
    /// list using `None` as the page-break marker (pdf.py:59), which works because a page
    /// line is always a list there. In Swift the same trick would be `[PageLine?]`, where
    /// "optional line" says nothing about what the `nil` means and every reader has to go
    /// find the comment. An enum with a named case says it in the type.
    enum LayoutItem {
        case line(PageLine)
        case pageBreak
    }

    var items: [LayoutItem] = []
    for block in doc.blocks {
        // A soft page is WordStar's own pagination: honored in a facsimile, ignored when
        // reflowing, where our own line cap repaginates from scratch.
        if block.kind == .pagebreak || (block.kind == .softpage && printed) {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .softpage {
            continue
        }
        for line in block.lines {
            // The module docstring's "headings bold" promise, unimplemented until Python
            // 1.1.5 (found by this port, job-011). Bold is added to EVERY span in a heading
            // block, not substituted: a span already italic stays italic and becomes
            // bold-italic, which is why this is a union and not an assignment.
            let spans = block.heading != 0
                ? line.spans.map { Span(text: $0.text, styles: $0.styles.union(.bold)) }
                : line.spans
            if printed {
                items.append(.line(spans))                    // verbatim, no wrap
            } else {
                items.append(contentsOf: wrapLine(spans, width: PDFMetrics.maxCols)
                    .map(LayoutItem.line))
            }
        }
        if !printed, !block.lines.isEmpty {
            items.append(.line([]))                           // blank line between paragraphs
        }
    }

    // Footnotes collect at the end under a 20-dash rule, numbered to match the `fnref`
    // spans in the text. Wrapped in both modes — a facsimile's footnotes were at the foot
    // of their own page in 1990, and reproducing that would mean laying out twice.
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

    let cap = printed ? PDFMetrics.linesPrinted : PDFMetrics.linesModern
    var pages: [Page] = []
    var page: Page = []
    for item in items {
        switch item {
        case .pageBreak:
            // Unconditional, even for an empty page: two `.pa` commands in a row leave a
            // blank page, which is what the author asked for. (Python's `if page or l is
            // None` is that same "or None" clause.)
            pages.append(page)
            page = []
        case .line(let line):
            if page.count >= cap {
                pages.append(page)
                page = []
            }
            page.append(line)
        }
    }
    if !page.isEmpty {
        pages.append(page)
    }
    // Content that exactly fills a page pushed an empty page out of the loop above — a blank
    // sheet. Explicit interior blanks from `.pa .pa` are preserved: only the LAST page is
    // popped, and only while there is more than one.
    //
    // KNOWN INCOMPLETE, and deliberately so — this reproduces Python 1.1.5 (pdf.py:95-96)
    // including the fact that it does not finish the job. The pop runs HERE, before the
    // blank-stripping below, but stripping is itself capable of emptying the last page: a
    // page holding nothing but blank lines survives this loop with a positive count and is
    // hollowed out afterwards, so the blank sheet comes back. `parse(exact-fill bytes)` in
    // modern mode still lands a trailing empty page at 1.1.5, and the job-012 vectors pin
    // that outcome — moving the pop after the stripping loop would fix the bug and fail the
    // vectors. Parity first; reported to Athena for 1.1.6.
    while pages.count > 1, pages[pages.count - 1].isEmpty {
        pages.removeLast()
    }
    if pages.isEmpty {
        return [[]]                                           // Python's `pages or [[]]`
    }

    // We supply the paper margins, so WordStar's own margin blanks in a print stream would
    // double up. But deliberate spacing (a chapter-drop on page 1) must survive: the MACHINE
    // margin is uniform on every page, so strip only the minimum leading-blank count seen on
    // pages 2+ — anything beyond it on any page is the author's layout. Trailing blanks are
    // always machine.
    func leading(_ page: Page) -> Int {
        var n = 0
        while n < page.count, isBlank(page[n]) {
            n += 1
        }
        return n
    }

    // The machine margin, or `nil` when there is none to protect — in modern mode we did the
    // layout ourselves, so every leading blank on a page is ours and all of them go.
    //
    // `min` runs over pages 2+, falling back to page 1's own count when there is no page 2:
    // `min()` of an empty sequence is `nil` on exactly that case, which is Python's
    // `if len(pages) > 1 else` written as one expression.
    let machine: Int? = printed
        ? (pages.dropFirst().map(leading).min() ?? leading(pages[0]))
        : nil
    for i in pages.indices {
        let blanks = leading(pages[i])
        pages[i].removeFirst(machine.map { min($0, blanks) } ?? blanks)
        while let last = pages[i].last, isBlank(last) {
            pages[i].removeLast()
        }
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
    !text.isEmpty && text.allSatisfy(\.isWhitespace)
}

/// Split into alternating runs of spaces and non-spaces, keeping both. Python's
/// `re.split(r'( +)', text)` minus the empty strings its edges produce.
///
/// Literal spaces only, matching the regex: a tab is part of the word it sits in, and gets
/// counted as one column like every other character.
private func splitKeepingSpaceRuns(_ text: String) -> [String] {
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
