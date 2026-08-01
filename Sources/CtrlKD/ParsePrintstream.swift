/// Print-to-disk capture parsing. Direct port of `parse_printstream`
/// (core.py:337-381) plus its `PRINT_CODES` table (core.py:331-335).
///
/// A print-to-disk file is not a WordStar document: it is the byte stream WordStar sent
/// to the printer, captured to a file. It IS the printed page. So every line is kept
/// verbatim — including blank ones, which are page geometry rather than noise — and the
/// wrap test never runs. That's the structural difference from `parseWS`, and the reason
/// this parser doesn't touch `linesPass` at all.

/// Whether a printer style code turns a style on or off. Unlike WordStar's inline
/// toggles (`wsToggles` in ParseWS.swift), printer codes are directional: each style has
/// a distinct on code and off code, so this is set/clear, never toggle.
public struct PrintCode: Hashable, Sendable {
    public let style: Style
    public let on: Bool

    public init(style: Style, on: Bool) {
        self.style = style
        self.on = on
    }
}

/// Empirically derived from a late-80s dot-matrix driver (see the Python README); pass a
/// custom table to `parsePrintstream` if the source printer differed. core.py:331-335.
public let printCodes: [UInt8: PrintCode] = [
    0x18: PrintCode(style: .sup, on: true),
    0x12: PrintCode(style: .sup, on: false),
    0x10: PrintCode(style: .underline, on: true),
    0x11: PrintCode(style: .underline, on: false),
    0x13: PrintCode(style: .italic, on: true),
    0x15: PrintCode(style: .italic, on: false),
    0x05: PrintCode(style: .italic, on: true),
    0x06: PrintCode(style: .italic, on: false),
    0x1E: PrintCode(style: .bold, on: true),
    0x1F: PrintCode(style: .bold, on: false),
]

/// COMMENT.BUG: a documented WordStar bug (Sawyer, WS archive REF notes, 2013) -- a
/// document containing `^ONC` comments, printed to disk with the ASCII/ASC256/PRVIEW/
/// WS4 drivers (NOT XTRACT), has everything after the comment deleted from that line,
/// may gain a stray `^T` (0x14), and the line ends with a bare LF (0x0A) instead of
/// CR LF (0x0D 0x0A). This is damage WordStar itself introduced at print time in the
/// 1990s -- not a parse failure -- so it's reported as a signature, not silently
/// swallowed or mistaken for something this tool got wrong.
///
/// Detection is necessarily a heuristic (a bare-LF line ending is the documented
/// signature, but a print stream that happens to use plain Unix line endings
/// throughout would also match); callers should read the flag as "this signature is
/// present", not "this file definitely hit the bug". Direct port of
/// `_detect_comment_bug` (Python ctrl-kd 1.2.0, core.py). Runs on the already
/// ^Z-truncated body, matching the Python call order.
private func detectCommentBug(_ data: [UInt8]) -> CommentBug? {
    var count = 0
    var first: Int? = nil
    var prev: UInt8? = nil    // Python's `prev = -1` sentinel: never equals 0x0D, so a
                               // file that begins with a bare 0x0A is also flagged.
    for (i, b) in data.enumerated() {
        if b == 0x0A && prev != 0x0D {
            count += 1
            if first == nil { first = i }
        }
        prev = b
    }
    guard count > 0, let firstOffset = first else { return nil }
    return CommentBug(count: count, firstOffset: firstOffset, strayControlT: data.contains(0x14))
}

public func parsePrintstream(
    _ data: [UInt8],
    codes: [UInt8: PrintCode] = printCodes
) -> Document {
    // core.py:343-345
    var body = data
    if let cut = data.firstIndex(of: 0x1a) {
        body = Array(data[..<cut])
    }
    let commentBug = detectCommentBug(body)

    var active: Style = []
    var blocks: [Block] = []
    var cur = Block(kind: .para)
    var line = Line()
    var buf: [UInt8] = []

    func flush() {
        if !buf.isEmpty {
            line.spans.append(Span(text: decodeCP437(buf), styles: active))
            buf.removeAll()
        }
    }

    // core.py:356-360 — appends UNCONDITIONALLY: an empty line is a blank printed line,
    // which is real page geometry. Contrast `parseWS`'s closeLine(), which drops them.
    func endline() {
        flush()
        cur.lines.append(line)
        line = Line()
    }

    for rawByte in body {
        // core.py:363 — mask first: stray high bits are printer noise, so 0xA0 is just a
        // space. Note this happens BEFORE the code lookup, so a style code carrying bit 7
        // still dispatches.
        let c = rawByte & 0x7F
        if let code = codes[c] {
            // core.py:364-367 — set/clear, not toggle.
            flush()
            if code.on {
                active.insert(code.style)
            } else {
                active.remove(code.style)
            }
        } else if c == 0x0A {
            endline()
        } else if c == 0x0C {
            // core.py:370-374 — form feed: finish the line, close the block, page break.
            endline()
            blocks.append(cur)
            blocks.append(Block(kind: .pagebreak))
            cur = Block(kind: .para)
        } else if c == 0x0D || (c < 0x20 && c != 0x09) {
            continue                     // CR and printer housekeeping (e.g. 0x14) dropped
        } else {
            buf.append(c)                // tab (0x09) reaches here and survives
        }
    }
    endline()
    blocks.append(cur)

    // core.py:342 — the variant is asserted, not detected: `parse_printstream` builds its
    // meta by hand and never calls detect(), so there is no evidence to report. Zeroed
    // evidence reads as "nothing counted", the same convention job-002 established for
    // detect()'s empty/^Z-at-start early return. `marginEstimate` stays nil: the wrap
    // test never ran.
    return Document(
        blocks: blocks,
        detection: Detection(variant: .printstream),
        columnar: true,
        commentBug: commentBug
    )
}
