/// The PDF emitter's writer half: laid-out pages -> PDF bytes. Port of `pdf.py`'s `_esc`
/// (pdf.py:32-34), `_page_stream` (pdf.py:131-152) and `emit_pdf` (pdf.py:154-207).
///
/// Hand-written PDF 1.4 with no dependencies, which is what the base-14 Courier family buys:
/// four fonts that every reader already has, with fixed metrics, so nothing is embedded and
/// the layout is exact. `PDFLayout` decided what goes where in characters and line counts;
/// this file is the only part that knows what a PDF looks like.
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
    let omit = doc.dotCommands.contains { cmd in
        let head = cmd.drop(while: { $0 == "." }).prefix(while: { !$0.isWhitespace })
        return head.lowercased() == "op"
    }
    let pl = Int(doc.page?.plLines ?? defaultPlLines)
    let mb = Int(doc.page?.mbLines ?? defaultMbLines)
    let fm = Int(doc.page?.fmLines ?? 2)

    // `#` -> the page number. Written by hand because this module imports nothing —
    // `replacingOccurrences` is Foundation, which CtrlKD deliberately does without.
    func render(_ txt: String) -> String {
        let replacement = omit ? "" : String(pageNo)
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

func pageStream(
    _ pagelines: Page, top: Int, pageHeight: Int = PDFMetrics.pageHeight,
    lead: Double = Double(PDFMetrics.lead), size: Int = PDFMetrics.size,
    left: Double = Double(PDFMetrics.margin),
    running: [[UInt8]] = []
) -> [UInt8] {
    var ops: [[UInt8]] = running
    // sup/sub size, derived once — Python: `max(1, round(size * 2 / 3))`. 8 at the
    // default size 12, same figure the writer hardcoded before ctrl-kd 2.0.0.
    let supSize = max(1, roundHalfToEven(Double(size * 2) / 3.0))
    // The baseline of the first line: down from the top of the paper by the margin, then by
    // one line's height, because `Td` positions a baseline and not a line's top edge.
    var y = Double(pageHeight - top - size)
    for line in pagelines {
        var x = left
        // Coalesced FIRST (pdf.py:136): the wrapper leaves one segment per word and per
        // space-run, and each segment costs a text-showing operator. Merging runs that share
        // styles changes nothing on paper and divides the stream size by roughly ten.
        for span in coalesce(line) {
            if span.text.isEmpty {
                continue                       // no operator, and no advance either
            }
            let styles = span.styles
            // Superscript and subscript are both SET SMALLER, not just moved: one size test
            // covering either, then the rise chooses the direction. `sup` wins if a span
            // somehow carries both, matching Python's nested conditional.
            let reduced = styles.contains(.sup) || styles.contains(.sub)
            let sizeHere = reduced ? supSize : size
            let rise = styles.contains(.sup) ? 3 : (styles.contains(.sub) ? -2 : 0)
            let font = pdfFont(bold: styles.contains(.bold), italic: styles.contains(.italic))

            var op = Array("BT /\(font) \(sizeHere) Tf \(rise) Ts ".utf8)
            op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            op += esc(span.text)
            op += Array(") Tj ET".utf8)
            ops.append(op)

            // `len(text) * sizeHere * 0.6`, mirroring Python's float arithmetic exactly (see
            // the CRITICAL FLOAT DETAIL above) rather than the pre-2.0.0 integer-tenths trick.
            let w = Double(span.text.width) * Double(sizeHere) * 0.6
            // A rule under a run of pure whitespace would be a stray dash, so Python guards
            // both with `text.strip()` — non-empty after stripping, i.e. the run has ink.
            let hasInk = span.text.contains { !$0.isWhitespace }
            if styles.contains(.underline), hasInk {
                ops.append(rule(xFrom: x, xTo: x + w, y: y - 1.5))      // 1.5pt below
            }
            if styles.contains(.strike), hasInk {
                ops.append(rule(xFrom: x, xTo: x + w, y: y + 3))        // 3pt above
            }
            x += w
        }
        y -= lead
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
/// the four fonts 3-6, then a page/contents pair per page from 7 up.
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

    // (number, body) — the body WITHOUT the `N 0 obj` wrapper, which the writer adds while
    // recording offsets.
    var objs: [(number: Int, body: [UInt8])] = []
    var nextNum = 3                                   // 1 and 2 are reserved, inserted below

    var fontNums: [(name: String, number: Int)] = []
    for font in pdfFonts {
        fontNums.append((font.name, nextNum))
        objs.append((nextNum, Array(
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(font.baseFont) >>".utf8)))
        nextNum += 1
    }
    // Every page's /Resources names all four fonts whether it uses them or not — four
    // indirect references cost less than tracking which styles a page turned out to contain.
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

    for (i, page) in pages.enumerated() {
        objs.append((pageNums[i], Array("""
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(PDFMetrics.pageWidth) \
        \(pageHeight)] /Resources << /Font << \(fontDict) >> >> \
        /Contents \(contentNums[i]) 0 R >>
        """.utf8)))
        // `.pn n` sets the number of the page it appears on, so a chapter file in a
        // larger manuscript numbers from where the previous one stopped.
        let startNo = doc.page?.pnStart ?? 1
        let running = runningOps(doc, pageNo: startNo + i, pageHeight: pageHeight,
                                 lead: lead, size: size, left: left, printed: printed)
        let stream = pageStream(page, top: top, pageHeight: pageHeight, lead: lead,
                                size: size, left: left, running: running)
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
