/// The PDF emitter's writer half: laid-out pages -> PDF bytes. Port of `pdf.py`'s `_esc`
/// (pdf.py:32-34), `_page_stream` (pdf.py:131-152) and `emit_pdf` (pdf.py:154-207).
///
/// Hand-written PDF 1.4 with no dependencies, which is what the base-14 set buys: fonts that
/// every reader already has, so nothing is embedded and the layout is exact. Modern mode is
/// Courier-only typewriter setting, by ruling; PRINTED mode also selects the faces the
/// document's own font blocks chose (`PDFFonts.swift`). `PDFLayout` decided what goes where
/// in characters and line counts; this file is the only part that knows what a PDF looks like.
///
/// EVERY COORDINATE IS CARRIED IN INTEGER TENTHS OF A POINT. Python does this arithmetic in
/// binary floats and lets `'%.1f'` round the accumulated error away — see `Formatting.swift`
/// for why that always works there and why it is not worth reproducing here. No `Double`
/// appears in this file.

/// The four Courier variants, in object-numbering order. `pdf.py:27-30` splits this across
/// two dicts keyed by `(bold, italic)` and by name; an ordered array is one structure and
/// fixes the order that `font_dict` and the object numbers both depend on.
///
/// Python gets that order from dict insertion order (`for f in ('F1', 'F2', 'F3', 'F4')`),
/// which is guaranteed in modern Python but is a property of the literal rather than of the
/// data. Here the order IS the data.
let pdfFonts: [(name: String, baseFont: String)] = [
    ("F1", "Courier"),
    ("F2", "Courier-Bold"),
    ("F3", "Courier-Oblique"),
    ("F4", "Courier-BoldOblique"),
]

/// The Courier variant for a style combination — Python's `FONTS[(bold, italic)]`.
///
/// Bold is the low bit and italic the high one, which reproduces the F1/F2/F3/F4 assignment
/// exactly: regular, bold, oblique, bold-oblique.
func pdfFont(bold: Bool, italic: Bool) -> String {
    pdfFonts[(bold ? 1 : 0) + (italic ? 2 : 0)].name
}

/// Encode text for a PDF string literal: Latin-1 with `?` for anything that doesn't fit,
/// then backslash and parentheses escaped. Port of `_esc` (pdf.py:32-34).
///
/// THE TWO ORDERINGS HERE ARE NOT EQUALLY LOAD-BEARING, and the difference is worth writing
/// down because both look like "order matters":
///
/// - Backslash BEFORE parens is essential. Escaping parens first would leave their new
///   backslashes for the backslash pass to double, turning `(` into `\\(` — a literal
///   backslash followed by an unescaped paren, which unbalances the string and corrupts the
///   rest of the content stream. Checked against the reference: of 584 strings drawn from
///   `a \ ( ) é — Ł ?`, 326 come out differently if the passes are swapped.
/// - Latin-1 BEFORE escaping is not observable at all. The two orders agree on every one of
///   those 584 strings, and must: the encoder's replacement character is `?`, which is
///   neither a backslash nor a parenthesis, so it can never create or consume an escape.
///
/// So the passes below are three separate replacements rather than one combined loop —
/// mutating any one of them, or their order, changes the output and the vectors say so.
func esc(_ text: String) -> [UInt8] {
    // Python's `text.encode('latin-1', 'replace')`. Latin-1 is the identity map on 0x00-0xFF,
    // so a scalar fits exactly when it is in that range; everything above becomes one `?`
    // per CHARACTER, which is what the `replace` error handler does.
    var raw: [UInt8] = []
    raw.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        raw.append(scalar.value <= 0xFF ? UInt8(scalar.value) : 0x3F)   // 0x3F = '?'
    }
    var out = replacingEach(raw, 0x5C, with: [0x5C, 0x5C])              // \  -> \\
    out = replacingEach(out, 0x28, with: [0x5C, 0x28])                  // (  -> \(
    out = replacingEach(out, 0x29, with: [0x5C, 0x29])                  // )  -> \)
    return out
}

/// One pass of Python's `bytes.replace`, for a single-byte needle.
private func replacingEach(_ bytes: [UInt8], _ needle: UInt8, with replacement: [UInt8]) -> [UInt8] {
    guard bytes.contains(needle) else { return bytes }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for byte in bytes {
        if byte == needle {
            out.append(contentsOf: replacement)
        } else {
            out.append(byte)
        }
    }
    return out
}

/// A stroked horizontal rule — the underline and strike-through. `0.6 w` sets the pen width;
/// `m`/`l`/`S` move, line, and stroke. `x` and `y` are both real `Double` point values since
/// ctrl-kd 2.0.0 — see `pageStream`'s doc comment for why.
private func rule(xFrom: Double, xTo: Double, y: Double) -> [UInt8] {
    let x1 = fixedOneDecimalDouble(xFrom)
    let x2 = fixedOneDecimalDouble(xTo)
    let yy = fixedOneDecimalDouble(y)
    return Array("0.6 w \(x1) \(yy) m \(x2) \(yy) l S".utf8)
}

/// One page's content stream. Port of `_page_stream` (pdf.py:131-152).
///
/// - Parameter top: the top margin in points — `topModern`, or `printedTop(doc)` for Printed
///   mode (PDFLayout.swift; a print stream with no page geometry gets the fixed `topPrinted`
///   from inside that function, same as before ctrl-kd 1.3.0).
/// - Parameter pageHeight: the resolved page height in points (`resolvedPageHeight`,
///   PDFLayout.swift) — `PDFMetrics.pageHeight` (Letter, 792) unless the document is Printed
///   mode with its own `.pl`-derived geometry. Defaulted so every existing caller that only
///   ever meant a plain Letter page (every test in this file, and the byte vectors) is
///   unaffected; `emitPDF` is the only caller that ever passes something else.
/// - Parameter lead: baseline-to-baseline distance in points — `PDFMetrics.lead` (12) for
///   Modern mode and print streams, or `printedLead(doc)` for a Printed-mode WS document
///   (PDFLayout.swift; ctrl-kd 1.3.0's `.lh`-derived figure). Defaulted to the fixed lead so
///   every pre-1.3.0 caller is unaffected.
/// - Parameter size: the base type size in points — `PDFMetrics.size` (12) for Modern mode
///   and print streams, or `printedSize(doc)` for a Printed-mode WS document (PDFLayout.swift;
///   ctrl-kd 2.0.0's `.cw`-derived figure). Defaulted to the fixed size so every pre-2.0.0
///   caller is unaffected. The sup/sub size (Python: `max(1, round(size * 2 / 3))`, 8 at the
///   default 12) is derived from this ONCE, not read from the fixed `8` the writer used
///   before 2.0.0.
/// - Parameter left: the left edge of text in points — `PDFMetrics.margin` (72) for Modern
///   mode and print streams, or `printedLeft(doc, size)` for a Printed-mode WS document
///   (PDFLayout.swift; ctrl-kd 2.0.0's `.po`-derived figure). Defaulted to the fixed margin
///   so every pre-2.0.0 caller is unaffected.
///
/// Text is placed absolutely, one `BT`/`ET` block per styled run: PDF's own text-positioning
/// operators track a line matrix that would have to be reset anyway, and Courier's fixed
/// advance means the x for every run is known here without asking a font for metrics.
///
/// CRITICAL FLOAT DETAIL (ctrl-kd 2.0.0): `x` is now a real `Double` in POINTS, same as `y`
/// below — the tenths-of-a-point convention this file used through 1.3.0 assumed `x` only
/// ever moved by exact multiples of 0.1 (an integer `size` times 0.6), which broke the moment
/// the LEFT MARGIN ITSELF could be `.po`-derived (`8 * 12 * 0.6` is exact, but not every
/// `.po`/`.cw` combination is). So `x` accumulates exactly as Python's `float` does — starting
/// at `left`, each advance `w = Double(charCount) * Double(sizeHere) * 0.6` — and
/// `fixedOneDecimalDouble` rounds the accumulated error away per line, same as `'%.1f'` does
/// on the Python side. Swift's `Double` and Python's `float` are both IEEE binary64, so
/// identical operation order gives identical bits. `y` was already a real `Double` in points
/// since 1.3.0 (`lead` can be irrational-at-48ths, e.g. `.lh 1C` -> `28.346456692913385`pt),
/// unaffected by this change. The DEFAULT left/size (72.0/12, both accumulated from integer
/// starts) are exact at every step, so every document that never sets `.po`/`.cw` still
/// produces byte-identical output to before this change.
/// Header and footer text for one page, as content-stream ops.
///
/// Geometry MEASURED on WordStar 4 (2026-08-03), not inferred:
///
///     line 0                      header line 1
///     ...                         header lines 2-5, if used
///     .hm blank lines
///     body
///     .fm blank lines
///     line pl-.mb+.fm             footer line 1
///
/// so the header sits at the very top of the paper and the footer `.fm` lines below the
/// body's last line. `#` becomes the page number — WordStar's own token, seen rendering
/// as "PAGE 1 / PAGE 2 / PAGE 3" in the probe.
///
/// `.op` ("omit page number ... unless the # has been used in footers or headers")
/// suppresses the substitution, leaving the token out rather than printing a literal `#`.
///
/// Printed mode only: Modern mode reflows and has no running heads.
func runningOps(
    _ doc: Document, pageNo: Int, pageHeight: Int, lead: Double, size: Int,
    left: Double, printed: Bool
) -> [[UInt8]] {
    guard printed, !(doc.headers.isEmpty && doc.footers.isEmpty) else { return [] }
    // `.op` does NOT suppress a `#` in a header or footer. WSFORMAT.TXT is explicit:
    // ".OP  Omit page number.  At print time no page numbers are printed UNLESS THE
    // '#' HAS BEEN USED IN FOOTERS OR HEADERS." It suppresses the AUTOMATIC page
    // number, the one `.pc` positions; a `#` the author put in a running head is the
    // exemption, not the target.
    //
    // This was implemented backwards on both sides, and the test asserted the backwards
    // behaviour while its docstring quoted the exempting clause. See ctrl-kd 88a0c43.
    let pl = Int(doc.page?.plLines ?? defaultPlLines)
    let mb = Int(doc.page?.mbLines ?? defaultMbLines)
    let fm = Int(doc.page?.fmLines ?? 2)

    // `#` -> the page number. Written by hand because this module imports nothing —
    // `replacingOccurrences` is Foundation, which CtrlKD deliberately does without.
    func render(_ txt: String) -> String {
        let replacement = String(pageNo)
        var out = ""
        for ch in txt {
            if ch == "#" { out += replacement } else { out.append(ch) }
        }
        return out
    }
    func op(_ txt: String, line: Int) -> [UInt8]? {
        let y = Double(pageHeight) - Double(line) * lead - Double(size)
        guard y >= 0 else { return nil }
        var out = Array("BT /\(pdfFont(bold: false, italic: false)) \(size) Tf 0 Ts ".utf8)
        out += Array("\(fixedOneDecimalDouble(left)) \(fixedOneDecimalDouble(y)) Td (".utf8)
        out += esc(render(txt))
        out += Array(") Tj ET".utf8)
        return out
    }

    var ops: [[UInt8]] = []
    for n in doc.headers.keys.sorted() {
        guard let txt = doc.headers[n], !txt.isEmpty else { continue }
        if let o = op(txt, line: n - 1) { ops.append(o) }
    }
    let footLine = pl - mb + fm
    for n in doc.footers.keys.sorted() {
        guard let txt = doc.footers[n], !txt.isEmpty else { continue }
        if let o = op(txt, line: footLine + n - 1) { ops.append(o) }
    }
    return ops
}

/// One coalesced segment of a line, resolved to the face and size it will be set in.
/// Python's `segs` tuple in `_page_stream`.
private struct LineSegment {
    let text: String
    let styles: Style
    let family: PDFFamily
    let size: Int
    /// The `Document.fonts` entry this run points at, or `nil` for a run with no font block —
    /// every WS4 file, every print stream, and every run before a WS5+ document's first font
    /// change. Carried because the LAYOUT needs its `width1800`, not just its face.
    let entry: FontChange?
    /// This segment is a line's LEADING WHITESPACE and is measured in the document's print
    /// columns rather than in its font. Set by `splitIndent`.
    let indent: Bool
}

/// `(point size, baseline rise)` for a span set at `size`. Port of `pdf._sized`.
///
/// Superscript and subscript are both SET SMALLER, not just moved: one size test covering
/// either, then the rise chooses the direction. `sup` wins if a span somehow carries both,
/// matching Python's nested conditional. Reduced to 2/3 — 8pt at the default 12, the ratio
/// this emitter has always used.
private func sized(_ styles: Style, _ size: Int) -> (points: Int, rise: Int) {
    if styles.contains(.sup) { return (max(1, roundHalfToEven(Double(size * 2) / 3.0)), 3) }
    if styles.contains(.sub) { return (max(1, roundHalfToEven(Double(size * 2) / 3.0)), -2) }
    return (size, 0)
}

/// Underline / strikethrough as stroked paths (PDF has no text attribute for either), for a
/// span occupying `w` points from `x`. Port of `pdf._rules`.
private func rules(_ styles: Style, _ text: String, x: Double, y: Double, w: Double) -> [[UInt8]] {
    // A rule under a run of pure whitespace would be a stray dash, so Python guards both
    // with `text.strip()` — non-empty after stripping, i.e. the run has ink.
    guard text.contains(where: { !$0.isWhitespace }) else { return [] }
    var ops: [[UInt8]] = []
    if styles.contains(.underline) { ops.append(rule(xFrom: x, xTo: x + w, y: y - 1.5)) }
    if styles.contains(.strike) { ops.append(rule(xFrom: x, xTo: x + w, y: y + 3)) }
    return ops
}

/// Per-character advance in POINTS for one span — WordStar's own number. Port of
/// `pdf._span_pitch`.
///
/// A WS5+ font block's FIRST word is the font width in HMIs (1/1800in): the pitch WordStar
/// itself laid the document out on, and the pitch it sent the printer. 1800 HMI = 1 inch =
/// 72pt, so the conversion is /25.
///
/// A span with no font block — every WS4 file, every print stream, and every run before a
/// WS5+ document's first font change — gets the document's own `.cw`-derived pitch instead.
/// `.cw` is character width in 1/120in, which `printedSize` already resolved into the point
/// size for exactly this reason (a Courier em advances 0.6, so cw/120in per character IS a
/// cw-point font), so the pitch here is that size's 0.6em. Written in POINTS rather than
/// converted through HMI on purpose: it is arithmetically the same number and it is the same
/// float this emitter has always produced, which is what keeps a fontless PDF byte-identical.
func spanPitch(_ entry: FontChange?, _ pt: Int) -> Double {
    if let width = entry?.width1800, width != 0 { return Double(width) / hmiPerPoint }
    return Double(pt) * 0.6
}

/// The slot WordStar reserved for a run of `count` characters, in points.
///
/// THE FONTLESS BRANCH IS NOT `count * spanPitch(...)`, and the difference is one of
/// evaluation order, not of value. The pitch is `pt * 0.6`, so the two forms are
/// `count * (pt * 0.6)` and `(count * pt) * 0.6` — equal in exact arithmetic, and not always
/// equal in binary64: at count 3, pt 12, the first is 21.599999999999998 and the second is
/// 21.6. This emitter has multiplied in the SECOND order since it existed, `x` accumulates
/// these, and the fontless digests are pinned on the result. So the legacy order is kept
/// verbatim where it can be observed, and the HMI form is used only where there was no
/// previous answer to preserve.
private func spanTarget(_ entry: FontChange?, _ pt: Int, count: Int) -> Double {
    if entry?.width1800 ?? 0 != 0 { return Double(count) * spanPitch(entry, pt) }
    return Double(count) * Double(pt) * 0.6
}

/// `(Tz percentage or nil, width actually occupied)` for one span asked to fill `targetW`
/// points. Port of `pdf._tz_scale`.
///
/// Courier lands on WordStar's grid by construction — 600/1000 em is exactly the 0.6 the
/// pitch was derived from — so the ratio comes out 100 and no `Tz` is emitted at all. Nothing
/// else does: Times at 12pt sets a word in whatever width Times wants, which is not the width
/// WordStar reserved for it, and by the end of a line the accumulated error is a word or
/// more. `AFM.swift` gives the natural width; `Tz` (horizontal scaling, percent) closes the
/// gap, so the span occupies the grid slot the file asked for and the NEXT span starts where
/// WordStar put it.
///
/// `nil` means "emit no scaling" and comes from three different places, all of which want the
/// same operator (or the absence of one) but not the same width:
///   * the ratio is 100 — Courier, or any face whose metrics happen to agree. Occupies the
///     target; nothing to say.
///   * the ratio is outside `[tzMin, tzMax]` — the metrics disagree pathologically (see the
///     clamp's own note). The span keeps its NATURAL width and the rest of the line shifts
///     with it, because overprinting the next span is worse than losing the grid.
///   * there is no metric at all (a face `AFM.swift` cannot measure, or a string of glyphs it
///     has no widths for). Nothing to compute a ratio from.
func tzScale(_ text: String, _ baseFont: String, _ pt: Int, _ targetW: Double)
    -> (scale: Double?, width: Double)
{
    let natural = stringWidthPt(text, baseFont, pt)
    if natural <= 0 || targetW <= 0 { return (nil, natural) }
    let scale = targetW / natural * 100.0
    if hundredths(scale) == hundredths(tzDefault) { return (nil, targetW) }
    if !(tzMin <= scale && scale <= tzMax) { return (nil, natural) }
    return (scale, targetW)
}

/// `segs` with each entry gaining an INDENT flag, and the first span split where a line's
/// leading whitespace ends. Port of `pdf._split_indent`.
///
/// The indent is rarely a span of its own: a tab's padding and the text after it carry the
/// same styles and the same font, so `coalesce` has already merged them into one run by the
/// time layout sees it. Peeling it off here is what lets the indent be measured in the
/// document's own print columns while the text keeps the font's advance (see `lineOpsPrinted`
/// for why those are different measures).
///
/// A span with NO font block is never flagged: the run's own pitch already IS the document's
/// there, so the flag would change nothing — and not raising it keeps every fontless line's
/// arithmetic, and therefore its bytes, untouched.
private func splitIndent(_ segs: [LineSegment]) -> [LineSegment] {
    var out: [LineSegment] = []
    var leading = true
    for seg in segs {
        if !leading {
            out.append(seg)
            continue
        }
        let pad = seg.text.count - seg.text.drop(while: { $0 == " " }).count
        if seg.entry != nil, pad > 0 {
            if pad < seg.text.count {
                out.append(LineSegment(text: String(seg.text.prefix(pad)), styles: seg.styles,
                                       family: seg.family, size: seg.size, entry: seg.entry,
                                       indent: true))
                out.append(LineSegment(text: String(seg.text.dropFirst(pad)),
                                       styles: seg.styles, family: seg.family, size: seg.size,
                                       entry: seg.entry, indent: false))
                leading = false
            } else {
                out.append(LineSegment(text: seg.text, styles: seg.styles, family: seg.family,
                                       size: seg.size, entry: seg.entry, indent: true))
            }
            continue
        }
        out.append(seg)
        if seg.text.contains(where: { !$0.isWhitespace }) {
            leading = false
        }
    }
    return out
}

/// One laid-out line, on the document's own horizontal grid. Port of `pdf._line_ops_printed`.
///
/// Every span gets its own text object at an ABSOLUTE x, and that x is WordStar's: the
/// characters before it, each at its own run's HMI advance (`spanPitch`). This replaced two
/// paths — a Courier one that did exactly this arithmetic with a hardcoded 0.6, and a
/// proportional one that put the whole line in a single text object and let PDF's natural
/// advance carry the pen. The second was the right call while this emitter had no font
/// metrics: with no way to know how wide Times actually set a word, a computed x was a guess
/// and natural advance at least never overlapped. `AFM.swift` removes that limitation, and
/// Jon's ruling followed it: "Printed that ignores fonts can't call itself Printed" — the
/// document's own layout math governs, so the grid is computed and each span is width-matched
/// onto it with `Tz`.
///
/// `tzState` carries the CURRENT horizontal scaling ACROSS calls, in exact hundredths. `Tz` is
/// text state, and text state survives `ET` — an 85 `Tz` set on one span would silently scale
/// every span after it, on every following line of the same content stream. So the operator is
/// written only when the value CHANGES, which also means a document that never needs scaling
/// (every fontless file, and Modern mode entirely) never emits one and its bytes are exactly
/// what they were before any of this existed.
///
/// THE ONE EXCEPTION to the HMI grid, and it is the document's own math too: a line's LEADING
/// WHITESPACE is positioning, measured in the document's print columns rather than in the
/// font. WordStar re-stamps a left indent from `.tb`/`.lm`/`.po` as machine spaces, and every
/// one of those commands is specified in 10-CPI print columns — the tab expander literally
/// converts the tab's HMI size to columns before emitting the padding. Run that padding at a
/// 72pt display font's own advance and a one-column shadow offset becomes a six-inch one: the
/// reference archive's own banner document tabs to 1.39in on one line and 1.4in on the next,
/// an offset of exactly one print column (7.2pt at 10 CPI), to print a display face twice with
/// a shadow. On the font's advance the second copy landed off the right edge of the paper.
/// Interior spaces — inside a run, after real text — are the author's own characters and stay
/// on the font's advance.
///
/// (The exception only fires for a span that HAS a font block: without one the run's pitch
/// already IS the document's, so it cannot change a fontless byte.)
private func lineOpsPrinted(
    _ segs: [LineSegment], left: Double, y: Double, size: Int, res: FontResources,
    tzState: inout Int
) -> [[UInt8]] {
    var ops: [[UInt8]] = []
    var x = left
    for seg in splitIndent(segs) {
        let (pt, rise) = sized(seg.styles, seg.size)
        let baseFont = base14(seg.family, bold: seg.styles.contains(.bold),
                              italic: seg.styles.contains(.italic))
        let font = res.ref(baseFont)
        let scale: Double?
        let w: Double
        if seg.indent {
            scale = nil
            w = Double(seg.text.width) * Double(size) * 0.6      // document print columns
        } else {
            let target = spanTarget(seg.entry, pt, count: seg.text.width)
            (scale, w) = tzScale(seg.text, baseFont, pt, target)
        }
        let want = hundredths(scale ?? tzDefault)
        var op = Array("BT /\(font) \(pt) Tf \(rise) Ts ".utf8)
        if want != tzState {
            op += Array("\(fixedTwoDecimal(hundredths: want)) Tz ".utf8)
            tzState = want
        }
        op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
        op += esc(seg.text)
        op += Array(") Tj ET".utf8)
        ops.append(op)
        ops += rules(seg.styles, seg.text, x: x, y: y, w: w)
        x += w
    }
    return ops
}

/// - Parameter lead: the DOCUMENT DEFAULT baseline advance. A line that carries its own
///   (`PageLine.lead`, from the `.lh` in force where it sat) advances by that instead — the
///   stateful-`.lh` half of the same ruling.
/// - Parameter fonts: `doc.fonts` in PRINTED mode and empty everywhere else (Modern is
///   Courier by design), so a span only leaves the document's own fixed pitch when the file
///   itself asked for another face, another size or another advance.
/// - Parameter res: the document-wide font table. One instance is shared by every page, so
///   the `/Fn` numbering is stable across the whole file; a fresh one is made when a caller
///   (every test in `PDFWriterTests.swift`) renders a page in isolation.
///
/// A LINE'S LEAD IS THE SPACE ABOVE IT, not below it, and that is measured rather than
/// assumed. `.lh` is a printer VMI: WordStar sets the vertical motion index and the line
/// feeds that follow use it, so the command — which sits in the file before the line it was
/// typed for — governs the feed that arrives ON that line. The reference archive's banner
/// document proves it: it prints one 72pt word, sets `.lh.05"`, and prints the same word
/// again, to overprint a shadow 0.05in (3.6pt) below the first. Read the other way round —
/// each lead spending itself below its own line — the two copies land 14pt apart and the
/// shadow is just a second, blurry banner. The first line of a page takes its position from
/// `top` and no lead at all.
func pageStream(
    _ pagelines: Page, top: Int, pageHeight: Int = PDFMetrics.pageHeight,
    lead: Double = Double(PDFMetrics.lead), size: Int = PDFMetrics.size,
    left: Double = Double(PDFMetrics.margin),
    running: [[UInt8]] = [], fonts: [FontChange] = [], res: FontResources? = nil
) -> [UInt8] {
    let res = res ?? FontResources()
    var ops: [[UInt8]] = running
    // The baseline of the first line: down from the top of the paper by the margin, then by
    // one line's height, because `Td` positions a baseline and not a line's top edge.
    var y = Double(pageHeight - top - size)
    // Horizontal scaling persists across text objects within a content stream; it starts at
    // PDF's own default on every page. See `lineOpsPrinted`.
    var tzState = hundredths(tzDefault)
    for (n, line) in pagelines.enumerated() {
        if n > 0 {
            y -= line.lead ?? lead
        }
        var segs: [LineSegment] = []
        // Coalesced FIRST (pdf.py:136): the wrapper leaves one segment per word and per
        // space-run, and each segment costs a text-showing operator. Merging runs that share
        // styles changes nothing on paper and divides the stream size by roughly ten.
        for span in coalesce(line) {
            if span.text.isEmpty {
                continue                       // no operator, and no advance either
            }
            let rendered = spanRender(span.text, font: span.font, fonts: fonts, size: size)
            segs.append(LineSegment(text: rendered.text, styles: span.styles,
                                    family: rendered.family, size: rendered.size,
                                    entry: rendered.entry, indent: false))
        }
        ops += lineOpsPrinted(segs, left: left, y: y, size: size, res: res, tzState: &tzState)
    }
    return joined(ops, separator: 0x0A)                                 // Python's b'\n'.join
}

/// `[UInt8].joined(separator:)` for a single byte — the stdlib's version wants a sequence and
/// returns a lazy flattened view, which is more machinery than one newline needs.
private func joined(_ chunks: [[UInt8]], separator: UInt8) -> [UInt8] {
    var out: [UInt8] = []
    for (i, chunk) in chunks.enumerated() {
        if i > 0 { out.append(separator) }
        out += chunk
    }
    return out
}

/// Render the document as a PDF. Port of `emit_pdf` (pdf.py:154-205).
///
/// Returns bytes, not a `String` — PDF is a binary format, and the xref table's byte offsets
/// mean it cannot survive any re-encoding. This is the one built-in emitter that returns
/// `EmitOutput.data`, and the reason that type exists.
///
/// Object layout, which the xref table pins by absolute file offset: catalog 1, page tree 2,
/// the fonts from 3 up — the Courier four ALWAYS, plus whatever base-14 faces a WS5+
/// document's own font runs reached for in printed mode — then a page/contents pair per page.
/// The Courier four are unconditional precisely so that numbering never moves for a document
/// without font runs; see `FontResources`.
@Sendable
public func emitPDF(_ doc: Document, mode: EmitMode = .modern,
                    options: EmitOptions = EmitOptions()) -> [UInt8] {
    let printed = mode == .printed || isPrinted(doc)
    let pages = docToPagelines(doc, printed: printed)
    // ctrl-kd 1.3.0: both figures are per-document in Printed mode now — `printedTop`/
    // `printedLead` (PDFLayout.swift) read the file's own `.mt`/`.lh`, falling back to the
    // same fixed `topPrinted`/`lead` a print stream (no page geometry) always used. Modern
    // mode is untouched: it never faithfulness-matches the original page, so it keeps the
    // fixed margin and lead regardless of what the document's geometry says.
    let top = printed ? printedTop(doc) : PDFMetrics.topModern
    let lead = printed ? printedLead(doc) : Double(PDFMetrics.lead)
    // ctrl-kd 2.0.0: `.cw`/`.po`-derived for a Printed-mode WS document (PDFLayout.swift's
    // `printedSize`/`printedLeft`), falling back to the same fixed size/margin a print
    // stream (no page geometry) always used. Modern mode is untouched: it never
    // faithfulness-matches the original page, so it keeps the fixed size and margin
    // regardless of what the document's geometry says.
    let size = printed ? printedSize(doc) : PDFMetrics.size
    let left = printed ? printedLeft(doc, size: size) : Double(PDFMetrics.margin)
    // The SAME figure `printedCap` derives the line count from (PDFLayout.swift) — Python
    // computes it once in `emit_pdf` and uses it for both the MediaBox and the content
    // stream's Y-origin (pdf.py:449,476-479). A page that paginates at a custom `.pl`'s
    // resolved capacity but still declares a Letter-size MediaBox would be internally
    // inconsistent: the right number of lines, drawn on the wrong-size sheet of paper.
    let pageHeight = resolvedPageHeight(doc, printed: printed)
    // Font runs are a PRINTED-mode facsimile feature: Modern mode is Courier by ruling, so
    // it is handed no fonts at all and every span stays on the fixed-pitch path. WS4
    // documents and print streams have no font blocks, so `doc.fonts` is empty for them and
    // this is a no-op.
    let fonts = printed ? doc.fonts : []

    // (number, body) — the body WITHOUT the `N 0 obj` wrapper, which the writer adds while
    // recording offsets.
    var objs: [(number: Int, body: [UInt8])] = []
    var nextNum = 3                                   // 1 and 2 are reserved, inserted below

    // `.pn n` sets the number of the page it appears on, so a chapter file in a larger
    // manuscript numbers from where the previous one stopped.
    let startNo = doc.page?.pnStart ?? 1

    // THE STREAMS ARE WRITTEN FIRST: which base-14 fonts the document actually uses is only
    // known once every span has been laid out, and the resource table has to name them all.
    let res = FontResources()
    var streams: [[UInt8]] = []
    for (i, page) in pages.enumerated() {
        let running = runningOps(doc, pageNo: startNo + i, pageHeight: pageHeight,
                                 lead: lead, size: size, left: left, printed: printed)
        streams.append(pageStream(page, top: top, pageHeight: pageHeight, lead: lead,
                                  size: size, left: left, running: running,
                                  fonts: fonts, res: res))
    }

    var fontNums: [(name: String, number: Int)] = []
    for font in res.fonts {
        fontNums.append((font.name, nextNum))
        objs.append((nextNum, Array(
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(font.baseFont) >>".utf8)))
        nextNum += 1
    }
    // Every page's /Resources names every font the DOCUMENT reached for, whether this page
    // used it or not — a handful of indirect references cost less than tracking which faces
    // a page turned out to contain, and a per-page table would renumber nothing but would
    // still have to be built twice.
    let fontDict = fontNums.map { "/\($0.name) \($0.number) 0 R" }.joined(separator: " ")

    var pageNums: [Int] = []
    var contentNums: [Int] = []
    for _ in pages {
        pageNums.append(nextNum); nextNum += 1
        contentNums.append(nextNum); nextNum += 1
    }

    let kids = pageNums.map { "\($0) 0 R" }.joined(separator: " ")
    objs.insert((1, Array("<< /Type /Catalog /Pages 2 0 R >>".utf8)), at: 0)
    objs.insert((2, Array(
        "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>".utf8)), at: 1)

    for (i, stream) in streams.enumerated() {
        objs.append((pageNums[i], Array("""
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(PDFMetrics.pageWidth) \
        \(pageHeight)] /Resources << /Font << \(fontDict) >> >> \
        /Contents \(contentNums[i]) 0 R >>
        """.utf8)))
        var body = Array("<< /Length \(stream.count) >>\nstream\n".utf8)
        body += stream
        body += Array("\nendstream".utf8)
        objs.append((contentNums[i], body))
    }

    // Python sorts `(num, bytes)` tuples; the numbers are unique, so this is by number.
    //
    // It is a no-op as the list is actually built, and provably so: the fonts go on in
    // ascending order, the two `insert`s put 1 and 2 at the front in that order, and the
    // page/contents pairs are appended in ascending order after them. Mutation testing found
    // this — deleting the sort changes no byte of any output, which is the honest reason it
    // has no test of its own. Kept because Python keeps it, and because the xref table's
    // entries are positional: if a later emitter ever appends an object out of order, this is
    // what stops entry n from pointing at some other object.
    objs.sort { $0.number < $1.number }

    var out = Array("%PDF-1.4\n".utf8)
    var offsets: [Int: Int] = [:]
    for obj in objs {
        offsets[obj.number] = out.count
        out += Array("\(obj.number) 0 obj\n".utf8)
        out += obj.body
        out += Array("\nendobj\n".utf8)
    }

    let xrefAt = out.count
    let count = (offsets.keys.max() ?? 0) + 1         // one past the highest object number
    // Object 0 is always the free-list head. The trailing space before each newline is
    // required: PDF fixes the xref entry at twenty bytes, `nnnnnnnnnn ggggg n\r\n` or the
    // space-newline spelling used here.
    out += Array("xref\n0 \(count)\n0000000000 65535 f \n".utf8)
    for n in 1..<count {
        // Numbering is contiguous from 1, so every entry has an offset; Python would raise
        // KeyError here rather than emit a wrong one, and a `!` says the same thing.
        out += Array("\(zeroPadded(offsets[n]!, width: 10)) 00000 n \n".utf8)
    }
    out += Array("""
    trailer
    << /Size \(count) /Root 1 0 R >>
    startxref
    \(xrefAt)
    %%EOF

    """.utf8)
    return out
}
