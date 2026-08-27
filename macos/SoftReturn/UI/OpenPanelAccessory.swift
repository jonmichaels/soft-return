import AppKit
import CtrlKD

/// The ⌘O panel's accessory: a Variant popup that filters which files are selectable.
///
/// The panel is the real `NSOpenPanel` — this only rides along in its accessory slot and
/// answers `panel(_:shouldEnable:)`. "All files visible, convertibles selectable, others
/// disabled" is the spec's rule, and it is a filtering decision, not a panel we drew.
final class OpenPanelAccessory: NSView, NSOpenSavePanelDelegate {
    /// Called when the popup changes, so the panel can re-ask about every visible row.
    var onChange: (() -> Void)?

    /// nil == Auto: every convertible type is selectable.
    private var filter: Variant?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Extensions WordStar itself wrote, plus the two plain-text shapes. A file with NO
    /// extension is the common case on a 1987 floppy and is always allowed through — the
    /// detector, not the filename, decides what it really is.
    private static let convertibleExtensions: Set<String> = [
        "ws", "ws1", "ws2", "ws3", "ws4", "ws5", "ws6", "ws7", "ws8", "ws9",
        "txt", "doc", "asc", "prn",
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        setAccessibilityIdentifier("open-panel-accessory")

        let label = NSTextField(labelWithString: "Variant:")
        label.alignment = .right
        label.setAccessibilityIdentifier("open-panel-variant-label")

        popup.setAccessibilityIdentifier("open-panel-variant-control")
        popup.setAccessibilityLabel("Variant filter")
        popup.target = self
        popup.action = #selector(filterChanged(_:))
        for (title, variant) in Self.choices {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = variant
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: 0)

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let choices: [(String, Variant?)] = [
        ("Auto", nil),
        ("WordStar 4", .ws4),
        ("WordStar 5+", .ws5plus),
        ("Print Stream", .printstream),
        ("Plain Text", .text),
    ]

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        filter = sender.selectedItem?.representedObject as? Variant
        onChange?()
    }

    // MARK: - NSOpenSavePanelDelegate

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        // Directories stay navigable whatever the filter says.
        if isDirectory.boolValue { return true }

        let ext = url.pathExtension.lowercased()
        let plausible = ext.isEmpty || Self.convertibleExtensions.contains(ext)
        guard plausible else { return false }

        // With a specific variant chosen, the bytes have to agree — this is the only
        // honest way to filter, since names and extensions lie about these files and the
        // detector is the library's whole first chapter.
        guard let filter else { return true }
        // Best-effort content sniff for an open-panel row: a file the panel cannot even read
        // a prefix of is not selectable under this filter either way, so it is disabled the
        // same as a genuine mismatch — no alert belongs on a row the user hasn't chosen yet.
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        // A prefix is enough: `detect` reads counts and ratios, and reading a whole
        // multi-megabyte file per row would make the panel crawl.
        let sample = [UInt8](data.prefix(64 * 1024))
        return detect(sample).variant == filter
    }
}
