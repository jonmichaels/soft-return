import Testing
@testable import CtrlKD

/// WS4's page counter and page furniture, as the WS4 teardown shows them (planning #549;
/// `wordstar4-dos/4-formatting-printing.md` 3.1/3.2, `evidence/pass3/exe-static.md` 8 and
/// 9). Port of ctrl-kd's `tests/test_ws4_pagination.py`. The rules live in `Era` fields, so
/// each test sets the same document against the WS4 and the WS7 era and states where they
/// differ.

private func ws4Doc(_ lines: [String], _ variant: Variant) -> Document {
    var data: [UInt8] = []
    for line in lines { data += bytes(line) + HARD }
    data.append(0x1A)
    return parseWS(data, variant: variant)
}

private func pageSizes(_ lines: [String], _ variant: Variant) -> [Int] {
    layoutPrintedPages(ws4Doc(lines, variant)).map { $0.count }
}

private func numbered(_ prefix: String, _ n: Int) -> [String] {
    (0..<n).map { prefix + String(format: "%02d", $0 + 1) }
}

@Test func ws4EraFieldsNameTheRules() {
    let ws4 = eraFor(.ws4)
    let ws7 = eraFor(.ws5plus)
    #expect(ws4.lineStartsInRoom && ws4.geometryActsAtOnce)
    #expect(!ws7.lineStartsInRoom && !ws7.geometryActsAtOnce)
    #expect(!ws4.pkEvenKeepsBlank && ws7.pkEvenKeepsBlank)
    #expect(ws4.pcDefault == 28 && ws7.pcDefault == 33.5)
}

@Test func automaticPageNumberSitsAtPc28ForWS4AndCentredForWS7() {
    // (po 8 + pc - 1) columns of 7.2pt: WS4 column 28, WS7's centred 33.5
    #expect(autoPageNumberXPt(ws4Doc(["text"], .ws4)) == 252.0)
    #expect(autoPageNumberXPt(ws4Doc(["text"], .ws5plus)) == 291.6)
    #expect(autoPageNumberXPt(ws4Doc([".pc 10", "text"], .ws4)) == 122.4)
}

@Test func ctrlKOnAnEvenPageDropsItsBlanksInWS4Only() {
    let text = "\u{0B}     Pg #"
    #expect(ctrlKEvenPage(text, 2, keepBlank: false) == "Pg #")
    #expect(ctrlKEvenPage("\u{0B} \t Pg #", 2, keepBlank: false) == "Pg #")
    #expect(ctrlKEvenPage(text, 2) == " Pg #")                  // WS7 keeps one
    #expect(ctrlKEvenPage(text, 3, keepBlank: false) == text)
}

@Test func ws4PageHoldsCeilHOverLHLines() {
    // H = 440 units: 55 at LH 8 (both eras), 37 at LH 12 in WS4 (floor(439/12) + 1) where
    // WS7 fits only whole lines (36)
    let body = numbered("a", 80)
    #expect(pageSizes(body, .ws4)[0] == 55)
    #expect(pageSizes(body, .ws5plus)[0] == 55)
    #expect(Array(pageSizes([".lh 12"] + body, .ws4).prefix(2)) == [37, 37])
    #expect(pageSizes([".lh 12"] + body, .ws5plus)[0] == 36)
}

@Test func ws4LHChangeMidFileCostsEachLineItsOwnLH() {
    // run t43-lh: 30 lines at 8, `.LH 16`: page 1 ends after the 13th line at 16
    // (R = 439 - 240 - 12 * 16 = 7, the 13th overruns)
    let lines = numbered("a", 30) + [".lh 16"] + numbered("b", 30)
    #expect(pageSizes(lines, .ws4)[0] == 43)
}

@Test func ws4MtMbReadMidPageChangeThePageInProgress() {
    // run t43-mtmb: `.MT 10 .MB 2` after 30 lines: H = 432, so page 1 holds 54 lines
    // although it opened at the factory margins
    let lines = numbered("a", 30) + [".mt 10", ".mb 2"] + numbered("b", 70)
    let pages = layoutPrintedPages(ws4Doc(lines, .ws4))
    #expect(pages[0].count == 54)
    #expect(pages[0].mtLines == 3.0)          // printed with the opening margins
    #expect(pages[0].mbLines == 2.0)          // footer set from the margin at its end
    // a later `.MB 12` tightens the page it is read on (H = 408: 51 lines, where WS7 never
    // tightens a page)
    let tighter = numbered("a", 70) + [".mb 12"] + numbered("b", 70)
    let sizes = pageSizes(tighter, .ws4)
    #expect(sizes[0] == 55 && sizes[1] == 51)
}

@Test func ws4CpBreaksWhenFewerThanNLinesRemainWhateverFollows() {
    // run w14-cpfoot: `.CP 10` after 50 lines leaves 5 lines of room and only 3 lines follow
    // the command; WS4 still breaks, the lines that follow are not what is counted
    #expect(pageSizes(numbered("n", 50) + [".cp 10", "x1", "x2", "x3"], .ws4) == [50, 3])
    // room for exactly n lines does not break
    #expect(pageSizes(numbered("n", 45) + [".cp 10", "x1", "x2", "x3"], .ws4) == [48])
}

@Test func ws7CpAlsoCountsTheLinesItAsksFor() {
    // WS7 report 11.3/14.3: room / line height < n breaks (runs cp4-cp6); 5 lines of room,
    // `.cp 6` breaks even with one line after it
    #expect(pageSizes(numbered("n", 50) + [".cp 6", "x1"], .ws5plus) == [50, 1])
    #expect(pageSizes(numbered("n", 50) + [".cp 5", "x1"], .ws5plus) == [51])
}
