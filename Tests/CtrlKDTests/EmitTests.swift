import Testing
@testable import CtrlKD

/// Named-test ports for the text and markdown emitters, plus coverage for behavior the
/// 28 vectors don't discriminate.

@Test func emitTextPortedTest() {
    // Mirrors test_emit_text (over the `prose_doc` fixture = parse_ws(make_prose())).
    let doc = parseWS(makeProse())
    let text = emitText(doc)
    #expect(text.contains("ends here."))
    #expect(text.contains("\n\n"))
}

@Test func emitMarkdownStyles() {
    // Mirrors test_emit_markdown_styles.
    var data: [UInt8] = boldOn + ws4Text("Bold") + boldOn + bytes(" ")
    data += italicOn + ws4Text("ital") + italicOn + HARD
    let md = emitMarkdown(parseWS(data))
    #expect(md.contains("**Bold**"))
    #expect(md.contains("*ital*"))
}

// MARK: - gap-closing tests (mutation-proven necessary; not covered by the vectors)

@Test func markdownSpanWrapsOnlyTheStrippedCore() {
    // The lead/trail peeling in _md_span only shows up when a styled span carries outer
    // whitespace: markup wrapped around the spaces wouldn't render. No vector has a styled
    // span with leading/trailing space, so skipping the peel passes the whole suite.
    let span = Span(text: "  bold words  ", styles: .bold)
    #expect(markdownSpan(span) == "  **bold words**  ")
}

@Test func markdownSpanEscapesBackslashBeforeOtherCharacters() {
    // Order matters: backslash must be doubled FIRST, or the backslashes added when
    // escaping `*_#`[]` get doubled too. The md_escaping vector already catches the wrong
    // order (its added backslashes get doubled), so this is not a coverage gap — it's the
    // direct statement of the rule, with a literal backslash in the INPUT, which no vector
    // has.
    let span = Span(text: #"a\b *c*"#, styles: [])
    #expect(markdownSpan(span) == #"a\\b \*c\*"#)
}

@Test func markdownWhitespaceOnlySpanPassesThroughUnescaped() {
    // _md_span returns whitespace-only spans untouched, BEFORE escaping — so a span that
    // is only spaces never acquires backslashes. The wrap-join space spans hit this path.
    #expect(markdownSpan(Span(text: "   ", styles: .bold)) == "   ")
}
