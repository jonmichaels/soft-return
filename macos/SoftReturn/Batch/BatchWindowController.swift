import AppKit
import CtrlKD
import os
import SoftReturnShared
import SwiftUI

/// The Batch Export window (⌥⌘E).
///
/// SwiftUI content in an AppKit window: the three-column layout, the form and the file
/// table are exactly what SwiftUI is good at, and the parts that must be system components
/// — the folder picker, the open panel, the save sheet — are real AppKit panels called from
/// the view, not drawn by it.
///
/// Job 528 (b34 intake N2, Jon's ruling — "That's the Settings window from Soft Return. That
/// one is correct. Have the worker do it the same way."): the controls column's seven
/// pulldowns (Variant/Style/Font/Size/Pictures/Page #/Spacing) were a SwiftUI `Picker` wrapped
/// in `.frame(width:)` — a width SwiftUI's own private macOS Picker backing silently ignores
/// outside a headless test host, sizing to its widest menu item and floating centered in the
/// slot instead (the root cause of jobs 511/518/522 never reproducing what Jon actually saw).
/// `BatchPopUpButton` below is the fix: a real `NSPopUpButton`, exactly the way
/// `SettingsWindowController.popup(_:_:_:_:)` builds its own —
/// `translatesAutoresizingMaskIntoConstraints = false` plus a hard `widthAnchor` constraint on
/// the CONTROL ITSELF, which AutoLayout enforces regardless of session — bridged into this
/// SwiftUI column via `NSViewRepresentable` rather than hoisting the whole column to AppKit,
/// the smaller diff of the two options the brief allowed.
final class BatchWindowController: NSWindowController {
    /// #271 M11, batch 31: the Mode row's label and the caption under Font and Size. Constants so a test can hold
    /// the words: SwiftUI `Text` cannot be read back in a test process (ExportModeWordingTests).
    static let modeLabel = "Mode:"
    static let fontCaption = "Font and size apply to Modern mode — RTF and PDF exports."

    private let model = BatchModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Batch Export"
        window.setAccessibilityIdentifier("batch-window")
        // Job 397 (Jon F9): `setFrameAutosaveName` alone only SAVES future moves/resizes — it
        // does not restore a prior frame, so the very first open (and any host with no saved
        // defaults) fell straight through to the literal (0, 0) screen-origin `contentRect`
        // above, the bottom-left-corner spawn bug. `setFrameUsingName` restores that saved
        // frame if one exists; `center()` (matching the Check for Updates `NSAlert`'s own
        // upper-third placement) is the fallback the first time there's nothing to restore.
        window.setFrameAutosaveName("BatchWindow")
        if !window.setFrameUsingName("BatchWindow") {
            window.center()
        }
        super.init(window: window)

        let root = BatchView(model: model, window: window)
        window.contentView = NSHostingView(rootView: root)
        window.registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
