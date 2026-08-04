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
    /// A 0x0B end-of-page mark fell at this line — the EDITOR's last-seen pagination.
    ///
    /// WSFORMAT.TXT on 0Bh End of page: "This sequence should usually be ignored. It's
    /// used by the WordStar editor to keep track of page breaks. It is TRANSIENT, and
    /// moves around with the page break." MEASURED on WordStar 7 (2026-08-04): the same
    /// document printed with and without 0x0B marks produced BYTE-IDENTICAL output — the
    /// print pipeline never reads them.
    ///
    /// Recorded for viewers that want the editor's last-seen pagination; NEVER a page
    /// break, and never a block split. Honouring these as breaks changed the page count
    /// of 43 archive documents (OLDTIMES.WS printed 15 pages instead of 10), and the
    /// mark also SEVERED real paragraphs — the editor drops one wherever the page
    /// currently ends, including mid-paragraph.
    public var softpage: Bool

    public init(spans: [Span] = [], soft: Bool = false, softpage: Bool = false) {
        self.spans = spans
        self.soft = soft
        self.softpage = softpage
    }

    /// All span text joined, e.g. for search or format-agnostic display.
    public func text() -> String {
        spans.map(\.text).joined()
    }
}
