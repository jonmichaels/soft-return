#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Printed

    /// Job 427: `doc` unless real output page `page` declares its own `.mt`/`.mb`
    /// (`Page.mtLines`/`.mbLines`, engine Finding 3/b26-print-fidelity-2), in which case a
    /// local copy with `.page` swapped — the SAME "swap `.page` on a local `Document`
    /// copy, scoped to just this call" idiom `emitPDF`'s own per-page loop uses
    /// (`PDFWriter.swift`, the source this ports) and `NativeStructuralParityTests.swift`'s
    /// `EngineTruth.structuralPages` already ported for its own test-harness reads. Callers
    /// check `page.mtLines != nil || page.mbLines != nil` themselves before calling this
    /// (matching the engine's own guard) so a page with no override never pays for a
    /// `Document` copy or a second `printedMetrics` call.
    // Internal, not private, so a test can take a page's top exactly as this renderer does
    // (`ColumnTopsMatchTheEngineTests`).
    public static func effectivePageDoc(_ doc: Document, for page: Page) -> Document {
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
    static func renderNative(_ state: DocumentState,
                                      exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        let session = nativeRenderSession(state, exportFlags: exportFlags)
        session.renderAll()
        return session.snapshot(final: true)
    }

    /// #271 M7: `renderNative`'s work, held open page by page. The engine hands the document over
    /// already paginated (`docToPagelines`, one cheap call); the cost is building each page's
    /// attributed text, which a session does for as many pages as it is asked, so a window can show
    /// a long document's first pages before the rest exist (`DocumentWindowController`'s progressive
    /// open). Everything document-wide — the metrics, the left anchor over every page — is decided
    /// from the whole page list up front, so the pages rendered so far are exactly the first pages of
    /// the full render, and rendering every page then taking the final snapshot IS `renderNative`.
    @MainActor
    public final class NativeRenderSession {
        /// How many pages the engine paginated the document into.
        public let pageCount: Int
        /// How many of them are rendered so far, from the first.
        public private(set) var renderedPages = 0
        private let renderPage: @MainActor (Int) -> Void
        private let makeSnapshot: @MainActor (Bool) -> RenderedDocument
        private var spent = false

        public init(pageCount: Int, renderPage: @escaping @MainActor (Int) -> Void,
             snapshot: @escaping @MainActor (Bool) -> RenderedDocument) {
            self.pageCount = pageCount
            self.renderPage = renderPage
            self.makeSnapshot = snapshot
        }

        public var isComplete: Bool { renderedPages >= pageCount }

        /// Renders up to `count` more pages.
        public func renderNext(_ count: Int) {
            let end = min(pageCount, renderedPages + max(1, count))
            while renderedPages < end {
                renderPage(renderedPages)
                renderedPages += 1
            }
        }

        public func renderAll() {
            renderNext(pageCount - renderedPages)
        }

        /// Batch 26: renders pages until `deadline` (`DispatchTime` uptime nanoseconds) passes — at least
        /// one, so every call makes progress — which keeps one turn of the main run loop short.
        public func renderNext(until deadline: UInt64) {
            guard !isComplete else { return }
            repeat {
                renderNext(1)
            } while !isComplete && DispatchTime.now().uptimeNanoseconds < deadline
        }

        /// The pages rendered so far, as a document of that many pages. A snapshot before the last
        /// page copies what it needs, so rendering can go on; `final` — once every page is rendered —
        /// finishes the flow in place, and the session is spent.
        public func snapshot(final: Bool = false) -> RenderedDocument {
            precondition(!spent, "NativeRenderSession: snapshot after the final one")
            precondition(!final || isComplete, "NativeRenderSession: final snapshot before the last page")
            if final { spent = true }
            return makeSnapshot(final)
        }
    }

    /// The options a Native render lays the document out with: the Margins choice and the resolved pictures.
    public static func nativeEngineOptions(_ state: DocumentState) -> EmitOptions {
        EmitOptions(pageSettings: state.pageSettingsPreset.value?.settings, pixResults: state.pixResults)
    }

    /// Batch 41 (A, presets): the options Modern's own export lays its pages out with — the bottom bar's page-settings
    /// preset and the Page Numbers setting (`ExportEngine.render`) — so the Modern view reads the same page furniture
    /// (`modernPageFurniture(_:options:)`, engine 93d458d) the export draws.
    /// `exportFlags` (batch 42): the furniture is asked for with the SAME flags the render was asked for, so the
    /// engine's own answer is the single decision about what this page carries.
    ///
    /// This is the second attempt at the same line, and the first one is worth recording because it looked
    /// right and did nothing. Batch 41 passed `options.headers` here too — but Modern ignored it: the flag
    /// reached `modernPageFurniture`, which reported its heads regardless, and an export with `--headers off`
    /// kept them. `EmitOptions.headers` governed Printed and RTF only. Engine ce41797 closed that, so asking is
    /// now worth doing.
    public static func modernEngineOptions(_ state: DocumentState,
                                    exportFlags: ExportFlags = .allOn) -> EmitOptions {
        var options = EmitOptions(pageSettings: state.pageSettingsPreset.value?.settings)
        options.pageNumbers = SettingsStore.shared.defaultPageNumbers
        options.headers = exportFlags.headers
        return options
    }

    /// `engine`: the engine's half made already — off the main thread, by a window (batch 26) — for
    /// `state` as it is now; nil makes it here.
    public static func nativeRenderSession(_ state: DocumentState,
                                    exportFlags: ExportFlags = .allOn,
                                    engine: NativeEngineWork? = nil) -> NativeRenderSession {
        // #271 M2: the document `emitPDF` lays out — the page-settings preset folded in, then a
        // `.pr or=l` landscape rotation on top (`printedDocument`, engine 944d897). Paginating the
        // parsed document instead left everything anchored off the page's own size — the odd/even
        // offsets, heads and feet, page numbers, the note area, a `.PIX`'s fit width — in its
        // portrait place on a landscape sheet. `printedMetrics` takes the PARSED document and the
        // same options, and folds them in itself.
        let options = nativeEngineOptions(state)
        let work = engine ?? NativeEngineWork.make(document: state.document, options: options,
                                                   pictures: exportFlags.pictures)
        let doc = work.doc
        let metrics = work.metrics
        // Job 371 item 1 (PIX IN VIEWS): `state.pixResults` was resolved once against the
        // document's real path when it was opened/reparsed (`DocumentState.init`/
        // `setVariant`) — passing it (plus `.embed`) here is what makes `docToPagelines`
        // substitute a resolved `.PIX` tag's own `PageLine` for an image one
        // (`PrintedBody.swift`'s `resolvePrintedBody`, the SAME sizing —
        // print-options-record-or-fit-to-measure — `emitPDF`'s own Printed PDF uses), so
        // Native's screen render can never show a picture PDF export doesn't, or vice
        // versa. Harmless when `pixResults` is empty (no graphics, or nothing resolved):
        // `resolvePrintedBody`'s own `embedImages` gate stays false, byte-for-byte the same
        // plain-text-placeholder pagination as before this job.
        let pages = work.pages
        let capacity = metrics.capacity
        // A mid-document `.po` can move a line LEFT of the document's default one, and an
        // AppKit head indent cannot express that: `firstLineHeadIndent`/`headIndent` are
        // offsets INTO the text container, and a negative value is clamped to zero, so such a
        // line silently rendered at the container's own left edge instead of where the engine
        // puts it. SCRIPT.WS is the proving case — its worked-example pages reset `.po` to
        // `.5"`, so `PageLine.left` is 36.0 against a document default of 57.6, and all ~74 of
        // its body lines on those pages sat 21.6pt (three columns) too far right.
        //
        // The fix is to anchor the container at the document's LEFTMOST line rather than at
        // its default `.po`, so every per-line indent is a non-negative offset from that
        // anchor and nothing needs clamping. A document that never moves left of its default
        // (every document that does not change `.po` mid-document, and every one that only
        // moves right) resolves `printedLeftAnchor` to exactly `metrics.left`, leaving its
        // frame and every indent bit-for-bit as before.
        let printedLeftAnchor = pages.reduce(metrics.left) { anchor, page in
            page.lines.reduce(anchor) { min($0, $1.left ?? metrics.left) }
        }
        // Job 210: driver-aware colour, gated exactly like the engine's own
        // `colourMap` (`PDFWriter.swift:708`) — non-empty only for LJ6DTP documents, so
        // every other driver's `span.colour` (if any) stays inert, same as before this job.
        let colourMap = doc.printerDriver == "LJ6DTP" ? nativeLJ6DTPColourGray : [:]

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
        /// This line's OWN height, as against `advanceLead`'s gap from the line before it.
        ///
        /// The two coincide everywhere except a page's FIRST line, and `advanceLead`'s
        /// `guard i > 0 else { return metrics.lead }` is right for what its name says: the
        /// gap before line 0 positions nothing, because nothing precedes it. But that same
        /// value was also being used as line 0's FRAGMENT HEIGHT, which is not cosmetic at
        /// all — it is how much of the page the line consumes.
        ///
        /// Measured, MARKUP.WS page 1: line 0's own lead is 2.00pt, `metrics.lead` is
        /// 15.00pt, and the page came out 57.00pt against the engine's 44.00pt budget. One
        /// line, the whole 13.00pt excess, every other line matching its lead exactly.
        ///
        /// A 2pt lead is a REAL WordStar value — `.lh` is in 1/48in units — so the facsimile
        /// must clamp to it exactly as the engine does, not fall back to the document
        /// default (Athena, 2026-09-07). This also finishes what job 427 started: it already
        /// established that a page's first line takes its position from its OWN lead rather
        /// than the document default, and pinned `firstBaseline` to
        /// `page.first?.lead ?? metrics.lead` for exactly that reason. The fragment height
        /// was the half of that rule which never got applied.
        func ownLead(_ page: Page, at i: Int) -> Double {
            guard i > 0 else { return page[i].lead ?? metrics.lead }
            return advanceLead(page, at: i)
        }
        // Register b31 (job 506): `extraLeftPt` shifts a paragraph's own left edge past
        // `metrics.left`, the document DEFAULT `.po` — needed because `.po` is now
        // stateful per line (`Line.poCols`/`PageLine.left`, the same "carries the rest,
        // nil means agrees with the document default" contract `PageLine.lead` already
        // has for `.lh`). `PageLine.left` arrives HERE already resolved to points by the
        // engine's own public `docToPagelines(doc, printed: true)` call
        // (`resolvePrintedBody` in `PrintedBody.swift` computes it via
        // the library's own internal `resolveLeftPt`, which this app cannot call
        // directly — same "internal helper, public resolved field" shape
        // `NativePCLGraphics.swift`'s own top doc comment already established for
        // `pclRectOps`) — this function only has to READ it, not re-derive the formula.
        // Both `firstLineHeadIndent`/`headIndent` get the SAME value: Printed mode clips
        // rather than wraps (`lineBreakMode = .byClipping`), so every paragraph here is
        // exactly one physical line, and AppKit distinguishes the two indents only across
        // a paragraph's own wrapped rows.
        func paragraphStyle(lead: Double, extraLeftPt: Double = 0) -> NSParagraphStyle {
            nativeLineParagraphStyle(fontSize: Double(metrics.size), lead: lead, extraLeftPt: extraLeftPt)
        }
        // `minimumLineHeight`/`maximumLineHeight` both 0 (`NSMutableParagraphStyle`'s own
        // default) mean "unbounded" — this file's own established convention (see
        // `nearZeroLead`'s doc comment above for the citation). Used only by `naturalPass`
        // (job 227): a line measured and drawn at its OWN font's natural height instead of
        // clamped to any document lead.
        func naturalParagraphStyle() -> NSParagraphStyle {
            nativeLineParagraphStyle(fontSize: Double(metrics.size), lead: nil)
        }
        // #271 M1: the `.sr` roll Printed moves a superscript or subscript by when a line carries
        // none of its own — the engine's `printedRollPt`, `(subSuperRoll48 ?? 3) × 1.5` points.
        let documentRoll = (doc.formatting.subSuperRoll48 ?? 3.0) * 1.5
        func lineAndTerminator(_ line: PageLine, lead: Double) -> NSAttributedString {
            let extraLeftPt = (line.left ?? metrics.left) - printedLeftAnchor
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
                    widthPt: image.widthPt, heightPt: image.heightPt, paragraph: paragraph,
                    descentClearancePt: Self.nativePixDescentPt(metrics.size)))
                piece.append(lineTerminator(font: courier(size: CGFloat(metrics.size)),
                                            paragraph: paragraph))
                return piece
            }
            let piece = NSMutableAttributedString(attributedString: nativePinJustifiedWords(
                nativePinGraphicCells(
                    attributedLine(
                        coalesce(line).spans, font: courier(size: CGFloat(metrics.size)),
                        paragraph: paragraph, fonts: doc.fonts, defaultSize: metrics.size,
                        colourMap: colourMap, disableKerning: true, useCourierPrime: true,
                        nativeSupSub: true, nativeRoll: line.roll ?? documentRoll,
                        nativePMActive: line.pmActive, nativeKerning: line.kerning),
                    placements: line.graphicCells ?? []),
                pieces: line.justifyWordX ?? []))
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
        // oversized title chief among them, whose natural (`styleLeadPt`) lead is nothing
        // like the document's plain-Courier default. Confirmed via the engine's real PDF
        // content stream (`Td`) for WARPRAYR.WS: its title baseline sits at
        // `top + its own 16pt Title lead`, not at the app's old `top + metrics.size(12)`.
        //
        // The ARITHMETIC here is unchanged and still correct — this pin reads the lead the
        // engine computed (`page.first?.lead`) rather than deriving one — but the worked
        // numbers this comment used to quote (79.2pt = top(60) + 1.2*16) are stale twice
        // over, and are dropped rather than restated: mechanism T (engine commit d6626a0)
        // put stock WordStar's auto-leading factor at 1.0, not 1.2, so the Title lead is
        // 16.0pt; and mechanism U (2e33e9e) made `printedTop` reserve `.mt` alone, moving
        // `top` itself. Both land here for free through `printedMetrics`/`docToPagelines` —
        // there is no factor and no top margin written down on this side to update, which
        // is exactly why this pin reads the engine's answer instead of recomputing it.
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
        var pinnedPageBottoms: [[Double]] = []
        var pinnedPageTops: [[Double]] = []
        // The highest flow top on any page whose own FIRST LINE is too short to hold the
        // face's ascent — the only shape that can put the anchor below the flow. See
        // `flowTopAdjustment`.
        var tightestFlowTop: Double?
        var pageColumnFragmentCounts: [[Int]] = []
        var allNumberPasses: [[ColumnPass]] = []
        var allGraphicRows: [[[PageLine.GraphicCellPlacement]]] = []
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
                           useCourierPrime: true, nativeSupSub: true, nativeRoll: line.roll ?? documentRoll,
                           nativePMActive: line.pmActive, nativeKerning: line.kerning)
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
                    paragraph: naturalParagraphStyle(), reservedLeadPt: reservedLead,
                    descentClearancePt: Self.nativePixDescentPt(metrics.size))
            }
            return attributedLine(coalesce(line).spans, font: courier(size: CGFloat(metrics.size)),
                           paragraph: naturalParagraphStyle(), fonts: doc.fonts,
                           defaultSize: metrics.size, colourMap: colourMap, disableKerning: true,
                           useCourierPrime: true, nativeSupSub: true, nativeRoll: line.roll ?? documentRoll,
                           nativePMActive: line.pmActive, nativeKerning: line.kerning)
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
        // #271 M7: one page's work — the loop body it always was, run by `NativeRenderSession` in order.
        func renderPage(_ index: Int, _ page: Page) {
            // Job 427 (Jon's ruling: "Native only changes fonts. Otherwise it's the same
            // as Printed."): this page's own effective top margin — `metrics.top` (the
            // document-global one) UNLESS this real page declares its own `.mt`/`.mb`
            // (`Page.mtLines`/`.mbLines`, engine Finding 3/b26-print-fidelity-2), in which
            // case a local copy of `doc` with `.page` swapped, mirroring `emitPDF`'s own
            // per-page idiom exactly (`PDFWriter.swift`'s per-page loop over `pages`,
            // "a local COPY of doc with .page swapped ... scoped to just this page's
            // printedTop/runningOps calls") — already ported to this test suite's own
            // `EngineTruth.structuralPages` (`NativeStructuralParityTests.swift`) but never
            // to the real render path until now. SCRIPT.WS's figure-listing pages (a very
            // different `.mt` from the screenplay body) are the proving case: without this,
            // every page rendered at the document's global top margin regardless of its own
            // declared one.
            let hasPageOverride = page.mtLines != nil || page.mbLines != nil
            let pageDoc = hasPageOverride ? Self.effectivePageDoc(doc, for: page) : doc
            let pageTop = hasPageOverride ? printedMetrics(pageDoc).top : metrics.top
            runningLines.append(exportFlags.headers
                ? Self.runningLines(for: page, pageNo: startNo + index, doc: pageDoc,
                                    metrics: metrics, leftAnchor: printedLeftAnchor,
                                    sheetHeight: work.sheets.indices.contains(index) ? Double(work.sheets[index].height) : nil)
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
            var graphicRows: [[PageLine.GraphicCellPlacement]] = []
            var pageColumnCounts: [Int] = []
            var numberPasses: [ColumnPass] = []
            let pageIsColumnar = (page.columns ?? 1) > 1
            if page.isEmpty {
                // One blank line, not `capacity` — a wholly blank page is still a blank
                // sheet (`PagedDocumentView`'s page rect is drawn from `pageSize`
                // regardless of how little the text container holds), and this function no
                // longer owns making the CONTAINER match the sheet's visual height.
                let piece = lineAndTerminator(PageLine(), lead: metrics.lead)
                let blankK = Self.isolatedFragmentK(piece, width: metrics.pageWidth - metrics.left)
                pinnedBaselines[output.length] = PinnedBaseline(
                    page: index, y: pageFirstBaseline, k: blankK, height: metrics.lead)
                pinnedPageBottoms.append([pageFirstBaseline + metrics.lead - blankK])
                pinnedPageTops.append([pageFirstBaseline - blankK])
                pageColumnFragmentCounts.append([1])
                output.append(piece)
                flags.append(false)
                passes.append([])
                selfPasses.append(nil)
                graphicRows.append([])
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
                // ONE COLUMN, ONE CONTAINER (item 19, Jon's ruling 2026-09-10).
                //
                // Every column's lines are in the flow, in the engine's own order
                // (`applyColumns` concatenates column 0's, then column 1's), each later column
                // restarting where the `.co` region starts on the sheet. `PagedDocumentView` gives each its own
                // text container, so AppKit flows one into the next the way its multi-column
                // model always did, and the text stays real: selectable, findable, spoken.
                //
                // `col` is `nil` on every ordinary page — `applyColumns` is the only thing
                // that sets it — so a non-columnar document runs this once with every line
                // in it and is byte-for-byte what it was.
                var columnBottoms: [Double] = []
                var columnTops: [Double] = []
                var columnCounts: [Int] = []
                for column in 0..<max(1, page.columns ?? 1) {
                let flowPage = pageIsColumnar
                    ? Page(page.lines.filter { ($0.col ?? 0) == column })
                    : page
                if flowPage.isEmpty { break }
                // THIS COLUMN's own anchor: where the column starts plus its own first line's
                // lead, the same formula the page's own first line uses and the same thing
                // `pageStream` does at a column boundary. Column 0 starts at the page's top and
                // runs through any title and blank the sheet opened with. Every later column
                // starts where the `.co` region starts on this sheet, `columnTopOffsetPt` below
                // the top (layout version 8), which is where real WS7 puts it.
                let columnFirstLead = flowPage.first?.lead ?? metrics.lead
                let columnStart = column > 0 ? (page.columnTopOffsetPt ?? 0) : 0
                let columnFirstBaseline = pageTop + columnStart + columnFirstLead
                // COUNTED HERE, not off the model. `pageColumnFragmentCounts` slices this
                // page's fragments into its columns for `buildExplicitPages`, and a count
                // that disagrees with the fragments this loop actually appends drifts the
                // slice for every page after it. Measured on PRINT.TST: the model assigns
                // page 3 forty-six lines, the renderer forms thirty-four fragments from
                // them, and reading the model's number left page 4 with nothing at all.
                var columnFragments = 0
                var pageEngineY: Double?
                var lastGroupBottom = columnFirstBaseline
                var lastGroupPiece: NSAttributedString?
                // THIS COLUMN's own first fragment top — see `pinnedPageTops`.
                var firstGroupTop: Double?
                var i = 0
                while i < flowPage.count {
                    // The chain runs while each member is itself `overprint` — its
                    // successor shares ITS baseline too.
                    var j = i
                    while flowPage[j].overprint, j + 1 < flowPage.count { j += 1 }
                    let base = flowPage[i]
                    // `i`, not `j` (job 245): the fragment's rendered height is the gap
                    // BEFORE THIS GROUP, i.e. `advanceLead`'s rule applied to the group's
                    // OWN base line — `flowPage[i].lead ?? metrics.lead`, checking whether the
                    // line immediately before the GROUP (not within it) was itself
                    // overprint. The chain's interior members (`i+1...j`) never form their
                    // own fragment regardless, so their own `.lead` is moot here.
                    let lead = advanceLead(flowPage, at: i)
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
                    // self-pass needs). LJ6DTP.WS's title (`flowPage[0]`) into its `.lh .05"`
                    // shadow copy (`flowPage[1]`, lead 3.6) is exactly this: the title's own gap
                    // (`lead`, the ordinary document default) correctly pins how far down the
                    // TITLE ITSELF sits below whatever came before it, untouched — but the OLD
                    // code also used that same `lead` for the title's own fragment height, so
                    // the shadow copy's fragment started a full ordinary lead below the title
                    // instead of 3.6pt, spreading the "shadow" into daylight and, since every
                    // later fragment on the page stacks on top of that same excess, parking
                    // the whole stack that much closer to the gray bar beneath it. Borrowing
                    // the NEXT real line's own lead instead reproduces `pageStream`'s own
                    // baseline chain (`y -= line[n].lead`) for a self-pass exactly the way job
                    // 245's `flowPage[i].lead` convention already does for ordinary content. Only
                    // the fragment HEIGHT changes here — pagination (`lead` above), the
                    // chain's own oversized test, and every non-oversized line are untouched;
                    // when the next line's lead already equals this line's own (the common,
                    // unstacked case, e.g. OLDTIMES.WS's single title), `fragmentLead == lead`
                    // and nothing visibly changes.
                    let fragmentLead: Double
                    if oversized, j + 1 < flowPage.count {
                        fragmentLead = advanceLead(flowPage, at: j + 1)
                    } else {
                        // `ownLead`, not `lead`: identical for every line but a page's
                        // first, where `advanceLead` deliberately answers the document
                        // default because the GAP before line 0 positions nothing. Its
                        // HEIGHT is not cosmetic — see `ownLead`'s own doc comment.
                        fragmentLead = ownLead(flowPage, at: i)
                    }
                    // Job 412: `lead` (not `fragmentLead`) is this GROUP's own gap from the
                    // fragment before it — `fragmentLead` only exists to give an oversized
                    // fragment the NEXT line's height (see the doc comment above), never to
                    // change how far down THIS group's own baseline sits. Matches
                    // `pageStream`'s own `y -= line[n].lead` exactly: advance once per real
                    // fragment (group), by that group's own base line's lead.
                    let engineY = pageEngineY.map { $0 + lead } ?? columnFirstBaseline
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
                        page: index, column: column, y: engineY + compensation, k: k,
                        height: fragmentLead)
                    if firstGroupTop == nil { firstGroupTop = engineY + compensation - k }
                    pageChunk.append(piece)
                    columnFragments += 1
                    // Job 412: whatever this holds when the loop ends is the PAGE's own
                    // LAST group — exactly what `RenderedDocument.pinnedPageBottoms` needs
                    // (see that field's own doc comment).
                    lastGroupBottom = engineY + fragmentLead
                    lastGroupPiece = piece
                    // The flag rides on the PRE-coalesce line — `coalesce` merges spans
                    // and carries no flags of its own (it only ever needed `lead`, see
                    // its doc comment in PDFLayout.swift).
                    flags.append(base.soft)
                    let linePasses = i == j ? [] : (i + 1...j).map { overprintPass(flowPage[$0]) }
                    passes.append(linePasses)
                    selfPasses.append(oversized
                        ? naturalPass(base, reservedLead: base.lead ?? (base.image?.heightPt ?? metrics.lead))
                        : nil)
                    graphicRows.append(base.graphicCells ?? [])
                    if let label = base.lineNo {
                        // Plain Courier at the document's own size — the engine's gutter is
                        // its own fallback face, never a `.f#` font block, and `x` arrives
                        // already right-aligned to `PDFMetrics.lineNoRightPt`.
                        numberPasses.append(ColumnPass(
                            text: NSAttributedString(string: label.text, attributes: [
                                .font: courier(size: CGFloat(metrics.size)),
                                .foregroundColor: NSColor.black,
                                .kern: nativeNoKerning,
                                .ligature: nativeNoLigatures,
                            ]),
                            xPt: label.x, baselineY: engineY))
                    }
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
                // 3.0, not 2.0: MARKUP.WS's 2pt-lead page is where the isolated probe is
                // furthest out. Its last fragment's real in-context baseline sits ONE POINT
                // ABOVE its own top (top 79, baseline 78) while the isolated probe answers
                // two points below — a 3pt discrepancy, and at 2.0 the container came out
                // half a point short of its own last line, which then did not lay out at all.
                //
                // Still far below a line: a leak needs room for the NEXT fragment's whole
                // height, and the smallest lead in this corpus is 2pt. One more point cannot
                // admit a line anywhere, which is the property job 412's straight override
                // exists to keep.
                let isolatedKSafetyMargin: Double = 3.0
                columnBottoms.append(lastGroupBottom - lastGroupK + isolatedKSafetyMargin)
                let columnTop = firstGroupTop ?? columnFirstBaseline
                columnTops.append(columnTop)
                if columnFirstLead < normalBaselineOffset {
                    tightestFlowTop = min(tightestFlowTop ?? columnTop, columnTop)
                }
                columnCounts.append(columnFragments)
                }
                pinnedPageBottoms.append(columnBottoms)
                pinnedPageTops.append(columnTops)
                pageColumnCounts = columnCounts
                output.append(pageChunk)
            }
            softLineFlags.append(flags)
            overprintPasses.append(passes)
            oversizedSelfPasses.append(selfPasses)
            pageColumnFragmentCounts.append(pageColumnCounts)
            allNumberPasses.append(numberPasses)
            allGraphicRows.append(graphicRows)
        }

        // #271 M7: the pages rendered so far, as a document. Before the last page it works on copies
        // of the flow and of the per-page tops, so the session can go on; the final snapshot finishes
        // them in place, exactly as this function's tail always did.
        func snapshot(final: Bool) -> RenderedDocument {
        let flow = final ? output : NSMutableAttributedString(attributedString: output)
        var pageTextTops = perPageTextTop
        let renderedPageCount = softLineFlags.count
        // The flow needs no trailing newline: the last line's own terminator already closed
        // it, and an extra one would start a phantom page.
        if flow.length > 0 { flow.deleteCharacters(in: NSRange(location: flow.length - 1, length: 1)) }

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
        // AND THE ANCHOR NEVER SITS BELOW THE FLOW IT ANCHORS.
        //
        // `textTop` is `firstBaseline` less an ISOLATED probe fragment's own first-baseline
        // offset, which is right wherever the document's lead leaves room for the face's
        // ascent and wrong where it does not: MARKUP.WS sets its whole page at a 2pt lead, so
        // the probe answers a NEGATIVE offset and the anchor lands at 39.0 for a first
        // baseline of 38.0 — the flow begins a point above the box that holds it, and its
        // first line was clipped straight out of the exported page.
        //
        // `pinnedPageTops` is the real answer, measured from the fragments this loop actually
        // built. Lowering the anchor to it moves the container's own origin and every page's
        // `perPageTextTop` by the SAME amount, so every absolute baseline still converts to
        // the same place and nothing on any ordinary page moves: the adjustment is zero
        // unless some page's flow really does start above the anchor.
        //
        // GATED ON THE PROBE'S OWN ANSWER BEING NEGATIVE, which is the only way the anchor can
        // end up below the flow. Measured without that gate and it was far too wide: an
        // OVERSIZED first line's fragment top sits well above its baseline by construction
        // (DARKNESS.WS's 16pt title, SCRIPT.WS's), so taking the minimum over every page
        // dragged the whole document's anchor and cost DARKNESS.WS its title off page 1 and
        // SCRIPT.WS page 10 a 56pt top-margin shift. A tall line is not an anchor error; a
        // negative baseline offset is.
        // ONLY WHERE A LINE IS TOO SHORT TO HOLD ITS OWN ASCENT, which is the only shape
        // that can put the anchor below the flow. Measured without that gate and it was far
        // too wide: an OVERSIZED first line's fragment top sits well above its baseline by
        // construction, so taking the minimum over every page dragged the whole document's
        // anchor — DARKNESS.WS lost its 16pt title off page 1 and SCRIPT.WS page 10 took a
        // 56pt top-margin shift. The condition is the page's own FIRST LINE's lead against
        // the face's own first-baseline offset, not the document's default lead: MARKUP.WS
        // declares `.lh` 12 and sets every line of page 1 at 2.
        let flowTopAdjustment = min(0, (tightestFlowTop ?? textTop) - textTop)
        if flowTopAdjustment < 0 {
            for index in pageTextTops.indices {
                pageTextTops[index] = max(0, pageTextTops[index] + flowTopAdjustment)
            }
        }
        let textFrame = CGRect(
            x: printedLeftAnchor,
            y: max(0, textTop + flowTopAdjustment),
            width: max(1, metrics.pageWidth - printedLeftAnchor),
            height: CGFloat(capacity) * metrics.lead - flowTopAdjustment
        )
        let leadingHeadroom = Self.leadingHeadroom(oversizedSelfPasses, firstBaselines: perPageFirstBaselines)

        var rendered = RenderedDocument(
            text: flow,
            pageSize: pageSize,
            textFrame: textFrame,
            pageCount: max(1, renderedPageCount),
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
            realPageIndexByPage: Array(0..<max(1, renderedPageCount)),
            pinnedBaselines: pinnedBaselines,
            perPageTextTop: pageTextTops,
            pinnedPageBottoms: pinnedPageBottoms,
            pinnedPageTops: pinnedPageTops,
            flowTopAdjustment: flowTopAdjustment,
            pageColumnFragmentCounts: pageColumnFragmentCounts,
            lineNumberPasses: allNumberPasses,
            graphicCellRows: allGraphicRows,
            // Printed has no screenplay-marker concept — see `RenderedDocument
            // .modernForcedPageBreakOffsets`'s own doc comment.
            modernForcedPageBreakOffsets: [],
            // Printed's own footnote placement is the engine's real pagination
            // (`docToPagelines`), already resolved by the time this function sees it — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            modernEndnoteAppendixStart: nil,
            pclPrograms: doc.pclPrograms
        )
        // A hand-picked Page Size is the paper for every page; a page the engine turned keeps its turn on that paper.
        let documentLandscape = metrics.pageWidth > metrics.pageHeight
        let manualPaper = state.pageSize.provenance == .manual && state.pageSize.value != nil
        rendered.perPageSize = work.sheets.prefix(max(1, renderedPageCount)).map { sheet in
            guard manualPaper else { return sheet }
            guard (sheet.width > sheet.height) != documentLandscape else { return pageSize }
            return CGSize(width: pageSize.height, height: pageSize.width)
        }
        return rendered
        }
        return NativeRenderSession(pageCount: pages.count,
                                   renderPage: { index in renderPage(index, pages[index]) },
                                   snapshot: snapshot)
    }
}
