/// Port of ctrl-kd's `tests/test_head_foot_timing.py` (triage Q9).
///
/// THE RULE, derived on the real thing. Nine probe documents were authored and printed
/// through ctrl-kd's own DOSBox-X harness (`tools/wordstar_harness.sh ws7`) against a
/// pristine WordStar 7 install and decoded with `tools/pcl_text.py`: a `.he`/`.fo` in a
/// page's opening dot block, after one blank line, after two, after a line of text, at
/// the very top of the file, several on one page, and the same positions on pages opened
/// by `.pa` and by organic overflow, at two page geometries (a 14-line page and
/// WordStar's own 55-line default).
///
///     A `.he` governs the page it is read on only when NOTHING has been printed on that
///     page yet -- and a blank line counts as printed. Otherwise it governs the next
///     page. A `.fo` governs the page it is read on wherever it sits, because a footer is
///     drawn at the bottom, after everything else on the page. And a page ENDS THE MOMENT
///     IT IS FULL, not when the next line turns out not to fit, so a dot command sitting
///     exactly on that boundary is read on the NEW page.
///
/// Every probe agreed, with no exceptions. `sawyer/MACROS/HOLYMAC/-HOLYMAC.WS` appeared
/// to contradict that on three of its 302 pages (17, 177 and 184, where real WS7 applies
/// a `.he` to the page it sits on). It does not: the commands were being read in the
/// wrong PLACE. This file tests the two things that were wrong.
import Testing
@testable import CtrlKD

private let hard: [UInt8] = [0x0d, 0x0a]
private let soft: [UInt8] = [0x8d, 0x0a]
/// WordStar's own stored page-break line ending.
private let pageMark: [UInt8] = [0x0d, 0x8a]

private func timingDoc(_ body: [UInt8]) -> Document {
    parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body)
}

/// A 12-line sheet with 2-line margins: 8 body lines a page, so a handful of lines is a
/// page and the probes' own arithmetic fits in a test.
private let geometry: [UInt8] = {
    var g = bytes(".pl 12")
    g += hard
    g += bytes(".mt 2")
    g += hard
    g += bytes(".mb 2")
    g += hard
    return g
}()

private func lines(_ prefix: String, _ range: ClosedRange<Int>) -> [UInt8] {
    var out: [UInt8] = []
    for i in range {
        out += bytes("\(prefix)\(i)")
        out += hard
    }
    return out
}

private func pageHeads(_ doc: Document) -> [String?] {
    layoutPrintedPagesPlain(doc).map { $0.headers[1] }
}

private func pageFeet(_ doc: Document) -> [String?] {
    layoutPrintedPagesPlain(doc).map { $0.footers[1] }
}

// ------------------------------------------------------------------ the rule itself

@Test func aHeadReadAfterALineGovernsTheNextPage() throws {
    // The probes' own answer, and this engine's behaviour before any of this: one line
    // on the page -- here a blank -- is enough.
    var body = geometry
    body += bytes(".he FIRST")
    body += hard
    body += lines("L", 1...8)
    body += hard
    body += bytes(".he SECOND")
    body += hard
    body += lines("M", 1...8)
    let heads = pageHeads(timingDoc(body))
    #expect(heads[0] == "FIRST" && heads[1] == "FIRST", "\(heads)")
    #expect(heads[2] == "SECOND", "\(heads)")
}

@Test func aFootReadAnywhereOnAPageGovernsThatPage() throws {
    // A footer is drawn at the bottom, so it is never too late for it -- the same
    // probes, the same pages, the opposite answer.
    var body = geometry
    body += bytes(".fo FIRST")
    body += hard
    body += lines("L", 1...4)
    body += bytes(".fo SECOND")
    body += hard
    body += lines("M", 1...4)
    #expect(pageFeet(timingDoc(body))[0] == "SECOND")
}

// ------------------------------------------- 1: read where the author typed it

@Test func aHeadRedefinedMidParagraphIsReadThere() throws {
    // `-HOLYMAC.WS` pages 177 and 184: the author redefines the running head BETWEEN two
    // physical lines of one paragraph. The command's position used to be recorded as a
    // whole BLOCK ("the paragraph after this one"), which deferred it past every
    // remaining line of that paragraph -- and, when the paragraph straddled a page
    // break, onto the page after the one WS7 gives it.
    var body = geometry
    body += bytes(".he FIRST")
    body += hard
    body += lines("L", 1...6)
    body += bytes("P1")                 // page 1's last two lines, one paragraph
    body += soft
    body += bytes("P2")
    body += pageMark
    body += bytes(".he SECOND")         // -- and the command right after them
    body += hard
    body += bytes("P3")                 // the paragraph's tail, page 2
    body += soft
    body += bytes("P4")
    body += hard
    let doc = timingDoc(body)
    #expect(doc.hfEventsWithin.contains { $0 != nil },
            "the command sits inside a block and must record where")
    let heads = pageHeads(doc)
    #expect(heads[0] == "FIRST", "\(heads)")
    #expect(heads[1] == "SECOND", "\(heads)")
}

@Test func aHeadBetweenBlocksStillRecordsNoPosition() throws {
    // The common case is unchanged: a command with nothing open in front of it is a
    // plain block-boundary event, exactly as before.
    var body = bytes(".he ONLY")
    body += hard
    body += bytes("text")
    body += hard
    let doc = timingDoc(body)
    #expect(doc.hfEventsWithin == [nil], "\(doc.hfEventsWithin)")
}

// ----------------------------------- 2: a page ends the moment it is full

@Test func aFootReadOnAFullPageBelongsToTheNextOne() throws {
    // `sawyer/MACROS/HOLYMAC/8MAC`: page 1 fills exactly, and a bare `.fo` -- the one
    // that turns the running foot off -- sits immediately after its last line. Real WS7
    // prints `286` at the foot of page 1 and nothing on pages 2-10, so WordStar had
    // already closed page 1 when it read that command. This engine breaks lazily, when
    // the next line turns out not to fit, and so read it while page 1 was still open and
    // silenced page 1's own footer.
    var body = geometry
    body += bytes(".fo KEEP")
    body += hard
    body += lines("L", 1...8)           // page 1 full
    body += bytes(".fo")
    body += hard
    body += lines("M", 1...4)
    let feet = pageFeet(timingDoc(body))
    #expect(feet[0] == "KEEP", "\(feet)")
    #expect(feet[1] == nil, "\(feet)")
}

@Test func aFootReadBeforeAPageIsFullStillGovernsIt() throws {
    // The guard above must not fire early: the same document with room left on page 1
    // keeps the old, correct answer.
    var body = geometry
    body += bytes(".fo KEEP")
    body += hard
    body += lines("L", 1...4)
    body += bytes(".fo")
    body += hard
    body += lines("M", 1...4)
    #expect(pageFeet(timingDoc(body))[0] == nil)
}
