/// Plain-text emitter. Direct port of `_printed` (emit.py:53-54) and `emit_text`
/// (emit.py:58-76).

/// Which rendering convention an emitter should use.
public enum EmitMode: String, Hashable, Sendable {
    /// Reflow for modern reading: paragraphs separated by blank lines, WordStar's own
    /// pagination dropped.
    case modern
    /// Reproduce the page as printed: every line kept, form feeds preserved.
    case printed
}

/// True when the document's layout IS its content — a print-to-disk capture, or anything
/// a `.r!` ruler marked columnar. Such documents are always rendered line-for-line, even
/// when the caller asked for `modern`, because reflowing them destroys the alignment that
/// carries the meaning. emit.py:53-54.
public func isPrinted(_ doc: Document) -> Bool {
    doc.detection?.variant == .printstream || doc.columnar
}

/// - Parameter options: accepted and ignored, as Python's `**_options` is (emit.py:58).
///   Present so every emitter has the one signature `Emitter.emit` stores.
///
/// `@Sendable` here (and on the other three) is what lets the function be stored directly in
/// an `Emitter` without a wrapper closure: an emitter is a pure function of its arguments,
/// holding no state between calls, so it is safe to call from any thread — and the compiler
/// should be told so rather than have the guarantee laundered through a `{ }`.
/// TXT's own note-marker wrapper (ruling 2026-08-24 item 3, Jon verbatim: "[1]
/// Footnote (1) Endnote. Use the same bracket or parenthesis in the body."): footnotes
/// (and annotations/comments, unchanged from before this ruling) keep brackets;
/// endnotes switch to parentheses so a footnote and an endnote are distinguishable
/// inline, not just in the trailing section. Applies identically to the inline body
/// marker and the trailing section entry — the ruling's own wording ("the body") plus
/// its own worked entry format (`(1)`) cover both. Port of `_txt_note_mark`.
func textNoteMark(_ kind: NoteKind, _ label: String) -> String {
    kind == .endnote ? "(\(label))" : "[\(label)]"
}

/// One span, plain text: an ordinary span passes through unchanged; an `fnref` span
/// becomes its note mark (`textNoteMark`) when its note is included, vanishes entirely
/// when the note's kind is opted out, and degrades to its own raw digits when it isn't
/// actually a reference at all (task item 3 — a stray `0x07` byte has nothing behind it
/// to bracket). `labels` is the document's already-resolved display labels — see
/// `resolveReference`'s doc comment.
private func textSpan(_ span: Span, refNotes: [Note], labels: [String], options: EmitOptions,
                      printed: Bool) -> String {
    if let hmi = span.pctlHMI {
        // screen-only display string: printed pads the declared width, modern shows
        // nothing (M4 extended, 2026-08-06 M10)
        guard printed else { return "" }
        return String(repeating: " ", count: max(0, roundHalfToEven(Double(hmi) / 180.0)))
    }
    guard span.styles.contains(.fnref) else { return span.text }
    switch resolveReference(span, refNotes: refNotes, labels: labels, options: options) {
    case .note(let note, let label, _):
        // comments are never marked inline in plain text: the kind has no printed
        // identity (word scheme = markless); opted-in comments appear in the Comments
        // section (M9)
        return note.kind == .comment ? "" : textNoteMark(note.kind, label)
    case .excluded: return ""
    case .invalid: return span.text
    }
}

@Sendable
/// The column this BLOCK's text is laid out within, for centring and right-alignment.
///
/// `.rm` is what WordStar itself measures against, and it is per-block because it is
/// stateful — a quoted passage narrows the margin and the passage after it widens back.
/// The archive's most common values are 65 and 60. Absent any `.rm`, fall back to the
/// width the rest of this project already wraps at.
///
/// `.lm` is added back on: WordStar centres BETWEEN the two margins, so a block indented
/// to column 5 with a right margin at 60 centres about column 32, not column 30.
func textWidth(_ block: Block) -> Int {
    let rm = (block.rightMargin ?? 0) > 0 ? block.rightMargin! : Double(PDFMetrics.maxCols)
    // leftMargin is OFFSET columns (normalised 2026-08-06): text occupies columns
    // lm+1 .. rm, so WordStar's centre line is (lm + 1 + rm) / 2.
    return Int(rm + (block.leftMargin ?? 0) + 1)
}

/// Centre or right-align a block's lines within the text width. Register C16/C17.
///
/// `justify` is deliberately NOT padded: WordStar justifies by widening the spaces it
/// already has, and a plain-text rendering that padded to a hard column would fabricate
/// whitespace the author never typed. Left and justify therefore render identically here,
/// and the distinction survives in the IR for the formats that CAN express it.
func alignLines(_ lines: [String], _ block: Block) -> [String] {
    let align = block.align
    guard align == .center || align == .right else { return lines }
    let width = textWidth(block)
    return lines.map { line in
        let stripped = line.trimmed()
        if stripped.isEmpty { return line }
        let pad = width - stripped.count
        if pad <= 0 { return stripped }
        return String(repeating: " ", count: align == .center ? pad / 2 : pad) + stripped
    }
}

public func emitText(_ doc: Document, mode: EmitMode = .modern,
                     options: EmitOptions = EmitOptions()) -> String {
    let refNotes = inlineReferenceNotes(doc)
    let printed = mode == .printed || isPrinted(doc)
    var options = options
    if printed {
        // printed is always silent about comments (ruling 2026-08-06 M9): WordStar
        // printed nothing for them, sections included
        options.notes.remove(.comment)
    }
    // Printed is a physical-line facsimile with real `\f` page breaks -- WordStar's own
    // per-page footnote numbers stay unambiguous there, same as Printed/Modern PDF
    // (ruling 2026-08-24: "Printed... keep WS7's per-page numbering"). Only Modern TXT
    // is genuinely page-less.
    let labels = printed ? annotatedNoteLabels(doc) : pagelessNoteLabels(doc)
    // N9 (b33 field notes): mode-aware default, flag overrides either way.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: printed)
    func render(_ line: Line) -> String {
        var seg = line.spans.map { textSpan($0, refNotes: refNotes, labels: labels, options: options,
                                            printed: printed) }
        if ssOn { seg = sentenceSpacingTexts(seg) }
        return seg.joined()
    }
    var out: [String] = []
    let margin = docMargin(doc)
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    // b24 round 20b (slate item 13): screenplay-detected regions get the SAME
    // verse-class (line-structure-preserving) treatment as a verified verse/stanza
    // unit -- computed once per document, not printed (a facsimile already preserves
    // every line's own position; detection only changes REFLOW behavior).
    let screenplayBlocks = printed ? [] : detectScreenplayBlocks(doc)
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak {
            out.append(mode == .printed ? "\u{0C}" : "\n" + String(repeating: "-", count: 20) + "\n")
            continue
        }
        if printed {
            // PHYSICAL lines: soft returns broke the line on paper.
            let lines = alignLines(block.lines.map(render), block)
            let para = lines.joined(separator: "\n")
            // emit.py:69 — in printed mode an all-whitespace paragraph is still a
            // printed paragraph and is kept.
            if !para.trimmed().isEmpty || mode == .printed {
                out.append(para)
            }
            continue
        }
        // Modern: one `out` entry per PARAGRAPH UNIT, not per block, so the blank-line
        // join below separates typed paragraphs from each other, not just Blocks from
        // each other. Within a unit, a bare newline is reserved for a REAL deliberate
        // break — a verified verse/stanza unit (round 3b: "no hard line breaks inside
        // paragraphs in ANY Modern format"). A multi-line unit that never got
        // verse-verified (bare phase-1 flush-continuation) flows as ONE line instead.
        let quote = isQuoteStyle(block)
        let dominant = blockDominantStyles(mergedLines(block))
        for unit in assembleParagraphs(block, margin: margin,
                                       headPosition: headPosition[bi] ?? false,
                                       conventionIndent: conventionIndent) {
            // round 7 (Register C23): a wrap=off block's unit is ALWAYS verse here --
            // assembleParagraphs already returns it as one whole-block unit
            // unconditionally, but without this guard a non-verse multi-line unit still
            // gets flowed into one run-on line, destroying a hand-positioned layout.
            let isVerse = unit.count > 1 && (!block.wrap || looksLikeVerse(unit, dominantStyles: dominant)
                                             || screenplayBlocks.contains(bi))
            var lines: [String]
            if unit.count > 1, !isVerse {
                // only the unit's own FIRST line keeps its typed indent (the
                // paragraph-start marker); continuation lines lose theirs the same
                // way a genuine soft-wrap already would have.
                var segs = [render(unit[0])]
                segs.append(contentsOf: unit.dropFirst().map {
                    String(render($0).drop(while: { $0 == " " }))
                })
                let joined = segs.filter { !$0.trimmed().isEmpty }.joined(separator: " ")
                lines = alignLines([joined], block)
            } else {
                lines = alignLines(unit.map(render), block)
            }
            if quote {
                // rule 3: plain text's only "quote" vocabulary is indentation, and the
                // source's own typed depth is inconsistent block to block. Normalize:
                // every line of every quote-block paragraph gets the SAME flat 4-space
                // indent, distinct from a body paragraph's own 5-space-first-line-then-
                // flush scheme.
                lines = lines.map { l in
                    l.trimmed().isEmpty ? l : "    " + String(l.drop(while: { $0 == " " }))
                }
            }
            let para = lines.joined(separator: "\n")
            if !para.trimmed().isEmpty {
                out.append(para)
            }
        }
    }

    // emit.py:71-72 — note the modern branch ALSO filters blank entries a second time.
    var text: String
    if printed {
        text = out.joined(separator: "\n")
    } else {
        text = out.filter { !$0.trimmed().isEmpty }.joined(separator: "\n\n")
    }

    // One labelled section per included, non-empty kind, in `noteKindOrder` — "Footnotes:"/
    // "Endnotes:"/"Annotations:"/"Comments:" followed by its "[label] text" lines.
    let sections = noteKindOrder.compactMap { kind -> String? in
        guard options.notes.contains(kind) else { return nil }
        let entries = noteListEntries(doc, kind: kind, labels: labels)
        guard !entries.isEmpty else { return nil }
        let lines = entries.map { entry -> String in
            let text = ssOn ? sentenceSpacingTexts([entry.note.text])[0] : entry.note.text
            return "\(textNoteMark(kind, entry.label)) \(text)"
        }
        return noteSectionTitle(kind) + ":\n" + lines.joined(separator: "\n")
    }
    if !sections.isEmpty {
        text += "\n\n" + sections.joined(separator: "\n\n")
    }
    // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index at the document's own end, gated by
    // `--toc` (default off). Text is a non-paged format even in its own "printed" mode (a
    // physical-line facsimile, not a page model) — no page references, ever.
    if options.toc {
        let tocLines = plainTOCIndexLines(doc)
        if !tocLines.isEmpty {
            text += "\n\n" + tocLines.joined(separator: "\n")
        }
    }
    return text + "\n"
}
