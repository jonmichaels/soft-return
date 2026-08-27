import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// QUICK LOOK MARGINS SETTING — job 315 (b19 items 10/11).
///
/// The bottom bar's "Use as Default for Quick Look" action item is gone
/// (`BottomBarHeaderTests`/`PopupSelectionWiringTests` cover its removal); this is where its
/// function landed — a real Settings pulldown, directly below Default Page Size, offering
/// the SAME vocabulary as the Margins popup and writing the SAME app-group key
/// `QuickLookPageSettingsPreference` already reads. Every test here injects an isolated
/// `UserDefaults` suite via `SettingsWindowController`'s own `quickLookDefaultsOverride`
/// seam — never the real `RC448RH3EN.softreturn` container — matching the discipline
/// `PageSettingsPickerTests` already holds every other caller of this type to.
@Suite struct QuickLookMarginsSettingTests {

    @MainActor
    private static func isolatedQuickLookDefaults() -> UserDefaults {
        UserDefaults(suiteName: "QuickLookMarginsSettingTests.ql.\(UUID().uuidString)")!
    }

    @MainActor
    private static func isolatedSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "QuickLookMarginsSettingTests.settings.\(UUID().uuidString)")!)
    }

    @MainActor
    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @MainActor
    private static func popup(_ identifier: String, in controller: SettingsWindowController) throws -> NSPopUpButton {
        let content = try #require(controller.window?.contentView, "settings window has no contentView")
        return try #require(
            descendants(content).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no popup with identifier \(identifier)")
    }

    // MARK: - Same vocabulary as the Margins popup

    @Test @MainActor func offersTheSameVocabularyAsTheBottomBarsMarginsPopup() throws {
        let controller = SettingsWindowController(
            settings: Self.isolatedSettings(), quickLookDefaultsOverride: Self.isolatedQuickLookDefaults())
        let popup = try Self.popup("quick-look-margins-control", in: controller)
        #expect(popup.itemTitles == DocumentOperations.PageSettingsPreset.marginsChoiceNames)
        #expect(popup.itemTitles == ["Embedded", "Factory", "Sawyer", "Modern"])
    }

    // MARK: - Placement: directly below Default Page Size

    @Test @MainActor func sitsDirectlyBelowDefaultPageSizeInTheForm() throws {
        let controller = SettingsWindowController(
            settings: Self.isolatedSettings(), quickLookDefaultsOverride: Self.isolatedQuickLookDefaults())
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let grid = try #require(Self.descendants(content).compactMap { $0 as? NSGridView }.first)

        func rowLabel(_ row: Int) -> String? {
            (grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?.stringValue
        }
        let pageSizeRow = try #require(
            (0..<grid.numberOfRows).first { rowLabel($0) == "Default Page Size:" },
            "no Default Page Size row found")
        #expect(rowLabel(pageSizeRow + 1) == "Quick Look Margins:",
                "Quick Look Margins does not sit directly below Default Page Size")
    }

    // MARK: - Default: whatever the app-group default currently holds

    @Test @MainActor func showsEmbeddedWhenNothingIsSet() throws {
        let controller = SettingsWindowController(
            settings: Self.isolatedSettings(), quickLookDefaultsOverride: Self.isolatedQuickLookDefaults())
        let popup = try Self.popup("quick-look-margins-control", in: controller)
        #expect(popup.titleOfSelectedItem == "Embedded")
    }

    @Test @MainActor func loadsWhateverThePreexistingAppGroupDefaultHolds() throws {
        let defaults = Self.isolatedQuickLookDefaults()
        QuickLookPageSettingsPreference.setDefault(.modern, defaults: defaults)
        let controller = SettingsWindowController(settings: Self.isolatedSettings(), quickLookDefaultsOverride: defaults)
        let popup = try Self.popup("quick-look-margins-control", in: controller)
        #expect(popup.titleOfSelectedItem == "Modern")
    }

    // MARK: - Wiring: the SAME app-group key the removed action item wrote

    @Test @MainActor func choosingAPresetWritesToTheAppGroupDefault() throws {
        let defaults = Self.isolatedQuickLookDefaults()
        let controller = SettingsWindowController(settings: Self.isolatedSettings(), quickLookDefaultsOverride: defaults)
        let popup = try Self.popup("quick-look-margins-control", in: controller)

        // The real dispatch path, not a direct method call — same technique
        // `PopupSelectionWiringTests` uses for the bottom bar's own popups.
        let menu = try #require(popup.menu)
        let index = try #require(menu.items.firstIndex { $0.title == "Sawyer" })
        menu.performActionForItem(at: index)

        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == .sawyer)
    }

    @Test @MainActor func choosingEmbeddedClearsTheStoredDefault() throws {
        let defaults = Self.isolatedQuickLookDefaults()
        QuickLookPageSettingsPreference.setDefault(.modern, defaults: defaults)
        let controller = SettingsWindowController(settings: Self.isolatedSettings(), quickLookDefaultsOverride: defaults)
        let popup = try Self.popup("quick-look-margins-control", in: controller)

        let menu = try #require(popup.menu)
        let index = try #require(menu.items.firstIndex { $0.title == "Embedded" })
        menu.performActionForItem(at: index)

        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == nil,
                "choosing Embedded again must clear the stored default, not merely leave it stale")
    }

    /// The bare production initializer must still compile and run without ever being handed
    /// an override — the whole point of the seam is that a real launch takes the `nil`
    /// branch (the real container) automatically, not that a caller has to opt into it.
    @Test @MainActor func productionInitializerNeedsNoOverride() throws {
        let controller = SettingsWindowController(settings: Self.isolatedSettings())
        let popup = try Self.popup("quick-look-margins-control", in: controller)
        #expect(!popup.itemTitles.isEmpty)
    }
}
