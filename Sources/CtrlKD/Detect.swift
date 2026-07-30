/// Content-based variant classification. Names and extensions lie — only the bytes
/// tell you what a WordStar-era file actually is.
///
/// Direct port of `detect()` in the Python reference (`src/ctrlkd/core.py`); every
/// threshold below is empirical and battle-tested, so they are copied literally
/// (comments cite the Python line each mirrors) rather than "cleaned up."
public enum Variant: String, Hashable, Sendable {
    case ws4
    case ws5plus = "ws5+"
    case printstream
    case text
    case binary
}

/// Detection result: the classified `variant` plus the evidence used to reach it.
///
/// Python returns a loosely-typed dict (evidence keys only present once `core` is
/// non-empty, `reason` only present for `binary`). Swift has no reason to preserve
/// that shape once, so `Detection` is a flat struct with a fixed field set — the
/// `empty (or ^Z at start)` case just reports zeroed evidence, since there is no
/// content for the counts to describe.
public struct Detection: Hashable, Sendable {
    public let variant: Variant
    public let reason: String?
    public let softReturns: Int
    public let hardReturns: Int
    public let highBitBytes: Int
    public let textPct: Int
    public let symmetricBlocks1D: Int
    public let size: Int

    public init(
        variant: Variant,
        reason: String? = nil,
        softReturns: Int = 0,
        hardReturns: Int = 0,
        highBitBytes: Int = 0,
        textPct: Int = 0,
        symmetricBlocks1D: Int = 0,
        size: Int = 0
    ) {
        self.variant = variant
        self.reason = reason
        self.softReturns = softReturns
        self.hardReturns = hardReturns
        self.highBitBytes = highBitBytes
        self.textPct = textPct
        self.symmetricBlocks1D = symmetricBlocks1D
        self.size = size
    }
}

public func detect(_ data: [UInt8]) -> Detection {
    // core.py:60 — truncate at the first ^Z (0x1A) before any counting.
    let core: [UInt8]
    if let zIndex = data.firstIndex(of: 0x1A) {
        core = Array(data[..<zIndex])
    } else {
        core = data
    }
    // core.py:61-62
    guard !core.isEmpty else {
        return Detection(variant: .binary, reason: "empty (or ^Z at start)")
    }

    // core.py:63-67
    let soft = countOccurrences(of: [0x8d, 0x0a], in: core)
    let hard = countOccurrences(of: [0x0d, 0x0a], in: core)
    let hi = core.reduce(into: 0) { count, byte in if byte >= 0x80 { count += 1 } }
    let blocks1D = core.reduce(into: 0) { count, byte in if byte == 0x1d { count += 1 } }
    let textLike = core.reduce(into: 0) { count, byte in
        let low = byte & 0x7F
        if (low >= 0x20 && low < 0x7F) || byte == 0x0D || byte == 0x0A || byte == 0x09 {
            count += 1
        }
    }
    let txt = textLike * 100 / core.count

    func result(_ variant: Variant, reason: String? = nil) -> Detection {
        Detection(
            variant: variant,
            reason: reason,
            softReturns: soft,
            hardReturns: hard,
            highBitBytes: hi,
            textPct: txt,
            symmetricBlocks1D: blocks1D,
            size: core.count
        )
    }

    // core.py:70-71
    if txt < 40 {
        return result(.binary, reason: "only \(txt)% text-like")
    }
    // core.py:72-74 — 1D symmetric blocks are WS5+ machinery regardless of anything else,
    // checked first after the binary gate.
    if blocks1D >= 2 {
        return result(.ws5plus)
    }
    // core.py:75-83 — soft returns are strong WS evidence on their own; high-bit density
    // alone is NOT (binaries are full of high bytes) unless the file is mostly text.
    if soft >= 3 || (hi >= max(1, core.count / 20) && txt >= 70) {
        // WS5+ kept soft returns but dropped the bit-7-on-last-letter convention: a
        // WordStar file with many soft returns and near-zero high bits is WS5+, as is
        // one using 1D symmetric blocks (footnotes etc., WS5+ only).
        if blocks1D >= 2 || (soft >= 3 && hi < soft / 4) {
            return result(.ws5plus)
        }
        return result(.ws4)
    }
    // core.py:84-88
    if txt >= 90 && hard >= 2 {
        return result(.printstream)
    }
    if txt >= 90 {
        return result(.text)
    }
    return result(.binary, reason: "\(txt)% text but no structure")
}

/// Non-overlapping occurrence count, matching Python `bytes.count`'s scan semantics.
private func countOccurrences(of pattern: [UInt8], in data: [UInt8]) -> Int {
    guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
    var count = 0
    var i = 0
    let limit = data.count - pattern.count
    while i <= limit {
        if Array(data[i..<(i + pattern.count)]) == pattern {
            count += 1
            i += pattern.count
        } else {
            i += 1
        }
    }
    return count
}
