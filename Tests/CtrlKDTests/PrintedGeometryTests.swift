import Testing
@testable import CtrlKD

/// `PrintedGeometry.swift` is a façade over the PDF emitter's internal metrics, added so
/// Soft Return.app can draw the Printed page at the same coordinates `emitPDF` writes it.
/// Its whole value is that agreement, so that is what these tests pin: every field must
/// equal the internal helper it delegates to, for documents whose dot commands actually
/// move the figures. A test that only checked "returns 792" would pass just as happily
/// against a copied formula that had since drifted — which is the failure this file exists
/// to make impossible.

/// A document carrying explicit page geometry. Defaults match WordStar's own
/// (`.pl 66`/`.mt 3`/`.mb 8`/`.po 8`/`.lh 8`/`.cw 12`) so each test can vary one figure.
private func geoDoc(
    plLines: Double = 66, heightIn: Double = 11, sizeName: String = "Letter",
    mtLines: Double = 3, mbLines: Double = 8, poCols: Double = 8,
    lh48: Double = 8, cw120: Double = 12, textLines: Int = 55
) -> Document {
    Document(
        blocks: [Block(lines: [Line(spans: [Span(text: "body")])])],
        page: PageGeometry(
            plLines: plLines, heightIn: heightIn, sizeName: sizeName, sizeSource: .file,
            mtLines: mtLines, mtSource: .file, mbLines: mbLines, mbSource: .file,
            poCols: poCols, poSource: .file, hmLines: 2, hmSource: .default,
            fmLines: 2, fmSource: .default, lh48: lh48, lhSource: .file,
            ls: 1, lsSource: .default, cw120: cw120, cwSource: .file,
            textLines: textLines
        )
    )
}

// MARK: - The façade agrees with the emitter, field by field

@Test func printedMetricsMatchTheEmittersOwnHelpers() {
    // Every figure moved off its default, so a stale copy of any one formula shows up.
    let doc = geoDoc(
        plLines: 84, heightIn: 14, sizeName: "Legal",
        mtLines: 5, poCols: 12, lh48: 6, cw120: 10, textLines: 71
    )
    let m = printedMetrics(doc)

    #expect(m.pageHeight == Double(resolvedPageHeight(doc, printed: true)))
    #expect(m.top == Double(printedTop(doc)))
    #expect(m.lead == printedLead(doc))
    #expect(m.size == printedSize(doc))
    #expect(m.left == printedLeft(doc, size: printedSize(doc)))
    #expect(m.capacity == printedCap(doc))
    #expect(m.pageWidth == Double(PDFMetrics.pageWidth))
}

@Test func printedMetricsTrackTheDocumentsOwnDotCommands() {
    // Not just "equal to the helper" — the values must actually be the file's, so a helper
    // that ignored `page` entirely would fail here even though the test above passed.
    let legal = printedMetrics(geoDoc(heightIn: 14, sizeName: "Legal", textLines: 71))
    let letter = printedMetrics(geoDoc())
    #expect(legal.pageHeight == 14 * 72)
    #expect(letter.pageHeight == 11 * 72)
    #expect(legal.capacity == 71)
    #expect(letter.capacity == 55)

    // `.cw 10` is 12 CPI elite: a 10pt face, 6pt pitch.
    let elite = printedMetrics(geoDoc(cw120: 10))
    #expect(elite.size == 10)
    #expect(elite.charWidth == 6.0)

    // `.cw 12` is 10 CPI pica: 12pt, and a pitch of "7.2pt" that is NOT literally 7.2 —
    // `12 * 0.6` is 7.199999999999999 in binary floating point. This is the same accident
    // PDFLayout.swift's header documents for `MAX_COLS`, where the truncation happens to
    // land on the right side of it. Asserted as the expression rather than the decimal so
    // this test says what the arithmetic does instead of what it looks like it should do.
    let pica = printedMetrics(geoDoc())
    #expect(pica.size == 12)
    #expect(pica.charWidth == 12 * 0.6)
    #expect(abs(pica.charWidth - 7.2) < 1e-9)

    // `.lh` is 1/48in; a point is 1/72in; so lead is `lh48 * 1.5`.
    #expect(printedMetrics(geoDoc(lh48: 6)).lead == 9.0)
    #expect(printedMetrics(geoDoc(lh48: 8)).lead == 12.0)

    // `.po` is columns at THIS document's advance, not a fixed margin.
    #expect(printedMetrics(geoDoc(poCols: 8, cw120: 12)).left == 8 * 12 * 0.6)   // 57.6
    #expect(printedMetrics(geoDoc(poCols: 12, cw120: 10)).left == 12 * 10 * 0.6) // 72.0
}

/// A print stream has no `page` at all (`parsePrintstream` reads no dot commands). The
/// emitter falls back to its fixed figures there; the façade must fall back identically
/// rather than crashing on the nil or inventing a default of its own.
@Test func printedMetricsFallBackForDocumentsWithoutPageGeometry() {
    let doc = Document(blocks: [Block(lines: [Line(spans: [Span(text: "x")])])])
    let m = printedMetrics(doc)

    #expect(doc.page == nil)
    #expect(m.top == Double(PDFMetrics.topPrinted))
    #expect(m.lead == Double(PDFMetrics.lead))
    #expect(m.size == PDFMetrics.size)
    #expect(m.left == Double(PDFMetrics.margin))
    #expect(m.pageHeight == Double(PDFMetrics.pageHeight))
}

// MARK: - Modern mode

/// Modern renders on the document's declared SHEET (Letter/Legal/A4 -- page size joined
/// the model 2026-08-06, task #16) but keeps its own 1in margins and metrics: the sheet
/// is the document's, the typography is Modern's. A `.po` never moves Modern's margin.
@Test func modernMetricsIgnoreTheDocumentsGeometry() {
    let legal = modernMetrics(geoDoc(heightIn: 14, sizeName: "Legal", poCols: 20, cw120: 10))
    #expect(legal.pageHeight == 1008.0)                          // the file's own sheet
    #expect(legal.left == Double(PDFMetrics.margin))             // 72, not .po-derived
    #expect(legal.top == Double(PDFMetrics.topModern))
    #expect(legal.capacity == PDFMetrics.linesModern)
    #expect(legal.size == PDFMetrics.size)
}
