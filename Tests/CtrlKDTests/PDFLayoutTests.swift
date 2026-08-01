import Testing
@testable import CtrlKD

/// job-011's own tests: the behavior the vectors don't reach.
///
/// The 15 vector cases in `VectorTests.swift` prove the layout against Python for five real
/// documents. What they cannot reach is anything those five documents don't contain — and
/// the page cap is the big one, since every vector document fits on one or two short pages
/// and none of them comes near 54 lines. The rest is the `EmitOutput` plumbing, which has no
/// Python counterpart to generate vectors from.

// MARK: - Pagination at the cap

/// A document of `n` single-word lines in one paragraph block.
private func linesDoc(_ n: Int) -> Document {
    Document(blocks: [Block(lines: (1...n).map { Line(spans: [Span(text: "line\($0)")]) })])
}

@Test func modernPaginatesAtFiftyFourLines() {
    // No vector document is longer than 7 lines, so the `page.count >= cap` branch — the
    // one that makes a long document a multi-page PDF at all — is unproven by all 10 of
    // them. 54 lines exactly fills page 1; the 55th starts page 2.
    let pages = docToPagelines(linesDoc(55), printed: false)
    #expect(pages.count == 2)
    #expect(pages[0].count == PDFMetrics.linesModern)
    #expect(pages[0].first?.first?.text == "line1")
    #expect(pages[0].last?.first?.text == "line54")
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line55")

    // And exactly 54, which is where the blank-sheet bug lived. Modern mode ends each block
    // with a blank line, so a full page of content pushes that blank onto page 2, where the
    // trailing-blank strip empties it — leaving a real empty second page. Python 1.1.5 tried
    // to pop it and popped too early to see it (job-012); 1.1.6 pops after the stripping and
    // this is one page, as it always should have been.
    #expect(docToPagelines(linesDoc(54), printed: false).map(\.count) == [54])
}

@Test func printedPaginatesAtSixtyLines() {
    // The printed cap is a different constant, and a port that used one for both would pass
    // every vector.
    #expect(docToPagelines(linesDoc(60), printed: true).count == 1)

    let pages = docToPagelines(linesDoc(61), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == PDFMetrics.linesPrinted)
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line61")
}

/// `linesDoc` with an explicit `PageGeometry`, exactly as `parseWS` produces for a real
/// file — nil `.page` (the case the other tests above cover) only happens for a bare
/// print-stream capture.
private func linesDoc(_ n: Int, page: PageGeometry) -> Document {
    Document(
        blocks: [Block(lines: (1...n).map { Line(spans: [Span(text: "line\($0)")]) })],
        page: page
    )
}

@Test func printedCapacityIsGeometricNotRawPL() {
    // The bug this test proves fixed: `printedPageCapacity` used to read the file's raw
    // declared `.pl` value (66 for a default Letter page) straight off as the line-break
    // threshold. Python's `_printed_cap` (pdf.py:55-60) instead resolves the page height in
    // POINTS from that geometry and derives lines from a fixed 72pt printed-mode margin --
    // 60 lines for that same Letter page, not 66. A `.pl 66` file (the common case: every
    // document that never sets `.pl` resolves to exactly this) must therefore still break
    // at 60, matching the untyped-geometry case `printedPaginatesAtSixtyLines` already
    // covers, even though this document's `page.plLines` is explicitly 66.
    let letter = PageGeometry(
        plLines: 66, heightIn: 11.0, sizeName: "Letter", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        poCols: 0, poSource: .default
    )
    #expect(docToPagelines(linesDoc(60, page: letter), printed: true).count == 1)
    let pages = docToPagelines(linesDoc(61, page: letter), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 60)
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line61")

    // A second, differently-sized page proves the geometry is actually being READ (not just
    // hardcoded back to 60): Legal, `.pl 84` -> height 14in -> (1008 - 72) / 12 = 78 lines,
    // not the raw 84 the pre-fix code would have used.
    let legal = PageGeometry(
        plLines: 84, heightIn: 14.0, sizeName: "Legal", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        poCols: 0, poSource: .default
    )
    #expect(docToPagelines(linesDoc(78, page: legal), printed: true).count == 1)
    let legalPages = docToPagelines(linesDoc(79, page: legal), printed: true)
    #expect(legalPages.count == 2)
    #expect(legalPages[0].count == 78)
    #expect(legalPages[1].count == 1)
}

@Test func printedCapacityFloorsOnDegenerateGeometry() {
    // A vanishingly small or absent page can never send the capacity below
    // `footnoteFloor + 1` (4) -- Python's own floor (pdf.py:53,60). Exercised at the
    // PageGeometry boundary rather than by reaching into the private floor constant.
    let tiny = PageGeometry(
        plLines: 1, heightIn: 0.01, sizeName: "Custom", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        poCols: 0, poSource: .default
    )
    #expect(docToPagelines(linesDoc(4, page: tiny), printed: true).count == 1)
    let pages = docToPagelines(linesDoc(5, page: tiny), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 4)
    #expect(pages[1].count == 1)
}

// MARK: - Page breaks

@Test func consecutivePageBreaksLeaveABlankPage() {
    // Python appends the current page on a break even when it is empty (`if page or l is
    // None`), so two `.pa` in a row cost a sheet of paper. The pagebreak vector has one
    // break between two paragraphs and cannot tell that apart from "skip empty pages".
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "first")])]),
        Block(kind: .pagebreak),
        Block(kind: .pagebreak),
        Block(lines: [Line(spans: [Span(text: "last")])]),
    ])
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 3)
    #expect(pages[0].first?.first?.text == "first")
    #expect(pages[1].isEmpty)
    #expect(pages[2].first?.first?.text == "last")
}

@Test func softPageIsPrintedOnlyPagination() {
    // WordStar's own pagination is honored in a facsimile and dropped when reflowing. Both
    // directions, because a port that ignored `printed` here would still pass one of them.
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "first")])]),
        Block(kind: .softpage),
        Block(lines: [Line(spans: [Span(text: "last")])]),
    ])
    #expect(docToPagelines(doc, printed: true).count == 2)
    #expect(docToPagelines(doc, printed: false).count == 1)
}

@Test func emptyDocumentIsOneEmptyPage() {
    // `pages or [[]]`. Reachable — an empty document is what a zero-length parse produces —
    // and the leading-blank pass indexes `pages[0]`, so getting this wrong is a crash, not
    // a wrong page.
    #expect(docToPagelines(Document(), printed: true) == [[]])
    #expect(docToPagelines(Document(), printed: false) == [[]])
    #expect(docToPagelines(Document(blocks: [Block()]), printed: true) == [[]])
}

// MARK: - The machine margin

@Test func lonePrintedPageFallsBackToItsOwnLeadingBlanks() {
    // With no page 2 to measure against, Python takes page 1's own leading count as the
    // machine margin — so a single-page print stream loses all its top blanks. Every
    // multi-page vector proves the `min(...)` half; this proves the fallback, which a port
    // could just as easily have written as "strip nothing".
    let doc = Document(blocks: [Block(lines: [
        Line(), Line(), Line(spans: [Span(text: "text")]),
    ])])
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1)
    #expect(pages[0].count == 1)
    #expect(pages[0][0].first?.text == "text")
}

@Test func chapterDropSurvivesOnlyWhatPagesTwoPlusAllow() {
    // The rule the job called the subtlest in the file, in its pure form: page 1 opens with
    // 5 blanks, page 2 with 2. Two of page 1's are the machine margin and go; three are the
    // author's chapter drop and stay.
    func page(blanks: Int, text: String) -> [Block] {
        [Block(lines: Array(repeating: Line(), count: blanks)
            + [Line(spans: [Span(text: text)])])]
    }
    let doc = Document(blocks: page(blanks: 5, text: "Chapter One")
        + [Block(kind: .pagebreak)]
        + page(blanks: 2, text: "continues"))

    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 4)                    // 3 surviving blanks + the text
    #expect(pages[0][0].isEmpty)
    #expect(pages[0][3].first?.text == "Chapter One")
    #expect(pages[1].count == 1)                    // both of page 2's blanks were machine
    #expect(pages[1][0].first?.text == "continues")

    // Modern mode has no machine margin to preserve against: it did the layout itself, so
    // every leading blank on every page goes — the drop does not survive a reflow. (The
    // line comes back through the wrapper, so it is three segments now, not one.)
    let modern = docToPagelines(doc, printed: false)
    #expect(modern[0].count == 1)
    #expect(modern[0][0].map(\.text).joined() == "Chapter One")
}

// MARK: - wrapLine / coalesce edges

@Test func wrapLineAlwaysReturnsALine() {
    // `if line or not lines` — an empty IR line wraps to one empty page line, not to no
    // lines at all, and the paragraph spacing in `docToPagelines` depends on it.
    #expect(wrapLine([], width: 65) == [[]])
    #expect(wrapLine([Span(text: "")], width: 65) == [[]])
    #expect(wrapLine([Span(text: "   ")], width: 65) == [[]])
}

@Test func wrapLineNeverBreaksMidWord() {
    // A word longer than the column overflows rather than being split — `col and` in the
    // guard means a token at column 0 is placed whatever its length.
    let long = String(repeating: "x", count: 30)
    #expect(wrapLine([Span(text: long)], width: 10) == [[Span(text: long)]])

    let got = wrapLine([Span(text: "ab \(long) cd")], width: 10)
    #expect(got.count == 3)
    #expect(got[0].map(\.text) == ["ab"])
    #expect(got[1].map(\.text) == [long])
    #expect(got[2].map(\.text) == ["cd"])
}

@Test func wrapLineCountsTabsAsCharactersNotSpaces() {
    // Python splits on `( +)` — literal spaces — but tests `isspace()`, which a tab passes.
    // So a tab inside a word is part of the word, and a span that is only a tab is a
    // whitespace token that gets stripped from the end of a line.
    #expect(wrapLine([Span(text: "a\tb")], width: 65) == [[Span(text: "a\tb")]])
    #expect(wrapLine([Span(text: "word"), Span(text: "\t")], width: 65)
            == [[Span(text: "word")]])
}

@Test func coalesceMergesOnlyAcrossEqualStyles() {
    #expect(coalesce([]) == [])
    // Same styles merge however many segments there are; a different style breaks the run,
    // and an identical style AFTER it starts a new one rather than rejoining the first.
    let line = [
        Span(text: "a", styles: .bold), Span(text: "b", styles: .bold),
        Span(text: "c"),
        Span(text: "d", styles: .bold),
    ]
    #expect(coalesce(line) == [
        Span(text: "ab", styles: .bold), Span(text: "c"), Span(text: "d", styles: .bold),
    ])
    // Style equality is by set, not by insertion order.
    #expect(coalesce([Span(text: "x", styles: [.bold, .italic]),
                      Span(text: "y", styles: [.italic, .bold])])
            == [Span(text: "xy", styles: [.bold, .italic])])
}

// MARK: - EmitOutput plumbing

/// A stand-in binary emitter — the shape `emit_pdf` will have in Job B.
private let fakeBinary = Emitter(name: "fake", ext: ".fake") { doc, _, _ in
    .data(Array("FAKE".utf8) + Array(doc.iterLines().map { $0.text() }.joined().utf8))
}

@Test func convertRefusesToStringifyABinaryFormat() throws {
    let registry = EmitterRegistry.standard.register(fakeBinary)
    let data = makeProse()

    #expect(throws: EmitError.binaryFormat(name: "fake", ext: ".fake")) {
        _ = try convert(data, to: "fake", registry: registry)
    }
    // convertData is the front door that serves both kinds.
    let out = try convertData(data, to: "fake", registry: registry)
    #expect(out.starts(with: Array("FAKE".utf8)))
}

@Test func convertDataEncodesTextFormatsAsUTF8() throws {
    // A text format through the data door is the same rendering, UTF-8 encoded — this is
    // what a save-to-disk caller gets, and it must not differ from what the preview showed.
    let data = makeProse()
    let text = try convert(data, to: "markdown")
    #expect(try convertData(data, to: "markdown") == Array(text.utf8))
}

@Test func emitOutputAccessorsAgree() {
    let text = EmitOutput.text("hi")
    #expect(text.asText == "hi")
    #expect(text.asBytes == Array("hi".utf8))
    #expect(!text.isBinary)

    let data = EmitOutput.data([0x25, 0x50])
    #expect(data.asText == nil)
    #expect(data.asBytes == [0x25, 0x50])
    #expect(data.isBinary)
}

@Test func builtInEmittersAllReportAsText() {
    // The `text:` convenience wraps each of the four; if one were registered raw and
    // returned `.data`, `convert` would start throwing for it.
    let doc = try! parse(makeProse())
    for name in ["text", "markdown", "html", "rtf"] {
        let emitter = EmitterRegistry.standard.getEmitter(name)
        #expect(emitter?.emit(doc, .modern, EmitOptions()).isBinary == false, "\(name)")
    }
}

// MARK: - Number formatting (Job B's writer needs these)

@Test func fixedOneDecimalMatchesPythonPercentF() {
    // Expected strings generated by Python: `'%.1f' % (tenths / 10)`. The list covers the
    // real coordinate domain (72 + n*7.2 and n*4.8 as tenths, page heights, the -1.5 and
    // +3 rule offsets) plus negatives, zero and randoms.
    let cases: [(Int, String)] = [
        (0, "0.0"), (1, "0.1"), (5, "0.5"), (9, "0.9"), (10, "1.0"), (15, "1.5"),
        (-15, "-1.5"), (720, "72.0"), (7920, "792.0"), (6900, "690.0"), (6885, "688.5"),
        (6930, "693.0"), (-1, "-0.1"), (-5, "-0.5"), (-720, "-72.0"), (4321, "432.1"),
        (792, "79.2"), (864, "86.4"), (936, "93.6"), (1008, "100.8"), (1080, "108.0"),
        (768, "76.8"), (816, "81.6"), (18589, "1858.9"), (46741, "4674.1"),
        (22068, "2206.8"), (18446, "1844.6"), (33128, "3312.8"), (53980, "5398.0"),
        (-50218, "-5021.8"), (-51592, "-5159.2"), (34194, "3419.4"), (24719, "2471.9"),
        (65120, "6512.0"), (60946, "6094.6"),
    ]
    for (tenths, want) in cases {
        #expect(fixedOneDecimal(tenths: tenths) == want, "tenths \(tenths)")
    }
}

@Test func zeroPaddedMatchesPythonPercent010d() {
    let cases: [(Int, String)] = [
        (0, "0000000000"), (1, "0000000001"), (9, "0000000009"), (42, "0000000042"),
        (-42, "-000000042"), (999, "0000000999"), (1234567890, "1234567890"),
        (12345678901, "12345678901"), (-1234567890, "-1234567890"),
        (99999, "0000099999"), (-1, "-000000001"),
    ]
    for (value, want) in cases {
        #expect(zeroPadded(value, width: 10) == want, "value \(value)")
    }
    // The width is a parameter even though the xref is the only caller today.
    #expect(zeroPadded(7, width: 3) == "007")
    #expect(zeroPadded(7, width: 0) == "7")
}

@Test func wrapLineMeasuresInUnicodeScalarsLikePython() {
    // Python's `len()` counts code points; Swift's `String.count` counts grapheme clusters.
    // The two only disagree on text CP437 cannot produce — all 256 of its bytes decode to
    // characters with no combining marks, checked against the codec — but `wrapLine` is
    // public, a hand-built Document can carry anything, and Python's answer is the one the
    // vectors were generated with.
    let text = "aa\u{301} bb"        // 6 scalars, 5 graphemes
    // At width 5, scalars put "bb" at column 4 and 4 + 2 > 5, so it wraps — which is what
    // Python does. Graphemes would put it at column 3, and 3 + 2 == 5 would keep one line.
    #expect(wrapLine([Span(text: text)], width: 5).count == 2)
}

// MARK: - Gaps the job-011 mutation run found

@Test func machineMarginIgnoresPageOnesOwnLeadingBlanks() {
    // Survivor from the first mutation run: `pages.dropFirst()` -> `pages`. The chapter-drop
    // vector cannot see the difference, because there page 1 has MORE leading blanks than
    // page 2 and the minimum is the same either way. This is the shape that separates them —
    // page 1 starts higher than the rest, so including it would understate the margin and
    // leave the machine blanks on every later page.
    //
    // Confirmed against the reference: pages of 1, 3 and 4 leading blanks strip to 1, 1 and
    // 2 lines — machine is 3, the minimum over pages 2+, not the 1 that page 1 would set.
    func blk(blanks: Int, text: String) -> Block {
        Block(lines: Array(repeating: Line(), count: blanks) + [Line(spans: [Span(text: text)])])
    }
    let doc = Document(blocks: [
        blk(blanks: 1, text: "first"), Block(kind: .pagebreak),
        blk(blanks: 3, text: "second"), Block(kind: .pagebreak),
        blk(blanks: 4, text: "third"),
    ])
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.map(\.count) == [1, 1, 2])
    #expect(pages[0][0].first?.text == "first")
    #expect(pages[1][0].first?.text == "second")
    #expect(pages[2][0].isEmpty)                    // the one blank beyond the machine margin
    #expect(pages[2][1].first?.text == "third")
}

@Test func aLineOfSpacesCountsAsBlank() {
    // Survivor from the first mutation run: `isBlank` -> `line.isEmpty`. Python asks whether
    // any segment has a non-whitespace character (`any(t.strip() ...)`), so a line holding a
    // single space-only span is blank and gets stripped like an empty one. Every vector
    // document's blanks are empty lines, so none of them can tell the two apart — but a real
    // print capture is full of space-padded lines.
    let doc = Document(blocks: [Block(lines: [
        Line(spans: [Span(text: "  ")]),
        Line(spans: [Span(text: "text")]),
        Line(spans: [Span(text: "   ")]),
    ])])
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1)
    #expect(pages[0].count == 1)                    // leading AND trailing space-lines gone
    #expect(pages[0][0].first?.text == "text")
}
