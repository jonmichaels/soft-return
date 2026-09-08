import Testing
@testable import CtrlKD

/// Mechanism G (ctrl-kd f328838, research: 2026-09-06_ws7-blank-lines-and-superscript-
/// advance.md, "G -- superscript/subscript advance in fixed-pitch text"). Real WS7's own
/// PCL font-selection command for a superscript/subscript span in a fixed-pitch document is
/// not merely a smaller glyph at the ambient pitch -- it is a DEDICATED, narrower pitch, an
/// independent field of the same font-select command, restored to the body's own values
/// immediately on exit. Two independent real WS7 captures (-SCREEN.pcl, a private paper's own .pcl -- both
/// Courier, typeface id 4099) carry the byte-identical font-select pair
/// `ESC(sp12v10.00hsb4099T` (body: 12pt, 10.00cpi = 7.2pt/char cell) /
/// `ESC(sp9.25v13.04hsb4099T` (sup/sub: 9.25pt, 13.04cpi = 5.5pt/char cell). These two
/// synthetic fixtures reproduce that measured shape exactly (invented words, same
/// arithmetic) in the TWO real code shapes the corpus exercises: a WS7 span with its own
/// font block (`entry` carries `width1800`) and a WS4/print-stream span with none (`entry`
/// is `nil`). Direct port of ctrl-kd's `test_pdf_sup_in_fixed_pitch_ws7_font_block_uses_the_
/// narrower_courier_cell` and `test_pdf_sup_in_fontless_ws4_span_is_not_narrowed_twice`
/// (tests/test_ctrlkd.py).

/// WS7 shape (-SCREEN.WS's own oracle): a span with a real font block. Before mechanism G,
/// `spanPitch` ignored the (already size-reduced) `pt` entirely once a font block existed,
/// drawing the sup glyph at the BODY's full 7.2pt cell -- landing everything after it +1.7pt
/// (7.2 - 5.5) too far right, exactly -SCREEN's own recorded residual. 'note: ' (6 chars
/// including the trailing space) ends the body run at 72.0 + 6*7.2 = 115.2; the sup '1' now
/// occupies 5.5pt (115.2 -> 120.7), not 7.2pt (-> 122.4).
@Test func supInFixedPitchWS7FontBlockUsesTheNarrowerCourierCell() throws {
    let cour = courierTypestyle()
    // Built up in statements: an 8-term heterogeneous `+` chain over [UInt8] made the
    // type checker give up on the Mac toolchain (Xcode 26.3), while compiling on Linux.
    var data: [UInt8] = ws7Block(0x00)
    data += fontBlock(cour, points: 12.0, width: 180)
    data += bytes("note: ")
    data += [0x14]
    data += bytes("1")
    data += [0x14]
    data += bytes(" /")
    data += HARD
    let doc = parseWS(data)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    var byText: [String: ShownSpan] = [:]
    for span in spans { byText[span.text] = span }

    let note = try #require(byText["note: "])
    #expect(note.x == 72.0)

    let sup = try #require(byText["1"])
    #expect(sup.size == 9)                 // round(12 * 9.25/12) -- mechanism G's own ratio
    #expect(sup.x == 115.2)                // unchanged: body cell governs up to the toggle

    let tail = try #require(byText[" /"])
    #expect(tail.x == 120.7)               // 115.2 + 5.5 (13.04cpi cell), NOT 115.2 + 7.2
}

/// WS4 shape (a private WS4 paper's own oracle): a span with NO font block at all (`entry` is
/// `nil`). Before mechanism G, `spanPitch(nil, pt)` fell back to `pt * 0.6` where `pt` was
/// already `sized`'s REDUCED size (8, the old flat 2/3 ratio) -- narrowing the cell TWICE
/// (once for the smaller drawn glyph, again via the reduced `pt`) to 4.8pt, 0.7pt narrower
/// than WS7's real 5.5pt, landing everything after it 0.7pt too far LEFT -- exactly that paper's
/// own recorded residual sign and magnitude. `seg.size` (the span's UNREDUCED declared size)
/// now drives the body-cell lookup instead, so a fontless span's own body cell (12pt document
/// default * 0.6 = 7.2pt) narrows ONCE, to the same 5.5pt the WS7-font-block shape gets.
/// 'cd.' (3 chars, no font block, no space before the toggle -- matching that paper's own
/// equivalent shape exactly) ends its body run at left + 3*7.2; the sup '1' then
/// occupies 5.5pt, not 4.8pt.
@Test func supInFontlessWS4SpanIsNotNarrowedTwice() throws {
    var data: [UInt8] = bytes("cd.")
    data += [0x14]
    data += bytes("1")
    data += [UInt8(0x14 | 0x80)]
    data += bytes("  ef")
    data += HARD
    let doc = parseWS(data)
    #expect(doc.detection?.variant == .ws4)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    var byText: [String: ShownSpan] = [:]
    for span in spans { byText[span.text] = span }

    let body = try #require(byText["cd."])
    let sup = try #require(byText["1"])
    #expect(sup.size == 9)
    #expect(sup.x == body.x! + 3 * 7.2)    // immediately after 'cd.', no gap

    let tail = try #require(byText["  ef"])
    #expect(tail.x == sup.x! + 5.5)        // NOT sup.x + 4.8 (the old double-narrow)
}
