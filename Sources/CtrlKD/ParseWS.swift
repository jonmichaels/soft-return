/// WordStar document parsing: inline control-code decoding plus the block/line
/// assembly loop. Direct port of `_decode_spans` (core.py:168-215) and `parse_ws`
/// (core.py:255-325).
///
/// This is the most bug-prone code in the project alongside `linesPass`. The comments
/// below mark the places where the ordering or the guard IS the behavior — several of
/// them shipped as production bugs in the Python implementation before being fixed.

/// WordStar inline control codes — the same core set from WS4 through WS7
/// (core.py:161-163). Note `0x02` and `0x04` both map to bold: `^D` doublestrike
/// renders as bold, and because Python toggles a *set*, hitting one after the other
/// closes the same style rather than nesting.
private let wsToggles: [UInt8: Style] = [
    0x02: .bold,
    0x13: .underline,
    0x19: .italic,
    0x14: .sup,
    0x16: .sub,
    0x18: .strike,
    0x04: .bold,
]

/// Control codes that are known-but-ignored: consumed silently, never counted as
/// unknown (core.py:164).
private let wsDrop: Set<UInt8> = [
    0x01, 0x03, 0x08, 0x0B, 0x0E, 0x10, 0x11, 0x12, 0x15, 0x17, 0x1C,
]

/// Dot commands that force a page break (core.py:166), compared uppercased.
private let dotPagebreak: Set<[UInt8]> = [Array("PA".utf8), Array("CP".utf8)]

/// One physical line of bytes -> `[Span]`. `active` persists across lines (WordStar
/// styles span line breaks) and `unknown` accumulates for the whole document, so both
/// are `inout`. `fnCounter` is non-nil only for ws5+ documents, where it numbers the
/// footnote-reference sentinels `symmetricBlocks` injected.
private func decodeSpans(
    _ raw: [UInt8],
    stripHibit: Bool,
    active: inout Style,
    unknown: inout [UInt8: Int],
    fnCounter: inout Int?
) -> [Span] {
    var spans: [Span] = []
    var buf: [UInt8] = []

    // core.py:175-178 — the span captures `active` as it stands right now; later
    // toggles must not retroactively restyle already-flushed text. `Style` is an
    // OptionSet (a value type), so the assignment below copies, matching Python's
    // explicit `frozenset(active)`.
    func flush() {
        if !buf.isEmpty {
            spans.append(Span(text: decodeCP437(buf), styles: active))
            buf.removeAll()
        }
    }

    var i = 0
    while i < raw.count {
        // core.py:182-185 — MASK BEFORE DISPATCH. WS4 sets bit 7 on the last character
        // of each word even when that character is a control toggle, so a word ending at
        // a style boundary arrives as e.g. 0x94 (= ^T | 0x80). Dispatching on the raw
        // byte instead leaks the toggle into the text and the style never closes —
        // that's the bug that turned whole paragraphs italic in production.
        let b: UInt8 = (stripHibit && raw[i] >= 0x80) ? (raw[i] & 0x7F) : raw[i]

        // core.py:186-187 — extended-character escape. Note it appends `raw[i + 1]`,
        // the UNMASKED byte: the escape exists precisely to smuggle a high byte past
        // the bit-7 stripping so it can decode as a cp437 extended character.
        if b == 0x1B && i + 1 < raw.count {
            buf.append(raw[i + 1])
            i += 2
            continue
        }

        if b == SENT_FNREF, let current = fnCounter {
            // core.py:188-191 — ws5+ only; counter is 1-based.
            flush()
            let n = current + 1
            fnCounter = n
            spans.append(Span(text: String(n), styles: active.union([.sup, .fnref])))
        } else if let style = wsToggles[b] {
            // core.py:192-195
            flush()
            if active.contains(style) {
                active.remove(style)
            } else {
                active.insert(style)
            }
        } else if b == 0x0F {
            buf.append(0x20)                    // binding space (core.py:196-197)
        } else if b == 0x1E {
            // inactive soft hyphen: dropped entirely (core.py:198-199)
        } else if b == 0x1F {
            buf.append(0x2D)                    // active soft hyphen -> '-' (core.py:200-201)
        } else if b == 0x09 {
            buf.append(b)                       // tab survives (core.py:202-203)
        } else if b < 0x20 || b == 0x7F {
            // core.py:204-206 — everything else in control range is either known-noise
            // or a diagnostic we want to surface.
            if !wsDrop.contains(b) {
                unknown[b, default: 0] += 1
            }
        } else {
            buf.append(b)
        }
        i += 1
    }
    flush()
    return spans
}

/// Parse a WordStar document (WS4 or WS5+) into the IR. core.py:255-325.
public func parseWS(_ data: [UInt8]) -> Document {
    let detection = detect(data)
    let stripHibit = detection.variant == .ws4
    let ws5 = detection.variant == .ws5plus

    // core.py:261-264 — the ws5+ gate is CORRECTNESS, not an optimization:
    // `symmetricBlocks` treats every 0x1D as a block-start marker, so running it on a
    // ws4 document would reinterpret a stray 0x1D that `wsDrop` should just discard.
    var body = data
    var footnotes: [[Span]] = []
    if ws5 {
        let stripped = symmetricBlocks(data)
        body = stripped.bytes
        footnotes = stripped.footnotes.map { [Span(text: $0)] }
    }

    let pass = linesPass(body)

    var active: Style = []
    var unknown: [UInt8: Int] = [:]
    var dots: [String] = []
    var fnCounter: Int? = ws5 ? 0 : nil
    var ruler = false

    var blocks: [Block] = []
    var cur = Block(kind: .para)
    var curLine = Line()

    // core.py:275-286 — empty lines and empty blocks are never appended.
    func closeLine() {
        if !curLine.spans.isEmpty {
            cur.lines.append(curLine)
        }
        curLine = Line()
    }
    func closeBlock() {
        closeLine()
        if !cur.lines.isEmpty {
            blocks.append(cur)
        }
        cur = Block(kind: .para)
    }

    for physical in pass.lines {
        var raw = physical.text
        // core.py:289 — masked unconditionally, NOT gated on stripHibit: a ws5+ dot line
        // is still recognized, and a ws4 dot whose '.' carries bit 7 (0xAE) still is too.
        let stripped = raw.map { $0 & 0x7F }

        if stripped.first == 0x2E {                          // '.' — dot command line
            // core.py:290-298 — captured as metadata; the line itself never becomes text.
            let cmd = rstrippingASCIIWhitespace(stripped)
            dots.append(decodeCP437(cmd))
            if dotPagebreak.contains(Array(cmd.dropFirst().prefix(2)).map(asciiUppercased)) {
                closeBlock()
                blocks.append(Block(kind: .pagebreak))
            }
            if Array(cmd.dropFirst().prefix(1)).map(asciiLowercased) == [0x72],  // 'r'
               cmd.contains(0x21) {                                             // '!'
                ruler = true
            }
            continue
        }

        if ws5 {
            // core.py:299-308 — sentinels injected by symmetricBlocks.
            if raw.contains(SENT_SOFTPAGE) {
                closeBlock()
                blocks.append(Block(kind: .softpage))
                raw.removeAll { $0 == SENT_SOFTPAGE }
            }
            // SENT_HEADING is a 2-BYTE unit: the sentinel plus an ASCII level digit.
            // The heading lands on the block `closeBlock()` just opened, not the one it
            // closed.
            if raw.first == SENT_HEADING && raw.count > 1 {
                closeBlock()
                cur.heading = Int(raw[1]) - 0x30
                raw = Array(raw.dropFirst(2))
            }
            raw.removeAll { $0 == SENT_HEADING }
        }

        let spans = decodeSpans(
            raw,
            stripHibit: stripHibit,
            active: &active,
            unknown: &unknown,
            fnCounter: &fnCounter
        )
        curLine.spans.append(contentsOf: spans)

        switch physical.separator {
        case .wrap:
            // core.py:312-315 — the join space inherits the LAST SPAN's styles (not the
            // current `active` set, which may have moved on), and is skipped when the
            // line already ends in a space or a hyphen.
            if let last = curLine.spans.last, !last.text.isEmpty,
               !last.text.hasSuffix(" "), !last.text.hasSuffix("-") {
                curLine.spans.append(Span(text: " ", styles: last.styles))
            }
        case .line:
            closeLine()
        case .para, .eof:
            closeBlock()
        }
    }
    closeBlock()

    return Document(
        blocks: blocks,
        footnotes: footnotes,
        detection: detection,
        marginEstimate: pass.margin,
        dotCommands: dots,
        unknownCodes: unknown,
        columnar: ruler
    )
}

// ---------------------------------------------------------------- internals

/// Python `bytes.rstrip()` with no argument strips this exact set. Unlike job-003's
/// space-only helper, the full set is needed here: the input is masked raw bytes, so
/// e.g. a 0x8D soft return masks to 0x0D and must still be trimmed.
private let asciiWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]

private func rstrippingASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
    var end = bytes.count
    while end > 0 && asciiWhitespace.contains(bytes[end - 1]) { end -= 1 }
    return Array(bytes[..<end])
}

/// ASCII-only case folding, matching `bytes.upper()`/`bytes.lower()` — which, unlike
/// `String` case mapping, never touches non-ASCII bytes.
private func asciiUppercased(_ b: UInt8) -> UInt8 {
    (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b
}

private func asciiLowercased(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
}
