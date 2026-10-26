import Foundation
import Testing
@testable import CtrlKD

/// Planning #577 (ruling R-130): in Printed mode a document WITH notes lays out exactly like
/// one WITHOUT, apart from the note area itself. There is one paginator for both
/// (`layoutPrintedPages`); a note is a feature it runs when the document has one. These tests
/// state that as behaviour: the same text, with and without a footnote on its last line,
/// gets the same page furniture and the same line geometry.

/// Dot commands that each took a different path with notes before the routes were one:
/// space before/after, `.pm` first-line indent, `.sr` roll, even/odd page offset, a running
/// head, and a changed top margin.
private let furnishedDots = [
    ".psb .2\"", ".psa .1\"", ".pm 4", ".sr 6", ".poe .5\"", ".poo 1\"",
    ".he RUNNING", ".mt 2",
].joined(separator: "\r\n") + "\r\n"

private func furnishedDoc(withNote: Bool) -> Document {
    var data = bytes(furnishedDots)
    data += bytes("Alpha line.\r\n\r\nBeta line")
    if withNote {
        data += ws7Note(bytes("A note."), cmd: 0x03, number: 0)
    }
    data += bytes(".\r\n")
    return parseWS(data)
}

/// The body of a page: every line the source supplied (they carry a block index), which is
/// everything but the note area's own lines.
private func bodyLines(_ page: Page) -> [PageLine] {
    page.lines.filter { $0.bi != nil }
}

@Test func aDocumentWithANoteGetsTheSameLineGeometryAsOneWithout() {
    let plain = docToPagelines(furnishedDoc(withNote: false), printed: true)
    let noted = docToPagelines(furnishedDoc(withNote: true), printed: true)
    #expect(plain.count == 1)
    #expect(noted.count == 1)
    let want = bodyLines(plain[0])
    let got = bodyLines(noted[0])
    #expect(got.count == want.count)
    for (a, b) in zip(got, want) {
        #expect(a.lead == b.lead, "space before/after and style leads")
        #expect(a.fi == b.fi, ".pm first-line indent")
        #expect(a.pmActive == b.pmActive)
        #expect(a.roll == b.roll, ".sr roll")
        #expect(a.left == b.left, ".po/.poe/.poo")
        #expect(a.parityLeft?.even == b.parityLeft?.even)
        #expect(a.parityLeft?.odd == b.parityLeft?.odd)
    }
    // The spacing really is in force on both, or the comparison above proves nothing.
    #expect(want.contains { ($0.lead ?? 0) > printedLead(furnishedDoc(withNote: false)) })
}

@Test func aPageWithANoteCarriesTheSameStampsAndRunningHeadAsOneWithout() {
    let plain = docToPagelines(furnishedDoc(withNote: false), printed: true)[0]
    let noted = docToPagelines(furnishedDoc(withNote: true), printed: true)[0]
    #expect(noted.headers == plain.headers)
    #expect(noted.headers[1] == "RUNNING")
    #expect(noted.footers == plain.footers)
    #expect(noted.mtLines == plain.mtLines, "the page's own .mt, stamped like any page's")
    #expect(noted.mbLines == plain.mbLines)
    #expect(noted.plLines == plain.plLines)
    #expect(noted.poCols == plain.poCols, ".poo resolved for the page's parity")
    #expect(noted.autoPagenoPo == plain.autoPagenoPo)
}

@Test func theNoteAreaIsTheOnlyThingAPageWithANoteAdds() {
    let plain = docToPagelines(furnishedDoc(withNote: false), printed: true)[0]
    let noted = docToPagelines(furnishedDoc(withNote: true), printed: true)[0]
    let area = noted.lines.filter { $0.bi == nil }
    #expect(plain.lines.allSatisfy { $0.bi != nil })
    #expect(area.contains { $0.map(\.text).joined().contains("A note.") })
    #expect(noted.lines.count == plain.lines.count + area.count)
}

@Test func naturalPageBreaksAreReportedForADocumentWithANote() {
    // 70 lines over WordStar's default 55-line page is one natural break; a footnote on
    // the first line adds a note area to page 1 and must not hide it (the annotated
    // layout used to report natural breaks only for documents with no notes at all).
    var data = bytes("Line 1.")
    data += ws7Note(bytes("A note."), cmd: 0x03, number: 0)
    data += bytes("\r\n")
    for n in 2...70 {
        data += bytes("Line \(n).\r\n")
    }
    let doc = parseWS(data)
    #expect(hasPlaceableNotes(doc))
    let annotated = annotatedLayout(doc)
    let natural = InkKind.pageBreakOrigin("")
    #expect(annotated.lines.filter { $0.pageBreakBefore == natural }.count == 1)
}

@Test func aThumbnailPageOfADocumentWithNotesIsTheFullRunsFirstPage() {
    // `maxPages: 1` stops paginating once the first page is on the shelf. A note area is
    // built page by page from what each page's own lines reference, so the prefix is the
    // same prefix; it used to be excluded for documents with notes, unproven.
    var data = bytes("Line 1.")
    data += ws7Note(bytes("A note."), cmd: 0x03, number: 0)
    data += bytes("\r\n")
    for n in 2...150 {
        data += bytes("Line \(n).")
        if n == 40 || n == 100 {
            data += ws7Note(bytes("Another note that runs on a little."), cmd: 0x03, number: n)
        }
        data += bytes("\r\n")
    }
    let doc = parseWS(data)
    let full = docToPagelines(doc, printed: true)
    #expect(full.count > 2)
    #expect(full[0].lines.contains { $0.bi == nil }, "page 1 ends in a note area")
    let first = docToPagelines(doc, printed: true, maxPages: 1)
    #expect(first.count == 1)
    #expect(first[0] == full[0])
}
