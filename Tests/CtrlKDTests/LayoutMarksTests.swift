import Testing
@testable import CtrlKD

/// b24 engine wave, round 20 item 6 (slate items 5/11, engine half) — mirrors ctrl-kd's
/// tests/test_layout_marks.py. What the Modern layout JSON (`modernSemanticFlow`/
/// `emitLayout`) carries for sr's own `AnnotatedLayout.swift` to build Show Invisibles
/// from, in Modern view. The VIEW rendering is a later wave (explicitly out of scope
/// this round) -- this round only ensures the DATA survives into the layout emission.
///
/// INVESTIGATION FINDINGS (2026-08-18, ctrl-kd, carried over verbatim):
///   - Header/footer declarations ('hf' items) and `.tc`/`.ix`/tab-ruler state ('tabs'
///     items) were ALREADY present inline in the flow's own item stream, anchored at
///     the correct block position -- nothing to fix.
///   - Page-break ORIGIN ('.pa' dot command vs a literal form-feed byte) was a genuine,
///     verifiable gap: `Block.origin` already carried the answer (Native's own
///     `doc.blocks`), but the flow's own `.pageBreak` item dropped it. FIXED using the
///     EXACT wire string `AnnotatedLayout.swift`'s own `InkKind.pageBreakOrigin`
///     already produces, so the two representations stay parity-testable as data.
///   - The comment-position gap this docstring used to flag as KNOWN, NOT-YET-FIXED
///     was CLOSED in round 22 (C5): a kept comment under the default 'word' note-ref
///     scheme now emits a ZERO-WIDTH anchor run (text: "", ref set) at its true inline
///     position -- the same spot the RTF export anchors \*\annotation at -- so Show
///     Invisibles has a position to draw the comment icon at while the mark itself
///     stays markless (Word's bubble convention). `PDFModernLayout.modernFlow` (the
///     shared-consumer risk the round-20 note worried about) skips empty ref runs
///     explicitly, so Modern PDF bytes are untouched. Tests below pin the anchor's
///     position against the RTF export's own anchor for the same fixture.

@Test func dotCommandPagebreakCarriesTheDotOrigin() throws {
    let data = bytes("Page one text.\r\n.pa\r\nPage two text.\r\n")
    let flow = modernSemanticFlow(parseWS(data))
    let breaks = flow.items.compactMap { item -> String? in
        if case .pageBreak(let origin) = item { return origin }
        return nil
    }
    #expect(!breaks.isEmpty, "no break item produced")
    #expect(breaks.first == ".pa")
}

@Test func literalFormfeedPagebreakCarriesTheFormfeedOrigin() throws {
    // WS4's bit-7-toggle path (a literal 0x0C in the byte stream) is a real, distinct
    // source from a WS5+ `.pa` dot command -- confirm the JSON layer reports it
    // distinctly too.
    let data = bytes("Page one.") + [0x0C] + bytes("Page two.\r\n")
    let flow = modernSemanticFlow(parseWS(data))
    let breaks = flow.items.compactMap { item -> String? in
        if case .pageBreak(let origin) = item { return origin }
        return nil
    }
    #expect(!breaks.isEmpty, "no break item produced")
    #expect(breaks.first == "\u{0C}")
}

@Test func pagebreakOriginIsTheOnlyNewKeyAdded() throws {
    // a strict addition -- confirm no other break-item shape changed.
    let data = bytes("Text.\r\n.pa\r\nMore.\r\n")
    let doc = parseWS(data)
    let json = emitLayout(doc, mode: .modern)
    #expect(json.contains("\"kind\": \"break\""))
    #expect(json.contains("\"origin\": \".pa\""))
}

/// A comment (type 0x06) anchored between 'Alpha' and 'beta' — the round-18 export
/// fixture shape: the anchor's true inline position is mid-sentence, not at line or
/// document end. Port of Python's `_comment_doc`.
private func commentDoc() -> Document {
    parseWS(wsBlock(cmd: 0x00) + bytes("Alpha ")
            + ws7Note(bytes("A margin comment."), cmd: 0x06, number: 0)
            + bytes("beta gamma.\r\n"))
}

/// The para items of `flow` that carry at least one reference run.
private func refParas(_ flow: SemanticFlow) -> [[SemanticRun]] {
    flow.items.compactMap { item -> [SemanticRun]? in
        guard case .para(_, _, _, let runs, _, _, _, _) = item,
              runs.contains(where: { $0.ref != nil }) else { return nil }
        return runs
    }
}

@Test func wordSchemeCommentEmitsZeroWidthAnchorAtInlinePosition() throws {
    // Round 22 (C5): the default 'word' scheme used to drop a comment's inline
    // position entirely (no run at all). It must now carry a markless zero-width
    // anchor run at the true position: between the 'Alpha ' run and the
    // 'beta gamma.' run.
    let flow = modernSemanticFlow(commentDoc(), notes: EmitOptions.allNotes, noteRefs: .word)
    let paras = refParas(flow)
    #expect(!paras.isEmpty, "no para item carries the comment anchor")
    let runs = try #require(paras.first)
    let iRef = try #require(runs.firstIndex { $0.ref != nil })
    #expect(runs[iRef].text == "")                    // markless: zero-width
    #expect(flow.notes[try #require(runs[iRef].ref)].kind == .comment)
    let iAlpha = try #require(runs.firstIndex { $0.text.contains("Alpha") })
    let iBeta = try #require(runs.firstIndex { $0.text.contains("beta") })
    #expect(iAlpha < iRef && iRef < iBeta)
}

@Test func commentAnchorPositionMatchesRTFExportAnchor() throws {
    // The layout stream's anchor and the RTF export's \*\annotation must sit between
    // the SAME two words for the same fixture -- the round-18 export anchoring is the
    // reference the layout stream now matches.
    let doc = commentDoc()
    let rtf = emitRTF(doc, mode: .modern,
                      options: EmitOptions(notes: EmitOptions.allNotes, noteRefs: .word))
    let alphaAt = try #require(rtf.range(of: "Alpha"))
    let annotationAt = try #require(rtf.range(of: #"\*\annotation"#))
    let betaAt = try #require(rtf.range(of: "beta"))
    #expect(alphaAt.lowerBound < annotationAt.lowerBound)
    #expect(annotationAt.lowerBound < betaAt.lowerBound)
    let flow = modernSemanticFlow(doc, notes: EmitOptions.allNotes, noteRefs: .word)
    let runs = try #require(refParas(flow).first)
    var order: [String] = []
    for r in runs {
        if r.ref != nil {
            order.append("anchor")
        } else if r.text.contains("Alpha") {
            order.append("Alpha")
        } else if r.text.contains("beta") {
            order.append("beta")
        }
    }
    #expect(order == ["Alpha", "anchor", "beta"])
}

@Test func prefixedSchemeCommentMarkIsUnchanged() throws {
    // the 'prefixed' scheme already carried the visible c-mark at the inline
    // position -- confirm the round-22 change didn't touch it.
    let flow = modernSemanticFlow(commentDoc(), notes: EmitOptions.allNotes,
                                  noteRefs: .prefixed)
    let runs = try #require(refParas(flow).first)
    let refRun = try #require(runs.first { $0.ref != nil })
    #expect(refRun.text == "c1")
}

@Test func defaultNoteKindsStillExcludeCommentsEntirely() throws {
    // flag semantics unchanged: comments are opt-in (defaultNotes excludes them) --
    // the default flow carries no anchor and no note row.
    let flow = modernSemanticFlow(commentDoc())
    #expect(refParas(flow).isEmpty)
    #expect(flow.notes.allSatisfy { $0.kind != .comment })
}

@Test func wordSchemeCommentAnchorAddsNoInkToModernPDF() throws {
    // PDFModernLayout's modernFlow skips empty ref runs: the anchor must not surface
    // as any visible mark in Modern PDF (no 'c1' text), while the opted-in comment
    // text still renders in the end-notes section as before.
    let pdf = emitPDF(commentDoc(), mode: .modern,
                      options: EmitOptions(notes: EmitOptions.allNotes, noteRefs: .word))
    #expect(!contains(pdf, bytes("(c1)")))
    #expect(contains(pdf, bytes("margin")))    // end-matter note text still renders
}

@Test func headerDeclarationAlreadyRidesInlineInModernItems() throws {
    // documents the pre-existing, already-correct behavior -- guards against a future
    // change silently dropping it.
    let data = bytes(".h1 My Header\r\nBody text.\r\n")
    let flow = modernSemanticFlow(parseWS(data))
    let hfItems = flow.items.compactMap { item -> (which: HFKind, text: String)? in
        if case .hf(let which, _, let text) = item { return (which, text) }
        return nil
    }
    #expect(!hfItems.isEmpty, "header declaration missing from Modern item stream")
    #expect(hfItems.first?.which == .header)
    #expect(hfItems.first?.text.contains("My Header") == true)
}

// ------------------------------------------------------- register b32-P1
// Schema addition (mirrored from ctrl-kd 314580b): an INLINE reference-mark run now
// carries its own 'note_kind', matching the end-matter 'note' item's existing field
// (which has always carried it -- see the module doc comment's own 'note' entry above)
// -- closing the one asymmetry in the contract that made a consumer look the kind up
// via `flow.notes[ref].kind` instead of reading it straight off the mark. Additive
// only: format stays version 1.

private func footnoteEndnoteDoc() -> Document {
    parseWS(wsBlock(cmd: 0x00) + bytes("alpha ")
            + ws7Note(bytes("A footnote."), cmd: 0x03)
            + bytes(" beta ")
            + ws7Note(bytes("An endnote."), cmd: 0x04)
            + bytes(" gamma.\r\n"))
}

@Test func inlineRefRunCarriesItsOwnNoteKind() throws {
    let doc = footnoteEndnoteDoc()
    let flow = modernSemanticFlow(doc, notes: EmitOptions.allNotes)
    let refRuns = flow.items.flatMap { item -> [SemanticRun] in
        guard case .para(_, _, _, let runs, _, _, _, _) = item else { return [] }
        return runs.filter { $0.ref != nil }
    }
    #expect(refRuns.count == 2)
    for r in refRuns {
        // the mark's own 'noteKind' must agree with the SAME note looked up the old
        // way, via its 'ref' index into flow.notes -- this is a redundant, convenience
        // copy, not a second source of truth.
        let ref = try #require(r.ref)
        #expect(r.noteKind == flow.notes[ref].kind)
    }
    #expect(Set(refRuns.compactMap(\.noteKind)) == [.footnote, .endnote])
}

@Test func wordSchemeCommentZeroWidthAnchorAlsoCarriesNoteKind() throws {
    // the markless comment anchor (round 22) is a 'ref' run too -- P1's addition
    // covers it the same as any other inline reference mark.
    let flow = modernSemanticFlow(commentDoc(), notes: EmitOptions.allNotes, noteRefs: .word)
    let runs = try #require(refParas(flow).first)
    let refRun = try #require(runs.first { $0.ref != nil })
    #expect(refRun.text == "")                       // still zero-width
    #expect(refRun.noteKind == .comment)
}
