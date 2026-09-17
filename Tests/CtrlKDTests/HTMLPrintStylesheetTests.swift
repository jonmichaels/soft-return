/// planning #264 R5 (Jon, 2026-09-14): "Fine. Add it." — C6, the HTML print stylesheet:
/// `@page` with the document's own paper size and margins, `break-after: page` at its own
/// page breaks, `break-inside: avoid` for the blocks `.cp`/`.cc` asked to hold together.
///
/// THIS DOES NOT GIVE HTML PAGES, and that is the point. The 2026-08-17 doctrine stands —
/// HTML has no pages on screen or anywhere else — and nothing here changes what a browser
/// SHOWS. What it changes is what comes out of a printer when someone hits Print on the
/// page: until now the sheet was the browser's default paper at the browser's default
/// margins, and the breaks fell wherever the browser felt like putting them.
///
/// PRINTED ONLY. Modern has no pages in any surface, so a Modern HTML export carries no
/// `@page` and no break rules at all. (A printstream, and any document `isPrinted()`
/// resolves as printed, is printed in BOTH modes — that is not an exception to this rule,
/// it is the rule.)
///
/// ON-SCREEN RENDERING IS UNCHANGED, and this file PROVES it rather than asserting it:
/// every rule lives inside one `@media print` block appended last, so the stylesheet
/// above it is byte-for-byte what it was, and no rule outside that block names the two
/// new classes.
///
/// Port of ctrl-kd's `tests/test_html_print_stylesheet.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private func printCSSDocument(_ body: String, dots: String = "") -> Document {
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

private func styleSheet(_ html: String) -> String {
    let open = html.range(of: "<style>")!
    let close = html.range(of: "</style>")!
    return String(html[open.upperBound..<close.lowerBound])
}

/// The stylesheet with the `@media print` block removed — what a browser uses to draw the
/// page.
private func screenCSS(_ html: String) -> String {
    let css = styleSheet(html)
    guard let at = css.range(of: "\n@media print{") else { return css }
    return String(css[css.startIndex..<at.lowerBound])
}

private func printBlock(_ html: String) -> String {
    let css = styleSheet(html)
    guard let at = css.range(of: "@media print{") else { return "" }
    return String(css[at.lowerBound...])
}

private let printBody =
    ".cp 3\r\nA Heading\r\n\r\nBody one.\r\n.pa\r\nPage two.\r\n"

// MARK: - @page

@Test func theSheetIsTheDocumentsOwnPaperAndMargins() {
    // `.pl`'s resolved height and the page model's width; `.mt`/`.mb` at 6 LPI and `.po`
    // at 10 CPI — the identical numbers the RTF page setup writes as twips.
    let html = emitHTML(printCSSDocument("Text.\r\n"), mode: .printed)
    #expect(printBlock(html).contains(
        "@page{size:8.5in 11in;margin:0.5in 0.8in 1.33333in 0.8in}"))
}

@Test func theDocumentsOwnMarginsReachTheRule() {
    let doc = printCSSDocument("Text.\r\n", dots: ".mt 6\r\n.mb 12\r\n.po 12\r\n")
    #expect(printBlock(emitHTML(doc, mode: .printed)).contains(
        "@page{size:8.5in 11in;margin:1in 1.2in 2in 1.2in}"))
}

@Test func sixSignificantDigitsIsWhatPythonWrites() {
    // `%g`, not `%.6f`: five sixths of an inch is `0.833333` (six significant digits past
    // the leading zero) and eight sixths is `1.33333` (six from the leading 1).
    #expect(cssInches(0.5) == "0.5")
    #expect(cssInches(11.0) == "11")
    #expect(cssInches(8.5) == "8.5")
    #expect(cssInches(8.0 / 6.0) == "1.33333")
    #expect(cssInches(5.0 / 6.0) == "0.833333")
    #expect(cssInches(1.2) == "1.2")
}

/// Planning #264 item 4(c), Jon's own framing of it (the browser check's section 3,
/// 2026-09-14): Modern has no pages and this gives it none. What it gives is the SHEET
/// — until now a reader hitting Print on a Modern page got the browser's default paper
/// at the browser's default margins, which for a document that declares its own is
/// simply wrong information.
///
/// So: `@page`, and nothing that decides where a sheet ENDS. No `hr.pb` break, no
/// `.ws-keep`, no `break-after` of any kind. The stylesheet says so in its own comment,
/// so a reader of the CSS meets the decision rather than an omission.
@Test func modernStatesThePaperAndDecidesNothingElse() {
    let html = emitHTML(printCSSDocument(printBody), mode: .modern)
    let block = printBlock(html)
    #expect(block.contains("@page{size:8.5in 11in;margin:0.5in 0.8in 1.33333in 0.8in}"))
    #expect(block.contains("No page breaks, by design"))
    #expect(!block.contains("break-after"))
    #expect(!block.contains("break-inside"))
    #expect(!block.contains("hr.pb"))
    #expect(!block.contains("ws-keep"))
    // and nothing about paper leaks into the SCREEN stylesheet
    if let at = html.range(of: "@media print") {
        #expect(!html[html.startIndex..<at.lowerBound].contains("@page"))
    }
}

// MARK: - page breaks

@Test func aPageBreakBecomesARealOneInPrint() {
    let block = printBlock(emitHTML(printCSSDocument(printBody), mode: .printed))
    #expect(block.contains("hr.pb{break-after:page;border:none;margin:0;height:0}"))
}

@Test func theDashedRuleIsStillTheScreensOwnMarker() {
    // The `<hr class="pb">` element and its SCREEN rule are untouched — the print rule
    // only stops it drawing on paper.
    let html = emitHTML(printCSSDocument(printBody), mode: .printed)
    #expect(html.contains("<hr class=\"pb\">"))
    #expect(screenCSS(html).contains("hr.pb{border:none;border-top:1px dashed #bbb;margin:2rem 0}"))
}

@Test func aDocumentWithNoBreakGetsNoBreakRule() {
    let block = printBlock(emitHTML(printCSSDocument("Text.\r\n"), mode: .printed))
    #expect(block.contains("@page"))
    #expect(!block.contains("hr.pb"))
}

// MARK: - keeps

@Test func theCPRunIsMarkedAndKept() {
    let html = emitHTML(printCSSDocument(printBody), mode: .printed)
    #expect(html.contains("ws-keep"))
    let block = printBlock(html)
    #expect(block.contains(".ws-keep{break-inside:avoid}"))
    #expect(block.contains(".ws-keepn{break-after:avoid}"))
}

@Test func theClassesNameExactlyTheBlocksR2Names() {
    // Read from R2's OWN plan, so the RTF and the printed HTML cannot disagree about
    // which paragraphs a `.cp` holds.
    let doc = printCSSDocument(printBody)
    let plan = rtfKeepPlan(doc)
    let html = emitHTML(doc, mode: .printed)
    var keeps = 0
    var keepns = 0
    var rest = Substring(html)
    while let open = rest.range(of: "<p class=\"") {
        rest = rest[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { break }
        let classes = rest[rest.startIndex..<close]
        if classes.contains("ws-keep") { keeps += 1 }
        if classes.contains("ws-keepn") { keepns += 1 }
        rest = rest[close...]
    }
    #expect(keeps == plan.count)
    #expect(keepns == plan.values.filter(\.keepn).count)
}

@Test func modernNeverCarriesTheKeepClasses() {
    #expect(!emitHTML(printCSSDocument(printBody), mode: .modern).contains("ws-keep"))
}

@Test func aDocumentWithNoCPGetsNoKeepRules() {
    let block = printBlock(emitHTML(printCSSDocument("Text.\r\n.pa\r\nMore.\r\n"),
                                    mode: .printed))
    #expect(!block.contains("ws-keep"))
}

// MARK: - the screen is untouched

@Test(arguments: [EmitMode.printed, .modern])
func theScreenStylesheetIsByteIdenticalToTheBase(mode: EmitMode) {
    // The proof the ruling asked for: strip `@media print` and what is left is exactly
    // the stylesheet that was there before — so nothing a browser renders can have moved.
    //
    // E9 H4 (2026-09-17) added ONE thing to the screen side, and only in Modern: the
    // reading measure (`modernMeasureCSS`). Printed's screen stylesheet is still the
    // base, byte for byte, which is the half of this claim the print round made.
    let html = emitHTML(printCSSDocument(printBody), mode: mode)
    #expect(screenCSS(html) == htmlCSS + (mode == .printed ? "" : modernMeasureCSS))
}

@Test func noScreenRuleEverNamesTheNewClasses() {
    // A class a screen rule matched would be a rendering change smuggled in as markup.
    for mode in [EmitMode.printed, .modern] {
        let screen = screenCSS(emitHTML(printCSSDocument(printBody), mode: mode))
        #expect(!screen.contains("ws-keep"))
        #expect(!screen.contains("@page"))
        #expect(!screen.contains("break-after"))
        #expect(!screen.contains("break-inside"))
    }
}

@Test func thePrintBlockIsTheLastThingInTheStylesheet() {
    let css = styleSheet(emitHTML(printCSSDocument(printBody), mode: .printed))
    #expect(css.hasSuffix("}"))
    #expect(css.components(separatedBy: "@media print{").count - 1 == 1)
    #expect(css.range(of: "@media print{")!.lowerBound
            > css.range(of: "hr.pb{border:none", options: .backwards)!.lowerBound)
}
