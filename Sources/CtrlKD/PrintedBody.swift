/// One body item of the printed paginator: an explicit break, a conditional page break, a
/// verbatim line, or a running head/foot occurrence.
enum PrintedBodyItem {
    /// `formFeed`: the break is a bare form feed in the text (`origin == .ff`), not a
    /// `.pa`/`.cb` -- WS7 ejects the sheet there without running its page-end routine, so
    /// the page it ends prints no foot (WS7 report 14.3, run ff2; WS4 report 3.2).
    case pageBreak(formFeed: Bool = false)
    /// `.cp n` / `.cc n` — resolved by the paginator, the only thing that knows how full
    /// the page is.
    case condPage(Int)
    /// A body line, plus the footnote/annotation notes whose `fnref` reference falls on it.
    /// `due` pairs each note with its index in `doc.notes` — the identity `noteLabel` needs
    /// (Python threads the precomputed label itself through its stream refs). Endnotes are
    /// collected separately at the end of the document — they never compete for page-bottom
    /// room. Empty for a line carrying no footnote/annotation reference.
    case line(PageLine, due: [(note: Note, index: Int)])
    /// A `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, replayed at the block it precedes.
    /// `parity` (planning #250) is `nil` for a plain `.h1`/`.he`/`.f1`/`.fo`, else
    /// `.even`/`.odd` for `.h1e`/`.h1o`/`.f1e`/`.f1o`.
    case hf(kind: HFKind, line: Int, text: String, parity: HFParity?, pcl: [HFPrintControl])
}

/// What the body walk layers on top of the lines themselves, resolved once per document:
/// the running head/foot replay, `.psb`/`.psa` space before/after, the `.pm` first-line
/// indent and per-line `.sr` roll, and the WS4 double-spacing classification. Every printed
/// document takes the same walk, with or without notes (planning #577, ruling R-130).
private struct PrintedBodyRules {
    var headFoot: HeadFootReplay
    /// b24 round 17 (RULINGS-LEDGER row 5/7): `.psb`/`.psa` extend round 6's RTF vertical-space
    /// model to Printed PDF, same relative-computation rules.
    var docSb: Double?
    var docSa: Double?
    /// Finding 1 (b26 visual pass): `[blockIndex: blank line indices]` that are a WS4
    /// document's own double-spacing idiom (`ws4SpacingBlankIndices`), empty for every
    /// other document by construction.
    var ws4SpacingBlanks: [Int: Set<Int>] = [:]

    init(_ doc: Document) {
        headFoot = HeadFootReplay(doc)
        (docSb, docSa) = printedDocSpacingPt(doc)
        // Scoped, per Jon's binding ruling, to a POSITIVELY-DETECTED condition --
        // `variant == .ws4` -- rather than trusting the block-pattern detector alone to stay
        // harmless everywhere else: `-README`/`VERSIONS` (both `ws5+`) picked up real
        // cross-page drift the first time this shipped scoped only by pattern, and "a rule
        // that un-matches exact documents to fix others is not WS7's real rule" (Jon).
        // Widening this gate past `ws4` needs its own oracle evidence. The forgiveness is
        // WS7's (`Era.forgivesSpacingBlank`): a WS4 file printed by WS4 has none.
        if doc.detection?.variant == .ws4, printingEra(doc).forgivesSpacingBlank {
            // Prefer the file's OWN `.LS` dot-state when it exists (WS7 manual, "Line
            // Spacing"): neither WS4 source measured sets `.LS` at all (WS4 predates the
            // dot command), so the structural fallback carries the detection, but a future
            // capture that DOES carry an explicit `.LS 2`+ is trusted over the pattern.
            let lsConfirmed = doc.page?.lsSource == .file && (doc.page?.ls ?? 1) > 1
            ws4SpacingBlanks = ws4SpacingBlankIndices(doc, lsConfirmed: lsConfirmed)
        }
    }
}

/// One span of a printed body line as the paginator carries it: the block's paragraph-style
/// attributes and colour merged in ("headings render bold"), and the document's driver-keyed
/// cp437-158 rule (`pesetaMeansEuro`, planning #266) applied. This path reads the document's
/// own spans directly and never passes through `modernSemanticFlow`, so it applies that
/// rule itself.
///
private func printedSpan(_ sp: Span, block: Block, euro: Bool) -> Span {
    let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
    // Register C5: the block's own paragraph-style colour is a default for every span it
    // governs, so it can move a span that carries no attribute change at all.
    let colour = effectiveSpanColour(sp, block: block)
    let text = euroText(sp.text, euro)
    let restyled = styles != sp.styles || colour != sp.colour
    if !restyled && text == sp.text { return sp }
    // `pix` rides along even when the styles changed (round 22 — the pix substitution needs
    // it), and `pcl` likewise (register C2): a HEADING block is exactly where the merge
    // changes the styles (headingBold), and LJ6DTP puts the page-border print control on a
    // heading line on four of its eight pages.
    return Span(text: text, styles: styles, font: sp.font, colour: colour,
                pctlHMI: sp.pctlHMI,
                pix: sp.pix, pcl: sp.pcl, tabHMI: sp.tabHMI, tabLeader: sp.tabLeader)
}

/// Blocks -> printed body items: the ONE walk the printed paginator reads, whether or not
/// the document has notes. Every `fnref` span is resolved to its displayed marker and the
/// footnote/annotation notes due on each line are returned beside it (`due`); a comment's
/// reference mark is dropped (`keepSpanOnPageline`), `doc.hfEvents` replay at the blocks they
/// precede, and `PrintedBodyRules` supplies the rest.
///
/// The parser numbers EVERY `fnref` sentinel (footnote, endnote, and annotation alike, in
/// document order — comments never get one printed) with one shared counter, so a span's raw
/// text is only a position, not a display value: the n-th `fnref` span corresponds to the
/// n-th note, and THAT, not the span's own text, decides what prints. This used to walk
/// `referenced` with a running cursor, which agrees with the text only while EVERY mark
/// reaches the loop; `pfRewrappedLines` now takes a comment's mark off the line first
/// (`dropCommentMarks`), and a cursor then resolved every later mark to the wrong note.
/// ctrl-kd's `_body_stream_printed` has always read the text (`k = int(s.text)`). A `fnref`
/// with no corresponding note (more sentinels than notes — malformed input, or a stray
/// control byte the parser mistook for one) is left as found rather than crashing or
/// dropping it; `stray_sentinel` is exactly this case.
///
/// `pixResults`/`pictures` (b24 rounds 19 and 22): a physical line whose only real content is
/// one resolved, decoded pix tag becomes an image PageLine (empty segments, `.image` set,
/// `.lead` = the RESERVED PLACEHOLDER block's height — round 26 wave 3, `pixReservedAdvance`
/// — not the raster's own continuous pixel height). Port of the round-22 half of Python's
/// `_body_stream_printed` and `_doc_to_pagelines`' block walk.
func resolvePrintedBody(
    _ doc: Document, pixResults: [PixResult] = [],
    pictures: EmitOptions.PixMode = .off, sentenceSpacing: Bool = false
) -> [PrintedBodyItem] {
    // ALL kinds are numbered by the parser's shared counter since M9 (comments included),
    // so a mark's own number indexes all of `doc.notes`; a comment holds its position and
    // renders NOTHING — never printed: no ink, no ref.
    let refNotes = inlineReferenceNotes(doc)
    // planning #266: this document's own driver-keyed cp437-158 rule, resolved once.
    let euro = pesetaMeansEuro(doc)
    let rules = PrintedBodyRules(doc)
    var pendingSa: Double? = nil
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    // "Fit to text measure" (ruled fallback/cap) sizing lives in `pixDimsPt`/
    // `printedTextWidthPt`, shared with Modern.
    let textWidthPt = embedImages ? printedTextWidthPt(doc) : 0.0
    let defaultLeadPt = printedLead(doc)
    // Register b31: a line's own `.po` override needs the printed type size for the same
    // edge-of-page clamp `printedLeft` already applies (`resolveLeftPt`).
    let sizeForLeft = printedSize(doc)
    let renderFonts = RenderFonts(doc)
    var leading = LineLeading(doc)
    // WS7's paginator (WS7 report 14.3, 14.5, 15.1, 15.10); see `Era`.
    let era = printingEra(doc)
    var items: [PrintedBodyItem] = []
    // Planning #227 (columns-rule research §7, corrected): only LEAVING a `.co n>1` region
    // forces a page break — confirmed against sawyer/DEFAULT/PRINT.TST's own `.co` off
    // transition. ENTERING one does NOT: sawyer/REF/SYMBOL.CHT's own title line sits on the
    // SAME page as its chart's columnar content in the real WS7 capture. `prevCols` tracks
    // the columns state of the most recently processed REAL (`.para`) block; sentinel
    // blocks never change it.
    //
    // Planning #245: `.cb`/`.cc` get the same sentinel treatment on both walks:
    // `.colbreak` reuses `.pageBreak`'s sentinel exactly the way `.pagebreak` does, and
    // `.condcolumn` reuses `.condPage`'s — "room remaining in the current column" and
    // "room remaining in the current page" are the same question whenever a column's own
    // height equals a page's (research §4: always, in this engine).
    var prevCols = 1
    for (bi, block) in doc.blocks.enumerated() {
        let spacingBlanks = rules.ws4SpacingBlanks[bi] ?? []
        items.append(contentsOf: rules.headFoot.beforeBlock(bi))
        if block.kind == .pagebreak, prevCols > 1 {
            // Planning #227 (corrected): a bare `.pa` occurring INSIDE an active `.co n>1`
            // region is ABSORBED, not honoured. Measured against sawyer/REF/WINGDING.CHT's
            // real WS7 capture: its source carries `.pa` markers the author placed between
            // chart-entry groups (a manual column-simulation convention kept alongside the
            // real `.co5`); honouring them fragmented one ~47-line column into a 44-line
            // page plus an orphaned 3-line page, inflating WINGDING.CHT to 2 engine pages
            // against WS7's real 1. Columns fill by height alone once `.co n>1` is active
            // (research §4); only `.cb` forces an early break inside one.
            continue
        }
        if block.kind == .pagebreak, block.origin != .ff, era.paIgnoredOnEmptyPage,
           pageHoldsNothing(items) {
            // WS7 report 15.1 (runs patop, paful): the paginator's `.pa` handler reads the
            // line end before the dot line, and when that already ends a page (or is a form
            // feed) the `.pa` is ignored -- so a `.pa` as the first line, or right after
            // another break, adds no empty page.
            continue
        }
        // An explicit `.pa` is honored verbatim in a facsimile. WordStar's own 0x0B
        // end-of-page marks are NOT breaks -- see `Line.softpage`.
        if block.kind == .pagebreak || block.kind == .colbreak {
            // Inside an active `.co n>1` region, the column-grouping post-pass
            // (`applyColumns`) turns every Nth forced break into a real page break and the
            // others into a column advance — exactly what a column break means.
            items.append(.pageBreak(formFeed: block.origin == .ff))
            continue
        }
        if block.kind == .condpage || block.kind == .condcolumn {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        if block.kind == .para {
            let curCols = block.columns ?? 1
            var lastIsBreak = false
            if case .pageBreak? = items.last { lastIsBreak = true }
            if prevCols > 1, curCols != prevCols, !items.isEmpty, !lastIsBreak {
                items.append(.pageBreak())
            }
            prevCols = curCols
        }
        if block.origin == .fi {
            // #241: `.fi` (file insert) on a target this engine cannot resolve fabricates a
            // visible `[insert: NAME]` placeholder paragraph (ParseWS.swift's
            // `parseCollectDot`, origin `.fi`) — useful in Modern (an editorial note about
            // what the source asked for), but WS7's real behaviour on an unresolvable `.fi`
            // target is to print NOTHING: measured directly (sawyer/RTF-RJS's own `.fi
            // C:\WS\RTF-RJS\LINKS.MRG` probes), WS7's capture goes straight from the line
            // before `.fi` to the document's own next real text, no gap, no placeholder.
            // This walk (Printed's own WS7-emulation surface) skips the block entirely —
            // zero lines, zero page-advance; Modern is untouched (still shows the
            // placeholder, per Jon's ruling: "report what Modern does and leave it").
            // Port of Python's `pdf.py` `.fi` skip.
            continue
        }
        let fiPt = printedPMFiPt(block)
        // planning #257: see `PageLine.pmActive`'s own doc comment -- the RAW `.pm` state,
        // not `fiPt` (already reduced to 0 in both the "no `.pm` at all" and the "typed
        // indent already satisfies a nonzero one" cases).
        let pmActive = (block.paraMargin ?? 0) != 0
        // The block's first physical line, blank or not: `.pm`'s first-line indent and
        // `.psb`'s space before belong to it.
        var firstLineOfBlock = true
        // The block's first REAL (non-blank) line: the one `enteringLeadPt` may floor
        // against the preceding block's own lead (Fix C). A blank line ahead of it
        // governs its own lead (`styleLeadPt(raw:)`) and does not use the entry up --
        // measured against real WS7 on LYING (a block opening on a blank line, its
        // first text line entering at the style's own 16pt, not the 12pt default).
        var enteringLinePending = true
        // Fix C (b26-print-fidelity-2): the nearest earlier REAL (`.para`) block, skipping
        // pagebreak/condpage sentinels — `enteringLeadPt`'s own "outgoing" reference for
        // this block's first line, computed once per block since it never changes within
        // one.
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        // Printed mode renders PHYSICAL lines verbatim — a soft return broke the line on
        // paper, so it stays broken here. planning #270 item 37: `.pf on` re-wraps a
        // paragraph at PRINT time (`pfRewrappedLines`; every other block hands back
        // `block.lines` itself). Indexed (not a plain `for`) so an embedded pix
        // substitution below can look ahead and CONSUME the blank placeholder lines
        // WordStar reserved for it — see `pixReservedAdvance`.
        let blkLines = pfRewrappedLines(doc, block)
        var li = 0
        while li < blkLines.count {
            items.append(contentsOf: rules.headFoot.within(block: bi, linesBefore: li))
            // The pre-increment index spots a block's own last line (planning #238).
            let lineIdx = li
            let line = blkLines[li]
            li += 1

            var spans: [Span] = []
            var due: [(note: Note, index: Int)] = []
            for sp in line.spans where keepSpanOnPageline(sp, refNotes: refNotes, printed: true) {
                let span = printedSpan(sp, block: block, euro: euro)
                if span.styles.contains(.fnref), let k = Int(sp.text),
                   k >= 1, k <= refNotes.count {
                    let noteIndex = k - 1
                    let note = refNotes[noteIndex]
                    spans.append(Span(text: noteMarker(note, doc: doc, index: noteIndex),
                                      styles: span.styles, font: span.font))
                    if note.kind == .footnote || note.kind == .annotation {
                        due.append((note: note, index: noteIndex))
                    }
                    continue
                }
                spans.append(span)
            }

            let ownLeft = line.poCols.map { resolveLeftPt($0, size: sizeForLeft) }
            // Planning #231 (.poe/.poo even/odd page offset): which of the two governs a
            // line depends on the PARITY of the page it lands on, not known at this stage
            // (pagination is a later pass), so this only records a CANDIDATE `(even, odd)`
            // pair; the paginator's `closePage` picks the real one. `nil` (the
            // overwhelming common case) costs nothing.
            var ownParityLeft: ParityLeft?
            if line.poeCols != nil || line.pooCols != nil {
                let fallbackPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                ownParityLeft = ParityLeft(
                    even: line.poeCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt,
                    odd: line.pooCols.map { resolveLeftPt($0, size: sizeForLeft) } ?? fallbackPt)
            }
            // Register b32-N10 (mirrored from ctrl-kd b48148c): this line's own `.sr` roll,
            // already resolved — `Line.roll48` is never `nil` on a real parsed line, so this
            // is simply the 1/48in -> points conversion `printedRollPt` uses for the
            // document-wide fallback, applied per line.
            let ownRoll = line.roll48.map { $0 * 1.5 }

            let isBlank = !spans.contains { $0.text.contains { !$0.isWhitespace } }
            let isFirstLine = firstLineOfBlock
            var ownLead = leading.lead(of: line, in: block, isBlank: isBlank,
                                       isFirstLine: enteringLinePending,
                                       prevParaBlock: prevParaBlock)
            let fontRise = leading.fontRise
            if !isBlank { enteringLinePending = false }
            // Finding 1: this blank IS the block's own double-spacing — it still becomes its
            // own literal PageLine at its own natural (unextended) lead; only its
            // `ws4Spacing` flag differs, which the paginator reads to decide whether
            // this blank alone may force a page break (see `ws4SpacingBlankIndices` for why
            // collapsing it into a neighbour's lead broke on irregular paragraph lengths).
            let ws4SpacingLine = isBlank && spacingBlanks.contains(lineIdx)
            var extra = 0.0
            if let sa = pendingSa {
                extra += sa
                pendingSa = nil
            }
            // no space-before on the document's own opening paragraph — nothing above it to
            // space away from.
            if isFirstLine, let sb = rules.docSb, bi > 0 {
                extra += sb
            }
            if extra != 0.0 {
                ownLead = (ownLead ?? defaultLeadPt) + extra
            }
            // b24 round 19 (RULINGS-LEDGER PIX row): exactly one pix tag, no other real text
            // on this physical line (the confirmed real-corpus shape: every acceptance
            // document's picture reference stands alone on its own paragraph) -> an image
            // PageLine instead of a text one. If a pix tag ever shares a line with OTHER
            // real text this deliberately does NOT substitute — text is never silently
            // dropped, and a footnote/annotation reference leaves its marker text behind,
            // which blocks the substitution (`due` still travels: nothing queued is lost).
            // Round 22: the detection/sizing rule is `spansPixSubstitution`, shared with
            // Modern. `.lead` is the RESERVED PLACEHOLDER block's height (round 26, Finding
            // A/C — `pixReservedAdvance`) plus whatever `.psb`/`.psa` extra was computed
            // above.
            if embedImages,
               let sub = spansPixSubstitution(spans.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                let (reserved, nBlank) = pixReservedAdvance(
                    blkLines, startIdx: li, ownLeadPt: ownLead ?? defaultLeadPt)
                li += nBlank
                items.append(.line(PageLine([], soft: line.soft, lead: reserved + extra,
                                            overprint: line.overprint, bi: bi,
                                            image: .init(pixIndex: sub.pixIndex,
                                                         widthPt: sub.wPt, heightPt: sub.hPt),
                                            left: ownLeft, poCols: line.poCols),
                                   due: due))
                firstLineOfBlock = false
                enteringLinePending = false
                continue
            }
            // N9 (b33 field notes): applied to the FINAL body spans — markers and prose
            // alike, since they render adjacently on the same physical line — AFTER the pix
            // check above, which needs the raw, untouched text to match its structural
            // placeholder.
            if sentenceSpacing { spans = sentenceSpacingSpans(spans) }
            // Planning #251 (2026-09-09): model-build-time bare-tab expansion, the same point
            // ctrl-kd's own `_doc_to_pagelines` applies it (right before the PageLine is
            // built) — see `expandBareTabsForPrintedLayout` (`EmitterRules.swift`).
            spans = expandBareTabsByDistance(spans, fonts: renderFonts, size: sizeForLeft)
                ?? expandBareTabsForPrintedLayout(spans)
            // A `.oc on` line's own centring tab is the EDITOR's arithmetic; the printer
            // re-centres on the ink alone (see recentredCentreTabSpans).
            spans = recentredCentreTabSpans(spans, block: block, doc: doc)
            // Planning #238 (.oj on full justification, research/
            // 2026-09-08_justification-rule.md, ctrl-kd aeb34ad): every line of an
            // `align == .justify` block EXCEPT ITS OWN LAST is stretched to the block's
            // resolved right margin — measured directly against WS7 (sawyer/LSRBOX/
            // LSRBOX.WS): the paragraph's final physical line sits short of the margin,
            // ragged, while every line above it reaches the margin exactly. `rightMargin`
            // is `.rm` in print columns, measured from the SAME `.po` origin as the left
            // edge (confirmed against LSRBOX's explicit `.po .7"/.rm 6.5"` and CTRL-K.H1's
            // all-defaults line: poOrigin + rmCols*7.2pt, never rm alone); 65.0 is
            // WordStar's own factory default (CTRL-K_EXT_H1.pcl's flush-right edge, 525.6pt
            // = .po 8 cols (57.6pt) + 65 cols (468pt)). Printed-only, so there is no
            // `printed` guard here — ctrl-kd's own equivalent gate is `printed and
            // b.align == 'justify' and ...`.
            //
            // WS7 justifies a line only when it ends in a soft return; a hard return (the
            // paragraph's last line, or a line the author ended by hand) is left ragged
            // (WS7 report 11.7.1, fixture w16-ljls: a hard-returned line inside the same
            // `.oj on` block stays at its natural widths). `line.soft` is exactly that in
            // every era: the STORED terminator, whatever Modern reflow makes of the break
            // (`keepBreak`). WS4 stores a justified line's blanks at wrap time and ends
            // only a wrapped line in a soft return (WS4 report 2.7, 7.7), so a
            // hard-returned line there stays ragged too. After a `.pf on` re-wrap
            // (planning #270 item 37) it is true of every produced line but the
            // paragraph's last.
            var justifyRightX: Double? = nil
            var softBlanks: PageLine.SoftBlanks? = nil
            let lastInUnit = !line.soft
            if block.align == .justify, !lastInUnit {
                let poOriginPt = ownLeft ?? printedLeft(doc, size: sizeForLeft)
                let rmCols = block.rightMargin ?? 65.0
                justifyRightX = poOriginPt + rmCols * pdfPtPerCol
                // The WS5+ soft spaces on this line, by offset (WS7 report 14.6: the
                // driver ignores the stored ones).
                let kept = line.spans.filter {
                    keepSpanOnPageline($0, refNotes: refNotes, printed: true)
                }
                let baseText = kept.map(\.text).joined()
                if kept.contains(where: { !$0.soft.isEmpty }),
                   spans.map(\.text).joined() == baseText {
                    var offs: [Int] = []
                    var base = 0
                    for sp in kept {
                        offs.append(contentsOf: sp.soft.map { base + $0 })
                        base += sp.text.unicodeScalars.count
                    }
                    softBlanks = PageLine.SoftBlanks(text: baseText, offsets: offs)
                }
            }
            // WS4's bit-7 characters, against the line's text as built here, while that is
            // still the text they were read from (`PageLine.hibit`).
            var hibit: PageLine.Hibit? = nil
            if !line.hibit.isEmpty {
                let baseText = line.spans.filter {
                    keepSpanOnPageline($0, refNotes: refNotes, printed: true)
                }.map(\.text).joined()
                if spans.map(\.text).joined() == baseText {
                    hibit = PageLine.Hibit(text: baseText, offsets: line.hibit)
                }
            }
            // WS4's HPLJET prints every character through COMPOS (`hpljetComposSpans`).
            var overstrike: [PageLine.Overstrike] = []
            if era.hpljetDriver {
                (spans, overstrike) = hpljetComposSpans(spans)
                if hibit != nil { hibit?.text = spans.map(\.text).joined() }
            }
            // A PageLine, not a bare list of spans, so the line's own `.lh` survives the
            // paginator whether or not the document has notes.
            items.append(.line(PageLine(spans, soft: line.soft, lead: ownLead,
                                        overprint: line.overprint,
                                        fi: isFirstLine ? fiPt : nil,
                                        pmActive: pmActive, bi: bi,
                                        ws4Spacing: ws4SpacingLine,
                                        kerning: line.kerning, left: ownLeft, roll: ownRoll,
                                        justifyRightX: justifyRightX,
                                        parityLeft: ownParityLeft,
                                        poCols: line.poCols, fontRise: fontRise,
                                        softBlanks: softBlanks, hibit: hibit,
                                        softHyphen: line.softHyphen, li: lineIdx,
                                        overstrike: overstrike), due: due))
            firstLineOfBlock = false
        }
        // triage Q9: events recorded at or past this block's own line count.
        items.append(contentsOf: rules.headFoot.atEnd(ofBlock: bi, lineCount: blkLines.count))
        // `!firstLineOfBlock`: this block actually appended at least one real PageLine (an
        // empty-text block leaves it true, nothing to space away from). Carried to whatever
        // PageLine comes next, however many items away that is.
        if let sa = rules.docSa, !block.lines.isEmpty, !firstLineOfBlock {
            pendingSa = sa
        }
    }
    // The blank lines a document ends with. The parser drops the trailing run from the IR
    // (it is not content), but to WS7 each is a text line: it takes its room, and one that
    // no longer fits makes a page that carries only its number (WS7 report 14.3, runs
    // pg55b and pa3). They go in as plain blank lines after everything else; the
    // paginator's clean-up tells a page made of them (`PrintedBodyItem.eofBlank`) from a
    // page of machine padding. A document with no block at all (a template of dot
    // commands) has no body for them to follow and keeps its one fallback page.
    if era.blankLinesMakePages, !doc.blocks.isEmpty {
        for _ in 0..<doc.eofBlankLines {
            items.append(.line(PageLine([], bi: doc.blocks.count - 1), due: []))
        }
    }
    return items
}

/// Whether the page the next entry of `items` would land on has had nothing placed on it:
/// no entries yet, or the last real one is a forced break. Header/footer events and `.cp`
/// sentinels place nothing. Port of `pdf._page_holds_nothing`.
private func pageHoldsNothing(_ items: [PrintedBodyItem]) -> Bool {
    for item in items.reversed() {
        switch item {
        case .hf, .condPage: continue
        case .pageBreak: return true
        case .line: return false
        }
    }
    return true
}

/// An embedded pix image's `(widthPt, heightPt)` — the ONE sizing rule every PDF path
/// shares (b24 round 22 factored it out of `resolvePrintedBody` so the Modern and
/// notes-pagination paths size identically to the plain Printed path): the print-options
/// record's physical size when the `.PIX` file carries one, else fit-to-text-measure at
/// the source aspect ratio; either way capped at `maxWPt` (the requesting path's own
/// text measure). Port of Python's `_pix_dims_pt`.
func pixDimsPt(_ r: PixResult, maxWPt: Double) -> (w: Double, h: Double) {
    var wPt: Double
    var hPt: Double
    if let widthIn = r.widthIn, let heightIn = r.heightIn, widthIn != 0, heightIn != 0 {
        wPt = inchesToPoints(widthIn)
        hPt = inchesToPoints(heightIn)
    } else {
        wPt = maxWPt
        hPt = r.gcols.map { $0 != 0 ? wPt * (Double(r.grows ?? 0) / Double($0)) : 0.0 } ?? 0.0
    }
    if wPt > maxWPt, wPt > 0 {
        let scale = maxWPt / wPt
        wPt *= scale
        hPt *= scale
    }
    return (wPt, hPt)
}

/// `(reservedLeadPt, nBlankConsumed)` for an embedded pix tag whose own physical line
/// already ended at `blkLines[startIdx - 1]`.
///
/// WordStar's own INSET convention: the author reserves the picture's print-time footprint
/// as blank PHYSICAL LINES in the source (the tag's own line plus however many blank lines
/// follow it, contiguously, in the same block) — print time overlays the picture on exactly
/// that reserved block, which is why the block's LINE COUNT governs the vertical advance,
/// not the picture's own continuous pixel height (the two rarely match to the point;
/// INSET's editor-time placeholder was drawn by eye).
///
/// Measured 2026-08-20 against -README.WS/-README.pcl (`fidelity_gate.py` Finding A): the
/// `.PIX` tag is followed by 7 contiguous blank lines before "COMPLETE WORDSTAR..." — 8
/// lines * 12pt = 96pt reserved. WS7's own first-body baseline (167.7pt) matches
/// `printedTop`'s 60pt + 96pt + this line's own 12pt lead to a 0.3pt residual, the same
/// decipoint-rounding-sized gap as the rest of the confirmed corpus. Using the raster's raw
/// height instead (73.9pt, from the print-options record) under-reserves by >20pt here and
/// cascades into every following line's position. The SAME `ceil(hPt/lead)` raw-height cost
/// also fed the page-capacity budget before this fix (round 26, Finding A/C) — the budget
/// now spends this same reserved `.lead`.
/// Port of Python's `_pix_reserved_advance`.
func pixReservedAdvance(_ blkLines: [Line], startIdx: Int, ownLeadPt: Double)
    -> (reserved: Double, nBlank: Int)
{
    var n = 0
    while startIdx + n < blkLines.count, blkLines[startIdx + n].text().trimmed().isEmpty {
        n += 1
    }
    return (Double(1 + n) * ownLeadPt, n)
}

/// `(pixIndex, wPt, hPt)` when `spans` is exactly ONE resolved, decoded pix placeholder
/// and nothing else with real text — the round-19 substitution rule, shared verbatim by
/// every PDF path since b24 round 22: text content is never silently dropped, so a
/// (hypothetical) pix tag sharing its line with other prose renders as the ordinary
/// placeholder text instead. `nil` when no substitution applies (off / miss / shared
/// line); the caller keeps the placeholder text unchanged. Port of Python's
/// `_spans_pix_substitution` (which reads the `pixN` style tag; the Swift IR carries the
/// same value structurally as `Span.pix`/`SemanticRun.pix`, hence the tuple shape here).
func spansPixSubstitution(_ spans: [(text: String, pix: Int?)],
                          pixMap: [Int: PixResult], maxWPt: Double)
    -> (pixIndex: Int, wPt: Double, hPt: Double)?
{
    var pixIdx: Int?
    for sp in spans {
        if let tag = sp.pix {
            if pixIdx != nil { return nil }        // >1 tag on one line: bail
            pixIdx = tag
        } else if !sp.text.trimmed().isEmpty {
            return nil                             // real prose shares the line
        }
    }
    guard let pixIdx, let r = pixMap[pixIdx], r.ok else { return nil }
    let (wPt, hPt) = pixDimsPt(r, maxWPt: maxWPt)
    return (pixIdx, wPt, hPt)
}

/// The Printed text measure in points, for pix fit/cap sizing: Printed PDF has no
/// per-block `.rm` resolved in points anywhere in this emitter (physical lines are
/// pre-wrapped by the parser at authoring time), so the right inset is mirrored from the
/// left one — a disclosed approximation (round 19), same class as RTF's borrowed TOC
/// page numbers. Port of Python's `_printed_text_width_pt` (round 22 factored it out,
/// shared with the notes-pagination path).
func printedTextWidthPt(_ doc: Document) -> Double {
    let size = printedSize(doc)
    let left = printedLeft(doc, size: size)
    let pageWPt = inchesToPoints(doc.page?.pwIn ?? letterWidthIn)
    return max(72.0, pageWPt - 2 * left)
}

/// A physical `Line` with no non-whitespace span text — the same test
/// `resolvePrintedBody`'s own per-line loop already applies inline (its `isBlank`),
/// factored out here so `ws4SpacingBlankIndices` can classify a whole block's lines
/// before that loop runs. Port of Python's `_is_blank_line`.
private func isBlankLine(_ line: Line) -> Bool {
    !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
}

/// Finding 1 (b26 visual pass, a private WS4 paper corpus, never entering this repo):
/// `[blockIndex: Set(line indices into that block's own .lines)]` — every blank
/// `Line` that is this document's OWN double-spacing idiom, not authored content.
/// ONLY CALLED for a `variant == .ws4` document — see the call site's own comment for
/// why this never even runs for anything else.
///
/// WordStar's OWN manual gives this a physical story, already quoted elsewhere in
/// this module (`ParseWS.swift`'s `defaultLs`/`enteringLeadPt`): "when you use line
/// spacing, the blank lines become part of the file" (WS7 manual, "Line Spacing") —
/// `.LS`'s blank lines are not computed at print time, they are literal `Line`s the
/// file itself carries. A classified blank stays exactly that: a literal `Line`, its
/// own ordinary `PageLine` at its own natural (single) lead — `resolvePrintedBody` does
/// NOT fold it into a neighbour's lead. An early version of this fix DID fold
/// (collapsing a double-spaced pair into one `PageLine` at 2x lead) and it broke on
/// irregular paragraph lengths: real WS7's own page-top baseline cycles through THREE
/// distinct phases 12pt apart (measured: a WS4 source with long, regular paragraphs
/// holds one phase for every interior page, 71.7pt; a WS4 source built mostly from
/// short dialogue paragraphs cycles 71.7/83.7/95.7pt depending on whether the page
/// break happened to land on odd or even raw-line parity) — collapsing every pair
/// into a single 2x-lead unit can only ever reproduce ONE of those phases, because it
/// throws away exactly the raw single-line parity information a page break's real
/// position depends on. Classifying which blanks are spacing (this function) but
/// leaving them as literal RAW `PageLine`s preserves that parity; only their
/// ELIGIBILITY to force a page break changes (`layoutPrintedPages`'s own
/// pagination loop, via each `PageLine`'s own `ws4Spacing` flag).
///
/// Classified PER BLOCK first (a block is WordStar's own paragraph unit), because a
/// WS4 fiction manuscript mixes double-spaced narrative with single-spaced inserts
/// (verse quoted verbatim, a bibliography) at exactly that granularity, not
/// document-wide — a block whose own lines are `T,T,...` (two real lines with no
/// blank between them) or start with a leading blank never counts, regardless of
/// anything nearby. Neither measured WS4 source sets `.LS` at all (checked their own
/// raw dot-command bytes directly): WS4 predates `.LS` even being a documented dot
/// command, so there is usually no stateful signal to key off and this has to read
/// the rhythm off the pattern itself — `lsConfirmed` (true only when the file's own
/// `.LS` dot-command positively declares spacing > 1, `doc.page?.lsSource == .file`)
/// trusts direct file evidence over the inferred pattern when it exists.
///
/// A block whose shape is a clean alternation (T,B,T,B,... with no two adjacent
/// same-kind lines, ignoring a possible TRAILING blank run at its very end — see
/// below) is COMPATIBLE with the rhythm; one that also has >= threshold interior
/// blanks (an interior blank is real text on BOTH sides, within the same block) on
/// its own is CONFIRMED. `threshold` is 1 under `lsConfirmed`, else 2 — 2 because a
/// real document can carry a single, genuinely authored blank line in the middle of
/// an ordinary paragraph (measured: a real corpus document's own block, one isolated
/// interior blank, never repeated anywhere else in that block) — that is authored
/// spacing, not a rhythm, and one occurrence alone must never count it. (That
/// document is `ws5+`, so the WS4 gate alone already keeps it untouched — the
/// threshold is the SECOND independent reason, for a future WS4 capture that turns
/// out to carry the same kind of aside.)
///
/// STATE, carried across blocks in document order like any other WordStar
/// dot-command state: a CONFIRMED block turns spacing mode on; a
/// COMPATIBLE-but-unconfirmed block counts too WHILE mode is already on (this is
/// what a lone short line of dialogue — too short to confirm 2 interior repeats by
/// itself — needs: measured against a real WS4 source, several consecutive short
/// dialogue paragraphs sit between longer confirmed ones, and their own 24pt gaps to
/// their neighbours check out against that source's own baselines exactly like the
/// confirmed ones'). An INCOMPATIBLE block (leading blank, or two real lines back to
/// back) turns the mode back OFF — the one hard stop, so a verse quotation or a
/// bibliography section breaks the chain exactly where the document's own shape says
/// it should, not where a document-wide guess would. A COMPATIBLE-but-unconfirmed
/// block seen BEFORE the first CONFIRMED one (mode still off) is left alone — there
/// is no evidence yet to count it against.
///
/// TRAILING RUN: a block that counts at all (confirmed, or compatible while mode is
/// on) counts its OWN trailing blanks too — from its last real line to its own end —
/// even though a trailing run is never "interior" (there is no following real line
/// left within THIS block for it to sit between). WordStar's "blank lines become
/// part of the file" is a property of `.LS`, not of which physical line happens to
/// be a paragraph's last — measured: a WS4 source's paragraph boundaries carry a 2-3
/// blank RUN, not the single blank its own within-paragraph rhythm uses (the
/// paragraph's last line still owes its own spacing filler; the author's own
/// blank-line gap between paragraphs, typed under the same `.LS`, owes its own
/// filler too), and the resulting larger gap (measured: 48pt across a 3-blank
/// boundary, exactly 2x a normal 24pt gap) checks out against the source's own
/// baselines too.
///
/// SCOPING RULING (Jon, b26 visual pass): an earlier version of this fix collapsed
/// spacing pairs and was scoped only by block-level pattern; it un-matched -README
/// and VERSIONS (both `ws5+`, both previously matching their own WS7 captures
/// EXACTLY) to fix two WS4 sources — "a rule that un-matches exact documents to fix
/// others is not WS7's real rule... fix the broken thing without breaking anything
/// else." Rebuilt gated on the POSITIVELY DETECTED `variant == .ws4` condition per
/// Jon's follow-up mandate, and every WS4 capture behind this fix (the two sources
/// it was built from, plus three out-of-sample captures checked afterward) is
/// modelled with the SAME rule as every other WS4 document — no per-source carve-out.
/// Port of Python's `_ws4_spacing_blank_indices`.
private func ws4SpacingBlankIndices(_ doc: Document, lsConfirmed: Bool) -> [Int: Set<Int>] {
    let threshold = lsConfirmed ? 1 : 2
    var spacingMap: [Int: Set<Int>] = [:]
    var spacingMode = false
    for (bi, b) in doc.blocks.enumerated() {
        guard b.kind == .para else { continue }     // sentinels never reset the state
        let flags = b.lines.map { !isBlankLine($0) }
        guard let first = flags.first, first else {
            spacingMode = false                      // empty, or opens on a blank
            continue
        }
        let lastReal = flags.lastIndex(of: true)!
        let core = Array(flags[0...lastReal])
        let compatible = core.count < 2
            || (0..<(core.count - 1)).allSatisfy { core[$0] != core[$0 + 1] }
        if !compatible {
            spacingMode = false
            continue
        }
        let interior: [Int] = flags.count > 2
            ? (1..<(flags.count - 1)).filter { flags[$0 - 1] && !flags[$0] && flags[$0 + 1] }
            : []
        let confirmed = interior.count >= threshold
        if confirmed || spacingMode {
            var spacing = Set(interior)
            if lastReal + 1 < flags.count {
                spacing.formUnion((lastReal + 1)..<flags.count)
            }
            spacingMap[bi] = spacing
            spacingMode = true
        }
        // else: compatible, but neither confirmed itself nor inheriting an already-on
        // mode -- no evidence yet; leave uncounted, mode stays off
    }
    return spacingMap
}

/// A centred line's own centring tab, recomputed for the PRINTER.
///
/// WordStar 5+ centres a `.oc on` line at EDITOR time and stores the result as an
/// absolute tab mark (`Span.tabHMI`, a type-9 block) on the line's own leading padding
/// span. That stored number is the EDITOR's arithmetic, and the editor counted the
/// line's TRAILING BLANKS as part of the text it was centring. Real WS7 does not: it
/// re-centres the line on the ink, with trailing blanks off.
///
/// MEASURED against ws7-prints/v4/sawyer__PLAYBILL_EXT_DOC (a `.oc on` playbill, every
/// line a centring tab of its own). Of its 12 centred lines, 9 carry a stored tab that
/// already equals the re-centred value and 3 do not — and those 3 are exactly the 3
/// lines whose stored text ends in blanks (one, one, and two). WS7 prints all 12 at
/// `(rm - inkCols) / 2`: `A gala opening night with the ` at column 18 where the file
/// stores 17.5, `City ... special season ` at 4.5 where the file stores 4, `for Theatre
/// in the Park.  ` at 20.5 where the file stores 19.5. All 12 land on WS7's own
/// decipoint.
///
/// ONLY a line whose every span is FIXED-PITCH is recomputed. A proportionally-set
/// centred line's stored tab is the editor's own measurement of a font WE DO NOT HAVE
/// (LYING's and WARPRAYR's title pages store fractional-column tabs for exactly that
/// reason, and both are clean against WS7 today); recomputing those from a substituted
/// face's metrics would replace a real measurement with a guess. Their stored tab is
/// left exactly as WordStar wrote it.
func recentredCentreTabSpans(_ spans: [Span], block: Block, doc: Document) -> [Span] {
    guard block.align == .center, let head = spans.first, head.tabHMI != nil else {
        return spans
    }
    for span in spans {
        if let f = span.font, f >= 0, f < doc.fonts.count, doc.fonts[f].proportional {
            return spans
        }
    }
    var inkChars = Array(spans.map(\.text).joined())
    while let f = inkChars.first, f == " " { inkChars.removeFirst() }
    while let l = inkChars.last, l == " " { inkChars.removeLast() }
    if inkChars.isEmpty { return spans }
    let lm = block.leftMargin ?? 0.0
    let rm = block.rightMargin ?? 65.0
    var cols = lm + (rm - lm - Double(inkChars.count)) / 2.0
    if cols < lm { cols = lm }
    let want = roundHalfToEven(cols * Double(tabHMIPerCol))
    if want == head.tabHMI { return spans }
    var out = spans
    out[0].tabHMI = want
    return out
}


/// Whether the document has any note that gets a PLACE on the printed page (a footnote
/// or annotation footer entry, or an endnote's end-of-document entry) — comments never
/// print. Port of Python's `_has_placeable_notes`. A predicate only: the printed paginator
/// is the same for every document, and a document with placeable notes simply has a note
/// area to grow (`PrintedNotes.swift`).
func hasPlaceableNotes(_ doc: Document) -> Bool {
    doc.notes.contains { $0.kind == .footnote || $0.kind == .endnote || $0.kind == .annotation }
}

/// A comment's reference mark is POSITION, not ink — it renders nowhere on this path
/// (printed facsimile, or the plain line layer). Port of `_doc_to_pagelines`'s
/// `_keep_span` (ruling 2026-08-06 M9).
///
/// `printed`: a ^ONI index ENTRY (`Span.indexEntry`) is the index file's text, not the
/// page's — real WS7 spends the row and prints nothing on it (MEASURED, ws7-prints/v4
/// `sawyer/REF/-INDEX.HOW`; see `symmetricBlocks`' cmd 0x0E branch). PRINTED only: every
/// other emitter, Modern included, keeps the phrase exactly as it always did.
func keepSpanOnPageline(_ span: Span, refNotes: [Note], printed: Bool = false) -> Bool {
    if printed, span.indexEntry { return false }
    if span.styles.contains(.fnref), let k = Int(span.text),
       k >= 1, k <= refNotes.count, refNotes[k - 1].kind == .comment {
        return false
    }
    return true
}
