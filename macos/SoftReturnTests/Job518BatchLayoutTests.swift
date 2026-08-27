import AppKit
import Testing
@testable import SoftReturn

/// Job 518 (b33 N4): Formats and Notes now sit side by side in the Batch Export window's left
/// column, and the column's own `ScrollView` (job 511's `controlsColumn`) is gone outright —
/// verified against the REAL hosted window, real display pass included (same technique as
/// `Job511BatchLayoutTests.makeWindow`, job 518's own upgrade of it — see that file's header).
/// `ZZProbeJob518Diag.swift.unused` is the probe that dumped this suite's real numbers.
///
/// SwiftUI's `.accessibilityIdentifier(_:)` modifier does NOT show up on
/// `NSView.accessibilityIdentifier()` for these hosted controls (probed directly: every
/// descendant in this window reports an empty identifier) — job 511's own tests already
/// worked around this by filtering on the backing AppKit TYPE instead, and this file follows
/// the same pattern: checkboxes back with a `FocusRingNSButton`, in tree order matching
/// declaration order.
@Suite struct Job518BatchLayoutTests {

    @MainActor
    private static func makeWindow() async throws -> (controller: BatchWindowController, content: NSView) {
        let controller = BatchWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(controller.window?.contentView)
        return (controller, content)
    }

    /// Every `FocusRingNSButton` (checkbox) whose absolute frame sits within the 300pt-wide
    /// `controlsColumn`, in tree order. Job 518's own probe confirmed a 13th one further right
    /// (the file list's own "Include subfolders" toggle) — excluded by the `minX < 300` guard
    /// rather than a hardcoded count, so this stays correct if a checkbox is ever added.
    @MainActor
    private static func controlsColumnCheckboxes(in content: NSView) -> [CGRect] {
        let checkboxViews = RenderProbeKit.descendants(content)
            .filter { String(describing: type(of: $0)) == "FocusRingNSButton" }
        let frames: [CGRect] = checkboxViews.map { view in view.convert(view.bounds, to: content) }
        return frames.filter { frame in frame.minX < 300 }
    }

    // MARK: - No scrollbar

    /// Before job 518, `controlsColumn` wrapped its `VStack` in a `ScrollView` — a second
    /// `NSScrollView` alongside the file list `Table`'s own. Removing it (Jon: "shrink the
    /// length so that all options in the left column display without a scrollbar") should
    /// leave exactly the file list's `Table` scroll view and nothing else.
    @Test @MainActor func controlsColumnHasNoScrollView() async throws {
        let (_, content) = try await Self.makeWindow()
        let scrollViews = RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }
        let message = "expected exactly 1 NSScrollView (the file list's own Table), found "
            + "\(scrollViews.count): \(scrollViews.map(\.frame))"
        #expect(scrollViews.count == 1, "\(message)")
    }

    // MARK: - Formats + Notes side by side

    /// Formats' 5 checkboxes and Notes' 4 checkboxes must occupy the SAME row (matching top
    /// edge) with Notes strictly to the right of Formats — two columns, not one stacked on
    /// the other. Declaration order (`controlsColumn`'s `HStack { formatsBox; notesBox }`)
    /// puts Formats' 5 checkboxes first in tree order, Notes' 4 next — job 518's own probe
    /// confirmed this ordering directly against the real window.
    @Test @MainActor func formatsAndNotesSitSideBySideInOneRow() async throws {
        let (_, content) = try await Self.makeWindow()
        let checkboxes = Self.controlsColumnCheckboxes(in: content)
        #expect(checkboxes.count == 12,
                "expected 12 controlsColumn checkboxes (5 Formats + 4 Notes + 3 Options), found \(checkboxes.count)")
        guard checkboxes.count == 12 else { return }

        let formatFrames = Array(checkboxes[0..<5])
        let noteFrames = Array(checkboxes[5..<9])

        let formatsMaxX = formatFrames.map(\.maxX).max() ?? 0
        let notesMinX = noteFrames.map(\.minX).min() ?? 0
        let sideBySideMessage = "Formats column (rightmost edge \(formatsMaxX)) must sit entirely left of "
            + "Notes (leftmost edge \(notesMinX)) — not stacked above/below it"
        #expect(formatsMaxX < notesMinX, "\(sideBySideMessage)")

        let formatsTop = formatFrames.map(\.minY).min() ?? 0
        let notesTop = noteFrames.map(\.minY).min() ?? 0
        let rowMessage = "Formats' first row (y=\(formatsTop)) and Notes' first row (y=\(notesTop)) "
            + "must start at the same height — one row, two columns"
        #expect(abs(formatsTop - notesTop) <= 2, "\(rowMessage)")
    }

    // MARK: - Everything fits at the window's default size, no clipping

    /// Nothing in the left column may sit below the content view's own bounds at the window's
    /// DEFAULT size — Jon's ask was that nothing needs to scroll to be seen. Measures every
    /// descendant view (not just checkboxes) restricted to the 300pt `controlsColumn`'s own
    /// x-range, so the true bottommost content (the Destination box's buttons) is what's
    /// checked, without needing to name a specific control.
    @Test @MainActor func leftColumnContentFitsWithoutScrollingAtDefaultWindowSize() async throws {
        let (controller, content) = try await Self.makeWindow()
        let contentHeight = try #require(controller.window?.contentView?.bounds.height)

        let allViews = RenderProbeKit.descendants(content)
        let allFrames: [CGRect] = allViews.map { view in view.convert(view.bounds, to: content) }
        let columnFrames = allFrames.filter { frame -> Bool in
            guard frame.width > 0, frame.height > 0 else { return false }
            guard frame.minX >= 0, frame.maxX <= 300 else { return false }
            return true
        }
        let bottomMostY = try #require(columnFrames.map(\.maxY).max(), "no controlsColumn content found")

        let fitMessage = "Left column's bottommost content (y=\(bottomMostY)) sits below the content view's "
            + "own height (\(contentHeight)) at the window's default size — needs a scrollbar to reach"
        #expect(bottomMostY <= contentHeight, "\(fitMessage)")
    }

    /// Job 520 (N5, b33 page-numbering UI): the brief for the new Page Numbering row asks
    /// explicitly to verify "at default and minimum window sizes" — the default-size check
    /// above predates that row; this pins the SAME "nothing needs to scroll to be seen"
    /// property at the window's declared minimum (`.frame(minWidth: 1040, minHeight: 560)`,
    /// `BatchWindowController.swift`'s own `BatchView.body`), the size where the one new row
    /// this job adds has the least slack to work with.
    @Test @MainActor func leftColumnContentFitsWithoutScrollingAtMinimumWindowSize() async throws {
        let (controller, content) = try await Self.makeWindow()
        guard let window = controller.window else {
            Issue.record("no window")
            return
        }
        window.setContentSize(NSSize(width: 1040, height: 560))
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        content.layoutSubtreeIfNeeded()

        let contentHeight = content.bounds.height
        #expect(abs(contentHeight - 560) < 1, "window did not actually shrink to its declared 560pt minimum")

        let scrollViews = RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }
        let scrollMessage = "expected exactly 1 NSScrollView (the file list's own Table) at minimum size, found "
            + "\(scrollViews.count): \(scrollViews.map(\.frame))"
        #expect(scrollViews.count == 1, "\(scrollMessage)")

        let allFrames: [CGRect] = RenderProbeKit.descendants(content).map { view in view.convert(view.bounds, to: content) }
        let columnFrames = allFrames.filter { frame -> Bool in
            guard frame.width > 0, frame.height > 0 else { return false }
            guard frame.minX >= 0, frame.maxX <= 300 else { return false }
            return true
        }
        let bottomMostY = try #require(columnFrames.map(\.maxY).max(), "no controlsColumn content found")
        let fitMessage = "Left column's bottommost content (y=\(bottomMostY)) sits below the content view's "
            + "own height (\(contentHeight)) at the window's MINIMUM size — needs a scrollbar to reach"
        #expect(bottomMostY <= contentHeight, "\(fitMessage)")
    }
}
