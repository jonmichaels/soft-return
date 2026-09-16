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

// MARK: - the same Q9 rule in MODERN (2026-09-15)
//
// Modern snapshotted BOTH head and foot at the moment a page took its first content —
// the HEADER rule, applied to footers as well — so a `.fo` read part-way down a page put
// its text on the NEXT one. Printed has read Q9 correctly since the 8MAC measurement
// above; these are the twins of the two tests either side of this comment, on Modern's
// own pages. Port of ctrl-kd's `test_modern_reads_a_mid_page_foot_onto_that_page` and
// its siblings.

/// Every op drawn on a Modern page, as (x, y, text), one list per page.
private func modernDrawn(_ doc: Document) -> [[(x: Double, y: Double, text: String)]] {
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions())
    let whole = String(decoding: pdf, as: UTF8.self)
    var out: [[(x: Double, y: Double, text: String)]] = []
    for chunk in whole.components(separatedBy: ">>\nstream\n").dropFirst() {
        let stream = chunk.components(separatedBy: "\nendstream")[0]
        var page: [(x: Double, y: Double, text: String)] = []
        var search = stream.startIndex..<stream.endIndex
        let pattern = #"Ts ([\d.]+) ([\d.]+) Td \(([^)]*)\) Tj"#
        while let range = stream.range(of: pattern, options: .regularExpression,
                                       range: search) {
            let body = stream[range]
            let fields = body.components(separatedBy: " ")
            if fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]) {
                let open = body.range(of: "(")!
                let close = body.range(of: ") Tj")!
                page.append((x: x, y: y,
                             text: String(body[open.upperBound..<close.lowerBound])))
            }
            search = range.upperBound..<stream.endIndex
        }
        out.append(page)
    }
    return out
}

/// The text drawn on each Modern page's own footer row (y 44.0).
private func modernFeet(_ doc: Document) -> [String?] {
    modernDrawn(doc).map { page in
        let row = page.filter { abs($0.y - 44.0) < 0.05 }.map(\.text).joined()
        return row.isEmpty ? nil : row
    }
}

/// BLANK-SEPARATED PARAGRAPHS ON PURPOSE — Modern's flow is block-granular, so a `.fo`
/// typed between two physical lines of ONE paragraph never reaches it. See the Q9 note in
/// `PDFModernLayout.modernStreams`.
private let modernFiller: [UInt8] = {
    var out: [UInt8] = []
    for _ in 0..<40 {
        out += bytes("The quick brown fox jumps over the lazy dog, and keeps running "
                     + "until this line has to wrap.")
        out += hard
        out += hard
    }
    return out
}()

@Test func modernReadsAMidPageFootOntoThatPage() {
    // A `.fo` read after the page has already taken content governs THAT page in Modern
    // too — a footer is drawn at the bottom, after everything else on the page.
    var body = bytes(".fo FIRST") + hard
    body += bytes("Opening line.") + hard + hard
    body += bytes(".fo SECOND") + hard
    body += modernFiller
    let feet = modernFeet(timingDoc(body))
    #expect(feet.count > 1)
    #expect(feet.first ?? nil == "SECOND")
}

@Test func modernReadsAFootAfterAFullPageOntoTheNextOne() {
    // The other half of Q9, and the reason this is a PENDING state rather than a snapshot
    // taken at the command: a footer read when the page can take no more content belongs
    // to the next page.
    var body = bytes(".fo FIRST") + hard
    body += modernFiller
    body += bytes(".fo SECOND") + hard
    body += modernFiller
    let feet = modernFeet(timingDoc(body))
    #expect(feet.first ?? nil == "FIRST")
    #expect(feet.last ?? nil == "SECOND")
}

@Test func modernReadsAFootTypedJustBeforeAPageBreakOntoThatPage() {
    // An explicit `.pa` is not "the page was full": the `.fo` in front of it is read while
    // the page is still open, so it governs THAT page. Printed says the same — its own
    // `pageAlreadyFull` peeks at the next LINE, and a page break is not one — and this is
    // why only the OVERFLOW close leaves the pending footer behind.
    var body = bytes(".fo FIRST") + hard
    body += bytes("Opening line.") + hard + hard
    body += bytes(".fo SECOND") + hard
    body += bytes(".pa") + hard
    body += bytes("Second page.") + hard
    #expect(modernFeet(timingDoc(body)).first ?? nil == "SECOND")
}

@Test func modernStillReadsAHeadOnlyAtTheTop() {
    // The header half is UNCHANGED: a `.he` read after the page's first line cannot reach
    // it, in Modern exactly as in Printed.
    var body = bytes(".he FIRST") + hard
    body += bytes("Opening line.") + hard + hard
    body += bytes(".he SECOND") + hard
    body += modernFiller
    let heads = modernDrawn(timingDoc(body)).map { page -> String? in
        let row = page.filter { abs($0.y - 748.0) < 0.05 }.map(\.text).joined()
        return row.isEmpty ? nil : row
    }
    #expect(heads.count > 1)
    #expect(heads[0] == "FIRST")
    #expect(heads[1] == "SECOND")
}
