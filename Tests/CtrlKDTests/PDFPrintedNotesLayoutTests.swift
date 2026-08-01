import Foundation
import Testing
@testable import CtrlKD

/// The Printed-mode footnote/endnote/annotation layout — WordStar 5's page-bottom
/// footnote area, per the WordStar manual algorithm quoted in the job brief. Ground truth
/// is the SAME `Fixtures/notes-vectors-1.2.0.json` `NotesVectorTests.swift` uses for
/// `notes[]`/`meta`, but this file decodes the one field that one deliberately skips:
/// `printed_pagelines`, the exact expected page-by-page, line-by-line Printed output.
///
/// `Foundation` is imported here for `JSONDecoder`/`Bundle` only; the `CtrlKD` library
/// target itself stays Foundation-free.

private struct PrintedVectorFile: Decodable {
    let generator: String
    let cases: [String: PrintedVectorCase]
}

private struct PrintedVectorCase: Decodable {
    let inputHex: String
    let printedPagelines: [[String]]

    enum CodingKeys: String, CodingKey {
        case inputHex = "input_hex"
        case printedPagelines = "printed_pagelines"
    }
}

private func loadPrintedVectors() throws -> PrintedVectorFile {
    let url = try #require(
        Bundle.module.url(forResource: "notes-vectors-1.2.0", withExtension: "json"),
        "notes-vectors-1.2.0.json missing from the test bundle"
    )
    return try JSONDecoder().decode(PrintedVectorFile.self, from: Data(contentsOf: url))
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
    let chars = Array(hex)
    precondition(chars.count % 2 == 0, "hex string must have an even length")
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
    }
    return out
}

/// A laid-out page reduced to plain strings — the vector's own shape, which carries no
/// style information (Printed's factory-default footnote/endnote/annotation text is
/// unstyled regardless of what the reference span itself carries).
private func plainLines(_ page: Page) -> [String] {
    page.map { $0.map(\.text).joined() }
}

@Test func printedFootnoteLayoutMatchesAllSixVectors() throws {
    let file = try loadPrintedVectors()
    #expect(file.generator == "ctrl-kd 1.2.0")
    #expect(file.cases.count == 6)

    for name in file.cases.keys.sorted() {
        let v = file.cases[name]!
        let doc = parseWS(bytesFromHex(v.inputHex))
        let got = docToPagelines(doc, printed: true).map(plainLines)
        #expect(got.count == v.printedPagelines.count, "\(name): page count")
        for (p, wantPage) in v.printedPagelines.enumerated() where p < got.count {
            #expect(got[p] == wantPage, "\(name) page \(p)")
        }
    }
}

// MARK: - The hang the Python version shipped with (see PDFLayout.swift's `fitFooter`)
//
// A footnote whose room, on every page it's offered, is exactly 1 line: the Python bug
// admitted one line, prepended it right back as `...Continued...` on the next attempt, and
// repeated forever. This is the shape that reaches it — a tiny `.pl` (the job brief's own
// "labels, index cards" example) and one footnote long enough that it can't finish in a
// single forced chunk.

/// 30 short, distinct words — long enough to need many wrapped lines at the real 65-column
/// width, short enough that every single one is cheap to check for in the output.
private func manyWords(_ n: Int) -> String {
    (0..<n).map { "word\($0)" }.joined(separator: " ")
}

@Test func tinyPageFootnoteSplitTerminatesAndLosesNoWords() {
    // `.PL 3`: three lines to a page — big enough to hold the 20-dash rule plus exactly one
    // line of note text (room == 1 for the note's own content once the rule is paid for),
    // which is precisely the boundary `fitFooter`'s forcing branch exists for.
    // `.mt`/`.mb` at WordStar's own defaults against a 3-line `.pl` drive
    // `textLinesPerPage` to its 1-line floor (3 - 3 - 8 = -8), but `printedCap` clamps
    // the actual page BUDGET to `footnoteFloor + 1` (4) regardless — matching the fixed
    // page height (0.5in) this test's height-based capacity used before ctrl-kd 1.3.0.
    let page = PageGeometry(
        plLines: 3, heightIn: 0.5, sizeName: "Custom", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        poCols: 0, poSource: .default,
        hmLines: 2, hmSource: .default, fmLines: 2, fmSource: .default,
        lh48: 8, lhSource: .default, ls: 1, lsSource: .default,
        textLines: textLinesPerPage(pl: 3, mt: 3, mb: 8, lh48: 8)
    )
    let noteText = manyWords(30)
    let doc = Document(
        blocks: [Block(lines: [Line(spans: [
            Span(text: "Ref"), Span(text: "1", styles: [.sup, .fnref]), Span(text: " end."),
        ])])],
        notes: [Note(kind: .footnote, text: noteText, number: 0)],
        page: page
    )

    let pages = docToPagelines(doc, printed: true)

    // Termination: bounded well under what an unbounded loop would need to even start
    // showing symptoms. (Runs synchronously — if `fitFooter` ever regresses to the
    // Python shape, this call does not return, and the fail-proof below is what shows
    // that failure mode without wedging the whole suite over it.)
    #expect(pages.count < 50, "page count \(pages.count) -- expected a small, bounded number")

    // No text lost: every one of the 30 words survives somewhere in the output, in order.
    let allText = pages.flatMap(plainLines).joined(separator: " ")
    for i in 0..<30 {
        #expect(allText.contains("word\(i)"), "word\(i) missing from output")
    }
    // And the reference line itself is intact.
    #expect(allText.contains("Ref1 end."))
}

// MARK: - The progress invariant
//
// The Rule 5 loop now has a progress guard, so a `fitFooter` regression can no longer
// hang the machine -- but that guard also made the regression INVISIBLE: with the bug
// reintroduced, both the layout test and all six vector comparisons still passed.
// Safety must not erase detectability. This tests the invariant directly, at the helper
// where it can actually be violated, in a single call that cannot loop.
@Test func fitFooterAlwaysConsumesAtLeastOneQueuedLine() {
    // The pathological geometry from the outage: room 3 -> overhead 1, budget 2,
    // avail 1. The pre-fix code split at avail == 1, admitting one line while owing a
    // `...Continued...` line back, for net-zero progress forever.
    // needsContinuedMarker: TRUE is load-bearing. On a first call there is no marker, so
    // even the buggy code consumes one line and looks fine -- an earlier version of this
    // test set it false and passed against the regression, i.e. it was vacuous. The stall
    // only appears on a CONTINUATION pass, where the single line of room is spent on the
    // "...Continued..." marker itself and `take - markerTaken == 0` leaves the note's own
    // text untouched -- a state that is easy to reason past when reading the code
    // statically, and only shows up on a continuation pass.
    var queue = [QueuedNote(
        remaining: [[Span(text: "alpha")], [Span(text: "beta")], [Span(text: "gamma")]],
        needsContinuedMarker: true)]
    let before = queue.reduce(0) { $0 + $1.remaining.count }
    _ = fitFooter(queue: &queue, room: 3, leadingBlank: false)
    let after = queue.reduce(0) { $0 + $1.remaining.count }
    #expect(after < before,
            "fitFooter consumed nothing (\(before) -> \(after)); the Rule 5 loop would spin forever without its progress guard")
}

/// Printed layout must use the SAME label rule as the flat emitters. It once had its own
/// copy that fell back to `?? 0` when a note carries no resolved number (a real outcome —
/// the tag word's high bit means the file never assigned one), so every unnumbered note of
/// a kind rendered with an identical marker: two different footnotes both shown as "1".
///
/// This must exercise the PRINTED LAYOUT, not the shared label helper. An earlier version
/// called `noteLabel` directly and passed happily with the bug reintroduced, because the
/// duplicated copy lived in a private function the test never reached. A regression test
/// has to travel the code path that actually broke.
@Test func unnumberedNotesGetDistinctMarkersInPrintedLayout() {
    // Distinct `offset`s are load-bearing: notes are identified by source offset, which
    // every really-parsed note has.
    var doc = Document()
    doc.notes = [
        Note(kind: .footnote, text: "first note", number: nil, offset: 100),
        Note(kind: .footnote, text: "second note", number: nil, offset: 200),
    ]
    doc.blocks = [Block(kind: .para, lines: [Line(spans: [
        Span(text: "a"), Span(text: "1", styles: .fnref),
        Span(text: " b"), Span(text: "2", styles: .fnref),
    ])])]
    let rendered = docToPagelines(doc, printed: true)
        .flatMap { $0 }.map { $0.map(\.text).joined() }
    let footerMarkers = rendered.compactMap { line -> String? in
        guard let r = line.range(of: #"^\s*(\d+)\."#, options: .regularExpression) else { return nil }
        return String(line[r]).trimmingCharacters(in: .whitespaces)
    }
    #expect(Set(footerMarkers).count == footerMarkers.count,
            "two unnumbered footnotes shared a footer marker: \(footerMarkers)")
    #expect(footerMarkers.count == 2, "expected both notes in the footer, got \(footerMarkers)")
}
