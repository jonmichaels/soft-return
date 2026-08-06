import Foundation
import Testing

@testable import CtrlKD
@testable import SoftReturnCLI

/// job-014: the `sr` command line — argument parsing, the conversion loop, and `--diagnose`
/// against the Python reference outputs in `Resources/job-014-vectors.json`.
///
/// The conversion loop runs against an in-memory `CLIEnvironment` rather than a temp
/// directory: what these tests are about is which destinations get written and what the
/// command says while writing them, and a dictionary answers that without a filesystem.
/// Process-level spawning of the built binary is deliberately not attempted — `swift run sr`
/// is exercised by hand and recorded in the job response.

/// job-014's vectors were machine-generated from Python 1.1.6 — before ctrl-kd 1.2.0's
/// note-model/page-geometry work — so the real reference's `diagnose()` now also emits
/// `notes` and `page` (and `producer`/`comment_bug` when applicable) that this fixture
/// never captured. Per the pattern already established for job-005/006/008/009/011's
/// stale footnote data (see `VectorTests.swift`), these new-in-1.2.0 keys are excluded
/// from the equivalence check below rather than the fixture being regenerated or the
/// test dropped: Swift's own `diagnose()` emitting them, and matching the real installed
/// Python reference's shape and values, is proven directly by the CLI-level tests below
/// (`diagnoseReportsNoteCountsForAllFourKinds`, `diagnoseReportsPageGeometry`,
/// `diagnoseReportsProducerWhenWordTsarCommandsAreSeen`,
/// `diagnoseReportsCommentBugForPrintstreamFiles`).
private let staleDiagnoseKeys: Set<String> = ["notes", "page", "producer", "comment_bug",
                                              "unknown_blocks", "footnotes"]  // footnotes: REMOVED in 1.2.0; unknown_blocks: added in 1.2.0

// MARK: - Diagnose, against the Python reference

@Test func diagnoseMatchesPythonReferenceVectors() throws {
    let vectors = try loadJob014Vectors()
    #expect(vectors.diagnoseReference.count == 4)

    for vector in vectors.diagnoseReference {
        let path = vector.pythonReferenceJSON.object?["file"]?.stringValue
        let got = diagnose(path: path ?? "/dev/null", data: bytesFromHex(vector.inputHex))

        // Equivalence, not byte identity (the ruling): same keys, same values, `file`
        // excluded because it is whatever path the generator happened to use.
        let mine = try #require(normalize(got).object, "diagnose must return an object")
        let theirs = try #require(vector.pythonReferenceJSON.object)
        // `staleDiagnoseKeys` must be filtered from BOTH sides: it covers keys ADDED in
        // 1.2.0 (absent from these 1.1.6-era vectors) and the flat `footnotes` count
        // REMOVED in 1.2.0 (present in them, and correctly gone from ours).
        let skip: (String) -> Bool = { staleDiagnoseKeys.contains($0) || $0 == "file" }
        #expect(
            mine.keys.sorted().filter { !skip($0) } == theirs.keys.sorted().filter { !skip($0) },
            "key set differs for \(vector.name)")
        for (key, expected) in theirs where !skip(key) {
            #expect(mine[key] == expected, "\(vector.name): \(key)")
        }
    }
}

/// The three shapes are the point of the vector set, so name them: WordStar files carry
/// parse evidence, plain detections carry counts only, and the empty/^Z case carries neither.
@Test func diagnoseShapesMatchPythonsThree() throws {
    let vectors = try loadJob014Vectors()
    func keys(_ name: String) throws -> [String] {
        let vector = try #require(vectors.diagnoseReference.first { $0.name == name })
        let value = diagnose(path: "/tmp/\(name)", data: bytesFromHex(vector.inputHex))
        return try #require(normalize(value).object).keys.sorted()
    }

    #expect(try keys("ws4_doc").contains("margin_estimate"))
    #expect(try keys("ws4_doc").contains("paragraphs"))
    // Detected but not WordStar: counts, no parse evidence.
    #expect(try keys("printstream").contains("size"))
    #expect(try !keys("printstream").contains("margin_estimate"))
    #expect(try !keys("printstream").contains("reason"))
    // Binary-by-threshold: counts AND a reason.
    #expect(try keys("binary").contains("reason"))
    #expect(try keys("binary").contains("text_pct"))
    // Empty/^Z: variant and reason, and nothing that would be a lie.
    #expect(try keys("empty_ctrlz") == ["file", "reason", "variant"])
}

@Test func diagnoseRendersSortedKeysAndTwoSpaceIndent() {
    let rendered = diagnose(path: "/tmp/printstream", data: bytes("Line one\r\nLine two\r\n")).render()
    #expect(
        rendered == """
            {
              "file": "/tmp/printstream",
              "hard_returns": 2,
              "high_bit_bytes": 0,
              "size": 20,
              "soft_returns": 0,
              "symmetric_blocks_1d": 0,
              "text_pct": 100,
              "variant": "printstream"
            }
            """)
}

/// `unknown_codes` is the job-004 bill coming due: the library counts by raw byte, and the
/// CLI is where those become Python's `"0x07"` keys.
@Test func diagnoseFormatsUnknownCodesAsHexStrings() throws {
    // ^G (0x07) is not a WordStar formatting code, so `_decode_spans` records it as unknown.
    let data = ws4Text("Alarm") + [0x07] + ws4Text(" bell") + HARD + makeProse()
    let value = diagnose(path: "/tmp/bell", data: data)
    let codes = try #require(normalize(value).object?["unknown_codes"]?.object)
    #expect(codes["0x07"] == .int(1))
}

@Test func diagnoseIgnoresTheVariantOverride() {
    // Python's diagnose() calls detect() and never looks at --variant; a run that forced a
    // variant would otherwise be told its own answer back.
    let recorder = Recorder(files: ["/in/PROSE.WS": makeProse()])
    let status = run(["--diagnose", "--variant", "printstream", "/in/PROSE.WS"],
                     environment: recorder.environment)
    #expect(status == ExitStatus.ok)
    #expect(recorder.out.first?.contains("\"variant\": \"ws4\"") == true)
}

// MARK: - Diagnose: ctrl-kd 1.2.0's new fields (notes, page, producer, comment_bug)

/// The trap this whole file's header warns about, aimed squarely at the new fields: go
/// through `run`, not `diagnose(path:data:)` directly, so a wiring mistake between the
/// command path and the library (an import error, a forgotten parameter) shows up here
/// the way it would for an actual user typing `sr --diagnose`.
@Test func diagnoseCommandPathReportsNoteCountsAndPage() throws {
    let recorder = Recorder(files: ["/in/SAMPLE.WS": fourKindData()])
    let status = run(["--diagnose", "/in/SAMPLE.WS"], environment: recorder.environment)
    #expect(status == ExitStatus.ok)
    #expect(recorder.err.isEmpty)
    let output = try #require(recorder.out.first)
    #expect(output.contains("\"footnote\": 1"))
    #expect(output.contains("\"endnote\": 1"))
    #expect(output.contains("\"annotation\": 1"))
    #expect(output.contains("\"comment\": 1"))
    #expect(output.contains("\"page\""))
    #expect(output.contains("\"size_name\": \"Letter\""))
}

/// Note kinds are reported separately, never flattened — a rescue tool converting a
/// file to plain text must still be able to say it has hidden comments.
@Test func diagnoseNotesObjectCountsEachKindSeparately() throws {
    let value = diagnose(path: "/tmp/four", data: fourKindData())
    let fields = try #require(normalize(value).object)
    let notes = try #require(fields["notes"]?.object, "notes must be an object, not flattened")
    #expect(notes["footnote"] == .int(1))
    #expect(notes["endnote"] == .int(1))
    #expect(notes["annotation"] == .int(1))
    #expect(notes["comment"] == .int(1))
}

/// A document with no notes at all still gets the `notes` object — every kind present,
/// zeroed — matching Python's dict comprehension, which never conditions on presence.
@Test func diagnoseNotesObjectIsAllZeroesWhenThereAreNoNotes() throws {
    let value = diagnose(path: "/tmp/plain", data: makeProse())
    let fields = try #require(normalize(value).object)
    let notes = try #require(fields["notes"]?.object)
    #expect(notes == ["footnote": .int(0), "endnote": .int(0), "annotation": .int(0), "comment": .int(0)])
}

@Test func diagnoseReportsResolvedPageGeometryWithProvenance() throws {
    let data = bytes(".pl 84") + HARD + bytes(".mt 6") + HARD + bytes(".mb 6") + HARD
        + bytes(".po 8") + HARD + ws7Block(0x00) + bytes("Body text here.") + HARD
    let value = diagnose(path: "/tmp/legal", data: data)
    let fields = try #require(normalize(value).object)
    let page = try #require(fields["page"]?.object)
    #expect(page["size_name"] == .string("Legal"))
    #expect(page["size_source"] == .string("file"))
    #expect(page["pl_lines"] == .double(84.0))
    #expect(page["height_in"] == .double(14.0))
    #expect(page["mt_lines"] == .double(6.0))
    #expect(page["mt_source"] == .string("file"))
    #expect(page["mb_lines"] == .double(6.0))
    #expect(page["mb_source"] == .string("file"))
    #expect(page["po_cols"] == .double(8.0))
    #expect(page["po_source"] == .string("file"))
    // `.lh` never changes here, so the one `lh_48` figure describes the whole document.
    #expect(page["lh_varies"] == .bool(false))
}

/// `.lh` is stateful, so the single `lh_48` figure is the document DEFAULT and can be an
/// incomplete description of the file. `lh_varies` is what tells a reader of this report
/// which of the two it is looking at — the diagnosis of the banner document that switches
/// leading fifteen times said "8" and stopped there.
@Test func diagnoseSaysWhenTheDocumentChangesItsLeading() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes(".lh 8") + HARD
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes(".lh 16") + HARD
    data += bytes("A tall line that must sit on its own sixteen forty-eighths lead.") + HARD
    let page = try #require(normalize(diagnose(path: "/tmp/banner", data: data))
        .object?["page"]?.object)
    #expect(page["lh_48"] == .double(8.0))        // still the first occurrence
    #expect(page["lh_source"] == .string("file"))
    #expect(page["lh_varies"] == .bool(true))
}

/// Nothing in the file sets page geometry, so every figure and source falls back to the
/// documented defaults (66 lines / US Letter).
@Test func diagnoseReportsDefaultPageGeometryWhenNothingOverridesIt() throws {
    let value = diagnose(path: "/tmp/plain", data: fourKindData())
    let fields = try #require(normalize(value).object)
    let page = try #require(fields["page"]?.object)
    #expect(page["size_name"] == .string("Letter"))
    #expect(page["size_source"] == .string("default"))
    #expect(page["pl_lines"] == .double(66.0))
    #expect(page["height_in"] == .double(11.0))
}

@Test func diagnoseReportsProducerOnlyWhenWordTsarCommandsAreSeen() throws {
    let withProducer = bytes(".PT 1") + HARD + ws7Block(0x00) + bytes("Body one.") + HARD
    let value = diagnose(path: "/tmp/wordtsar", data: withProducer)
    let fields = try #require(normalize(value).object)
    #expect(fields["producer"] == .string("wordtsar"))

    let without = ws7Block(0x00) + bytes("Body two.") + HARD
    let value2 = diagnose(path: "/tmp/plain", data: without)
    let fields2 = try #require(normalize(value2).object)
    #expect(fields2["producer"] == nil, "producer must be absent, not null, when not detected")
}

/// COMMENT.BUG is printstream-only: the documented signature (a line ending in a bare
/// LF instead of CR LF) is 1990s print-time damage, not a parse failure, and it only
/// ever shows up on the print-to-disk path — a ws4/ws5+ document never carries it.
@Test func diagnoseReportsCommentBugSignatureForPrintstreamFilesOnly() throws {
    let buggy = bytes("Line one\r\nLine two\r\nLine three\n")
    let value = diagnose(path: "/tmp/bug", data: buggy)
    let fields = try #require(normalize(value).object)
    #expect(fields["variant"] == .string("printstream"))
    let bug = try #require(fields["comment_bug"]?.object)
    #expect(bug["count"] == .int(1))
    #expect(bug["stray_ctrl_t"] == .bool(false))
    #expect(bug["first_offset"] != nil)

    // No bare-LF lines: the key must be absent entirely, not present-and-zero.
    let clean = bytes("Line one\r\nLine two\r\n")
    let cleanFields = try #require(normalize(diagnose(path: "/tmp/clean", data: clean)).object)
    #expect(cleanFields["comment_bug"] == nil)

    // A ws5+ document never runs the printstream path, so it never carries the key
    // either — even one whose text happens to include a bare 0x0A somewhere.
    let ws5Fields = try #require(normalize(diagnose(path: "/tmp/ws5", data: fourKindData())).object)
    #expect(ws5Fields["comment_bug"] == nil)
}

// MARK: - Argument surface

@Test func defaultFormatIsRTF() throws {
    // Ruling 2026-08-05: the default format follows the mode -- bare (modern) -> the
    // full-fidelity RTF, "each mode's bare run yields its best artifact". Supersedes the
    // old markdown-always default.
    let command = parseArguments(["PAPER.WS"])
    #expect(command == .run({
        var options = Options()
        options.files = ["PAPER.WS"]
        return options
    }()))
    guard case .run(let options) = command else { return }
    #expect(options.formats == ["rtf"])
    #expect(options.mode == .modern)
}

@Test func printedModeDefaultsToPDF() throws {
    // Same ruling: bare --mode printed -> PDF, "the closest thing to actually printing".
    guard case .run(let options) = parseArguments(["--mode", "printed", "PAPER.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.formats == ["pdf"])
    #expect(options.mode == .printed)
    #expect(options.modeExplicit)
}

@Test func explicitToFlagWinsOverTheModeDefault() throws {
    guard case .run(let options) = parseArguments(["--mode", "printed", "-t", "html", "PAPER.WS"])
    else {
        Issue.record("expected a run")
        return
    }
    #expect(options.formats == ["html"])
}

@Test func toFlagIsRepeatableAndKeepsOrder() throws {
    guard case .run(let options) = parseArguments(["-t", "text", "-t", "html", "PAPER.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.formats == ["text", "html"])
}

@Test func toFlagAcceptsAliasesAndRejectsUnknownFormats() {
    guard case .run(let options) = parseArguments(["--to=md", "PAPER.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.formats == ["md"])

    guard case .usageError(let message) = parseArguments(["-t", "docx", "PAPER.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message.contains("invalid choice: 'docx'"))
    #expect(message.contains("'markdown'"))
}

/// The guard is on both halves of the product — several inputs OR several formats — and
/// Python's message is kept verbatim because it names the fix.
@Test func outputFlagRequiresASingleInputAndASingleFormat() {
    let expected = "-o works with a single input and a single format; use -d for batch"

    #expect(parseArguments(["-o", "out.md", "A.WS", "B.WS"]) == .usageError(expected))
    #expect(parseArguments(["-o", "out.md", "-t", "text", "-t", "html", "A.WS"]) == .usageError(expected))

    guard case .run(let options) = parseArguments(["-o", "out.html", "-t", "html", "A.WS"]) else {
        Issue.record("single input + single format must be accepted")
        return
    }
    #expect(options.output == "out.html")
}

@Test func modeAndVariantAreValidatedAgainstTheirChoices() {
    guard case .run(let options) = parseArguments(["--mode", "printed", "--variant", "ws5+", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.mode == .printed)
    #expect(options.variant == .ws5plus)

    guard case .usageError(let modeError) = parseArguments(["--mode", "sideways", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(modeError.contains("'modern', 'printed'"))

    // `binary` is a Variant the library knows and NOT a choice this flag accepts — forcing it
    // could only produce "not a convertible file".
    guard case .usageError(let variantError) = parseArguments(["--variant", "binary", "A.WS"]) else {
        Issue.record("--variant binary must be refused")
        return
    }
    #expect(variantError.contains("invalid choice: 'binary'"))
}

@Test func missingValuesAndUnknownFlagsAreUsageErrors() {
    #expect(parseArguments(["-t"]) == .usageError("argument -t: expected one argument"))
    #expect(parseArguments(["--outdir"]) == .usageError("argument --outdir: expected one argument"))
    #expect(parseArguments(["--sideways", "A.WS"]) == .usageError("unrecognized arguments: --sideways"))
    #expect(parseArguments([]) == .usageError("the following arguments are required: files"))
}

@Test func attachedFormsAndTheEndOfOptionsMarkerParse() {
    guard case .run(let attached) = parseArguments(["-thtml", "-o/tmp/x.html", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(attached.formats == ["html"])
    #expect(attached.output == "/tmp/x.html")

    // After `--`, a file may be named anything, including `--mode`.
    guard case .run(let separated) = parseArguments(["--", "--mode"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(separated.files == ["--mode"])
}

/// The dropped flag answers for itself rather than falling through to "unrecognized" —
/// somebody with a ctrl-kd command line in their shell history deserves the reason.
@Test func encodingAcceptsOnlyCP437() {
    // Standardized with ctrl-kd (2026-08-05): the flag exists, cp437 is the
    // one accepted value (a no-op), anything else is refused with the
    // no-corpus-to-validate-against reasoning.
    guard case .run = parseArguments(["--encoding", "cp437", "A.WS"]) else {
        Issue.record("--encoding cp437 must be accepted as a no-op")
        return
    }
    guard case .usageError(let message) = parseArguments(["--encoding", "latin-1", "A.WS"]) else {
        Issue.record("expected a usage error for a non-437 encoding")
        return
    }
    #expect(message.contains("cp437"))
    #expect(message.contains("corpus"))
}

@Test func versionLineNamesBothTheCLIAndTheReference() {
    #expect(versionLine == "sr 3.0.0 (ctrl-kd parity 4.0.0)")

    let recorder = Recorder()
    #expect(run(["--version"], environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.out == [versionOutput])
    #expect(versionOutput.hasSuffix("sr 3.0.0 (ctrl-kd parity 4.0.0)"))
    #expect(versionOutput.contains("_____       ______     ____"))  // the SOFT RETURN Slant banner leads
    #expect(recorder.written.isEmpty)
}

@Test func helpPromisesOnlyWhatExists() {
    let help = helpText()
    #expect(!help.lowercased().contains("plugin"))
    #expect(help.contains("--encoding"))
    #expect(help.contains("cp437"))
    #expect(help.contains("--diagnose"))
    #expect(help.contains("--no-notes"))
    #expect(help.contains("--no-styles"))
    #expect(help.contains("--comments"))
    for format in EmitterRegistry.standard.formats() {
        #expect(help.contains(format))
    }
}

// MARK: - Style pass-through (--no-styles)

@Test func stylePassThroughIsOnByDefaultAndOffWithTheFlag() {
    guard case .run(let byDefault) = parseArguments(["A.WS"]),
          case .run(let off) = parseArguments(["--no-styles", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(byDefault.styles)
    #expect(!off.styles)

    guard case .usageError(let message) = parseArguments(["--no-styles=x", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message.contains("ignored explicit argument"))
}

// MARK: - Render target (--fonts)

@Test func fontsTargetDefaultsToMacAndValidatesItsChoices() {
    // Jon's ruling, 2026-08-04 night: office is the DEFAULT because it is the widest
    // single answer — Word and Google Docs both resolve the Microsoft names.
    guard case .run(let byDefault) = parseArguments(["A.WS"]),
          case .run(let mac) = parseArguments(["--fonts", "mac", "A.WS"]),
          case .run(let linux) = parseArguments(["--fonts", "linux", "A.WS"]),
          case .run(let attached) = parseArguments(["--fonts=google", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    // D7 ruling: sr is the Mac tool -- mac names by default
    // (ctrl-kd defaults to office; a sanctioned platform difference)
    #expect(byDefault.fontsTarget == .mac)
    #expect(mac.fontsTarget == .mac)
    #expect(linux.fontsTarget == .linux)
    #expect(attached.fontsTarget == .google)
    // Every case of the enum is a choice and every choice is a case — the list that
    // spells the error message cannot drift from the vocabulary it describes.
    #expect(fontsChoices == FontsTarget.allCases.map(\.rawValue))

    guard case .usageError(let message) = parseArguments(["--fonts", "libreoffice", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message.contains("invalid choice: 'libreoffice'"))
    #expect(message.contains("'office', 'mac', 'google', 'linux'"))
}

// MARK: - Note selection (--no-notes / --comments)

@Test func defaultNotesOmitCommentsOnly() {
    guard case .run(let options) = parseArguments(["A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.notes == EmitOptions.defaultNotes)
    #expect(!options.notes.contains(.comment))
}

@Test func noNotesFlagEmptiesTheNoteSet() {
    guard case .run(let options) = parseArguments(["--no-notes", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.notes == EmitOptions.noNotes)
    #expect(options.notes.isEmpty)
}

@Test func commentsFlagAddsCommentsWithoutDisplacingTheDefaults() {
    guard case .run(let options) = parseArguments(["--comments", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.notes == EmitOptions.allNotes)
    #expect(options.notes.isSuperset(of: EmitOptions.defaultNotes))
}

/// cli.py:78-81 — `--no-notes` wins outright: its branch never even looks at
/// `a.comments`. `--comments` alone with no `--no-notes` must not be silently ignored.
@Test func noNotesWinsOverComments() {
    guard case .run(let options) = parseArguments(["--no-notes", "--comments", "A.WS"]) else {
        Issue.record("expected a run")
        return
    }
    #expect(options.notes == EmitOptions.noNotes)
}

@Test func noNotesAndCommentsRejectAnAttachedValue() {
    guard case .usageError(let message) = parseArguments(["--no-notes=x", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message.contains("ignored explicit argument"))

    guard case .usageError(let message2) = parseArguments(["--comments=x", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message2.contains("ignored explicit argument"))
}

/// The library work is proven at the API level (`EmitOptions.notes`); what only the CLI
/// can prove is that the flag actually reaches the emitter through `run`'s conversion
/// loop, which is exactly the kind of wiring the import-error trap (see the file
/// header) shows unit tests of the API alone can miss.
@Test func defaultRunIncludesNotesButNeverComments() throws {
    let recorder = Recorder(files: ["/in/SAMPLE.WS": fourKindData()])
    #expect(run(["-t", "text", "/in/SAMPLE.WS"], environment: recorder.environment) == ExitStatus.ok)
    let text = String(decoding: try #require(recorder.written["/in/SAMPLE.txt"]), as: UTF8.self)
    #expect(text.contains("Footnote text."))
    #expect(text.contains("Endnote text."))
    #expect(text.contains("Annotation text"))
    #expect(!text.contains("Comment text."), "WordStar itself never printed comments")
}

@Test func noNotesFlagReachesTheEmitterAndSuppressesAllFourKinds() throws {
    let recorder = Recorder(files: ["/in/SAMPLE.WS": fourKindData()])
    #expect(run(["--no-notes", "-t", "text", "/in/SAMPLE.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    let text = String(decoding: try #require(recorder.written["/in/SAMPLE.txt"]), as: UTF8.self)
    for gone in ["Footnote text.", "Endnote text.", "Annotation text", "Comment text."] {
        #expect(!text.contains(gone), "\(gone) must be gone under --no-notes")
    }
}

@Test func commentsFlagReachesTheEmitterWithoutDisplacingTheDefaults() throws {
    let recorder = Recorder(files: ["/in/SAMPLE.WS": fourKindData()])
    #expect(run(["--comments", "-t", "text", "/in/SAMPLE.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    let text = String(decoding: try #require(recorder.written["/in/SAMPLE.txt"]), as: UTF8.self)
    #expect(text.contains("Comment text."))
    #expect(text.contains("Footnote text."))
}

// MARK: - The conversion loop

@Test func conversionWritesBesideTheInputByDefault() {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    let status = run(["/archive/PAPER.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.ok)
    // Bare invocation is Modern RTF now (ruling 2026-08-05) — .md was the old default.
    #expect(Array(recorder.written.keys) == ["/archive/PAPER.rtf"])
    // Status lines go to STDERR: on stdout they land inside the converted
    // document whenever the destination is /dev/stdout or a pipe (both CLIs
    // carried this defect; fixed together 2026-08-04).
    #expect(recorder.out.isEmpty)
    #expect(recorder.err == ["/archive/PAPER.WS -> /archive/PAPER.rtf"])
    #expect(recorder.createdDirectories.isEmpty)
}

@Test func bareFilenameWritesToTheCurrentDirectory() {
    // Python's `os.path.dirname(path) or '.'` — a bare name has no directory part.
    let recorder = Recorder(files: ["PAPER.WS": makeProse()])
    #expect(run(["PAPER.WS"], environment: recorder.environment) == ExitStatus.ok)
    #expect(Array(recorder.written.keys) == ["./PAPER.rtf"])
}

@Test func outdirIsCreatedAndUsedForEveryFormat() {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    let status = run(["-t", "text", "-t", "html", "-d", "/out", "/archive/PAPER.WS"],
                     environment: recorder.environment)

    #expect(status == ExitStatus.ok)
    #expect(recorder.written.keys.sorted() == ["/out/PAPER.html", "/out/PAPER.txt"])
    #expect(recorder.createdDirectories == ["/out", "/out"])
}

@Test func outputFlagNamesTheDestinationExactly() {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-o", "/tmp/anything.txt", "-t", "text", "/archive/PAPER.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    #expect(Array(recorder.written.keys) == ["/tmp/anything.txt"])
}

@Test func diagnoseConvertsNothing() {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    let status = run(["--diagnose", "/archive/PAPER.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.ok)
    #expect(recorder.written.isEmpty, "--diagnose must not write output files")
    #expect(recorder.out.count == 1)
    // Sorted keys put `columnar` first for a WordStar file, so this is a contains, not a prefix.
    #expect(recorder.out.first?.contains("\"file\": \"/archive/PAPER.WS\"") == true)
    #expect(recorder.out.first?.hasPrefix("{\n  \"columnar\"") == true)
}

/// `--diagnose` is what you reach for when a file will not convert, so it must work on
/// exactly those files.
@Test func diagnoseWorksOnFilesThatCannotBeParsed() {
    let recorder = Recorder(files: ["/archive/MYSTERY.FIL": (0..<32).map(UInt8.init)])
    let status = run(["--diagnose", "/archive/MYSTERY.FIL"], environment: recorder.environment)

    #expect(status == ExitStatus.ok)
    #expect(recorder.err.isEmpty)
    #expect(recorder.out.first?.contains("\"variant\": \"binary\"") == true)
}

@Test func aBinaryFileFailsThatFileWithAdvice() {
    let recorder = Recorder(files: ["/archive/MYSTERY.FIL": (0..<32).map(UInt8.init)])
    let status = run(["/archive/MYSTERY.FIL"], environment: recorder.environment)

    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.written.isEmpty)
    #expect(recorder.err.first?.contains("not a convertible file (detected: binary)") == true)
    #expect(recorder.err.first?.contains("--variant to force") == true)
}

@Test func anUnreadableFileFailsOnlyItself() {
    let recorder = Recorder(files: ["/archive/GOOD.WS": makeProse()])
    let status = run(["/archive/MISSING.WS", "/archive/GOOD.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.fileFailure, "one bad input must not make the run succeed")
    #expect(Array(recorder.written.keys) == ["/archive/GOOD.rtf"], "the good file still converts")
    // stderr carries the failure for MISSING.WS plus GOOD's status line
    #expect(recorder.err.count == 2)
    #expect(recorder.err.contains("/archive/GOOD.WS -> /archive/GOOD.rtf"))
}

@Test func usageErrorsExitTwoAndSayUsage() {
    let recorder = Recorder()
    let status = run(["-o", "out.md", "A.WS", "B.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.usage)
    #expect(recorder.err.first?.hasPrefix("usage: sr") == true)
    #expect(recorder.err.last?.contains("use -d for batch") == true)
    #expect(recorder.out.isEmpty)
}

/// The `EmitOutput` switch: a text format is written as UTF-8, a binary one as itself.
@Test func binaryAndTextFormatsBothReachDiskAsBytes() throws {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-t", "pdf", "-t", "markdown", "-d", "/out", "/archive/PAPER.WS"],
                environment: recorder.environment) == ExitStatus.ok)

    let pdf = try #require(recorder.written["/out/PAPER.pdf"])
    #expect(Array(pdf.prefix(5)) == bytes("%PDF-"))
    let markdown = try #require(recorder.written["/out/PAPER.md"])
    #expect(String(decoding: markdown, as: UTF8.self).contains("Second paragraph."))
}

@Test func theTitleOptionCarriesTheInputsStem() throws {
    // Python passes `title=base` to every emitter (cli.py:71); HTML is the one that reads it.
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-t", "html", "/archive/PAPER.WS"], environment: recorder.environment) == ExitStatus.ok)
    let html = try #require(recorder.written["/archive/PAPER.html"])
    #expect(String(decoding: html, as: UTF8.self).contains("<title>PAPER</title>"))
}

@Test func modeReachesTheEmitter() throws {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["--mode", "printed", "-t", "text", "/archive/PAPER.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    let printed = try #require(recorder.written["/archive/PAPER.txt"])

    let recorder2 = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-t", "text", "/archive/PAPER.WS"], environment: recorder2.environment) == ExitStatus.ok)
    let modern = try #require(recorder2.written["/archive/PAPER.txt"])

    // Printed keeps WordStar's own line breaks; modern reflows them into one long line.
    #expect(printed != modern)
}

@Test func variantOverrideChangesHowTheFileIsParsed() throws {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["--variant", "printstream", "-t", "text", "/archive/PAPER.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    let forced = String(decoding: try #require(recorder.written["/archive/PAPER.txt"]), as: UTF8.self)

    let recorder2 = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-t", "text", "/archive/PAPER.WS"], environment: recorder2.environment) == ExitStatus.ok)
    let natural = String(decoding: try #require(recorder2.written["/archive/PAPER.txt"]), as: UTF8.self)

    // Detection says ws4, which reflows the soft-wrapped lines into one paragraph. Forced to
    // printstream, the same bytes keep every line break — so the override reached `parse`
    // rather than merely agreeing with detection.
    #expect(forced.contains("words\ny"))
    #expect(natural.contains("words y"))
}

@Test func aWriteFailureIsReportedAndDoesNotStopTheRun() {
    let recorder = Recorder(files: ["/archive/A.WS": makeProse(), "/archive/B.WS": makeProse()])
    recorder.refuseWritesTo = "/archive/A.rtf"
    let status = run(["/archive/A.WS", "/archive/B.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.fileFailure)
    #expect(Array(recorder.written.keys) == ["/archive/B.rtf"])
    #expect(recorder.err.first?.contains("/archive/A.rtf") == true)
}

// MARK: - The wholesale-defaults batch (CLI-Defaults-Audit, all ruled 2026-08-05)

@Test func bareInvocationIsModernRTF() throws {
    // THE ruling: "the converter is about bringing the old docs to a modern audience" --
    // no flags means Modern RTF, Georgia 14 body, modern page. Port of
    // `test_bare_invocation_is_modern_rtf`.
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    #expect(run(["/archive/DOC.WS"], environment: recorder.environment) == ExitStatus.ok)
    let out = String(decoding: try #require(recorder.written["/archive/DOC.rtf"]), as: UTF8.self)
    #expect(out.hasPrefix(#"{\rtf1"#))
    #expect(out.contains(#"{\f0 Georgia{\*\falt Times New Roman};}"#))
    #expect(out.contains(#"\f0\fs28"#))                   // the cozy-book 14pt
    #expect(out.contains(#"\paperw12240"#))
    #expect(out.contains(#"\margl1440"#))
}

@Test func printedModeDefaultsToPDFEndToEnd() throws {
    // Port of `test_printed_mode_defaults_to_pdf`.
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    #expect(run(["--mode", "printed", "/archive/DOC.WS"], environment: recorder.environment)
            == ExitStatus.ok)
    let pdf = try #require(recorder.written["/archive/DOC.pdf"])
    #expect(pdf.starts(with: bytes("%PDF-1.4")))
}

@Test func pageSettingsPresets() throws {
    // sawyer: the DEFAULT.PAT machine (mt ~0.83in -> margt 1195/1440*1440 twips = 1195...
    // in lines*240: 4.979*240 = 1195); default: factory page. Port of
    // `test_page_settings_presets`.
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    #expect(run(["--mode", "printed", "-t", "rtf", "--page-settings", "sawyer", "/archive/DOC.WS"],
                environment: recorder.environment) == ExitStatus.ok)
    let sawyer = String(decoding: try #require(recorder.written["/archive/DOC.rtf"]), as: UTF8.self)
    #expect(sawyer.contains(#"\margt1195"#))
    #expect(sawyer.contains(#"\margb1440"#))
    #expect(sawyer.contains(#"\margl1008"#))

    let recorder2 = Recorder(files: ["/archive/DOC.WS": makeProse()])
    #expect(run(["--mode", "printed", "-t", "rtf", "--page-settings", "default", "/archive/DOC.WS"],
                environment: recorder2.environment) == ExitStatus.ok)
    let factory = String(decoding: try #require(recorder2.written["/archive/DOC.rtf"]), as: UTF8.self)
    #expect(factory.contains(#"\margt720"#))
    #expect(factory.contains(#"\margb1920"#))              // factory 0.5/1.33in
}

@Test func forcedPrintedNoticeOnExplicitModern() throws {
    // D5: a print stream cannot reflow; an EXPLICIT --mode modern gets one stderr line
    // saying so. The default (no --mode) stays quiet. Port of
    // `test_forced_printed_notice_on_explicit_modern`.
    let stream = bytes("Line one of a printed page\r\nLine two of it\r\n") + [0x1a]
    let recorder = Recorder(files: ["/archive/CAP.PRN": stream])
    #expect(run(["--mode", "modern", "-t", "text", "/archive/CAP.PRN"],
                environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.err.contains { $0.contains("modern reflow is not possible") })

    let recorder2 = Recorder(files: ["/archive/CAP2.PRN": stream])
    #expect(run(["-t", "text", "/archive/CAP2.PRN"], environment: recorder2.environment)
            == ExitStatus.ok)
    #expect(!recorder2.err.contains { $0.contains("modern reflow") })
}

// MARK: - D4: sr's own overwrite prompt (ruled platform divergence, "it's a Mac";
// ctrl-kd's own --force is a documented no-op, ctrl-kd always overwrites silently)

@Test func forceFlagIsAccepted() throws {
    // Port of `test_force_flag_is_accepted` (there, a no-op; here, real: bypasses D4).
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    recorder.existingFiles.insert("/archive/DOC.rtf")
    #expect(run(["--force", "/archive/DOC.WS"], environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.written["/archive/DOC.rtf"] != nil)
}

@Test func overwriteIsSilentWhenTheDestinationIsNew() throws {
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    #expect(run(["/archive/DOC.WS"], environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.written["/archive/DOC.rtf"] != nil)
    #expect(recorder.err.allSatisfy { !$0.contains("already exists") })
}

@Test func overwriteIsRefusedOutrightWhenStdinIsNotATTY() throws {
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    recorder.existingFiles.insert("/archive/DOC.rtf")
    recorder.isTTY = false
    let status = run(["/archive/DOC.WS"], environment: recorder.environment)
    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.written["/archive/DOC.rtf"] == nil)
    #expect(recorder.err.contains { $0.contains("already exists") && $0.contains("--force") })
}

@Test func overwriteAsksAndProceedsOnYesWhenStdinIsATTY() throws {
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    recorder.existingFiles.insert("/archive/DOC.rtf")
    recorder.isTTY = true
    recorder.answers = ["y"]
    #expect(run(["/archive/DOC.WS"], environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.written["/archive/DOC.rtf"] != nil)
}

@Test func overwriteAsksAndRefusesOnAnythingButYes() throws {
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    recorder.existingFiles.insert("/archive/DOC.rtf")
    recorder.isTTY = true
    recorder.answers = ["n"]
    let status = run(["/archive/DOC.WS"], environment: recorder.environment)
    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.written["/archive/DOC.rtf"] == nil)
}

@Test func overwriteAtEOFOnAPromptIsTreatedAsNo() throws {
    // An unanswerable prompt (stdin closed mid-run) must never fall through to
    // overwriting — silently hanging or silently agreeing are both worse than refusing.
    let recorder = Recorder(files: ["/archive/DOC.WS": makeProse()])
    recorder.existingFiles.insert("/archive/DOC.rtf")
    recorder.isTTY = true
    recorder.answers = []                                  // EOF
    let status = run(["/archive/DOC.WS"], environment: recorder.environment)
    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.written["/archive/DOC.rtf"] == nil)
}

// MARK: - Gaps the job-014 mutation run found

/// `diagnose-ws5-dropped`: the parse-evidence keys are for `ws4` OR `ws5+`, and every test
/// above happened to use a ws4 fixture — so dropping the `ws5+` half of the condition
/// changed nothing any test could see.
@Test func diagnoseReportsParseEvidenceForWS5Files() throws {
    let data = ws7Block(0x00) + bytes("Treaties were made.")
        + ws7Note(bytes("See the 1868 accords."))
        + bytes(" More text follows here.") + HARD
    let value = diagnose(path: "/tmp/ws7", data: data)
    let fields = try #require(normalize(value).object)

    #expect(fields["variant"] == .string("ws5+"))
    #expect(fields["margin_estimate"] != nil, "a ws5+ file must carry parse evidence too")
    #expect(fields["columnar"] == .bool(false))
    // `diagnose-footnote-count`: nothing above used a file that HAS a footnote, so reporting
    // a constant zero was invisible. ctrl-kd 1.2.0 dropped the flat `footnotes` count in
    // favour of the per-kind `notes` object -- a single number could not tell a footnote
    // from an endnote from an annotation, which is the whole point of the rework.
    #expect(fields["footnotes"] == nil, "the flat count was removed in 1.2.0")
    if case .object(let kinds)? = fields["notes"] {
        #expect(kinds["footnote"] == .int(1))
    } else {
        Issue.record("diagnose must report a per-kind notes object")
    }
}

/// `diagnose-paragraph-filter`: `paragraphs` counts `.para` blocks, not blocks. Every fixture
/// above was all-paragraphs, which makes the filter and the plain count the same number.
@Test func diagnoseCountsParagraphBlocksOnly() throws {
    let data = ws4Text("Page one text here.") + HARD + bytes(".pa") + HARD
        + ws4Text("Page two text here.") + HARD
    let doc = parseWS(data)
    #expect(doc.blocks.map(\.kind) == [.para, .pagebreak, .para], "the fixture must have a non-para block")

    let fields = try #require(normalize(diagnose(path: "/tmp/pa", data: data)).object)
    #expect(fields["variant"] == .string("ws4"), "the .pa block only reaches diagnose via a WordStar detection")
    #expect(fields["paragraphs"] == .int(2))
    #expect(fields["dot_commands"] == .array([.string(".pa")]))
}

/// `run-usage-exit-code`: asserting `status == ExitStatus.usage` compares the code to itself,
/// so changing the constant kept every such test passing. The numbers are the contract a
/// shell script reads, so pin the numbers.
@Test func exitStatusesAreTheNumbersAShellScriptExpects() {
    #expect(ExitStatus.ok == 0)
    #expect(ExitStatus.fileFailure == 1)
    #expect(ExitStatus.usage == 2, "argparse exits 2 on a usage error and so does sr")

    let usage = Recorder()
    #expect(run(["-o", "out.md", "A.WS", "B.WS"], environment: usage.environment) == 2)

    let missing = Recorder()
    #expect(run(["/nowhere/A.WS"], environment: missing.environment) == 1)

    let fine = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["/archive/PAPER.WS"], environment: fine.environment) == 0)
}

/// `run-text-not-utf8` and `run-data-truncated`: every assertion on written output was a
/// `contains` or a prefix, so truncating either arm of the `EmitOutput` switch slipped
/// through. What the CLI writes must be exactly what the library produced — no more, no less.
@Test func writtenBytesAreExactlyTheLibrarysOutput() throws {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    #expect(run(["-t", "markdown", "-t", "pdf", "-d", "/out", "/archive/PAPER.WS"],
                environment: recorder.environment) == ExitStatus.ok)

    let markdown = try convert(makeProse(), to: "markdown", options: EmitOptions(title: "PAPER"))
    #expect(recorder.written["/out/PAPER.md"] == Array(markdown.utf8))

    let pdf = try convertData(makeProse(), to: "pdf", options: EmitOptions(title: "PAPER"))
    #expect(recorder.written["/out/PAPER.pdf"] == pdf)
    #expect(pdf.count > 400, "the comparison is only worth something if the PDF has content")
}

// MARK: - Path handling

@Test func pathHelpersFollowPythonsRules() {
    #expect(stem("/a/b/PAPER.WS") == "PAPER")
    #expect(stem("PAPER") == "PAPER")
    #expect(stem("/a/.bashrc") == ".bashrc", "a leading dot is a name, not an extension")
    #expect(stem("/a/archive.tar.gz") == "archive.tar")
    #expect(dirname("/a/b/PAPER.WS") == "/a/b")
    #expect(dirname("PAPER.WS") == "")
    #expect(dirname("/PAPER.WS") == "/")
    #expect(joinPath("/out", "x.md") == "/out/x.md")
    #expect(joinPath("/out/", "x.md") == "/out/x.md")
    #expect(joinPath("", "x.md") == "x.md")
}

// MARK: - The JSON writer

@Test func jsonWriterMatchesPythonsIndentedShape() {
    let value = JSONValue.object([
        "b": .array([.int(1), .object(["z": .bool(false), "a": .null])]),
        "a": .string("quote\" backslash\\ tab\t"),
        "empty_object": .object([:]),
        "empty_array": .array([]),
    ])
    #expect(
        value.render() == """
            {
              "a": "quote\\" backslash\\\\ tab\\t",
              "b": [
                1,
                {
                  "a": null,
                  "z": false
                }
              ],
              "empty_array": [],
              "empty_object": {}
            }
            """)
}

@Test func jsonWriterEscapesControlBytes() {
    #expect(JSONValue.string("\u{01}\u{08}\u{0C}\r\n").render() == "\"\\u0001\\b\\f\\r\\n\"")
}

// MARK: - Support

/// An in-memory `CLIEnvironment` plus the record of what was done to it.
///
/// `@unchecked Sendable`: `run` is synchronous and single-threaded, so the closures below
/// never touch this from two places at once — the annotation buys the mutable state past
/// `CLIEnvironment`'s `@Sendable` requirement without a lock that would guard nothing.
private final class Recorder: @unchecked Sendable {
    var files: [String: [UInt8]]
    var written: [String: [UInt8]] = [:]
    var createdDirectories: [String] = []
    var out: [String] = []
    var err: [String] = []
    /// Destination that fails to write, for the error path.
    var refuseWritesTo: String?
    /// Destinations the D4 overwrite gate should treat as already existing — separate from
    /// `written` (which only grows once a write actually happens) so a test can simulate a
    /// pre-existing file the run never itself created.
    var existingFiles: Set<String> = []
    /// D4's TTY test. `false` (a script/pipeline) by default, matching production's own
    /// safer default when nothing overrides it.
    var isTTY = false
    /// Canned answers to the D4 y/n prompt, consumed in order; `nil` (the default, an
    /// empty queue) means EOF — treated as "no", same as production's real stdin closing.
    var answers: [String] = []

    init(files: [String: [UInt8]] = [:]) {
        self.files = files
    }

    struct NoSuchFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no such file or directory" }
    }

    struct WriteRefused: Error, CustomStringConvertible {
        var description: String { "permission denied" }
    }

    var environment: CLIEnvironment {
        CLIEnvironment(
            readFile: { [self] path in
                guard let data = files[path] else { throw NoSuchFile(path: path) }
                return data
            },
            writeFile: { [self] path, data in
                if path == refuseWritesTo { throw WriteRefused() }
                written[path] = data
            },
            createDirectory: { [self] path in createdDirectories.append(path) },
            writeOut: { [self] line in out.append(line) },
            writeErr: { [self] line in err.append(line) },
            fileExists: { [self] path in existingFiles.contains(path) || written[path] != nil },
            stdinIsTTY: { [self] in isTTY },
            readLine: { [self] in answers.isEmpty ? nil : answers.removeFirst() }
        )
    }
}

private struct Job014Vectors: Decodable {
    let note: String
    let diagnoseReference: [DiagnoseVector]

    enum CodingKeys: String, CodingKey {
        case note
        case diagnoseReference = "diagnose_reference"
    }
}

private struct DiagnoseVector: Decodable {
    let name: String
    let inputHex: String
    let pythonReferenceJSON: RefJSON

    enum CodingKeys: String, CodingKey {
        case name
        case inputHex = "input_hex"
        case pythonReferenceJSON = "python_reference_json"
    }
}

/// The reference JSON as decoded, and the comparison currency for `JSONValue`.
private enum RefJSON: Decodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([RefJSON])
    case object([String: RefJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            // Int before Bool: JSONDecoder is strict about the two, and this order keeps a
            // `1` an integer rather than depending on which attempt runs first.
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            // Double after Int: an integral JSON number (`66`) must still decode as
            // `.int` above; this only catches the fractional ones (`66.0`, page geometry).
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RefJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RefJSON].self))
        }
    }

    var object: [String: RefJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

private func normalize(_ value: JSONValue) -> RefJSON {
    switch value {
    case .string(let s): return .string(s)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .bool(let b): return .bool(b)
    case .null: return .null
    case .array(let items): return .array(items.map(normalize))
    case .object(let fields): return .object(fields.mapValues(normalize))
    }
}

private func loadJob014Vectors() throws -> Job014Vectors {
    let url = try #require(
        Bundle.module.url(forResource: "job-014-vectors", withExtension: "json"),
        "job-014-vectors.json missing from the test bundle"
    )
    return try JSONDecoder().decode(Job014Vectors.self, from: Data(contentsOf: url))
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
        out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return out
}
