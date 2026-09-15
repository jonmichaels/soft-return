/// planning #264 item 3 (packet row B4): a picture row is kept on one line in HTML.
/// Port of ctrl-kd 9d957ff (whose own tests live beside the Modern-PDF clip rule in
/// `tests/test_modern_centring_clip.py`).
///
/// THE DEFECT. A row of box-drawing characters -- a border, a legend, a
/// substitution-table row -- folded in the middle of a narrow browser window and stopped
/// being the picture it drew. The Modern PDF has refused to fold such a row since
/// planning #263 (job 456, ported from the app); HTML read nothing of that verdict.
///
/// ONE RULE, BOTH EMITTERS. `modernClipsRow` now delegates to `graphicRowClips`
/// (EmitterRules.swift), with the app's own three branches intact -- wholly graphic;
/// carrying more than one graphic character (the threshold is TWO, so an ordinary
/// paragraph with one incidental list marker still wraps like the prose it is); or with
/// nowhere to break. HTML DROPS THE THIRD BRANCH deliberately: a browser never breaks
/// inside a word on its own, so marking a row that merely has no space in it would be
/// markup that changes nothing -- and would put the class on every one-word row in every
/// document.
import Testing
@testable import CtrlKD

private func htmlRow(_ text: String, mode: EmitMode = .modern) -> String {
    let doc = Document(blocks: [Block(kind: .para,
                                      lines: [Line(spans: [Span(text: text)])])])
    return emitHTML(doc, mode: mode)
}

@Test func htmlKeepsAWhollyGraphicRowOnOneLine() throws {
    let out = htmlRow("\u{250c}\u{2500}\u{2500}\u{2500}\u{2510}")
    #expect(out.contains("class=\"ws-nowrap\""))
    #expect(out.contains("span.ws-nowrap{white-space:nowrap}"))
}

@Test func htmlKeepsAMixedLegendRowOnOneLine() throws {
    // The field report's own shape: a prose label and its glyphs, which ordinary
    // wrapping folds at the perfectly legal space between them.
    let out = htmlRow("LL: \u{2514} LR: \u{2518} H: \u{2550}")
    #expect(out.contains("class=\"ws-nowrap\""))
}

@Test func htmlLeavesOneIncidentalGlyphAlone() throws {
    // The threshold is TWO, so an ordinary paragraph carrying a single list marker still
    // wraps like the prose it is.
    let out = htmlRow("\u{25a0} one marker, and then ordinary prose that wraps")
    #expect(!out.contains("ws-nowrap"))
}

@Test func htmlDoesNotMarkARowThatMerelyHasNowhereToBreak() throws {
    // The rule's third branch is deliberately dropped in HTML.
    #expect(!htmlRow("sawyer@sfwriter.com").contains("ws-nowrap"))
    #expect(graphicRowClips("sawyer@sfwriter.com"))
}

@Test func htmlMarksThePictureRowInPrintedModeToo() throws {
    // A picture is a picture in either view. The fixed-pitch block is
    // `white-space:pre-wrap`, where plain `nowrap` would also collapse the column
    // spacing that block exists to preserve -- so the rule inside it is `pre`,
    // `pre-wrap`'s non-wrapping twin.
    let out = htmlRow("\u{250c}\u{2500}\u{2500}\u{2500}\u{2510}", mode: .printed)
    #expect(out.contains("class=\"ws-nowrap\""))
    #expect(out.contains("p.ws-native span.ws-nowrap{white-space:pre}"))
}

@Test func aDocumentWithNoPictureRowPaysNoCSSForOne() throws {
    // Same discipline as the `.ws-nonprop` and list rules: the stylesheet grows only
    // when a row actually used the class.
    #expect(!htmlRow("ordinary prose, no glyphs at all").contains("ws-nowrap"))
}

@Test func theTwoSurfacesAskAboutTwoDifferentCharacterSets() throws {
    // The PDF's `graphicChars` is the union of its own per-glyph DRAWING tables and holds
    // two things the content classification deliberately does not: the four arc corners
    // (produced only by the LJ6DTP Univers substitution at render time, never decoded
    // from a file) and `\u{20A7}`, the peseta -- drawn as geometry because no base-14
    // face carries it (planning #266), but an ordinary currency character in prose.
    //
    // A price row is the case that matters: the archive's own printer character charts
    // carry rows like `158  \u{20A7} \u{20A7}`, which the drawing set reads as TWO
    // graphic characters (a picture) and the content set reads as none (prose). HTML must
    // ask the content set or every such row gets a nowrap it should never have had --
    // this is what the cross-engine gate caught, on eight cells across two documents.
    let row = "158  \u{20A7} \u{20A7}"
    #expect(graphicChars.contains("\u{20A7}"))
    #expect(!contentGraphicChars.contains("\u{20A7}"))
    #expect(graphicRowClips(row) == false)
    #expect(graphicRowClips(row, graphicChars) == true)
    #expect(!htmlRow(row).contains("ws-nowrap"))
    // ... and the PDF's own adapter keeps asking the drawing set, unchanged.
    #expect(modernClipsRow([ModernToken(text: row, styles: [], family: .times,
                                        pt: 12, entry: nil, width: 0.0)]))
}

@Test func htmlAndThePDFReadOneSharedRule() throws {
    // `graphicRowClips` is the single implementation; `modernClipsRow` is its
    // token-shaped adapter and `htmlRowIsNowrap` its HTML-shaped one.
    for text in ["\u{2502}    \u{2502}", "LL: \u{2514} LR: \u{2518}",
                 "\u{25a0} ordinary prose", "no glyphs here at all"] {
        let toks = [ModernToken(text: text, styles: [], family: .times, pt: 12,
                                entry: nil, width: 0.0)]
        #expect(modernClipsRow(toks) == graphicRowClips(text, graphicChars))
    }
}
