/// HTML emitter. Direct port of `_html_span` (emit.py:143-154) and `emit_html`
/// (emit.py:156-190), with the `_CSS` blob (emit.py:134-139) and `_TAG` table
/// (emit.py:141).

/// emit.py:134-139, verbatim. This is data, not a style opinion — the vectors compare the
/// generated page byte for byte, embedded newlines included, so reflowing or "tidying" this
/// string breaks equivalence with Python. Change it there first if it ever needs changing.
private let htmlCSS = """
body{max-width:42rem;margin:2rem auto;padding:0 1rem;
font:17px/1.6 Georgia,serif;color:#222}p{margin:0 0 1em}
pre{font:14px/1.5 ui-monospace,Menlo,Consolas,monospace;overflow-x:auto}
hr.pb{border:none;border-top:1px dashed #bbb;margin:2rem 0}
section[role=doc-endnotes]{margin-top:2rem}
section[role=doc-endnotes] h2{font-size:1.1rem}
@media(prefers-color-scheme:dark){body{background:#161616;color:#ddd}
hr.pb{border-top-color:#444}}
"""

/// `_TAG` (emit.py:141), listed in the order Python's `sorted(s.styles)` yields the style
/// *codes*: `b, i, strike, sub, sup, u`. Because each style wraps the accumulated text,
/// that order is observable — `<u><strong>w</strong></u>` and `<strong><u>w</u></strong>`
/// are different strings — so the table order IS the behavior and must not be rearranged.
///
/// `fnref` is deliberately absent: Python does `_TAG.get(st)` and skips a style with no tag,
/// leaving a footnote reference's digits bare inside whatever `sup` also applied. Its
/// alphabetical slot (between `b` and `i`) is therefore unobservable.
private let htmlTags: [(style: Style, tag: String)] = [
    (.bold, "strong"),
    (.italic, "em"),
    (.strike, "s"),
    (.sub, "sub"),
    (.sup, "sup"),
    (.underline, "u"),
]

/// Python's `html.escape(s, quote=True)`. The ampersand must go first or the entities added
/// afterwards get their own `&` escaped; the rest are order-independent.
///
/// `'` -> `&#x27;` is included because `html.escape` does it, though no vector reaches it
/// (see `htmlEscapesApostropheLikePython` in the tests).
func htmlEscape(_ text: String) -> String {
    var out = text.replacingAll("&", with: "&amp;")
    out = out.replacingAll("<", with: "&lt;")
    out = out.replacingAll(">", with: "&gt;")
    out = out.replacingAll("\"", with: "&quot;")
    return out.replacingAll("'", with: "&#x27;")
}

/// One span -> escaped, tagged HTML. emit.py:143-154.
///
/// `keepWS: true` is the `<pre>` path, where the source's own spacing is already
/// significant and the browser will honour it. Everywhere else a run of five or more
/// leading spaces is a deliberate indent (a poem, a typescript block quote) that HTML
/// would otherwise collapse to nothing, so it is re-inflated to `&nbsp;`.
func htmlSpan(_ span: Span, keepWS: Bool = false) -> String {
    var text = htmlEscape(span.text)

    // emit.py:145-149 — five spaces is the threshold, but the count that survives is the
    // FULL leading whitespace run (Python measures with `lstrip()`, which takes tabs too).
    if !keepWS && text.hasPrefix("     ") {
        let lead = text.leadingWhitespace()
        text = String(repeating: "&nbsp;", count: lead.unicodeScalars.count) + text.trimmedLeading()
    }

    for entry in htmlTags where span.styles.contains(entry.style) {
        text = "<\(entry.tag)>" + text + "</\(entry.tag)>"
    }
    return text
}

/// The two-character id prefix DPUB-ARIA rendering uses for one kind: `fn`/`en`/`an`/`cm`.
/// A reference anchor's id is `{prefix}ref{label}`, its note-list destination's id is
/// `{prefix}{label}`, and the backlink from destination to reference points at the first.
private func htmlIDPrefix(_ kind: NoteKind) -> String {
    switch kind {
    case .footnote: return "fn"
    case .endnote: return "en"
    case .annotation: return "an"
    case .comment: return "cm"
    }
}

/// `(ref_id, target_id)` for one note — `"fnref1"`/`"fn1"`, `"enref1"`/`"en1"`,
/// `"anrefAC1"`/`"anAC1"` — kind-prefixed so a footnote #1 and an endnote #1 (genuinely
/// different notes) never collide. Direct port of `_html_ids` (emit.py:354-360).
///
/// `label` goes through `noteSlug`, NOT `htmlEscape`: an id/URL fragment has its own syntax
/// that HTML-escaping (meant for text content — `&amp;`, `&lt;`, …) does nothing to protect —
/// an annotation tag containing `[`, `]`, `?`, or whitespace would otherwise land unescaped
/// inside `id="…"`/`href="#…"`, which is what actually broke before this fix (not merely a
/// parity mismatch: a malformed id/fragment either way).
private func htmlIDs(_ kind: NoteKind, label: String) -> (ref: String, target: String) {
    let prefix = htmlIDPrefix(kind)
    let slug = noteSlug(label)
    return (ref: prefix + "ref" + slug, target: prefix + slug)
}

/// A valid, included reference: `<sup><a id="…ref…" href="#…" role="doc-noteref">label</a></sup>`.
/// Per task spec, `doc-noteref`/`doc-backlink` are the DPUB-ARIA roles used throughout —
/// `doc-footnote`/`doc-endnote` deliberately do not appear (the former is scoped to
/// in-body notes, the latter deprecated for a listitem role; see `htmlNoteListItem` below).
///
/// The id/href use the slugged form (`htmlIDs`); the visible link text stays the raw,
/// HTML-escaped label — display text and identifier are sanitized for different purposes and
/// must not share one sanitizer.
private func htmlReferenceAnchor(_ note: Note, label: String) -> String {
    let ids = htmlIDs(note.kind, label: label)
    let escaped = htmlEscape(label)
    return "<sup><a id=\"\(ids.ref)\" href=\"#\(ids.target)\" role=\"doc-noteref\">\(escaped)</a></sup>"
}

/// One span, HTML: an ordinary span goes through `htmlSpan` unchanged; a valid, included
/// `fnref` becomes the anchor above; an excluded kind's reference vanishes entirely; an
/// invalid one (task item 3 — a stray `0x07` with no note behind it) falls back to
/// `htmlSpan`'s ordinary styling, which already renders it as bare digits inside whatever
/// `sup` it carries (see `htmlSpanFnrefContributesNoTag`).
private func htmlBodySpan(
    _ span: Span, keepWS: Bool = false, refNotes: [Note], doc: Document, options: EmitOptions
) -> String {
    guard span.styles.contains(.fnref) else { return htmlSpan(span, keepWS: keepWS) }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label): return htmlReferenceAnchor(note, label: label)
    case .excluded: return ""
    case .invalid: return htmlSpan(span, keepWS: keepWS)
    }
}

/// One entry in a kind's `<ol>`: the destination id, `data-note-kind`, `data-note-tag` when
/// the note actually carries one, the (escaped, plain-text) note body, and — every kind but
/// comment, which is never referenced inline and so has nothing to link back to — a backlink.
///
/// `data-note-tag` mirrors Python's own condition (emit.py:394): present when `note.tag` is
/// non-nil AND non-empty, not merely "this note's kind is `.annotation`" — the two happen to
/// coincide for a real annotation with a tag, but matching Python's actual condition (rather
/// than the kind) is what keeps this right if that ever isn't so. Its value is the RAW tag,
/// HTML-escaped for display — not the slug used for the id below, which exists only to keep
/// `id`/`href` syntactically valid and was never meant to be shown.
private func htmlNoteListItem(_ entry: NoteListEntry) -> String {
    let kind = entry.note.kind
    let ids = htmlIDs(kind, label: entry.label)
    var li = "<li id=\"\(ids.target)\" data-note-kind=\"\(kind.rawValue)\""
    if let tag = entry.note.tag, !tag.isEmpty {
        li += " data-note-tag=\"\(htmlEscape(tag))\""
    }
    li += ">" + htmlEscape(entry.note.text)
    if kind != .comment {
        li += " <a href=\"#\(ids.ref)\" role=\"doc-backlink\">\u{21A9}</a>"
    }
    return li + "</li>"
}

/// Render a whole standalone page: doctype, head, the CSS above, then one element per
/// block. emit.py:156-190.
///
/// - Parameter options: `options.title` goes in `<title>`, escaped, as in Python
///   (emit.py:156 takes `title=''`, its three siblings do not). `options.notes` decides
///   which note kinds get an inline reference and a trailing `doc-endnotes` section — see
///   `htmlBodySpan`/`htmlNoteListItem`.
@Sendable
public func emitHTML(_ doc: Document, mode: EmitMode = .modern,
                     options: EmitOptions = EmitOptions()) -> String {
    let title = options.title
    let printed = mode == .printed || isPrinted(doc)
    let refNotes = inlineReferenceNotes(doc)
    var parts: [String] = []

    for block in doc.blocks {
        if block.kind == .softpage {
            // WordStar's own pagination: a visible rule only when we're reproducing pages.
            if printed { parts.append(pageRule) }
            continue
        }
        if block.kind == .pagebreak {
            parts.append(pageRule)
            continue
        }
        // emit.py:167-172 — a heading is a heading in both modes; note this check sits
        // AFTER the two break kinds and BEFORE the printed/modern split, so a heading never
        // renders as `<pre>`.
        if block.heading != 0 {
            let text = block.lines
                .map { line in line.spans.map { htmlBodySpan($0, refNotes: refNotes, doc: doc, options: options) }.joined() }
                .joined(separator: " ")             // heading lines read as one phrase
                .trimmed()
            if !text.isEmpty {
                parts.append("<h\(block.heading)>\(text)</h\(block.heading)>")
            }
            continue
        }
        if printed {
            let body = block.lines
                .map { line in line.spans.map { htmlBodySpan($0, keepWS: true, refNotes: refNotes, doc: doc, options: options) }.joined() }
                .joined(separator: "\n")
            if !body.trimmed().isEmpty {
                parts.append("<pre>\(body)</pre>")
            }
        } else {
            let lines = block.lines.map { line in line.spans.map { htmlBodySpan($0, refNotes: refNotes, doc: doc, options: options) }.joined() }
            // emit.py:180 — the author's own line breaks inside a paragraph, kept as <br>.
            let para = lines.joined(separator: "<br>\n")
            if !para.trimmed().isEmpty {
                parts.append("<p>\(para)</p>")
            }
        }
    }

    // One `doc-endnotes` section per included, non-empty kind, `noteKindOrder`'s order —
    // a plain `<hr>` first, only if at least one such section exists.
    let sections: [String] = noteKindOrder.compactMap { kind in
        guard options.notes.contains(kind) else { return nil }
        let entries = noteListEntries(doc, kind: kind)
        guard !entries.isEmpty else { return nil }
        let labelID = "\(kind.rawValue)s-label"
        let items = entries.map(htmlNoteListItem).joined()
        return "<section role=\"doc-endnotes\" aria-labelledby=\"\(labelID)\">"
            + "<h2 id=\"\(labelID)\">\(noteSectionTitle(kind))</h2><ol>\(items)</ol></section>"
    }
    if !sections.isEmpty {
        parts.append("<hr>")
        parts.append(contentsOf: sections)
    }

    // Built in steps rather than one `+` chain: long string concatenations are the other
    // half of the type-checker trap the byte-array literals hit in earlier jobs.
    var page = "<!doctype html><html><head><meta charset=\"utf-8\">"
    page += "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    page += "<title>\(htmlEscape(title))</title><style>\(htmlCSS)</style></head>\n"
    page += "<body>\n"
    page += parts.joined(separator: "\n")
    page += "\n</body></html>\n"
    return page
}

/// The page-break rule, shared by the `softpage` and `pagebreak` branches (emit.py:162, 165).
private let pageRule = "<hr class=\"pb\">"
