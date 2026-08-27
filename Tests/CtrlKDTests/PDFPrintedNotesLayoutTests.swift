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

// MARK: - The hang the Python version shipped with (see PDFLayout.swift's `admitFootnotes`)
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
    // which is precisely the boundary `admitFootnotes`' forcing branch exists for.
    // `.mt`/`.mb` at WordStar's own defaults against a 3-line `.pl` drive
    // `textLinesPerPage` to its 1-line floor (3 - 3 - 8 = -8), but `printedCap` clamps
    // the actual page BUDGET to `footnoteFloor + 1` (4) regardless — matching the fixed
    // page height (0.5in) this test's height-based capacity used before ctrl-kd 1.3.0.
    let page = PageGeometry(
        plLines: 3, heightIn: 0.5, sizeName: "Custom", sizeSource: .file,
        mtLines: 3, mtSource: .default, mbLines: 8, mbSource: .default,
        poCols: 8, poSource: .default,
        hmLines: 2, hmSource: .default, fmLines: 2, fmSource: .default,
        lh48: 8, lhSource: .default, ls: 1, lsSource: .default,
        cw120: 12, cwSource: .default,
        textLines: textLinesPerPage(pl: 3, mt: 3, mb: 8, lh48: 8)
    )
    let noteText = manyWords(30)
    let doc = Document(
        blocks: [Block(lines: [Line(spans: [
            Span(text: "Ref"), Span(text: "1", styles: [.sup, .fnref]), Span(text: " end."),
        ])])],
        notes: [Note(kind: .footnote, text: noteText, number: 0, numberFormat: 3)],
        page: page
    )

    let pages = docToPagelines(doc, printed: true)

    // Termination: bounded well under what an unbounded loop would need to even start
    // showing symptoms. (Runs synchronously — if `admitFootnotes` ever loses its
    // forcing branch, this call does not return, and the fail-proof below is what shows
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
// The Rule 5 loop now has a progress guard, so an admission-helper regression can no
// longer hang the machine -- but that guard also made the regression INVISIBLE: with the
// bug reintroduced, both the layout test and all six vector comparisons still passed.
// Safety must not erase detectability. This tests the invariant directly, at the helper
// where it can actually be violated, in a single call that cannot loop. (Originally
// written against `fitFooter`; retargeted 2026-08-18 when the Rule 5 loop moved to the
// Python-shape `admitFootnotes`, which owns the same forcing branch now.)
@Test func admitFootnotesAlwaysConsumesAtLeastOneQueuedLine() {
    // The pathological geometry from the outage, restated for the ported helper: an
    // empty area costs the 3-line header, so ceiling 4 leaves room 1 -- too small for a
    // net-progress split, which is exactly when the forcing branch must take the
    // continuation marker plus at least ONE real line.
    // needsContinuedMarker: TRUE is load-bearing. On a first call there is no marker, so
    // even a buggy forcing branch consumes one line and looks fine -- an earlier version
    // of this test set it false and passed against the regression, i.e. it was vacuous.
    // The stall only appears on a CONTINUATION pass, where the room is spent on the
    // "...Continued..." marker itself and the note's own text is left untouched -- a
    // state that is easy to reason past when reading the code statically.
    var entries: [[PageLine]] = []
    var queue = [QueuedNote(
        remaining: [[Span(text: "alpha")], [Span(text: "beta")], [Span(text: "gamma")]],
        needsContinuedMarker: true)]
    let before = queue.reduce(0) { $0 + $1.remaining.count }
    admitFootnotes(&entries, &queue, ceiling: 4)
    let after = queue.reduce(0) { $0 + $1.remaining.count }
    #expect(after < before,
            "admitFootnotes consumed nothing (\(before) -> \(after)); the Rule 5 loop would spin forever without its progress guard")
}

// MARK: - Rule 5's top-of-page header (2026-08-18)
//
// "Except after the last page of regular text, where footnotes are printed at the top of
// the page." Python renders EVERY area — bottom-of-page and these trailing top-of-page
// ones alike — through `_render_area`, whose header is always the same 3 lines:
// blank / 20-dash separator / blank. The Swift trailing loop used `fitFooter` with
// `leadingBlank: false`, which dropped the leading blank and emitted a 1-line header
// (separator only) — a shape divergence from the oracle on any document whose notes
// overflow past the last body page. Ported 2026-08-18: the trailing loop now goes through
// the same `admitFootnotes`/`renderArea` pair as the in-page area.
@Test func trailingNotesPageCarriesTheFullThreeLineHeader() {
    // One body line referencing one footnote whose text wraps to more lines than the
    // last body page's area can hold (terminal ceiling 54 on the default 55-line page,
    // minus the 3-line header = 51 lines of note text), so the remainder prints at the
    // top of its own fresh page.
    var doc = Document()
    doc.notes = [Note(kind: .footnote, text: manyWords(450), number: 0)]
    doc.blocks = [Block(kind: .para, lines: [Line(spans: [
        Span(text: "Ref"), Span(text: "1", styles: [.sup, .fnref]),
    ])])]

    let pages = docToPagelines(doc, printed: true)
    let texts = pages.map { $0.map { $0.map(\.text).joined() } }

    #expect(texts.count == 2, "expected 2 pages, got \(texts.count)")
    guard texts.count == 2 else { return }

    // Page 1: exactly full — 1 body line + the area grown to the terminal ceiling.
    #expect(texts[0].count == 55, "page 1 holds \(texts[0].count) lines, expected 55")

    // Page 2, the trailing top-of-page area: the SAME 3-line header as everywhere else
    // (blank / 20-dash rule / blank), then the continuation marker and the rest.
    let dashes = String(repeating: "-", count: 20)
    #expect(Array(texts[1].prefix(3)) == ["", dashes, ""],
            "trailing area header must be blank/rule/blank, got \(Array(texts[1].prefix(3)))")
    #expect(texts[1].count > 3 && texts[1][3] == "...Continued...",
            "the resumed note leads with its continuation marker")

    // No text lost across the split.
    let all = texts.flatMap { $0 }.joined(separator: " ")
    #expect(all.contains("word0") && all.contains("word449"))
}

// MARK: - The projected-full-footer counterexample (2026-08-18)
//
// The body-admission check used to project the WHOLE outstanding note queue unsplit
// (`footerFullSize`) and demand it fit alongside the body — a differently-shaped guess at
// Python's incremental `_admit_footnotes` loop, which commits note lines as references
// appear and SPLITS a note that can't finish, so a reference line whose notes only partly
// fit is still admitted (rule 4: the overflow continues on the next page's area).
// Equivalence between the two shapes was empirical until a 20-annotation document
// produced the first counterexample: at the page boundary the projected check pushed the
// reference line (and all its notes) to the next page, while WordStar — and Python —
// admit the line, fill the area to the ceiling, and continue the leftover note overleaf.
//
// This synthetic fixture reproduces that exact decision on the default 55-line page:
// 12 one-line annotations already admitted (area 26 with its 3-line header and
// inter-note blanks), 24 body lines down, and then a reference line carrying 3 more
// annotations. Correct (Python-oracle) behavior: the line IS admitted (24+1+26 = 51 <= 55),
// two of its notes join the area (area 30, page exactly full at 55), and the third
// defers WHOLE to page 2's area. The old projected check computed 24+1+32 = 57 > 55 and
// broke the page first — page 1 ended at 50 lines with the reference line overleaf.
@Test func referenceLineIsAdmittedWhileItsNotesSplitAcrossThePageBoundary() {
    var doc = Document()
    doc.notes = (1...15).map {
        Note(kind: .annotation, text: "note \($0)", tag: "T\($0)", offset: $0 * 100)
    }
    var lines: [Line] = []
    // Line 1 carries the first 12 references; their notes all fit the page-1 area.
    lines.append(Line(spans: [Span(text: "Line 1")]
        + (1...12).map { _ in Span(text: "0", styles: [.sup, .fnref]) }))
    for k in 2...24 {
        lines.append(Line(spans: [Span(text: "Line \(k)")]))
    }
    // The divergent line: 3 more references, of which only 2 notes still fit below.
    lines.append(Line(spans: [Span(text: "Tail")]
        + (1...3).map { _ in Span(text: "0", styles: [.sup, .fnref]) }))
    lines.append(Line(spans: [Span(text: "After")]))
    doc.blocks = [Block(kind: .para, lines: lines)]

    let pages = docToPagelines(doc, printed: true)
    let texts = pages.map { $0.map { $0.map(\.text).joined() } }

    #expect(pages.count == 2, "expected 2 pages, got \(pages.count)")
    guard texts.count == 2 else { return }

    // Page 1: exactly full — 25 body lines + the 30-line area (header 3 + 14 notes + 13
    // inter-note blanks). The reference line is the 25th body line, NOT pushed overleaf.
    #expect(texts[0].count == 55, "page 1 holds \(texts[0].count) lines, expected 55")
    #expect(texts[0][24].hasPrefix("Tail"), "the reference line must stay on page 1")
    #expect(texts[0][26] == String(repeating: "-", count: 20), "20-dash rule after one blank")
    // Finding 4 (b26 visual pass): tags T1-T9 (2 cols) and T10-T15 (3 cols) differ in
    // width, so this mixed-width annotation list hangs to a shared column
    // (`notesMarkerPadCols`) -- three/two spaces here, not the plain single space.
    #expect(texts[0].contains("T13  note 13"), "first note of the split line fits page 1")
    #expect(texts[0].contains("T14  note 14"), "second note of the split line fits page 1")
    #expect(!texts[0].contains("T15  note 15"), "the third note defers whole to page 2")

    // Page 2: the remaining body line, then the deferred note in a fresh bottom area.
    #expect(texts[1].first == "After")
    #expect(texts[1].contains("T15  note 15"), "the deferred note lands in page 2's area")
    #expect(texts[1].count == 5, "page 2 is 1 body line + the 4-line area, got \(texts[1].count)")
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
        Note(kind: .footnote, text: "first note", number: nil, numberFormat: 3, offset: 100),
        Note(kind: .footnote, text: "second note", number: nil, numberFormat: 3, offset: 200),
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

// MARK: - Finding 2 (b26-print-fidelity-2): bottom-anchored footnote/endnote area
//
// The area used to flow-append right after the body -- wherever the body's own y happened
// to end -- landing mid-page on any document shorter than a full page. Real WS7 anchors it
// at the page bottom instead. `printedNotesReservePt` in PDFLayout.swift.

@Test func printedNoteAreaAnchorsAtThePageBottomOnAShortPage() {
    // Finding 2: a short page's footnote/endnote area used to flow-append right after the
    // body -- wherever the body's own y happened to end -- landing mid-page. Real WS7
    // anchors it at the page bottom instead (measured: -SCREEN.pcl's "1. Footnote"/"(1)
    // Endnote"/dash-rule at PDF y=84/60/108, i.e. top-down 708/732/684; LYING.pcl's own
    // single-footnote area lands on the SAME y=84/108 -- its page is full, so flow-append
    // and bottom-anchor coincide there, which is exactly why the gate never caught this).
    // This doc's body is two short lines -- nowhere near a full (default) 55-line page --
    // so a flow-appended area would land far above y=108; anchored, it lands exactly where
    // WS7 does, at every page-geometry DEFAULT (`.mb` 8 lines -> 84pt reserve, see
    // `printedNotesReservePt`).
    var data = ws7Block(0x00)
    data += bytes("Short body line has a note") + ws7Note(bytes("Footnote text."), cmd: 0x03, number: 0)
    data += bytes(" and an endnote") + ws7Note(bytes("Endnote text."), cmd: 0x04, number: 0)
    data += bytes(" here.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    func y(_ text: String) -> Double? { spans.first { $0.text == text }?.y }
    #expect(y(String(repeating: "-", count: 20)) == 108.0)
    // Finding 4 (b26 visual pass): "1." and "(1)" differ in width, so this mixed
    // footnote/endnote list hangs to a shared column -- three/two spaces, not the
    // plain single space (`notesMarkerPadCols`).
    #expect(y("1.   Footnote text.") == 84.0)
    #expect(y("(1)  Endnote text.") == 60.0)
}

@Test func printedNoteAreaAnchorIsANoOpOnAnAlreadyFullPage() {
    // The bottom-anchor override only fires when it would push the area DOWN past where
    // sequential flow already puts it -- a page whose body already reaches (within one
    // default lead of) the anchor target is untouched, which is what keeps LYING.WS's
    // printed PDF byte-identical. Pinned here with a synthetic page sized so the body runs
    // right up to the anchor at every page-geometry DEFAULT (cap 55 = `.pl` 66 - `.mt` 3 -
    // `.mb` 8): 51 body lines (one carrying the footnote ref) leave the 4-line footnote
    // area exactly filling the rest of the 55-line cap -- the SAME "flow already gets
    // there" case LYING.WS's own full pages are in (measured: override computes to
    // exactly 0.0 here, so the area renders at its natural flow position, 12pt above where
    // the bottom-anchor formula alone would put it).
    var data = ws7Block(0x00)
    data += bytes("Body line 1 has a note") + ws7Note(bytes("Note."), cmd: 0x03, number: 0)
    data += bytes(" here.") + HARD
    for i in 2...51 {
        data += bytes("Body line \(i).") + HARD
    }
    let doc = parseWS(data)
    #expect(printedCap(doc) == 55)
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    func y(_ text: String) -> Double? { spans.first { $0.text == text }?.y }
    // natural flow (top 60 + 51 body lines * 12 + this line's own 12 = 96, PDF
    // bottom-origin) -- ONE line short of the 84pt anchor's own target for a 4-line area
    // (108), confirming the override did NOT fire and pull the rule down to the anchor
    // position.
    #expect(y(String(repeating: "-", count: 20)) == 96.0)
    #expect(y("1. Note.") == 72.0)
}
