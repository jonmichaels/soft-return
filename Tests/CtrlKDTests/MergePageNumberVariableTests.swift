/// Planning #270 item 40 (triage Q7), Jon's ruling 2026-09-13: "I guess we can
/// adopt... page numbers seems reasonable."
///
/// WordStar's MailMerge substitutes the page-number variable `&#&` at PRINT time with
/// the number of the page it lands on, and real WS7 does exactly that in both corpus
/// documents that print one — `sawyer/REF/TOCTRICK.WS` prints `2` on page 2 where the
/// author typed `&#/r&`, and `sawyer/ARTICLES/POWERUSE.WS` prints `CNT=8` on page 8
/// where the author typed `CNT=&#&`.
///
/// The other half of the ruling matters just as much, and is what most of this file
/// guards: this is the ONLY merge variable that is ever substituted. From the same
/// ruling's MAIL MERGE scope paragraph — "a merge letter opens and exports as the
/// letter itself, variables shown as-is (not substituted, not stripped), except the
/// page-number variables per item 40."
///
/// Port of ctrl-kd's `tests/test_merge_page_number_variable.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private let hard: [UInt8] = [0x0D, 0x0A]

private func ws7Block(_ cmd: UInt8, _ content: [UInt8]) -> [UInt8] {
    let count = UInt16(content.count + 4)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var out: [UInt8] = [0x1D]
    out += le
    out += [cmd]
    out += content
    out += le
    out += [0x1D]
    return out
}

private func mergeDocument(_ body: String) -> Document {
    var bytes = ws7Block(0x00, [0x70] + [UInt8](repeating: 0, count: 15))
    bytes += [UInt8](body.utf8)
    return parseWS(bytes)
}

/// `[[line text, ...], ...]` per printed page — what the writer draws.
private func printedPageText(_ doc: Document) -> [[String]] {
    docToPagelines(doc, printed: true).map { page in
        page.lines.map { $0.spans.map(\.text).joined() }
    }
}

// MARK: - the page-number variable

@Test func thePageNumberVariableIsSubstitutedOnThePageItLandsOn() {
    // TOCTRICK.WS's own shape: the variable appears on more than one page and each
    // occurrence takes ITS OWN page's number, not the first's.
    let pages = printedPageText(mergeDocument(
        "Page one text with &#& in it.\r\n.pa\r\nPage two text with &#& in it.\r\n"))
    #expect(pages[0].contains { $0.contains("with 1 in it.") })
    #expect(pages[1].contains { $0.contains("with 2 in it.") })
    for page in pages {
        for line in page { #expect(!line.contains("&#")) }
    }
}

@Test func aSlashModifierIsAcceptedAndPrintsThePlainArabicNumber() {
    // `&#/r&` is what `sawyer/REF/TOCTRICK.WS` actually stores, and real WS7 prints
    // `2` for it on page 2 — the plain arabic number, not a roman numeral (the
    // capture's own chunks at x_decipoints 720 and 2304, text `2`).
    let pages = printedPageText(mergeDocument("Trick: &#/r& here.\r\n"))
    #expect(pages[0].contains { $0.contains("Trick: 1 here.") })
}

@Test func theVariableSubstitutesInsideAWordNotOnlyAlone() {
    // POWERUSE.WS prints `CNT=8`, not `CNT= 8` or `CNT=` — the variable is spliced
    // into the surrounding text with no spacing of its own.
    let pages = printedPageText(mergeDocument("CNT=&#& is a new value.\r\n"))
    #expect(pages[0].contains { $0.contains("CNT=1 is a new value.") })
}

@Test func aPNRestartSubstitutesTheNumberWordStarWouldHavePrinted() {
    // The page number comes from the same `.pn`/`.pg` checkpoint walk the running
    // head's `#` and the automatic page number already use, never the page's index.
    let pages = printedPageText(mergeDocument(
        "First sheet with &#&.\r\n.pa\r\n.pn 10\r\nSecond sheet with &#&.\r\n"))
    #expect(pages[0].contains { $0.contains("with 1.") })
    #expect(pages[1].contains { $0.contains("with 10.") })
}

// MARK: - every OTHER merge variable stays

@Test func anOrdinaryMergeVariableIsNeverSubstitutedOrStripped() {
    // The ruling's scope, verbatim: "variables shown as-is (not substituted, not
    // stripped), except the page-number variables per item 40."
    let pages = printedPageText(mergeDocument(
        "Dear &NAME&, of &COMPANY& at &ADDRESS/O&:\r\n"))
    let line = pages[0].first { $0.contains("Dear") } ?? ""
    #expect(line.contains("&NAME&"))
    #expect(line.contains("&COMPANY&"))
    #expect(line.contains("&ADDRESS/O&"))
}

@Test func aVariableMerelyContainingAHashIsNotThePageNumber() {
    // Only the variable whose NAME is exactly `#` is the page number.
    let pages = printedPageText(mergeDocument("See &REF#& and &#COUNT& and &N#M&.\r\n"))
    let line = pages[0].first { $0.contains("See") } ?? ""
    #expect(line.contains("&REF#&"))
    #expect(line.contains("&#COUNT&"))
    #expect(line.contains("&N#M&"))
}

@Test func aDocumentWithNoMergeVariableIsUntouched() {
    let pages = printedPageText(mergeDocument("Ordinary prose, an ampersand & a hash #.\r\n"))
    #expect(pages[0].contains { $0.contains("Ordinary prose, an ampersand & a hash #.") })
}

@Test func theScannerRejectsEveryShapeThatIsNotThePageNumberVariable() {
    // The accepted shape, exactly: `&`, `#`, optionally `/` plus one or more ASCII
    // letters, `&`. Everything else is ordinary text.
    #expect(mergePageNumberRange(Array("&#&"), from: 0) == 3)
    #expect(mergePageNumberRange(Array("&#/r&"), from: 0) == 5)
    #expect(mergePageNumberRange(Array("&#/RO&"), from: 0) == 6)
    #expect(mergePageNumberRange(Array("&#/&"), from: 0) == nil)     // empty modifier
    #expect(mergePageNumberRange(Array("&#/1&"), from: 0) == nil)    // digits aren't one
    #expect(mergePageNumberRange(Array("&#"), from: 0) == nil)       // unterminated
    #expect(mergePageNumberRange(Array("&##&"), from: 0) == nil)
    #expect(mergePageNumberRange(Array("&NAME&"), from: 0) == nil)
}

// MARK: - the 10.15 floor, and the iOS 16 crash (2026-09-14)

/// The pre-filter in front of the scan, and why it is hand-written.
///
/// The first version of `substituteMergePageNumbersPrinted` guarded its loop with
/// `text.contains("&#")`. That is the Swift 5.7 stdlib `Collection` overload of
/// `contains(_:)` — the one taking another STRING — and it is two separate defects at
/// once:
///
///   1. it is `@available(macOS 13.0, *)`, and this package's floor is
///      `.macOS(.v10_15)` (Package.swift `platforms:`), so it compiles on a modern
///      toolchain and fails the Mac floor build; and
///   2. on iOS 16.0 it CRASHES at runtime — "String index is out of bounds"
///      (Swift/Substring.swift:316), inside the two-way search that overload uses,
///      reached from `docToPagelines` on `sawyer/REF/BOOKLET.RJS`.
///
/// An `#available` guard would only have hidden (1) and left (2) exactly where it was on
/// every device at the floor, so the overload is not called at all:
/// `containsMergePageNumberOpener` walks indices itself. These cases are the crash's own
/// shape — the empty string and the one-character string are where a searcher runs off
/// the end, and `&` as the LAST character is the specific index this one walked past.
@Test func theMergePageNumberPreFilterSurvivesEveryDegenerateString() {
    #expect(containsMergePageNumberOpener("") == false)
    #expect(containsMergePageNumberOpener("&") == false)
    #expect(containsMergePageNumberOpener("#") == false)
    #expect(containsMergePageNumberOpener("x") == false)
    #expect(containsMergePageNumberOpener("x&") == false)
    #expect(containsMergePageNumberOpener("&&") == false)
    #expect(containsMergePageNumberOpener("&#") == true)
    #expect(containsMergePageNumberOpener("&&#") == true)
    #expect(containsMergePageNumberOpener("a&b&#c") == true)
    #expect(containsMergePageNumberOpener("&NAME&") == false)
    // Non-ASCII, where a UTF-8 byte search and a Character search disagree about
    // indices — the class of string the crashing overload was walking.
    #expect(containsMergePageNumberOpener("café&") == false)
    #expect(containsMergePageNumberOpener("café&#&") == true)
    #expect(containsMergePageNumberOpener("\u{1F600}&") == false)
}

/// The document the crash was found on, driven through the pass that crashed.
///
/// `sawyer/REF/BOOKLET.RJS` is a landscape `.pr or=l` article with no merge variable in
/// it at all — which is the point: the crash was in the PRE-FILTER, so it fired on
/// ordinary text, on every line, on a document that had nothing to substitute. Running
/// the real thing end to end is the only assertion that matters here; a green run IS the
/// result.
@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func bookletRJSGoesThroughTheMergePageNumberPassWithoutCrashing() throws {
    let url = URL(fileURLWithPath: sawyerArchivePath)
        .appendingPathComponent("REF/BOOKLET.RJS")
    let raw = [UInt8](try Data(contentsOf: url))
    let doc = parseWS(raw)
    var pages = docToPagelines(doc, printed: true)
    #expect(!pages.isEmpty)
    substituteMergePageNumbersPrinted(doc, &pages)
    // Every span of every line, filtered by the same test the pass uses — nothing in
    // this document opens the variable, so nothing may have changed.
    for page in pages {
        for line in page.lines {
            for span in line.spans {
                #expect(containsMergePageNumberOpener(span.text) == false)
            }
        }
    }
}

// MARK: - non-paged exports carry no page apparatus (#270 item 42)
//
// Planning #270 item 42, Jon's ruling 2026-09-14, verbatim: "Actual page numbers and
// the page number merge should NOT be sent to non-paged exports: HTML, Markdown, and
// Text. The current handling of Headers and Footers for non-paged exports is correct.
// That data should not be sent."
//
// Those three formats have no pages, so there is no number to substitute and nothing
// the variable could mean. It is REMOVED — never shown as typed — which is the ONE
// exception to the Mail Merge scope rule's "variables stay visible exactly as typed",
// for the same reason headers and feet are already dropped beside it.

private func nonPagedExports(_ doc: Document, _ mode: EmitMode) -> [(String, String)] {
    [("text", emitText(doc, mode: mode)),
     ("markdown", emitMarkdown(doc, mode: mode)),
     ("html", emitHTML(doc, mode: mode))]
}

@Test func noNonPagedExportEverShowsThePageNumberVariable() {
    let doc = mergeDocument("Set in type on page &#/r& of &#& of this.\r\n")
    for mode in [EmitMode.printed, .modern] {
        for (name, out) in nonPagedExports(doc, mode) {
            #expect(!out.contains("&#/r&"), "\(name)/\(mode)")
            #expect(!out.contains("&#&"), "\(name)/\(mode)")
        }
    }
}

@Test func aNonPagedExportRemovesTheVariableRatherThanNumberingIt() {
    // Removed, not substituted: a page-less format has no page 1 to name.
    let doc = mergeDocument("Page &#&.\r\n")
    for (name, out) in nonPagedExports(doc, .modern) {
        #expect(!out.contains("Page 1."), "\(name)")
    }
}

@Test func everyOtherMergeVariableSurvivesANonPagedExport() {
    let doc = mergeDocument("Dear &NAME& of &COMPANY&, see &REF#& and &#COUNT&.\r\n")
    for mode in [EmitMode.printed, .modern] {
        for (name, out) in nonPagedExports(doc, mode) {
            // HTML escapes the ampersand and Markdown backslash-escapes both the hash
            // and (since the Markdown escaping round) the ampersand — neither is this
            // rule's business, so compare against what a READER of each format actually
            // shows. A Markdown reader renders `\\&` as `&` and `\\#` as `#`; the rule
            // here is "the variable survives", not "the bytes are unescaped".
            let plain = out.replacingOccurrences(of: "&amp;", with: "&")
                           .replacingOccurrences(of: "\\#", with: "#")
                           .replacingOccurrences(of: "\\&", with: "&")
            for variable in ["&NAME&", "&COMPANY&", "&REF#&", "&#COUNT&"] {
                #expect(plain.contains(variable), "\(name)/\(mode)/\(variable)")
            }
        }
    }
}

@Test func aDocumentWithNoVariableIsTheSameDocumentOnTheWayThrough() {
    // The pass is free for the documents that carry none — nothing is rewritten.
    let doc = mergeDocument("Ordinary prose with an ampersand & and a hash #.\r\n")
    let dropped = mergePagenoDropped(doc)
    #expect(dropped.blocks.count == doc.blocks.count)
    for (a, b) in zip(dropped.blocks, doc.blocks) {
        #expect(a.lines.map { $0.spans.map(\.text) } == b.lines.map { $0.spans.map(\.text) })
    }
}

@Test func theDropScanAcceptsExactlyTheVariableAndNothingElse() {
    #expect(mergePagenoDroppedText("a &#& b") == "a  b")
    #expect(mergePagenoDroppedText("a &#/r& b") == "a  b")
    #expect(mergePagenoDroppedText("a &REF#& b") == "a &REF#& b")
    #expect(mergePagenoDroppedText("a &#COUNT& b") == "a &#COUNT& b")
    #expect(mergePagenoDroppedText("a &#/& b") == "a &#/& b")
    #expect(mergePagenoDroppedText("plain text") == "plain text")
}

@Test func thePagedSurfacesStillSubstituteARealNumber() {
    // The other half of the same ruling: Printed is unchanged, and a paged surface
    // prints the number, not a hole.
    let pages = printedPageText(mergeDocument("Set on page &#&.\r\n"))
    #expect(pages[0].contains { $0.contains("Set on page 1.") })
}

// MARK: - item 42 remainder: the paged EXPORTS
//
// Jon's ruling 2026-09-14 (planning #270 item 42), verbatim: "The page number merge
// variable should be substituted for page numbers in Modern PDF and RTF. And it should
// be controlled by the page number flag."
//
// Printed PDF already substituted (above). What follows is the rest: Modern PDF, and
// BOTH RTF modes — Printed RTF is not named by the ruling, and gets it for the same
// reason Modern RTF does. RTF's answer to "the number of the page this lands on" is
// `{\chpgn }`, the reader's own current-page field: an RTF's pages are the reader's, in
// both modes (packet section 3), so a field is not a fallback for a number we could not
// compute — it is the only answer that stays true after the reader lays the file out at
// its own margins and fonts.

private let chpgn = #"{\chpgn }"#

/// The RTF with its `\footer` group removed, so an assertion about the BODY cannot pass
/// on the automatic page number's own field.
private func rtfBody(_ doc: Document, _ mode: EmitMode,
                     _ options: EmitOptions = EmitOptions()) -> String {
    let out = emitRTF(doc, mode: mode, options: options)
    guard let start = out.range(of: #"{\footer "#) else { return out }
    guard let end = out.range(of: #"\par}"#, range: start.upperBound..<out.endIndex) else {
        return out
    }
    return String(out[out.startIndex..<start.lowerBound])
        + String(out[end.upperBound..<out.endIndex])
}

/// `[[word, ...], ...]` per Modern page — Modern draws one `Tj` per word, so the phrase
/// never appears as one string in the stream.
private func modernPageWords(_ doc: Document,
                             _ options: EmitOptions = EmitOptions()) -> [[String]] {
    let text = String(decoding: emitPDF(doc, mode: .modern, options: options),
                      as: UTF8.self)
    var pages: [[String]] = []
    for chunk in text.components(separatedBy: "endstream") {
        var words: [String] = []
        // M15 (2026-09-15): Modern draws WordStar's own automatic page number in the
        // bottom margin zone (y <= 44). These tests are about the MERGE variable in the
        // body, so that zone is skipped — otherwise every page's word list grows a
        // leading page number that has nothing to do with `&#&`.
        for line in chunk.components(separatedBy: "\n") {
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].range(of: ") Tj") else { continue }
            let fields = line.components(separatedBy: " ")
            if let tsIdx = fields.firstIndex(of: "Ts"), fields.count > tsIdx + 2,
               let y = Double(fields[tsIdx + 2]), y <= 44.0 { continue }
            words.append(String(line[line.index(after: open)..<close.lowerBound]))
        }
        if !words.isEmpty { pages.append(words) }
    }
    return pages
}

private func pageNumbersOff() -> EmitOptions {
    var o = EmitOptions()
    o.pageNumbers = .off
    return o
}

@Test(arguments: [EmitMode.printed, .modern])
func bothRTFModesSubstituteTheReadersOwnPageField(mode: EmitMode) {
    let body = rtfBody(mergeDocument("Count is &#& today.\r\n"), mode)
    #expect(body.contains(chpgn))
    #expect(!body.contains("&#"))
}

@Test(arguments: [EmitMode.printed, .modern])
func theSlashModifierFormSubstitutesInRTFToo(mode: EmitMode) {
    #expect(rtfBody(mergeDocument("Trick: &#/r& here.\r\n"), mode).contains(chpgn))
}

@Test(arguments: [EmitMode.printed, .modern])
func pageNumbersOffRemovesTheVariableFromRTF(mode: EmitMode) {
    // `off` REMOVES it rather than showing it as typed — with no number to show there is
    // nothing left for the variable to say, so it goes the way it goes on a page-less
    // surface.
    let body = rtfBody(mergeDocument("Count is &#& today.\r\n"), mode, pageNumbersOff())
    #expect(!body.contains(chpgn))
    #expect(!body.contains("&#"))
    #expect(body.contains("Count is  today."))
}

@Test(arguments: [EmitMode.printed, .modern])
func noOtherMergeVariableBecomesAFieldInRTF(mode: EmitMode) {
    let body = rtfBody(mergeDocument("Dear &NAME&, see &REF#& and &#COUNT&.\r\n"), mode)
    #expect(!body.contains(chpgn))
    #expect(body.contains("&NAME&"))
    #expect(body.contains("&REF#&"))
    #expect(body.contains("&#COUNT&"))
}

@Test(arguments: [EmitMode.printed, .modern])
func theMarkerNeverSurvivesIntoTheRTF(mode: EmitMode) {
    // A private-use code point in a delivered file would be a defect in its own right.
    let out = emitRTF(mergeDocument("Count is &#& today.\r\n"), mode: mode)
    #expect(!out.contains(mergePagenoMark))
}

@Test func modernPDFSubstitutesARealNumber() {
    #expect(modernPageWords(mergeDocument("Count is &#& today.\r\n"))[0]
            == ["Count", "is", "1", "today."])
}

@Test func modernPDFPageNumbersOffRemovesIt() {
    #expect(modernPageWords(mergeDocument("Count is &#& today.\r\n"), pageNumbersOff())[0]
            == ["Count", "is", "today."])
}

@Test func printedPDFPageNumbersOffRemovesIt() {
    let out = String(decoding: emitPDF(mergeDocument("Count is &#& today.\r\n"),
                                       mode: .printed, options: pageNumbersOff()),
                     as: UTF8.self)
    #expect(!out.contains("&#"))
    #expect(!out.contains("1 today"))
}

@Test func modernTakesEachOccurrencesOwnPage() {
    // Two occurrences either side of a forced break take two different numbers — the
    // measuring pass reads the page each one actually fell on, not the document's first.
    let pages = modernPageWords(mergeDocument(
        "Alpha with &#& in it.\r\n.pa\r\nBeta with &#& in it.\r\n"))
    #expect(pages[0] == ["Alpha", "with", "1", "in", "it."])
    #expect(pages[1] == ["Beta", "with", "2", "in", "it."])
}

@Test func modernNumbersItTheWayModernNumbersItsPages() {
    // NOT the printed answer, and that is deliberate. Modern's own page number is `.pn`'s
    // start value plus the page index (`modernStreams`' `startNo + pi`) — a `.pn` that
    // re-anchors MID-document has never reached Modern's running heads either, and this
    // variable is answered by the same number the rest of the Modern page shows, not by a
    // second, better paginator nothing else uses. A document that OPENS with `.pn` does
    // carry it.
    let pages = modernPageWords(mergeDocument(
        "First sheet with &#&.\r\n.pa\r\n.pn 10\r\nSecond sheet with &#&.\r\n"))
    #expect(pages[0] == ["First", "sheet", "with", "1."])
    #expect(pages[1] == ["Second", "sheet", "with", "2."])
    let opened = modernPageWords(mergeDocument(".pn 7\r\nSheet with &#&.\r\n"))
    #expect(opened[0] == ["Sheet", "with", "7."])
}

@Test func aDocumentWithoutTheVariableCostsNoMeasuringPass() {
    // The measuring pass is a whole extra Modern composition, so the necessary condition
    // that gates it has to be real: `-HOLYMAC.WS`, the speed benchmark, must not pay for
    // a feature it does not use.
    let d = mergeDocument("Ordinary prose with no variable.\r\n")
    let out = mergePagenoModern(d, options: EmitOptions())
    #expect(out.blocks.count == d.blocks.count)
    #expect(out.blocks.first?.lines.first?.spans.first?.text
            == d.blocks.first?.lines.first?.spans.first?.text)
}

@Test func theNonPagedFormatsAreUnchangedByAnyOfThis() {
    // HTML/Markdown/text still REMOVE it, and still do so whatever the page-number flag
    // says — they have no pages for the flag to govern.
    let d = mergeDocument("Count is &#& today.\r\n")
    for mode in [EmitMode.printed, .modern] {
        for pn in [EmitOptions.PageNumberMode.auto, .on, .off] {
            var o = EmitOptions()
            o.pageNumbers = pn
            for out in [emitText(d, mode: mode, options: o),
                        emitMarkdown(d, mode: mode, options: o),
                        emitHTML(d, mode: mode, options: o)] {
                #expect(!out.contains("&#"))
                #expect(!out.contains("chpgn"))
            }
        }
    }
}

// MARK: - the drift check (Sawyer archive)
//
// `mergePagenoModern` measures once and renders once, and substituting SHORTENS the
// text: in principle an occurrence sitting within a few characters of a page's last line
// could move up a page between the two compositions and then name the page it left. That
// is not iterated to a fixed point (one need not exist — a shorter line can pull the
// variable back, which lengthens it again); it is CHECKED, here, on every document in
// the archive that carries one.
//
// The check is exact rather than a spot assertion: if the measuring composition and the
// rendering composition put the same number of drawn words on every page, then they
// paginated identically, and every occurrence is on the page it was measured on.

private let mergePagenoDocs = ["REF/TOCTRICK.WS", "ARTICLES/POWERUSE.WS", "REF/CODES.WS"]

private func archiveDocument(_ name: String) throws -> Document {
    let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(name)
    return try parse([UInt8](try Data(contentsOf: url)))
}

/// The drawn-word count of every page of one Modern composition — the shape of the
/// pagination, independent of what the words say.
private func modernPageShape(_ doc: Document) -> [Int] {
    var noCells: [Int: [PageLine.GraphicCellPlacement]]? = nil
    return modernStreams(doc, options: EmitOptions(), res: FontResources(),
                         attachGraphicCells: &noCells)
        .map { stream in
            var n = 0
            var rest = Substring(String(decoding: stream, as: UTF8.self))
            while let open = rest.firstIndex(of: "("),
                  let close = rest[open...].range(of: ") Tj") {
                n += 1
                rest = rest[close.upperBound...]
            }
            return n
        }
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: mergePagenoDocs)
func modernMeasuringAndRenderingPaginateAlike(name: String) throws {
    let doc = try archiveDocument(name)
    // The MEASURING composition: the document exactly as `mergePagenoModern` first sees
    // it, variables still as typed. The RENDERING composition: the same document with the
    // numbers written in. Equal word counts on every page means the two paginated
    // identically, which means every occurrence is on the page it was measured on.
    let measured = modernPageShape(doc)
    let rendered = modernPageShape(mergePagenoModern(doc, options: EmitOptions()))
    #expect(measured == rendered, "\(name): \(measured) vs \(rendered)")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: mergePagenoDocs)
func noPagedExportOfARealDocumentStillShowsTheVariable(name: String) throws {
    let doc = try archiveDocument(name)
    for mode in [EmitMode.printed, .modern] {
        #expect(!emitRTF(doc, mode: mode).contains("&#"))
        let pdfText = String(decoding: emitPDF(doc, mode: mode), as: UTF8.self)
        #expect(!pdfText.contains("&#"))
    }
}
