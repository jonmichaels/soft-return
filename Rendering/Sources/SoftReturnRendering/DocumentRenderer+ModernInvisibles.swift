#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Modern, Show Invisibles (job 294, Jon's ruling)

    /// `renderModern`'s sibling for the `showInvisibles` screen path — job 300 REWRITE.
    ///
    /// Jon's b16 field report on OLDTIMES (screenshots on file): toggling Show Invisibles
    /// in Modern changed the LAYOUT — centering lost, the def-list/bullet ladder collapsed,
    /// `^B`/`^Y` style tokens shown as literal inline text instead of applying as real
    /// bold/italic, a stray `^Y` at the left margin, different wrap/spacing. The ROOT CAUSE
    /// (job 294's own original design): this function walked `CtrlKD.annotatedLayout(doc)`
    /// — the RAW per-physical-line stream `renderNativeAnnotated` uses for Native — instead
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
    ///   attributed line (Native's own placement, `renderNativeAnnotated`) — it can only
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
    ///   that caused this job. Native's own philosophy (`renderNativeAnnotated`) inserts
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
    /// Batch 40 (M14): the room, in points, Show Invisibles leaves between a Modern line's last glyph and its "¶" —
    /// more than the 0.68 pt a glyph's ink was measured overhanging its advance, taken back from the mark's own advance.
    public static let modernHardReturnRoom: CGFloat = 1.5

    /// Batch 40 (M14): Show Invisibles' Modern "¶", as a fraction of the body size — small enough that its ink clears a
    /// descender on a tightly led row above (b40-m14-after4), and every hard return the same size.
    public static let modernHardReturnScale: CGFloat = 0.8

    internal static func renderModernAnnotated(
        _ state: DocumentState, notes: Set<NoteKind> = EmitOptions.defaultNotes,
        exportFlags: ExportFlags = .allOn
    ) -> RenderedDocument {
        let render = modernAnnotatedRender(state, notes: notes, exportFlags: exportFlags)
        render.renderAll()
        return render.finish()
    }

    /// Batch 27: `renderModernAnnotated`'s work in slices (`SlicedRender`), one flow item a step, the loop body
    /// the one it always was. `flow`: `modernSemanticFlow` made already, off the main thread, with `notes`.
    public static func modernAnnotatedRender(
        _ state: DocumentState, notes: Set<NoteKind> = EmitOptions.defaultNotes, flow engineFlow: SemanticFlow? = nil,
        furniture engineFurniture: [ModernPageFurniture]? = nil,
        exportFlags: ExportFlags = .allOn
    ) -> SlicedRender {
        let doc = state.document
        let basis = Self.modernBasis(state)
        let size = basis.size
        let bodyFont = basis.bodyFont
        let modernFallbackFont = basis.fallbackFont
        let modernFontlessFamily = basis.fontlessFamily
        let colPt = basis.colPt
        // A GRAPHIC CELL IS SIZED BY THE PRINTED TYPE, not the Modern type. The library's
        // `modernTokenWidth` graphic branch is `spanPitch(entry, printedPt)` — the document's
        // own fixed-pitch size (`printedSize`, its `.cw`), never the Modern point size the
        // prose beside it is set in. Measured on VERSIONS.WS's bullet rows: its marker cell
        // is 7.20pt in the library (12 x 0.6) and was 8.40 here (14 x 0.6), so every one of
        // those rows started 1.20pt right of the library's and lost its last word.
        let modernPrintedPt = basis.printedPt
        var flow = engineFlow ?? modernSemanticFlow(doc, notes: notes)
        // b34 N1 (job 529): same collapse as `renderModern`'s identical citation —
        // Show Invisibles' own note/footnote appendix reads `flow.notes[...].text` too
        // and must match what the OFF-state view (and export) actually show.
        Self.modernCollapseNoteSpacing(&flow)
        let items = flow.items
        // Planning #264 (layout JSON v10, sr 924bad9): the 0x0F print controls the flow dropped,
        // by the item they sat in. Their labels are drawn here and nowhere else: Show Invisibles
        // is the one surface allowed to show them, and here as marks, never as ink. The same list
        // `emitLayout` publishes as `invisibles["modern_print_controls"]`.
        var printControlsByItem: [Int: [SemanticPrintControl]] = [:]
        for control in flow.printControls where !control.label.isEmpty {
            printControlsByItem[control.item, default: []].append(control)
        }
        let blockHangCols = Self.defListBlockHangCols(items: items, colPt: colPt)
        // Job 434: the SAME figure `renderModern` hoists for its own `modernLeadingSpacer`
        // measurement — `InvisiblesModernLayoutOracle`'s own law (job 300) requires this
        // function to insert the identical spacer paragraph `renderModern` does, at the same
        // place, so a page-1 oversized title's screen affordance stays invisible to that
        // oracle's per-item comparison, not a Show-Invisibles-only layout change.
        // Batch 41 (A): the same engine page `renderModern` lays out on (`modernPage`) — made off
        // the main thread by a window, with the flow (`engineFurniture`), since it runs the whole
        // Modern emitter: made here it held -HOLYMAC.WS's main thread 1.7 s (b41-a).
        // Batch 42: asked with this render's own flags, as the plain session asks — see `modernEngineOptions`.
        let modernFurniture = engineFurniture
            ?? modernPageFurniture(doc, options: Self.modernEngineOptions(state, exportFlags: exportFlags))
        let modernPage = Self.modernPage(state, furniture: modernFurniture)
        let modernTextWidthPt: Double = max(1, Double(modernPage.measure))
        let blankParagraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                        indentCols: 0, cutCols: 0)
        let noteFont = basis.noteFont
        let noteParagraph = basis.noteParagraph

        let output = NSMutableAttributedString()

        // Batch 40 (M14): the "¶" is set smaller than the body. At the body's 14 pt its ink rises 9.70 pt above the
        // baseline; on -README.WS page 18 a row set about 12.5 pt below the one above put that ink 1.23 pt into a
        // descender above it (b40-m14-after4). At `modernHardReturnScale` it rises 7.76 pt — still taller than the
        // text's x-height — and every hard return, on a line or alone on a blank one, is the one size.
        let hardReturnFont = bodyFont.withSize(bodyFont.pointSize * Self.modernHardReturnScale)
        func markRun(_ text: String, paragraph: NSParagraphStyle, spoken: String, font: NSFont? = nil) -> NSAttributedString {
            invisibleMarkRun(text, font: font ?? bodyFont, spoken: spoken, paragraph: paragraph)
        }
        func appendNoteLine(_ text: String) {
            output.append(Self.modernNoteLine(text, font: noteFont, paragraph: noteParagraph))
        }
        // Job 452: hoisted above the loop — see `renderModern`'s identical citation on
        // why the `.noteSeparator` case below needs this to emit footnotes first.
        let footnoteRows = flow.notes.enumerated().filter { $0.element.kind == .footnote }
        var footnotesEmitted = false

        func itemStep(_ i: Int) {
            let item = items[i]
            switch item {
            case .para(let align, let indentCols, let cutCols, let runs, _, let structure, let isVerse, _):
                // The same line face `renderModern` measures its own leading spacer and
                // tight leading against — job 300's ruling again: invisibles ON is the OFF
                // layout with marks added, so the two passes must reserve the identical
                // headroom and stack at the identical height.
                let paragraphFace = Self.modernParagraphFace(
                    runs: runs, fonts: doc.fonts, size: size,
                    fontlessFamily: modernFontlessFamily)
                let (paragraphSpans, paragraph) = Self.modernParagraphContent(
                    align: align, indentCols: indentCols.value, cutCols: cutCols.value, runs: runs,
                    structure: structure, colPt: colPt, size: size, font: bodyFont,
                    blockHangCols: blockHangCols[i], isVerse: isVerse,
                    fonts: doc.fonts, printedPt: modernPrintedPt,
                    tightFamily: paragraphFace.family)
                // THE SAME BREAK MARKS `renderModern` PUTS IN. Job 300's ruling is that
                // invisibles ON is the OFF layout with marks ADDED — nothing moves — and
                // these two passes MOVE things: they are what decides where a line breaks.
                // Leaving them out of this path made ON and OFF two different documents, and
                // `InvisiblesModernLayoutTests` reported it on OLDTIMES.WS, STRENGTH.WS and
                // VERSIONS.WS. The measure is the same one this function computes below, so
                // it is hoisted here the way `renderModern` hoists its own.
                let annotatedMeasureWidthPt = max(
                    1, modernTextWidthPt - indentCols.value * colPt - cutCols.value * colPt)
                let renderSpans = Self.joinOversizedTokens(
                    Self.runBoundaryBreaks(paragraphSpans),
                    font: modernFallbackFont, fonts: doc.fonts, defaultSize: Int(size),
                    measurePt: annotatedMeasureWidthPt)
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
                    useCourierPrime: true,
                    modernPitchScale: true, modernPrintedPt: modernPrintedPt,
                    modernFontlessFamily: modernFontlessFamily
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
                    // Planning #222 (b): backing `tight` off has to RESTORE THE BODY'S
                    // leading, not merely remove the compression. Clearing the multiple used
                    // to be enough because the body's own leading was AppKit's natural
                    // metric, so "no attribute" and "normal body leading" were the same
                    // thing. They are not any more: the body is pinned to the library's
                    // 1.2x, and a bare `= 0` left this paragraph at AppKit's natural 16.0
                    // against a 16.8 body — job 437's ruling read literally as the number it
                    // happened to produce, instead of as the RELATION it states (a
                    // soft-wrapped continuation gets the body's leading, whatever that is).
                    paragraph.lineHeightMultiple = 0
                    let restored = CGFloat(size) * Self.modernLibraryLineFactor
                    paragraph.minimumLineHeight = restored
                    paragraph.maximumLineHeight = restored
                    line = NSMutableAttributedString(attributedString: attributedLine(
                        coalesce(PageLine(renderSpans)).spans,
                        font: modernFallbackFont,
                        paragraph: paragraph,
                        fonts: doc.fonts,
                        defaultSize: Int(size),
                        useCourierPrime: true,
                        modernPitchScale: true, modernPrintedPt: modernPrintedPt,
                        modernFontlessFamily: modernFontlessFamily
                    ))
                }
                line = NSMutableAttributedString(attributedString: Self.modernBulletGapCell(line, structure: structure))
                // b28 note 9 (part 2): same suppression `renderModern` applies — see that call
                // site's own citation. Must mirror it exactly (job 300's ruling, this
                // function's own header) rather than re-deriving it.
                let precededByGraphicRow = i > 0
                    && Self.paraContainsGraphicChar(items[i - 1]) && Self.paraContainsGraphicChar(item)
                if !precededByGraphicRow, let spacer = Self.modernLeadingSpacer(
                    for: line, paragraph: paragraph, bodyFont: bodyFont, face: paragraphFace) {
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
                //
                // Planning #264 (layout JSON v10): a print control's label goes in the same way,
                // ahead of the run it preceded (`SemanticPrintControl.run`; `runs.count` is after
                // the last run). Offsets count UTF-16 units, which is what `line` indexes by. A
                // centered or structured row rebuilds its runs (padding trimmed, a marker or label
                // split off), so a run index has no offset there: its labels go after the line's
                // content, ahead of the ¶.
                let isPlainParagraph = structure?.centered != true && structure?.kind == nil
                let printControls = printControlsByItem[i] ?? []
                func printControlMark(_ control: SemanticPrintControl) -> NSAttributedString {
                    markRun(control.label, paragraph: paragraph, spoken: "print control: \(control.label)")
                }
                if isPlainParagraph {
                    // Batch 40 (M14): the offset walks `line` itself, stepping over the zero-width break characters
                    // `runBoundaryBreaks` and `joinOversizedTokens` put in (U+200B, U+2060), which no run's own text
                    // holds. Summing the runs' lengths alone left every later mark that many characters short of its
                    // run's boundary: inside a word, or splitting a token the joiners hold together.
                    var position = 0
                    func isInsertedBreak(_ index: Int) -> Bool {
                        let unit = line.mutableString.character(at: index)
                        return unit == 0x200B || unit == 0x2060
                    }
                    func insertMark(_ mark: NSAttributedString) {
                        line.insert(mark, at: min(position, line.length))
                        position += mark.length
                    }
                    for (runIndex, run) in runs.enumerated() {
                        for control in printControls where control.run == runIndex {
                            insertMark(printControlMark(control))
                        }
                        if run.ref != nil, run.text.isEmpty {
                            insertMark(markRun("[comment]", paragraph: paragraph, spoken: "comment"))
                        } else {
                            var remaining = run.text.utf16.count
                            while remaining > 0, position < line.length {
                                if !isInsertedBreak(position) { remaining -= 1 }
                                position += 1
                            }
                        }
                    }
                    for control in printControls where control.run >= runs.count {
                        line.append(printControlMark(control))
                    }
                } else {
                    for control in printControls {
                        line.append(printControlMark(control))
                    }
                }
                // Batch 40 (M14): a little room between the line's last glyph and its "¶". The mark sat at the last
                // glyph's advance, and a glyph's ink can overhang its advance — b40-m14-after2 measured 28 marks on
                // -README.WS touching the letter before them, by up to 0.68 pt. The room is added after the last
                // character and taken back from the mark's own advance, so the line is exactly as wide as it was: it
                // breaks where it broke and nothing on it moves (job 300's ruling, `InvisiblesModernLayoutTests`).
                let hardReturn = NSMutableAttributedString(attributedString: markRun(
                    "¶", paragraph: paragraph, spoken: "hard return", font: hardReturnFont))
                if line.length > 0 {
                    let last = (line.string as NSString).rangeOfComposedCharacterSequence(at: line.length - 1)
                    let existing = (line.attribute(.kern, at: last.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                    line.addAttribute(.kern, value: existing + Double(Self.modernHardReturnRoom), range: last)
                    hardReturn.addAttribute(.kern, value: -Double(Self.modernHardReturnRoom),
                                            range: NSRange(location: 0, length: hardReturn.length))
                }
                line.append(hardReturn)
                output.append(line)
                output.append(lineTerminator(font: bodyFont, paragraph: paragraph))
            case .blank:
                // The author's own blank line — a hard return with no text of its own, so
                // unlike `renderModern`'s invisible-space placeholder, the "¶" mark alone
                // already gives AppKit a real glyph on this line's baseline grid (same
                // font/paragraph as the placeholder would have used) — matching Native's
                // own blank-hard-return line, which shows only "¶", no leading space.
                output.append(markRun("¶", paragraph: blankParagraph, spoken: "hard return", font: hardReturnFont))
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
                guard !text.isEmpty else { return }
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
                return
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
        func finish() -> RenderedDocument {
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

        // Same paper/margin choice as the plain Modern path (`modernTextFrame` carries the
        // reasoning) — Show Invisibles changes what's drawn, never the page it is drawn on.
        let paper = modernPage.paper
        let textFrame = modernPage.textFrame

        markModernSquareBullets(output)
        var annotated = RenderedDocument(
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
            pinnedPageBottoms: [], pinnedPageTops: [], flowTopAdjustment: 0, pageColumnFragmentCounts: [], lineNumberPasses: [], graphicCellRows: [],
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
            modernEndnoteAppendixStart: nil,
            pclPrograms: [],
            modernFurniture: modernFurniture,
            // Passed EXPLICITLY, not left to its default: this is the annotated path (Show Invisibles), and a
            // `RenderedDocument` that quietly reported `.allOn` would draw the furniture's heads on an export
            // that asked for none — the same fault, one render path over. See `RenderedDocument.exportFlags`.
            exportFlags: exportFlags
        )
        let furnitureFonts = Self.modernFurnitureFonts(doc, bodyFallback: modernFallbackFont, bodySize: size)
        annotated.modernFurnitureFont = furnitureFonts.font
        annotated.modernHeaderFonts = furnitureFonts.headers
        annotated.modernFooterFonts = furnitureFonts.footers
        return annotated
        }
        return SlicedRender(phases: [SlicedRender.Phase(count: { items.count }, step: itemStep)], finish: finish)
    }

    /// `CtrlKD.Alignment` (the block's own `.oc`/`.oj` state, `SemanticItem.para`'s `align`)
    /// to AppKit's paragraph-style enum — the same four cases `rtfAlignControl`
    /// (`EmitRTF.swift`) maps to `\ql`/`\qc`/`\qr`/`\qj`.
    static func modernNSAlignment(_ align: Alignment) -> NSTextAlignment {
        switch align {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justify: return .justified
        }
    }
}
