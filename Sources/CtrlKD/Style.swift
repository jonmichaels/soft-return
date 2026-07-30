/// Inline styles a `Span` can carry, plus the `fnref` marker for footnote references.
///
/// Mirrors the Python IR's `frozenset` of style strings (`b i u sup sub strike fnref`).
/// Modeled as an `OptionSet` rather than `Set<Style>`: Python toggles styles with
/// `active.add`/`active.remove` against a small fixed vocabulary, which is exactly
/// what OptionSet's bitmask union/subtract/contains give for free, without hashing
/// overhead or heap allocation for every span.
public struct Style: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold      = Style(rawValue: 1 << 0)
    public static let italic    = Style(rawValue: 1 << 1)
    public static let underline = Style(rawValue: 1 << 2)
    public static let sup       = Style(rawValue: 1 << 3)
    public static let sub       = Style(rawValue: 1 << 4)
    public static let strike    = Style(rawValue: 1 << 5)
    public static let fnref     = Style(rawValue: 1 << 6)
}
