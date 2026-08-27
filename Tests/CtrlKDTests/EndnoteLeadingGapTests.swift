import Testing
@testable import CtrlKD

/// b28 note 6: the blank line ahead of the FIRST endnote on a page that also carries
/// body text.
///
/// Jon, reviewing b27 against real WS7: "On the last page of Printed from WS7, the
/// endnotes go *immediately* after the text. In ours we add a line return before the
/// notes in our engine. Ours looks better but it's not accurate."
///
/// Round 26 wave 3 added that gap unconditionally, on the strength of a 2026-08-20
/// measurement of `-SCREEN.pcl` reading a 240-decipoint advance as "24pt, one blank
/// line". WS7's note face is 12-point, so ONE note line IS 120dp and 240dp is two —
/// the measurement was right about `-SCREEN` and wrong to generalise. Re-measured
/// 2026-08-23 across both WS7 captures (WordStar/ws7-captures/ + the deprecated v1/ batch):
///
///   -SCREEN.pcl  "1. Footnote" V=7080 -> "(1) Endnote"  V=7320 = 240dp
///                = one blank line, endnotes joining a FOOTNOTE AREA.
///   TESTING.pcl  last body line     V=3765 -> "(1)This..." V=3885 = 120dp
///                = NO blank line, endnotes following BODY TEXT.
///   TESTING.pcl  endnote (1) V=3885 -> (2) V=4125 = 240dp = one blank line BETWEEN
///                entries.
///
/// Swift-side mirror of ctrl-kd's `tests/test_endnote_leading_gap.py`; the two engines
/// are also held together on this by `LayoutByteParityTests`, whose oracle was
/// regenerated from the fixed Python in the same change.
private let ws5SeedForNotes = ws7Block(0x0B, payload: [0, 0, 0, 0])
private let endnoteCmd: UInt8 = 0x04
private let footnoteCmd: UInt8 = 0x03

/// One joined string per PageLine, blank lines preserved as "".
private func lineTexts(_ page: Page) -> [String] {
    page.map { line in
        line.map(\.text).joined()
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
}

private func index(of needle: String, in lines: [String]) throws -> Int {
    let i = lines.firstIndex { $0.contains(needle) }
    return try #require(i, "\(needle) not found in \(lines)")
}

private func lastPageLines(_ data: [UInt8]) -> [String] {
    let pages = docToPagelines(parseWS(data), printed: true)
    return lineTexts(pages[pages.count - 1])
}

@Test func endnoteAfterBodyTextHasNoLeadingBlankLine() throws {
    // WS7 TESTING.pcl: 120dp = one note line = the endnote butts straight up against
    // the last body line.
    var data: [UInt8] = bytes("Body line one.") + HARD
        + bytes("Body line two carries the marker.")
    data += ws7Note(bytes("This is our test endnote."), cmd: endnoteCmd) + HARD
    data += ws5SeedForNotes + [0x1A]
    let lines = lastPageLines(data)
    let body = try index(of: "Body line two", in: lines)
    let note = try index(of: "This is our test endnote.", in: lines)
    #expect(note == body + 1,
            "WS7 puts the first endnote on the very next line after body text; got \(note - body) lines of gap in \(lines)")
}

@Test func endnoteAfterAFootnoteAreaKeepsItsLeadingBlankLine() throws {
    // WS7 -SCREEN.pcl: 240dp = two note lines = one blank line, because the endnote is
    // joining the footnote AREA as one more entry. Must not regress when the body-text
    // case above loses its gap.
    var data: [UInt8] = bytes("Body text with both marks.")
        + ws7Note(bytes("Footnote body."), cmd: footnoteCmd)
    data += ws7Note(bytes("Endnote body."), cmd: endnoteCmd) + HARD
    data += ws5SeedForNotes + [0x1A]
    let lines = lastPageLines(data)
    let fn = try index(of: "Footnote body.", in: lines)
    let en = try index(of: "Endnote body.", in: lines)
    #expect(en == fn + 2 && lines[fn + 1].isEmpty,
            "an endnote joining a footnote area keeps exactly one blank line above it; got \(Array(lines[fn...en]))")
}

@Test func successiveEndnotesKeepOneBlankLineBetweenThem() throws {
    // WS7 TESTING.pcl endnote (1) V=3885 -> (2) V=4125 = 240dp. The inter-entry gap is
    // a separate rule from the leading one.
    var data: [UInt8] = bytes("Body text.")
        + ws7Note(bytes("First endnote."), cmd: endnoteCmd)
    data += ws7Note(bytes("Second endnote."), cmd: endnoteCmd, number: 2) + HARD
    data += ws5SeedForNotes + [0x1A]
    let lines = lastPageLines(data)
    let a = try index(of: "First endnote.", in: lines)
    let b = try index(of: "Second endnote.", in: lines)
    #expect(b == a + 2 && lines[a + 1].isEmpty,
            "expected one blank line between endnote entries; got \(Array(lines[a...b]))")
}
