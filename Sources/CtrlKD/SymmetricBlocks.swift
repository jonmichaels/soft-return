/// WS5+ 1D symmetric block stripping — the pre-pass `parseWS` runs on ws5+ documents
/// before `linesPass`. Direct port of `_symmetric_blocks` + `_note_text`
/// (core.py:217-253). Verified against the 86 WS7 documents in Robert J. Sawyer's
/// WordStar archive (per the Python docstring); ported literally, guard conditions
/// included, rather than "cleaned up."
///
/// A `0x1D` symmetric sequence is `0x1D` + 2-byte little-endian body length + body,
/// with a command byte at the start of the body. This pass rewrites the byte stream:
/// footnote/endnote blocks are extracted to `footnotes` and replaced with a
/// `SENT_FNREF` sentinel; structural blocks (tab, softpage, heading) become either
/// literal bytes or another sentinel; anything else is dropped silently. The result
/// feeds `linesPass`, which never sees a `0x1D` byte from a well-formed ws5+ document.

/// Sentinels injected into the cleaned stream. These byte values cannot appear as text
/// in a WS5+ document body, so the assembly loop (job-006) can distinguish them from
/// real content unambiguously.
public let SENT_FNREF: UInt8 = 0x07
public let SENT_SOFTPAGE: UInt8 = 0x0B
public let SENT_HEADING: UInt8 = 0x11

/// Result of a symmetric-blocks pass: the rewritten byte stream plus every
/// footnote/endnote extracted from it, in document order.
public struct SymmetricBlocksResult: Hashable, Sendable {
    public let bytes: [UInt8]
    public let footnotes: [String]

    public init(bytes: [UInt8], footnotes: [String]) {
        self.bytes = bytes
        self.footnotes = footnotes
    }
}

public func symmetricBlocks(_ data: [UInt8]) -> SymmetricBlocksResult {
    var out: [UInt8] = []
    var footnotes: [String] = []
    var i = 0
    while i < data.count {
        // core.py:234 — need the marker plus both length bytes present.
        if data[i] == 0x1d && i + 3 <= data.count {
            let jump = Int(data[i + 1]) | (Int(data[i + 2]) << 8)   // little-endian 16-bit
            // core.py:236 — `block` re-includes the 2-byte length field, then `jump`
            // more bytes: block[0..<2] is the length, block[2] is the command byte.
            let blockEnd = min(i + 3 + jump, data.count)
            let block = Array(data[(i + 1)..<blockEnd])
            let cmd: Int = block.count > 2 ? Int(block[2]) : -1
            switch cmd {
            case 0x03, 0x04:                                       // foot/endnote
                footnotes.append(noteText(block))
                out.append(SENT_FNREF)
            case 0x09:                                             // tab
                out.append(contentsOf: [0x20, 0x20, 0x20, 0x20])
            case 0x0B:                                             // end of page
                out.append(SENT_SOFTPAGE)
            case 0x11 where block.count > 3:                       // paragraph style
                let level = [0x05: 1, 0x02: 2, 0x03: 3][Int(block[3])] ?? 0
                if level != 0 {
                    out.append(SENT_HEADING)
                    out.append(UInt8(0x30 + level))
                }
            default:
                break                                              // block skipped entirely
            }
            i += jump + 3
        } else {
            out.append(data[i])
            i += 1
        }
    }
    return SymmetricBlocksResult(bytes: out, footnotes: footnotes)
}

/// core.py:217-223. Note content is NESTED: header, then an inner `0x1D`, the text,
/// then a 2-byte length + `0x1D` tail (verified on the Sawyer WS7 archive, where the
/// literal tail bytes are `,\x00`). `block.split(0x1D)` in Python keeps empty
/// subsequences and has no max-split, so the hand-rolled splitter below must too.
private func noteText(_ block: [UInt8]) -> String {
    let inner = splitOnByte(block, 0x1d)
    let text: [UInt8]
    if inner.count > 1 && inner[1].count > 2 {
        text = Array(inner[1].dropLast(2))
    } else {
        text = Array(block.dropFirst(20))                          // core.py:221 fallback
    }
    let clean = text.filter { c in (c >= 0x20 && c < 0x7F) || c >= 0x80 || c == 0x09 }
    return stripWhitespace(decodeCP437(clean))
}

/// Non-omitting split on a single byte, matching Python `bytes.split(sep)` (no
/// maxsplit): every occurrence is a boundary, including adjacent/leading/trailing
/// ones, which produce empty segments that are kept, not dropped.
private func splitOnByte(_ data: [UInt8], _ separator: UInt8) -> [[UInt8]] {
    var result: [[UInt8]] = []
    var current: [UInt8] = []
    for b in data {
        if b == separator {
            result.append(current)
            current = []
        } else {
            current.append(b)
        }
    }
    result.append(current)
    return result
}

/// Stand-in for Python's `str.strip()` (default whitespace set) on the specific
/// character universe `noteText` can ever produce. `Foundation` is off-limits in
/// Sources, so this isn't `trimmingCharacters(in:.whitespaces)` — it's a literal
/// enumeration, justified by construction: `clean` above only ever contains bytes
/// 0x09, 0x20-0x7E, or >=0x80. Scanning every CP437 codepoint in that range for
/// which Python's `str.isspace()` is true yields exactly three: U+0009 (tab),
/// U+0020 (space), and U+00A0 (NBSP, CP437 byte 0xFF) — no other byte in this
/// pass's alphabet decodes to a Unicode whitespace codepoint. Do not shortcut this
/// to space-only: NBSP is real WordStar body content (word-spacing) and Python's
/// `.strip()` removes it here, so a Swift port that doesn't will diverge on any
/// note ending or starting with one.
private func stripWhitespace(_ s: String) -> String {
    let isSpace: (Unicode.Scalar) -> Bool = { $0.value == 0x09 || $0.value == 0x20 || $0.value == 0xA0 }
    var scalars = Array(s.unicodeScalars)
    while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}
