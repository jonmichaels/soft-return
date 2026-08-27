import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `DocumentOperations` is the shared layer both features (and, later, an AppleScript
/// implementation) sit on — these tests exercise it directly, independent of any Intent or
/// appex, so a regression here is caught at its actual source rather than only downstream.
@Suite struct DocumentOperationsTests {

    // MARK: - Open

    @Test func openAutoDetectsTheSameVariantDetectReports() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let detection = detect(data)
        let opened = try DocumentOperations.open(data: data)

        #expect(opened.variant == detection.variant)
        #expect(opened.detection == detection)
    }

    @Test func openForcesTheRequestedVariantRatherThanAutoDetecting() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        // Forced .text always parses via parsePrintstream, whatever the detector said —
        // proving the force actually took, not merely that opening succeeded.
        let opened = try DocumentOperations.open(data: data, variant: .text)
        #expect(opened.variant == .text)
    }

    @Test func openThrowsNotConvertibleForBinaryBytes() {
        let bytes: [UInt8] = (0..<64).map { _ in 0x00 }
        #expect(throws: DocumentOperations.OperationError.self) {
            _ = try DocumentOperations.open(data: bytes)
        }
    }

    // MARK: - Convert

    @Test func convertProducesEveryRequestedFormat() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))
        let options = DocumentOperations.ConversionOptions(
            formats: ["text", "markdown", "html", "rtf", "pdf"], mode: .modern)

        let results = try DocumentOperations.convert(data: data, options: options)

        #expect(results.count == 5)
        for result in results {
            #expect(!result.bytes.isEmpty, "\(result.format) produced no bytes")
        }
        let pdf = try #require(results.first { $0.format == "pdf" })
        #expect(Data(pdf.bytes).prefix(4) == Data("%PDF".utf8))
    }

    @Test func convertRejectsAnUnknownFormatName() {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8]((try? Data(contentsOf: url)) ?? Data())
        let options = DocumentOperations.ConversionOptions(formats: ["klingon"])

        #expect(throws: DocumentOperations.OperationError.self) {
            _ = try DocumentOperations.convert(data: data, options: options)
        }
    }

    @Test func convertAppliesAPageSettingsPresetToPDFGeometry() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let plain = try DocumentOperations.convert(
            data: data,
            options: DocumentOperations.ConversionOptions(formats: ["pdf"], mode: .printed))
        let widened = try DocumentOperations.convert(
            data: data,
            options: DocumentOperations.ConversionOptions(
                formats: ["pdf"], mode: .printed,
                pageSettings: DocumentOperations.PageSettingsPreset.modern.settings))

        // A materially different top/bottom margin and column count changes the emitted
        // PDF's byte stream — not a geometry assertion (that's `GeometryOracleTests`'
        // job), just proof the option actually reached the emitter.
        #expect(plain[0].bytes != widened[0].bytes)
    }

    // MARK: - Diagnose

    @Test func diagnoseReportsVariantDotCommandsAndUnknownCodeCount() throws {
        // narrow.ws4 sets .cw/.lh/.mb/.mt/.pl/.po — a fixture that actually exercises the
        // dot-commands list, unlike boundary.ws4 (which has none).
        let url = Oracle.fixturesDirectory.appendingPathComponent("narrow.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let diagnosis = DocumentOperations.diagnose(data: data)

        #expect(diagnosis.variant == .ws4)
        #expect(diagnosis.hasDotCommands)
        #expect(diagnosis.dotCommands.contains { $0.hasPrefix(".pl") })
        #expect(diagnosis.unknownCodeCount >= 0)
        guard case .object(let fields) = diagnosis.info else {
            Issue.record("documentInfo did not return an object")
            return
        }
        #expect(fields["variant"] == .string("ws4"))
    }

    @Test func diagnoseNeverThrowsForBinaryBytesAndReportsNilPageCount() {
        let bytes: [UInt8] = (0..<64).map { _ in 0x00 }
        let diagnosis = DocumentOperations.diagnose(data: bytes)

        #expect(diagnosis.variant == .binary)
        #expect(diagnosis.pageCount == nil)
        #expect(diagnosis.dotCommands.isEmpty)
        #expect(diagnosis.unknownCodeCount == 0)
    }

    // MARK: - Page count

    @Test func pageCountMatchesTheLibrarysOwnPrintedPagination() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))
        let opened = try DocumentOperations.open(data: data)

        let expected = max(1, docToPagelines(opened.document, printed: true).count)
        let pages = try DocumentOperations.pageCount(data: data)

        #expect(pages == expected)
    }

    // MARK: - Plain text content

    @Test func plainTextContentStripsControlBytesWordStarUsesForSoftReturns() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let text = try DocumentOperations.plainTextContent(data: data)

        #expect(!text.isEmpty)
        #expect(!text.unicodeScalars.contains { $0.value == 0x8D })
    }

    // MARK: - Page-settings presets

    @Test func pageSettingsPresetsMatchTheCLIsPagePresetsExactly() {
        #expect(DocumentOperations.PageSettingsPreset.default.settings == PageSettings())
        #expect(DocumentOperations.PageSettingsPreset.sawyer.settings
                == PageSettings(mtLines: 1195.0 / 1440.0 * 6.0, mbLines: 6.0, poCols: 7.0))
        #expect(DocumentOperations.PageSettingsPreset.modern.settings
                == PageSettings(mtLines: 6.0, mbLines: 6.0, poCols: 10.0))
    }

    // MARK: - Naming

    @Test func uniqueFileNameFollowsFindersOwnCollisionRule() {
        var taken: Set<String> = ["Paper.md"]
        let first = DocumentOperations.uniqueFileName(basename: "Paper", extension: "md") {
            taken.contains($0)
        }
        #expect(first == "Paper 2.md")
        taken.insert(first)
        let second = DocumentOperations.uniqueFileName(basename: "Paper", extension: "md") {
            taken.contains($0)
        }
        #expect(second == "Paper 3.md")
    }
}
