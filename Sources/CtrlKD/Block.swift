/// Provenance of a structural block — see `Block.origin` (tasks #20/#21).
public enum BlockOrigin: String, Hashable, Sendable {
    /// A pagebreak made by a literal 0x0C byte.
    case ff
    /// The fabricated `[insert: NAME]` paragraph for a `.fi` line.
    case fi
}

/// What kind of content a `Block` holds.
public enum BlockKind: String, Hashable, Sendable {
    /// Ordinary content.
    case para
    /// An explicit page break (`.pa` dot command / form feed).
    case pagebreak
    // `softpage` RETIRED 2026-08-04: a 0x0B end-of-page mark is transient editor state,
    // now `Line.softpage` — it never breaks a page and never splits a block.
    /// `.cp n` — a CONDITIONAL page break, requesting that n lines be kept together.
    /// The condition cannot be evaluated at parse time (it depends on how many lines
    /// remain on the page, which only pagination knows), so the block carries n in
    /// `heading` and the page-filling loop applies the rule.
    case condpage
}

/// Horizontal alignment of a block's lines. WordStar's default is `.left`, which every
/// emitter renders exactly as it did before alignment existed — no attribute, no control
/// code — so a document that never touches `.oc`/`.oj` is unaffected.
public enum Alignment: String, Hashable, Sendable {
    case left
    case center
    case right
    case justify
}

/// A paragraph-level unit of the document: one kind, an optional heading level,
/// and the lines it contains.
///
/// `lines` holds PHYSICAL lines since ctrl-kd 2.0.0 — see `Line.soft` and
/// `mergedLines(_:)` below.
public struct Block: Hashable, Sendable {
    public var kind: BlockKind
    public var lines: [Line]
    /// 0 = body text; 1-3 = WS5+ title/header/subheading.
    ///
    /// Overloaded for `.condpage`, where it carries `.cp`'s requested line count
    /// instead — Python stores it in the same slot, and a port that invented a second
    /// field here would diverge from the vectors for no behavioural gain.
    public var heading: Int
    /// Horizontal alignment in force when this block was opened. From `.oc` (centering
    /// on/off) and `.oj` (justification off/on/c/r), which are STATEFUL — they apply
    /// from where they appear until changed — so the state is stamped onto each block as
    /// it opens rather than looked up later. Register C16/C17.
    public var align: Alignment
    /// Whether WordStar was word-wrapping when this block was opened (`.aw on|off`).
    /// Register C23: with wrap off the author is positioning lines by hand, so a
    /// reflowing consumer must NOT re-wrap them or the layout is destroyed.
    public var wrap: Bool
    /// `.lm` / `.rm` / `.pm` in force when this block opened, in print COLUMNS (10 CPI,
    /// the same unit `.po` uses). `nil` means the file never set it, so a consumer
    /// applies its own default rather than a fabricated one. Register C9.
    ///
    /// Stateful like the alignment above, and emphatically NOT first-occurrence: one
    /// archive file sets `.pm` seven hundred times. `.pm` is the PARAGRAPH margin — the
    /// first line's own indent — which is why it is separate from `.lm`.
    public var leftMargin: Double?
    public var rightMargin: Double?
    public var paraMargin: Double?
    /// Python typing provenance for the margins (layout byte parity, ruled 2026-08-18):
    /// a paragraph-STYLE margin is a Python int (`round(hmi / 180)`), a dot-command
    /// margin a Python float (`float()`d) — and the layout JSON spells "7" vs "7.0"
    /// accordingly. True = the margin came from a style's HMI field.
    public var leftMarginPyInt: Bool
    public var rightMarginPyInt: Bool
    /// The ruler tab stops in force when this block opened (`.tb`, 10-CPI columns) —
    /// stateful like the margins. Measured 2026-08-06 (46 archive files use `.tb`, ZERO
    /// of them carry a bare 0x09): tab stops are EDITOR-time state — the Tab key
    /// resolves against them and bakes a type-9 sequence with its own position — so
    /// they change no rendered byte here; they are carried for the layout contract,
    /// Show Invisibles, and a future editor. `nil` = the ruler default (factory: every
    /// 5 cols). Task #19.
    public var tabStops: [Double]?
    /// `.co <n>, <gutter>` — newspaper columns in force when this block opened, and the
    /// gutter between them in print columns. `nil` means the file never asked, which is
    /// not the same as asking for one column. Register C5.
    public var columns: Int?
    public var columnGutter: Double?
    /// WordStar's paragraph style (symmetric type 0x11), when one was applied: the
    /// 0-based library SLOT the block's style HANDLE resolves to, and the resolved
    /// entry's name. `heading` derives from the NAME (`styleHeadingLevel`) — the corpus
    /// proved slot numbers carry no semantics. Full entry: `Document.styles`, matched on
    /// `slot`. Register C1.
    public var styleID: Int?
    public var styleName: String?
    /// Print attributes the active style turns ON, as span styles. Emitters merge them
    /// into every span in the block, the same way heading bold is merged -- the style's
    /// formatting is not a property of any one span, it applies to the paragraph.
    public var styleAttrs: Style
    /// The style record's own `lineHeightVMI` (WSFORMAT.WS's format spec: "Word: Line
    /// height in VMI, -1 = inherit" — `StyleRecord`'s own `swordNone` already folds -1
    /// to `nil` at parse time, so what survives here is -2 ("auto", the only value the
    /// measured oracle LYING.WS/LYING.pcl carries — see `styleLeadPt` in PDFLayout.swift)
    /// or an explicit positive VMI count. `nil` means no style governs this block (or the
    /// style set no line height of its own): a consumer's pre-existing `.lh`/default
    /// leading is UNCHANGED — WS4/styleless docs must not shift. Register: leading bug
    /// fix, 2026-08-20. Port of Python's `core.Block.line_height_vmi`.
    public var lineHeightVMI: Int?
    /// The style's own font SIZE in points (its font triple's height word, /20.0 — the
    /// same 1/1440in VMI unit WSFORMAT.WS documents for a font's height word, "Font
    /// height in VMIs (1/1440ths)"), captured at the BLOCK level rather than read off a
    /// line's own spans: a blank physical line carries no spans, so leading for THAT line
    /// must still resolve to its style's own size. `nil` when the style set no font of
    /// its own. Port of Python's `core.Block.style_font_pt`.
    public var styleFontPt: Double?
    /// The style's own declared PALETTE INDEX (WSFORMAT's 16-colour CGA/EGA table, the
    /// same index space as an inline symmetric type-1 colour change -- `StyleRecord`'s
    /// own `colour`). `nil` when the style never set one (or none governs this block); 0
    /// is an EXPLICIT "Black", kept distinct from `nil` but merged nowhere -- see
    /// `effectiveSpanColour`, which treats both the same (colour 0 changes nothing under
    /// any known driver palette, so tagging it would only add noise, e.g. to RTF/HTML
    /// exports of every plain paragraph). Register C5: LJ6DTP's own "Section Heading
    /// Font" style declares colour 3 (50% gray under the LJ6DTP palette) -- a real WS7
    /// LaserJet halftone-screens that into the light, patterned look the paper shows,
    /// which solid-black bold sans (`styleAttrs`'s own bold, correctly merged) never
    /// reproduced alone. Port of Python's `core.Block.style_colour`.
    public var styleColour: Int?
    /// Provenance of a STRUCTURAL block (tasks #20/#21, the round-trip writer): `.ff` =
    /// a pagebreak made by a literal 0x0C in the byte stream (the writer re-emits the
    /// form feed); `.fi` = the synthetic `[insert: NAME]` paragraph `parseWS` fabricates
    /// for a `.fi` line (no source bytes of its own — the dot ledger re-emits the `.fi`
    /// line, so the writer skips this block). `nil` everywhere else, including
    /// dot-command pagebreaks (`.pa`), whose bytes are the dot line itself.
    public var origin: BlockOrigin?

    public init(
        kind: BlockKind = .para, lines: [Line] = [], heading: Int = 0,
        align: Alignment = .left, wrap: Bool = true,
        leftMargin: Double? = nil, rightMargin: Double? = nil, paraMargin: Double? = nil,
        leftMarginPyInt: Bool = false, rightMarginPyInt: Bool = false,
        tabStops: [Double]? = nil,
        columns: Int? = nil, columnGutter: Double? = nil, styleID: Int? = nil,
        styleName: String? = nil, styleAttrs: Style = [],
        lineHeightVMI: Int? = nil, styleFontPt: Double? = nil, styleColour: Int? = nil,
        origin: BlockOrigin? = nil
    ) {
        self.origin = origin
        self.tabStops = tabStops
        self.leftMargin = leftMargin
        self.rightMargin = rightMargin
        self.paraMargin = paraMargin
        self.leftMarginPyInt = leftMarginPyInt
        self.rightMarginPyInt = rightMarginPyInt
        self.columns = columns
        self.columnGutter = columnGutter
        self.styleID = styleID
        self.styleName = styleName
        self.styleAttrs = styleAttrs
        self.lineHeightVMI = lineHeightVMI
        self.styleFontPt = styleFontPt
        self.styleColour = styleColour
        self.kind = kind
        self.lines = lines
        self.heading = heading
        self.align = align
        self.wrap = wrap
    }
}

/// `Block.lines` with soft-wrapped runs joined back into logical lines — what
/// `Block.lines` itself WAS before ctrl-kd 2.0.0 stored physical lines. Direct port of
/// `core.merged_lines` (core.py).
///
/// Printed mode renders `block.lines` directly: a soft return is where WordStar broke
/// the line on paper, so the physical line IS the printed line (merging them was the
/// bug that printed thousand-column lines). Reflowing consumers (every Modern emitter)
/// call this instead: a soft break is just word wrap, so the continuation belongs to
/// the same logical line. The join rule is the one `parseWS` itself used when it merged
/// at parse time — a space in the wrapped line's trailing style, suppressed after an
/// existing space or a hyphenated break — so Modern output is byte-identical either
/// side of the 2.0.0 split.
/// Hard blank lines at the END of a block — the author's own paragraph spacing.
/// `mergedLines` emits interior blanks and buffers trailing ones away; Modern layouts
/// used to paper over the difference with a synthetic blank after EVERY block, which
/// invented spacing wherever a dot command split the block (ruling 2026-08-06: command
/// codes are invisible — only the author's blank lines make space). Soft blanks are
/// `.ls` filler and never count, same as in `mergedLines`. Port of
/// `core.trailing_blank_lines`.
public func trailingBlankLines(_ block: Block) -> Int {
    var n = 0
    for line in block.lines.reversed() {
        if !line.spans.isEmpty { break }
        if !line.soft { n += 1 }
    }
    return n
}

public func mergedLines(_ block: Block) -> [Line] {
    var out: [Line] = []
    var cur: Line? = nil
    // Hard blanks are emitted only BETWEEN content, never trailing. A block that ENDS
    // with the author's blank already gets a structural blank from the Modern layout,
    // and emitting both double-spaces every paragraph of a WS4 document ([52, 26] where
    // [54] is right). Buffering them until real content follows serves both shapes.
    var pendingBlanks = 0
    for line in block.lines {
        if line.spans.isEmpty {
            // A blank PHYSICAL line, and the two kinds mean different things.
            //
            // SOFT is `.ls` filler — typography, not a logical line of text, so reflow
            // drops it and lets the Modern layout do its own spacing.
            //
            // HARD is the author's own return, and it is the ONLY paragraph separation
            // a print stream has. Dropping it was correct only while blank lines still
            // delimited BLOCKS; once they became content (2026-08-03) a whole print
            // stream is one block, so "Modern emits its own blank between paragraphs"
            // fired exactly once for the entire document and every paragraph ran
            // together in the PDF.
            if !line.soft {
                if var c = cur {
                    // ctrl-kd round 10: this is one of THREE places a completed `cur`
                    // reaches `out` -- the other two (a normal non-blank hard line
                    // ending it, and end-of-block) both coalesce first; this one, a
                    // blank hard line cutting a logical line short, did not. A soft-
                    // wrapped run's own spans never get coalesced AT the physical-line
                    // seam (each physical line decodes independently, so two adjacent
                    // empty-style text spans either side of a wrap are the ordinary
                    // case), which is fine as long as SOME flush path catches up --
                    // this one didn't, leaving un-merged seam spans in the IR for any
                    // paragraph that wraps across several physical lines and is THEN
                    // immediately followed by a blank line.
                    c.spans = coalesceSpans(c.spans)
                    out.append(c)
                    cur = nil
                }
                pendingBlanks += 1
            }
            continue
        }
        if pendingBlanks > 0 {
            out.append(contentsOf: (0..<pendingBlanks).map { _ in Line(spans: []) })
            pendingBlanks = 0
        }
        if cur == nil {
            cur = Line(spans: line.spans)
        } else {
            // A soft-wrapped CONTINUATION carries WordStar's own re-emitted left
            // indent — a `.lm`/tab the program stamps onto every wrapped line, not
            // something the author typed. Printed renders it (it really is on the
            // paper); reflow must not, or the indent lands mid-paragraph.
            //
            // Round 15: Python strips this with bare `.strip()`/`.lstrip()` (no
            // argument), which is EVERY whitespace character Python's `str.isspace()`
            // recognises — tab included, since WordStar re-emits the wrapped line's
            // own indent as a type-9 tab sequence just as often as literal spaces
            // (found via the v7 corpus parity sweep: CLOCK.COM and 4 other printer/
            // driver-catalog files, whose tab-aligned continuation lines leaked a
            // literal `\t` into Modern output). The space-only check here predates
            // `Whitespace.swift`'s Python-faithful helpers; switched to them so this
            // site cannot drift from `splitLeadingIndent`'s own reading of "an
            // indent" again.
            var spans = line.spans
            while let f = spans.first, f.text.trimmed().isEmpty {
                spans.removeFirst()
            }
            if let f = spans.first {
                let stripped = f.text.trimmedLeading()
                if stripped != f.text {
                    // The font run travels with the styles: Python keeps `fontN` in the
                    // same frozenset it copies here, so a rebuilt span that dropped it
                    // ended the run at every wrap point (the modern HTML/RTF of six
                    // archive documents lost the tag on every continuation line).
                    spans[0] = Span(text: stripped, styles: f.styles, font: f.font)
                }
            }
            cur!.spans.append(contentsOf: spans)
        }
        if line.soft {
            let t = cur!.spans.last?.text ?? ""
            if !t.isEmpty, !t.hasSuffix(" "), !t.hasSuffix("-") {
                cur!.spans.append(Span(text: " ", styles: cur!.spans.last!.styles,
                                       font: cur!.spans.last!.font))
            }
            continue
        }
        cur!.spans = coalesceSpans(cur!.spans)
        out.append(cur!)
        cur = nil
    }
    if var cur {
        cur.spans = coalesceSpans(cur.spans)
        out.append(cur)
    }
    return out
}

// b33 N9 (Jon's ruling, 2026-08-26, field notes register row, mirrored from ctrl-kd
// 0750948): the typewriter double space after a sentence-ending '.', '?', or '!' --
// "convert to single space after a period ending a sentence" on Modern by default, kept
// verbatim on Printed/Native by default, either forced by the CLI flag. The field notes
// name '.' explicitly and don't rule '?'/'!' in or out; absent a narrower ruling this
// covers all three real sentence enders (the classic typing-class rule, and what
// "single-space convention" means to a reader) -- reported at delivery for Jon to
// narrow if he only meant the bare period. Port of ctrl-kd's `SENTENCE_END_CHARS`.
let sentenceEndChars: Set<Character> = [".", "?", "!"]

/// N9 'single' mode: collapse a run of 2+ literal spaces immediately after a
/// sentence-ending character down to exactly one space, carrying state ACROSS the
/// boundaries between consecutive text pieces -- so it is safe to call on a Line's own
/// per-span text (a style change can land inside the space run, or right at the
/// sentence-ending character) or on any other ordered sequence of text pieces that
/// concatenate into one line. A deliberately SIMPLE textual rule, no abbreviation
/// detection (Jon's ruling, "no cleverness"): `"e.g.  x"` collapses exactly like a
/// genuine sentence end, because the document doesn't carry the difference and neither
/// does this.
///
/// Returns a NEW array, same length; a piece whose text is unchanged is returned as the
/// SAME string (cheap no-op for the overwhelmingly common case of a piece with no space
/// run at all). Port of `sentence_spacing_texts`.
public func sentenceSpacingTexts(_ texts: [String]) -> [String] {
    var out: [String] = []
    out.reserveCapacity(texts.count)
    var afterEnd = false      // last non-space character seen was . ? or !
    var seenSpace = false     // already kept ONE space in the run since then
    for t in texts {
        var changed = false
        var chars: [Character] = []
        chars.reserveCapacity(t.count)
        for ch in t {
            if ch == " " {
                if afterEnd {
                    if seenSpace {
                        changed = true
                        continue          // drop: 2nd+ space in the run
                    }
                    seenSpace = true
                }
                chars.append(ch)
            } else {
                chars.append(ch)
                afterEnd = sentenceEndChars.contains(ch)
                seenSpace = false
            }
        }
        out.append(changed ? String(chars) : t)
    }
    return out
}

/// The N9 mode-aware default (Jon's ruling): `.auto` -> single on Modern, keep on
/// Printed/Native -- keyed on the EFFECTIVE printed-ness (a print stream/ruler-line
/// document renders printed even under a `modern` mode request), not the raw mode, so a
/// forced-printed document gets the Printed default it actually renders as. `.keep`/
/// `.single` (the flag) override in either direction regardless of mode. Returns the
/// resolved boolean (`.single` is `true`) every emitter's own span-to-output step
/// consults. Port of `resolve_sentence_spacing`.
public func resolveSentenceSpacing(_ value: EmitOptions.SentenceSpacingMode, printed: Bool) -> Bool {
    switch value {
    case .auto: return !printed
    case .keep: return false
    case .single: return true
    }
}

/// `sentenceSpacingTexts` applied to a list of Spans, every other field preserved -- the
/// common case every emitter's own span-to-output step calls. Cross-span joints are
/// handled (state carries across spans in the same call), so this is safe to call on a
/// whole Line's `.spans` regardless of where a style boundary happens to fall relative
/// to a sentence-ending character or its following spaces. Port of
/// `sentence_spacing_spans`.
public func sentenceSpacingSpans(_ spans: [Span]) -> [Span] {
    let texts = sentenceSpacingTexts(spans.map(\.text))
    return zip(spans, texts).map { sp, t in
        guard t != sp.text else { return sp }
        var out = sp
        out.text = t
        return out
    }
}
