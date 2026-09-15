import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// iOS stage 6 (batch 11): the Mac's own exports of LYING.WS in every view and every format —
/// the reference the iOS `ExportParityTests` compare against byte for byte (text, Markdown,
/// HTML, RTF and the Printed PDF) or page for page (the Native and Modern PDFs, which are each
/// platform's own renderer).
///
/// `ExportEngine.render` exactly as the Export As sheet calls it for one document: the sheet's
/// factory options (the Settings defaults — headers on, table of contents off, inline styling
/// on, pictures embedded, page numbering auto, sentence spacing auto — and the library's
/// default notes), the view chosen as both `style` and `viewStyle`, titled with the document's
/// own stem. Settings come from a throwaway defaults suite and the sample is copied into
/// scratch first.
///
/// Written to `ios/ScreenshotProofs/MacExport/` (ignored by git) as `LYING-<view>.<ext>`, with
/// `manifest.json` giving each PDF's page count.
@Suite(.serialized) @MainActor
struct MacExportSamplesTests {
    static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoftReturnTests/
            .deletingLastPathComponent()  // macos/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("ios/ScreenshotProofs/MacExport", isDirectory: true)
    }

    @Test func lyingInEveryViewAndFormat() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExportSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        let copy = try BundledSampleFixture.copy("LYING.WS", into: scratch)
        let suite = "MacExportSamples.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: copy)),
                                      settings: SettingsStore(defaults: defaults), docPath: copy.path)

        var pdfPages: [String: Int] = [:]
        for view in [ViewStyle.printed, .native, .modern] {
            let products = try ExportEngine.render(
                document: state.document, state: state, formats: ExportFormat.allCases,
                notes: NoteSelection(), style: view.renderStyle, viewStyle: view,
                title: "LYING", docPath: copy.path,
                headers: true, toc: false, inlineStyling: true, pictures: .embed,
                pageNumbers: .auto, sentenceSpacing: .auto)
            #expect(products.map(\.format) == ExportFormat.allCases)
            for product in products {
                let file = "LYING-\(view.rawValue).\(product.format.fileExtension)"
                try Data(product.bytes).write(to: Self.outputDirectory.appendingPathComponent(file))
                if product.format == .pdf {
                    let document = try #require(PDFDocument(data: Data(product.bytes)), "\(file) is not a PDF")
                    pdfPages[file] = document.pageCount
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pdfPages).write(to: Self.outputDirectory.appendingPathComponent("manifest.json"))
    }
}
