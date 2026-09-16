import Foundation
import Testing
@testable import CtrlKD

/// The two WS7 style rulings of 2026-09-16, Swift side. Byte-for-byte the same behaviour
/// ctrl-kd's `tests/test_style_symbol_map_resolved_face.py` and
/// `tests/test_style_strikeout_runs_until_cleared.py` pin, built from the same synthetic
/// fixtures. No corpus file is read here.
///
/// ## 1. A resolved ordinary typeface beats the character-set bits
///
/// A WS5+ font record's typestyle word carries two independent fields: the low nine bits
/// name a typeface out of WSFORMAT's 245-entry table, and bits 12-13 pick one of four
/// upper-128 character sets (cp437, cp850, math, symbols). `fontTranslitKind` used to let
/// the character-set bits overrule ANY name that did not itself say "symbol" or "dingbat",
/// so a record reading "Courier, math character set" redirected its whole run through Adobe
/// Symbol's encoding and every ordinary Latin letter came out as the Greek letter sitting
/// at its keyboard position. A WS7 manuscript in the private corpus carries exactly that
/// record on its front-matter styles, and real WS7's own LaserJet output prints those pages
/// as plain readable Courier.
///
/// ## 2. A style-library strikeout runs until a style clears it
///
/// WSFORMAT.TXT on the two attribute words: "if both corresponding bits are off, then the
/// attribute is inherited from the current state". A style that sets the strikeout bit
/// starts a run that only a later style's own `attrsOff` word ends; both engines used to
/// end it with the styled paragraph. The WS7 capture of the affected manuscript strikes all
/// 52 pages. Applied to strikeout ONLY (`stickyStyleAttrs`) -- see the last test for the
/// scope and the question left open.

private let HARDRET: [UInt8] = [0x0D, 0x0A]

// Typestyle words, field by field from `FontChange`'s own bit readers.
private let MATH_BITS = 2 << 12
private let LQ = 0x4000
private let COURIER_MATH = 3 | MATH_BITS | LQ          // the real corpus word, 0x6603
private let SYMBOL_MATH = 192 | MATH_BITS | LQ
private let DINGBATS_MATH = 82 | MATH_BITS | LQ
private let UNNAMED_MATH = 300 | MATH_BITS | LQ        // past the 245-entry name table

private func fontFor(_ typestyle: Int) -> FontChange {
    FontChange(offset: 0, width1800: 180, height1440: 240, typestyle: typestyle)
}

private func docInFace(_ typestyle: Int, text: String) -> Document {
    // `fontBlock` takes the typeface number and the high bits separately.
    let block = fontBlock(typestyle & 0x01FF, points: 12.0, styleBits: typestyle & ~0x01FF)
    var data = ws7Block(0x00)
    data += block
    data += bytes(text)
    data += HARDRET
    return parseWS(data)
}

// ------------------------------------------------------------------ ruling 1: the verdict

@Test func resolvedOrdinaryFaceIgnoresTheCharacterSetBits() {
    #expect(fontTranslitKind(fontFor(COURIER_MATH)) == nil)
}

@Test func namedSymbolFaceStillTransliterates() {
    // The name is still the specific signal, and the reason it is read BEFORE the bits: a
    // Dingbats row whose coarse bits read 'math' must transliterate as Dingbats, not Greek.
    #expect(fontTranslitKind(fontFor(SYMBOL_MATH)) == .math)
    #expect(fontTranslitKind(fontFor(DINGBATS_MATH)) == .symbols)
}

@Test func unresolvedFaceStillFallsBackToTheBits() {
    #expect(fontFor(UNNAMED_MATH).typestyleName == nil)
    #expect(fontTranslitKind(fontFor(UNNAMED_MATH)) == .math)
}

@Test func namedNonTextRepertoireStillFallsBackToTheBits() {
    // 'Math', 'PI' and 'Greek' name a glyph repertoire, not a typeface a sentence can be
    // set in -- they are not ordinary faces and do not win over the bits.
    for number in [188, 166, 244] {
        #expect(fontTranslitKind(fontFor(number | MATH_BITS | LQ)) == .math,
                "typestyle \(number)")
    }
}

@Test func courierMathProseStaysLatinInEveryFormat() {
    let prose = "If you choose to depict the physicist on the cover"
    for mode in [EmitMode.printed, .modern] {
        let doc = docInFace(COURIER_MATH, text: prose)
        let outputs: [(String, String)] = [
            ("text", emitText(doc, mode: mode)),
            ("markdown", emitMarkdown(doc, mode: mode)),
            ("html", emitHTML(doc, mode: mode)),
            ("rtf", emitRTF(doc, mode: mode)),
            ("layout", emitLayout(doc, mode: mode)),
        ]
        for (name, text) in outputs {
            #expect(text.contains("If you choose"), "\(name)/\(mode): prose is not Latin")
            let greek = text.unicodeScalars.contains { $0.value >= 0x0370 && $0.value <= 0x03FF }
            #expect(!greek, "\(name)/\(mode): a Greek code point reached the output")
        }
    }
}

// --------------------------------------------------------------- ruling 2: the model

private let STRIKE_BIT = 0x01
private let BOLD_BIT = 0x40
/// The real corpus shape: an attrs_off word that clears everything EXCEPT strikeout (and
/// the spec's own unlabelled 0x04 bit).
private let CLEARS_ALL_BUT_STRIKE = 0xFA
private let CLEARS_EVERYTHING = 0xFB

private let PLAIN_TEXT = "Plain paragraph before any styled one at all."
private let STRUCK_TEXT = "The styled heading that turns strikeout on."
private let AFTER_TEXT = "The following paragraph, whose own style never clears it."
private let CLEARED_TEXT = "The paragraph whose style does clear it again."

private func strikeLibrary() -> [UInt8] {
    styleLibrary([
        (name: "Plain", record: styleRecord(inheritTabs: true, attrsOn: 0,
                                            attrsOff: CLEARS_ALL_BUT_STRIKE)),
        (name: "Struck", record: styleRecord(inheritTabs: true,
                                             attrsOn: STRIKE_BIT | BOLD_BIT,
                                             attrsOff: CLEARS_ALL_BUT_STRIKE & ~BOLD_BIT)),
        (name: "Clears", record: styleRecord(inheritTabs: true, attrsOn: 0,
                                             attrsOff: CLEARS_EVERYTHING)),
    ])
}

/// One `styleRef` + its paragraph text + a blank line, as bytes.
private func styledParagraph(_ slot: Int, _ text: String) -> [UInt8] {
    var out = styleRef(slot)
    out += bytes(text)
    out += HARDRET
    out += HARDRET
    return out
}

private func runDoc() -> Document {
    // Plain -> Struck -> Plain (inherits the run) -> Clears (ends it).
    var body = styledParagraph(0, PLAIN_TEXT)
    body += styledParagraph(1, STRUCK_TEXT)
    body += styledParagraph(0, AFTER_TEXT)
    body += styleRef(2)
    body += bytes(CLEARED_TEXT)
    body += HARDRET
    return parseWS(documentWithStyleLibrary(body: body, library: strikeLibrary()))
}

private func blockFor(_ doc: Document, _ text: String) -> Block {
    let wanted = String(text.prefix(20))
    guard let block = doc.blocks.first(where: {
        $0.lines.map { $0.text() }.joined().contains(wanted)
    }) else {
        Issue.record("no block carrying \(wanted)")
        return doc.blocks[0]
    }
    return block
}

@Test func strikeRunStartsContinuesAndEndsOnTheBlocks() {
    let doc = runDoc()
    #expect(!blockFor(doc, PLAIN_TEXT).styleAttrs.contains(.strike),
            "strikeout before the style that turns it on")
    #expect(blockFor(doc, STRUCK_TEXT).styleAttrs.contains(.strike),
            "the style that turns strikeout on did not")
    #expect(blockFor(doc, AFTER_TEXT).styleAttrs.contains(.strike),
            "the run stopped at the styled paragraph instead of continuing")
    #expect(!blockFor(doc, CLEARED_TEXT).styleAttrs.contains(.strike),
            "a style setting 0x01 in attrs_off did not end the run")
}

@Test func unresolvableStyleHandleInheritsRatherThanResets() {
    // A 0x03xx editing-temp handle declares neither attribute word, so every attribute
    // inherits -- the same sentence of the spec, where there is no record to read.
    var handle = le16(0x0301)
    handle += le16(0x0301)
    handle += le16(0x0301)
    handle += le16(0x0301)
    var body = styledParagraph(1, STRUCK_TEXT)
    body += ws7Block(0x11, payload: handle)
    body += bytes(AFTER_TEXT)
    body += HARDRET
    let doc = parseWS(documentWithStyleLibrary(body: body, library: strikeLibrary()))
    #expect(blockFor(doc, AFTER_TEXT).styleAttrs.contains(.strike))
}

// ------------------------------------------------- ruling 2: one rule, every format

/// The `{...}` character-run group carrying `needle` -- RTF's own scope for a run's
/// attributes, so the assertion reads exactly one run.
private func rtfGroup(_ body: String, _ needle: String) -> String {
    guard let hit = body.range(of: needle),
          let open = body.range(of: "{", options: .backwards, range: body.startIndex..<hit.lowerBound),
          let close = body.range(of: "}", range: hit.upperBound..<body.endIndex)
    else { return "" }
    return String(body[open.lowerBound..<close.upperBound])
}

/// The opening tag of the element carrying `needle`.
private func htmlTag(_ body: String, _ needle: String) -> String {
    guard let hit = body.range(of: needle),
          let open = body.range(of: "<", options: .backwards, range: body.startIndex..<hit.lowerBound),
          let close = body.range(of: ">", range: open.upperBound..<body.endIndex)
    else { return "" }
    return String(body[open.lowerBound..<close.upperBound])
}

@Test func rtfMarksTheInheritedParagraphStruck() {
    for mode in [EmitMode.printed, .modern] {
        let body = emitRTF(runDoc(), mode: mode)
        #expect(rtfGroup(body, "never clears").contains("\\strike"),
                "\(mode): the inherited paragraph carries no \\strike")
        #expect(!rtfGroup(body, "does clear it again").contains("\\strike"),
                "\(mode): the run did not end at the clearing style")
    }
}

@Test func htmlMarksTheInheritedParagraphStruck() {
    for mode in [EmitMode.printed, .modern] {
        let body = emitHTML(runDoc(), mode: mode)
        // HTML's paragraph attributes ride a CSS class keyed to the STYLE SLOT, so an
        // attribute inherited from an EARLIER style needs its own class
        // (`inheritedAttrCSS`) -- the slot's own rule cannot carry it.
        #expect(body.contains(".ws-inherit-strike { text-decoration:line-through }"),
                "\(mode): no CSS rule for the inherited run")
        #expect(htmlTag(body, "never clears").contains("ws-inherit-strike"),
                "\(mode): the inherited paragraph is not marked struck")
        #expect(!htmlTag(body, "does clear it again").contains("ws-inherit-strike"),
                "\(mode): the run did not end at the clearing style")
    }
}

@Test func layoutJSONCarriesTheInheritedRun() {
    for mode in [EmitMode.printed, .modern] {
        let body = emitLayout(runDoc(), mode: mode)
        let hits = body.components(separatedBy: "\"strike\"").count - 1
        #expect(hits >= 2,
                "\(mode): fewer struck runs than the styled paragraph plus the one it runs into")
    }
}

@Test func markdownModernMarksTheInheritedParagraphStruck() {
    // Modern Markdown carries character attributes; PRINTED Markdown is a verbatim
    // monospace page inside a fence and has no inline markers at all, in either
    // behaviour -- there is nothing for this rule to change there.
    let body = emitMarkdown(runDoc(), mode: .modern)
    guard let line = body.split(separator: "\n").first(where: { $0.contains("never clears") })
    else {
        Issue.record("no line carrying the inherited paragraph")
        return
    }
    #expect(line.trimmingCharacters(in: .whitespaces).hasPrefix("~~"),
            "no strikethrough markers: \(line)")
}

@Test func textOutputIsUnaffectedAndStillCarriesTheWords() {
    // Plain text has no representation for strikeout in either behaviour -- named here so
    // the format is not silently missing from the list above.
    let body = emitText(runDoc(), mode: .printed)
    for sample in [PLAIN_TEXT, STRUCK_TEXT, AFTER_TEXT, CLEARED_TEXT] {
        #expect(body.contains(String(sample.prefix(20))))
    }
}

// ----------------------------------------------------------------- ruling 2: the scope

@Test func onlyStrikeoutIsSticky() {
    // The narrow scope, pinned. Bold here is turned on by one style and never cleared by
    // the next one's attrs_off, and it still must NOT carry: no WS7 capture in the corpus
    // can show whether real WordStar would carry it, so the rule is not extended to bold,
    // underline or italic on a guess. Widening `stickyStyleAttrs` means finding a capture
    // that settles it.
    #expect(stickyStyleAttrs.count == 1)
    #expect(stickyStyleAttrs[0].bit == 0x01 && stickyStyleAttrs[0].style == Style.strike)
    let library = styleLibrary([
        (name: "Bold", record: styleRecord(inheritTabs: true, attrsOn: BOLD_BIT, attrsOff: 0)),
        (name: "Next", record: styleRecord(inheritTabs: true, attrsOn: 0, attrsOff: 0)),
    ])
    var body = styledParagraph(0, STRUCK_TEXT)
    body += styleRef(1)
    body += bytes(AFTER_TEXT)
    body += HARDRET
    let doc = parseWS(documentWithStyleLibrary(body: body, library: library))
    #expect(blockFor(doc, STRUCK_TEXT).styleAttrs.contains(.bold))
    #expect(!blockFor(doc, AFTER_TEXT).styleAttrs.contains(.bold),
            "bold carried past its own paragraph -- the scope was widened silently")
}
