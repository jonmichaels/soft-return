#if DEBUG
import AppKit

/// Debug ▸ Send Note… — the interface-notes loop back to the design site.
///
/// Captures the frontmost window as a PNG, takes one line of comment, and POSTs both to the
/// same receiver the design site's annotation tool uses. DEBUG builds only: this is a
/// build-time channel between Jon and whoever is working on the app, not a product feature.
///
/// The accessibility identifiers are the shared vocabulary here — a note that says
/// "variant-control is too quiet" names the same thing in the app, in the mockups, and in
/// the spec. That is why they are stable, LEGEND-style names rather than incidental.
@MainActor
enum InterfaceNoteSender {
    /// The receiver that mints note IDs. There is NO default and no hardcoded host: the
    /// endpoint is purely local developer configuration, because a review server lives on a
    /// private network and private infrastructure names never enter source code — DEBUG
    /// paths included. Set it either way:
    ///
    ///     defaults write me.beforeti.softreturn InterfaceNoteEndpoint https://…/api/notes
    ///     SOFT_RETURN_NOTE_ENDPOINT=https://…/api/notes   (environment, wins if both set)
    ///
    /// Unset means the menu item is disabled and says why. Nothing is committed either way.
    nonisolated static let endpointDefaultsKey = "InterfaceNoteEndpoint"
    nonisolated static let endpointEnvironmentKey = "SOFT_RETURN_NOTE_ENDPOINT"

    /// nonisolated: menu construction reads this, and both sources are thread-safe reads.
    nonisolated static var endpoint: URL? {
        let raw = ProcessInfo.processInfo.environment[endpointEnvironmentKey]
            ?? UserDefaults.standard.string(forKey: endpointDefaultsKey)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Why the menu item is disabled, in the item's own tooltip.
    nonisolated static var unconfiguredReason: String {
        "Set a review endpoint first: defaults write me.beforeti.softreturn "
            + "\(endpointDefaultsKey) <url>, or the \(endpointEnvironmentKey) environment "
            + "variable. Local configuration only — nothing is stored in the repo."
    }

    static func presentComposer() {
        guard let endpoint else {
            present(message: "No review endpoint configured.",
                    informative: unconfiguredReason, style: .warning)
            return
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            present(message: "No window to capture.", style: .warning)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Send an interface note"
        alert.informativeText = "A screenshot of “\(window.title)” goes with it."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "What’s wrong, in one line"
        field.setAccessibilityIdentifier("debug-note-field")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        send(note: text, window: window, to: endpoint)
    }

    private static func send(note: String, window: NSWindow, to endpoint: URL) {
        let png = capture(window)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "SoftReturnNote-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("text", note)
        field("source", "Soft Return.app")
        field("window", window.title)
        if let identifier = identifierUnderCursor(in: window) {
            field("identifier", identifier)
        }
        if let png {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"window.png\"\r\n"
                .data(using: .utf8)!)
            body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
            body.append(png)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let failure = error?.localizedDescription
            Task { @MainActor in
                if let failure {
                    present(message: "Couldn’t send the note.", informative: failure,
                            style: .warning)
                    return
                }
                guard (200..<300).contains(code) else {
                    present(message: "The receiver rejected the note (HTTP \(code)).",
                            informative: bodyText, style: .warning)
                    return
                }
                present(message: "Note sent.", informative: bodyText, style: .informational)
            }
        }.resume()
    }

    /// The window's own pixels, without the shadow or anything behind it.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Cheap extra context: which control the pointer is over, by accessibility identifier.
    private static func identifierUnderCursor(in window: NSWindow) -> String? {
        let point = window.mouseLocationOutsideOfEventStream
        guard let hit = window.contentView?.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view {
            let identifier = current.accessibilityIdentifier()
            if !identifier.isEmpty { return identifier }
            view = current.superview
        }
        return nil
    }

    private static func present(message: String, informative: String = "",
                                style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
