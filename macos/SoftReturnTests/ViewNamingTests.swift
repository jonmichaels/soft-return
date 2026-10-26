import AppKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// #271 M11 (batch 30, ruled 2026-09-14): Native, Printed and Modern are VIEWS wherever a person reads them. The
/// Settings window's "Starting View:" reads "Open at Launch:" with the choices Document Viewer and Batch Exporter, and
/// "Default Style:" reads "Default View:"; the document window's bottom-bar menu is headed View.
///
/// The controls behind the labels: the Open at Launch popup offers exactly the ruled choices, and both renamed
/// popups say what they are to VoiceOver.
@Suite(.serialized)
@MainActor
struct ViewNamingTests {
    private func controller() -> SettingsWindowController {
        SettingsWindowController(
            settings: SettingsStore(defaults: UserDefaults(suiteName: "ViewNaming.settings.\(UUID().uuidString)")!),
            quickLookDefaultsOverride: UserDefaults(suiteName: "ViewNaming.ql.\(UUID().uuidString)")!)
    }

    private func popup(_ identifier: String, in view: NSView) -> NSPopUpButton? {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == identifier }
    }

    @Test func settingsWindowSaysViewAndOpenAtLaunch() throws {
        let controller = controller()
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let openAtLaunch = try #require(popup("starting-view-control", in: content))
        #expect(openAtLaunch.itemTitles == ["Document Viewer", "Batch Exporter"])
        #expect(openAtLaunch.accessibilityLabel() == "Open at launch")
        let defaultView = try #require(popup("default-style-control", in: content))
        #expect(defaultView.itemTitles == ["Native", "Printed", "Modern"])
        #expect(defaultView.accessibilityLabel() == "Default view")
    }
}
