/// Port of ctrl-kd's `tests/test_bare_tab_modulus8.py` (planning #202 batch).
///
/// WS7's own file-format reference (WSFORMAT.WS control-code table, byte 09h ^I)
/// states the rule in one sentence -- "At print time the number of hard spaces
/// required to reach a modulus 8 print position is generated" -- and this engine
/// rendered a bare 0x09 with ZERO width, gluing the word before it to the word
/// after. VERIFIED against WS7's own real LaserJet PCL capture the same way the
/// Python port was: "00h ^@<TAB>Fix" -- 6 characters before the tab -- places
/// "Fix" at exactly column 8.
import Testing
@testable import CtrlKD

@Test func bareTabAfterSixColumnsReachesTheNextModulus8Stop() {
    let doc = parseWS(bytes("00h ^@\tFix ") + bytes("Filler prose so the detector reads this as a document, plainly.") + HARD)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.hasPrefix("00h ^@  Fix"), "\(text)")
}

@Test func bareTabAtLineStartExpandsToAFullStop() {
    let doc = parseWS(bytes("\tWord ") + bytes("Filler prose so the detector reads this as a document, plainly.") + HARD)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.hasPrefix(String(repeating: " ", count: 8) + "Word"), "\(text)")
}

@Test func bareTabExactlyOnAStopStillAdvancesAFull8() {
    // 8 characters before the tab -- already sitting on a modulus-8 print
    // position. The standard tab convention (and the only reading consistent
    // with the line-start case above) is that it still advances a full 8, not 0.
    let doc = parseWS(bytes("12345678\tWord ") + bytes("Filler prose so the detector reads this as a document, plainly.") + HARD)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.hasPrefix("12345678" + String(repeating: " ", count: 8) + "Word"), "\(text)")
}

@Test func bareTabColumnCountResetsAtTheNextPhysicalLine() {
    // A short second line must not inherit the column count from the line
    // before it -- `decodeSpans` is called once per physical CRLF-delimited
    // source line and the column count must reset each time.
    let doc = parseWS(bytes("\tWord") + HARD +
                      bytes("ab\tWord ") + bytes("Filler prose so the detector reads this as a document, plainly.") + HARD)
    #expect(doc.blocks[0].lines[0].text().hasPrefix(String(repeating: " ", count: 8) + "Word"))
    #expect(doc.blocks[0].lines[1].text().hasPrefix("ab" + String(repeating: " ", count: 6) + "Word"))
}
