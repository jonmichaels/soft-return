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
        #expect(
            mine.keys.sorted().filter { $0 != "file" } == theirs.keys.sorted().filter { $0 != "file" },
            "key set differs for \(vector.name)")
        for (key, expected) in theirs where key != "file" {
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

// MARK: - Argument surface

@Test func defaultFormatIsMarkdown() throws {
    let command = parseArguments(["PAPER.WS"])
    #expect(command == .run({
        var options = Options()
        options.files = ["PAPER.WS"]
        return options
    }()))
    guard case .run(let options) = command else { return }
    #expect(options.formats == ["markdown"])
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
@Test func encodingFlagIsRefusedWithAnExplanation() {
    guard case .usageError(let message) = parseArguments(["--encoding", "latin-1", "A.WS"]) else {
        Issue.record("expected a usage error")
        return
    }
    #expect(message.contains("CP437"))
}

@Test func versionLineNamesBothTheCLIAndTheReference() {
    #expect(versionLine == "sr 1.0.0 (ctrl-kd parity 1.1.6)")

    let recorder = Recorder()
    #expect(run(["--version"], environment: recorder.environment) == ExitStatus.ok)
    #expect(recorder.out == ["sr 1.0.0 (ctrl-kd parity 1.1.6)"])
    #expect(recorder.written.isEmpty)
}

@Test func helpPromisesOnlyWhatExists() {
    let help = helpText()
    #expect(!help.lowercased().contains("plugin"))
    #expect(!help.contains("--encoding"))
    #expect(help.contains("CP437"))
    #expect(help.contains("--diagnose"))
    for format in EmitterRegistry.standard.formats() {
        #expect(help.contains(format))
    }
}

// MARK: - The conversion loop

@Test func conversionWritesBesideTheInputByDefault() {
    let recorder = Recorder(files: ["/archive/PAPER.WS": makeProse()])
    let status = run(["/archive/PAPER.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.ok)
    #expect(Array(recorder.written.keys) == ["/archive/PAPER.md"])
    #expect(recorder.out == ["/archive/PAPER.WS -> /archive/PAPER.md"])
    #expect(recorder.createdDirectories.isEmpty)
}

@Test func bareFilenameWritesToTheCurrentDirectory() {
    // Python's `os.path.dirname(path) or '.'` — a bare name has no directory part.
    let recorder = Recorder(files: ["PAPER.WS": makeProse()])
    #expect(run(["PAPER.WS"], environment: recorder.environment) == ExitStatus.ok)
    #expect(Array(recorder.written.keys) == ["./PAPER.md"])
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
    #expect(Array(recorder.written.keys) == ["/archive/GOOD.md"], "the good file still converts")
    #expect(recorder.err.count == 1)
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
    recorder.refuseWritesTo = "/archive/A.md"
    let status = run(["/archive/A.WS", "/archive/B.WS"], environment: recorder.environment)

    #expect(status == ExitStatus.fileFailure)
    #expect(Array(recorder.written.keys) == ["/archive/B.md"])
    #expect(recorder.err.first?.contains("/archive/A.md") == true)
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
    // a constant zero was invisible.
    #expect(fields["footnotes"] == .int(1))
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
            writeErr: { [self] line in err.append(line) }
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
