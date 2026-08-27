import AppIntents
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 373 (b24 FLAG UI) item 4: AppleScript/Shortcuts parity for the four export-sheet
/// flags. `ExportCommand.decode`/`ConvertCommand.decode` are pure argument decoders (see
/// their own headers) — these tests hand them the same `NSNumber`/`Bool` shapes Cocoa
/// Scripting would, exactly `ExportCommandTests`/`ConvertCommandTests`' own established
/// pattern, plus one `AppIntent` end-to-end test for the Shortcuts side.
@Suite struct FlagUIScriptingTests {

    private static let destination = URL(fileURLWithPath: "/tmp/soft-return-export-test/OUT.rtf")

    // MARK: - ExportCommand.decode

    @Test func exportDecodeUsesExplicitArgumentsOverTheCallersDefaults() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingHeaders": false,
                "scriptingTOC": true,
                "scriptingInlineStyling": false,
                "scriptingPictures": ScriptingCodes.nsNumber("SRxo"),
                "scriptingPageNumbers": ScriptingCodes.nsNumber("SRp0"),
            ],
            documentStyle: .modern,
            defaultHeaders: true, defaultTOC: false, defaultInlineStyling: true, defaultPictures: .embed,
            defaultPageNumbers: .auto)
        #expect(args.headers == false)
        #expect(args.toc == true)
        #expect(args.inlineStyling == false)
        #expect(args.pictures == .off)
        #expect(args.pageNumbers == .off)
    }

    @Test func exportDecodeFallsBackToTheCallersDefaultsWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern,
            defaultHeaders: false, defaultTOC: true, defaultInlineStyling: false, defaultPictures: .export,
            defaultPageNumbers: .on)
        #expect(args.headers == false)
        #expect(args.toc == true)
        #expect(args.inlineStyling == false)
        #expect(args.pictures == .export)
        #expect(args.pageNumbers == .on)
    }

    /// Bare `ExportCommand.decode(arguments:documentStyle:)` (no `default*` arguments at
    /// all) must land on the RULED defaults — the same ones `EmitOptions()`/
    /// `ConversionOptions()`/a fresh `SettingsStore` all agree on.
    @Test func exportDecodeBareCallLandsOnTheRuledDefaults() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.headers == true)
        #expect(args.toc == false)
        #expect(args.inlineStyling == true)
        #expect(args.pictures == .embed)
        #expect(args.pageNumbers == .auto)
    }

    // MARK: - line numbers (job 504)

    @Test func exportDecodeDefaultsLineNumbersToTrueWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.lineNumbers == true)
    }

    @Test func exportDecodeReadsAnExplicitLineNumbersFalse() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingLineNumbers": false,
            ],
            documentStyle: .modern)
        #expect(args.lineNumbers == false)
    }

    @Test func convertDecodeDefaultsLineNumbersToTrueWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.lineNumbers == true)
    }

    @Test func convertDecodeReadsAnExplicitLineNumbersFalse() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingLineNumbers": false,
            ])
        #expect(args.lineNumbers == false)
    }

    // MARK: - styles (job 504)

    @Test func exportDecodeDefaultsStylesToTrueWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.styles == true)
    }

    @Test func exportDecodeReadsAnExplicitStylesFalse() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingStyles": false,
            ],
            documentStyle: .modern)
        #expect(args.styles == false)
    }

    @Test func convertDecodeDefaultsStylesToTrueWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.styles == true)
    }

    @Test func convertDecodeReadsAnExplicitStylesFalse() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingStyles": false,
            ])
        #expect(args.styles == false)
    }

    // MARK: - fonts (job 504)

    @Test func exportDecodeDefaultsFontsTargetToMacWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.fontsTarget == .mac)
    }

    @Test func exportDecodeReadsAnExplicitFontsTarget() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingFontsTarget": ScriptingCodes.nsNumber("SRgg"),
            ],
            documentStyle: .modern)
        #expect(args.fontsTarget == .google)
    }

    @Test func convertDecodeDefaultsFontsTargetToMacWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.fontsTarget == .mac)
    }

    @Test func convertDecodeReadsAnExplicitFontsTarget() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingFontsTarget": ScriptingCodes.nsNumber("SRlx"),
            ])
        #expect(args.fontsTarget == .linux)
    }

    // MARK: - page numbers (job 506, b31)

    @Test func exportDecodeDefaultsPageNumbersToAutoWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.pageNumbers == .auto)
    }

    @Test func exportDecodeReadsAnExplicitPageNumbers() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingPageNumbers": ScriptingCodes.nsNumber("SRpo"),
            ],
            documentStyle: .modern)
        #expect(args.pageNumbers == .on)
    }

    @Test func convertDecodeDefaultsPageNumbersToAutoWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.pageNumbers == .auto)
    }

    @Test func convertDecodeReadsAnExplicitPageNumbers() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingPageNumbers": ScriptingCodes.nsNumber("SRp0"),
            ])
        #expect(args.pageNumbers == .off)
    }

    // MARK: - sentence spacing (job 521, b33 N9) — deliberately NO Settings-backed default

    @Test func exportDecodeDefaultsSentenceSpacingToAutoWhenOmitted() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
            ],
            documentStyle: .modern)
        #expect(args.sentenceSpacing == .auto)
    }

    @Test func exportDecodeReadsAnExplicitSentenceSpacing() throws {
        let args = try ExportCommand.decode(
            arguments: [
                "scriptingDestination": Self.destination,
                "scriptingFormat": ScriptingCodes.nsNumber("SRfr"),
                "scriptingSentenceSpacing": ScriptingCodes.nsNumber("SRsk"),
            ],
            documentStyle: .modern)
        #expect(args.sentenceSpacing == .keep)
    }

    @Test func convertDecodeDefaultsSentenceSpacingToAutoWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")])
        #expect(args.sentenceSpacing == .auto)
    }

    @Test func convertDecodeReadsAnExplicitSentenceSpacing() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingSentenceSpacing": ScriptingCodes.nsNumber("SRsl"),
            ])
        #expect(args.sentenceSpacing == .single)
    }

    // MARK: - ConvertCommand.decode

    @Test func convertDecodeUsesExplicitArgumentsOverTheCallersDefaults() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: [
                "scriptingFormats": ScriptingCodes.nsNumber("SRfr"),
                "scriptingHeaders": false,
                "scriptingTOC": true,
                "scriptingInlineStyling": false,
                "scriptingPictures": ScriptingCodes.nsNumber("SRxx"),
                "scriptingPageNumbers": ScriptingCodes.nsNumber("SRp0"),
            ],
            defaultHeaders: true, defaultTOC: false, defaultInlineStyling: true, defaultPictures: .embed,
            defaultPageNumbers: .auto)
        #expect(args.headers == false)
        #expect(args.toc == true)
        #expect(args.inlineStyling == false)
        #expect(args.pictures == .export)
        #expect(args.pageNumbers == .off)
    }

    @Test func convertDecodeFallsBackToTheCallersDefaultsWhenOmitted() throws {
        let args = try ConvertCommand.decode(
            direct: [Self.destination],
            arguments: ["scriptingFormats": ScriptingCodes.nsNumber("SRfr")],
            defaultHeaders: false, defaultTOC: true, defaultInlineStyling: false, defaultPictures: .off,
            defaultPageNumbers: .on)
        #expect(args.headers == false)
        #expect(args.toc == true)
        #expect(args.inlineStyling == false)
        #expect(args.pictures == .off)
        #expect(args.pageNumbers == .on)
    }

    // MARK: - ConvertWordStarDocumentIntent (Shortcuts)

    private static func tocFixtureData() -> Data {
        var data: [UInt8] = [0x1d, 0x04, 0x00, 0x00, 0x04, 0x00, 0x1d]  // ws7Block(0x00)
        data += Array("Prose padding for detection, a perfectly ordinary sentence.".utf8) + [0x0d, 0x0a]
        data += Array(".tc Chapter One".utf8) + [0x0d, 0x0a]
        data += Array("Closing prose line keeps the byte ratio looking like text.".utf8) + [0x0d, 0x0a]
        return Data(data)
    }

    @MainActor
    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "FlagUIScriptingTests.\(UUID().uuidString)")!)
    }

    @Test @MainActor func intentExplicitTOCTrueCompilesTheTableOfContents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlagUIScriptingTests-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var intent = ConvertWordStarDocumentIntent()
        intent.files = [IntentFile(data: Self.tocFixtureData(), filename: "toc.ws7")]
        intent.formats = [.text]
        intent.style = .modern
        intent.destinationFolder = IntentFile(fileURL: tempDir)
        intent.tableOfContents = true

        let result = try await intent.perform()
        let outputs = try #require(result.value)
        let writtenURL = try #require(outputs.first?.fileURL)
        let text = String(decoding: try Data(contentsOf: writtenURL), as: UTF8.self)
        #expect(text.contains("Chapter One"), "tableOfContents: true should compile the .tc entry in")
    }

    @Test @MainActor func intentOmittedTOCFallsBackToSettingsDefault() async throws {
        let settings = SettingsStore.shared
        let saved = settings.defaultTOC
        settings.defaultTOC = true
        defer { settings.defaultTOC = saved }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlagUIScriptingTests-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var intent = ConvertWordStarDocumentIntent()
        intent.files = [IntentFile(data: Self.tocFixtureData(), filename: "toc.ws7")]
        intent.formats = [.text]
        intent.style = .modern
        intent.destinationFolder = IntentFile(fileURL: tempDir)
        // intent.tableOfContents left nil deliberately — must read Settings' own live default.

        let result = try await intent.perform()
        let outputs = try #require(result.value)
        let writtenURL = try #require(outputs.first?.fileURL)
        let text = String(decoding: try Data(contentsOf: writtenURL), as: UTF8.self)
        #expect(text.contains("Chapter One"),
                "an omitted tableOfContents parameter should read Settings.defaultTOC (set true here)")
    }
}
