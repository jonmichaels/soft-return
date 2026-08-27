import CoreServices
import CtrlKD
import Foundation

/// `convert {POSIX file "..."} to folder ... as {RTF, PDF} using style printed with
/// searching subfolders` — `SoftReturn.sdef`'s `convert` command, the CLI's `-d` batch
/// mode: app-level, no windows, every input converted independently through
/// `DocumentOperations.convert`. Walking folders and tracking produced/skipped/failed
/// is orchestration the CLI's own `Run.swift` does too — it is not conversion logic, so
/// it stays here rather than pushing filesystem concerns into the shared layer.
final class ConvertCommand: NSScriptCommand {
    struct Arguments: Equatable {
        var inputs: [URL]
        var destinationFolder: URL?
        var formats: [String]
        /// "Omitted: each document's current/detected style" only makes sense for an open
        /// document (`export`'s rule); a headless batch input has no "current style" to
        /// fall back to, so an omitted `using style` here defaults to Modern — the same
        /// default `DocumentOperations.ConversionOptions.mode`/the bare CLI use.
        var mode: EmitMode
        var searchingSubfolders: Bool
        var forcingVariant: Variant?
        var pageSettings: PageSettings?
        /// Job 504: `convert` gains the same footnotes/endnotes/annotations/comments
        /// switches `export` already has — same default (footnotes/endnotes/annotations
        /// on, comments off) as `EmitOptions.defaultNotes`.
        var notes: Set<NoteKind> = EmitOptions.defaultNotes
        /// Job 373 (b24 FLAG UI): the export-sheet's own four flags — see `ExportCommand
        /// .Arguments`' own doc comment for why the default comes from the caller
        /// (`decode`'s `default*` parameters), not this type reading `SettingsStore.shared`
        /// itself. Defaulted here too (matching `EmitOptions`' own ruled defaults) so every
        /// existing direct `Arguments(...)` construction (tests predating this job) keeps
        /// compiling unchanged.
        var headers: Bool = true
        var toc: Bool = false
        var inlineStyling: Bool = true
        var pictures: EmitOptions.PixMode = .embed
        /// Job 504: the sdef's `line numbers` parameter — see `ExportCommand.Arguments`'s
        /// own field for why this is a plain literal default, not Settings-backed.
        var lineNumbers: Bool = true
        /// Job 504: the sdef's `styles` parameter — see `ExportCommand.Arguments`'s own
        /// field for why this is a plain literal default, not Settings-backed.
        var styles: Bool = true
        /// Job 504: the sdef's `fonts` parameter — see `ExportCommand.Arguments`'s own
        /// field for why `.mac` is the default, not `EmitOptions`' own `.office`.
        var fontsTarget: FontsTarget = .mac
        /// Job 506 (b31): the sdef's `page numbers` parameter — `EmitOptions.pageNumbers`/
        /// the CLI's `--page-numbers`. Job 520 (N5): omitted now means "Settings' own
        /// default" (the caller-supplied `decode`'s `defaultPageNumbers` parameter below),
        /// the same shape as `headers`/`toc`/`inlineStyling`/`pictures` above — no longer a
        /// plain `.auto` literal.
        var pageNumbers: EmitOptions.PageNumberMode = .auto
        /// Job 521 (N9, b33): the sdef's `sentence spacing` parameter — see `ExportCommand
        /// .Arguments`'s own field for why this is a plain literal default, not
        /// Settings-backed (Jon's ruling: no Settings item for this one).
        var sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    }

    /// Job 216 (b12 leg A, ae-result-shape): `produced` replaces the old `converted` count —
    /// every OUTPUT file actually written (one input can produce several, one per requested
    /// format), not a per-input tally. This is the list whose paths `performDefaultImplementation`
    /// joins into `SoftReturn.sdef`'s `convert` reply (job 241: `<result type="text">`, see that
    /// method's own doc comment for why); `skipped`/`failed` stay for the scriptErrorString
    /// `performDefaultImplementation` raises when NOTHING converts (see there), but are no
    /// longer part of the reply itself.
    struct Result: Equatable {
        var produced: [URL] = []
        var skipped = 0
        var failed: [URL] = []
        /// Job 218: set when the destination itself couldn't be secured, so a bad
        /// destination never gets folded silently into `failed` per file (the fix model's
        /// "never silently failed"). `to folder` checks this once, before any file is
        /// touched. Job 253: a bare destination (no `to folder`) has no single directory to
        /// pre-check — this is set after the loop instead, from the first
        /// `BesideSourceWriter` failure, only when nothing converted at all.
        var destinationAccessError: String?
    }

    enum DecodeError: Error, LocalizedError, Equatable {
        case missingInputs
        case missingFormats
        case nothingConverted(skipped: Int, failed: Int)
        case destinationNotWritable(String)
        case besideSourceWriteFailed(source: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .missingInputs: return "convert needs at least one file or folder."
            case .missingFormats: return "convert needs at least one format (\"as\")."
            case .nothingConverted(let skipped, let failed):
                return "convert produced no output (skipped: \(skipped), failed: \(failed))."
            case .destinationNotWritable(let detail):
                return "convert couldn't write its output: \(detail)"
            case .besideSourceWriteFailed(let source, let reason):
                return "Soft Return couldn't write next to \(source); pass a destination with " +
                    "\"to folder\" (\(reason))."
            }
        }
    }

    /// Job 216 (b12 leg A): a per-instance tag, present in every breadcrumb this class
    /// records, so a field read-back can tell "why twice" apart: field breadcrumbs since
    /// job 199 show `convert` dispatching cleanly TWICE per single `osascript` invocation,
    /// but the ring buffer alone never said whether that was Cocoa constructing two
    /// `ConvertCommand` instances (e.g. a probe + the real dispatch) or one instance whose
    /// dispatch genuinely ran twice. Two "constructed" entries with the SAME tag would be
    /// the latter (impossible given `constructed` only fires from `init`, but cheap to keep
    /// as a sanity check); two entries with DIFFERENT tags confirms the former.
    ///
    /// Job 219: every `AppleEventLifecycleBreadcrumbs.record` call below is unconditional in
    /// source but a no-op by default in EVERY build, including this Release one — `record`
    /// itself checks `SRDiagnosticsGate` (see that type's header). Nothing here needs an
    /// `#if DEBUG`; a field machine that needs this evidence trail turns it on with
    /// `defaults write me.beforeti.softreturn SRDiagnostics -bool YES`, no rebuild required.
    private let instanceTag = UUID().uuidString.prefix(8)

    /// Job 237 (ae-timeline, continuing 235/236): job 235 proved `ConvertCommand` gets
    /// constructed 2-3x per single self-addressed `AESendMessage`, and job 236 disproved the
    /// leading hypothesis (a redundant `loadSuites` call) without explaining the remaining
    /// constructions. This exists to let a report reader classify each one from the OUTSIDE,
    /// without more guessing:
    ///   - `hasCurrentAppleEvent`: `NSAppleEventManager.shared().currentAppleEvent` is non-nil
    ///     ONLY while Cocoa is actively dispatching a real Apple Event on the calling thread
    ///     (`NSAppleEventManager.h`) — true here means THIS construction is happening inside a
    ///     genuine AE dispatch, not a lookalike programmatic call.
    ///   - `returnID`: that event's `keyReturnIDAttr` attribute, when present — ties a
    ///     construction back to a specific sender's send/reply pair, so two constructions from
    ///     two DIFFERENT real dispatches (vs. one dispatch producing two constructions) are
    ///     distinguishable even when `hasCurrentAppleEvent` is true for both.
    ///   - `stack`: the first 8 `Thread.callStackSymbols` frames, kept VERBATIM rather than
    ///     trimmed to a guessed "real caller" index — the same "an instrument that has only ever
    ///     returned one answer is untested" discipline job 236's `SuiteRegistrationProbe` already
    ///     established for this exact ambiguity (Swift/ObjC thunk frames vary by call site, and a
    ///     wrong guess is indistinguishable from a right one without independently knowing the
    ///     true caller).
    ///   - `mono`: `ProcessInfo.processInfo.systemUptime`, the same monotonic clock
    ///     `AppleEventSelfSendProbe`'s send/return timestamps use, so a report can merge both
    ///     sides into one ordered timeline with real deltas instead of comparing wall-clock
    ///     `Date`s across threads.
    private static func dispatchTimelineDetail(instanceTag: Substring) -> String {
        let monotonic = ProcessInfo.processInfo.systemUptime
        let currentEvent = NSAppleEventManager.shared().currentAppleEvent
        let returnID = currentEvent?.attributeDescriptor(forKeyword: AEKeyword(keyReturnIDAttr))?.int32Value
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: " <- ")
        return "instance=\(instanceTag) mono=\(monotonic) hasCurrentAppleEvent=\(currentEvent != nil) " +
            "returnID=\(returnID.map(String.init) ?? "nil") stack=\(stack)"
    }

    /// Job 222 (finding F, scriptcommand-exemplar-shape): jobs 199-216 also overrode
    /// `execute()`, `receiversSpecifier`, and `suspendExecution()`/`resumeExecution(withResult:)`
    /// to breadcrumb them, and those overrides SHIPPED IN RELEASE. Audited against real working
    /// scriptable apps (`docs/reference/apple/scriptcommand-exemplars-packet.md`, from
    /// NetNewsWire's actual source): every one of them overrides ONLY
    /// `performDefaultImplementation()` — never `execute()`, `receiversSpecifier`, or
    /// `suspendExecution()`. `NSScriptCommand.h`'s own doc comment on `-executeCommand` says
    /// it "invokes [`-performDefaultImplementation`], and it is not meant to be invoked from
    /// anywhere else" and "You should not have to override this method" — `execute()` is the
    /// method that packages a command's result into the reply, so intercepting it (even to run
    /// `super.execute()` and return its value unchanged) is a live candidate for the empty-reply
    /// -1708. Those overrides are removed; `constructed`/`pdi-entered` below stay, since reading
    /// this init and the one sanctioned override point is not the same as intercepting them.
    /// Effect on the real field -1708 is UNVERIFIED until a real cross-process `osascript` run —
    /// this change matches the exemplar shape, it does not by itself prove a fix.
    override init(commandDescription: NSScriptCommandDescription) {
        super.init(commandDescription: commandDescription)
        AppleEventLifecycleBreadcrumbs.record(
            stage: "constructed", detail: Self.dispatchTimelineDetail(instanceTag: instanceTag))
    }

    /// `SoftReturn.sdef`'s `convert` command declares `<result type="text">` (job 241, was
    /// `<result type="file" list="yes">` returning a plain `[NSURL]` — see that sdef comment
    /// for the full A/B matrix). Job 235-239b proved the real field -1708 is Cocoa's own
    /// reply-packaging trampoline reporting `errAEEventNotHandled` AFTER a command has already
    /// executed successfully, with a completely empty reply — the fourth, previously
    /// unreachable-in-process layer job 207/216 could only infer existed. Job 241 named it
    /// precisely: that trampoline cannot coerce ANY list-shaped return value into the reply,
    /// independent of the sdef's declared type (native `[NSURL]`, a hand-built `typeAEList` of
    /// `typeFileURL` descriptors, and a hand-built list returned under a scalar-declared sdef
    /// result all failed identically) — only a SCALAR reply value succeeds. `convert` is
    /// inherently a batch command that can produce more than one file, so the joined-text
    /// shape is the one tested option that both actually replies successfully AND preserves
    /// every produced path, not just the least invasive one available.
    ///
    /// Empty vs. partial vs. total failure, per the ruled shape: an empty result on its own
    /// would look identical to "nothing to do, no problem" to a script, which is wrong when
    /// every input failed — so NOTHING converting is a real script error
    /// (`scriptErrorNumber`/`scriptErrorString`), not a silent empty reply. A PARTIAL
    /// success (some produced, some skipped/failed) returns just the successes, no error —
    /// the caller has positive information (what it can now open/see); the `failed` file
    /// list this command's reply used to carry is gone, not reintroduced.
    override func performDefaultImplementation() -> Any? {
        AppleEventLifecycleBreadcrumbs.record(
            stage: "pdi-entered", detail: Self.dispatchTimelineDetail(instanceTag: instanceTag))
        do {
            // AppleEvent dispatch is guaranteed to run on the main thread (this class's own
            // extensive -1708 investigation history establishes that repeatedly) but
            // `NSScriptCommand` itself carries no static `@MainActor` isolation — `assumeIsolated`
            // states that guarantee to the compiler rather than threading `SettingsStore.shared`
            // through as yet another decode parameter this class alone would need.
            let (defaultHeaders, defaultTOC, defaultInlineStyling, defaultPictures, defaultPageNumbers) =
                MainActor.assumeIsolated {
                    let settings = SettingsStore.shared
                    return (settings.defaultHeaders, settings.defaultTOC, settings.defaultInlineStyling,
                           settings.defaultPictures, settings.defaultPageNumbers)
                }
            let args = try Self.decode(
                direct: directParameter, arguments: evaluatedArguments ?? [:],
                defaultHeaders: defaultHeaders, defaultTOC: defaultTOC,
                defaultInlineStyling: defaultInlineStyling, defaultPictures: defaultPictures,
                defaultPageNumbers: defaultPageNumbers)
            let files = Self.expand(args.inputs, searchingSubfolders: args.searchingSubfolders)
            let result = Self.convert(files: files, args: args)
            if let destinationAccessError = result.destinationAccessError {
                throw DecodeError.destinationNotWritable(destinationAccessError)
            }
            guard !result.produced.isEmpty else {
                throw DecodeError.nothingConverted(skipped: result.skipped, failed: result.failed.count)
            }
            return result.produced.map(\.path).joined(separator: "\n") as NSString
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }
    }

    /// One file's outcome is exactly `DocumentOperations.OperationError`'s own split:
    /// `.notConvertible` is "skipped" (not a WordStar-era document at all — the CLI's own
    /// per-file continue), anything else (an unreadable file, a write failure) is
    /// "failed".
    ///
    /// Job 253 (`convert-destination`): a bare `convert {...} as {...}` — no `to folder` —
    /// writes through `BesideSourceWriter`, beside the source. Job 218 (comment removed)
    /// wrote into this app's own sandbox container Documents folder by default; Jon's field
    /// ruling (2026-08-12) is that a silent divert into the container is "absolutely no good"
    /// (real repro: a Dropbox file's output landed in `~/Library/Containers/.../Documents/`,
    /// invisible next to the source the user actually opened). Un-sandboxed (job 392), the
    /// container that ruling reacted to no longer exists, but the discipline stands: a write
    /// that genuinely fails gets a named, honest error — never a silent write anywhere else.
    static func convert(files: [URL], args: Arguments) -> Result {
        var result = Result()
        var besideSourceFailure: (source: URL, reason: String)?

        // `to folder` is the blessed path (packet: a granted FOLDER covers everything
        // written inside it, recursively) — use it untouched. Confirmed ONCE, before
        // touching any file — a bad destination is an access problem, not a per-file
        // conversion failure, and must say so rather than silently counting every input as
        // "failed".
        if let directory = args.destinationFolder {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                result.destinationAccessError = "can't write to \(directory.path): \(error.localizedDescription)"
                return result
            }
        }

        for file in files {
            let data: Data
            do {
                data = try ScriptingFileArgument.readData(at: file)
            } catch {
                // Job 220: the reason is discarded here on purpose, not lost — job 216's
                // ruled reply shape carries only a count for a partial batch failure, no
                // per-file reasons; a fully-failed batch still surfaces via
                // `.nothingConverted` below.
                result.failed.append(file)
                continue
            }
            // fontsTarget defaults to `.mac` (mistake-registry #24: a Mac app's user-facing
            // RTF fonttbl defaults to the mac mapping, never the library's `.office`
            // default) but is no longer pinned there — job 504's `fonts` parameter lets a
            // script override it via `args.fontsTarget`.
            let options = DocumentOperations.ConversionOptions(
                formats: args.formats, mode: args.mode, variant: args.forcingVariant,
                title: file.deletingPathExtension().lastPathComponent,
                notes: args.notes, styles: args.styles, fontsTarget: args.fontsTarget,
                pageSettings: args.pageSettings, docPath: file.path,
                headers: args.headers, toc: args.toc, inlineStyling: args.inlineStyling,
                pictures: args.pictures, lineNumbers: args.lineNumbers,
                pageNumbers: args.pageNumbers, sentenceSpacing: args.sentenceSpacing)
            do {
                let products = try DocumentOperations.convert(data: [UInt8](data), options: options)
                let basename = file.deletingPathExtension().lastPathComponent
                if let directory = args.destinationFolder {
                    for product in products {
                        let name = DocumentOperations.uniqueFileName(
                            basename: basename, extension: product.fileExtension
                        ) { candidate in
                            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                        }
                        let outputURL = directory.appendingPathComponent(name)
                        try Data(product.bytes).write(to: outputURL, options: .atomic)
                        result.produced.append(outputURL)
                    }
                } else {
                    for product in products {
                        let outputURL = try BesideSourceWriter.write(
                            Data(product.bytes), besideSource: file, extension: product.fileExtension)
                        result.produced.append(outputURL)
                    }
                }
            } catch let error as DocumentOperations.OperationError {
                switch error {
                case .notConvertible: result.skipped += 1
                case .unknownFormat: result.failed.append(file)
                }
            } catch let error as BesideSourceWriter.WriteError {
                if besideSourceFailure == nil {
                    besideSourceFailure = (file, error.localizedDescription)
                }
                result.failed.append(file)
            } catch {
                result.failed.append(file)
            }
        }
        // Same "never silently failed" discipline as the `to folder` access check above,
        // just necessarily per-file instead of checked up front — a bare destination has no
        // single directory to validate before the loop, since each sibling write's location
        // depends on that file's own source. Only surfaces when NOTHING converted (job 216's
        // partial-success rule: some produced output means positive information and no
        // error), and only names the FIRST beside-source failure — the arbiter this job's
        // brief asks for is a single-file probe, and a clear single reason beats an
        // enumerated list nobody asked for.
        if result.produced.isEmpty, let besideSourceFailure {
            result.destinationAccessError = DecodeError.besideSourceWriteFailed(
                source: besideSourceFailure.source.path, reason: besideSourceFailure.reason
            ).errorDescription
        }
        return result
    }

    /// A file input passes through; a folder input lists its regular files — recursively
    /// when `searchingSubfolders`, top-level only otherwise. Order is filesystem-enumeration
    /// order, not sorted — batch conversion has no ordering contract to keep.
    static func expand(_ inputs: [URL], searchingSubfolders: Bool) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                result.append(input)
                continue
            }
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if !searchingSubfolders { options.insert(.skipsSubdirectoryDescendants) }
            // Job 220 (finding C): an input folder this can't enumerate at all is skipped —
            // genuinely ignorable, not a fresh silent-nothing bug, because it lands in the
            // exact same place job 216 already ruled acceptable: fewer files reach `convert`,
            // and a batch that produces NOTHING still throws `.nothingConverted` below; one
            // skipped-among-several folder is the same "partial success, no per-item reason"
            // shape as a skipped-among-several FILE already is.
            guard let enumerator = fm.enumerator(
                at: input, includingPropertiesForKeys: [.isRegularFileKey], options: options)
            else { continue }
            for case let url as URL in enumerator {
                // One entry racing out from under the walk (rare) is skipped, not the folder.
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true { result.append(url) }
            }
        }
        return result
    }

    /// Pure argument decoding — see `ExportCommand.decode` for why this is split out.
    static func decode(
        direct: Any?, arguments: [String: Any],
        defaultHeaders: Bool = true, defaultTOC: Bool = false, defaultInlineStyling: Bool = true,
        defaultPictures: EmitOptions.PixMode = .embed,
        defaultPageNumbers: EmitOptions.PageNumberMode = .auto
    ) throws -> Arguments {
        let inputs = try ScriptingFileArgument.urls(from: direct)
        guard !inputs.isEmpty else { throw DecodeError.missingInputs }

        let destinationFolder = try (arguments["scriptingDestinationFolder"])
            .map(ScriptingFileArgument.url(from:))

        let formats = decodeFormats(arguments["scriptingFormats"])
        guard !formats.isEmpty else { throw DecodeError.missingFormats }

        var mode = EmitMode.modern
        if let styleNumber = arguments["scriptingStyle"] as? NSNumber,
           let decoded = ScriptingEnumCoding.style(forCode: styleNumber.uint32Value) {
            // Job 313B: `style(forCode:)` now decodes the sdef's three-case `ViewStyle`
            // (native/printed/modern) — `convert` (batch, no window, no print-path PDF
            // route) keeps its pre-313 two-case behavior by collapsing through
            // `renderStyle.emitMode`, same as every other non-`export` caller.
            mode = decoded.renderStyle.emitMode
        }

        var notes = EmitOptions.defaultNotes
        ExportCommand.setNote(.footnote, in: &notes, from: arguments["scriptingFootnotes"] as? Bool)
        ExportCommand.setNote(.endnote, in: &notes, from: arguments["scriptingEndnotes"] as? Bool)
        ExportCommand.setNote(.annotation, in: &notes, from: arguments["scriptingAnnotations"] as? Bool)
        ExportCommand.setNote(.comment, in: &notes, from: arguments["scriptingComments"] as? Bool)

        let searchingSubfolders = (arguments["scriptingSearchingSubfolders"] as? Bool) ?? false

        var forcingVariant: Variant?
        if let variantNumber = arguments["scriptingForcingVariant"] as? NSNumber {
            forcingVariant = ScriptingEnumCoding.variant(forCode: variantNumber.uint32Value)
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
            inputs: inputs, destinationFolder: destinationFolder, formats: formats, mode: mode,
            searchingSubfolders: searchingSubfolders, forcingVariant: forcingVariant,
            pageSettings: pageSettings, notes: notes,
            headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
            lineNumbers: lineNumbers, styles: styles, fontsTarget: fontsTarget,
            pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)
    }

    private static func decodeFormats(_ raw: Any?) -> [String] {
        let numbers: [NSNumber]
        switch raw {
        case let array as [NSNumber]: numbers = array
        case let array as NSArray: numbers = array.compactMap { $0 as? NSNumber }
        case let single as NSNumber: numbers = [single]
        default: numbers = []
        }
        return numbers.compactMap { ScriptingEnumCoding.libraryFormat(forCode: $0.uint32Value) }
    }
}
