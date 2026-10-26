import CtrlKD
import Foundation

// The per-export options both apps offer, with the words they use and the formats each one
// means something for. The Mac's Export As sheet, Settings window and Batch window and the
// iPhone's export sheet and Settings all read these, so a title or an availability rule is
// written once.

/// The six per-export controls, in the order the iPhone's sheet lists them.
public enum ExportOption: CaseIterable, Sendable {
    case headers, toc, inlineStyling, pictures, pageNumbers, sentenceSpacing

    public var title: String {
        switch self {
        case .headers: return "Headers/Footers"
        case .toc: return "Table of Contents"
        case .inlineStyling: return "Inline Styling"
        case .pictures: return "Pictures"
        case .pageNumbers: return "Page Numbering"
        case .sentenceSpacing: return "Sentence Spacing"
        }
    }

    /// Whether the control does anything for at least one of `formats`, or for every format
    /// (Table of Contents and Sentence Spacing are never disabled, even with nothing checked).
    /// A control that does nothing is disabled but keeps its last value, so re-checking a
    /// format restores what the person chose.
    public func isEnabled<Formats: Collection>(forFormats formats: Formats) -> Bool
    where Formats.Element == ExportFormat {
        ExportFormat.allCases.allSatisfy { $0.allows(self) } || formats.contains { $0.allows(self) }
    }
}

extension ExportFormat {
    /// The paged-surface rule, per format: Headers/Footers and Page Numbering only mean
    /// something for the two paged emitters (RTF, PDF); Inline Styling only for RTF and HTML;
    /// Pictures for every format but plain text (a `.PIX` has no flat-text form); Table of
    /// Contents and Sentence Spacing apply to all five.
    public func allows(_ option: ExportOption) -> Bool {
        switch option {
        case .headers, .pageNumbers: return self == .rtf || self == .pdf
        case .inlineStyling: return self == .rtf || self == .html
        case .pictures: return self != .text
        case .toc, .sentenceSpacing: return true
        }
    }
}

// MARK: - Choice titles

extension EmitOptions.PixMode {
    /// Menu order: Off, Embed, Export.
    public static let choices: [EmitOptions.PixMode] = [.off, .embed, .export]

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .embed: return "Embed"
        case .export: return "Export"
        }
    }
}

extension EmitOptions.PageNumberMode {
    /// Menu order: Auto, On, Off.
    public static let choices: [EmitOptions.PageNumberMode] = [.auto, .on, .off]

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

extension EmitOptions.SentenceSpacingMode {
    /// Menu order: Auto, Keep as typed, Single space.
    public static let choices: [EmitOptions.SentenceSpacingMode] = [.auto, .keep, .single]

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .keep: return "Keep as typed"
        case .single: return "Single space"
        }
    }
}

// MARK: - Choices as one value

/// The six per-export choices as one value: what a sheet holds, what Settings supplies as the
/// starting point, what a script's parameters decode to. Writes the engine's `EmitOptions`
/// fields from them in one place.
public struct ExportChoices: Equatable, Sendable {
    public var headers: Bool
    public var toc: Bool
    public var inlineStyling: Bool
    public var pictures: EmitOptions.PixMode
    public var pageNumbers: EmitOptions.PageNumberMode
    public var sentenceSpacing: EmitOptions.SentenceSpacingMode

    /// The library's own ruled defaults: headers on, no table of contents, inline styling on,
    /// pictures embedded, automatic page numbers and sentence spacing.
    public init(
        headers: Bool = true, toc: Bool = false, inlineStyling: Bool = true,
        pictures: EmitOptions.PixMode = .embed, pageNumbers: EmitOptions.PageNumberMode = .auto,
        sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    ) {
        self.headers = headers
        self.toc = toc
        self.inlineStyling = inlineStyling
        self.pictures = pictures
        self.pageNumbers = pageNumbers
        self.sentenceSpacing = sentenceSpacing
    }

    /// What the person set in Settings. Sentence spacing has no Settings item (ruled), so it
    /// starts at Auto.
    @MainActor
    public init(settings: SettingsStore) {
        self.init(
            headers: settings.defaultHeaders, toc: settings.defaultTOC,
            inlineStyling: settings.defaultInlineStyling, pictures: settings.defaultPictures,
            pageNumbers: settings.defaultPageNumbers, sentenceSpacing: .auto)
    }

    /// Writes the six choices into `options`.
    public func apply(to options: inout EmitOptions) {
        options.headers = headers
        options.toc = toc
        options.inlineStyling = inlineStyling
        options.pictures = pictures
        options.pageNumbers = pageNumbers
        options.sentenceSpacing = sentenceSpacing
    }
}
