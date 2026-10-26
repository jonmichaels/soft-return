import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

extension PagedDocumentView {
    func buildPages(for rendered: RenderedDocument, firstPages: Int? = nil, probe: ExplicitProbe? = nil) {
        let containerSize = rendered.textFrame.size
        if rendered.clipsLines {
            buildExplicitPages(for: rendered, width: containerSize.width, firstPages: firstPages, probe: probe)
            return
        }

        var chain = ModernChain(pendingBreaks: rendered.modernForcedPageBreakOffsets, blankRanges: [:])
        for range in rendered.modernBlankLineRanges { chain.blankRanges[range.location] = range }

        // A BLANK BEFORE ANY CONTENT COSTS NOTHING EITHER. The library's guard is
        // `!body.isEmpty`, which is false for the document's very first items as well as for
        // a page top — so a leading blank is dropped there too. The per-page collapse below
        // can never see those: it asks where the NEXT container will start, and the first
        // container starts at 0. Measured on VERSIONS.WS, whose first body baseline sat at
        // 102.60 against the library's 88.80 — one whole line of nothing.
        var leadingOffset = 0
        while let blank = chain.blankRanges[leadingOffset] {
            collapseBlankLine(blank)
            chain.blankRanges[leadingOffset] = nil
            leadingOffset = NSMaxRange(blank)
        }

        pendingPages = .modern(chain)
        growModernChain(count: firstPages ?? .max, deadline: nil)
    }

    /// Grows Modern's page chain by up to `count` pages, stopping early once every glyph is placed or
    /// `deadline` passes (at least one page a call); then replays the running heads over the pages so far.
    func growModernChain(count: Int, deadline: UInt64?) {
        guard case .modern(var chain)? = pendingPages, let rendered else { return }
        var added = 0
        repeat {
            buildNextModernPage(&chain, rendered: rendered)
            added += 1
        } while chain.pagesBuilt < Self.maxModernPages && !allGlyphsPlaced() && added < count
            && deadline.map({ DispatchTime.now().uptimeNanoseconds < $0 }) ?? true
        let done = chain.pagesBuilt >= Self.maxModernPages || allGlyphsPlaced()
        pendingPages = done ? nil : .modern(chain)

        // Job 393 (391 root cause 2): only once Modern's real pages exist can `rendered.hfEvents`
        // be replayed against them — see `RenderedDocument.runningLines`'s own doc comment on
        // why this can't happen inside `DocumentRenderer` the way Printed's own `runningLines`
        // does. A no-op for every other render (`hfEvents` empty). Replayed over the pages built
        // so far each time the chain grows (batch 26) — only the new ones — so a page shows its heads as soon
        // as it exists.
        // Batch 41 (C): OR the engine laid furniture. A document numbered only by WordStar's automatic page
        // number carries no `.h#`/`.f#` at all, so `hfEvents` alone would have switched the resolver off on
        // exactly the documents that item is about, and the number would silently never draw.
        if !rendered.hfEvents.isEmpty || !rendered.modernFurniture.isEmpty {
            let replayed = self.rendered?.runningLines ?? []
            self.rendered?.runningLines = resolvedModernRunningLines(for: rendered, after: replayed)
        }
    }

    /// One page of Modern's chain — the body of the loop that used to build every page at once.
    private func buildNextModernPage(_ chain: inout ModernChain, rendered: RenderedDocument) {
            let pageIndex = pageViews.count
            // Batch 41 (columns): the engine's own partition of this page, when it lays one — each reported column's
            // end in this view's own text (`RenderedDocument.modernColumnBreaks`). Where it covers the page the view
            // takes every break from it and decides none of its own; where it does not (no furniture), the chain of
            // forced breaks, `.cp` tests and blank collapses below is what paginates, as it always did.
            // ONLY WHERE THE ENGINE LAYS MORE THAN ONE COLUMN. Every document has furniture, so testing for its
            // presence alone handed the engine the page breaks of every ordinary single-column document too —
            // measured as -PRINT.TST at 11 pages against the engine's 6, a short page in FORMFEED.WS, and the
            // Modern finishing turn running long. The partition is what this commit is about; a single-column
            // page keeps the view's own pagination exactly as it was.
            let engineColumns: [ModernColumnBreak]? = rendered.modernColumns(onPage: pageIndex) > 1
                && rendered.modernColumnBreaks.indices.contains(pageIndex)
                ? rendered.modernColumnBreaks[pageIndex] : nil
            // Batch 41 (A): one column's width on a page the engine lays in newspaper columns.
            let containerSize = CGSize(width: rendered.modernColumnWidth(onPage: pageIndex),
                                       height: rendered.textFrame.height)
            let maxPages = Self.maxModernPages
            let container = BreakingTextContainer(size: containerSize)
            // The default 5pt padding would shift every line right of where the library
            // said, and silently narrow the text column.
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            // The NEXT pending break, if any — always strictly ahead of whatever this
            // container has placed so far (see the consumption check below, which pops a
            // break only once some container's real content has actually reached it).
            container.forcedBreakOffset = engineColumns.map { $0.first?.end ?? nil } ?? chain.pendingBreaks.first
            layoutManager.addTextContainer(container)
            containers.append(container)
            containerPage.append(pageIndex)
            containerColumn.append(engineColumns?.first?.column ?? 0)
            columnViews.append([])
            columnViewColumns.append([])

            let view = makePageView(container: container, rendered: rendered, pageIndex: pageIndex)
            pageViews.append(view)
            addSubview(view, positioned: .below, relativeTo: overlayView)

            layoutManager.ensureLayout(for: container)

            // Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like
            // Printed): reserve room at THIS container's own foot for any footnote(s)
            // attached to a paragraph that landed on it, before asking where the next
            // container should pick up — see `RenderedDocument.modernFootnoteEvents`'s own
            // doc comment for why this has to run HERE, one real page at a time, rather than
            // resolved after the whole chain exists the way running heads/feet are.
            var footnoteEntries: [NSAttributedString] = []
            if !rendered.modernFootnoteEvents.isEmpty {
                footnoteEntries = reserveFootnoteBlock(in: container, fullHeight: containerSize.height,
                                                       rendered: rendered)
            }
            // Batch 41 (columns): the endnote-appendix and `.cp` rules below, the blank collapse and the pending-break
            // consumption are the view's OWN pagination. On a page the engine partitions they would fight it, so they
            // run only where it does not.
            let viewPaginates = engineColumns == nil

            // Planning #221 (Jon's ruling 2026-09-07, verbatim): "endnotes go right at the
            // end of text / image on the last page unless there are footnotes on that page.
            // Then the endnotes start on a new page." Endnotes are never interleaved with a
            // footnote block.
            //
            // The engine applies this in `modernStreams`, which knows each page's reserved
            // note lines before it places anything. AppKit does not decide a Modern page
            // break until the page has actually been laid out, so the identical test runs
            // HERE instead — on a real page, right after its own footnote block is known,
            // which is the same reason `reserveFootnoteBlock` itself has to run in this loop
            // rather than after it.
            //
            // The guard is deliberately a STRICT interior test. If the appendix already
            // begins this page, breaking would open an empty page rather than move anything;
            // and once the break is taken the next container begins AT the appendix, so its
            // own `location` check cannot fire a second time.
            if viewPaginates, let appendixStart = rendered.modernEndnoteAppendixStart, !footnoteEntries.isEmpty {
                let laid = layoutManager.characterRange(
                    forGlyphRange: layoutManager.glyphRange(for: container), actualGlyphRange: nil)
                if appendixStart > laid.location, appendixStart < laid.location + laid.length {
                    container.forcedBreakOffset = appendixStart
                    // `forcedBreakOffset` is consulted during TYPESETTING, so text already
                    // laid into this container has to be invalidated for the new refusal to
                    // mean anything — a container's own geometry change is what does that
                    // implicitly inside `reserveFootnoteBlock`; here it is stated directly,
                    // from the appendix to the end of the document.
                    let tail = NSRange(location: appendixStart,
                                       length: max(0, rendered.text.length - appendixStart))
                    layoutManager.invalidateLayout(forCharacterRange: tail, actualCharacterRange: nil)
                    layoutManager.ensureLayout(for: container)
                    // This page just lost its appendix, so its footnote block is measured
                    // again. That set can only have stayed the same or shrunk — every
                    // footnote marker sits in body text, ahead of the appendix — never grown.
                    footnoteEntries = reserveFootnoteBlock(in: container, fullHeight: containerSize.height,
                                                           rendered: rendered)
                }
            }

            if !rendered.modernFootnoteEvents.isEmpty {
                self.rendered?.modernFootnoteBlocks.append(footnoteEntries)
            }

            // `.cp`: A PARAGRAPH THAT ASKS FOR ROOM THIS PAGE HAS NOT GOT STARTS THE NEXT
            // ONE. The engine's own test, made here because only a real page can answer it:
            // `if !body.isEmpty, y - (margb + noteBlockH()) < need { close() }`. `need` came
            // with the offset (`RenderedDocument.modernConditionalBreaks`); the room left is
            // this container's own height below where the paragraph would start.
            //
            // Only the FIRST unmet `.cp` in a container matters: forcing the break there
            // moves everything after it to the next page, where the next `.cp` is asked
            // again against that page's own room.
            //
            // ASKED AGAIN AFTER THE BLANK COLLAPSE BELOW, because the collapse changes the
            // answer: a page that could not hold the blank CAN hold the hairline it becomes,
            // and then whatever followed that blank — measured on -README.WS page 18, whose
            // foot took the collapsed blank and the 3.70pt leading spacer behind it, leaving
            // page 19's heading to open with its own headroom stranded on the page before.
            func applyConditionalBreak() {
                guard viewPaginates, !rendered.modernConditionalBreaks.isEmpty,
                      container.forcedBreakOffset == nil else { return }
                let glyphs = layoutManager.glyphRange(for: container)
                let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let pageEnd = chars.location + chars.length
                let bottom = container.size.height
                for entry in rendered.modernConditionalBreaks
                where entry.charOffset > chars.location && entry.charOffset < pageEnd {
                    let glyph = layoutManager.glyphIndexForCharacter(at: entry.charOffset)
                    let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    guard Double(bottom - fragment.minY) < entry.needPt else { continue }
                    container.forcedBreakOffset = entry.charOffset
                    let tail = NSRange(location: entry.charOffset,
                                       length: max(0, rendered.text.length - entry.charOffset))
                    layoutManager.invalidateLayout(forCharacterRange: tail, actualCharacterRange: nil)
                    layoutManager.ensureLayout(for: container)
                    break
                }
            }
            applyConditionalBreak()

            // Batch 41 (columns): THE PAGE'S LATER NEWSPAPER COLUMNS. A Modern page the engine lays in
            // `.co` columns fills its first column, then each next one from the text frame's own top,
            // before the next page begins. Each is a container of one column's width with a view of
            // its own lying over the page's sheet (`paintsSheet` off) at its column's x
            // (`syncColumnViews`), and it ends where the engine's own pagination ended that column
            // (`ModernColumnBreak`). A column the engine left empty is not reported and gets no
            // container of its own. Where no furniture covers the page, one container holds it, as
            // before, and the page-level rules below read the page's LAST column.
            var lastColumn: BreakingTextContainer = container
            let laterColumns: [ModernColumnBreak] = engineColumns.map { Array($0.dropFirst()) } ?? []
            for entry in laterColumns {
                let next = BreakingTextContainer(size: containerSize)
                next.lineFragmentPadding = 0
                next.widthTracksTextView = false
                next.heightTracksTextView = false
                next.forcedBreakOffset = entry.end
                layoutManager.addTextContainer(next)
                containers.append(next)
                containerPage.append(pageIndex)
                containerColumn.append(entry.column)
                let columnView = makePageView(container: next, rendered: rendered, pageIndex: pageIndex)
                (columnView as? PageTextView)?.paintsSheet = false
                columnViews[pageIndex].append(columnView)
                columnViewColumns[pageIndex].append(entry.column)
                addSubview(columnView, positioned: .below, relativeTo: overlayView)
                layoutManager.ensureLayout(for: next)
                lastColumn = next
            }

            // A BLANK LINE AT A PAGE TOP COSTS NOTHING (`RenderedDocument
            // .modernBlankLineRanges`). This container has just been laid out, so where the
            // NEXT one will begin is now known — and if that is a recorded blank, the
            // library would have dropped it (`PDFModernLayout`'s paginator: "no blank at a
            // page top"). Collapsed to a hairline rather than deleted: deleting would move
            // every offset this render already recorded (the forced breaks above, the
            // footnote events, the appendix start), and a hairline fragment is absorbed by
            // THIS page, leaving the next to open on the real line — the same outcome the
            // library reaches by skipping it.
            //
            // `while`, because the library drops EVERY blank at a page top, not just the
            // first: its guard is `!body.isEmpty`, which stays false across a run of them.
            // Each collapse is re-laid before the next offset is read, so this converges on
            // the first non-blank — and cannot loop, since each pass consumes one recorded
            // blank strictly ahead of the last.
            if viewPaginates, !chain.blankRanges.isEmpty {
                var collapsed = 0
                while let next = nextContainerStart(for: lastColumn),
                      let blank = chain.blankRanges[next], collapsed < maxPages {
                    collapseBlankLine(blank)
                    layoutManager.ensureLayout(for: lastColumn)
                    chain.blankRanges[next] = nil
                    collapsed += 1
                }
                // The page holds different content now — see `applyConditionalBreak`'s own
                // note. Only ever asked once more: a forced break can only move content OFF
                // this page, and there is no blank left at the next container's start to
                // collapse again.
                if collapsed > 0 { applyConditionalBreak() }
            }

            // Did THIS container's own real content reach the break it was given? A break
            // far past what this container would have held naturally has no effect above
            // (the container simply runs out of room first) and stays pending, unconsumed,
            // for the container after this one to try again.
            if viewPaginates, let nextBreak = chain.pendingBreaks.first {
                // Batch 41 (A): the page's content ends in its last column that holds any.
                let first = layoutManager.characterRange(
                    forGlyphRange: layoutManager.glyphRange(for: container), actualGlyphRange: nil)
                let last = lastColumn === container ? first : layoutManager.characterRange(
                    forGlyphRange: layoutManager.glyphRange(for: lastColumn), actualGlyphRange: nil)
                if max(NSMaxRange(first), NSMaxRange(last)) >= nextBreak {
                    chain.pendingBreaks.removeFirst()
                }
            }
            chain.pagesBuilt += 1
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
        // WITHOUT THE TRAILING TERMINATOR. Every note line carries its own `\n`
        // (`DocumentRenderer`'s `noteLineAttributedString`), so the concatenated block ends
        // with one — and AppKit gives a string ending in a newline an extra, empty line
        // fragment. Measured on LYING.WS's one-note page: the block reserved 39.60pt where
        // the library reserves `sepH + noteLead * count` = 26.40, a whole note line too much,
        // and the page's last body line landed at 673.80 against the library's 691.20.
        if block.string.hasSuffix("\n") {
            block.deleteCharacters(in: NSRange(location: block.length - 1, length: 1))
        }
        // NOT `.usesFontLeading`. The note paragraph already pins its own line height to the
        // library's own figure — `noteLead = modernLine * modernNotePt`, 13.20pt at 11pt —
        // and `.usesFontLeading` tells AppKit to ignore that and add the FACE's leading
        // instead. Measured on LYING.WS: the library reserves `sepH + noteLead * count` =
        // 26.40pt for its one-note page and this reserved 30.07, which cost the page a whole
        // body line — its last line landed at 673.80 against the library's 691.20.
        let bounds = block.boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        return bounds.height
    }

    /// One page's own running heads/feet, replayed from `rendered.hfEvents` against that
    /// page's REAL first character offset — the state `.hf` events left "in force" by the
    /// time AppKit actually placed this page's first glyph, matching the engine's own
    /// `openPage()` rule (`DocumentRenderer.modernRunningLines`'s own doc comment has the
    /// full citation). A page with no glyphs of its own (defensive only — the build loop
    /// above never leaves a genuinely empty container mid-chain) inherits the offset of the
    /// page before it, rather than resetting to the very start of the document.
    ///
    /// `existing` (batch 26): pages already replayed, kept as they are. A page's heads depend only on the
    /// events before its own first character, which is settled once its container is built, so a chain
    /// grown a turn at a time replays only its new pages. Each replay measures a face
    /// (`DocumentRenderer.modernRunningLines`' `firstBaselineOffset`), and replaying every page on every
    /// turn made each turn slower than the last (b26-holymac-fix2: Modern's layout slices grew from 34 ms
    /// to 593 ms over -HOLYMAC.WS's pages).
    private func resolvedModernRunningLines(for rendered: RenderedDocument,
                                            after existing: [[RunningLine]] = []) -> [[RunningLine]] {
        let kept = min(existing.count, containers.count)
        var result = Array(existing.prefix(kept))
        var lastOffset = 0
        for container in containers.prefix(kept).reversed() {
            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length > 0 {
                lastOffset = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
                break
            }
        }
        for (index, container) in containers.enumerated().dropFirst(kept) {
            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length > 0 {
                lastOffset = layoutManager.characterRange(
                    forGlyphRange: glyphRange, actualGlyphRange: nil).location
            }
            var lines = DocumentRenderer.modernRunningLines(
                events: rendered.hfEvents, upToOffset: lastOffset,
                pageNo: rendered.pageNumberStart + index,
                pageHeight: Double(rendered.pageSize.height), font: rendered.modernFurnitureFont)
            // Batch 41 (F): where the engine laid furniture for THIS page, its own heads and feet REPLACE the
            // replay — placed where it placed them, and an ink-less line simply absent, because the engine never
            // reported one. Furniture record `index`, as Athena ruled the mapping (app page i takes record i).
            //
            // Where it laid none — a page past the engine's last record — the replay still runs. The draft said
            // such a page "draws no furniture"; blanking the heads outright is the more literal reading, and it
            // is the one that fails silently if the two page counts ever disagree. The replay is what this file
            // did before F and it is the safe half of the ruling, so that is what a page past the end keeps.
            //
            // AND ONLY WHEN THIS RENDER WAS ASKED FOR HEADS. Suppression used to be a property of the text —
            // no `.hf` events recorded, so nothing to draw — and the furniture describes the page whatever the
            // export asked for, so the flag has to be honoured HERE, where the lines are consumed
            // (`RenderedDocument.exportFlags`). Without this an export with headers off still drew them: two
            // PDFs kept their running head and a page put ink 44pt from its foot, below its own container.
            if rendered.exportFlags.headers, rendered.modernFurniture.indices.contains(index) {
                lines = DocumentRenderer.modernFurnitureRunningLines(
                    furniture: rendered.modernFurniture[index],
                    textLeft: Double(rendered.textFrame.origin.x), rendered: rendered)
            }
            // Batch 41 (C): and the engine's own automatic page number for this page. The engine decides whether
            // the page is numbered at all — `nil` for `.op`, a footer in use, or page numbers off.
            //
            // NOT gated on `headers`: the automatic number is `pageNumbers`' business, and a document may
            // legitimately number its pages with running heads switched off.
            if rendered.modernFurniture.indices.contains(index),
               let auto = DocumentRenderer.modernAutoPageNumberLine(
                furniture: rendered.modernFurniture[index], textLeft: Double(rendered.textFrame.origin.x), rendered: rendered) {
                lines.append(auto)
            }
            result.append(lines)
        }
        return result
    }
}
