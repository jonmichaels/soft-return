import Foundation
import Testing
@testable import SoftReturn

/// Job 218 (b12), when this app was still sandboxed: pinned that every write site writes
/// EXACTLY the URL/folder it was handed, never a reconstructed sibling — the property a
/// sandbox grant needs to keep working. Job 392 un-sandboxed the app (that whole grant
/// framing no longer applies), but the underlying "write exactly what you were handed"
/// contract is still worth pinning on its own terms, so these tests stay.
@Suite struct SandboxWriteTests {

    // MARK: - ExportEngine.writeSingle: exactly the granted url, nothing reconstructed

    @Test @MainActor func writeSingleWritesExactlyTheGivenURLNotAReconstructedSibling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The exact "grant" shape a save panel hands back: an arbitrary name, not derived
        // from `basename`/format — proving the write target is the URL itself, not something
        // rebuilt from a directory + a format's own extension.
        let grantedURL = dir.appendingPathComponent("Whatever The User Typed.rtf")
        let product = ExportEngine.Product(format: .rtf, bytes: Array("{\\rtf1 hi}".utf8))

        try ExportEngine.writeSingle(product, to: grantedURL)

        #expect(FileManager.default.fileExists(atPath: grantedURL.path))
        #expect(try Data(contentsOf: grantedURL) == Data("{\\rtf1 hi}".utf8))
        // Nothing else landed in the directory — no second, reconstructed file.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings == ["Whatever The User Typed.rtf"])
    }

    // MARK: - ConvertCommand: `to folder` blessed; omitted falls to a no-grant-required default

    @Test func convertToFolderWritesInsideExactlyTheGrantedFolderRecursively() throws {
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxWriteTests-src-\(UUID().uuidString)")
        let granted = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxWriteTests-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: granted)
        }
        let copy = sourceDir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: granted, formats: ["text"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)

        #expect(result.destinationAccessError == nil)
        #expect(FileManager.default.fileExists(
            atPath: granted.appendingPathComponent("dropped-chapter.txt").path))
        #expect(!FileManager.default.fileExists(
            atPath: sourceDir.appendingPathComponent("dropped-chapter.txt").path))
    }

    // MARK: - CommandLineToolInstaller: no panel, no reconstruction — a pure command string

    @Test func installCommandNeverTouchesUsrLocalBinItself() {
        // The whole point of job 218's fix: this is a STRING for the user's own unsandboxed
        // Terminal to run, never a path this (sandboxed) process writes to.
        let command = CommandLineToolInstaller.installCommand(bundledPath: "/App.app/Contents/MacOS/sr")
        #expect(command.contains("sudo cp"))
        #expect(command.contains("/usr/local/bin/sr"))
    }

    @Test func installCommandSingleQuotesPathsSoSpacesAndSpecialCharactersSurviveTheShell() {
        let command = CommandLineToolInstaller.installCommand(
            bundledPath: "/Applications/Soft Return.app/Contents/MacOS/sr",
            destinationPath: "/usr/local/bin/sr")
        #expect(command.contains("'/Applications/Soft Return.app/Contents/MacOS/sr'"))
    }

    /// Job 248: the test host IS the app bundle, built by the same Tuist script phase
    /// (`Scripts/build-sr-cli.sh`) that now bundles `sr` for every configuration, not only
    /// Release. Job 264 (`cli-marked-method`): this is the same lookup
    /// `CommandLineToolInstaller.bundledExecutableURL()` does — if it resolves,
    /// `CLIHelpWindowController`'s Manual section shows the real reveal/copy command instead of
    /// the "this build doesn't include the bundled sr binary" placeholder.
    @Test func bundledSRToolResolvesSoInstallFlowReachesInstructionsNotTheMissingToolAlert() {
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "sr")
        #expect(bundled != nil)
        if let bundled {
            #expect(FileManager.default.isExecutableFile(atPath: bundled.path))
        }
    }

    // MARK: - Write failure: a genuinely unreachable destination, no chmod games

    /// Job 392: replaces the old chmod-0o000-directory denial test (`.enabled(if:
    /// ScriptingFileAccessSandboxTests.canConstructAccessDenial())` — that gate is gone along
    /// with the sandboxed-grant framing this suite's header comment used to describe). A
    /// destination inside a directory that never existed is the honestly constructible
    /// "genuinely can't write there" case left: the disk write itself fails, which must throw,
    /// never crash or silently succeed.
    @MainActor
    @Test func writeSingleFailsRatherThanCrashingAgainstANonexistentDirectory() throws {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxWriteTests-missing-\(UUID().uuidString)")
        let missingURL = missingDir.appendingPathComponent("OUT.rtf")
        let product = ExportEngine.Product(format: .rtf, bytes: Array("x".utf8))

        #expect(throws: (any Error).self) {
            try ExportEngine.writeSingle(product, to: missingURL)
        }
    }
}
