/// HTML emitter. Direct port of `_html_span` (emit.py:143-154) and `emit_html`
/// (emit.py:156-190), with the `_CSS` blob (emit.py:134-139) and `_TAG` table
/// (emit.py:141).

/// Verbatim `_CSS`. This is data, not a style opinion — the vectors compare the generated
/// page byte for byte, embedded newlines included, so reflowing or "tidying" this string
/// breaks equivalence with Python. Change it there first if it ever needs changing.
///
/// NO WIDTH/MEASURE DECLARATION ANYWHERE (round 3 addendum): an earlier version capped the
/// body at `max-width:42rem` as a reading-measure nicety — reasonable on its own, but still
/// OUR OWN page-width opinion, the same category of thing the rest of this round strips.
/// HTML has no page; width belongs entirely to the renderer/reader, in both Modern AND
/// Native output. `padding` is a fixed breathing-room gutter, not a measure.
private let htmlCSS = """
body{margin:0;padding:2rem 1rem;
font:14pt/1.6 Georgia,'Times New Roman',P052,serif;color:#222}p{margin:0 0 1em}
.ws-native{white-space:pre-wrap;font:14px/1.5 ui-monospace,Menlo,Consolas,monospace}
span.ws-graphic{font-family:ui-monospace,Menlo,Consolas,monospace}
hr.pb{border:none;border-top:1px dashed #bbb;margin:2rem 0}
blockquote{margin:1em 2em;padding-left:1em;border-left:2px solid #ccc}
blockquote p{margin:0}
section[role=doc-endnotes]{margin-top:2rem}
section[role=doc-endnotes] h2{font-size:1.1rem}
@media(prefers-color-scheme:dark){body{background:#161616;color:#ddd}
hr.pb{border-top-color:#444}blockquote{border-left-color:#555}}
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

/// Whether `text` is entirely cp437 box-drawing/shade/block/card-suit content (spaces
/// allowed, e.g. a box's own top-border run of `─`) — the HTML/RTF-side twin of PDF's own
/// graphics doctrine ("the reason the box shows up is that it could be done in that era"),
/// used to force a monospace face on exactly the pieces `splitGraphicSpans` isolated,
/// never on prose sharing their line. Reuses PDF's own `graphicChars` set (single source
/// of truth in this module — ctrl-kd's Python keeps two independent copies for its own
/// file-organization reasons, which don't apply here). Port of `emit._is_graphic_text`.
func isGraphicText(_ text: String) -> Bool {
    let stripped = text.replacingAll(" ", with: "")
    guard !stripped.isEmpty else { return false }
    return stripped.allSatisfy { graphicChars.contains($0) }
}

/// One span -> escaped, tagged HTML. emit.py:143-154.
///
/// `keepWS: true` is the `<pre>` path, where the source's own spacing is already
/// significant and the browser will honour it. Everywhere else a run of five or more
/// leading spaces is a deliberate indent (a poem, a typescript block quote) that HTML
/// would otherwise collapse to nothing, so it is re-inflated to `&nbsp;`.
func htmlSpan(_ span: Span, keepWS: Bool = false, inlineStyling: Bool = true) -> String {
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
    // loop, and each wrap encloses everything built so far. Class(es) only — the matching
    // CSS rules come from `styleCSS`/the static sheet, so `--no-styles` leaves them inert.
    var classes: [String] = []
    if let font = span.font {
        classes.append("ws-font-\(font)")
    }
    // b24 round 18 (RULINGS-LEDGER row 10): inline colour -- `.ws-colour-N` matches
    // `styleCSS`'s own generated rule (N is the raw palette index, not an array index).
    // `--inline-styling off` never applies the class -- no rule exists for it either
    // (`styleCSS` skips the whole loop), so this stays inert either way, but skipping
    // here too keeps `--no-styles`'s own "classes only, CSS decides" contract honest.
    if inlineStyling, let colour = span.colour {
        classes.append("ws-colour-\(colour)")
    }
    // `span.ws-graphic` (element+class) outranks the plain-class `.ws-font-N` rule
    // regardless of stylesheet order, so a box-drawing run stays monospace even under a
    // document font the generated `.ws-font-N` rule made proportional. Port of the
    // round-8 (SCRIPT.WS) fix to `_html_span`.
    if isGraphicText(span.text) {
        classes.append("ws-graphic")
    }
    if !classes.isEmpty {
        text = "<span class=\"\(classes.joined(separator: " "))\">" + text + "</span>"
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

/// One `<img>` for a resolved, decoded `PixResult` -- a data URI in embed mode, a
/// relative link (from `imageLinks`, built by the caller via `writeExportImages`) in
/// export mode. Explicit width/height only when the print-options record gave a real
/// physical size (round 19); otherwise the browser's own native-pixel default applies,
/// same fallback doctrine as RTF's 96dpi goal size. Port of `_html_img`.
private func htmlImg(_ result: PixResult, pictures: EmitOptions.PixMode,
                     imageLinks: [Int: String]) -> String {
    let alt = htmlEscape(pixBasename(result.rawPath))
    let style: String
    if let w = result.widthIn, let h = result.heightIn {
        style = " style=\"width:\(fixedThreeDecimals(w))in;height:\(fixedThreeDecimals(h))in\""
    } else {
        style = ""
    }
    let src: String
    if pictures == .export, let link = imageLinks[result.index] {
        src = htmlEscape(link)
    } else {
        src = "data:image/png;base64," + base64Encode(result.png ?? [])
    }
    return "<img src=\"\(src)\" alt=\"\(alt)\"\(style)>"
}

/// Python's `'%.3f'`, for `htmlImg`'s inline width/height style.
private func fixedThreeDecimals(_ v: Double) -> String {
    let scaled = v >= 0 ? Int(v * 1000 + 0.5) : -Int(-v * 1000 + 0.5)
    let whole = scaled / 1000
    var frac = String(abs(scaled % 1000))
    while frac.count < 3 { frac = "0" + frac }
    return "\(whole).\(frac)"
}

/// One span, HTML: an ordinary span goes through `htmlSpan` unchanged; a valid, included
/// `fnref` becomes the anchor above; an excluded kind's reference vanishes entirely; an
/// invalid one (task item 3 — a stray `0x07` with no note behind it) falls back to
/// `htmlSpan`'s ordinary styling, which already renders it as bare digits inside whatever
/// `sup` it carries (see `htmlSpanFnrefContributesNoTag`).
private func htmlBodySpan(
    _ span: Span, keepWS: Bool = false, refNotes: [Note], labels: [String], options: EmitOptions,
    shownMap: [Int: String]? = nil
) -> String {
    if let hmi = span.pctlHMI {
        // screen-only print-control display string: the printed physical layer
        // (`keepWS`) pads the declared width; every reading mode shows nothing (M10)
        guard keepWS else { return "" }
        return String(repeating: " ", count: max(0, roundHalfToEven(Double(hmi) / 180.0)))
    }
    // b24 round 19 (RULINGS-LEDGER PIX row, "PIX images RULED IN"): same doctrine as
    // RTF's own pix-tag branch -- off, or a miss, falls straight through to the
    // unchanged placeholder <span> below via the normal htmlSpan() call.
    if let pixIndex = span.pix, options.pictures != .off,
       let result = options.pixResults.first(where: { $0.index == pixIndex }), result.ok {
        return htmlImg(result, pictures: options.pictures, imageLinks: options.imageLinks)
    }
    guard span.styles.contains(.fnref) else {
        return htmlSpan(span, keepWS: keepWS, inlineStyling: options.inlineStyling)
    }
    switch resolveReference(span, refNotes: refNotes, labels: labels, options: options) {
    case .note(let note, let label, let index):
        if note.kind == .comment, shownMap == nil {
            // word scheme: comments are markless (a bubble in Word, a section entry
            // here) — an empty visible anchor would be noise, so none is emitted (M9)
            return ""
        }
        return htmlReferenceAnchor(note, label: label, shown: shownMap?[index])
    case .excluded: return ""
    case .invalid: return htmlSpan(span, keepWS: keepWS, inlineStyling: options.inlineStyling)
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
private func htmlNoteListItem(_ entry: NoteListEntry, linkComments: Bool = false,
                              sentenceSpacing: Bool = false) -> String {
    let kind = entry.note.kind
    let ids = htmlIDs(kind, label: entry.label)
    var li = "<li id=\"\(ids.target)\" data-note-kind=\"\(kind.rawValue)\""
    if let tag = entry.note.tag, !tag.isEmpty {
        li += " data-note-tag=\"\(htmlEscape(tag))\""
    }
    let noteText = sentenceSpacing ? sentenceSpacingTexts([entry.note.text])[0] : entry.note.text
    li += ">" + htmlEscape(noteText)
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

private let htmlAlignCSS: [Alignment: String] = [
    .center: "text-align:center", .right: "text-align:right", .justify: "text-align:justify",
]

/// One combined `style="..."` attribute for a Modern `<p>` — alignment, first-line
/// indent, and (b24 round 20, slate item 4) verse/centered tight line-height all live
/// there, so a centred, indented, tight paragraph doesn't need three competing style
/// attributes (HTML allows only one). `tight` — a verse-classified unit or any centered
/// paragraph (which may itself wrap in the reader, "wrapped centered units") — sets
/// line-height to `verseLineHeight` instead of the document default. Port of
/// `emit._html_para_style`.
func htmlParaStyle(_ align: Alignment, indentCols: Int = 0, tight: Bool = false) -> String {
    var props: [String] = []
    if let css = htmlAlignCSS[align] { props.append(css) }
    if indentCols != 0 { props.append("text-indent:\(indentCols)ch") }
    if tight { props.append("line-height:\(verseLineHeight)") }
    return props.isEmpty ? "" : " style=\"\(props.joined(separator: ";"))\""
}

/// Merge an extra CSS class into an already-built `' class="..."'` attribute string (or
/// start a fresh one if `clsAttr` is empty) — Native HTML's own per-style class (may be
/// absent) plus the `ws-native` monospace/pre-wrap treatment both need to land on the same
/// element now that Native no longer wraps in a bare `<pre>`. Port of `emit._add_html_class`.
func addHTMLClass(_ clsAttr: String, _ extra: String) -> String {
    guard !clsAttr.isEmpty else { return " class=\"\(extra)\"" }
    return String(clsAttr.dropLast()) + " \(extra)\""
}

// -------------------------------------------------------- structure rules (HTML)

/// `spans` cut to the character range `[start, end)` (`end == nil`: to the end) --
/// `modernSemanticFlow`'s own `.lm`-drop generalised to an arbitrary offset, so a
/// marker/label/padding strip can happen on the STYLED spans (bold, italics, fonts)
/// instead of the plain text `classifyRows` worked from, and stay stylistically correct
/// on the way to HTML. Port of `emit._slice_spans`.
func sliceSpans(_ spans: [Span], start: Int, end: Int? = nil) -> [Span] {
    let total = spans.reduce(0) { $0 + $1.text.count }
    let end = end ?? total
    var out: [Span] = []
    var pos = 0
    for sp in spans {
        let chars = Array(sp.text)
        let spStart = pos, spEnd = pos + chars.count
        pos = spEnd
        let lo = max(start, spStart), hi = min(end, spEnd)
        if lo < hi {
            out.append(Span(text: String(chars[(lo - spStart)..<(hi - spStart)]), styles: sp.styles,
                            font: sp.font, colour: sp.colour, pctlHMI: sp.pctlHMI, pix: sp.pix))
        }
    }
    return out
}

/// One row's spans -> escaped, tagged HTML, joined. Coalesces adjacent identically-styled
/// spans unconditionally: cheap, idempotent for a caller that already coalesced (Modern's
/// `mergedLines`), and the ONE place Printed's own physical-line spans get the same fix
/// (item e of the overhaul — the fragmentation gap applies there too). Port of
/// `emit._html_line`.
private func htmlLine(_ spans: [Span], keepWS: Bool = false, refNotes: [Note], labels: [String],
                      options: EmitOptions, shownMap: [Int: String]?,
                      sentenceSpacing: Bool = false) -> String {
    // N9 (b33 field notes): the sentence-spacing collapse runs FIRST, on the raw
    // incoming spans -- before this is the SINGLE choke point every HTML render path
    // (Printed physical lines, Modern paragraph units, `htmlSlice`'s structure-row
    // slices alike) funnels through, so one application here covers all of them.
    let spans = sentenceSpacing ? sentenceSpacingSpans(spans) : spans
    // Graphic runs split out AFTER coalescing, not before (round 8): coalescing merges
    // by style equality alone, so a split-then-coalesce order would silently re-glue a
    // box character back onto the prose beside it the moment they share a style.
    return splitGraphicSpans(coalesceSpans(spans)).map {
        htmlBodySpan($0, keepWS: keepWS, refNotes: refNotes, labels: labels, options: options,
                    shownMap: shownMap)
    }.joined()
}

private func htmlSlice(_ spans: [Span], start: Int, end: Int?, refNotes: [Note], labels: [String],
                       options: EmitOptions, shownMap: [Int: String]?,
                       sentenceSpacing: Bool = false) -> String {
    // N9 scope note: sentence-spacing state does not carry ACROSS a slice boundary
    // (each slice is its own `htmlLine` call) -- immaterial for every real
    // structure-row split (bullet/def-list markers, spaces padding) since those land
    // on the marker, never mid-sentence. Mirrors ctrl-kd's own observable quirk.
    htmlLine(sliceSpans(spans, start: start, end: end), refNotes: refNotes, labels: labels,
            options: options, shownMap: shownMap, sentenceSpacing: sentenceSpacing)
}

/// The centred line's own text with its alignment padding sliced off (both mechanisms: a
/// real align=center tag already had the M3 strip upstream, so lead/trail are 0 and this
/// is a no-op; spaces-only centering strips the padding here for the first time). Port of
/// `emit._html_centered_row`.
private func htmlCenteredRow(_ line: Line, refNotes: [Note], labels: [String], options: EmitOptions,
                             shownMap: [Int: String]?, sentenceSpacing: Bool = false) -> String {
    let raw = Array(line.spans.map(\.text).joined())
    var lead = 0
    while lead < raw.count, raw[lead] == " " { lead += 1 }
    var trail = 0
    while trail < raw.count, raw[raw.count - 1 - trail] == " " { trail += 1 }
    return htmlSlice(line.spans, start: lead, end: raw.count - trail, refNotes: refNotes, labels: labels,
                     options: options, shownMap: shownMap, sentenceSpacing: sentenceSpacing)
}

/// `{block_index: [(Line, structure)]}` for every ordinary (non-heading, non-pagebreak,
/// non-multi-column, non-quote, non-wrap=off) block, classified as ONE document-wide row
/// sequence -- bullet-marker discovery and nesting both need the whole order, not one
/// block seen in isolation. Mirrors `modernSemanticFlow`'s own row-building exactly, so
/// HTML sees the identical classification the `layout` JSON emitter would for the same
/// document. Port of `emit._classify_modern_blocks`.
///
/// ctrl-kd round 13 (the main-merge reconciliation) widened the exclusion list by two:
/// quote-classified blocks and wrap=off (`.aw off`) blocks are BOTH, structurally, the
/// same class of hazard the multi-column exclusion already existed for -- content whose
/// own margin/positioning is a deliberate, source-carried decision rather than evidence
/// of centering or a list. A quote's own typed-paragraph indent is documented elsewhere
/// as INCONSISTENT by source (round 4: "opens its first typed paragraph at column 7 and
/// every later one at column 12"), which the spaces-centering heuristic below can and did
/// mistake for deliberate symmetric padding on a short attribution line (a 3-paragraph
/// quote group lost its middle paragraph to a false centering match once both features
/// composed). A wrap=off block is BY DEFINITION hand-positioned, the exact opposite of
/// "reflow-eligible content classifyRows should reinterpret."
func classifyModernBlocks(_ doc: Document) -> [Int: [(line: Line, structure: RowStructure?)]] {
    var entries: [StructureEntry] = []
    var plan: [(blockIndex: Int, line: Line)?] = []
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak || block.heading != 0 || (block.columns ?? 0) > 1
            || isQuoteStyle(block) || !block.wrap {
            entries.append(.hard)
            plan.append(nil)
            continue
        }
        let lm = pyIndentCols(block)
        let cut = pyCutCols(block)
        for line in mergedLines(block) {
            let text = line.spans.map(\.text).joined()
            entries.append(.para(indentCols: lm, cutCols: cut, align: block.align, text: text))
            plan.append((bi, line))
        }
    }
    var byBlock: [Int: [(line: Line, structure: RowStructure?)]] = [:]
    for (row, s) in zip(plan, classifyRows(entries)) {
        guard let row else { continue }
        byBlock[row.blockIndex, default: []].append((row.line, s))
    }
    return byBlock
}

/// One node of the `_HtmlListBuilder` tree: either a plain html fragment (a bullet
/// item's own content, or a top-level paragraph), a def-list item's own `dt`/`dd` pair,
/// or a nested list.
private enum HTMLListNode {
    case text(String)
    case defHead(dt: String, dd: String)
    case list(HTMLListBuilderNode)
}

/// A reference-typed container of nodes -- one list's growing item, or the whole tree's
/// root -- mutated in place the way Python's shared list objects are, since `_open`
/// keeps live references into the SAME tree it's building.
private final class HTMLNodeContainer {
    var nodes: [HTMLListNode] = []
}

private final class HTMLListBuilderNode {
    var kind: RowStructureKind
    var cls: String
    var items: [HTMLNodeContainer] = []
    init(kind: RowStructureKind, cls: String) {
        self.kind = kind
        self.cls = cls
    }
}

/// Turns a stream of classified Modern rows (`classifyRows`, the same classification the
/// `layout` JSON emitter exposes) into nested `<ul>`/`<dl>` markup -- HTML and
/// `layout.json` agree on where a list starts, ends, and nests, because they share the
/// one classifier. A row with no structure (`kind == nil`) closes any open list back to
/// the document flow and renders as an ordinary `<p>`, same as before this rule set
/// existed. Port of `emit._HtmlListBuilder`.
private final class HTMLListBuilder {
    private let root = HTMLNodeContainer()
    private struct Frame {
        var level: Int
        var kind: RowStructureKind?
        var list: HTMLListBuilderNode?
        var currentItem: HTMLNodeContainer
    }
    private var stack: [Frame]

    init() {
        stack = [Frame(level: 0, kind: nil, list: nil, currentItem: root)]
    }

    func addText(_ html: String) {
        guard !html.trimmed().isEmpty else { return }
        stack = [stack[0]]
        root.nodes.append(.text(html))
    }

    func addBullet(level: Int, cls: String, html: String) {
        let item = open(level: level, kind: .bullet, cls: cls)
        item.nodes.append(.text(html))
    }

    func addDef(level: Int, cls: String, dt: String, dd: String) {
        let item = open(level: level, kind: .def, cls: cls)
        item.nodes.append(.defHead(dt: dt, dd: dd))
    }

    private func open(level: Int, kind: RowStructureKind, cls: String) -> HTMLNodeContainer {
        while stack.count > 1 {
            let top = stack[stack.count - 1]
            if top.level < level || (top.level == level && top.kind == kind) { break }
            stack.removeLast()
        }
        var top = stack[stack.count - 1]
        if top.level == level, top.kind == kind, let list = top.list {
            let newItem = HTMLNodeContainer()
            list.items.append(newItem)
            top.currentItem = newItem
            stack[stack.count - 1] = top
            return newItem
        }
        let newList = HTMLListBuilderNode(kind: kind, cls: cls)
        let newItem = HTMLNodeContainer()
        newList.items.append(newItem)
        top.currentItem.nodes.append(.list(newList))
        stack.append(Frame(level: level, kind: kind, list: newList, currentItem: newItem))
        return newItem
    }

    func flush(_ parts: inout [String]) {
        parts.append(contentsOf: renderListNodes(root.nodes))
        root.nodes = []
        stack = [Frame(level: 0, kind: nil, list: nil, currentItem: root)]
    }
}

/// Port of `emit._render_list_nodes`.
private func renderListNodes(_ nodes: [HTMLListNode]) -> [String] {
    var out: [String] = []
    for node in nodes {
        switch node {
        case .text(let html):
            out.append(html)
        case .defHead:
            break   // only ever an item's own head node (consumed directly below), never reached here
        case .list(let list):
            var entries: [String] = []
            if list.kind == .def {
                for item in list.items {
                    guard case .defHead(let dt, let dd) = item.nodes.first else { continue }
                    let tail = Array(item.nodes.dropFirst())
                    entries.append("<dt\(list.cls)>\(dt)</dt><dd\(list.cls)>\(dd)"
                        + renderListNodes(tail).joined() + "</dd>")
                }
                out.append("<dl>" + entries.joined() + "</dl>")
            } else {
                for item in list.items {
                    guard case .text(let head) = item.nodes.first else { continue }
                    let tail = Array(item.nodes.dropFirst())
                    entries.append("<li\(list.cls)>\(head)"
                        + renderListNodes(tail).joined() + "</li>")
                }
                out.append("<ul>" + entries.joined() + "</ul>")
            }
        }
    }
    return out
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
    // N9 (b33 field notes): mode-aware default, flag overrides either way.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: printed)
    let refNotes = inlineReferenceNotes(doc)
    // HTML has no real pagination in EITHER mode -- a pagebreak is only ever a
    // decorative `<hr class="pb">`, never a page boundary that keeps two same-numbered
    // notes apart (unlike Printed/Modern PDF's real pages). So HTML takes the same
    // collision-triggered continuous renumbering as Modern TXT/MD, in printed mode too
    // (ruling 2026-08-24: "HTML needs it as well" -- measured and ruled without a mode
    // qualifier).
    let labels = pagelessNoteLabels(doc)
    // `prefixed` reference labels (ruling 2026-08-06 M8) change the visible mark text
    // only; ids and sections are structural and stay put.
    let shownMap: [Int: String]? = (options.noteRefs == .prefixed && !printed)
        ? noteRefLabels(refNotes, labels: labels, scheme: .prefixed) : nil
    var parts: [String] = []
    var styleClass: [Int: String] = [:]
    if options.styles {
        for entry in doc.styles {
            styleClass[entry.slot] = " class=\"\(styleSlug(entry))\""
        }
    }
    // Structure rules (M-rules addendum, 2026-08-13) only apply to the reflowed Modern
    // view -- printed is a physical facsimile, its Native rendering stays exactly the
    // plain-text-of-the-page it always was.
    //
    // NOTE on composing with the b23 exports overhaul: ctrl-kd main (e9f6c42, this job's
    // oracle) never merged the structure-rules feature (`classify_rows`/`_HtmlListBuilder`
    // lived only on ctrl-kd's own unmerged `modern-structure-rules` branch) -- so the real
    // oracle has NO bullet/def-list/centered-line HTML transform at all, and there is no
    // upstream guidance for how the two features should compose. Rather than regress this
    // repo's own shipped, previously parity-proven feature, structure classification still
    // runs FIRST exactly as before (job284); only the PLAIN (unclassified) line runs left
    // over now reflow through `assembleParagraphUnits` instead of a flat `<br>`-joined
    // buffer. A document whose structure classification actually fires (VERSIONS.WS's
    // def-list is the known real example) will diverge from the oracle's html.* cells on
    // that basis alone -- a pre-existing gap this job did not introduce and cannot close
    // without either dropping shipped behavior or the oracle regenerating from a ctrl-kd
    // main that has it.
    let blockRows: [Int: [(line: Line, structure: RowStructure?)]] =
        printed ? [:] : classifyModernBlocks(doc)
    let builder = HTMLListBuilder()
    let margin = docMargin(doc)
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    // b24 round 20b (slate item 13): screenplay-detected regions get verse-class
    // (line/indent-preserving) treatment -- see emitText's identical comment for the
    // doctrine. Not printed: a facsimile already preserves every line's own position.
    let screenplayBlocks = printed ? [] : detectScreenplayBlocks(doc)

    // Quote-block CONTINUITY (round 4): consecutive units in the same quote-classified
    // style are ONE quote block, not one <blockquote> per paragraph unit nor per WordStar
    // Block. `quoteBuffer` accumulates <p> strings across units AND across Blocks as long
    // as SOME quote style keeps matching and nothing else intervenes; `flushQuote` closes
    // it into one <blockquote> the moment it doesn't. `quoteIndentCols` is the GROUP's own
    // first-line indent, computed once from the group's first paragraph and reused for
    // every paragraph in it (the source's own typed indent is not reliable per paragraph).
    var quoteBuffer: [String] = []
    var quoteIndentCols: Int?

    func flushQuote() {
        if !quoteBuffer.isEmpty {
            parts.append("<blockquote>" + quoteBuffer.joined() + "</blockquote>")
            quoteBuffer.removeAll()
        }
        quoteIndentCols = nil
    }

    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak {
            if !printed { builder.flush(&parts) }
            flushQuote()
            parts.append(pageRule)
            continue
        }
        let cls = block.styleID.flatMap { styleClass[$0] } ?? ""
        // emit.py:167-172 — a heading is a heading in both modes; note this check sits
        // AFTER the two break kinds and BEFORE the printed/modern split, so a heading never
        // renders as Native.
        if block.heading != 0 {
            if !printed { builder.flush(&parts) }
            flushQuote()
            // Merged in BOTH modes: a heading is a logical unit, and joining its logical
            // lines with a space is what this always rendered (ctrl-kd 2.0.0).
            // Alignment-space stripping (defect b, round 3): a centred heading used to
            // keep its baked centering spaces as visible &nbsp; runs ON TOP of the CSS
            // that already centres it.
            let text = mergedLines(block)
                .map { line in htmlLine(maybeStripAlign(block, line.spans), refNotes: refNotes,
                                        labels: labels, options: options, shownMap: shownMap,
                                        sentenceSpacing: ssOn) }
                .joined(separator: " ")             // heading lines read as one phrase
                .trimmed()
            if !text.isEmpty {
                parts.append("<h\(block.heading)\(cls)>\(text)</h\(block.heading)>")
            }
            continue
        }
        if printed {
            flushQuote()
            // PHYSICAL lines, normal flow (round 3 addendum -- retires the earlier <pre>
            // wrapper): a <pre> box implies a width-constraining monospace grid, which is
            // exactly the page-geometry opinion this round strips everywhere else.
            // Native's own identity is the FONT (kept via the `ws-native` class:
            // monospace, `white-space:pre-wrap` so literal column spacing still lines up)
            // -- not a boxed, non-wrapping element. Every physical line break is now an
            // explicit <br> rather than a literal newline relying on <pre>'s own
            // whitespace handling.
            let lines = block.lines.map { line in
                htmlLine(line.spans, keepWS: true, refNotes: refNotes, labels: labels,
                        options: options, shownMap: shownMap, sentenceSpacing: ssOn)
            }
            let body = lines.joined(separator: "<br>\n")
            if !body.trimmed().isEmpty {
                let nativeCls = addHTMLClass(cls, "ws-native")
                parts.append("<p\(nativeCls)>\(body)</p>")
            }
        } else {
            // A plain (non-list, non-centred) run of lines now reflows the SAME way an
            // ordinary block's lines would (`assembleParagraphUnits`) instead of joining
            // with a flat <br> -- only a line that actually matches one of the three
            // structure rules ever breaks out of that into its own element, so an
            // ordinary multi-line block (an address, a signature) still renders as one
            // (now properly reflowed) paragraph.
            //
            // C5: newspaper columns (round 15 fix). A columnar block used to be its OWN
            // early branch here -- a flat mergedLines+<br> join with no paragraph
            // assembly at all, which lost the typed-indent-as-text-indent treatment
            // every other paragraph gets (found via the v7 corpus parity sweep:
            // PRINT.TST/PSPRINT.TST, both carrying `.co3` catalog tables whose own rows
            // are ordinary indented paragraphs, not verse). Python's `emit.py` never had
            // a separate branch: a columnar block's lines are "excluded from structure
            // classification... arrive here as ONE plain run, UNAFFECTED either way" —
            // the SAME flushPlain()/assembleParagraphUnits pipeline runs, and only the
            // already-fully-rendered `<p>` gets wrapped in the column `<div>` afterward.
            // `classifyModernBlocks` already excludes columns from row classification
            // (`(block.columns ?? 0) > 1` in its own guard), so this block's rows are
            // already the `blockRows[bi] ?? mergedLines(...)` all-plain fallback below —
            // nothing else here needs to change for a columnar block to reach this path.
            let quote = isQuoteStyle(block)
            if quote {
                // quote continues buffering across this block, same as a body paragraph.
            } else {
                flushQuote()
            }
            let dominant = blockDominantStyles(mergedLines(block))
            var plainRunLines: [Line] = []
            // The convention-outlier/positional epigraph route only makes sense when the
            // plain run IS the block's own opening lines -- a run that starts after a
            // structure-classified row (a bullet list's own trailing plain note, say)
            // has no "document's own opening line" to compare against.
            var plainRunIsBlockStart = true

            func flushPlain() {
                guard !plainRunLines.isEmpty else { return }
                let unitConventionIndent = plainRunIsBlockStart ? conventionIndent : nil
                let units = assembleParagraphUnits(plainRunLines, margin: margin,
                                                   headPosition: headPosition[bi] ?? false,
                                                   conventionIndent: unitConventionIndent,
                                                   wrap: block.wrap)
                for unit in units {
                    // round 7 (Register C23): a wrap=off block's unit is ALWAYS treated as
                    // verse here too -- assembleParagraphUnits already returns it as one
                    // whole-block unit unconditionally, but this is where a NON-verse
                    // multi-line unit gets flowed into one line; without the `!block.wrap`
                    // guard that flow logic would still run on a hand-positioned block's
                    // lines and destroy the layout via a different mechanism.
                    let isVerse = unit.count > 1 && (!block.wrap || looksLikeVerse(unit, dominantStyles: dominant)
                                                     || screenplayBlocks.contains(bi))
                    let firstStripped = maybeStripAlign(block, unit[0].spans)
                    var (indentCols, first) = splitLeadingIndent(firstStripped)
                    if quote {
                        // round 4: the quote GROUP's own first paragraph sets the indent
                        // for every paragraph in the group, not each one's own raw column
                        // count -- the source carries it inconsistently.
                        if quoteIndentCols == nil { quoteIndentCols = indentCols }
                        indentCols = quoteIndentCols!
                    }
                    var rendered = [htmlLine(first, refNotes: refNotes, labels: labels, options: options,
                                             shownMap: shownMap, sentenceSpacing: ssOn)]
                    for line in unit.dropFirst() {
                        var spans = maybeStripAlign(block, line.spans)
                        if !isVerse {
                            (_, spans) = splitLeadingIndent(spans)
                        }
                        rendered.append(htmlLine(spans, refNotes: refNotes, labels: labels,
                                                 options: options, shownMap: shownMap,
                                                 sentenceSpacing: ssOn))
                    }
                    let para: String
                    if unit.count > 1, !isVerse {
                        para = rendered.filter { !$0.trimmed().isEmpty }.joined(separator: " ")
                    } else {
                        para = rendered.joined(separator: "<br>\n")
                    }
                    guard !para.trimmed().isEmpty else { continue }
                    // b24 round 20 (slate item 4): a verse-classified unit, or any
                    // centered paragraph (which may itself wrap in the reader) --
                    // unchanged VERSE-TRIGGER logic, this round only adds the tight-
                    // spacing CONSEQUENCE.
                    let style = htmlParaStyle(block.align, indentCols: indentCols,
                                              tight: isVerse || block.align == .center)
                    var pHTML = "<p\(cls)\(style)>\(para)</p>"
                    // C5: newspaper columns. CSS does this properly, so HTML is the one
                    // format that can honour `.co` rather than merely record it. A gutter
                    // is print columns at 10 CPI -> tenths of an inch. Wraps the ALREADY
                    // fully-assembled/indented paragraph — see this branch's own header
                    // comment for why this is not a separate rendering path.
                    if let n = block.columns, n > 1 {
                        let gap = block.columnGutter.map {
                            "; column-gap:\(fixedTwoDecimals($0 / 10.0))in"
                        } ?? ""
                        pHTML = "<div style=\"column-count:\(n)\(gap)\">\(pHTML)</div>"
                    }
                    if quote {
                        // round 3/4: quote-classified styles become a real <blockquote>;
                        // CONSECUTIVE quote paragraphs share ONE.
                        quoteBuffer.append(pHTML)
                    } else {
                        builder.addText(pHTML)
                    }
                }
                plainRunLines.removeAll()
            }

            // Columns (or any other block excluded from structure classification --
            // quote-styled, wrap=off) never reach `blockRows` -- the whole block is one
            // plain run, the same shape assembleParagraphUnits already gave it before
            // structure rules existed. `blockRows[bi] ?? []` alone would silently drop
            // an excluded block's own content instead (an empty row list flushes
            // nothing) -- ctrl-kd round 13, mechanism 3's fix, found the SAME way here:
            // a quote group's own paragraphs vanished entirely once quote blocks were
            // excluded, until this fallback was added.
            let rows = blockRows[bi] ?? mergedLines(block).map { (line: $0, structure: nil as RowStructure?) }
            for (line, structure) in rows {
                guard let s = structure, let kind = s.kind else {
                    // Only the untagged, spaces-padded mechanism is new here (rule 3's
                    // second half) -- a real align=center/right/justify tag already
                    // renders correctly via `htmlAlignAttribute` below and is left
                    // exactly as it was, so a document using only the tag stays
                    // byte-identical.
                    if let s = structure, s.centered, s.centerVia == .spaces {
                        flushPlain()
                        plainRunIsBlockStart = false
                        let html = htmlCenteredRow(line, refNotes: refNotes, labels: labels,
                                                   options: options, shownMap: shownMap,
                                                   sentenceSpacing: ssOn)
                        if !html.trimmed().isEmpty {
                            // b24 round 20 (slate item 4): a "wrapped centered unit" --
                            // same tight spacing as verse, same single named constant.
                            let centeredHTML = "<p\(cls) style=\"text-align:center;"
                                + "line-height:\(verseLineHeight)\">\(html)</p>"
                            // A spaces-centered row inside a quote-classified block must
                            // still participate in quote CONTINUITY (round 4) — without
                            // this it broke a quote group in two around the centred row.
                            if quote {
                                quoteBuffer.append(centeredHTML)
                            } else {
                                builder.addText(centeredHTML)
                            }
                        }
                    } else {
                        plainRunLines.append(line)
                    }
                    continue
                }
                flushPlain()
                plainRunIsBlockStart = false
                let raw = Array(line.spans.map(\.text).joined())
                switch kind {
                case .bullet:
                    let bodyLen = s.body?.count ?? 0
                    let body = htmlSlice(line.spans, start: raw.count - bodyLen, end: nil,
                                         refNotes: refNotes, labels: labels, options: options,
                                         shownMap: shownMap, sentenceSpacing: ssOn)
                    builder.addBullet(level: s.level, cls: cls, html: body)
                case .def:
                    var lead = 0
                    while lead < raw.count, raw[lead] == " " { lead += 1 }
                    let labelLen = s.label?.count ?? 0
                    let bodyLen = s.body?.count ?? 0
                    let dt = htmlSlice(line.spans, start: lead, end: lead + labelLen,
                                       refNotes: refNotes, labels: labels, options: options,
                                       shownMap: shownMap, sentenceSpacing: ssOn)
                    let dd = htmlSlice(line.spans, start: raw.count - bodyLen, end: nil,
                                       refNotes: refNotes, labels: labels, options: options,
                                       shownMap: shownMap, sentenceSpacing: ssOn)
                    builder.addDef(level: s.level, cls: cls, dt: dt, dd: dd)
                }
            }
            flushPlain()
        }
    }
    builder.flush(&parts)
    flushQuote()

    // One `doc-endnotes` section per included, non-empty kind, `noteKindOrder`'s order —
    // a plain `<hr>` first, only if at least one such section exists.
    let sections: [String] = noteKindOrder.compactMap { kind in
        guard options.notes.contains(kind) else { return nil }
        let entries = noteListEntries(doc, kind: kind, labels: labels)
        guard !entries.isEmpty else { return nil }
        let labelID = "\(kind.rawValue)s-label"
        let items = entries.map { htmlNoteListItem($0, linkComments: shownMap != nil,
                                                   sentenceSpacing: ssOn) }.joined()
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
        let extra = styleCSS(doc, printed: printed, inlineStyling: options.inlineStyling)
        if !extra.isEmpty { css += "\n" + extra }
    }
    // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index at the document's own end, gated by
    // `--toc` (default off). HTML is non-paged: no page references, ever.
    if options.toc {
        let tocHTML = htmlTOCIndex(doc)
        if !tocHTML.isEmpty {
            parts.append(tocHTML)
        }
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
///
/// PRINTED keeps the margins verbatim — Printed's whole point is the file's own WS4-absolute
/// page geometry. MODERN drops `margin-left`/`margin-right` entirely (round 3): those inch
/// values were measured against the ORIGINAL page's own width, and a reflowed reader column
/// is a different, much narrower measure. Modern presentation NORMALIZES instead: body
/// styles get the full reader measure; a quote-classified style's visible inset comes
/// structurally from `<blockquote>` at the `emitHTML` call site, not from this per-style CSS.
func styleCSS(_ doc: Document, printed: Bool = true, inlineStyling: Bool = true) -> String {
    var rules: [String] = []
    for entry in doc.styles {
        guard let record = entry.record else { continue }   // recordless base entry
        var props: [String] = []
        if let align = record.justification {
            props.append("text-align:\(align.rawValue)")
        }
        // A ZERO margin is not a margin worth emitting — Python tests the value's own
        // truthiness, not merely its presence.
        if printed {
            if let lm = record.leftMarginHMI, lm != 0 {
                props.append("margin-left:\(fixedTwoDecimals(Double(lm) / 1800.0))in")
            }
            if let rm = record.rightMarginHMI, rm != 0 {
                // `.rm`'s hmi is a COLUMN POSITION, same as `rightMargin` everywhere
                // else (register b32) -- convert to columns, then to the actual
                // indent width, before rendering it as inches.
                let rmCols = Double(roundHalfToEven(Double(rm) / 180.0))
                let riCols = rmIndentCols(rmCols)
                if riCols != 0 {
                    props.append("margin-right:\(fixedTwoDecimals(riCols * 0.1))in")
                }
            }
        }
        let attrs = record.attrs
        if attrs.contains(.bold) { props.append("font-weight:bold") }
        if attrs.contains(.italic) { props.append("font-style:italic") }
        var deco: [String] = []
        if attrs.contains(.underline) { deco.append("underline") }
        if attrs.contains(.strike) { deco.append("line-through") }
        if !deco.isEmpty { props.append("text-decoration:" + deco.joined(separator: " ")) }
        // round 5: a paragraph STYLE can declare sub/super (WSFORMAT's own attrs-on bits
        // 0x10/0x20), the same as it declares bold/italic/underline/strikeout above — the
        // paragraph-level equivalent of the run-level <sub>/<sup> tag `htmlSpan` already
        // uses, matching those elements' own default UA stylesheet.
        if attrs.contains(.sub) {
            props.append("vertical-align:sub;font-size:smaller")
        } else if attrs.contains(.sup) {
            props.append("vertical-align:super;font-size:smaller")
        }
        if let font = record.font {
            if font.height != 0 {
                props.append("font-size:\(fourSignificantDigits(Double(font.height) / 20.0))pt")
            }
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
        // ctrl-kd round 9: an UNNAMED typestyle number (no name at all) still carries a
        // real proportional bit -- `family` alone being empty must not skip the
        // monospace-or-not decision, or a nameless proportional=false record would
        // silently inherit whatever proportional face the surrounding context has.
        if !family.isEmpty || !font.proportional {
            // The whole stack: the era name first (pass-through), then the modern
            // alternates, then the generic from the block's own style bits — CSS
            // fallback is real fallback, so the original never loses its chance.
            let stack = fontStack(family, generic: font.genericStyle, proportional: font.proportional)
            let css = stack.map { name in
                // Python's `n if ' ' not in n and n.islower() else f"'{n}'"`: the bare
                // CSS generics go unquoted, every family name is quoted.
                !name.contains(" ") && name.isLowercaseCased ? name : "'\(name)'"
            }
            props.append("font-family:" + css.joined(separator: ", "))
        }
        // Python tests the float's own truthiness: a zero height is not a size.
        // b24 round 18 (RULINGS-LEDGER row 10): gated ONLY for a genuinely INLINE
        // (mid-text) font change -- `font.offset` is the byte position of a REAL
        // symmetric type-2 block, -1 (Python's `None`) for a font that came from a
        // paragraph STYLE's own record instead. A style's declared size is document
        // formatting, not "the author's own inline styling", and stays unconditional --
        // `--inline-styling off` never touches it.
        if font.points != 0, inlineStyling || font.offset < 0 {
            props.append("font-size:\(fourSignificantDigits(font.points))pt")
        }
        if !props.isEmpty {
            rules.append(".ws-font-\(index) { " + props.joined(separator: "; ") + " }")
        }
    }
    if inlineStyling {
        for n in coloursUsed(doc) {
            let (r, g, b) = cgaPalette[n % 16]
            rules.append(".ws-colour-\(n) { color:#" + hex2(r) + hex2(g) + hex2(b) + " }")
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
