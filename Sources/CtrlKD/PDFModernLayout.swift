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
/// (`('para', toks, align, notes, indent, cut)`, `('blank', height)`, `('break',)`,
/// `('cond', n)`, `('hf', kind, line, text)`).
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
    /// exactly as its fonts do (M2).
    case para(toks: [ModernToken], align: Alignment,
              notes: [(index: Int, note: Note, label: String)],
              indent: Double, cut: Double)
}

/// Endnote display label under Modern: lowercase roman, Word's own default for `\ftnalt`
/// endnotes — the PDF matches the RTF it mirrors, and a page can carry footnote [1] and
/// endnote [i] without collision (ruling 2026-08-06 M1). Port of `_endnote_label`.
func endnoteRomanLabel(_ label: String) -> String {
    guard let n = Int(label), n > 0 else { return label }
    var remaining = n
    var out = ""
    for (v, s) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                   (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                   (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
        while remaining >= v {
            out += s
            remaining -= v
        }
    }
    return out
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
    let width = max(144.0, Double(PDFMetrics.pageWidth) - margl - 72.0)
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
    if let entry, text.contains(where: { graphicChars.contains($0) }) {
        // mixed tokens split into graphic runs (cell advance) and text (natural), same
        // rule as printed's `splitGraphics`.
        var total = 0.0
        let pitch = entry.proportional ? Double(spt) : spanPitch(entry, spt)
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

/// The document as a flat list of layout items — Port of `_modern_flow`. A footnote
/// reference resolves through the SAME plumbing the flat emitters use (`resolveReference`/
/// `noteLabel`): a real reference to a kind not in `keep` or a stray/out-of-range sentinel
/// contributes NOTHING at all (no token, unlike RTF/HTML's fallback to plain styled
/// text) — Python's `except (ValueError, IndexError): continue` / `if note.kind not in
/// keep: continue`, both `continue`s with no token appended either.
func modernFlow(_ doc: Document, keep: Set<NoteKind>,
                noteRefs: NoteRefs = .word) -> [ModernFlowItem] {
    let refNotes = inlineReferenceNotes(doc)
    // Reference-mark display per scheme (ruling 2026-08-06 M8): `word` shows arabic
    // footnotes / roman endnotes / annotation tags — what Word itself renders from our
    // RTF; `prefixed` shows the Markdown emitter's own labels (1 2 3, e1 e2, a1 a2),
    // matched across formats.
    var shownByIndex: [Int: String]
    if noteRefs == .prefixed {
        shownByIndex = noteRefLabels(refNotes, doc: doc, scheme: .prefixed)
    } else {
        shownByIndex = [:]
        var ords: [NoteKind: Int] = [:]
        for (i, note) in refNotes.enumerated() {
            let k = (ords[note.kind] ?? 0) + 1
            ords[note.kind] = k
            let label = noteLabel(note, doc: doc)
            switch note.kind {
            case .endnote:
                shownByIndex[i] = endnoteRomanLabel(label)
            case .comment:
                // self-identifying in the end list either scheme; under `word` there
                // is no inline mark to match anyway (M9)
                shownByIndex[i] = "c" + String(k)
            default:
                shownByIndex[i] = label
            }
        }
    }
    // LJ6DTP substitutions apply in Modern too (ruling 2026-08-06 M7): the driver's
    // patched slots are CONTENT — an em dash is an em dash in any century — while its
    // page art (colour, rules, boxes) stays print-time.
    let lj = doc.printerDriver == "LJ6DTP"
    // one WordStar column in points, at the document's own `.cw`
    let colPt = (doc.page?.cw120 ?? 12.0) * 0.6
    var hfByBlock: [Int: [(kind: HFKind, line: Int, text: String)]] = [:]
    for event in doc.hfEvents {
        hfByBlock[event.blockAnchor, default: []].append((event.kind, event.line, event.text))
    }
    var flow: [ModernFlowItem] = []
    var endPairs: [(index: Int, note: Note, shown: String)] = []
    var endSeen: Set<Int> = []            // endnotes/annotations, document order
    let blankH = modernLine * Double(modernBodyPt)
    for (bi, block) in doc.blocks.enumerated() {
        for event in hfByBlock[bi] ?? [] {
            flow.append(.hf(kind: event.kind, line: event.line, text: event.text))
        }
        if block.kind == .pagebreak {
            flow.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            flow.append(.cond(max(1, block.heading)))
            continue
        }
        let lm = block.leftMargin ?? 0
        let indent = lm * colPt
        let rm = block.rightMargin ?? 0
        // `.rm` narrows the measure from the document's full line (`maxCols`, the same
        // 65 columns the era page gives); a block at the default 65 cuts nothing
        let cut = rm != 0 ? max(0.0, Double(PDFMetrics.maxCols) - rm) * colPt : 0.0
        for line in mergedLines(block) {
            if line.spans.isEmpty {
                flow.append(.blank(blankH))
                continue
            }
            var spans = line.spans
            if lm != 0 {
                // WordStar stamps `.lm` onto every line it writes; the indent is carried
                // by the BLOCK now, so the stamped spaces come off the front (whatever
                // indent remains past `.lm` is the author's own tab and stays)
                var drop = lm
                while drop > 0, !spans.isEmpty {
                    let chars = Array(spans[0].text)
                    var take = 0
                    while take < chars.count, Double(take) < drop, chars[take] == " " {
                        take += 1
                    }
                    if take == 0 { break }
                    drop -= Double(take)
                    if take < chars.count {
                        spans[0].text = String(chars[take...])
                        break
                    }
                    spans.removeFirst()
                }
            }
            var toks: [ModernToken] = []
            var notes: [(index: Int, note: Note, label: String)] = []
            for span in spans {
                if span.pctlHMI != nil {
                    // a 0x0F print control's display string is SCREEN-ONLY; the paper
                    // got the raw payload. Printed pads its HMI width; Modern shows
                    // nothing — command codes are invisible (M4, extended M10)
                    continue
                }
                var styles = span.styles
                if block.heading != 0 { styles.insert(.bold) }
                styles.formUnion(block.styleAttrs)
                if span.styles.contains(.fnref) {
                    // Python's `except (ValueError, IndexError): continue` / kind-filter
                    // `continue` — a stray sentinel or excluded kind contributes NOTHING.
                    guard let n = Int(span.text), n >= 1, n <= refNotes.count else { continue }
                    let note = refNotes[n - 1]
                    guard keep.contains(note.kind) else { continue }
                    let label = noteLabel(note, doc: doc)
                    let shown = shownByIndex[n - 1] ?? label
                    if note.kind != .comment || noteRefs == .prefixed {
                        // `word` comments are markless (Word's bubble convention);
                        // `prefixed` shows the c-mark (M9)
                        let width = modernTokenWidth(shown, styles: styles, family: .times,
                                                     pt: modernBodyPt, entry: nil)
                        toks.append(ModernToken(text: shown, styles: styles, family: .times,
                                                pt: modernBodyPt, entry: nil, width: width))
                    }
                    if note.kind == .footnote {
                        notes.append((n - 1, note, label))
                    } else if !endSeen.contains(n - 1) {
                        endSeen.insert(n - 1)
                        endPairs.append((n - 1, note, shown))
                    }
                    continue
                }
                for piece in splitKeepingSpaceRuns(span.text) {
                    let resolved = modernTokFont(piece, font: span.font, fonts: doc.fonts)
                    var written = resolved.written
                    if lj, let entry = resolved.entry, entry.proportional {
                        written = ljSubstituteText(written, entry: entry)
                    }
                    let width = modernTokenWidth(written, styles: styles,
                                                 family: resolved.family, pt: resolved.pt,
                                                 entry: resolved.entry)
                    toks.append(ModernToken(text: written, styles: styles,
                                            family: resolved.family, pt: resolved.pt,
                                            entry: resolved.entry, width: width))
                }
            }
            if block.align == .center || block.align == .right {
                // WordStar 5+ aligned at EDITOR time — the centering is already in the
                // file as spaces (the same fact the WS4 `.oj` DOSBox probe proved for
                // justification). Applying the stored tag on top of the baked spaces
                // aligned twice; the spaces come off and the tag does the work (ruling
                // 2026-08-06 M3 — no per-document exceptions).
                while let first = toks.first, first.text.trimmed().isEmpty {
                    toks.removeFirst()
                }
                while let last = toks.last, last.text.trimmed().isEmpty {
                    toks.removeLast()
                }
            }
            flow.append(.para(toks: toks, align: block.align, notes: notes,
                              indent: indent, cut: cut))
        }
        // Only the author's own blank lines make space (ruling 2026-08-06 M4): a block
        // boundary is often just a dot command, and command codes are invisible.
        // `mergedLines` buffered these away; count them back.
        for _ in 0..<trailingBlankLines(block) {
            flow.append(.blank(blankH))
        }
    }
    if !endPairs.isEmpty {
        // Endnotes and annotations at the true end, after the last body line — flowing,
        // not bottom-anchored — behind the same 20-dash separator the page-bottom notes
        // use. No heading: WordStar never printed one (any "Notes" heading in a period
        // document was typed).
        flow.append(.blank(blankH))
        let separator = String(repeating: "-", count: 20)
        let sepW = stringWidthPt(separator, "Times-Roman", modernNotePt)
        flow.append(.para(toks: [ModernToken(text: separator, styles: [], family: .times,
                                             pt: modernNotePt, entry: nil, width: sepW)],
                          align: .left, notes: [], indent: 0.0, cut: 0.0))
        for pair in endPairs {
            flow.append(.para(toks: modernNoteToks(pair.note, label: pair.shown),
                              align: .left, notes: [], indent: 0.0, cut: 0.0))
        }
    }
    return flow
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

/// One note as `[label] text` tokens of Times `modernNotePt`. Port of `_modern_note_toks`.
func modernNoteToks(_ note: Note, label: String) -> [ModernToken] {
    let text = "[\(label)] \(note.text)"
    var toks: [ModernToken] = []
    for piece in splitKeepingSpaceRuns(text) {
        let width = stringWidthPt(piece, "Times-Roman", modernNotePt)
        toks.append(ModernToken(text: piece, styles: [], family: .times, pt: modernNotePt,
                                entry: nil, width: width))
    }
    return toks
}

/// A page-bottom note as wrapped visual lines of Times `modernNotePt`. Port of
/// `_modern_note_lines`.
func modernNoteLines(_ note: Note, label: String, width: Double) -> [[ModernToken]] {
    modernWrap(modernNoteToks(note, label: label), width: width)
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
        if let entry = tok.entry, tok.text.contains(where: { graphicChars.contains($0) }) {
            // split mixed tokens: graphic runs draw as vectors at the cell advance,
            // interleaved text renders through the normal (recursive) path
            let pitch = entry.proportional ? Double(spt) : spanPitch(entry, spt)
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
                ops += graphicOps(run, x: gx, y: y, pitch: pitch, pt: spt)
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
    let flow = modernFlow(doc, keep: keep, noteRefs: options.noteRefs)
    let noteLead = modernLine * Double(modernNotePt)
    let sepH = noteLead

    typealias BodyLine = (y: Double, toks: [ModernToken], align: Alignment,
                          indent: Double, cut: Double)
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
        case .blank(let h):
            guard !body.isEmpty else { continue }         // no blank at a page top
            if y - h < margb + noteBlockH() {
                close()
                continue
            }
            y -= h
        case .para(let toks, let align, let notes, let indent, let cut):
            let lineW = max(36.0, width - indent - cut)
            let vis = modernWrap(toks, width: lineW)
            var newNoteLines: [[ModernToken]] = []
            for entry in notes where !seenNotes.contains(entry.index) {
                newNoteLines += modernNoteLines(entry.note, label: entry.label, width: width)
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
                body.append((y, vline, align, indent, cut))
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
