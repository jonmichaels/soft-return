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
func markdownSpan(_ span: Span, plain: Bool = false) -> String {
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

    // round 3 (2026-08-17): a letterless marker line (a centred '#' scene break, an
    // ellipsis-only pause) gets NO emphasis wrapping even when its source span carries
    // one — style alone can't tell "this is a marker" from "this is prose." The
    // character escaping above still applies; only the wrapping is skipped.
    if plain {
        return lead + core + trail
    }

    for entry in markdownDelimiters where span.styles.contains(entry.style) {
        core = entry.delimiter + core + entry.delimiter
    }
    for entry in markdownHTMLTags where span.styles.contains(entry.style) {
        core = "<\(entry.tag)>" + core + "</\(entry.tag)>"
    }
    return lead + core + trail
}

/// A real scene-break marker ('#', '* * *', '...') is a handful of characters at most —
/// see `mdUnitLines`'s own docstring for why this bound exists at all. Port of
/// `emit._MARKER_MAX_LEN`.
private let markerMaxLen = 5

/// One paragraph unit's Lines rendered to Markdown text, EVERY line's own leading indent
/// dropped — Markdown carries no first-line-indent concept and no verse-indent concept
/// either; a literal leading run also risks CommonMark reading 4+ columns as an indented
/// code block. A SHORT letterless marker line renders with `plain: true` so it never picks
/// up emphasis wrapping from a source style it happens to share with body prose. Every
/// span's EFFECTIVE styles (merged with the containing Block's own paragraph-style attrs)
/// are what actually get rendered. Port of `emit._md_unit_lines`.
private func mdUnitLines(_ unit: [Line], refNotes: [Note], labels: [String], options: EmitOptions,
                         block: Block, sentenceSpacing: Bool = false) -> [String] {
    unit.map { line in
        let raw = line.spans.map(\.text).joined()
        let stripped = raw.trimmed()
        let plain = !stripped.isEmpty && stripped.count <= markerMaxLen
            && !raw.contains(where: \.isLetter)
        var spans = line.spans.map { sp -> Span in
            var s = sp
            s.styles = effectiveSpanStyles(sp, block: block)
            s.colour = effectiveSpanColour(sp, block: block)      // register C5
            return s
        }
        // N9 (b33 field notes): applied to the EFFECTIVE-style spans, before rendering --
        // the same choke point every other emitter's own span-to-output step uses.
        if sentenceSpacing { spans = sentenceSpacingSpans(spans) }
        let text = spans.map { markdownReferenceSpan($0, refNotes: refNotes, labels: labels,
                                                      options: options, plain: plain) }.joined()
        // N9 MD guard (independent of the flag): never leave a line ending in 2+ spaces
        // baked into its OWN text -- CommonMark reads that as a hard break, and the only
        // place this emitter ever WANTS one is the explicit "  \n" join the caller adds
        // itself. `strippedOfSpaces()` (both ends, space-only) replaces the old
        // leading-only drop -- even 'keep' must not let an author's own trailing double
        // space at a reflowed line end masquerade as a break the source never asked for.
        return text.strippedOfSpaces()
    }
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
    _ span: Span, refNotes: [Note], labels: [String], options: EmitOptions, plain: Bool = false
) -> String {
    if span.pctlHMI != nil {
        return ""                  // screen-only print-control display string (M10)
    }
    // b24 round 19 (RULINGS-LEDGER PIX row, "PIX images RULED IN"): MD has NO true
    // embed (ruled) -- both `.embed` and `.export` render the same relative link here;
    // the CLI ALWAYS writes the PNG for MD regardless of which mode was asked (embed
    // additionally gets a one-line stderr degradation note, printed by the CLI -- this
    // function stays silent, same convention as every other emitter's pix branch). A
    // miss, `.off`, or a caller that built `pixResults`/`pictures` but never wrote the
    // files (no `imageLinks` entry) all fall straight through to the unchanged
    // placeholder text below -- never a link to a file that was never written.
    if let pixIndex = span.pix, options.pictures != .off,
       let result = options.pixResults.first(where: { $0.index == pixIndex }), result.ok,
       let link = options.imageLinks[result.index] {
        let alt = pixBasename(result.rawPath).replacingAll("[", with: "\\[")
            .replacingAll("]", with: "\\]")
        return "![\(alt)](\(link))"
    }
    guard span.styles.contains(.fnref) else { return markdownSpan(span, plain: plain) }
    switch resolveReference(span, refNotes: refNotes, labels: labels, options: options) {
    case .note(let note, let label, _): return "[^\(markdownReferenceKey(note.kind, label: label))]"
    case .excluded: return ""
    case .invalid: return markdownSpan(span, plain: plain)
    }
}

/// TOC/Index for Markdown — `TABLE OF CONTENTS`/`INDEX` become `# `-headed, every entry
/// double-newline-separated (CommonMark's own paragraph break), blank filler lines from
/// `plainTOCIndexLines` (which uses them as single-newline section spacing) dropped since
/// the `\n\n` join already provides breathing room. Empty when there is nothing to compile.
/// Port of the transform inline in `emit_markdown`'s two toc-handling sites.
private func markdownTOCIndexBlock(_ doc: Document) -> String {
    let lines = plainTOCIndexLines(doc)
    guard !lines.isEmpty else { return "" }
    return lines.filter { !$0.isEmpty }.map {
        ($0 == "TABLE OF CONTENTS" || $0 == "INDEX") ? "# \($0)" : $0
    }.joined(separator: "\n\n")
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
        // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index goes OUTSIDE the fence -- it is
        // ADDED content, not part of the verbatim facsimile the fence itself promises --
        // so `toc` is explicitly excluded from the delegated emitText call and handled
        // here instead. Markdown is non-paged even in printed mode: no page references.
        var textOptions = options
        textOptions.toc = false
        let body = emitText(doc, mode: .printed, options: textOptions)
        var out = "```\n" + body.trimmingTrailing("\n") + "\n```\n"
        if options.toc {
            let block = markdownTOCIndexBlock(doc)
            if !block.isEmpty {
                out += "\n" + block + "\n"
            }
        }
        return out
    }

    let refNotes = inlineReferenceNotes(doc)
    // Reached only in Modern mode (printed returned above via emit_text's own printed
    // facsimile, `\f` pages included) -- Modern MD has no pages of its own, so it
    // takes the same collision-triggered continuous renumbering as Modern TXT (ruling
    // 2026-08-24).
    let labels = pagelessNoteLabels(doc)
    let margin = docMargin(doc)
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    // N9 (b33 field notes): always the Modern side of the mode-aware default here
    // (Printed already returned above, inside its own fenced-facsimile branch).
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: false)
    // b24 round 20b (slate item 13): reached only in Modern mode (printed returns
    // above, inside its own fenced-facsimile branch) -- see emitText's identical
    // comment for the doctrine.
    let screenplayBlocks = detectScreenplayBlocks(doc)
    var out: [String] = []
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak {
            out.append("---")
            continue
        }
        if block.heading != 0 {
            // a heading is a logical unit, not reflowed prose. EVERY line's own leading
            // indent is dropped — an interior line's own baked centering/typed indent
            // must not leak into the output raw, same CommonMark 4-space hazard
            // `mdUnitLines` guards against for ordinary paragraphs.
            let lines = mergedLines(block).map { line -> String in
                var spans = line.spans.map { sp -> Span in
                    var s = sp
                    s.styles = effectiveSpanStyles(sp, block: block)
                    s.colour = effectiveSpanColour(sp, block: block)  // register C5
                    return s
                }
                // N9: applied here too (a heading is content), but WITHOUT the
                // trailing-space MD guard below -- ctrl-kd's own heading path never
                // gained that guard (it only touched `_md_unit_lines`/note defs), and
                // byte-parity beats elegance.
                if ssOn { spans = sentenceSpacingSpans(spans) }
                let text = spans.map { markdownReferenceSpan($0, refNotes: refNotes, labels: labels,
                                                              options: options) }.joined()
                return String(text.drop(while: { $0 == " " }))
            }
            let para = lines.joined(separator: "  \n")
            if !para.trimmed().isEmpty {
                out.append(String(repeating: "#", count: max(0, block.heading)) + " " + para.trimmed())
            }
            continue
        }
        let quote = isQuoteStyle(block)
        let dominant = blockDominantStyles(mergedLines(block))
        for unit in assembleParagraphs(block, margin: margin,
                                       headPosition: headPosition[bi] ?? false,
                                       conventionIndent: conventionIndent) {
            var lines = mdUnitLines(unit, refNotes: refNotes, labels: labels, options: options, block: block,
                                    sentenceSpacing: ssOn)
            guard lines.contains(where: { !$0.trimmed().isEmpty }) else { continue }
            // round 3b: a hard break is reserved for a REAL deliberate line break — a
            // verified verse/stanza unit — matching HTML/RTF/Text's own same-rule fix.
            // round 7 (Register C23): a wrap=off block's unit is ALWAYS verse -- without
            // this guard a non-verse multi-line unit still flows into one run-on line.
            let isVerse = !block.wrap || looksLikeVerse(unit, dominantStyles: dominant)
                || screenplayBlocks.contains(bi)
            if unit.count > 1, !isVerse {
                lines = [lines.filter { !$0.trimmed().isEmpty }.joined(separator: " ")]
            }
            if quote {
                // rule D: Markdown's only way to say "quoted" is '>'.
                out.append(lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
            } else {
                // round 4: a hard break is two TRAILING SPACES before the newline, not a
                // trailing backslash — invisible in the raw text, which a backslash is not.
                out.append(lines.joined(separator: "  \n"))
            }
        }
    }

    var md = out.joined(separator: "\n\n")

    // A flat list of `[^key]: text` definitions, `noteKindOrder`'s kinds each contributing
    // their notes in document order — no per-kind grouping or header (pandoc needs none),
    // just one definition per line. Each embedded line's own leading run is stripped for
    // the same reason as everywhere else in this emitter: no first-line-indent or
    // verse-indent concept in Markdown, and 4+ columns risks CommonMark reading it as an
    // indented code block.
    var defs: [String] = []
    for kind in noteKindOrder where options.notes.contains(kind) {
        for entry in noteListEntries(doc, kind: kind, labels: labels) {
            // ctrl-kd round 12: also backslash-escape it, same as `markdownSpan` already
            // does for every other piece of rendered text. A note's text bypasses
            // `markdownSpan` entirely (embedded verbatim, here), so it was the one path
            // in this emitter a content backslash reached CommonMark unescaped --
            // doubled at ANY position (not just end of line), since a bare backslash is
            // CommonMark's ESCAPE character everywhere it appears, not only where it
            // also happens to double as the hard-break marker.
            //
            // N9: the sentence-spacing collapse applies to the note's WHOLE text before
            // splitting on embedded newlines (state carries across them, same as every
            // other choke point); the MD guard below is `strippedOfSpaces()` (both
            // ends), not just a leading drop -- same reason as `mdUnitLines`'s own guard,
            // a note's own trailing double space at an embedded line break must never be
            // read as an unintended hard break.
            let noteText = ssOn ? sentenceSpacingTexts([entry.note.text])[0] : entry.note.text
            let body = noteText.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).strippedOfSpaces().replacingAll("\\", with: "\\\\") }
                .joined(separator: "\n")
            defs.append("[^\(markdownReferenceKey(kind, label: entry.label))]: " + body)
        }
    }
    if !defs.isEmpty {
        md += "\n\n" + defs.joined(separator: "\n")
    }
    // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index at the document's own end, gated by
    // `--toc` (default off). Non-paged: no page references.
    if options.toc {
        let block = markdownTOCIndexBlock(doc)
        if !block.isEmpty {
            md += "\n\n" + block
        }
    }
    return md + "\n"
}
