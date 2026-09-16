import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared

/// Batch 40 (M11, Jon: ">5 seconds… blank window… then the first page and all thumbnails appear at once."): the
/// spacebar preview of a WordStar document, page 1 first and the rest as they are made — the app's own progressive
/// open (batches 26 and 27), in the Quick Look extension.
///
/// The data-based preview this replaces had to hand Quick Look one finished PDF: -HOLYMAC.WS's 302 pages were parsed,
/// set, laid out and captured before anything showed (5.3 s, b28-ql-measure). A view-based preview owns its view, so:
/// - the parse and the engine's pagination run off the main thread (`QuickLookEngineWork`);
/// - page 1 is set, laid out and captured alone — the thumbnail's own path (`QuickLookRender.pageOne`) — and shown in a
///   `PDFView`, and Quick Look is told the preview is ready;
/// - the whole document's text is built a turn at a time on the main run loop, then its pages are laid out and
///   captured a turn at a time and appended to the same PDF document, so the view grows while it is read;
/// - the page thumbnails show once every page is in.
///
/// Compiled into the app as well as the extension (as `QuickLookNativeRenderer` is), so the tests can time it.
@MainActor
final class QuickLookProgressivePreview {
    let view = NSView()
    let pdfView = PDFView()
    let thumbnails = PDFThumbnailView()
    let document = PDFDocument()
    /// Page 1's size, once it is made — what Quick Look sizes its window to.
    private(set) var pageSize: CGSize = .zero
    private(set) var isComplete = false
    /// `DispatchTime` uptimes, for the timing tests: when `load` began, page 1 showed, and every page showed.
    private(set) var startedAt: UInt64 = 0
    private(set) var firstPageAt: UInt64?
    private(set) var completedAt: UInt64?
    /// Told once every page is in and the thumbnails show.
    var onComplete: (() -> Void)?

    static let thumbnailWidth: CGFloat = 132
    /// The longest one turn holds the main thread before it yields, and the least time between turns.
    static let turnBudgetNanoseconds: UInt64 = 16_000_000
    static let turnSpacing: TimeInterval = 0.002

    private var thumbnailsWidth: NSLayoutConstraint?
    private var cancelled = false

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
        thumbnails.isHidden = true
        view.addSubview(thumbnails)
        view.addSubview(pdfView)
        let width = thumbnails.widthAnchor.constraint(equalToConstant: 0)
        thumbnailsWidth = width
        NSLayoutConstraint.activate([
            thumbnails.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnails.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Stops whatever is left to make; the preview keeps the pages it has.
    func cancel() {
        cancelled = true
    }

    /// Parses `bytes` off the main thread, shows page 1, then the rest a turn at a time. `firstPage` is told once page 1
    /// is in the view, or with the error that stopped it.
    func load(bytes: [UInt8], docPath: String, pageSettingsPreset: DocumentOperations.PageSettingsPreset?,
              firstPage: @escaping @MainActor @Sendable (Error?) -> Void) {
        startedAt = DispatchTime.now().uptimeNanoseconds
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
                    self?.engineWorkReady(work, firstPage: firstPage)
                }
            }
            CFRunLoopWakeUp(main)
        }
    }

    private func engineWorkReady(_ work: Result<QuickLookEngineWork, Error>, firstPage: @MainActor (Error?) -> Void) {
        guard !cancelled else { return }
        switch work {
        case .failure(let error):
            firstPage(error)
        case .success(let work):
            do {
                let one = try QuickLookNativeRenderer.firstPage(for: QuickLookRender.pageOne(for: work))
                pageSize = one.bounds(for: .mediaBox).size
                document.insert(one, at: 0)
                pdfView.document = document
                firstPageAt = DispatchTime.now().uptimeNanoseconds
                firstPage(nil)
            } catch {
                firstPage(error)
                return
            }
            let session = DocumentRenderer.nativeRenderSession(QuickLookRender.nativeState(for: work), engine: work.engine)
            nextTurn { $0.renderTurn(session) }
        }
    }

    /// The whole document's text, a turn's budget at a time; then its pages.
    private func renderTurn(_ session: DocumentRenderer.NativeRenderSession) {
        session.renderNext(until: Self.deadline())
        guard session.isComplete else {
            nextTurn { $0.renderTurn(session) }
            return
        }
        let rendered = session.snapshot(final: true)
        nextTurn { preview in
            let pages = PagedDocumentView(frame: .zero)
            pages.setContent(rendered, display: .continuousScroll, firstPages: 2)
            pages.setFrameSize(pages.intrinsicContentSize)
            pages.layoutSubtreeIfNeeded()
            preview.nextTurn { $0.captureTurn(pages, next: 1) }
        }
    }

    /// Pages laid out and captured, from `next` on, a turn's budget at a time; page 1 is in already.
    private func captureTurn(_ pages: PagedDocumentView, next: Int) {
        let deadline = Self.deadline()
        var index = next
        repeat {
            if index >= pages.pageCount, !pages.isLaidOut {
                pages.layOutMorePages(until: deadline)
            }
            guard index < pages.pageCount else { break }
            if let page = Self.capture(pages, page: index) {
                document.insert(page, at: document.pageCount)
            }
            index += 1
        } while DispatchTime.now().uptimeNanoseconds < deadline
        pdfView.layoutDocumentView()
        if index >= pages.pageCount, pages.isLaidOut {
            finish()
        } else {
            nextTurn { $0.captureTurn(pages, next: index) }
        }
    }

    private func finish() {
        isComplete = true
        completedAt = DispatchTime.now().uptimeNanoseconds
        thumbnailsWidth?.constant = Self.thumbnailWidth
        thumbnails.isHidden = false
        onComplete?()
    }

    /// One page of `pages` as a PDF page, captured alone — `QuickLookNativeRenderer.multiPagePDF`'s capture.
    private static func capture(_ pages: PagedDocumentView, page index: Int) -> PDFPage? {
        let rect = pages.rect(ofPage: index)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return autoreleasepool {
            pages.capturingPageIndex = index
            let data = pages.dataWithPDF(inside: rect)
            pages.capturingPageIndex = nil
            return PDFDocument(data: data)?.page(at: 0)
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
