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

/// FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): the original version's
/// "expected" values were computed by calling `resolvedPageHeight`/`printedTop`/
/// `printedLead`/`printedSize`/`printedLeft`/`printedCap` directly -- the EXACT SAME calls
/// `printedMetrics` itself makes to build the struct under test (see `PrintedGeometry.swift`
/// -- `printedMetrics` is nothing but these six calls assembled into a struct literal), so
/// this could only ever fail if the struct literal transposed two fields; it could never
/// catch a wrong VALUE, because both sides always call the identical function. Pinned as
/// independent hand-derived literals instead (each with its derivation), doubling as the
/// "does the façade transpose any field" wiring check the original was after.
@Test func printedMetricsMatchTheEmittersOwnHelpers() {
    // Every figure moved off its default, so a stale copy of any one formula shows up.
    let doc = geoDoc(
        plLines: 84, heightIn: 14, sizeName: "Legal",
        mtLines: 5, poCols: 12, lh48: 6, cw120: 10, textLines: 71
    )
    let m = printedMetrics(doc)

    #expect(m.pageWidth == 612.0, "printed mode is always US Letter WIDTH regardless of sheet")
    #expect(m.pageHeight == 1008.0, "Legal, 14in * 72pt/in")
    // `mtLines: 5` -- `printedTop` reserves `.mt` alone (mechanism U, ctrl-kd commit
    // 26169cd; `.hm` is never added, `mtSource` explicit or default): 5 lines * 12pt/line
    // = 60pt.
    #expect(m.top == 60.0)
    // `.lh 6` (1/48in units) -> 6 * 1.5 = 9pt lead.
    #expect(m.lead == 9.0)
    // `.cw 10` is 12 CPI elite -> a 10pt font (cw * 1.0, the pitch formula documented on
    // `printedSize`).
    #expect(m.size == 10)
    // `.po` is a FIXED 7.2pt/column regardless of pitch (2026-08-20 dx finding): 12 * 7.2.
    #expect(m.left == 86.4)
    // `printedCap` reads `page.textLines` straight through (clamped to a 4-line floor,
    // `footnoteFloor + 1` -- nowhere near binding here) -- `geoDoc`'s own `textLines: 71`
    // argument, verbatim.
    #expect(m.capacity == 71)
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

    // `.po` is a FIXED 7.2pt/column, pitch-independent -- real WS7 PCL contradicts the
    // manual's ".CW determines the actual amount of indentation" clause (dx experiment
    // 2026-08-20, port of ctrl-kd ace279b). `cw120` varies below to prove `.left` does
    // NOT move with it.
    #expect(printedMetrics(geoDoc(poCols: 8, cw120: 12)).left == 8 * 7.2)   // 57.6
    #expect(printedMetrics(geoDoc(poCols: 12, cw120: 10)).left == 12 * 7.2) // 86.4, not 72.0
}

/// dx experiment 2026-08-20: real WS7 keeps `.po` at a fixed 7.2pt/column at both 10cpi
/// and 12cpi (PCL ESC&aH 576dp identical for `.po 8` at either pitch) -- the manual's
/// ".CW determines the actual amount of indentation" clause is contradicted by measured
/// bytes. Regression (port of ctrl-kd ace279b,
/// `test_printed_left_po_columns_are_pitch_independent`): 12cpi (`size: 10`) must not
/// shrink the left edge to 48pt.
@Test func printedLeftPoColumnsArePitchIndependent() {
    let doc = geoDoc(poCols: 8)
    #expect(abs(printedLeft(doc, size: 12) - 57.6) < 1e-9)
    #expect(abs(printedLeft(doc, size: 10) - 57.6) < 1e-9)
}

/// A print stream has no `page` at all (`parsePrintstream` reads no dot commands). The
/// emitter falls back to its fixed figures there; the façade must fall back identically
/// rather than crashing on the nil or inventing a default of its own.
///
/// FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): the original version
/// compared each fallback field to the literal SAME named constant (`PDFMetrics.topPrinted`
/// etc.) that `printedTop`/`printedLead`/`printedSize`/`printedLeft`'s own `guard let page
/// = doc.page else { return ... }` branches return — so if that constant's VALUE ever
/// changed, both sides of the comparison would move together and the test would keep
/// passing no matter what the number was; it could only ever catch a WIRING mistake (the
/// façade reading the wrong constant), never a wrong VALUE. Pinned here as independent
/// literals instead, each with its own derivation, so a change to `PDFMetrics` is a
/// reviewed diff against a real number, not a silent no-op.
@Test func printedMetricsFallBackForDocumentsWithoutPageGeometry() {
    let doc = Document(blocks: [Block(lines: [Line(spans: [Span(text: "x")])])])
    let m = printedMetrics(doc)

    #expect(doc.page == nil)
    // `.mt 3` (WordStar's own default top margin, WSCHANGE factory table) resolves to
    // exactly 36pt (3 lines * 12pt/line) -- see PDFMetrics.topPrinted's own doc comment.
    #expect(m.top == 36.0)
    // `.lh 8` (1/48in units) -> 8 * 1.5 = 12pt lead, WordStar's dot-matrix-standard 6 LPI.
    #expect(m.lead == 12.0)
    // `.cw 12` (10 CPI pica, the WS7 default) IS a 12pt font by the pitch formula
    // `printedMetricsTrackTheDocumentsOwnDotCommands` derives above (`cw * 1.0`).
    #expect(m.size == 12)
    // No `.po` to read -- the pre-2026-08-20 guess of a flat 1in (72pt) margin, kept as
    // the print-stream-only fallback (real WS7 `.po` measurement doesn't apply: a print
    // stream's own offset spaces are already in-band).
    #expect(m.left == 72.0)
    // US Letter, 11in * 72pt/in.
    #expect(m.pageHeight == 792.0)
}

// MARK: - Modern mode

/// Modern renders on the document's declared SHEET (Letter/Legal/A4 -- page size joined
/// the model 2026-08-06, task #16) but keeps its own 1in margins and metrics: the sheet
/// is the document's, the typography is Modern's. A `.po` never moves Modern's margin.
// FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): as above -- the original
// compared against the same named `PDFMetrics` constants `modernMetrics` itself returns
// verbatim, so a changed constant value could never be caught here. Independent literals,
// each derived in the comment.
@Test func modernMetricsIgnoreTheDocumentsGeometry() {
    let legal = modernMetrics(geoDoc(heightIn: 14, sizeName: "Legal", poCols: 20, cw120: 10))
    #expect(legal.pageHeight == 1008.0)                          // the file's own sheet
    #expect(legal.left == 72.0, "1in margin, not .po-derived")   // Modern's own fixed margin
    #expect(legal.top == 72.0, "1in top margin")
    // (792 - 2*72) / 12 = 54 lines/page at Modern's fixed 1in margins and 12pt lead.
    #expect(legal.capacity == 54)
    #expect(legal.size == 12, "Modern's own Courier figure, 12pt/6 LPI dot-matrix standard")
}
