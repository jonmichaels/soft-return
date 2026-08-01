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
    /// Source byte offset of this block's opening `0x1D`.
    public var offset: Int

    public init(
        kind: NoteKind,
        text: String = "",
        number: Int? = nil,
        tag: String? = nil,
        lineCount: Int = 0,
        numberFormat: Int = 0,
        convertTo: Int = 0,
        dotCommands: [String] = [],
        offset: Int = 0
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

/// `.pl`/`.po`/`.mt`/`.mb` resolved, with provenance. Direct port of `parse_ws`'s
/// `doc.meta['page']` dict (core.py, "Page geometry, period-authentic footnote layout,
/// and note-aware export"). Unit-less dot-command arguments are LINES (columns for
/// `.po`), never inches — see `ParseWS.swift`'s page-geometry section for the full trap
/// writeup and the named-size snap tolerance.
public struct PageGeometry: Hashable, Sendable {
    public var plLines: Double
    public var heightIn: Double
    public var sizeName: String
    public var sizeSource: Provenance
    public var mtLines: Double
    public var mtSource: Provenance
    public var mbLines: Double
    public var mbSource: Provenance
    public var poCols: Double
    public var poSource: Provenance

    public init(
        plLines: Double,
        heightIn: Double,
        sizeName: String,
        sizeSource: Provenance,
        mtLines: Double,
        mtSource: Provenance,
        mbLines: Double,
        mbSource: Provenance,
        poCols: Double,
        poSource: Provenance
    ) {
        self.plLines = plLines
        self.heightIn = heightIn
        self.sizeName = sizeName
        self.sizeSource = sizeSource
        self.mtLines = mtLines
        self.mtSource = mtSource
        self.mbLines = mbLines
        self.mbSource = mbSource
        self.poCols = poCols
        self.poSource = poSource
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

    public init(
        blocks: [Block] = [],
        footnotes: [[Span]] = [],
        detection: Detection? = nil,
        marginEstimate: Int? = nil,
        dotCommands: [String] = [],
        unknownCodes: [UInt8: Int] = [:],
        columnar: Bool = false,
        notes: [Note] = [],
        unknownBlocks: [UnknownBlock] = [],
        page: PageGeometry? = nil,
        producer: String? = nil,
        footnoteNumberStart: Int? = nil,
        endnoteNumberStart: Int? = nil,
        commentBug: CommentBug? = nil
    ) {
        self.blocks = blocks
        self.footnotes = footnotes
        self.detection = detection
        self.marginEstimate = marginEstimate
        self.dotCommands = dotCommands
        self.unknownCodes = unknownCodes
        self.columnar = columnar
        self.notes = notes
        self.unknownBlocks = unknownBlocks
        self.page = page
        self.producer = producer
        self.footnoteNumberStart = footnoteNumberStart
        self.endnoteNumberStart = endnoteNumberStart
        self.commentBug = commentBug
    }

    public func iterLines() -> [Line] {
        blocks.flatMap(\.lines)
    }
}
