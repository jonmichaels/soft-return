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

/// A WS5+/WS7 1D symmetric block: `\x1d` + little-endian 16-bit body length + body.
func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
    var body: [UInt8] = [cmd]
    body.append(contentsOf: payload)
    let length = UInt16(body.count)
    return [0x1d, UInt8(length & 0xFF), UInt8(length >> 8)] + body
}
