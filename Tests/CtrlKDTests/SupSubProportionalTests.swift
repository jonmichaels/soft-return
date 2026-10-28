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
/// before/after this fix).
///
/// WS7's LASERJET driver now places each piece (LaserJet.swift), and the face-constant scale
/// this paragraph describes is gone for such a font: 'Prize.' is 122 dots of Times PC at 12pt
/// (29.28pt), so the '1' starts at 57.6 + 29.28, moved to the whole decipoint below (86.8). The
/// '1' is measured at the block's own script size (175/256 of 240 twips, floored to 160: 8pt),
/// 17 dots; then a 15-dot blank, so 'X' is at 86.88 + 4.08 + 3.6 = 94.56 (94.5). Each piece is
/// drawn to its own width with Tz. Port of ctrl-kd's
/// `test_pdf_sup_in_proportional_ws7_font_block_is_measured_at_the_drivers_script_size`
/// (tests/test_ctrlkd.py).
@Test func supInProportionalWS7FontBlockIsMeasuredAtTheDriversScriptSize() throws {
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

    // The page number at the foot is also a "1": only the body's own lines count.
    let spans = contentSpans(emitPDF(doc, mode: .printed)).filter { ($0.y ?? 0) > 100 }
    var byText: [String: ShownSpan] = [:]
    for span in spans { byText[span.text] = span }

    let body = try #require(byText["Prize."])
    #expect(body.size == 12)
    #expect(body.x == 57.6)

    let sup = try #require(byText["1"])
    #expect(sup.size == 8)                 // round(12 * 2/3) -- default ratio, non-Courier
    #expect(sup.x == 86.8)

    let tail = try #require(byText["X"])
    #expect(tail.size == 12)
    #expect(tail.x == 94.5)
}
