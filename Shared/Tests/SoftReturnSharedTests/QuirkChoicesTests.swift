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
        #expect(QuirkChoices.shipped.enabled == Set([QuirkName.euroSwap, QuirkName.smartPunctuation, QuirkName.boxCorners,
                                                     QuirkName.colorsAsGray, QuirkName.fillPatterns]))
        #expect(QuirkChoices.shipped.preset == .auto)
        #expect(QuirkChoices.all.preset == .all)
        #expect(QuirkChoices.off.preset == .off)
        var custom = QuirkChoices.shipped
        custom.set(QuirkName.boxCorners, on: false)
        #expect(custom.preset == .custom)
        #expect(QuirkChoices.Preset.custom.choices == nil)
        #expect(QuirkChoices.Preset.allCases.map(\.displayName) == ["Auto", "All", "Off", "Custom"])
    }

    @Test func rowsReadTheCanvasTitlesAndTheEnginesDescriptions() {
        #expect(QuirkChoices.names.map(QuirkChoices.title(of:)) == [
            "Euro swap", "Smart punctuation", "Box corners", "Colors as gray", "Fill patterns", "Sawyer strikeout",
        ])
        #expect(QuirkChoices.description(of: QuirkName.sawyerStrikeout) == "Ignore a strikeout set only by a style")
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
        #expect(all.quirks?.applied.contains(QuirkName.sawyerStrikeout) == true)
        #expect(all.blocks.first?.styleAttrs.contains(.strike) == false)
        var noCorners = QuirkChoices.shipped
        noCorners.set(QuirkName.boxCorners, on: false)
        #expect(!quirkEnabled(noCorners.apply(to: document), QuirkName.boxCorners))
        #expect(quirkEnabled(noCorners.apply(to: document), QuirkName.smartPunctuation))
    }

    @Test func overridesLieOverTheDefaults() {
        let choices = QuirkChoices.shipped.overridden(by: [QuirkName.euroSwap: false, QuirkName.sawyerStrikeout: true])
        #expect(!choices.isOn(QuirkName.euroSwap))
        #expect(choices.isOn(QuirkName.sawyerStrikeout))
        #expect(choices.isOn(QuirkName.smartPunctuation))
        #expect(QuirkChoices.shipped.overridden(by: ["no-such-quirk": true]) == .shipped)
    }

    /// Stored with every name, so a quirk a later engine adds reads its shipped default instead of off.
    @Test func storedChoicesRoundTripAndAMissingNameReadsShipped() throws {
        var choices = QuirkChoices.all
        choices.set(QuirkName.euroSwap, on: false)
        let data = try JSONEncoder().encode(choices)
        #expect(try JSONDecoder().decode(QuirkChoices.self, from: data) == choices)
        let old = try JSONEncoder().encode([QuirkName.euroSwap: false])
        let decoded = try JSONDecoder().decode(QuirkChoices.self, from: old)
        #expect(decoded == QuirkChoices.shipped.overridden(by: [QuirkName.euroSwap: false]))
    }

    /// Batch 47 (E5c): the six names 4.4.0 stored — in the app's defaults and in a document's own choices — read as the
    /// six new ones: the same choices, and a document's stored overrides kept.
    @MainActor
    @Test func theNamesFourFourZeroStoredReadAsTheNewOnes() throws {
        let old = ["driver-euro-sign", "lj6dtp-typography", "lj6dtp-box-corners", "lj6dtp-colour-as-gray",
                   "lj6dtp-fill-patterns", "stray-style-strikeout"]
        let new = [QuirkName.euroSwap, QuirkName.smartPunctuation, QuirkName.boxCorners, QuirkName.colorsAsGray,
                   QuirkName.fillPatterns, QuirkName.sawyerStrikeout]
        #expect(QuirkChoices.names == new)
        for (flip, _) in old.enumerated() {
            var stored: [String: Bool] = [:]
            var expected: [String: Bool] = [:]
            for (index, (oldName, newName)) in zip(old, new).enumerated() {
                let on = (index + flip) % 2 == 0
                stored[oldName] = on
                expected[newName] = on
            }
            let fromOld = try JSONDecoder().decode(QuirkChoices.self, from: JSONEncoder().encode(stored))
            let fromNew = try JSONDecoder().decode(QuirkChoices.self, from: JSONEncoder().encode(expected))
            #expect(fromOld == fromNew, "old keys \(stored) read as \(fromOld.enabled.sorted()), new \(fromNew.enabled.sorted())")
            // Re-saved, the new names only.
            let resaved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fromOld)) as? [String: Bool]
            #expect(Set(resaved?.keys ?? [:].keys) == Set(new))
        }
        for (oldName, newName) in zip(old, new) {
            #expect(QuirkChoices.title(of: oldName) == QuirkChoices.title(of: newName))
            #expect(QuirkChoices.shipped.isOn(oldName) == QuirkChoices.shipped.isOn(newName))
        }
        // A document's overrides stored under an old name.
        let state = DocumentState(document: Self.document(), settings: SettingsStore(defaults: UserDefaults(suiteName: "QuirkChoicesTests.\(UUID().uuidString)")!))
        state.setQuirkOverrides(["stray-style-strikeout": true, "driver-euro-sign": false])
        #expect(state.quirkOverrides == [QuirkName.sawyerStrikeout: true, QuirkName.euroSwap: false])
        #expect(state.isQuirkOverridden("stray-style-strikeout"))
        #expect(state.document.quirks?.applied.contains(QuirkName.sawyerStrikeout) == true)
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
        #expect(state.applicableQuirks.map(\.name) == [QuirkName.euroSwap, QuirkName.smartPunctuation, QuirkName.boxCorners,
                                                       QuirkName.colorsAsGray, QuirkName.fillPatterns,
                                                       QuirkName.sawyerStrikeout])

        #expect(state.setQuirk(QuirkName.sawyerStrikeout, on: true))
        #expect(state.quirkOverrides == [QuirkName.sawyerStrikeout: true])
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == false)
        // Back to the default is no override at all.
        #expect(state.setQuirk(QuirkName.sawyerStrikeout, on: false))
        #expect(state.quirkOverrides.isEmpty)
        #expect(state.document.blocks.first?.styleAttrs.contains(.strike) == true)
        #expect(!state.setQuirk(QuirkName.sawyerStrikeout, on: false))

        #expect(state.setQuirk(QuirkName.smartPunctuation, on: true))
        #expect(state.setQuirkDefaults(.shipped))
        // The document's own choice now matches the new default, and stays its own choice.
        #expect(state.quirkOverrides == [QuirkName.smartPunctuation: true])
        #expect(!state.isQuirkOverridden(QuirkName.smartPunctuation))
        #expect(state.useAppDefaultQuirks() == false)
        #expect(state.quirkOverrides.isEmpty)
        #expect(state.quirkChoices == .shipped)
    }
}
