import Foundation
import Testing
@testable import CtrlKD

/// M31: `.pr or=l` / `.pr or=p` is a PER-PAGE sheet, not one flag for the whole document.
/// Swift port of ctrl-kd's `tests/test_per_page_orientation.py` — same synthetic
/// documents, same expectations.
///
/// WHAT WAS WRONG. `.pr or=` was captured once, at parse time, into
/// `doc.formatting.orientation` — whatever value the file happened to set LAST. That is
/// the same defect class `poCols`/`lead48` are already excluded from the document-level
/// formatting record for; it simply never reached `.pr`. A file that asks for landscape
/// on one page and portrait on the rest printed every page portrait, and the landscape
/// page's content ran off the right edge of a sheet too narrow to hold it — silently,
/// because a viewer clips at the MediaBox without complaining.
///
/// THE TIMING RULE IS MEASURED, not inferred. Real WordStar 7 under DOSBox-X, printing
/// through the LASERJET driver to PCL5, 2026-09-17:
///
///   MIDPAGE probe — two lines of text, then `.pr or=l`, then a third line, then `.pa`:
///       offset 0x0030  ESC&l0O   portrait, written at the top of page 1
///       offset 0x0128  0x0c      form feed ending page 1
///       offset 0x0129  ESC&l1O   landscape, one byte AFTER that form feed
///   All THREE of page 1's lines — including the one after `.pr or=l` — printed under
///   the portrait setting. WS7 emits no orientation escape mid-page at all; it queues
///   the change to the next page boundary.
///
///   TOPPAGE probe — `.pr or=l` immediately after a `.pa`, before that page's text:
///       0x008c  0x0c      form feed ending page 1
///       0x008d  ESC&l1O   landscape, before page 2's own text
///       0x00cc  0x0c      form feed ending page 2
///       0x00cd  ESC&l0O   portrait again, before page 3's text
///   Each command applies to the page it OPENS.
///
/// So the orientation in force at the position a page OPENS at is that page's sheet, and
/// a command reached later in the page belongs to the next one. The position is
/// `(block, how many lines of that block earlier pages took)` — the block alone cannot
/// tell the two probes apart, because a `.pr` typed between two lines of a paragraph sits
/// in the SAME block the page opened at.
///
/// SYNTHETIC ONLY: every document below is constructed bytes. The real-world document
/// this was found on lives in the private corpus and is covered by the shared answer key.

private let M31_HARD: [UInt8] = [0x0D, 0x0A]

/// The WS5+ seed block every real WS5/6/7 document opens with. Without it a short,
/// plainly-laid-out synthetic file classifies as a `printstream`, and the RTF emitter
/// then renders a `printstream` PRINTED whatever mode it is asked for (a documented,
/// long-standing rule) — which would make the Modern half of the RTF test below assert
/// nothing at all.
private func m31WS7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
    let count = UInt16(content.count + 4)
    let countBytes: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var out: [UInt8] = [0x1D]
    out += countBytes
    out.append(cmd)
    out += content
    out += countBytes
    out.append(0x1D)
    return out
}

private let m31WS5Seed = m31WS7Block(0x0B, [0, 0, 0, 0])

private func m31Body(_ tag: String, lines: Int = 3) -> [UInt8] {
    var out: [UInt8] = []
    for i in 1...lines { out += Array("\(tag) line \(i).".utf8) + M31_HARD }
    return out
}

private func m31Dot(_ text: String) -> [UInt8] { Array(text.utf8) + M31_HARD }

/// Join the pieces of a fixture document. Sequential `+=`, never a chained `+` across
/// many terms: macOS CI's type-checker abandons those (`tools/githooks/pre-push`, planning
/// #253), and Linux's does not, so nothing local catches it without the guard.
private func m31Doc(_ parts: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    for part in parts { out += part }
    return out
}

/// Every page's `/MediaBox [0 0 W H]`, in page order.
private func mediaBoxes(_ pdf: [UInt8]) -> [(width: Int, height: Int)] {
    let text = String(decoding: pdf, as: UTF8.self)
    var out: [(width: Int, height: Int)] = []
    var rest = Substring(text)
    while let range = rest.range(of: "/MediaBox [0 0 ") {
        rest = rest[range.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { break }
        let nums = rest[..<close].split(separator: " ").compactMap { Int($0) }
        if nums.count == 2 { out.append((nums[0], nums[1])) }
        rest = rest[close...]
    }
    return out
}

private func printedBoxes(_ data: [UInt8]) -> [(width: Int, height: Int)] {
    mediaBoxes(emitPDF(parseWS(data), mode: .printed))
}

private let portrait = (width: 612, height: 792)
private let landscape = (width: 792, height: 612)

private func same(_ boxes: [(width: Int, height: Int)],
                  _ expected: [(width: Int, height: Int)]) -> Bool {
    boxes.count == expected.count
        && zip(boxes, expected).allSatisfy { $0 == $1 }
}

// ------------------------------------------------------------ the two probe shapes

@Test func aPageTopOrientationCommandLandsOnThePageItOpens() {
    // TOPPAGE, reproduced: `.pr or=l` after a `.pa` and before that page's own text is
    // THAT page's sheet, and `.pr or=p` after the next `.pa` puts the page after it back.
    let data = m31Doc([m31Body("ONE"),
                       m31Dot(".pa"), m31Dot(".pr or=l"), m31Body("TWO"),
                       m31Dot(".pa"), m31Dot(".pr or=p"), m31Body("THREE")])
    #expect(same(printedBoxes(data), [portrait, landscape, portrait]))
}

@Test func aMidPageOrientationCommandWaitsForTheNextPage() {
    // MIDPAGE, reproduced: text, then `.pr or=l`, then MORE text on the same page. Real
    // WS7 printed all of that page portrait and only turned landscape on after the form
    // feed — so page 1 stays portrait here and page 2 is the landscape one.
    let data = m31Doc([Array("ONE line 1.".utf8), M31_HARD,
                       Array("ONE line 2.".utf8), M31_HARD,
                       m31Dot(".pr or=l"),
                       Array("ONE line 3, after the landscape command.".utf8), M31_HARD,
                       m31Dot(".pa"), m31Body("TWO")])
    #expect(same(printedBoxes(data), [portrait, landscape]))
}

@Test func anOrientationDeclaredBeforeAnyTextOwnsPageOne() {
    // The overwhelmingly common real shape — a landscape template whose `.pr or=l` sits
    // in its opening dot block — is unchanged: every page landscape, exactly as the
    // document-wide flag already gave it.
    let data = m31Doc([m31Dot(".pr or=l"), m31Body("ONE"), m31Dot(".pa"), m31Body("TWO")])
    #expect(same(printedBoxes(data), [landscape, landscape]))
}

@Test func aDocumentThatNeverMentionsPRIsUntouched() {
    // No `.pr` anywhere: one sheet, every page, same as before M31.
    let data = m31Doc([m31Body("ONE"), m31Dot(".pa"), m31Body("TWO"),
                       m31Dot(".pa"), m31Body("THREE")])
    #expect(same(printedBoxes(data), [portrait, portrait, portrait]))
}

// ------------------------------------------------------------- the other surfaces

@Test func theLayoutJSONPublishesTheSheetOnlyWhereItDiffers() throws {
    // Layout schema version 13: a printed page carries its own `size` ONLY when its
    // orientation differs from the document's. A page without one is the document's own
    // sheet (the top-level `page` object).
    let data = m31Doc([m31Body("ONE"),
                       m31Dot(".pa"), m31Dot(".pr or=l"), m31Body("TWO"),
                       m31Dot(".pa"), m31Dot(".pr or=p"), m31Body("THREE")])
    let json = try #require(try JSONSerialization.jsonObject(
        with: Data(emitLayout(parseWS(data), mode: .printed).utf8)) as? [String: Any])
    #expect(json["version"] as? Int == 13)
    let printed = try #require(json["printed"] as? [String: Any])
    let pages = try #require(printed["pages"] as? [[String: Any]])
    #expect(pages.count == 3)
    #expect(pages[0]["size"] == nil)
    #expect(pages[2]["size"] == nil)
    let size = try #require(pages[1]["size"] as? [String: Any])
    #expect(size["width_pt"] as? Int == 792)
    #expect(size["height_pt"] as? Int == 612)
    #expect(size["orientation"] as? String == "landscape")
}

@Test func printedRTFOpensALandscapeSectionAndModernDoesNot() {
    // RTF's page size is a section property as well as a document one, so the Printed RTF
    // says per section what the Printed PDF says per page. Modern deliberately does NOT:
    // Modern PDF composes every page on one sheet (ruled 2026-09-15), and Modern PDF is
    // the printed form of the Modern RTF (ruled 2026-08-05), so a landscape section there
    // would be an RTF its own PDF does not print.
    let data = m31Doc([m31WS5Seed, m31Body("ONE"),
                       m31Dot(".pa"), m31Dot(".pr or=l"), m31Body("TWO"),
                       m31Dot(".pa"), m31Dot(".pr or=p"), m31Body("THREE")])
    let doc = parseWS(data)
    #expect(!isPrinted(doc), "fixture must not classify as a print stream")
    #expect(emitRTF(doc, mode: .printed).contains(#"\pgwsxn15840\pghsxn12240\lndscpsxn"#))
    #expect(!emitRTF(doc, mode: .modern).contains(#"\lndscpsxn"#))
}

@Test func htmlAndTextAreUntouchedByOrientation() {
    // Neither is a paged surface; neither has a sheet to change.
    let flat = m31Doc([m31Body("ONE"), m31Dot(".pa"), m31Body("TWO")])
    let turned = m31Doc([m31Body("ONE"), m31Dot(".pa"), m31Dot(".pr or=l"), m31Body("TWO")])
    #expect(emitText(parseWS(flat)) == emitText(parseWS(turned)))
    #expect(emitHTML(parseWS(flat)) == emitHTML(parseWS(turned)))
}

@Test func thePublicPageMetricsFacadeCarriesTheSheetPerPage() {
    // planning M31: the apps place Printed/Native text at the coordinates `emitPDF` would,
    // so they must be able to ask for ONE PAGE's sheet. `printedMetrics(doc, page:)` is
    // that accessor; a page with no orientation of its own answers exactly what
    // `printedMetrics(doc)` answers, so a caller may use it unconditionally.
    let data = m31Doc([m31Body("ONE"),
                       m31Dot(".pa"), m31Dot(".pr or=l"), m31Body("TWO"),
                       m31Dot(".pa"), m31Dot(".pr or=p"), m31Body("THREE")])
    let doc = parseWS(data)
    let pages = docToPagelines(printedDocument(doc, options: EmitOptions()), printed: true)
    #expect(pages.count == 3)
    let docMetrics = printedMetrics(doc)
    #expect((docMetrics.pageWidth, docMetrics.pageHeight) == (612.0, 792.0))
    let perPage = pages.map { printedMetrics(doc, page: $0) }
    #expect(perPage.map(\.pageWidth) == [612.0, 792.0, 612.0])
    #expect(perPage.map(\.pageHeight) == [792.0, 612.0, 792.0])
    // Only the SHEET moves: .mt/.lh/.cw/.po are the document's on every page.
    #expect(perPage.allSatisfy { $0.top == docMetrics.top && $0.lead == docMetrics.lead
                                 && $0.size == docMetrics.size && $0.left == docMetrics.left })
    // And the sheet it reports is the one the MediaBox actually carries.
    #expect(same(printedBoxes(data), [portrait, landscape, portrait]))
}
