import Testing
@testable import CtrlKD

/// b26-modern item 3 (BUILD-SLATES.md item 27, Jon's decided screenplay ruling, ctrl-kd
/// c82b2ff): when the existing screenplay-layout detection fires
/// (`detectScreenplayBlocks`), Modern PDF must:
///   (a) keep each real numbered page a separate Modern page (never spread one source
///       page's screenplay content across two Modern pages);
///   (b) render the page-number marker ("1." alone at the top of the page) flush
///       against the right margin, below the running head, not at the left margin;
///   (c) keep a slugline's own right-hand scene number on the same line at the right,
///       never dropped to its own line by word-wrap.
/// Only INSIDE a detected screenplay region -- an ordinary document's own numbered
/// list, table, or short line must render exactly as before.
///
/// MECHANISM (`PDFModernLayout.swift`'s `modernFlow`/`modernStreams`; this is the ONLY
/// place in the codebase that renders Modern PDF pages, so this is where the ruling has
/// to live -- neither `Layout.swift`'s shared item stream nor `detectScreenplayBlocks`
/// itself needed to change beyond `SemanticItem.para`'s additive `bi` field):
///   - `screenplayBlocks` (the existing, already-corpus-gated detector) is computed
///     once per document.
///   - A line inside that region matching `matchesScreenplayPageMarker` (nothing but
///     whitespace and a bare 1-4 digit number, optional trailing period) is a page
///     marker: its paragraph gets `align = .right` (rule b) and, if the current Modern
///     page already has body content on it, forces a page break before it (rule a) -- a
///     marker that already opens a fresh page (an explicit `.pa` immediately preceded
///     it, the real SCRIPT.WS shape) costs nothing extra.
///   - A line matching the SAME slugline anchor `detectScreenplayBlocks` itself uses,
///     that ALSO ends in a right-hand number, gets an unbounded wrap width
///     (`modernWrap` can never find a break point), so it can never lose its trailing
///     number to a new line (rule c).
///   - `detectScreenplayBlocks`'s own region growth is documented to extend only
///     FORWARD from its slugline anchor, so a page marker (which precedes the slugline)
///     is never itself a region member -- `screenplayMarkerBis` widens candidacy by
///     one/two blocks forward to cover exactly that shape without touching the shared
///     detector.
///
/// Synthetic fixtures only (CLAUDE.md) -- no private corpus ships with this repo. Port
/// of ctrl-kd's `tests/test_screenplay_pdf.py`.

// MARK: - rule (a)

@Test func pageMarkerForcesABreakWhenThePageAlreadyHasContent() throws {
    let data = ws7Block(0x00)
        + bytes("Some prose before the marker, to give the page real content first.")
        + HARD + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("INT. HOUSE - DAY") + HARD + HARD
        + bytes("JOHN stares at the door for a long moment before speaking quietly.")
        + HARD
    let doc = parseWS(data)
    #expect(!detectScreenplayBlocks(doc).isEmpty, "fixture must trigger screenplay detection")
    let pdf = emitPDF(doc, mode: .modern)
    #expect(contains(pdf, bytes("/Count 2")))
}

@Test func pageMarkerAfterAnExplicitPaCostsNoExtraPage() throws {
    // The real SCRIPT.WS shape: content, then an explicit `.pa`, then the marker as the
    // page's own first line. The marker's own break-forcing must be a no-op here --
    // exactly 2 pages (the .pa's own break), not 3.
    let data = ws7Block(0x00)
        + bytes("Some opening prose that appears before the page break happens.")
        + HARD + bytes(".pa") + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("INT. HOUSE - DAY") + HARD + HARD
        + bytes("JOHN stares at the door for a long moment before speaking quietly.")
        + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    #expect(contains(pdf, bytes("/Count 2")))
}

@Test func markerShapedLineOutsideAScreenplayRegionNeverForcesABreak() throws {
    // Zero-false-positive: the exact same marker SHAPE (whitespace + a bare number)
    // with no slugline anywhere in the document -- an ordinary numbered-list-ish line
    // -- must never force a page break.
    let data = ws7Block(0x00)
        + bytes("Some prose before the marker, to give the page real content first.")
        + HARD + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("More ordinary prose that is definitely not a screenplay at all.")
        + HARD
    let doc = parseWS(data)
    #expect(detectScreenplayBlocks(doc).isEmpty)
    let pdf = emitPDF(doc, mode: .modern)
    #expect(contains(pdf, bytes("/Count 1")))
}

// MARK: - rule (b)

@Test func pageMarkerRendersFlushAgainstTheRightMargin() throws {
    let data = ws7Block(0x00)
        + bytes("Some prose before the marker, to give the page real content first.")
        + HARD + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("INT. HOUSE - DAY") + HARD + HARD
        + bytes("JOHN stares at the door for a long moment before speaking quietly.")
        + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let (margl, _, _, width) = modernGeometry(doc)
    let x = try #require(contentSpans(pdf).first { $0.text == "1." }?.x)
    // "1." at 14pt Times: flush means its OWN right edge sits at the margin, so its Td
    // x (left edge of the glyph run) is somewhat left of that -- checked as "close to
    // the margin", not touching the left margin at all (the pre-fix left-flow failure
    // mode).
    #expect(x > margl + width * 0.7)
}

@Test func markerShapedLineOutsideAScreenplayRegionStaysLeftFlowed() throws {
    let data = ws7Block(0x00)
        + bytes("Some prose before the marker, to give the page real content first.")
        + HARD + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("More ordinary prose that is definitely not a screenplay at all.")
        + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let (margl, _, _, width) = modernGeometry(doc)
    let x = try #require(contentSpans(pdf).first { $0.text == "1." }?.x)
    // left-flowed: nowhere near the right margin (unlike the screenplay case)
    #expect(x < margl + width * 0.6)
}

// MARK: - rule (c)

@Test func sluglineWithTrailingSceneNumberNeverWraps() throws {
    let line = bytes("12    INT. A VERY LONG LOCATION NAME THAT GOES ON AND ON - DAY   12")
    let data = ws7Block(0x00) + line + HARD + HARD + bytes("Action line.") + HARD
    let doc = parseWS(data)
    #expect(!detectScreenplayBlocks(doc).isEmpty, "fixture must trigger detection")
    let pdf = emitPDF(doc, mode: .modern)
    let ys = Set(contentSpans(pdf).filter { $0.text == "DAY" || $0.text == "12" }
        .compactMap(\.y))
    #expect(ys.count == 1, "\(ys)")
}

@Test func equallyLongOrdinaryLineOutsideScreenplayStillWraps() throws {
    // Control: the SAME kind of overflow (a line too wide for the page), but with no
    // slugline anywhere -- must wrap normally, proving the no-wrap mechanism is doing
    // real work above, not just "everything happens to fit."
    let line = bytes("This is a very long ordinary line of prose text that goes "
                     + "well past the margin at twelve point type")
    let data = ws7Block(0x00) + fontBlock(0, points: 12.0) + line + HARD
    let doc = parseWS(data)
    #expect(detectScreenplayBlocks(doc).isEmpty)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = Set(contentSpans(pdf).compactMap(\.y))
    #expect(ys.count > 1, "control line should have wrapped onto more than one visual line")
}

@Test func sluglineWithoutATrailingNumberIsUnaffected() throws {
    // A slugline with NO right-hand scene number has nothing to protect -- must render
    // through the ordinary wrap path, same as any other line (mechanism must not
    // blanket-disable wrapping for every screenplay-detected line, only the specific
    // shape that needs it).
    let data = ws7Block(0x00) + fontBlock(0, points: 12.0)
        + bytes("INT. A VERY LONG LOCATION NAME THAT GOES ON AND ON AND ON - DAY")
        + HARD + HARD + bytes("Action line.") + HARD
    let doc = parseWS(data)
    #expect(!detectScreenplayBlocks(doc).isEmpty)
    let pdf = emitPDF(doc, mode: .modern)
    let texts = Set(contentSpans(pdf).map(\.text))
    // no trailing number to protect -- ordinary wrap behavior decides this line's own
    // layout; the real assertion is just that the mechanism didn't crash and the rest
    // of the region still renders.
    #expect(texts.contains("DAY"))
    #expect(texts.contains("Action"))
}

// MARK: - Printed unaffected

@Test func printedModeNeverReadsScreenplayState() throws {
    // Printed PDF's own code path (`layoutPrintedPages`/`pageStream`) is completely
    // separate from `modernStreams` -- a screenplay-shaped document must render
    // identically in Printed mode whether or not the Modern-only screenplay mechanism
    // exists. Proven indirectly: Printed emits every line verbatim regardless of
    // `detectScreenplayBlocks`, so the same fixture's Printed output must show the
    // marker's OWN typed spacing (left-flowed, WS7's own literal-facsimile doctrine),
    // never a right-aligned override.
    let data = ws7Block(0x00)
        + bytes("Some prose before the marker, to give the page real content first.")
        + HARD + HARD
        + bytes("                                                            1.")
        + HARD + HARD
        + bytes("INT. HOUSE - DAY") + HARD + HARD
        + bytes("JOHN stares at the door for a long moment before speaking quietly.")
        + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(pdf.starts(with: bytes("%PDF")))
    #expect(contains(pdf, bytes("/Count 1")))
}
