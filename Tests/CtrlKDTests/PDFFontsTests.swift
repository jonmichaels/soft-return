/// Printed-mode base-14 fonts. Port of the tests ctrl-kd added in 9846771.
///
/// Jon's ruling, 2026-08-04: a PRINTED-mode PDF of a WS5+ document renders WordStar's exact
/// line breaks (it always did) PLUS the fonts the document chose, through the PDF base-14
/// built-ins -- no embedding, no dependencies. Modern mode stays Courier-only typewriter
/// setting. WS4 files and print streams carry no font blocks and are therefore Courier
/// automatically.
import Testing
@testable import CtrlKD

@Test func pdfFontlessDocumentsAreByteIdenticalToPreFontsOutput() {
    // THE regression that guards the whole feature: a document with no font runs -- every
    // WS4 file, every print stream, and most WS5+ documents -- must come out of emitPDF byte
    // for byte as it did before base-14 fonts existed here. These digests were taken from
    // THIS engine as it stood at de50744, the commit before the font work, and are the
    // proof, not a description of it: nothing about the new path may perturb a Courier page,
    // including the object numbering (which is why the Courier four are always emitted, used
    // or not -- see `FontResources`).
    //
    // They are also, as it happens, the same four digests the Python suite pins. Soft Return
    // and ctrl-kd are not obliged to agree byte for byte -- the cross-check compares text
    // formats and asserts PDF EQUIVALENCE, not identity -- so the agreement is an
    // observation about these four fixtures, not a contract. The pin is on this engine's own
    // output either way.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var styled = bytes("Plain ") + [0x02] + bytes("bold") + [0x02] + bytes(" ")
    styled += [0x13] + bytes("under") + [0x13] + bytes(" ")
    styled += bytes("and (word) here.") + HARD
    styled += bytes("More ordinary prose for the detector to chew on.") + HARD
    let stream: [UInt8] = bytes("Line one of printed page\r\nLine two\r\nLine three\r\n") + [0x1a]

    #expect(sha256Hex(emitPDF(parseWS(makeProse()), mode: .printed))
        == "ca74410ce6cdf27def1cc293b860b695b1745025505bf8af29c84acd322a08b8")
    #expect(sha256Hex(emitPDF(parseWS(makeProse()), mode: .modern))
        == "1e97def80007bd6578a0ab0910eeabcd883d7115b3369fb0660729280c18f69a")
    #expect(sha256Hex(emitPDF(parseWS(styled), mode: .printed))
        == "734aca69d48ddb539dcbd3699f9f3ddf9f46e8039508b7692a1680787fa7408f")
    #expect(sha256Hex(emitPDF(parsePrintstream(stream), mode: .printed))
        == "cd63c39b705acff2d8b2df84fde2f0a6ac28f9e2bcfed01ac75cfd9de9a98717")
}

@Test func sha256HelperMatchesTheStandardsOwnVectors() {
    // The digests above are only evidence if the digest function is right. FIPS 180-4's own
    // two worked examples, which a transcription error in the round constants or the padding
    // cannot survive.
    #expect(sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(sha256Hex(bytes("abc"))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func pdfPrintedRendersTheDocumentsOwnFontAndSize() {
    // Typestyle 4 is 'Helv' with the block's own generic bits saying sans, at 14pt (height
    // word 280 VMI = 14 points). Printed mode is a facsimile: it sets that run in Helvetica
    // at 14, from the file's own words. Modern mode is Courier by ruling and must show
    // neither.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("Before. ") + fontBlock(4, points: 14.0) + bytes("After.") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    #expect(doc.detection?.variant == .ws5plus)
    #expect(!doc.fonts.isEmpty)

    let pdf = emitPDF(doc, mode: .printed)
    // Streams are uncompressed: the text below is readable.
    #expect(!contains(pdf, bytes("/Filter")))
    let fonts = baseFonts(pdf)
    #expect(fonts.values.contains("Helvetica"))
    let helv = try! #require(fontName(for: "Helvetica", in: pdf))
    #expect(fonts["F1"] == "Courier")             // the four are still F1..F4
    let shown = contentSpans(pdf)
    // The block's own points, on the run that asked for them.
    #expect(shown.contains { $0.font == helv && $0.size == 14 && $0.text == "After." })
    #expect(shown.contains { $0.font == "F1" && $0.size == 12 && $0.text.hasPrefix("Before.") })

    let modern = emitPDF(doc, mode: .modern)
    #expect(!contains(modern, bytes("Helvetica")))
    #expect(contains(modern, bytes("/Courier")))
}

@Test func pdfSymbolRunSetsTheSymbolFaceWithItsOwnBytes() {
    // A Symbol/ZapfDingbats byte is a glyph index, transliterated to Unicode at parse time so
    // text formats need no font. PDF is the one consumer that HAS the font -- Symbol and
    // ZapfDingbats are in the base-14 set -- so the transliteration is undone and the original
    // codes go back on the page: 'a' with /Symbol selected IS alpha, in any viewer, with
    // nothing embedded.
    let symbolN = typestyleNames.firstIndex { asciiLowercased($0).hasPrefix("symbol") }
    let dingbatN = typestyleNames.firstIndex { asciiContains(asciiLowercased($0), "dingbat") }
    let sym = try! #require(symbolN)
    let ding = try! #require(dingbatN)
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Plain prose padding so the detector reads this as a document.") + HARD
    data += bytes("Greek: ") + fontBlock(sym) + bytes("abG")
    data += fontBlock(ding) + bytes("!\"#") + HARD
    data += bytes("And a closing line of ordinary prose keeps the ratio honest.") + HARD
    let doc = parseWS(data)
    let txt = emitText(doc, mode: .printed)
    #expect(txt.contains("αβΓ"))                  // text output: still Unicode
    #expect(txt.contains("✁✂✃"))

    let pdf = emitPDF(doc, mode: .printed)
    let fonts = baseFonts(pdf)
    #expect(fonts.values.contains("Symbol"))
    #expect(fonts.values.contains("ZapfDingbats"))
    let symName = try! #require(fontName(for: "Symbol", in: pdf))
    let dingName = try! #require(fontName(for: "ZapfDingbats", in: pdf))
    let shown = contentSpans(pdf)
    // alpha is back to 0x61 'a' — the ORIGINAL byte, drawn in the real face.
    #expect(shown.contains { $0.font == symName && $0.size == 12 && $0.text == "abG" })
    #expect(shown.contains { $0.font == dingName && $0.size == 12 && $0.text == "!\"#" })
}

@Test func pdfCourierBeatsTheGenericBitsThatCallItSerif() {
    // The trap this ordering exists for: the spec's own font block for Courier declares
    // generic style 'serif' -- honest typography (it is a slab serif) and true of 48 of the
    // 121 font blocks in the reference corpus. Reading the generic bits before the
    // fixed-pitch names would have set every Courier run in Times, the one substitution a
    // typescript facsimile must never make. Pica/Elite/LinePrinter go the same way.
    //
    // Python builds these from literal dicts; here a FontChange is decoded from the real
    // typestyle word, so the generic bits are set the way a file sets them: bits 10-11,
    // 0=sans 1=serif 2=script 3=display.
    func entry(_ name: String, _ generic: Int) -> FontChange {
        let number = typestyleNames.firstIndex { asciiLowercased($0).hasPrefix(asciiLowercased(name)) }!
        return FontChange(offset: 0, width1800: 180, height1440: 240,
                          typestyle: number | (generic << 10))
    }
    #expect(pdfFamily(entry("Courier", 1)) == .courier)      // ...declared serif, and is not
    #expect(pdfFamily(entry("Pica", 1)) == .courier)
    #expect(pdfFamily(entry("LinePrinter", 0)) == .courier)  // ...declared sans, and is not
    // Everything else resolves by the strict serif/sans/mono split (Jon's amendment: no
    // special flavouring for faces we cannot truly represent).
    #expect(pdfFamily(entry("Garamond", 1)) == .times)
    #expect(pdfFamily(entry("Univers", 0)) == .helvetica)
    #expect(pdfFamily(entry("ZapfChancery", 2)) == .times)   // script -> Times
    #expect(pdfFamily(entry("Univ. Roman", 3)) == .helvetica) // display -> Helvetica
    // Python's fifth case, `_pdf_family(None)`: no font run at all.
    #expect(pdfFamily(nil) == .courier)
}

@Test func base14SelectsAllFourVariantsAndSymbolHasNone() {
    // Bold and italic come ONLY from the span's own styles, and the index arithmetic is the
    // same one `pdfFont(bold:italic:)` uses -- a transposition here would swap italic for
    // bold on every proportional run and no other test would see it.
    #expect(base14(.times, bold: false, italic: false) == "Times-Roman")
    #expect(base14(.times, bold: true, italic: false) == "Times-Bold")
    #expect(base14(.times, bold: false, italic: true) == "Times-Italic")
    #expect(base14(.times, bold: true, italic: true) == "Times-BoldItalic")
    #expect(base14(.helvetica, bold: true, italic: true) == "Helvetica-BoldOblique")
    #expect(base14(.courier, bold: false, italic: true) == "Courier-Oblique")
    // Neither symbol face has variants in the base-14 set, so the roman stands in for all
    // four rather than the emitter inventing a synthetic oblique.
    #expect(base14(.symbol, bold: true, italic: true) == "Symbol")
    #expect(base14(.zapfDingbats, bold: true, italic: false) == "ZapfDingbats")
}

@Test func fontResourcesKeepsTheCourierFourAndAppendsFromF5() {
    // The byte-identity mechanism itself, stated directly rather than only through the
    // digests: /F1../F4 are Courier whether or not anything asks for them, and a new face
    // takes the next number instead of displacing one of them.
    let res = FontResources()
    #expect(res.fonts.map(\.name) == ["F1", "F2", "F3", "F4"])
    #expect(res.ref("Courier-Bold") == "F2")           // already there, not re-added
    #expect(res.fonts.count == 4)
    #expect(res.ref("Helvetica") == "F5")
    #expect(res.ref("Times-Roman") == "F6")
    #expect(res.ref("Helvetica") == "F5")              // first-use order, registered once
    #expect(res.fonts.map(\.baseFont).suffix(2) == ["Helvetica", "Times-Roman"])
}
