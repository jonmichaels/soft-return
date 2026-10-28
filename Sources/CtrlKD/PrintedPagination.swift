/// The Printed paginator: points-based, with the geometry timelines, running head/foot replay
/// and column groups. Its body walk is `resolvePrintedBody`; a document with notes adds the
/// note area (`NoteArea`, PrintedNotes.swift) to the same pages, and nothing else differs.

/// Points-based printed pagination — Python's `_doc_to_pagelines`. Port of ctrl-kd
/// 17e4ea0/8b902ff. One paginator for every printed document (planning #577, ruling R-130):
/// a document with footnotes, endnotes or annotations lays out exactly like one without,
/// apart from the note area itself.
///
/// Paper is physical: WordStar advances each line by the `.lh` in force and starts a
/// new page when the next advance would leave the text area, so a document that varies
/// its leading fits more or fewer lines than the default-lead COUNT says. The budget is
/// the page's own text HEIGHT (`printedBudgetPt`) and EVERY line — the first one
/// included — spends its own lead out of it, which is exactly where each line's
/// baseline lands on paper (`pageStream`: the first line sits at `top` plus its OWN
/// lead, each later one a further lead down). A uniform-lead page therefore paginates
/// EXACTLY as the old line count did (n leads fit iff n <= floor(height / lead) == cap),
/// so no fontless byte moves; only a page that MIXES leads can now reach into the
/// fractional remainder `cap`'s own floor discarded — see `printedBudgetPt`, which
/// measures that against real WS7. Overprint lines spend no lead at all, on paper and
/// here.
///
/// The running head/foot IN FORCE on a page is replayed from `doc.hfEvents` rather than
/// read from the document's final state: WordStar applies a running head from the page
/// where it is defined — on that page itself only if no text has printed there yet,
/// else from the next page.
// NOT private (job 255, additive): `AnnotatedLayout.swift`'s natural page-break
// detection needs the real paginator, not a re-derived guess — "the engine is the
// single source of truth."
func layoutPrintedPages(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false, rawPageCap: Int? = nil
) -> [Page] {
    let items = resolvePrintedBody(doc, pixResults: pixResults,
                                   pictures: pictures, sentenceSpacing: sentenceSpacing)
    var capacity = printedCap(doc)
    let defaultLead = printedLead(doc)
    var notes = NoteArea(doc, defaultLead: defaultLead, sentenceSpacing: sentenceSpacing)
    // WS4's page counter (`Era.lineStartsInRoom`, `.geometryActsAtOnce`): the body height is
    // exactly `.pl - .mt - .mb` at the geometry in force, with no rounding up to the cap or
    // "never tighten" clamp, and it is re-read for the page IN PROGRESS whenever one of them
    // changes (WS4 teardown 3.1, `evidence/pass3/exe-static.md` 8; runs t43-mtmb). Port of
    // Python's `exact_budget`/`_budget_for`.
    let era = printingEra(doc)
    let exactBudget = era.geometryActsAtOnce
    let bodyGeometry = exactBudget ? doc.bodyGeometryTimeline() : nil
    func budgetFor(_ capacity: Int, _ mt: Double, _ mb: Double, _ pl: Double) -> Double {
        if exactBudget, pl != 0 {
            let usable = (pl - mt - mb) * Double(PDFMetrics.lead)
            if usable.isFinite { return max(0.0, usable) }
        }
        return printedBudgetPt(doc, capacity: capacity, defaultLead: defaultLead,
                               mtLines: mt, mbLines: mb, plLines: pl)
    }
    var budget = printedBudgetPt(doc, capacity: capacity, defaultLead: defaultLead)
    // b24 round 17b (RULINGS-LEDGER row 5/6, register C8): `.sb` suppresses blank lines
    // specifically at the TOP of a page — WordStar's own pagination concern, not a
    // text-content one, so it belongs in THIS loop (the only place that knows a page
    // just started) rather than `resolvePrintedBody`'s line-building pass above.
    let suppressBlanks = doc.formatting.suppressBlanks ?? false
    // Finding 3 (b26-print-fidelity-2): a fresh page picks up whatever `.mt`/`.mb` was
    // in force at its OWN first block, not the document's global first-occurrence pair
    // — see `mtMbTimeline`. `globalMt`/`globalMb` are what `printedCap(doc)` itself
    // already used above; a page whose own checkpoint matches them leaves
    // `Page.mtLines`/`mbLines` at their `nil` default (render side: "use the document
    // global", untouched).
    let mtMbList = doc.mtMbTimeline()
    let globalMt = mtMbList.entries[0].value.mt
    let globalMb = mtMbList.entries[0].value.mb
    var curMt = globalMt
    var curMb = globalMb
    // register b31-dot-command-sweep: `.pl`/`.hm`/`.fm` are stateful too, same mechanism
    // as `.mt`/`.mb` above -- see `plTimeline`/`hmFmTimeline`. `Timeline.at(.., 0)`/
    // `Timeline.at(.., 0)`, NOT a raw index-0 read: block 0's seed is WordStar's hardcoded
    // default, which a document that declares `.pl`/`.hm`/`.fm` right at its own start
    // immediately supersedes with another (bi=0) checkpoint -- the `At` helpers resolve
    // that correctly, a raw index-0 read would not.
    let plList = doc.plTimeline()
    let globalPl = plList.at(0)
    var curPl = globalPl
    if exactBudget { budget = budgetFor(capacity, globalMt, globalMb, globalPl) }
    let hmFmList = doc.hmFmTimeline()
    let globalHm = hmFmList.at(0).hm
    let globalFm = hmFmList.at(0).fm
    var curHm = globalHm
    var curFm = globalFm
    // mechanism O (ctrl-kd 55d2b52): `.po` too -- see `poTimeline`. Feeds `runningOps`'s
    // own header/footer LEFT edge only (body text's per-LINE `.po` already works,
    // `Line.poCols`) -- still ride the SAME per-page-start recompute so `Page.poCols` is
    // known by the time a page closes, exactly like `plLines`/`hmLines`/`fmLines`.
    let poList = doc.poTimeline()
    let globalPo = poList.at(0)
    var curPo = globalPo
    // Planning #231: `.poe`/`.poo` -- see `parityPoTimeline`. No block-0 seed
    // (unlike `poCheckpointsList` above): "never used" is a real, different answer
    // from "used at the document default," and `leftForParity` already treats a `nil`
    // value as "fall back to `curPo`" -- exactly what a document that never writes
    // `.poe`/`.poo` needs, byte-identical to before this feature existed.
    let poeList = doc.parityPoTimeline(dotName: "POE")
    let pooList = doc.parityPoTimeline(dotName: "POO")
    var curPoe: Double? = poeList.atIfAny(0)
    var curPoo: Double? = pooList.atIfAny(0)
    // `closePage`'s "does this page need its own render-time override" test can NOT
    // compare against `globalPl`/`globalHm`/`globalFm`/`globalPo` above: those are seeded at
    // WordStar's hardcoded default (correct for BEFORE any real occurrence), but the
    // render loop's fallback ("Page.* left nil means use doc.page AS IS") reads
    // `ParseWS.swift`'s own first-occurrence value, which -- in the exact degenerate case
    // the seed fix above exists for (a command whose ONLY occurrence sits mid-document) --
    // is that SAME later value, wrongly, for every page. Comparing against the RAW
    // `doc.page` reading instead makes a page whose resolved value happens to DIFFER from
    // it get its own override even when that resolved value equals the (correct)
    // checkpoint global, which is exactly the pages BEFORE such a command's first real
    // occurrence.
    let docMt = doc.page?.mtLines ?? defaultMtLines
    let docMb = doc.page?.mbLines ?? defaultMbLines
    let docPl = doc.page?.plLines ?? defaultPlLines
    let docHm = doc.page?.hmLines ?? defaultHmLines
    let docFm = doc.page?.fmLines ?? defaultFmLines
    let docPo = doc.page?.poCols ?? defaultPoCols
    // triage Q12: how far into the document this page has READ, kept as a running
    // per-block line tally. `checkpointsByPage` needs it because `finalizePages` strips
    // a page's trailing blanks -- a page of nothing but blank lines ends up EMPTY, with
    // no `bi` left on it at all, and the leading blank run a `.pn` sits inside is
    // exactly that shape. Counted here, before anything is stripped.
    var readTally: [Int: Int] = [:]
    // M31: the `.pr or=` checkpoints, and the document-level value a page is compared
    // AGAINST before it stamps one of its own -- `doc.formatting.orientation`, the
    // document-wide last-write-wins reading every non-printed surface still uses.
    let orList = doc.orTimeline()
    let docOr = doc.formatting.orientation ?? .portrait
    var curOr = orList.at(0, consumed: 0)
    /// (mt, mb, pl, hm, fm, po, poe, poo, orientation) in force at block `bi`, for the page about to start there --
    /// shared by BOTH places a fresh page begins: the explicit-break path below (`page`
    /// already empty by the time the next `.line` case's top-of-switch check runs), and
    /// the ORGANIC-overflow close (where `page` is NOT yet empty at the top of THIS
    /// iteration -- the line that overflows IS the new page's own first line, and must use
    /// ITS block's geometry, not the closing page's). Missed until register b31-dot-
    /// command-sweep: `.pl`'s own oracle (PL_PROBE) has no explicit break at all -- an
    /// ordinary organic page break -- and real WS7 still used the new `.pl` starting the
    /// very next page, which only the organic-close recompute site can reproduce. This
    /// also strengthens `.mt`/`.mb` for organic breaks (previously recomputed only at the
    /// explicit-break site).
    func recomputeGeom(_ bi: Int) -> (mt: Double, mb: Double, pl: Double, hm: Double, fm: Double,
                                      po: Double, poe: Double?, poo: Double?,
                                      orientation: Orientation) {
        var margins = mtMbList.at(bi)
        var pl = plList.at(bi)
        if let bodyGeometry {
            // WS4: the line-exact reading (`bodyGeometryTimeline`), at the page's opening line.
            let geometry = bodyGeometry.at(bi, consumed: readTally[bi] ?? 0)
            margins = MarginLines(mt: geometry.mt, mb: geometry.mb)
            pl = geometry.pl
        }
        let (mt, mb) = (margins.mt, margins.mb)
        let headFoot = hmFmList.at(bi)
        let (hm, fm) = (headFoot.hm, headFoot.fm)
        let po = poList.at(bi)
        let poe = poeList.atIfAny(bi)
        let poo = pooList.atIfAny(bi)
        // M31: the line-exact form -- `readTally[bi]` is how many lines of this block
        // earlier pages consumed, i.e. where this page opens INSIDE the block, and it is
        // still the pre-line value here (the tally advances at the bottom of the loop
        // body). See `Timeline.at`.
        let orientation = orList.at(bi, consumed: readTally[bi] ?? 0)
        return (mt, mb, pl, hm, fm, po, poe, poo, orientation)
    }

    var pages: [Page] = []
    var page: [PageLine] = []
    var readPos: PageReadPos?
    var spent = 0.0
    var pageEndGeom: BodyGeometry?   // (mt, mb, pl) at the open page's last line (WS4)
    // True from the moment the paginator ends a page for room until a line lands on the
    // page it opens: the blank soft-return lines at that top are swallowed
    // (`era.softBlanksSwallowed`).
    var roomBreakOpen = false
    // The index in `items` of the last line appended to a page, for the clean-up that tells
    // a last page made of the document's own trailing blank lines from padding.
    var lastAppendedItem = -1
    var carryOpen = true            // the open page's note-area carry-over is not yet admitted
    var lastRoomLines = 0           // whole lines free on the page closed last, under its area
    var lastHasArea = false         // ...and whether that page ends with a note area
    var curHeaders: [Int: String] = [:]
    var curFooters: [Int: String] = [:]
    var pageHeaders: [Int: String] = [:]     // state at the OPEN page's start
    // cause 10: the 0x0F print-control siblings of `curHeaders`/`pageHeaders`,
    // snapshotted at exactly the same moments -- see `Page.headerPcl`.
    var curHeadersPcl: [Int: [HFPrintControl]] = [:]
    var curFootersPcl: [Int: [HFPrintControl]] = [:]
    var pageHeadersPcl: [Int: [HFPrintControl]] = [:]
    var pageFootersPcl: [Int: [HFPrintControl]] = [:]
    var pageFooters: [Int: String] = [:]
    // Planning #250: the SAME flat/snapshot machinery as `curHeaders`/`pageHeaders`
    // above, one independent pair per parity — `.h1e`/`.f1e` write only `curHeadersE`/
    // `curFootersE`, `.h1o`/`.f1o` only `curHeadersO`/`curFootersO`; a plain `.h1`/
    // `.fo` never clears either (the same "each command in this family is
    // independently stateful" rule `.poe`/`.poo` already established). Resolved
    // against the real page parity only in `closePage`, the one place that knows it.
    var curHeadersE: [Int: String] = [:]
    var curHeadersO: [Int: String] = [:]
    var curFootersE: [Int: String] = [:]
    var curFootersO: [Int: String] = [:]
    var pageHeadersE: [Int: String] = [:]
    var pageHeadersO: [Int: String] = [:]
    var pageFootersE: [Int: String] = [:]
    var pageFootersO: [Int: String] = [:]

    // Planning #227 follow-up (2026-09-12): A COLUMN GROUP SHARES ONE TOP.
    // `applyColumns` folds every N consecutive sub-"pages" of a `.co n` region into one
    // physical sheet, side by side -- so those N sub-pages are N COLUMNS OF THE SAME
    // SHEET, and on paper they all begin at the SAME vertical position: wherever the
    // columnar region itself began on that sheet, BELOW any non-columnar prefix (a
    // title line and its blank) the sheet opened with. Each column therefore has that
    // much LESS room than a whole page, not a whole page's worth.
    //
    // Measured against real WS7 (`ws7-prints/v4`, PRISTINE.EXE) -- every column of
    // every one of these begins at the region's own top, and every column holds the
    // same number of lines as column 1's own columnar part, never more:
    //   REF/WINGDING.CHT   prefix 2 lines (24pt): WS7 columns 2-5 start at 153.2pt and
    //                      hold 45 lines; this engine started them at the sheet's own
    //                      first text line (129.2pt) and gave them 46.
    //   REF/SYMBOL.CHT     prefix 2 lines (24pt): WS7 124.4pt / 47 lines; engine
    //                      100.4pt / 48.
    //   PRINTERS/fontcrib.ws, PRINTER.PS   prefix 2 lines (24pt): WS7 66.8pt / 51
    //                      lines; engine 42.8pt / 52.
    // `colOffsetPt` is that prefix's own height in points, captured from `spent` at the
    // moment the group's FIRST columnar line is admitted -- the same quantity
    // `applyColumns` re-derives per merged sheet for the DRAW side
    // (`Page.columnTopOffsetPt`), from the same lines' own leads. It is charged against
    // `budget` for every column of the group EXCEPT the first (which pays the prefix
    // itself, out of the same budget, line by line), and released when the group wraps
    // onto a fresh sheet or the region ends. Port of Python's `_doc_to_pagelines`.
    var colGroupCols = 1            // `.co n` of the region the open page is in
    var colGroupIndex = 0           // which column of the group the open page is
    var colOffsetPt = 0.0           // the group's shared prefix height, in points
    func lineCols(_ line: PageLine) -> Int? {
        guard let bi = line.bi, bi >= 0, bi < doc.blocks.count else { return nil }
        return doc.blocks[bi].columns ?? 1
    }
    /// How much of `budget` the OPEN page must leave to the group's shared prefix:
    /// nothing for column 0, which pays that prefix line by line out of the same
    /// budget, and the prefix's own height for every column after it, which starts
    /// BELOW it.
    func colCut() -> Double { colGroupIndex > 0 ? colOffsetPt : 0.0 }

    /// This line's own vertical advance, in points -- what it spends out of `budget`
    /// (the page's real text height, `printedBudgetPt`).
    ///
    /// EVERY line spends its own lead, the page's first one included: `pageStream`
    /// places that first baseline at `top` plus its OWN lead, so on paper it has
    /// already consumed exactly that much of the text height. This used to credit the
    /// first line as free against a budget one default lead short
    /// (`(cap - 1) * defaultLead`), which is the same arithmetic whenever that line's
    /// lead is at or above the document default -- but a page opening on a line
    /// SHORTER than the default (sawyer/REF/WINGDING.CHT's own 12pt title under its
    /// `.lh 14pt`) was charged the full default for it and lost the difference. See
    /// `printedBudgetPt` for the measurements.
    ///
    /// b26-mtmb-general (pictures-mode pagination, -README.WS) and planning #236
    /// (sawyer/INTERVU.WS) both fall straight out of this rule rather than needing
    /// their own credits: an embedded image's `.lead` is a RESERVED-BAND total
    /// (`pixReservedAdvance` -- the pix tag's own line plus its contiguous following
    /// blanks), and charging it in full is precisely what the `pictures = .off` path
    /// spends on the same band as ordinary per-line advances, so the two modes break in
    /// the same place wherever the band lands; and a page whose first body line runs at
    /// a STYLE's own larger VMI (INTERVU.WS's 24pt "MS Body Copy" against an unset 12pt
    /// `.lh`) no longer pockets phantom room it never had.
    ///
    /// An OVERPRINT line shares the previous line's baseline and spends nothing, on
    /// paper and here. Port of Python's `_doc_to_pagelines`'s own `_cost`.
    func cost(_ line: PageLine) -> Double {
        let lead = line.lead ?? defaultLead
        if let last = page.last, last.overprint { return 0.0 }
        return lead
    }
    func closePage(explicit: Bool = false, breakBI: Int? = nil, formFeed: Bool = false) {
        var pg = Page(page,
                      headers: pageHeaders.filter { !$0.value.isEmpty },
                      footers: pageFooters.filter { !$0.value.isEmpty })
        // cause 10: kept even when the text dicts above drop the slot -- a header line
        // whose whole content was one print control has EMPTY text and a real control
        // to draw, which is exactly LSRBOX.WS's own `.h1`.
        pg.headerPcl = pageHeadersPcl.filter { !$0.value.isEmpty }
        pg.footerPcl = pageFootersPcl.filter { !$0.value.isEmpty }
        pg.footerInUse = !pageFooters.isEmpty
        pg.endedByFormFeed = formFeed
        // #228: only ever true from the post-loop trailing-`.pa` branch below,
        // and only when `page` (this closing page's own body) is empty -- a
        // page WITH content already carries real `.bi`-bearing lines, so it
        // needs no fallback and stays exempt from `finalizePages`'s empty-
        // trailing-page cleanup on its own (that cleanup only pops truly-
        // empty pages to begin with).
        if explicit, page.isEmpty {
            pg.explicitBreak = true
            pg.explicitBreakBI = breakBI
        }
        // WS4 sets the footer after the body from the bottom margin in force when the page
        // ENDS (run t43-mtmb: the number of page 1 sits at row 67 = 66 - 2 + 2 + 1, `.MB 2`
        // having been read mid-page), while the top margin printed at the page's start stays
        // what it opened with.
        let endMb = pageEndGeom?.mb ?? curMb
        if curMt != docMt || endMb != docMb {
            pg.mtLines = curMt
            pg.mbLines = endMb
        }
        // M31: this page's own sheet, stamped only when it differs from the document's
        // -- same `nil`/"document global" contract as everything else here, so every page
        // of every document with at most one column-1 `.pr or=` is byte-identical.
        if curOr != docOr {
            pg.orientation = curOr
        }
        if curPl != docPl {
            pg.plLines = curPl
        }
        if curHm != docHm || curFm != docFm {
            pg.hmLines = curHm
            pg.fmLines = curFm
        }
        // Planning #231: this page's own PARITY -- `pages.count` is exactly the count
        // of pages already closed, so the page closing right now is page number
        // `pages.count + 1`, known for the FIRST time here (nothing upstream of
        // pagination can know it). `leftForParity` falls back to `curPo` whenever
        // neither `.poe` nor `.poo` is in force, so a document that never uses either
        // resolves to `curPo` on every page, byte-identical to before this feature
        // existed.
        let isEvenPage = (pages.count + 1) % 2 == 0
        let parityPo = leftForParity(curPo, curPoe, curPoo, isEven: isEvenPage)
        if parityPo != docPo {
            pg.poCols = parityPo
            // #241 follow-up: mark that this override is a live `.poe`/`.poo` parity
            // decision (not a plain mid-document `.po` excursion) so the running
            // head/foot's own `pageGeomChanged` gate (`PDFWriter.swift`) -- correctly
            // built to exclude a HOLYMAC-style transient `.po` -- lets it through
            // regardless. See `Page.poParity`.
            pg.poParity = curPoe != nil || curPoo != nil
        }
        // THE AUTOMATIC NUMBER IS STAMPED WHERE THE PAGE ENDS, not where it began -- so
        // its `.po` is the one in force at this page's LAST line, and `curPo` (the
        // page-OPEN snapshot every other field here carries) is the wrong question to
        // ask for it. The oracle is `sawyer/REF/REFORM.DOT`: its `.po 1i` lands two
        // lines before the page's own `.pa`, WS7 prints the LAST body line at 72.0pt
        // (10 columns -- the new offset, live) and that same page's number at 306.0pt,
        // `(10 + 33.5 - 1) * 7.2`. Reading the page's opening `.po 8` instead put the
        // number at 291.6pt. `sawyer/REF/FONTS.REF` (alternating `.po.2i`/`.po.7i`, ten
        // numbered pages at 248.4 / 284.4 page by page) agrees under both readings and
        // so does not separate them; REFORM does.
        //
        // Read off `PageLine.poCols` -- the parser's own `.if`-aware per-line state --
        // and NEVER `poTimeline`, which lists a `.po` inside a FALSE `.if` block like
        // any other and would answer `REF/REFORM.DOT` and `FONTS/PS/ERROR.WS` with the
        // `.po .7i` WordStar never executes (WS7 numbers both at 306.0pt, the `.po 1i`
        // before the conditional; the checkpoint scan says 284.4).
        //
        // NO CHECKPOINT FALLBACK either. `PageLine.poCols` `nil` on every line of the
        // page means what it means everywhere else here -- "this page agrees with the
        // document's own default" -- and `autoPageNumberXPt` reads that default itself
        // when handed `nil`. `FONTS/PS/ERROR.WS` is `.po 1i` + `.if 1=0`/`.po .7i`/`.ei`
        // and NOTHING else, so no line ever carries an override, the document default is
        // the correct 10 columns, and the checkpoint scan's own answer is the dead 7.
        //
        // PARITY STILL WINS, resolved at the same block: `.poe`/`.poo` are the page's
        // own even/odd offsets whatever `.po` says (planning #231).
        let pageBIs = pg.lines.compactMap { $0.bi }
        if let endBI = pageBIs.max() {
            let endPo = pg.lines.reversed().compactMap { $0.poCols }.first
            let endPoe = poeList.atIfAny(endBI)
            let endPoo = pooList.atIfAny(endBI)
            if endPo != nil || endPoe != nil || endPoo != nil {
                pg.autoPagenoPo = leftForParity(endPo ?? docPo, endPoe, endPoo,
                                                isEven: isEvenPage)
            }
        }
        // Planning #250: `.h1e`/`.h1o`/`.f1e`/`.f1o` -- this page's own PARITY
        // (`isEvenPage`, just resolved above) picks its real line-1 text the same way
        // `.poe`/`.poo` picks its own left origin: its OWN parity variant if the
        // document ever set one FOR THIS PARITY, else whatever plain `.h1`/`.he`/
        // `.f1`/`.fo` governs (`pageHeaders`/`pageFooters`, already the page's own
        // snapshot, unchanged). `pageHeadersE`/`O`/`pageFootersE`/`O` all empty (no
        // document that never uses the family) means `parityHF` returns `nil` every
        // time below -- `pg.headers`/`pg.footers` stay byte-identical to before this
        // feature existed.
        //
        // "Only one of the pair set" (no corpus document exercises it): the un-set
        // parity has no override of its own here and falls through to `pageHeaders`/
        // `pageFooters` -- the flat dict every `.h#`/`.f#` command ALSO writes
        // (`parseHeadFoot`, unconditionally, parity or not), the SAME last-in-source-
        // order-wins projection Modern/RTF/plain-text already read. Port of ctrl-kd's
        // own `_parity_hf` (pdf.py, planning #250) -- see its own doc comment for why
        // the flat fallback is NOT necessarily "the plain `.h1`'s own text" (a parity-
        // specific override is independently stateful, same as `.poe`/`.poo`).
        func parityHF(evenMap: [Int: String], oddMap: [Int: String],
                     fontsParity: [Int: [HFParity: Int]], tabsParity: [Int: [HFParity: HFTabMark]],
                     alignParity: [Int: [HFParity: Alignment]],
                     styleAttrsParity: [Int: [HFParity: Style]])
            -> (text: String, override: HFOverride)? {
            guard evenMap[1] != nil || oddMap[1] != nil else { return nil }
            let letter: HFParity
            let text: String
            if isEvenPage, let t = evenMap[1] {
                letter = .even; text = t
            } else if !isEvenPage, let t = oddMap[1] {
                letter = .odd; text = t
            } else {
                return nil
            }
            // Planning #255: this page's own resolved style-sheet alignment/span attrs,
            // the SAME parity slot fontIdx/tab just above already read.
            let override = HFOverride(fontIdx: fontsParity[1]?[letter], tab: tabsParity[1]?[letter],
                                      align: alignParity[1]?[letter],
                                      styleAttrs: styleAttrsParity[1]?[letter] ?? [])
            return (text, override)
        }
        if let (text, override) = parityHF(evenMap: pageHeadersE, oddMap: pageHeadersO,
                                           fontsParity: doc.headerFontsParity,
                                           tabsParity: doc.headerTabsParity,
                                           alignParity: doc.headerAlignParity,
                                           styleAttrsParity: doc.headerStyleAttrsParity) {
            if text.isEmpty { pg.headers.removeValue(forKey: 1) } else { pg.headers[1] = text }
            pg.headHfOverride = [1: override]
        }
        if let (text, override) = parityHF(evenMap: pageFootersE, oddMap: pageFootersO,
                                           fontsParity: doc.footerFontsParity,
                                           tabsParity: doc.footerTabsParity,
                                           alignParity: doc.footerAlignParity,
                                           styleAttrsParity: doc.footerStyleAttrsParity) {
            if text.isEmpty { pg.footers.removeValue(forKey: 1) } else { pg.footers[1] = text }
            pg.footHfOverride = [1: override]
        }
        // Body text: `resolvePrintedBody` could not resolve a `.poe`/`.poo`-governed
        // line's own left origin at BUILD time (which page, and therefore which
        // parity, a line lands on is a pagination question, not a parse-order one) --
        // it left a `(even, odd)` candidate pair on `.parityLeft` instead. Resolved
        // now, in place, the one moment this loop actually knows this page's parity.
        for i in pg.lines.indices {
            if let parityLeft = pg.lines[i].parityLeft {
                pg.lines[i].left = isEvenPage ? parityLeft.even : parityLeft.odd
            }
        }
        // triage Q12 -- see `Page.readPos`'s own comment. Counted off the BODY only: a note
        // area's lines are the emitter's own, and the reference that pulled them down here
        // was already counted on the body line carrying it.
        pg.readPos = readPos
        // The note area closes with its page: every page of a document with notes carries
        // the stamps, parity and head/foot state above like any other, the area is the only
        // thing added. Its lines carry no `bi`, so none of the per-line passes above
        // (`.po`, parity, the automatic number) read them.
        openArea()
        lastRoomLines = roomLines() - areaSize(notes.entries)
        lastHasArea = !notes.entries.isEmpty
        if lastHasArea {
            let geometry = pageGeometryDocument(doc, for: pg) ?? doc
            let bodyY = Double(printedTop(geometry)) + colCut() + spent
            let bodyEmpty = pg.lines.isEmpty
            for line in notes.anchoredArea(in: geometry, bodyY: bodyY, bodyEmpty: bodyEmpty) {
                pg.append(line)
            }
            if bodyEmpty, let pos = readPos {
                // a note-only page prints its page number (run fnlong120 p3): with no body
                // line to look it up from, it takes the state of the last block read.
                pg.explicitBreakBI = pos.bi
            }
        }
        pages.append(pg)
    }
    func openNewPage() {
        // One sub-page just closed: the NEXT one is the next column of this group,
        // until the group wraps onto a fresh physical sheet (where there is no prefix
        // above the region any more). Port of Python's `_advance_column`.
        if colGroupCols > 1 {
            colGroupIndex += 1
            if colGroupIndex >= colGroupCols {
                colGroupIndex = 0
                colOffsetPt = 0.0
            }
        }
        page = []
        spent = 0.0
        pageEndGeom = nil
        pageHeaders = curHeaders
        pageFooters = curFooters
        pageHeadersPcl = curHeadersPcl
        pageFootersPcl = curFootersPcl
        pageHeadersE = curHeadersE
        pageHeadersO = curHeadersO
        pageFootersE = curFootersE
        pageFootersO = curFootersO
        notes.beginPage()
        carryOpen = true
    }

    // The note area's two hooks into this page. Whole default-lead lines of the open page
    // still free under the body placed so far (floored: a fractional line already spent by
    // a styled line is never credited back), and the carry-over -- whatever an earlier
    // page's area could not hold -- admitted before any new reference queues behind it. It
    // waits until the new page's own geometry is known (`recomputeGeom`), or the page
    // closes. A document with no notes queues nothing, so both are no-ops.
    func roomLines() -> Int {
        // Floored by hand: `rounded(.down)` calls the C library's `floor`, which this Foundation-free engine does not
        // link on Linux (the public engine workflow's link failure, v4.6.0).
        let lines = (budget - colCut() - spent) / defaultLead + 1e-9
        let whole = Int(lines)
        return Double(whole) > lines ? whole - 1 : whole
    }
    func admitNotes() {
        notes.admit(roomLines: roomLines())
    }
    /// Whether `line`, a body line that fits, goes to the next page together with its
    /// notes (WS7 report 14.8, 14.15): its notes do not fit whole under it and the room
    /// left from this line down, the line itself and any area already committed counted
    /// out, is under `fnrun` note lines -- or leaves no room to run a first part at all.
    /// Otherwise the line stays and the notes run (`NoteArea`).
    func noteMovesWithLine(_ line: PageLine, _ due: [(note: Note, index: Int)]) -> Bool {
        if due.isEmpty { return false }
        let lines = (budget - colCut() - spent - cost(line)) / defaultLead + 1e-9
        let whole = Int(lines)
        let roomAfter = Double(whole) > lines ? whole - 1 : whole
        let (split, taken) = notes.runWouldSplit(due, width: PDFMetrics.maxCols,
                                                 roomLines: roomAfter)
        if !split { return false }
        let roomBefore = roomLines() - areaSize(notes.entries)
        return roomBefore < (doc.footnoteRunLines ?? footnoteRunFactory) || taken < 1
    }
    func openArea() {
        guard carryOpen else { return }
        carryOpen = false
        admitNotes()
    }

    /// Triage Q9: WordStar closes a page the MOMENT it is full; this engine breaks
    /// lazily, when the next line turns out not to fit. True when the next real line on
    /// this page cannot fit — i.e. the break has, in WordStar's own reckoning, already
    /// happened, so a dot command read here belongs to the next page. An EXPLICIT break
    /// ahead is not this case: the command still belongs to the page it was read on.
    func pageAlreadyFull(_ fromIndex: Int) -> Bool {
        if page.isEmpty { return false }
        for peek in items[(fromIndex + 1)...] {
            switch peek {
            case .pageBreak: return false
            case .line(let pl, _):
                return spent + cost(pl) + notes.heightPt > budget - colCut() + 1e-6
            default: continue
            }
        }
        return false
    }

    // planning #271 M10 (the QuickLook thumbnail): stop paginating once the caller's
    // prefix is on the shelf. `rawPageCap` is already the SUB-page budget -- one column
    // of a `.co n` region is a sub-page here, and `applyColumns` folds n of them into
    // one sheet afterwards -- with one spare on top, so the page the caller asked for is
    // never the array's LAST page and never meets a tail rule it would not meet in a
    // full run. `docToPagelines` computes it; nothing else calls this with a cap.
    var stoppedEarly = false
    for (itemIndex, item) in items.enumerated() {
        if let cap = rawPageCap, pages.count >= cap {
            stoppedEarly = true
            break
        }
        switch item {
        case .hf(let kind, let line, let text, let parity, let pcl):
            if parity == .even {
                if kind == .header { curHeadersE[line] = text } else { curFootersE[line] = text }
            } else if parity == .odd {
                if kind == .header { curHeadersO[line] = text } else { curFootersO[line] = text }
            }
            if kind == .header { curHeaders[line] = text } else { curFooters[line] = text }
            // cause 10: this event's own print controls travel with its text.
            if kind == .header { curHeadersPcl[line] = pcl } else { curFootersPcl[line] = pcl }
            // A HEADER is emitted at the TOP of a page, so a `.he`/`.h#` read after
            // the page's first line cannot reach it -- that is the `page.isEmpty`
            // gate, and it is right. A FOOTER is emitted at the BOTTOM, so a
            // `.fo`/`.f#` read ANYWHERE before the page ends still governs that page.
            // Both used to take the header's rule, which put every footer change one
            // page late.
            //
            // MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on
            // `sawyer/MACROS/HOLYMAC/8MAC`, which sets `.fo<31 blanks>#` after a blank
            // line (so page 1 has already begun) and clears it with a bare `.fo`
            // immediately AFTER its first page break. WS7 prints "286" at 280.8pt --
            // column 31, exactly where the `#` sits -- at the foot of page 1 and NO
            // footer on pages 2-10; and, from the same commands, NO header on page 1
            // and "HOLY MACRO!  #" on 2-10. This engine printed the automatic page
            // number on page 1 (centred, 291.6pt) and the footer on page 2.
            //
            // AND (triage Q9) WordStar closes a page the MOMENT it is full; this engine
            // breaks lazily, when the next line turns out not to fit. A dot command
            // sitting exactly on that boundary is therefore read on the OLD page here and
            // on the NEW page in WordStar. `8MAC`'s page 1 fills exactly (its last body
            // line at 7200 decipoints, the last the page has) and its bare `.fo` sits
            // immediately after it: real WS7 keeps `286` at the foot of page 1, so that
            // `.fo` was read on page 2.
            if kind == .footer && !pageAlreadyFull(itemIndex) {
                pageFooters = curFooters
                pageFootersPcl = curFootersPcl
                pageFootersE = curFootersE
                pageFootersO = curFootersO
            } else if kind == .header && page.isEmpty {   // nothing printed on this page yet
                pageHeaders = curHeaders
                pageHeadersPcl = curHeadersPcl
                pageHeadersE = curHeadersE
                pageHeadersO = curHeadersO
            }
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            // planning #236 remainder (sawyer/INTERVU.WS): the same style-vs-
            // document-default gap `cost`'s first-line credit above was just
            // fixed for. A flat `n * defaultLead` room estimate prices the
            // upcoming reserved lines at `n * defaultLead` points when they
            // may actually cost more (a style's own bigger VMI, or a
            // stateful `.lh` override) — measured directly against
            // INTERVU.WS's WS7 capture: a `.cp2` sitting right after a Q&A
            // paragraph break measured room in default-lead units as
            // sufficient when only 36pt of real room was left and both
            // reserved lines (each a real 24pt "MS Body Copy" style line)
            // together need 48pt. Real WS7 pushes the WHOLE paragraph to a
            // fresh page instead of splitting it. Look ahead at the REAL
            // cost of the next `n` PageLines (skipping sentinels) instead of
            // assuming each one is exactly `defaultLead` tall — confirmed
            // necessary and not merely redundant with the `cost` fix: without
            // this lookahead too, the same document still mispaginates.
            // Port of Python's identical `pdf._doc_to_pagelines` fix.
            var needed = 0.0
            var seen = 0
            var lastLead = defaultLead
            peekLoop: for peekIndex in (itemIndex + 1)..<items.count {
                switch items[peekIndex] {
                case .pageBreak:
                    break peekLoop
                case .hf, .condPage:
                    continue peekLoop
                case .line(let peekLine, _):
                    lastLead = peekLine.lead ?? defaultLead
                    needed += lastLead
                    seen += 1
                    if seen >= n { break peekLoop }
                }
            }
            // `.cp n` asks whether n lines fit, not whether the lines that happen to follow
            // it do: a line that is not there (a `.pa`, the end of the text) still takes the
            // room it would have (WS4 teardown 7.7, runs w14-pafoot/w14-cpfoot; WS7 teardown
            // `wordstar-dos/11-print-engine.md` 11.3, 15.1: room / line height < n breaks).
            needed += Double(max(0, n - seen)) * lastLead
            let room = budget - colCut() - spent - notes.heightPt
            // WS4: floor(R / LH) + 1 < n, i.e. the nth line from here would not start in the
            // room that is left.
            let short = era.lineStartsInRoom ? (needed - lastLead) >= room - 1e-6
                                             : room < needed - 1e-6
            if short, !page.isEmpty {
                closePage()
                openNewPage()
                roomBreakOpen = false
            }
        case .pageBreak(let formFeed):
            // Always closes -- even an empty page, which IS a blank sheet (`.pa .pa` before
            // WS5; in WS7 a `.pa` on an empty page never gets here, see
            // `resolvePrintedBody`).
            closePage(formFeed: formFeed)
            openNewPage()
            roomBreakOpen = false
        case .line(let line, let due):
            // Finding 3: a line about to start a FRESH page picks up the `.mt`/`.mb`
            // in force at ITS OWN block — recomputing `capacity`/`budget` for THIS
            // page only, so a page whose geometry never changes never recomputes to a
            // different number (see `printedCapFor`'s docstring).
            if page.isEmpty, let bi = line.bi {
                let (mt, mb, pl, hm, fm, po, poe, poo, orient) = recomputeGeom(bi)
                curMt = mt
                curMb = mb
                curPl = pl
                curHm = hm
                curFm = fm
                curPo = po
                curPoe = poe
                curPoo = poo
                curOr = orient
                capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                budget = budgetFor(capacity, mt, mb, pl)
            }
            openArea()
            // A line LEAVING the columnar region releases the group's shared prefix
            // before this page's own room is judged -- the break that carried us here
            // was forced by that same state change (`resolvePrintedBody`'s own `prevCols`
            // gate), so the page it opens is an ordinary whole one again.
            if colGroupCols > 1, lineCols(line) == 1 {
                colGroupCols = 1
                colGroupIndex = 0
                colOffsetPt = 0.0
            }
            // A body line is admitted while it fits ABOVE the note area already committed
            // (`notes.heightPt`, 0 for a page with none), which `admitNotes` grew
            // incrementally, splitting notes when they couldn't finish. A reference line
            // whose notes only PARTLY fit stays when the room is `fnrun` lines or more, and
            // its overflow continues on the next page's area; below that it moves with its
            // notes to the next page (`noteMovesWithLine`). A page whose area ends in a
            // note that runs takes no more body lines (`notes.sealed`). A page's first line
            // is admitted whatever it costs (`page.isEmpty` below), so an image taller than
            // the whole page still lands somewhere: a slightly overflowing page beats a
            // hang or lost content (the same doctrine `admitFootnotes` documents).
            var lineGeometry: BodyGeometry?
            if exactBudget, let bi = line.bi {
                // WS4: a `.pl/.mt/.mb` read mid-page changes this page's budget at once; the
                // page's own stamps (`curMt`..., its printed top margin) stay what the page
                // opened with.
                let geometry = bodyGeometry!.at(bi, consumed: readTally[bi] ?? 0)
                lineGeometry = geometry
                budget = budgetFor(capacity, geometry.mt, geometry.mb, geometry.pl)
            }
            var need = cost(line)
            if let rise = line.fontRise, rise > 0, era.overhangsByFontRise {
                // WS7 report 15.1 (runs tall24, tall36): under `.lh a` the paginator looks
                // one base line ahead at each line's end, so a line starts while a base
                // line still fits, and a font on it that raises its height moves it to the
                // next page only when the room left is smaller than the RISE -- otherwise
                // it stays and overhangs the bottom. The room test is therefore against the
                // larger of the base line and the rise, not against the line's whole
                // height.
                need = max(defaultLead, rise)
            }
            // WS4 starts a line while the height used is under the body height; the page ends
            // after the first line that overruns it (`Era.lineStartsInRoom`).
            let overflow = era.lineStartsInRoom
                ? spent + notes.heightPt > budget - colCut() - 1e-6
                : spent + need + notes.heightPt > budget - colCut() + 1e-6
            // Finding 1 (b26 visual pass): the FIRST `ws4Spacing` blank (see
            // `ws4SpacingBlankIndices`) to overflow a page's budget never triggers
            // the break by itself -- a physical blank-line paper advance right at
            // the bottom margin doesn't need a fresh sheet, and giving it its OWN
            // page-break decision was this finding's original bug (a page break
            // landing mid text/blank pair silently spent one line of the NEXT
            // page's budget on ink-free paper, growing a cumulative real-line
            // deficit every other page). ONLY a PageLine `ws4SpacingBlankIndices`
            // positively classified gets this exemption -- an ordinary blank
            // (every non-WS4 document's blanks, and a WS4 document's own authored
            // ones, chapter-drops included) still forces the break exactly as
            // before this fix, since `ws4Spacing` defaults `false` and nothing here
            // changes that default. `alreadyOver` denies the exemption to a SECOND
            // consecutive over-budget spacing blank (a paragraph boundary's own 2-3
            // blank run): forgiving every blank in a run over-admits a whole extra
            // real line one measured source's own WS7 capture didn't have.
            let alreadyOver = spent + notes.heightPt > budget - colCut() + 1e-6
            var full = overflow && !(line.ws4Spacing && !alreadyOver)
            if !full, !page.isEmpty {
                full = notes.sealed || noteMovesWithLine(line, due)
            }
            if full, !page.isEmpty {
                closePage()
                openNewPage()
                roomBreakOpen = true
                // organic overflow (see `recomputeGeom`'s doc comment): `line` itself is
                // the new page's first line and never reaches the top-of-case
                // `page.isEmpty` gate above, since `page` is not empty until closePage/
                // openNewPage runs right here, mid-iteration.
                if let bi = line.bi {
                    let (mt, mb, pl, hm, fm, po, poe, poo, orient) = recomputeGeom(bi)
                    curMt = mt
                    curMb = mb
                    curPl = pl
                    curHm = hm
                    curFm = fm
                    curPo = po
                    curPoe = poe
                    curPoo = poo
                    curOr = orient
                    capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                    budget = budgetFor(capacity, mt, mb, pl)
                }
                openArea()
                // A page of nothing but a carried-over note is a page too: the note takes
                // the whole of it and the line waits for the next (WS7 report 15.1, run
                // fnlong120).
                while !notes.entries.isEmpty,
                      spent + cost(line) + notes.heightPt > budget - colCut() + 1e-6 {
                    closePage()
                    openNewPage()
                    openArea()
                }
            }
            // `.sb`: a blank line at the top of a page doesn't print.
            if suppressBlanks, page.isEmpty, isBlankPageLine(line) {
                continue
            }
            if era.softBlanksSwallowed, roomBreakOpen, page.isEmpty, line.soft,
               isBlankPageLine(line) {
                // WS7 report 15.1 (run sb8d): when a line ends a page by room the paginator
                // swallows the empty lines that follow it whose return is soft -- the same
                // loop that serves `.sb`, which swallows every empty line. Hard-return
                // empties carry over to the top of the next page (blank3).
                continue
            }
            roomBreakOpen = false
            if let lc = lineCols(line), lc > 1, colGroupCols == 1 {
                // The group starts HERE: whatever this page has already spent is the
                // prefix every column of it shares.
                colGroupCols = lc
                colGroupIndex = 0
                colOffsetPt = spent
            }
            spent += cost(line)
            if let bi = line.bi {
                readTally[bi, default: 0] += 1
                readPos = PageReadPos(bi: bi, count: readTally[bi]!)
            }
            page.append(line)
            if let lineGeometry { pageEndGeom = lineGeometry }
            lastAppendedItem = itemIndex
            // Then this line's notes queue, and as many as fit join the area.
            notes.enqueue(due, width: PDFMetrics.maxCols)
            admitNotes()
        }
    }
    if stoppedEarly {
        // The open page is a partial page of content we deliberately stopped reading;
        // closing it would append a page that a full run would have filled further.
        // Everything below this line is end-of-document reasoning, and this is not the
        // end of the document.
        return pages
    }
    if !page.isEmpty {
        closePage()
        // The document's own trailing blank lines (`resolvePrintedBody` put them last): the
        // page that holds the last of them is marked for `finalizePages`.
        if era.blankLinesMakePages, !doc.blocks.isEmpty, doc.eofBlankLines > 0,
           lastAppendedItem == items.count - 1 {
            pages[pages.count - 1].eofBlankBI = doc.blocks.count - 1
        }
    } else if case .pageBreak = items.last, doc.paEofBlankAfter {
        // #228 (research/2026-09-08_trailing-pa-rule.md, planning #228):
        // "WS7 opens the page after a forced `.pa` break ONLY when at
        // least one more real content paragraph -- even an entirely
        // blank one -- follows that `.pa` before end-of-file." The
        // document's last item was an explicit `.pa`, `page` is empty
        // by construction (reset when that pagebreak was processed
        // above, never touched since), and `doc.paEofBlankAfter`
        // (computed once at parse time from the file's own saved-
        // trailer bytes -- `trailingPaHasContentAfter` in ParseWS.swift)
        // confirms this specific document really did save a blank
        // paragraph after that `.pa`, not just a bare unconditional
        // pagebreak (the overwhelming majority of `.pa`-terminated
        // documents, which open no extra page at all).
        closePage(explicit: true, breakBI: doc.blocks.count - 1)
    }

    // What follows is the note area's own end of the document -- nothing below runs for a
    // document without notes. The pages it adds take the head/foot and geometry state in
    // force at the end, like any page opened there (`closeTailPage`).
    carryOpen = false
    /// A page of the note area's tail: `lines` as the whole page, on a page opened after
    /// everything read so far.
    func closeTailPage(_ lines: [PageLine], explicitBI: Int? = nil) {
        openNewPage()
        carryOpen = false
        page = lines
        closePage()
        if let explicitBI { pages[pages.count - 1].explicitBreakBI = explicitBI }
    }

    // Rule 5: whatever the last body page's bottom footer couldn't hold prints at the TOP
    // of its own fresh page(s) instead of waiting for a "next page" that doesn't exist.
    // Rendered through the SAME `admitFootnotes`/`renderArea` pair as the in-page area, so
    // the header here is the same 3 lines -- blank / 20-dash rule / blank -- not the 1-line
    // separator the retired `fitFooter(leadingBlank: false)` path used to emit (shape
    // divergence from the oracle, closed 2026-08-18). The ceiling is the whole page: these
    // pages ARE the manual's stated exception.
    //
    // PROGRESS GUARD. This loop's termination used to depend entirely on its helper
    // consuming at least one queued line per call, with nothing checking that it did. On
    // 2026-07-31 a regression in the helper made it consume nothing at `capacity == 3`;
    // this loop then appended a page per pass forever, reached 15.7 GB, and stalled the
    // whole machine for 2h40m -- no crash, no OOM kill, just unbounded growth.
    //
    // A layout loop whose exit depends on a helper making progress must verify that the
    // progress happened. Two invariants, in priority order: no text is ever lost, and the
    // layout always terminates. So when a pass consumes nothing, flush everything still
    // queued onto one page and stop -- that page overflows, which is strictly better than
    // dropping text or hanging.
    while !notes.queue.isEmpty {
        let linesBefore = notes.queuedLineCount
        var entries: [[PageLine]] = []
        admitFootnotes(&entries, &notes.queue, ceiling: capacity)
        let area = renderArea(entries)
        if notes.queuedLineCount >= linesBefore {
            // No progress. Emit the page we just built, then flush the rest verbatim so
            // nothing is lost, and leave the loop. No Python oracle covers this
            // Swift-only safety branch; treating it as "no room" is a deliberate,
            // conservative judgment call so endnotes never try to continue onto a page
            // that just absorbed a raw overflow dump.
            if !area.isEmpty { closeTailPage(area) }
            var flushed: [PageLine] = []
            for entry in notes.queue {
                if !flushed.isEmpty { flushed.append([]) }
                flushed.append(contentsOf: entry.remaining)
            }
            notes.queue.removeAll()
            if !flushed.isEmpty { closeTailPage(flushed) }
            lastRoomLines = 0
            lastHasArea = true
            break
        }
        closeTailPage(area)
        lastRoomLines = capacity - areaSize(entries)
        lastHasArea = true
    }

    // Endnotes: the true end of the document, no heading, no separator.
    //
    // CONTINUES the last body/footnote page when it has room (round 26 wave 3,
    // fidelity_gate.py Finding C), instead of always forcing a fresh one -- not a fresh
    // 3-line area header, since this is one more entry in the SAME note area, not a new
    // section. The previous unconditional-fresh-page version put "(1) Endnote" alone on an
    // otherwise-near-empty page 2, the actual cause of -SCREEN's 2-page overflow (WS7: 1).
    // A page with NO room left (the overwhelmingly common multi-page case) is untouched:
    // endnotes start fresh exactly as before.
    //
    // `lastHasArea` (round 27, b28 note 6) decides whether a blank line precedes the FIRST
    // endnote, and it is NOT unconditional. WS7's note face is 12-point, so ONE note line
    // advances 120 decipoints -- the 2026-08-20 measurement that put a blank line here read
    // the natural 240dp two-line advance as "24pt, one blank line" and generalised it.
    // Re-measured 2026-08-23 against both WS7 captures (jon_vault WordStar/ws7-prints/v1/):
    //
    //   -SCREEN.pcl  "1. Footnote" V=7080 -> "(1) Endnote"  V=7320 = 240dp
    //                = ONE BLANK LINE, endnotes joining a FOOTNOTE AREA.
    //   TESTING.pcl  last body line     V=3765 -> "(1)This..." V=3885 = 120dp
    //                = NO BLANK LINE, endnotes following BODY TEXT.
    //   TESTING.pcl  endnote (1) V=3885 -> (2) V=4125 = 240dp = one blank line BETWEEN
    //                entries (the blank `endnoteSectionLines` puts between them).
    //
    // So the leading gap belongs only when the last page ends with a footnote area -- it is
    // one more entry joining that area. Following plain body text the endnotes butt straight
    // up against it, which is what Jon reported in the b27 review.
    //
    // #228 (research/2026-09-08_trailing-pa-rule.md): a trailing `.pa` -- the document's own
    // LAST block -- closes the current page (WordStar's own "force a new page" signal) even
    // when nothing real follows it before EOF and no visible extra page ever opens
    // (`doc.paEofBlankAfter` false, the ordinary case). Giving that page no room makes the
    // continuation below refuse to merge the document's endnotes onto page 1's remaining
    // room, matching WordStar's own documented default endnote placement (WSFORMAT.TXT: no
    // `.PE` -> "endnotes will be printed at the very end of the document ... starting a new
    // page if they don't fit what's left"). Confirmed against sawyer/DISPLAY.WS and
    // sawyer/REF/NOTES.TST: both end in a bare `.pa` (nothing after) and both need their real
    // endnote content on ITS OWN fresh page, not merged with the footnote already on page 1.
    if doc.blocks.last?.kind == .pagebreak {
        lastRoomLines = 0
    }
    var endnotes = endnoteSectionLines(doc, padCols: notes.padCols, width: PDFMetrics.maxCols,
                                       sentenceSpacing: sentenceSpacing)
    if !endnotes.isEmpty {
        if lastRoomLines > 0, let last = pages.last, !last.isEmpty {
            if lastHasArea {                // see the WS7 measurements above
                endnotes.insert([], at: 0)
            }
            var room = lastRoomLines
            while room >= 1, !endnotes.isEmpty {
                pages[pages.count - 1].append(endnotes.removeFirst())
                room -= 1
            }
        }
        // #228: a FRESH endnote page (not a continuation of the body's own last page) has
        // no `.bi`-carrying line of its own -- every line here comes from
        // `endnoteEntryLines`, never a `.bi`-tagged PageLine -- so the auto-page-number
        // lookup at render time has nothing to resolve against. `explicitBreakBI` (the
        // document's own highest block index -- "wherever the document's own state was by
        // its own end") stands in, the same fallback the trailing-`.pa` blank page uses.
        // Confirmed against sawyer/DISPLAY.WS: WS7's own page 2 (the endnote, on its own page
        // once the trailing-`.pa` continuation fix above stops it merging with page 1)
        // carries the automatic page number "2".
        while !endnotes.isEmpty {
            let chunk = min(capacity, endnotes.count)
            closeTailPage(Array(endnotes.prefix(chunk)), explicitBI: doc.blocks.count - 1)
            endnotes.removeFirst(chunk)
        }
    }

    return pages
}

/// Whether a page line has nothing on it — no segments, or only whitespace. b24 round
/// 19 (RULINGS-LEDGER PIX row): an image PageLine has no text segments (`[]`, by
/// construction — see `resolvePrintedBody`'s substitution), so `.image` must be checked
/// FIRST or an embedded picture sitting last in a short document (the real-corpus
/// shape: every acceptance document's own pix tag is its own final content) reads as a
/// trailing machine blank and gets silently popped off the page it was just placed on
/// (the PREVIEW.WS root-cause fix). Port of `_is_blank`.
func isBlankPageLine(_ line: PageLine) -> Bool {
    line.image == nil && !line.contains { $0.text.contains { !$0.isWhitespace } }
}
