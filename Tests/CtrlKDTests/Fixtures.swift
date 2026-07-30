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

/// A WS5+/WS7 1D symmetric block: `\x1d` + little-endian 16-bit body length + body.
func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
    var body: [UInt8] = [cmd]
    body.append(contentsOf: payload)
    let length = UInt16(body.count)
    return [0x1d, UInt8(length & 0xFF), UInt8(length >> 8)] + body
}

/// A footnote/endnote block: 17 zero bytes, an inner `\x1d`, the text, then the
/// `,\x00` tail `_note_text` trims off. Mirrors the Python fixture of the same name.
func ws7Note(_ text: [UInt8]) -> [UInt8] {
    let inner = Array(repeating: UInt8(0), count: 17) + [0x1d] + text + [0x2c, 0x00]
    return ws7Block(0x03, payload: inner)
}
