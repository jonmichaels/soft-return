/// M18 (Jon's queue 2026-09-15): MODERN LAYS OUT ON THE SHEET IT DECLARES.
///
/// Modern's MediaBox has been the document's own declared sheet since 2026-08-06 ("the
/// page is the document's declared size -- Letter/Legal/A4"). Its composing ORIGIN was
/// Letter's 792pt regardless, so a document whose sheet is not 11in tall had its text
/// drawn at coordinates that are not on the page the PDF says it drew:
/// `sawyer/MAILLIST/ENVELOPE.LST` (`.pl 4.17"`) came out a 612x300 box with every line
/// at y >= 552 — six blank pages. The taller direction lost space instead of text: a
/// 13in Rolodex template began its first line 144pt below the top of its own sheet.
///
/// M17 fixed the LANDSCAPE half of the same arithmetic and named this half in
/// `modernSheetH`'s own docstring as "a real, separate defect ... it waits for its own".
/// This is it. One definition of Modern's sheet height now serves both the MediaBox and
/// the composing origin, so the two cannot disagree again.
///
/// `.pl 0` is not a sheet: it is WordStar's "page breaks off" (bug 12284), and the page
/// BOX falls back to Letter — verbatim what Printed has always done
/// (`resolvedPrintedPageHeight`), quoted rather than re-decided. Before this fix Modern
/// gave such a document a ZERO-HEIGHT MediaBox. (The document that carries it in the
/// archive, `sawyer/REF/-PATCHES.WS`, is separately an excluded `degenerate` document by
/// Jon's ruling 2026-09-10, planning #261 — excluded from JUDGING its fidelity, which is
/// not a licence to emit an invalid PDF for it.)
///
/// Port of ctrl-kd's `tests/test_modern_sheet_height.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private let CR = "\r\n"

private let sheetParagraph =
    "The quick brown fox jumps over the lazy dog and keeps running "
    + "until the line has to wrap somewhere sensible." + CR

private func sheetDocument(_ body: String, dots: String = "") -> Document {
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

/// A one-paragraph document declaring nothing but its own page length.
private func sheet(_ pl: String) -> Document {
    var dots = ".pl "
    dots += pl
    dots += CR
    return sheetDocument(sheetParagraph, dots: dots)
}

private func sheetMediaBox(_ pdf: [UInt8]) -> (width: Int, height: Int)? {
    let text = String(decoding: pdf, as: UTF8.self)
    guard let range = text.range(of: #"/MediaBox \[0 0 (\d+) (\d+)\]"#,
                                 options: .regularExpression) else { return nil }
    let parts = text[range].split(separator: " ")
    guard parts.count >= 5,
          let w = Int(parts[3]),
          let h = Int(parts[4].dropLast(1)) else { return nil }
    return (w, h)
}

/// Every drawn text y, in draw order.
private func drawnYs(_ pdf: [UInt8]) -> [Double] {
    let text = String(decoding: pdf, as: UTF8.self)
    var out: [Double] = []
    var search = text.startIndex..<text.endIndex
    while let range = text.range(of: #" [\d.]+ [\d.]+ Td"#, options: .regularExpression,
                                 range: search) {
        let parts = text[range].split(separator: " ")
        if parts.count >= 2, let y = Double(parts[1]) { out.append(y) }
        search = range.upperBound..<text.endIndex
    }
    return out
}

private func pageCount(_ pdf: [UInt8]) -> Int {
    String(decoding: pdf, as: UTF8.self).components(of: "/Type /Page ").count - 1
}

private extension String {
    func components(of needle: String) -> [String] { components(separatedBy: needle) }
}

// MARK: - the short sheet, the whole defect

@Test func aShortPortraitSheetIsLaidOutOnItself() throws {
    // ENVELOPE.LST's own `.pl 4.17"`: a 300pt sheet whose every line used to be drawn
    // at y >= 552, i.e. above the top of the page it was on.
    let out = emitPDF(sheet("4.17\""), mode: .modern)
    let box = try #require(sheetMediaBox(out))
    #expect(box.width == 612)
    #expect(box.height == 300)
    let ys = drawnYs(out)
    #expect(!ys.isEmpty)
    #expect((ys.max() ?? .infinity) < 300)
}

@Test func aTallSheetStartsAtItsOwnTopNotLetters() throws {
    // The taller direction lost space rather than text: a 13in Rolodex template began
    // 144pt below the top of its own sheet.
    let out = emitPDF(sheet("13.00\""), mode: .modern)
    let box = try #require(sheetMediaBox(out))
    #expect(box.height == 936)
    #expect((drawnYs(out).max() ?? 0) > 792)
}

@Test func aLetterDocumentIsUntouched() throws {
    let box = try #require(sheetMediaBox(emitPDF(sheetDocument(sheetParagraph),
                                                 mode: .modern)))
    #expect(box.width == 612)
    #expect(box.height == 792)
}

@Test func theMediaBoxAndTheComposingHeightAreOneNumber() throws {
    // The defect was two derivations of "how tall is this sheet" that disagreed. There
    // is one now, and this asserts it for each shape.
    for pl in ["4.17\"", "13.00\"", "8.50\"", "1.00\""] {
        let doc = sheet(pl)
        let box = try #require(sheetMediaBox(emitPDF(doc, mode: .modern)))
        #expect(Double(box.height) == modernSheetH(doc), "\(pl)")
    }
}

// MARK: - `.pl 0`

@Test func plZeroFallsBackToLetterNotAZeroHeightPage() throws {
    // `.pl 0` is "page breaks off", not a zero-tall sheet. Printed has read it that way
    // since `resolvedPrintedPageHeight` was written; Modern used to emit a
    // `/MediaBox [0 0 612 0]`.
    let doc = sheet("0")
    #expect(modernSheetH(doc) == Double(PDFMetrics.pageHeight))
    let box = try #require(sheetMediaBox(emitPDF(doc, mode: .modern)))
    #expect(box.width == 612)
    #expect(box.height == 792)
}

@Test func plZeroReadsTheSameInBothModes() {
    let doc = sheet("0")
    #expect(modernSheetH(doc) == Double(resolvedPageHeight(doc, printed: true)))
}

// MARK: - degenerate shapes

@Test func aSheetShorterThanTheFootnoteFloorKeepsTheFloor() throws {
    // Printed's own floor and Printed's own reason: a page has to hold
    // `footnoteFloor + 1` lines.
    let doc = sheet("0.25\"")
    let floorPoints = PDFMetrics.lead * (footnoteFloor + 1)
    #expect(modernSheetH(doc) == Double(floorPoints))
    let box = try #require(sheetMediaBox(emitPDF(doc, mode: .modern)))
    #expect(box.height == floorPoints)
}

@Test func aSheetShorterThanModernsOwnMarginsStillTerminates() throws {
    // A 1in sheet with no `.mt`/`.mb` of its own leaves Modern's default 1in top and 1in
    // bottom margins overlapping. It must still produce a finite PDF rather than
    // paginating forever.
    let out = emitPDF(sheet("1.00\""), mode: .modern)
    let box = try #require(sheetMediaBox(out))
    #expect(box.height == 72)
    #expect(pageCount(out) >= 1)
}

// MARK: - M17 still stands

@Test func aLandscapeSheetStillResolvesTheSwappedPair() throws {
    var dots = ".pr or=l"
    dots += CR
    dots += ".pl 8.50\""
    dots += CR
    let out = emitPDF(sheetDocument(sheetParagraph, dots: dots), mode: .modern)
    let box = try #require(sheetMediaBox(out))
    #expect(box.width == 792)
    #expect(box.height == 612)
    #expect((drawnYs(out).max() ?? .infinity) < 612)
}
