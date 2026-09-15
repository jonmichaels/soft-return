/// Port of ctrl-kd's `tests/test_zero_width_tab.py` (triage Q10).
///
/// A tab whose stop the pen has already reached is ZERO columns wide. Measured on
/// `sawyer/REF/FONT-TAG.CMP` against its real WS7 LaserJet capture (ws7-prints/v4, page
/// 1): the document types `Bit #:`, a type-9 tab block, then `Usage:`. The tab's
/// absolute stop is 273.6pt from the page's left edge, which is exactly where `Bit #:`
/// already ends, and its own width word says 28 HMI -- under a sixth of a 10-CPI column.
/// Real WS7 prints `Bit #:Usage:` with nothing between them (`Bit` at 230.4pt,
/// `#:Usage:` at 259.2pt, one continuous run).
///
/// This engine spent a placeholder column anyway -- a `max(1, ...)` floor in
/// `tabColumns`, and a one-space-wide nudge in the printed PDF's own overrun branch --
/// so `Usage:` printed 7.2pt right of where WordStar puts it, on every surface at once:
/// printed, layout, RTF, HTML, plain text.
///
/// The other half of the same mechanism, and the reason zero columns is not simply "drop
/// the tab": a zero-column tab is still a POSITIONING instruction. `sawyer/MICKEE/
/// MICKEE.WS` page 23 opens a line with a 90-HMI tab -- half a 10-CPI column, so no
/// whole column at all -- and real WS7 starts that line at 10.8pt where the margin alone
/// would put it at 7.2pt. The span carrying the stop has no characters now, so the
/// printed renderer has to keep it rather than drop it with the other empty runs.
import Testing
@testable import CtrlKD

private func tabBlock(size: Int, absHMI: Int, type: UInt8 = 0x20) -> [UInt8] {
    ws7Block(0x09, payload: [UInt8(size & 0xFF), UInt8(size >> 8),
                             UInt8(absHMI & 0xFF), UInt8(absHMI >> 8),
                             type, 0xFF])
}

private func doc(_ body: [UInt8]) -> Document {
    parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body)
}

/// The `Td` x immediately preceding `(word` in the PDF -- copied from
/// `BareTabModulus8Tests.swift`'s own helper, per this repo's "copy, don't import"
/// test-helper convention.
private func firstX(_ pdf: [UInt8], _ word: String) -> Double? {
    let needle = "(\(word)"
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

private let hardBreak: [UInt8] = [0x0d, 0x0a]

// ------------------------------------------------------------------------ the width

@Test func aTabThePenHasAlreadyReachedIsZeroColumns() throws {
    // FONT-TAG.CMP's own block, byte for byte: 28 HMI of width, which is no whole
    // 10-CPI column (180 HMI) at all. `tabColumns` is file-private, so this is checked
    // through what it produces -- the decoded run.
    var src = bytes("Bit #:")
    src += tabBlock(size: 28, absHMI: 5040)
    src += bytes("Usage:")
    src += hardBreak
    let d = doc(src)
    #expect(d.blocks[0].lines[0].text() == "Bit #:Usage:", "\(d.blocks[0].lines[0].text())")
}

@Test func anOrdinaryTabStillMeasuresItsOwnColumns() throws {
    // The floor is gone, not the arithmetic: a real 3-column tab is still three columns.
    var src = bytes("a")
    src += tabBlock(size: 540, absHMI: 5040)
    src += bytes("b")
    src += hardBreak
    let d = doc(src)
    #expect(d.blocks[0].lines[0].text() == "a   b", "\(d.blocks[0].lines[0].text())")
}

// ------------------------------------------------------------- the positioning half

@Test func aZeroWidthTabStillSetsThePrintedPen() throws {
    // MICKEE.WS page 23's shape: a leading tab of 90 HMI -- half a column, so zero whole
    // columns -- whose absolute stop is still 3.6pt in from the margin. WS7 starts the
    // line there, not at the margin, so the empty span carrying the stop must survive
    // into the printed page.
    var tabbedSrc = tabBlock(size: 90, absHMI: 90)
    tabbedSrc += bytes("Spell,")
    tabbedSrc += hardBreak
    var plainSrc = bytes("Spell,")
    plainSrc += hardBreak
    let tabbed = emitPDF(doc(tabbedSrc), mode: .printed)
    let plain = emitPDF(doc(plainSrc), mode: .printed)
    let a = try #require(firstX(tabbed, "Spell,"))
    let b = try #require(firstX(plain, "Spell,"))
    #expect((a - b - 3.6).magnitude < 0.05, "\(a) vs \(b)")
}
