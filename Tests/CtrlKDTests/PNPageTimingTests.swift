/// Triage Q12: which page reads a `.pn`, and what a leading blank run does to the
/// arithmetic. The Swift twin of ctrl-kd's `tests/test_pn_page_timing.py`.
///
/// WHY A PROBE. `-HOLYMAC.WS` printed an automatic `0` at the foot of page 1 where real
/// WS7 prints nothing. The document turns the number off with `.op` in its opening dot
/// block and turns it back on with a later `.pn0` — and that `.pn0` sits immediately
/// after "Charles Maher", the last line page 1 has room for, inside a front matter that
/// is almost entirely BLANK LINES. A blank line prints nothing, so no corpus document
/// can show where a page breaks inside one; only running WordStar can.
///
/// THE PROBES (2026-09-14, ctrl-kd's DOSBox-X harness against a pristine WordStar 7
/// install, decoded with its `pcl_text.py`). Ten text lines to a page (`.pl 12`,
/// `.mt 1`, `.mb 1`), a long run of blank lines, and one dot command moved through it:
///
///     .fo after  5 blanks   footer on page 1
///     .fo after 10 blanks   page 1 takes the AUTOMATIC number, footer from page 2
///     .fo after 25 blanks   pages 1-2 automatic, footer from page 3
///     .op + .pn0 after  9 blanks            page 1 numbered 0
///     .op + .pn0 after 10 blanks            page 1 silent, page 2 numbered 0
///     .op + an inked 10th line, then .pn0   page 1 silent, page 2 `0`
///
/// and the same at WordStar's own 55-line default geometry, which agreed in every case.
///
/// THE RULE, and it is two sentences. A BLANK LINE OCCUPIES A PAGE LINE exactly as an
/// inked one does — nothing about a leading run is special. And A PAGE ENDS THE MOMENT
/// IT IS FULL, so a command sitting exactly on the boundary is read on the NEW page.
/// That second clause is the one triage Q9 measured for `.he`/`.fo`; Q12 says it governs
/// `.pn` and `.op`/`.pg` too, which nothing had tested. One more, from the probe with a
/// bare `.fo` inside the run: a footer in use suppresses the automatic number from the
/// page it is read on, and a later `.pn0` does NOT bring it back — which is why
/// `-HOLYMAC`'s pages 2-3 were already right.
import Foundation
import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

/// WordStar's own default geometry, 55 text lines to a page — the shape this emitter
/// draws a footer on.
private let defGeometry = ".pl 66\r\n.mt 3\r\n.mb 8\r\n.lm1\r\n.rm65\r\n.po1i\r\n.lh8\r\n.ps off\r\n"
/// The probes' own ten-lines-to-a-page geometry, for the boundary cases.
private let smallGeometry = ".pl 12\r\n.mt 1\r\n.mb 1\r\n.lm1\r\n.rm65\r\n.po1i\r\n.lh8\r\n.ps off\r\n"

private func blanks(_ n: Int) -> String {
    String(repeating: "\r\n", count: n)
}

/// What each page actually draws, in page order — read straight out of the emitted PDF's
/// own per-page content streams.
private func drawn(_ prefix: String, _ body: String) -> [[String]] {
    let out = emitPDF(parseWS(bytes(prefix + body)), mode: .printed)
    let text = String(decoding: out, as: UTF8.self)
    var pages: [[String]] = []
    var rest = Substring(text)
    while let open = rest.range(of: "stream\n"), let close = rest.range(of: "endstream") {
        guard open.upperBound <= close.lowerBound else { break }
        let stream = rest[open.upperBound..<close.lowerBound]
        var shown: [String] = []
        var scan = stream
        while let l = scan.range(of: "("), let r = scan.range(of: ") Tj") {
            guard l.upperBound <= r.lowerBound else { break }
            shown.append(String(scan[l.upperBound..<r.lowerBound]))
            scan = scan[r.upperBound...]
        }
        pages.append(shown)
        rest = rest[close.upperBound...]
    }
    return pages
}

/// (page numbers, automatic-number-on flags) — the mechanism itself, for the geometries
/// this emitter draws no footer on.
private func numbers(_ prefix: String, _ body: String) -> (nums: [Int], on: [Bool]) {
    let doc = parseWS(bytes(prefix + body))
    let pages = docToPagelines(doc, printed: true)
    return (resolvePageNumbers(pnCheckpoints(doc), pages),
            pgnumByPage(pgnumCheckpoints(doc), pages))
}

@Test func aPNOneLineShortOfTheBoundaryNumbersItsOwnPage() {
    // Nine blank lines then `.pn0`, at ten lines to a page: the command is still on
    // page 1, so page 1 is numbered 0 and page 2 is 1.
    var body = ".pn0\r\n.op\r\n"
    body += blanks(9)
    body += ".pn0\r\n"
    body += blanks(11)
    body += "MBODY\r\n"
    let r = numbers(smallGeometry, body)
    #expect(r.on[0] == true)
    #expect(Array(r.nums.prefix(3)) == [0, 1, 2])
}

@Test func aPNExactlyOnTheBoundaryIsReadOnTheNewPage() {
    // The whole point of the round. Ten blank lines fill page 1 exactly; the `.pn0`
    // immediately after them belongs to page 2, so page 1 stays silent under `.op` and
    // page 2 carries the 0.
    var body = ".pn0\r\n.op\r\n"
    body += blanks(10)
    body += ".pn0\r\n"
    body += blanks(10)
    body += "LBODY\r\n"
    let r = numbers(smallGeometry, body)
    #expect(r.on[0] == false)
    #expect(r.on[1] == true)
    #expect(r.nums[1] == 0 && r.nums[2] == 1)
}

@Test func anInkedLastLineThenAPNIsTheHolymacShape() {
    // `-HOLYMAC.WS`'s own arithmetic, in miniature. The tenth line carries ink, the
    // `.pn0` follows it, and real WS7 prints nothing on page 1 and 0 on page 2.
    var body = ".pn0\r\n.op\r\n"
    body += blanks(9)
    body += "NLAST\r\n.pn0\r\n"
    body += blanks(10)
    body += "NBODY\r\n"
    let r = numbers(smallGeometry, body)
    #expect(r.on[0] == false)
    #expect(r.on[1] == true && r.nums[1] == 0)
}

@Test func aBlankLineCostsAPageLineLikeAnInkedOne() {
    // The half of the rule a corpus cannot show, at the geometry this emitter draws
    // footers on. Five blanks then a `.fo` puts the footer on page 1; forty-five blanks
    // then a `.fo` still puts it on page 1, because forty-five fit inside fifty-five.
    var earlyBody = blanks(5)
    earlyBody += ".fo FJ#\r\n"
    earlyBody += blanks(60)
    earlyBody += "JBODY\r\n"
    let early = drawn(defGeometry, earlyBody)
    #expect(early[0] == ["FJ1"])
    var lateBody = blanks(45)
    lateBody += ".fo FH#\r\n"
    lateBody += blanks(20)
    lateBody += "HBODY\r\n"
    let late = drawn(defGeometry, lateBody)
    #expect(late[0] == ["FH1"])
}

@Test func aPNPastTheFirstPageOfABlankRunNumbersTheSecond() {
    // The full-geometry twin of the boundary case: `.op` at the top, sixty blank lines,
    // then `.pn0`. Page 1 holds fifty-five of those blanks and stays silent; the `.pn0`
    // is read on page 2, which prints `0`.
    var body = ".pn0\r\n.op\r\n"
    body += blanks(60)
    body += ".pn0\r\n"
    body += blanks(20)
    body += "KBODY\r\n"
    let pages = drawn(defGeometry, body)
    #expect(pages[0] == [])
    #expect(pages[1] == ["0", "KBODY"])
}

@Test func aBareFOSilencesTheNumberAndALaterPNDoesNotUndoIt() {
    // A bare `.fo` is a footer IN USE, and WSFORMAT's own text says the automatic number
    // is "active only when the footers are not in use". The `.pn0` further down the run
    // does not bring it back.
    // Sequential `+=`, never a chained `+` across many terms (planning #253): macOS
    // CI's type-checker abandons those, and this repo's own pre-push hook rejects them.
    var body = ".pn0\r\n.op\r\n"
    body += blanks(5)
    body += ".fo\r\n"
    body += blanks(50)
    body += ".pn0\r\n"
    body += blanks(20)
    body += "GBODY\r\n"
    let pages = drawn(defGeometry, body)
    #expect(pages[0] == [])
    #expect(!pages.contains(["0"]) && !pages.contains(["1"]))
}

@Test func theCheckpointsCarryTheirLinePosition() {
    // The mechanism, not just its effect: a `.pn` records how many of its own block's
    // lines came before it, which is what lets the boundary case above be answered at
    // all — and two `.pn` commands inside ONE block are now two checkpoints, not one,
    // because their positions differ.
    let doc = parseWS(bytes(smallGeometry + ".pn3\r\nA\r\nB\r\n.pn7\r\nC\r\n"))
    let cps = pnCheckpoints(doc)
    #expect(Array(cps.suffix(2).map(\.pn)) == [3, 7])
    #expect(cps[cps.count - 1].lineIndex > cps[cps.count - 2].lineIndex)
}

// ====== the footnote path reads the document's own `.op` (2026-09-15) ======
//
// Research: "Why real WS7 prints no page number on some documents" (2026-09-15). Real
// WordStar 7 numbers every page unless the document says otherwise, and `.op` is one of
// the four things that say otherwise. The bundled sample `LYING.WS` carries `.op` AND a
// footnote, and the positional walk the Q12 tests above introduced printed a number on
// all three of its pages: a page built by the FOOTNOTE paginator got no `readPos`, the
// walk's inner loop never ran, and the answer stayed on the seeded "numbering ON"
// checkpoint 0 — the `.op` was never consulted. Across all 308 WS7 captures no document
// carrying `.op` prints a number, with zero counter-examples, and a whole-corpus sweep
// finds exactly three documents carrying both a footnote and a numbering-off command,
// so those are the whole blast radius.

/// WordStar's own default geometry with no `.ps off` — a document whose ONLY dot command
/// is the one under test, so nothing else can be blamed for the answer.
private let plainGeometry = ".pl 66\r\n.mt 3\r\n.mb 8\r\n.po1i\r\n"

/// A one-line FOOTNOTE — the note kind that sends a document down `paginatePrintedNotes`,
/// which is the paginator that lost the `.op`.
private func footnote(_ text: String) -> String {
    String(decoding: ws7Note(bytes(text), cmd: 0x03, number: 1), as: UTF8.self)
}

/// Per page, the digit-only chunks drawn on that page's LOWEST print line — the research
/// note's own install-independent test for "is there an automatic page number here",
/// which assumes no fixed x or y (`.pl`, `.mb`, `.po` and `.pc` all move the real one).
private func footDigits(_ data: [UInt8]) -> [[String]] {
    let out = emitPDF(parseWS(data), mode: .printed)
    let text = String(decoding: out, as: UTF8.self)
    var pages: [[String]] = []
    var rest = Substring(text)
    while let open = rest.range(of: "stream\n"), let close = rest.range(of: "endstream") {
        guard open.upperBound <= close.lowerBound else { break }
        let stream = rest[open.upperBound..<close.lowerBound]
        // PDF y grows UPWARD, so the page's lowest print line is its SMALLEST y.
        var lowest: Double?
        var byY: [Double: [String]] = [:]
        for line in stream.split(separator: "\n") {
            guard let tj = line.range(of: ") Tj") else { continue }
            guard let td = line.range(of: " Td (") else { continue }
            let shown = String(line[td.upperBound..<tj.lowerBound])
            let head = line[line.startIndex..<td.lowerBound].split(separator: " ")
            guard let y = head.last.flatMap({ Double($0) }) else { continue }
            byY[y, default: []].append(shown)
            if lowest == nil || y < lowest! { lowest = y }
        }
        let foot = lowest.flatMap { byY[$0] } ?? []
        pages.append(foot.filter { chunk in
            let t = chunk.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.allSatisfy { $0.isNumber }
        })
        rest = rest[close.upperBound...]
    }
    return pages
}

@Test func lyingWSPrintsNoAutomaticPageNumberOnAnyPage() throws {
    // The regression itself, pinned on the bundled public-domain sample. LYING.WS's `.op`
    // is the FIRST LINE OF THE FILE — it follows the header block's closing 0x1D with no
    // CR LF before it — and it turns the automatic number off for the whole document.
    // Real WS7's own capture prints no number on any of the three pages.
    let data = try BundledSamples.bytes(for: "LYING")
    let doc = parseWS(data)
    #expect(!doc.notes.isEmpty)          // LYING is the fixture BECAUSE it has a footnote
    let pages = docToPagelines(doc, printed: true)
    #expect(pgnumByPage(pgnumCheckpoints(doc), pages) == [false, false, false])
    #expect(footDigits(data) == [[], [], []])
}

@Test func aFootnoteDocumentThatOmitsNumbersReadsItsOwnOP() {
    // The same shape synthetically, so the rule is pinned even if the sample ever changes.
    // Sequential `+=`, never a chained `+` across many terms (planning #253).
    var body = ".op\r\n"
    body += "OPBODY"
    body += footnote("A footnote.")
    body += "\r\n"
    body += blanks(80)
    body += "OPTAIL\r\n"
    #expect(footDigits(bytes(plainGeometry + body)) == [[], []])
}

@Test func aFootnoteDocumentWithPNIsStillNumbered() {
    // The control, and the half a too-broad fix would break: footnotes have NOTHING to do
    // with the automatic number. 28 numbered WS7 captures carry real footnotes. `.pn` says
    // number the pages, and it still does.
    var body = ".pn 1\r\n"
    body += "PNBODY"
    body += footnote("A footnote.")
    body += "\r\n"
    body += blanks(80)
    body += "PNTAIL\r\n"
    #expect(footDigits(bytes(plainGeometry + body)) == [["1"], ["2"]])
}

@Test func theFootnotePaginatorRecordsWhereEachPageReadTo() throws {
    // The first half of the mechanism: a page built by the notes-aware paginator now
    // carries its own `readPos`, so it answers the walk directly instead of falling
    // through to the seeded default.
    var opBody = ".op\r\nXBODY"
    opBody += footnote("A footnote.")
    opBody += "\r\n"
    opBody += blanks(80)
    opBody += "XTAIL\r\n"
    var pnBody = ".pn 1\r\nXBODY"
    pnBody += footnote("A footnote.")
    pnBody += "\r\n"
    pnBody += blanks(80)
    pnBody += "XTAIL\r\n"
    let cases: [[UInt8]] = [try BundledSamples.bytes(for: "LYING"),
                            bytes(plainGeometry + opBody),
                            bytes(plainGeometry + pnBody)]
    for data in cases {
        let doc = parseWS(data)
        #expect(hasPlaceableNotes(doc))
        let positions = docToPagelines(doc, printed: true).map(\.readPos)
        #expect(positions.allSatisfy { $0 != nil })
        let bis = positions.map { $0!.bi }
        #expect(bis == bis.sorted())
    }
}

@Test func aPageWithNoReadPositionFallsBackToTheBlockRangeRule() {
    // The second half, and the belt to that brace: a page that carries no read position
    // at all — a synthetic or degenerate page, from any future paginator — is answered by
    // block range (the last checkpoint at or before the highest block the page carries),
    // not by the seeded checkpoint 0. Checkpoints here: ON at block 0, OFF at block 2.
    let positions = [(blockIndex: 0, lineIndex: 0), (blockIndex: 2, lineIndex: 0)]
    var early = PageLine([Span(text: "x")])
    early.bi = 1
    var late = PageLine([Span(text: "y")])
    late.bi = 3
    let earlyPage = Page([early], headers: [:], footers: [:])
    let latePage = Page([late], headers: [:], footers: [:])
    let emptyPage = Page([], headers: [:], footers: [:])
    #expect(checkpointsByPage(positions, [earlyPage, latePage]) == [0, 1])
    #expect(checkpointsByPage(positions, [latePage]) == [1])
    // No `bi` anywhere on the page: nothing to range over, walk unchanged.
    #expect(checkpointsByPage(positions, [emptyPage]) == [0])
}
