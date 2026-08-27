import AppKit
import CoreText
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 447 (b27 item 7 part 2 — wires job 445's `printedCoverageAwareResolvedMacFont` into the
/// real render path job 442 diagnosed and job 445 built the resolver for but did not wire).
///
/// RUN-BOUNDARY RULE (stated before any code, per the brief): a run is a maximal contiguous
/// substring of a span's own text where every character's `graphicChars` membership agrees —
/// exactly the same grouping `graphicCells` itself already walks character-by-character. Only a
/// GRAPHIC run's font is re-resolved with coverage awareness; a non-graphic run keeps whatever
/// font `attributedRun` already picked for it, untouched. The wiring itself lives in
/// `DocumentRenderer.swift`'s `coverageSplitAttributedString`/`coverageAwareGraphicFont`
/// (new, this job), called from `attributedRun`'s own tail — see that file for the full
/// citation trail. `graphicCells` (`PrintedVectorGraphics.swift`) itself is UNCHANGED: once the
/// text storage carries the right font per run, AppKit's own real layout (which `graphicCells`
/// already trusts via `manager.location(forGlyphAt:)`) is correct by construction, with no new
/// per-glyph position math needed in the historically fragile shared function itself.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job447GraphicCellsCoverageWiringTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    /// Same technique `FontsInViewsTests`/`Job445CoverageAwareFontResolutionTests` already use:
    /// a real `FontChange` from the live ws7 corpus on one of the courier-class rows job 442's
    /// diagnosis names.
    private static func firstCourierClassFontChange() throws -> FontChange {
        let prefixes = ["courier", "pica", "elite", "lineprinter", "prestige"]
        for fixture in try FileManager.default.contentsOfDirectory(atPath: Self.ws7Directory.path)
            where fixture.uppercased().hasSuffix(".WS") {
            let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent(fixture)))
            guard let doc = try? parse(bytes, variant: nil) else { continue }
            if let hit = doc.fonts.first(where: { entry in
                let family = entry.family.lowercased()
                return prefixes.contains { family.hasPrefix($0) }
            }) {
                return hit
            }
        }
        Issue.record("no ws7 fixture carries a courier-class font run")
        throw CocoaError(.fileReadUnknown)
    }

    private static let horizontalArm: Character = "\u{2500}"   // ─
    private static let engineCanonicalAdvanceAt12pt: Double = 0.6 * 12.0

    // MARK: - Section A: run-boundary rule — a mixed span resolves each part separately

    /// A single span carrying prose, then a 50-wide box-drawing run, then more prose — job
    /// 442's own BOXES.WS/LJ6DTP.WS observation that one `Span` can carry both. Asserts the
    /// prose stays on EXACTLY the font it already had (`Courier Prime`, job 306/312's ruled
    /// substitution — unchanged, proving no whole-span rerouting happened) while the graphic
    /// run alone moves to a covering font (`Courier New`, job 442's own measured near-canonical
    /// alternate).
    @Test @MainActor func mixedSpanResolvesProseAndGraphicRunsSeparately() throws {
        let entry = try Self.firstCourierClassFontChange()
        let prefix = "SEE"
        let bar = String(repeating: Self.horizontalArm, count: 50)
        let suffix = "HERE"
        let text = prefix + bar + suffix
        let span = Span(text: text, font: 0)
        let fallback = NSFont.systemFont(ofSize: 12)

        let attributed = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
            defaultSize: 12, useCourierPrime: true)

        // attributedLine appends its own line terminator via `attributedRun`'s callers
        // elsewhere in the file, but the plain-span path used by `attributedLine` itself
        // (`appendSpan` -> `attributedRun`) does not add one, so `attributed`'s own string
        // should still start with the span's own text verbatim.
        let full = attributed.string
        try #require(full.hasPrefix(text), "unexpected line construction: \(full.debugDescription)")

        func familyName(at index: Int) -> String? {
            (attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.familyName
        }

        let proseFamily = try #require(familyName(at: 1))
        let graphicFamily = try #require(familyName(at: prefix.count + 25))
        let proseTailFamily = try #require(familyName(at: prefix.count + bar.count + 1))

        #expect(proseFamily == "Courier Prime",
                "the prose BEFORE the graphic run must keep the font it already had, got \(proseFamily)")
        #expect(proseTailFamily == "Courier Prime",
                "the prose AFTER the graphic run must keep the font it already had, got \(proseTailFamily)")
        #expect(graphicFamily == "Courier New",
                "the graphic run alone must move to a font that covers cp437 box-drawing, got \(graphicFamily)")
    }

    // MARK: - Section B: high column index (40+) and an 87-column row, through the WIRED path,
    // fail-before/pass-after — both Native and Modern share this exact call (see
    // `FontsInViewsTests.courierClassFontRunIsMonospaceInBothViews`'s own citation: both
    // `renderPrinted` (Native) and `renderModern` call this SAME `attributedLine` with
    // `useCourierPrime: true`, so proving it here proves it for both on-screen views at once).

    /// This run's own left-arm fill x0 for glyph `n` (0-based) — `graphicCells` emits exactly
    /// two fills per `horizontalArm` glyph (left-half then right-half, `boxArms["\u{2500}"] ==
    /// (0, 0, 1, 1)`), so fill index `2n` is glyph `n`'s own left edge, real AppKit position.
    @MainActor
    private static func leftArmXs(_ attributed: NSAttributedString) throws -> [Double] {
        let isolated = try #require(isolatedLineLayout(attributed, width: 4000))
        let cells = graphicCells(manager: isolated.manager, storage: isolated.storage,
                                  glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect)
        let fills = cells.flatMap(\.fills)
        var xs: [Double] = []
        var i = 0
        while i < fills.count {
            xs.append(Double(fills[i].frame.minX))
            i += 2
        }
        return xs
    }

    @Test @MainActor func highColumnBoxDrawingMatchesEngineCanonicalPitchThroughTheWiredPath() throws {
        let entry = try Self.firstCourierClassFontChange()
        let columns = 87
        let text = String(repeating: Self.horizontalArm, count: columns)
        let span = Span(text: text, font: 0)
        let fallback = NSFont.systemFont(ofSize: 12)

        // AFTER (the real, wired path — both Native and Modern call this exact function).
        let wired = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
            defaultSize: 12, useCourierPrime: true)
        let wiredXs = try Self.leftArmXs(wired)
        try #require(wiredXs.count == columns, "expected \(columns) box-drawing cells, got \(wiredXs.count)")

        // BEFORE reconstruction (same technique `Job445CoverageAwareFontResolutionTests
        // .resolvedAdvanceMatchesEngineGridButCurrentResolutionDoesNot` already uses): what
        // `attributedRun` built for this exact span BEFORE this job — one uniform font
        // (`printedResolvedMacFont`'s own pre-wiring pick for this courier-class row, "Courier
        // Prime") for the WHOLE run, no coverage check, no run splitting.
        let oldFont = try #require(NSFont(name: "Courier Prime", size: 12))
        let oldAttributed = NSAttributedString(string: text, attributes: [.font: oldFont])
        let oldXs = try Self.leftArmXs(oldAttributed)
        try #require(oldXs.count == columns, "expected \(columns) box-drawing cells in the 'before' reconstruction, got \(oldXs.count)")

        let tolerance = 0.15   // job 442's own measurement: new residual ~0.0012pt/glyph
                                // (0.1pt cumulative by column 87), old (AppKit-substituted)
                                // residual ~0.0246pt/glyph (2.1pt cumulative by column 87) —
                                // this sits strictly between the two.
        for column in [40, 87] {
            let n = column - 1
            let expected = Double(n) * Self.engineCanonicalAdvanceAt12pt
            let wiredMeasured = wiredXs[n] - wiredXs[0]
            let oldMeasured = oldXs[n] - oldXs[0]
            #expect(abs(wiredMeasured - expected) < tolerance, """
                AFTER (wired): column \(column) measured \(wiredMeasured)pt from column 1, \
                engine canonical is \(expected)pt (delta \(abs(wiredMeasured - expected))pt, \
                tolerance \(tolerance)pt)
                """)
            #expect(abs(oldMeasured - expected) >= tolerance, """
                BEFORE (unwired) test assumption changed: column \(column) already matches the \
                engine canonical grid within \(tolerance)pt (measured \(oldMeasured)pt, expected \
                \(expected)pt) — job 442's defect may no longer reproduce on this machine
                """)
        }
    }

    // MARK: - Section C: real end-to-end page render, both Native and Modern, on BOXES.WS —
    // proves the wiring reaches a REAL document through `DocumentRenderer.render(_:style:)`,
    // not just a synthetic span built directly against `attributedLine`.

    @MainActor
    private static func documentState(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job447.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// Every CONTIGUOUS run of `GraphicCell`s on every page of `state`, rendered through the
    /// REAL `render(_:style:)` -> `PagedDocumentView` path (Native when `style == .printed`,
    /// Modern when `style == .modern` — `ViewStyle`'s own doc comment, `DocumentState.swift`).
    /// Each returned array is one run's own left-edge (`eraseFrame.minX`) per graphic
    /// character, in stream order.
    ///
    /// NOT grouped by line-fragment Y alone: `BOXES.WS` (this file's own fixture, page 4's
    /// "Single/Double/Mixed/Mixed" figure) draws SEVERAL separate box columns side by side on
    /// the SAME line, each its own contiguous run separated by literal space characters — a
    /// first version of this helper grouped every cell sharing a line's Y into one "row" and
    /// produced nonsense (a 144-column "row" on a fixture whose widest real box is 79 columns,
    /// because it was silently concatenating 3-4 unrelated box columns end to end). A run
    /// breaks wherever the gap between one cell's `eraseFrame.maxX` and the next's `.minX`
    /// exceeds `runGapTolerance` — comfortably bigger than any float jitter between adjacent
    /// real glyphs, comfortably smaller than one blank column's own pitch.
    @MainActor
    private static func realPageVectorRuns(fixture: String, style: RenderStyle) throws -> [[Double]] {
        let state = try Self.documentState(fixture: fixture)
        state.style.setManually(style.viewStyle)
        let rendered = DocumentRenderer.render(state, style: style)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)

        let runGapTolerance = 2.0
        var runs: [[Double]] = []
        for tv in view.pageViews {
            guard let manager = tv.layoutManager, let container = tv.textContainer,
                  let storage = tv.textStorage else { continue }
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }
            var index = glyphs.location
            let end = glyphs.location + glyphs.length
            while index < end {
                var effective = NSRange(location: 0, length: 0)
                let fragment = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
                let cells = graphicCells(manager: manager, storage: storage, glyphRange: effective, fragment: fragment)
                var currentRun: [Double] = []
                var lastMaxX: Double?
                for cell in cells {
                    let minX = Double(cell.eraseFrame.minX)
                    let maxX = Double(cell.eraseFrame.maxX)
                    if let lastMaxX, minX - lastMaxX > runGapTolerance {
                        if currentRun.count >= 2 { runs.append(currentRun) }
                        currentRun = []
                    }
                    currentRun.append(minX)
                    lastMaxX = maxX
                }
                if currentRun.count >= 2 { runs.append(currentRun) }
                guard effective.length > 0 else { break }
                index = effective.location + effective.length
            }
        }
        return runs
    }

    /// Real-document, real-render-path proof for one `RenderStyle`: on `BOXES.WS`, at least
    /// one CONTIGUOUS run of box-drawing cells spans 40+ columns, and its rightmost cell sits
    /// within `tolerance` of the engine's canonical `(n - 1) * 0.6 * size` grid measured from
    /// its own leftmost cell — i.e. the drift job 442 measured (growing to +0.55pt/+1.5pt+ the
    /// wider the run) is closed in the REAL render path, not just the synthetic span this
    /// file's Section B already proved.
    @MainActor
    private static func assertHighColumnRowsMatchCanonicalGrid(style: RenderStyle) throws {
        let state = try Self.documentState(fixture: "BOXES.WS")
        let size = Double(printedMetrics(state.document).size)
        try #require(size > 0, "vacuity guard: BOXES.WS reported a zero/invalid base size")
        let pitch = 0.6 * size
        let tolerance = 0.2

        let runs = try Self.realPageVectorRuns(fixture: "BOXES.WS", style: style)
        let wideRuns = runs.filter { $0.count >= 40 }
        #expect(!wideRuns.isEmpty, """
            \(style): vacuity guard: BOXES.WS produced no real rendered run spanning 40+ \
            box-drawing columns to check — the fixture no longer exercises this class in \
            this view
            """)
        for leftEdges in wideRuns {
            let columns = leftEdges.count
            let expected = Double(columns - 1) * pitch
            let measured = leftEdges.max()! - leftEdges.min()!
            #expect(abs(measured - expected) < tolerance, """
                \(style): a \(columns)-column real BOXES.WS run measured \(measured)pt \
                end-to-end, engine canonical is \(expected)pt (delta \
                \(abs(measured - expected))pt, tolerance \(tolerance)pt)
                """)
        }
    }

    @Test @MainActor func realBoxesWSNativeHighColumnRowsMatchCanonicalGrid() throws {
        try Self.assertHighColumnRowsMatchCanonicalGrid(style: .printed)
    }

    @Test @MainActor func realBoxesWSModernHighColumnRowsMatchCanonicalGrid() throws {
        try Self.assertHighColumnRowsMatchCanonicalGrid(style: .modern)
    }
}
