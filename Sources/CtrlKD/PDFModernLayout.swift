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
              notes: [(index: Int, label: String, text: String)],
              indent: Double, cut: Double)
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
        // and '?' is nobody's take -- the geometry IS the glyph. Printed keeps its
        // fontless-untouched doctrine; Modern draws the shape at the em advance.
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

/// The MEASURED Modern flow: `modernSemanticFlow`'s semantic items (the single
/// implementation of the M-rules — see `Layout.swift`'s contract) converted to this
/// emitter's tokens. This adapter adds exactly what a PDF needs — font resolution, AFM
/// widths, points — and decides nothing about WHAT renders: that is the semantic layer's
/// job, shared with the app's native text stack and the `layout` JSON emitter. Port of
/// `_modern_flow` (post-facade, task #15).
func modernFlow(_ doc: Document, keep: Set<NoteKind>,
                noteRefs: NoteRefs = .word) -> [ModernFlowItem] {
    let sem = modernSemanticFlow(doc, notes: keep, noteRefs: noteRefs)
    // one WordStar column in points, at the document's own `.cw`
    let colPt = (doc.page?.cw120 ?? 12.0) * 0.6
    let blankH = modernLine * Double(modernBodyPt)
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
                              align: .left, notes: [], indent: 0.0, cut: 0.0))
        case .note(_, let label, let text):
            flow.append(.para(toks: modernNoteToks(label: label, text: text),
                              align: .left, notes: [], indent: 0.0, cut: 0.0))
        case .para(let align, let indentCols, let cutCols, let runs, let footnotes):
            var toks: [ModernToken] = []
            for run in runs {
                var styles = run.styles
                if run.ref != nil {
                    // a reference mark: Times at the body size, measured as-is
                    styles.insert(.fnref)
                    let width = modernTokenWidth(run.text, styles: styles, family: .times,
                                                 pt: modernBodyPt, entry: nil)
                    toks.append(ModernToken(text: run.text, styles: styles, family: .times,
                                            pt: modernBodyPt, entry: nil, width: width))
                    continue
                }
                for piece in splitKeepingSpaceRuns(run.text) {
                    let resolved = modernTokFont(piece, font: run.font, fonts: doc.fonts)
                    let width = modernTokenWidth(resolved.written, styles: styles,
                                                 family: resolved.family, pt: resolved.pt,
                                                 entry: resolved.entry)
                    toks.append(ModernToken(text: resolved.written, styles: styles,
                                            family: resolved.family, pt: resolved.pt,
                                            entry: resolved.entry, width: width))
                }
            }
            let notes = footnotes.map {
                (index: $0.index, label: $0.label, text: sem.notes[$0.index].text)
            }
            flow.append(.para(toks: toks, align: align, notes: notes,
                              indent: indentCols * colPt, cut: cutCols * colPt))
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
func modernNoteToks(label: String, text noteText: String) -> [ModernToken] {
    let text = "[\(label)] \(noteText)"
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
func modernNoteLines(label: String, text: String, width: Double) -> [[ModernToken]] {
    modernWrap(modernNoteToks(label: label, text: text), width: width)
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
