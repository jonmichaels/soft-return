/// HTML emitter. Direct port of `_html_span` (emit.py:143-154) and `emit_html`
/// (emit.py:156-190), with the `_CSS` blob (emit.py:134-139) and `_TAG` table
/// (emit.py:141).

/// emit.py:134-139, verbatim. This is data, not a style opinion — the vectors compare the
/// generated page byte for byte, embedded newlines included, so reflowing or "tidying" this
/// string breaks equivalence with Python. Change it there first if it ever needs changing.
private let htmlCSS = """
body{max-width:42rem;margin:2rem auto;padding:0 1rem;
font:14pt/1.6 Georgia,'Times New Roman',P052,serif;color:#222}p{margin:0 0 1em}
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
    // The font run wraps OUTSIDE the style tags: Python appends this after the `_TAG`
    // loop, and each wrap encloses everything built so far. Class only — the matching
    // `.ws-font-N` rule comes from `styleCSS`, so `--no-styles` leaves the class inert.
    if let font = span.font {
        text = "<span class=\"ws-font-\(font)\">" + text + "</span>"
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
/// `shown` overrides the visible text only (the `prefixed` scheme, ruling 2026-08-06 M8);
/// the ids stay kind-prefixed and stable either way.
private func htmlReferenceAnchor(_ note: Note, label: String, shown: String? = nil) -> String {
    let ids = htmlIDs(note.kind, label: label)
    let escaped = htmlEscape(shown ?? label)
    return "<sup><a id=\"\(ids.ref)\" href=\"#\(ids.target)\" role=\"doc-noteref\">\(escaped)</a></sup>"
}

/// One span, HTML: an ordinary span goes through `htmlSpan` unchanged; a valid, included
/// `fnref` becomes the anchor above; an excluded kind's reference vanishes entirely; an
/// invalid one (task item 3 — a stray `0x07` with no note behind it) falls back to
/// `htmlSpan`'s ordinary styling, which already renders it as bare digits inside whatever
/// `sup` it carries (see `htmlSpanFnrefContributesNoTag`).
private func htmlBodySpan(
    _ span: Span, keepWS: Bool = false, refNotes: [Note], doc: Document, options: EmitOptions,
    shownMap: [Int: String]? = nil
) -> String {
    guard span.styles.contains(.fnref) else { return htmlSpan(span, keepWS: keepWS) }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label, let index):
        if note.kind == .comment, shownMap == nil {
            // word scheme: comments are markless (a bubble in Word, a section entry
            // here) — an empty visible anchor would be noise, so none is emitted (M9)
            return ""
        }
        return htmlReferenceAnchor(note, label: label, shown: shownMap?[index])
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
private func htmlNoteListItem(_ entry: NoteListEntry, linkComments: Bool = false) -> String {
    let kind = entry.note.kind
    let ids = htmlIDs(kind, label: entry.label)
    var li = "<li id=\"\(ids.target)\" data-note-kind=\"\(kind.rawValue)\""
    if let tag = entry.note.tag, !tag.isEmpty {
        li += " data-note-tag=\"\(htmlEscape(tag))\""
    }
    li += ">" + htmlEscape(entry.note.text)
    // Comments backlink only under `prefixed`, which is when a visible inline anchor
    // exists to link back to (word scheme is markless — M9).
    if kind != .comment || linkComments {
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
/// `text-align` for a block, or "" for WordStar's default.
/// Two-decimal formatting without Foundation, matching Python's `'%.2f'`.
func fixedTwoDecimals(_ v: Double) -> String {
    // `Int(_:)` truncates, so +0.5 rounds half away from zero. `.rounded()` would
    // pull in libm, and this module deliberately imports nothing.
    let scaled = v >= 0 ? Int(v * 100 + 0.5) : -Int(-v * 100 + 0.5)
    let whole = scaled / 100
    let frac = abs(scaled % 100)
    return "\(whole)." + (frac < 10 ? "0\(frac)" : "\(frac)")
}

func htmlAlignAttribute(_ align: Alignment) -> String {
    switch align {
    case .left: return ""
    case .center: return #" style="text-align:center""#
    case .right: return #" style="text-align:right""#
    case .justify: return #" style="text-align:justify""#
    }
}

public func emitHTML(_ doc: Document, mode: EmitMode = .modern,
                     options: EmitOptions = EmitOptions()) -> String {
    let title = options.title
    let printed = mode == .printed || isPrinted(doc)
    var options = options
    if printed {
        // printed is always silent about comments (ruling 2026-08-06 M9)
        options.notes.remove(.comment)
    }
    let refNotes = inlineReferenceNotes(doc)
    // `prefixed` reference labels (ruling 2026-08-06 M8) change the visible mark text
    // only; ids and sections are structural and stay put.
    let shownMap: [Int: String]? = (options.noteRefs == .prefixed && !printed)
        ? noteRefLabels(refNotes, doc: doc, scheme: .prefixed) : nil
    var parts: [String] = []
    var styleClass: [Int: String] = [:]
    if options.styles {
        for entry in doc.styles {
            styleClass[entry.slot] = " class=\"\(styleSlug(entry))\""
        }
    }

    for block in doc.blocks {
        if block.kind == .pagebreak {
            parts.append(pageRule)
            continue
        }
        let cls = block.styleID.flatMap { styleClass[$0] } ?? ""
        // emit.py:167-172 — a heading is a heading in both modes; note this check sits
        // AFTER the two break kinds and BEFORE the printed/modern split, so a heading never
        // renders as `<pre>`.
        if block.heading != 0 {
            // Merged in BOTH modes: a heading is a logical unit, and joining its logical
            // lines with a space is what this always rendered (ctrl-kd 2.0.0).
            let text = mergedLines(block)
                .map { line in line.spans.map { htmlBodySpan($0, refNotes: refNotes, doc: doc, options: options, shownMap: shownMap) }.joined() }
                .joined(separator: " ")             // heading lines read as one phrase
                .trimmed()
            if !text.isEmpty {
                parts.append("<h\(block.heading)\(cls)>\(text)</h\(block.heading)>")
            }
            continue
        }
        if printed {
            // PHYSICAL lines: inside <pre>, a soft return is a real line break.
            let body = block.lines
                .map { line in line.spans.map { htmlBodySpan($0, keepWS: true, refNotes: refNotes, doc: doc, options: options, shownMap: shownMap) }.joined() }
                .joined(separator: "\n")
            if !body.trimmed().isEmpty {
                parts.append("<pre\(cls)>\(body)</pre>")
            }
        } else {
            // Logical lines: soft wraps joined back (`mergedLines`, ctrl-kd 2.0.0).
            let lines = mergedLines(block).map { line in line.spans.map { htmlBodySpan($0, refNotes: refNotes, doc: doc, options: options, shownMap: shownMap) }.joined() }
            // emit.py:180 — the author's own line breaks inside a paragraph, kept as <br>.
            let para = lines.joined(separator: "<br>\n")
            if !para.trimmed().isEmpty {
                // C16/C17: HTML expresses all four alignments, so unlike plain text it
                // does not collapse justify into left. `left` is WordStar's default and
                // gets no attribute, so a document that never touches `.oc`/`.oj` emits
                // byte-identical HTML to before.
                let pTag = "<p\(cls)\(htmlAlignAttribute(block.align))>\(para)</p>"
                // C5: newspaper columns. CSS does this properly, so HTML is the one
                // format that can honour `.co` rather than merely record it. A gutter
                // is print columns at 10 CPI -> tenths of an inch.
                if let n = block.columns, n > 1 {
                    let gap = block.columnGutter.map {
                        "; column-gap:\(fixedTwoDecimals($0 / 10.0))in"
                    } ?? ""
                    parts.append("<div style=\"column-count:\(n)\(gap)\">\(pTag)</div>")
                } else {
                    parts.append(pTag)
                }
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
        let items = entries.map { htmlNoteListItem($0, linkComments: shownMap != nil) }.joined()
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
    var css = htmlCSS
    if options.styles {
        let extra = styleCSS(doc)
        if !extra.isEmpty { css += "\n" + extra }
    }
    page += "<title>\(htmlEscape(title))</title><style>\(css)</style></head>\n"
    page += "<body>\n"
    page += parts.joined(separator: "\n")
    page += "\n</body></html>\n"
    return page
}

/// The page-break rule, for the `pagebreak` branch (emit.py:165).
private let pageRule = "<hr class=\"pb\">"


// MARK: - Paragraph style pass-through (C1)

/// A stable, readable CSS class for one library entry: slot + slugged name (the slot
/// disambiguates same-named entries, and the archive is full of them — two `WordStar
/// Defaults` in the same library is the normal case).
func styleSlug(_ entry: StyleEntry) -> String {
    // Python's `re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-') or 'style'`: lower
    // FIRST, so an upper-case letter is a letter, not a separator.
    var out = ""
    var pendingDash = false
    for scalar in entry.name.unicodeScalars {
        let v = scalar.value >= 0x41 && scalar.value <= 0x5A ? scalar.value + 0x20 : scalar.value
        if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
            if pendingDash, !out.isEmpty { out.append("-") }
            pendingDash = false
            out.unicodeScalars.append(Unicode.Scalar(v)!)
        } else {
            pendingDash = true
        }
    }
    return "ws-\(entry.slot)-" + (out.isEmpty ? "style" : out)
}

/// CSS rules derived from the style records themselves — a PASS-THROUGH of the file's own
/// data (Jon, 2026-08-04: never hardwire a style name to a font or a size; expose the data
/// so a consumer can attach its own). Every property below comes from the entry's 102-byte
/// record: alignment, margins (HMI/1800 = inches), print attributes, and the font block's
/// height word (VMI/20 = points). Inherited fields emit nothing.
func styleCSS(_ doc: Document) -> String {
    var rules: [String] = []
    for entry in doc.styles {
        guard let record = entry.record else { continue }   // recordless base entry
        var props: [String] = []
        if let align = record.justification {
            props.append("text-align:\(align.rawValue)")
        }
        // A ZERO margin is not a margin worth emitting — Python tests the value's own
        // truthiness, not merely its presence.
        if let lm = record.leftMarginHMI, lm != 0 {
            props.append("margin-left:\(fixedTwoDecimals(Double(lm) / 1800.0))in")
        }
        if let rm = record.rightMarginHMI, rm != 0 {
            props.append("margin-right:\(fixedTwoDecimals(Double(rm) / 1800.0))in")
        }
        let attrs = record.attrs
        if attrs.contains(.bold) { props.append("font-weight:bold") }
        if attrs.contains(.italic) { props.append("font-style:italic") }
        var deco: [String] = []
        if attrs.contains(.underline) { deco.append("underline") }
        if attrs.contains(.strike) { deco.append("line-through") }
        if !deco.isEmpty { props.append("text-decoration:" + deco.joined(separator: " ")) }
        if let font = record.font {
            if font.height != 0 {
                props.append("font-size:\(fourSignificantDigits(Double(font.height) / 20.0))pt")
            }
            props.append("--ws-typestyle:\(font.typestyle & 0x01FF)")
        }
        if !props.isEmpty {
            rules.append(".\(styleSlug(entry)) { " + props.joined(separator: "; ") + " }")
        }
    }
    // One rule per FONT RUN, from the font block's own words: the family up to the
    // spec's parenthetical and the height word as points. A run with neither a named
    // family nor a size gets no rule, and its class stays inert.
    for (index, font) in doc.fonts.enumerated() {
        var props: [String] = []
        let family = font.family
        if !family.isEmpty {
            // The whole stack: the era name first (pass-through), then the modern
            // alternates, then the generic from the block's own style bits — CSS
            // fallback is real fallback, so the original never loses its chance.
            let stack = fontStack(family, generic: font.genericStyle)
            let css = stack.map { name in
                // Python's `n if ' ' not in n and n.islower() else f"'{n}'"`: the bare
                // CSS generics go unquoted, every family name is quoted.
                !name.contains(" ") && name.isLowercaseCased ? name : "'\(name)'"
            }
            props.append("font-family:" + css.joined(separator: ", "))
        }
        // Python tests the float's own truthiness: a zero height is not a size.
        if font.points != 0 {
            props.append("font-size:\(fourSignificantDigits(font.points))pt")
        }
        if !props.isEmpty {
            rules.append(".ws-font-\(index) { " + props.joined(separator: "; ") + " }")
        }
    }
    return rules.joined(separator: "\n")
}

/// Python's `'%.4g'`, for the one place that needs it (a style record's type size).
///
/// No exponent form is reachable here and none is implemented: the value is always
/// `height / 20` for a 16-bit VMI word, i.e. 0.05 … 3276.75, whose decimal exponent stays
/// inside `%g`'s fixed-notation window (-4 <= exp < 4). Rounds half-to-even like Python's
/// own formatter, then drops trailing zeros and a bare trailing point.
func fourSignificantDigits(_ value: Double) -> String {
    guard value != 0 else { return "0" }
    let negative = value < 0
    let magnitude = negative ? -value : value
    var decimals = 3
    var bound = 10.0
    while decimals > 0 && magnitude >= bound {
        decimals -= 1
        bound *= 10
    }
    var scale = 1
    for _ in 0..<decimals { scale *= 10 }
    let scaled = roundHalfToEven(magnitude * Double(scale))
    var whole = String(scaled / scale)
    if decimals > 0 {
        var frac = String(scaled % scale)
        while frac.count < decimals { frac = "0" + frac }
        while frac.hasSuffix("0") { frac.removeLast() }
        if !frac.isEmpty { whole += "." + frac }
    }
    return (negative ? "-" : "") + whole
}
