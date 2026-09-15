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

/// #271 M3, Jon's first-open rule for a DOCUMENT window: its height spans from the bottom of the
/// menu bar to the top of the Dock (`NSScreen.visibleFrame`), and the page is zoomed to fit whole
/// inside it — never above 100% (Actual Size) on a large screen, and landscape pages alike.
@Suite("Document window first open (#271 M3)", .serialized)
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
        #expect(layout.frame.height == Self.large.height && layout.frame.minY == Self.large.minY)
        #expect(layout.scale == actual, "the page would fit taller, but never above 100%: scale \(layout.scale)")
    }

    @Test func aLandscapePageGetsTheSameRule() {
        let layout = DocumentWindowController.firstOpenLayout(
            page: Self.landscape, visible: Self.laptop, titleBarHeight: 28, barHeight: BottomBar.barHeight, actualScale: 1)
        #expect(layout.frame.height == Self.laptop.height)
        #expect(Self.landscape.height * layout.scale <= Self.laptop.height - 28 - BottomBar.barHeight + 0.5)
        #expect(Self.landscape.width * layout.scale <= Self.laptop.width + 0.5)
        #expect(layout.frame.width <= Self.laptop.width)
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
        #expect(abs(window.frame.height - visible.height) <= 1, "window \(window.frame), visible \(visible)")
        #expect(abs(window.frame.minY - visible.minY) <= 1, "window \(window.frame), visible \(visible)")
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
