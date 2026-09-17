/// E9 H4 (Jon's ruling 2026-09-17, the human-eye export audit section G): Modern HTML gets
/// a measure and an overflow guard. Port of ctrl-kd's `tests/test_modern_html_measure.py`.
///
/// THE DEFECT. With no measure at all a 1400px window gave about 150 characters to the
/// line, roughly twice a comfortable one, and with no overflow guard 60 of 509 Modern
/// documents scrolled sideways at 400px, four of them more than four times the viewport.
/// Modern gets a 38em measure with `margin:0 auto`, `overflow-wrap:anywhere`, a scroll on
/// the paragraph, and the same scroll on the one span that may not fold. Printed is
/// deliberately untouched: it was already clean at 400px, its `p.ws-native` blocks scroll
/// inside themselves, and a measure imposed on a line-for-line page would be exactly the
/// page-width opinion the round 3 addendum rejected.
///
/// Synthetic fixtures only.
import Testing
@testable import CtrlKD

private let measureCSS = "body{max-width:38em;margin:0 auto;overflow-wrap:anywhere}"
private let paraScrollCSS = "p{overflow-x:auto}"
private let nowrapScrollCSS =
    "\nspan.ws-nowrap{display:inline-block;max-width:100%;overflow-x:auto;vertical-align:top}"

private func measureDoc(_ body: String) -> Document {
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += Array(body.utf8)
    return parseWS(data)
}

@Test func modernCarriesTheMeasure() {
    let html = emitHTML(measureDoc("some prose\r\n"), mode: .modern)
    #expect(html.contains(measureCSS))
    #expect(html.contains(paraScrollCSS))
}

@Test func theNowrapScrollIsAppendedOnlyWhenARowUsesIt() {
    // Same "no CSS-byte delta for a feature this document never used" discipline the
    // other conditional rules follow.
    #expect(!emitHTML(measureDoc("some prose\r\n"), mode: .modern).contains(nowrapScrollCSS))
    // cp437 box-drawing bytes, not UTF-8: the parser reads the era's code page.
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += [0xda, 0xc4, 0xc4, 0xc4, 0xbf, 0x0d, 0x0a]        // ┌───┐
    let graphic = emitHTML(parseWS(data), mode: .modern)
    #expect(graphic.contains("class=\"ws-nowrap\""))
    #expect(graphic.contains(nowrapScrollCSS))
}

@Test func printedDoesNotCarryTheMeasure() {
    let html = emitHTML(measureDoc("some prose\r\n"), mode: .printed)
    #expect(!html.contains(measureCSS))
    #expect(!html.contains(paraScrollCSS))
    // the facsimile block keeps its own scroll, which is all it ever needed
    #expect(html.contains(".ws-native{white-space:pre;overflow-x:auto;"))
}
