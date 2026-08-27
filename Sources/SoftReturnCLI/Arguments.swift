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
/// CLI's user-visible contract. 3.2.0 is the b23 exports-overhaul batch
/// (4.0.0 is reserved: Jon's ruling 2026-08-17, sr becomes 4.0.0 at the Soft Return
/// v4.0.0 public release, not before) (2026-08-17,
/// ctrl-kd's own modern-reflow branch, merged upstream at e9f6c42): Modern paragraph
/// assembly (typed-paragraph manuscripts reflow into real paragraphs; verse/stanza runs
/// keep their forced breaks; no hard line breaks inside a paragraph in ANY Modern format);
/// WS-absolute page-width geometry stripped from every Modern style (HTML/RTF alike;
/// Native HTML drops `<pre>` for `<p class="ws-native">` + `<br>`); consecutive quote-
/// classified paragraphs merge into one continuous quote (`<blockquote>`/`\li\ri` inset/
/// 4-space TXT indent/`>` MD) instead of one box per paragraph; RTF direct-formatting
/// doctrine (`\sN` is nominal only — every paragraph and run carries its complete effective
/// formatting, style-declared attrs included, as direct tokens); Markdown hard breaks are
/// two trailing spaces, never a backslash. A MAJOR bump: existing invocations' MODERN
/// output bytes change for typed-paragraph/quote/verse-shaped documents, the same
/// "existing behavior changes" bar 3.0.0's own bump used, even though no CLI flag moved.
/// 3.1.0 is the Modern-rounds + v4-engine-queue batch
/// (2026-08-06): `--note-refs word|prefixed`, `--page-settings size=letter|legal|a4`, the
/// `layout` output format (`-t layout`), the `--comments`+printed and LJ6DTP-modern
/// stderr notices, and refusals that explain themselves (ParseError kinds) -- new surface,
/// no changed defaults, so MINOR. 3.0.0 is the wholesale defaults batch (CLI-Defaults-Audit,
/// 2026-08-05) -- a MAJOR bump because the repo's own versioning contract says so ("CLI
/// defaults changed"): bare invocation is now Modern RTF (not markdown); `--mode printed`
/// alone now defaults to PDF; `--page-defaults` is renamed `--page-settings` everywhere
/// (CLI flag, `PageSettings` type, `EmitOptions.pageSettings`) and gains the
/// `default`/`sawyer`/`modern` presets, applied once so every emitter sees the same page;
/// Modern PDF is now the printed form of Modern RTF (document fonts carried, proportional
/// reflow, page-bottom footnotes) rather than a fixed Courier grid; the sophisticated
/// fontless body is Georgia 14 in RTF/HTML and Times 14 in PDF; RTF emits its page setup
/// explicitly; `--force` bypasses sr's own overwrite prompt (a sanctioned platform
/// difference from ctrl-kd, which always overwrites silently — "it's a Mac"); an explicit
/// `--mode modern` meeting a print stream/ruler document now says so on stderr (D5). 2.1.0
/// is the LJ6DTP page-width batch (style-record fonts activate on selection; proportional
/// runs advance at natural per-word widths times a face-constant Tz; 0x0F print controls
/// are screen-only in printed mode; bare CR is `^PM` overprint; driver-aware colour
/// (LJ6DTP) and cp437 blocks/shades/box-drawing as printed vectors; `/WinAnsiEncoding` +
/// cp1252 on text fonts; running heads/feet apply from the page where their dot command
/// sits, replayed per page from `hfEvents`; `--page-defaults` for a machine's own patched
/// geometry); 2.0.0 is the spec-audit wave (paragraph styles parsed, applied, and passed
/// through to HTML/RTF with --no-styles to opt out; heading levels from resolved style
/// names; flagged-control model; wrapped-character opacity; detection that believes the
/// header block; tab HMI correction; FAQ/ERAS documentation); 1.3.0 added physical lines +
/// horizontal geometry (printed mode now shows every line where WordStar broke it,
/// `.po`/`.cw`-derived left margin and type size in the PDF writer, `.po`'s default
/// changes from 0 to 8 columns); 1.2.0 adds WordStar's own page-geometry model (printed
/// capacity/top/lead from `.pl`/`.mt`/`.mb`/`.lh`, with `.hm`/`.fm`/`.ls` in --diagnose);
/// 1.1.0 added the note-selection flags and the expanded --diagnose fields; 1.0.0 was the
/// first CLI release.
public let srVersion = "3.2.0"

/// The `ctrl-kd` release this port is verified against. A constant, updated by hand when a
/// sync job pins the port to a new Python release — it is a claim about which reference the
/// vectors came from, so it must never be derived or guessed. 4.0.0 here means ctrl-kd at
/// commit e9f6c42 (the b23 exports-overhaul merge onto main -- paragraph assembly, quote
/// continuity, RTF direct-formatting doctrine; ctrl-kd's own __version__ stayed 4.0.0
/// through that batch, same as it did through abb9d3c's, the prior pin).
public let ctrlKDParity = "4.0.0"

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

/// The one-line version claim, a function of the (build-time-injected) dev date so tests
/// can exercise the dev shape without a stamp. Deliberately NOT paired with a same-named
/// computed var: a top-level `var versionLine` alongside this overload can't call it —
/// the bare name inside the getter binds to the var itself (job 312 caught exactly that).
/// Callers pass `srDevDate`. Each paren group is one claim: the dev date says "cut
/// between releases, this fresh"; the parity says which reference the vectors came from.
public func versionLine(devDate: String?) -> String {
    let version = devDate.map { "\(srVersion) (dev \($0))" } ?? srVersion
    return "sr \(version) (ctrl-kd parity \(ctrlKDParity))"
}

/// What `--version` actually prints: the banner, then the version line.
public var versionOutput: String { slantBanner + "\n" + versionLine(devDate: srDevDate) }

/// Everything the run needs, after parsing and validation.
public struct Options: Equatable, Sendable {
    public var files: [String] = []
    /// Resolved, never empty — `["rtf"]` when no `-t` was given and the mode is (or
    /// defaults to) modern, `["pdf"]` for printed (ruling 2026-08-05: "each mode's bare
    /// run yields its best artifact" — modern's is the full-fidelity RTF, printed's is
    /// PDF, "the closest thing to actually printing"). Python's `formats = a.to or
    /// (['pdf'] if a.mode == 'printed' else ['rtf'])`. This field's own default (`["rtf"]`)
    /// matches `mode`'s default (`.modern`) so a directly-constructed `Options()` — not
    /// run through `parseArguments` — is self-consistent without having to know that rule.
    public var formats: [String] = ["rtf"]
    public var output: String?
    public var outdir: String?
    /// `.modern` by default (ruling 2026-08-05: "the converter is about bringing the old
    /// docs to a modern audience" — supersedes the earlier E4 ruling, which this project
    /// never carried out; see `modeExplicit` for whether the CLI caller actually asked).
    public var mode: EmitMode = .modern
    /// Whether `--mode` was actually given on the command line, as opposed to defaulted.
    /// Distinguishing the two is what lets a print stream or ruler-line document — which
    /// always renders printed regardless — say so on stderr only when the override
    /// silently defeats something the user explicitly asked for (D5), not on every bare
    /// run that never asked for modern in the first place.
    public var modeExplicit = false
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
    /// D7 ruling (2026-08-05): sr defaults to MAC font names -- it is the
    /// Mac tool, and its bare RTF should open true in Pages/TextEdit.
    /// ctrl-kd defaults to office. A sanctioned platform difference under
    /// the standardization principle, documented loudly in --help.
    public var fontsTarget: FontsTarget = .mac
    /// `--page-settings` (ctrl-kd's `--page-settings`/`page_settings=`; renamed from
    /// "page defaults" at every layer, ruling 2026-08-05), a preset name or raw values,
    /// parsed into `PageSettings`. `nil` when the flag was never given.
    public var pageSettings: PageSettings?
    /// `--note-refs word|prefixed` (ctrl-kd's `--note-refs`, ruling 2026-08-06 M8):
    /// note reference-mark display in Modern output. See `NoteRefs`.
    public var noteRefs: NoteRefs = .word
    /// Whether `--comments` itself was given (Python's `a.comments`) — read by the
    /// `--comments` + printed contradiction notice, which keys on the FLAG, not on the
    /// resolved note set (`--no-notes` wins the set but the notice still explains).
    public var commentsRequested = false
    /// `--headers {on,off}` (ctrl-kd's `--headers`, b24 round 17): headers, footers,
    /// and page numbers in the paged surfaces (Printed/Native PDF and RTF). Default on.
    public var headers = true
    /// `--line-numbers {on,off}` (ctrl-kd's `--line-numbers`, b24 round 17b): the
    /// document's own `.l#` line-number gutter in the paged surfaces. Default on.
    public var lineNumbers = true
    /// `--toc {on,off}` (ctrl-kd's `--toc`, b24 round 18 item 1): compile the document's
    /// `.tc`/`.ix` entries into a Table of Contents / Index section, in every format.
    /// Default off (the ruled default).
    public var toc = false
    /// `--inline-styling {on,off}` (ctrl-kd's `--inline-styling`, b24 round 18 item 2):
    /// the author's own inline colour and font-size changes. Default on (the ruled
    /// default — "the author's own styling shows; flag exists to strip").
    public var inlineStyling = true
    /// `--pictures {off,embed,export}` (ctrl-kd's `--pictures`, b24 round 19 —
    /// RULINGS-LEDGER PIX row, "PIX images RULED IN"): WS5+ `.PIX` image references.
    /// Default `.embed` (Jon's ruled default). See `EmitOptions.PixMode`'s own doc
    /// comment for what each mode does.
    public var pictures: EmitOptions.PixMode = .embed
    /// `--page-numbers {auto,on,off}` (ctrl-kd's `--page-numbers`, register b31, E3 item
    /// 2, ruled 2026-08-25): WordStar's own AUTOMATIC page number, Printed PDF only.
    /// Default `.auto` (the ruled default — the document's own dot commands decide).
    /// See `EmitOptions.PageNumberMode`'s own doc comment for what each mode does.
    public var pageNumbers: EmitOptions.PageNumberMode = .auto
    /// `--sentence-spacing {auto,keep,single}` (ctrl-kd's `--sentence-spacing`, b33 N9,
    /// mirrored from ctrl-kd 0750948, "same auto/on/off shape as --page-numbers"): the
    /// typewriter double space after a sentence-ending `.`, `?`, or `!`. Default
    /// `.auto` (the ruled default — Modern converts to a single space, Printed/Native
    /// keeps the document exactly as authored). See `EmitOptions.SentenceSpacingMode`'s
    /// own doc comment for what each mode does.
    public var sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    /// `--force`: accepted for compatibility with ctrl-kd (where it is a documented
    /// no-op — ctrl-kd always overwrites). Here it does real work: it bypasses `sr`'s own
    /// overwrite prompt/refusal (D4, the sanctioned Mac-vs-Unix platform divergence — "it's
    /// a Mac"). See `CLIEnvironment`'s `fileExists`/`stdinIsTTY`/`readLine` and `Run.swift`.
    public var force = false

    public init() {}
}

/// What the command line asked for.
public enum ParsedCommand: Equatable, Sendable {
    case run(Options)
    case help
    /// `verbose` is true when `--verbose` rides alongside `--version` (either order):
    /// it adds the exact engine commit to the output on dev builds — humans get the
    /// date on the banner, tracing gets the hash one flag away.
    case version(verbose: Bool)
    /// Argparse's `ap.error(...)`: the message, and exit status 2.
    case usageError(String)
    /// `--samples DIR` (S1): write the four bundled public-domain WordStar sample
    /// documents into DIR and stop. No Python analogue and no FILE positional — like
    /// `--help`/`--version`, parsing returns this the moment the flag is seen rather than
    /// falling through to the "files required" check below.
    case samples(String)
}

/// The variants `--variant` accepts. `binary` is missing on purpose, here as in Python
/// (cli.py:41): forcing "this is not a convertible file" is not an override anyone wants.
let variantChoices = ["ws4", "ws5+", "printstream", "text"]

let modeChoices = ["modern", "printed"]

/// `--fonts`. `FontsTarget` has exactly these four cases, so — as with `--mode` — the
/// initializer IS the validation and this list only spells the error message.
let fontsChoices = ["office", "mac", "google", "linux"]

/// `--note-refs`. Same pattern: `NoteRefs` has exactly these two cases.
let noteRefsChoices = ["word", "prefixed"]

/// `--pictures` (b24 round 18 item 3): reserved shape ahead of R19's actual wiring --
/// every use refuses, so this list only spells the error message's own choice set.
let picturesChoices = ["off", "embed", "export"]

/// `--page-numbers` (register b31, E3 item 2, ruled 2026-08-25). Same pattern:
/// `EmitOptions.PageNumberMode` has exactly these three cases.
let pageNumbersChoices = ["auto", "on", "off"]

/// `--sentence-spacing` (b33 N9, mirrored from ctrl-kd 0750948). Same pattern:
/// `EmitOptions.SentenceSpacingMode` has exactly these three cases.
let sentenceSpacingChoices = ["auto", "keep", "single"]

/// `--page-settings` presets (ruling 2026-08-05, D8): `default` is the explicit no-op —
/// WordStar factory geometry IS what an empty settings value means, since a document's own
/// resolved page already carries the factory numbers until something overrides them.
/// `sawyer` is Robert J. Sawyer's own WSCHANGE-recovered machine (DEFAULT.PAT vs
/// PRISTINE.PAT, the INIEDT block): mt ~=0.83in (1195/1440in, expressed here in the same
/// LINES-at-6-LPI unit `mtLines` always uses), mb exactly 1in, po 0.7in. `modern` is
/// Modern mode's own page, named and made inspectable: 1in margins on Letter (6 lines
/// top/bottom at 6 LPI, 10 columns at 10 CPI). Port of cli.py's `PAGE_PRESETS`.
let pagePresets: [String: PageSettings] = [
    "default": PageSettings(),
    "sawyer": PageSettings(mtLines: 1195.0 / 1440.0 * 6.0, mbLines: 6.0, poCols: 7.0),
    "modern": PageSettings(mtLines: 6.0, mbLines: 6.0, poCols: 10.0),
]

/// `--page-settings` parse outcome: the resolved geometry, or a usage-error message.
enum PageSettingsParseResult {
    case success(PageSettings)
    case failure(String)
}

/// Parse `--page-settings sawyer` or `--page-settings mt=0.83in,mb=1in,po=0.7in` into
/// `PageSettings`. Port of cli.py's inline parse (ctrl-kd's `--page-settings`, renamed
/// from `--page-defaults` at every layer, ruling 2026-08-05).
///
/// A preset name (`default`/`sawyer`/`modern`, matched case-insensitively after trimming)
/// is tried FIRST; anything else falls through to the raw `key=value,...` syntax, exactly
/// as cli.py's `if preset in PAGE_PRESETS: ... else: ...` does. Raw syntax: `mt`/`mb`/
/// `hm`/`fm` convert at 6 LPI (lines), `po` at 10 CPI (columns). A value ending in `in`
/// (case-insensitively, matched on the LOWERCASED string) converts from inches; a bare
/// number is already NATIVE units (lines, or columns for `po`) — same trap as the dot
/// commands themselves.
func parsePageSettings(_ arg: String) -> PageSettingsParseResult {
    let preset = Substring(arg).trimmingASCIIWhitespace().lowercased()
    if let known = pagePresets[preset] {
        return .success(known)
    }
    var result = PageSettings()
    for part in arg.split(separator: ",", omittingEmptySubsequences: false) {
        let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = pieces.count > 0 ? pieces[0].trimmingASCIIWhitespace().lowercased() : ""
        let rawValue = pieces.count > 1 ? pieces[1].trimmingASCIIWhitespace().lowercased() : ""
        let presetList = pagePresets.keys.sorted().joined(separator: ", ")
        if key == "size" {
            // the three main page sizes (ruled 2026-08-06) as .pl lines; width rides on
            // the height inference in the page model
            let sizes: [String: Double] = ["letter": 66.0, "legal": 84.0,
                                           "a4": 11.693 * 6]
            guard let pl = sizes[rawValue] else {
                return .failure("--page-settings: unknown size '\(rawValue)' "
                    + "(choose from a4, legal, letter)")
            }
            result.plLines = pl
            continue
        }
        guard !rawValue.isEmpty else {
            return .failure("--page-settings: unknown or empty entry '\(part)' "
                + "(or use a preset: \(presetList))")
        }
        let perInch: Double
        switch key {
        case "mt", "mb", "hm", "fm": perInch = 6.0
        case "po": perInch = 10.0
        default:
            return .failure("--page-settings: unknown or empty entry '\(part)' "
                + "(or use a preset: \(presetList))")
        }
        let value: Double
        if rawValue.hasSuffix("in") {
            guard let inches = Double(rawValue.dropLast(2)) else {
                return .failure("--page-settings: bad value in '\(part)'")
            }
            value = inches * perInch
        } else {
            guard let v = Double(rawValue) else {
                return .failure("--page-settings: bad value in '\(part)'")
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
            return .version(verbose: argv.contains("--verbose"))
        case "--samples":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            return .samples(value)
        case "--verbose":
            // Only meaningful beside --version (checked there by scanning the whole
            // argv, so the order doesn't matter); swallowed silently otherwise rather
            // than erroring, so `sr --verbose --version` and future uses both work.
            break
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
            options.modeExplicit = true
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
        case "--note-refs":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard let scheme = NoteRefs(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(noteRefsChoices)))")
            }
            options.noteRefs = scheme
        case "--headers":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard value == "on" || value == "off" else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' (choose from 'on', 'off')")
            }
            options.headers = value == "on"
        case "--line-numbers":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard value == "on" || value == "off" else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' (choose from 'on', 'off')")
            }
            options.lineNumbers = value == "on"
        case "--toc":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard value == "on" || value == "off" else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' (choose from 'on', 'off')")
            }
            options.toc = value == "on"
        case "--inline-styling":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard value == "on" || value == "off" else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' (choose from 'on', 'off')")
            }
            options.inlineStyling = value == "on"
        case "--pictures":
            // b24 round 19 (RULINGS-LEDGER PIX row): live -- the round-18 reservation
            // ("not yet wired") is gone now that R19 actually wires PIX embedding.
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard picturesChoices.contains(value), let mode = EmitOptions.PixMode(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(picturesChoices)))")
            }
            options.pictures = mode
        case "--page-numbers":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard pageNumbersChoices.contains(value),
                  let mode = EmitOptions.PageNumberMode(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(pageNumbersChoices)))")
            }
            options.pageNumbers = mode
        case "--sentence-spacing":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            guard sentenceSpacingChoices.contains(value),
                  let mode = EmitOptions.SentenceSpacingMode(rawValue: value) else {
                return .usageError(
                    "argument \(flag): invalid choice: '\(value)' "
                        + "(choose from \(quotedList(sentenceSpacingChoices)))")
            }
            options.sentenceSpacing = mode
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
        case "--page-settings":
            guard let value = takeValue(flag, attached: attached) else {
                return .usageError("argument \(flag): expected one argument")
            }
            switch parsePageSettings(value) {
            case .success(let parsed):
                options.pageSettings = parsed
            case .failure(let message):
                return .usageError(message)
            }
        case "--force":
            if attached != nil {
                return .usageError("argument \(flag): ignored explicit argument '\(attached!)'")
            }
            options.force = true
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
    // The default format follows the mode (ruling 2026-08-05): bare modern -> the
    // full-fidelity RTF; bare printed -> the facsimile PDF ("the closest thing to
    // actually printing"). Python's `formats = a.to or (['pdf'] if a.mode == 'printed'
    // else ['rtf'])`.
    if !formats.isEmpty {
        options.formats = formats
    } else {
        options.formats = options.mode == .printed ? ["pdf"] : ["rtf"]
    }
    // cli.py:78-81, verbatim: `--no-notes` empties the set outright; otherwise the
    // default three kinds, plus comments when `--comments` opted them in.
    if noNotes {
        options.notes = EmitOptions.noNotes
    } else if comments {
        options.notes = EmitOptions.allNotes
    }
    options.commentsRequested = comments

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
              [--page-settings PRESET|mt=..,mb=..,po=..] [--force]
              [--headers {on,off}] [--line-numbers {on,off}] [--toc {on,off}]
              [--inline-styling {on,off}] [--pictures {off,embed,export}]
              [--page-numbers {auto,on,off}] [--sentence-spacing {auto,keep,single}]
              [--no-styles] [--no-notes] [--comments] [--diagnose] [--samples DIR]
              FILE [FILE ...]

    Convert WordStar 4-7 documents and print-to-disk files to text, Markdown, HTML,
    RTF, or PDF. ^KD: save and done.

    positional arguments:
      FILE                  input file(s)

    options:
      -h, --help            show this help and exit
      --version             show the version and exit
      -t, --to FORMAT       output format, repeatable. Default follows the mode:
                            modern -> rtf (the full-fidelity living document),
                            printed -> pdf (the closest thing to actually printing)
                            choices: \(registry.formats().joined(separator: ", "))
      -o, --output FILE     output file (single input and single format only)
      -d, --outdir DIR      output directory for batch conversion
      --mode MODE           modern: the document brought to a modern audience --
                            reflowed, its own fonts carried, gaps filled with
                            today's conventions (default). printed: the 1990
                            facsimile -- line-for-line on the era page. Print
                            streams and ruler-line documents always render
                            printed (a notice is printed if you asked for modern)
      --variant VARIANT     override detection
                            choices: \(variantChoices.joined(separator: ", "))
      --fonts TARGET        RTF font-name target: mac (Cocoa-native, the
                            DEFAULT -- sr is the Mac tool; note ctrl-kd
                            defaults to office instead), office (Word/Docs),
                            google (Docs catalog), linux (URW base-35)
      --note-refs SCHEME    note reference-mark display in Modern output.
                            "word" (default): the Word standard -- arabic
                            footnotes, lowercase-roman endnotes, WordStar
                            tags for annotations. "prefixed": footnotes 1 2
                            3, endnotes e1 e2, annotations a1 a2 -- the same
                            labels the markdown output always uses, matched
                            across formats. Printed output is a facsimile
                            and ignores this.
      --page-settings P     page geometry for everything the document does not
                            declare itself (its own dot commands always win).
                            Presets: "default" (WordStar factory: mt 0.5in,
                            mb 1.33in, po 0.8in), "sawyer" (Robert J. Sawyer's own
                            WSCHANGE-recovered machine: mt 0.83in, mb 1in,
                            po 0.7in), "modern" (1in margins). Or raw values --
                            keys mt, mb, po, hm, fm, comma-separated, e.g.
                            mt=0.83in,mb=1in,po=0.7in -- an "in" suffix converts
                            from inches, else native units (lines at 6 LPI; po in
                            10-CPI columns). size=letter|legal|a4 names the sheet
                            for files that declare no page length
      --force               overwrite an existing output file without asking.
                            Without it, sr asks before overwriting when stdin is
                            a terminal, and refuses outright (suggesting
                            --force) in a script or pipeline -- ctrl-kd itself
                            always overwrites silently; this is the one place
                            sr's own defaults diverge from it ("it's a Mac")
      --headers {on,off}    headers, footers, and page numbers in the paged
                            surfaces (Printed/Native PDF and RTF). Default: on
      --line-numbers {on,off}
                            the document's own .l# line-number gutter in the
                            paged surfaces; no effect on a document that never
                            set .l#. Default: on
      --toc {on,off}        compile a Table of Contents (.tc) and Index (.ix)
                            section at the document end, in every format; the
                            two paged surfaces (Printed PDF and RTF) resolve
                            each entry to a real page number, every other
                            format lists entries without one. Default: off
      --inline-styling {on,off}
                            inline colour (^A) and font-size (^B... a symmetric
                            type-2 font block) changes the author placed mid-
                            text -- RTF gets \\cf from a 16-colour screen
                            palette and \\fsN; HTML gets a span with color/
                            font-size. Default: on
      --pictures {off,embed,export}
                            WS5+ PIX image references. embed (DEFAULT): RTF/PDF
                            native embedding, HTML data URI, MD exports files +
                            a one-line stderr note (MD has no true embed).
                            export: PNG files under <docname>-images/ beside
                            the output, relative links from HTML/MD; RTF/PDF
                            still embed (no portable reference mechanism) AND
                            the PNGs are also written. off: the plain
                            [image: NAME] placeholder, as before this flag
                            existed. A missing/unreadable .PIX is reported on
                            stderr (name + probed locations) and never fails
                            the conversion; the placeholder is kept either way.
      --page-numbers {auto,on,off}
                            WordStar's own AUTOMATIC page number -- the one
                            .pc positions, a separate mechanism from a # the
                            author placed inside a real .he/.fo (that always
                            prints, unaffected by this flag). Printed PDF
                            only. auto (DEFAULT): the document's own dot
                            commands decide -- .pn/.pg turn it on, .op turns
                            it off, exactly like real WordStar; a document
                            that never touches any of the four gets no
                            number, byte-identical to before this flag
                            existed. on: force stock default numbering
                            (bottom row a footer would use; .pc repositions
                            it) even on a silent document. off: suppress it
                            unconditionally. A declared footer always
                            pre-empts it, in every mode (WSFORMAT.WS: "active
                            only when the footers are not in use").
                            --headers off also suppresses it, per --headers'
                            own documented scope.
      --sentence-spacing {auto,keep,single}
                            the typewriter double space after a sentence-ending '.',
                            '?', or '!'. auto (DEFAULT): follows --mode -- modern
                            converts it to a single space (the modern typographic
                            convention); printed keeps the document exactly as
                            authored (period fidelity). keep/single force that
                            choice regardless of mode. A simple textual rule, no
                            abbreviation detection: "e.g.  x" collapses like a real
                            sentence end. Markdown never emits a trailing double
                            space from this either way (that is CommonMark's own
                            hard-break marker) -- unrelated to this flag, always on.
      --no-notes            omit footnotes, endnotes and annotations from the output
      --comments            include WordStar comments, which it never printed
                            (author's asides, hidden since the file was written)
      --diagnose            report what the file is (variant, margin, dot commands,
                            unknown codes, note counts, page geometry) as JSON;
                            no conversion
      --samples DIR         write the four bundled public-domain WordStar sample documents into DIR

    --encoding cp437 is accepted (and is the default); every other value is
    refused. The high-bit bytes in every known WordStar file are IBM-PC code
    page 437, and no non-437 corpus exists to validate another decoding
    against — the CLI refuses what it cannot verify.

    examples:
      sr PAPER.WS                       # -> PAPER.rtf, modern reflow, Georgia body
      sr PAPER.WS -t html -o out.html
      sr --mode printed LETTER          # -> LETTER.pdf, as it came off the printer
      sr --diagnose MYSTERY.FIL         # what IS this file?
      sr -t text -t html -d out/ *.WS   # batch, multiple formats
      sr -t rtf --fonts mac LETTER.WS   # font names TextEdit and Pages resolve
      sr --comments MEMO.WS             # include the author's hidden comments
      sr --no-notes PAPER.WS            # body text only, no notes
      sr --page-settings sawyer LETTER  # the DEFAULT.PAT-recovered machine's page
      sr --force PAPER.WS               # overwrite PAPER.rtf without asking
      sr --samples ./samples            # write the four bundled sample documents there
    """
}
