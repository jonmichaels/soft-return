import Testing
@testable import CtrlKD

/// The three GENERIC Modern structure rules (Jon's field notes, 2026-08-13):
/// def-list/hanging-indent, nested hierarchy (the same mechanism applied recursively),
/// and centered lines -- derived purely from a paragraph's own column geometry
/// (`classifyRows` in `Layout.swift`), never keyed to a specific file. The real-world
/// source for all three is the Sawyer WS7 archive (VERSIONS.WS, CONVERT.WS,
/// STRENGTH.WS); these fixtures build the identical shapes byte-by-byte, per this
/// repo's synthetic-fixtures-only rule. Ports of `tests/test_ctrlkd.py`'s 9 new tests
/// under the "Modern structure rules" banner.

/// Forces the reflow path (not `<pre>`) the way Python's `_modern()` test helper does:
/// a tiny synthetic fixture can otherwise misclassify under `detect()`, and
/// `isPrinted` honours `.printstream` even when the caller asked for `.modern`.
private func modernDoc(_ data: [UInt8]) -> Document {
    var doc = parseWS(data)
    doc.detection = Detection(variant: .ws4)
    return doc
}

/// The `structure` field of every `para` item, in document order.
private func paraStructures(_ doc: Document) -> [RowStructure] {
    modernSemanticFlow(doc).items.compactMap { item in
        if case .para(_, _, _, _, _, let structure, _, _) = item { return structure }
        return nil
    }
}

@Test func deflistRaggedLabelWidthsShareOneColumn() {
    // Rule 1: a def-list label is a paragraph's own first word glued to its
    // description by 2+ spaces -- WordStar has no def-list markup, so an author
    // signals it purely by padding labels of different lengths out to a shared
    // description column. VERSIONS.WS's 'WS.EXE:'/'WSRJS.EXE:' shape.
    let data = bytes(".lm 15") + HARD
        + bytes("A:             short label.") + HARD
        + bytes("LONGLABEL:     longer label, same column.") + HARD
    let doc = modernDoc(data)
    let structures = paraStructures(doc)
    #expect(structures.map { $0.kind } == [.def, .def])
    #expect(structures.map { $0.label } == ["A:", "LONGLABEL:"])
    #expect(structures.map { $0.body } == ["short label.", "longer label, same column."])
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("<dl><dt>A:</dt><dd>short label.</dd>"
        + "<dt>LONGLABEL:</dt><dd>longer label, same column.</dd></dl>"))
}

@Test func deflistSingleEntryNeedsNoRepetition() {
    // Edge case: unlike a bullet marker (a bare glyph could just be punctuation, so it
    // needs a repeated sibling to be trusted), one label+gap+description line alone is
    // already unambiguous.
    let data = bytes("Note:  a single hanging label, alone in its own document.") + HARD
    let doc = modernDoc(data)
    let s = paraStructures(doc)[0]
    #expect(s.kind == .def)
    #expect(s.label == "Note:")
    #expect(s.body == "a single hanging label, alone in its own document.")
}

@Test func bareColonAloneIsNotADeflistLabel() {
    // Regression guard: ctrl-kd's `_DEFLIST_RE = r'^(\S+:)( {2,})(\S.*)$'` requires the
    // `\S+` group to contribute at least one character IN ADDITION to the mandatory
    // trailing ':' literal -- a label token that is nothing but a bare ":" (length 1)
    // can only satisfy `\S+` by consuming the colon itself, leaving nothing to match
    // the required literal ':' that follows, so the whole match fails. REF/-PATCHES.WS
    // has exactly this shape (a colon, a wide gap, then "result; e.g., if 2B35, enter
    // 6B35.)"): ctrl-kd keeps it a plain paragraph at level 1; a bug had sr's
    // `deflistMatch` accept a 1-character label (`i > 0` instead of `i > 1`), reading it
    // as a def-list item at level 2 and cascading a nesting-level mismatch through the
    // rest of the document.
    let data = bytes(":                          result; e.g., if 2B35, enter 6B35.)") + HARD
    let doc = modernDoc(data)
    let s = paraStructures(doc)[0]
    #expect(s.kind == nil)
    #expect(s.label == nil)
}

@Test func bulletListWithNestedDeflist() {
    // Rule 2: a def-list nested INSIDE a bullet list -- the same column-geometry
    // mechanism as rule 1, one level deeper. CONVERT.WS's own 'Peter Mierau...:
    // WSASC.COM: ...' shape.
    let data = bytes(".lm 2") + HARD
        + bytes("* First bullet item.") + HARD
        + bytes("* Second bullet, introduces a sub-list:") + HARD
        + bytes(" LABEL:  nested description.") + HARD
        + bytes("* Third bullet, back at the outer level.") + HARD
    let doc = modernDoc(data)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("<ul><li>First bullet item.</li>"
        + "<li>Second bullet, introduces a sub-list:"
        + "<dl><dt>LABEL:</dt><dd>nested description.</dd></dl></li>"
        + "<li>Third bullet, back at the outer level.</li></ul>"))
}

@Test func threeLevelNesting() {
    // Edge case: nesting recurses to arbitrary depth, not just one level -- a bullet
    // list containing a nested bullet list containing a nested def-list, three columns
    // deep.
    let data = bytes(".lm 2") + HARD
        + bytes("* Outer bullet one.") + HARD
        + bytes("* Outer bullet two, introduces inner list:") + HARD
        + bytes("  # Inner one") + HARD
        + bytes("  # Inner two, introduces a def-list:") + HARD
        + bytes("   LABEL:  deepest.") + HARD
    let doc = modernDoc(data)
    let structures = paraStructures(doc)
    #expect(structures.map { $0.level } == [1, 1, 2, 2, 3])
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("<ul><li>Outer bullet one.</li>"
        + "<li>Outer bullet two, introduces inner list:"
        + "<ul><li>Inner one</li>"
        + "<li>Inner two, introduces a def-list:"
        + "<dl><dt>LABEL:</dt><dd>deepest.</dd></dl></li></ul></li></ul>"))
}

@Test func centeredBySpacesDetectedAndRendered() {
    // Rule 3, encoding finding: STRENGTH.WS's title/author/email carry NO `.oc` tag at
    // all -- centering is leading-space padding only, symmetric within the document's
    // own 65-column measure. Structural detection must catch this untagged mechanism,
    // which nothing rendered correctly before.
    let title = "A Centered Title"
    let pad = (65 - title.count) / 2
    let data = bytes(String(repeating: " ", count: pad) + title) + HARD
    let doc = modernDoc(data)
    let s = paraStructures(doc)[0]
    #expect(s.centered)
    #expect(s.centerVia == .spaces)
    #expect(s.centerText == title)
    let html = emitHTML(doc, mode: .modern)
    // b24 round 20 (slate item 4): a "wrapped centered unit" now also carries the
    // tight verse line-height on the SAME style attribute.
    #expect(html.contains("<p style=\"text-align:center;line-height:1.15\">A Centered Title</p>"))
}

@Test func centeredTagAlsoClassifiedUniformly() {
    // The other mechanism named in the field notes ('likely both need handling'): a
    // real align=center tag is ALSO exposed as centered=true (centerVia=.tag) for a
    // consumer that wants one uniform signal -- but the tag's own existing HTML
    // rendering (M3 already strips its padding) is left completely alone, so a tagged
    // document's output is unchanged by this rule set.
    let doc = modernDoc(bytes(".oc on") + HARD + bytes("Centred.") + HARD + bytes(".oc off") + HARD)
    let s = paraStructures(doc)[0]
    #expect(s.centered)
    #expect(s.centerVia == .tag)
}

@Test func nearCenteredButNotStaysPlain() {
    // Edge case: a genuinely off-centre indent -- not padded to sit near the measure's
    // own midpoint -- must not be misread as a centered line, however coincidentally
    // short the paragraph is.
    let data = bytes("    Not Quite Centered") + HARD   // ideal pad would be (65-19)//2=23
    let doc = modernDoc(data)
    let s = paraStructures(doc)[0]
    #expect(!s.centered)
}

@Test func ordinaryMultilineBlockStaysOneParagraph() {
    // Regression guard: a block with NO list/def/center structure at all -- a
    // signature block with several hard-broken lines -- must still render as ONE <p>
    // with <br> between lines, exactly as before this rule set existed.
    let data = bytes("-- Robert J. Sawyer") + HARD + bytes("   sawyer@sfwriter.com") + HARD
    let doc = modernDoc(data)
    let html = emitHTML(doc, mode: .modern)
    // b24 round 20 (slate item 4): this signature block verse-classifies (short,
    // non-prose lines), so it now carries the tight verse line-height -- the SAME
    // ordinary-<p>-with-<br> shape this test guards, plus the round's own intended
    // new styling. ctrl-kd's own equivalent fixture needed the identical update.
    #expect(html.contains(
        "<p style=\"line-height:1.15\">-- Robert J. Sawyer<br>\n   sawyer@sfwriter.com</p>"))
}

@Test func ordinaryProseIsNotSweptIntoAList() {
    // False-positive guard: an ordinary sentence must never be read as a bullet (needs
    // a repeated marker glyph) or a def-list label (needs a 2+-space gap right after
    // its very first word).
    let data = bytes("This is an entirely ordinary sentence, nothing structural here.") + HARD
    let doc = modernDoc(data)
    let html = emitHTML(doc, mode: .modern)
    #expect(!html.contains("<ul>"))
    #expect(!html.contains("<dl>"))
    #expect(countOccurrences(of: Array("<p>".utf8), in: Array(html.utf8)) == 1)
}
