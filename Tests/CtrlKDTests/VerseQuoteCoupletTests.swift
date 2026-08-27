import Testing
@testable import CtrlKD

/// b26-modern item 5 (ctrl-kd d686f8b): a quoted verse couplet (two short, hard-
/// terminated, identically-indented lines forming ONE quotation that merely spans two
/// lines) was misclassified as prose by `looksLikeVerse`'s quote-opening veto, so
/// Modern inserted full paragraph spacing between the two lines instead of tight verse
/// spacing.
///
/// ROOT CAUSE (real corpus, WARPRAYR.WS — Mark Twain's "The War Prayer", the hymn
/// couplet '"God the all-terrible! Thou who ordainest, / Thunder thy clarion and
/// lightning thy sword!"'): `verseQuoteVetoFraction`'s veto counted ANY line starting
/// with a quote mark (`opensQuote`) toward its fraction, without checking whether that
/// line's quotation was ALSO CLOSED on the same line. For this couplet, only line 1
/// opens with `"` (1-of-2 = 0.5), comfortably past the 1/3 veto bar — but that single
/// opening line does not itself close the quotation; the quotation spans into line 2,
/// which is exactly what a genuine multi-line quoted passage (hymn, poem, prose
/// excerpt) looks like, NOT what real spoken dialogue looks like. The veto's own
/// calibration evidence (`ModernLintGateTests.swift`'s
/// `ws4DialogueRunDoesNotFalsePositiveAsStanza` fixtures, '"Where are you going?"' /
/// '"I already told you."') is entirely SELF-CONTAINED quotes — each opens AND closes
/// on its own single line.
///
/// FIX (general, not WARPRAYR-specific): `selfContainedQuote` requires both an opening
/// AND a closing quote mark on the SAME line before a line counts toward the veto
/// fraction. A line that only opens a quotation (the passage continues past it) no
/// longer single-handedly vetoes a verse read; self-contained dialogue lines are
/// unaffected.
///
/// Synthetic fixtures only (CLAUDE.md), reproducing the couplet's exact real shape: a
/// WS7-format document (`ws7Block`) — both lines carry the SAME 10-space indent, so
/// Phase 1 of `assembleParagraphUnits` already splits them into two 1-line units, and
/// Phase 2's short-run reconsideration (`looksLikeVerse`) is what is being tested.
/// Port of ctrl-kd's `tests/test_verse_quote_couplet.py`.

private func typedParagraphDoc(_ lines: [[UInt8]]) -> Document {
    // A WS7-format document (header record present, no style library needed): one
    // Block, `lines` as hard-return-terminated typed paragraphs — same helper shape as
    // `ModernLintGateTests.swift`'s own WS4 fixtures, but WS7-framed (the real
    // WARPRAYR.WS shape).
    var data = ws7Block(0x00)
    for (i, line) in lines.enumerated() {
        if i > 0 { data += HARD }
        data += line
    }
    data += HARD
    return parseWS(data)
}

@Test func quotedCoupletSpanningTwoLinesReadsAsVerse() throws {
    // The exact regression shape: two 10-space-indented lines, together forming ONE
    // quotation (opening `"` on line 1 only, closing `"` at the very end of line 2) —
    // must merge into ONE preserved unit, not split into two separately-paragraphed
    // lines.
    let lines: [[UInt8]] = [
        bytes("          \"God the all-terrible! Thou who ordainest,"),
        bytes("          Thunder thy clarion and lighten thy sword!\""),
    ]
    let doc = typedParagraphDoc(lines)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 1, "\(units.map { $0.map(lineVisibleText) })")
    #expect(units.reduce(0) { $0 + $1.count } == 2)
}

@Test func selfContainedQuoteHelperDistinguishesSpanFromUtterance() {
    // The mechanism directly: a line that both opens and closes its own quotation
    // counts; a line that only opens one (the quote continues past it) does not — even
    // though `opensQuote` alone says `true` for both.
    #expect(selfContainedQuote("\"Where are you going?\"") == true)
    #expect(selfContainedQuote("\"God the all-terrible! Thou who ordainest,") == false)
    #expect(opensQuote("\"God the all-terrible! Thou who ordainest,") == true)
    #expect(selfContainedQuote("Thunder thy clarion and lightning thy sword!\"") == false)
    #expect(selfContainedQuote("An ordinary line, no quote at all.") == false)
}

@Test func selfContainedDialogueStillVetoesAsProse() {
    // The veto's own calibration fixture (`ModernLintGateTests.swift`'s dialogue-run
    // test), re-pinned here at the `looksLikeVerse` level directly: real spoken
    // dialogue — each line opening AND closing its own quotation — must still veto a
    // verse call exactly as before.
    let runLines = ["\"Where are you going?\"", "\"I already told you.\""]
    let fakeLines = runLines.map { Line(spans: [Span(text: $0)]) }
    #expect(looksLikeVerse(fakeLines) == false)
}

@Test func ordinaryProseOpeningAQuoteAndContinuingStaysProse() {
    // Safety net: removing the bare quote-opening veto must not FLIP ordinary quoted
    // prose into verse — a two-line narrative sentence that happens to open with a
    // quotation mark and continues as a normal, terminally-punctuated sentence still
    // reads as prose via the terminal-punctuation signal (`verseAttrSupportedCeiling`),
    // same as it always has.
    let lines: [[UInt8]] = [
        bytes("          \"Well,\" she said, \"I suppose we should be going"),
        bytes("          now, before the weather turns any worse than this.\""),
    ]
    let doc = typedParagraphDoc(lines)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 2, "\(units.map { $0.map(lineVisibleText) })")
}
