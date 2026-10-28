/// A printed body line's own leading, resolved the one way every printed-body walk
/// resolves it.
///
/// The walks that need it (`resolvePrintedBody` for both paginators, and
/// `resolvedPrintedLeads48`, which reports the same answer per block for the layout JSON)
/// used to carry a private copy of this chain each, together with the three variables that
/// drive its last step. The precedence, strongest first:
///
/// 1. a block's own paragraph-style leading (`styleLeadPt`), which governs OUTRIGHT: a
///    stale, document-wide `.lh` must never outrank the style the block actually carries
///    (planning #256, `-HOW-TO.RJS`). A blank line takes the raw value (nothing to clip, so
///    the entering-line floor does not apply), a block's first real line takes
///    `enteringLeadPt`'s floor against the previous block, any other real line the plain
///    fallback-eligible value (Fix C, b26-print-fidelity-2);
/// 2. the line's own carried `.lh` (`Line.lead48`);
/// 3. for a WS5+ font-block document with no `.lh` of its own, the font block in force
///    (`fontLeadPt`, round 26 wave 3, fidelity_gate.py Finding B).
///
/// `nil` means "the document default applies".
///
/// The font-block state is carried across every physical line of the document in source
/// order, blank lines and non-first real lines included, even where only one resolved value
/// per block is kept: an inline font change inside a later line must still update the
/// carried size, or a later block's first line would resolve against a stale one.
struct LineLeading {
    private let doc: Document
    /// Whether the font-block rule is live at all: some block asks for auto leading and the
    /// file never set a numeric `.lh` (the same `lhSource` guard `styleLeadPt` applies).
    private let fontLeadOk: Bool
    private let fontLeadBase: Double
    private var fontLeadState: Double?
    /// How far the line `lead(of:)` last resolved stands above the base line, in points,
    /// when its lead came from the fonts on it (`.lh a`); `nil` otherwise. The paginator
    /// lets such a line overhang the bottom by that rise (`PageLine.fontRise`).
    private(set) var fontRise: Double?

    init(_ doc: Document) {
        self.doc = doc
        fontLeadOk = doc.blocks.contains { $0.lhAuto } && doc.page?.lhSource != .file
        fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
        fontLeadState = nil
    }

    /// `isFirstLine`: `line` is the first line of `block` that the caller counts as its
    /// entering line. `prevParaBlock`: the nearest earlier `.para` block (skipping page
    /// and column sentinels), `enteringLeadPt`'s "outgoing" reference.
    mutating func lead(of line: Line, in block: Block, isBlank: Bool, isFirstLine: Bool,
                       prevParaBlock: Block?) -> Double? {
        var ownLead = leadPt(line.lead48)
        let styleLead: Double?
        if isBlank {
            styleLead = styleLeadPt(block, doc, raw: true)
        } else if isFirstLine {
            styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
        } else {
            styleLead = styleLeadPt(block, doc)
        }
        if let styleLead {
            ownLead = styleLead
        }
        fontRise = nil
        if ownLead == nil, fontLeadOk, block.lhAuto {
            let lead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                  state: &fontLeadState)
            ownLead = lead
            fontRise = max(0.0, lead - printedLead(doc))
        }
        return ownLead
    }
}

/// One `.lh` value (1/48in units) as points: a point is 1/72in, so `lh * 1.5`. `nil` or
/// non-positive -> `nil`, meaning "no answer here, use the document's default". Port of
/// `pdf._lead_pt`.
func leadPt(_ lh48: Double?) -> Double? {
    guard let lh48, lh48 > 0 else { return nil }
    return lh48 * 1.5
}

/// Mechanism T (ctrl-kd `tools/PCL-DIVERGENCE-TRIAGE.md`, 21e6d94): the factor
/// `styleLeadPt`'s "auto" (vmi == -2) branch, its too-small-explicit-vmi fallback, and
/// `fontLeadPt`'s WS5+ font-block formula all multiply a governing font size by, for
/// STOCK WordStar 7's single-spacing leading.
///
/// Every prior measurement of this factor (1.2, "19.2pt on a 16pt style", etc. — see this
/// file's own git history and `StyleLeadingTests.swift` before this fix) was taken from
/// `ws7-prints/v1`/`v2`, both captured through Robert J. Sawyer's own WSCHANGE-customized
/// `WS.EXE` — the SAME install mechanism S already found responsible for the `.po`
/// contamination (column 7 vs the manual's/stock's column 8). WSCHANGE's own settings
/// chart (`Installing and Customizing (WordStar 7)`, the "Changing WordStar Settings in
/// WSCHANGE" appendix) lists this exact feature by name, twice (once under the
/// alphabetical chart, once under its own "Leading" cluster alongside "Leading (line
/// height)" BCJ/240):
///
///     Automatic leading, 120% of text size        BCL     OFF
///
/// i.e. "120% of text size" (1.2x) is a WSCHANGE-toggleable setting whose FACTORY DEFAULT
/// IS OFF. Confirmed directly against a `PRISTINE.EXE` (factory, no WSCHANGE) recapture of
/// the same 4 documents whose leading this file already modelled from Sawyer's install
/// (`ws7-prints/v3`): every baseline gap driven by this formula scales by EXACTLY 1/1.2 of
/// the v1 figure, zero exceptions — LYING/WARPRAYR's Title(16pt)->Author gap: 19.2pt (v1,
/// Sawyer) -> 16.0pt (v3, pristine); -SCREEN/PREVIEW's font-block gaps: 14.4pt (v1) ->
/// 12.0pt (v3), and every `fontLeadPt`-governed gap in PREVIEW likewise at exactly 1/1.2.
/// Every OTHER transition this file measures (explicit vmi that already fits its own
/// font, `.lh`-governed lines, a blank line's own RAW lead) is IDENTICAL between v1 and
/// v3 — confirming this factor is the ONLY thing that moved between the two installs.
///
/// So: 1.0 (plain single-spacing, no auto-leading padding) is STOCK WordStar 7's real
/// behaviour; 1.2 was Sawyer's own personalization, exactly like `.po` column 7 and
/// page-numbering-off before it. The engine models stock. Swift-convention counterpart of
/// Python's `pdf.AUTO_LEAD_FACTOR` (same value, same call sites) — NOT `modernLine`
/// (`PDFModernLayout.swift`), which is Modern's own, deliberate, Word-convention 1.2x
/// single-spacing and stays 1.2 regardless of this constant (CLAUDE.md: "Modern diverges
/// from paper BY DESIGN").
let autoLeadFactor = 1.0

/// The baseline-to-baseline leading a WS7 paragraph STYLE dictates for every physical
/// line in `block` (`Block.lineHeightVMI`/`styleFontPt`, set from the style record's own
/// font/line-height fields — `parseWS`'s style-selection parse). `nil` when no style
/// governs this block, or the style set no line height of its own: the caller falls back
/// to the pre-existing `.lh`/document-default leading UNCHANGED, so a WS4 or otherwise
/// styleless document never shifts.
///
/// vmi == -2 ("auto" — the ONLY value seen on every style in the measured oracle,
/// LYING.WS/LYING.pcl): real WS7 leading is `autoLeadFactor`x the style's own font size,
/// not the document's fixed default — originally measured 2026-08-20 from PCL decipoint
/// baseline gaps against `ws7-prints/v1` (Sawyer's WSCHANGE-customized install): Title/
/// Author (16pt style) 192 decipoints (19.2pt) apart, Body (12pt) 144 decipoints (14.4pt)
/// apart, and a blank line between a 16pt block and the next 12pt block contributing its
/// OWN 19.2pt of the two lines' combined 336-decipoint (33.6pt) gap — a blank line
/// advances at ITS block's leading, which `styleFontPt` already gives it (block-level,
/// not read off the line's own spans, precisely because a blank line carries no
/// spans/font tag of its own — see `Block.styleFontPt`). Falls back to the document's own
/// printed SIZE (`printedSize`) if the style declared no font of its own (an all-zero/
/// recordless font triple).
///
/// UPDATE (mechanism T, `autoLeadFactor`'s own doc comment): the 1.2x/19.2pt/14.4pt/
/// 33.6pt figures above were measured against Sawyer's `ws7-prints/v1` install. A
/// `PRISTINE.EXE` (factory, no WSCHANGE) recapture of the SAME documents
/// (`ws7-prints/v3`) shows every one of these gaps at exactly 1/1.2 of the number above
/// (Title/Author 19.2pt -> 16.0pt, Body-to-Body 14.4pt -> 12.0pt, the blank-line-spanning
/// 33.6pt -> 28.0pt) — stock WordStar 7's real auto-leading factor is 1.0, not 1.2; see
/// `autoLeadFactor`'s own doc comment for the manual citation and the full v1-vs-v3
/// evidence table. Left the rest of this doc comment's OLD (Sawyer-measured) numbers as
/// written below — still an accurate record of what was measured and when — rather than
/// editing every instance; only the LIVE factor (`autoLeadFactor`) changed.
///
/// vmi > 0: an EXPLICIT count, in the same 1/1440in VMI unit WSFORMAT.WS documents for a
/// font's own height word ("Font height in VMIs (1/1440ths)") — so vmi/20.0 is points,
/// the identical conversion a font's height word already gets. Evidenced from the format
/// spec's own text, not guessed.
///
/// UPDATE 2026-08-20 (b26 round 26 wave 3, ctrl-kd's `fidelity_gate.py` Unit A): a WS7
/// oracle for a vmi>0 style now DOES exist — WARPRAYR.pcl (ws7-prints/v1), which this
/// docstring previously (wrongly) said was never printed on real WS7. WARPRAYR carries
/// vmi=240 on both its byline (16pt) and its entire body (12pt). The vmi/20.0=12pt formula
/// above is CONFIRMED, not contradicted, for the body: WARPRAYR.pcl's own baseline_gaps_pt
/// run 12.0pt for ~20 consecutive body-paragraph lines, exactly vmi/20 at 12pt font, with
/// zero drift. The ONE anomaly is the byline's OWN baseline, 19.2pt below the title's
/// (78.9 -> 98.1), not the 12pt vmi/20 (or the document default, also 12pt) predicts.
///
/// An EARLIER version of this comment special-cased vmi==240 to behave like -2/auto
/// everywhere (reasoning from the byline anomaly alone, plus 240 being suspiciously
/// identical to WSCHANGE's own "VMI units for line height" factory default, Installing
/// and Customizing p.2-47, DBA2H). That over-generalised: applied to the BODY it made
/// every body line 14.4pt instead of the CONFIRMED 12pt, which does get WARPRAYR to the
/// WS7 page count (3) but at the cost of a much larger positional residual within the
/// page (median jumped from ~2.5pt to 24pt) — fitting the one number the task asked for
/// by breaking twenty it didn't. Reverted, and a margin-COLLAPSING hypothesis (the
/// byline's OWN entry gap borrows the outgoing title block's larger lead, CSS-style) was
/// reported instead of acted on — correctly: it isn't margin collapsing.
///
/// FIX B (b26-print-fidelity-2), the evidence-backed resolution: the byline's vmi
/// (240 = 12pt) is simply too SMALL for its own 16pt font — 12pt leading on 16pt type
/// overlaps ascender-to-descender, so WS7 falls back to the SAME auto formula (1.2x the
/// style's own size, 19.2pt) an unset vmi already gets. The body's vmi=240 on its OWN
/// 12pt font is the negative case that PROVES this doesn't regress: 240/20 = 12.0 >=
/// 12.0, no fallback, the already-CONFIRMED 12.0pt stands untouched. Cross-checked
/// against every OTHER styled document in the corpus before landing: LYING's four
/// styles are all vmi=-2/auto (never reach this branch); OCAPTAIN/TWAINLET carry no
/// paragraph styles at all.
///
/// RESOLVED by Fix C's full block-transition inventory (below, and `enteringLeadPt`):
/// this doc comment's own UPDATE section originally read the byline's 19.2pt as a
/// property of the WHOLE Author block (so this fallback was applied uniformly, per
/// block, to every line). That was ALSO wrong, just less visibly — Author's own
/// trailing BLANK line (the one line inside it besides the byline itself) measures its
/// OWN space at 12.0pt, the UNFALLEN-BACK vmi/20, not 19.2pt. The fallback protects
/// against a REAL line's ascender/descender clipping into the line above — a blank line
/// has no glyphs to clip, so it never needs it: `raw: true` (every BLANK line, and the
/// value a block hands to `enteringLeadPt` as the NEXT block's "outgoing" reference)
/// always returns the unfallen-back vmi/20, regardless of position in the block.
/// `raw: false` (the default, every REAL line, first or not — every EXISTING call site
/// before Fix C only ever rendered a block's OWN first line through this function, so
/// this is the identical behaviour there) keeps the fallback.
///
/// RESOLVED (planning #256, sawyer/REF/-HOW-TO.RJS): this function used to return `nil`
/// outright for ANY document that ever used a real `.lh` dot command (`doc.page?.lhSource
/// == .file`), on the stated reasoning that "no corpus evidence exists for how real WS7
/// arbitrates a style's vmi against an ACTIVE `.lh`". -HOW-TO.RJS IS that evidence: its
/// ONE `.lh14/72"` (14pt) sits immediately before a `.pa` page break's heading paragraph,
/// which — like the numbered list that follows it — carries the SAME real paragraph
/// style ("Editing Defaults", vmi=240 = 12pt on its own font). Measured against the real
/// WS7 v4 PCL capture: the heading (14pt Univers) prints at a 14pt lead (vmi/20 = 12pt is
/// SMALLER than its own 14pt font — the too-small-vmi fallback below, `size *
/// autoLeadFactor`, already gives exactly this), and every 10pt-font list-item line
/// prints at the style's own EXPLICIT 12pt (vmi/20, no fallback needed — 12 >= 10). The
/// stale, document-global `.lh14/72"` value (14pt) is what a bare `.lh`-wins-
/// unconditionally reading was producing for the list items instead — wrong by 2pt per
/// line, compounding across the whole page. The style's own vmi now governs whenever a
/// block carries one — exactly the intent this doc comment already stated a few
/// paragraphs up ("a style's own leading... governs OVER the generic `.lh`/document
/// default") but a defensive, unevidenced document-wide veto silently contradicted (see
/// each call site's own comment for the other half of this fix: `ownLead` must let
/// `styleLead` win outright, not only when a line's own carried `.lh` happens to be
/// unset). Port of Python's `pdf._style_lead_pt`.
func styleLeadPt(_ block: Block, _ doc: Document, raw: Bool = false) -> Double? {
    guard let vmi = block.lineHeightVMI else { return nil }
    if vmi == -2 {
        // Python: `if not size: size = _printed_size(doc)` -- falsy catches both `None`
        // and a literal 0.0, not just the sentinel's absence.
        var size = block.styleFontPt ?? 0
        if size == 0 { size = Double(printedSize(doc)) }
        return size * autoLeadFactor
    }
    if vmi > 0 {
        // Finding B (b26-print-fidelity-2): an explicit vmi too SMALL for the style's
        // own font falls back to the SAME auto formula (autoLeadFactor x the style's
        // own size) an unset vmi already gets — WARPRAYR's Author style (vmi=240=12pt
        // on a 16pt font; 12pt lead on 16pt type would overlap ascender-to-descender)
        // measures 16.0pt (stock, autoLeadFactor x 16 — see mechanism T /
        // `autoLeadFactor`'s own doc comment for the v1-Sawyer-vs-v3-pristine
        // measurement this factor is now taken from; was 19.2pt/1.2x16 under Sawyer's
        // install). The Body style's vmi=240 on its OWN 12pt font is the negative case
        // PROVING vmi/20 remains correct when it fits (240/20 = 12.0 >= 12.0, no
        // fallback) — the already-CONFIRMED 12.0pt body leading (~20 consecutive
        // lines, zero drift), unmoved by this fix.
        //
        // `raw` (Fix C, b26-print-fidelity-2): the fallback above protects a REAL
        // line's ascender/descender from clipping into the line above — a BLANK line
        // has no glyphs to clip, so it never needs it. `raw: true` skips the fallback
        // and returns the unfallen-back vmi/20 always — see `enteringLeadPt`, which is
        // the ONLY caller that ever passes `raw: true` (for the block being LEFT, never
        // the one being entered), and the direct blank-line call sites in
        // `resolvePrintedBody`. `raw: false` (the default) is every
        // EXISTING call site's own behaviour, unchanged.
        let pt = Double(vmi) / 20.0
        if let size = block.styleFontPt, !raw, size > 0, pt < size {
            return size * autoLeadFactor
        }
        return pt
    }
    return nil
}

/// A block's own FIRST REAL (non-blank) physical line's lead: `styleLeadPt`'s
/// font-relative fallback (Finding B), floored against the block being ENTERED's own
/// natural minimum — Fix C (b26-print-fidelity-2, WARPRAYR.WS). An EXPLICIT (vmi>0)
/// style's first line never sits CLOSER to the preceding content than that content's
/// own RAW lead was — i.e. entering an explicitly, tightly-leaded block never crowds
/// whatever was above it.
///
/// Full block-transition inventory (WARPRAYR.pcl, WS7 frame, blank-line +
/// entering-line combined gaps — a blank line carries no glyph, so only the PAIR is
/// independently measurable; stock/v3 numbers, 1.2x/v1-Sawyer numbers alongside where
/// they differ — mechanism T, `autoLeadFactor`'s own doc comment):
///     Author(fallback,16.0; was 19.2) -> Body(vmi 240=12, fits)  24.0 = 12.0 + 12.0 (UNCHANGED — all-raw/fitting)
///     Body(vmi 240=12)    -> Quote(auto,12.0; was 14.4)  x2      24.0 = 12.0 + 12.0 (was 26.4 = 12.0 + 14.4)
///     Quote(auto,12.0; was 14.4)    -> Body(vmi 240=12)  x2      24.0 = 12.0 + 12.0 (was 28.8 = 14.4 + 14.4)
/// Only the Quote -> Body pairs need MORE than `styleLeadPt` alone gives (Body's own
/// 12.0 entering gap) — WS7 floors Body's own entering gap at Quote's own 12.0 instead
/// (a no-op at stock's factor, since Quote's own and Body's own both land on 12.0
/// already; the floor's EXISTENCE is still proven by the Sawyer/v1 numbers, where
/// 12.0 < 14.4 and the floor visibly engages). Author -> Body does NOT need this floor
/// once Finding B's fallback is correctly scoped to REAL lines only (`raw: true` for
/// Author's OWN blank line, above): Author's raw/exported lead is 12.0 (not its
/// fallback value, whatever the live factor makes that), so Body's own entering gap
/// (12.0) is ALREADY >= it, no floor needed — matching the measured 24.0 exactly with
/// no special case, at either factor.
///
/// Cross-checked against LYING.WS, which is entirely auto styles (no vmi>0 block
/// exists there to test the floor itself) but DOES cover the discriminating case this
/// floor must NOT fire for: Author(auto, 16.0; was 19.2) -> Subtitle(auto, 12.0; was
/// 14.4) measures 28.0 (was 33.6) = 16.0 + 12.0 — Subtitle's OWN entering gap, NOT
/// floored up to Author's outgoing 16.0 (which would give 32.0, wrong). The floor
/// therefore only applies when the block being ENTERED has an EXPLICIT vmi (this
/// function's own `vmi > 0` guard below) — a genuinely auto style already computes
/// generously relative to its own font and needs no protection against the block
/// before it; this is the ONE rule shape that fits every transition in both measured
/// styled documents, in both directions, with no unexplained gap, at either factor.
///
/// NOT independently confirmed: a SECOND real (non-blank) line inside a too-small-vmi
/// style also getting the fallback rather than the raw value — no such line exists in
/// the corpus (WARPRAYR's Author block has exactly one real line). Reasoned from the
/// SAME clipping rationale Finding B's own fallback rests on (a real line's
/// ascender/descender doesn't stop clipping just because it isn't the block's first),
/// not from a second measurement.
///
/// UPDATE 2026-09-08 (#236, INTERVU.WS/WORDSTAR.WS title blocks): the LYING.WS
/// cross-check above and the "auto never needs the floor" conclusion it supported only
/// ever exercised a transition with a BLANK line between the two blocks (Author's own
/// trailing blank separates it from Subtitle) — the blank line already provides real
/// separation, at ITS OWN (outgoing) block's lead, before Subtitle's first real line is
/// even reached, so no extra floor is needed there. INTERVU.WS's title block is the
/// discriminating case that reading never covered: three single-line AUTO-style
/// paragraphs stacked with NO blank line between them at all (H1 "Why I Still Use
/// WordStar:" directly followed by H2 "An Interview...", no intervening blank).
/// Measured directly against WS7's own capture: H1(18pt)->H2(16pt) advances 18.0pt
/// (H1's OWN outgoing size, not H2's entering 16.0), and H2->H3(14pt) advances 16.0pt
/// (H2's own outgoing size) — the identical floor this function already applies for an
/// explicit vmi, engaging for auto too, but ONLY when the line above is REAL (no blank
/// line already did the job). The floor therefore applies whenever the block being
/// ENTERED has an EXPLICIT vmi (unconditionally, as before), OR an auto (-2) vmi AND
/// the previous block's own LAST line still carries real content (no blank line
/// intervening) — a genuinely auto style needs no protection when a blank line already
/// separated it from what came before, but does need it butted directly against
/// another real line, for the same ascender/descender-clipping reason Finding B's own
/// fallback exists. Port of Python's `pdf._entering_lead_pt`.
func enteringLeadPt(_ block: Block, _ doc: Document, prevBlock: Block?) -> Double? {
    guard let own = styleLeadPt(block, doc, raw: false) else { return nil }
    guard let prevBlock else { return own }
    let vmi = block.lineHeightVMI
    let explicit = (vmi ?? 0) > 0
    let autoAdjacent = vmi == -2 && (prevBlock.lines.last?.spans.isEmpty == false)
    guard explicit || autoAdjacent else { return own }
    guard let prevRaw = styleLeadPt(prevBlock, doc, raw: true) else { return own }
    return max(own, prevRaw)
}

/// This physical line's own baseline-to-baseline lead in points under WordStar's
/// AUTO-LEADING, for a WS5+ font-block document with no paragraph style governing the
/// line (`styleLeadPt` returns `nil` for it).
///
/// THE GATE is the caller's: auto-leading is a MODE the document turns on with `.lh a` /
/// `.lh auto` (`Block.lhAuto`), not something inferred from proportional fonts being
/// present, and a real numeric `.lh` anywhere in the document (`lhSource == .file`) switches
/// it off. This function is only consulted for a line in an `lhAuto` block of such a
/// document. A document with big proportional font blocks and no `.lh` (ERROR.WS: 72pt and
/// 42pt blocks) never gets here and prints at the flat document lead, so there is no
/// size ceiling to apply.
///
/// THE RULE (measured on real WS7 with PREVIEW.WS and probe documents; every entering
/// advance was an exact multiple of 10 decipoints on a declared font height):
///
///     advance(line N) = max( the size CARRIED OUT of line N-1,
///                            every font size declared anywhere ON line N )
///
/// What a line carries OUT is the size of the font in force at its END when that font is
/// PROPORTIONAL, and `baseSize` (the document default) when it is fixed-pitch or there is
/// no font at all. A blank line declares nothing, so it passes its predecessor's answer
/// through and advances by it.
///
/// THE END OF A LINE counts a font record that follows its last text and precedes its
/// return (WS7 report 14.5, runs lead3 and lead5: Times 24 text closed by a restore
/// record before the return, and the next line, Courier, advances 12; a 24-pt font that
/// runs on from mid line 3 into line 4 makes line 4 advance 24 and line 5 12 -- "a
/// line's height is the largest font on it, counting the font in effect at its start,
/// and nothing carries further"). Such a record puts no span on the line it ends, so the
/// font in force at the end is `Line.fontOut`, read at parse time; a line built without
/// it falls back to its last span's. A fixed-pitch block therefore never
/// carries into the next line, but it does raise its OWN line (an inline Courier 20pt line
/// entered from a 12pt state advances 20pt). The result is multiplied by `autoLeadFactor`
/// (1.0 on a stock install).
///
/// `state` is `inout`, owned and threaded by the CALLER across every physical line of the
/// document in source order (mirrors `pendingSa`'s cross-block carry). `nil` means
/// nothing has carried yet, which reads as `baseSize`. Port of Python's `_font_lead_pt`.
func fontLeadPt(_ line: Line, fonts: [FontChange], baseSize: Double, state: inout Double?)
    -> Double
{
    func entry(_ span: Span) -> FontChange? {
        guard let fidx = span.font, fidx >= 0, fidx < fonts.count else { return nil }
        let e = fonts[fidx]
        return e.points > 0 ? e : nil
    }
    var governing = (state ?? 0) > 0 ? state! : baseSize
    for span in line.spans {
        if let e = entry(span), e.points > governing { governing = e.points }
    }
    if let fontOut = line.fontOut {
        // the font in force at the line's end, a trailing record included
        let e = (fontOut >= 0 && fontOut < fonts.count && fonts[fontOut].points > 0)
            ? fonts[fontOut] : nil
        state = (e?.proportional ?? false) ? e!.points : baseSize
    } else if let last = line.spans.last {
        let e = entry(last)
        state = (e?.proportional ?? false) ? e!.points : baseSize
    }
    return governing * autoLeadFactor
}

/// `[block index in doc.blocks: lead48]` for every printed content block (`.para` kind,
/// headings included — `.pagebreak`/`.condpage` sentinels carry no lines and are
/// skipped), giving RTF's own per-paragraph `\sl` (`rtfBlockLead48`) the SAME resolved
/// leading this file's own PDF page-building already uses per PHYSICAL line
/// (`docToPagelines`'s printed branch: `.lh` override, else a paragraph STYLE's own
/// `lineHeightVMI`-derived leading via `styleLeadPt`/`enteringLeadPt`, else a WS5+
/// font-block's own proportional size via `fontLeadPt`, else the document default).
/// Ruling 2026-08-26 (mirrored from ctrl-kd ebc2939, register row, b33 field notes N2):
/// Printed/Native RTF previously emitted ONE flat `\sl` for the whole document — a 16pt
/// Title/Author style (WS7 style vmi -2/auto, real leading 1.2x16=19.2pt) was squeezed
/// onto the document's plain 12pt body lead, clipping in Word/TextEdit. This ports the
/// READ side of that same per-line algorithm to block granularity — RTF's `\sl` is a
/// PARAGRAPH property with no per-line control word, so a block collapses to its own
/// FIRST REAL (non-blank) physical line's resolved value, exactly the "ceiling of what
/// RTF can express per paragraph" `rtfBlockLead48`'s own doc comment already named (a
/// `.lh` change strictly mid-paragraph was already out of scope there, unchanged here).
/// `fontLeadState` is still threaded across EVERY physical line of the WHOLE document in
/// source order, blank lines and non-first real lines included, even though only one
/// resolved value per block is kept — an inline font-block change inside a later line
/// must still update the carried state exactly as `docToPagelines` computes it, or a
/// LATER block's own first line would resolve against a stale governing size. No
/// existing PDF consumer of `leadPt`/`styleLeadPt`/`enteringLeadPt`/`fontLeadPt` is
/// touched — this only calls them, read-only, in the same per-line order and under the
/// same gates they already use. Port of `pdf.resolved_printed_leads_48`.
func resolvedPrintedLeads48(_ doc: Document) -> [Int: Double] {
    var leading = LineLeading(doc)
    let defaultLeadPt = printedLead(doc)
    var out: [Int: Double] = [:]
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak || block.kind == .condpage { continue }
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        var firstLineOfBlock = true
        var resolvedPt: Double? = nil
        for line in block.lines {
            let isBlank = !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
            let ownLead = leading.lead(of: line, in: block, isBlank: isBlank,
                                       isFirstLine: firstLineOfBlock,
                                       prevParaBlock: prevParaBlock)
            if !isBlank { firstLineOfBlock = false }
            if resolvedPt == nil, !isBlank {
                resolvedPt = ownLead ?? defaultLeadPt
            }
        }
        if resolvedPt == nil {
            // every line in this block is blank (a pure spacer block) — no REAL line
            // ever set resolvedPt above. Fall back to the block's own first line, raw
            // (no entering-floor: there is no real glyph here to protect from clipping
            // into whatever came before), same `raw: true` doctrine as a blank line
            // mid-block.
            if let line = block.lines.first {
                let ownLead = leading.lead(of: line, in: block, isBlank: true,
                                           isFirstLine: false, prevParaBlock: prevParaBlock)
                resolvedPt = ownLead ?? defaultLeadPt
            } else {
                resolvedPt = defaultLeadPt
            }
        }
        out[bi] = resolvedPt! / 1.5      // points -> 1/48in, inverse of leadPt
    }
    return out
}
