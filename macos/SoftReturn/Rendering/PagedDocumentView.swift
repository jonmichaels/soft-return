import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

/// The pages of one document, stacked, inside a scroll view that supplies zoom.
///
/// One `NSTextStorage` and one `NSLayoutManager` for the whole document, with one
/// `NSTextContainer` — and one `NSTextView` — per page. See `RenderedDocument` for why
/// that arrangement rather than a view per page holding its own text: it is what makes
/// selection, Find, Speech and VoiceOver work ACROSS pages instead of stopping at each
/// page's edge, and all four are [SYS] requirements the app is forbidden to reimplement.
///
/// Zoom is `NSScrollView.magnification`, not a transform we apply ourselves — that keeps
/// pinch-to-zoom, the scroll wheel, and Zoom In/Out on one mechanism, and it is why the
/// page views below are always laid out at 100% and never resized by the zoom control.
final class PagedDocumentView: NSView {
    /// Gap between pages in continuous scroll, and the margin around a single page. Only
    /// ever visible once the user has zoomed or resized — first open fills the window
    /// exactly, per the spec's geometry rule. Batch 40 (M10): the one number for the gap, in page
    /// points (so it shrinks and grows with the zoom). Batch 41: 10, Preview's own spacing between
    /// pages (Jon, from a Preview screenshot: "The gap is small but not 0"); it was 20.
    static let pageGap: CGFloat = 10

    /// Continuous Scroll only: local page `index`'s own cumulative top, `pageGap` plus
    /// every earlier page's own `pageSize.height` plus every page THROUGH `index`'s own
    /// `headroom(atPage:)` (job 396) — rebuilt once per `setContent` (`rebuildPageTops`),
    /// not recomputed per call, since an export/print loop asks `rect(ofPage:)` once per
    /// page and an O(n) rebuild each time would make that loop O(n²) on a long document.
    /// Single Page never consults this: only one page is ever laid out at a time there
    /// (`layout()`'s own `.singlePage` case applies `headroom(atPage:currentPageIndex)`
    /// directly), so no cumulative table is needed.
    var pageTops: [CGFloat] = []

    /// WHICH PAGE A `dataWithPDF(inside:)` CAPTURE IS ASKING FOR, or `nil` on screen.
    ///
    /// This view's own `draw(_:)` needs nothing from it — measured: a capture is NOT re-based
    /// for the parent, so drawing every page's furniture at document coordinates is correct
    /// there and always was. The OVERLAY subview is the problem. Its frame spans the whole
    /// document, so its drawing is not re-based either, and it walks EVERY page: page one's
    /// oversized title is painted into page two's and page three's captures, at document
    /// coordinates that land above their own sheets.
    ///
    /// Measured on DARKNESS.WS, page-local y read back out of the app's own exported PDF:
    /// its running head landed at -764.0 on page 2 and -1576.0 on page 3 — 48.0 less one
    /// page height plus the gap, and less two of them — while the engine's own PDF has it at
    /// 48.0. Off the top of its own sheet, so invisible to anyone looking at the export,
    /// which is why it stood.
    ///
    /// A capture states its page rather than being guessed at. Set around each capture by
    /// `PageCapture.swift`, which every export, Quick Look and batch-preview capture goes through.
    ///
    /// Workaround, kept (reviewed 2026-10-26, macOS 26.7): `dataWithPDF(inside:)` still draws subviews at document
    /// coordinates without re-basing; re-test if a capture API that draws one page alone is used instead.
    var capturingPageIndex: Int? {
        didSet {
            // Batch 40 (M10): the page a capture asks for is shown, wherever the scroll is.
            if let capturingPageIndex { setPagesShown(near: rect(ofPage: capturingPageIndex), hidingTheRest: false) }
        }
    }

    /// Job 396 (391 root cause 5): extra blank canvas `RenderedDocument.leadingHeadroom`
    /// says local page `index` needs ABOVE its own nominal top, or `0` when `rendered` is
    /// nil, `index` is out of range, or that page's own first line isn't an oversized
    /// title that needs one. See `RenderedDocument.leadingHeadroom`'s own doc comment for
    /// how the figure is measured, and `rebuildPageTops`/`layout()`/`draw(_:)` below for
    /// how it is spent — always as bonus canvas space ABOVE a page's existing geometry,
    /// never as a change to where a glyph's own baseline sits.
    func headroom(atPage index: Int) -> CGFloat {
        guard let rendered, rendered.leadingHeadroom.indices.contains(index) else { return 0 }
        return rendered.leadingHeadroom[index]
    }

    /// Job 427 (Jon's ruling: "Native only changes fonts. Otherwise it's the same as
    /// Printed."): local page `index`'s own text-container top-edge distance from the
    /// paper's top — `RenderedDocument.perPageTextTop[index]` when that page has its own
    /// entry, else `rendered.textFrame.origin.y` (every non-Printed render path's flat,
    /// shared anchor, and Printed's own fallback for an index the per-page array somehow
    /// doesn't cover — defensive only, `renderNative` always sizes the array to
    /// `pages.count`). Replaces the single shared `rendered.textFrame.origin.y` every call
    /// site below used before this job — see `RenderedDocument.perPageTextTop`'s own doc
    /// comment for why a single shared anchor could not represent a page whose own `.mt`/
    /// `.mb` differs from the document's global pair.
    func textTop(atPage index: Int) -> CGFloat {
        guard let rendered else { return 0 }
        guard rendered.perPageTextTop.indices.contains(index) else { return rendered.textFrame.origin.y }
        return CGFloat(rendered.perPageTextTop[index])
    }

    /// Job 428 (job 426 item 3's own scoped diagnosis, closing it): local page `index`'s
    /// own REAL text-container height — `containers[index].size.height` (the exact figure
    /// `buildExplicitPages` already computed per-page, from `pinnedPageBottoms`) — instead
    /// of the single flat `rendered.textFrame.size.height` every `layout()` call site used
    /// before this job. `containers` and `pageViews` are always built together (`setContent`
    /// appends one of each per real page, `buildExplicitPages`), so the indices agree by
    /// construction; the flat fallback stays for defensive-only cases (nothing rendered yet).
    ///
    /// Why this matters: `layout()` positions the `NSTextView`'s own FRAME, a DIFFERENT
    /// quantity from its `NSTextContainer`'s size — sizing the frame smaller than the real
    /// container clips whatever the container laid out past that frame edge. On-screen and
    /// in `PixelOracleAppEngineTests`' own `cacheDisplay`-based capture this went unnoticed
    /// (layer-composited drawing tolerates content painted past a view's own nominal frame —
    /// this codebase's own `oversizedSelfPasses` overlay already relies on exactly that kind
    /// of controlled bleed elsewhere), but `QuickLookNativeRenderer.multiPagePDF`'s
    /// `dataWithPDF(inside:)` (a vector/print-imaging path) clips a subview strictly to its
    /// own frame bounds — SCRIPT.WS page 10's own real content needs a container ~147pt
    /// taller than the flat frame provided, and QuickLook's PDF silently dropped the
    /// overflow (`QLCLIByteParityTests` job 426's own diagnosis, `missingInActual`).
    /// How tall page `index`'s own text area is — the TALLEST of its columns.
    ///
    /// `containers[index]` was right while there was exactly one container per page and
    /// became a straight index error when item 19 gave every COLUMN its own
    /// (`containerPage` is the map). On a columnar document every page from the first
    /// multi-column one onward took some other page's column's height: MICKEE.WS page 16
    /// was framed 423.5pt tall — a height belonging to `containers[16]`, which by then was
    /// page 9's second column — against its own columns' 555.5 and 579.5.
    ///
    /// That is a frame, and a text view CLIPS to its frame, so the bottom of the page simply
    /// did not export. `syncColumnViews` hands every one of a page's columns this same
    /// frame, so both halves of MICKEE's page 16 lost their tails: the app's own PDF ended
    /// that page at "shows a single entire page, unless you are already" where the library's
    /// carries eleven more lines. PRINT.TST page 2 is the same story at 383.5 against 613.5.
    ///
    /// The MAXIMUM rather than column 0's, because that one frame has to hold every column
    /// on the page, and a later column is routinely the longer one (MICKEE's 48 against 46).
    func textHeight(atPage index: Int) -> CGFloat {
        guard let rendered else { return 0 }
        let own = containerPage.indices.filter {
            containerPage[$0] == index && containers.indices.contains($0)
        }
        if let tallest = own.map({ containers[$0].size.height }).max() { return tallest }
        guard containers.indices.contains(index) else { return rendered.textFrame.size.height }
        return containers[index].size.height
    }

    /// Rebuilds `pageTops` for Continuous Scroll — called once per `setContent`, after
    /// `pageViews`/`rendered` are both current. `y` accumulates: `pageGap` before every
    /// page but the first, then THIS page's own `headroom`, then its own `pageSize.height`
    /// — so `pageTops[index]` lands exactly where local page `index`'s own text container
    /// sits (`layout()`'s `.continuousScroll` case adds only `text.origin.y` to it, same
    /// as before this job), while the space `rect(ofPage:)`/`rectForPage`/`draw(_:)` grow
    /// into for the bleed is `pageTops[index] - headroom(atPage: index)` through
    /// `pageTops[index]` — reserved here, not overlapping the page before it.
    func rebuildPageTops() {
        guard let rendered else { pageTops = []; return }
        var tops: [CGFloat] = []
        tops.reserveCapacity(pageViews.count)
        var y: CGFloat = 0
        for index in pageViews.indices {
            if index > 0 { y += Self.pageGap }
            y += headroom(atPage: index)
            tops.append(y)
            // Batch 47 (M31-app): each page's own sheet.
            y += rendered.pageSize(atPage: index).height
        }
        pageTops = tops
    }

    private var storage = NSTextStorage()
    // Batch 41 (columns): read-only outside, as the iPhone's `PageLayout` holds its own — a test that asks where a
    // column's glyphs really ended needs the manager that laid them.
    private(set) var layoutManager = softReturnLayoutManager()
    var containers: [NSTextContainer] = []
    /// Which page and which of its columns each container in `containers` belongs to — item
    /// 19. The layout delegate matches a fragment's own `PinnedBaseline.page`/`.column`
    /// against these to know whether the container it is being asked to lay into is the one
    /// that fragment belongs in.
    // Batch 41 (columns): read-only outside, as the iPhone's `PageLayout` already declares its own three — a test
    // that holds the view's columns to the engine's ranges has to see where each container really ended.
    var containerPage: [Int] = []
    var containerColumn: [Int] = []
    /// Per page, the text views for its SECOND and later columns — `pageViews` keeps the
    /// first, so every page-indexed thing in this file still means what it did.
    var columnViews: [[NSTextView]] = []
    /// Batch 41 (columns): which column each of `columnViews[page]` holds, in the same order. Native's later columns
    /// are simply 1, 2, …; a Modern page the engine partitions can skip one it left empty, and a view's own x depends
    /// on the real column, not its ordinal.
    var columnViewColumns: [[Int]] = []
    /// Job 412: `true` only while `buildExplicitPages`'s own throwaway, whole-document probe
    /// container is attached — see that call site's own doc comment for why the
    /// `NSLayoutManagerDelegate` conformance below must stay a no-op there.
    var isMeasuringProbeContainer = false
    var pageViews: [NSTextView] = []
    /// Job 227: draws `RenderedDocument.oversizedSelfPasses` — see `drawOversizedSelfPasses`'s
    /// own doc comment for why this needs a dedicated subview ABOVE every `PageTextView`
    /// rather than either this view's own background `draw(_:)` (subviews always composite
    /// on top of it, oversized content or not) or `PageTextView` itself (its own bounds are
    /// exactly the box the oversized glyph doesn't fit in). Re-added (moving it to the end
    /// of the subview list, i.e. topmost) at the end of every `setContent`, since `pageViews`
    /// are torn down and rebuilt there.
    let overlayView = OversizedPassOverlayView()

    var rendered: RenderedDocument?
    var display: PageDisplay = .singlePage
    /// Which page is showing in Single Page mode. Ignored in Continuous Scroll.
    private(set) var currentPageIndex = 0

    /// The first text view, which owns the selection and is what Find and Speech attach
    /// to. All page views share one layout manager, so any of them can answer for the
    /// document; the first is simply a stable choice.
    var primaryTextView: NSTextView? { pageViews.first }

    /// A11Y AUDIT FIX (parent/child mismatch, finding 1 of 2): this view sits between the
    /// scroll view's own accessible `.scrollArea` and each page's `.textArea` with no role
    /// of its own — an untyped node hosting typed children is exactly the shape the audit's
    /// parent/child check flags. `.group` names what it actually is: the pages, plural, not
    /// one document view standing in for the whole window.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document pages")
        overlayView.owner = self
        addSubview(overlayView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Drawing stays inside this view. Since macOS 14 that is not the default, and a view
    /// that paints outside itself is how the blank document window happened.
    override var clipsToBounds: Bool {
        get { true }
        set { _ = newValue }
    }

    // MARK: - Batch 40 (M10): Continuous Scroll shows only the pages near the screen

    /// How far above and below the visible rect, in screens, page views stay shown in Continuous Scroll.
    ///
    /// b40-m10-diag: one view of -HOLYMAC.WS (302 pages) drew in 248.9 ms, and in 4.07 ms with the 300 page text views
    /// off the screen hidden. AppKit visits every shown subview on every draw — about 0.8 ms each there, whatever it
    /// ends up drawing — while the pages view's own drawing took 0.43 ms and the two text views on screen 2.28 ms. So
    /// a page far from the screen is hidden and shown again before a scroll reaches it: the clip view reports each
    /// bounds change as it happens, and two screens either side keep a fast scroll's next strip shown already.
    static let pagesShownAroundTheScreen: CGFloat = 2

    private weak var followedClipView: NSClipView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        followClipView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followClipView()
        showOnlyPagesNearTheScreen()
    }

    private func followClipView() {
        let clip = enclosingScrollView?.contentView
        guard clip !== followedClipView else { return }
        if let followedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: followedClipView)
        }
        followedClipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        showOnlyPagesNearTheScreen()
    }

    /// Continuous Scroll in a window's scroll view: the pages within `pagesShownAroundTheScreen` screens of the visible
    /// rect shown, the rest hidden. Anywhere else — Single Page, a view outside a window (print, export, Quick Look), a
    /// capture in progress — nothing is hidden here.
    private func showOnlyPagesNearTheScreen() {
        guard display == .continuousScroll, capturingPageIndex == nil, window != nil, enclosingScrollView != nil else { return }
        let visible = visibleRect
        guard !visible.isEmpty else { return }
        let reach = visible.height * Self.pagesShownAroundTheScreen
        setPagesShown(near: visible.insetBy(dx: 0, dy: -reach), hidingTheRest: true)
    }

    /// Shows every page view (and its later columns) whose sheet reaches `region`; with `hidingTheRest`, hides the others.
    private func setPagesShown(near region: NSRect, hidingTheRest: Bool) {
        guard display == .continuousScroll else { return }
        for (index, view) in pageViews.enumerated() where pageTops.indices.contains(index) {
            let near = rect(ofPage: index).intersects(region)
            if near, view.isHidden {
                view.isHidden = false
                syncColumnViews(atPage: index, frame: nil, hidden: false)
            } else if !near, hidingTheRest, !view.isHidden {
                view.isHidden = true
                syncColumnViews(atPage: index, frame: nil, hidden: true)
            }
        }
    }

    // A capture draws what it asks for, wherever the scroll is: the pages it reaches are shown first.
    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        setPagesShown(near: rect, hidingTheRest: false)
        super.cacheDisplay(in: rect, to: bitmapImageRep)
    }

    override func displayIgnoringOpacity(_ rect: NSRect, in context: NSGraphicsContext) {
        setPagesShown(near: rect, hidingTheRest: false)
        super.displayIgnoringOpacity(rect, in: context)
    }

    override func dataWithPDF(inside rect: NSRect) -> Data {
        setPagesShown(near: rect, hidingTheRest: false)
        return super.dataWithPDF(inside: rect)
    }

    override func beginDocument() {
        setPagesShown(near: bounds, hidingTheRest: false)
        super.beginDocument()
    }

    /// Every page stays in the accessibility tree: a page hidden to spare drawing is still part of the document.
    override func accessibilityChildren() -> [Any]? {
        guard display == .continuousScroll, pageViews.contains(where: { $0.isHidden }) else { return super.accessibilityChildren() }
        var children: [Any] = []
        for (index, view) in pageViews.enumerated() {
            children.append(view)
            if columnViews.indices.contains(index) { children.append(contentsOf: columnViews[index] as [Any]) }
        }
        return children
    }

    // MARK: - Content

    /// Replace the displayed document. Rebuilds the container chain, because page size and
    /// line capacity both change with style.
    ///
    /// `firstPages` (batch 26, #271 M7): lay out only that many pages now and leave the rest to
    /// `layOutMorePages(until:)` — a long document's pages built a turn of the run loop at a time
    /// instead of in one block. nil lays out every page, as it always did.
    ///
    /// `probe` (batch 27): the unpinned probe's measurement of `rendered`, made already, offscreen, a slice at a
    /// time (`ProbeMeasurement`) — a render that pins nothing (Show Invisibles) then skips its in-view probe and
    /// lays out a page at a time like a pinned one.
    func setContent(_ rendered: RenderedDocument, display: PageDisplay, firstPages: Int? = nil,
                    probe: ExplicitProbe? = nil) {
        self.rendered = rendered
        self.display = display
        pendingPages = nil
        modernTopRises = [:]

        // Tear down the old chain. Removing the layout manager from the storage first
        // detaches every container and view in one move.
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []
        containers = []
        containerPage = []
        containerColumn = []
        // Batch 40 (M10): a page's later columns are views of their own. Emptying the list alone left every one
        // in the view, at its old frame, on the old layout's containers — ghost text over the new pages after
        // every rebuild of a multi-column document.
        columnViews.joined().forEach { $0.removeFromSuperview() }
        columnViews = []
        columnViewColumns = []
        if let old = storage.layoutManagers.first { storage.removeLayoutManager(old) }

        storage = NSTextStorage(attributedString: rendered.text)
        layoutManager = softReturnLayoutManager()
        // MODERN'S LEADING IS THE LIBRARY'S, AND NOTHING IS ADDED TO IT.
        //
        // `modernParagraphStyle` already pins `minimumLineHeight == maximumLineHeight ==
        // size * 1.2`, which is `PDFModernLayout`'s own `modernLine * pt` exactly — and
        // AppKit then added the FACE's external leading on top of the clamp, because
        // `usesFontLeading` defaults to true. Measured on -README.WS's Modern pages: the
        // library advances 16.80pt line to line at a 14pt body and the app advanced
        // 17.394pt, the difference being Times New Roman's own 0.594pt leading, every line,
        // so the app fitted fewer lines per page and paginated 22 pages against 21.
        //
        // Printed keeps it: its fragments are pinned through the layout-manager delegate
        // rather than by the paragraph clamp alone, and changing what AppKit adds underneath
        // that is a separate question from this one.
        // Batch 40 (M14): not for a Native render nothing pins — Show Invisibles'. There the paragraph's clamp is the
        // whole line height, and the face's leading added on top made every line taller than the lead its page's budget
        // counted, so the text crept down its page and into what the page draws at fixed places.
        layoutManager.usesFontLeading = Self.usesFontLeading(rendered)
        // A viewer never edits, so nothing needs the extra glyph generation that
        // non-contiguous layout trades away — and turning it off makes the page-count loop
        // below exact rather than eventually-consistent.
        layoutManager.allowsNonContiguousLayout = false
        // Job 412 ("pin it"): `self` implements `NSLayoutManagerDelegate` below, overriding
        // AppKit's own proposed fragment position for every fragment `rendered
        // .pinnedBaselines` covers — see that conformance's own doc comment. `weak`
        // (the protocol's own declared property), so this creates no retain cycle; `self`
        // already outlives `layoutManager` (this view owns it), never the reverse.
        layoutManager.delegate = self
        storage.addLayoutManager(layoutManager)

        buildPages(for: rendered, firstPages: firstPages, probe: probe)
        applyPageAccessibilityLabels()
        currentPageIndex = min(currentPageIndex, max(0, pageViews.count - 1))
        // Job 460: `rebuildPageTops()` BEFORE `applyDisplayMode()` — Continuous Scroll's own
        // branch of `applyDisplayMode()` unhides every page view at once, and needs `pageTops`
        // already built to give each one a real frame before it goes visible (see
        // `applyDisplayMode()`'s own job 460 doc comment for why order matters here).
        rebuildPageTops()
        applyDisplayMode()
        sizeToContent()
        // Re-adding an existing subview moves it to the end (topmost) of the subview list —
        // `buildPages`/`buildExplicitPages` just added every `PageTextView` above, so this
        // is what keeps the overlay drawing LAST (on top of all of them) every time.
        addSubview(overlayView)
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
    }

    /// A11Y AUDIT FIX (label not human-readable, finding 1 of 2): every page view carried
    /// `.textArea` as its role but no label at all, so each of several simultaneous
    /// `.textArea` elements (Continuous Scroll shows every page at once) was
    /// indistinguishable from the others to VoiceOver. "Page N of M" is what a sighted
    /// reader already sees from the page's own edges.
    func applyPageAccessibilityLabels(from start: Int = 0) {
        let total = pageViews.count
        for (index, view) in pageViews.enumerated().dropFirst(start) {
            view.setAccessibilityLabel("Page \(index + 1) of \(total)")
        }
    }

    /// Set our own frame from the page geometry.
    ///
    /// REQUIRED, not a nicety: as an `NSScrollView`'s `documentView` this view is positioned
    /// by frame, and a scroll view does not consult `intrinsicContentSize` unless the
    /// document view is driven by constraints. Without this the view stays at its initial
    /// zero frame and has nothing to draw into.
    ///
    /// This comment used to claim the zero frame was the cause of the blank document window.
    /// That was WRONG, and it cost three sessions of looking in the wrong place. The blank
    /// window was `BottomBar` painting its background over the whole window (it filled
    /// `dirtyRect`, and since macOS 14 views are not clipped to their bounds by default).
    /// The page drew correctly throughout. Setting the frame here is still necessary — it
    /// just never was the bug.
    private func sizeToContent() {
        invalidateIntrinsicContentSize()
        let size = intrinsicContentSize
        if frame.size != size {
            setFrameSize(size)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Build the container chain for `rendered`. Native style places each `docToPagelines`
    /// page in its own EXPLICITLY sized container (`buildExplicitPages`); Modern style has
    /// no library pagination to honour, so AppKit grows the chain and reflows on its own —
    /// the only way to learn ITS page count is to lay out and ask.
    /// The character offset the container AFTER `container` will begin at — one past the
    /// last character this one actually placed. `nil` once the document is exhausted, so the
    /// caller stops rather than collapsing a blank nothing will ever open on.
    func nextContainerStart(for container: NSTextContainer) -> Int? {
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let next = chars.location + chars.length
        return next < storage.length ? next : nil
    }

    /// Gives one recorded blank line a hairline's height, so the page it would have opened
    /// spends nothing on it. A paragraph style is copied and re-set rather than mutated in
    /// place: `NSAttributedString` copies the value at set-time, so mutating the style
    /// object a laid-out run already holds would not invalidate anything.
    func collapseBlankLine(_ range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subrange, _ in
            let style = (value as? NSParagraphStyle).map {
                ($0.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            } ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = 0
            style.minimumLineHeight = 0.01
            style.maximumLineHeight = 0.01
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            self.storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        storage.endEditing()
    }


    var pendingPages: PendingPages?

    /// Batch 40 (M10): the strip the last layout turn marked for display, for the tests — a view outside a window
    /// answers `needsToDraw(_:)` true for every rect, so the mark cannot be read back from AppKit there.
    var lastMarkedForDisplay: NSRect?

    var modernTopRises: [Int: CGFloat] = [:]

    // MARK: - Display mode

    func setDisplay(_ display: PageDisplay) {
        guard display != self.display else { return }
        self.display = display
        applyDisplayMode()
        // Single Page and Continuous Scroll have different heights, so the frame has to
        // move with the mode — same reason as `setContent`.
        sizeToContent()
    }

    /// How many pages this document laid out. The Go menu bounds itself against this.
    var pageCount: Int { pageViews.count }

    /// The page size of the content on screen, once there is some (#271 M7).
    var renderedPageSize: CGSize? { rendered?.pageSize }

    /// Batch 41: each page's running lines as this view draws them. Modern's are resolved here, after its pages are laid,
    /// so they exist only on this view's own copy of the rendered document.
    var drawnRunningLines: [[RunningLine]] { rendered?.runningLines ?? [] }

    /// Item 19: the text views for local page `index`'s SECOND and later newspaper columns,
    /// in column order — empty for every ordinary page. Internal for the same "a test needs
    /// this page's own content directly" reason `runningLines(atPageIndex:)` below is.
    func columnTextViews(atPage index: Int) -> [NSTextView] {
        columnViews.indices.contains(index) ? columnViews[index] : []
    }

    /// The running heads/feet `drawRunningLines` will actually paint for local page `index`
    /// — `internal`, not `private`, purely so tests can assert per-page header/footer content
    /// directly (job 393's `HeadersInViewsTests`) rather than pixel-sampling `cacheDisplay`,
    /// the same "loosen to internal for test access" convention this codebase already uses
    /// elsewhere (`invisibleMarkColour`, `attributedLine`'s own doc comments).
    func runningLines(atPageIndex index: Int) -> [RunningLine] {
        guard let rendered, rendered.runningLines.indices.contains(index) else { return [] }
        return rendered.runningLines[index]
    }

    /// Job 502: the footnote entries `drawFootnoteBlock` will actually paint at local page
    /// `index`'s own foot — `internal`, not `private`, for the SAME "tests can assert
    /// per-page content directly" reason `runningLines(atPageIndex:)` just above is internal.
    /// Reads `self.rendered` (this view's OWN post-`buildPages` copy), not whatever
    /// `RenderedDocument` a caller separately holds from before `setContent` ran — a plain
    /// `DocumentRenderer.render(...)` result's own `modernFootnoteEvents` is real (job 502's
    /// own doc comment), but its `modernFootnoteBlocks` is always empty: that field is filled
    /// in DURING `buildPages`, on the view's internal copy, exactly like `runningLines` is
    /// (see `RenderedDocument.modernFootnoteBlocks`'s own doc comment).
    func footnoteBlock(atPageIndex index: Int) -> [NSAttributedString] {
        guard let rendered, rendered.modernFootnoteBlocks.indices.contains(index) else { return [] }
        return rendered.modernFootnoteBlocks[index]
    }

    /// Job 502: local page `index`'s own real text-container BOTTOM edge, page-relative
    /// (`textTop(atPage:) + textHeight(atPage:)`) — where `drawFootnoteBlock` starts
    /// painting a footnote block. `internal`, same "tests can assert directly" reason as
    /// `footnoteBlock(atPageIndex:)` just above — a placement test needs this exact figure
    /// without hand-deriving `reserveFootnoteBlock`'s own reservation math a second time.
    func textContainerBottom(atPageIndex index: Int) -> CGFloat {
        textTop(atPage: index) + textHeight(atPage: index)
    }

    /// Job 257 (Show Invisibles part 3/4): the real `docToPagelines` page index "in force"
    /// at local page `index` — see `RenderedDocument.realPageIndexByPage`'s own doc
    /// comment. `index` itself when nothing is rendered yet or the index is out of range,
    /// so a caller can use this unconditionally without a nil-check.
    func realPageIndex(at index: Int) -> Int {
        guard let rendered, rendered.realPageIndexByPage.indices.contains(index) else { return index }
        return rendered.realPageIndexByPage[index]
    }

    /// The earliest local page that shows real page `target`'s content — the inverse of
    /// `realPageIndex(at:)`, used to re-find the reader's place across the Show Invisibles
    /// toggle. Reflow only ever SPLITS a real page across more local pages, never merges
    /// one away, so `target`'s content always starts at or after `target`'s own index;
    /// the first local page whose own real index has caught up to (or passed, if `target`
    /// no longer exists post-toggle) `target` is where it begins.
    func pageIndex(forRealPage target: Int) -> Int {
        guard let rendered else { return target }
        return rendered.realPageIndexByPage.firstIndex(where: { $0 >= target }) ?? max(0, pageViews.count - 1)
    }

    /// The rect of page `index` in this view's own coordinates, gap excluded — what
    /// Continuous Scroll scrolls TO when the Go menu asks for a page, and what print/
    /// native-PDF-export (`ExportEngine`, `QuickLookNativeRenderer`) crop a single page's
    /// own image to.
    ///
    /// Job 396 (391 root cause 5): grown by `headroom(atPage:)` at the TOP only — the
    /// page's own BOTTOM edge (`pageTops[index] + size.height`) is untouched, so the gap
    /// to the NEXT page is still exactly `pageGap`; only the boundary above this page
    /// moves, into space `rebuildPageTops` already reserved for exactly this. An oversized
    /// title's own real ascent bleeds into that reserved space (`drawOversizedSelfPasses`,
    /// unchanged by this job — it already draws relative to `PageTextView.frame.origin`,
    /// which `layout()` above now positions `headroom(atPage:)` further from this view's
    /// own top), so every caller that crops a page to exactly this rect — print, PDF
    /// export, QuickLook — now gets the full glyph too, not merely the screen view.
    func rect(ofPage index: Int) -> CGRect {
        guard let rendered, index >= 0, index < pageViews.count else { return .zero }
        let size = rendered.pageSize(atPage: index)
        switch display {
        case .singlePage:
            return CGRect(origin: .zero, size: NSSize(width: size.width, height: size.height + headroom(atPage: index)))
        case .continuousScroll:
            guard pageTops.indices.contains(index) else { return .zero }
            let extra = headroom(atPage: index)
            return CGRect(x: 0, y: pageTops[index] - extra, width: size.width, height: size.height + extra)
        }
    }

    /// Which page is showing, for either display mode.
    ///
    /// In Single Page that is simply `currentPageIndex`. In Continuous Scroll it has to be
    /// derived from what is actually scrolled into view, because nothing "selects" a page
    /// there — the page containing the top of the visible rect is the one the user is on.
    var visiblePageIndex: Int {
        switch display {
        case .singlePage:
            return currentPageIndex
        case .continuousScroll:
            guard !pageViews.isEmpty, !pageTops.isEmpty else { return 0 }
            // Nearest page TOP to the scroll offset (job 396: `pageTops` entries are no
            // longer an even `index * stride`, once a page's own `headroom(atPage:)` is
            // non-zero, so this can no longer divide by a constant stride — it has to
            // search the real table instead). Equivalent to the old formula on every
            // ordinary document, where every gap is `pageGap` and this is just "round to
            // the nearest multiple of the stride".
            let top = visibleRect.origin.y
            var best = 0
            var bestDelta = CGFloat.greatestFiniteMagnitude
            for (index, pageTop) in pageTops.enumerated() {
                let delta = abs(pageTop - top)
                if delta < bestDelta {
                    bestDelta = delta
                    best = index
                }
            }
            return best
        }
    }

    /// Show page `index` in Single Page mode.
    func showPage(_ index: Int) {
        guard display == .singlePage else { return }
        currentPageIndex = max(0, min(index, pageViews.count - 1))
        applyDisplayMode()
        // Job 396: Single Page's own `intrinsicContentSize`/`layout()` now depend on
        // CURRENT page's own `headroom(atPage:)`, which varies page to page (an oversized
        // title's own page needs more canvas than an ordinary one) — `setDisplay`'s own
        // "the frame has to move with the mode" reasoning applies per-page here too.
        sizeToContent()
    }

    /// Job 460: sets each page view about to become visible its own real frame FIRST, then
    /// clears `isHidden` — never the other way around. This is the invariant the defect above
    /// broke: a page view must never be visible at a zero frame, and that has to be established
    /// HERE, before `isHidden` changes, not left to some later `layout()` pass that might not
    /// run before the next paint. `frameForPage(_:)`'s own doc comment has the full root cause.
    ///
    /// Continuous Scroll needs `pageTops` already built to give every page a real frame here —
    /// `setContent` now calls `rebuildPageTops()` before this method for exactly that reason. A
    /// page whose frame this leaves at `.zero` (Continuous Scroll, if ever called before
    /// `pageTops` is ready) simply stays `.zero`; the fix only guarantees ISHIDDEN and FRAME
    /// change together, not that geometry no one has computed yet springs into existence.

    /// Item 19: a page's SECOND and later column views get the same frame and the same
    /// visibility as the page they belong to.
    ///
    /// They are full-page-width overlays on their own page's sheet — a line already carries
    /// its own column's left edge as a paragraph indent, so nothing here needs an x — which
    /// means they must be framed exactly like `pageViews[index]` and never left at the
    /// origin. Left unframed they land on page 1: FORMFEED.WS drew its page-7 second column
    /// on page 1, the identical 240x36pt rect reported extraInActual there and
    /// missingInActual where it belonged.
    private func syncColumnViews(atPage index: Int, frame: NSRect?, hidden: Bool) {
        guard columnViews.indices.contains(index) else { return }
        for (offset, view) in columnViews[index].enumerated() {
            // Which column this view holds (`columnViewColumns`), not its ordinal: a Modern page the engine
            // partitions can skip a column it left empty.
            let column = columnViewColumns.indices.contains(index)
                && columnViewColumns[index].indices.contains(offset)
                ? columnViewColumns[index][offset] : offset + 1
            if let frame { view.frame = columnFrame(frame, column: column, page: index) }
            view.isHidden = hidden
        }
    }

    /// Batch 41 (A): a later column's frame. Every Native column shares its page's frame — the engine's own x is in
    /// its lines — while a Modern column the engine lays in `.co` columns starts at its own x
    /// (`RenderedDocument.modernColumnOffset`) and runs to the frame's right edge.
    private func columnFrame(_ pageFrame: NSRect, column: Int, page: Int) -> NSRect {
        guard let rendered, rendered.modernColumns(onPage: page) > 1 else { return pageFrame }
        let offset = rendered.modernColumnOffset(column, onPage: page)
        return NSRect(x: pageFrame.minX + offset, y: pageFrame.minY,
                      width: max(1, pageFrame.width - offset), height: pageFrame.height)
    }

    /// Batch 26: `applyDisplayMode()` for the pages from `start` on — those a turn of progressive layout just
    /// added; the pages before them are framed and shown already.
    func applyDisplayMode(toPagesFrom start: Int) {
        guard start < pageViews.count else { return }
        for index in start..<pageViews.count {
            let view = pageViews[index]
            switch display {
            case .continuousScroll:
                view.frame = frameForPage(index)
                view.isHidden = false
            case .singlePage:
                if index == currentPageIndex { view.frame = frameForPage(index) }
                view.isHidden = index != currentPageIndex
            }
            syncColumnViews(atPage: index, frame: view.frame, hidden: view.isHidden)
        }
        showOnlyPagesNearTheScreen()
    }

    func applyDisplayMode() {
        switch display {
        case .continuousScroll:
            for (index, view) in pageViews.enumerated() {
                view.frame = frameForPage(index)
                view.isHidden = false
                syncColumnViews(atPage: index, frame: view.frame, hidden: false)
            }
        case .singlePage:
            for (index, view) in pageViews.enumerated() {
                if index == currentPageIndex {
                    view.frame = frameForPage(index)
                }
                view.isHidden = index != currentPageIndex
                syncColumnViews(atPage: index, frame: view.frame, hidden: view.isHidden)
            }
        }
        showOnlyPagesNearTheScreen()
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        guard let rendered else { return NSSize(width: 100, height: 100) }
        let page = rendered.pageSize(atPage: currentPageIndex)
        switch display {
        case .singlePage:
            // Job 396: grown by CURRENT page's own `headroom` — screen-only canvas so an
            // oversized title's real ascent has room to bleed into instead of clipping at
            // this view's own top edge (see `headroom(atPage:)`'s own doc comment). `0`
            // for the overwhelming majority of pages, so this is a no-op almost always.
            return NSSize(width: page.width, height: page.height + headroom(atPage: currentPageIndex))
        case .continuousScroll:
            guard !pageTops.isEmpty else { return NSSize(width: rendered.widestPageWidth, height: page.height) }
            let bottom = (pageTops.last ?? 0) + rendered.pageSize(atPage: pageTops.count - 1).height
            return NSSize(width: rendered.widestPageWidth, height: bottom)
        }
    }

    override func layout() {
        super.layout()
        guard rendered != nil else { return }

        // Job 460: `frameForPage(_:)`, the same computation `applyDisplayMode()`/`makePageView`
        // now use — this pass is no longer the ONLY place a page view ever gets a real frame
        // (see that method's own doc comment), so it has to agree with them exactly, not merely
        // approximate what they did.
        switch display {
        case .singlePage:
            for (index, view) in pageViews.enumerated() where index == currentPageIndex {
                view.frame = frameForPage(index)
                syncColumnViews(atPage: index, frame: view.frame, hidden: view.isHidden)
            }
        case .continuousScroll:
            for (index, view) in pageViews.enumerated() where pageTops.indices.contains(index) {
                view.frame = frameForPage(index)
                syncColumnViews(atPage: index, frame: view.frame, hidden: view.isHidden)
            }
        }
    }

    // MARK: - Printing

    /// Tell AppKit where the pages are instead of letting it guess.
    ///
    /// Without these, `NSPrintOperation` paginates by slicing the view every
    /// `paperSize.height`. This view is laid out for the SCREEN, where pages are separated
    /// by `pageGap` — so the slices drift by `pageGap × (n − 1)` and each sheet after the
    /// first carries a strip of the previous page. Measured before this was added: a
    /// two-page document laid out 2416pt tall, which AppKit divided by 792pt of Letter and
    /// reported as **four** sheets in the print panel.
    ///
    /// The gap is a screen affordance, like the grey desk the pages sit on. Rather than
    /// build a second layout for printing that could disagree with the first, the view
    /// simply reports the page rectangles it already knows — each one page, gap excluded.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // Only the stacked layout has pages to report. `makePrintOperation` always builds
        // its view in continuous scroll; single-page is one sheet and AppKit's default is
        // already right for it.
        guard rendered != nil, display == .continuousScroll, !pageViews.isEmpty else {
            return false
        }
        range.pointee = NSRange(location: 1, length: pageViews.count)
        return true
    }

    /// The rect of one page, gap excluded (job 396: bleed headroom included at the top —
    /// see `rect(ofPage:)`'s own doc comment). Pages are 1-based, as AppKit numbers them.
    override func rectForPage(_ page: Int) -> NSRect {
        guard display == .continuousScroll else { return .zero }
        // Same rect `rect(ofPage:)` reports, deliberately — if these two ever disagree,
        // the printed sheet will not match the screen (and, since this job, an oversized
        // title's own bleed would print clipped even though the screen shows it whole).
        return rect(ofPage: page - 1)
    }

    // MARK: - Scrolling as page flips

    /// In Single Page the page always fills the window, so there is nothing to scroll WITHIN
    /// a page — a scroll gesture means "next page", the way turning a sheet over does. In
    /// Continuous Scroll the view really scrolls and this steps aside entirely.
    ///
    /// `accumulatedScroll` exists because trackpad events arrive as a stream of small deltas;
    /// without it one flick would flip a dozen pages.
    ///
    /// Batch 40 (M10): no `scrollWheel(with:)` override any more. A document view that overrides it takes the
    /// scroll view out of AppKit's responsive scrolling, so Continuous Scroll drew every newly exposed strip on
    /// the main thread as it scrolled. `DocumentWindowController` hands scroll events here from a local event
    /// monitor instead, and only while Single Page shows.
    private var accumulatedScroll: CGFloat = 0
    private static let scrollPerPage: CGFloat = 50

    /// Whether this view can flip pages for a scroll event: Single Page, with more than one page.
    var flipsPagesOnScroll: Bool { display == .singlePage && pageViews.count > 1 }

    /// A scroll event in Single Page turns pages; false, and nothing done, in Continuous Scroll or with one page.
    @discardableResult
    func flipPages(for event: NSEvent) -> Bool {
        guard flipsPagesOnScroll else { return false }
        // A new gesture starts a fresh count, so a previous flick cannot carry over.
        if event.phase == .began { accumulatedScroll = 0 }
        accumulatedScroll += event.scrollingDeltaY

        while abs(accumulatedScroll) >= Self.scrollPerPage {
            // Natural scrolling: content moves with the fingers, so a positive deltaY (content
            // pulled down) reveals what is ABOVE — the previous page.
            let step = accumulatedScroll > 0 ? -1 : 1
            let target = currentPageIndex + step
            guard target >= 0, target < pageViews.count else {
                accumulatedScroll = 0
                return true
            }
            showPage(target)
            pageDidChange?(target)
            accumulatedScroll -= CGFloat(step) * -Self.scrollPerPage
        }
        return true
    }

    /// Called whenever the displayed page changes, so the window controller can revalidate
    /// the Go menu without polling.
    var pageDidChange: ((Int) -> Void)?

    /// #271 M7: called once, at the first draw after it is set — where the window's
    /// `open.firstPageDrawn` interval ends.
    var onFirstDraw: (() -> Void)?
}
