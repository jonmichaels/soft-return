/// The native writer: serialize a `Document` back to WordStar bytes, plus the
/// round-trip CAPTURE helpers `parseWS` records the ledger with. Port of `writer.py`
/// and core.py's `_rt_*` block (tasks #20/#21, ruled 2026-08-06):
/// `emitWS(parseWS(x)) == x`, byte for byte, for as much of the corpus as achievable —
/// with the shortfall measured honestly (the round-trip census) rather than papered
/// over.
///
/// THE CONTRACT
/// ------------
/// The body is serialized FROM THE IR — spans, style sets, physical lines — so an
/// editor that mutates the IR and saves gets its mutations. What comes from
/// `doc.roundtrip` (the raw-source ledger `parseWS` now carries) is only what the IR
/// proper cannot express without faking:
///
///   * dot-command lines, byte-exact (the IR stores them bit-7-masked and rstripped;
///     mailmerge lines must NEVER be re-serialized from an interpretation — permanent
///     ruling);
///   * every consumed 0x1D symmetric sequence, spliced back verbatim at the
///     cleaned-stream offset where its expansion sits (a font block, a note, a tab —
///     an editor treats these as opaque objects);
///   * the raw separator bytes per line (`<8D 8A>` and friends);
///   * the trailing-blank run `linesPass` drops at EOF, and the file tail from the
///     bare 0x1A onward (^Z padding, the WS5+ style library);
///   * per-line byte restorations (`Line.fixups`) and trailing toggle runs
///     (`Line.togEnd`) for the decode's known lossy spots — masked WS4 flag bits,
///     collapsed 0x0F/0x1F/0xA0, dropped controls, ^D-vs-^B, bare extended bytes,
///     Symbol/Dingbats transliteration. Each is GUARDED: it patches only where the
///     re-encode matches what the parse predicted, so an edited line keeps its clean
///     re-encode instead of being corrupted.
///
/// A `Document` built without `parseWS` (no ledger) still writes: breaks are inferred
/// from the flags and defaults stand in for the rest.
///
/// The capture helpers mirror `decodeSpans`'s dispatch, case for case — change one,
/// change both.

/// A `Document` this writer cannot faithfully serialize (e.g. a Shift-JIS document,
/// whose parse rewrote the stream in a way no recorded offset survives). Refusal over
/// corruption, with the reason attached. Port of `WriteError`.
public struct WriteError: Error, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// ---------------------------------------------------------------- shared tables
//
// Style tag <-> the toggle byte that turns it on AND off. Built to mirror core's own
// WS_TOGGLES minus the ^D doublestrike alias (0x04 also maps to bold; re-emitting bold
// as ^B is the one honest choice the collapsed IR allows). The capture and the writer
// MUST agree byte for byte.

/// Canonical toggle byte per style, in ascending byte order (Python's `_TOGGLE_FOR` /
/// `_RT_TOGGLE_ON`, built from `sorted(WS_TOGGLES)` with setdefault).
let rtToggleFor: [(style: Style, byte: UInt8)] = [
    (.bold, 0x02), (.underline, 0x13), (.sup, 0x14), (.sub, 0x16),
    (.strike, 0x18), (.italic, 0x19),
]

/// Toggle byte (masked) -> style, the ^D alias included (core's `WS_TOGGLES`).
let rtToggleByByte: [UInt8: Style] = [
    0x02: .bold, 0x04: .bold, 0x13: .underline, 0x14: .sup, 0x16: .sub,
    0x18: .strike, 0x19: .italic,
]

/// The togglable state a span diff can express (Python's `_TOGGLABLE` /
/// `_RT_TOGGLABLE`): the six toggles plus the WS4 alternate-font flag.
let rtTogglable: Style = [.bold, .underline, .sup, .sub, .strike, .italic, .altFont]

/// Unicode -> cp437 byte, for everything above ASCII: the cp437 high half (0x80-0xFF).
/// Python's `_CP437_HIGH`/`_RT_CP437_HIGH` — shared by the writer and the fixup
/// capture, which predicts the writer's emissions.
let rtCP437High: [Character: UInt8] = {
    var out: [Character: UInt8] = [:]
    for b in 0x80...0xFF {
        let s = decodeCP437([UInt8(b)])
        if let ch = s.first, s.count == 1, out[ch] == nil {
            out[ch] = UInt8(b)
        }
    }
    return out
}()

/// The IBM GRAPHICS glyphs at control positions, reversed — minus 0x00, whose glyph is
/// `' '` (a space is a space; a wrapped NUL cannot win that collision). Python's
/// `_GRAPHICS_REV`/`_RT_GRAPHICS_REV`.
let rtGraphicsReverse: [Character: UInt8] = {
    var out: [Character: UInt8] = [:]
    for b in cp437Graphics.keys.sorted() where b != 0x00 {
        let s = cp437Graphics[b]!
        if let ch = s.first, s.count == 1, out[ch] == nil {
            out[ch] = b
        }
    }
    return out
}()

/// Inverse of the Symbol forward map, restricted to forward keys a decode can actually
/// REACH: transliteration runs on cp437-decoded text, so a key like U+00AD (soft
/// hyphen; the forward map sends it to '↑') can never fire — no cp437 byte decodes to
/// it — and reversing '↑' through it would corrupt a '↑' that was really a wrapped
/// 0x18 glyph (fontcrib.ws). First reachable key wins over sorted keys (no duplicate
/// values exist; sorting keeps this deterministic if one is ever added). Python's
/// `_RT_SYM_REV`.
let rtSymbolReverse: [UInt32: Unicode.Scalar] = {
    var out: [UInt32: Unicode.Scalar] = [:]
    for code in symbolEncoding.keys.sorted() {
        guard let scalar = Unicode.Scalar(code) else { continue }
        let reachable = (scalar.value >= 0x20 && scalar.value <= 0x7E)
            || rtCP437High[Character(scalar)] != nil
        guard reachable, let uni = symbolEncoding[code] else { continue }
        if out[uni.value] == nil { out[uni.value] = scalar }
    }
    return out
}()

/// Inverse of `transliterate` with the SAME passthrough rule: a character the forward
/// map never touched (an é wrapped in a triple inside a Symbol run, ASCII digits)
/// rides back unchanged. Deliberately NOT `untransliterate`, whose '?' degradation is
/// right for a PDF (the face cannot show the glyph) and wrong for a writer (the file
/// could). Dingbats reverse by the U+2700-block formula alone — the card-suit
/// exceptions are latin-1 keyed and unreachable from cp437 text, exactly like the
/// Symbol dead keys above. Port of `_rt_untranslit`.
func rtUntranslit(_ text: String, _ kind: SymbolTranslit?) -> String {
    guard let kind else { return text }
    var view = String.UnicodeScalarView()
    switch kind {
    case .math:
        for scalar in text.unicodeScalars {
            view.append(rtSymbolReverse[scalar.value] ?? scalar)
        }
    case .symbols:
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2701 && scalar.value <= 0x275E {
                view.append(Unicode.Scalar(scalar.value - 0x2700 + 0x20)!)
            } else {
                view.append(scalar)
            }
        }
    }
    return String(view)
}

/// Mirror of `encodeText` for ONE character — the fixup capture predicts emissions
/// with it, so the two must stay identical. Port of `_rt_encode_char`.
func rtEncodeChar(_ ch: Character, ws5: Bool) -> [UInt8] {
    guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
        return [0x3F]
    }
    let o = scalar.value
    if ch == "\t" || (o >= 0x20 && o < 0x7F) {
        return [UInt8(o)]
    }
    let b = rtCP437High[ch] ?? rtGraphicsReverse[ch]
    guard let b else { return [0x3F] }
    return ws5 ? [0x1B, b, 0x1C] : [b]
}

/// Is `b` (already bit-7-masked where applicable) a byte that leaves NO text behind in
/// `decodeSpans` — a style toggle, altfont, or a dropped control? Runs of these form
/// one span boundary, at which the writer emits a single net style diff; anything else
/// ends the run. 0x1B is handled by the caller (an escape is content; a trailing bare
/// 0x1B is dropped). Port of `_rt_cluster_byte`.
func rtClusterByte(_ b: UInt8) -> Bool {
    if rtToggleByByte[b] != nil || b == 0x01 || b == 0x0E || b == 0x1E || b == 0x7F {
        return true
    }
    return b < 0x20 && b != 0x09 && b != 0x0F && b != 0x1B && b != 0x1F
}

/// Exactly the bytes the writer's span diff emits for one style-set change: removals
/// then additions, each sorted by toggle byte (altfont keys sort/emit as 0x0E on
/// removal, 0x01 on addition). Port of `_rt_toggle_diff`.
func rtToggleDiff(_ prev: Style, _ want: Style) -> [UInt8] {
    var out: [UInt8] = []
    var removals: [(key: UInt8, emit: UInt8)] = []
    var additions: [(key: UInt8, emit: UInt8)] = []
    for (style, byte) in rtToggleFor {
        if prev.contains(style), !want.contains(style) { removals.append((byte, byte)) }
        if want.contains(style), !prev.contains(style) { additions.append((byte, byte)) }
    }
    if prev.contains(.altFont), !want.contains(.altFont) { removals.append((0x0E, 0x0E)) }
    if want.contains(.altFont), !prev.contains(.altFont) { additions.append((0x01, 0x01)) }
    out += removals.sorted { $0.key < $1.key }.map(\.emit)
    out += additions.sorted { $0.key < $1.key }.map(\.emit)
    return out
}

/// One forward pass over a line's raw bytes -> (fixups, togEnd). Port of
/// `_rt_line_capture` — see `Line.fixups`/`Line.togEnd` for what the two carry.
/// `active0` is the togglable style state in force as the line begins; `translit0` the
/// transliteration (if any) of the font in force at line start; `translitAt` mid-line
/// changes, entry-relative offsets ascending.
func rtLineCapture(_ raw: [UInt8], stripHibit: Bool, ws5: Bool,
                   active0: Style = [], translit0: SymbolTranslit? = nil,
                   translitAt: [(Int, SymbolTranslit?)] = []) -> (fixups: [Fixup], togEnd: [UInt8]) {
    var fx: [Fixup] = []
    var cur = active0
    var translit = translit0
    var pending = translitAt.sorted { $0.0 < $1.0 }
    var i = 0
    let n = raw.count
    while i < n {
        while let first = pending.first, first.0 <= i {
            translit = first.1
            pending.removeFirst()
        }
        let b0 = raw[i]
        let b = (stripHibit && b0 >= 0x80) ? b0 & 0x7F : b0
        if rtClusterByte(b), !(b == 0x1B && i + 1 < n) {
            // A toggle/dropped-control CLUSTER: one span boundary. The writer emits
            // only the NET style change, in its own canonical order — so <02 19>
            // against an italic run comes out <19 02>, <14 14> comes out empty, ^D
            // comes out ^B — and the fixup restores the file's own byte order.
            let start = i
            let prev = cur.intersection(rtTogglable)
            while i < n {
                let c0 = raw[i]
                let c = (stripHibit && c0 >= 0x80) ? c0 & 0x7F : c0
                if !rtClusterByte(c) || (c == 0x1B && i + 1 < n) {
                    break                        // escape/content ends the run
                }
                if let style = rtToggleByByte[c] {
                    cur.formSymmetricDifference(style)
                } else if c == 0x01 {
                    cur.insert(.altFont)
                } else if c == 0x0E {
                    cur.remove(.altFont)
                }
                i += 1
            }
            let seq = Array(raw[start..<i])
            if i >= n {
                // the run closes the line: it is the togEnd, not a fixup
                return (fx, seq)
            }
            let exp = rtToggleDiff(prev, cur.intersection(rtTogglable))
            if exp != seq {
                fx.append(Fixup(offset: start, expected: exp, original: seq))
            }
            continue
        }
        if b == 0x1B, i + 1 < n {
            // Extended-character escape. `decodeSpans` consumes <1B x> and lets a
            // following 1C fall into the drop set; the writer re-emits the decoded
            // character canonically — a full triple for glyphs and extended characters
            // (WS5+), the bare byte for a printable x.
            let x = raw[i + 1]
            var j = i + 2
            if j < n {
                let cj0 = raw[j]
                let cj = (stripHibit && cj0 >= 0x80) ? cj0 & 0x7F : cj0
                if cj == 0x1C { j += 1 }
            }
            let seq = Array(raw[i..<j])
            var exp: [UInt8]
            if ws5, x < 0x20 || x >= 0x7F {
                if translit == nil {
                    // through the shared encoder, not a blind triple: the glyph at
                    // 0x00 is ' ', which re-encodes as a bare space (LSRBOXES.MRG
                    // wraps NULs)
                    let ch: Character
                    if x < 0x20 || x == 0x7F {
                        ch = Character(cp437Graphics[x]!)
                    } else {
                        ch = Character(decodeCP437([x]))
                    }
                    exp = rtEncodeChar(ch, ws5: true)
                } else if x < 0x20 || x == 0x7F {
                    // A glyph span skips forward transliteration at decode, but the
                    // writer's reverse pass still sees its character — fontcrib.ws
                    // wraps '←' (glyph 0x1B) inside a Symbol run, and the reverse
                    // turns it into cp437 '¬'. Predict that emission so the fixup can
                    // restore the wrapped original.
                    let reversed = rtUntranslit(cp437Graphics[x]!, translit)
                    exp = reversed.count == 1 ? rtEncodeChar(reversed.first!, ws5: true) : [0x3F]
                } else {
                    // a wrapped TEXT character rides through the forward
                    // transliteration and back: <1B E0 1C> (cp437 α) in a Symbol run
                    // comes out as the face's own 'a'
                    let ch = decodeCP437([x])
                    let roundtripped = rtUntranslit(transliterate(ch, translit!), translit)
                    exp = roundtripped.count == 1
                        ? rtEncodeChar(roundtripped.first!, ws5: true) : [0x3F]
                }
            } else {
                exp = [x]
            }
            if exp != seq {
                fx.append(Fixup(offset: i, expected: exp, original: seq))
            }
            i = j
            continue
        }
        if b == 0x0F {
            fx.append(Fixup(offset: i, expected: [0x20], original: [b0]))   // binding space
        } else if b == 0x1F {
            fx.append(Fixup(offset: i, expected: [0x2D], original: [b0]))   // active soft hyphen
        } else if b == 0x09 {
            if b0 != b {
                fx.append(Fixup(offset: i, expected: [0x09], original: [b0]))
            }
        } else if b == 0xA0, !stripHibit {
            fx.append(Fixup(offset: i, expected: [0x20], original: [b0]))   // WS5+ soft space
        } else if ws5, b0 >= 0x80 {
            // bare extended byte: decoded as its cp437 character, which the writer
            // would re-wrap as a triple — patch back to the bare form
            fx.append(Fixup(offset: i, expected: [0x1B, b0, 0x1C], original: [b0]))
        } else if b0 != b {
            fx.append(Fixup(offset: i, expected: [b], original: [b0]))      // WS4 flag bit
        }
        i += 1
    }
    return (fx, [])
}

// ---------------------------------------------------------------- the writer

/// One span's text back to WordStar bytes. WS5+ wraps anything outside plain ASCII in
/// the `<1B x 1C>` extended-character escape (that is how real extended characters
/// travel — bare high bytes are soft/flag forms); WS4 has no escape machinery, so a
/// high character goes out as its bare cp437 byte. Port of `_encode_text`.
private func encodeText(_ text: String, ws5: Bool, into out: inout [UInt8]) {
    for ch in text {
        out += rtEncodeChar(ch, ws5: ws5)
    }
}

/// Spans -> bytes, emitting toggle bytes where the style set changes. `active` persists
/// across lines, exactly as it did at parse. Synthetic spans (note references,
/// dot-comment marks) carry `.fnref` and own no source bytes: the note's bytes are its
/// 0x1D block (spliced back from the ledger) or its dot line — skip them entirely.
/// Port of `_emit_spans`.
private func emitSpans(_ spans: [Span], active: inout Style, ws5: Bool,
                       into out: inout [UInt8], fonts: [FontChange]) {
    for span in spans {
        if span.styles.contains(.fnref) { continue }
        let want = span.styles.intersection(rtTogglable)
        out += rtToggleDiff(active, want)
        active = want
        var text = span.text
        // A Symbol/ZapfDingbats run was transliterated to real Unicode at decode; the
        // file's own bytes are the FONT's glyph codes, so send the text back through
        // the inverse before encoding.
        if let fontIndex = span.font, fontIndex < fonts.count,
           let kind = fontTranslitKind(fonts[fontIndex]) {
            text = rtUntranslit(text, kind)
        }
        encodeText(text, ws5: ws5, into: &out)
    }
}

/// Separator bytes for a `Line` with no recorded ones (a synthetic `Document`):
/// WordStar's canonical forms, from the flags. Port of `_infer_break`.
private func inferBreak(_ line: Line) -> [UInt8] {
    if line.overprint { return [0x0D] }                    // bare CR: ^PM overprint
    if line.soft { return [0x8D, 0x0A] }                   // soft return
    return [0x0D, 0x0A]                                    // the author's Return
}

/// Patch one line's emission back to its source bytes. Each fixup says: at line offset
/// p (SOURCE byte space) the writer emitted `expected`; the file had `original`.
/// Guarded: the first mismatch stops patching for the line — an edited line simply
/// keeps its clean re-encode (the flags/controls belonged to bytes that no longer
/// exist), never gets corrupted. Port of `_apply_fixups`.
private func applyFixups(_ body: inout [UInt8], start: Int, fixups: [Fixup]) {
    let unpatched = Array(body[start...])
    var out: [UInt8] = []
    var u = 0
    for fixup in fixups {
        let copy = fixup.offset - out.count
        if copy < 0 || u + copy > unpatched.count { break }
        out += unpatched[u..<(u + copy)]
        u += copy
        if u + fixup.expected.count > unpatched.count
            || Array(unpatched[u..<(u + fixup.expected.count)]) != fixup.expected {
            break
        }
        out += fixup.original
        u += fixup.expected.count
    }
    out += unpatched[u...]
    body.replaceSubrange(start..., with: out)
}

/// Serialize `doc` to native WordStar bytes. Port of `emit_ws`.
///
/// Throws `WriteError` for documents the writer cannot faithfully write: non-WordStar
/// variants (a printstream is printer output, not a document — there is nothing to
/// write back to), and Shift-JIS documents (see `RoundtripLedger.unsupported`).
public func emitWS(_ doc: Document) throws -> [UInt8] {
    let rt = doc.roundtrip
    let era = rt?.era ?? doc.era ?? doc.detection?.variant.rawValue
    guard era == "ws4" || era == "ws3" || era == "ws5+" else {
        throw WriteError("not a WordStar document (era: \(era ?? "nil")) -- "
            + "only ws4/ws5+ documents serialize back to .WS")
    }
    if let unsupported = rt?.unsupported {
        throw WriteError("cannot faithfully serialize: \(unsupported) "
            + "(the parse rewrote the stream; offsets are unreplayable)")
    }
    let ws5 = era == "ws5+"
    let fromParse = rt != nil

    // Dot lines by event anchor: "emit before event N", N counting Lines and form-feed
    // pagebreaks in order (the same counter parseWS stamped).
    var dots: [Int: [[UInt8]]] = [:]
    for dot in rt?.dots ?? [] {
        dots[dot.anchor, default: []].append(dot.raw + dot.brk)
    }

    var body: [UInt8] = []
    var active: Style = []
    var event = 0

    func flushDots() {
        for piece in dots[event] ?? [] {
            body += piece
        }
    }

    for block in doc.blocks {
        if block.origin == .fi {
            continue                     // fabricated `[insert:]` placeholder: its
                                          // bytes are the .fi dot line
        }
        if block.kind == .pagebreak {
            if block.origin == .ff {
                flushDots()
                body.append(0x0C)
                event += 1
            }
            continue                     // `.pa` bytes are its dot line
        }
        if block.kind == .condpage {
            continue                     // `.cp` likewise
        }
        for line in block.lines {
            flushDots()
            let start = body.count
            emitSpans(line.spans, active: &active, ws5: ws5, into: &body, fonts: doc.fonts)
            if !line.fixups.isEmpty {
                applyFixups(&body, start: start, fixups: line.fixups)
            }
            if !line.togEnd.isEmpty {
                // trailing toggles, verbatim (flag bits included) — and the writer's
                // own style state must flip with them, or the next line's span diff
                // would emit each toggle a second time
                body += line.togEnd
                for tb in line.togEnd {
                    let mb = tb & 0x7F
                    if mb == 0x01 {
                        active.insert(.altFont)
                    } else if mb == 0x0E {
                        active.remove(.altFont)
                    } else if let style = rtToggleByByte[mb] {
                        active.formSymmetricDifference(style)
                    }
                }
            }
            var brk = line.brkRaw
            if brk == nil {
                // No recorded separator. From parse this happens in exactly two
                // shapes, and both correctly emit nothing here: a line cut short by a
                // literal form feed (the 0x0C is the next block's byte), and the
                // visible half of a whitespace-only physical line, whose separator
                // rides on the phantom blank Line parseWS appends right after it. A
                // synthetic Document infers canonical separators instead.
                brk = fromParse ? [] : inferBreak(line)
            }
            body += brk!
            event += 1
        }
    }
    flushDots()                          // dot lines after the last event
    body += rt?.eofTail ?? []

    if ws5, let rt {
        // Un-translate the flagged control bytes (length-preserving, so the recorded
        // cleaned-stream offsets hold on the reconstruction)...
        for flagged in rt.flaggedAt where flagged.offset < body.count {
            body[flagged.offset] = flagged.original
        }
        // ...then splice every consumed symmetric sequence back over its own
        // expansion, in consumption order. Offsets are trusted, not searched: if the
        // body reconstruction drifted, the census reports the divergence — silently
        // resynchronising would hide it.
        if !rt.sym.isEmpty {
            var spliced: [UInt8] = []
            var pos = 0
            for entry in rt.sym {
                if entry.offset < pos || entry.offset > body.count {
                    continue             // unreplayable entry; census will say
                }
                spliced += body[pos..<entry.offset]
                spliced += entry.raw
                pos = entry.offset + max(entry.expansion, 0)
            }
            spliced += body[min(pos, body.count)...]
            body = spliced
        }
    }

    body += rt?.tail ?? []
    if !fromParse, bareEOF(body) == nil {
        body.append(0x1A)                // a synthetic document still ends like a
                                          // WordStar file
    }
    return body
}
