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
    /// A BARE CR terminator (WS documents only, `overprintCr`): `^PM` Overprint Line —
    /// the NEXT physical line prints at THIS line's own baseline. No blank-counting, no
    /// wrap inference: this is its own thing.
    case over
}

/// One physical line and the break that followed it. `text` is the RAW bytes as they
/// appeared in the file — high bits and control codes intact, for later passes to
/// decode. Only the classification logic looks at the "visible" projection.
public struct PhysicalLine: Hashable, Sendable {
    public let text: [UInt8]
    public let separator: LineSeparator
    /// Structural events falling inside this line, rebased to it. These used to be
    /// in-band sentinel bytes; every byte available for one is a real WordStar control
    /// code — see `StructuralMark`.
    public var marks: [(offset: Int, mark: StructuralMark)] {
        markPairs.map { (offset: $0.0, mark: $0.1) }
    }
    let markPairs: [(Int, StructuralMark)]

    public static func == (a: PhysicalLine, b: PhysicalLine) -> Bool {
        a.text == b.text && a.separator == b.separator
            && a.markPairs.map(\.0) == b.markPairs.map(\.0)
            && a.markPairs.map(\.1) == b.markPairs.map(\.1)
    }
    public func hash(into h: inout Hasher) {
        h.combine(text); h.combine(separator); h.combine(markPairs.map(\.0))
    }

    public init(text: [UInt8], separator: LineSeparator,
                markPairs: [(Int, StructuralMark)] = []) {
        self.markPairs = markPairs
        self.text = text
        self.separator = separator
    }
}

/// Result of a lines pass: the classified lines plus the margin the wrap test used.
public struct LinesPassResult: Hashable, Sendable {
    public let lines: [PhysicalLine]
    /// 90th percentile of soft-wrapped line lengths, floor 65 (the WS4 default).
    public let margin: Int
    /// Raw separator bytes per entry of `lines`, parallel by index (tasks #20/#21,
    /// round-trip writer): collected only, never classified, so the writer can re-emit
    /// `<8D 8A>` and friends instead of a canonicalised guess. Empty for an `.eof` line
    /// whose text simply ran out. Python's `raw_extras['breaks']`.
    public let rawBreaks: [[UInt8]]
    /// The verbatim bytes of the invisible trailing run this pass drops when a file
    /// ends in blank lines before its 0x1A — text and separators both, so the writer
    /// can put them back. Python's `raw_extras['eof_tail']`.
    public let eofTail: [UInt8]

    public init(lines: [PhysicalLine], margin: Int, rawBreaks: [[UInt8]] = [],
                eofTail: [UInt8] = []) {
        self.lines = lines
        self.margin = margin
        self.rawBreaks = rawBreaks
        self.eofTail = eofTail
    }
}

/// - Parameter softIsWrap: WS5+. A soft return is ALWAYS wrap, with no heuristic. The
///   would-it-have-fit test below is a WS4-era inference over FIXED-PITCH byte lengths;
///   WS5+ documents use proportional fonts, where byte length says nothing about printed
///   width, and the archive's own documents misread as ~5 "deliberate" breaks per
///   paragraph (204 spurious `\line` breaks in one story's RTF — found by Jon reading the
///   export, 2026-08-04). In WS5+ the editor re-wraps paragraphs dynamically, so a
///   surviving soft return IS wrap by construction; deliberate breaks are hard returns.
/// - Parameter overprintCr: WS documents only (`parseWS`). A BARE CR (WSFORMAT and the
///   WS4 manual agree) is `^PM` Overprint Line: the next line prints at THIS line's own
///   baseline. Gated so a CR-only text file (classic Mac line endings, reaching this via
///   `parsePrintstream`) never has every line overprint.
public func linesPass(_ data: [UInt8], tabAt: Set<Int> = [],
                      marks: [Int: [StructuralMark]] = [:],
                      softIsWrap: Bool = false, overprintCr: Bool = false) -> LinesPassResult {
    // core.py:108-110 — truncate at the first ^Z before anything else. The first BARE
    // one: a 0x1A wrapped in `<1B 1A 1C>` is a character to display, not end of file.
    var body = data
    if let cut = bareEOF(data) {
        body = Array(data[..<cut])
    }

    let lines = splitIntoRawLines(body, tabAt: tabAt, marks: marks, overprintCr: overprintCr)

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
    var rawBreaks: [[UInt8]] = []
    var eofTail: [UInt8] = []
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
                                        separator: kind == .soft ? .blankSoft : .blankHard,
                                        markPairs: lines[i].marks))
                rawBreaks.append(lines[i].brk)
            }
            i += 1
            continue
        }

        if kind == .over {
            // An overprint separator is its own thing: no blank-counting, no wrap
            // inference -- the next physical line shares this baseline.
            out.append(PhysicalLine(text: text, separator: .over, markPairs: lines[i].marks))
            rawBreaks.append(lines[i].brk)
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
            out.append(PhysicalLine(text: text, separator: .eof, markPairs: lines[i].marks))
            // This line's own real break, and the invisible trailing run the classifier
            // consumes without ever yielding (a file ending in blank lines before its
            // ^Z lost them entirely) — verbatim, text and separators both, so the
            // writer can put them back (#20/#21).
            rawBreaks.append(lines[i].brk)
            for b in (i + 1)..<lines.count {
                eofTail += lines[b].text
                eofTail += lines[b].brk
            }
            break
        }

        let sep: LineSeparator
        if nHard >= 1 && nTotal >= 2 {
            sep = .para                                     // core.py:143-144
        } else if nHard == 1 {
            sep = .line                                     // core.py:145-146
        } else {
            // core.py:147-154 — the wrap test, applied to an all-soft break run.
            var nextVis = visible(lines[j].text)
            if lines[j].machineIndent {
                // Machine indent: WordStar re-stamped the left margin onto this wrapped
                // line from a TAB. Drop it before measuring, or the "first word" is the
                // empty string before the spaces, W is 0, and the wrap test concludes
                // the next word would have fit — which lands back on 'deliberate' by a
                // different route.
                nextVis = Array(nextVis.drop(while: { $0 == 0x20 }))
            }
            if nextVis.first == 0x20 && !lines[j].machineIndent {
                // An indented continuation the AUTHOR typed is a deliberate break (a
                // poem, a block quote). One WordStar itself emitted from a tab is not:
                // it re-stamps the left indent onto every wrapped line, so treating that
                // as deliberate stopped whole paragraphs from ever reflowing in Modern —
                // they rendered as physical lines with the wrong margins. A3.
                sep = .line                                 // indented continuation = deliberate
            } else if softIsWrap {
                // WS5+: a surviving soft return IS wrap by construction (the editor
                // re-wraps dynamically; deliberate breaks are hard returns). The fit
                // heuristic below is a WS4 fixed-pitch inference that misfires on
                // proportional text — 204 spurious breaks in one story's RTF (Jon's
                // export review, 2026-08-04).
                sep = .wrap
            } else {
                let L = rstrippingSpaces(vis).count
                let W = firstWordLength(nextVis)
                // STRICT `<`: WS4 wrapped even when the next word would land EXACTLY at
                // the margin, so an exact fit is still wrap, not a deliberate break.
                // Do not "fix" this to `<=` — that exact bug cost a release.
                sep = (L + 1 + W < margin) ? .line : .wrap
            }
        }
        out.append(PhysicalLine(text: text, separator: sep, markPairs: lines[i].marks))
        rawBreaks.append(lines[i].brk)
        // The blanks this run consumed, in document order, after the line they
        // follow. They were counted above to classify `sep` and are now also kept
        // as content — the counting and the keeping are separate jobs.
        if i + 1 < j {
            for b in (i + 1)..<j where lines[b].kind != .eof {
                out.append(PhysicalLine(text: lines[b].text,
                                        separator: lines[b].kind == .soft ? .blankSoft : .blankHard,
                                        markPairs: lines[b].marks))
                rawBreaks.append(lines[b].brk)
            }
        }
        i = j
    }
    return LinesPassResult(lines: out, margin: margin, rawBreaks: rawBreaks,
                           eofTail: eofTail)
}

// ---------------------------------------------------------------- internals

/// Offset of the file's real EOF — the start of the trailing run of ^Z padding
/// WordStar writes to fill out a CP/M sector, not the first coincidental 0x1A byte.
///
/// Two things can make a bare 0x1A look like EOF when it isn't:
///   - wrapped: the middle byte of a `<1B x 1C>` wrapped extended character
///     (ASCIITAB.WS wraps every control code to print its chart, `<1B 1A 1C>`
///     included; cutting at that middle byte amputated 86% of the file);
///   - in-content: a lone bare 0x1A used as an ordinary control byte deep inside
///     real content, with no EOF significance at all (REF/ROUNDED.BRD's
///     box-drawing template hits one at offset 48, but the file is a genuine
///     6.4 KB document — its real trailing padding doesn't start until offset
///     6324).
///
/// So: collect every BARE 0x1A (skipping wrapped-triple middle bytes), then look
/// for a run of >= `padMin` CONSECUTIVE bare offsets — genuine disk-block padding,
/// never an isolated in-content byte — and return where that run starts. If no
/// such run exists, the file has no padding tail at all; fall back to the first
/// bare 0x1A, same as before this function grew run-detection — a document can
/// be genuinely truncated right at a real, unpadded EOF marker.
///
/// `nil` when there is no bare 0x1A at all. Direct port of `_bare_eof`. Internal,
/// not private: `parseWS`'s round-trip ledger recomputes the same cut (#20/#21),
/// and the writer appends a canonical 0x1A only when absent.
func bareEOF(_ data: [UInt8], padMin: Int = 8) -> Int? {
    var bare: [Int] = []
    var at = 0
    while at < data.count {
        if data[at] == 0x1a {
            let wrapped = at >= 1 && data[at - 1] == 0x1b
                && at + 1 < data.count && data[at + 1] == 0x1c
            if !wrapped { bare.append(at) }
        }
        at += 1
    }
    guard !bare.isEmpty else { return nil }
    var runStart = bare[0]
    var runLen = 1
    for i in 1..<bare.count {
        if bare[i] == bare[i - 1] + 1 {
            runLen += 1
        } else {
            if runLen >= padMin { return runStart }
            runStart = bare[i]
            runLen = 1
        }
    }
    if runLen >= padMin { return runStart }
    return bare[0]
}

/// The break tokens, in the alternation order of the Python regex (core.py:111).
private enum BreakKind {
    case soft
    case hard
    case eof
    /// A BARE CR (WS documents only) — `^PM` Overprint Line.
    case over
}

/// Hand-rolled equivalent of
/// `re.split(rb'(\x8d\x8a|\x8d\x0a|\x0d\x8a|\x0d\x0a|\x8d|\x8a|\x0d|\x0a)', data)`
/// followed by core.py's pairing loop. Swift has no bytes-regex, but the alternation is
/// ordered and non-overlapping, so a left-to-right scanner that tries the two-byte tokens
/// before their one-byte prefixes produces the identical stream.
///
/// THE LF OF A RETURN PAIR MAY CARRY THE HIGH BIT TOO. MEASURED on a real WS7 document
/// (2026-08-04), the soft return written after every end-of-page block is `<8D 8A>` — both
/// bytes flagged — and a hard CR can be followed by a flagged LF (`<0D 8A>`). WordStar's
/// own printer masks the flag and performs the line advance (traced in PCL: a
/// vertical-move escape, zero glyphs); decoding 0x8A as text invented an 'e-grave' at 14
/// page boundaries in one document.
///
/// A separator always emits a line (with possibly-empty text) — those empty lines are
/// the blank lines the break-run logic counts. Trailing text with no separator emits
/// an `.eof` line only when non-empty, matching core.py:117.
/// `machineIndent` marks a line whose leading whitespace was emitted by WordStar from a
/// TAB, not typed by the author — see the wrap test, where the difference decides whether
/// a paragraph reflows at all. A3.
/// Python's tuple-ordering key for a mark's own KIND + associated values: the STRING TAG
/// each Python mark tuple opens with (`'colour'`, `'fnref'`, `'font'`, `'pctl'`,
/// `'softpage'`, `'style'`), then its own trailing values in the SAME order Python's own
/// tuple carries them. Used only to break a `rel` tie in `splitIntoRawLines`'s own final
/// sort — see that call site's comment for why the tie exists and matters.
private func pythonMarkOrderKey(_ m: StructuralMark) -> (kind: String, values: [Int]) {
    switch m {
    case .colour(let index): return ("colour", [index])
    case .fnref: return ("fnref", [])
    case .font(let index): return ("font", [index])
    // Register C2: the Python mark tuple grew a 4th element (the pcl-program index),
    // which its own `sorted()` compares only when kind/hmi/byteLen all tie — two
    // print controls at the SAME offset with the SAME declared width and display
    // length. `nil` (a display-only control, Python's `None`) sorts first as -1;
    // Python would raise comparing None to an int there, which is not a behaviour
    // worth reproducing.
    case .pctl(let hmi, let byteLen, let pcl): return ("pctl", [hmi, byteLen, pcl ?? -1])
    case .pix(let index, let byteLen): return ("pix", [index, byteLen])
    case .softpage: return ("softpage", [])
    case .tab(let absHMI, let leader, let cols): return ("tab", [absHMI, Int(leader), cols])
    case .style(let handle): return ("style", [handle])
    }
}

/// Python tuple comparison (`(kind, *values) < (kind, *values)`): kind name first, then
/// values pairwise, then — Python's own rule for a tuple that's a strict PREFIX of the
/// other — the shorter one sorts first.
private func pythonMarkOrderLess(_ a: StructuralMark, _ b: StructuralMark) -> Bool {
    let ka = pythonMarkOrderKey(a)
    let kb = pythonMarkOrderKey(b)
    if ka.kind != kb.kind { return ka.kind < kb.kind }
    for i in 0..<Swift.min(ka.values.count, kb.values.count) where ka.values[i] != kb.values[i] {
        return ka.values[i] < kb.values[i]
    }
    return ka.values.count < kb.values.count
}

private func splitIntoRawLines(_ data: [UInt8], tabAt: Set<Int>,
                               marks: [Int: [StructuralMark]] = [:],
                               overprintCr: Bool = false)
    -> [(text: [UInt8], kind: BreakKind, machineIndent: Bool,
         marks: [(Int, StructuralMark)], brk: [UInt8])] {
    var result: [(text: [UInt8], kind: BreakKind, machineIndent: Bool,
                  marks: [(Int, StructuralMark)], brk: [UInt8])] = []
    var starts: [(at: Int, len: Int, idx: Int)] = []
    var text: [UInt8] = []
    var i = 0
    // Offset of the CURRENT line's first byte, so a tab-derived indent recorded by
    // `symmetricBlocks` can be matched to the line it starts. Python tracks the same
    // figure as `at`, advancing by `len(text) + len(brk)` per line.
    var lineStart = 0
    func emit(_ kind: BreakKind, _ advance: Int) {
        starts.append((at: lineStart, len: text.count, idx: result.count))
        // this line's raw separator bytes, for the round-trip ledger (#20/#21)
        let brk = advance > 0 ? Array(data[i..<(i + advance)]) : []
        result.append((text, kind, tabAt.contains(lineStart), [], brk))
        lineStart += text.count + advance
        text = []
    }
    while i < data.count {
        let b = data[i]
        let next: UInt8? = (i + 1 < data.count) ? data[i + 1] : nil
        if b == 0x1b && i + 2 < data.count && data[i + 2] == 0x1c {
            // A `<1B x 1C>` wrapped extended character is matched FIRST and is TEXT: its
            // middle byte can be any value 00h-FFh, and a wrapped 0x0A or 0x0D is a chart
            // glyph, not a line break — ASCIITAB.WS's table rows broke apart at those
            // cells. The triple wins the alternation (Python matches it as the first
            // branch of the regex, ahead of every break token), so a break inside one is
            // never seen; all three bytes travel on to `decodeSpans`.
            text.append(b)
            text.append(data[i + 1])
            text.append(data[i + 2])
            i += 3
        } else if b == 0x8d && (next == 0x8a || next == 0x0a) {
            emit(.soft, 2); i += 2
        } else if b == 0x0d && (next == 0x8a || next == 0x0a) {
            // The break's FIRST byte decides the kind (Python's `brk[0] in (0x8D, 0x8A)`),
            // so a flagged LF after a hard CR is still a hard return.
            emit(.hard, 2); i += 2
        } else if b == 0x8d || b == 0x8a {
            emit(.soft, 1); i += 1
        } else if b == 0x0d {
            // A BARE CR (not paired above with a following LF) is `^PM` Overprint Line
            // in a WS document; a CR-only text file (classic Mac endings) never opts in.
            emit(overprintCr ? .over : .hard, 1); i += 1
        } else if b == 0x0a {
            emit(.hard, 1); i += 1
        } else {
            text.append(b)
            i += 1
        }
    }
    if !text.isEmpty {
        emit(.eof, 0)
    }
    // Attach each mark to the line containing it. A mark landing INSIDE a break — a
    // soft page break sits between two lines, not within one — belongs to the line
    // that FOLLOWS it, at relative offset 0. Otherwise it would be silently dropped,
    // which is the failure the sentinels were replaced to end.
    //
    // ONE EXCEPTION (b26): `.fnref` is a backward-looking ANCHOR, not forward-looking
    // state -- see its own handling below.
    for (off, mlist) in marks.sorted(by: { $0.key < $1.key }) {
        for m in mlist {
            if let s = starts.first(where: { off >= $0.at && off < $0.at + $0.len }) {
                result[s.idx].marks.append((off - s.at, m))
            } else if case .fnref = m, let prev = starts.first(where: { $0.at + $0.len == off }) {
                // A note REFERENCE anchors to the text immediately BEFORE it -- WordStar
                // renders a footnote/endnote/annotation marker inline at the point in the
                // body where the author left it, never at the start of whatever comes
                // next. A note's own bytes contribute nothing to the cleaned stream (see
                // `symmetricBlocks`), so its mark's offset is always exactly wherever the
                // cleaned stream already was -- the anchor text's own END, which is ALSO,
                // whenever the note sits at the end of a line followed by a blank
                // paragraph line (measured: LYING.WS's "...Thirty-Dollar Prize." + its
                // footnote), the START of that following zero-length blank line. The
                // generic "forward to the next line" rule below picked the blank line
                // then (offset 0 in an otherwise empty line -- the marker breaks to its
                // own line, byte-verified against real WS7's LYING.pcl, which prints the
                // superscript "1" inline at the end of the Prize. line).
                // `starts` is in ascending-offset emission order, so the FIRST line whose
                // text ends exactly at `off` is the real anchor line, never a same-offset
                // zero-length line that happens to start where it ends (that line, if
                // any, necessarily comes later in this list).
                result[prev.idx].marks.append((prev.len, m))
            } else if let n = starts.first(where: { $0.at >= off }) {
                result[n.idx].marks.append((0, m))
            } else if let last = starts.last {
                result[last.idx].marks.append((last.len, m))
            }
        }
    }
    // Python's marks are literal tagged tuples (`('style', w0)`, `('font', idx)`, ...),
    // and its own final pass — `mk.sort()` over the SAME `(rel, mark)` pairs built here —
    // is a full tuple comparison: ties on `rel` fall through to comparing the MARK
    // itself, kind name first (alphabetically, since Python compares the tag strings),
    // then its own associated values. Two ZERO-WIDTH marks can genuinely land at the
    // same relative offset — a style-select immediately followed by ANOTHER style-select
    // (found via the v7 corpus parity sweep: PRINTER.PS, a printer-driver font-catalog
    // whose own rows re-select a style redundantly right where the previous one ends) —
    // and `[$0.0 < $1.0]` alone is merely STABLE for that tie, preserving byte-scan
    // insertion order, which is NOT what Python's tuple comparison does. Swift's own
    // mark-consumption (`decodeSpans`'s `pendingFonts` loop) applies same-offset font
    // changes in LIST order and keeps only the LAST one's effect before any byte
    // decodes, so an out-of-order tie silently attaches the wrong font to the span that
    // follows -- byte-identical marks, wrong resulting font.
    for i in result.indices {
        result[i].marks.sort { a, b in
            a.0 != b.0 ? a.0 < b.0 : pythonMarkOrderLess(a.1, b.1)
        }
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
