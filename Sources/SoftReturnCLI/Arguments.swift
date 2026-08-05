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
/// CLI's user-visible contract. 2.1.0 is the LJ6DTP page-width batch (style-record fonts
/// activate on selection; proportional runs advance at natural per-word widths times a
/// face-constant Tz; 0x0F print controls are screen-only in printed mode; bare CR is
/// `^PM` overprint; driver-aware colour (LJ6DTP) and cp437 blocks/shades/box-drawing as
/// printed vectors; `/WinAnsiEncoding` + cp1252 on text fonts; running heads/feet apply
/// from the page where their dot command sits, replayed per page from `hfEvents`;
/// `--page-defaults` for a machine's own patched geometry); 2.0.0 is the spec-audit wave
/// (paragraph styles parsed, applied, and passed through to HTML/RTF with --no-styles to
/// opt out; heading levels from resolved style names; flagged-control model;
/// wrapped-character opacity; detection that believes the header block; tab HMI
/// correction; FAQ/ERAS documentation); 1.3.0 added physical lines + horizontal geometry
/// (printed mode now shows every line where WordStar broke it, `.po`/`.cw`-derived left
/// margin and type size in the PDF writer, `.po`'s default changes from 0 to 8 columns);
/// 1.2.0 adds WordStar's own page-geometry model (printed capacity/top/lead from
/// `.pl`/`.mt`/`.mb`/`.lh`, with `.hm`/`.fm`/`.ls` in --diagnose); 1.1.0 added the
/// note-selection flags and the expanded --diagnose fields; 1.0.0 was the first CLI
/// release.
public let srVersion = "2.1.0"

/// The `ctrl-kd` release this port is verified against. A constant, updated by hand when a
/// sync job pins the port to a new Python release — it is a claim about which reference the
/// vectors came from, so it must never be derived or guessed.
public let ctrlKDParity = "3.0.0"

/// `sr 2.0.0 (ctrl-kd parity 3.0.0)`.
/// FIGlet "Slant" by Glenn Chappell (1993) -- FIGlet's own co-creator, in the
/// WordStar 7 release window. Jon's ruling: --version, --help and the README
/// carry it; conversion output and stderr status never do. A static constant:
/// the name never changes, so no .flf machinery.
public let slantBanner = """
   _____       ______     ____       __
  / ___/____  / __/ /_   / __ \\___  / /___  ___________
  \\__ \\/ __ \\/ /_/ __/  / /_/ / _ \\/ __/ / / / ___/ __ \\
 ___/ / /_/ / __/ /_   / _, _/  __/ /_/ /_/ / /  / / / /
/____/\\____/_/  \\__/  /_/ |_|\\___/\\__/\\__,_/_/  /_/ /_/
"""

public var versionLine: String { "sr \(srVersion) (ctrl-kd parity \(ctrlKDParity))" }

/// What `--version` actually prints: the banner, then the version line.
public var versionOutput: String { slantBanner + "\n" + versionLine }

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
    /// Paragraph-style pass-through (HTML classes + generated CSS, RTF stylesheet).
    /// `--no-styles` turns it off; on by default, like ctrl-kd's `styles=`.
    public var styles = true
    /// Which importer the RTF font names target (`--fonts`, ctrl-kd's `--fonts`).
    /// `.office` by default: Word and Google Docs both resolve the Microsoft names.
    public var fontsTarget: FontsTarget = .office
    /// `--page-defaults` (ctrl-kd's `--page-defaults`/`page_defaults=`), parsed into
    /// `PageGeometryDefaults`. `nil` when the flag was never given.
    public var pageDefaults: PageGeometryDefaults?

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

/// `--fonts`. `FontsTarget` has exactly these four cases, so — as with `--mode` — the
/// initializer IS the validation and this list only spells the error message.
let fontsChoices = ["office", "mac", "google", "linux"]

/// `--page-defaults` parse outcome: the resolved geometry, or a usage-error message.
enum PageDefaultsParseResult {
    case success(PageGeometryDefaults)
    case failure(String)
}

/// Parse `--page-defaults mt=0.83in,mb=1in,po=0.7in` into `PageGeometryDefaults`. Port of
/// cli.py's inline parse (ctrl-kd's `--page-defaults`).
///
/// `mt`/`mb`/`hm`/`fm` convert at 6 LPI (lines), `po` at 10 CPI (columns). A value ending
/// in `in` (case-insensitively, matched on the LOWERCASED string) converts from inches;
/// a bare number is already NATIVE units (lines, or columns for `po`) — same trap as the
/// dot commands themselves.
func parsePageDefaults(_ arg: String) -> PageDefaultsParseResult {
    var result = PageGeometryDefaults()
    for part in arg.split(separator: ",", omittingEmptySubsequences: false) {
        let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = pieces.count > 0 ? pieces[0].trimmingASCIIWhitespace().lowercased() : ""
        let rawValue = pieces.count > 1 ? pieces[1].trimmingASCIIWhitespace().lowercased() : ""
        guard !rawValue.isEmpty else {
            return .failure("--page-defaults: unknown or empty entry '\(part)'")
        }
        let perInch: Double
        switch key {
        case "mt", "mb", "hm", "fm": perInch = 6.0
        case "po": perInch = 10.0
        default: return .failure("--page-defaults: unknown or empty entry '\(part)'")
        }
        let value: Double
        if rawValue.hasSuffix("in") {
            guard let inches = Double(rawValue.dropLast(2)) else {
                return .failure("--page-defaults: bad value in '\(part)'")
            }
            value = inches * perInch
        } else {
            guard let v = Double(rawValue) else {
                return .failure("--page-defaults: bad value in '\(part)'")
            }
            value = v
        }
        switch key {
        case "mt": result.mtLines = value
        case "mb": result.mbLines = value
        case "hm": result.hmLines = value
        case "fm": result.fmLines = value
        case "po": result.poCols = value
        default: break
        }
    }
    return .success(result)
}

private extension Substring {
    /// Python's `str.strip()`: ASCII whitespace trimmed from both ends.
    func trimmingASCIIWhitespace() -> String {
        var s = self
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}

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
        case "--fonts":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard let target = FontsTarget(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(fontsChoices)))")
            }
            options.fontsTarget = target
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
        case "--no-styles":
            if attached != nil {
                return .usageError("argument \(flag): ignored explicit argument '\(attached!)'")
            }
            options.styles = false
        case "--page-defaults":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            switch parsePageDefaults(value) {
            case .success(let parsed):
                options.pageDefaults = parsed
            case .failure(let message):
                return .usageError(message)
            }
        case "--encoding":
            // Standardized with ctrl-kd (Jon's ruling, 2026-08-05): the flag EXISTS in both
            // CLIs and accepts exactly one value. cp437 is the only code page any known
            // WordStar file uses, and with no non-437 corpus to validate against, another
            // decoding would be an assumption — this project ships evidence, so the CLI
            // refuses what it cannot verify (reasoning documented in ctrl-kd's FAQ.md).
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard value.lowercased() == "cp437" else {
                return .usageError(
                    "argument --encoding: invalid choice: '\(value)' (choose from 'cp437') — "
                        + "every known WordStar file uses IBM PC code page 437, and no "
                        + "non-437 corpus exists to validate another decoding against")
            }
            // cp437 is already the (only) behavior; accepting it is a no-op.
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
    return slantBanner + "\n\n" + helpBody(registry: registry)
}

func helpBody(registry: EmitterRegistry = .standard) -> String {
    """
    usage: sr [-h] [--version] [-t FORMAT] [-o FILE] [-d DIR] [--mode MODE]
              [--variant VARIANT] [--fonts TARGET] [--encoding cp437]
              [--no-styles] [--no-notes] [--comments] [--diagnose]
              FILE [FILE ...]

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
      --fonts TARGET        RTF font-name target: office (Word/Docs, default;
                            these fonts ship with MS Office, not bare Windows),
                            mac (Cocoa-native: TextEdit/Pages), google (Docs
                            catalog incl. its chancery script), linux (URW
                            base-35 -- free clones of exactly this era's faces)
                            choices: \(fontsChoices.joined(separator: ", "))
      --no-styles           omit paragraph-style pass-through (HTML classes +
                            generated CSS, RTF stylesheet) from the output
      --page-defaults L     replacement DEFAULTS for page geometry a document does
                            not declare (its own dot commands always win). Keys:
                            mt, mb (top/bottom margin), po (page offset), hm, fm
                            (header/footer margin), comma-separated, e.g.
                            mt=0.83in,mb=1in,po=0.7in -- an "in" suffix converts
                            from inches, else native units (lines at 6 LPI; po in
                            10-CPI columns). Use when the printing machine's
                            WSCHANGE-patched defaults are known
      --no-notes            omit footnotes, endnotes and annotations from the output
      --comments            include WordStar comments, which it never printed
                            (author's asides, hidden since the file was written)
      --diagnose            report what the file is (variant, margin, dot commands,
                            unknown codes, note counts, page geometry) as JSON;
                            no conversion

    --encoding cp437 is accepted (and is the default); every other value is
    refused. The high-bit bytes in every known WordStar file are IBM-PC code
    page 437, and no non-437 corpus exists to validate another decoding
    against — the CLI refuses what it cannot verify.

    examples:
      sr PAPER.WS                       # -> PAPER.md, modern reflow
      sr PAPER.WS -t html -o out.html
      sr --mode printed LETTER          # as it came off the printer
      sr --diagnose MYSTERY.FIL         # what IS this file?
      sr -t text -t html -d out/ *.WS   # batch, multiple formats
      sr -t rtf --fonts mac LETTER.WS   # font names TextEdit and Pages resolve
      sr --comments MEMO.WS             # include the author's hidden comments
      sr --no-notes PAPER.WS            # body text only, no notes
    """
}
