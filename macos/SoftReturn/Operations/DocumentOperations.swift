import CtrlKD
import Foundation

/// Open / convert / diagnose against CtrlKD — UI-free.
///
/// Everything in this repo that needs to open, convert, or diagnose a WordStar document
/// without a window — App Intents, the Spotlight importer's indexing logic, and eventually
/// an AppleScript implementation — calls THIS layer, never CtrlKD directly. Its option
/// surface (variant forcing, format list, mode/style, notes, page-settings presets) is
/// deliberately shaped like `sr`'s own `SoftReturnCLI.Options`/`Run.swift` (the CtrlKD
/// checkout's `Sources/SoftReturnCLI/`), so a future AppleScript dictionary can offer the
/// CLI's full parameter surface by calling the same functions — even though today's two
/// Intents only expose part of it.
///
/// No AppKit, no `Observation`, no `@MainActor`: this must run headlessly inside an appex
/// process and inside an Intents extension process, neither of which can host
/// `DocumentState`'s on-screen concerns (zoom, display, page-size UI). It is a thin,
/// deterministic wrapper — `DocumentState`/`ExportEngine` remain the app's own UI-facing
/// layer on top of it, not a caller of it, so the windowed app keeps its Modern-PDF/AppKit
/// divergence unaffected.
public enum DocumentOperations {

    // MARK: - Errors

    public enum OperationError: Error, LocalizedError, Sendable {
        case notConvertible(variant: Variant, reason: String)
        case unknownFormat(name: String, known: [String])

        public var errorDescription: String? {
            switch self {
            case .notConvertible(let variant, let reason):
                return "Not a convertible WordStar-era document (detected \(variant.rawValue): \(reason))."
            case .unknownFormat(let name, let known):
                return "Unknown format \"\(name)\" (known: \(known.joined(separator: ",")))."
            }
        }
    }

    // MARK: - Page-settings presets

    /// The CLI's three named `--page-settings` presets (`Arguments.swift`'s `pagePresets`),
    /// reproduced verbatim so a caller can request "sawyer" without hand-building margins.
    public enum PageSettingsPreset: String, CaseIterable, Sendable {
        case `default`
        case sawyer
        case modern

        public var settings: PageSettings {
            switch self {
            case .default: return PageSettings()
            case .sawyer:  return PageSettings(mtLines: 1195.0 / 1440.0 * 6.0, mbLines: 6.0, poCols: 7.0)
            case .modern:  return PageSettings(mtLines: 6.0, mbLines: 6.0, poCols: 10.0)
            }
        }

        /// The ruled AppleScript vocabulary (`SoftReturn.sdef`'s `settings preset`
        /// enumeration: "factory" / "sawyer" / "modern", Title Cased), NOT the Swift
        /// case names verbatim — the single source both the bottom bar's Margins popup
        /// and the View ▸ Margins submenu (job 314) show, so a person sees the same words in
        /// every surface and the Script Editor's dictionary. Job 315: "Modern Defaults" ->
        /// "Modern" — semantics unchanged, only the word.
        public var displayName: String {
            switch self {
            case .default: return "Factory"
            case .sawyer:  return "Sawyer"
            case .modern:  return "Modern"
            }
        }

        /// The full margins vocabulary a person chooses from: "Embedded" (`nil`, no
        /// preset) plus every named preset, in the one order the bottom bar's Margins
        /// popup and Settings' own Quick Look Margins pulldown (job 315) both show it in —
        /// one list feeding two menus, so they cannot drift apart.
        public static let embeddedChoiceName = "Embedded"
        public static var marginsChoiceNames: [String] { [embeddedChoiceName] + allCases.map(\.displayName) }
    }

    // MARK: - Open

    /// One opened document: the bytes, what the detector said, which variant actually
    /// parsed it (the forced one, if given — the detector's own answer otherwise), and the
    /// parse itself.
    public struct OpenedDocument: Sendable {
        public let data: [UInt8]
        public let detection: Detection
        public let variant: Variant
        public let document: CtrlKD.Document
    }

    /// Detect, then parse — optionally under a forced `variant`, exactly like `sr --variant`
    /// and the app's own "Force Variant" menu (`DocumentState.setVariant(_:)`).
    public static func open(data: [UInt8], variant: Variant? = nil) throws -> OpenedDocument {
        let detection = detect(data)
        do {
            let document = try parse(data, variant: variant)
            return OpenedDocument(
                data: data, detection: detection,
                variant: variant ?? detection.variant, document: document)
        } catch let ParseError.notConvertible(v, reason, _) {
            throw OperationError.notConvertible(variant: v, reason: reason)
        }
    }

    // MARK: - Convert

    public struct ConversionOptions: Sendable {
        /// Library emitter names — "text", "markdown", "html", "rtf", "pdf" (also "layout").
        public var formats: [String]
        /// Style: `.modern` reflows for reading, `.printed` reproduces the page — the
        /// app's `RenderStyle` under the library's own name.
        public var mode: EmitMode
        /// Forced variant, `nil` for auto-detect.
        public var variant: Variant?
        public var title: String
        public var notes: Set<NoteKind>
        public var styles: Bool
        /// Default `.mac`, NOT the library's own `EmitOptions` default (`.office`) — this
        /// layer's doc comment above says its surface is shaped like `sr`'s own options, and
        /// `sr` itself defaults to `.mac` (D7 ruling, `Arguments.swift`: "sr defaults to MAC
        /// font names -- it is the Mac tool"). Job 262 (`output-parity`): this struct's own
        /// default silently disagreed with the CLI it claims to mirror — every production
        /// caller already overrode it to `.mac` by hand, which is exactly how a wrong default
        /// hides until something calls this layer bare.
        public var fontsTarget: FontsTarget
        public var pageSettings: PageSettings?
        public var noteRefs: NoteRefs
        /// b24 views wave, job 371 item 0 (PICTURE WIRING): the source document's own path,
        /// so `.PIX` tags can be resolved against real siblings/ancestors near it
        /// (`DocumentPictures.resolve`, the app's own Foundation-based port of the engine's
        /// `resolveDocumentPictures` — see that type's header for why the app can't call the
        /// engine's copy directly). Empty (the default) means "no location to search from" —
        /// every `.PIX` tag then reports `.unresolved` and the plain `[image: NAME]`
        /// placeholder shows, exactly the pre-wiring behavior, so a caller with no real file
        /// on disk (bytes-only Intents input, a library caller) is unaffected.
        public var docPath: String
        /// Job 373 (b24 FLAG UI): the export-sheet/AppleScript-visible half of the b24 flag
        /// wave (rounds 17-18 — see `EmitOptions`' own field comments for what each governs).
        /// Defaults mirror `EmitOptions`' own ruled defaults exactly (headers ON, TOC OFF,
        /// pictures Embed, inline styling ON) — this layer's own doc comment already promises
        /// its surface is shaped like `sr`'s, and `sr` itself takes these flags at these same
        /// defaults.
        public var headers: Bool
        public var toc: Bool
        public var inlineStyling: Bool
        public var pictures: EmitOptions.PixMode
        /// Job 504 (AppleScript CLI parity): the document's own `.l#` line-number gutter
        /// in the paged surfaces — `EmitOptions.lineNumbers` (the CLI's `--line-numbers`),
        /// threaded through here the same way `styles`/`fontsTarget` already are. Default
        /// true, matching `EmitOptions`' own ruled default.
        public var lineNumbers: Bool
        /// Job 506 (b31, AppleScript CLI parity): WordStar's own AUTOMATIC page number —
        /// `EmitOptions.pageNumbers` (the CLI's `--page-numbers`), threaded through here the
        /// same way `lineNumbers` above is. Default `.auto`, matching `EmitOptions`' own
        /// ruled default.
        public var pageNumbers: EmitOptions.PageNumberMode
        /// Job 521 (N9, b33, AppleScript CLI parity): the typewriter double space after a
        /// sentence-ending `.`/`?`/`!` — `EmitOptions.sentenceSpacing` (the CLI's
        /// `--sentence-spacing`), threaded through here the same way `pageNumbers` above is.
        /// Default `.auto`, matching `EmitOptions`' own default — but unlike `pageNumbers`
        /// there is deliberately no Settings-backed default for this one (Jon's ruling).
        public var sentenceSpacing: EmitOptions.SentenceSpacingMode

        public init(
            formats: [String], mode: EmitMode = .modern, variant: Variant? = nil,
            title: String = "", notes: Set<NoteKind> = EmitOptions.defaultNotes,
            styles: Bool = true, fontsTarget: FontsTarget = .mac,
            pageSettings: PageSettings? = nil, noteRefs: NoteRefs = .word, docPath: String = "",
            headers: Bool = true, toc: Bool = false, inlineStyling: Bool = true,
            pictures: EmitOptions.PixMode = .embed, lineNumbers: Bool = true,
            pageNumbers: EmitOptions.PageNumberMode = .auto,
            sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
        ) {
            self.formats = formats
            self.mode = mode
            self.variant = variant
            self.title = title
            self.notes = notes
            self.styles = styles
            self.fontsTarget = fontsTarget
            self.pageSettings = pageSettings
            self.noteRefs = noteRefs
            self.docPath = docPath
            self.headers = headers
            self.toc = toc
            self.inlineStyling = inlineStyling
            self.pictures = pictures
            self.lineNumbers = lineNumbers
            self.pageNumbers = pageNumbers
            self.sentenceSpacing = sentenceSpacing
        }
    }

    public struct ConvertedFile: Sendable {
        public let format: String
        public let bytes: [UInt8]

        /// Without the leading dot — `Emitter.ext` carries one (".txt"), but
        /// `uniqueFileName(basename:extension:exists:)` adds its own, Finder-style.
        public var fileExtension: String {
            let ext = EmitterRegistry.standard.getEmitter(format)?.ext ?? format
            return ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        }
    }

    /// Convert `data` to every format in `options.formats`.
    ///
    /// Parses once under the forced (or auto) variant, applies `pageSettings` once to the
    /// resolved page, then hands the SAME parsed document to every requested emitter — the
    /// exact sequence `sr`'s `Run.swift` follows, so a caller forcing `--variant` gets the
    /// same document out of every format rather than re-detecting per format. (The free
    /// `convertData(_:to:mode:options:)` front door does not accept a variant, which is why
    /// this calls the registry's emitters directly instead.)
    ///
    /// PDF here is always the library's own `emitPDF` (Courier-only) — the app's
    /// Modern-PDF-through-AppKit divergence (`ExportEngine.modernPDF`) needs
    /// `NSGraphicsContext`, so it stays app-only; a headless caller gets the library's own
    /// PDF, which is a documented difference, not a bug.
    public static func convert(data: [UInt8], options: ConversionOptions) throws -> [ConvertedFile] {
        var doc = try open(data: data, variant: options.variant).document
        if let pageSettings = options.pageSettings, let page = doc.page {
            doc.page = effectivePage(page, settings: pageSettings)
        }
        // Resolve once per document, reused across every requested format — see
        // `DocumentPictures.resolve`'s own doc comment for why this can't be the engine's
        // `resolveDocumentPictures` directly.
        let pixResults = DocumentPictures.resolve(doc, docPath: options.docPath)

        var results: [ConvertedFile] = []
        for format in options.formats {
            guard let emitter = EmitterRegistry.standard.getEmitter(format) else {
                throw OperationError.unknownFormat(
                    name: format, known: EmitterRegistry.standard.formats())
            }
            let output = emitter.emit(doc, options.mode, EmitOptions(
                title: options.title, notes: options.notes, styles: options.styles,
                fontsTarget: options.fontsTarget, noteRefs: options.noteRefs,
                headers: options.headers, lineNumbers: options.lineNumbers, toc: options.toc,
                inlineStyling: options.inlineStyling,
                pictures: options.pictures, pageNumbers: options.pageNumbers,
                sentenceSpacing: options.sentenceSpacing, pixResults: pixResults))
            results.append(ConvertedFile(format: format, bytes: output.asBytes))
        }
        return results
    }

    // MARK: - Diagnose

    public struct DiagnosisResult: Sendable {
        public let variant: Variant
        /// The library's own pagination count — see `pageCount(data:variant:)`. `nil` only
        /// when the bytes don't parse at all (`variant == .binary`, `ParseError
        /// .notConvertible`); `ws4`/`ws5+`, `printstream` and `text` all paginate.
        public let pageCount: Int?
        /// The dot commands `parseWS` observed in the file, in file order.
        public let dotCommands: [String]
        /// Total occurrences of every code `parseWS` did not recognize, summed across all
        /// unrecognized byte values — `documentInfo`'s `unknown_codes` is keyed per byte;
        /// this is that dictionary's values added together, the single number a Shortcuts
        /// user wants ("how much of this file did we not understand").
        public let unknownCodeCount: Int
        /// The full report, for a caller that wants more than the three fields above.
        public let info: InfoValue

        public var hasDotCommands: Bool { !dotCommands.isEmpty }
    }

    /// `documentInfo`, plus the figures a caller that doesn't want to walk `InfoValue` by
    /// hand needs flattened out: page count, dot-commands list, and a summed unknown-code
    /// count. Never throws — `documentInfo` itself has an answer for every byte sequence,
    /// including empty and binary ones (shape 1/2/3, see `Info.swift`'s doc comment), which
    /// is exactly what "Diagnose" is for: it must say something about a file "Convert"
    /// would refuse.
    ///
    /// Job 373 (b24 FLAG UI, discoverability rule): `pixResults`, when the caller already has
    /// one (`DocumentState.pixResults`, resolved once per parse — see `DocumentPictures
    /// .resolve`'s own doc comment), reaches `documentInfo`'s own `pix` field so the
    /// Document Info window reports each `.PIX` tag's REAL resolved-or-not state, not the
    /// pessimistic "every tag unresolved" `documentInfo` falls back to for a bytes-only
    /// caller with no location to search from (`nil`, the default, preserves that fallback —
    /// the CLI's `--diagnose` and every other headless caller here are unaffected).
    public static func diagnose(data: [UInt8], path: String? = nil,
                                pixResults: [PixResult]? = nil) -> DiagnosisResult {
        let detection = detect(data)
        let info = documentInfo(data, path: path, pixResults: pixResults)

        var dotCommands: [String] = []
        var unknownCount = 0
        if case .object(let fields) = info {
            if case .array(let arr)? = fields["dot_commands"] {
                dotCommands = arr.compactMap { value -> String? in
                    if case .string(let s) = value { return s }
                    return nil
                }
            }
            if case .object(let codes)? = fields["unknown_codes"] {
                unknownCount = codes.values.reduce(into: 0) { sum, value in
                    if case .int(let n) = value { sum += n }
                }
            }
        }

        // Diagnose "never throws" by design (see this function's doc comment) — an unpaginable
        // file is exactly the kind of thing Diagnose exists to say something about anyway, so
        // a nil page count is a legitimate field of the result, not a swallowed failure.
        let pages = try? pageCount(data: data, variant: detection.variant)

        return DiagnosisResult(
            variant: detection.variant, pageCount: pages,
            dotCommands: dotCommands, unknownCodeCount: unknownCount, info: info)
    }

    // MARK: - Page count

    /// The library's own pagination — `docToPagelines(doc, printed: true).count`, the same
    /// call `emitLayout` and the app's Printed-style renderer (`DocumentRenderer`) make.
    ///
    /// Deliberately NOT the app's Modern-style page count: that number only exists after
    /// AppKit reflows the text at a user-chosen font in a live view (see
    /// `DocumentRenderer.renderModern`'s `pageCount: 1` placeholder), which no headless
    /// caller — an Intent, the Spotlight importer, a future AppleScript call — can produce
    /// without hosting a window. Printed pagination is the one page count that exists
    /// before any UI does, so it is the one this layer reports.
    public static func pageCount(data: [UInt8], variant: Variant? = nil) throws -> Int {
        let opened = try open(data: data, variant: variant)
        return max(1, docToPagelines(opened.document, printed: true).count)
    }

    // MARK: - Naming

    /// Finder's own collision rule, so a headless caller (an Intent, a future AppleScript
    /// call) never overwrites a file the same way the windowed app's Export As sheet and
    /// Batch window never do — see `ExportEngine.uniqueName`, the app-side twin of this
    /// exact rule. Kept here too because `ExportEngine` is `@MainActor` (its Modern-PDF path
    /// needs AppKit) and an Intent's `perform()` runs off the main actor.
    public static func uniqueFileName(basename: String, extension ext: String,
                                      exists: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let first = basename + suffix
        guard exists(first) else { return first }
        var counter = 2
        while true {
            let candidate = "\(basename) \(counter)\(suffix)"
            if !exists(candidate) { return candidate }
            counter += 1
            if counter > 10_000 { return candidate }
        }
    }

    // MARK: - Plain text content (Spotlight indexing)

    /// Modern-mode plain text: searchable words, not control bytes — the "text" emitter
    /// already strips dot commands, note markers and page furniture. This is the source
    /// Spotlight indexing reads (see `SpotlightIndexing`) rather than the raw bytes or the
    /// Printed facsimile, which would index page-break padding and column rules as if they
    /// were words.
    public static func plainTextContent(data: [UInt8], variant: Variant? = nil) throws -> String {
        let opened = try open(data: data, variant: variant)
        guard let emitter = EmitterRegistry.standard.getEmitter("text") else {
            throw OperationError.unknownFormat(
                name: "text", known: EmitterRegistry.standard.formats())
        }
        return emitter.emit(opened.document, .modern, EmitOptions()).asText ?? ""
    }
}
