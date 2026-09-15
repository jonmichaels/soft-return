import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 28 (#271 M10): the Quick Look extensions' faster work draws what the old work drew.
///
/// - Finder's thumbnail is built from page 1 alone (`QuickLookNativeRenderer.thumbnail`: the engine's work made off the
///   main thread, then page 1's text and one page laid out). A one-page render decides its document-wide figures —
///   the flow's top, the leading headroom — from the one page it holds, so every byte of the bitmap is compared with
///   the thumbnail of the whole render's page 1, per document.
/// - The spacebar preview's PDF is written a page at a time into one PDF context instead of joined by PDFKit
///   (`QuickLookNativeRenderer.multiPagePDF`). Every page is rasterized as `QLCLIByteParityTests` rasterizes, and each
///   page's pixels are compared with the same page of the PDFKit join, kept here as it was (`pdfKitJoinedPDF`).
///
/// Walked over the bundled samples, every ws7 fixture and -HOLYMAC.WS; `SR_DOC` narrows the walks.
@Suite(.tags(.corpus), .serialized)
struct QuickLookRequestIdentityTests {
    static let bundledSamples = ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"]
    static let thumbnailSize = CGSize(width: 1024, height: 1024)

    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PrivateCorpusSupport.ws7Directory.path)) ?? []
        return CorpusDocumentFilter.apply(names.filter { $0.uppercased().hasSuffix(".WS") }.sorted())
    }

    @Test(arguments: CorpusDocumentFilter.apply(bundledSamples))
    @MainActor func bundledSample(name: String) throws {
        if CorpusDocumentFilter.recordIfUnmatched(name) { return }
        let url = try #require(HolymacTimingTests.bundledSample(name), "no bundled \(name)")
        try Self.expectThumbnailIdentical(url, name: name)
        try Self.expectPreviewIdentical(url, name: name, scale: 2)
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason), arguments: ws7Fixtures)
    @MainActor func ws7Fixture(name: String) throws {
        if CorpusDocumentFilter.recordIfUnmatched(name) { return }
        let url = PrivateCorpusSupport.ws7Directory.appendingPathComponent(name)
        try Self.expectThumbnailIdentical(url, name: name)
        try Self.expectPreviewIdentical(url, name: name, scale: 2)
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func holymac() throws {
        guard !CorpusDocumentFilter.apply(["-HOLYMAC.WS"], name: { $0 }).isEmpty else { return }
        let url = try #require(PrivateCorpusSupport.sawyerArchiveRoot)
            .appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        try Self.expectThumbnailIdentical(url, name: "-HOLYMAC.WS")
        try Self.expectPreviewIdentical(url, name: "-HOLYMAC.WS", scale: 1)
    }

    // MARK: - Thumbnail

    @MainActor static func expectThumbnailIdentical(_ url: URL, name: String) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let whole = try QuickLookNativeRenderer.thumbnailImage(
            of: try QuickLookNativeRenderer.firstPage(for: try QuickLookNativeRenderer.renderedDocument(
                fromFileBytes: bytes, docPath: url.path, pageSettingsPreset: nil)),
            maximumSize: thumbnailSize)
        let pageOne = try QuickLookNativeRenderer.thumbnail(fromFileBytes: bytes, docPath: url.path,
                                                            maximumSize: thumbnailSize, pageSettingsPreset: nil)
        #expect(pageOne.size == whole.size, "\(name): thumbnail \(pageOne.size) against the whole render's \(whole.size)")
        let wholeBytes = whole.image.dataProvider?.data as Data?
        let pageOneBytes = pageOne.image.dataProvider?.data as Data?
        let differing = zip(wholeBytes ?? Data(), pageOneBytes ?? Data()).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
        #expect(wholeBytes != nil && wholeBytes == pageOneBytes,
                "\(name): \(differing) of \(wholeBytes?.count ?? 0) thumbnail bytes differ from the whole render's page 1")
    }

    // MARK: - Preview

    @MainActor static func expectPreviewIdentical(_ url: URL, name: String, scale: CGFloat) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let rendered = try QuickLookNativeRenderer.renderedDocument(fromFileBytes: bytes, docPath: url.path,
                                                                    pageSettingsPreset: nil)
        let joined = try QLCLIByteParityTests.rasterize(try pdfKitJoinedPDF(for: rendered), scale: scale)
        let preview = try QuickLookNativeRenderer.previewPDF(fromFileBytes: bytes, docPath: url.path,
                                                             pageSettingsPreset: nil)
        let written = try QLCLIByteParityTests.rasterize(preview.pdf, scale: scale)
        #expect(preview.pageSize == rendered.pageSize, "\(name): preview page size \(preview.pageSize)")
        #expect(written.count == joined.count, "\(name): \(written.count) preview pages against \(joined.count)")
        var differentPages: [String] = []
        for (old, new) in zip(joined, written) {
            let oldBitmap = old.bitmap, newBitmap = new.bitmap
            guard oldBitmap.pixelsWide == newBitmap.pixelsWide, oldBitmap.pixelsHigh == newBitmap.pixelsHigh,
                  let oldData = oldBitmap.bitmapData, let newData = newBitmap.bitmapData else {
                differentPages.append("\(old.label) (size)")
                continue
            }
            let count = oldBitmap.bytesPerRow * oldBitmap.pixelsHigh
            guard newBitmap.bytesPerRow * newBitmap.pixelsHigh == count else {
                differentPages.append("\(old.label) (layout)")
                continue
            }
            var differing = 0
            for index in 0..<count where oldData[index] != newData[index] { differing += 1 }
            if differing > 0 { differentPages.append("\(old.label) (\(differing) of \(count) bytes)") }
        }
        #expect(differentPages.isEmpty, "\(name): preview pages differing from the PDFKit join: \(differentPages.prefix(10))")
    }

    /// `multiPagePDF` as it was before batch 28: each page's own PDF opened by PDFKit, its page inserted into one
    /// `PDFDocument`, and that document's `dataRepresentation`.
    @MainActor static func pdfKitJoinedPDF(for rendered: RenderedDocument) throws -> Data {
        let pagedView = PagedDocumentView(frame: .zero)
        pagedView.setContent(rendered, display: .continuousScroll)
        pagedView.setFrameSize(pagedView.intrinsicContentSize)
        pagedView.layoutSubtreeIfNeeded()
        let combined = PDFDocument()
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            autoreleasepool {
                pagedView.capturingPageIndex = index
                let onePageData = pagedView.dataWithPDF(inside: rect)
                pagedView.capturingPageIndex = nil
                if let onePagePDF = PDFDocument(data: onePageData), let page = onePagePDF.page(at: 0) {
                    combined.insert(page, at: combined.pageCount)
                }
            }
        }
        return try #require(combined.dataRepresentation(), "the PDFKit join wrote nothing")
    }
}
