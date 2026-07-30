import Testing
@testable import CtrlKD

/// Named-test ports for the HTML and RTF emitters, plus coverage for behavior the 33
/// job-009 vectors don't discriminate. Every expected value below was produced by running
/// the Python reference (ctrl-kd 1.1.4) locally — same ground truth as the vectors, just
/// for inputs the vector set doesn't reach.

// MARK: - ports of the Python named tests

@Test func emitHTMLPoemBreaks() {
    // Mirrors test_emit_html_poem_breaks.
    let poem = bytes("     line one,") + SOFT + bytes("     line two.") + HARD
    let html = emitHTML(parseWS(poem))
    #expect(html.contains("<br>"))
    #expect(html.contains("<p>"))
    // Stronger than the Python assertion, and free: the whole body, exactly.
    #expect(html.contains(
        "<body>\n<p>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;line one,<br>\n" +
        "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;line two.</p>\n</body></html>\n"
    ))
}

@Test func emitHTMLPrintedPre() {
    // Mirrors test_emit_html_printed_pre: a print stream's column alignment must survive,
    // which is the whole point of the keep_ws branch.
    let data = bytes("A    B    C\r\nD    E    F\r\n")
    let html = emitHTML(parsePrintstream(data), mode: .printed)
    #expect(html.contains("<pre>"))
    #expect(html.contains("A    B    C"))
    #expect(html.contains("<body>\n<pre>A    B    C\nD    E    F\n</pre>\n</body></html>\n"))
}

@Test func emitRTFValidShape() {
    // Mirrors test_emit_rtf_valid_shape, brace-balance assertion included: every span opens
    // a group and must close it, or a reader chokes on the whole document.
    let rtf = emitRTF(parseWS(makeProse()))
    #expect(rtf.hasPrefix(#"{\rtf1"#))
    #expect(rtf.trimmed().hasSuffix("}"))
    #expect(rtf.filter { $0 == "{" }.count == rtf.filter { $0 == "}" }.count)
}

// MARK: - gap-closing tests (not discriminated by the 33 vectors)

@Test func htmlEscapesApostropheAndQuoteLikePython() {
    // html.escape(quote=True) also escapes ' -> &#x27;, which no vector input contains.
    #expect(htmlEscape(#"Jon's ex"tra <b> & more"#)
            == "Jon&#x27;s ex&quot;tra &lt;b&gt; &amp; more")
    // The ampersand pass must run FIRST, or the entities added after it get re-escaped
    // (`&lt;` -> `&amp;lt;`). This input has both a literal & and a literal <.
    #expect(htmlEscape("&<") == "&amp;&lt;")
}

@Test func htmlSpanNbspThresholdIsFiveSpaces() {
    // Four leading spaces are ordinary text and stay as-is; five are a deliberate indent.
    // Every vector with an indent has exactly five, so a mutated threshold (>=1, >=4)
    // passes the whole vector suite.
    #expect(htmlSpan(Span(text: "    four")) == "    four")
    #expect(htmlSpan(Span(text: "     five")) == "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;five")
}

@Test func htmlSpanNbspCountsTheWholeLeadingRunNotJustSpaces() {
    // The trigger is five SPACES, but the count that gets inflated is the full leading
    // whitespace run — Python measures it with lstrip(), which eats the tab too. So this is
    // six &nbsp;, not five.
    #expect(htmlSpan(Span(text: "     \tsix")) == String(repeating: "&nbsp;", count: 6) + "six")
}

@Test func htmlSpanKeepWSSuppressesNbsp() {
    // Inside <pre> the browser honours the spaces already; inflating them would double the
    // indent. (The poem_indents/html/printed vector covers this too — kept as the direct
    // statement of the rule.)
    #expect(htmlSpan(Span(text: "     five"), keepWS: true) == "     five")
}

@Test func htmlSpanNestsMultipleStylesInPythonSortedOrder() {
    // Python wraps in sorted(styles) order — b, i, strike, sub, sup, u — so bold ends up
    // innermost and underline outermost. No vector carries a span with two TAGGED styles
    // (the only multi-style span in the set is {fnref, sup}, and fnref has no tag), so the
    // table order is otherwise unproven.
    #expect(htmlSpan(Span(text: "w", styles: [.bold, .underline])) == "<u><strong>w</strong></u>")
    #expect(htmlSpan(Span(text: "w", styles: [.bold, .italic, .underline, .sup, .sub, .strike]))
            == "<u><sup><sub><s><em><strong>w</strong></em></s></sub></sup></u>")
}

@Test func htmlSpanFnrefContributesNoTag() {
    // fnref is absent from _TAG, and Python's _TAG.get skips it silently — the reference
    // renders as the bare digits inside the sup it also carries.
    #expect(htmlSpan(Span(text: "1", styles: [.fnref, .sup])) == "<sup>1</sup>")
    #expect(htmlSpan(Span(text: "1", styles: .fnref)) == "1")
}

@Test func htmlHeadingJoinsItsLinesWithSpacesAndStrips() {
    // A heading that wrapped across two lines reads as one phrase, and the join leaves
    // trailing space that .strip() removes. Every vector heading is a single line.
    let doc = Document(blocks: [Block(
        kind: .para,
        lines: [Line(spans: [Span(text: "Chapter")]), Line(spans: [Span(text: "One  ")])],
        heading: 2
    )])
    #expect(emitHTML(doc).contains("<body>\n<h2>Chapter One</h2>\n</body></html>\n"))
}

@Test func rtfEscapesMetacharactersAndNonASCII() {
    // No vector input contains a backslash or a brace, so this whole branch of
    // _rtf_escape is unproven by the vector set — and it's the branch that would corrupt a
    // document (an unescaped brace opens a group that never closes).
    #expect(rtfEscape(#"a\b {c} é"#) == #"a\\b \{c\} \u233?"#)
}

@Test func rtfEmitsControlWordsInPythonSortedOrder() {
    // Concatenated, not nested, so the order is visible in the output. fnref contributes
    // nothing (Python's .get(s, '') default).
    let doc = Document(blocks: [Block(lines: [Line(spans: [
        Span(text: "w", styles: [.bold, .italic, .underline, .sup, .sub, .strike, .fnref]),
    ])])])
    #expect(emitRTF(doc).contains(#"{\b \i \strike \sub \super \ul w}"#))
}

@Test func rtfEmitsEscapedBracesInsideTheGroupStructure() {
    // Escaped braces in a whole document, not just through rtfEscape: the escape has to
    // survive being wrapped in the span's own group.
    //
    // NOTE on the brace-balance assertion in `emitRTFValidShape`: it does NOT generalize to
    // brace-bearing text. Counting `{` vs `}` over the raw output counts the ESCAPED ones
    // too, so a document whose text contains an odd literal brace reports 7 vs 6 — in
    // Python exactly as here (verified against the reference). The assertion is a shape
    // check for prose, not an escaping check; this exact-output test is the escaping check.
    let doc = Document(blocks: [Block(lines: [Line(spans: [Span(text: "a{b}c{")])])])
    #expect(emitRTF(doc) == #"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}{\f1 Courier New;}}"#
            + "\n" + #"\f0\fs24 "# + "\n"
            + #"{a\{b\}c\{}\par "# + "\n" + #"\par "# + "\n}\n")
}

@Test func rtfModernEmitsABlankParagraphEvenForAnEmptyBlock() {
    // emit.py:231-232 appends `\par ` unconditionally in modern mode, so a block that
    // contributed no paragraph of its own still emits one — three `\par ` runs between A
    // and B, not two. A quirk, verified against Python rather than assumed.
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "A")])]),
        Block(lines: []),
        Block(lines: [Line(spans: [Span(text: "B")])]),
    ])
    #expect(emitRTF(doc) == #"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}{\f1 Courier New;}}"#
            + "\n" + #"\f0\fs24 "# + "\n"
            + #"{A}\par "# + "\n" + #"\par "# + "\n" + #"\par "# + "\n"
            + #"{B}\par "# + "\n" + #"\par "# + "\n}\n")
}

@Test func htmlSkipsAnEmptyBlockEntirely() {
    // Same document, HTML side: the `<p>` is suppressed rather than emitted empty.
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "A")])]),
        Block(lines: []),
        Block(lines: [Line(spans: [Span(text: "B")])]),
    ])
    #expect(emitHTML(doc).contains("<body>\n<p>A</p>\n<p>B</p>\n</body></html>\n"))
}
