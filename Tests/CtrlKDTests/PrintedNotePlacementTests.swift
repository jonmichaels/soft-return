import Testing
@testable import CtrlKD

/// Where Printed puts a footnote, and what it calls it (WS7 teardown: report 11.11, 14.8,
/// 14.15, 15.1, 15.10; runs fnmb0, fn2, fnfit52, fnr0-fnr99, fnbig, fnhuge, fnlong120,
/// fnnum5, w16-fnlow2, w16-fnup2). Swift-side mirror of ctrl-kd's
/// `tests/test_printed_note_placement.py`; synthetic documents only.

private let sep = String(repeating: "-", count: 20)

/// `nLines` body lines, the note's reference at the end of `refLine`.
private func noteDoc(_ nLines: Int, ref refLine: Int, note: String, number: Int = 0,
                     head: [UInt8] = []) -> Document {
    var data = head + ws7Block(0x00)
    for i in 1...nLines {
        data += bytes("line " + (i < 10 ? "0\(i)" : "\(i)"))
        if i == refLine { data += ws7Note(bytes(note), number: number) }
        data += HARD
    }
    return parseWS(data)
}

private func pagesOf(_ doc: Document) -> [[String]] {
    docToPagelines(doc, printed: true).map { pg in
        pg.map { line in
            line.map(\.text).joined()
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
    }
}

private func words(_ n: Int) -> String {
    (0..<n).map { i in "w" + String(repeating: "0", count: i < 10 ? 2 : (i < 100 ? 1 : 0)) + "\(i)" }
        .joined(separator: " ")
}

/// The body lines, without the reference mark a line may end in.
private func body(_ page: [String]) -> [String] {
    page.filter { $0.hasPrefix("line ") }.map { String($0.prefix(7)) }
}

private func noteLines(_ page: [String]) -> [String] {
    page.filter { $0.hasPrefix("w") || $0.hasPrefix("1.") }
}

@Test func aNoteReferenceOnATrailingBlankLastLineIsKept() {
    // run fnmb0: the note sits on the unterminated empty line after line 05
    var data = ws7Block(0x00)
    for i in 1...5 { data += bytes("line 0\(i)") + HARD }
    data += ws7Note(bytes("note text"), number: 0)
    let pages = pagesOf(parseWS(data))
    #expect(pages.count == 1)
    #expect(pages[0].contains(sep) && pages[0].contains("1.note text"), "\(pages)")
}

@Test func aNoteThatDoesNotFitMovesWithItsReferenceLine() {
    // run fnfit52: a one-line note at line 52 of 60; 51 is the last line that keeps its note
    var pages = pagesOf(noteDoc(60, ref: 52, note: "note"))
    #expect(body(pages[0]).count == 51 && body(pages[0]).last == "line 51")
    #expect(body(pages[1]).first == "line 52")
    #expect(pages[1].contains("1.note") && !pages[0].contains("1.note"))
    pages = pagesOf(noteDoc(60, ref: 51, note: "note"))
    #expect(body(pages[0]).last == "line 51" && pages[0].contains("1.note"))
}

@Test func aLongNoteMovesWholeBelowFnrunAndRunsAtOrAboveIt() {
    // runs fnlong2 / fnr0-fnr99: line 50 of 60 leaves 6 note lines of room; the factory
    // fnrun is 8, so the line and the whole note go to page 2
    let note = words(100)
    var pages = pagesOf(noteDoc(60, ref: 50, note: note))
    #expect(body(pages[0]).last == "line 49")
    #expect(body(pages[1]).first == "line 50")
    // fnrun 6 (a patched WS.EXE): the note runs, one line under the reference
    var doc = noteDoc(60, ref: 50, note: note)
    doc.footnoteRunLines = 6
    pages = pagesOf(doc)
    #expect(body(pages[0]).last == "line 50")
    #expect(noteLines(pages[0]).count == 1)
    // fnrun 7: moves again
    doc = noteDoc(60, ref: 50, note: note)
    doc.footnoteRunLines = 7
    #expect(body(pagesOf(doc)[0]).last == "line 49")
}

@Test func aRunningNoteFillsThePageAndContinuesUnderTheSeparator() {
    // run fnbig: a 20-line note at line 40: no body line after it on the page, and the
    // rest on page 2 with the Continued line directly under the separator, a blank after it
    let pages = pagesOf(noteDoc(60, ref: 40, note: words(250)))
    #expect(body(pages[0]).last == "line 40")
    let next = pages[1]
    guard let s = next.firstIndex(of: sep) else {
        Issue.record("no separator on page 2")
        return
    }
    #expect(next[s + 1] == "...Continued..." && next[s + 2] == "")
    #expect(body(next).first == "line 41")
}

@Test func aNoteLongerThanAPageMakesNoteOnlyPages() {
    // run fnlong120: no floor of body lines against a carried-over note
    let pages = pagesOf(noteDoc(60, ref: 50, note: words(1500)))
    let noteOnly = pages.filter { body($0).isEmpty }
    #expect(!noteOnly.isEmpty && noteOnly.allSatisfy { $0.first == sep })
}

/// (baseline y in points, text) for each line of a page: the page top plus every line's own
/// lead, the document default 12 where it has none.
private func ys(_ pg: Page) -> [(y: Double, text: String)] {
    var y = 36.0
    var out: [(y: Double, text: String)] = []
    for ln in pg {
        y += ln.lead ?? 12.0
        let text = ln.map(\.text).joined()
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        out.append((((y * 10).rounded()) / 10, text))
    }
    return out
}

private func chainPages(_ wordCount: Int) -> [Page] {
    docToPagelines(noteDoc(60, ref: 50, note: words(wordCount)), printed: true)
}

private func at(_ rows: [(y: Double, text: String)], _ prefix: String) -> [Double] {
    rows.filter { $0.text.hasPrefix(prefix) }.map(\.y)
}

@Test func aNoteOnlyPageSits16PtBelowTheGridAndPrintsItsNumber() {
    // runs fnlong120, fnch175, fnch250: separator 616, Continued 736, first note 976, the
    // 51st note line at BB + 16 decipoints
    let pg = chainPages(1464)[2]
    let rows = ys(pg)
    #expect(rows[0].y == 61.6 && rows[0].text == sep)
    #expect(rows[1].y == 73.6 && rows[1].text == "...Continued...")
    #expect(rows[3].y == 97.6 && rows[rows.count - 1].y == 697.6)
    #expect(rows.count == 54)
    // nothing on it to look the automatic number up from: it takes the state of the last
    // block read (run fnlong120 prints "3" on this page)
    #expect(pg.explicitBreakBI != nil)
}

@Test func thePageWhereAChainOfNoteOnlyPagesEndsSitsAtBBLessRLH2H() {
    // run fnlong120 p4: R = 19 note lines left; P = BB - R*LH - 2H puts the separator at 396
    // pt, one blank row more under Continued, the first note line at P + 720 (444 pt) and
    // the last three rows above BB
    let rows = ys(chainPages(1464)[3])
    #expect(at(rows, "line ").first == 48.0 && at(rows, "line ").last == 156.0)
    #expect(at(rows, "-----") == [396.0])
    #expect(at(rows, "...Continued") == [408.0])
    let notes = at(rows, "w")
    #expect(notes.count == 19 && notes.first == 444.0 && notes.last == 660.0)
}

@Test func aRemainderTooLongForTheTextPrintsUnderItAndRunsOn() {
    // run fnch250: 250 note lines, note-only pages 3-5; page 6 has 47 left, which with 2H
    // does not fit under the resumed text: lines 51-55, the separator three rows under the
    // last of them, 45 note lines to BB, the other two on page 7, again under the text,
    // with the extra blank row
    let pages = chainPages(2898)
    #expect(pages.count == 7)
    var rows = ys(pages[5])
    #expect(at(rows, "line ").last == 96.0 && at(rows, "line ").count == 5)
    #expect(at(rows, "-----") == [132.0] && at(rows, "...Continued") == [144.0])
    var notes = at(rows, "w")
    #expect(notes.first == 168.0 && notes.last == 696.0 && notes.count == 45)
    rows = ys(pages[6])
    #expect(rows.filter { $0.text.hasPrefix("line ") }.last?.text == "line 60")
    #expect(at(rows, "line ").last == 96.0 && at(rows, "line ").count == 5)
    #expect(at(rows, "-----") == [132.0] && at(rows, "...Continued") == [144.0])
    notes = at(rows, "w")
    #expect(notes == [180.0, 192.0])
}

@Test func aBareFHashStartIsNotAddedToTheStoredNumbers() {
    // run fnnum5: `.f# 5` stored 4, 5 / 0, 1 and printed 5., 6. / 1., 2.
    var data = bytes(".f# 5") + HARD + ws7Block(0x00)
    data += bytes("one") + ws7Note(bytes("n"), number: 4) + HARD
    data += bytes("two") + ws7Note(bytes("n"), number: 5) + HARD
    data += bytes(".pa") + HARD
    data += bytes("three") + ws7Note(bytes("n"), number: 0) + HARD
    let pages = pagesOf(parseWS(data))
    #expect(pages[0].filter { $0.hasSuffix(".n") } == ["5.n", "6.n"])
    #expect(pages[1].filter { $0.hasSuffix(".n") } == ["1.n"])
}

private func fHash(_ arg: String, _ cmd: String = ".f# ") -> [UInt8] {
    var out = bytes(cmd + arg)
    out += HARD
    out += ws7Block(0x00)
    out += bytes("one")
    out += ws7Note(bytes("n"), number: 0)
    out += HARD
    out += bytes("two")
    out += ws7Note(bytes("n"), number: 1)
    out += HARD
    return out
}

@Test func fHashLettersLabelThePrintedNotes() {
    // runs w16-fnlow2 / w16-fnup2: the .f# format at print time, not the note's stored nibble
    let low = parseWS(fHash("a"))
    #expect(low.footnoteNumberFormat == .lower)
    #expect(pagesOf(low)[0].filter { $0.hasSuffix(".n") } == ["a.n", "b.n"])
    let up = parseWS(fHash("A"))
    #expect(pagesOf(up)[0].filter { $0.hasSuffix(".n") } == ["A.n", "B.n"])
}

@Test func digitsAndModesInFHashKeepArabicLabels() {
    for arg in ["3", "d 1", "page", "p"] {
        let doc = parseWS(fHash(arg))
        #expect(doc.footnoteNumberFormat == nil, "\(arg)")
        let marks = pagesOf(doc)[0].filter { $0.hasSuffix(".n") }
        #expect(marks.first?.hasPrefix("1.") == true || marks.first?.hasPrefix("3.") == true,
                "\(arg): \(marks)")
    }
}

@Test func fHashLettersReachTheOtherPrintedExports() {
    let doc = parseWS(fHash("a"))
    #expect(emitRTF(doc, mode: .printed).contains(#"\ftnnalc"#))
    var eData = bytes(".e# A")
    eData += HARD
    eData += ws7Block(0x00)
    eData += bytes("x")
    eData += ws7Note(bytes("end"), cmd: 0x04, number: 0)
    eData += HARD
    #expect(emitRTF(parseWS(eData), mode: .printed).contains(#"\aftnnauc"#))
}

/// A note-refs scheme the caller names wins over the document; without one, Modern follows
/// the document's `.f#`/`.e#` like Printed. Port of ctrl-kd's
/// `test_modern_follows_f_hash_letters_unless_note_refs_is_given`.
@Test func modernFollowsFHashLettersUnlessNoteRefsIsGiven() {
    let doc = parseWS(fHash("a"))
    #expect(emitText(doc, mode: .modern).contains("[a] n"))
    #expect(emitRTF(doc, mode: .modern).contains(#"\ftnnalc"#))
    let footnotes = { (flow: SemanticFlow) in
        Array(flow.notes.filter { $0.kind == .footnote }.map(\.shown).prefix(2))
    }
    #expect(footnotes(modernSemanticFlow(doc)) == ["a", "b"])
    for scheme in [NoteRefs.word, .prefixed] {
        let options = EmitOptions(noteRefs: scheme)
        let text = emitText(doc, mode: .modern, options: options)
        #expect(text.contains("[1] n") && !text.contains("[a]"), "\(scheme)")
        #expect(!emitRTF(doc, mode: .modern, options: options).contains(#"\ftnnalc"#))
        #expect(footnotes(modernSemanticFlow(doc, noteRefs: scheme)) == ["1", "2"])
    }
    var eData = bytes(".e# A")
    eData += HARD
    eData += ws7Block(0x00)
    eData += bytes("x")
    eData += ws7Note(bytes("end"), cmd: 0x04, number: 0)
    eData += HARD
    let eDoc = parseWS(eData)
    #expect(modernSemanticFlow(eDoc).notes.map(\.shown) == ["A"])
    #expect(modernSemanticFlow(eDoc, noteRefs: .word).notes.map(\.shown) == ["i"])
}

/// WS7 prints an annotation with no tag without any mark, in the text or before the note:
/// its text sits at the margin (the capture of run ann52, WS7 report 15.1). The other outputs
/// keep a running count. Port of ctrl-kd's `test_an_untagged_annotation_prints_no_mark`.
@Test func anUntaggedAnnotationPrintsNoMark() {
    var data = Array("Body text".utf8)
    data += ws7Note(Array("An annotation.".utf8), cmd: 0x05, number: 0)
    data += Array(".\r\n".utf8)
    let doc = parseWS(data)
    let note = doc.notes[0]
    #expect(noteLabel(note, doc: doc, index: 0, printed: true) == "")
    #expect(noteLabel(note, doc: doc, index: 0, printed: false) == "1")
    let texts = contentSpans(emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .off)))
        .map(\.text)
    #expect(texts.contains("An annotation."))
    #expect(!texts.contains("1"))
}
