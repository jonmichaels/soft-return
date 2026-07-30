/// The top-level IR: a parsed document as blocks, footnotes, and parse diagnostics.
///
/// The Python side's `meta` is a single heterogeneous dict — `parse_ws`/
/// `parse_printstream` pour `detect()`'s result plus their own diagnostics
/// (`margin_estimate`, `dot_commands`, `unknown_codes`, `columnar`) into it, because a
/// dict is Python's path of least resistance for "several parse passes each add a
/// little state." Once every field parse_ws actually writes is known (core.py:255-325),
/// that heterogeneity buys nothing in Swift — it only costs every reader a downcast.
/// So `meta` is gone; each field below is what it actually held, typed.
public struct Document: Hashable, Sendable {
    public var blocks: [Block]
    /// Numbered 1..n; referenced from the text via `Style.fnref` spans.
    public var footnotes: [[Span]]
    /// The `detect()` result this document was parsed as. `nil` only for documents
    /// built by hand (tests, fixtures) rather than through `parseWS`/`parsePrintstream`.
    public var detection: Detection?
    /// 90th-percentile wrap margin `linesPass` computed (core.py:267). `nil` for
    /// `parsePrintstream`, which never runs the wrap test — every line there is kept
    /// verbatim (core.py:339).
    public var marginEstimate: Int?
    /// Raw text of every dot-command line encountered (`.pa`, `.r!`, etc.), in order.
    public var dotCommands: [String]
    /// Control bytes below 0x20 (or 0x7F) that `_decode_spans` didn't recognize,
    /// counted by raw byte value rather than Python's `"0x07"`-formatted string key —
    /// hex formatting is a `--diagnose`-output concern, not part of the type.
    public var unknownCodes: [UInt8: Int]
    /// Whether a `.r!` ruler line (or a printstream, which is columnar by definition)
    /// was seen — signals the source used fixed-width column layout.
    public var columnar: Bool

    public init(
        blocks: [Block] = [],
        footnotes: [[Span]] = [],
        detection: Detection? = nil,
        marginEstimate: Int? = nil,
        dotCommands: [String] = [],
        unknownCodes: [UInt8: Int] = [:],
        columnar: Bool = false
    ) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.detection = detection
        self.marginEstimate = marginEstimate
        self.dotCommands = dotCommands
        self.unknownCodes = unknownCodes
        self.columnar = columnar
    }

    public func iterLines() -> [Line] {
        blocks.flatMap(\.lines)
    }
}
