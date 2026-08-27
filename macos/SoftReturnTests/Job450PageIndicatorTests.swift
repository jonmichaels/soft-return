import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 450 (b6): a page-position indicator for Single Page mode.
///
/// Jon reported `-SCREEN.WS`'s footnote/endnote appendix as "MISSING" in Modern. Job 439's own
/// live repro (`Job439ModernAppendixLiveTests.swift`) found the render layer innocent: the
/// appendix renders correctly and lands entirely on the document's real page 2 — but Single
/// Page mode (the factory default, `SettingsStore.swift:40`) shows exactly page 1 with NO
/// on-screen affordance anywhere telling a sighted reader page 2 exists
/// (`PagedDocumentView.applyPageAccessibilityLabels`'s own "Page N of M" is VoiceOver-only,
/// `DocumentWindowController+Actions.swift`'s `pageTotal`/`currentPage` only ever fed menu-item
/// enablement and the "Go to Page" dialog). The render was never broken; the app hid half the
/// document with nothing on screen to say so.
///
/// Navigation to page 2 was ALREADY reachable in Single Page mode before this job — the Go menu
/// (`Down`/`Last Page`/`Go to Page…`, `MainMenu.swift`'s `goMenu()`) and a trackpad scroll
/// gesture (`PagedDocumentView.scrollWheel`) both already flip pages — `GoMenuTests.swift`
/// already covers that reachability. The defect is purely that nothing SIGHTED reported the
/// count, so the fix is a `BottomBar` label (`BottomBar.updatePageIndicator`), reusing the
/// bar's own existing "bare value, no ceremony" idiom rather than inventing new UI. It appears
/// only in Single Page mode: Continuous Scroll already shows other pages' edges to a sighted
/// reader (`PagedDocumentView.applyPageAccessibilityLabels`'s own doc comment), and a one-page
/// document has nothing to report — showing "Page 1 of 1" would be furniture nobody asked for.
///
/// No pagination/layout/rendering changed for this fix — a presentation-layer addition only,
/// which `PixelOracleAppEngineTests`/`OracleByteParityTests` (untouched by this job) are what
/// continue to prove.
///
/// JOB 454 UPDATE: Jon reported the mode-conditional visibility this job shipped as
/// "confusing... it can't be coming and going" — the indicator is now unconditional (every
/// style, every display mode, every page count, including "Page 1 of 1" for a one-page
/// document). The two tests below that asserted the OLD hidden-in-some-states behaviour
/// (`singlePageModeHidesIndicatorForOnePageDocument`, `continuousScrollModeHidesTheIndicator`)
/// are updated in place to assert the new always-visible contract — see
/// `Job454PageIndicatorTests.swift` for the Printed-mode coverage this job's brief scoped out
/// (`DocumentWindowController.refreshPageIndicator`'s doc comment, at the time).
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job450PageIndicatorTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    /// Modern, the style `-SCREEN.WS` needs to reproduce the 2-page overflow
    /// (`Job439ModernAppendixLiveTests.swift`'s own finding) — set manually before the window
    /// controller's `init` reads `documentState.style.value` during its own `buildContent()`.
    @MainActor
    private static func controller(fixture: String) throws -> DocumentWindowController {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job450PageIndicator.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.modern)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        return controller
    }

    /// Same subview-walk `BottomBarHeaderTests.popup(_:in:)` uses to find a control by its
    /// accessibility identifier — the indicator is a plain `NSTextField`, not a popup, so this
    /// is the text-field equivalent of that same lookup.
    @MainActor
    private static func pageIndicatorLabel(in bar: BottomBar) throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return try #require(
            descendants(bar).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "page-indicator" },
            "no page indicator label found in the bottom bar")
    }

    // MARK: - Single Page mode, multi-page document: the indicator shows and tracks navigation

    @Test @MainActor func singlePageModeShowsIndicatorForMultiPageDocumentAndTracksNavigation() throws {
        let controller = try Self.controller(fixture: "-SCREEN.WS")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        try #require(controller.pageTotal == 2,
                     "fixture must lay out to 2 Modern pages (Job439's own finding) for this test to mean anything")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false,
                "Single Page mode must show a page indicator when the document has more than one page")
        #expect(label.stringValue == "Page 1 of 2")

        // The Go menu's own "Down" — a reader reaching page 2 the same way GoMenuTests proves
        // is already possible — must move the indicator, not just the initial render.
        controller.goDown(nil)
        #expect(controller.currentPage == 1)
        #expect(label.stringValue == "Page 2 of 2",
                "the indicator must track Go-menu navigation, not only the page laid out at open")

        controller.goFirstPage(nil)
        #expect(label.stringValue == "Page 1 of 2", "the indicator must track navigating back too")
    }

    // MARK: - Single Page mode, one-page document: always on (job 454)

    /// Job 450 shipped this fixture hiding the indicator ("no furniture nobody asked for").
    /// Job 454: Jon ruled the coming-and-going itself confusing — "Always on" — so a one-page
    /// document now reads "Page 1 of 1" rather than showing nothing.
    @Test @MainActor func singlePageModeShowsIndicatorForOnePageDocumentToo() throws {
        let controller = try Self.controller(fixture: "BOTHNOTE.WS")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        try #require(controller.pageTotal == 1,
                     "control fixture (no image, unlike -SCREEN.WS) must fit on exactly one Modern page")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false,
                "job 454: the indicator must never vanish, even for a one-page document")
        #expect(label.stringValue == "Page 1 of 1")
    }

    // MARK: - Continuous Scroll: also always on (job 454)

    /// Job 450 shipped this fixture hiding the indicator in Continuous Scroll. Job 454: "Always
    /// on" applies to every display mode, not just Single Page.
    @Test @MainActor func continuousScrollModeShowsTheIndicatorToo() throws {
        let controller = try Self.controller(fixture: "-SCREEN.WS")
        try #require(controller.pageTotal == 2)
        controller.setDisplay(.continuousScroll)

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false,
                "job 454: Continuous Scroll must show the indicator too — no mode may hide it")
        #expect(label.stringValue == "Page 1 of 2")
    }
}
