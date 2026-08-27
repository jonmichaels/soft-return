import AppKit
import CoreText
import CtrlKD

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
/// In Printed style, pagination is CtrlKD's decision, not AppKit's — `docToPagelines`
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
struct RenderedDocument {
    /// The whole document, styled and ready to flow.
    let text: NSAttributedString
    /// Paper size in points.
    let pageSize: CGSize
    /// The text area within one page — where the container sits on the paper.
    let textFrame: CGRect
    /// How many pages the flow will need.
    let pageCount: Int
    /// Whether lines are clipped rather than wrapped (Printed) or reflowed (Modern).
    let clipsLines: Bool
    /// Per page, per line (page N's own real lines only, no padding — see this type's
    /// "How the library's pagination is honoured" doc comment above): whether that
    /// `PageLine` carried CtrlKD's own `soft` flag — WordStar's own word wrap, as opposed
    /// to the author pressing Return. Also `PagedDocumentView.buildPages`'s own source for
    /// how many real AppKit fragments page N has — `softLineFlags[n].count` IS that page's
    /// real line count, by construction. Empty in Modern style, whose `mergedLines` already
    /// undid the physical wrap the flag would describe. Job 256 (Show Invisibles part 2/4):
    /// no longer what Show Invisibles overlays — the margin arrow this fed
    /// (`drawSoftReturnMarkers`) is gone, superseded by real inline marks baked into
    /// `renderPrintedAnnotated`'s own `text` (a SEPARATE `RenderedDocument`,
    /// `DocumentRenderer.renderWithInvisibles`'s screen-only output — never what print/
    /// export/QuickLook request). This field's only remaining job is the container-sizing
    /// one described above; its per-line VALUES are otherwise unused.
    let softLineFlags: [[Bool]]
    /// Job 224: per page, per line fragment (same indexing as `softLineFlags` — page N's own
    /// real lines only, no padding) — the EXTRA `.overprint`-chained `PageLine`s that share that
    /// fragment's baseline, in document order, rendered but never given a fragment of their
    /// own. `PageTextView` composites each one directly on top of the fragment's real glyph
    /// geometry (`PagedDocumentView.swift`'s `drawOverprintPasses`) instead of laying it out
    /// as its own (even near-zero-height) paragraph — see `renderPrinted`'s own doc comment
    /// on the pagination bug this replaces. Empty in Modern style, which has no `PageLine`s
    /// (and therefore no overprint concept) at all.
    let overprintPasses: [[[NSAttributedString]]]
    /// Job 227: per page, per line fragment (same indexing as `softLineFlags`) — `nil`
    /// unless that fragment's own base `PageLine` is OVERSIZED (`lineExceedsFragment`: its
    /// tallest resolved glyph is far taller than the fragment `advanceLead` assigned it —
    /// LJ6DTP.WS's 72pt banner title and its `.lh .05"` shadow copy). The fragment's real,
    /// flowed content is left BLANK in that case (`renderPrinted`'s own call site); this is
    /// that line's TRUE content instead, rendered at its own natural (unbounded) height for
    /// `PagedDocumentView.drawOversizedSelfPasses` to composite at the PAPER level — this
    /// view's own text container is exactly the box the glyph doesn't fit in, so unlike an
    /// `.overprint` chain's passes (`overprintPasses` above), this canNOT be drawn by
    /// `PageTextView` itself. Empty in Modern style, which has no `PageLine`s at all.
    let oversizedSelfPasses: [[NSAttributedString?]]
    /// Job 227: a fragment's TOP, plus this constant, is where a NORMAL (non-oversized)
    /// line's own baseline sits — the same quantity `renderPrinted` already derives once to
    /// place the container itself (`firstBaseline - firstBaselineOffset(...)`, this file's
    /// own doc comment on `textTop`). `PagedDocumentView.drawOversizedSelfPasses` uses it to
    /// land an oversized self-pass's baseline at that SAME target. `0` in Modern style,
    /// which has no passes at all.
    let baselineOffset: CGFloat
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
    let leadingHeadroom: [CGFloat]
    /// Per page: the running heads/feet in force on that page (`Page.headers`/`.footers`,
    /// already replayed through pagination), positioned exactly where `emitPDF`'s
    /// `runningOps` puts them. UNLIKE `softLineFlags`, these belong in print/PDF export too
    /// — a running head is facsimile content, not a screen-only annotation — so
    /// `PageTextView` draws them unconditionally, with no `isDrawingToScreen` gate.
    ///
    /// `var`, not `let` (job 393, 391 root cause 2): Printed's own real pages are known at
    /// render time (`docToPagelines`), so `renderPrinted`/`renderPrintedAnnotated` fill this
    /// in directly and it never changes again. Modern's pages are NOT known until AppKit lays
    /// the flow out (`PagedDocumentView.buildPages`'s own "AppKit is to decide" doc comment)
    /// — `renderModern` leaves this empty and hands back `hfEvents` instead;
    /// `PagedDocumentView` replays those against each REAL page's own first character offset
    /// once layout is done, then writes the result back here so `drawRunningLines` (Native/
    /// Printed/Modern alike) never has to know which style built its own running lines.
    var runningLines: [[RunningLine]]
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
    let hfEvents: [HFEvent]
    /// The engine's `doc.page?.pnStart ?? 1` — Modern's own running lines substitute `#` for
    /// `pageNo`, the same token `runningLines(for:pageNo:doc:metrics:)` substitutes for
    /// Printed, and the real page number a local AppKit page shows depends on where in the
    /// document it falls, so this has to travel with `hfEvents` rather than being baked into
    /// their stored text. `1` (the engine's own default) when unused.
    let pageNumberStart: Int
    /// Job 257 (Show Invisibles part 3/4, reflow): per LOCAL page, which page index into
    /// `docToPagelines(doc, printed: true)`'s own `[Page]` is "in force" there — the real
    /// engine page whose content that local page shows (or is about to show, if the local
    /// page opens with dot-command marks before any real line). Identity (`0, 1, 2, ...`)
    /// for the plain render, where local page IS the real page; for
    /// `renderPrintedAnnotated`, invisible-only lines can push a real page's content across
    /// SEVERAL local pages once reflow spills it, so more than one local page can carry the
    /// SAME real-page index. This is the anchor `PagedDocumentView.realPageIndex(at:)`/
    /// `pageIndex(forRealPage:)` use to keep the reader's place across the Show Invisibles
    /// toggle — see those methods' own doc comments.
    let realPageIndexByPage: [Int]
    /// Job 412 (Jon's ruling on job 408's decision brief, option (a): "pin it"): per real
    /// AppKit fragment, the ENGINE's own absolute baseline Y (points, top-down from the
    /// paper's top edge — same convention as `EngineTruth.StructuralLine.yFromTop`,
    /// `PrintedStructuralParityTests.swift`) that fragment's content must land on, keyed by
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
    /// walk `renderPrinted` already performs for pagination — see `PagedDocumentView`'s own
    /// delegate implementation) removes the accumulation at its source, leaving AppKit's own
    /// per-fragment `K` (and therefore its own font metrics) completely untouched — only
    /// WHERE the fragment sits changes, never how tall it is or where its own baseline sits
    /// within it.
    ///
    /// Empty in Modern style (reflowed by design — explicitly NOT pinned, Jon's ruling) and
    /// in `renderPrintedAnnotated`'s Show Invisibles screen path (never measured by any
    /// structural-parity gate; left exactly as AppKit lays it out, unchanged by this job).
    let pinnedBaselines: [Int: PinnedBaseline]
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
    let perPageTextTop: [Double]
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
    /// Empty in Modern style and `renderPrintedAnnotated`'s Show Invisibles path, matching
    /// `pinnedBaselines`'s own emptiness there — `buildExplicitPages` falls back to its
    /// existing AppKit-probe-only measurement whenever this is empty or missing an entry.
    let pinnedPageBottoms: [Double]
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
    let modernForcedPageBreakOffsets: [Int]
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
    let modernFootnoteEvents: [ModernFootnoteEvent]
    /// Job 502: the SAME 20-dash separator the end-of-document note appendix draws
    /// (`renderModern`'s `.noteSeparator` case), pre-styled identically and shared here so a
    /// footnote block at a page's foot uses the exact same rule, never a second one.
    /// Content-empty (but still a valid, attribute-bearing string) whenever
    /// `modernFootnoteEvents` is empty — never drawn in that case, so its content never
    /// matters, but a real (rather than optional) value keeps `PagedDocumentView` from
    /// needing a nil-handling branch for a field that, in practice, is either fully unused
    /// or unconditionally needed.
    let modernFootnoteSeparator: NSAttributedString
    /// Job 502: per REAL local page (`PagedDocumentView.buildPages`'s own container index —
    /// filled in as that loop goes, not resolved after like `runningLines`, since the value
    /// itself is what decides that page's own container height), the footnote entries
    /// `drawFootnoteBlock` paints at the page's foot, dash-separated, in `modernFootnoteEvents`
    /// order. Empty for every LOCAL page with no footnote attached to it, and for every
    /// render path that never populates `modernFootnoteEvents` in the first place.
    var modernFootnoteBlocks: [[NSAttributedString]] = []
    /// Job 490 (item 1, LJ6DTP title-top): `Document.pclPrograms` verbatim, threaded through
    /// so `PageTextView.drawPCLGraphics` (`PrintedPCLGraphics.swift`) can execute a `.pctl`
    /// attachment's own embedded PCL program at draw time — see that file's top doc comment.
    /// Empty in Modern style, which has no `PageLine`/paper-facsimile concept for a PCL
    /// rectangle to draw against at all.
    let pclPrograms: [[UInt8]]
}

/// Job 412: one `RenderedDocument.pinnedBaselines` entry — see that field's own doc comment.
/// `page` travels alongside `y` (not just the page-relative Y alone) because
/// `PagedDocumentView`'s delegate needs it too: `buildExplicitPages`'s own whole-document
/// probe container lays every page's content into ONE shared coordinate space, where a
/// page-relative `y` that resets at every page's own top would make page 2's content jump
/// BACKWARD and overlap page 1's — `page` is what lets that one call site give the probe a
/// monotonically increasing target instead, without changing what the REAL per-page
/// containers use (see that delegate's own doc comment for the two call shapes).
struct PinnedBaseline: Sendable {
    let page: Int
    let y: Double
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
    let k: Double
}

/// Job 413: `line` with every span's `.sup`/`.sub` style bit cleared — used ONLY to probe
/// `PinnedBaseline.k` (`isolatedFragmentK` below), never for real drawn content. A raised or
/// lowered run's own glyph is a DECORATION within the line (`attributedRun`'s own
/// `scriptMetrics` doc comment: sized and offset to fit inside the base font's envelope), not
/// a property of where the LINE ITSELF sits — probing with it still present let that
/// decoration perturb the whole line's pinned position (see `PinnedBaseline.k`'s own doc
/// comment for the DARKNESS.WS defect this fixes).
private func desuperscripted(_ line: PageLine) -> PageLine {
    var copy = line
    for i in copy.indices { copy[i].styles.subtract([.sup, .sub]) }
    return copy
}

/// One running head/foot line, positioned in the app's own top-down convention (baseline
/// distance from the paper's top edge, matching `RenderedDocument.textFrame`'s origin).
/// Pre-styled (Courier at the document's printed size, black ink — the same face `emitPDF`
/// names for a running line, `PDFWriter.swift:209`'s `pdfFont(bold: false, italic: false)`)
/// so `PagedDocumentView` only ever has to draw it, never reconstruct its font.
struct RunningLine {
    enum Kind { case header, footer }
    let text: NSAttributedString
    let baselineFromTop: Double
    /// How far `PagedDocumentView.drawRunningLines` must pull its `NSAttributedString
    /// .draw(at:)` origin ABOVE `baselineFromTop` for that call's true baseline to land ON
    /// `baselineFromTop` — AppKit-measured (`DocumentRenderer.firstBaselineOffset`, the SAME
    /// "ask the layout manager, don't derive it by hand" discipline the body text container's
    /// own `normalBaselineOffset` uses), not `font.ascender` (job 228: `draw(at:)` still goes
    /// through a real AppKit line-height decision — "point-drawn, so there's no layout
    /// decision to ask about" was this file's own wrong assumption, see this job's citations).
    let drawOriginOffset: Double
    let kind: Kind
    /// Job 489 (b29 adoption, register C6): extra distance PAST `PagedDocumentView
    /// .drawRunningLines`'s ordinary `x` a line with its own font block starts drawing at —
    /// zero for every line that goes through the plain Courier path below. Mirrors the
    /// engine's own `hfLineOps` (`PDFWriter.swift`): a PROPORTIONAL font's leading
    /// whitespace advances the pen without emitting a `Tj`, so `text` above never carries
    /// those characters at all — this is the width that skipped run would have occupied,
    /// measured the same way `appendSpan`'s body-text indent carve-out already measures it
    /// (the document's base Courier at its own size — "already advances at exactly that
    /// grid" per that call site's own citation).
    var leadingOffset: Double = 0
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
struct HFEvent {
    let kind: RunningLine.Kind
    let line: Int
    let text: String
    let charOffset: Int
}

/// One paragraph's worth of footnote attachments in Modern's own flow — see
/// `RenderedDocument.modernFootnoteEvents`'s own doc comment for the full mechanism this
/// exists for (job 502). `entries` are already fully styled (`noteFont`/`noteParagraph`, the
/// SAME attributes the end-of-document note appendix already draws with — `appendNoteLine`
/// in `renderModern`) and each one already carries its own trailing line terminator, so
/// `PagedDocumentView` can measure and draw a page's footnote block by straight
/// concatenation, with no styling knowledge of its own.
struct ModernFootnoteEvent {
    let charOffset: Int
    let entries: [NSAttributedString]
}

/// Job 240 (b13, Part 1) — MAC VIEWING RULING (decision register 2026-08-11, restated and
/// binding; skill registry #25): "We are on a MAC now... we don't have to fool around with
/// making sure we only use native-to-PDF fonts... We are using that same availability to
/// make the Mac viewer awesome." Printed-mode font resolution no longer clamps a WS5+ font
/// run to the base-14 PDF set (the `PrintedFontFamily` enum this replaced); it maps the
/// typestyle name through the SAME `.mac` render-target table the CLI's `--fonts mac`
/// target uses, so the viewer shows the real typeface family (Univers/Aachen/etc.) instead
/// of whichever of Times/Helvetica/Courier its generic-style bits happened to clamp to.
/// Engine PDF export is untouched — base-14 stays exactly right for that surface (Jon
/// ruled its PDF output looks good); this is a VIEWING-surface-only change.

/// Port of `targetFonts[.mac]` (`CtrlKD/FontMap.swift:192-217`, `internal` — same
/// "parallel port, not a call" discipline as this file's other engine ports, e.g.
/// `printedLJ6DTPColourGray`/`printedLJ6DTPCharSubst` above). Keys are the RENDERED family
/// (`FontChange.family`, i.e. the typestyle name up to its first parenthetical), lowercased.
/// `falt` is that row's own second modern name — "fallback chain per the mapping's
/// alternates" (this job's brief) — tried when the primary can't be resolved to an
/// installed font; unlisted families fall through to `printedMacGenericPrimary` below,
/// the font block's own generic-style bits as terminus, exactly like `rtfFonts`'s own
/// fallback order (`FontMap.swift:279-281`).
private let printedMacFontRows: [String: (primary: String, falt: String?)] = {
    func expand(_ rows: [(keys: String, primary: String, falt: String?)])
        -> [String: (primary: String, falt: String?)] {
        var flat: [String: (primary: String, falt: String?)] = [:]
        for row in rows {
            for key in row.keys.split(separator: "|") { flat[String(key)] = (row.primary, row.falt) }
        }
        return flat
    }
    return expand([
        ("avant garde", "Futura", "Century Gothic"),
        ("bookman", "Cochin", "Bookman Old Style"),
        ("cntry schlbk|newcntschlbk|new century schoolbook|century", "Georgia", "Century Schoolbook"),
        ("american classic", "Baskerville", "Century Schoolbook"),
        ("helv|helvetica", "Helvetica", "Arial"),
        ("helv narrow|helv cond.|helvetica narrow", "Arial Narrow", "Helvetica Neue Condensed"),
        ("palatino", "Palatino", "Palatino Linotype"),
        ("tms rmn|times|cg times", "Times New Roman", nil),
        ("zapfchancery|zapf chancery|coronet", "Apple Chancery", "Monotype Corsiva"),
        ("zapfdingbats|zapf dingbats", "Zapf Dingbats", nil),
        ("symbol", "Symbol", nil),
        ("courier|pica|elite|lineprinter", "Courier New", nil),
        ("letter gothic|gothic", "Menlo", "Courier New"),
        ("prestige", "Courier New", nil),
        ("univers", "Helvetica Neue", "Arial"),
        ("cg triumvirate|ps sansser qual", "Helvetica", "Arial"),
        ("antique olive", "Optima", "Verdana"),
        ("optima", "Optima", "Candara"),
        ("garamond", "Hoefler Text", "Garamond"),
        ("clarendon", "Rockwell", "Clarendon"),
        ("aachen|rockwell", "Rockwell", "Courier New"),
        ("bodoni", "Bodoni 72", "Bodoni MT"),
        ("broadway", "Phosphate Solid", "Futura"),
        ("univ. roman", "Didot", "Georgia"),
    ])
}()

/// Port of `genericPrimary[.mac]` (`CtrlKD/FontMap.swift:116-117`). The terminus for any
/// typestyle name `printedMacFontRows` doesn't carry — an unmapped family still gets a
/// USEFUL Mac-native face from its font block's own generic-style bits, never nothing.
private let printedMacGenericPrimary: [GenericStyle: String] = [
    .sans: "Helvetica", .serif: "Times New Roman", .script: "Apple Chancery", .display: "Futura",
]

/// `entry.family`, lowercased, redirected to the short mono key ("courier"/"pica"/"elite"/
/// "lineprinter") when it's one of those NAMES WITH A SUFFIX the spec's own table carries
/// (e.g. `"Courier Italic (TI 855)"` -> family `"Courier Italic"`) — same `hasPrefix` guard
/// and same reasoning `printedMonoFamilies`'s own doc comment already gives: these are
/// monospace-family variants the `.mac` table's exact-string keys don't spell out
/// individually, and belong on that family's own mapped face, not the generic-style
/// fallback its OTHER bits (serif/sans) might otherwise select.
private func printedMacFamilyKey(_ family: String) -> String {
    let lower = family.lowercased()
    if let mono = printedMonoFamilies.first(where: { lower.hasPrefix($0) }) { return mono }
    return lower
}

/// Job 306 (b18): the `printedMacFontRows` keys Jon's ruling names — Native's courier-class
/// mapping (`"courier|pica|elite|lineprinter"` and `"prestige"`, the two rows this job's
/// brief quotes verbatim; `"letter gothic|gothic"`'s primary is Menlo, not this class, so it
/// is untouched even though its OWN `falt` happens to be "Courier New" too).
///
/// Job 312/b19 (2026-08-14, Jon's ruling, SUPERSEDES job 306's Modern scoping below): Modern's
/// VIEW now resolves these rows to Courier Prime too, same as Native —
/// `renderModern`/`renderModernAnnotated`'s `attributedLine` calls now pass
/// `useCourierPrime: true` (`DocumentRenderer.swift`). What still keeps the views apart is the
/// EMITTED-output boundary, not a Modern/Native split: every emitter (RTF/HTML/MD/DOCX/CLI/QL
/// text) calls `printedMacFontName`/`attributedLine`'s callers with `useCourierPrime`
/// defaulted `false` or explicitly `false`, so `OutputParityTests` still pins every output
/// surface to "Courier New" — only the two on-screen views (Native's Printed render and
/// Modern's) pass `true`. See `ModernViewerStyleTests
/// .bodyProseKeepsTheDocumentsOwnCourierNotTheUsersGeorgiaSetting` for the pinned Modern-side
/// expectation this must never regress.
private let courierPrimeRowKeys: Set<String> = ["courier", "pica", "elite", "lineprinter", "prestige"]

/// Job 394 (391 root cause 3): the DECISIVE monospace verdict for `printedMacFontName`
/// below, consulted BEFORE any name/generic-style lookup there — a direct call to the
/// engine's own shared `resolveFont` (`CtrlKD/FontMap.swift`'s b24 round 21 item 5
/// architectural deliverable: "ONE public function so the app's own view layer... can
/// ask the SAME question every export emitter already does, without re-deriving the
/// decision"), not a reimplementation of the bit test. `rtfFonts`'s own doc comment
/// states the rule this mirrors: "`proportional == false`... is DECISIVE and short-
/// circuits all of the above... routed through the SAME per-target 'courier' table entry
/// every genuine mono family already resolves through, never a family-name or falt
/// garnish." Before this job, `printedMacFontName` had NO such short-circuit: a WSFORMAT
/// typestyle with `proportional == false` but no entry in `printedMacFontRows` (ctrl-kd's
/// generic Non-PostScript categories — "NPS SansSer Qual"/"NPS Serif Qual", typestyle
/// numbers 103/104, SCRIPT.WS's own screenplay body font) fell all the way through to
/// `printedMacGenericPrimary`'s sans/serif bucket and rendered a real PROPORTIONAL Mac
/// face for a record whose own bit says it is NOT one — the live Native/Modern view (and
/// therefore print and the AppKit-rendered PDF export, which both call this same
/// function) diverging from the RTF/PDF emitters, which already apply this identical
/// short-circuit via `rtfFonts`/`pdfFamily`.
private func printedMacIsMonospace(_ entry: FontChange) -> Bool {
    resolveFont(entry).isMonospace
}

/// The Mac font name (plus fallback alternate) for one WS5+ font-block span — replaces the
/// base-14 `printedFontFamily`/`printedFontPostScriptName` pair this job removed. Symbol/
/// dingbat BYTE-ENCODING detection (`entry.symbolMap`, and the typestyle-name prefix checks
/// job 186/210 already established) still takes priority over the name-driven table lookup,
/// unchanged from before this job: those bytes need the Symbol/Zapf Dingbats glyphs to mean
/// anything at all, independent of what face the typestyle name would otherwise select.
/// `printedMacIsMonospace` (job 394, its own doc comment above) takes priority right after
/// those two — same "decisive, ahead of the name table" position `rtfFonts` gives the
/// identical bit.
///
/// `useCourierPrime` (job 306, default `false` so every EMITTER caller/test is unaffected):
/// the two on-screen views' own callers pass `true` (Native since job 306; Modern since
/// job 312/b19, 2026-08-14), substituting the bundled Courier Prime
/// (`CourierPrimeFontRegistration`) as primary with "Courier New" as `falt` — reached only if
/// the bundled face somehow failed to register/load — for exactly the two rows
/// `courierPrimeRowKeys` names, ahead of the shared `printedMacFontRows` lookup.
private func printedMacFontName(_ entry: FontChange, useCourierPrime: Bool = false) -> (primary: String, falt: String?) {
    let name = (entry.typestyleName ?? "").lowercased()
    if name.hasPrefix("symbol") { return ("Symbol", nil) }
    if name.contains("dingbat") { return ("Zapf Dingbats", nil) }
    switch entry.symbolMap {
    case .math: return ("Symbol", nil)
    case .symbols: return ("Zapf Dingbats", nil)
    case .cp437, .cp850: break
    }
    if printedMacIsMonospace(entry) {
        if useCourierPrime { return ("Courier Prime", "Courier New") }
        return printedMacFontRows["courier"] ?? ("Courier New", nil)
    }
    let key = printedMacFamilyKey(entry.family)
    if useCourierPrime, courierPrimeRowKeys.contains(key) {
        return ("Courier Prime", "Courier New")
    }
    if let row = printedMacFontRows[key] { return row }
    return (printedMacGenericPrimary[entry.genericStyle] ?? "Helvetica", nil)
}

/// Bold/italic traits onto a resolved Mac face via `NSFontManager`, same mechanism
/// `DocumentRenderer.styled(_:with:)` already uses for Modern style — a family name has no
/// fixed 4-member PostScript variant table the way base-14 did, so traits are synthesised
/// instead of looked up. Symbol and Zapf Dingbats are excluded: both are single-form faces
/// (no bold/italic member exists), and asking `NSFontManager` to synthesise a trait it can't
/// find on the family risks it substituting a DIFFERENT family entirely rather than doing
/// nothing — the same risk `styled(_:with:)`'s own early-return-on-no-traits avoids for the
/// common case, made explicit here for these two.
private func printedApplyTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
    guard font.familyName != "Symbol" && font.familyName != "Zapf Dingbats" else { return font }
    var traits: NSFontTraitMask = []
    if bold { traits.insert(.boldFontMask) }
    if italic { traits.insert(.italicFontMask) }
    guard !traits.isEmpty else { return font }
    return NSFontManager.shared.convert(font, toHaveTrait: traits)
}

/// `NSFont` for one WS5+ font-block span at `size`, trying the mapped primary name, then
/// its `falt`, then giving up (the caller falls back to the document's own Courier — see
/// `resolvedFont`'s call site). Every name in `printedMacFontRows`/`printedMacGenericPrimary`
/// is a real installed macOS font (Jon's device verification, `FontMap.swift:140-142`'s own
/// citation — "every mac cell device-verified... Font Book, locked-flag test"), so the
/// `falt`/`nil` path is a defensive fallback, not an expected one.
private func printedResolvedMacFont(
    _ entry: FontChange, size: CGFloat, bold: Bool, italic: Bool, useCourierPrime: Bool = false
) -> NSFont? {
    let (primary, falt) = printedMacFontName(entry, useCourierPrime: useCourierPrime)
    for name in [primary, falt].compactMap({ $0 }) {
        if let base = NSFont(name: name, size: size) {
            return printedApplyTraits(base, bold: bold, italic: italic)
        }
    }
    return nil
}

/// Job 445 (b27 item 7 part 1 — job 442's diagnosis, `outbox/job442/report.md`): whether
/// `font` has a REAL glyph, via `CTFontGetGlyphsForCharacters` (the Core Text coverage API
/// — no hardcoded box-drawing/cp437 codepoint list here), for every character in `text`.
/// `NSFont(name:size:)` succeeding only proves the FAMILY exists; it says nothing about
/// which Unicode blocks that face's own cmap covers — job 442 measured that neither
/// `Courier` nor `Courier Prime` covers cp437 box-drawing, yet both construct cleanly,
/// which is exactly the gap `printedResolvedMacFont` above never checks. `NSFont`/`CTFont`
/// are toll-free bridged on macOS, so `font as CTFont` needs no re-lookup.
private func fontCoversAllCharacters(_ font: NSFont, in text: String) -> Bool {
    let units = Array(text.utf16)
    guard !units.isEmpty else { return true }
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
}

/// Coverage-aware sibling of `printedResolvedMacFont` above (job 445, part 1 of the b27
/// box-corner fix). Tries the SAME `[primary, falt]` candidate order that function already
/// tries, but its stop condition is stricter: a candidate is accepted only once it both
/// CONSTRUCTS and COVERS (`fontCoversAllCharacters`) every character actually being set —
/// `printedResolvedMacFont` stops at construction alone, which is how it silently keeps
/// `Courier Prime` for a box-drawing run neither `Courier Prime` nor its own bundled name
/// contains a glyph for, letting AppKit's own missing-glyph substitution pick an unmanaged
/// fallback (Menlo on this machine) instead. When NO candidate covers `text`, falls back to
/// the first candidate that at least constructed — same "never return nil when the old code
/// would have shown something" guarantee `printedResolvedMacFont` itself keeps.
///
/// NOT YET WIRED into any render path — `resolvedFont`/`graphicCells` still call
/// `printedResolvedMacFont`. Wiring this in (and the per-glyph run-boundary tracking that
/// needs, per job 442's own recommended-fix section) is part 2, a separate job.
func printedCoverageAwareResolvedMacFont(
    _ entry: FontChange, size: CGFloat, bold: Bool, italic: Bool, useCourierPrime: Bool = false,
    coveringCharactersIn text: String
) -> NSFont? {
    let (primary, falt) = printedMacFontName(entry, useCourierPrime: useCourierPrime)
    var firstConstructed: NSFont?
    for name in [primary, falt].compactMap({ $0 }) {
        guard let base = NSFont(name: name, size: size) else { continue }
        if firstConstructed == nil { firstConstructed = base }
        if fontCoversAllCharacters(base, in: text) {
            return printedApplyTraits(base, bold: bold, italic: italic)
        }
    }
    return firstConstructed.map { printedApplyTraits($0, bold: bold, italic: italic) }
}

/// Job 210 (b11 leg 3): port of `colourGrayLJ6DTP` (`CtrlKD/PDFDriverLJ6DTP.swift:15-19`,
/// `internal` — same "parallel port, not a call" discipline as `printedFontFamily` above).
/// LJ6DTP's colour palette as grayscale (0 black, 1 white). Applied ONLY when the document
/// declares driver LJ6DTP (`Document.printerDriver`, `public`); every other document's
/// `span.colour` is ignored, matching the engine's own `doc.printerDriver == "LJ6DTP" ?
/// colourGrayLJ6DTP : [:]` gate (`PDFWriter.swift:708`). Index 15 (`1.0`, white) is the
/// KNOCKOUT — white text set to overprint a black-filled vector bar (`PDFWriter.swift:484`'s
/// own comment: "white (15) text overprinted onto a black bar punches out of it exactly as
/// the LaserJet printed it").
private let printedLJ6DTPColourGray: [Int: Double] = [
    1: 0.15, 2: 0.25, 3: 0.50, 4: 0.75, 5: 0.85, 6: 0.95, 7: 0.98,
    15: 1.0,
]

/// job-489 (C1 — "Pattern fills are FLATTENED TO GREY"): indices 9-14 (HP1-HP6) are NOT flat
/// grays at all — they're six visually distinct tiling patterns (horizontal, vertical, two
/// diagonals, crosshatch, dense X), `LJ6DTPPattern`'s own doc comment
/// (`PrintedVectorGraphics.swift`), port of the engine's `lj6dtpHPPatterns`
/// (`PDFDriverLJ6DTP.swift:43-50`). Collapsing them into `printedLJ6DTPColourGray`'s single
/// mid-gray (as this app did before this job) made page 5's whole point — six textures
/// distinguishable from each other — read as one swatch repeated six times. Kept as its own
/// set (rather than folded into `printedLJ6DTPColourGray`) because a pattern needs a
/// DIFFERENT resolution path than a flat gray: `driverColour` returns a real tiled
/// `NSColor(patternImage:)` for these, never a `colourMap` lookup.
let lj6dtpHPPatternIndices: Set<Int> = [9, 10, 11, 12, 13, 14]

/// Job 226: port of `ljSubst`/`ljSubstUnivers` (`CtrlKD/PDFDriverLJ6DTP.swift:26-41`,
/// `private` — same parallel-port discipline as `printedLJ6DTPColourGray` above, one level
/// deeper: even the ENGINE'S OWN `DocumentRenderer`-facing callers can't see these, they're
/// `private` to that one file). LJ6DTP's driver patches PC-8 slots so typing `_` PRINTS an
/// em dash, `` ` ``/`'` print curly singles, `«»` print curly doubles, and the WordStar-era
/// smiley/sun glyphs the author typed for ©/… print as such — "an em dash is an em dash in
/// any century" (the engine's own ruling 2026-08-06 M7 comment). Gated identically to the
/// engine (`entry.proportional`, `PDFDriverLJ6DTP.swift:49`/`61`) by `printedLJ6DTPSubstitute`
/// below — fixed-pitch runs (Courier, Letter Gothic, LinePrinter) are never patched, matching
/// the driver's own chart.
// Job 401 (Class 3 diagnosis): widened from `private` to `internal` (no behaviour change)
// so `PrintedStructuralParityTests.swift`'s `EngineTruth` — a different file in the same
// module — can reuse this SAME verified port instead of a second copy. Needed because
// `docToPagelines`'s own `PageLine.text` is PRE-substitution: the engine applies
// `ljSubstitute` later, inside `lineOpsPrinted` (`PDFWriter.swift:509`), directly on the
// segments it is about to draw — a step that never writes back into `Page.lines`. So the
// PDF a viewer actually shows (and what this app already matches) carries the substituted
// glyph, but the "engine truth" this test harness read via `docToPagelines` was still the
// raw pre-substitution character — a harness blind spot, not an app defect. See that
// file's own `EngineTruth.structuralPages` for the call site and citation.
let printedLJ6DTPCharSubst: [Character: Character] = [
    "\u{263B}": "\u{00A9}",   // ☻ -> ©
    "\u{263C}": "\u{2026}",   // ☼ -> …
    "'": "\u{2019}",          // ' -> '
    "_": "\u{2014}",          // _ -> — (em dash)
    "`": "\u{2018}",          // ` -> '
    "\u{00AB}": "\u{201C}",   // « -> "
    "\u{00BB}": "\u{201D}",   // » -> "
    "\u{2261}": "\u{2013}",   // ≡ -> – (en dash)
]
// Job 495 (Class 7 residual, LJ6DTP.WS page 3): was `\u{250C}`/`\u{2510}`/`\u{2514}`/
// `\u{2518}` (plain sharp-corner ┌┐└┘) — job 226 ported the WRONG engine table. The
// engine has TWO separate Univers-corner tables (`PDFDriverLJ6DTP.swift:78-96`):
// `ljSubstUnivers` (real PDF print-time substitution, `♥♦♣♠ -> ╭╮╰╯`, drawn as a
// stroked quarter-circle join via `arcCorners`/`graphicOps`) and
// `ljSubstUniversSemantic` (a SEPARATE table, that file's own doc comment: "for a
// layout/RTF/HTML consumer... it gets a CHARACTER... the character WordStar's own
// chart names for these slots is the plain box corner" — i.e. explicitly NOT what a
// vector-capable Printed renderer should draw). Job 226 ported the semantic table by
// mistake. Landing on plain ┌┐└┘ additionally happens to collide with `boxArms`
// (`PrintedVectorGraphics.swift`) — a SECOND, real box-drawing character set — so
// LJ6DTP.WS's own "You type / Shows on screen as / Prints as" reference table
// (page 3, and the isolated "rounded box corner (Univers only)" demo lines just above
// it) wrongly decomposed into sharp-corner box ARMS instead of showing a rounded-corner
// glyph, an extra 16 vector ops job 494's own Class 7 table carried unexplained
// (confirmed via `PAGE3-ORD`/`PAGE3-ALLLINE` probes this job: every one of the 16 extra
// fills traces to exactly these 4 characters, 2 `boxArms` fills each, at 8 real-fragment
// occurrences). `\u{256D}`-`\u{256F}` (BOX DRAWINGS LIGHT ARC) are not in `boxArms`/
// `symbolShapes`/any of the app's graphicChars sets, so they now draw as ordinary TEXT —
// a real Unicode box-drawing glyph most system fonts carry directly (not the missing-
// glyph '?' case `graphicChars` exists to patch), a closer visual match to the engine's
// own rounded join than a sharp corner, with no vector geometry needed to port.
let printedLJ6DTPCharSubstUnivers: [Character: Character] = [
    "\u{2665}": "\u{256D}",   // ♥ -> ╭
    "\u{2666}": "\u{256E}",   // ♦ -> ╮
    "\u{2663}": "\u{2570}",   // ♣ -> ╰
    "\u{2660}": "\u{256F}",   // ♠ -> ╯
]

/// LJ6DTP's character substitutions for one proportional run — port of `ljSubstituteText`
/// (`PDFDriverLJ6DTP.swift:48-55`). `entry` `nil` (no font block) or fixed-pitch: no-op,
/// matching the engine's own guard.
func printedLJ6DTPSubstitute(_ text: String, entry: FontChange?) -> String {
    guard let entry, entry.proportional else { return text }
    var out = String(text.map { printedLJ6DTPCharSubst[$0] ?? $0 })
    if (entry.typestyleName ?? "").hasPrefix("Univers") {
        out = String(out.map { printedLJ6DTPCharSubstUnivers[$0] ?? $0 })
    }
    return out
}

/// Job 240 (b13, Part 1): `printedEscDegrade`/`printedEscFallback` (job 226's port of
/// `escFallback`, `CtrlKD/PDFWriter.swift:40-47`) REMOVED from this native path — MAC
/// VIEWING RULING (decision register 2026-08-11; skill registry #25). That degradation
/// existed only because `emitPDF` hand-encodes Printed-mode text as a `/WinAnsiEncoding`
/// (cp1252) PDF string literal, which has no slot for •, ‼, or the box-drawing rule
/// characters — a PDF-EXPORT constraint. AppKit's text stack draws real Unicode against a
/// real installed font; every Mac face this renderer now resolves through
/// `printedMacFontName` carries all six of these glyphs natively, so there is nothing here
/// for a degradation table to guard against. The engine's own `emitPDF`/QL-via-PDF path is
/// untouched — Jon ruled that PDF output looks good as is; this removal is scoped to the
/// native viewer's own text attributes only.

/// Job 226: disables `NSAttributedString`'s default kerning on every Printed-style string
/// this renderer builds. `PDFWriter.lineOpsPrinted`/`runningOps`'s whole positioning model —
/// `spanPitch`, `spanTarget`, `tzScale`, the running-head/footer `Td` math — assumes a FIXED
/// per-character advance with no font-pair kerning at all: PDF's plain `Tj` operator (this
/// emitter never writes a `TJ` array with per-glyph adjustments) places glyphs back to back
/// at the font's raw advance widths, full stop. `.kern: 0` is Cocoa's documented way to
/// disable kerning per run, so this is applied on general principle to keep AppKit's layout
/// matching that same "no font-pair kerning" model.
///
/// NOT CONFIRMED as the explanation for the header drift this job chased (a `"Courier"`
/// `NSAttributedString.size()` probe measured a 53-char header string at 367.26pt against an
/// expected 381.6pt (53 * 7.2) — a ~14pt gap matching the observed reference-vs-actual
/// drift — but the SAME probe with `.kern: 0` added measured IDENTICAL 367.26pt: legacy
/// `NSStringDrawing.size()` either doesn't apply `.kern` the way real `NSLayoutManager`
/// layout does, or isn't measuring what this job assumed (leading-space handling is one
/// candidate, untested). The real oracle (TextKit-rendered, not `.size()`) DID show some
/// LJ6DTP row counts move after this change landed, but not cleanly enough to credit kerning
/// specifically — several other fixes landed in the same pass. Left in as a real, defensible
/// correctness fix on its own terms; the header's remaining pixel drift is NOT closed and
/// its root cause is still open — see this job's report/LESSONS, not a re-derivation here.
private let printedNoKerning: Float = 0

/// Job 226: a running head/foot carries WordStar's OWN embedded print-control bytes
/// verbatim — `parseHeadFoot`/`decodeHeadFootText` (`ParseWS.swift:1366`/`1401`) keep the
/// text "as content, not command syntax" (that file's own comment) and never intercept
/// them the way `decodeSpans` does for body text (LJ6DTP's own `.H1` wraps its title in a
/// bold toggle, `\u{02}...\u{02}` — confirmed on this fixture by direct inspection). The
/// engine's `esc(_:)`/`cp1252Encode` pass a C0 control through as its own raw byte value
/// (cp1252 is ASCII-identity there), landing in the PDF's `Tj` string at a codepoint
/// `/WinAnsiEncoding` has no GLYPH for — a PDF viewer (PDFKit, this oracle's reference)
/// draws nothing for an undefined code, but for a monospaced base-14 font (Courier's own
/// `/MissingWidth`, uniform with every other glyph's) STILL ADVANCES the pen by one
/// character cell — confirmed empirically (a direct pixel sample of this oracle's own
/// reference bitmap, not assumed): the reference's visible text starts exactly TWO
/// character-cells later than a naive removal produces. AppKit has no such notion of a
/// per-font missing-glyph width; asked to lay out a real `NSFont` glyph for U+0002 it
/// would reserve ITS OWN (real) advance, and outright deleting the character (this fix's
/// first attempt) undershoots the reference by those same two cells the other way. A
/// plain space reproduces the reference's actual behaviour exactly: same fixed-pitch
/// advance, zero ink — without inventing a bold-toggle PORT (this renderer has no
/// running-head style support at all, and adding one is out of this fix's scope; see
/// this job's LESSONS).
private func printedStripControlChars(_ text: String) -> String {
    String(text.unicodeScalars.map { $0.value >= 0x20 && $0.value != 0x7F ? Character($0) : " " })
}

/// Job 489 (b29 adoption): port of the engine's own `hfToggles`/`hfRuns` (`EmitRTF.swift`,
/// not `public`, so re-derived here rather than imported) — a running head/foot's raw text
/// can carry WordStar's own print-toggle bytes verbatim (LJ6DTP's `.h1` is
/// `^B^BLJ6DTP ... ^B`), and a document whose `.h#`/`.f#` opened with its own font block
/// (`Document.headerFonts`/`footerFonts`, register C6) needs those bytes INTERPRETED —
/// consumed as style flips, never drawn as literal control characters — the same way the
/// engine's `hfLineOps` reads them, rather than degraded to blank spaces the way
/// `printedStripControlChars` treats every OTHER control byte. Only reached when a font
/// block is present; the plain (no font block) path below is untouched and still uses
/// `printedStripControlChars` alone.
private let printedHFToggles: [UInt32: Style] = [
    0x02: .bold, 0x19: .italic, 0x13: .underline,
    0x14: .sup, 0x16: .sub, 0x18: .strike,
]

/// A running-head/foot string -> [(text, styles)], WordStar's own toggle bytes interpreted
/// and every other control byte dropped (not space-degraded). Returns `[]` for a head that
/// is nothing but control bytes — the caller treats that as "nothing to draw," matching
/// `hfRuns`'s own doc comment. Port of `hfRuns` (`EmitRTF.swift`, CtrlKD).
private func printedHeadFootRuns(_ text: String) -> [(text: String, styles: Style)] {
    var runs: [(text: String, styles: Style)] = []
    var buf = ""
    var active: Style = []
    func flush() {
        if !buf.isEmpty { runs.append((buf, active)); buf = "" }
    }
    for scalar in text.unicodeScalars {
        if scalar.value == 0x2219 { buf.unicodeScalars.append(Unicode.Scalar(0x2022)!); continue }
        if let toggle = printedHFToggles[scalar.value] {
            flush()
            active.formSymmetricDifference(toggle)
            continue
        }
        if scalar.value < 0x20 { continue }
        buf.unicodeScalars.append(scalar)
    }
    flush()
    guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
    return runs
}

/// Fixed-pitch era faces, matched on the typestyle NAME — same list and same "run before the
/// generic-style bits" ordering as the engine's `monoFamilies` (`PDFFonts.swift`), and for the
/// same reason: the spec's own `Courier` font block declares generic style `serif`.
private let printedMonoFamilies = ["courier", "pica", "elite", "lineprinter"]


/// Job 256 (Show Invisibles, part 2/4): the ink every invisible mark draws in — same gray
/// for all five classes (dot commands, comments, style toggles, soft/hard returns,
/// page-break origin). `NSColor(white: 0.45, alpha: 0.55)` is the spec's own starting
/// point; part 4 tunes the exact value with Jon's own eyes.
///
/// Internal rather than `private` so `SoftReturnTests` can identify a mark run directly by
/// its own colour, the same "loosen to internal for test access" convention `attributedLine`
/// itself already uses.
///
/// Job 258 (Show Invisibles part 4/4): `var`, not `let` — the evidence-sheet harness renders
/// the SAME page at several alphas for Jon's own eyes to pick from (this job's brief: "the
/// judgment... belongs to JON, this job's deliverable is the EVIDENCE SHEET"), restoring the
/// shipped default immediately after each capture. `nonisolated(unsafe)` because a top-level
/// `var` is otherwise flagged as unguarded shared mutable state under Swift 6 strict
/// concurrency; every read/write in practice happens on the main actor (rendering only ever
/// runs there) so there is no real data race, matching the `nonisolated(unsafe) static var`
/// convention this codebase already uses for other test-mutated globals (e.g.
/// `AppleEventDiagnosticTap.calls`).
nonisolated(unsafe) var invisibleMarkColour = NSColor(white: 0.45, alpha: 0.55)

/// Job 258 (Show Invisibles part 4/4, edge sweep): tags every character `markRun` (below)
/// draws — real characters in the SAME `NSTextStorage` as the document's own text (see this
/// file's top doc comment on why there is only one) — so `PageTextView.copy(_:)`
/// (`PagedDocumentView.swift`) can exclude invisible-ink marks from what lands on the
/// pasteboard: the spec's own default is that Cmd-C copies the document, not the screen
/// furniture Show Invisibles draws alongside it. A dedicated key rather than filtering by
/// `.foregroundColor == invisibleMarkColour` avoids an `NSColor` equality check that can
/// silently fail across colour spaces.
extension NSAttributedString.Key {
    static let invisibleMarkRun = NSAttributedString.Key("SoftReturn.invisibleMarkRun")
}

@MainActor
enum DocumentRenderer {
    /// Job 375 item C2 (b24 completion): the export-only overrides `appKitRenderedPDF` needs
    /// to honor the SAME `EmitOptions` the library's own emitters read — `render(_:style:)`'s
    /// own default (`.allOn`) reproduces every existing caller's current behavior exactly
    /// (the live document window has no per-window "hide headers" concept; only an EXPORT
    /// can ask for that), so every caller that predates this struct is unaffected. Not
    /// `EmitOptions` itself: this only ever gates the three flags with a real mechanism in
    /// the AppKit render path (headers/pictures/inline colour) — `toc` is handled entirely
    /// in `ExportEngine.appKitRenderedPDF` by appending extra pages, never inside the core
    /// render functions below.
    struct ExportFlags {
        var headers = true
        var pictures = true
        var inlineStyling = true
        static let allOn = ExportFlags()
    }

    /// Render `state`'s document in its current style, or `style` when the caller needs a
    /// different one without perturbing the window's own on-screen state (job 244 Leg 3: the
    /// Export panel's Style control renders whatever it says, defaulting to — but not forced
    /// to track — the window's live style).
    ///
    /// This function only ever draws through AppKit, so the default projects `state.style`
    /// (job 265's three-case `ViewStyle`) onto its two-case `RenderStyle` axis via
    /// `ViewStyle.renderStyle` — Native and Printed both mean the SAME facsimile layout here
    /// (Printed's own PDFKit rendering is a totally different code path, `pdfView` in
    /// `DocumentWindowController`, which never calls this function at all). Every real
    /// caller that cares about the distinction (`DocumentWindowController`,
    /// `QuickLookNativeRenderer`) passes `style` explicitly rather than relying on this.
    ///
    /// NEVER consults `state.showInvisibles` — this is the plain layout every non-screen
    /// caller (`ExportEngine`, `makePrintOperation`, `QuickLookNativeRenderer`,
    /// `PagePreviewRenderer`) calls, several of them against the SAME live `DocumentState`
    /// the document window shares, so Show Invisibles staying screen-only depends on this
    /// function never branching on that flag. See `renderWithInvisibles` below (the one
    /// caller that DOES want the annotated layout) and
    /// `showInvisiblesNeverReachesPrintedExportBytes`/`showInvisiblesAnnotatedOnlyOnScreen`
    /// (`WiringTests.swift`), which exist to catch a future regression of exactly this.
    static func render(_ state: DocumentState, style: RenderStyle? = nil,
                       exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        switch style ?? state.style.value.renderStyle {
        case .printed: return renderPrinted(state, exportFlags: exportFlags)
        case .modern:  return renderModern(state, exportFlags: exportFlags)
        }
    }

    /// Job 256 (Show Invisibles, part 2/4): Native style with WordStar's five invisible-ink
    /// classes (dot commands, comments, style toggles, soft/hard returns, page-break origin)
    /// rendered inline as real, faint text, via `CtrlKD.annotatedLayout`. Screen-only — the
    /// ONLY call site is `DocumentWindowController.reloadContent()`, gated on
    /// `documentState.showInvisibles`; every export/print/QuickLook path keeps calling
    /// `render(_:style:)` above, untouched by this function's existence.
    ///
    /// Job 294 (Jon's ruling): Modern now shows invisibles too, via `renderModernAnnotated`
    /// below — a DIFFERENT mark selection than Native's, not the same annotated layout
    /// reused verbatim (see that function's own doc comment for the differences: no
    /// soft-return marks ever, and a page break is a faint inline annotation, never a real
    /// page split). Printed (job 265's PDFKit mode) never reaches this function in practice
    /// — the View menu disables Show Invisibles while Printed is active — but a plain
    /// facsimile layout is the least-surprising thing to hand back should a caller ever slip
    /// through anyway.
    static func renderWithInvisibles(_ state: DocumentState) -> RenderedDocument {
        switch state.style.value {
        case .native:  return renderPrintedAnnotated(state)
        case .modern:  return renderModernAnnotated(state)
        case .printed: return render(state, style: .printed)
        }
    }

    // MARK: - Printed

    /// Job 427: `doc` unless real output page `page` declares its own `.mt`/`.mb`
    /// (`Page.mtLines`/`.mbLines`, engine Finding 3/b26-print-fidelity-2), in which case a
    /// local copy with `.page` swapped — the SAME "swap `.page` on a local `Document`
    /// copy, scoped to just this call" idiom `emitPDF`'s own per-page loop uses
    /// (`PDFWriter.swift`, the source this ports) and `PrintedStructuralParityTests.swift`'s
    /// `EngineTruth.structuralPages` already ported for its own test-harness reads. Callers
    /// check `page.mtLines != nil || page.mbLines != nil` themselves before calling this
    /// (matching the engine's own guard) so a page with no override never pays for a
    /// `Document` copy or a second `printedMetrics` call.
    private static func effectivePageDoc(_ doc: Document, for page: Page) -> Document {
        guard var eff = doc.page else { return doc }
        if let mt = page.mtLines { eff.mtLines = mt; eff.mtSource = .file }
        if let mb = page.mbLines { eff.mbLines = mb; eff.mbSource = .file }
        var pageDoc = doc
        pageDoc.page = eff
        return pageDoc
    }

    /// Line-for-line typescript reproduction, at exactly the coordinates `emitPDF` writes.
    ///
    /// Courier at the file's own `.cw` size, `.lh` leading, `.mt` top, `.po` left — all via
    /// `printedMetrics`, which is the same arithmetic the PDF emitter uses (see
    /// `PrintedGeometry.swift`). Screen and export therefore cannot disagree.
    ///
    /// `state.pageSettingsPreset` (job 203, the footer's Page Settings control), when set,
    /// is applied to `doc.page` via `effectivePage` BEFORE `printedMetrics`/`docToPagelines`
    /// read it — the exact same one-shot application `emitPDF`'s own `options.pageSettings`
    /// and the CLI's `--page-settings` flag make (`EmitOptions.swift`'s `effectivePage`), so
    /// every figure this function derives from `doc.page` (margins, header/footer lines,
    /// page length) already reflects the chosen preset with no separate override plumbing.
    private static func renderPrinted(_ state: DocumentState,
                                      exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        var doc = state.document
        if let preset = state.pageSettingsPreset.value, let page = doc.page {
            doc.page = effectivePage(page, settings: preset.settings)
        }
        let metrics = printedMetrics(doc)
        // Job 371 item 1 (PIX IN VIEWS): `state.pixResults` was resolved once against the
        // document's real path when it was opened/reparsed (`DocumentState.init`/
        // `setVariant`) — passing it (plus `.embed`) here is what makes `docToPagelines`
        // substitute a resolved `.PIX` tag's own `PageLine` for an image one
        // (`PDFLayout.swift`'s `resolvePlainBody`, the SAME sizing —
        // print-options-record-or-fit-to-measure — `emitPDF`'s own Printed PDF uses), so
        // Native's screen render can never show a picture PDF export doesn't, or vice
        // versa. Harmless when `pixResults` is empty (no graphics, or nothing resolved):
        // `resolvePlainBody`'s own `embedImages` gate stays false, byte-for-byte the same
        // plain-text-placeholder pagination as before this job.
        let pages = docToPagelines(doc, printed: true,
                                   pixResults: exportFlags.pictures ? state.pixResults : [],
                                   pictures: .embed)
        let capacity = metrics.capacity
        // Job 210: driver-aware colour, gated exactly like the engine's own
        // `colourMap` (`PDFWriter.swift:708`) — non-empty only for LJ6DTP documents, so
        // every other driver's `span.colour` (if any) stays inert, same as before this job.
        let colourMap = doc.printerDriver == "LJ6DTP" ? printedLJ6DTPColourGray : [:]

        // Clipping, not wrapping — see the type's doc comment. A wrapped line would add a
        // line to a page and push every later page break off by one.
        //
        // A11Y AUDIT FIX (potentially inaccessible text, both findings): a line wider than
        // the printed column is genuinely clipped ON SCREEN — that is the facsimile, not a
        // bug, and cannot change without breaking pagination fidelity to the library. What
        // the audit is right to flag is whether that clipping ALSO hides the text from
        // assistive technology; it does not. NSTextView's accessibility value reads from
        // `NSTextStorage`, the full unclipped string, never from what actually painted —
        // `PagedDocumentViewAccessibilityTests` proves the page views' `.string` matches
        // the library's own page text exactly, independent of column width. Modern style,
        // which reflows instead of clipping, remains the accessible reading path; Printed
        // style stays a visual facsimile with its full text still exposed to VoiceOver.
        //
        // EXACT PER-LINE LEADING (job 202) — a port of `pageStream`'s own Y-advance loop
        // (`PDFWriter.swift:602-607`), not a uniform `metrics.lead` for every line. A
        // uniform lead was the root cause of the page-2+ body-line SHIFT job 201 found
        // (`LJ6DTP.WS`/`YOURWAY.WS`): `docToPagelines` paginates each page against a
        // POINTS budget built from every line's REAL advance (`layoutPrintedPagesPlain`'s
        // `cost(_:)`, `PDFLayout.swift:1054-1058` — a line's own `.lead`, or zero if the
        // line before it was an overprint line), so a page with tighter custom leads or
        // overprint runs can legitimately hold more (or fewer) than `capacity` `PageLine`s
        // while still costing at most `(capacity - 1) * metrics.lead` points — the exact
        // height `capacity` real lines would cost at the document's DEFAULT lead. Render
        // every line at that same uniform default instead, and a page with e.g. 61
        // real lines (`capacity` 48) renders 61 * lead points of text into a container
        // sized for 48, and AppKit's automatic container-chain flow silently pushes the
        // (61 - 48) excess into the NEXT container — cascading a constant line-count
        // shift onto every later page, which is exactly the field symptom.
        //
        // `pageStream`'s loop (`PDFWriter.swift:602-607`) advances by `line[n].lead ??
        // lead` UNLESS the line immediately before it was `overprint` (then by zero — the
        // next line shares its baseline instead of starting a new one). That is a gap
        // BEFORE line n, indexed by line n itself — not by the line before it.
        //
        // JOB 245 FIX (FORMFEED.WS one-line-low, job 232 class b): this function used to
        // assign fragment k's height from line k+1's lead, on the theory that "fragment
        // k's height carries fragment k+1's top from fragment k's [baseline]" — i.e. that
        // baseline-to-baseline gap equals the EARLIER fragment's own pinned height. That
        // theory is false in AppKit: `firstBaselineOffset` above exists BECAUSE a
        // fragment's baseline-from-its-own-top offset is a function of THAT fragment's own
        // pinned `minimumLineHeight`/`maximumLineHeight`, not a font-fixed constant — a
        // 24pt-tall fixed fragment sits its baseline ~12pt lower inside itself than a
        // 12pt-tall one does. Composing that with fragment tops accumulating via the
        // PRECEDING fragment's own height gives baseline(n) - baseline(n-1) = H(n), the
        // CURRENT fragment's own height, not H(n-1). The old off-by-one was invisible on
        // every uniform-lead page (H(n) == H(n-1) everywhere, so it made no difference)
        // and only surfaced exactly at a `.lh` transition, which is why it survived jobs
        // 202/224/225/227's own extensive verification: FORMFEED.WS's `.lh 24` paragraph
        // start jumped a whole ordinary lead too EARLY (`ZZProbeJob245Formfeed`'s replica
        // of this function's old formula matched the code exactly — 12 at the blank line
        // before the transition, 24 starting the next — proving the ARITHMETIC was right
        // and the INDEXING CONVENTION was the defect). Reading `page[i].lead` (this
        // fragment's own line, matching `pageStream`'s `line[n].lead` exactly) fixes it;
        // the old "last real line: cosmetic" tail guard is gone too — nothing here needs
        // to peek at `i + 1` any more, so there is no tail case left needing one.
        // `nearZeroLead` stands in for a true zero-height fragment —
        // `NSParagraphStyle.maximumLineHeight == 0.0` means "unbounded" in AppKit's own
        // API, not zero, so an actual zero can't be expressed directly; a fragment this
        // small reproduces "shares the previous baseline" for pagination purposes (the
        // only thing this port is scoped to fix) while leaving true overprint
        // double-strike RENDERING — visually overlaying the two lines' glyphs — as an
        // unclaimed follow-up, same as before job 202.
        let nearZeroLead: Double = 0.01
        func advanceLead(_ page: Page, at i: Int) -> Double {
            guard i > 0 else { return metrics.lead }   // first line on page: cosmetic
            return page[i - 1].overprint ? nearZeroLead : (page[i].lead ?? metrics.lead)
        }
        // Register b31 (job 506): `extraLeftPt` shifts a paragraph's own left edge past
        // `metrics.left`, the document DEFAULT `.po` — needed because `.po` is now
        // stateful per line (`Line.poCols`/`PageLine.left`, the same "carries the rest,
        // nil means agrees with the document default" contract `PageLine.lead` already
        // has for `.lh`). `PageLine.left` arrives HERE already resolved to points by the
        // engine's own public `docToPagelines(doc, printed: true)` call
        // (`resolvePrintedBody`/`resolvePlainBody` in `PDFLayout.swift` compute it via
        // the library's own internal `resolveLeftPt`, which this app cannot call
        // directly — same "internal helper, public resolved field" shape
        // `PrintedPCLGraphics.swift`'s own top doc comment already established for
        // `pclRectOps`) — this function only has to READ it, not re-derive the formula.
        // Both `firstLineHeadIndent`/`headIndent` get the SAME value: Printed mode clips
        // rather than wraps (`lineBreakMode = .byClipping`), so every paragraph here is
        // exactly one physical line, and AppKit distinguishes the two indents only across
        // a paragraph's own wrapped rows.
        func paragraphStyle(lead: Double, extraLeftPt: Double = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = CGFloat(lead)
            style.maximumLineHeight = CGFloat(lead)
            style.lineBreakMode = .byClipping
            if extraLeftPt != 0 {
                style.firstLineHeadIndent = CGFloat(extraLeftPt)
                style.headIndent = CGFloat(extraLeftPt)
            }
            return style
        }
        // `minimumLineHeight`/`maximumLineHeight` both 0 (`NSMutableParagraphStyle`'s own
        // default) mean "unbounded" — this file's own established convention (see
        // `nearZeroLead`'s doc comment above for the citation). Used only by `naturalPass`
        // (job 227): a line measured and drawn at its OWN font's natural height instead of
        // clamped to any document lead.
        func naturalParagraphStyle() -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            return style
        }
        func lineAndTerminator(_ line: PageLine, lead: Double) -> NSAttributedString {
            let extraLeftPt = (line.left.map { $0 - metrics.left }) ?? 0
            let paragraph = paragraphStyle(lead: lead, extraLeftPt: extraLeftPt)
            // Job 371 item 1 (PIX IN VIEWS): a resolved `.PIX` tag became its OWN `PageLine`
            // at the `docToPagelines` call above (`spans` empty by construction — see
            // `PageLine.image`'s own doc comment) — draw the decoded bitmap instead of
            // running `attributedLine` over an empty span list (which would otherwise emit
            // just the blank-line space filler). `widthPt`/`heightPt` are already the
            // engine's own print-options-record-or-fit-to-measure size, in points — the
            // SAME box `emitPDF`'s `pageStream` draws the XObject into — so Native's screen
            // size and the Printed PDF's size can never disagree.
            if let image = line.image {
                let piece = NSMutableAttributedString(attributedString: Self.pixAttachmentString(
                    state.pixResults, index: image.pixIndex,
                    widthPt: image.widthPt, heightPt: image.heightPt, paragraph: paragraph))
                piece.append(lineTerminator(font: courier(size: CGFloat(metrics.size)),
                                            paragraph: paragraph))
                return piece
            }
            let piece = NSMutableAttributedString(attributedString: attributedLine(
                coalesce(line).spans, font: courier(size: CGFloat(metrics.size)),
                paragraph: paragraph, fonts: doc.fonts, defaultSize: metrics.size,
                colourMap: colourMap, disableKerning: true, useCourierPrime: true))
            piece.append(lineTerminator(font: courier(size: CGFloat(metrics.size)),
                                        paragraph: paragraph))
            return piece
        }
        let output = NSMutableAttributedString()
        var softLineFlags: [[Bool]] = []
        var overprintPasses: [[[NSAttributedString]]] = []
        var oversizedSelfPasses: [[NSAttributedString?]] = []
        var runningLines: [[RunningLine]] = []
        let startNo = doc.page?.pnStart ?? 1
        // Job 412: `top` is the distance from the paper's top edge to the FIRST BASELINE —
        // hoisted here (ahead of its previous, later position, computing the same value
        // from the same `metrics`-only inputs) because the pagination loop below now needs
        // it as the PER-PAGE Y anchor for `pinnedBaselines`, not only for the container's
        // own top-edge placement. See this file's original citation on `firstBaseline`
        // (still below, where `textFrame`/`normalBaselineOffset` are built) for the
        // `y = pageHeight - top - size` field-evidence citation.
        //
        // This is the NOMINAL figure only — `textFrame`'s own shared top-edge position,
        // still built from it below for sizing/fallback purposes. Job 427: the SCREEN
        // container's per-page top edge no longer has to share one flat position — see
        // `RenderedDocument.perPageTextTop` — but this flat figure stays as the array's own
        // fallback value and as every OTHER render path's (Modern, Show Invisibles) single
        // shared anchor, matching `pinnedBaselines`'s own emptiness there. Per-page baseline
        // ANCHORING uses `pageFirstBaseline` instead, computed fresh inside the loop below.
        let firstBaseline = metrics.top + Double(metrics.size)
        // Job 425 (b26 round 26 wave 3, ctrl-kd's own `pageStream`, PDFWriter.swift: "The
        // first line of a page takes its position from `top` and ITS OWN lead (not a flat
        // `size`, and not always the document default `lead` parameter)"): each PAGE's real
        // engine anchor — `page.first?.lead ?? metrics.lead`, exactly `pagelines.first?.lead
        // ?? lead` on the engine side, the SAME field `advanceLead` above already reads for
        // every OTHER line. Previously every page reused the single flat `firstBaseline`
        // (`top + metrics.size`) as its own first-fragment anchor too — invisible whenever a
        // page's first line's own lead equalled the document default (true of every fixture
        // before this pin, since `size`/`lead` happened to coincide everywhere they'd been
        // measured), but WRONG the moment a page opens on a line with its OWN lead — an
        // oversized title chief among them, whose natural (`styleLeadPt`, 1.2x its own font
        // size) lead is nothing like the document's plain-Courier default. Confirmed via the
        // engine's real PDF content stream (`Td`) for WARPRAYR.WS: title baseline at
        // paper-top-distance 79.2pt = top(60) + 1.2*16 (its own 16pt lead), not the app's old
        // 72pt = top(60) + metrics.size(12) — a 7.2pt miss, matching
        // `warprayrTitleTopAgreesWithEngine`'s measured 7.5pt (pixel-scan/font-substitution
        // noise makes up the rest, well inside its own tolerance once the anchor is right).
        var perPageFirstBaselines: [Double] = []
        perPageFirstBaselines.reserveCapacity(pages.count)
        // Job 427: hoisted from below `pages.enumerated()` (was computed once, after the
        // loop, from `metrics` alone) — needed INSIDE the loop now to build
        // `perPageTextTop` per page. Safe to move: every input (`metrics.size`/`.lead`/
        // `.pageWidth`/`.left`, `courier(size:)`, `paragraphStyle(lead:)`) is document-
        // global, none of them a function of any one page's own content or margin.
        let normalBaselineOffset = firstBaselineOffset(
            font: courier(size: CGFloat(metrics.size)),
            paragraph: paragraphStyle(lead: metrics.lead),
            width: max(1, metrics.pageWidth - metrics.left))
        // Job 427: also hoisted (was computed once, after the loop, alongside
        // `normalBaselineOffset` above) — this is the DOCUMENT-GLOBAL container anchor
        // every page used before this job, and stays the BASE every page's own
        // `perPageTextTop` entry is built from below (see that call site's own doc
        // comment for why the per-page entry is this base PLUS a delta, not a wholesale
        // re-derivation from `pageFirstBaseline`).
        let textTop = max(0, firstBaseline - normalBaselineOffset)
        var perPageTextTop: [Double] = []
        perPageTextTop.reserveCapacity(pages.count)
        // Job 412 (Jon's ruling on job 408's decision brief, option (a) — see
        // `RenderedDocument.pinnedBaselines`'s own doc comment for the full mechanism):
        // per real AppKit fragment, keyed by the character offset where it starts, the
        // ENGINE's own absolute baseline Y. `pageEngineY` is the running per-page
        // accumulator — reset to `firstBaseline` at the first real fragment of every page
        // (the engine's own `openPage()` anchor, `PDFWriter.swift`), then advanced by
        // exactly the same `lead` value the loop below already computes for PAGINATION
        // purposes (`advanceLead(page, at: i)`, the group's own base line) — the identical
        // `y -= line.lead` walk `pageStream` performs, just accumulated top-down instead of
        // bottom-up.
        var pinnedBaselines: [Int: PinnedBaseline] = [:]
        // Job 412: per page, `lastGroupEngineY + lastGroupOwnHeight - lastGroupIsolatedK` —
        // see `RenderedDocument.pinnedPageBottoms`'s own doc comment for why
        // `PagedDocumentView.buildExplicitPages` needs this instead of trusting its own
        // AppKit probe measurement for a pinned page's container height.
        var pinnedPageBottoms: [Double] = []
        // Job 224: one line's `.overprint` flag means the NEXT line shares ITS baseline
        // (`PDFWriter.pageStream`'s own `prevOverprint` skip, `PDFWriter.swift:600-604`; the
        // flag itself comes from a bare-CR "^PM Overprint Line" separator,
        // `ParseWS.swift:783-785`'s own comment: "the NEXT line prints at THIS line's own
        // baseline (LJ6DTP's white-on-black knockouts; strikeover composites)"). A RUN of
        // such lines — the field fixture has chains up to 3 deep: two flush-right bar passes
        // (`PDFDriverLJ6DTP.swift`'s own note on why a proportional-font block needs two
        // passes to close a full-width bar) then the knockout text on top — all share ONE
        // baseline, not `len` separate ones.
        //
        // Before this job, EVERY chain member got rendered as its own real (if
        // `nearZeroLead`-tall) fragment: correct for PAGINATION cost (`advanceLead` already
        // charged a chain member zero real lead), but AppKit does not honour a pinned
        // `minimumLineHeight == maximumLineHeight` bit-for-bit per fragment (job 202's own
        // finding: ~0.5pt of rounding per 43 fragments) — accumulated across LJ6DTP.WS's own
        // several chains (one 3-deep chain alone on page 1, four more on page 6), that
        // rounding was enough to push the fixture one whole page longer than the engine
        // (app=9, engine=8; `docToPagelines`, which BOTH the engine and this function call,
        // already agrees the real answer is 8). Only the FIRST member of a chain becomes a
        // real fragment below; every other member is captured here and composited by
        // `PageTextView.drawOverprintPasses` (`PagedDocumentView.swift`) directly onto that
        // fragment's own glyph geometry — zero extra height, on paper and here, matching
        // `layoutPrintedPagesPlain`'s `cost(_:)` (`PDFLayout.swift:1054-1058`) exactly instead
        // of merely approximating it.
        // Job 246 (p6-knockout): NATURAL (unbounded) height, not `paragraphStyle(lead:
        // metrics.lead)` — a pass never contributes to pagination cost either way (see
        // this function's own doc comment above, "a chain member charges ZERO pagination
        // cost"), so there was never a page-count reason to clamp it, only an unexamined
        // default. Clamping bit LJ6DTP.WS's "Black Text on a Gray Background" heading
        // (24pt, chained under a 28pt gray band far taller than `metrics.lead`): AppKit's
        // baseline placement inside a pinned box shorter than the line's own tallest font
        // is undocumented and, measured directly, put the baseline only 6pt below an
        // 18.8pt-tall fragment top for THAT 24pt run — nowhere near where a 24pt font's
        // real baseline sits — which is what sent `drawOverprintPasses`'s (now baseline-
        // correct, see its own job 246 doc comment) alignment chasing a wrong number.
        // `naturalPass` below already establishes the fix for a chain's BASE line; this
        // is the identical fix for every OTHER member of the chain.
        func overprintPass(_ line: PageLine) -> NSAttributedString {
            attributedLine(coalesce(line).spans, font: courier(size: CGFloat(metrics.size)),
                           paragraph: naturalParagraphStyle(), fonts: doc.fonts,
                           defaultSize: metrics.size, colourMap: colourMap, disableKerning: true,
                           useCourierPrime: true)
        }
        // Job 227: LJ6DTP.WS's 72pt "LJ6DTP" banner title, immediately followed by its own
        // `.lh .05"` (3.6pt) shadow copy — the reference archive document `PDFWriter
        // .pageStream`'s own doc comment cites by name (PDFWriter.swift:576-584). A line's
        // lead is only ever the space ABOVE it there; the engine never boxes a line's
        // height to that gap, so an oversized glyph simply paints past it with nothing to
        // clip. This fragment's `minimumLineHeight == maximumLineHeight` box has no such
        // freedom: measured directly (`ZZProbeJob227`), the 72pt banner squeezed into its
        // 3.6pt-tall real fragment gets a baseline at y=-13.4 in a container that starts at
        // y=0 — entirely above the visible page, which is why the banner was
        // `missingInActual` in the oracle rather than merely clipped.
        //
        // `lineExceedsFragment` (below) flags a line whose own tallest resolved font is far
        // taller than the fragment `advanceLead` is about to give it. `naturalPass` renders
        // that SAME content again at its own natural (unbounded) height instead. UNLIKE an
        // `.overprint` chain's continuation passes (`overprintPass` above), this does NOT
        // go into `overprintPasses` — `PageTextView.drawOverprintPasses` composites onto
        // this view's OWN glyph geometry, and this view's own bounds equal the text
        // CONTAINER, which is exactly the box a 72pt glyph does not fit in (see
        // `PagedDocumentView.drawOversizedSelfPasses`'s own doc comment for why that draws
        // it at the PAPER level instead, where the glyph has room to bleed into the margin
        // the same way it does in the engine's own unbounded PDF canvas). The real fragment
        // itself stays exactly as tiny as `advanceLead` says (see the call site) —
        // pagination and every line after this one are untouched, only what gets DRAWN
        // inline changes.
        // `reservedLead`: only consulted for an image line (below) — this line's own
        // RESERVED BAND height, `PageLine.lead ?? image.heightPt` (job 438; port of
        // `PDFWriter.pageStream`'s real image branch, `let reserved = line.lead ?? img
        // .heightPt` — confirmed against the ACTUALLY-LINKED engine checkout, not the
        // possibly-stale top-level mirror job 427 already warned about). Falling back to
        // the image's OWN height (not `metrics.lead`) when a line genuinely carries no
        // lead at all matches the engine's own fallback: "no reservation declared" means
        // "reserve exactly what the picture needs," not the document's unrelated text lead.
        func naturalPass(_ line: PageLine, reservedLead: Double) -> NSAttributedString {
            // Job 426: an image line's own self-pass — `coalesce(line).spans` is empty by
            // construction for a PIX `PageLine` (job 371's own citation), so this fell
            // through to blank/empty content before, drawing nothing at the paper level
            // where `lineExceedsFragment`'s new image check now routes it. Same
            // `pixAttachmentString` `lineAndTerminator` uses for an ordinary (non-oversized)
            // picture, just at natural (unbounded) height instead of a clamped fragment lead
            // — the picture's own real size was always `widthPt`/`heightPt`; only the
            // CONTAINER used to be too small to show it.
            if let image = line.image {
                return Self.pixAttachmentString(
                    state.pixResults, index: image.pixIndex,
                    widthPt: image.widthPt, heightPt: image.heightPt,
                    paragraph: naturalParagraphStyle(), reservedLeadPt: reservedLead)
            }
            return attributedLine(coalesce(line).spans, font: courier(size: CGFloat(metrics.size)),
                           paragraph: naturalParagraphStyle(), fonts: doc.fonts,
                           defaultSize: metrics.size, colourMap: colourMap, disableKerning: true,
                           useCourierPrime: true)
        }
        // Job 225: this function no longer tries to make each page's own block of lines
        // RENDER to any particular height — it emits page N's own real lines and nothing
        // else, padding included or not. Making AppKit's container chain break exactly on
        // `docToPagelines`' own boundaries is `PagedDocumentView.buildPages`'s job now: it
        // measures this same flow once (a single oversized probe container) and gives each
        // page's own real text container exactly the height that measured, so there is no
        // "how much padding closes the gap" arithmetic left to get wrong here. See that
        // function's own doc comment for the mechanism and why a page-side padding/
        // measurement compromise (this function's previous approach; job 202/223/224's
        // LJ6DTP residual) could not fully close it: an ISOLATED per-page probe (a
        // freshly-built `NSTextStorage`/`NSLayoutManager` holding only that page's own
        // chunk) measurably disagrees with how the SAME text measures once actually
        // embedded in the real multi-container chain, and no amount of retuning the
        // padding math on this side can fix a measurement taken on the wrong flow.
        for (index, page) in pages.enumerated() {
            // Job 427 (Jon's ruling: "Native only changes fonts. Otherwise it's the same
            // as Printed."): this page's own effective top margin — `metrics.top` (the
            // document-global one) UNLESS this real page declares its own `.mt`/`.mb`
            // (`Page.mtLines`/`.mbLines`, engine Finding 3/b26-print-fidelity-2), in which
            // case a local copy of `doc` with `.page` swapped, mirroring `emitPDF`'s own
            // per-page idiom exactly (`PDFWriter.swift`'s per-page loop over `pages`,
            // "a local COPY of doc with .page swapped ... scoped to just this page's
            // printedTop/runningOps calls") — already ported to this test suite's own
            // `EngineTruth.structuralPages` (`PrintedStructuralParityTests.swift`) but never
            // to the real render path until now. SCRIPT.WS's figure-listing pages (a very
            // different `.mt` from the screenplay body) are the proving case: without this,
            // every page rendered at the document's global top margin regardless of its own
            // declared one.
            let hasPageOverride = page.mtLines != nil || page.mbLines != nil
            let pageDoc = hasPageOverride ? Self.effectivePageDoc(doc, for: page) : doc
            let pageTop = hasPageOverride ? printedMetrics(pageDoc).top : metrics.top
            runningLines.append(exportFlags.headers
                ? Self.runningLines(for: page, pageNo: startNo + index, doc: pageDoc, metrics: metrics)
                : [])
            // Job 425: this page's own real anchor — see the citation on `perPageFirstBaselines`
            // above. `page.first?.lead` (not `pages[index].first?.lead` re-derived) since
            // `page` IS `pages[index]`, the loop's own element. `pageTop`, not `metrics.top`
            // (job 427) — see this loop's own citation just above.
            let pageFirstBaseline = pageTop + (page.first?.lead ?? metrics.lead)
            perPageFirstBaselines.append(pageFirstBaseline)
            // Job 427: `textTop` (the document-global anchor, unchanged) PLUS the delta a
            // genuine per-page `.mt`/`.mb` override introduces (`pageTop - metrics.top`,
            // exactly `0` for every page without one) — NOT a wholesale re-derivation from
            // `pageFirstBaseline` above. `pageFirstBaseline` mixes in the page's own FIRST
            // LINE's lead (job 425), a real but UNRELATED difference from `firstBaseline`'s
            // own `size`-based anchor that the `NSLayoutManagerDelegate`'s per-fragment
            // `entry.y - textTop` conversion already absorbs algebraically for the container
            // ORIGIN (the `pageTextTop` term cancels: screen Y ends up `entry.y - k`
            // regardless of what constant `textTop` uses, AS LONG AS the built container is
            // tall enough) — but `buildExplicitPages`' HEIGHT calculation does NOT get that
            // same cancellation (`pinnedPageBottoms[i] - textTop(atPage: i)` is a real
            // subtraction, not one that nets out), so re-deriving this from
            // `pageFirstBaseline` wholesale silently shrank every ordinary (no-override)
            // page's own container by the lead-vs-size gap and broke the delegate's own
            // `entry.page == containerPageIndex` overflow guard on any document where the
            // document lead differs from its type size (confirmed: YOURWAY.WS, `.lh 18` on
            // `.cw 12`, regressed pages 9+ before this fix). Isolating the new term to ONLY
            // the override's own delta keeps every no-override page byte-identical to
            // before this job.
            perPageTextTop.append(max(0, textTop + (pageTop - metrics.top)))
            var flags: [Bool] = []
            var passes: [[NSAttributedString]] = []
            var selfPasses: [NSAttributedString?] = []
            if page.isEmpty {
                // One blank line, not `capacity` — a wholly blank page is still a blank
                // sheet (`PagedDocumentView`'s page rect is drawn from `pageSize`
                // regardless of how little the text container holds), and this function no
                // longer owns making the CONTAINER match the sheet's visual height.
                let piece = lineAndTerminator(PageLine(), lead: metrics.lead)
                let blankK = Self.isolatedFragmentK(piece, width: metrics.pageWidth - metrics.left)
                pinnedBaselines[output.length] = PinnedBaseline(page: index, y: pageFirstBaseline, k: blankK)
                pinnedPageBottoms.append(pageFirstBaseline + metrics.lead - blankK)
                output.append(piece)
                flags.append(false)
                passes.append([])
                selfPasses.append(nil)
            } else {
                let pageChunk = NSMutableAttributedString()
                let pageStartOffset = output.length
                // Job 412: this page's own running engine Y — reset to `firstBaseline` at
                // the page's first real fragment (below), then advanced by each
                // subsequent group's own `lead` (the SAME value already computed for
                // pagination, `advanceLead(page, at: i)`) — the identical walk
                // `pageStream` performs, accumulated top-down instead of bottom-up. `nil`
                // means "not yet anchored," distinguishing the page's first group from
                // every later one without a separate `Bool`.
                var pageEngineY: Double?
                var lastGroupBottom = pageFirstBaseline
                var lastGroupPiece: NSAttributedString?
                var i = 0
                while i < page.count {
                    // The chain runs while each member is itself `overprint` — its
                    // successor shares ITS baseline too.
                    var j = i
                    while page[j].overprint, j + 1 < page.count { j += 1 }
                    let base = page[i]
                    // `i`, not `j` (job 245): the fragment's rendered height is the gap
                    // BEFORE THIS GROUP, i.e. `advanceLead`'s rule applied to the group's
                    // OWN base line — `page[i].lead ?? metrics.lead`, checking whether the
                    // line immediately before the GROUP (not within it) was itself
                    // overprint. The chain's interior members (`i+1...j`) never form their
                    // own fragment regardless, so their own `.lead` is moot here.
                    let lead = advanceLead(page, at: i)
                    // Job 227: an oversized base line (see `lineExceedsFragment`) renders NO
                    // glyphs of its own inline — squeeze-drawing them into this tiny real
                    // fragment is exactly what clipped the banner off the top of the page.
                    // The fragment still costs the SAME `lead` either way, so pagination and
                    // every line after it are unaffected; only what's drawn here changes.
                    let oversized = Self.lineExceedsFragment(
                        base, assignedLead: lead, fallback: courier(size: CGFloat(metrics.size)),
                        fonts: doc.fonts, defaultSize: metrics.size, useCourierPrime: true)
                    let content = oversized ? PageLine([], soft: base.soft) : base
                    // Job 269 (title-stack spacing): an oversized SELF-PASS fragment never
                    // draws real content of its own — `drawOversizedSelfPasses` positions its
                    // own baseline from `RenderedDocument.baselineOffset`, a SINGLE offset
                    // shared by every self-pass on every page, not a per-fragment offset
                    // AppKit would compute for real content sized to `lead` — so this
                    // fragment's PINNED HEIGHT is consulted only to place the NEXT fragment's
                    // top, and has to carry the NEXT LINE's own gap (`advanceLead` applied to
                    // the line after this group), not this line's own (`lead` above, correct
                    // for pagination and for a real-content fragment, but not for what a
                    // self-pass needs). LJ6DTP.WS's title (`page[0]`) into its `.lh .05"`
                    // shadow copy (`page[1]`, lead 3.6) is exactly this: the title's own gap
                    // (`lead`, the ordinary document default) correctly pins how far down the
                    // TITLE ITSELF sits below whatever came before it, untouched — but the OLD
                    // code also used that same `lead` for the title's own fragment height, so
                    // the shadow copy's fragment started a full ordinary lead below the title
                    // instead of 3.6pt, spreading the "shadow" into daylight and, since every
                    // later fragment on the page stacks on top of that same excess, parking
                    // the whole stack that much closer to the gray bar beneath it. Borrowing
                    // the NEXT real line's own lead instead reproduces `pageStream`'s own
                    // baseline chain (`y -= line[n].lead`) for a self-pass exactly the way job
                    // 245's `page[i].lead` convention already does for ordinary content. Only
                    // the fragment HEIGHT changes here — pagination (`lead` above), the
                    // chain's own oversized test, and every non-oversized line are untouched;
                    // when the next line's lead already equals this line's own (the common,
                    // unstacked case, e.g. OLDTIMES.WS's single title), `fragmentLead == lead`
                    // and nothing visibly changes.
                    let fragmentLead: Double
                    if oversized, j + 1 < page.count {
                        fragmentLead = advanceLead(page, at: j + 1)
                    } else {
                        fragmentLead = lead
                    }
                    // Job 412: `lead` (not `fragmentLead`) is this GROUP's own gap from the
                    // fragment before it — `fragmentLead` only exists to give an oversized
                    // fragment the NEXT line's height (see the doc comment above), never to
                    // change how far down THIS group's own baseline sits. Matches
                    // `pageStream`'s own `y -= line[n].lead` exactly: advance once per real
                    // fragment (group), by that group's own base line's lead.
                    let engineY = pageEngineY.map { $0 + lead } ?? pageFirstBaseline
                    pageEngineY = engineY
                    let piece = lineAndTerminator(content, lead: fragmentLead)
                    // Job 413: probed from a DE-SUPERSCRIPTED copy of this same content —
                    // see `PinnedBaseline.k`'s own doc comment for why a raised/lowered run
                    // left in would perturb this line's own pinned baseline on its account.
                    let k = Self.isolatedFragmentK(
                        lineAndTerminator(desuperscripted(content), lead: fragmentLead),
                        width: metrics.pageWidth - metrics.left)
                    // Job 413: see `firstGlyphRaiseCompensation`'s own doc comment — folded
                    // into `PinnedBaseline.y`, NEVER into `engineY`/`pageEngineY` (this
                    // fragment's own TRUE grid position, which every LATER line's own
                    // accumulation and `pinnedPageBottoms` both still need untouched).
                    let compensation = Self.firstGlyphRaiseCompensation(
                        content, fallback: courier(size: CGFloat(metrics.size)), fonts: doc.fonts,
                        defaultSize: metrics.size, useCourierPrime: true)
                    pinnedBaselines[pageStartOffset + pageChunk.length] = PinnedBaseline(
                        page: index, y: engineY + compensation, k: k)
                    pageChunk.append(piece)
                    // Job 412: whatever this holds when the loop ends is the PAGE's own
                    // LAST group — exactly what `RenderedDocument.pinnedPageBottoms` needs
                    // (see that field's own doc comment).
                    lastGroupBottom = engineY + fragmentLead
                    lastGroupPiece = piece
                    // The flag rides on the PRE-coalesce line — `coalesce` merges spans
                    // and carries no flags of its own (it only ever needed `lead`, see
                    // its doc comment in PDFLayout.swift).
                    flags.append(base.soft)
                    let linePasses = i == j ? [] : (i + 1...j).map { overprintPass(page[$0]) }
                    passes.append(linePasses)
                    selfPasses.append(oversized
                        ? naturalPass(base, reservedLead: base.lead ?? (base.image?.heightPt ?? metrics.lead))
                        : nil)
                    i = j + 1
                }
                let lastGroupK = lastGroupPiece.map {
                    Self.isolatedFragmentK($0, width: metrics.pageWidth - metrics.left)
                } ?? 0
                // Job 412: `isolatedK` is measured the same "ask AppKit" way as every other
                // figure in this file, but job 408 already found an ISOLATED single-line
                // probe doesn't always predict the real IN-CONTEXT baseline offset exactly
                // (measured discrepancy there: ~1pt, isolated vs. embedded-in-a-real-
                // multi-paragraph-flow) — a small, fixed safety margin absorbs that known
                // slop without being anywhere near a full line's own height (12pt+ on
                // every fixture measured), so it cannot let a whole extra line sneak into
                // a page the way an UNCOMPENSATED-K guess did (this field's own doc
                // comment has that citation).
                let isolatedKSafetyMargin: Double = 2.0
                pinnedPageBottoms.append(lastGroupBottom - lastGroupK + isolatedKSafetyMargin)
                output.append(pageChunk)
            }
            softLineFlags.append(flags)
            overprintPasses.append(passes)
            oversizedSelfPasses.append(selfPasses)
        }
        // The flow needs no trailing newline: the last line's own terminator already closed
        // it, and an extra one would start a phantom page.
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        // The library's own geometry is the facsimile truth for where the TEXT sits —
        // untouched below, so screen and `emitPDF` never disagree (see this file's top doc
        // comment). The PAPER itself is a separate display choice the bottom bar's Page
        // control makes: when the user has picked a size by hand, the sheet the text sits on
        // grows or shrinks to that choice while every glyph stays exactly where the library
        // put it — the same relationship a print shop reprinting a typescript on a different
        // sheet would preserve. Previously this function never consulted `state.pageSize` at
        // all, so a manual Page Size choice changed the bottom bar's label and silently did
        // nothing to what was on screen — one of the "selections don't visibly take effect"
        // findings.
        var pageSize = CGSize(width: metrics.pageWidth, height: metrics.pageHeight)
        if state.pageSize.provenance == .manual, let manual = state.pageSize.value {
            pageSize = manual.sizeInPoints
        }
        // `top` is the distance from the paper's top edge to the FIRST BASELINE. A text
        // container is positioned by its top EDGE, so the container has to start exactly one
        // first-baseline-offset above where the library wants that baseline.
        //
        // That offset is NOT the lead. This subtracted `metrics.lead` and put every line 3pt
        // high on every fixture — measured by the geometry oracle, which is how it was found
        // rather than by Jon looking at a page. Nor is it worth deriving from ascent by hand:
        // the figure depends on the font AND the paragraph style's fixed line height, and
        // AppKit is the only authority on what it will actually do. So ask it.
        // `metrics.top` is the top MARGIN, not the first baseline — whatever the façade's
        // doc comment says. The PDF emitter is the authority and its formula is
        //     y = pageHeight - top - size
        // i.e. the first baseline sits `top + size` below the paper's top edge. Measured
        // against `sr --mode printed` on the same file: the library puts line 1's baseline at
        // 48.0pt (top 36 + size 12); this code placed it at 36.0 and every line after it was
        // one full line high. That is the "top and bottom margins are very wrong" Jon
        // reported — the whole block sat 12pt up, so the head was short and the foot long.
        // (`firstBaseline` itself is now computed further up, job 412 — see that
        // declaration's own comment for why the pagination loop needs it too.)
        // The container's top-edge offset is a property of the document's DEFAULT line
        // grid (`metrics.lead`), not of any one page's own first line — that line's
        // rendered height now varies per page (see `advanceLead` above). `textTop` itself
        // (job 427: hoisted above the per-page loop alongside `normalBaselineOffset`, see
        // that hoist's own doc comment) stays the flat, document-global figure — used for
        // `textFrame` below (sizing, and every non-Printed path's shared anchor) and as the
        // BASE every page's own `perPageTextTop` entry adds its own override delta to.
        let textFrame = CGRect(
            x: metrics.left,
            y: textTop,
            width: max(1, metrics.pageWidth - metrics.left),
            height: CGFloat(capacity) * metrics.lead
        )
        let leadingHeadroom = Self.leadingHeadroom(oversizedSelfPasses, firstBaselines: perPageFirstBaselines)

        return RenderedDocument(
            text: output,
            pageSize: pageSize,
            textFrame: textFrame,
            pageCount: max(1, pages.count),
            clipsLines: true,
            softLineFlags: softLineFlags,
            overprintPasses: overprintPasses,
            oversizedSelfPasses: oversizedSelfPasses,
            baselineOffset: normalBaselineOffset,
            leadingHeadroom: leadingHeadroom,
            runningLines: runningLines,
            // Printed's own real pages are known here already (`docToPagelines` above) — no
            // deferred replay log needed (job 393's own `hfEvents`/`pageNumberStart`, Modern-
            // only; see `RenderedDocument.hfEvents`'s own doc comment).
            hfEvents: [],
            pageNumberStart: startNo,
            realPageIndexByPage: Array(0..<max(1, pages.count)),
            pinnedBaselines: pinnedBaselines,
            perPageTextTop: perPageTextTop,
            pinnedPageBottoms: pinnedPageBottoms,
            // Printed has no screenplay-marker concept — see `RenderedDocument
            // .modernForcedPageBreakOffsets`'s own doc comment.
            modernForcedPageBreakOffsets: [],
            // Printed's own footnote placement is the engine's real pagination
            // (`docToPagelines`), already resolved by the time this function sees it — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            pclPrograms: doc.pclPrograms
        )
    }

    // MARK: - Printed, Show Invisibles (job 256/257, parts 2-3/4)

    /// `renderPrinted`'s sibling for the `showInvisibles` screen path — same page metrics,
    /// margins and Courier grid, but the text comes from `CtrlKD.annotatedLayout(doc)`
    /// instead of `docToPagelines`: an ordered stream where dot-command lines, comments,
    /// style-toggle tokens and soft/hard end-of-line marks are already tagged, interleaved
    /// with the document's own `.visible` runs.
    ///
    /// `.visible` spans reuse `appendSpan` — the SAME per-span logic `attributedLine` runs
    /// for the plain path (font/style resolution, the leading-indent re-stamp, kerning) —
    /// so real text looks identical to today's rendering. LJ6DTP driver colour still does
    /// not survive (`AnnotatedSpan` carries no `colour` field at all — job 255's own API
    /// gap, unrelated to pagination and out of scope for an engine-side fix here).
    ///
    /// JOB 257 (part 3/4, the spec's reflow ruling): job 256 grouped pages from
    /// `annotated.lines`' own `pageBreakBefore` markers directly and matched running
    /// heads/feet to `docToPagelines`' pages BY INDEX — both were naive on purpose ("page-
    /// count correctness is part 3"). This function now:
    ///   1. Repaginates for real: every `pageBreakBefore` marker (explicit `.pa`/`.cp`/
    ///      form-feed, or the natural-overflow break the PLAIN document's own budget
    ///      decided) still forces a break exactly where the engine already put it, but a
    ///      NEW budget walk on top of that — the identical points arithmetic
    ///      `layoutPrintedPagesPlain` uses, `(capacity - 1) * defaultLead`, spent one
    ///      annotated line at a time — adds FURTHER breaks whenever the extra dot-command
    ///      lines this feature inserts push a page over budget. Invisible lines have no
    ///      `.lh` of their own (they are screen furniture, not source text) and spend the
    ///      document's default lead; a real line spends its own `.lh`-aware lead exactly
    ///      like `renderPrinted`'s `advanceLead`. This is why a dot-heavy page can render
    ///      MORE pages with Invisibles on than off, never fewer — the ruling.
    ///   2. Running heads/feet are looked up from whichever REAL `docToPagelines` page is
    ///      "in force" at each local page's own position (tracked per real line via
    ///      `flatPageIndex`, not by matching index) — correct once reflow has made the two
    ///      page counts diverge, and identical to job 256's approximation on any document
    ///      that never diverges (the common case).
    ///   3. Reuses `renderPrinted`'s own two per-line mechanisms directly against the REAL
    ///      `PageLine` each annotated real line pairs with: `.overprint` chain compositing
    ///      (job 224) and oversized-self-pass routing (job 227, `lineExceedsFragment`) — a
    ///      real line's `.visible` text is suppressed inline and the SAME annotated content
    ///      (marks included) re-rendered as a natural-height pass/self-pass, so LJ6DTP's
    ///      banners and knockouts survive Invisibles being on. Dot-command/mark-only lines
    ///      never chain and are never oversized (`baseFont`, always well under any `.lh`).
    private static func renderPrintedAnnotated(_ state: DocumentState) -> RenderedDocument {
        var doc = state.document
        if let preset = state.pageSettingsPreset.value, let page = doc.page {
            doc.page = effectivePage(page, settings: preset.settings)
        }
        let metrics = printedMetrics(doc)
        let baseFont = courier(size: CGFloat(metrics.size))
        let annotated = annotatedLayout(doc)
        let pages = docToPagelines(doc, printed: true)
        // Every REAL line's own engine `PageLine` (lead/overprint/spans), in document
        // order, and which `pages` index it came from — `flatLines[n]` and
        // `flatPageIndex[n]` describe the SAME real line `pages` itself already produced.
        let flatLines: [PageLine] = pages.flatMap { $0 }
        var flatPageIndex: [Int] = []
        flatPageIndex.reserveCapacity(flatLines.count)
        for (pi, page) in pages.enumerated() { flatPageIndex.append(contentsOf: Array(repeating: pi, count: page.count)) }

        func paragraphStyle(lead: Double) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = CGFloat(lead)
            style.maximumLineHeight = CGFloat(lead)
            style.lineBreakMode = .byClipping
            return style
        }
        // Job 267 (field bug 3, mark wrapping): a line whose marks make it wider than the
        // page — POWERUSE.WS's `^T` comment, FORMFEED.WS's own `^T` reference block — must
        // wrap within the margins like real text instead of clipping (today's `paragraphStyle`
        // above) or overflowing past the right margin uncontained. `minimumLineHeight ==
        // maximumLineHeight` still pins every WRAPPED row to the SAME lead grid a clipped line
        // uses, so a 3-row wrapped mark line costs exactly 3 ordinary rows of budget/page
        // space — "counting marks as real lines" per the reflow ruling, extended to a mark
        // that itself spans several visual rows. No `\n` is ever inserted at a wrap point —
        // wrapping is AppKit's own visual line-breaking of ONE paragraph, never a new
        // character — so `endMark`'s own ↵/¶ glyph (appended once, after the LAST span) can
        // never appear anywhere but the paragraph's true end, matching "wrap points show no
        // ↵ icon" exactly by construction, not by suppressing anything.
        func wrapParagraphStyle(lead: Double) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = CGFloat(lead)
            style.maximumLineHeight = CGFloat(lead)
            style.lineBreakMode = .byWordWrapping
            return style
        }
        func naturalParagraphStyle() -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            return style
        }
        let defaultParagraph = paragraphStyle(lead: metrics.lead)
        let naturalParagraph = naturalParagraphStyle()
        let textWidth = max(1, metrics.pageWidth - metrics.left)
        // A line "needs" wrap protection when it can carry a mark wide enough to overflow —
        // every fabricated line (dot-command/comment-only, `endMark == nil`) is ALL marks by
        // definition, and a real line needs it exactly when annotating it inserted at least
        // one non-`.visible` span (a style toggle, or a comment beside its reference) that
        // could push its total width past the margin the plain render never had to survive.
        // An ordinary real line with no marks at all renders identically to the plain path
        // either way (its own text already fits, proven by the untouched OFF-state parity
        // gates), so leaving it clipped is both safe and avoids re-measuring every line in
        // the document for nothing.
        func lineNeedsWrap(_ line: AnnotatedLine) -> Bool {
            guard line.endMark != nil else { return true }
            return line.spans.contains { span in
                if case .visible = span.kind { return false }
                return true
            }
        }
        // How many visual rows AppKit actually gives `content` at the page's own text width —
        // measured the same "lay it out unbounded, count real fragments" way `isolatedLineLayout`
        // does, so this NEVER guesses a number `buildExplicitPages`' own later real-flow
        // measurement could disagree with (that mismatch is exactly what a blank/blocked page
        // would look like — see `RenderedDocument.softLineFlags`'s own "IS that page's real
        // line count, by construction" contract).
        func rowCount(_ content: NSAttributedString) -> Int {
            guard content.length > 0 else { return 1 }
            let storage = NSTextStorage(attributedString: content)
            let manager = NSLayoutManager()
            manager.allowsNonContiguousLayout = false
            let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            var count = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
                count += 1
            }
            return max(1, count)
        }
        // Stands in for a true zero-height fragment, same trick and same value as
        // `renderPrinted`'s own `nearZeroLead` (this file's citation on that one) — an
        // overprint continuation shares its predecessor's baseline, so its OWN fragment
        // (job 256 never gave it a chain, job 257 does) must not add a visible gap.
        let nearZeroLead: Double = 0.01

        // A short, human label per invisible-ink class — "spoken prefixes via accessibility
        // attributes where cheap" (job 256's brief): carried in
        // `NSAccessibilityAnnotationTextAttribute`/`NSAccessibilityAnnotationLabel`, the real
        // AppKit mechanism for annotating a SUBRANGE of an attributed string for VoiceOver
        // (`NSAccessibilityConstants.h`'s own doc comment: "allows annotation information to
        // be conveyed") — the marks are already real, AX-readable text without this (see
        // `PagedDocumentViewAccessibilityTests`'s own established finding that `NSTextView`'s
        // accessibility value reads `NSTextStorage` directly), so this is a genuine "where
        // cheap" addition, not the mechanism that makes them readable at all.
        func spokenLabel(_ kind: InkKind) -> String {
            switch kind {
            case .visible: return ""
            case .dotCommand: return "dot command"
            case .comment: return "comment"
            case .softReturn: return "soft return"
            case .hardReturn: return "hard return"
            case .styleToggle: return "style toggle"
            case .pageBreakOrigin: return "page break"
            }
        }
        func markRun(_ text: String, font: NSFont, spoken: String, paragraph: NSParagraphStyle) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: invisibleMarkColour,
                .paragraphStyle: paragraph,
                .accessibilityAnnotationTextAttribute: [[NSAccessibility.AnnotationAttributeKey.label: spoken]],
                .invisibleMarkRun: true,
            ])
        }
        // A mark's own face — "SAME face/size as their line" (job 256's brief): every
        // `AnnotatedSpan` already carries the host run's own `font` (`AnnotatedSpan`'s own
        // doc comment: "so a viewer can size a mark like the line it sits in without
        // re-deriving the surrounding run"), so this is a direct read, never a guess.
        func markFont(_ font: FontChange?, styles: Style) -> NSFont {
            guard let font else { return styled(baseFont, with: styles) }
            return resolvedFont(for: font, styles: styles, fallback: baseFont, defaultSize: metrics.size,
                                useCourierPrime: true)
        }

        // JOB 257: `suppressVisible` blanks a line's OWN `.visible` text — used only for an
        // oversized real line's INLINE fragment, mirroring `renderPrinted`'s own
        // `content = oversized ? PageLine([], soft: base.soft) : base` — while keeping
        // every invisible mark on that same line (page-break prefix, dot-command/comment/
        // style-toggle marks, the end-of-line symbol): none of those is ever the oversized
        // glyph, they are always set at `baseFont`, so leaving them inline is always safe,
        // and it is what lets a banner line's OWN page-break annotation still show.
        func lineAttributedString(
            _ line: AnnotatedLine, paragraph: NSParagraphStyle, suppressVisible: Bool = false
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()

            // "pageBreakOrigin: faint annotation ON THE BREAK LINE" (job 256's brief) —
            // prefixed onto this same line's own content, not a separate fragment. Natural
            // overflow (`reason == .pageBreakOrigin("")`) draws nothing, per the brief's own
            // "natural = nothing".
            if case .pageBreakOrigin(let text)? = line.pageBreakBefore, !text.isEmpty {
                let label = text == "\u{0C}" ? "form feed" : text
                result.append(markRun("— \(label) —  ", font: baseFont,
                                      spoken: "page break: \(label)", paragraph: paragraph))
            }

            // One pass over `line.spans` in document order, reusing `appendSpan` — the SAME
            // per-span visible-text logic `attributedLine` runs for the plain path — for
            // every `.visible` run, and inserting a faint mark run for everything else
            // right where it sits. This is what makes a style-toggle token or a comment
            // land INLINE, beside the exact boundary/reference it annotates, rather than
            // batched separately and reordered.
            var leading = true
            for span in line.spans {
                switch span.kind {
                case .visible:
                    guard !suppressVisible else { continue }
                    // A synthetic single-span `Span`/`fonts` pair — `AnnotatedSpan.font` is
                    // already a resolved `FontChange`, not an index, so index 0 into a
                    // fresh one-entry array stands in for `Document.fonts`' role. LJ6DTP
                    // driver colour does not survive this conversion (`AnnotatedSpan` has
                    // no `colour` field) — see this function's own top doc comment.
                    let syntheticFonts: [FontChange] = span.font.map { [$0] } ?? []
                    let synthetic = Span(text: span.text, styles: span.style,
                                         font: syntheticFonts.isEmpty ? nil : 0)
                    appendSpan(synthetic, to: result, leading: &leading, font: baseFont,
                              paragraph: paragraph, fonts: syntheticFonts, defaultSize: metrics.size,
                              colourMap: [:], disableKerning: true, useCourierPrime: true)
                case .dotCommand, .comment, .styleToggle:
                    let font = markFont(span.font, styles: span.style)
                    result.append(markRun(span.text, font: font,
                                          spoken: "\(spokenLabel(span.kind)): \(span.text)", paragraph: paragraph))
                case .softReturn, .hardReturn, .pageBreakOrigin:
                    // Line-level marks (`endMark`/`pageBreakBefore`), never an
                    // `AnnotatedSpan`'s own `kind` — unreachable per `annotatedLayout`'s own
                    // construction (`AnnotatedLayout.swift`), kept only for switch
                    // exhaustiveness.
                    break
                }
            }

            // "soft/hard end-of-line marks... inline after the last character" (job 256's
            // brief) — `endMark` is the LINE's own property, appended once, after every span.
            if let endMark = line.endMark {
                let symbol = endMark == .softReturn ? "↵" : "¶"
                result.append(markRun(symbol, font: baseFont, spoken: spokenLabel(endMark), paragraph: paragraph))
            }

            // Same "blank line needs a real glyph to sit its baseline on the grid" trick
            // `attributedLine` itself uses (see that function's own doc comment) — a
            // fabricated page-break-only line with an empty reason, a genuinely blank body
            // line, or an oversized line with its own visible text suppressed, would
            // otherwise be nothing but its own terminator newline.
            if result.length == 0 {
                result.append(NSAttributedString(string: " ", attributes: [
                    .font: baseFont, .paragraphStyle: paragraph, .foregroundColor: NSColor.black,
                ]))
            }
            return result
        }
        func lineAndTerminator(
            _ line: AnnotatedLine, lead: Double, suppressVisible: Bool = false, wrap: Bool = false
        ) -> NSAttributedString {
            let paragraph = wrap ? wrapParagraphStyle(lead: lead) : paragraphStyle(lead: lead)
            let piece = NSMutableAttributedString(attributedString:
                lineAttributedString(line, paragraph: paragraph, suppressVisible: suppressVisible))
            piece.append(lineTerminator(font: baseFont, paragraph: paragraph))
            return piece
        }
        // Job 227's own natural (unbounded) pass, ported: an `.overprint` continuation's
        // full content, or an oversized base line's TRUE content for its self-pass — always
        // the SAME annotated marks a normal fragment would carry, never suppressed.
        func naturalPass(_ line: AnnotatedLine) -> NSAttributedString {
            lineAttributedString(line, paragraph: naturalParagraph)
        }

        // Pair every REAL (`endMark != nil`) annotated line with its own index into
        // `flatLines`, in order — `annotatedLayout`'s own construction interleaves real
        // lines with fabricated ones (dot-command lines; the blank page-marker placeholder)
        // in exactly the same relative order `resolvePlainBody`/`docToPagelines` produced
        // the real ones, so a running counter correlates them with no ambiguity... EXCEPT
        // when `doc` has placeable notes: `docToPagelines` then routes through
        // `layoutPrintedPages`, the footnote/endnote-aware paginator, whose page-bottom
        // area interleaves REAL footnote-text `PageLine`s that `annotatedLayout` never
        // represents at all (it only ever surfaces a `.comment`-kind note as an inline
        // span beside its reference, `AnnotatedLayout.swift`'s own `refNotes` handling —
        // never a footnote's own body text) — `flatLines.count` then exceeds the real
        // annotated-line count and a naive running counter walks past the end of
        // `flatLines`. `annotatedLayout` already draws this same line itself for its own
        // natural-overflow detection ("the notes-aware paginator's page-bottom area growth
        // has no line-for-line correlation back to the source Lines this pass can cheaply
        // reconstruct, and misreporting a break is worse than omitting one") — `CtrlKD
        // .hasPlaceableNotes` isn't public, so this checks the same fact the direct way:
        // if the two counts disagree, there IS no correlation, full stop. Every real line
        // then falls back to job 256's simpler behaviour (uniform default lead, no
        // `.overprint` chain, no oversized detection, running heads matched by page INDEX
        // instead of by position) rather than crash or silently mismatch indices.
        // `wrapEligible`: precomputed per unit, purely LOCAL facts (never depends on page
        // position or neighbors) so it is safe to compute once here and trust in both the
        // budget walk and the render loop below. A fabricated unit is always eligible
        // (`lineNeedsWrap` is unconditionally true for one). A real unit is eligible only when
        // it needs wrap protection AND is not `.overprint` — an overprint line shares its
        // successor's baseline (job 224's chain) and a wrapped multi-row fragment has no
        // "successor shares this baseline" concept, so wrapping stays off for those, exactly
        // like an OVERSIZED real line stays off (its own self-pass/inline-suppress mechanism,
        // job 227, already assumes one fragment). Both exclusions are the SAME "don't touch
        // the two existing per-line compositing mechanisms" boundary this job's bug 1 fix
        // drew for the very same reason.
        struct Unit { let line: AnnotatedLine; let flatIndex: Int?; let wrapEligible: Bool }
        let realLineCount = annotated.lines.lazy.filter { $0.endMark != nil }.count
        let correlatable = realLineCount == flatLines.count
        var units: [Unit] = []
        units.reserveCapacity(annotated.lines.count)
        var realCounter = 0
        for line in annotated.lines {
            if line.endMark != nil {
                let fi = correlatable ? realCounter : nil
                let eligible: Bool
                if let fi, lineNeedsWrap(line) {
                    let flat = flatLines[fi]
                    let assignedLead = flat.lead ?? metrics.lead
                    eligible = !flat.overprint && !Self.lineExceedsFragment(
                        flat, assignedLead: assignedLead, fallback: baseFont,
                        fonts: doc.fonts, defaultSize: metrics.size, useCourierPrime: true)
                } else {
                    eligible = false
                }
                units.append(Unit(line: line, flatIndex: fi, wrapEligible: eligible))
                realCounter += 1
            } else {
                units.append(Unit(line: line, flatIndex: nil, wrapEligible: true))
            }
        }

        // JOB 267 (field bug 2, the reflow ruling — supersedes job 257's "additive only"
        // approach): job 257 forced a break at EVERY `pageBreakBefore` marker, including a
        // NATURAL-overflow one (`.pageBreakOrigin("")`, `AnnotatedLayout.swift`'s own retrofit
        // of the PLAIN document's own budget-exhaustion point). That boundary was correct for
        // the plain line count it was computed from, but once mark lines add extra content
        // BEFORE it, the marked-up page runs out of room earlier — forcing a break at the old
        // (now-arbitrary) plain-document boundary anyway is exactly what produced blank/near-
        // empty pages and marooned dot-line-only pages (Jon: "Show Invisibles needs to reflow
        // text. That includes PAGE BREAKS... RE-PAGINATE the marked-up stream FROM SCRATCH").
        // Only an EXPLICIT origin (`.pa`/`.cp`/a real form feed — non-empty reason text) is an
        // authorial decision and still forces a break exactly where the engine put it; a
        // natural-empty reason is discarded as a FORCING signal (its own annotation already
        // draws nothing either way, job 256's "natural = nothing" rule) and breaks are instead
        // decided purely by the SAME points budget `layoutPrintedPagesPlain` walks
        // (`(capacity - 1) * defaultLead`), one annotated line at a time exactly like that
        // function's own `.line` case — first unit on a page is free, a unit right after a
        // real overprint line is free (it shares that line's baseline), everything else
        // spends its own lead (a real line's `.lh`-aware `flatLines[n].lead`, or the
        // document default for a fabricated mark line, which has no `.lh` of its own).
        // A `.cpN` reason (`explicitBreakReason`'s own `.condpage` case, `AnnotatedLayout
        // .swift`) is CONDITIONAL by WordStar's own definition — "break only if fewer than N
        // lines remain on the current page" — not an unconditional author decision like `.pa`/
        // a form feed. `annotatedLayout` bakes the condition's OUTCOME for the PLAIN document
        // into the reason it attaches (the block exists in the IR regardless of which way the
        // condition went), so treating ANY non-empty reason as an unconditional force — as job
        // 257 did, and as this job's own first attempt still did — re-forces a `.cp2`/`.cp4`
        // break that only held true for the PLAIN page's own remaining room. Once mark lines
        // change how much of the current page is already spent, the SAME conditional command
        // can find MORE room free (the marks all landed on an earlier page) and should NOT
        // break at all — exactly the discrepancy that produced OLDTIMES.WS's own near-empty
        // page 2 (a `.cp4` forced a break with 44 of 54 lines still unspent). Re-evaluate the
        // condition against THIS reflow's own remaining budget instead of trusting the reason
        // string's mere presence; `.pa`/a real form feed carry no numeric threshold and stay
        // unconditional, matching Jon's own "or a real page-break origin" carve-out.
        func conditionalThreshold(_ text: String) -> Int? {
            let upper = text.uppercased()
            guard upper.hasPrefix(".CP") else { return nil }
            return Int(upper.dropFirst(3))
        }
        // Job 267 (field bug 3, mark wrapping): how many visual rows each unit actually
        // costs — 1 for everything not `wrapEligible`, or AppKit's real wrapped-fragment
        // count for a unit that is. Row count is a function of WIDTH/glyphs only, never of
        // the lead (row HEIGHT) a fragment is later assigned, so measuring every eligible
        // unit ONCE here with a fixed reference lead is exactly what render time's own,
        // possibly different, per-unit lead will still produce — computed up front so the
        // budget walk below can charge a wrapped unit its TRUE cost ("counting marks as real
        // lines" extended to a mark spanning several rows) instead of silently under-costing
        // it by 1 and drifting the same way an un-reflowed natural break did (field bug 2).
        var unitRows: [Int] = []
        unitRows.reserveCapacity(units.count)
        for unit in units {
            guard unit.wrapEligible else { unitRows.append(1); continue }
            let content = lineAttributedString(unit.line, paragraph: wrapParagraphStyle(lead: metrics.lead))
            unitRows.append(rowCount(content))
        }
        let budget = Double(metrics.capacity - 1) * metrics.lead
        func shouldForceBreak(_ reason: InkKind?, spent: Double) -> Bool {
            guard case .pageBreakOrigin(let text)? = reason, !text.isEmpty else { return false }
            guard let n = conditionalThreshold(text) else { return true }
            let remaining = budget - spent
            return remaining < Double(n) * metrics.lead - 1e-6
        }
        var pageStarts: [Int] = [0]
        var spent = 0.0
        var pageEmpty = true
        var previousWasOverprint = false
        for i in 0..<units.count {
            let unit = units[i]
            if i > 0, shouldForceBreak(unit.line.pageBreakBefore, spent: spent) {
                pageStarts.append(i)
                spent = 0
                pageEmpty = true
                previousWasOverprint = false
            }
            // Job 267 (field bug 3): `unitRows[i]` rows total, only the FIRST of which can
            // ever be free (first-on-page, or sharing an overprint predecessor's baseline) —
            // every row after that is a genuinely new row this unit's own wrap produced and
            // always spends its own lead, regardless of position. `rows == 1` (everything not
            // `wrapEligible`) collapses this back to job 257's original two-branch formula
            // exactly.
            let ownLead = unit.flatIndex.map { flatLines[$0].lead ?? metrics.lead } ?? metrics.lead
            func rowsCost(pageEmpty: Bool, previousWasOverprint: Bool) -> Double {
                let freeRows = (pageEmpty || previousWasOverprint) ? 1 : 0
                return Double(max(0, unitRows[i] - freeRows)) * ownLead
            }
            let rawCost = rowsCost(pageEmpty: pageEmpty, previousWasOverprint: previousWasOverprint)
            if !pageEmpty, spent + rawCost > budget + 1e-6 {
                pageStarts.append(i)
                spent = 0
                pageEmpty = true
                previousWasOverprint = false
            }
            let cost = rowsCost(pageEmpty: pageEmpty, previousWasOverprint: previousWasOverprint)
            spent += cost
            pageEmpty = false
            previousWasOverprint = unit.flatIndex.map { flatLines[$0].overprint } ?? false
        }

        // Rendering: one pass per page range, chaining consecutive real `.overprint` units
        // into one fragment (job 224's mechanism, ported) and routing an oversized real
        // line (job 227's mechanism) through a blanked inline fragment plus a natural self-
        // pass — reusing `lineExceedsFragment` directly against the REAL `PageLine` so the
        // decision matches the plain path exactly.
        let output = NSMutableAttributedString()
        var softLineFlags: [[Bool]] = []
        var overprintPasses: [[[NSAttributedString]]] = []
        var oversizedSelfPasses: [[NSAttributedString?]] = []
        var runningLines: [[RunningLine]] = []
        var realPageIndexByPage: [Int] = []
        let startNo = doc.page?.pnStart ?? 1
        var currentRealPageIndex = 0
        // Hoisted out of the per-line loop below (job 267): a function of `baseFont`/
        // `defaultParagraph`/`metrics` only, identical to what this function used to compute
        // once at the very end for `RenderedDocument.baselineOffset` — needed INSIDE the loop
        // now too, for an oversized line's own extra-height math (see that call site's
        // doc comment), so it is measured once, up here, and reused both places.
        let normalBaselineOffset = firstBaselineOffset(
            font: baseFont, paragraph: defaultParagraph,
            width: max(1, metrics.pageWidth - metrics.left))

        for (groupIndex, start) in pageStarts.enumerated() {
            let end = groupIndex + 1 < pageStarts.count ? pageStarts[groupIndex + 1] : units.count
            let pageChunk = NSMutableAttributedString()
            var flags: [Bool] = []
            var passes: [[NSAttributedString]] = []
            var selfPasses: [NSAttributedString?] = []
            var k = start
            var isFirstFragment = true
            while k < end {
                let unit = units[k]
                if let fi = unit.flatIndex {
                    currentRealPageIndex = flatPageIndex[fi]
                    // The chain runs while each member is itself `overprint` — its
                    // successor shares ITS baseline too (see `renderPrinted`'s own doc
                    // comment on this exact loop). A mark line or a fresh page break both
                    // end the chain, same as a real line simply not being overprint does.
                    var m = k
                    while let curFi = units[m].flatIndex, flatLines[curFi].overprint,
                          m + 1 < end, units[m + 1].flatIndex != nil, units[m + 1].line.pageBreakBefore == nil {
                        m += 1
                    }
                    let baseFlat = flatLines[fi]
                    let lead: Double = isFirstFragment ? metrics.lead
                        : ((k > start && (units[k - 1].flatIndex.map { flatLines[$0].overprint } ?? false))
                            ? nearZeroLead : (baseFlat.lead ?? metrics.lead))
                    let oversized = Self.lineExceedsFragment(
                        baseFlat, assignedLead: lead, fallback: baseFont, fonts: doc.fonts, defaultSize: metrics.size,
                        useCourierPrime: true)
                    // Job 267 (field bug 1, .h1/title collision): an oversized line's OWN
                    // fragment grows past `lead` by whatever `oversizedClearanceBelowBaseline`
                    // says its self-pass needs below its target baseline — the self-pass
                    // baseline is anchored to THIS fragment's own TOP (`fragmentOrigin.y +
                    // rendered.baselineOffset`, `PagedDocumentView.drawOversizedSelfPasses`),
                    // never to its bottom, so growing this fragment cannot move that baseline;
                    // it only pushes every fragment AFTER this one further down, which is
                    // exactly the clearance the reflow needs before whatever comes next —
                    // real content or a fabricated dot-command/comment mark alike. On the real
                    // facsimile (Invisibles off), which never inserts a fabricated line here,
                    // the author's own next line already sat far enough away for this same
                    // bleed not to matter, so `renderPrinted` carries no equivalent — this is
                    // scoped to `renderPrintedAnnotated` alone, a screen-only reflow surface,
                    // so it cannot perturb OFF-state pagination or `emitPDF` parity.
                    let fragmentLead: Double
                    if oversized {
                        let clearance = Self.oversizedClearanceBelowBaseline(
                            baseFlat, fallback: baseFont, fonts: doc.fonts, defaultSize: metrics.size,
                            useCourierPrime: true)
                        fragmentLead = lead + max(0, normalBaselineOffset + clearance - lead)
                    } else {
                        fragmentLead = lead
                    }
                    // Job 267 (field bug 3): `unit.wrapEligible` already excludes an
                    // `.overprint`/oversized real line (see `Unit`'s own doc comment), so `m
                    // == k` always here when it's true — wrapping never has to interact with
                    // the chain walk above. `unitRows[k]` real rows now land in the SAME
                    // single `pageChunk.append` (AppKit wraps the ONE paragraph on its own,
                    // job 267's `wrapParagraphStyle` doc comment), but `flags`/`selfPasses`/
                    // `passes` must still gain one entry per ACTUAL fragment it produces —
                    // `RenderedDocument.softLineFlags`'s own contract ("IS that page's real
                    // line count, by construction") — or every later index on this page
                    // misaligns against `PagedDocumentView.buildExplicitPages`' real probe.
                    // Continuation rows carry no soft-return glyph, self-pass, or overprint
                    // pass of their own — those all belong to the paragraph's ONE logical
                    // line, already drawn on its first row.
                    pageChunk.append(lineAndTerminator(
                        unit.line, lead: fragmentLead, suppressVisible: oversized, wrap: unit.wrapEligible))
                    flags.append(unit.line.endMark == .softReturn)
                    selfPasses.append(oversized ? naturalPass(unit.line) : nil)
                    passes.append(k == m ? [] : (k + 1...m).map { naturalPass(units[$0].line) })
                    if unit.wrapEligible {
                        for _ in 1..<unitRows[k] {
                            flags.append(false)
                            selfPasses.append(nil)
                            passes.append([])
                        }
                    }
                    k = m + 1
                } else {
                    pageChunk.append(lineAndTerminator(unit.line, lead: metrics.lead, wrap: true))
                    flags.append(unit.line.endMark == .softReturn)
                    selfPasses.append(nil)
                    passes.append([])
                    for _ in 1..<unitRows[k] {
                        flags.append(false)
                        selfPasses.append(nil)
                        passes.append([])
                    }
                    k += 1
                }
                isFirstFragment = false
            }
            output.append(pageChunk)
            softLineFlags.append(flags)
            overprintPasses.append(passes)
            oversizedSelfPasses.append(selfPasses)
            // Not correlatable (a placeable-notes document, see `units`' own doc comment):
            // no real-position mapping exists, so fall back to job 256's original
            // approximation, matching a local page to `pages` BY INDEX.
            let realPageIndex = correlatable ? currentRealPageIndex : groupIndex
            realPageIndexByPage.append(realPageIndex)
            runningLines.append(pages.indices.contains(realPageIndex)
                ? Self.runningLines(for: pages[realPageIndex], pageNo: startNo + realPageIndex,
                                    doc: doc, metrics: metrics)
                : [])
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        // Same geometry formulas `renderPrinted` uses (see that function's own extensive
        // citations on `firstBaseline`/`normalBaselineOffset`/`textTop`) — a function of
        // `metrics`/`state.pageSize` only, never of page CONTENT, so it applies unchanged
        // to this function's differently-grouped pages.
        var pageSize = CGSize(width: metrics.pageWidth, height: metrics.pageHeight)
        if state.pageSize.provenance == .manual, let manual = state.pageSize.value {
            pageSize = manual.sizeInPoints
        }
        let firstBaseline = metrics.top + Double(metrics.size)
        // `normalBaselineOffset` is now computed once, up front, before the render loop
        // (see that computation's own job 267 doc comment) — reused here unchanged.
        let textTop = max(0, firstBaseline - normalBaselineOffset)
        let textFrame = CGRect(
            x: metrics.left, y: textTop,
            width: max(1, metrics.pageWidth - metrics.left),
            height: CGFloat(metrics.capacity) * metrics.lead
        )
        // Job 425: this path's `pinnedBaselines` is always empty by construction (see
        // `NSLayoutManagerDelegate`'s own "Modern style and the Show Invisibles screen path
        // both hand back an EMPTY dictionary" citation, `PagedDocumentView.swift`) — the
        // per-page real-anchor fix `renderPrinted` needed for its own `leadingHeadroom` call
        // does not apply here (there is no pin to correct), so every page keeps the SAME
        // flat nominal anchor this path always used. Not a per-page regression: unchanged
        // from before this job.
        let leadingHeadroom = Self.leadingHeadroom(
            oversizedSelfPasses, firstBaselines: Array(repeating: firstBaseline, count: oversizedSelfPasses.count))

        return RenderedDocument(
            text: output,
            pageSize: pageSize,
            textFrame: textFrame,
            pageCount: max(1, pageStarts.count),
            clipsLines: true,
            softLineFlags: softLineFlags,
            overprintPasses: overprintPasses,
            oversizedSelfPasses: oversizedSelfPasses,
            baselineOffset: normalBaselineOffset,
            leadingHeadroom: leadingHeadroom,
            runningLines: runningLines,
            // Printed-annotated's own real pages are known here already, same as plain
            // Printed — see that call site's own comment on why job 393's Modern-only fields
            // are empty here.
            hfEvents: [],
            pageNumberStart: startNo,
            realPageIndexByPage: realPageIndexByPage,
            // Job 412: Show Invisibles is a screen-only path no structural-parity gate
            // measures — left exactly as AppKit lays it out, same as before this job.
            pinnedBaselines: [:],
            // Job 427: Show Invisibles is exempt from the geometry-parity law (Jon's own
            // scope fence: "a visual information layer that reflows BY DESIGN") — one
            // flat, shared anchor per page, matching `pinnedBaselines`'s own emptiness here.
            perPageTextTop: Array(repeating: Double(textFrame.origin.y), count: max(1, pageStarts.count)),
            pinnedPageBottoms: [],
            // Printed-annotated has no screenplay-marker concept either — same reason as
            // plain Printed's own call site.
            modernForcedPageBreakOffsets: [],
            // Same reason as plain Printed's own call site.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            pclPrograms: doc.pclPrograms
        )
    }

    // MARK: - Modern

    /// Reflow for reading: fixed 1in margins on the app's page, the user's font and size —
    /// but the document's OWN font identity and paragraph structure, not one flat body font
    /// (job 263, Jon's field report: OLDTIMES's title/author/citations were all falling
    /// back to plain body text with only char-level bold/italic surviving).
    ///
    /// Modern deliberately does NOT reproduce the original page — that is Printed's job.
    /// AppKit does the wrapping here (that is the point), so lines are logical, not
    /// physical: `modernSemanticFlow` (`CtrlKD/Layout.swift`) has ALREADY undone WordStar's
    /// own word wrap, editor-time alignment spaces and `.lm`/`.rm` margin stamping — it is
    /// the engine's own words "the single implementation of the M-rules", the SAME model
    /// `PDFModernLayout.swift` (PDF), `EmitRTF.swift`, and `EmitHTML.swift` measure into
    /// their own surfaces. This function is the app's fourth consumer: convert the shared
    /// semantic items straight to AppKit paragraph/font attributes, never re-derive
    /// alignment/indent/style structure from `doc.blocks` by hand the way the flat
    /// `mergedLines`-only version this replaced did.
    ///
    /// ## Font identity, size hierarchy, and the body/heading reconciliation rule
    ///
    /// A run carrying a WS5+ font block (`SemanticRun.font`, non-`nil`) resolves through
    /// `resolvedFont`/`printedResolvedMacFont` below — the SAME MAC-target mapping table
    /// (`printedMacFontRows`, mistake-registry #24, job 240's MAC VIEWING RULING) Printed
    /// already uses, e.g. OLDTIMES's Aachen title resolves to Rockwell, Univers to Helvetica
    /// Neue — at THAT run's own declared point size (`FontChange.points`), which is exactly
    /// the field `fontControlRTF` reads for the RTF stylesheet's `\fsNN`, so a styled run's
    /// size here matches the RTF export's by construction, not by copying a number. A run
    /// with NO font block (plain body prose) falls through `resolvedFont`'s own existing
    /// fallback to `bodyFont` — the user's Settings "Modern font/size"
    /// (`SettingsStore.defaultFontName`/`.fontSizes`, the Georgia-14-body ruling).
    ///
    /// The reconciliation: body copy renders in the user's chosen face/size; the document's
    /// own styled runs (title/byline/citation/quote/etc.) keep their ABSOLUTE face and size
    /// from the file's own structure — bold/larger/centered exactly as the RTF stylesheet
    /// has them — rather than being rescaled relative to whatever face the user picked for
    /// body text. This is `resolvedFont`'s pre-existing architecture (job 202/240, Printed)
    /// applied unchanged to Modern, not a new rule invented for this job.
    /// `.lm`/`.rm` block margins arrive as WordStar print COLUMNS (`SemanticItem.para`'s
    /// own contract); a modern column is the document's own `.cw` (default 12, 10 CPI)
    /// at 0.6pt/char — the SAME conversion `PDFModernLayout.modernFlow`'s `colPt` uses
    /// for the PDF Modern path, ported here since the module docstring's own contract is
    /// "each consumer converts with its own metrics" (columns are deliberately unitless
    /// in the shared model).
    private static func modernColPt(_ doc: Document) -> Double {
        (doc.page?.cw120 ?? 12.0) * 0.6
    }

    /// b28 note 7 (Jon's ruling, verbatim): "The look of our notes in Modern: 1. Footnoote.
    /// and i. Endnote. No brackets. No superscript... The note marker in the text should
    /// still be superscript." This only reformats the trailing APPENDIX entry
    /// (`appendNoteLine`'s callers) — the in-text reference marker is a separate `SemanticRun`
    /// carrying its own `.sup` style bit, set upstream and rendered through `attributedLine`'s
    /// span processing, never touched here. `label`/`row.shown` (`shownLabels`,
    /// `Layout.swift`) are already bare (`"1"`, `"i"` via `endnoteRomanLabel`, `"c1"` for
    /// comments) with no trailing punctuation — the `hasSuffix` guard is defensive, so a
    /// future label scheme that already carries its own period never doubles it into `"1.."`.
    private static func modernNoteEntryLabel(_ label: String) -> String {
        label.hasSuffix(".") ? label : label + "."
    }

    /// `hangCols`, when given, opens a HANGING indent (M-rules addendum, structure rows
    /// only): the first line sits at `indentCols`, every WRAPPED line at
    /// `indentCols + hangCols` — a def-list label or bullet marker is only ever on line
    /// one, so its continuation hangs under the body text instead of repeating under the
    /// marker. `nil` (every pre-existing caller) keeps first-line and wrapped lines at
    /// the SAME column, unchanged from before job 299.
    ///
    /// `hangPt`, when given, opens the SAME hanging indent but measured in real points
    /// past `indentCols` rather than WordStar print columns — job 329/b21, Jon's field
    /// note on VERSIONS.WS's Sawyer-customizations bullets: "the line wrap doesn't line
    /// up with the first line after the • bullet." `hangCols`' column-based math assumes
    /// a monospace cell (`colPt`, the document's own `.cw`), but a bullet's "• " marker
    /// renders in Modern's own PROPORTIONAL body font — its real advance width almost
    /// never lands on a whole number of `colPt`-wide cells, so the fixed `hangCols: 2`
    /// this used to pass drifted from the actual glyph. `hangPt` takes precedence over
    /// `hangCols` when both are given (no caller passes both).
    ///
    /// Shared by `renderModern` and `renderModernAnnotated` (job 300) — Show Invisibles
    /// must never compute its own paragraph geometry, or the two views can drift the way
    /// Jon's b16 field report caught (centering lost, ladder collapsed, when ON).
    /// Job 371 item 5 (VERSE SPACING IN VIEWS, RULINGS-LEDGER item 4): `EmitRTF`/`EmitHTML`
    /// both tighten a centered/verse-classified unit's own internal line spacing — "poetry
    /// and centered material... conventionally sets SINGLE-spaced internally regardless of
    /// the surrounding prose's own spacing" (`FontMap.swift`'s own citation).
    ///
    /// Job 395 (391 root cause 4) — THE FIX: job 371's predecessor here
    /// (`modernVerseLineHeight`, 1.15) was applied as `NSParagraphStyle.lineHeightMultiple`
    /// UNCHANGED from `EmitHTML.swift`'s own `line-height:1.15` — but that HTML number only
    /// reads as tight relative to CSS's own explicit, loose ambient (`htmlCSS`'s body
    /// shorthand `"14pt/1.6 Georgia..."` — 1.15 is tighter than THAT page's own 1.6
    /// default). AppKit's plain (non-tight) paragraph here sets NO line-height override at
    /// all (see below) — its own "1.0" baseline is already the tight, natural font-metric
    /// height, not a loose ambient the way HTML's page default is — so multiplying that
    /// ALREADY-tight AppKit baseline by 1.15 unchanged made verse ~15% TALLER than prose,
    /// precisely inverted (Jon's field report on 391: OLDTIMES's award blocks/stanzas
    /// "aren't any tighter"). Two absolute-geometry alternatives were tried and rejected
    /// empirically before this one: `NSParagraphStyle.minimumLineHeight` (RTF's own
    /// `\sl`-positive convention, `rtfVerseTightSlTwips`'s doc comment) is a FLOOR — it
    /// can only ever raise an already-small line, never tighten a bigger one, so it would
    /// be silently inert for ordinary body text. A fixed absolute `maximumLineHeight` PORT
    /// of `rtfVerseTightSlTwips()`'s own points (`verseLineHeight`(1.15) *
    /// `modernBodySize`(14) = 16.1pt, `FontMap.swift`/`EmitRTF.swift`) was ALSO measured
    /// inert: AppKit's own natural single-line height for the app's default Modern body
    /// font (Georgia 14, `SettingsStore.defaultFontName`/`.modernFontSize`) is ~16.0pt via
    /// `NSLayoutManager`'s real laid-out line fragments — already AT that ceiling, so it
    /// never engaged (measured directly building this fix; see
    /// `VerseSpacingInViewsTests.verseRendersTighterThanProseSameFontSize`, which is what
    /// caught it). The only mechanism that reliably tightens ANY font's line height below
    /// its own natural metric, unconditionally, is a RELATIVE multiplier below 1.0 — the
    /// SAME property (`lineHeightMultiple`) the predecessor fix already used, just with the
    /// CORRECT number: `EmitHTML.swift`'s own two explicit literals, ported as a RATIO
    /// rather than as HTML's absolute 1.15 alone — `verseLineHeight`(1.15) /
    /// htmlAmbientLineHeight(1.6) = 0.71875 — the cross-format law FontMap.swift's own
    /// comment already states ("HTML body: 1.6; RTF style/reader default is comparably
    /// loose"): verse reads tighter than the surrounding ambient by THIS ratio, in every
    /// consumer. AppKit's own natural (no-override) baseline plays HTML's "1.0-before-1.6"
    /// role here, so applying the SAME ratio directly against AppKit's own natural is the
    /// faithful translation — not a re-guess, both source numbers are pinned literal ports
    /// (same situation `DocumentPictures.resolve`'s own header explains for PIX resolution
    /// — CtrlKD's own constants are `internal`, no product to import them from).
    static let modernVerseTightLineHeightMultiple: CGFloat = 0.71875

    private static func modernParagraphStyle(
        colPt: Double, size: CGFloat, align: Alignment, indentCols: Double, cutCols: Double,
        hangCols: Double? = nil, hangPt: Double? = nil, tight: Bool = false
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // A little air between paragraphs; Modern is a reading view, not a facsimile.
        // Neither the engine's own RTF stylesheet nor the semantic flow defines a
        // space-before figure (`rtfStylesheet` emits only qc/qr/qj, li/ri, b/i/ul/
        // strike, fs) — this constant is this app's own, unchanged from before job 263.
        paragraph.paragraphSpacing = size * 0.35
        paragraph.alignment = modernNSAlignment(align)
        // `tight`: the SAME condition's centered half `EmitRTF.swift`/`EmitHTML.swift`
        // check (`isVerse || block.align == .center`) — every centered paragraph (a
        // detected/tagged centered row, OR an explicit `.oc` block) tightens here.
        // b24 completion (C1): the non-centered "verse" half is no longer a gap —
        // `modernSemanticFlow`'s `SemanticItem.para` now carries the engine's own
        // `isVerse` verdict per line (`Layout.swift`, computed with the SAME
        // `assembleParagraphUnits`/`looksLikeVerse` formula `EmitRTF`/`EmitHTML` use),
        // so this function's plain-paragraph caller passes it straight through instead
        // of re-deriving paragraph units itself — the shared-API discipline
        // `resolveFont` already established, not a reimplementation.
        // A plain (non-tight) paragraph sets no override at all here — its baseline IS
        // AppKit's own natural font-metric line height, not a silent guess. `tight`
        // multiplies THAT baseline down (never up — see `modernVerseTightLineHeightMultiple`'s
        // own doc comment for why a floor/ceiling against an absolute point value can't
        // reliably tighten here the way a relative multiplier does).
        if tight { paragraph.lineHeightMultiple = modernVerseTightLineHeightMultiple }
        let firstIndent = indentCols * colPt
        let hangIndent: Double
        if let hangPt {
            hangIndent = firstIndent + hangPt
        } else {
            hangIndent = hangCols.map { (indentCols + $0) * colPt } ?? firstIndent
        }
        if firstIndent > 0 || hangIndent > 0 {
            // Applies to every wrapped line of the paragraph, not just its first —
            // WordStar's `.lm` indents the whole block uniformly (the double-indent
            // quote styles this job's brief names), unlike a prose first-line indent.
            paragraph.firstLineHeadIndent = firstIndent
            paragraph.headIndent = hangIndent
        }
        let cut = cutCols * colPt
        if cut > 0 { paragraph.tailIndent = -cut }
        return paragraph
    }

    /// b27 item 8: a box-drawing/cp437-graphic row must never offer AppKit's word-wrap a
    /// break INSIDE it, or the row's borders tear onto separate visual lines (Jon's field
    /// report on `BOXES.WS`'s first box in Modern — "open top-right corner, a stray
    /// interior vertical, missing right side"). Reproduced directly: at Modern's real
    /// 468pt text width, `BOXES.WS`'s plain 80-column border row (`┌────...────┐`, NO
    /// space characters anywhere in it) still split into 2 line fragments — AppKit's own
    /// line-breaker allows a break directly BETWEEN two adjacent box-drawing glyphs, not
    /// only at whitespace (confirmed empirically: swapping interior spaces alone, the
    /// first fix tried here, left this exact row still splitting).
    ///
    /// Port of the engine's own fix (`modernTokenize`/`_MODERN_TOK_RE`,
    /// `PDFModernLayout.swift`, b26-modern item 2, ctrl-kd 8122706) — same graphic-run
    /// boundary shape `graphicRunRanges` already names (a maximal run starting AND ending
    /// on a graphic char, with only graphic-chars-or-spaces in between). The engine hand-
    /// rolls a full tokenizer because its own PDF emitter lays out every token by hand;
    /// AppKit already has a real line-breaker, so the equivalent fix here is narrower:
    /// splice a U+2060 WORD JOINER (zero-width, explicitly a non-break per Unicode's own
    /// line-breaking algorithm) between EVERY adjacent character pair strictly inside a
    /// graphic run — the run becomes one unbreakable unit exactly as `modernTokenize`
    /// makes it one token, without a second hand-rolled layout pass, and without adding
    /// any visible glyph or width (U+2060 has no glyph and no advance in any real font).
    /// Scattered single graphic chars amid ordinary prose (a legend line like "LL: └")
    /// are unaffected for the same reason `graphicRunRanges` itself is safe there: the
    /// run must CLOSE on another graphic char, so it can never cross real letters — a
    /// lone graphic char has no adjacent pair inside its own (zero-length) run at all.
    private static func modernNoBreakGraphicRuns(_ text: String) -> String {
        guard text.contains(where: { graphicChars.contains($0) }) else { return text }
        let chars = Array(text)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            guard graphicChars.contains(chars[i]) else { out.append(chars[i]); i += 1; continue }
            var j = i
            var lastGraphic = i
            while j < n, graphicChars.contains(chars[j]) || chars[j] == " " {
                if graphicChars.contains(chars[j]) { lastGraphic = j }
                j += 1
            }
            for k in i...lastGraphic {
                out.append(chars[k])
                if k < lastGraphic { out.append("\u{2060}") }
            }
            i = lastGraphic + 1
        }
        return String(out)
    }

    /// A row that is ENTIRELY graphic content (a plain box border like `┌────...────┐`,
    /// no real prose at all) can still be wider than Modern's own text measure — AppKit's
    /// word-wrap will force a break through even a `modernNoBreakGraphicRuns`-protected
    /// run when the whole unbreakable unit exceeds the container's width (confirmed
    /// empirically: word-joining alone did not stop `BOXES.WS`'s 90-column border row
    /// from still splitting in 2). The engine's own fix keeps a graphic row as ONE
    /// unbroken block regardless — matched here by suppressing wrap ENTIRELY for a row
    /// this is true of (`.byClipping`: the row runs past the measure rather than
    /// reflowing), rather than trying to force AppKit past its own word-wrap contract.
    /// A MIXED row (real prose plus a shorter embedded graphic run, e.g. a "LL: └ LR: ┘"
    /// legend line) is untouched — it still wraps normally at its own real word
    /// boundaries, which `modernNoBreakGraphicRuns` alone already protects correctly.
    private static func isWhollyGraphicRow(_ spans: [Span]) -> Bool {
        let combined = spans.map(\.text).joined()
        guard combined.contains(where: { graphicChars.contains($0) }) else { return false }
        return combined.allSatisfy { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{2060}" || graphicChars.contains($0) }
    }

    /// b28 note 10 (Jon's field report: "line returns in the middle" on `BOXES.WS`'s legend
    /// rows — `V:   ┃`, `H:  ─`, `Mixed:  ╗  ╝`). A MIXED row (a real prose label plus one or
    /// more separate box-drawing/shade/symbol glyphs) is not WHOLLY graphic
    /// (`isWhollyGraphicRow` correctly returns false for it), so it never got `.byClipping`
    /// and stayed on the default word-wrap — which folds the row at the ordinary legal wrap
    /// point between the label and its glyph once the row exceeds `modernTextWidthPt`.
    /// `modernNoBreakGraphicRuns` only protects the space BETWEEN two adjacent graphic chars,
    /// never the space between a label and a graphic run, so it cannot fix this alone.
    ///
    /// Narrowed to "more than one graphic char" rather than "any at all"
    /// (`modernNoBreakGraphicRuns`'s own guard uses "any") specifically to avoid clipping
    /// ordinary prose that merely contains ONE incidental symbol — e.g. a Sawyer-README
    /// bullet row's own single `■` marker (`partBlocks`' own citation, "Sawyer's -README list
    /// markers") — where suppressing wrap entirely would truncate real, legitimately-wrapping
    /// content instead of fixing a legend row. Every legend row this note names carries 2+
    /// distinct graphic glyphs (or is already short enough never to wrap on its own), so this
    /// threshold catches the real defect without touching a normal bulleted paragraph.
    private static func hasMultipleGraphicChars(_ spans: [Span]) -> Bool {
        let combined = spans.map(\.text).joined()
        return combined.lazy.filter { graphicChars.contains($0) }.count > 1
    }

    /// b28 note 9 (Jon, screenshot circled in red: "THE BOXES ARE NOT CORRECT! The sides are
    /// dashed lines!"). Whether a `SemanticItem.para` payload's own runs contain at least one
    /// `graphicChars` glyph — used ONLY to detect a graphic row immediately followed by
    /// another graphic row (see the `paragraphSpacing` suppression at both `renderModern` and
    /// `renderModernAnnotated`'s call sites), never to reclassify or restyle the row itself.
    private static func paraContainsGraphicChar(_ item: SemanticItem) -> Bool {
        guard case .para(_, _, _, let runs, _, _, _, _) = item else { return false }
        return runs.contains { run in run.text.contains { graphicChars.contains($0) } }
    }

    /// The structure classification (centered / def-list / bullet ladder / plain) for one
    /// `SemanticItem.para` payload, and the paragraph style it renders under — the SAME
    /// decision either Modern view (`renderModern`, `renderModernAnnotated`) makes for the
    /// SAME item, so Show Invisibles can only ever ADD marks, never recompute layout (job
    /// 300, Jon's b16 field report: invisibles ON silently lost centering and the def-list
    /// ladder because the old `renderModernAnnotated` walked the raw `annotatedLayout`
    /// stream instead of this same classified flow).
    private static func modernParagraphContent(
        align: Alignment, indentCols: Double, cutCols: Double, runs: [SemanticRun],
        structure: RowStructure?, colPt: Double, size: CGFloat, font: NSFont, blockHangCols: Double? = nil,
        isVerse: Bool = false
    ) -> (spans: [Span], paragraph: NSMutableParagraphStyle) {
        // b34 N1 (Jon's ruling, job 529): Modern's VIEW never applied the N9 sentence-
        // spacing collapse `PDFModernLayout.swift`'s own `modernFlow` adapter applies to
        // Modern's PDF/export output (that file's own doc comment: "a consumer [...] the
        // app's native text stack) applies sentence-spacing on top, same as every other
        // `modernFlow` option that never reaches the semantic items" — this app never
        // did, so the on-screen view kept typed double spaces after a sentence-ending
        // `.`/`?`/`!` while export collapsed them to one. `resolveSentenceSpacing` isn't
        // consulted here: Modern is never "printed" (that resolves to Printed's own
        // `renderPrinted`, a different function entirely), so `.auto`'s mode-aware
        // default always resolves to single-space on screen, unconditionally, matching
        // every other view-only option this job's own family (job 520/521) already
        // leaves without a Settings override. `sentenceSpacingSpans` (Block.swift,
        // CtrlKD) is the engine's own port of `sentence_spacing_spans` — called here, not
        // reimplemented, so any future rule change (e.g. narrowing to bare `.`) lands in
        // both the view and every emitter at once. Shared by BOTH `renderModern` and
        // `renderModernAnnotated` (Show Invisibles), which both call this function for
        // their own paragraph body text.
        //
        // Applied to each branch's own FINAL rendered content below, never to this
        // `spans` array itself: `structuredPrefixAndBody` (the bullet/def branch) slices
        // its `body`/`label` by CHARACTER OFFSET, cross-referencing `structure.body`/
        // `.label`'s own COUNT — lengths the ENGINE computed from the untransformed text.
        // Collapsing a space in `spans` before that slice runs shortens the concatenated
        // text by one character without shortening `structure.body.count` to match,
        // shifting `sliceSpans`'s start left by one and pulling an extra leading
        // character (the marker/body gap space) into `body` — a real regression this job
        // hit and fixed: VERSIONS.WS's Sawyer bullet ("...can be shown.  This...", the
        // exact double space this rule targets) started rendering "•  Modifying" (two
        // spaces) instead of "• Modifying", breaking `ModernIndentLadderTests`'s own
        // wrapped-line alignment law. `centerStrippedSpans` has no such precomputed-length
        // dependency (it counts padding directly off whatever text it receives), so it is
        // unaffected either way, but the transform is still applied to its OUTPUT below
        // for the same "never feed transformed text into structural slicing" discipline.
        let spans = runs.map {
            Span(text: Self.modernNoBreakGraphicRuns($0.text), styles: $0.styles, font: $0.font, colour: $0.colour)
        }
        if let structure, structure.centered {
            // Undeclared (spaces-padded) or tag-declared centering (M-rules
            // addendum): strip the padding off the STYLED spans, same as the
            // engine's own `htmlCenteredRow` — a no-op for a real `align=center`
            // tag row (`modernSemanticFlow` already stripped that padding
            // upstream, M3), so the only real effect is on undeclared
            // spaces-only centering, which previously rendered as an ordinary
            // left-aligned paragraph with the padding baked into a proportional
            // font (STRENGTH.WS's title/byline/email).
            let renderSpans = sentenceSpacingSpans(Self.centerStrippedSpans(spans))
            let paragraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .center,
                                                       indentCols: indentCols, cutCols: cutCols, tight: true)
            if Self.isWhollyGraphicRow(renderSpans) || Self.hasMultipleGraphicChars(renderSpans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (renderSpans, paragraph)
        } else if let structure, let kind = structure.kind {
            // Def-list / bullet rows (job 299, the indent LADDER): `structure.col`
            // is the document's own absolute WordStar column — the block's `.lm`
            // plus this row's own residual indent — which is source-file trivia,
            // not a screen position. Two blocks in the SAME document can open a
            // top-level (`level == 1`) list at wildly different raw columns (job
            // 299's VERSIONS.WS: `.lm 15`, `.lm 2`, and `.lm 0` def/bullet blocks
            // all in the same file), so rendering `structure.col` directly put
            // level-1 labels at three different distances from the margin instead
            // of together at it — Jon's field report "the whole block floats far
            // right of it". `structure.level` (nesting depth, 1 = outermost) is
            // the ladder's real input: level 1 sits AT the 1in margin, and every
            // deeper level steps in by the same `levelStepCols`, regardless of
            // what raw column the source happened to use.
            let ladderIndentCols = Double(max(structure.level - 1, 0)) * Self.levelStepCols
            // The hang — where a WRAPPED continuation line lands.
            //
            // Bullet rows (job 329/b21, Jon's field note): the marker+gap
            // (`structuredPrefixAndBody`'s `"\u{2022} "`) renders in Modern's own
            // PROPORTIONAL body font, so its real advance width is measured directly
            // (`bulletMarkerWidthPt`) rather than assumed to land on a whole number of
            // `colPt`-wide monospace cells — the old fixed `hangCols: 2` drifted from
            // the actual glyph, which is what put wrapped lines slightly deeper than
            // the first line's own text start. This is a POINTS hang (`hangPt`), not a
            // columns one, precisely because it must match a real glyph, not a print
            // column.
            //
            // Def-list labels are untouched (job 322's own 2in-from-page-edge rule):
            // a label used to be measured PER ROW (job 299: `label.count + 2`), but
            // Jon's b17 field report on VERSIONS.WS caught the consequence — every row
            // in the same block wraps at a DIFFERENT column, "each line wrap seems to
            // have its own place." Job 307's fix: `defListBlockHangCols` (below)
            // precomputes ONE hang for the whole block (every def row sharing this
            // item's own contiguous run at this same nesting level), passed in as
            // `blockHangCols` — never derived from this row alone. A def-list nested
            // inside a bullet keeps this same def rule at its own deeper level.
            let hangCols: Double? = kind == .def
                ? (blockHangCols ?? Double((structure.label?.count ?? 0) + 2))
                : nil
            let hangPt: Double? = kind == .bullet ? Self.bulletMarkerWidthPt(font: font) : nil
            let (prefix, body) = Self.structuredPrefixAndBody(kind: kind, structure: structure, spans: spans)
            // N9 collapse applied to `body` ONLY, after slicing — `prefix` is the
            // synthesized "• "/label+"  " marker/gap (never user text), and the def
            // case's own literal `"  "` gap is a deliberate TWO-space structural
            // separator (`structuredPrefixAndBody`'s own doc comment) that must survive
            // even when a label happens to end in a sentence-ending character.
            let renderSpans = prefix + sentenceSpacingSpans(body)
            let paragraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                       indentCols: ladderIndentCols, cutCols: cutCols,
                                                       hangCols: hangCols, hangPt: hangPt)
            if Self.isWhollyGraphicRow(renderSpans) || Self.hasMultipleGraphicChars(renderSpans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (renderSpans, paragraph)
        } else {
            // Plain (non-structure) paragraph. Jon's b17 field report on VERSIONS.WS:
            // its intro paragraph ("In folder C:\WS, ...") sat at an arbitrary indent —
            // the document's own `.lm 16`, still active from a dot command upstream,
            // carried straight into `indentCols` even though this paragraph is no def-
            // list/bullet/quote styling, just source-file trivia (same trap as job
            // 299's `structure.col`, one level up: a WHOLE PARAGRAPH's margin instead
            // of one row's indent). Ruling: an ordinary paragraph starts at Modern's own
            // 1in margin, period — UNLESS it's a genuine two-sided block-quote style
            // (BOTH `.lm` and `.rm` narrow the measure, e.g. OLDTIMES's Copyright block,
            // `\s14` "Double-Indented Quote", job 263's own `copyrightBlockIsDouble
            // Indented` test), which keeps its declared indent on both sides. A single
            // one-sided margin with no matching cut is never a deliberate style in this
            // corpus — only a residual `.lm` left open from an earlier block.
            let isDoubleIndentQuote = indentCols > 0 && cutCols > 0
            let paragraph = Self.modernParagraphStyle(
                colPt: colPt, size: size, align: align,
                indentCols: isDoubleIndentQuote ? indentCols : 0,
                cutCols: isDoubleIndentQuote ? cutCols : 0,
                tight: align == .center || isVerse)
            if Self.isWhollyGraphicRow(spans) || Self.hasMultipleGraphicChars(spans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (sentenceSpacingSpans(spans), paragraph)
        }
    }

    /// Job 434 (b27 items 1/9): Modern's own counterpart to Native's `oversizedSelfPasses`/
    /// `leadingHeadroom` (`DocumentRenderer.swift:903-1263`, `PagedDocumentView.swift:37`) —
    /// Jon's b26 field review found a WS4 title's ascenders clipped at the top in MODERN
    /// (and separately, LJ6DTP's shadow-title first line still top-clipped in MODERN); Native
    /// had already fixed the SAME class of bug (job 396/422) but `renderModern` was always a
    /// THIRD implementation with no headroom mechanism at all — `oversizedSelfPasses: []`/
    /// `leadingHeadroom: []` below are literals, never populated.
    ///
    /// Root cause: `modernParagraphStyle`'s "tight" line-height (`modernVerseTightLineHeightMultiple`,
    /// a RELATIVE multiplier on AppKit's own NATURAL line height, applied to every centered/
    /// verse paragraph) compresses the line box below a big title font's own real ascender.
    /// For the very first line of Modern's one continuous flow there is no earlier content
    /// for the excess ascent to bleed into — it clips against the text container's own top
    /// edge; for any OTHER line it instead crowds the line above it (a real defect too, not
    /// merely cosmetic — `oversizedClearanceBelowBaseline`'s own citation on why "the glyph
    /// technically stays inside its own box" is not the bar).
    ///
    /// This is NOT a port of Native's own self-pass/overlay mechanism (Jon's ruling): Modern
    /// has no `PageLine`s, no overprint/self-pass compositing, and no page boundaries known at
    /// render time (`RenderedDocument.hfEvents`'s own doc comment — AppKit decides where a
    /// Modern page breaks, never this function). Instead the reserved room is baked directly
    /// into the FLOWING TEXT, as an invisible SPACER PARAGRAPH inserted immediately before the
    /// affected one — NOT as `paragraphSpacingBefore` on that paragraph itself, which was the
    /// first thing tried here and empirically does NOT work for the exact case that matters
    /// most: AppKit suppresses `paragraphSpacingBefore` entirely for whichever paragraph is
    /// the very first one in a text container (confirmed empirically building this fix — the
    /// deficit value landed correctly in the attribute, but the real first-fragment's own
    /// container-relative position never moved). A preceding spacer paragraph sidesteps that
    /// suppression rule entirely: its own fixed `minimumLineHeight`/`maximumLineHeight` is
    /// ordinary line STACKING, not spacing-relative-to-a-predecessor, so it reserves the same
    /// room whether the paragraph it precedes is the document's very first line (a hard
    /// container-top clip) or an ordinary mid-flow line AppKit's own later pagination happens
    /// to start a page on — `PagedDocumentView.buildPages` already respects ordinary paragraph
    /// stacking the same way for everything else in this file, no separate headroom/overlay
    /// bookkeeping to keep in sync with it.
    ///
    /// The RULE lives here only: "if this paragraph's real ink rises above where AppKit's own
    /// (possibly tight-compressed) placement would put it, reserve the difference plus a
    /// float-safety margin" — same `+ 2` convention `leadingHeadroom` already uses, for the
    /// same reason (a second, independent AppKit drawing pass does not land pixel-for-pixel
    /// identical to the one that measured it). `modernAscentDeficit` below is the METRICS
    /// seam a later refactor (e.g. once Modern gets its own real per-page geometry) can
    /// replace without touching this rule.
    private static func modernLeadingSpacer(
        for line: NSAttributedString, paragraph: NSParagraphStyle, bodyFont: NSFont, width: CGFloat
    ) -> NSAttributedString? {
        // Only a TIGHT (compressed-below-natural) paragraph can ever need this — a plain
        // paragraph sets no line-height override at all (`modernParagraphStyle`'s own doc
        // comment: "its baseline IS AppKit's own natural font-metric line height"), so
        // AppKit's default placement already reserves a font's own real ascender above its
        // baseline, the same way it does for every ordinary (non-tight) line in this file.
        guard paragraph.lineHeightMultiple > 0, paragraph.lineHeightMultiple < 1 else { return nil }
        let deficit = Self.modernAscentDeficit(for: line, width: width)
        guard deficit > 0 else { return nil }
        let height = deficit + 2
        let spacerParagraph = NSMutableParagraphStyle()
        spacerParagraph.minimumLineHeight = height
        spacerParagraph.maximumLineHeight = height
        let spacer = NSMutableAttributedString()
        spacer.append(attributedLine([], font: bodyFont, paragraph: spacerParagraph))
        spacer.append(lineTerminator(font: bodyFont, paragraph: spacerParagraph))
        return spacer
    }

    /// METRICS: lays `line` out alone, in a throwaway container at the SAME width the real
    /// render uses, then compares AppKit's own real first-fragment baseline placement
    /// (`NSLayoutManager.location(forGlyphAt:)`, the same idiom `leadingHeadroom`'s own doc
    /// comment already trusts over a guessed formula for how `lineHeightMultiple` divides its
    /// compression between ascent and descent) against the line's own real glyph ink bounds
    /// (`CTLineGetBoundsWithOptions(.useGlyphPathBounds)`, this file's established "measure
    /// real ink, never guess" convention — `leadingHeadroom`'s own doc comment, `line
    /// ExceedsFragment`'s job 242 fix). A positive result means the real ink rises above
    /// where AppKit would place it; zero or negative means it already fits.
    private static func modernAscentDeficit(for line: NSAttributedString, width: CGFloat) -> CGFloat {
        guard line.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: line)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return 0 }
        let baselineFromFragmentTop = layoutManager.location(forGlyphAt: glyphRange.location).y
        let ctLine = CTLineCreateWithAttributedString(line)
        let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
        let inkAboveBaseline = bounds.origin.y + bounds.height
        return inkAboveBaseline - baselineFromFragmentTop
    }

    /// Job 450 (b27, revert of job 439's marker-override): job 439 substituted Native/
    /// Printed's plain-arabic endnote label into Modern, believing it matched a b26 intake
    /// ruling. It did not — Jon ruled on 2026-08-20, having already weighed the paper
    /// evidence, that Modern KEEPS the Word-standard lowercase-roman endnote convention
    /// (`modernSemanticFlow`'s own `shownLabels` under its `.word` scheme, MS-OI29500
    /// §17.11.17: "In Word, the default value for endnote numbering format is lowerRoman"):
    /// "Since the point is to be Modern, I think we should keep it at the Word standard we
    /// are using. For now." Doctrine going forward: paper scans adjudicate Native/Printed;
    /// Modern diverges from paper BY DESIGN to match Word/modern conventions, and a scan
    /// must never be cited against it. So this file no longer substitutes anything —
    /// `renderModern`/`renderModernAnnotated` render `flow.notes`/`SemanticRun.text` exactly
    /// as `modernSemanticFlow` (the engine) already romanizes them.

    /// Job 437 (b27 item 10, Jon's ruling): `NSParagraphStyle.lineHeightMultiple` is a
    /// PARAGRAPH-level attribute — it compresses EVERY AppKit line fragment of a hard-
    /// returned line uniformly, including any fragment produced by AppKit's own word-wrap
    /// INSIDE that same hard-returned line (`modernSemanticFlow` already reflows a
    /// WordStar-source soft return away, so a `.para` item's text is real prose that gets
    /// re-wrapped fresh at Modern's own proportional-font width — job field report:
    /// POWERUSE.WS's TTO #2/#3 captions, `TTO #2`'s own source using WordStar soft returns
    /// (`0x8D`) between short print lines, reflow into ONE long paragraph that then wraps
    /// in Modern). Jon's ruling: tight leading is only ever legitimate BETWEEN hard-
    /// returned lines — never on a soft-wrapped CONTINUATION of one — "no paragraph class
    /// justifies sub-normal leading" there, verse or not. AppKit has no attribute that
    /// tightens only the inter-paragraph gap while leaving a paragraph's own internal wrap
    /// spacing alone, so the fix backs `tight` off ENTIRELY for a paragraph occurrence that
    /// actually wraps — both fragments render at ordinary body leading, the closest
    /// available approximation to "hard-returns only" AppKit's own model supports.
    ///
    /// Whether a hard-returned line actually wraps depends on real AppKit layout at the
    /// real render width (mixed per-run fonts, PIX widths, indent geometry already baked
    /// into `paragraph`) — the same "measure real layout, never guess" rule
    /// `modernAscentDeficit` above already established, so this measures the ACTUAL built
    /// `line` rather than estimating from a character count. (Horizontal word-wrap is a
    /// width-only decision — `lineHeightMultiple` is a vertical metric that plays no part
    /// in WHERE AppKit breaks a line — so measuring the wrap on the tight-styled `line` is
    /// exactly as accurate as measuring it on a hypothetical untight one.)
    private static func modernLineWraps(_ line: NSAttributedString, width: CGFloat) -> Bool {
        guard line.length > 0 else { return false }
        let storage = NSTextStorage(attributedString: line)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var fragments = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
            fragments += 1
        }
        return fragments > 1
    }

    /// One hang column per def-list BLOCK, not per row (job 307, Jon's b17 field
    /// report round 2 on VERSIONS.WS/CONVERT.WS: job 299's per-row `label.count + 2`
    /// hang made every row in the same block wrap at its own column). Rule: 2in
    /// (144pt) from the PAGE EDGE past the block's own level start, i.e. 72pt past
    /// Modern's own 1in (72pt) margin — a Modern screen measure, independent of the
    /// document's own column width, and now (job 322/b20, Jon's field ruling
    /// 2026-08-15: "I don't like the 2.5-inch wrap... it needs to be 2 inches")
    /// FIXED — never widened, no matter how long a block's longest label is.
    ///
    /// Job 312/b19 (2026-08-14, Jon's field report, corrects job 307's own spec error):
    /// `renderModern`'s `textFrame` origin already sits at the 1in margin, so a
    /// paragraph's `headIndent` of 144pt (job 307's original figure) landed the column
    /// at margin(72pt) + 144pt = 216pt from the page edge — 3in total, "indented too
    /// much... 1 inch off margin" per Jon. The base fixed offset is 72pt (one inch
    /// PAST the margin, so margin(72pt) + 72pt = 144pt/2in from the page edge, matching
    /// the field spec) — the per-level ladder stepping for nested blocks below is
    /// unchanged from job 307.
    ///
    /// Job 322/b20: job 312's own longest-label override — widening the column past
    /// 144pt for a block whose longest label wouldn't fit — is GONE. Jon rejected the
    /// look it produced (b19's VERSIONS.WS block, with `RJSMACRO.EXE:` in it, wrapped
    /// its whole block at 2.5in). The column never moves now: a label longer than it
    /// simply overlaps — its description starts right after the label + gap on the
    /// label's own line (no paragraph-geometry trick needed for this: `modernParagraph
    /// Style`'s `firstLineHeadIndent` only ever governs where LINE ONE starts, never
    /// where it ends, so a long label already ran past `headIndent` on line one before
    /// this job — only wrapped lines ever obeyed `headIndent`/`hangCols`), and every
    /// WRAPPED line still snaps to the fixed 144pt column like every other row's.
    ///
    /// A "block" is a maximal contiguous run of list rows (bullet/def/plain rows
    /// embedded inside one, e.g. VERSIONS.WS's unlabelled continuation line) that
    /// never dips shallower than a given nesting level — CONVERT.WS's nested level-2
    /// def rows (WSASC.COM etc., nested inside a level-1 bullet run) form their OWN
    /// block at their OWN level, stepped in with the rest of the ladder (job 299),
    /// never sharing the outer block's column. Returns the item's ARRAY INDEX (not
    /// identity — `SemanticItem` rows can repeat) mapped to its block's hang, for
    /// every row with `structure.level >= 1`; callers look this up per index while
    /// walking the same `items` array. Job 322 leaves this block-grouping machinery in
    /// place even though every block now resolves to the SAME fixed column regardless
    /// of its content — the machinery is what job 312c's blank-line coalescing (below)
    /// still needs, and re-deriving block boundaries a second, simpler way risks the
    /// two drifting apart the way `renderModern`/`renderModernAnnotated` sharing this
    /// one function is specifically designed to prevent.
    ///
    /// Job 312c/b19 (2026-08-14, Jon's ruling): a blank source line between two def
    /// entries is vertical spacing WITHIN the visual list, not a boundary — his own
    /// complaint ("each line wrap seems to have its own place") is about the whole
    /// list Jon looks at, and VERSIONS.WS's entries are blank-line separated. A blank
    /// row therefore does NOT close a block when the next non-blank row continues the
    /// list (a non-centered row with `structure.level >= 1`); the block only closes on
    /// a genuine non-list row (prose/heading), or at end of items. Nesting dipping
    /// shallower is still handled the moment that shallower row actually arrives — the
    /// existing `closeLevels(atLeast: level + 1)` call below already closes only the
    /// levels deeper than it, so a blank line ahead of a same-or-shallower list row
    /// needs no special-casing of its own.
    private static func defListBlockHangCols(
        items: [SemanticItem], colPt: Double
    ) -> [Int: Double] {
        let fixedCols = 72.0 / colPt
        var openIndices: [Int: [Int]] = [:]
        var result: [Int: Double] = [:]

        func closeLevels(atLeast level: Int) {
            for l in openIndices.keys.filter({ $0 >= level }) {
                for idx in openIndices[l] ?? [] { result[idx] = fixedCols }
                openIndices[l] = nil
            }
        }

        func isListRow(_ item: SemanticItem) -> Bool {
            guard case let .para(_, _, _, _, _, structureOpt, _, _) = item,
                  let structure = structureOpt, !structure.centered, structure.level >= 1
            else { return false }
            return true
        }

        func nextNonBlankContinuesList(after i: Int) -> Bool {
            var j = i + 1
            while j < items.count, case .blank = items[j] { j += 1 }
            guard j < items.count else { return false }
            return isListRow(items[j])
        }

        for (i, item) in items.enumerated() {
            if case .blank = item {
                if nextNonBlankContinuesList(after: i) { continue }
                closeLevels(atLeast: 1)
                continue
            }
            guard case let .para(_, _, _, _, _, structureOpt, _, _) = item,
                  let structure = structureOpt, !structure.centered, structure.level >= 1
            else {
                closeLevels(atLeast: 1)
                continue
            }
            let level = structure.level
            closeLevels(atLeast: level + 1)
            openIndices[level, default: []].append(i)
        }
        closeLevels(atLeast: 1)
        return result
    }

    private static func renderModern(_ state: DocumentState,
                                     exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        let doc = state.document
        let size = CGFloat(state.modernFontSize)
        let bodyFont = NSFont(name: state.modernFontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        // Job 437 (b27, Jon's font-fallback ruling): the Settings default (`bodyFont`,
        // above) is the NO-INFORMATION case only — it must never override font information
        // the document actually supplies. A span with no font index (`SemanticRun.font ==
        // nil`) in a document that DOES declare fonts elsewhere is not "no information",
        // it's just a run no WS5+ font block happens to cover — the RIGHT fallback there is
        // the same Courier Prime substitute Native's own `attributedLine` callers already
        // use unconditionally (`courier`/`courierPrime` above), not the user's chosen
        // reading face, and NOT the document's first declared font either (which is
        // typically a title/display face, `printedMacFontRows`' own family table — a
        // bizarre choice for ordinary body text). `doc.fonts.isEmpty` is the SAME "carries
        // no font information at all" test `ModernViewerStyleTests
        // .fontlessDocumentUsesTheUsersModernSettings` already pins for the other half of
        // this rule.
        let modernFallbackFont = doc.fonts.isEmpty ? bodyFont : Self.courierPrime(size: size)
        let colPt = Self.modernColPt(doc)
        var flow = modernSemanticFlow(doc)
        // b34 N1 (job 529): same collapse `modernParagraphContent`'s own citation
        // explains, applied to note/footnote text — `PDFModernLayout.swift`'s
        // `modernFlow` collapses `.note`/footnote text the identical way
        // (`sentenceSpacingTexts([text])[0]`, its own local idiom, ported verbatim
        // here), and this view's `.note`/`.noteSeparator`-driven footnote appendix reads
        // `flow.notes[...].text` at every one of its own call sites below — mutating it
        // once, here, keeps all of them (and the `SRDiagnosticsGate` string search
        // further down, which must see the SAME text actually rendered) in lockstep
        // rather than needing the same call repeated at each site.
        flow.notes = flow.notes.map { row in
            var row = row
            row.text = sentenceSpacingTexts([row.text])[0]
            return row
        }
        let items = flow.items
        let blockHangCols = Self.defListBlockHangCols(items: items, colPt: colPt)
        // Job 423 (view item d): the ACTUAL available text width, not `colPt` (one
        // monospace COLUMN's width, e.g. ~7pt — a single character cell, `modernColPt`'s
        // own doc comment). `pixDimsPt`'s "cap to the measure so an oversized image never
        // overflows" only makes sense against the real column MEASURE an image sits in;
        // passing a single character's width as that cap scaled every inline Modern image
        // down by roughly the same ratio as its real width to one column (PREVIEW.WS's
        // WORDSTAR.PIX: ~468pt wide native, capped to ~7pt — the "dash placeholder" field
        // report, intake items 15/23). Same paper/margin this function computes at its own
        // end for `textFrame` — hoisted here since it does not depend on anything the item
        // loop below produces.
        let modernTextWidthPt: Double = {
            let paper = state.pageSize.value?.sizeInPoints
                ?? CGSize(width: modernMetrics(doc).pageWidth, height: modernMetrics(doc).pageHeight)
            return max(1, Double(paper.width) - 144)
        }()
        // b27 item 11: computed once, not per-line — `ModernScreenplay.detectBlocks` already
        // walks the whole document itself (same discipline the engine's own `modernFlow`
        // uses for its own `screenplayBlocks`/`screenplayMarkerBis`).
        let screenplayBlocks = ModernScreenplay.detectBlocks(doc)
        let screenplayMarkerBis = ModernScreenplay.markerCandidateBlocks(
            screenplayBlocks, blockCount: doc.blocks.count)

        let output = NSMutableAttributedString()
        var hfEvents: [HFEvent] = []
        var modernFootnoteEvents: [ModernFootnoteEvent] = []
        let blankParagraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                        indentCols: 0, cutCols: 0)
        // Job 423 (view item a, intake item 6): shared by the `.noteSeparator`/`.note` case
        // below AND the footnote appendix after the loop — one paragraph of note-appendix
        // text, mirroring the engine's OWN Modern renderer's convention exactly
        // (`PDFModernLayout.swift`'s `modernFlow`: Times-Roman at `modernNotePt`, 11/14 of
        // `modernBodyPt`'s 14). This app's Modern view already diverges from the engine's
        // fixed Times-Roman body font by design (the user's own chosen `modernFontName`,
        // per this file's own header on `ExportEngine`'s "documented AppKit divergence") —
        // notes keep that SAME app font, just at the engine's own relative size ratio,
        // rather than forcing Times where the body never is.
        let noteSize = size * (11.0 / 14.0)
        let noteFont = NSFont(name: state.modernFontName, size: noteSize)
            ?? NSFont.systemFont(ofSize: noteSize)
        let noteParagraph = Self.modernParagraphStyle(
            colPt: colPt, size: noteSize, align: .left, indentCols: 0, cutCols: 0)
        // Job 502: factored out of `appendNoteLine` below so the page-foot footnote block
        // (`ModernFootnoteEvent.entries`, built in the `.para` case further down) can share
        // the identical styling without `PagedDocumentView` ever needing a copy of it —
        // includes its own trailing terminator so a caller can concatenate several of these
        // and get correctly separated lines with no further attribute bookkeeping.
        func noteLineAttributedString(_ text: String) -> NSAttributedString {
            let result = NSMutableAttributedString(string: text, attributes: [
                .font: noteFont,
                .paragraphStyle: noteParagraph,
                // Job 478: this page is ALWAYS white paper (PagedDocumentView's page
                // NSView hard-codes `.backgroundColor = .white`), never a UI surface — so
                // `.textColor` (black in Light Mode, WHITE in Dark Mode) painted the note
                // text invisible on Jon's Dark Mode machine while every headless test, run
                // under the default Aqua appearance, saw it as black and passed. Fixed
                // colour, matching what body text on this same paper already hard-codes
                // (`NSColor.black`, this function's own sibling call sites).
                .foregroundColor: NSColor.black,
            ])
            result.append(lineTerminator(font: noteFont, paragraph: noteParagraph))
            return result
        }
        func appendNoteLine(_ text: String) {
            output.append(noteLineAttributedString(text))
        }
        // Job 502: the SAME 20-dash rule the `.noteSeparator` case below draws for the real
        // end-of-document appendix, built once here so a page-foot footnote block
        // (`PagedDocumentView.drawFootnoteBlock`) never has its own copy of either the text
        // or the styling.
        let modernFootnoteSeparator = noteLineAttributedString(String(repeating: "-", count: 20))
        // b28 note 11 (Jon's ruling): character offset into `output`, ascending, of every
        // screenplay page-number-marker paragraph's own first character — the render-side
        // half of rule (a) (`ModernScreenplay`'s own doc comment: "Modern has no page-break
        // counterpart... noted, not silently dropped" — this is that gap closed). Captured
        // HERE, gated by the exact SAME `screenplayBlocks`/`screenplayMarkerBis` membership
        // test rule (b) already uses below, per Jon's own ruling on scope ("only supposed to
        // apply when our code detects a screenplay") — never widened to every bare numbered
        // line. `PagedDocumentView.buildPages` is the sole consumer: it forces AppKit's own
        // container chain to end just before each offset, so the marker paragraph becomes the
        // FIRST content of a new page instead of merely holding the right margin on whichever
        // page it happened to reflow onto.
        var modernForcedPageBreakOffsets: [Int] = []
        for (i, item) in items.enumerated() {
            switch item {
            case .para(let align, let indentCols, let cutCols, let runs, let paraFootnotes, let structure, let isVerse, let bi):
                // b27 item 11: Jon's screenplay ruling, Modern's own port (see
                // `ModernScreenplay`'s own doc comment for the rule and the
                // internal-to-CtrlKD reason this can't just call the engine's detector).
                // b28 note 11: rule (a) (a page-number marker starts a new PAGE) DOES now
                // have a Modern counterpart — `modernForcedPageBreakOffsets` below records
                // where, and `PagedDocumentView.buildPages` is what actually forces AppKit's
                // container chain to break there (this loop itself still makes no page
                // decision; it only tells the view WHERE one belongs).
                var effectiveAlign = align
                var isScreenplaySceneNumberLine = false
                var isScreenplayPageMarkerLine = false
                if screenplayBlocks.contains(bi) || screenplayMarkerBis.contains(bi) {
                    let visible = runs.filter { $0.ref == nil }.map(\.text).joined()
                    if ModernScreenplay.matchesPageMarker(visible) {
                        // Rule (b): the page-number marker renders flush against the
                        // right margin, not left-aligned.
                        effectiveAlign = .right
                        // b28 note 11, rule (a): this SAME line also starts a new Modern
                        // page — captured below, at the point this paragraph's own first
                        // character actually lands in `output` (after any leading spacer).
                        isScreenplayPageMarkerLine = true
                    } else if screenplayBlocks.contains(bi),
                              ModernScreenplay.matchesSlugline(visible),
                              ModernScreenplay.matchesTrailingSceneNumber(visible) {
                        // Rule (c): a slugline carrying its own right-hand scene number
                        // must never wrap that number onto its own line.
                        isScreenplaySceneNumberLine = true
                    }
                }
                let (paragraphSpans, paragraph) = Self.modernParagraphContent(
                    align: effectiveAlign, indentCols: indentCols.value, cutCols: cutCols.value,
                    runs: runs,
                    structure: structure, colPt: colPt, size: size, font: bodyFont,
                    blockHangCols: blockHangCols[i], isVerse: isVerse)
                // b28 note 9: a graphic (box-drawing) row immediately followed by ANOTHER
                // graphic row must sit at its natural line advance, no inter-paragraph gap —
                // see `modernParagraphStyle`'s own `paragraphSpacing` comment for the bug this
                // closes (every Modern paragraph got the SAME 0.35em space-after unconditionally,
                // which turns a box's continuous vertical rule into a dashed line, one dash per
                // row). `paragraphSpacing` is a space-AFTER property, so the row ABOVE a
                // boundary owns that boundary's gap: an ordinary prose paragraph immediately
                // above or below a box is untouched by this check and keeps its own normal
                // spacing — the box's leading gap (owned by the prose above it) and its
                // trailing gap (owned by the box's OWN last row, since that row's next
                // neighbour isn't graphic) both survive; only a graphic-to-graphic pair loses
                // its gap.
                if Self.paraContainsGraphicChar(item), i + 1 < items.count, Self.paraContainsGraphicChar(items[i + 1]) {
                    paragraph.paragraphSpacing = 0
                }
                let measureWidthPt = max(1, modernTextWidthPt - indentCols.value * colPt - cutCols.value * colPt)
                let renderSpans = isScreenplaySceneNumberLine
                    ? ModernScreenplay.collapseSceneNumberGap(paragraphSpans)
                    : paragraphSpans
                if isScreenplaySceneNumberLine {
                    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: CGFloat(measureWidthPt))]
                }
                var line = attributedLine(
                    coalesce(PageLine(renderSpans)).spans,
                    font: modernFallbackFont,
                    paragraph: paragraph,
                    fonts: doc.fonts,
                    defaultSize: Int(size),
                    useCourierPrime: true,
                    pixResults: exportFlags.pictures ? state.pixResults : [],
                    pixMeasureWidthPt: measureWidthPt
                )
                // Job 437 (b27 item 10): a tight (verse/centered) paragraph that actually
                // word-wraps must render at NORMAL leading throughout — see
                // `modernLineWraps`'s own doc comment. `paragraph` still needs to carry the
                // correction going forward (`modernLeadingSpacer`/`lineTerminator` below
                // both read it), and `line` must be rebuilt: `NSAttributedString` copies an
                // `NSParagraphStyle` attribute value at set-time, so mutating `paragraph`
                // after `line` already exists would NOT change `line`'s own baked-in style.
                if paragraph.lineHeightMultiple > 0,
                   Self.modernLineWraps(line, width: CGFloat(measureWidthPt)) {
                    paragraph.lineHeightMultiple = 0
                    line = attributedLine(
                        coalesce(PageLine(renderSpans)).spans,
                        font: modernFallbackFont,
                        paragraph: paragraph,
                        fonts: doc.fonts,
                        defaultSize: Int(size),
                        useCourierPrime: true,
                        pixResults: exportFlags.pictures ? state.pixResults : [],
                        pixMeasureWidthPt: measureWidthPt
                    )
                }
                // b28 note 9 (part 2, found verifying the recon): BOXES.WS's rows are
                // classified `isVerse` (the engine's own consecutive-short-lines heuristic —
                // a box reads exactly like a stanza's shape), which makes EVERY row `tight`
                // (`modernParagraphStyle`'s `tight: align == .center || isVerse`) — and a tight
                // row whose real glyph ink rises above the compressed line box triggers job
                // 434's own leading-spacer headroom mechanism (`modernLeadingSpacer`,
                // `modernAscentDeficit`), independently of `paragraphSpacing`. Measured directly
                // building this fix: box-drawing glyphs DO report a positive ascent deficit
                // against the tight line height, so the spacer fires between every row even
                // after the `paragraphSpacing` suppression above — closing only the
                // `paragraphSpacing` half left a real, measured ~5pt gap between rows, still a
                // visible dash, not the continuous rule Jon asked for. `modernLeadingSpacer`'s
                // own headroom purpose (reserving room for an oversized TITLE's ascender) does
                // not apply to box-drawing content the same way, so the same "preceded by
                // another graphic row" test used above suppresses it here too.
                let precededByGraphicRow = i > 0
                    && Self.paraContainsGraphicChar(items[i - 1]) && Self.paraContainsGraphicChar(item)
                // b28 note 11: recorded BEFORE the leading spacer (if any) — the spacer, when
                // present, is this SAME paragraph's own headroom and must move to the new page
                // with it, not stay stranded as trailing blank canvas on the page before. Job
                // 502: `modernFootnoteEvents` (below) uses this SAME offset for the SAME reason
                // — a footnote attached to this paragraph belongs on whichever real page this
                // paragraph's own leading canvas lands on, not on some later page a mid-
                // paragraph marker glyph happens to wrap onto.
                let paragraphCharOffset = output.length
                if isScreenplayPageMarkerLine {
                    modernForcedPageBreakOffsets.append(output.length)
                }
                if !precededByGraphicRow, let spacer = Self.modernLeadingSpacer(
                    for: line, paragraph: paragraph, bodyFont: bodyFont, width: CGFloat(measureWidthPt)) {
                    output.append(spacer)
                }
                output.append(line)
                output.append(lineTerminator(font: bodyFont, paragraph: paragraph))
                // Job 502 (Jon's ruling, 2026-08-25: footnotes sit at the page FOOT, dash-
                // separated, like Printed — job 490 item 1 got the right PAGE and the wrong
                // PLACE). This paragraph's own footnote text no longer joins `output` inline —
                // `PagedDocumentView.buildPages` is the one place Modern's REAL pages exist
                // (AppKit decides where they break, this function's own top doc comment), so
                // it is the one place that can reserve room for a footnote block at a real
                // page's own foot and draw it there, mirroring the engine's own `modernStreams`
                // reservation (`PDFModernLayout.swift`'s `noteBlockH`/`sepH`, read at the pinned
                // engine commit 7e8ffdb — see this job's own report). `paragraphCharOffset`
                // carries job 490's still-correct "the marker's own paragraph" placement rule
                // forward to that later consumer.
                let footnoteEntries: [NSAttributedString] = paraFootnotes.compactMap { footnote in
                    guard flow.notes.indices.contains(footnote.index) else { return nil }
                    let row = flow.notes[footnote.index]
                    return noteLineAttributedString("\(Self.modernNoteEntryLabel(row.shown)) \(row.text)")
                }
                if !footnoteEntries.isEmpty {
                    modernFootnoteEvents.append(ModernFootnoteEvent(
                        charOffset: paragraphCharOffset, entries: footnoteEntries))
                }
            case .blank:
                // The author's own blank line (M4) — `attributedLine([], ...)` supplies the
                // single invisible space `lineTerminator`'s own doc comment explains blank
                // lines need to stay on the baseline grid.
                output.append(attributedLine([], font: bodyFont, paragraph: blankParagraph))
                output.append(lineTerminator(font: bodyFont, paragraph: blankParagraph))
            case .hf(let which, let line, let text):
                // Job 393 (391 root cause 2): job 371 item 3's own comment here used to argue
                // Modern couldn't honour per-page replay because "Modern's own reflow has no
                // page-break DECISION until AppKit lays it out" — true, but that only means
                // the REPLAY has to happen later, against AppKit's own real pages, not that it
                // can't happen at all. The engine's own Modern PDF already replays every `.hf`
                // per real page (`PDFModernLayout.swift`'s `modernStreams`, ruling 2026-08-06
                // M5: "Modern keeps headers") — showing the text inline, once, additively, is
                // what actually produced job 391's bug: OLDTIMES's `.h1` sits AFTER page 1's
                // own title text, so the OLD inline placement put it on page 1 (WordStar's own
                // rule says it should apply from page 2), and POWERUSE's header never repeated
                // past whichever single page it happened to flow onto.
                //
                // No suppression logic lives here any more: this case ONLY records WHERE
                // (character offset) and WHAT changed, exactly the shape `Page.headers`/
                // `.footers`' own engine replay consumes (`curHeaders[line] = text`,
                // unconditionally, even empty — `RenderedDocument.hfEvents`'s own doc comment
                // on why an empty `text` still needs an event, not a skip). Turning this log
                // into real per-page `RunningLine`s is entirely `DocumentRenderer
                // .modernRunningLines`/`PagedDocumentView`'s job now — "consume the engine's
                // verdict," not re-derive it here.
                guard exportFlags.headers else { continue }
                hfEvents.append(HFEvent(kind: which == .header ? .header : .footer,
                                        line: line, text: text, charOffset: output.length))
            case .pageBreak, .cond, .tabs:
                // No rendered consequence on screen: `.pageBreak`/`.cond` are Printed-only
                // pagination decisions, `.tabs` is editor-time state (same "no rendered
                // consequence" the engine's own `modernFlow` gives `.tabs`, `PDFModernLayout
                // .swift:172-173`).
                continue
            case .noteSeparator:
                // Job 423 (view item a, intake item 6): the endnote/annotation/comment
                // appendix was absent from the on-screen Modern view since job 263 (scope
                // was font identity/paragraph fidelity, not this) — closed here. Job 490
                // item 1: footnotes no longer join this appendix — they emit inline, right
                // after their own marker's paragraph, in the `.para` case above (see that
                // case's own citation). This separator/loop now serves ONLY real endnotes/
                // annotations/comments, which stay a true end-of-document appendix by
                // WordStar's own convention (`modernSemanticFlow`'s own `endRows` doc
                // comment: "flowing, not bottom-anchored").
                appendNoteLine(String(repeating: "-", count: 20))
            case .note(_, _, let label, let text):
                // b34 N1 (job 529): unlike the footnote path above, `text` here is
                // `SemanticItem.note`'s OWN snapshot (`Layout.swift`'s `modernSemanticFlow`
                // copies `noteRows[ni].text` in at item-construction time, before this
                // function ever sees `flow`) — mutating `flow.notes` above never reaches
                // it, so the same collapse is applied again, right here, at the one place
                // this specific copy is read.
                appendNoteLine("\(Self.modernNoteEntryLabel(label)) \(sentenceSpacingTexts([text])[0])")
            }
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        // Job 477: the decisive measurement for the persistent "no footnotes/endnotes in
        // Modern" report — every established fact says the appendix/inline notes SHOULD be
        // in `output` (this function's own `.noteSeparator`/`.note` cases above, and the
        // inline footnote emission in the `.para` case, job 490), yet Jon sees none on
        // screen. This says, once per
        // render, whether the appendix actually made it into the built string at all, so the
        // next round measures instead of guessing between "never appended" and "appended but
        // not visible." Gated on the SAME `SRDiagnosticsGate` switch `PagedDocumentView
        // .logPageDiagnostics` (job 460) already uses.
        if SRDiagnosticsGate.isEnabled() {
            let haystack = output.string as NSString
            let separatorRange = haystack.range(of: String(repeating: "-", count: 20))
            let separatorDesc = separatorRange.location == NSNotFound
                ? "NOT-FOUND" : "FOUND@\(separatorRange.location)"
            func kindLabel(_ kind: NoteKind) -> String {
                switch kind {
                case .footnote: return "footnote"
                case .endnote: return "endnote"
                case .annotation: return "annotation"
                case .comment: return "comment"
                default: return "note"
                }
            }
            let itemsDesc = flow.notes.enumerated().map { index, row -> String in
                let range = haystack.range(of: row.text)
                let found = range.location == NSNotFound ? "NOT-FOUND" : "FOUND@\(range.location)"
                return "\(kindLabel(row.kind))[\(index)]=\(found)"
            }.joined(separator: " ")
            NSLog("[SoftReturn] DocumentRenderer.renderModern noteAppendix outputLength=%d separator=%@ %@",
                  output.length, separatorDesc, itemsDesc.isEmpty ? "<no-notes>" : itemsDesc)
        }

        // Modern's page is the app's own, not the file's: the user's chosen paper, 1in
        // margins. `modernMetrics` supplies the library's fixed figures; the margin is the
        // spec's, and the paper is whatever the bottom bar's Page control reports.
        let paper = state.pageSize.value?.sizeInPoints
            ?? CGSize(width: modernMetrics(doc).pageWidth, height: modernMetrics(doc).pageHeight)
        // Unlike Printed, there is no independent PDF baseline to back-solve against here:
        // Modern's own PDF export (`ExportEngine.modernPDF`) draws this SAME `textFrame`
        // through the native text stack, so screen and export can only ever agree or
        // disagree together. Placing the container's top EDGE at the margin — exactly as
        // the left/right edges already are — is therefore both simplest and correct.
        //
        // A back-solve like Printed's USED to live here, aiming the first BASELINE at a
        // fixed `margin + modernMetrics(doc).size`. That size (12) is the library's Courier
        // figure, unrelated to `bodyFont` — the user's own face and size, which Modern
        // renders instead by design. Subtracting THAT font's baseline offset from a target
        // built from a DIFFERENT font's size pulled the container's top edge off 72pt by a
        // few points, in either direction depending on the chosen font's metrics — top and
        // bottom margins that silently stopped being 1in and drifted by font choice, the
        // asymmetry Jon's measurement caught. The margin is the margin; nothing here needs
        // to know what glyph sits nearest it.
        let margin: CGFloat = 72
        let textFrame = CGRect(
            x: margin, y: margin,
            width: max(1, paper.width - margin * 2),
            height: max(1, paper.height - margin * 2)
        )

        return RenderedDocument(
            text: output,
            pageSize: paper,
            // Page count is AppKit's to decide once it has flowed the text; the view layer
            // grows containers until the text is consumed and reports the real number. One
            // is the floor so an empty document still shows a blank page.
            textFrame: textFrame,
            pageCount: 1,
            clipsLines: false,
            // Modern's `modernSemanticFlow` already reflowed WordStar's own wrap away — no
            // physical soft-return left to mark, and this plain path never runs while Show
            // Invisibles is on anyway (`renderWithInvisibles` calls `renderModernAnnotated`
            // instead, job 294).
            softLineFlags: [],
            // Overprint is Printed-only too — Modern has no `PageLine`s at all, so there is
            // no `.overprint` flag to chain.
            overprintPasses: [],
            oversizedSelfPasses: [],
            // No passes to align in Modern style — see `RenderedDocument.baselineOffset`'s
            // own doc comment.
            baselineOffset: 0,
            // No oversized self-passes to reserve room for either (job 396) — same reason.
            leadingHeadroom: [],
            // Empty here, not Printed-only any more (job 393): Modern's real per-page running
            // lines can't be built until AppKit has laid the flow out — `hfEvents` below is
            // what carries the replay log to the caller that CAN, `PagedDocumentView`.
            runningLines: [],
            hfEvents: hfEvents,
            pageNumberStart: doc.page?.pnStart ?? 1,
            // Modern has one AppKit-grown page, no library pagination to anchor against.
            realPageIndexByPage: [0],
            // Job 412 (Jon's ruling): Modern is reflowed by design — explicitly NOT pinned.
            pinnedBaselines: [:],
            // Job 427: Modern has no per-page margin concept (Jon's own ruling scopes
            // geometry unification to Printed/Native only — Modern is the app's own page,
            // not the file's, see this function's own doc comment above) — one flat, shared
            // anchor. `PagedDocumentView.textTop(atPage:)` falls back to this same value for
            // every page beyond this array's single placeholder entry (Modern's real page
            // count isn't known until AppKit lays the flow out).
            perPageTextTop: [Double(textFrame.origin.y)],
            pinnedPageBottoms: [],
            // b28 note 11: the ascending list this loop just built above — the sole
            // non-empty producer of this field (see `RenderedDocument
            // .modernForcedPageBreakOffsets`'s own doc comment).
            modernForcedPageBreakOffsets: modernForcedPageBreakOffsets,
            // Job 502: the per-paragraph footnote log this loop just built above — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: modernFootnoteEvents,
            modernFootnoteSeparator: modernFootnoteSeparator,
            // Modern has no `PageLine`/paper-facsimile concept — see `RenderedDocument
            // .pclPrograms`'s own doc comment.
            pclPrograms: []
        )
    }

    // MARK: - Modern, Show Invisibles (job 294, Jon's ruling)

    /// `renderModern`'s sibling for the `showInvisibles` screen path — job 300 REWRITE.
    ///
    /// Jon's b16 field report on OLDTIMES (screenshots on file): toggling Show Invisibles
    /// in Modern changed the LAYOUT — centering lost, the def-list/bullet ladder collapsed,
    /// `^B`/`^Y` style tokens shown as literal inline text instead of applying as real
    /// bold/italic, a stray `^Y` at the left margin, different wrap/spacing. The ROOT CAUSE
    /// (job 294's own original design): this function walked `CtrlKD.annotatedLayout(doc)`
    /// — the RAW per-physical-line stream `renderPrintedAnnotated` uses for Native — instead
    /// of `modernSemanticFlow`, so it never ran the centering/def-list/bullet-ladder
    /// classification `renderModern` applies, and it re-inserted every `.styleToggle`
    /// token (`annotatedLayout`'s own caret text, `"^B"`/`"^Y"`/…) as literal characters
    /// inline — extra glyphs that shift word wrap, exactly the "moves" this job forbids.
    ///
    /// THE RULE (job 300's brief, Jon's standing ruling): invisibles ON in Modern is
    /// EXACTLY the invisibles-OFF layout with faint marks ADDED — nothing moves, nothing
    /// restyles. This rewrite makes that true by CONSTRUCTION rather than by inspection:
    /// every `.para`/`.blank` item below is classified and styled by the exact same
    /// `modernParagraphContent`/`modernParagraphStyle` calls `renderModern` makes on the
    /// SAME `modernSemanticFlow(doc).items`, and the SAME `attributedLine` call builds its
    /// visible text — the two views can never compute a different paragraph for the same
    /// item, because they share the one code path that decides it. Marks are ADDED, never
    /// substituted for real styling:
    ///
    /// - A hard return (the author's own Return — every `.para`/`.blank` item, both are
    ///   hard-return-terminated by `modernSemanticFlow`'s own construction) gets the SAME
    ///   "¶" glyph Native shows, appended as the LAST character inside that paragraph's own
    ///   attributed line (Native's own placement, `renderPrintedAnnotated`) — it can only
    ///   ever add a trailing glyph to a paragraph that already exists, never move, resize,
    ///   or restyle another one.
    /// - No soft-return mark (`↵`) ever appears: `modernSemanticFlow` already reflowed
    ///   WordStar's own word-wrap away (`renderModern`'s own doc comment), so there is no
    ///   physical soft-return left to mark — unchanged from job 294's original ruling.
    /// - `.pageBreak` (`.pa`/form feed) and `.cond` (`.cp N`) items — SILENTLY DROPPED by
    ///   `renderModern` (`continue`, zero output) — get a faint "— .pa —"/"— .cp N —"
    ///   marker on a line of their OWN, using `renderModern`'s OFF-state flat paragraph:
    ///   purely additive (OFF renders nothing for these items at all), so it can never
    ///   perturb a real paragraph's frame either side of it. Never a real page split —
    ///   Modern has one continuous AppKit-grown flow, no library pagination to break
    ///   against (unchanged from job 294).
    /// - Style-toggle tokens (`^B`/`^Y`/…) get NO marker at all — the brief's own explicit
    ///   "or nothing" option, taken deliberately: `modernSemanticFlow` bakes every toggle
    ///   straight into `SemanticRun.styles` (real bold/italic/underline, applied via the
    ///   SAME `runs`/spans `renderModern` renders), so there is no toggle POSITION left in
    ///   this flow to mark without re-deriving one from adjacent runs' style deltas and
    ///   inserting a character — which is exactly the "extra glyph shifts wrap" mechanism
    ///   that caused this job. Native's own philosophy (`renderPrintedAnnotated`) inserts
    ///   the caret token inline and ACCEPTS the reflow it causes (job 257: "real reflow
    ///   pagination" is Printed's own invisibles-on contract); Modern's contract is the
    ///   opposite — layout must not move — so "nothing" is that same philosophy's honest
    ///   translation, not a gap.
    /// - Dot commands other than `.pa`/`.cp`/`.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` and inline
    ///   comments are NOT shown: unlike Native's raw byte stream, `modernSemanticFlow`
    ///   never retains their text at all — every other dot command (`.lm`, `.oc`, `.tb`, …)
    ///   is already consumed into block attributes upstream. Endnotes/annotations/comments
    ///   (`.noteSeparator`/`.note`) and footnotes (folded into `.para`'s own `footnotes:`
    ///   field, `SemanticFootnote` — see `renderModern`'s own citation) were job 263's own
    ///   flagged gap (`.tabs`/`.noteSeparator`/`.note` all `continue`d there) — CLOSED job
    ///   423 (view item a/c): `renderModern`'s OFF state renders the full note appendix
    ///   now, and this ON path shows the identical content (this switch's own
    ///   `.noteSeparator`/`.note` case, plus the footnote appendix after this loop),
    ///   additively, per the same "OFF must show it too" rule job 371 item 3 established
    ///   for `.hf`. `.tabs` alone stays scoped out — editor-time state, no rendered
    ///   consequence in either view.
    ///
    /// `notes`: which `NoteKind`s `modernSemanticFlow` keeps — defaults to the engine's own
    /// `EmitOptions.defaultNotes` (comments excluded, opt-in unchanged, b24 completion C5's
    /// own ruling). `renderWithInvisibles(_:)`, the one live call site, never overrides this
    /// — there is no on-screen "show comments" control yet (a future job's own gap, not this
    /// one's: C5 is the VIEW HALF of drawing a comment's anchor mark once one IS present in
    /// the flow, not adding the toggle that puts it there). `internal` rather than `private`
    /// so `SoftReturnTests` can exercise the mark with `notes: [.comment]`, the same reason
    /// `attributedLine` above is `internal`.
    internal static func renderModernAnnotated(
        _ state: DocumentState, notes: Set<NoteKind> = EmitOptions.defaultNotes
    ) -> RenderedDocument {
        let doc = state.document
        let size = CGFloat(state.modernFontSize)
        let bodyFont = NSFont(name: state.modernFontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        // Job 437 (b27, Jon's font-fallback ruling): same correction `renderModern` applies
        // — see that function's own doc comment for the rule.
        let modernFallbackFont = doc.fonts.isEmpty ? bodyFont : Self.courierPrime(size: size)
        let colPt = Self.modernColPt(doc)
        var flow = modernSemanticFlow(doc, notes: notes)
        // b34 N1 (job 529): same collapse as `renderModern`'s identical citation —
        // Show Invisibles' own note/footnote appendix reads `flow.notes[...].text` too
        // and must match what the OFF-state view (and export) actually show.
        flow.notes = flow.notes.map { row in
            var row = row
            row.text = sentenceSpacingTexts([row.text])[0]
            return row
        }
        let items = flow.items
        let blockHangCols = Self.defListBlockHangCols(items: items, colPt: colPt)
        // Job 434: the SAME figure `renderModern` hoists for its own `modernLeadingSpacer`
        // measurement — `InvisiblesModernLayoutOracle`'s own law (job 300) requires this
        // function to insert the identical spacer paragraph `renderModern` does, at the same
        // place, so a page-1 oversized title's screen affordance stays invisible to that
        // oracle's per-item comparison, not a Show-Invisibles-only layout change.
        let modernTextWidthPt: Double = {
            let paper = state.pageSize.value?.sizeInPoints
                ?? CGSize(width: modernMetrics(doc).pageWidth, height: modernMetrics(doc).pageHeight)
            return max(1, Double(paper.width) - 144)
        }()
        let blankParagraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                        indentCols: 0, cutCols: 0)
        let noteSize = size * (11.0 / 14.0)
        let noteFont = NSFont(name: state.modernFontName, size: noteSize)
            ?? NSFont.systemFont(ofSize: noteSize)
        let noteParagraph = Self.modernParagraphStyle(
            colPt: colPt, size: noteSize, align: .left, indentCols: 0, cutCols: 0)

        let output = NSMutableAttributedString()

        func markRun(_ text: String, paragraph: NSParagraphStyle, spoken: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: bodyFont,
                .foregroundColor: invisibleMarkColour,
                .paragraphStyle: paragraph,
                .accessibilityAnnotationTextAttribute: [[NSAccessibility.AnnotationAttributeKey.label: spoken]],
                .invisibleMarkRun: true,
            ])
        }
        func appendNoteLine(_ text: String) {
            output.append(NSAttributedString(string: text, attributes: [
                .font: noteFont,
                .paragraphStyle: noteParagraph,
                // Job 478: see `renderModern`'s identical citation — same always-white
                // paper, same dynamic-`.textColor`-goes-invisible-in-Dark-Mode defect.
                .foregroundColor: NSColor.black,
            ]))
            output.append(lineTerminator(font: noteFont, paragraph: noteParagraph))
        }
        // Job 452: hoisted above the loop — see `renderModern`'s identical citation on
        // why the `.noteSeparator` case below needs this to emit footnotes first.
        let footnoteRows = flow.notes.enumerated().filter { $0.element.kind == .footnote }
        var footnotesEmitted = false

        for (i, item) in items.enumerated() {
            switch item {
            case .para(let align, let indentCols, let cutCols, let runs, _, let structure, let isVerse, _):
                let (renderSpans, paragraph) = Self.modernParagraphContent(
                    align: align, indentCols: indentCols.value, cutCols: cutCols.value, runs: runs,
                    structure: structure, colPt: colPt, size: size, font: bodyFont,
                    blockHangCols: blockHangCols[i], isVerse: isVerse)
                // b28 note 9: same suppression `renderModern` applies — see that call site's
                // own citation. Show Invisibles must compute the SAME paragraph geometry (job
                // 300's ruling), so this mirrors it exactly rather than re-deriving it.
                if Self.paraContainsGraphicChar(item), i + 1 < items.count, Self.paraContainsGraphicChar(items[i + 1]) {
                    paragraph.paragraphSpacing = 0
                }
                var line = NSMutableAttributedString(attributedString: attributedLine(
                    coalesce(PageLine(renderSpans)).spans,
                    font: modernFallbackFont,
                    paragraph: paragraph,
                    fonts: doc.fonts,
                    defaultSize: Int(size),
                    useCourierPrime: true
                ))
                // Job 434: measured from `line` BEFORE any invisible mark is appended below —
                // the same, unmarked content `renderModern`'s own `modernLeadingSpacer` call
                // measures — so OFF and ON reserve the identical amount and stay in lockstep
                // for `InvisiblesModernLayoutOracle`.
                let measureWidthPt = max(1, modernTextWidthPt - indentCols.value * colPt - cutCols.value * colPt)
                // Job 437 (b27 item 10): same correction `renderModern` applies, before this
                // line's own unmarked content picture is measured for the spacer — see
                // `modernLineWraps`'s own doc comment for why `line` must be rebuilt rather
                // than mutating `paragraph` after the fact.
                if paragraph.lineHeightMultiple > 0,
                   Self.modernLineWraps(line, width: CGFloat(measureWidthPt)) {
                    paragraph.lineHeightMultiple = 0
                    line = NSMutableAttributedString(attributedString: attributedLine(
                        coalesce(PageLine(renderSpans)).spans,
                        font: modernFallbackFont,
                        paragraph: paragraph,
                        fonts: doc.fonts,
                        defaultSize: Int(size),
                        useCourierPrime: true
                    ))
                }
                // b28 note 9 (part 2): same suppression `renderModern` applies — see that call
                // site's own citation. Must mirror it exactly (job 300's ruling, this
                // function's own header) rather than re-deriving it.
                let precededByGraphicRow = i > 0
                    && Self.paraContainsGraphicChar(items[i - 1]) && Self.paraContainsGraphicChar(item)
                if !precededByGraphicRow, let spacer = Self.modernLeadingSpacer(
                    for: line, paragraph: paragraph, bodyFont: bodyFont, width: CGFloat(measureWidthPt)) {
                    output.append(spacer)
                }
                // b24 completion (C5): a kept comment's zero-width anchor run (`ref != nil`,
                // `text == ""` — `Layout.swift`'s own run contract, round 22) carries no ink
                // through `modernParagraphContent`/`attributedLine` (an empty `Span` renders
                // nothing), so the reference had no position a reader could see even with
                // Show Invisibles on — round 20's own investigation had flagged exactly this
                // gap. `renderSpans` is `runs` mapped 1:1 in the SAME order for a PLAIN
                // paragraph — `classifyRows` always hands back a `RowStructure` (even an
                // all-nil one for an ordinary row), so "plain" is `modernParagraphContent`'s
                // OWN else-branch condition (`centered == false && kind == nil`), not
                // `structure == nil` — the only shape a comment anchor realistically appears
                // in, an inline reference inside body prose, never a bullet/def-list marker
                // or a centered title — so the anchor's character offset in the final line is
                // just the summed length of the runs ahead of it; inserting a mark there
                // lands it exactly between the words it separates, same styling family
                // (`markRun`) as every other invisible-ink class this view already marks.
                let isPlainParagraph = structure?.centered != true && structure?.kind == nil
                if isPlainParagraph {
                    var offset = 0
                    for run in runs {
                        if run.ref != nil, run.text.isEmpty {
                            let mark = markRun("[comment]", paragraph: paragraph, spoken: "comment")
                            line.insert(mark, at: min(offset, line.length))
                            offset += mark.length
                        } else {
                            offset += run.text.count
                        }
                    }
                }
                line.append(markRun("¶", paragraph: paragraph, spoken: "hard return"))
                output.append(line)
                output.append(lineTerminator(font: bodyFont, paragraph: paragraph))
            case .blank:
                // The author's own blank line — a hard return with no text of its own, so
                // unlike `renderModern`'s invisible-space placeholder, the "¶" mark alone
                // already gives AppKit a real glyph on this line's baseline grid (same
                // font/paragraph as the placeholder would have used) — matching Native's
                // own blank-hard-return line, which shows only "¶", no leading space.
                output.append(markRun("¶", paragraph: blankParagraph, spoken: "hard return"))
                output.append(lineTerminator(font: bodyFont, paragraph: blankParagraph))
            case .pageBreak(let origin):
                // Job 371 item 3: `origin` is round 20's own restoration (`SemanticItem
                // .pageBreak`'s own doc comment — "the SAME wire string
                // `AnnotatedLayout.swift`'s own `InkKind.pageBreakOrigin` already
                // produces") — consumed here now, matching Native's OWN label exactly
                // (`lineAttributedString`'s `text == "\u{0C}" ? "form feed" : text`) so a
                // form-feed-origin break reads "— form feed —" in BOTH views, not
                // "— .pa —" everywhere regardless of what the file actually did
                // ("invisibles-mark parity Native vs Modern").
                let label = origin == "\u{0C}" ? "form feed" : origin
                output.append(markRun("— \(label) —", paragraph: blankParagraph, spoken: "page break: \(label)"))
                output.append(lineTerminator(font: bodyFont, paragraph: blankParagraph))
            case .cond(let lines):
                let label = "— .cp\(lines) —"
                output.append(markRun(label, paragraph: blankParagraph, spoken: "page break: .cp\(lines)"))
                output.append(lineTerminator(font: bodyFont, paragraph: blankParagraph))
            case .hf(let which, _, let text):
                // Job 371 item 3: the SAME content `renderModern`'s own OFF-state case
                // shows (invisibles ON never shows content OFF doesn't — job 300's ruling,
                // this function's own header doc comment), plus a faint "[header]"/
                // "[footer]" TAG ahead of it — "Modern Show Invisibles regains the header
                // tag" — so a person can tell running-head text apart from body text, the
                // same distinguishing role every other mark here already plays.
                guard !text.isEmpty else { continue }
                let tag = which == .header ? "[header] " : "[footer] "
                let line = NSMutableAttributedString(attributedString: markRun(
                    tag, paragraph: blankParagraph, spoken: which == .header ? "header" : "footer"))
                line.append(attributedLine(
                    [Span(text: text)], font: bodyFont, paragraph: blankParagraph,
                    fonts: doc.fonts, defaultSize: Int(size), useCourierPrime: true))
                output.append(line)
                output.append(lineTerminator(font: bodyFont, paragraph: blankParagraph))
            case .tabs:
                // Not rendered OFF either (`renderModern`'s own switch) — editor-time
                // state, no rendered consequence in either state.
                continue
            case .noteSeparator:
                // Job 423 (view item a/c): `renderModern`'s OFF state now renders the
                // note appendix (see that switch's own citation) — job 300's ruling
                // ("invisibles ON never shows content OFF doesn't") means ON must show the
                // SAME content, not silently hide it. No additional mark needed: the
                // `[label]` bracket already distinguishes a note from body text the same
                // way a mark would, so this is the identical OFF-state rendering, purely
                // additive to what was an empty `continue` before.
                appendNoteLine(String(repeating: "-", count: 20))
                // Job 452: footnotes print here, ahead of the endnote/annotation/comment
                // `.note` items that follow — same fix and same reasoning as `renderModern`'s
                // own `.noteSeparator` case (the engine's `noteKindOrder` puts footnotes
                // first).
                if !footnoteRows.isEmpty {
                    for (_, row) in footnoteRows {
                        appendNoteLine("\(Self.modernNoteEntryLabel(row.shown)) \(row.text)")
                    }
                    footnotesEmitted = true
                }
            case .note(_, _, let label, let text):
                // b34 N1 (job 529): same reasoning as `renderModern`'s identical citation
                // — this `text` is `SemanticItem.note`'s own construction-time snapshot,
                // not read from the `flow.notes` array mutated above.
                appendNoteLine("\(Self.modernNoteEntryLabel(label)) \(sentenceSpacingTexts([text])[0])")
            }
        }
        // Footnotes: same end-of-document appendix `renderModern`'s own OFF state builds
        // (see that function's citation on why `SemanticItem.para`'s `footnotes:` field
        // alone can't place them) — identical content, no extra mark, same reasoning as
        // `.noteSeparator`/`.note` just above. Job 452: reached only when the loop never hit
        // `.noteSeparator` — see `renderModern`'s identical citation.
        if !footnotesEmitted, !footnoteRows.isEmpty {
            if !items.contains(where: { if case .noteSeparator = $0 { return true }; return false }) {
                appendNoteLine(String(repeating: "-", count: 20))
            }
            for (_, row) in footnoteRows {
                appendNoteLine("\(Self.modernNoteEntryLabel(row.shown)) \(row.text)")
            }
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        // Same paper/margin choice as the plain Modern path (`renderModern`'s own doc
        // comment covers the reasoning) — Show Invisibles changes what's drawn, never the
        // page the user picked.
        let paper = state.pageSize.value?.sizeInPoints
            ?? CGSize(width: modernMetrics(doc).pageWidth, height: modernMetrics(doc).pageHeight)
        let margin: CGFloat = 72
        let textFrame = CGRect(
            x: margin, y: margin,
            width: max(1, paper.width - margin * 2),
            height: max(1, paper.height - margin * 2)
        )

        return RenderedDocument(
            text: output,
            pageSize: paper,
            textFrame: textFrame,
            pageCount: 1,
            clipsLines: false,
            // No physical soft-return ever reaches this stream (see this function's own
            // doc comment) — nothing for a caller to flag as one.
            softLineFlags: [],
            overprintPasses: [],
            oversizedSelfPasses: [],
            baselineOffset: 0,
            leadingHeadroom: [],
            runningLines: [],
            // Show Invisibles keeps `.hf` inline as a "[header]"/"[footer]"-tagged annotation
            // (this function's own `.hf` case above) — a DIFFERENT, screen-only purpose than
            // `renderModern`'s real per-page replay (job 393), so no replay log to hand back.
            hfEvents: [],
            pageNumberStart: 1,
            realPageIndexByPage: [0],
            // Job 412 (Jon's ruling): Modern is reflowed by design — explicitly NOT pinned.
            pinnedBaselines: [:],
            // Job 427: same flat, shared anchor as plain Modern's own construction site —
            // see that call site's own doc comment.
            perPageTextTop: [Double(textFrame.origin.y)],
            pinnedPageBottoms: [],
            // b28 note 11: Show Invisibles' Modern path never ported ANY of
            // `ModernScreenplay`'s rules (a pre-existing gap this job did not widen scope
            // to close — see `RenderedDocument.modernForcedPageBreakOffsets`'s own doc
            // comment) — nothing to record here.
            modernForcedPageBreakOffsets: [],
            // Show Invisibles' Modern path keeps footnotes folded into the SAME end-of-
            // document appendix real endnotes/annotations/comments use (this function's own
            // `.noteSeparator`/`.note` handling above, job 452) — job 490's per-marker
            // placement never applied here, so job 502's page-foot placement does not either;
            // see `modernForcedPageBreakOffsets`'s own comment just above for the identical
            // scope boundary.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            pclPrograms: []
        )
    }

    /// `CtrlKD.Alignment` (the block's own `.oc`/`.oj` state, `SemanticItem.para`'s `align`)
    /// to AppKit's paragraph-style enum — the same four cases `rtfAlignControl`
    /// (`EmitRTF.swift`) maps to `\ql`/`\qc`/`\qr`/`\qj`.
    private static func modernNSAlignment(_ align: Alignment) -> NSTextAlignment {
        switch align {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justify: return .justified
        }
    }

    // MARK: - Modern structure rules (M-rules addendum, def-list/bullet/centered)

    /// Character-range slice of styled spans, preserving each span's own attributes —
    /// the app-side port of the engine's internal (module-private) `sliceSpans`
    /// (`CtrlKD/EmitHTML.swift`), needed here because a def-list label/body or a
    /// spaces-centered line's own padding is sliced off the STYLED spans, not the
    /// plain joined text, so a bold/italic/font run inside the kept text survives.
    private static func sliceSpans(_ spans: [Span], start: Int, end: Int? = nil) -> [Span] {
        let total = spans.reduce(0) { $0 + $1.text.count }
        let end = end ?? total
        var out: [Span] = []
        var pos = 0
        for sp in spans {
            let chars = Array(sp.text)
            let spStart = pos, spEnd = pos + chars.count
            pos = spEnd
            let lo = max(start, spStart), hi = min(end, spEnd)
            if lo < hi {
                out.append(Span(text: String(chars[(lo - spStart)..<(hi - spStart)]), styles: sp.styles,
                                font: sp.font, colour: sp.colour, pctlHMI: sp.pctlHMI))
            }
        }
        return out
    }

    /// Strips a spaces-centered row's own leading/trailing padding off the styled
    /// spans — port of the engine's `htmlCenteredRow`. A no-op for a real
    /// `align=center` tag row: `modernSemanticFlow` already stripped that padding
    /// upstream (M3), so lead/trail are both 0 there.
    private static func centerStrippedSpans(_ spans: [Span]) -> [Span] {
        let raw = Array(spans.map(\.text).joined())
        var lead = 0
        while lead < raw.count, raw[lead] == " " { lead += 1 }
        var trail = 0
        while trail < raw.count, raw[raw.count - 1 - trail] == " " { trail += 1 }
        return sliceSpans(spans, start: lead, end: raw.count - trail)
    }

    /// A bullet row's own real text start — job 329/b21, Jon's field note on VERSIONS.WS's
    /// Sawyer-customizations bullets: "the line wrap doesn't line up with the first line
    /// after the • bullet." `structuredPrefixAndBody`'s marker+gap is always the same two
    /// characters (`"\u{2022} "`), but Modern's body font is PROPORTIONAL — this app's own
    /// font of the user's choice, not the library's fixed-pitch Courier — so those two
    /// characters' real advance width varies by font/size and almost never lands on a
    /// whole number of `colPt`-wide monospace cells. Job 299's original `bulletHangCols:
    /// 2` (a column count, like the def-list hang) assumed it would; it didn't, which is
    /// exactly the misalignment Jon's screenshot caught. Measured via `CTLine`'s real
    /// typographic advance — the same measurement style `inkTop` above already uses for
    /// glyph geometry — rather than a `NSAttributedString.size()` probe (this file's own
    /// job-240-era doc comment on `.size()` flags it as unreliable against real TextKit
    /// layout).
    private static func bulletMarkerWidthPt(font: NSFont) -> Double {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2022} ", attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// The indent LADDER's one step (job 299, Jon's field report on VERSIONS.WS/
    /// CONVERT.WS): how far EACH nesting level sits past the one above it, in WordStar
    /// print columns (the same `colPt` conversion every other Modern indent uses). Level
    /// 1 (outermost) sits at the 1in margin (`ladderIndentCols` at the call site is 0
    /// there); a level-2 row sits `levelStepCols` past that, and so on — one constant,
    /// so a nested def-list under a bullet (CONVERT.WS's WSASC/WSOLD/ASCWS) always reads
    /// as a clearly deeper level regardless of what raw column the source document
    /// happened to use for either row. 4 columns (~0.4in at the library's default 12cpi)
    /// is comfortably wider than the 1-2 column gap the raw-column bug was producing
    /// (CONVERT.WS's nested rows sat a single column past their parent bullet) while
    /// staying short of `defHangCols`-scale hang indents that would read as a second
    /// column of body text rather than a nesting step.
    private static let levelStepCols: Double = 4

    /// The marker/label prefix and the body spans for one classified bullet/def row —
    /// port of `EmitHTML.swift`'s own per-kind slicing (a bullet's body is
    /// `raw.count - bodyLen...`; a def's label is `lead..<lead+labelLen`, its body
    /// `raw.count - bodyLen...`). The marker glyph itself is replaced with a plain
    /// bullet (U+2022) rather than the document's own glyph — Modern is a reading
    /// view, and HTML makes the identical substitution: a real `<li>`'s marker comes
    /// from its own CSS `list-style`, never `RowStructure.marker` (`_render_list_nodes`
    /// never reads it).
    private static func structuredPrefixAndBody(
        kind: RowStructureKind, structure: RowStructure, spans: [Span]
    ) -> (prefix: [Span], body: [Span]) {
        let raw = Array(spans.map(\.text).joined())
        switch kind {
        case .bullet:
            let bodyLen = structure.body?.count ?? 0
            let body = sliceSpans(spans, start: raw.count - bodyLen, end: nil)
            return ([Span(text: "\u{2022} ")], body)
        case .def:
            var lead = 0
            while lead < raw.count, raw[lead] == " " { lead += 1 }
            let labelLen = structure.label?.count ?? 0
            let bodyLen = structure.body?.count ?? 0
            let label = sliceSpans(spans, start: lead, end: lead + labelLen)
            let body = sliceSpans(spans, start: raw.count - bodyLen, end: nil)
            return (label + [Span(text: "  ")], body)
        }
    }

    // MARK: - Running heads and feet

    /// Port of `runningOps`'s GEOMETRY (`CtrlKD/PDFWriter.swift:177-238`) — not its PDF byte
    /// emission, which stays engine-only. `runningOps` itself is `internal`, so this reads the
    /// same public inputs it does (`Page.headers`/`.footers`, `Document.page`'s `mtLines`/
    /// `hmLines`/`plLines`/`mbLines`/`fmLines`) and reproduces its two placement formulas:
    ///
    /// - Header: anchored to the BODY, not the paper edge — its last line sits `.hm` lines
    ///   above the first body line, inside `.mt` (`PDFWriter.swift:216-226`).
    ///   `headBase = max(0, mt - hm - topHead)`, `topHead` = the highest header line number
    ///   in use.
    /// - Footer: `.fm` lines below the body, at `footLine = pl - mb + fm`
    ///   (`PDFWriter.swift:233`).
    ///
    /// Both then place line `n` at `n * lead + size` points below the paper's top edge — the
    /// app's own top-down convention, converted from the engine's bottom-up
    /// `y = pageHeight - line*lead - size` (`PDFWriter.swift:207`) via `pageHeight - y`.
    ///
    /// `#` -> page number, same token `runningOps`'s own `render(_:)` substitutes
    /// (`PDFWriter.swift:198-205`).
    ///
    /// The three WordStar-spec fallback constants (66/8/2 lines) are the SAME literals
    /// `runningOps` falls back to for a bare print stream with no `Document.page`
    /// (`defaultPlLines`/`defaultMbLines` in `ParseWS.swift`, and `doc.page?.fmLines ?? 2`
    /// in `PDFWriter.swift:194`) — spec constants, not derived engine arithmetic, so vendoring
    /// them here carries none of the `spanPitch`/`tzScale` drift risk this file's other doc
    /// comments warn about.
    private static func runningLines(
        for page: Page, pageNo: Int, doc: Document, metrics: PrintedPageMetrics
    ) -> [RunningLine] {
        guard !(page.headers.isEmpty && page.footers.isEmpty) else { return [] }

        // Job 240 (b13, Part 1): the cp1252 esc-degradation this used to chain
        // (`printedEscDegrade`) is gone — MAC VIEWING RULING, see that removal's own doc
        // comment above. `printedStripControlChars` stays: that is a genuine control-byte
        // display fix (job 226), unrelated to font-encoding floors.
        func rendered(_ text: String) -> String {
            printedStripControlChars(text.replacingOccurrences(of: "#", with: String(pageNo)))
        }
        let font = courier(size: CGFloat(metrics.size))
        // Job 228: the AppKit-measured distance from a `draw(at:)` origin to that call's
        // actual first baseline, for exactly the font and (absent — see `line` below)
        // paragraph style a running line is built with. `RunningLine.drawOriginOffset`'s own
        // doc comment has the citation; measured once per page since it depends only on
        // `font`, not on any one header/footer's text.
        let drawOriginOffset = Double(firstBaselineOffset(
            font: font, paragraph: NSParagraphStyle(),
            width: max(1, metrics.pageWidth - metrics.left)))
        // Job 226: `nil` when the SOURCE text was entirely print-control bytes (LJ6DTP.WS's
        // own footer, `"\u{0F}\u{0F}"` — two rule-drawing controls, no visible content at
        // all) — `printedStripControlChars` degrades that to `""`, and `PagedDocumentView
        // .drawRunningLines` reads `.attribute(.font, at: 0, ...)` unconditionally, which
        // traps on a zero-length attributed string. A running line with nothing left to
        // show is exactly a running line that should not exist, matching the engine's own
        // behaviour (`runningOps`'s `op(_:line:)` still emits a — invisible — `Tj` for it,
        // but an empty string here is the same "draws nothing" outcome without the trap).
        // Job 429 (`NativeVsEngineGeometryTests`' own margin gate, YOURWAY.WS's proving
        // failure — `.lh 18` is the fixture's whole point): `lineLead` used to be
        // `metrics.lead` (the document's own `.lh`-derived BODY lead) unconditionally for
        // both kinds. The engine's own `runningOps` (`PDFWriter.swift:301-330`) uses a
        // DIFFERENT unit per kind: the header's `op(txt, line:lead:)` call passes the FIXED
        // `PDFMetrics.lead` (12pt, 6 LPI — `.mt`/`.hm` are LINE-COUNT dot commands "always at
        // the FIXED 6 LPI (12pt) baseline... a SEPARATE unit from `.lh`", that citation's own
        // words), while the footer's call passes the real `lead` parameter (the document's
        // own body lead) — an intentional, documented asymmetry, not an oversight. This
        // function's own header call site duplicated the WRONG half of that split (the real
        // `.lh`-derived lead, matching the engine's FOOTER unit) — invisible on every fixture
        // whose `.lh` happens to already be 12pt (`PDFMetrics.lead`'s own value), exactly the
        // condition the engine's own citation names as why this bug class hides "until
        // [a fixture] whose own `.lh` is customized" surfaces it. Confirmed against real
        // `emitPDF` bytes (`EngineTruth.structuralPages`, `PrintedStructuralParityTests.swift`)
        // via `NativeVsEngineGeometryTests.marginsMatchTheEngine`: YOURWAY.WS's own header
        // (`.lh 18`, `headBase` 2 lines) sat exactly `2 * (18 - 12) = 12.0pt` too low on every
        // page but the first.
        // Job 489 (b29 adoption, register C6): the resolved face for a `.h#`/`.f#` line
        // that opened with its own WS5+ font block — mirrors the engine's `hfLineOps`
        // (`PDFWriter.swift`): toggle-byte-interpreted runs, a PROPORTIONAL font's leading
        // whitespace re-stamped onto the document's own Courier column grid (never drawn
        // in the proportional face, exactly `appendSpan`'s own body-text indent carve-out),
        // and every other run drawn in the resolved face with that run's own bold/italic.
        // Returns `nil` for a line with nothing left to draw once toggles are consumed
        // (`printedHeadFootRuns`' own empty-runs case).
        func styledLine(_ rawText: String, entry: FontChange) -> (text: NSAttributedString, leadingOffset: Double, drawOriginOffset: Double)? {
            let substituted = rawText.replacingOccurrences(of: "#", with: String(pageNo))
            let runs = printedHeadFootRuns(substituted)
            guard !runs.isEmpty else { return nil }
            let result = NSMutableAttributedString()
            var leadingOffset: Double = 0
            var stillLeading = true
            for run in runs {
                let text = printedStripControlChars(run.text)
                guard !text.isEmpty else { continue }
                if stillLeading, entry.proportional, text.trimmingCharacters(in: .whitespaces).isEmpty {
                    leadingOffset += NSAttributedString(string: text, attributes: [.font: font]).size().width
                    continue
                }
                stillLeading = false
                let runFont = resolvedFont(for: entry, styles: run.styles, fallback: font,
                                           defaultSize: metrics.size, useCourierPrime: true)
                result.append(NSAttributedString(string: text, attributes: [
                    .font: runFont, .foregroundColor: NSColor.black, .kern: printedNoKerning,
                ]))
            }
            guard result.length > 0 else { return nil }
            let resolvedBase = resolvedFont(for: entry, styles: [], fallback: font,
                                            defaultSize: metrics.size, useCourierPrime: true)
            let originOffset = Double(firstBaselineOffset(
                font: resolvedBase, paragraph: NSParagraphStyle(),
                width: max(1, metrics.pageWidth - metrics.left)))
            return (result, leadingOffset, originOffset)
        }

        // Job 489/490 tried a matching `baseline <= metrics.pageHeight` guard here (mirroring
        // the engine's own `runningOps`, `PDFWriter.swift`, `guard y >= 0 else { continue }` —
        // a running line whose baseline would land past the bottom of the sheet never gets a
        // `Tj` at all) and reverted it: measured against `PrintedStructuralParityTests`'
        // `EngineTruth` at the time, it "fixed 6 of LJ6DTP's own known divergent slots but
        // silently introduced 2 NEW ones (pages 7/8's own footer, previously agreeing, now
        // wrongly suppressed)".
        //
        // Job 491 root-caused THAT measurement itself as corrupted: `EngineTruth
        // .contentStreams` (`PrintedStructuralParityTests.swift`) assumed only page-content
        // objects carry a `stream`/`endstream` pair, which is false for any LJ6DTP-driver
        // fixture — the driver's own 6 HP1-HP6 tiling patterns (`PDFWriter.swift`'s
        // `patternObjs`, register C3) ALSO carry one, at LOWER object numbers than any page,
        // so they sorted first in the real PDF and silently shifted job-489/490's "page 7/8"
        // reads to genuinely page 1/2's own content. With that harness bug fixed, the
        // engine's real per-page running-head X/Y (parsed straight from the real, correctly
        // page-aligned `emitPDF` bytes) is IDENTICAL to what this function already computes
        // on every page of LJ6DTP.WS — `NativeVsEngineGeometryTests.marginsMatchTheEngine`
        // went from 1 failure to 0 (46/46) from the harness fix ALONE, no production code
        // changed. The guard below is reintroduced NOW, against that corrected baseline, and
        // the full suite (see this job's report) shows it introduces no new divergence.
        func line(_ text: String, atLine n: Double, lineNo: Int, kind: RunningLine.Kind) -> RunningLine? {
            let lineLead = kind == .header ? Double(PDFMetrics.lead) : metrics.lead
            let baseline = n * lineLead + Double(metrics.size)
            guard baseline <= metrics.pageHeight else { return nil }
            let fontIdx = kind == .header ? doc.headerFonts[lineNo] : doc.footerFonts[lineNo]
            let entry = fontIdx.flatMap { doc.fonts.indices.contains($0) ? doc.fonts[$0] : nil }
            if let entry, let styled = styledLine(text, entry: entry) {
                return RunningLine(text: styled.text, baselineFromTop: baseline,
                                   drawOriginOffset: styled.drawOriginOffset, kind: kind,
                                   leadingOffset: styled.leadingOffset)
            }
            let degraded = rendered(text)
            guard !degraded.isEmpty else { return nil }
            // No `.paragraphStyle` attribute — matches `drawOriginOffset`'s own measurement,
            // which uses the same absence (`NSParagraphStyle()`, unconstrained) rather than
            // the body text's lead-pinned style; a running line is drawn at its own natural
            // single-line height, never clamped to the document's `.lead` grid.
            let attributed = NSAttributedString(string: degraded, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .kern: printedNoKerning,
            ])
            return RunningLine(text: attributed, baselineFromTop: baseline,
                               drawOriginOffset: drawOriginOffset, kind: kind)
        }

        let mt = doc.page?.mtLines ?? 3.0
        // Job 425 (b26 wave-2 pin, `Provenance.machineDefault` fix — engine commit 45b9726,
        // PDFWriter.swift: "hm's participation is keyed on mtSource, not hmSource" — see that
        // commit's own extensive citation table): `hm` only subtracts from the header's own
        // base line when `.mt` was DECLARED IN THE FILE ITSELF (`mtSource == .file`) — a
        // preset-applied or factory-default `.mt` (`.default`/`.machineDefault`) leaves `hm`
        // out entirely, regardless of `hm`'s own provenance. Previously unconditional here —
        // invisible on every fixture whose `.mt` happened to be file-declared, wrong the
        // moment a preset (or a factory default) supplies it instead; the running head sat a
        // whole `hm` (2 lines, 24pt) too high. Confirmed against the engine's real emitPDF for
        // OLDTIMES.WS (bare AND sawyer-preset both moved 24pt when this pin landed).
        let hm = doc.page?.mtSource == .file ? (doc.page?.hmLines ?? 2.0) : 0.0
        let topHead = Double(page.headers.keys.max() ?? 1)
        let headBase = max(0.0, mt - hm - topHead)

        let pl = doc.page?.plLines ?? 66.0
        let mb = doc.page?.mbLines ?? 8.0
        let fm = doc.page?.fmLines ?? 2.0
        let footLine = pl - mb + fm

        var out: [RunningLine] = []
        for n in page.headers.keys.sorted() {
            guard let text = page.headers[n], !text.isEmpty else { continue }
            if let built = line(text, atLine: headBase + Double(n - 1), lineNo: n, kind: .header) { out.append(built) }
        }
        for n in page.footers.keys.sorted() {
            guard let text = page.footers[n], !text.isEmpty else { continue }
            if let built = line(text, atLine: footLine + Double(n - 1), lineNo: n, kind: .footer) { out.append(built) }
        }
        return out
    }

    /// Modern's own per-page running head/foot geometry (job 393, 391 root cause 2) — the
    /// app-side analog of `runningLines(for:pageNo:doc:metrics:)` above, but resolved from
    /// `HFEvent`s replayed against a REAL AppKit page boundary rather than an engine `Page`,
    /// because Modern's own page breaks are not known until `PagedDocumentView` lays the flow
    /// out (`RenderedDocument.hfEvents`'s own doc comment). `PagedDocumentView` calls this
    /// once per real page, passing that page's own first character offset — everything before
    /// it (`event.charOffset <= offset`) is "in force," mirroring `modernStreams`'s own
    /// `openPage()`: the state a page opens with is whatever was true when it took its first
    /// content, and a later `.hf` on that SAME page (after `offset`) does not apply until the
    /// next one.
    ///
    /// Placement matches `PDFModernLayout.swift`'s own `modernStreams` exactly: Times at its
    /// `modernNotePt` (11 — internal to the engine module, so vendored here as a literal, same
    /// "cite the source line, don't import the constant" discipline `runningLines` above
    /// already follows for its own Printed literals), header lines walking down from 44pt off
    /// the top edge, footer lines up from 44pt off the bottom (floored at 8pt so a document
    /// with many footer lines can't push one off the page) — `PDFModernLayout.swift:518-532`.
    internal static func modernRunningLines(
        events: [HFEvent], upToOffset offset: Int, pageNo: Int, pageHeight: Double
    ) -> [RunningLine] {
        var headers: [Int: String] = [:]
        var footers: [Int: String] = [:]
        for event in events where event.charOffset <= offset {
            if event.kind == .header { headers[event.line] = event.text } else { footers[event.line] = event.text }
        }
        guard !(headers.isEmpty && footers.isEmpty) else { return [] }

        let size: CGFloat = 11
        let font = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        let noteLead = 1.2 * Double(size)
        let drawOriginOffset = Double(firstBaselineOffset(
            font: font, paragraph: NSParagraphStyle(), width: 500))

        func rendered(_ text: String) -> String {
            printedStripControlChars(text.replacingOccurrences(of: "#", with: String(pageNo)))
        }
        func line(_ text: String, baselineFromTop: Double, kind: RunningLine.Kind) -> RunningLine? {
            let degraded = rendered(text)
            guard !degraded.isEmpty else { return nil }
            let attributed = NSAttributedString(string: degraded, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
            return RunningLine(text: attributed, baselineFromTop: baselineFromTop,
                               drawOriginOffset: drawOriginOffset, kind: kind)
        }

        var out: [RunningLine] = []
        for n in headers.keys.sorted() {
            guard let text = headers[n] else { continue }
            if let built = line(text, baselineFromTop: 44.0 + Double(n - 1) * noteLead, kind: .header) {
                out.append(built)
            }
        }
        for n in footers.keys.sorted() {
            guard let text = footers[n] else { continue }
            let fromBottom = max(8.0, 44.0 - Double(n - 1) * noteLead)
            if let built = line(text, baselineFromTop: pageHeight - fromBottom, kind: .footer) {
                out.append(built)
            }
        }
        return out
    }

    // MARK: - Line terminators and the first baseline

    /// A newline carrying the SAME font and paragraph style as the line it ends.
    ///
    /// An unattributed `"\n"` takes the system default font and default paragraph style. On
    /// a line that carries text this mostly does not show, because the run's own attributes
    /// govern the fragment. On a BLANK line the newline is the only character there is, so
    /// the whole line becomes system-height — roughly 15-17pt instead of the document's 12pt
    /// lead. Every blank line then pushes the rest of the page down, the baseline grid breaks
    /// at the first one, and a page consumes more than `capacity * lead` points.
    ///
    /// A document that opens with blank lines — the dropped-chapter shape — is the worst
    /// case, and `dropped-chapter.ws4` exists to hold this fixed.
    private static func lineTerminator(font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            // Job 478 audit: same white-paper/dynamic-colour class as the note-entry
            // defect this job fixes. A "\n" control character paints no visible glyph
            // regardless of colour, so this was never the VISIBLE bug — but it shares
            // every caller (renderPrinted and both Modern renderers) with attributed
            // runs that DO paint ink, so fixed here too rather than left as a dynamic
            // colour sitting on paper waiting for AppKit to someday give it ink.
            .foregroundColor: NSColor.black,
        ])
    }

    /// How far below a line fragment's top edge AppKit will put the first baseline, for this
    /// font and paragraph style.
    ///
    /// Measured by laying out one glyph and asking the layout manager, rather than computed
    /// from `ascent` or from the lead. With a fixed line height (min == max) the figure is a
    /// function of both the font and that height, and AppKit is the only authority on the
    /// result — deriving it by hand is what produced a 3pt error on every document.
    private static func firstBaselineOffset(
        font: NSFont, paragraph: NSParagraphStyle, width: CGFloat
    ) -> CGFloat {
        let storage = NSTextStorage(string: "X", attributes: [
            .font: font, .paragraphStyle: paragraph,
        ])
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return font.ascender }
        return manager.location(forGlyphAt: 0).y
    }

    /// Job 412: `firstBaselineOffset`'s own technique (lay it out, ask the layout manager,
    /// never derive by hand), generalized to REAL content instead of a fixed "X" placeholder
    /// — the isolated baseline-from-fragment-top offset (`K`) for one specific fragment's
    /// own real text/paragraph style, used only by `RenderedDocument.pinnedPageBottoms` to
    /// size a page's real container correctly (see that field's own doc comment for why a
    /// page's last fragment needs its OWN measured `K`, not a shared/assumed one).
    private static func isolatedFragmentK(_ content: NSAttributedString, width: CGFloat) -> Double {
        let storage = NSTextStorage(attributedString: content)
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return 0 }
        return Double(manager.location(forGlyphAt: 0).y)
    }

    /// Job 413: how far `Oracle.structuralBodyLines`' own sampled position for this line
    /// (`PrintedStructuralParityTests.swift` — the FIRST non-whitespace glyph's real
    /// `location(forGlyphAt:)`) will be pulled off this line's own pinned grid target by
    /// that glyph's `.sup`/`.sub` visual raise, and therefore how much needs folding into
    /// `PinnedBaseline.y` (never into `engineY`'s own running per-page accumulator) to
    /// cancel it. 0 when the first non-whitespace span carries neither.
    ///
    /// Root cause (DARKNESS.WS's own footnote-marker residual, job 412's disclosed "not
    /// further diagnosed" gap): a fragment whose OWN first content is a raised run — e.g. a
    /// standalone `.fnref` marker line — has its ONE sampled glyph physically shifted by
    /// `attributedRun`'s own `scriptMetrics` call (a real `.baselineOffset` ATTRIBUTE on
    /// that glyph, distinct from the FRAGMENT-level `baselineOffset` OUT-PARAM `PagedDocument
    /// View`'s delegate controls). Pinning the fragment's own unraised reference exactly on
    /// the grid (job 412's original mechanism) is therefore not what lands the OBSERVED,
    /// raised glyph on the grid — it lands `scriptMetrics`'s own offset SHORT of it, every
    /// time, which is exactly the constant-looking residual job 412 measured and did not
    /// chase further.
    ///
    /// This is the SAME split the engine's own emitter already makes (the brief's own
    /// citation — see `PDFWriter.sized`, `CtrlKD` source): a raised/lowered span's `rise` is
    /// a `Ts` PDF operator applied WITHIN a line whose own `Td` (position) never moves for
    /// it — the LINE anchors to the grid, the GLYPH moves within it. Reusing `scriptMetrics`
    /// itself (rather than measuring the shift via a fresh isolated AppKit layout pass, the
    /// way `isolatedFragmentK` does elsewhere in this file) is deliberate: this value must
    /// equal EXACTLY what `attributedRun` bakes into the real glyph's own attribute — not a
    /// separately-measured approximation of it — for the two to cancel with no residual.
    /// `scriptMetrics` is pure font-metrics arithmetic (`NSFont.ascender`, no layout pass,
    /// no window), so both this figure and the value it cancels are already
    /// process-independent — computing it this way rather than asking AppKit to lay
    /// anything out is what makes it exact rather than merely close, unlike `isolatedFragmentK`'s
    /// own well-known ~1pt isolated-vs-in-context slop (job 408).
    private static func firstGlyphRaiseCompensation(
        _ line: PageLine, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool
    ) -> Double {
        guard let span = line.spans.first(where: {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }), span.styles.contains(.sup) || span.styles.contains(.sub) else { return 0 }
        let font = resolvedFont(for: span, fallback: fallback, fonts: fonts,
                                defaultSize: defaultSize, useCourierPrime: useCourierPrime)
        return Double(scriptMetrics(for: font, raise: span.styles.contains(.sup)).offset)
    }

    // MARK: - Spans to attributed text

    /// One span appended to `line`, threading the leading-indent gate the CALLER's whole
    /// line shares — extracted from `attributedLine`'s own per-span loop (job 256, Show
    /// Invisibles part 2/4: `renderPrintedAnnotated` needed this same per-span logic
    /// available to call once per `.visible` `AnnotatedSpan`, interleaved with its own
    /// invisible-mark runs, rather than duplicating it). Pure extraction — every existing
    /// `attributedLine` caller's behavior is unchanged; `showInvisiblesOffStateByteIdentical`
    /// and the oracle/structural-parity gates are what verify that.
    private static func appendSpan(
        _ span: Span, to line: NSMutableAttributedString, leading: inout Bool,
        font: NSFont, paragraph: NSParagraphStyle, fonts: [FontChange], defaultSize: Int,
        colourMap: [Int: Double], disableKerning: Bool, useCourierPrime: Bool = false,
        pixResults: [PixResult] = [], pixMeasureWidthPt: Double = 0
    ) {
        // Job 371 item 1 (PIX IN VIEWS): a resolved `.PIX` tag, INLINE — the shape Modern's
        // own reflow keeps `span.pix` in (unlike Printed, whose `docToPagelines` already
        // substituted a whole `PageLine.image` before any span reaches here — see
        // `lineAndTerminator`'s own doc comment). An unresolved tag (`ok == false`, or the
        // index missing from `pixResults` entirely — a caller that never resolved anything)
        // falls straight through to the plain-text branch below, which renders the span's
        // own literal "[image: NAME]" placeholder — "missing image = placeholder text,
        // never an error" (job 371's own brief, restating the 2026-08-17 ruling).
        //
        // `span.pix ?? Self.inferredPixIndex(...)`: `modernSemanticFlow`'s own `SemanticRun`
        // (`Layout.swift`, CtrlKD) carries no `pix` field at all — text/styles/font/colour/
        // ref only — so `modernParagraphContent`'s `Span(text:styles:font:colour:)`
        // reconstruction (this file) can never set `pix` for a Modern span, even though the
        // run's OWN text is still the exact same "[image: NAME]" placeholder the parser
        // wrote. Rather than porting a `pix` field onto `SemanticRun` in the engine repo
        // (no push access there — see `DocumentPictures.resolve`'s own header), this reads
        // the same NAME straight back out of the placeholder text `appendSpan` is about to
        // render anyway and matches it against `pixResults` by basename
        // (`pixBasename(rawPath)`, the identical string `SymmetricBlocks.swift`'s own
        // placeholder-building used to construct it) — the addressability the field would
        // have given directly, recovered from the one place it still exists.
        let pixIndex = span.pix ?? Self.inferredPixIndex(fromPlaceholderText: span.text, pixResults: pixResults)
        if let pixIndex, pixResults.indices.contains(pixIndex), pixResults[pixIndex].ok {
            let (wPt, hPt) = pixDimsPt(pixResults[pixIndex], measureWidthPt: pixMeasureWidthPt)
            line.append(Self.pixAttachmentString(
                pixResults, index: pixIndex, widthPt: wPt, heightPt: hPt, paragraph: paragraph))
            leading = false
            return
        }
        // M10, ported from `PDFWriter.lineOpsPrinted` (`PDFWriter.swift:466-475`): a
        // 0x0F user print control's display string is SCREEN-ONLY — on paper WordStar
        // sent the printer its raw control payload, never the human-readable string
        // (`Shaded Relative -00.250"...`, `Empty |00.300"hx...`) the parser decoded for
        // display. The engine draws nothing and advances by the block's own declared
        // HMI width; this is the FIRST check per span there, ahead of font/colour/
        // graphics handling, because a pctl span never carries any of those. Same
        // order here, same reason: this app was drawing the raw display string as
        // literal paper content instead of skipping it (Jon's b11 field evidence).
        if let hmi = span.pctlHMI {
            line.append(Self.pctlAdvanceAttachment(hmi: hmi, pcl: span.pcl, paragraph: paragraph))
            return
        }
        // Job 503 item 1: `Span.tabHMI` — a REAL WordStar tab stop (a type-9 block, parsed
        // straight off the file — `ParseWS.swift`'s own citation), carrying its ABSOLUTE
        // target in HMI (1/1800in) FROM THE LINE'S OWN LEFT MARGIN. Never consumed by this
        // renderer before this job — every "column" symptom job 490/491 chased (table rows
        // that don't line up, the LJ6DTP masthead's shadow sitting at the wrong offset, the
        // checkerboard's 18pt-in-the-engine cell pitch, the flush-right overprint bars) is
        // WordStar authoring its OWN real tab stops, not literal typed filler spaces —
        // confirmed directly against this fixture (`outbox/job503/scratch-title-dump.txt`,
        // since discarded): the masthead's two "leading space" spans measured
        // `tabHMI=2414`/`2502` — `2414/25=96.56pt`, `+50.4pt` margin `=146.96`, matching the
        // pinned engine's own PDF `Td` x `147.0` to within decipoint rounding — and the
        // checkerboard's 33 two-space separators are ALL `tabHMI`-marked at steps of 450
        // (`450/25=18.0pt`, the engine's own real cell pitch, not this app's previous
        // 14.4pt). `appendProportionalRun`'s space/period-run "10-CPI grid" heuristic
        // (job 490) approximated the same INTENT by counting literal characters — wrong
        // whenever the real target (this field) doesn't land on a whole grid multiple,
        // which is most of the time. Checked ahead of that heuristic (and of the
        // leading-indent special case just below, which this field's own presence already
        // supersedes) — same order `PDFWriter.swift`'s `lineOpsPrinted` checks it in,
        // right after `pctlHMI`.
        if let tabHMI = span.tabHMI {
            Self.appendTabRun(span, tabHMI: tabHMI, font: font, paragraph: paragraph, fonts: fonts,
                              defaultSize: defaultSize, colourMap: colourMap,
                              useCourierPrime: useCourierPrime, to: line)
            if span.text.contains(where: { !$0.isWhitespace }) {
                leading = false
            }
            return
        }
        // A PROPORTIONAL WS5+ font run's LEADING spaces are WordStar's own indent
        // positioning, re-stamped onto the document's fixed 10-CPI column grid rather
        // than the run's own (narrower) proportional advance — `PDFWriter.swift`'s own
        // doc comment on `splitIndent`: "WordStar re-stamps a left indent... as
        // machine spaces, and every one of those commands is specified in 10-CPI print
        // columns." `courier(size:)` at the document's base size already advances at
        // exactly that grid (10 CPI = `size * 0.6`pt/char, this file's own
        // `PDFMetrics`-matching convention), so rendering just the leading-space
        // PREFIX in `font` — the document's base Courier passed into this function,
        // not `resolvedFont`'s proportional face — reproduces the engine's
        // `Double(seg.text.width) * Double(size) * 0.6` indent width (`PDFWriter.swift:541`)
        // by construction, with no separate width arithmetic needed here. This is
        // Jon's field symptom (title/author/awards sitting left of the engine's
        // placement on `OLDTIMES.WS` p1) — the proportional font's own narrower space
        // advance was carrying the indent instead of the document's column grid.
        //
        // Gated the same way the engine gates it: only while `leading` (nothing real
        // has printed yet on this line) and only for a run with a PROPORTIONAL font
        // block. A fixed-pitch block's own space already sits on the document's grid
        // (`PDFWriter.swift`'s own note: "For 10-CPI Courier the two measures are the
        // same number"), and a fontless span's pitch already IS the document's — both
        // already correct under `resolvedFont`'s plain advance, so neither is split.
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        if leading, let entry, entry.proportional {
            let pad = span.text.prefix(while: { $0 == " " }).count
            if pad > 0 {
                var indentAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraph,
                ]
                indentAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
                if disableKerning { indentAttributes[.kern] = printedNoKerning }
                line.append(NSAttributedString(
                    string: String(span.text.prefix(pad)), attributes: indentAttributes))
                if pad == span.text.count {
                    // The WHOLE run was leading whitespace — still leading, exactly
                    // like `splitIndent`'s own `else` branch (a later span may carry
                    // more of the same line's indent before real content arrives).
                    return
                }
                let rest = Span(text: String(span.text.dropFirst(pad)), styles: span.styles,
                                font: span.font, colour: span.colour, pctlHMI: span.pctlHMI)
                Self.appendProportionalRun(
                    rest, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                    colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                    to: line)
                leading = false
                return
            }
        }
        if let entry, entry.proportional {
            Self.appendProportionalRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                to: line)
        } else {
            line.append(Self.attributedRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime))
        }
        if span.text.contains(where: { !$0.isWhitespace }) {
            leading = false
        }
    }

    /// Job 490 item 2 (Jon: "Make sure that all columns in tables line up. They're all
    /// over the place right now" — confirmed against real WS7's `LJ6DTP-p3.png`: the
    /// reference has every column dead-aligned, ours drifts). WordStar authors a table by
    /// typing runs of literal spaces to reach the next column, on the file's own fixed
    /// 10-CPI character grid — under a PROPORTIONAL Mac font substitute, a run of N literal
    /// spaces measures narrower than the N grid CELLS the author actually counted, and by a
    /// DIFFERENT amount per row (the text preceding the run varies), so two rows whose
    /// author-typed column position was IDENTICAL drift apart on screen. `PDFWriter.swift`'s
    /// own `splitIndent` already re-stamps a LINE's LEADING space run onto the document's
    /// own Courier grid (`font`, this file's `size * 0.6`pt/char convention) instead of the
    /// proportional face's own advance (the `if leading, let entry, entry.proportional`
    /// block above, job 202) — this is that SAME re-stamp, generalized to any run of 2+
    /// consecutive column FILLER characters (`isColumnFillerChar`: a space, or — p5's
    /// dot-leader rows, `"Shading 85%................"` — a period) ANYWHERE in a
    /// proportional span, not just the line-initial one.
    ///
    /// A run of exactly ONE space is left untouched, laying out at the resolved font's own
    /// natural advance like ordinary prose — the MAC VIEWING RULING (job 240, `attributedRun`'s
    /// own doc comment) removed PER-WORD corrective kerning specifically so single-space-
    /// separated prose keeps reading naturally, and this does not reopen that: a genuine
    /// inter-word gap is one space, so it never qualifies. Two-or-more is the signal a human
    /// typed deliberate column padding, not a sentence — the same signal a monospace-authored
    /// document already gives a reader.
    ///
    /// Applies identically to Native and (this app's own on-screen/export) Printed, which
    /// share this function — see `resolvedFont`'s own doc comment ("Native only changes
    /// fonts. Otherwise it's the same as Printed", job 427's ruling). Measured directly
    /// (job 490): both currently show the IDENTICAL drift on `LJ6DTP.WS` p3/p5, since neither
    /// applied any re-stamping past the leading run — the true byte-exact reference PDF
    /// (`CtrlKD`'s own `PDFWriter.emitPDF`, a separate code path this app never renders
    /// through on screen) is what already gets this right; this app's own two AppKit
    /// renderers did not, equally.
    private static func appendProportionalRun(
        _ span: Span, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double],
        disableKerning: Bool, useCourierPrime: Bool, to line: NSMutableAttributedString
    ) {
        let segments = Self.splitOnColumnSpaceRuns(span.text)
        guard segments.count > 1 || segments.first?.isGrid == true else {
            line.append(Self.attributedRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime))
            return
        }
        for segment in segments where !segment.text.isEmpty {
            if segment.isGrid {
                var gridAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraph,
                ]
                gridAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
                if disableKerning { gridAttributes[.kern] = printedNoKerning }
                line.append(NSAttributedString(string: segment.text, attributes: gridAttributes))
            } else {
                let piece = Span(text: segment.text, styles: span.styles, font: span.font,
                                 colour: span.colour, pctlHMI: span.pctlHMI)
                line.append(Self.attributedRun(
                    piece, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                    colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime))
            }
        }
    }

    /// A WordStar column filler character — a plain space, or (LJ6DTP p5's "Color Mappings"
    /// chart: `"Shading 85%................"`) a dot-leader period.
    private static func isColumnFillerChar(_ c: Character) -> Bool { c == " " || c == "." }

    /// Splits `text` on every MAXIMAL run of 2+ consecutive occurrences of the SAME filler
    /// character (see `isColumnFillerChar`) — see `appendProportionalRun`'s own doc comment
    /// for why 2 is the threshold. A run never MIXES spaces and periods: ordinary prose
    /// punctuation (a sentence-ending period followed by the typewriter convention's own
    /// two spaces, `". "` × 2 — common throughout this proportional-font corpus) is one
    /// single, un-grid-stamped period immediately followed by its OWN 2-space grid run, not
    /// one merged three-character leader — merging them was tried and measured to visibly
    /// distort ordinary sentence punctuation across the whole document (the period itself
    /// landing at the Courier grid's width, not its own proportional face's), so runs are
    /// homogeneous by construction: `j` only extends while it keeps seeing the SAME
    /// character `chars[i]` started with. Order-preserving; a segment is never empty except
    /// possibly a leading/trailing one, which `appendProportionalRun`'s own
    /// `where !segment.text.isEmpty` filter skips.
    /// Internal rather than `private` (same rationale as `lineExceedsFragment`'s own doc
    /// comment) so `SoftReturnTests` can pin this splitter's exact segmenting behaviour
    /// directly, including the homogeneous-run regression guard described above.
    static func splitOnColumnSpaceRuns(_ text: String) -> [(text: String, isGrid: Bool)] {
        var result: [(text: String, isGrid: Bool)] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if Self.isColumnFillerChar(chars[i]) {
                let filler = chars[i]
                var j = i
                while j < chars.count, chars[j] == filler { j += 1 }
                let runLength = j - i
                if runLength >= 2 {
                    if !current.isEmpty { result.append((current, false)); current = "" }
                    result.append((String(chars[i..<j]), true))
                } else {
                    current.append(chars[i])
                }
                i = j
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        if !current.isEmpty { result.append((current, false)) }
        return result
    }

    /// One laid-out line's spans as styled text.
    ///
    /// Internal rather than `private` so `SoftReturnTests` can exercise the mark-rendering
    /// fix below directly, against real `Span`/`Style` values, without round-tripping a
    /// footnote through the WS4 byte parser just to get one into a `Document`.
    static func attributedLine(
        _ spans: [Span],
        font: NSFont,
        paragraph: NSParagraphStyle,
        fonts: [FontChange] = [],
        defaultSize: Int = 0,
        colourMap: [Int: Double] = [:],
        disableKerning: Bool = false,
        useCourierPrime: Bool = false,
        pixResults: [PixResult] = [],
        pixMeasureWidthPt: Double = 0
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        // Port of `splitIndent` (`PDFWriter.swift:389-421`): still true until the first
        // non-whitespace content on this line — see `appendSpan`'s own note below for what
        // it gates.
        var leading = true
        for span in spans {
            appendSpan(span, to: line, leading: &leading, font: font, paragraph: paragraph,
                      fonts: fonts, defaultSize: defaultSize, colourMap: colourMap,
                      disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                      pixResults: pixResults, pixMeasureWidthPt: pixMeasureWidthPt)
        }
        // A line with no spans at all (a blank PageLine) would otherwise be represented
        // on screen by nothing but its OWN terminator newline — a control character, which
        // AppKit positions at the BOTTOM of its (fixed-height) line fragment rather than at
        // the font's normal ascent-based baseline, unlike every real glyph. A blank line's
        // baseline then lands off the grid a real character's never would, even though its
        // FRAGMENT height (and therefore pagination) is unaffected. One space — invisible on
        // paper, and trimmed away everywhere the text is compared — gives the layout manager
        // a real glyph to place instead of the bare terminator.
        //
        // CORRECTION (job 408, `PrintedStructuralParityTests.swift`'s own Class 4 comment):
        // "so a blank line's baseline sits on the same grid a line of text would" is WRONG —
        // measured directly (`Oracle.lines`' `location(forGlyphAt:).y` vs `fragment.origin.y`
        // under this same pinned min==max paragraph style), a blank/space-filler line's
        // baseline offset does NOT match a real-text line's: they differ by ~1pt (Courier
        // 12pt). The space filler's own offset happens to match the ENGINE's assumed grid
        // (proven via a graphics-only PageLine, which renders the same all-whitespace way and
        // lands exactly on the engine's Y) — it is real TEXT lines that sit ~1pt off, a defect
        // this filler never touched and an isolated single-glyph AppKit probe cannot
        // reproduce (job 408's report). Left as-is: swapping this filler cannot fix the actual
        // gap, since the gap is on the other side of it.
        if line.length == 0 {
            line.append(NSAttributedString(string: " ", attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.black,
            ]))
        }
        return line
    }

    /// A zero-drawing spacer the exact width of a suppressed 0x0F print control's declared
    /// HMI block — an `NSTextAttachment` with an empty image, so it occupies horizontal
    /// space in the line without painting anything, the same way a real control payload
    /// occupies the platen without leaving a mark a reader can see. `widthPt` mirrors the
    /// engine's own conversion (`PDFWriter.swift:473`, `x += Double(hmi) / hmiPerPoint`;
    /// `hmiPerPoint = 1800.0 / 72.0`, `PDFFonts.swift:66` — 1800 HMI units per inch, 72pt
    /// per inch).
    /// - Parameter pcl: Register C2 (`span.pcl`) — the index into `Document.pclPrograms` of
    ///   this control's raw printer payload, or `nil`. Stashed as `.printedPCLProgram` so
    ///   `PageTextView.drawPCLGraphics` (`PrintedPCLGraphics.swift`) can find this attachment's
    ///   own glyph position later and execute the program there — see that file's top doc
    ///   comment for why this is a real feature (LJ6DTP's page border/checkerboard), not
    ///   decoration.
    private static func pctlAdvanceAttachment(hmi: Int, pcl: Int? = nil, paragraph: NSParagraphStyle) -> NSAttributedString {
        let hmiPerPoint = 1800.0 / 72.0
        let widthPt = max(0, CGFloat(hmi) / hmiPerPoint)
        let attachment = NSTextAttachment()
        attachment.image = NSImage()
        attachment.bounds = CGRect(x: 0, y: 0, width: widthPt, height: 0)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if let pcl {
            result.addAttribute(.printedPCLProgram, value: pcl, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// Job 503 item 1: one real WordStar tab stop (`Span.tabHMI`/`.tabLeader`) — port of
    /// `PDFWriter.swift`'s `lineOpsPrinted` tab branch. `line`'s own accumulated NATURAL
    /// width (`line.size().width`) already IS the engine's pen position `x` measured from
    /// `left`: this function's caller (`attributedLine`) builds one `PageLine` per call into
    /// an initially-empty string, and that container's own paragraph style carries no head
    /// indent (`naturalParagraphStyle`/`paragraphStyle(lead:)`), so x=0 here already equals
    /// the engine's own `left`. `tabHMI`'s target is likewise declared relative to `left`
    /// alone (never `left + fi` — `PDFWriter.swift`'s own `let targetX = left + Double(tabHMI)
    /// / hmiPerPoint`), so no separate first-line-indent bookkeeping is needed here either.
    private static func appendTabRun(
        _ span: Span, tabHMI: Int, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double],
        useCourierPrime: Bool, to line: NSMutableAttributedString
    ) {
        let hmiPerPoint = 1800.0 / 72.0
        let targetX = CGFloat(tabHMI) / CGFloat(hmiPerPoint)
        let currentX = line.size().width
        if targetX <= currentX {
            // Overrun guard (`PDFWriter.swift`'s own rule): the stop is at or behind the
            // pen already — never move backward, advance by one document-column space
            // instead (the same document-default-size 0.6em measure the fontless/fixed-
            // pitch branch elsewhere in this file already uses).
            line.append(NSAttributedString(string: " ", attributes: [
                .font: courier(size: CGFloat(defaultSize)),
                .paragraphStyle: paragraph,
            ]))
            return
        }
        if !span.text.isEmpty {
            // Render the span's OWN literal text (almost always the author's typed
            // spaces or dot-leader periods) rather than a content-free `NSTextAttachment`
            // spacer or a freshly-counted run of leader glyphs — this span's real
            // characters are content other readers of this rendered string depend on:
            // `PrintedStructuralParityTests.structuralParity`'s own text-content class
            // reads the live `NSAttributedString` back against `EngineTruth`'s own text,
            // itself built from `docToPagelines`'s PRE-tab-expansion `PageLine.text` (the
            // author's ORIGINAL typed run, not `PDFWriter.swift`'s own recomputed
            // leader-glyph COUNT for the gap), and `PixelOracleAppEngineTests
            // .knockoutRunsClassifyTheSameWayTheEngineDoes` reads colour AT A CHARACTER
            // INDEX. Both regressed the moment this span's real characters were replaced
            // (confirmed: an attachment spacer cost -README.WS a literal space between
            // "■" and the word after it and shifted a knockout run's colour off by the
            // width of the swallowed characters; a freshly-counted dot-leader run cost
            // LJ6DTP.WS's own "Shading 85%..." row its real, shorter typed dot count).
            // A per-character `.kern` computed to land the total advance on `targetX`
            // keeps the real characters (and `colourMap`'s own word-colour attribute,
            // exactly as an ordinary span gets) while still landing the pen where the
            // engine's own real tab stop does — visually a stretched/compressed run of
            // the SAME glyphs instead of the engine's exact repeat-count, close enough
            // for a Mac-viewing facsimile of a fill run never meant to be read character
            // by character (dots, spaces) and never claimed byte-exact in the first place.
            let resolvedTabFont = Self.resolvedFont(
                for: span, fallback: font, fonts: fonts, defaultSize: defaultSize, useCourierPrime: useCourierPrime)
            var runAttributes: [NSAttributedString.Key: Any] = [
                .font: resolvedTabFont,
                .paragraphStyle: paragraph,
            ]
            runAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
            let natural = NSAttributedString(string: span.text, attributes: [.font: resolvedTabFont]).size().width
            let gap = targetX - currentX
            runAttributes[.kern] = (gap - natural) / CGFloat(span.text.count)
            line.append(NSAttributedString(string: span.text, attributes: runAttributes))
            return
        }
        // An empty-text tab (rare — a type-9 block with no filler characters typed at
        // all) has no real content to preserve; land on `targetX` with a zero-drawing
        // spacer instead (`pctlAdvanceAttachment`'s own technique).
        let remainder = targetX - currentX
        if remainder > 0 {
            let attachment = NSTextAttachment()
            attachment.image = NSImage()
            attachment.bounds = CGRect(x: 0, y: 0, width: remainder, height: 0)
            let spacer = NSMutableAttributedString(attachment: attachment)
            spacer.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: spacer.length))
            line.append(spacer)
        }
    }

    /// Job 371 item 1 (PIX IN VIEWS): a resolved `.PIX` tag's decoded image, drawn in-memory
    /// via `NSTextAttachment` (no PNG files, no export machinery on screen — the ruled
    /// design) at `widthPt`x`heightPt` — already the engine's own size for a Printed
    /// `PageLine.image`, or `pixDimsPt`'s own port of that same sizing for Modern's inline
    /// case. `index` out of range or unresolved never reaches here — `appendSpan`/
    /// `lineAndTerminator` both gate on `.ok` first — but the empty-image fallback keeps
    /// this total rather than force-unwrapping, matching every other "never raise, degrade"
    /// pix rule in this codebase.
    /// - Parameter reservedLeadPt: this line's own reserved-band height (job 438) — stashed
    ///   in `attachment.bounds.origin.y`, a field job 428 already confirmed `NSLayoutManager`
    ///   never consults for an attachment-only unbounded line's own placement (so this is a
    ///   pure side channel, never a layout input). `PagedDocumentView.drawOversizedSelfPasses`
    ///   reads it back to anchor an oversized image self-pass's TOP at the reserved band's own
    ///   top rather than at its tiny AppKit fragment's top — see that call site's own doc
    ///   comment. `0` for every OTHER caller (the ordinary inline/non-oversized picture case),
    ///   which never reaches that code path and so never looks at this value.
    private static func pixAttachmentString(
        _ pixResults: [PixResult], index: Int, widthPt: Double, heightPt: Double,
        paragraph: NSParagraphStyle, reservedLeadPt: Double = 0
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if pixResults.indices.contains(index), let png = pixResults[index].png,
           let image = NSImage(data: Data(png)) {
            attachment.image = image
        } else {
            attachment.image = NSImage()
        }
        attachment.bounds = CGRect(x: 0, y: reservedLeadPt, width: max(0, widthPt), height: max(0, heightPt))
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Fit-to-measure fallback for Modern's INLINE `span.pix` case — a port of the engine's
    /// own `imageDimsPt` (`PDFLayout.swift`'s `resolvePlainBody`), which is Printed-only
    /// there (its own doc comment: "the caller never invokes this function for Modern").
    /// Same rule either way: the print-options record's own physical size when the `.PIX`
    /// file carried one, else fill the column measure at the image's own pixel aspect
    /// ratio; either way, capped to the measure so an oversized image never overflows the
    /// column it sits in.
    private static func pixDimsPt(_ result: PixResult, measureWidthPt: Double) -> (w: Double, h: Double) {
        var wPt: Double
        var hPt: Double
        if let widthIn = result.widthIn, let heightIn = result.heightIn, widthIn != 0, heightIn != 0 {
            wPt = widthIn * 72.0
            hPt = heightIn * 72.0
        } else {
            wPt = measureWidthPt
            hPt = result.gcols.map { $0 != 0 ? wPt * (Double(result.grows ?? 0) / Double($0)) : 0.0 } ?? 0.0
        }
        if wPt > measureWidthPt, wPt > 0 {
            let scale = measureWidthPt / wPt
            wPt *= scale
            hPt *= scale
        }
        return (wPt, hPt)
    }

    /// Recover a `Document.graphics`/`pixResults` index from placeholder TEXT alone — see
    /// `appendSpan`'s own call-site comment for why Modern needs this. `text` must be
    /// EXACTLY one placeholder and nothing else (`"[image: NAME]"`, trimmed) — a span with
    /// extra real text around a placeholder never matches, same "never substitute when
    /// there is other real content" discipline the engine's own Printed-mode substitution
    /// keeps (`PDFLayout.swift`'s `resolvePlainBody`: "If a hypothetical pix tag ever
    /// shares a line with OTHER real text, this deliberately does NOT substitute"). Matches
    /// the FIRST resolved (`.ok`) result whose own raw path's basename equals `NAME` — exact
    /// address recovery when basenames are unique (the confirmed real-corpus shape: one
    /// picture per document), a reasonable same-image degradation on the rarer case two
    /// tags share a bare filename.
    private static func inferredPixIndex(fromPlaceholderText text: String, pixResults: [PixResult]) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[image: "), trimmed.hasSuffix("]") else { return nil }
        let name = String(trimmed.dropFirst("[image: ".count).dropLast())
        return pixResults.first { $0.ok && pixBasename($0.rawPath) == name }?.index
    }

    /// One span, fully styled — the per-span body `attributedLine`'s own loop used to
    /// inline before the leading-indent port needed to call it from two places (the
    /// split-off "rest" of an indented run, and every ordinary span).
    private static func attributedRun(
        _ span: Span, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double] = [:],
        disableKerning: Bool = false, useCourierPrime: Bool = false
    ) -> NSAttributedString {
        // Job 226: same lookup `resolvedFont` already needs — shared here so the LJ6DTP
        // character substitution below gates on the SAME font entry, not a second lookup.
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        // Job 240 (b13, Part 1): the driver's own character substitution stays — LJ6DTP's
        // ☻->©/☼->…/etc. reflect the DRIVER's documented semantics (job 226 M7 ruling:
        // "an em dash is an em dash in any century"), document meaning rather than an
        // encoding-floor workaround, and Part 1 explicitly keeps it. The universal cp1252
        // esc-degradation that used to chain after it is gone — see `printedEscDegrade`'s
        // removal doc comment above (MAC VIEWING RULING).
        var text = span.text
        if !colourMap.isEmpty {
            text = printedLJ6DTPSubstitute(text, entry: entry)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(for: span, fallback: font, fonts: fonts, defaultSize: defaultSize,
                                useCourierPrime: useCourierPrime),
            .paragraphStyle: paragraph,
        ]
        // Ink on paper, so black by default — `textColor` inverts with the system
        // appearance and would go white on the white sheet drawn by
        // `PagedDocumentView`. A driver-colour run (LJ6DTP, job 210) overrides this to
        // its palette gray, or (job-489, C1) a real tiled HP pattern — see
        // `driverColourAttributes`'s own doc comment.
        attributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
        if disableKerning { attributes[.kern] = printedNoKerning }
        if span.styles.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if span.styles.contains(.strike) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // `.superscript` (NSAttributedString's Cocoa-Text-System key) raises the glyph
        // WITHOUT shrinking it, which grows the run's ascent past the base font's own —
        // harmless in Printed (its paragraph style pins min==max line height to the
        // library's lead), but Modern sets neither, by design (it is a reading view,
        // not a facsimile). There, a `.fnref` mark — always `.sup`, `ParseWS.swift` —
        // made ITS line's fragment taller than its plain neighbours: the extra leading
        // in Jon's screenshot. `sized()` in the library's own `PDFWriter.swift` never
        // hits this because it sets sup/sub SMALLER (2/3), not just higher. Doing the
        // same here — scaled font plus a baseline offset measured against THAT font's
        // own ascender/descender — keeps a marked run inside the unmarked glyphs'
        // envelope, so the line fragment never grows on its account, in either style.
        //
        // Job 246 (p6-knockout): the baseline OFFSET half of this is TEXT-ONLY in the
        // library too — `lineOpsPrinted` (`PDFWriter.swift:476,501-505`) computes
        // `sized()`'s `(pt, rise)` for every span, but a graphic/cp437-block span takes
        // the `graphicOps` branch BEFORE `rise` is ever consumed, so a superscripted
        // block-character run (LJ6DTP's "PRETTY NEAT, HUH?" knockout: two `.overprint`-
        // chained rows of block(219) glyphs, the second one `.sup`-flagged per WordStar's
        // "superscript the second line" instruction) shrinks to 2/3 size in place, on the
        // SAME shared baseline as the row before it — never rises. Applying `.baselineOffset`
        // here regardless raised that row's vector-fill cell (`graphicCells` reads the
        // glyph's real AppKit position, offset included) off the shared baseline the
        // `.overprint` chain and the knockout text both still sit on, which is what made
        // the composited result overlap/garble. Gated the same way the library gates it:
        // `graphicChars` alone — matching `lineOpsPrinted`'s own `seg.text.contains(where:
        // graphicChars.contains)` check exactly (job 404: the ONLY gate `lineOpsPrinted`
        // ever applies to the graphics decision, font block or none — see `graphicCells`'
        // own doc comment, `PrintedVectorGraphics.swift`).
        if span.styles.contains(.sup) || span.styles.contains(.sub) {
            let base = attributes[.font] as? NSFont ?? font
            let isGraphic = text.contains(where: { graphicChars.contains($0) })
            let (scaled, offset) = scriptMetrics(for: base, raise: span.styles.contains(.sup))
            attributes[.font] = scaled
            if !isGraphic { attributes[.baselineOffset] = offset }
        }
        // Job 399 (Class 6 gate-debt): a footnote reference used to get an app-invented
        // `NSColor.darkGray` tint here ("reads as a reference without inventing a glyph") —
        // but the engine's own `lineOpsPrinted`/`runningOps` never colour an `.fnref` span at
        // all (grep confirms: no `CtrlKD` emitter branches on `.fnref` for colour, only for
        // marker-text substitution — `PDFLayout.swift:709`, `Writer.swift:336`). That made the
        // tint a pure app decoration that broke Printed-mode byte parity with no engine
        // counterpart (`PrintedStructuralParityTests`' Class 6 caught it on `DARKNESS.WS`: a
        // real `NSColor.foregroundColor` divergence unrelated to the LJ6DTP knockout residual
        // this class actually tracks). The reference is already visually distinct via its own
        // `.sup` styling (WordStar's own mark, not this renderer's addition) — removed rather
        // than gated, since no engine surface ever wanted it.
        // Job 240 (b13, Part 2): job 229's word-anchored proportional placement (per-word
        // corrective `.kern` to an AFM×Tz target) is REMOVED — MAC VIEWING RULING. Words in
        // a proportional WS5+ run now lay out at the resolved Mac font's own NATURAL
        // advance, same as every other span; line breaks and page breaks stay
        // engine-authoritative (`docToPagelines`, untouched) — that IS structure. This also
        // resolves job 232's "class a" (LJ6DTP.WS p4: a bold word's corrective kern landing
        // entirely as trailing kern silently ate the following inter-word space) by removing
        // the corrective-kern mechanism that caused it, not by patching it.
        //
        // Job 447 (b27 item 7 part 2 — job 445's `printedCoverageAwareResolvedMacFont` wired
        // in): everything above this line is UNCHANGED — `attributes[.font]` is still exactly
        // the font the rest of this function already decided (LJ6DTP substitution, sup/sub
        // scaling, traits, all done). The only new step is the one below: when `text` contains
        // NO `graphicChars`, return exactly as before (zero behaviour change for prose, which
        // is the entire corpus outside vector-graphics fixtures). When it does, hand off to
        // `coverageSplitAttributedString`, which is where the fix actually lives.
        guard text.contains(where: { graphicChars.contains($0) }) else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        return coverageSplitAttributedString(
            text, attributes: attributes, entry: entry, bold: span.styles.contains(.bold),
            italic: span.styles.contains(.italic), useCourierPrime: useCourierPrime)
    }

    /// Job 447: splits `text` at every boundary between a `graphicChars` run and an ordinary
    /// one, so a span mixing box-drawing/symbol glyphs with real prose (job 442's own
    /// BOXES.WS/LJ6DTP.WS measurement: one span can carry both) resolves EACH kind
    /// separately. RUN-BOUNDARY RULE: a run is a maximal contiguous substring of `text` where
    /// every character's `graphicChars` membership agrees — i.e. exactly the same grouping
    /// `graphicCells` itself already walks character-by-character
    /// (`PrintedVectorGraphics.swift`'s own `guard graphicChars.contains(ch) else { continue
    /// }` loop). A non-graphic run keeps `attributes` UNTOUCHED — the coverage-aware lookup
    /// never runs on prose, so a mixed span's own text portion can never end up on a
    /// different font than it already had (job 442's "Recommended fix" section explicitly
    /// rules out any whole-span substitution, since a general Courier-Prime-vs-Courier-New
    /// swap would visibly change how real prose looks). Only a graphic run's own `.font` is
    /// replaced, with `coverageAwareGraphicFont` below, checked against that run's OWN text —
    /// not the whole span's — so a font that covers this run's particular glyphs but not some
    /// other run's is still accepted.
    private static func coverageSplitAttributedString(
        _ text: String, attributes: [NSAttributedString.Key: Any], entry: FontChange?,
        bold: Bool, italic: Bool, useCourierPrime: Bool
    ) -> NSAttributedString {
        guard let baseFont = attributes[.font] as? NSFont else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let size = baseFont.pointSize
        // Job 447 (found while proving this job's own full-corpus regression, CONVERT.WS/
        // STRENGTH.WS): a graphic run whose OWN font already covers it (the common case — a
        // single "│" side character in a proportional face that happens to carry cp437
        // box-drawing) needs no font override at all, but SPLITTING it into its own
        // `NSAttributedString` piece regardless still measurably moved neighbouring glyphs by
        // ~0.004pt in both fixtures — a real, if tiny, cross-run kerning artifact from the
        // run boundary itself, not from any font change. `runs` below collects (text,
        // isGraphic, font) for every run FIRST, without touching `result`; only when at least
        // one graphic run's own resolved font actually differs from `baseFont` does this
        // function build the split string — otherwise it returns EXACTLY the single, unsplit
        // string the pre-job-447 code already built, with no run boundary introduced at all.
        var runs: [(text: String, font: NSFont, isGraphic: Bool)] = []
        var runStart = text.startIndex
        var runIsGraphic = graphicChars.contains(text[runStart])
        var anyFontChanged = false
        func flush(upTo end: String.Index) {
            guard runStart < end else { return }
            let runText = String(text[runStart..<end])
            var runFont = baseFont
            if runIsGraphic {
                runFont = coverageAwareGraphicFont(
                    baseFont: baseFont, entry: entry, size: size, bold: bold, italic: italic,
                    useCourierPrime: useCourierPrime, coveringCharactersIn: runText)
                if runFont.fontName != baseFont.fontName { anyFontChanged = true }
            }
            runs.append((runText, runFont, runIsGraphic))
        }
        var index = text.startIndex
        while index < text.endIndex {
            let isGraphic = graphicChars.contains(text[index])
            if isGraphic != runIsGraphic {
                flush(upTo: index)
                runStart = index
                runIsGraphic = isGraphic
            }
            index = text.index(after: index)
        }
        flush(upTo: text.endIndex)
        // Job 512 (b32, Jon's field report — BOX.WS's Modern view: right side open, a
        // phantom vertical mid-box): a "filler" run — plain spaces (optionally interleaved
        // with `modernNoBreakGraphicRuns`'s own zero-width U+2060 joiners) sitting between
        // two graphic runs, e.g. a box row's `│    │` interior — renders at `baseFont`'s own
        // proportional SPACE advance, while the graphic runs flanking it render at that same
        // font's box-drawing-GLYPH advance. Neither font substitution (`anyFontChanged`,
        // above) nor `attributedRun`'s WS5+-only `appendProportionalRun` grid-restamp
        // (gated on `entry.proportional`, never true for a fontless WS4 document like
        // `BOX.WS`) touches this: the two advances are simply different numbers in the SAME
        // font (Georgia-14 measured: box glyph ≈9.9pt, space ≈3.4pt), so a row's interior
        // right border compounds that gap over every blank column and lands far short of
        // where the border rows' own box glyphs put the real right edge. Pins each SPACE in
        // such a run to the pitch of its own neighbouring graphic run's first character
        // (measured in THAT run's resolved font, the one actually painted beside it) via
        // `.kern`, so every column of a box/legend row — border, side, or blank — advances
        // by the same amount regardless of which characters happen to be spaces. A run of
        // exactly one bare space (never produced by `modernNoBreakGraphicRuns`, which only
        // ever joins WITHIN a run of 2+ — see its own doc comment) is not this case at all;
        // requiring 2+ real spaces keeps a single incidental gap (a legend line's "LL: └")
        // untouched, same MAC VIEWING RULING carve-out `appendProportionalRun` already
        // documents for ordinary prose.
        func graphicPitch(for font: NSFont, in runText: String) -> CGFloat? {
            guard let first = runText.first else { return nil }
            return (String(first) as NSString).size(withAttributes: [.font: font]).width
        }
        var needsFillerKern = false
        var pitches: [CGFloat?] = Array(repeating: nil, count: runs.count)
        // Scoped to a genuinely proportional BASE font — Printed's own callers always pass a
        // fixed-pitch Courier `font` (`renderPrinted`'s `attributedLine` call sites), under
        // which this correction would compute a near-zero kern anyway (Courier's own space
        // already matches its other glyphs' advance, by definition), but Printed's box
        // rendering is additionally the ACTUAL visible ink for these glyphs
        // (`PagedDocumentView.drawVectorGraphics`'s vector fills, gated `isPrintedStyle`) and
        // sits under a byte-exact Tier-1 gate (`OracleByteParityTests`, "NO '?' box corners,
        // ever," `docs/RUNBOOK.md`) — leaving it untouched entirely removes any risk to that
        // gate from even a sub-point nudge. Modern has no such vector overlay (`graphicChars`
        // glyphs stay live text there, this job's own root cause) and no byte-exact gate. The
        // pre-existing `anyFontChanged` split (Printed's own Courier -> Courier New coverage
        // substitution, job 447) is UNCHANGED either way — only this NEW filler-kern pass is
        // skipped for a fixed-pitch base.
        if !baseFont.isFixedPitch {
            for i in runs.indices where !runs[i].isGraphic {
                let spaceCount = runs[i].text.lazy.filter { $0 == " " }.count
                guard spaceCount >= 2 else { continue }
                let neighbour = (i > 0 && runs[i - 1].isGraphic) ? runs[i - 1]
                    : (i + 1 < runs.count && runs[i + 1].isGraphic ? runs[i + 1] : nil)
                guard let neighbour, let pitch = graphicPitch(for: neighbour.font, in: neighbour.text) else { continue }
                pitches[i] = pitch
                needsFillerKern = true
            }
        }
        guard anyFontChanged || needsFillerKern else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        for (i, run) in runs.enumerated() {
            var runAttributes = attributes
            runAttributes[.font] = run.font
            if let pitch = pitches[i] {
                let spaceAdvance = (" " as NSString).size(withAttributes: [.font: run.font]).width
                var spaceAttributes = runAttributes
                spaceAttributes[.kern] = pitch - spaceAdvance
                for ch in run.text {
                    if ch == " " {
                        result.append(NSAttributedString(string: " ", attributes: spaceAttributes))
                    } else {
                        result.append(NSAttributedString(string: String(ch), attributes: runAttributes))
                    }
                }
            } else {
                result.append(NSAttributedString(string: run.text, attributes: runAttributes))
            }
        }
        return result
    }

    /// One graphic run's own font (job 447): if `baseFont` — the font `attributedRun` would
    /// have used for this whole span before this job — already covers `text`, it is returned
    /// UNCHANGED (a graphic run whose primary font happens to cover it, e.g. a document
    /// already on a covering face, never gets rerouted). Otherwise tries the SAME alternate
    /// job 442 measured as near-canonical ("Courier New", 0.0012pt/glyph residual vs. the
    /// engine's exact pitch — `outbox/job442/report.md`'s own measurement table): via
    /// `printedCoverageAwareResolvedMacFont` (job 445) when `entry` is a real WS5+ font
    /// block, or directly by name when it is not (`entry == nil`: a WS4/print-stream span,
    /// or a WS5+ span whose index didn't resolve — neither has a `FontChange` to look a
    /// `falt` up FROM, the same gap `courierPrime(size:)`'s own doc comment names). Never
    /// returns nil: falls back to `baseFont`, so an uncoverable run keeps exactly the font
    /// (and therefore exactly the pre-job-447 AppKit substitution) it already had.
    private static func coverageAwareGraphicFont(
        baseFont: NSFont, entry: FontChange?, size: CGFloat, bold: Bool, italic: Bool,
        useCourierPrime: Bool, coveringCharactersIn text: String
    ) -> NSFont {
        if fontCoversAllCharacters(baseFont, in: text) { return baseFont }
        if let entry {
            return printedCoverageAwareResolvedMacFont(
                entry, size: size, bold: bold, italic: italic, useCourierPrime: useCourierPrime,
                coveringCharactersIn: text) ?? baseFont
        }
        guard let alt = NSFont(name: "Courier New", size: size) else { return baseFont }
        let styledAlt = printedApplyTraits(alt, bold: bold, italic: italic)
        return fontCoversAllCharacters(styledAlt, in: text) ? styledAlt : baseFont
    }

    /// `(scaled font, baseline offset)` for a superscript or subscript run set against
    /// `base`.
    ///
    /// Two thirds of `base`'s size — the same ratio `PDFWriter.sized()` uses — then a
    /// baseline shift measured from THAT smaller font's own ascender/descender so its
    /// raised (or lowered) glyph tops out exactly at `base`'s own ascender (or bottoms out
    /// at `base`'s own descender). Either edge, matched exactly rather than cleared with
    /// margin: the point is fitting inside a line built for `base`, not looking as large as
    /// possible while doing it.
    static func scriptMetrics(for base: NSFont, raise: Bool) -> (font: NSFont, offset: CGFloat) {
        let scaledSize = max(1, (base.pointSize * 2 / 3).rounded())
        let scaled = NSFont(descriptor: base.fontDescriptor, size: scaledSize) ?? base
        let offset = raise
            ? base.ascender - scaled.ascender
            : base.descender - scaled.descender
        return (scaled, offset)
    }

    /// The face for one Printed-style span — WS5+'s font runs, faithfully; WS4's and every
    /// print stream's Courier, unconditionally.
    ///
    /// `fonts` is `doc.fonts`: EMPTY for WS4 files and print streams (`PDFWriter.swift`'s own
    /// comment on `doc.fonts` — "a PRINTED-mode facsimile feature"). The guard below falls
    /// through to `fallback` whenever `fonts` is empty OR `span.font` doesn't index it, so a
    /// WS4 document never enters the WS5+ branch at all — there is no format check here
    /// because there is nothing left to check once the array is empty. This is the same trick
    /// `spanFontEntry`/`pdfFamily` use in the engine (`PDFFonts.swift`) to keep a fontless
    /// document on Courier by construction rather than by branching on a format flag.
    ///
    /// Job 240 (b13, Part 1): chooses the engine's `.mac` render-target family
    /// (`printedMacFontName`/`printedResolvedMacFont`, this file's own top-of-file doc
    /// comments) rather than the base-14 clamp job 186/210/226 built and this job removed —
    /// MAC VIEWING RULING (decision register 2026-08-11; skill registry #25). `FontChange`'s
    /// fields used here (`typestyleName`, `symbolMap`, `family`, `genericStyle`, `points`)
    /// are all `public`, so this port only reads data the engine already exposes; it does
    /// not re-derive anything from raw bytes.
    ///
    /// PARTIALLY ported (job 202): a proportional span's LEADING-INDENT whitespace is
    /// re-stamped onto the document's own column grid in `attributedLine`, matching
    /// `splitIndent`'s own carve-out — see that call site's doc comment. The REST of a
    /// proportional span (real text after the indent, and any interior run) lays out at
    /// this resolved font's own NATURAL advance (job 229's per-word AFM/Tz corrective-kern
    /// port, `PrintedWordAnchor.swift`, is REMOVED this job — see `attributedRun`'s own doc
    /// comment on that removal).
    private static func resolvedFont(
        for span: Span, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool = false
    ) -> NSFont {
        guard !fonts.isEmpty, let index = span.font, index >= 0, index < fonts.count else {
            return styled(fallback, with: span.styles)
        }
        return resolvedFont(for: fonts[index], styles: span.styles, fallback: fallback, defaultSize: defaultSize,
                            useCourierPrime: useCourierPrime)
    }

    /// The shared tail of `resolvedFont(for: Span...)` above, parameterized on an already-
    /// resolved `FontChange` rather than a `Span`+index lookup — job 256 (Show Invisibles
    /// part 2/4) needed this same Mac-font resolution for `AnnotatedSpan.font`, which
    /// already carries the `FontChange` directly (`AnnotatedLayout.swift`'s own doc comment:
    /// "so a viewer can size a mark... without re-deriving the surrounding run"), not an
    /// index into `Document.fonts`. Pure extraction — behavior for the `Span` overload above
    /// is unchanged.
    private static func resolvedFont(
        for font: FontChange, styles: Style, fallback: NSFont, defaultSize: Int, useCourierPrime: Bool = false
    ) -> NSFont {
        let size = font.points > 0 ? max(1, CGFloat(font.points.rounded())) : CGFloat(defaultSize)
        return printedResolvedMacFont(
            font, size: size, bold: styles.contains(.bold), italic: styles.contains(.italic),
            useCourierPrime: useCourierPrime
        ) ?? styled(fallback, with: styles)
    }

    /// Job 227: does this line's own tallest resolved glyph need more room than the
    /// fragment `advanceLead` is about to give it?
    ///
    /// LJ6DTP.WS's 72pt "LJ6DTP" banner title, immediately followed by its own `.lh .05"`
    /// (3.6pt) shadow copy — the reference archive document `PDFWriter.pageStream`'s own
    /// doc comment cites by name (PDFWriter.swift:576-584). A line's lead is only ever the
    /// space ABOVE it there; the engine never boxes a line's height to that gap, so an
    /// oversized glyph simply paints past it with nothing to clip. This fragment's
    /// `minimumLineHeight == maximumLineHeight` box has no such freedom: measured directly
    /// (a throwaway probe, since removed — see this job's report), the 72pt banner squeezed
    /// into its 3.6pt-tall real fragment got a baseline at y=-13.4 in a container that
    /// starts at y=0 — entirely above the visible page, which is why the banner was
    /// `missingInActual` in the oracle rather than merely clipped.
    ///
    /// Job 240 (b13, Part 3) — TRIED AND REVERTED: LJ6DTP.WS p5's "Color Mappings" heading
    /// (job 232 class c) resolves (post this job's Mac font mapping, Part 1) to 22pt
    /// Optima-Bold in a 14pt-tall fragment. Direct measurement confirmed real clipping —
    /// `natural` (`defaultLineHeight`) ≈26.7pt (under the ×2 cutoff of 28pt), and the
    /// curly-quote GLYPH's own ink bounding box (`CTFontGetBoundingRectsForGlyphs`) tops
    /// out at 15.6pt, 1.6pt above the fragment's 14pt ceiling. Replacing the ×2 multiplier
    /// with a small FIXED points tolerance (tried: 1.5pt) DOES catch this fixture, but a
    /// full-gate re-run (`OracleByteParityTests`/`PrintedStructuralParityTests`/
    /// `OverprintCompositingTests`) showed it also reclassifies large amounts of ORDINARY
    /// body text (YOURWAY.WS and others) as oversized — `natural` for a plain 10-12pt
    /// Times/Helvetica run routinely exceeds a tight document `.lh` by more than 1.5pt on
    /// its own, so a small FIXED allowance (unlike the ×2 ratio, which shrinks toward zero
    /// alongside `assignedLead`) is not selective enough: real body lines went BLANK
    /// (routed through the empty-inline-fragment/oversized-pass path meant for rare titles).
    /// Reverted to the original ×2 margin that job — the real signal (confirmed by direct
    /// glyph-bbox measurement) is glyph INK bounds vs. fragment height, not metric
    /// `defaultLineHeight` vs. any multiple/margin of `assignedLead`; that job's own report
    /// asked a follow-up to measure per-glyph ink bounds directly instead of retuning this
    /// margin further.
    ///
    /// Job 242 (b13) — FIXED, doing exactly what job 240 asked for: `natural`
    /// (`NSLayoutManager.defaultLineHeight`, the font's METRICS-table ascent+descent+
    /// leading, present whether or not this line's own characters ever reach that far) is
    /// replaced with the line's REAL ink extent — `CTLineGetBoundsWithOptions
    /// (.useGlyphPathBounds)` on each span's actual text at its resolved font (`inkTop`
    /// below), unioned across every span on the line, compared directly against
    /// `assignedLead` with NO multiplier. A metric proxy needs a fudge margin (the ×2, or
    /// job 240's rejected 1.5pt) precisely because it overstates ordinary glyphs' real
    /// height; real ink doesn't, so none is needed. This is why it's selective where job
    /// 240's fixed tolerance wasn't: an ordinary 10-12pt Times/Helvetica body run's own
    /// glyphs ink out to roughly cap-height (~0.7em), comfortably under a same-size-ish
    /// `.lh` — job 240's YOURWAY.WS false-positive class was a METRIC artefact, not a real-
    /// ink one, so it does not reappear here. Optima-Bold's 22pt curly quote inks out to
    /// 15.6pt in a 14pt fragment either way — real clipping, correctly caught. Verified
    /// against the same full gate job 240 used to catch its own regression (see this job's
    /// report).
    ///
    /// Internal rather than `private` so `SoftReturnTests` can tell which `PageLine`s
    /// `renderPrinted` routes through `naturalPass` instead of an ordinary fragment —
    /// `OverprintCompositingTests` needs it to keep its own real-fragment/pass accounting
    /// exact now that a pass can come from an oversized base line as well as an
    /// `.overprint` chain continuation.
    static func lineExceedsFragment(
        _ line: PageLine, assignedLead: Double, fallback: NSFont, fonts: [FontChange], defaultSize: Int,
        useCourierPrime: Bool = false
    ) -> Bool {
        // Job 426 (PREVIEW.WS PIX in Native): an image `PageLine` (`line.image`, `spans`
        // empty by construction — job 371's own citation) never reached this check before —
        // this function measured ONLY `line.spans`' glyph ink, so a 74pt logo pinned into
        // whatever ~12-14pt fragment `advanceLead` gave it, same defect class as an
        // unrecognized oversized title, just never taught the same lesson. The image's own
        // `heightPt` (the SAME box `pageStream`'s XObject `cm` matrix and this renderer's own
        // `pixAttachmentString` both already draw the picture at) is the ink-equivalent
        // figure here — no glyph-bounds measurement needed, the image's real size already IS
        // its own "ink."
        if let image = line.image {
            return CGFloat(image.heightPt) > CGFloat(assignedLead)
        }
        var inkTop: CGFloat = 0
        for span in line.spans {
            guard !span.text.isEmpty else { continue }
            let font = resolvedFont(for: span, fallback: fallback, fonts: fonts, defaultSize: defaultSize,
                                    useCourierPrime: useCourierPrime)
            // Job 422: `.useGlyphPathBounds`' tight per-glyph ink (`Self.inkTop`) is not the
            // only figure that decides where this line's real content lands once AppKit lays
            // it out — the layout manager positions a fragment's baseline from the font's own
            // ASCENDER (the same figure `oversizedClearanceBelowBaseline`'s own doc comment
            // already cites as "the same figure NSLayoutManager.defaultLineHeight builds a
            // normal line's height from"), which for a real, non-monospaced-cap-height font
            // can exceed the tight glyph-path measurement by several points. WARPRAYR.WS's
            // 20pt title measured 11.6pt of tight ink against a 12pt lead — just under this
            // function's old ink-only threshold, so it fell through to ordinary (non-oversized)
            // handling — but the real `NSLayoutManager` reserved room for CourierPrime-Bold's
            // own 15.6pt ascender, needing ~13pt more than the 12pt fragment had, with nowhere
            // for that overshoot to go on a page's own first line: real, visible top-clipping
            // (job 422's own probe: `ZZProbeJob422Layout`, `titleBoundingRect` measured 12.84pt
            // above the fragment's own top edge) that both the tight-ink check here AND
            // `TitleAscenderTests`' own independently-derived expectation (the SAME
            // `.useGlyphPathBounds` measurement, `expectedTopInkPt`) were blind to, since both
            // sides of that comparison shared the identical blind spot.
            inkTop = max(inkTop, Self.inkTop(for: span.text, font: font), font.ascender)
        }
        return inkTop > CGFloat(assignedLead)
    }

    /// Job 242: the real glyph ink extent of `text` set in `font`, measured ABOVE the
    /// baseline (`y = 0`) the same way `lineExceedsFragment` compares it against
    /// `assignedLead` — i.e. what a same-baseline, unbounded container would actually need
    /// above the line to avoid clipping this exact text, not what the font's metrics table
    /// promises some OTHER glyph in it might need. `.useGlyphPathBounds` asks CoreText for
    /// the drawn outline's own bounds (job 240's probe used the lower-level per-glyph
    /// `CTFontGetBoundingRectsForGlyphs`; this is the same measurement, taken once per span
    /// across its whole run — including real kerning/positioning — rather than unioning
    /// isolated per-glyph boxes by hand).
    private static func inkTop(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return bounds.origin.y + bounds.height
    }

    /// Job 267 (Show Invisibles reflow, field bug 1): how much room below its own target
    /// baseline an OVERSIZED line's self-pass (`lineExceedsFragment`'s `naturalPass`/
    /// `drawOversizedSelfPasses`) needs to clear before the NEXT fragment can safely start.
    ///
    /// Deliberately the font's own METRIC descent (`-font.descender`, always >= 0, a fixed
    /// per-font figure — same family `NSLayoutManager.defaultLineHeight` draws from), not
    /// `inkTop`'s tight per-glyph `.useGlyphPathBounds` reading. A title with no literal
    /// descenders (`OLDTIMES.WS`'s "Just Like Old Times" — no g/j/p/q/y) inks exactly zero
    /// pixels below its own baseline, so the tight measurement was tried first and measured
    /// a real 0 — yet Jon's field screenshot shows the very next line (the reflow's own
    /// fabricated `.h1` mark) crowding directly against the title's own CAP-HEIGHT lettering
    /// with no visual air between them at all. A human reading "collision" is judging
    /// TYPOGRAPHIC clearance, the gap a normal line of this size would command, not whether
    /// individual glyph outlines technically touch — the same gap the font's own metrics
    /// table (and every ordinary `NSLayoutManager` line height) already encodes.
    static func oversizedClearanceBelowBaseline(
        _ line: PageLine, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool = false
    ) -> CGFloat {
        var clearance: CGFloat = 0
        for span in line.spans {
            guard !span.text.isEmpty else { continue }
            let font = resolvedFont(for: span, fallback: fallback, fonts: fonts, defaultSize: defaultSize,
                                    useCourierPrime: useCourierPrime)
            // `-font.descender` alone (job 267's first attempt) still measured a visible
            // collision on OLDTIMES's own title: the font's cap-height/ascent, not just its
            // descender, is what pins the SELF-PASS's own baseline so close to its fragment's
            // top edge in the first place (`normalBaselineOffset` is a small BASE-FONT figure,
            // 9pt, used for every self-pass regardless of the oversized font's own size) — a
            // large font's ascent alone can already exceed a 12pt lead many times over, and
            // whatever of that doesn't fit above the baseline reads, to a human, as "sitting
            // low, crowding the next line" even where the glyph ink technically stays inside
            // its own box. `ascender - descender` (the font's FULL em advance — the same
            // figure `NSLayoutManager.defaultLineHeight` builds a normal line's height from)
            // is the conservative, guaranteed-enough figure: reserving a full ordinary line's
            // worth of THIS font's own natural height, not merely its descent.
            clearance = max(clearance, font.ascender - font.descender)
        }
        return clearance
    }

    /// Job 396 (391 root cause 5): `RenderedDocument.leadingHeadroom` — per page, how much
    /// blank canvas `PagedDocumentView` must reserve above that page's own nominal top so
    /// its FIRST fragment's oversized self-pass (`oversizedSelfPasses[page].first`, when
    /// non-nil) can bleed its full ascent without clipping.
    ///
    /// Measured exactly the way `lineExceedsFragment`/`inkTop` already measure a fragment's
    /// real ink — `CTLineGetBoundsWithOptions(.useGlyphPathBounds)` on the self-pass's own
    /// (already fully resolved/styled) `NSAttributedString`, not a font-metrics guess —
    /// against THIS PAGE's own real first-baseline (`firstBaselines[page]`, job 425 — see
    /// `perPageFirstBaselines`'s own citation in `renderPrinted`: `top + THIS line's own
    /// lead`, not a flat `top + size` shared by every page). A self-pass whose real ink
    /// already fits above that baseline (LJ6DTP.WS's banner may or may not, depending on its
    /// resolved font — not assumed either way, only measured) needs no extra room at all.
    /// Using each page's own REAL anchor (where `drawOversizedSelfPasses` actually draws it,
    /// via `pinnedBaselines`) rather than the nominal shared `textTop` anchor is deliberate:
    /// "does this ink bleed off the PHYSICAL page's top edge" is a question about where the
    /// ink is actually drawn, not about the screen container's own nominal position.
    ///
    /// The `+ 2` float-safety margin on a real deficit is bigger than this codebase's usual
    /// established convention for a measured-not-guessed figure
    /// (`PagedDocumentView.buildExplicitPages`'s `epsilon`, 0.5) — deliberately: the ink
    /// bounds a real glyph path reports are not perfectly reproduced by a second,
    /// independent AppKit drawing pass landing pixel-for-pixel on the same coordinate, so a
    /// razor-tight reservation would reintroduce a one-pixel version of the exact bug this
    /// fixes, and a wider margin also keeps a REGRESSION (headroom silently dropped again)
    /// unambiguously distinguishable from "working as intended" under a pixel-truth test's
    /// own antialiasing tolerance (`TitleAscenderTests`).
    static func leadingHeadroom(
        _ oversizedSelfPasses: [[NSAttributedString?]], firstBaselines: [Double]
    ) -> [CGFloat] {
        oversizedSelfPasses.enumerated().map { pageIndex, page in
            guard let maybePass = page.first, let pass = maybePass, pass.length > 0 else { return 0 }
            guard firstBaselines.indices.contains(pageIndex) else { return 0 }
            let ctLine = CTLineCreateWithAttributedString(pass)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
            let inkTop = bounds.origin.y + bounds.height
            let deficit = inkTop - CGFloat(firstBaselines[pageIndex])
            return deficit > 0 ? deficit + 2 : 0
        }
    }

    /// Job 210: the foreground colour for one span — `colourMap[span.colour]` as a
    /// grayscale `NSColor` when the document's driver colour applies (`colourMap` is
    /// non-empty only for LJ6DTP, `printedLJ6DTPColourGray`'s own doc comment), else the
    /// ordinary black ink every other document has always used. Port of the SAME gate the
    /// engine's `lineOpsPrinted` applies to its own `g` operator (`PDFWriter.swift:486-492`:
    /// "Emitted only when the value CHANGES... every all-black document... writes not one
    /// extra byte") — here there is no operator-diffing to do (AppKit attributes aren't a
    /// byte stream), so every run simply asks for its own resolved colour directly.
    private static func driverColour(_ colour: Int?, _ colourMap: [Int: Double]) -> NSColor {
        guard let colour else { return .black }
        // job-489 (C1): `colourMap` empty means this document isn't LJ6DTP at all
        // (`renderPrinted`'s own gate) — the SAME condition every other driver-colour branch
        // here already checks, so a pattern index never applies to a non-LJ6DTP document's
        // own `span.colour` (if any) either.
        if !colourMap.isEmpty, lj6dtpHPPatternIndices.contains(colour) {
            return NSColor(patternImage: LJ6DTPPattern.tileImage(for: colour))
        }
        guard let gray = colourMap[colour] else { return .black }
        return NSColor(white: CGFloat(gray), alpha: 1)
    }

    /// job-489 (C1): `driverColour`'s own `.foregroundColor`, plus — only for an HP pattern
    /// index — the companion `.lj6dtpPatternIndex` attribute `graphicCells`
    /// (`PrintedVectorGraphics.swift`) needs to recover which of the six hatches a colour-
    /// driven glyph FILL (not just plain text) wants. Both call sites that used to write
    /// `.foregroundColor: driverColour(...)` directly now merge this dictionary in instead.
    /// Register b31 (job 506, E2): also tags a colour1-7 run with `.lj6dtpDarkenColour` —
    /// see that key's own doc comment — so a self-pass drawing this text (LJ6DTP's masthead
    /// shadow) can ask the graphics context for a Darken blend the same way the engine's
    /// `lineOpsPrinted` now does. Colour15 (white knockouts) and plain colourless black text
    /// are excluded by the SAME `(1...7).contains(colour)` range check the engine uses.
    private static func driverColourAttributes(
        _ colour: Int?, _ colourMap: [Int: Double]
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: driverColour(colour, colourMap)]
        if let colour, !colourMap.isEmpty, lj6dtpHPPatternIndices.contains(colour) {
            attrs[.lj6dtpPatternIndex] = colour
        }
        if let colour, !colourMap.isEmpty, (1...7).contains(colour) {
            attrs[.lj6dtpDarkenColour] = true
        }
        return attrs
    }

    /// Apply the IR's bold/italic to a base face. Printed style asks for Courier, whose
    /// bold and oblique members are what the PDF emitter names; Modern asks for the user's
    /// font, whose traits AppKit synthesises where the family lacks them.
    private static func styled(_ font: NSFont, with styles: Style) -> NSFont {
        var traits: NSFontTraitMask = []
        if styles.contains(.bold) { traits.insert(.boldFontMask) }
        if styles.contains(.italic) { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    /// Courier, the typescript face — the same family `emitPDF` names, so a page looks the
    /// same on screen as it does exported. Falls back to the system monospaced face if
    /// Courier is ever absent, which would change the look but never the metrics: both are
    /// asked for at the document's own `.cw`-derived size.
    private static func courier(size: CGFloat) -> NSFont {
        NSFont(name: "Courier", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Job 437 (b27, Jon's font-fallback ruling): the NO-FONT-INDEX fallback for a span
    /// inside a document that DOES declare fonts elsewhere — the bundled face Native's own
    /// courier-class rows already resolve to (`printedMacFontName`'s `useCourierPrime`
    /// branch, "Courier Prime" primary / "Courier New" `falt`), used here directly rather
    /// than through that WS5+-font-block-keyed lookup: a span with no font index has no
    /// `FontChange` to look a row up FROM in the first place — this is the same terminal
    /// substitute those rows resolve TO, requested unconditionally. "Courier New" is the
    /// same defensive second choice `printedMacFontName` already names for the identical
    /// reason (the bundled face failing to register); the system monospaced face is a third
    /// line only `courier(size:)` above has ever needed to reach for.
    private static func courierPrime(size: CGFloat) -> NSFont {
        NSFont(name: "Courier Prime", size: size)
            ?? NSFont(name: "Courier New", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
