/// Modern-mode PDF layout: the printed form of the Modern RTF. Port of `pdf.py`'s
/// `_modern_geometry`, `_modern_tok_font`, `_modern_w`, `_modern_flow`, `_modern_wrap`,
/// `_modern_note_lines`, `_modern_line_ops`, `_modern_streams` (added 2026-08-05).
///
/// Ruled 2026-08-05: "Modern PDF needs to be the printed version of Modern RTF." One
/// content model for the Modern column -- the RTF model (reflowed, document fonts
/// carried, footnotes anchored) -- with PDF as its paper rendering. Everything here
/// mirrors what Word does when you print the RTF: proportional wrap at the real measure,
/// single spacing by the line's own type size, footnotes at the page bottom, paragraph
/// gaps, `.pa` honored. Fontless text is base-14 Times at the sophisticated size (Georgia
/// has no base-14 seat; "the PDF needs to work no matter what"). The Courier-only Modern
/// died with the WS4 lens; that typescript aesthetic lives only in Printed now, where a
/// fontless document on a fixed grid genuinely IS a typescript.

/// The sophisticated size (Jon's specimen ruling). Distinct from `modernBodySize`
/// (`FontMap.swift`, RTF/HTML's Georgia 14) the way Python keeps two separate constants —
/// same value, different files, different design principle behind each (base-14 has no
/// Georgia seat, so the PDF body is Times, not Georgia, at this same size).
let modernBodyPt = 14
let modernNotePt = 11
/// Single-spacing: baseline advance = 1.2 x the line's own type size.
let modernLine = 1.2

// ------------------------------------------- verse/centre tightening (#263)
//
/// Poetry and centred material set SINGLE-spaced internally regardless of the surrounding
/// prose's own spacing — the cross-format law Modern RTF (`EmitRTF`'s verse-tight `\sl`) and
/// Modern HTML (`line-height:1.15` against the page's own 1.6 ambient) already follow. Modern
/// PDF did not, and Modern PDF is what Soft Return.app's Modern VIEW is answerable to, so the
/// two disagreed on where every centred/verse line fell. Backported from the app's own
/// shipped, measured implementation (Jon's ruling 2026-09-11, "Yes. I want it. Backport it.")
/// by way of ctrl-kd's `MODERN_VERSE_TIGHT` (fe87b41).
///
/// THE FACTOR is the app's `modernVerseTightLineHeightMultiple` — itself the ratio of the two
/// literals Modern HTML already states (verse 1.15 against the page ambient 1.6). It is a
/// RELATIVE multiplier on the FACE's own natural line height, never on `modernLine * pt`: an
/// absolute floor or ceiling cannot tighten reliably across faces (it is inert the moment a
/// face's natural height already sits under it), and the same relative number means different
/// leading in different faces, which is the point.
public let modernVerseTight = 0.71875

/// NATURAL LINE HEIGHT, per face, as a multiple of type size.
///
/// "Natural" means what the app's text stack reports for the real face it sets Modern in
/// (`NSLayoutManager.defaultLineHeight`) — the number `modernVerseTight` is relative TO. This
/// engine has no such stack and no such faces (base-14 only, nothing embedded, by design), so
/// the two faces that matter are carried as MEASURED CONSTANTS, taken from the app and
/// recorded with the measurement that produced them:
///
///   Times New Roman 14pt -> 16.0pt natural   (16.0 / 14 = 8/7)
///   Courier Prime   12pt -> 14.0pt natural   (14.0 / 12 = 7/6)
///
/// So a tightened Times line at the 14pt body size is 11.50pt against the untightened 16.80,
/// and a tightened Courier line at 12pt is 10.06 against 14.40. The two ratios against
/// `modernLine * pt` are 0.685 and 0.699 — NOT the same number, which is why a single
/// face-independent constant cannot reproduce the app and this is a table rather than a scalar.
///
/// The faces with no measurement of their own (Helvetica, Symbol, ZapfDingbats) take the Times
/// row, not an invented one: Times is Modern's own default body face (`modernTokFont`: a token
/// with no font information reads in Times), the only other PROPORTIONAL measurement in hand,
/// and the conservative choice — Courier's row is the odd one out precisely because it is the
/// monospace face. An unmeasured face is named as unmeasured here rather than silently
/// interpolated.
public func modernNaturalLine(_ family: PDFFamily) -> Double {
    family == .courier ? 7.0 / 6.0 : 8.0 / 7.0
}

/// WHERE THE BASELINE LANDS inside a tightened box, as a multiple of type size: the face's own
/// ASCENT, from which the whole of the compression is taken. The line's descent and leading
/// keep their full, untightened size below the baseline, and the box loses its height off the
/// TOP — which is exactly why tightening can clip a tall glyph's ascender at all, and what
/// `modernLeadingSpacer` exists to reserve room for.
///
/// Times New Roman's ascent is 1825/2048 em (its own `hhea` ascender); Courier Prime's is
/// 11/12 em, leaving the classic 1/4-em monospace descent under its measured 7/6 natural box.
/// Same unmeasured-face fallback rule as `modernNaturalLine`.
///
/// MEASURED against the app, so the residual is on the record rather than implied: the app's
/// own -README spacers are 3.70/3.71/3.94pt, this engine's on the same document 3.59-3.74.
/// What is left sits in the INK, not in this constant — the app measures a real Mac face's
/// glyph PATH bounds, which do not match the design bounding boxes the AFM publishes for the
/// metric-compatible base-14 face this engine sets in, and no base-14 number can close that by
/// construction.
public func modernFaceAscent(_ family: PDFFamily) -> Double {
    family == .courier ? 11.0 / 12.0 : 1825.0 / 2048.0
}

/// The app's own fixed pad on a leading spacer's height: a second, independent drawing pass
/// does not land pixel-for-pixel on the one that measured it.
public let modernSpacerPad = 2.0

/// The indent LADDER's one step, in WordStar print columns: how far each nesting level of a
/// def/bullet row sits past the one above it. Level 1 sits AT the margin (the row's own
/// declared column is deliberately never used — one file opens level-1 blocks at `.lm 15`,
/// `.lm 2` and `.lm 0`, and rendering the raw column put level-1 labels at three different
/// distances). Jon's b17 ruling.
public let modernLevelStepCols = 4

/// A def row's HANG — where a wrapped continuation lands, past the margin. One FIXED figure
/// for every def row, never the longest label's width and never the row's own: a per-row hang
/// made every row in the same block wrap at its own column ("each line wrap seems to have its
/// own place"), and a block-wide longest-label hang landed the column far enough right to read
/// as a second column of body text (job 322). 72pt past the margin puts it 2in from the page
/// edge on Modern's own 1in margins.
public let modernDefHangPt = 72.0

/// One token in Modern PDF's flow: written text, its resolved face/size/font-block entry,
/// and its measured advance in points. Python's 6-tuple `(text, styles, family, pt, entry,
/// width)`, as a named type — the tuple shape is what made `_modern_line_ops`'s recursive
/// single-token sub-calls painless in Python; a Swift array-of-one plays the same role.
struct ModernToken {
    var text: String
    var styles: Style
    var family: PDFFamily
    var pt: Int
    var entry: FontChange?
    var width: Double
}

/// One item in the document's Modern flow, before pagination. Python's tagged tuples
/// (`('para', toks, align, notes, indent, cut, no_wrap, page_marker)`, `('blank',
/// height)`, `('break',)`, `('cond', n)`, `('hf', kind, line, text)`).
enum ModernFlowItem {
    case pageBreak
    /// `.cp n` — resolved by the paginator, the only thing that knows how full the page is.
    case cond(Int)
    case blank(Double)
    /// A running-head/foot change, replayed by the paginator so each page carries the
    /// state in force when it took content (ruling 2026-08-06 M5: Modern keeps headers).
    case hf(kind: HFKind, line: Int, text: String)
    /// One logical (already soft-wrap-merged) line's tokens, ready for real-measure wrap.
    /// `notes` are the FOOTNOTES this line's `fnref` markers reference — carried with the
    /// line so the paginator can reserve their page-bottom room the moment the line that
    /// first names them is placed (endnotes/annotations collect at the document end
    /// instead — M1). `index` is the note's position in `inlineReferenceNotes(doc)`, the
    /// stable identity Python's `id(note)` provides for dedup. `indent`/`cut` carry the
    /// block's own `.lm`/`.rm` in points — the document's explicit margins win in Modern
    /// exactly as its fonts do (M2). `noWrap`/`pageMarker` (b26-modern item 3, ctrl-kd
    /// c82b2ff): the screenplay pagination ruling's two line shapes, gated on
    /// `detectScreenplayBlocks` — see `modernFlow`'s own doc comment for the full
    /// mechanism.
    /// `endNotesStart` (round 2026-09-07, Jon's ruling): `true` for exactly the ONE
    /// `.para` this file builds from `.noteSeparator` — the item that opens the
    /// end-matter appendix (endnotes/annotations/comments, M1) — `false` for every other
    /// paragraph, including the end-matter's own note entries. The paginator
    /// (`modernStreams`) uses it to decide whether the appendix needs a fresh page.
    /// `tight`/`hang` (planning #263, ported from ctrl-kd fe87b41): the two figures the
    /// verse/centre and def/bullet rules hand the paginator — `tight` says this paragraph
    /// sets at the face's COMPRESSED line height (`modernTightHeight`) rather than at
    /// `modernLine * pt`, `hang` is a structured row's own continuation indent in points,
    /// which moves every visual line after the first to the right and narrows what those
    /// lines wrap at. Both are 0/false for every ordinary paragraph.
    case para(toks: [ModernToken], align: Alignment,
              notes: [(index: Int, label: String, text: String)],
              indent: Double, cut: Double, noWrap: Bool, pageMarker: Bool,
              endNotesStart: Bool, tight: Bool, hang: Double)
    /// An embedded pix image standing alone on its own paragraph — b24 round 22, closing
    /// round 19's documented Modern scope cut. Python's `('image', idx, w, h)` tuple.
    case image(pixIndex: Int, widthPt: Double, heightPt: Double)
}

/// `doc.page` as MODERN reads it: the document's own declared sheet, with `.pr or=l`'s
/// landscape swap applied. Port of `_modern_page_dict`.
///
/// Jon's ruling 2026-09-15 ("Yes. Fix it."): Modern PDF keeps the document's sheet
/// ORIENTATION. That is the paged-surface doctrine's own point 2 (2026-08-17, "honor
/// `.pr or=l` landscape in ALL paged surfaces") finally reaching the one paged surface
/// it had not, and it follows from the 2026-08-05 ruling that Modern PDF is the printed
/// form of the Modern RTF — a landscape document printed portrait is not a printing of
/// anything the document says.
///
/// IDEMPOTENT, deliberately. `landscapePage` recomputes the height/width pair fresh from
/// the page's own `.pl` rather than swapping whatever height it is handed, so this
/// answers the same thing whether or not `resolvedGeometryDocument` has already rotated
/// the document — which matters because `emitLayout` reaches `modernStreams` (through
/// `attachGraphicCellsModern`) with the document as parsed, and the two passes must
/// compose the same pages.
/// Does WordStar's AUTOMATIC page number appear on a Modern page whose content ends at
/// block `bi`? Port of `_modern_auto_pageno_shows`.
///
/// Jon's ruling M15 (2026-09-15): "I think it should in Modern View... it looks weird
/// that it suddenly goes away. Now on Export that's different. There's a flag if people
/// want Page Number or not." So the Modern view shows the number wherever Printed does,
/// and Modern exports obey `--page-numbers` auto/on/off exactly as Printed does — which
/// is the same thing said twice, because the view IS the `auto` export.
///
/// THE THREE SILENCERS, and they are the document's, not Modern's
/// (research/2026-09-15_ws7-missing-auto-page-number.md, measured across 308 real WS7
/// captures with zero counter-examples):
///
///   1. `.op` — and `.pn`/`.pg` turn it back on, from where THEY sit. Read here through
///      `pgnumAt`, the same block-granular state Printed reads.
///   2. ANY footer command (`.fo`, `.f1`-`.f8`), with text, bare, or carrying only
///      invisible characters. The footer REPLACES the number.
///   3. `.mb 0` — no footer row on the sheet at all. `autoPagenoRowY` is the one
///      definition of that, shared with Printed.
///
/// `pageNumbers` is the export flag: `.off` and `.on` force it either way (`on` even over
/// a document's own `.op`, `off` even over `.pn`), and `.auto` — the default, and what
/// the app's own Modern view renders — asks the document. The footer and `.mb 0` rules
/// are NOT flag-gated: they are what WordStar itself does, and `--page-numbers on` cannot
/// conjure a row onto a sheet that has none or overwrite a footer that occupies it.
func modernAutoPagenoShows(_ doc: Document, bi: Int,
                           pageNumbers: EmitOptions.PageNumberMode,
                           pgnumCheckpoints cps: [PgnumCheckpoint],
                           footerInUse: Bool) -> Bool {
    if pageNumbers == .off || footerInUse { return false }
    // A page that closed with no content of its own (an explicit break with nothing
    // after it) has no position to read; it falls back to the document's opening state.
    let bi = max(bi, 0)
    let pl = plAt(plCheckpoints(doc), bi)
    let mb = mtMbAt(mtMbCheckpoints(doc), bi).mb
    let fm = doc.page?.fmLines ?? 2.0
    guard autoPagenoRowY(pageHeight: resolvedPageHeight(doc, printed: true),
                         pl: pl, mb: mb, fm: fm, size: printedSize(doc)) != nil else {
        return false
    }
    if pageNumbers == .on { return true }
    return pgnumAt(cps, bi)
}

func modernPageDict(_ doc: Document) -> PageGeometry? {
    guard let page = doc.page else { return nil }
    return doc.formatting.orientation == .landscape ? landscapePage(page) : page
}

/// The height of the sheet Modern composes on, in points: the document's OWN declared
/// sheet, always — and the same number `emitPDF` writes into the Modern MediaBox, so the
/// page Modern draws on and the page it says it drew on can never disagree. Port of
/// `_modern_sheet_h`.
///
/// M18 (Jon's queue 2026-09-15). This used to answer Letter's own 792 for every portrait
/// document whatever the file declared, and M17 corrected only the landscape half of
/// that ("a landscape sheet is genuinely shorter than Letter, and laying out from 792 on
/// one draws every line above the top of the page"), naming the portrait half as a real,
/// separate defect in this docstring: "a label/envelope template (`.pl 4.17"`) gets a
/// 612x300 MediaBox with every line drawn at y >= 552 — the whole page blank." That is
/// this fix. MAILLIST/ENVELOPE.LST rendered every one of its pages blank; so did the
/// rest of the label/envelope/Rolodex template family, and an A4 document (`.pl 11.69"`)
/// lost the 50pt its taller sheet gives it.
///
/// THE SHEET IS NOT SOMETHING MODERN RE-DECIDES. Modern's own choices are typographic —
/// its fonts, its 1.2 line height, its margins, its running heads — and the MediaBox has
/// read the document's declared height since 2026-08-06 ("the page is the document's
/// declared size (Letter/Legal/A4)"). Only the composing ORIGIN was hardcoded, which is
/// why the defect reads as a blank page rather than as a wrong page size: the text was
/// drawn, at coordinates off the top of the sheet it was drawn on.
///
/// `.pl 0` IS NOT A SHEET. It is WordStar's "page breaks off" (bug 12284,
/// `textLinesPerPage`), and the text model already never breaks, so the page BOX falls
/// back to Letter — a truly unbounded page is not expressible in PDF. That is verbatim
/// what Printed has done since `resolvedPrintedPageHeight` was written, quoted here
/// rather than re-decided. Before this fix it gave Modern a ZERO-HEIGHT MediaBox.
///
/// The floor is Printed's own, for Printed's own reason: a page has to hold the footnote
/// floor's worth of lines (`footnoteFloor + 1`).
func modernSheetH(_ doc: Document) -> Double {
    let heightIn = modernPageDict(doc)?.heightIn ?? 11.0
    if heightIn == 0 { return Double(PDFMetrics.pageHeight) }
    let floorPoints = PDFMetrics.lead * (footnoteFloor + 1)
    return Double(max(floorPoints, roundHalfToEven(heightIn * 72.0)))
}

/// `(one column's own measure, the gutter)` in points, inside Modern's text frame —
/// `.co n, gutter` as MODERN reads it. Port of `_modern_column_width`.
///
/// Modern PDF is the printed form of the Modern RTF (ruled 2026-08-05), and
/// `\cols n\colsx g` says exactly this to a reader: divide THIS section's own text area
/// into n equal columns separated by g. So Modern divides its OWN measure — Modern's
/// margins scaled to the sheet — rather than re-deriving the column from the document's
/// `.rm` the way Printed does. Those are the same measure stated twice: `applyColumns`
/// reads the column off `.rm` precisely because "an author who wants n real columns sets
/// `.rm` to ONE column's own width first", and BOOKLET.WS proves the pair agree
/// (`.po .2i` + `.rm 4.50"` + a 1.00" gutter fills an 11in landscape sheet almost
/// exactly as this division does). Applying the `.rm` cut ON TOP of the division would
/// narrow every column twice, which is why a columnar region's lines take the column as
/// their measure and not the block's own cut.
///
/// The gutter is print columns at 10 CPI — WordStar's own unit for it, the same `.po`
/// uses — and an author who names none gets one print column: the identical reading
/// `rtfColsControl` gives the very same `.co` pair when it writes `\colsx`.
func modernColumnWidth(_ width: Double, cols: Int, gutter: Double?)
    -> (columnWidth: Double, gutterPt: Double) {
    guard cols > 1 else { return (width, 0.0) }
    let g = gutter ?? 0
    let gutterPt = (g != 0 ? g : 1) * pdfPtPerCol
    return (max(36.0, (width - Double(cols - 1) * gutterPt) / Double(cols)), gutterPt)
}

/// `(left, topMargin, bottomMargin, textWidth)` in points. The document's declared
/// geometry wins (governing principle); silence is the modern page: 1in margins on
/// Letter.
///
/// THE RIGHT MARGIN MIRRORS THE LEFT (Jon's ruling 2026-09-15, "Yes to mirror
/// margin"). It used to be a flat 1in while Modern RTF mirrored `.po` into `\margr`
/// (`rtfPageSetup`: `margr = margl`), so the same document's two Modern surfaces
/// disagreed about where its text ended -- `sawyer/REF/BOOKLET.WS` measured 763.2pt
/// wide in RTF and 705.6 in PDF. One rule, both surfaces: whatever `.po` the document
/// declares is the margin on both sides, 1in the fallback on both when it declares
/// none. WordStar's own `.rm` is still not consulted on either: it is a text measure,
/// not a page property.
///
/// The alternative was measured first, at Jon's instruction: forcing a LITERAL 1in on
/// both sides regardless of `.po` blanks 6 label documents on 1in-tall sheets, moves
/// envelope address blocks by up to 5.5in and collapses the two space-set character
/// charts (research/2026-09-15_modern-one-inch-margins-impact.md). Mirroring the
/// DECLARED value harms none of those. Port of `_modern_geometry`.
public func modernGeometry(_ doc: Document) -> (left: Double, top: Double, bottom: Double, width: Double) {
    let page = modernPageDict(doc)
    let mtDeclared = (page?.mtSource ?? .default) != .default
    let mbDeclared = (page?.mbSource ?? .default) != .default
    let poDeclared = (page?.poSource ?? .default) != .default
    let margt = mtDeclared ? (page?.mtLines ?? 6.0) * 12.0 : 72.0
    let margb = mbDeclared ? (page?.mbLines ?? 6.0) * 12.0 : 72.0
    let margl = poDeclared ? (page?.poCols ?? 10.0) * 7.2 : 72.0
    let pageW = (page?.pwIn ?? 8.5) * 72.0     // A4 files are narrower (2026-08-06)
    let width = max(144.0, pageW - margl - margl)
    return (margl, margt, margb, width)
}

/// `(written, family, pt, entry)` for one modern token. `spanRender` does the real work
/// (untransliteration, entry sizes); the one modern rule on top: a token with NO font
/// information reads in Times at the sophisticated size, never Courier — the typescript
/// aesthetic lives only in Printed now. Port of `_modern_tok_font`.
///
/// `nonpropFallback` (planning #252, Jon's ruling 2026-09-09 verbatim, ported from
/// ctrl-kd pdf.py's identical parameter added the same round): the ONE exception. A
/// document can carry font blocks elsewhere (so this run's own lack of one is a real
/// gap, not a fontless document) AND separately declare itself non-proportional at the
/// document level (`.ps off`, WSFORMAT register C19 — `doc.formatting.proportional ==
/// false`, the SAME flag round 9 already parsed and deliberately left unconsumed — see
/// Info.swift's old `ps_note`). Round 9's ruling stands for every run a real font block
/// DOES cover (`pdfFamily`'s own `entry.proportional == false` check, unchanged); this
/// is only the uncovered-run fallback. Caller resolves `nonpropFallback` ONCE per
/// document (`!fonts.isEmpty && doc.formatting.proportional == false`) — a document
/// with zero font blocks anywhere stays Times regardless of `.ps`, matching the
/// ruling's explicit "no fonts -> Times (unchanged)."
func modernTokFont(_ text: String, font: Int?, fonts: [FontChange], nonpropFallback: Bool = false)
    -> (written: String, family: PDFFamily, pt: Int, entry: FontChange?)
{
    let rendered = spanRender(text, font: font, fonts: fonts, size: modernBodyPt)
    if rendered.entry == nil {
        return (rendered.text, nonpropFallback ? .courier : .times, rendered.size, nil)
    }
    return (rendered.text, rendered.family, rendered.size, rendered.entry)
}

/// A token's advance in points under modern layout: natural face widths (face-scaled for
/// entries, straight AFM for fontless Times), the fixed grid only where a fixed-pitch
/// font block asks for it. Port of `_modern_w`.
///
/// `printedPt` (planning #254, 2026-09-10): the document's OWN fixed-pitch type size
/// (`printedSize(doc)`), never the Modern reading size -- a graphic character (box-
/// drawing, block, shade) draws on the Printed fixed-pitch cell REGARDLESS of a resolved
/// font entry's own `proportional` flag (WordStar counted a `.cw`-pitch column grid for
/// these glyphs no matter what printer face the document declared; Modern's reading face
/// is irrelevant to that count -- Jon's ruling). Before this fix, a fontless run
/// (`entry == nil`, every WS4 file and any run before a WS5+ document's first font-
/// change record) advanced graphic cells at the Modern BODY size (14pt) instead:
/// -README's 65-column `=` rule measured 65*14 = 910pt in a 468pt measure, 370pt past
/// the sheet's right edge. `spanPitch(entry, printedPt)` already ignores `printedPt`
/// entirely once `entry` carries its own `widthHMI` (a real WS5+ font block), so this
/// same call is correct for a resolved fixed-pitch OR proportional entry too -- passing
/// `printedPt` here (not `spt`) only changes the FALLBACK branch (`entry == nil`), which
/// is exactly the shape that was wrong. Port of ctrl-kd's identical `printed_pt`.
func modernTokenWidth(_ text: String, styles: Style, family: PDFFamily, pt: Int, entry: FontChange?,
                      printedPt: Int) -> Double {
    let (spt, _) = sized(styles, pt)
    let basefont = base14(family, bold: styles.contains(.bold), italic: styles.contains(.italic))
    if text.contains(where: { graphicChars.contains($0) }) {
        // mixed tokens split into graphic runs (cell advance) and text (natural), same
        // rule as printed's `splitGraphics`. FONTLESS spans take this path too under
        // Modern (round 3, 2026-08-06 M11): a cp437 box/block glyph has no cp1252 slot,
        // and '?' is nobody's take -- the geometry IS the glyph. Printed's own fontless
        // spans draw the same shape at the same em advance now too (job 187) -- the two
        // modes agree on this rule, not just on its rationale.
        var total = 0.0
        let pitch = spanPitch(entry, printedPt)
        let chars = Array(text)
        var pos = 0
        for range in graphicRunRanges(chars) {
            if range.lowerBound > pos {
                let piece = String(chars[pos..<range.lowerBound])
                total += modernTokenWidth(piece, styles: styles, family: family, pt: pt, entry: entry,
                                          printedPt: printedPt)
            }
            total += Double(range.count) * pitch
            pos = range.upperBound
        }
        if pos < chars.count {
            let piece = String(chars[pos...])
            total += modernTokenWidth(piece, styles: styles, family: family, pt: pt, entry: entry,
                                      printedPt: printedPt)
        }
        return total
    }
    if let entry, !entry.proportional {
        return Double(text.width) * spanPitch(entry, spt)
    }
    let natural = stringWidthPt(text, basefont, spt)
    if let entry {
        return natural * faceTz(basefont, spanPitch(entry, spt), spt) / 100.0
    }
    return natural
}

/// Modern's token boundaries: the SAME border-gap-border graphic-run shape
/// (`graphicRunRanges`, `PDFDriverLJ6DTP.swift`) the drawing code already understands
/// as one unit, tried BEFORE falling back to the generic space/non-space split. Port of
/// `_MODERN_TOK_RE = _GRAPHIC_RUN.pattern + r'|[^ ]+| +'` (b26-modern item 2, ctrl-kd
/// 8122706).
///
/// Root cause this fixes: the plain space/non-space split broke a box-drawing row
/// (`<left border><interior spaces><right border>`) into THREE tokens, because the
/// interior is pure whitespace and the old tokenizer always broke on space runs. The
/// border tokens then measured through `modernTokenWidth`'s graphic-pitch branch, but
/// the all-space middle token had no graphic char in it, so it fell through to ordinary
/// proportional-text measurement instead — the two measurement systems only coincided
/// by accident when a resolved fixed-pitch font `entry` was active (both sides reduce
/// to the same `spanPitch` formula then); a genuinely fontless region (`entry == nil` —
/// every WS4 file, and any WS5+ document before its own first font-change record, e.g.
/// a box that is the document's own first content) measured its border chars and its
/// interior gap by two UNRELATED formulas, so the row's own drawn width stopped
/// matching its neighbouring rows (reproduced on the real corpus, BOXES.WS: its opening
/// box, before any font record, measured 322pt per row; an identical box appearing
/// later in the same file, by then under a resolved font, measured 165.6pt). Trying the
/// graphic-run shape FIRST lets a box row reach width measurement and `modernWrap` as
/// the ONE unit it visually is — this also fixes a second symptom: a graphic row wider
/// than the page's text width used to wrap mid-row (the closing border landing on its
/// own visual line); it now stays one unbroken block, satisfying the "non-reflowing
/// graphic/char-array region" rule. Scattered single graphic chars amid ordinary prose
/// (legend lines like "UL: <char>  UR: <char>") are unaffected — `graphicRunRanges`'s
/// own shape requires closing on another graphic char with nothing but
/// graphic-chars-or-spaces in between, so it can never cross real letters.
func modernTokenize(_ text: String) -> [String] {
    let chars = Array(text)
    let n = chars.count
    var pieces: [String] = []
    var i = 0
    while i < n {
        if graphicChars.contains(chars[i]) {
            // The maximal graphic-run starting HERE — same algorithm as
            // `graphicRunRanges`'s own per-run scan, applied from this one start
            // position (matches `_GRAPHIC_RUN`'s greedy-then-backtrack-to-last-graphic
            // behavior when tried at this position in `finditer`).
            var j = i
            var lastGraphic = i
            while j < n, graphicChars.contains(chars[j]) || chars[j] == " " {
                if graphicChars.contains(chars[j]) { lastGraphic = j }
                j += 1
            }
            pieces.append(String(chars[i...lastGraphic]))
            i = lastGraphic + 1
        } else if chars[i] == " " {
            var j = i
            while j < n, chars[j] == " " { j += 1 }
            pieces.append(String(chars[i..<j]))
            i = j
        } else {
            var j = i
            while j < n, chars[j] != " " { j += 1 }
            pieces.append(String(chars[i..<j]))
            i = j
        }
    }
    return pieces
}

/// `(family, point size)` of the token that SETS a visual line's height — the largest one, the
/// same token the untightened `modernLine * max(size)` advance is measured from. Port of
/// `_modern_line_face`.
///
/// The family comes off the TOKEN, never re-derived here: `modernTokFont` has already applied
/// Modern's own face rule (planning #252) — a run no font block covers reads in Times at the
/// body size, unless the document declares fonts AND declares its type non-proportional
/// (`.ps off`), which puts an uncovered run in Courier. Those two faces have different natural
/// line heights and very different marker advances, so every measurement in this file's
/// tightening/hang rules inherits that one answer rather than Printed's unconditional
/// fixed-pitch default. The `(.times, modernBodyPt)` fallback is reached only by a line with NO
/// tokens at all — a paragraph whose runs were all zero-width note anchors, which draws no ink
/// either way.
func modernLineFace(_ vline: [ModernToken]) -> (family: PDFFamily, pt: Int) {
    var best: (pt: Int, family: PDFFamily)?
    for t in vline {
        let spt = sized(t.styles, t.pt).points
        if best == nil || spt >= best!.pt { best = (spt, t.family) }
    }
    guard let best else { return (.times, modernBodyPt) }
    return (best.family, best.pt)
}

/// A tightened (verse/centred) line's own height in points: the face's natural line height,
/// compressed by `modernVerseTight`. Port of `_modern_tight_h`.
///
/// `public` because Soft Return's Modern VIEW pins its own tightened line boxes to this
/// figure rather than letting AppKit multiply the face's natural metric — the same option-B
/// doctrine (planning #222, Jon) already applied to Modern's ordinary leading, extended to
/// the tightened line now that the library has a tightened line of its own to match. See
/// `DocumentRenderer.modernParagraphStyle`.
public func modernTightHeight(_ family: PDFFamily, _ pt: Int) -> Double {
    Double(pt) * modernNaturalLine(family) * modernVerseTight
}

/// How far BELOW a tightened line's own top edge its baseline sits. The compression comes off
/// the ascent and nothing else (see `modernFaceAscent`), so this is the face's full natural
/// ascent minus everything the tightening removed from the box. Port of
/// `_modern_tight_baseline`.
///
/// `public` because Soft Return's own Modern view computes its leading spacer from THIS
/// number and `inkTopPt`, rather than from AppKit's own placement and glyph-path bounds
/// (Jon, on the leading spacer: "Do it in the engine. Adopt it in Soft Return.") — see
/// `DocumentRenderer.modernAscentDeficit`.
public func modernTightBaseline(_ family: PDFFamily, _ pt: Int) -> Double {
    let natural = Double(pt) * modernNaturalLine(family)
    let ascent = Double(pt) * modernFaceAscent(family)
    return ascent - natural * (1.0 - modernVerseTight)
}

/// How far below a Modern line's own BASELINE the face descends, in points and POSITIVE — the
/// face's AFM `Descender`, negated. Port of `_modern_descent`.
///
/// This is the whole of the page baseline model backported in planning #263 (Jon's standing
/// principle, "the engine needs to work the way Soft Return does"; ledger 2026-09-11): Modern
/// stacks LINE BOXES down from the text frame's top edge, and a box's baseline sits
/// `h - descent` below its own top, not at its bottom. See `modernStreams`' own "THE PAGE
/// BASELINE MODEL" note for what that does and does not change.
///
/// An unmeasured face takes the TIMES row — the same rule, for the same two faces (Symbol,
/// ZapfDingbats), that `modernNaturalLine` and `modernFaceAscent` already state: Modern's own
/// default body face, named as a fallback rather than invented from a bounding box
/// (`afmDescenders` carries no entry for either, deliberately).
///
/// The face's bold/italic variant is not consulted: every Times variant publishes -217, every
/// Helvetica variant -207 and every Courier variant -157, so the roman's row IS the family's
/// row in the base-14.
func modernDescent(_ family: PDFFamily, _ pt: Int) -> Double {
    let roman = base14(family, bold: false, italic: false)
    return -(descenderPt(roman, pt) ?? descenderPt("Times-Roman", pt)!)
}

/// The highest point any glyph of these tokens actually PAINTS above the baseline, in points —
/// real outline extent (`inkTopPt`), never a nominal ascender, because a line of x-height
/// letters and a line carrying one parenthesis must not measure the same. Port of
/// `_modern_ink_above_baseline`.
///
/// A cp437 box/block/shade character is not a base-14 glyph at all: Modern draws it as a vector
/// cell, and `graphicOps` puts that cell's own top edge `(leadFactor - 0.25) * pt` above the
/// baseline — so its ink is taken from that geometry, the same place the drawing does, rather
/// than from the '?' cp1252 would substitute for it.
func modernInkAboveBaseline(_ toks: [ModernToken]) -> Double {
    var top = 0.0
    for tok in toks {
        if tok.text.trimmed().isEmpty { continue }
        let (spt, rise) = sized(tok.styles, tok.pt)
        var text = tok.text
        if text.contains(where: { graphicChars.contains($0) }) {
            top = max(top, Double(rise) + (modernLine - 0.25) * Double(spt))
            let plain = String(text.filter { !graphicChars.contains($0) })
            if plain.trimmed().isEmpty { continue }
            text = plain
        }
        let basefont = base14(tok.family, bold: tok.styles.contains(.bold),
                              italic: tok.styles.contains(.italic))
        top = max(top, Double(rise) + inkTopPt(text, basefont, spt))
    }
    return top
}

/// Job 434's leading spacer, in points — 0.0 for a line that needs none. Port of
/// `_modern_leading_spacer`.
///
/// A tightened line box is shorter than the face's natural one, and the whole of that
/// compression comes off the ascent, so a line whose real ink rises above where the baseline
/// now lands inside that shorter box would either clip against the top of the text frame (the
/// flow's very first line) or crowd the line above it. The room is reserved as an invisible
/// blank advance immediately BEFORE the line, never as space-after on its predecessor: only
/// the former survives being the first thing on a page, and only the former moves to the new
/// page WITH the line when one breaks.
///
/// Fires only on a TIGHTENED line (an untightened one is at the face's own natural height,
/// which already reserves its own ascender) and only when the deficit is genuinely positive;
/// `modernSpacerPad` is a fixed pad on top, not a derived figure.
func modernLeadingSpacer(_ toks: [ModernToken], _ family: PDFFamily, _ pt: Int) -> Double {
    let deficit = modernInkAboveBaseline(toks) - modernTightBaseline(family, pt)
    return deficit > 0 ? deficit + modernSpacerPad : 0.0
}

/// The vertical advance Modern actually spends on ONE tightened (verse/centred) line
/// built from `spans` — its compressed box plus the headroom reserved above it — in
/// points.
///
/// PUBLIC because Modern RTF needs the same number (planning #264 R3, Jon's ruling
/// 2026-09-14). `rtfVerseTightSlTwips` used to state the tightening as one fixed
/// multiple of the body size, which reproduced neither this engine's own Modern PDF nor
/// the app the PDF was backported from; measured through LibreOffice it also did
/// nothing at all, because a POSITIVE `\sl` is only a minimum and 1.15 × 14pt sits
/// under the reader's own single spacing for the face. An EXACT `\sl` has to carry a
/// real number, and the only real number is the one the page uses.
///
/// TWO PARTS, both of them `modernStreams`' own (see the `h` it stacks):
///
///   `modernTightHeight`    the compressed line box itself — the face's natural line
///                          height times `modernVerseTight`.
///   `modernLeadingSpacer`  job 434's headroom, spent as part of the line's own advance,
///                          which is why it belongs in the pitch a reader reproduces
///                          rather than beside it.
///
/// On STRENGTH.WS's title block (Times 14) that is 11.50 + 3.59 = 15.09pt, and 15.1pt is
/// exactly what the Modern PDF measures between that document's byline and its email
/// line. A reader honouring `\sl-302\slmult0` lands on the same pitch.
///
/// The spacer is ink-dependent, so two lines of the same face can differ by a fraction
/// of a point — that is the PDF's own behaviour, reproduced, not noise introduced here.
/// The C2 boundary is NOT part of this number: a blank line after a tightened block
/// advances by the body's ordinary leading (`modernStreams`' `lastH = lead`), and Modern
/// RTF resets `\sl` to 0 for exactly that reason. Port of
/// `pdf.modern_tight_line_advance_pt`.
public func modernTightLineAdvancePt(_ spans: [Span], fonts: [FontChange],
                                     nonpropFallback: Bool = false) -> Double {
    var toks: [ModernToken] = []
    for sp in spans {
        let f = modernTokFont(sp.text, font: sp.font, fonts: fonts,
                              nonpropFallback: nonpropFallback)
        toks.append(ModernToken(text: f.written, styles: sp.styles, family: f.family,
                                pt: f.pt, entry: f.entry, width: 0.0))
    }
    let face = modernLineFace(toks)
    return modernTightHeight(face.family, face.pt)
        + modernLeadingSpacer(toks, face.family, face.pt)
}

/// Is this flow entry a paragraph that draws at least one cp437 box/block/shade character?
/// (`modernStreams`' own suppression test — a box's vertical rule must read as one continuous
/// stroke, not a dashed one, so two graphic rows in a row get no spacer between them.) Port of
/// `_modern_para_is_graphic`.
func modernParaIsGraphic(_ item: ModernFlowItem) -> Bool {
    guard case .para(let toks, _, _, _, _, _, _, _, _, _) = item else { return false }
    return toks.contains { $0.text.contains(where: { graphicChars.contains($0) }) }
}

/// Whether this row refuses to wrap — job 456, the app's own rule.
///
/// The rule and its evidence are `graphicRowClips` (EmitterRules.swift), where planning
/// #264 item 3 (packet row B4) moved them so HTML can ask the same question — but NOT
/// with the same character set: THIS side asks the PDF's own `graphicChars` (the union of
/// the per-glyph drawing tables, arc corners and the peseta included), exactly as before
/// the move, while HTML asks `contentGraphicChars`. This is the token-shaped adapter:
/// read the row's FINAL tokens, after a centred row's padding has come off and a def
/// row's label/gap prefix has gone on. A clipped row is set as ONE line and runs past the
/// measure rather than reflowing (`modernStreams` gives it an unbounded wrap width) — the
/// app's `.byClipping`.
func modernClipsRow(_ toks: [ModernToken]) -> Bool {
    graphicRowClips(toks.map(\.text).joined(), graphicChars)
}

/// The sub-list of `runs` covering characters `[start, end)` of their own concatenated text,
/// each run's styles (and note reference) carried onto whatever piece of it survives. Port of
/// `_slice_runs`.
func sliceRuns(_ runs: [SemanticRun], _ start: Int, _ end: Int) -> [SemanticRun] {
    var out: [SemanticRun] = []
    var pos = 0
    for r in runs {
        let chars = Array(r.text)
        let n = chars.count
        let a = max(start, pos), b = min(end, pos + n)
        if b > a {
            let piece = String(chars[(a - pos)..<(b - pos)])
            if piece == r.text {
                out.append(r)
            } else {
                var copy = r
                copy.text = piece
                out.append(copy)
            }
        }
        pos += n
    }
    return out
}

/// `(prefix runs, body runs)` for one def-list row — its LABEL followed by a two-space gap,
/// then its body — or `nil` for a row whose recorded label/body no longer line up with its own
/// text. Port of `_modern_def_runs`.
///
/// A def row's raw text carries the author's own column padding between label and body (one
/// file pads to column 15 with eight spaces), which is typewriter geometry, not content:
/// Modern re-sets the row as a hanging label, so the padding is replaced by one structural
/// separator and the body's real start decides where the first line's text runs to. The
/// engine's HTML export makes the identical slice for the identical reason; this is the same
/// rule reaching the PDF.
///
/// Sliced by CHARACTER OFFSET against `structure`'s own recorded `label`/`body` lengths — the
/// counts the classifier took from this exact text — so styled spans crossing the boundary keep
/// their styles.
func modernDefRuns(_ runs: [SemanticRun], _ structure: RowStructure)
    -> (prefix: [SemanticRun], body: [SemanticRun])?
{
    let labelLen = (structure.label ?? "").count
    let bodyLen = (structure.body ?? "").count
    let raw = Array(runs.map(\.text).joined())
    let lead = raw.count - raw.drop(while: { $0 == " " }).count
    guard labelLen != 0, bodyLen != 0, lead + labelLen <= raw.count - bodyLen else { return nil }
    return (sliceRuns(runs, lead, lead + labelLen) + [SemanticRun(text: "  ")],
            sliceRuns(runs, raw.count - bodyLen, raw.count))
}

/// `(row start indent, continuation hang)`, both in points, for one structured def/bullet row.
/// The caller has already decided this IS one (a row with a `kind`, not centred — the centred
/// reading wins). Port of `_modern_structure_indent_hang`.
///
/// THE LADDER, where a row starts: `max(level - 1, 0)` steps of `modernLevelStepCols` past the
/// margin. Level 1 sits AT the margin. The row's own declared column (`structure.col`, the
/// block's `.lm` plus its residual indent) is deliberately not used — see `modernLevelStepCols`.
///
/// THE HANG, where a wrapped continuation lands, is per kind:
///   def     a fixed `modernDefHangPt` past the margin, shared by every row of the list.
///   bullet  the real measured advance of THIS row's own marker text in the face that draws it.
///           A points hang, not a column count, precisely because it has to line up with a
///           glyph: a marker and its gap never land on a whole number of monospace cells in a
///           proportional face, and a column-count hang put every wrapped line slightly past
///           its own first line's text start (Jon's b21 field note).
func modernStructureIndentHang(_ structure: RowStructure, colPt: Double, toks: [ModernToken],
                               printedPt: Int) -> (indent: Double, hang: Double) {
    let indent = Double(max(structure.level - 1, 0) * modernLevelStepCols) * colPt
    if structure.kind == .def { return (indent, modernDefHangPt) }
    // the marker text is the row's own first two characters (the glyph and the single space
    // after it — `classifyRows` only ever calls a glyph a marker when exactly that shape
    // holds), which the tokenizer may have split across several tokens
    var hang = 0.0
    var need = 2
    for tok in toks {
        let take = String(Array(tok.text).prefix(need))
        hang += take == tok.text
            ? tok.width
            : modernTokenWidth(take, styles: tok.styles, family: tok.family, pt: tok.pt,
                               entry: tok.entry, printedPt: printedPt)
        need -= take.count
        if need <= 0 { break }
    }
    return (indent, hang)
}

/// What the column-range recorder needs from `modernFlow` and nothing else does
/// (planning #276 follow-up, 2026-09-15).
///
/// `tokenOffsets` is keyed by FLOW index (not by semantic index, and not a parallel
/// array): only a `.para` item can be split mid-item by a column boundary, so only a
/// `.para` item has an entry, and a dictionary says that without asking every other
/// `flow.append` site below to remember to append an empty list beside it. Each value is
/// parallel to that item's own `toks`: the UTF-16 offset, into the SEMANTIC item's own
/// `runs.map(\.text).joined()`, that the token's text came from.
///
/// `itemCount` is `sem.items.count` — the exclusive end the document's last column range
/// reports, and not derivable from the flow (a trailing `.tabs` item produces no flow
/// entry at all).
struct ModernFlowSource {
    var tokenOffsets: [Int: [Int]] = [:]
    var itemCount = 0
}

/// A forward-only cursor over one semantic item's own `runs.map(\.text).joined()`, handing
/// each token the UTF-16 offset of the source text it draws.
///
/// WHY A SEARCH RATHER THAN ARITHMETIC. The tokens a `.para` item renders are not a
/// partition of its run texts: `sentenceSpacingRuns` rewrites a run's spaces, a def row's
/// label/gap/body is re-sliced out of the joined text (`modernDefRuns`), `modernTokFont`
/// transliterates a piece into a different string entirely, and `symbolFallbackSplit`
/// splits one piece into several. Counting characters through all of that would be a
/// second model of five transforms; searching FORWARD for the piece from where the last
/// one ended is one rule that is exact wherever the text survived a transform (the
/// overwhelming majority — the match is found at the cursor itself, so this is O(n) in
/// practice) and monotone, never backward, wherever it did not.
/// Searched over UTF-16 code units directly rather than through Foundation's
/// `String.range(of:)`: the offsets this reports ARE UTF-16 offsets (that is the unit the
/// apps index text in), and a code-unit comparison can never disagree with them the way a
/// canonical-equivalence match could.
struct ModernSourceCursor {
    private let units: [UInt16]
    private var at = 0

    init(_ text: String) {
        units = Array(text.utf16)
    }

    /// The offset `piece` was drawn from, and the cursor moved past it. A piece the
    /// source does not contain verbatim (a transliteration, a def row's synthetic
    /// two-space gap) leaves the cursor where it was and reports it — the next piece that
    /// DOES survive re-synchronises the walk.
    mutating func take(_ piece: String) -> Int {
        let needle = Array(piece.utf16)
        guard !needle.isEmpty, at + needle.count <= units.count else { return at }
        var i = at
        while i + needle.count <= units.count {
            var k = 0
            while k < needle.count, units[i + k] == needle[k] { k += 1 }
            if k == needle.count {
                at = i + needle.count
                return i
            }
            i += 1
        }
        return at
    }
}

/// The MEASURED Modern flow: `modernSemanticFlow`'s semantic items (the single
/// implementation of the M-rules — see `Layout.swift`'s contract) converted to this
/// emitter's tokens. This adapter adds exactly what a PDF needs — font resolution, AFM
/// widths, points — and decides nothing about WHAT renders: that is the semantic layer's
/// job, shared with the app's native text stack and the `layout` JSON emitter. Port of
/// `_modern_flow` (post-facade, task #15).
///
/// `pixResults`/`pictures` (b24 round 22, closing round 19's documented Modern scope
/// cut): a para whose runs are exactly one resolved, decoded pix placeholder becomes an
/// `.image` item, sized by the same shared rule as the Printed paths (`pixDimsPt`:
/// print-options record when present, else fit to `textWidthPt` at source aspect,
/// capped at the measure). A run carrying a note reference counts as real content
/// (anchors are never silently dropped), so such a line keeps its placeholder text —
/// same never-drop rule as `spansPixSubstitution`.
///
/// `sentenceSpacing` (N9, b33 field notes): pre-resolved bool (`true` = 'single'),
/// applied to a paragraph's own run texts and a note's own text HERE, in this PDF-only
/// adapter, never inside `modernSemanticFlow` itself — the shared `sem` this function
/// builds is also the `layout` JSON emitter's own contract, and that schema does not
/// move for this ruling (register: schema moves only when both engines move together).
/// The JSON emitter therefore always serializes the document's own unconverted text; a
/// consumer (this adapter, the app's native text stack) applies sentence-spacing on
/// top, same as every other `modernFlow` option that never reaches the semantic items.
/// `semIndexOfItem` (planning #251 follow-up, 2026-09-10): `nil` to record nothing (every
/// ordinary render call), a real (empty) array to fill with, for each element of the
/// returned `[ModernFlowItem]` IN ORDER, the index into `sem.items` (this function's own
/// internal `modernSemanticFlow(doc, ...)` result) that produced it -- the provenance
/// `attachGraphicCellsModern` needs to attribute a wrapped/paginated visual line's own
/// graphic cells back to the SEMANTIC item (`layout` JSON's own `modern.items` entry) it
/// came from. `.tabs` is the one `sem.items` entry that produces NO `flow` entry at all
/// (an editor-time-only item, `continue`d before any append below) -- every other case
/// appends exactly one `flow` entry per `sem.items` entry, in the same order, so this is
/// pure bookkeeping alongside the existing loop, never a parallel re-derivation of what
/// that loop already decides.
///
/// `blockIndexOfItem` (Jon's ruling 2026-09-15, Modern columns): the same shape, one
/// entry per element of the returned flow -- the `doc.blocks` index that produced it
/// (`SemanticItem.para` already carries `bi`), or `nil` for an item that has no block of
/// its own (a blank, a break, a running-head change, an end-matter note).
/// `modernStreams` reads the `.co n` regime in force, and the `.cb` column breaks sitting
/// between two blocks, off the IR with it. An out-parameter for the same reason
/// `semIndexOfItem` is one: the item values ARE the `layout` JSON contract, and this
/// ruling moves no schema.
///
/// `src` (planning #276 follow-up, 2026-09-15): `nil` for every ordinary render call,
/// otherwise filled with what `ModernColumnRange` needs and nothing else does — see
/// `ModernFlowSource`. Gated, because its per-token source-offset walk is real work
/// (`ModernSourceCursor`) that an export has no use for.
func modernFlow(_ doc: Document, keep: Set<NoteKind>,
                noteRefs: NoteRefs = .word, pixResults: [PixResult] = [],
                pictures: EmitOptions.PixMode = .off,
                textWidthPt: Double = 0.0, sentenceSpacing: Bool = false,
                semIndexOfItem: inout [Int]?,
                semCached: SemanticFlow? = nil,
                blockIndexOfItem: inout [Int?]?,
                src: UnsafeMutablePointer<ModernFlowSource>? = nil) -> [ModernFlowItem] {
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    // planning #254: the document's own fixed-pitch size, for a graphic character's cell
    // advance ONLY (`modernTokenWidth`'s own `printedPt` doc comment) -- never the Modern
    // reading size.
    let printedPt = printedSize(doc)
    // `semCached` (perf, planning #271 M7): the caller already ran
    // `modernSemanticFlow` with the SAME `keep`/`noteRefs` and kept its answer —
    // `emitLayout` does, for the JSON's own `modern.items`, one call before it asks
    // `attachGraphicCellsModern` for the cells. Re-deriving the whole semantic flow
    // there is the single largest avoidable cost in the `layout` format on a
    // novel-length document (-HOLYMAC.WS, 302 pages: 0.45s of 2.09s). The flow is
    // READ here, never mutated, so sharing one is exact, not approximate; a caller
    // that cannot promise the same arguments passes nothing and gets a fresh call.
    let sem = semCached ?? modernSemanticFlow(doc, notes: keep, noteRefs: noteRefs)
    src?.pointee.itemCount = sem.items.count
    // one WordStar column in points, at the document's own `.cw`
    let colPt = (doc.page?.cw120 ?? 12.0) * 0.6
    let blankH = modernLine * Double(modernBodyPt)
    // b26-modern item 3 (screenplay ruling, BUILD-SLATES.md item 27, Jon's decided
    // ruling): computed once, not per-line -- `detectScreenplayBlocks` already walks
    // the whole document itself.
    let screenplayBlocks = detectScreenplayBlocks(doc)
    // The page-marker rule (a)/(b) needs one more block index than `screenplayBlocks`
    // itself carries: a real screenplay's own page-number marker sits BEFORE its
    // scene's slugline (SCRIPT.WS's own shape -- the marker block immediately precedes
    // the slugline block that anchors the detected region), but
    // `detectScreenplayBlocks`'s region growth is documented to extend only FORWARD
    // from its slugline anchor, never backward, so the marker's own block index is
    // never a member of `screenplayBlocks`. Widen candidacy by one or two blocks
    // forward (covering an intervening blank-only block) rather than touching the
    // shared detector's own region-growth rule, which carries its own zero-false-
    // positive corpus gate this wave must not risk.
    let screenplayMarkerBis: Set<Int> = screenplayBlocks.isEmpty ? [] : Set(
        (0..<doc.blocks.count).filter {
            screenplayBlocks.contains($0 + 1) || screenplayBlocks.contains($0 + 2)
        })
    // planning #252 (Jon's ruling 2026-09-09): resolved ONCE per document, not per
    // token -- see `modernTokFont`'s own doc comment for the full reasoning. Ported
    // from ctrl-kd pdf.py's identical `nonprop_fallback` local, added the same round.
    let nonpropFallback = !doc.fonts.isEmpty && doc.formatting.proportional == false
    var flow: [ModernFlowItem] = []
    for (semI, item) in sem.items.enumerated() {
        switch item {
        case .blank:
            flow.append(.blank(blankH))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .pageBreak:
            flow.append(.pageBreak)
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .cond(let lines):
            flow.append(.cond(lines))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .hf(let which, let line, let text):
            flow.append(.hf(kind: which, line: line, text: text))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .tabs:
            continue          // editor-time state: no rendered consequence (task #19)
        case .noteSeparator:
            let separator = String(repeating: "-", count: 20)
            let sepW = stringWidthPt(separator, "Times-Roman", modernNotePt)
            // endNotesStart: true -- layout.swift's modernSemanticFlow emits exactly one
            // .noteSeparator, always immediately before the first .note item, when the
            // document has any end-matter notes at all. Jon's ruling 2026-09-07 fires on
            // this flag in modernStreams.
            flow.append(.para(toks: [ModernToken(text: separator, styles: [], family: .times,
                                                 pt: modernNotePt, entry: nil, width: sepW)],
                              align: .left, notes: [], indent: 0.0, cut: 0.0,
                              noWrap: false, pageMarker: false, endNotesStart: true,
                              tight: false, hang: 0.0))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .note(let ni, _, let label, let text):
            let noteText = sentenceSpacing ? sentenceSpacingTexts([text])[0] : text
            flow.append(.para(toks: modernNoteToks(label: label, text: noteText,
                                                    kind: sem.notes[ni].kind),
                              align: .left, notes: [], indent: 0.0, cut: 0.0,
                              noWrap: false, pageMarker: false, endNotesStart: false,
                              tight: false, hang: 0.0))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(nil)
        case .para(let align, let indentCols, let cutCols, let runs, let footnotes,
                  let structure, let isVerse, let bi):
            if embedImages, !runs.contains(where: { $0.ref != nil }),
               let sub = spansPixSubstitution(runs.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                flow.append(.image(pixIndex: sub.pixIndex, widthPt: sub.wPt,
                                   heightPt: sub.hPt))
                semIndexOfItem?.append(semI)
                blockIndexOfItem?.append(bi)
                continue
            }
            // planning #263: a def row renders as LABEL + a two-space gap + body, not as
            // the author's own raw column padding -- see `modernDefRuns`. Done here,
            // BEFORE the N9 collapse below, because the slice offsets are character
            // counts the structure classifier took from the untransformed text;
            // collapsing a space first shortens the text without shortening the counts
            // and drags the gap into the body.
            var paraRuns = runs
            var fixedRuns: [SemanticRun] = []
            if let structure, !structure.centered, structure.kind == .def,
               let split = modernDefRuns(paraRuns, structure) {
                fixedRuns = split.prefix
                paraRuns = split.body
            }
            // N9: applied to the run texts, in order, same cross-piece state-carrying as
            // every other emitter's own choke point -- the pix-substitution check above
            // already ran on the RAW runs (a structural placeholder match, not prose).
            // The label/gap prefix above is exempt: it is structure, not prose, and its
            // two-space gap is a deliberate separator that must survive a label ending in
            // a sentence-ending character.
            if sentenceSpacing { paraRuns = sentenceSpacingRuns(paraRuns) }
            var toks: [ModernToken] = []
            // Parallel to `toks` from here to the `flow.append` below, INCLUDING the
            // padding strips further down -- every `toks.removeFirst()`/`removeLast()`
            // takes this array's own element with it, or an offset would be reported
            // against the wrong token. Left EMPTY (and every write to it skipped) when
            // nothing asked for the provenance, so an ordinary export allocates nothing
            // and runs no cursor: hence the `isEmpty` guards on the two strips, which are
            // the only places the two arrays could fall out of step.
            var tokOff: [Int] = []
            var cursor = src != nil ? ModernSourceCursor(runs.map(\.text).joined()) : nil
            for run in fixedRuns + paraRuns {
                var styles = run.styles
                if run.ref != nil {
                    if run.text.isEmpty {
                        // a zero-width comment anchor (round 22, Layout.swift's run
                        // contract): position data for Show Invisibles, no ink on
                        // paper -- skipping it keeps Modern PDF bytes exactly what
                        // they were
                        continue
                    }
                    // a reference mark: Times at the body size, measured as-is
                    styles.insert(.fnref)
                    let width = modernTokenWidth(run.text, styles: styles, family: .times,
                                                 pt: modernBodyPt, entry: nil, printedPt: printedPt)
                    toks.append(ModernToken(text: run.text, styles: styles, family: .times,
                                            pt: modernBodyPt, entry: nil, width: width))
                    if cursor != nil { tokOff.append(cursor!.take(run.text)) }
                    continue
                }
                for piece in modernTokenize(run.text) {
                    // Taken ONCE per source piece: a fallback split below turns one piece
                    // into several tokens, and all of them are drawn from the same place
                    // in the source.
                    let pieceOff = cursor != nil ? cursor!.take(piece) : 0
                    let resolved = modernTokFont(piece, font: run.font, fonts: doc.fonts,
                                                 nonpropFallback: nonpropFallback)
                    // round 2026-09-07 (ported from ctrl-kd pdf.py's b26-modern item 4):
                    // a token whose family isn't already Symbol/ZapfDingbats may still
                    // carry cp437 Greek/math/Dingbats bytes cp1252 can't encode -- same
                    // fallback Printed's `splitSymbolFallback` applies, factored out
                    // (`symbolFallbackSplit`) so both paths share one answer.
                    let fbPieces: [(text: String, family: PDFFamily)] =
                        (resolved.family == .symbol || resolved.family == .zapfDingbats)
                        ? [(resolved.written, resolved.family)]
                        : symbolFallbackSplit(resolved.written, family: resolved.family)
                    for (fbText, fbFamily) in fbPieces {
                        let width = modernTokenWidth(fbText, styles: styles,
                                                     family: fbFamily, pt: resolved.pt,
                                                     entry: resolved.entry, printedPt: printedPt)
                        toks.append(ModernToken(text: fbText, styles: styles,
                                                family: fbFamily, pt: resolved.pt,
                                                entry: resolved.entry, width: width))
                        if cursor != nil { tokOff.append(pieceOff) }
                    }
                }
            }
            // b26-modern item 3 (screenplay ruling): only lines inside a DETECTED
            // screenplay region (or immediately preceding one, for the page-marker
            // case -- see `screenplayMarkerBis` above) are even candidates -- an
            // ordinary document's own numbered list or table never qualifies, same
            // discipline as the emitters' own `bi in screenplayBlocks` gate.
            var lineAlign = align
            var noWrap = false
            var pageMarker = false
            if screenplayBlocks.contains(bi) || screenplayMarkerBis.contains(bi) {
                let visible = Array(runs.filter { $0.ref == nil }.map(\.text).joined())
                if matchesScreenplayPageMarker(visible) {
                    // "1." alone at the top of a real screenplay page: render flush
                    // against the right margin, below the header -- rule (b). Leading
                    // whitespace tokens stay in `toks` untouched: `modernLineOps`'s own
                    // right-align spends them as blank advance before the visible
                    // glyph, landing it flush regardless of how much leading space the
                    // source typed.
                    pageMarker = true
                    lineAlign = .right
                } else if screenplayBlocks.contains(bi),
                          matchesScreenplaySlugline(visible),
                          matchesScreenplayTrailingSceneNumber(visible) {
                    // A slugline carrying its own right-hand scene number (real
                    // screenplay convention: the number repeats at both margins) must
                    // never wrap the number onto its own line -- rule (c).
                    // `modernStreams` gives this line an unbounded wrap width instead
                    // of reflowing per-token widths differently. (`bi in
                    // screenplayBlocks` specifically -- a marker-lookahead block is
                    // never also a slugline.)
                    noWrap = true
                }
            }
            let notes = footnotes.map { fn -> (index: Int, label: String, text: String) in
                let noteText = sem.notes[fn.index].text
                return (index: fn.index, label: fn.label,
                       text: sentenceSpacing ? sentenceSpacingTexts([noteText])[0] : noteText)
            }
            // planning #263. THREE mutually exclusive readings of one row, in the app's
            // own order -- a centred structured row first, a def/bullet row next, an
            // ordinary paragraph last:
            //
            //   centred structured row  tightens, unconditionally. This is a separate
            //       path from the plain-paragraph one below and fires on rows that one
            //       never sees (an undeclared, spaces-padded centred line keeps
            //       `align == .left`).
            //   def/bullet row          takes the indent LADDER and its own HANG, and is
            //       never tightened.
            //   plain paragraph         tightens when it is centred or when it is part of
            //       a verse/stanza unit -- the SAME condition Modern RTF and Modern HTML
            //       already apply.
            var indent = indentCols.value * colPt
            let cut = cutCols.value * colPt
            var hang = 0.0
            var tight = false
            if structure?.centered == true {
                tight = true
                // UNDECLARED CENTRING IS STILL CENTRING (the app's b17 rule, ported here):
                // a line the author centred by TYPING leading spaces carries no `.oc` and
                // no align tag at all, so it arrives `align == .left` with its padding
                // still in the text. Rendered as-is in a proportional face the padding
                // became an arbitrary indent AND spent measure, so the row both sat
                // off-centre and wrapped early. The classifier has already decided this row
                // reads as centred (`classifyRows`: symmetric padding, at least 2 leading
                // columns, not the document's own routine paragraph indent, at least 4
                // columns of slack, at most one wide internal gap, no internal tab run) --
                // so the padding comes off and the row is centred on its own measure.
                //
                // A tag-declared centred row (`centerVia == .tag`) reaches this same branch
                // and is unaffected: `modernSemanticFlow` stripped that padding upstream
                // (M3) and its align is already `.center`, so both steps below are no-ops.
                // The whole effect is on undeclared, spaces-padded rows.
                lineAlign = .center
                while let first = toks.first, first.text.trimmed().isEmpty {
                    toks.removeFirst()
                    if !tokOff.isEmpty { tokOff.removeFirst() }
                }
                while let last = toks.last, last.text.trimmed().isEmpty {
                    toks.removeLast()
                    if !tokOff.isEmpty { tokOff.removeLast() }
                }
            } else if let structure, structure.kind != nil {
                // the ladder REPLACES the block's own `.lm` indent (that is the whole
                // point of it), so the row's residual leading spaces go with it -- left
                // in, they would push a level-1 row off the margin the ladder just put it
                // on. Dropped BEFORE the hang is measured: a bullet's hang is the advance
                // of the row's own first two characters, which are its marker and gap only
                // once the padding is gone.
                while let first = toks.first, first.text.trimmed().isEmpty {
                    toks.removeFirst()
                    if !tokOff.isEmpty { tokOff.removeFirst() }
                }
                (indent, hang) = modernStructureIndentHang(structure, colPt: colPt, toks: toks,
                                                          printedPt: printedPt)
            } else {
                tight = lineAlign == .center || isVerse
                // A ONE-SIDED `.lm` IS NOT A STYLE (Jon's b17 ruling, the same family as
                // the ladder above, one level up: there the trap was a ROW's own declared
                // column, here it is a whole PARAGRAPH's declared margin). WordStar leaves
                // a `.lm` open until something closes it, so an ordinary paragraph
                // downstream of one inherits an indent nobody styled -- the document whose
                // intro paragraph sits at its own residual `.lm 15` with no `.rm` anywhere
                // near it. An ordinary paragraph starts at Modern's own margin, period,
                // UNLESS it is a genuine two-sided block quote: BOTH margins narrowing the
                // measure is a deliberate style, and keeps its declared indent.
                //
                // `.rm` IS ALWAYS HONOURED, and the asymmetry is the point: the ruling's
                // whole argument is that a left margin left open upstream reaches
                // paragraphs nobody styled. A narrowed RIGHT margin has no such failure
                // mode -- it is what sets the measure every line is broken at -- so
                // dropping it would not restore Modern's own margin, it would WIDEN the
                // paragraph past the one the author asked for and move every wrap in the
                // block.
                if !(indent > 0 && cut > 0) { indent = 0.0 }
            }
            // A GRAPHIC ROW DOES NOT WRAP (job 456 -- `modernClipsRow`). Decided last, on
            // this row's own FINAL tokens: a centred row has shed its padding and a def row
            // has gained its label/gap prefix by now, and the rule reads the text the page
            // will actually carry. Never clears a `noWrap` an earlier rule set.
            noWrap = noWrap || modernClipsRow(toks)
            if src != nil { src!.pointee.tokenOffsets[flow.count] = tokOff }
            flow.append(.para(toks: toks, align: lineAlign, notes: notes,
                              indent: indent, cut: cut,
                              noWrap: noWrap, pageMarker: pageMarker, endNotesStart: false,
                              tight: tight, hang: hang))
            semIndexOfItem?.append(semI)
            blockIndexOfItem?.append(bi)
        }
    }
    return flow
}

/// N9 (b33 field notes): `sentenceSpacingTexts` applied to a list of `SemanticRun`s,
/// every other field preserved -- `modernFlow`'s own local analogue of
/// `sentenceSpacingSpans` (Block.swift). Kept local to this file rather than made
/// generic over `SemanticRun`: that type (Layout.swift) also backs the shared `layout`
/// JSON contract, and this transform must never reach it (see `modernFlow`'s own doc
/// comment — layout.py's schema does not move for this ruling).
private func sentenceSpacingRuns(_ runs: [SemanticRun]) -> [SemanticRun] {
    let texts = sentenceSpacingTexts(runs.map(\.text))
    return zip(runs, texts).map { r, t in
        guard t != r.text else { return r }
        var out = r
        out.text = t
        return out
    }
}

/// Greedy wrap of one logical line's tokens -> visual lines. Leading whitespace stays
/// (paragraph indent); a space token at a wrap point is swallowed, exactly as any renderer
/// would. Port of `_modern_wrap`.
///
/// `hang` (planning #263): a structured row's own continuation indent. A hang moves every line
/// after the first to the right WITHOUT moving the right edge, so those lines wrap at a measure
/// narrower by exactly that much — the same thing a head-indent does in any real text stack,
/// and the reason a hang changes a row's line COUNT as well as its look.
///
/// `indices` (planning #276 follow-up, 2026-09-15): `nil` to record nothing (every caller
/// but the column-range recorder), otherwise filled with the `toks` INDEX of each token
/// kept on each visual line — the same nesting as the returned lines, one index per token.
/// A swallowed wrap-point space contributes no index, which is exactly what makes this
/// usable as a source map: the first index of line `vi` is the token that STARTS that
/// line, and `ModernColumnRange`'s own `startOffset` is that token's source offset. Stated
/// as an out-parameter on the one wrap definition rather than as a second index-only wrap
/// function: a second copy of this greedy loop is a drift waiting to be found in a column
/// that filled differently from the page that drew it.
func modernWrap(_ toks: [ModernToken], width: Double, hang: Double = 0.0,
                indices: UnsafeMutablePointer<[[Int]]>? = nil) -> [[ModernToken]] {
    var lines: [[ModernToken]] = []
    var cur: [ModernToken] = []
    var idxLines: [[Int]] = []
    var idxCur: [Int] = []
    var curw = 0.0
    for (ti, tok) in toks.enumerated() {
        let hasInk = !tok.text.trimmed().isEmpty
        let limit = lines.isEmpty ? width : max(36.0, width - hang)
        if !cur.isEmpty, curw + tok.width > limit, hasInk {
            lines.append(cur)
            cur = []
            if indices != nil { idxLines.append(idxCur); idxCur = [] }
            curw = 0.0
        }
        if cur.isEmpty, !hasInk, !lines.isEmpty {
            continue                          // swallow the wrap-point space
        }
        cur.append(tok)
        if indices != nil { idxCur.append(ti) }
        curw += tok.width
    }
    if !cur.isEmpty || lines.isEmpty {
        lines.append(cur)
        if indices != nil { idxLines.append(idxCur) }
    }
    indices?.pointee = idxLines
    return lines
}

/// One note as its Modern entry tokens, Times `modernNotePt`.
///
/// Footnote/endnote entries (ruling 2026-08-23/24, Jon verbatim: "1. Footnoote. and i.
/// Endnote. No brackets. No superscript"): `LABEL. text` — `label` arrives here already
/// in its final display form (arabic for a footnote, lower-roman for an endnote under
/// the `word` scheme — see `shownLabels`/`endnoteRomanLabel`), so this only has to drop
/// the brackets in favour of a period. Annotation/comment entries are UNCHANGED by that
/// ruling (it named only footnote/endnote appearance) and keep the pre-existing
/// `[label]` bracket form — their label is a WordStar tag or a running count, not a
/// number, and nothing in the register asked for their look to change. Port of
/// `_modern_note_toks`.
func modernNoteToks(label: String, text noteText: String, kind: NoteKind = .footnote) -> [ModernToken] {
    let text = (kind == .footnote || kind == .endnote)
        ? "\(label). \(noteText)" : "[\(label)] \(noteText)"
    var toks: [ModernToken] = []
    for piece in splitKeepingSpaceRuns(text) {
        let width = stringWidthPt(piece, "Times-Roman", modernNotePt)
        toks.append(ModernToken(text: piece, styles: [], family: .times, pt: modernNotePt,
                                entry: nil, width: width))
    }
    return toks
}

/// A page-bottom note as wrapped visual lines of Times `modernNotePt`. Page-bottom notes
/// are always FOOTNOTES (endnotes/annotations collect at the document end instead — M1,
/// see this file's module docstring), so `kind` defaults to `.footnote` here; threaded
/// through anyway for the same reason `modernNoteToks` takes it. Port of
/// `_modern_note_lines`.
func modernNoteLines(label: String, text: String, width: Double, kind: NoteKind = .footnote) -> [[ModernToken]] {
    modernWrap(modernNoteToks(label: label, text: text, kind: kind), width: width)
}

/// One modern running-head/foot line: Times `modernNotePt` in the margin zone, WordStar's
/// `#` token as the page number (same rule as printed: `.op` never suppresses an explicit
/// `#`). The header keeps its own baked spaces — that is how a 1990 head positioned its
/// parts, and a running head is a page fixture, not reflowing text. Raw toggle bytes in
/// the stored head (`^B` bold and friends — LJ6DTP's `.h1`) are interpreted as styles via
/// `hfRuns`, so measurement and drawing agree; letters overlapped when the toggles were
/// measured as glyphs (M10). Port of `_modern_hf_ops`.
/// `printedPt` (planning #254): threaded to `modernLineOps` only for the graphic-cell
/// cases neither header nor footer text has ever been observed to carry -- see that
/// parameter's own doc comment.
///
/// `align`: the line's own declared alignment, resolved by `modernHFAlign` — `.left`
/// unless the document's own `.h#`/`.f#` style says centre or right, in which case the
/// line is centred or right-aligned in MODERN's measure (`left` to `left + width`), never
/// against a `.po` or a style margin Modern does not have. A head keeps its own baked
/// spaces either way, because that is how a 1990 head positioned its parts; a
/// left-aligned line is therefore byte-identical to every version of this function before
/// alignment was read at all. WordStar's own AUTOMATIC page number passes `.center`
/// directly (M15): it has no typed spaces to honour, and Modern's own reading of "bottom
/// centre" is a real centring in Modern's measure, not Printed's `.pc` column.
///
/// Which family `modernHFAlign` reads.
enum ModernHFKind { case header, footer }

/// One running head/foot line's own alignment, for Modern. Port of `_modern_hf_align`.
///
/// M5 ruled that Modern keeps the running heads; nothing ever ruled that it flattens
/// them. Every head and foot line was drawn left at Modern's own left margin whatever its
/// own `.h#`/`.f#` style declared, so `sawyer/REF/BOOKLET.WS`'s right-aligned "Header
/// Odd" sat on top of its left-aligned "Header Even" at the same x — and its own Modern
/// RTF, which has carried `\qr` since planning #264 item 4 (row A4), said otherwise.
/// Modern PDF is ruled to be that RTF's printed form (2026-08-05), so the two have to
/// agree.
///
/// WHAT IT ALIGNS AGAINST IS MODERN'S, not WordStar's. M16's rule — an aligned head
/// aligns to `.po` plus ITS OWN STYLE's right margin — is a PRINTED-fidelity rule about a
/// WordStar page this view does not draw: Modern has no `.po` and no style margin, it has
/// its own measure. So the DECISION ("this line is right-aligned") is the document's,
/// read from the same `headerAlign`/`footerAlign` the Printed path and the RTF both read,
/// and the GEOMETRY is Modern's — `margl` to `margl + width`, exactly as a body line's
/// own alignment resolves.
///
/// PARITY IS NOT READ HERE, and is not this rule's gap: Modern's flow carries no parity
/// at all (`modernFlow`'s own `hf` items are keyed by line number, never by side), so a
/// `.h1o`/`.h1e` document already shows one flat head on both sides in Modern. Reading
/// the flat `headerAlign` alongside the flat head TEXT keeps the two consistent; reading
/// the parity table here would align a line the other side's text. Pre-existing, named,
/// untouched.
func modernHFAlign(_ doc: Document, _ which: ModernHFKind, _ lno: Int) -> Alignment {
    let align = (which == .header ? doc.headerAlign : doc.footerAlign)[lno]
    return (align == .center || align == .right) ? align! : .left
}

/// One running head/foot line's own Modern tokens -- `#` substituted for `pageNo`,
/// toggle-byte runs kept, in the Times face and `modernNotePt` size Modern's furniture
/// uses. Split out so `modernPageFurniture` reports the SAME text and the same measured
/// width the drawn line has (`modernPlaceLine`), never a re-derivation of either.
func modernHFToks(_ txt: String, pageNo: Int) -> [ModernToken] {
    var toks: [ModernToken] = []
    for run in hfRuns(txt) {
        let runText = run.text.replacingAll("#", with: String(pageNo))
        for piece in splitKeepingSpaceRuns(runText) {
            let basefont = base14(.times, bold: run.styles.contains(.bold),
                                  italic: run.styles.contains(.italic))
            let w = stringWidthPt(piece, basefont, modernNotePt)
            toks.append(ModernToken(text: piece, styles: run.styles, family: .times,
                                    pt: modernNotePt, entry: nil, width: w))
        }
    }
    return toks
}

func modernHFOps(_ txt: String, pageNo: Int, left: Double, y: Double, width: Double,
                 res: FontResources, tzState: inout Int, printedPt: Int,
                 align: Alignment = .left) -> [[UInt8]] {
    let toks = modernHFToks(txt, pageNo: pageNo)
    if toks.isEmpty { return [] }
    var discardedGraphicCells: [PageLine.GraphicCellPlacement]? = nil
    return modernLineOps(toks, left: left, y: y, width: width, align: align,
                         res: res, tzState: &tzState, printedPt: printedPt,
                         recordGraphicCells: &discardedGraphicCells)
}

/// Where one Modern visual line STARTS, and the tokens that survive to be drawn --
/// trailing whitespace tokens trimmed, then `left` shifted by the line's own alignment
/// inside `width`.
///
/// ONE DEFINITION, two readers: `modernLineOps` draws from it, and
/// `modernPageFurniture` reports the very same x to the apps without re-deriving it.
/// Extracting it is what lets that accessor be an answer about the drawn page rather
/// than a second opinion about it.
///
/// `neumaierSum`, not a plain `reduce(+)`: the reference is Python's `sum()`, which on
/// CPython 3.12+ compensates float error exactly the way this helper does, and a naive
/// left-to-right total differs from it in the last bits. That used to be invisible -- a
/// left-aligned line never spends `lineWidth` on a drawn coordinate -- but a CENTRED
/// line's own start is `left + (width - lineWidth) / 2`, so one ULP here can move a
/// later token across a `%.1f` rounding boundary and print an x 0.1pt away from the
/// reference's. Measured: a 21-token row summing to 327.768 naively and to
/// 327.76800000000003 compensated, which moved three drawn x values on one archive
/// document. Same reason `PDFWriter.swift`'s own justification total already uses it.
func modernPlaceLine(_ toksIn: [ModernToken], left: Double, width: Double,
                     align: Alignment) -> (x: Double, toks: [ModernToken]) {
    var toks = toksIn
    var lineWidth = neumaierSum(toks.map(\.width))
    while let last = toks.last, last.text.trimmed().isEmpty {
        lineWidth -= last.width
        toks.removeLast()
    }
    var x = left
    if align == .center {
        x += max(0.0, (width - lineWidth) / 2)
    } else if align == .right {
        x += max(0.0, width - lineWidth)
    }
    return (x, toks)
}

/// Content-stream ops for one modern visual line. One op per word keeps a viewer's
/// substitute-metric drift bounded, same as printed. Port of `_modern_line_ops`.
///
/// `printedPt` (planning #254, 2026-09-10): the document's own fixed-pitch type size
/// (`printedSize(doc)`) -- see `modernTokenWidth`'s own doc comment for the full rule
/// and the bug this closes (a graphic row's own cell advance must never depend on the
/// Modern reading size). Threaded (not recomputed -- no `doc` reaches this function)
/// from every real caller: `modernStreams` (body/footnote lines) and `modernHFOps`
/// (running heads/feet), and through this function's own recursive sub-calls below so a
/// graphic run split across several sub-calls always agrees with the piece that measured
/// it in `modernTokenWidth`.
///
/// `recordGraphicCells` (planning #251 follow-up, 2026-09-10): same contract as
/// `PDFWriter.swift`'s own `lineOpsPrinted` parameter of the same name -- `nil` to
/// record nothing (every ordinary render call), a real array to APPEND this call's own
/// cp437 graphic-character placements to (never cleared first: a caller collecting
/// across several calls, as `attachGraphicCellsModern` does across a paragraph's own
/// wrapped visual lines, gets one running list). Threaded through this function's own
/// recursive sub-calls (the non-graphic pieces flanking a graphic run) so every call
/// site stays source-compatible with a single required argument, even though those
/// particular sub-calls never themselves append anything (a piece `graphicRunRanges`
/// extracts BETWEEN two runs is, by construction, never itself a graphic run).
func modernLineOps(
    _ toksIn: [ModernToken], left: Double, y: Double, width: Double, align: Alignment,
    res: FontResources, tzState: inout Int, printedPt: Int,
    recordGraphicCells: inout [PageLine.GraphicCellPlacement]?
) -> [[UInt8]] {
    let placed = modernPlaceLine(toksIn, left: left, width: width, align: align)
    let toks = placed.toks
    var x = placed.x
    var ops: [[UInt8]] = []
    for tok in toks {
        let (spt, rise) = sized(tok.styles, tok.pt)
        let basefont = base14(tok.family, bold: tok.styles.contains(.bold),
                              italic: tok.styles.contains(.italic))
        let font = res.ref(basefont)
        if tok.text.contains(where: { graphicChars.contains($0) }) {
            // split mixed tokens: graphic runs draw as vectors at the cell advance,
            // interleaved text renders through the normal (recursive) path (fontless
            // spans included under Modern -- round 3, 2026-08-06 M11)
            let entry = tok.entry
            let pitch = spanPitch(entry, printedPt)
            let chars = Array(tok.text)
            var pos = 0
            var gx = x
            for range in graphicRunRanges(chars) {
                if range.lowerBound > pos {
                    let piece = String(chars[pos..<range.lowerBound])
                    let pieceWidth = modernTokenWidth(piece, styles: tok.styles,
                                                      family: tok.family, pt: tok.pt, entry: entry,
                                                      printedPt: printedPt)
                    let pieceTok = ModernToken(text: piece, styles: tok.styles, family: tok.family,
                                               pt: tok.pt, entry: entry, width: pieceWidth)
                    ops += modernLineOps([pieceTok], left: gx, y: y, width: width, align: .left,
                                         res: res, tzState: &tzState, printedPt: printedPt,
                                         recordGraphicCells: &recordGraphicCells)
                    gx += pieceWidth
                }
                let run = String(chars[range])
                // b32: Modern's own line-to-line advance is exactly `modernLine * pt`
                // (`PDFModernLayout`'s own uniform per-vline `h`) -- pass it as the
                // glyph cell's height too, so a box-drawing arm's vertical stroke
                // chains continuously across physical lines instead of leaving
                // `graphicOps`'s Printed-tuned default gap (see `graphicOps`'s own
                // doc comment).
                ops += graphicOps(run, x: gx, y: y, pitch: pitch, pt: spt, leadFactor: modernLine)
                // planning #251 follow-up (2026-09-10): the model's own per-cell x/width
                // -- same "recorded here, the ONE place this run's per-character cell
                // positions are ever computed" precedent `lineOpsPrinted`'s own
                // `recordGraphicCells` doc comment states. `widthIsWholePointPitch` is
                // always `false` here now (planning #254): `pitch` is always
                // `spanPitch`'s own Double, entry or no -- the old `wholePitch` branch
                // this comment used to describe tracked a since-removed code path that
                // advanced a fontless run's graphic cells at the Modern reading size
                // instead.
                if recordGraphicCells != nil {
                    for (i, ch) in run.enumerated() {
                        recordGraphicCells!.append(
                            PageLine.GraphicCellPlacement(char: ch, x: gx + Double(i) * pitch,
                                                          width: pitch,
                                                          widthIsWholePointPitch: false))
                    }
                }
                gx += Double(range.count) * pitch
                pos = range.upperBound
            }
            if pos < chars.count {
                let piece = String(chars[pos...])
                let pieceWidth = modernTokenWidth(piece, styles: tok.styles, family: tok.family,
                                                  pt: tok.pt, entry: entry, printedPt: printedPt)
                let pieceTok = ModernToken(text: piece, styles: tok.styles, family: tok.family,
                                           pt: tok.pt, entry: entry, width: pieceWidth)
                ops += modernLineOps([pieceTok], left: gx, y: y, width: width, align: .left,
                                     res: res, tzState: &tzState, printedPt: printedPt,
                                     recordGraphicCells: &recordGraphicCells)
            }
            x += tok.width
            continue
        }
        if !tok.text.trimmed().isEmpty {
            let want: Int
            if let entry = tok.entry, !entry.proportional {
                let target = Double(tok.text.width) * spanPitch(entry, spt)
                let (scale, _) = tzScale(tok.text, basefont, spt, target)
                want = hundredths(scale ?? tzDefault)
            } else if let entry = tok.entry {
                want = hundredths(faceTz(basefont, spanPitch(entry, spt), spt))
            } else {
                want = hundredths(tzDefault)
            }
            if want == tzState {
                ops.append(Array("BT /\(font) \(spt) Tf \(rise) Ts ".utf8)
                    + Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
                    + esc(tok.text) + Array(") Tj ET".utf8))
            } else {
                ops.append(Array("BT /\(font) \(spt) Tf \(rise) Ts ".utf8)
                    + Array("\(fixedTwoDecimal(hundredths: want)) Tz ".utf8)
                    + Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
                    + esc(tok.text) + Array(") Tj ET".utf8))
                tzState = want
            }
        }
        // Modern passes a whole span at a time, so its strike was already one
        // continuous rule across the gaps — no sink, inline emission unchanged (E3).
        var noStrikeSink: [(struck: Bool, x0: Double, x1: Double)]? = nil
        ops += rules(tok.styles, tok.text, x: x, y: y, w: tok.width,
                     strikeSink: &noStrikeSink)
        x += tok.width
    }
    return ops
}

/// All page content streams for Modern mode. Port of `_modern_streams`.
/// `attachGraphicCells` (planning #251 follow-up, 2026-09-10): same contract as
/// `attachGraphicCellsPrinted`'s own `lineOpsPrinted` call -- `nil` for every ordinary
/// render (`emitPDF`'s own call, zero extra cost beyond the `nil` checks already
/// threaded through `modernFlow`/`modernLineOps`), a real (empty) dictionary for
/// `attachGraphicCellsModern`'s throwaway pass, which this function fills keyed by
/// `sem.items` index (see `BodyLine.semIndex`'s own doc comment) with every graphic
/// cell that paragraph's own wrapped visual lines draw, in document order, ACROSS
/// however many visual lines/pages that paragraph's own non-wrapping graphic run
/// actually lands on -- the SAME `modernLineOps` call the real content stream is built
/// from, so the values are exactly what the PDF draws, never a parallel re-derivation.
/// Scope: body paragraphs, and the end-matter appendix's own endnote/annotation
/// entries (both flow through `body` below) -- a FOOTNOTE's own text is collected and
/// drawn through the separate `notesLines`/`page.notes` mechanism, which carries no
/// `sem.items` identity, so a graphic character inside a footnote's own text (not
/// observed anywhere in the public corpus) is not attached; this mirrors `layout`
/// JSON's own existing choice to leave raw `headers`/`footers` unresolved onto
/// `PageLine` (`header_lines`/`footer_lines`, planning #251(d), are the separate,
/// already-resolved answer for those).
/// `doc` with its MailMerge page-number variables replaced by the Modern PDF page
/// numbers they land on — the SAME document for the documents that carry none.
///
/// THE APPROACH, and why it is not the printed one. Printed physical lines are never
/// re-wrapped, so `substituteMergePageNumbersPrinted` can edit a composed page's own line
/// segments and be exact by construction. Modern REFLOWS, and a Modern token carries its
/// advance (`ModernToken.width`) baked at flow-build time, so the same post-pagination
/// edit would leave every token after it on the line drawing at the VARIABLE's width —
/// `&#&` is about three characters wider than the number that replaces it. The numbers
/// therefore have to be in the text before it is wrapped.
///
/// So: MEASURE, then RENDER. One throwaway Modern composition with the variables still as
/// typed says which page each one falls on (`modernStreams`' `recordMergePages`); those
/// numbers go into the document's own text (`mergePagenoNumbered`); the real render then
/// wraps, paginates and draws text that is already final. Nothing downstream knows this
/// happened.
///
/// THE RESIDUAL, stated rather than hidden: substituting SHORTENS the text, so the
/// measuring pass and the rendering pass are not guaranteed to paginate identically — an
/// occurrence sitting within a few characters of a page's last line could in principle
/// move up one page and then name the page it left. It is not iterated to a fixed point
/// because a fixed point need not exist (a shorter line can pull the variable back, which
/// lengthens it again). What is done instead is a real check:
/// `MergePageNumberVariableTests` renders the Modern PDF of every corpus document that
/// prints one and compares the two compositions page by page, so a drift would fail by
/// name rather than ship.
///
/// The measuring pass is paid ONLY by a document that actually carries the variable —
/// four in the whole archive, and `-HOLYMAC.WS`, the speed benchmark, is not one of them.
/// Port of `pdf._merge_pageno_modern`.
func mergePagenoModern(_ doc: Document, options: EmitOptions) -> Document {
    var carries = false
    outer: for block in doc.blocks {
        for line in block.lines where line.spans.contains(where: {
            containsMergePageNumberOpener($0.text)
        }) {
            carries = true
            break outer
        }
    }
    if !carries {
        carries = doc.notes.contains { containsMergePageNumberOpener($0.text) }
    }
    if !carries { return doc }
    var record = MergePagenoRecord()
    var noCells: [Int: [PageLine.GraphicCellPlacement]]? = nil
    withUnsafeMutablePointer(to: &record) { ptr in
        _ = modernStreams(doc, options: options, res: FontResources(),
                          attachGraphicCells: &noCells, recordMergePages: ptr)
    }
    let startNo = doc.page?.pnStart ?? 1
    return mergePagenoNumbered(doc,
                               body: record.body.map { startNo + $0 },
                               notes: record.notes.map { startNo + $0 })
}

/// Where each surviving MailMerge page-number variable lands, filled by
/// `modernStreams`' measuring pass. Planning #270 item 42 — see `mergePagenoModern`.
struct MergePagenoRecord {
    /// Page INDEX (not number) per body occurrence, in document order.
    var body: [Int] = []
    /// Page INDEX per note-text occurrence, in document order.
    var notes: [Int] = []
}

// MARK: - Modern page furniture, for the apps (planning #276)

/// One running head or foot line on one Modern page, exactly as the Modern PDF draws
/// it: `#` already substituted for this page's number, the x its own alignment resolved
/// to inside Modern's measure, and the baseline y it is drawn at.
public struct ModernHeadFootLine: Hashable, Sendable {
    /// The `.h#`/`.f#` slot this line came from, 1-based.
    public let line: Int
    /// The drawn text, `#` substituted and any trailing whitespace token trimmed --
    /// WordStar's inline style TOGGLE BYTES are still in it, exactly as
    /// `HeadFootLine.text` keeps them on the Printed side. Run it through `hfRuns` to
    /// style it.
    public let text: String
    /// Left edge in points, alignment already applied (`modernPlaceLine`).
    public let x: Double
    /// Baseline y in points, from the bottom of the sheet.
    public let y: Double
    /// Modern draws its furniture in Times at `modernNotePt`; both are stated rather
    /// than assumed so a caller never has to know that.
    public let family: PDFFamily
    public let pt: Int
    /// `.left`, `.center` or `.right` -- the alignment ALREADY applied to `x`, reported
    /// so a caller re-laying the text at a different measure can reproduce it.
    public let align: Alignment
}

/// WordStar's own automatic page number on one Modern page -- the one `.pc` positions
/// on the Printed page, placed the Modern way (M15, Jon's ruling 2026-09-15): centred
/// in Modern's own measure on the row a Modern footer line 1 rides, never Printed's
/// `.pc` column or its `pl - mb + fm` row.
public struct ModernAutoPageNumber: Hashable, Sendable {
    public let text: String
    public let x: Double
    public let y: Double
}

/// WHY one column of one Modern page stopped taking content (planning #276 follow-up,
/// 2026-09-15). The app fills a column by walking the same items the engine walked, so it
/// needs the engine's own reason as well as the engine's own boundary: a column that ran
/// out of room and a column an author ended with `.cb` look identical from the range
/// alone, and only the second one must survive a re-measure at a different font size.
///
///   `overflow`     the next piece of content did not fit. Includes the end of the
///                  document (the last column stops because there is nothing left) and a
///                  `.cp n` whose requested lines did not fit.
///   `columnBreak`  a `.cb` between two blocks, inside a live `.co n>1` region.
///   `pageBreak`    a break that ends the SHEET whatever column it was on: a `.pa` or a
///                  form feed outside a columnar region, a change of `.co` regime, and
///                  the two forced breaks Modern makes for itself (a screenplay page
///                  marker, and the end-matter block opening after a page that already
///                  carries footnotes).
public enum ModernColumnEnd: String, Hashable, Sendable {
    case overflow, columnBreak, pageBreak
}

/// The slice of the Modern flow that one column of one page actually holds.
///
/// WHY THIS EXISTS. The app's Modern view must fill its columns exactly as the engine's
/// Modern pagination does — one source of layout truth, the app never re-deriving
/// (Jon's rule). Everything about WHERE a column sits was already reported by
/// `ModernPageFurniture`; WHAT goes in it was not, so the app was making its own
/// column-fill decisions and disagreeing with the engine the moment the rules were
/// subtle. `sawyer/REF/BOOKLET.WS` is the measured case: it stores four form feeds
/// mid-paragraph, which the engine ABSORBS under its `.co 2` (three pages) and the app
/// broke on (nine).
///
/// `startItem`/`endItem` index `modernSemanticFlow(doc).items` — the flow `modernStreams`
/// lays out, the same order as the `layout` JSON's own `modern.items`. `endItem` is
/// EXCLUSIVE: it is where the next column (or the next page's first column) starts, so
/// the ranges are contiguous across columns and across pages, and the last one ends at
/// `items.count` with a `0` offset.
///
/// `startOffset`/`endOffset` are UTF-16 offsets into that item's own
/// `runs.map(\.text).joined()`, and are `0` whenever the boundary is a whole item — a
/// column that starts at the top of an item reports `0`, never the offset of its first
/// drawn glyph, so a centred row whose leading padding the engine strips still reports
/// the item's own start. A non-zero offset means exactly one thing: this item was split
/// across the boundary at a VISUAL LINE, and the offset is where the first line placed on
/// this side of it begins.
///
/// An item that draws nothing at a column top (a blank the paginator drops there, a form
/// feed a columnar region absorbs, a running-head change) sits INSIDE the range that
/// follows it, never at a boundary of its own. A column that took no content at all is
/// not reported: its items roll into the next column that did, which is what keeps the
/// ranges contiguous with no holes.
public struct ModernColumnRange: Hashable, Sendable {
    /// `0..<columns` on this page.
    public let column: Int
    public let startItem: Int
    public let startOffset: Int
    public let endItem: Int
    public let endOffset: Int
    public let ended: ModernColumnEnd
}

/// Everything the Modern PDF draws on one page that is NOT body text: the sheet, the
/// column geometry, the resolved running heads and feet, and the automatic page number.
///
/// WHY THIS EXISTS. The Mac and iOS apps draw Modern's own page furniture themselves,
/// and were re-deriving all of it -- which sheet, which margins, how wide a column,
/// where a centred running head starts, whether this page is numbered at all. Every one
/// of those is a decision the engine has already made, and a second derivation of a
/// decision is a disagreement waiting to be found in a screenshot. These values are
/// recorded BY `modernStreams` itself, at the moment each drawing op is built, from the
/// same numbers that op uses; there is no parallel model here to drift.
///
/// `columnTopOffset` is ALWAYS 0.0 and is reported for symmetry with Printed's own
/// `Page.columnTopOffsetPt`, which is not: Printed's columns begin below whatever
/// non-columnar prefix opened the sheet, while every Modern column restarts at the text
/// frame's own top (`modernStreams`' `close()` sets `y = sheetH - margt` for each).
///
/// The RIGHT margin is `marginLeft + textWidth`, i.e. `modernGeometry` as it stands
/// today. A ruling on whether Modern's right margin should mirror `.po` or stay a flat
/// 1in is pending (register 2026-09-15); this accessor reports what is drawn, and will
/// keep doing so when that changes.
public struct ModernPageFurniture: Hashable, Sendable {
    /// 0-based index into the emitted pages.
    public let pageIndex: Int
    /// The number printed on this page (`.pn`'s own start plus the index).
    public let pageNumber: Int
    /// The sheet the Modern PDF's MediaBox declares, in points -- the document's own
    /// declared page with `.pr or=l`'s landscape swap already applied.
    public let sheetWidth: Double
    public let sheetHeight: Double
    /// Modern's own text frame on that sheet (`modernGeometry`).
    public let marginLeft: Double
    public let marginTop: Double
    public let marginBottom: Double
    public let textWidth: Double
    /// `.co n` as Modern reads it (`modernColumnWidth`): 1 and 0.0 and the full
    /// `textWidth` on an ordinary page.
    public let columns: Int
    public let columnGutter: Double
    public let columnWidth: Double
    public let columnTopOffset: Double
    /// Ascending by `.h#`/`.f#` slot. Empty when the page has none.
    public let headers: [ModernHeadFootLine]
    public let footers: [ModernHeadFootLine]
    /// `nil` when this page is not numbered -- the document carries `.op`, a footer is
    /// in use, or `--page-numbers off` (`modernAutoPagenoShows`).
    public let autoPageNumber: ModernAutoPageNumber?
    /// What each column of this page holds, ascending by `column` -- see
    /// `ModernColumnRange`. Empty for a page that took no body content at all.
    public let columnRanges: [ModernColumnRange]
    /// The `modernSemanticFlow(doc).notes` (`SemanticNoteRow`) indices whose entries this
    /// page's own foot block draws, in the order they were committed to it. Empty on a
    /// page with no footnotes. A note is committed to the page its reference's own first
    /// visual line LANDED on, which is not always the page that line was first tried on.
    public let footnoteRows: [Int]
}

/// What the Modern PDF draws on each page besides body text -- see
/// `ModernPageFurniture`.
///
/// Computed by RUNNING the Modern emitter (`modernStreams`) and recording each value
/// where the op that draws it is built, then discarding the streams. It is the drawn
/// page's own answer, not a model of it.
///
/// `pageNumbers` is `EmitOptions.pageNumbers` and means what it means everywhere else:
/// `.auto` (the default) lets the document's own `.op`/`.pn`/`.pg` decide, `.on` forces
/// the number, `.off` suppresses it.
///
/// Convenience spelling of the `options:` overload below, for the caller whose only
/// departure from the defaults is the page-number flag. Anything else the export sets --
/// `pageSettings` above all, since a `--page-settings` preset MOVES the margins and the
/// sheet this accessor reports -- must go through `options:`, or this would answer about
/// a differently-laid-out page than the one being exported.
public func modernPageFurniture(_ doc: Document,
                                pageNumbers: EmitOptions.PageNumberMode = .auto)
    -> [ModernPageFurniture] {
    modernPageFurniture(doc, options: EmitOptions(pageNumbers: pageNumbers))
}

/// The same accessor over the WHOLE option set the export will use.
///
/// Added 2026-09-15 because the `pageNumbers:` spelling built its own `EmitOptions()` and
/// therefore silently dropped every other option -- `pageSettings` in particular, the
/// `--page-settings`/`pageSettings` preset that `resolvedGeometryDocument` folds into the
/// page before `emitPDF(.modern)` lays a single line out. An app exporting under a preset
/// got furniture measured on the UNPRESET page: the wrong margins, the wrong top, and
/// running heads drawn where nothing is.
///
/// Pass the document as it came out of `parseWS` -- NOT `printedDocument(doc)`. The
/// geometry fold below is the same one that façade performs, so a pre-resolved document
/// would have `.pr or=l`'s landscape swap applied to it twice.
public func modernPageFurniture(_ doc: Document, options: EmitOptions)
    -> [ModernPageFurniture] {
    // The SAME two geometry steps `emitPDF` applies before it lays anything out
    // (`.pr or=l`'s landscape swap, any `--page-settings` preset) and the SAME
    // page-number merge-variable resolution, or this accessor would answer about a
    // different page than the one the app is looking at.
    var prepared = resolvedGeometryDocument(doc, printed: false, options: options)
    if options.pageNumbers == .off {
        prepared = mergePagenoDropped(prepared)
    } else {
        prepared = mergePagenoModern(prepared, options: options)
    }
    var furniture: [ModernPageFurniture] = []
    var cells: [Int: [PageLine.GraphicCellPlacement]]? = nil
    withUnsafeMutablePointer(to: &furniture) { out in
        _ = modernStreams(prepared, options: options, res: FontResources(),
                          attachGraphicCells: &cells, recordFurniture: out)
    }
    return furniture
}

func modernStreams(_ doc: Document, options: EmitOptions, res: FontResources,
                   attachGraphicCells: inout [Int: [PageLine.GraphicCellPlacement]]?,
                   semCached: SemanticFlow? = nil,
                   recordMergePages: UnsafeMutablePointer<MergePagenoRecord>? = nil,
                   recordFurniture: UnsafeMutablePointer<[ModernPageFurniture]>? = nil)
    -> [[UInt8]] {
    // Python: `frozenset(options.get('notes', ())) or frozenset((...))` — an EMPTY set
    // (however it got that way, `--no-notes` included) falls back to the default three.
    // A real quirk in the reference, reproduced rather than "fixed": confirmed against
    // Python directly (2026-08-05) that `emit_pdf(doc, 'modern', notes=frozenset())`
    // still renders footnotes. Modern PDF's own note-kind filtering is therefore only
    // reachable by passing a NON-EMPTY subset that excludes a kind (`{'footnote'}` to
    // drop endnotes, say) — never by emptying it outright.
    let keep: Set<NoteKind> = options.notes.isEmpty
        ? [.footnote, .endnote, .annotation] : options.notes
    let (margl, margt, margb, width) = modernGeometry(doc)
    let sheetH = modernSheetH(doc)
    // planning #254: threaded to every `modernLineOps`/`modernHFOps` call below -- see
    // `modernTokenWidth`'s own doc comment.
    let printedPt = printedSize(doc)
    // planning #266 follow-up 2: the driver-keyed euro rule (`pesetaMeansEuro`/
    // `euroText`), resolved once. Applied below, at each header/footer line's own call
    // into `modernHFOps` -- the same point `PDFWriter.swift`'s `runningOps` calls into
    // `hfLineOps` were patched at (00b85ae/planning #266): a running head/foot carrying
    // cp437 code 158 kept showing the pre-driver-rule degradation under Modern too, the
    // latent twin of that gap. Port of ctrlkd.pdf's `_modern_streams` fix.
    let euro = pesetaMeansEuro(doc)
    // N9 (b33 field notes): this function only ever runs the Modern path (printed=false
    // by construction -- `emitPDF`'s own `else` branch), so 'auto' always resolves to
    // single here.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: false)
    // Also armed by `recordFurniture`: `ModernColumnRange` reports SEMANTIC item indices,
    // and this is where the flow's own items are mapped back to them. Arming it changes
    // no emitted byte -- the recorded index only ever reaches `BodyLine.semIndex`, which
    // the drawing loop reads exclusively when `attachGraphicCells` asked for cells.
    var semIndexOfItem: [Int]? = (attachGraphicCells != nil || recordFurniture != nil) ? [] : nil
    // The per-token source offsets and the semantic item count the column-range recorder
    // needs -- see `ModernFlowSource`. Never built for an ordinary export.
    var flowSrc = ModernFlowSource()
    // `.co n` reaches Modern (Jon's ruling 2026-09-15). The regime in force at every
    // block, and where the `.cb` hard column breaks sit, come off the IR through the
    // SAME helper Printed RTF's own section spine reads (`rtfColumnsState`) -- one
    // definition of "which column regime is this block in", never a second one that
    // could drift from it.
    var blockIndexOfItem: [Int?]? = []
    let colState = rtfColumnsState(doc)
    let colbreakBis = Set(doc.blocks.indices.filter { doc.blocks[$0].kind == .colbreak })
    let flow = withUnsafeMutablePointer(to: &flowSrc) { srcOut in
        modernFlow(doc, keep: keep, noteRefs: options.noteRefs,
                   pixResults: options.pixResults, pictures: options.pictures,
                   textWidthPt: width, sentenceSpacing: ssOn,
                   semIndexOfItem: &semIndexOfItem, semCached: semCached,
                   blockIndexOfItem: &blockIndexOfItem,
                   src: recordFurniture != nil ? srcOut : nil)
    }
    let blockOfItem = blockIndexOfItem ?? []
    let semOfItem = semIndexOfItem ?? []
    let noteLead = modernLine * Double(modernNotePt)
    let sepH = noteLead

    /// `image` non-nil marks an embedded pix line (b24 round 22) — `toks` is empty then,
    /// mirroring Python's `('image', ...)` tuple riding in the `toks` slot.
    /// `semIndex` (planning #251 follow-up, 2026-09-10): the `sem.items` index this
    /// visual line's own tokens came from (`semIndexOfItem`'s own value for the `flow`
    /// item this line was wrapped/paginated out of), or `nil` when `attachGraphicCells`
    /// wasn't requested -- carried so the final content-stream loop below can attribute
    /// a graphic cell it draws back to the semantic paragraph the `layout` JSON's own
    /// `modern.items` array will serialize it against.
    typealias BodyLine = (y: Double, toks: [ModernToken], align: Alignment,
                          indent: Double, cut: Double, image: PageLine.ImageRef?,
                          semIndex: Int?)
    var pages: [(body: [BodyLine], notes: [[ModernToken]],
                 headers: [Int: String], footers: [Int: String],
                 endBlock: Int,
                 // The `.co` regime in force when this page closed -- recorded here
                 // because it is the only place it is known per PAGE (it changes as the
                 // flow walks blocks). Read by `recordFurniture` only; the drawing loop
                 // below still uses the live `curCols`/`colW`/`colGap`, unchanged.
                 cols: Int, gutterPt: Double, columnWidth: Double,
                 // planning #276 follow-up: what each column of this page holds, and the
                 // note rows its foot block draws. Recorded by `close()` and by the
                 // note-commit site below -- the same two places that decide them.
                 ranges: [ModernColumnRange], noteRows: [Int])] = []
    var body: [BodyLine] = []
    var notesLines: [[ModernToken]] = []
    // Dedup by the note's index in `inlineReferenceNotes` — the stable identity Python's
    // `id(note)` provides (`Note` is a value type here).
    var seenNotes: Set<Int> = []
    // THE PAGE BASELINE MODEL (planning #263, ledger 2026-09-11; Jon's standing
    // principle, "the engine needs to work the way Soft Return does"). `y` is a LINE BOX
    // cursor, not a baseline: it starts at the text frame's own top edge and each line
    // spends its own height `h` off it, so after `y -= h` the value is that line's BOX
    // BOTTOM, which is also the next line's box top. Line boxes stack from the top of the
    // frame -- what AppKit does with line fragments, and what the app's Modern view is
    // therefore answerable to.
    //
    // WHERE THE BASELINE GOES inside that box: `h - descent` below its own top, i.e. one
    // face DESCENT above the box bottom (`modernDescent`). This engine used to draw the
    // baseline ON the box bottom, which put every Modern line one descent lower than the
    // app drew the same line and left each line's descenders hanging below its own box.
    //
    // WHAT THIS DOES NOT CHANGE: the fit test, and therefore which lines land on which
    // page. A line fits while its box BOTTOM is inside the frame (`y - h >= margb`,
    // unchanged below) -- the app's rule stated as "fragment bottom <= top + H", the
    // identical arithmetic on a Letter page where `margb == pageHeight - (margt + H)`.
    // Page composition, page counts, every x and the whole Printed path are untouched by
    // this; what moves is the y every Modern line draws at, by its OWN line's descent (so
    // a mixed-size page does not shift rigidly).
    //
    // NOT ported with it: the tightened line's own headroom figure (`modernTightBaseline`,
    // job 434's spacer). That is the app's own separately-measured number -- glyph-path
    // bounds through NSLayoutManager -- and the app itself has not yet adopted the AFM
    // form of it (it is waiting on `afmInkTops`). Changing it here would move the engine's
    // spacers AWAY from the app's measured 3.70/3.71/3.94 on the archive's README.
    var y = sheetH - margt
    var curH: [Int: String] = [:]          // running-head state as events replay
    var curF: [Int: String] = [:]
    var pageH: [Int: String] = [:]         // state when the OPEN page took content
    var pageF: [Int: String] = [:]
    var opened = false
    // Q9 TIMING FOR THE FOOTER (2026-09-15). A HEADER is emitted at the TOP of a page, so
    // a `.he`/`.h#` read after the page's first line cannot reach it — that is
    // `openPage`'s snapshot, and it is right. A FOOTER is emitted at the BOTTOM, so a
    // `.fo`/`.f#` read ANYWHERE before the page ends still governs that page; Printed has
    // read it that way since the 8MAC measurement (`docToPagelines`' own
    // `kind == .footer && !pageAlreadyFull(li)`), and Modern took the header's rule for
    // both, which put every mid-page footer change one page late in Modern alone.
    //
    // `pageAlreadyFull` IS THE HALF THAT MATTERS, and it is why this is a PENDING state
    // rather than a snapshot taken at the event: a footer read when the page can take no
    // more content belongs to the NEXT page. Printed answers that by peeking at the next
    // line; Modern cannot peek (its own line heights are resolved during placement, not
    // before it), so it answers the same question by WAITING — the footer state a `.fo`
    // declares is handed to whichever page actually takes the next piece of content, and
    // to any page that closes for a reason OTHER than running out of room.
    //
    // ONE LIMIT WORTH NAMING, pre-existing and untouched: Modern's flow is BLOCK-granular
    // (`modernFlow` walks `doc.blocks.enumerated()` and hangs each `hf` event on its
    // anchor block), so a `.fo` typed between two physical lines of ONE paragraph has no
    // block to hang on and never reaches this loop at all. Q9 in Modern is therefore only
    // as fine-grained as a block boundary. Every corpus document this rule moves anchors
    // its `.fo` at one.
    var pendingF: [Int: String]? = nil
    // The newspaper-column cursor. A document begins outside any columnar region, so
    // `curCols` is 1 and every line below takes the full measure and sits at `colI == 0`
    // -- exactly the arithmetic that was here before this ruling, which is why a document
    // with no `.co` anywhere in it emits the bytes it always did.
    var curCols = 1
    var curGutter: Double? = nil
    var colW = width
    var colGap = 0.0
    var colI = 0                           // 0-based column of the open sheet
    var colBody = false                    // has THIS column taken content yet
    var lastBi = -1                        // last block that reached the page
    // M15 (2026-09-15): the LAST block whose content reached this page. WordStar's
    // automatic page number is a per-PAGE answer to a positional question, and Printed
    // resolves it at the position the page had READ UP TO when it closed
    // (`checkpointsByPage`), not at the page's start — its own `.op`/`.pn`/`.pg` is read
    // on the page it physically sits on. Modern's flow carries block indices and no
    // source line indices, so this is `checkpointByBlock`'s granularity exactly: the
    // highest block index the page carries. -1 until the page takes content.
    var pageEndBi = -1
    // b26-modern item 4 (ctrl-kd c402094): a blank line's own advance must scale with
    // the SURROUNDING text's font size, same principle as Printed's established "a
    // blank advances at the preceding block's own leading" rule (StyleLeadingTests.swift)
    // -- Modern already computes each real line's own size-proportional `h` (modernLine
    // * that line's own max token size) below, but a 'blank' item used to carry a FIXED
    // height baked at flow-build time (modernLine * modernBodyPt, the 14pt document
    // default) regardless of what was actually on the page. Measured on PREVIEW.WS (real
    // corpus, font-sample page mixing 24pt/20pt/12pt lines): a blank between two 24pt
    // lines advanced by the SAME fixed 16.8pt a blank between a 24pt and an 8pt line
    // would -- the total inter-paragraph gap tracked only the ENTERING line's own size,
    // never the size actually being LEFT, so two structurally-identical "one blank line"
    // transitions produced visibly different gaps whenever the preceding line's size
    // differed. Fix: track the most recently placed line's own `h` and use THAT for the
    // next blank, falling back to the 14pt default only when nothing has been placed yet
    // (unchanged behavior for a leading blank).
    var lastH = modernLine * Double(modernBodyPt)
    // THE COLUMN-RANGE RECORDER (planning #276 follow-up, 2026-09-15). All of it is dead
    // weight -- three vars and one `append` inside `close()` -- unless `recordFurniture`
    // asked for it; nothing here is read by the drawing loop or reaches a single emitted
    // byte.
    //
    // `cursor` is the position of the NEXT piece of content, in the SEMANTIC item indices
    // `ModernColumnRange` reports: set to each flow item's own semantic index as the loop
    // reaches it, and advanced to a visual line's own source offset inside a `.para` just
    // before that line is fitted. A `close()` therefore always reads the exact point the
    // column stopped at, because it is called at the moment the paginator decides to stop.
    var colStart = (item: 0, offset: 0)
    var cursor = (item: 0, offset: 0)
    var pageRanges: [ModernColumnRange] = []
    var pageNoteRows: [Int] = []

    func noteBlockH() -> Double {
        notesLines.isEmpty ? 0.0 : sepH + noteLead * Double(notesLines.count)
    }
    func openPage() {
        // the page's running heads are the state in force when it takes its first
        // content — OLDTIMES defines .h1 after page 1's title, and a manuscript has no
        // running head on page 1 (same rule as printed)
        if !opened {
            pageH = curH
            pageF = curF
            opened = true
        }
    }
    /// Hand the page now taking content the footer state a `.fo` read earlier on it
    /// declared — see the Q9 note above.
    func takePendingFoot() {
        if let pending = pendingF {
            pageF = pending
            pendingF = nil
        }
    }
    /// End the current COLUMN. On the last column of a `.co n` sheet -- and on every page
    /// of an ordinary one-column document, where n is 1 and this is the only branch that
    /// ever runs -- that ends the physical page too.
    ///
    /// `hard: true` ends the physical page whatever column it was on: the callers are a
    /// change of column regime, which starts its own sheet the same way `docToPagelines`'
    /// own block loop forces a break on every `columns` state change, and the end of the
    /// document. A trailing group of fewer than n columns is simply left short --
    /// WordStar does not balance (planning #227 §5, measured on WINGDING.CHT's own short
    /// last column), and neither does this.
    ///
    /// `overflow: true` is Printed's own "already full" case — the page ended because the
    /// next piece of content did not fit — and leaves the pending footer for the page
    /// that does take it. Every other close (an explicit `.pa`, a `.cp` that breaks, a
    /// column-regime change, the end of the document) ends a page that was still open, so
    /// the footer is its own.
    ///
    /// `ended` (planning #276 follow-up) is the reason this column stopped, for the range
    /// recorded below -- see `ModernColumnEnd`. It defaults to `.overflow` because that is
    /// what "the paginator decided there was no more room" means at every unmarked call
    /// site, the end of the document included.
    ///
    /// A COLUMN THAT TOOK NO CONTENT IS NOT RECORDED (`colBody == false` on entry): it has
    /// no first drawn item to start at, and leaving `colStart` where it is rolls whatever
    /// it swallowed into the next column that did take something, which is what keeps the
    /// ranges contiguous with no holes.
    func close(hard: Bool = false, overflow: Bool = false,
               ended: ModernColumnEnd = .overflow) {
        if recordFurniture != nil, colBody {
            pageRanges.append(ModernColumnRange(
                column: colI, startItem: colStart.item, startOffset: colStart.offset,
                endItem: cursor.item, endOffset: cursor.offset, ended: ended))
            colStart = cursor
        }
        if !overflow { takePendingFoot() }
        openPage()
        colBody = false
        y = sheetH - margt
        if !hard, curCols > 1, colI + 1 < curCols {
            colI += 1
            return                       // same sheet, next column
        }
        pages.append((body, notesLines, pageH, pageF, pageEndBi,
                      curCols, colGap, colW, pageRanges, pageNoteRows))
        body = []
        notesLines = []
        pageRanges = []
        pageNoteRows = []
        colI = 0
        opened = false
        pageEndBi = -1
    }

    for (fi, item) in flow.enumerated() {
        let semI = semIndexOfItem?[fi]
        if recordFurniture != nil {
            // The boundary a break taken HERE reports sits before this item, so the item
            // that forced the break (a `.cb`'s own block, a `.co` regime change) opens the
            // next column rather than closing the one before it.
            cursor = (item: fi < semOfItem.count ? semOfItem[fi] : cursor.item, offset: 0)
        }
        if fi < blockOfItem.count, let bi = blockOfItem[fi] {
            // `.cb` (a `colbreak` block) between the last block that put something on the
            // page and this one: a hard break to the next column, and -- exactly as
            // `rtfColsControl`'s twin writes nothing for a `.cb` outside a columnar
            // region -- a no-op outside one. Read off the IR here rather than carried as
            // a flow item because the Modern flow IS the `layout` JSON contract and this
            // ruling moves no schema.
            if curCols > 1, lastBi + 1 < bi,
               (lastBi + 1..<bi).contains(where: { colbreakBis.contains($0) }) {
                close(ended: .columnBreak)
            }
            let want = bi < colState.count ? colState[bi] : (cols: 1, gutter: nil)
            if want.cols != curCols || want.gutter != curGutter {
                if !body.isEmpty || !notesLines.isEmpty || colBody {
                    close(hard: true, ended: .pageBreak)
                }
                curCols = want.cols
                curGutter = want.gutter
                (colW, colGap) = modernColumnWidth(width, cols: curCols, gutter: curGutter)
                colI = 0
            }
            lastBi = bi
        }
        switch item {
        case .hf(let kind, let line, let text):
            if kind == .header {
                curH[line] = text
            } else {
                curF[line] = text
                pendingF = curF                  // Q9, see `takePendingFoot`
            }
        case .pageBreak:
            // A bare `.pa` INSIDE a live `.co n>1` region is absorbed, not taken -- the
            // identical reading Printed has carried since planning #227 (measured
            // against WINGDING.CHT's own real WS7 capture: the author's `.pa` markers
            // are a manual column simulation that predates the real `.co` governing the
            // same content, and honouring them fragments one real column) and that
            // Printed RTF adopted with its section spine.
            if curCols <= 1 {
                // The break item is CONSUMED by the page it ends, so the boundary sits
                // after it -- or the next page would open on a break it would take again.
                // `.tabs` produces no flow entry, so the next flow item's own semantic
                // index is read rather than assumed to be this one plus one.
                if recordFurniture != nil {
                    cursor = (item: fi + 1 < semOfItem.count ? semOfItem[fi + 1]
                                                             : flowSrc.itemCount,
                              offset: 0)
                }
                close(ended: .pageBreak)
            }
        case .cond(let n):
            let need = Double(n) * modernLine * Double(modernBodyPt)
            if colBody, y - (margb + noteBlockH()) < need {
                close()
            }
        case .blank:
            guard colBody else { continue }              // no blank at a column top
            let h = lastH
            if y - h < margb + noteBlockH() {
                close(overflow: true)
                continue
            }
            y -= h
        case .image(let pixIndex, let wPt, let hPt):
            // Round 22 (closing round 19's Modern scope cut): an embedded pix image
            // spends its own height against the page exactly as a body line does; the
            // drawing loop below paints its XObject with the bottom edge at the y this
            // advance lands on (same convention as Printed's `pageStream`).
            //
            // b27-WP3 item 4 (ctrl-kd 721a94b): `lastH` is exclusively a TEXT-leading
            // memory -- the height a following `.blank` case reuses (see above). An
            // image's own height is a page-space cost, not a leading, so it must NEVER
            // be written into `lastH`: doing so let a blank run immediately after an
            // image inherit the image's height instead of the surrounding text's
            // leading (measured on -README.WS: an inline image 73.9pt tall followed by
            // 7 blank source lines advanced 7 x 73.9 = 517.3pt instead of the correct
            // 7 x 16.8 = 117.6pt 14pt-body leading). `lastH` is left exactly as it was
            // -- the most recently placed TEXT line's own leading, or the 14pt default
            // if no text has been placed yet.
            if colBody, y - hPt < margb + noteBlockH() {
                close(overflow: true)
            }
            openPage()
            takePendingFoot()
            pageEndBi = max(pageEndBi, lastBi)
            y -= hPt
            let imgColOff = Double(colI) * (colW + colGap)
            body.append((y, [], .left, imgColOff, -imgColOff,
                         PageLine.ImageRef(pixIndex: pixIndex, widthPt: wPt, heightPt: hPt), semI))
            colBody = true
        case .para(let toks, let align, let notes, let indent, let cut, let noWrap, let pageMarker,
                  let endNotesStart, let paraTight, let hang):
            if pageMarker, !body.isEmpty {
                // b26-modern item 3, rule (a): a real screenplay page-number marker
                // starts a new real page -- if this Modern page already has content on
                // it (no explicit .pa immediately preceded this marker, the ordinary
                // case), force the break here instead of letting the marker land
                // mid-page. A marker that is already the first thing on a fresh page
                // (an explicit .pa DID precede it, SCRIPT.WS's own shape) costs nothing
                // extra -- `close()` on an empty page would just insert a spurious
                // blank one, so this only fires when there is something to separate
                // FROM.
                close(ended: .pageBreak)
            }
            if endNotesStart, !body.isEmpty, !notesLines.isEmpty {
                // Jon's ruling 2026-09-07 (RULINGS-LEDGER.md verbatim): "endnotes go
                // right at the end of text / image on the last page unless there are
                // footnotes on that page. Then the endnotes start on a new page."
                // Endnotes are never interleaved with a footnote block. `notesLines` is
                // exclusively footnote text here (M1's own split: footnote -> the
                // per-paragraph page-bottom area; endnote/annotation -> the end-matter
                // appendix this ONE `.noteSeparator`-opened item begins) -- non-empty
                // means the CURRENT page already carries at least one footnote, so the
                // appendix starts fresh instead of continuing directly after the last
                // body line/image. `!body.isEmpty` guards the same way `pageMarker`'s
                // check does: a fresh, still-empty page needs no extra break (nothing
                // to separate FROM).
                close(ended: .pageBreak)
            }
            // rule (c): a screenplay slugline carrying its own right-hand scene number
            // never wraps -- an unbounded width means `modernWrap`'s greedy break
            // condition can never trigger, so the whole line places as ONE visual line
            // regardless of its natural width, exactly as real screenplay software
            // keeps a slugline unbroken.
            // INSIDE A COLUMNAR REGION THE COLUMN IS THE MEASURE, and the block's own
            // `.rm` cut is not spent on top of it -- the two are the same measure stated
            // twice (see `modernColumnWidth`), and taking both would narrow every column
            // by the amount the division already took off.
            let effCut = curCols > 1 ? width - colW : cut
            let lineW = noWrap ? Double.infinity : max(36.0, width - indent - effCut)
            // `visIdx` (planning #276 follow-up): which `toks` index starts each visual
            // line, asked of the wrap itself rather than re-derived from the placed
            // tokens -- a swallowed wrap-point space is invisible in `vis` and would
            // silently shift a source offset by one token if this were counted here.
            var visIdx: [[Int]] = []
            let vis = recordFurniture != nil
                ? withUnsafeMutablePointer(to: &visIdx) {
                      modernWrap(toks, width: lineW, hang: hang, indices: $0)
                  }
                : modernWrap(toks, width: lineW, hang: hang)
            let tokOff = recordFurniture != nil ? (flowSrc.tokenOffsets[fi] ?? []) : []
            // planning #263, job 437: a tightened paragraph that actually WRAPS renders at
            // the body's ordinary leading throughout instead. The tightening is about how a
            // verse or centred LINE reads against its neighbours; a paragraph long enough
            // to need a second visual line is prose that merely got classified, and
            // compressing its own internal wrap crowds it. Resolved once, here, because
            // everything downstream (the line height, the leading spacer, which is the same
            // paragraph's own headroom) has to agree on the answer.
            let tight = paraTight && vis.count == 1
            // The leading spacer (job 434) is this paragraph's own headroom, so it is spent
            // as part of the FIRST visual line's advance: that way the page-fit test below
            // already accounts for it, and a paragraph pushed to the next page takes its
            // spacer with it rather than leaving it stranded as blank canvas on the page
            // before.
            var spacer = 0.0
            if tight, !(fi > 0 && modernParaIsGraphic(flow[fi - 1]) && modernParaIsGraphic(item)) {
                let face = modernLineFace(toks)
                spacer = modernLeadingSpacer(toks, face.family, face.pt)
            }
            var newNoteLines: [[ModernToken]] = []
            var newNoteRows: [Int] = []
            var newNoteMerges = 0
            for entry in notes where !seenNotes.contains(entry.index) {
                if recordMergePages != nil {
                    newNoteMerges += mergePagenoCount(entry.text)
                }
                // `entry.index` IS the `SemanticNoteRow` index (`modernFlow` built these
                // entries off `sem.notes[fn.index]`), which is what `footnoteRows`
                // reports -- collected here, committed to a page below at the same
                // moment `notesLines` is.
                newNoteRows.append(entry.index)
                newNoteLines += modernNoteLines(label: entry.label, text: entry.text, width: width)
            }
            for (vi, vline) in vis.enumerated() {
                let face = modernLineFace(vline)
                var h = tight ? modernTightHeight(face.family, face.pt)
                              : modernLine * Double(face.pt)
                // A BLANK NEVER INHERITS A TIGHTENED HEIGHT (planning #263, measured on
                // -README.WS). `lastH` is the leading a following `.blank` advances by, and
                // the app -- the reference for every Modern rule Jon ruled on, his standing
                // principle "the engine needs to work the way Soft Return does" -- records
                // the placed line's own point SIZE there (`DocumentRenderer`'s
                // `lastParagraphPt`) and builds the blank at that size's ordinary
                // `modernLine` leading, tight or not. `lastH` predates verse tightening,
                // when every text line WAS `modernLine * pt` and the two readings could not
                // differ; tightening split them. Measured on -README.WS page 1, whose
                // centred title block classifies as verse: its three internal blanks
                // advanced 11.50pt each here against the app's 16.80, 15.90pt of the page
                // recovered, which is what let the library fit sixteen lines on page 1 where
                // the app fits fourteen -- and every page after it inherited the drift.
                let lead = modernLine * Double(face.pt)
                if vi == 0 { h += spacer }
                let extra: Double
                if vi == 0, !newNoteLines.isEmpty {
                    extra = (notesLines.isEmpty ? sepH : 0.0) + noteLead * Double(newNoteLines.count)
                } else {
                    extra = 0.0
                }
                // WHERE THIS LINE STARTS IN THE SOURCE, resolved BEFORE the fit test: if
                // the line does not fit, the column that just closed ends exactly here
                // and the next one starts exactly here. `vi == 0` reports the item's own
                // start (0), never its first drawn token's offset -- a centred row whose
                // leading padding was stripped still begins at the item.
                if recordFurniture != nil {
                    cursor.offset = vi == 0 ? 0
                        : (visIdx.indices.contains(vi) ? (visIdx[vi].first.flatMap {
                               tokOff.indices.contains($0) ? tokOff[$0] : nil
                           } ?? cursor.offset)
                         : cursor.offset)
                }
                if colBody, y - h < margb + noteBlockH() + extra {
                    close(overflow: true)
                }
                openPage()
                takePendingFoot()
                pageEndBi = max(pageEndBi, lastBi)
                y -= h
                // `lastH` is a LEADING memory (what the next blank item should advance by),
                // so it records the line's own height, never the one-off headroom spent
                // above it.
                lastH = lead
                // WHICH COLUMN THIS LINE SITS IN, resolved here because the fit test just
                // above may have moved it to the next one. The offset is added to the
                // line's own indent and taken back off its cut, so the frame MOVES
                // without changing width: the drawing loop below spends `margl + indent`
                // and `width - indent - cut`, and those two come out as the column's own
                // left edge and the column's own measure. `colGap`/`colW` are 0/`width`
                // outside a columnar region, where this is a no-op by arithmetic.
                let colOff = Double(colI) * (colW + colGap)
                // THE PAGE BASELINE MODEL (planning #263): `y` is this line BOX's own
                // bottom edge -- the next box's top -- and the baseline sits one face
                // DESCENT above it, never on it. See the note at the head of this function.
                body.append((y + modernDescent(face.family, face.pt), vline, align,
                             indent + colOff + (vi > 0 ? hang : 0.0), effCut - colOff,
                             nil, semI))
                colBody = true
                if let record = recordMergePages {
                    // planning #270 item 42: this visual line is now ON the page being
                    // composed (`pages.count` is its index -- the page is appended by
                    // `close()`), so every variable in it is answered by that page's own
                    // number. Token order inside the line is document order, and the
                    // lines are appended in document order, so the list needs no other
                    // key than its position.
                    for tok in vline {
                        for _ in 0..<mergePagenoCount(tok.text) {
                            record.pointee.body.append(pages.count)
                        }
                    }
                }
                if vi == 0, !newNoteLines.isEmpty {
                    notesLines.append(contentsOf: newNoteLines)
                    pageNoteRows.append(contentsOf: newNoteRows)
                    newNoteRows = []
                    for entry in notes { seenNotes.insert(entry.index) }
                    if let record = recordMergePages, newNoteMerges > 0 {
                        // Recorded HERE, not where the note's lines were built: a note
                        // block is committed to the page its reference's own first visual
                        // line actually landed on, which is one `close()` later whenever
                        // that line did not fit.
                        record.pointee.notes.append(
                            contentsOf: Array(repeating: pages.count, count: newNoteMerges))
                        newNoteMerges = 0
                    }
                    newNoteLines = []
                }
            }
        }
    }
    // The document is over, so the sheet is over whichever column it had reached --
    // `hard`, or a columnar document's own last sheet would advance to an empty column
    // instead of being handed to the page list.
    // The last column's range ends past the last item, at offset 0 -- the document is
    // over, so there is no next piece of content to name.
    if recordFurniture != nil { cursor = (item: flowSrc.itemCount, offset: 0) }
    close(hard: true)
    while pages.count > 1, pages[pages.count - 1].body.isEmpty, pages[pages.count - 1].notes.isEmpty {
        pages.removeLast()
    }

    let startNo = doc.page?.pnStart ?? 1
    // M15: the `.op`/`.pn`/`.pg` state, resolved once for the document and read per page
    // at that page's own block — the same checkpoints the Printed writer reads.
    let pageNumbersMode = options.pageNumbers
    let pgnumCps = pgnumCheckpoints(doc)
    // M15: WHERE EACH FOOTER COMMAND WAS READ, off the document's own `hfEvents` rather
    // than off the page's `curF` snapshot. Two reasons, both measured:
    //   * "A FOOTER is emitted at the BOTTOM, so a `.fo`/`.f#` read ANYWHERE before the
    //     page ends still governs that page" (`docToPagelines`' own rule, WS7
    //     v4/PRISTINE.EXE) — so the anchor is compared against the page's LAST block.
    //   * A `.fo` typed after the document's last block (`sawyer/REF/BUGS.WS`: two
    //     blocks, footer anchored at block 2) never reaches the Modern FLOW at all
    //     (`modernFlow` walks `doc.blocks.enumerated()`), so `curF` could never say so.
    let footAnchors = doc.hfEvents.filter { $0.kind == .footer }.map { $0.blockAnchor }.sorted()
    // `--headers off` reaches Modern too. The flag governs the RUNNING HEADS AND FEET on
    // every paged surface (register, "Flag UI + defaults"; ruled again 2026-09-14,
    // planning #264 R7) — Printed PDF and both RTF modes have honoured it since ctrl-kd
    // `722b877`/sr `4f673db`, and Modern PDF was the one paged surface still drawing its
    // heads under `off`. M5 ("Modern keeps running heads", ruled 2026-08-06) is the
    // DEFAULT this flag turns off, never a refusal of the flag.
    //
    // `footerInUse` below is deliberately NOT gated with it: "in use" is a property of
    // the DOCUMENT (a declared `.fo`), never of what we draw — the same rule, and the
    // same hazard, `4f673db` spells out for the Printed writer's own call site.
    // Suppressing a footer's DRAWING must not conjure an automatic number the document
    // never had. And the automatic number itself answers to `--page-numbers` alone, so
    // it is drawn below under `--headers off` exactly as it is under `on`.
    //
    // `recordFurniture` follows the ops because it IS this loop: a head that is not
    // drawn is not reported, so `modernPageFurniture` never hands the apps a line the
    // PDF does not have.
    let showHeaders = options.headers
    var streams: [[UInt8]] = []
    for (pi, page) in pages.enumerated() {
        var tzState = hundredths(tzDefault)
        var ops: [[UInt8]] = []
        let pageNo = startNo + pi
        // running heads live in the margin zones: header lines walk down from ~0.6in off
        // the top edge, footer lines sit ~0.6in off the bottom — inside Modern's 1in
        // margins, clear of the body
        // `recordFurniture` (planning #276, 2026-09-15): the Mac and iOS apps draw
        // Modern's own running heads, feet and automatic number, and had to re-derive
        // where they go. They read `modernPageFurniture` now, which is THIS loop --
        // every value below is recorded at the moment the op that draws it is built,
        // from the same `y`, the same substituted text and the same
        // `modernPlaceLine` x. There is no second placement model to drift from it.
        var furnHeaders: [ModernHeadFootLine] = []
        var furnFooters: [ModernHeadFootLine] = []
        var furnAuto: ModernAutoPageNumber? = nil
        /// `nil` for a line that PUTS NO INK ON THE PAGE -- exactly the case
        /// `modernHFOps` returns no ops for (`toks.isEmpty`). A `.f1` whose whole
        /// content is 0x0F user print controls is the real one: `REF/BOOKLET.WS`
        /// declares one, and reporting it as furniture would have the apps drawing a
        /// line the PDF does not.
        func furnitureLine(_ txt: String, lno: Int, y: Double,
                           align: Alignment) -> ModernHeadFootLine? {
            let toks = modernHFToks(txt, pageNo: pageNo)
            if toks.isEmpty { return nil }
            let placed = modernPlaceLine(toks, left: margl, width: width, align: align)
            return ModernHeadFootLine(
                line: lno, text: placed.toks.map(\.text).joined(),
                x: placed.x, y: y, family: .times, pt: modernNotePt, align: align)
        }
        for lno in (showHeaders ? page.headers.keys.sorted() : []) {
            guard let txt = page.headers[lno], !txt.isEmpty else { continue }
            let hy = sheetH - 44.0 - Double(lno - 1) * noteLead
            let align = modernHFAlign(doc, .header, lno)
            if recordFurniture != nil,
               let f = furnitureLine(euroText(txt, euro), lno: lno,
                                     y: hy, align: align) {
                furnHeaders.append(f)
            }
            ops += modernHFOps(euroText(txt, euro), pageNo: pageNo, left: margl, y: hy,
                               width: width, res: res, tzState: &tzState, printedPt: printedPt,
                               align: align)
        }
        for lno in (showHeaders ? page.footers.keys.sorted() : []) {
            guard let txt = page.footers[lno], !txt.isEmpty else { continue }
            let fy = max(8.0, 44.0 - Double(lno - 1) * noteLead)
            let align = modernHFAlign(doc, .footer, lno)
            if recordFurniture != nil,
               let f = furnitureLine(euroText(txt, euro), lno: lno,
                                     y: fy, align: align) {
                furnFooters.append(f)
            }
            ops += modernHFOps(euroText(txt, euro), pageNo: pageNo, left: margl, y: fy,
                               width: width, res: res, tzState: &tzState, printedPt: printedPt,
                               align: align)
        }
        // M15 (Jon's ruling 2026-09-15): WordStar's own AUTOMATIC page number — the one
        // `.pc` positions, never a `#` an author typed into a real `.he`/`.fo`, which
        // `modernHFOps` has always substituted. Modern RTF has carried it since M5 (a
        // `\footer` group of `\chpgn`, centred, in the body face); Modern PDF is ruled to
        // be that RTF's printed form (2026-08-05) and was the one surface still dropping
        // it, so the app's Modern view showed a document's numbering vanish the moment
        // you switched to it.
        //
        // PLACEMENT IS MODERN'S OWN, exactly as the ruling says ("placed the Modern
        // way"): the row a Modern footer line 1 rides, centred in Modern's own measure,
        // in the face and size Modern's running feet already use — never Printed's `.pc`
        // column or its `pl - mb + fm` row. WHETHER it shows is the document's answer,
        // and `modernAutoPagenoShows` is where that is read.
        let footerInUse = !footAnchors.isEmpty
            && (footAnchors[0] <= page.endBlock || pi == pages.count - 1)
        if page.endBlock >= 0,
           modernAutoPagenoShows(doc, bi: page.endBlock, pageNumbers: pageNumbersMode,
                                 pgnumCheckpoints: pgnumCps, footerInUse: footerInUse) {
            if recordFurniture != nil {
                let placed = modernPlaceLine(modernHFToks(String(pageNo), pageNo: pageNo),
                                             left: margl, width: width, align: .center)
                furnAuto = ModernAutoPageNumber(text: String(pageNo), x: placed.x, y: 44.0)
            }
            ops += modernHFOps(String(pageNo), pageNo: pageNo, left: margl, y: 44.0,
                               width: width, res: res, tzState: &tzState,
                               printedPt: printedPt, align: .center)
        }
        if let recordFurniture {
            let sheet = modernPageDict(doc)
            recordFurniture.pointee.append(ModernPageFurniture(
                pageIndex: pi, pageNumber: pageNo,
                sheetWidth: Double(roundHalfToEven((sheet?.pwIn ?? 8.5) * 72.0)),
                sheetHeight: sheetH,
                marginLeft: margl, marginTop: margt, marginBottom: margb,
                textWidth: width,
                columns: page.cols, columnGutter: page.gutterPt,
                columnWidth: page.columnWidth, columnTopOffset: 0.0,
                headers: furnHeaders, footers: furnFooters,
                autoPageNumber: furnAuto,
                columnRanges: page.ranges, footnoteRows: page.noteRows))
        }
        for line in page.body {
            if let img = line.image {
                // Round 22: the XObject draw — same operator shape (and `%.2f`
                // formatting) as Printed's `pageStream`, bottom edge at this line's y.
                // `margl + line.indent` rather than a bare `margl`: an image in a
                // columnar region carries its own column's offset as an indent, exactly
                // as a text line does. Every image outside one carries an indent of 0.0,
                // so this is byte-identical everywhere the previous form was reached.
                var op = Array("q \(fixedTwoDecimals(img.widthPt)) 0 0 \(fixedTwoDecimals(img.heightPt)) ".utf8)
                op += Array("\(fixedTwoDecimals(margl + line.indent)) \(fixedTwoDecimals(line.y)) cm /Im\(img.pixIndex) Do Q".utf8)
                ops.append(op)
                continue
            }
            var lineCells: [PageLine.GraphicCellPlacement]? = attachGraphicCells != nil ? [] : nil
            ops += modernLineOps(line.toks, left: margl + line.indent, y: line.y,
                                 width: max(36.0, width - line.indent - line.cut),
                                 align: line.align, res: res, tzState: &tzState, printedPt: printedPt,
                                 recordGraphicCells: &lineCells)
            if let semI = line.semIndex, let lineCells, !lineCells.isEmpty {
                attachGraphicCells![semI, default: []].append(
                    contentsOf: lineCells.map { cell in
                        var c = cell
                        c.page = pageNo
                        return c
                    })
            }
        }
        let nlines = page.notes
        if !nlines.isEmpty {
            let total = nlines.count + 1                  // +1 for the separator rule
            for i in 0..<total {
                let ly = margb + noteLead * Double(total - 1 - i)
                if i == 0 {
                    let f = res.ref("Times-Roman")
                    ops.append(Array("BT /\(f) \(modernNotePt) Tf 0 Ts ".utf8)
                        + Array("\(fixedOneDecimalDouble(margl)) \(fixedOneDecimalDouble(ly)) Td (".utf8)
                        + esc(String(repeating: "-", count: 20)) + Array(") Tj ET".utf8))
                } else {
                    // Footnote text: no `sem.items` identity to attach to (see this
                    // function's own doc comment) -- always discarded.
                    var discardedGraphicCells: [PageLine.GraphicCellPlacement]? = nil
                    ops += modernLineOps(nlines[i - 1], left: margl, y: ly, width: width,
                                         align: .left, res: res, tzState: &tzState, printedPt: printedPt,
                                         recordGraphicCells: &discardedGraphicCells)
                }
            }
        }
        streams.append(joinedNewlines(ops))
    }
    return streams
}

/// planning #251 follow-up (2026-09-10, app coder job 348): every `sem.items` index
/// (`modernSemanticFlow(doc, notes:, noteRefs:)`'s own item list -- the SAME call
/// `emitLayout`'s `modern.items` serializes) with at least one drawn cp437 graphic-
/// character cell, mapped to that paragraph's own cells (char/x/width/page, document
/// order across however many wrapped visual lines/pages the paragraph's own non-
/// wrapping graphic run lands on) -- via a real (throwaway-resources) call to
/// `modernStreams` itself, using its own `attachGraphicCells` recording parameter, so
/// the values are exactly what Modern PDF draws (`PDFDriverLJ6DTP.swift`'s own
/// `graphicOps`), never a parallel re-derivation. Mirrors `attachGraphicCellsPrinted`'s
/// own precedent (`PDFWriter.swift`) for Printed.
///
/// Skipped outright (returns `[:]`) when NO block anywhere in the document carries a
/// graphic character at all -- the same necessary-condition short-circuit
/// `attachGraphicCellsPrinted` applies per LINE, applied once here per DOCUMENT (the
/// only granularity available before `modernStreams`' own pagination has run), sparing
/// the overwhelming majority of documents a full throwaway Modern-PDF pagination pass.
///
/// `notes`/`noteRefs` come from the caller and must be the SAME values passed to
/// `modernSemanticFlow` at the `emitLayout` call site, so a cell's own item index always
/// lines up with the `sem.items` that produced it; every other option
/// (`pixResults`/`pictures`/`sentenceSpacing`) is the library default `EmitOptions()`
/// itself carries, matching `modernSemanticFlow`'s own "document's own unconverted
/// text" convention (its own doc comment on the `sentenceSpacing` parameter) -- a pix-
/// substituted paragraph never carries a graphic character in the first place (its
/// runs are "exactly one resolved, decoded pix placeholder"), so `pictures: .off` here
/// changes nothing this function could ever attach to.
///
/// `public` (2026-09-10, planning #251 follow-up): this is the ONLY way to read a
/// Modern paragraph's own drawn graphic-cell geometry outside `emitLayout`'s JSON --
/// `modernSemanticFlow`'s own `SemanticFlow` carries no such field (the cells are
/// keyed by `sem.items` index, not attached to any one `SemanticItem`). Was `internal`
/// -- unreachable from the app, which needs this same geometry Native's own view
/// draws from, matching `attachGraphicCellsPrinted`'s already-`public` precedent for
/// Printed. ctrl-kd's own twin, `pdf.attach_graphic_cells_modern` (no leading
/// underscore -- that module's own "public" convention), was never module-private to
/// begin with; this brings Swift's visibility to the same place.
/// True when ANY span anywhere in the document carries a cp437 graphic character — the
/// necessary condition for `attachGraphicCellsModern` to attach anything at all, and
/// therefore for its throwaway Modern-PDF pass to be worth running.
///
/// `public` (perf, planning #271 M7) so `emitLayout` can ask the same question BEFORE it
/// decides whether to share its own semantic flow with that pass. Port of ctrl-kd
/// `pdf.has_modern_graphic_content`.
public func hasModernGraphicContent(_ doc: Document) -> Bool {
    doc.blocks.contains { block in
        block.lines.contains { line in
            line.spans.contains { span in
                span.text.contains { graphicChars.contains($0) }
            }
        }
    }
}

public func attachGraphicCellsModern(_ doc: Document, notes: Set<NoteKind>, noteRefs: NoteRefs,
                                     semCached: SemanticFlow? = nil)
    -> [Int: [PageLine.GraphicCellPlacement]]
{
    guard hasModernGraphicContent(doc) else { return [:] }
    var cells: [Int: [PageLine.GraphicCellPlacement]]? = [:]
    let options = EmitOptions(notes: notes, noteRefs: noteRefs)
    // `semCached` (perf, planning #271 M7): `emitLayout`'s own already-run
    // `modernSemanticFlow` answer, shared rather than re-derived — see `modernFlow`'s
    // own note. Dropped on the floor when `notes` is EMPTY, because `modernStreams`'
    // own documented quirk then resolves `keep` to the default three instead: the
    // caller's flow and this pass's flow would be two different flows, and a shared
    // one would silently change what this function attaches.
    _ = modernStreams(doc, options: options, res: FontResources(), attachGraphicCells: &cells,
                      semCached: notes.isEmpty ? nil : semCached)
    return cells ?? [:]
}

/// `[[UInt8]].joined(separator: 0x0A)` (Python's `b'\n'.join`), local to this file since
/// `PDFWriter.swift`'s equivalent (`joined(_:separator:)`) is `private` there.
private func joinedNewlines(_ chunks: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    for (i, chunk) in chunks.enumerated() {
        if i > 0 { out.append(0x0A) }
        out += chunk
    }
    return out
}
