/// Synthetic byte-fixture builders, ported from `tests/test_ctrlkd.py` in the Python
/// reference. All fixtures are built byte-by-byte here — no real WordStar files are
/// shipped with the port.
@testable import CtrlKD

let SOFT: [UInt8] = [0x8d, 0x0a]
let HARD: [UInt8] = [0x0d, 0x0a]

/// WS4 sets bit 7 on the last character of each word ("microjustify" flags).
func ws4Word(_ w: String) -> [UInt8] {
    var bytes = Array(w.utf8)
    guard !bytes.isEmpty else { return bytes }
    bytes[bytes.count - 1] |= 0x80
    return bytes
}

func ws4Text(_ s: String) -> [UInt8] {
    let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var out: [UInt8] = []
    for (i, w) in words.enumerated() {
        if i > 0 { out.append(0x20) }
        out.append(contentsOf: ws4Word(w))
    }
    return out
}

func bytes(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

extension String {
    /// Stand-in for Python's `str.strip()` in test assertions ported from the Python
    /// suite, which lean on it for leading/trailing whitespace.
    func trimmed() -> String {
        var scalars = Array(unicodeScalars)
        let isSpace: (Unicode.Scalar) -> Bool = {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.value == 0x0B || $0.value == 0x0C
        }
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isSpace(l) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// Two paragraphs; the first wraps twice at a 65 margin (long lines), the second short.
/// Mirrors `make_prose()` in the Python tests.
func makeProse() -> [UInt8] {
    let l1 = bytes(String(repeating: "x", count: 55) + " words")      // 61 chars, wrapped
    let l2 = bytes(String(repeating: "y", count: 50) + " continuing") // 61 chars, wrapped
    let l3 = bytes("ends here.")
    let p2 = bytes("Second paragraph.")
    return l1 + SOFT + l2 + SOFT + l3 + SOFT + HARD + SOFT + p2 + HARD
}

/// A WS5+/WS7 1D symmetric block: `\x1d`, a little-endian 16-bit count, the command
/// byte, the payload, then the SAME count repeated and a closing `\x1d` — genuinely
/// symmetric (hence the name), matching Python's `ws7_block` test helper exactly
/// (count = len(payload) + 4: cmd(1) + payload(len) + count-again(2) + closing 0x1d(1),
/// i.e. everything the leading count must skip over to reach the next real block).
///
/// The previous version of this helper omitted the trailing count+`\x1d` entirely —
/// harmless for the old (now-replaced) note-text extraction, which never trusted a
/// block's trailing bytes, but wrong for the real `_parse_note` port in
/// `SymmetricBlocks.swift`, which slices `block[3..<(count-3)]` assuming that trailing
/// self-reference genuinely occupies the last 3 bytes. Without it, `parseNote` would
/// silently truncate the last 3 bytes of real note text.
func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
    let count = UInt16(payload.count + 4)
    let countBytes: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    return [0x1d] + countBytes + [cmd] + payload + countBytes + [0x1d]
}

/// One footnote/endnote/annotation/comment note block (types 3-6), per the WordStar
/// 7.0 file format spec: line count, note number (embedded directly — tag-word high
/// bit clear), conversion flag (high nybble = numbering format, low nybble =
/// convert-to type), then the note text. Direct port of Python's `ws7_note` test
/// helper (ctrl-kd 1.2.0) — the correct shape `SymmetricBlocks.swift`'s `parseNote`
/// expects, replacing this file's previous synthetic (and spec-incorrect) 17-zero-byte
/// approximation of the pre-1.2.0 Python implementation.
func ws7Note(
    _ text: [UInt8],
    cmd: UInt8 = 0x03,
    number: Int = 1,
    lineCount: Int = 1,
    numberFormat: Int = 3,
    convertTo: Int = 0
) -> [UInt8] {
    let convFlag = UInt8(((numberFormat & 0x0F) << 4) | (convertTo & 0x0F))
    var content: [UInt8] = [
        UInt8(lineCount & 0xFF), UInt8((lineCount >> 8) & 0xFF),
        UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF),
        convFlag,
    ]
    content.append(contentsOf: text)
    return ws7Block(cmd, payload: content)
}

/// One WordStar annotation (symmetrical-sequence type 5), shaped like a real WS7 one:
/// its OWN text embeds one or more dot-command lines (a ruler, a `..` comment —
/// WordStar notes can carry these same as the body can), followed by a nested tag
/// sequence whose remaining bytes are a display TEXT string (not a number — that's
/// footnote/endnote-only), followed by the real annotation text. The conversion-flag
/// byte is documented "not used" for annotations, so it's deliberately junk here to
/// prove it's ignored rather than misreported. Direct port of Python's
/// `ws7_annotation_with_tag` test helper (ctrl-kd 1.2.0).
func ws7AnnotationWithTag(
    dotLines: [[UInt8]],
    text: [UInt8],
    tagText: [UInt8],
    junkConvFlag: UInt8 = 0x05
) -> [UInt8] {
    let tagContent: [UInt8] = [0x00, 0x00, 0x00, 0x00, junkConvFlag] + tagText
    let tag = ws7Block(0x05, payload: tagContent)
    var body: [UInt8] = []
    for (i, line) in dotLines.enumerated() {
        if i > 0 { body += HARD }
        body += line
    }
    body += HARD + tag + bytes(" ") + text + HARD
    let content: [UInt8] = [0x01, 0x00, 0x00, 0x80, junkConvFlag] + body
    return ws7Block(0x05, payload: content)
}

/// One synthetic WS7 document carrying all four note kinds — footnote, endnote,
/// annotation, and comment — so a single fixture exercises the real mix a WS7 file has.
/// Direct port of Python's `four_kind_data()` test helper (ctrl-kd 1.2.0). `number: 0`
/// for the footnote/endnote: WS7's own storage is a 0-based index (WordStar itself
/// displays it as 1).
func fourKindData() -> [UInt8] {
    ws7Block(0x00)
        + bytes("one ") + ws7Note(bytes("Footnote text."), cmd: 0x03, number: 0)
        + bytes(" two ") + ws7Note(bytes("Endnote text."), cmd: 0x04, number: 0)
        + bytes(" three ") + ws7AnnotationWithTag(
            dotLines: [bytes(".. remark")], text: bytes("Annotation text"), tagText: bytes("AC1"))
        + bytes(" four ") + ws7Note(bytes("Comment text."), cmd: 0x06, number: 0)
        + bytes(" five") + HARD
}

// MARK: - Reading PDF bytes back in assertions
//
// Shared here rather than kept private to one file: job-013's exact-fill tests need the same
// three, and a second copy of `countOccurrences` is a second thing to get wrong.

/// Latin-1 decode — the inverse of `esc`'s encoding, so a PDF reads as text in an assertion.
/// Every byte maps to the scalar of the same value, so this never fails and never merges
/// bytes into one Character the way a UTF-8 decode would.
func latin1(_ bytes: [UInt8]) -> String {
    String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
}

func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    countOccurrences(of: needle, in: haystack) > 0
}

/// Python's `bytes.count` — non-overlapping occurrences.
func countOccurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    var i = 0
    while i <= haystack.count - needle.count {
        if Array(haystack[i..<(i + needle.count)]) == needle {
            count += 1
            i += needle.count
        } else {
            i += 1
        }
    }
    return count
}

/// One WS5+ symmetric sequence, with REAL framing: `1D <jump:LE16> <cmd> <content>
/// <jump:LE16> 1D`. The sequence is BRACKETED BY ITS OWN LENGTH — that is what makes it
/// "symmetric", and it is exactly what hand-built fixtures kept getting wrong before
/// ctrl-kd's `tools/ws_fixture.py` (whose self-test checks this framing byte-for-byte
/// against real WordStar output) settled it.
///
/// `jump` counts the command byte, the content, and the 3-byte close, so the parser's
/// `data[i+1 ..< i+3+jump]` slice lands exactly on the closing bracket.
func wsBlock(cmd: UInt8, content: [UInt8] = []) -> [UInt8] {
    let jump = content.count + 4
    let lo = UInt8(jump & 0xFF), hi = UInt8((jump >> 8) & 0xFF)
    return [0x1D, lo, hi, cmd] + content + [lo, hi, 0x1D]
}

// MARK: - Paragraph style library

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: Int) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

/// A 102-byte style record per WSFORMAT's field list (validated corpus-wide 2026-08-04:
/// 59/59 records). Inheritance sentinels: margins -2, most others -1 — and tab COUNTS are
/// 0xFF when inherited (the spec's prose says 0; the corpus says 0xFF, 56/118 fields),
/// with the 32-word tab array then holding STALE bytes that must not be read. Port of
/// Python's `_style_record` test helper.
func styleRecord(left: Int = 1800, tabs: [Int] = [900, 1800], decimalTabs: Int = 0,
                 just: Int = 0, inheritTabs: Bool = false,
                 attrsOn: Int = 0b1000000) -> [UInt8] {
    var rec = [UInt8](repeating: 0, count: 102)
    func put(_ off: Int, _ b: [UInt8]) { for (k, v) in b.enumerated() { rec[off + k] = v } }
    put(0, le16(0xFFFF))                          // font: inherited
    put(10, le16(left))                           // left margin HMI
    put(12, le16(0xFFFE))                         // right: inherited
    put(14, le16(0xFFFE))                         // para: inherited
    if inheritTabs {
        rec[18] = 0xFF; rec[19] = 0xFF
        for k in 0..<32 { put(20 + 2 * k, le16(0xBEEF)) }    // stale junk on purpose
    } else {
        rec[18] = UInt8(tabs.count - decimalTabs); rec[19] = UInt8(decimalTabs)
        for (k, t) in tabs.enumerated() { put(20 + 2 * k, le16(t)) }
    }
    rec[86] = UInt8(((just % 256) + 256) % 256)
    rec[87] = 1                                   // wrap on
    put(88, le16(0xFFFF))                         // line height: inherit
    rec[90] = 0xFF                                // spacing: inherit
    put(91, le16(attrsOn))
    rec[95] = 0xFF                                // colour: inherit
    return rec
}

/// One style library: master index header (13 bytes) + one object-index block with
/// stride-33 items, then the records those items point at. A `nil` name is an unused/
/// deleted slot (24 x 0x3F), which still occupies a slot number. Port of Python's
/// `_style_library` test helper.
func styleLibrary(_ entries: [(name: String?, record: [UInt8]?)]) -> [UInt8] {
    let n = entries.count
    var items: [UInt8] = []
    var records: [UInt8] = []
    let recBase = 13 + 5 + 33 * n
    for entry in entries {
        guard let name = entry.name else {
            items += [UInt8](repeating: 0x3F, count: 24) + [UInt8](repeating: 0, count: 9)
            continue
        }
        var nm = bytes(name)
        while nm.count < 24 { nm.append(0x20) }
        if let rec = entry.record {
            items += nm + [0x02] + [UInt8](repeating: 0, count: 4) + le32(recBase + records.count)
            records += rec
        } else {
            items += nm + [0x00] + [UInt8](repeating: 0, count: 8)
        }
    }
    let head: [UInt8] = [0x1A, 0x55] + le16(1) + [0x01] + le16(n) + le16(102) + le32(13)
    return head + [UInt8(n)] + [UInt8](repeating: 0, count: 4) + items + records
}

/// A ws5+ document whose header block points at `lib`: the body padded to a 128-byte
/// boundary with the EOF byte, then the library, with the header's own content offsets
/// 12-15 patched to the resulting base. Mirrors what the Python tests build inline.
func documentWithStyleLibrary(header: [UInt8] = [0x70] + [UInt8](repeating: 0, count: 15),
                              body: [UInt8], library: [UInt8]) -> [UInt8] {
    var doc = ws7Block(0x00, payload: header) + body
    let base = ((doc.count + 127) / 128) * 128
    while doc.count < base { doc.append(0x1A) }
    doc += library
    // content offsets 12-15 inside the 0x00 block: 0x1D + 2 length bytes + cmd = 4
    for (k, v) in le32(base).enumerated() { doc[4 + 12 + k] = v }
    return doc
}

/// A WS5+ note block (3=footnote, 4=endnote, 5=annotation, 6=comment) carrying `text`.
/// Content layout per the WordStar 7.0 spec's Notes section: line-count word, number
/// word, conversion-flag byte (high nybble = numbering format), then the text.
func wsNote(cmd: UInt8, _ text: String, number: Int = 1, lineCount: Int = 1) -> [UInt8] {
    let content: [UInt8] = [
        UInt8(lineCount & 0xFF), UInt8((lineCount >> 8) & 0xFF),
        UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF),
        0x30,
    ] + Array(text.utf8)
    return wsBlock(cmd: cmd, content: content)
}
