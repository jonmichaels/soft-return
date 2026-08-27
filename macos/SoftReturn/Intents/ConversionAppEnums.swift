import AppIntents
import CtrlKD

/// The five formats `DocumentOperations.ConversionOptions.formats` accepts, as a Shortcuts
/// picker. Case names and raw values match the library's own emitter names (`ExportFormat`
/// in `SettingsStore.swift` is the same vocabulary, app-side) — `libraryFormatName` states
/// that relationship as a fact instead of leaving it a coincidence a rename could break.
enum ConversionFormat: String, AppEnum, CaseIterable, Sendable {
    case text
    case markdown
    case html
    case rtf
    case pdf

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [ConversionFormat: DisplayRepresentation] = [
        .text: "Plain Text",
        .markdown: "Markdown",
        .html: "HTML",
        .rtf: "RTF",
        .pdf: "PDF",
    ]

    var libraryFormatName: String { rawValue }
}

/// The library's `EmitMode` — `RenderStyle` in `DocumentState.swift` is the same axis,
/// app-side, under the app's own vocabulary ("Printed"/"Modern" — export/convert's two
/// formats; `ViewStyle`, job 265, is the separate three-case axis the View menu now uses).
enum ConversionStyle: String, AppEnum, CaseIterable, Sendable {
    case modern
    case printed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [ConversionStyle: DisplayRepresentation] = [
        .modern: "Modern — reflowed for reading",
        .printed: "Printed — typescript facsimile",
    ]

    var emitMode: EmitMode {
        switch self {
        case .modern:  return .modern
        case .printed: return .printed
        }
    }
}

/// Job 373 (b24 FLAG UI): the library's `EmitOptions.PixMode` (`--pictures {off,embed,export}`),
/// as a Shortcuts picker — the App Intents half of the export-sheet Pictures pulldown.
enum ConversionPictures: String, AppEnum, CaseIterable, Sendable {
    case off
    case embed
    case export

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pictures"
    static let caseDisplayRepresentations: [ConversionPictures: DisplayRepresentation] = [
        .off: "Off",
        .embed: "Embed",
        .export: "Export",
    ]

    var pixMode: EmitOptions.PixMode {
        switch self {
        case .off:   return .off
        case .embed: return .embed
        case .export: return .export
        }
    }

    init(_ mode: EmitOptions.PixMode) {
        switch mode {
        case .off:   self = .off
        case .embed: self = .embed
        case .export: self = .export
        }
    }
}
