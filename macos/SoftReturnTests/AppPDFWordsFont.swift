import CoreGraphics
import CtrlKD
import Foundation

/// One PDF font, reduced to the two things word extraction needs: how bytes map to codes,
/// and how wide each code is.
///
/// Widths come from the font's OWN `/Widths` (simple fonts) or `/W`/`/DW` (CID fonts), in
/// 1/1000 em — the same numbers a viewer advances by. The base-14 fallback exists only for a
/// font that legitimately carries no width array, which for the base-14 faces is allowed by
/// the spec; a wrong fallback would show up immediately as an x drift in the round-trip
/// proof against ctrl-kd's own dump, so it is checked rather than trusted.
struct PDFFont {

    /// A decoded character code plus whether it was the single byte 0x20, which is the ONLY
    /// thing `Tw` word spacing applies to (a 2-byte CID 32 does not take it).
    struct Code {
        let value: Int
        let isSingleByteSpace: Bool
    }

    let baseFont: String?
    /// The Symbol face specifically — NOT `font_class == "symbol"`, which also covers
    /// Dingbats, whose encoding is a different map entirely (`dingbat`, not
    /// `symbolEncoding`).
    private let isSymbolFace: Bool
    private let isTwoByte: Bool
    private let firstChar: Int
    private let widths: [Double]
    private let cidWidths: [Int: Double]
    private let defaultWidth: Double
    private let toUnicode: [Int: Character]
    /// The single-byte encoding `/Encoding` declares, or `nil` when it names one this
    /// does not model (`StandardEncoding`, `MacExpertEncoding`) — never a silent
    /// default, because the fallback below is Latin-1 and Latin-1 is nobody's
    /// declared encoding here.
    private let byteEncoding: String.Encoding?

    init(dictionary: CGPDFDictionaryRef) {
        var name: UnsafePointer<Int8>?
        var base: String?
        if CGPDFDictionaryGetName(dictionary, "BaseFont", &name), let name {
            base = String(cString: name)
        }
        self.baseFont = base
        let bareName = (base ?? "").contains("+")
            ? String((base ?? "").split(separator: "+", maxSplits: 1).last!) : (base ?? "")
        self.isSymbolFace = bareName.lowercased().hasPrefix("symbol")

        var subtype: UnsafePointer<Int8>?
        var subtypeName = ""
        if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype {
            subtypeName = String(cString: subtype)
        }

        // A Type0 font's codes are multi-byte; every other subtype here is single-byte.
        // Identity-H, which is what Quartz emits for a subset TrueType, is 2 bytes.
        let composite = subtypeName == "Type0"
        self.isTwoByte = composite

        // THE SINGLE-BYTE ENCODING THE FONT DECLARES. Two of them appear in practice and
        // they disagree exactly where this gate lives:
        //
        // - `/WinAnsiEncoding` IS cp1252, NOT Latin-1, and the two differ over 0x80-0x9F —
        //   exactly where ctrl-kd's own emitter puts the characters it cares about (its
        //   pdf.py says so at its own `_esc`: "cp1252, not latin-1: the declared
        //   /WinAnsiEncoding IS cp1252"). Decoding those as Latin-1 turned -README's `€,`
        //   into `,` and lost the word, which the round-trip proof caught immediately.
        //
        // - `/MacRomanEncoding` is what QUARTZ writes, and it is the ONLY named encoding in
        //   any app PDF measured — checked on -SCREEN, BOXES, LYING, DOCC and SCRIPT, none
        //   of which carries a `/Differences` array either. Handling only WinAnsi meant every
        //   such byte fell through to the raw-scalar branch, which is Latin-1, and MacRoman
        //   and Latin-1 share nothing above 0x7F. Measured cost on -SCREEN: the engine's
        //   `ß` (MacRoman 0xA7) came out as cp1252's `§`, so the 14-character Greek run read
        //   `α§ΓπΣσµτΦΘΩδφε` against the engine's `αßΓπΣσµτΦΘΩδφε` and could never match.
        //   I reported that as a missing app glyph. It was this.
        var encoding: UnsafePointer<Int8>?
        var encodingName: String?
        if CGPDFDictionaryGetName(dictionary, "Encoding", &encoding), let encoding {
            encodingName = String(cString: encoding)
        } else {
            // A dictionary-form /Encoding carries its own BaseEncoding.
            var encodingDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Encoding", &encodingDict),
               let encodingDict {
                var base: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(encodingDict, "BaseEncoding", &base), let base {
                    encodingName = String(cString: base)
                }
            }
        }
        switch encodingName {
        case "WinAnsiEncoding": self.byteEncoding = .windowsCP1252
        case "MacRomanEncoding": self.byteEncoding = .macOSRoman
        default: self.byteEncoding = nil
        }

        var first: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dictionary, "FirstChar", &first)
        self.firstChar = Int(first)

        var simple: [Double] = []
        var widthsArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Widths", &widthsArray), let widthsArray {
            for index in 0..<CGPDFArrayGetCount(widthsArray) {
                var value: CGPDFReal = 0
                simple.append(CGPDFArrayGetNumber(widthsArray, index, &value) ? Double(value) : 0)
            }
        }
        self.widths = simple

        var cid: [Int: Double] = [:]
        var fallback: Double = composite ? 1000 : 0
        if composite {
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants),
               let descendants, CGPDFArrayGetCount(descendants) > 0,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                var dw: CGPDFReal = 0
                if CGPDFDictionaryGetNumber(descendant, "DW", &dw) { fallback = Double(dw) }
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(descendant, "W", &w), let w {
                    cid = PDFFont.parseCIDWidths(w)
                }
            }
        }
        self.cidWidths = cid
        self.defaultWidth = fallback
        self.toUnicode = PDFFont.parseToUnicode(dictionary)
    }

    /// `/W` is `[ c [w1 w2 ...] cFirst cLast w ... ]` — both forms, interleaved.
    private static func parseCIDWidths(_ array: CGPDFArrayRef) -> [Int: Double] {
        var out: [Int: Double] = [:]
        var index = 0
        let count = CGPDFArrayGetCount(array)
        while index < count {
            var start: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, index, &start) else { index += 1; continue }
            var nested: CGPDFArrayRef?
            if index + 1 < count, CGPDFArrayGetArray(array, index + 1, &nested), let nested {
                for offset in 0..<CGPDFArrayGetCount(nested) {
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(nested, offset, &value) {
                        out[Int(start) + offset] = Double(value)
                    }
                }
                index += 2
                continue
            }
            var last: CGPDFInteger = 0
            var value: CGPDFReal = 0
            if index + 2 < count, CGPDFArrayGetInteger(array, index + 1, &last),
               CGPDFArrayGetNumber(array, index + 2, &value), last >= start {
                for code in Int(start)...Int(last) { out[code] = Double(value) }
                index += 3
                continue
            }
            index += 1
        }
        return out
    }

    /// The `/ToUnicode` CMap, parsed only for `bfchar`/`bfrange` — enough to recover the
    /// text of a subset-encoded font, which is the only reason this is here. A font without
    /// one falls back to Latin-1, which is correct for the simple base-14 fonts ctrl-kd's
    /// own emitter uses.
    private static func parseToUnicode(_ dictionary: CGPDFDictionaryRef) -> [Int: Character] {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "ToUnicode", &stream), let stream else {
            return [:]
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return [:] }
        guard let text = String(data: data, encoding: .isoLatin1) else { return [:] }

        var map: [Int: Character] = [:]
        func scalar(_ hex: String) -> Character? {
            guard let value = UInt32(hex.prefix(4), radix: 16),
                  let unicode = Unicode.Scalar(value) else { return nil }
            return Character(unicode)
        }
        // bfchar: <src> <dst>
        for block in text.components(separatedBy: "beginbfchar").dropFirst() {
            let body = block.components(separatedBy: "endbfchar").first ?? ""
            let hexes = body.components(separatedBy: "<").dropFirst()
                .compactMap { $0.components(separatedBy: ">").first }
            for pair in stride(from: 0, to: hexes.count - 1, by: 2) {
                if let code = Int(hexes[pair], radix: 16), let char = scalar(hexes[pair + 1]) {
                    map[code] = char
                }
            }
        }
        // bfrange: <lo> <hi> <dstStart>
        for block in text.components(separatedBy: "beginbfrange").dropFirst() {
            let body = block.components(separatedBy: "endbfrange").first ?? ""
            let hexes = body.components(separatedBy: "<").dropFirst()
                .compactMap { $0.components(separatedBy: ">").first }
            for triple in stride(from: 0, to: hexes.count - 2, by: 3) {
                guard let low = Int(hexes[triple], radix: 16),
                      let high = Int(hexes[triple + 1], radix: 16),
                      let start = UInt32(hexes[triple + 2].prefix(4), radix: 16),
                      high >= low, high - low < 4096 else { continue }
                for code in low...high {
                    if let unicode = Unicode.Scalar(start + UInt32(code - low)) {
                        map[code] = Character(unicode)
                    }
                }
            }
        }
        return map
    }

    // MARK: - Decoding

    func codes(in bytes: [UInt8]) -> [Code] {
        guard isTwoByte else {
            return bytes.map { Code(value: Int($0), isSingleByteSpace: $0 == 0x20) }
        }
        var out: [Code] = []
        var index = 0
        while index + 1 < bytes.count {
            out.append(Code(value: Int(bytes[index]) << 8 | Int(bytes[index + 1]),
                            isSingleByteSpace: false))
            index += 2
        }
        return out
    }

    /// The Symbol face's own byte -> real Unicode, derived from the ENGINE's public
    /// `symbolReverse` rather than a second table here.
    ///
    /// `symbolReverse` is Unicode -> Symbol byte (what the emitter needs); reading a PDF
    /// needs the inverse. Inverting is exact rather than lossy: SymbolTranslit.swift's own
    /// comment records that the map is collision-free — "81 entries, 81 distinct glyphs —
    /// checked" — so no two Unicode scalars share a byte.
    ///
    /// Without this the extractor reports what the font literally draws, `aßGpSsµtFQWdfe`,
    /// where ctrl-kd reports `αßΓπΣσµτΦΘΩδφε`. The POSITIONS already agreed to the
    /// hundredth; only the text differed, because ctrl-kd untransliterates in `_op_chars`
    /// so the two sides compare comparable text and not just comparable geometry.
    private static let symbolForward: [Int: Character] = {
        var out: [Int: Character] = [:]
        for (unicodeValue, symbolByte) in symbolReverse {
            if let scalar = Unicode.Scalar(unicodeValue) {
                out[Int(symbolByte.value)] = Character(scalar)
            }
        }
        return out
    }()

    func character(for code: Int) -> Character {
        // A Symbol-encoded run's bytes are Symbol's own codepoints, not Latin text — the
        // font is the encoding. Resolve those first, before /ToUnicode or cp1252, both of
        // which would happily return the ASCII letter the byte looks like.
        if isSymbolFace, let greek = PDFFont.symbolForward[code] { return greek }
        if let mapped = toUnicode[code] { return mapped }
        if let byteEncoding, code >= 0, code <= 0xFF,
           let decoded = String(bytes: [UInt8(code)], encoding: byteEncoding),
           let first = decoded.first {
            return first
        }
        if let unicode = Unicode.Scalar(UInt32(code)) { return Character(unicode) }
        return " "
    }

    /// Width in 1/1000 em. The PDF's own `/Widths` (or `/W`) when it has them; the ENGINE's
    /// base-14 AFM metrics when it does not.
    ///
    /// The fallback is not a nicety. ctrl-kd's own PDFs embed the base-14 faces with NO
    /// `/Widths` array at all — checked on LYING: seven font objects, Courier through
    /// Times-Italic, `/Widths present: False` on every one — which the spec permits. A flat
    /// guess there is wrong for every proportional face, and it showed: with a 500/1000
    /// default, characters from two runs on one baseline sorted into each other and
    /// mechanism Z segmentation produced `HistoricaAlnd` and `AntiquarianClub` out of
    /// LYING's title. Real metrics are required to compute a gap at all.
    ///
    /// They come from `CtrlKD.stringWidth1000` (public as of sr bc8a75d) rather than a table
    /// copied into this target, for the same reason the Symbol substitution reads
    /// `untransliterate`: a second copy of the base-14 metrics would drift, and the register's
    /// test for inheritance is whether the app reads the engine's answer or computes its own.
    func width(for code: Int) -> Double {
        if isTwoByte { return cidWidths[code] ?? defaultWidth }
        let index = code - firstChar
        if index >= 0, index < widths.count, widths[index] > 0 { return widths[index] }
        guard let baseFont else { return PDFFont.base14Width(baseFont: nil, code: code) }
        // `stringWidth1000` takes text, and encodes it cp1252 — which is exactly the
        // encoding these fonts declare (`/WinAnsiEncoding`), so a single-character string
        // built from this code round-trips to the same byte the PDF drew.
        let bare = baseFont.contains("+")
            ? String(baseFont.split(separator: "+", maxSplits: 1).last!) : baseFont
        guard let scalar = Unicode.Scalar(UInt32(code)) else {
            return PDFFont.base14Width(baseFont: baseFont, code: code)
        }
        return Double(CtrlKD.stringWidth1000(String(Character(scalar)), bare))
    }

    /// Only for a font that carries no `/Widths` at all, which the spec permits for the
    /// base-14 faces. Courier is the one that matters here — every WordStar facsimile line
    /// is fixed pitch — and its advance is exactly 600/1000 em at every size, which is the
    /// same 0.6 factor the app's own geometry oracle uses for a typed column.
    private static func base14Width(baseFont: String?, code: Int) -> Double {
        let name = (baseFont ?? "").lowercased()
        if name.contains("courier") || name.contains("mono") { return 600 }
        return 500
    }
}
