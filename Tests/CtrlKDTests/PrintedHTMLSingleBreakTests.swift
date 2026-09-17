/// E9 H1 (Jon's ruling 2026-09-17, the human-eye export audit section D): one newline per
/// facsimile line in Printed HTML, and no `<br>`. Port of ctrl-kd's
/// `tests/test_printed_html_single_break.py`.
///
/// THE DEFECT. `p.ws-native` settled on `white-space:pre` (its `overflow-x:auto` is what
/// lets a wide facsimile line scroll inside itself instead of dragging the page sideways),
/// and under `pre` the newline IS the break. The emitter also wrote a `<br>` at the end of
/// every line, so there were TWO breaks per line: every line of the document was followed
/// by a blank one, a 57-page novel arrived twice as tall as it is, and the 1990 line grid
/// was gone. 481 of 511 Printed HTML documents used `ws-native`; 195 Modern ones did,
/// through the print-stream/ruler-line documents forced to the facsimile path.
///
/// Synthetic fixtures only.
import Testing
@testable import CtrlKD

private func ws7Doc(_ body: String) -> Document {
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += Array(body.utf8)
    return parseWS(data)
}

/// The text inside the first `<p class="... ws-native">`.
private func nativeBlock(_ html: String) throws -> String {
    let marker = "ws-native\">"
    let start = try #require(html.range(of: marker))
    let end = try #require(html.range(of: "</p>", range: start.upperBound..<html.endIndex))
    return String(html[start.upperBound..<end.lowerBound])
}

@Test func printedLinesAreSeparatedByOneNewline() throws {
    let html = emitHTML(ws7Doc("first line\r\nsecond line\r\nthird line\r\n"),
                        mode: .printed)
    #expect(!html.contains("<br>"))
    #expect(try nativeBlock(html) == "first line\nsecond line\nthird line")
}

@Test func theNativeBlockIsStillAPreBlock() {
    // The newline only IS the break because `white-space:pre` says so -- if that ever
    // changes the `<br>` has to come back.
    #expect(emitHTML(ws7Doc("a line\r\n"), mode: .printed)
        .contains(".ws-native{white-space:pre;overflow-x:auto;"))
}

@Test func printedLeadingColumnSpacingSurvives() throws {
    // `pre` is also what keeps the typed columns lined up, which is the whole point.
    let html = emitHTML(ws7Doc("    indented\r\nplain\r\n"), mode: .printed)
    #expect(try nativeBlock(html) == "    indented\nplain")
}
