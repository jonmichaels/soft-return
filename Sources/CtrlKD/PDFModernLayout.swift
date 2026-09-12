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

/// `(left, topMargin, bottomMargin, textWidth)` in points. The document's declared
/// geometry wins (governing principle); silence is the modern page: 1in margins on
/// Letter. The right margin is always 1in — WordStar's right edge is a text measure
/// (`.rm`), not a page property. Port of `_modern_geometry`.
public func modernGeometry(_ doc: Document) -> (left: Double, top: Double, bottom: Double, width: Double) {
    let page = doc.page
    let mtDeclared = (page?.mtSource ?? .default) != .default
    let mbDeclared = (page?.mbSource ?? .default) != .default
    let poDeclared = (page?.poSource ?? .default) != .default
    let margt = mtDeclared ? (page?.mtLines ?? 6.0) * 12.0 : 72.0
    let margb = mbDeclared ? (page?.mbLines ?? 6.0) * 12.0 : 72.0
    let margl = poDeclared ? (page?.poCols ?? 10.0) * 7.2 : 72.0
    let pageW = (page?.pwIn ?? 8.5) * 72.0     // A4 files are narrower (2026-08-06)
    let width = max(144.0, pageW - margl - 72.0)
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

/// Is this flow entry a paragraph that draws at least one cp437 box/block/shade character?
/// (`modernStreams`' own suppression test — a box's vertical rule must read as one continuous
/// stroke, not a dashed one, so two graphic rows in a row get no spacer between them.) Port of
/// `_modern_para_is_graphic`.
func modernParaIsGraphic(_ item: ModernFlowItem) -> Bool {
    guard case .para(let toks, _, _, _, _, _, _, _, _, _) = item else { return false }
    return toks.contains { $0.text.contains(where: { graphicChars.contains($0) }) }
}

/// WHICH MODERN ROWS REFUSE TO WRAP (job 456, and the app's own b28 follow-up on it — ported
/// here, the app is the reference). Port of `_modern_clips_row`.
///
/// A row of box-drawing or block characters is a picture, not a sentence: broken across two
/// visual lines it stops being the thing it draws. Three shapes qualify, read off the row's own
/// final rendered text:
///
///   wholly graphic    at least one graphic character, and nothing else on the row but graphic
///                     characters and spaces (a box border, a rule).
///   2+ graphic chars  job 456's own rule and the field report behind it ("I don't understand
///                     what happened in Modern. They have line returns in the middle"). A MIXED
///                     row — a real prose label plus its glyphs — is the case: a legend row
///                     ("LL: └ LR: ┘ … Joins: … Mixed: …") or a substitution-table row, which
///                     ordinary word wrapping folds at the perfectly legal space between label
///                     and glyph. The threshold is TWO, not one, so an ordinary paragraph
///                     carrying a single incidental symbol (a list marker) still wraps like the
///                     prose it is.
///   nowhere to break  a row with no space in it at all. This engine's greedy wrap never breaks
///                     inside a token, so such a row already sets as one line; stated anyway,
///                     because it is part of the rule being ported and a renderer that CAN break
///                     a word must not.
///
/// A clipped row is set as ONE line and runs past the measure rather than reflowing
/// (`modernStreams` gives it an unbounded wrap width) — the app's `.byClipping`. Read the row's
/// FINAL tokens, after a centred row's padding has come off and a def row's label/gap prefix has
/// gone on.
func modernClipsRow(_ toks: [ModernToken]) -> Bool {
    let text = toks.map(\.text).joined()
    let graphicCount = text.reduce(0) { $0 + (graphicChars.contains($1) ? 1 : 0) }
    if graphicCount > 0,
       text.allSatisfy({ graphicChars.contains($0) || $0 == " " || $0 == "\u{00a0}" || $0 == "\u{2060}" }) {
        return true
    }
    if graphicCount > 1 { return true }
    return !text.isEmpty && !text.contains(" ")
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
func modernFlow(_ doc: Document, keep: Set<NoteKind>,
                noteRefs: NoteRefs = .word, pixResults: [PixResult] = [],
                pictures: EmitOptions.PixMode = .off,
                textWidthPt: Double = 0.0, sentenceSpacing: Bool = false,
                semIndexOfItem: inout [Int]?) -> [ModernFlowItem] {
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    // planning #254: the document's own fixed-pitch size, for a graphic character's cell
    // advance ONLY (`modernTokenWidth`'s own `printedPt` doc comment) -- never the Modern
    // reading size.
    let printedPt = printedSize(doc)
    let sem = modernSemanticFlow(doc, notes: keep, noteRefs: noteRefs)
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
        case .pageBreak:
            flow.append(.pageBreak)
            semIndexOfItem?.append(semI)
        case .cond(let lines):
            flow.append(.cond(lines))
            semIndexOfItem?.append(semI)
        case .hf(let which, let line, let text):
            flow.append(.hf(kind: which, line: line, text: text))
            semIndexOfItem?.append(semI)
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
        case .note(let ni, _, let label, let text):
            let noteText = sentenceSpacing ? sentenceSpacingTexts([text])[0] : text
            flow.append(.para(toks: modernNoteToks(label: label, text: noteText,
                                                    kind: sem.notes[ni].kind),
                              align: .left, notes: [], indent: 0.0, cut: 0.0,
                              noWrap: false, pageMarker: false, endNotesStart: false,
                              tight: false, hang: 0.0))
            semIndexOfItem?.append(semI)
        case .para(let align, let indentCols, let cutCols, let runs, let footnotes,
                  let structure, let isVerse, let bi):
            if embedImages, !runs.contains(where: { $0.ref != nil }),
               let sub = spansPixSubstitution(runs.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                flow.append(.image(pixIndex: sub.pixIndex, widthPt: sub.wPt,
                                   heightPt: sub.hPt))
                semIndexOfItem?.append(semI)
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
                    continue
                }
                for piece in modernTokenize(run.text) {
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
                while let first = toks.first, first.text.trimmed().isEmpty { toks.removeFirst() }
                while let last = toks.last, last.text.trimmed().isEmpty { toks.removeLast() }
            } else if let structure, structure.kind != nil {
                // the ladder REPLACES the block's own `.lm` indent (that is the whole
                // point of it), so the row's residual leading spaces go with it -- left
                // in, they would push a level-1 row off the margin the ladder just put it
                // on. Dropped BEFORE the hang is measured: a bullet's hang is the advance
                // of the row's own first two characters, which are its marker and gap only
                // once the padding is gone.
                while let first = toks.first, first.text.trimmed().isEmpty { toks.removeFirst() }
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
            flow.append(.para(toks: toks, align: lineAlign, notes: notes,
                              indent: indent, cut: cut,
                              noWrap: noWrap, pageMarker: pageMarker, endNotesStart: false,
                              tight: tight, hang: hang))
            semIndexOfItem?.append(semI)
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
func modernWrap(_ toks: [ModernToken], width: Double, hang: Double = 0.0) -> [[ModernToken]] {
    var lines: [[ModernToken]] = []
    var cur: [ModernToken] = []
    var curw = 0.0
    for tok in toks {
        let hasInk = !tok.text.trimmed().isEmpty
        let limit = lines.isEmpty ? width : max(36.0, width - hang)
        if !cur.isEmpty, curw + tok.width > limit, hasInk {
            lines.append(cur)
            cur = []
            curw = 0.0
        }
        if cur.isEmpty, !hasInk, !lines.isEmpty {
            continue                          // swallow the wrap-point space
        }
        cur.append(tok)
        curw += tok.width
    }
    if !cur.isEmpty || lines.isEmpty {
        lines.append(cur)
    }
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
func modernHFOps(_ txt: String, pageNo: Int, left: Double, y: Double, width: Double,
                 res: FontResources, tzState: inout Int, printedPt: Int) -> [[UInt8]] {
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
    if toks.isEmpty { return [] }
    var discardedGraphicCells: [PageLine.GraphicCellPlacement]? = nil
    return modernLineOps(toks, left: left, y: y, width: width, align: .left,
                         res: res, tzState: &tzState, printedPt: printedPt,
                         recordGraphicCells: &discardedGraphicCells)
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
    var toks = toksIn
    // `neumaierSum`, not a plain `reduce(+)`: the reference is Python's `sum()`, which on
    // CPython 3.12+ compensates float error exactly the way this helper does, and a naive
    // left-to-right total differs from it in the last bits. That used to be invisible --
    // a left-aligned line never spends `lineWidth` on a drawn coordinate -- but a CENTRED
    // line's own start is `left + (width - lineWidth) / 2`, so one ULP here can move a
    // later token across a `%.1f` rounding boundary and print an x 0.1pt away from the
    // reference's. Measured: a 21-token row summing to 327.768 naively and to
    // 327.76800000000003 compensated, which moved three drawn x values on one archive
    // document. Same reason `PDFWriter.swift`'s own justification total already uses it.
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
        ops += rules(tok.styles, tok.text, x: x, y: y, w: tok.width)
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
func modernStreams(_ doc: Document, options: EmitOptions, res: FontResources,
                   attachGraphicCells: inout [Int: [PageLine.GraphicCellPlacement]]?) -> [[UInt8]] {
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
    var semIndexOfItem: [Int]? = attachGraphicCells != nil ? [] : nil
    let flow = modernFlow(doc, keep: keep, noteRefs: options.noteRefs,
                          pixResults: options.pixResults, pictures: options.pictures,
                          textWidthPt: width, sentenceSpacing: ssOn,
                          semIndexOfItem: &semIndexOfItem)
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
                 headers: [Int: String], footers: [Int: String])] = []
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
    var y = Double(PDFMetrics.pageHeight) - margt
    var curH: [Int: String] = [:]          // running-head state as events replay
    var curF: [Int: String] = [:]
    var pageH: [Int: String] = [:]         // state when the OPEN page took content
    var pageF: [Int: String] = [:]
    var opened = false
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
    func close() {
        openPage()
        pages.append((body, notesLines, pageH, pageF))
        body = []
        notesLines = []
        y = Double(PDFMetrics.pageHeight) - margt
        opened = false
    }

    for (fi, item) in flow.enumerated() {
        let semI = semIndexOfItem?[fi]
        switch item {
        case .hf(let kind, let line, let text):
            if kind == .header { curH[line] = text } else { curF[line] = text }
        case .pageBreak:
            close()
        case .cond(let n):
            let need = Double(n) * modernLine * Double(modernBodyPt)
            if !body.isEmpty, y - (margb + noteBlockH()) < need {
                close()
            }
        case .blank:
            guard !body.isEmpty else { continue }         // no blank at a page top
            let h = lastH
            if y - h < margb + noteBlockH() {
                close()
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
            if !body.isEmpty, y - hPt < margb + noteBlockH() {
                close()
            }
            openPage()
            y -= hPt
            body.append((y, [], .left, 0.0, 0.0,
                         PageLine.ImageRef(pixIndex: pixIndex, widthPt: wPt, heightPt: hPt), semI))
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
                close()
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
                close()
            }
            // rule (c): a screenplay slugline carrying its own right-hand scene number
            // never wraps -- an unbounded width means `modernWrap`'s greedy break
            // condition can never trigger, so the whole line places as ONE visual line
            // regardless of its natural width, exactly as real screenplay software
            // keeps a slugline unbroken.
            let lineW = noWrap ? Double.infinity : max(36.0, width - indent - cut)
            let vis = modernWrap(toks, width: lineW, hang: hang)
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
            for entry in notes where !seenNotes.contains(entry.index) {
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
                if !body.isEmpty, y - h < margb + noteBlockH() + extra {
                    close()
                }
                openPage()
                y -= h
                // `lastH` is a LEADING memory (what the next blank item should advance by),
                // so it records the line's own height, never the one-off headroom spent
                // above it.
                lastH = lead
                // THE PAGE BASELINE MODEL (planning #263): `y` is this line BOX's own
                // bottom edge -- the next box's top -- and the baseline sits one face
                // DESCENT above it, never on it. See the note at the head of this function.
                body.append((y + modernDescent(face.family, face.pt), vline, align,
                             indent + (vi > 0 ? hang : 0.0), cut, nil, semI))
                if vi == 0, !newNoteLines.isEmpty {
                    notesLines.append(contentsOf: newNoteLines)
                    for entry in notes { seenNotes.insert(entry.index) }
                    newNoteLines = []
                }
            }
        }
    }
    close()
    while pages.count > 1, pages[pages.count - 1].body.isEmpty, pages[pages.count - 1].notes.isEmpty {
        pages.removeLast()
    }

    let startNo = doc.page?.pnStart ?? 1
    var streams: [[UInt8]] = []
    for (pi, page) in pages.enumerated() {
        var tzState = hundredths(tzDefault)
        var ops: [[UInt8]] = []
        let pageNo = startNo + pi
        // running heads live in the margin zones: header lines walk down from ~0.6in off
        // the top edge, footer lines sit ~0.6in off the bottom — inside Modern's 1in
        // margins, clear of the body
        for lno in page.headers.keys.sorted() {
            guard let txt = page.headers[lno], !txt.isEmpty else { continue }
            let hy = Double(PDFMetrics.pageHeight) - 44.0 - Double(lno - 1) * noteLead
            ops += modernHFOps(euroText(txt, euro), pageNo: pageNo, left: margl, y: hy,
                               width: width, res: res, tzState: &tzState, printedPt: printedPt)
        }
        for lno in page.footers.keys.sorted() {
            guard let txt = page.footers[lno], !txt.isEmpty else { continue }
            let fy = max(8.0, 44.0 - Double(lno - 1) * noteLead)
            ops += modernHFOps(euroText(txt, euro), pageNo: pageNo, left: margl, y: fy,
                               width: width, res: res, tzState: &tzState, printedPt: printedPt)
        }
        for line in page.body {
            if let img = line.image {
                // Round 22: the XObject draw — same operator shape (and `%.2f`
                // formatting) as Printed's `pageStream`, bottom edge at this line's y.
                var op = Array("q \(fixedTwoDecimals(img.widthPt)) 0 0 \(fixedTwoDecimals(img.heightPt)) ".utf8)
                op += Array("\(fixedTwoDecimals(margl)) \(fixedTwoDecimals(line.y)) cm /Im\(img.pixIndex) Do Q".utf8)
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
public func attachGraphicCellsModern(_ doc: Document, notes: Set<NoteKind>, noteRefs: NoteRefs)
    -> [Int: [PageLine.GraphicCellPlacement]]
{
    let hasGraphicContent = doc.blocks.contains { block in
        block.lines.contains { line in
            line.spans.contains { span in
                span.text.contains { graphicChars.contains($0) }
            }
        }
    }
    guard hasGraphicContent else { return [:] }
    var cells: [Int: [PageLine.GraphicCellPlacement]]? = [:]
    let options = EmitOptions(notes: notes, noteRefs: noteRefs)
    _ = modernStreams(doc, options: options, res: FontResources(), attachGraphicCells: &cells)
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
