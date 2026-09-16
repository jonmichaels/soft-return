import AppKit
import Testing
@testable import SoftReturn
import SoftReturnShared

/// Job 397 (Jon F9 ruling): every programmatic (non-document) window used to spawn touching
/// the screen's bottom-left corner — `NSWindow(contentRect:)` takes contentRect's origin as a
/// literal SCREEN-space frame, and (0, 0) is that corner, not "AppKit will place it". The
/// ruling: centered horizontally, upper third, `NSWindow.center()` semantics — "the same rough
/// placement as the Check for Updates pop-up" (an `NSAlert`, which AppKit centers this same way
/// when run outside a sheet). Document windows (`NSDocument`-managed, cascading) are explicitly
/// OUT of scope and have no test here.
///
/// This suite exercises the REAL `center()`/frame-autosave call each controller now makes (not
/// a re-derivation of AppKit's placement math), so it is measuring actual on-screen behavior —
/// same discipline job 395's "ports measured inert first" used for its own geometry fix.
@Suite("Window placement (job 397)", .serialized)
@MainActor
struct WindowPlacementTests {

    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "WindowPlacementTests.\(UUID().uuidString)")!)
    }

    /// Every in-scope window is given a FRESH frame-autosave name's worth of throwaway state:
    /// `setFrameUsingName` reads from `NSUserDefaultsController`/`UserDefaults.standard` under
    /// a fixed key literal (`"BatchWindow"` etc — AppKit's autosave API has no injectable
    /// suite), so a prior test run on the same host that left a saved frame behind would make
    /// `setFrameUsingName` succeed and skip the `center()` fallback this suite means to
    /// exercise. Clearing the key first makes every run exercise the true first-open path
    /// regardless of what a previous session saved.
    private func clearSavedFrame(_ autosaveName: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
    }

    private func assertCenteredUpperThirdNoEdges(
        _ window: NSWindow?, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let window = try #require(window, "\(name) has no window", sourceLocation: sourceLocation)
        let screen = try #require(
            window.screen ?? NSScreen.main, "no screen available to check \(name) against",
            sourceLocation: sourceLocation)
        let visible = screen.visibleFrame
        let frame = window.frame

        let horizontalOffset = abs(frame.midX - visible.midX)
        #expect(horizontalOffset <= 2,
                "\(name) is not horizontally centered: frame.midX=\(frame.midX), screen.visibleFrame.midX=\(visible.midX)",
                sourceLocation: sourceLocation)

        #expect(frame.minX > visible.minX && frame.maxX < visible.maxX,
                "\(name) touches the screen's left/right edge: frame=\(frame), visible=\(visible)",
                sourceLocation: sourceLocation)
        #expect(frame.minY > visible.minY && frame.maxY < visible.maxY,
                "\(name) touches the screen's top/bottom edge: frame=\(frame), visible=\(visible)",
                sourceLocation: sourceLocation)

        // "Upper third" per the ruling is `center()`'s own vertical bias, not a literal
        // screen-thirds partition (impossible for a window taller than a third of the screen,
        // e.g. Batch at 620pt) — `center()` places the window ABOVE dead-center vertically, the
        // same lift an `NSAlert` gets. This asserts that bias, not a fixed fraction.
        #expect(frame.midY >= visible.midY,
                """
                \(name) sits at or below the screen's exact vertical center (frame.midY=\(frame.midY), \
                screen.visibleFrame.midY=\(visible.midY)) — expected center()'s upward bias, not dead-center or lower
                """,
                sourceLocation: sourceLocation)
    }

    @Test func aboutWindowIsCenteredUpperThird() throws {
        let controller = AboutWindowController()
        try assertCenteredUpperThirdNoEdges(controller.window, name: "About")
    }

    @Test func cliHelpWindowIsCenteredUpperThird() throws {
        let controller = CLIHelpWindowController(bundledExecutableURL: URL(fileURLWithPath: "/tmp/sr"))
        try assertCenteredUpperThirdNoEdges(controller.window, name: "CLI Help")
    }

    @Test func downloadProgressWindowIsCenteredUpperThird() throws {
        let controller = DownloadProgressWindowController(assetName: "Soft-Return.dmg")
        try assertCenteredUpperThirdNoEdges(controller.window, name: "Download Progress")
    }

    @Test func spotlightBackfillWindowIsCenteredUpperThird() throws {
        let controller = SpotlightBackfillWindowController()
        try assertCenteredUpperThirdNoEdges(controller.window, name: "Spotlight Backfill")
    }

    @Test func settingsWindowIsCenteredUpperThirdOnFirstOpen() throws {
        clearSavedFrame("SettingsWindow")
        let controller = SettingsWindowController(settings: throwawaySettings())
        try assertCenteredUpperThirdNoEdges(controller.window, name: "Settings")
    }

    @Test func documentInfoWindowIsCenteredUpperThirdOnFirstOpen() throws {
        clearSavedFrame("DocumentInfoPanel")
        let controller = DocumentInfoWindowController()
        try assertCenteredUpperThirdNoEdges(controller.window, name: "Document Info")
    }

    @Test func batchWindowIsCenteredUpperThirdOnFirstOpen() throws {
        clearSavedFrame("BatchWindow")
        let controller = BatchWindowController()
        try assertCenteredUpperThirdNoEdges(controller.window, name: "Batch")
    }

    /// Dead code as of job 335 (nothing constructs `LicenseWindowController` anymore — see its
    /// header comment) but still given the same first-open fallback as the other frame-autosave
    /// windows, so this pins that it isn't a live placement bug the day something reconnects it.
    @Test func licenseWindowIsCenteredUpperThirdOnFirstOpen() throws {
        clearSavedFrame("LicenseWindow")
        let controller = LicenseWindowController(licenseText: "MIT")
        try assertCenteredUpperThirdNoEdges(controller.window, name: "License")
    }
}

/// #271 M3, Jon's first-open rule for a DOCUMENT window: the page is zoomed to fit whole inside the
/// visible frame, from the bottom of the menu bar to the top of the Dock (`NSScreen.visibleFrame`), never
/// above 100% (Actual Size) on a large screen, and landscape pages alike. Batch 40 (M13, a refinement of
/// M3): the window is exactly that fitted page plus the title bar and the bottom bar, centred, in both
/// orientations; it spans the visible height only when the page's height limits the fit.
@Suite("Document window first open (#271 M3, M13)", .serialized)
@MainActor
struct DocumentWindowFirstOpenTests {
    static let letter = CGSize(width: 612, height: 792)
    static let landscape = CGSize(width: 792, height: 612)
    /// A 13-inch laptop's visible frame (1440×900, menu bar and Dock taken out — short enough that
    /// a Letter page must shrink) and a 27-inch display's.
    static let laptop = NSRect(x: 0, y: 85, width: 1440, height: 790)
    static let large = NSRect(x: 0, y: 80, width: 2560, height: 1335)

    @Test func onALaptopTheWindowIsFullHeightAndThePageFitsWhole() {
        let layout = DocumentWindowController.firstOpenLayout(
            page: Self.letter, visible: Self.laptop, titleBarHeight: 28, barHeight: BottomBar.barHeight, actualScale: 1)
        #expect(layout.frame.height == Self.laptop.height && layout.frame.minY == Self.laptop.minY)
        #expect(Self.letter.height * layout.scale <= Self.laptop.height - 28 - BottomBar.barHeight + 0.5,
                "the page is cut off: \(Self.letter.height * layout.scale)pt tall")
        #expect(layout.scale < 1, "a Letter page is taller than a laptop's visible frame, so it is scaled down")
        #expect(abs(layout.frame.midX - Self.laptop.midX) <= 1)
    }

    @Test func onALargeScreenThePageStopsAtActualSize() {
        let actual: CGFloat = 1.08
        let layout = DocumentWindowController.firstOpenLayout(
            page: Self.letter, visible: Self.large, titleBarHeight: 28, barHeight: BottomBar.barHeight, actualScale: actual)
        #expect(layout.scale == actual, "the page would fit taller, but never above 100%: scale \(layout.scale)")
        // Batch 40 (M13): the window is the page at that scale and no taller, centred in the visible frame.
        #expect(layout.frame.height == (Self.letter.height * actual).rounded() + 28 + BottomBar.barHeight)
        #expect(layout.frame.width == (Self.letter.width * actual).rounded())
        #expect(abs(layout.frame.midY - Self.large.midY) <= 1 && abs(layout.frame.midX - Self.large.midX) <= 1)
    }

    /// Batch 40 (M13, Jon: "The Landscape window is opening too big all around… I want it to be exactly the same size as
    /// the page. Just like in Portrait."): a landscape page fits whole, and the window is exactly the fitted page plus the
    /// title bar and the bottom bar, in both directions, centred.
    @Test func aLandscapePageGetsTheSameRule() {
        let layout = DocumentWindowController.firstOpenLayout(
            page: Self.landscape, visible: Self.laptop, titleBarHeight: 28, barHeight: BottomBar.barHeight, actualScale: 1)
        #expect(Self.landscape.height * layout.scale <= Self.laptop.height - 28 - BottomBar.barHeight + 0.5)
        #expect(Self.landscape.width * layout.scale <= Self.laptop.width + 0.5)
        #expect(layout.frame.width == (Self.landscape.width * layout.scale).rounded())
        #expect(layout.frame.height == (Self.landscape.height * layout.scale).rounded() + 28 + BottomBar.barHeight,
                "window \(layout.frame.size) for a \(Self.landscape) page at \(layout.scale)")
        #expect(layout.frame.height < Self.laptop.height, "the landscape window spans the visible height: grey above and below")
        #expect(abs(layout.frame.midY - Self.laptop.midY) <= 1 && abs(layout.frame.midX - Self.laptop.midX) <= 1)
    }

    /// The real window on this machine's own screen, and then resized to a large display's layout:
    /// full visible height, the whole page on screen at no more than 100%. Both photographed.
    @Test func aRealDocumentWindowFollowsTheRule() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let state = try Oracle.state(for: url)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let visible = try #require(window.screen ?? NSScreen.main).visibleFrame
        window.contentView?.layoutSubtreeIfNeeded()
        // Batch 40 (M13): the window is the fitted page and its bars, as tall as the visible frame only when the page's
        // height is what limits the fit.
        #expect(window.frame.height <= visible.height + 1 && window.frame.minY >= visible.minY - 1,
                "window \(window.frame), visible \(visible)")
        let viewport = controller.currentViewportSize()
        let fitted = controller.currentPageSize()
        #expect(abs(viewport.width - fitted.width * controller.currentMagnification) <= 1
                    && abs(viewport.height - fitted.height * controller.currentMagnification) <= 1,
                "viewport \(viewport) against the page \(fitted) at \(controller.currentMagnification): grey shows")
        #expect(controller.currentMagnification <= controller.currentActualScale + 0.001,
                "Fit went above Actual Size: \(controller.currentMagnification)")
        try Self.photograph(window, "m3-firstopen-this-screen.png")

        let titleBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let large = DocumentWindowController.firstOpenLayout(
            page: Self.letter, visible: Self.large, titleBarHeight: titleBar,
            barHeight: BottomBar.barHeight, actualScale: controller.currentActualScale)
        window.setFrame(large.frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.currentMagnification <= controller.currentActualScale + 0.001,
                "Fit went above Actual Size on the large layout: \(controller.currentMagnification)")
        try Self.photograph(window, "m3-firstopen-large-screen.png")
    }

    /// Batch 40 (M13, Jon: "The Landscape window is opening too big all around. I'm seeing the gray background. I want it
    /// to be exactly the same size as the page."): REF/BOOKLET.RJS, a 792×612 landscape sheet, opens in a window whose
    /// viewport is exactly its fitted page — no grey on any side — in Native and in Printed. Photographed:
    /// m13-booklet-landscape-<view>.png.
    @Test(.tags(.corpus), .enabled(if: NativeLandscapePageTests.booklet != nil, NativeLandscapePageTests.skipReason),
          arguments: [ViewStyle.native, .printed])
    func aLandscapeDocumentWindowIsExactlyItsPage(view: ViewStyle) throws {
        let url = try #require(NativeLandscapePageTests.booklet)
        let defaults = try #require(UserDefaults(suiteName: "M13Booklet.\(UUID().uuidString)"))
        let settings = SettingsStore(defaults: defaults)
        settings.defaultStyle = view
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: settings, docPath: url.path)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let visible = try #require(window.screen ?? NSScreen.main).visibleFrame
        let page = controller.currentPageSize()
        let viewport = controller.currentViewportSize()
        let scale = controller.currentMagnification
        print("M13 BOOKLET \(view.displayName): style \(state.style.value), page \(page), scale \(scale), fitted \(page.width * scale)×\(page.height * scale), viewport \(viewport), window \(window.frame), visible \(visible)")
        #expect(state.style.value == view)
        #expect(page.width > page.height, "BOOKLET.RJS's page \(page) is not landscape")
        #expect(abs(viewport.width - page.width * scale) <= 1, "\(view.displayName): viewport \(viewport.width) wide, the page \(page.width * scale)")
        #expect(abs(viewport.height - page.height * scale) <= 1, "\(view.displayName): viewport \(viewport.height) tall, the page \(page.height * scale)")
        #expect(scale <= controller.currentActualScale + 0.001, "Fit went above Actual Size: \(scale)")
        #expect(window.frame.minY >= visible.minY - 1 && window.frame.maxY <= visible.maxY + 1, "window \(window.frame), visible \(visible)")
        try Self.photograph(window, "m13-booklet-landscape-\(view.displayName.lowercased()).png")
    }

    static func photograph(_ window: NSWindow, _ name: String) throws {
        let content = try #require(window.contentView)
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let file = proofs.appendingPathComponent(name)
        #expect(try RenderProbeKit.renderPNG(view: content, appearance: NSAppearance(named: .aqua)!, to: file) > 0)
        print("PROOF: \(file.path) window \(window.frame)")
    }
}
