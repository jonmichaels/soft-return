/// The paragraph style library (WS5.5+): the styles a document carries at its end,
/// reached via the type 0 header block's 32-bit pointer. Direct port of
/// `_parse_style_library` (Python ctrl-kd, core.py). Register C1.

/// One style's 102-byte record. Every field is `nil` when the record's own sentinel says
/// "inherit" — the caller falls back to the running dot-command state rather than
/// substituting a fabricated default.
public struct StyleRecord: Hashable, Sendable {
    /// The record's own font triple: width (HMI, 1/1800in), height (VMI, 1/1440in) and
    /// typestyle word — the same three fields, in the same order, as a type 2 font block.
    /// `nil` when word 0 is the -1 inherit sentinel.
    public let font: (width: Int, height: Int, typestyle: Int)?
    /// Margins in HMI (1/1800in). Sentinel: -2 (0xFFFE).
    public let leftMarginHMI: Int?
    public let rightMarginHMI: Int?
    public let paraMarginHMI: Int?
    /// Tab stops in HMI. `nil` when EITHER count byte reads 0xFF — see the parser: the
    /// 32-word array then holds stale bytes from prior edit state and must never be read.
    public let tabsHMI: [Int]?
    /// How many of `tabsHMI` are decimal tabs; `nil` alongside an inherited tab array.
    public let decimalTabs: Int?
    /// The justification byte mapped to the spec's own vocabulary; `nil` when inherited
    /// (-1) or when the byte is a value the spec does not name. `justificationRaw` keeps
    /// the byte either way, so nothing is dropped.
    public let justification: StyleJustification?
    /// The raw signed justification byte; `nil` only for the -1 inherit sentinel.
    public let justificationRaw: Int?
    public let wordWrap: Bool?
    /// Line height in VMI (1/1440in). Sentinel: -1.
    public let lineHeightVMI: Int?
    public let lineSpacing: Int?
    /// The print attributes this style turns on / off, as the spec's own bit words.
    public let attrsOn: Int
    public let attrsOff: Int
    /// Palette index. Sentinel: -1.
    public let colour: Int?

    public init(
        font: (width: Int, height: Int, typestyle: Int)? = nil,
        leftMarginHMI: Int? = nil, rightMarginHMI: Int? = nil, paraMarginHMI: Int? = nil,
        tabsHMI: [Int]? = nil, decimalTabs: Int? = nil,
        justification: StyleJustification? = nil, justificationRaw: Int? = nil,
        wordWrap: Bool? = nil, lineHeightVMI: Int? = nil, lineSpacing: Int? = nil,
        attrsOn: Int = 0, attrsOff: Int = 0, colour: Int? = nil
    ) {
        self.font = font
        self.leftMarginHMI = leftMarginHMI
        self.rightMarginHMI = rightMarginHMI
        self.paraMarginHMI = paraMarginHMI
        self.tabsHMI = tabsHMI
        self.decimalTabs = decimalTabs
        self.justification = justification
        self.justificationRaw = justificationRaw
        self.wordWrap = wordWrap
        self.lineHeightVMI = lineHeightVMI
        self.lineSpacing = lineSpacing
        self.attrsOn = attrsOn
        self.attrsOff = attrsOff
        self.colour = colour
    }

    // `font` is a tuple, which is not `Equatable`/`Hashable` for free.
    public static func == (a: StyleRecord, b: StyleRecord) -> Bool {
        a.font?.width == b.font?.width && a.font?.height == b.font?.height
            && a.font?.typestyle == b.font?.typestyle
            && (a.font == nil) == (b.font == nil)
            && a.leftMarginHMI == b.leftMarginHMI && a.rightMarginHMI == b.rightMarginHMI
            && a.paraMarginHMI == b.paraMarginHMI && a.tabsHMI == b.tabsHMI
            && a.decimalTabs == b.decimalTabs && a.justification == b.justification
            && a.justificationRaw == b.justificationRaw && a.wordWrap == b.wordWrap
            && a.lineHeightVMI == b.lineHeightVMI && a.lineSpacing == b.lineSpacing
            && a.attrsOn == b.attrsOn && a.attrsOff == b.attrsOff && a.colour == b.colour
    }

    public func hash(into h: inout Hasher) {
        h.combine(font?.width); h.combine(font?.height); h.combine(font?.typestyle)
        h.combine(leftMarginHMI); h.combine(rightMarginHMI); h.combine(paraMarginHMI)
        h.combine(tabsHMI); h.combine(decimalTabs); h.combine(justification)
        h.combine(justificationRaw); h.combine(wordWrap); h.combine(lineHeightVMI)
        h.combine(lineSpacing); h.combine(attrsOn); h.combine(attrsOff); h.combine(colour)
    }
}

/// The spec's justification vocabulary: "0 means no justification, -1 inherit, 1 right
/// justified, -2 centered, -3 flush right."
public enum StyleJustification: String, Hashable, Sendable {
    case none
    case right
    case center
    case flushright
}

/// One library entry: its name, and the 102-byte record where the index item says one
/// exists. An entry with no record is the inherit-everything base (`WordStar Defaults`),
/// which is a real, selectable style — it contributes no formatting of its own.
public struct StyleEntry: Hashable, Sendable {
    public let name: String
    /// 0-based position in ALLOCATION ORDER, deleted slots counted — exactly what a 0x11
    /// handle's low byte indexes.
    public let slot: Int
    public let record: StyleRecord?

    public init(name: String, slot: Int = 0, record: StyleRecord? = nil) {
        self.name = name
        self.slot = slot
        self.record = record
    }
}

/// Heading level from a RESOLVED style name — never from the handle's slot number, which
/// the corpus proved carries no semantics (NOVEL.WS's real H1/H2/H3 styles sat at slots
/// 4/10/8 while its footer style was being rendered as a heading).
///
/// HEURISTIC tiers, drawn from the archive's own style names: exact H1/H2/H3; 'chapter
/// title' / trailing 'Title' -> 1 (MS Chapter Title); 'subhead' / 'section heading' -> 2
/// (MS Subhead, Section Heading Font). Everything else is a non-heading style: the block
/// still carries `styleName` for consumers with better taxonomy.
public func styleHeadingLevel(_ name: String) -> Int {
    let n = asciiLowercased(name.trimmed())
    if n == "h1" { return 1 }
    if n == "h2" { return 2 }
    if n == "h3" { return 3 }
    if n.contains("chapter title") || n.hasSuffix(" title") || n == "title" { return 1 }
    if n.contains("subhead") || n.contains("section heading") { return 2 }
    return 0
}

/// Python's `str.lower()` restricted to ASCII — the style names this compares against are
/// ASCII, and a full Unicode case fold is Foundation's job, not this library's.
private func asciiLowercased(_ s: String) -> String {
    var view = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if scalar.value >= 0x41 && scalar.value <= 0x5A {
            view.append(Unicode.Scalar(scalar.value + 0x20)!)
        } else {
            view.append(scalar)
        }
    }
    return String(view)
}

/// Parse the paragraph style library at file-absolute offset `base`.
///
/// Layout per WSFORMAT.TXT ("Paragraph style library"), every field validated
/// corpus-wide 2026-08-04 (21 documents carrying a library: 194/194 index entries,
/// 59/59 style records, zero decode errors):
///
///     master index header (13 bytes at base):
///       1A 55, word next-512-block, byte n_objects, word n_alloc,
///       word entry_size (102), dword object-index ptr (base-relative, obs. 13)
///     object index blocks (chainable):
///       byte n_entries, dword next-block link (base-relative, 0 = none), items
///     index item, STRIDE 33 -- the spec's own field list sums to 24+1+2+2+4;
///     rounding it to 32 desyncs every entry after the first, which is exactly the
///     "some entries decode as garbage" symptom the first attempt hit:
///       24 bytes name (blank-filled; 24 x 0x3F = unused/deleted slot),
///       byte flag (observed 0x02 = has record, 0x00 = none, 194/194),
///       2 words internal, dword style-record ptr (base-relative, 0 = none)
///     style record (102 bytes): see the field reads below.
///
/// Inheritance sentinels, AS OBSERVED against the spec's prose: margins -2 (0xFFFE);
/// font word 0, line height, justification, wrap, spacing, colour -1; tab COUNTS are
/// 0xFF when inherited (the spec says 0, the corpus says 0xFF, 56/118 fields) — and when
/// the count byte says inherited the 32-word tab array holds STALE bytes from prior edit
/// state and must not be read; gate on the count byte only.
///
/// A pointer equal to the file length is WordStar's "next available offset" default for
/// documents that never defined a style — not an error, just no library (56 of 85 corpus
/// documents).
public func parseStyleLibrary(_ raw: [UInt8], base: Int) -> [StyleEntry] {
    var styles: [StyleEntry] = []
    guard base > 0, base <= raw.count - 13, raw[base] == 0x1A, raw[base + 1] == 0x55 else {
        return styles
    }

    func word(_ off: Int) -> Int {
        Int(raw[off]) | (Int(raw[off + 1]) << 8)
    }
    /// A signed 16-bit LE read — Python's `int.from_bytes(..., signed=True)`.
    func sword(_ off: Int) -> Int {
        let u = word(off)
        return u >= 0x8000 ? u - 0x10000 : u
    }
    /// A signed 8-bit read.
    func sbyte(_ off: Int) -> Int {
        let u = Int(raw[off])
        return u >= 0x80 ? u - 0x100 : u
    }
    func swordNone(_ off: Int, sentinel: Int) -> Int? {
        let v = sword(off)
        return v == sentinel ? nil : v
    }

    let nAlloc = word(base + 5)
    let entrySize = word(base + 7)
    var blockOff = base + (word(base + 9) | (word(base + 11) << 16))
    var seenBlocks: Set<Int> = []
    var walked = 0
    // `seenBlocks` is not tidiness: the object-index blocks are a LINKED LIST read out of
    // a file that may be truncated or corrupt, and a self-referential link would spin
    // forever.
    while blockOff != 0, base <= blockOff, blockOff <= raw.count - 5,
          !seenBlocks.contains(blockOff) {
        seenBlocks.insert(blockOff)
        let nHere = Int(raw[blockOff])
        let link = word(blockOff + 1) | (word(blockOff + 3) << 16)
        var item = blockOff + 5
        for _ in 0..<nHere {
            if walked >= nAlloc || item + 33 > raw.count { break }
            let nameRaw = Array(raw[item..<(item + 24)])
            let flag = raw[item + 24]
            let sptr = word(item + 29) | (word(item + 31) << 16)
            item += 33
            walked += 1
            if nameRaw.allSatisfy({ $0 == 0x3F }) { continue }   // unused/deleted slot
            let name = decodeCP437(nameRaw).trimmedTrailing()
            var record: StyleRecord? = nil
            let rec = base + sptr
            if flag == 0x02, sptr != 0, rec + entrySize <= raw.count {
                let f0 = sword(rec)
                let font: (width: Int, height: Int, typestyle: Int)? =
                    f0 == -1 ? nil : (word(rec), word(rec + 2), word(rec + 4))
                let nReg = raw[rec + 18], nDec = raw[rec + 19]
                var tabs: [Int]? = nil
                var decimalTabs: Int? = nil
                if nReg != 0xFF && nDec != 0xFF {
                    let nTabs = Swift.min(Int(nReg) + Int(nDec), 32)
                    tabs = (0..<nTabs).map { word(rec + 20 + 2 * $0) }
                    decimalTabs = Int(nDec)
                }
                // else: inherited, and the array is STALE — never read it.
                let just = sbyte(rec + 86)
                let justification: StyleJustification? = [
                    0: StyleJustification.none, 1: .right, -2: .center, -3: .flushright,
                ][just]
                let wrapByte = sbyte(rec + 87)
                let ls = sbyte(rec + 90)
                record = StyleRecord(
                    font: font,
                    leftMarginHMI: swordNone(rec + 10, sentinel: -2),
                    rightMarginHMI: swordNone(rec + 12, sentinel: -2),
                    paraMarginHMI: swordNone(rec + 14, sentinel: -2),
                    tabsHMI: tabs,
                    decimalTabs: decimalTabs,
                    justification: just == -1 ? nil : justification,
                    justificationRaw: just == -1 ? nil : just,
                    wordWrap: wrapByte == -1 ? nil : wrapByte != 0,
                    lineHeightVMI: swordNone(rec + 88, sentinel: -1),
                    lineSpacing: ls == -1 ? nil : ls,
                    attrsOn: word(rec + 91),
                    attrsOff: word(rec + 93),
                    colour: sbyte(rec + 95) == -1 ? nil : sbyte(rec + 95))
            }
            styles.append(StyleEntry(name: name, slot: walked - 1, record: record))
        }
        blockOff = link != 0 ? base + link : 0
    }
    return styles
}
