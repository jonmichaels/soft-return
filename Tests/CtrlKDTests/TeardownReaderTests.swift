import Testing
@testable import CtrlKD

/// The reader and detection rules the WordStar run fixtures fixed (planning #549). Port of
/// ctrl-kd's `tests/test_teardown_reader.py`: each test builds its bytes from what the
/// teardown run showed WordStar doing, and cites the report section the rule comes from.

// MARK: - detection

@Test func teardownD1PageMarkIsWordStarEvidence() {
    // WS4 report 1.10, 3.14 (run marks3): the editor stores 0D 8A where it paginated.
    // Plain ASCII lines with one mark are a WS4 document.
    var data: [UInt8] = []
    for n in 1...5 { data += Array("line 0\(n)".utf8) + HARD }
    data += Array("line 06".utf8) + [0x0D, 0x8A]
    for n in 7...9 { data += Array("line 0\(n)".utf8) + HARD }
    data += Array("line 10".utf8) + HARD
    data += Array("line 11".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    #expect(detect(data).variant == .ws4)
    // the same lines without the mark are a print stream
    var plain: [UInt8] = []
    var i = 0
    while i < data.count {
        if data[i] == 0x0D, i + 1 < data.count, data[i + 1] == 0x8A {
            plain += HARD
            i += 2
        } else {
            plain.append(data[i])
            i += 1
        }
    }
    #expect(detect(plain).variant == .printstream)
}

@Test func teardownD1PageMarkNeedsTheDensityFloor() {
    // one chance 0D 8A in a large text file is below the noise floor
    let line = Array("just a line of plain ASCII text".utf8) + HARD
    var data: [UInt8] = []
    for _ in 0..<3000 { data += line }
    data += Array("tail".utf8)
    data += [0x0D, 0x8A]
    data += Array("tail".utf8) + HARD
    for _ in 0..<3000 { data += line }
    #expect(detect(data).variant != .ws4)
}

@Test func teardownD2WrappedCharactersDoNotOutvoteWS4WordEnds() {
    // WS4 report 3.14 (run laser1): hundreds of `1B xx 1C` wrapped box characters in WS4 text
    // that sets bit 7 on every word end. The triples alone are WS5+ machinery; with WS4's
    // word ends beside them the file is WS4.
    var box: [UInt8] = []
    for _ in 0..<60 { box += [0x1B, 0xCD, 0x1C] }
    box += HARD
    let prose = ws4Text("the quick brown fox jumps over the lazy dog again and again") + HARD
    var withWordEnds = box
    for _ in 0..<4 { withWordEnds += prose }
    #expect(detect(withWordEnds).variant == .ws4)
    // without the word ends the same triples stay WS5+
    let bare = Array("the quick brown fox jumps over the lazy dog again and again".utf8) + HARD
    var withoutWordEnds = box
    for _ in 0..<4 { withoutWordEnds += bare }
    #expect(detect(withoutWordEnds).variant == .ws5plus)
}

@Test func teardownD3UnclosedHeaderShapedBlockIsTextNotBinary() {
    // WS4 report 3.14 (run ws5hdr): a `1D 7D 00 00 80 00` header with zero fill loads as one
    // line of `^]}^@^@...`. It does not close, so it is not a header; the zeros are WS4's
    // kept 00h, and the text after it decides.
    var head: [UInt8] = [0x1D, 0x7D, 0x00, 0x00, 0x80]
    head += [UInt8](repeating: 0, count: 123)
    var data = head
    data += Array("Body line one.".utf8) + HARD
    data += Array("Body line two.".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 20)
    #expect(detect(data).variant == .ws4)
    // a binary tail after the same opening is still refused
    var junk = head
    for _ in 0..<3 { junk += (0x80..<0xB0).map { UInt8($0) } }
    #expect(detect(junk).variant == .binary)
}

@Test func teardownD4TwoSoftReturnsInShortHeaderlessWS7FileAreWS5() {
    // WS7 report 11.7, 14.6 (runs just0, just1): soft returns whose only high bits are
    // their own 8D, no bit-7 word ends: WS5+. Two are enough when the file is short.
    var data = Array("The quick brown fox jumps over the lazy dog and keeps running ".utf8) + SOFT
    data += Array("until it reaches the far side of the field where the farmer ".utf8) + SOFT
    data += Array("waits for it with a bucket of cold water and a towel.".utf8) + HARD + [0x1A]
    #expect(detect(data).variant == .ws5plus)
    // the same lines with WS4's word-end flags are WS4
    var ws4 = ws4Text("The quick brown fox jumps over the lazy dog and keeps running") + [0x20] + SOFT
    ws4 += ws4Text("until it reaches the far side of the field where the farmer") + [0x20] + SOFT
    ws4 += ws4Text("waits for it with a bucket of cold water and a towel.") + HARD + [0x1A]
    #expect(detect(ws4).variant == .ws4)
}

// MARK: - reader

private func lineTexts(_ doc: Document) -> [String] {
    doc.blocks.flatMap { $0.lines }.map { $0.text() }
}

@Test func teardownE2EnterUnderLs2KeepsTheSoftReturnSoft() throws {
    // WS7 report 15.10 (runs w16-ls2, w16-ls3): Enter under `.ls n` stores `8D 0A`, n-2
    // empty soft lines and an empty hard line. The text line stays soft although the
    // paragraph ends there.
    let cases: [([UInt8], String)] = [(HARD, ".ls 2"), (SOFT + HARD, ".ls 3")]
    for (filler, ls) in cases {
        var data = Array(ls.utf8) + HARD
        data += Array("first line".utf8) + SOFT + filler
        data += Array("Z".utf8) + HARD
        data += Array("second line".utf8) + HARD
        let doc = try parse(data, variant: .ws5plus)
        let lines = doc.blocks.flatMap { $0.lines }
        let first = lines.first { $0.text() == "first line" }
        #expect(first?.soft == true)
        let z = lines.first { $0.text() == "Z" }
        #expect(z?.soft == false)
        // reflow still ends the paragraph there: no join space is left behind
        let merged = doc.blocks.flatMap { mergedLines($0) }.map { $0.text() }
        #expect(merged.contains("first line"))
    }
}

@Test func teardownE3WS4ReadsABareRRAsARejectedRuler() throws {
    // WS4 report, evidence/pass3/exe-static.md P17, P19B: a bare `.RR` has LM = RM and is
    // rejected; the next line is ordinary text. (In WS7 it introduces a ruler image on the
    // next line.)
    var data = Array(".RR".utf8) + HARD
    data += Array("     XZ".utf8) + HARD + [0x1A]
    let ws4 = try parse(data, variant: .ws4)
    #expect(ws4.dotCommands == [".RR"])
    #expect(lineTexts(ws4).joined() == "     XZ")
    let ws7 = try parse(data, variant: .ws5plus)
    #expect(ws7.dotCommands.count == 2)
}

@Test func teardownE3BareRRRestoresTheDocumentStartRulerInWS4() throws {
    var data = Array(".RR-----!-----!----R".utf8) + HARD
    data += Array("one".utf8) + HARD
    data += Array(".RR".utf8) + HARD
    data += Array("two".utf8) + HARD + [0x1A]
    let doc = try parse(data, variant: .ws4)
    #expect(doc.dotCommands == [".RR-----!-----!----R", ".RR"])
    // the ruler's R pip set a right margin; the rejected `.RR` clears it
    let rights = doc.blocks.filter { $0.kind == .para }.map { $0.rightMargin }
    #expect(rights.first! != nil)
    #expect(rights.last! == nil)
}

@Test func teardownE4NondocumentKeepsBit7() throws {
    // WS7 report 14.2 (run ws4an): a WS4 file opened as a nondocument shows its high-bit
    // bytes as CP437 characters; only the flagged return, line feed and form feed keep
    // their meaning.
    var data: [UInt8] = Array("Thi".utf8)
    data += [0xF3]
    data += Array(" i".utf8) + [0xF3]
    data += Array(" a".utf8) + [0xA0]
    data += Array(" soft".utf8) + [0xA0]
    data += Array(" wrappe".utf8) + [0xE4]
    data += Array(" line".utf8) + [0x8D, 0x0A]
    data += Array("Extended ".utf8) + [0x1B, 0x82, 0x1C] + Array(" and ".utf8)
    data += [0x1B] + Array("A".utf8) + [0x1C]
    data += Array(" items.".utf8) + HARD
    data += Array("Line before a page mark.".utf8) + [0x0D, 0x8A]
    data += Array("Last line.".utf8) + HARD
    data += Array("Z".utf8) + [0x1A]
    let doc = try parse(data, variant: .text)
    let text = lineTexts(doc)
    #expect(text[0] == "Thi\u{2264} i\u{2264} a\u{00E1} soft\u{00E1} wrappe\u{03A3} line")
    #expect(text[1] == "Extended \u{00E9} and A items.")
    #expect(text[2] == "Line before a page mark.")
    #expect(text[3] == "Last line.")
}

@Test func teardownE4PrintStreamStillMasksStrayHighBits() throws {
    // Only a file opened as a nondocument keeps bit 7. A print-to-disk capture's stray high
    // bits are printer noise, as before.
    var data = Array("abc".utf8)
    data += [0xE4]
    data += Array(" def".utf8) + HARD
    let stream = try parse(data, variant: .printstream)
    #expect(lineTexts(stream).first == "abcd def")
    let text = try parse(data, variant: .text)
    #expect(lineTexts(text).first == "abc\u{03A3} def")
}

// MARK: - stored soft returns (E1)

private func terminators(_ doc: Document) -> [[Bool]] {
    let lines = doc.blocks.flatMap { $0.lines }.filter { !$0.spans.isEmpty }
    return lines.map { [$0.soft, $0.keepBreak] }
}

@Test func teardownE1AStoredSoftReturnStaysSoftWhateverReflowDecides() throws {
    // WS4 report 2.7, 6.1, 7.7: `Line.soft` is the stored terminator; `keepBreak` is
    // Modern reflow's own decision to keep the break, and only those lines carry it.
    // A poem: the next word would have fit, so reflow keeps the break.
    var poem = Array("     A short poem line,".utf8) + SOFT
    poem += Array("     another short line.".utf8) + HARD
    var doc = parseWS(poem)
    #expect(terminators(doc) == [[true, true], [false, false]])
    #expect(doc.blocks[0].lines.map(\.wraps) == [false, false])
    #expect(mergedLines(doc.blocks[0]).map { $0.text() }
            == ["     A short poem line,", "     another short line."])
    // a line that really wrapped: soft, and reflow joins it
    var wrapped = Array((String(repeating: "x", count: 58) + " words").utf8) + SOFT
    wrapped += Array("tail.".utf8) + HARD
    doc = parseWS(wrapped)
    #expect(terminators(doc) == [[true, false], [false, false]])
    #expect(doc.blocks[0].lines[0].wraps)
    #expect(mergedLines(doc.blocks[0]).map { $0.text() }
            == [String(repeating: "x", count: 58) + " words tail."])
    // a hard return is hard
    var twoHard = Array("one line".utf8)
    twoHard += HARD
    twoHard += Array("two line".utf8)
    twoHard += HARD
    doc = parseWS(twoHard)
    #expect(terminators(doc) == [[false, false], [false, false]])
}

@Test func teardownE1AKeptBreakAfterASoftHyphenIsStillASoftHyphenLine() throws {
    // `1F 8D 0A` (WS4 report 2.7, run hyph2): the remainder of the word is short, so
    // reflow keeps the break, but the stored line is soft and ends in the soft hyphen,
    // which `.pf on` drops when it re-joins the paragraph.
    var data = Array("A long word is cut at the hyphenation stop of Indenta".utf8) + [0x1F] + SOFT
    data += Array("tion.".utf8) + HARD
    let doc = parseWS(data)
    let first = doc.blocks[0].lines[0]
    #expect(first.soft)
    #expect(first.keepBreak)
    #expect(first.softHyphen)
}

@Test func teardownE1ALineBeforeATypedIndentIsAStoredSoftReturn() throws {
    // The `linesPass` typed-indent rule keeps the break for reflow; the stored return is
    // still soft (WS4 report 7.7, run w14-pmhang).
    var data = Array("     The first line stops short".utf8) + SOFT
    data += Array("     and the next line starts indented.".utf8) + HARD
    let doc = parseWS(data)
    #expect(terminators(doc)[0] == [true, true])
}
