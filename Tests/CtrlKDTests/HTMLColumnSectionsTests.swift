/// E9 H2 (Jon's ruling 2026-09-17, the human-eye export audit section E). Port of
/// ctrl-kd's `tests/test_html_column_sections.py`.
///
/// NEWSPAPER COLUMNS ARE A SECTION, NOT A PARAGRAPH. Modern HTML wrapped every
/// paragraph of a `.co n` region in its own `column-count` box, so each paragraph balanced
/// itself across the columns and a fresh pair started underneath -- half-empty right-hand
/// columns and a reading order that looks broken, on a document the RTF emitter gets right
/// with a single `\cols2` section. Printed HTML dropped the columns entirely: 0 of 511
/// Printed HTML documents carried any. Both modes now open ONE container per columnar
/// section, and a phone collapses it to one column.
///
/// Synthetic fixtures only.
import Testing
@testable import CtrlKD

private let measureCSS = "body{max-width:38em;margin:0 auto;overflow-wrap:anywhere}"
private let paraScrollCSS = "p{overflow-x:auto}"
private let nowrapScrollCSS =
    "span.ws-nowrap{display:inline-block;max-width:100%;overflow-x:auto;vertical-align:top}"

private func ws7Doc(_ body: String, dots: String = "") -> Document {
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += Array((dots + body).utf8)
    return parseWS(data)
}

private func twoColumnDoc() -> Document {
    ws7Doc("first paragraph\r\n\r\nsecond paragraph\r\n\r\nthird paragraph\r\n",
           dots: ".co 2, 0.25\"\r\n")
}

private func containers(_ html: String) -> Int {
    html.components(separatedBy: "<div class=\"ws-cols\" style=\"").count - 1
}

@Test func modernOpensOneContainerForTheWholeSection() throws {
    let html = emitHTML(twoColumnDoc(), mode: .modern)
    #expect(containers(html) == 1)
    #expect(html.contains("<div class=\"ws-cols\" style=\"column-count:2; column-gap:0.25in\">"))
    // and all three paragraphs live inside it
    let after = try #require(html.range(of: "<div class=\"ws-cols\""))
    let close = try #require(html.range(of: "</div>", range: after.upperBound..<html.endIndex))
    let inside = html[after.upperBound..<close.lowerBound]
    #expect(inside.components(separatedBy: "<p").count - 1 == 3)
}

@Test func printedKeepsTheColumnsItUsedToDrop() {
    let html = emitHTML(twoColumnDoc(), mode: .printed)
    #expect(containers(html) == 1)
    #expect(html.contains("ws-native"))          // still the facsimile block inside
}

@Test func aPhoneGetsOneColumn() {
    #expect(emitHTML(twoColumnDoc(), mode: .modern)
        .contains("@media(max-width:600px){div.ws-cols{column-count:1!important}}"))
}

@Test func aDocumentWithoutColumnsPaysNoCSSForThem() {
    #expect(!emitHTML(ws7Doc("plain\r\n"), mode: .modern).contains("ws-cols"))
}
