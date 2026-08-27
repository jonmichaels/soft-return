import AppKit

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
    /// exactly, per the spec's geometry rule.
    private static let pageGap: CGFloat = 20

    /// Continuous Scroll only: local page `index`'s own cumulative top, `pageGap` plus
    /// every earlier page's own `pageSize.height` plus every page THROUGH `index`'s own
    /// `headroom(atPage:)` (job 396) — rebuilt once per `setContent` (`rebuildPageTops`),
    /// not recomputed per call, since an export/print loop asks `rect(ofPage:)` once per
    /// page and an O(n) rebuild each time would make that loop O(n²) on a long document.
    /// Single Page never consults this: only one page is ever laid out at a time there
    /// (`layout()`'s own `.singlePage` case applies `headroom(atPage:currentPageIndex)`
    /// directly), so no cumulative table is needed.
    private var pageTops: [CGFloat] = []

    /// Job 396 (391 root cause 5): extra blank canvas `RenderedDocument.leadingHeadroom`
    /// says local page `index` needs ABOVE its own nominal top, or `0` when `rendered` is
    /// nil, `index` is out of range, or that page's own first line isn't an oversized
    /// title that needs one. See `RenderedDocument.leadingHeadroom`'s own doc comment for
    /// how the figure is measured, and `rebuildPageTops`/`layout()`/`draw(_:)` below for
    /// how it is spent — always as bonus canvas space ABOVE a page's existing geometry,
    /// never as a change to where a glyph's own baseline sits.
    private func headroom(atPage index: Int) -> CGFloat {
        guard let rendered, rendered.leadingHeadroom.indices.contains(index) else { return 0 }
        return rendered.leadingHeadroom[index]
    }

    /// Job 427 (Jon's ruling: "Native only changes fonts. Otherwise it's the same as
    /// Printed."): local page `index`'s own text-container top-edge distance from the
    /// paper's top — `RenderedDocument.perPageTextTop[index]` when that page has its own
    /// entry, else `rendered.textFrame.origin.y` (every non-Printed render path's flat,
    /// shared anchor, and Printed's own fallback for an index the per-page array somehow
    /// doesn't cover — defensive only, `renderPrinted` always sizes the array to
    /// `pages.count`). Replaces the single shared `rendered.textFrame.origin.y` every call
    /// site below used before this job — see `RenderedDocument.perPageTextTop`'s own doc
    /// comment for why a single shared anchor could not represent a page whose own `.mt`/
    /// `.mb` differs from the document's global pair.
    private func textTop(atPage index: Int) -> CGFloat {
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
    private func textHeight(atPage index: Int) -> CGFloat {
        guard let rendered else { return 0 }
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
    private func rebuildPageTops() {
        guard let rendered else { pageTops = []; return }
        var tops: [CGFloat] = []
        tops.reserveCapacity(pageViews.count)
        var y: CGFloat = 0
        for index in pageViews.indices {
            if index > 0 { y += Self.pageGap }
            y += headroom(atPage: index)
            tops.append(y)
            y += rendered.pageSize.height
        }
        pageTops = tops
    }

    private var storage = NSTextStorage()
    private var layoutManager = NSLayoutManager()
    private var containers: [NSTextContainer] = []
    /// Job 412: `true` only while `buildExplicitPages`'s own throwaway, whole-document probe
    /// container is attached — see that call site's own doc comment for why the
    /// `NSLayoutManagerDelegate` conformance below must stay a no-op there.
    private var isMeasuringProbeContainer = false
    private(set) var pageViews: [NSTextView] = []
    /// Job 227: draws `RenderedDocument.oversizedSelfPasses` — see `drawOversizedSelfPasses`'s
    /// own doc comment for why this needs a dedicated subview ABOVE every `PageTextView`
    /// rather than either this view's own background `draw(_:)` (subviews always composite
    /// on top of it, oversized content or not) or `PageTextView` itself (its own bounds are
    /// exactly the box the oversized glyph doesn't fit in). Re-added (moving it to the end
    /// of the subview list, i.e. topmost) at the end of every `setContent`, since `pageViews`
    /// are torn down and rebuilt there.
    private let overlayView = OversizedPassOverlayView()

    private var rendered: RenderedDocument?
    private var display: PageDisplay = .singlePage
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

    // MARK: - Content

    /// Replace the displayed document. Rebuilds the container chain, because page size and
    /// line capacity both change with style.
    func setContent(_ rendered: RenderedDocument, display: PageDisplay) {
        self.rendered = rendered
        self.display = display

        // Tear down the old chain. Removing the layout manager from the storage first
        // detaches every container and view in one move.
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []
        containers = []
        if let old = storage.layoutManagers.first { storage.removeLayoutManager(old) }

        storage = NSTextStorage(attributedString: rendered.text)
        layoutManager = NSLayoutManager()
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

        buildPages(for: rendered)
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
    private func applyPageAccessibilityLabels() {
        let total = pageViews.count
        for (index, view) in pageViews.enumerated() {
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

    /// Build the container chain for `rendered`. Printed style places each `docToPagelines`
    /// page in its own EXPLICITLY sized container (`buildExplicitPages`); Modern style has
    /// no library pagination to honour, so AppKit grows the chain and reflows on its own —
    /// the only way to learn ITS page count is to lay out and ask.
    private func buildPages(for rendered: RenderedDocument) {
        let containerSize = rendered.textFrame.size
        if rendered.clipsLines {
            buildExplicitPages(for: rendered, width: containerSize.width)
            return
        }

        var guardCounter = 0
        // A hard ceiling: a malformed document should produce an ugly page count, never an
        // unbounded loop that hangs the app with no way to cancel.
        let maxPages = 10_000
        // b28 note 11: forced screenplay-marker breaks still waiting to be honoured, in
        // ascending order — `BreakingTextContainer`'s own doc comment has the mechanism.
        // Empty for every document `RenderedDocument.modernForcedPageBreakOffsets` doesn't
        // populate, which is every document but a screenplay-detected one — this loop is
        // then IDENTICAL to before this job, container for container.
        var pendingBreaks = rendered.modernForcedPageBreakOffsets

        repeat {
            let container = BreakingTextContainer(size: containerSize)
            // The default 5pt padding would shift every line right of where the library
            // said, and silently narrow the text column.
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            // The NEXT pending break, if any — always strictly ahead of whatever this
            // container has placed so far (see the consumption check below, which pops a
            // break only once some container's real content has actually reached it).
            container.forcedBreakOffset = pendingBreaks.first
            layoutManager.addTextContainer(container)
            containers.append(container)

            let view = makePageView(container: container, rendered: rendered, pageIndex: pageViews.count)
            pageViews.append(view)
            addSubview(view)

            layoutManager.ensureLayout(for: container)

            // Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like
            // Printed): reserve room at THIS container's own foot for any footnote(s)
            // attached to a paragraph that landed on it, before asking where the next
            // container should pick up — see `RenderedDocument.modernFootnoteEvents`'s own
            // doc comment for why this has to run HERE, one real page at a time, rather than
            // resolved after the whole chain exists the way running heads/feet are.
            if !rendered.modernFootnoteEvents.isEmpty {
                let entries = reserveFootnoteBlock(in: container, fullHeight: containerSize.height,
                                                    rendered: rendered)
                self.rendered?.modernFootnoteBlocks.append(entries)
            }

            // Did THIS container's own real content reach the break it was given? A break
            // far past what this container would have held naturally has no effect above
            // (the container simply runs out of room first) and stays pending, unconsumed,
            // for the container after this one to try again.
            if let nextBreak = pendingBreaks.first {
                let glyphRange = layoutManager.glyphRange(for: container)
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                if charRange.location + charRange.length >= nextBreak {
                    pendingBreaks.removeFirst()
                }
            }
            guardCounter += 1
        } while guardCounter < maxPages && !allGlyphsPlaced()

        // Job 393 (391 root cause 2): only NOW do Modern's real pages exist to replay
        // `rendered.hfEvents` against — see `RenderedDocument.runningLines`'s own doc comment
        // on why this can't happen inside `DocumentRenderer` the way Printed's own
        // `runningLines` does. A no-op for every other render (`hfEvents` empty).
        if !rendered.hfEvents.isEmpty {
            self.rendered?.runningLines = resolvedModernRunningLines(for: rendered)
        }
    }

    /// Job 502: shrinks `container`'s own height to leave room for whichever of
    /// `rendered.modernFootnoteEvents` land inside it (their `charOffset` inside this
    /// container's own real character range), re-laying it out after every shrink, and
    /// returns the footnote entries that will actually draw at its foot — the SAME
    /// reservation the engine's own `PDFModernLayout.swift` performs (`modernStreams`'s
    /// `noteBlockH`/`sepH`), just run incrementally against AppKit's real layout instead of
    /// hand-derived line metrics, since Modern's real page breaks are not known until AppKit
    /// decides them (this file's own top doc comment).
    ///
    /// Shrinking a container can only ever REMOVE glyphs from it — AppKit has nowhere else to
    /// put text that no longer fits within a single container in this chain-building loop —
    /// so the set of footnote events landing inside it can only ever shrink too as
    /// `reservedHeight` grows. That is what guarantees this converges rather than
    /// oscillating between "shrinking admits fewer footnotes" and "fewer footnotes would fit
    /// in a taller container": `reservedHeight` only ever grows across iterations, bounded by
    /// the number of footnote events attached to this page, so it cannot cycle back to a
    /// smaller value. A page whose own footnote set genuinely shrinks under compression keeps
    /// the LARGER, earlier reservation — a little unused blank canvas above the footnote
    /// block in that rare case, never a wrong placement.
    private func reserveFootnoteBlock(
        in container: NSTextContainer, fullHeight: CGFloat, rendered: RenderedDocument
    ) -> [NSAttributedString] {
        let width = container.size.width
        var reservedHeight: CGFloat = 0
        var entries: [NSAttributedString] = []
        var guardCounter = 0
        // A hard ceiling matching `buildPages`'s own `maxPages` guard's spirit — bounded by
        // the number of footnote events this whole document carries, since each iteration
        // that does not converge strictly removes at least one from this page's own set.
        let maxIterations = max(1, rendered.modernFootnoteEvents.count) + 1
        while guardCounter < maxIterations {
            guardCounter += 1
            let glyphRange = layoutManager.glyphRange(for: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let pageEnd = charRange.location + charRange.length
            let onThisPage = rendered.modernFootnoteEvents
                .filter { $0.charOffset >= charRange.location && $0.charOffset < pageEnd }
                .flatMap(\.entries)
            let neededHeight = Self.footnoteBlockHeight(
                entries: onThisPage, separator: rendered.modernFootnoteSeparator, width: width)
            entries = onThisPage
            if neededHeight <= reservedHeight { break }
            reservedHeight = neededHeight
            container.size = CGSize(width: width, height: max(1, fullHeight - reservedHeight))
            layoutManager.ensureLayout(for: container)
        }
        return entries
    }

    /// The real, wrapped height `entries` (plus `separator`, when `entries` is non-empty)
    /// will occupy at the foot of a page `width` points wide — measured with AppKit's own
    /// `NSAttributedString.boundingRect`, the same "ask AppKit, don't hand-derive it" rule
    /// this codebase already applies everywhere else font metrics matter
    /// (`DocumentRenderer.firstBaselineOffset`'s own doc comment). Every string involved
    /// already carries its own font/paragraph style (`ModernFootnoteEvent`'s own doc
    /// comment), so this needs no styling knowledge of its own — just concatenation and a
    /// measurement.
    private static func footnoteBlockHeight(
        entries: [NSAttributedString], separator: NSAttributedString, width: CGFloat
    ) -> CGFloat {
        guard !entries.isEmpty else { return 0 }
        let block = NSMutableAttributedString(attributedString: separator)
        for entry in entries { block.append(entry) }
        let bounds = block.boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return bounds.height
    }

    /// One page's own running heads/feet, replayed from `rendered.hfEvents` against that
    /// page's REAL first character offset — the state `.hf` events left "in force" by the
    /// time AppKit actually placed this page's first glyph, matching the engine's own
    /// `openPage()` rule (`DocumentRenderer.modernRunningLines`'s own doc comment has the
    /// full citation). A page with no glyphs of its own (defensive only — the build loop
    /// above never leaves a genuinely empty container mid-chain) inherits the offset of the
    /// page before it, rather than resetting to the very start of the document.
    private func resolvedModernRunningLines(for rendered: RenderedDocument) -> [[RunningLine]] {
        var result: [[RunningLine]] = []
        var lastOffset = 0
        for (index, container) in containers.enumerated() {
            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length > 0 {
                lastOffset = layoutManager.characterRange(
                    forGlyphRange: glyphRange, actualGlyphRange: nil).location
            }
            result.append(DocumentRenderer.modernRunningLines(
                events: rendered.hfEvents, upToOffset: lastOffset,
                pageNo: rendered.pageNumberStart + index,
                pageHeight: Double(rendered.pageSize.height)))
        }
        return result
    }

    /// Job 225: place `docToPagelines`' own page breaks explicitly instead of letting AppKit's
    /// automatic container-chain overflow decide where a page ends.
    ///
    /// ## Why AppKit's own flow could not be trusted to land on the library's breaks
    ///
    /// Every container in the old chain was the SAME fixed size (`capacity * metrics.lead`,
    /// `DocumentRenderer.RenderedDocument.textFrame`), and AppKit flowed the whole document's
    /// text through that chain automatically — it had no idea page N's lines were "meant" for
    /// container N. `DocumentRenderer` tried to make that automatic break land on the right
    /// boundary by PADDING each page's real content up to the container's fixed height with
    /// blank filler lines, sized from a MEASUREMENT of that page's own chunk. That measurement
    /// (job 202's `measuredHeight`) laid the chunk out in an ISOLATED, freshly-built
    /// `NSTextStorage`/`NSLayoutManager` holding only that one page's text — and on
    /// `LJ6DTP.WS`, a font/graphics-dense fixture, that isolated measurement measurably
    /// disagreed with how the SAME text measured once actually embedded in the real
    /// multi-container chain (job 224's own A/B: removing near-zero overprint fragments did
    /// not close the gap, because the padding was self-compensating — retuning it can only
    /// ever chase the isolated probe's own number, never the embedded chain's real one).
    ///
    /// ## The fix: measure the REAL embedded flow once, then size containers from THAT
    ///
    /// `DocumentRenderer` now emits page N's own real lines only — no padding at all (see its
    /// own doc comment). This function lays that SAME, single, real `NSTextStorage`/
    /// `layoutManager` out ONCE in a single oversized "probe" container spanning the whole
    /// document, and reads back the line-fragment rects AppKit actually produced —
    /// `enumerateLineFragments` on the REAL flow, not a re-typeset fragment. Because container
    /// boundaries do not change how tall AppKit renders any one fragment (this document's
    /// paragraph style pins `minimumLineHeight == maximumLineHeight`, so a fragment's height is
    /// a function of its own font/paragraph attributes only, never of what container it later
    /// lands in), the height the probe measured for page N's own `rendered.softLineFlags[n]
    /// .count` fragments is EXACTLY what those same fragments cost once laid out again in
    /// their own, separately sized container — so giving container N that height leaves no
    /// room for a single glyph of page N+1 to spill in, and no gap for page N's own last line
    /// to spill out.
    ///
    /// The probe container is removed before the real per-page containers are added — a
    /// `NSLayoutManager` re-flows its already-generated glyphs into whatever containers are
    /// attached to it, so removing the probe and adding the real chain in its place simply
    /// re-runs the SAME flow through the SAME glyphs, this time bounded by the real page
    /// heights instead of one unbounded one.
    private func buildExplicitPages(for rendered: RenderedDocument, width: CGFloat) {
        let lineCounts = rendered.softLineFlags.map(\.count)
        guard !lineCounts.isEmpty else { return }

        let probe = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        probe.lineFragmentPadding = 0
        probe.widthTracksTextView = false
        probe.heightTracksTextView = false
        // Job 412: the probe stays UNPINNED — see the `NSLayoutManagerDelegate`
        // conformance's own doc comment (`isMeasuringProbeContainer`'s first use) for why.
        // Its measurement below is only a FALLBACK/floor now: a pinned page's real height
        // comes from `RenderedDocument.pinnedPageBottoms` instead (see the
        // `height`/`pinnedHeight` computation below and that field's own doc comment).
        isMeasuringProbeContainer = true
        layoutManager.addTextContainer(probe)
        layoutManager.ensureLayout(for: probe)

        var fragmentTops: [CGFloat] = []
        var fragmentBottoms: [CGFloat] = []
        let probeGlyphs = layoutManager.glyphRange(for: probe)
        if probeGlyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: probeGlyphs) { rect, _, _, _, _ in
                fragmentTops.append(rect.minY)
                fragmentBottoms.append(rect.maxY)
            }
        }
        layoutManager.removeTextContainer(at: 0)
        isMeasuringProbeContainer = false

        // Float-safety margin only — the height itself is already the real AppKit
        // measurement above, not a second isolated guess. Same 0.5pt this codebase's own
        // oracles already treat as "on the grid" (`GeometryOracleTests.swift`).
        let epsilon: CGFloat = 0.5

        var cursor = 0
        for (pageIndex, count) in lineCounts.enumerated() {
            var height: CGFloat
            if count > 0, cursor + count <= fragmentTops.count {
                height = (fragmentBottoms[cursor + count - 1] - fragmentTops[cursor]) + epsilon
            } else {
                // Defensive fallback only — `count` comes from the exact same
                // `RenderedDocument` this probe just measured, so the fragment count
                // should always match. Falls back to the page's own visual frame height
                // rather than a zero-height container.
                height = rendered.textFrame.size.height
            }
            cursor += count
            // Job 412: this probe measured AppKit's own UNPINNED natural stacking — no
            // longer trustworthy for a PINNED page (see `RenderedDocument
            // .pinnedPageBottoms`'s own doc comment on why). A STRAIGHT OVERRIDE, not a
            // `max` with the probe's own figure: pinned content is usually more COMPACT
            // than the unpinned natural stacking the probe measured, so `max` would keep
            // the LARGER, unpinned-natural height — leaving spare room at this page's own
            // bottom that AppKit could (and did, confirmed empirically) fill with the
            // FOLLOWING page's own overflow content, since that content's own unpinned
            // proposal can still fit inside a container sized for the less-compact natural
            // stacking. The real per-page container has to be sized to EXACTLY this page's
            // own pinned content, not to whichever of the two measurements is bigger.
            if rendered.pinnedPageBottoms.indices.contains(pageIndex) {
                // Job 427: THIS page's own container-local anchor (`textTop(atPage:)`), not
                // the single shared `rendered.textFrame.origin.y` — `pinnedPageBottoms
                // [pageIndex]` is an absolute paper-Y built from this SAME page's own
                // `pageFirstBaseline` (`DocumentRenderer.renderPrinted`'s per-page loop), so
                // converting it to a container-local height has to subtract this page's own
                // origin or a page whose own `.mt`/`.mb` differs from the document's global
                // pair gets a container sized against the WRONG anchor.
                height = CGFloat(rendered.pinnedPageBottoms[pageIndex]) - textTop(atPage: pageIndex) + epsilon
            }

            let container = NSTextContainer(size: CGSize(width: max(1, width), height: max(1, height)))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
            containers.append(container)

            let view = makePageView(container: container, rendered: rendered, pageIndex: pageViews.count)
            pageViews.append(view)
            addSubview(view)
            layoutManager.ensureLayout(for: container)
        }
    }

    /// Has the last container consumed the end of the text?
    private func allGlyphsPlaced() -> Bool {
        guard let last = containers.last else { return true }
        let placed = layoutManager.glyphRange(for: last)
        let total = layoutManager.numberOfGlyphs
        if total == 0 { return true }
        return placed.location + placed.length >= total
    }

    /// Job 460 (b28 notes 4/8, third attempt): local page `index`'s own real frame for the
    /// CURRENT `display` mode — the single source of truth `layout()`, `applyDisplayMode()`
    /// and `makePageView` all now share, so a page view's frame is never assigned by one of
    /// them using different geometry than another would compute for the same index.
    ///
    /// Root cause this exists to close: every page view used to start life at `frame: .zero`
    /// and only ever receive a real frame from `layout()`'s own `.singlePage` branch, which
    /// skips every index except `currentPageIndex` — so a NEWLY current page went `isHidden =
    /// false` in `applyDisplayMode()` with no frame of its own yet, relying entirely on a LATER,
    /// separately-scheduled `layout()` pass to hand it one. `showPage`'s own `sizeToContent()`
    /// only sets `needsLayout`/`needsDisplay` (a REQUEST, not an act), so between `isHidden =
    /// false` and that deferred pass a page view was genuinely visible at a zero frame — proven
    /// with real numbers by `Job457ModernSinglePageBlankTests
    /// .screenWSPageTwoFrameStateBeforeAndAfterSettle()`, job 460's own step 1: `frame=(0,0,0,0)
    /// isHidden=false` immediately after `showPage`, on the exact fixture Jon reported this on.
    /// AppKit clips a view's drawing to its own bounds, so a zero-frame page paints nothing —
    /// this is the blank page.
    ///
    /// Returns `.zero` when the data this page's own frame depends on isn't ready yet — Single
    /// Page needs nothing but `rendered` (`textTop`/`headroom`/`textHeight` are all keyed off
    /// data that exists the moment this page's own container does, `buildPages`/
    /// `buildExplicitPages` both append to `containers` before calling `makePageView`); Continuous
    /// Scroll additionally needs `pageTops`, which isn't built until `rebuildPageTops()` runs
    /// AFTER every page view already exists — `.zero` there is a safe placeholder precisely
    /// because nothing may ever go `isHidden = false` before `applyDisplayMode()` runs, and
    /// `setContent` now calls `rebuildPageTops()` before `applyDisplayMode()` for exactly this
    /// reason (see that call site's own job 460 doc comment).
    private func frameForPage(_ index: Int) -> CGRect {
        guard let rendered else { return .zero }
        let text = rendered.textFrame
        switch display {
        case .singlePage:
            return CGRect(
                x: text.origin.x, y: textTop(atPage: index) + headroom(atPage: index),
                width: text.width, height: textHeight(atPage: index))
        case .continuousScroll:
            guard pageTops.indices.contains(index) else { return .zero }
            return CGRect(
                x: text.origin.x, y: pageTops[index] + textTop(atPage: index),
                width: text.width, height: textHeight(atPage: index))
        }
    }

    private func makePageView(container: NSTextContainer, rendered: RenderedDocument,
                               pageIndex: Int) -> NSTextView {
        // Job 460: a real frame from construction, not `.zero` — belt-and-braces alongside
        // `applyDisplayMode()` setting it again before ever clearing `isHidden`. This first
        // assignment is what covers Single Page (its own geometry is ready at this point,
        // before `applyDisplayMode()` even runs once for this `setContent` call); Continuous
        // Scroll's own real frame isn't computable yet here (`frameForPage`'s own doc comment)
        // and gets `.zero` — safe, since nothing is visible until `applyDisplayMode()` runs.
        let view = PageTextView(frame: frameForPage(pageIndex), textContainer: container)
        // Job 246 (p6-knockout): a line index whose `oversizedSelfPasses` entry is non-nil
        // is drawn by `drawOversizedSelfPasses` instead (the OVERLAY subview, always
        // composited above every `PageTextView` — see that method's own doc comment on
        // why an oversized base bleeds at the paper level). That overlay now ALSO draws
        // this same index's `overprintPasses` right after its self-pass (see its own job
        // 246 doc comment), so this view must NOT draw them too — the engine's own PDF
        // paints a chain in ONE order (base, then each pass, later ops on top); splitting
        // "oversized base" and "its own chain's continuation" across two independently-
        // ordered drawing layers (this view UNDER the overlay, always) inverted that order
        // for LJ6DTP.WS's "Black Text on a Gray Background" (28pt gray band, `page[50]`,
        // oversized) — the closing heading text (`page[51]`) painted here, UNDER the
        // overlay, so the band's own self-pass glyphs painted OVER it afterward and hid it.
        let selfPasses = rendered.oversizedSelfPasses.indices.contains(pageIndex)
            ? rendered.oversizedSelfPasses[pageIndex] : []
        let rawPasses = rendered.overprintPasses.indices.contains(pageIndex)
            ? rendered.overprintPasses[pageIndex] : []
        view.overprintPasses = rawPasses.enumerated().map { index, passes in
            (selfPasses.indices.contains(index) && selfPasses[index] != nil) ? [] : passes
        }
        view.baselineOffset = rendered.baselineOffset
        // Job 211: gates the vector-graphics overlay — Printed only, same as
        // `softLineFlags`/`runningLines` (`RenderedDocument.clipsLines`'s own convention).
        view.isPrintedStyle = rendered.clipsLines
        // A viewer, not an editor — the spec's first sentence about this app.
        view.isEditable = false
        view.isSelectable = true
        view.isFieldEditor = false
        view.drawsBackground = true
        view.backgroundColor = .white   // paper, not a UI surface — see draw(_:)
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        // Nothing here should second-guess a 1987 document: no smart quotes, no
        // substitutions, no spell checking a file the author cannot be asked about.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        // Writing Tools rewrites text. There is no text here to rewrite — the document is
        // read-only and belongs to someone who is probably dead. Turning it off at the text
        // view is also what keeps its command out of the Edit menu. The API (and Writing
        // Tools itself) is macOS 15+ only — floored at 13.0 (job 342), there is nothing to
        // turn off on 13/14, so the honest fallback is simply no-op there.
        if #available(macOS 15, *) {
            view.writingToolsBehavior = .none
        }
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.setAccessibilityRole(.textArea)
        return view
    }

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
        let size = rendered.pageSize
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
    private func applyDisplayMode() {
        switch display {
        case .continuousScroll:
            for (index, view) in pageViews.enumerated() {
                view.frame = frameForPage(index)
                if view.isHidden { (view as? PageTextView)?.didDrawSinceShown = false }
                view.isHidden = false
            }
        case .singlePage:
            for (index, view) in pageViews.enumerated() {
                if index == currentPageIndex {
                    view.frame = frameForPage(index)
                    if view.isHidden { (view as? PageTextView)?.didDrawSinceShown = false }
                }
                view.isHidden = index != currentPageIndex
            }
        }
        logPageDiagnostics(event: "applyDisplayMode(\(display))")
    }

    /// Job 460 (step 4, diagnostic fallback): Jon is the only person who has ever seen this
    /// defect, and headless CI cannot see his screen — if the fix above still misses some case
    /// on his real machine, this is what turns a fourth blind guess into evidence. Gated on the
    /// SAME `SRDiagnostics=1` switch every other investigation tool in this codebase already
    /// uses (`SRDiagnosticsGate` — "one switch, not a flag per tool"), and logged via `NSLog`
    /// exactly like `AppleEventSelfSendProbe`/`AppleEventSelfTest` already do, so Jon can grab it
    /// from Console.app or `log show` with no new tooling.
    ///
    /// `frame`/`containerSize`/`glyphRange`/`isHidden` are captured SYNCHRONOUSLY, right here,
    /// so a line labelled with THIS event's `display`/navigation always reports THIS event's own
    /// state — even if another `applyDisplayMode()` call (e.g. a second, immediately-following
    /// display-mode switch) lands before the async block below runs. Only `didDraw` is deferred:
    /// at the point `applyDisplayMode()` calls this, AppKit has not yet run the draw pass
    /// `needsDisplay = true` merely requested, so reading it now would always report `didDraw=NO`
    /// for the page that just became current — not the question this diagnostic exists to answer
    /// ("did the page that's now visible actually get painted"). Captured per VIEW OBJECT
    /// (`page.view`, not a re-fetched `self.pageViews[index]`), so even if the page list itself
    /// is torn down and rebuilt (`setContent`) before the async block runs, this reads the same
    /// view this specific event was about, not whatever now sits at that index.
    /// Job 477: the field job-460's `frame`/`glyphRange`/`didDraw` line above could not answer
    /// — those prove a page DRAWS, never WHAT it draws, and that gap is exactly what left two
    /// equally-plausible theories (appendix present-but-invisible vs. never appended) standing
    /// after three rounds on the missing-footnotes defect. Text/paraCount/color are pulled from
    /// the SAME `NSTextStorage` every container shares (`RenderedDocument`'s own "one string,
    /// not one view per page" doc comment), sliced to just this page's own glyph range converted
    /// to a character range — so this reports what THIS page actually holds, not the whole
    /// document.
    private func diagnosticTextSnapshot(storage: NSTextStorage?, range: NSRange?) -> (text: String, paraCount: Int, color: String) {
        guard let storage, let range, range.length > 0 else { return ("<EMPTY>", 0, "n/a") }
        let ns = storage.string as NSString
        let full = ns.substring(with: range)
        var paraCount = 0
        full.enumerateSubstrings(in: full.startIndex..<full.endIndex, options: .byParagraphs) { _, _, _, _ in
            paraCount += 1
        }
        let escaped = full.replacingOccurrences(of: "\n", with: "\\n")
        let chars = Array(escaped)
        let text: String
        if chars.count <= 180 {
            text = "\"\(escaped)\""
        } else {
            text = "\"\(String(chars.prefix(120)))\" … \"\(String(chars.suffix(60)))\""
        }
        let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let colorDescription: String
        if let color, let rgb = color.usingColorSpace(.sRGB) {
            colorDescription = String(format: "rgba(%.2f,%.2f,%.2f,%.2f)",
                                       rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        } else {
            colorDescription = color?.description ?? "nil"
        }
        return (text, paraCount, colorDescription)
    }

    /// One line per page view, every field the brief named: index, frame, containerSize, glyph
    /// range, isHidden, and whether `draw(_:)` fired since this page was last made visible.
    /// Job 477 adds this page's own text (first 120 / last 60 characters, `<EMPTY>` when the
    /// range is empty), `paraCount`, and the `foregroundColor` of the range's first character —
    /// additive, every job-460 field is unchanged.
    private func logPageDiagnostics(event: String) {
        guard SRDiagnosticsGate.isEnabled() else { return }
        struct PageSnapshot {
            let index: Int
            let view: NSTextView
            let frame: CGRect
            let containerSize: CGSize
            let glyphRange: NSRange?
            let isHidden: Bool
            let text: String
            let paraCount: Int
            let color: String
        }
        let snapshots: [PageSnapshot] = pageViews.enumerated().map { index, view in
            let containerSize = view.textContainer?.size ?? .zero
            let layoutManager = view.layoutManager
            let textContainer = view.textContainer
            let glyphRange = layoutManager.flatMap { manager in
                textContainer.map { manager.glyphRange(for: $0) }
            }
            var charRange: NSRange?
            if let manager = layoutManager, let glyphRange {
                charRange = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            }
            let snapshot = diagnosticTextSnapshot(storage: view.textStorage, range: charRange)
            return PageSnapshot(index: index, view: view, frame: view.frame,
                                 containerSize: containerSize, glyphRange: glyphRange, isHidden: view.isHidden,
                                 text: snapshot.text, paraCount: snapshot.paraCount, color: snapshot.color)
        }
        DispatchQueue.main.async {
            for snapshot in snapshots {
                let didDraw = (snapshot.view as? PageTextView)?.didDrawSinceShown ?? false
                NSLog("[SoftReturn] PagedDocumentView.%@ page=%d frame=%@ containerSize=%@ "
                      + "glyphRange=%@ isHidden=%@ didDraw=%@ text=%@ paraCount=%d color=%@",
                      event, snapshot.index, NSStringFromRect(snapshot.frame), NSStringFromSize(snapshot.containerSize),
                      snapshot.glyphRange.map { NSStringFromRange($0) } ?? "nil",
                      snapshot.isHidden ? "YES" : "NO", didDraw ? "YES" : "NO",
                      snapshot.text, snapshot.paraCount, snapshot.color)
            }
        }
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        guard let rendered else { return NSSize(width: 100, height: 100) }
        let page = rendered.pageSize
        switch display {
        case .singlePage:
            // Job 396: grown by CURRENT page's own `headroom` — screen-only canvas so an
            // oversized title's real ascent has room to bleed into instead of clipping at
            // this view's own top edge (see `headroom(atPage:)`'s own doc comment). `0`
            // for the overwhelming majority of pages, so this is a no-op almost always.
            return NSSize(width: page.width, height: page.height + headroom(atPage: currentPageIndex))
        case .continuousScroll:
            guard !pageTops.isEmpty else { return NSSize(width: page.width, height: page.height) }
            let bottom = (pageTops.last ?? 0) + page.height
            return NSSize(width: page.width, height: bottom)
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
            }
        case .continuousScroll:
            for (index, view) in pageViews.enumerated() where pageTops.indices.contains(index) {
                view.frame = frameForPage(index)
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
    private var accumulatedScroll: CGFloat = 0
    private static let scrollPerPage: CGFloat = 50

    override func scrollWheel(with event: NSEvent) {
        guard display == .singlePage, pageViews.count > 1 else {
            super.scrollWheel(with: event)
            return
        }
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
                return
            }
            showPage(target)
            pageDidChange?(target)
            accumulatedScroll -= CGFloat(step) * -Self.scrollPerPage
        }
    }

    /// Called whenever the displayed page changes, so the window controller can revalidate
    /// the Go menu without polling.
    var pageDidChange: ((Int) -> Void)?

    // MARK: - Drawing the paper

    /// The page rectangles themselves — white sheets under the text views, and the grey
    /// they sit on. Drawn rather than made of subviews: they carry no behaviour, and a
    /// hundred-page document should not cost a hundred extra views.
    override func draw(_ dirtyRect: NSRect) {
        guard let rendered else { return }
        let page = rendered.pageSize

        // The grey desk the pages sit on is a SCREEN affordance. Paper has no desk, and
        // printing it would put a grey wash across every sheet — so on paper we draw only
        // the pages. (`isDrawingToScreen` is false for the print context and for PDF/EPS
        // export, which is exactly the set of cases that want this.)
        let toScreen = NSGraphicsContext.current?.isDrawingToScreen ?? true
        if toScreen {
            NSColor.softReturnCanvas.setFill()
            // `bounds`, NOT `dirtyRect`. Since macOS 14 `NSView.clipsToBounds` defaults to
            // false, so filling `dirtyRect` paints outside this view — harmless on screen
            // where a clip view catches it, ruinous in print where there is no clip view at
            // all: `makePrintOperation` hands a bare PagedDocumentView to NSPrintOperation.
            // This is the same defect that made the document window look blank, in a second
            // place. See BottomBar for the first.
            bounds.fill()
        }

        // PAPER IS WHITE. Not `textBackgroundColor`, which follows the system appearance and
        // turned the page black — white type on a black sheet — the moment the Mac switched
        // to Dark Mode. Printed style is a line-for-line reproduction of a 1980s typescript;
        // a facsimile that inverts with the time of day is not a facsimile. The print output
        // was always correct (it never consulted the screen's appearance), so this was a
        // screen-only defect, and only a screenshot could catch it — every test passed and
        // the geometry oracle is colour-blind by design.
        NSColor.white.setFill()
        switch display {
        case .singlePage:
            // Job 396: the sheet itself grows to include CURRENT page's own bleed
            // headroom (same figure `intrinsicContentSize`/`layout()` already applied) —
            // still one seamless white sheet, just possibly a little taller at the top,
            // never a grey strip showing through above an oversized title's own ascender.
            let nominalTop = headroom(atPage: currentPageIndex)
            CGRect(x: 0, y: 0, width: page.width, height: page.height + nominalTop).fill()
            drawRunningLines(rendered: rendered, pageIndex: currentPageIndex,
                             pageOrigin: CGPoint(x: 0, y: nominalTop))
            drawPCLGraphics(rendered: rendered, pageIndex: currentPageIndex,
                            pageOrigin: CGPoint(x: 0, y: nominalTop))
            drawFootnoteBlock(rendered: rendered, pageIndex: currentPageIndex,
                              pageOrigin: CGPoint(x: 0, y: nominalTop))
        case .continuousScroll:
            for index in 0..<max(1, pageViews.count) {
                let rect = self.rect(ofPage: index)
                if rect.intersects(dirtyRect) {
                    rect.fill()
                    let nominalTop = pageTops.indices.contains(index) ? pageTops[index] : rect.origin.y
                    drawRunningLines(rendered: rendered, pageIndex: index,
                                     pageOrigin: CGPoint(x: 0, y: nominalTop))
                    drawPCLGraphics(rendered: rendered, pageIndex: index,
                                    pageOrigin: CGPoint(x: 0, y: nominalTop))
                    drawFootnoteBlock(rendered: rendered, pageIndex: index,
                                      pageOrigin: CGPoint(x: 0, y: nominalTop))
                }
            }
        }
    }

    /// Running heads/feet for one page — facsimile content, not a screen affordance, so
    /// (unlike `PageTextView`'s Show Invisibles overlay) this runs unconditionally: on
    /// screen, in print, and in a PDF built by printing this view. `Document Operations`'
    /// own "Save as PDF" for Printed style goes straight through `emitPDF` instead
    /// (`DocumentOperations.swift:139`), so this path and that one can never disagree about
    /// running-line CONTENT — both read `Page.headers`/`.footers` — only independently
    /// reproduce its placement (see `DocumentRenderer.runningLines`'s own citations).
    private func drawRunningLines(rendered: RenderedDocument, pageIndex: Int, pageOrigin: CGPoint) {
        guard rendered.runningLines.indices.contains(pageIndex) else { return }
        for running in rendered.runningLines[pageIndex] {
            // Job 228: `running.drawOriginOffset`, not `font.ascender` — `draw(at:)` still
            // goes through a real AppKit line-height decision, and `ascender` alone was a
            // hand-derived stand-in for it (see `RunningLine.drawOriginOffset`'s own doc
            // comment). That mismatch was the running-head drift job 223/226 kept finding on
            // every page from p2 on, on WORDSTAR/OLDTIMES/YOURWAY alike.
            // Job 489: `running.leadingOffset` — nonzero only for a line with its own
            // proportional font block whose leading whitespace was re-stamped onto the
            // Courier column grid rather than drawn (`RunningLine.leadingOffset`'s own doc
            // comment) — shifts the draw origin past exactly the width that skipped run
            // would have occupied, matching the engine's own skip-then-`Tj` behaviour.
            let point = NSPoint(
                x: rendered.textFrame.origin.x + CGFloat(running.leadingOffset),
                y: pageOrigin.y + CGFloat(running.baselineFromTop) - CGFloat(running.drawOriginOffset)
            )
            running.text.draw(at: point)
        }
    }

    /// Job 502: local page `index`'s own footnote block (dash separator, then each entry in
    /// `rendered.modernFootnoteEvents` order) — drawn directly onto the PAPER, like
    /// `drawRunningLines` just above, rather than through the shared `NSTextStorage`/
    /// `layoutManager` chain `PageTextView` flows body text through. It has to be: the
    /// reservation that made room for it (`reserveFootnoteBlock`) already shrank this page's
    /// own container so body text stops short of it, and drawing INTO that same container
    /// would put the footnote block back in the body's own reading order — exactly job 490's
    /// bug, one layer down. Positioned in the GAP `reserveFootnoteBlock` opened up: from the
    /// shrunk container's own real bottom (`textTop` + `textHeight`, the ACTUAL, possibly-
    /// reduced height `buildPages` gave this page) down to the page's original, unreduced
    /// bottom (`textTop` + `rendered.textFrame.size.height`) — the same rect a Printed page's
    /// footnote area would occupy, expressed in Modern's own per-page container terms.
    private func drawFootnoteBlock(rendered: RenderedDocument, pageIndex: Int, pageOrigin: CGPoint) {
        guard rendered.modernFootnoteBlocks.indices.contains(pageIndex) else { return }
        let entries = rendered.modernFootnoteBlocks[pageIndex]
        guard !entries.isEmpty else { return }
        let block = NSMutableAttributedString(attributedString: rendered.modernFootnoteSeparator)
        for entry in entries { block.append(entry) }
        let containerBottom = textTop(atPage: pageIndex) + textHeight(atPage: pageIndex)
        let fullBottom = textTop(atPage: pageIndex) + rendered.textFrame.size.height
        let rect = CGRect(
            x: rendered.textFrame.origin.x, y: pageOrigin.y + containerBottom,
            width: rendered.textFrame.size.width, height: max(0, fullBottom - containerBottom)
        )
        block.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// Job 490 (item 1, LJ6DTP title-top): a `.pctl` attachment glyph carrying
    /// `.printedPCLProgram` (`DocumentRenderer.pctlAdvanceAttachment`) — execute that
    /// control's own raw PCL program (`PrintedPCLGraphics.swift`) anchored at its real,
    /// laid-out position, ADDED to the PAPER canvas here rather than inside the owning
    /// `PageTextView` (same reasoning as `drawOversizedSelfPasses`'s own doc comment just
    /// below: LJ6DTP's page border draws OUTSIDE the text container's own margins, all the
    /// way to the paper edge — a view whose own bounds/clip ARE the text container cannot
    /// show ink past them).
    ///
    /// Coordinates: `layoutManager.enumerateLineFragments`'s own `rect`/`location(forGlyphAt:)`
    /// are CONTAINER-local; `textTop(atPage:)`/`rendered.textFrame.origin.x` (the same pair
    /// `drawRunningLines`/`frameForPage` already use to place a container within the page)
    /// convert that into PAGE-local before `pclGraphicRects` ever sees it — an ABSOLUTE PCL
    /// move addresses the PAPER's own top-left corner, not the container's, so executing the
    /// program in container-local coordinates would land an absolute fill wherever the
    /// container's own local origin happens to be instead (confirmed empirically: the
    /// border's own top rule landed at container-local y=20.4, well inside the text area's
    /// own top edge, not 20.4pt down from the real page top, before this fix).
    ///
    /// Job 495: routed through `pclRectsInIsolatedPass` (shared with
    /// `drawOversizedSelfPasses`'s own self-pass call just below, `drawPCLGraphicsOverlay`,
    /// and this file's test-harness mirror) rather than a hand-rolled walk — its own doc
    /// comment has the mechanism. ABSOLUTE-only programs (the border) ONLY — a RELATIVE one
    /// (page 4's checkerboard) draws from `drawPCLGraphicsOverlay` instead: THIS call site is
    /// UNDER every `PageTextView` in z-order, invisible for the border (drawn in the page's
    /// own margin, nothing else paints there) but genuinely covered for content sitting
    /// inside the text flow, which is exactly `pclRectsInIsolatedPass`'s own doc comment's
    /// diagnosis of job 490's real (not the originally-suspected anchor) cause.
    private func drawPCLGraphics(rendered: RenderedDocument, pageIndex: Int, pageOrigin: CGPoint) {
        guard !rendered.pclPrograms.isEmpty, pageViews.indices.contains(pageIndex) else { return }
        let textView = pageViews[pageIndex]
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage
        else { return }

        let originX = rendered.textFrame.origin.x
        let originY = textTop(atPage: pageIndex)
        let containerWidth = textContainer.size.width
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, effectiveGlyphRange, _ in
            for fill in pclRectsInIsolatedPass(
                manager: layoutManager, storage: textStorage, glyphRange: effectiveGlyphRange,
                fragment: rect, offset: CGPoint(x: originX, y: originY), containerWidth: containerWidth,
                pclPrograms: rendered.pclPrograms, includeRelative: false) {
                fill.offsetBy(dx: pageOrigin.x, dy: pageOrigin.y).fill()
            }
        }
    }

    /// Job 495 (Class 7, LJ6DTP.WS page 4's checkerboard): a RELATIVE PCL program's own
    /// counterpart to `drawPCLGraphics` above — same walk, same shared
    /// `pclRectsInIsolatedPass`, but called from `OversizedPassOverlayView.draw(_:)` (see
    /// that type's own citation, and `drawOversizedSelfPasses`'s doc comment just below for
    /// why an overlay subview is the ONLY way to paint on top of every `PageTextView`) so a
    /// relative program's own ink — usually sitting on an ordinary line squarely inside the
    /// text flow, unlike the border's own margin position — is not silently covered by
    /// whatever that line's real fragment paints at the same spot.
    ///
    /// Job 503 item 3: `includeAbsolute` now also `true` — `drawPCLGraphics`'s own doc
    /// comment's premise ("drawn in the page's own margin, nothing else paints there") is
    /// false for the RIGHT half of LJ6DTP's own border. `RenderedDocument.textFrame`'s own
    /// width is `pageWidth - metrics.left` ONLY (`DocumentRenderer.swift`'s own citation on
    /// that field) — i.e. the container's real frame runs from the LEFT margin all the way
    /// to the PAPER's own right edge, never narrowed to the document's declared `.rm`. The
    /// border's right edge sits well inside that span (measured: page 2, x≈293pt of a
    /// 612pt-wide page, comfortably left of the container's own right edge at 612pt) — so
    /// `PageTextView`'s own opaque background COVERS it for exactly the container's own
    /// vertical extent (the page's real body height), leaving only the slivers above/below
    /// the container (the top/bottom margins) visible — precisely the "visible near the top
    /// and bottom, missing through the middle" symptom. The border's LEFT edge (x≈9pt) never
    /// has this problem: it sits left of the container's own left edge (`metrics.left`)
    /// regardless. Drawing the absolute case from this topmost overlay too (redundantly
    /// covering `drawPCLGraphics`'s own now-partially-hidden draw underneath, harmless for an
    /// opaque solid fill at the identical position) fixes the cover-up without touching
    /// `textFrame`'s own width — a much larger, doc-comment-guarded change this fixture-scale
    /// fix has no need to risk.
    /// job-491 (C5): the page-canvas-only origin `drawPCLGraphicsOverlay` must add on top of
    /// `pclRectsInIsolatedPass`'s own `offset:` argument (which already carries this page's
    /// own margin into every fill it returns) — `viewOrigin` is `view.frame.origin`
    /// (`frameForPage`'s own doc comment: page position + margin, for both display modes),
    /// so subtracting `marginOrigin` back out reproduces `drawPCLGraphics`'s own page-only
    /// `pageOrigin` parameter convention (`(0, nominalTop)`/`(0, pageTops[index])`) exactly.
    /// Before this fix, `drawPCLGraphicsOverlay` used `viewOrigin` directly as its own
    /// "pageOrigin" — double-counting the margin `offset:` already applied, and landing
    /// LJ6DTP.WS page 4's checkerboard (the only relative-addressed content this function
    /// ever draws) a full margin-width too far right of the engine's own real position.
    static func pclOverlayPageOrigin(viewOrigin: CGPoint, marginOrigin: CGPoint) -> CGPoint {
        CGPoint(x: viewOrigin.x - marginOrigin.x, y: viewOrigin.y - marginOrigin.y)
    }

    func drawPCLGraphicsOverlay(_ dirtyRect: NSRect) {
        guard let rendered, !rendered.pclPrograms.isEmpty else { return }
        for (pageIndex, view) in pageViews.enumerated() {
            guard !view.isHidden, view.frame.intersects(dirtyRect) else { continue }
            guard let layoutManager = view.layoutManager, let textContainer = view.textContainer,
                  let textStorage = view.textStorage
            else { continue }
            let originX = rendered.textFrame.origin.x
            let originY = textTop(atPage: pageIndex)
            let pageOrigin = Self.pclOverlayPageOrigin(
                viewOrigin: view.frame.origin, marginOrigin: CGPoint(x: originX, y: originY))
            let containerWidth = textContainer.size.width
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, effectiveGlyphRange, _ in
                for fill in pclRectsInIsolatedPass(
                    manager: layoutManager, storage: textStorage, glyphRange: effectiveGlyphRange,
                    fragment: rect, offset: CGPoint(x: originX, y: originY), containerWidth: containerWidth,
                    pclPrograms: rendered.pclPrograms) {
                    fill.offsetBy(dx: pageOrigin.x, dy: pageOrigin.y).fill()
                }
            }
        }
    }

    /// Job 227: composite `RenderedDocument.oversizedSelfPasses` — an oversized base line's
    /// own natural (unbounded) content, LJ6DTP.WS's 72pt banner title and its `.lh .05"`
    /// shadow copy chief among them — at the PAPER level, not inside the owning
    /// `PageTextView`.
    ///
    /// Why not `PageTextView.drawOverprintPasses`, which already composites `.overprint`
    /// chain passes exactly this way: that view's own BOUNDS are the text CONTAINER
    /// (`layout()` above sets every page view's frame to `rendered.textFrame`), which is
    /// precisely the box a 72pt glyph's ascent does not fit in — a pass drawn inside that
    /// view gets its baseline positioned correctly and then silently clipped the moment its
    /// ink needs room the container never had, the same way the real inline glyph was
    /// before this job. This view's own bounds span the whole stacked-pages canvas, margins
    /// included, so a self-pass drawn HERE can bleed above its container the same way it
    /// bleeds into a page's top margin in the engine's own unbounded PDF canvas.
    ///
    /// Why a dedicated overlay subview (`overlayView`, `drawOversizedSelfPasses` is only
    /// ever called from `OversizedPassOverlayView.draw(_:)`) rather than drawing directly in
    /// `PagedDocumentView.draw(_:)` above: subviews ALWAYS composite on top of their
    /// superview's own drawing, regardless of call order — drawing a self-pass in THIS
    /// view's own `draw(_:)` would still end up UNDER every `PageTextView`'s own (blank,
    /// opaque-white-background) real fragment content wherever the two overlap. Only a
    /// subview positioned AFTER every `PageTextView` in the subview list (`setContent`
    /// re-adds `overlayView` last, every time) draws on top of them.
    ///
    /// Coordinates: `view.frame.origin` is exactly what `layout()` already computed for
    /// this page (`pageTop + text.origin.y`/`text.origin.x`), so translating a fragment's
    /// own CONTAINER-local rect by it gives this view's (and the overlay's, since they
    /// share a coordinate space) own local coordinates directly — no separate page-origin
    /// bookkeeping needed. The isolated pass is laid out unbounded (`isolatedLineLayout`,
    /// `PrintedVectorGraphics.swift`) and its own BASELINE (not merely its fragment's top
    /// edge — `RenderedDocument.baselineOffset`'s own doc comment on why top-alignment is
    /// only a good proxy for same-size content) is translated onto the target every
    /// ordinary line in that fragment's slot would sit on.
    /// Job 428: `pass`'s own resolved `.PIX` attachment height, or `nil` when `pass` carries
    /// no real image attachment (an ordinary oversized TEXT self-pass — a title, a knockout
    /// band). `drawOversizedSelfPasses` uses this to pick the image-specific top-anchored
    /// placement rule instead of the generic font-baseline one — see that call site's own
    /// doc comment for why the two need to differ.
    private static func imageSelfPassHeight(_ pass: NSAttributedString) -> CGFloat? {
        var height: CGFloat?
        pass.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pass.length)) { value, _, stop in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image,
                  image.size.width > 0, image.size.height > 0
            else { return }
            height = attachment.bounds.height
            stop.pointee = true
        }
        return height
    }

    /// Job 438: `pass`'s own RESERVED BAND height — `DocumentRenderer.pixAttachmentString`'s
    /// `reservedLeadPt` side channel (`attachment.bounds.origin.y`; see that call site's own
    /// doc comment for why this field is safe to reuse this way), or `nil` when `pass` carries
    /// no image attachment at all. `drawOversizedSelfPasses` uses this alongside
    /// `imageSelfPassHeight` to place an oversized image's TOP at its own reserved band's top
    /// (`PDFWriter.pageStream`'s real ground truth: "flush with the top of the RESERVED band,"
    /// not merely "flush with its own tiny AppKit fragment's top") rather than assuming the
    /// two coincide, which they only do when the document's declared reservation happens to
    /// equal the picture's real height.
    private static func imageSelfPassReservedLead(_ pass: NSAttributedString) -> CGFloat? {
        var reserved: CGFloat?
        pass.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pass.length)) { value, _, stop in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image,
                  image.size.width > 0, image.size.height > 0
            else { return }
            reserved = attachment.bounds.origin.y
            stop.pointee = true
        }
        return reserved
    }

    func drawOversizedSelfPasses(_ dirtyRect: NSRect) {
        guard let rendered, rendered.clipsLines, !rendered.oversizedSelfPasses.isEmpty else { return }
        for (pageIndex, view) in pageViews.enumerated() {
            guard !view.isHidden, rendered.oversizedSelfPasses.indices.contains(pageIndex) else { continue }
            let selfPasses = rendered.oversizedSelfPasses[pageIndex]
            guard selfPasses.contains(where: { $0 != nil }) else { continue }
            guard let layoutManager = view.layoutManager, let textContainer = view.textContainer else { continue }
            let pageOrigin = view.frame.origin
            // Job 503 item 3: an ABSOLUTE PCL program's own rects (LJ6DTP's border, on 4 of
            // this fixture's 8 pages sitting on the page's own OVERSIZED opening line —
            // `pclRectsInIsolatedPass`'s own job 495 doc comment) come back in PAGE-ONLY
            // coordinates (measured from the page's own top-left, no margin) — `pclGraphicRects`'
            // own doc comment: an absolute move OVERWRITES the running cursor outright, so
            // `anchorX`/`anchorY` (and therefore this call's own `offset:` argument) never
            // reach an absolute op at all. `pageOrigin` here is `view.frame.origin`, which
            // (`pclOverlayPageOrigin`'s own doc comment) already carries this page's MARGIN
            // in addition to its position — adding it directly would double-count the margin
            // exactly the way job-491 found and fixed for the checkerboard's own relative-
            // program overlay. Reusing that same fix's own utility here instead.
            let pageOnlyOrigin = Self.pclOverlayPageOrigin(
                viewOrigin: pageOrigin,
                marginOrigin: CGPoint(x: rendered.textFrame.origin.x, y: textTop(atPage: pageIndex)))
            let width = textContainer.size.width
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else { continue }
            var lineIndex = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragGlyphRange, _ in
                defer { lineIndex += 1 }
                guard lineIndex < selfPasses.count, let pass = selfPasses[lineIndex] else { return }
                guard let isolated = isolatedLineLayout(pass, width: width) else { return }
                let fragmentOrigin = NSPoint(
                    x: pageOrigin.x + fragmentRect.origin.x, y: pageOrigin.y + fragmentRect.origin.y)
                // Job 412: this fragment's OWN real baseline-within-fragment offset
                // (`layoutManager.location(forGlyphAt:).y`, the same quantity `Oracle
                // .structuralBodyLines`/every other geometry reader in this codebase asks
                // for), not the single document-wide `rendered.baselineOffset` constant —
                // once the base fragment's own TOP is pinned to the engine's grid (this
                // job's own `NSLayoutManagerDelegate`), asking for ITS real baseline
                // location directly reproduces the engine's own Y exactly; the shared
                // constant was only ever an approximation of that (job 269's own doc
                // comment), and stayed off by however much THIS fragment's own real K
                // differs from the constant — confirmed empirically via
                // `TitleAscenderTests.lj6dtpTitleTopAgreesWithEngine()` regressing 10.5pt
                // when the pin above changed which Y that approximation was measured from
                // without this fragment-local correction alongside it.
                // Job 428 (PREVIEW.WS caption regression), reworked job 438 (README/SCREEN
                // downward-bleed-over-body regression): an image self-pass's own real height
                // (`imageSelfPassHeight`, nil for an ordinary oversized TEXT pass — a title, a
                // knockout band) picks a DIFFERENT anchor than the generic fragment-baseline
                // rule below. `PDFWriter.pageStream`'s own image branch (`PDFWriter.swift`,
                // the ACTUALLY-LINKED checkout — job 427's own warning about the stale
                // top-level mirror applies here too) is the ground truth this ports: `let
                // reserved = line.lead ?? img.heightPt; let imgY = y + (reserved -
                // img.heightPt)` — an oversized picture draws flush with the TOP of its own
                // RESERVED BAND (this line's own `.lead`, exactly the gap an ordinary line of
                // text would have been given) and bleeds DOWNWARD by however much its real
                // height exceeds that band, never upward into whatever sits above it.
                //
                // `fragmentOrigin.y + fragmentK` is that reserved band's own BOTTOM edge in
                // this view's coordinates — the SAME quantity the `else` branch below already
                // uses directly as an ordinary oversized TITLE's target baseline, since a
                // title's real glyphs draw flush with exactly that position with no further
                // adjustment (its ascent bleeds upward past the band on its own, needing no
                // help from this function). An image's TOP, not its baseline, has to land at
                // the band's TOP instead — `bandBottom - reservedLead` — and its bottom is
                // `imageHeight` below that: ONE shared anchor (`bandBottom`), with the image
                // case applying the extra `(imageHeight - reservedLead)` delta that a title
                // never needs. That delta is exactly 0 when a document's declared reservation
                // happens to equal the picture's real height (PREVIEW.WS's shape, `imageHeight
                // ≈ reservedLead` — both ~74pt vs its own ordinary lead's close neighbours —
                // is what let job 428's simpler `fragmentOrigin.y` approximation pass there
                // even though it silently assumed `reservedLead == fragmentK`, not `==
                // imageHeight`; this rule is exact rather than coincidental for every case,
                // covering the SAME PREVIEW.WS caption-safety job 428 fixed for the identical
                // reason — the delta is still small there, nowhere near a full image height).
                // README.WS is the case that broke the coincidence: `reservedLead` (96pt, this
                // document's own generous gap before its title) is far larger than
                // `imageHeight` (73.9pt), so the OLD rule's implicit "reservedLead == fragmentK
                // (~9pt)" assumption bled the picture's bottom 62pt into the title below it;
                // this rule spends the real 96pt reservation instead, landing the picture (and
                // the clear run of paper beneath it) exactly where `pageStream` puts it.
                //
                // The generic `fragmentK`-based baseline assumes ascent/descent split the
                // way a real text glyph run does — true for an oversized TITLE (confirmed
                // via `TitleAscenderTests`), but not for a bare attachment run:
                // `NSLayoutManager` places an attachment-only unbounded line's own
                // "baseline" (`location(forGlyphAt:)`) at the very BOTTOM of its cell
                // regardless of `NSTextAttachment.bounds.origin` (confirmed empirically,
                // job 428 — the origin offset that shifts a MIXED text+attachment line's
                // ascent/descent split is silently ignored when the attachment is the
                // line's only content), so this anchors the image's BOTTOM (`targetBaseline`)
                // rather than its top — `bandBottom - reservedLead + imageHeight`, algebraically
                // the same "top at the band's top" position, `imageHeight` lower.
                let fragmentK = layoutManager.location(forGlyphAt: fragGlyphRange.location).y
                let bandBottom = fragmentOrigin.y + fragmentK
                let targetBaseline: CGFloat
                if let imageHeight = Self.imageSelfPassHeight(pass) {
                    let reservedLead = Self.imageSelfPassReservedLead(pass) ?? imageHeight
                    targetBaseline = bandBottom - reservedLead + imageHeight
                } else {
                    targetBaseline = bandBottom
                }
                let isolatedBaseline = isolated.fragmentRect.origin.y
                    + isolated.manager.location(forGlyphAt: isolated.glyphRange.location).y
                let offset = NSPoint(
                    x: fragmentOrigin.x - isolated.fragmentRect.origin.x,
                    y: targetBaseline - isolatedBaseline)
                // Register b31 (job 506, E2): LJ6DTP's masthead draws "LJ6DTP" black at
                // slot 0, then a colour4 (0.75 gray) "shadow" copy at slot 1, offset
                // down-right — two SEQUENTIAL self-passes in this same top-to-bottom walk,
                // not the bare-CR overprint mechanism. The engine now composites a
                // colour1-7 fill with Darken (`.lj6dtpDarkenColour`'s own doc comment) so
                // the gray copy never replaces the black ink it overlaps; this mirrors that
                // with the AppKit equivalent, `CGBlendMode.darken`, scoped to only the
                // glyphs this ONE pass draws (`saveGState`/`restoreGState` bracket it so it
                // never leaks into the next pass or any other drawing in this view). Checked
                // across the WHOLE pass, not just character 0: a title's own leading
                // filler spaces (the tabHMI-based indent job 503 fixed) carry no colour
                // attribute at all, so probing only the first character always missed the
                // real coloured run that starts after them.
                var wantsDarken = false
                if pass.length > 0 {
                    pass.enumerateAttribute(
                        .lj6dtpDarkenColour, in: NSRange(location: 0, length: pass.length)
                    ) { value, _, stop in
                        if (value as? Bool) == true {
                            wantsDarken = true
                            stop.pointee = true
                        }
                    }
                }
                if wantsDarken, let context = NSGraphicsContext.current {
                    context.saveGraphicsState()
                    context.compositingOperation = .darken
                    isolated.manager.drawGlyphs(forGlyphRange: isolated.glyphRange, at: offset)
                    context.restoreGraphicsState()
                } else {
                    isolated.manager.drawGlyphs(forGlyphRange: isolated.glyphRange, at: offset)
                }
                // Job 403: this self-pass's OWN cp437 graphics (a bare "█"-bar oversized line
                // has no text glyph at all, only vector fills) — before this job, only a
                // CHAIN CONTINUATION member (below) ever got `graphicCells`; the self-pass's
                // own content only ever got `drawGlyphs`, so an oversized line whose content
                // IS graphics-only painted nothing here (its glyph is the base-14 missing-
                // glyph placeholder `graphicCells`/`drawVectorGraphics`'s own top doc comment
                // names, and nothing ever erased+refilled it, since this overlay draws
                // AFTER `PageTextView.draw` already finished). Same erase-then-fill sequence
                // every other vector-graphics call site in this file uses.
                for cell in graphicCells(manager: isolated.manager, storage: isolated.storage,
                                          glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect) {
                    NSColor.white.setFill()
                    cell.eraseFrame.offsetBy(dx: offset.x, dy: offset.y).fill()
                    for fill in cell.fills {
                        fill.offsetBy(dx: offset.x, dy: offset.y).fill()
                    }
                }
                // Job 495: this self-pass's OWN PCL control (LJ6DTP's border on its 4
                // oversized page-open lines) — see `pclRectsInIsolatedPass`'s own doc
                // comment for why this line's REAL fragment (`drawPCLGraphics`'s own walk)
                // never sees it.
                //
                // Job 503 item 3: split absolute/relative, same as `drawPCLGraphics`/
                // `drawPCLGraphicsOverlay` — a RELATIVE program's own anchor already folds
                // `offset` in (`pclRectsInIsolatedPass`'s own `anchorX`/`anchorY` computation),
                // so `fill.fill()` alone is correct for it; an ABSOLUTE program's rects
                // (`pageOnlyOrigin`'s own doc comment above) need that page's own canvas
                // position added instead — `offset` was never in that coordinate space for
                // an absolute op, which is why the border was drawing far off any visible
                // page here (pages 5-8, this fixture's own 4 oversized-line occurrences)
                // even though the SAME program renders correctly from `drawPCLGraphics`'s
                // ordinary-line walk (pages 1-4).
                for fill in pclRectsInIsolatedPass(
                    manager: isolated.manager, storage: isolated.storage,
                    glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect,
                    offset: offset, containerWidth: width, pclPrograms: rendered.pclPrograms,
                    includeAbsolute: false) {
                    fill.fill()
                }
                for fill in pclRectsInIsolatedPass(
                    manager: isolated.manager, storage: isolated.storage,
                    glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect,
                    offset: offset, containerWidth: width, pclPrograms: rendered.pclPrograms,
                    includeRelative: false) {
                    fill.offsetBy(dx: pageOnlyOrigin.x, dy: pageOnlyOrigin.y).fill()
                }

                // Job 246: this slot's OWN `.overprint` chain continuation (if any) — the
                // engine paints a chain base-then-passes, in one order, so the closing
                // member of an oversized chain (LJ6DTP.WS's "Black Text on a Gray
                // Background" heading, `page[51]`, chained onto `page[50]`'s 28pt gray
                // band above) must land HERE, right after the self-pass, not in
                // `PageTextView.drawOverprintPasses` (which now skips this exact index —
                // see `PagedDocumentView.makePageView`'s own job 246 doc comment) — that
                // view draws UNDER this overlay unconditionally, which painted the band
                // over the text instead of under it.
                guard rendered.overprintPasses.indices.contains(pageIndex),
                      rendered.overprintPasses[pageIndex].indices.contains(lineIndex)
                else { return }
                for chainPass in rendered.overprintPasses[pageIndex][lineIndex] {
                    guard let chainIsolated = isolatedLineLayout(chainPass, width: width) else { continue }
                    let chainBaseline = chainIsolated.fragmentRect.origin.y
                        + chainIsolated.manager.location(forGlyphAt: chainIsolated.glyphRange.location).y
                    let chainOffset = NSPoint(
                        x: fragmentOrigin.x - chainIsolated.fragmentRect.origin.x,
                        y: targetBaseline - chainBaseline)
                    chainIsolated.manager.drawGlyphs(forGlyphRange: chainIsolated.glyphRange, at: chainOffset)
                    for cell in graphicCells(manager: chainIsolated.manager, storage: chainIsolated.storage,
                                              glyphRange: chainIsolated.glyphRange, fragment: chainIsolated.fragmentRect) {
                        NSColor.white.setFill()
                        cell.eraseFrame.offsetBy(dx: chainOffset.x, dy: chainOffset.y).fill()
                        for fill in cell.fills {
                            fill.offsetBy(dx: chainOffset.x, dy: chainOffset.y).fill()
                        }
                    }
                }
            }
        }
    }
}

/// b28 note 11 (Jon's ruling: SCRIPT.WS's Modern view must break the page just before the
/// screenplay page-number marker, e.g. the "1." ahead of a scene's slugline): the idiomatic
/// TextKit 1 way to force `NSLayoutManager` to end the CURRENT container and continue laying
/// text out in the NEXT one at a chosen character offset — there is no other API to request a
/// break mid-flow the way Printed style's own library pagination already dictates its page
/// boundaries (`buildExplicitPages`, this file's own sibling method, sidesteps the question
/// entirely by pre-sizing each container to its own known page instead).
///
/// Returning a ZERO rect for any character at or past `forcedBreakOffset` is what AppKit
/// reads as "this container has no room here" — the SAME signal an ordinary container running
/// out of natural vertical space already gives it, so the overflow lands in the next
/// container the exact way any other overflow does. No separate "forced break" concept exists
/// anywhere else in this file: `layout()`, `applyDisplayMode()`, `rect(ofPage:)`, etc. all
/// still just ask each container what it holds.
///
/// `forcedBreakOffset` is `nil` on the overwhelming majority of containers — every real
/// document has at most a handful of screenplay page markers, most containers have none at
/// all — and `PagedDocumentView.buildPages` only ever sets it to a break that has not YET been
/// reached, so a break offset that falls well past what a container would have filled
/// naturally has NO effect here: the container simply runs out of its own room first, exactly
/// as it always did before this job.
private final class BreakingTextContainer: NSTextContainer {
    var forcedBreakOffset: Int?

    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int,
                                    writingDirection baseWritingDirection: NSWritingDirection,
                                    remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        if let forcedBreakOffset, characterIndex >= forcedBreakOffset {
            return .zero
        }
        return super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                       writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

/// Job 412 (Jon's ruling on job 408's decision brief, option (a) — "pin it"): overrides
/// AppKit's own proposed line-fragment position with the engine's own grid, for every
/// fragment `RenderedDocument.pinnedBaselines` covers — see that field's own doc comment
/// for the full job 411 root-cause mechanism this replaces (a per-content-class baseline
/// offset AppKit itself computes correctly WITHIN a fragment, but never corrects for
/// ACROSS a content-class transition, since it stacks fragment tops from the fragment
/// before rather than from any shared external grid).
extension PagedDocumentView: NSLayoutManagerDelegate {
    /// Fires once per real line fragment as the typesetter lays it out — possibly more than
    /// once for the SAME fragment within one `setContent` call (`buildExplicitPages`'s own
    /// probe-container pass, then again once laid into the real per-page containers), and
    /// in whatever order AppKit chooses to (re)lay text out. A CHARACTER-OFFSET lookup
    /// (`pinnedBaselines`'s own key, not fragment call order) is what stays correct
    /// regardless — document position is the one thing that never changes.
    ///
    /// Moves the fragment's POSITION (`lineFragmentRect`/`lineFragmentUsedRect`'s own
    /// `origin.y`, shifted together by the same delta so they stay aligned) AND overwrites
    /// `baselineOffset` itself — job 412's original design left `baselineOffset` untouched,
    /// trusting AppKit's own LIVE per-fragment report to place the baseline correctly within
    /// the repositioned fragment; job 413 replaces that live report with
    /// `RenderedDocument.pinnedBaselines`'s own `PinnedBaseline.k`, a value computed once,
    /// off-screen, in `DocumentRenderer` (see that field's own doc comment for the two job
    /// 412/413 defects a live per-pass report caused: a superscript run inside the line
    /// perturbing it, and windowed-vs-windowless AppKit disagreeing on it by a hair) — so the
    /// out-param has to be overwritten to match, or the glyphs AppKit actually draws would
    /// land somewhere `delta` below never assumed. Both rects' HEIGHT stays completely
    /// untouched: `buildExplicitPages`'s container-height measurement reads these same rects
    /// and stays correct (a page's own content still costs exactly the sum of its own
    /// fragments' pinned-height paragraph styles, unrelated to where the group as a whole
    /// sits) — only WHERE the fragment sits, and where its own baseline sits within it,
    /// change; how TALL it is does not.
    ///
    /// Returns `false` (AppKit's own proposal stands, unmodified) for any fragment this
    /// document's own `pinnedBaselines` doesn't cover at all — Modern style and the Show
    /// Invisibles screen path both hand back an EMPTY dictionary (see
    /// `RenderedDocument.pinnedBaselines`'s own doc comment), so this delegate is a
    /// complete no-op for both BY CONSTRUCTION (the empty-dictionary guard below), not by
    /// any style check in this method.
    /// `nonisolated`, bridged back to the main actor via `MainActor.assumeIsolated` — the
    /// SAME "known safe, Swift can't prove it across an old un-annotated ObjC delegate
    /// protocol" shape `DocumentRenderer.invisibleMarkColour`'s own `nonisolated(unsafe)`
    /// doc comment already establishes for this codebase (there is no real data race: this
    /// app is single-window/single-document per `layoutManager`, and `NSLayoutManager` only
    /// ever calls its delegate synchronously from whatever thread owns it, always the main
    /// thread here — `allowsNonContiguousLayout` is off and nothing in this app touches a
    /// `layoutManager`/`storage` off-main). `NSLayoutManagerDelegate` itself carries no
    /// actor annotation (a pre-concurrency ObjC protocol), so a plain (non-`nonisolated`)
    /// implementation on an otherwise MainActor-inferred `NSView` subclass compiles fine
    /// under this target's own default actor isolation but not under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (`SoftReturnQuickLook`/
    /// `SoftReturnThumbnail`, which also compile this same file — job 247/`Quick
    /// LookNativeRenderer`'s own "every viewing surface, same pipeline" doc comment) —
    /// `nonisolated` here is what makes the ONE implementation correct for every target
    /// that links it, rather than diverging behavior (or a build failure) by target.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                    shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                                    baselineOffset: UnsafeMutablePointer<CGFloat>,
                                    in textContainer: NSTextContainer,
                                    forGlyphRange glyphRange: NSRange) -> Bool {
        // Only PLAIN, `Sendable` data (a `Dictionary`/`CGFloat`/`Bool`, all value types)
        // crosses back OUT of the actor-isolated closure below — the non-`Sendable` AppKit
        // pointer parameters this method itself owns (`lineFragmentRect` et al.) are
        // read/written entirely out here, in this `nonisolated` scope, never captured INTO
        // the closure. Capturing them there is what produced the "sending risks causing
        // data races" diagnostic this shape avoids: `MainActor.assumeIsolated`'s own
        // closure crossing an isolation boundary is fine for VALUES: it is not fine for
        // pointers the region checker cannot prove stay only on one side of that boundary.
        // `ObjectIdentifier` (a `Sendable` value type wrapping a pointer), not `textContainer`
        // itself, is what crosses into the closure below — the same "only plain values, never
        // the AppKit object itself" discipline this method's own top doc comment already
        // establishes for the pointer parameters; capturing `textContainer` (a class instance,
        // not provably confined) directly produced the identical "sending risks causing data
        // races" diagnostic those pointers did.
        let textContainerID = ObjectIdentifier(textContainer)
        let pinned: (baselines: [Int: PinnedBaseline], perPageTextTop: [Double],
                     fallbackTextTop: Double, containerPageIndex: Int?)? = MainActor.assumeIsolated {
            // Job 412: the probe is ONE container spanning the WHOLE document — `entry.y`
            // resets to `firstBaseline` at the start of EVERY page (see `RenderedDocument
            // .pinnedBaselines`'s own doc comment), so pinning it here would make page 2's
            // own first fragment jump BACKWARD and overlap page 1's real content in this
            // one shared coordinate space, corrupting the typesetter's own incremental
            // layout for everything after (confirmed empirically — a spurious/misassigned
            // fragment crossed a page boundary when this guard was absent; a later attempt
            // to pin the probe too, using a monotonic per-page Y band instead, ALSO
            // regressed several previously-clean fixtures by consistently one line per
            // page boundary, root cause not fully isolated before the simpler unpinned
            // probe + `RenderedDocument.pinnedPageBottoms` combination — below — proved
            // reliable across the full fixture set). This is why the probe stays UNPINNED:
            // its own measurement is only a FALLBACK/floor now, not authoritative — a
            // pinned page's real height comes from `pinnedPageBottoms` instead.
            guard !isMeasuringProbeContainer,
                  let rendered, !rendered.pinnedBaselines.isEmpty else { return nil }
            return (rendered.pinnedBaselines, rendered.perPageTextTop, Double(rendered.textFrame.origin.y),
                    containers.firstIndex(where: { ObjectIdentifier($0) == textContainerID }))
        }
        guard let pinned, let containerPageIndex = pinned.containerPageIndex else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // A fragment whose OWN intended page (`entry.page`, from `DocumentRenderer`'s own
        // per-line page assignment) doesn't match the REAL container it's being asked to
        // lay into is AppKit trying to OVERFLOW this page's excess content into the next
        // container — exactly the signal a pinned Y would otherwise HIDE: pinning always
        // proposes a small, in-bounds-looking position (a new page's own first line pins
        // near `firstBaseline`, i.e. near container-local Y 0), so AppKit never sees the
        // "this doesn't fit" natural overflow it needs to actually break to a new
        // container — confirmed empirically (job 412): without this guard, one real
        // container on `LJ6DTP.WS` silently swallowed two entire pages' worth of fragments
        // (88 instead of the expected 44), each new page's content pinning right back to
        // the container's own top instead of overflowing out of it. Returning `false` here
        // lets AppKit's own UNPINNED proposal stand for this one fragment, restoring the
        // natural "doesn't fit, break here" signal — the pin resumes on the NEXT container,
        // where this same fragment's `entry.page` finally matches.
        guard let entry = pinned.baselines[charRange.location], entry.page == containerPageIndex else { return false }
        // `k`: this fragment's own DETERMINISTIC baseline-from-fragment-TOP offset —
        // `PinnedBaseline.k` (job 413; see its own doc comment), not the delegate's own
        // `baselineOffset` out-param job 412 originally read here. Same "distance down from
        // the fragment's own top" quantity every OTHER geometry computation in this file
        // calls `K` (`DocumentRenderer.firstBaselineOffset`'s own `location(forGlyphAt: 0)
        // .y`) — using it directly, with no inversion, is what makes this fragment's own
        // real `location(forGlyphAt:)` (read by every caller downstream, including
        // `Oracle.structuralBodyLines`) land the baseline exactly at `targetY` below, once
        // `baselineOffset.pointee` is overwritten to match (below) so AppKit's own real
        // drawing baseline is THIS `k`, not whatever it would have proposed live.
        let k = CGFloat(entry.k)
        // Job 427: THIS page's own container-to-paper anchor
        // (`pinned.perPageTextTop[containerPageIndex]`, `DocumentRenderer.renderPrinted`'s
        // per-page `pageFirstBaseline - normalBaselineOffset`), not a single shared one —
        // converting `entry.y` (absolute, measured from THIS PAGE's own paper top, reset
        // every page, and itself now built from this SAME page's own `.mt`/`.mb` when it
        // declares one) into this container's own LOCAL coordinate system, where `layout()`
        // above places container-local Y = 0 at exactly that same page's own text top
        // (`view.frame.origin.y` is `textTop(atPage:)` plus a page-level constant, never a
        // function of fragment content). Falls back to `pinned.fallbackTextTop` for a page
        // index the array somehow doesn't cover — defensive only, `renderPrinted` always
        // sizes `perPageTextTop` to `pages.count`, the same count `containers` has here.
        let pageTextTop = pinned.perPageTextTop.indices.contains(containerPageIndex)
            ? pinned.perPageTextTop[containerPageIndex] : pinned.fallbackTextTop
        let targetY = entry.y - pageTextTop
        let delta = CGFloat(targetY) - k - lineFragmentRect.pointee.origin.y
        lineFragmentRect.pointee.origin.y += delta
        lineFragmentUsedRect.pointee.origin.y += delta
        // Overwritten unconditionally, even when `delta == 0`: AppKit's own LIVE proposal
        // for this out-param can still differ from `k` (that live/deterministic gap is
        // exactly what job 413 exists to remove) independent of whether the rect itself
        // needed to move.
        baselineOffset.pointee = k
        return true
    }
}

/// Job 227: a subview whose sole job is drawing `PagedDocumentView.drawOversizedSelfPasses`
/// ABOVE every `PageTextView` — see that method's own doc comment for why compositing order
/// requires a dedicated subview rather than either `PagedDocumentView`'s own background
/// `draw(_:)` or `PageTextView` itself. Transparent to hit-testing (`hitTest` always `nil`)
/// so it never steals clicks, selection drags, or scrolling from the views underneath.
private final class OversizedPassOverlayView: NSView {
    weak var owner: PagedDocumentView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        owner?.drawOversizedSelfPasses(dirtyRect)
        owner?.drawPCLGraphicsOverlay(dirtyRect)
    }
}

/// One page's text. Job 256 (Show Invisibles part 2/4): this view USED TO draw a margin
/// arrow overlay for View ▸ Show Invisibles (`drawSoftReturnMarkers`, on top of the glyphs
/// after `super.draw`, gated on `isDrawingToScreen` so it could never ride into
/// `RenderedDocument.text` and leak into print/export). That is gone — invisible ink is now
/// real text baked into a SEPARATE `RenderedDocument` (`DocumentRenderer
/// .renderPrintedAnnotated`, screen-only via `renderWithInvisibles`), so this view draws
/// exactly the same glyphs regardless of the toggle; screen-only-ness is enforced one layer
/// up, at which `RenderedDocument` gets requested, not here.
private final class PageTextView: NSTextView {
    /// Job 211: `RenderedDocument.clipsLines` for this page — gates the vector-graphics
    /// overlay below, same convention `runningLines` already uses (Modern
    /// reflows cp437 glyphs as plain text; see `PrintedVectorGraphics.swift`'s top comment).
    var isPrintedStyle = false
    /// Job 224: this page's `RenderedDocument.overprintPasses[pageIndex]` — one entry per
    /// line fragment (same indexing as `softLineFlags`), each a (possibly empty) list of
    /// extra `.overprint`-chained `PageLine`s sharing that fragment's baseline. See
    /// `drawOverprintPasses` below.
    var overprintPasses: [[NSAttributedString]] = []
    /// `RenderedDocument.baselineOffset` — see `drawOverprintPasses`'s job 246 doc comment
    /// for why it, not the real fragment's own raw origin, is the chain's shared baseline.
    var baselineOffset: CGFloat = 0
    /// Job 460 (step 4): whether `draw(_:)` has fired since `PagedDocumentView.applyDisplayMode`
    /// last made this view visible — diagnostic only, read by that method's own
    /// `logPageDiagnostics`. Reset to `false` there at the moment a hidden page goes visible, so
    /// a `SRDiagnostics=1` log line answering `didDraw=NO` means exactly "AppKit has not painted
    /// this page since it became current," not merely "has never painted it, ever."
    var didDrawSinceShown = false

    override func draw(_ dirtyRect: NSRect) {
        didDrawSinceShown = true
        super.draw(dirtyRect)
        drawVectorGraphics(dirtyRect)
        drawOverprintPasses(dirtyRect)
    }

    /// Job 211 (b11 leg 3b): cp437 box/shade/block glyphs as vector fills — see
    /// `PrintedVectorGraphics.swift`'s top doc comment for the port citation and the
    /// architecture reasoning (real AppKit glyph geometry, not a `DocumentRenderer`-side
    /// precomputed Y). UNLIKE `drawSoftReturnMarkers` above, this is facsimile CONTENT, not
    /// a screen affordance — no `isDrawingToScreen` guard, same reasoning as
    /// `PagedDocumentView.drawRunningLines`: it belongs on paper too, for the SAME reason a
    /// running head does, since `makePrintOperation` prints this view's own draw path
    /// (unlike Printed-style PDF export, which goes straight through `emitPDF` and never
    /// touches this view at all — that path already draws real vector ops perfectly).
    private func drawVectorGraphics(_ dirtyRect: NSRect) {
        guard isPrintedStyle else { return }
        guard let layoutManager, let textContainer, let textStorage else { return }

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, effectiveGlyphRange, _ in
            guard rect.intersects(dirtyRect) else { return }
            for cell in graphicCells(manager: layoutManager, storage: textStorage,
                                      glyphRange: effectiveGlyphRange, fragment: rect) {
                NSColor.white.setFill()
                cell.eraseFrame.fill()
                for fill in cell.fills {
                    fill.fill()
                }
            }
        }
    }

    /// Job 224: composite every `.overprint`-chained `PageLine` `DocumentRenderer` captured
    /// for this fragment (`RenderedDocument.overprintPasses`, `overprintPasses` above)
    /// directly onto that fragment's own real glyph geometry — LJ6DTP's white-on-black
    /// knockouts and flush-right two-pass bars, previously laid out as their own separate
    /// (if `nearZeroLead`-tall) fragments, which is what pushed the fixture one whole page
    /// past the engine's own count (see `DocumentRenderer.renderPrinted`'s own doc comment
    /// on `overprintPasses` for the pagination arithmetic this replaces).
    ///
    /// Each pass is laid out in ISOLATION (`isolatedLineLayout`, `PrintedVectorGraphics.swift`
    /// — the same "unbounded, freshly-built `NSLayoutManager`" technique
    /// `DocumentRenderer.measuredHeight`/`firstBaselineOffset` already use and job 202 already
    /// proved accurate) rather than inserted into this view's own shared `layoutManager` —
    /// there is no fragment for it to occupy there at all, by design. `offset` is the delta
    /// between that isolated layout's own fragment origin and the REAL base fragment this
    /// pass shares a baseline with; translating by it is what lands the pass exactly on that
    /// baseline, not merely near it. Passes draw in DOCUMENT ORDER (the array's own order,
    /// `DocumentRenderer.renderPrinted`'s `(i + 1...j).map`), matching the engine's own
    /// painter's-model compositing (`PDFWriter.swift`'s content stream: later ops paint over
    /// earlier ones at the same position) — a bar's own two flush-right passes land in the
    /// order that closes the bar, and the knockout text (always last in the chain) draws on
    /// top of both.
    ///
    /// Glyphs before cp437 fills, per pass — same order `drawVectorGraphics` already uses for
    /// the base fragment (`super.draw` before `drawVectorGraphics` above): a pass's own
    /// missing-glyph placeholder for any box/shade/block character it carries must be erased
    /// and refilled AFTER that pass's glyphs are drawn, not before.
    ///
    /// Job 227 does NOT route an oversized base line's own natural content through here —
    /// this view's own bounds equal the text CONTAINER, which is exactly the box a 72pt
    /// glyph does not fit in; a pass drawn here can align its baseline correctly and still
    /// get silently clipped by this view's own frame the moment its ascent needs room the
    /// container never had. `PagedDocumentView.drawOversizedSelfPasses` handles that case at
    /// the PAPER level instead, where there is room above the container to bleed into (the
    /// same margin a tall glyph bleeds into in the engine's own unbounded PDF canvas). This
    /// function stays exactly what job 224 shipped.
    /// Job 246 (p6-knockout): aligns each pass by BASELINE (`self.baselineOffset`, the same
    /// `RenderedDocument.baselineOffset` `PagedDocumentView.drawOversizedSelfPasses` already
    /// anchors to), not by raw fragment-ORIGIN subtraction. The two agree exactly when base
    /// and pass share one pinned line height (every case this shipped against before this
    /// job), but diverge when a pass is `.sup`/`.sub`-styled TEXT: `DocumentRenderer
    /// .attributedRun`'s job 246 fix stops adding a baseline RISE to a graphic/cp437-block
    /// span (the library never rises one either — only shrinks it), but a plain-TEXT
    /// sup/sub pass still legitimately carries a rise, and sits its own glyphs off its
    /// isolated fragment's top by a different amount than the base's glyphs sit off
    /// theirs — fragment-origin alignment silently assumed those two amounts were equal.
    /// LJ6DTP.WS's "PRETTY NEAT, HUH?" chain (`page[39..41]`) is this fixture's case.
    ///
    /// A chain whose BASE is itself oversized (`DocumentRenderer.lineExceedsFragment` —
    /// "Black Text on a Gray Background"'s 28pt band, `page[50]`) is NOT handled here at
    /// all any more: `self.overprintPasses` comes pre-filtered by `PagedDocumentView
    /// .makePageView` to exclude any index with a real `oversizedSelfPasses` entry, and
    /// `drawOversizedSelfPasses` draws that index's passes itself, right after its own
    /// self-pass — see that method's own job 246 doc comment for why painting them here
    /// (this view draws UNDER the self-pass overlay unconditionally) put the closing
    /// heading text under its own gray band instead of over it.
    private func drawOverprintPasses(_ dirtyRect: NSRect) {
        guard isPrintedStyle, !overprintPasses.isEmpty else { return }
        guard let layoutManager, let textContainer else { return }
        let width = textContainer.size.width

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineIndex = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragGlyphRange, _ in
            defer { lineIndex += 1 }
            guard lineIndex < self.overprintPasses.count else { return }
            let passes = self.overprintPasses[lineIndex]
            guard !passes.isEmpty, fragmentRect.intersects(dirtyRect) else { return }
            // Job 412: this fragment's OWN real baseline-within-fragment offset, not the
            // single document-wide `self.baselineOffset` constant — see
            // `PagedDocumentView.drawOversizedSelfPasses`'s own job 412 doc comment for
            // why, once the base fragment's own TOP is pinned to the engine's grid, only
            // asking AppKit for THIS fragment's real baseline location reproduces the
            // engine's own Y exactly.
            let baseBaseline = fragmentRect.origin.y + layoutManager.location(forGlyphAt: fragGlyphRange.location).y
            for pass in passes {
                guard let isolated = isolatedLineLayout(pass, width: width) else { continue }
                let passBaseline = isolated.fragmentRect.origin.y
                    + isolated.manager.location(forGlyphAt: isolated.glyphRange.location).y
                let offset = NSPoint(
                    x: fragmentRect.origin.x - isolated.fragmentRect.origin.x,
                    y: baseBaseline - passBaseline)
                isolated.manager.drawGlyphs(forGlyphRange: isolated.glyphRange, at: offset)
                for cell in graphicCells(manager: isolated.manager, storage: isolated.storage,
                                          glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect) {
                    NSColor.white.setFill()
                    cell.eraseFrame.offsetBy(dx: offset.x, dy: offset.y).fill()
                    for fill in cell.fills {
                        fill.offsetBy(dx: offset.x, dy: offset.y).fill()
                    }
                }
            }
        }
    }

    /// Job 258 (Show Invisibles part 4/4, edge sweep): the spec's own default — Cmd-C
    /// copies the document's own text, not the invisible-ink marks Show Invisibles draws
    /// alongside it (dot commands, comments, style toggles, soft/hard-return glyphs,
    /// page-break origin). The marks are real characters in the same `NSTextStorage` every
    /// page view shares (this file's top doc comment), tagged `.invisibleMarkRun` at the
    /// point they're built (`DocumentRenderer.markRun`) — stripping by that attribute is
    /// what makes this cheap, no separate "what's a mark" derivation needed here.
    ///
    /// Falls back to `super.copy(_:)` whenever there is nothing to filter (no storage, no
    /// selection), so plain-text-path Cmd-C (Show Invisibles off, or any selection with no
    /// marks in it) is byte-for-byte what `NSTextView` already did before this job.
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return super.copy(sender) }
        let ranges = selectedRanges.compactMap { $0 as? NSRange }.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return super.copy(sender) }

        let filtered = NSMutableString()
        for range in ranges {
            storage.enumerateAttribute(.invisibleMarkRun, in: range, options: []) { value, subrange, _ in
                guard (value as? Bool) != true else { return }
                filtered.append(storage.attributedSubstring(from: subrange).string)
            }
        }
        guard filtered.length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(filtered as String, forType: .string)
    }
}
