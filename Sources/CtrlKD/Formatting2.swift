/// The running FORMATTING state: `.oc` `.oj` `.aw` `.ul` `.sb` `.ps` `.kr` `.pr` `.sr`.
///
/// These are not page geometry and deliberately do not use its machinery. Page commands
/// resolve once per document — first occurrence wins, because a page is a page. These
/// apply FROM WHERE THEY APPEAR ONWARD: the WordStar 7 archive brackets individual
/// headings with `.oc on` / `.oc off` inside otherwise justified text, so the state is
/// stamped onto each `Block` as it opens and a change closes the block it interrupts.
///
/// Register C8, C16-C23. Direct port of Python's `_parse_format_dot`/`_align_now`.
///
/// ARGUMENT FORMS COME FROM THE ARCHIVE, NOT THE MANUAL. Three would have been wrong
/// from the manual alone — see `applyFormatDot` for `.pr`, `.oj` and `.sr`.
struct FormatState {
    /// `.oc` — centering. Wins over `.oj`: WordStar centres the line whatever the
    /// justification setting says, which is what lets `.oc on`/`.oc off` pairs sit
    /// inside justified text.
    var centering: Bool? = nil
    /// `.oj` — justification, when it is not overridden by centering.
    var justify: Alignment? = nil
    /// `.aw` — word wrap.
    var wrap: Bool? = nil

    // Document-wide flags. Only what the file actually SET is reported, so a consumer
    // can tell "the author asked for portrait" from "nobody said" — the same provenance
    // rule the page geometry follows.
    var underlineBlanks: Bool? = nil        // `.ul`  C21
    var suppressBlanks: Bool? = nil         // `.sb`  C8
    var proportional: Bool? = nil           // `.ps`  C19
    var kerning: Bool? = nil                // `.kr`  C20
    var orientation: Orientation? = nil     // `.pr`  C18
    var subSuperRoll48: Double? = nil       // `.sr`  C22

    // `.lm` / `.rm` / `.pm` — per-block, not document-wide. C9.
    var leftMargin: Double? = nil
    var rightMargin: Double? = nil
    var paraMargin: Double? = nil
    var columns: Int? = nil                 // `.co`  C5
    var columnGutter: Double? = nil
    var endnotesHere: Bool? = nil           // `.pe`  C4
    var convertNotes: [String] = []         // `.cv`  C13
    var autoPageNumbers: Bool? = nil        // `.op` / `.pg`
    var paranumFormat: String? = nil        // `.p#`
    var condCol: [String] = []              // `.cc`
    var tabStops: [Double]? = nil           // `.tb`
    /// `.lh` — line height in 1/48in, as RUNNING state. Register C24.
    ///
    /// Also read (first occurrence only) by `parsePageDot` into the page geometry, which is
    /// the DOCUMENT-LEVEL default — page capacity, the emitters' baseline lead, `--diagnose`.
    /// That reading is not wrong; it is incomplete. `.lh` is stateful like every other
    /// command in this struct, and a document that sets `.lh10pt` before its body and
    /// `.lh16pt` before each banner heading means both, in order. Carried per LINE
    /// (`Line.lead48`) because that is the granularity it acts at — a lead is the distance
    /// between baselines, not a property of a paragraph, which is also why it is NOT part of
    /// `blockFormat` and therefore never closes a block.
    var lead48: Double? = nil

    /// Everything stamped onto a `Block` when it opens. A change to ANY of these has to
    /// close the current block, because a single block cannot hold two values of it:
    /// `.oc on` mid-paragraph means the lines after it are centred and the ones before
    /// are not, and `.lm 5` mid-paragraph means the same about the indent.
    var blockFormat: BlockFormat {
        // `.tb` mid-paragraph means the lines after it were typed against different
        // stops (2026-08-06) — rendering doesn't change, but per-block fidelity of the
        // carried state does. Empty stops count as none, mirroring Python's
        // `tuple(...) if state.get('tab_stops') else None`.
        BlockFormat(align: alignment, wrap: wrap ?? true, leftMargin: leftMargin,
                    rightMargin: rightMargin, paraMargin: paraMargin,
                    columns: columns, columnGutter: columnGutter,
                    tabStops: (tabStops?.isEmpty ?? true) ? nil : tabStops)
    }

    /// The alignment in force.
    var alignment: Alignment {
        if centering == true { return .center }
        return justify ?? .left
    }
}

/// The tuple of per-block formatting, compared to decide whether a dot command has to
/// close the block it interrupts.
struct BlockFormat: Equatable {
    var align: Alignment
    var wrap: Bool
    var leftMargin: Double?
    var rightMargin: Double?
    var paraMargin: Double?
    var columns: Int?
    var columnGutter: Double?
    var tabStops: [Double]?
}

public enum Orientation: String, Hashable, Sendable {
    case portrait
    case landscape
}

/// What a document asked for that is not page geometry and not per-block. Only keys the
/// file actually set are non-nil.
public struct Formatting: Hashable, Sendable {
    public var underlineBlanks: Bool?
    public var suppressBlanks: Bool?
    public var proportional: Bool?
    public var kerning: Bool?
    public var orientation: Orientation?
    /// `.sr` — the sub/superscript roll, in 1/48in units. `0` is a real value meaning
    /// "do not shift at all", which is why this is an optional rather than defaulting.
    public var subSuperRoll48: Double?
    /// `.pe` — endnotes print HERE rather than at the document end. Register C4.
    public var endnotesHere: Bool?
    /// `.cv` arguments verbatim, in order. Register C13.
    public var convertNotes: [String]
    /// `.op` / `.pg` — whether the AUTOMATIC page number prints. `nil` when neither was
    /// seen. A `#` in a header or footer is unaffected either way.
    public var autoPageNumbers: Bool?
    /// `.p#` — the format string for the 0x0D paragraph-number blocks, verbatim.
    /// RECORDED, not rendered: see `applyFormatDot`.
    public var paranumFormat: String?
    /// `.cc n` arguments verbatim, in order — `.cp`'s partner for newspaper columns.
    /// RECORDED, deliberately inert: see `applyFormatDot`.
    public var condCol: [String]
    /// `.tb` — the stops a plain ASCII 0x09 tab expands to, in print columns. `nil` when
    /// the file never set them; ASCII-tab expansion stays at the spec's modulus-8
    /// default either way. See `applyFormatDot`.
    public var tabStops: [Double]?

    public init(underlineBlanks: Bool? = nil, suppressBlanks: Bool? = nil,
                proportional: Bool? = nil, kerning: Bool? = nil,
                orientation: Orientation? = nil, subSuperRoll48: Double? = nil,
                endnotesHere: Bool? = nil, convertNotes: [String] = [],
                autoPageNumbers: Bool? = nil, paranumFormat: String? = nil,
                condCol: [String] = [], tabStops: [Double]? = nil) {
        self.paranumFormat = paranumFormat
        self.condCol = condCol
        self.tabStops = tabStops
        self.endnotesHere = endnotesHere
        self.convertNotes = convertNotes
        self.autoPageNumbers = autoPageNumbers
        self.underlineBlanks = underlineBlanks
        self.suppressBlanks = suppressBlanks
        self.proportional = proportional
        self.kerning = kerning
        self.orientation = orientation
        self.subSuperRoll48 = subSuperRoll48
    }

    /// True when the file set nothing at all — Python's empty `meta['formatting']`.
    public var isEmpty: Bool {
        underlineBlanks == nil && suppressBlanks == nil && proportional == nil
            && kerning == nil && orientation == nil && subSuperRoll48 == nil
            && endnotesHere == nil && convertNotes.isEmpty && autoPageNumbers == nil
            && paranumFormat == nil && condCol.isEmpty && tabStops == nil
    }
}

/// `ON`/`OFF` -> true/false, anything else -> nil.
///
/// WordStar's on/off dot commands accept only those two words; an argument that is
/// neither (a stray `.oc` inside a manual's own prose, and the archive has those) leaves
/// the state alone rather than guessing — which is why this returns nil, not false.
private func onOff(_ arg: [UInt8]) -> Bool? {
    let a = trimmed(arg).map(asciiUpper)
    if a.starts(with: Array("ON".utf8)) { return true }
    if a.starts(with: Array("OFF".utf8)) { return false }
    return nil
}

private func asciiUpper(_ b: UInt8) -> UInt8 { (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b }
private func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b }

private func trimmed(_ b: [UInt8]) -> [UInt8] {
    var s = 0, e = b.count
    while s < e, b[s] == 0x20 || b[s] == 0x09 { s += 1 }
    while e > s, b[e - 1] == 0x20 || b[e - 1] == 0x09 || b[e - 1] == 0x0D { e -= 1 }
    return Array(b[s..<e])
}

/// Update running formatting state from one dot-command line.
func applyFormatDot(_ cmd: [UInt8], _ state: inout FormatState) {
    guard var (name, arg) = dotCommandNameAndArg(cmd) else { return }
    if name.map(asciiUpper) == Array("P".utf8), arg.first == 0x23 {
        // `.p#` — '#' is not a letter, so the shared name scanner splits it into name
        // 'P', arg '#...'; rejoin before dispatch.
        name = Array("P#".utf8)
        arg = Array(arg.dropFirst())
    }
    switch String(decoding: name.map(asciiUpper), as: UTF8.self) {
    case "OC":
        if let v = onOff(arg) { state.centering = v }
    case "OJ":
        // The manual leads with on/off; the archive really uses `.oj r` and `.oj c`.
        if let v = onOff(arg) {
            state.justify = v ? .justify : nil
        } else if let first = trimmed(arg).first.map(asciiUpper) {
            if first == 0x43 { state.justify = .center }        // 'C'
            else if first == 0x52 { state.justify = .right }    // 'R'
        }
    case "AW":
        if let v = onOff(arg) { state.wrap = v }
    case "UL":
        if let v = onOff(arg) { state.underlineBlanks = v }
    case "SB":
        if let v = onOff(arg) { state.suppressBlanks = v }
    case "PS":
        if let v = onOff(arg) { state.proportional = v }
    case "KR":
        if let v = onOff(arg) { state.kerning = v }
    case "PR":
        // Real syntax, from the archive rather than the manual's prose: `.pr or=l` /
        // `.pr or=p`. 18 of the 22 files that use `.pr` set landscape this way, and
        // every one was rendering portrait with no diagnostic. Register C18.
        let a = trimmed(arg).map(asciiLower)
        if a.starts(with: Array("or=".utf8)), a.count > 3 {
            if a[3] == 0x6C { state.orientation = .landscape }      // 'l'
            else if a[3] == 0x70 { state.orientation = .portrait }  // 'p'
        }
    case "LH":
        // Line height, 1/48in units — RUNNING state, unlike the page geometry's first-wins
        // read of the same command. See `FormatState.lead48`. Junk or a non-positive height
        // is rejected by `resolveLhArg` and the state stands, exactly as `.lm` does.
        guard let (value, unit) = parseDotNumber(arg), value.isFinite else { return }
        if let resolved = resolveLhArg(value, unit) { state.lead48 = resolved }
    case "LM", "RM", "PM":
        // Print columns at 10 CPI, matching `.po`; a unit suffix converts, since the
        // archive writes both `.rm 65` and `.rm 6.5"`.
        guard let (value, unit) = parseDotNumber(arg), value.isFinite else { return }
        var cols = resolveColsArg(value, unit)
        let isLM = String(decoding: name.map(asciiUpper), as: UTF8.self) == "LM"
        if isLM, unit == nil || unit!.isEmpty {
            // `.lm 8` is a COLUMN NUMBER (1-based: text begins AT column 8 = 7 columns
            // of offset), while a unit-suffixed `.lm 0.7"` and a paragraph style's
            // left_margin_hmi are already offsets from the edge. Normalised here so
            // leftMargin means one thing -- offset columns -- to every consumer,
            // whichever way the file said it (found 2026-08-06 wiring Modern block
            // margins).
            cols = Swift.max(0.0, cols - 1.0)
        }
        switch String(decoding: name.map(asciiUpper), as: UTF8.self) {
        case "LM": state.leftMargin = cols
        case "RM": state.rightMargin = cols
        default: state.paraMargin = cols
        }
    case "CO":
        // `.co <n>, <gutter>` — the archive writes `.co2, 0.3"`, `.CO3,  .20"` and
        // `.co1` (one column = columns off). Stateful like the margins. Register C5.
        let body = trimmed(arg)
        guard let (n, _, numEnd) = parseDotNumberConsuming(body), n.isFinite else { return }
        state.columns = Swift.max(1, Int(n))
        // The gutter follows the count after separators that may be a comma OR
        // just spaces -- `.co2, 0.3"` and `.co 2  1.00"` are both real. Python:
        // `body[m.end():].lstrip(b' \t,')`. Scanning for a comma lost every
        // space-separated gutter (BOOKLET's two-column gap, cross-check
        // 2026-08-04).
        var k = numEnd
        while k < body.count, body[k] == 0x20 || body[k] == 0x09 || body[k] == 0x2C { k += 1 }
        if k < body.count {
            if let (g, unit) = parseDotNumber(Array(body[k...])), g.isFinite {
                state.columnGutter = resolveColsArg(g, unit)
            }
        }
    case "OP", "PG":
        // WSFORMAT.TXT: ".OP  Omit page number" / ".PG  Number pages ... Usually used
        // to restore page numbering after being turned off with .OP." A STATEFUL pair —
        // front matter often turns it off and the body turns it back on — and only the
        // AUTOMATIC number is affected. A `#` the author placed in a header or footer
        // prints either way; the spec names that as the explicit exemption.
        state.autoPageNumbers = (String(decoding: name.map(asciiUpper), as: UTF8.self) == "PG")
    case "PE":
        // `.pe` marks where endnotes should print instead of the document end.
        // Previously endnotes always went to the end regardless. Register C4.
        state.endnotesHere = true
    case "CV":
        // `.cv <from> <to>` retypes notes mid-document. Recorded verbatim: acting on
        // it means re-kinding notes already parsed, a separate pass. Register C13.
        state.convertNotes.append(decodeCP437(trimmed(arg)))
    case "P#":
        // `.p#` sets the format and/or initial value for the 0x0D paragraph-number
        // blocks. Format alphabet, from Sawyer's own PARAGRAP.NUM notes (a WS file, read
        // with THIS converter): '1' numerals from 1, '9' numerals from 0, 'Z'/'z'
        // upper/lowercase letters, 'I' roman. RECORDED, not rendered: zero documents in
        // the archive use it, so a format engine would be code with no real input to
        // check against — the 47 real 0x0D blocks all render with the default numeric
        // form.
        state.paranumFormat = decodeCP437(trimmed(arg))
    case "CC":
        // `.cc n` is `.cp`'s partner for newspaper columns (WSFORMAT: "Like the .CP
        // command, but works with columnar breaks instead"). RECORDED, deliberately
        // inert: this converter does not simulate column filling (columns render as CSS
        // column-count in HTML; the browser decides the breaks), so there is no column
        // fill state to test n against. Zero archive documents use it.
        state.condCol.append(decodeCP437(trimmed(arg)))
    case "TB":
        // `.tb` sets the RULER's tab stops (WSFORMAT: "E P ... Sets multiple tab stops
        // for further editing/printing"). Their real mechanism is EDITOR-time (measured
        // 2026-08-06, third confirmation of the doctrine): the Tab key resolves against
        // the stops and bakes a type-9 sequence carrying its own HMI position, so the
        // stops change no rendered byte — 46 archive files use `.tb` and ZERO of them
        // contain a bare 0x09 (the intersection is empty, corpus-wide). A bare 0x09's
        // print expansion stays at the spec's own fixed rule ("modulus 8 print
        // position"); whether `.tb` would override THAT is unmeasured and unreachable
        // in this corpus. Stops are carried per-block for the layout contract and a
        // future editor. Task #19.
        var stops: [Double] = []
        for token in splitOnDotSpace(arg.map { $0 == 0x2C ? 0x20 : $0 }) {
            if let (value, unit) = parseDotNumber(token), value.isFinite {
                stops.append(resolveColsArg(value, unit))
            }
        }
        if !stops.isEmpty { state.tabStops = stops }
    case "SR":
        if let roll = parseSRArg(arg) { state.subSuperRoll48 = roll }
    default:
        break
    }
}

/// `.sr` — the sub/superscript roll, in 1/48in units.
///
/// WordStar's own unit for this command is 48ths, so a bare number IS 48ths. The archive
/// also writes it as a fraction of an inch (`3/48"`, `4/48i`) and in points (`5pt`), both
/// of which convert. A roll of 0 is meaningful — it means do not shift at all — so this
/// returns nil only for an argument it cannot read, never for a legitimate zero.
func parseSRArg(_ arg: [UInt8]) -> Double? {
    guard let (num, unitAfterNum) = parseDotNumber(arg) else { return nil }
    // A fraction: `<num> / <den>` with an optional unit. Both paths multiply by 48
    // because a unit-less fraction is already a fraction OF AN INCH (`3/48` == 3/48in),
    // which is exactly what the 48ths unit expresses.
    var i = 0
    var seenDigits = false
    while i < arg.count {
        let c = arg[i]
        if c >= 0x30 && c <= 0x39 || c == 0x2E { seenDigits = true; i += 1; continue }
        if c == 0x20 || c == 0x09 { i += 1; continue }
        break
    }
    if seenDigits, i < arg.count, arg[i] == 0x2F {                  // '/'
        guard let (den, _) = parseDotNumber(Array(arg[(i + 1)...])), den != 0 else {
            return nil
        }
        return (num / den) * 48.0
    }
    guard num.isFinite else { return nil }
    if let inches = dotArgInches(num, unitAfterNum) { return inches * 48.0 }
    return num
}

/// A colour change (symmetric type 0x01). WSFORMAT.TXT, type 1 Color:
///
///     Byte: Color number (see below).
///     Byte: Previous color in file.
///
/// CURRENT and PREVIOUS, not foreground and background — which is what this recorded
/// until 2026-08-04. The palette is named and fixed (0 Black … 0Fh White on black), so
/// the number resolves to a colour rather than being an opaque index.
///
/// Recorded, not rendered: the printed page this project reproduces was monochrome.
/// Register C2.
public struct ColourChange: Hashable, Sendable {
    public let offset: Int
    public let colour: Int
    public let previous: Int
    public init(offset: Int, colour: Int, previous: Int) {
        self.offset = offset
        self.colour = colour
        self.previous = previous
    }
}

/// The typestyle word's symbol-map field, bits 12-13.
///
/// FLAGGED, NOT YET ACTED ON: across the archive this reads cp437 183, MATH 302,
/// CP850 377, and every decode in this project is cp437 unconditionally. CP850 differs
/// from CP437 through the whole upper half, so accented characters in those documents
/// may be decoding wrong. Recorded rather than guessed at.
public enum SymbolMap: String, Hashable, Sendable {
    case cp437
    case cp850
    case math
    case symbols
}

/// The typestyle word's generic-style field, bits 10-11.
public enum GenericStyle: String, Hashable, Sendable {
    case sans
    case serif
    case script
    case display
}

/// A font change (symmetric type 0x02/0x15). WSFORMAT.TXT, type 2 Font — six
/// little-endian words:
///
///     Word: Font width in HMIs  (1/1800ths of an inch)
///     Word: Font height in VMIs (1/1440ths of an inch)
///     Word: Typestyle
///     Word x3: the previous width, height and typestyle
///
/// WIDTH COMES FIRST. Until 2026-08-04 this read word 1 as the height "in 1/20 point"
/// and word 2 as the width — swapped. The error survived because 1/1440in IS 1/20 point
/// exactly (1440/72 = 20), so treating the WIDTH word as 20ths-of-a-point produced 9pt,
/// 8pt, 11pt across 862 real blocks: sizes plausible enough that they were cited as
/// confirming the reading. They were the right arithmetic on the wrong word. Read
/// correctly, 749 of those blocks are 12pt at 10 CPI.
///
/// Register C3. Deliberate for PDF, which is Courier by design; RTF/HTML can express a
/// size change and now have the figures.
public struct FontChange: Hashable, Sendable {
    public let offset: Int
    /// Width in HMIs, 1/1800 inch.
    public let width1800: Int
    /// Height in VMIs, 1/1440 inch.
    public let height1440: Int
    /// The raw typestyle word; the accessors below decode its documented bit fields.
    public let typestyle: Int

    public init(offset: Int, width1800: Int, height1440: Int, typestyle: Int) {
        self.offset = offset
        self.width1800 = width1800
        self.height1440 = height1440
        self.typestyle = typestyle
    }

    /// The size in points — 1/1440in IS 1/20pt exactly.
    public var points: Double { Double(height1440) / 20.0 }
    /// Characters per inch. `nil` for a zero width, which is not a printable pitch.
    public var cpi: Double? { width1800 == 0 ? nil : 1800.0 / Double(width1800) }
    public var proportional: Bool { typestyle & 0x8000 != 0 }
    public var letterQuality: Bool { typestyle & 0x4000 != 0 }
    public var symbolMap: SymbolMap {
        [SymbolMap.cp437, .cp850, .math, .symbols][(typestyle >> 12) & 0x03]
    }
    public var genericStyle: GenericStyle {
        [GenericStyle.sans, .serif, .script, .display][(typestyle >> 10) & 0x03]
    }
    public var typestyleNumber: Int { typestyle & 0x01FF }
    /// The spec's own 245-entry name table (`Typestyles.swift`); `nil` for numbers the
    /// table doesn't carry. A NAME, not a font choice: the table never picks a typeface,
    /// it says what the file said.
    public var typestyleName: String? {
        let n = typestyleNumber
        return n < typestyleNames.count ? typestyleNames[n] : nil
    }

    /// The RENDERABLE family from the spec typestyle name: `Helv (also Helvetica, CG
    /// Triumvirate, and Swiss)` -> `Helv`. The verbatim name stays in `typestyleName`
    /// (pass-through); this is presentation only, and empty when the table carries no
    /// name for this number. Python's `_font_family` (emit.py), which lives in the
    /// emitter there only because a Python font is a dict.
    public var family: String {
        guard let name = typestyleName else { return "" }
        var out = ""
        let scalars = Array(name.unicodeScalars)
        // Python's `name.split(' (')[0]` — everything before the FIRST " (".
        var i = 0
        while i < scalars.count {
            if scalars[i] == " " && i + 1 < scalars.count && scalars[i + 1] == "(" { break }
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
        return out.trimmed()
    }
}

/// WSFORMAT.TXT, type 0 Header — 128 bytes in total:
///
///     Byte:      version number in BCD (50h = Release 5.0, 55h = 5.5, 60h = 6.0)
///     9 bytes:   null-terminated driver name
///     2 bytes:   reserved
///     2 words:   32-bit pointer to the file's style library
///     107 bytes: reserved
///
/// This block was read as nothing but a driver name (`Document.printerDriver`, still
/// parsed below it). The VERSION BYTE is the more valuable field by far: `detect`
/// INFERS ws4-vs-ws5+ from byte statistics, and the file states its release outright —
/// 78 archive documents say 7.0 and 3 say 6.0. The style-library pointer is what C1
/// proper needs, and 81 documents carry one.
public struct WSHeader: Hashable, Sendable {
    /// The raw BCD byte, when it was one of the recognised releases.
    public let versionBCD: Int?
    /// `versionBCD` rendered as `"7.0"` — the two BCD nybbles, dot-joined.
    public let release: String?
    /// File-absolute offset of the paragraph style library; `nil` when the field is
    /// zero. A pointer equal to the file length is WordStar's "next available offset"
    /// default and means no library — see `parseStyleLibrary`.
    public let styleLibraryOffset: Int?

    public init(versionBCD: Int? = nil, release: String? = nil,
                styleLibraryOffset: Int? = nil) {
        self.versionBCD = versionBCD
        self.release = release
        self.styleLibraryOffset = styleLibraryOffset
    }

    /// Nothing was readable in the block — no version byte, no pointer.
    public var isEmpty: Bool {
        versionBCD == nil && styleLibraryOffset == nil
    }
}

/// A Japanese run: the UNDECODED Shift-JIS that sat between a shift-in and its
/// shift-out, lifted out of the text stream and replaced there by a placeholder.
///
/// Per WSFORMAT.TXT the `0x17` block is a one-byte MODE TOGGLE (1 = into Japanese,
/// 0 = back), not a container of text, so the run is the span BETWEEN two markers.
/// Nothing is lost and no mojibake is presented as text. Register C15.
public struct ShiftRun: Hashable, Sendable {
    public let offset: Int
    public let bytes: [UInt8]
    public init(offset: Int, bytes: [UInt8]) {
        self.offset = offset
        self.bytes = bytes
    }
}

/// A `.tc` table-of-contents entry. `blockIndex` is what lets a consumer resolve the
/// entry to a PAGE after pagination — the text alone cannot, since two chapters can
/// share a title. Register C7.
public struct TOCEntry: Hashable, Sendable {
    public let level: Int
    public let text: String
    public let blockIndex: Int
    public init(level: Int, text: String, blockIndex: Int) {
        self.level = level
        self.text = text
        self.blockIndex = blockIndex
    }
}

/// A `.ix` index entry. Register C6.
public struct IndexEntry: Hashable, Sendable {
    public let text: String
    public let blockIndex: Int
    public init(text: String, blockIndex: Int) {
        self.text = text
        self.blockIndex = blockIndex
    }
}

/// Dot commands that COLLECT an entry rather than set state: `.tc`/`.tc1`-`.tc9`
/// (table of contents), `.ix` (index), `.l#` (line numbering).
///
/// All three were parsed as text and discarded, so a document that asked for a table of
/// contents produced none and said nothing about it. Compiling the finished list is the
/// consumer's job; not losing the entries is this one's. Register C6, C7, C11.
/// Returns a `.fi` filename when the command was one, so the caller can place its
/// marker in document order.
@discardableResult
func parseCollectDot(_ cmd: [UInt8], toc: inout [TOCEntry], index: inout [IndexEntry],
                     lineNumbering: inout Int?, blockIndex: Int) -> String? {
    guard cmd.count >= 3 else { return nil }
    let c1 = asciiUpper(cmd[1]), c2 = asciiUpper(cmd[2])

    if c1 == 0x54 && c2 == 0x43 {                                   // ".TC"
        var k = 3
        var level = 1
        if k < cmd.count, cmd[k] >= 0x31 && cmd[k] <= 0x39 {        // ".tc1".."tc9"
            level = Int(cmd[k] - 0x30)
            k += 1
        }
        if k < cmd.count, cmd[k] == 0x20 { k += 1 }                 // Python's `\s?`
        toc.append(TOCEntry(level: level,
                            text: decodeCP437(rstripASCII(Array(cmd[k...]))),
                            blockIndex: blockIndex))
        return nil
    }
    if c1 == 0x46 && c2 == 0x49 {                                   // ".FI"
        // WSFORMAT.TXT: ".FI  File insert.  Prints the specified file at that point in
        // the document." A whole file the document composes itself from, rendering as
        // NOTHING — the same class already fixed for inset graphics (0x10) and the
        // printer's `%F"NAME"` includes (0x0F), missed here because it is a dot command
        // rather than a block.
        //
        // The file is NOT read: it may not exist, and the spec allows it to be a Lotus
        // worksheet. Saying a file belongs here is the honest half. The CALLER places
        // the marker, so it lands in document order.
        var k = 3
        while k < cmd.count, cmd[k] == 0x20 || cmd[k] == 0x09 { k += 1 }
        var name: [UInt8] = []
        while k < cmd.count, cmd[k] != 0x20, cmd[k] != 0x09, cmd[k] != 0x0D {
            name.append(cmd[k]); k += 1
        }
        if !name.isEmpty { return decodeCP437(name) }
        return nil
    }
    if c1 == 0x49 && c2 == 0x58 {                                   // ".IX"
        var k = 3
        if k < cmd.count, cmd[k] == 0x20 { k += 1 }
        index.append(IndexEntry(text: decodeCP437(rstripASCII(Array(cmd[k...]))),
                                blockIndex: blockIndex))
        return nil
    }
    if c1 == 0x4C && cmd[2] == 0x23 {                               // ".L#"
        // `.l# 0` turns line numbering OFF; any other number is the interval.
        guard let (value, _) = parseDotNumber(Array(cmd.dropFirst(3))), value.isFinite
        else { return nil }
        lineNumbering = Int(value) > 0 ? Int(value) : nil
    }
    return nil
}

private func rstripASCII(_ b: [UInt8]) -> [UInt8] {
    var e = b.count
    while e > 0, b[e - 1] == 0x20 || b[e - 1] == 0x09 || b[e - 1] == 0x0D { e -= 1 }
    return Array(b[..<e])
}

/// Python's `bytes.split()` with no argument: split on runs of ASCII whitespace, dropping
/// empty fields (including leading and trailing ones).
private func splitOnDotSpace(_ b: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in b {
        if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            || byte == 0x0B || byte == 0x0C {
            if !current.isEmpty { out.append(current); current = [] }
        } else {
            current.append(byte)
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}
