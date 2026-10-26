import AppKit

/// The app's alerts: a message, its explanation and its buttons, as a sheet on `window`, or a modal panel when there
/// is none. `completion` gets the button chosen (`.alertFirstButtonReturn` for the first); `accessory` sits under the
/// text and takes the keyboard first (the field the Go to Page and interface-note alerts ask for).
@MainActor
enum Alert {
    static func show(_ message: String, informative: String = "", style: NSAlert.Style = .warning,
                     buttons: [String] = ["OK"], accessory: NSView? = nil, in window: NSWindow?,
                     completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = style
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        if let accessory {
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = accessory
        }
        if let window {
            alert.beginSheetModal(for: window) { completion?($0) }
        } else {
            completion?(alert.runModal())
        }
    }
}
