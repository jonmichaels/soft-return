#if DEBUG
import AppKit

/// A floating readout of the accessibility identifier under the pointer.
///
/// The spec's "optional nicety", and it earns its place: the identifiers are the shared
/// vocabulary between the app, the mockups and the interface notes, so being able to point
/// at a control and read its name is what makes a note like "variant-control is too quiet"
/// possible without digging through source.
@MainActor
final class IdentifierHUD {
    static let shared = IdentifierHUD()

    private var panel: NSPanel?
    private var monitor: Any?

    private init() {}

    var isVisible: Bool { panel != nil }

    func toggle() { isVisible ? hide() : show() }

    private func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true

        let label = NSTextField(labelWithString: "—")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel

        // Local monitor only: this follows the pointer inside our own windows, and has no
        // business watching the rest of the system.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.update(label: label, panel: panel, event: event)
            return event
        }
        // Mouse-moved events only arrive if a window asks for them.
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
    }

    private func update(label: NSTextField, panel: NSPanel, event: NSEvent) {
        guard let window = event.window else { return }
        let point = event.locationInWindow
        var identifier: String?
        var view = window.contentView?.hitTest(point)
        while let current = view {
            let found = current.accessibilityIdentifier()
            if !found.isEmpty {
                identifier = found
                break
            }
            view = current.superview
        }
        label.stringValue = identifier ?? "—"

        // Sit just below-right of the pointer, in screen space.
        let screenPoint = window.convertPoint(toScreen: point)
        panel.setFrameOrigin(NSPoint(x: screenPoint.x + 14, y: screenPoint.y - 34))
    }

    private func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
#endif
