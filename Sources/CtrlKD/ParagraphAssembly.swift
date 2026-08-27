/// Modern paragraph assembly, verse/stanza preservation, and shared style-merge helpers —
/// the b23 "exports overhaul." Direct port of `core.py`'s additions: `coalesce_spans`,
/// `assemble_paragraphs`, `paragraph_layout_context`, `looks_like_verse`,
/// `effective_span_styles`, `split_leading_indent`, and their supporting helpers.
///
/// A WordStar manuscript that marks new paragraphs by indentation, not a blank line, stores
/// every typed paragraph as its own hard-return-terminated Line inside ONE Block. Nothing
/// before this reflowed that Block back into paragraphs; every Modern emitter joined all of
/// them with its same-paragraph separator, so typed paragraphs read as one run-on paragraph
/// with forced line breaks. This file supplies the shared classification every Modern
/// emitter (Text/Markdown/HTML/RTF) now consumes.

/// How far short of the block's own measured wrap point a hard-terminated line's visible
/// length may fall and still count as "short" — a stanza candidate rather than an ordinary
/// paragraph. Port of `core.PARAGRAPH_JOIN_SLACK`.
let paragraphJoinSlack = 10
/// Fraction of a run's letters-containing lines ending as a finished sentence, at or above
/// which the run reads as prose rather than verse. Port of `core.VERSE_TERMINAL_FRACTION`.
let verseTerminalFraction = 0.8
/// Fraction of a run's lines opening AND CLOSING a quotation on their own single line
/// that vetoes a verse call outright — SELF-CONTAINED, not merely "starts with a quote
/// mark" (b26-modern item 5, ctrl-kd d686f8b, WARPRAYR.WS's own quoted hymn couplet,
/// real WS7 corpus): `"God the all-terrible! Thou who ordainest, / Thunder thy
/// clarion..."` is a SINGLE quotation spanning two short lines — only its first line
/// opens with `"`, at 1-of-2 (0.5) comfortably past the old bare-"starts with a quote
/// mark" bar, silently vetoing a genuine verse couplet as if it were dialogue. Real
/// spoken-dialogue exchanges (this fraction's own calibration fixtures,
/// `ws4DialogueRunDoesNotFalsePositiveAsStanza`: `"Where are you going?"` / `"I already
/// told you."`) open AND close their quote on the SAME line every time — each is one
/// self-contained utterance. A line that opens a quotation but does not close it before
/// its own end is exactly as consistent with "this is the first line of a quoted
/// passage spanning several lines" as with dialogue, so it must not single-handedly
/// veto a verse read; `selfContainedQuote` requires both marks on one line before a
/// line counts toward this fraction. Port of `core.VERSE_QUOTE_VETO_FRACTION`.
let verseQuoteVetoFraction = 1.0 / 3.0
/// Fraction of a run showing an attribute shift from the block's dominant style, above
/// which the run reads as verse. Port of `core.VERSE_ATTR_SHIFT_FRACTION`.
let verseAttrShiftFraction = 0.5
/// Fraction of a run ending as finished sentences at or above which NO attribute shift can
/// rescue a verse call — decisively terminal prose, full stop. Port of
/// `core.VERSE_ATTR_SUPPORTED_CEILING`.
let verseAttrSupportedCeiling = 0.9

private let closingQuoteChars: Set<Character> = ["\"", "\u{2019}", "\u{201D}", "'"]
private let openingQuoteChars: Set<Character> = ["\"", "\u{2018}", "\u{201C}", "'"]

/// A span's full "effective attribute set" for coalescing/shift-detection purposes — style
/// bits plus font/colour/print-control identity, matching Python's single `styles` frozenset
/// (which carries `fontN`/`colourN`/`pctlN` as string tags in the SAME set the b/i/u/... codes
/// live in). Two spans are the coalescing-equal / shift-equal iff their `StyleKey`s match.
public struct StyleKey: Hashable, Sendable {
    public var styles: Style
    public var font: Int?
    public var colour: Int?
    public var pctlHMI: Int?
    /// b24 round 19 (RULINGS-LEDGER PIX row): joins the key for the same reason
    /// `pctlHMI` does — Python's `pix<N>` tag lives in the same frozenset as every
    /// other style code, so two adjacent placeholder spans with DIFFERENT indices
    /// (a document with two consecutive pix tags) must never coalesce into one.
    public var pix: Int?
    /// Register C2 (LJ6DTP parity): a print control carrying a RAW PCL payload is tagged
    /// `pcl<N>` in Python's same frozenset, so two ADJACENT controls -- LJ6DTP's
    /// checkerboard row is a long run of them, every one declaring the same 0 HMI width --
    /// never coalesce into one there. Merged here, the second control's program is lost.
    public var pcl: Int?
    /// The tab-positioning round: Python tags a type-9 tab's padding span
    /// `tabhmi<N>`/`tableader<N>` in that same frozenset, which is precisely what keeps the
    /// padding a span of its OWN -- never merged with the typed text before or after it.
    /// PDFLayout's `coalesce` already carries both; this is the identical test for the
    /// RTF/HTML/Layout/Markdown side, which shares `coalesceSpans` instead.
    public var tabHMI: Int?
    public var tabLeader: Int?

    public init(styles: Style = [], font: Int? = nil, colour: Int? = nil, pctlHMI: Int? = nil,
               pix: Int? = nil, pcl: Int? = nil, tabHMI: Int? = nil, tabLeader: Int? = nil) {
        self.styles = styles
        self.font = font
        self.colour = colour
        self.pctlHMI = pctlHMI
        self.pix = pix
        self.pcl = pcl
        self.tabHMI = tabHMI
        self.tabLeader = tabLeader
    }
}

extension Span {
    var styleKey: StyleKey {
        StyleKey(styles: styles, font: font, colour: colour, pctlHMI: pctlHMI, pix: pix,
                 pcl: pcl, tabHMI: tabHMI, tabLeader: tabLeader)
    }
}

/// Adjacent Spans with byte-identical effective attributes merged into one. `merged_lines`
/// concatenates a soft-wrapped run's spans onto the logical Line it belongs to but never
/// merged the two runs at the seam even when they carried the exact same style set — one
/// continuous italic sentence that happened to wrap mid-word came out as two adjacent RTF
/// groups / HTML spans instead of one. Two spans merge iff their `StyleKey`s are equal AND
/// NEITHER is an `fnref` pointer — a footnote/endnote/annotation/comment reference mark is
/// POSITION-dependent, so merging one into surrounding text would blur a pointer, not just
/// its formatting. Port of `core.coalesce_spans`.
func coalesceSpans(_ spans: [Span]) -> [Span] {
    var out: [Span] = []
    for s in spans {
        if !out.isEmpty, out[out.count - 1].styleKey == s.styleKey,
           !out[out.count - 1].styles.contains(.fnref), !s.styles.contains(.fnref) {
            out[out.count - 1].text += s.text
        } else {
            out.append(s)
        }
    }
    return out
}

/// Break spans that MIX graphic (box-drawing/shade/block/card-suit) characters with
/// ordinary text into consecutive same-kind pieces, each its own Span carrying the
/// original styles/font/colour unchanged — so a renderer can single out the purely-
/// graphic pieces (force a monospace face; see `isGraphicText`/`ws-graphic` in
/// EmitHTML.swift, and the RTF `\f1` override in EmitRTF.swift) without touching the
/// prose sharing their line (a figure caption's own text, e.g. "Figure 1" between a
/// box's two vertical bars). Mirrors PDF's own `splitGraphics`, at the Span level
/// instead of PDF's segment tuples, reusing the SAME `graphicChars` set (single source
/// of truth in this module). A span with no graphic character at all passes through
/// unchanged. Port of `core.split_graphic_spans` (ctrl-kd round 8).
func splitGraphicSpans(_ spans: [Span]) -> [Span] {
    var out: [Span] = []
    for sp in spans {
        guard sp.text.contains(where: { graphicChars.contains($0) }) else {
            out.append(sp)
            continue
        }
        var runStart = sp.text.startIndex
        var runIsGraphic: Bool? = nil
        var idx = sp.text.startIndex
        func flush(to end: String.Index) {
            guard runStart < end else { return }
            var piece = sp
            piece.text = String(sp.text[runStart..<end])
            out.append(piece)
        }
        while idx < sp.text.endIndex {
            let isG = graphicChars.contains(sp.text[idx])
            if let cur = runIsGraphic, cur != isG {
                flush(to: idx)
                runStart = idx
            }
            runIsGraphic = isG
            idx = sp.text.index(after: idx)
        }
        flush(to: sp.text.endIndex)
    }
    return out
}

/// A Line's text with footnote/endnote/annotation/comment REFERENCE MARKERS (`fnref` spans
/// — `.text` is a reference index, not real content) skipped. Port of `core.line_visible_text`.
func lineVisibleText(_ line: Line) -> String {
    line.spans.filter { !$0.styles.contains(.fnref) }.map(\.text).joined()
}

/// Count of literal leading space characters — Python's `len(t) - len(t.lstrip(' '))`,
/// which strips ONLY the space character, unlike this codebase's general `trimmedLeading()`
/// (a wider whitespace set). Every indent measurement in this file needs the space-only form.
func leadingSpaceCount(_ text: String) -> Int {
    var n = 0
    for ch in text {
        guard ch == " " else { break }
        n += 1
    }
    return n
}

/// Whether `text` ends as a finished sentence (`.`/`!`/`?`), a trailing closing
/// quote/apostrophe stripped first so a quoted question ("What?") still counts. Port of
/// `core._ends_terminal`.
private func endsTerminal(_ text: String) -> Bool {
    var chars = Array(text.trimmedTrailing())
    while let last = chars.last, closingQuoteChars.contains(last) {
        chars.removeLast()
    }
    guard let last = chars.last else { return false }
    return last == "." || last == "!" || last == "?"
}

/// Port of `core._opens_quote`. Not `private`: b26-modern item 5's ported test
/// (`VerseQuoteCoupletTests.swift`) calls this directly, mirroring ctrl-kd's own
/// `core._opens_quote` reference at the test level (module-internal, same as
/// `selfContainedQuote` below — visible to `@testable import` test targets, hidden
/// from consumers outside this package).
func opensQuote(_ text: String) -> Bool {
    guard let first = text.trimmedLeading().first else { return false }
    return openingQuoteChars.contains(first)
}

/// Whether TEXT both opens AND closes a quotation on its own single line —
/// `verseQuoteVetoFraction`'s own evidence base (see its doc comment): real spoken
/// dialogue is one self-contained utterance per line, but a line that only OPENS a
/// quotation — the first line of a passage quoted across several lines, e.g. a hymn or
/// poem excerpt — is not, even though `opensQuote` alone would also say `true` for it.
/// Port of `core._self_contained_quote` (b26-modern item 5).
func selfContainedQuote(_ text: String) -> Bool {
    let t = text.trimmedLeading()
    guard let first = t.first, openingQuoteChars.contains(first) else { return false }
    return t.dropFirst().contains { closingQuoteChars.contains($0) }
}

/// The ATTRIBUTES a character actually renders with — a span's own typed toggles merged with
/// whatever the containing Block's own paragraph STYLE turns on, plus WordStar's own
/// "headings render bold" convention when `headingBold` is asked for. Port of
/// `core.effective_span_styles`.
func effectiveSpanStyles(_ span: Span, block: Block, headingBold: Bool = false) -> Style {
    var styles = span.styles.union(block.styleAttrs)
    if headingBold, block.heading != 0 { styles.insert(.bold) }
    return styles
}

/// The COLOUR a span actually renders in — its own inline colour, or the containing
/// Block's paragraph STYLE colour as the default. Register C5: a paragraph style's own
/// declared colour (`Block.styleColour`, e.g. LJ6DTP's "Section Heading Font" at colour
/// 3) is a DEFAULT for every span the style governs — used only when the span carries no
/// colour of its own (an inline type-1 colour change mid-run overrides the style default,
/// never the reverse) and only when it is NOT 0. Colour 0 is explicit "Black" in the style
/// record, but every known driver palette (and RTF's own colour-0-is-automatic convention)
/// already treats 0 identically to "no colour at all" — honouring it would add a colour
/// class/control word to nearly every plain paragraph in a styled document for zero visual
/// change, which is not what this merge is for.
///
/// Python does this inside `effective_span_styles`, where a `colourN` string joins the
/// same frozenset as the attribute codes; `Span.colour` is a typed field here, so the
/// merge is its own function called beside that one.
func effectiveSpanColour(_ span: Span, block: Block) -> Int? {
    if span.colour == nil, let styleColour = block.styleColour, styleColour != 0 {
        return styleColour
    }
    return span.colour
}

/// The styles of a Line's own text, its leading indent (if any) set aside first — the signal
/// `looksLikeVerse` needs to notice a run set in a DIFFERENT attribute than the block's prose.
/// Returns the first non-blank span's full `StyleKey`, or an empty key for an all-blank line.
/// Port of `core.line_body_styles`.
func lineBodyStyles(_ line: Line) -> StyleKey {
    let (_, spans) = splitLeadingIndent(line.spans)
    for sp in spans where !sp.styles.contains(.fnref) && !sp.text.trimmed().isEmpty {
        return sp.styleKey
    }
    return StyleKey()
}

/// The most common `lineBodyStyles` result across a block's own (already merged) Lines — its
/// "ordinary prose" attribute. Ties resolve to the first-encountered value, matching Python's
/// insertion-ordered `Counter`. Port of `core.block_dominant_styles`.
func blockDominantStyles(_ lines: [Line]) -> StyleKey {
    var order: [StyleKey] = []
    var counts: [StyleKey: Int] = [:]
    for line in lines {
        let key = lineBodyStyles(line)
        if counts[key] == nil { order.append(key) }
        counts[key, default: 0] += 1
    }
    guard var best = order.first else { return StyleKey() }
    for key in order where counts[key]! > counts[best]! { best = key }
    return best
}

/// Fraction of RUN's letters-containing lines that end as a finished sentence. 1.0 (reads as
/// maximally prose) for a scoreless run. Port of `core._run_term_frac`.
func runTermFrac(_ run: [Line]) -> Double {
    let texts = run.map(lineVisibleText).filter { !$0.trimmed().isEmpty }
    let scored = texts.filter { $0.contains(where: \.isLetter) }
    guard !scored.isEmpty else { return 1.0 }
    return Double(scored.filter(endsTerminal).count) / Double(scored.count)
}

/// Whether a RUN of consecutive short, indented, hard-terminated Lines reads as a stanza
/// (deliberate verse) rather than a run of short PROSE paragraphs. Three signals, no single
/// one required — see `core.looks_like_verse`'s own docstring for the full evidence trail.
/// Ties resolve to PROSE.
func looksLikeVerse(_ run: [Line], dominantStyles: StyleKey = StyleKey()) -> Bool {
    let nonBlank = run.map(lineVisibleText).filter { !$0.trimmed().isEmpty }
    // A FOURTH signal, checked first and decisive on its own (ctrl-kd round 8, SCRIPT.WS):
    // a run that is MAJORITY pure cp437 box-drawing/shade/block content (no letters at
    // all) is never prose, full stop -- a caption box's own top and bottom border carry
    // zero alphabetic scoring material by definition, which is exactly the case the
    // letters-only floor right below exists to be cautious about, and wrongly so here (a
    // figure caption's own box -- 2 of its 3 lines pure border -- tripped that floor,
    // fell back to prose, and split one box into three independently-reflowed/centred
    // paragraphs, misaligned once a proportional font entered the picture).
    if nonBlank.count >= 2 {
        let graphicHits = nonBlank.filter { t in
            !t.contains(where: \.isLetter) && t.contains(where: { graphicChars.contains($0) })
        }.count
        if Double(graphicHits) / Double(nonBlank.count) >= 0.5 {
            return true
        }
    }
    let scored = nonBlank.filter { $0.contains(where: \.isLetter) }
    guard scored.count >= 2 else { return false }
    if Double(scored.filter(selfContainedQuote).count) / Double(scored.count) >= verseQuoteVetoFraction {
        return false
    }
    let termFrac = Double(scored.filter(endsTerminal).count) / Double(scored.count)
    if termFrac >= verseAttrSupportedCeiling {
        return false
    }
    let shifted = run.filter { !lineVisibleText($0).trimmed().isEmpty }.map(lineBodyStyles)
    let emptyKey = StyleKey()
    let shiftHits = shifted.filter { $0 != emptyKey && $0 != dominantStyles }.count
    let shiftFrac = Double(shiftHits) / Double(shifted.count)
    // strict >, not >=: a tie must NOT be enough on its own -- ties resolve to prose.
    if shiftFrac > verseAttrShiftFraction {
        return true
    }
    return termFrac < verseTerminalFraction
}

/// `merged_lines(block)` grouped into Modern paragraph units — see `core.assemble_paragraphs`
/// for the full two-phase rationale (indent starts a unit, flush continues one; runs of short
/// single-line units get a second look via `looksLikeVerse`) plus the convention-outlier/
/// positional epigraph route and the in-run widening addendum. Returns a list of paragraph
/// units, each a non-empty list of Lines.
func assembleParagraphs(_ block: Block, margin: Double = 65, headPosition: Bool = false,
                        conventionIndent: Int? = nil) -> [[Line]] {
    assembleParagraphUnits(mergedLines(block), margin: margin, headPosition: headPosition,
                           conventionIndent: conventionIndent, wrap: block.wrap)
}

/// The line-list-based core of `assembleParagraphs`, split out so a caller that already
/// has its own line subsequence (HTML's structure-rules classification pulls
/// bullet/def/centered rows out of a block's own `mergedLines` first, leaving the
/// remaining "plain" rows to reflow the same way an ordinary block's lines would) can
/// reuse the paragraph-assembly logic without a whole synthetic `Block`. Every caller that
/// wants Python's own `core.assemble_paragraphs(block, ...)` contract should go through
/// `assembleParagraphs(_:margin:headPosition:conventionIndent:)` above instead — this
/// entry point exists for the one case this port needs it (HTML's plain-line sub-runs),
/// which the b23 Python source has no equivalent of (see `EmitHTML.swift`'s own notes on
/// the structure-rules feature not existing upstream).
///
/// `wrap` (ctrl-kd round 7, Register C23): `.aw off` means the author is positioning
/// these lines BY HAND — checked FIRST, before either phase and before the convention-
/// outlier route, and unconditionally (never put through `looksLikeVerse` at all: an
/// explicit dot command is stronger evidence than any inferred signal). Every caller
/// MUST pass the real block's own `wrap` (the default `true` here only covers a caller
/// that genuinely has no block, e.g. a heading's own line-joining, which was never
/// wrap-sensitive to begin with).
func assembleParagraphUnits(_ lines: [Line], margin: Double = 65, headPosition: Bool = false,
                            conventionIndent: Int? = nil, wrap: Bool = true) -> [[Line]] {
    guard !lines.isEmpty else { return [] }

    if !wrap {
        return [lines]           // .aw off: whole block, one preserved unit
    }

    if let conventionIndent {
        let firstText = lineVisibleText(lines[0])
        let openingIndent = leadingSpaceCount(firstText)
        if openingIndent != conventionIndent {
            let nonBlank = lines.filter { !lineVisibleText($0).trimmed().isEmpty }
            if nonBlank.count >= 2 {
                var wholeVerse = looksLikeVerse(nonBlank, dominantStyles: blockDominantStyles(lines))
                if wholeVerse, !headPosition {
                    wholeVerse = runTermFrac(nonBlank) == 0.0
                }
                if wholeVerse {
                    return [lines]
                }
            }
        }
    }
    let effectiveMarginValue = margin != 0 ? margin : 65
    let threshold = max(1, Int(effectiveMarginValue) - paragraphJoinSlack)

    var units: [[Line]] = [[lines[0]]]
    for line in lines.dropFirst() {
        if lineVisibleText(line).hasPrefix("     ") {
            units.append([line])
        } else {
            units[units.count - 1].append(line)
        }
    }

    func isShort(_ u: [Line]) -> Bool {
        guard u.count == 1 else { return false }
        let text = lineVisibleText(u[0]).trimmedTrailing()
        return !text.isEmpty && text.count < threshold
    }

    let effectiveMargin = Int(effectiveMarginValue)

    func isRunCandidate(_ k: Int) -> Bool {
        if isShort(units[k]) { return true }
        let u = units[k]
        guard u.count == 1 else { return false }
        let text = lineVisibleText(u[0]).trimmedTrailing()
        guard !text.isEmpty, text.count < effectiveMargin else { return false }
        let prevOK = k > 0 && isShort(units[k - 1])
        let nextOK = k + 1 < units.count && isShort(units[k + 1])
        return prevOK && nextOK
    }

    let dominant = blockDominantStyles(lines)
    var out: [[Line]] = []
    var i = 0
    while i < units.count {
        if !isRunCandidate(i) {
            out.append(units[i])
            i += 1
            continue
        }
        var j = i
        while j < units.count, isRunCandidate(j) { j += 1 }
        let run = units[i..<j].map { $0[0] }
        if run.count >= 2, looksLikeVerse(run, dominantStyles: dominant) {
            out.append(run)
        } else {
            out.append(contentsOf: units[i..<j])
        }
        i = j
    }
    return out
}

/// (conventionIndent, headPosition) — the two whole-document signals `assembleParagraphs`'s
/// convention-outlier/positional route needs, computed once per document. `headPosition` is
/// keyed by BLOCK INDEX (Swift's `Block` is a value type with no Python-`id()` equivalent;
/// document order is stable and unambiguous either way). Port of `core.paragraph_layout_context`.
func paragraphLayoutContext(_ doc: Document) -> (conventionIndent: Int, headPosition: [Int: Bool]) {
    var order: [Int] = []
    var counts: [Int: Int] = [:]
    for block in doc.blocks {
        guard block.kind == .para, !block.lines.isEmpty, block.heading == 0 else { continue }
        let lines = mergedLines(block)
        guard let first = lines.first else { continue }
        let indent = leadingSpaceCount(lineVisibleText(first))
        if counts[indent] == nil { order.append(indent) }
        counts[indent, default: 0] += 1
    }
    var conventionIndent = 0
    if var best = order.first {
        for v in order where counts[v]! > counts[best]! { best = v }
        conventionIndent = best
    }

    var headPosition: [Int: Bool] = [:]
    var inFrontMatter = true
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak {
            inFrontMatter = true
            continue
        }
        guard block.kind == .para, !block.lines.isEmpty else { continue }
        if block.heading != 0 {
            inFrontMatter = true
            continue
        }
        headPosition[bi] = inFrontMatter
        if inFrontMatter {
            let lines = mergedLines(block)
            if let first = lines.first {
                let indent = leadingSpaceCount(lineVisibleText(first))
                if indent == conventionIndent { inFrontMatter = false }
            }
        }
    }
    return (conventionIndent, headPosition)
}

/// (indentCols, spans) — a leading run of literal spaces measured and removed from the first
/// VISIBLE span (a leading `fnref` marker is skipped over, not mistaken for having no
/// indent). `(0, spans)` unchanged when there is no leading run — `spans` is returned as-is.
///
/// ctrl-kd round 10: the indent itself can straddle a STYLE change (a document that types
/// five plain spaces, toggles bold, then types three MORE spaces before the visible label
/// — "     " + <^B> + "   Function:") — one typed indent in the author's own head, but two
/// Spans once decoded, with genuinely different (so correctly un-coalesced) style sets. Any
/// number of WHOLE leading spans-only Spans, of any style, are consumed first, before the
/// final partial strip runs on whichever span is left at the front carrying real content —
/// the original single-span version below popped the first all-whitespace span and stopped,
/// leaving a second span's own leading spaces sitting untouched as a literal indent.
/// Port of `core.split_leading_indent`.
func splitLeadingIndent(_ spans: [Span]) -> (Int, [Span]) {
    guard !spans.isEmpty else { return (0, spans) }
    var i = 0
    while i < spans.count, spans[i].styles.contains(.fnref) { i += 1 }
    guard i < spans.count else { return (0, spans) }
    var j = i
    var n = 0
    while j < spans.count, !spans[j].text.isEmpty, spans[j].text.trimmed().isEmpty {
        n += spans[j].text.count
        j += 1
    }
    guard j < spans.count else {
        return n == 0 ? (0, spans) : (n, Array(spans[..<i]) + Array(spans[j...]))
    }
    let t = spans[j].text
    let stripped = String(t.drop(while: { $0 == " " }))
    let m = t.count - stripped.count
    guard n != 0 || m != 0 else { return (0, spans) }
    n += m
    var tail = Array(spans[(j + 1)...])
    if !stripped.isEmpty {
        var head = spans[j]
        head.text = stripped
        tail.insert(head, at: 0)
    }
    return (n, Array(spans[..<i]) + tail)
}

/// Whether a WordStar paragraph-style NAME marks quoted material (e.g. "Double-Indented
/// Quote", "MS Double-Indented Quote") — one substring test shared by every Modern format's
/// own quote treatment. Port of `core._is_quote_name`/`_is_quote_style`.
func isQuoteName(_ name: String?) -> Bool {
    asciiContains(asciiLowercased(name ?? ""), "quote")
}

func isQuoteStyle(_ block: Block) -> Bool {
    isQuoteName(block.styleName)
}

/// `stripAlignSpaces(spans)` when this block's own alignment tag will already render the
/// same visual effect, spans unchanged otherwise. Shared by every Modern body AND heading
/// path so a centred heading and a centred paragraph are never treated differently. Port of
/// `emit._maybe_strip_align`.
func maybeStripAlign(_ block: Block, _ spans: [Span]) -> [Span] {
    guard block.align == .center || block.align == .right, !spans.isEmpty else { return spans }
    return stripAlignSpaces(spans)
}

/// The block's own measured wrap point — `doc.marginEstimate`, falling back to the project's
/// 65-column floor for a synthetically built Document with no measurement at all. Port of
/// `emit._doc_margin`.
func docMargin(_ doc: Document) -> Double {
    guard let m = doc.marginEstimate, m != 0 else { return 65 }
    return Double(m)
}
