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
/// One span, plain text: an ordinary span passes through unchanged; an `fnref` span
/// becomes `[label]` when its note is included, vanishes entirely when the note's kind is
/// opted out, and degrades to its own raw digits when it isn't actually a reference at all
/// (task item 3 — a stray `0x07` byte has nothing behind it to bracket).
private func textSpan(_ span: Span, refNotes: [Note], doc: Document, options: EmitOptions) -> String {
    guard span.styles.contains(.fnref) else { return span.text }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(_, let label): return "[\(label)]"
    case .excluded: return ""
    case .invalid: return span.text
    }
}

@Sendable
/// The column text is laid out within, for centring and right-alignment. `.rm` is what
/// WordStar itself measures against (the archive's common values are 65 and 60); absent
/// that, the 65 this project already wraps at.
func textWidth(_ doc: Document) -> Int {
    PDFMetrics.maxCols
}

/// Centre or right-align a block's lines within the text width. Register C16/C17.
///
/// `justify` is deliberately NOT padded: WordStar justifies by widening the spaces it
/// already has, and a plain-text rendering that padded to a hard column would fabricate
/// whitespace the author never typed. Left and justify therefore render identically here,
/// and the distinction survives in the IR for the formats that CAN express it.
func alignLines(_ lines: [String], _ align: Alignment, _ doc: Document) -> [String] {
    guard align == .center || align == .right else { return lines }
    let width = textWidth(doc)
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
    var out: [String] = []
    for block in doc.blocks {
        if block.kind == .softpage {
            // WordStar's own pagination: meaningful only line-for-line (emit.py:61-64).
            if mode == .printed { out.append("\u{0C}") }
            continue
        }
        if block.kind == .pagebreak {
            out.append(mode == .printed ? "\u{0C}" : "\n" + String(repeating: "-", count: 20) + "\n")
            continue
        }
        // printed: PHYSICAL lines (soft returns broke the line on paper); modern:
        // logical lines, soft runs joined back (`mergedLines`, ctrl-kd 2.0.0).
        let rendered = (printed ? block.lines : mergedLines(block))
            .map { line in line.spans.map { textSpan($0, refNotes: refNotes, doc: doc, options: options) }.joined() }
        let para = alignLines(rendered, block.align, doc).joined(separator: "\n")
        // emit.py:69 — in printed mode an all-whitespace paragraph is still a printed
        // paragraph and is kept.
        if !para.trimmed().isEmpty || mode == .printed {
            out.append(para)
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
        let entries = noteListEntries(doc, kind: kind)
        guard !entries.isEmpty else { return nil }
        let lines = entries.map { "[\($0.label)] \($0.note.text)" }
        return noteSectionTitle(kind) + ":\n" + lines.joined(separator: "\n")
    }
    if !sections.isEmpty {
        text += "\n\n" + sections.joined(separator: "\n\n")
    }
    return text + "\n"
}
