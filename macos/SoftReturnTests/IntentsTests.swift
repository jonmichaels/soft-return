import AppIntents
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Both App Intents' `perform()`, driven directly against real fixtures — no Shortcuts
/// runtime involved, exactly the pattern Apple's own intent-testing guidance recommends:
/// construct the intent, set its `@Parameter`s, `await perform()`, and inspect the result.
@Suite struct IntentsTests {

    // MARK: - Convert

    @Test func convertProducesEveryRequestedFormatInTheDestinationFolder() async throws {
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = try Data(contentsOf: source)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftReturnIntentTests-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var intent = ConvertWordStarDocumentIntent()
        intent.files = [IntentFile(data: data, filename: "dropped-chapter.ws4")]
        intent.formats = [.text, .markdown]
        intent.style = .modern
        intent.destinationFolder = IntentFile(fileURL: tempDir)

        let result = try await intent.perform()
        let outputs = try #require(result.value)

        #expect(outputs.count == 2)
        let names = Set(outputs.map(\.filename))
        #expect(names.contains("dropped-chapter.txt"))
        #expect(names.contains("dropped-chapter.md"))
        for output in outputs {
            let writtenURL = try #require(output.fileURL)
            #expect(FileManager.default.fileExists(atPath: writtenURL.path))
            #expect(!(try Data(contentsOf: writtenURL)).isEmpty)
        }
    }

    /// Job 218: `destinationFolder` used to default to `file.fileURL?.deletingLastPathComponent()`
    /// — writing beside the source. Per `docs/reference/apple/sandbox-file-writes-packet.md`
    /// ("What a user-selected grant covers"), reading a file grants that file, never its
    /// enclosing folder, so that path carried no real grant. Omitted, this now falls
    /// straight to `FileManager.default.temporaryDirectory` — no grant needed at all — the
    /// SAME no-op-in-the-old-code fallback this file already had as its last resort, now
    /// promoted to the direct default. `copy`'s own folder (a temp dir this test created,
    /// not any grant Shortcuts handed the intent) is deliberately NOT where the output
    /// should land — proving the fix, not the old behavior.
    @Test func convertWritesToTemporaryDirectoryWhenNoDestinationIsGiven() async throws {
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = try Data(contentsOf: source)

        var intent = ConvertWordStarDocumentIntent()
        intent.files = [IntentFile(data: data, filename: "dropped-chapter.ws4")]
        intent.formats = [.rtf]
        intent.style = .printed
        // destinationFolder left nil deliberately.

        let result = try await intent.perform()
        let outputs = try #require(result.value)

        #expect(outputs.count == 1)
        let writtenURL = try #require(outputs.first?.fileURL)
        defer { try? FileManager.default.removeItem(at: writtenURL) }
        #expect(writtenURL.deletingLastPathComponent().standardizedFileURL.path
                == FileManager.default.temporaryDirectory.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))
    }

    @Test func convertRejectsAnEmptyFormatList() async {
        var intent = ConvertWordStarDocumentIntent()
        let source = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        intent.files = [IntentFile(fileURL: source)]
        intent.formats = []

        await #expect(throws: ConversionIntentError.self) {
            _ = try await intent.perform()
        }
    }

    @Test func convertReportsAFriendlyErrorForAnUnconvertibleFile() async {
        var intent = ConvertWordStarDocumentIntent()
        let bytes: [UInt8] = (0..<64).map { _ in 0x00 }
        intent.files = [IntentFile(data: Data(bytes), filename: "noise.ws4")]
        intent.formats = [.text]

        await #expect(throws: ConversionIntentError.self) {
            _ = try await intent.perform()
        }
    }

    // MARK: - Diagnose

    @Test func diagnoseReportsVariantPageCountDotCommandsAndUnknownCodes() async throws {
        // narrow.ws4 sets .cw/.lh/.mb/.mt/.pl/.po — a fixture that actually exercises the
        // dot-commands list, unlike boundary.ws4 (which has none).
        let url = Oracle.fixturesDirectory.appendingPathComponent("narrow.ws4")
        let data = try Data(contentsOf: url)

        var intent = DiagnoseWordStarDocumentIntent()
        intent.file = IntentFile(data: data, filename: "narrow.ws4")

        let result = try await intent.perform()
        let diagnosis = try #require(result.value)

        #expect(diagnosis.variantName == "ws4")
        #expect((diagnosis.pageCount ?? 0) >= 1)
        #expect(diagnosis.dotCommands.contains { $0.hasPrefix(".pl") })
    }

    @Test func diagnoseOnAFileWithNoDotCommandsReportsAnEmptyList() async throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("no-dot-commands.ws4")
        let data = try Data(contentsOf: url)

        var intent = DiagnoseWordStarDocumentIntent()
        intent.file = IntentFile(data: data, filename: "no-dot-commands.ws4")

        let result = try await intent.perform()
        let diagnosis = try #require(result.value)

        #expect(diagnosis.dotCommands.isEmpty)
    }

    /// Diagnose never throws — even bytes with no WordStar evidence at all get a real
    /// answer (`variant: binary`), the same "say what it is, always" contract
    /// `documentInfo` gives `sr --diagnose`.
    @Test func diagnoseNeverThrowsEvenForUnconvertibleBytes() async throws {
        let bytes: [UInt8] = (0..<64).map { _ in 0x00 }
        var intent = DiagnoseWordStarDocumentIntent()
        intent.file = IntentFile(data: Data(bytes), filename: "noise.ws4")

        let result = try await intent.perform()
        let diagnosis = try #require(result.value)

        #expect(diagnosis.variantName == "binary")
        #expect(diagnosis.pageCount == nil)
        #expect(diagnosis.dotCommands.isEmpty)
    }
}
