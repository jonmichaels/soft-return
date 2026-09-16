import AppKit
import CtrlKD
import SoftReturnShared
import PDFKit

/// One document window: the page, and the bottom bar under it.
///
/// The window is built in code rather than a nib — the first-open geometry rule below is
/// arithmetic on the document's own page size, which a nib cannot express, and the thin
/// title bar wants no toolbar at all.
final class DocumentWindowController: NSWindowController {
    /// The view state this window shows. Internal rather than private: the menu-command
    /// extension in `DocumentWindowController+Actions.swift` drives the same state, and
    /// splitting the commands into their own file is what keeps this one about the window.
    let documentState: DocumentState
    /// Injectable so tests can gate restoration without touching `UserDefaults.standard` —
    /// the same seam `DocumentState.init(data:settings:)` already uses.
    private let settings: SettingsStore
    private let scrollView = NSScrollView()
    /// Internal, not private: the Go menu commands live in the Actions extension and drive
    /// page navigation through this view, exactly as the style and zoom commands drive the
    /// document state. Splitting the commands into their own file is what keeps this one
    /// about the window.
    let pagedView = PagedDocumentView()
    /// Job 265: Printed style's own content view — the engine's literal PDF
    /// (`emitPDF(doc, mode: .printed)`), never `pagedView`'s AppKit layout. Lives beside
    /// `scrollView` at the same position in `content`; `reloadContent()` shows exactly one
    /// of the two, by hiding the other, depending on `documentState.style.value`.
    let pdfView = PDFView()
    let bottomBar = BottomBar()
    /// The per-window Inspector (job 314, View ▸ Show Document Info / ⌘I). Internal, not
    /// private: the Actions extension's `toggleDocumentInfo`/`validateMenuItem` read and
    /// drive it, same reasoning as `pagedView` above. Lazily created on first toggle — most
    /// windows never open it, so nothing here builds one until asked.
    var documentInfoWindowController: DocumentInfoWindowController?

    /// Set once the window has been sized from its document. The geometry rule applies to
    /// the FIRST presentation only — after that the window is the user's.
    private var hasAppliedFirstOpenGeometry = false
    /// Batch 40 (M10): the local event monitor that turns pages for a scroll in Single Page (`PagedDocumentView.flipPages`),
    /// removed when the window closes.
    private var scrollMonitor: Any?
    /// The scale the first-open rule chose, kept so `snapToViewport()` knows what size the
    /// page is meant to be on screen once the real viewport is known.
    private var firstOpenScale: CGFloat = 1
    private var hasSnappedToViewport = false
    /// How this window turns its current screen into the "Actual Size" magnification factor.
    /// A stored closure rather than a hardwired `DisplayPhysicalMetrics.live(for:)` call —
    /// injectable so a test can pin known, synthetic display metrics instead of depending on
    /// whatever real screen the test happens to run against.
    private let actualSizeMetrics: (NSScreen) -> DisplayPhysicalMetrics?

    /// #271 M7 (the engine agent's design note; batches 25–26): load a long document without holding the
    /// main thread. On for the app's own open (`WSDocument.makeWindowControllers`), for a document at
    /// least `WSDocument.backgroundParseThreshold` long (`loadsProgressively`); a shorter one loads at
    /// once, as it always did. A progressive load:
    /// - shows a spinner while the document still awaits its parse (`documentDidFinishParsing()`);
    /// - makes the engine's half of a render (`NativeEngineWork`, `ModernEngineWork`) and the Printed PDF
    ///   off the main thread;
    /// - builds the attributed text a slice of a run-loop turn at a time (`turnBudgetNanoseconds`), Native
    ///   showing its first pages as soon as they exist;
    /// - lays the pages out the same way: a few with the content, the rest on later turns
    ///   (`PagedDocumentView.layOutMorePages(until:)`).
    /// Off by default, so a test that builds a window and measures it at once has every page, as before.
    private let progressiveOpen: Bool
    /// Whether the content is still being made: a parse awaited, a render under way, or pages to lay out.
    private(set) var isLoadingContent = false
    /// The document's page count while a Native render or its layout is under way; nil once the pages view knows.
    private(set) var expectedPageTotal: Int?
    /// A page asked for (Go menu, AppleScript, a style switch) past the pages laid out so far; gone to once they are.
    var pendingPageIndex: Int?
    /// Bumped by every load, so the rest of a progressive load stops if its content is replaced.
    private var loadToken = 0
    /// Bumped by everything that changes what a style renders — variant, page size, margins, Show
    /// Invisibles, restoration — and never by a style switch, which is what the caches below keep.
    private var contentGeneration = 0
    private struct RenderKey: Hashable {
        let style: ViewStyle
        let showInvisibles: Bool
        let modernFontName: String
        let modernFontSize: Int
        let generation: Int
    }
    /// #271 M7: each paged style's rendered document for `contentGeneration`, so going back to a style
    /// never runs its whole-document passes again (`docToPagelines` or `modernSemanticFlow`, and the
    /// text built on it).
    private var renderedCache: [RenderKey: RenderedDocument] = [:]
    /// Printed's PDF for `contentGeneration`, so going back to Printed never emits it again.
    private var printedCache: (generation: Int, document: PDFDocument)?
    /// Batch 27: each unpinned render's probe (Show Invisibles, Native), so going back to it never measures the
    /// whole flow again.
    private var probeCache: [RenderKey: PagedDocumentView.ExplicitProbe] = [:]
    /// Batch 27: the style whose content is on screen now — which, while a progressive load runs, can still be the
    /// style before a switch.
    private(set) var shownContentStyle: ViewStyle? {
        didSet { shownContentVersion += 1 }
    }
    /// Batch 27: bumped every time new content goes on screen — a first page, a preview, a whole render, a PDF —
    /// the same style again included (Show Invisibles turned on or off).
    private(set) var shownContentVersion = 0
    /// Batch 27: Modern's text built before its first pages are shown from a snapshot of it — far enough past a
    /// first page that the page is the whole render's own.
    static let modernPreviewCharacters = 32_000
    private var allPagesToken: PerformanceSignposts.Token?
    /// Pages a progressive Native render shows before the rest of its text is built.
    static let firstPages = 3
    /// Pages a progressive load lays out with its content, the rest following a turn at a time: one, because
    /// a page is what the reader sees, and laying out three with Modern's content made that turn — the text
    /// copied into a new storage, three pages laid out, the page drawn — the only one at or over 100 ms left
    /// (b26-holymac-fix5: `pages.setContent` 67–72 ms, turns of 98.5–102.5 ms).
    static let firstLaidOutPages = 1
    /// The longest a progressive load's work holds one turn of the main run loop before it yields.
    static let turnBudgetNanoseconds: UInt64 = 20_000_000
    /// Shown while a progressive load has nothing new on screen yet.
    let loadingIndicator = NSProgressIndicator()
    /// The page size the first-open geometry was sized for. A progressive load sizes the window before its
    /// pages exist, against a stand-in, and sizes it again once if the real page differs (`contentDidAppear`).
    private var firstOpenPageSize: CGSize?
    private var hasShownContent = false

    init(state: DocumentState, settings: SettingsStore = .shared,
         actualSizeMetrics: @escaping (NSScreen) -> DisplayPhysicalMetrics? = DisplayPhysicalMetrics.live,
         progressiveOpen: Bool = false) {
        self.documentState = state
        self.settings = settings
        self.actualSizeMetrics = actualSizeMetrics
        self.progressiveOpen = progressiveOpen
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
            // NO .fullSizeContentView. It exists so content can show THROUGH a transparent
            // titlebar; with an opaque one it only hides content, and it breaks the geometry
            // rule twice over: `contentRect(forFrameRect:)` becomes the frame itself, so
            // `titleBarHeight` measures 0 for a bar that really costs 28pt, and AppKit hands
            // the scroll view an automatic 28pt top content inset nobody asked for.
            // Measured before removal: titleBarHeight=0, contentLayoutRect 28pt shorter than
            // the frame, scrollView.contentInsets.top = 28.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Thin title bar, BBEdit-class: traffic lights, the proxy icon and the filename as
        // one centred group, and no toolbar buttons at all.
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        // No `toolbarStyle`: this window never installs an NSToolbar, and setting a style
        // for a toolbar that does not exist only invited the content inset above.
        // A stable identifier, not just `isRestorable` (default true): AppKit needs one to
        // correlate a window's encoded state back to a window on relaunch.
        window.identifier = NSUserInterfaceItemIdentifier("document-window")
        // "Restore windows on launch" OFF means this window writes nothing at quit time —
        // set once at window creation, matching how every other preference in this app reads
        // as "what happens to windows opened from now on" rather than reaching back into
        // windows already open. See `window(_:willEncodeRestorableState:)` below for the
        // belt-and-suspenders gate on the custom state blob specifically.
        window.isRestorable = settings.restoreWindowsOnLaunch
        super.init(window: window)
        // #271 M7: from here to the pages' first draw, and the window's own construction within it.
        let firstPage = PerformanceSignposts.begin("open.firstPageDrawn")
        pagedView.onFirstDraw = { PerformanceSignposts.end(firstPage) }
        allPagesToken = PerformanceSignposts.begin("open.allPages")
        window.delegate = self
        PerformanceSignposts.measure("open.window") { buildContent() }
        if !isLoadingContent { endAllPages() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // The geometry rule says no scrollbars on first open. Autohiding is what keeps that
        // true without lying later: a window the user has since shrunk DOES need them.
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // A CenteringClipView BEFORE `documentView` is assigned — the centring ruling
        // (page centred on any axis smaller than the viewport, normal scrolling on any axis
        // larger) lives entirely in that class; see its doc comment.
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .softReturnCanvas
        // Zoom is the scroll view's own magnification, which is what makes pinch-to-zoom
        // and the Zoom In/Out commands one mechanism rather than three.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4.0
        scrollView.documentView = pagedView
        // A scroll gesture in Single Page flips pages, which changes what the Go menu should
        // allow. Menu validation runs when a menu opens, so this only has to keep the window
        // in step — but without it, page-dependent UI would lag a flick by one interaction.
        // #271 M7: only the page indicator. Nothing else the bottom bar shows depends on the page,
        // and rebuilding its five menus on every flip was work a fast scroll through a long
        // document repeats page after page.
        pagedView.pageDidChange = { [weak self] _ in
            self?.refreshPageIndicator()
        }
        // Batch 40 (M10): Single Page's scroll-to-flip, from a local monitor rather than a `scrollWheel(with:)`
        // override on the pages view — an override takes the scroll view out of responsive scrolling, which
        // Continuous Scroll needs. An event over this window's pages is consumed only when it turned pages.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // The isolated part answers only whether pages turned: its result must be Sendable, and an NSEvent is not.
            let turnedPages = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window,
                      self.pagedView.flipsPagesOnScroll, !self.scrollView.isHidden,
                      self.scrollView.bounds.contains(self.scrollView.convert(event.locationInWindow, from: nil))
                else { return false }
                return self.pagedView.flipPages(for: event)
            }
            return turnedPages ? nil : event
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("document-scroll-view")
        // A11Y AUDIT FIX (label not human-readable, finding 2 of 2): an identifier is a
        // programmatic handle, not a label — this carried the former with nothing standing
        // in for the latter.
        scrollView.setAccessibilityLabel("Document")

        // Scroller style is NOT a constant. macOS switches between overlay and legacy
        // depending on whether a mouse is in use, and it can flip while a document is open.
        // That matters here because legacy scrollers take their thickness out of the clip
        // view: a window sized under one style and laid out under the other ends up with a
        // viewport smaller than the page, and both scrollers appear — the exact thing the
        // first-open rule forbids. Re-fit when it changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollerStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil)

        // Printed style's own view, at rest until `reloadContent()` shows it — see the
        // property's own doc comment. `autoScales` stays false: `applyZoom()` drives
        // `pdfView.scaleFactor` explicitly, the same "one named ZoomSetting, one scale
        // formula" contract the AppKit path already keeps.
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = false
        pdfView.backgroundColor = .softReturnCanvas
        // PDFKit's own defaults draw a drop shadow just outside each page's media box —
        // `PagedDocumentView.draw(_:)` draws no such shadow for Native, so left on, this is
        // extra content beyond the page's true bounds that the internal scroll view sees:
        // exactly the "grey padding around the page" and the sliver of scrollers Native
        // never shows for the same page rect and scale. Off makes Printed's true content
        // size equal the page's `mediaBox`, matching what `currentPageSize()` already
        // assumes it is.
        pdfView.pageShadowsEnabled = false
        // Job 298 — THE REAL FIX. `pageShadowsEnabled = false` (above) was not enough: PDFKit
        // pads `PDFDocumentView`'s own layout size beyond the page's `mediaBox` by
        // `pageBreakMargins` REGARDLESS of the shadow — measured on OLDTIMES.WS at 1100x800,
        // Fit: page 612x792, but the internal document view laid out at 628x811 (16pt/19pt of
        // margin PDFKit reserves for inter-page spacing even in Single Page mode). `applyZoom()`
        // computes `fitScale` from the PAGE size (`currentPageSize()`), then PDFKit applies that
        // same scale factor to its OWN, margin-padded document view — so the margin's extra
        // 19pt of height survives scaling and pushes the effective content 18.6pt past the
        // viewport at Fit, which is invisible to a static rect probe (job 278's
        // `PrintedViewFramingTests`, tolerance 1.0pt on the PAGE rect, which itself measures
        // correctly) but is real, persistent overflow: PDFKit's internal scroll view responds
        // by showing a genuine, non-transient (`NSScroller.Style.legacy` on this Mac) vertical
        // scroller — Jon's field screenshots' "grey band and scrollbars appear". Zero margins
        // makes the document view's true size equal the page's, the same "true content size
        // equals the page's mediaBox" contract the shadow fix above already established.
        pdfView.pageBreakMargins = NSEdgeInsetsZero
        pdfView.setAccessibilityIdentifier("document-pdf-view")
        pdfView.setAccessibilityLabel("Document")
        pdfView.isHidden = true
        // Job 454 (PART B): Printed's page indicator needs to track navigation that never
        // goes through `goToPage(index:)` at all — PDFView owns its own keyboard (arrow/page
        // up-down), trackpad-swipe, and scroll-driven page changes internally. This is the one
        // hook PDFKit gives for "the current page changed", regardless of which of those moved
        // it, so it is the only reliable place to call `refreshPageIndicator()` from for
        // Printed — `goToPage(index:)`'s own Printed branch (`DocumentWindowController+Actions.
        // swift`) relies on this notification firing rather than calling it directly.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfViewPageChanged),
            name: .PDFViewPageChanged,
            object: pdfView)

        bottomBar.delegate = self
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        // Batch 26: a progressive load's spinner, over whichever content view shows.
        loadingIndicator.style = .spinning
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.setAccessibilityLabel("Loading document")

        content.addSubview(scrollView)
        content.addSubview(pdfView)
        content.addSubview(loadingIndicator)
        content.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            pdfView.topAnchor.constraint(equalTo: content.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        window.contentView = content

        reloadContent()
    }

    /// Re-render and re-present. Called for anything that changes what the page looks like:
    /// variant, style, invisibles, font.
    ///
    /// Job 265: dispatches to one of two entirely different content views depending on
    /// style — `pagedView` (AppKit, Native/Modern) or `pdfView` (PDFKit, Printed) — showing
    /// exactly one and hiding the other. Job 256 (Show Invisibles part 2/4): this is still
    /// the ONLY call site allowed to request `DocumentRenderer.renderWithInvisibles` — every
    /// other renderer caller (`ExportEngine`, `makePrintOperation`, `QuickLookNativeRenderer`,
    /// `PagePreviewRenderer`) keeps calling the plain `render(_:style:)`, which never
    /// consults `showInvisibles` at all. See `DocumentRenderer.render`'s own top doc comment.
    private func reloadContent() {
        let isPrinted = documentState.style.value == .printed
        if isPrinted {
            loadPrintedPDFContent()
        } else {
            loadPagedContent()
        }
        scrollView.isHidden = isPrinted
        pdfView.isHidden = !isPrinted
        bottomBar.update(from: documentState)
        refreshPageIndicator()
        applyZoom()
        // Job 314: keep the Inspector honest across a variant/style/page-size change while
        // it happens to be open — never recomputed for a window that never opened it.
        if documentInfoWindowController?.window?.isVisible == true {
            documentInfoWindowController?.refresh(from: self)
        }
    }

    /// Lazily creates the Inspector on first use — see `documentInfoWindowController`'s own
    /// doc comment for why this is not built eagerly with every window.
    func documentInfoWindowControllerCreatingIfNeeded() -> DocumentInfoWindowController {
        if let documentInfoWindowController { return documentInfoWindowController }
        let controller = DocumentInfoWindowController()
        documentInfoWindowController = controller
        return controller
    }

    /// Batch 26: whether this window's loads are progressive — the app's own open, of a long document.
    private var loadsProgressively: Bool {
        progressiveOpen && documentState.data.count >= WSDocument.backgroundParseThreshold
    }

    /// A new load: whatever the last one left for later turns stops here (`loadToken`).
    private func beginLoad() -> Int {
        loadToken += 1
        isLoadingContent = false
        expectedPageTotal = nil
        loadingIndicator.stopAnimation(nil)
        return loadToken
    }

    /// The load has work left for later turns. `spinner` when nothing on screen stands for it yet.
    private func setLoading(spinner: Bool) {
        isLoadingContent = true
        if spinner {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    /// Every part of the load is done.
    private func finishLoad() {
        isLoadingContent = false
        expectedPageTotal = nil
        loadingIndicator.stopAnimation(nil)
        goToPendingPage()
        refreshPageIndicator()
        endAllPages()
    }

    /// The cache key for what the window shows now.
    private var currentRenderKey: RenderKey {
        let style = documentState.style.value
        return RenderKey(style: style, showInvisibles: style != .printed && documentState.showInvisibles,
                         modernFontName: documentState.modernFontName,
                         modernFontSize: documentState.modernFontSize, generation: contentGeneration)
    }

    private func loadPagedContent() {
        let token = beginLoad()
        let key = currentRenderKey
        // Batch 26: nothing to render until the parse returns (`documentDidFinishParsing`).
        if documentState.isAwaitingParse {
            setLoading(spinner: true)
            return
        }
        // #271 M7: a style already shown lays out its rendered document again, without re-entering
        // the engine or rebuilding the text.
        if let cached = renderedCache[key] {
            present(cached, token: token)
            return
        }
        if loadsProgressively {
            setLoading(spinner: true)
            switch (key.style.renderStyle, key.showInvisibles) {
            case (.native, false): renderNativeProgressively(token: token)
            case (.modern, false): renderModernProgressively(token: token)
            // Batch 27: Show Invisibles goes the same way — engine work off the main thread, the rest in slices.
            case (.native, true): renderNativeAnnotatedProgressively(token: token)
            case (.modern, true): renderModernAnnotatedProgressively(token: token)
            }
            return
        }
        // Job 294: Modern shows invisibles too now, not just Native — `renderWithInvisibles`
        // itself picks the right annotated pass per style (`renderNativeAnnotated` vs
        // `renderModernAnnotated`); Printed never reaches here (`reloadContent` routes it to
        // `pdfView` instead).
        let rendered = PerformanceSignposts.measure("render.content") {
            key.showInvisibles
                ? DocumentRenderer.renderWithInvisibles(documentState)
                : DocumentRenderer.render(documentState, style: key.style.renderStyle)
        }
        renderedCache[key] = rendered
        present(rendered, token: token)
    }

    /// Shows `rendered`: every page at once, or — in a progressive load — the first few now and the rest a
    /// turn at a time (`layOutRemainingPages`), the reader's page gone to once it is laid out.
    private func present(_ rendered: RenderedDocument, token: Int) {
        // Batch 27: a render that pins nothing (Show Invisibles, Native) is laid out from a probe measured offscreen
        // in slices first, so its pages come a turn at a time too.
        let key = currentRenderKey
        var probe = probeCache[key]
        if loadsProgressively, rendered.clipsLines, probe == nil, !PagedDocumentView.pinsEveryPage(rendered) {
            measureProbe(PagedDocumentView.ProbeMeasurement(rendered: rendered), token: token)
            return
        }
        if !loadsProgressively { probe = nil }
        let readerPage = currentPage
        let display = documentState.display.value
        PerformanceSignposts.measure("pages.setContent") {
            pagedView.setContent(rendered, display: display, firstPages: loadsProgressively ? Self.firstLaidOutPages : nil,
                                 probe: probe)
        }
        shownContentStyle = documentState.style.value
        contentDidAppear()
        guard !pagedView.isLaidOut else {
            finishLoad()
            return
        }
        expectedPageTotal = rendered.clipsLines ? rendered.pageCount : nil
        if pendingPageIndex == nil, readerPage >= pagedView.pageCount {
            pendingPageIndex = readerPage
        }
        setLoading(spinner: false)
        layOutRemainingPages(token: token)
    }

    /// `body` on a later turn of the main run loop, unless another load has replaced this one by then.
    ///
    /// A run-loop perform in the default mode, not `DispatchQueue.main.async`: a main-queue block cannot
    /// run while another main-queue block is running, and a caller that turns the run loop from inside one
    /// (a `@MainActor` test waiting on the pages) starved every chunk (b25-holymac-fix1). The default mode
    /// also pauses the work while a scroll or resize is being tracked, so it never stutters one.
    private func onNextTurn(token: Int, _ body: @escaping @MainActor @Sendable (DocumentWindowController) -> Void) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.loadToken == token else { return }
                body(self)
            }
        }
    }

    private static func turnDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + turnBudgetNanoseconds
    }

    /// The pages `present` left, a turn's budget of them at a time.
    private func layOutRemainingPages(token: Int) {
        onNextTurn(token: token) { controller in
            let done = PerformanceSignposts.measure("pages.layOut") {
                controller.pagedView.layOutMorePages(until: DocumentWindowController.turnDeadline())
            }
            if done {
                controller.finishLoad()
            } else {
                controller.goToPendingPage()
                controller.refreshPageIndicator()
                controller.layOutRemainingPages(token: token)
            }
        }
    }

    /// Goes to the page asked for past the pages laid out, once it is laid out (or nothing more is coming).
    private func goToPendingPage() {
        guard let pending = pendingPageIndex, pending < pagedView.pageCount || !isLoadingContent else { return }
        pendingPageIndex = nil
        goToPage(index: pending)
    }

    /// The first content of a progressive load is on screen, so the page's real size is known: the
    /// first-open geometry, sized against a stand-in (`currentPageSize`) or not at all yet, is sized again
    /// if they differ, and the zoom settles on it.
    private func contentDidAppear() {
        guard loadsProgressively, !hasShownContent else { return }
        hasShownContent = true
        if firstOpenPageSize != currentPageSize() {
            hasAppliedFirstOpenGeometry = false
            hasSnappedToViewport = false
            applyFirstOpenGeometry()
        }
        applyZoom()
    }

    /// Batch 27: the offscreen probe for the render just cached, a turn's budget at a time; then the render is shown.
    private func measureProbe(_ measurement: PagedDocumentView.ProbeMeasurement, token: Int) {
        onNextTurn(token: token) { controller in
            PerformanceSignposts.measure("pages.probe") {
                measurement.measure(until: DocumentWindowController.turnDeadline())
            }
            guard measurement.isComplete else {
                controller.measureProbe(measurement, token: token)
                return
            }
            controller.probeCache[controller.currentRenderKey] = measurement.result()
            controller.presentCachedOnNextTurn(token: token)
        }
    }

    /// Batch 27: Native's Show Invisibles render, progressively.
    private func renderNativeAnnotatedProgressively(token: Int) {
        let document = documentState.document
        let options = DocumentRenderer.nativeEngineOptions(documentState)
        let start = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) {
            let work = NativeAnnotatedEngineWork.make(document: document, options: options)
            MainRunLoop.perform { [weak self] in
                guard let self, self.loadToken == token else { return }
                PerformanceSignposts.record("render.engine", startedAt: start)
                let render = PerformanceSignposts.measure("render.session") {
                    DocumentRenderer.nativeAnnotatedRender(self.documentState, engine: work)
                }
                self.renderSliced(render, token: token)
            }
        }
    }

    /// Batch 27: Modern's Show Invisibles render, progressively.
    private func renderModernAnnotatedProgressively(token: Int) {
        let document = documentState.document
        let options = DocumentRenderer.modernEngineOptions(documentState)
        let start = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) {
            let flow = modernSemanticFlow(document)
            // Batch 41 (A): the engine's Modern page furniture runs the whole Modern emitter — made here, off the main
            // thread, beside the flow, with the Modern export's own options.
            let furniture = modernPageFurniture(document, options: options)
            MainRunLoop.perform { [weak self] in
                guard let self, self.loadToken == token else { return }
                PerformanceSignposts.record("render.engine", startedAt: start)
                let render = PerformanceSignposts.measure("render.session") {
                    DocumentRenderer.modernAnnotatedRender(self.documentState, flow: flow, furniture: furniture)
                }
                self.renderSliced(render, token: token)
            }
        }
    }

    /// Batch 27: a sliced render a turn's budget at a time, finished on a turn of its own, cached, then shown.
    private func renderSliced(_ render: DocumentRenderer.SlicedRender, token: Int) {
        onNextTurn(token: token) { controller in
            PerformanceSignposts.measure("render.chunk") {
                render.renderNext(until: DocumentWindowController.turnDeadline())
            }
            guard render.isComplete else {
                controller.renderSliced(render, token: token)
                return
            }
            controller.onNextTurn(token: token) { controller in
                let rendered = PerformanceSignposts.measure("render.finish") { render.finish() }
                controller.renderedCache[controller.currentRenderKey] = rendered
                controller.presentCachedOnNextTurn(token: token)
            }
        }
    }

    /// Batch 26: the document this window opened awaiting its parse has it now
    /// (`WSDocument.startDeferredParse`); the bottom bar reads its variant and page size, and its content loads.
    func documentDidFinishParsing() {
        reloadContent()
    }

    /// Batch 26: a Native render made the progressive way — the engine's half off the main thread, then the
    /// text a turn's budget at a time, the first pages shown as soon as they exist.
    private func renderNativeProgressively(token: Int) {
        let document = documentState.document
        let options = DocumentRenderer.nativeEngineOptions(documentState)
        let start = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) {
            let work = NativeEngineWork.make(document: document, options: options, pictures: true)
            MainRunLoop.perform { [weak self] in
                self?.nativeEngineWorkDone(work, token: token, startedAt: start)
            }
        }
    }

    private func nativeEngineWorkDone(_ work: NativeEngineWork, token: Int, startedAt start: UInt64) {
        guard loadToken == token else { return }
        PerformanceSignposts.record("render.engine", startedAt: start)
        let session = PerformanceSignposts.measure("render.session") {
            DocumentRenderer.nativeRenderSession(documentState, engine: work)
        }
        expectedPageTotal = session.pageCount
        renderNativeText(session, token: token, firstPagesShown: false)
    }

    private func renderNativeText(_ session: DocumentRenderer.NativeRenderSession, token: Int, firstPagesShown: Bool) {
        onNextTurn(token: token) { controller in
            PerformanceSignposts.measure("render.chunk") {
                session.renderNext(until: DocumentWindowController.turnDeadline())
            }
            guard !session.isComplete else {
                controller.onNextTurn(token: token) { controller in
                    let rendered = PerformanceSignposts.measure("render.finish") { session.snapshot(final: true) }
                    controller.renderedCache[controller.currentRenderKey] = rendered
                    controller.presentCachedOnNextTurn(token: token)
                }
                return
            }
            var shown = firstPagesShown
            if !shown, session.renderedPages >= DocumentWindowController.firstPages {
                // The first pages, while the rest render.
                let first = PerformanceSignposts.measure("render.firstPages") { session.snapshot() }
                PerformanceSignposts.measure("pages.setContent") {
                    controller.pagedView.setContent(first, display: controller.documentState.display.value)
                }
                controller.shownContentStyle = controller.documentState.style.value
                controller.contentDidAppear()
                controller.setLoading(spinner: false)
                controller.refreshPageIndicator()
                shown = true
            }
            controller.renderNativeText(session, token: token, firstPagesShown: shown)
        }
    }

    /// Batch 26: a Modern render made the progressive way — the flow off the main thread, then the text a
    /// turn's budget at a time. Modern's pages are AppKit's to find, so nothing of it shows until it is whole.
    private func renderModernProgressively(token: Int) {
        let document = documentState.document
        let options = DocumentRenderer.modernEngineOptions(documentState)
        let start = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) {
            let work = ModernEngineWork.make(document: document, options: options)
            MainRunLoop.perform { [weak self] in
                self?.modernEngineWorkDone(work, token: token, startedAt: start)
            }
        }
    }

    private func modernEngineWorkDone(_ work: ModernEngineWork, token: Int, startedAt start: UInt64) {
        guard loadToken == token else { return }
        PerformanceSignposts.record("render.engine", startedAt: start)
        let session = PerformanceSignposts.measure("render.session") {
            DocumentRenderer.modernRenderSession(documentState, engine: work)
        }
        renderModernText(session, token: token, previewShown: false)
    }

    /// Batch 27 (item 3): once the text runs `modernPreviewCharacters` past the start, Modern's first pages show from
    /// a snapshot while the rest renders — the Native way — and the whole render replaces them when it is done.
    private func renderModernText(_ session: DocumentRenderer.ModernRenderSession, token: Int, previewShown: Bool) {
        onNextTurn(token: token) { controller in
            PerformanceSignposts.measure("render.chunk") {
                session.renderNext(until: DocumentWindowController.turnDeadline())
            }
            guard session.isComplete else {
                var shown = previewShown
                if !shown, session.textLength >= DocumentWindowController.modernPreviewCharacters {
                    let preview = PerformanceSignposts.measure("render.firstPages") { session.snapshot() }
                    PerformanceSignposts.measure("pages.setContent") {
                        controller.pagedView.setContent(preview, display: controller.documentState.display.value,
                                                        firstPages: DocumentWindowController.firstLaidOutPages)
                    }
                    controller.shownContentStyle = controller.documentState.style.value
                    controller.contentDidAppear()
                    controller.setLoading(spinner: false)
                    controller.refreshPageIndicator()
                    shown = true
                }
                controller.renderModernText(session, token: token, previewShown: shown)
                return
            }
            controller.onNextTurn(token: token) { controller in
                let rendered = PerformanceSignposts.measure("render.finish") { session.finish() }
                controller.renderedCache[controller.currentRenderKey] = rendered
                controller.presentCachedOnNextTurn(token: token)
            }
        }
    }

    /// Shows the rendered document just cached for what the window shows, on the next turn — each of the
    /// render's last steps gets a turn of its own.
    private func presentCachedOnNextTurn(token: Int) {
        onNextTurn(token: token) { controller in
            guard let rendered = controller.renderedCache[controller.currentRenderKey] else { return }
            controller.present(rendered, token: token)
        }
    }

    private func endAllPages() {
        guard let token = allPagesToken else { return }
        allPagesToken = nil
        PerformanceSignposts.end(token)
    }

    /// Everything a style renders from has changed: forget every style's rendered answer.
    private func invalidateRenderedContent() {
        contentGeneration += 1
        renderedCache.removeAll()
        printedCache = nil
        probeCache.removeAll()
    }

    /// The engine's own PDF, not `DocumentRenderer` at all — `emitPDF(doc, mode: .printed)`
    /// is literally what `sr --mode printed` writes, so this view is byte-identical to the
    /// CLI by construction, never a second AppKit approximation of it. Page settings flow
    /// through the SAME `EmitOptions.pageSettings` channel `ExportEngine`'s Printed-mode PDF
    /// export and `DocumentRenderer.renderNative`'s screen path both already use — a preset
    /// chosen in the footer can never disagree with what this view shows.
    private func loadPrintedPDFContent() {
        // Job 371 item 1 (PIX IN VIEWS): `documentState.pixResults` was already resolved once
        // against the document's own real path at open/reparse time — reused here rather than
        // re-resolved, same "decode once per document" contract every other pix consumer keeps.
        let token = beginLoad()
        defer { applyPrintedDisplayMode() }
        // Batch 26: nothing to emit until the parse returns (`documentDidFinishParsing`).
        if documentState.isAwaitingParse {
            setLoading(spinner: true)
            return
        }
        // #271 M7: a Printed PDF already emitted for this content is shown again, not emitted again.
        if let cached = printedCache, cached.generation == contentGeneration {
            if pdfView.document !== cached.document { pdfView.document = cached.document }
            shownContentStyle = .printed
            return
        }
        let options = EmitOptions(
            pageSettings: documentState.pageSettingsPreset.value?.settings,
            pixResults: documentState.pixResults)
        guard loadsProgressively else {
            let bytes = PerformanceSignposts.measure("printed.emit") {
                emitPDF(documentState.document, mode: .printed, options: options)
            }
            showPrintedPDF(bytes)
            return
        }
        // Batch 26: the engine's PDF, made off the main thread (`printedPDFDone`).
        setLoading(spinner: true)
        let document = documentState.document
        let start = DispatchTime.now().uptimeNanoseconds
        Task.detached(priority: .userInitiated) {
            let bytes = emitPDF(document, mode: .printed, options: options)
            MainRunLoop.perform { [weak self] in
                self?.printedPDFDone(bytes, token: token, startedAt: start)
            }
        }
    }

    private func printedPDFDone(_ bytes: [UInt8], token: Int, startedAt start: UInt64) {
        guard loadToken == token else { return }
        PerformanceSignposts.record("printed.emit", startedAt: start)
        showPrintedPDF(bytes)
        applyPrintedDisplayMode()
        contentDidAppear()
        finishLoad()
    }

    private func showPrintedPDF(_ bytes: [UInt8]) {
        PerformanceSignposts.measure("printed.load") {
            pdfView.document = PDFDocument(data: Data(bytes))
        }
        shownContentStyle = .printed
        if let document = pdfView.document { printedCache = (contentGeneration, document) }
    }

    private func applyPrintedDisplayMode() {
        pdfView.displayMode = documentState.display.value == .continuousScroll
            ? .singlePageContinuous : .singlePage
    }

    // MARK: - Commands (driven by the menu extension)

    /// Re-render after a state change the menu made.
    func rerender() {
        invalidateRenderedContent()
        reloadContent()
    }

    func setStyle(_ style: ViewStyle) {
        documentState.style.setManually(style)
        reloadContent()
    }

    func setDisplay(_ display: PageDisplay) {
        documentState.display.setManually(display)
        pagedView.setDisplay(display)
        pdfView.displayMode = display == .continuousScroll ? .singlePageContinuous : .singlePage
        bottomBar.update(from: documentState)
        refreshPageIndicator()
        applyZoom()
    }

    /// Job 450 (b6) introduced the bottom bar's "Page N of M"; job 454 makes it unconditional
    /// — Jon: "always on", every style and display mode, never gated on page count.
    /// `currentPage`/`pageTotal` (`DocumentWindowController+Actions.swift`) already read
    /// whichever of `pagedView`/`pdfView` is live, so this is a small wrapper, not a new
    /// source of truth — called from every place that already calls `bottomBar.update(from:)`
    /// PLUS `goToPage(index:)`, which changes the current page without touching anything else
    /// the bar shows, and `pdfViewPageChanged` (below), which catches Printed navigation PDFKit
    /// drives itself (arrow keys, trackpad swipe, scrolling) outside `goToPage(index:)` entirely.
    func refreshPageIndicator() {
        bottomBar.updatePageIndicator(currentPage: currentPage, pageTotal: pageTotal)
    }

    func setZoom(_ zoom: ZoomSetting) {
        documentState.zoom.setManually(zoom)
        bottomBar.update(from: documentState)
        applyZoom()
    }

    func setPageSize(_ size: NamedPageSize) {
        documentState.setPageSize(size)
        invalidateRenderedContent()
        reloadContent()
    }

    func setPageSettingsPreset(_ preset: DocumentOperations.PageSettingsPreset?) {
        documentState.setPageSettingsPreset(preset)
        invalidateRenderedContent()
        reloadContent()
    }

    /// Re-parse under `variant` (`nil` == Auto, back to the detector's own answer) — the ONE
    /// path both the bottom bar's popup and the Edit ▸ Change Variant menu drive, so a
    /// selection from either one applies exactly the same way. `DocumentState.setVariant`
    /// always re-parses, even when `variant` is already current: there is no early-return
    /// short-circuit here or in it, which is the "forced re-parse on selection" Jon's ruling
    /// asks for.
    func setVariant(_ variant: Variant?) {
        if let variant {
            if let error = documentState.setVariant(variant) {
                presentVariantFailure(variant, error)
                return
            }
        } else {
            documentState.resetVariantToAuto()
        }
        invalidateRenderedContent()
        reloadContent()
    }

    /// "That isn't WS4" is an answer to the user's question, not a failure to show them
    /// anything — the previous parse stays on screen behind the alert.
    private func presentVariantFailure(_ variant: Variant, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "This file can’t be read as that format."
        alert.informativeText =
            "Soft Return couldn’t parse it that way, so it’s still showing the previous "
            + "reading. Try another format, or Auto to go back to what was detected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// What is actually on screen right now, whatever named state produced it — the figure
    /// Zoom In/Out needs to find the nearest rung when coming from Fit. Printed reads
    /// `pdfView.scaleFactor` instead of `scrollView.magnification` — the two views' own
    /// native scale properties — since exactly one of the two is ever showing content.
    var currentMagnification: CGFloat {
        documentState.style.value == .printed ? pdfView.scaleFactor : scrollView.magnification
    }

    /// The page size currently on screen, however it got there — `pdfView`'s own loaded
    /// `PDFDocument` for Printed, `DocumentRenderer`'s AppKit layout for Native/Modern. The
    /// one place `applyFirstOpenGeometry`/`snapToViewport`/`applyZoom` all ask "how big is
    /// the page", so none of the three can disagree about which view is authoritative.
    func currentPageSize() -> CGSize {
        // Batch 26: while a progressive load has nothing of this style on screen yet, the named page size
        // stands in. Rendering the whole document here only to measure its page is the very block the load
        // exists to avoid; the real size replaces the stand-in when the content arrives (`contentDidAppear`).
        let standIn = isLoadingContent ? (documentState.pageSize.value?.sizeInPoints ?? .zero) : .zero
        if documentState.style.value == .printed {
            return pdfView.document?.page(at: 0)?.bounds(for: .mediaBox).size ?? standIn
        }
        if isLoadingContent, pagedView.renderedPageSize == nil {
            return standIn
        }
        // #271 M7: the page the pages view has laid out. `reloadContent()` loads it before anything
        // asks, so this no longer renders the whole document again for every zoom, resize and
        // first-open measure (five full renders on one open, from the code: init's applyZoom,
        // applyFirstOpenGeometry, windowDidResize, showWindow's applyZoom, snapToViewport).
        if let laidOut = pagedView.renderedPageSize {
            return laidOut
        }
        return PerformanceSignposts.measure("render.pageSize") {
            DocumentRenderer.render(documentState, style: documentState.style.value.renderStyle).pageSize
        }
    }

    /// The viewport the current content view actually has to draw into — `scrollView`'s clip
    /// view for Native/Modern, `pdfView`'s own bounds for Printed (it manages its own
    /// scrolling internally, so its bounds ARE its viewport, the same role the clip view
    /// plays for `scrollView`).
    func currentViewportSize() -> CGSize {
        documentState.style.value == .printed ? pdfView.bounds.size : scrollView.contentView.frame.size
    }

    /// This window's CURRENT screen turned into an Actual Size magnification factor (see
    /// `ActualSizeMagnification`). Internal, not private: `stepZoom` (in the Actions
    /// extension) needs it too, now that 100% means `actualScale` rather than a flat 1.0 —
    /// converting Fit's raw magnification into "percent" has to divide by the SAME actualScale
    /// `applyZoom()` used to draw it, or the two would disagree about what "100%" means.
    var currentActualScale: CGFloat {
        let metrics = window?.screen.flatMap(actualSizeMetrics)
        return ActualSizeMagnification.compute(from: metrics)
    }

    /// The default filename for an export: the source's own name without its extension, so
    /// "PAPER.WS" exports as "PAPER.md" and a batch keeps every row's own basename.
    var exportBasename: String {
        let name = document?.fileURL?.deletingPathExtension().lastPathComponent
        return name ?? (document as? NSDocument)?.displayName ?? "Untitled"
    }

    // MARK: - The first-open geometry rule

    /// "First open: Printed style, Single Page, Zoom to Fit, window size DERIVED from the
    /// page so the page fills it exactly — no grey visible on any side, NO scrollbars."
    ///
    /// So the window is sized from the document, not the other way round: take the page's
    /// aspect, scale it to what fits comfortably on this screen, and make the content area
    /// exactly that plus the bottom bar. Magnification is set to the same scale, so the
    /// page lands pixel-exact against the content edges and neither scroller has anything
    /// to show.
    ///
    /// This must be called from `showWindow(_:)` and NOWHERE ELSE. It is guarded to run
    /// once, so the first caller wins — and for a controller built with `init(window:)`,
    /// `windowDidLoad()` can fire on the first access to `self.window`, which happens inside
    /// `buildContent()` before the scroll view exists. Calling it there would burn the
    /// single run against an empty view tree and silently disable the geometry rule; the
    /// tell is scrollbars visible on first open. (Measured 2026-08-02: `windowDidLoad` does
    /// NOT fire early in this construction — the probe showed this method entered once, from
    /// `showWindow`, with a real view tree. That is a fact about today's construction, not a
    /// guarantee, which is why the warning stays.)
    /// Tests only: the visible frame the first-open rule sizes against, in place of the window's
    /// own screen — so a test can open a document "on" a screen of another size.
    var firstOpenVisibleFrameOverride: NSRect?

    /// Jon's first-open rule (#271 M3), as arithmetic. The page is zoomed to fit whole inside the
    /// screen's visible frame — from the bottom of the menu bar to the top of the Dock
    /// (`visibleFrame`), less the title bar and the bottom bar — never above 100% (Actual Size),
    /// portrait or landscape alike.
    ///
    /// Batch 40 (M13, Jon: "The Landscape window is opening too big all around. I'm seeing the gray
    /// background. I want it to be exactly the same size as the page. Just like in Portrait."): the
    /// window is exactly the fitted page, plus the title bar and the bottom bar, in both directions —
    /// never larger than the visible frame, and centred in it. A page the visible height limits (a
    /// portrait Letter page on a laptop) still spans that height, as before; one that Actual Size or
    /// the width limits (landscape) gets a window no taller than itself, where M3's window spanned the
    /// whole height and showed grey above and below the page.
    static func firstOpenLayout(page: CGSize, visible: NSRect, titleBarHeight: CGFloat,
                                barHeight: CGFloat, actualScale: CGFloat) -> (frame: NSRect, scale: CGFloat) {
        let pageAreaHeight = visible.height - titleBarHeight - barHeight
        let scale = max(0.05, min(actualScale, pageAreaHeight / page.height, visible.width / page.width))
        let width = min(visible.width, (page.width * scale).rounded())
        let height = min(visible.height, (page.height * scale).rounded() + titleBarHeight + barHeight)
        let frame = NSRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                           width: width, height: height)
        return (frame, scale)
    }

    private func applyFirstOpenGeometry() {
        guard !hasAppliedFirstOpenGeometry, let window else { return }
        let page = currentPageSize()
        // Nothing to size against yet — a progressive load with no page and no named size to stand in for
        // it: the rule runs once the content is on screen (`contentDidAppear`).
        guard page.width > 0, page.height > 0 else { return }
        hasAppliedFirstOpenGeometry = true
        firstOpenPageSize = page

        let screen = window.screen ?? NSScreen.main
        let visible = firstOpenVisibleFrameOverride
            ?? screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Sized to the fitted page's width. Legacy scrollers will take their thickness out of
        // the clip view, but WHICH style is in force cannot be predicted here: macOS switches
        // between overlay and legacy depending on whether a mouse is in use, and it can change
        // between this method and the first layout pass. `snapToViewport()` measures the
        // shortfall after layout instead.
        let layout = Self.firstOpenLayout(page: page, visible: visible,
                                          titleBarHeight: titleBarHeight(of: window),
                                          barHeight: BottomBar.barHeight,
                                          actualScale: currentActualScale)
        firstOpenScale = layout.scale
        if documentState.style.value == .printed {
            pdfView.scaleFactor = layout.scale
        } else {
            scrollView.magnification = layout.scale
        }
        window.setFrame(layout.frame, display: false)
    }

    /// Grow the window by whatever the scrollers actually took.
    ///
    /// Called once, after the first layout pass, when the real viewport exists. Legacy
    /// scrollers eat their thickness out of the clip view and overlay ones eat nothing —
    /// and the style can change between sizing the window and laying it out, so the only
    /// reliable figure is the one measured here. Whatever is missing gets added to the
    /// window, which is what makes "the page fills it exactly, no scrollbars" true under
    /// either style instead of under the one that happened to be set a moment ago.
    private func snapToViewport() {
        guard !hasSnappedToViewport, let window else { return }
        let page = currentPageSize()
        guard page.width > 0, page.height > 0 else { return }

        let wanted = NSSize(width: page.width * firstOpenScale,
                            height: page.height * firstOpenScale)
        let viewport = currentViewportSize()
        // Sub-point differences are rounding, not scrollers. Batch 40 (M13): the height is grown too, now that a window
        // is only as tall as its page — but never past the visible frame, which already holds the fitted page whole.
        let visible = firstOpenVisibleFrameOverride ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let shortfallX = wanted.width - viewport.width
        let roomY = visible.map { $0.height - window.frame.height } ?? 0
        let shortfallY = min(wanted.height - viewport.height, max(roomY, 0))
        hasSnappedToViewport = true
        guard shortfallX > 0.5 || shortfallY > 0.5 else { return }

        var frame = window.frame
        if shortfallX > 0.5 {
            frame.size.width += shortfallX
            frame.origin.x -= (shortfallX / 2).rounded()
        }
        if shortfallY > 0.5 {
            frame.size.height += shortfallY
            frame.origin.y -= (shortfallY / 2).rounded()
            if let visible { frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height) }
        }
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The scroller style flipped under us. The window keeps the size the user (or the
    /// first-open rule) gave it; what has to change is the fit, because the viewport just
    /// grew or shrank by the scroller thickness without any resize notification firing.
    @objc private func scrollerStyleChanged() {
        window?.contentView?.layoutSubtreeIfNeeded()
        snapToViewport()
        applyZoom()
    }

    /// Job 454 (PART B): `pdfView`'s own notification that its current page moved — see the
    /// registration in `buildContent()` for why this, and not a direct call from
    /// `goToPage(index:)`, is the source of truth for Printed's page indicator.
    @objc private func pdfViewPageChanged() {
        refreshPageIndicator()
    }

    private func titleBarHeight(of window: NSWindow) -> CGFloat {
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        return max(0, frame.height - content.height)
    }

    // MARK: - Zoom

    /// `reapplying`: the second pass Fit makes when applying the first changed the viewport (below).
    private func applyZoom(reapplying: Bool = false) {
        let zoomToken = PerformanceSignposts.begin("zoom.apply")
        defer { PerformanceSignposts.end(zoomToken) }
        let page = currentPageSize()
        guard page.width > 0, page.height > 0 else { return }

        // The clip view's FRAME, not its BOUNDS (Native/Modern) — see the long-standing note
        // this replaced, still true for `scrollView`: on a magnified scroll view the clip
        // view's BOUNDS are already divided by the current magnification, so computing a
        // scale from them feeds the magnification back into the value that sets it.
        // `currentViewportSize()` reads the FRAME for `scrollView` and `pdfView.bounds` for
        // Printed — `PDFView` has no separate magnified/unmagnified coordinate split the way
        // `NSScrollView`'s clip view does, so its own `bounds` is always the true viewport.
        let available = currentViewportSize()
        // Before the first layout pass the viewport is 0x0 and there is no fit to compute.
        // Declining is correct: the layout pass will ask again. This method really is
        // reached that early — `buildContent()` ends in `reloadContent()` — and it computed
        // a scale of 0 there, which only escaped notice because NSScrollView clamps an
        // assignment into [minMagnification, maxMagnification] and turned it into 0.25.
        guard available.width > 0, available.height > 0 else { return }

        // "Fit" means the whole page, both dimensions — not fit-width, which would cut the
        // bottom off and is the wrong default for a viewer whose users are reading pages.
        let fitScale = min(available.width / page.width, available.height / page.height)
        // The window's CURRENT screen, not `NSScreen.main` — a window dragged to a second
        // display must render Actual Size against the display it is actually on.
        let actualScale = currentActualScale
        // Fit never goes above Actual Size on the Mac (#271 M3: "never above 100% on large
        // screens"). The shared `ZoomSetting.fit` stays uncapped: the iPhone's fit-width zooms in
        // past 1 when rotated, by Jon's own rule there.
        let zoom = documentState.zoom.value
        let scale = zoom == .fit
            ? min(fitScale, actualScale)
            : zoom.scale(fitScale: fitScale, actualScale: actualScale)
        // A non-finite magnification puts a NaN into the layer transform. Refusing is the
        // only safe response; there is no sensible value to fall back to.
        guard scale.isFinite, scale > 0 else { return }
        if documentState.style.value == .printed {
            pdfView.scaleFactor = scale
        } else {
            scrollView.magnification = scale
            // Fit worked out against a viewport a scroller was taking room from stays short once that scroller hides.
            // Measured: shrinking the window from its large first-open zoom, `windowDidResize` reached here while the
            // legacy horizontal scroller still took 15pt. At the new scale the page fitted, the scroller auto-hid, the
            // viewport grew 15pt, and the page stayed 15pt smaller than Fit (0.5189 against 0.5379 at 600x450).
            // So once the scale is applied the scroll view tiles again, and if the viewport moved, Fit is worked out
            // once more against the one that is really there. One extra pass is enough: a scroller that hid at this
            // scale is not needed at a scale worked out without it.
            if zoom == .fit, !reapplying {
                scrollView.tile()
                let settled = currentViewportSize()
                if abs(settled.width - available.width) > 0.5 || abs(settled.height - available.height) > 0.5 {
                    applyZoom(reapplying: true)
                }
            }
        }
    }

    // MARK: - Printing

    /// Print what you see. The paged view already IS the pages at paper size, so the print
    /// operation renders it directly rather than building a second layout that could
    /// disagree with the screen. Printed (job 265) already has a real `PDFDocument` loaded —
    /// `PDFKit`'s own `printOperation(for:scalingMode:autoRotate:)` prints those exact bytes,
    /// no AppKit re-layout involved at all.
    func makePrintOperation(settings: [NSPrintInfo.AttributeKey: Any]) -> NSPrintOperation {
        if documentState.style.value == .printed {
            let info = NSPrintInfo(dictionary: settings)
            if let document = pdfView.document,
               let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) {
                return operation
            }
            return NSPrintOperation(view: pdfView, printInfo: info)
        }

        let rendered = DocumentRenderer.render(documentState, style: documentState.style.value.renderStyle)
        let info = NSPrintInfo(dictionary: settings)
        info.paperSize = rendered.pageSize
        info.topMargin = 0; info.bottomMargin = 0
        info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        // A print-only view: every page laid out continuously at 100%, whatever the window
        // is currently showing. Printing a document should not depend on which page happens
        // to be on screen.
        let printView = PagedDocumentView()
        printView.setContent(rendered, display: .continuousScroll)
        printView.frame = CGRect(
            origin: .zero,
            size: NSSize(width: rendered.pageSize.width,
                         height: printView.intrinsicContentSize.height)
        )
        return NSPrintOperation(view: printView, printInfo: info)
    }
}

// MARK: - Window lifecycle

extension DocumentWindowController: NSWindowDelegate {
    override func windowDidLoad() {
        super.windowDidLoad()
        applyFirstOpenGeometry()
    }

    override func showWindow(_ sender: Any?) {
        let showToken = PerformanceSignposts.begin("open.showWindow")
        defer { PerformanceSignposts.end(showToken) }
        applyFirstOpenGeometry()
        super.showWindow(sender)
        // The proxy icon and the filename come from the URL — the system draws both, which
        // is the spec's requirement (never our own icon).
        window?.representedURL = document?.fileURL
        if let name = (document as? NSDocument)?.displayName { window?.title = name }

        // The window is on screen now, so the scroll view has a real frame for the first
        // time. `applyFirstOpenGeometry` predicted the scale arithmetically; this settles it
        // against the viewport that actually exists, which is what makes "no scrollbars on
        // first open" true rather than approximately true.
        window?.contentView?.layoutSubtreeIfNeeded()
        applyZoom()
    }

    // MARK: - Window state restoration

    /// Standard AppKit state restoration: reopening the last-open documents and their window
    /// frames is `NSDocumentController`'s own doing once `applicationSupportsSecureRestorableState`
    /// answers true (see `AppDelegate`) — nothing here has to ask for that half. This is the
    /// EXTRA per-window view state the spec asks for on top of it: style, zoom, display,
    /// variant and page size selections, and scroll position. One JSON blob, gated by the
    /// preference — off means this writes nothing, so nothing comes back at the next launch.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard settings.restoreWindowsOnLaunch else { return }
        let restorable = WindowRestorableState(
            documentState: documentState,
            scrollOrigin: scrollView.contentView.bounds.origin,
            showDocumentInfo: documentInfoWindowController?.window?.isVisible == true
        )
        WindowRestorationCoding.encode(restorable, into: state)
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        guard settings.restoreWindowsOnLaunch,
              let restorable = WindowRestorationCoding.decode(from: state)
        else { return }
        restorable.apply(to: documentState)
        invalidateRenderedContent()
        reloadContent()
        window.contentView?.layoutSubtreeIfNeeded()
        // Applied last: `reloadContent()` calls `applyZoom()`, which can itself move the
        // scroll position, so the restored position has to win by going on after it.
        scrollView.contentView.scroll(to: NSPoint(x: restorable.scrollX, y: restorable.scrollY))
        if restorable.showDocumentInfo {
            let inspector = documentInfoWindowControllerCreatingIfNeeded()
            inspector.refresh(from: self)
            inspector.showWindow(nil)
        }
    }

    /// The Inspector is this window's own — closing the document must not leave it floating
    /// with nothing left to describe.
    func windowWillClose(_ notification: Notification) {
        documentInfoWindowController?.close()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    func windowDidResize(_ notification: Notification) {
        // Fit has to stay fit across a resize, which is the reason zoom is a named state
        // rather than a frozen percentage.
        //
        // "Fit does not fit" (Jon's baseline finding: the page sat at 612pt regardless of
        // window size) traced to this method reading `scrollView.contentView.frame` before
        // AutoLayout had actually resized it. A window's constraint-based layout is not
        // guaranteed to have run by the time `windowDidResize` fires — `scrollerStyleChanged`
        // below already knew this and called `layoutSubtreeIfNeeded()` first; this method
        // read the stale, pre-resize viewport and computed `fitScale` from it, so Fit locked
        // onto whatever the viewport happened to be at the FIRST resize and never moved
        // again. Forcing layout first is what makes `applyZoom()`'s viewport real.
        guard documentState.zoom.value == .fit else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        applyZoom()
    }

    /// The window moved to a different display (dragged across, or the display arrangement
    /// changed under it). Actual Size is a function of the CURRENT screen's physical points
    /// per inch, so a screen change can move its magnification even though nothing about the
    /// document or the window's own size changed.
    func windowDidChangeScreen(_ notification: Notification) {
        guard documentState.zoom.value == .actual else { return }
        applyZoom()
    }
}

// MARK: - Bottom bar

extension DocumentWindowController: BottomBarDelegate {
    // Every one of these is the SAME action path a menu equivalent uses (`setVariant` is
    // also Edit ▸ Change Variant's; `setStyle`/`setZoom` are also View's) — see "Commands"
    // above. A popup and its menu equivalent choosing the same value must produce identical
    // results, and duplicating the logic here is exactly how they used to drift apart.
    func bottomBarDidChooseVariant(_ variant: Variant?) { setVariant(variant) }
    func bottomBarDidChooseStyle(_ style: ViewStyle) { setStyle(style) }
    func bottomBarDidChooseZoom(_ zoom: ZoomSetting) { setZoom(zoom) }
    func bottomBarDidChoosePageSize(_ size: NamedPageSize) { setPageSize(size) }
    func bottomBarDidChoosePageSettings(_ preset: DocumentOperations.PageSettingsPreset?) {
        setPageSettingsPreset(preset)
    }
}

/// Batch 26 (#271 M7): work finished off the main thread comes back through the main RUN LOOP, in its
/// default mode — not `await MainActor.run`, and not `DispatchQueue.main.async`. Both of those enqueue on
/// the main dispatch queue, which cannot run while another main-queue block is running, so a caller that
/// turns the run loop from inside one (a `@MainActor` test waiting on a window) never saw a background
/// parse finish (b26-holymac-fix1: every wait ran to its limit). A run-loop block runs on the next turn of
/// the loop however the loop is being turned, and — like a progressive load's own slices — waits while a
/// scroll or a resize is being tracked.
enum MainRunLoop {
    /// `body` on the main thread, on a coming turn of its run loop. Callable from any thread.
    nonisolated static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(loop)
    }
}
