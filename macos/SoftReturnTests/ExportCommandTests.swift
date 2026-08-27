import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `ExportCommand.decode(arguments:documentStyle:)` — the pure Apple-Event-argument
/// decoding step `performDefaultImplementation()` is a thin wrapper around. These tests
/// hand it the same shapes Cocoa Scripting would (`NSNumber` for every enumerator,
/// `Bool` for the with/without notes switches, a file URL for the destination) without
/// needing a live Apple Event or an open document — exactly what a fake buys here.
@Suite struct ExportCommandTests {

    private static let destination = URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT.rtf")

    // MARK: - required arguments

    @Test func decodeThrowsWhenDestinationIsMissing() {
        let arguments: [String: Any] = ["scriptingFormat": ScriptingCodes.nsNumber("SRfr")]
        #expect(throws: ExportCommand.DecodeError.missingDestination) {
            _ = try ExportCommand.decode(arguments: arguments, documentStyle: .modern)
        }
    }

    @Test func decodeThrowsWhenFormatIsMissing() {
        let arguments: [String: Any] = ["scriptingDestination": Self.destination]
        #expect(throws: ExportCommand.DecodeError.missingFormat) {
            _ = try ExportCommand.decode(arguments: arguments, documentStyle: .modern)
        }
    }

    @Test func decodeThrowsForAFormatCodeThatIsntInTheDictionary() {
        let arguments: [String: Any] = [
            "scriptingDestination": Self.destination,
            "scriptingFormat": NSNumber(value: 0),
        ]
        #expect(throws: ExportCommand.DecodeError.unknownFormat) {
            _ = try ExportCommand.decode(arguments: arguments, documentStyle: .modern)
        }
    }

    // MARK: - format, including the ruled layout JSON entry

    @Test func decodeAcceptsEveryRuledExportFormatIncludingLayoutJSON() throws {
        let cases: [(String, String)] = [
            ("SRft", "text"), ("SRfk", "markdown"), ("SRfh", "html"),
            ("SRfr", "rtf"), ("SRfp", "pdf"), ("SRfj", "layout"),
        ]
        for (code, expected) in cases {
            let args = try ExportCommand.decode(
                arguments: [
                    "scriptingDestination": Self.destination,
                    "scriptingFormat": ScriptingCodes.nsNumber(code),
                ],
                documentStyle: .modern)
            #expect(args.format == expected)
        }
    }

    // MARK: - style default ("omitted: the document's current style")

    @Test func decodeFallsBackToTheDocumentsCurrentStyleWhenUsingStyleIsOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .printed)
        #expect(args.mode == .printed)
    }

    @Test func decodeUsesAnExplicitUsingStyleOverTheDocumentsCurrentStyle() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingStyle": ScriptingCodes.nsNumber("SRsm"),   // modern
            ],
            documentStyle: .printed)
        #expect(args.mode == .modern)
    }

    // MARK: - native (job 313B): honest viewStyle, mode collapses to printed everywhere but PDF

    @Test func decodeFallsBackToNativeWhenTheDocumentsCurrentStyleIsNativeAndUsingStyleIsOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .native)
        #expect(args.viewStyle == .native)
        #expect(args.mode == .printed,
                "mode (the two-case EmitMode every non-PDF format uses) must still collapse native to printed")
    }

    @Test func decodeAcceptsAnExplicitUsingStyleNative() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfp"),
                "scriptingStyle": ScriptingCodes.nsNumber("SRsn"),   // native
            ],
            documentStyle: .printed)
        #expect(args.viewStyle == .native)
        #expect(args.mode == .printed)
    }

    // MARK: - notes switches — "defaults mirror the app: notes on, comments off"

    @Test func decodeDefaultsToTheAppsOwnNoteSelectionWhenNoSwitchIsGiven() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.notes == EmitOptions.defaultNotes)
        #expect(!args.notes.contains(.comment))
    }

    @Test func decodeWithCommentsAndWithoutFootnotesFlipsExactlyThoseTwoKinds() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingComments": true,
                "scriptingFootnotes": false,
            ],
            documentStyle: .modern)
        #expect(args.notes.contains(.comment))
        #expect(!args.notes.contains(.footnote))
        #expect(args.notes.contains(.endnote))
        #expect(args.notes.contains(.annotation))
    }

    // MARK: - note references

    @Test func decodeDefaultsNoteReferencesToWordStyle() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.noteRefs == .word)
    }

    @Test func decodeReadsAnExplicitPrefixedNoteReferenceStyle() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingNoteReferences": ScriptingCodes.nsNumber("SRnp"),
            ],
            documentStyle: .modern)
        #expect(args.noteRefs == .prefixed)
    }

    // MARK: - page settings — preset or record, per the polymorphic parameter

    @Test func decodeResolvesAPageSettingsPresetArgument() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingPageSettings": ScriptingCodes.nsNumber("SRxs"),   // sawyer
            ],
            documentStyle: .modern)
        #expect(args.pageSettings == DocumentOperations.PageSettingsPreset.sawyer.settings)
    }

    @Test func decodeLeavesPageSettingsNilWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.pageSettings == nil)
    }

    // MARK: - destination decoding accepts what Cocoa Scripting would hand back

    @Test func decodeAcceptsAPlainStringPathForDestination() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": "/tmp/soft-return-export-test/STRING.rtf",
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.destination.path == "/tmp/soft-return-export-test/STRING.rtf")
    }

    // MARK: - uniqueDestination (job 504: Finder-style collision naming, "AppleScript
    // overwrite should handle it like a Mac would")

    @Test func uniqueDestinationReturnsTheRequestedNameWhenNothingExistsThere() {
        let destination = URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT.rtf")
        let result = ExportCommand.uniqueDestination(for: destination) { _ in false }
        #expect(result == destination)
    }

    @Test func uniqueDestinationAddsA2BeforeTheExtensionOnCollision() {
        let destination = URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT.rtf")
        var taken: Set<String> = [destination.path]
        let result = ExportCommand.uniqueDestination(for: destination) { taken.contains($0.path) }
        #expect(result == URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT 2.rtf"))
        taken.insert(result.path)
        let third = ExportCommand.uniqueDestination(for: destination) { taken.contains($0.path) }
        #expect(third == URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT 3.rtf"))
    }

    /// A real filesystem round trip, not just the fake `exists` closure above: the same
    /// write-with-collision-handling sequence `WSDocument.handleExportScriptCommand` runs
    /// (`uniqueDestination` then `Data.write`), on real files in a temp directory — proves
    /// the pre-existing file is never touched and the returned URL is the one actually
    /// written.
    @Test func uniqueDestinationNeverClobbersARealPreExistingFileOnDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportCommandTests-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let requested = tempDir.appendingPathComponent("OUT.rtf")
        try Data("pre-existing".utf8).write(to: requested)

        let written = ExportCommand.uniqueDestination(for: requested) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try Data("new export".utf8).write(to: written)

        #expect(written == tempDir.appendingPathComponent("OUT 2.rtf"))
        #expect(try String(contentsOf: requested, encoding: .utf8) == "pre-existing")
        #expect(try String(contentsOf: written, encoding: .utf8) == "new export")
    }

    // MARK: - routed through DocumentOperations.convert on a real fixture

    /// Not a live Apple Event round trip (see the job report for what that would take) —
    /// this replicates exactly what `performDefaultImplementation()` does after
    /// `decode(...)` succeeds: the same `DocumentOperations.convert` call, on real bytes,
    /// writing a real file. Proves the decode step's output actually routes to a working
    /// conversion, the thing `ExportCommand` exists to do.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func decodedArgumentsRouteThroughDocumentOperationsToARealRTFFile() throws {
        let source = MultipageMargins.testDocsDirectory
            .appendingPathComponent("ws4/INDIAN.ws")
        let data = [UInt8](try Data(contentsOf: source))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent("INDIAN.rtf")

        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingStyle": ScriptingCodes.nsNumber("SRsm"),
            ],
            documentStyle: .printed)

        let options = DocumentOperations.ConversionOptions(
            formats: [args.format], mode: args.mode, notes: args.notes,
            pageSettings: args.pageSettings, noteRefs: args.noteRefs)
        let converted = try DocumentOperations.convert(data: data, options: options)
        let product = try #require(converted.first)
        try Data(product.bytes).write(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let written = try Data(contentsOf: destination)
        #expect(written.prefix(6) == Data(#"{\rtf1"#.utf8))
    }
}
