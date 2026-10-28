import Testing
@testable import CtrlKD

/// Planning #549: two Printed behaviours read from WS7's own runs. Port of ctrl-kd's
/// `tests/test_alternate_font_and_line_numbers.py`.
///
/// E20 -- raw 01h (^PA) selects the printer's alternate font, 0Eh the normal one. On
/// LASERJET the alternate font is Gothic 10 point at 14.29 cpi (21 dots a character); a
/// bare tab after such text goes to the next 8-column stop by distance, not by character
/// count (WS7 teardown, `wordstar-dos/reference/drivera-map.txt`, run raw01-lj).
///
/// E27 -- `.l#` numbers every row of the page, the empty ones after the text too, and
/// draws a double bar at 504 decipoints and a single bar at 5328 beside each number
/// (`wordstar-dos/reference/drivera-map.txt`, run lnum-lj).

private func ws7Doc(_ body: [UInt8], driver: String = "LASERJET") -> Document {
    var src: [UInt8] = wsBlock(cmd: 0x00, content: Array(("p" + driver).utf8) + [0, 0, 0, 0x80])
    src += body
    return parseWS(src)
}

@Test func theAlternateFontIsGothicAt1429CpiOnLaserjet() {
    let doc = ws7Doc(bytes("\u{01}wwwwwwwwww\u{01}\tX in 01\r\n"))
    let fonts = RenderFonts(doc)
    let alt = spanRender("w", font: nil, fonts: fonts.fonts, size: 12, altFont: true,
                         alt: fonts.alt)
    #expect(alt.size == 10 && alt.family == .courier)
    #expect(spanPitch(alt.entry, alt.size) == 126.0 / 25)            // 21 dots
    // the normal font after 0Eh is the document's own
    let normal = spanRender("w", font: nil, fonts: fonts.fonts, size: 12, altFont: false,
                            alt: fonts.alt)
    #expect(normal.size == 12 && normal.entry == nil)
}

@Test func theAlternateFontNeedsTheLaserjetDriver() {
    #expect(RenderFonts(ws7Doc(bytes("\u{01}w\r\n"), driver: "DRAFT")).alt == nil)
}

/// Ten alternate-font characters are 7 columns of the 10-cpi ruler, so the tab stops at
/// column 8 (57.6pt), not at column 16.
@Test func aTabAfterAlternateFontTextGoesToTheNextStopByDistance() throws {
    let doc = ws7Doc(bytes("\u{01}wwwwwwwwww\u{01}\tX in 01\r\n"))
    let line = docToPagelines(doc, printed: true)[0][0]
    let tabs = line.spans.compactMap(\.tabHMI)
    #expect(tabs == [1440])                      // 1440/1800 inch = 8 columns
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .off))
    #expect(try #require(contentSpans(pdf).first { $0.text == "X in 01" }?.x) == 115.2)
}

@Test func anOrdinaryTabKeepsTheColumnRule() {
    let doc = ws7Doc(bytes("wwwwwwwwww\tX\r\n"))
    let line = docToPagelines(doc, printed: true)[0][0]
    #expect(line.spans.map(\.text).joined() == "wwwwwwwwww" + String(repeating: " ", count: 6) + "X")
}

@Test func lineNumbersRunToTheEndOfThePageWithBars() {
    let doc = ws7Doc(bytes(".l# 1\r\nline 01\r\nline 02\r\n"))
    let page = docToPagelines(doc, printed: true)[0]
    #expect(page.count == 55)
    let labelled = page.filter { $0.lineNo != nil }
    #expect(labelled.map { $0.lineNo!.text } == (1...55).map { String($0) })
    #expect(labelled[0].lineNo!.x == 21.6)
    #expect(roundToOneDecimal(labelled[9].lineNo!.x) == 14.4)
    for ln in labelled {
        #expect((ln.graphicCells ?? []).map { "\($0.char)\($0.x)" } == ["║50.4", "│532.8"])
    }
}

@Test func numberingTurnedOffBeforeTheEndDoesNotFillThePage() {
    let doc = ws7Doc(bytes(".l# 1\r\nline 01\r\n\r\n.l# 0\r\nline 02\r\n"))
    #expect(docToPagelines(doc, printed: true)[0].count < 55)
}
