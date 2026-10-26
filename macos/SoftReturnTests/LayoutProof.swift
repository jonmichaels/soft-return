import AppKit

/// A reusable GUI layout-proof harness — hosts any `NSView` in a real, window-server-
/// backed `NSWindow` and forces a full layout pass, so a test measures the frames the view
/// has once it is actually on screen.
///
/// Why a real window at all, rather than the bare `view.layoutSubtreeIfNeeded()` most existing
/// tests use: job 545's own honesty caveat records that its "verification" ran on a headless
/// macOS 15.7.4 box and was NOT a live screenshot of the macOS 26/Tahoe session where Jon's bug
/// report came from — a view laid out without ever being hosted in a window can resolve
/// `NSStackView`/`NSGridView` ambiguities differently than the same view once it is actually on
/// screen. The test host has a real GUI login session, so hosting for real (offscreen —
/// positioned outside every screen's frame, not `isVisible == false`, so it is still a genuine
/// window-server window) is available and is what this harness always does.
///
/// This file knows nothing about any specific window, view, or fixture — that is every caller's
/// job (see `Job549ExportAccessoryLayoutProofTests.swift` for the Export accessory adapter).
/// ALL future GUI layout jobs should reach for this rather than hand-rolling another one-off
/// `makeWindow()` — `Job511BatchLayoutTests`/`Job518BatchLayoutTests` each grew their own before
/// this existed.
@MainActor
public enum LayoutProof {
    // MARK: - Hosting

    /// Hosts `view` at `size` in a real, borderless, offscreen `NSWindow`: sets it as the
    /// window's content view, orders the window front, and forces layout + a display pass
    /// (plus a short sleep for the window server to actually catch up — the same margin
    /// `Job511BatchLayoutTests.makeWindow`/`Job518BatchLayoutTests.makeWindow` already use).
    /// Returns the window; `view` is reachable via `window.contentView`.
    @discardableResult
    public static func host(_ view: NSView, size: CGSize) async -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - Tree walk

    /// Every descendant of `view`, tree order (a view before its own children, siblings in
    /// declaration order) — the same order `RenderProbeKit.descendants` already establishes
    /// elsewhere in this test target; duplicated here (rather than imported) so this file has
    /// no dependency of its own and can be lifted into another target verbatim.
    public static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
