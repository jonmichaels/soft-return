import Testing
@testable import CtrlKD

/// job-011's own tests: the behavior the vectors don't reach.
///
/// The 15 vector cases in `VectorTests.swift` prove the layout against Python for five real
/// documents. What they cannot reach is anything those five documents don't contain — and
/// the page cap is the big one, since every vector document fits on one or two short pages
/// and none of them comes near 54 lines. The rest is the `EmitOutput` plumbing, which has no
/// Python counterpart to generate vectors from.

// MARK: - Pagination at the cap

/// A document of `n` single-word lines in one paragraph block.
private func linesDoc(_ n: Int) -> Document {
    Document(blocks: [Block(lines: (1...n).map { Line(spans: [Span(text: "line\($0)")]) })])
}

@Test func modernPaginatesAtFiftyFourLines() {
    // No vector document is longer than 7 lines, so the `page.count >= cap` branch — the
    // one that makes a long document a multi-page PDF at all — is unproven by all 10 of
    // them. 54 lines exactly fills page 1; the 55th starts page 2.
    let pages = docToPagelines(linesDoc(55), printed: false)
    #expect(pages.count == 2)
    #expect(pages[0].count == PDFMetrics.linesModern)
    #expect(pages[0].first?.first?.text == "line1")
    #expect(pages[0].last?.first?.text == "line54")
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line55")

    // And exactly 54, which is where the blank-sheet bug lived. Modern mode ends each block
    // with a blank line, so a full page of content pushes that blank onto page 2, where the
    // trailing-blank strip empties it — leaving a real empty second page. Python 1.1.5 tried
    // to pop it and popped too early to see it (job-012); 1.1.6 pops after the stripping and
    // this is one page, as it always should have been.
    #expect(docToPagelines(linesDoc(54), printed: false).map(\.count) == [54])
}

@Test func printedPaginatesAtFiftyFiveLinesWithNoPageGeometry() {
    // A document with no page geometry at all (`doc.page == nil` — what a bare
    // `parsePrintstream` capture produces; `linesDoc` here builds one by hand the same
    // way) gets WordStar's DOCUMENTED defaults: `.pl 66 - .mt 3 - .mb 8` = 55.
    //
    // This asserted 66 through ctrl-kd 2.0.0, on the reasoning that a print stream's own
    // margin blanks travel in-band so its budget is the whole physical page. That
    // reasoning was checked against raw bytes and retracted (2026-08-03): real
    // print-to-disk output carries no form feeds and no top margin after page one. 66 was
    // a page size WordStar does not document and no evidence supported — and the figure
    // had already been 60 before that, for a third reason. The model now matches the
    // program: run live, WordStar 4 puts 11-line gaps (`.mb 8 + .mt 3`) on a 66-line
    // pitch, which is 55 lines of text.
    #expect(docToPagelines(linesDoc(55), printed: true).count == 1)

    let pages = docToPagelines(linesDoc(56), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 55)
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line56")
}

/// A `PageGeometry` built from just `.pl`/`.mt`/`.mb` (WordStar's own defaults for
/// everything else — `.hm`/`.fm`/`.lh`/`.ls` never vary in this file), with `textLines`
/// computed the same way `parseWS` computes it so a hand-built test fixture can't drift
/// from the real derivation.
private func geometry(
    pl: Double, height: Double, size: String, sizeSource: Provenance = .file,
    mt: Double = 3, mtSource: Provenance = .default,
    mb: Double = 8, mbSource: Provenance = .default
) -> PageGeometry {
    PageGeometry(
        plLines: pl, heightIn: height, sizeName: size, sizeSource: sizeSource,
        mtLines: mt, mtSource: mtSource, mbLines: mb, mbSource: mbSource,
        // ctrl-kd 2.0.0 defaults -- this helper never varies `.po`/`.cw`, so both stay at
        // WordStar's own defaults (8 columns, 12/120in) the same way `parseWS` would
        // resolve them for a file that never sets either.
        poCols: 8, poSource: .default,
        hmLines: 2, hmSource: .default, fmLines: 2, fmSource: .default,
        lh48: 8, lhSource: .default, ls: 1, lsSource: .default,
        cw120: 12, cwSource: .default,
        textLines: textLinesPerPage(pl: pl, mt: mt, mb: mb, lh48: 8)
    )
}

/// `linesDoc` with an explicit `PageGeometry`, exactly as `parseWS` produces for a real
/// file — nil `.page` (the case the other tests above cover) only happens for a bare
/// print-stream capture.
private func linesDoc(_ n: Int, page: PageGeometry) -> Document {
    Document(
        blocks: [Block(lines: (1...n).map { Line(spans: [Span(text: "line\($0)")]) })],
        page: page
    )
}

@Test func printedCapacityIsGeometricNotRawPL() {
    // The bug this test proves fixed (job-011): `printedPageCapacity` used to read the
    // file's raw declared `.pl` value (66 for a default Letter page) straight off as the
    // line-break threshold. ctrl-kd 1.3.0's `printedCap` (PDFLayout.swift, port of Python's
    // `_printed_cap`) uses WordStar's OWN vertical model instead — `.pl - .mt - .mb` at the
    // `.lh` line height, WordStar's own defaults giving 55 for this Letter page, not the
    // raw 66 `.pl` states OR the 60 an intermediate (pre-1.3.0, fixed-72pt-margin) version
    // of this fix produced. `.pl 66 .mt 3 .mb 8` (the common case: every document that
    // never sets any of the three resolves to exactly this) must therefore break at 55.
    let letter = geometry(pl: 66, height: 11.0, size: "Letter")
    #expect(docToPagelines(linesDoc(55, page: letter), printed: true).count == 1)
    let pages = docToPagelines(linesDoc(56, page: letter), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 55)
    #expect(pages[1].count == 1)
    #expect(pages[1].first?.first?.text == "line56")

    // A second, differently-sized page proves the geometry is actually being READ (not just
    // hardcoded back to one number): Legal, `.pl 84 .mt 3 .mb 8` -> 84 - 3 - 8 = 73 lines,
    // not the raw 84 the very first version of this fix would have used, nor the
    // fixed-72pt-margin 78 an intermediate version gave.
    let legal = geometry(pl: 84, height: 14.0, size: "Legal")
    #expect(docToPagelines(linesDoc(73, page: legal), printed: true).count == 1)
    let legalPages = docToPagelines(linesDoc(74, page: legal), printed: true)
    #expect(legalPages.count == 2)
    #expect(legalPages[0].count == 73)
    #expect(legalPages[1].count == 1)
}

@Test func printedCapacityFloorsOnDegenerateGeometry() {
    // A vanishingly small or absent page can never send the capacity below
    // `footnoteFloor + 1` (4) -- Python's own floor (pdf.py:53,60). Exercised at the
    // PageGeometry boundary rather than by reaching into the private floor constant.
    // `.mt 3 .mb 8` against a one-line `.pl` drives `textLinesPerPage` deep negative
    // (1 - 3 - 8 = -10), which is exactly the degenerate case the floor exists for.
    let tiny = geometry(pl: 1, height: 0.01, size: "Custom")
    #expect(docToPagelines(linesDoc(4, page: tiny), printed: true).count == 1)
    let pages = docToPagelines(linesDoc(5, page: tiny), printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 4)
    #expect(pages[1].count == 1)
}

// MARK: - Finding 3 (b26-print-fidelity-2): per-page .mt/.mb statefulness

@Test func printedMidDocumentMtMbGetsItsOwnPageCapacity() {
    // SCRIPT.WS changes .mt/.mb around its embedded worked-example figures (measured:
    // block 64's .mt1/.mb0), and real WS7 fits the figure on ONE page using the
    // figure's OWN tiny margins -- the engine used to apply the document-global FIRST-
    // occurrence .mt/.mb (7/6 here) to every page, capping capacity at pl - 7 - 6 = 53
    // lines regardless, splitting a 60-line tiny-margin section across two pages.
    // Fixed: a fresh page picks up whatever .mt/.mb was in force at its own first block
    // (mtMbCheckpoints, mirroring how .lh already tracks per-line state) -- pl - 1 - 0 =
    // 65 lines of room, so the same 60 lines fit on one page.
    var data = bytes(".mt7") + HARD + bytes(".mb6") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".mt1") + HARD + bytes(".mb0") + HARD
    for i in 1...60 { data += bytes("Tiny line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.mtLines == 7.0)      // global: the FIRST occurrence
    #expect(doc.page?.mbLines == 6.0)
    let checkpoints = mtMbCheckpoints(doc)
    #expect(checkpoints[0].blockIndex == 0 && checkpoints[0].mt == 7.0 && checkpoints[0].mb == 6.0)
    let last = checkpoints[checkpoints.count - 1]
    #expect(last.mt == 1.0 && last.mb == 0.0)      // the figure's own override
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)                      // NOT 3 -- see comment above
    #expect(pages[0].count == 20 && pages[1].count == 60)
    #expect(pages[1].mtLines == 1.0 && pages[1].mbLines == 0.0)
    #expect(pages[0].mtLines == nil)               // untouched: "use the doc global"
}

@Test func printedMidDocumentMtMbNeverShrinksBelowTheGlobalCapacity() {
    // b26-mtmb-general (LJ6DTP.WS): the OTHER direction from the sibling test above --
    // a mid-document .mt/.mb change may LOOSEN a page's capacity, but WS7 does not let
    // one TIGHTEN it. LJ6DTP.WS's block 12 (.mt1"/.mb1", right after a .pa, structurally
    // identical to SCRIPT's own figure-margin pattern) computes a LOCAL cap (46 lines,
    // pl 66 - mt 6.0 - mb 6.0) SMALLER than the document's own global cap (48, from its
    // opening .mt 1.1"/.mb .5") -- honoring it split LJ6DTP's "Proportional Spacing
    // Tables" section across two engine pages where real WS7 (measured: LJ6DTP.pcl, page
    // 7 of 8) prints it on one; matching WS7's page count (8, not 9) needs the clamp:
    // printedCapFor never returns less than printedCap(doc).
    // Reproduced synthetically here: a tighter .mb after a .pa must NOT split content
    // that fits within the document's own GLOBAL capacity.
    var data = bytes(".mt3") + HARD + bytes(".mb3") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".mb50") + HARD
    for i in 1...39 { data += bytes("Tight line \(i).") + HARD }
    let doc = parseWS(data)
    let checkpoints = mtMbCheckpoints(doc)
    let last = checkpoints[checkpoints.count - 1]
    #expect(last.mt == 3.0 && last.mb == 50.0)     // the tighter local override
    let globalCap = printedCap(doc)
    #expect(printedCapFor(doc, mtLines: 3.0, mbLines: 50.0) == globalCap)   // clamped, not 13
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)                      // NOT 4 -- the 39 "Tight"
                                                    // lines fit on ONE page
    #expect(pages[0].count == 20 && pages[1].count == 39)
    #expect(pages[1].mbLines == 50.0)              // the override still RENDERS
                                                    // (bottom margin/footer geometry
                                                    // unaffected) -- only capacity clamps
}

@Test func printedMidDocumentMtMbRepositionsTheHeader() {
    // The SAME per-page .mt (Finding 3) reaches `runningOps` too, via the `doc.page`
    // swap `emitPDF` now does per page -- `runningOps`'s own existing
    // `max(0.0, mt - hm - topHead)` formula (unchanged) naturally degrades the header
    // to right-at-the-top when the page's own .mt is too small to fit the usual .hm gap
    // above it, with no separate "suppress the header" rule needed. `.hm3` here is
    // EXPLICIT (matching real SCRIPT.WS's own `.HM 3`, never restated on the tiny page
    // either -- b26-header-baseline: `.hm` only participates in `headBase` when the
    // document set it itself, see `runningOps`'s own doc comment; this fixture's
    // explicit `.hm` keeps it in the formula on BOTH pages, exactly like SCRIPT). Pinned
    // against the same fixture's actual y values: normal page (.mt 7, .hm 3) headBase =
    // 7-3-1 = 3 -> y=744/top-down 48; tiny page (.mt 1, .hm still 3) headBase =
    // max(0, 1-3-1) = 0 -> y=780/top-down 12, TWELVE points closer to the physical top --
    // not absent, just compressed, exactly what real WS7 does (measured: SCRIPT.pcl's
    // own normal/figure-1 pages, top-down 48/12 exactly).
    var data = bytes(".mt7") + HARD + bytes(".mb6") + HARD + bytes(".hm3") + HARD
        + bytes(".he TITLE") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".mt1") + HARD + bytes(".mb0") + HARD
    for i in 1...60 { data += bytes("Tiny line \(i).") + HARD }
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let ys = contentSpans(pdf).filter { $0.text == "TITLE" }.compactMap(\.y)
    #expect(ys == [744.0, 780.0])
}

@Test func printedSingleGeometryDocumentNeverTouchesMtMbCheckpoints() {
    // A document that never repeats .mt/.mb after its own opening geometry (every
    // document this project has ever rendered, before SCRIPT.WS's figures) gets exactly
    // ONE checkpoint -- `mtMbAt` returns the SAME pair for every block, so
    // `Page.mtLines`/`mbLines` stay at their nil default and no page ever triggers the
    // `doc.page` swap in `emitPDF`. Byte-identity for real documents is verified
    // separately (LYING.WS sha256 parity); this pins the mechanism directly.
    var data = bytes(".mt7") + HARD + bytes(".mb6") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    let checkpoints = mtMbCheckpoints(doc)
    #expect(checkpoints.count == 1)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.allSatisfy { $0.mtLines == nil && $0.mbLines == nil })
}

// MARK: - register b31-dot-command-sweep: per-page .pl

@Test func printedMidDocumentPlAfterPaGetsItsOwnPageCapacity() {
    // `.pl` is stateful exactly like `.mt`/`.mb` (Finding 3) -- real WS7 (PL_PROBE,
    // dosbox-x, register b31-dot-command-sweep) printed 18 lines on a page held to
    // `.pl 20`/`.mt 1`/`.mb 1` (cap 18) and 38 on the page after a mid-document `.pl 40`
    // (cap 38) -- the SECOND value, not the document's first-occurrence one, governs the
    // page it appears on. This reproduces it after an explicit `.pa`, the same structural
    // shape as the sibling `mtMbCheckpoints` tests above.
    var data = bytes(".pl20") + HARD + bytes(".mt1") + HARD + bytes(".mb1") + HARD
    for i in 1...18 { data += bytes("Apage line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".pl40") + HARD
    for i in 1...60 { data += bytes("Bpage line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.plLines == 20.0)        // global: first occurrence
    let checkpoints = plCheckpoints(doc)
    // checkpoints[0] itself is WordStar's own hardcoded default (66) -- the SEED for
    // "before any real .pl occurrence" -- immediately superseded by another bi=0 entry
    // once `.pl20` (this document's own opening geometry) is walked; `plAt(checkpoints, 0)`
    // resolves the one that actually governs block 0, exactly as the render loop does.
    #expect(checkpoints[0].pl == 66.0)
    #expect(plAt(checkpoints, 0) == 20.0)
    #expect(checkpoints[checkpoints.count - 1].pl == 40.0)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 3)
    #expect(pages.map(\.count) == [18, 38, 22])   // 60 Bpage lines at cap 38
    #expect(pages[1].plLines == 40.0 && pages[2].plLines == 40.0)
    #expect(pages[0].plLines == nil)              // untouched: "use the doc global"
}

@Test func printedMidDocumentPlWithNoForcedBreakStillGetsItsOwnCapacity() {
    // The organic-break case -- NO `.pa`, the content simply overflows the page -- which
    // is exactly PL_PROBE's own shape (real WS7 was never asked for a forced break) and
    // which `mtMbCheckpoints`'s two real oracles never happened to exercise: both of
    // THEIR mid-document changes sit right after a `.pa`, so the pagination loop's
    // fresh-page recompute (gated on `page.isEmpty`, true only once the page has actually
    // emptied) fired correctly by construction. Without a `.pa`, the line that overflows
    // the OLD page is also the new page's own first line, in the SAME loop iteration --
    // `page.isEmpty` is still false at that point (the old page hasn't been closed yet
    // when the gate is checked), so the recompute silently never re-fired for any organic
    // break. `recomputeGeom` closed the gap: a second recompute call sits right after the
    // organic close, using the line that triggered it.
    var data = bytes(".pl20") + HARD + bytes(".mt1") + HARD + bytes(".mb1") + HARD
    for i in 1...18 { data += bytes("Apage line \(i).") + HARD }
    data += HARD + bytes(".pl40") + HARD          // blank line -> new block, no .pa
    for i in 1...60 { data += bytes("Bpage line \(i).") + HARD }
    let doc = parseWS(data)
    let pages = docToPagelines(doc, printed: true)
    // page 1: the 18 Apage lines (cap 18, .pl 20). page 2: the blank (still under the OLD
    // checkpoint -- it precedes ".pl40" in the source) plus the first 17 Bpage lines (18
    // total, same old cap). page 3: the organic break lands here, recomputes to cap 38
    // (.pl 40) for the remaining 38 Bpage lines. page 4: the last 5.
    #expect(pages.map(\.count) == [18, 18, 38, 5])
    #expect(pages[2].plLines == 40.0)
    #expect(pages[0].plLines == nil && pages[1].plLines == nil)
}

@Test func printedSingleGeometryDocumentNeverTouchesPlCheckpoints() {
    // Mirrors `printedSingleGeometryDocumentNeverTouchesMtMbCheckpoints` in EFFECT, not
    // in raw checkpoint-list shape: `.pl50` here sits at the document's own true start
    // (block 0), so `plCheckpoints` resolves it to a SECOND entry superseding the
    // hardcoded-default seed at that same block (`plCheckpoints`'s doc comment) -- but the
    // render loop compares against `doc.page?.plLines` (also 50.0, `ParseWS.swift`'s own
    // first-occurrence reading), so no page ever gets its own `plLines` override:
    // byte-identical to before this fix for every document that declares its geometry
    // once, up front, and never repeats it.
    var data = bytes(".pl50") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    let checkpoints = plCheckpoints(doc)
    #expect(plAt(checkpoints, 0) == 50.0)
    #expect(plAt(checkpoints, 0) == doc.page?.plLines)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.allSatisfy { $0.plLines == nil })
}

// MARK: - register b31-dot-command-sweep: per-page .hm/.fm

@Test func printedMidDocumentHmFmRepositionsHeaderAndFooterWithMtUntouched() {
    // `.hm`/`.fm` are stateful too (register b31-dot-command-sweep) -- and, unlike
    // `.mt`/`.mb`/`.pl`, this is measurable even when `.mt` itself NEVER moves: real WS7
    // (HMFM_PROBE, dosbox-x) held `.mt` at its factory default for the whole document and
    // still printed its header/footer at two different PCL rows once a mid-document
    // `.hm 6`/`.fm 6` (factory default `.hm 2`/`.fm 2`) took effect -- 35.7pt/75.6pt
    // before, 12.0pt/80.4pt after (both within the usual 0.3pt decipoint residual).
    //
    // This also FALSIFIES the mtSource-only header gate (`runningOps`) -- `.mt` is
    // `.default` on EVERY page here, yet the header row still moves, because `.hm` itself
    // was explicitly typed (hmSource == .file) on the pages after it. Fixed to an OR of
    // the two sources; see `runningOps`'s own doc comment. The footer needed no formula
    // change -- `footLine = pl - mb + fm` was already unconditional, and 66-8+2=60 vs
    // 66-8+6=64 (*12 = 48pt) matches the measured 48pt shift exactly, no residual.
    //
    // Register b31, E3 open items 2+3 (2026-08-25, ctrl-kd 5f3a102): `.hm6`/`.fm6` here
    // sit AFTER 60 lines of real body text, so `parsePageDot` (pre-text-last-wins) no
    // longer lets this mid-document occurrence become the document's own global
    // reading -- `doc.page?.hmLines`/`fmLines` now correctly stay at WordStar's
    // hardcoded default (2.0/2.0), matching what `hmFmCheckpoints`'s own
    // hardcoded-default seed already gave block 0. That RETIRES the degenerate case this
    // test used to pin (the parser's global reading disagreeing with the checkpoint
    // global on the PRE-change pages): pages 1-2 no longer need their own override at
    // all (both readings now agree at 2.0), and pages 3-4 are the ones that genuinely
    // deviate and get the explicit override instead -- the override has moved to the
    // pages that actually changed, which is what it should have been pointing at all
    // along. The measured PCL rows (ysH/ysF below) are real WS7 ground truth and do not
    // move.
    var data = bytes(".he TITLE") + HARD + bytes(".fo FOOTTXT") + HARD
    for i in 1...60 { data += bytes("Body line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".hm6") + HARD + bytes(".fm6") + HARD
    for i in 1...60 { data += bytes("Page2 line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.mtSource == .default)       // .mt NEVER appears
    #expect(doc.page?.hmLines == 2.0 && doc.page?.fmLines == 2.0)
    #expect(doc.page?.hmSource == .default && doc.page?.fmSource == .default)
    let checkpoints = hmFmCheckpoints(doc)
    let last = checkpoints[checkpoints.count - 1]
    #expect(last.hm == 6.0 && last.fm == 6.0)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0].hmLines == nil && pages[0].fmLines == nil)   // agrees with the
    #expect(pages[1].hmLines == nil && pages[1].fmLines == nil)   // now-correct document
                                                                    // default (2.0/2.0):
                                                                    // no override needed
    #expect(pages[2].hmLines == 6.0 && pages[2].fmLines == 6.0)    // these are the pages
    #expect(pages[3].hmLines == 6.0 && pages[3].fmLines == 6.0)    // that actually
                                        // deviate from the document's true opening geometry
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    let ysH = spans.filter { $0.text == "TITLE" }.compactMap(\.y)
    let ysF = spans.filter { $0.text == "FOOTTXT" }.compactMap(\.y)
    #expect(ysH == [756.0, 756.0, 780.0, 780.0])
    #expect(ysF == [60.0, 60.0, 12.0, 12.0])
}

@Test func printedSingleGeometryDocumentNeverTouchesHmFmCheckpoints() {
    // A document that declares `.hm`/`.fm` once, up front (or never at all), never gets a
    // per-page render-time override -- byte-identical to before this fix.
    var data = bytes(".hm5") + HARD + bytes(".fm5") + HARD
    for i in 1...20 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    let checkpoints = hmFmCheckpoints(doc)
    let (hm, fm) = hmFmAt(checkpoints, 0)
    #expect(hm == 5.0 && fm == 5.0)
    #expect(hm == doc.page?.hmLines && fm == doc.page?.fmLines)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.allSatisfy { $0.hmLines == nil && $0.fmLines == nil })
}

// MARK: - register b31-dot-command-sweep: per-page .pn

@Test func printedMidDocumentPnReanchorsNumberingFromThePageItLandsOn() {
    // `.pn` is stateful too -- the WS4 finding (2026-08-03, `pnSetsTheStartingPageNumber`)
    // only ever measured a SINGLE `.pn` (numbering pages 7, 8, 9), never a second one later
    // in the same document. Real WS7 (PN_PROBE, dosbox-x, register b31-dot-command-sweep)
    // printed page 1 as "10", page 2 as "11" (a `.pn 10` up front, incrementing normally),
    // then page 3 as "500" and page 4 as "501" once a mid-document `.pn 500` was reached --
    // re-anchoring the count from the page it lands on, exactly like the first `.pn` does.
    // Before this, `pnStart` (`ParseWS.swift`'s "first occurrence wins") was read ONCE,
    // globally: this exact document would have numbered every page 10, 11, 12, 13, silently
    // ignoring the second `.pn` entirely.
    //
    // A blank line separates the two `.pn`-bearing sections -- the same block-boundary
    // requirement the organic-break `.pl` test above needs: `Document.dotPositions` is
    // BLOCK-granular, so `.pn 500` needs its own block to be distinguishable from `.pn 10`'s.
    var data = bytes(".he PAGENO #") + HARD + bytes(".pn 10") + HARD
    for i in 1...110 { data += bytes("Numline \(i).") + HARD }
    data += HARD + bytes(".pn 500") + HARD
    for i in 111...220 { data += bytes("Numline \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.pnStart == 10)              // global: first occurrence
    let checkpoints = pnCheckpoints(doc)
    #expect(checkpoints[checkpoints.count - 1].pn == 500)
    let pdf = emitPDF(doc, mode: .printed)
    let nums = contentSpans(pdf).filter { $0.text.hasPrefix("PAGENO ") }
        .compactMap { Int($0.text.dropFirst("PAGENO ".count)) }
    #expect(nums == [10, 11, 500, 501, 502])
}

@Test func printedSinglePnDocumentNeverTouchesPnCheckpoints() {
    // A document that sets `.pn` once, up front (or never at all), never gets a per-page
    // override beyond the normal +1-per-page count -- byte-identical to before this fix.
    var data = bytes(".he PAGENO #") + HARD + bytes(".pn 7") + HARD
    for i in 1...110 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    let checkpoints = pnCheckpoints(doc)
    let pages = docToPagelines(doc, printed: true)
    let nums = resolvePageNumbers(checkpoints, pages)
    #expect(nums == [7, 8])                       // matches the WS4 finding
    let pdf = emitPDF(doc, mode: .printed)
    let rendered = contentSpans(pdf).filter { $0.text.hasPrefix("PAGENO ") }
        .compactMap { Int($0.text.dropFirst("PAGENO ".count)) }
    #expect(rendered == nums)
}

// MARK: - Page breaks

@Test func consecutivePageBreaksLeaveABlankPage() {
    // Python appends the current page on a break even when it is empty (`if page or l is
    // None`), so two `.pa` in a row cost a sheet of paper. The pagebreak vector has one
    // break between two paragraphs and cannot tell that apart from "skip empty pages".
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "first")])]),
        Block(kind: .pagebreak),
        Block(kind: .pagebreak),
        Block(lines: [Line(spans: [Span(text: "last")])]),
    ])
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 3)
    #expect(pages[0].first?.first?.text == "first")
    #expect(pages[1].isEmpty)
    #expect(pages[2].first?.first?.text == "last")
}

@Test func softpageNeverBreaksAPage() {
    // WSFORMAT.TXT on 0Bh End of page: "This sequence should usually be ignored. It's
    // used by the WordStar editor to keep track of page breaks. It is TRANSIENT, and
    // moves around with the page break."
    //
    // MEASURED on WordStar 7 (2026-08-04): the same document printed with and without
    // 0x0B marks produced BYTE-IDENTICAL output. The marks carry two words (VMIs on page,
    // line # on page) and the print pipeline never reads them. Honouring them as breaks
    // changed the page count of 43 archive documents. The block is still PARSED (real
    // structure a viewer may want); no renderer may act on it.
    //
    // Written as the minimal pair the physical experiment was: marked versus unmarked.
    let p1 = bytes("First paragraph of perfectly plain prose.")
    let p2 = bytes("Second paragraph, still plain.")
    let p3 = bytes("Third paragraph closes the document.")
    let mark = ws7Block(0x0B, payload: [24, 0, 3, 0])
    let base = parseWS(ws7Block(0x00) + p1 + HARD + p2 + HARD + p3 + HARD)
    let marked = parseWS(ws7Block(0x00) + p1 + HARD + mark + p2 + HARD + mark + p3 + HARD)

    #expect(marked.blocks.flatMap(\.lines).filter(\.softpage).count == 2)
    // and the mark must not sever the flow into extra blocks
    #expect(marked.blocks.map(\.kind) == base.blocks.map(\.kind))
    for mode in [EmitMode.printed, .modern] {
        #expect(emitText(marked, mode: mode) == emitText(base, mode: mode))
        #expect(emitHTML(marked, mode: mode) == emitHTML(base, mode: mode))
        #expect(emitRTF(marked, mode: mode) == emitRTF(base, mode: mode))
    }
    for printed in [true, false] {
        #expect(docToPagelines(marked, printed: printed).count
                == docToPagelines(base, printed: printed).count)
    }
}

@Test func emptyDocumentIsOneEmptyPage() {
    // `pages or [[]]`. Reachable — an empty document is what a zero-length parse produces —
    // and the leading-blank pass indexes `pages[0]`, so getting this wrong is a crash, not
    // a wrong page.
    #expect(docToPagelines(Document(), printed: true) == [[]])
    #expect(docToPagelines(Document(), printed: false) == [[]])
    #expect(docToPagelines(Document(blocks: [Block()]), printed: true) == [[]])
}

// MARK: - The machine margin

@Test func lonePrintedPageFallsBackToItsOwnLeadingBlanks() {
    // With no page 2 to measure against, Python takes page 1's own leading count as the
    // machine margin — so a single-page print stream loses all its top blanks. Every
    // multi-page vector proves the `min(...)` half; this proves the fallback, which a port
    // could just as easily have written as "strip nothing".
    //
    // The machine-margin strip applies ONLY to a print stream (`.detection.variant ==
    // .printstream`): a parsed WS document's own leading blanks are authorial, not the
    // machine's, and are never stripped -- see `finalizePages`.
    let doc = Document(blocks: [Block(lines: [
        Line(), Line(), Line(spans: [Span(text: "text")]),
    ])], detection: Detection(variant: .printstream))
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1)
    #expect(pages[0].count == 1)
    #expect(pages[0][0].first?.text == "text")
}

@Test func chapterDropSurvivesOnlyWhatPagesTwoPlusAllow() {
    // The rule the job called the subtlest in the file, in its pure form: page 1 opens with
    // 5 blanks, page 2 with 2. Two of page 1's are the machine margin and go; three are the
    // author's chapter drop and stay.
    func page(blanks: Int, text: String) -> [Block] {
        [Block(lines: Array(repeating: Line(), count: blanks)
            + [Line(spans: [Span(text: text)])])]
    }
    // A print stream: its own leading blanks on pages 2+ are the machine's uniform top
    // margin (see `finalizePages`); a parsed WS document's are never stripped at all.
    let doc = Document(blocks: page(blanks: 5, text: "Chapter One")
        + [Block(kind: .pagebreak)]
        + page(blanks: 2, text: "continues"),
        detection: Detection(variant: .printstream))

    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].count == 4)                    // 3 surviving blanks + the text
    #expect(pages[0][0].isEmpty)
    #expect(pages[0][3].first?.text == "Chapter One")
    #expect(pages[1].count == 1)                    // both of page 2's blanks were machine
    #expect(pages[1][0].first?.text == "continues")

    // Modern mode has no machine margin to preserve against: it did the layout itself, so
    // every leading blank on every page goes — the drop does not survive a reflow. (The
    // line comes back through the wrapper, so it is three segments now, not one.)
    let modern = docToPagelines(doc, printed: false)
    #expect(modern[0].count == 1)
    #expect(modern[0][0].map(\.text).joined() == "Chapter One")
}

// MARK: - wrapLine / coalesce edges

@Test func wrapLineAlwaysReturnsALine() {
    // `if line or not lines` — an empty IR line wraps to one empty page line, not to no
    // lines at all, and the paragraph spacing in `docToPagelines` depends on it.
    #expect(wrapLine([], width: 65) == [[]])
    #expect(wrapLine([Span(text: "")], width: 65) == [[]])
    #expect(wrapLine([Span(text: "   ")], width: 65) == [[]])
}

@Test func wrapLineNeverBreaksMidWord() {
    // A word longer than the column overflows rather than being split — `col and` in the
    // guard means a token at column 0 is placed whatever its length.
    let long = String(repeating: "x", count: 30)
    #expect(wrapLine([Span(text: long)], width: 10) == [[Span(text: long)]])

    let got = wrapLine([Span(text: "ab \(long) cd")], width: 10)
    #expect(got.count == 3)
    #expect(got[0].map(\.text) == ["ab"])
    #expect(got[1].map(\.text) == [long])
    #expect(got[2].map(\.text) == ["cd"])
}

@Test func wrapLineCountsTabsAsCharactersNotSpaces() {
    // Python splits on `( +)` — literal spaces — but tests `isspace()`, which a tab passes.
    // So a tab inside a word is part of the word, and a span that is only a tab is a
    // whitespace token that gets stripped from the end of a line.
    #expect(wrapLine([Span(text: "a\tb")], width: 65) == [[Span(text: "a\tb")]])
    #expect(wrapLine([Span(text: "word"), Span(text: "\t")], width: 65)
            == [[Span(text: "word")]])
}

@Test func coalesceMergesOnlyAcrossEqualStyles() {
    #expect(coalesce([]) == [])
    // Same styles merge however many segments there are; a different style breaks the run,
    // and an identical style AFTER it starts a new one rather than rejoining the first.
    let line: PageLine = [
        Span(text: "a", styles: .bold), Span(text: "b", styles: .bold),
        Span(text: "c"),
        Span(text: "d", styles: .bold),
    ]
    #expect(coalesce(line) == [
        Span(text: "ab", styles: .bold), Span(text: "c"), Span(text: "d", styles: .bold),
    ])
    // Style equality is by set, not by insertion order.
    #expect(coalesce([Span(text: "x", styles: [.bold, .italic]),
                      Span(text: "y", styles: [.italic, .bold])])
            == [Span(text: "xy", styles: [.bold, .italic])])
}

// MARK: - EmitOutput plumbing

/// A stand-in binary emitter — the shape `emit_pdf` will have in Job B.
private let fakeBinary = Emitter(name: "fake", ext: ".fake") { doc, _, _ in
    .data(Array("FAKE".utf8) + Array(doc.iterLines().map { $0.text() }.joined().utf8))
}

@Test func convertRefusesToStringifyABinaryFormat() throws {
    let registry = EmitterRegistry.standard.register(fakeBinary)
    let data = makeProse()

    #expect(throws: EmitError.binaryFormat(name: "fake", ext: ".fake")) {
        _ = try convert(data, to: "fake", registry: registry)
    }
    // convertData is the front door that serves both kinds.
    let out = try convertData(data, to: "fake", registry: registry)
    #expect(out.starts(with: Array("FAKE".utf8)))
}

@Test func convertDataEncodesTextFormatsAsUTF8() throws {
    // A text format through the data door is the same rendering, UTF-8 encoded — this is
    // what a save-to-disk caller gets, and it must not differ from what the preview showed.
    let data = makeProse()
    let text = try convert(data, to: "markdown")
    #expect(try convertData(data, to: "markdown") == Array(text.utf8))
}

@Test func emitOutputAccessorsAgree() {
    let text = EmitOutput.text("hi")
    #expect(text.asText == "hi")
    #expect(text.asBytes == Array("hi".utf8))
    #expect(!text.isBinary)

    let data = EmitOutput.data([0x25, 0x50])
    #expect(data.asText == nil)
    #expect(data.asBytes == [0x25, 0x50])
    #expect(data.isBinary)
}

@Test func builtInEmittersAllReportAsText() {
    // The `text:` convenience wraps each of the four; if one were registered raw and
    // returned `.data`, `convert` would start throwing for it.
    let doc = try! parse(makeProse())
    for name in ["text", "markdown", "html", "rtf"] {
        let emitter = EmitterRegistry.standard.getEmitter(name)
        #expect(emitter?.emit(doc, .modern, EmitOptions()).isBinary == false, "\(name)")
    }
}

// MARK: - Number formatting (Job B's writer needs these)

@Test func fixedOneDecimalMatchesPythonPercentF() {
    // Expected strings generated by Python: `'%.1f' % (tenths / 10)`. The list covers the
    // real coordinate domain (72 + n*7.2 and n*4.8 as tenths, page heights, the -1.5 and
    // +3 rule offsets) plus negatives, zero and randoms.
    let cases: [(Int, String)] = [
        (0, "0.0"), (1, "0.1"), (5, "0.5"), (9, "0.9"), (10, "1.0"), (15, "1.5"),
        (-15, "-1.5"), (720, "72.0"), (7920, "792.0"), (6900, "690.0"), (6885, "688.5"),
        (6930, "693.0"), (-1, "-0.1"), (-5, "-0.5"), (-720, "-72.0"), (4321, "432.1"),
        (792, "79.2"), (864, "86.4"), (936, "93.6"), (1008, "100.8"), (1080, "108.0"),
        (768, "76.8"), (816, "81.6"), (18589, "1858.9"), (46741, "4674.1"),
        (22068, "2206.8"), (18446, "1844.6"), (33128, "3312.8"), (53980, "5398.0"),
        (-50218, "-5021.8"), (-51592, "-5159.2"), (34194, "3419.4"), (24719, "2471.9"),
        (65120, "6512.0"), (60946, "6094.6"),
    ]
    for (tenths, want) in cases {
        #expect(fixedOneDecimal(tenths: tenths) == want, "tenths \(tenths)")
    }
}

@Test func zeroPaddedMatchesPythonPercent010d() {
    let cases: [(Int, String)] = [
        (0, "0000000000"), (1, "0000000001"), (9, "0000000009"), (42, "0000000042"),
        (-42, "-000000042"), (999, "0000000999"), (1234567890, "1234567890"),
        (12345678901, "12345678901"), (-1234567890, "-1234567890"),
        (99999, "0000099999"), (-1, "-000000001"),
    ]
    for (value, want) in cases {
        #expect(zeroPadded(value, width: 10) == want, "value \(value)")
    }
    // The width is a parameter even though the xref is the only caller today.
    #expect(zeroPadded(7, width: 3) == "007")
    #expect(zeroPadded(7, width: 0) == "7")
}

@Test func wrapLineMeasuresInUnicodeScalarsLikePython() {
    // Python's `len()` counts code points; Swift's `String.count` counts grapheme clusters.
    // The two only disagree on text CP437 cannot produce — all 256 of its bytes decode to
    // characters with no combining marks, checked against the codec — but `wrapLine` is
    // public, a hand-built Document can carry anything, and Python's answer is the one the
    // vectors were generated with.
    let text = "aa\u{301} bb"        // 6 scalars, 5 graphemes
    // At width 5, scalars put "bb" at column 4 and 4 + 2 > 5, so it wraps — which is what
    // Python does. Graphemes would put it at column 3, and 3 + 2 == 5 would keep one line.
    #expect(wrapLine([Span(text: text)], width: 5).count == 2)
}

// MARK: - Gaps the job-011 mutation run found

@Test func machineMarginIgnoresPageOnesOwnLeadingBlanks() {
    // Survivor from the first mutation run: `pages.dropFirst()` -> `pages`. The chapter-drop
    // vector cannot see the difference, because there page 1 has MORE leading blanks than
    // page 2 and the minimum is the same either way. This is the shape that separates them —
    // page 1 starts higher than the rest, so including it would understate the margin and
    // leave the machine blanks on every later page.
    //
    // Confirmed against the reference: pages of 1, 3 and 4 leading blanks strip to 1, 1 and
    // 2 lines — machine is 3, the minimum over pages 2+, not the 1 that page 1 would set.
    func blk(blanks: Int, text: String) -> Block {
        Block(lines: Array(repeating: Line(), count: blanks) + [Line(spans: [Span(text: text)])])
    }
    let doc = Document(blocks: [
        blk(blanks: 1, text: "first"), Block(kind: .pagebreak),
        blk(blanks: 3, text: "second"), Block(kind: .pagebreak),
        blk(blanks: 4, text: "third"),
    ], detection: Detection(variant: .printstream))
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.map(\.count) == [1, 1, 2])
    #expect(pages[0][0].first?.text == "first")
    #expect(pages[1][0].first?.text == "second")
    #expect(pages[2][0].isEmpty)                    // the one blank beyond the machine margin
    #expect(pages[2][1].first?.text == "third")
}

@Test func aLineOfSpacesCountsAsBlank() {
    // Survivor from the first mutation run: `isBlank` -> `line.isEmpty`. Python asks whether
    // any segment has a non-whitespace character (`any(t.strip() ...)`), so a line holding a
    // single space-only span is blank and gets stripped like an empty one. Every vector
    // document's blanks are empty lines, so none of them can tell the two apart — but a real
    // print capture is full of space-padded lines.
    // A print stream, so the leading space-only line is the machine margin and strips
    // along with the trailing one -- a parsed WS document would keep its leading blank
    // (authorial) and only lose the trailing one. See `finalizePages`.
    let doc = Document(blocks: [Block(lines: [
        Line(spans: [Span(text: "  ")]),
        Line(spans: [Span(text: "text")]),
        Line(spans: [Span(text: "   ")]),
    ])], detection: Detection(variant: .printstream))
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1)
    #expect(pages[0].count == 1)                    // leading AND trailing space-lines gone
    #expect(pages[0][0].first?.text == "text")
}

// MARK: - b26 notes wave: legacy Modern dump per-kind labels

@Test func docToPagelinesModernNotesDumpUsesPerKindLabels() {
    // Port of ctrl-kd 5da154b (b26 notes wave, Fix 2) --
    // `test_doc_to_pagelines_modern_notes_dump_uses_per_kind_labels`. `layoutModernPages`'s
    // own legacy end-of-document notes dump (superseded for real Modern PDF output by
    // `PDFModernLayout.swift`'s `modernStreams`, but still directly unit-testable through
    // `docToPagelines`) used to renumber every kept note through ONE shared sequential
    // index regardless of kind -- a footnote #1 and an endnote #1 both printed
    // "[1]"/"[2]", disagreeing with every real emitter's own label. Fixed to match
    // `footerEntryLines`/`endnoteEntryLines` (the Printed-mode area's own siblings): "1."
    // for the footnote, "(1)" for the endnote -- oracle-verified against -SCREEN.WS.
    var data = ws7Block(0x00)
    data += bytes("a") + ws7Note(bytes("Foot text."), cmd: 0x03, number: 0)
    data += bytes(" b") + ws7Note(bytes("End text."), cmd: 0x04, number: 0)
    data += bytes(" c") + HARD
    let doc = parseWS(data)
    let pages = docToPagelines(doc, printed: false)
    let flat = pages.flatMap { $0.map { $0.map(\.text).joined() } }
    #expect(flat.contains("1. Foot text."))
    #expect(flat.contains("(1) End text."))
    #expect(!flat.contains("[1] Foot text."))
    #expect(!flat.contains("[2] End text."))
}

// ---------------------------------------------------------------- .cp

/// Numbered lines with a `.cp n` inserted before line `cpBefore`. Mirrors Python's
/// `_cp_doc` so both suites measure the same document.
private func cpDoc(cpBefore: Int, n: Int, total: Int = 60) -> [UInt8] {
    var out: [String] = []
    for i in 1...total {
        if i == cpBefore {
            out.append(".cp \(n)")
        }
        out.append("LINE \(String(format: "%03d", i)) " + String(repeating: "-", count: 40))
    }
    return bytes(out.joined(separator: "\r\n") + "\r\n")
}

private func pageTexts(_ page: Page) -> [String] {
    page.map { $0.map(\.text).joined() }
}

@Test func cpDoesNotBreakWhenThereIsRoom() {
    // `.cp` exists so a heading is NOT stranded at a page bottom. Firing it
    // unconditionally inserts the very break it was there to prevent — which is what the
    // old code did, treating `.CP` exactly like `.PA`.
    let pages = docToPagelines(parseWS(cpDoc(cpBefore: 20, n: 10)), printed: true)
    let first = pageTexts(pages[0])
    // 36 of 55 lines remain at line 20: plenty of room, no break there.
    #expect(first.contains { $0.contains("LINE 020") }, "line 20 was pushed off page 1")
    #expect(first.contains { $0.contains("LINE 055") }, "page 1 should still hold 55 lines")
}

@Test func cpBreaksWhenShortOfRoom() {
    let pages = docToPagelines(parseWS(cpDoc(cpBefore: 50, n: 10)), printed: true)
    let first = pageTexts(pages[0])
    // 6 of 55 remain at line 50 — fewer than 10, so it breaks BEFORE line 50.
    #expect(first.contains { $0.contains("LINE 049") })
    #expect(!first.contains { $0.contains("LINE 050") }, ".cp did not break")
}

@Test func cpBoundaryIsStrict() {
    // Measured on WordStar 4 (2026-08-03): with EXACTLY n lines remaining it does not
    // break — the test is `remaining < n`, not `<=`. The manual says only "if there are
    // less than the number of lines specified remaining" and never settles which.
    let pages = docToPagelines(parseWS(cpDoc(cpBefore: 46, n: 10)), printed: true)
    let first = pageTexts(pages[0])
    #expect(first.contains { $0.contains("LINE 046") }, "exactly n remaining must NOT break")
    #expect(first.contains { $0.contains("LINE 055") })
}

@Test func bareCPAsksForOneLine() {
    // `_cp_lines`' default. A bare `.cp` with a full page left must not break.
    let doc = parseWS(bytes(".cp\r\n") + bytes("only line\r\n"))
    #expect(doc.blocks.contains { $0.kind == .condpage && $0.heading == 1 })
    #expect(docToPagelines(doc, printed: true).count == 1)
}

// -------------------------------------------------- running heads and page numbers

@Test func headersAndFootersAreCaptured() {
    // These are fully-documented dot commands that had NO field anywhere in the IR, so
    // their text was captured only in the `dotCommands` diagnostic and silently
    // discarded by every emitter — the reserved SPACE was honoured, the content was
    // not. A running title vanished from every page with no indication it existed.
    let doc = parseWS(bytes(".he My Running Title\r\n.fo Page #\r\nBody text.\r\n"))
    #expect(doc.headers[1] == "My Running Title")
    #expect(doc.footers[1] == "Page #")
}

@Test func numberedHeaderLinesSelectTheirOwnLine() {
    let doc = parseWS(bytes(".h1 First\r\n.h3 Third\r\n.f2 Foot two\r\nBody.\r\n"))
    #expect(doc.headers[1] == "First")
    #expect(doc.headers[3] == "Third")
    #expect(doc.headers[2] == nil)
    #expect(doc.footers[2] == "Foot two")
}

@Test func anEmptyArgumentClearsTheLineRatherThanBeingIgnored() {
    // How WordStar turns a running head off part-way through. An empty value must be
    // STORED as "" — skipping it would leave the earlier title running forever.
    let doc = parseWS(bytes(".he Title\r\nBody.\r\n.he\r\nMore.\r\n"))
    #expect(doc.headers[1] == "")
}

@Test func pnSetsTheStartingPageNumber() {
    // MEASURED on WordStar 4 (2026-08-03): `.pn 7` numbers the pages 7, 8, 9 in both
    // the header's `#` and the footer's.
    let doc = parseWS(bytes(".pn 7\r\nBody.\r\n"))
    #expect(doc.page?.pnStart == 7)
    #expect(doc.page?.pnSource == .file)
    #expect(parseWS(bytes("Body.\r\n")).page?.pnStart == 1)
    #expect(parseWS(bytes("Body.\r\n")).page?.pnSource == .default)
}

@Test func pcIsRecordedButDoesNotMoveAHeaderHash() {
    // `.pc` positions the AUTOMATIC page number. Measured: it does NOT move a `#`
    // placed inside a header or footer, which prints where the author put it. Two
    // separate mechanisms — conflating them is the bug this keeps apart.
    let doc = parseWS(bytes(".pc 40\r\n.fo Page #\r\nBody.\r\n"))
    #expect(doc.page?.pcCol == 40)
    #expect(doc.footers[1] == "Page #")          // untouched by .pc
    #expect(parseWS(bytes("Body.\r\n")).page?.pcCol == nil)
}

@Test func runningHeadsRenderOnlyInPrintedMode() {
    let doc = parseWS(bytes(".he Title\r\n.fo Page #\r\nBody text.\r\n"))
    let printed = runningOps(doc, pageNo: 1, pageHeight: PDFMetrics.pageHeight,
                             lead: Double(PDFMetrics.lead), size: PDFMetrics.size,
                             left: 72.0, printed: true)
    #expect(printed.count == 2)                  // one header op, one footer op
    let modern = runningOps(doc, pageNo: 1, pageHeight: PDFMetrics.pageHeight,
                            lead: Double(PDFMetrics.lead), size: PDFMetrics.size,
                            left: 72.0, printed: false)
    #expect(modern.isEmpty)                      // Modern reflows; no running heads
}

@Test func hashBecomesThePageNumberAndOPSuppressesIt() {
    func footerText(_ src: String, page: Int) -> String {
        let doc = parseWS(bytes(src))
        let ops = runningOps(doc, pageNo: page, pageHeight: PDFMetrics.pageHeight,
                             lead: Double(PDFMetrics.lead), size: PDFMetrics.size,
                             left: 72.0, printed: true)
        return ops.map { String(decoding: $0, as: UTF8.self) }.joined()
    }
    #expect(footerText(".fo Page #\r\nBody.\r\n", page: 3).contains("(Page 3)"))
    // `.op` does NOT suppress a `#` in a header or footer. WSFORMAT.TXT: "no page
    // numbers are printed UNLESS THE '#' HAS BEEN USED IN FOOTERS OR HEADERS" — the
    // running head is the exemption, not the target. This asserted the opposite until
    // 2026-08-03, and passed against a backwards implementation.
    #expect(footerText(".op\r\n.fo Page #\r\nBody.\r\n", page: 3).contains("(Page 3)"))
}

@Test func headerAppliesFromThePageWhereItIsDefinedNotBefore() {
    // WordStar applies a running head from the page where its dot command sits -- on
    // that page itself only if no text has printed there yet, else from the NEXT page.
    // A manuscript that defines its `.h1` after page 1's title block (OLDTIMES's own
    // shape) therefore has NO running head on page 1 -- the final-state `doc.headers`
    // dict cannot express that distinction; only replaying `doc.hfEvents` through
    // pagination can (`Page.headers`, `layoutPrintedPagesPlain`).
    let data = bytes("Title paragraph text on page one.\r\n\r\n")
        + bytes(".h1 Running Head\r\n")
        + bytes(".pa\r\n")
        + bytes("Second page body text.\r\n")
    let doc = parseWS(data)
    #expect(doc.headers[1] == "Running Head")     // final state: still true document-wide
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 2)
    #expect(pages[0].headers.isEmpty, "page 1 predates the .h1 -- no running head yet")
    #expect(pages[1].headers[1] == "Running Head")

    let pdf = emitPDF(doc, mode: .printed)
    // The header text reaches page 2's content stream...
    #expect(contains(pdf, bytes("(Running Head)")))
    // ...but page 1's own stream (before the FIRST `endstream`, i.e. page 1's own
    // content) never shows it.
    func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }
    if let streamEnd = firstIndex(of: bytes("endstream"), in: pdf) {
        #expect(!contains(Array(pdf[..<streamEnd]), bytes("Running Head")))
    } else {
        Issue.record("could not locate page 1's content stream boundary")
    }
}

/// 120 numbered lines under a `.he`/`.fo` pair — Swift twin of Python's `_hf_doc`.
private func hfDoc(_ n: Int = 120) -> [UInt8] {
    var out = bytes(".he HEADER-TEXT PAGE #") + HARD + bytes(".fo FOOTER-TEXT PAGE #") + HARD
    for i in 1...n {
        out += bytes("LINE \(zeroPadded(i, width: 3)) " + String(repeating: "-", count: 40)) + HARD
    }
    return out
}

@Test func headerAndFooterLandWhereWordStarPutsThem() {
    // Header placement MEASURED on WordStar 4 (2026-08-03): header on page line 0,
    // footer on line 60 (.pl - .mb + .fm) -- `runningOps` positions both independently
    // of `printedTop`. Body start was ALSO measured at line 3 (.mt alone) on WS4 at the
    // time, but that reading is now SUPERSEDED by real WS7 evidence (round 26,
    // fidelity_gate.py Finding A): -README (ws7-prints/v1), a genuine WS7 capture with a
    // `.h1` header, prints its body at line 5 (.mt 3 + .hm 2) on every headered page, the
    // same offset headerless WS7 documents already measure -- `printedTop` reserves
    // `.hm` unconditionally now. 55 body lines per page is capacity (`printedCap`),
    // unaffected by where line 0 sits. Asserted in lines, not points, so it stays
    // readable.
    //
    // HEADER line ALSO superseded (b26-header-baseline), by the SAME -README capture:
    // `.hm` at this fixture's DEFAULT value (2, `hfDoc` never states `.hm`) does not
    // participate in the header's own placement -- WS7's real header baseline for an
    // all-default document (-README: .mt 3 default, .hm 2 default) is line 2
    // (mt - topHead, 35.7pt measured, NOT line 0), not line 0. See `runningOps`'s own
    // doc comment for the full four-point derivation (-README plus three SCRIPT.WS
    // pages, `.hm` explicit there and mid-document `.mt` changes on two of them) that
    // settles `.hm`'s default-vs-explicit participation with no exception. FOOTER line
    // is UNCHANGED and still real WS4 evidence -- checked for the same asymmetry and
    // explicitly NOT extended to `.fm` (see `runningOps`): this test is the reason why,
    // and stays the anchor for it. `.fm` here is ALSO at its default value (2), so this
    // is exactly the discriminating case: header ignores a default `.hm`, footer does
    // not ignore a default `.fm`.
    let doc = parseWS(hfDoc())
    let pdf = emitPDF(doc, mode: .printed)
    func lineOf(_ y: Double) -> Int { Int((792.0 - y - 12.0) / 12.0 + 0.5) }
    // Page 1's own content stream only — matches Python's non-greedy `stream...endstream`
    // scope (`re.search`, not `findall`), so a 120-line, multi-page fixture still pins
    // page 1's own header/body/footer placement without a later page's repeats muddying it.
    let spans = contentSpans(pdfContentStreams(pdf)[0])
    let hdr = spans.filter { $0.text.contains("HEADER-TEXT") }.compactMap(\.y).map(lineOf)
    let txt = spans.filter { $0.text.hasPrefix("LINE") }.compactMap(\.y).map(lineOf)
    let ftr = spans.filter { $0.text.contains("FOOTER-TEXT") }.compactMap(\.y).map(lineOf)
    #expect(hdr == [2], "header should sit at mt(3)-topHead(1) = line 2 (.hm 2 is default, ignored), got \(hdr)")
    #expect(txt.first == 5, "body should start at .mt+.hm = 5, got \(String(describing: txt.first))")
    #expect(txt.count == 55, "55 body lines per page, got \(txt.count)")
    #expect(ftr == [60], "footer at .pl-.mb+.fm = 60 (.fm UNCHANGED, still applies at its default), got \(ftr)")
}

@Test func headerBaselineIgnoresADefaultHm() {
    // b26-header-baseline (-README.WS): the -README shape directly -- ALL default page
    // geometry (.mt 3 default, .hm 2 default, matching `doc.page?.hmSource == .default`).
    // WS7's real header baseline there is 35.7pt (top-down), i.e. headBase 2 = mt(3) -
    // topHead(1) -- NOT mt - hm - topHead (0, the pre-fix bug: 12.0pt, 24pt too high).
    // Pinned here at 36.0pt (the same 0.3pt decipoint residual every other measured
    // constant in this project carries).
    var data = bytes(".he TITLE") + HARD
    for i in 1...9 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.hmSource == .default)
    let pdf = emitPDF(doc, mode: .printed)
    let ys = contentSpans(pdf).filter { $0.text == "TITLE" }.compactMap(\.y)
    #expect(ys == [756.0])                    // 792 - 36.0
}

@Test func headerBaselineAppliesADefaultHmOnceMtIsExplicit() {
    // b26-header-round2 (LJ6DTP.WS): b26-header-baseline's rule ("hm participates only
    // when hmSource == .file") broke LJ6DTP, whose header rendered INSIDE the body text
    // (Jon's paper review) -- LJ6DTP is the first oracle with mt EXPLICIT but hm at its
    // OWN default, separating "keyed on hm's source" from "keyed on mt's". Reproduced
    // here: `.mt 1.1"` (explicit) with NO `.hm` at all, plus a `.lh` custom enough
    // (9.33333/48in = 14pt, LJ6DTP's own real value) to expose the SECOND bug this same
    // round found -- headBase must convert to points at the FIXED 6 LPI unit `.mt`/`.hm`
    // are always specified in (`PDFMetrics.lead`, 12pt), never the document's own
    // customized `.lh` leading, which is a wholly separate quantity. Page 2's `.mt1"`
    // mid-document override (b26-mtmb-general's per-page swap: capacity clamps to the
    // document's global capacity, but Page.mtLines/mtSource still carry the page's own
    // LOCAL 6.0/.file, the same value `printedTop` already renders the correct body
    // baseline from) gives headBase 3 = mt(6.0) - hm(2, APPLIED despite hmSource
    // .default, because mtSource is .file) - topHead(1) -> y = 3*12 + 12 = 48.0pt,
    // matching LJ6DTP.pcl exactly. Page 1 (mt 6.6 global, ALSO explicit) gets the same
    // treatment: 55.2pt -- incidentally the same class of number the OLD, doubly-broken
    // pre-b26-header-baseline code produced for LJ6DTP by coincidence, not because this
    // fixture reproduces that bug (its own hm=2 here is genuinely applied, not left over
    // from an unconditional-subtract formula).
    var data = bytes(".mt 1.1\"") + HARD + bytes(".lh 9.33333") + HARD + bytes(".he TITLE") + HARD
    for i in 1...4 { data += bytes("Body line \(i).") + HARD }
    data += bytes(".pa") + HARD + bytes(".mt1\"") + HARD + bytes(".mb1\"") + HARD
    for i in 1...4 { data += bytes("Page2 line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.mtSource == .file && doc.page?.hmSource == .default)
    let pdf = emitPDF(doc, mode: .printed)
    let ys = contentSpans(pdf).filter { $0.text == "TITLE" }.compactMap(\.y)
    #expect(ys == [736.8, 744.0])              // 792 - 55.2, 792 - 48.0
}

// MARK: - Finding 1 (b26 visual pass): WS4 double-spacing blanks stay raw PageLines

@Test func ws4DoubleSpacingSurvivesToPagelines() {
    // `.ls 2` materialises its filler as SOFT blank lines in the file (WS7 Reference:
    // "when you use line spacing, the blank lines become part of the file" -- see
    // ParseWS.swift's own quote of the same manual passage). A real double-spaced WS4
    // essay is stored this way -- text lines interleaved with soft blanks -- and
    // collapsing them destroys the document's vertical rhythm and its page count.
    //
    // Finding 1 (b26 visual pass): each of those blanks stays its OWN literal
    // PageLine, at its own natural lead -- an earlier version of this fix COLLAPSED a
    // spacing pair into one 2x-lead PageLine and that broke on documents with
    // irregular paragraph lengths (a real WS7 capture's own page-top baseline cycles
    // through phases 12pt apart depending on raw-line parity at the page break;
    // collapsing pairs can only reproduce one phase). What changes instead is each
    // spacing blank's `ws4Spacing` flag (see `ws4SpacingBlankIndices`) -- pagination
    // reads it to decide whether the blank alone may force a page break, never
    // whether it exists as a PageLine at all.
    var body: [UInt8] = []
    for n in 0..<6 {
        body += ws4Text("Line number \(n) of the double spaced body text.") + SOFT + SOFT
    }
    let pages = docToPagelines(parseWS(body), printed: true)
    func blankPageLine(_ ln: PageLine) -> Bool {
        !ln.spans.contains { $0.text.contains { !$0.isWhitespace } }
    }
    let pat = pages[0].prefix(6).map { blankPageLine($0) ? "." : "T" }.joined()
    #expect(pat == "T.T.T.", "double spacing collapsed: \(pat)")
    let blanks = pages[0].filter(blankPageLine)
    #expect(!blanks.isEmpty && blanks.allSatisfy { $0.ws4Spacing },
            "spacing blanks not classified: ws4SpacingBlankIndices")
}
