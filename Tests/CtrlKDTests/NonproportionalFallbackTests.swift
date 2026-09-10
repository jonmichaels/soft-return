import Testing
@testable import CtrlKD

/// Planning #252, Jon's ruling 2026-09-09 (verbatim, on the issue):
///
/// "...doesn't declare font proportionality, is Times in Modern in ctrl-kd and sr, and
/// Georgia 14 (or whatever is set in Settings). There's a setting in WS where it can
/// declare that fonts are not proportional. If that's the case, and no font block
/// exists, then it becomes Courier (or Courier Prime in macOS)."
///
/// The document-level setting is `.ps off` (WSFORMAT register C19, `Formatting2.swift`'s
/// `_parseFormatDot`-equivalent), which round 9 already parsed into
/// `doc.formatting.proportional` but deliberately left unconsumed for exactly this case —
/// round 9's own ruling covered only runs a REAL font block covers (`pdfFamily`'s
/// `entry.proportional == false`), which this round leaves untouched. This round gives
/// `.ps off` its first real consumer: the Modern fallback for a run NO font block covers,
/// in a document that declares fonts SOMEWHERE ELSE (a document with zero font blocks
/// anywhere stays Times/Georgia regardless of `.ps` — the ruling's own "no fonts -> Times,
/// unchanged"). Printed is untouched (its whole body is already Courier; `.ps` never
/// governed it and still doesn't).
///
/// Direct port of ctrl-kd's `test_modern_nonproportional_*` quartet
/// (`tests/test_ctrlkd.py`), exercising the Swift twins of the same three functions:
/// `modernTokFont` (`PDFModernLayout.swift`), `rtfBodySpan` (`EmitRTF.swift`), `htmlSpan`
/// (`EmitHTML.swift`).

/// A WS7 document with an optional `.ps on|off` declaration, an UNCOVERED first line (no
/// font block in force yet), then a real proportional Helvetica font block covering a
/// second line.
private func psDoc(_ ps: String?, styleBits: Int = 0x8000) -> [UInt8] {
    var data = ws7Block(0x00)
    if let ps { data += bytes(".ps \(ps)") + HARD }
    data += bytes("Uncovered first line.") + HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: styleBits)
    data += bytes("Covered second line.") + HARD
    return data
}

@Test func modernNonproportionalDeclaredGivesUncoveredRunCourier() throws {
    let doc = parseWS(psDoc("off"))
    #expect(doc.formatting.proportional == false)
    #expect(!doc.fonts.isEmpty)

    let pdf = emitPDF(doc, mode: .modern)
    let fonts = baseFonts(pdf)
    let shown = contentSpans(pdf)
    let cour = try #require(fonts.first { $0.value == "Courier" }?.key)
    let helv = try #require(fonts.first { $0.value == "Helvetica" }?.key)
    #expect(shown.contains { $0.font == cour && $0.size == 14 && $0.text == "Uncovered" })
    #expect(shown.contains { $0.font == helv && $0.size == 12 && $0.text == "Covered" })

    let rtf = emitRTF(doc, mode: .modern)
    #expect(rtf.contains(#"{\f1 Uncovered first line.}"#))   // \f1 == Courier New, always in \fonttbl

    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains(#"<span class="ws-nonprop">Uncovered first line.</span>"#))
    #expect(html.contains(#"ws-font-0">Covered second line."#))
}

@Test func modernProportionalOrUnsetKeepsTimesFallback() throws {
    // fonts-declared + proportional (`.ps on`) -- and fonts-declared with `.ps` never
    // set -- both leave the uncovered-run fallback at Times/Georgia, unchanged. Round
    // 9's own per-block rule (not this round) still decides the COVERED run's face.
    for ps: String? in ["on", nil] {
        let doc = parseWS(psDoc(ps))
        #expect(doc.formatting.proportional != false)

        let pdf = emitPDF(doc, mode: .modern)
        let fonts = baseFonts(pdf)
        let shown = contentSpans(pdf)
        let times = try #require(fonts.first { $0.value == "Times-Roman" }?.key)
        #expect(shown.contains { $0.font == times && $0.size == 14 && $0.text == "Uncovered" })

        let rtf = emitRTF(doc, mode: .modern)
        #expect(rtf.contains("{Uncovered first line.}"))   // no \fN control: inherits \f0 (Georgia)

        let html = emitHTML(doc, mode: .modern)
        #expect(!html.contains(#"class="ws-nonprop""#))
    }
}

@Test func modernNonproportionalDeclaredButNoFontsStaysTimes() throws {
    // The ruling's explicit carve-out: `.ps off` with NO font blocks anywhere in the
    // document changes nothing.
    var data = ws7Block(0x00)
    data += bytes(".ps off") + HARD + bytes("No font blocks anywhere at all.") + HARD
    let doc = parseWS(data)
    #expect(doc.formatting.proportional == false)
    #expect(doc.fonts.isEmpty)

    let pdf = emitPDF(doc, mode: .modern)
    let fonts = baseFonts(pdf)
    let shown = contentSpans(pdf)
    let times = try #require(fonts.first { $0.value == "Times-Roman" }?.key)
    #expect(shown.contains { $0.font == times && $0.size == 14 && $0.text == "No" })
    #expect(!shown.contains { fonts[$0.font] == "Courier" })

    let html = emitHTML(doc, mode: .modern)
    #expect(!html.contains(#"class="ws-nonprop""#))
    let rtf = emitRTF(doc, mode: .modern)
    #expect(rtf.contains("{No font blocks anywhere at all.}"))
}

@Test func modernNonproportionalFallbackNeverTouchesPrinted() throws {
    // Printed's own body face doctrine (Courier, the era's typescript) is untouched by
    // `.ps off` -- it always rendered fontless/uncovered text as Courier anyway, for a
    // completely different, pre-existing reason (round 9's Printed doctrine, not this
    // round).
    let docOff = parseWS(psDoc("off"))
    let docOn = parseWS(psDoc("on"))
    let pdfOff = emitPDF(docOff, mode: .printed)
    let pdfOn = emitPDF(docOn, mode: .printed)
    // Printed's own geometry differs only in the `.ps` dot line itself being a no-op
    // either way -- the two PDFs' text-showing operators for the two body lines must
    // carry identical text/font/size.
    let spansOff = contentSpans(pdfOff).map { ($0.font, $0.size, $0.text) }
    let spansOn = contentSpans(pdfOn).map { ($0.font, $0.size, $0.text) }
    #expect(spansOff.elementsEqual(spansOn, by: ==))
}
