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
    var src = bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n.oj on\r\n")
    src += bytes("AA BB CC")
    src += SOFT
    src += bytes("DD.")
    src += HARD
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
    #expect(json.contains("\"version\": 7"))
    #expect(json.contains("\"justify_word_x\""))
}

@Test func justifyWordXAbsentForAStyledMixedLine() {
    // A second (unjustified) line so the styled first line is not ALSO the block's
    // own last physical line (rule 1 -- always unjustified regardless of shape).
    var src = bytes(".po 0\"\r\n.lm 0\r\n.rm 40\r\n.oj on\r\n")
    src += bytes("AA ")
    src += [0x02]
    src += bytes("BB")
    src += [0x02]
    src += bytes(" CC")
    src += SOFT
    src += bytes("DD.")
    src += HARD
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
    var src251d: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src251d += body
    let doc = parseWS(src251d)
    let pages = docToPagelines(doc, printed: true)
    let labels = pages[0].compactMap { $0.lineNo?.text }
    #expect(labels == ["1", "2", "3"])
    // every labelled line lands at the SAME right-aligned x (single-digit labels).
    let xs = Set(pages[0].compactMap { $0.lineNo?.x })
    #expect(xs.count == 1)
    #expect(pages[0].contains { $0.lineNo == nil })

    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"version\": 7"))
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
    var body: [UInt8] = [0xda, 0xc4, 0xc4, 0xbf]
    body += HARD
    body += [0xb3]
    body += bytes("ab")
    body += [0xb3]
    body += HARD
    body += [0xc0, 0xc4, 0xc4, 0xd9]
    body += HARD
    var doc251c: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    doc251c += body
    let doc = parseWS(doc251c)
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
    #expect(json.contains("\"version\": 7"))
    #expect(json.contains("\"graphic_cells\""))
}

@Test func graphicCellsAbsentForALineWithNoGraphics() {
    var src251c: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src251c += bytes("An ordinary line of prose, nothing graphic here at all.")
    src251c += HARD
    let doc = parseWS(src251c)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0][0].graphicCells == nil)
}

// ------------------------------------------- (c follow-up) Modern graphicCells

/// Planning #251 follow-up (2026-09-10, app coder job 348): the SAME cp437 box
/// draws a vector rule in Modern PDF too (`PDFDriverLJ6DTP.swift`'s `graphicOps`,
/// called from `modernLineOps`), and the app's Modern view needs the model's own
/// x/width/page to place it -- `attachGraphicCellsModern` records exactly what
/// `modernStreams` draws, via a real (throwaway) call to that same function.
@Test func modernGraphicCellsLandOnTheLayoutJSON() {
    // A single ═══ rule, long enough to prove it stays ONE non-wrapping run.
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += [UInt8](repeating: 0xCD, count: 10)     // ═ x 10
    src += HARD
    let doc = parseWS(src)
    let cells = attachGraphicCellsModern(doc, notes: EmitOptions.defaultNotes, noteRefs: .word)
    #expect(!cells.isEmpty)
    let allCells = cells.values.flatMap { $0 }
    #expect(allCells.count == 10)
    #expect(allCells.allSatisfy { $0.char == "\u{2550}" })
    #expect(allCells.allSatisfy { $0.page == 1 })
    let xs = allCells.map(\.x)
    #expect(xs == xs.sorted())

    // Same answer, one level up, through the public `layout` JSON's `modern.items`.
    let json = emitLayout(doc, mode: .modern)
    #expect(json.contains("\"version\": 7"))
    #expect(json.contains("\"graphic_cells\""))
    #expect(json.contains("\"page\": 1"))
}

@Test func modernGraphicCellsAbsentForADocumentWithNoGraphics() {
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += bytes("An ordinary line of prose, nothing graphic here at all.")
    src += HARD
    let doc = parseWS(src)
    #expect(attachGraphicCellsModern(doc, notes: EmitOptions.defaultNotes, noteRefs: .word).isEmpty)
    let json = emitLayout(doc, mode: .modern)
    #expect(!json.contains("\"graphic_cells\""))
}

/// PDF bytes are unaffected -- `attachGraphicCellsModern`'s own throwaway call
/// never touches the real `emitPDF` render path (`attachGraphicCells: nil` by
/// default at its one real call site).
@Test func modernGraphicCellsNeverChangePDFBytes() {
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += [UInt8](repeating: 0xCD, count: 10)
    src += HARD
    let doc = parseWS(src)
    let pdf1 = emitPDF(doc, mode: .modern)
    let pdf2 = emitPDF(doc, mode: .modern)
    #expect(pdf1 == pdf2)
    _ = attachGraphicCellsModern(doc, notes: EmitOptions.defaultNotes, noteRefs: .word)
    let pdf3 = emitPDF(doc, mode: .modern)
    #expect(pdf3 == pdf1)
}

// --------------------------------------------------- (d) running head/foot

/// Planning #251(d), running-head/foot half (2026-09-10): `Page.headerLines`/
/// `footerLines`/`autoPageno` -- resolved text/x/y/font for the running head and
/// foot, moved off `PDFWriter.swift`'s own render-time-only `runningOps` onto the
/// page-lines model, via the shared `resolveHeadFootLines`. Swift port of ctrl-kd's
/// own new `tests/test_ctrlkd.py` cases (`test_head_foot_lines_*`).

@Test func headFootLinesLandOnTheModelMatchingTheWriter() {
    var src = bytes(".h1 Header Text\r\n.f1 Footer Text\r\n")
    src += bytes("Page one prose, plain and ordinary and long enough here.")
    src += HARD
    src += bytes(".pa\r\n")
    src += bytes("Page two prose, also plain, ordinary, long enough here.")
    src += HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].headerLines == [HeadFootLine(text: "Header Text", x: 57.6, y: 780.0, font: nil)])
    #expect(pages[0].footerLines == [HeadFootLine(text: "Footer Text", x: 57.6, y: 60.0, font: nil)])
    #expect(pages[0].autoPageno == nil)     // a real footer is in force -> no auto number
    #expect(pages[1].headerLines == [HeadFootLine(text: "Header Text", x: 57.6, y: 780.0, font: nil)])

    let pdf = emitPDF(doc, mode: .printed)
    let streams = pdfContentStreams(pdf)
    let asString = String(decoding: streams[0], as: UTF8.self)
    #expect(asString.contains("57.6 780.0 Td (Header Text) Tj"))
    #expect(asString.contains("57.6 60.0 Td (Footer Text) Tj"))
}

@Test func headFootLinesResolveTheSamePageNumberSubstitutionAndTabBake() {
    // -README's own right-tab shape (see `runningHeadRightTabRepositionsWhenThePage
    // NumberWidens`, the same synthetic fixture) -- the model's own `headerLines[0]
    // .text` carries BOTH the `#` substitution and the fontless tab-realignment
    // bake, proving the model and the writer resolve identically.
    func tabBlock(cols: Int, absHMI: Int, tabType: UInt8 = 0x5D) -> [UInt8] {
        let size = cols * 180
        var payload = withUnsafeBytes(of: UInt16(size).littleEndian, Array.init)
        payload += withUnsafeBytes(of: UInt16(absHMI).littleEndian, Array.init)
        payload += [tabType, UInt8(ascii: " ")]
        return ws7Block(0x09, payload: payload)
    }
    let tab = tabBlock(cols: 13, absHMI: 2340)
    var src = bytes(".pn 9\r\n.h1 ")
    src += tab
    src += bytes("TEST / #")
    src += HARD
    src += bytes("Page one prose, plain and ordinary and long enough here.")
    src += HARD
    src += bytes(".pa\r\n")
    src += bytes("Page two prose, also plain, ordinary, long enough here.")
    src += HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0].headerLines?[0].text == String(repeating: " ", count: 13) + "TEST / 9")
    #expect(pages[1].headerLines?[0].text == String(repeating: " ", count: 12) + "TEST / 10")

    let pdf = emitPDF(doc, mode: .printed)
    let streams = pdfContentStreams(pdf)
    #expect(String(decoding: streams[0], as: UTF8.self).contains(pages[0].headerLines![0].text))
    #expect(String(decoding: streams[1], as: UTF8.self).contains(pages[1].headerLines![0].text))
}

@Test func headFootLinesTrackAMidDocumentPoParityLeftEdge() {
    // PHONE.LST/-HOW-TO.RJS's own shape: DIFFERENT odd/even offsets with no plain
    // `.po` at all -- the model's own header `x` must follow `Page.poParity` the
    // same way `runningOps`'s own `pageLeft` already does.
    var src = bytes(".h1 Running Head\r\n.poo 2\r\n.poe 6\r\n")
    src += bytes("Page one prose, plain and ordinary and long enough here.")
    src += HARD
    src += bytes(".pa\r\n")
    src += bytes("Page two prose, also plain, ordinary, long enough here.")
    src += HARD
    src += bytes(".pa\r\n")
    src += bytes("Page three prose, also plain, ordinary, long enough.")
    src += HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 3)
    // page 1/3 odd -> .poo 2 (14.4pt); page 2 even -> .poe 6 (43.2pt).
    #expect(pages[0].headerLines?[0].x == 14.4)
    #expect(pages[1].headerLines?[0].x == 43.2)
    #expect(pages[2].headerLines?[0].x == 14.4)
}

@Test func headFootLinesOmittedWhenTheDocumentHasNeither() {
    // No `.h#`/`.f#` and no automatic number showing (`.op`, no `#` anywhere) --
    // `headerLines`/`footerLines`/`autoPageno` stay `nil`, omitted from `layout`
    // JSON too (version 6 emits byte-identical output to version 5 for a document
    // like this, aside from the version number itself).
    var src = bytes(".op\r\n")
    src += bytes("Ordinary prose, plain, with no header or footer at all here.")
    src += HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0].headerLines == nil)
    #expect(pages[0].footerLines == nil)
    #expect(pages[0].autoPageno == nil)
    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"version\": 7"))
    #expect(!json.contains("\"header_lines\""))
    #expect(!json.contains("\"footer_lines\""))
    #expect(!json.contains("\"auto_page_number\""))
}

@Test func layoutJSONCarriesResolvedHeadFootLines() {
    var src = bytes(".h1 Header Text\r\n")
    src += bytes("Page one prose, plain and ordinary and long enough here.")
    src += HARD
    let doc = parseWS(src)
    let json = emitLayout(doc, mode: .printed)
    #expect(json.contains("\"header_lines\""))
    #expect(json.contains("\"text\" : \"Header Text\"") || json.contains("\"text\": \"Header Text\""))
    #expect(json.contains("\"auto_page_number\""))
}
