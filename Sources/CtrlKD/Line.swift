/// One byte restoration for the round-trip writer (tasks #20/#21): at line offset
/// `offset` (SOURCE byte space) the writer's re-encode emits `expected`; the file had
/// `original`. Guarded at apply time — see `Line.fixups`.
public struct Fixup: Hashable, Sendable {
    public var offset: Int
    public var expected: [UInt8]
    public var original: [UInt8]

    public init(offset: Int, expected: [UInt8], original: [UInt8]) {
        self.offset = offset
        self.expected = expected
        self.original = original
    }
}

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

    /// `.KR` in force AS THIS LINE ENDS — STATEFUL like `.lh` above, captured the same
    /// way (`closeLine()` reads the running format state, `true` being WordStar's own
    /// default, per LJ6DTP's own prose "when kerning is on, which is the default").
    /// Register C7: LJ6DTP's page 2 types the identical ``` `` ```/`''` pair twice, once
    /// under `.kr off` and once under `.kr on`, specifically to demonstrate that the pair
    /// only reads as a proper curly DOUBLE quote when kerned — `ljSubstitute` is the
    /// consumer.
    public var kerning: Bool

    /// The `.po` (page offset / left origin) IN FORCE ON THIS LINE, in `.po`'s own print
    /// columns — `nil` meaning "the document's own default" (`Document.page?.poCols`),
    /// same "absolute here, `nil` once the document default is known" contract as
    /// `lead48` above. `.po` is STATEFUL exactly like `.lh`/`.kr`: real documents move it
    /// mid-file (LJ6DTP.WS sets it five times — its ordinary .7in body margin, then 2.5"
    /// for page 4's racing-stripe checkerboard, then back), and the page geometry's
    /// `poCols` is the FIRST occurrence — one resolved answer per document, which is what
    /// a consumer needs for a default and for `--diagnose` — and resolving ONLY that
    /// anchored every line, checkerboard included, at the document's own .7in body
    /// margin, 2.05in left of real WordStar 7 output. Register b31.
    public var poCols: Double?

    /// The `.sr` sub/superscript roll IN FORCE ON THIS LINE, in 1/48in units (WordStar's
    /// own unit for the command) — STATEFUL exactly like `lead48`/`poCols` above
    /// (register b32-N10, mirrored from ctrl-kd b48148c): a sub/superscript roll re-fires
    /// from where it sits onward, and the Printed renderer used to read ONE document-wide
    /// value (`Document.formatting.subSuperRoll48`) regardless of a line's own position
    /// relative to the `.sr` that set it — the same disease register b31's E3 sweep found
    /// and fixed for `.pl`/`.hm`/`.fm`/`.pn`. A private WS7 specimen isolated it: a superscript that
    /// is a line's LAST span, with a LATER `.sr` in the same document, rendered at the
    /// wrong position because every span in the whole document — including ones that
    /// printed before the `.sr` line was ever reached — shared that one late-document
    /// value.
    ///
    /// Unlike `lead48`/`poCols`, this field is always the RESOLVED ABSOLUTE value (never
    /// back-dated to `nil` for "agrees with the document default"): `.sr` has no
    /// competing style/font precedence chain to fall back through, so there is nothing an
    /// emitter needs a `nil` sentinel to defer to — every line's own value is already
    /// complete and correct on its own, from the document's very first line (the WSFORMAT
    /// default, 3/48in) onward. `Document.formatting.subSuperRoll48` (the document-WIDE
    /// last-occurrence snapshot) is untouched by this field and keeps its own existing
    /// consumers (Printed RTF's `\up`/`\dn`, `--diagnose`) — their own statefulness is a
    /// separate, not-yet-scoped item.
    public var roll48: Double?

    /// RAW SOURCE bytes of the separator that ended this physical line (tasks #20/#21,
    /// the round-trip writer). `soft`/`overprint` collapse the byte-level variants — a
    /// WS7 soft return after an end-of-page block is `<8D 8A>`, both bytes flagged
    /// (measured 2026-08-04), and a hard CR can be followed by a flagged LF `<0D 8A>` —
    /// so the writer needs the bytes themselves, not the classification. `nil` = not
    /// parsed from a file (a synthetically built Line); the writer then infers from the
    /// flags.
    public var brkRaw: [UInt8]?
    /// Trailing style-toggle run (tasks #20/#21): the verbatim toggle bytes that sat
    /// between this line's last text byte and its separator. `decodeSpans` folds them
    /// into the running style state — the NEXT line's spans carry the style — so
    /// without this the writer re-emits them at the head of the following line, and the
    /// corpus shows WordStar overwhelmingly writes them before the break (40+ archive
    /// documents diverged on exactly `02 0d 0a`).
    public var togEnd: [UInt8]
    /// Byte restorations for this line (tasks #20/#21), in ascending offset order,
    /// offsets in the line's own SOURCE byte space. Each records one place the decode
    /// collapsed bytes irreversibly — 0x0F binding space to ' ', ^D doublestrike to the
    /// same bold tag as ^B, a dropped control, a WS4 flag bit, a bare high byte the
    /// writer would re-wrap as a triple. The writer re-encodes the spans, then patches
    /// `expected` back to `original` where the emission matches — so edited text
    /// degrades gracefully (guard fails, no patch) instead of corrupting. See
    /// `rtLineCapture` for the capture rules.
    public var fixups: [Fixup]

    public init(spans: [Span] = [], soft: Bool = false, softpage: Bool = false,
                lead48: Double? = nil, overprint: Bool = false,
                brkRaw: [UInt8]? = nil, togEnd: [UInt8] = [], fixups: [Fixup] = [],
                kerning: Bool = true, poCols: Double? = nil, roll48: Double? = nil) {
        self.spans = spans
        self.soft = soft
        self.softpage = softpage
        self.lead48 = lead48
        self.kerning = kerning
        self.overprint = overprint
        self.brkRaw = brkRaw
        self.togEnd = togEnd
        self.fixups = fixups
        self.poCols = poCols
        self.roll48 = roll48
    }

    /// All span text joined, e.g. for search or format-agnostic display.
    public func text() -> String {
        spans.map(\.text).joined()
    }
}
