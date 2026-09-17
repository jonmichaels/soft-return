import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 46 (Jon's quirks rulings, 2026-09-16; canvas v3 MacDocQuirks, MacQuirksDefaults, MacSettings).
/// - View ▸ Quirks… (⌥⌘K: ⌥⌘Q is the system's Quit and Keep Windows) opens this document's Quirks window, 640 × 470:
///   the quirks it trips, Overridden where its own choice differs from the app's default, Use App Defaults, App Default
///   Settings… and Done. A checkbox re-renders the document.
/// - Settings has a centred, unlabelled Quirks… button, a popup wide, under the popups; it opens the app-defaults
///   window, 560 × 500: Auto | All | Off | Custom over all six, and Done.
/// - Quick Look reads the app's default quirks from the app group.
/// Proofs: quirks-document-<light|dark>.png, quirks-defaults-<light|dark>.png, quirks-settings-light.png.
@Suite("Quirks windows (batch 46)", .serialized)
@MainActor
struct QuirksWindowTests {
    static func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "QuirksWindowTests.\(UUID().uuidString)")!)
    }

    /// LJ6DTP in the header and a paragraph style that strikes with no cross-out typed: all six quirks apply.
    static func quirkyState(settings: SettingsStore) -> DocumentState {
        var document = CtrlKD.Document()
        document.printerDriver = "LJ6DTP"
        var heading = Block(kind: .para, lines: [Line(spans: [Span(text: "A heading its style strikes through")])])
        heading.styleAttrs.insert(.strike)
        document.blocks = [heading, Block(kind: .para, lines: [Line(spans: [Span(text: "The paragraph after it.")])])]
        return DocumentState(document: document, settings: settings)
    }

    static var proofs: URL {
        RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
    }

    static func render(_ controller: NSWindowController, _ name: String, dark: Bool) throws {
        let content = try #require(controller.window?.contentView)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        controller.window?.appearance = appearance
        content.layoutSubtreeIfNeeded()
        // Redraw everything under this appearance first.
        for view in [content] + RenderProbeKit.descendants(content) { view.needsDisplay = true }
        content.displayIfNeeded()
        let png = proofs.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        #expect(try RenderProbeKit.renderPNG(view: content, appearance: appearance, to: png) > 0)
        print("PROOF: \(png.path)")
    }

    @Test func viewMenuHasQuirksOnOptionCommandK() throws {
        let menu = MainMenu.build()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let quirks = try #require(items.first { $0.action == #selector(DocumentWindowController.showQuirks(_:)) })
        #expect(quirks.title == "Quirks…")
        #expect(quirks.keyEquivalent == "k" && quirks.keyEquivalentModifierMask == [.command, .option])
        let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
        #expect(view.items.contains(quirks))
        // Nothing else in the menu bar takes ⌥⌘K, and nothing is on ⌥⌘Q, Quit and Keep Windows.
        let optionCommand = items.filter { $0.keyEquivalentModifierMask == [.command, .option] }
        #expect(optionCommand.filter { $0.keyEquivalent == "k" }.count == 1)
        #expect(!optionCommand.contains { $0.keyEquivalent == "q" })
    }

    @Test(arguments: [false, true])
    func documentWindowListsTheDocumentsQuirksAndReRenders(dark: Bool) throws {
        let settings = Self.throwawaySettings()
        let state = Self.quirkyState(settings: settings)
        let document = DocumentWindowController(state: state, settings: settings)
        document.showWindow(nil)
        defer { document.close() }
        document.quirksWindowController = QuirksWindowController(scope: .document(document))
        // Dark from before the window first draws. Even so, `cacheDisplay` draws the push buttons and the segmented
        // control blank in dark (b46-qm-mac3, -mac4) while the box, labels and checkboxes render dark: a limit of this
        // capture, which a real screenshot (Screen Recording) would settle.
        document.quirksWindowController?.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        document.showQuirks(nil)
        let quirks = try #require(document.quirksWindowController)
        defer { quirks.close() }
        let window = try #require(quirks.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == QuirksWindowController.documentContentSize)
        #expect(window.title.hasSuffix("— Quirks"))
        #expect(quirks.names == QuirkChoices.names)
        #expect(quirks.presetControl.superview == nil, "a document's window has no Auto | All | Off | Custom")
        let content = try #require(window.contentView)
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
        #expect(Set(buttons.map(\.title)) == ["Use App Defaults", "App Default Settings…", "Done"])
        let titles = RenderProbeKit.descendants(content).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(titles.contains("Euro swap") && titles.contains("Ignore a strikeout set only by a style"))

        let stray = try #require(quirks.checkboxes[QuirkName.sawyerStrikeout])
        #expect(stray.state == .off && quirks.checkboxes[QuirkName.euroSwap]?.state == .on)
        // Each checkbox at the box's leading edge, the canvas's 16 pt in, not centred.
        for (name, checkbox) in quirks.checkboxes {
            let box = try #require(checkbox.superview?.superview?.superview)
            let x = checkbox.convert(checkbox.bounds, to: box).minX
            #expect(x < 24, "\(name)'s checkbox is \(x) pt in")
        }
        #expect(quirks.overriddenLabels[QuirkName.sawyerStrikeout]?.isHidden == true)
        stray.performClick(nil)
        #expect(state.quirkOverrides == [QuirkName.sawyerStrikeout: true])
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == false)
        #expect(settings.quirkDefaults == .shipped)
        #expect(quirks.overriddenLabels[QuirkName.sawyerStrikeout]?.isHidden == false)
        try Self.render(quirks, "quirks-document", dark: dark)

        // The app's defaults move under it; the document's own choice stays.
        settings.quirkDefaults = .off
        #expect(state.document.quirks?.applied == [QuirkName.sawyerStrikeout])
        #expect(quirks.checkboxes[QuirkName.euroSwap]?.state == .off)

        let useDefaults = try #require(buttons.first { $0.title == "Use App Defaults" })
        useDefaults.performClick(nil)
        #expect(state.quirkOverrides.isEmpty)
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == true)
        #expect(stray.state == .off)
    }

    @Test(arguments: [false, true])
    func appDefaultsWindowHasThePresetsAndCustom(dark: Bool) throws {
        let settings = Self.throwawaySettings()
        let defaults = QuirksWindowController(scope: .app(settings))
        defaults.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defaults.showWindow(nil)
        defer { defaults.close() }
        let window = try #require(defaults.window)
        #expect(window.title == "Quirks")
        #expect(window.contentRect(forFrameRect: window.frame).size == QuirksWindowController.appContentSize)
        #expect(defaults.names == QuirkChoices.names)
        #expect((0..<4).map { defaults.presetControl.label(forSegment: $0) } == ["Auto", "All", "Off", "Custom"])
        #expect(defaults.presetControl.selectedSegment == 0)
        try Self.render(defaults, "quirks-defaults", dark: dark)

        defaults.presetControl.selectedSegment = 1
        defaults.presetChosen(defaults.presetControl)
        #expect(settings.quirkDefaults == .all)
        defaults.presetControl.selectedSegment = 0
        defaults.presetChosen(defaults.presetControl)
        #expect(settings.quirkDefaults == .shipped)
        try #require(defaults.checkboxes[QuirkName.boxCorners]).performClick(nil)
        #expect(settings.quirkDefaults.preset == .custom)
        #expect(defaults.presetControl.selectedSegment == 3)
        let custom = settings.quirkDefaults
        defaults.presetChosen(defaults.presetControl)
        #expect(settings.quirkDefaults == custom, "choosing Custom changed the switches")
        if !dark { try Self.render(defaults, "quirks-defaults-custom", dark: false) }
    }

    @Test func settingsHasACentredQuirksButton() throws {
        let settings = Self.throwawaySettings()
        let controller = SettingsWindowController(
            settings: settings,
            quickLookDefaultsOverride: UserDefaults(suiteName: "QuirksWindowTests.QL.\(UUID().uuidString)")!)
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let button = try #require(RenderProbeKit.descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "settings-quirks-button" })
        #expect(button.title == "Quirks…")
        // The layout width, not the frame: a push button's frame carries its bezel's shadow insets.
        #expect(abs(button.alignmentRect(forFrame: button.frame).width - SettingsWindowController.popupWidth) < 0.5)
        #expect(abs(button.frame.midX - content.bounds.midX) < 1, "Quirks… is not centred: \(button.frame) in \(content.bounds)")
        // Under the popups, above the separator; no label beside it.
        let separator = try #require(content.subviews.first { ($0 as? NSBox)?.boxType == .separator })
        let grid = try #require(content.subviews.first { $0 is NSGridView })
        #expect(button.frame.minY > separator.frame.maxY && button.frame.maxY < grid.frame.minY)
        let labelsBeside = RenderProbeKit.descendants(content).compactMap { $0 as? NSTextField }
            .filter { abs($0.frame.midY - button.frame.midY) < 4 && $0.superview === content }
        #expect(labelsBeside.isEmpty)
        try Self.render(controller, "quirks-settings", dark: false)
    }

    /// Jon's option 2: the document's own choice is kept by the app, keyed to the file — back when it opens again, and
    /// after a rename — and the file's bytes never change.
    @Test func aDocumentsOwnChoiceSurvivesReopeningAndARename() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("QuirksWindowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = try BundledSampleFixture.copy("LYING.WS", into: scratch)
        let bytes = try Data(contentsOf: url)
        defer { QuirkOverrideStore.shared.setOverrides([:], for: url) }

        let first = try WSDocument(contentsOf: url, ofType: "public.data")
        let controller = DocumentWindowController(state: try #require(first.state), settings: Self.throwawaySettings())
        first.addWindowController(controller)
        controller.setQuirk(QuirkName.euroSwap, on: false)
        #expect(QuirkOverrideStore.shared.overrides(for: url) == [QuirkName.euroSwap: false])
        first.close()

        let again = try WSDocument(contentsOf: url, ofType: "public.data")
        #expect(again.state?.quirkOverrides == [QuirkName.euroSwap: false])
        #expect(again.state?.quirkChoices.isOn(QuirkName.euroSwap) == false)
        #expect(try Data(contentsOf: url) == bytes, "the document was written")
        again.close()

        let renamed = scratch.appendingPathComponent("LYING-RENAMED.WS")
        try FileManager.default.moveItem(at: url, to: renamed)
        defer { QuirkOverrideStore.shared.setOverrides([:], for: renamed) }
        let moved = try WSDocument(contentsOf: renamed, ofType: "public.data")
        #expect(moved.state?.quirkOverrides == [QuirkName.euroSwap: false])
        let movedController = DocumentWindowController(state: try #require(moved.state), settings: Self.throwawaySettings())
        moved.addWindowController(movedController)
        movedController.useAppDefaultQuirks()
        #expect(QuirkOverrideStore.shared.overrides(for: renamed).isEmpty)
        moved.close()
    }

    @Test func quickLookReadsTheAppsDefaultQuirks() throws {
        let suite = "QuirksWindowTests.group.\(UUID().uuidString)"
        let group = try #require(UserDefaults(suiteName: suite))
        defer { group.removePersistentDomain(forName: suite) }
        #expect(QuickLookPageSettingsPreference.resolvedQuirkDefaults(defaults: group) == .shipped)
        #expect(QuickLookPageSettingsPreference.resolvedQuirkDefaults(defaults: nil) == .shipped)
        QuickLookPageSettingsPreference.setQuirkDefaults(.off, defaults: group)
        #expect(QuickLookPageSettingsPreference.resolvedQuirkDefaults(defaults: group) == .off)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("QuirksWindowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sample = try BundledSampleFixture.copy("LYING.WS", into: scratch)
        let bytes = [UInt8](try Data(contentsOf: sample))
        let work = try QuickLookEngineWork.make(bytes: bytes, docPath: sample.path, pageSettingsPreset: nil, quirks: .off)
        #expect(work.parsed.document.quirks?.applied == [])
        let state = QuickLookRender.nativeState(for: work)
        #expect(state.quirkChoices == .off)
        #expect(state.document.quirks?.applied == [])
    }
}
