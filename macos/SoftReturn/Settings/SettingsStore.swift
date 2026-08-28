import CtrlKD
import Foundation
import UniformTypeIdentifiers

/// The nine preferences the build spec allows, and nothing else.
///
/// "Few options" is a governing ruling, not a style note: this app's second user converts
/// a shoebox of files in one afternoon and never opens it again, so every setting is a
/// question asked of someone who does not want to be asked. The list below is closed —
/// adding to it needs a spec change, not a code change. (Accessibility supports are exempt
/// from that count and are not settings here; they follow the system.)
///
/// The ninth, `restoreWindowsOnLaunch`, is exactly such a spec change — the window
/// restoration ruling that added it also ruled it needs an on/off switch, so it is not a
/// code-only addition slipped past the "closed list" rule above.
///
/// Job 373 (b24 FLAG UI): four more, same exception — the b24 flag wave's own ruling names
/// exact per-flag Settings defaults (headers ON, TOC OFF, Pictures Embed, inline styling ON),
/// so `defaultHeaders`/`defaultTOC`/`defaultPictures`/`defaultInlineStyling` below are a
/// second ruled spec change, not four settings slipped past the closed list either.
///
/// Job 520 (N5, b33 page-numbering UI ruling): one more, same exception — the b33
/// three-state `auto`/`on`/`off` page-numbering ruling names its own Settings default
/// (Auto), so `defaultPageNumbers` is a third ruled spec change, not a setting slipped in.
///
/// Values live in `UserDefaults.standard` under a `settings.` prefix. Nothing here is
/// secret and nothing is machine-specific.
/// Plain `@MainActor` class, not `@Observable` (job 342: needs macOS 14, and this app's floor
/// is now 13.0) — see `DocumentState`'s header comment; nothing reads this store through
/// SwiftUI's reactive tracking, so dropping the macro changes no observable behavior.
@MainActor
final class SettingsStore {
    /// Shared instance. The app has one preferences store; documents and the batch window
    /// read the same one so a change is visible everywhere immediately.
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.startingView = defaults.decode(Key.startingView) ?? .document
        self.defaultZoom = defaults.decode(Key.defaultZoom) ?? .fit
        self.defaultStyle = defaults.decode(Key.defaultStyle) ?? .native
        self.defaultDisplay = defaults.decode(Key.defaultDisplay) ?? .singlePage
        self.modernFontName = defaults.string(forKey: Key.modernFontName) ?? SettingsStore.defaultFontName
        self.modernFontSize = defaults.object(forKey: Key.modernFontSize) as? Int ?? 14
        self.defaultExportFormats = defaults.decode(Key.defaultExportFormats) ?? [.rtf]
        self.defaultPageSize = defaults.decode(Key.defaultPageSize) ?? .usLetter
        self.restoreWindowsOnLaunch = defaults.object(forKey: Key.restoreWindowsOnLaunch) as? Bool ?? true
        self.defaultHeaders = defaults.object(forKey: Key.defaultHeaders) as? Bool ?? true
        self.defaultTOC = defaults.object(forKey: Key.defaultTOC) as? Bool ?? false
        self.defaultInlineStyling = defaults.object(forKey: Key.defaultInlineStyling) as? Bool ?? true
        self.defaultPictures = defaults.decode(Key.defaultPictures) ?? .embed
        self.defaultPageNumbers = defaults.decode(Key.defaultPageNumbers) ?? .auto
        self.includeBetaVersions = defaults.object(forKey: Key.includeBetaVersions) as? Bool ?? false
    }

    // MARK: - The eight

    /// 1. Starting View. `document` opens with just the menu bar and NO file picker — the
    /// spec is explicit that an empty-handed launch does not nag.
    var startingView: StartingView { didSet { defaults.encode(startingView, Key.startingView) } }

    /// 2. Default Zoom.
    var defaultZoom: ZoomSetting { didSet { defaults.encode(defaultZoom, Key.defaultZoom) } }

    /// 3. Default Style. Native (job 265 ruling: the DEFAULT experience is unchanged — Native
    /// is what "Printed" meant before this job renamed it).
    var defaultStyle: ViewStyle { didSet { defaults.encode(defaultStyle, Key.defaultStyle) } }

    /// 4. Default Display.
    var defaultDisplay: PageDisplay { didSet { defaults.encode(defaultDisplay, Key.defaultDisplay) } }

    /// 5. Font — Modern style only.
    var modernFontName: String { didSet { defaults.set(modernFontName, forKey: Key.modernFontName) } }

    /// 6. Size. The spec fixes the menu to exactly these eight, default 14.
    var modernFontSize: Int { didSet { defaults.set(modernFontSize, forKey: Key.modernFontSize) } }

    /// 7. Default Export Formats — multi-select; pre-checks the Export As sheet.
    var defaultExportFormats: Set<ExportFormat> {
        didSet { defaults.encode(defaultExportFormats, Key.defaultExportFormats) }
    }

    /// 8. Default Page Size — the fallback for files that declare no geometry of their own.
    /// Never overrides a file that did.
    var defaultPageSize: NamedPageSize { didSet { defaults.encode(defaultPageSize, Key.defaultPageSize) } }

    /// 9. Restore windows on launch. Default ON — a one-afternoon user does not want to be
    /// asked, and losing the documents they had open the last time they quit is the more
    /// surprising failure of the two. Gates whether `DocumentWindowController` writes ANY of
    /// its restorable state at all; see that class's `window(_:willEncodeRestorableState:)`.
    var restoreWindowsOnLaunch: Bool {
        didSet { defaults.set(restoreWindowsOnLaunch, forKey: Key.restoreWindowsOnLaunch) }
    }

    /// 10-13. Job 373 (b24 FLAG UI): the export-sheet per-export controls' own defaults —
    /// RULED (headers ON, TOC OFF, Pictures Embed, inline styling ON), matching `EmitOptions`'
    /// own field defaults exactly. The Export As sheet initializes its four new controls from
    /// these on every open; a per-export override there never writes back here.
    var defaultHeaders: Bool { didSet { defaults.set(defaultHeaders, forKey: Key.defaultHeaders) } }
    var defaultTOC: Bool { didSet { defaults.set(defaultTOC, forKey: Key.defaultTOC) } }
    var defaultInlineStyling: Bool {
        didSet { defaults.set(defaultInlineStyling, forKey: Key.defaultInlineStyling) }
    }
    var defaultPictures: EmitOptions.PixMode {
        didSet { defaults.encode(defaultPictures, Key.defaultPictures) }
    }

    /// 14. Job 520 (N5, b33 page-numbering UI): the app-wide default for the three-state
    /// `auto`/`on`/`off` page-numbering option — ruled default Auto. Both export surfaces
    /// (the Export As sheet, the Batch window) initialize their own per-export pulldown
    /// from this, same "initializes from, never writes back" rule the b24 flags follow.
    var defaultPageNumbers: EmitOptions.PageNumberMode {
        didSet { defaults.encode(defaultPageNumbers, Key.defaultPageNumbers) }
    }

    /// 15. Job 537 (rulings 20-21, Sparkle channel opt-in): a fourth ruled spec change, same
    /// exception as job 373/520 above — "include beta versions" is not a setting slipped past
    /// the closed list, it is the one user-facing control the channel ruling names. Default
    /// OFF: a one-afternoon user gets stable only unless they deliberately go looking for it
    /// (see `SettingsWindowController`'s Option-revealed checkbox). Feeds
    /// `SparkleChannelPolicy.allowedChannels(includeBetaVersions:)`, which
    /// `AppDelegate.allowedChannels(for:)` reads fresh on every Sparkle channel check.
    var includeBetaVersions: Bool {
        didSet { defaults.set(includeBetaVersions, forKey: Key.includeBetaVersions) }
    }

    // MARK: - Fixed vocabularies

    /// The size menu, per spec: "9, 10, 11, 12, 13, 14, 16, 18 only, default 14".
    static let fontSizes = [9, 10, 11, 12, 13, 14, 16, 18]

    /// Modern's default face. A serif reading face rather than the system UI font: Modern
    /// style exists to make a 1987 document *readable*, and body text is what it is for.
    static let defaultFontName = "Georgia"

    private enum Key {
        static let startingView = "settings.startingView"
        static let defaultZoom = "settings.defaultZoom"
        static let defaultStyle = "settings.defaultStyle"
        static let defaultDisplay = "settings.defaultDisplay"
        static let modernFontName = "settings.modernFontName"
        static let modernFontSize = "settings.modernFontSize"
        static let defaultExportFormats = "settings.defaultExportFormats"
        static let defaultPageSize = "settings.defaultPageSize"
        static let restoreWindowsOnLaunch = "settings.restoreWindowsOnLaunch"
        static let defaultHeaders = "settings.defaultHeaders"
        static let defaultTOC = "settings.defaultTOC"
        static let defaultInlineStyling = "settings.defaultInlineStyling"
        static let defaultPictures = "settings.defaultPictures"
        static let defaultPageNumbers = "settings.defaultPageNumbers"
        static let includeBetaVersions = "settings.includeBetaVersions"
    }
}

/// What the app shows when it launches with no document.
enum StartingView: String, Hashable, CaseIterable, Codable, Sendable {
    case document
    case batchConvert

    var displayName: String {
        switch self {
        case .document:     return "Document"
        case .batchConvert: return "Batch Convert"
        }
    }
}

/// The five export formats, in the order the spec lists them everywhere.
enum ExportFormat: String, Hashable, CaseIterable, Codable, Sendable {
    case text
    case markdown
    case html
    case rtf
    case pdf

    var displayName: String {
        switch self {
        case .text:     return "Text"
        case .markdown: return "Markdown"
        case .html:     return "HTML"
        case .rtf:      return "RTF"
        case .pdf:      return "PDF"
        }
    }

    /// The name the library's emitter registry knows this format by.
    var libraryFormatName: String { rawValue }

    /// File extension, without the dot.
    var fileExtension: String {
        switch self {
        case .text:     return "txt"
        case .markdown: return "md"
        case .html:     return "html"
        case .rtf:      return "rtf"
        case .pdf:      return "pdf"
        }
    }

    /// Built straight from `fileExtension` rather than a system-registered identifier — a
    /// dynamic type still carries the right `preferredFilenameExtension`, which is all
    /// `NSSavePanel.allowedContentTypes` needs to append/enforce the extension itself (job
    /// 244 Leg 1: the panel grants the extension as part of what it hands back, so
    /// `ExportEngine.writeSingle` keeps writing exactly the granted URL).
    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }
}

// MARK: - Codable-through-UserDefaults

/// `ZoomSetting` has an associated value, so it needs a hand-written coding — the rest are
/// plain string enums and get theirs for free.
extension ZoomSetting: Codable {
    private enum Stored: Codable {
        case fit, actual
        case percent(Int)
    }

    init(from decoder: Decoder) throws {
        switch try Stored(from: decoder) {
        case .fit:              self = .fit
        case .actual:           self = .actual
        case .percent(let pct): self = .percent(pct)
        }
    }

    func encode(to encoder: Encoder) throws {
        let stored: Stored
        switch self {
        case .fit:              stored = .fit
        case .actual:           stored = .actual
        case .percent(let pct): stored = .percent(pct)
        }
        try stored.encode(to: encoder)
    }
}

extension ViewStyle: Codable {}
extension PageDisplay: Codable {}
extension NamedPageSize: Codable {}
extension EmitOptions.PixMode: Codable {}
extension EmitOptions.PageNumberMode: Codable {}

private extension UserDefaults {
    /// JSON in a defaults key. Plain `set(_:forKey:)` handles strings and ints; anything
    /// with a case payload or a Set goes through Codable rather than growing a bespoke
    /// representation per type.
    func encode<T: Encodable>(_ value: T, _ key: String) {
        // Job 220 (finding C): every type riding through this is a plain enum/struct with no
        // custom Encodable — an encode failure here is not a real-world path, and a dropped
        // preference write just leaves the previous value (or the type's own default) in
        // place, not a corrupted one.
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }

    func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        // A round-trip fallback: `nil` here reads exactly like "never set", which is the
        // safe/default behavior a corrupted or pre-migration defaults blob should get, not
        // a crash or an alert over a single preference.
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
