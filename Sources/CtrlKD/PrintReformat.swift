/// `.pf on`: the print-time re-wrap of a paragraph WordStar itself broke, and the comment-mark
/// handling it shares with the body walk.

// MARK: - `.pf on`: print-time re-wrap
//
// Planning #270 item 37 (Jon's ruling 2026-09-13, triage Q5: "Yes, support it."),
// MicroPro's own definition (WSFORMAT.TXT, the `.PF` row): "Paragraph realignment while
// printing... When ON, subsequent paragraphs are realigned as they are printed... using
// the left, right, and paragraph margins currently in effect."
//
// WHY A DOCUMENT NEEDS THIS AT ALL. WordStar's EDITOR is a character screen: it wraps at
// a COLUMN COUNT whatever face the text is set in, and stores the break it chose. The
// PRINTER is not: it wraps at the real measure, in the real fonts, at print time. With
// `.pf on` the two can disagree, and the paper is the one that wins. Two measured cases,
// both from the v4 PRISTINE captures:
//
//   `sawyer/REF/REFORM.DOT` — Courier, `.rm 6.5"` at print time but `.rm 5.0"` in the
//   editor (its own `.if 1=0` block, true while editing and false while printing). The
//   file stores "...in editing, but" + soft return + "another to occur during printing";
//   real WS7 prints ONE 63-character line ending "...another to occur". 65 columns is the
//   measure; "during" needs 7 more.
//
//   `sawyer/PRINT.TST` — the OPPOSITE case, and the regression test that matters: all 94
//   of its soft-wrapped lines print EXACTLY as stored ("custom-"/"ized", "de-"/"fault",
//   "docu-"/"ment", "professional-"/"looking"), because nothing changed between edit time
//   and print time.
//
// ONE MEASURE for both: the sum of each span's own printed advance, `spanPitch` —
// WordStar's own HMI for a WS5+ font block, the `.cw`-derived cell otherwise — so a
// Courier paragraph measures in 7.2pt columns and an 11pt Helv one in 5.52pt cells, from
// one formula. (Real per-glyph widths are what the PRINTER used, and decide both captured
// cases identically; `spanPitch` is chosen because it is what this module then DRAWS
// with, so a re-wrapped line can never overflow the right edge its own justification pins
// to.)
//
// SCOPE, deliberately narrow, every bound measurable: only `.pf on` (`off`/`dis`/absent
// keep the stored lines, and ZERO archive documents say `dis`); only a paragraph WordStar
// ITSELF broke — two or more physical lines joined by soft returns, a single stored line
// is never re-broken; only `left`/`justify` blocks with word wrap on (`.aw on`); and never
// a paragraph carrying a tab, a print control, a picture placeholder or an index entry,
// because those spans encode a POSITION. A note reference is deliberately NOT in that
// list: it travels with the word it follows.
//
// A paragraph ends at a HARD return. Soft returns inside it are re-flowable, and an
// ACTIVE SOFT HYPHEN at one of them is discretionary (`Line.softHyphen`): it disappears
// with the break it was made for and is printed again when the break is still needed. A
// TYPED hyphen is text — also a break point, and it survives the break.
//
// Port of ctrl-kd's `pdf.pf_rewrapped_lines`, byte-identical.

/// The 1-based reference indices (an `fnref` span's own text) that point at a COMMENT.
///
/// `symmetricBlocks` numbers every note kind through ONE counter in document order and
/// `refPairs` keeps that order, so the index a mark carries IS the position in
/// `doc.notes`. Port of `pdf._comment_mark_indices`.
func commentMarkIndices(_ doc: Document) -> Set<Int> {
    var out: Set<Int> = []
    for (i, n) in doc.notes.enumerated() where n.kind == .comment { out.insert(i + 1) }
    return out
}

/// `lines` with every COMMENT reference mark removed.
///
/// A WordStar comment PRINTS NOTHING — not the comment, not a number standing in for it.
/// `..` (and its `.IG` spelling) is a non-printing comment LINE: MicroPro's own reference
/// gives it no paper presence at all, and real WS7 confirms it — `sawyer/REF/REFORM.DOT`
/// carries three `..` lines and the v4 PRISTINE capture has no mark, no digit and no
/// shift where they sit. The ^ON comment BLOCK is a different construct and is equally
/// silent on paper (ruling 2026-08-06: "printed ALWAYS silent"), so both origins are
/// dropped here by the same rule.
///
/// The mark is still IR: Modern anchors RTF's `\*\annotation` and HTML's backlink at
/// exactly this position, and Show Invisibles needs somewhere to draw the comment icon.
/// Only the PRINTED surfaces lose it — and they lose it HERE, before anything measures or
/// re-wraps, rather than at the drawing step: a mark that survives into the measure is
/// three columns of width WordStar never spent, and under `.pf on` its characters fuse
/// with the neighbouring text into a word ("123") that then gets printed.
///
/// The identical array back when the document has no comment at all, which is nearly
/// every document, so nothing else can move. Port of `pdf._drop_comment_marks`.
func dropCommentMarks(_ doc: Document, _ lines: [Line]) -> [Line] {
    guard doc.notes.contains(where: { $0.kind == .comment }) else { return lines }
    let marks = commentMarkIndices(doc)
    if marks.isEmpty { return lines }
    func keep(_ s: Span) -> Bool {
        guard s.styles.contains(.fnref), let k = Int(s.text) else { return true }
        return !marks.contains(k)
    }
    var touched = false
    for line in lines where line.spans.contains(where: { !keep($0) }) {
        touched = true
        break
    }
    if !touched { return lines }
    return lines.map { line -> Line in
        let kept = line.spans.filter(keep)
        if kept.count == line.spans.count { return line }
        var copy = line
        copy.spans = kept
        return copy
    }
}

/// True when this span PLACES something rather than merely carrying text — the one
/// reason `.pf on` leaves a paragraph exactly as WordStar stored it.
func pfPositional(_ span: Span) -> Bool {
    span.tabHMI != nil || span.pctlHMI != nil || span.pix != nil || span.pcl != nil
        || span.indexEntry || span.text.contains("\t" as Character)
}

/// The leading run of pure whitespace of one stored physical line, split out of the
/// first span if it only STARTS with one, and the rest. WordStar re-stamps `.lm`/`.pm`
/// as real spaces on every line it writes, so this IS the paragraph's indent, read off
/// the file rather than recomputed from the dot commands.
func pfLeadingIndent(_ line: Line) -> (indent: [Span], rest: [Span]) {
    var head: [Span] = []
    var rest = line.spans
    while let first = rest.first, first.text.trimmed().isEmpty {
        head.append(first)
        rest.removeFirst()
    }
    if var first = rest.first {
        let stripped = String(first.text.drop(while: { $0 == " " }))
        if stripped.count != first.text.count {
            var lead = first
            lead.text = String(first.text.prefix(first.text.count - stripped.count))
            head.append(lead)
            first.text = stripped
            rest[0] = first
        }
    }
    return (head, rest)
}

/// One character of the paragraph being re-wrapped: the character itself and the span it
/// came out of (its text ignored), so the re-wrapped rows can be rebuilt with every
/// attribute intact and coalesced back to runs.
struct PFCell {
    var ch: Character
    var span: Span
    /// Which span of the paragraph this character came out of, or `nil` when the span is
    /// ordinary text. The re-wrap works a character at a time, and two REFERENCE MARKS
    /// that end up side by side must not fuse back into one span the way two runs of
    /// plain text legitimately do — the text of a mark is a pointer, not letters
    /// (`coalesceSpans` states the same rule; here the marks have already been reduced to
    /// characters, so the source index is what tells two of them apart).
    var source: Int?
}

func pfSameAttrs(_ a: Span, _ b: Span) -> Bool {
    a.styles == b.styles && a.font == b.font && a.colour == b.colour
        && a.pctlHMI == b.pctlHMI && a.pix == b.pix && a.pcl == b.pcl
        && a.tabHMI == b.tabHMI && a.tabLeader == b.tabLeader
        && a.indexEntry == b.indexEntry
}

/// One paragraph's physical lines, re-wrapped to `measure` points. `nil` when the
/// paragraph is one this mechanism leaves alone (see the SCOPE note above) — the caller
/// then keeps the stored lines.
func pfRewrapParagraph(_ para: [Line], measure: Double, fonts: [FontChange],
                               size: Int, cache: inout [Int?: Double]) -> [Line]? {
    guard para.count >= 2 else { return nil }
    for line in para where line.spans.contains(where: pfPositional) { return nil }

    func pitch(_ span: Span) -> Double {
        if let w = cache[span.font] { return w }
        let w = spanPitch(spanFontEntry(span.font, fonts), size)
        cache[span.font] = w
        return w
    }
    func width(_ cells: [PFCell]) -> Double {
        cells.reduce(0.0) { $0 + pitch($1.span) }
    }
    var markSeq = 0
    func cells(_ spans: [Span]) -> [PFCell] {
        spans.flatMap { sp -> [PFCell] in
            var src: Int?
            if sp.styles.contains(.fnref) { markSeq += 1; src = markSeq }
            return sp.text.map { PFCell(ch: $0, span: sp, source: src) }
        }
    }

    let firstIndent = pfLeadingIndent(para[0]).indent
    let contIndent = pfLeadingIndent(para[1]).indent
    let firstW = width(cells(firstIndent))
    let contW = width(cells(contIndent))
    guard measure - max(firstW, contW) > 0 else { return nil }

    // The paragraph's text as one run, joined the way `mergedLines` joins a soft-wrapped
    // run. `dis` collects the DISCRETIONARY hyphen positions: a break there prints a '-'
    // and no break there prints nothing, which is why the character itself is not in the
    // run.
    var chars: [PFCell] = []
    var dis: Set<Int> = []
    for (k, line) in para.enumerated() {
        var run = cells(pfLeadingIndent(line).rest)
        if k < para.count - 1 {
            if line.softHyphen, run.last?.ch == "-" {
                run.removeLast()
                dis.insert(chars.count + run.count)
            } else if let last = run.last, last.ch != " ", last.ch != "-" {
                run.append(PFCell(ch: " ", span: last.span, source: nil))
            }
        }
        chars.append(contentsOf: run)
    }
    guard !chars.isEmpty else { return nil }

    // TOKENS: (leading spaces, body, what ends it). A break may be taken between any two
    // tokens; the spaces that separate them stay on the line that is finished, exactly
    // where WordStar itself stores them.
    enum PFEnd { case plain, typed, discretionary }
    var tokens: [(gap: [PFCell], body: [PFCell], end: PFEnd)] = []
    var i = 0
    while i < chars.count {
        var gap: [PFCell] = []
        while i < chars.count, chars[i].ch == " " { gap.append(chars[i]); i += 1 }
        var body: [PFCell] = []
        var end = PFEnd.plain
        while i < chars.count {
            if dis.contains(i), !body.isEmpty { end = .discretionary; break }
            if chars[i].ch == " " { break }
            body.append(chars[i])
            i += 1
            if body[body.count - 1].ch == "-" { end = .typed; break }   // TYPED hyphen
        }
        tokens.append((gap, body, end))
    }

    let hyphW = pitch(chars[chars.count - 1].span)
    var rows: [[PFCell]] = []
    var cur: [PFCell] = []
    var curW = firstW
    var prevEnd = PFEnd.plain
    for token in tokens {
        let gw = width(token.gap), bw = width(token.body)
        // a token a break may follow with a PRINTED hyphen has to leave room for it
        let need = gw + bw + (token.end == .discretionary ? hyphW : 0.0)
        if !cur.isEmpty, curW + need > measure + 1e-6 {
            if prevEnd == .discretionary {
                cur.append(PFCell(ch: "-", span: cur[cur.count - 1].span, source: nil))
            }
            cur.append(contentsOf: token.gap)
            rows.append(cur)
            cur = token.body
            curW = contW + bw
        } else {
            cur.append(contentsOf: token.gap)
            cur.append(contentsOf: token.body)
            curW += gw + bw
        }
        prevEnd = token.end
    }
    if !cur.isEmpty { rows.append(cur) }

    var out: [Line] = []
    for (k, row) in rows.enumerated() {
        var spans: [Span] = []
        var prevSource: Int?
        for cell in row {
            if let last = spans.last, pfSameAttrs(last, cell.span), cell.source == prevSource {
                spans[spans.count - 1].text.append(cell.ch)
            } else {
                var fresh = cell.span
                fresh.text = String(cell.ch)
                spans.append(fresh)
            }
            prevSource = cell.source
        }
        let src = k == 0 ? para[0] : para[1]
        out.append(Line(spans: coalesceSpans((k == 0 ? firstIndent : contIndent) + spans),
                        soft: k < rows.count - 1 || para[para.count - 1].soft,
                        lead48: src.lead48, kerning: src.kerning, poCols: src.poCols,
                        roll48: src.roll48, poeCols: src.poeCols, pooCols: src.pooCols,
                        // the paragraph ends in the font its last stored line ended in
                        fontOut: k == rows.count - 1 ? para[para.count - 1].fontOut : nil))
    }
    return out
}

/// `block.lines` as WordStar PRINTS them: unchanged unless the block is under `.pf on`,
/// in which case every paragraph WordStar itself broke is re-joined and re-wrapped to the
/// margins and fonts in force. See the note above for the rule, the two measured
/// documents and the scope.
///
/// Returns the block's OWN array when this pass re-decided nothing, so a caller can
/// assert "nothing moved" identically for a `.pf on` block WordStar left alone and for
/// every block in every other document.
public func pfRewrappedLines(_ doc: Document, _ block: Block) -> [Line] {
    let base = dropCommentMarks(doc, block.lines)
    guard block.printReformat == "on", block.kind == .para, block.wrap,
          block.align == .left || block.align == .justify else { return base }
    let measure = (block.rightMargin ?? 65.0) * pdfPtPerCol
    let size = printedSize(doc)
    var cache: [Int?: Double] = [:]
    var out: [Line] = []
    var moved = false
    var i = 0
    let lines = base
    while i < lines.count {
        var j = i
        while j < lines.count - 1, lines[j].soft, !lines[j].spans.isEmpty { j += 1 }
        let para = Array(lines[i...j])
        i = j + 1
        let rewrapped = para.allSatisfy { !$0.spans.isEmpty }
            ? pfRewrapParagraph(para, measure: measure, fonts: doc.fonts, size: size,
                                cache: &cache)
            : nil
        if let rewrapped {
            moved = true
            out.append(contentsOf: rewrapped)
        } else {
            out.append(contentsOf: para)
        }
    }
    return moved ? out : base
}
