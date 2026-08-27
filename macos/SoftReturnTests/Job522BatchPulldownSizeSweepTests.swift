import AppKit
import Testing
@testable import SoftReturn

/// Job 522 (b33 N3, STRUCTURAL fix): jobs 511 and 518 could not reproduce Jon's reported b32
/// pulldown misalignment under any live condition tried (real display pass, forced `.legacy`
/// scroller, dark appearance, resized-to-minimum window — `ZZProbeJob518Diag.swift.unused`).
/// Jon then confirmed his own window "is exactly the size the window opened for me" — i.e. a
/// window restored from `BatchWindowController.init`'s own `setFrameUsingName("BatchWindow")`
/// AUTOSAVE, a variable neither prior probe seeded (both always exercised a fresh, unsaved
/// frame). The b33 ruling: stop chasing the repro and make the layout structurally
/// size-invariant instead — this suite is that structural lock. Each test renders the REAL
/// hosted window at ONE swept size (the declared minimum, the default, an odd non-integral
/// size, a larger "Jon-plausible" size, or a size RESTORED from a seeded autosave default
/// exactly the way Jon's own window opens) and asserts all 7 pulldowns' absolute frames are
/// not just internally consistent (job 511's own `allSevenPulldownsShareOneRightAlignedColumn`
/// already covers that) but IDENTICAL to a cached reference measurement taken at the window's
/// default size — the structural guarantee that misalignment is impossible by construction,
/// not by per-size coincidence.
///
/// One window per test method, never more than one live at a time: an earlier version of this
/// suite opened all 5 swept sizes back to back inside a single test method (closing each
/// before the next) and crashed reproducibly with a SIGSEGV in `objc_release` during a later
/// `Task.sleep`'s autorelease-pool drain — no application code anywhere in that crash's stack,
/// only AppKit/libdispatch/Swift-Concurrency frames, i.e. some per-process state that five
/// sequential open/sleep/close cycles inside ONE async test body corrupts but that resets
/// cleanly between separate test invocations (the shape every other window test in this
/// repo already uses, at scale, without incident). Splitting one size per test method — the
/// established, already-proven-safe shape — sidesteps it entirely.
///
/// Why this is structurally guaranteed already: `BatchView.body`'s `controlsColumn` is pinned
/// to a literal `.frame(width: 300)` (`BatchWindowController.swift`), so the column's own width
/// — and therefore everything inside it — can never see the window's outer size at all; the
/// window can only ever change how much of `fileListColumn` (the flexible third column) is
/// visible. Job 528 makes each pulldown's OWN width doubly size-invariant on top of that: it
/// is no longer a SwiftUI `.frame(width:)` offered to a `Picker` (which a real Aqua session was
/// free to ignore, per that job's ruling) but a hard `widthAnchor` constraint on a genuine
/// `NSPopUpButton` (`BatchPopUpButton`), which AutoLayout resolves identically regardless of
/// window size or host session. This suite is the empirical proof of the column-width
/// argument, not a recomputation of it.
@Suite(.serialized)
struct Job522BatchPulldownSizeSweepTests {

    private static let autosaveDefaultsKey = "NSWindow Frame BatchWindow"

    /// Same key `WindowPlacementTests.clearSavedFrame` clears — `setFrameUsingName` has no
    /// injectable suite, so a prior test (in this suite or `WindowPlacementTests`) leaving a
    /// saved frame behind would make the wrong test case exercise the seeded path. Cleared
    /// before every case, and again once each test ends.
    @MainActor
    private static func clearAutosavedFrame() {
        UserDefaults.standard.removeObject(forKey: autosaveDefaultsKey)
    }

    /// Seeds a saved autosave frame the same way a real, previously-moved/resized window would
    /// have written one — `NSWindow.saveFrame(usingName:)`, the real AppKit persistence API,
    /// not a hand-built UserDefaults string. `saveFrame(usingName:)` writes the named default
    /// directly; it does not require `setFrameAutosaveName` on THIS window first, and calling
    /// `setFrameAutosaveName("BatchWindow")` here registered the SAME autosave name on two live
    /// windows at once (this throwaway one and, moments later, `BatchWindowController`'s real
    /// one) — reproducibly crashed the host with a SIGSEGV in `objc_release` during a later
    /// `Task.sleep`'s autorelease-pool drain, isolated by running this test alone. Never shown
    /// (`defer: true`, no `makeKeyAndOrderFront`) and never explicitly closed — it never enters
    /// any AppKit window list, so plain ARC deallocation when `seed` goes out of scope is enough.
    @MainActor
    private static func seedAutosavedFrame(_ frame: NSRect) {
        let seed = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: true)
        seed.setFrame(frame, display: false)
        seed.saveFrame(usingName: "BatchWindow")
    }

    @MainActor
    private static func makeWindow(contentSize: NSSize) async throws -> (controller: BatchWindowController, content: NSView) {
        let controller = BatchWindowController()
        controller.showWindow(nil)
        controller.window?.setContentSize(contentSize)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(controller.window?.contentView)
        return (controller, content)
    }

    /// The 7 pulldowns' absolute frames, converted into the content view's own coordinate
    /// space — same technique as `Job511BatchLayoutTests.allSevenPulldownsShareOneRightAlignedColumn`.
    /// Job 528 rebuilt these as real `NSPopUpButton`s (`BatchPopUpButton`,
    /// `BatchWindowController.swift`), so this queries the control itself directly rather than
    /// the SwiftUI `PlatformViewRepresentableAdaptor<PlatformView>` host the old `Picker` +
    /// `.frame(width:)` used to render inside — the very indirection job 528's ruling replaced.
    @MainActor
    private static func pulldownFrames(in content: NSView) -> [CGRect] {
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
        return buttons.compactMap { button -> CGRect? in
            guard let superview = button.superview else { return nil }
            return superview.convert(button.frame, to: content)
        }
    }

    private struct SharedEdges: Equatable, CustomStringConvertible {
        let width: CGFloat
        let left: CGFloat
        let right: CGFloat
        var description: String { "width=\(width) left=\(left) right=\(right)" }
    }

    /// Opens ONE window at `contentSize` (seeding an autosaved frame first when `seededAutosaveFrame`
    /// is given), measures all 7 pulldowns, closes the window, and returns the one shared
    /// width/left/right edge all 7 must agree on at this size — failing the per-size internal-
    /// consistency check inline via `#expect` before returning.
    @MainActor
    private static func measureSharedEdges(contentSize: NSSize, seededAutosaveFrame: NSRect?, label: String) async throws -> SharedEdges {
        if let seeded = seededAutosaveFrame {
            seedAutosavedFrame(seeded)
        } else {
            clearAutosavedFrame()
        }
        let (controller, content) = try await makeWindow(contentSize: contentSize)
        let frames = pulldownFrames(in: content)
        controller.close()
        clearAutosavedFrame()

        let hostCountMessage = "expected 7 pulldown hosts (Variant/Style/Font/Size/Pictures/Page "
            + "Numbering/Sentence Spacing) at \(label), found \(frames.count)"
        #expect(frames.count == 7, "\(hostCountMessage)")

        let widths = Set(frames.map { $0.width.rounded() })
        let lefts = Set(frames.map { $0.minX.rounded() })
        let rights = Set(frames.map { $0.maxX.rounded() })
        #expect(widths.count == 1, "at \(label): all 7 pulldowns must share one width, found \(widths)")
        #expect(lefts.count == 1, "at \(label): all 7 pulldowns must share one left edge, found \(lefts)")
        #expect(rights.count == 1, "at \(label): all 7 pulldowns must share one right edge, found \(rights)")

        return SharedEdges(width: widths.first ?? -1, left: lefts.first ?? -1, right: rights.first ?? -1)
    }

    /// Cached once per process: the shared width/left/right edge measured at the window's
    /// shipped DEFAULT size (1080x620, no autosave involved) — the baseline every other swept
    /// size is compared against. Cached (not re-measured per test) so no test method other than
    /// whichever runs first ever opens more than one window — the same one-window-per-test
    /// shape as every other passing suite in this file.
    @MainActor
    private static var cachedDefaultSizeEdges: SharedEdges?

    @MainActor
    private static func defaultSizeEdges() async throws -> SharedEdges {
        if let cached = cachedDefaultSizeEdges { return cached }
        let edges = try await measureSharedEdges(
            contentSize: NSSize(width: 1080, height: 620), seededAutosaveFrame: nil,
            label: "shipped default (1080x620), establishing the reference")
        cachedDefaultSizeEdges = edges
        return edges
    }

    @MainActor
    private static func assertMatchesDefault(contentSize: NSSize, seededAutosaveFrame: NSRect?, label: String) async throws {
        let reference = try await defaultSizeEdges()
        let measured = try await measureSharedEdges(
            contentSize: contentSize, seededAutosaveFrame: seededAutosaveFrame, label: label)
        #expect(measured == reference,
                "pulldown geometry at \(label) (\(measured)) does not match the default-size reference (\(reference))")
    }

    @Test @MainActor func pulldownGeometryAtDefaultSize() async throws {
        // Exercises `defaultSizeEdges()` itself (population, not just consumption) — every
        // other test in this suite depends on this cache being populated correctly.
        let edges = try await Self.defaultSizeEdges()
        #expect(edges.width > 0, "reference width was never measured: \(edges)")
    }

    @Test @MainActor func pulldownGeometryAtMinimumSizeMatchesDefault() async throws {
        try await Self.assertMatchesDefault(
            contentSize: NSSize(width: 1040, height: 560), seededAutosaveFrame: nil,
            label: "declared minimum (1040x560)")
    }

    @Test @MainActor func pulldownGeometryAtLargeSizeMatchesDefault() async throws {
        try await Self.assertMatchesDefault(
            contentSize: NSSize(width: 1600, height: 900), seededAutosaveFrame: nil,
            label: "large / Jon-plausible (1600x900)")
    }

    @Test @MainActor func pulldownGeometryAtOddNonIntegralSizeMatchesDefault() async throws {
        try await Self.assertMatchesDefault(
            contentSize: NSSize(width: 1234.75, height: 733.25), seededAutosaveFrame: nil,
            label: "odd non-integral (1234.75x733.25)")
    }

    /// The case that stands in for Jon's actual bug report: a window that opens at whatever an
    /// autosave restore hands it, not a size this process chose fresh.
    @Test @MainActor func pulldownGeometryAtAutosaveRestoredSizeMatchesDefault() async throws {
        try await Self.assertMatchesDefault(
            contentSize: NSSize(width: 1337.5, height: 812),
            seededAutosaveFrame: NSRect(x: 40, y: 60, width: 1337.5, height: 812),
            label: "restored from a seeded autosaved frame (1337.5x812)")
    }
}
