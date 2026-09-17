import CtrlKD
import Foundation
import Testing
@testable import SoftReturnShared

/// Batch 46 (Jon's quirks rulings, 2026-09-16): the switches both apps store and apply.
@Suite @MainActor struct QuirkChoicesTests {
    /// A document whose own header names LJ6DTP, with a paragraph style that strikes and no cross-out typed: it trips
    /// all six quirks (LJ6DTP is one of the euro-patched drivers too).
    static func document() -> CtrlKD.Document {
        var document = CtrlKD.Document()
        document.printerDriver = "LJ6DTP"
        var block = Block(kind: .para, lines: [Line(spans: [Span(text: "A struck heading")])])
        block.styleAttrs.insert(.strike)
        document.blocks = [block]
        return document
    }

    @Test func autoIsWhatShippedAndThePresetsReadBack() {
        #expect(QuirkChoices.shipped.enabled == Set([QuirkName.euro, QuirkName.ljTypography, QuirkName.ljBoxCorners,
                                                     QuirkName.ljColourAsGray, QuirkName.ljFillPatterns]))
        #expect(QuirkChoices.shipped.preset == .auto)
        #expect(QuirkChoices.all.preset == .all)
        #expect(QuirkChoices.off.preset == .off)
        var custom = QuirkChoices.shipped
        custom.set(QuirkName.ljBoxCorners, on: false)
        #expect(custom.preset == .custom)
        #expect(QuirkChoices.Preset.custom.choices == nil)
        #expect(QuirkChoices.Preset.allCases.map(\.displayName) == ["Auto", "All", "Off", "Custom"])
    }

    @Test func rowsReadTheCanvasTitlesAndTheEnginesDescriptions() {
        #expect(QuirkChoices.names.map(QuirkChoices.title(of:)) == [
            "Euro sign", "LJ6DTP typography", "LJ6DTP box corners", "LJ6DTP colour as gray", "LJ6DTP fill patterns",
            "Stray style strikeout",
        ])
        #expect(QuirkChoices.description(of: QuirkName.strayStyleStrikeout) == "Ignore a strikeout set only by a style")
    }

    /// The shipped set records exactly the decision the engine makes with nothing asked, so nobody's output changes.
    @Test func theShippedSetChangesNothing() throws {
        let document = Self.document()
        let applied = QuirkChoices.shipped.apply(to: document)
        #expect(applied.quirks == (try QuirkRegistry.standard.resolve(document)))
        #expect(applied.blocks.map(\.styleAttrs) == document.blocks.map(\.styleAttrs))
    }

    @Test func eachSwitchReachesTheDocument() {
        let document = Self.document()
        #expect(QuirkChoices.off.apply(to: document).quirks?.applied == [])
        let all = QuirkChoices.all.apply(to: document)
        #expect(all.quirks?.applied.contains(QuirkName.strayStyleStrikeout) == true)
        #expect(all.blocks.first?.styleAttrs.contains(.strike) == false)
        var noCorners = QuirkChoices.shipped
        noCorners.set(QuirkName.ljBoxCorners, on: false)
        #expect(!quirkEnabled(noCorners.apply(to: document), QuirkName.ljBoxCorners))
        #expect(quirkEnabled(noCorners.apply(to: document), QuirkName.ljTypography))
    }

    @Test func overridesLieOverTheDefaults() {
        let choices = QuirkChoices.shipped.overridden(by: [QuirkName.euro: false, QuirkName.strayStyleStrikeout: true])
        #expect(!choices.isOn(QuirkName.euro))
        #expect(choices.isOn(QuirkName.strayStyleStrikeout))
        #expect(choices.isOn(QuirkName.ljTypography))
        #expect(QuirkChoices.shipped.overridden(by: ["no-such-quirk": true]) == .shipped)
    }

    /// Stored with every name, so a quirk a later engine adds reads its shipped default instead of off.
    @Test func storedChoicesRoundTripAndAMissingNameReadsShipped() throws {
        var choices = QuirkChoices.all
        choices.set(QuirkName.euro, on: false)
        let data = try JSONEncoder().encode(choices)
        #expect(try JSONDecoder().decode(QuirkChoices.self, from: data) == choices)
        let old = try JSONEncoder().encode([QuirkName.euro: false])
        let decoded = try JSONDecoder().decode(QuirkChoices.self, from: old)
        #expect(decoded == QuirkChoices.shipped.overridden(by: [QuirkName.euro: false]))
    }

    @Test func settingsKeepTheDefaultsAndSayWhenTheyChange() {
        let suite = "QuirkChoicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.quirkDefaults == .shipped)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: SettingsStore.quirkDefaultsDidChange,
                                                           object: settings, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.quirkDefaults = .all
        #expect(posted == 1)
        #expect(SettingsStore(defaults: defaults).quirkDefaults == .all)
    }

    @Test func aDocumentAppliesTheDefaultsAndItsOwnChoices() throws {
        let suite = "QuirkChoicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.quirkDefaults = .off
        let state = DocumentState(document: Self.document(), settings: settings)
        #expect(state.quirkChoices == .off)
        #expect(state.document.quirks?.applied == [])
        #expect(state.applicableQuirks.map(\.name) == [QuirkName.euro, QuirkName.ljTypography, QuirkName.ljBoxCorners,
                                                       QuirkName.ljColourAsGray, QuirkName.ljFillPatterns,
                                                       QuirkName.strayStyleStrikeout])

        #expect(state.setQuirk(QuirkName.strayStyleStrikeout, on: true))
        #expect(state.quirkOverrides == [QuirkName.strayStyleStrikeout: true])
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == false)
        // Back to the default is no override at all.
        #expect(state.setQuirk(QuirkName.strayStyleStrikeout, on: false))
        #expect(state.quirkOverrides.isEmpty)
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == true)
        #expect(!state.setQuirk(QuirkName.strayStyleStrikeout, on: false))

        #expect(state.setQuirk(QuirkName.ljTypography, on: true))
        #expect(state.setQuirkDefaults(.shipped))
        // The document's own choice now matches the new default, and stays its own choice.
        #expect(state.quirkOverrides == [QuirkName.ljTypography: true])
        #expect(!state.isQuirkOverridden(QuirkName.ljTypography))
        #expect(state.useAppDefaultQuirks() == false)
        #expect(state.quirkOverrides.isEmpty)
        #expect(state.quirkChoices == .shipped)
    }
}
