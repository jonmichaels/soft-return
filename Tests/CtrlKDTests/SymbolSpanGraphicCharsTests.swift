/// cp437 block/shade/box glyphs degrading to '?' in a Symbol-mapped span (Printed and
/// Modern PDF alike). Swift mirror of ctrl-kd's `tests/test_symbol_span_graphic_chars.py`
/// (3aceb48) -- same fixture shape, same three spans, same assertions, ported to this
/// project's own Fixtures.swift/PDFReadback.swift helpers.
///
/// FOUND against the real corpus: sawyer/REF/-LASERJE.FNT line 9 -- twelve cp437 glyphs
/// ('░▒▓│┤╡╢╖╕╣║╗') typed under a font block whose typestyle is Brush Script, whose own
/// symbol-map bits read 'math'. `pdfFamily` reads those bits before anything else and
/// resolves the span to the Symbol face, so `spanRender` used to run the WHOLE span
/// through `untransliterate(text, .math)` -- `SymbolTranslit.swift`'s own documented
/// contract for a character it cannot round-trip into the real Symbol font's byte table is
/// to degrade it to '?' -- and none of `graphicChars` has a Symbol code point. The twelve
/// real box/shade glyphs became twelve literal '?' TEXT characters at the Symbol font's
/// own advance instead of the vector fills `splitGraphics`/`graphicOps` already draw for
/// the SAME characters in every other span (fontless or ordinary-fonted).
///
/// FIX (`PDFFonts.swift`'s `spanRender`): `graphicChars` members skip the
/// Symbol/ZapfDingbats untransliteration round trip and keep their true Unicode code
/// points, so `splitGraphics` finds them downstream and draws them as geometry exactly
/// like it already does for every other family -- generic, applies to both Printed and
/// Modern PDF (both share this one function).
///
/// Companion fix (`SymbolTranslit.swift`): a middle dot (U+00B7) is not a `graphicChars`
/// member, but reaching a Symbol-mapped span it hit the identical '?' degradation
/// (`symbolReverse` had no entry for it). Adobe Symbol's own encoding carries a real
/// 'periodcentered' glyph at byte 0xB7, visually identical to Unicode's middle dot --
/// `symbolEncoding` now maps it self-to-self, the same convention already used for
/// U+00B0/U+00B1.
import Testing
@testable import CtrlKD

/// SHADE_GRAY (░▒▓) + BOX_ARMS (│┤╡╢╖╕╣║╗) in cp437 byte order, the same twelve-glyph
/// sample -LASERJE.FNT line 9 types.
private let graphicCP437: [UInt8] = [0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5,
                                     0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB]
/// cp437 0xFA -- U+00B7 MIDDLE DOT.
private let dotCP437: [UInt8] = [0xFA]

/// Real -LASERJE.FNT font6 typestyle word decomposed into `fontBlock`'s (number,
/// styleBits) shape: number 54 ("Brush Script", `Typestyles.swift`), styleBits
/// proportional (0x8000) | symbolMap=math (0x2000, bits 12-13 value 2) | genericStyle=
/// script (0x0800, bits 10-11 value 2) -- decodes to the SAME 59958 word ctrl-kd's
/// `test_symbol_span_graphic_chars.py` uses directly (0x8000+0x2000+0x0800+54 = 43308+
/// ... i.e. `54 | 0xA800` -- verified against `FontChange`'s own bit accessors).
private let symbolMappedNumber = 54
private let symbolMappedStyleBits = 0x8000 | 0x2000 | 0x0800
/// Ordinary proportional, non-Symbol font (Helvetica) -- the "already worked" baseline.
private let ordinaryStyleBits = 0x8000

/// Fontless span, then an ordinary-fonted span, then the Symbol-mapped span that
/// reproduces the real corpus defect -- all three carry the SAME graphic run + middle dot.
private func buildDoc() -> Document {
    var data: [UInt8] = []
    data += graphicCP437 + bytes(" ") + dotCP437 + HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: ordinaryStyleBits, width: 180)
    data += graphicCP437 + bytes(" ") + dotCP437 + HARD
    data += fontBlock(symbolMappedNumber, points: 12.0, styleBits: symbolMappedStyleBits, width: 180)
    data += graphicCP437 + bytes(" ") + dotCP437 + HARD
    return parseWS(data)
}

@Test func fontlessOrdinaryAndSymbolMappedSpansAllDrawVectorsNotQuestionMarks() {
    let doc = buildDoc()
    for mode: EmitMode in [.printed, .modern] {
        let pdf = emitPDF(doc, mode: mode)
        // The bug, pinned directly: none of the three spans may show the twelve-glyph
        // run (or the middle dot) as a degraded '?' -- before the fix the Symbol-mapped
        // span failed this outright ("(????????????) Tj").
        #expect(contentSpans(pdf).allSatisfy { !$0.text.contains("?") },
               "\(mode): a '?' reached a text-showing operator")
        // Three IDENTICAL twelve-glyph runs: the shade trio (three "re f" fills, one per
        // SHADE_GRAY level) plus the nine BOX_ARMS glyphs' own arm rectangles, x3 spans.
        let fillCount = countOccurrences(of: bytes(" re f"), in: pdf)
        #expect(fillCount >= 3 * (3 + 9),
               "\(mode): fewer vector fill ops than three full twelve-glyph runs (got \(fillCount))")
    }
}

@Test func symbolMappedSpanMiddleDotStillSelectsTheSymbolFont() {
    let doc = buildDoc()
    let pdf = emitPDF(doc, mode: .printed)
    let symbolName = fontName(for: "Symbol", in: pdf)
    #expect(symbolName != nil, "no /BaseFont /Symbol resource registered at all")
    let spans = contentSpans(pdf)
    // The LAST text-showing operator is the third span's middle dot -- one bare 0xB7
    // byte (Adobe Symbol's periodcentered), under the Symbol resource, never '?'.
    let last = spans.last
    #expect(last?.font == symbolName,
           "last Tj (\(String(describing: last))) is not under the Symbol font resource")
    #expect(last?.text == "\u{b7}",
           "Symbol-mapped middle dot did not encode as periodcentered (0xb7): got \(String(describing: last?.text))")
}

@Test func fontlessAndOrdinaryFontSpansAreUnaffectedBaseline() {
    // splitGraphics already drew graphicChars as vectors for a fontless or
    // ordinary-fonted span before this fix (job 187/ruling B) -- the Symbol-family fix
    // must not disturb that. All THREE spans (including the Symbol-mapped one) draw
    // their SHADE_GRAY trio as vector fills with no font operator at all -- geometry
    // never selects a font, so even the Symbol-mapped span's box run precedes its own
    // first Tf. Baseline guard: if this ever regresses, the bug is in one of the OTHER
    // two spans, not the one this fix was about.
    let doc = buildDoc()
    let pdf = emitPDF(doc, mode: .printed)
    #expect(countOccurrences(of: bytes("0.75 g"), in: pdf) == 3)
    #expect(countOccurrences(of: bytes("0.50 g"), in: pdf) == 3)
    #expect(countOccurrences(of: bytes("0.25 g"), in: pdf) == 3)
    #expect(contentSpans(pdf).allSatisfy { !$0.text.contains("?") })
}
