import Testing
@testable import CtrlKD

/// The footnote rules the WordStar run fixtures fixed (planning #549): the note-only page,
/// the block that ends a chain of them, the first part under a reference, and the overflow
/// row. Swift-side mirror of ctrl-kd's `tests/test_teardown_notes.py`.
///
/// Each test builds its bytes here, from what the teardown runs showed WordStar doing, and
/// cites the report section the rule comes from. Decipoints (dp, 1/720 in) and VMI (1/1440
/// in) as the reports give them; the engine's pages are in points (dp / 10).

/// A typed note: `n` lines `note line NNN` (with `pad` blanks), each with its own return,
/// as the runs' documents store them.
private func typed(_ n: Int, pad: Int = 0) -> [UInt8] {
    var out: [UInt8] = []
    for i in 1...n {
        let num = (i < 10 ? "00" : (i < 100 ? "0" : "")) + "\(i)"
        out += bytes("note line " + num)
        out += [UInt8](repeating: 0x20, count: pad)
        out += HARD
    }
    return out
}

private func noteDoc(_ note: [UInt8], ref refLine: Int = 50, lines nLines: Int = 60,
                     dots: [UInt8] = []) -> Document {
    var data = dots
    data += ws7Block(0x00)
    for i in 1...nLines {
        data += bytes("line " + (i < 10 ? "0\(i)" : "\(i)"))
        if i == refLine { data += ws7Note(note, number: 0) }
        data += HARD
    }
    return parseWS(data)
}

private func dot(_ s: String) -> [UInt8] {
    var out = bytes(s)
    out += HARD
    return out
}

/// (baseline in dp, text) for each line of a page whose text top is `top` points down the
/// page: the top plus every line's own lead, 12 where it has none.
private func rows(_ pg: Page, top: Double) -> [(v: Int, text: String)] {
    var y = top
    var out: [(v: Int, text: String)] = []
    for ln in pg {
        y += ln.lead ?? 12.0
        var text = ln.map(\.text).joined()
        while text.hasSuffix(" ") { text.removeLast() }
        out.append((Int((y * 10).rounded()), text))
    }
    return out
}

private func at(_ rs: [(v: Int, text: String)], _ prefix: String) -> [Int] {
    rs.filter { $0.text.hasPrefix(prefix) }.map(\.v)
}

private func notes(_ rs: [(v: Int, text: String)]) -> [Int] {
    rs.filter { $0.text.contains("note line") }.map(\.v)
}

private let separator = String(repeating: "-", count: 20)

// MARK: - the pure rules

@Test func noteOnlySeparatorIsTheStaleWord() {
    // WS7 teardown 15.1, 20.1, 21.8: separator = 360 + 128 * (MT >> 8), MT the `.mt` in
    // VMI: the page's pen is MT & FF00h
    let cases: [(Int, Int)] = [(0, 360), (240, 360), (480, 488), (720, 616), (960, 744),
                               (504, 488), (792, 744), (1008, 744), (1920, 1256),
                               (3840, 2280), (4320, 2408), (7200, 3944)]
    for (mt, sep) in cases { #expect(noteOnlySeparatorDp(mt) == sep, "\(mt)") }
}

@Test func noteOnlyCapacityIsTheLineTopsAboveBB() {
    // WS7 teardown 21.8 (27 runs), 21.9: from F = separator + 360, a line at V prints while
    // 2V - [1A15] + 1 <= PL - MB (VMI)
    let cases: [(Int, Int)] = [(0, 53), (240, 53), (480, 52), (720, 51), (960, 50),
                               (1440, 48), (1920, 46), (504, 52), (792, 50), (1008, 50),
                               (3840, 37), (4320, 36), (7200, 24)]
    for (mt, n) in cases {
        #expect(noteOnlyLines(plVMI: 15840, mtVMI: mt, mbVMI: 1920) == n, "\(mt)")
    }
    #expect(noteOnlyLines(plVMI: 14400, mtVMI: 720, mbVMI: 1920) == 45)    // `.pl 60`
    #expect(noteOnlyLines(plVMI: 17280, mtVMI: 720, mbVMI: 1920) == 57)    // `.pl 72`
    #expect(noteOnlyLines(plVMI: 15840, mtVMI: 720, mbVMI: 3360) == 45)    // `.mb 14`
    // nf59-pl: `.pl 10.84"` (15609, truncated), BB 6844.5: still 53 to 6960
    #expect(vmi(65.04) == 15609)
    #expect(noteOnlyLines(plVMI: vmi(65.04), mtVMI: 0, mbVMI: 1920) == 53)
}

@Test func theChainEndBlockHangsFromTheReserve() {
    // WS7 teardown 21.9's table: pen = PL - MB - [4FBA] - H, separator at (pen + 240) / 2,
    // truncated
    #expect(chainBlockSeparatorDp(plVMI: 15840, mbVMI: 1920, reserveVMI: 4080) == 4560)
    #expect(chainBlockSeparatorDp(plVMI: 15609, mbVMI: 1920, reserveVMI: 5004) == 3982)
    #expect(vmi(65.4) == 15696)                                         // `.pl 10.9"`
}

@Test func theOverflowRowNeedsTheLastBlock() {
    // WS7 teardown 21.9: a record over 1,024 bytes, and a page end whose printed bytes reach
    // its last 1,024-byte block
    #expect(!overflowRowDue(size: 3774, printed: 3066))     // fnch250 p5: 6 short
    #expect(overflowRowDue(size: 3774, printed: 3741))      // fnch250 p6
    #expect(overflowRowDue(size: 1824, printed: 1536))      // fnlong120 p3
    #expect(!overflowRowDue(size: 1824, printed: 771))      // fnlong120 p2
    #expect(overflowRowDue(size: 1774, printed: 1171))      // sp60-p11 p1
    #expect(!overflowRowDue(size: 1284, printed: 849))      // sp60-p4
    #expect(!overflowRowDue(size: 2404, printed: 1585))     // sp60-p20
    #expect(!overflowRowDue(size: 1025, printed: 686))      // qu51-1025
    #expect(!overflowRowDue(size: 1024, printed: 1021))     // no overflow at 1,024
    #expect(!overflowRowDue(size: 864, printed: 861))       // fs59-short
}

@Test func aNoteKeepsItsRecordSizeAndLineEnds() {
    // WS7 teardown 21.9 counts a page's progress from the record's 1D: the length word, the
    // type, the 5-byte head, the text with its CR LFs
    let doc = noteDoc(typed(70), ref: 5)
    #expect(doc.notes.count == 1)
    let note = doc.notes[0]
    #expect(note.recordSize == 9 + 70 * 15 + 3)
    #expect(Array(note.lineEnds.prefix(2)) == [24, 39])
    #expect(note.lineEnds[45] == 9 + 46 * 15)
    #expect(note.lineEnds.count == 70 && note.textLines.count == 70)
}

// MARK: - the pages

@Test func aNoteOnlyPageAtMt0() {
    // run nw-mt0 (WS7 teardown 15.1, 21.8): separator 360, Continued 480, first note 720,
    // 53 lines to 6960; the chain's last page has its separator at 4560, with the overflow
    // row: first note 5040
    let pages = docToPagelines(noteDoc(typed(180), dots: dot(".mt 0")), printed: true)
    #expect(pages.count == 5)
    let p2 = rows(pages[1], top: 0)
    #expect(at(p2, "-----") == [360] && at(p2, "...Continued...") == [480])
    #expect(notes(p2).first == 720 && notes(p2).last == 6960 && notes(p2).count == 53)
    let p5 = rows(pages[4], top: 0)
    #expect(at(p5, "-----") == [4560] && at(p5, "...Continued...") == [4680])
    #expect(notes(p5).first == 5040 && notes(p5).count == 17)
}

@Test func theFirstPartHangsUnderItsReference() {
    // run mt36-35 (WS7 teardown 15.1, 21.9): `.mt 0.35"` (504 VMI); the note on page 2's
    // first line runs, its separator 360 dp under the line, and prints while its line tops
    // are above BB: 51 lines, the last at BB + 12; the note-only pages use MT's high byte
    // only: separator 488
    let doc = noteDoc(typed(180), dots: dot(".mt 0.35\""))
    let pages = docToPagelines(doc, printed: true)
    let top = Double(printedTop(doc))
    let p2 = rows(pages[1], top: top)
    #expect(at(p2, "-----") == [732])
    #expect(notes(p2).count == 51 && notes(p2).last == 6972)
    #expect(at(rows(pages[2], top: top), "-----") == [488])
}

@Test func theOverflowRowOnATwoPageSplit() {
    // run sp60-p11 (WS7 teardown 21.9): 25-byte lines, a 1,762-byte record here; page 1
    // ends at byte 1,159, inside the last block, so page 2's note lines start a row lower
    // (4320, not 4200) and the last prints at 7080, a row below BB
    let pages = docToPagelines(noteDoc(typed(70, pad: 10), ref: 5, lines: 20), printed: true)
    #expect(pages.count == 2)
    let p2 = rows(pages[1], top: 36)
    #expect(at(p2, "-----") == [3840] && at(p2, "...Continued...") == [3960])
    #expect(notes(p2).first == 4320 && notes(p2).last == 7080)
}

@Test func noRowBeforeTheLastBlock() {
    // run sp60-p4 (WS7 teardown 21.9): 18-byte lines, a 1,272-byte record here; page 1
    // ends at byte 837, before the last block: no row (note 47 at 4200, the last on BB)
    let pages = docToPagelines(noteDoc(typed(70, pad: 3), ref: 5, lines: 20), printed: true)
    let p2 = rows(pages[1], top: 36)
    #expect(notes(p2).first == 4200 && notes(p2).last == 6960)
}

@Test func noRowWithoutAnOverflow() {
    // run fs59-short: a 120-line note of 5-character lines (an 864-byte record): note-only
    // page 3, and page 4 keeps the 2H reserve (separator 3960) with no row: its first note
    // at 4320
    var note: [UInt8] = []
    for i in 1...120 {
        note += bytes("nt" + (i < 10 ? "00" : (i < 100 ? "0" : "")) + "\(i)")
        note += HARD
    }
    let pages = docToPagelines(noteDoc(note), printed: true)
    #expect(pages.count == 4)
    let p4 = rows(pages[3], top: 36)
    #expect(at(p4, "-----") == [3960])
    #expect(at(p4, "nt").first == 4320)
}

@Test func aFractionalPlPutsTheChainEndHigher() {
    // runs nf59-pl, pl60-109 (WS7 teardown 21.9): the note-only pages print whole lines but
    // the reserve takes the exact room off, so the chain's last block sits higher than the
    // lines need
    var dots = dot(".mt 0")
    dots += dot(".pl 10.84\"")
    var pages = docToPagelines(noteDoc(typed(180), dots: dots), printed: true)
    #expect(at(rows(pages[4], top: 0), "-----") == [3982])
    pages = docToPagelines(noteDoc(typed(180), dots: dot(".pl 10.9\"")), printed: true)
    #expect(at(rows(pages[4], top: 36), "-----") == [2592])
}

@Test func aCarryLeftAfterTheTextPrintsUnderTheTopMargin() {
    // run nw59-mt30 p11 (WS7 report 15.1): the last note line, carried past the last page of
    // text, prints as a block under no text: the separator 360 dp under the top margin, and
    // the page keeps its number
    let pages = docToPagelines(noteDoc(typed(180), dots: dot(".mt 30")), printed: true)
    #expect(pages.count == 11)
    let p11 = rows(pages[10], top: 360)
    #expect(p11.first?.v == 3960 && p11.first?.text == separator)
    #expect(notes(p11) == [4320])
    #expect(pages[10].explicitBreakBI != nil)
}

// MARK: - `.f#`

@Test func fHashFormsSetTheStart() {
    // WS7 report 15.1, 18 (`.f#` 0x27DC9; ^ONN writes `.f# p 5`, run on27a; runs fnnum5,
    // fnnumd): `d` / `p` set continuous / per page and the number after them sets the next
    // note to n; two footnotes whose records store no number (the tag word's high bit set,
    // no tag record) take their labels from it
    let cases: [(String, Int)] = [(".f# p 5", 5), (".f# d 5", 5), (".f#d 1", 1), (".f# 5", 5)]
    for (cmd, start) in cases {
        var data = dot(cmd)
        data += ws7Block(0x00)
        let note = ws7Block(0x03, payload: [0x01, 0x00, 0x00, 0x80, 0x30, 0x6e])
        data += bytes("one")
        data += note
        data += HARD
        data += bytes("two")
        data += note
        data += HARD
        let doc = parseWS(data)
        #expect(doc.footnoteNumberStart == start, "\(cmd)")
        #expect(doc.footnoteNumberMode == (cmd.contains("d") ? .continuous : .page), "\(cmd)")
        let page = docToPagelines(doc, printed: true)[0].map { $0.map(\.text).joined() }
        #expect(page.filter { $0.hasSuffix(".n") } == ["\(start).n", "\(start + 1).n"], "\(cmd)")
    }
}

@Test func eHashSetsTheEndnoteStartAndNoMode() {
    // `.e#` sets the endnote counter, which never resets per page (WS7 report 15.1)
    var data = dot(".e# 5")
    data += bytes("x")
    data += HARD
    let doc = parseWS(data)
    #expect(doc.endnoteNumberStart == 5)
    #expect(doc.endnoteNumberMode == nil)
}

// MARK: - print-time numbering

/// The runs' 100-line document (fnnum0, tg61-*): a note `<kind> for line NN` on each line in
/// `at`, each record storing the number in `stored` (0-based, as WS7 saves it).
private func numberedDoc(_ kind: String, stored: [Int], at: [Int] = [5, 10, 60, 65],
                         dots: [UInt8] = []) -> Document {
    var data = dots
    data += ws7Block(0x00)
    for i in 1...100 {
        let nn = i < 10 ? "0\(i)" : "\(i)"
        data += bytes("line " + nn)
        if let k = at.firstIndex(of: i) {
            data += ws7Note(bytes(kind + " for line " + nn), cmd: kind == "note" ? 0x03 : 0x04,
                            number: stored[k])
        }
        data += HARD
    }
    return parseWS(data)
}

private func pageTexts(_ doc: Document) -> [[String]] {
    docToPagelines(doc, printed: true).map { page in
        page.map { line in
            var text = line.map(\.text).joined()
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
    }
}

@Test func printedFootnotesIgnoreTheStoredNumber() {
    // WS7 teardown 21.10, run tg61-stale: the four records store 4, 3, 9, 8 and the print is
    // fnnum0's byte for byte, 1, 2 / 1, 2: the printer numbers the notes itself, restarting
    // on each page (factory fntyp+1 0)
    let doc = numberedDoc("note", stored: [3, 2, 8, 7])
    let pages = pageTexts(doc)
    #expect(pages[0].filter { $0.contains("note for") }
            == ["1.note for line 05", "2.note for line 10"])
    #expect(pages[1].filter { $0.contains("note for") }
            == ["1.note for line 60", "2.note for line 65"])
    #expect(pages[0].contains("line 051") && pages[0].contains("line 102"))
    #expect(pages[1].contains("line 601") && pages[1].contains("line 652"))
    // every other output keeps the stored number
    let labels = doc.notes.indices.map { noteLabel(doc.notes[$0], doc: doc, index: $0, printed: true) }
    #expect(labels == ["4", "3", "9", "8"])
}

@Test func printedFootnotesFollowFHashInFlow() {
    // WS7 teardown 15.1 (runs fnnumd, fnnum5): `.f#d 1` runs on, 1, 2 / 3, 4; a bare `.f# 5`
    // sets the next number and per page, 5, 6 / 1, 2; 15.10: a letter sets the format. The
    // stored numbers (all 0 here) are not read (21.10).
    let cases: [(String, [String])] = [(".f#d 1", ["1.", "2.", "3.", "4."]),
                                       (".f# 5", ["5.", "6.", "1.", "2."]),
                                       (".f# a", ["a.", "b.", "a.", "b."])]
    for (cmd, want) in cases {
        let pages = pageTexts(numberedDoc("note", stored: [0, 0, 0, 0], dots: dot(cmd)))
        let got = (pages[0] + pages[1]).filter { $0.contains("note for") }.map { String($0.prefix(2)) }
        #expect(got == want, "\(cmd)")
    }
}

@Test func printedEndnotesRunOnWithNoBlankAfterTheMark() {
    // WS7 teardown 21.10, run tg61-en0: endnotes on lines 5 and 60 print
    // `(1)endnote for line 05`, `(2)endnote for line 60` after the text, numbered by the
    // printer whatever the records store (21.10)
    let texts = pageTexts(numberedDoc("endnote", stored: [6, 2], at: [5, 60])).flatMap { $0 }
    #expect(texts.filter { $0.contains("endnote for") }
            == ["(1)endnote for line 05", "(2)endnote for line 60"])
    #expect(texts.contains("line 051") && texts.contains("line 602"))
}
