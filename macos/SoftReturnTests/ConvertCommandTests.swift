import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `ConvertCommand` — the CLI's `-d` batch mode as `convert {...} to folder ... as
/// {...}`. `decode`/`expand`/`convert` are all pure/file-system-only static functions
/// (no Apple Event dispatch), so these tests drive them directly with fakes and temp
/// directories, mirroring `DocumentOperationsTests`' own fixture-driven style.
@Suite struct ConvertCommandTests {

    // MARK: - decode

    @Test func decodeThrowsWhenThereAreNoInputs() {
        #expect(throws: ConvertCommand.DecodeError.missingInputs) {
            _ = try ConvertCommand.decode(direct: nil, arguments: [:])
        }
    }

    @Test func decodeThrowsWhenThereAreNoFormats() {
        #expect(throws: ConvertCommand.DecodeError.missingFormats) {
            _ = try ConvertCommand.decode(
                direct: [URL(fileURLWithPath: "/tmp/x")], arguments: [:])
        }
    }

    @Test func decodeAcceptsAListOfFormatCodesInOrder() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": [ScriptingCodes.nsNumber("SRfr"), ScriptingCodes.nsNumber("SRfp")]])
        #expect(args.formats == ["rtf", "pdf"])
    }

    @Test func decodeAcceptsASingleFormatCodeNotInAList() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRft")])
        #expect(args.formats == ["text"])
    }

    @Test func decodeDefaultsStyleToModernWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.mode == .modern)
    }

    /// Job 313B: `convert` has no window/print path, so an explicit `using style native`
    /// still collapses to `EmitMode.printed`, same as a plain `using style printed` would —
    /// the ruling's "every other format -> identical to printed" applies here in full,
    /// since `convert` never routes PDF through `ExportEngine` either.
    @Test func decodeCollapsesAnExplicitUsingStyleNativeToPrintedMode() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingStyle": ScriptingCodes.nsNumber("SRsn"),
            ])
        #expect(args.mode == .printed)
    }

    @Test func decodeDefaultsSearchingSubfoldersToFalse() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.searchingSubfolders == false)
    }

    @Test func decodeReadsForcingVariantWhenGiven() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingForcingVariant": ScriptingCodes.nsNumber("SRv4"),
            ])
        #expect(args.forcingVariant == .ws4)
    }

    @Test func decodeReadsADestinationFolder() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingDestinationFolder": URL(fileURLWithPath: "/tmp/out"),
            ])
        #expect(args.destinationFolder == URL(fileURLWithPath: "/tmp/out"))
    }

    @Test func decodeLeavesDestinationFolderNilWhenToFolderIsOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.destinationFolder == nil)
    }

    // MARK: - notes switches (job 504: convert gains export's own footnotes/endnotes/annotations/comments)

    @Test func decodeDefaultsToTheAppsOwnNoteSelectionWhenNoSwitchIsGiven() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.notes == EmitOptions.defaultNotes)
        #expect(!args.notes.contains(.comment))
    }

    @Test func decodeWithCommentsAndWithoutFootnotesFlipsExactlyThoseTwoKinds() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/x")],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingComments": true,
                "scriptingFootnotes": false,
            ])
        #expect(args.notes.contains(.comment))
        #expect(!args.notes.contains(.footnote))
        #expect(args.notes.contains(.endnote))
        #expect(args.notes.contains(.annotation))
    }

    // MARK: - expand (folders and subfolders)

    @Test func expandPassesAFileInputThrough() {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("A.ws")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        let expanded = ConvertCommand.expand([file], searchingSubfolders: false)
        #expect(expanded == [file])
    }

    @Test func expandListsAFoldersTopLevelFilesWithoutRecursing() {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let top = dir.appendingPathComponent("TOP.ws")
        FileManager.default.createFile(atPath: top.path, contents: Data("x".utf8))
        let subdir = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let nested = subdir.appendingPathComponent("NESTED.ws")
        FileManager.default.createFile(atPath: nested.path, contents: Data("x".utf8))

        let expanded = ConvertCommand.expand([dir], searchingSubfolders: false)
        #expect(expanded.map(\.lastPathComponent) == ["TOP.ws"])
    }

    @Test func expandRecursesIntoSubfoldersWhenAsked() {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let top = dir.appendingPathComponent("TOP.ws")
        FileManager.default.createFile(atPath: top.path, contents: Data("x".utf8))
        let subdir = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let nested = subdir.appendingPathComponent("NESTED.ws")
        FileManager.default.createFile(atPath: nested.path, contents: Data("x".utf8))

        let expanded = Set(ConvertCommand.expand([dir], searchingSubfolders: true).map(\.lastPathComponent))
        #expect(expanded == ["TOP.ws", "NESTED.ws"])
    }

    // MARK: - convert: produced / skipped / failed, routed through DocumentOperations

    @Test func convertCountsAnUnreadableFileAsFailed() {
        let missing = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist-\(UUID().uuidString).ws")
        let args = ConvertCommand.Arguments(
            inputs: [missing], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)

        let result = ConvertCommand.convert(files: [missing], args: args)
        #expect(result.produced.isEmpty)
        #expect(result.skipped == 0)
        #expect(result.failed == [missing])
    }

    @Test func convertCountsBinaryBytesAsSkippedNotFailed() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("BINARY")
        let bytes = Data((0..<64).map { _ in UInt8(0) })
        try bytes.write(to: file)

        let args = ConvertCommand.Arguments(
            inputs: [file], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [file], args: args)

        #expect(result.produced.isEmpty)
        #expect(result.skipped == 1)
        #expect(result.failed.isEmpty)
    }

    /// Job 216: `produced` is one entry PER OUTPUT FILE, not per input — this input asks for
    /// two formats, so `produced` must have two URLs, not a `converted == 1` count.
    ///
    /// Job 253 (`convert-destination`): `destinationFolder: nil` means "beside the source"
    /// again — job 218's container-fallback default is gone per Jon's ruling that a silent
    /// divert into the container is "absolutely no good". The write goes through
    /// `BesideSourceWriter`, a plain `Data.write(to:)` beside the source under its own
    /// related-item name.
    @Test func convertWritesEveryFormatBesideTheSourceWhenNoToFolderIsGiven() throws {
        let sourceDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let copy = sourceDir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: nil, formats: ["text", "rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)

        let txt = sourceDir.appendingPathComponent("dropped-chapter.txt")
        let rtf = sourceDir.appendingPathComponent("dropped-chapter.rtf")
        #expect(Set(result.produced) == Set([txt, rtf]))
        #expect(result.skipped == 0)
        #expect(result.failed.isEmpty)
        #expect(result.destinationAccessError == nil)
        #expect(FileManager.default.fileExists(atPath: txt.path))
        #expect(FileManager.default.fileExists(atPath: rtf.path))
    }

    /// Job 504 (Jon's ruling, superseding job 261's hard-fail-on-collision): a pre-existing
    /// same-name sibling never gets clobbered AND never fails the batch — the write lands
    /// at the Finder-style uniqued name instead, exactly like `to folder`'s own
    /// `uniqueFileName` path already behaves.
    @Test func convertWritesTheFinderStyleUniquedNameBesideSourceWhenTheExactOutputNameAlreadyExists() throws {
        let sourceDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let copy = sourceDir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)
        let collidingRTF = sourceDir.appendingPathComponent("dropped-chapter.rtf")
        try Data("pre-existing".utf8).write(to: collidingRTF)

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)

        let uniqued = sourceDir.appendingPathComponent("dropped-chapter 2.rtf")
        #expect(result.produced == [uniqued])
        #expect(result.failed.isEmpty)
        #expect(result.destinationAccessError == nil)
        #expect(FileManager.default.fileExists(atPath: uniqued.path))
        // The pre-existing sibling is untouched — proves this is a uniqued write, not an
        // overwrite.
        #expect(try String(contentsOf: collidingRTF, encoding: .utf8) == "pre-existing")
    }

    /// The counter keeps climbing past 2 on repeated collisions, exactly Finder's own rule.
    @Test func convertCollisionNumberingContinuesToThreeOnASecondCollision() throws {
        let sourceDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let copy = sourceDir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)
        try Data("first".utf8).write(to: sourceDir.appendingPathComponent("dropped-chapter.rtf"))
        try Data("second".utf8).write(to: sourceDir.appendingPathComponent("dropped-chapter 2.rtf"))

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)

        let uniqued = sourceDir.appendingPathComponent("dropped-chapter 3.rtf")
        #expect(result.produced == [uniqued])
        #expect(FileManager.default.fileExists(atPath: uniqued.path))
    }

    /// Job 392: replaces the old chmod-0o000-source-directory denial test (`.enabled(if:
    /// ScriptingFileAccessSandboxTests.canConstructAccessDenial())` — that gate, and the whole
    /// sandboxed-grant framing it existed for, is gone). A directly-driven `BesideSourceWriter
    /// .write` call with a source that sits in a directory that never existed is the honestly
    /// constructible "the sibling write genuinely can't land" case left, with no chmod games:
    /// the disk write itself fails (no such directory), which must classify as `.writeFailed`,
    /// never a crash.
    @Test func besideSourceWriterThrowsWriteFailedRatherThanCrashingWhenTheParentDirectoryIsGone() throws {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertCommandTests-missing-\(UUID().uuidString)")
        let source = missingDir.appendingPathComponent("dropped-chapter.ws4")

        #expect(throws: BesideSourceWriter.WriteError.self) {
            try BesideSourceWriter.write(Data("x".utf8), besideSource: source, extension: "txt")
        }
    }

    @Test func convertWritesToAnExplicitDestinationFolderWhenGiven() throws {
        let sourceDir = Self.makeTempDir()
        let outDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outDir)
        }
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let copy = sourceDir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: outDir, formats: ["text"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        _ = ConvertCommand.convert(files: [copy], args: args)

        #expect(FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("dropped-chapter.txt").path))
        #expect(!FileManager.default.fileExists(
            atPath: sourceDir.appendingPathComponent("dropped-chapter.txt").path))
    }

    // MARK: - performDefaultImplementation's reply-shape logic (job 241, was job 216)

    /// `SoftReturn.sdef`'s `convert` command declares `<result type="text">` (job 241 — was
    /// `<result type="file" list="yes">`/a plain `[NSURL]`; job 241's A/B matrix proved Cocoa's
    /// reply-packaging trampoline cannot coerce ANY list-shaped return value, so the reply is a
    /// newline-joined path list instead — see `ConvertCommand`'s own doc comment).
    /// `performDefaultImplementation()` itself isn't independently driven here (same reason
    /// `DiagnoseAndImportPageSettingsCommandTests` gives — no live Apple Event needed to
    /// exercise this logic, and constructing a bare `NSScriptCommand` outside real dispatch has
    /// no `commandDescription` to hand it); this replicates its body exactly: decode → expand →
    /// convert → guard/join, the same steps
    /// `ConvertCommandReceiverDispatchTests.replyResultDescriptorForTheNativeFileListReturnValueAlsoRemainsAbsent`
    /// drives through a real dispatch (and confirms the actual conversion side effect, since
    /// the AE reply channel itself is unreachable in-process either way).
    @Test func performDefaultImplementationBodyReturnsProducedPathsAsJoinedTextForAPartialSuccess() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let copy = dir.appendingPathComponent("dropped-chapter.ws4")
        try FileManager.default.copyItem(at: source, to: copy)
        let missing = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist-\(UUID().uuidString).ws")

        let args = ConvertCommand.Arguments(
            inputs: [copy, missing], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy, missing], args: args)

        // Exactly performDefaultImplementation()'s own guard/return: produced is non-empty
        // (a partial success), so the reply is the produced paths, newline-joined — no
        // script error, even though `missing` genuinely failed.
        #expect(!result.produced.isEmpty)
        let reply = result.produced.map(\.path).joined(separator: "\n") as NSString
        #expect(reply == dir.appendingPathComponent("dropped-chapter.rtf").path as NSString)
        #expect(result.failed == [missing], "the failure is real and counted, just not surfaced in a partial-success reply")
    }

    @Test func performDefaultImplementationBodyThrowsNothingConvertedWhenEveryInputFails() {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingA = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist-a-\(UUID().uuidString).ws")
        let missingB = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist-b-\(UUID().uuidString).ws")
        let args = ConvertCommand.Arguments(
            inputs: [missingA, missingB], destinationFolder: nil, formats: ["rtf"], mode: .modern,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [missingA, missingB], args: args)

        #expect(result.produced.isEmpty, "nothing converted — this is the guard performDefaultImplementation checks")
        let error = ConvertCommand.DecodeError.nothingConverted(skipped: result.skipped, failed: result.failed.count)
        #expect(error.errorDescription == "convert produced no output (skipped: 0, failed: 2).")
    }

    // MARK: - helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertCommandTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
