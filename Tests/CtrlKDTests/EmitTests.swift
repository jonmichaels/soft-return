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

@Test func markdownSpanNestsMultipleStylesInPythonSortedOrder() {
    // Python wraps in sorted(styles) order — b, i, strike, sub, sup, u — same alphabetical
    // rule EmitHTML.swift/EmitRTF.swift already follow (see
    // htmlSpanNestsMultipleStylesInPythonSortedOrder). Markdown's own `markdownHTMLTags`
    // table used to list `u, sup, sub` (the reverse), which put `<sub>` outermost instead of
    // `<u>` for any span carrying two or more of {sub, sup, underline} — verified against
    // the Python reference (`_md_span(Span('w', frozenset({'sub','sup'})))` ==
    // `'<sup><sub>w</sub></sup>'`).
    #expect(markdownSpan(Span(text: "w", styles: [.sub, .sup])) == "<sup><sub>w</sub></sup>")
    #expect(markdownSpan(Span(text: "w", styles: [.bold, .italic, .underline, .sup, .sub, .strike]))
            == "<u><sup><sub>~~***w***~~</sub></sup></u>")
}

@Test func markdownAnnotationTagWithPunctuationIsSlugged() {
    // An annotation's tag becomes part of a `[^key]` Markdown reference — WordStar puts no
    // character restriction on a tag, so an unslugged tag containing `[`/`]`/`?` produces a
    // malformed key with an unescaped `]` INSIDE it (`[^a[How?]]`). `_note_slug` (emit.py's
    // `re.sub(r'[^A-Za-z0-9_.-]+', '-', label).strip('-')`) is what Python runs the label
    // through first; verified against the reference:
    // `emit_markdown(Document(blocks=[...one fnref span referencing this note...],
    // notes=[Note('annotation', text='Annotation body.', tag='[How?]')]))` produces exactly
    // `'Ref [^aHow]\n\n[^aHow]: Annotation body.\n'`.
    let doc = Document(
        blocks: [Block(lines: [Line(spans: [
            Span(text: "Ref "),
            Span(text: "1", styles: .fnref),
        ])])],
        notes: [Note(kind: .annotation, text: "Annotation body.", tag: "[How?]")]
    )
    #expect(emitMarkdown(doc) == "Ref [^aHow]\n\n[^aHow]: Annotation body.\n")
}

@Test func annotationWithNoTagFallsBackToItsPositionAmongAnnotations() {
    // WordStar's tag field is nullable/empty, and Python's `_annotated_notes` falls back to
    // the running per-kind counter in exactly that case (`n.tag or str(counters[n.kind])`),
    // not to a blank label — verified against the reference for this precise shape (three
    // annotations: absent tag, empty tag, real tag) via `_annotated_notes`, which returns
    // labels `1`, `2`, `X` in that order.
    //
    // `EmitNotes.swift`'s `noteLabel` used to return `note.tag ?? ""` with no such fallback,
    // which is what a real corpus file (variant ws5+, a 530-byte document with one untagged
    // annotation) surfaced as `[^a0]` (`noteSlug`'s OWN empty-string default, not Python's
    // counter) where the Python reference emits `[^a1]` — confirmed byte-for-byte against
    // the reference on that file (first differing byte: Python `0x31` ('1'), Swift `0x30`
    // ('0'), at the same offset job-008's `[1]`-vs-`[]` symptom described for text/RTF).
    let doc = Document(
        blocks: [Block(lines: [Line(spans: [
            Span(text: "1", styles: .fnref), Span(text: " "),
            Span(text: "2", styles: .fnref), Span(text: " "),
            Span(text: "3", styles: .fnref),
        ])])],
        // Distinct `offset`s: real parsed notes always have one (each note's own `0x1D`
        // header can't share a byte position with another note's), and `notePosition`
        // disambiguates by it — three notes sharing the default `offset: 0` would collide.
        notes: [
            Note(kind: .annotation, text: "no tag", offset: 0),
            Note(kind: .annotation, text: "empty tag", tag: "", offset: 10),
            Note(kind: .annotation, text: "tagged", tag: "X", offset: 20),
        ]
    )
    let md = emitMarkdown(doc)
    #expect(md.contains("[^a1]"))
    #expect(md.contains("[^a2]"))
    #expect(md.contains("[^aX]"))
    #expect(md.contains("[^a1]: no tag"))
    #expect(md.contains("[^a2]: empty tag"))
    #expect(md.contains("[^aX]: tagged"))
}

@Test func markdownNegativeHeadingLevelDoesNotCrashAndDropsTheHashes() {
    // ParseWS.swift derives `heading` from a dot-command argument byte
    // (`Int(raw[1]) - 0x30`), which goes negative on a garbage byte from a non-WordStar
    // file `detect()` mistakenly accepted — real crash, confirmed as
    // `Swift/StringLegacy.swift:31: Fatal error: Negative count not allowed` inside
    // `String(repeating: "#", count: block.heading)` here. Python's `'#' * b.heading` for a
    // negative count is simply `''` (verified against the reference: a hand-built Document
    // with `heading=-3` emits `' Title\n'`, not an error) — a converter must never crash on
    // bytes its own detection let through. Built directly on the IR since neither parser can
    // itself produce a negative heading from well-formed input.
    let doc = Document(blocks: [Block(
        lines: [Line(spans: [Span(text: "Title")])], heading: -3
    )])
    #expect(emitMarkdown(doc) == " Title\n")
}

@Test func emitMarkdownNoteDefsAreGroupedByKindNotReferenceOrder() {
    // Q2 ruling (b32 field notes, 2026-08-26, mirrored from ctrl-kd 9a232c8): "sr's
    // grouped order wins; ctrl-kd conforms" -- ALL footnote defs first, then ALL
    // endnote defs, regardless of the order the notes are first REFERENCED inline. sr
    // already grouped by `noteKindOrder` before this ruling (EmitMarkdown.swift's own
    // per-kind loop); this fixture references them out of kind-grouped order (footnote
    // 1, endnote 1, footnote 2) specifically to distinguish "grouped by kind" from
    // "first-reference order" -- the two orderings agree unless a test deliberately
    // interleaves kinds like this, so it's the one shape that would have caught a
    // regression to reference order.
    let data = ws7Block(0x00)
        + bytes("one ") + ws7Note(bytes("First footnote."), cmd: 0x03, number: 0)
        + bytes(" two ") + ws7Note(bytes("First endnote."), cmd: 0x04, number: 0)
        + bytes(" three ") + ws7Note(bytes("Second footnote."), cmd: 0x03, number: 1)
        + bytes(" four") + HARD
    let doc = parseWS(data)
    let md = emitMarkdown(doc, mode: .modern, options: EmitOptions(notes: EmitOptions.allNotes))
    guard let i1 = md.range(of: "[^1]: First footnote."),
          let i2 = md.range(of: "[^2]: Second footnote."),
          let ie1 = md.range(of: "[^e1]: First endnote.") else {
        Issue.record("expected all three note definitions present")
        return
    }
    #expect(i1.lowerBound < i2.lowerBound && i2.lowerBound < ie1.lowerBound,
            "footnote defs must both precede the endnote def")
}
