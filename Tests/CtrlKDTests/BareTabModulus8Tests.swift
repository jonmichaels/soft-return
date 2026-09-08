/// Port of ctrl-kd's `tests/test_bare_tab_modulus8.py` (planning #202 batch AND planning
/// #244, the round-trip gauntlet fix that moved the expansion out of `decodeSpans`).
///
/// WS7's own file-format reference (WSFORMAT.WS control-code table, byte 09h ^I) states
/// the rule in one sentence -- "At print time the number of hard spaces required to
/// reach a modulus 8 print position is generated" -- and this engine once rendered a
/// bare 0x09 with ZERO width, gluing the word before it to the word after. VERIFIED
/// against WS7's own real LaserJet PCL capture the same way the Python port was: "00h
/// ^@<TAB>Fix" -- 6 characters before the tab -- places "Fix" at exactly column 8.
///
/// THE SPLIT (planning #244, 2026-09-08): the FIRST fix (planning #202 batch) baked this
/// expansion into `decodeSpans` at PARSE time, which turned every computed space into
/// something byte-indistinguishable from a space the author actually typed --
/// `emitWS`'s round-trip (`WriterTests`'s corpus gauntlet) re-emitted spaces instead of
/// the source file's own 0x09 byte and never reproduced `sawyer/MACROS/HOLYMAC/-HOLYMAC
/// .WS`, `sawyer/REF/WINDOWS7.WS`, or `sawyer/REF/wordstar-file-format.ws` (found
/// 2026-09-08 by the census). `decodeSpans` now keeps the literal 0x09 byte again (its
/// pre-#237 form -- the document model IS the source bytes, unexpanded);
/// `expandBareTabsForPrintedLayout` (PDFWriter.swift) applies the SAME modulus-8 rule
/// instead, at PRINTED-mode render time only, on a transient copy of the segment text
/// that never touches the stored Span. Every OTHER mode (text, markdown, html, rtf, and
/// Modern PDF) sees the bare, un-expanded tab byte now -- exactly its own pre-#237
/// behavior, since #237's own evidence (the WS7 LaserJet PCL capture above) was
/// Printed-PDF-only despite living in a function every mode shared.
import Testing
@testable import CtrlKD

/// `WriterTests.swift`'s own `ws5Seed` is file-private -- a local copy, same bytes.
private let ws5SeedLocal = ws7Block(0x0B, payload: [0, 0, 0, 0])

/// The full Tj operand string of the first drawn text object CONTAINING `substring`, or
/// `nil`. A plain, single-styled fixed-pitch printed line draws as ONE whole-line Tj
/// (this file's own bare-tab lines included -- no styled span to split it, same as any
/// other unjustified single-span line, see `JustificationTests.ojOffIsUnaffected` for
/// the sibling finding), so the expansion is checked directly in the drawn STRING.
private func drawnLine(_ pdf: [UInt8], containing substring: String) -> String? {
    let text = latin1(pdf)
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.contains(" Td ("), let openParen = line.firstIndex(of: "(") else { continue }
        guard let close = line.range(of: ") Tj") else { continue }
        let candidate = String(line[line.index(after: openParen)..<close.lowerBound])
        if candidate.contains(substring) { return candidate }
    }
    return nil
}

private func printedPDF(_ src: [UInt8]) -> [UInt8] {
    emitPDF(parseWS(bytes(".po 0\"\r\n.lm 0\r\n") + src), mode: .printed)
}

/// The `Td` x immediately preceding `(word) Tj` in the PDF, or `nil` if the word never
/// appears as its own Tj operand -- copied from `JustificationTests.swift`'s own helper
/// (file-private there too), per this repo's "copy, don't import" test-helper
/// convention.
private func wordX(_ pdf: [UInt8], _ word: String) -> Double? {
    let needle = "(\(word)) Tj"
    for line in latin1(pdf).split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: needle) else { continue }
        let prefix = line[line.startIndex..<r.lowerBound]
        guard prefix.hasSuffix("Td ") else { continue }
        let fields = prefix.dropLast(3).split(separator: " ")
        guard fields.count >= 2 else { continue }
        return Double(fields[fields.count - 2])
    }
    return nil
}

// ------------------------------------------------- decodeSpans: keeps the literal byte

@Test func decodeSpansKeepsTheLiteralTabByte() throws {
    let doc = parseWS(bytes("00h ^@\tFix"))
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains("\t"), "\(text)")
}

@Test func aTbRulerType9TabBlockIsUnaffected() throws {
    // decodeSpans's own note (the 0x09 branch's neighbour): 46 archive files use `.tb`
    // and ZERO contain a bare 0x09 -- the two mechanisms never coexist, and a type-9
    // tab block's own padding bytes never reach the bare-0x09 branch at all.
    let tab = ws7Block(0x09, payload: [0x68, 0x01, 0x68, 0x01] + bytes(" ") + [0x02])
    let doc = parseWS(ws5SeedLocal + tab + bytes("indented text") + HARD + [0x1A])
    let text = doc.blocks[0].lines[0].text()
    #expect(!text.contains("\t"), "\(text)")
}

// --------------------------------------- Printed-PDF layout-time expansion

@Test func bareTabAfterSixColumnsReachesTheNextModulus8StopInPrintedPDF() throws {
    // The exact WS7-verified case: 6 characters before the tab ("00h ^@"), landing on
    // column 8 -- 2 hard spaces, not zero. Fontless (no font block), so `spanPitch`
    // falls back to the 12pt-default 7.2pt/char grid -- exact arithmetic.
    let pdf = printedPDF(bytes("00h ^@\tFix.") + HARD)
    #expect(drawnLine(pdf, containing: "Fix.") == "00h ^@  Fix.")
}

@Test func bareTabAtLineStartExpandsToAFullStopInPrintedPDF() throws {
    // A tab at column 0 is still "not yet at a stop" by the standard tab convention (a
    // tab always advances at least one column) -- it must reach column 8, a full 8
    // hard spaces, not 0.
    let pdf = printedPDF(bytes("\tWord.") + HARD)
    #expect(drawnLine(pdf, containing: "Word.") == String(repeating: " ", count: 8) + "Word.")
}

@Test func bareTabExactlyOnAStopStillAdvancesAFull8InPrintedPDF() throws {
    // 8 characters before the tab -- already sitting on a modulus-8 print position.
    // WordStar's own rule ("hard spaces required to REACH a modulus 8 position") still
    // means the next one, not zero -- the only reading consistent with the line-start
    // case above.
    let pdf = printedPDF(bytes("12345678\tWord.") + HARD)
    #expect(drawnLine(pdf, containing: "Word.")
            == "12345678" + String(repeating: " ", count: 8) + "Word.")
}

@Test func bareTabColumnCountResetsAtTheNextPhysicalLineInPrintedPDF() throws {
    // Printed mode renders physical lines verbatim, never rewrapped, and
    // `expandBareTabsForPrintedLayout` runs once per `lineOpsPrinted` call (one
    // physical line) -- a short second line must not inherit the column count from the
    // line before it. Without the reset, line two's own running count would start at
    // line one's ending column (16, not 0), and "ab" + a tab from there lands on
    // column 24, not 8 -- different trailing words ("WordOne."/"WordTwo.") disambiguate
    // `drawnLine`, which returns the FIRST matching Tj containing the needle.
    let pdf = printedPDF(bytes("\tWordOne.") + HARD + bytes("ab\tWordTwo.") + HARD)
    #expect(drawnLine(pdf, containing: "WordOne.") == String(repeating: " ", count: 8) + "WordOne.")
    #expect(drawnLine(pdf, containing: "WordTwo.") == "ab" + String(repeating: " ", count: 6) + "WordTwo.")
}

@Test func ojOffDefaultTextModeKeepsTheBareTabLiteral() throws {
    // Every mode OTHER than Printed PDF sees the raw, un-expanded byte -- the pre-#237
    // behavior, now deliberately restored rather than accidentally shared.
    let doc = parseWS(bytes("From:\tWordStar") + HARD)
    let out = emitText(doc, mode: .printed)
    #expect(out.contains("\t"), "\(out)")
}

@Test func aStyledMixedLineWithABareTabIsStillDrawnCorrectly() throws {
    // A line resolving to more than one styled span still reaches
    // `expandBareTabsForPrintedLayout` (it runs on the RAW segs, ahead of the split
    // that later decides eligibility for other per-line features like planning #238's
    // justification) -- the tab expands the same way regardless of how many styles
    // surround it. "AB" (2 chars, plain) + tab (needed=6, to column 8) + "CD" (bold) +
    // "EF." (plain) -- "EF." lands at column 10 (8 + 2 for "CD").
    let pdf = printedPDF(bytes("AB") + [0x02] + bytes("\tCD") + [0x02] + bytes("EF.") + HARD)
    let x = try #require(wordX(pdf, "EF."))
    #expect(x == 10 * 7.2, "\(x)")
}
