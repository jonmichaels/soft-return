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
/// (`('line', ...)` never actually used — see `_modern_flow`'s only real arms —
/// `('para', toks, align, notes)`, `('blank', height)`, `('break',)`, `('cond', n)`).
enum ModernFlowItem {
    case pageBreak
    /// `.cp n` — resolved by the paginator, the only thing that knows how full the page is.
    case cond(Int)
    case blank(Double)
    /// One logical (already soft-wrap-merged) line's tokens, ready for real-measure wrap.
    /// `notes` are the footnote/endnote/annotation notes this line's `fnref` markers
    /// reference — carried with the line so the paginator can reserve their page-bottom
    /// room the moment the line that first names them is placed.
    case para(toks: [ModernToken], align: Alignment, notes: [(note: Note, label: String)])
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
func modernFlow(_ doc: Document, keep: Set<NoteKind>) -> [ModernFlowItem] {
    let refNotes = inlineReferenceNotes(doc)
    let refOptions = EmitOptions(notes: keep)
    var flow: [ModernFlowItem] = []
    for block in doc.blocks {
        if block.kind == .pagebreak {
            flow.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            flow.append(.cond(max(1, block.heading)))
            continue
        }
        for line in mergedLines(block) {
            var toks: [ModernToken] = []
            var notes: [(note: Note, label: String)] = []
            for span in line.spans {
                var styles = span.styles
                if block.heading != 0 { styles.insert(.bold) }
                styles.formUnion(block.styleAttrs)
                if span.styles.contains(.fnref) {
                    switch resolveReference(span, refNotes: refNotes, doc: doc, options: refOptions) {
                    case .note(let note, let label):
                        let width = modernTokenWidth(label, styles: styles, family: .times,
                                                     pt: modernBodyPt, entry: nil)
                        toks.append(ModernToken(text: label, styles: styles, family: .times,
                                                pt: modernBodyPt, entry: nil, width: width))
                        notes.append((note, label))
                    case .excluded, .invalid:
                        break
                    }
                    continue
                }
                for piece in splitKeepingSpaceRuns(span.text) {
                    let resolved = modernTokFont(piece, font: span.font, fonts: doc.fonts)
                    let width = modernTokenWidth(resolved.written, styles: styles,
                                                 family: resolved.family, pt: resolved.pt,
                                                 entry: resolved.entry)
                    toks.append(ModernToken(text: resolved.written, styles: styles,
                                            family: resolved.family, pt: resolved.pt,
                                            entry: resolved.entry, width: width))
                }
            }
            flow.append(.para(toks: toks, align: block.align, notes: notes))
        }
        flow.append(.blank(modernLine * Double(modernBodyPt)))
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

/// A page-bottom note as wrapped visual lines of Times `modernNotePt`. Port of
/// `_modern_note_lines`.
func modernNoteLines(_ note: Note, label: String, width: Double) -> [[ModernToken]] {
    let text = "[\(label)] \(note.text)"
    var toks: [ModernToken] = []
    for piece in splitKeepingSpaceRuns(text) {
        let width = stringWidthPt(piece, "Times-Roman", modernNotePt)
        toks.append(ModernToken(text: piece, styles: [], family: .times, pt: modernNotePt,
                                entry: nil, width: width))
    }
    return modernWrap(toks, width: width)
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
    let flow = modernFlow(doc, keep: keep)
    let noteLead = modernLine * Double(modernNotePt)
    let sepH = noteLead

    var pages: [(body: [(y: Double, toks: [ModernToken], align: Alignment)], notes: [[ModernToken]])] = []
    var body: [(y: Double, toks: [ModernToken], align: Alignment)] = []
    var notesLines: [[ModernToken]] = []
    // Dedup by source offset, not object identity (Python's `id(note)`): `Note` is a
    // value type here, and `.offset` is the field this codebase already uses elsewhere
    // to tell two field-for-field-identical notes apart (`noteLabel`'s `notePosition`).
    var seenNotes: Set<Int> = []
    var y = Double(PDFMetrics.pageHeight) - margt

    func noteBlockH() -> Double {
        notesLines.isEmpty ? 0.0 : sepH + noteLead * Double(notesLines.count)
    }
    func close() {
        pages.append((body, notesLines))
        body = []
        notesLines = []
        y = Double(PDFMetrics.pageHeight) - margt
    }

    for item in flow {
        switch item {
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
        case .para(let toks, let align, let notes):
            let vis = modernWrap(toks, width: width)
            var newNoteLines: [[ModernToken]] = []
            for entry in notes where !seenNotes.contains(entry.note.offset) {
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
                y -= h
                body.append((y, vline, align))
                if vi == 0, !newNoteLines.isEmpty {
                    notesLines.append(contentsOf: newNoteLines)
                    for entry in notes { seenNotes.insert(entry.note.offset) }
                    newNoteLines = []
                }
            }
        }
    }
    close()
    while pages.count > 1, pages[pages.count - 1].body.isEmpty, pages[pages.count - 1].notes.isEmpty {
        pages.removeLast()
    }

    var streams: [[UInt8]] = []
    for page in pages {
        var tzState = hundredths(tzDefault)
        var ops: [[UInt8]] = []
        for line in page.body {
            ops += modernLineOps(line.toks, left: margl, y: line.y, width: width,
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
