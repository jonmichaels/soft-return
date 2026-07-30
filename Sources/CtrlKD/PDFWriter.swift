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
/// `m`/`l`/`S` move, line, and stroke.
private func rule(xFrom: Int, xTo: Int, y: Int) -> [UInt8] {
    let x1 = fixedOneDecimal(tenths: xFrom)
    let x2 = fixedOneDecimal(tenths: xTo)
    let yy = fixedOneDecimal(tenths: y)
    return Array("0.6 w \(x1) \(yy) m \(x2) \(yy) l S".utf8)
}

/// One page's content stream. Port of `_page_stream` (pdf.py:131-152).
///
/// - Parameter top: the top margin in points — `topModern` or `topPrinted`. A print stream
///   carries its own top-margin blank lines, so it gets the smaller paper margin.
///
/// Text is placed absolutely, one `BT`/`ET` block per styled run: PDF's own text-positioning
/// operators track a line matrix that would have to be reset anyway, and Courier's fixed
/// advance means the x for every run is known here without asking a font for metrics.
func pageStream(_ pagelines: Page, top: Int) -> [UInt8] {
    var ops: [[UInt8]] = []
    // The baseline of the first line: down from the top of the paper by the margin, then by
    // one line's height, because `Td` positions a baseline and not a line's top edge.
    var y = (PDFMetrics.pageHeight - top - PDFMetrics.size) * 10
    for line in pagelines {
        var x = PDFMetrics.margin * 10
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
            let size = reduced ? 8 : PDFMetrics.size
            let rise = styles.contains(.sup) ? 3 : (styles.contains(.sub) ? -2 : 0)
            let font = pdfFont(bold: styles.contains(.bold), italic: styles.contains(.italic))

            var op = Array("BT /\(font) \(size) Tf \(rise) Ts ".utf8)
            op += Array("\(fixedOneDecimal(tenths: x)) \(fixedOneDecimal(tenths: y)) Td (".utf8)
            op += esc(span.text)
            op += Array(") Tj ET".utf8)
            ops.append(op)

            // `len(text) * size * 0.6` in tenths: Courier advances 0.6 em, so 6 tenths per
            // point of type size per character. Exact in integers; the float version isn't.
            let w = span.text.width * size * 6
            // A rule under a run of pure whitespace would be a stray dash, so Python guards
            // both with `text.strip()` — non-empty after stripping, i.e. the run has ink.
            let hasInk = span.text.contains { !$0.isWhitespace }
            if styles.contains(.underline), hasInk {
                ops.append(rule(xFrom: x, xTo: x + w, y: y - 15))       // 1.5pt below
            }
            if styles.contains(.strike), hasInk {
                ops.append(rule(xFrom: x, xTo: x + w, y: y + 30))       // 3pt above
            }
            x += w
        }
        y -= PDFMetrics.lead * 10
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
    let top = printed ? PDFMetrics.topPrinted : PDFMetrics.topModern

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
        \(PDFMetrics.pageHeight)] /Resources << /Font << \(fontDict) >> >> \
        /Contents \(contentNums[i]) 0 R >>
        """.utf8)))
        let stream = pageStream(page, top: top)
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
