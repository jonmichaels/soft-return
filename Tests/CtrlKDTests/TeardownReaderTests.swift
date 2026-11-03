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

// MARK: - bit 7 under a header (A3)

/// WS7's 128-byte header (WS7 teardown 3.3, 14.1): `1D 7D 00`, the version byte 70h after a
/// zero, the driver name, zeros, `7D 00 1D`.
private func ws7Header(driver: String = "LASERJET") -> [UInt8] {
    var inner: [UInt8] = [0x00, 0x70]
    inner += Array(driver.utf8)
    inner += [UInt8](repeating: 0, count: 122 - inner.count)
    var head: [UInt8] = [0x1D, 0x7D, 0x00]
    head += inner
    head += [0x7D, 0x00, 0x1D]
    return head
}

@Test func teardownA3HeaderedDocumentClearsBit7() throws {
    // WS7 teardown 14.2, 21.8 (runs hb59-raw-p, hb59c-raw-s): a WS7 document with bytes
    // 80h-FFh in its text, printed from disk or opened: every printable byte loses bit 7
    // (A1h-FFh), 82h and 93h act as 02h bold and 13h underline.
    var data = ws7Header()
    data += Array("Thi".utf8) + [0xF3]
    data += Array(" i".utf8) + [0xF3]
    data += [0x20, 0xE1]
    data += Array(" tes".utf8) + [0xF4]
    data += Array(" line".utf8) + HARD
    data += Array("letters ".utf8) + [0xE1, 0xE2, 0xE3]
    data += Array(" shades ".utf8) + [0xB0, 0xB1, 0xB2]
    data += Array(" rules ".utf8) + [0xC4, 0xCD]
    data += Array(" end".utf8) + HARD
    data += Array("x".utf8) + [0x82]
    data += Array("bold".utf8) + [0x82]
    data += Array(" y".utf8) + [0x93]
    data += Array("under".utf8) + [0x93]
    data += Array(" z".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    #expect(doc.detection?.variant == .ws5plus)
    let texts = lineTexts(doc)
    #expect(Array(texts.prefix(3)) == ["This is a test line", "letters abc shades 012 rules DM end",
                                       "xbold yunder z"])
    let line3 = doc.blocks.flatMap { $0.lines }.first { $0.text() == "xbold yunder z" }
    let bold = line3?.spans.first { $0.text == "bold" }
    let under = line3?.spans.first { $0.text == "under" }
    #expect(bold?.styles.contains(.bold) == true)
    #expect(under?.styles.contains(.underline) == true)
}

@Test func teardownA3ItemsRecordsSoftReturnsAndSoftSpacesAreKept() throws {
    // WS7 teardown 14.2, 21.8 (run hb59c-cv-s): Star Exchange's WS5 file loses its
    // word-end bits; `8D 0A`, the tab record and `1B 82 1C` stay, and A0h (the soft space)
    // is read raw.
    var tab: [UInt8] = [0x1D, 0x0A, 0x00, 0x09, 0x84, 0x03, 0xA0, 0x05]
    tab += [0x20, 0x05, 0x0A, 0x00, 0x1D]
    var data = ws7Header(driver: "")
    data += [0xC1]
    data += Array(" firs".utf8) + [0xF4]
    data += Array(" lin".utf8) + [0xE5]
    data += Array(" wrap".utf8) + [0xF3]
    data += [0x20] + SOFT
    data += Array("secon".utf8) + [0xE4, 0xA0]
    data += Array("line".utf8) + HARD
    data += Array("Tab".utf8) + tab
    data += Array("then".utf8) + [0x1B, 0x82, 0x1C]
    data += Array(" item".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    let lines = doc.blocks.flatMap { $0.lines }.filter { !$0.spans.isEmpty }
    #expect(lines[0].text() == "A first line wraps ")
    #expect(lines[0].soft)
    #expect(lines[1].text() == "second line")
    #expect(lines[2].text().hasSuffix("then\u{00E9} item"))
    // the round-trip writer still gives the file back byte for byte
    #expect(try emitWS(doc) == data)
}

@Test func teardownA3PrintControlsDisplayStringKeepsItsHighBytes() throws {
    // WS7 teardown 3.6: the load sanitiser steps over a whole 1Dh record, so the
    // guillemets of a 0Fh print control's display string stay as stored.
    var pctl: [UInt8] = [0x1D, 0x25, 0x00, 0x0F, 0x00, 0x00, 0x1A, 0xAE]
    pctl += Array("Do not skip performation".utf8)
    pctl += [0xAF, 0x1B]
    pctl += Array("&0L".utf8)
    pctl += [0x25, 0x00, 0x1D]
    var data = ws7Header()
    data += pctl + HARD
    data += Array("x".utf8) + [0xF9]
    data += Array("y".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let texts = lineTexts(try parse(data))
    #expect(texts.contains("\u{00AB}Do not skip performation\u{00BB}"))
    #expect(texts.contains("xyy"))
}

// MARK: - records in a running head (A8)

/// One WS5+ record: `1D <count> <cmd> <content> <count> 1D`.
private func record(_ cmd: UInt8, _ content: [UInt8]) -> [UInt8] {
    let count = content.count + 4
    let lo = UInt8(count & 0xFF)
    let hi = UInt8(count >> 8)
    var out: [UInt8] = [0x1D, lo, hi, cmd]
    out += content
    out += [lo, hi, 0x1D]
    return out
}

/// A footnote record shaped as run h24-allow's (WS7 teardown 3.15): number 1, its inner
/// record, then the note's text.
private func footnote(_ text: String) -> [UInt8] {
    var content: [UInt8] = [0x01, 0x00, 0x09, 0x80, 0x33]
    content += [0x1D, 0x09, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x33, 0x09, 0x00, 0x1D]
    content += Array(text.utf8)
    content += HARD
    return record(0x03, content)
}

/// Run h24-allow's `.he` argument (WS7 teardown 3.15): `A`, a font record, `B`, a footnote,
/// `C`, an annotation, `D`, a tab to 1800 HMI, `E`, a colour record, `F`.
private func h24Line() -> [UInt8] {
    let font = record(0x02, [0x13, 0x01, 0xE0, 0x01, 0x05, 0xC6, 0xB4, 0x00, 0xF0, 0x00, 0x00, 0x00])
    var note: [UInt8] = [0x01, 0x00, 0x09, 0x80]
    note += record(0x03, [0x00, 0x00, 0x00, 0x00])
    note += Array("note text".utf8) + HARD
    var ann: [UInt8] = [0x01, 0x00, 0x09, 0x80]
    ann += record(0x05, [0x00, 0x00, 0x00, 0x00])
    ann += Array("annotation text".utf8) + HARD
    var out: [UInt8] = Array("A".utf8) + font
    out += Array("B".utf8) + record(0x03, note)
    out += Array("C".utf8) + record(0x05, ann)
    out += Array("D".utf8) + record(0x09, [0x08, 0x07, 0x08, 0x07, 0x20, 0x0A])
    out += Array("E".utf8) + record(0x01, [0x04, 0x00])
    out += Array("F".utf8)
    return out
}

@Test func teardownA8RunningHeadKeepsOnlyTheListedRecords() throws {
    // WS7 teardown 3.15 (runs h24-allow, h24-body): the `.he`/`.fo` line rebuild keeps
    // records of types 01 02 09 0F 10 11 15 and drops the rest: the font and the tab act,
    // the two notes print nothing. The head's own font is not the body's.
    var data = ws7Header()
    data += Array(".he ".utf8) + h24Line()
    data += HARD
    for n in 1...3 { data += Array("line 0\(n)".utf8) + HARD }
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    let head = doc.headers[1] ?? ""
    #expect(String(head.filter { $0 != " " }) == "ABCDEF")
    #expect(!head.contains("note"))
    // the notes print nothing, and are no notes of the document either
    #expect(doc.notes.isEmpty && doc.footnotes.isEmpty)
    // the line opens in the head's own face; the font record after A is a change of face
    // from B on (`headerFontRuns`)
    #expect(doc.headerFonts[1] == nil)
    #expect(doc.headerFontRuns == [1: [head: [HFFontRun(charIdx: 1, font: 0)]]])
    // the body keeps the document's font: nothing carried out of the head
    let body = doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }.filter { $0.text.hasPrefix("line") }
    #expect(!body.isEmpty)
    #expect(body.allSatisfy { $0.font == nil && $0.colour == nil })
}

@Test func teardownA8AFontAfterTextInAHeadChangesTheFaceFromThere() throws {
    // WS7 teardown 3.15 (run h24-allow): `A` prints in Courier 12pt at the margin (576
    // decipoints), then the font record's 24pt Times for `BCD`, and `EF` 1800 HMI (1 inch)
    // from the margin, after the tab: 1296.
    var data = ws7Header()
    data += Array(".he ".utf8) + h24Line()
    data += HARD
    for n in 1...3 { data += Array("line 0\(n)".utf8) + HARD }
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    let pdf = String(decoding: emitPDF(doc, mode: .printed), as: UTF8.self)
    let pattern = #/ (\d+) Tf 0 Ts (?:[0-9.]+ Tz )?([0-9.]+) 780\.0 Td \(([^)]*)\) Tj/#
    let drawn = pdf.matches(of: pattern).map { "\($0.1) \($0.2) \($0.3)" }
    #expect(drawn == ["12 57.6 A", "24 64.8 BCD", "24 129.6 EF"])
    let line = try #require(docToPagelines(doc, printed: true).first?.headerLines?.first)
    #expect(line.font == nil)
    #expect(line.pieces == [HeadFootPiece(text: "A", font: nil),
                            HeadFootPiece(text: "BCD      ", font: 0),
                            HeadFootPiece(text: "EF", font: 0, x: 129.6)])
    #expect(line.pieces?.map { $0.text }.joined() == line.text)
}

@Test func teardownA8ANoteInAHeadLeavesTheBodyNotesPaired() throws {
    // WS7 teardown 3.15 (run h24-allow): a footnote in a `.he` line prints neither its
    // number nor its note, so the body's own footnote is note 1.
    var data = ws7Header()
    data += Array(".he Head".utf8) + footnote("head note")
    data += HARD
    data += Array("Body".utf8) + footnote("body note")
    data += Array(" text".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    #expect(doc.notes.map { $0.text } == ["body note"])
    #expect(doc.footnotes.map { $0.map { $0.text } } == [["body note"]])
}

@Test func teardownA8TheSameRecordsInTheBodyPrintTheirNote() throws {
    // WS7 teardown 3.15 (run h24-body): on a body line the footnote prints its reference
    // and its note, and the font goes on into the next lines.
    var data = ws7Header()
    data += h24Line() + HARD
    data += Array("line 01".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    #expect(doc.notes.map { $0.kind } == [.footnote, .annotation])
    let next = doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }.first { $0.text == "line 01" }
    #expect(next?.font != nil)
}

@Test func teardownA8AnUntaggedAnnotationDoesNotWidenTheFootnoteMarker() throws {
    // WS7 teardown 3.15 (run h24-body): `1.note text` prints flush, beside an annotation
    // that prints no marker of its own.
    var data = ws7Header()
    data += h24Line() + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    #expect(notesMarkerPadCols(try parse(data)) == nil)
}

@Test func teardownA8AHeadTabLandsWhereTheSameStopPutsBodyText() throws {
    // WS7 teardown 3.15 (run h24-allow): a tab in a running head goes to its absolute
    // position from the margin, whatever comes before it; control bytes before it take no
    // column. The shape is `sawyer/MAILLIST/PHONE.LST`'s column heading over a 4" stop.
    func tab(_ size: Int, _ absHMI: Int, _ kind: UInt8) -> [UInt8] {
        record(0x09, [UInt8(size & 0xFF), UInt8(size >> 8), UInt8(absHMI & 0xFF), UInt8(absHMI >> 8),
                      kind, 0x20])
    }
    var data = ws7Header()
    data += Array(".h1 ".utf8) + [0x13]
    data += Array("Name".utf8) + [0x13]
    data += tab(5760, 7200, 0x16) + [0x13]
    data += Array("Phone Number".utf8) + [0x13]
    data += HARD
    data += Array("Name".utf8) + tab(6912, 7200, 0x20)
    data += Array("555-1212".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let pdf = String(decoding: emitPDF(try parse(data), mode: .printed), as: UTF8.self)
    func x(of text: String) -> Substring? {
        guard let r = pdf.firstRange(of: " Td (\(text)) Tj") else { return nil }
        let head = pdf[..<r.lowerBound]
        let parts = head.split(separator: " ")
        return parts.count >= 2 ? parts[parts.count - 2] : nil
    }
    #expect(x(of: "Phone Number") != nil)
    #expect(x(of: "Phone Number") == x(of: "555-1212"))
}

// MARK: - `.RR` with ordinary text (A10)

/// (left, para, right) of the block holding the line `text`.
private func margins(_ doc: Document, _ text: String) -> (Double?, Double?, Double?)? {
    for block in doc.blocks where block.lines.contains(where: { $0.text() == text }) {
        return (block.leftMargin, block.paraMargin, block.rightMargin)
    }
    return nil
}

@Test func teardownA10WS4ReadsRRTextAsARulerFromTheLine() throws {
    // WS4 teardown 7.11 (run w25-rr1): `.RRabc defgh` makes `L----!----!R`, L at the dot
    // (column 1), R at the last non-blank (column 12); the letters are not margin pips. The
    // stops in force are kept.
    var data = Array(".RRabc defgh".utf8) + HARD
    data += Array("X".utf8) + HARD + [0x1A]
    let m = margins(try parse(data, variant: .ws4), "X")
    #expect(m?.0 == 0.0 && m?.1 == nil && m?.2 == 12.0)
    // the ruler grammar itself, columns from the line's start (exe-static.md P16, P19): R
    // at 20; a blank resets, L at 5 and R at 9
    var data2 = Array(".RR-----!-----!----R".utf8) + HARD
    data2 += Array("X".utf8) + HARD
    data2 += Array(".RR L---R".utf8) + HARD
    data2 += Array("Y".utf8) + HARD + [0x1A]
    let doc = try parse(data2, variant: .ws4)
    let x = margins(doc, "X")
    let y = margins(doc, "Y")
    #expect(x?.0 == 0.0 && x?.1 == nil && x?.2 == 20.0)
    #expect(y?.0 == 4.0 && y?.1 == nil && y?.2 == 9.0)
}

@Test func teardownA10WS7ReadsEveryLPRAsAPipUpToTheR() throws {
    // WS7 teardown 5.1 (runs rr59-low, rr59-up, rr59-abc): L, P and R in either case are
    // pips; the last L before the R is the left margin (the second `l` of `hello`), and the
    // R ends the ruler, so the `l` of `world` is ignored. With no pip there is no margin.
    #expect(rulerPips(Array("hello world".utf8)) == (3, nil, 8))
    #expect(rulerPips(Array("HELLO WORLD".utf8)) == (3, nil, 8))
    #expect(rulerPips(Array("abc defgh".utf8)) == (nil, nil, nil))
    #expect(rulerPips(Array("--R---L".utf8)) == (nil, nil, 2))
    var data = Array(".rr--R---L".utf8) + HARD
    data += Array("X".utf8) + HARD + [0x1A]
    #expect(margins(try parse(data, variant: .ws5plus), "X")?.0 == nil)
}

@Test func teardownA10WS7CountsASameLineRulerFromTheDot() throws {
    // WS7 teardown 5.1: on the dot line itself the columns count from the dot as 0. Run
    // rr59-ctl: `.rrL----!----!-----R` is LM 3 and RM 19, and the text fills columns 3-19
    // (`dd ee ff gg hh ii`); runs rr59-low/-up: `.rrhello world` is LM 6, RM 11. The R is
    // the last column text reaches, so the right margin, as `.rm` counts it, is its column
    // + 1 (the factory ruler's R is column 64, `.rm 65`).
    #expect(rulerPips(Array("hello world".utf8), first: 3) == (6, nil, 11))
    #expect(rulerPips(Array("L----!----!-----R".utf8), first: 3) == (3, nil, 19))
    var data = Array(".rrL----!----!-----R".utf8) + HARD
    data += Array("X".utf8) + HARD
    data += Array(".rrhello world".utf8) + HARD
    data += Array("Y".utf8) + HARD + [0x1A]
    let doc = try parse(data, variant: .ws5plus)
    let x = margins(doc, "X")
    let y = margins(doc, "Y")
    #expect(x?.0 == 3.0 && x?.1 == nil && x?.2 == 20.0)
    #expect(y?.0 == 6.0 && y?.1 == nil && y?.2 == 12.0)
}

// MARK: - flagged controls in a WS5+ body

@Test func teardownA3AFlagged9BhItemLeadIsAnExtendedCharacter() throws {
    // WS7 teardown 3.6 (load sanitiser 0x3C1F3): control bytes are examined with bit 7
    // masked, and a flagged lead `9B x 1C` is rewritten to 1Bh: the item's character,
    // exactly as `1B x 1C` gives it.
    var plain = ws7Header()
    plain += [0x61, 0x1B, 0x82, 0x1C, 0x62] + HARD
    plain += [UInt8](repeating: 0x1A, count: 8)
    var flagged = ws7Header()
    flagged += [0x61, 0x9B, 0x82, 0x1C, 0x62] + HARD
    flagged += [UInt8](repeating: 0x1A, count: 8)
    #expect(lineTexts(try parse(flagged)) == lineTexts(try parse(plain)))
    #expect(lineTexts(try parse(flagged)) == ["a\u{E9}b"])
}

@Test func teardownA3AFlagged9DhOpensARecord() throws {
    // WS7 teardown 3.6, 3.7: the record scanners compare the lead with bit 7 masked and the
    // closing 1Dh unmasked, so `9D <count> ... 1D` is a record (here a footnote), while a
    // 9Dh that is no record is a lone 1Dh.
    var note = footnote("note text")
    note[0] = 0x9D
    var data = ws7Header()
    data += Array("Body".utf8) + note
    data += Array(" text".utf8) + HARD
    data += [UInt8](repeating: 0x1A, count: 8)
    let doc = try parse(data)
    #expect(doc.notes.map { $0.text } == ["note text"])
    #expect(lineTexts(doc) == ["Body1 text"])
    var lone = ws7Header()
    lone += [0x61, 0x62, 0x9D, 0x63, 0x64] + HARD
    lone += [UInt8](repeating: 0x1A, count: 8)
    var same = ws7Header()
    same += [0x61, 0x62, 0x1D, 0x63, 0x64] + HARD
    same += [UInt8](repeating: 0x1A, count: 8)
    #expect(lineTexts(try parse(lone)) == lineTexts(try parse(same)))
}

@Test func teardownA3AFlagged9AhEndsTheText() throws {
    // WS7 teardown 3.6 (0x3C224): the load sanitiser ends the text at a 1Ah, and it reads
    // 9Ah as 1Ah. What follows is not part of the document, however much padding comes
    // after it.
    for eof: UInt8 in [0x9A, 0x1A] {
        var data = ws7Header()
        data += Array("kept".utf8) + HARD
        data += [eof]
        data += Array("gone".utf8) + HARD
        data += Array("more".utf8) + HARD
        data += [UInt8](repeating: 0x1A, count: 8)
        #expect(lineTexts(try parse(data)) == ["kept"])
    }
}
