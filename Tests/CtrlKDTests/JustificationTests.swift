import Testing
@testable import CtrlKD

/// Planning #238: `.oj on` full justification in Printed mode — Swift port of ctrl-kd's
/// `tests/test_justification.py` (aeb34ad/7276894), same 6 synthetic byte-exact cases.
///
/// Rule (measured against real WS7 captures — full writeup, before/after numbers, and
/// the open sub-decipoint question: the maintainer's own private research notes,
/// `2026-09-08_justification-rule.md`, WordStar research vault — PRIVATE corpus
/// paths/findings stay out of even this private repo's tests, only the RULE and
/// synthetic fixtures do, same doctrine ctrl-kd's own port note states):
///
///   1. Every line of a `.oj on` (`align == .justify`) paragraph EXCEPT ITS OWN LAST
///      physical line is stretched so its last character lands exactly on the block's
///      resolved right margin (`.rm`, in print columns, measured from the same `.po`
///      origin as the left edge). The last line of the paragraph is left ragged.
///   2. Only single-blank inter-word gaps are stretched — a run of 2+ literal blanks is
///      left at its natural width. The line's total slack is split EVENLY across the
///      single-blank gaps — a documented APPROXIMATION (see `lineOpsPrinted`'s own doc
///      comment): WS7's own real per-gap split is not perfectly flat even when the
///      total divides evenly.
///   3. Only a line that resolves to exactly ONE styled span is justified — a
///      styled/mixed line is left unjustified this pass.
///   4. Only a FIXED-PITCH span is justified — no evidenced proportional-font `.oj on`
///      capture was found in the corpus this pass.
///   5. Modern mode is untouched.
///
/// Fixed-pitch WS4-shaped fontless documents throughout (no font block — `spanPitch`
/// falls back to `pt * 0.6` = 7.2pt/char at the 12pt default), so every width below is
/// exact arithmetic, not a font-metric approximation — same construction Python's own
/// fixture set uses.

/// The `Td` x immediately preceding `(word) Tj` in the emitted PDF's own content
/// streams, or `nil` if the word never appears as its own Tj operand — Swift's content
/// streams are never Flate-compressed (unlike ctrl-kd's, see `HorizontalVectorTests
/// .pdfOpsTriples`), so no decompression step is needed here. Port of Python's
/// `_word_x`.
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

private func justifyDoc(_ src: [UInt8]) -> Document {
    parseWS(bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n") + src)
}

/// `.po 0"` / `.lm 0` / `.rm 20` (144pt) -- "AA BB CC" is 8 chars (57.6pt) natural, 2
/// single-blank gaps, needing 86.4pt of slack split evenly (43.2pt/gap, `base` below):
/// AA@0, BB@AA(14.4)+gap(7.2+43.2)=64.8, CC@BB_end(64.8+14.4)+gap(7.2+43.2)=129.6,
/// ending at 129.6+14.4=144.0 -- the one confirmed-solid part of the rule (every
/// justified line in the corpus lands its last character exactly on the margin); the
/// per-gap SPLIT that gets it there is this pass's own documented approximation (rule
/// 2 above), not a WS7 byte-for-byte match.
@Test func justifiedLineReachesTheResolvedRightMargin() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB CC") + SOFT + bytes("DD.") + HARD)
    let b = doc.blocks[0]
    #expect(b.align == .justify)
    #expect(b.lines.count == 2)
    let pdf = emitPDF(doc, mode: .printed)
    let xAA = try #require(wordX(pdf, "AA"))
    let xBB = try #require(wordX(pdf, "BB"))
    let xCC = try #require(wordX(pdf, "CC"))
    #expect(xAA == 0.0)
    let base = (144.0 - 8 * 7.2) / 2       // 43.2pt of slack per elastic gap
    let xBBExpected = 2 * 7.2 + (7.2 + base)
    let xCCExpected = xBBExpected + 2 * 7.2 + (7.2 + base)
    #expect(xBB == (xBBExpected * 10).rounded() / 10)
    #expect(xCC == (xCCExpected * 10).rounded() / 10)
    // The confirmed-solid part of the rule: CC's own right edge lands exactly on the
    // margin, not just "somewhere further right".
    #expect(xCC + 2 * 7.2 == 144.0)
}

/// WS7 never justifies a paragraph's own trailing line (measured directly against a
/// real WS7 capture, per this file's own header) -- "DD." here is the second (last)
/// physical line of the SAME block and must render at its natural, un-stretched
/// position.
@Test func lastLineOfJustifiedParagraphIsNotStretched() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB CC") + SOFT + bytes("DD.") + HARD)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(wordX(pdf, "DD.") == 0.0)
}

/// `.rm` chosen so the SINGLE-blank gap (AA-BB) and the DOUBLE-blank gap (BB-CC, an
/// author's own end-of-sentence spacing) are both present on the one physical line --
/// only the single-blank gap should carry any of the line's slack; the double stays at
/// its natural 2*7.2=14.4pt.
@Test func multiSpaceGapIsNotStretchedSingleSpaceGapsAbsorbIt() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB  CC") + SOFT + bytes("DD.") + HARD)
    let b = doc.blocks[0]
    #expect(b.lines[0].text() == "AA BB  CC")
    let pdf = emitPDF(doc, mode: .printed)
    let xAA = try #require(wordX(pdf, "AA"))
    let xBB = try #require(wordX(pdf, "BB"))
    let xCC = try #require(wordX(pdf, "CC"))
    #expect(xAA == 0.0)
    // BB's own gap (AA-BB, single blank) carries ALL the line's slack -- the only
    // elastic gap on this line.
    let naturalTotal = 9.0 * 7.2      // "AA BB  CC" = 9 chars
    let stretch = 144.0 - naturalTotal
    let xBBExpected = 2 * 7.2 + 7.2 + stretch
    #expect(xBB == (xBBExpected * 10).rounded() / 10)
    // BB-CC stays at its natural DOUBLE-blank width -- not stretched.
    let xCCExpected = xBB + 2 * 7.2 + 2 * 7.2
    #expect(xCC == (xCCExpected * 10).rounded() / 10)
    #expect(xCC + 2 * 7.2 == 144.0)
}

/// The default (no `.oj on` anywhere) must render exactly as it did before this
/// feature existed: one whole-line Tj (`justifyEligible` never fires, so the line is
/// never split into per-word pieces), the line's own single, exact, un-stretched text.
@Test func ojOffIsUnaffected() throws {
    let doc = justifyDoc(bytes("AA BB CC") + SOFT + bytes("DD.") + HARD)
    #expect(doc.blocks[0].align == .left)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(wordX(pdf, "AA BB CC") == 0.0)
    #expect(wordX(pdf, "BB") == nil)     // never its OWN Tj -- not split
}

@Test func ojOnThenOffMidDocumentOnlyJustifiesTheOnBlock() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB CC") + SOFT + bytes("DD.") + HARD
        + bytes(".oj off\r\n") + bytes("EE FF GG") + SOFT + bytes("HH.") + HARD)
    #expect(doc.blocks.map { $0.align } == [.justify, .left])
    let pdf = emitPDF(doc, mode: .printed)
    let xBB = try #require(wordX(pdf, "BB"))       // justified block -- split, stretched
    #expect(xBB > 2 * 7.2 + 7.2)
    #expect(wordX(pdf, "EE FF GG") == 0.0)          // .oj off block -- one whole-line Tj
    #expect(wordX(pdf, "FF") == nil)                // never split into pieces
}

/// A line that carries more than one styled span (a bold word mid-sentence) resolves
/// to more than one seg -- out of this pass's scope (rule 3 above) -- so it renders at
/// its natural width rather than guessing how to split the slack among several spans.
@Test func styledMixedLineIsLeftUnjustifiedDocumentedScope() throws {
    let bold: [UInt8] = [0x02]
    let doc = parseWS(bytes(".po 0\"\r\n.lm 0\r\n.rm 40\r\n.oj on\r\n")
        + bytes("AA ") + bold + bytes("BB") + bold + bytes(" CC") + HARD)
    let b = doc.blocks[0]
    #expect(b.align == .justify)
    #expect(b.lines[0].spans.count > 1)
    let pdf = emitPDF(doc, mode: .printed)
    let xBB = try #require(wordX(pdf, "BB"))
    #expect(xBB == 2 * 7.2 + 7.2)     // natural, not stretched to the 40-col margin
}
