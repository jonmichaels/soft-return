import AppKit

/// Keeps text-AUTHORING commands out of the Edit menu.
///
/// macOS injects several commands into any menu it identifies as the Edit menu, without
/// being asked and after the menu has been built: Start Dictation, Emoji & Symbols, Writing
/// Tools, AutoFill. Every one of them exists to put text into, or rewrite text inside, an
/// editable document.
///
/// This app has no editable document. Its text views are `isEditable = false` and the spec
/// is explicit that it is a viewer — "Text selectable, never editable". Offering Writing
/// Tools on a 1987 file the author cannot be consulted about is worse than inert; it invites
/// an operation the app will not perform.
///
/// Two of the four have documented opt-outs (`NSDisabledDictationMenuItem`,
/// `NSDisabledCharacterPaletteMenuItem`, registered in `AppDelegate`). Writing Tools and
/// AutoFill do not — they are inserted with private identifiers
/// (`__NSTextViewContextSubmenuIdentifierWritingTools`, `_NSMenuItemAutoFillIdentifier`), so
/// the only reliable removal point is just before the menu is displayed.
///
/// Matching is on the IDENTIFIER, not the title: titles are localised and would break in
/// every language but English. It is a loose contains-match rather than an exact one,
/// because the underscore prefixes on those identifiers are private and have churned
/// between releases. If Apple renames them outright the items reappear — a cosmetic
/// regression, visible immediately, and not a crash.
@MainActor
final class EditMenuGuard: NSObject, NSMenuDelegate {
    /// Retained by the app delegate for the process's lifetime; `NSMenu.delegate` is weak.
    static let shared = EditMenuGuard()

    /// Substrings that mark an injected authoring command.
    private static let unwantedIdentifierFragments = [
        "writingtools",
        "autofill",
    ]

    /// Attach to the Edit menu. Safe to call once, at launch.
    func attach(to mainMenu: NSMenu) {
        guard let edit = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu else { return }
        edit.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let doomed = menu.items.filter { item in
            guard let identifier = item.identifier?.rawValue.lowercased() else { return false }
            return Self.unwantedIdentifierFragments.contains { identifier.contains($0) }
        }
        for item in doomed { menu.removeItem(item) }

        // The injected items arrive after a separator of their own, which is left dangling
        // once they go. Drop any trailing separator so the menu does not end in a rule.
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
