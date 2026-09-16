import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 40 (M11, Jon: ">5 seconds… blank window… then the first page and all thumbnails appear at once."): the
/// spacebar preview's pages as `PreviewViewController` shows them — `QuickLookProgressivePreview`, run in-process in a
/// window, because a test cannot load the extension (see `QuickLookExtensionTests`). Timed from `load` to page 1 in the
/// view (Athena's target for -HOLYMAC.WS: under 1.5 s) and to every page in; page 1 shows alone first, the
/// thumbnails show only once every page is in, and the pages in the end are the whole preview's, in number and size.
/// Main-thread stretches while the rest loads are measured and printed. LYING.WS always; -HOLYMAC.WS when the private
/// corpus is armed.
@Suite(.serialized)
@MainActor
struct QuickLookProgressivePreviewTests {
    @Test(arguments: ["LYING.WS", "-HOLYMAC.WS"])
    func pageOneFirstThenTheRest(document: String) throws {
        let url: URL
        if document == "LYING.WS" {
            url = try #require(HolymacTimingTests.bundledSample("LYING.WS"))
        } else {
            guard PrivateCorpusSupport.isArmed, let root = PrivateCorpusSupport.sawyerArchiveRoot else {
                print("QL-PROGRESSIVE \(document): skipped, \(PrivateCorpusSupport.skipReason)")
                return
            }
            url = root.appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
            try #require(FileManager.default.fileExists(atPath: url.path), "no -HOLYMAC.WS in the Sawyer archive")
        }
        let bytes = [UInt8](try Data(contentsOf: url))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let preview = QuickLookProgressivePreview()
        window.contentView?.addSubview(preview.view)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                preview.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                preview.view.topAnchor.constraint(equalTo: content.topAnchor),
                preview.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        defer { preview.cancel() }

        let monitor = HolymacTimingTests.BlockMonitor()
        let outcome = FirstPage()
        preview.load(bytes: bytes, docPath: url.path, pageSettingsPreset: nil) { error in
            outcome.done = true
            outcome.error = error
            outcome.pagesAtFirstPage = preview.document.pageCount
            outcome.thumbnailsHiddenAtFirstPage = preview.thumbnails.isHidden
        }
        let shown = monitor.wait("page 1", limit: 60) { outcome.done }
        try #require(shown, "\(document): page 1 never showed")
        #expect(outcome.error == nil, "\(document): \(String(describing: outcome.error))")
        let firstPageMs = Double((preview.firstPageAt ?? 0) - preview.startedAt) / 1_000_000
        let blocksBeforeFirst = monitor.blocks.count

        let finished = monitor.wait("the rest", limit: HolymacTimingTests.waitLimit) { preview.isComplete }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let allPagesMs = Double((preview.completedAt ?? 0) - preview.startedAt) / 1_000_000
        let longestAfter = monitor.blocks.dropFirst(blocksBeforeFirst).max { $0.milliseconds < $1.milliseconds }

        let whole = try QuickLookNativeRenderer.previewPDF(fromFileBytes: bytes, docPath: url.path, pageSettingsPreset: nil)
        let wholePDF = try #require(PDFDocument(data: whole.pdf))
        print("QL-PROGRESSIVE \(document): page 1 shown after \(String(format: "%.1f", firstPageMs)) ms with \(outcome.pagesAtFirstPage) page(s) in, thumbnails hidden \(outcome.thumbnailsHiddenAtFirstPage); every page (\(preview.document.pageCount)) after \(String(format: "%.1f", allPagesMs)) ms; longest main-thread stretch after page 1 \(String(format: "%.1f", longestAfter?.milliseconds ?? 0)) ms (\(longestAfter?.what ?? "none")); the whole preview has \(wholePDF.pageCount) pages")

        #expect(outcome.pagesAtFirstPage == 1, "\(document): \(outcome.pagesAtFirstPage) pages in when page 1 showed")
        #expect(outcome.thumbnailsHiddenAtFirstPage, "\(document): the thumbnails showed with page 1")
        #expect(!preview.thumbnails.isHidden, "\(document): the thumbnails never showed")
        #expect(preview.pdfView.document === preview.document)
        #expect(preview.document.pageCount == wholePDF.pageCount,
                "\(document): \(preview.document.pageCount) pages in, the whole preview has \(wholePDF.pageCount)")
        for index in [0, wholePDF.pageCount / 2, wholePDF.pageCount - 1] where index < preview.document.pageCount {
            #expect(preview.document.page(at: index)?.bounds(for: .mediaBox).size == wholePDF.page(at: index)?.bounds(for: .mediaBox).size,
                    "\(document): page \(index + 1)'s size differs from the whole preview's")
        }
        if document == "-HOLYMAC.WS" {
            #expect(firstPageMs < 1500, "-HOLYMAC.WS: page 1 showed after \(firstPageMs) ms, not under 1.5 s")
        }
    }

    @MainActor
    final class FirstPage {
        var done = false
        var error: Error?
        var pagesAtFirstPage = 0
        var thumbnailsHiddenAtFirstPage = false
    }
}
