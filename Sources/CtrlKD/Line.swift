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

    /// True when this line ends in a BARE CR — `^PM` Overprint Line (WSFORMAT and the
    /// WS4 manual agree): the NEXT line prints at THIS line's own baseline, additively —
    /// LJ6DTP's white-on-black knockouts and strikeover composites both work this way.
    /// Printed renderers re-use the y; reflow modes treat it as a plain break (the field
    /// is simply never consulted there).
    public var overprint: Bool

    /// The line height IN FORCE ON THIS LINE, in `.lh`'s own 1/48in units — `nil` meaning
    /// "the document's own default" (`Document.page?.lh48`), which is the overwhelmingly
    /// common case and keeps the field free for every file that never changes leading.
    ///
    /// `.lh` is STATEFUL: it applies from where it appears onward, exactly like `.oc`/`.lm`,
    /// and real documents switch it constantly (one archive file alternates `.lh10pt` and
    /// `.lh16pt` around its banner headings). The page geometry's `lh48` is the FIRST
    /// occurrence — one resolved answer per document, which is what a consumer needs for a
    /// default and for `--diagnose` — and resolving ONLY that stacked 72pt banners on a
    /// single 14pt lead, which is the bug this field exists to fix. Register C24.
    ///
    /// A LEAD IS THE SPACE ABOVE ITS LINE, not below it: `.lh` is a printer VMI, set before
    /// the feed that lands on the line it was typed for. See `pageStream` for the archive
    /// document that measures it.
    public var lead48: Double?

    public init(spans: [Span] = [], soft: Bool = false, softpage: Bool = false,
                lead48: Double? = nil, overprint: Bool = false) {
        self.spans = spans
        self.soft = soft
        self.softpage = softpage
        self.lead48 = lead48
        self.overprint = overprint
    }

    /// All span text joined, e.g. for search or format-agnostic display.
    public func text() -> String {
        spans.map(\.text).joined()
    }
}
