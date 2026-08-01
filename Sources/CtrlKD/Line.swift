/// One PHYSICAL line within a `Block` — exactly what sat on one printed line (ctrl-kd
/// 2.0.0; core.py's `Line` dataclass). Before 2.0.0, word wrap was joined into one
/// logical `Line` at parse time; printed mode could not undo that, so soft-wrapped
/// paragraphs rendered as single thousand-column lines running off the page edge.
/// `soft` now marks WordStar's own word wrap so a consumer can tell a real page break
/// from a mere wrap point; call `mergedLines(_:)` (Block.swift) to get logical lines
/// back for reflowing.
public struct Line: Hashable, Sendable {
    public var spans: [Span]
    /// True when this line ends in WordStar's own word wrap (an 8D 0A soft return
    /// classified `wrap` by `linesPass`): ON PAPER this was a real line break; for
    /// reflow it joins the next line (see `mergedLines(_:)`).
    public var soft: Bool

    public init(spans: [Span] = [], soft: Bool = false) {
        self.spans = spans
        self.soft = soft
    }

    /// All span text joined, e.g. for search or format-agnostic display.
    public func text() -> String {
        spans.map(\.text).joined()
    }
}
