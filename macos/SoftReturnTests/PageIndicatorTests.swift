import AppKit
import CtrlKD
import SoftReturnShared
import Foundation
import PDFKit
import Testing
import TestSupport
@testable import SoftReturn

/// The bottom bar's page indicator ("Page N of M"): always on, in every style and display mode and for
/// every page count including one, and it follows navigation.
///
/// It began as a Single Page affordance: `-SCREEN.WS`'s footnote/endnote appendix lands entirely on the
/// document's real page 2, and Single Page mode (the factory default) shows exactly page 1 with nothing on
/// screen saying page 2 exists (`PagedDocumentView.applyPageAccessibilityLabels`'s "Page N of M" is
/// VoiceOver-only). The first version hid itself in some states ("it can't be coming and going"), and left
/// Printed alone: Printed is a PDFKit `PDFView`, not the TextKit `PagedDocumentView`, so
/// `DocumentWindowController.currentPage`/`pageTotal` read `pdfView` for it and a
/// `.PDFViewPageChanged` observer keeps the label current.
///
/// Page counts are read from the controller, never written down: the engine decides them, and a layout
/// rule that moves one must not fail a test whose subject is the indicator.
@Suite struct PageIndicatorTests {

    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    /// A controller over `url`, in `style` (Modern reproduces `-SCREEN.WS`'s two-page overflow; set
    /// manually before the window controller's `init` reads the style while building its content).
    @MainActor
    private static func controller(at url: URL, style: ViewStyle) throws -> DocumentWindowController {
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "PageIndicator.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(style)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        return controller
    }

    /// The indicator is a plain `NSTextField` found by its accessibility identifier.
    @MainActor
    private static func pageIndicatorLabel(in bar: BottomBar) throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return try #require(
            descendants(bar).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "page-indicator" },
            "no page indicator label found in the bottom bar")
    }

    // MARK: - Modern, from the page views

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func singlePageModeShowsIndicatorForMultiPageDocumentAndTracksNavigation() throws {
        let controller = try Self.controller(
            at: Self.ws7Directory.appendingPathComponent("-SCREEN.WS"), style: .modern)
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        try #require(controller.pageTotal == 2,
                     "fixture must lay out to 2 Modern pages for this test to mean anything")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false,
                "Single Page mode must show a page indicator when the document has more than one page")
        #expect(label.stringValue == "Page 1 of 2")

        // The Go menu's own "Down": the indicator moves with navigation, not only at open.
        controller.goDown(nil)
        #expect(controller.currentPage == 1)
        #expect(label.stringValue == "Page 2 of 2",
                "the indicator must track Go-menu navigation, not only the page laid out at open")

        controller.goFirstPage(nil)
        #expect(label.stringValue == "Page 1 of 2", "the indicator must track navigating back too")
    }

    /// A one-page document reads "Page 1 of 1" rather than showing nothing. The document is written
    /// here, not found: a corpus fixture that fits one page today stops doing so when a layout rule
    /// moves (it happened to two of them), and two short lines are one page for a reason no layout rule
    /// can revoke.
    @Test @MainActor func singlePageModeShowsIndicatorForOnePageDocumentToo() throws {
        let scratch = try TestScratch(prefix: "PageIndicator")
        defer { scratch.remove() }
        let url = scratch.url(for: "ONEPAGE.WS")
        try Data(Array("A One-Page Document\r\n\r\nTwo short lines, no notes of any kind.\r\n".utf8)).write(to: url)
        let controller = try Self.controller(at: url, style: .modern)
        defer { controller.close() }
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        let premise = "control document must fit on exactly one Modern page — it laid out to "
            + "\(controller.pageTotal)"
        try #require(controller.pageTotal == 1, "\(premise)")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "the indicator must never vanish, even for a one-page document")
        #expect(label.stringValue == "Page 1 of 1")
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func continuousScrollModeShowsTheIndicatorToo() throws {
        let controller = try Self.controller(
            at: Self.ws7Directory.appendingPathComponent("-SCREEN.WS"), style: .modern)
        try #require(controller.pageTotal == 2)
        controller.setDisplay(.continuousScroll)

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "Continuous Scroll must show the indicator too — no mode may hide it")
        #expect(label.stringValue == "Page 1 of 2")
    }

    // MARK: - Printed, from the PDF view

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

    /// The old `refreshPageIndicator()` hid the label for EVERY Printed document, one page or not.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func printedStyleShowsIndicatorForOnePageDocument() throws {
        let controller = try Self.printedController(fixture: "BOTHNOTE.WS")
        try #require(controller.pageTotal == 1,
                     "control fixture must be exactly one Printed page for this test to mean anything")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "Printed style must show the page indicator too — no style may hide it")
        #expect(label.stringValue == "Page 1 of 1")
    }

    /// FORMFEED.WS is a real multi-page Printed document.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func printedStyleShowsIndicatorForMultiPageDocumentAndTracksNavigation() throws {
        let controller = try Self.printedController(fixture: "FORMFEED.WS")
        try #require(controller.documentState.display.value == .singlePage,
                     "test assumes the factory-default display mode")
        let total = controller.pageTotal
        let premise = "fixture must lay out to more than one Printed page for this test to "
            + "mean anything — it laid out to \(total)"
        try #require(total >= 2, "\(premise)")

        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.isHidden == false, "Printed style must show the page indicator")
        #expect(label.stringValue == "Page 1 of \(total)")

        controller.goDown(nil)
        #expect(controller.currentPage == 1)
        #expect(label.stringValue == "Page 2 of \(total)",
                "the indicator must track Go-menu navigation in Printed style, not only the page laid out at open")

        controller.goLastPage(nil)
        #expect(label.stringValue == "Page \(total) of \(total)",
                "the indicator must track navigating to the last page too")

        controller.goFirstPage(nil)
        #expect(label.stringValue == "Page 1 of \(total)", "the indicator must track navigating back too")
    }

    /// PDFKit's own page-change notification is the mechanism, not just `goToPage(index:)`'s explicit
    /// call: this drives `pdfView.go(to:)` directly, as PDFKit's keyboard and trackpad navigation does,
    /// bypassing `DocumentWindowController`'s command layer.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func printedIndicatorTracksDirectPDFViewNavigation() throws {
        let controller = try Self.printedController(fixture: "FORMFEED.WS")
        let total = controller.pageTotal
        let premise = "fixture must lay out to at least 4 Printed pages to navigate to page 4 "
            + "— it laid out to \(total)"
        try #require(total >= 4, "\(premise)")
        let label = try Self.pageIndicatorLabel(in: controller.bottomBar)
        #expect(label.stringValue == "Page 1 of \(total)")

        let targetPage = try #require(controller.pdfView.document?.page(at: 3))
        controller.pdfView.go(to: targetPage)

        let message = "the .PDFViewPageChanged observer must update the indicator even when navigation "
            + "bypasses DocumentWindowController's own goToPage(index:) entirely"
        #expect(label.stringValue == "Page 4 of \(total)", "\(message)")
    }
}
