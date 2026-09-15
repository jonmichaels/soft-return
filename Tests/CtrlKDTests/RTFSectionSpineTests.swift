/// planning #264 R1 (Jon, 2026-09-14): "Yes" — RTF sections: newspaper columns (A7),
/// hard column break `.cb` (A9), head/foot redefined mid-document (A13), one piece of
/// work, both engines.
///
/// THE SHAPE OF THE ANSWER is packet section 3's own recommendation, and R6 settled the
/// alternative the same morning: "Let's skip page breaks" — no imposed page positions. So
/// a section opens where the DOCUMENT'S OWN GEOMETRY changes and nowhere else, and an RTF
/// reader still paginates inside every section exactly as it did before.
///
///   A7  `.co n, gutter` becomes `\sect\sectd\cols n\colsx <gutter>`.
///   A9  `.cb` becomes `\column` — a break to the next column INSIDE a section, never a
///       section of its own.
///   A13 a running head or foot redefined mid-document opens a section carrying its own
///       `\header`/`\footer` groups. A slot defined ONCE, however late, is not a
///       redefinition: that is the ordinary case section 1 already carried, with
///       `\titlepg` when it starts after page 1.
///
/// PRINTED ONLY for columns, and the reason is a standing ruling rather than a
/// limitation: Modern PDF has no column model at all, and 2026-08-05 ruled "Modern PDF
/// needs to be the printed version of the Modern RTF" — a columnar Modern RTF would be a
/// Modern RTF its own PDF could not render. Modern's own flow drops `.cb` outright, so
/// `\column` is Printed-only for the same reason. A13 reaches BOTH modes: Modern keeps
/// running heads (ruling M5, 2026-08-06).
///
/// Port of ctrl-kd's `tests/test_rtf_section_spine.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private func spineDocument(_ body: String, dots: String = "") -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var bytes: [UInt8] = [0x1D]
    bytes += le
    bytes += [0x00, 0x70]
    bytes += [UInt8](repeating: 0, count: 15)
    bytes += le
    bytes += [0x1D]
    bytes += [UInt8](dots.utf8)
    bytes += [UInt8](body.utf8)
    return parseWS(bytes)
}

/// Every `\sect\sectd ...` opener in the file, verbatim.
private func sectionOpeners(_ rtf: String) -> [String] {
    var out: [String] = []
    var rest = Substring(rtf)
    while let start = rest.range(of: #"\sect\sectd"#) {
        var end = start.lowerBound
        while end < rest.endIndex, !rest[end].isWhitespace { end = rest.index(after: end) }
        out.append(String(rest[start.lowerBound..<end]))
        rest = rest[end...]
    }
    return out
}

/// Each opener with its head/foot GAP stripped — `\headery`/`\footery` are section
/// properties `\sectd` resets, so every section that draws anything in a margin restates
/// them; what these rows are about is the column regime.
private func sectionColumns(_ rtf: String) -> [String] {
    sectionOpeners(rtf).map { opener in
        guard let gap = opener.range(of: #"\headery"#) else { return opener }
        var end = gap.upperBound
        var seenFootery = false
        while end < opener.endIndex {
            if opener[end...].hasPrefix(#"\footery"# ) { seenFootery = true }
            if seenFootery, opener[end...].hasPrefix(#"\cols"#) { break }
            end = opener.index(after: end)
        }
        return String(opener[opener.startIndex..<gap.lowerBound])
            + String(opener[end...])
    }
}

// MARK: - A7 newspaper columns

@Test func aColumnarRegionOpensASectionWithItsOwnColumnCount() {
    let rtf = emitRTF(spineDocument("Opening paragraph.\r\n.co 3, 5\r\nColumnar text.\r\n"),
                      mode: .printed)
    #expect(sectionColumns(rtf) == [#"\sect\sectd\cols3\colsx720"#])
}

@Test func theGutterIsPrintColumnsAtTenCPI() {
    // `.co n, g`'s gutter is the same unit `.po` uses — 144 twips a column — so `5` is
    // half an inch and `10` is a full one.
    for (gutter, twips) in [(5, 720), (10, 1440), (2, 288)] {
        let rtf = emitRTF(spineDocument("Opening.\r\n.co 2, \(gutter)\r\nText.\r\n"),
                          mode: .printed)
        #expect(rtf.contains(#"\cols2\colsx\#(twips)"#))
    }
}

@Test func aDocumentThatOpensInColumnsCarriesThemInThePageSetup() {
    // `\cols` is a section property and the page setup IS section 1's, so a document
    // whose very first block is columnar needs no `\sect` at all — the corpus's
    // REVIEW.DOC and BOOKLET.WS are this shape.
    let rtf = emitRTF(spineDocument("Columnar from the start.\r\n", dots: ".co 2, 10\r\n"),
                      mode: .printed)
    let head = rtf.components(separatedBy: #"\sect"#)[0]
    #expect(head.contains(#"\cols2\colsx1440"#))
    #expect(sectionOpeners(rtf).isEmpty)
}

@Test func columnsOffClosesTheSectionAndOpensAPlainOne() {
    let rtf = emitRTF(spineDocument(
        "One.\r\n.co 2, 5\r\nTwo.\r\n.co 1\r\nThree.\r\n"), mode: .printed)
    #expect(sectionColumns(rtf) == [#"\sect\sectd\cols2\colsx720"#, #"\sect\sectd"#])
}

@Test func turningColumnsOffAndOnAgainWithANewGutterIsTwoSections() {
    // `.co1`'s own gutter argument is noise — columns are off — so it normalises away and
    // only the real regime changes count.
    let rtf = emitRTF(spineDocument(
        "One.\r\n.co 2, 5\r\nTwo.\r\n.co 1, 9\r\nThree.\r\n.co 1, 3\r\nFour.\r\n"),
        mode: .printed)
    #expect(sectionColumns(rtf) == [#"\sect\sectd\cols2\colsx720"#, #"\sect\sectd"#])
}

@Test func modernRTFStaysOneColumn() {
    // Not an omission: Modern PDF has no column model, and Modern PDF is ruled to be the
    // printed form of the Modern RTF.
    let rtf = emitRTF(spineDocument("One.\r\n.co 3, 5\r\nTwo.\r\n"), mode: .modern)
    #expect(!rtf.contains(#"\cols"#))
    #expect(sectionOpeners(rtf).isEmpty)
}

@Test(arguments: [EmitMode.printed, .modern])
func aDocumentWithNoCoAtAllOpensNoSection(mode: EmitMode) {
    let rtf = emitRTF(spineDocument("Just prose.\r\nMore prose.\r\n"), mode: mode)
    #expect(!rtf.contains(#"\sect"#))
    #expect(!rtf.contains(#"\cols"#))
}

// MARK: - A9 `.cb`

@Test func cbBecomesAColumnBreakInsideAColumnarRegion() {
    let rtf = emitRTF(spineDocument(
        ".co 2, 5\r\nFirst column.\r\n.cb\r\nSecond column.\r\n"), mode: .printed)
    #expect(rtf.contains(#"\column "#))
    let first = rtf.range(of: "First column.")!
    let col = rtf.range(of: #"\column "#)!
    let second = rtf.range(of: "Second column.")!
    #expect(first.upperBound < col.lowerBound)
    #expect(col.upperBound < second.lowerBound)
}

@Test func cbOutsideAColumnarRegionWritesNothing() {
    // WordStar never put one there, and in a single-column section the control would mean
    // "page break" to a reader — which `.cb` is not.
    let rtf = emitRTF(spineDocument("One.\r\n.cb\r\nTwo.\r\n"), mode: .printed)
    #expect(!rtf.contains(#"\column"#))
}

@Test func cbWritesNothingInModern() {
    let rtf = emitRTF(spineDocument(".co 2, 5\r\nOne.\r\n.cb\r\nTwo.\r\n"), mode: .modern)
    #expect(!rtf.contains(#"\column"#))
}

@Test func aPAInsideAColumnarRegionIsAbsorbed() {
    // The identical reading the Printed PDF has carried since planning #227 —
    // WINGDING.CHT's author used `.pa` as a manual column simulation and honouring them
    // fragments one real column into two short pages.
    let rtf = emitRTF(spineDocument(".co 2, 5\r\nOne.\r\n.pa\r\nTwo.\r\n"), mode: .printed)
    #expect(!rtf.contains(#"\page"#))
}

@Test func aPAOutsideAColumnarRegionIsStillAPageBreak() {
    let rtf = emitRTF(spineDocument("One.\r\n.pa\r\nTwo.\r\n"), mode: .printed)
    #expect(rtf.contains(#"\page "#))
}

// MARK: - A13 a head that changes

private func headTexts(_ rtf: String) -> [String] {
    var out: [String] = []
    var rest = Substring(rtf)
    while let open = rest.range(of: #"{\header \pard\plain "#) {
        rest = rest[open.upperBound...]
        guard let brace = rest.firstIndex(of: "{") else { break }
        rest = rest[rest.index(after: brace)...]
        guard let close = rest.firstIndex(of: "}") else { break }
        out.append(String(rest[rest.startIndex..<close]))
        rest = rest[close...]
    }
    return out
}

@Test(arguments: [EmitMode.printed, .modern])
func aHeadRedefinedMidDocumentOpensASectionWithItsOwnHead(mode: EmitMode) {
    let rtf = emitRTF(spineDocument(
        ".he First Head\r\nChapter one.\r\n.pa\r\n.he Second Head\r\nChapter two.\r\n"),
        mode: mode)
    #expect(sectionOpeners(rtf).count == 1)
    #expect(headTexts(rtf) == ["First Head", "Second Head"])
}

@Test(arguments: [EmitMode.printed, .modern])
func aHeadDefinedOnceHoweverLateOpensNoSection(mode: EmitMode) {
    // The ordinary "this document has a running head" case — section 1 carries it, with
    // `\titlepg` for the page before it.
    let rtf = emitRTF(spineDocument(
        "Title page.\r\n.pa\r\n.he The Only Head\r\nBody.\r\n"), mode: mode)
    #expect(sectionOpeners(rtf).isEmpty)
    #expect(headTexts(rtf) == ["The Only Head"])
    #expect(rtf.contains(#"\titlepg"#))
}

@Test(arguments: [EmitMode.printed, .modern])
func aHeadRedefinedToTheSameTextIsNotARedefinition(mode: EmitMode) {
    let rtf = emitRTF(spineDocument(".he Same\r\nOne.\r\n.pa\r\n.he Same\r\nTwo.\r\n"),
                      mode: mode)
    #expect(sectionOpeners(rtf).isEmpty)
}

@Test(arguments: [EmitMode.printed, .modern])
func aFooterRedefinedMidDocumentOpensASectionToo(mode: EmitMode) {
    let rtf = emitRTF(spineDocument(
        ".fo First Foot\r\nOne.\r\n.pa\r\n.fo Second Foot\r\nTwo.\r\n"), mode: mode)
    #expect(sectionOpeners(rtf).count == 1)
    #expect(rtf.contains("First Foot"))
    #expect(rtf.contains("Second Foot"))
}

@Test(arguments: [EmitMode.printed, .modern])
func aLaterSectionRestatesTheHeadGapSectdReset(mode: EmitMode) {
    // `\sectd` resets every section property, `\headery`/`\footery` among them, so a
    // section that draws a head has to say where it sits.
    let rtf = emitRTF(spineDocument(".he One\r\nA.\r\n.pa\r\n.he Two\r\nB.\r\n"),
                      mode: mode)
    let opener = sectionOpeners(rtf)[0]
    let head = rtf.components(separatedBy: #"\sect"#)[0]
    #expect(opener.contains(#"\headery"#) == head.contains(#"\headery"#))
}

@Test func headersOffGivesALaterSectionNoHeadEither() {
    var options = EmitOptions()
    options.headers = false
    let rtf = emitRTF(spineDocument(".he One\r\nA.\r\n.pa\r\n.he Two\r\nB.\r\n"),
                      mode: .printed, options: options)
    #expect(headTexts(rtf).isEmpty)
    #expect(!rtf.contains("One"))
    #expect(!rtf.contains("Two"))
}

// MARK: - the two together

@Test func aColumnsChangeAndAHeadChangeAtOneBlockOpenOneSection() {
    let rtf = emitRTF(spineDocument(
        "One.\r\n.co 2, 5\r\n.he A Head\r\nTwo.\r\n.pa\r\n.he B Head\r\nThree.\r\n"),
        mode: .printed)
    let openers = sectionOpeners(rtf)
    #expect(openers.count == 2)
    #expect(openers[0].hasSuffix(#"\cols2\colsx720"#))
}

@Test func everySectionOpenerIsWellFormed() {
    // `\sect` ends the previous section and `\sectd` resets the next one's properties;
    // the pair is never written apart.
    let rtf = emitRTF(spineDocument("One.\r\n.co 2, 5\r\nTwo.\r\n.co 1\r\nThree.\r\n"),
                      mode: .printed)
    let sects = rtf.components(separatedBy: #"\sect"#).count - 1
    let pairs = rtf.components(separatedBy: #"\sect\sectd"#).count - 1
    #expect(sects == pairs * 2)
}
