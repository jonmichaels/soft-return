/// One deliberate line break within a `Block` — word wrap has already been
/// joined by the time a `Line` exists; only the author's own line breaks remain.
public struct Line: Hashable, Sendable {
    public var spans: [Span]

    public init(spans: [Span] = []) {
        self.spans = spans
    }

    /// All span text joined, e.g. for search or format-agnostic display.
    public func text() -> String {
        spans.map(\.text).joined()
    }
}
