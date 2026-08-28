import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 536 (v4.0.0 UI notes, Part A1) — Jon's ruling: every window whose titlebar shows a
/// title (+ optional document icon) must be CENTERED, never left-justified. His screenshot of
/// an installed b34 showed the document window's title ("OLDTIMES.WS") hugging the left.
///
/// AppKit centers a `.titled` window's title (and its represented-file proxy icon, as one
/// group) automatically — this is the "standard AppKit way" and there is no public API to ask
/// for it explicitly; it is what you get by NOT fighting it. Centering breaks only when a
/// window adopts `.fullSizeContentView` (the title then draws over custom content with no
/// guaranteed centering) or attaches an `NSToolbar` without `.expanded` style (toolbar items
/// can push the title off-center). Neither applies anywhere in this app: confirmed live —
/// `outbox/job536/evidence/titlebar-crop3.png` is a real `screencapture` of the running Debug
/// build with `TestDocs/ws7/OLDTIMES.WS` open, and the title+proxy-icon group sits centered in
/// the frame. HONESTY per the job brief: that is one headless/live self-consistency check on
/// one machine, one window size, one build configuration — not Jon's own acceptance screenshot
/// of the signed release build, which is the only thing that actually closes this out.
///
/// This suite is the regression guard for the MECHANISM behind that live result: every window
/// controller that shows a real titlebar title must never pick up `.fullSizeContentView`, and
/// must never attach a toolbar that isn't `.expanded` — either one would silently break
/// centering again with no compiler warning and no failing UI test (`SoftReturnUITests` never
/// runs here at all — job 409's `com.apple.LocalAuthentication -1004` runner handshake failure
/// blocks the whole target in this environment).
@Suite("Titlebar centering contract", .serialized)
@MainActor
struct TitlebarCenteringTests {

    private func assertCenteringContract(_ window: NSWindow?, name: String, sourceLine: Int = #line) throws {
        let window = try #require(window, "\(name): no window")
        #expect(window.styleMask.contains(.titled), "\(name): must be a titled window to have a titlebar at all")
        #expect(!window.styleMask.contains(.fullSizeContentView),
                "\(name): .fullSizeContentView draws content through the titlebar and forfeits AppKit's automatic title centering")
        if !window.title.isEmpty {
            #expect(window.titleVisibility == .visible, "\(name): a non-empty title must actually be shown")
        }
        if let toolbar = window.toolbar {
            #expect(toolbar.isVisible == false || window.toolbarStyle == .expanded,
                    "\(name): a visible toolbar must use .expanded style, the one AppKit toolbar style that keeps the title centered")
        }
    }

    @Test func documentWindowKeepsTheCenteringContract() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("report.ps")
        let state = try Oracle.state(for: url)
        let controller = DocumentWindowController(state: state)
        try assertCenteringContract(controller.window, name: "document window")
    }

    @Test func settingsWindowKeepsTheCenteringContract() throws {
        let controller = SettingsWindowController(quickLookDefaultsOverride: UserDefaults(suiteName: #function))
        try assertCenteringContract(controller.window, name: "Settings window")
    }

    @Test func batchWindowKeepsTheCenteringContract() throws {
        let controller = BatchWindowController()
        try assertCenteringContract(controller.window, name: "Batch Export window")
    }

    @Test func documentInfoWindowKeepsTheCenteringContract() throws {
        let controller = DocumentInfoWindowController()
        try assertCenteringContract(controller.window, name: "Document Info panel")
    }

    @Test func spotlightBackfillWindowKeepsTheCenteringContract() throws {
        let controller = SpotlightBackfillWindowController()
        try assertCenteringContract(controller.window, name: "Spotlight backfill window")
    }

    @Test func licenseWindowKeepsTheCenteringContract() throws {
        let controller = LicenseWindowController(licenseText: "MIT")
        try assertCenteringContract(controller.window, name: "License window")
    }

    @Test func downloadProgressWindowKeepsTheCenteringContract() throws {
        let controller = DownloadProgressWindowController(assetName: "Soft-Return-4.0.0.dmg")
        try assertCenteringContract(controller.window, name: "Download progress window")
    }

    @Test func cliHelpWindowKeepsTheCenteringContract() throws {
        let controller = CLIHelpWindowController()
        try assertCenteringContract(controller.window, name: "CLI help window")
    }

    /// The About window is exempt by its own, separate ruling (job 335: an intentionally
    /// untitled title bar, `AboutWindowControllerTests.titleBarHasNoText`) — nothing to center.
    @Test func aboutWindowHasNoTitleTextSoCenteringDoesNotApply() throws {
        let controller = AboutWindowController(
            engineProbe: NoOpEngineVersionProbe(), urlOpener: NoOpAboutURLOpener())
        let window = try #require(controller.window)
        #expect(window.title.isEmpty)
    }
}

@MainActor
private final class NoOpEngineVersionProbe: EngineVersionProbing {
    func currentInfo() -> EngineVersionInfo? { nil }
}

@MainActor
private final class NoOpAboutURLOpener: AboutURLOpening {
    func open(_ url: URL) {}
}
