import AppKit
import PDFKit
import SoftReturnRendering

/// A rendered document's pages laid out off screen and captured one page at a time: what an export, Quick Look, the
/// batch preview and printing draw from, so the steps are written once.
extension PagedDocumentView {
    /// `rendered`'s pages, every one laid out, continuously at 100%, never on screen.
    static func laidOut(_ rendered: RenderedDocument) -> PagedDocumentView {
        let pages = PagedDocumentView(frame: .zero)
        pages.setContent(rendered, display: .continuousScroll)
        pages.setFrameSize(pages.intrinsicContentSize)
        pages.layoutSubtreeIfNeeded()
        return pages
    }

    /// Page `index` alone as a one-page PDF and its size, or nil for a page with no area. `capturingPageIndex` names
    /// the page, so nothing of a neighbouring page draws into it; the capture's own memory goes as soon as it is made.
    func pagePDF(at index: Int) -> (data: Data, size: CGSize)? {
        let rect = rect(ofPage: index)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return autoreleasepool {
            capturingPageIndex = index
            defer { capturingPageIndex = nil }
            return (dataWithPDF(inside: rect), rect.size)
        }
    }

    /// Page `index` as a PDFKit page, or nil when it has no area or its PDF will not open.
    func pdfPage(at index: Int) -> PDFPage? {
        guard let capture = pagePDF(at: index) else { return nil }
        return PDFDocument(data: capture.data)?.page(at: 0)
    }

    /// Page `index` drawn as a bitmap at its own size (one point a pixel), or nil for a page with no area.
    func pageImage(at index: Int) -> NSImage? {
        let rect = rect(ofPage: index)
        guard rect.width > 0, rect.height > 0, let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        capturingPageIndex = index
        defer { capturingPageIndex = nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}
