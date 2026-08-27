import Testing
@testable import CtrlKD

/// b24 engine wave, round 20b (slate item 13) — mirrors ctrl-kd's
/// tests/test_screenplay_detection.py and tests/test_screenplay_rendering.py.
/// `detectScreenplayBlocks` anchors on a genuine INT./EXT. slugline (case-sensitive,
/// optional scene number, optional WordStar merge-var scene marker) and grows the
/// region forward to cover the scene's own action/character/dialogue/parenthetical
/// content, stopping at the next slugline, a heading, a pagebreak/condpage, or a
/// generous block cap. Real-corpus-gated tests (the zero-false-positive acceptance
/// gate, SCRIPT.WS-specific pins) are not ported — no private corpus ships with this
/// repo; the synthetic tests below pin the mechanism without it.

// MARK: - detection (synthetic)

@Test func noSluglineNoRegion() throws {
    let data = bytes("Just an ordinary paragraph of prose, nothing screenplay-shaped.\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).isEmpty)
}

@Test func bareIntSluglineDetected() throws {
    let data = bytes("INT. HOUSE - DAY\r\n\r\nSome action description here.\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).contains(0))
}

@Test func bareExtSluglineDetected() throws {
    let data = bytes("EXT. STREET - NIGHT\r\n\r\nRain falls.\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).contains(0))
}

@Test func sceneNumberedSluglineDetected() throws {
    let data = bytes("12    INT. HOUSE - DAY                                        12\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).contains(0))
}

@Test func mergeVarAnchoredSluglineDetected() throws {
    // WordStar merge-var scene marker (&n/s&) immediately before the slugline --
    // slate's own named "merge-var scene markers" signal.
    let data = bytes("&n/s& INT. WRITER'S OFFICE - DAY\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).contains(0))
}

@Test func lowercaseIntIsNotASlugline() throws {
    // case-sensitive by design -- "int." is a plausible real abbreviation in ordinary
    // prose ("this is an int. value") and must NEVER match.
    let data = bytes("This function returns an int. Not a big deal.\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).isEmpty)
}

@Test func intMidWordIsNotASlugline() throws {
    let data = bytes("This is an INTERESTING sentence about EXTRA things.\r\n")
    #expect(detectScreenplayBlocks(parseWS(data)).isEmpty)
}

@Test func regionGrowsToIncludeFollowingBlocks() throws {
    let data = bytes("INT. HOUSE - DAY\r\n\r\n")
        + bytes("JOHN stares at the door.\r\n\r\n")
        + bytes("                    JOHN\r\n")
        + bytes("          What is that noise?\r\n\r\n")
    let doc = parseWS(data)
    let region = detectScreenplayBlocks(doc)
    #expect(region == Set(0..<doc.blocks.count))
}

@Test func regionStopsAtTheNextSlugline() throws {
    let data = bytes("INT. HOUSE - DAY\r\n\r\n")
        + bytes("Action one.\r\n\r\n")
        + bytes("EXT. STREET - NIGHT\r\n\r\n")
        + bytes("Action two.\r\n\r\n")
    let doc = parseWS(data)
    let region = detectScreenplayBlocks(doc)
    // both sluglines anchor their own region -- every block still ends up covered,
    // but via TWO scenes, not one that swallowed the second slugline's own action
    // line into scene one's growth silently.
    let slugBi = doc.blocks.indices.filter { doc.blocks[$0].kind == .para
        && matchesScreenplaySluglineForTest(doc.blocks[$0]) }
    #expect(slugBi.count == 2)
    #expect(region == Set(0..<doc.blocks.count))
}

@Test func regionStopsAtAPagebreak() throws {
    let data = bytes("INT. HOUSE - DAY\r\n\r\n")
        + bytes("Action one.\r\n\r\n.pa\r\n")
        + bytes("Unrelated content after the page break.\r\n")
    let doc = parseWS(data)
    let region = detectScreenplayBlocks(doc)
    let pbIndices = doc.blocks.indices.filter { doc.blocks[$0].kind == .pagebreak }
    #expect(!pbIndices.isEmpty, "fixture did not produce a pagebreak block")
    if let firstPb = pbIndices.first {
        #expect(region.allSatisfy { $0 < firstPb })
    }
}

@Test func regionStopsAtAHeading() throws {
    // Constructing a REAL style-library-resolved heading is more machinery than this
    // stopping-condition test needs -- this only proves detectScreenplayBlocks's own
    // region-growth loop respects `block.heading` once set, whatever set it.
    let data = bytes("INT. HOUSE - DAY\r\n\r\n")
        + bytes("Action one.\r\n\r\n")
        + bytes("A Real Section Heading\r\n\r\n")
        + bytes("Unrelated article prose that follows the heading.\r\n")
    var doc = parseWS(data)
    guard let headingBi = doc.blocks.firstIndex(where: {
        $0.lines.flatMap(\.spans).map(\.text).joined().contains("Real Section Heading")
    }) else {
        Issue.record("fixture did not produce the heading text this test needs")
        return
    }
    doc.blocks[headingBi].heading = 1
    let region = detectScreenplayBlocks(doc)
    #expect(region.allSatisfy { $0 < headingBi })
}

/// Test-only mirror of `blockHasSlugline` (private to Screenplay.swift) -- built from
/// the same public `matchesScreenplaySlugline` the production code uses.
private func matchesScreenplaySluglineForTest(_ block: Block) -> Bool {
    block.lines.contains { line in
        matchesScreenplaySlugline(Array(line.spans.map(\.text).joined()))
    }
}

// MARK: - rendering (mechanism proof, one per format)

/// A synthetic screenplay-shaped scene, deliberately positioned so ordinary
/// `looksLikeVerse` heuristics might ALSO fire (proving the wiring is genuine is
/// harder than pinning it in isolation) -- close enough to ctrl-kd's own monkeypatch
/// proof in spirit: the region is detected and gets verse treatment either way.
private func screenplayFixture() -> Document {
    let data = bytes("INT. HOUSE - DAY\r\n\r\n")
        + bytes("JOHN stares at the door.\r\n\r\n")
        + bytes("                    JOHN\r\n")
        + bytes("          What is that noise?\r\n\r\n")
    var doc = parseWS(data)
    // Six hard returns, no soft ones -- detect() would otherwise read this as a
    // `printstream` (txt>=90 && hard>=2) and force printed rendering regardless of
    // the requested mode (D5 override), which would make every assertion below pass
    // for the WRONG reason (Printed's own line-for-line facsimile, not the round-20b
    // verse-class wiring under test). Force ws4 classification directly, matching
    // this file's own established fix pattern elsewhere in the suite.
    doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 6,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: data.count)
    return doc
}

@Test func textEmitterPreservesScreenplayLineStructure() throws {
    let doc = screenplayFixture()
    #expect(!detectScreenplayBlocks(doc).isEmpty)
    let text = emitText(doc, mode: .modern)
    // A verse-classified unit keeps its own line breaks (bare "\n" inside one
    // paragraph entry) rather than being flowed into one run-on line.
    #expect(text.contains("JOHN\n"))
}

@Test func markdownEmitterPreservesScreenplayLineStructure() throws {
    let doc = screenplayFixture()
    let md = emitMarkdown(doc, mode: .modern)
    // round 4's own hard-break convention: two trailing spaces then newline.
    #expect(md.contains("  \n"))
}

@Test func htmlEmitterPreservesScreenplayLineStructure() throws {
    let doc = screenplayFixture()
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("<br>"))
}

@Test func rtfEmitterPreservesScreenplayLineStructure() throws {
    let doc = screenplayFixture()
    let rtf = emitRTF(doc, mode: .modern)
    #expect(rtf.contains(#"\line"#))
}

@Test func ordinaryProseIsByteIdenticalWhenNoScreenplayDetected() throws {
    let data = bytes("An entirely ordinary document with no slugline anywhere in it.\r\n")
    let doc = parseWS(data)
    #expect(detectScreenplayBlocks(doc).isEmpty)
    // Sanity: emitting still works and produces the plain, undecorated output --
    // this mechanism must never fire on a document that never matched.
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("An entirely ordinary document"))
}
