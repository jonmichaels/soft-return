/// Markdown emitter. Direct port of `_md_span` (emit.py:83-101) and `emit_markdown`
/// (emit.py:103-125), with their `_MD`/`_MD_HTML` tables (emit.py:80-81).

/// Styles Markdown expresses with symmetric delimiters (emit.py:80).
private let markdownDelimiters: [(style: Style, delimiter: String)] = [
    (.bold, "**"),
    (.italic, "*"),
    (.strike, "~~"),
]

/// Styles with no Markdown syntax, emitted as inline HTML instead (emit.py:81).
private let markdownHTMLTags: [(style: Style, tag: String)] = [
    (.underline, "u"),
    (.sup, "sup"),
    (.sub, "sub"),
]

/// Characters Markdown would otherwise interpret (emit.py:90).
private let markdownEscapes: [Character] = ["*", "_", "#", "`", "[", "]"]

/// One span -> Markdown. emit.py:83-101.
///
/// NOTE ON STYLE ORDER: Python iterates `s.styles`, a `frozenset`, so for a span carrying
/// two or more *wrapping* styles the nesting order — and therefore the exact output — is
/// whatever that set's iteration order happens to be, which varies with `PYTHONHASHSEED`
/// between processes (`{b, strike}` emits `**~~w~~**` under one seed and `~~**w**~~` under
/// another). Swift has no such nondeterminism, so this applies styles in a FIXED,
/// documented order: delimiter styles (bold, italic, strike) innermost-first, then HTML
/// tag styles (u, sup, sub) outside them. For single-style spans — every case the vectors
/// exercise, and the overwhelming majority of real documents — this is identical to
/// Python. For multi-style spans it is one of several orderings Python might produce, and
/// deliberately the stable one. See the job-008 response: the Python side is the thing
/// that needs fixing here, not this port.
func markdownSpan(_ span: Span) -> String {
    // emit.py:85-86 — footnote references short-circuit BEFORE any styling, which is why
    // the {fnref, sup} span never reaches the ordering loop above.
    if span.styles.contains(.fnref) {
        return "[^\(span.text)]"
    }
    // emit.py:87-88 — whitespace-only spans pass through untouched and unescaped.
    if span.text.trimmed().isEmpty {
        return span.text
    }

    // emit.py:89-91 — backslash first, or the escapes added below get double-escaped.
    var escaped = span.text.replacingAll("\\", with: "\\\\")
    for character in markdownEscapes {
        escaped = escaped.replacingAll(character, with: "\\" + String(character))
    }

    // emit.py:92-94 — peel the outer whitespace off, style only the core, reattach. Markup
    // wrapped around leading/trailing spaces doesn't render.
    let lead = escaped.leadingWhitespace()
    let trail = escaped.trailingWhitespace()
    var core = escaped.trimmed()

    for entry in markdownDelimiters where span.styles.contains(entry.style) {
        core = entry.delimiter + core + entry.delimiter
    }
    for entry in markdownHTMLTags where span.styles.contains(entry.style) {
        core = "<\(entry.tag)>" + core + "</\(entry.tag)>"
    }
    return lead + core + trail
}

/// - Parameter options: accepted and ignored, as Python's `**_options` is (emit.py:108).
@Sendable
public func emitMarkdown(_ doc: Document, mode: EmitMode = .modern,
                         options: EmitOptions = EmitOptions()) -> String {
    // emit.py:104-107 — for a printed or columnar document the alignment IS the content, so
    // a fenced block is the honest representation. Delegates to emitText rather than
    // reimplementing the line-for-line layout.
    if mode == .printed || isPrinted(doc) {
        let body = emitText(doc, mode: .printed)
        return "```\n" + body.trimmingTrailing("\n") + "\n```\n"
    }

    var out: [String] = []
    for block in doc.blocks {
        if block.kind == .softpage {
            continue                                // dropped entirely in modern mode
        }
        if block.kind == .pagebreak {
            out.append("---")
            continue
        }
        let lines = block.lines.map { line in
            line.spans.map(markdownSpan).joined()
        }
        // emit.py:116 — hard line breaks inside a paragraph become a trailing backslash.
        var para = lines.joined(separator: "\\\n")
        if block.heading != 0 && !para.trimmed().isEmpty {
            para = String(repeating: "#", count: block.heading) + " " + para.trimmed()
        }
        if !para.trimmed().isEmpty {
            out.append(para)
        }
    }

    var md = out.joined(separator: "\n\n")
    if !doc.footnotes.isEmpty {
        let notes = doc.footnotes.enumerated().map { i, note in
            "[^\(i + 1)]: " + note.map(\.text).joined()
        }
        md += "\n\n" + notes.joined(separator: "\n")
    }
    return md + "\n"
}
