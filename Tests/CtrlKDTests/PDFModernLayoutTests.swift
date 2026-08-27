import Testing
@testable import CtrlKD

/// Modern PDF as the printed form of Modern RTF (ruling 2026-08-05, CLI-Defaults-Audit).
/// Direct port of `test_modern_pdf_is_the_printed_modern_rtf` and
/// `test_modern_pdf_page_bottom_footnotes` (`tests/test_ctrlkd.py`).

@Test func modernPDFIsThePrintedFormOfModernRTF() throws {
    // Document fonts carried (base-14 mapped), fontless body Times 14, footnotes at the
    // page bottom behind the 20-dash separator, the Courier four still always allocated.
    let pdf = emitPDF(parseWS(makeProse()), mode: .modern)
    #expect(contains(pdf, bytes("/BaseFont /Times-Roman")))
    #expect(contains(pdf, bytes(" 14 Tf")))
    #expect(contains(pdf, bytes("/BaseFont /Courier")))
    #expect(contains(pdf, bytes("Tf 0 Ts")))

    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helvTypestyle(), points: 18.0, styleBits: 0x8000, width: 250)
    data += bytes("Styled in a real face.") + HARD
    let pdf2 = emitPDF(parseWS(data), mode: .modern)
    #expect(contains(pdf2, bytes("/BaseFont /Helvetica")))
    #expect(contains(pdf2, bytes("18 Tf")))
}

@Test func modernPDFPageBottomFootnotes() throws {
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("The referenced line")
    data += ws7Note(bytes("A note that lands at the page bottom."), number: 0)
    data += bytes(" continues after.") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    #expect(!doc.notes.isEmpty)
    let pdf = emitPDF(doc, mode: .modern)
    #expect(contains(pdf, bytes(String(repeating: "-", count: 20))))   // the 20-dash separator
    #expect(contains(pdf, bytes("(bottom.)")))

    // Note text renders word-per-op; check words, and that they sit BELOW the body
    // (page-bottom = smaller y than every body line — PDF y increases upward).
    let shown = contentSpans(pdf)
    let noteY = try #require(shown.first { $0.text == "bottom." }?.y)
    let bodyY = try #require(shown.first { $0.text.contains("referenced") }?.y)
    #expect(noteY < bodyY)
}
