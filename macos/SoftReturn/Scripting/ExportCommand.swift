import AppKit
import CtrlKD
import Foundation

/// `export document 1 to file ... as RTF using style modern with footnotes ...` —
/// `SoftReturn.sdef`'s `export` command. One document, one output file, exactly the
/// CLI's single-file conversion (`sr FILE -t FORMAT -o OUT`).
///
/// Job 254 (`export-specifier`): this used to be an `NSScriptCommand` subclass bound via
/// `<cocoa class="...">` with its own `performDefaultImplementation()`, decoding
/// `directParameter as? WSDocument`. Job 252's field probe (`AppleEventSelfSendProbe
/// .performExport`) proved that cast never succeeds against a real Apple Event — export's
/// direct-parameter is an OBJECT (`type="document"`), and Cocoa never hands the resolved
/// object (or even the unevaluated specifier — Candidate A, evaluating it by hand inside
/// `performDefaultImplementation()`, did not fix it either) to a custom command class at
/// all. The actual conversion logic now lives on `WSDocument.handleExportScriptCommand(_:)`
/// (`WSDocument+Scripting.swift`), reached via `<responds-to>` on the `document` class —
/// the same receiver-dispatch mechanism `close`/`print`/`save` already use successfully.
/// This type is now just the pure, independently testable argument decoder
/// (`ExportCommandTests` exercises it directly, without any live Apple Event or command
/// object) that handler calls into.
enum ExportCommand {
    struct Arguments: Equatable {
        var destination: URL
        var format: String
        var mode: EmitMode
        /// Job 313B: the honest three-case style the `using style` argument (or, omitted,
        /// the document's own current style) actually resolved to — `mode` above stays the
        /// two-case collapse (`viewStyle.renderStyle.emitMode`) every non-PDF format and the
        /// library's own literal-Printed PDF still use; PDF alone also consults this field,
        /// to route through the print path when it is `.native` (`WSDocument
        /// .handleExportScriptCommand`).
        var viewStyle: ViewStyle
        var notes: Set<NoteKind>
        var noteRefs: NoteRefs
        var pageSettings: PageSettings?
        /// Job 373 (b24 FLAG UI): the export-sheet's own four flags. Their sdef parameters
        /// are optional — omitted means "Settings' own default", which the CALLER supplies
        /// (`decode`'s own `default*` parameters below) rather than this pure argument
        /// decoder reading `SettingsStore.shared` itself (kept free of `@MainActor`, exactly
        /// like `documentStyle`'s own caller-supplied-fallback shape above). Defaulted here
        /// too (matching `EmitOptions`' own ruled defaults), same reason as `ConvertCommand
        /// .Arguments`' own identical fields.
        var headers: Bool = true
        var toc: Bool = false
        var inlineStyling: Bool = true
        var pictures: EmitOptions.PixMode = .embed
        /// Job 504: the sdef's `line numbers` parameter — `EmitOptions.lineNumbers`/the
        /// CLI's `--line-numbers`. Default true, a plain literal (unlike `headers`/`toc`/
        /// `inlineStyling`/`pictures` above, this has no Settings-backed export-sheet UI
        /// default to fall back to — same shape as `noteRefs`'s own literal default below).
        var lineNumbers: Bool = true
        /// Job 504: the sdef's `styles` parameter — `EmitOptions.styles`/the CLI's
        /// `--no-styles`. Default true, same plain-literal shape as `lineNumbers` above.
        var styles: Bool = true
        /// Job 504: the sdef's `fonts` parameter — `EmitOptions.fontsTarget`/the CLI's
        /// `--fonts`. Default `.mac`, matching the app's own hardcoded call site this
        /// replaces (`WSDocument.handleExportScriptCommand`) — no longer a ceiling.
        var fontsTarget: FontsTarget = .mac
        /// Job 506 (b31): the sdef's `page numbers` parameter — `EmitOptions.pageNumbers`/
        /// the CLI's `--page-numbers`. Job 520 (N5): omitted now means "Settings' own
        /// default" (the caller-supplied `decode`'s `defaultPageNumbers` parameter below),
        /// the same shape as `headers`/`toc`/`inlineStyling`/`pictures` above — no longer a
        /// plain `.auto` literal.
        var pageNumbers: EmitOptions.PageNumberMode = .auto
        /// Job 521 (N9, b33): the sdef's `sentence spacing` parameter —
        /// `EmitOptions.sentenceSpacing`/the CLI's `--sentence-spacing`. Unlike `pageNumbers`
        /// above, this has no Settings-backed export-sheet UI default to fall back to (Jon's
        /// ruling: no Settings item) — a plain literal default, same shape as `lineNumbers`/
        /// `styles` above.
        var sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    }

    enum DecodeError: Error, LocalizedError, Equatable {
        case missingDestination
        case missingFormat
        case unknownFormat

        var errorDescription: String? {
            switch self {
            case .missingDestination: return "export needs a destination file (\"to\")."
            case .missingFormat: return "export needs a format (\"as\")."
            case .unknownFormat: return "export was given a format it doesn't recognize."
            }
        }
    }

    /// Pure argument decoding: no Apple Event dispatch, no file I/O — everything an
    /// `ExportCommandTests` fake can hand it directly. `documentStyle` is the fallback
    /// when `using style` is omitted ("the document's current style", per the dictionary) —
    /// job 313B: now the document's honest three-case `ViewStyle`, not a pre-collapsed
    /// `EmitMode`, so an omitted `using style` on a Native-viewing document actually reports
    /// (and, for PDF, exports) Native rather than silently landing on Printed.
    static func decode(
        arguments: [String: Any], documentStyle: ViewStyle,
        defaultHeaders: Bool = true, defaultTOC: Bool = false, defaultInlineStyling: Bool = true,
        defaultPictures: EmitOptions.PixMode = .embed,
        defaultPageNumbers: EmitOptions.PageNumberMode = .auto
    ) throws -> Arguments {
        guard let destination = arguments["scriptingDestination"] else {
            throw DecodeError.missingDestination
        }
        let url = try ScriptingFileArgument.url(from: destination)

        guard let formatNumber = arguments["scriptingFormat"] as? NSNumber else {
            throw DecodeError.missingFormat
        }
        guard let format = ScriptingEnumCoding.libraryFormat(forCode: formatNumber.uint32Value) else {
            throw DecodeError.unknownFormat
        }

        var viewStyle = documentStyle
        if let styleNumber = arguments["scriptingStyle"] as? NSNumber,
           let decoded = ScriptingEnumCoding.style(forCode: styleNumber.uint32Value) {
            viewStyle = decoded
        }
        // Every non-PDF format, and PDF for anything but a genuinely Native view, still goes
        // through the library's own two-case `EmitMode` — `native` collapses to `printed`
        // here exactly as the sdef documents ("every other format -> identical to printed").
        let mode = viewStyle.renderStyle.emitMode

        var notes = EmitOptions.defaultNotes
        setNote(.footnote, in: &notes, from: arguments["scriptingFootnotes"] as? Bool)
        setNote(.endnote, in: &notes, from: arguments["scriptingEndnotes"] as? Bool)
        setNote(.annotation, in: &notes, from: arguments["scriptingAnnotations"] as? Bool)
        setNote(.comment, in: &notes, from: arguments["scriptingComments"] as? Bool)

        var noteRefs = NoteRefs.word
        if let refsNumber = arguments["scriptingNoteReferences"] as? NSNumber,
           let decoded = ScriptingEnumCoding.noteRefs(forCode: refsNumber.uint32Value) {
            noteRefs = decoded
        }

        let pageSettings = PageSettingsScripting.resolve(arguments["scriptingPageSettings"])

        let headers = (arguments["scriptingHeaders"] as? Bool) ?? defaultHeaders
        let toc = (arguments["scriptingTOC"] as? Bool) ?? defaultTOC
        let inlineStyling = (arguments["scriptingInlineStyling"] as? Bool) ?? defaultInlineStyling
        var pictures = defaultPictures
        if let picturesNumber = arguments["scriptingPictures"] as? NSNumber,
           let decoded = ScriptingEnumCoding.picturesMode(forCode: picturesNumber.uint32Value) {
            pictures = decoded
        }

        let lineNumbers = (arguments["scriptingLineNumbers"] as? Bool) ?? true
        let styles = (arguments["scriptingStyles"] as? Bool) ?? true
        var fontsTarget = FontsTarget.mac
        if let fontsNumber = arguments["scriptingFontsTarget"] as? NSNumber,
           let decoded = ScriptingEnumCoding.fontsTarget(forCode: fontsNumber.uint32Value) {
            fontsTarget = decoded
        }
        var pageNumbers = defaultPageNumbers
        if let pageNumbersNumber = arguments["scriptingPageNumbers"] as? NSNumber,
           let decoded = ScriptingEnumCoding.pageNumbersMode(forCode: pageNumbersNumber.uint32Value) {
            pageNumbers = decoded
        }
        var sentenceSpacing = EmitOptions.SentenceSpacingMode.auto
        if let sentenceSpacingNumber = arguments["scriptingSentenceSpacing"] as? NSNumber,
           let decoded = ScriptingEnumCoding.sentenceSpacingMode(forCode: sentenceSpacingNumber.uint32Value) {
            sentenceSpacing = decoded
        }

        return Arguments(
            destination: url, format: format, mode: mode, viewStyle: viewStyle, notes: notes,
            noteRefs: noteRefs, pageSettings: pageSettings,
            headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
            lineNumbers: lineNumbers, styles: styles, fontsTarget: fontsTarget,
            pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)
    }

    /// Job 504: `internal`, not `private` — `ConvertCommand.decode` reuses this exact
    /// with/without-a-kind rule for its own new footnotes/endnotes/annotations/comments
    /// parameters, rather than re-deriving it.
    static func setNote(_ kind: NoteKind, in notes: inout Set<NoteKind>, from flag: Bool?) {
        guard let flag else { return }
        if flag { notes.insert(kind) } else { notes.remove(kind) }
    }

    /// Job 504 (Jon's ruling, verbatim: "AppleScript overwrite should handle it like a Mac
    /// would: add a ' 2' to the end of the filename (before extension)"): scripted `export`
    /// never clobbers a pre-existing file at the requested destination — on collision this
    /// reuses `DocumentOperations.uniqueFileName`'s Finder-style counter (the same rule
    /// `convert`'s `to folder` path and a re-downloaded update already use) to find "NAME
    /// 2.ext", then "NAME 3.ext", and so on. Pure and file-system-free (`exists` is
    /// caller-supplied, exactly `uniqueFileName`'s own shape) so this is testable without
    /// touching disk; `WSDocument.handleExportScriptCommand` supplies a real
    /// `FileManager.fileExists` check.
    static func uniqueDestination(for destination: URL, exists: (URL) -> Bool) -> URL {
        let directory = destination.deletingLastPathComponent()
        let basename = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let name = DocumentOperations.uniqueFileName(basename: basename, extension: ext) { candidate in
            exists(directory.appendingPathComponent(candidate))
        }
        return directory.appendingPathComponent(name)
    }
}
