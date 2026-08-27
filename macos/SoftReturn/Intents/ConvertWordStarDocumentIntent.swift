import AppIntents
import CtrlKD
import Foundation

/// Shortcuts' "Convert WordStar Document" — a thin parameter/file translation over
/// `DocumentOperations.convert(data:options:)`. No conversion logic lives here; this file's
/// only job is turning Shortcuts' `IntentFile`s into bytes, handing them to the shared
/// layer, and turning the results back into `IntentFile`s to hand back.
struct ConvertWordStarDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert WordStar Document"
    static let description = IntentDescription(
        "Converts one or more WordStar-era documents to text, Markdown, HTML, RTF, or PDF.")

    // Job 342 (b23 floor drop): `@Parameter(title:supportedContentTypes:)` for an
    // `IntentFile`/`[IntentFile]` property resolves to an initializer that is macOS 15+ only
    // (measured via `swiftc -target arm64-apple-macos13.0 -typecheck` — the plain
    // `@Parameter(title:)` form typechecks clean at 13.0, the `supportedContentTypes:` form
    // does not, on ANY target including 14.0). No dual-path is possible here (a stored
    // property's wrapper can't vary by runtime availability), and no macOS-13-compatible
    // equivalent exists — so `supportedContentTypes` is dropped everywhere in this file. This
    // only removes Shortcuts' own file-picker UI filtering; `perform()` below already rejects
    // non-WordStar bytes via `DocumentOperations.convert`'s own `OperationError`, so the real
    // feature (refusing to convert a non-WordStar file) is unaffected on any OS version.
    @Parameter(title: "Documents")
    var files: [IntentFile]

    @Parameter(title: "Output Formats")
    var formats: [ConversionFormat]

    @Parameter(title: "Style", default: .modern)
    var style: ConversionStyle

    @Parameter(
        title: "Destination Folder",
        description: "Leave empty to hand the results to the next Shortcuts action without saving them anywhere first.")
    var destinationFolder: IntentFile?

    /// Job 373 (b24 FLAG UI): the export-sheet's own four flags, as optional Shortcuts
    /// parameters — omitted (`nil`) means "Settings' own default", read live in `perform()`,
    /// never a value baked in at declaration time.
    @Parameter(title: "Headers and Footers")
    var headers: Bool?

    @Parameter(title: "Table of Contents")
    var tableOfContents: Bool?

    @Parameter(title: "Inline Styling")
    var inlineStyling: Bool?

    @Parameter(title: "Pictures")
    var pictures: ConversionPictures?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$formats), \(\.$style) style") {
            \.$destinationFolder
            \.$headers
            \.$tableOfContents
            \.$inlineStyling
            \.$pictures
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard !formats.isEmpty else {
            throw ConversionIntentError.noFormatsSelected
        }

        let settings = SettingsStore.shared
        let resolvedHeaders = headers ?? settings.defaultHeaders
        let resolvedTOC = tableOfContents ?? settings.defaultTOC
        let resolvedInlineStyling = inlineStyling ?? settings.defaultInlineStyling
        let resolvedPictures = (pictures.map(\.pixMode)) ?? settings.defaultPictures

        var outputs: [IntentFile] = []
        for file in files {
            let bytes = [UInt8](file.data)
            let basename = (file.filename as NSString).deletingPathExtension
            // fontsTarget pinned to `.mac` — mistake-registry #24: a Mac app's user-facing
            // RTF fonttbl always uses the mac mapping, never the library's `.office` default.
            let options = DocumentOperations.ConversionOptions(
                formats: formats.map(\.libraryFormatName),
                mode: style.emitMode,
                title: basename,
                fontsTarget: .mac,
                docPath: file.fileURL?.path ?? "",
                headers: resolvedHeaders, toc: resolvedTOC, inlineStyling: resolvedInlineStyling,
                pictures: resolvedPictures)

            let converted: [DocumentOperations.ConvertedFile]
            do {
                converted = try DocumentOperations.convert(data: bytes, options: options)
            } catch let error as DocumentOperations.OperationError {
                throw ConversionIntentError.conversionFailed(file: file.filename, underlying: error)
            }

            // Job 218: this used to fall back to `file.fileURL?.deletingLastPathComponent()`
            // — writing beside the source — before finally trying `temporaryDirectory`. Per
            // `docs/reference/apple/sandbox-file-writes-packet.md` ("What a user-selected
            // grant covers"), a folder the user actually picked (`destinationFolder`, the
            // Shortcuts step's own `.folder`-typed parameter) is the ONLY thing here that
            // carries a real grant; the SOURCE file's own URL, however it reached this
            // intent, grants that file, never its enclosing folder.
            //
            // App Intents' file-grant rule verified here differs from AppleScript's in one
            // load-bearing way this fix leans on: `file.data` (used above, unconditionally)
            // already hands over the source's BYTES directly — confirmed by this file's own
            // pre-existing, compiling use of it, not by a doc citation this job could pull
            // (the AppIntents swiftinterface on this worker has no prose doc comments, and a
            // full manual scan for `IntentFile`'s declaration proved cost-prohibitive — see
            // the job report's "unverified" note). Cocoa Scripting's file arguments, by
            // contrast, hand over a URL that must itself be read through a security scope
            // (`ScriptingFileArgument.readData`). Since no URL-level read grant is needed
            // here, dropping straight to a no-grant-required default when `destinationFolder`
            // is omitted is the same shape as `ConvertCommand`'s fix, minus a read-side
            // security-scope bracket App Intents doesn't need.
            let directory = destinationFolder?.fileURL ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            for product in converted {
                let name = DocumentOperations.uniqueFileName(
                    basename: basename, extension: product.fileExtension
                ) { candidate in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(candidate).path)
                }
                let url = directory.appendingPathComponent(name)
                try Data(product.bytes).write(to: url, options: .atomic)
                outputs.append(IntentFile(fileURL: url, filename: name))
            }
        }
        return .result(value: outputs)
    }
}

enum ConversionIntentError: Error, LocalizedError {
    case noFormatsSelected
    case conversionFailed(file: String, underlying: DocumentOperations.OperationError)

    var errorDescription: String? {
        switch self {
        case .noFormatsSelected:
            return "Choose at least one output format."
        case .conversionFailed(let file, let underlying):
            return "Couldn’t convert \"\(file)\": \(underlying.errorDescription ?? "unknown error")."
        }
    }
}
