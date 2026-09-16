import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared

/// Batch 40 (M11, Jon: ">5 seconds… blank window… then the first page and all thumbnails appear at once."): the
/// spacebar preview of a WordStar document, shown before every page is made — the app's own progressive open (batches
/// 26 and 27), in the Quick Look extension.
///
/// The data-based preview this replaces had to hand Quick Look one finished PDF: -HOLYMAC.WS's 302 pages were parsed,
/// set, laid out and captured before anything showed (5.3 s, b28-ql-measure). A view-based preview owns its view, so:
/// - the parse and the engine's pagination run off the main thread (`QuickLookEngineWork`);
/// - the first `batchPages` pages' text is built, laid out and captured a turn at a time on the main run loop, then
///   shown at once in a `PDFView` with the page thumbnails beside it, opened on page 1, and Quick Look is told the
///   preview is ready (batch 44, M21, Jon: "calculate 10 pages, then display page 1 including the visible
///   thumbnails"); a document that short is shown whole;
/// - the rest of the text is built, then its pages are laid out and captured and appended `batchPages` at a time to
///   the same PDF document, so the view grows while it is read.
///
/// Batch 44 (M21, Jon on 4.3.0's preview: "Completely unusable"; "The USER gets to choose which page to display. Not
/// us."): nothing here moves the view. An append re-lays out the document view, and PDFKit does not keep the clip
/// view's place across that, so it rode to the newest page; each append now keeps the page being read, and the
/// thumbnail strip's selection with it. The strip sits on the trailing edge, as Apple's PDF preview has it, and shows
/// from the first paint, so the pages never re-fit when it arrives.
///
/// Compiled into the app as well as the extension (as `QuickLookNativeRenderer` is), so the tests can time it.
@MainActor
final class QuickLookProgressivePreview {
    let view = NSView()
    let pdfView = PDFView()
    let thumbnails = PDFThumbnailView()
    let document = PDFDocument()
    /// Page 1's size, once it is made.
    private(set) var pageSize: CGSize = .zero
    /// What Quick Look sizes its window to: page 1 beside the thumbnail strip.
    var preferredContentSize: CGSize {
        pageSize == .zero ? .zero : CGSize(width: pageSize.width + Self.thumbnailWidth, height: pageSize.height)
    }
    private(set) var isComplete = false
    /// `DispatchTime` uptimes, for the timing tests: when `load` began, the first pages showed, and every page showed.
    private(set) var startedAt: UInt64 = 0
    private(set) var firstPaintAt: UInt64?
    private(set) var completedAt: UInt64?
    /// Told after every append — the first paint's included — with the number of pages in; the tests watch the view's
    /// place through it.
    var onAppend: ((Int) -> Void)?
    /// Told once every page is in.
    var onComplete: (() -> Void)?

    /// How many pages are made before anything shows, and how many each later append adds — portrait and landscape
    /// alike (Jon: "Stick with 10 for everything").
    static let batchPages = 10
    static let thumbnailWidth: CGFloat = 132
    /// The longest one turn holds the main thread before it yields, and the least time between turns.
    static let turnBudgetNanoseconds: UInt64 = 16_000_000
    static let turnSpacing: TimeInterval = 0.002

    private var cancelled = false
    /// Pages captured and not yet in the document.
    private var pending: [PDFPage] = []
    /// The index of the next page to capture.
    private var nextPage = 0
    private var firstPaint: (@MainActor (Error?) -> Void)?

    init() {
        view.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .softReturnCanvas
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = CGSize(width: 96, height: 124)
        view.addSubview(pdfView)
        view.addSubview(thumbnails)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnails.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnails.widthAnchor.constraint(equalToConstant: Self.thumbnailWidth),
        ])
    }

    /// Stops whatever is left to make; the preview keeps the pages it has.
    func cancel() {
        cancelled = true
    }

    /// Parses `bytes` off the main thread, shows the first `batchPages` pages, then the rest. `firstPaint` is told once
    /// those pages are in the view, or with the error that stopped them.
    func load(bytes: [UInt8], docPath: String, pageSettingsPreset: DocumentOperations.PageSettingsPreset?,
              firstPaint: @escaping @MainActor @Sendable (Error?) -> Void) {
        startedAt = DispatchTime.now().uptimeNanoseconds
        self.firstPaint = firstPaint
        DispatchQueue.global(qos: .userInitiated).async {
            let work = Result { try QuickLookEngineWork.make(bytes: bytes, docPath: docPath, pageSettingsPreset: pageSettingsPreset) }
            // Back to the main thread as a run-loop perform in the default mode, not `DispatchQueue.main.async` — the
            // app's own `MainRunLoop.perform` (DocumentWindowController.swift, which this extension does not compile),
            // written out here. A main-queue block cannot run while another main-queue block is running, and a caller
            // that waits by spinning the run loop from inside one never sees it: b40-m11's tests waited 60 s for page 1
            // on LYING.WS and -HOLYMAC.WS and it never came.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated { [weak self] in
                    self?.engineWorkReady(work)
                }
            }
            CFRunLoopWakeUp(main)
        }
    }

    private func engineWorkReady(_ work: Result<QuickLookEngineWork, Error>) {
        guard !cancelled else { return }
        switch work {
        case .failure(let error):
            tellFirstPaint(error)
        case .success(let work):
            let session = DocumentRenderer.nativeRenderSession(QuickLookRender.nativeState(for: work), engine: work.engine)
            guard session.pageCount > 0 else {
                tellFirstPaint(QuickLookNativeRenderer.RenderError.emptyDocument)
                return
            }
            nextTurn { $0.renderTurn(session) }
        }
    }

    /// The document's text, a turn's budget at a time. Before the first paint, only as far as its first pages, which
    /// are laid out and shown while the rest is built (the session's pages so far are exactly the first pages of the
    /// whole render); then every page.
    private func renderTurn(_ session: DocumentRenderer.NativeRenderSession) {
        session.renderNext(until: Self.deadline())
        if session.isComplete {
            let rendered = session.snapshot(final: true)
            nextTurn { $0.layOut(rendered, firstPagesOf: nil) }
        } else if firstPaintAt == nil, session.renderedPages >= Self.batchPages {
            let rendered = session.snapshot()
            nextTurn { $0.layOut(rendered, firstPagesOf: session) }
        } else {
            nextTurn { $0.renderTurn(session) }
        }
    }

    /// `rendered`'s pages, set and laid out to be captured. With `session`, `rendered` is its first pages only: they
    /// are captured and shown, and the session's text goes on.
    private func layOut(_ rendered: RenderedDocument, firstPagesOf session: DocumentRenderer.NativeRenderSession?) {
        let pages = PagedDocumentView(frame: .zero)
        pages.setContent(rendered, display: .continuousScroll, firstPages: 2)
        pages.setFrameSize(pages.intrinsicContentSize)
        pages.layoutSubtreeIfNeeded()
        nextTurn { $0.captureTurn(pages, next: $0.nextPage, firstPagesOf: session) }
    }

    /// Pages laid out and captured, from `next` on, a turn's budget at a time, and appended `batchPages` at a time.
    private func captureTurn(_ pages: PagedDocumentView, next: Int,
                             firstPagesOf session: DocumentRenderer.NativeRenderSession?) {
        let deadline = Self.deadline()
        var index = next
        repeat {
            if session != nil, index >= Self.batchPages { break }
            if index >= pages.pageCount, !pages.isLaidOut {
                pages.layOutMorePages(until: deadline)
            }
            guard index < pages.pageCount else { break }
            if let page = Self.capture(pages, page: index) {
                pending.append(page)
            }
            index += 1
        } while pending.count < Self.batchPages && DispatchTime.now().uptimeNanoseconds < deadline
        nextPage = index
        let captured = session != nil ? index >= Self.batchPages : index >= pages.pageCount && pages.isLaidOut
        if pending.count >= Self.batchPages || captured {
            appendPending()
        }
        guard !cancelled else { return }
        if !captured {
            nextTurn { $0.captureTurn(pages, next: index, firstPagesOf: session) }
        } else if let session {
            nextTurn { $0.renderTurn(session) }
        } else {
            finish()
        }
    }

    /// The pages captured so far, into the document. The first time, the document goes into the view, on page 1;
    /// after that, the view is kept on the page being read.
    private func appendPending() {
        guard !pending.isEmpty else { return }
        if firstPaintAt == nil {
            for page in pending {
                document.insert(page, at: document.pageCount)
            }
            pending.removeAll()
            pageSize = document.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
            pdfView.document = document
            // b44-render4: set as the view's document, the pages draw nothing — in the view's own layers, on screen,
            // a second later — until the view is sent to one. Sent to page 1, page 1 draws.
            if let one = document.page(at: 0) {
                pdfView.go(to: one)
            }
            firstPaintAt = DispatchTime.now().uptimeNanoseconds
            tellFirstPaint(nil)
        } else {
            // `layoutDocumentView()` re-frames the taller document without keeping the clip view's place
            // (research 2026-09-16, pdfview-append-without-scroll). Pages only ever go on the end, so the place is
            // the distance from the document's top, kept exactly — b44-r1 measured `currentDestination` put back with
            // `go(to:)` holding page 1 but slipping a view moved to page 15 back onto page 14.
            let place = Self.distanceFromTop(of: pdfView)
            for page in pending {
                document.insert(page, at: document.pageCount)
            }
            pending.removeAll()
            pdfView.layoutDocumentView()
            if let place {
                Self.scroll(pdfView, toDistanceFromTop: place)
            }
            keepThumbnailSelection()
        }
        onAppend?(document.pageCount)
    }

    /// How far below the document's top the visible part of `pdfView` starts, in its document view's points.
    private static func distanceFromTop(of pdfView: PDFView) -> CGFloat? {
        guard let documentView = pdfView.documentView else { return nil }
        let visible = documentView.visibleRect
        return documentView.isFlipped ? visible.minY : documentView.bounds.height - visible.maxY
    }

    private static func scroll(_ pdfView: PDFView, toDistanceFromTop distance: CGFloat) {
        guard let documentView = pdfView.documentView else { return }
        let visible = documentView.visibleRect
        let y = documentView.isFlipped ? distance : documentView.bounds.height - distance - visible.height
        documentView.scroll(NSPoint(x: visible.minX, y: y))
    }

    /// The thumbnail strip selects the page being read again: an append leaves it with nothing selected (b44-r1), and
    /// the view has not changed page, so PDFKit tells it nothing. The strip listens for the view's page change;
    /// failing that, binding it to the view again selects the current page.
    private func keepThumbnailSelection() {
        guard let current = pdfView.currentPage else { return }
        func selected() -> Bool { thumbnails.selectedPages?.count == 1 && thumbnails.selectedPages?.first === current }
        guard !selected() else { return }
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: pdfView)
        guard !selected() else { return }
        thumbnails.pdfView = nil
        thumbnails.pdfView = pdfView
    }

    private func finish() {
        if firstPaintAt == nil {
            tellFirstPaint(QuickLookNativeRenderer.RenderError.emptyDocument)
        }
        isComplete = true
        completedAt = DispatchTime.now().uptimeNanoseconds
        onComplete?()
    }

    private func tellFirstPaint(_ error: Error?) {
        let told = firstPaint
        firstPaint = nil
        told?(error)
    }

    /// One page of `pages` as a PDF page, captured alone — `QuickLookNativeRenderer.multiPagePDF`'s capture. A
    /// `NumberedPage`, so its thumbnail is numbered where it sits in the preview, not "1" as the page of its own
    /// one-page PDF (batch 44: every thumbnail read "1").
    private static func capture(_ pages: PagedDocumentView, page index: Int) -> PDFPage? {
        let rect = pages.rect(ofPage: index)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return autoreleasepool {
            pages.capturingPageIndex = index
            let data = pages.dataWithPDF(inside: rect)
            pages.capturingPageIndex = nil
            guard let captured = PDFDocument(data: data) else { return nil }
            captured.delegate = NumberedPage.maker
            return captured.page(at: 0)
        }
    }

    private static func deadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + turnBudgetNanoseconds
    }

    /// `body` on a later pass of the main run loop, in its default mode — so the work waits while the person scrolls —
    /// unless the preview was cancelled.
    private func nextTurn(_ body: @escaping @MainActor (QuickLookProgressivePreview) -> Void) {
        let timer = Timer(timeInterval: Self.turnSpacing, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                body(self)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }
}

/// A preview page labelled by where it sits in its document: 1, 2, 3… `PDFDocument` makes its pages of this class once
/// `maker` is its delegate.
final class NumberedPage: PDFPage {
    override var label: String? {
        guard let document else { return super.label }
        let index = document.index(for: self)
        return index == NSNotFound ? super.label : String(index + 1)
    }

    @MainActor static let maker = Maker()

    final class Maker: NSObject, PDFDocumentDelegate {
        func classForPage() -> AnyClass {
            NumberedPage.self
        }
    }
}
