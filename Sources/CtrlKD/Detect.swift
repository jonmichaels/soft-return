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
    // The file may DECLARE itself before any statistics: a WS5+ document opens
    // with a type-0 header block (version BCD + driver + style pointer) at
    // offset 0. Full framing is validated -- jump range, trailing count and
    // bracket, plausible BCD version -- so a random 0x1D cannot impersonate
    // one. This runs BEFORE the 0x1A truncation below: the header's own
    // content can contain 0x1A, and truncating there judged a real 6.6 KB
    // document on its first 17 bytes.
    if data.count >= 8, data[0] == 0x1D, data[3] == 0x00 {
        let jump = Int(data[1]) | (Int(data[2]) << 8)
        let end = 2 + jump
        if jump >= 8, jump < 0x400, end < data.count, data[end] == 0x1D,
           Int(data[end - 2]) | (Int(data[end - 1]) << 8) == jump,
           [0x50, 0x55, 0x60, 0x70].contains(data[4]) {
            return Detection(
                variant: .ws5plus,
                reason: "opens with a valid header block (declared release "
                    + "\(data[4] >> 4).\(data[4] & 0x0F))",
                size: data.count)
        }
    }
    // core.py:1199 — truncate at the file's real EOF before any counting: the
    // start of the trailing ^Z padding run when one exists, else the first bare
    // 0x1A. NOT the first 0x1A anywhere — that byte can be legitimate in-content
    // control data (REF/ROUNDED.BRD's box-drawing template hits one at offset 48
    // inside a real symmetrical sequence; truncating there judged the 6.4 KB
    // document on 48 bytes ("89% text but no structure") and parse refused it
    // outright). See `bareEOF` in LinesPass.swift for the run-detection.
    let core: [UInt8]
    if let eof = bareEOF(data) {
        core = Array(data[..<eof])
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
    // STRUCTURAL, not a byte tally: counting bare 0x1D bytes counted chance bytes and
    // let 21 MB of Windows executable in (job-493). See `countSymmetricBlocks`.
    let blocks1D = countSymmetricBlocks(core)
    let textLike = core.reduce(into: 0) { count, byte in
        let low = byte & 0x7F
        if (low >= 0x20 && low < 0x7F) || byte == 0x0D || byte == 0x0A || byte == 0x09 {
            count += 1
        }
    }
    // A wrapped extended character <1B x 1C> is three bytes of WS5+ machinery
    // around ONE text character; its frame bytes counted as binary noise, so
    // a document whose body is box-drawing read as "63% text but no
    // structure" and was refused.
    var trips = 0
    var t = 0
    while t + 2 < core.count {
        if core[t] == 0x1B, core[t + 2] == 0x1C {
            trips += 1
            t += 3
        } else {
            t += 1
        }
    }
    let txt = min(100, (textLike + 2 * trips) * 100 / core.count)

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
    // A wrapped triple is three bytes with an ARBITRARY middle, so unlike a symmetric
    // block there is no framing left to verify — the only corroboration available is
    // density. Chance alone puts a <1B ? 1C> every 65536 bytes of random data, which is
    // why 11 triples in 2 MB of dosbox-x.exe (job-493) meant nothing: that is BELOW the
    // noise floor. Real machinery is orders of magnitude denser — BOX.WS runs ~90
    // triples in 304 bytes — so require at least 4x the chance rate (one triple per
    // 16 KB) on top of the standing count of 3. Measured across the archive the two
    // populations do not overlap: every genuine trip-carrying document sits at >= 7x
    // chance, every binary at <= 2x.
    let denseTrips = trips >= 3 && trips * 16384 >= core.count
    // ONE well-formed block is the threshold, not two. The old `>= 2` was a BYTE
    // threshold and a single real block spends two 0x1D bytes (opening bracket and
    // closing bracket), so `>= 2` bytes and `>= 1` block are the same standard for a
    // genuine document — measured: 51 archive files (PLAYS.DOC, the MAILLIST envelope
    // layouts, the LSRBOX templates, the WS7 TAGS/ files, -MACROS.DOC) carry exactly
    // one block, and reading the old constant as a block count would have dropped every
    // one of them.
    // core.py:72-74 — well-formed 1D symmetric blocks and 1B..1C wrapped extended
    // characters are WS5+ machinery regardless of anything else, checked first after
    // the binary gate.
    if blocks1D >= 1 || denseTrips {
        return result(.ws5plus)
    }
    // core.py:75-83 — soft returns are strong WS evidence on their own; high-bit density
    // alone is NOT (binaries are full of high bytes) unless the file is mostly text.
    // `soft` is a two-byte sequence, so it needs the same density floor the wrapped
    // triples get: chance puts an <8D 0A> every 65536 bytes, and dosbox-x.exe's 12 in
    // 2 MB is BELOW that noise floor — with the 0x1D count made structural, those 12
    // chance bytes were the whole remaining case for calling a 21 MB Windows executable
    // a WS4 document. A real WS4 document soft-wraps every line: one per ~60 bytes,
    // thousands of times the floor asked for here.
    let denseSoft = soft >= 3 && soft * 16384 >= core.count
    if denseSoft || (hi >= max(1, core.count / 20) && txt >= 70) {
        // WS5+ kept soft returns but dropped the bit-7-on-last-letter convention: a
        // WordStar file with many soft returns and near-zero high bits is WS5+.
        // (Symmetric blocks — footnotes etc., WS5+ only — settled it above; blocks1D is
        // necessarily 0 by the time we get here, so this branch is about returns alone.)
        if denseSoft && hi < soft / 4 {
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
