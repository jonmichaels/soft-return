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

public func emitText(_ doc: Document, mode: EmitMode = .modern) -> String {
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
        let para = block.lines.map { $0.text() }.joined(separator: "\n")
        // emit.py:69 — in printed mode an all-whitespace paragraph is still a printed
        // paragraph and is kept.
        if !para.trimmed().isEmpty || mode == .printed {
            out.append(para)
        }
    }

    // emit.py:71-72 — note the modern branch ALSO filters blank entries a second time.
    var text: String
    if mode == .printed || isPrinted(doc) {
        text = out.joined(separator: "\n")
    } else {
        text = out.filter { !$0.trimmed().isEmpty }.joined(separator: "\n\n")
    }

    if !doc.footnotes.isEmpty {
        let notes = doc.footnotes.enumerated().map { i, note in
            "[\(i + 1)] " + note.map(\.text).joined()
        }
        text += "\n\n" + notes.joined(separator: "\n")
    }
    return text + "\n"
}
