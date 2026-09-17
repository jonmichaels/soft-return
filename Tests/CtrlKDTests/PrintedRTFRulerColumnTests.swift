/// E9 R1 (Jon's ruling 2026-09-17, the human-eye export audit section A): the Printed RTF
/// text column is the document's own ruler, not paper minus twice `.po`. Port of ctrl-kd's
/// `tests/test_printed_rtf_ruler_column.py`.
///
/// THE DEFECT. Printed RTF wrote `\margr = \margl`, which makes the text column *paper
/// width - 2 x `.po`*. At the ordinary default (`.po 0.8in` on Letter) that is exactly 69
/// columns, one short of the 69-character lines real documents carry, so 6,488 facsimile
/// lines in 216 documents came back re-wrapped from the reader -- the one thing Printed
/// mode exists to prevent -- and `MAILLIST/ENVELOPE.LST` (`.poo/.poe 4.20"` on an 8.5in
/// sheet) was left with a text column ONE TENTH OF AN INCH wide.
///
/// The column is now `max(the widest .rm in force, the document's own longest printed
/// line) + one cell`, measured from the `.po` origin exactly as the Printed PDF measures
/// its right edge, with `\paperw` growing when the sheet cannot hold it (capped at 22in,
/// Word's own maximum page dimension).
///
/// The one cell of slack is not decoration: a reader breaks a line whose width EQUALS the
/// measure exactly (measured, LibreOffice 24.2.7.2 -- 68 characters fit a 69-column
/// column, 69 do not), and `pd-samples/authored/OCAPTAIN.WS` is exactly that boundary.
///
/// Synthetic fixtures only.
import Testing
@testable import CtrlKD

private let cell = 144              // one 10-CPI print column, in twips

private func ws7Doc(_ body: String, dots: String = "") -> Document {
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += Array((dots + body).utf8)
    return parseWS(data)
}

private struct PageBox {
    let paperw: Int, margl: Int, margr: Int
    var column: Int { paperw - margl - margr }
}

private func pageBox(_ rtf: String) throws -> PageBox {
    // `\paperwN\paperhN\marglN\margrN`, in that fixed order
    func number(after word: String, in s: String) -> Int? {
        guard let r = s.range(of: word) else { return nil }
        var digits = ""
        for ch in s[r.upperBound...] {
            guard ch.isNumber else { break }
            digits.append(ch)
        }
        return Int(digits)
    }
    let paperw = try #require(number(after: #"\paperw"#, in: rtf))
    let margl = try #require(number(after: #"\margl"#, in: rtf))
    let margr = try #require(number(after: #"\margr"#, in: rtf))
    return PageBox(paperw: paperw, margl: margl, margr: margr)
}

@Test func printedColumnIsTheDeclaredRulerPlusOneCell() throws {
    let doc = ws7Doc("short line\r\n", dots: ".po 8\r\n.rm 60\r\n")
    let box = try pageBox(emitRTF(doc, mode: .printed))
    #expect(box.column == (60 + 1) * cell)
    // `.po` still owns the LEFT edge -- only the right edge moved
    #expect(box.margl == 8 * cell)
}

@Test func printedColumnFollowsALinePastItsRuler() throws {
    // Box art, print streams and plain-text sources overrun their own `.rm`; the
    // facsimile follows the ink, not just the ruler.
    let doc = ws7Doc(String(repeating: "X", count: 100) + "\r\n", dots: ".po 8\r\n.rm 60\r\n")
    #expect(try pageBox(emitRTF(doc, mode: .printed)).column == (100 + 1) * cell)
}

@Test func printedKeepsTheSixtyNineCharacterLineWhole() throws {
    // The OCAPTAIN boundary: 69 characters under the old arithmetic landed in a
    // 69-column column and came back as two lines.
    let doc = ws7Doc(String(repeating: "W", count: 69) + "\r\n", dots: ".po 8\r\n")
    let box = try pageBox(emitRTF(doc, mode: .printed))
    #expect(box.column >= 70 * cell)
    #expect(box.paperw == 12240)         // still Letter: the column fits inside it
}

@Test func printedTrailingSpacesDoNotWidenTheColumn() throws {
    // A reader does not break a line because of the spaces hanging off its end
    // (measured, LibreOffice 24.2.7.2), so neither does this measure.
    let plain = ws7Doc(String(repeating: "Z", count: 40) + "\r\n", dots: ".po 8\r\n.rm 60\r\n")
    let padded = ws7Doc(String(repeating: "Z", count: 40) + String(repeating: " ", count: 40)
                        + "\r\n", dots: ".po 8\r\n.rm 60\r\n")
    #expect(try pageBox(emitRTF(plain, mode: .printed)).column
            == (try pageBox(emitRTF(padded, mode: .printed)).column))
}

@Test func printedRulerWiderThanTheSheetWidensThePaper() throws {
    // The audit's question 6, ruled yes: an envelope template declares `.po 4.20"` and
    // `.rm 9.50"` on a short sheet. Mirrored offsets used to leave 0.1in of text column.
    let doc = ws7Doc("&name&\r\n",
                     dots: ".pl 4.17\"\r\n.poo 4.20\"\r\n.poe 4.20\"\r\n.rm 9.50\"\r\n")
    let rtf = emitRTF(doc, mode: .printed)
    let box = try pageBox(rtf)
    #expect(box.column == (95 + 1) * cell)
    #expect(box.paperw == box.margl + box.column + box.margr)
    // `\margmirror` keeps BOTH declared offsets -- the outside margin is a real
    // page-parity fact, not leftover paper
    #expect(box.margl == 42 * cell && box.margr == 42 * cell)
    #expect(rtf.contains(#"\margmirror"#))
}

@Test func printedPaperStopsAtTwentyTwoInches() throws {
    // Word's own maximum page dimension. A document whose own lines are longer than that
    // keeps the reader's re-wrap -- there is no page any reader will accept for them.
    let doc = ws7Doc(String(repeating: "Q", count: 3000) + "\r\n", dots: ".po 8\r\n")
    #expect(try pageBox(emitRTF(doc, mode: .printed)).paperw == 22 * 1440)
}

@Test func modernPageBoxIsUntouched() throws {
    // Modern reflows; the ruler is Printed's business alone.
    let doc = ws7Doc(String(repeating: "X", count: 100) + "\r\n", dots: ".po 8\r\n.rm 60\r\n")
    let box = try pageBox(emitRTF(doc, mode: .modern))
    #expect(box.paperw == 12240 && box.margl == 8 * cell && box.margr == 8 * cell)
}
