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

    public init(
        readFile: @escaping @Sendable (String) throws -> [UInt8],
        writeFile: @escaping @Sendable (String, [UInt8]) throws -> Void,
        createDirectory: @escaping @Sendable (String) throws -> Void,
        writeOut: @escaping @Sendable (String) -> Void,
        writeErr: @escaping @Sendable (String) -> Void
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.createDirectory = createDirectory
        self.writeOut = writeOut
        self.writeErr = writeErr
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
    case .version:
        environment.writeOut(versionLine)
        return ExitStatus.ok
    case .usageError(let message):
        environment.writeErr("usage: sr [-h] [--version] [-t FORMAT] [-o FILE] [-d DIR] "
            + "[--mode MODE]\n          [--variant VARIANT] [--diagnose] FILE [FILE ...]")
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
            environment.writeOut(diagnose(path: path, data: data).render())
            continue
        }

        let doc: Document
        do {
            doc = try parse(data, variant: options.variant)
        } catch {
            environment.writeErr(
                "sr: \(path): \(message(for: error)) "
                    + "(use --diagnose to inspect, --variant to force)")
            status = ExitStatus.fileFailure
            continue
        }

        let base = stem(path)
        for format in options.formats {
            // Already validated at parse time, so a miss here is impossible unless the caller
            // passed a different registry to `run` than to `parseArguments`.
            guard let emitter = registry.getEmitter(format) else {
                environment.writeErr("sr: unknown format: \(format)")
                status = ExitStatus.fileFailure
                continue
            }
            let output = emitter.emit(doc, options.mode, EmitOptions(title: base))

            let destination: String
            if let explicit = options.output {
                destination = explicit
            } else {
                let directory = options.outdir ?? (dirname(path).isEmpty ? "." : dirname(path))
                destination = joinPath(directory, base + emitter.ext)
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
            environment.writeOut("\(path) -> \(destination)")
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
    case ParseError.notConvertible(let variant):
        return "not a convertible file (detected: \(variant.rawValue))"
    case EmitError.unknownFormat(let name, let known):
        return "unknown format '\(name)' (known: \(known.joined(separator: ", ")))"
    case EmitError.binaryFormat(let name, _):
        return "\(name) renders to bytes, not text"
    default:
        return "\(error)"
    }
}
