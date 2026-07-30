/// The top-level IR: a parsed document as blocks, footnotes, and detection metadata.
public struct Document: Hashable, Sendable {
    public var blocks: [Block]
    /// Numbered 1..n; referenced from the text via `Style.fnref` spans.
    public var footnotes: [[Span]]
    /// Detection + parse diagnostics (e.g. `variant`, `margin_estimate`, `dot_commands`).
    ///
    /// The Python side's `meta` is a heterogeneous dict (strings, ints, bools, nested
    /// dicts/lists) because `detect()`/`lines_pass()` stuff varied diagnostic shapes into
    /// it. Ported here as `[String: String]` since only the four IR types are in scope
    /// for this job — revisit the value type once `detect()`/`parse_ws()` are ported and
    /// we know what actually needs to round-trip.
    public var meta: [String: String]

    public init(blocks: [Block] = [], footnotes: [[Span]] = [], meta: [String: String] = [:]) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.meta = meta
    }

    public func iterLines() -> [Line] {
        blocks.flatMap(\.lines)
    }
}
