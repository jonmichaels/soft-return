import Testing
@testable import CtrlKD

/// job-012's named ports plus the gaps its vectors don't reach.
///
/// The 18 vector cases in `VectorTests.swift` include two COMPLETE PDFs compared byte for
/// byte, which is the strongest evidence in the suite — an object numbered wrong, a `/Length`
/// off by one, or a single xref offset shifted all fail it. What they can't do is say which
/// part broke, and they can't reach behavior neither document contains: the escaping of a
/// paren next to a backslash, a rule under whitespace, the four-way font selection. The
/// Python ports below are the named structural checks; the rest close those gaps.

// MARK: - the seven named ports from tests/test_ctrlkd.py

/// Python's `test_pdf_structure`.
@Test func pdfStructure() throws {
    let pdf = emitPDF(parseWS(makeProse()))
    #expect(pdf.starts(with: bytes("%PDF-1.4")))
    #expect(latin1(pdf).trimmed().hasSuffix("%%EOF"))
    #expect(countOccurrences(of: bytes("/Type /Page "), in: pdf) == 1)
    // The Courier four are ALWAYS allocated, used or not (`FontResources`).
    #expect(contains(pdf, bytes("/Courier")))
    // The text actually reached a content stream, escaped as a PDF string literal —
    // one word per Tj op under Modern's proportional reflow (ruling 2026-08-05), so
    // "Second paragraph." is two ops, not one string.
    #expect(contains(pdf, bytes("(Second)")))
    #expect(contains(pdf, bytes("(paragraph.)")))
}

/// Python's `test_pdf_pagebreak_makes_pages`.
@Test func pdfPagebreakMakesPages() throws {
    let data = bytes("Page one text here.") + HARD + bytes(".pa") + HARD
        + bytes("Page two text here.") + HARD
    let pdf = emitPDF(parseWS(data))
    // Note the trailing space in the needle: `/Type /Pages` would otherwise match too, and
    // this assertion is counting sheets of paper.
    #expect(countOccurrences(of: bytes("/Type /Page "), in: pdf) == 2)
}

/// Python's `test_pdf_styles_and_escaping`.
@Test func pdfStylesAndEscaping() throws {
    let bold: [UInt8] = [0x02]
    let underline: [UInt8] = [0x13]
    let data = bold + ws4Text("Bold (word)") + bold + bytes(" ")
        + underline + ws4Text("under") + underline + HARD
    let pdf = emitPDF(parseWS(data))
    #expect(contains(pdf, bytes("/F2")))            // Courier-Bold selected
    #expect(contains(pdf, bytes(#"\(word\)"#)))     // parens escaped
    #expect(contains(pdf, bytes(" l S")))           // underline stroked
}

/// Python's `test_pdf_via_cli_registry` — as a registry test, per the job spec.
@Test func pdfViaRegistry() throws {
    let emitter = try #require(EmitterRegistry.standard.getEmitter("pdf"))
    #expect(emitter.ext == ".pdf")
    let out = emitter.emit(parseWS(makeProse()), .modern, EmitOptions())
    // The registry's own contract, which Python has no way to express: a binary format comes
    // back as `.data`, so `asText` is nil and `isBinary` agrees.
    #expect(out.isBinary)
    #expect(out.asText == nil)
    #expect(out.asBytes.starts(with: bytes("%PDF-")))
    // And the whole reason `EmitOutput` exists: asking `convert` for a String must fail
    // rather than hand back mangled bytes.
    #expect(throws: EmitError.binaryFormat(name: "pdf", ext: ".pdf")) {
        _ = try convert(makeProse(), to: "pdf")
    }
}

/// Python's `test_pdf_chapter_drop_survives`.
@Test func pdfChapterDropSurvives() throws {
    // The machine top margin — blanks uniform across every page — is stripped; the author's
    // extra blank lines on page 1 (a chapter drop) survive. So page 1's first text sits
    // LOWER on the paper than page 2's, which in PDF coordinates means a smaller y.
    let page1 = HARD.repeated(8) + bytes("Chapter opening text here.") + HARD
    let page2 = HARD.repeated(2) + bytes("Second page text here.") + HARD
    let pdf = emitPDF(parsePrintstream(page1 + [0x0c] + page2), mode: .printed)

    let chapterY = try #require(baselineY(before: "(Chapter", in: pdf))
    let secondY = try #require(baselineY(before: "(Second", in: pdf))
    #expect(chapterY < secondY, "chapter drop should push page-1 text down the page")
    // Tenths, exactly, rather than only the inequality: page 2 starts at the top margin
    // (744.0) and page 1 is six lines of surviving chapter drop below it.
    #expect(secondY == 7440)
    #expect(chapterY == 7440 - 6 * PDFMetrics.lead * 10)
}

/// Python 1.1.5's `test_pdf_headings_render_bold` — the fix for this port's job-011 finding.
@Test func pdfHeadingsRenderBold() throws {
    // Heading level comes from the NAME the style handle resolves to in the document's
    // own library, never from the slot number, so the fixture carries a real library.
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil),
        (name: "WordStar Defaults", record: nil),
        (name: "MS Chapter Title", record: styleRecord()),
    ])
    // A style selection PERSISTS until the next one, so the fixture switches back to the
    // recordless base before the body — exactly what real documents do (NOVEL.WS
    // re-selects 'MS Body Copy' after every heading). Prose padding keeps the
    // block-heavy fixture detecting as ws5+, not binary (the documented small-fixture
    // trap).
    let data = documentWithStyleLibrary(
        body: styleRef(2) + bytes("Chapter One") + HARD + HARD
            + styleRef(1)
            + bytes("Body text here, at a perfectly ordinary length for a paragraph.") + HARD
            + bytes("A second sentence keeps the prose-to-binary ratio realistic.") + HARD,
        library: lib)
    let segments = docToPagelines(parseWS(data), printed: false).flatMap { $0 }.flatMap { $0 }
    // `wrapLine` tokenizes into words, so assert at segment granularity.
    #expect(segments.contains { $0.text == "Chapter" && $0.styles.contains(.bold) })
    #expect(segments.contains { $0.text == "Body" && !$0.styles.contains(.bold) })

    // Python's version stops at the layout. Carry it into the bytes too, which is where the
    // promise was made and where a reader sees it: the heading must select bold. Modern
    // PDF carries fonts now (ruling 2026-08-05) — a fontless bold heading reads in
    // Times-Bold at the sophisticated size (14pt), not Courier-Bold at 12pt, and each word
    // is its own Tj op under proportional reflow, not one combined string.
    // The x values carry the style's own left margin as a real Modern indent since M2
    // (ruling 2026-08-06: block margins are the document's explicit choices and win in
    // Modern exactly as its fonts do) — re-pinned against the live Python reference.
    let pdf = emitPDF(parseWS(data), mode: .modern)
    #expect(contains(pdf, bytes("/BaseFont /Times-Bold")))
    #expect(contains(pdf, bytes("BT /F5 14 Tf 0 Ts 144.0 703.2 Td (Chapter) Tj ET")))
    #expect(contains(pdf, bytes("BT /F5 14 Tf 0 Ts 197.3 703.2 Td (One) Tj ET")))
    #expect(contains(pdf, bytes("(realistic.)")))
}

/// Python 1.1.6's `test_pdf_exact_fill_no_blank_sheet` — the rewritten version.
///
/// The 1.1.5 original was ported here exactly, including the fact that it could not fail:
/// it fed `parse_ws` bytes that `detect` calls a print stream, which produce one page by a
/// different route, so `all(pg for pg in pages)` was trivially true on the unfixed code
/// (job-012). 1.1.6 replaced the input with real WS4 bytes through `parse()`, which is the
/// true exact-fill boundary — 54 entries of content on page 1, the final structural blank
/// spilling to page 2 — and pinned the premise (`variant == ws4`) so the test cannot quietly
/// stop testing what it says again.
@Test func pdfExactFillNoBlankSheet() throws {
    // 26 one-line paragraphs + a final paragraph long enough to wrap once = 54 lines.
    let n = (PDFMetrics.linesModern - 2) / 2
    var data: [UInt8] = []
    for i in 0..<n {
        data += ws4Text("Paragraph \(i) here today.") + HARD + HARD
    }
    data += ws4Text("This final paragraph is deliberately long enough that the "
                    + "wrap test must break it across two physical lines.") + HARD

    let doc = try parse(data)
    // Python asserts `doc.meta['variant'] == 'ws4'`; `meta` became typed fields in job-004.
    #expect(doc.detection?.variant == .ws4, "the test's own premise, pinned")
    let pages = docToPagelines(doc, printed: false)
    #expect(pages.map(\.count) == [PDFMetrics.linesModern])
}

// The 1.1.5 exact-fill fix was incomplete, and `exactFillStillLeavesABlankSheet` lived here
// recording that: the pop ran before the blank-stripping that empties the page, so the sheet
// came back. 1.1.6 moved the pop and the test's premise is now false, so it is gone rather
// than inverted in place — its fixtures live on in `PDFExactFillTests.swift` (job-013), where
// the same bytes that proved the bug now prove the fix.

// MARK: - the 1.1.5 layout fixes: gaps the mutation run found

@Test func headingBoldIsAddedToExistingStyles() {
    // `styles | {'b'}`, not `= {'b'}`. Every vector heading carries plain spans, so a port
    // that ASSIGNED bold instead of adding it passed all four layout cases while silently
    // dropping the italics off an italic heading. Confirmed against Python: ['b', 'i'].
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "Chapter", styles: .italic)])], heading: 1),
    ])
    let segments = docToPagelines(doc, printed: false).flatMap { $0 }.flatMap { $0 }
    #expect(segments.first?.styles == [.bold, .italic])
    // Modern PDF now carries fonts (ruling 2026-08-05): a fontless bold-italic heading
    // reads in Times-BoldItalic at the sophisticated size (14pt), not Courier-BoldOblique
    // at 12pt — the Courier-only Modern died with the WS4 lens. F5 is the first slot past
    // the Courier four (F1-F4), the only route there from a document with one font run.
    let pdf = latin1(emitPDF(doc, mode: .modern))
    #expect(pdf.contains("/BaseFont /Times-BoldItalic"))
    #expect(pdf.contains("/F5 14 Tf"))
}

@Test func trailingDoublePageBreakDoesNotLeaveABlankSheet() {
    // A `.pa .pa` at the very end appends a genuinely empty page, which the pop removes.
    // When this was written it was the pop's ONLY reachable case: at 1.1.5 the exact-fill
    // page the fix was actually written for held a blank LINE, so it still had a positive
    // count when the pop looked at it and slipped past. Without this test the pop could be
    // deleted outright and the suite stayed green. Since 1.1.6 moved the pop after the
    // stripping, both cases reach it — this one still earns its place as the path that needs
    // no stripping to be empty.
    //
    // Interior `.pa .pa` still costs a sheet: only the last page is popped. That direction
    // is `consecutivePageBreaksLeaveABlankPage` in the job-011 file.
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "text")])]),
        Block(kind: .pagebreak),
        Block(kind: .pagebreak),
    ])
    #expect(docToPagelines(doc, printed: true).count == 1)
    #expect(docToPagelines(doc, printed: false).count == 1)
    #expect(countOccurrences(of: bytes("/Type /Page "), in: emitPDF(doc, mode: .printed)) == 1)
}

// MARK: - esc gaps

@Test func escEscapesBackslashBeforeParens() {
    // The load-bearing half of `_esc`'s ordering. Escaping parens first would leave their
    // new backslashes for the backslash pass to double: `(` would come out as `\\(` — a
    // literal backslash and then an UNESCAPED paren, which closes the string early and
    // corrupts every operator after it. No vector case puts the two characters adjacent.
    #expect(latin1(esc(#"\("#)) == #"\\\("#)
    #expect(latin1(esc(#"a\(b)c"#)) == #"a\\\(b\)c"#)
    // The other ordering — cp1252 before escaping — is NOT observable, and this says why:
    // the replacement character is `?`, which can neither create nor consume an escape. So
    // there is no test for it; there is nothing to catch. (U+0141 Ł, not U+2014 em dash: an
    // em dash IS cp1252-representable since 2026-08-05 — see `escMatchesPythonVectors` —
    // so it no longer demonstrates a `?` replacement at all.)
    #expect(latin1(esc("(\u{0141})")) == #"\(?\)"#)
}

@Test func escLeavesOtherBytesAlone() {
    // Only three bytes are special in a PDF string literal as this writer spells them. In
    // particular \r and \n pass through raw — legal inside a literal, and no line of a
    // page-line ever contains one.
    #expect(latin1(esc("a\rb\nc\td")) == "a\rb\nc\td")
    #expect(latin1(esc("")) == "")
    // 0x80-0xFF survive as themselves: Latin-1 is the identity there, so a CP437-decoded
    // accent is one byte, not a '?'.
    #expect(esc("é") == [0xE9])
    #expect(esc("ÿ") == [0xFF])
    #expect(esc("\u{100}") == [0x3F])       // first scalar that does not fit
}

// MARK: - page_stream gaps

@Test func pageStreamSelectsAllFourCourierVariants() {
    // The vectors reach F1, F2 and F3 but never bold-italic, and a font table with two
    // entries transposed would pass all six of them.
    #expect(pdfFont(bold: false, italic: false) == "F1")
    #expect(pdfFont(bold: true, italic: false) == "F2")
    #expect(pdfFont(bold: false, italic: true) == "F3")
    #expect(pdfFont(bold: true, italic: true) == "F4")

    let line: Page = [[Span(text: "x", styles: [.bold, .italic])]]
    #expect(latin1(pageStream(line, top: 72)).contains("/F4 12 Tf"))
}

@Test func pageStreamSkipsRulesUnderWhitespaceOnlyRuns() {
    // Python guards both rules with `text.strip()`. Without it, an underlined space run —
    // which the wrapper produces whenever a styled span ends in a space — would draw a
    // stray dash between words.
    let spaces: Page = [[Span(text: "   ", styles: [.underline, .strike])]]
    let stream = latin1(pageStream(spaces, top: 72))
    #expect(!stream.contains(" l S"), "no rule under whitespace")
    #expect(stream.contains("(   ) Tj"), "but the run is still shown, and still advances x")

    // The advance happens even though no rule was drawn: the next run starts three
    // characters along, at 72.0 + 3 * 12 * 0.6 = 93.6.
    let then: Page = [[Span(text: "   ", styles: [.underline]), Span(text: "w")]]
    #expect(latin1(pageStream(then, top: 72)).contains("93.6 708.0 Td (w)"))
}

@Test func pageStreamEmptyRunEmitsNothingAndDoesNotAdvance() {
    // `if not text: continue` — an empty run must produce no operator at all, not an empty
    // `() Tj`.
    //
    // THE STYLES ON THE EMPTY SPAN ARE THE POINT. Written first with two unstyled spans, this
    // test could not fail: `coalesce` runs before the guard and merges same-style neighbours,
    // so `"" + "a"` became one `"a"` run and the empty span never reached the branch being
    // tested. Mutation testing caught that — deleting the guard changed nothing. Giving the
    // empty run a style of its own is what keeps `coalesce` from hiding it.
    let line: Page = [[Span(text: "", styles: .bold), Span(text: "a")]]
    #expect(latin1(pageStream(line, top: 72)) == "BT /F1 12 Tf 0 Ts 72.0 708.0 Td (a) Tj ET")

    // And the merge itself, so the reason above stays true: adjacent same-style runs are one
    // operator, which is what makes the empty-span case unreachable through `coalesce`.
    let merged: Page = [[Span(text: ""), Span(text: "a")]]
    #expect(latin1(pageStream(merged, top: 72)) == "BT /F1 12 Tf 0 Ts 72.0 708.0 Td (a) Tj ET")
}

@Test func pageStreamEmptyPageIsAnEmptyStream() {
    // Reachable, and the blank-sheet case above depends on it: `/Length 0`.
    #expect(pageStream([], top: 72).isEmpty)
    // A page of blank lines is also empty — no operators, but y still advances per line, so
    // this cannot be short-circuited by testing the page for content.
    #expect(pageStream([[], [], []], top: 72).isEmpty)
}

@Test func pageStreamAdvancesYByTheLeadPerLine() {
    // Three lines, so two decrements — a sign error or a missing decrement shows here.
    let page: Page = [[Span(text: "a")], [Span(text: "b")], [Span(text: "c")]]
    let ys = latin1(pageStream(page, top: 72)).split(separator: "\n").map {
        Swift.String($0.split(separator: " ")[7])
    }
    #expect(ys == ["708.0", "696.0", "684.0"])
}

@Test func pageStreamSupWinsOverSubWhenBothAreSet() {
    // Python's nested conditional resolves the contradiction toward `sup`; a span carrying
    // both is not something the parser produces, but the branch is there and asymmetric.
    let line: Page = [[Span(text: "x", styles: [.sup, .sub])]]
    #expect(latin1(pageStream(line, top: 72)).contains("/F1 8 Tf 3 Ts"))
}

// MARK: - emit_pdf gaps

@Test func emitPDFXrefOffsetsPointAtTheirObjects() {
    // The vectors pin the offsets as bytes; this checks the INVARIANT, which is what a
    // reader relies on and what a wrong `startxref` or an off-by-one in the ten-digit
    // padding would break. Every entry must land exactly on `N 0 obj`.
    let pdf = emitPDF(try! parse(makeProse()), mode: .modern)
    let text = latin1(pdf)
    let startxref = try! #require(text.components(separatedBy: "startxref\n").last?
        .components(separatedBy: "\n").first)
    let xrefAt = try! #require(Int(startxref))
    #expect(text.dropFirst(xrefAt).hasPrefix("xref\n"), "startxref must point at the table")

    // Parse the table back and follow every offset.
    let table = Swift.String(text.dropFirst(xrefAt)).components(separatedBy: "\n")
    let size = try! #require(Int(table[1].split(separator: " ")[1]))
    #expect(table[2] == "0000000000 65535 f ", "the free-list head, trailing space and all")
    for n in 1..<size {
        let entry = table[n + 2]
        // Ten digits, space, five digits, space, the type letter, and the trailing space:
        // nineteen, with the newline that was split off making PDF's fixed twenty.
        #expect(entry.unicodeScalars.count == 19,
                "entry \(n) is a fixed-width column: \(entry.debugDescription)")
        let offset = try! #require(Int(entry.prefix(10)))
        #expect(text.dropFirst(offset).hasPrefix("\(n) 0 obj\n"),
                "xref entry \(n) must point at object \(n)")
    }
    #expect(text.contains("/Size \(size) /Root 1 0 R"))
}

@Test func emitPDFObjectNumberingIsContiguousAndOrdered() {
    // Catalog 1, page tree 2, fonts 3-6, then a page/contents pair per page. Written in a
    // different order than numbered, then sorted — so a broken sort shows up as objects out
    // of sequence in the file, which is what this reads back.
    let data = bytes("one") + HARD + bytes(".pa") + HARD + bytes("two") + HARD
    let text = latin1(emitPDF(parseWS(data), mode: .modern))
    let numbers = text.components(separatedBy: " 0 obj\n").dropLast().map {
        Int($0.components(separatedBy: "\n").last!)
    }
    #expect(numbers == Array(1...10).map { Optional($0) }, "two pages -> objects 1...10")
    // The fonts are where the page/contents pairs start counting from.
    #expect(text.contains("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Courier"
        + " /Encoding /WinAnsiEncoding >>"))
    #expect(text.contains("6 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont"
        + " /Courier-BoldOblique /Encoding /WinAnsiEncoding >>"))
    #expect(text.contains("/Kids [7 0 R 9 0 R] /Count 2"))
    #expect(text.contains("/Contents 8 0 R"))
    #expect(text.contains("/Contents 10 0 R"))
}

@Test func emitPDFLengthMatchesEachStream() {
    // `/Length` is what a reader trusts to find `endstream`; a wrong one silently truncates
    // the page. Checked for every stream in a multi-page document with styles.
    let bold: [UInt8] = [0x02]
    let data = bold + ws4Text("Bold text here") + bold + HARD + bytes(".pa") + HARD
        + ws4Text("Second page of it") + HARD
    let text = latin1(emitPDF(parseWS(data), mode: .modern))
    var found = 0
    for chunk in text.components(separatedBy: "<< /Length ").dropFirst() {
        let declared = try! #require(Int(chunk.components(separatedBy: " >>").first!))
        // Split on the full delimiters, not on `stream\n` — `endstream\n` ends with it too,
        // and splitting on the short form swallows the terminator into the body.
        let body = chunk.components(separatedBy: " >>\nstream\n")[1]
        let actual = body.components(separatedBy: "\nendstream")[0]
        #expect(actual.unicodeScalars.count == declared,
                "declared \(declared), stream is \(actual.unicodeScalars.count)")
        found += 1
    }
    #expect(found == 2)
}

@Test func emitPDFEmptyDocumentIsStillAValidOnePagePDF() {
    // `pages or [[]]` means one empty page, so the file has a full object graph and an empty
    // content stream — not zero pages, which would be a PDF no reader will open.
    let text = latin1(emitPDF(Document(), mode: .modern))
    #expect(text.hasPrefix("%PDF-1.4\n"))
    #expect(text.hasSuffix("%%EOF\n"))
    #expect(text.contains("/Count 1"))
    #expect(text.contains("<< /Length 0 >>\nstream\n\nendstream"))
}

@Test func emitPDFHonoursPrintedModeAndTheDocumentsOwnVerdict() {
    // Two ways to reach the printed layout, and the top margin is how you tell: 792-36-12
    // = 744.0 printed. Modern's own geometry changed under the Modern-PDF rewrite (ruling
    // 2026-08-05): the first BASELINE is `PAGE_H - margt - lineHeight`, not `- size` — a
    // visual line's height is `1.2 x` its own type size (single-spacing), not the fixed
    // 12pt Courier lead — so fontless Times at the sophisticated 14pt gives
    // 792 - 72 - (1.2 * 14) = 703.2, not the old Courier-grid 708.0.
    let ws = parseWS(ws4Text("Some words here") + HARD)
    #expect(ws.detection?.variant == .ws4)
    #expect(latin1(emitPDF(ws, mode: .modern)).contains("72.0 703.2 Td"))
    // ctrl-kd 2.0.0: printed mode's left margin is now `.po`-derived, not the fixed 72pt
    // MARGIN this emitter used to guess. `ws` never sets `.po`/`.cw`, so it resolves to
    // the new defaults (8 columns at 10 CPI) -- 8 * 12 * 0.6 = 57.6pt, the WS7 manual's
    // ".8 inch" (PDFLayout.swift's `printedLeft`), not the old 72.0.
    #expect(latin1(emitPDF(ws, mode: .printed)).contains("57.6 744.0 Td"))

    // A print stream overrides `modern` — `isPrinted` wins, because reflowing a document
    // whose layout IS its content destroys it.
    let stream = parsePrintstream(bytes("Some words here") + HARD)
    #expect(isPrinted(stream))
    #expect(latin1(emitPDF(stream, mode: .modern)).contains("72.0 744.0 Td"))
}

@Test func emitPDFMediaBoxMatchesTheDocumentsOwnGeometryInPrintedMode() {
    // The bug this test proves fixed: `emitPDF` used to hardcode `PDFMetrics.pageHeight`
    // (792, Letter) into BOTH the MediaBox and the content stream's Y-origin regardless of
    // the document's own `.pl`-derived geometry -- so a custom-size page paginated at the
    // right (now-fixed, see PDFLayoutTests.swift) line count but was still drawn on, and
    // declared as, a Letter-size sheet. Geometry taken from a real short/custom page found
    // in the corpus gauntlet (`.pl` resolving to height 8.33in): `round(8.33 * 72) = 600`
    // points, not 792.
    let custom = PageGeometry(
        plLines: 49.98, heightIn: 8.33, sizeName: "Custom", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        // WordStar's own default (WS7 manual, ".8 inch") since ctrl-kd 2.0.0 -- this
        // fixture never sets `.po`/`.cw` in the file, so a real `parseWS` document would
        // resolve both to their defaults (8 columns, 12/120in), same as here.
        poCols: 8, poSource: .default,
        hmLines: 2, hmSource: .default, fmLines: 2, fmSource: .default,
        lh48: 8, lhSource: .default, ls: 1, lsSource: .default,
        cw120: 12, cwSource: .default,
        textLines: textLinesPerPage(pl: 49.98, mt: 3, mb: 8, lh48: 8)
    )
    let doc = Document(
        blocks: [Block(lines: [Line(spans: [Span(text: "line one")])])],
        page: custom
    )
    let text = latin1(emitPDF(doc, mode: .printed))
    #expect(text.contains("/MediaBox [0 0 612 600]"))
    #expect(!text.contains("/MediaBox [0 0 612 792]"))
    // Y-origin: (600 - printedTop(36, from the default .mt 3) - size(12)) = 552.0, not
    // modern's or Letter's 744.0. 36 here is `printedTop(doc)` landing on the same figure
    // the old fixed `topPrinted` constant always used, because `.mt 3` (the default) has
    // always resolved to exactly 36pt — not the constant itself, since ctrl-kd 1.3.0.
    // Left margin: ctrl-kd 2.0.0's `.po`-derived 57.6pt (8 * 12 * 0.6), not the old fixed
    // 72.0 this emitter used to guess (see `emitPDFHonoursPrintedModeAndTheDocumentsOwnVerdict`).
    #expect(text.contains("57.6 552.0 Td"))

    // Modern mode on the SAME document renders on the file's declared sheet too since
    // page size joined the model (2026-08-06, task #16) -- the custom 50-line page.
    let modernText = latin1(emitPDF(doc, mode: .modern))
    #expect(modernText.contains("/MediaBox [0 0 612 600]"))
}

// MARK: - byte-oriented test helpers

/// The `y` of the first `Td` whose text-showing operator starts with `marker`, in TENTHS of a
/// point — Python's test parses these as floats; tenths keep the comparison exact.
private func baselineY(before marker: String, in pdf: [UInt8]) -> Int? {
    for op in latin1(pdf).split(separator: "\n") where op.contains(" Td \(marker)") {
        let fields = op.split(separator: " ")
        guard let td = fields.firstIndex(of: "Td"), td >= 1 else { continue }
        let parts = fields[td - 1].split(separator: ".")
        guard parts.count == 2, let whole = Int(parts[0]), let tenth = Int(parts[1]) else {
            continue
        }
        return whole * 10 + tenth
    }
    return nil
}

extension Array {
    /// `HARD.repeated(8)` — Python's `b'\r\n' * 8`.
    func repeated(_ times: Int) -> [Element] {
        var out: [Element] = []
        for _ in 0..<times { out += self }
        return out
    }
}
