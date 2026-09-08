/// cp437 box/block/shade glyphs in Printed-mode PDF, drawn as vectors rather than text
/// (`PDFDriverLJ6DTP.swift`'s `boxArms`/`shadeGray`/`partBlocks`/`graphicOps`) — the ONLY
/// representation available at all, since cp1252 (`/WinAnsiEncoding`, what `esc` encodes
/// text into) has no slot for any of them and would otherwise degrade every one to `?`.
///
/// Job 187 (2026-08-10): a fontless run (every WS4 file; no `.fo` font block) used to be
/// excluded from this path — `splitGraphics`'s old guard treated "no font block" as
/// "never touch this run", so a classic WordStar line-draw box (real field fixture:
/// `BOX.WS`, PC-8 bytes 0xDA/0xC4/0xBF/0xB3/0xC0/0xD9 wrapped `<1B x 1C>`, no font block
/// anywhere in the file) fell through to the plain text path and printed literal `?`s for
/// every corner and a `-`/`|` lookalike (`PDFWriter.swift`'s `escFallback`) for just two of
/// its sides. Modern mode already drew the same glyphs as shapes for fontless runs
/// (`PDFModernLayout.swift`'s `modernTokenWidth`, ruling M11) — this brought Printed's own
/// emitter into agreement with Modern's, using the SAME tables, rather than inventing a
/// second one.
import Testing
@testable import CtrlKD

/// One line of a classic (fontless) WordStar box: `<1B 0xDA 1C><1B 0xC4 1C><1B 0xC4 1C>
/// <1B 0xBF 1C>` — the exact escape-wrap shape `BOX.WS`'s top rule uses, decoding (via
/// `decodeCP437`) to "┌──┐".
private func fontlessBoxLine(_ cp437Bytes: [UInt8]) -> [UInt8] {
    cp437Bytes.flatMap { [0x1B, $0, 0x1C] }
}

@Test func fontlessBoxDrawingRendersAsVectorsNotQuestionMarks() {
    let data = ws7Block(0x00) + fontlessBoxLine([0xDA, 0xC4, 0xC4, 0xBF]) + HARD
    let doc = parseWS(data)
    // Confirms the fixture really is fontless — `doc.fonts` only ever gets entries from a
    // `.fo` font block (`PDFFonts.swift`'s own contract, `DocumentRenderer.swift` cites it
    // too), and this document never declares one.
    #expect(doc.fonts.isEmpty)

    let pdf = emitPDF(doc, mode: .printed)
    // The vector path: box arms are unfilled rectangles ("re f"), never text-shown.
    #expect(contains(pdf, bytes(" re f")))
    // No span was asked to show a graphic character as TEXT, so `esc`'s cp1252 replacement
    // never fired for one — the whole point of the fix.
    #expect(contentSpans(pdf).allSatisfy { !$0.text.contains("?") })
}

@Test func fontBlockedBoxDrawingStillRendersAsVectors() {
    // Regression: the WS5+ (font-blocked) path this test file had zero prior coverage of,
    // unchanged by job 187 — box drawing under a real font block took the vector path
    // before this fix and must keep doing so.
    let helv = helvTypestyle()
    let data = ws7Block(0x00)
        + fontBlock(helv, points: 12.0, styleBits: 0, width: 720)
        + fontlessBoxLine([0xDA, 0xC4, 0xC4, 0xBF]) + HARD
    let doc = parseWS(data)
    #expect(!doc.fonts.isEmpty)

    let pdf = emitPDF(doc, mode: .printed)
    #expect(contains(pdf, bytes(" re f")))
    #expect(contentSpans(pdf).allSatisfy { !$0.text.contains("?") })
}

@Test func cp437SymbolGlyphsDrawAsVectorsNotQuestionMarks() {
    // Jon's ruling (2026-08-11, extending ruling B): "the card suits, etc. show up
    // everywhere." LJ6DTP p3's "Shows on screen as" column is the literal control-position
    // bytes 02-06/0F/F0 — era screens showed card suits, the smiley, the sun, and the
    // triple bar. Latin-1 has none of them; before this ruling every one degraded to '?'
    // in the printed PDF. Now they draw as filled vector geometry (`symbolShapes` in
    // `PDFDriverLJ6DTP.swift`). Same `<1B x 1C>`-wrapped shape the box pin above uses.
    let data = ws7Block(0x00) + fontlessBoxLine([0x02, 0x03, 0x04, 0x05, 0x06, 0x0F, 0xF0]) + HARD
    let doc = parseWS(data)

    let pdf = emitPDF(doc, mode: .printed)
    #expect(contains(pdf, bytes(" c")))
    #expect(contains(pdf, bytes(" re f")))
    #expect(contentSpans(pdf).allSatisfy { !$0.text.contains("?") })
}

@Test func cp437GreekInPlainCourierRoutesThroughSymbolFace() {
    // b26 fix: cp437 puts Greek/math at 0xE0-0xEE with NO font block declaring Symbol at
    // all -- plain WS4/WS7 body text, the "screen chart" case (jon_vault's -SCREEN.pcl +
    // .measurements.json: real WS7 prints the line αßΓπΣσµτΦΘΩδφε cleanly). Printed PDF's
    // text path (`esc`, cp1252-encode-with-replace) has no Greek at all, so before this fix
    // every one of those 14 characters became '?'. Only the 12 that cp1252 truly cannot
    // carry route to Symbol -- ß (sharp s) and µ (micro sign) are genuine cp1252 characters
    // in their own right (not this bug) and stay on the plain Courier face.
    let greekCP437: [UInt8] = [0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7,
                                0xE8, 0xE9, 0xEA, 0xEB, 0xED, 0xEE]
    let line = "αßΓπΣσµτΦΘΩδφε"
    var data = ws7Block(0x00)
    data += bytes("Plain prose padding so the detector reads this as a document.") + HARD
    data += greekCP437 + HARD
    data += bytes("And a closing line of ordinary prose keeps the ratio honest.") + HARD
    let doc = parseWS(data)
    let txt = emitText(doc, mode: .printed)
    #expect(txt.contains(line))                     // text formats: untouched

    // Printed's fontless body face is Courier at the doc size (12); Modern's is Times at
    // modernBodyPt (14) -- pdfFamily/modernTokFont's own documented per-mode split,
    // unrelated to this bug. The Symbol split itself (which pieces switch face, in what
    // order) must be the SAME sequence either way, so check that at whichever size/body
    // face each mode actually uses.
    //
    // Round 2026-09-07 (Jon, ctrl-kd 4.5.1/sr 4.0.3 field report): Modern PDF -- the
    // CLI's own default mode -- had this exact bug too, and worse: `--mode modern` runs
    // unless a document requests Printed, so the original b26 fix (Printed-only,
    // `lineOpsPrinted`'s `splitSymbolFallback`) left the DEFAULT export path emitting
    // literal '?' for this line. The fix (`symbolFallbackSplit`, shared by both paths via
    // `modernFlow`'s per-token loop) makes Modern match Printed exactly -- same Symbol
    // face, same per-character split, same bytes.
    for (mode, bodyFont): (EmitMode, String) in [(.printed, "Courier"), (.modern, "Times-Roman")] {
        let pdf = emitPDF(doc, mode: mode)
        let fonts = baseFonts(pdf)
        #expect(fonts.values.contains("Symbol"))
        let sym = try! #require(fontName(for: "Symbol", in: pdf))
        let body = try! #require(fontName(for: bodyFont, in: pdf))
        let shown = contentSpans(pdf)
        #expect(!shown.contains { $0.text.contains("?") })    // the whole point
        let sz = try! #require(shown.first { $0.font == sym && $0.text == "a" }?.size)
        // split exactly at the cp1252-representable ß/µ, same order as the source
        #expect(shown.contains { $0.font == sym && $0.size == sz && $0.text == "a" })
        #expect(shown.contains { $0.font == body && $0.size == sz && $0.text == "\u{00DF}" })
        #expect(shown.contains { $0.font == sym && $0.size == sz && $0.text == "GpSs" })
        #expect(shown.contains { $0.font == body && $0.size == sz && $0.text == "\u{00B5}" })
        #expect(shown.contains { $0.font == sym && $0.size == sz && $0.text == "tFQWdfe" })
    }

    let rPrinted = emitRTF(doc, mode: .printed)
    let rModern = emitRTF(doc, mode: .modern)
    // RTF was never routed through cp1252 at all (\uNNNN unicode escapes, this fix's
    // PDFWriter.swift/PDFModernLayout.swift never touched) -- alpha/Gamma/Sigma/Omega
    // present either way.
    #expect(rPrinted.contains(#"\u945"#) && rPrinted.contains(#"\u915"#))
    #expect(rModern.contains(#"\u945"#) && rModern.contains(#"\u915"#))
}

@Test func symbolFallbackSplitGeneralisesToZapfDingbats() {
    // `symbolFallbackSplit`/`symbolFallbackKind` answer `.math` (Symbol) OR `.symbols`
    // (ZapfDingbats), not just `.math` -- the same fallback this round wired into Modern
    // covers both faces a genuine `.symbol`/`.dingbat` font block already covers. Port of
    // ctrl-kd's `test_symbol_fallback_split_generalises_to_zapfdingbats`.
    //
    // Exercised directly on the helper rather than through a parsed WS document: cp437
    // (the only body encoding a real WordStar document carries) has no Dingbats
    // repertoire of its own outside the four `graphicChars` card-suit glyphs
    // (club/diamond/heart/spade, already vector fills -- deliberately excluded from this
    // path), so there is no cp437 byte sequence that reaches `symbolFallbackKind` with a
    // `.symbols` verdict via a parsed document. A real ZapfDingbats run reaches PDF only
    // through a document's own font block (`fontTranslitKind`, already covered by
    // `symbolRunStylingIsSynthesizedBoldItalicBoldItalic`'s sibling tests for both modes)
    // -- this test is the fallback CODE PATH's correctness, not a claim that today's
    // corpus can trigger it.
    let scissors = "\u{2701}"                        // U+2701 SCISSORS: real ZapfDingbats,
                                                       // no cp1252 code point, not graphicChars.
    #expect(symbolFallbackKind(Character(scissors)) == .symbols)
    #expect(!graphicChars.contains(Character(scissors)))
    // the four graphicChars card-suit glyphs stay vector fills, never diverted here, even
    // though `symbolFallbackKind` recognises their bytes too.
    for suit in "\u{2663}\u{2666}\u{2665}\u{2660}" {
        #expect(graphicChars.contains(suit))
        let pieces = symbolFallbackSplit(String(suit), family: .courier)
        #expect(pieces.count == 1 && pieces[0].text == String(suit) && pieces[0].family == .courier)
    }
    let text = "ok" + scissors + "done"
    let pieces = symbolFallbackSplit(text, family: .courier)
    #expect(pieces.map(\.text) == ["ok", untransliterate(scissors, .symbols), "done"])
    #expect(pieces.map(\.family) == [.courier, .zapfDingbats, .courier])
    // a piece mixing Symbol- and ZapfDingbats-fallback characters splits into three
    // pieces, not two -- the two encodings never merge into one run even though both
    // divert off the body face.
    let mixed = "a" + "\u{03B1}" + scissors           // 'a', alpha (Symbol), scissors
    let mixedPieces = symbolFallbackSplit(mixed, family: .courier)
    #expect(mixedPieces.map(\.text) == ["a", untransliterate("\u{03B1}", .math),
                                         untransliterate(scissors, .symbols)])
    #expect(mixedPieces.map(\.family) == [.courier, .symbol, .zapfDingbats])
}

@Test func symbolRunStylingIsSynthesizedBoldItalicBoldItalic() {
    // Finding 1 (b26-print-fidelity-2): Symbol has ONE cut in the base-14 set, so a
    // bold/italic span routed there used to lose its styling silently -- but real WS7
    // prints all four (plain/bold/italic/bold-italic) visibly distinct (measured:
    // -SCREEN.pcl offset 2767, the Greek sample line's four `ESC(s...T` groups carry
    // style=0/1 and weight=0/3 flags on the SAME typeface/height/pitch, and the four
    // runs measure the SAME 108pt advance for 14 glyphs regardless of style -- the
    // driver styled the glyph, never the advance). Pinned here bit-for-bit: bold adds
    // `2 Tr` (fill+stroke) with a stroke width proportional to size before `Ts`;
    // italic swaps `Td` for a sheared `Tm` (~12 degrees) at the SAME (x, y) `Td` would
    // have used; bold-italic does both. An unstyled Symbol run keeps its pre-existing
    // Td-only op, untouched.
    //
    // Finding 3 (b26 visual pass): italic-only now ALSO writes an explicit `0 Tr`
    // (Tr is graphics state that survives ET/BT, and this is the only place in
    // PDFWriter.swift that ever sets it, so the italic run used to silently inherit
    // the BOLD run's `2 Tr` stroke from earlier on the very same content stream
    // instead of getting the plain fill-only paint the real printer actually used).
    let greek: [UInt8] = [0xE0, 0xE2, 0xE3]   // cp437 alpha/Gamma/pi -> Symbol "aGp"
    var data = ws7Block(0x00)
    data += bytes("Plain prose padding so the detector reads this as a document.") + HARD
    data += greek + HARD
    data += boldOn + greek + boldOn + HARD
    data += italicOn + greek + italicOn + HARD
    data += boldOn + italicOn + greek + boldOn + italicOn + HARD
    data += bytes("And a closing line of ordinary prose keeps the ratio honest.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let text = latin1(pdf)

    // The four "(aGp)" text-show literals, in source order.
    var ranges: [Range<String.Index>] = []
    var searchFrom = text.startIndex
    while let r = text.range(of: "(aGp)", range: searchFrom..<text.endIndex) {
        ranges.append(r)
        searchFrom = r.upperBound
    }
    #expect(ranges.count == 4)

    // Each op's own "BT /Fn ... Tj ET" span, isolated by walking out from the literal.
    func op(_ i: Int) -> String {
        let r = ranges[i]
        let bt = text.range(of: "BT /F", options: .backwards,
                            range: text.startIndex..<r.lowerBound)!
        let etEnd = text.range(of: " Tj ET", range: r.upperBound..<text.endIndex)!.upperBound
        return String(text[bt.lowerBound..<etEnd])
    }
    let plain = op(0), bold = op(1), italic = op(2), boldItalic = op(3)

    // plain: untouched, the pre-existing Td-only shape -- no Tr/w/Tm at all.
    #expect(plain.contains("Td (aGp)"))
    #expect(!plain.contains("2 Tr") && !plain.contains("Tm ("))
    // bold: `2 Tr <w> w` before `Ts`, same Td shape as plain.
    #expect(bold.contains("2 Tr 0.48 w 0 Ts"))
    #expect(bold.contains("Td (aGp)"))
    #expect(!bold.contains("Tm ("))
    // italic: `Td` replaced by a sheared `Tm`, tan(12deg) ~= 0.2126 -- and (Finding 3)
    // an explicit `0 Tr` fill-only reset, no stroke width, so it can never inherit a
    // bold run's stroke left on the stream.
    #expect(italic.contains("0 Tr 0 Ts 1 0 0.2126 1 "))
    #expect(italic.contains("Tm (aGp)"))
    #expect(!italic.contains("2 Tr"))
    // bold-italic: both -- stroke AND shear.
    #expect(boldItalic.contains("2 Tr 0.48 w 0 Ts 1 0 0.2126 1 "))
    #expect(boldItalic.contains("Tm (aGp)"))

    // The three styled runs land at the SAME x the plain run did (styling changes only
    // how the glyph paints, never the run's own position).
    func xy(_ opText: String, marker: String) -> (String, String) {
        let tokens = opText.split(separator: " ").map(String.init)
        let idx = tokens.firstIndex(of: marker)!
        return (tokens[idx - 2], tokens[idx - 1])
    }
    let plainXY = xy(plain, marker: "Td")
    let boldXY = xy(bold, marker: "Td")
    let italicXY = xy(italic, marker: "Tm")
    #expect(boldXY.0 == plainXY.0)
    #expect(italicXY.0 == plainXY.0)
}

@Test func symbolRunStylingIsPrintedOnly() {
    // The synthesis lives in `PDFWriter.swift`'s Printed-only `lineOpsPrinted` (never
    // shared with Modern, which routes through its own token-font path instead) and
    // never fires for a Symbol run with no bold/italic styling (byte-identical
    // requirement).
    let greek: [UInt8] = [0xE0, 0xE2, 0xE3]
    var data = ws7Block(0x00)
    data += bytes("Plain prose padding so the detector reads this as a document.") + HARD
    data += boldOn + greek + boldOn + HARD
    data += bytes("And a closing line of ordinary prose keeps the ratio honest.") + HARD
    let doc = parseWS(data)
    let pdfPrinted = emitPDF(doc, mode: .printed)
    #expect(contains(pdfPrinted, bytes("2 Tr")))
    #expect(!contains(pdfPrinted, bytes("Tm (aGp) Tj")))
    let pdfModern = emitPDF(doc, mode: .modern)
    #expect(!contains(pdfModern, bytes("2 Tr")))
}
