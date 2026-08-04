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

    /// Everything stamped onto a `Block` when it opens. A change to ANY of these has to
    /// close the current block, because a single block cannot hold two values of it:
    /// `.oc on` mid-paragraph means the lines after it are centred and the ones before
    /// are not, and `.lm 5` mid-paragraph means the same about the indent.
    var blockFormat: BlockFormat {
        BlockFormat(align: alignment, wrap: wrap ?? true, leftMargin: leftMargin,
                    rightMargin: rightMargin, paraMargin: paraMargin,
                    columns: columns, columnGutter: columnGutter)
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

    public init(underlineBlanks: Bool? = nil, suppressBlanks: Bool? = nil,
                proportional: Bool? = nil, kerning: Bool? = nil,
                orientation: Orientation? = nil, subSuperRoll48: Double? = nil,
                endnotesHere: Bool? = nil, convertNotes: [String] = [],
                autoPageNumbers: Bool? = nil) {
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
    guard let (name, arg) = dotCommandNameAndArg(cmd) else { return }
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
    case "LM", "RM", "PM":
        // Print columns at 10 CPI, matching `.po`; a unit suffix converts, since the
        // archive writes both `.rm 65` and `.rm 6.5"`.
        guard let (value, unit) = parseDotNumber(arg), value.isFinite else { return }
        let cols = resolveColsArg(value, unit)
        switch String(decoding: name.map(asciiUpper), as: UTF8.self) {
        case "LM": state.leftMargin = cols
        case "RM": state.rightMargin = cols
        default: state.paraMargin = cols
        }
    case "CO":
        // `.co <n>, <gutter>` — the archive writes `.co2, 0.3"`, `.CO3,  .20"` and
        // `.co1` (one column = columns off). Stateful like the margins. Register C5.
        guard let (n, _) = parseDotNumber(arg), n.isFinite else { return }
        state.columns = Swift.max(1, Int(n))
        // The gutter follows a comma; a bare figure is columns like `.po`, and the
        // archive's own values carry an inch mark, which converts.
        var rest = trimmed(arg)
        var k = 0
        while k < rest.count, rest[k] != 0x2C { k += 1 }          // ','
        if k < rest.count {
            rest = Array(rest[(k + 1)...])
            if let (g, unit) = parseDotNumber(rest), g.isFinite {
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

/// A colour change (symmetric type 0x01): palette INDICES, not RGB. Recorded, not
/// rendered — the printed page this project reproduces was monochrome. Register C2.
public struct ColourChange: Hashable, Sendable {
    public let offset: Int
    public let foreground: Int
    public let background: Int
    public init(offset: Int, foreground: Int, background: Int) {
        self.offset = offset
        self.foreground = foreground
        self.background = background
    }
}

/// A font change (symmetric type 0x02/0x15). `height20thPt` is the type size in 1/20
/// point — 180 = 9pt — which is the part a modern renderer can actually use;
/// `driverBytes` identify the face to a 1987 printer and mean nothing without it. C3.
public struct FontChange: Hashable, Sendable {
    public let offset: Int
    public let height20thPt: Int
    public let width20thPt: Int
    public let driverBytes: [UInt8]
    public init(offset: Int, height20thPt: Int, width20thPt: Int, driverBytes: [UInt8]) {
        self.offset = offset
        self.height20thPt = height20thPt
        self.width20thPt = width20thPt
        self.driverBytes = driverBytes
    }
    /// The size in points, which is what an emitter wants.
    public var points: Double { Double(height20thPt) / 20.0 }
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
