import CtrlKD
import Foundation

/// Bridges every enumeration in `SoftReturn.sdef` to and from the library/app-side Swift
/// type it stands for. One table per enumeration, both directions, codes copied verbatim
/// from the sdef — this file and the sdef must be read side by side when either changes.
enum ScriptingEnumCoding {

    // MARK: - variant

    static let variantCodes: [Variant: String] = [
        .ws4: "SRv4", .ws5plus: "SRv5", .printstream: "SRvp", .text: "SRvt",
    ]

    static func code(for variant: Variant) -> UInt32? {
        variantCodes[variant].map(ScriptingCodes.fourCharCode)
    }

    static func variant(forCode code: UInt32) -> Variant? {
        variantCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - style (ViewStyle)

    /// Job 313B (Jon's ruling 2026-08-14, superseding job 265's "Native has no export
    /// equivalent"): keyed by `ViewStyle` — the window's own three-case type — not
    /// `EmitMode`, now that a script CAN ask for `native`. Callers that only ever wanted the
    /// two-case export/convert axis (`ExportCommand`, `ConvertCommand`) collapse a decoded
    /// `ViewStyle` through `.renderStyle.emitMode` themselves; this table stops doing that
    /// collapsing on their behalf so the honest three-case value survives for callers that
    /// DO care (the `document.style` property, and PDF export's native print-path carve-out).
    static let styleCodes: [ViewStyle: String] = [.native: "SRsn", .printed: "SRsp", .modern: "SRsm"]

    static func code(for style: ViewStyle) -> UInt32? {
        styleCodes[style].map(ScriptingCodes.fourCharCode)
    }

    static func style(forCode code: UInt32) -> ViewStyle? {
        styleCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - export format (library emitter names)

    /// `DocumentOperations.ConversionOptions.formats`/`EmitterRegistry` names — "layout"
    /// included, per the ruling (full CLI parity).
    static let exportFormatCodes: [String: String] = [
        "text": "SRft", "markdown": "SRfk", "html": "SRfh",
        "rtf": "SRfr", "pdf": "SRfp", "layout": "SRfj",
    ]

    static func code(forLibraryFormat name: String) -> UInt32? {
        exportFormatCodes[name].map(ScriptingCodes.fourCharCode)
    }

    static func libraryFormat(forCode code: UInt32) -> String? {
        exportFormatCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - note reference style (NoteRefs)

    static let noteRefsCodes: [NoteRefs: String] = [.word: "SRnw", .prefixed: "SRnp"]

    static func code(for noteRefs: NoteRefs) -> UInt32? {
        noteRefsCodes[noteRefs].map(ScriptingCodes.fourCharCode)
    }

    static func noteRefs(forCode code: UInt32) -> NoteRefs? {
        noteRefsCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - page size (NamedPageSize)

    static let pageSizeCodes: [NamedPageSize: String] = [
        .usLetter: "SRpl", .usLegal: "SRpg", .a4: "SRp4",
    ]

    static func code(for pageSize: NamedPageSize) -> UInt32? {
        pageSizeCodes[pageSize].map(ScriptingCodes.fourCharCode)
    }

    static func pageSize(forCode code: UInt32) -> NamedPageSize? {
        pageSizeCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - settings preset (DocumentOperations.PageSettingsPreset)

    /// Public AppleScript names differ from the Swift case names on purpose (Jon's
    /// ruling, 2026-08-08: "sawyer stays") — `default` reads as "factory" in the
    /// dictionary; `sawyer`/`modern` are unchanged (job 315: the dictionary term was
    /// "modern defaults", now plain "modern", matching the Swift case again).
    static let settingsPresetCodes: [DocumentOperations.PageSettingsPreset: String] = [
        .default: "SRxf", .sawyer: "SRxs", .modern: "SRxm",
    ]

    static func code(for preset: DocumentOperations.PageSettingsPreset) -> UInt32? {
        settingsPresetCodes[preset].map(ScriptingCodes.fourCharCode)
    }

    static func settingsPreset(forCode code: UInt32) -> DocumentOperations.PageSettingsPreset? {
        settingsPresetCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - pictures mode (EmitOptions.PixMode)

    /// Job 373 (b24 FLAG UI): the export sheet/CLI's `--pictures {off,embed,export}`.
    static let picturesModeCodes: [EmitOptions.PixMode: String] = [
        .off: "SRxo", .embed: "SRxe", .export: "SRxx",
    ]

    static func code(for pictures: EmitOptions.PixMode) -> UInt32? {
        picturesModeCodes[pictures].map(ScriptingCodes.fourCharCode)
    }

    static func picturesMode(forCode code: UInt32) -> EmitOptions.PixMode? {
        picturesModeCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - fonts (FontsTarget)

    /// Job 504: the CLI's `--fonts {office,mac,google,linux}` — `export`/`convert`'s
    /// hardcoded `.mac` fontsTarget becomes this optional parameter's default value
    /// instead of a ceiling (`WSDocument+Scripting.swift`/`ConvertCommand.swift`).
    static let fontsTargetCodes: [FontsTarget: String] = [
        .office: "SRof", .mac: "SRmc", .google: "SRgg", .linux: "SRlx",
    ]

    static func code(for fontsTarget: FontsTarget) -> UInt32? {
        fontsTargetCodes[fontsTarget].map(ScriptingCodes.fourCharCode)
    }

    static func fontsTarget(forCode code: UInt32) -> FontsTarget? {
        fontsTargetCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - page numbers mode (EmitOptions.PageNumberMode)

    /// Job 506 (b31): the CLI's `--page-numbers {auto,on,off}`.
    static let pageNumbersModeCodes: [EmitOptions.PageNumberMode: String] = [
        .auto: "SRpa", .on: "SRpo", .off: "SRp0",
    ]

    static func code(for pageNumbers: EmitOptions.PageNumberMode) -> UInt32? {
        pageNumbersModeCodes[pageNumbers].map(ScriptingCodes.fourCharCode)
    }

    static func pageNumbersMode(forCode code: UInt32) -> EmitOptions.PageNumberMode? {
        pageNumbersModeCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - sentence spacing mode (EmitOptions.SentenceSpacingMode)

    /// Job 521 (N9, b33): the CLI's `--sentence-spacing {auto,keep,single}`.
    static let sentenceSpacingModeCodes: [EmitOptions.SentenceSpacingMode: String] = [
        .auto: "SRsa", .keep: "SRsk", .single: "SRsl",
    ]

    static func code(for sentenceSpacing: EmitOptions.SentenceSpacingMode) -> UInt32? {
        sentenceSpacingModeCodes[sentenceSpacing].map(ScriptingCodes.fourCharCode)
    }

    static func sentenceSpacingMode(forCode code: UInt32) -> EmitOptions.SentenceSpacingMode? {
        sentenceSpacingModeCodes.first { ScriptingCodes.fourCharCode($0.value) == code }?.key
    }

    // MARK: - zoom setting (the named half of ZoomSetting)

    static func code(forZoomNamed setting: ZoomSetting) -> UInt32? {
        switch setting {
        case .fit: return ScriptingCodes.fourCharCode("SRzf")
        case .actual: return ScriptingCodes.fourCharCode("SRza")
        case .percent: return nil
        }
    }

    static func namedZoom(forCode code: UInt32) -> ZoomSetting? {
        if code == ScriptingCodes.fourCharCode("SRzf") { return .fit }
        if code == ScriptingCodes.fourCharCode("SRza") { return .actual }
        return nil
    }
}
