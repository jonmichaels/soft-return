import Foundation
import CtrlKD
import SoftReturnCLI

/// Regenerate `TestDocs/oracle/sawyer_preset_pdf_sr.json` — sr's OWN self-recorded oracle
/// for the ONE geometry `CorpusParityTests` still checks after planning #205 Task 2 retired
/// `TestDocs/oracle/python-printed-manifest.json`: Printed PDF rendered with the
/// `--page-settings sawyer` preset AND real `.PIX` image resolution against the live Sawyer
/// archive tree. Run with `swift run generate-sawyer-preset-drift-sr`.
///
/// WHY THIS EXISTS. ctrl-kd's shared answer key (`tests/answer_key.json`,
/// `AnswerKeyParityTests.swift`) now covers every public document's bare `pdf.printed` cell
/// — `EmitOptions()` defaults, NO page-settings override, NO real pix resolution (empty
/// `pixResults`, so any `.PIX` reference renders as a placeholder on both engines) — which
/// is what made retiring `python-printed-manifest.json`'s OWN `bare` geometry correct: it's
/// now a real subset of the answer key's grid. But that manifest's OTHER geometry,
/// `sawyer` (`pagePresets["sawyer"]` applied, PLUS real `resolveDocumentPictures` against
/// the archive), has no equivalent in the answer key at all — the key's own docs are
/// explicit that it "never applies" a page-settings preset (`docs/TESTING.md`). Retiring
/// the manifest therefore leaves that ONE geometry with no recording anywhere. This
/// generator is the replacement: it renders that exact geometry with THIS engine (sr) and
/// commits the result, so `CorpusParityTests` still has something to check bytes against.
///
/// SELF-RECORDED, NOT TRUTH — same honesty class as ctrl-kd's own answer key
/// (`tools/answer_key.py`'s docstring) and this repo's own `answer_key_sr.json`
/// (`Sources/GenerateAnswerKeySR/main.swift`): there is no independent second engine
/// checked here, only sr's own output at generation time. This file can only detect DRIFT
/// in sr's `sawyer`-preset-plus-pix-resolution rendering path since the last time someone
/// deliberately regenerated it and reviewed the diff — it proves nothing about
/// cross-engine correctness (that's `AnswerKeyParityTests`, over the DIFFERENT bare
/// geometry, above). Never generate it from a value you don't trust, and never hand-edit a
/// cell to make a test pass.
///
/// SCOPE — "re-based on the key's documents" (planning #205 Task 2): rather than walking
/// the archive tree itself (`python-printed-manifest.json`'s old approach, which is how it
/// drifted to 308 entries against a then-396-file live tree), this generator reads its doc
/// list from the SAME place `AnswerKeyParityTests`/`generate-answer-key-sr` do — ctrl-kd's
/// own `tests/answer_key.json`, `groups.sawyer.convertible` — so the corpus these three
/// files agree on can never silently diverge. Samples are excluded (the 4 bundled samples
/// carry no filesystem path to resolve `.PIX` references against, and the retired manifest
/// never covered them either — it walked only the Sawyer archive tree).
///
/// Never run from inside `swift test` — a change to this file's output is a reviewed diff,
/// exactly like every other regeneration script in this repo.

struct GeneratorError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

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

struct SawyerDoc {
    let name: String
    let relativePath: String
}

/// Read ctrl-kd's own answer key purely as a (name, path) LIST — never for its cells — so
/// this generator's corpus can never disagree with `AnswerKeyParityTests.swift`'s about
/// what "the Sawyer convertible set" is.
func loadSawyerConvertibleDocs(ctrlkdSrc: String) throws -> [SawyerDoc] {
    let keyPath = URL(fileURLWithPath: ctrlkdSrc).deletingLastPathComponent()
        .appendingPathComponent("tests/answer_key.json")
    let data = try Data(contentsOf: keyPath)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let groups = json["groups"] as? [String: Any],
          let sawyer = groups["sawyer"] as? [String: Any],
          let convertible = sawyer["convertible"] as? [String: Any]
    else {
        throw GeneratorError(message: "\(keyPath.path) did not parse in the expected shape")
    }
    var docs: [SawyerDoc] = []
    for (name, raw) in convertible {
        guard let dict = raw as? [String: Any], let path = dict["path"] as? String else { continue }
        docs.append(SawyerDoc(name: name, relativePath: path))
    }
    return docs.sorted { $0.name < $1.name }
}

/// Real-filesystem `CLIEnvironment` — same shape `CorpusParityTests
/// .realFilesystemEnvironment()` uses, duplicated (not shared) because that one lives in
/// the `@testable`-only test target.
func realFilesystemEnvironment() -> CLIEnvironment {
    let fm = FileManager.default
    return CLIEnvironment(
        readFile: { path in
            guard let data = fm.contents(atPath: path) else {
                throw GeneratorError(message: "could not read \(path)")
            }
            return [UInt8](data)
        },
        writeFile: { _, _ in },
        createDirectory: { _ in },
        writeOut: { _ in },
        writeErr: { _ in },
        listDirectory: { path in try? fm.contentsOfDirectory(atPath: path) },
        isFile: { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
    )
}

func main() throws {
    let env = ProcessInfo.processInfo.environment
    guard let archive = env["CTRLKD_SAWYER_ARCHIVE"], !archive.isEmpty else {
        throw GeneratorError(message: "CTRLKD_SAWYER_ARCHIVE must be set — this generator " +
            "renders against the real Sawyer archive tree, same requirement every sibling " +
            "generator/oracle in this repo states")
    }
    guard let src = env["CTRLKD_SRC"], !src.isEmpty else {
        throw GeneratorError(message: "CTRLKD_SRC must be set — this generator reads its " +
            "doc list from ctrl-kd's own tests/answer_key.json, a sibling of $CTRLKD_SRC's src/")
    }
    let archiveRoot = archive.hasSuffix("/") ? String(archive.dropLast()) : archive
    let docs = try loadSawyerConvertibleDocs(ctrlkdSrc: src)
    guard let sawyerSettings = pagePresets["sawyer"] else {
        throw GeneratorError(message: "pagePresets[\"sawyer\"] missing — Arguments.swift's " +
            "preset table changed; update this generator to match")
    }

    var docsGrid: [String: [String: Any]] = [:]
    docsGrid.reserveCapacity(docs.count)
    for doc in docs {
        let fileURL = URL(fileURLWithPath: archiveRoot).appendingPathComponent(doc.relativePath)
        let sourceBytes = [UInt8](try Data(contentsOf: fileURL))
        var parsed = try parse(sourceBytes, variant: nil)
        if let page = parsed.page {
            parsed.page = effectivePage(page, settings: sawyerSettings)
        }
        let pixResults = resolveDocumentPictures(parsed, docPath: fileURL.path,
                                                  environment: realFilesystemEnvironment())
        let pdf = emitPDF(parsed, mode: .printed, options: EmitOptions(pixResults: pixResults))
        let pixList: [[String: Any]] = pixResults.map { r in
            ["tag": pixBasename(r.rawPath), "resolved": r.ok]
        }
        docsGrid[doc.name] = [
            "path": doc.relativePath,
            "source_sha256": sha256Hex(sourceBytes),
            "cells": [
                "pdf.sawyer_preset.printed": [
                    "sha256": sha256Hex(pdf),
                    "bytes": pdf.count,
                    "pix": pixList,
                ] as [String: Any]
            ],
        ]
    }

    let (sha, date) = try gitInfo()
    let key: [String: Any] = [
        "schema_version": 1,
        "self_recorded": true,
        "note": "SELF-RECORDED (same honesty class as ctrl-kd's tools/answer_key.py and " +
            "this repo's own answer_key_sr.json, see their docstrings): sr's OWN Printed " +
            "PDF output with the --page-settings sawyer preset applied and real .PIX image " +
            "resolution against the live Sawyer archive -- a geometry the shared answer " +
            "key (tests/answer_key.json) never covers (it applies no page-settings preset " +
            "and resolves no real pictures). Detects drift in sr's OWN rendering of this " +
            "geometry over time; proves nothing about cross-engine correctness -- that is " +
            "AnswerKeyParityTests, over the bare pdf.printed cell. Replaces the retired " +
            "TestDocs/oracle/python-printed-manifest.json's 'sawyer' geometry (planning " +
            "#205 Task 2); that manifest's 'bare' geometry needed no replacement -- it is " +
            "now a real subset of the answer key's own pdf.printed grid. Regenerate with " +
            "`swift run generate-sawyer-preset-drift-sr` (CTRLKD_SAWYER_ARCHIVE and " +
            "CTRLKD_SRC both armed) and commit the diff as a reviewed change; never " +
            "hand-edit a cell to make a test pass.",
        "generator": ["tool": "swift run generate-sawyer-preset-drift-sr", "git_sha": sha, "date": date],
        "doc_count": docs.count,
        "docs": docsGrid,
    ]
    let outPath = repoRoot.appendingPathComponent("TestDocs/oracle/sawyer_preset_pdf_sr.json")
    let data = try JSONSerialization.data(withJSONObject: key, options: [.prettyPrinted, .sortedKeys])
    try (String(data: data, encoding: .utf8)! + "\n").write(to: outPath, atomically: true, encoding: .utf8)
    print("wrote \(outPath.path): \(docs.count) doc(s)")
}

try main()
