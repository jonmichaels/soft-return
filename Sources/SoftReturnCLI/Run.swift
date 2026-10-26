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

/// The I/O half of `sr`: read each input, hand it to `ConversionJob`, then print what the
/// job warns about and write what it produces. Which bytes come out, and what they are
/// called, is the job's business.
private func convertAll(
    _ options: Options,
    environment: CLIEnvironment,
    registry: EmitterRegistry
) -> Int32 {
    var status = ExitStatus.ok

    // `--list-quirks` with no file at all: the catalogue this build carries. Same JSON
    // shape ctrl-kd's own `--list-quirks` prints, byte for byte (both sort their keys and
    // both emit UTF-8 rather than \uXXXX escapes).
    if options.listQuirks, options.files.isEmpty {
        environment.writeOut(quirkListingJSON(QuirkRegistry.standard.list()).render())
        return ExitStatus.ok
    }

    let job = ConversionJob(options: options, registry: registry)

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

        let doc: Document
        do {
            doc = try job.parseDocument(data)
        } catch ConversionJob.Failure.parse(let error) {
            environment.writeErr(
                "sr: \(path): \(message(for: error)) "
                    + "(use --diagnose to inspect, --variant to force)")
            status = ExitStatus.fileFailure
            continue
        } catch ConversionJob.Failure.unknownQuirk(let name, let known) {
            // A name this build does not know is a usage error, not something to
            // swallow: swallowing it would hand back output the caller did not ask for.
            environment.writeErr("sr: error: unknown quirk '\(name)' "
                + "(known: \(known.joined(separator: ", ")))")
            return ExitStatus.usage
        } catch ConversionJob.Failure.quirks(let error) {
            environment.writeErr("sr: \(path): \(message(for: error))")
            status = ExitStatus.fileFailure
            continue
        } catch {
            environment.writeErr("sr: \(path): \(message(for: error))")
            status = ExitStatus.fileFailure
            continue
        }

        if options.listQuirks {
            environment.writeOut(JSONValue.object([
                "file": .string(basename(path)),
                "quirks": quirkListingJSON(QuirkRegistry.standard.list(for: doc)),
            ]).render())
            continue
        }

        let plan = job.plan(doc, path: path, environment: environment)
        for warning in plan.warnings {
            environment.writeErr(warning)
        }

        for format in options.formats {
            let target: ConversionJob.Target
            do {
                target = try job.target(format: format, plan: plan)
            } catch {
                environment.writeErr("sr: unknown format: \(format)")
                status = ExitStatus.fileFailure
                continue
            }
            let destination = target.destination

            // --pictures export writes PNG files beside the output for every applicable
            // format; MD's own embed mode degrades to the same export-and-link behavior
            // -- ONE stderr note for that degradation.
            var imageLinks: [Int: String] = [:]
            if let export = target.imageExport {
                let written = writeExportImages(export.images, imagesDir: export.directory,
                                                environment: environment)
                if !written.isEmpty {
                    imageLinks = export.links(written: written)
                    if let note = export.degradationNote(path: path, writtenCount: written.count) {
                        environment.writeErr(note)
                    }
                }
            }

            let bytes = job.render(plan, target, imageLinks: imageLinks)

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


/// One `--list-quirks` row set as JSON. The field names and the two-space, sorted-key
/// rendering are chosen to match ctrl-kd's own `--list-quirks` output byte for byte, so a
/// script can read either CLI's answer with one parser.
private func quirkListingJSON(_ rows: [QuirkListing]) -> JSONValue {
    .array(rows.map { row in
        var fields: [String: JSONValue] = [
            "name": .string(row.name),
            "description": .string(row.description),
            "class": .string(row.quirkClass.rawValue),
        ]
        if let applicable = row.applicable {
            fields["applicable"] = .bool(applicable)
            fields["reason"] = row.reason.map { JSONValue.string($0) } ?? .null
            fields["enabled"] = .bool(row.enabled ?? false)
        }
        return .object(fields)
    })
}
