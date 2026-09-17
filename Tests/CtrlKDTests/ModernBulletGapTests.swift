import Foundation
import Testing
@testable import CtrlKD

/// M27/E8 (Jon, 2026-09-17): Modern puts the SAME gap after a list bullet that Printed and
/// the app's Native view do. Swift port of ctrl-kd's `tests/test_modern_bullet_gap.py`.
///
/// THE DEFECT. A bullet row's marker and the single space after it each occupy one
/// monospace CELL in Printed and in Native, so the item's first word starts two cells past
/// the marker's own left edge. Modern already drew the marker pinned to that same cell
/// (`■` is vector art, not a glyph), but then measured the SPACE after it in the READING
/// face, where a Times-14 space is 3.5pt against the cell's 7.2. Measured off the rendered
/// PDF for `sawyer/-README.WS`: the first word landed 4.70pt past the square's ink where
/// Native puts it 8.40pt past. The bullet and its text read as one crowded word.
///
/// WHY THE CELL AND NOT THE BODY SIZE. `colPt` is the document's own `.cw`-derived fixed
/// pitch (7.2pt at the default `.cw 12`) — the same cell Printed lays its whole page on
/// and the one the marker is already pinned to. The Modern BODY size would have given
/// 14 × 0.6 = 8.4pt of gap and put the word 9.66pt past the ink, past what Native shows.
/// The measured target was the cell.
///
/// SCOPED TO BULLETS, not to every `■`: the gate is the structure classifier's own
/// `kind == .bullet` plus its recorded marker.
///
/// Synthetic fixtures only.

private let e8Hard: [UInt8] = [0x0D, 0x0A]
private let e8Square = "■"
private let e8CellPt = 7.2          // the default `.cw 12` fixed pitch, 12 * 0.6

private func e8WS7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
    let count = UInt16(content.count + 4)
    var out: [UInt8] = [0x1D]
    out += [UInt8(count & 0xFF), UInt8(count >> 8)]
    out.append(cmd)
    out += content
    out += [UInt8(count & 0xFF), UInt8(count >> 8)]
    out.append(0x1D)
    return out
}

private let e8Seed = e8WS7Block(0x0B, [0, 0, 0, 0])

/// cp437 for `■`.
private let e8SquareByte: UInt8 = 0xFE

/// Two or more `■ text` rows: `classifyRows` only calls a glyph a marker when it repeats,
/// which is what makes the rows a LIST rather than one line starting with a square.
private func e8BulletList(_ items: [String]) -> [UInt8] {
    var out = e8Seed
    for item in items {
        out.append(e8SquareByte)
        out.append(0x20)
        out += Array(item.utf8)
        out += e8Hard
    }
    return out
}

/// The first bullet row's Modern tokens, after the flow has applied the structure ladder —
/// i.e. what actually gets measured and drawn.
private func e8BulletRow(_ data: [UInt8]) -> (toks: [ModernToken], hang: Double)? {
    let doc = parseWS(data)
    var semIndex: [Int]? = nil
    var blockIndex: [Int?]? = nil
    let width = Double(PDFMetrics.pageWidth - 2 * PDFMetrics.margin)
    let flow = modernFlow(doc, keep: EmitOptions.defaultNotes, textWidthPt: width,
                          semIndexOfItem: &semIndex, blockIndexOfItem: &blockIndex)
    for item in flow {
        if case .para(let toks, _, _, _, _, _, _, _, _, let hang) = item,
           toks.contains(where: { $0.text == e8Square }) {
            return (toks, hang)
        }
    }
    return nil
}

@Test func theSpaceAfterABulletIsOneFixedPitchCell() throws {
    // The whole fix, at the one place it happens: the marker keeps its pinned cell and the
    // space after it becomes the same width.
    let row = try #require(e8BulletRow(e8BulletList(["Alpha item text here.",
                                                     "Beta item text here."])))
    #expect(row.toks[0].text == e8Square)
    #expect(row.toks[1].text == " ")
    #expect(abs(row.toks[0].width - e8CellPt) < 0.01, "\(row.toks[0])")
    #expect(abs(row.toks[1].width - e8CellPt) < 0.01, "\(row.toks[1])")
}

@Test func theFirstWordStartsTwoCellsPastTheMarker() throws {
    // What Jon actually looked at: Printed and Native start the text two cells in, and
    // Modern now agrees.
    let row = try #require(e8BulletRow(e8BulletList(["Alpha item text here.",
                                                     "Beta item text here."])))
    #expect(abs((row.toks[0].width + row.toks[1].width) - 2 * e8CellPt) < 0.01)
}

@Test func theHangFollowsTheWidenedGap() throws {
    // A wrapped continuation lines up under the item's first word, so the hang has to be
    // measured AFTER the gap is widened — measured before, every continuation would sit
    // 3.7pt to the left of the text it belongs to.
    let long = "Alpha " + String(repeating: "word ", count: 40)
    let row = try #require(e8BulletRow(e8BulletList([long, "Beta item text here."])))
    #expect(abs(row.hang - 2 * e8CellPt) < 0.01, "\(row.hang)")
}

@Test func everyOtherSpaceKeepsTheReadingFace() throws {
    // Only the ONE space after the marker moves. A Times-14 space is 3.5pt and stays
    // 3.5pt everywhere else in the row.
    let row = try #require(e8BulletRow(e8BulletList(["Alpha beta gamma.",
                                                     "Delta epsilon zeta."])))
    let later = row.toks.dropFirst(2).filter { $0.text == " " }
    #expect(!later.isEmpty)
    #expect(later.allSatisfy { abs($0.width - e8CellPt) > 0.01 }, "\(later)")
    #expect(later.allSatisfy { abs($0.width - 3.5) < 0.01 }, "\(later)")
}

@Test func aSquareInRunningProseIsUntouched() throws {
    // SCOPE. A `■` that is not a list marker — no repeating column, so `classifyRows`
    // never calls it one — keeps the reading face's own space after it.
    var data = e8Seed + Array("A line about the ".utf8)
    data.append(e8SquareByte)
    data += Array(" symbol in ordinary prose.".utf8)
    data += e8Hard
    let row = try #require(e8BulletRow(data))
    let i = try #require(row.toks.firstIndex { $0.text == e8Square })
    let after = row.toks[i + 1]
    #expect(after.text == " ")
    #expect(abs(after.width - e8CellPt) > 0.01, "\(after)")
}

@Test func theRTFBulletHangIsTheSameTwoCells() {
    // Modern RTF expresses the same measurement as a hanging indent, and it used to
    // compute a THIRD number (the two characters in Times, 9.72pt) that matched neither
    // Printed nor the Modern PDF.
    let doc = parseWS(e8BulletList(["Alpha item.", "Beta item."]))
    var structure = RowStructure(col: .int(0), level: 1)
    structure.kind = .bullet
    structure.marker = e8Square
    let (li, fi) = rtfStructureIndentHang(structure, doc, markerText: e8Square + " ")
    #expect(li == Int((2 * e8CellPt * 20).rounded()), "\(li)")   // 288 twips
    #expect(fi == -li)
}

@Test func aDefRowHangIsUnchanged() {
    // A def row has a real proportional LABEL in front of it, not a pinned cell, so its
    // hang stays the fixed points figure it always was.
    let doc = parseWS(e8Seed + Array("Label  body text.".utf8) + e8Hard)
    var structure = RowStructure(col: .int(0), level: 1)
    structure.kind = .def
    let (li, _) = rtfStructureIndentHang(structure, doc, markerText: "")
    #expect(li == Int((modernDefHangPt * 20).rounded()), "\(li)")
}
