import AppKit
import PDFKit
import SoftReturnShared

/// What a document window shows its pages in: Native's and Modern's paged view in its scroll view, or Printed's
/// engine PDF in a PDF view (job 265). The window asks the one its style shows (`DocumentWindowController.content`)
/// and never which view it is.
@MainActor
protocol PageContent: AnyObject {
    /// The view in the window.
    var view: NSView { get }
    /// The pages' scale on screen.
    var magnification: CGFloat { get set }
    /// What the pages draw into: a scroll view's clip view FRAME (its bounds are already divided by the
    /// magnification, which would feed the scale back into itself), or the PDF view's own bounds.
    var viewportSize: CGSize { get }
    /// The size of a page, once something is laid out or loaded.
    var pageSize: CGSize? { get }
    /// The page the reader is on.
    var currentPage: Int { get }
    var pageCount: Int { get }
    /// Shows page `index` the way `display` means it: Single Page swaps the page shown, Continuous Scroll scrolls to it.
    func go(toPage index: Int, display: PageDisplay)
    func setDisplay(_ display: PageDisplay)
    /// After a zoom: lets the view settle the scrollers the new scale shows or hides. Fit is worked out again if the
    /// viewport moved (`applyZoom`).
    func settleAfterZoom()
}

/// Native and Modern: `PagedDocumentView` in a magnifying scroll view.
@MainActor
final class PagedContent: PageContent {
    let scrollView: NSScrollView
    let pages: PagedDocumentView

    init(scrollView: NSScrollView, pages: PagedDocumentView) {
        self.scrollView = scrollView
        self.pages = pages
    }

    var view: NSView { scrollView }

    var magnification: CGFloat {
        get { scrollView.magnification }
        set { scrollView.magnification = newValue }
    }

    var viewportSize: CGSize { scrollView.contentView.frame.size }
    var pageSize: CGSize? { pages.renderedPageSize }
    var currentPage: Int { pages.visiblePageIndex }
    var pageCount: Int { pages.pageCount }

    func go(toPage index: Int, display: PageDisplay) {
        switch display {
        case .singlePage:
            pages.showPage(index)
        case .continuousScroll:
            let rect = pages.rect(ofPage: index)
            pages.scrollToVisible(CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width,
                                         height: pages.visibleRect.height))
        }
    }

    func setDisplay(_ display: PageDisplay) {
        pages.setDisplay(display)
    }

    func settleAfterZoom() {
        scrollView.tile()
    }
}

/// Printed: the engine's own PDF, in a PDF view that scrolls and pages itself.
@MainActor
final class PrintedContent: PageContent {
    let pdfView: PDFView

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    var view: NSView { pdfView }

    var magnification: CGFloat {
        get { pdfView.scaleFactor }
        set { pdfView.scaleFactor = newValue }
    }

    var viewportSize: CGSize { pdfView.bounds.size }
    var pageSize: CGSize? { pdfView.document?.page(at: 0)?.bounds(for: .mediaBox).size }

    var currentPage: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    var pageCount: Int { pdfView.document?.pageCount ?? 0 }

    func go(toPage index: Int, display: PageDisplay) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func setDisplay(_ display: PageDisplay) {
        pdfView.displayMode = display == .continuousScroll ? .singlePageContinuous : .singlePage
    }

    func settleAfterZoom() {}
}
