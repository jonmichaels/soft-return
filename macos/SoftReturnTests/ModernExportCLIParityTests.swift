import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (H): the app's Modern RTF and HTML exports carry the engine's new Modern output unchanged — the document's own
/// landscape sheet and columns (engine d63da8c, dcef60f), its declared sheet height (8d792ee), the automatic page number
/// (8dd37f9), right-aligned running heads (f78d04b) and the def-row rule (c7bd094, 591068d). For each document the Modern
/// export (`ExportEngine.render`, style Modern) is byte-identical to the app's own bundled
/// `sr -t rtf|html --mode modern --fonts mac` on the same file, and to `DocumentOperations.convert` in Modern mode with Mac
/// fonts — the shared layer the iPhone exports through. Every option at the CLI's default, the title the file's stem, as
/// `NativeExportCLIParityTests` does for Native.
///
/// The documents: REF/BOOKLET.WS (landscape, two columns, a right-aligned head — its RTF must say `\landscape`, `\cols2`,
/// `\paperw15840`, `\paperh12240`, `\qr`) and MAILLIST/ENVELOPE.LST (a 4.17 in sheet — `\paperh6005`).
@Suite(.tags(.corpus), .serialized)
struct ModernExportCLIParityTests {
    static let formats: [ExportFormat] = [.rtf, .html]

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: ["REF/BOOKLET.WS", "MAILLIST/ENVELOPE.LST"])
    @MainActor func modernExportIsTheCLIsModernWithMacFonts(document: String) throws {
        let source = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModernExportCLIParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let stem = copy.deletingPathExtension().lastPathComponent
        let bytes = [UInt8](try Data(contentsOf: copy))

        let defaults = try #require(UserDefaults(suiteName: "ModernExportCLIParity.\(UUID().uuidString)"))
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: copy.path)
        for format in Self.formats {
            let modern = try #require(try ExportEngine.render(
                document: state.document, state: state, formats: [format], notes: NoteSelection(),
                style: .modern, viewStyle: .modern, title: stem, docPath: copy.path,
                headers: true, toc: false, inlineStyling: true, pictures: .embed, pageNumbers: .auto,
                sentenceSpacing: .auto).first).bytes
            let cli = try Self.cliBytes(copy, format: format, into: scratch)
            let library = try #require(try DocumentOperations.convert(data: bytes, options: .init(
                formats: [format.libraryFormatName], mode: .modern, title: stem, fontsTarget: .mac,
                docPath: copy.path)).first).bytes
            print("MODERN-EXPORT \(document) \(format.rawValue): app \(modern.count) bytes, sr \(cli.count), DocumentOperations \(library.count)")
            #expect(modern == cli, """
                \(document) \(format.rawValue): the app's Modern export (\(modern.count) bytes) is not \
                `sr -t \(format.libraryFormatName) --mode modern --fonts mac` (\(cli.count) bytes)
                """)
            #expect(cli == library, """
                \(document) \(format.rawValue): sr (\(cli.count) bytes) and DocumentOperations modern/.mac \
                (\(library.count) bytes) disagree
                """)
            if format == .rtf {
                let rtf = String(decoding: modern, as: UTF8.self)
                let wanted: [String] = document == "REF/BOOKLET.WS"
                    ? ["\\landscape", "\\cols2", "\\paperw15840", "\\paperh12240", "\\qr"]
                    : ["\\paperw12240", "\\paperh6005"]
                let absent = wanted.filter { !rtf.contains($0) }
                print("MODERN-EXPORT \(document) rtf controls \(wanted), absent \(absent)")
                #expect(absent.isEmpty, "\(document): the Modern RTF lacks \(absent)")
            }
        }
    }

    /// `sr -t <format> --mode modern --fonts mac -o <scratch>/<stem>-sr.<format> --force <copy>`, the app's own bundled `sr`.
    static func cliBytes(_ copy: URL, format: ExportFormat, into scratch: URL) throws -> [UInt8] {
        let sr = try #require(Bundle.main.url(forAuxiliaryExecutable: "sr")
                              ?? Bundle.main.url(forResource: "sr", withExtension: nil), "the app bundles no sr")
        let output = scratch.appendingPathComponent("\(copy.deletingPathExtension().lastPathComponent)-sr.\(format.libraryFormatName)")
        let process = Process()
        process.executableURL = sr
        process.arguments = ["-t", format.libraryFormatName, "--mode", "modern", "--fonts", "mac",
                             "-o", output.path, "--force", copy.path]
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
