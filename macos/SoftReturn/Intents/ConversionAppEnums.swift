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

    // #271 M11, batch 31: an export's Mode, as the CLI's --mode names it.
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
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

/// The CLI's `--quirks {off,auto,all}` (R-127): which quirks run before the named ones are turned on or off.
enum ConversionQuirksMode: String, AppEnum, CaseIterable, Sendable {
    case off
    case auto
    case all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quirks"
    static let caseDisplayRepresentations: [ConversionQuirksMode: DisplayRepresentation] = [
        .off: "Off",
        .auto: "Auto",
        .all: "All",
    ]

    var quirkMode: QuirkMode {
        switch self {
        case .off:  return .off
        case .auto: return .auto
        case .all:  return .all
        }
    }
}

/// One quirk, by the engine's name (`QuirkName`) under the title the app's Quirks screens use — the CLI's `--quirk`
/// and `--no-quirk` names as a Shortcuts picker (R-127).
enum ConversionQuirk: String, AppEnum, CaseIterable, Sendable {
    case euroSwap = "euro-swap"
    case smartPunctuation = "smart-punctuation"
    case boxCorners = "box-corners"
    case colorsAsGray = "colors-as-gray"
    case fillPatterns = "fill-patterns"
    case sawyerStrikeout = "sawyer-strikeout"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quirk"
    static let caseDisplayRepresentations: [ConversionQuirk: DisplayRepresentation] = [
        .euroSwap: "Euro swap",
        .smartPunctuation: "Smart punctuation",
        .boxCorners: "Box corners",
        .colorsAsGray: "Colors as gray",
        .fillPatterns: "Fill patterns",
        .sawyerStrikeout: "Sawyer strikeout",
    ]
}
