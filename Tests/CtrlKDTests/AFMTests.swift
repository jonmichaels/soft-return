/// The Adobe Core 14 widths landed intact.
///
/// `AFM.swift` is generated (`Scripts/generate-afm.py`) precisely so that nobody hand-copies
/// 3,328 numbers, but "generated" is only a promise until something checks the output. These
/// are the figures Adobe publishes for the faces, quoted in the generator's own provenance
/// note — if the transcription ever slipped a column or a table, they are what says so.
import Testing
@testable import CtrlKD

@Test func afmWidthsMatchAdobesPublishedFigures() {
    #expect(stringWidth1000("A", "Helvetica") == 667)
    #expect(stringWidth1000(" ", "Helvetica") == 278)
    #expect(stringWidth1000("A", "Times-Roman") == 722)
    #expect(stringWidth1000(" ", "Times-Roman") == 250)
    // Symbol is indexed by the font's OWN encoding: 0x61 is alpha, not 'a'.
    #expect(stringWidth1000("a", "Symbol") == 631)

    // Courier is 600 for every glyph in all four weights — that is what makes it land on
    // WordStar's grid by construction rather than by correction.
    #expect(stringWidth1000("Hello", "Courier") == 5 * afmCourierWidth)
    #expect(stringWidth1000("Hello", "Courier-BoldOblique") == 5 * afmCourierWidth)
    #expect(afmWidths.count == 14)               // the base-14, all of it

    // Slant does not change advance: the oblique faces share the roman tables, which the
    // generator established by comparing values rather than assuming it.
    #expect(stringWidth1000("Wg,", "Helvetica-Oblique") == stringWidth1000("Wg,", "Helvetica"))
    #expect(stringWidth1000("Wg,", "Helvetica-BoldOblique")
        == stringWidth1000("Wg,", "Helvetica-Bold"))
    // ...but a real italic IS a different face, and Times' is.
    #expect(stringWidth1000("Wg,", "Times-Italic") != stringWidth1000("Wg,", "Times-Roman"))
}

@Test func afmMeasuresTextAsThePDFWillWriteIt() {
    // `esc` encodes Latin-1 and replaces everything else with '?', so measuring the string
    // as-is would count a character the PDF never receives. U+0100 is the first scalar that
    // does not fit; it must measure as one question mark.
    #expect(stringWidth1000("\u{100}", "Helvetica") == stringWidth1000("?", "Helvetica"))
    #expect(stringWidth1000("é", "Helvetica") == 556)      // 0xE9, in the table, not a '?'

    // Points, at a size: 1/1000 em times the size.
    #expect(stringWidthPt("AAAA", "Helvetica", 12) == 4.0 * 667.0 * 12.0 / 1000.0)

    // A face the tables do not carry cannot be measured; 600 is this emitter's own default
    // pitch, not a guess at the missing face.
    #expect(stringWidth1000("abc", "Bembo") == 3 * afmCourierWidth)
}
