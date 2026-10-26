import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

extension PagedDocumentView {
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
    func buildExplicitPages(for rendered: RenderedDocument, width: CGFloat, firstPages: Int? = nil,
                                    probe: ExplicitProbe? = nil) {
        let lineCounts = rendered.softLineFlags.map(\.count)
        guard !lineCounts.isEmpty else { return }
        // A RENDER THAT STATES NO COLUMNS HAS ONE PER PAGE — see the page loop below.
        let columnCountsByPage = rendered.pageColumnFragmentCounts.isEmpty
            ? lineCounts.map { [$0] }
            : rendered.pageColumnFragmentCounts

        // A RENDER THAT PINS EVERY PAGE NEEDS NO PROBE (batch 26, #271 M7). A pinned column's
        // container height comes from `RenderedDocument.pinnedPageBottoms` and overrides the
        // probe's figure outright (job 412, below), so when every column of every page is pinned
        // the probe — a layout of the whole flow, the larger half of laying out a long document —
        // decides nothing. Then each page's containers can be built on their own, in order, and a
        // window can build the first few now and the rest on later turns (`layOutMorePages`).
        // `renderNative` pins every page; the Show Invisibles and table-of-contents renders pin
        // none and keep the probe.
        let everyPagePinned = columnCountsByPage.indices.allSatisfy { page in
            rendered.pinnedPageBottoms.indices.contains(page)
                && rendered.pinnedPageBottoms[page].count >= columnCountsByPage[page].count
        }
        if everyPagePinned {
            pendingPages = .explicit(next: 0, columnCountsByPage: columnCountsByPage, width: width,
                                     cursor: 0, fragmentTops: [], fragmentBottoms: [])
            addExplicitPages(count: firstPages ?? .max, deadline: nil)
            return
        }
        // Batch 27: the probe measured already, offscreen (`ProbeMeasurement`): the pages from it, a few at a time.
        if let probe {
            pendingPages = .explicit(next: 0, columnCountsByPage: columnCountsByPage, width: width,
                                     cursor: 0, fragmentTops: probe.fragmentTops, fragmentBottoms: probe.fragmentBottoms)
            addExplicitPages(count: firstPages ?? .max, deadline: nil)
            return
        }

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

        // ONE CONTAINER PER COLUMN PER PAGE (item 19, Jon's ruling 2026-09-10).
        //
        // `pageColumnFragmentCounts` is the model's own answer for how many fragments each
        // of a page's newspaper columns contributes, so each container is sized to its own
        // column's content rather than its page's. On an ordinary page there is exactly one
        // column and this is what it always was.
        //
        // Every container is FULL PAGE WIDTH, not column width: a line already carries its
        // own column's left edge as a paragraph indent (`extraLeftPt`, from the engine's own
        // `PageLine.left`), so the text lands in its column without this having to know any
        // x at all. Only the HEIGHT differs per column, and the height is what stops one
        // column's spare room being filled with the next page's content.
        // A RENDER THAT STATES NO COLUMNS HAS ONE PER PAGE. `renderNativeAnnotated` (Show
        // Invisibles) and `ExportEngine`'s synthesized TOC page both build a
        // `RenderedDocument` without this field, the same way they build without
        // `pinnedBaselines`; without this fallback they got no containers and therefore no
        // pages at all, which is what turned every Show Invisibles and evidence-sheet
        // lookup into `noMatchingPage`.
        var cursor = 0
        for (pageIndex, columnCounts) in columnCountsByPage.enumerated() {
            buildExplicitPage(pageIndex, columnCounts: columnCounts, rendered: rendered, width: width,
                              fragmentTops: fragmentTops, fragmentBottoms: fragmentBottoms, cursor: &cursor)
        }
    }

    /// Batch 26: the Native pages `pendingPages` still names, from the next, up to `count` of them or
    /// until `deadline` passes — at least one a call. Only a render that pins every page gets here, so
    /// there is no probe to index.
    func addExplicitPages(count: Int, deadline: UInt64?) {
        guard case .explicit(var next, let columnCountsByPage, let width, var cursor, let tops, let bottoms)? = pendingPages,
              let rendered else { return }
        var added = 0
        while next < columnCountsByPage.count, added < count {
            buildExplicitPage(next, columnCounts: columnCountsByPage[next], rendered: rendered, width: width,
                              fragmentTops: tops, fragmentBottoms: bottoms, cursor: &cursor)
            next += 1
            added += 1
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }
        pendingPages = next < columnCountsByPage.count
            ? .explicit(next: next, columnCountsByPage: columnCountsByPage, width: width,
                        cursor: cursor, fragmentTops: tops, fragmentBottoms: bottoms) : nil
    }

    /// One page's containers and views, one per newspaper column — the body of `buildExplicitPages`'
    /// page loop. `fragmentTops`/`fragmentBottoms` are the unpinned probe's measurement, read at
    /// `cursor`; empty when every page is pinned.
    private func buildExplicitPage(_ pageIndex: Int, columnCounts: [Int], rendered: RenderedDocument, width: CGFloat,
                                   fragmentTops: [CGFloat], fragmentBottoms: [CGFloat], cursor: inout Int) {
        // Float-safety margin only — the height itself is already the real AppKit
        // measurement, not a second isolated guess. Same 0.5pt this codebase's own
        // oracles already treat as "on the grid" (`GeometryOracleTests.swift`).
        let epsilon: CGFloat = 0.5
        // PAGE-LOCAL, unlike `cursor`: `overprintPasses`/`oversizedSelfPasses`/
        // `graphicCellRows` are indexed by fragment ordinal within the PAGE, and each
        // column owns its own stretch of that numbering — see `makePageView`'s `fragments`.
        var pageFragmentStart = 0
        for (column, count) in columnCounts.enumerated() {
            let columnFragments = pageFragmentStart..<(pageFragmentStart + max(0, count))
            pageFragmentStart += max(0, count)
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
            if rendered.pinnedPageBottoms.indices.contains(pageIndex),
               rendered.pinnedPageBottoms[pageIndex].indices.contains(column) {
                let pinnedBottom = rendered.pinnedPageBottoms[pageIndex][column]
                // MEASURED FROM WHERE THE FLOW STARTS, which is not always the text frame's
                // top — see `RenderedDocument.pinnedPageTops`. At any ordinary lead the two
                // are the same number and this changes nothing; at MARKUP.WS's 2pt lead the
                // flow begins a point above the frame and the container has to hold it.
                let flowTop = rendered.pinnedPageTops.indices.contains(pageIndex)
                    && rendered.pinnedPageTops[pageIndex].indices.contains(column)
                    ? min(CGFloat(rendered.pinnedPageTops[pageIndex][column]), textTop(atPage: pageIndex))
                    : textTop(atPage: pageIndex)
                // Job 427: THIS page's own container-local anchor (`textTop(atPage:)`), not
                // the single shared `rendered.textFrame.origin.y` — `pinnedPageBottoms
                // [pageIndex]` is an absolute paper-Y built from this SAME page's own
                // `pageFirstBaseline` (`DocumentRenderer.renderNative`'s per-page loop), so
                // converting it to a container-local height has to subtract this page's own
                // origin or a page whose own `.mt`/`.mb` differs from the document's global
                // pair gets a container sized against the WRONG anchor.
                height = CGFloat(pinnedBottom) - flowTop + epsilon
            }

            // Batch 47 (M31-app): a page on a wider sheet clips its lines at that sheet's edge, not the document's.
            let widening = max(0, rendered.pageSize(atPage: pageIndex).width - rendered.pageSize.width)
            let container = NSTextContainer(size: CGSize(width: max(1, width + widening), height: max(1, height)))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
            containers.append(container)

            containerPage.append(pageIndex)
            containerColumn.append(column)

            let view = makePageView(container: container, rendered: rendered,
                                    pageIndex: pageIndex, fragments: columnFragments)
            if column == 0 {
                pageViews.append(view)
                columnViews.append([])
                columnViewColumns.append([])
            } else {
                // A later column draws its own glyphs over the same sheet its page's own
                // view already painted, so it must not paint a second one on top of it.
                // Batch 41: NOT `drawsBackground = false`. Text views on one layout manager
                // share that setting, so the next page view's `true` put it back on every
                // column view, and a column's full-page frame painted the sheet white over
                // the column before it — REF/BOOKLET.WS drew only its second column.
                (view as? PageTextView)?.paintsSheet = false
                columnViews[pageIndex].append(view)
                columnViewColumns[pageIndex].append(column)
            }
            addSubview(view, positioned: .below, relativeTo: overlayView)
            layoutManager.ensureLayout(for: container)
        }
    }

    /// Has the last container consumed the end of the text?
    func allGlyphsPlaced() -> Bool {
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
    func frameForPage(_ index: Int) -> CGRect {
        guard let rendered else { return .zero }
        let text = rendered.textFrame
        // Batch 47 (M31-app): a page on a wider sheet than the document's shows its lines out to that sheet's edge.
        let widening = max(0, rendered.pageSize(atPage: index).width - rendered.pageSize.width)
        switch display {
        case .singlePage:
            return CGRect(
                x: text.origin.x, y: textTop(atPage: index) + headroom(atPage: index) + modernTopRise(atPage: index),
                width: text.width + widening, height: textHeight(atPage: index))
        case .continuousScroll:
            guard pageTops.indices.contains(index) else { return .zero }
            return CGRect(
                x: text.origin.x, y: pageTops[index] + textTop(atPage: index) + modernTopRise(atPage: index),
                width: text.width + widening, height: textHeight(atPage: index))
        }
    }

    /// Batch 47 (M30): how far a Modern page's text sits below its content top so its first line's ink is not cut
    /// (`modernFirstLineRise`); 0 for a pinned layout (Native), and for a page not laid out yet.
    func modernTopRise(atPage index: Int) -> CGFloat {
        guard let rendered, rendered.pinnedBaselines.isEmpty, !isMeasuringProbeContainer,
              let first = containerPage.firstIndex(of: index), containers.indices.contains(first) else { return 0 }
        if let cached = modernTopRises[index] { return cached }
        let rise = modernFirstLineRise(layoutManager, container: containers[first])
        modernTopRises[index] = rise
        return rise
    }

    /// `fragments` is this view's own slice of its PAGE's fragment ordinals.
    ///
    /// `overprintPasses`, `oversizedSelfPasses` and `graphicCellRows` are all indexed by
    /// fragment ordinal WITHIN THE PAGE, and a page's columns share that numbering — column
    /// 0's fragments, then column 1's, exactly as the renderer appends them. Every column's
    /// view used to be handed the whole page's arrays, so column 0's view looked up column
    /// 1's overprint pass at column 0's ordinal and column 1's view never found its own at
    /// all. BOOKLET.WS page 3 is the case: its second column holds 27 model lines forming 26
    /// fragments — one overprint pair — and the pass on that pair simply never reached the
    /// paper, so the app's page 3 was one run short of the engine's.
    ///
    /// `nil` for a caller with no column information (`buildExplicitPages`' own single
    /// container per page), which keeps the whole-page arrays it always had.
    func makePageView(container: NSTextContainer, rendered: RenderedDocument,
                               pageIndex: Int, fragments: Range<Int>? = nil) -> NSTextView {
        // Job 460: a real frame from construction, not `.zero` — belt-and-braces alongside
        // `applyDisplayMode()` setting it again before ever clearing `isHidden`. This first
        // assignment is what covers Single Page (its own geometry is ready at this point,
        // before `applyDisplayMode()` even runs once for this `setContent` call); Continuous
        // Scroll's own real frame isn't computable yet here (`frameForPage`'s own doc comment)
        // and gets `.zero` — safe, since nothing is visible until `applyDisplayMode()` runs.
        let view = PageTextView(frame: frameForPage(pageIndex), textContainer: container)
        // Batch 26: hidden until `applyDisplayMode` frames and shows it — job 460's own order. A page view added
        // visible, at Single Page's one shared page rect, invalidated the page on screen as it was added and
        // again as it was hidden, once per page built.
        view.isHidden = true
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
        func ownSlice<Element>(_ whole: [Element]) -> [Element] {
            guard let fragments else { return whole }
            let lower = min(fragments.lowerBound, whole.count)
            let upper = min(fragments.upperBound, whole.count)
            return Array(whole[lower..<upper])
        }
        let selfPasses = ownSlice(rendered.oversizedSelfPasses.indices.contains(pageIndex)
            ? rendered.oversizedSelfPasses[pageIndex] : [])
        let rawPasses = ownSlice(rendered.overprintPasses.indices.contains(pageIndex)
            ? rendered.overprintPasses[pageIndex] : [])
        view.overprintPasses = rawPasses.enumerated().map { index, passes in
            (selfPasses.indices.contains(index) && selfPasses[index] != nil) ? [] : passes
        }
        view.baselineOffset = rendered.baselineOffset
        view.graphicCellRows = ownSlice(rendered.graphicCellRows.indices.contains(pageIndex)
            ? rendered.graphicCellRows[pageIndex] : [])
        view.graphicLeftAnchor = Double(rendered.textFrame.origin.x)
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
}
