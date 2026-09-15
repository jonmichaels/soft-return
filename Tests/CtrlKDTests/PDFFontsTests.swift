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
    // for byte across unrelated feature work. First pinned at de50744 (pre-font emitter);
    // re-pinned ONCE on 2026-08-05 when `/Encoding /WinAnsiEncoding` was added to every text
    // font object -- a deliberate, global, single-line change to the font dictionaries
    // (cp1252 strings need the declared encoding; without it the base-14 built-in
    // StandardEncoding renders curly quotes and dashes as the wrong glyphs). Nothing else
    // about the fonts/colour/graphics work may perturb a Courier page, including the object
    // numbering (which is why the Courier four are always emitted, used or not -- see
    // `FontResources`).
    //
    // They are also, as it happens, the same four digests the Python suite pins (re-taken
    // there the same day, for the same reason). Soft Return and ctrl-kd are not obliged to
    // agree byte for byte -- the cross-check compares text formats and asserts PDF
    // EQUIVALENCE, not identity -- so the agreement is an observation about these four
    // fixtures, not a contract. The pin is on this engine's own output either way.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var styled = bytes("Plain ")
    styled += [0x02]
    styled += bytes("bold")
    styled += [0x02]
    styled += bytes(" ")
    styled += [0x13]
    styled += bytes("under")
    styled += [0x13]
    styled += bytes(" ")
    styled += bytes("and (word) here.") + HARD
    styled += bytes("More ordinary prose for the detector to chew on.") + HARD
    let stream: [UInt8] = bytes("Line one of printed page\r\nLine two\r\nLine three\r\n") + [0x1a]

    // Re-pinned a SECOND time 2026-08-20 (b26 round 26 wave 3, PRINTED hash only -- modern
    // is untouched): `printedTop` now folds `.hm` into a headerless document's top-of-text
    // offset (WS7 ground truth, see `printedTop`'s own docstring), moving this fixture's
    // body down 24pt. A real, evidenced, deliberate change to Printed geometry, not
    // incidental -- and, as it happens, the identical digest ctrl-kd's own re-pinned
    // fixture now carries.
    //
    // Re-pinned a THIRD time 2026-09-07 (PRINTED hashes only, again -- modern still
    // untouched: page numbering is a Printed-only feature; ported from ctrl-kd b6d5d03):
    // none of these fixtures touch `.pn`/`.pg`/`.op`/`.pc`, so `pgnumCheckpoints`'s
    // corrected default (ws7-prints/v3 finding #2, seeded ON to match stock WS7 instead of
    // Robert J. Sawyer's WSCHANGE-customized install) now adds a stock automatic page
    // number to each of them -- a real, evidenced, deliberate content change, not
    // incidental, and again the identical digest ctrl-kd's own re-pinned fixture carries.
    //
    // Re-pinned a FOURTH time 2026-09-07, same day (mechanism U, ctrl-kd
    // `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round, commit 26169cd):
    // `.mt` ALONE (36pt), not `.mt`+`.hm` (60pt), for a document that never sets its own
    // `.mt` -- see `printedTop`'s own doc comment. Moves the two default-`.mt` PRINTED
    // fixtures (`makeProse`, `styled`) up 24pt; the print-stream fixture is UNCHANGED
    // (`page == nil` -> the fixed `PDFMetrics.topPrinted` constant, never `.mt`-derived
    // either way).
    #expect(sha256Hex(emitPDF(parseWS(makeProse()), mode: .printed))
        == "267278729cfed03a1fecae8a90feb3c6102b43639be92b3eebdc0c658e74f5a6")
    // Modern's pin is RE-TAKEN (ruling 2026-08-05: "Modern PDF needs to be the printed
    // version of Modern RTF" — document fonts carried, proportional reflow, the
    // Courier-only Modern died with the WS4 lens). This exact digest is also what the
    // Python reference now pins for the identical fixture (`make_prose()` ==
    // `makeProse()`) — confirmed directly against Python, not merely copied: Modern PDF
    // parity is byte-for-byte here, though the cross-check contract only requires
    // equivalence, not identity (see this test's own header comment).
    //
    // Re-pinned a FIFTH time 2026-09-11 (MODERN hash only -- the Printed hashes here are
    // untouched): planning #263's page baseline model. A Modern line's baseline now sits one
    // face DESCENT above its own line box's bottom instead of on it (`modernDescent`), which
    // moves every Modern baseline on every document by that line's own descent -- here
    // 1.884pt, Courier at the 12pt this fixture sets. A deliberate, global, ruled change to
    // Modern geometry; the box ladder, the page breaks and every x are unchanged, which is
    // why only one of these four hashes moves. Again the identical digest ctrl-kd's own
    // re-pinned fixture carries (9fb1677).
    #expect(sha256Hex(emitPDF(parseWS(makeProse()), mode: .modern))
        == "cd3760328da8b4ffadd366e6d253a8e9cf3adbe1981fa68f7f1c5a8bc472c87b")
    // Re-pinned a SIXTH time 2026-09-14 (this `styled` PRINTED hash ONLY -- the other
    // three are untouched): a run that is all whitespace no longer gets a text-showing
    // op of its own (`lineOpsPrinted`, planning #270 item 39). Blanks put no ink on
    // paper in any face; the advance is unchanged and `rules` already drew nothing for
    // such a run, which is why only the ONE fixture that happens to contain a
    // whitespace-only span -- the single space between the bold and underlined words --
    // moves at all. Again the identical digest ctrl-kd's own re-pinned fixture carries.
    #expect(sha256Hex(emitPDF(parseWS(styled), mode: .printed))
        == "0f0797c238b8e8e347baa2eca89c3cfb363c8b1a38dc73a65acac2cb8df30472")
    #expect(sha256Hex(emitPDF(parsePrintstream(stream), mode: .printed))
        == "9dec7b10d0158a392bf684b63ff1e243f821a86194354b53f1095b23533c59f6")
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
    // at 14, from the file's own words. Modern mode CARRIES the document's fonts too now
    // (ruling 2026-08-05: Modern PDF is the printed form of Modern RTF) — the Courier-only
    // Modern died with the WS4 lens, so Helvetica shows there as well; the fontless run
    // reads in Times at the sophisticated size (14pt) instead of Courier. Proportional
    // bit set (ctrl-kd round 9): a real 'Helv' record is genuinely proportional, and
    // that flag is now what decides Helvetica vs Courier -- not the name alone.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("Before. ")
    data += fontBlock(4, points: 14.0, styleBits: 0x8000)
    data += bytes("After.")
    data += HARD
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
    #expect(contains(modern, bytes("Helvetica")))
    let modernShown = contentSpans(modern)
    #expect(modernShown.contains { $0.size == 14 && $0.text.contains("After.") })
    #expect(baseFonts(modern).values.contains("Times-Roman"))
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
    //
    // ctrl-kd round 9: proportional bit (0x8000) forced ON for every entry here,
    // INCLUDING the three genuinely fixed-pitch names (Courier/Pica/LinePrinter, whose
    // own real-world records would normally say proportional=false). The round-9
    // ruling makes that bit DECISIVE and checked FIRST, ahead of both the name list and
    // the generic-style bits this test exists to order against each other -- so with
    // the bit left at its default false, EVERY entry below (Courier included) would
    // resolve to Courier via tier 1 alone, and the tier-2-vs-tier-4 ordering this test
    // is actually about would never be reached. Setting it true here isolates exactly
    // that question; tier 1's own behavior has its own dedicated coverage elsewhere
    // (fontsTargetSelectsPrimariesAndGenericCoverage's mono-lint gate and the PDF NLQ
    // fixed-pitch tests).
    func entry(_ name: String, _ generic: Int) -> FontChange {
        let number = typestyleNames.firstIndex { asciiLowercased($0).hasPrefix(asciiLowercased(name)) }!
        return FontChange(offset: 0, width1800: 180, height1440: 240,
                          typestyle: number | (generic << 10) | 0x8000)
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

@Test func printedFontBlockLeadingIsCarriedThroughBlanksAndResetByFixedPitch() throws {
    // WS7's auto-leading, MEASURED on the real harness 2026-09-14 (planning #270 item 34
    // / triage Q4; see `fontLeadPt`'s own doc comment for the probe). A line's advance is
    // the max of the size carried out of the line before it and every font size declared
    // on it; what a line carries out is its LAST span's size when that font is
    // PROPORTIONAL and the document default otherwise.
    //
    // The expected leads below are UNCHANGED by that measurement — this fixture's shape
    // reads the same under both models — but the `.lh a` line at the top is new and is
    // the point: auto-leading is a MODE a document turns on, not a state inferred from
    // the presence of proportional fonts. Without it every lead here is the flat 12.
    //
    // Reading them one at a time: "Intro line." has no tag and nothing has carried, so it
    // takes the document default. "Prop line." raises its OWN line to 20 (the max rule,
    // not "the line after it") and carries 20 out. The blank has no spans at all, so it
    // carries that 20 through and advances by it. "Fixed line."'s own 12 loses the max
    // against the carried 20 — so its own line is still 20 — and a FIXED-PITCH font
    // carries NOTHING out, which is what drops "After fixed." back to the default.
    // PREVIEW.WS is the corpus oracle for that last step: six blank lines after its
    // trailing Courier-20pt line advance at 12, not 20.
    let prop = fontBlock(0, points: 20.0, styleBits: 0x8000)     // proportional, 20pt
    let fixed = fontBlock(1, points: 12.0, styleBits: 0)         // fixed-pitch (Courier), 12pt
    var data = bytes(".lh a") + HARD                             // auto-leading: the gate
    data += bytes("Intro line.") + HARD
    data += prop + bytes("Prop line.") + HARD
    data += HARD                                                  // blank: carries state forward
    data += fixed + bytes("Fixed line.") + HARD
    data += bytes("After fixed.") + HARD
    data += [0x1a]
    let doc = parseWS(data)
    #expect(doc.fonts.count == 2)
    #expect(doc.fonts[0].proportional)
    #expect(!doc.fonts[1].proportional)

    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1)
    let leads = pages[0].map { $0.lead }
    // `12.0 * autoLeadFactor` rather than a bare literal, matching the real Python
    // reference's own computed value (`12 * AUTO_LEAD_FACTOR`) -- at stock's 1.0 factor
    // this is exactly 12.0 (no floating-point residue the way `12 * 1.2` had under
    // Sawyer's install; mechanism T).
    let flat = 12.0 * autoLeadFactor
    #expect(leads == [flat, 20.0, 20.0, 20.0, flat])
    // And the mode is the whole of it: the identical bytes without `.lh a` lay flat.
    var plain = bytes("Intro line.") + HARD
    plain += prop + bytes("Prop line.") + HARD
    plain += HARD
    plain += fixed + bytes("Fixed line.") + HARD
    plain += bytes("After fixed.") + HARD
    plain += [0x1a]
    let plainLeads = docToPagelines(parseWS(plain), printed: true)[0].map { $0.lead }
    #expect(plainLeads.allSatisfy { $0 == nil || $0 == flat }, "\(plainLeads)")
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
