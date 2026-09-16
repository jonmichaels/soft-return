/// cp437 block/shade/box glyphs degrading to '?' in a Symbol-mapped span (Printed and
/// Modern PDF alike). Swift mirror of ctrl-kd's `tests/test_symbol_span_graphic_chars.py`
/// (3aceb48) -- same fixture shape, same three spans, same assertions, ported to this
/// project's own Fixtures.swift/PDFReadback.swift helpers.
///
/// PARTLY SUPERSEDED, 2026-09-16: the premise below -- a font block named Brush Script
/// whose character-set bits read 'math' resolving to the Adobe Symbol face -- is exactly
/// the misread the 2026-09-16 ruling ends ("a resolved ordinary typeface beats the
/// character-set bits"; class tests in StyleAttributeRulings20260916Tests.swift). That run
/// now stays on its own ordinary face. The GEOMETRY guarantee this file was written for is
/// unchanged and still the point of every test here: box/shade glyphs draw as vector fills
/// and a middle dot stays a real byte, in every font state a span can be in.
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
    data += graphicCP437
    data += bytes(" ")
    data += dotCP437
    data += HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: ordinaryStyleBits, width: 180)
    data += graphicCP437
    data += bytes(" ")
    data += dotCP437
    data += HARD
    data += fontBlock(symbolMappedNumber, points: 12.0, styleBits: symbolMappedStyleBits, width: 180)
    data += graphicCP437
    data += bytes(" ")
    data += dotCP437
    data += HARD
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

@Test func symbolMappedSpanNoLongerSelectsTheSymbolFontAtAll() {
    // SUPERSEDED BY THE 2026-09-16 RULING ("a resolved ordinary typeface beats the
    // character-set bits"). This case -- typestyle 54, "Brush Script", with the coarse
    // symbol-map bits reading math -- is the very misread that ruling ends: Brush Script
    // is a perfectly ordinary named face, so its run now stays on the ordinary text font
    // and the character-set bits govern only the extended characters, as WordStar
    // intended.
    //
    // What this file's own bug fix guaranteed is unchanged and still checked here: the
    // twelve box/shade glyphs draw as vector geometry and the middle dot stays a real
    // 0xB7 text byte, never the '?' degradation. The byte is the same either way --
    // cp1252 and Adobe Symbol both carry periodcentered at 0xB7 -- so the visible page
    // does not move; only the font resource does. See
    // StyleAttributeRulings20260916Tests.swift for the ruling's own class tests.
    let doc = buildDoc()
    let pdf = emitPDF(doc, mode: .printed)
    #expect(fontName(for: "Symbol", in: pdf) == nil,
           "a /BaseFont /Symbol resource was registered for an ordinary named face")
    // The LAST text-showing operator is the third span's middle dot -- one bare 0xB7
    // byte, never '?'.
    let last = contentSpans(pdf).last
    #expect(last?.text == "\u{b7}",
           "the middle dot did not survive as a real byte: got \(String(describing: last?.text))")
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
