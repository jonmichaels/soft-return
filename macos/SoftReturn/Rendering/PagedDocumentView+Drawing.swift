import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

extension PagedDocumentView {
    // MARK: - Drawing the paper

    /// The page rectangles themselves — white sheets under the text views, and the grey
    /// they sit on. Drawn rather than made of subviews: they carry no behaviour, and a
    /// hundred-page document should not cost a hundred extra views.
    override func draw(_ dirtyRect: NSRect) {
        guard let rendered else { return }
        if let firstDraw = onFirstDraw {
            onFirstDraw = nil
            firstDraw()
        }

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
        // to Dark Mode. Native style is a line-for-line reproduction of a 1980s typescript;
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
            let sheet = rendered.pageSize(atPage: currentPageIndex)
            CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height + nominalTop).fill()
            drawRunningLines(rendered: rendered, pageIndex: currentPageIndex,
                             pageOrigin: CGPoint(x: 0, y: nominalTop))
            drawPCLGraphics(rendered: rendered, pageIndex: currentPageIndex,
                            pageOrigin: CGPoint(x: 0, y: nominalTop))
            drawFootnoteBlock(rendered: rendered, pageIndex: currentPageIndex,
                              pageOrigin: CGPoint(x: 0, y: nominalTop))
        case .continuousScroll:
            for index in 0..<max(1, pageViews.count) {
                // A capture draws ONLY the page it asked for — but at the same DOCUMENT
                // coordinates it always used. Selecting the page and re-basing the origin
                // are two different changes and only the first is wanted: a capture is not
                // re-based for the parent view, so drawing at document coordinates is
                // correct here, and moving it to (0,0) is what broke the Modern export
                // against its viewer on 100 pages. Without the selection, page one's running
                // lines are drawn into every later page's file — report.ps page 2 carried
                // its "2" at a page-local -80.0, which is 732.0 less one page height and the
                // gap, while the model puts it at 732.0 on every page.
                if let capturingPageIndex, index != capturingPageIndex { continue }
                let rect = self.rect(ofPage: index)
                if rect.intersects(dirtyRect) {
                    // Batch 40 (M10, Jon's "big black bar"): white set for EVERY sheet, not once before the loop. Drawing
                    // a page's running lines draws text, and drawing text leaves the text's colour as the fill colour —
                    // so when one draw reached two pages, the second sheet was filled black under its text. Measured on
                    // -HOLYMAC.WS at pages 151–152 and 301–302 (b40-m10), where the first page carries a running foot.
                    NSColor.white.setFill()
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
            // Mechanism O (engine commit 840cf4c): `running.pageLeftOffset` — nonzero only
            // on a page whose own `.po` differs from the document's global one, which the
            // engine applies to the running head/foot row ALONE (see that property's own doc
            // comment). Body text takes its own per-line `.po` through `PageLine.left`, so
            // this is the only place the page-granularity value is needed.
            let point = NSPoint(
                x: rendered.textFrame.origin.x + CGFloat(running.leadingOffset)
                    + CGFloat(running.pageLeftOffset),
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
        // Same options the reservation above measures with, for the same reason — drawing
        // with a leading the reservation did not reserve is how a block overflows its own
        // reserved strip.
        block.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    /// Job 490 (item 1, LJ6DTP title-top): a `.pctl` attachment glyph carrying
    /// `.nativePCLProgram` (`DocumentRenderer.pctlAdvanceAttachment`) — execute that
    /// control's own raw PCL program (`NativePCLGraphics.swift`) anchored at its real,
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
            guard capturingPageIndex == nil || capturingPageIndex == pageIndex else { continue }
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
    /// `NativeVectorGraphics.swift`) and its own BASELINE (not merely its fragment's top
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

    /// Planning #227 follow-up: every line of a page's SECOND and later newspaper columns,
    /// painted where the library puts it.
    ///
    /// Only the `.l#` gutter numbers use this now — a page's newspaper columns are real
    /// text again (item 19). The
    /// arithmetic here is the simplest in this file precisely because they are: a pass
    /// carries an absolute paper X and an absolute paper baseline Y, so all this does is put
    /// the paper's own top-left corner under them. `pclOverlayPageOrigin` is that corner —
    /// the page view's own origin less this page's margin, the same conversion the PCL
    /// overlay beside it already needed for absolute coordinates.
    func drawColumnPasses(_ dirtyRect: NSRect) {
        guard let rendered,
              !rendered.lineNumberPasses.isEmpty
        else { return }
        for (pageIndex, view) in pageViews.enumerated() {
            guard !view.isHidden, view.frame.intersects(dirtyRect) else { continue }
            guard capturingPageIndex == nil || capturingPageIndex == pageIndex else { continue }
            let passes = rendered.lineNumberPasses.indices.contains(pageIndex)
                ? rendered.lineNumberPasses[pageIndex] : []
            guard !passes.isEmpty, let textContainer = view.textContainer else { continue }
            let paperOrigin = Self.pclOverlayPageOrigin(
                viewOrigin: view.frame.origin,
                marginOrigin: CGPoint(x: rendered.textFrame.origin.x,
                                      y: textTop(atPage: pageIndex)))
            let width = textContainer.size.width
            for pass in passes {
                guard let isolated = isolatedLineLayout(pass.text, width: width) else { continue }
                // Where this line's own baseline sits inside the isolated layout, so the
                // offset below lands the REAL baseline on the engine's figure rather than
                // the fragment's top edge.
                let isolatedBaseline = isolated.fragmentRect.origin.y
                    + isolated.manager.location(forGlyphAt: isolated.glyphRange.location).y
                let origin = NSPoint(
                    x: paperOrigin.x + CGFloat(pass.xPt) - isolated.fragmentRect.origin.x,
                    y: paperOrigin.y + CGFloat(pass.baselineY) - isolatedBaseline)
                isolated.manager.drawGlyphs(forGlyphRange: isolated.glyphRange, at: origin)
            }
        }
    }

    func drawOversizedSelfPasses(_ dirtyRect: NSRect) {
        guard let rendered, rendered.clipsLines, !rendered.oversizedSelfPasses.isEmpty else { return }
        for (pageIndex, view) in pageViews.enumerated() {
            guard !view.isHidden, rendered.oversizedSelfPasses.indices.contains(pageIndex) else { continue }
            guard capturingPageIndex == nil || capturingPageIndex == pageIndex else { continue }
            // Batch 40 (M10): only a page the dirty rect reaches, with a gap's room either side for a pass that
            // bleeds past its sheet. Every visible page's oversized lines were laid out and drawn on every draw —
            // in Continuous Scroll, every page of the document for each strip a scroll exposed.
            guard capturingPageIndex != nil
                || rect(ofPage: pageIndex).insetBy(dx: -Self.pageGap, dy: -Self.pageGap).intersects(dirtyRect)
            else { continue }
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
