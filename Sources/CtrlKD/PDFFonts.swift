/// The PDF base-14 fonts, and the mapping from a WordStar typestyle onto them. Port of the
/// font machinery `pdf.py` grew in ctrl-kd 9846771.
///
/// Jon's ruling, 2026-08-04: a PRINTED-mode PDF of a WS5+ document renders WordStar's exact
/// line breaks (it always has) PLUS the fonts the document chose -- through the PDF base-14
/// built-ins, so still zero dependencies and still nothing embedded. MODERN mode is
/// unchanged: Courier-only typewriter setting, deliberately. WS4 files and print streams
/// carry no font blocks at all, so they stay Courier automatically -- there is nothing to
/// look up.
///
/// The base-14 set is what every PDF viewer must provide: Times x4, Helvetica x4, Courier
/// x4, Symbol, ZapfDingbats. A WordStar typestyle is mapped to one of those five families by
/// a strict three-way split -- serif, sans, mono -- plus the two symbol faces (Jon's
/// amendment: "every face we can't truly represent resolves by serif/sans/mono, no special
/// flavoring"). Univers becomes Helvetica, Garamond becomes Times, Pica becomes Courier. The
/// era name itself is never lost: it stays verbatim in `Document.fonts` and rides into the
/// RTF/HTML exports, which CAN name a real face.

/// One of the five base-14 families this emitter can select.
enum PDFFamily: Hashable, Sendable {
    case courier
    case times
    case helvetica
    case symbol
    case zapfDingbats
}

/// The four style variants of each family, in `(bold) + 2 * (italic)` order — the same
/// index arithmetic `pdfFont(bold:italic:)` uses for the Courier four.
///
/// Neither symbol face has variants in the base-14 set: bold/italic on a Symbol run has no
/// face to go to, so the roman stands in for all four.
private let base14Variants: [(family: PDFFamily, variants: [String])] = [
    (.courier, ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"]),
    (.times, ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"]),
    (.helvetica, ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"]),
    (.symbol, ["Symbol", "Symbol", "Symbol", "Symbol"]),
    (.zapfDingbats, ["ZapfDingbats", "ZapfDingbats", "ZapfDingbats", "ZapfDingbats"]),
]

/// The PDF `/BaseFont` name for one family at one style combination.
///
/// Bold and italic come ONLY from the span's own `b`/`i` styles — never from the typestyle,
/// which names a face and not a weight.
func base14(_ family: PDFFamily, bold: Bool, italic: Bool) -> String {
    let variants = base14Variants.first { $0.family == family }!.variants
    return variants[(bold ? 1 : 0) + (italic ? 2 : 0)]
}

/// Fixed-pitch era faces, matched on the typestyle NAME.
///
/// THIS TEST MUST RUN BEFORE THE GENERIC-STYLE BITS, and the archive says why: the spec's own
/// font block for `Courier` declares generic style `serif` (a slab serif, which is honest
/// typography), and 48 of the 121 font blocks in the reference corpus are exactly that.
/// Reading the bits first would have set every Courier run in Times -- the one substitution a
/// typescript facsimile must never make. Pica/Elite/LinePrinter go the same way.
let monoFamilies = ["courier", "pica", "elite", "lineprinter"]

/// WordStar measures horizontal advance in HMIs — 1/1800 inch — and every font block in a
/// WS5+ file carries the per-character width it laid the document out on. A PDF point is
/// 1/72 inch, so 1800 HMI = 72pt and the conversion is a division by 25.
///
/// (The per-family average-advance guesses this replaced — Times 0.5, Helvetica 0.55 — are
/// gone: `AFM.swift` carries the real per-glyph tables now, so nothing here has to
/// approximate a width.)
let hmiPerPoint = 1800.0 / 72.0                 // = 25

/// `Tz` (horizontal scaling, percent) clamp. A span is scaled to land exactly on WordStar's
/// grid; a ratio outside this range does not mean the author wanted glyphs at a quarter
/// width, it means the file's HMI and the substituted face's metrics disagree — a typestyle
/// we can only approximate, a font block from a printer whose pitch had nothing to do with
/// the base-14. Stretching to obey it would produce unreadable text in the name of fidelity,
/// so outside the clamp the span keeps its natural advance and the grid loses that one
/// argument. 40/250 is wide enough to cover every real substitution in the reference corpus
/// (the worst honest case there is ~0.85) and narrow enough that a genuinely absurd ratio is
/// caught.
let tzMin = 40.0
let tzMax = 250.0
/// PDF's own initial text state.
let tzDefault = 100.0

/// The base-14 family for one `Document.fonts` entry. Port of `pdf._pdf_family`.
///
/// Order is deliberate:
///   1. the font's own symbol-map/name verdict (`fontTranslitKind`) — `math` IS Symbol,
///      `symbols` IS ZapfDingbats, and those two we can reproduce exactly rather than
///      approximate;
///   2. fixed-pitch names -> Courier (see `monoFamilies` for why this beats the bits);
///   3. the font block's own generic-style bits: serif -> Times, sans -> Helvetica.
///      `script` also lands on Times and `display` on Helvetica (Jon: "I don't think we have
///      any option for script... maybe just Times"); the base-14 set has no chancery and no
///      poster face, and the era's display typestyles are overwhelmingly sans-shaped, so
///      those are the honest neighbours rather than an italic/bold pretence;
///   4. no font at all -> Courier, the emitter's own default.
///
/// Python has a fifth case — an entry whose `generic_style` key is missing — which cannot
/// arise here: `FontChange.genericStyle` decodes two bits of the typestyle word and is
/// therefore always one of the four. Python's parser always sets the key too, so that branch
/// only ever caught a hand-built dict.
func pdfFamily(_ entry: FontChange?) -> PDFFamily {
    guard let entry else { return .courier }
    switch fontTranslitKind(entry) {
    case .math: return .symbol
    case .symbols: return .zapfDingbats
    case nil: break
    }
    let family = asciiLowercased(entry.family)
    if monoFamilies.contains(where: { family.hasPrefix($0) }) { return .courier }
    switch entry.genericStyle {
    case .serif, .script: return .times
    case .sans, .display: return .helvetica
    }
}

/// The page-resource font table, built as the content streams are written.
///
/// The Courier four are ALWAYS /F1../F4 and always emitted, used or not. That is not
/// laziness: it is what keeps a document with no font runs -- every WS4 file, every print
/// stream, and most WS5+ documents -- byte-for-byte identical to what this emitter produced
/// before fonts existed here. Emitting only the fonts a page really touches would renumber
/// the object table for those files and change every PDF the project has ever made. Fonts
/// BEYOND the Courier four are added on demand, in first-use order, so a Courier document
/// still ships exactly four font objects.
///
/// A CLASS, not a struct: one table is shared by every page of a document, and a value type
/// would give each page its own numbering.
final class FontResources {
    /// `/Fn` -> `/BaseFont`, in object-numbering order.
    private(set) var fonts: [(name: String, baseFont: String)] = pdfFonts
    private var byBase: [String: String]

    init() {
        var map: [String: String] = [:]
        for font in pdfFonts { map[font.baseFont] = font.name }
        byBase = map
    }

    /// The `/Fn` name for a base-14 font, registering it if new.
    func ref(_ baseFont: String) -> String {
        if let existing = byBase[baseFont] { return existing }
        let name = "F\(fonts.count + 1)"
        fonts.append((name, baseFont))
        byBase[baseFont] = name
        return name
    }
}

/// The `Document.fonts` entry a span's active font run points at, or `nil`.
///
/// Python reads the lowest `fontN` tag out of the span's style set; a Swift span carries the
/// index in its own field (`Span.font`), so this is the bounds check and nothing else. The
/// `.altFont` style — WS4's ^PA printer-alternate flag — is deliberately not consulted: it
/// names no font, it only says "the other wheel".
func spanFontEntry(_ index: Int?, _ fonts: [FontChange]) -> FontChange? {
    guard !fonts.isEmpty, let index, index >= 0, index < fonts.count else { return nil }
    return fonts[index]
}

/// `(text-as-written, family, size, font-entry)` for one span. Port of `pdf._span_render`.
///
/// Symbol/ZapfDingbats runs were transliterated to real Unicode at parse time
/// (`SymbolTranslit.swift`) so that every text format renders without a font. Here we HAVE
/// the font, so the transliteration is undone: the original byte codes go back on the page
/// with the real face selected, and a viewer draws the actual glyph -- alpha, not the letter
/// 'a', with nothing embedded.
func spanRender(_ text: String, font: Int?, fonts: [FontChange], size: Int)
    -> (text: String, family: PDFFamily, size: Int, entry: FontChange?)
{
    let entry = spanFontEntry(font, fonts)
    let family = pdfFamily(entry)
    var written = text
    if family == .symbol || family == .zapfDingbats, let entry {
        written = untransliterate(text, fontTranslitKind(entry))
    }
    // `Tf` has always been written as an integer here; the span's own size comes from the
    // font block's height word, falling back to the document's size. Python's `if pts` is
    // false for a zero height word, which is not a printable size.
    //
    // The entry itself rides along because the LAYOUT needs its width word — `width1800`,
    // the per-character advance WordStar used (`spanPitch`).
    let points = entry?.points ?? 0
    return (written, family, points > 0 ? max(1, roundHalfToEven(points)) : size, entry)
}
