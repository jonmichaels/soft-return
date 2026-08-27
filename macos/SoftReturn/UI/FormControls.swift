import AppKit

/// The "Settings form idiom" — a fixed-width `NSPopUpButton` plus a right-aligned label —
/// factored out (job 531) after `SettingsWindowController.popup(_:_:_:_:)`/`.label(_:)` and
/// `ExportAccessoryView.makePopup`/`.makeLabel` had each re-derived the identical five lines
/// (job 530's own doc comments on those methods already said "same shape as
/// `SettingsWindowController`..."). `BatchWindowController`'s `BatchPopUpButton` is NOT
/// folded in here: it is a SwiftUI `NSViewRepresentable` wrapper (Batch's window is SwiftUI,
/// not plain AppKit), a different construction shape, not a duplicate of this one.
enum FormControl {
    static func popUpButton(
        titles: [String], identifier: String, accessibilityLabel: String, width: CGFloat,
        target: AnyObject? = nil, action: Selector? = nil
    ) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.target = target
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    static func rightAlignedLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }
}
