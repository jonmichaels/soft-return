import CtrlKD

/// Everything `run` does that touches the world, in one injectable struct.
///
/// The point is the tests: the conversion loop's interesting behavior is *which files it
/// writes and what it says while doing it*, and asserting that against a real filesystem
/// means temp directories, cleanup, and a suite that fails differently on a full disk.
/// With this, the whole loop runs against a dictionary.
public struct CLIEnvironment: Sendable {
    public var readFile: @Sendable (String) throws -> [UInt8]
    public var writeFile: @Sendable (String, [UInt8]) throws -> Void
    public var createDirectory: @Sendable (String) throws -> Void
    public var writeOut: @Sendable (String) -> Void
    public var writeErr: @Sendable (String) -> Void
    /// Whether a file already exists at `path` — the D4 overwrite gate (sr-only ruling,
    /// 2026-08-05: ctrl-kd always overwrites silently; sr asks — "it's a Mac"). Defaults to
    /// "nothing ever exists" so every caller from before this flag existed (every other
    /// test in this file, and `--force` itself) is unaffected.
    public var fileExists: @Sendable (String) -> Bool
    /// Whether stdin is an interactive terminal. Decides which half of D4 fires: a TTY
    /// gets asked; a script or pipeline gets refused outright rather than hang silently on
    /// a prompt nobody can answer (the audit's own implementation note).
    public var stdinIsTTY: @Sendable () -> Bool
    /// One line of the user's answer to the D4 overwrite prompt, or `nil` at EOF (treated
    /// as "no" — an unanswerable prompt must never fall through to overwriting).
    public var readLine: @Sendable () -> String?
    /// b24 round 19 (RULINGS-LEDGER PIX row): the entries of `path` if it is a readable
    /// directory, else `nil` (not a directory, or unreadable — never throws). Bare
    /// entry names, not full paths — `piximg`'s own case-insensitive walk
    /// (`PixResolve.swift`) joins them itself. Defaults to "nothing is ever a
    /// directory" so every caller from before this flag existed is unaffected.
    public var listDirectory: @Sendable (String) -> [String]?
    /// Whether `path` exists and is a REAL FILE (not a directory) — `fileExists` alone
    /// doesn't distinguish the two, and PIX resolution's own final candidate check
    /// needs to (a resolved directory is not a resolved image). Defaults to "nothing is
    /// ever a file".
    public var isFile: @Sendable (String) -> Bool

    public init(
        readFile: @escaping @Sendable (String) throws -> [UInt8],
        writeFile: @escaping @Sendable (String, [UInt8]) throws -> Void,
        createDirectory: @escaping @Sendable (String) throws -> Void,
        writeOut: @escaping @Sendable (String) -> Void,
        writeErr: @escaping @Sendable (String) -> Void,
        fileExists: @escaping @Sendable (String) -> Bool = { _ in false },
        stdinIsTTY: @escaping @Sendable () -> Bool = { false },
        readLine: @escaping @Sendable () -> String? = { nil },
        listDirectory: @escaping @Sendable (String) -> [String]? = { _ in nil },
        isFile: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.createDirectory = createDirectory
        self.writeOut = writeOut
        self.writeErr = writeErr
        self.fileExists = fileExists
        self.stdinIsTTY = stdinIsTTY
        self.readLine = readLine
        self.listDirectory = listDirectory
        self.isFile = isFile
    }
}

/// Exit statuses. Argparse exits 2 on a usage error and this keeps that, because shell
/// scripts and `make` rules read it: 2 means "you typed it wrong", 1 means "a file failed".
public enum ExitStatus {
    public static let ok: Int32 = 0
    public static let fileFailure: Int32 = 1
    public static let usage: Int32 = 2
}

/// Parse, then convert (or diagnose) every input. Port of `main` (cli.py:24-88).
///
/// `argv` excludes the program name. Returns the process exit status; it never exits itself,
/// which is what lets the tests call it.
public func run(
    _ argv: [String],
    environment: CLIEnvironment,
    registry: EmitterRegistry = .standard
) -> Int32 {
    switch parseArguments(argv, registry: registry) {
    case .help:
        environment.writeOut(helpText(registry: registry))
        return ExitStatus.ok
    case .version(let verbose):
        if verbose, let hash = srDevHash {
            environment.writeOut(versionOutput + "\nengine commit \(hash)")
        } else {
            environment.writeOut(versionOutput)
        }
        return ExitStatus.ok
    case .samples(let dir):
        return writeSamples(to: dir, environment: environment)
    case .usageError(let message):
        environment.writeErr("usage: sr [-h] [--version] [-t FORMAT] [-o FILE] [-d DIR] "
            + "[--mode MODE]\n          [--variant VARIANT] [--fonts TARGET] "
            + "[--note-refs SCHEME] [--page-settings P]\n          [--force] [--no-notes] "
            + "[--comments] [--diagnose] FILE [FILE ...]")
        environment.writeErr("sr: error: \(message)")
        return ExitStatus.usage
    case .run(let options):
        return convertAll(options, environment: environment, registry: registry)
    }
}

private func convertAll(
    _ options: Options,
    environment: CLIEnvironment,
    registry: EmitterRegistry
) -> Int32 {
    var status = ExitStatus.ok

    for path in options.files {
        let data: [UInt8]
        do {
            data = try environment.readFile(path)
        } catch {
            environment.writeErr("sr: \(path): \(message(for: error))")
            status = ExitStatus.fileFailure
            continue
        }

        // cli.py:59-61 — diagnose reports and converts nothing, including for files that
        // would fail to parse. That is the whole point of the flag.
        if options.diagnose {
            environment.writeOut(diagnose(path: path, data: data, environment: environment).render())
            continue
        }

        var doc: Document
        do {
            doc = try parse(data, variant: options.variant)
        } catch {
            environment.writeErr(
                "sr: \(path): \(message(for: error)) "
                    + "(use --diagnose to inspect, --variant to force)")
            status = ExitStatus.fileFailure
            continue
        }

        // D5 (ruled 2026-08-05): when the user EXPLICITLY asked for modern and the input
        // can only render printed (a print stream, or a ruler-line/columnar document —
        // `isPrinted` is exactly that gate), say so once instead of silently disobeying
        // the flag. The override itself stands — a print stream has no soft returns to
        // unwrap — the CLI only explains itself. Quiet when modern was merely defaulted:
        // every bare run of one of these files would otherwise print this on every file.
        if options.modeExplicit, options.mode == .modern, isPrinted(doc) {
            let kind = doc.detection?.variant == .printstream
                ? "print stream" : "ruler-line document"
            environment.writeErr("sr: \(path): \(kind) -- modern reflow is not possible; "
                + "rendering printed")
        }

        // --comments + printed is a contradiction the CLI explains rather than silently
        // resolving (ruling 2026-08-06 M9): WordStar printed nothing for a comment, and
        // the facsimile doesn't either.
        if options.commentsRequested,
           options.mode == .printed || doc.detection?.variant == .printstream || doc.columnar,
           doc.notes.contains(where: { $0.kind == .comment }) {
            environment.writeErr("sr: \(path): comments are never part of the printed "
                + "page -- WordStar did not print them, so the facsimile doesn't either; "
                + "convert with --mode modern to see them")
        }

        // A driver-art document reflowed under modern will look strange, and the log
        // should say why (ruling 2026-08-06): the driver's page art (colour knockouts,
        // rules, hand-laid boxes) exists only at print time. Its CHARACTER substitutions
        // are content and ARE applied.
        if options.mode == .modern, doc.printerDriver == "LJ6DTP" {
            environment.writeErr("sr: \(path): LJ6DTP driver document -- its print-time "
                + "page art (boxes, rules, colour) does not reflow; character "
                + "substitutions applied. --mode printed reproduces the page")
        }

        // --page-settings applies ONCE to the resolved page, so every emitter (PDF
        // geometry, RTF page setup) sees the same effective page (ruling 2026-08-05,
        // "Page Settings at every layer") — mirrors `PDFWriter.swift`'s own `emitPDF`
        // option for a caller using the library directly, without going through the CLI.
        if let pageSettings = options.pageSettings, let page = doc.page {
            doc.page = effectivePage(page, settings: pageSettings)
        }

        let base = stem(path)

        // b24 round 19 (RULINGS-LEDGER PIX row, "PIX images RULED IN"): resolved+
        // decoded ONCE per document, reused across every requested format (each PIX
        // file is read and decoded at most once regardless of how many -t flags this
        // run carries). Misses are reported on stderr once per document (not once per
        // format) unless --pictures off, since a user who turned pictures off doesn't
        // want to hear about missing ones either.
        let pixResults: [PixResult] = doc.graphics.isEmpty ? []
            : resolveDocumentPictures(doc, docPath: path, environment: environment)
        if !pixResults.isEmpty, options.pictures != .off {
            reportPixMisses(pixResults, pathLabel: path, docPath: path, environment: environment)
        }

        for format in options.formats {
            // Already validated at parse time, so a miss here is impossible unless the caller
            // passed a different registry to `run` than to `parseArguments`.
            guard let emitter = registry.getEmitter(format) else {
                environment.writeErr("sr: unknown format: \(format)")
                status = ExitStatus.fileFailure
                continue
            }

            let destination: String
            if let explicit = options.output {
                destination = explicit
            } else {
                let directory = options.outdir ?? (dirname(path).isEmpty ? "." : dirname(path))
                destination = joinPath(directory, base + emitter.ext)
            }

            // --pictures export writes PNG files beside the output for every applicable
            // format; MD's own embed mode degrades to the same export-and-link behavior
            // (ruled: MD has no true embed) -- ONE stderr note for that degradation.
            // The MD degradation note only fires in MODERN mode -- a Printed-mode MD
            // body is emit_text's fenced facsimile (never consults imageLinks at all,
            // by design: a fence is the emitter's own "verbatim" promise), so exporting
            // files and printing the note for it would be pure waste, not a
            // correctness issue but a confusing one.
            var imageLinks: [Int: String] = [:]
            let needExport = options.pictures == .export
                || (format == "md" && options.pictures == .embed && options.mode == .modern)
            if needExport, pixResults.contains(where: \.ok) {
                let destDir = dirname(destination)
                let imagesDir = joinPath(destDir.isEmpty ? "." : destDir, base + "-images")
                let written = writeExportImages(pixResults, imagesDir: imagesDir, environment: environment)
                if !written.isEmpty {
                    imageLinks = Dictionary(uniqueKeysWithValues:
                        written.map { (idx, name) in (idx, "\(base)-images/\(name)") })
                    if format == "md", options.pictures == .embed {
                        environment.writeErr(
                            "sr: \(path): Markdown has no true image embedding -- exporting "
                                + "\(written.count) PNG file(s) to \(basename(imagesDir))/ and "
                                + "linking to them instead (degradation per the pictures flag ruling)")
                    }
                }
            }

            // No `pageSettings` here: the CLI already applied it once to `doc.page` above,
            // so every format sees the identical effective page. (`EmitOptions.pageSettings`
            // stays available to a caller using `emitPDF` directly, outside the CLI.)
            let output = emitter.emit(doc, options.mode,
                                      EmitOptions(title: base, notes: options.notes,
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
                                                  pixResults: pixResults,
                                                  imageLinks: imageLinks))

            // D4 (sr-only ruling, 2026-08-05 — a sanctioned platform divergence from
            // ctrl-kd, which always overwrites silently: "it's a Mac"). `--force` bypasses
            // this whole gate. Otherwise: a TTY gets asked; a script or pipeline (no TTY to
            // ask) is refused outright rather than hang forever on a prompt nothing will
            // ever answer — the audit's own implementation note.
            if !options.force, environment.fileExists(destination) {
                if environment.stdinIsTTY() {
                    environment.writeErr("sr: \(destination) already exists. Overwrite? [y/N] ")
                    let answer = environment.readLine()?.lowercased() ?? ""
                    guard answer.hasPrefix("y") else {
                        environment.writeErr("sr: \(destination): not overwritten")
                        status = ExitStatus.fileFailure
                        continue
                    }
                } else {
                    environment.writeErr(
                        "sr: \(destination): already exists (use --force to overwrite)")
                    status = ExitStatus.fileFailure
                    continue
                }
            }

            do {
                if let outdir = options.outdir {
                    try environment.createDirectory(outdir)
                }
                // Python decides between `open(dest, 'wb')` and `open(dest, 'w',
                // encoding='utf-8')` with `isinstance(out, bytes)`. Here the emitter's return
                // type says which it is and the compiler checks that both cases are handled —
                // the job-010 payoff. Both arms end at the same call because the difference
                // between them is entirely "does this need encoding first".
                let bytes: [UInt8]
                switch output {
                case .text(let string): bytes = Array(string.utf8)
                case .data(let raw): bytes = raw
                }
                try environment.writeFile(destination, bytes)
            } catch {
                // Python has no handler here: a write failure exits with a traceback. Report
                // it like every other per-file failure instead, and keep going.
                environment.writeErr("sr: \(destination): \(message(for: error))")
                status = ExitStatus.fileFailure
                continue
            }
            // Status goes to STDERR: with `-o /dev/stdout` (or a pipe) a status
            // line on stdout lands INSIDE the converted document -- found
            // 2026-08-04 when a Python-vs-Swift archive comparison flagged all
            // 81 convertible documents as differing by exactly this line.
            // Both CLIs carried the defect; both fixed together.
            environment.writeErr("\(path) -> \(destination)")
        }
    }
    return status
}

/// Errors as the CLI says them.
///
/// `ParseError` and `EmitError` get sentences; anything else — an I/O failure from the
/// environment — falls through to its own description, which for Foundation's errors is
/// already a readable sentence ("The file ... doesn't exist.").
func message(for error: Error) -> String {
    switch error {
    case ParseError.empty:
        return "empty file: nothing to convert"
    case ParseError.notConvertible(let variant, let reason, _):
        // the refusal explains itself (task #18): WHY, not just "no"
        return "not a convertible file (detected: \(variant.rawValue) -- \(reason))"
    case EmitError.unknownFormat(let name, let known):
        return "unknown format '\(name)' (known: \(known.joined(separator: ", ")))"
    case EmitError.binaryFormat(let name, _):
        return "\(name) renders to bytes, not text"
    default:
        return "\(error)"
    }
}
