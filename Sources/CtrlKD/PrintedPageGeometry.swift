/// Printed page geometry and numbering: the resolved sheet, the text capacity and budget a
/// paginator spends, the left edge, and the checkpoint lookups that give each page its number.

/// Port of Python's `round()` (round-half-to-even / banker's rounding), which differs from
/// Swift's `FloatingPoint.rounded()` default (round-half-away-from-zero) — and `.rounded()`
/// itself needs libm symbols this Foundation-free Linux build can't link. `x` is always
/// non-negative here (a resolved page height in points), so `Int(x)` (truncation, which
/// equals floor for non-negatives) plus plain comparison reproduces `round()` exactly,
/// including its `.5` tie case, with no floating-point library call at all. Same technique
/// as `SymmetricBlocks.swift`'s `roundHalfToEven`, which works in pure integer arithmetic;
/// this one takes a `Double` because a page height in inches isn't always a whole number of
/// `.pl` lines (custom/converted geometry), unlike that function's HMI fields.
///
/// Not `private`: `PDFWriter.swift`'s `pageStream` needs the same banker's-rounding (ctrl-kd
/// 2.0.0's `supSize = round(size * 2 / 3)`, mirroring Python's `round()` exactly).
public func roundHalfToEven(_ x: Double) -> Int {
    let whole = Int(x)
    let fraction = x - Double(whole)
    if fraction < 0.5 { return whole }
    if fraction > 0.5 { return whole + 1 }
    return whole % 2 == 0 ? whole : whole + 1
}

/// A copy of `page` with `heightIn`/`pwIn` SWAPPED — `.pr or=l` (b24 round 17,
/// RULINGS-LEDGER row 2, register C18, Paged-surface doctrine point 2: "honor .pr or=l
/// landscape in all paged surfaces"). Port of Python's `_landscape_page`. Swapping at this
/// single source lets every existing `heightIn`/`pwIn` consumer (pagination capacity, top
/// margin, the MediaBox itself, RTF's `\paperh`/`\paperw`) cascade correctly with no
/// per-site change — a landscape page is genuinely SHORTER top-to-bottom (fewer text
/// lines fit) as well as wider, exactly what real landscape printing does. `.mt`/`.mb`/
/// `.po`-derived margins are left untouched — still top/bottom/left relative to the text,
/// same as WordStar's own driver-level rotation never re-interpreted them either.
///
/// planning #256 (sawyer/REF/-HOW-TO.RJS + the HP-ENV.LST/HP-ENVMM.LST mailing-label
/// pair): a plain swap of `page.heightIn`/`pwIn` (`resolvePageSize`'s PORTRAIT-convention
/// resolution, which Modern's own page box ALSO reads directly and unswapped — "the page
/// is the document's declared size", ruled 2026-08-06) only works when the document's
/// `.pl` already snapped to a NAMED portrait height. A `.pl` that instead matches a named
/// size's WIDTH column (every real landscape template measured: `.pl 8.5(i|")`/`8.33"`,
/// none a portrait height) resolves to a bare, un-landscape-aware SQUARE Custom fallback
/// there, and swapping two equal numbers changes nothing. Recomputes the pair fresh,
/// orientation-aware, from `page.plLines` alone — never from the cached, Modern-shared
/// portrait pair — so this correction stays scoped to Printed's own PDF/RTF geometry and
/// never touches `doc.page` (and therefore Modern's own page box) at all.
func landscapePage(_ page: PageGeometry) -> PageGeometry {
    let (heightIn, _, pwIn) = resolvePageSize(page.plLines, orientation: "landscape")
    var eff = page
    eff.heightIn = pwIn
    eff.pwIn = heightIn
    return eff
}

/// `page` as THIS SHEET's orientation wants it (M31). Port of Python's
/// `_page_dict_for_orientation`.
///
/// `landscapePage` is idempotent by construction -- it recomputes the height/width pair
/// fresh from the page's own `.pl` rather than swapping whatever pair it is handed -- so
/// `.landscape` can be applied to a geometry that has already been swapped, or to one that
/// has not, with the same answer. `.portrait` is the other direction and needs the same
/// treatment: `resolvePageSize`'s own PORTRAIT-convention resolution of this page's `.pl`,
/// recomputed fresh, so a page that must be put BACK from a document-wide landscape swap
/// lands exactly where a portrait document's own geometry would have.
public func pageGeometryFor(_ page: PageGeometry, orientation: Orientation) -> PageGeometry {
    if orientation == .landscape { return landscapePage(page) }
    let (heightIn, _, pwIn) = resolvePageSize(page.plLines)
    var eff = page
    eff.heightIn = heightIn
    eff.pwIn = pwIn
    return eff
}

/// The document an emitter actually lays out: `options.pageSettings` folded in, then
/// Printed's `.pr or=l` rotation on top of it, in that order. THE one place that order is
/// written down.
///
/// `options.pageSettings` is replacement geometry for everything the document does not
/// declare itself (a field is overridden only when its own resolved value is still this
/// project's built-in default — a document's own dot commands always win), because
/// WordStar's stock defaults are not what a given machine printed: WSCHANGE patches them
/// per installation. Applied to a COPY — `Document` is a value type, so there is nothing to
/// restore afterward, unlike Python's save/try/finally dance around a shared mutable
/// `doc.meta['page']`. The CLI applies the same thing once per document (`Run.swift`) via
/// the same `effectivePage` (EmitOptions.swift).
///
/// The rotation lands AFTER `pageSettings` — matching ctrl-kd: page-settings replacement
/// geometry, then orientation swap on top of it. It was PRINTED-ONLY (b24 round 17,
/// RULINGS-LEDGER row 2) until Jon's ruling 2026-09-15 ("Yes. Fix it.") took `.pr or=l`
/// to Modern as well: the paged-surface doctrine's own point 2 ("honor .pr or=l landscape
/// in ALL paged surfaces", 2026-08-17) reaching the last paged surface that ignored it,
/// and the 2026-08-05 ruling that Modern PDF is the printed form of the Modern RTF.
/// `printed` therefore no longer selects anything here; the parameter stays because this
/// function is the one place mode-specific page geometry belongs, and because
/// `printedDocument` is the public façade that says which mode it is asking about.
///
/// WHY IT IS A FUNCTION (planning #271 M2). Both steps used to be written inline at the top
/// of `emitPDF`, and the public façade the app draws its on-screen Printed page from
/// (`printedMetrics`, PrintedGeometry.swift) did NEITHER: a landscape document measured a
/// 612-wide portrait page on screen while the exported PDF used the rotated 792x612 and
/// anchored its running content, note area and first baseline to that — the same document
/// two ways, which is the exact failure that file exists to prevent. `printedDocument` is
/// the public form of this call; nothing outside re-derives the order.
///
/// `printed` is the caller's own already-resolved mode flag (`mode == .printed ||
/// isPrinted(doc)`), not re-derived here, so a caller that already knows which page it is
/// asking about (the façade: always Printed) does not have to fake a `Document` to say so.
func resolvedGeometryDocument(_ doc: Document, printed: Bool, options: EmitOptions) -> Document {
    var out = doc
    if let pageSettings = options.pageSettings, let page = out.page {
        out.page = effectivePage(page, settings: pageSettings)
    }
    if out.formatting.orientation == .landscape, let page = out.page {
        out.page = landscapePage(page)
    }
    return out
}

/// Resolved page height, in points, for THIS document — the general form of Python's
/// `_resolved_page_height(doc, printed)` (pdf.py:42-53). `PDFWriter.swift`'s `emitPDF` needs
/// this too (the MediaBox and the content stream's Y-origin must agree with the capacity
/// this same figure drives, or a custom-geometry page paginates correctly but still gets
/// drawn on/labeled as a Letter-size sheet) so this is `internal`, not `private`.
///
/// Modern renders on the document's declared sheet (Letter/Legal/A4 -- ruled
/// 2026-08-06); silence is Letter, exactly as before.
///
/// M18 (2026-09-15): Modern has its own answer now, `modernSheetH`, and `emitPDF`'s
/// Modern branch calls THAT — the same number `modernStreams` composes on, with `.pl 0`
/// and the footnote floor handled the way Printed handles them. The `printed == false`
/// branch below is the shape of this function's contract, never a live Modern render.
/// True when NOT ONE line on any page carries a block index — a document with no body at
/// all. The corpus's examples are galley and manuscript TEMPLATES, one page each, nothing
/// but dot commands and a pair of `.h1o`/`.h1e` running heads. See
/// `pgnumForBodilessPage`. Port of `_pgnum_is_bodiless`.
func pgnumIsBodiless(_ pages: [Page]) -> Bool {
    !pages.contains { $0.contains { $0.bi != nil } }
}

/// Whether WordStar numbers a page that carries no `.bi` of its own. Port of
/// `_pgnum_for_bodiless_page`.
///
/// `explicitBreakBI` (planning #228) is the `.pa` block's own index and stands in for
/// "wherever the document's own state was when this page opened" on a confirmed
/// trailing-`.pa` page, which DOES need a number (WS7 stamps one). That case is unchanged.
///
/// A page with NEITHER used to answer a hard `false`, which is not a fallback but a
/// different rule. Planning #274 (2026-09-15): a document that is ALL HEAD AND NO BODY got
/// no number on its one page even though nothing in it ever asked for `.op`, while real
/// WS7 stamps one at the exact row this engine already computes. For such a document the
/// opening state IS the page's state: there is no later block whose `.op`/`.pn`/`.pg`
/// could have been read, so checkpoint 0 is not an approximation, it is the answer.
///
/// THAT IS WHY `bodilessDoc` IS A WHOLE-DOCUMENT TEST and not a per-page one. A page that
/// merely came out EMPTY inside a document that does have blocks — a run of blank lines,
/// `finalizePages` having stripped them — is a different thing: answering it from
/// checkpoint 0 would ignore every command read since, which is exactly the misnumbering
/// the 2026-09-15 research note names. Those pages keep the previous answer.
func pgnumForBodilessPage(_ timeline: Timeline<Bool>, fallbackBi: Int?,
                          bodilessDoc: Bool) -> Bool {
    if let fallbackBi { return timeline.at(fallbackBi) }
    return bodilessDoc ? timeline.at(0) : false
}

/// The baseline y (points) of WordStar's automatic page-number row — the SAME row a
/// `.fo` line 1 rides, `pl - mb + fm` — or nil when the sheet has no such row at all.
/// Port of `_auto_pageno_row_y`.
///
/// ONE DEFINITION, two readers. Printed DRAWS at this y (`resolveHeadFootLines`). Modern
/// only asks whether it is nil, because "the Modern view shows WordStar's automatic page
/// number wherever Printed does" (Jon's ruling M15, 2026-09-15) is a question about
/// WHETHER WordStar numbers this page, never about where Modern then puts it — Modern
/// places it in its own margin model. Deriving that answer twice is how the two views
/// would come to disagree about the same document.
///
/// THE STEP IS A WORDSTAR PAGE LINE, 1/6 IN, NEVER THE DOCUMENT'S `.lh` (planning #274,
/// 2026-09-15). `.pl`/`.mb`/`.fm` count PAGE lines — the fixed 6-LPI grid WordStar
/// measures a sheet in — and this arithmetic used to multiply that count by
/// `printedLead(doc)`, the document's own body leading. The two are the same number for
/// every document that leaves `.lh` alone (the default 8/48in IS 12pt), which is why it
/// went unnoticed; a document that sets `.lh` higher pushed the row down by
/// (lh - 12) x ~60 lines and off the paper entirely, and the number simply vanished.
/// MEASURED against all 212 WS7 captures that print an automatic number: the 1/6in step
/// agrees with 211 of them, the `.lh` step with 200. The one disagreement under either
/// rule is the corpus's own `.pl 0` document, whose behaviour WordStar leaves undefined
/// and which Jon removed from all further work on 2026-09-10 (planning #261).
///
/// THE COUNTS ARE REAL PAGE LINES, never truncated: `.mb 1.8`/`.fm 1.14` are ordinary
/// corpus values and rounding them moves the row by most of an inch.
///
/// nil IS THE `.mb 0` RULE (research 2026-09-15, rule 3: "no bottom margin — there is no
/// footer line on the sheet at all, so there is nowhere to put a number"; in this corpus,
/// label stock, Rolodex cards and mail-merge format files — 24 captures, not one of them
/// numbered). It is TESTED FOR, since 2026-09-15. It used to fall out of the arithmetic
/// instead — MAILLIST/LABELA is `.pl 6 .mb 0 .fm 0` on a 72pt sheet, so the row landed at
/// y = -12 and a blanket "must be on the paper" guard dropped it — and that guard was
/// wrong about the OTHER class it caught. Real WS7 does not clamp the row to the sheet:
/// with `.mb 1.8 .fm 2` on a 66-line page it commands the number 806.4pt from the top of
/// a 792pt sheet, 14.4pt PAST the bottom edge. So the row is returned wherever the
/// arithmetic puts it and the page clips it exactly as the printer does; only a document
/// with NO bottom margin has no row at all.
func autoPagenoRowY(pageHeight: Int, pl: Double, mb: Double, fm: Double,
                    size: Int) -> Double? {
    if mb <= 0 { return nil }
    return Double(pageHeight) - (pl - mb + fm) * Double(PDFMetrics.lead) - Double(size)
}

func resolvedPageHeight(_ doc: Document, printed: Bool) -> Int {
    printed ? resolvedPrintedPageHeight(doc)
        : roundHalfToEven(inchesToPoints(doc.page?.heightIn ?? letterHeightIn))
}

/// Resolved PRINTED-page height, in points. Port of `_resolved_page_height(doc, printed:
/// True)` (pdf.py:42-53) — the printed-mode branch of `resolvedPageHeight` above.
///
/// Honours the file's own `.pl`-derived `heightIn` where the document has one (every
/// `parseWS` document does, resolved with a default when the file never set `.pl`);
/// defaults to 11in (`doc.meta.get('page', {}).get('height_in', 11.0)` in Python) for a bare
/// print-stream capture, which carries no dot commands to resolve page geometry from at
/// all. Clamped to at least `LEAD * (footnoteFloor + 1)` points so a degenerate tiny/absent
/// page can never send the capacity below the floor `_printed_cap` itself also enforces.
func resolvedPrintedPageHeight(_ doc: Document) -> Int {
    guard let page = doc.page else { return printedPageHeightPt(nil) }
    return printedPageHeightPt(page)
}

/// One PAGE GEOMETRY's own printed height in points -- the arithmetic
/// `resolvedPrintedPageHeight` has always done, split out (M31) so a caller holding a
/// single page's resolved sheet (per-page orientation, the layout JSON's `size`) gets the
/// same answer without a whole `Document`. `nil` is the bare print-stream capture's own
/// 11in default. Port of Python's `_page_height_pt_for`.
public func printedPageHeightPt(_ page: PageGeometry?) -> Int {
    let heightIn = page?.heightIn ?? letterHeightIn
    if heightIn == 0 {
        // `.pl 0` = page breaks off (bug 12284; see `textLinesPerPage`). The text model
        // already never breaks; the PDF page box itself falls back to Letter — a truly
        // unbounded page is not expressible in PDF.
        return PDFMetrics.pageHeight
    }
    let floorPoints = PDFMetrics.lead * (footnoteFloor + 1)
    return max(floorPoints, roundHalfToEven(inchesToPoints(heightIn)))
}

/// Printed-mode page capacity, in lines. Port of Python's `_printed_cap` (pdf.py, ctrl-kd
/// 1.3.0) — WordStar's own vertical model, not the fixed-margin arithmetic this used before:
///
/// WS documents (`doc.page` non-nil) get WordStar's own vertical model
/// (`textLinesPerPage`/Python's `_text_lines_per_page`: `.pl - .mt - .mb` at the `.lh` line
/// height — 55 for WordStar's own defaults, NOT the 60 a naive 1in-margin computation gave
/// before this fix). Print streams (`ParsePrintstream.swift`'s `parsePrintstream` — no `page`
/// meta at all) get the SAME model, from WordStar's documented defaults — see the body for
/// why the previous "their margin blanks travel in-band, so give them the full 66" reasoning
/// was retracted.
///
/// Clamped to at least `footnoteFloor + 1` lines either way, so a degenerate/tiny page can
/// never divide the page-bottom math by, or loop over, too little room.
///
/// SECOND KNOWN LIMIT, added with stateful `.lh` (2026-08-05). Capacity is computed at the
/// DOCUMENT-DEFAULT line height — `textLinesPerPage` on `page.lh48`, the file's first `.lh`.
/// A document that changes leading mid-page therefore paginates at a fixed lines-per-page
/// while its lines advance at their own leads, so a page of tightly-led text ends early and a
/// page of banners can run long. Whether WordStar RECOMPUTED lines-per-page as `.lh` changed
/// is UNMEASURED — register open question #15 — and the honest options (recompute per line,
/// or accumulate points until the text height is used up) are different answers to a question
/// no manual page settles. Guessing here would silently repaginate every multi-`.lh` document
/// on an assumption; leaving capacity where the evidence is keeps the change to what was
/// ruled: leads, not pagination.
func printedCap(_ doc: Document) -> Int {
    if let page = doc.page {
        return max(footnoteFloor + 1, page.textLines)
    }
    // PRINT STREAMS GET THE SAME MODEL. Corrected 2026-08-03 (Jon's ruling: "print
    // streams need to follow WordStar standards, not our falsely invented ones").
    // This used to hand a print stream the FULL page height — 66 lines on Letter —
    // justified by the claim that "their margin blanks travel in-band". That claim
    // was checked against raw bytes and is FALSE for real print-to-disk output: such
    // a stream carries no form feeds, and no top margin after its first page. It is
    // not a stack of whole physical pages; it is a run of printed lines. Paginating
    // it at 66 invented a page size WordStar does not document and no evidence
    // supports.
    //
    // So a stream with no page metadata falls back to WordStar's documented defaults,
    // the same as a document that declares none: .pl 66 - .mt 3 - .mb 8 = 55 lines.
    // That is what WordStar 4 itself produces when run (its live output shows 11-line
    // inter-page gaps = .mb 8 + .mt 3, on a 66-line pitch), and it makes the three
    // renderings of one document — the WS4 source, its print stream, and the live
    // program — finally agree at 9 pages, which none of them did before.
    //
    // KNOWN LIMIT, recorded rather than papered over: a print stream that DOES carry
    // its margins in band (WordStar 4's live output does) now gets margin on top of
    // margin. Distinguishing the two cases needs evidence we do not have, and
    // inventing a detector is exactly what this change undoes.
    return max(footnoteFloor + 1,
               textLinesPerPage(pl: defaultPlLines, mt: defaultMtLines,
                                mb: defaultMbLines, lh48: defaultLh48))
}

/// `printedCap`, but for an EXPLICIT (mt, mb) pair instead of the document's global
/// first-occurrence values — Finding 3 (b26-print-fidelity-2)'s per-page capacity; see
/// `mtMbTimeline`. Port of Python's `_printed_cap_for`.
///
/// `doc.page?.textLines` is a value CACHED at parse time from the document's global
/// mt/mb (`ParseWS.swift`'s own `textLinesPerPage` call) — calling that same function
/// directly here, rather than reading the cache, is what makes a page whose (mt, mb)
/// MATCHES the global pair come out byte-identical (same formula, same inputs) while a
/// page that changes them gets its own true capacity.
///
/// NEVER BELOW the document's own global capacity (b26-mtmb-general, LJ6DTP.WS): a
/// mid-document margin change may LOOSEN a page (more room than the document's own
/// declared default) but WS7 does not let one TIGHTEN it. Reconciled from two real WS7
/// captures whose mid-document `.mt`/`.mb` changes point opposite directions:
///   SCRIPT.WS block 64 (`.mt1`/`.mb0`, Figure 1's own tiny margins): local cap 65 >
///     global cap 53 (pl 66 - mt 7 - mb 6, its own `.MT 7`/`.MB 6`) — HONORED. WS7 fits
///     the whole figure on one page (measured: SCRIPT.pcl page count 11, matching only
///     when this local cap is used).
///   LJ6DTP.WS block 12 (`.mt1"`/`.mb1"`, right after the SAME kind of `.pa`-then-
///     margin-restate SCRIPT's own figures use): local cap 46 (pl 66 - mt 6.0 - mb 6.0)
///     < global cap 48 (pl 66 - mt 6.6 - mb 3.0, its own `.mt 1.1"`/`.mb .5"`) — NOT
///     honored. WS7's "Proportional Spacing Tables" section (measured: LJ6DTP.pcl, page
///     7 of 8) prints on ONE page; using the tighter local cap splits it across two, one
///     page too many (9 engine vs WS7's 8).
/// Both obey `cap = max(local, global)` with no exception — the ONE rule shape that
/// fits both real captures pointing opposite ways. Applying the SAME clamp per-field
/// (e.g. only to `.mb`, treating `.mt` differently) was considered and rejected:
/// LJ6DTP's own `.mt` change (6.6 -> 6.0, negligible) can't discriminate between "mb
/// never applies mid-document" and "mb is clamped" from this evidence alone, but "mb
/// never applies" independently FAILS SCRIPT (whose `.mb0` must be honored) while the
/// whole-cap max does not — so the max is the narrower, non-file-specific reading of
/// what's actually measured. The RENDERED override (`Page.mtLines`/`mbLines`, used for
/// the per-page printed-top/running-ops geometry swap) is untouched — only pagination
/// CAPACITY clamps; a document's own declared margin still renders where it says.
/// `plLines` (register b31-dot-command-sweep, `plTimeline`): `.pl` is STATEFUL exactly
/// like `.mt`/`.mb` -- measured against real WS7 (PL_PROBE, dosbox-x): a document holding
/// `.mt`/`.mb` fixed and setting `.pl 20` then `.pl 40` mid-document printed 18 lines on
/// page 1 (cap = 20-1-1) and 38 on page 2 (cap = 40-1-1) -- the SECOND value, not the
/// first, governs the page that follows it. `nil` means "no page-specific override", i.e.
/// use the document's own global first-occurrence `.pl` (every document that never
/// repeats `.pl` mid-document). Port of Python's `_printed_cap_for`.
func printedCapFor(_ doc: Document, mtLines: Double, mbLines: Double, plLines: Double? = nil) -> Int {
    let pl = plLines ?? (doc.page?.plLines ?? defaultPlLines)
    let lh = doc.page?.lh48 ?? defaultLh48
    let local = max(footnoteFloor + 1, textLinesPerPage(pl: pl, mt: mtLines, mb: mbLines, lh48: lh))
    return max(local, printedCap(doc))
}

/// A printed page's own vertical budget IN POINTS -- the real text height
/// `.pl - .mt - .mb` measures on paper, at the 6 LPI grid those three commands are
/// counted on (`PDFMetrics.lead`, 12pt a line), NOT that height re-quantized to a whole
/// number of DEFAULT leads. Port of Python's `pdf._printed_budget_pt`.
///
/// `printedCap` answers a different question -- "how many default-lead lines fit" -- and
/// answering it requires a FLOOR (`textLinesPerPage`'s own `Int(usable * 8 / lh48)`).
/// Spending the floored count back out as `cap * defaultLead` throws away the page's own
/// fractional remainder: up to one default lead of real paper that WordStar does put
/// lines on whenever the lines that land there are SHORTER than the default. Measured
/// against real WS7 (`ws7-prints/v4`, PRISTINE.EXE), on the four documents that pair a
/// fractional-inch `.mt` with an explicit `.lh 14pt` and open with two 12pt lines before
/// that `.lh` takes effect:
///
///   | Doc | `.mt`/`.mb` | usable | cap x 14pt | WS7 | old | new |
///   |---|---|---:|---:|---:|---:|---:|
///   | REF/WINGDING.CHT | 1.6"/.3" | 655.2pt | 644 | 2 + 45 | 2 + 44 | 2 + 45 |
///   | REF/SYMBOL.CHT | 1.2"/.3" | 684.0pt | 672 | 2 + 47 | 2 + 46 | 2 + 47 |
///   | PRINTERS/fontcrib.ws | .4"/.3" | 741.6pt | 728 | 2 + 51 | 2 + 50 | 2 + 51 |
///   | PRINTER.PS | .4"/.3" | 741.6pt | 728 | 2 + 51 | 2 + 50 | 2 + 51 |
///
/// Every one lost EXACTLY one line per page, on every column of every page.
///
/// BYTE-IDENTICAL WHEREVER THE LEAD IS UNIFORM, which is the whole corpus outside those
/// documents: with every line on a page carrying the same lead `L`, `n` lines fit iff
/// `n * L <= usablePt`, i.e. `n <= floor(usablePt / L)` -- and when `L` is the document
/// default that floor IS `cap`, so the answer does not move. The remainder can only ever
/// be spent by a line whose own lead is SMALLER than the default, which is exactly the
/// mixed-`.lh` page this corrects (register open question #15's second half, now
/// measured rather than guessed).
///
/// NEVER BELOW `cap * defaultLead`: `printedCap`/`printedCapFor` carry two rulings that
/// RAISE the line count above what this page's own `.pl/.mt/.mb` would give -- the
/// `footnoteFloor + 1` floor, and b26-mtmb-general's `max(local, global)` (a mid-document
/// margin change may loosen a page, never tighten it). Both are expressed in lines, so
/// they are re-applied here as `cap * defaultLead` and win when they are the larger
/// number; a `.pl 0` document (capacity 10^9, page breaks off) falls out of the same max
/// with no special case.
func printedBudgetPt(_ doc: Document, capacity: Int, defaultLead: Double,
                     mtLines: Double? = nil, mbLines: Double? = nil,
                     plLines: Double? = nil) -> Double {
    let pl = plLines ?? (doc.page?.plLines ?? defaultPlLines)
    let mt = mtLines ?? (doc.page?.mtLines ?? defaultMtLines)
    let mb = mbLines ?? (doc.page?.mbLines ?? defaultMbLines)
    let ruledFloor = Double(capacity) * defaultLead
    let usablePt = (pl - mt - mb) * Double(PDFMetrics.lead)
    if !usablePt.isFinite { return ruledFloor }
    return max(ruledFloor, usablePt)
}

/// `doc` with one page's own stamped geometry (`Page.mtLines`/`mbLines`/`plLines`/`hmLines`/
/// `fmLines`/`orientation`, set by the paginator only where it differs from the document's)
/// applied -- the replacement-geometry copy every per-page consumer (the PDF writer, the
/// head/foot model, the notes area's bottom anchor) reads `printedTop`/`runningOps`/
/// `resolvedPageHeight` through. `nil` when the page stamped nothing: the document's own
/// geometry already is the page's, and the caller keeps using `doc` itself.
///
/// M31: `Page.orientation` is set only when the `.pr or=` in force where the page OPENED
/// differs from `doc.formatting.orientation`, the document-wide value
/// `resolvedGeometryDocument` has already applied (or not applied) to `doc.page`. So a
/// stamped page is always one that must be corrected the OTHER way from the whole document:
/// landscape here means the global swap did not happen and this page needs one; portrait
/// means it did and this page must be put back. `pageGeometryFor` recomputes the pair fresh
/// from `.pl` rather than swapping what it is handed, so both directions are exact.
func pageGeometryDocument(_ doc: Document, for page: Page) -> Document? {
    guard page.mtLines != nil || page.mbLines != nil || page.plLines != nil
        || page.hmLines != nil || page.fmLines != nil || page.orientation != nil,
          var eff = doc.page else { return nil }
    if let mt = page.mtLines { eff.mtLines = mt; eff.mtSource = .file }
    if let mb = page.mbLines { eff.mbLines = mb; eff.mbSource = .file }
    if let pl = page.plLines { eff.plLines = pl }
    if let hm = page.hmLines {
        // `.file` only if THIS page's own resolved hm is a real override of WordStar's
        // hardcoded default, not merely different from the document's (possibly WRONG, in the
        // degenerate mid-document-only-occurrence case) global reading -- `runningOps`'s
        // OR-gate treats hmSource == .file as "the author touched .hm", which must stay false
        // for a page that sits BEFORE a document's only `.hm` ever fires, even though it
        // still needs its own override (back to the true default) to correct
        // `ParseWS.swift`'s global reading.
        eff.hmLines = hm
        eff.hmSource = hm != defaultHmLines ? .file : .default
    }
    if let fm = page.fmLines { eff.fmLines = fm; eff.fmSource = .file }
    if let orientation = page.orientation { eff = pageGeometryFor(eff, orientation: orientation) }
    var pageDoc = doc
    pageDoc.page = eff
    return pageDoc
}

/// The resolved `poCols` for a page of the given parity (planning #231): its OWN
/// parity override if one is in force (`poe`/`poo`, each already `Timeline.at`-resolved or
/// `nil` -- see `parityPoTimeline`), else whatever plain `.po` governs. Brief's own
/// rule: "odd pages use .poo (or .po), even pages .poe (or .po)." Port of ctrl-kd's
/// `_left_for_parity`.
func leftForParity(_ po: Double, _ poe: Double?, _ poo: Double?, isEven: Bool) -> Double {
    isEven ? (poe ?? po) : (poo ?? po)
}

/// For each page, the index of the LAST checkpoint READ on or before it — the one shared
/// walk `resolvePageNumbers` and the automatic-number toggle (`pgnumByPage`) both need,
/// so the two cannot disagree about where a `.pn` was read.
///
/// A checkpoint has been read by the end of a page when the paginator, ON that page, had
/// got past its position. THE POSITION IS THE PAGE'S OWN `readPos` — `(block, how many
/// lines of that block this page had read)` when it closed — and NOT a count taken off
/// the finished pages, because `finalizePages` strips a page's trailing blanks: a page of
/// nothing but blank lines ends up empty, with no `bi` on it at all, which is precisely
/// the shape a leading blank run makes. A page that never got one (a synthetic or
/// degenerate page) inherits the last real position rather than resetting the walk.
///
/// A PAGE WITH NO POSITION AT ALL — not even an inherited one, because no earlier page
/// had one either — FALLS BACK TO THE BLOCK-RANGE RULE, the granularity this walk
/// replaced on 2026-09-14: the last checkpoint whose block index is at or before the
/// highest block index this page carries. Leaving it on the seeded checkpoint 0 instead
/// silently answered "the document's opening default" for a page that plainly reads
/// further in, and the document's own `.op` was never consulted: `LYING.WS` numbered all
/// three of its pages where real WordStar 7 numbers none of them, because the footnote
/// paginator set no `readPos` and LYING's `.op` is checkpoint 1 (research: "Why real WS7
/// prints no page number on some documents", 2026-09-15). Never moves BACKWARD — the
/// walk's consumers (`resolvePageNumbers`' re-anchor test) read a falling index as a new
/// anchor.
///
/// Checkpoints are ascending, so the first one this page has not reached stops the walk:
/// nothing after it can have been reached either. Port of `_checkpoints_by_page`.
func checkpointsByPage(_ positions: [(blockIndex: Int, lineIndex: Int)],
                       _ pages: [Page]) -> [Int] {
    var out: [Int] = []
    var last = 0
    var pos: PageReadPos?
    for pg in pages {
        if let p = pg.readPos { pos = p }
        if let pos {
            var idx = last + 1
            while idx < positions.count {
                let cp = positions[idx]
                if !(cp.blockIndex < pos.bi
                     || (cp.blockIndex == pos.bi && cp.lineIndex < pos.count)) { break }
                last = idx
                idx += 1
            }
        } else {
            last = max(last, checkpointByBlock(positions, pg))
        }
        out.append(last)
    }
    return out
}

/// The BLOCK-RANGE answer for one page: the index of the last checkpoint whose block
/// index is at or before the highest block index the page carries — `Timeline.at`'s own
/// "last checkpoint at or before this block wins" contract, as an index rather than a
/// value so the positional walk above can keep using it as a floor.
///
/// A page carrying no `bi` at all (nothing but emitter-made lines — a footnote-area-only
/// page, a blank page whose trailing blanks were stripped) has no block range to test, so
/// it keeps whatever the walk already had. Port of `_checkpoint_by_block`.
func checkpointByBlock(_ positions: [(blockIndex: Int, lineIndex: Int)],
                       _ pg: Page) -> Int {
    var top: Int?
    for ln in pg {
        if let bi = ln.bi, top == nil || bi > top! { top = bi }
    }
    guard let top else { return 0 }
    var last = 0
    var idx = 1
    while idx < positions.count {
        if positions[idx].blockIndex > top { break }
        last = idx
        idx += 1
    }
    return last
}

/// `[pageNumber, ...]`, one per `pages` (ascending, from `docToPagelines`) -- walks the
/// pages in order, re-anchoring to a `.pn` checkpoint's own value on whichever page its
/// block index first lands on (WordStar's own "sets the number of the page it appears
/// on"), otherwise continuing the previous page's number by one. A page with no
/// `bi`-carrying line at all (should not happen for real content, but a synthetic/
/// degenerate page is handled rather than crashed on) just continues the count. Port of
/// Python's `_resolve_page_numbers`.
///
/// A checkpoint is consumed (matched to a page) at most once, by the FIRST page whose own
/// block range reaches it -- `appliedBi` tracks the highest checkpoint block index already
/// used, so a checkpoint sitting mid-page is applied to THAT page (not the next one) and
/// never re-applied to a later page that also happens to satisfy `cp.blockIndex <=
/// pageMaxBi`.
func resolvePageNumbers(_ timeline: Timeline<Int>, _ pages: [Page]) -> [Int] {
    var numbers: [Int] = []
    var current: Int?
    var previous = -1
    let byPage = checkpointsByPage(timeline.positions, pages)
    for idx in byPage {
        if current == nil || idx > previous {
            current = timeline.entries[idx].value      // re-anchored on this page
        } else {
            current! += 1
        }
        previous = idx
        numbers.append(current!)
    }
    return numbers
}

/// Whether the automatic page number is ON, per page — the positional twin of `Timeline.at`
/// (triage Q12, probes 2026-09-14). `.pn`/`.pg` turn it on and `.op` turns it off, and
/// WHERE each one is read is the same question `resolvePageNumbers` asks, so it is the
/// same walk: `checkpointsByPage`. Read at block granularity, `-HOLYMAC.WS`'s second
/// `.pn0` — which sits immediately after "Charles Maher", the last line page 1 has room
/// for — turned numbering back on ON page 1 and printed a `0` real WS7 does not print.
func pgnumByPage(_ timeline: Timeline<Bool>, _ pages: [Page]) -> [Bool] {
    checkpointsByPage(timeline.positions, pages).map { timeline.entries[$0].value }
}

/// Measured (dosbox-x, register b31, E3 item 2, 2026-08-25): the automatic page
/// number's LEFT edge sits at column `(poCols + pcCol - 1)` in the SAME 10-CPI frame
/// `.po`/`.lm`/`.rm`/`.pm` share (`pdfPtPerCol`), regardless of how many digits the
/// number itself has (a 3-digit number landed at the IDENTICAL x as a 1-digit one at
/// the same `.pc`/`.po` pair -- LEFT-anchored, not right-anchored or centred on the
/// string itself). Confirmed relative to `.po`, not absolute from the page edge: two
/// independent `.po` values both fit the SAME formula exactly once `.po` is added in; a
/// plain `N * 7.2pt` (ignoring `.po`) does not.
///
/// `.pc 0` (WSFORMAT.WS's own text: "If the column specified is 0, then the page
/// number is centered between the margins in effect") and `.pc` NEVER DECLARED AT ALL
/// produced the IDENTICAL position in every probe -- "unset" and "0" are the SAME
/// internal state. But the manual's own "centered between the margins" claim does NOT
/// hold in this install/driver as measured: `.rm 40` with `.pc 0` landed at the
/// IDENTICAL x as `.pc 0` at this install's own default `.rm` -- no dependency on `.rm`
/// at all, twice confirmed. Measured bytes beat manual prose (`printedLeft`'s own
/// precedent, same doctrine): the "0/unset" case resolves to this FIXED measured
/// column instead of a dynamically computed lm/rm midpoint. Fit from two independent
/// `.po` values (7.0 exactly, 20.0 exactly) with zero decipoint residual either way --
/// not a guess, and not (yet) traced to a WSCHANGE factory constant, so it may be THIS
/// install's own customisation the same way its `.po` 7.0 (vs the manual's 8.0) is;
/// flagged, not hidden.
///
/// THE DEFAULT IS AN ERA FIELD (`Era.pcDefault`): 33.5 above is WS7's, and WS4's
/// automatic number line is `(PC - 1)` spaces then `#` with the factory `.PC` 28, counted
/// from `.po` (WS4 teardown, `wordstar4-dos/4-formatting-printing.md` 3.2; runs x41-*,
/// p12-hepk, dt1), so a WS4 document's number starts at column 28.

/// Left edge (points) of the automatic page number's text, from `.po`/`.pc` -- see
/// the comment above for the formula's own measurement. `pcCol` 0 or unset (both measured
/// identical) uses the era's `pcDefault`; an explicit non-zero `.pc N` overrides it.
///
/// `poCols` IS THIS PAGE'S OWN PRINT OFFSET, and the document's default is only the
/// fallback for a caller with no page in hand. The number rides the running foot's own
/// left origin -- the same `.po`/`.poe`/`.poo` state `emitPDF`'s per-page `pageLeft`
/// resolves -- never the document's opening `.po`. Reading the document default here put
/// the number at the WRONG COLUMN on every page whose own offset differs, which this
/// corpus produces three separate ways, all measured against real WS7:
///
///   * `.poe`/`.poo` (an even/odd offset pair). `sawyer/REF/ADVANCE.DOT` `.poo 5.6"` ->
///     637.2pt, `GALLEYS.DOT` `.poo 5.8125"` -> 652.3pt (predicted 652.5, a 2-decipoint
///     driver residual -- its own running head carries the same 0.2pt),
///     `REF/BOOKLET.HOW` 644.4pt odd / 248.4pt even, `REF/BOOKLET.RJS` and its
///     byte-identical twin `REF/-HOW-TO.RJS` 651.6pt odd / 255.6pt even -- every one
///     EXACTLY `(po + pc - 1) * 7.2` once the page's own parity offset is used. This
///     engine drew all five at 291.6pt, the Letter-portrait `.po 8` default. All five
///     are also `.pr or=l` landscape, which is a coincidence of who in this corpus uses
///     `.poe`/`.poo` and NOT part of the rule: the number is not centred on the sheet,
///     and nothing about it reads the sheet's width.
///   * a MID-DOCUMENT `.po`. `sawyer/REF/FONTS.REF` alternates `.po.2i`/`.po.7i`: WS7
///     numbers its pages 248.4 / 284.4 / 248.4 / 284.4... page by page, while the
///     document default (`.po.2i`) alone gives 248.4 throughout.
///   * a `.po` the document's OPENING state never sees at all. `sawyer/REF/REFORM.DOT`'s
///     own `.po 1i` lands past block 0, so the document default stays at WordStar's
///     `.po 8`; WS7 numbers its one page at 306.0pt, which is `.po 1i` = 10 columns.
///
/// Port of ctrl-kd's `_auto_pageno_x_pt`.
func autoPageNumberXPt(_ doc: Document, poCols: Double? = nil) -> Double {
    let po = poCols ?? doc.page?.poCols ?? defaultPoCols
    let pcRaw = doc.page?.pcCol
    let pc = (pcRaw != nil && pcRaw != 0) ? Double(pcRaw!)
        : printingEra(doc).pcDefault
    return (po + pc - 1) * pdfPtPerCol
}

/// Top-of-text offset in points for printed mode: the bottom edge of WS7's reserved
/// TOP-MARGIN zone (`.mt`, lines at 6 LPI -> 12pt each; the default `.mt 3` = 36pt). Print
/// streams (no `page` meta) keep the fixed 36pt — their own top-margin blanks are in the
/// data (minus the machine-margin strip in `docToPagelines`). Clamped inside the page so
/// garbage `.mt` from a misdetected binary degrades to an ugly page, never an absurd
/// coordinate space. Deliberately measured against the FIXED `PDFMetrics.lead` (not
/// `printedLead(doc)`) — this is a page-geometry clamp, not a
/// line-spacing one.
///
/// Mechanism U (ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round,
/// commit 26169cd): `.hm` is NEVER added on top of `.mt`, matching the WS7 manual's own
/// dot-command reference (already quoted in this codebase for the symmetric `.mb`/`.fm`
/// case). This function used to add `.hm` (2 lines, 24pt) whenever `.mt` was left at its
/// document default — see the "INCLUDES `.hm`" history below, all of it measured ONLY
/// against `ws7-prints/v1`/`v2`, both captured through Robert J. Sawyer's own
/// WSCHANGE-customized `WS.EXE` (the SAME install mechanisms S and T already found
/// responsible for the `.po` and auto-leading contaminations). A `PRISTINE.EXE` (factory,
/// no WSCHANGE) recapture of 5 default-`.mt` documents (OCAPTAIN/BOXES/SAWYER/LYING/
/// WARPRAYR) settles it: every one measures its first real content line at EXACTLY `.mt`
/// alone (36pt) + that line's own entering lead, zero residual — 36 (`.mt` alone) + 12
/// (OCAPTAIN/BOXES/SAWYER's own 12pt entering lead) = 48.0pt exactly; 36 + 16 (LYING/
/// WARPRAYR's 16pt Title style, at `AUTO_LEAD_FACTOR` 1.0) = 52.0pt exactly. `ws7-prints/v1`'s
/// uniform ~24-27pt EXTRA gap on the SAME 5 documents is Sawyer's own `.hm`-adds-to-`.mt`
/// customization, not stock WS7's — invisible to this codebase's own `pcl` tier verdicts
/// because it is a UNIFORM per-page offset that a per-page median-dy calibration silently
/// absorbs, the same masking mechanism already named for `.po`, now confirmed on the
/// vertical axis too.
///
/// ---- history below, superseded by the above ----
///
/// NO LONGER SPECIAL-CASED FOR HEADERED DOCUMENTS (round 26 wave 3, ctrl-kd's
/// `fidelity_gate.py` Finding A — reversing the headerless scoping this function used to
/// carry). A genuine WS7 capture WITH a real `.h1` header (-README, ws7-prints/v1) contradicts
/// the WS4-era reading this function's SCOPED TO HEADERLESS DOCUMENTS reasoning rested on:
/// -README's OWN header prints starting page 2 (page 1 has none — WordStar suppresses a
/// running head on the document's first page) at PCL baseline y=35.7pt (`.mt` alone, matching
/// `runningOps`'s OWN placement, unaffected by this function), but the BODY text on those SAME
/// headered pages starts at y=71.7pt — byte-for-byte the SAME offset the headerless corpus
/// measures ((.mt 3 + .hm 2)*12 + 12pt baseline = 72pt, 0.3pt residual). Mechanism U (above)
/// now confirms the ORIGINAL WS4-era reading was right about STOCK WS7 all along — `.hm` is
/// always within `.mt`, headered document or not — and -README's own body-vs-header split
/// (used at the time to argue the opposite) was itself measuring the Sawyer-install `.hm`
/// contamination on the BODY side while its header (`runningOps`, a separate computation)
/// happened to stay correct.
///
/// PREVIEW.WS (ws7-prints/v1) is unaffected by this change either way: it declares its OWN
/// `.mt` explicitly (`mtSource == .file`, 4.98 lines — a WSFORMAT-style non-integer `.mt`,
/// likely typed as a decimal inch value), and both its `ws7-prints/v1` and `v3` captures
/// already match `.mt` ALONE (round(4.98*12)=60, +12+12 for this headerless document's own
/// two leading blank lines at `AUTO_LEAD_FACTOR` 1.0 = 84pt vs the `v3` measured 83.7pt,
/// 0.3pt residual — the same decipoint-rounding gap every other oracle here shows).
///
/// WSCHANGE's factory-defaults table (Installing and Customizing, WS7 manual, p.2-46/2-45)
/// independently confirms the `.mt` default used here: "Top margin ... 0.50"". Port of
/// Python's `_printed_top` (pdf.py, ctrl-kd 2.0.0/round 26 wave 3, refined same day on
/// PREVIEW.WS evidence, and again by mechanism U, commit 26169cd).
func printedTop(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.topPrinted }
    let pageHeight = resolvedPrintedPageHeight(doc)
    let reserve = page.mtLines
    return max(0, min(roundHalfToEven(reserve * 12), pageHeight - PDFMetrics.lead))
}

/// Bottom-of-page reserve for `layoutPrintedPages`'s FOOTNOTE area (never the endnote
/// continuation — endnotes are never queued through this function's own pagination, they
/// simply continue this area's sequential flow and inherit its position for free), in
/// points — Finding 2 (b26-print-fidelity-2). Port of Python's `_printed_notes_reserve_pt`.
///
/// The area used to be flow-appended right after the body (whatever y the body happened to
/// end at), correct only when the body already fills the page (LYING.WS, every page) — on a
/// short page (-SCREEN.WS, a 1-page doc whose body ends mid-page) that put the area
/// mid-page, colliding with the WORDSTAR.PIX image; real WS7 prints it at the physical
/// bottom.
///
/// Originally measured against TWO WS7 captures (ws7-prints/v1), both at every
/// page-geometry default (`.mb` 8 lines): -SCREEN.pcl's footnote line "1. Footnote" at
/// y=708pt (dash rule at 684pt) and LYING.pcl's "1.Did not take the prize." also at y=708pt
/// (dash rule also 684pt — LYING's page is full, so its flow-appended position and this
/// anchor coincide). Both landed on 84pt = (`.mb` - 1) * 12 = 7 lines, alongside a
/// (since-fixed) 3-line header model (`areaSize`/`renderArea`) that inserted an extra
/// leading blank neither real capture ever printed.
///
/// Mechanism U (ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round,
/// commit 26169cd, same install already found responsible for the `.po`/leading/top-margin
/// contaminations — mechanisms S, T, and this function's own sibling `printedTop`).
/// Re-deriving BOTH real captures from scratch with the header-count fix landed (2 lines:
/// rule then blank, not 3):
///
/// -SCREEN (`ws7-prints/v1`, Sawyer): a genuinely SHORT page, so this anchor's own reserve
/// governs directly. Solving with the 2-line header: reserve = 96.0pt = `.mb * 12` EXACTLY
/// (8 lines, no adjustment at all) — zero residual. The old `-1` was compensating for the
/// wrong (3-line) header model, not a real per-install customization.
///
/// LYING (`ws7-prints/v3`, pristine): a FULL page, so this document's own natural
/// (un-anchored) flow places it — once `printedTop`'s fix lands, the body's last real
/// content line plus the 2-line header's 24pt plus the text's own 12pt entering lead
/// matches pristine's real measurement with ZERO residual via PURE SEQUENTIAL FLOW; this
/// document's own oracle only bounds the reserve from BELOW (`reserve >= 120`, its own
/// 3-line area).
///
/// So: `-SCREEN` (Sawyer) needs EXACTLY 96pt (`.mb * 12`); `LYING` (pristine) needs AT
/// LEAST 120pt (`(.mb + 2) * 12`) to avoid wrongly overriding its own already-correct
/// natural position — but see the 2026-09-07 correction below: that `>= 120` bound itself
/// carried a 12pt derivation error, and the real value is 108pt.
///
/// 2026-09-07 correction (ctrl-kd commit 135a14a, `-SCREEN` recapture): the reasoning
/// above compared `target_first` against `natural_y` (648, LYING's own last BODY CONTENT
/// line) instead of the code's actual comparison point, `bodyY` (`648 + 12 = 660`, the
/// position of the NEXT line after the body — what `layoutPrintedPages`'s own override
/// arithmetic uses). That is a 12pt/one-line error in the DERIVATION, not in the code's
/// own arithmetic, and it inflated the reserve requirement to `>= 120` when the code's
/// real gate only requires `>= 108`.
///
/// The error was invisible until now because -SCREEN's own footnote/endnote block was
/// believed genuinely ABSENT from the `ws7-prints/v3` PRISTINE.EXE capture (that corpus's
/// own README finding #3) — it was actually just TRUNCATED at the document's embedded
/// Inset picture (corpus commit 2be7569, 2026-09-06), so -SCREEN could never corroborate
/// or refute this constant either way until the recapture. The complete capture measures:
/// dash rule at V=660.0pt, footnote line ("1." then, tab-separated, "Footnote") at
/// V=684.0pt, endnote line ("(1)" then "Endnote") at V=708.0pt. -SCREEN's body ends at
/// V=434.1pt — nowhere near the anchor — so, being a genuinely short page, this anchor
/// governs the reserve DIRECTLY (not just a lower bound, unlike LYING): solving
/// `792 - reserve - (areaLen-1)*12 = 660` with `areaLen=3` (rule, blank, text) gives
/// `reserve = 108.0pt = (.mb + 1) * 12`, not `120pt = (.mb + defaultHmLines) * 12`.
///
/// Re-checked against LYING with `reserve = 108`: `override = targetFirst - bodyY =
/// (792 - 108 - 24) - 660 = 0`, and the code's own gate is `if override > 0`, so `0`
/// still does NOT engage the anchor — LYING's already-correct pure-sequential-flow
/// position (684.0pt, matching pristine with zero residual) is completely undisturbed.
/// So `108` is not a compromise between two installs' needs; it is the exact value both
/// real stock captures independently agree on: `-SCREEN` governs it directly (short
/// page), LYING is consistent with it as a boundary case (full page, override lands at
/// exactly 0 rather than needing to stay strictly negative).
///
/// CONFIRMED under stock, n=2 (`-SCREEN` direct + `LYING` boundary-consistent),
/// superseding the prior n=1 judgment call: `108pt = (.mb + 1) * 12`, not
/// `(.mb + defaultHmLines) * 12`. The `.hm`-symmetry reading that motivated `+2` doesn't
/// hold; the footnote area's real cushion above the physical bottom margin is one line,
/// not `defaultHmLines` lines — `printedTop`'s own `.hm` finding (top of page) and this
/// reserve (bottom of page) are NOT mirror images after all, contra the earlier note here.
/// Port of Python's `_printed_notes_reserve_pt` (ctrl-kd commit 135a14a).
func printedNotesReservePt(_ doc: Document) -> Double {
    guard let page = doc.page else { return 108.0 }  // print streams: no `.mb` to read;
                                                      // the measured default constant
    return max(0.0, (page.mbLines + 1) * 12.0)
}

/// Baseline-to-baseline distance in points for printed mode. Port of Python's
/// `_printed_lead` (pdf.py, ctrl-kd 1.3.0): `.lh` is 1/48in units, a point is 1/72in ->
/// `lh48 * 1.5`. Default `.lh 8` IS the 12pt lead this emitter always used. Print streams
/// (no `page` meta) keep the fixed lead.
/// Only the DEFAULT: `.lh` is stateful and a line that was set at a different leading carries
/// its own (`Line.lead48` -> `PageLine.lead`), which `pageStream` honours per line. This is
/// what a line WITHOUT one falls back to, and what page CAPACITY is still computed at (see
/// `printedCap`).
func printedLead(_ doc: Document) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.lead) }
    return leadPt(page.lh48) ?? Double(PDFMetrics.lead)
}

/// The `.sr` sub/superscript roll for printed mode, in points — ONE document-wide value
/// (b24 round 17, RULINGS-LEDGER row 3, register C22). Port of Python's `_printed_roll_pt`.
/// Not stateful per-line like `.lh`: `.sr` re-selects mid-document have no evidence behind
/// per-position tracking the way `.lh`'s own archive banner example does — the ruling
/// itself only asks that the file's OWN roll finally be read at all (previously byte-
/// identical across `.sr 0`/`.sr 40`/absent). Default 3 (WSFORMAT's own stated `.sr`
/// default, 3/48in) whenever the file never sets it, converted the same way every other
/// 1/48in value is (round 6: 1/48in = 1.5pt).
func printedRollPt(_ doc: Document) -> Double {
    (doc.formatting.subSuperRoll48 ?? 3.0) * 1.5
}

/// Print columns (10 CPI) -> points: 72pt/in / 10 col/in = 7.2pt/col — the SAME unit
/// `.lm`/`.rm`/`.pm`/`.po` all share, and the exact value `MAX_COLS`'s own line-wrap math
/// already derives from (size 12 * 0.6 == 7.2 at the default size).
let pdfPtPerCol = 7.2

/// planning #257 (sawyer/REF/-HOW-TO.RJS pages 10-12): a typed leading-space run
/// before proportional text with NO `.pm` backing it (`lineOpsPrinted`'s own
/// `pmActive`/`columnIndent`) still needs its OWN width — not `pdfPtPerCol` (that
/// branch is for a `.pm`-governed run, WARPRAYR), and not this Base14 Helvetica
/// substitute's own AFM space glyph either (0.278em — correct for an ORDINARY
/// inter-word space inside running text, measured: "PRINTING UNBOUND"'s own single
/// space landed within 0.1pt of it — but too narrow for a run of many consecutive
/// typed ones). MEASURED directly against two independent blocks of the same real
/// WS7 capture (ws7-prints/v4/sawyer__REF__-HOW-TO_EXT_RJS.pcl, both Univers/Helv
/// 10pt, `.pm 0"` in force): the banner heading's 20/22/18/30-space lines (left
/// 21.6pt, WS7 x 88.8/95.5/82.0/122.4) and the later `IfException` block's 12-space
/// lines (left 417.6pt, WS7 x 457.9) both solve to the SAME flat 0.336em/pt ratio to
/// within 0.1pt (decipoint rounding) — e.g. 21.6 + 20*3.36 = 88.8 exactly, 417.6 +
/// 12*3.36 = 457.92 vs 457.9. Applied UNSCALED (no `faceTz` factor: that scale lands
/// the face's AVERAGE character on its own HMI grid, and a space is not average —
/// scaling it the same amount overshot every one of these lines). Untested outside
/// a Helv/Univers substitution — no other proportional face types a literal indent
/// with no `.pm` anywhere in the current corpus. Port of ctrl-kd's
/// `_TYPED_INDENT_SPACE_EM`.
///
/// `public` so a consumer that must reproduce this measure — Soft Return.app's own Printed
/// facsimile, whose leading-indent run has to land where this puts it — reads the number
/// rather than keeping a second copy of it, the same reason `graphicChars` and
/// `symbolReverse` are public.
public let typedIndentSpaceEM = 0.336

/// First-line indent in points from `.pm` — b24 round 17 (RULINGS-LEDGER row 5/7), also
/// the source of Printed RTF's `\fi`, relative to li=0: Printed PDF has no per-block `.lm`/`.rm`
/// margin of its own yet (that gap is Printed RTF's own ledger row 8, a SEPARATE item),
/// so the baseline this indent sits against is the document's own left edge — the same
/// li=0 an unstyled/WS4 Printed RTF paragraph already gets from the SAME round 6 code.
/// `nil` when the block never set `.pm`. Port of Python's `_printed_pm_fi_pt`.
///
/// The rule itself — `.pm`'s absolute column, reduced by whatever the author already
/// typed, clamped at zero — is `pmFirstLineIndentCols` (EmitterRules.swift), where
/// planning #264 item 2 moved it so Printed RTF asks the same question. Its doc comment
/// carries the WARPRAYR.WS (planning #202) and -HOW-TO.RJS (planning #257) evidence.
/// This function is only that answer in points.
///
/// `.pf` GATE (planning #270 item 39 / triage Q6, 2026-09-14; port of ctrl-kd). A
/// paragraph margin reaches the PRINTED page only through print-time realignment.
/// MicroPro's own file-format reference says so in one sentence — `.PF`: "When OFF,
/// paragraphs are not realigned... Paragraphs are aligned using the left, right, and
/// paragraph margins currently in effect" — and the corpus agrees: with realignment off
/// WordStar prints the stored physical lines verbatim, whatever indentation the author
/// typed included, and `.lm`/`.rm`/`.pm` are EDIT-time state that already spent itself
/// at typing time (which is exactly why this module has never applied `.lm` to a
/// printed line either).
///
/// MEASURED, `sawyer/MACROS/HOLYMAC/-HOLYMAC.WS` (v4 PRISTINE capture, no `.pf`
/// anywhere in the file, `.pm4` in force): its pages 223, 258 and 293 each open with a
/// line real WS7 prints at the plain left edge (x 72.0pt, and 77.5pt for the page-293
/// footnote's own superscript) while this engine indented all three by `.pm`'s 3
/// columns, +21.60pt, 16 divergences. Every other `.pm`-bearing block in the HOLYMAC
/// set (`7MAC1`/`7MAC2`/`7MAC3`, clean) opens on a BLANK line, so the indent never
/// showed and none of them was evidence either way. No document in the corpus prints a
/// `.pm` first-line indent with `.pf` off. `dis` is treated as not-on: it realigns only
/// when merge data is substituted, which never happens here.
func printedPMFiPt(_ block: Block) -> Double? {
    guard block.printReformat == "on" else { return nil }
    guard let cols = pmFirstLineIndentCols(block) else { return nil }
    return cols * pdfPtPerCol
}

/// `(sb, sa)` in points from WordTsar's own `.psa`/`.psb` extensions — b24 round 17
/// (RULINGS-LEDGER row 5/7), mirrors `rtfDocSpacingTwips` (round 6) exactly, converted to
/// points via the document's own DEFAULT leading (the same quantity `PageLine.lead`
/// already carries) instead of twips. `(nil, nil)` when neither command was ever seen.
/// Port of Python's `_printed_doc_spacing_pt`.
func printedDocSpacingPt(_ doc: Document) -> (sb: Double?, sa: Double?) {
    guard doc.spaceBeforeLines != nil || doc.spaceAfterLines != nil else { return (nil, nil) }
    let leadPt = printedLead(doc)
    let sb = doc.spaceBeforeLines.map { $0 * leadPt }
    let sa = doc.spaceAfterLines.map { $0 * leadPt }
    return (sb, sa)
}

/// Type size in points for printed mode, from `.cw`: character width in 1/120in units,
/// and Courier advances 0.6em, so a pitch of cw/120in per character IS a
/// `(cw*72/120)/0.6 = cw*1.0` point font. The default `.cw 12` (10 CPI pica) IS the 12pt
/// this emitter always used; `.cw 10` is 12 CPI elite at 10pt. Rounded to whole points
/// (the `Tf` operator is written as an integer, as it always has been), floored at 1.
/// Print streams keep the fixed `SIZE`. Port of Python's `_printed_size` (pdf.py, ctrl-kd
/// 2.0.0).
public func printedSize(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.size }
    let cw = page.cw120
    return cw > 0 ? max(1, roundHalfToEven(cw)) : PDFMetrics.size
}

/// Left edge of text in points for printed mode, from `.po`: "the number of print
/// columns from the left edge of the paper to the left margin of text. The current
/// setting of character width (.CW) determines the actual amount of indentation" — but
/// real WS7 output contradicts that clause: PCL captures keep `.po` at a FIXED
/// 7.2pt/column at BOTH 10cpi and 12cpi (dx experiment 2026-08-20: ESC&aH = 576dp for
/// `.po 8` at either pitch), matching `pdfPtPerCol` exactly as `.lm`/`.rm`/`.pm` already
/// do. Measured bytes beat manual prose. The default `.po 8` (the WS7 manual's ".8 inch"
/// at 10 CPI) lands at 57.6pt — NOT the old fixed 72pt `MARGIN`, which was this emitter's
/// guess, not WordStar's. Print streams keep `MARGIN`: their offset spaces, where a
/// driver emitted them, are in-band. Clamped inside the page for garbage `.po` from
/// misdetected binaries. Port of Python's `_printed_left` (pdf.py, ctrl-kd 2.0.0).
///
/// This is the DOCUMENT DEFAULT — the file's first `.po`, exactly like `printedLead`'s
/// document default. A line whose own `.po` differs (`Line.poCols`, register b31 —
/// LJ6DTP.WS moves `.po` to 2.5" for its page-4 checkerboard) overrides this at layout
/// time in `resolvePrintedBody` (`PageLine.left`), the same `.lh`-
/// stateful shape `PageLine.lead` already carries.
func printedLeft(_ doc: Document, size: Int) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.margin) }
    return resolveLeftPt(page.poCols, size: size)
}

/// `.po` print columns -> left edge in points, clamped inside the page — the conversion
/// `printedLeft` (the document DEFAULT) and a line's own override (`Line.poCols`, stateful
/// like `.lh`; register b31) both need, factored out so a line that never overrides `.po`
/// resolves IDENTICALLY to the document default it would otherwise have inherited. Port of
/// Python's `_resolve_left_pt`.
func resolveLeftPt(_ poCols: Double, size: Int) -> Double {
    let left = poCols * pdfPtPerCol
    return max(0.0, min(left, Double(PDFMetrics.pageWidth) - Double(size) * 0.6))
}

/// The LaserJet's logical page, in 300-dpi dots from the paper's side edge (HP PCL 5
/// Technical Reference, tables 2-1 and 2-2): every PCL x WordStar sends is measured from
/// it, not from the paper (WS7 report 7.4). A4 and the metric sizes sit a little closer to
/// the edge than Letter, Legal and Executive; landscape closer still. Port of Python's
/// `_PCL_LOGICAL_PAGE_DOTS`.
private func pclLogicalPageDots(_ orientation: Orientation, a4: Bool) -> Int {
    switch orientation {
    case .portrait: return a4 ? 71 : 75
    case .landscape: return a4 ? 59 : 60
    }
}

/// Where a Printed page's x = 0 sits on the paper, in points: Printed lays a page out in
/// the printer's own frame, the PCL logical page, and the page is placed on the sheet this
/// far in from its left edge. Every x the page model carries (`PageLine.left`, the running
/// lines, the automatic page number) is in that frame; a view drawing on the sheet adds
/// this. `orientation` is the page's own (`printedPageOrientation`): a `.pl` shorter than
/// the sheet is wide is still portrait paper. A print stream carries its own offset
/// in-band, so it is placed at the edge (0). Port of Python's `logical_page_x`.
public func logicalPageX(_ doc: Document, orientation: Orientation, sheetWidth: Int) -> Double {
    if doc.detection?.variant == .printstream { return 0.0 }
    let a4 = sheetWidth == 595 || sheetWidth == 842       // A4 portrait, A4 landscape
    return Double(pclLogicalPageDots(orientation, a4: a4)) * 72.0 / 300.0
}

/// The orientation a Printed page was opened in: its own `.pr or=`, else the
/// document's. Port of Python's `_page_orientation`.
public func printedPageOrientation(_ doc: Document, _ page: Page?) -> Orientation {
    page?.orientation ?? doc.formatting.orientation ?? .portrait
}

/// A page's content stream moved `x` points right on the sheet. Port of Python's
/// `_place_on_sheet`.
func placeOnSheet(_ stream: [UInt8], x: Double) -> [UInt8] {
    if x == 0 { return stream }
    let x2 = Double(hundredths(x)) / 100.0
    return Array("q 1 0 0 1 \(tfSize(x2)) 0 cm\n".utf8) + stream + Array("\nQ".utf8)
}
