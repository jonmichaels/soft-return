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
    case para(toks: [ModernToken], align: Alignment,
              notes: [(index: Int, label: String, text: String)],
              indent: Double, cut: Double, noWrap: Bool, pageMarker: Bool)
    /// An embedded pix image standing alone on its own paragraph — b24 round 22, closing
    /// round 19's documented Modern scope cut. Python's `('image', idx, w, h)` tuple.
    case image(pixIndex: Int, widthPt: Double, heightPt: Double)
}

/// `(left, topMargin, bottomMargin, textWidth)` in points. The document's declared
/// geometry wins (governing principle); silence is the modern page: 1in margins on
/// Letter. The right margin is always 1in — WordStar's right edge is a text measure
/// (`.rm`), not a page property. Port of `_modern_geometry`.
func modernGeometry(_ doc: Document) -> (left: Double, top: Double, bottom: Double, width: Double) {
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
func modernTokFont(_ text: String, font: Int?, fonts: [FontChange])
    -> (written: String, family: PDFFamily, pt: Int, entry: FontChange?)
{
    let rendered = spanRender(text, font: font, fonts: fonts, size: modernBodyPt)
    if rendered.entry == nil {
        return (rendered.text, .times, rendered.size, nil)
    }
    return (rendered.text, rendered.family, rendered.size, rendered.entry)
}

/// A token's advance in points under modern layout: natural face widths (face-scaled for
/// entries, straight AFM for fontless Times), the fixed grid only where a fixed-pitch
/// font block asks for it. Port of `_modern_w`.
func modernTokenWidth(_ text: String, styles: Style, family: PDFFamily, pt: Int, entry: FontChange?) -> Double {
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
        let pitch = (entry == nil || entry!.proportional) ? Double(spt) : spanPitch(entry, spt)
        let chars = Array(text)
        var pos = 0
        for range in graphicRunRanges(chars) {
            if range.lowerBound > pos {
                let piece = String(chars[pos..<range.lowerBound])
                total += modernTokenWidth(piece, styles: styles, family: family, pt: pt, entry: entry)
            }
            total += Double(range.count) * pitch
            pos = range.upperBound
        }
        if pos < chars.count {
            let piece = String(chars[pos...])
            total += modernTokenWidth(piece, styles: styles, family: family, pt: pt, entry: entry)
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
func modernFlow(_ doc: Document, keep: Set<NoteKind>,
                noteRefs: NoteRefs = .word, pixResults: [PixResult] = [],
                pictures: EmitOptions.PixMode = .off,
                textWidthPt: Double = 0.0, sentenceSpacing: Bool = false) -> [ModernFlowItem] {
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
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
    var flow: [ModernFlowItem] = []
    for item in sem.items {
        switch item {
        case .blank:
            flow.append(.blank(blankH))
        case .pageBreak:
            flow.append(.pageBreak)
        case .cond(let lines):
            flow.append(.cond(lines))
        case .hf(let which, let line, let text):
            flow.append(.hf(kind: which, line: line, text: text))
        case .tabs:
            continue          // editor-time state: no rendered consequence (task #19)
        case .noteSeparator:
            let separator = String(repeating: "-", count: 20)
            let sepW = stringWidthPt(separator, "Times-Roman", modernNotePt)
            flow.append(.para(toks: [ModernToken(text: separator, styles: [], family: .times,
                                                 pt: modernNotePt, entry: nil, width: sepW)],
                              align: .left, notes: [], indent: 0.0, cut: 0.0,
                              noWrap: false, pageMarker: false))
        case .note(let ni, _, let label, let text):
            let noteText = sentenceSpacing ? sentenceSpacingTexts([text])[0] : text
            flow.append(.para(toks: modernNoteToks(label: label, text: noteText,
                                                    kind: sem.notes[ni].kind),
                              align: .left, notes: [], indent: 0.0, cut: 0.0,
                              noWrap: false, pageMarker: false))
        case .para(let align, let indentCols, let cutCols, var runs, let footnotes, _, _, let bi):
            if embedImages, !runs.contains(where: { $0.ref != nil }),
               let sub = spansPixSubstitution(runs.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                flow.append(.image(pixIndex: sub.pixIndex, widthPt: sub.wPt,
                                   heightPt: sub.hPt))
                continue
            }
            // N9: applied to the run texts, in order, same cross-piece state-carrying as
            // every other emitter's own choke point -- the pix-substitution check above
            // already ran on the RAW runs (a structural placeholder match, not prose).
            if sentenceSpacing { runs = sentenceSpacingRuns(runs) }
            var toks: [ModernToken] = []
            for run in runs {
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
                                                 pt: modernBodyPt, entry: nil)
                    toks.append(ModernToken(text: run.text, styles: styles, family: .times,
                                            pt: modernBodyPt, entry: nil, width: width))
                    continue
                }
                for piece in modernTokenize(run.text) {
                    let resolved = modernTokFont(piece, font: run.font, fonts: doc.fonts)
                    let width = modernTokenWidth(resolved.written, styles: styles,
                                                 family: resolved.family, pt: resolved.pt,
                                                 entry: resolved.entry)
                    toks.append(ModernToken(text: resolved.written, styles: styles,
                                            family: resolved.family, pt: resolved.pt,
                                            entry: resolved.entry, width: width))
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
            flow.append(.para(toks: toks, align: lineAlign, notes: notes,
                              indent: indentCols.value * colPt, cut: cutCols.value * colPt,
                              noWrap: noWrap, pageMarker: pageMarker))
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
func modernWrap(_ toks: [ModernToken], width: Double) -> [[ModernToken]] {
    var lines: [[ModernToken]] = []
    var cur: [ModernToken] = []
    var curw = 0.0
    for tok in toks {
        let hasInk = !tok.text.trimmed().isEmpty
        if !cur.isEmpty, curw + tok.width > width, hasInk {
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
func modernHFOps(_ txt: String, pageNo: Int, left: Double, y: Double, width: Double,
                 res: FontResources, tzState: inout Int) -> [[UInt8]] {
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
    return modernLineOps(toks, left: left, y: y, width: width, align: .left,
                         res: res, tzState: &tzState)
}

/// Content-stream ops for one modern visual line. One op per word keeps a viewer's
/// substitute-metric drift bounded, same as printed. Port of `_modern_line_ops`.
func modernLineOps(
    _ toksIn: [ModernToken], left: Double, y: Double, width: Double, align: Alignment,
    res: FontResources, tzState: inout Int
) -> [[UInt8]] {
    var toks = toksIn
    var lineWidth = toks.reduce(0.0) { $0 + $1.width }
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
            let pitch = (entry == nil || entry!.proportional) ? Double(spt) : spanPitch(entry, spt)
            let chars = Array(tok.text)
            var pos = 0
            var gx = x
            for range in graphicRunRanges(chars) {
                if range.lowerBound > pos {
                    let piece = String(chars[pos..<range.lowerBound])
                    let pieceWidth = modernTokenWidth(piece, styles: tok.styles,
                                                      family: tok.family, pt: tok.pt, entry: entry)
                    let pieceTok = ModernToken(text: piece, styles: tok.styles, family: tok.family,
                                               pt: tok.pt, entry: entry, width: pieceWidth)
                    ops += modernLineOps([pieceTok], left: gx, y: y, width: width, align: .left,
                                         res: res, tzState: &tzState)
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
                gx += Double(range.count) * pitch
                pos = range.upperBound
            }
            if pos < chars.count {
                let piece = String(chars[pos...])
                let pieceWidth = modernTokenWidth(piece, styles: tok.styles, family: tok.family,
                                                  pt: tok.pt, entry: entry)
                let pieceTok = ModernToken(text: piece, styles: tok.styles, family: tok.family,
                                           pt: tok.pt, entry: entry, width: pieceWidth)
                ops += modernLineOps([pieceTok], left: gx, y: y, width: width, align: .left,
                                     res: res, tzState: &tzState)
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
func modernStreams(_ doc: Document, options: EmitOptions, res: FontResources) -> [[UInt8]] {
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
    // N9 (b33 field notes): this function only ever runs the Modern path (printed=false
    // by construction -- `emitPDF`'s own `else` branch), so 'auto' always resolves to
    // single here.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: false)
    let flow = modernFlow(doc, keep: keep, noteRefs: options.noteRefs,
                          pixResults: options.pixResults, pictures: options.pictures,
                          textWidthPt: width, sentenceSpacing: ssOn)
    let noteLead = modernLine * Double(modernNotePt)
    let sepH = noteLead

    /// `image` non-nil marks an embedded pix line (b24 round 22) — `toks` is empty then,
    /// mirroring Python's `('image', ...)` tuple riding in the `toks` slot.
    typealias BodyLine = (y: Double, toks: [ModernToken], align: Alignment,
                          indent: Double, cut: Double, image: PageLine.ImageRef?)
    var pages: [(body: [BodyLine], notes: [[ModernToken]],
                 headers: [Int: String], footers: [Int: String])] = []
    var body: [BodyLine] = []
    var notesLines: [[ModernToken]] = []
    // Dedup by the note's index in `inlineReferenceNotes` — the stable identity Python's
    // `id(note)` provides (`Note` is a value type here).
    var seenNotes: Set<Int> = []
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

    for item in flow {
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
                         PageLine.ImageRef(pixIndex: pixIndex, widthPt: wPt, heightPt: hPt)))
        case .para(let toks, let align, let notes, let indent, let cut, let noWrap, let pageMarker):
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
            // rule (c): a screenplay slugline carrying its own right-hand scene number
            // never wraps -- an unbounded width means `modernWrap`'s greedy break
            // condition can never trigger, so the whole line places as ONE visual line
            // regardless of its natural width, exactly as real screenplay software
            // keeps a slugline unbroken.
            let lineW = noWrap ? Double.infinity : max(36.0, width - indent - cut)
            let vis = modernWrap(toks, width: lineW)
            var newNoteLines: [[ModernToken]] = []
            for entry in notes where !seenNotes.contains(entry.index) {
                newNoteLines += modernNoteLines(label: entry.label, text: entry.text, width: width)
            }
            for (vi, vline) in vis.enumerated() {
                let sizes = vline.map { sized($0.styles, $0.pt).points }
                let h = modernLine * Double(sizes.max() ?? modernBodyPt)
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
                lastH = h
                body.append((y, vline, align, indent, cut, nil))
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
            ops += modernHFOps(txt, pageNo: pageNo, left: margl, y: hy, width: width,
                               res: res, tzState: &tzState)
        }
        for lno in page.footers.keys.sorted() {
            guard let txt = page.footers[lno], !txt.isEmpty else { continue }
            let fy = max(8.0, 44.0 - Double(lno - 1) * noteLead)
            ops += modernHFOps(txt, pageNo: pageNo, left: margl, y: fy, width: width,
                               res: res, tzState: &tzState)
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
            ops += modernLineOps(line.toks, left: margl + line.indent, y: line.y,
                                 width: max(36.0, width - line.indent - line.cut),
                                 align: line.align, res: res, tzState: &tzState)
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
                    ops += modernLineOps(nlines[i - 1], left: margl, y: ly, width: width,
                                         align: .left, res: res, tzState: &tzState)
                }
            }
        }
        streams.append(joinedNewlines(ops))
    }
    return streams
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
