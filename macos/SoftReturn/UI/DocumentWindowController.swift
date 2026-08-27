import AppKit
import CtrlKD
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
    /// The scale the first-open rule chose, kept so `snapToViewport()` knows what size the
    /// page is meant to be on screen once the real viewport is known.
    private var firstOpenScale: CGFloat = 1
    private var hasSnappedToViewport = false
    /// How this window turns its current screen into the "Actual Size" magnification factor.
    /// A stored closure rather than a hardwired `DisplayPhysicalMetrics.live(for:)` call —
    /// injectable so a test can pin known, synthetic display metrics instead of depending on
    /// whatever real screen the test happens to run against.
    private let actualSizeMetrics: (NSScreen) -> DisplayPhysicalMetrics?

    init(state: DocumentState, settings: SettingsStore = .shared,
         actualSizeMetrics: @escaping (NSScreen) -> DisplayPhysicalMetrics? = DisplayPhysicalMetrics.live) {
        self.documentState = state
        self.settings = settings
        self.actualSizeMetrics = actualSizeMetrics
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
        window.delegate = self
        buildContent()
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
        pagedView.pageDidChange = { [weak self] _ in
            guard let self else { return }
            self.bottomBar.update(from: self.documentState)
            self.refreshPageIndicator()
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

        content.addSubview(scrollView)
        content.addSubview(pdfView)
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

    private func loadPagedContent() {
        let renderStyle = documentState.style.value.renderStyle
        // Job 294: Modern shows invisibles too now, not just Native — `renderWithInvisibles`
        // itself picks the right annotated pass per style (`renderPrintedAnnotated` vs
        // `renderModernAnnotated`); Printed never reaches here (`reloadContent` routes it to
        // `pdfView` instead).
        let rendered = (documentState.style.value != .printed && documentState.showInvisibles)
            ? DocumentRenderer.renderWithInvisibles(documentState)
            : DocumentRenderer.render(documentState, style: renderStyle)
        pagedView.setContent(rendered, display: documentState.display.value)
    }

    /// The engine's own PDF, not `DocumentRenderer` at all — `emitPDF(doc, mode: .printed)`
    /// is literally what `sr --mode printed` writes, so this view is byte-identical to the
    /// CLI by construction, never a second AppKit approximation of it. Page settings flow
    /// through the SAME `EmitOptions.pageSettings` channel `ExportEngine`'s Printed-mode PDF
    /// export and `DocumentRenderer.renderPrinted`'s screen path both already use — a preset
    /// chosen in the footer can never disagree with what this view shows.
    private func loadPrintedPDFContent() {
        // Job 371 item 1 (PIX IN VIEWS): `documentState.pixResults` was already resolved once
        // against the document's own real path at open/reparse time — reused here rather than
        // re-resolved, same "decode once per document" contract every other pix consumer keeps.
        let options = EmitOptions(
            pageSettings: documentState.pageSettingsPreset.value?.settings,
            pixResults: documentState.pixResults)
        let bytes = emitPDF(documentState.document, mode: .printed, options: options)
        pdfView.document = PDFDocument(data: Data(bytes))
        pdfView.displayMode = documentState.display.value == .continuousScroll
            ? .singlePageContinuous : .singlePage
    }

    // MARK: - Commands (driven by the menu extension)

    /// Re-render after a state change the menu made.
    func rerender() { reloadContent() }

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
        reloadContent()
    }

    func setPageSettingsPreset(_ preset: DocumentOperations.PageSettingsPreset?) {
        documentState.setPageSettingsPreset(preset)
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
    private func currentPageSize() -> CGSize {
        if documentState.style.value == .printed {
            return pdfView.document?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        }
        return DocumentRenderer.render(documentState, style: documentState.style.value.renderStyle).pageSize
    }

    /// The viewport the current content view actually has to draw into — `scrollView`'s clip
    /// view for Native/Modern, `pdfView`'s own bounds for Printed (it manages its own
    /// scrolling internally, so its bounds ARE its viewport, the same role the clip view
    /// plays for `scrollView`).
    private func currentViewportSize() -> CGSize {
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
    private func applyFirstOpenGeometry() {
        guard !hasAppliedFirstOpenGeometry, let window else { return }
        hasAppliedFirstOpenGeometry = true

        let page = currentPageSize()
        guard page.width > 0, page.height > 0 else { return }

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Leave the page room to breathe on screen without ever exceeding it. The bottom
        // bar and title bar are chrome the page does not have to share.
        let chromeHeight = BottomBar.barHeight + titleBarHeight(of: window)
        let maxPageHeight = visible.height * 0.92 - chromeHeight
        let maxPageWidth = visible.width * 0.92

        let scale = min(1.0, min(maxPageHeight / page.height, maxPageWidth / page.width))
        // Sized to the page. Legacy scrollers will take their thickness out of the clip
        // view, but WHICH style is in force cannot be predicted here: macOS switches between
        // overlay and legacy depending on whether a mouse is in use, and it can change
        // between this method and the first layout pass. Guessing the thickness here was a
        // real bug — the window came out 15pt wrong whenever the guess and the layout
        // disagreed. `snapToViewport()` measures the shortfall after layout instead.
        let contentSize = NSSize(
            width: (page.width * scale).rounded(),
            height: (page.height * scale).rounded() + BottomBar.barHeight
        )

        firstOpenScale = scale
        if documentState.style.value == .printed {
            pdfView.scaleFactor = scale
        } else {
            scrollView.magnification = scale
        }
        window.setContentSize(contentSize)
        window.center()
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
        let shortfallX = wanted.width - viewport.width
        let shortfallY = wanted.height - viewport.height
        // Sub-point differences are rounding, not scrollers.
        guard shortfallX > 0.5 || shortfallY > 0.5 else {
            hasSnappedToViewport = true
            return
        }
        hasSnappedToViewport = true

        let content = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: content.width + max(0, shortfallX),
                                     height: content.height + max(0, shortfallY)))
        window.center()
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

    private func applyZoom() {
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
        let scale = documentState.zoom.value.scale(fitScale: fitScale, actualScale: actualScale)
        // A non-finite magnification puts a NaN into the layer transform. Refusing is the
        // only safe response; there is no sensible value to fall back to.
        guard scale.isFinite, scale > 0 else { return }
        if documentState.style.value == .printed {
            pdfView.scaleFactor = scale
        } else {
            scrollView.magnification = scale
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
