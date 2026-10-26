import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

/// b28 note 11 (Jon's ruling: SCRIPT.WS's Modern view must break the page just before the
/// screenplay page-number marker, e.g. the "1." ahead of a scene's slugline): the idiomatic
/// TextKit 1 way to force `NSLayoutManager` to end the CURRENT container and continue laying
/// text out in the NEXT one at a chosen character offset — there is no other API to request a
/// break mid-flow the way Native style's own library pagination already dictates its page
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
///
/// Workaround, kept (reviewed 2026-10-26, macOS 26.7): TextKit 1 has no public "break here" for a container short of filling
/// it, and Native's page breaks are the engine's, not TextKit's. Kept while the pages are laid out by TextKit 1.
final class BreakingTextContainer: NSTextContainer {
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

/// Job 227: a subview whose sole job is drawing `PagedDocumentView.drawOversizedSelfPasses`
/// ABOVE every `PageTextView` — see that method's own doc comment for why compositing order
/// requires a dedicated subview rather than either `PagedDocumentView`'s own background
/// `draw(_:)` or `PageTextView` itself. Transparent to hit-testing (`hitTest` always `nil`)
/// so it never steals clicks, selection drags, or scrolling from the views underneath.
final class OversizedPassOverlayView: NSView {
    weak var owner: PagedDocumentView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        owner?.drawColumnPasses(dirtyRect)
        owner?.drawOversizedSelfPasses(dirtyRect)
        owner?.drawPCLGraphicsOverlay(dirtyRect)
    }
}

/// One page's text. Job 256 (Show Invisibles part 2/4): this view USED TO draw a margin
/// arrow overlay for View ▸ Show Invisibles (`drawSoftReturnMarkers`, on top of the glyphs
/// after `super.draw`, gated on `isDrawingToScreen` so it could never ride into
/// `RenderedDocument.text` and leak into print/export). That is gone — invisible ink is now
/// real text baked into a SEPARATE `RenderedDocument` (`DocumentRenderer
/// .renderNativeAnnotated`, screen-only via `renderWithInvisibles`), so this view draws
/// exactly the same glyphs regardless of the toggle; screen-only-ness is enforced one layer
/// up, at which `RenderedDocument` gets requested, not here.
final class PageTextView: NSTextView {
    /// Job 211: `RenderedDocument.clipsLines` for this page — gates the vector-graphics
    /// overlay below, same convention `runningLines` already uses (Modern
    /// reflows cp437 glyphs as plain text; see `NativeVectorGraphics.swift`'s top comment).
    var isPrintedStyle = false
    /// Job 224: this page's `RenderedDocument.overprintPasses[pageIndex]` — one entry per
    /// line fragment (same indexing as `softLineFlags`), each a (possibly empty) list of
    /// extra `.overprint`-chained `PageLine`s sharing that fragment's baseline. See
    /// `drawOverprintPasses` below.
    var overprintPasses: [[NSAttributedString]] = []
    /// Planning #251(c): this page's `RenderedDocument.graphicCellRows[pageIndex]` — one
    /// entry per line fragment, the engine's own x and width for each graphic cell that
    /// fragment draws. `leftAnchor` is the paper x this view's own local x = 0 sits at
    /// (`RenderedDocument.textFrame.origin.x`), which is what converts one to the other.
    var graphicCellRows: [[PageLine.GraphicCellPlacement]] = []
    var graphicLeftAnchor: Double = 0
    /// `RenderedDocument.baselineOffset` — see `drawOverprintPasses`'s job 246 doc comment
    /// for why it, not the real fragment's own raw origin, is the chain's shared baseline.
    var baselineOffset: CGFloat = 0
    /// Batch 41: false for a page's later columns, which lie over the sheet their page's own view paints. This view's
    /// own, unlike `drawsBackground`, which every text view on the layout manager shares.
    var paintsSheet = true

    override var isOpaque: Bool { paintsSheet && super.isOpaque }

    override func drawBackground(in rect: NSRect) {
        guard paintsSheet else { return }
        super.drawBackground(in: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawVectorGraphics(dirtyRect)
        drawOverprintPasses(dirtyRect)
    }

    /// Job 211 (b11 leg 3b): cp437 box/shade/block glyphs as vector fills — see
    /// `NativeVectorGraphics.swift`'s top doc comment for the port citation and the
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
        var fragmentIndex = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, effectiveGlyphRange, _ in
            fragmentIndex += 1
            guard rect.intersects(dirtyRect) else { return }
            let placements = self.graphicCellRows.indices.contains(fragmentIndex)
                ? self.graphicCellRows[fragmentIndex] : []
            for cell in graphicCells(manager: layoutManager, storage: textStorage,
                                      glyphRange: effectiveGlyphRange, fragment: rect,
                                      placements: placements,
                                      leftAnchor: self.graphicLeftAnchor) {
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
    /// past the engine's own count (see `DocumentRenderer.renderNative`'s own doc comment
    /// on `overprintPasses` for the pagination arithmetic this replaces).
    ///
    /// Each pass is laid out in ISOLATION (`isolatedLineLayout`, `NativeVectorGraphics.swift`
    /// — the same "unbounded, freshly-built `NSLayoutManager`" technique
    /// `DocumentRenderer.measuredHeight`/`firstBaselineOffset` already use and job 202 already
    /// proved accurate) rather than inserted into this view's own shared `layoutManager` —
    /// there is no fragment for it to occupy there at all, by design. `offset` is the delta
    /// between that isolated layout's own fragment origin and the REAL base fragment this
    /// pass shares a baseline with; translating by it is what lands the pass exactly on that
    /// baseline, not merely near it. Passes draw in DOCUMENT ORDER (the array's own order,
    /// `DocumentRenderer.renderNative`'s `(i + 1...j).map`), matching the engine's own
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
