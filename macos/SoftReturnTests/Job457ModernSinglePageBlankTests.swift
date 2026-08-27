import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 457 — b28 notes 4 and 8 (Jon's list, verbatim): Modern shows a BLANK page past page 1.
///
/// Note 4: `-SCREEN.WS` in Modern reads "Page 2 of 2" in the bottom bar; page 2 exists and is
/// navigable to, but nothing draws. Note 8: "Footnotes as Endnotes STILL don't display in
/// Modern" — the same event from the other end, since `-SCREEN.WS`'s note appendix is exactly
/// what overflows onto page 2.
///
/// `Job439ModernAppendixLiveTests` already proves the CONSTRUCTION is innocent: the real
/// `NSLayoutManager` genuinely places the appendix glyphs into container index 1 — but it only
/// ever drives `PagedDocumentView` through `.continuousScroll`
/// (`Job439ModernAppendixLiveTests.swift:71`), and `.singlePage` is the app's actual default
/// (`SettingsStore.swift:40`) — the exact mode Jon was in. This file drives the REAL app object
/// graph (`DocumentWindowController`, same construction `Job454PageIndicatorTests` uses) in
/// `.singlePage`, navigates to page 2 the way the Go menu does, and inspects the real, live,
/// embedded `NSTextView` AppKit is actually showing — not a synthetic probe.
///
/// Per this round's evidence law: `RenderProbeKit`'s own composited-page capture is NOT used
/// here. The strongest check below calls `cacheDisplay(in:to:)` directly on the one real page
/// `NSTextView` object embedded in the real window's real view hierarchy — the view drawing
/// itself, not an off-screen stand-in.
/// Job 535: every test in this suite reads `TestDocs/ws7` (`OracleByteParityTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job457ModernSinglePageBlankTests {

    static var ws7Directory: URL { OracleByteParityTests.ws7Directory }

    @MainActor
    private static func controller(fixture: String) throws -> DocumentWindowController {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job457ModernSinglePageBlank.\(UUID().uuidString)")!
        // `docPath`, not `Oracle.state(for:)` (which defaults it to ""): -SCREEN.WS's own
        // image (the thing that pushes it to 2 Modern pages at all, per
        // `Job439ModernAppendixLiveTests`' own citation) resolves relative to the document's
        // real path — the same construction `Job439ModernAppendixLiveTests.state(fixture:)`
        // uses for exactly this reason.
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 1100, height: 800))
        controller.setStyle(.modern)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    /// Whether `bitmap` carries any pixel meaningfully darker than white paper — the
    /// discriminator between "text actually drew" and "blank," since a page that paints no
    /// glyph at all still fills its own opaque white `backgroundColor`
    /// (`PagedDocumentView.makePageView`'s `view.backgroundColor = .white`) — a uniformly white
    /// bitmap is what "nothing drew" looks like here, not a uniformly canvas-grey one.
    /// `colorAt(x:y:)`, same technique `RenderProbeKit.inkMargins` already uses, rather than
    /// raw byte math against an assumed pixel layout.
    private static func containsInk(_ bitmap: NSBitmapImageRep, tolerance: CGFloat = 0.06) -> Bool {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return false }
        for y in 0..<height {
            for x in 0..<width {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - 1) > tolerance || abs(c.greenComponent - 1) > tolerance
                    || abs(c.blueComponent - 1) > tolerance {
                    return true
                }
            }
        }
        return false
    }

    @Test @MainActor func screenWSPageTwoDrawsInSinglePageMode() throws {
        let controller = try Self.controller(fixture: "-SCREEN.WS")
        try #require(controller.pageTotal == 2,
                     "-SCREEN.WS must lay out to 2 Modern pages for this repro to mean anything")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode — the one Jon actually saw the bug in")

        controller.goDown(nil)
        try #require(controller.currentPage == 1, "navigation to page 2 (the Go menu's own path) must have taken effect")
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let pageView = controller.pagedView.pageViews[1]

        // Candidate 1: is the view even positioned and visible once it is the current page?
        #expect(pageView.isHidden == false, "page 2's NSTextView must not be hidden once it is the current page")
        #expect(pageView.frame.width > 0 && pageView.frame.height > 0,
                "page 2's NSTextView must have a non-zero frame once shown")
        #expect(controller.pagedView.bounds.intersects(pageView.frame),
                "page 2's NSTextView frame must fall inside the document view's own bounds")

        // Candidate 2: did AppKit actually place glyphs in THIS container?
        guard let layoutManager = pageView.layoutManager, let container = pageView.textContainer else {
            Issue.record("page 2's NSTextView has no layout manager/text container")
            return
        }
        let glyphRange = layoutManager.glyphRange(for: container)
        #expect(glyphRange.length > 0, "page 2's own text container must have a non-empty glyph range")

        // Candidate 3 (strongest, per this job's brief): render THIS real, live, embedded
        // NSTextView exactly as it draws on screen and look for actual ink. Not
        // RenderProbeKit's own composited page-level capture — the real view object drawing
        // itself.
        guard let bitmap = pageView.bitmapImageRepForCachingDisplay(in: pageView.bounds) else {
            Issue.record("could not allocate a bitmap for page 2's own real NSTextView")
            return
        }
        pageView.cacheDisplay(in: pageView.bounds, to: bitmap)
        let inked = Self.containsInk(bitmap)
        #expect(inked, "page 2's real, live NSTextView must draw actual ink — a blank result here IS Jon's reported bug, reproduced headless")
    }

    /// Job 460 — step 1 of the third attempt at this defect: measure the page-2 `NSTextView`'s
    /// real geometry state IMMEDIATELY after `showPage`/`goDown`, BEFORE any masking call
    /// (`layoutSubtreeIfNeeded`/`cacheDisplay`) forces AppKit to hand it a frame. job-457's own
    /// test (above) already calls `controller.window?.contentView?.layoutSubtreeIfNeeded()`
    /// right after navigating — job-457 recorded a zero-frame snapshot BEFORE that call and
    /// dismissed it as "a synchronous-test artifact." This test asserts on that same
    /// pre-settle snapshot directly, with raw numbers, instead of discarding it.
    @Test @MainActor func screenWSPageTwoFrameStateBeforeAndAfterSettle() throws {
        let controller = try Self.controller(fixture: "-SCREEN.WS")
        try #require(controller.pageTotal == 2,
                     "-SCREEN.WS must lay out to 2 Modern pages for this repro to mean anything")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode — the one Jon actually saw the bug in")

        // `Self.controller(fixture:)` already called `layoutSubtreeIfNeeded()` once, while page 1
        // was current — that settles PAGE 1 only (job-460 brief: "page 1 received its one and
        // only real frame during the first layout() at setContent time"). Nothing has forced
        // layout since, so page 2 is exactly where `showPage`/`applyDisplayMode` left it.
        controller.goDown(nil)
        try #require(controller.currentPage == 1, "navigation to page 2 (the Go menu's own path) must have taken effect")

        let pageView = controller.pagedView.pageViews[1]

        // --- BEFORE any settle call ---
        let beforeFrame = pageView.frame
        let beforeBounds = pageView.bounds
        let beforeContainerSize = pageView.textContainer?.containerSize ?? .zero
        let beforeGlyphRange = pageView.layoutManager.map { $0.glyphRange(for: pageView.textContainer!) }
        let beforeIsHidden = pageView.isHidden
        let beforeNeedsLayout = pageView.needsLayout
        let beforeNeedsDisplay = pageView.needsDisplay

        // --- AFTER a settle pass (the same call job-457's own test already relies on) ---
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let afterFrame = pageView.frame
        let afterContainerSize = pageView.textContainer?.containerSize ?? .zero
        let afterGlyphRange = pageView.layoutManager.map { $0.glyphRange(for: pageView.textContainer!) }
        let afterIsHidden = pageView.isHidden

        // Raw numbers, unconditionally — evidence law: state what was measured before any verdict.
        print("""
        job-460 step 1 measurements for -SCREEN.WS page 2 (index 1), Modern .singlePage:
          BEFORE settle: frame=\(beforeFrame) bounds=\(beforeBounds) containerSize=\(beforeContainerSize) \
        glyphRange=\(String(describing: beforeGlyphRange)) isHidden=\(beforeIsHidden) \
        needsLayout=\(beforeNeedsLayout) needsDisplay=\(beforeNeedsDisplay)
          AFTER settle:  frame=\(afterFrame) containerSize=\(afterContainerSize) \
        glyphRange=\(String(describing: afterGlyphRange)) isHidden=\(afterIsHidden)
        """)

        // The invariant this job exists to establish: a page view must never be VISIBLE at a
        // zero frame. `isHidden == false` is the "visible" half of that; the frame must already
        // be real by the time it is checked, not merely by the time some LATER call forces it.
        #expect(beforeIsHidden == false,
                "page 2 must already be unhidden right after showPage — if this is false the bug is not a zero-frame-while-visible defect at all")
        #expect(beforeFrame.width > 0 && beforeFrame.height > 0,
                "page 2's NSTextView must already have a non-zero frame immediately after showPage/applyDisplayMode, before any later call forces layout — a zero frame here IS Jon's bug, not a test artifact")
        #expect(beforeContainerSize.width > 0 && beforeContainerSize.height > 0,
                "page 2's text container must already have a real size immediately after showPage")

        // These should hold regardless — recorded for completeness, not the crux of the bug.
        #expect(afterFrame.width > 0 && afterFrame.height > 0)
        #expect(afterIsHidden == false)
        _ = afterGlyphRange
    }

    /// Job 460 — step 4's own regression guard: exercises the `SRDiagnostics=1` logging path
    /// (`PagedDocumentView.logPageDiagnostics`, fired from `applyDisplayMode` on every display-
    /// mode change and page navigation) end to end through real navigation, proving it doesn't
    /// throw/crash when enabled. NOT proof of the log's actual TEXT — that write goes to NSLog/
    /// the unified log, which this harness has no supported way to capture assertions against;
    /// see the job report for what remains unverified. `UserDefaults.standard` (not the test's
    /// own scoped suite) because `SRDiagnosticsGate.isEnabled()` reads the real default suite at
    /// every other call site in this module — reset in `defer` so this test can't leak the flag
    /// into any test that runs after it.
    @Test @MainActor func diagnosticLoggingPathDoesNotCrashWhenEnabled() throws {
        let key = SRDiagnosticsGate.defaultsKey
        let hadPriorValue = UserDefaults.standard.object(forKey: key) != nil
        let priorValue = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if hadPriorValue {
                UserDefaults.standard.set(priorValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let controller = try Self.controller(fixture: "-SCREEN.WS")
        try #require(controller.pageTotal == 2)
        controller.goDown(nil)
        try #require(controller.currentPage == 1)
        // Job 460 report: a style switch (`setStyle(.native)`) was tried here first and dropped
        // — Native lays -SCREEN.WS out to a single page, so switching to it and back clamps
        // `currentPageIndex` to 0 (`setContent`'s own documented behaviour, not a bug), which
        // made this test's own assertion fail for a reason unrelated to the diagnostic under
        // test. `setDisplay` exercises `applyDisplayMode`'s OTHER branch (Continuous Scroll)
        // without touching page count or index.
        controller.setDisplay(.continuousScroll)
        controller.setDisplay(.singlePage)

        // If `logPageDiagnostics`'s async dispatch or its optional-chaining through
        // `layoutManager`/`textContainer` were wrong, one of the calls above would have crashed
        // this process already — Swift Testing has no separate "did not crash" assertion.
        #expect(controller.currentPage == 1)
    }

    // A second scenario was explored and ruled out, not committed as a test: note 4's wording
    // ("Jon OPENS -SCREEN.WS in MODERN, the bar reads Page 2 of 2") could describe switching
    // TO Modern from a LATER page already reached in the app's default style (Native) —
    // PagedDocumentView.setContent only CLAMPS currentPageIndex across a style switch
    // (`min(currentPageIndex, max(0, pageViews.count - 1))`), it never resets to 0, so a
    // carried-over index could in principle land Modern straight on page 2 with no navigation
    // at all. Checked empirically: -SCREEN.WS lays out to exactly ONE page in Native
    // (`controller.pageTotal == 1` after `DocumentWindowController(state:)`'s own default
    // style), so there is no later page for that index to carry over from — this specific
    // fixture cannot exercise that path. Named here, not filed as a failing/vacuous test.
}
