#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

/// ONE PIECE OF INK AT AN ABSOLUTE PLACE ON THE PAPER — a `.l#` gutter number.
///
/// `xPt` and `baselineY` are both absolute on the PAPER — measured from its left and top
/// edges, not from the text container — because that is the form the engine's own page-lines
/// model states them in (`PageLine.lineNo`, its x already right-aligned) and because a gutter
/// number has no fragment of its own to be relative to. See `RenderedDocument.lineNumberPasses`
/// for why it has none.
public struct ColumnPass {
    public let text: NSAttributedString
    public let xPt: Double
    public let baselineY: Double
    /// A `.l#` row's two bars (`PDFMetrics.lineNoBarChars` at `lineNoBarXs`), as cells in the
    /// engine's frame like `xPt`, drawn with the number. Empty for any other pass.
    public var bars: [GraphicCell] = []
}


/// A document turned into something AppKit can lay out: one attributed string, plus the
/// page geometry to flow it through.
///
/// ## Why one string and not one view per page
///
/// The obvious build is a view per page, each holding its own text. It is also the build
/// that loses cross-page selection, cross-page Find, Speech over a whole document, and a
/// coherent VoiceOver reading order — all of which the spec marks [SYS], meaning we are
/// required to have them and forbidden from reimplementing them.
///
/// So: ONE `NSTextStorage` per document, one `NSLayoutManager`, and one `NSTextContainer`
/// per page. AppKit flows the text through the containers and gives all of the above for
/// free. Each page view draws one container. This is the classic multi-page AppKit layout,
/// and the reason the type below hands back a string plus a container size rather than a
/// list of per-page strings.
///
/// ## How the library's pagination is honoured
///
/// In Native style, pagination is CtrlKD's decision, not AppKit's — `docToPagelines`
/// already assigned every line to a page using WordStar's own vertical model. This function
/// renders each page's own real lines ONLY, no padding to `capacity` — `PagedDocumentView
/// .buildPages` is what makes the boundaries land where the library put them: it measures
/// this SAME flow once in a single oversized probe container, then gives page N's own real
/// text container exactly the height that probe measured for page N's own line count, so
/// AppKit has no room to place a glyph from page N+1 in page N's container (job 225's own
/// doc comment there has the full mechanism and why the previous padding-to-`capacity`
/// approach could not close the residual it left on `LJ6DTP.WS`). Lines are also set to
/// clip rather than wrap, so a pathological over-wide line cannot shift the count and
/// misalign every page after it.
public struct RenderedDocument {
    /// The whole document, styled and ready to flow.
    public let text: NSAttributedString
    /// Paper size in points.
    public let pageSize: CGSize
    /// The text area within one page — where the container sits on the paper.
    public let textFrame: CGRect
    /// How many pages the flow will need.
    public let pageCount: Int
    /// Whether lines are clipped rather than wrapped (Printed) or reflowed (Modern).
    public let clipsLines: Bool
    /// Per page, per line (page N's own real lines only, no padding — see this type's
    /// "How the library's pagination is honoured" doc comment above): whether that
    /// `PageLine` carried CtrlKD's own `soft` flag — WordStar's own word wrap, as opposed
    /// to the author pressing Return. Also `PagedDocumentView.buildPages`'s own source for
    /// how many real AppKit fragments page N has — `softLineFlags[n].count` IS that page's
    /// real line count, by construction. Empty in Modern style, whose `mergedLines` already
    /// undid the physical wrap the flag would describe. Job 256 (Show Invisibles part 2/4):
    /// no longer what Show Invisibles overlays — the margin arrow this fed
    /// (`drawSoftReturnMarkers`) is gone, superseded by real inline marks baked into
    /// `renderNativeAnnotated`'s own `text` (a SEPARATE `RenderedDocument`,
    /// `DocumentRenderer.renderWithInvisibles`'s screen-only output — never what print/
    /// export/QuickLook request). This field's only remaining job is the container-sizing
    /// one described above; its per-line VALUES are otherwise unused.
    public let softLineFlags: [[Bool]]
    /// Job 224: per page, per line fragment (same indexing as `softLineFlags` — page N's own
    /// real lines only, no padding) — the EXTRA `.overprint`-chained `PageLine`s that share that
    /// fragment's baseline, in document order, rendered but never given a fragment of their
    /// own. `PageTextView` composites each one directly on top of the fragment's real glyph
    /// geometry (`PagedDocumentView.swift`'s `drawOverprintPasses`) instead of laying it out
    /// as its own (even near-zero-height) paragraph — see `renderNative`'s own doc comment
    /// on the pagination bug this replaces. Empty in Modern style, which has no `PageLine`s
    /// (and therefore no overprint concept) at all.
    public let overprintPasses: [[[NSAttributedString]]]
    /// Job 227: per page, per line fragment (same indexing as `softLineFlags`) — `nil`
    /// unless that fragment's own base `PageLine` is OVERSIZED (`lineExceedsFragment`: its
    /// tallest resolved glyph is far taller than the fragment `advanceLead` assigned it —
    /// LJ6DTP.WS's 72pt banner title and its `.lh .05"` shadow copy). The fragment's real,
    /// flowed content is left BLANK in that case (`renderNative`'s own call site); this is
    /// that line's TRUE content instead, rendered at its own natural (unbounded) height for
    /// `PagedDocumentView.drawOversizedSelfPasses` to composite at the PAPER level — this
    /// view's own text container is exactly the box the glyph doesn't fit in, so unlike an
    /// `.overprint` chain's passes (`overprintPasses` above), this canNOT be drawn by
    /// `PageTextView` itself. Empty in Modern style, which has no `PageLine`s at all.
    public let oversizedSelfPasses: [[NSAttributedString?]]
    /// Job 227: a fragment's TOP, plus this constant, is where a NORMAL (non-oversized)
    /// line's own baseline sits — the same quantity `renderNative` already derives once to
    /// place the container itself (`firstBaseline - firstBaselineOffset(...)`, this file's
    /// own doc comment on `textTop`). `PagedDocumentView.drawOversizedSelfPasses` uses it to
    /// land an oversized self-pass's baseline at that SAME target. `0` in Modern style,
    /// which has no passes at all.
    public let baselineOffset: CGFloat
    /// Job 396 (391 root cause 5): per LOCAL page, extra blank SCREEN canvas
    /// `PagedDocumentView` reserves ABOVE that page's own nominal top so an oversized
    /// FIRST-fragment self-pass (`oversizedSelfPasses[page].first`) can bleed its full,
    /// real ascent without the view's own hard clip cutting it off — see
    /// `PagedDocumentView.headroom(atPage:)`'s own doc comment for how it is spent. `0`
    /// for every page whose first fragment isn't oversized, or whose oversized ascent
    /// already fits inside `firstBaseline`'s existing small allowance. Purely a SCREEN/
    /// print/native-export affordance, like `PagedDocumentView.pageGap` — it never moves
    /// `textFrame`/`baselineOffset`, so it changes nothing about WHERE a glyph's baseline
    /// sits (the figure `emitPDF`'s own `pageStream` places identically), only how much
    /// blank room the view gives itself to draw into before that baseline. Empty (every
    /// page reads as `0`) in Modern style and both Show-Invisibles reflow annotated
    /// styles, none of which route any line through `oversizedSelfPasses` at all.
    public let leadingHeadroom: [CGFloat]
    /// Per page: the running heads/feet in force on that page (`Page.headers`/`.footers`,
    /// already replayed through pagination), positioned exactly where `emitPDF`'s
    /// `runningOps` puts them. UNLIKE `softLineFlags`, these belong in print/PDF export too
    /// — a running head is facsimile content, not a screen-only annotation — so
    /// `PageTextView` draws them unconditionally, with no `isDrawingToScreen` gate.
    ///
    /// `var`, not `let` (job 393, 391 root cause 2): Printed's own real pages are known at
    /// render time (`docToPagelines`), so `renderNative`/`renderNativeAnnotated` fill this
    /// in directly and it never changes again. Modern's pages are NOT known until AppKit lays
    /// the flow out (`PagedDocumentView.buildPages`'s own "AppKit is to decide" doc comment)
    /// — `renderModern` leaves this empty and hands back `hfEvents` instead;
    /// `PagedDocumentView` replays those against each REAL page's own first character offset
    /// once layout is done, then writes the result back here so `drawRunningLines` (Native/
    /// Printed/Modern alike) never has to know which style built its own running lines.
    public var runningLines: [[RunningLine]]
    /// Modern's own running-head/foot log (job 393, 391 root cause 2): one entry per
    /// `.hf` item `renderModern` walks past, in document order, at the CHARACTER OFFSET into
    /// `text` where it occurs — Modern's counterpart to the engine's `Page.headers`/
    /// `.footers` (already-resolved per real page), deferred to character-offset form because
    /// Modern has no real pages yet at render time (see `runningLines`'s own doc comment
    /// above). `PagedDocumentView` resolves these into real `RunningLine`s per AppKit page,
    /// replaying "the state in force when the page took its first content" — the SAME rule
    /// `PDFModernLayout.swift`'s own paginator (`modernStreams`'s `openPage()`) applies to the
    /// identical events, so a page the engine's Modern PDF gives a header gets one here too.
    /// Empty for every OTHER render (Printed, both annotated views), which never populate it.
    public let hfEvents: [HFEvent]
    /// The engine's `doc.page?.pnStart ?? 1` — Modern's own running lines substitute `#` for
    /// `pageNo`, the same token `runningLines(for:pageNo:doc:metrics:)` substitutes for
    /// Printed, and the real page number a local AppKit page shows depends on where in the
    /// document it falls, so this has to travel with `hfEvents` rather than being baked into
    /// their stored text. `1` (the engine's own default) when unused.
    public let pageNumberStart: Int
    /// Job 257 (Show Invisibles part 3/4, reflow): per LOCAL page, which page index into
    /// `docToPagelines(doc, printed: true)`'s own `[Page]` is "in force" there — the real
    /// engine page whose content that local page shows (or is about to show, if the local
    /// page opens with dot-command marks before any real line). Identity (`0, 1, 2, ...`)
    /// for the plain render, where local page IS the real page; for
    /// `renderNativeAnnotated`, invisible-only lines can push a real page's content across
    /// SEVERAL local pages once reflow spills it, so more than one local page can carry the
    /// SAME real-page index. This is the anchor `PagedDocumentView.realPageIndex(at:)`/
    /// `pageIndex(forRealPage:)` use to keep the reader's place across the Show Invisibles
    /// toggle — see those methods' own doc comments.
    public let realPageIndexByPage: [Int]
    /// Job 412 (Jon's ruling on job 408's decision brief, option (a): "pin it"): per real
    /// AppKit fragment, the ENGINE's own absolute baseline Y (points, top-down from the
    /// paper's top edge — same convention as `EngineTruth.StructuralLine.yFromTop`,
    /// `NativeStructuralParityTests.swift`) that fragment's content must land on, keyed by
    /// the CHARACTER OFFSET into `text` where that fragment's own content begins (its
    /// `lineAndTerminator`/`attributedLine` call's first character) rather than by fragment
    /// order. A character-offset key survives `PagedDocumentView`'s
    /// `NSLayoutManagerDelegate` being asked for the SAME fragment more than once (the
    /// probe-container pass, then again once laid into the real per-page containers,
    /// `buildExplicitPages`'s own doc comment) and in whatever order AppKit chooses to
    /// (re)lay text out — document position is the one thing that never changes.
    ///
    /// This is job 411's fix: AppKit stacks fragment N's top at fragment (N-1)'s own top
    /// plus (N-1)'s own PINNED height, but places fragment N's baseline at `top + K`, where
    /// `K` (the baseline-within-fragment offset AppKit itself computes from that fragment's
    /// own font/content) is a near-constant PER CONTENT CLASS, not a document-wide
    /// constant — every transition between two different-K neighbours leaves a permanent,
    /// uncorrected gap every later fragment on the page inherits (job 411's own root-cause
    /// citation has the full mechanism and the measured K values). Pinning the fragment's
    /// TOP directly from the engine's own Y-advance arithmetic (the same `advanceLead`
    /// walk `renderNative` already performs for pagination — see `PagedDocumentView`'s own
    /// delegate implementation) removes the accumulation at its source, leaving AppKit's own
    /// per-fragment `K` (and therefore its own font metrics) completely untouched — only
    /// WHERE the fragment sits changes, never how tall it is or where its own baseline sits
    /// within it.
    ///
    /// Empty in Modern style (reflowed by design — explicitly NOT pinned, Jon's ruling) and
    /// in `renderNativeAnnotated`'s Show Invisibles screen path (never measured by any
    /// structural-parity gate; left exactly as AppKit lays it out, unchanged by this job).
    public let pinnedBaselines: [Int: PinnedBaseline]
    /// Job 427 (Jon's ruling: "Native only changes fonts. Otherwise it's the same as
    /// Printed."): per LOCAL page, the text container's own TOP EDGE distance from the
    /// paper's top — the per-page counterpart to what used to be `textFrame.origin.y`
    /// alone. A page whose own `.mt`/`.mb` differs from the document's global pair
    /// (`Page.mtLines`/`.mbLines`, engine Finding 3/b26-print-fidelity-2 — see
    /// `PDFWriter.swift`'s own per-page `pageTop` swap, `emitPDF`'s per-page loop) gets its
    /// own real engine top margin here, not the document-global one — SCRIPT.WS's own
    /// figure-listing pages (very different `.mt` from the screenplay body) are the
    /// proving case. `pinnedBaselines`' own `PinnedBaseline.y` is already computed from
    /// each page's own real anchor (`pageFirstBaseline`, itself now built from this same
    /// per-page top); this field is the container-placement half of that same fix — see
    /// `PagedDocumentView.layout()`/`textTop(atPage:)` and its `NSLayoutManagerDelegate`
    /// conformance for the two call sites that convert `pinnedBaselines`' absolute paper-Y
    /// into container-local coordinates using THIS page's own entry, not a single shared
    /// one.
    ///
    /// One shared, repeated value (`textFrame.origin.y`) in every OTHER render path
    /// (Modern, both Show Invisibles annotated views) — none of those have a per-page
    /// margin override concept, matching `pinnedBaselines`'s own emptiness there.
    /// `PagedDocumentView.textTop(atPage:)` falls back to `textFrame.origin.y` for any
    /// page index this array doesn't cover (Modern's real page count isn't known until
    /// AppKit lays it out, so this array is only ever seeded with a placeholder entry
    /// there).
    public let perPageTextTop: [Double]
    /// Job 412: per page, the engine's own pinned BOTTOM edge (page-relative — same
    /// "distance from THIS page's own paper top" convention as `pinnedBaselines`'s own
    /// `PinnedBaseline.y`) — what `PagedDocumentView.buildExplicitPages` needs to size a
    /// PINNED page's real container correctly.
    ///
    /// The probe measurement that function already performs (AppKit's own natural,
    /// UNPINNED stacking) is no longer trustworthy for sizing a page whose REAL (pinned)
    /// content has been compacted or expanded relative to that natural stacking — job 411's
    /// own drift, by construction, is the difference between the two. A page the probe
    /// measured too SHORT for its own pinned content overflows its own last fragment into
    /// the NEXT page's container once really laid out pinned (confirmed empirically:
    /// several fixtures' pages landed a whole PAGE off before this field existed).
    ///
    /// Computed as `lastGroupEngineY + lastGroupOwnHeight - lastGroupIsolatedK`: the
    /// fragment's real RECT bottom, not merely its baseline plus height — a fragment's own
    /// RECT TOP sits `K` (`firstBaselineOffset`'s own quantity) ABOVE its baseline, not AT
    /// it, so leaving `K` out overstates how much room the fragment needs by exactly one
    /// `K` (confirmed empirically: naively using `baseline + height` alone left enough
    /// spare room at a page's own bottom for AppKit to fit ONE MORE line there than
    /// `docToPagelines` assigned that page, silently pulling the next page's own first
    /// line into the wrong container). `lastGroupIsolatedK` is measured the same "ask
    /// AppKit, don't derive it by hand" way `firstBaselineOffset` measures its own figure —
    /// laying out the LAST group's own real content in an isolated single-line probe and
    /// reading `location(forGlyphAt: 0).y` — rather than the whole-document PINNED probe
    /// `buildExplicitPages` already runs (an earlier attempt at that: pin the SAME probe
    /// using a monotonic per-page Y band so it measures pinned deltas directly — regressed
    /// several previously-clean fixtures by consistently one line per page boundary,
    /// root cause not fully isolated; this ONE-FRAGMENT isolated measurement sidesteps
    /// whatever that whole-document-scale mechanism was).
    ///
    /// Empty in Modern style and `renderNativeAnnotated`'s Show Invisibles path, matching
    /// `pinnedBaselines`'s own emptiness there — `buildExplicitPages` falls back to its
    /// existing AppKit-probe-only measurement whenever this is empty or missing an entry.
    /// Per page, each of its newspaper columns' own bottom — one entry for an ordinary
    /// page. A column is about to become its own text container, and a container is sized
    /// from its own content, not its page's.
    public let pinnedPageBottoms: [[Double]]
    /// And the same column's own TOP — its first fragment's top edge, which is that
    /// fragment's own pinned baseline less its own ascent, on the same absolute paper scale
    /// as `pinnedPageBottoms`.
    ///
    /// A container is measured from where its flow actually STARTS, and that is not always
    /// the text frame's top. `textFrame.origin.y` is the document's top margin plus a fixed
    /// three points, which is right at any ordinary lead and wrong at a small one: MARKUP.WS
    /// sets its whole page at a 2pt lead, so its first baseline is 38.0 against a text frame
    /// starting at 39.0 — the flow begins a point ABOVE the box it is measured in. Measured
    /// from the frame, that page's container came to 43.5pt for a flow that stacks 44.0, and
    /// the last of its 22 lines did not fit.
    public let pinnedPageTops: [[Double]]
    /// How far the container anchor had to be LOWERED to reach the flow it holds — zero on
    /// every ordinary document, negative only where the lead is smaller than the face's own
    /// first-baseline offset (MARKUP.WS's 2pt page). `buildPages` gives the container that
    /// much extra room at the bottom, because the flow that used to start above the anchor
    /// now starts at it and still has to end where it did.
    public let flowTopAdjustment: Double
    /// Per page, how many line FRAGMENTS each of its newspaper columns contributes — the
    /// model's own answer, counted the way this renderer forms fragments (an overprint chain
    /// is one) rather than measured from a layout.
    ///
    /// Nothing reads it yet. It is what sizes each column's own text container when the
    /// columns come back into the flow as real text (Jon's ruling, 2026-09-10): a container
    /// has to be sized to its own column's lines, and the only trustworthy count of those is
    /// the engine's, not a probe of a layout that has not happened.
    public let pageColumnFragmentCounts: [[Int]]
    /// Planning #251(d): per page, the `.l#` gutter numbers — `PageLine.lineNo`, which the
    /// engine resolves onto the model (the label AND its absolute, already right-aligned x)
    /// rather than counting lines at render time.
    ///
    /// Painted rather than flowed for the plain reason that they are not in the flow: the
    /// gutter sits in the margin `.po`已 reserved, LEFT of the text container's own edge, and
    /// edge, and no line of body text has any relationship to it. One document in the corpus
    /// uses them
    /// (PRINT.TST, 23 lines); the app drew none of them before this.
    public let lineNumberPasses: [[ColumnPass]]
    /// Planning #251(c): per page, per line fragment, the engine's own placement for every
    /// cp437 graphic character that fragment draws — `PageLine.graphicCells`, carried
    /// through untouched.
    ///
    /// The app has drawn these as vectors for a long time (`NativeVectorGraphics`), but it
    /// placed them at AppKit's own glyph positions, which are the Mac face's advances rather
    /// than the library's cells. The model now states the cell, so the two stop being
    /// independent answers to the same question. Empty in Modern style and the Show
    /// Invisibles path, like the pinned arrays beside it.
    public let graphicCellRows: [[[PageLine.GraphicCellPlacement]]]
    /// b28 note 11 (Jon's screenplay page-break ruling): character offsets into `text`,
    /// ascending, where a screenplay page-number-marker paragraph (`ModernScreenplay
    /// .matchesPageMarker`) begins — rule (a) of `ModernScreenplay`'s own doc comment,
    /// closed here. `PagedDocumentView.buildPages` is the sole consumer: it forces AppKit's
    /// own container chain to stop just short of each offset (`BreakingTextContainer`), so
    /// the marker paragraph lands as the FIRST content of a new page instead of wherever
    /// natural reflow would have put it.
    ///
    /// Gated by the identical `screenplayBlocks`/`screenplayMarkerBis` membership test rule
    /// (b) already uses — Jon's own ruling ("only supposed to apply when our code detects a
    /// screenplay") scopes this exactly as narrowly as the right-alignment fix it travels
    /// alongside. Populated ONLY by `renderModern` — the view Jon reported the missing break
    /// in. Empty (the default) in every other render path, including `renderModernAnnotated`
    /// (Show Invisibles' Modern path never ported ANY of `ModernScreenplay`'s rules — a
    /// pre-existing gap this job did not widen scope to close) and both Printed paths, none
    /// of which have a screenplay-marker concept at all.
    public let modernForcedPageBreakOffsets: [Int]
    /// Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like Printed —
    /// job 490 item 1 got the right PAGE and the wrong PLACE): Modern's counterpart to
    /// `hfEvents`, but read DURING `PagedDocumentView.buildPages` rather than resolved after
    /// it — a footnote's own reserved block changes that page's usable HEIGHT, unlike a
    /// running head/foot, which floats in the margin gutter beside the text container and
    /// never affects container sizing at all. One entry per paragraph `renderModern` walks
    /// that carries at least one footnote, keyed by `charOffset` (`text.length` at that
    /// paragraph's own first character, the SAME anchor `modernForcedPageBreakOffsets` uses)
    /// — job 490's "the marker's own paragraph" placement rule restated for a consumer that
    /// reads it once real pages exist: whichever real page contains this offset draws
    /// `entries` at its own foot (see `ModernFootnoteEvent`'s own doc comment for why they
    /// need no styling knowledge to draw). Empty in every other render path, including
    /// `renderModernAnnotated` (Show Invisibles' Modern path never ported job 490's per-
    /// marker placement either — a pre-existing gap this job does not widen scope to close,
    /// same boundary `modernForcedPageBreakOffsets`'s own doc comment already draws) and
    /// both Printed paths, whose own footnote placement is the engine's `docToPagelines`
    /// pagination, already real by the time `DocumentRenderer` sees it.
    public let modernFootnoteEvents: [ModernFootnoteEvent]
    /// Job 502: the SAME 20-dash separator the end-of-document note appendix draws
    /// (`renderModern`'s `.noteSeparator` case), pre-styled identically and shared here so a
    /// footnote block at a page's foot uses the exact same rule, never a second one.
    /// Content-empty (but still a valid, attribute-bearing string) whenever
    /// `modernFootnoteEvents` is empty — never drawn in that case, so its content never
    /// matters, but a real (rather than optional) value keeps `PagedDocumentView` from
    /// needing a nil-handling branch for a field that, in practice, is either fully unused
    /// or unconditionally needed.
    public let modernFootnoteSeparator: NSAttributedString
    /// Planning #221 (Jon's ruling 2026-09-07, verbatim): "endnotes go right at the end of
    /// text / image on the last page unless there are footnotes on that page. Then the
    /// endnotes start on a new page." Character offset into `text` of the end-matter
    /// appendix's own first character — the 20-dash separator `renderModern`'s
    /// `.noteSeparator` case appends — or nil for a document with no end-matter notes at
    /// all, which is nearly all of them.
    ///
    /// This is the app's counterpart to the engine's `ModernFlowItem.para(endNotesStart:)`
    /// flag, and deliberately the same shape: the engine sets it on exactly the ONE
    /// paragraph built from `.noteSeparator`, and so does this. What differs is only WHERE
    /// the rule can be applied. The engine's `modernStreams` knows each page's reserved
    /// footnote lines before it places anything, so it can test the appendix against them
    /// up front; AppKit does not decide Modern's page breaks until a container has actually
    /// been laid out, so `PagedDocumentView.buildPages` applies the identical rule one real
    /// page at a time, right after that page's own footnote reservation — the same place,
    /// and for the same reason, that `reserveFootnoteBlock` already has to run there.
    ///
    /// Nil in every other render path, including `renderModernAnnotated` and both Printed
    /// paths, on the same boundary `modernFootnoteEvents` already draws — Printed's endnote
    /// placement is the engine's own `docToPagelines` decision, already real by the time
    /// `DocumentRenderer` sees it.
    public let modernEndnoteAppendixStart: Int?
    /// Job 502: per REAL local page (`PagedDocumentView.buildPages`'s own container index —
    /// filled in as that loop goes, not resolved after like `runningLines`, since the value
    /// itself is what decides that page's own container height), the footnote entries
    /// `drawFootnoteBlock` paints at the page's foot, dash-separated, in `modernFootnoteEvents`
    /// order. Empty for every LOCAL page with no footnote attached to it, and for every
    /// render path that never populates `modernFootnoteEvents` in the first place.
    public var modernFootnoteBlocks: [[NSAttributedString]] = []
    /// A BLANK LINE AT A PAGE TOP COSTS NOTHING — the library's own rule, stated in
    /// `PDFModernLayout`'s paginator as `case .blank: guard !body.isEmpty else { continue }
    /// // no blank at a page top`, and again one line down (a blank that does not fit closes
    /// the page and is dropped rather than carried over).
    ///
    /// The app cannot express that where the string is built, because nothing there knows
    /// where a page will break — AppKit decides that. So `renderModern` records each blank
    /// line's own character range here, ascending and non-overlapping, and
    /// `PagedDocumentView.buildPages` — the one place Modern's REAL pages exist — collapses
    /// a recorded blank that lands at the top of a page it has just opened.
    ///
    /// Measured against the library's own Modern PDF (2026-09-11): six of -README.WS's 21
    /// pages and two of SCRIPT.WS's 16 began one whole line lower than the library's with
    /// identical content, and everything below shifted with them.
    ///
    /// Populated ONLY by `renderModern`, like `modernForcedPageBreakOffsets` beside it —
    /// Show Invisibles draws its own "¶" on a blank line (it is a mark the reader asked to
    /// SEE), and neither Printed path has a reflowed blank at all.
    public var modernBlankLineRanges: [NSRange] = []
    /// `.cp` — a CONDITIONAL page break, recorded as (where, how much room it wants) because
    /// only the view can answer the second half. The engine's rule is `if !body.isEmpty,
    /// y - (margb + noteBlockH()) < need { close() }` with `need = n * modernLine *
    /// modernBodyPt`; `PagedDocumentView.buildPages` applies exactly that against a real
    /// page. Populated only by `renderModern`.
    public var modernConditionalBreaks: [ModernConditionalBreak] = []
    /// Job 490 (item 1, LJ6DTP title-top): `Document.pclPrograms` verbatim, threaded through
    /// so `PageTextView.drawPCLGraphics` (`NativePCLGraphics.swift`) can execute a `.pctl`
    /// attachment's own embedded PCL program at draw time — see that file's top doc comment.
    /// Empty in Modern style, which has no `PageLine`/paper-facsimile concept for a PCL
    /// rectangle to draw against at all.
    public let pclPrograms: [[UInt8]]
    /// Batch 41 (A): what the engine's Modern PDF draws on each page besides body text
    /// (`modernPageFurniture`, engine be5fefb) — the sheet, the text frame, the newspaper columns.
    /// Empty for every non-Modern render.
    public var modernFurniture: [ModernPageFurniture] = []
    /// The flags THIS render was asked for, carried so the view can check them against what the furniture holds.
    ///
    /// THE ENGINE IS THE DECISION (batch 42). `modernEngineOptions` now asks for the furniture with the run's
    /// own flags, and engine ce41797 made Modern honour `EmitOptions.headers` — so a render asked for with
    /// headers off gets furniture carrying no heads, and there is nothing left for the view to suppress.
    ///
    /// THE RESOLVERS' GATE STAYS, as a defensive assertion rather than the mechanism. It costs one comparison
    /// and it fails closed: if a furniture record ever arrives with heads on a render that asked for none —
    /// a stale cached record, a caller that forgot to thread its flags, an engine regression — the view draws
    /// nothing rather than putting a running head on a page the export said should have none.
    ///
    /// The history is worth keeping, because the first fix looked right and did nothing. Suppression used to be
    /// a property of the TEXT: `guard exportFlags.headers else { return }` skipped recording the `.hf` events,
    /// and the view drew from those events. Batch 41 moved the view onto the furniture, which then reported its
    /// heads regardless, and an export with `--headers off` kept them — three failures in the release gate.
    /// Passing `options.headers` was tried first and changed nothing, because Modern ignored that flag in both
    /// engines; the flag governed Printed and RTF only. Gating consumption is what actually fixed it, and the
    /// engine change since has made asking work too. Both halves are now in place, in that order.
    public var exportFlags = DocumentRenderer.ExportFlags.allOn
    /// Batch 41 (columns): per Modern page, where each of its columns ends in THIS render's own text — the engine's own
    /// column partition (`ModernPageFurniture.columnRanges`, engine 63fab84) resolved against the text this render
    /// built. Empty when no furniture covers the render, where the views keep their own chain of forced breaks.
    public var modernColumnBreaks: [[ModernColumnBreak]] = []
    /// Batch 41 (columns): where each flow item began in this render's own text, or -1 for an item that put nothing
    /// there. The engine names a column's end as an item and an offset inside it, and the two texts are NOT the same
    /// length — the engine's flow carries `hf` and `break` text the view's does not — so this is what the mapping
    /// resolves against, and what a test needs to say WHERE the two disagree rather than only that they do.
    public var modernItemStarts: [Int] = []
    /// Batch 47 (M31-app): each page's own sheet, in points — a page whose `.pr or=` differs from the document's prints
    /// landscape inside a portrait document (engine 07b040c), and Native draws it on that sheet. Empty (every page on
    /// `pageSize`) for Modern, which stays on one sheet by design.
    public var perPageSize: [CGSize] = []
    /// Batch 48 (E10, engine 8b4862f; Jon: page furniture "needs to follow the general font rules. If fonts are declared
    /// for headers and footers, use them."): the face Modern draws a head, foot or automatic page number in when its
    /// line declares no font — the body's own fontless face (the reader's Modern face, or Courier Prime under `.ps off`)
    /// at the body size less 2 pt. Nil outside Modern.
    public var modernFurnitureFont: NSFont?
    /// The font records the document's `.h#`/`.f#` lines open (`Document.headerFonts`/`footerFonts`), by line number.
    public var modernHeaderFonts: [Int: FontChange] = [:]
    public var modernFooterFonts: [Int: FontChange] = [:]

    /// Native's page placement (the engine's `logicalPageX`): how far in from the sheet's left edge the engine's
    /// x = 0 sits. Printed lays a page out in the LaserJet's own frame and places it 1/4" in on a Letter sheet, so
    /// every engine x (`PageLine.left`, the running lines' `x`, a `.l#` number, a graphic cell, a PCL program's
    /// absolute move) is measured from there. `documentLogicalPageX` is the document's own sheet's, and is already
    /// inside `textFrame.origin.x`; `perPageLogicalX` holds each page's, which differs only on a page turned by its
    /// own `.pr or=`. Zero, and empty, for every surface but Native.
    public var documentLogicalPageX: Double = 0
    public var perPageLogicalX: [Double] = []

    /// Page `index`'s placement: its own, or the document's.
    public func logicalPageX(atPage index: Int) -> CGFloat {
        CGFloat(perPageLogicalX.indices.contains(index) ? perPageLogicalX[index] : documentLogicalPageX)
    }

    /// How much further right page `index`'s text sits than `textFrame` says: nonzero only on a page whose own
    /// orientation gives it a different placement from the document's.
    public func logicalShift(atPage index: Int) -> CGFloat {
        logicalPageX(atPage: index) - CGFloat(documentLogicalPageX)
    }

    /// The engine x a page view's own x = 0 stands for — `textFrame.origin.x` back in the engine's frame. Anything
    /// the engine places by an absolute x is drawn at that x less this, inside the view; or, measured from a
    /// page's paper corner, at the page's `logicalPageX(atPage:)` plus that x.
    public var engineLeftAnchor: CGFloat {
        textFrame.origin.x - CGFloat(documentLogicalPageX)
    }

    /// Page `index`'s sheet: its own, or the document's.
    public func pageSize(atPage index: Int) -> CGSize {
        perPageSize.indices.contains(index) ? perPageSize[index] : pageSize
    }

    /// The widest sheet — the width a view of every page needs.
    public var widestPageWidth: CGFloat {
        perPageSize.map(\.width).max().map { max($0, pageSize.width) } ?? pageSize.width
    }

    /// Every stored property, as the memberwise initializer has them (public, for the app's synthesized pages).
    public init(
        text: NSAttributedString,
        pageSize: CGSize,
        textFrame: CGRect,
        pageCount: Int,
        clipsLines: Bool,
        softLineFlags: [[Bool]],
        overprintPasses: [[[NSAttributedString]]],
        oversizedSelfPasses: [[NSAttributedString?]],
        baselineOffset: CGFloat,
        leadingHeadroom: [CGFloat],
        runningLines: [[RunningLine]],
        hfEvents: [HFEvent],
        pageNumberStart: Int,
        realPageIndexByPage: [Int],
        pinnedBaselines: [Int: PinnedBaseline],
        perPageTextTop: [Double],
        pinnedPageBottoms: [[Double]],
        pinnedPageTops: [[Double]],
        flowTopAdjustment: Double,
        pageColumnFragmentCounts: [[Int]],
        lineNumberPasses: [[ColumnPass]],
        graphicCellRows: [[[PageLine.GraphicCellPlacement]]],
        modernForcedPageBreakOffsets: [Int],
        modernFootnoteEvents: [ModernFootnoteEvent],
        modernFootnoteSeparator: NSAttributedString,
        modernEndnoteAppendixStart: Int?,
        modernFootnoteBlocks: [[NSAttributedString]] = [],
        modernBlankLineRanges: [NSRange] = [],
        modernConditionalBreaks: [ModernConditionalBreak] = [],
        pclPrograms: [[UInt8]],
        modernFurniture: [ModernPageFurniture] = [],
        exportFlags: DocumentRenderer.ExportFlags = .allOn,
        modernColumnBreaks: [[ModernColumnBreak]] = [],
        modernItemStarts: [Int] = [],
        perPageSize: [CGSize] = [],
        modernFurnitureFont: NSFont? = nil,
        modernHeaderFonts: [Int: FontChange] = [:],
        modernFooterFonts: [Int: FontChange] = [:]
    ) {
        self.text = text
        self.pageSize = pageSize
        self.textFrame = textFrame
        self.pageCount = pageCount
        self.clipsLines = clipsLines
        self.softLineFlags = softLineFlags
        self.overprintPasses = overprintPasses
        self.oversizedSelfPasses = oversizedSelfPasses
        self.baselineOffset = baselineOffset
        self.leadingHeadroom = leadingHeadroom
        self.runningLines = runningLines
        self.hfEvents = hfEvents
        self.pageNumberStart = pageNumberStart
        self.realPageIndexByPage = realPageIndexByPage
        self.pinnedBaselines = pinnedBaselines
        self.perPageTextTop = perPageTextTop
        self.pinnedPageBottoms = pinnedPageBottoms
        self.pinnedPageTops = pinnedPageTops
        self.flowTopAdjustment = flowTopAdjustment
        self.pageColumnFragmentCounts = pageColumnFragmentCounts
        self.lineNumberPasses = lineNumberPasses
        self.graphicCellRows = graphicCellRows
        self.modernForcedPageBreakOffsets = modernForcedPageBreakOffsets
        self.modernFootnoteEvents = modernFootnoteEvents
        self.modernFootnoteSeparator = modernFootnoteSeparator
        self.modernEndnoteAppendixStart = modernEndnoteAppendixStart
        self.modernFootnoteBlocks = modernFootnoteBlocks
        self.modernBlankLineRanges = modernBlankLineRanges
        self.modernConditionalBreaks = modernConditionalBreaks
        self.pclPrograms = pclPrograms
        self.modernFurniture = modernFurniture
        self.exportFlags = exportFlags
        self.modernColumnBreaks = modernColumnBreaks
        self.modernItemStarts = modernItemStarts
        self.perPageSize = perPageSize
        self.modernFurnitureFont = modernFurnitureFont
        self.modernHeaderFonts = modernHeaderFonts
        self.modernFooterFonts = modernFooterFonts
    }
}

/// Batch 41 (columns): one Modern column's own end in the view's text.
public struct ModernColumnBreak: Sendable {
    /// The column this content sits in, `0..<columns`. Not always the container's ordinal: a column the engine's
    /// pagination left empty is not reported at all, and its items roll into the next column that took some.
    public let column: Int
    /// Where this column's content ends in the view's own text — `nil` for the last column of the last page, which
    /// runs to the end.
    public let end: Int?
}

extension RenderedDocument {
    /// Batch 41 (columns): how many newspaper columns the engine lays page `page` in (`ModernPageFurniture.columns`,
    /// which a `.co` regime change varies from page to page). One for every other render, and for a page the engine
    /// lays no Modern page for.
    public func modernColumns(onPage page: Int) -> Int {
        guard !clipsLines, modernFurniture.indices.contains(page) else { return 1 }
        return max(1, modernFurniture[page].columns)
    }

    /// One Modern column's width on page `page` — the engine's own, or the whole text frame where there is one column.
    public func modernColumnWidth(onPage page: Int) -> CGFloat {
        guard modernColumns(onPage: page) > 1, modernFurniture.indices.contains(page) else { return textFrame.width }
        return max(1, CGFloat(modernFurniture[page].columnWidth))
    }

    /// How far column `index` of page `page` starts right of the text frame's own left edge.
    public func modernColumnOffset(_ index: Int, onPage page: Int) -> CGFloat {
        guard index > 0, modernColumns(onPage: page) > 1, modernFurniture.indices.contains(page) else { return 0 }
        let furniture = modernFurniture[page]
        return CGFloat(index) * (CGFloat(furniture.columnWidth) + CGFloat(furniture.columnGutter))
    }
}

/// Job 412: one `RenderedDocument.pinnedBaselines` entry — see that field's own doc comment.
/// `page` travels alongside `y` (not just the page-relative Y alone) because
/// `PagedDocumentView`'s delegate needs it too: `buildExplicitPages`'s own whole-document
/// probe container lays every page's content into ONE shared coordinate space, where a
/// page-relative `y` that resets at every page's own top would make page 2's content jump
/// BACKWARD and overlap page 1's — `page` is what lets that one call site give the probe a
/// monotonically increasing target instead, without changing what the REAL per-page
/// containers use (see that delegate's own doc comment for the two call shapes).
public struct PinnedBaseline: Sendable {
    public let page: Int
    /// Which of that page's newspaper columns the fragment belongs to — 0 for every line of
    /// every ordinary page. `PagedDocumentView` builds one text container per column per
    /// page (item 19, Jon's ruling 2026-09-10), and `page` and `column` together name the
    /// container a fragment belongs in.
    public var column: Int = 0
    public let y: Double
    /// Job 413: this line's own deterministic baseline-from-fragment-top offset, computed
    /// once here via an isolated off-screen probe (`isolatedFragmentK`) of this line's own
    /// content with any `.sup`/`.sub` styling stripped (`desuperscripted` below) — NOT read
    /// live from AppKit's own per-pass `baselineOffset` out-param the way job 412 did.
    ///
    /// Two problems traced to that one live read: (1) a raised/lowered run's OWN glyph is
    /// deliberately size-reduced-and-offset (`attributedRun`'s `scriptMetrics` call) to fit
    /// inside the base font's envelope, but AppKit's live per-fragment report for the line
    /// still shifted a hair when one was present — pinning to that live number moved the
    /// whole LINE on account of a mark that should only move WITHIN it (DARKNESS.WS's
    /// footnote-marker residual, job 413). (2) that same live report also varies a hair
    /// between a windowed and a windowless AppKit layout pass (job 412's own disclosed
    /// QL-vs-app regression). Stripping `.sup`/`.sub` before probing removes the line's own
    /// content from cause (1); probing off-screen instead of reading the real in-window (or
    /// in-QL) layout pass removes it from cause (2) — both app and QuickLook call this same
    /// `DocumentRenderer` function and get the identical number.
    public let k: Double
    /// THIS FRAGMENT'S OWN HEIGHT — the lead the renderer assigned it.
    ///
    /// `paragraphStyle` already pins `minimumLineHeight == maximumLineHeight == lead`, and
    /// AppKit does not always honour it: a run set in a face whose natural line height
    /// exceeds the lead comes back TALLER. Measured on WINGDING.CHT, a Wingdings chart whose
    /// lines read `76   L ✬` — Courier Prime for the code, Helvetica Neue for the letter,
    /// Zapf Dingbats for the mark, each its own homogeneous run, every face the app's OWN
    /// correct choice — the clamp reads [14.00, 14.00] and the fragment comes back 14.34.
    /// PRINTER.PS reaches 17.00 against the same 14.00.
    ///
    /// Nothing about the FONT SELECTION is wrong there, so no font fix can help: coverage-
    /// aware resolution was wired and measured (it made the fragment 14.39 and changed
    /// nothing else), and there is no mixed run to split. The excess accumulates —
    /// 44 lines x 0.34pt is 14.96pt, more than one whole line — until the page runs out of
    /// room and the last line is pushed onto the next, which is the ten page boundaries the
    /// pagination oracle reports across six Sawyer charts.
    ///
    /// So the delegate that already pins this fragment's ORIGIN and BASELINE pins its HEIGHT
    /// too. That is the same mechanism finishing its own job, in the one place that already
    /// decides fragment geometry — not a second clamp layered over one that failed.
    public let height: Double
}

/// Job 413: `line` with every span's `.sup`/`.sub` style bit cleared — used ONLY to probe
/// `PinnedBaseline.k` (`isolatedFragmentK` below), never for real drawn content. A raised or
/// lowered run's own glyph is a DECORATION within the line (`attributedRun`'s own
/// `scriptMetrics` doc comment: sized and offset to fit inside the base font's envelope), not
/// a property of where the LINE ITSELF sits — probing with it still present let that
/// decoration perturb the whole line's pinned position (see `PinnedBaseline.k`'s own doc
/// comment for the DARKNESS.WS defect this fixes).
func desuperscripted(_ line: PageLine) -> PageLine {
    var copy = line
    for i in copy.indices { copy[i].styles.subtract([.sup, .sub]) }
    return copy
}

/// One running head/foot line, positioned in the app's own top-down convention (baseline
/// distance from the paper's top edge, matching `RenderedDocument.textFrame`'s origin).
/// Pre-styled (Courier at the document's printed size, black ink — the same face `emitPDF`
/// names for a running line, `PDFWriter.swift:209`'s `pdfFont(bold: false, italic: false)`)
/// so `PagedDocumentView` only ever has to draw it, never reconstruct its font.
public struct RunningLine {
    /// Batch 41 (C): `autoPageNumber` is WordStar's own automatic number, which rides a footer's row but is NOT a
    /// typed `.f#` line — a document can carry both, and a test that asked "which of these is the number" could
    /// only have guessed from the text otherwise. Nothing switches exhaustively on this, and the probes' own
    /// `isHeader` test (`kind == .header`) stays right: the number is not a header.
    public enum Kind: Sendable { case header, footer, autoPageNumber }
    public let text: NSAttributedString
    public let baselineFromTop: Double
    /// How far `PagedDocumentView.drawRunningLines` must pull its `NSAttributedString
    /// .draw(at:)` origin ABOVE `baselineFromTop` for that call's true baseline to land ON
    /// `baselineFromTop` — AppKit-measured (`DocumentRenderer.firstBaselineOffset`, the SAME
    /// "ask the layout manager, don't derive it by hand" discipline the body text container's
    /// own `normalBaselineOffset` uses), not `font.ascender` (job 228: `draw(at:)` still goes
    /// through a real AppKit line-height decision — "point-drawn, so there's no layout
    /// decision to ask about" was this file's own wrong assumption, see this job's citations).
    public let drawOriginOffset: Double
    public let kind: Kind
    /// Job 489 (b29 adoption, register C6): extra distance PAST `PagedDocumentView
    /// .drawRunningLines`'s ordinary `x` a line with its own font block starts drawing at —
    /// zero for every line that goes through the plain Courier path below. Mirrors the
    /// engine's own `hfLineOps` (`PDFWriter.swift`): a PROPORTIONAL font's leading
    /// whitespace advances the pen without emitting a `Tj`, so `text` above never carries
    /// those characters at all — this is the width that skipped run would have occupied,
    /// measured the same way `appendSpan`'s body-text indent carve-out already measures it
    /// (the document's base Courier at its own size — "already advances at exactly that
    /// grid" per that call site's own citation).
    public var leadingOffset: Double = 0
    /// MECHANISM O (engine commit 840cf4c, mirroring ctrl-kd 55d2b52): how far THIS PAGE's
    /// own `.po` (page offset) moves the running head/foot's left edge away from the
    /// document's global one — signed, and zero for every page of every document that never
    /// changes `.po` mid-document.
    ///
    /// The engine resolves a page-local left (`Page.poCols`, set by
    /// `layoutPrintedPagesPlain` from `poTimeline`) and hands it to `runningOps` ALONE:
    /// `emitPDF`'s own `pageStream` keeps the document's global `left` unchanged, because
    /// body text already carries a per-LINE `.po` override (`Line.poCols` -> the public
    /// `PageLine.left` this renderer reads as `extraLeftPt`). The running head was the one
    /// row with no page-granularity twin. SCRIPT.WS's worked-example figures are the real
    /// case: they reset `.po` to `.5"` alongside their `.mt`/`.hm` changes, and WS7's own
    /// capture moves the running head's left edge with it.
    ///
    /// Stored as an OFFSET rather than an absolute x because `drawRunningLines` places every
    /// running line from `rendered.textFrame.origin.x` — the document's global left, already
    /// in view coordinates — and this is the only thing that varies per page.
    public var pageLeftOffset: Double = 0
}

/// One header/footer state change in Modern's own flow (job 393, 391 root cause 2) — see
/// `RenderedDocument.hfEvents`'s own doc comment for why Modern needs this indirection where
/// Printed does not. `charOffset` is `RenderedDocument.text.length` at the moment
/// `renderModern` walked past the `.hf` item; `line`/`text` are the same `HFKind`-scoped
/// running-line slot and content `CtrlKD.SemanticItem.hf` carries (an empty `text` clears
/// that slot from here on, exactly as `Document.headers`' own doc comment says — filtered out
/// at RESOLVE time, in `DocumentRenderer.modernRunningLines`, not recorded away here, so a
/// later page correctly sees the slot as cleared rather than reverting to whatever it held
/// before).
public struct HFEvent: Sendable {
    public let kind: RunningLine.Kind
    public let line: Int
    public let text: String
    public let charOffset: Int
}

/// One paragraph's worth of footnote attachments in Modern's own flow — see
/// `RenderedDocument.modernFootnoteEvents`'s own doc comment for the full mechanism this
/// exists for (job 502). `entries` are already fully styled (`noteFont`/`noteParagraph`, the
/// SAME attributes the end-of-document note appendix already draws with — `appendNoteLine`
/// in `renderModern`) and each one already carries its own trailing line terminator, so
/// `PagedDocumentView` can measure and draw a page's footnote block by straight
/// concatenation, with no styling knowledge of its own.
public struct ModernFootnoteEvent {
    public let charOffset: Int
    public let entries: [NSAttributedString]
}

/// One `.cp`: the character it sits at, and the room in points the paragraph after it needs
/// before a page may start it. See `RenderedDocument.modernConditionalBreaks`.
public struct ModernConditionalBreak: Sendable {
    public let charOffset: Int
    public let needPt: Double
}

/// Job 240 (b13, Part 1) — MAC VIEWING RULING (decision register 2026-08-11, restated and
/// binding; skill registry #25): "We are on a MAC now... we don't have to fool around with
/// making sure we only use native-to-PDF fonts... We are using that same availability to
/// make the Mac viewer awesome." Printed-mode font resolution no longer clamps a WS5+ font
/// run to the base-14 PDF set (the `NativeFontFamily` enum this replaced); it maps the
/// typestyle name through the SAME `.mac` render-target table the CLI's `--fonts mac`
/// target uses, so the viewer shows the real typeface family (Univers/Aachen/etc.) instead
/// of whichever of Times/Helvetica/Courier its generic-style bits happened to clamp to.
/// Engine PDF export is untouched — base-14 stays exactly right for that surface (Jon
/// ruled its PDF output looks good); this is a VIEWING-surface-only change.
