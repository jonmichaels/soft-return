/// Pre-Unicode symbol-font encodings -> real Unicode. Direct port of
/// `src/ctrlkd/symbolmap.py`.
///
/// A byte set in the Symbol or ZapfDingbats font is not styled text -- it is a GLYPH
/// INDEX into that font: `a` in Symbol means alpha, `!` in Dingbats means an upper-blade
/// scissors. Unicode absorbed both faces (U+2700..27BF is ITC Zapf Dingbats by name and
/// order; Symbol's Greek and operators all have codepoints), so the faithful conversion
/// is transliteration at decode time -- after which the text renders everywhere with NO
/// font requirement at all. Jon's framing, 2026-08-04: "pre-unicode/emoji... I don't
/// think there's an equivalent" -- there is, and it's Unicode itself.
///
/// Trigger is the font block's own symbol-map bits (10=Math -> Symbol encoding,
/// 11=Symbols -> Dingbats encoding) with the typestyle NAME as fallback. Consistent with
/// the CP850 oracle finding: there the DRIVER ignored the bits (body bytes stayed cp437
/// for text fonts); here the FONT carries the glyphs, and emulating the font is exactly
/// what a converter is for.
///
/// Unmapped bytes pass through unchanged -- pass-through beats a wrong guess.

/// Which font encoding a run needs decoding through. `nil` from `fontTranslitKind` means
/// an ordinary text font, whose bytes are already cp437 and stay that way.
public enum SymbolTranslit: Hashable, Sendable {
    /// Adobe Symbol encoding (the font block's `math` symbol-map bit).
    case math
    /// ZapfDingbats (the font block's `symbols` symbol-map bit).
    case symbols
}

/// Adobe Symbol encoding, the well-established core: Greek per Latin letter positions,
/// plus the operators the era actually printed. (Not exhaustive; unmapped characters fall
/// through verbatim.)
///
/// Keyed by the SOURCE code point rather than a character literal, because several keys
/// are invisible or confusable in source -- U+00AD is a soft hyphen, and U+00D7 (which
/// maps to the dot operator) is itself a multiplication sign. Python's own table is
/// character-keyed; these are the same 81 entries, code point for code point.
let symbolEncoding: [UInt32: Unicode.Scalar] = [
    // Greek capitals, at the Latin capital positions
    0x41: "\u{0391}",   // 'A'     -> Α
    0x42: "\u{0392}",   // 'B'     -> Β
    0x47: "\u{0393}",   // 'G'     -> Γ
    0x44: "\u{0394}",   // 'D'     -> Δ
    0x45: "\u{0395}",   // 'E'     -> Ε
    0x5A: "\u{0396}",   // 'Z'     -> Ζ
    0x48: "\u{0397}",   // 'H'     -> Η
    0x51: "\u{0398}",   // 'Q'     -> Θ
    0x49: "\u{0399}",   // 'I'     -> Ι
    0x4B: "\u{039A}",   // 'K'     -> Κ
    0x4C: "\u{039B}",   // 'L'     -> Λ
    0x4D: "\u{039C}",   // 'M'     -> Μ
    0x4E: "\u{039D}",   // 'N'     -> Ν
    0x58: "\u{039E}",   // 'X'     -> Ξ
    0x4F: "\u{039F}",   // 'O'     -> Ο
    0x50: "\u{03A0}",   // 'P'     -> Π
    0x52: "\u{03A1}",   // 'R'     -> Ρ
    0x53: "\u{03A3}",   // 'S'     -> Σ
    0x54: "\u{03A4}",   // 'T'     -> Τ
    0x55: "\u{03A5}",   // 'U'     -> Υ
    0x46: "\u{03A6}",   // 'F'     -> Φ
    0x43: "\u{03A7}",   // 'C'     -> Χ
    0x59: "\u{03A8}",   // 'Y'     -> Ψ
    0x57: "\u{03A9}",   // 'W'     -> Ω

    // Greek lower case, at the Latin lower-case positions
    0x61: "\u{03B1}",   // 'a'     -> α
    0x62: "\u{03B2}",   // 'b'     -> β
    0x67: "\u{03B3}",   // 'g'     -> γ
    0x64: "\u{03B4}",   // 'd'     -> δ
    0x65: "\u{03B5}",   // 'e'     -> ε
    0x7A: "\u{03B6}",   // 'z'     -> ζ
    0x68: "\u{03B7}",   // 'h'     -> η
    0x71: "\u{03B8}",   // 'q'     -> θ
    0x69: "\u{03B9}",   // 'i'     -> ι
    0x6B: "\u{03BA}",   // 'k'     -> κ
    0x6C: "\u{03BB}",   // 'l'     -> λ
    0x6D: "\u{03BC}",   // 'm'     -> μ
    0x6E: "\u{03BD}",   // 'n'     -> ν
    0x78: "\u{03BE}",   // 'x'     -> ξ
    0x6F: "\u{03BF}",   // 'o'     -> ο
    0x70: "\u{03C0}",   // 'p'     -> π
    0x72: "\u{03C1}",   // 'r'     -> ρ
    0x73: "\u{03C3}",   // 's'     -> σ
    0x74: "\u{03C4}",   // 't'     -> τ
    0x75: "\u{03C5}",   // 'u'     -> υ
    0x66: "\u{03C6}",   // 'f'     -> φ
    0x63: "\u{03C7}",   // 'c'     -> χ
    0x79: "\u{03C8}",   // 'y'     -> ψ
    0x77: "\u{03C9}",   // 'w'     -> ω

    // the variant forms Adobe puts at the leftover Latin positions
    0x56: "\u{03C2}",   // 'V'     -> ς
    0x6A: "\u{03D5}",   // 'j'     -> ϕ
    0x76: "\u{03D6}",   // 'v'     -> ϖ
    0x4A: "\u{03D1}",   // 'J'     -> ϑ

    // the operators the era actually printed
    0x22: "\u{2200}",   // '"'     -> ∀
    0x24: "\u{2203}",   // '$'     -> ∃
    0x27: "\u{220B}",   // '''     -> ∋
    0x2A: "\u{2217}",   // '*'     -> ∗
    0x2D: "\u{2212}",   // '-'     -> −
    0x40: "\u{2245}",   // '@'     -> ≅
    0x7E: "\u{223C}",   // '~'     -> ∼
    0xB9: "\u{2260}",   // U+00B9  -> ≠
    0xA3: "\u{2264}",   // U+00A3  -> ≤
    0xB3: "\u{2265}",   // U+00B3  -> ≥
    0xB4: "\u{00D7}",   // U+00B4  -> ×
    0xB8: "\u{00F7}",   // U+00B8  -> ÷
    0xA5: "\u{221E}",   // U+00A5  -> ∞
    0xCE: "\u{2208}",   // U+00CE  -> ∈
    0xCF: "\u{2209}",   // U+00CF  -> ∉
    0xE5: "\u{2211}",   // U+00E5  -> ∑
    0xD5: "\u{220F}",   // U+00D5  -> ∏
    0xD6: "\u{221A}",   // U+00D6  -> √
    0xD7: "\u{22C5}",   // U+00D7  -> ⋅
    0xB0: "\u{00B0}",   // U+00B0  -> °
    0xB1: "\u{00B1}",   // U+00B1  -> ±
    0xB6: "\u{2202}",   // U+00B6  -> ∂
    0xD1: "\u{2207}",   // U+00D1  -> ∇
    0xF2: "\u{222B}",   // U+00F2  -> ∫
    0xAB: "\u{2194}",   // U+00AB  -> ↔
    0xAC: "\u{2190}",   // U+00AC  -> ←
    0xAD: "\u{2191}",   // U+00AD  -> ↑
    0xAE: "\u{2192}",   // U+00AE  -> →
    0xAF: "\u{2193}",   // U+00AF  -> ↓
]

/// ZapfDingbats low half: Unicode's U+2700 block was DEFINED in Zapf order, so 0x21-0x7E
/// map by formula. The handful of famous cross-block residents (card suits, which Unicode
/// already had at U+2660) are explicit.
private let dingbatExceptions: [UInt32: Unicode.Scalar] = [
    0xA8: "\u{2663}",   // club
    0xA9: "\u{2666}",   // diamond
    0xAA: "\u{2665}",   // heart
    0xAB: "\u{2660}",   // spade
]

private func dingbat(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    let b = scalar.value
    if let exception = dingbatExceptions[b] { return exception }
    if b >= 0x21 && b <= 0x7E { return Unicode.Scalar(0x2700 + (b - 0x20))! }
    return scalar                               // pass through, never guess
}

// MARK: - The way back: Unicode -> the font's own byte codes
//
// Transliteration is the right answer for text formats, which have no font at all. The PDF
// emitter is the one consumer that CAN show the real glyph: the PDF base-14 set includes
// Symbol and ZapfDingbats themselves, so selecting that font and writing the ORIGINAL byte
// gives the true face with nothing embedded. That needs the inverse of the map above.
//
// Round-trip rule, symmetric with `transliterate`: a character the forward map never touched
// (digits, space, punctuation -- all of which sit at their ASCII positions in both faces)
// passes back through as itself. Anything else has no code point in the face at all and
// becomes '?', the same degradation the rest of the PDF emitter uses for characters it
// cannot write.

/// `symbolEncoding` read backwards: real Unicode -> the Symbol byte that draws it.
///
/// Python builds this with `setdefault` over the forward map, so the FIRST key wins on a
/// collision; there are none (81 entries, 81 distinct glyphs — checked). Swift's dictionary
/// iteration order is not insertion order, so the loop runs over SORTED codes instead: with
/// no duplicates the two agree exactly, and if a duplicate is ever added this stays
/// deterministic rather than varying per run.
let symbolReverse: [UInt32: Unicode.Scalar] = {
    var out: [UInt32: Unicode.Scalar] = [:]
    for code in symbolEncoding.keys.sorted() {
        guard let uni = symbolEncoding[code] else { continue }
        if out[uni.value] == nil { out[uni.value] = Unicode.Scalar(code)! }
    }
    return out
}()

/// The four cross-block residents, read backwards — the card suits Unicode already had at
/// U+2660 before it absorbed the rest of Zapf's sheet at U+2700.
private let dingbatReverse: [UInt32: Unicode.Scalar] = {
    var out: [UInt32: Unicode.Scalar] = [:]
    for code in dingbatExceptions.keys.sorted() {
        guard let uni = dingbatExceptions[code] else { continue }
        if out[uni.value] == nil { out[uni.value] = Unicode.Scalar(code)! }
    }
    return out
}()

/// Inverse of `dingbat(_:)`: the ZapfDingbats byte for a Unicode glyph, or `nil` if this
/// face never carried it.
private func dingbatCode(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
    if let exception = dingbatReverse[scalar.value] { return exception }
    let cp = scalar.value
    if cp >= 0x2701 && cp <= 0x275E {                // the block `dingbat(_:)` emits
        return Unicode.Scalar(cp - 0x2700 + 0x20)!
    }
    return nil
}

/// Inverse of `transliterate`: real Unicode -> the bytes to set in the Symbol/ZapfDingbats
/// font itself. Unmappable characters -> `?`.
///
/// `nil` for `kind` is Python's "this is an ordinary text font" case (`kind not in ('math',
/// 'symbols')`), and returns the text untouched — so a caller can hand it whatever
/// `fontTranslitKind` said without testing first.
func untransliterate(_ text: String, _ kind: SymbolTranslit?) -> String {
    guard let kind else { return text }
    var view = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        let code: Unicode.Scalar?
        switch kind {
        case .math: code = symbolReverse[scalar.value]
        case .symbols: code = dingbatCode(scalar)
        }
        if let code {
            view.append(code)
        } else {
            // ASCII rode through the forward map untouched and rides back the same way
            // (both faces keep ASCII punctuation and digits in place).
            view.append(scalar.value >= 0x20 && scalar.value <= 0x7E ? scalar : "?")
        }
    }
    return String(view)
}

/// Transliterate one decoded string through a font's own encoding.
///
/// Iterates unicode scalars, as Python iterates code points: the mapping is per code
/// point and grapheme clustering would merge a combining mark into a neighbour.
func transliterate(_ text: String, _ kind: SymbolTranslit) -> String {
    var view = String.UnicodeScalarView()
    switch kind {
    case .math:
        for scalar in text.unicodeScalars {
            view.append(symbolEncoding[scalar.value] ?? scalar)
        }
    case .symbols:
        for scalar in text.unicodeScalars {
            view.append(dingbat(scalar))
        }
    }
    return String(view)
}

/// The transliteration a font run needs, from the block's own symbol-map bits first,
/// typestyle name as fallback. `nil` = ordinary text font.
func fontTranslitKind(_ font: FontChange) -> SymbolTranslit? {
    // NAME first: it is the specific signal. The coarse symbol-map bits can say `math`
    // for BOTH faces (PS.TST's Dingbats row transliterated to Greek until this
    // ordering); the bits remain the fallback for unnamed fonts.
    let name = asciiLowercased(font.typestyleName ?? "")
    if name.hasPrefix("symbol") { return .math }
    if asciiContains(name, "dingbat") { return .symbols }
    switch font.symbolMap {
    case .math: return .math
    case .symbols: return .symbols
    case .cp437, .cp850: return nil
    }
}
