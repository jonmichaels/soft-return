/// planning #264 R2 (Jon, 2026-09-14): "Yes add it" — A8 keep-with-next for `.cp`/`.cc`
/// in RTF, both engines.
///
/// WHAT WORDSTAR ASKED FOR. `.cp n` says "break to a new page unless at least n lines
/// still fit here"; `.cc n` says the same of a column. The author's purpose is never the
/// break itself: it is that the n lines AFTER the command arrive together — `.cp` exists
/// precisely so a heading is not stranded at the foot of a page.
///
/// WHAT RTF CAN SAY. Not "break here": R6 declined imposed page positions outright the
/// same morning, and a reader paginating with its own fonts and margins would fight one
/// anyway. It can say `\keepn` (keep this paragraph with the next) and `\keep` (do not
/// split this paragraph across a page) — CONSTRAINTS the reader honours while paginating
/// rather than positions imposed on it. That is the packet's own reason A8 works where
/// A12 does not.
///
/// BOTH MODES. The rule reads the same blocks either way, and a stranded heading is as
/// wrong in a reflowed export as in a facsimile.
///
/// Port of ctrl-kd's `tests/test_rtf_keep_with_next.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private func keepDocument(_ body: String) -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var bytes: [UInt8] = [0x1D]
    bytes += le
    bytes += [0x00, 0x70]
    bytes += [UInt8](repeating: 0, count: 15)
    bytes += le
    bytes += [0x1D]
    bytes += [UInt8](body.utf8)
    return parseWS(bytes)
}

/// Every keep control in document order, `\keep0`/`\keepn0` included.
private func keepControls(_ rtf: String) -> [String] {
    var out: [String] = []
    var rest = Substring(rtf)
    while let hit = rest.range(of: #"\keep"#) {
        var end = hit.upperBound
        if end < rest.endIndex, rest[end] == "n" { end = rest.index(after: end) }
        if end < rest.endIndex, rest[end] == "0" { end = rest.index(after: end) }
        if end < rest.endIndex, rest[end] == " " {
            out.append(String(rest[hit.lowerBound..<end]) + " ")
            rest = rest[rest.index(after: end)...]
        } else {
            rest = rest[hit.upperBound...]
        }
    }
    return out
}

private let headingAndTwo =
    ".cp 3\r\nA Heading\r\n\r\nBody line one.\r\nBody line two.\r\n"

@Test(arguments: [EmitMode.printed, .modern])
func cpKeepsTheHeadingWithWhatFollows(mode: EmitMode) {
    // The packet's own example: "Don't strand this heading".
    let rtf = emitRTF(keepDocument(headingAndTwo), mode: mode)
    #expect(Array(keepControls(rtf).prefix(2)) == [#"\keep "#, #"\keepn "#])
    #expect(rtf.range(of: #"\keepn "#)!.lowerBound < rtf.range(of: "A Heading")!.lowerBound)
}

@Test(arguments: [EmitMode.printed, .modern])
func theLastParagraphOfTheRunIsKeptButNotKeptWithNext(mode: EmitMode) {
    // `\keepn` on the last one would bind the run to text the author never asked for.
    let rtf = emitRTF(keepDocument(headingAndTwo), mode: mode)
    #expect(rtf.contains(#"\keepn0 "#))
    #expect(rtf.range(of: #"\keepn0 "#)!.lowerBound
            < rtf.range(of: "Body line one.")!.lowerBound)
}

@Test(arguments: [EmitMode.printed, .modern])
func theRunEndsAndThePropertiesAreTurnedBackOff(mode: EmitMode) {
    // `\keep`/`\keepn` persist across `\par` like every other paragraph property, so a
    // paragraph outside the run has to say so.
    let rtf = emitRTF(keepDocument(headingAndTwo + "\r\nUnrelated later prose.\r\n"),
                      mode: mode)
    #expect(rtf.contains(#"\keep0 "#))
    #expect(rtf.range(of: #"\keep0 "#)!.lowerBound
            < rtf.range(of: "Unrelated later prose.")!.lowerBound)
}

@Test(arguments: [EmitMode.printed, .modern])
func aDocumentWithNoCPWritesNoKeepControlAtAll(mode: EmitMode) {
    let rtf = emitRTF(keepDocument("Just prose.\r\nMore prose.\r\n"), mode: mode)
    #expect(keepControls(rtf).isEmpty)
}

@Test(arguments: [EmitMode.printed, .modern])
func ccIsReadExactlyAsCPIs(mode: EmitMode) {
    // WSFORMAT.TXT: "Like the .CP command, but works with columnar breaks instead." The
    // request is the same request.
    let cp = emitRTF(keepDocument(headingAndTwo), mode: mode)
    let cc = emitRTF(keepDocument(headingAndTwo.replacingOccurrences(of: ".cp 3",
                                                                    with: ".cc 3")),
                     mode: mode)
    #expect(keepControls(cp) == keepControls(cc))
}

@Test(arguments: [EmitMode.printed, .modern])
func aRunSatisfiedByOneParagraphIsKeptButNotBoundOnward(mode: EmitMode) {
    // The n lines the author asked for are already inside that one paragraph, so nothing
    // needs holding to what follows.
    let rtf = emitRTF(keepDocument(
        ".cp 2\r\nLine one.\r\nLine two.\r\n\r\nA separate paragraph.\r\n"), mode: mode)
    #expect(keepControls(rtf).first == #"\keep "#)
    #expect(!rtf.contains(#"\keepn "#))
}

@Test(arguments: [EmitMode.printed, .modern])
func aBiggerNReachesFurtherDownTheDocument(mode: EmitMode) {
    // `.cp 6` over three one-line paragraphs holds all three.
    let rtf = emitRTF(keepDocument(
        ".cp 6\r\nOne.\r\n\r\nTwo.\r\n\r\nThree.\r\n\r\nFour.\r\n"), mode: mode)
    #expect(keepControls(rtf).filter { $0 == #"\keepn "# }.count == 1)
    #expect(keepControls(rtf).filter { $0 == #"\keepn0 "# }.count == 1)
}

@Test(arguments: [EmitMode.printed, .modern])
func aPageBreakEndsTheRun(mode: EmitMode) {
    // `.cp` cannot ask for lines that are on the other side of a break the author put
    // there himself.
    let rtf = emitRTF(keepDocument(".cp 9\r\nOne.\r\n.pa\r\nTwo.\r\n"), mode: mode)
    #expect(!rtf.contains(#"\keepn "#))
    #expect(rtf.contains(#"\keep "#))
}

@Test func thePlanNamesExactlyTheBlocksItHolds() {
    // The unit under the export, so the mapping can be read directly.
    let plan = rtfKeepPlan(keepDocument(headingAndTwo))
    let kept = plan.keys.sorted()
    #expect(kept.map { plan[$0]!.keep } == [true, true])
    #expect(kept.map { plan[$0]!.keepn } == [true, false])
}
