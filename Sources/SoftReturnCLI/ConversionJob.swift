import CtrlKD

/// The conversion pipeline behind `sr`, as a library entry point: parse, resolve quirks,
/// apply the effective page, resolve pictures, build `EmitOptions`, plan the image export,
/// name the output, render. It lives here and not in the engine because every input it
/// takes (`Options`, `CLIEnvironment`, the `--page-settings` and `--pictures` rules, `sr`'s
/// output naming) is this module's; the engine stays a stdlib-only renderer.
///
/// The job never writes. Picture resolution READS through the environment (a picture is
/// found by walking the directories beside the document); everything that would be
/// written comes back as values: the bytes, the destination name, the planned image files
/// and the warnings. `run` (Run.swift) is the caller that writes and prints; the sawyer
/// drift generator is a caller that does neither.
///
/// The stages are separate calls because the CLI interleaves its own I/O between them: it
/// writes the exported images before it renders (a failed image write drops that image's
/// link from the output), and it asks about overwriting between rendering and writing.
/// `convert` strings the stages together for a caller that does no I/O.
public struct ConversionJob {
    public let options: Options
    public let registry: EmitterRegistry

    public init(options: Options, registry: EmitterRegistry = .standard) {
        self.options = options
        self.registry = registry
    }

    /// Why a document could not go through the pipeline. The caller words it.
    public enum Failure: Error {
        case parse(Error)
        /// A quirk name this build does not know: a usage error for the whole run.
        case unknownQuirk(name: String, known: [String])
        case quirks(Error)
        case unknownFormat(String)
    }

    /// A parsed document with the run's quirks applied.
    public func parseDocument(_ data: [UInt8]) throws -> Document {
        let parsed: Document
        do {
            parsed = try parse(data, variant: options.variant, printedBy: options.printedBy)
        } catch {
            throw Failure.parse(error)
        }
        // Quirks are resolved ONCE per document, before any emitter reads it, so every
        // requested format renders the same decision and the layout JSON's own report can
        // never disagree with what ran.
        do {
            return try QuirkRegistry.standard.applyQuirks(
                to: parsed, enable: options.quirksEnabled, disable: options.quirksDisabled,
                mode: options.quirksMode)
        } catch let QuirkError.unknownQuirk(name, known) {
            throw Failure.unknownQuirk(name: name, known: known)
        } catch {
            throw Failure.quirks(error)
        }
    }

    /// A document ready to render: effective page applied, pictures resolved once.
    public struct Plan {
        public let document: Document
        public let path: String
        /// The input's name without extension: the title and the output stem.
        public let base: String
        public let pixResults: [PixResult]
        /// stderr lines, in the order `sr` has always printed them.
        public let warnings: [String]
    }

    public func plan(_ document: Document, path: String, environment: CLIEnvironment) -> Plan {
        var doc = document
        var warnings: [String] = []

        // D5 (ruled 2026-08-05): when the user EXPLICITLY asked for modern and the input
        // can only render printed (a print stream, or a ruler-line/columnar document),
        // say so once instead of silently disobeying the flag. The override stands; the
        // CLI only explains itself. Quiet when modern was merely defaulted.
        if options.modeExplicit, options.mode == .modern, isPrinted(doc) {
            let kind = doc.detection?.variant == .printstream
                ? "print stream" : "ruler-line document"
            warnings.append("sr: \(path): \(kind) -- modern reflow is not possible; "
                + "rendering printed")
        }

        // --comments + printed is a contradiction the CLI explains rather than silently
        // resolving (ruling 2026-08-06 M9): WordStar printed nothing for a comment, and
        // the facsimile doesn't either.
        if options.commentsRequested,
           options.mode == .printed || doc.detection?.variant == .printstream || doc.columnar,
           doc.notes.contains(where: { $0.kind == .comment }) {
            warnings.append("sr: \(path): comments are never part of the printed "
                + "page -- WordStar did not print them, so the facsimile doesn't either; "
                + "convert with --mode modern to see them")
        }

        // A driver-art document reflowed under modern will look strange, and the log
        // should say why (ruling 2026-08-06): the driver's page art exists only at print
        // time. Its CHARACTER substitutions are content and ARE applied.
        if options.mode == .modern, doc.printerDriver == "LJ6DTP" {
            warnings.append("sr: \(path): LJ6DTP driver document -- its print-time "
                + "page art (boxes, rules, color) does not reflow; character "
                + "substitutions applied. --mode printed reproduces the page")
        }

        // --page-settings applies ONCE to the resolved page, so every emitter (PDF
        // geometry, RTF page setup) sees the same effective page (ruling 2026-08-05,
        // "Page Settings at every layer").
        if let pageSettings = options.pageSettings, let page = doc.page {
            doc.page = effectivePage(page, settings: pageSettings)
        }

        // Pictures are resolved and decoded ONCE per document and reused across every
        // requested format. Misses are reported once per document (not once per format)
        // unless --pictures off.
        let pixResults: [PixResult] = doc.graphics.isEmpty ? []
            : resolveDocumentPictures(doc, docPath: path, environment: environment)
        if !pixResults.isEmpty, options.pictures != .off {
            warnings += pixMissMessages(pixResults, pathLabel: path, docPath: path,
                                        environment: environment)
        }
        return Plan(document: doc, path: path, base: stem(path), pixResults: pixResults,
                    warnings: warnings)
    }

    /// The images a format needs on disk (`--pictures export`, or Markdown's embed, which
    /// degrades to export-and-link because Markdown has no true embed).
    public struct ImageExport {
        /// Where the PNG files go.
        public let directory: String
        /// The directory as the output document names it: `<base>-images`.
        public let linkPrefix: String
        public let images: [ExportImage]
        /// Markdown's embed degradation is announced once; plain export is not.
        public let isMarkdownDegradation: Bool

        /// `{picture index: link}` for the images that were actually written.
        public func links(written: [Int: String]) -> [Int: String] {
            Dictionary(uniqueKeysWithValues: written.map { ($0.key, "\(linkPrefix)/\($0.value)") })
        }

        /// The links when every planned image gets written.
        public var allLinks: [Int: String] {
            links(written: Dictionary(uniqueKeysWithValues: images.map { ($0.index, $0.name) }))
        }

        /// The stderr note for the Markdown degradation, or `nil` for any other case.
        public func degradationNote(path: String, writtenCount: Int) -> String? {
            guard isMarkdownDegradation, writtenCount > 0 else { return nil }
            return "sr: \(path): Markdown has no true image embedding -- exporting "
                + "\(writtenCount) PNG file(s) to \(basename(directory))/ and "
                + "linking to them instead (degradation per the pictures flag ruling)"
        }
    }

    /// One requested format for one document.
    public struct Target {
        public let emitter: Emitter
        public let destination: String
        public let imageExport: ImageExport?
    }

    /// Resolve `format` to its emitter, its output name and its image export. The output
    /// name is `-o` if given, else `<stem><ext>` in `-d` or beside the input.
    public func target(format: String, plan: Plan) throws -> Target {
        // Already validated at parse time, so a miss is impossible unless the caller
        // passed a different registry here than to `parseArguments`.
        guard let emitter = registry.getEmitter(format) else {
            throw Failure.unknownFormat(format)
        }
        let destination: String
        if let explicit = options.output {
            destination = explicit
        } else {
            let directory = options.outdir
                ?? (pathDirname(plan.path).isEmpty ? "." : pathDirname(plan.path))
            destination = joinPath(directory, plan.base + emitter.ext)
        }

        // Branch on the resolved emitter's canonical name, never the raw `-t` value:
        // "md" is only an alias of "markdown". The degradation applies in MODERN mode
        // only: a Printed-mode Markdown body is a fenced facsimile that never consults
        // image links, so exporting files for it would be pure waste.
        let isMarkdown = emitter.name == "markdown"
        let needExport = options.pictures == .export
            || (isMarkdown && options.pictures == .embed && options.mode == .modern)
        var imageExport: ImageExport?
        if needExport, plan.pixResults.contains(where: \.ok) {
            let destDir = pathDirname(destination)
            let directory = joinPath(destDir.isEmpty ? "." : destDir, plan.base + "-images")
            imageExport = ImageExport(
                directory: directory, linkPrefix: plan.base + "-images",
                images: plannedExportImages(plan.pixResults),
                isMarkdownDegradation: isMarkdown && options.pictures == .embed)
        }
        return Target(emitter: emitter, destination: destination, imageExport: imageExport)
    }

    /// Render one target. `imageLinks` is what the caller managed to write; `[:]` when
    /// there is no export.
    public func render(_ plan: Plan, _ target: Target, imageLinks: [Int: String]) -> [UInt8] {
        // No `pageSettings` here: `plan` already applied it once to `document.page`, so
        // every format sees the identical effective page.
        let output = target.emitter.emit(
            plan.document, options.mode,
            EmitOptions(title: plan.base, notes: options.notes,
                        styles: options.styles,
                        fontsTarget: options.fontsTarget,
                        noteRefs: options.noteRefs,
                        headers: options.headers,
                        lineNumbers: options.lineNumbers,
                        toc: options.toc,
                        inlineStyling: options.inlineStyling,
                        pictures: options.pictures,
                        pageNumbers: options.pageNumbers,
                        sentenceSpacing: options.sentenceSpacing,
                        pixResults: plan.pixResults,
                        imageLinks: imageLinks))
        return output.asBytes
    }

    /// One converted format.
    public struct Output {
        public let format: String
        public let destination: String
        public let bytes: [UInt8]
        /// The PNG files that belong beside `destination`, if any.
        public let imageExport: ImageExport?
    }

    public struct Result {
        public let outputs: [Output]
        /// How each picture reference in the document resolved.
        public let pixResults: [PixResult]
        public let warnings: [String]
    }

    /// Every requested format of one document, with no I/O of its own. Exported images
    /// are assumed written, so their links are in the bytes; a caller that writes them
    /// itself and wants to handle a failed write uses the stages instead (as `run` does).
    public func convert(_ data: [UInt8], path: String, environment: CLIEnvironment) throws -> Result {
        let document = try parseDocument(data)
        let prepared = plan(document, path: path, environment: environment)
        var outputs: [Output] = []
        for format in options.formats {
            let aim = try target(format: format, plan: prepared)
            let bytes = render(prepared, aim, imageLinks: aim.imageExport?.allLinks ?? [:])
            outputs.append(Output(format: format, destination: aim.destination,
                                  bytes: bytes, imageExport: aim.imageExport))
        }
        return Result(outputs: outputs, pixResults: prepared.pixResults,
                      warnings: prepared.warnings)
    }
}
