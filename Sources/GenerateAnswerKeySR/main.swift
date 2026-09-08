import Foundation
import CtrlKD

/// Regenerate `TestDocs/oracle/answer_key_sr.json` — sr's OWN self-recorded oracle, for
/// formats sr registers that ctrl-kd does not (Planning #198/#195, Engine-Test-Finalization-
/// Plan Task 3). Run with `swift run generate-answer-key-sr`.
///
/// WHY THIS EXISTS, AND WHY IT IS CURRENTLY EMPTY. `Tests/CtrlKDTests/AnswerKeyParityTests
/// .swift` already checks every format sr shares with ctrl-kd (`text`, `markdown`, `html`,
/// `rtf`, `pdf`, `layout`) against ctrl-kd's own `tests/answer_key.json` — a real
/// cross-engine truth check, not a self-recording. As of this commit, `EmitterRegistry
/// .standard` (`Sources/CtrlKD/Registry.swift`) registers EXACTLY those six canonical
/// formats and nothing else: there is no DOCX emitter, or any other sr-only format,
/// anywhere in this repo (Sources/CtrlKD or the macOS app). `srOnlyFormats` below is
/// therefore empty, and this file's `docs` grid is `{}` — a true, current fact, not a
/// placeholder waiting to be filled by hand.
///
/// When a real sr-only format ships (DOCX is the named candidate — see docs/TESTING.md),
/// add its canonical name to `srCanonicalFormats` below (it must already be true that
/// `EmitterRegistry.standard` registers it) and rerun this generator: it will render every
/// (doc, mode) cell for every sr-only format over the SAME corpus
/// `AnswerKeyParityTests.swift` uses (the 4 bundled samples, plus every Sawyer-catalog
/// convertible document named in ctrl-kd's own `tests/answer_key.json` — read here purely
/// as a doc/path LIST, never for its cells, so the two files can never disagree about what
/// "the corpus" is) and commit the diff as a reviewed change, same discipline as ctrl-kd's
/// own `tools/answer_key.py`.
///
/// SELF-RECORDED, NOT TRUTH — same honesty class ctrl-kd's own answer key claims for
/// itself (`tools/answer_key.py`'s docstring): this file can only detect DRIFT in sr's own
/// output for a format no other engine here implements, never correctness. Never generate
/// it from a value you don't trust, and never hand-edit a cell to make a test pass — the
/// same rule this repo already applies to every other committed oracle.
///
/// Never run from inside `swift test` — a change to this file is a reviewed diff, exactly
/// like every other regeneration script in this repo.

/// Kept in sync with `EmitterRegistry.standard`'s registration list
/// (`Sources/CtrlKD/Registry.swift`) — canonical names only, no aliases (`txt`/`md`).
/// Update this list whenever a canonical format is added there.
let srCanonicalFormats = ["text", "markdown", "html", "rtf", "pdf", "layout"]

/// ctrl-kd's own `FORMATS` axis (`tools/answer_key.py`) — the six `AnswerKeyParityTests
/// .swift` already checks byte-for-byte against ctrl-kd's real answer key.
let ctrlKDFormats: Set<String> = ["text", "markdown", "html", "rtf", "pdf", "layout"]

let srOnlyFormats = srCanonicalFormats.filter { !ctrlKDFormats.contains($0) }.sorted()
let modes: [EmitMode] = [.printed, .modern]

struct GeneratorError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// This file lives at `Sources/GenerateAnswerKeySR/main.swift`; the repo root is two levels
/// up (matching every other `#filePath`-relative lookup already in this repo, e.g.
/// `CorpusParityManifest.url`, `PCLFidelityTests.swift`'s script path).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func gitInfo() throws -> (sha: String, date: String) {
    func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repoRoot.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return (try run(["rev-parse", "HEAD"]), try run(["log", "-1", "--format=%cI", "HEAD"]))
}

struct CorpusDoc {
    let name: String
    let load: () throws -> [UInt8]
}

/// The 4 bundled samples, read straight from their canonical committed location
/// (`Sources/SoftReturnCLI/Samples.swift`'s own `baseNames`/`filenames`) rather than through
/// `BundledSamples` itself: that type is `internal` to the `SoftReturnCLI` module, and this
/// executable target is a plain (non-`@testable`) importer, same restriction any other
/// consumer of the package would have.
let sampleBaseNames = ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"]

/// Samples always; the Sawyer catalog too, IF `CTRLKD_SAWYER_ARCHIVE`/`CTRLKD_SRC` are both
/// armed — read purely for the doc NAME/PATH list (never cells), from ctrl-kd's own
/// `tests/answer_key.json`, so this generator's corpus can never silently diverge from
/// `AnswerKeyParityTests.swift`'s.
func loadCorpus() throws -> [CorpusDoc] {
    let samplesDir = repoRoot.appendingPathComponent("Sources/SoftReturnCLI/Resources/SampleDocuments")
    var docs = sampleBaseNames.map { base -> CorpusDoc in
        let url = samplesDir.appendingPathComponent("\(base).WS")
        return CorpusDoc(name: "\(base).WS", load: { [UInt8](try Data(contentsOf: url)) })
    }
    let env = ProcessInfo.processInfo.environment
    guard let archive = env["CTRLKD_SAWYER_ARCHIVE"], !archive.isEmpty,
          let src = env["CTRLKD_SRC"], !src.isEmpty else {
        FileHandle.standardError.write(Data(("warning: CTRLKD_SAWYER_ARCHIVE/CTRLKD_SRC unset " +
            "-- sr-only-format cells over the Sawyer catalog are SKIPPED (samples only)\n").utf8))
        return docs
    }
    let archiveRoot = archive.hasSuffix("/") ? String(archive.dropLast()) : archive
    let keyPath = URL(fileURLWithPath: src).deletingLastPathComponent()
        .appendingPathComponent("tests/answer_key.json")
    let data = try Data(contentsOf: keyPath)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let groups = json["groups"] as? [String: Any],
          let sawyer = groups["sawyer"] as? [String: Any],
          let convertible = sawyer["convertible"] as? [String: Any]
    else {
        throw GeneratorError(message: "\(keyPath.path) did not parse in the expected shape")
    }
    for (name, raw) in convertible {
        guard let dict = raw as? [String: Any], let path = dict["path"] as? String else { continue }
        docs.append(CorpusDoc(name: name, load: {
            [UInt8](try Data(contentsOf: URL(fileURLWithPath: archiveRoot).appendingPathComponent(path)))
        }))
    }
    return docs
}

func buildDocsGrid() throws -> [String: [String: [String: Any]]] {
    guard !srOnlyFormats.isEmpty else { return [:] }
    var grid: [String: [String: [String: Any]]] = [:]
    for doc in try loadCorpus() {
        let bytes = try doc.load()
        let parsed = try parse(bytes, variant: nil)
        var cells: [String: [String: Any]] = [:]
        for format in srOnlyFormats {
            guard let emitter = EmitterRegistry.standard.getEmitter(format) else {
                throw GeneratorError(message: "srCanonicalFormats names \(format), which " +
                    "EmitterRegistry.standard does not register -- fix the list above")
            }
            for mode in modes {
                let out = emitter.emit(parsed, mode, EmitOptions()).asBytes
                cells["\(format).\(mode.rawValue)"] = ["sha256": sha256Hex(out), "bytes": out.count]
            }
        }
        grid[doc.name] = cells
    }
    return grid
}

func main() throws {
    let (sha, date) = try gitInfo()
    let docsGrid = try buildDocsGrid()
    let key: [String: Any] = [
        "schema_version": 1,
        "self_recorded": true,
        "note": "SELF-RECORDED (same honesty class as ctrl-kd's tools/answer_key.py, see " +
            "that file's own docstring): drift detection for sr-ONLY formats (ones " +
            "EmitterRegistry.standard registers that ctrl-kd's tests/answer_key.json does " +
            "not cover), never a cross-engine truth check -- that check is " +
            "Tests/CtrlKDTests/AnswerKeyParityTests.swift, over ctrl-kd's real answer key, " +
            "for the six formats both engines share. sr_only_formats is empty as of this " +
            "generation: sr currently registers no format ctrl-kd lacks (no DOCX emitter " +
            "exists in this repo). Regenerate with `swift run generate-answer-key-sr` after " +
            "a sr-only format ships.",
        "generator": ["tool": "swift run generate-answer-key-sr", "git_sha": sha, "date": date],
        "shared_formats_with_ctrl_kd": ctrlKDFormats.sorted(),
        "sr_only_formats": srOnlyFormats,
        "modes": modes.map(\.rawValue),
        "docs": docsGrid,
    ]
    let outPath = repoRoot.appendingPathComponent("TestDocs/oracle/answer_key_sr.json")
    let data = try JSONSerialization.data(withJSONObject: key, options: [.prettyPrinted, .sortedKeys])
    try (String(data: data, encoding: .utf8)! + "\n").write(to: outPath, atomically: true, encoding: .utf8)
    print("wrote \(outPath.path): \(srOnlyFormats.count) sr-only format(s), " +
          "\(docsGrid.count) doc(s) in the grid")
}

try main()
