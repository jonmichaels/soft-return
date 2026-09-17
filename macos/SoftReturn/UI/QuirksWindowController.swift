import AppKit
import CtrlKD
import SoftReturnShared

/// Batch 46 (Jon's quirks rulings, 2026-09-16; canvas v3 MacDocQuirks, MacQuirksDefaults): the engine's quirks as
/// checkboxes, in two windows.
///
/// - View ▸ Quirks… (⌥⌘K — ⌥⌘Q is the system's Quit and Keep Windows), one per document window, 640 × 470: the quirks
///   this document trips, each its name and the engine's one-line description, marked Overridden where the document's
///   own choice differs from the app's default; Use App Defaults, App Default Settings… and Done.
/// - Settings ▸ Quirks…, the app's defaults, 560 × 500: Auto | All | Off | Custom over all six, and Done. Auto is what
///   shipped; Custom is selected only when the checkboxes match nothing else, and choosing it changes nothing.
///
/// Each checkbox applies at once: the document re-renders under the new set.
final class QuirksWindowController: NSWindowController, NSWindowDelegate {
    enum Scope {
        case app(SettingsStore)
        case document(DocumentWindowController)
    }

    static let documentContentSize = NSSize(width: 640, height: 470)
    static let appContentSize = NSSize(width: 560, height: 500)

    /// The one app-defaults window, whichever button opened it.
    private static var appDefaults: QuirksWindowController?

    static func showAppDefaults(settings: SettingsStore = .shared, sender: Any?) {
        let controller = appDefaults ?? QuirksWindowController(scope: .app(settings))
        appDefaults = controller
        controller.reload()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    let scope: Scope
    let presetControl = NSSegmentedControl(labels: QuirkChoices.Preset.allCases.map(\.displayName),
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let rows = NSStackView()
    private(set) var checkboxes: [String: NSButton] = [:]
    private(set) var overriddenLabels: [String: NSTextField] = [:]

    init(scope: Scope) {
        self.scope = scope
        let size: NSSize
        if case .document = scope { size = Self.documentContentSize } else { size = Self.appContentSize }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        switch scope {
        case .app:
            window.title = "Quirks"
            window.setAccessibilityIdentifier("quirks-defaults-window")
        case .document(let controller):
            window.title = "\((controller.document as? NSDocument)?.displayName ?? "Untitled") — Quirks"
            window.setAccessibilityIdentifier("quirks-document-window")
        }
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(quirkDefaultsChanged),
                                               name: SettingsStore.quirkDefaultsDidChange, object: nil)
        reload()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func quirkDefaultsChanged() { reload() }

    private var settings: SettingsStore {
        switch scope {
        case .app(let settings): return settings
        case .document(let controller): return controller.settings
        }
    }

    private var documentController: DocumentWindowController? {
        if case .document(let controller) = scope { return controller }
        return nil
    }

    /// The rows: every quirk for the app's defaults; for a document, the ones it trips.
    var names: [String] {
        guard let documentController else { return QuirkChoices.names }
        return documentController.documentState.applicableQuirks.map(\.name)
    }

    var choices: QuirkChoices {
        documentController?.documentState.quirkChoices ?? settings.quirkDefaults
    }

    // MARK: - Building

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        if documentController == nil {
            presetControl.target = self
            presetControl.action = #selector(presetChosen(_:))
            presetControl.setAccessibilityIdentifier("quirks-preset-control")
            presetControl.setAccessibilityLabel("Quirks")
            stack.addArrangedSubview(presetControl)
        }

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .textBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        box.contentView = rows
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)

        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("quirks-done")
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        if documentController != nil {
            let useDefaults = NSButton(title: "Use App Defaults", target: self, action: #selector(useAppDefaults(_:)))
            useDefaults.setAccessibilityIdentifier("quirks-use-app-defaults")
            let appDefaults = NSButton(title: "App Default Settings…", target: self, action: #selector(showAppDefaults(_:)))
            appDefaults.setAccessibilityIdentifier("quirks-app-default-settings")
            buttons.addArrangedSubview(useDefaults)
            buttons.addArrangedSubview(appDefaults)
        }
        let flexible = NSView()
        flexible.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.addArrangedSubview(flexible)
        buttons.addArrangedSubview(done)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    /// One row: the checkbox, then the quirk's name in semibold over its description.
    private func makeRow(_ name: String, last: Bool) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(quirkToggled(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(name)
        checkbox.setAccessibilityIdentifier("quirks-checkbox-\(name)")
        checkbox.setAccessibilityLabel(QuirkChoices.title(of: name))
        checkboxes[name] = checkbox

        let title = NSTextField(labelWithString: QuirkChoices.title(of: name))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: QuirkChoices.description(of: name))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let overridden = NSTextField(labelWithString: "Overridden")
        overridden.font = .systemFont(ofSize: 11)
        overridden.textColor = .secondaryLabelColor
        overridden.setAccessibilityIdentifier("quirks-overridden-\(name)")
        overriddenLabels[name] = overridden
        let text = NSStackView(views: [title, detail, overridden])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [checkbox, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        row.setAccessibilityIdentifier("quirks-row-\(name)")
        let container = NSStackView(views: [row])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        // The row spans the box, so its checkbox sits at the leading edge rather than centred (b46-qm-mac2's proof).
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        if !last {
            let rule = NSBox()
            rule.boxType = .separator
            container.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        return container
    }

    // MARK: - State

    func reload() {
        let names = self.names
        if Set(checkboxes.keys) != Set(names) || rows.arrangedSubviews.isEmpty {
            rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
            checkboxes = [:]
            overriddenLabels = [:]
            if names.isEmpty {
                let none = NSTextField(labelWithString: "No quirks apply to this document.")
                none.textColor = .secondaryLabelColor
                none.setAccessibilityIdentifier("quirks-none")
                let pad = NSStackView(views: [none])
                pad.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
                rows.addArrangedSubview(pad)
            }
            for (index, name) in names.enumerated() {
                let row = makeRow(name, last: index == names.count - 1)
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
        let choices = self.choices
        for name in names {
            checkboxes[name]?.state = choices.isOn(name) ? .on : .off
            overriddenLabels[name]?.isHidden = !(documentController?.documentState.isQuirkOverridden(name) ?? false)
        }
        presetControl.selectedSegment = QuirkChoices.Preset.allCases.firstIndex(of: choices.preset) ?? 0
    }

    @objc func quirkToggled(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        if let documentController {
            documentController.setQuirk(name, on: on)
        } else {
            var defaults = settings.quirkDefaults
            defaults.set(name, on: on)
            settings.quirkDefaults = defaults
        }
        reload()
    }

    @objc func presetChosen(_ sender: NSSegmentedControl) {
        let preset = QuirkChoices.Preset.allCases[sender.selectedSegment]
        // Custom is where the checkboxes already are, not a set of its own.
        if let chosen = preset.choices { settings.quirkDefaults = chosen }
        reload()
    }

    @objc func useAppDefaults(_ sender: Any?) {
        documentController?.useAppDefaultQuirks()
        reload()
    }

    @objc func showAppDefaults(_ sender: Any?) {
        Self.showAppDefaults(settings: settings, sender: sender)
    }

    @objc func done(_ sender: Any?) {
        close()
    }
}
