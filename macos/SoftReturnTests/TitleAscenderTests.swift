import AppKit
import CoreText
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 371 item 4 (TITLE ASCENDERS, RULINGS-LEDGER item 14): "the engine PDF renders
/// full-height; the view's line cell clips ascenders." `DocumentRenderer`'s own oversized-
/// glyph handling (job 227's `lineExceedsFragment`/`oversizedSelfPasses`, job 242's fix to
/// measure REAL glyph ink bounds rather than font metrics, `PagedDocumentView
/// .drawOversizedSelfPasses`'s paper-level compositing) already exists and was verified
/// across several jobs — but only through geometry/glyph-bbox CALCULATIONS
/// (`ZZProbeJob240ClipHeight.swift.unused`'s own archived probe), never a real rendered-pixel
/// check. This file is that check: real 72pt+ banner titles, captured via
/// `NSView.cacheDisplay(in:to:)` (the same same-process, Screen-Recording-free technique job
/// 359's `BottomBarHeaderTests` established) and scanned with `RenderProbeKit.inkMargins` — the
/// pixel truth of where ink actually starts, not a query that stops at the model layer.
///
/// Job 396 (391 root cause 5): job 371 shipped only the oversized-glyph MODEL machinery
/// (`oversizedSelfPasses`/the paper-level overlay) — no production fix ever made the full
/// ascent actually visible on screen, because `PagedDocumentView`'s own hard clip
/// (`clipsToBounds`) still cut it off the moment a title's real ascent needed more headroom
/// than the document's own top margin gives, with page 1 worst off (no earlier page's own
/// blank canvas to borrow into). Jon's field screenshots on DARKNESS.WS/WARPRAYR.WS (large-
/// font first lines) caught it twice; this job's own production fix
/// (`RenderedDocument.leadingHeadroom`, `PagedDocumentView.headroom(atPage:)`) reserves real
/// screen-only canvas headroom instead. This file's own assertion law changes with it: the
/// OLD check only asked "did ink rise above the fully-clipped position" (a real render that
/// still clips PART of the ascender passes that one-sided test) — the law below is FULL
/// non-clipping: real measured ink must land within a small tolerance of where the glyph's
/// own true ink bounds say it should, independently recomputed, not merely "somewhere higher
/// than before".
///
/// Job 400 (F11, sample bundle refresh): `DARKNESS.WS` left the shipping sample bundle
/// (`SoftReturn/Resources/SampleDocuments/`), so its two dedicated tests below are gone too
/// — `TestDocs/ws7/DARKNESS.WS` itself stayed on as a fixture for other `ws7Fixtures`-driven
/// suites (e.g. `PrintedStructuralParityTests`) even though this file stopped naming it
/// specifically. Job 498 (Jon's ruling, content bar) removed the fixture itself too, so that
/// is now moot. The tall-title class this file exists to catch stays live via
/// `warprayrTitleFullyVisible`/`warprayrTitleTopAgreesWithEngine`.
/// Job 535: every test in this suite reads `TestDocs/ws7` (directly or via
/// `OracleByteParityTests.ws7Directory`/`PixelOracleAppEngine`) — gated at the suite level so
/// a bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly instead of throwing on the first `Data(contentsOf:)`.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct TitleAscenderTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    enum ProbeError: Error { case noBitmap, noInk }

    @MainActor
    private static func topInkMarginPt(fixture: String) throws -> (topInk: Double, metrics: PrintedPageMetrics) {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "TitleAscenderTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.native)

        let controller = DocumentWindowController(state: state)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        controller.pagedView.showPage(0)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        guard let bitmap = controller.pagedView.bitmapImageRepForCachingDisplay(in: controller.pagedView.bounds)
        else { throw ProbeError.noBitmap }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            controller.pagedView.cacheDisplay(in: controller.pagedView.bounds, to: bitmap)
        }
        guard let margins = RenderProbeKit.inkMargins(
            in: bitmap, background: .white, viewSize: controller.pagedView.bounds.size)
        else { throw ProbeError.noInk }

        return (margins.top, printedMetrics(state.document))
    }

    /// Job 396: the FULL non-clipping law, independently derived — not `PagedDocumentView`'s
    /// own reserved-headroom FIELD (which would just check the code agrees with itself), but
    /// a fresh CoreText measurement of the SAME real, fully-resolved first-line content
    /// `DocumentRenderer` produces, re-deriving from it where the real glyph's own ink top
    /// SHOULD land given `firstBaseline` (`emitPDF`'s own `top + size`, this file's
    /// `PrintedPageMetrics.top`/`.size` citation) — then leaving the tolerance in
    /// `assertFullNonClippingLaw` to catch anything the VIEW's own layout/clip/overlay wiring
    /// gets wrong, since that (not this arithmetic) is what job 396 actually changed.
    ///
    /// A page's own first line takes one of two shapes: an OVERSIZED title
    /// (`RenderedDocument.oversizedSelfPasses[0].first`, non-nil — its real content lives
    /// there, since `renderPrinted` leaves the inline fragment BLANK for these, see that
    /// field's own doc comment), or ordinary text, where the FIRST physical line is often
    /// blank filler (a title vertically centred a few lines down the page — OLDTIMES.WS's
    /// own shape) rather than the real ink. For the ordinary case this walks
    /// `RenderedDocument.text`'s own physical lines (paragraphs), accumulating each one's
    /// own baseline the SAME way `pageStream`/AppKit do — the first line "takes its
    /// position from top and no lead at all" (`PDFWriter.swift`'s own citation), every line
    /// after it advances by ITS OWN paragraph style's `minimumLineHeight` (each line's real,
    /// possibly `.lh`-overridden lead — `lineAndTerminator`'s own `paragraphStyle(lead:)`) —
    /// until the first line with real ink is found. Either shape measures the REAL,
    /// resolved-font content the app itself is about to draw, at its own natural (unbounded)
    /// height — never a font-metrics guess.
    @MainActor
    private static func expectedTopInkPt(fixture: String) throws -> Double {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "TitleAscenderTests.expected.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .printed)
        let metrics = printedMetrics(state.document)
        // Job 425 (b26 round 26 wave 3, ctrl-kd's `pageStream`, PDFWriter.swift): the page's
        // first line takes its baseline from `top` and ITS OWN lead, not a flat `metrics.
        // size` — the SAME fix `DocumentRenderer.renderPrinted`'s own `perPageFirstBaselines`
        // now applies in production (see that citation). Re-derived here from
        // `docToPagelines` directly (the same call `renderPrinted` itself makes) rather than
        // reused from `rendered`, since `RenderedDocument` does not expose the raw
        // per-page `PageLine.lead` this needs.
        let pages = docToPagelines(state.document, printed: true)
        let firstBaseline = metrics.top + (pages.first?.first?.lead ?? metrics.lead)

        // Job 490 (item 1): a page-1 `.pctl` span whose control survived parsing with a real
        // PCL payload (`Span.pcl`, register C2) can draw REAL ink above wherever the text
        // itself starts — LJ6DTP.WS's own page border, drawn entirely this way
        // (`PrintedPCLGraphics.swift`'s top doc comment). This law's own "expected" value was
        // blind to that before this job (font-metrics only), so a fixture whose border now
        // legitimately draws the page's topmost ink needs it folded in here too, or a
        // CORRECT render (border ink genuinely higher than the title) reads as a false
        // clipping regression against a stale, text-only expectation. Anchor (0, 0): every
        // `.pcl` program this corpus's page 1 carries addresses the page ABSOLUTELY (LJ6DTP's
        // border — `PrintedPCLGraphics.swift`'s own citation against the raw fixture bytes),
        // so the anchor a relative op would need never arises here; a fixture whose page 1
        // carried a RELATIVE-only program would need its own real anchor, not exercised by
        // this corpus today.
        var pclTopInkPt = Double.infinity
        for line in pages.first?.lines ?? [] {
            for span in line.spans {
                guard let idx = span.pcl, state.document.pclPrograms.indices.contains(idx) else { continue }
                let prog = parsePCLProgram(state.document.pclPrograms[idx])
                // Job 490: matches production's own `PagedDocumentView.drawPCLGraphics`
                // gate — see `pclProgramIsAbsoluteOnly`'s own doc comment.
                guard pclProgramIsAbsoluteOnly(prog) else { continue }
                for fill in pclGraphicRects(prog, anchorX: 0, anchorY: 0) {
                    pclTopInkPt = min(pclTopInkPt, Double(fill.frame.origin.y))
                }
            }
        }

        func inkTop(of content: NSAttributedString) -> Double? {
            guard content.length > 0 else { return nil }
            let ctLine = CTLineCreateWithAttributedString(content)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
            guard bounds.width > 0 || bounds.height > 0 else { return nil }
            return Double(bounds.origin.y + bounds.height)
        }

        // One fragment (`softLineFlags[0]`/`oversizedSelfPasses[0]`'s own indexing) per
        // physical line of `rendered.text` — an oversized fragment's own inline line is
        // BLANK there (`renderPrinted`'s own call site: `oversized ? PageLine([], ...) :
        // base`), so walking `rendered.text`'s physical lines in lockstep with
        // `oversizedSelfPasses[0]` visits every fragment exactly once, oversized or not.
        // OLDTIMES.WS's own title is fragment 4, not 0 (a byline/copyright block/award
        // list sit above it) — an oversized title is not always the page's literal first
        // physical line, so every fragment has to be checked, not merely the first.
        let selfPasses = rendered.oversizedSelfPasses.first ?? []
        let full = rendered.text.string as NSString
        var location = 0
        var index = 0
        var baseline = firstBaseline
        while location < full.length {
            if selfPasses.indices.contains(index), let pass = selfPasses[index],
               let ink = inkTop(of: pass) {
                return min(pclTopInkPt, baseline - ink)
            }
            let lineRange = full.lineRange(for: NSRange(location: location, length: 0))
            let content = rendered.text.attributedSubstring(from: lineRange)
            if let ink = inkTop(of: content) {
                return min(pclTopInkPt, baseline - ink)
            }
            // Job 425: `advanceLead(page, at: i)` (`DocumentRenderer.renderPrinted`) — the
            // arithmetic this loop re-derives — advances the baseline INTO row i by row i's
            // OWN lead, never the row BEFORE it (`PrintedPageMetrics.lead`'s own citation:
            // "A LEAD IS THE SPACE ABOVE ITS LINE, not below it"). This loop used to read the
            // CURRENT (about-to-be-left) line's own paragraph style and spend it advancing to
            // the NEXT line — off by one row, the exact class of bug job 245's own doc
            // comment on `advanceLead` already names and fixed once in the real renderer.
            // Invisible on OLDTIMES.WS before the b26 pin (every blank line shared one
            // uniform lead, so which row's lead got charged made no numeric difference); the
            // pin's fidelity-round fix gave the blank lines ABOVE OLDTIMES.WS's own title a
            // real, non-uniform per-line `.lh` lead (12/14.4/14.4/14.4/21.6), which finally
            // made the indexing error visible: 9.28pt of drift, confirmed closed to 0.32pt by
            // peeking the NEXT line's own style instead.
            let nextLocation = lineRange.location + lineRange.length
            var lead = metrics.lead
            if nextLocation < full.length {
                let nextLineRange = full.lineRange(for: NSRange(location: nextLocation, length: 0))
                if let style = rendered.text.attribute(
                    .paragraphStyle, at: nextLineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                   style.minimumLineHeight > 0 {
                    lead = Double(style.minimumLineHeight)
                }
            }
            baseline += lead
            location = nextLocation
            index += 1
        }
        if pclTopInkPt.isFinite { return pclTopInkPt }
        throw ProbeError.noInk
    }

    /// The full law itself: real measured ink (`topInkMarginPt`, live `cacheDisplay` pixels)
    /// must land within `tolerance` of the independently-derived `expectedTopInkPt` — NOT the
    /// old one-sided "higher than the clipped position" check, which a still-partially-
    /// clipped render can pass. `tolerance` covers `DocumentRenderer.leadingHeadroom`'s own
    /// `+ 2` float-safety margin plus ordinary antialiasing fringe (`inkMargins`'s own
    /// tolerance); a regression back to a hard clip lands the real measurement tens of points
    /// away from `expectedTopInkPt` on every oversized fixture below, far outside it.
    @MainActor
    private static func assertFullNonClippingLaw(fixture: String, tolerance: Double = 4) throws {
        let (topInk, _) = try Self.topInkMarginPt(fixture: fixture)
        let expected = try Self.expectedTopInkPt(fixture: fixture)
        #expect(abs(topInk - expected) < tolerance, """
            \(fixture)'s first line ink should land within \(tolerance)pt of its own real \
            glyph bounds (expected \(expected)pt from the paper's top edge) — measured \
            \(topInk)pt. A hard clip re-clips this line if the gap is much larger than the \
            tolerance.
            """)
    }

    @Test @MainActor func lj6dtpTitleFullyVisible() throws {
        try Self.assertFullNonClippingLaw(fixture: "LJ6DTP.WS")
    }

    @Test @MainActor func oldtimesTitleFullyVisible() throws {
        try Self.assertFullNonClippingLaw(fixture: "OLDTIMES.WS")
    }

    /// Job 396 (391 root cause 5), the second reported fixture — field screenshots showed
    /// WARPRAYR.WS's own large-font first line clipped in Native (DARKNESS.WS's matching
    /// test, the first reported fixture, was removed in job 400 when DARKNESS.WS left the
    /// shipping sample bundle — see this file's own top doc comment).
    @Test @MainActor func warprayrTitleFullyVisible() throws {
        try Self.assertFullNonClippingLaw(fixture: "WARPRAYR.WS")
    }

    // MARK: - Oversized-pass routing (job 422)

    /// Job 422: root cause of the title clipping THREE prior rounds (371/396/412-413) each
    /// believed fixed. `lineExceedsFragment` (`DocumentRenderer.swift`) decided whether a
    /// line needed the oversized-self-pass/headroom machinery using ONLY a tight
    /// `.useGlyphPathBounds` ink measurement — for WARPRAYR.WS's old machine-authored title
    /// (20pt CourierPrime-Bold, tight ink 11.6pt) that sat just UNDER the 12pt line lead, so
    /// the line fell through to ORDINARY `NSLayoutManager` layout — whose real typesetting
    /// reserves room from the font's own ASCENDER (15.6pt, `ZZProbeJob422Layout`'s own
    /// probe measured the title's real `boundingRect` extending 12.84pt above its own
    /// fragment top), not the tight ink figure. `TitleAscenderTests` itself never caught
    /// this: `assertFullNonClippingLaw`/`assertTitleTopAgreesWithEngine` both only check
    /// where the line's TOPMOST pixel lands, which stayed misleadingly close to correct
    /// (the tallest glyph on the line dominates that scalar) even while OTHER glyphs on the
    /// same line (whatever this specific string's own font-substitution/hinting pass
    /// distorts) rendered visibly malformed a few points below the top edge — a shape defect
    /// no single top-margin number can see. Fixed by folding `font.ascender` into
    /// `lineExceedsFragment`'s own comparison (the same figure `oversizedClearanceBelowBaseline`
    /// already cites as what `NSLayoutManager.defaultLineHeight` itself is built from), so a
    /// borderline line like this one now correctly routes through the self-pass mechanism
    /// job 227/396/412/413 already built and proved out on LJ6DTP.WS/OLDTIMES.WS.
    ///
    /// This asserts the MECHANISM directly (`oversizedSelfPasses` non-nil for the title's own
    /// physical line), not a pixel scalar — the exact kind of check the bug's own history
    /// shows a pixel-margin-only law cannot catch. Renderer-level and fast, not view/pixel
    /// dependent, so it catches a regression in the DECISION independent of whatever a later
    /// job's screen pipeline happens to do with the result.
    @MainActor
    private static func assertTitleRoutesThroughOversizedPass(fixture: String) throws {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "TitleAscenderTests.oversized.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .printed)
        let firstPageSelfPasses = rendered.oversizedSelfPasses.first ?? []
        #expect(firstPageSelfPasses.contains(where: { $0 != nil }), """
            \(fixture) page 1 should route its title line through the oversized self-pass \
            mechanism (`DocumentRenderer.lineExceedsFragment`) — none of its \
            \(firstPageSelfPasses.count) physical lines did. A line whose font's own ascender \
            exceeds its assigned lead falling through to ordinary layout is exactly what \
            produced job 422's clipped/malformed WARPRAYR.WS title.
            """)
    }

    @Test @MainActor func warprayrTitleRoutesThroughOversizedPass() throws {
        try Self.assertTitleRoutesThroughOversizedPass(fixture: "WARPRAYR.WS")
    }

    @Test @MainActor func lyingTitleRoutesThroughOversizedPass() throws {
        try Self.assertTitleRoutesThroughOversizedPass(fixture: "LYING.WS")
    }

    // MARK: - View vs. engine (job 396 item 3)

    /// Job 396 item 3: the view-vs-engine assertion that catches this CLASS of bug, not only
    /// this one instance — the Native view's own measured title-top position, checked
    /// (tolerance, not byte-for-byte — `PixelOracleAppEngine`'s own doc comment already
    /// establishes the two renderers were never meant to agree pixel-for-pixel, only in
    /// PLACEMENT: Courier Prime substitution, independent rasterizers) against the engine's
    /// REAL `emitPDF` bytes for the SAME document, rasterized through PDFKit
    /// (`PixelOracleAppEngine.renderEngine`, already this repo's own app-vs-engine pixel
    /// oracle, job 223) — reused rather than re-derived, and Continuous Scroll (not Single
    /// Page) so `PagedDocumentView.rect(ofPage:)` is the real crop boundary print/export/QL
    /// already use (job 396's own fix to that function).
    @MainActor
    private static func assertTitleTopAgreesWithEngine(fixture: String, tolerance: Double = 5) throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent(fixture)
        let appPages = try PixelOracleAppEngine.renderApp(fixtureURL: url)
        let enginePages = try PixelOracleAppEngine.renderEngine(fixtureURL: url)
        guard let appPage = appPages.first else { throw ProbeError.noBitmap }
        guard let enginePage = enginePages.first else { throw ProbeError.noBitmap }

        guard let appMargins = RenderProbeKit.inkMargins(
            in: appPage.bitmap, background: .white, viewSize: appPage.pointSize)
        else { throw ProbeError.noInk }
        guard let engineMargins = RenderProbeKit.inkMargins(
            in: enginePage.bitmap, background: .white, viewSize: enginePage.pointSize)
        else { throw ProbeError.noInk }

        #expect(abs(appMargins.top - engineMargins.top) < tolerance, """
            \(fixture) page 1's title-top should land within \(tolerance)pt of the engine's \
            own emitPDF placement — app measured \(appMargins.top)pt, engine measured \
            \(engineMargins.top)pt.
            """)
    }

    /// DARKNESS.WS's matching test was removed in job 400 — see this file's own top doc
    /// comment.
    @Test @MainActor func warprayrTitleTopAgreesWithEngine() throws {
        try Self.assertTitleTopAgreesWithEngine(fixture: "WARPRAYR.WS")
    }

    @Test @MainActor func lj6dtpTitleTopAgreesWithEngine() throws {
        try Self.assertTitleTopAgreesWithEngine(fixture: "LJ6DTP.WS")
    }
}
