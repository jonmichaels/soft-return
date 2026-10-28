#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Printed, Show Invisibles (job 256/257, parts 2-3/4)

    /// `renderNative`'s sibling for the `showInvisibles` screen path — same page metrics,
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
    ///      like `renderNative`'s `advanceLead`. This is why a dot-heavy page can render
    ///      MORE pages with Invisibles on than off, never fewer — the ruling.
    ///   2. Running heads/feet are looked up from whichever REAL `docToPagelines` page is
    ///      "in force" at each local page's own position (tracked per real line via
    ///      `flatPageIndex`, not by matching index) — correct once reflow has made the two
    ///      page counts diverge, and identical to job 256's approximation on any document
    ///      that never diverges (the common case).
    ///   3. Reuses `renderNative`'s own two per-line mechanisms directly against the REAL
    ///      `PageLine` each annotated real line pairs with: `.overprint` chain compositing
    ///      (job 224) and oversized-self-pass routing (job 227, `lineExceedsFragment`) — a
    ///      real line's `.visible` text is suppressed inline and the SAME annotated content
    ///      (marks included) re-rendered as a natural-height pass/self-pass, so LJ6DTP's
    ///      banners and knockouts survive Invisibles being on. Dot-command/mark-only lines
    ///      never chain and are never oversized (`baseFont`, always well under any `.lh`).
    static func renderNativeAnnotated(_ state: DocumentState) -> RenderedDocument {
        let render = nativeAnnotatedRender(state)
        render.renderAll()
        return render.finish()
    }

    /// Batch 27: `renderNativeAnnotated`'s work in slices (`SlicedRender`): the line units, their wrapped row
    /// counts, the page-break walk, then the pages — each loop body the one it always was. `engine`: the engine's
    /// half made already, off the main thread, for `state` as it is now; nil makes it here.
    public static func nativeAnnotatedRender(_ state: DocumentState, engine: NativeAnnotatedEngineWork? = nil) -> SlicedRender {
        // #271 M2: the same printed document `renderNative` lays out — see its own comment.
        let options = EmitOptions(pageSettings: state.pageSettingsPreset.value?.settings,
                                  pixResults: state.pixResults)
        let work = engine ?? NativeAnnotatedEngineWork.make(document: state.document, options: options)
        let doc = work.doc
        let metrics = work.metrics
        let baseFont = courierPrime(size: CGFloat(metrics.size))
        let annotated = work.annotated
        let pages = work.pages
        // Every REAL line's own engine `PageLine` (lead/overprint/spans), in document
        // order, and which `pages` index it came from — `flatLines[n]` and
        // `flatPageIndex[n]` describe the SAME real line `pages` itself already produced.
        let flatLines: [PageLine] = pages.flatMap { $0 }
        var flatPageIndex: [Int] = []
        flatPageIndex.reserveCapacity(flatLines.count)
        for (pi, page) in pages.enumerated() { flatPageIndex.append(contentsOf: Array(repeating: pi, count: page.count)) }
        // #270 item 36 (sr 4ff64d5, layout JSON v9): a 0x0F print control's SCREEN label is drawn
        // nowhere but here, in Show Invisibles, and here as a mark, never as the page's ink.
        // `annotatedLayout` hands it over as an ordinary `.visible` span (`AnnotatedSpan` carries no
        // `pctlHMI`), so the labels come from the engine's own page-lines: every span
        // `docToPagelines` marks with `pctlHMI`, the same harvest the layout JSON now publishes as
        // `invisibles["print_controls"]`. Before this, this pass drew them as ordinary black text.
        let printControlLabels = Set(flatLines.lazy.flatMap(\.spans)
            .filter { $0.pctlHMI != nil && !$0.text.isEmpty }.map(\.text))

        func paragraphStyle(lead: Double) -> NSParagraphStyle {
            nativeLineParagraphStyle(fontSize: Double(metrics.size), lead: lead)
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
        // character — so `endMark`'s own ¬/¶ glyph (appended once, after the LAST span) can
        // never appear anywhere but the paragraph's true end, matching "wrap points show no
        // soft-return icon" exactly by construction, not by suppressing anything.
        func wrapParagraphStyle(lead: Double) -> NSParagraphStyle {
            nativeLineParagraphStyle(fontSize: Double(metrics.size), lead: lead, lineBreakMode: .byWordWrapping)
        }
        func naturalParagraphStyle() -> NSParagraphStyle {
            nativeLineParagraphStyle(fontSize: Double(metrics.size), lead: nil)
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
            let manager = softReturnLayoutManager()
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
        // `renderNative`'s own `nearZeroLead` (this file's citation on that one) — an
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
            invisibleMarkRun(text, font: font, spoken: spoken, paragraph: paragraph)
        }
        // A mark's own face — "SAME face/size as their line" (job 256's brief): every
        // `AnnotatedSpan` already carries the host run's own `font` (`AnnotatedSpan`'s own
        // doc comment: "so a viewer can size a mark like the line it sits in without
        // re-deriving the surrounding run"), so this is a direct read, never a guess.
        //
        // Batch 40 (M14, Athena's rule: one glyph and one colour per kind of mark): every mark is set in the page's base
        // face, `baseFont`, whatever run it sits in. A mark in its run's own face and weight took that run's size and
        // bold/italic — a `.h1` title's marks drawn huge beside body-sized ones, a style toggle bold in one place and
        // plain in the next — and a mark taller than the line's lead reached into the lines around it.
        func markFont(_ font: FontChange?, styles: Style) -> NSFont {
            baseFont
        }

        // JOB 257: `suppressVisible` blanks a line's OWN `.visible` text — used only for an
        // oversized real line's INLINE fragment, mirroring `renderNative`'s own
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
                case .visible where printControlLabels.contains(span.text):
                    // A print control's label (#270 item 36): the marks' colour and face, never ink.
                    guard !suppressVisible else { continue }
                    result.append(markRun(span.text, font: markFont(span.font, styles: span.style),
                                          spoken: "print control: \(span.text)", paragraph: paragraph))
                    leading = false
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
                    // `nativePMActive` unset: `AnnotatedLine` carries no `.pm` state, so a
                    // proportional line's typed leading indent keeps this path's own long-
                    // standing 10-CPI measure rather than the engine's two-measure rule. Same
                    // documented shape as this conversion's colour loss above; the marks
                    // overlay is not the facsimile.
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
                // Batch 40 (M14): "¬" for a soft return. System Courier, `baseFont`, has no "↵" (nor "↩", "⏎" or "↲"
                // — measured with CTFontGetGlyphsForCharacters), so every soft-return mark was drawn in a fallback face
                // with its own, taller metrics; it has "¬" and "¶".
                let symbol = endMark == .softReturn ? "¬" : "¶"
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
        // in exactly the same relative order `resolvePrintedBody`/`docToPagelines` produced
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
        func unitStep(_ lineIndex: Int) {
            let line = annotated.lines[lineIndex]
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
        func rowStep(_ unitIndex: Int) {
            let unit = units[unitIndex]
            guard unit.wrapEligible else { unitRows.append(1); return }
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
        func walkStep(_ i: Int) {
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

        func pageStep(_ groupIndex: Int) {
            let start = pageStarts[groupIndex]
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
                    // successor shares ITS baseline too (see `renderNative`'s own doc
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
                    // bleed not to matter, so `renderNative` carries no equivalent — this is
                    // scoped to `renderNativeAnnotated` alone, a screen-only reflow surface,
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
                    // A loop, not `.map`: inside a step `SlicedRender` holds, a closure handed to `map` is a region
                    // of its own, and capturing `naturalPass` (its face and paragraph) there is a data-race error.
                    var chainPasses: [NSAttributedString] = []
                    if k < m {
                        for member in (k + 1)...m {
                            chainPasses.append(naturalPass(units[member].line))
                        }
                    }
                    passes.append(chainPasses)
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
                // The annotated (Show Invisibles) path anchors its own frame at `metrics.left`
                // — it is an informational reflow layer, exempt from the facsimile gates, and
                // does not carry the per-line `.po` anchoring the plain path needs.
                ? Self.runningLines(for: pages[realPageIndex], pageNo: startNo + realPageIndex,
                                    doc: doc, metrics: metrics, leftAnchor: metrics.left)
                : [])
        }
        func finish() -> RenderedDocument {
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        // Same geometry formulas `renderNative` uses (see that function's own extensive
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
        // Placed on the sheet as plain Native is (`logicalPageX`): the engine's x = 0 sits at
        // the LaserJet's logical page, 1/4" in on Letter.
        let documentLogicalX = logicalPageX(doc, orientation: printedPageOrientation(doc, nil),
                                            sheetWidth: Int(metrics.pageWidth.rounded()))
        let textFrame = CGRect(
            x: metrics.left + documentLogicalX, y: textTop,
            width: max(1, metrics.pageWidth - metrics.left),
            height: CGFloat(metrics.capacity) * metrics.lead
        )
        // Job 425: this path's `pinnedBaselines` is always empty by construction (see
        // `NSLayoutManagerDelegate`'s own "Modern style and the Show Invisibles screen path
        // both hand back an EMPTY dictionary" citation, `PagedDocumentView.swift`) — the
        // per-page real-anchor fix `renderNative` needed for its own `leadingHeadroom` call
        // does not apply here (there is no pin to correct), so every page keeps the SAME
        // flat nominal anchor this path always used. Not a per-page regression: unchanged
        // from before this job.
        let leadingHeadroom = Self.leadingHeadroom(
            oversizedSelfPasses, firstBaselines: Array(repeating: firstBaseline, count: oversizedSelfPasses.count))

        var annotatedNative = RenderedDocument(
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
            pinnedPageBottoms: [], pinnedPageTops: [], flowTopAdjustment: 0, pageColumnFragmentCounts: [], lineNumberPasses: [], graphicCellRows: [],
            // Printed-annotated has no screenplay-marker concept either — same reason as
            // plain Printed's own call site.
            modernForcedPageBreakOffsets: [],
            // Same reason as plain Printed's own call site.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            modernEndnoteAppendixStart: nil,
            pclPrograms: doc.pclPrograms
        )
        annotatedNative.documentLogicalPageX = documentLogicalX
        return annotatedNative
        }
        return SlicedRender(phases: [
            SlicedRender.Phase(count: { annotated.lines.count }, step: unitStep),
            SlicedRender.Phase(count: { units.count }, step: rowStep),
            SlicedRender.Phase(count: { units.count }, step: walkStep),
            SlicedRender.Phase(count: { pageStarts.count }, step: pageStep),
        ], finish: finish)
    }
}
