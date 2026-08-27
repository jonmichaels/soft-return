import AppKit

/// Job 276: shown while `AppDelegate` downloads a release DMG. No determinate-progress
/// affordance existed anywhere else in this app to reuse (the batch window's per-row indicator
/// is an indeterminate `ProgressView` spinner, not a fraction-driven bar — see
/// `BatchWindowController`), so per the brief this is the fallback it names: "a simple
/// indeterminate spinner alert with Cancel."
@MainActor
final class DownloadProgressWindowController: NSWindowController {
    private let progressIndicator = NSProgressIndicator()
    var onCancel: (() -> Void)?

    init(assetName: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.title = "Downloading Update"
        window.setAccessibilityIdentifier("download-progress-window")
        super.init(window: window)
        buildContent(assetName: assetName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(assetName: String) {
        guard let window else { return }

        let label = NSTextField(labelWithString: "Downloading \(assetName)…")
        label.setAccessibilityIdentifier("download-progress-label")

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.setAccessibilityIdentifier("download-progress-indicator")
        progressIndicator.startAnimation(nil)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.setAccessibilityIdentifier("download-progress-cancel-button")

        let stack = NSStackView(views: [label, progressIndicator, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
        // Job 397 (Jon F9): fixes the bottom-left-corner spawn — see
        // `AboutWindowController.buildContent`'s comment on the same call. A transient
        // progress window, same treatment as the Check for Updates `NSAlert` it stands in for.
        window.center()
    }

    @objc private func cancelTapped() {
        onCancel?()
        close()
    }
}
