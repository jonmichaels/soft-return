/// Physical-line splitting and break-run classification — "the wrap test."
///
/// Direct port of `lines_pass()` in the Python reference (`src/ctrlkd/core.py:95-157`).
/// This decides whether each WordStar soft return is word wrap (join it) or a
/// deliberate break the author chose (poem line, heading). Every rule is empirical,
/// so they are ported literally — see the comment on the strict `<` in particular.

/// How the break after a physical line should be interpreted.
public enum LineSeparator: String, Hashable, Sendable {
    /// A soft return that is just word wrap: join with a space.
    case wrap
    /// A single hard return (the author's Return), or a soft return where the next
    /// word WOULD have fit — so breaking early was a choice.
    case line
    /// A break run with >=1 hard return and >=2 breaks total (a blank line).
    case para
    /// End of input.
    case eof
    /// A blank physical line whose terminator was SOFT — the filler that a line
    /// spacing greater than one materialises into the file. Added 2026-08-03.
    case blankSoft = "blank-soft"
    /// A blank physical line whose terminator was HARD — the author's own Return.
    case blankHard = "blank-hard"
}

/// One physical line and the break that followed it. `text` is the RAW bytes as they
/// appeared in the file — high bits and control codes intact, for later passes to
/// decode. Only the classification logic looks at the "visible" projection.
public struct PhysicalLine: Hashable, Sendable {
    public let text: [UInt8]
    public let separator: LineSeparator

    public init(text: [UInt8], separator: LineSeparator) {
        self.text = text
        self.separator = separator
    }
}

/// Result of a lines pass: the classified lines plus the margin the wrap test used.
public struct LinesPassResult: Hashable, Sendable {
    public let lines: [PhysicalLine]
    /// 90th percentile of soft-wrapped line lengths, floor 65 (the WS4 default).
    public let margin: Int

    public init(lines: [PhysicalLine], margin: Int) {
        self.lines = lines
        self.margin = margin
    }
}

public func linesPass(_ data: [UInt8]) -> LinesPassResult {
    // core.py:108-110 — truncate at the first ^Z before anything else.
    var body = data
    if let cut = data.firstIndex(of: 0x1a) {
        body = Array(data[..<cut])
    }

    let lines = splitIntoRawLines(body)

    // core.py:120-122 — margin is the 90th percentile of soft-wrapped line lengths
    // (outliers from hanging punctuation sit 1-2 past the true margin), floor 65.
    // Indexed exactly as Python does: `softlens[int(len(softlens) * 0.9)]`, truncating
    // toward zero. Swift's Double is IEEE 754 like Python's float, so
    // `Int(Double(count) * 0.9)` reproduces its rounding bit-for-bit — deliberately
    // NOT a "better" percentile method.
    var softLens: [Int] = []
    for line in lines where line.kind == .soft {
        let vis = visible(line.text)
        if !isBlank(vis) {
            softLens.append(rstrippingSpaces(vis).count)
        }
    }
    softLens.sort()
    let percentile = softLens.isEmpty ? 0 : softLens[Int(Double(softLens.count) * 0.9)]
    let margin = max(65, percentile)

    // core.py:124-157
    var out: [PhysicalLine] = []
    var i = 0
    while i < lines.count {
        let (text, kind) = (lines[i].text, lines[i].kind)
        let vis = visible(text)
        // A blank line is CONTENT, not a delimiter (2026-08-03, matching core.py).
        // It used to be skipped here and counted only to classify the PREVIOUS
        // line's separator, then discarded — which on a real double-spaced 1992
        // essay deleted 221 of 448 physical lines, took the author's chapter drop
        // with it, and changed the page count.
        //
        // The RAW bytes are kept, never emptied: a line can be visually blank and
        // still carry style toggles, and dropping them would unstyle everything
        // after it. The terminator KIND is carried because WordStar distinguishes
        // them — soft blanks are `.ls` filler and are suppressed at a page top,
        // hard blanks are the author's and print.
        if isBlank(vis) {
            if kind != .eof {
                out.append(PhysicalLine(text: text,
                                        separator: kind == .soft ? .blankSoft : .blankHard))
            }
            i += 1
            continue
        }

        // core.py:131-139 — absorb the run of blank lines that follows, counting the
        // breaks in it. This is what collapses double-spaced documents.
        var nHard = (kind == .hard) ? 1 : 0
        var nTotal = (kind == .eof) ? 0 : 1
        var j = i + 1
        while j < lines.count && isBlank(visible(lines[j].text)) {
            let k = lines[j].kind
            if k != .eof {
                nTotal += 1
                if k == .hard { nHard += 1 }
            }
            j += 1
        }

        // core.py:140-142 — nothing but blanks left: this line ends the document.
        if j >= lines.count {
            out.append(PhysicalLine(text: text, separator: .eof))
            break
        }

        let sep: LineSeparator
        if nHard >= 1 && nTotal >= 2 {
            sep = .para                                     // core.py:143-144
        } else if nHard == 1 {
            sep = .line                                     // core.py:145-146
        } else {
            // core.py:147-154 — the wrap test, applied to an all-soft break run.
            let nextVis = visible(lines[j].text)
            if nextVis.first == 0x20 {
                sep = .line                                 // indented continuation = deliberate
            } else {
                let L = rstrippingSpaces(vis).count
                let W = firstWordLength(nextVis)
                // STRICT `<`: WS4 wrapped even when the next word would land EXACTLY at
                // the margin, so an exact fit is still wrap, not a deliberate break.
                // Do not "fix" this to `<=` — that exact bug cost a release.
                sep = (L + 1 + W < margin) ? .line : .wrap
            }
        }
        out.append(PhysicalLine(text: text, separator: sep))
        // The blanks this run consumed, in document order, after the line they
        // follow. They were counted above to classify `sep` and are now also kept
        // as content — the counting and the keeping are separate jobs.
        if i + 1 < j {
            for b in (i + 1)..<j where lines[b].kind != .eof {
                out.append(PhysicalLine(text: lines[b].text,
                                        separator: lines[b].kind == .soft ? .blankSoft : .blankHard))
            }
        }
        i = j
    }
    return LinesPassResult(lines: out, margin: margin)
}

// ---------------------------------------------------------------- internals

/// The break tokens, in the alternation order of the Python regex (core.py:111).
private enum BreakKind {
    case soft
    case hard
    case eof
}

/// Hand-rolled equivalent of `re.split(rb'(\x8d\x0a|\x0d\x0a|\x8d|\x0d|\x0a)', data)`
/// followed by core.py:113-118's pairing loop. Swift has no bytes-regex, but the
/// alternation is ordered and non-overlapping, so a left-to-right scanner that tries
/// the two-byte tokens before their one-byte prefixes produces the identical stream.
///
/// A separator always emits a line (with possibly-empty text) — those empty lines are
/// the blank lines the break-run logic counts. Trailing text with no separator emits
/// an `.eof` line only when non-empty, matching core.py:117.
private func splitIntoRawLines(_ data: [UInt8]) -> [(text: [UInt8], kind: BreakKind)] {
    var result: [(text: [UInt8], kind: BreakKind)] = []
    var text: [UInt8] = []
    var i = 0
    while i < data.count {
        let b = data[i]
        let next: UInt8? = (i + 1 < data.count) ? data[i + 1] : nil
        if b == 0x8d && next == 0x0a {
            result.append((text, .soft)); text = []; i += 2
        } else if b == 0x0d && next == 0x0a {
            result.append((text, .hard)); text = []; i += 2
        } else if b == 0x8d {
            result.append((text, .soft)); text = []; i += 1
        } else if b == 0x0d || b == 0x0a {
            result.append((text, .hard)); text = []; i += 1
        } else {
            text.append(b)
            i += 1
        }
    }
    if !text.isEmpty {
        result.append((text, .eof))
    }
    return result
}

/// core.py:92-93 — strip bit 7 and drop everything that isn't a printable ASCII glyph.
private func visible(_ text: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(text.count)
    for b in text {
        let low = b & 0x7F
        if low >= 0x20 && low < 0x7F {
            out.append(low)
        }
    }
    return out
}

// Python's `bytes.strip()`/`.rstrip()` remove all ASCII whitespace, but these only ever
// run on `visible()` output, which by construction contains nothing outside 0x20...0x7E.
// Space is therefore the only whitespace that can appear, so these two helpers are
// exact stand-ins for Python's here — not a loosening of it.

private func isBlank(_ visible: [UInt8]) -> Bool {
    visible.allSatisfy { $0 == 0x20 }
}

private func rstrippingSpaces(_ visible: [UInt8]) -> [UInt8] {
    var end = visible.count
    while end > 0 && visible[end - 1] == 0x20 { end -= 1 }
    return Array(visible[..<end])
}

/// Length of the next line's first word — `nxt_vis.split(b' ', 1)[0]` at core.py:153.
private func firstWordLength(_ visible: [UInt8]) -> Int {
    visible.prefix(while: { $0 != 0x20 }).count
}
