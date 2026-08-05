/// Windows-1252 (cp1252) encoding support, shared by `PDFWriter.swift`'s `esc` and
/// `AFM.swift`'s `stringWidth1000`.
///
/// Since 2026-08-05 the PDF text font objects declare `/Encoding /WinAnsiEncoding` (which
/// IS cp1252) and the writer encodes strings as cp1252 instead of Latin-1, so bytes, glyphs
/// and AFM widths agree over the WHOLE range — including the 0x80-0x9F typographic row
/// (curly quotes, en/em dashes, ellipsis, bullet, dagger, trademark, ligatures) that
/// Latin-1 has no glyphs for at all (those codes are the C1 control range there).
///
/// 0x00-0x7F and 0xA0-0xFF are the identity map, same as Latin-1; only 0x80-0x9F differs,
/// and only five of those thirty-two slots (0x81, 0x8D, 0x8F, 0x90, 0x9D) are genuinely
/// undefined in Windows-1252 — mapped here to their own C1 control value purely for
/// round-trip symmetry, since real text never produces them.
private let cp1252High: [UInt8: UInt32] = [
    0x80: 0x20AC, 0x81: 0x0081, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E,
    0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030,
    0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8D: 0x008D, 0x8E: 0x017D,
    0x8F: 0x008F, 0x90: 0x0090, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
    0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
    0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9D: 0x009D,
    0x9E: 0x017E, 0x9F: 0x0178,
]

/// Unicode scalar VALUE -> cp1252 byte, built once from the table above (plus the
/// identity ranges, added lazily below rather than pre-populated for every one of 224
/// codepoints).
private let cp1252HighReverse: [UInt32: UInt8] = {
    var out: [UInt32: UInt8] = [:]
    for (byte, scalar) in cp1252High { out[scalar] = byte }
    return out
}()

/// The cp1252 byte for one Unicode scalar, or `nil` when the scalar has no cp1252
/// representation at all (the caller substitutes `?`, matching Python's `encode('cp1252',
/// 'replace')`).
func cp1252Byte(for scalar: Unicode.Scalar) -> UInt8? {
    let v = scalar.value
    if v <= 0x7F { return UInt8(v) }
    if v >= 0xA0 && v <= 0xFF { return UInt8(v) }
    return cp1252HighReverse[v]
}

/// Encode `text` as cp1252, `?` (0x3F) for anything with no cp1252 representation —
/// Python's `text.encode('cp1252', 'replace')`.
func cp1252Encode(_ text: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        out.append(cp1252Byte(for: scalar) ?? 0x3F)
    }
    return out
}
