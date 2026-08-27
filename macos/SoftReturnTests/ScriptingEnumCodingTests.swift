import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Every enumeration in `SoftReturn.sdef` bridges to/from its Swift type through
/// `ScriptingEnumCoding`'s tables — these tests pin both the round trip and the exact
/// codes copied from the sdef, so the two files cannot drift silently.
@Suite struct ScriptingEnumCodingTests {

    @Test func fourCharCodeIsBigEndianLikeCAndCarbonExpect() {
        // 'SRv4' == 0x53527634, the same value `FOUR_CHAR_CODE('SRv4')` would produce.
        #expect(ScriptingCodes.fourCharCode("SRv4") == 0x53527634)
    }

    @Test func everyEnumCodeIsExactlyFourASCIIBytes() {
        let allCodes =
            Array(ScriptingEnumCoding.variantCodes.values)
            + Array(ScriptingEnumCoding.styleCodes.values)
            + Array(ScriptingEnumCoding.exportFormatCodes.values)
            + Array(ScriptingEnumCoding.noteRefsCodes.values)
            + Array(ScriptingEnumCoding.pageSizeCodes.values)
            + Array(ScriptingEnumCoding.settingsPresetCodes.values)
            + Array(ScriptingEnumCoding.picturesModeCodes.values)
            + Array(ScriptingEnumCoding.fontsTargetCodes.values)
            + Array(ScriptingEnumCoding.pageNumbersModeCodes.values)
            + ["SRzf", "SRza"]
        for code in allCodes {
            #expect(code.utf8.count == 4, "\(code) is not 4 bytes")
            #expect(code.utf8.allSatisfy { $0 < 0x80 }, "\(code) is not ASCII")
        }
    }

    @Test func everyEnumCodeIsUniqueWithinItsOwnEnumeration() {
        for table in [
            ScriptingEnumCoding.variantCodes.values.map { $0 } as [String],
            Array(ScriptingEnumCoding.styleCodes.values),
            Array(ScriptingEnumCoding.exportFormatCodes.values),
            Array(ScriptingEnumCoding.noteRefsCodes.values),
            Array(ScriptingEnumCoding.pageSizeCodes.values),
            Array(ScriptingEnumCoding.settingsPresetCodes.values),
            Array(ScriptingEnumCoding.picturesModeCodes.values),
            Array(ScriptingEnumCoding.fontsTargetCodes.values),
            Array(ScriptingEnumCoding.pageNumbersModeCodes.values),
        ] {
            #expect(Set(table).count == table.count)
        }
    }

    // MARK: - variant — the ruled enumeration (ws5plus one word, ws4/printstream/text)

    @Test func variantRoundTripsAllFourRuledCases() throws {
        for variant: Variant in [.ws4, .ws5plus, .printstream, .text] {
            let code = try #require(ScriptingEnumCoding.code(for: variant))
            #expect(ScriptingEnumCoding.variant(forCode: code) == variant)
        }
    }

    @Test func variantExcludesBinaryFromScriptingChoices() {
        #expect(ScriptingEnumCoding.variantCodes[.binary] == nil)
    }

    // MARK: - style

    /// Job 313B (Jon's ruling 2026-08-14, superseding job 265): `native` joins the
    /// enumeration — the sdef `style` type is keyed by `ViewStyle` (three cases) now, not
    /// `EmitMode` (two), so a script can round-trip every view the window itself offers.
    @Test func styleRoundTripsNativePrintedAndModern() throws {
        for style: ViewStyle in [.native, .printed, .modern] {
            let code = try #require(ScriptingEnumCoding.code(for: style))
            #expect(ScriptingEnumCoding.style(forCode: code) == style)
        }
    }

    // MARK: - export format — full CLI parity, including layout JSON (Jon's ruling)

    @Test func exportFormatCoversEveryLibraryEmitterIncludingLayout() throws {
        let expected: Set<String> = ["text", "markdown", "html", "rtf", "pdf", "layout"]
        #expect(Set(ScriptingEnumCoding.exportFormatCodes.keys) == expected)
        for name in expected {
            let code = try #require(ScriptingEnumCoding.code(forLibraryFormat: name))
            #expect(ScriptingEnumCoding.libraryFormat(forCode: code) == name)
        }
    }

    // MARK: - note reference style

    @Test func noteRefsRoundTripsWordAndPrefixed() throws {
        for scheme: NoteRefs in [.word, .prefixed] {
            let code = try #require(ScriptingEnumCoding.code(for: scheme))
            #expect(ScriptingEnumCoding.noteRefs(forCode: code) == scheme)
        }
    }

    // MARK: - page size

    @Test func pageSizeRoundTripsAllThreeNamedSizes() throws {
        for size: NamedPageSize in [.usLetter, .usLegal, .a4] {
            let code = try #require(ScriptingEnumCoding.code(for: size))
            #expect(ScriptingEnumCoding.pageSize(forCode: code) == size)
        }
    }

    // MARK: - settings preset — "sawyer" stays; default/modern read as factory/modern defaults

    @Test func settingsPresetRoundTripsAllThreePresets() throws {
        for preset: DocumentOperations.PageSettingsPreset in [.default, .sawyer, .modern] {
            let code = try #require(ScriptingEnumCoding.code(for: preset))
            #expect(ScriptingEnumCoding.settingsPreset(forCode: code) == preset)
        }
    }

    // MARK: - pictures mode (job 373, b24 FLAG UI)

    @Test func picturesModeRoundTripsAllThreeCases() throws {
        for mode: EmitOptions.PixMode in [.off, .embed, .export] {
            let code = try #require(ScriptingEnumCoding.code(for: mode))
            #expect(ScriptingEnumCoding.picturesMode(forCode: code) == mode)
        }
    }

    // MARK: - fonts (job 504)

    @Test func fontsTargetRoundTripsAllFourCases() throws {
        for target: FontsTarget in [.office, .mac, .google, .linux] {
            let code = try #require(ScriptingEnumCoding.code(for: target))
            #expect(ScriptingEnumCoding.fontsTarget(forCode: code) == target)
        }
    }

    // MARK: - page numbers mode (job 506, b31)

    @Test func pageNumbersModeRoundTripsAllThreeCases() throws {
        for mode: EmitOptions.PageNumberMode in [.auto, .on, .off] {
            let code = try #require(ScriptingEnumCoding.code(for: mode))
            #expect(ScriptingEnumCoding.pageNumbersMode(forCode: code) == mode)
        }
    }

    // MARK: - sentence spacing mode (job 521, b33 N9)

    @Test func sentenceSpacingModeRoundTripsAllThreeCases() throws {
        for mode: EmitOptions.SentenceSpacingMode in [.auto, .keep, .single] {
            let code = try #require(ScriptingEnumCoding.code(for: mode))
            #expect(ScriptingEnumCoding.sentenceSpacingMode(forCode: code) == mode)
        }
    }

    // MARK: - zoom setting (the named half of ZoomSetting)

    @Test func zoomSettingRoundTripsFitAndActual() throws {
        for setting: ZoomSetting in [.fit, .actual] {
            let code = try #require(ScriptingEnumCoding.code(forZoomNamed: setting))
            #expect(ScriptingEnumCoding.namedZoom(forCode: code) == setting)
        }
    }

    @Test func zoomSettingHasNoCodeForAPercentage() {
        #expect(ScriptingEnumCoding.code(forZoomNamed: .percent(100)) == nil)
    }

    @Test func namedZoomReturnsNilForAnOrdinaryPercentageValue() {
        // A realistic zoom percentage never collides with a four-char code's huge integer
        // value — this is the assumption `WSDocument.scriptingZoom`'s setter leans on.
        #expect(ScriptingEnumCoding.namedZoom(forCode: 100) == nil)
        #expect(ScriptingEnumCoding.namedZoom(forCode: 50) == nil)
    }
}
