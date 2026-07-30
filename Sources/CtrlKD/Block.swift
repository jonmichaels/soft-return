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
