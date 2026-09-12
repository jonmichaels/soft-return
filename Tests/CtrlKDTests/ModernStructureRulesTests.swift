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
    // `+=` statements, never a chained `+` expression (macOS CI type-checker
    // times out on it -- see this repo's own CLAUDE.md).
    var expected = "<ul><li>First bullet item.</li>"
    expected += "<li>Second bullet, introduces a sub-list:"
    expected += "<dl><dt>LABEL:</dt><dd>nested description.</dd></dl></li>"
    expected += "<li>Third bullet, back at the outer level.</li></ul>"
    #expect(html.contains(expected))
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
    // `+=` statements, never a chained `+` expression (macOS CI type-checker
    // times out on it -- see this repo's own CLAUDE.md).
    var expected = "<ul><li>Outer bullet one.</li>"
    expected += "<li>Outer bullet two, introduces inner list:"
    expected += "<ul><li>Inner one</li>"
    expected += "<li>Inner two, introduces a def-list:"
    expected += "<dl><dt>LABEL:</dt><dd>deepest.</dd></dl></li></ul></li></ul>"
    #expect(html.contains(expected))
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

/// One type-9 "Tabs and dot leaders" symmetrical sequence, `cols` columns wide (HMI =
/// `cols * 180`, `core.TAB_HMI_PER_COL`), a plain space leader (`tabType: 0x20`) unless
/// told otherwise. Matches `test_ctrlkd.py`'s own `tab_block` test helper byte-for-byte:
/// `size`(LE16) + `absHMI`(LE16) + `tabType`(1) + a filler byte -- `_tabColumns`'
/// Swift/Python ports both only read offsets 0-1 (size) and 4 (tabType), so the filler
/// byte's own value is unobserved either side.
private func tabBlock(cols: Int, absHMI: Int = 1000, tabType: UInt8 = 0x20) -> [UInt8] {
    let size = cols * 180
    func le16(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] }
    return ws7Block(0x09, payload: le16(size) + le16(absHMI) + [tabType, 0x0D])
}

@Test func internalTabRunRowIsNotFalselyCentered() throws {
    // Issue #206: WSFORMAT.WS's own Symmetric-Sequences table row ("4" + a WordStar
    // tabs-and-dot-leaders symmetrical sequence + "Endnote", no `.oc` tag) used to
    // false-positive `classifyRows`' spaces-centering heuristic -- the row's own lead
    // (all from the tab-run's absolute-column jump, not typed spaces) happened to land
    // close to the row's arithmetic centre, so it read as hand-typed centering padding.
    // Real WS7 (paper-scan-verified) and this engine's own Printed PDF both show the row
    // LEFT-aligned, never centered. `hasInternalTabRun` (Layout.swift) excludes any row
    // whose tab-run splits label from value -- a SECOND tab-run past the row's own
    // leading edge -- from `centerVia == .spaces` entirely (a title/byline with only a
    // single LEADING tab-run, e.g. ARTICLES/FORMFEED.WS's own "-30-", is unaffected --
    // see titleCenteredViaASingleLeadingTabRunStillCenters below). Reproduced here via a
    // synthetic symmetric-sequence tab block padded so the OLD heuristic would have
    // called it centered -- not the real corpus file.
    //
    // Issue #204's own history lives here too: this exact row used to be (wrongly)
    // treated as centered, and a since-removed `mergeTabPositionTags`-equivalent
    // mechanism on the ctrl-kd side collapsed its tab-run into one `<span>` purely to
    // match sr's then-observed byte shape (sr itself never had an explicit mechanism --
    // its own `htmlCenteredRow`/`sliceSpans` happened to drop the tab tags as a side
    // effect of an unrelated, incomplete port). Once the row is correctly NOT centered,
    // it renders through the ordinary paragraph path instead -- which keeps the tab-run
    // in its own `&nbsp;`-converted run, unmerged, exactly like every other plain
    // paragraph's tab-run (confirmed byte-for-byte against a ctrl-kd build carrying the
    // identical #206 fix, same round).
    let body = bytes("4") + tabBlock(cols: 14) + bytes("Endnote")
    let pad = (65 - "4".count - 14 - "Endnote".count) / 2
    let doc = try parse([UInt8](repeating: 0x20, count: pad) + body + HARD, variant: nil)
    let s = paraStructures(doc)[0]
    #expect(!s.centered)
    #expect(s.centerVia == nil)
    let html = emitHTML(doc, mode: .modern)
    #expect(!html.contains("<p style=\"text-align:center"))
    // The tab-run keeps its own separate &nbsp; run -- an internal tab jump is real
    // table structure, never merged into the surrounding text.
    #expect(html.contains(String(repeating: "&nbsp;", count: 14)))
}

@Test func titleCenteredViaASingleLeadingTabRunStillCenters() throws {
    // Regression guard for #206's own precision: a title/byline typed AT a tab stop
    // chosen to look centered -- WordStar's own leading-space-only shape, no different
    // in kind from a hand-typed indent -- must NOT lose its centering just because the
    // padding happens to come from a real tab-stop span rather than literal spaces.
    // Found against ARTICLES/FORMFEED.WS's own "TURNING OFF FORM FEEDS" title and
    // "-30-" end-of-article marker during #206's own corpus-wide verification (both
    // real, both tab-positioned, both correctly still centered after the fix).
    // `hasInternalTabRun` only disqualifies a row whose tab-run splits label from value
    // -- a SECOND tab jump past the row's own leading edge -- never a single leading one.
    let title = "A Tab-Positioned Title"
    let padCols = (65 - title.count) / 2
    let doc = try parse(tabBlock(cols: padCols) + bytes(title) + HARD, variant: nil)
    let s = paraStructures(doc)[0]
    #expect(s.centered)
    #expect(s.centerVia == .spaces)
    #expect(s.centerText == title)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains(
        "<p style=\"text-align:center;line-height:1.15\">A Tab-Positioned Title</p>"))
}

@Test func ordinaryTabRunRowKeepsItsOwnNbspSpan() throws {
    // Regression guard, formerly "the #204 fix is scoped to centered rows only":
    // WSFORMAT.WS's OWN "00h ^@ <tab-run> Fix the print position..." row -- a plain,
    // un-centered, long paragraph carrying the identical internal-tab-run SHAPE as the
    // #206 table rows above -- keeps its `&nbsp;`-run exactly as before either issue was
    // filed. Not itself a false-centering case (far too long for `classifyRows`' own
    // slack/ideal arithmetic to ever call it centered), so #206's `hasInternalTabRun`
    // guard never even has to act on it -- this test exists purely so nobody widens that
    // guard's scope into touching a row this engine's own tracked bytes say must stay
    // untouched. Plain `parse(_:variant:)` (auto-detect), matching the Python fixture's
    // own bare `core.parse(data)` -- not `modernDoc()`'s forced ws4 variant.
    let data = bytes("00h ^@") + tabBlock(cols: 9)
        + bytes("Fix the print position at print time, a normal plain "
               + "paragraph long enough to stay unclassified.") + HARD
    let doc = try parse(data, variant: nil)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains(
        "<p>00h ^@" + String(repeating: "&nbsp;", count: 9) + "Fix the print"))
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
