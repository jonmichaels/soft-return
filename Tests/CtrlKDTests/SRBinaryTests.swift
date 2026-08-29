import Foundation
import Testing
@testable import CtrlKD

/// Tests that execute the REAL `sr` binary as a subprocess.
///
/// Every other CLI test calls `SoftReturnCLI.run()` in-process, which never exercises
/// `main.swift`, argument delivery, exit codes, or anything the process boundary owns. The
/// sibling Python project shipped a release where 89 library tests passed while the command
/// crashed instantly on an import error, because nothing ran the actual entry point. A
/// seven-line pass-through is still seven lines that can be wrong, and "probably fine" is
/// not a test.
///
/// `swift test` builds executable targets, so the binary is present whenever these run.
private func runSR(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
    // Tests/CtrlKDTests/<this file> -> repo root is three levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = ["debug", "release"].map {
        root.appendingPathComponent(".build/\($0)/sr")
    }
    guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        // Deliberately a failure, not a skip: silently skipping would recreate exactly the
        // blind spot this file exists to remove.
        Issue.record("sr binary not found; looked in \(candidates.map(\.path))")
        throw CocoaError(.fileNoSuchFile)
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self))
}

/// A WS5+ document carrying one of each note kind, written to a temp file.
private func withFourKindFile(_ body: (String) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sr-bin-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("SAMPLE.WS")
    try Data(fourKindData()).write(to: path)
    try body(path.path)
}

@Test func binaryRunsAndReportsItsVersion() throws {
    let r = try runSR(["--version"])
    #expect(r.status == 0, "sr --version exited \(r.status): \(r.err)")
    #expect(r.out.contains("sr "), "no version string in: \(r.out)")
    #expect(r.out.contains("sr v4.0.2"), "banner missing sr v4.0.2 in: \(r.out)")
    #expect(!r.out.contains("parity"), "parity clause must stay gone: \(r.out)")
}

@Test func binaryHelpListsTheNoteFlags() throws {
    let r = try runSR(["--help"])
    #expect(r.status == 0, "sr --help exited \(r.status)")
    #expect(r.out.contains("--no-notes"), "--help omits --no-notes")
    #expect(r.out.contains("--comments"), "--help omits --comments")
}

@Test func binaryDiagnoseEmitsParseableJSONWithTheNewFields() throws {
    try withFourKindFile { path in
        let r = try runSR(["--diagnose", path])
        #expect(r.status == 0, "diagnose exited \(r.status): \(r.err)")
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
            "diagnose did not emit a JSON object: \(r.out)")
        #expect(obj["variant"] as? String == "ws5+")
        let notes = try #require(obj["notes"] as? [String: Any], "no notes object")
        for kind in ["footnote", "endnote", "annotation", "comment"] {
            #expect(notes[kind] as? Int == 1, "notes.\(kind) wrong: \(notes)")
        }
        #expect(obj["page"] != nil, "no page geometry")
        #expect(obj["unknown_blocks"] != nil, "no unknown_blocks")
    }
}

@Test func binaryConvertsAndHonoursTheNoteFlags() throws {
    try withFourKindFile { path in
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-out-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        func convert(_ extra: [String]) throws -> String {
            // --force: this test reuses one output path across three conversions to
            // compare note-flag behavior, which is a legitimate overwrite -- not what
            // the D4 prompt/refusal (ruling 2026-08-05) exists to catch.
            let r = try runSR(["-t", "text", "-o", out.path, "--force"] + extra + [path])
            #expect(r.status == 0, "convert \(extra) exited \(r.status): \(r.err)")
            return try String(contentsOf: out, encoding: .utf8)
        }

        let byDefault = try convert([])
        #expect(byDefault.contains("Footnote text."), "default output lost footnotes")
        #expect(!byDefault.contains("Comment text."),
                "comments must stay hidden unless asked for -- WordStar never printed them")

        let withComments = try convert(["--comments"])
        #expect(withComments.contains("Comment text."), "--comments did not include them")

        let without = try convert(["--no-notes"])
        for gone in ["Footnote text.", "Endnote text.", "Annotation text"] {
            #expect(!without.contains(gone), "--no-notes left \(gone) in the output")
        }
    }
}

@Test func binaryFailsCleanlyOnAMissingFile() throws {
    let r = try runSR(["-t", "text", "/nonexistent/definitely-not-here.ws"])
    #expect(r.status != 0, "a missing input must not exit 0")
    #expect(!r.err.isEmpty, "a failure must say something on stderr")
    #expect(!r.err.contains("Fatal error"), "crashed instead of failing cleanly: \(r.err)")
}

@Test func binaryRejectsAnUnknownFlagWithoutCrashing() throws {
    let r = try runSR(["--definitely-not-a-flag"])
    #expect(r.status != 0, "an unknown flag must not exit 0")
    #expect(!r.err.contains("Fatal error"), "crashed instead of failing cleanly: \(r.err)")
}
