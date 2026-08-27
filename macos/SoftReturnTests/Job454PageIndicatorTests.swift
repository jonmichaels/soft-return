import AppKit
import CtrlKD
import PDFKit
import Testing
@testable import SoftReturn

/// Job 454 — Jon reported the page indicator (job 450) "coming and going" in a way he found
/// confusing, and separately that it "doesn't seem to show up at all when in Printed mode no
/// matter how many pages there are."
///
/// PART A (always on): `Job450PageIndicatorTests.swift`'s
/// `singlePageModeShowsIndicatorForOnePageDocumentToo`/`continuousScrollModeShowsTheIndicatorToo`
/// cover the mode-conditional-visibility removal for the `pagedView` surface. This file adds the
/// one case neither that file nor job 450 ever exercised: a one-page document IN PRINTED STYLE,
/// which the old `refreshPageIndicator()` gated out unconditionally regardless of page count.
///
/// PART B (Printed mode): Printed is a separate content surface — a PDFKit `PDFView`, not the
/// TextKit-hosted `PagedDocumentView` job 450 read `currentPage`/`pageTotal` from — and job 450
/// explicitly scoped it out ("only for a style that actually uses `pagedView`"). This file wires
/// and proves it: `DocumentWindowController.currentPage`/`pageTotal`
/// (`DocumentWindowController+Actions.swift`) already special-case `.printed` to read
/// `pdfView.document`/`pdfView.currentPage`; `refreshPageIndicator()` just had to stop refusing
/// to call `bottomBar.updatePageIndicator` for that style, and the app needed a new
/// `.PDFViewPageChanged` observer (`DocumentWindowController.buildContent()`) plus an explicit
/// `refreshPageIndicator()` call in `goToPage(index:)`'s own Printed branch
/// (`DocumentWindowController+Actions.swift`) so the label tracks navigation, not only the page
/// laid out at open.
/// Job 535: every test in this suite reads `TestDocs/ws7` (`OracleByteParityTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job454PageIndicatorTests {

    static var ws7Directory: URL { OracleByteParityTests.ws7Directory }

    @MainActor
    private static func printedController(fixture: String) throws -> DocumentWindowController {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let state = try Oracle.state(for: url)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 1100, height: 800))
        controller.setStyle(.printed)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    /// Same subview-walk `Job450PageIndicatorTests.pageIndicatorLabel(in:)` uses.
    @MainActor
    private static func pageIndicatorLabel(in bar: BottomBar) throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return try #require(
            descendants(bar).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "page-indicator" },
            "no page indicator label found in the bottom bar")
    }

    // MARK: - PART A: one-page document, Printed style

    /// Before job 454, `refreshPageIndicator()` gated on `documentState.style.value != .printed`
    /// — the label was hidden for EVERY Printed document, one-page or not. This is the
    /// one-page case specifically, since job 454's ruling is "always on" even where there is
    /// only one page to report.
    @Test @MainActor func printedStyleShowsIndicatorForOnePageDocument() throws {
        let controller = try Self.printedController(fixture: "BOTHNOTE.WS")
        try #require(controller.pageTotal == 1,
                     "control fixture must be exactly one Printed page for this test to mean anything")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "Printed style must show the page indicator too — no style may hide it")
        #expect(label.stringValue == "Page 1 of 1")
    }

    // MARK: - PART B: multi-page Printed document, present and tracking navigation

    /// FORMFEED.WS lays out to 8 Printed pages (`PrintedStructuralParityTests.swift`'s own
    /// "FORMFEED.WS's all-8-pages residual" note) — a real multi-page Printed document, not a
    /// synthetic one.
    @Test @MainActor func printedStyleShowsIndicatorForMultiPageDocumentAndTracksNavigation() throws {
        let controller = try Self.printedController(fixture: "FORMFEED.WS")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        try #require(controller.pageTotal == 8,
                     "fixture must lay out to 8 Printed pages for this test to mean anything")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "Printed style must show the page indicator")
        #expect(label.stringValue == "Page 1 of 8")

        // The Go menu's own "Down" — the same command `Job450PageIndicatorTests` proves moves
        // the indicator for the pagedView surface — must move it for Printed too.
        controller.goDown(nil)
        #expect(controller.currentPage == 1)
        #expect(label.stringValue == "Page 2 of 8",
                "the indicator must track Go-menu navigation in Printed style, not only the page laid out at open")

        controller.goLastPage(nil)
        #expect(label.stringValue == "Page 8 of 8", "the indicator must track navigating to the last page too")

        controller.goFirstPage(nil)
        #expect(label.stringValue == "Page 1 of 8", "the indicator must track navigating back too")
    }

    /// PDFKit's own page-change notification (`.PDFViewPageChanged`) is the mechanism, not just
    /// `goToPage(index:)`'s explicit call — this drives `pdfView.go(to:)` directly, the same
    /// call PDFKit's own keyboard/trackpad navigation makes internally, bypassing
    /// `DocumentWindowController`'s command layer entirely, to prove the notification observer
    /// itself (not just the belt-and-suspenders call in `goToPage(index:)`) is what updates the
    /// label.
    @Test @MainActor func printedIndicatorTracksDirectPDFViewNavigation() throws {
        let controller = try Self.printedController(fixture: "FORMFEED.WS")
        try #require(controller.pageTotal == 8)
        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.stringValue == "Page 1 of 8")

        let targetPage = try #require(controller.pdfView.document?.page(at: 3))
        controller.pdfView.go(to: targetPage)

        let message = "the .PDFViewPageChanged observer must update the indicator even when navigation "
            + "bypasses DocumentWindowController's own goToPage(index:) entirely"
        #expect(label.stringValue == "Page 4 of 8", "\(message)")
    }
}
