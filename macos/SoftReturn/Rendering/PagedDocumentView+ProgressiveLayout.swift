import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

extension PagedDocumentView {
    /// Batch 26 (#271 M7): the pages `setContent(_:display:firstPages:)` left for later turns.
    enum PendingPages {
        /// Native: the pages from `next` on. Every page's height is pinned by the render, so each is
        /// built on its own, in order, with no probe of the whole flow.
        case explicit(next: Int, columnCountsByPage: [[Int]], width: CGFloat,
                      cursor: Int, fragmentTops: [CGFloat], fragmentBottoms: [CGFloat])
        /// Modern: AppKit's own page chain, grown a page at a time.
        case modern(ModernChain)
    }

    /// Where Modern's page chain stands between the pages it grows (`buildNextModernPage`).
    struct ModernChain {
        /// b28 note 11: forced screenplay-marker breaks still waiting to be honoured, in
        /// ascending order — `BreakingTextContainer`'s own doc comment has the mechanism.
        /// Empty for every document `RenderedDocument.modernForcedPageBreakOffsets` doesn't
        /// populate, which is every document but a screenplay-detected one — the chain is
        /// then IDENTICAL to before that job, container for container.
        var pendingBreaks: [Int]
        /// Blank lines by their own START offset, so "does the next page open on one?" is a
        /// dictionary lookup rather than a scan — see the collapse in `buildNextModernPage`.
        var blankRanges: [Int: NSRange]
        var pagesBuilt = 0
    }


    /// A hard ceiling on Modern's chain: a malformed document should produce an ugly page count,
    /// never an unbounded loop that hangs the app with no way to cancel.
    static let maxModernPages = 10_000

    /// Whether every page of the content is laid out (batch 26: `setContent(_:display:firstPages:)`).
    var isLaidOut: Bool { pendingPages == nil }

    /// Batch 26 (#271 M7): lays out more of the pages `setContent(_:display:firstPages:)` left, until
    /// every page is laid out or `deadline` (`DispatchTime` uptime nanoseconds) passes — at least one
    /// page a call. True once every page is laid out.
    @discardableResult
    func layOutMorePages(until deadline: UInt64) -> Bool {
        guard let pending = pendingPages else { return true }
        let firstNewPage = pageViews.count
        switch pending {
        case .explicit:
            addExplicitPages(count: .max, deadline: deadline)
        case .modern:
            growModernChain(count: .max, deadline: deadline)
        }
        let done = pendingPages == nil
        // Only what the new pages change: their labels, their tops and visibility, and the view's size where
        // that grows — every page relabelled once, at the end. Relabelling every page, re-marking the whole view
        // for layout and display and re-adding the overlay on every turn cost more than the layout itself
        // (b26-holymac-fix4: Modern's turns ran 102–129 ms around layout slices of at most 57–80 ms).
        applyPageAccessibilityLabels(from: done ? 0 : firstNewPage)
        rebuildPageTops()
        applyDisplayMode(toPagesFrom: firstNewPage)
        if done || display == .continuousScroll {
            invalidateIntrinsicContentSize()
            let size = intrinsicContentSize
            if frame.size != size { setFrameSize(size) }
        }
        // Batch 40 (M10): the new pages' paper. Their text views draw only their text area; the white sheet, its
        // margins, running lines and footnotes are this view's own `draw(_:)`, and growing the frame marked none of
        // it — the desk showed through the new pages' margins (grey, near-black in Dark Mode) until something else
        // redrew them. Only the new pages' strip is marked, not the whole view.
        if display == .continuousScroll, firstNewPage < pageViews.count, pageTops.indices.contains(firstNewPage) {
            let top = max(0, rect(ofPage: firstNewPage).minY - Self.pageGap)
            let strip = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
            setNeedsDisplay(strip)
            lastMarkedForDisplay = strip
        }
        return done
    }


    /// Whether a layout of `rendered` adds each face's own leading: a pinned Native render keeps it (its fragments are
    /// placed through the delegate); Modern and Show Invisibles' Native render do not (batch 40, M14).
    nonisolated static func usesFontLeading(_ rendered: RenderedDocument) -> Bool {
        rendered.clipsLines && !rendered.pinnedBaselines.isEmpty
    }

    /// Batch 40 (M10): how many later-column text views the pages hold, for the tests.
    var columnViewCount: Int { columnViews.reduce(0) { $0 + $1.count } }

    /// Batch 27: the unpinned probe's line-fragment tops and bottoms for a whole flow.
    struct ExplicitProbe: Sendable {
        let fragmentTops: [CGFloat]
        let fragmentBottoms: [CGFloat]
    }

    /// Whether `rendered` pins every column of every page (`renderNative` does): its pages need no probe.
    static func pinsEveryPage(_ rendered: RenderedDocument) -> Bool {
        let counts = rendered.pageColumnFragmentCounts.isEmpty
            ? rendered.softLineFlags.map { [$0.count] }
            : rendered.pageColumnFragmentCounts
        return counts.indices.allSatisfy { page in
            rendered.pinnedPageBottoms.indices.contains(page)
                && rendered.pinnedPageBottoms[page].count >= counts[page].count
        }
    }

    /// Batch 27: `buildExplicitPages`' unpinned probe, measured OFFSCREEN a slice of characters at a time, so a
    /// long render that pins nothing (Show Invisibles, Native) never lays its whole flow out in one block. The same
    /// text, the same layout manager, leading and contiguous layout, one unbounded container at the same width and
    /// no pins — the probe `buildExplicitPages` makes in view — so the same fragments.
    @MainActor
    final class ProbeMeasurement {
        private let storage: NSTextStorage
        private let manager: NSLayoutManager
        private let container: NSTextContainer
        private var measuredTo = 0
        private var step = 2_000

        init(rendered: RenderedDocument) {
            storage = NSTextStorage(attributedString: rendered.text)
            manager = softReturnLayoutManager()
            manager.usesFontLeading = PagedDocumentView.usesFontLeading(rendered)
            manager.allowsNonContiguousLayout = false
            container = NSTextContainer(size: CGSize(width: max(1, rendered.textFrame.size.width),
                                                     height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        var isComplete: Bool { measuredTo >= storage.length }

        /// Lays more of the flow out until `deadline` passes — a slice at least — each slice sized toward a
        /// few milliseconds.
        func measure(until deadline: UInt64) {
            repeat {
                let end = min(storage.length, measuredTo + step)
                let sliceStart = DispatchTime.now().uptimeNanoseconds
                manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: end))
                measuredTo = end
                let took = DispatchTime.now().uptimeNanoseconds - sliceStart
                if took < 2_000_000 {
                    step = min(step * 2, 200_000)
                } else if took > 8_000_000 {
                    step = max(step / 2, 200)
                }
            } while !isComplete && DispatchTime.now().uptimeNanoseconds < deadline
        }

        /// The fragments, once the whole flow is laid out.
        func result() -> ExplicitProbe {
            var tops: [CGFloat] = []
            var bottoms: [CGFloat] = []
            let glyphs = manager.glyphRange(for: container)
            if glyphs.length > 0 {
                manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    tops.append(rect.minY)
                    bottoms.append(rect.maxY)
                }
            }
            return ExplicitProbe(fragmentTops: tops, fragmentBottoms: bottoms)
        }
    }
}
