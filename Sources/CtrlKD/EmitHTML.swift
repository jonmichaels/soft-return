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

/// Render a whole standalone page: doctype, head, the CSS above, then one element per
/// block. emit.py:156-190.
///
/// - Parameter title: goes in `<title>`, escaped. Python defaults it to `''`, which yields
///   an empty `<title></title>` rather than omitting the tag — kept, because the vectors
///   pin it.
public func emitHTML(_ doc: Document, mode: EmitMode = .modern, title: String = "") -> String {
    let printed = mode == .printed || isPrinted(doc)
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
                .map { line in line.spans.map { htmlSpan($0) }.joined() }
                .joined(separator: " ")             // heading lines read as one phrase
                .trimmed()
            if !text.isEmpty {
                parts.append("<h\(block.heading)>\(text)</h\(block.heading)>")
            }
            continue
        }
        if printed {
            let body = block.lines
                .map { line in line.spans.map { htmlSpan($0, keepWS: true) }.joined() }
                .joined(separator: "\n")
            if !body.trimmed().isEmpty {
                parts.append("<pre>\(body)</pre>")
            }
        } else {
            let lines = block.lines.map { line in line.spans.map { htmlSpan($0) }.joined() }
            // emit.py:180 — the author's own line breaks inside a paragraph, kept as <br>.
            let para = lines.joined(separator: "<br>\n")
            if !para.trimmed().isEmpty {
                parts.append("<p>\(para)</p>")
            }
        }
    }

    if !doc.footnotes.isEmpty {
        // Plain text only — a footnote's spans keep their styles in the IR, but Python
        // escapes and drops them here (emit.py:184-185).
        let notes = doc.footnotes
            .map { note in "<li>" + note.map { htmlEscape($0.text) }.joined() + "</li>" }
            .joined()
        parts.append("<hr><ol class=\"footnotes\">\(notes)</ol>")
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
