/// One footnote/endnote/annotation/comment: WordStar 7.0 symmetrical sequence types 3-6
/// (WordStar International, 1992). Direct port of the Python `Note` dataclass
/// (core.py, "Parse all four WordStar note kinds correctly"). All four share one block
/// layout (line-count word, tag/number word, conversion-flag byte, text) so one model
/// covers them; `kind` is what lets callers tell them apart.
public enum NoteKind: String, Hashable, Sendable {
    case footnote
    case endnote
    case annotation
    case comment
}

/// Where a note came from (ruling 2026-08-06 M9: both WordStar comment forms unify into
/// `Note(kind: .comment)`; origin is the provenance that explains an odd-looking entry —
/// a commented-out `..rm 60` is still a comment). `block` is a real ^ON/^FN symmetrical
/// sequence; the other two are the dot-line comment syntaxes.
public enum NoteOrigin: String, Hashable, Sendable {
    case block
    case dotDot = ".."
    case dotIG = ".ig"
}

/// See `NoteKind` for the shared layout this decodes. Field-by-field provenance is in
/// `SymmetricBlocks.swift`'s `parseNote`, which is the direct port of Python's
/// `_parse_note`.
public struct Note: Hashable, Sendable {
    public var kind: NoteKind
    public var text: String
    /// Footnote/endnote only: the file's own (0-based) note number. `nil` for
    /// annotations/comments, which have no numeric identity in the spec — annotations
    /// carry `tag` instead, comments carry neither.
    public var number: Int?
    /// Annotations only: the nested tag sequence's display TEXT (e.g. `"AC1"`).
    /// Footnote/endnote carry a number instead; comments carry neither.
    public var tag: String?
    /// WordStar's own stored text height — cheap pagination hint.
    public var lineCount: Int
    /// Conversion-flag high nybble: 0 symbols, 1 upper, 2 lower, 3 numeric. Meaningless
    /// for annotations (spec: "not used"), left 0 there rather than reporting noise.
    public var numberFormat: Int
    /// Conversion-flag low nybble: 0 = none, else the target note type if converted.
    /// Same annotation caveat as `numberFormat`.
    public var convertTo: Int
    /// The note's OWN dot-command lines (a ruler or comment can live inside a note's
    /// text same as the body) — stripped from `text` but preserved verbatim, in order.
    public var dotCommands: [String]
    /// Source byte offset of this block's opening `0x1D` (0 for dot-line comments, which
    /// have no block — their stable anchor is `Document.dotPositions`).
    public var offset: Int
    /// Where this note came from — see `NoteOrigin` (ruling 2026-08-06 M9).
    public var origin: NoteOrigin

    public init(
        kind: NoteKind,
        text: String = "",
        number: Int? = nil,
        tag: String? = nil,
        lineCount: Int = 0,
        numberFormat: Int = 0,
        convertTo: Int = 0,
        dotCommands: [String] = [],
        offset: Int = 0,
        origin: NoteOrigin = .block
    ) {
        self.kind = kind
        self.text = text
        self.number = number
        self.tag = tag
        self.lineCount = lineCount
        self.numberFormat = numberFormat
        self.convertTo = convertTo
        self.dotCommands = dotCommands
        self.offset = offset
        self.origin = origin
    }
}

/// Where in the document one dot command sat: the index of the block it precedes and how
/// many lines that block already held. The coarsest anchor that is actually STABLE — it
/// survives reflow, which a byte offset does not — so a consumer that wants to SHOW a
/// dot command in place (Soft Return.app's Show Invisibles) has one. Python's
/// `meta['dot_positions']` entries.
public struct DotPosition: Hashable, Sendable {
    public var blockIndex: Int
    public var lineIndex: Int
    public var text: String

    public init(blockIndex: Int, lineIndex: Int, text: String) {
        self.blockIndex = blockIndex
        self.lineIndex = lineIndex
        self.text = text
    }
}

/// A symmetrical sequence whose type we don't interpret: kept verbatim (bytes + source
/// offset) instead of being silently dropped, per the project rule to preserve what
/// isn't understood — so `--diagnose` can report it instead of going quiet. `cmd` is
/// `Int`, not `UInt8`: Python's `-1` sentinel (a block too short to even contain a
/// command byte) is a real, distinct case worth keeping rather than coercing into 0-255.
public struct UnknownBlock: Hashable, Sendable {
    public var cmd: Int
    public var bytes: [UInt8]
    public var offset: Int

    public init(cmd: Int, bytes: [UInt8], offset: Int) {
        self.cmd = cmd
        self.bytes = bytes
        self.offset = offset
    }
}

/// Whether a resolved page-geometry figure came from the file itself or is this
/// project's documented default. A consumer needs to be able to tell "Legal, because
/// the file said so" from "Letter, because nothing said otherwise" — provenance lives
/// alongside every resolved figure, not just the page size.
public enum Provenance: String, Hashable, Sendable {
    case file
    case `default`
}

/// `.pl`/`.po`/`.mt`/`.mb`/`.hm`/`.fm`/`.lh`/`.ls`/`.cw` resolved, with provenance. Direct
/// port of `parse_ws`'s `doc.meta['page']` dict (core.py, "Page geometry, period-authentic
/// footnote layout, and note-aware export"; ctrl-kd 1.3.0 added `.hm`/`.fm`/`.lh`/`.ls`
/// and the derived `text_lines`; 2.0.0 added `.cw` and changed `.po`'s default — see
/// `cwSource`/`ParseWS.swift`'s `defaultPoCols`). Unit-less dot-command arguments are
/// LINES (columns for `.po`; 1/48in units for `.lh`; 1/120in units for `.cw`), never
/// inches — see `ParseWS.swift`'s page-geometry section for the full trap writeup and
/// the named-size snap tolerance.
///
/// `.hm`/`.fm` (header/footer margin, in lines) and `.ls` (line spacing, a small integer
/// count) are recorded with provenance for `--diagnose` only — see `ParseWS.swift`'s
/// `textLinesPerPage` for why neither one ever enters the capacity formula. `lh48` is
/// `.lh`'s argument in 1/48in units (WordStar's own unit for this command); `textLines`
/// is the one derived figure a caller actually needs: printed text lines per page, from
/// `pl_lines`/`mt_lines`/`mb_lines`/`lh_48` via WordStar's own vertical model — see
/// `textLinesPerPage` for the formula and the manual quotations behind it.
public struct PageGeometry: Hashable, Sendable {
    public var plLines: Double
    public var heightIn: Double
    public var sizeName: String
    /// Physical page WIDTH in inches — INFERRED from the height (there is no dot
    /// command for width; ruled 2026-08-06, "the 3 main page sizes"): A4-tall pages
    /// are 210mm (8.268in) wide, everything else is the 8.5in American sheet. Its
    /// provenance is therefore the size's provenance (`sizeSource`).
    public var pwIn: Double
    public var sizeSource: Provenance
    public var mtLines: Double
    public var mtSource: Provenance
    public var mbLines: Double
    public var mbSource: Provenance
    public var poCols: Double
    public var poSource: Provenance
    public var hmLines: Double
    public var hmSource: Provenance
    public var fmLines: Double
    public var fmSource: Provenance
    public var lh48: Double
    public var lhSource: Provenance
    public var ls: Double
    public var lsSource: Provenance
    /// Character width, 1/120in units (ctrl-kd 2.0.0's `.cw`) — 12 is 10 CPI, the
    /// default. Positions printed text at `poCols * cw120` from the paper edge and sets
    /// its type size (see `PDFLayout.swift`'s `printedSize`/`printedLeft`).
    public var cw120: Double
    public var cwSource: Provenance
    /// Printed text lines per page — derived, not independently settable: `parseWS`
    /// computes this via `textLinesPerPage(pl:mt:mb:lh48:)` from the four fields above and
    /// passes the result in here, matching Python's `doc.meta['page']['text_lines']`
    /// being set once, after the rest of the page dict is assembled.
    public var textLines: Int
    /// `.pn n` — the number of the page it appears on, so a chapter file in a larger
    /// manuscript can start where the previous one stopped rather than always at 1.
    /// MEASURED on WordStar 4 (2026-08-03): `.pn 7` numbers the pages 7, 8, 9 in both
    /// the header's `#` and the footer's. Defaults to 1.
    public var pnStart: Int
    public var pnSource: Provenance
    /// `.pc n` — the column of the AUTOMATIC page number, the one WordStar prints on
    /// its own. Measured: it does NOT move a `#` placed inside a header or footer,
    /// which prints where the author put it. Two separate mechanisms, and conflating
    /// them was the bug this field exists to keep apart. `nil` when unset.
    public var pcCol: Int?
    public var pcSource: Provenance
    /// True when ANY line's `.lh` differs from `lh48` above — one flag so a consumer can
    /// say "this document changes its leading" without walking every line.
    ///
    /// `.lh` is STATEFUL (register C24): it applies from where it appears, so `lh48` is the
    /// document DEFAULT (the file's first occurrence, which is also what page capacity is
    /// computed at) and `Line.lead48` carries the rest. The archive's banner document
    /// switches leading fifteen times.
    public var lhVaries: Bool

    public init(
        plLines: Double,
        heightIn: Double,
        sizeName: String,
        pwIn: Double = 8.5,
        sizeSource: Provenance,
        mtLines: Double,
        mtSource: Provenance,
        mbLines: Double,
        mbSource: Provenance,
        poCols: Double,
        poSource: Provenance,
        hmLines: Double,
        hmSource: Provenance,
        fmLines: Double,
        fmSource: Provenance,
        lh48: Double,
        lhSource: Provenance,
        ls: Double,
        lsSource: Provenance,
        cw120: Double,
        cwSource: Provenance,
        textLines: Int,
        pnStart: Int = 1,
        pnSource: Provenance = .default,
        pcCol: Int? = nil,
        pcSource: Provenance = .default,
        lhVaries: Bool = false
    ) {
        self.plLines = plLines
        self.heightIn = heightIn
        self.sizeName = sizeName
        self.pwIn = pwIn
        self.sizeSource = sizeSource
        self.mtLines = mtLines
        self.mtSource = mtSource
        self.mbLines = mbLines
        self.mbSource = mbSource
        self.poCols = poCols
        self.poSource = poSource
        self.hmLines = hmLines
        self.hmSource = hmSource
        self.fmLines = fmLines
        self.fmSource = fmSource
        self.lh48 = lh48
        self.lhSource = lhSource
        self.ls = ls
        self.lsSource = lsSource
        self.cw120 = cw120
        self.cwSource = cwSource
        self.textLines = textLines
        self.pnStart = pnStart
        self.pnSource = pnSource
        self.pcCol = pcCol
        self.pcSource = pcSource
        self.lhVaries = lhVaries
    }
}

/// Whether a `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` event sets a header or a footer line.
public enum HFKind: Hashable, Sendable {
    case header
    case footer
}

/// One `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, IN DOCUMENT ORDER, with the block it
/// precedes. WordStar applies a running head/foot from the PAGE where it is defined — on
/// that page itself only if no text has printed there yet, else from the next page.
/// `Document.headers`/`.footers` (the FINAL state) cannot express that: a manuscript that
/// defines its head after page 1's title block gets no running head on page 1, which the
/// final-state dicts alone cannot distinguish from "defined from the very start." The
/// paginator replays these events instead — see `PDFLayout.swift`'s `Page`.
public struct HFEvent: Hashable, Sendable {
    public var kind: HFKind
    /// 1-5 — `.he`/`.fo` are line 1, the numbered forms select their own.
    public var line: Int
    /// The text as `parseHeadFoot` decoded it (an empty string CLEARS that line).
    public var text: String
    /// The index into `Document.blocks` this event precedes: the block still open (if it
    /// has content) or the next one to open. Mirrors the `blockIndex`/`pointsAt` convention
    /// `parseCollectDot` already uses for TOC/index entries.
    public var blockAnchor: Int

    public init(kind: HFKind, line: Int, text: String, blockAnchor: Int) {
        self.kind = kind
        self.line = line
        self.text = text
        self.blockAnchor = blockAnchor
    }
}

/// COMMENT.BUG: a documented WordStar bug (Sawyer, WS archive REF notes, 2013) — see
/// `ParsePrintstream.swift`'s `detectCommentBug` for the full writeup. Detection is
/// necessarily a heuristic; read this as "this signature is present", not "this file
/// definitely hit the bug".
public struct CommentBug: Hashable, Sendable {
    public var count: Int
    public var firstOffset: Int
    public var strayControlT: Bool

    public init(count: Int, firstOffset: Int, strayControlT: Bool) {
        self.count = count
        self.firstOffset = firstOffset
        self.strayControlT = strayControlT
    }
}

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
    /// Where each dot command sat — parallel in order to `dotCommands`, but anchored.
    /// See `DotPosition`. Python's `meta['dot_positions']`.
    public var dotPositions: [DotPosition]
    /// Control bytes below 0x20 (or 0x7F) that `_decode_spans` didn't recognize,
    /// counted by raw byte value rather than Python's `"0x07"`-formatted string key —
    /// hex formatting is a `--diagnose`-output concern, not part of the type.
    public var unknownCodes: [UInt8: Int]
    /// Whether a `.r!` ruler line (or a printstream, which is columnar by definition)
    /// was seen — signals the source used fixed-width column layout.
    public var columnar: Bool
    /// ALL notes (footnotes/endnotes/annotations/comments), in document order: the
    /// authoritative structure. `footnotes` above is a convenience view over this (kept
    /// for the existing emitters, which only know how to render one flattened,
    /// numbered list) — this is what tells the four kinds apart. WS5+ only; empty for
    /// WS4 and printstream documents.
    public var notes: [Note]
    /// Symmetrical-sequence types this parser doesn't interpret, preserved verbatim
    /// rather than dropped. WS5+ only.
    public var unknownBlocks: [UnknownBlock]
    /// `.pl`/`.po`/`.mt`/`.mb` resolved, with provenance. Set by `parseWS` regardless of
    /// variant (WS4 or WS5+) since page geometry is a dot-command concern, not a
    /// symmetric-block one; `nil` for `parsePrintstream`, which has no dot commands to
    /// read (a print-to-disk capture already IS the printed page).
    public var page: PageGeometry?
    /// `"wordtsar"` when `.PT`/`.PSA`/`.PSB` were seen — these are WordTsar's own
    /// invented dot commands, never written by real WordStar, so their mere presence is
    /// a producer signal. This is provenance, not format: `detection.variant` stays
    /// whatever the actual encoding is.
    public var producer: String?
    /// `.F#`'s numeric argument, when present. Footnotes and endnotes number
    /// independently, so this and `endnoteNumberStart` are separate fields.
    public var footnoteNumberStart: Int?
    /// `.E#`'s numeric argument, when present.
    public var endnoteNumberStart: Int?
    /// Set only by `parsePrintstream`, when the COMMENT.BUG signature (a line ending in
    /// a bare `0x0A` instead of `0x0D 0x0A`) is present.
    public var commentBug: CommentBug?
    /// Running head text by line number (1-5). `.he` is line 1; `.h1`-`.h5` select
    /// their own, so a document can carry up to five.
    ///
    /// Added 2026-08-03: these are fully-documented dot commands that had NO field
    /// anywhere in the IR, so their text was captured only in the `dotCommands`
    /// diagnostic and silently discarded by every emitter — the reserved SPACE was
    /// honoured, the content was not. A running title or a "Page #" line vanished from
    /// every page with no indication it had ever existed.
    ///
    /// Geometry, MEASURED on WordStar 4 (2026-08-03) rather than inferred:
    ///
    ///     line 1        header text          (.he / .h1-.h5)
    ///     .hm lines     blank                (default 2)
    ///     .pl-.mt-.mb   body                 (55 at the defaults)
    ///     .fm lines     blank                (default 2)
    ///     1 line        footer text          (.fo / .f1-.f5)
    ///     remainder     blank                (to fill .mb)
    ///
    /// so `.mt 3` == header + `.hm 2`, and `.mb 8` == `.fm 2` + footer + 5.
    ///
    /// An empty string is a real value, not an absence: an empty argument CLEARS that
    /// line, which is how WordStar turns a running head off part-way through.
    /// What the file asked for that is neither page geometry nor per-block: `.ul`,
    /// `.sb`, `.ps`, `.kr`, `.pr`, `.sr`. Only keys the file actually set are non-nil.
    /// Register C8, C18-C22.
    /// INSET picture paths, in document order — one per `[image: NAME]` placeholder in
    /// the text. A converter cannot render a 1987 `.PIX`, but recording the path means a
    /// consumer can find the file, and the placeholder means the reader can see that a
    /// figure belongs there. Register C10.
    public var graphics: [String]
    /// Colour changes (type 0x01): palette indices, not RGB. Register C2.
    public var colours: [ColourChange]
    /// Font changes (type 0x02/0x15). Size is 1/20 point. Register C3.
    public var fonts: [FontChange]
    /// Files the printer was told to pull in (`%F"NAME"`), one per `[include: NAME]`
    /// placeholder in the text — same class as `graphics`.
    public var includes: [String]
    /// Japanese Shift-In/Out runs, kept UNDECODED. Register C15.
    public var shiftRuns: [ShiftRun]
    /// The printer driver this file was last formatted for. Provenance: it explains why
    /// a file's measurements look the way they do.
    public var printerDriver: String?
    /// The type 0 HEADER sequence: the release the file declares outright (where
    /// `detection` only infers it from byte statistics) and the pointer to its
    /// paragraph style library. WS5+ only; `nil` when no header block carried either.
    public var wsHeader: WSHeader?
    /// Paragraph style library (WS5.5+): the styles the document carries at its end,
    /// reached via the header block's 32-bit pointer. Each entry is a name plus, where
    /// the index item says one exists, the 102-byte record's fields (margins/tabs in HMI
    /// 1/1800in, line height in VMI, attribute words), with each inheritable field `nil`
    /// when its sentinel says "inherit". Register C1.
    public var styles: [StyleEntry]
    /// `.tc` entries. Register C7.
    public var tocEntries: [TOCEntry]
    /// `.ix` entries. Register C6.
    public var indexEntries: [IndexEntry]
    /// `.l#` interval; `nil` when off or never set. Register C11.
    public var lineNumbering: Int?
    public var formatting: Formatting
    public var headers: [Int: String]
    /// Running foot text by line number (1-5). `.fo` is line 1; `.f1`-`.f5` select
    /// their own. See `headers` for the measured geometry.
    public var footers: [Int: String]
    /// Every `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, in document order, with the
    /// block it precedes — see `HFEvent`. `headers`/`footers` above are the FINAL state,
    /// a convenience view kept for callers that don't need per-page replay.
    public var hfEvents: [HFEvent]
    /// Name of the `Era` whose rules were applied (`Era.swift`) — so a caller can see
    /// WHICH release's behaviour this document was parsed under, not just which variant
    /// was detected. Mirrors Python's `meta['era']`.
    public var era: String?

    public init(
        blocks: [Block] = [],
        footnotes: [[Span]] = [],
        detection: Detection? = nil,
        marginEstimate: Int? = nil,
        dotCommands: [String] = [],
        dotPositions: [DotPosition] = [],
        unknownCodes: [UInt8: Int] = [:],
        columnar: Bool = false,
        notes: [Note] = [],
        unknownBlocks: [UnknownBlock] = [],
        page: PageGeometry? = nil,
        producer: String? = nil,
        footnoteNumberStart: Int? = nil,
        endnoteNumberStart: Int? = nil,
        commentBug: CommentBug? = nil,
        era: String? = nil,
        headers: [Int: String] = [:],
        footers: [Int: String] = [:],
        hfEvents: [HFEvent] = [],
        formatting: Formatting = Formatting(),
        graphics: [String] = [],
        colours: [ColourChange] = [],
        fonts: [FontChange] = [],
        includes: [String] = [],
        shiftRuns: [ShiftRun] = [],
        printerDriver: String? = nil,
        wsHeader: WSHeader? = nil,
        styles: [StyleEntry] = [],
        tocEntries: [TOCEntry] = [],
        indexEntries: [IndexEntry] = [],
        lineNumbering: Int? = nil
    ) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.detection = detection
        self.marginEstimate = marginEstimate
        self.dotCommands = dotCommands
        self.dotPositions = dotPositions
        self.unknownCodes = unknownCodes
        self.columnar = columnar
        self.notes = notes
        self.unknownBlocks = unknownBlocks
        self.page = page
        self.producer = producer
        self.footnoteNumberStart = footnoteNumberStart
        self.endnoteNumberStart = endnoteNumberStart
        self.commentBug = commentBug
        self.era = era
        self.headers = headers
        self.footers = footers
        self.hfEvents = hfEvents
        self.formatting = formatting
        self.graphics = graphics
        self.colours = colours
        self.fonts = fonts
        self.includes = includes
        self.shiftRuns = shiftRuns
        self.printerDriver = printerDriver
        self.wsHeader = wsHeader
        self.styles = styles
        self.tocEntries = tocEntries
        self.indexEntries = indexEntries
        self.lineNumbering = lineNumbering
    }

    public func iterLines() -> [Line] {
        blocks.flatMap(\.lines)
    }
}
