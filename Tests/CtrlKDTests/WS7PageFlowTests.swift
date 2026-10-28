import Testing
@testable import CtrlKD

/// WS7's vertical page flow in Printed, as the teardown runs show it (WS7 report 14.3,
/// 14.5, 15.1, 15.10). Port of ctrl-kd's `tests/test_ws7_page_flow.py`: each case builds a
/// small WS7 document and asserts what lands on which page, and where.
///
///   a blank line after a full page, or after a trailing `.pa`, is a text line and makes
///   a page that prints its number (pg55b, pa3);
///   a `.pa` on a page that holds nothing yet is ignored (patop, paful);
///   empty soft-return lines at the top of a page ended for room are swallowed,
///   hard-return ones are not (sb8d, blank3);
///   a page ended by a bare form feed prints no foot (ff2);
///   under `.lh a` a line is led by the font it starts in and nothing carries further
///   (lead3, lead5), and a line whose font raises its height stays at the page bottom
///   when the rise fits the room left (tall24, tall36);
///   the automatic number's baseline does not move with `.cw` (w16-cwtab).
///
/// Fixtures are built with sequential `+=`, never a chained `+` expression (planning #253).
@Suite struct WS7PageFlowTests {

    /// A WS7 document: the header block makes it read as one, never as plain text.
    static func doc(_ body: [UInt8], dots: [UInt8] = [], variant: Variant? = nil) -> Document {
        var src = variant == nil ? ws7Block(0x00) : []
        src += dots
        src += body
        return parseWS(src, variant: variant)
    }

    static func lines(_ n: Int, first: Int = 1) -> [UInt8] {
        var out: [UInt8] = []
        for k in first..<(first + n) {
            out += bytes("line \(k < 10 ? "0" : "")\(k)")
            out += HARD
        }
        return out
    }

    static func pages(_ doc: Document) -> [Page] {
        docToPagelines(doc, printed: true)
    }

    static func texts(_ page: Page) -> [String] {
        page.map { $0.map(\.text).joined().trimmed() }
    }

    static func face(_ prefix: String) -> Int {
        typestyleNames.firstIndex { ASCII.lowercased($0).hasPrefix(prefix) }!
    }

    // ------------------------------------------------------------------ blank lines
    @Test func aBlankLineAfterAFullPageMakesAPageThatPrintsItsNumber() {
        var body = Self.lines(55)
        body += HARD
        let doc = Self.doc(body)
        #expect(doc.eofBlankLines == 1)
        let pages = Self.pages(doc)
        #expect(pages.map(\.count) == [55, 0])
        #expect(pages[1].explicitBreak)
        #expect(pages[1].autoPageno?.text == "2")
    }

    @Test func aBlankLineThatFitsMakesNoPage() {
        var body = Self.lines(54)
        body += HARD
        #expect(Self.pages(Self.doc(body)).map(\.count) == [54])
    }

    @Test func aBlankLineAfterATrailingPaMakesAPage() {
        var body = Self.lines(10)
        body += bytes(".pa")
        body += HARD
        body += HARD
        let pages = Self.pages(Self.doc(body))
        #expect(pages.count == 2)
        #expect(pages[1].isEmpty)
        #expect(pages[1].autoPageno?.text == "2")
    }

    @Test func aTrailingPaAloneMakesNoPage() {
        var body = Self.lines(10)
        body += bytes(".pa")
        body += HARD
        #expect(Self.pages(Self.doc(body)).count == 1)
    }

    @Test func modernStillDropsTheEmptyTrailingPage() {
        var body = Self.lines(PDFMetrics.linesModern)
        body += HARD
        let pages = docToPagelines(Self.doc(body), printed: false)
        #expect(pages.map(\.count) == [PDFMetrics.linesModern])
    }

    @Test func theOldEraKeepsDroppingTheTrailingBlankRun() {
        var body = Self.lines(55)
        body += HARD
        let doc = Self.doc(body, variant: .ws4)
        #expect(doc.detection?.variant == .ws4)
        #expect(Self.pages(doc).map(\.count) == [55])
    }

    // ------------------------------------------------------------------ .pa
    @Test func aPaAsTheFirstLineAddsNoEmptyPage() {
        var body = bytes(".pa")
        body += HARD
        body += Self.lines(3)
        let pages = Self.pages(Self.doc(body))
        #expect(pages.count == 1)
        #expect(Self.texts(pages[0]).first == "line 01")
    }

    @Test func aPaRightAfterAPaAddsNoEmptyPage() {
        var body = bytes("One.")
        body += HARD
        body += bytes(".pa")
        body += HARD
        body += bytes(".pa")
        body += HARD
        body += bytes("Two.")
        body += HARD
        #expect(Self.pages(Self.doc(body)).map(Self.texts) == [["One."], ["Two."]])
    }

    @Test func aPaAfterAFormFeedAddsNoEmptyPage() {
        var body = bytes("One.")
        body += [0x0C]
        body += HARD
        body += bytes(".pa")
        body += HARD
        body += bytes("Two.")
        body += HARD
        #expect(Self.pages(Self.doc(body)).map(Self.texts) == [["One."], ["Two."]])
    }

    @Test func aPaAfterAFullPageStillBreaksOnce() {
        var body = Self.lines(55)
        body += bytes(".pa")
        body += HARD
        body += bytes("after")
        body += HARD
        #expect(Self.pages(Self.doc(body)).map(\.count) == [55, 1])
    }

    // ------------------------------------------------------------------ soft blanks
    @Test func emptySoftReturnLinesAreSwallowedAtARoomBreak() {
        var body = Self.lines(55)
        body += SOFT
        body += SOFT
        body += SOFT
        body += bytes("x")
        body += HARD
        #expect(Self.texts(Self.pages(Self.doc(body))[1]) == ["x"])
    }

    @Test func emptyHardReturnLinesCarryOverToTheTopOfTheNextPage() {
        var body = Self.lines(55)
        body += HARD
        body += HARD
        body += HARD
        body += bytes("x")
        body += HARD
        #expect(Self.texts(Self.pages(Self.doc(body))[1]) == ["", "", "", "x"])
    }

    @Test func softBlanksAfterAPaAreNotSwallowed() {
        var body = Self.lines(3)
        body += bytes(".pa")
        body += HARD
        body += SOFT
        body += SOFT
        body += bytes("x")
        body += HARD
        #expect(Self.texts(Self.pages(Self.doc(body))[1]) == ["", "", "x"])
    }

    // ------------------------------------------------------------------ form feed
    @Test func aPageEndedByABareFormFeedPrintsNoNumber() {
        var body = Self.lines(5)
        body += [0x0C]
        body += Self.lines(5, first: 6)
        let pages = Self.pages(Self.doc(body))
        #expect(pages.count == 2)
        #expect(pages[0].endedByFormFeed)
        #expect(pages[0].autoPageno == nil)
        #expect(!pages[1].endedByFormFeed)
        #expect(pages[1].autoPageno?.text == "2")
    }

    @Test func aFormFeedPagePrintsNoFooterEither() {
        var body = bytes(".fo Foot #")
        body += HARD
        body += Self.lines(5)
        body += [0x0C]
        body += Self.lines(5, first: 6)
        let pages = Self.pages(Self.doc(body))
        #expect(pages[0].footerLines == nil)
        #expect(pages[1].footerLines?.map(\.text) == ["Foot 2"])
    }

    @Test func aPaPageStillPrintsItsNumber() {
        var body = Self.lines(5)
        body += bytes(".pa")
        body += HARD
        body += Self.lines(5, first: 6)
        #expect(Self.pages(Self.doc(body))[0].autoPageno?.text == "1")
    }

    // ------------------------------------------------------------------ .lh a
    static func autoDoc(_ body: [UInt8]) -> Document {
        Self.doc(body, dots: bytes(".lh a") + HARD)
    }

    static func leads(_ doc: Document) -> [Double?] {
        Self.pages(doc)[0].map(\.lead)
    }

    @Test func aLineIsLedByTheFontItStartsInAndNothingCarriesFurther() {
        // lead3: line 3 is Times 24, closed before its return; line 4 is Courier again.
        let times = Self.face("tms"), courier = Self.face("courier")
        var body = bytes("line 01")
        body += HARD
        body += bytes("line 02")
        body += HARD
        body += fontBlock(times, points: 24, styleBits: 0x8000)
        body += bytes("line 03")
        body += fontBlock(courier, points: 12)
        body += HARD
        body += bytes("line 04")
        body += HARD
        body += bytes("line 05")
        body += HARD
        #expect(Self.leads(Self.autoDoc(body)).prefix(5).map { $0 ?? -1 }
                == [12.0, 12.0, 24.0, 12.0, 12.0])
    }

    @Test func aFontThatRunsIntoTheNextLineLeadsItToo() {
        // lead5: the 24-pt font runs from mid line 3 into line 4.
        let times = Self.face("tms"), courier = Self.face("courier")
        var body = bytes("line 01")
        body += HARD
        body += bytes("line 02")
        body += HARD
        body += bytes("line 03 ")
        body += fontBlock(times, points: 24, styleBits: 0x8000)
        body += bytes("BIG")
        body += HARD
        body += bytes("line 04 big")
        body += fontBlock(courier, points: 12)
        body += bytes(" small")
        body += HARD
        body += bytes("line 05")
        body += HARD
        #expect(Self.leads(Self.autoDoc(body)).prefix(5).map { $0 ?? -1 }
                == [12.0, 12.0, 24.0, 24.0, 12.0])
    }

    @Test func aBlankLineTakesTheFontTheLineAboveEndedIn() {
        let times = Self.face("tms")
        var body = bytes("line 01")
        body += HARD
        body += fontBlock(times, points: 24, styleBits: 0x8000)
        body += bytes("BIG")
        body += HARD
        body += HARD
        body += bytes("tail")
        body += HARD
        #expect(Self.leads(Self.autoDoc(body)).prefix(4).map { $0 ?? -1 }
                == [12.0, 24.0, 24.0, 24.0])
    }

    @Test func theFontInForceAtTheEndOfALineCountsATrailingRecord() {
        let times = Self.face("tms"), courier = Self.face("courier")
        var body = bytes("line 01")
        body += HARD
        body += fontBlock(times, points: 24, styleBits: 0x8000)
        body += bytes("big")
        body += fontBlock(courier, points: 12)
        body += HARD
        body += bytes("small")
        body += HARD
        let doc = Self.autoDoc(body)
        let textLines = doc.blocks[0].lines.filter { !$0.spans.isEmpty }
        #expect(textLines.count >= 3)
        #expect(doc.fonts[textLines[1].fontOut!].points == 12.0)
        #expect(doc.fonts[textLines[2].fontOut!].points == 12.0)
    }

    static func tallPageEnds(_ points: Double) -> [String] {
        let times = Self.face("tms"), courier = Self.face("courier")
        var body = Self.lines(54)
        body += fontBlock(times, points: points, styleBits: 0x8000)
        body += bytes("line 55")
        body += fontBlock(courier, points: 12)
        body += HARD
        body += bytes("line 56")
        body += HARD
        return Self.pages(Self.autoDoc(body)).map { Self.texts($0).last ?? "" }
    }

    @Test func aLineWhoseRiseFitsTheRoomLeftStaysAndOverhangs() {
        // tall24: line 55 starts in a font that raises it by exactly the room left.
        #expect(Self.tallPageEnds(24) == ["line 55", "line 56"])
    }

    @Test func aLineWhoseRiseExceedsTheRoomMovesToTheNextPage() {
        // tall36: the rise is more than the room left.
        #expect(Self.tallPageEnds(36) == ["line 54", "line 56"])
    }

    // ------------------------------------------------------------------ .cw
    @Test func theAutomaticNumberDoesNotMoveWithCw() {
        let plain = Self.pages(Self.doc(Self.lines(3)))[0].autoPageno
        let wide = Self.pages(Self.doc(Self.lines(3), dots: bytes(".cw 20") + HARD))[0].autoPageno
        #expect(plain != nil)
        #expect(plain?.y == wide?.y)
    }

    /// Under WS4's HPLJET the number sits its vbias below the foot row, whatever `.cw` is.
    /// Port of `test_ws4s_hpljet_puts_the_number_its_vbias_below_the_foot_row`. ctrl-kd's
    /// `test_the_old_era_number_row_still_follows_the_type_size` now asks WS3, which has
    /// no `Variant` here (`ws3Era` is kept out of `eras`), so it has no twin.
    @Test func ws4sHpljetPutsTheNumberItsVbiasBelowTheFootRow() throws {
        // V = ((PL - MB + FM)·8 + 16)·15 decipoints, whatever .cw is (WS4 teardown 4 15.2:
        // 7440 at PL 66 / MB 8 / FM 2)
        let plain = Self.pages(Self.doc(Self.lines(3), variant: .ws4))[0].autoPageno
        let wide = Self.pages(Self.doc(Self.lines(3), dots: bytes(".cw 20") + HARD,
                                       variant: .ws4))[0].autoPageno
        let plainY = try #require(plain?.y)
        #expect(plainY == wide?.y)
        #expect(abs(plainY - (792 - 744.0)) < 1e-9)
    }
}
