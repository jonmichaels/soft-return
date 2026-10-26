import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// R-127 (planning #574): AppleScript's `export` and `convert` take `sr`'s quirk choices — `quirks off|auto|all`,
/// `enabling quirks` and `disabling quirks` — and convert to the same bytes `sr` does with the same flags. An open
/// document's `export` with none of them runs the document's own quirks, as its window shows them (R-126).
@Suite struct ScriptedQuirksTests {
    private static let destination = URL(fileURLWithPath: "/tmp/soft-return-quirks-test/OUT.txt")

    private static func exportArguments(_ extra: [String: Any] = [:]) -> [String: Any] {
        var arguments: [String: Any] = [
            "scriptingDestination": destination,
            "scriptingFormat": ScriptingCodes.nsNumber("SRft"),
        ]
        arguments.merge(extra) { $1 }
        return arguments
    }

    @Test func anExportWithNoQuirkParametersRunsTheDocumentsOwn() throws {
        let own = QuirkChoices(enabled: [QuirkName.sawyerStrikeout])
        let args = try ExportCommand.decode(arguments: Self.exportArguments(), documentStyle: .modern, documentQuirks: own)
        #expect(args.quirks == own)
    }

    @Test func anExportsQuirkParametersReplaceAndAdjustTheDocumentsOwn() throws {
        let own = QuirkChoices(enabled: [QuirkName.sawyerStrikeout])
        let off = try ExportCommand.decode(
            arguments: Self.exportArguments(["scriptingQuirksMode": ScriptingCodes.nsNumber("SRq0")]),
            documentStyle: .modern, documentQuirks: own)
        #expect(off.quirks == .off)
        let adjusted = try ExportCommand.decode(
            arguments: Self.exportArguments([
                "scriptingEnablingQuirks": [QuirkName.euroSwap],
                "scriptingDisablingQuirks": [QuirkName.sawyerStrikeout],
            ]),
            documentStyle: .modern, documentQuirks: own)
        #expect(adjusted.quirks == QuirkChoices(enabled: [QuirkName.euroSwap]))
    }

    @Test func anUnknownQuirkNameIsAScriptError() {
        #expect(throws: DocumentOperations.OperationError.self) {
            _ = try ExportCommand.decode(
                arguments: Self.exportArguments(["scriptingEnablingQuirks": ["no-such-quirk"]]), documentStyle: .modern)
        }
    }

    @Test func convertDefaultsToAutoAsSrDoes() throws {
        let args = try ConvertCommand.decode(
            direct: [URL(fileURLWithPath: "/tmp/soft-return-quirks-test/IN.WS")],
            arguments: ["scriptingFormats": [ScriptingCodes.nsNumber("SRft")]])
        #expect(args.quirks == .shipped)
    }

    /// LJ6DTP.WS trips the five auto quirks. Each set of choices converts to exactly what `sr` writes with the same
    /// flags, and the choices change the text (so the test can tell them apart).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func scriptedConvertIsSrWithTheSameQuirkFlags() throws {
        let source = PrivateCorpusSupport.ws7Directory.appendingPathComponent("LJ6DTP.WS")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptedQuirks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let bytes = [UInt8](try Data(contentsOf: copy))

        let cases: [(script: [String: Any], cli: [String])] = [
            ([:], []),
            (["scriptingQuirksMode": ScriptingCodes.nsNumber("SRq0")], ["--quirks", "off"]),
            (["scriptingQuirksMode": ScriptingCodes.nsNumber("SRql")], ["--quirks", "all"]),
            (["scriptingDisablingQuirks": [QuirkName.smartPunctuation]], ["--no-quirk", QuirkName.smartPunctuation]),
        ]
        var outputs: [[UInt8]] = []
        for (index, item) in cases.enumerated() {
            var arguments: [String: Any] = ["scriptingFormats": [ScriptingCodes.nsNumber("SRft")]]
            arguments.merge(item.script) { $1 }
            let args = try ConvertCommand.decode(direct: [copy], arguments: arguments)
            var options = DocumentOperations.ConversionOptions(
                formats: args.formats, mode: args.mode, title: "LJ6DTP", fontsTarget: args.fontsTarget,
                docPath: copy.path, choices: args.choices)
            options.quirks = args.quirks
            let scripted = try #require(try DocumentOperations.convert(data: bytes, options: options).first).bytes
            let cli = try Self.srBytes(copy, flags: item.cli, into: scratch, index: index)
            #expect(scripted == cli, "\(item.cli): scripted \(scripted.count) bytes, sr \(cli.count)")
            outputs.append(scripted)
        }
        #expect(outputs[0] != outputs[1], "quirks off changed nothing in LJ6DTP.WS's text")
    }

    static func srBytes(_ copy: URL, flags: [String], into scratch: URL, index: Int) throws -> [UInt8] {
        let sr = try #require(Bundle.main.url(forAuxiliaryExecutable: "sr")
                              ?? Bundle.main.url(forResource: "sr", withExtension: nil), "the app bundles no sr")
        let output = scratch.appendingPathComponent("sr-\(index).txt")
        let process = Process()
        process.executableURL = sr
        process.arguments = ["-t", "text", "--mode", "modern", "-o", output.path, "--force"] + flags + [copy.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "sr exited \(process.terminationStatus): \(message)")
        return [UInt8](try Data(contentsOf: output))
    }
}
