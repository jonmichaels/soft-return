import AppKit
import CtrlKD
import Foundation
import SoftReturnShared

/// The spacebar preview of a WordStar document: page images in a column, with their thumbnails beside it.
///
/// Batch 45 (M24, Jon's final ruling, ledger 2026-09-16 "M24 FINAL"): PDFKit leaves the preview.
/// - Page 1 is made, drawn to an image and shown at once, with the thumbnail column already at full width and page 1's
///   thumbnail in it. Quick Look is told the preview is ready then.
/// - Every later page is laid out and captured a turn at a time on the main run loop — the text system is AppKit's and
///   lives there — and drawn to an image OFF the main thread. The moment its image is made it is appended below the
///   last page, and its thumbnail below the last thumbnail. One page at a time: no batches, no spinner.
/// - Nothing that exists is redrawn or moved by an append. The column's document view is flipped, so a taller column
///   keeps the reader's place by construction, and page 1's top is the view's top when it opens (M23: 4.3.1 opened in
///   page 1's lower half, a `go(to:)` point in PDFKit's bottom-left page space).
/// - Scrolling reaches whatever exists; clicking a thumbnail shows that page from its top.
///
/// Memory: -HOLYMAC.WS's 302 pages at Retina scale would be about 2.8 GB of bitmaps, so a page holds its image only
/// while it is within `reachScreens` screens of the view, and is drawn again, off the main thread, when the reader
/// comes back to it. Thumbnails are small; each is drawn once and kept.
///
/// Compiled into the app as well as the extension (as `QuickLookNativeRenderer` is), so the tests can time it.
@MainActor
final class QuickLookProgressivePreview {
    let view = NSView()
    let pageScroll = NSScrollView()
    let pageColumn = FlippedColumnView()
    let thumbnailScroll = NSScrollView()
    let thumbnailColumn = FlippedColumnView()
    /// One per page shown, in order.
    private(set) var pageViews: [PageImageView] = []
    private(set) var thumbnailViews: [ThumbnailItemView] = []
    /// Page 1's size, once it is made.
    private(set) var pageSize: CGSize = .zero
    /// What Quick Look sizes its window to: page 1 beside the thumbnail column.
    var preferredContentSize: CGSize {
        guard pageSize != .zero else { return .zero }
        // The page column's own scroller, where it takes width (legacy scrollers: b47-m29-mac, a 597 pt column in a 744 pt
        // window, page 1 773 pt tall and 11 pt of page 2 in view).
        let scroller = max(0, pageScroll.frame.width - pageScroll.contentView.frame.width)
        let size = Self.contentSize(forPage: pageSize)
        return CGSize(width: size.width + scroller, height: size.height)
    }

    /// Batch 47 (M29): a window showing exactly `page` beside the thumbnail column — and, before page 1 is made, a US
    /// Letter page's (`defaultContentSize`), so the window Quick Look opens from the view's first frame already has the
    /// thumbnail column's room (a bare 612 × 792 view left the page column 480 pt wide, page 1 621 pt tall, and 171 pt of
    /// page 2 in view).
    static func contentSize(forPage page: CGSize) -> CGSize {
        CGSize(width: page.width + thumbnailWidth, height: page.height)
    }
    /// A Letter page's window, with room for a scroller where the system's scrollers take width.
    static var defaultContentSize: CGSize {
        let size = contentSize(forPage: CGSize(width: 612, height: 792))
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return CGSize(width: size.width + scroller, height: size.height)
    }
    private(set) var isComplete = false
    /// `DispatchTime` uptimes, for the timing tests: when `load` began, page 1 showed, and every page showed.
    private(set) var startedAt: UInt64 = 0
    private(set) var firstPaintAt: UInt64?
    private(set) var completedAt: UInt64?
    /// The page the reader is on: the one under the top quarter of the view.
    private(set) var selectedPageIndex: Int?
    /// Told after every page is appended, with the number of pages shown.
    var onAppend: ((Int) -> Void)?
    /// Told once every page is in.
    var onComplete: (() -> Void)?

    static let thumbnailWidth: CGFloat = 132
    static let pageGap: CGFloat = 8
    static let thumbnailItemHeight: CGFloat = 132
    nonisolated static let thumbnailImageBox = CGSize(width: 76, height: 98)
    /// Pages this many screens above or below the view hold their images; beyond twice that they let them go.
    static let reachScreens: CGFloat = 1.5
    /// Pages captured from the text's first pages before the rest of the text is built.
    static let firstPagesAhead = 10
    /// The longest one turn holds the main thread before it yields, and the least time between turns.
    static let turnBudgetNanoseconds: UInt64 = 16_000_000
    static let turnSpacing: TimeInterval = 0.002

    private let rasterQueue = DispatchQueue(label: "QuickLookProgressivePreview.raster", qos: .userInitiated)
    private var cancelled = false
    private var firstPaint: (@MainActor (Error?) -> Void)?
    /// The next page to capture, and how many captured pages are still being drawn.
    private var nextPage = 1
    private var drawing = 0
    private var capturedAll = false
    private var firstPagesCaptured = false
    /// Each page's own one-page PDF, which its image is drawn from — again, if it was let go.
    private var pageData: [Data] = []
    private var pageImageRequested: [Bool] = []
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    private let selection = NSView()

    init() {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        for scroll in [pageScroll, thumbnailScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            // Never autohidden: a legacy scroller appearing as the column outgrows the view would narrow the column and
            // re-fit every page shown (b45-m24-r1: page 1 drawn twice and moved). Overlay scrollers take no width.
            scroll.autohidesScrollers = false
            scroll.drawsBackground = true
            scroll.automaticallyAdjustsContentInsets = false
            view.addSubview(scroll)
        }
        pageScroll.backgroundColor = .softReturnCanvas
        pageScroll.documentView = pageColumn
        thumbnailScroll.backgroundColor = .windowBackgroundColor
        thumbnailScroll.documentView = thumbnailColumn
        selection.wantsLayer = true
        selection.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        selection.layer?.cornerRadius = 4
        selection.isHidden = true
        thumbnailColumn.addSubview(selection)
        NSLayoutConstraint.activate([
            pageScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageScroll.topAnchor.constraint(equalTo: view.topAnchor),
            pageScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnailScroll.leadingAnchor.constraint(equalTo: pageScroll.trailingAnchor),
            thumbnailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailScroll.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnailScroll.widthAnchor.constraint(equalToConstant: Self.thumbnailWidth),
        ])
        pageColumn.onWidthChange = { [weak self] in self?.relayOutPages() }
        pageScroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: pageScroll.contentView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewMoved() }
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Stops whatever is left to make; the preview keeps the pages it has.
    func cancel() {
        cancelled = true
    }

    /// The part of the page column on screen, in the column's (flipped) coordinates.
    var visibleRect: CGRect { pageScroll.contentView.bounds }

    /// Shows page `index` from its top.
    func showPage(_ index: Int) {
        guard pageViews.indices.contains(index) else { return }
        let clip = pageScroll.contentView
        let highest = max(0, pageColumn.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(pageViews[index].frame.minY, highest)))
        pageScroll.reflectScrolledClipView(clip)
    }

    /// What the preview holds, for the tests: the pages' one-page PDFs, and the page and thumbnail images, in bytes.
    var heldBytes: (pageDocuments: Int, pageImages: Int, pagesWithImages: Int, thumbnailImages: Int) {
        let images = pageViews.compactMap(\.image)
        return (pageData.reduce(0) { $0 + $1.count }, images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, images.count,
                thumbnailViews.compactMap(\.imageView.image).reduce(0) { $0 + $1.bytesPerRow * $1.height })
    }

    /// Page `index`'s one-page PDF, for the tests.
    func pageDocumentData(_ index: Int) -> Data? {
        pageData.indices.contains(index) ? pageData[index] : nil
    }

    /// Parses `bytes` off the main thread and shows page 1; the rest follow. `firstPaint` is told once page 1 is on
    /// screen, or with the error that stopped it.
    func load(bytes: [UInt8], docPath: String, pageSettingsPreset: DocumentOperations.PageSettingsPreset?,
              quirks: QuirkChoices = .shipped,
              firstPaint: @escaping @MainActor @Sendable (Error?) -> Void) {
        startedAt = DispatchTime.now().uptimeNanoseconds
        self.firstPaint = firstPaint
        DispatchQueue.global(qos: .userInitiated).async {
            let work = Result {
                try QuickLookEngineWork.make(bytes: bytes, docPath: docPath, pageSettingsPreset: pageSettingsPreset,
                                             quirks: quirks)
            }
            // Back to the main thread as a run-loop perform in the default mode, not `DispatchQueue.main.async`: a
            // main-queue block cannot run while another is running, and a caller that waits by spinning the run loop
            // from inside one never sees it (b40-m11).
            Self.performOnMain { [weak self] in
                self?.engineWorkReady(work)
            }
        }
    }

    private func engineWorkReady(_ work: Result<QuickLookEngineWork, Error>) {
        guard !cancelled else { return }
        switch work {
        case .failure(let error):
            tellFirstPaint(error)
        case .success(let work):
            let session = DocumentRenderer.nativeRenderSession(QuickLookRender.nativeState(for: work), engine: work.engine)
            guard session.pageCount > 0,
                  let one = Self.capture(Self.laidOut(QuickLookRender.pageOne(for: work)), page: 0) else {
                tellFirstPaint(QuickLookNativeRenderer.RenderError.emptyDocument)
                return
            }
            pageSize = one.size
            view.layoutSubtreeIfNeeded()
            // Page 1 is drawn here, on the main thread: it is what the reader waits for, and one page is quick.
            let image = Self.drawPage(one.data, pixelScale: pixelScale(forPageWidth: one.size.width))
            let thumbnail = Self.drawPage(one.data, fitting: Self.thumbnailImageBox, backingScale: backingScale)
            append(data: one.data, size: one.size, image: image, thumbnail: thumbnail, requested: true)
            firstPaintAt = DispatchTime.now().uptimeNanoseconds
            tellFirstPaint(nil)
            if session.pageCount == 1 {
                capturedAll = true
                finishIfDone()
            } else {
                nextTurn { $0.renderTurn(session) }
            }
        }
    }

    /// The document's text, a turn's budget at a time. Once its first pages are built they are laid out and captured
    /// while the rest is built — the session's pages so far are exactly the first pages of the whole render.
    private func renderTurn(_ session: DocumentRenderer.NativeRenderSession) {
        session.renderNext(until: Self.deadline())
        if session.isComplete {
            let rendered = session.snapshot(final: true)
            nextTurn { $0.layOut(rendered, firstPagesOf: nil) }
        } else if !firstPagesCaptured, session.renderedPages >= Self.firstPagesAhead {
            let rendered = session.snapshot()
            nextTurn { $0.layOut(rendered, firstPagesOf: session) }
        } else {
            nextTurn { $0.renderTurn(session) }
        }
    }

    private func layOut(_ rendered: RenderedDocument, firstPagesOf session: DocumentRenderer.NativeRenderSession?) {
        let pages = PagedDocumentView(frame: .zero)
        pages.setContent(rendered, display: .continuousScroll, firstPages: 2)
        pages.setFrameSize(pages.intrinsicContentSize)
        pages.layoutSubtreeIfNeeded()
        nextTurn { $0.captureTurn(pages, firstPagesOf: session) }
    }

    /// Pages laid out and captured a turn's budget at a time; each goes off to be drawn as soon as it is captured.
    private func captureTurn(_ pages: PagedDocumentView, firstPagesOf session: DocumentRenderer.NativeRenderSession?) {
        let deadline = Self.deadline()
        repeat {
            if nextPage >= pages.pageCount, !pages.isLaidOut {
                pages.layOutMorePages(until: deadline)
            }
            guard nextPage < pages.pageCount else { break }
            if let page = Self.capture(pages, page: nextPage) {
                draw(page)
            }
            nextPage += 1
        } while DispatchTime.now().uptimeNanoseconds < deadline
        let done = nextPage >= pages.pageCount && pages.isLaidOut
        if !done {
            nextTurn { $0.captureTurn(pages, firstPagesOf: session) }
        } else if let session {
            firstPagesCaptured = true
            nextTurn { $0.renderTurn(session) }
        } else {
            capturedAll = true
            finishIfDone()
        }
    }

    /// `page` drawn off the main thread — its thumbnail always, its image if it will land within reach — and appended
    /// the moment it is ready. The draws run one at a time, so pages land in order.
    private func draw(_ page: (data: Data, size: CGSize)) {
        drawing += 1
        let top = pageColumn.frame.height + CGFloat(drawing - 1) * (pageColumnWidth * page.size.height / page.size.width)
        let inReach = reach(nearby: true).intersects(CGRect(x: 0, y: top, width: 1, height: pageColumnWidth * page.size.height / page.size.width))
        let pixelScale = inReach ? self.pixelScale(forPageWidth: page.size.width) : 0
        let backingScale = self.backingScale
        rasterQueue.async {
            let image = pixelScale > 0 ? Self.drawPage(page.data, pixelScale: pixelScale) : nil
            let thumbnail = Self.drawPage(page.data, fitting: Self.thumbnailImageBox, backingScale: backingScale)
            let drawn = DrawnPage(image: image, thumbnail: thumbnail)
            Self.performOnMain { [weak self] in
                guard let self else { return }
                drawing -= 1
                guard !cancelled else { return }
                append(data: page.data, size: page.size, image: drawn.image, thumbnail: drawn.thumbnail, requested: inReach)
                finishIfDone()
            }
        }
    }

    /// A page and its thumbnail, below the last. Nothing already shown changes but the columns' heights.
    private func append(data: Data, size: CGSize, image: CGImage?, thumbnail: CGImage?, requested: Bool) {
        let index = pageViews.count
        let pageView = PageImageView(frame: pageFrame(below: pageViews.last, size: size))
        pageView.pageSize = size
        pageView.setImage(image)
        pageColumn.addSubview(pageView)
        pageViews.append(pageView)
        pageData.append(data)
        pageImageRequested.append(requested || image != nil)
        pageColumn.setFrameSize(NSSize(width: pageColumnWidth, height: pageView.frame.maxY))

        let itemWidth = thumbnailScroll.contentView.bounds.width > 0 ? thumbnailScroll.contentView.bounds.width : Self.thumbnailWidth
        let item = ThumbnailItemView(frame: NSRect(x: 0, y: CGFloat(index) * Self.thumbnailItemHeight,
                                                   width: itemWidth, height: Self.thumbnailItemHeight),
                                     number: index + 1, pageSize: size, image: thumbnail)
        item.onClick = { [weak self] in self?.showPage(index) }
        thumbnailColumn.addSubview(item)
        thumbnailViews.append(item)
        thumbnailColumn.setFrameSize(NSSize(width: itemWidth, height: item.frame.maxY))

        if selectedPageIndex == nil { updateSelection() }
        onAppend?(pageViews.count)
    }

    private func finishIfDone() {
        guard capturedAll, drawing == 0, !isComplete else { return }
        isComplete = true
        completedAt = DispatchTime.now().uptimeNanoseconds
        onComplete?()
    }

    // MARK: - Geometry

    private var pageColumnWidth: CGFloat {
        let width = pageScroll.contentView.bounds.width
        return width > 0 ? width : max(pageSize.width, 1)
    }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? 2 }

    private func pixelScale(forPageWidth width: CGFloat) -> CGFloat {
        backingScale * pageFrame(below: nil, size: CGSize(width: width, height: pageSize.height > 0 && pageSize.width > 0
            ? width * pageSize.height / pageSize.width : width * 792 / 612)).width / max(width, 1)
    }

    /// The column's visible height.
    private var pageColumnHeight: CGFloat {
        let height = pageScroll.contentView.bounds.height
        return height > 0 ? height : max(pageSize.height, 1)
    }

    /// A page fitted to the column — its width, or its visible height where that is the tighter (batch 47, M29: a window
    /// shorter for its width than the page never shows a part of the next page below the first), centred across the
    /// column, `pageGap` below `previous` (page 1 at the very top).
    func pageFrame(below previous: NSView?, size: CGSize) -> NSRect {
        let scale = min(pageColumnWidth / max(size.width, 1), pageColumnHeight / max(size.height, 1))
        let width = (size.width * scale).rounded()
        let top = previous.map { $0.frame.maxY + Self.pageGap } ?? 0
        return NSRect(x: ((pageColumnWidth - width) / 2).rounded(), y: top, width: width,
                      height: (size.height * scale).rounded())
    }

    /// The column changed width (the view was first laid out, or the window was resized): every page is fitted again
    /// and the pages within reach drawn again at the new size, the reader kept on their page.
    private func relayOutPages() {
        guard !pageViews.isEmpty, pageViews[0].frame != pageFrame(below: nil, size: pageViews[0].pageSize) else { return }
        let reading = selectedPageIndex
        var previous: NSView?
        for pageView in pageViews {
            pageView.frame = pageFrame(below: previous, size: pageView.pageSize)
            previous = pageView
        }
        pageColumn.setFrameSize(NSSize(width: pageColumnWidth, height: previous?.frame.maxY ?? 0))
        if let reading { showPage(reading) }
        for index in pageImageRequested.indices where pageViews[index].frame.intersects(reach(nearby: true)) {
            pageImageRequested[index] = false
        }
        viewMoved()
    }

    /// The column rect within reach of the view: `reachScreens` either side, or twice that for letting images go.
    private func reach(nearby: Bool) -> CGRect {
        let visible = visibleRect
        let screens = Self.reachScreens * (nearby ? 1 : 2)
        return visible.insetBy(dx: 0, dy: -visible.height * screens)
    }

    private func viewMoved() {
        updateSelection()
        let near = reach(nearby: true)
        let far = reach(nearby: false)
        for (index, pageView) in pageViews.enumerated() {
            if pageView.frame.intersects(near) {
                if !pageImageRequested[index] {
                    pageImageRequested[index] = true
                    let data = pageData[index]
                    let pixelScale = pixelScale(forPageWidth: pageView.pageSize.width)
                    rasterQueue.async {
                        let image = Self.drawPage(data, pixelScale: pixelScale)
                        let drawn = DrawnPage(image: image, thumbnail: nil)
                        Self.performOnMain { [weak self] in
                            guard let self, pageImageRequested.indices.contains(index), pageImageRequested[index] else { return }
                            pageViews[index].setImage(drawn.image)
                        }
                    }
                }
            } else if !pageView.frame.intersects(far), pageImageRequested[index] {
                pageImageRequested[index] = false
                pageView.setImage(nil)
            }
        }
    }

    private func updateSelection() {
        let visible = visibleRect
        let line = visible.minY + visible.height / 4
        let index = pageViews.firstIndex { $0.frame.maxY + Self.pageGap > line } ?? pageViews.indices.last
        guard let index, index != selectedPageIndex else { return }
        selectedPageIndex = index
        let item = thumbnailViews[index]
        selection.frame = item.convert(item.imageView.frame, to: thumbnailColumn).insetBy(dx: -4, dy: -4)
        selection.isHidden = false
    }

    // MARK: - Capture and drawing

    /// `rendered`'s pages laid out, as `QuickLookNativeRenderer` lays them out to capture them.
    private static func laidOut(_ rendered: RenderedDocument) -> PagedDocumentView {
        let pages = PagedDocumentView(frame: .zero)
        pages.setContent(rendered, display: .continuousScroll)
        pages.setFrameSize(pages.intrinsicContentSize)
        pages.layoutSubtreeIfNeeded()
        return pages
    }

    /// One page of `pages` as a one-page PDF, captured alone — `QuickLookNativeRenderer.multiPagePDF`'s capture.
    private static func capture(_ pages: PagedDocumentView, page index: Int) -> (data: Data, size: CGSize)? {
        let rect = pages.rect(ofPage: index)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return autoreleasepool {
            pages.capturingPageIndex = index
            let data = pages.dataWithPDF(inside: rect)
            pages.capturingPageIndex = nil
            return (data, rect.size)
        }
    }

    /// A one-page PDF drawn to an image, `pixelScale` pixels a point, on white.
    nonisolated static func drawPage(_ data: Data, pixelScale: CGFloat) -> CGImage? {
        guard let page = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.page(at: 1) else { return nil }
        return draw(page, scale: pixelScale)
    }

    /// A one-page PDF drawn to fit `box` points at `backingScale`.
    nonisolated static func drawPage(_ data: Data, fitting box: CGSize, backingScale: CGFloat) -> CGImage? {
        guard let page = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.page(at: 1) else { return nil }
        let media = page.getBoxRect(.mediaBox)
        let fit = min(box.width / max(media.width, 1), box.height / max(media.height, 1))
        return draw(page, scale: fit * backingScale)
    }

    private nonisolated static func draw(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let media = page.getBoxRect(.mediaBox)
        let width = Int((media.width * scale).rounded(.up))
        let height = Int((media.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: - Turns

    private func tellFirstPaint(_ error: Error?) {
        let told = firstPaint
        firstPaint = nil
        told?(error)
    }

    private static func deadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + turnBudgetNanoseconds
    }

    private nonisolated static func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(main)
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

/// What a draw hands back to the main thread.
private struct DrawnPage: @unchecked Sendable {
    let image: CGImage?
    let thumbnail: CGImage?
}

/// A flipped document view: a column that grows downward, so growing never moves what is on screen.
final class FlippedColumnView: NSView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    private var lastHeight: CGFloat = 0

    /// The clip view's width drives the page column's; a change re-fits the pages. Batch 47 (M29): so does its height,
    /// which a page may be fitted to.
    func clipWidthChanged(to width: CGFloat, height: CGFloat? = nil) {
        guard width != lastWidth || (height.map { $0 != lastHeight } ?? false) else { return }
        lastWidth = width
        if let height { lastHeight = height }
        onWidthChange?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = superview as? NSClipView {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                                   name: NSView.frameDidChangeNotification, object: clip)
        }
    }

    @objc private func clipFrameChanged(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        clipWidthChanged(to: clip.bounds.width, height: clip.bounds.height)
    }
}

/// A page, or a thumbnail's picture: an image set as its layer's contents. It never draws in `draw(_:)`, and it counts
/// every image it is given, so the tests can tell that nothing shown was drawn again.
final class PageImageView: NSView {
    var pageSize: CGSize = .zero
    private(set) var imagesSet = 0
    private(set) var image: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.contentsGravity = .resize
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func setImage(_ image: CGImage?) {
        self.image = image
        imagesSet += 1
        layer?.contents = image
    }
}

/// One thumbnail: page `number`'s picture above its number. Clicking it shows the page.
final class ThumbnailItemView: NSView {
    let imageView = PageImageView(frame: .zero)
    let label: NSTextField
    var onClick: (() -> Void)?

    init(frame: NSRect, number: Int, pageSize: CGSize, image: CGImage?) {
        label = NSTextField(labelWithString: String(number))
        super.init(frame: frame)
        let box = QuickLookProgressivePreview.thumbnailImageBox
        let fit = min(box.width / max(pageSize.width, 1), box.height / max(pageSize.height, 1))
        let size = CGSize(width: (pageSize.width * fit).rounded(), height: (pageSize.height * fit).rounded())
        imageView.frame = NSRect(x: ((frame.width - size.width) / 2).rounded(), y: 10 + (box.height - size.height) / 2,
                                 width: size.width, height: size.height)
        imageView.pageSize = pageSize
        imageView.setImage(image)
        addSubview(imageView)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 10 + box.height + 4, width: frame.width, height: 16)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Page \(number)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
