import AppKit
import Testing
@testable import SoftReturn

/// Job 537 (rulings 20-21): `SettingsStore.includeBetaVersions` (default OFF) and the
/// Option-revealed checkbox in `SettingsWindowController` — same "default value / real control
/// exists / round-trips" shape `FlagUISettingsTests` already pins for the b24/b33 rows, plus
/// the visibility rule that's new here.
///
/// Headless honesty: real `⌥` key state and live window redraw aren't observable from this
/// process. `SettingsWindowController.shouldShowBetaVersionsCheckbox` (the pure decision) and
/// `optionKeyHeldOverride` (the DI seam standing in for a real held `⌥`, the same shape
/// `quickLookDefaultsOverride` already uses for the app-group container) are exactly as deep as
/// a headless `Testing` suite can go — whether the checkbox actually appears/disappears under a
/// real held Option key, on a real screen, needs eyes on the running app.
@Suite @MainActor struct BetaVersionsSettingsTests {

    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "BetaVersionsSettingsTests.\(UUID().uuidString)")!)
    }

    private func throwawayQuickLookDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BetaVersionsSettingsTests.QL.\(UUID().uuidString)")!
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    // MARK: - SettingsStore: default off, persists

    @Test func includeBetaVersionsDefaultsToFalseOnAFreshStore() {
        #expect(throwawaySettings().includeBetaVersions == false)
    }

    @Test func includeBetaVersionsPersistsAcrossReload() {
        let name = "BetaVersionsSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        SettingsStore(defaults: defaults).includeBetaVersions = true
        #expect(SettingsStore(defaults: defaults).includeBetaVersions == true)
    }

    // MARK: - Pure visibility rule

    @Test func hiddenWhenPreferenceOffAndOptionNotHeld() {
        #expect(SettingsWindowController.shouldShowBetaVersionsCheckbox(
            preferenceOn: false, optionHeld: false) == false)
    }

    @Test func revealedByOptionWhilePreferenceOff() {
        #expect(SettingsWindowController.shouldShowBetaVersionsCheckbox(
            preferenceOn: false, optionHeld: true) == true)
    }

    @Test func shownUnconditionallyWhenPreferenceOnRegardlessOfOption() {
        #expect(SettingsWindowController.shouldShowBetaVersionsCheckbox(
            preferenceOn: true, optionHeld: false) == true)
        #expect(SettingsWindowController.shouldShowBetaVersionsCheckbox(
            preferenceOn: true, optionHeld: true) == true)
    }

    // MARK: - The real window: absent by default, present with the DI override, wiring round-trips

    @Test func checkboxAbsentByDefaultNeitherOptionNorPreference() throws {
        let controller = SettingsWindowController(
            settings: throwawaySettings(), quickLookDefaultsOverride: throwawayQuickLookDefaults(),
            optionKeyHeldOverride: false)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let checkbox = descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" }
        #expect(checkbox == nil, "the beta checkbox is in the view hierarchy with neither Option held nor the preference on")
    }

    @Test func checkboxPresentWhenOptionOverrideIsHeld() throws {
        let controller = SettingsWindowController(
            settings: throwawaySettings(), quickLookDefaultsOverride: throwawayQuickLookDefaults(),
            optionKeyHeldOverride: true)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let checkbox = try #require(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" })
        #expect(checkbox.state == .off, "preference is off, so the revealed checkbox should start unchecked")
        #expect(!(checkbox.accessibilityLabel() ?? "").isEmpty)
    }

    @Test func checkboxPresentWhenPreferenceIsOnEvenWithoutOptionHeld() throws {
        let settings = throwawaySettings()
        settings.includeBetaVersions = true
        let controller = SettingsWindowController(
            settings: settings, quickLookDefaultsOverride: throwawayQuickLookDefaults(),
            optionKeyHeldOverride: false)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let checkbox = try #require(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" })
        #expect(checkbox.state == .on)
    }

    @Test func showWindowReEvaluatesVisibilityRatherThanOnlyBuildForm() throws {
        // `AppDelegate` keeps one `SettingsWindowController` alive and reuses it across opens
        // (`showWindow(_:)` on the same instance) -- a construction-time-only check would never
        // see a later change. `optionKeyHeldOverride` is fixed per instance (can't be flipped
        // after `init`, deliberately -- see its own doc comment), so this drives the OTHER
        // input, the preference, on the SAME instance between two `showWindow(_:)` calls: if
        // visibility were only ever decided in `buildForm`, the second call would not react.
        let settings = throwawaySettings()
        let controller = SettingsWindowController(
            settings: settings, quickLookDefaultsOverride: throwawayQuickLookDefaults(),
            optionKeyHeldOverride: false)
        let content = try #require(controller.window?.contentView)

        controller.showWindow(nil)
        content.layoutSubtreeIfNeeded()
        #expect(!descendants(content).compactMap { $0 as? NSButton }
            .contains { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" },
            "hidden on first show: preference off, Option override off")

        settings.includeBetaVersions = true
        controller.showWindow(nil)
        content.layoutSubtreeIfNeeded()
        #expect(descendants(content).compactMap { $0 as? NSButton }
            .contains { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" },
            "showWindow(_:) did not re-evaluate visibility after the preference changed")

        settings.includeBetaVersions = false
        controller.showWindow(nil)
        content.layoutSubtreeIfNeeded()
        #expect(!descendants(content).compactMap { $0 as? NSButton }
            .contains { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" },
            "the row should be removed again once the preference goes back off (Option override still off)")
    }

    @Test func togglingTheCheckboxWritesThroughToTheStore() throws {
        let settings = throwawaySettings()
        let controller = SettingsWindowController(
            settings: settings, quickLookDefaultsOverride: throwawayQuickLookDefaults(),
            optionKeyHeldOverride: true)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let checkbox = try #require(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "include-beta-versions-checkbox" })
        checkbox.state = .on
        checkbox.sendAction(checkbox.action, to: checkbox.target)
        #expect(settings.includeBetaVersions == true)

        checkbox.state = .off
        checkbox.sendAction(checkbox.action, to: checkbox.target)
        #expect(settings.includeBetaVersions == false)
    }
}
