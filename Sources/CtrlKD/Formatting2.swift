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

    /// The alignment in force.
    var alignment: Alignment {
        if centering == true { return .center }
        return justify ?? .left
    }
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

    public init(underlineBlanks: Bool? = nil, suppressBlanks: Bool? = nil,
                proportional: Bool? = nil, kerning: Bool? = nil,
                orientation: Orientation? = nil, subSuperRoll48: Double? = nil) {
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
