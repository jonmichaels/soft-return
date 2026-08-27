import AppKit
import Testing
@testable import SoftReturn

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
