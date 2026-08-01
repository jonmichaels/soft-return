/// What kind of content a `Block` holds.
public enum BlockKind: String, Hashable, Sendable {
    /// Ordinary content.
    case para
    /// An explicit page break (`.pa` dot command / form feed).
    case pagebreak
    /// WordStar's own pagination — render only in printed mode.
    case softpage
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
    public var heading: Int

    public init(kind: BlockKind = .para, lines: [Line] = [], heading: Int = 0) {
        self.kind = kind
        self.lines = lines
        self.heading = heading
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
    for line in block.lines {
        if cur == nil {
            cur = Line(spans: line.spans)
        } else {
            cur!.spans.append(contentsOf: line.spans)
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
