import AppKit

/// Job 549: a reusable GUI layout-proof harness — hosts any `NSView` in a real, window-server-
/// backed `NSWindow`, forces a full layout pass, and hands back two forms of PROOF: a
/// machine-readable frame dump (every descendant's identifier/class/frame) and a rendered PNG
/// of what actually got drawn.
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
    public struct FrameRow: Sendable {
        public let className: String
        public let identifier: String
        public let frame: CGRect
    }

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

    // MARK: - Frame dump

    /// Every descendant of `view`, tree order (a view before its own children, siblings in
    /// declaration order) — the same order `RenderProbeKit.descendants` already establishes
    /// elsewhere in this test target; duplicated here (rather than imported) so this file has
    /// no dependency of its own and can be lifted into another target verbatim.
    public static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// One row per view in `root`'s subtree (root itself included first), every frame
    /// converted into `root`'s own coordinate space so the table reads as one flat, directly
    /// comparable geometry regardless of how deep a view actually sits in the tree.
    public static func frameTable(root: NSView) -> [FrameRow] {
        func row(_ view: NSView) -> FrameRow {
            let identifier = view.accessibilityIdentifier()
            return FrameRow(
                className: String(describing: type(of: view)),
                identifier: identifier.isEmpty ? "(no identifier)" : identifier,
                frame: view.convert(view.bounds, to: root))
        }
        return [row(root)] + descendants(root).map(row)
    }

    /// Deterministic, machine-readable text table: one line per view, fixed column order,
    /// coordinates rounded to 2 decimal places so two runs of an unchanged layout diff clean.
    public static func renderFrameTable(_ rows: [FrameRow]) -> String {
        func fmt(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        let lines = rows.map { row in
            "\(row.className)\t\(row.identifier)\tx=\(fmt(row.frame.minX)) y=\(fmt(row.frame.minY)) "
                + "w=\(fmt(row.frame.width)) h=\(fmt(row.frame.height))"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders and writes `frameTable(root:)` in one call — the shape every caller actually
    /// wants (a proof artifact on disk), returning the text too so a test can assert on it
    /// without re-reading the file it just wrote.
    @discardableResult
    public static func writeFrameTable(root: NSView, to url: URL) throws -> String {
        let text = renderFrameTable(frameTable(root: root))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return text
    }

    // MARK: - Rendered PNG

    /// Full-size rendered bitmap of `view` via `cacheDisplay(in:to:)` — real composited pixels
    /// (background, subviews, and any overlay all drawn in real z-order), the same mechanism
    /// and the same reasoning `RenderProbeKit.renderPNG` already documents: a page/accessory
    /// view's own chrome (paper, borders, popup bezels) is often painted by a DIFFERENT view
    /// than the one a naive single-view capture would target.
    @discardableResult
    public static func renderPNG(
        view: NSView, appearance: NSAppearance = NSAppearance(named: .aqua)!, to url: URL
    ) throws -> Int {
        try RenderProbeKit.renderPNG(view: view, appearance: appearance, to: url)
    }
}
