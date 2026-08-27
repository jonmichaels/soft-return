import Testing
@testable import CtrlKD

/// Five rulings, 2026-08-24 (WordStar-Feature-Decision-Register.md rows for
/// 2026-08-23/2026-08-24), ported from `tests/test_note_rulings_20260824.py`:
///
///   1. Collision-triggered continuous renumbering for footnotes/endnotes in TXT, MD,
///      HTML (the three page-less formats) -- ONLY when WordStar's own per-page-reset
///      numbers actually collide within a kind. Printed, Modern PDF, and RTF must never
///      renumber.
///   2. Modern PDF note ENTRY labels drop the brackets: `1.` (footnote), `i.` (endnote)
///      -- no brackets, no superscript on the entry.
///   3. TXT note markers: `[N]` footnotes, `(N)` endnotes, inline and in the entry --
///      same wrapper both places.
///   4. Note TAGS (WSFORMAT.TXT high-bit-on-high-bit case): a footnote/endnote can carry
///      a user MARK instead of a number. Display it, never renumber it. NO ARCHIVE
///      SPECIMEN CARRIES ONE -- synthetic fixtures only, never verified against real
///      WordStar behaviour.
///   5. Note FORMAT TYPES (conversion-flag high nybble): 0 symbols, 1 upper, 2 lower,
///      3 numeric. Briefly honoured for footnote/endnote display, then REVERTED:
///      `DISPLAY.WS`, WordStar's own tutorial file, carries a footnote at
///      numberFormat=2 and an endnote at numberFormat=1, and real WordStar 7 (printed
///      under DOSBox-X) renders both as plain arabic. `Note.numberFormat` stays parsed
///      but is no longer consulted for display; the label is always arabic.
///
/// This repo carries no private WS7 corpus fixture equivalent to the private WS7
/// specimen the Python port uses
/// (CLAUDE.md: engine coding here works from synthetic byte fixtures only), so unlike
/// the Python port there is no real-specimen collision test to gate behind an env var --
/// every case here is a hand-built byte fixture.

// =========================== item 4: note tags ==============================

@Test func footnoteTagIsCapturedAndHasNoNumber() {
    let data = ws7NoteTagged(cmd: 0x03, text: bytes("A marked footnote."), tagText: bytes("STAR"))
    let doc = parseWS(data)
    let note = doc.notes[0]
    #expect(note.kind == .footnote)
    #expect(note.tag == "STAR")
    #expect(note.number == nil)
    #expect(note.text == "A marked footnote.")
    #expect(note.numberFormat == 0 && note.convertTo == 0)   // spec: unused with a tag
}

@Test func endnoteTagIsCapturedAndHasNoNumber() {
    let data = ws7NoteTagged(cmd: 0x04, text: bytes("A marked endnote."), tagText: bytes("DAGGER"))
    let doc = parseWS(data)
    let note = doc.notes[0]
    #expect(note.kind == .endnote)
    #expect(note.tag == "DAGGER")
    #expect(note.number == nil)
}

@Test func taggedFootnoteDisplaysTagAndIsImmuneToCollisionRenumbering() {
    // Two PLAIN footnotes stored as 0 (a real collision) plus one TAGGED footnote in
    // between. The plain pair must renumber continuously; the tagged one must show its
    // mark, untouched, in every format, and must not itself trigger or absorb any
    // renumbering.
    var data = ws7Block(0x00) + bytes("one")
    data += ws7Note(bytes("Plain one."), cmd: 0x03, number: 0)
    data += bytes(" two")
    data += ws7NoteTagged(cmd: 0x03, text: bytes("Marked one."), tagText: bytes("STAR"))
    data += bytes(" three")
    data += ws7Note(bytes("Plain two."), cmd: 0x03, number: 0)
    data += bytes(" end.") + HARD
    let doc = parseWS(data)
    let t = emitText(doc, mode: .modern)
    #expect(t.contains("[1] Plain one."))
    #expect(t.contains("[STAR] Marked one."))
    #expect(t.contains("[2] Plain two."))
    let md = emitMarkdown(doc, mode: .modern)
    #expect(md.contains("[^1]: Plain one.") && md.contains("[^2]: Plain two."))
    let h = emitHTML(doc, mode: .modern)
    #expect(h.contains("id=\"fn1\"") && h.contains("id=\"fn2\"") && h.contains("id=\"fnSTAR\""))
}

@Test func rtfTaggedFootnoteUsesCustomMarkNotChftn() {
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("A marked reference")
    data += ws7NoteTagged(cmd: 0x03, text: bytes("A marked footnote."), tagText: bytes("STAR"))
    data += bytes(" continues after.") + HARD
    let doc = parseWS(data)
    let r = emitRTF(doc, mode: .modern)
    #expect(r.contains(#"{\super STAR}"#))
    #expect(!r.contains(#"\chftn"#))     // never auto-numbered once tagged
}

// ====================== item 5: note format types ===========================

@Test func symbolCycleMatchesClassicalSequenceAndDoublesPastSix() {
    #expect((1...6).map(noteSymbol) == ["*", "\u{2020}", "\u{2021}", "\u{00A7}", "\u{2016}", "\u{00B6}"])
    #expect(noteSymbol(7) == "**")
    #expect(noteSymbol(13) == "***")
}

@Test func alphaLabelIsBijectiveBase26() {
    #expect(alphaLabel(1, upper: false) == "a")
    #expect(alphaLabel(26, upper: false) == "z")
    #expect(alphaLabel(27, upper: false) == "aa")
    #expect(alphaLabel(1, upper: true) == "A")
}

/// WordStar's format spec documents a conversion-flag high nybble (0 symbols / 1 upper /
/// 2 lower / 3 numeric) and we briefly honoured it (ruling 2026-08-24 item 5).
///
/// REAL WORDSTAR 7 DISPROVED THAT. `DISPLAY.WS` -- WordStar's own tutorial file in the
/// archive -- carries a footnote at numberFormat=2 and an endnote at numberFormat=1.
/// Printed through real WS7 under DOSBox-X it puts `1.` and `(1)` on the page: plain
/// arabic, exactly like every other document. Capture: `ws7-prints/ws7-captures/DISPLAY.pcl`.
///
/// So the label is ALWAYS arabic. The field stays parsed -- preserve-what-you-find
/// governs the IR -- and is simply not consulted for display.
@Test func numberFormatIsNotHonouredGroundTruthSaysArabic() {
    for fmt in [0, 1, 2, 3, 9] {
        #expect(formatNoteNumber(1, fmt) == "1")
        #expect(formatNoteNumber(7, fmt) == "7")
    }
}

@Test func aNonnumericFormatCodeStillRendersArabicEverywhere() {
    // The same ground truth, end to end: a note carrying a non-numeric format code
    // renders arabic in the actual output, not a symbol or a letter.
    let data = ws7Block(0x00) + bytes("ref")
        + ws7Note(bytes("Symbol note."), cmd: 0x03, number: 0, numberFormat: 0)
        + bytes(" end.") + HARD
    let doc = parseWS(data)
    let t = emitText(doc, mode: .modern)
    #expect(t.contains("[1] Symbol note."))
    #expect(!t.contains("[*]") && !t.contains("[A]") && !t.contains("[a]"))
}

@Test func modernEndnoteWithAFormatCodeStillRomanizesNormally() {
    // A non-numeric format code must not disturb Modern's lower-roman endnote labels:
    // the code is ignored, the label stays arabic underneath, and `endnoteRomanLabel`
    // romanizes it exactly as it would any other. (Before ground truth, this test
    // asserted `A.` -- WordStar itself prints arabic for such a note, so `i.` is
    // correct here.)
    let data = ws7Block(0x00) + bytes("ref")
        + ws7Note(bytes("Alpha endnote."), cmd: 0x04, number: 0, numberFormat: 1)
        + bytes(" end.") + HARD
    let doc = parseWS(data)
    let words = contentSpans(emitPDF(doc, mode: .modern)).map(\.text)
    #expect(words.contains("i."))
    #expect(!words.contains("A."))
}

// ============ item 1: collision-triggered pageless renumbering ==============

@Test func noCollisionLeavesStoredNumbersUntouched() {
    // Simulates a `.F#`-consecutive document: two footnotes with DIFFERENT stored
    // numbers already display distinctly and must NOT be forced into 1, 2 -- collision
    // is the only trigger.
    var data = ws7Block(0x00) + bytes("one") + ws7Note(bytes("First."), cmd: 0x03, number: 0)
    data += bytes(" two") + ws7Note(bytes("Second."), cmd: 0x03, number: 5)
    data += bytes(" end.") + HARD
    let doc = parseWS(data)
    let t = emitText(doc, mode: .modern)
    #expect(t.contains("[1] First.") && t.contains("[6] Second."))
}

@Test func collisionRenumbersTxtMdHtmlButNotPrintedModernPDFRTF() {
    var data = ws7Block(0x00) + bytes("one") + ws7Note(bytes("First."), cmd: 0x03, number: 0)
    data += bytes(" two") + ws7Note(bytes("Second."), cmd: 0x03, number: 0)
    data += bytes(" end.") + HARD
    let doc = parseWS(data)

    let t = emitText(doc, mode: .modern)
    #expect(t.contains("[1] First.") && t.contains("[2] Second."))

    let md = emitMarkdown(doc, mode: .modern)
    #expect(md.contains("[^1]: First.") && md.contains("[^2]: Second."))

    let h = emitHTML(doc, mode: .modern)
    #expect(countOccurrencesOfSubstring("id=\"fn1\"", in: h) == 1)
    #expect(countOccurrencesOfSubstring("id=\"fn2\"", in: h) == 1)
    #expect(countOccurrencesOfSubstring("id=\"fnref1\"", in: h) == 1)
    #expect(countOccurrencesOfSubstring("id=\"fnref2\"", in: h) == 1)

    let ptexts = contentSpans(emitPDF(doc, mode: .printed)).map(\.text).joined(separator: " ")
    #expect(ptexts.contains("First.") && ptexts.contains("Second."))
    #expect(!ptexts.contains("2."))                     // WS7's own number: both "1."

    let mtexts = contentSpans(emitPDF(doc, mode: .modern)).map(\.text).joined(separator: " ")
    #expect(mtexts.contains("First.") && mtexts.contains("Second."))
    #expect(!mtexts.contains("2."))                     // unrenumbered here too

    let r = emitRTF(doc, mode: .modern)
    // unstarred (ruling 2026-08-26, mirrored from ctrl-kd 47b7049): a `\footnote`
    // destination, no `\*`.
    #expect(countOccurrencesOfSubstring(#"\footnote"#, in: r) == 2)
    #expect(!r.contains(#"\*\footnote"#))
    #expect(countOccurrencesOfSubstring(#"\chftn"#, in: r) >= 2)
}

// ================ item 2: Modern PDF entry labels, no brackets ==============

@Test func modernPDFFootnoteAndEndnoteEntriesDropBrackets() {
    var data = ws7Block(0x00) + bytes("ref one") + ws7Note(bytes("Foot body."), cmd: 0x03, number: 0)
    data += bytes(" ref two") + ws7Note(bytes("End body."), cmd: 0x04, number: 0)
    data += bytes(" end.") + HARD
    let doc = parseWS(data)
    let words = contentSpans(emitPDF(doc, mode: .modern)).map(\.text)
    #expect(words.contains("1."))                       // footnote entry: arabic + period
    #expect(words.contains("i."))                        // endnote entry: lower-roman + period
    #expect(!words.contains("[1]") && !words.contains("[i]"))
}

@Test func modernPDFAnnotationEntryKeepsBracketsUnaffectedByRuling() {
    // The ruling named only footnote/endnote appearance; an annotation's tag-based
    // entry must stay exactly as it was.
    var data = ws7Block(0x00) + bytes("ref")
    data += ws7AnnotationWithTag(dotLines: [bytes(".. aside")], text: bytes("Anno body."),
                                 tagText: bytes("AC1"))
    data += bytes(" end.") + HARD
    let doc = parseWS(data)
    let words = contentSpans(emitPDF(doc, mode: .modern)).map(\.text)
    #expect(words.contains("[AC1]"))
}

// ==================== item 3: TXT [N] footnote, (N) endnote =================

@Test func txtFootnoteBracketEndnoteParenInlineAndEntry() {
    var data = ws7Block(0x00) + bytes("foot here") + ws7Note(bytes("Foot body."), cmd: 0x03, number: 0)
    data += bytes(" end here") + ws7Note(bytes("End body."), cmd: 0x04, number: 0)
    data += bytes(" done.") + HARD
    let doc = parseWS(data)
    let t = emitText(doc, mode: .modern)
    #expect(t.contains("foot here[1] end here(1) done."))
    #expect(t.contains("Footnotes:\n[1] Foot body."))
    #expect(t.contains("Endnotes:\n(1) End body."))
}

// MARK: - helpers

/// Non-overlapping occurrences of a literal substring -- the String equivalent of this
/// file's `[UInt8]`-based `countOccurrences`, needed here since `emitHTML`/`emitRTF`
/// return `String`, not bytes.
private func countOccurrencesOfSubstring(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}
