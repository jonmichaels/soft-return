/// Jon's ruling 2026-09-15 ("Yes. Fix it."): the Modern PDF keeps the document's own
/// SHEET ORIENTATION (`.pr or=l`, or a `.pl` shorter than the sheet is wide) and its own
/// COLUMN COUNT (`.co n`).
///
/// Two standing rulings converge on it. 2026-08-05: "Modern PDF needs to be the printed
/// version of the Modern RTF" — a landscape, two-column document rendered portrait and
/// one-column is not a printing of anything the document says. 2026-08-17, the
/// paged-surface doctrine, point 2: "honor `.pr or=l` landscape in ALL paged surfaces" —
/// Modern PDF was the one paged surface it had never reached.
///
/// WHAT MODERN KEEPS OF ITS OWN (the governing-defaults principle, 2026-08-05: the
/// document's explicit choices win, and where it is silent Modern gap-fills with our
/// take): the typography. Modern fonts, 1.2 line height, Modern's own margins scaled to
/// the sheet, its own running heads (M5) and its own end-matter (M1). What it takes from
/// the document is the SHEET and the COLUMN GRID — the two things the document states
/// outright.
///
/// A column's own measure is Modern's text width divided n ways with the document's
/// gutter, which is what `\cols n\colsx g` says to an RTF reader and therefore what
/// Modern PDF, as that RTF's printed form, must do. Printed reads the same measure off
/// `.rm` instead, because an author who wants n real columns sets `.rm` to one column's
/// width first — the same number stated in WordStar's own units. BOOKLET.WS proves they
/// agree: `.po .2i` + `.rm 4.50"` + a 1.00" gutter fills an 11in landscape sheet almost
/// exactly as the division does.
///
/// NO BALANCING, because WordStar does not balance (planning #227 §5, measured on
/// WINGDING.CHT's own short last column): a trailing group of fewer than n columns is
/// simply left short.
///
/// Port of ctrl-kd's `tests/test_modern_columns.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private func columnsDocument(_ body: String, dots: String = "") -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var data: [UInt8] = [0x1D]
    data += le
    data += [0x00, 0x70]
    data += [UInt8](repeating: 0, count: 15)
    data += le
    data += [0x1D]
    data += [UInt8](dots.utf8)
    data += [UInt8](body.utf8)
    return parseWS(data)
}

private let CR = "\r\n"

private let paragraphLine =
    "The quick brown fox jumps over the lazy dog and keeps running "
    + "until the line has to wrap somewhere sensible." + CR

private func repeatedBody(_ n: Int) -> String {
    var out = ""
    for _ in 0..<n { out += paragraphLine }
    return out
}

private func mediaBox(_ pdf: [UInt8]) -> (width: Int, height: Int)? {
    let text = String(decoding: pdf, as: UTF8.self)
    guard let range = text.range(of: "/MediaBox [0 0 ") else { return nil }
    let rest = text[range.upperBound...]
    guard let close = rest.firstIndex(of: "]") else { return nil }
    let parts = rest[..<close].split(separator: " ")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    return (w, h)
}

/// Each page's content stream, in page order.
private func pageStreams(_ pdf: [UInt8]) -> [String] {
    let text = String(decoding: pdf, as: UTF8.self)
    var out: [String] = []
    var rest = Substring(text)
    while let open = rest.range(of: ">>\nstream\n") {
        let body = rest[open.upperBound...]
        guard let close = body.range(of: "\nendstream") else { break }
        out.append(String(body[..<close.lowerBound]))
        rest = body[close.upperBound...]
    }
    return out
}

/// M15 (2026-09-15): Modern draws its running feet — and WordStar's own automatic page
/// number — in the bottom margin zone, at y <= 44. These tests are about the COLUMN grid,
/// so the zone is skipped rather than each assertion being taught to expect one more
/// (centred) x; Modern's body never reaches it.
private let modernFootZone = 44.0

/// `(x, word)` for every drawn text run on one page, in draw order.
private func drawnRuns(_ stream: String) -> [(x: Double, word: String)] {
    var out: [(Double, String)] = []
    for line in stream.split(separator: "\n") {
        guard let tsRange = line.range(of: "Ts ") else { continue }
        let after = line[tsRange.upperBound...]
        guard let tdRange = after.range(of: " Td (") else { continue }
        let coords = after[..<tdRange.lowerBound].split(separator: " ")
        guard coords.count == 2, let x = Double(coords[0]),
              let y = Double(coords[1]), y > modernFootZone else { continue }
        let tail = after[tdRange.upperBound...]
        guard let end = tail.range(of: ") Tj") else { continue }
        out.append((x, String(tail[..<end.lowerBound])))
    }
    return out
}

private func drawnXs(_ stream: String) -> [Double] { drawnRuns(stream).map(\.x) }

private func drawnWords(_ stream: String) -> [String] { drawnRuns(stream).map(\.word) }

// MARK: - the sheet's orientation

@Test func aLandscapeDocumentGetsALandscapeModernSheet() throws {
    let doc = columnsDocument("Body text." + CR, dots: ".pr or=l" + CR)
    #expect(doc.formatting.orientation == .landscape)
    let box = mediaBox(emitPDF(doc, mode: .modern))
    #expect(box?.width == 792)
    #expect(box?.height == 612)
}

@Test func aLandscapePlThatIsNoPortraitHeightStillResolvesTheSheet() throws {
    // Every real landscape template in the archive declares a `.pl` that matches
    // Letter's WIDTH, not its height (`.pl 8.5"`): resolved on the portrait column it
    // used to come back a square.
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    var body = "Body text."
    body += CR
    let doc = columnsDocument(body, dots: dots)
    let box = mediaBox(emitPDF(doc, mode: .modern))
    #expect(box?.width == 792)
    #expect(box?.height == 612)
}

@Test func theBodyIsLaidOutOnTheLandscapeSheetNotAboveIt() throws {
    // The swap alone is not the fix: Modern used to start its `y` cursor at Letter's
    // own 792pt whatever sheet it was drawing on, which puts every line of a 612pt-tall
    // landscape page above the top of the page.
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    let doc = columnsDocument(paragraphLine, dots: dots)
    let pdf = emitPDF(doc, mode: .modern)
    let height = try #require(mediaBox(pdf)?.height)
    let text = String(decoding: pdf, as: UTF8.self)
    var ys: [Double] = []
    for line in text.split(separator: "\n") {
        guard let tsRange = line.range(of: "Ts ") else { continue }
        let after = line[tsRange.upperBound...]
        guard let tdRange = after.range(of: " Td (") else { continue }
        let coords = after[..<tdRange.lowerBound].split(separator: " ")
        if coords.count == 2, let y = Double(coords[1]) { ys.append(y) }
    }
    #expect(!ys.isEmpty)
    #expect((ys.max() ?? .infinity) < Double(height))
}

@Test func aPortraitDocumentKeepsThePortraitModernSheet() throws {
    let doc = columnsDocument("Body text." + CR, dots: ".pr or=p" + CR)
    let box = mediaBox(emitPDF(doc, mode: .modern))
    #expect(box?.width == 612)
    #expect(box?.height == 792)
}

@Test func aDocumentThatNeverDeclaresAnOrientationIsUntouched() throws {
    let doc = columnsDocument("Body text." + CR)
    let box = mediaBox(emitPDF(doc, mode: .modern))
    #expect(box?.width == 612)
    #expect(box?.height == 792)
}

// MARK: - the column grid

private func columnarDocument(cols: Int = 2, gutter: String = " 10",
                              landscape: Bool = true, body: String? = nil) -> Document {
    var dots = ""
    if landscape {
        dots += ".pr or=l" + CR
        dots += ".pl 8.50\"" + CR
    }
    dots += ".co \(cols),\(gutter)" + CR
    return columnsDocument(body ?? repeatedBody(12), dots: dots)
}

@Test func aTwoColumnLandscapeDocumentDrawsBothColumnsOnPageOne() throws {
    let pdf = emitPDF(columnarDocument(), mode: .modern)
    #expect(mediaBox(pdf)?.width == 792)
    let xs = drawnXs(try #require(pageStreams(pdf).first))
    #expect(!xs.isEmpty)
    // two distinct left edges, and the second starts past the middle of the sheet --
    // a real second column, not an indent
    #expect((xs.min() ?? 0) < 396)
    #expect((xs.max() ?? 0) > 396)
}

@Test func theSecondColumnStartsOneColumnPlusTheGutterOver() throws {
    // `.co 2, 10`: the gutter is print columns at 10 CPI, so 10 is a full inch -- the
    // identical reading `rtfColsControl` gives `\colsx`.
    let doc = columnarDocument(cols: 2, gutter: " 10")
    let pdf = emitPDF(doc, mode: .modern)
    let (margl, _, _, width) = modernGeometry(doc)
    let (colW, gap) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    #expect((gap * 10).rounded() / 10 == 72.0)              // 10 cols at 10 CPI
    let xs = drawnXs(try #require(pageStreams(pdf).first))
    let left = try #require(xs.min())
    let second = try #require(xs.filter { $0 > margl + colW }.min())
    #expect(((second - left) * 10).rounded() == ((colW + gap) * 10).rounded())
}

@Test func aLineWrapsAtTheColumnNotAtThePage() throws {
    // The whole point of the grid: the measure every line is broken at is one column's,
    // not the sheet's.
    let doc = columnarDocument()
    let pdf = emitPDF(doc, mode: .modern)
    let (margl, _, _, width) = modernGeometry(doc)
    let (colW, _) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    let col0 = drawnXs(try #require(pageStreams(pdf).first)).filter { $0 < margl + colW }
    #expect(!col0.isEmpty)
    let col0Right = (col0.max() ?? .infinity) - margl
    #expect(col0Right <= colW)
}

@Test func columnsFillDownThenAcross() throws {
    // Fill order is down column 1, then column 2 -- research §4, confirmed against
    // WINGDING.CHT/SYMBOL.CHT/PRINT.TST's own real WS7 captures.
    var body = ""
    for i in 1...120 { body += String(format: "Line %03d here.", i) + CR }
    let doc = columnarDocument(body: body)
    let pdf = emitPDF(doc, mode: .modern)
    let (margl, _, _, width) = modernGeometry(doc)
    let (colW, _) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    let runs = drawnRuns(try #require(pageStreams(pdf).first))
    let col0 = runs.filter { $0.x < margl + colW && Int($0.word) != nil }.map(\.word)
    let col1 = runs.filter { $0.x >= margl + colW && Int($0.word) != nil }.map(\.word)
    #expect(!col0.isEmpty)
    #expect(!col1.isEmpty)
    #expect(Int(col0.first ?? "") == 1)
    let firstOfCol1 = Int(col1.first ?? "") ?? 0
    let lastOfCol0 = Int(col0.last ?? "") ?? 0
    #expect(firstOfCol1 > lastOfCol0)
}

@Test func aOneColumnDocumentPlacesEveryLineWithinTheFullMeasure() throws {
    // The control: `.co 1` (or no `.co` at all) is the arithmetic that was there before
    // this ruling.
    for dots in ["", ".co 1" + CR] {
        let doc = columnsDocument(repeatedBody(6), dots: dots)
        let xs = drawnXs(try #require(pageStreams(emitPDF(doc, mode: .modern)).first))
        #expect(!xs.isEmpty)
        #expect((xs.max() ?? .infinity) < 612)
    }
}

@Test func turningColumnsOffStartsAFreshSheet() throws {
    // A change of column regime starts its own sheet, the same rule `docToPagelines`'
    // own block loop follows in Printed.
    var body = "Columnar text."
    body += CR
    body += ".co 1"
    body += CR
    body += "Back to one column."
    body += CR
    var dots = ".co 2, 10"
    dots += CR
    let doc = columnsDocument(body, dots: dots)
    let streams = pageStreams(emitPDF(doc, mode: .modern))
    #expect(streams.count == 2)
    #expect(drawnWords(streams[0]).contains("Columnar"))
    #expect(drawnWords(streams[1]).contains("Back"))
}

@Test func aPaInsideAColumnarRegionIsAbsorbed() throws {
    // The identical reading Printed has carried since planning #227, measured against
    // WINGDING.CHT's own WS7 capture: the author's `.pa` markers are a manual column
    // simulation that predates the real `.co` governing the same content.
    var body = "First."
    body += CR
    body += ".pa"
    body += CR
    body += "Second."
    body += CR
    var dots = ".co 2, 10"
    dots += CR
    let doc = columnsDocument(body, dots: dots)
    let streams = pageStreams(emitPDF(doc, mode: .modern))
    #expect(streams.count == 1)
    let words = Set(drawnWords(try #require(streams.first)))
    #expect(words.contains("First."))
    #expect(words.contains("Second."))
}

@Test func aPaOutsideAColumnarRegionIsStillAPageBreak() throws {
    var body = "First."
    body += CR
    body += ".pa"
    body += CR
    body += "Second."
    body += CR
    let doc = columnsDocument(body)
    #expect(pageStreams(emitPDF(doc, mode: .modern)).count == 2)
}

@Test func cbBreaksToTheNextColumnInsideAColumnarRegion() throws {
    var body = "First."
    body += CR
    body += ".cb"
    body += CR
    body += "Second."
    body += CR
    var dots = ".co 2, 10"
    dots += CR
    let doc = columnsDocument(body, dots: dots)
    let streams = pageStreams(emitPDF(doc, mode: .modern))
    #expect(streams.count == 1)
    let runs = drawnRuns(try #require(streams.first))
    let firstX = try #require(runs.first { $0.word == "First." }?.x)
    let secondX = try #require(runs.first { $0.word == "Second." }?.x)
    #expect(secondX > firstX)
}

@Test func cbOutsideAColumnarRegionDrawsNothingAndBreaksNothing() throws {
    // `.cb` with no live `.co` is a no-op -- the twin of Printed RTF writing no
    // `\column` for one.
    var body = "First."
    body += CR
    body += ".cb"
    body += CR
    body += "Second."
    body += CR
    let doc = columnsDocument(body)
    let streams = pageStreams(emitPDF(doc, mode: .modern))
    #expect(streams.count == 1)
    let words = Set(drawnWords(try #require(streams.first)))
    #expect(words.contains("First."))
    #expect(words.contains("Second."))
}

@Test func theLastColumnGroupIsNotBalanced() throws {
    // WordStar does not balance. A document with barely any text fills column 1 and
    // leaves column 2 empty rather than splitting it evenly.
    let doc = columnsDocument("Only one short line." + CR, dots: ".co 2, 10" + CR)
    let (margl, _, _, width) = modernGeometry(doc)
    let (colW, _) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    let streams = pageStreams(emitPDF(doc, mode: .modern))
    #expect(streams.count == 1)
    let xs = drawnXs(try #require(streams.first))
    #expect(!xs.isEmpty)
    let columnOneRight = margl + colW                       // nothing in column 2
    #expect((xs.max() ?? .infinity) < columnOneRight)
}

@Test func theColumnMeasureIsModernOwnWidthDividedNotTheRm() throws {
    // `.rm` inside a columnar region IS the column measure restated in WordStar's own
    // units; spending it on top of the division would narrow every column twice.
    var dots = ".co 2, 10"
    dots += CR
    dots += ".rm 4.50\""
    dots += CR
    let doc = columnsDocument(repeatedBody(8), dots: dots)
    let (_, _, _, width) = modernGeometry(doc)
    let (colW, gap) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    let xs = drawnXs(try #require(pageStreams(emitPDF(doc, mode: .modern)).first))
    let left = try #require(xs.min())
    let col0 = xs.filter { $0 < left + colW - 1 }
    // the widest line in column 1 reaches well past what a doubly-cut column would
    // allow (which would be colW minus the `.rm` shortfall)
    let col0Width = (col0.max() ?? 0) - left
    #expect(col0Width > colW / 2)
    #expect((gap * 10).rounded() / 10 == 72.0)
}

@Test func modernColumnWidthUsesAGutterDefaultOfOnePrintColumn() throws {
    // An author who names no gutter gets one print column, the same default
    // `rtfColsControl` writes into `\colsx`.
    let single = modernColumnWidth(500.0, cols: 1, gutter: nil)
    #expect(single.columnWidth == 500.0)
    #expect(single.gutterPt == 0.0)
    let pair = modernColumnWidth(500.0, cols: 2, gutter: nil)
    #expect((pair.gutterPt * 100).rounded() / 100 == 7.2)
    #expect((pair.columnWidth * 100).rounded() == (((500.0 - 7.2) / 2) * 100).rounded())
}

// MARK: - M17b: the Modern RTF says so too

// The 2026-08-05 ruling runs in both directions: Modern PDF is the printed form of the
// Modern RTF, so the RTF has to SAY the sheet and the column grid its PDF draws. Before
// M17b a landscape two-column document's Modern RTF was a square
// `\paperw12240\paperh12240` with no `\landscape` and no `\cols` — an RTF its own PDF
// could not print. Reuses planning #264 R1's section spine (`rtfColumnsState`,
// `rtfColsControl`, `rtfSectionBreaks`), which is also what keeps the two engines'
// readings of "which column regime is this block in" from ever drifting apart.

private func modernRTF(_ doc: Document) -> String {
    emitRTF(doc, mode: .modern)
}

@Test func theModernRTFCarriesTheLandscapeSheet() {
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    let rtf = modernRTF(columnsDocument("Body text." + CR, dots: dots))
    #expect(rtf.contains(#"\paperw15840"#))
    #expect(rtf.contains(#"\paperh12240"#))
    #expect(rtf.contains(#"\landscape"#))
}

@Test func theModernRTFSheetIsItsOwnPDFMediaBox() throws {
    // The 08-05 tie, asserted directly: what the RTF declares in twips and what its
    // printed form draws in points are the same sheet.
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    let doc = columnsDocument(paragraphLine, dots: dots)
    let (w, h) = try #require(mediaBox(emitPDF(doc, mode: .modern)))
    let rtf = modernRTF(doc)
    #expect(rtf.contains("\\paperw\(w * 20)"))
    #expect(rtf.contains("\\paperh\(h * 20)"))
}

@Test func aPortraitModernRTFSaysNothingAboutOrientation() {
    let rtf = modernRTF(columnsDocument("Body text." + CR, dots: ".pr or=p" + CR))
    #expect(!rtf.contains(#"\landscape"#))
    #expect(rtf.contains(#"\paperw12240"#))
}

/// `.pr or=l` + `.pl 8.50"` + `.co 2, 10` — the shape every real landscape,
/// two-column template in the archive declares, BOOKLET.WS included.
private func landscapeColumnarDots() -> String {
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    dots += ".co 2, 10"
    dots += CR
    return dots
}

@Test func theModernRTFCarriesTheColumnCountAndGutter() {
    let rtf = modernRTF(columnsDocument(repeatedBody(12), dots: landscapeColumnarDots()))
    #expect(rtf.contains(#"\cols2"#))
    #expect(rtf.contains(#"\colsx1440"#))        // 10 print columns x 144 twips
}

@Test func theModernRTFGutterIsThePDFGutter() {
    let doc = columnsDocument(repeatedBody(12), dots: landscapeColumnarDots())
    let (_, _, _, width) = modernGeometry(doc)
    let (_, gapPt) = modernColumnWidth(width, cols: 2, gutter: 10.0)
    #expect(modernRTF(doc).contains("\\colsx\(Int((gapPt * 20).rounded()))"))
}

@Test func aOneColumnModernRTFWritesNoCols() {
    #expect(!modernRTF(columnsDocument(paragraphLine)).contains(#"\cols"#))
}

@Test func aMidDocumentCoOpensAModernSection() {
    var body = "Opening."
    body += CR
    body += ".co 2, 10"
    body += CR
    body += paragraphLine
    let rtf = modernRTF(columnsDocument(body))
    #expect(rtf.contains(#"\sect\sectd"#))
    #expect(rtf.contains(#"\cols2"#))
}

/// "First.", one break control, "Second." — the smallest document that can show a
/// break landing (or not landing) between two known words.
private func brokenBody(_ control: String) -> String {
    var body = "First."
    body += CR
    body += control
    body += CR
    body += "Second."
    body += CR
    return body
}

@Test func cbIsAColumnBreakInTheModernRTF() {
    let doc = columnsDocument(brokenBody(".cb"), dots: ".co 2, 10" + CR)
    #expect(modernRTF(doc).contains(#"\column"#))
}

@Test func cbOutsideAColumnarRegionWritesNothingInTheModernRTF() {
    #expect(!modernRTF(columnsDocument(brokenBody(".cb"))).contains(#"\column"#))
}

@Test func aPAInsideAColumnarRegionIsAbsorbedInTheModernRTF() {
    // The same reading Modern PDF takes (planning #227, WINGDING.CHT's own WS7 capture):
    // those `.pa` markers are a manual column simulation, and honouring them fragments
    // one real column into two short pages.
    let doc = columnsDocument(brokenBody(".pa"), dots: ".co 2, 10" + CR)
    #expect(!modernRTF(doc).contains(#"\page "#))
    #expect(modernRTF(columnsDocument(brokenBody(".pa"))).contains(#"\page "#))
}
