import CtrlKD

/// Argument parsing for `sr`, hand-rolled.
///
/// NO swift-argument-parser, deliberately. The surface is seven options over one variadic
/// positional; the library would be the package's only dependency, and it would be a
/// dependency of the *executable* in a package whose entire pitch is that the library has
/// none. What it would buy — `--help` generation and choice validation — is a hundred lines
/// here, and those hundred lines are unit-testable as pure functions, which a
/// `@main`-attached parser is not.

/// `sr`'s own version. Independent of the library and of the Python reference: this is the
/// CLI's user-visible contract. 1.3.0 adds physical lines + horizontal geometry (printed
/// mode now shows every line where WordStar broke it, `.po`/`.cw`-derived left margin and
/// type size in the PDF writer, `.po`'s default changes from 0 to 8 columns); 1.2.0 adds
/// WordStar's own page-geometry model (printed capacity/top/lead from `.pl`/`.mt`/`.mb`/
/// `.lh`, with `.hm`/`.fm`/`.ls` in --diagnose); 1.1.0 added the note-selection flags and
/// the expanded --diagnose fields; 1.0.0 was the first CLI release.
public let srVersion = "1.3.0"

/// The `ctrl-kd` release this port is verified against. A constant, updated by hand when a
/// sync job pins the port to a new Python release — it is a claim about which reference the
/// vectors came from, so it must never be derived or guessed.
public let ctrlKDParity = "2.0.0"

/// `sr 1.3.0 (ctrl-kd parity 2.0.0)`.
public var versionLine: String { "sr \(srVersion) (ctrl-kd parity \(ctrlKDParity))" }

/// Everything the run needs, after parsing and validation.
public struct Options: Equatable, Sendable {
    public var files: [String] = []
    /// Resolved, never empty — `["markdown"]` when no `-t` was given (Python's
    /// `formats = a.to or ['markdown']`).
    public var formats: [String] = ["markdown"]
    public var output: String?
    public var outdir: String?
    public var mode: EmitMode = .modern
    public var variant: Variant?
    public var diagnose = false
    /// Which note kinds an emitter should render — both the inline reference marker and
    /// the trailing note-list entry. Resolved from `--no-notes`/`--comments` at the end of
    /// parsing (ctrl-kd 1.2.0's `--no-notes`/`--comments`, cli.py:78-81); the default is
    /// `EmitOptions.defaultNotes` (footnote/endnote/annotation — never comments, since
    /// WordStar itself never printed one).
    public var notes: Set<NoteKind> = EmitOptions.defaultNotes

    public init() {}
}

/// What the command line asked for.
public enum ParsedCommand: Equatable, Sendable {
    case run(Options)
    case help
    case version
    /// Argparse's `ap.error(...)`: the message, and exit status 2.
    case usageError(String)
}

/// The variants `--variant` accepts. `binary` is missing on purpose, here as in Python
/// (cli.py:41): forcing "this is not a convertible file" is not an override anyone wants.
let variantChoices = ["ws4", "ws5+", "printstream", "text"]

let modeChoices = ["modern", "printed"]

public func parseArguments(
    _ argv: [String],
    registry: EmitterRegistry = .standard
) -> ParsedCommand {
    var options = Options()
    var formats: [String] = []
    var files: [String] = []
    var index = 0
    var optionsEnded = false
    // Resolved into `options.notes` once parsing is done (cli.py:78-81) — `--no-notes`
    // wins outright over `--comments` if both are given, exactly as Python's `if
    // a.no_notes: ... else: ...` never looks at `a.comments` in that branch.
    var noNotes = false
    var comments = false

    /// The value for an option, from `--to=html` (already split off), `-thtml`, or the next
    /// argument. Returns nil when there is no next argument to take.
    func takeValue(_ flag: String, attached: String?) -> String? {
        if let attached { return attached }
        index += 1
        guard index < argv.count else { return nil }
        return argv[index]
    }

    while index < argv.count {
        let arg = argv[index]

        if optionsEnded || arg == "-" || !arg.hasPrefix("-") {
            files.append(arg)
            index += 1
            continue
        }
        if arg == "--" {
            optionsEnded = true
            index += 1
            continue
        }

        // Split `--flag=value`; a bare `--flag` leaves `attached` nil and the value, if the
        // flag needs one, comes from the next argument.
        var flag = arg
        var attached: String?
        if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
            flag = String(arg[..<equals])
            attached = String(arg[arg.index(after: equals)...])
        } else if !arg.hasPrefix("--"), arg.count > 2 {
            // `-thtml`, `-oout.md` — the attached short form argparse also accepts.
            flag = String(arg.prefix(2))
            attached = String(arg.dropFirst(2))
        }

        switch flag {
        case "-h", "--help":
            return .help
        case "--version":
            return .version
        case "-t", "--to":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard registry.getEmitter(value) != nil else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(registry.formats())))")
            }
            formats.append(value)
        case "-o", "--output":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            options.output = value
        case "-d", "--outdir":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            options.outdir = value
        case "--mode":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            // `EmitMode` has exactly these two cases, so its initializer IS the validation;
            // `modeChoices` only spells the message. (`--variant` is not so lucky: `Variant`
            // also has `binary`, which is not an accepted choice — see below.)
            guard let mode = EmitMode(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(modeChoices)))")
            }
            options.mode = mode
        case "--variant":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard variantChoices.contains(value), let variant = Variant(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(variantChoices)))")
            }
            options.variant = variant
        case "--diagnose":
            // A flag takes no value, so `--diagnose=x` is a mistake worth naming rather than
            // silently ignoring.
            if attached != nil {
                return .usageError("argument \(flag): ignored explicit argument '\(attached!)'")
            }
            options.diagnose = true
        case "--no-notes":
            if attached != nil {
                return .usageError("argument \(flag): ignored explicit argument '\(attached!)'")
            }
            noNotes = true
        case "--comments":
            if attached != nil {
                return .usageError("argument \(flag): ignored explicit argument '\(attached!)'")
            }
            comments = true
        case "--encoding":
            // Dropped, not forgotten — see the help text. Named explicitly so anyone porting a
            // ctrl-kd command line gets an answer instead of "unrecognized option".
            return .usageError(
                "argument --encoding: no longer accepted — the source encoding is always "
                    + "CP437, the only code page a WordStar file's high-bit bytes can be")
        default:
            return .usageError("unrecognized arguments: \(arg)")
        }
        index += 1
    }

    guard !files.isEmpty else {
        return .usageError("the following arguments are required: files")
    }
    options.files = files
    if !formats.isEmpty { options.formats = formats }
    // cli.py:78-81, verbatim: `--no-notes` empties the set outright; otherwise the
    // default three kinds, plus comments when `--comments` opted them in.
    if noNotes {
        options.notes = EmitOptions.noNotes
    } else if comments {
        options.notes = EmitOptions.allNotes
    }

    // cli.py:48-49, verbatim in spirit and in message: one output path cannot name the
    // results of several conversions.
    if options.output != nil, options.files.count > 1 || options.formats.count > 1 {
        return .usageError("-o works with a single input and a single format; use -d for batch")
    }
    return .run(options)
}

private func quotedList(_ items: [String]) -> String {
    items.map { "'\($0)'" }.joined(separator: ", ")
}

/// `--help`. Mentions no plugin mechanism, because there is none to mention: the library's
/// extension point is `EmitterRegistry.register` at the call site, not an installable
/// package (see Registry.swift), and a CLI that promised otherwise would be lying.
public func helpText(registry: EmitterRegistry = .standard) -> String {
    """
    usage: sr [-h] [--version] [-t FORMAT] [-o FILE] [-d DIR] [--mode MODE]
              [--variant VARIANT] [--no-notes] [--comments] [--diagnose] FILE [FILE ...]

    Convert WordStar 4-7 documents and print-to-disk files to text, Markdown, HTML,
    RTF, or PDF. ^KD: save and done.

    positional arguments:
      FILE                  input file(s)

    options:
      -h, --help            show this help and exit
      --version             show the version and exit
      -t, --to FORMAT       output format, repeatable (default: markdown)
                            choices: \(registry.formats().joined(separator: ", "))
      -o, --output FILE     output file (single input and single format only)
      -d, --outdir DIR      output directory for batch conversion
      --mode MODE           modern: reflowed paragraphs. printed: line-for-line,
                            fixed-width, as it printed in 1990 (default: modern;
                            print streams and ruler-line documents always render
                            printed)
      --variant VARIANT     override detection
                            choices: \(variantChoices.joined(separator: ", "))
      --no-notes            omit footnotes, endnotes and annotations from the output
      --comments            include WordStar comments, which it never printed
                            (author's asides, hidden since the file was written)
      --diagnose            report what the file is (variant, margin, dot commands,
                            unknown codes, note counts, page geometry) as JSON;
                            no conversion

    The source encoding is always CP437 and there is no flag to change it: the
    high-bit bytes in a WordStar file are IBM-PC code page 437, and every other
    code page mis-decodes them.

    examples:
      sr PAPER.WS                       # -> PAPER.md, modern reflow
      sr PAPER.WS -t html -o out.html
      sr --mode printed LETTER          # as it came off the printer
      sr --diagnose MYSTERY.FIL         # what IS this file?
      sr -t text -t html -d out/ *.WS   # batch, multiple formats
      sr --comments MEMO.WS             # include the author's hidden comments
      sr --no-notes PAPER.WS            # body text only, no notes
    """
}
