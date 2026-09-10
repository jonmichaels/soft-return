import Testing
@testable import CtrlKD

/// Planning #251(b)/(c)/(d): justification spread, graphic-cell geometry, and `.l#`
/// gutter numbers all move onto the page-lines model. Swift port of ctrl-kd's own new
/// unit tests (`tests/test_justification.py`'s `justify_word_x` cases, `tests/
/// test_graphic_cells.py`, `tests/test_printed_fidelity.py`'s `.l#` model case) --
/// cross-engine byte parity for the full 389-doc public corpus is `AnswerKeyParityTests`'
/// own job; these are the narrower, synthetic, single-document checks the task's own
/// "unit tests per part" asks for.

// ------------------------------------------------------------- (b) justifyWordX

@Test func justifyWordXLandsOnThePagelinesModel() {
    // Same fixture/arithmetic as JustificationTests' own
    // `justifiedLineReachesTheResolvedRightMargin`.
    let src = bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n.oj on\r\n") + bytes("AA BB CC") + SOFT
        + bytes("DD.") + HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    let pieces = pages[0][0].justifyWordX
    #expect(pieces != nil)
    guard let pieces else { return }
    #expect(pieces.map(\.text) == ["AA", " ", "BB", " ", "CC"])
    let base = (144.0 - 8 * 7.2) / 2
    #expect(pieces[0].x == 0.0)
    #expect(roundToOneDecimal(pieces[2].x) == roundToOneDecimal(2 * 7.2 + (7.2 + base)))
    let lastX = pieces[4].x, lastW = pieces[4].width
    #expect(roundToOneDecimal(lastX + lastW) == 144.0)

    // The last (unjustified) line carries no opinion -- `.oj on` never stretches a
    // paragraph's own trailing line.
    #expect(pages[0][1].justifyRightX == nil)
    #expect(pages[0][1].justifyWordX == nil)

    // Same answer, one level up, through the public `layout` JSON.
    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"version\": 5"))
    #expect(json.contains("\"justify_word_x\""))
}

@Test func justifyWordXAbsentForAStyledMixedLine() {
    // A second (unjustified) line so the styled first line is not ALSO the block's
    // own last physical line (rule 1 -- always unjustified regardless of shape).
    let src = bytes(".po 0\"\r\n.lm 0\r\n.rm 40\r\n.oj on\r\n") + bytes("AA ")
        + [0x02] + bytes("BB") + [0x02] + bytes(" CC") + SOFT + bytes("DD.") + HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    let line = pages[0][0]
    #expect(line.justifyRightX != nil)     // still eligible BY POSITION
    #expect(line.justifyWordX == nil)       // not by SHAPE (2+ spans)
}

// ------------------------------------------------------------------ (d) lineNo

@Test func lineNoLabelsAndXLandOnThePagelinesModel() {
    // planning #247's own labelling rule: interval 2, six body lines -> lines
    // 1/3/5 (0-based 0/2/4) numbered 1/2/3.
    var body = bytes(".l# 2") + HARD
    for i in 1...6 { body += bytes("Line \(i) text.") + HARD }
    let doc = parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body)
    let pages = docToPagelines(doc, printed: true)
    let labels = pages[0].compactMap { $0.lineNo?.text }
    #expect(labels == ["1", "2", "3"])
    // every labelled line lands at the SAME right-aligned x (single-digit labels).
    let xs = Set(pages[0].compactMap { $0.lineNo?.x })
    #expect(xs.count == 1)
    #expect(pages[0].contains { $0.lineNo == nil })

    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"version\": 5"))
    #expect(json.contains("\"line_no\""))
}

// ----------------------------------------------------------- (c) graphicCells

@Test func graphicCellRectsCoversEveryGraphicCharacter() {
    for ch in graphicChars {
        let rects = graphicCellRects(ch)
        #expect(!rects.isEmpty, "\(ch) (U+\(String(format: "%04X", ch.unicodeScalars.first!.value))) has no rects")
        for r in rects {
            #expect(r.w > 0 && r.h > 0)
        }
    }
}

@Test func graphicCellRectsEmptyForANonGraphicCharacter() {
    #expect(graphicCellRects("A").isEmpty)
    #expect(graphicCellRects(" ").isEmpty)
}

@Test func graphicCellRectsFullBlockAndShadesFillTheCell() {
    let full = graphicCellRects(fullBlock)
    #expect(full.count == 1 && full[0] == (0.0, 0.0, 1.0, 1.0))
    for ch in shadeGray.keys {
        let r = graphicCellRects(ch)
        #expect(r.count == 1 && r[0] == (0.0, 0.0, 1.0, 1.0))
    }
}

@Test func graphicCellRectsArcCornerIsATwoStubApproximation() {
    // '╭' (was '┌') gets the same two-stub SHAPE as its square-cornered boxArms
    // sibling -- an honest approximation, not a curve.
    let arc = graphicCellRects("\u{256D}")
    let square = graphicCellRects("\u{250C}")
    #expect(arc.count == 2 && square.count == 2)
}

@Test func graphicCellsLandOnThePagelinesModel() {
    // ┌──┐ / │ab│ / └──┘ (cp437 bytes: da c4 c4 bf / b3 'ab' b3 / c0 c4 c4 d9).
    let body: [UInt8] = [0xda, 0xc4, 0xc4, 0xbf] + HARD
        + [0xb3] + bytes("ab") + [0xb3] + HARD
        + [0xc0, 0xc4, 0xc4, 0xd9] + HARD
    let doc = parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body)
    let pages = docToPagelines(doc, printed: true)
    let lines = pages[0].filter { $0.graphicCells != nil }
    #expect(lines.count == 3)
    let top = lines[0].graphicCells!
    #expect(top.map(\.char) == ["\u{250C}", "\u{2500}", "\u{2500}", "\u{2510}"])
    let widths = Set(top.map(\.width))
    #expect(widths.count == 1)
    let xs = top.map(\.x)
    #expect(xs == xs.sorted())

    let middle = lines[1].graphicCells!
    #expect(middle.map(\.char) == ["\u{2502}", "\u{2502}"])   // only the two bars

    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"version\": 5"))
    #expect(json.contains("\"graphic_cells\""))
}

@Test func graphicCellsAbsentForALineWithNoGraphics() {
    let doc = parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
        + bytes("An ordinary line of prose, nothing graphic here at all.") + HARD)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0][0].graphicCells == nil)
}
