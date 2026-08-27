import Foundation
import Testing

@testable import CtrlKD
@testable import SoftReturnCLI

/// S1: the four public-domain WordStar sample documents bundled into `sr`
/// (`--samples DIR`), mirroring the flag of the same name added to ctrl-kd.
///
/// Three things this file proves, matching the job brief exactly:
/// 1. the bundled SPM resources are present and byte-identical to the repo copies they
///    were copied from (`bundledSampleResourcesAreByteIdenticalToRepoCopies`);
/// 2. `--samples DIR` writes all four, byte-identical, and errors plainly when `DIR` is
///    missing or unwritable (`samplesFlag...` below);
/// 3. every bundled document is a real, convertible WordStar file — parse + text emit
///    both succeed (`bundledSamplesParseAndEmitTextSuccessfully`).

private let sampleBaseNames = ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"]

/// `Tests/CtrlKDTests/SampleDocumentsTests.swift` -> repo root is three levels up, same
/// arithmetic `SRBinaryTests.swift`'s own `runSR` uses for the same reason: the checked-in
/// repo copy at `Sources/SoftReturnCLI/Resources/SampleDocuments/` is the independent
/// answer to "did packaging preserve these bytes exactly", so it has to be read via a real
/// path, not via `Bundle.module` (which is the thing being checked).
private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func repoSampleBytes(_ baseName: String) throws -> [UInt8] {
    let url = repoRoot.appendingPathComponent(
        "Sources/SoftReturnCLI/Resources/SampleDocuments/\(baseName).WS")
    return [UInt8](try Data(contentsOf: url))
}

// MARK: - Resources present, byte-identical to the repo copies

@Test func bundledSampleResourcesAreByteIdenticalToRepoCopies() throws {
    for base in sampleBaseNames {
        let bundled = try BundledSamples.bytes(for: base)
        let repoCopy = try repoSampleBytes(base)
        #expect(!bundled.isEmpty, "\(base).WS: bundled resource is empty")
        #expect(bundled == repoCopy, "\(base).WS: bundled resource diverges from the repo copy")
    }
}

@Test func bundledSamplesAreExactlyTheFourExpectedFiles() {
    #expect(BundledSamples.filenames == ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"])
}

// MARK: - --samples DIR

/// An in-memory `CLIEnvironment` — same preference as `SRCLITests.swift`'s own
/// `noFSEnvironment()`: what's under test is which paths get written and what the CLI says,
/// not real disk I/O (that gets its own real-filesystem test below).
private final class Recorder {
    var written: [String: [UInt8]] = [:]
    var err: [String] = []

    func environment(existingDirectories: Set<String>) -> CLIEnvironment {
        CLIEnvironment(
            readFile: { _ in [] },
            writeFile: { [self] path, bytes in written[path] = bytes },
            createDirectory: { _ in },
            writeOut: { _ in },
            writeErr: { [self] line in err.append(line) },
            listDirectory: { path in existingDirectories.contains(path) ? [] : nil }
        )
    }
}

@Test func samplesFlagWritesFourByteIdenticalFiles() throws {
    let recorder = Recorder()
    let status = run(["--samples", "/out"],
                      environment: recorder.environment(existingDirectories: ["/out"]))
    #expect(status == ExitStatus.ok)
    #expect(Set(recorder.written.keys) == Set(BundledSamples.filenames.map { "/out/\($0)" }))
    for base in sampleBaseNames {
        let expected = try repoSampleBytes(base)
        #expect(recorder.written["/out/\(base).WS"] == expected, "\(base).WS not byte-identical")
    }
}

@Test func samplesFlagRequiresAValue() {
    guard case .usageError(let message) = parseArguments(["--samples"]) else {
        Issue.record("expected a usage error for --samples with no value")
        return
    }
    #expect(message.contains("--samples"))
}

@Test func samplesFlagErrorsPlainlyWhenDirIsMissing() {
    let recorder = Recorder()
    let status = run(["--samples", "/nope"],
                      environment: recorder.environment(existingDirectories: []))
    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.written.isEmpty, "no partial write when the directory itself is missing")
    #expect(recorder.err.contains { $0.contains("no such directory") },
            "expected a plain 'no such directory' message, got: \(recorder.err)")
}

@Test func samplesFlagErrorsPlainlyWhenDirIsUnwritable() {
    let recorder = Recorder()
    var environment = recorder.environment(existingDirectories: ["/out"])
    environment.writeFile = { _, _ in
        // The real shape Foundation's `Data.write(to:)` throws for EACCES (verified by
        // hand against `sr --samples` on a chmod 555 directory) -- `plainWriteFailure`
        // reduces exactly this to "permission denied".
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        throw NSError(domain: NSCocoaErrorDomain, code: 513,
                      userInfo: [NSUnderlyingErrorKey: underlying])
    }
    let status = run(["--samples", "/out"], environment: environment)
    #expect(status == ExitStatus.fileFailure)
    #expect(recorder.err.contains { $0.contains("permission denied") },
            "expected a plain 'permission denied' message, got: \(recorder.err)")
    #expect(!recorder.err.contains { $0.contains("NSCocoaErrorDomain") },
            "raw Foundation error dump leaked through instead of a plain sentence")
}

/// A genuine filesystem round trip (real temp directory, real `chmod`), not the in-memory
/// recorder above -- proves `--samples` works end to end against real I/O, permission
/// failure included. Same real-environment construction `main.swift` uses.
@Test func samplesFlagRealDiskRoundTripAndRealPermissionFailure() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sr-samples-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let environment = CLIEnvironment(
        readFile: { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) },
        writeFile: { try Data($1).write(to: URL(fileURLWithPath: $0)) },
        createDirectory: { try FileManager.default.createDirectory(
            atPath: $0, withIntermediateDirectories: true) },
        writeOut: { _ in }, writeErr: { _ in },
        listDirectory: { try? FileManager.default.contentsOfDirectory(atPath: $0) }
    )

    #expect(run(["--samples", dir.path], environment: environment) == ExitStatus.ok)
    for base in sampleBaseNames {
        let written = try Data(contentsOf: dir.appendingPathComponent("\(base).WS"))
        let expected = try repoSampleBytes(base)
        #expect([UInt8](written) == expected, "\(base).WS not byte-identical on real disk")
    }

    // Linux checks the OWNER's own permission bits regardless of who is running the
    // process (no root here), so chmod 555 on our own tempdir really does deny our own
    // writes into it.
    let locked = dir.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    #expect(run(["--samples", locked.path], environment: environment) == ExitStatus.fileFailure)
}

// MARK: - Conversion smoke test

/// Every bundled document is a real, convertible WordStar file, not just bytes that happen
/// to sit in the resource bundle: `parse` (variant auto-detected, the real CLI path) then
/// a text emit, for each of the four.
@Test func bundledSamplesParseAndEmitTextSuccessfully() throws {
    guard let emitter = EmitterRegistry.standard.getEmitter("text") else {
        Issue.record("no 'text' emitter registered")
        return
    }
    for base in sampleBaseNames {
        let bytes = try BundledSamples.bytes(for: base)
        let doc = try parse(bytes, variant: nil)
        let output = emitter.emit(doc, .modern, EmitOptions(title: base))
        switch output {
        case .text(let string):
            #expect(!string.isEmpty, "\(base).WS: text emit produced no output")
        case .data:
            Issue.record("\(base).WS: 'text' emitter unexpectedly returned binary data")
        }
    }
}
