/// M16 (2026-09-15): WHERE A RUNNING HEAD'S LINES GO.
///
/// Jon, reviewing sawyer/REF/BOOKLET.WS: "REF/BOOKLET.WS seems broken. Native and
/// Printed show very different things. I don't think Printed is showing the right-hand
/// header in the correct spot, but I can't easily check it against the WordStar output."
///
/// Checked against the WordStar output. Real WS7 prints that document's two header lines
/// — `.h1 Header Odd #` and `.h2 Header Even #` — on ONE row at y = 0.57in, "Header Even
/// 1" starting at x = 0.20in and "Header Odd 1" at x = 9.21in on an 11in landscape
/// sheet. The engine stacked them on two rows and put "Header Odd 1" 3.71in in.
///
/// SIX PROBES, printed by real WordStar 7 under DOSBox-X against the pristine
/// `PRISTINE.EXE` install, each one byte-editing a scratch copy of the document so the
/// file length (and therefore its style-library pointer) never moves. Both engines
/// reproduce all six exactly; the numbers are recorded in
/// `vault WordStar/research/2026-09-15_booklet-heads-under-columns.md`.
///
///   B0  the document as it stands — reproduces the `ws7-prints/v4` capture exactly.
///   B1  `.lh 0` commented out, columns left alone -> TWO rows, 0.40 and 0.57, the x
///       values unchanged. The columns do not collapse the lines.
///   B2  the `.co 2` commented out, `.lh 0` left alone -> ONE row, x unchanged. The line
///       height does collapse them, and the x is not the column grid's doing.
///   B3  `.co 3` with `.rm 2.50"` instead of `.co 2` with `.rm 4.50"` -> the heads do
///       not move. The x is not `.rm`'s doing.
///   B4  `.po` 0.2in -> 1.2in -> both heads move by exactly 1.00in.
///   B5  `.h2` commented out -> the one head line prints at 0.57in, the row the SECOND
///       of two occupies. The block is anchored on its last line.
///
/// THE TWO RULES, zero counter-examples in 308 WS7 captures and 6 probes:
///
///   1. A right- or centre-aligned head/foot line aligns against `.po` plus ITS OWN
///      STYLE's right margin. BOOKLET.WS's "Header Odd" style declares 18000 HMI = 100
///      columns = 10.00in. Every other corpus document with an aligned head declares a
///      style right margin equal to its own `.rm`, which is why reading `.rm` was right
///      everywhere else.
///   2. The step between head lines is the `.lh` in force at each line's own command —
///      1/6in by default, 0 when the document says `.lh 0`.
///
/// Port of ctrl-kd's `tests/test_head_foot_placement_m16.py`.
import Foundation
import Testing
@testable import CtrlKD

/// The two fields these helpers read, on an otherwise empty document.
private func m16Document(styleRM: [Int: Double] = [:],
                         leads: [Int: Double] = [:]) -> Document {
    var doc = Document(blocks: [])
    doc.headerStyleRM = styleRM
    doc.headerLeads = leads
    return doc
}

// MARK: - the arithmetic

@Test func aLineWithNoStyleRightMarginKeepsTheDocumentsOwnEdge() {
    #expect(hfLineRight(m16Document(), kind: .header, line: 1,
                        left: 14.4, docRight: 338.4) == 338.4)
}

@Test func aStyleRightMarginIsMeasuredFromThisPagesPo() {
    // BOOKLET.WS's own numbers: `.po` 0.2in (14.4pt) + 100 columns.
    let doc = m16Document(styleRM: [1: 100.0])
    let got = hfLineRight(doc, kind: .header, line: 1, left: 14.4, docRight: 338.4)
    #expect(got == 14.4 + 100.0 * pdfPtPerCol)
    #expect(got == 734.4)
}

@Test func theStepDefaultsToWordStarsOwnSixthOfAnInch() {
    #expect(hfLineStepPt(m16Document(), kind: .header, line: 1) == 12.0)
}

@Test func aZeroLineHeightIsAZeroStep() {
    #expect(hfLineStepPt(m16Document(leads: [1: 0.0]), kind: .header, line: 1) == 0.0)
}

@Test func aDeclaredLineHeightIsTheStep() {
    // `.lh12` is 12/48in = 18pt.
    #expect(hfLineStepPt(m16Document(leads: [1: 12.0]), kind: .header, line: 1) == 18.0)
}

// MARK: - the measured document

/// `[y_in: [x_in: text]]` for page 1, y measured from the TOP.
private func drawnRows(_ pdf: [UInt8]) -> [String: String] {
    let text = String(decoding: pdf, as: UTF8.self)
    var height = 792.0
    if let box = text.range(of: #"/MediaBox \[0 0 \d+ (\d+)\]"#,
                            options: .regularExpression) {
        let parts = text[box].split(separator: " ")
        if parts.count >= 5, let h = Double(parts[4].dropLast(1)) { height = h }
    }
    guard let first = text.range(of: ">>\nstream\n"),
          let end = text[first.upperBound...].range(of: "\nendstream") else { return [:] }
    let stream = String(text[first.upperBound..<end.lowerBound])
    var out: [String: String] = [:]
    for line in stream.split(separator: "\n") {
        guard let tsRange = line.range(of: "Ts "),
              let tdRange = line.range(of: " Td ("),
              let close = line.range(of: ") Tj") else { continue }
        let coords = line[tsRange.upperBound..<tdRange.lowerBound].split(separator: " ")
        guard coords.count == 2, let x = Double(coords[0]),
              let y = Double(coords[1]) else { continue }
        let key = String(format: "%.2f,%.2f", (height - y) / 72.0, x / 72.0)
        out[key] = String(line[tdRange.upperBound..<close.lowerBound])
    }
    return out
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func bookletHeadsLandWhereRealWS7PutsThem() throws {
    // Probe B0, reproduced. Both head lines on ONE row at 0.57in, "Header Even 1" at
    // 0.20in and "Header Odd 1" at 9.21in — the same numbers the `ws7-prints/v4` capture
    // carries, to the hundredth of an inch.
    let data = try Data(contentsOf: URL(fileURLWithPath:
        sawyerArchivePath + "/REF/BOOKLET.WS"))
    let rows = drawnRows(emitPDF(parseWS([UInt8](data)), mode: .printed))
    #expect(rows["0.57,0.20"] == "Header Even 1")
    #expect(rows["0.57,9.21"] == "Header Odd 1")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func bookletsOwnStyleAndLineHeightAreWhatTheEngineReads() throws {
    // The two IR fields the placement rests on, read off the real file so a parser
    // change that silently drops either is caught here rather than in a coordinate that
    // happens to still look right.
    let data = try Data(contentsOf: URL(fileURLWithPath:
        sawyerArchivePath + "/REF/BOOKLET.WS"))
    let doc = parseWS([UInt8](data))
    #expect(doc.headerStyleRM == [1: 100.0])          // 18000 HMI / 180
    #expect(doc.headerLeads == [1: 0.0, 2: 0.0])      // its own `.lh 0`
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func aDefaultTwoLineHeadIsUntouched() throws {
    // The corpus's other multi-line heads declare no `.lh` and no style right margin, so
    // they keep the rows and the left edge they had.
    let data = try Data(contentsOf: URL(fileURLWithPath:
        sawyerArchivePath + "/MAILLIST/PROOF.LST"))
    let doc = parseWS([UInt8](data))
    #expect(doc.headerLeads.isEmpty)
    #expect(doc.headerStyleRM.isEmpty)
}
