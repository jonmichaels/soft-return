import Foundation
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
/// `ESC(sp9.25v13.04hsb4099T` (sup/sub: 9.25pt, 13.04cpi = 23 dots = 5.52pt/char cell). WS7's
/// own rule gives both: Courier's X38 is 198, floor(240 * 198 / 256) = 185 twips = 9.25pt, and
/// the driver's fixed-pitch width is round_half_up(185 / 8) = 23 dots (WS7 teardown,
/// `wordstar-dos/9-printer-drivers.md` 9.6). These two
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
/// occupies 5.52pt (115.2 -> 120.7), not 7.2pt (-> 122.4).
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
    #expect(sup.size == 9.25)              // floor(240 * 198 / 256) twips
    #expect(sup.x == 115.2)                // unchanged: body cell governs up to the toggle

    let tail = try #require(byText[" /"])
    #expect(tail.x == 120.7)               // 115.2 + 5.52 (13.04cpi cell), NOT 115.2 + 7.2
}

/// WS4 shape (a private WS4 paper's own oracle): a span with NO font block at all (`entry` is
/// `nil`). Before mechanism G, `spanPitch(nil, pt)` fell back to `pt * 0.6` where `pt` was
/// already `sized`'s REDUCED size (8, the old flat 2/3 ratio) -- narrowing the cell TWICE
/// (once for the smaller drawn glyph, again via the reduced `pt`) to 4.8pt, 0.7pt narrower
/// than WS7's real 5.5pt, landing everything after it 0.7pt too far LEFT -- exactly that paper's
/// own recorded residual sign and magnitude. The cell now comes from the reduced size by the
/// driver's own formula, so a fontless span gets the same 5.52pt the WS7-font-block shape gets.
/// 'cd.' (3 chars, no font block, no space before the toggle -- matching that paper's own
/// equivalent shape exactly) ends its body run at left + 3*7.2; the sup '1' then
/// occupies 5.52pt, not 4.8pt. The oracle is WS7's print, so the file is printed by WS7
/// (`printedBy: .ws7`); WS4's own HPLJET keeps the script full size
/// (`HPLJETTests.hpljetPrintsAScriptFullSizeOnItsOwnCell`).
@Test func supInFontlessWS4SpanIsNotNarrowedTwice() throws {
    var data: [UInt8] = bytes("cd.")
    data += [0x14]
    data += bytes("1")
    data += [UInt8(0x14 | 0x80)]
    data += bytes("  ef")
    data += HARD
    let doc = parseWS(data, printedBy: .ws7)
    #expect(doc.detection?.variant == .ws4)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    var byText: [String: ShownSpan] = [:]
    for span in spans { byText[span.text] = span }

    let body = try #require(byText["cd."])
    let sup = try #require(byText["1"])
    #expect(sup.size == 9.25)
    #expect(abs(sup.x! - (body.x! + 3 * 7.2)) < 1e-9)   // immediately after 'cd.', no gap

    let tail = try #require(byText["  ef"])
    #expect(abs(tail.x! - (sup.x! + 5.52)) < 0.05)   // NOT sup.x + 4.8 (the old double-narrow)
}

/// WS7's rule for every face: size' = floor(size_twips * X38 / 256), down to the LaserJet's
/// 5-twip step. Port of ctrl-kd's `test_printed_sup_sub_size_follows_each_faces_x38`.
@Test func printedSupSubSizeFollowsEachFacesX38() {
    func font(_ typestyle: Int) -> FontChange {
        FontChange(offset: 0, width1800: 0, height1440: 240, typestyle: typestyle)
    }
    #expect(sizedPrinted([.sup], 12, rollPt: nil, family: .times, entry: font(5)).points == 8.0)
    #expect(sizedPrinted([.sub, .bold, .italic], 12, rollPt: nil, family: .times,
                         entry: font(5)).points == 8.25)
    #expect(sizedPrinted([.sup], 12, rollPt: nil, family: .helvetica, entry: font(46)).points == 8.25)
    #expect(sizedPrinted([.sup], 12, rollPt: nil, family: .times, entry: font(81)).points == 12)
    #expect(sizedPrinted([.sup], 12, rollPt: nil, family: .helvetica, entry: font(511)).points == 8.25)
    #expect(sizedPrinted([.sup], 12, rollPt: nil, family: .courier, entry: nil).points == 9.25)
    #expect(sized([.sup], 12).points == 8)                 // Modern
    #expect(tfSize(9.25) == "9.25" && tfSize(8.5) == "8.5" && tfSize(12) == "12")
}

/// A bare `.po` sets the page offset to 0 in WS7 Rev. D and in WS4; WS4 sets 0 for a bad
/// argument (`.PO x`) too (WS4 teardown 4 §2.3, 3.12; runs po-args), while a bad `.po` in a
/// WS7 file keeps its value (unrun). Port of ctrl-kd's `test_bare_po_sets_zero`.
@Test func barePoSetsZero() throws {
    let body = Array(".po\r\nflush left\r\n.po 8\r\nindented\r\n.po x\r\nafter bad\r\n".utf8)
    var data7: [UInt8] = ws7Block(0x00)
    data7 += body
    let doc7 = try parse(data7, variant: .ws5plus)
    var x7: [String: Double] = [:]
    for span in contentSpans(emitPDF(doc7, mode: .printed)) { x7[span.text] = span.x }
    #expect(x7["flush left"] == 0.0)
    #expect(x7["indented"] == 57.6)
    #expect(x7["after bad"] == 57.6)
    let doc4 = try parse(body, variant: .ws4)
    var x4: [String: Double] = [:]
    for span in contentSpans(emitPDF(doc4, mode: .printed)) { x4[span.text] = span.x }
    #expect(x4["flush left"] == 0.0)
    #expect(x4["indented"] == 57.6)
    #expect(x4["after bad"] == 0.0)
}

/// Port of ctrl-kd's `test_sup_sub_cell_in_a_non_courier_fixed_pitch_face`.
@Test func supSubCellInANonCourierFixedPitchFace() {
    let lp = FontChange(offset: 0, width1800: 108, height1440: 170, typestyle: 0)
    #expect(supSubSpanPitch(lp, [.sup], .courier, 8.0, 8) == 108.0 / 25.0)
    let gothic = FontChange(offset: 0, width1800: 150, height1440: 240, typestyle: 6)
    #expect(supSubSpanPitch(gothic, [.sub], .courier, 9.0, 12) == 150.0 / 25.0 * 9.0 / 12.0)
    #expect(supSubSpanPitch(nil, [.sup], .courier, 9.25, 12) == 23.0 * 72.0 / 300.0)
}

/// A Printed page sits on the LaserJet's logical page: 75 dots (1/4") in from a Letter or
/// Legal sheet's left edge, 71 on A4, 60 in landscape; a print stream stays at the edge.
/// The page's own x is untouched. Port of ctrl-kd's
/// `test_printed_page_sits_on_the_laserjet_logical_page`.
@Test func printedPageSitsOnTheLaserJetLogicalPage() throws {
    func placement(_ text: String, _ variant: Variant = .ws4) throws -> String? {
        let pdf = String(decoding: emitPDF(try parse(Array(text.utf8), variant: variant),
                                           mode: .printed), as: UTF8.self)
        guard let range = pdf.range(of: #"stream\nq 1 0 0 1 [\d.]+ 0 cm\n"#,
                                    options: .regularExpression) else { return nil }
        return pdf[range].split(separator: " ")[5].description
    }
    #expect(try placement("text\r\n") == "18")
    #expect(try placement(".pl 84\r\ntext\r\n") == "18")
    #expect(try placement(".pl 70\r\ntext\r\n") == "17.04")
    #expect(try placement(".pr or=l\r\ntext\r\n") == "14.4")
    #expect(try placement(".pl 20\r\ntext\r\n") == "18")       // a short page is still portrait
    #expect(try placement("text\r\n", .printstream) == nil)
    let letter = try parse(Array("text\r\n".utf8), variant: .ws4)
    var x: [String: Double] = [:]
    for span in contentSpans(emitPDF(letter, mode: .printed)) { x[span.text] = span.x }
    #expect(x["text"] == 57.6)
    let json = try #require(try JSONSerialization.jsonObject(
        with: Data(emitLayout(letter, mode: .printed).utf8)) as? [String: Any])
    let pages = try #require((json["printed"] as? [String: Any])?["pages"] as? [[String: Any]])
    #expect(pages.first?["logical_page_x"] as? Double == 18.0)
}

/// `printedSupSubMetrics` is the size and cell Printed sets a sub/superscript at, for Native:
/// Courier 9.25pt on a 23-dot cell at a 12pt body, Helvetica 8.25pt with no fixed cell, and
/// nothing for a plain span.
@Test func printedSupSubMetricsIsWhatPrintedSets() {
    let courier = printedSupSubMetrics([.sup], size: 12, entry: nil)
    #expect(courier?.points == 9.25 && courier?.cell == 23.0 * 72.0 / 300.0)
    let helvetica = FontChange(offset: 0, width1800: 0, height1440: 240, typestyle: 511)
    #expect(printedSupSubMetrics([.sub], size: 12, entry: helvetica)?.points
        == sizedPrinted([.sub], 12, rollPt: nil, family: pdfFamily(helvetica), entry: helvetica).points)
    #expect(printedSupSubMetrics([], size: 12, entry: nil) == nil)
}

/// WS4 prints a WS4 file's page number at `.PC` 28; WS7 prints the same file with it
/// centred on 33.5; a WS5+ file is printed by WS7 either way. Port of ctrl-kd's
/// `test_printed_by_chooses_which_wordstar_prints_a_ws4_file`.
@Test func printedByChoosesWhichWordStarPrintsAWS4File() throws {
    let body = Array("text\r\n".utf8)
    func numberX(_ doc: Document) -> Double? {
        contentSpans(emitPDF(doc, mode: .printed)).first { $0.text == "1" }?.x
    }
    #expect(numberX(try parse(body, variant: .ws4)) == Double(8 + 28 - 1) * 7.2)
    let ws7X = try #require(numberX(try parse(body, variant: .ws4, printedBy: .ws7)))
    #expect(abs(ws7X - (8 + 33.5 - 1) * 7.2) < 1e-6)
    var ws7: [UInt8] = ws7Block(0x00)
    ws7 += body
    #expect(numberX(try parse(ws7, variant: .ws5plus))
        == numberX(try parse(ws7, variant: .ws5plus, printedBy: .ws7)))
}
