/// What kind of content a `Block` holds.
public enum BlockKind: String, Hashable, Sendable {
    /// Ordinary content.
    case para
    /// An explicit page break (`.pa` dot command / form feed).
    case pagebreak
    /// WordStar's own pagination — render only in printed mode.
    case softpage
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
    /// `.co <n>, <gutter>` — newspaper columns in force when this block opened, and the
    /// gutter between them in print columns. `nil` means the file never asked, which is
    /// not the same as asking for one column. Register C5.
    public var columns: Int?
    public var columnGutter: Double?
    /// WordStar's paragraph-style ID (symmetric type 0x11), when one was applied.
    /// `heading` is the subset this parser gives a heading meaning to (1-3); every OTHER
    /// style used to be dropped silently, so a styled paragraph became an unstyled one
    /// with no trace. The archive uses at least twelve distinct IDs. Register C1.
    public var styleID: Int?

    public init(
        kind: BlockKind = .para, lines: [Line] = [], heading: Int = 0,
        align: Alignment = .left, wrap: Bool = true,
        leftMargin: Double? = nil, rightMargin: Double? = nil, paraMargin: Double? = nil,
        columns: Int? = nil, columnGutter: Double? = nil, styleID: Int? = nil
    ) {
        self.leftMargin = leftMargin
        self.rightMargin = rightMargin
        self.paraMargin = paraMargin
        self.columns = columns
        self.columnGutter = columnGutter
        self.styleID = styleID
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
                if let c = cur {
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
            var spans = line.spans
            while let f = spans.first, f.text.allSatisfy({ $0 == " " }), !f.text.isEmpty {
                spans.removeFirst()
            }
            if let f = spans.first {
                let stripped = String(f.text.drop(while: { $0 == " " }))
                if stripped != f.text {
                    spans[0] = Span(text: stripped, styles: f.styles)
                }
            }
            cur!.spans.append(contentsOf: spans)
        }
        if line.soft {
            let t = cur!.spans.last?.text ?? ""
            if !t.isEmpty, !t.hasSuffix(" "), !t.hasSuffix("-") {
                cur!.spans.append(Span(text: " ", styles: cur!.spans.last!.styles))
            }
            continue
        }
        out.append(cur!)
        cur = nil
    }
    if let cur {
        out.append(cur)
    }
    return out
}
