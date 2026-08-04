/// WS5+ 1D symmetric block stripping — the pre-pass `parseWS` runs on ws5+ documents
/// before `linesPass`. Direct port of `_symmetric_blocks` + `_parse_note` +
/// `_strip_dot_commands` + `_tab_columns` (Python ctrl-kd 1.2.0, core.py). Verified
/// against the 86 WS7 documents in Robert J. Sawyer's WordStar archive (per the Python
/// docstring); ported literally, guard conditions included, rather than "cleaned up."
///
/// A `0x1D` symmetric sequence is `0x1D` + 2-byte little-endian body length + body,
/// with a command byte at the start of the body. This pass rewrites the byte stream:
/// footnote/endnote/annotation blocks are extracted to `notes` and replaced with a
/// `SENT_FNREF` sentinel (comments never get one — WordStar never printed them
/// inline); structural blocks (tab, softpage, heading) become either literal bytes or
/// another sentinel; anything else is preserved as an `UnknownBlock` rather than
/// dropped. The result feeds `linesPass`, which never sees a `0x1D` byte from a
/// well-formed ws5+ document.

/// Sentinels injected into the cleaned stream. They must be bytes that CANNOT occur as
/// content, or a document's own byte gets mistaken for one — which is how the assembly
/// loop (job-006) tells them from real content.
///
/// `SENT_FNREF` was `0x07` until 2026-08-03. `0x07` is ^G, WordStar's phantom rubout —
/// rare and print-time-only by 1990, but REAL, and a literal one in a WS5+ body was read
/// as a note reference. Out-of-range degraded gracefully; an IN-range collision silently
/// attached the WRONG footnote to a piece of body text. Moved to `0x00`. NUL is not text
/// in a WordStar body — the format terminates on `0x1A` and never emits a NUL as content
/// — and unlike `0x1B` (the extended-character escape, tried first and rejected) nothing
/// downstream consumes it.
public let SENT_FNREF: UInt8 = 0x00
public let SENT_SOFTPAGE: UInt8 = 0x0B
public let SENT_HEADING: UInt8 = 0x11

/// Symmetrical-sequence "Notes" types (WordStar 7.0 file format spec, WordStar
/// International, 1992): 3 Footnote, 4 Endnote, 5 Annotation, 6 Comment. All four are
/// rendered inline via a reference marker except comments, which WordStar never
/// prints — they're only reachable through `Document.notes`/`.comments`-style filtering.
private func noteKind(forCmd cmd: Int) -> NoteKind? {
    switch cmd {
    case 0x03: return .footnote
    case 0x04: return .endnote
    case 0x05: return .annotation
    case 0x06: return .comment
    default: return nil
    }
}

/// Result of a symmetric-blocks pass: the rewritten byte stream, every note extracted
/// from it (in document order), and every symmetrical-sequence type this pass doesn't
/// interpret (preserved, not dropped).
public struct SymmetricBlocksResult: Hashable, Sendable {
    public let bytes: [UInt8]
    public let notes: [Note]
    public let unknownBlocks: [UnknownBlock]
    /// INSET picture paths, in document order — one per `[image: NAME]` placeholder in
    /// the rewritten stream. Register C10.
    public let graphics: [String]

    public let colours: [ColourChange]
    public let fonts: [FontChange]
    public let includes: [String]
    public let shiftRuns: [ShiftRun]
    public let printerDriver: String?

    public init(bytes: [UInt8], notes: [Note], unknownBlocks: [UnknownBlock],
                graphics: [String] = [], colours: [ColourChange] = [],
                fonts: [FontChange] = [], includes: [String] = [],
                shiftRuns: [ShiftRun] = [], printerDriver: String? = nil) {
        self.colours = colours
        self.fonts = fonts
        self.includes = includes
        self.shiftRuns = shiftRuns
        self.printerDriver = printerDriver
        self.bytes = bytes
        self.notes = notes
        self.unknownBlocks = unknownBlocks
        self.graphics = graphics
    }
}

public func symmetricBlocks(_ data: [UInt8]) -> SymmetricBlocksResult {
    var out: [UInt8] = []
    var notes: [Note] = []
    var unknownBlocks: [UnknownBlock] = []
    var graphics: [String] = []
    var colours: [ColourChange] = []
    var fonts: [FontChange] = []
    var includes: [String] = []
    var shiftRuns: [ShiftRun] = []
    var driver: String? = nil
    var i = 0
    while i < data.count {
        // core.py — need the marker plus both length bytes present.
        if data[i] == 0x1d && i + 3 <= data.count {
            let start = i
            let jump = Int(data[i + 1]) | (Int(data[i + 2]) << 8)   // little-endian 16-bit
            // `block` re-includes the 2-byte length field, then `jump` more bytes:
            // block[0..<2] is the length, block[2] is the command byte.
            let blockEnd = min(i + 3 + jump, data.count)
            let block = Array(data[(i + 1)..<blockEnd])
            let cmd: Int = block.count > 2 ? Int(block[2]) : -1
            if let kind = noteKind(forCmd: cmd) {
                let content = blockContent(block)
                notes.append(parseNote(kind: kind, cmd: cmd, content: content, offset: start))
                if cmd != 0x06 {                                   // comments: never printed inline
                    out.append(SENT_FNREF)
                }
            } else if cmd == 0x09 {                                // tab (and dot leaders)
                let (cols, leader) = tabColumns(blockContent(block))
                for _ in 0..<cols { out.append(leader) }
            } else if cmd == 0x0B {                                // end of page
                out.append(SENT_SOFTPAGE)
            } else if cmd == 0x0D {                                // paragraph number
                // WordStar's AUTOMATIC outline/legal numbering (`.p#`) — "2.1.3" and
                // the like. It used to fall through to `UnknownBlock`, which DELETES
                // the computed number from the output entirely: not unstyled, gone.
                // Outline-numbered essays, wills and structured reports lost every
                // generated number with no trace.
                out += blockContent(block)
                    .map { $0 & 0x7F }
                    .filter { $0 >= 0x20 && $0 < 0x7F }
            } else if cmd == 0x01 {                                // colour change
                // Two bytes: foreground and background colour INDICES into WordStar's
                // own palette, not RGB (the archive shows 00/00, 04/00, 08/04, 0c/08).
                // The text was never at risk here, but the change was invisible: a
                // document that coloured a passage rendered identically to one that
                // did not. Recorded, not rendered — the printed page this project
                // reproduces was monochrome. Register C2.
                let content = blockContent(block)
                if content.count >= 2 {
                    colours.append(ColourChange(offset: out.count,
                                                foreground: Int(content[0]),
                                                background: Int(content[1])))
                }
            } else if cmd == 0x02 || cmd == 0x15 {                 // font change
                // Six 16-bit little-endian values. The first is the type size in 1/20
                // POINT — across 862 real blocks that yields 9pt, 8pt, 11pt, 7pt, 6pt,
                // 12pt, 10pt, 14pt, and it is those sensible sizes that confirm the
                // reading. The rest identify the face to a 1987 printer driver and
                // mean nothing without it.
                //
                // Deliberate for PDF, which is Courier by design — but there is no
                // excuse for RTF/HTML, where a size change is expressible. Register C3.
                let content = blockContent(block)
                if content.count >= 4 {
                    fonts.append(FontChange(
                        offset: out.count,
                        height20thPt: Int(content[0]) | (Int(content[1]) << 8),
                        width20thPt: Int(content[2]) | (Int(content[3]) << 8),
                        driverBytes: Array(content[4...])))
                }
            } else if cmd == 0x0F {                                // print-file inclusion
                // A file the printer was told to pull in — the archive carries
                // `%F"PLEAD.PS"`. Like an inset graphic, the block holds a FILENAME
                // and was being dropped whole.
                // Written byte-wise: `range(of:)`/`trimmingCharacters` are Foundation
                // and this module deliberately imports nothing.
                let printable = blockContent(block)
                    .map { $0 & 0x7F }.filter { $0 >= 0x20 && $0 < 0x7F }
                var mark = -1
                if printable.count >= 2 {
                    for k in 0...(printable.count - 2)
                    where printable[k] == 0x25 && printable[k + 1] == 0x46 {   // "%F"
                        mark = k + 2
                        break
                    }
                }
                if mark >= 0 {
                    var body = Array(printable[mark...])
                    while let f = body.first, f == 0x20 || f == 0x22 || f == 0x09 {
                        body.removeFirst()
                    }
                    while let l = body.last, l == 0x20 || l == 0x22 || l == 0x09 {
                        body.removeLast()
                    }
                    let name = decodeCP437(body)
                    if !name.isEmpty {
                        includes.append(name)
                        out += Array("[include: \(name)]".utf8)
                        i += jump + 3
                        continue
                    }
                }
                // No `%F` in it — most of these are PostScript preambles. Consuming
                // them silently would be WORSE than the bug being fixed: it turns a
                // reported unknown into an unreported one.
                unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
            } else if cmd == 0x00 {                                // printer/driver name
                // The driver the document was last formatted for (LASERJET in 43
                // archive documents). Provenance: it explains why a file's
                // measurements look the way they do. The byte before the name is a
                // record tag, not part of it (`pLASERJET`).
                var name: [UInt8] = []
                for c in blockContent(block) {
                    let ch = c & 0x7F
                    if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x30 && ch <= 0x39) {
                        name.append(ch)
                    } else if !name.isEmpty {
                        break
                    }
                }
                if name.isEmpty {
                    // No name in it. An EMPTY 0x00 block is a plain wrapper, not a
                    // driver record — same rule as an 0x0F with no `%F`: consuming it
                    // silently would turn a reported unknown into an unreported one.
                    unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
                } else if driver == nil {
                    driver = decodeCP437(name)
                }
            } else if cmd == 0x17 {                                // Shift-In/Shift-Out
                // Japanese double-byte text. NOT decoded: these are Shift-JIS and a
                // cp437 decoder would produce confident mojibake — worse than an
                // honest placeholder, because it looks like text. Nothing in the
                // archive contains one; implemented from the spec. Register C15.
                let content = blockContent(block)
                shiftRuns.append(ShiftRun(offset: out.count, bytes: content))
                out += Array("[shift-jis: \(content.count) bytes]".utf8)
            } else if cmd == 0x16 {                                // truncation marker
                // The spec says a truncated line shows a literal marker. Nothing in
                // the archive contains one, so this is implemented FROM THE SPEC and
                // has never been checked against a file that really has it. C14.
                out += Array("<TRUNCATED>".utf8)
            } else if cmd == 0x10 {                                // inset graphic
                // An INSET picture placed in the text. The block's content is the
                // image's path, and it was falling through to `UnknownBlock` — which
                // preserves the bytes for diagnostics but drops the text — so a
                // document with figures rendered as if it had none. Register C10.
                //
                // A converter cannot render a 1987 .PIX file, but it must not go quiet
                // about one: the path is recorded and a visible placeholder goes into
                // the text where the picture sat.
                let path = decodeCP437(blockContent(block)
                    .map { $0 & 0x7F }
                    .filter { $0 >= 0x20 && $0 < 0x7F })
                graphics.append(path)
                let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
                    .map(String.init) ?? path
                out += Array("[image: \(name)]".utf8)
            } else if cmd == 0x0E {                                // index item
                // An inline indexed PHRASE. WordStar prints the phrase in the body —
                // the index ENTRY is the non-printing part — so dropping the block
                // risks losing text outright when the phrase is not duplicated in the
                // visible stream.
                out += blockContent(block)
                    .map { $0 & 0x7F }
                    .filter { $0 >= 0x20 && $0 < 0x7F }
            } else if cmd == 0x11 && block.count > 3 {             // paragraph style
                // WordStar's paragraph-style mechanism. Three IDs were mapped to
                // heading levels and EVERY OTHER STYLE WAS DROPPED — silently, so a
                // styled paragraph became an unstyled one with nothing to say a style
                // had been applied. The archive uses at least twelve distinct IDs;
                // 0x06 alone appears 60 times, more often than two of the three that
                // were mapped. Register C1.
                //
                // The sentinel carries the style ID as well as the level, so a
                // consumer can see WHICH style even where this parser has no heading
                // meaning for it. Level 0 = "a style, but not one of the three".
                let styleID = Int(block[3])
                let level = [0x05: 1, 0x02: 2, 0x03: 3][styleID] ?? 0
                out.append(SENT_HEADING)
                out.append(UInt8(0x30 + level))
                out.append(UInt8(0x30 + (styleID & 0x3F)))
            } else {
                unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
            }
            i += jump + 3
        } else {
            out.append(data[i])
            i += 1
        }
    }
    return SymmetricBlocksResult(bytes: out, notes: notes, unknownBlocks: unknownBlocks,
                                 graphics: graphics, colours: colours, fonts: fonts,
                                 includes: includes, shiftRuns: shiftRuns,
                                 printerDriver: driver)
}

/// `block[3:-3] if len(block) >= 6 else block[3:]` — strips the leading length+cmd
/// header and, when there's room, the trailing self-referential length+marker that
/// closes a well-formed symmetric block. Bounds-checked so a truncated/malformed block
/// degrades to whatever content bytes actually exist rather than crashing.
private func blockContent(_ block: [UInt8]) -> [UInt8] {
    if block.count >= 6 {
        return Array(block[3..<(block.count - 3)])
    }
    return block.count > 3 ? Array(block[3...]) : []
}

/// Decode one note block's content (the bytes between the type byte and the closing
/// count+0x1D), per the spec's Notes section. Direct port of `_parse_note`:
///
///     Word: line count of the note text
///     Word: offset to the internal tag sequence (high bit set -> low 15 bits are the
///           offset) OR the note number itself (high bit clear)
///     Byte: conversion flag (used only when there is no internal tag) -- low nybble =
///           target type if converted (0 = not converted), high nybble = numbering
///           format (0 symbols, 1 upper, 2 lower, 3 numeric)
///     Remaining bytes: the note text, which may itself hold ONE nested symmetrical
///           sequence (the internal tag, or a font change) -- spec: "Currently only
///           one level of this recursion is used."
///
/// The tag/conversion-flag word and the internal tag mean different things per kind,
/// though: only footnotes/endnotes carry a NUMBER (the spec is explicit that
/// annotations'/comments' equivalent fields are "not used"). Annotations instead carry
/// a TEXT tag ("the text used to display and print the tag of the note") in the very
/// same position a footnote's internal tag would carry its number -- so the same
/// nested-sequence walk below extracts a number for footnote/endnote and a tag string
/// for annotation, and the outer conversion flag is only trusted where the spec says
/// it's actually used (not annotations).
private func parseNote(kind: NoteKind, cmd: Int, content: [UInt8], offset: Int) -> Note {
    guard content.count >= 5 else { return Note(kind: kind, offset: offset) }
    let lineCount = Int(content[0]) | (Int(content[1]) << 8)
    let tagWord = Int(content[2]) | (Int(content[3]) << 8)
    var convFlag = content[4]
    let numeric = kind == .footnote || kind == .endnote
    var number: Int? = numeric ? ((tagWord & 0x8000) != 0 ? nil : tagWord) : nil
    var tag: String? = nil
    let remainder = Array(content.dropFirst(5))

    var textBytes: [UInt8] = []
    var i = 0
    while i < remainder.count {
        if remainder[i] == 0x1d && i + 3 <= remainder.count {
            let jump = Int(remainder[i + 1]) | (Int(remainder[i + 2]) << 8)
            let innerEnd = min(i + 3 + jump, remainder.count)
            let inner = Array(remainder[(i + 1)..<innerEnd])
            let innerCmd: Int = inner.count > 2 ? Int(inner[2]) : -1
            if innerCmd == cmd {                                   // the internal tag sequence
                let innerContent = blockContent(inner)
                if numeric && innerContent.count >= 5 {
                    number = Int(innerContent[2]) | (Int(innerContent[3]) << 8)
                    convFlag = innerContent[4]
                } else if kind == .annotation && innerContent.count > 5 {
                    let rawTag = innerContent.dropFirst(5).filter { c in
                        (c >= 0x20 && c < 0x7F) || c >= 0x80 || c == 0x09
                    }
                    let decoded = decodeCP437(Array(rawTag)).trimmed()
                    tag = decoded.isEmpty ? nil : decoded
                }
            }
            i += jump + 3                                          // skip the whole nested sequence
        } else {
            textBytes.append(remainder[i])
            i += 1
        }
    }

    let (text, dots) = stripDotCommands(textBytes)
    let numberFormat: Int
    let convertTo: Int
    if kind == .annotation {
        // spec: "Byte: Conversion flag. Not used for annotations." -- don't report
        // noise from a byte the format documents as meaningless here.
        numberFormat = 0
        convertTo = 0
    } else {
        numberFormat = Int((convFlag >> 4) & 0x0F)
        convertTo = Int(convFlag & 0x0F)
    }
    return Note(
        kind: kind, text: text, number: number, tag: tag, lineCount: lineCount,
        numberFormat: numberFormat, convertTo: convertTo, dotCommands: dots, offset: offset
    )
}

/// Split note text into physical lines (the same hard-return bytes the body splits on)
/// and pull any dot-command lines out of it -- a note can carry its own dot commands (a
/// `.rr` ruler, a `..` comment line) exactly like the body can, and the body already
/// never renders those as text. Unrecognised dot commands are kept verbatim, in order,
/// not dropped; surviving text lines are cleaned the same way note text always was and
/// rejoined with a space (notes are short callouts, not reflowed prose). Direct port of
/// `_strip_dot_commands`.
private func stripDotCommands(_ raw: [UInt8]) -> (text: String, dots: [String]) {
    let lines = splitOnLineBreaks(raw)
    var kept: [String] = []
    var dots: [String] = []
    for line in lines {
        let stripped = line.map { $0 & 0x7F }              // same masking the body uses
        if stripped.first == 0x2e {
            dots.append(decodeCP437(stripped).trimmed())
            continue
        }
        let clean = line.filter { c in (c >= 0x20 && c < 0x7F) || c >= 0x80 || c == 0x09 }
        let piece = decodeCP437(clean).trimmed()
        if !piece.isEmpty {
            kept.append(piece)
        }
    }
    return (kept.joined(separator: " "), dots)
}

/// Non-overlapping split on any of WordStar's line-break tokens, matching
/// `re.split(rb'\x8d\x0a|\x0d\x0a|\x8d|\x0d|\x0a', raw)` — every separator is consumed
/// (not kept), including adjacent/leading/trailing ones, which produce empty segments
/// that stay in the result (Python `re.split` never drops them).
private func splitOnLineBreaks(_ data: [UInt8]) -> [[UInt8]] {
    var result: [[UInt8]] = []
    var current: [UInt8] = []
    var i = 0
    while i < data.count {
        let b = data[i]
        let next: UInt8? = (i + 1 < data.count) ? data[i + 1] : nil
        if b == 0x8d && next == 0x0a {
            result.append(current); current = []; i += 2
        } else if b == 0x0d && next == 0x0a {
            result.append(current); current = []; i += 2
        } else if b == 0x8d || b == 0x0d || b == 0x0a {
            result.append(current); current = []; i += 1
        } else {
            current.append(b)
            i += 1
        }
    }
    result.append(current)
    return result
}

/// Tabs and dot leaders (symmetrical sequence type 9, WordStar 7.0 file format spec):
/// Word tab size in HMIs, Word absolute tab size in HMIs, Byte tab type, Byte tab size
/// in tenths. Documented tab-type bytes: ' ' hard tab, soft space (0xA0) soft tab, '#'
/// decimal, '!' center, '[' right-align. ']' is an UNDOCUMENTED right-align variant --
/// WordTsar's author found it by testing against MicroPro's own PRINT.TST (confirmed
/// present there too: a type-9 block with tab type byte 0x5D, ']'). It renders
/// identically to the documented '[': same right-align intent, just a second byte
/// value nobody wrote down. Any other byte is a dot-leader character (spec: "Other
/// character such as '.' or '*' are used for dot leaders.").
///
/// HMI -> columns: at 1440 units/inch and 10 CPI, one column is 1440/10 = 144 HMI --
/// the same derivation the project's footnote-VMI research already used for VMI
/// (1440/6 = 240 per line at 6 LPI); treated here as the matching inference for the
/// horizontal axis, not a spec-stated constant. Direct port of `_tab_columns`.
private let tabHMIPerCol = 144
private let tabRightTypes: Set<UInt8> = [0x5B, 0x5D]        // '[' documented, ']' undocumented

/// Python's `round()` is round-half-to-even (banker's rounding), unlike Swift's
/// `FloatingPoint.rounded()` default (round-half-away-from-zero). `size`/`divisor` are
/// always non-negative here (2-byte LE HMI fields), so exact integer arithmetic — no
/// floating point, no libm dependency — reproduces it precisely, including the exact
/// `.5` tie case `round()` handles specially.
private func roundHalfToEven(_ numerator: Int, by divisor: Int) -> Int {
    let quotient = numerator / divisor
    let remainder = numerator % divisor
    let doubledRemainder = remainder * 2
    if doubledRemainder < divisor { return quotient }
    if doubledRemainder > divisor { return quotient + 1 }
    return quotient % 2 == 0 ? quotient : quotient + 1
}

/// We can't reflow text to truly right/center/decimal-align a tab without knowing the
/// width of what follows it -- this pass runs before line/word splitting -- so those
/// types degrade to plain space padding, but of the CORRECT width (from the tab's own
/// HMI size) rather than a guessed constant. Dot-leader tabs (any byte outside the
/// documented/undocumented set) repeat their own leader character.
private func tabColumns(_ content: [UInt8]) -> (cols: Int, leader: UInt8) {
    guard content.count >= 5 else {
        return (4, 0x20)            // malformed/short block: the old fixed-4-spaces
                                     // behaviour as a safe fallback, never a crash
    }
    let size = Int(content[0]) | (Int(content[1]) << 8)
    let tabType = content[4]
    let cols = max(1, roundHalfToEven(size, by: tabHMIPerCol))
    let leader: UInt8
    if tabType == 0x20 || tabType == 0xA0 || tabType == UInt8(ascii: "#")
        || tabType == UInt8(ascii: "!") || tabRightTypes.contains(tabType) {
        leader = 0x20
    } else if tabType >= 0x20 && tabType < 0x7F {
        leader = tabType                                    // dot-leader character
    } else {
        leader = 0x20
    }
    return (cols, leader)
}
