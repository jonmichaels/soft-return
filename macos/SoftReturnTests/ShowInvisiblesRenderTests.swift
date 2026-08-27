import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 256 (Show Invisibles, part 2/4): `DocumentRenderer.renderWithInvisibles`/
/// `renderPrintedAnnotated` — the screen-only inline rendering of `CtrlKD.annotatedLayout`'s
/// five invisible-ink classes. `RenderProbeTests.oldtimesInvisiblesOnOffPage1` is this job's
/// visual evidence; this file is the byte/structural proof underneath it.
@MainActor
private func oldtimesState() throws -> DocumentState {
    let url = OracleByteParityTests.ws7Directory.appendingPathComponent("OLDTIMES.WS")
    return try Oracle.state(for: url)
}

/// Every `NSAccessibilityAnnotationLabel` (job 256's "spoken prefixes") attached anywhere in
/// `text`, alongside whether that run also carries `invisibleMarkColour` — a mark run must
/// carry both, never one without the other.
@MainActor
private func markAnnotations(in text: NSAttributedString) -> [(label: String, faint: Bool)] {
    var found: [(label: String, faint: Bool)] = []
    let full = NSRange(location: 0, length: text.length)
    text.enumerateAttributes(in: full) { attributes, _, _ in
        guard let entries = attributes[.accessibilityAnnotationTextAttribute]
            as? [[NSAccessibility.AnnotationAttributeKey: Any]] else { return }
        let faint = (attributes[.foregroundColor] as? NSColor) == invisibleMarkColour
        for entry in entries {
            guard let label = entry[.label] as? String else { continue }
            found.append((label, faint))
        }
    }
    return found
}

/// `render(_:style:)` must never depend on `showInvisibles` — the property every non-screen
/// caller (`ExportEngine`, `makePrintOperation`, `QuickLookNativeRenderer`,
/// `PagePreviewRenderer`) relies on, several of them against the SAME live `DocumentState`
/// the document window shares. This is the OFF-state structural-digest pin job 256's brief
/// asked for: toggling `showInvisibles` back and forth must leave `render(state)`'s own output
/// byte-identical, every time. Job 257 (part 3/4) extends it CORPUS-WIDE — the pagination
/// rewrite this job makes to `renderPrintedAnnotated` is exactly the kind of change that
/// could leak into the plain path through some shared helper by accident, and only OLDTIMES.WS
/// exercising it would miss a fixture-specific regression (an LJ6DTP-only leak, say).
@Test(arguments: OracleByteParityTests.ws7Fixtures) @MainActor
func showInvisiblesNeverAffectsThePlainRenderFunction(fixtureName: String) throws {
    let url = OracleByteParityTests.ws7Directory.appendingPathComponent(fixtureName)
    let state = try Oracle.state(for: url)
    state.style.setManually(.native)

    let baseline = DocumentRenderer.render(state)

    state.showInvisibles = true
    _ = DocumentRenderer.renderWithInvisibles(state)   // exercise the annotated path for real
    let whileOn = DocumentRenderer.render(state)
    #expect(whileOn.text.string == baseline.text.string,
            "\(fixtureName): render(_:style:) text changed while showInvisibles was true")
    #expect(whileOn.softLineFlags == baseline.softLineFlags,
            "\(fixtureName): render(_:style:) structural digest (softLineFlags) changed while showInvisibles was true")
    #expect(whileOn.pageCount == baseline.pageCount,
            "\(fixtureName): render(_:style:) pageCount changed while showInvisibles was true")

    state.showInvisibles = false
    let afterOff = DocumentRenderer.render(state)
    #expect(afterOff.text.string == baseline.text.string,
            "\(fixtureName): render(_:style:) text differs after toggling showInvisibles back off")
    #expect(afterOff.softLineFlags == baseline.softLineFlags,
            "\(fixtureName): render(_:style:) structural digest (softLineFlags) differs after toggling showInvisibles back off")
    #expect(afterOff.pageCount == baseline.pageCount,
            "\(fixtureName): render(_:style:) pageCount differs after toggling showInvisibles back off")
}

/// `renderWithInvisibles` itself is screen-only by NAME, but the real guarantee is that
/// nothing outside `DocumentWindowController.reloadContent()` ever calls it — this proves the
/// one thing that guarantee actually rests on: `render(_:style:)`'s output for OLDTIMES.WS is
/// the SAME `RenderedDocument` shape `renderWithInvisibles` would have replaced. (The export
/// and print byte-level proof already lives in `WiringTests
/// .showInvisiblesNeverReachesPrintedExportBytes`; this is the render-function-level
/// complement job 256's brief also asks for.)
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func showInvisiblesAnnotatedLayoutDiffersFromThePlainOne() throws {
    let state = try oldtimesState()
    state.style.setManually(.native)

    let plain = DocumentRenderer.render(state)
    state.showInvisibles = true
    let annotated = DocumentRenderer.renderWithInvisibles(state)

    #expect(annotated.text.string != plain.text.string,
            "renderWithInvisibles produced the same text as the plain render — nothing was annotated")
    #expect(!markAnnotations(in: annotated.text).isEmpty,
            "renderWithInvisibles produced no AX-annotated mark runs at all")
}

/// OLDTIMES.WS's own dot commands, surfaced inline and faint — the brief's own count (5
/// dot-command lines), verified against the real fixture, not assumed; a future OLDTIMES.WS
/// re-sync that changes this is exactly what this test exists to catch.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func oldtimesInvisiblesOnSurfacesDotCommandsFaint() throws {
    let state = try oldtimesState()
    state.style.setManually(.native)
    state.showInvisibles = true

    let rendered = DocumentRenderer.renderWithInvisibles(state)
    let marks = markAnnotations(in: rendered.text)
    let dotCommands = marks.filter { $0.label.hasPrefix("dot command:") }

    #expect(dotCommands.count == 5,
            "expected 5 dot-command mark runs in OLDTIMES.WS, found \(dotCommands.count): \(dotCommands.map(\.label))")
    #expect(dotCommands.allSatisfy { $0.faint }, "a dot-command mark run was not drawn in invisibleMarkColour")
}

/// OLDTIMES.WS's own 2 comments — present in the annotated stream (matching `doc.notes`
/// exactly), but rendered as EMPTY marks: this real archive file's 2 comment notes carry no
/// text of their own (`doc.notes[i].text == ""`, confirmed directly — not an
/// `annotatedLayout`/rendering defect, a genuine property of this parsed file). An empty
/// `NSAttributedString` run occupies zero characters, so it cannot be found by walking
/// `rendered.text`'s attribute runs the way `oldtimesInvisiblesOnSurfacesDotCommandsFaint`
/// finds dot commands — this test instead confirms the mark COUNT at the annotated-layout
/// level, the same layer `renderPrintedAnnotated` consumes. Flagged for the report/LESSONS:
/// a future job may want a placeholder glyph for a genuinely empty comment so its presence
/// is not entirely invisible to a reader.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func oldtimesCommentNotesAreTaggedEvenThoughTheyCarryNoText() throws {
    let state = try oldtimesState()

    let comments = state.document.notes.filter { $0.kind == .comment }
    #expect(comments.count == 2, "expected 2 comment notes in OLDTIMES.WS, found \(comments.count)")
    #expect(comments.allSatisfy { $0.text.isEmpty },
            "OLDTIMES.WS's comment notes now carry text — the empty-mark case this test documents no longer applies; the rendering-level test above may need a fixture change")

    let annotated = annotatedLayout(state.document)
    let commentSpans = annotated.lines.flatMap(\.spans).filter { $0.kind == .comment }
    #expect(commentSpans.count == 2,
            "expected 2 .comment AnnotatedSpans for OLDTIMES.WS, found \(commentSpans.count)")
}

/// Print/export/QuickLook never see an invisible mark — `render(_:style:)` (what every one
/// of them calls) contains ZERO AX-annotated mark runs, on or off, because it never consults
/// `showInvisibles` at all (see `showInvisiblesNeverAffectsThePlainRenderFunction` above).
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func plainRenderCarriesNoInvisibleMarksEvenWithTheFlagOn() throws {
    let state = try oldtimesState()
    state.style.setManually(.native)
    state.showInvisibles = true

    let plain = DocumentRenderer.render(state)
    #expect(markAnnotations(in: plain.text).isEmpty,
            "render(_:style:) — the function print/export/QuickLook all call — carried invisible marks")
}

/// Job 257 (Show Invisibles part 3/4, the reflow ruling), UPDATED by job 267 (field bug 2):
/// an INDEPENDENT re-derivation of the SAME points budget `layoutPrintedPagesPlain`/
/// `renderPrintedAnnotated` walk — first unit on a page free, a unit right after a real
/// overprint line free, everything else its own lead (a real line's `.lh`-aware lead, or the
/// document default for a fabricated dot-command line) — built directly from
/// `printedMetrics`/`docToPagelines`/`annotatedLayout`, the same three engine entry points
/// the render function itself calls, rather than a literal page-count constant. A future
/// OLDTIMES.WS re-sync that changes its dot-command count or page breaks recomputes the right
/// answer here instead of going stale.
///
/// Job 267: a `.cp2`/`.cp4` `pageBreakBefore` reason is now CONDITIONAL — re-evaluated against
/// this walk's own remaining budget, not trusted as an unconditional force — see
/// `renderPrintedAnnotated`'s own `shouldForceBreak` doc comment for the full ruling this
/// mirrors. Does NOT replicate that function's mark-WRAPPING row-cost math (`unitRows`):
/// OLDTIMES.WS's own dot-commands/comments are all short (its 2 `NoteKind.comment` notes are
/// empty strings — `oldtimesCommentNotesAreTaggedEvenThoughTheyCarryNoText`'s own finding) and
/// never wrap in practice, so every unit here costs exactly 1 row, same as job 257's original
/// formula — this fixture cannot exercise that math, unlike POWERUSE.WS/FORMFEED.WS
/// (`RenderProbeTests`' own screenshot evidence for those).
@MainActor
private func expectedAnnotatedPageCount(for doc: Document) -> Int {
    let metrics = printedMetrics(doc)
    let pages = docToPagelines(doc, printed: true)
    let flatLines = pages.flatMap { $0 }
    let annotated = annotatedLayout(doc)

    var units: [(pageBreakBefore: InkKind?, flatIndex: Int?)] = []
    var realIndex = 0
    for line in annotated.lines {
        if line.endMark != nil {
            units.append((line.pageBreakBefore, realIndex))
            realIndex += 1
        } else {
            units.append((line.pageBreakBefore, nil))
        }
    }

    let budget = Double(metrics.capacity - 1) * metrics.lead
    func conditionalThreshold(_ text: String) -> Int? {
        let upper = text.uppercased()
        guard upper.hasPrefix(".CP") else { return nil }
        return Int(upper.dropFirst(3))
    }
    func shouldForceBreak(_ reason: InkKind?, spent: Double) -> Bool {
        guard case .pageBreakOrigin(let text)? = reason, !text.isEmpty else { return false }
        guard let n = conditionalThreshold(text) else { return true }
        return budget - spent < Double(n) * metrics.lead - 1e-6
    }
    var pageCount = 1
    var spent = 0.0
    var pageEmpty = true
    var previousWasOverprint = false
    for (index, unit) in units.enumerated() {
        if index > 0, shouldForceBreak(unit.pageBreakBefore, spent: spent) {
            pageCount += 1
            spent = 0
            pageEmpty = true
            previousWasOverprint = false
        }
        let rawCost: Double = pageEmpty ? 0
            : previousWasOverprint ? 0
            : (unit.flatIndex.map { flatLines[$0].lead ?? metrics.lead } ?? metrics.lead)
        if !pageEmpty, spent + rawCost > budget + 1e-6 {
            pageCount += 1
            spent = 0
            pageEmpty = true
            previousWasOverprint = false
        }
        let cost = pageEmpty ? 0 : rawCost
        spent += cost
        pageEmpty = false
        previousWasOverprint = unit.flatIndex.map { flatLines[$0].overprint } ?? false
    }
    return pageCount
}

/// OLDTIMES.WS's 5 dot-command lines (`oldtimesInvisiblesOnSurfacesDotCommandsFaint`'s own
/// count) consume real leads once Invisibles is on — this is the spec's own reflow ruling,
/// checked against the engine's own arithmetic rather than a magic number, and the ON >= OFF
/// property the ruling guarantees (reflow only ever ADDS pages, never removes one).
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func oldtimesReflowPageCountMatchesEngineArithmetic() throws {
    let state = try oldtimesState()
    state.style.setManually(.native)

    let offCount = DocumentRenderer.render(state).pageCount
    state.showInvisibles = true
    let onCount = DocumentRenderer.renderWithInvisibles(state).pageCount
    let expected = expectedAnnotatedPageCount(for: state.document)

    #expect(onCount == expected,
            "OLDTIMES.WS Invisibles-on page count (\(onCount)) didn't match the engine's own budget arithmetic (\(expected))")
    #expect(onCount >= offCount,
            "OLDTIMES.WS Invisibles-on page count (\(onCount)) was fewer than Invisibles-off (\(offCount)) — reflow must never shrink the page count")
}

/// Job 257 (part 3/4): LJ6DTP.WS's own `.overprint` chains and oversized banner (jobs
/// 224/227/246's subjects) must still composite once Invisibles interleaves dot-command
/// lines around them — the structural proof under
/// `RenderProbeTests.lj6dtpInvisiblesOnP1P6NoCompositingRegression`'s screenshots. Both
/// counts must stay non-zero: a silent regression to job 256's "no `.overprint`/oversized
/// handling in the annotated path at all" would zero these out without changing `pageCount`
/// or crashing anything, which is exactly why this needs its own check.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func lj6dtpInvisiblesOnReusesOverprintAndOversizedCompositing() throws {
    let url = OracleByteParityTests.ws7Directory.appendingPathComponent("LJ6DTP.WS")
    let state = try Oracle.state(for: url)
    state.style.setManually(.native)

    let plain = DocumentRenderer.render(state)
    let plainPassCount = plain.overprintPasses.flatMap { $0 }.reduce(0) { $0 + $1.count }
    let plainOversizedCount = plain.oversizedSelfPasses.flatMap { $0 }.filter { $0 != nil }.count
    #expect(plainPassCount > 0, "LJ6DTP.WS's plain render carries no overprint passes at all — fixture assumption broke")
    #expect(plainOversizedCount > 0, "LJ6DTP.WS's plain render carries no oversized self-passes at all — fixture assumption broke")

    state.showInvisibles = true
    let annotated = DocumentRenderer.renderWithInvisibles(state)
    let annotatedPassCount = annotated.overprintPasses.flatMap { $0 }.reduce(0) { $0 + $1.count }
    let annotatedOversizedCount = annotated.oversizedSelfPasses.flatMap { $0 }.filter { $0 != nil }.count

    #expect(annotatedPassCount > 0,
            "LJ6DTP.WS's annotated render carries no overprint passes — job 257's ported compositing isn't reaching the annotated path")
    #expect(annotatedOversizedCount > 0,
            "LJ6DTP.WS's annotated render carries no oversized self-passes — job 257's ported compositing isn't reaching the annotated path")
}

/// Job 257 (part 3/4, best effort): toggling Show Invisibles must not strand the reader —
/// `DocumentWindowController.toggleInvisibles` captures the REAL page
/// (`PagedDocumentView.realPageIndex(at:)`) before re-rendering and asks for whichever
/// local page shows that real page's content again afterward
/// (`pageIndex(forRealPage:)`). OLDTIMES.WS's own reflow (this job's other tests prove ON
/// needs more local pages than OFF) makes this a real round-trip, not a no-op.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func toggleInvisiblesKeepsTheReaderOnTheSameRealPage() throws {
    let state = try oldtimesState()
    state.style.setManually(.native)

    let controller = DocumentWindowController(state: state)
    controller.showWindow(nil)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.goToPage(index: controller.pageTotal - 1)
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let offRealPage = controller.pagedView.realPageIndex(at: controller.currentPage)

    controller.toggleInvisibles(nil)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let onRealPage = controller.pagedView.realPageIndex(at: controller.currentPage)
    #expect(onRealPage == offRealPage,
            "toggling Show Invisibles on moved the reader from real page \(offRealPage) to \(onRealPage)")

    controller.toggleInvisibles(nil)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let afterOffRealPage = controller.pagedView.realPageIndex(at: controller.currentPage)
    #expect(afterOffRealPage == offRealPage,
            "toggling Show Invisibles back off moved the reader from real page \(offRealPage) to \(afterOffRealPage)")
}
