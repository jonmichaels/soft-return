import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 373 (b24 FLAG UI): `SettingsStore`'s four new defaults (Headers/Footers, Table of
/// Contents, Inline Styling, Pictures) and their row in `SettingsWindowController` — the
/// same "default value / persists across reload / real control exists" shape
/// `WindowRestorationTests` already pins for `restoreWindowsOnLaunch`.
///
/// Job 520 (N5, b33 page-numbering UI): a fifth default, `defaultPageNumbers`
/// (`EmitOptions.PageNumberMode`, ruled default `.auto`), joins the four above — same shape,
/// same tests extended rather than duplicated into a second suite.
@Suite @MainActor struct FlagUISettingsTests {

    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "FlagUISettingsTests.\(UUID().uuidString)")!)
    }

    // MARK: - Ruled defaults (brief item 2: headers ON, TOC OFF, Pictures Embed, inline ON)

    @Test func ruledDefaultsOnAFreshStore() {
        let settings = throwawaySettings()
        #expect(settings.defaultHeaders == true)
        #expect(settings.defaultTOC == false)
        #expect(settings.defaultInlineStyling == true)
        #expect(settings.defaultPictures == .embed)
        #expect(settings.defaultPageNumbers == .auto)
    }

    // MARK: - Persist across reload (same UserDefaults suite, a fresh SettingsStore instance)

    @Test func eachDefaultPersistsAcrossReload() {
        let name = "FlagUISettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        SettingsStore(defaults: defaults).defaultHeaders = false
        #expect(SettingsStore(defaults: defaults).defaultHeaders == false)

        SettingsStore(defaults: defaults).defaultTOC = true
        #expect(SettingsStore(defaults: defaults).defaultTOC == true)

        SettingsStore(defaults: defaults).defaultInlineStyling = false
        #expect(SettingsStore(defaults: defaults).defaultInlineStyling == false)

        SettingsStore(defaults: defaults).defaultPictures = .export
        #expect(SettingsStore(defaults: defaults).defaultPictures == .export)

        SettingsStore(defaults: defaults).defaultPageNumbers = .on
        #expect(SettingsStore(defaults: defaults).defaultPageNumbers == .on)
    }

    // MARK: - The real Settings window: controls exist, are labelled, and round-trip

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @Test func settingsWindowExposesAllFourControls() throws {
        let controller = SettingsWindowController(settings: throwawaySettings())
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)

        let headers = try #require(
            views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "default-headers-checkbox" })
        let toc = try #require(
            views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "default-toc-checkbox" })
        let inlineStyling = try #require(
            views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "default-inline-styling-checkbox" })
        let pictures = try #require(
            views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "default-pictures-control" })
        let pageNumbers = try #require(
            views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "default-page-numbers-control" })

        #expect(headers.state == .on, "ruled default: headers ON")
        #expect(toc.state == .off, "ruled default: TOC OFF")
        #expect(inlineStyling.state == .on, "ruled default: inline styling ON")
        #expect(pictures.titleOfSelectedItem == "Embed", "ruled default: Pictures Embed")
        #expect(pageNumbers.titleOfSelectedItem == "Auto", "ruled default: Page Numbering Auto")

        for control in [headers, toc, inlineStyling] as [NSButton] {
            #expect(!(control.accessibilityLabel() ?? "").isEmpty)
        }
        #expect(!(pictures.accessibilityLabel() ?? "").isEmpty)
        #expect(!(pageNumbers.accessibilityLabel() ?? "").isEmpty)
    }

    @Test func togglingASettingsWindowControlWritesThroughToTheStore() throws {
        let settings = throwawaySettings()
        let controller = SettingsWindowController(settings: settings)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let headers = try #require(
            descendants(content).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "default-headers-checkbox" })
        headers.state = .off
        headers.sendAction(headers.action, to: headers.target)
        #expect(settings.defaultHeaders == false)

        let toc = try #require(
            descendants(content).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "default-toc-checkbox" })
        toc.state = .on
        toc.sendAction(toc.action, to: toc.target)
        #expect(settings.defaultTOC == true)

        let pictures = try #require(
            descendants(content).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "default-pictures-control" })
        pictures.selectItem(withTitle: "Off")
        pictures.sendAction(pictures.action, to: pictures.target)
        #expect(settings.defaultPictures == .off)

        let pageNumbers = try #require(
            descendants(content).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "default-page-numbers-control" })
        pageNumbers.selectItem(withTitle: "On")
        pageNumbers.sendAction(pageNumbers.action, to: pageNumbers.target)
        #expect(settings.defaultPageNumbers == .on)
    }
}
