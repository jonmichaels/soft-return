import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 31 item 6 (Jon, 2026-09-14): "It's a Mac app. It uses Mac fonts." Every export keeps `fontsTarget: .mac` in
/// every mode, so the Native export mode's RTF and HTML are the Printed ones by design. This holds them to the CLI:
/// for each document, the app's Native RTF and HTML export (`ExportEngine.render`, style and view Native) is
/// byte-identical to the app's own bundled `sr -t rtf|html --mode printed --fonts mac`, run on the same file — and to
/// `DocumentOperations.convert` in printed mode with Mac fonts, the shared layer the iPhone's own twin of this test
/// holds its Native export to (an iPhone cannot run `sr`).
///
/// Every option is passed at the CLI's own default (notes: footnotes, endnotes, annotations; headers on, TOC off,
/// inline styling on, pictures embedded, page numbers and sentence spacing auto) and the title is the file's stem, as
/// `sr` titles it, so what is compared is the output, not the options.
///
/// The curated set: the four bundled samples always, and every ws7 fixture when the private corpus is armed.
@Suite(.tags(.corpus), .serialized)
struct NativeExportCLIParityTests {
    static let bundledSamples = ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"]
    static let formats: [ExportFormat] = [.rtf, .html]

    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateCorpusSupport.ws7Directory.path)) ?? []
        return CorpusDocumentFilter.apply(names.filter { $0.uppercased().hasSuffix(".WS") }.sorted())
    }

    @Test(arguments: CorpusDocumentFilter.apply(bundledSamples))
    @MainActor func bundledSample(name: String) throws {
        if CorpusDocumentFilter.recordIfUnmatched(name) { return }
        try Self.expectNativeIsTheCLIsPrintedWithMacFonts(try #require(HolymacTimingTests.bundledSample(name)), name: name)
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason), arguments: ws7Fixtures)
    @MainActor func ws7Fixture(name: String) throws {
        if CorpusDocumentFilter.recordIfUnmatched(name) { return }
        try Self.expectNativeIsTheCLIsPrintedWithMacFonts(PrivateCorpusSupport.ws7Directory.appendingPathComponent(name),
                                                          name: name)
    }

    @MainActor static func expectNativeIsTheCLIsPrintedWithMacFonts(_ source: URL, name: String) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeExportCLIParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // One copy both sides read, so pictures resolve against the same place.
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let stem = copy.deletingPathExtension().lastPathComponent
        let bytes = [UInt8](try Data(contentsOf: copy))

        let defaults = try #require(UserDefaults(suiteName: "NativeExportCLIParity.\(UUID().uuidString)"))
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: copy.path)
        for format in formats {
            let native = try #require(try ExportEngine.render(
                document: state.document, state: state, formats: [format], notes: NoteSelection(),
                style: .native, viewStyle: .native, title: stem, docPath: copy.path,
                headers: true, toc: false, inlineStyling: true, pictures: .embed, pageNumbers: .auto,
                sentenceSpacing: .auto).first).bytes
            let cli = try cliBytes(copy, format: format, into: scratch)
            let library = try #require(try DocumentOperations.convert(data: bytes, options: .init(
                formats: [format.libraryFormatName], mode: .printed, title: stem, fontsTarget: .mac,
                docPath: copy.path)).first).bytes
            #expect(native == cli, """
                \(name) \(format.rawValue): the app's Native export (\(native.count) bytes) is not \
                `sr -t \(format.libraryFormatName) --mode printed --fonts mac` (\(cli.count) bytes)
                """)
            #expect(cli == library, """
                \(name) \(format.rawValue): sr (\(cli.count) bytes) and DocumentOperations printed/.mac \
                (\(library.count) bytes) disagree — the iPhone's twin of this test leans on them agreeing
                """)
        }
    }

    /// `sr -t <format> --mode printed --fonts mac -o <scratch>/<stem>.<format> --force <copy>`, the app's own bundled
    /// `sr` (the same one `CommandLineToolInstaller` installs).
    static func cliBytes(_ copy: URL, format: ExportFormat, into scratch: URL) throws -> [UInt8] {
        let sr = try #require(Bundle.main.url(forAuxiliaryExecutable: "sr")
                              ?? Bundle.main.url(forResource: "sr", withExtension: nil), "the app bundles no sr")
        let output = scratch.appendingPathComponent("\(copy.deletingPathExtension().lastPathComponent)-sr.\(format.libraryFormatName)")
        let process = Process()
        process.executableURL = sr
        process.arguments = ["-t", format.libraryFormatName, "--mode", "printed", "--fonts", "mac",
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
