/// WSCHANGE .PAT interpreter: WordStar 7's saved-installation-patch format. Port of
/// `wschange.py` (task #22).
///
/// WSCHANGE (WordStar's installer/customiser) can dump the machine's current patch state
/// to a `.PAT` file and re-apply one later. Those dumps are the closest thing that
/// exists to a WordStar user's "settings file", and the Sawyer archive carries seven of
/// them — two full 294-line dumps (factory and Sawyer's own machine) plus five partial
/// patch sets. The byte-level decode this module implements lives in the project's
/// INIEDT-full-decode reading (hereafter "the decode doc"), which mapped the INIEDT
/// struct and the RLRINI ruler table field-by-field against PATCH.LST's own assembly
/// listing and sanity-checked every value against the WS7 factory defaults.
///
/// The format (decode doc, Method item 2 — learned the hard way there): `.PAT` files are
/// NOT raw memory dumps at PATCH.LST addresses. They are CRLF text: one line per named
/// patch variable, `LABEL=hh,hh,...` with comma-separated hex byte pairs, long values
/// wrapped across continuation lines that start with a bare `=`. Items can also be
/// double-quoted ASCII strings (`NOTYPE="BAK"` — literal bytes, observed in NOTYPE.PAT;
/// no quoted item in the corpus contains a comma or an embedded quote, but commas inside
/// quotes are honoured anyway since splitting there would be silent corruption). Files
/// are padded to sector size with DOS ^Z (0x1A).
///
/// This is library-only plumbing for the machine layer of the page model: document dot
/// commands > machine settings > WordStar factory (`effectivePage`). The 'sawyer' preset
/// in the CLI was hand-derived from these very bytes; `patPageSettings` below re-derives
/// it mechanically, and the tests hold the two against each other. Taps stay off per the
/// ruling: no CLI wiring until real import cases appear.

/// A `.PAT` line this parser cannot read — which means the file is not a .PAT, and
/// guessing would corrupt a byte-level mapping silently. Python raises `ValueError`.
public struct PATError: Error, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Split one line's value part on commas, except inside double quotes. A quoted item is
/// literal ASCII bytes; a comma in one is content. Port of `_split_items`.
private func splitPATItems(_ rest: [UInt8]) -> [[UInt8]] {
    var items: [[UInt8]] = []
    var cur: [UInt8] = []
    var inQuote = false
    for ch in rest {
        if ch == 0x22 {                       // '"'
            inQuote.toggle()
            cur.append(ch)
        } else if ch == 0x2C, !inQuote {      // ','
            items.append(cur)
            cur = []
        } else {
            cur.append(ch)
        }
    }
    items.append(cur)
    return items
}

private func rstripPAT(_ line: ArraySlice<UInt8>) -> [UInt8] {
    var out = Array(line)
    while let last = out.last, last == 0x0D || last == 0x09 || last == 0x20 {
        out.removeLast()
    }
    return out
}

private func stripPAT(_ item: [UInt8]) -> [UInt8] {
    var out = item
    while let first = out.first, first == 0x20 || first == 0x09 { out.removeFirst() }
    while let last = out.last, last == 0x20 || last == 0x09 { out.removeLast() }
    return out
}

private func hexNibble(_ b: UInt8) -> Int? {
    switch b {
    case 0x30...0x39: return Int(b - 0x30)
    case 0x41...0x46: return Int(b - 0x41 + 10)
    case 0x61...0x66: return Int(b - 0x61 + 10)
    default: return nil
    }
}

/// Parse a WSCHANGE `.PAT` dump into `[label: reassembled value bytes]`. Port of
/// `parse_pat`.
///
/// The mapping holds every label (a PARTIAL patch set simply yields a small dictionary —
/// subset semantics by construction). A repeated label RESTARTS its value, last
/// occurrence winning: both full dumps in the archive really do carry `UDATE` twice
/// (lines 1 and 559, identical bytes both times — WSCHANGE stamps the dump date at both
/// ends), which is also why "294 labels" in the decode doc is 293 unique names here.
///
/// Tolerated: LF-only line ends, trailing whitespace, blank lines, empty continuation
/// lines (`=` alone — the full dumps end PRNID with one), trailing commas, and DOS ^Z
/// padding (everything from the first 0x1A is discarded — these are text files, so a
/// bare 0x1A can only be the DOS EOF convention). Anything else throws `PATError` naming
/// the line.
public func parsePAT(_ data: [UInt8]) throws -> [String: [UInt8]] {
    var data = data
    if let eof = data.firstIndex(of: 0x1A) {
        data = Array(data[..<eof])
    }
    var out: [String: [UInt8]] = [:]
    var last: String? = nil
    var lineno = 0
    for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
        lineno += 1
        let line = rstripPAT(raw)
        if line.isEmpty { continue }
        guard let eq = line.firstIndex(of: 0x3D) else {   // '='
            let head = String(decoding: line.prefix(40), as: UTF8.self)
            throw PATError(".PAT line \(lineno): no \"=\" in '\(head)'")
        }
        let label = Array(line[..<eq])
        let rest = Array(line[(eq + 1)...])
        var vals: [UInt8] = []
        for rawItem in splitPATItems(rest) {
            let item = stripPAT(rawItem)
            if item.isEmpty { continue }                  // trailing comma / bare '='
            if item.count >= 2, item.first == 0x22, item.last == 0x22 {
                vals += item.dropFirst().dropLast()       // quoted literal ASCII
                continue
            }
            let byte: Int?
            if item.count == 1, let lo = hexNibble(item[0]) {
                byte = lo
            } else if item.count == 2, let hi = hexNibble(item[0]),
                      let lo = hexNibble(item[1]) {
                byte = hi * 16 + lo
            } else {
                byte = nil
            }
            guard let byte else {
                let text = String(decoding: item, as: UTF8.self)
                throw PATError(".PAT line \(lineno): bad hex item '\(text)'")
            }
            vals.append(UInt8(byte))
        }
        if !label.isEmpty {
            guard label.allSatisfy({ $0 < 0x80 }) else {
                throw PATError(".PAT line \(lineno): non-ASCII label")
            }
            let name = String(decoding: label, as: UTF8.self)
            out[name] = vals
            last = name
        } else {
            guard let last else {
                throw PATError(".PAT line \(lineno): continuation before any label")
            }
            out[last]! += vals
        }
    }
    return out
}

// ---------------------------------------------------------------- INIEDT

// INIEDT struct offsets, RELATIVE to the block start (PATCH.LST base 0x1219, 68 bytes,
// INISIZ assembler-enforced — decode doc field map). All are LE16. Every field below is
// marked DOCUMENTED in the doc; the flagged/INFERRED fields (page-number placement,
// font/typestyle quad) are deliberately NOT interpreted here.
//
//   doc addr  rel    field                              units
private let mtOff = 0x122D - 0x1219    // 0x14  top margin (.mt)           1/1440 in
private let mbOff = 0x122F - 0x1219    // 0x16  bottom margin (.mb)        1/1440 in
private let plOff = 0x1231 - 0x1219    // 0x18  page length (.pl)          1/1440 in
private let hmOff = 0x1238 - 0x1219    // 0x1F  heading margin (.hm)       1/1440 in
private let fmOff = 0x123A - 0x1219    // 0x21  footing margin (.fm)       1/1440 in
private let poEvenOff = 0x123D - 0x1219   // 0x24  page offset, even pages (.po)  1/1800 in
private let poOddOff = 0x123F - 0x1219    // 0x26  page offset, odd pages  (.po)  1/1800 in
private let lhOff = 0x1259 - 0x1219    // 0x40  line height (.lh)          1/1440 in

/// LE16 at `off`, or nil when the block is too short to carry it — a truncated INIEDT
/// yields the fields it has rather than a guess. Port of `_le16`.
private func patLE16(_ block: [UInt8], _ off: Int) -> Int? {
    guard block.count >= off + 2 else { return nil }
    return Int(block[off]) | (Int(block[off + 1]) << 8)
}

/// Interpret a parsed dump's INIEDT block into the page-geometry keys `effectivePage`'s
/// machine layer consumes: `mt_lines`/`mb_lines`/`pl_lines`/`hm_lines`/`fm_lines`
/// (lines at 6 LPI), `po_cols` (10-CPI print columns), `lh_48` (1/48in units) — the
/// project's native units throughout. Port of `page_settings`; a dictionary because
/// Python's is (the machine layer plugs keys in generically, and taps are off).
///
/// Unit conversions (decode doc: VMI = 1/1440 in, confirmed by PATCH.LST's own 1440/6
/// idiom; HMI = 1/1800 in, PATCH.LST line 2613):
///   1440ths -> lines at 6 LPI:  /1440 * 6   (720 -> 3.0, the .mt factory)
///   1800ths -> 10-CPI columns:  /1800 * 10  (1440 -> 8.0, the .po factory)
///   1440ths -> 48ths:           /1440 * 48  (240 -> 8.0, the .lh factory)
///
/// `.po` is stored TWICE (even/odd pages, a duplexing refinement the dot command does
/// not have); both files in the archive hold them equal, and the page model has one
/// `po_cols`, so the even-page value is used — an odd-page value that differed would be
/// dropped here, accepted as the model's limitation rather than papered over.
///
/// A dump with no INIEDT label (four of the five partial patch sets) returns `[:]` —
/// "this machine says nothing about page geometry", which the machine layer treats as
/// no overrides at all.
public func patPageSettings(_ pat: [String: [UInt8]]) -> [String: Double] {
    guard let ie = pat["INIEDT"] else { return [:] }
    var out: [String: Double] = [:]
    let fields: [(key: String, off: Int, perUnit: Double)] = [
        ("mt_lines", mtOff, 6.0 / 1440.0),
        ("mb_lines", mbOff, 6.0 / 1440.0),
        ("pl_lines", plOff, 6.0 / 1440.0),
        ("hm_lines", hmOff, 6.0 / 1440.0),
        ("fm_lines", fmOff, 6.0 / 1440.0),
        ("po_cols", poEvenOff, 10.0 / 1800.0),
        ("lh_48", lhOff, 48.0 / 1440.0),
    ]
    for field in fields {
        if let raw = patLE16(ie, field.off) {
            out[field.key] = Double(raw) * field.perUnit
        }
    }
    return out
}

// ---------------------------------------------------------------- RLRINI

// RLRINI: ten 74-byte ruler records (.RR 0 - .RR 9) + 1 reserved byte = 741, matching
// the .PAT block's byte count exactly (decode doc, PATCH.LST 0x1263-0x1547). Record
// layout, offsets within a record:
private let rrSize = 74
private let rrNTabsOff = 0x08          // 1 byte   number of tab stops in table
private let rrTabsOff = 0x0A           // 25 x LE16 tab positions, ascending, HMI
private let rrMaxTabs = 25

/// Default tab stops from RLRINI's `.RR 0` record (the primary default ruler), as
/// 10-CPI print columns — the same unit `.po` and the margin fields use everywhere.
/// Factory decode: 11 stops every 900 HMI = every 5 columns, [5.0, 10.0, ... 55.0],
/// which reproduces the WS7 manual's stated tab defaults exactly (decode doc:
/// DOCUMENTED, high confidence — and byte-identical in both full dumps; Sawyer never
/// touched his ruler defaults). Port of `ruler_tabs`.
///
/// Positions only: the record also carries a decimal-tab COUNT (+0x09), but the doc
/// does not map WHICH entries are decimal, so that distinction is not invented here —
/// future `.tb` work that needs it has to extend the decode first. Missing/short
/// RLRINI returns [].
public func patRulerTabs(_ pat: [String: [UInt8]]) -> [Double] {
    guard let rl = pat["RLRINI"], rl.count >= rrSize else { return [] }
    let rr0 = Array(rl[..<rrSize])
    let n = min(Int(rr0[rrNTabsOff]), rrMaxTabs)
    var tabs: [Double] = []
    for i in 0..<n {
        let hmi = Int(rr0[rrTabsOff + 2 * i]) | (Int(rr0[rrTabsOff + 2 * i + 1]) << 8)
        if hmi == 0 { continue }              // unused entries are 0 (doc)
        tabs.append(Double(hmi) * 10.0 / 1800.0)
    }
    return tabs
}
