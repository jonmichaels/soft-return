import AppKit
import SwiftUI

/// The minimal progress sheet behind Help ▸ "Index All WordStar Documents…" (job 152 Part C):
/// "found N, requested M, done", cancelable. All the real work is `SpotlightBackfill` — this
/// is deliberately thin, matching the spec's "engine, testable; UI thin" split.
///
/// `ObservableObject`/`@Published`, not `@Observable` — see `BatchModel`'s header comment
/// (job 342): the Observation framework's macro needs macOS 14, and this SwiftUI sheet must
/// keep working at the app's macOS 13.0 floor.
@MainActor
final class SpotlightBackfillModel: ObservableObject {
    @Published private(set) var snapshot = SpotlightBackfill.Snapshot(found: 0, requested: 0, done: false)
    @Published private(set) var isCancelled = false

    var statusText: String {
        if !snapshot.done && snapshot.found == 0 && snapshot.requested == 0 {
            return "Looking for WordStar documents…"
        }
        if snapshot.done {
            return isCancelled
                ? "Cancelled after \(snapshot.requested) of \(snapshot.found)."
                : "Indexed \(snapshot.requested) of \(snapshot.found) document(s)."
        }
        return "Found \(snapshot.found). Indexed \(snapshot.requested)…"
    }

    func run(finder: MetadataQuerying) async {
        snapshot = SpotlightBackfill.Snapshot(found: 0, requested: 0, done: false)
        isCancelled = false
        snapshot = await SpotlightBackfill.run(
            finder: finder,
            isCancelled: { @Sendable [weak self] in await MainActor.run { self?.isCancelled ?? false } },
            progress: { @Sendable [weak self] snapshot in await MainActor.run { self?.snapshot = snapshot } })
    }

    func cancel() { isCancelled = true }
}

final class SpotlightBackfillWindowController: NSWindowController, NSWindowDelegate {
    private let model = SpotlightBackfillModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Index All WordStar Documents"
        window.setAccessibilityIdentifier("spotlight-backfill-window")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SpotlightBackfillView(model: model))
        window.delegate = self
        // Job 397 (Jon F9): fixes the bottom-left-corner spawn — see
        // `AboutWindowController.buildContent`'s comment on the same call. A transient
        // progress window; opening it IS the command, so there's no "remembered position" a
        // user would expect the way a form window has.
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Starts the real run as soon as the window is on screen — there is no "Start" button;
    /// opening this window IS the command, per the menu item's own "…" ellipsis convention.
    func start() {
        Task { @MainActor in
            await model.run(finder: NSMetadataQueryCandidateFinder())
        }
    }

    /// Closing the window (⌘W, the red button, or the Cancel/Done button below) is the only
    /// cancellation gesture — it always tells the model to stop, which is a no-op once the run
    /// has already finished.
    func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}

private struct SpotlightBackfillView: View {
    @ObservedObject var model: SpotlightBackfillModel

    var body: some View {
        VStack(spacing: 16) {
            if !model.snapshot.done {
                ProgressView().controlSize(.small)
            }
            Text(model.statusText)
                .accessibilityIdentifier("spotlight-backfill-status")
                .multilineTextAlignment(.center)
            Button(model.snapshot.done ? "Done" : "Cancel") {
                model.cancel()
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(model.snapshot.done ? .defaultAction : .cancelAction)
            .accessibilityIdentifier("spotlight-backfill-cancel-button")
        }
        .padding(20)
        .frame(width: 340)
    }
}
