import Testing
@testable import CtrlKD

/// Mechanism G's proportional half (planning #259, 2026-09-10). LYING.WS's own
/// footnote-marker residual: WS7 advances +1.64pt more than this engine at the
/// transition out of a superscript footnote marker ('Prize.¹' then the next word).
///
/// Unlike Courier (`SupSubFixedPitchTests.swift`, mechanism G's fixed-pitch half), real
/// WS7's raw PCL for a PROPORTIONAL sup/sub span does NOT reselect pitch -- LYING.pcl's own
/// ESC(s...T pair shows the SAME Pitch field ("1", an unused placeholder) in both the body
/// (`...s1p12vsb4101T`) and the marker (`...s1p8vsb4101T`); only the Height field changes,
/// 12v -> 8v. So a proportional span's own `factor` (`faceTz`'s Tz scale, the constant that
/// lands the substitute face's average glyph on the font block's own declared pitch) is a
/// property of the FONT BLOCK, not of any one span's drawn size -- exactly mechanism G's own
/// principle, just manifesting through `faceTz` instead of a flat pitch multiply. Before this
/// fix, the proportional branch computed `factor` from the marker's OWN reduced `pt` (8),
/// asking an 8pt-average reference glyph to stretch up to the pitch a 12pt-declared font
/// block wants -- LYING's own entry (width1800=137) inflated `want` from a correct 101.12%
/// to 151.69%, landing the sup '1' at 6.07pt, ~1.5x its natural 4.0pt advance (confirmed
/// directly against ctrl-kd's own `tools/fidelity_gate.py --dump-engine-chars` on LYING.WS
/// before/after this fix). Direct port of ctrl-kd's
/// `test_pdf_sup_in_proportional_ws7_font_block_uses_body_size_for_the_tz_scale`
/// (tests/test_ctrlkd.py).
@Test func supInProportionalWS7FontBlockUsesBodySizeForTheTzScale() throws {
    let times = timesTypestyle()
    let styleBits = 0x8000 | (1 << 10)   // proportional + generic_style=serif
    var data: [UInt8] = ws7HeaderBlock()
    data += fontBlock(times, points: 12.0, styleBits: styleBits, width: 137)
    data += bytes("Prize.")
    data += [0x14]
    data += bytes("1")
    data += [0x14]
    data += bytes(" X")
    data += HARD
    let doc = parseWS(data)
    let entry = try #require(doc.fonts.first)
    #expect(entry.proportional)
    #expect(entry.width1800 == 137)

    let spans = contentSpans(emitPDF(doc, mode: .printed))
    var byText: [String: ShownSpan] = [:]
    for span in spans { byText[span.text] = span }

    let body = try #require(byText["Prize."])
    #expect(body.size == 12)
    #expect(body.tz == 101.12)
    #expect(body.x == 57.6)

    let sup = try #require(byText["1"])
    #expect(sup.size == 8)                 // round(12 * 2/3) -- default ratio, non-Courier
    // NO Tz operator for the sup span at all -- the SAME line-wide scale 'Prize.' already
    // set, never a span-local recompute (mechanism G's proportional half: `factor` is the
    // font block's property, not this one span's drawn size).
    #expect(sup.tz == nil)
    #expect(sup.x == 85.6)                 // immediately after 'Prize.', no gap

    let tail = try #require(byText["X"])
    #expect(tail.tz == nil)                // still unchanged, back to body size too
    #expect(tail.x == 92.6)                // 85.6 + 4.0448 (natural '1'), NOT + 6.0676
}
