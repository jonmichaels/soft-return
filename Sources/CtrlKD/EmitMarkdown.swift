/// Markdown emitter. Direct port of `_md_span` (emit.py:83-101) and `emit_markdown`
/// (emit.py:103-125), with their `_MD`/`_MD_HTML` tables (emit.py:80-81).

/// Styles Markdown expresses with symmetric delimiters (emit.py:80).
private let markdownDelimiters: [(style: Style, delimiter: String)] = [
    (.bold, "**"),
    (.italic, "*"),
    (.strike, "~~"),
]

/// Styles with no Markdown syntax, emitted as inline HTML instead (emit.py:81), in the order
/// Python's `sorted(s.styles)` yields the style *codes* `sub, sup, u` — alphabetical, same as
/// `EmitHTML.swift`'s `htmlTags` and `EmitRTF.swift`'s `rtfControlWords`. This was previously
/// `underline, sup, sub` (the reverse), which put `<sub>` outermost instead of `<u>` for any
/// span carrying more than one of these three styles — an internal inconsistency with this
/// port's own HTML/RTF emitters as much as a Python parity bug, since both of those already
/// sort alphabetically and matched Python already.
private let markdownHTMLTags: [(style: Style, tag: String)] = [
    (.sub, "sub"),
    (.sup, "sup"),
    (.underline, "u"),
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
    // NOTE: this function deliberately does NOT special-case `.fnref` (ctrl-kd 1.2.0 moved
    // that decision up into `emitMarkdown`'s block loop, alongside note-kind selection and
    // the out-of-range guard — see `markdownReferenceSpan` below). An `fnref` span that
    // reaches here is exactly the "not actually a reference" case (task item 3): it falls
    // straight through to the ordinary styling below, which is what turns a stray sentinel
    // into `<sup>1</sup>` rather than a bogus `[^1]`.
    //
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

/// The pandoc/GFM reference key inside `[^…]`: bare for a footnote, `e`-prefixed for an
/// endnote, `a`-prefixed for an annotation (tag-based, not numeric), `c`-prefixed for a
/// comment. Shared between the inline marker and the trailing definition, which use the
/// exact same key — pandoc matches them by string equality.
///
/// `label` is run through `noteSlug` (emit.py's `_note_slug`) before the prefix is attached —
/// footnote/endnote labels are already plain digits so this is a no-op there, but an
/// annotation's tag can carry punctuation (WordStar puts no such restriction on a tag), and an
/// unslugged tag containing `[`/`]` breaks the `[^…]` token it would be embedded in.
private func markdownReferenceKey(_ kind: NoteKind, label: String) -> String {
    let slug = noteSlug(label)
    switch kind {
    case .footnote: return slug
    case .endnote: return "e" + slug
    case .annotation: return "a" + slug
    case .comment: return "c" + slug
    }
}

/// One span, Markdown: an ordinary span goes through `markdownSpan`; a valid, included
/// `fnref` becomes `[^key]` with no styling of its own; an excluded kind's reference
/// vanishes; an invalid one (task item 3) falls back to `markdownSpan`'s ordinary styling,
/// which is what turns a stray sentinel into `<sup>1</sup>`.
private func markdownReferenceSpan(
    _ span: Span, refNotes: [Note], doc: Document, options: EmitOptions
) -> String {
    guard span.styles.contains(.fnref) else { return markdownSpan(span) }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label): return "[^\(markdownReferenceKey(note.kind, label: label))]"
    case .excluded: return ""
    case .invalid: return markdownSpan(span)
    }
}

/// - Parameter options: read for `options.notes` (which kinds get an inline marker and a
///   trailing definition); `options.title` is ignored, as in Python (emit.py:108).
@Sendable
public func emitMarkdown(_ doc: Document, mode: EmitMode = .modern,
                         options: EmitOptions = EmitOptions()) -> String {
    // emit.py:104-107 — for a printed or columnar document the alignment IS the content, so
    // a fenced block is the honest representation. Delegates to emitText rather than
    // reimplementing the line-for-line layout; `options` carries the same note selection
    // through so a printed/columnar document honors it too.
    if mode == .printed || isPrinted(doc) {
        let body = emitText(doc, mode: .printed, options: options)
        return "```\n" + body.trimmingTrailing("\n") + "\n```\n"
    }

    let refNotes = inlineReferenceNotes(doc)
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
            line.spans.map { markdownReferenceSpan($0, refNotes: refNotes, doc: doc, options: options) }.joined()
        }
        // emit.py:116 — hard line breaks inside a paragraph become a trailing backslash.
        var para = lines.joined(separator: "\\\n")
        // emit.py:113-114 — `'#' * b.heading` in Python: for a negative `b.heading` that's an
        // empty string (Python's string-repeat-by-negative rule), never an error. Swift's
        // `String(repeating:count:)` traps on a negative count instead, so clamp to match —
        // `max(0, …)` reproduces Python's "negative repeat is empty" rather than crashing.
        // A negative heading isn't supposed to occur for real WordStar input, but
        // `ParseWS.swift`'s `Int(raw[1]) - 0x30` can go negative on a garbage dot-command
        // byte (e.g. a non-WordStar file `detect()` mistakenly accepted), and a converter
        // must never crash on bytes its own detection let through.
        if block.heading != 0 && !para.trimmed().isEmpty {
            para = String(repeating: "#", count: max(0, block.heading)) + " " + para.trimmed()
        }
        if !para.trimmed().isEmpty {
            out.append(para)
        }
    }

    var md = out.joined(separator: "\n\n")

    // A flat list of `[^key]: text` definitions, `noteKindOrder`'s kinds each contributing
    // their notes in document order — no per-kind grouping or header (pandoc needs none),
    // just one definition per line.
    var defs: [String] = []
    for kind in noteKindOrder where options.notes.contains(kind) {
        for entry in noteListEntries(doc, kind: kind) {
            defs.append("[^\(markdownReferenceKey(kind, label: entry.label))]: \(entry.note.text)")
        }
    }
    if !defs.isEmpty {
        md += "\n\n" + defs.joined(separator: "\n")
    }
    return md + "\n"
}
