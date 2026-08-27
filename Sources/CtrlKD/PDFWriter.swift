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

/// Lookalike degradations for glyphs cp1252 cannot carry — applied BEFORE encoding so a
/// middle dot from a header triple or a box glyph in a fontless span degrades to its
/// nearest visible relative, not to `?`. Port of Python's `_ESC_FALLBACK`.
///
/// Finding 2 (b26 visual pass, a real WS7 paper capture): cp437 code 158 decodes to
/// PESETA SIGN (U+20A7) — cp1252/WinAnsi has no glyph for it either (base-14 has no
/// euro glyph and no peseta glyph — Symbol has neither), so it fell to `?` here same
/// as any other unrepresentable character. The reference document's OWN text explains
/// the honest reading for a post-1999 WordStar install: WordStar was last updated in
/// 1992, seven years before the euro currency symbol was adopted in 1999 — the
/// capture's own dosbox-x setup patches its printer driver files to show the euro at
/// this exact code instead of the standard peseta (`euro=158` in the `[render]`
/// section), and its own worked example inserts code 158 to PROVE the euro renders.
/// Substituting the one glyph cp1252 actually has at this position (EURO SIGN,
/// U+20AC, cp1252 0x80) turns a guaranteed `?` into what a real modern WS7 install of
/// this exact document shows.
///
/// KNOWN LIMIT, recorded rather than hidden: a private-corpus WordStar document (a
/// bare cp437 code-to-glyph reference chart, no euro context at all) also carries one
/// code-158 triple — real cp437 code 158 IS the peseta sign, not the euro, so this
/// substitution is specifically right for the -README document's own documented
/// intent and arguably wrong for that chart's literal entry. Both currently show `?`
/// at that position either way (no font in this pipeline can draw a real peseta
/// glyph), so this is not a working document regressing — it is one broken cell
/// resolved the same way in both, and that private document is outside the
/// checked-in/gated corpus, so nothing here is verified against its own WS7 capture.
// Register C9: '•' (U+2022 BULLET -- WordStar's own cp437 0x07 list marker,
// `cp437Graphics`'s own mapping) is NOT a fallback case at all: cp1252 has a real bullet
// glyph for it (0x95), same as every base-14 face's own /WinAnsiEncoding. It used to
// collapse to the SAME target as its lookalike '∙' (U+2219 BULLET OPERATOR, a math symbol
// genuinely absent from cp1252), downgrading every WordStar bulleted list (LJ6DTP's own
// Features list, page 1) from a round bullet to a middle dot for no encoding reason at all
// -- measured against LJ6DTP-p1.png. '∙' keeps its fallback; '•' needs none.
private let escFallback: [Unicode.Scalar: Unicode.Scalar] = [
    "\u{2219}": "\u{00B7}",   // ∙ -> ·
    "\u{203C}": "!",          // ‼ -> !
    "\u{2502}": "|",          // │ -> |
    "\u{2500}": "-",          // ─ -> -
    "\u{2550}": "=",          // ═ -> =
    "\u{20A7}": "\u{20AC}",   // ₧ -> €
]

/// Encode text for a PDF string literal: cp1252 (the declared `/WinAnsiEncoding`) with `?`
/// for anything that doesn't fit, then backslash and parentheses escaped. Port of `_esc`
/// (pdf.py).
///
/// THE TWO ORDERINGS HERE ARE NOT EQUALLY LOAD-BEARING, and the difference is worth writing
/// down because both look like "order matters":
///
/// - Backslash BEFORE parens is essential. Escaping parens first would leave their new
///   backslashes for the backslash pass to double, turning `(` into `\\(` — a literal
///   backslash followed by an unescaped paren, which unbalances the string and corrupts the
///   rest of the content stream. Checked against the reference: of 584 strings drawn from
///   `a \ ( ) é — Ł ?`, 326 come out differently if the passes are swapped.
/// - cp1252 BEFORE escaping is not observable at all. The two orders agree on every one of
///   those 584 strings, and must: the encoder's replacement character is `?`, which is
///   neither a backslash nor a parenthesis, so it can never create or consume an escape.
///
/// So the passes below are three separate replacements rather than one combined loop —
/// mutating any one of them, or their order, changes the output and the vectors say so.
///
/// cp1252, not Latin-1 (since 2026-08-05): the declared `/WinAnsiEncoding` IS cp1252, and
/// it is what gives the base-14 faces curly quotes, en/em dashes, ellipsis and the rest of
/// the typographic range the LJ6DTP substitutions produce (`ljSubstitute`).
func esc(_ text: String) -> [UInt8] {
    var degraded = String.UnicodeScalarView()
    degraded.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        degraded.append(escFallback[scalar] ?? scalar)
    }
    let raw = cp1252Encode(String(degraded))
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
///
/// - Parameters:
///   - headers: the running head text IN FORCE on this page — `nil` (the default)
///     falls back to `doc.headers`, the document's final state. A per-page dict comes
///     from replaying `doc.hfEvents` through pagination (`Page.headers`); the
///     notes-aware paginator never replays them and so always passes `nil`.
///   - footers: same, for `doc.footers`/`Page.footers`.
///   - autoPageNumber: register b31, E3 item 2 (ruled 2026-08-25, ctrl-kd 6f30157) — the
///     caller's ALREADY-RESOLVED answer to "does WordStar's own AUTOMATIC page number
///     (the one `.pc` positions — a completely separate mechanism from a `#` the author
///     placed inside a real `.he`/`.fo`) show on THIS page", combining
///     `EmitOptions.PageNumberMode` and, for `.auto`, the per-page `pgnumCheckpoints`
///     state (PDFLayout.swift). `runningOps` itself only resolves WHERE (from `.po`/
///     `.pc` via `autoPageNumberXPt`) and WHETHER a real footer pre-empts it
///     (WSFORMAT.WS: "active only when the footers are not in use") — never the on/off
///     DECISION itself, which needs page-level context this function does not have. A
///     caller that never passes it (every existing call site but the one main per-page
///     loop wires it into) gets `false`, byte-identical to before this parameter
///     existed — the TOC/Index call site included, which passes `headers: [:]`/
///     `footers: [:]` explicitly and must not suddenly grow a number it never had.
func runningOps(
    _ doc: Document, pageNo: Int, pageHeight: Int, lead: Double, size: Int,
    left: Double, printed: Bool, headers: [Int: String]? = nil, footers: [Int: String]? = nil,
    res: FontResources? = nil, autoPageNumber: Bool = false
) -> [[UInt8]] {
    let headers = headers ?? doc.headers
    let footers = footers ?? doc.footers
    let footerInUse = !footers.isEmpty && footers.values.contains { !$0.isEmpty }
    let showAutoNum = printed && autoPageNumber && !footerInUse
    guard printed, !headers.isEmpty || !footers.isEmpty || showAutoNum else { return [] }
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
    /// One header/footer LINE's ops (register C6). `fontIdx` is the `Document.fonts`
    /// index found on this line's own `.h#`/`.f#` (`Document.headerFonts`/`footerFonts` —
    /// absent when that line opened with no font-change block of its own). Resolved the
    /// SAME way a body span's own font run is (`pdfFamily`), so LJ6DTP's running head —
    /// Antique Olive, a proportional sans face, per its own `.h1` — no longer falls back
    /// to a hardcoded Courier just because header text has no span machinery of its own.
    /// `hfRuns` (already used by Modern/RTF for this exact text, never before by Printed)
    /// turns WordStar's own typed toggle bytes into styles, so a genuinely bold run still
    /// renders bold in whatever face this resolves to, and the toggle bytes themselves
    /// never reach the page as literal control characters.
    ///
    /// No font on this line (the overwhelmingly common case — every document that never
    /// opens a `.h#`/`.f#` with a font block) is BYTE-IDENTICAL to before this existed:
    /// one Tj, the whole string, Courier. `res` is required for the new path (it registers
    /// whatever base-14 font gets used in the page's own /Font resources); a caller that
    /// omits it gets the old behaviour rather than a crash.
    func hfLineOps(_ txt: String, y: Double, fontIdx: Int?) -> [[UInt8]] {
        var entry: FontChange? = nil
        if let fontIdx, res != nil, fontIdx >= 0, fontIdx < doc.fonts.count {
            entry = doc.fonts[fontIdx]
        }
        guard let entry, let res else {
            var out = Array("BT /\(pdfFont(bold: false, italic: false)) \(size) Tf 0 Ts ".utf8)
            out += Array("\(fixedOneDecimalDouble(left)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            out += esc(render(txt))
            out += Array(") Tj ET".utf8)
            return [out]
        }
        let family = pdfFamily(entry)
        let pt = entry.points != 0 ? max(1, roundHalfToEven(entry.points)) : size
        var ops: [[UInt8]] = []
        var x = left
        for (i, run) in hfRuns(txt).enumerated() {
            let runText = render(run.text)
            if runText.isEmpty { continue }
            if i == 0, runText.trimmed().isEmpty, entry.proportional {
                // WordStar re-stamps a tab-derived leading indent as 10-CPI machine
                // spaces regardless of the font in force (the SAME rule `splitIndent`
                // applies to body text) -- a proportional face's space glyph is much
                // narrower, so advancing on IT would pull the header text back toward the
                // margin instead of where WS7's own absolute-position PCL puts it
                // (measured: LJ6DTP.pcl's `&a1718H` immediately before this exact line's
                // "LJ6DTP").
                x += Double(runText.count) * pdfPtPerCol
                continue
            }
            let basefont = base14(family, bold: run.styles.contains(.bold),
                                  italic: run.styles.contains(.italic))
            let font = res.ref(basefont)
            var op = Array("BT /\(font) \(pt) Tf 0 Ts ".utf8)
            op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            op += esc(runText)
            op += Array(") Tj ET".utf8)
            ops.append(op)
            x += stringWidthPt(runText, basefont, pt)
        }
        return ops
    }

    // The header block is anchored to the BODY, not the paper edge: its last line sits
    // `.hm` lines above the first body line, inside `.mt` (".MT ... The header is
    // printed within this margin"; ".HM ... the distance between the header and the
    // text"). At WordStar's defaults (.mt 3, .hm 2, one header line) that IS paper line
    // 0 -- which is why rendering headers at the literal top of the sheet looked right
    // for years -- but a document that widens .mt moves its header DOWN with the body,
    // where a laser printer can physically print it (no printer lays ink at y = 0).
    //
    // b26-header-round2 (SUPERSEDES the b26-header-baseline analysis just above -- that
    // round's rule, "subtract hm only when hmSource == .file", was fit to a corpus where
    // every EXPLICIT-mt document also happened to carry an explicit .hm (SCRIPT), so
    // hmSource and mtSource were CONFOUNDED: nothing distinguished "keyed on hm's own
    // source" from "keyed on mt's". It shipped, then broke LJ6DTP.WS on Jon's paper
    // review -- LJ6DTP is the first oracle where mt is explicit (.mt 1.1") but hm is NOT
    // (never touches .hm at all), and it separates the two hypotheses cleanly.
    //
    // Two independent bugs were tangled in that break, both now fixed:
    //
    // (1) hm's participation is keyed on mtSource, not hmSource. Five measured WS7
    //     header baselines (WS7 frame, the usual -0.3pt decipoint residual), three
    //     independent documents:
    //       -README (.mt 3 DEFAULT, .hm 2 default): WS7 35.7 == headBase 2 =
    //         mt(3) - topHead(1) -- hm NOT subtracted (mtSource .default).
    //       SCRIPT normal (.MT 7 EXPLICIT, .HM 3 explicit): WS7 48.0 == headBase 3 =
    //         mt(7) - hm(3) - topHead(1) -- hm subtracted (mtSource .file).
    //       SCRIPT figure-1 (.mt1 mid-doc EXPLICIT, .HM 3 carries): WS7 12.0 ==
    //         headBase max(0, 1-3-1) = 0 -- hm subtracted.
    //       SCRIPT figure-2 (.mt1" mid-doc EXPLICIT, .HM 3 carries): WS7 36.0 ==
    //         headBase 2 = mt(6) - hm(3) - topHead(1).
    //       LJ6DTP (.mt 1.1" EXPLICIT globally, its own mid-document .mt1"/.mb1" --
    //         b26-mtmb-general's per-page swap sets THIS page's mtLines/mtSource to the
    //         LOCAL 6.0/.file, the SAME value `printedTop` already renders the (correct,
    //         unchanged) 86.0pt body baseline from; .hm never touches at all, stays
    //         2/.default): WS7 48.0 == headBase 3 = mt(6.0) - hm(2) - topHead(1) -- hm
    //         SUBTRACTED despite being hmSource .default, because mtSource is .file
    //         (the page's own local override, same one the body already trusts).
    //     All five fit ONE rule: hm participates whenever mt IS NOT at the document's
    //     factory default (mtSource == .file, reading whatever mt is ACTUALLY in force
    //     on this page -- the per-page swap value where one applies) -- regardless of
    //     whether hm ITSELF was ever typed. Once an author moves mt off the factory
    //     default, WS7 reserves hm's distance (explicit or its own factory default)
    //     between the header and the body; a document that never touches mt at all
    //     needs no such reservation, mt alone already being the header's own working
    //     measure.
    //
    // (2) `.mt`/`.hm` are LINE-COUNT dot commands in WordStar's own file format, always
    //     at the FIXED 6 LPI (12pt) baseline (`resolveLinesArg`'s own doc comment) -- a
    //     SEPARATE unit from `.lh`, the document's own (possibly customized) BODY TEXT
    //     leading. This function's headBase-to-points conversion used the caller's
    //     `lead` parameter (the document's `.lh`-derived body lead) instead of that
    //     fixed 12pt/line unit -- invisible on every prior oracle (-README, SCRIPT: both
    //     `.lh`-default, 12pt either way) until LJ6DTP, whose own `.lh` is customized to
    //     14pt (9.333/48in): bug (1) ALONE (hm unconditionally ignored, mtSource never
    //     checked) gave headBase 5.0 * 14pt lead + 12 = 82.0, the exact wrong baseline
    //     on Jon's paper -- squarely inside LJ6DTP's own body text (86.0pt, unaffected:
    //     `printedTop`'s top-margin reservation was never mixed with `.lh` to begin
    //     with). Fixing ONLY bug (1) with the WRONG (customized) lead still would not
    //     reach 48.0 (headBase 3.0 * 14 + 12 = 54.0) -- both had to be found.
    //     `PDFMetrics.lead` (this module's own 6 LPI constant, already used for the
    //     fontless/default-.lh case everywhere else) replaces `lead` here; `size` is
    //     untouched (the header's own font size, never a margin-count unit).
    // register b31-dot-command-sweep (SUPERSEDES the mtSource-only gate above): a probe
    // held `.mt` at its factory default for the WHOLE document (mtSource == .default
    // throughout, never .file) and still measured the header move to a DIFFERENT PCL row
    // once a mid-document `.hm` changed -- something the mtSource-only gate cannot produce
    // at all (it zeroes `hm` unconditionally whenever mt stays default). `hmSource` was
    // `.file` on the pages that moved (the author DID type `.hm` there) and `.default` on
    // the ones that didn't -- exactly what an OR of the two sources predicts, and every
    // one of the five measurements behind the gate above (each of which happened to have
    // hmSource == .file whenever mtSource was too, or vice versa) still fits an OR read
    // identically to the single-field gate they were built from: this widens the gate, it
    // does not re-litigate them.
    let mt = doc.page?.mtLines ?? 3.0
    let hm = (doc.page?.mtSource == .file || doc.page?.hmSource == .file)
        ? (doc.page?.hmLines ?? 2.0) : 0.0
    let topHead = Double(headers.keys.max() ?? 1)
    let headBase = max(0.0, mt - hm - topHead)

    var ops: [[UInt8]] = []
    for n in headers.keys.sorted() {
        guard let txt = headers[n], !txt.isEmpty else { continue }
        let y = Double(pageHeight) - (headBase + Double(n - 1)) * Double(PDFMetrics.lead)
            - Double(size)
        guard y >= 0 else { continue }
        ops += hfLineOps(txt, y: y, fontIdx: doc.headerFonts[n])
    }
    // b26-header-baseline: `fm` is deliberately UNCHANGED -- checked for the same
    // default/explicit asymmetry `.hm` turned out to have, above, and NOT applying it
    // here on the evidence actually available. No oracle in the corpus can test it
    // directly: -README (the coordinator's cited footer example) has no `.fo` at all --
    // `doc.footers` is empty, this was a wrong steer -- and LJ6DTP's own footer is two
    // raw print-control bytes with no visible text baseline to measure. The one real
    // data point that DOES exist (WordStar 4, 2026-08-03, footer at line
    // `.pl - .mb + .fm` = 60, `.fm` at its DEFAULT value, unconditionally applied)
    // argues AGAINST extending the header's fix here by symmetry -- it is real, if
    // dated, evidence that a default `.fm` already participates in the footer's own
    // placement, unlike a default `.hm` in the header's. Reported, not acted on.
    let footLine = pl - mb + fm
    for n in footers.keys.sorted() {
        guard let txt = footers[n], !txt.isEmpty else { continue }
        let y = Double(pageHeight) - Double(footLine + n - 1) * lead - Double(size)
        guard y >= 0 else { continue }
        ops += hfLineOps(txt, y: y, fontIdx: doc.footerFonts[n])
    }
    if showAutoNum {
        // WordStar's own AUTOMATIC number rides the SAME row a footer line 1 would (n=1:
        // footLine + 1 - 1 == footLine) — measured, every probe that ever showed both
        // together (a footer's own text plus its own `#`-substituted number; the
        // plain-auto-number probes' bottom digits) landed at the identical y a real
        // `.fo` line 1 uses. `showAutoNum` already excludes the case a real footer is in
        // use (WSFORMAT.WS's own "active only when the footers are not in use"), so this
        // never collides with the loop just above — at most one of the two ever fires
        // for a given page. Plain Courier, no font lookup — matches ctrl-kd's own
        // `FONTS[(False, False)]`, the same fallback face `hfLineOps` uses for a line
        // with no `.h#`/`.f#` font block of its own.
        let y = Double(pageHeight) - Double(footLine) * lead - Double(size)
        if y >= 0 {
            let x = autoPageNumberXPt(doc)
            var op = Array("BT /\(pdfFont(bold: false, italic: false)) \(size) Tf 0 Ts ".utf8)
            op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            op += esc(String(pageNo))
            op += Array(") Tj ET".utf8)
            ops.append(op)
        }
    }
    return ops
}

/// One coalesced segment of a line, resolved to the face and size it will be set in.
/// Python's `segs` tuple in `_page_stream`.
struct LineSegment {
    var text: String
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
    /// The active COLOUR (palette index), or `nil` for Black/no explicit colour — see
    /// `Span.colour`. Carried through layout the same way `entry`/`font` is.
    let colour: Int?
    /// A 0x0F user print control's declared HMI width, or `nil` — see `Span.pctlHMI`.
    let pctlHMI: Int?
    /// The index into `Document.pclPrograms` of this print control's raw PCL payload, or
    /// `nil` — see `Span.pcl`. Register C2.
    let pcl: Int?
    /// This segment IS a type-9 tab's own padding run: the block's ABSOLUTE target in
    /// HMIs from the left margin, and its leader byte — see `Span.tabHMI`/`tabLeader`.
    let tabHMI: Int?
    let tabLeader: Int?

    init(text: String, styles: Style, family: PDFFamily, size: Int, entry: FontChange?,
        indent: Bool, colour: Int? = nil, pctlHMI: Int? = nil, pcl: Int? = nil,
        tabHMI: Int? = nil, tabLeader: Int? = nil) {
        self.text = text
        self.styles = styles
        self.family = family
        self.size = size
        self.entry = entry
        self.indent = indent
        self.colour = colour
        self.pctlHMI = pctlHMI
        self.pcl = pcl
        self.tabHMI = tabHMI
        self.tabLeader = tabLeader
    }

    /// A copy with different text — everything else (styles, font, colour, pctl) carried
    /// over. Used by `splitGraphics`/`splitIndent`, which break one segment into several
    /// pieces of the same run.
    func withText(_ newText: String) -> LineSegment {
        LineSegment(text: newText, styles: styles, family: family, size: size, entry: entry,
                   indent: indent, colour: colour, pctlHMI: pctlHMI, pcl: pcl,
                   tabHMI: tabHMI, tabLeader: tabLeader)
    }
}

/// `(point size, baseline rise)` for a span set at `size`. Port of `pdf._sized`.
///
/// Superscript and subscript are both SET SMALLER, not just moved: one size test covering
/// either, then the rise chooses the direction. `sup` wins if a span somehow carries both,
/// matching Python's nested conditional. Reduced to 2/3 — 8pt at the default 12, the ratio
/// this emitter has always used.
/// `rollPt` (b24 round 17, RULINGS-LEDGER row 3, register C22): the declared `.sr` roll,
/// ALREADY converted to points — Printed's own domain only. `nil` (every Modern call site,
/// and any caller that predates this) keeps the exact prior fixed 3/-2 rise, same "reader
/// owns presentation" doctrine as every other Printed-only vertical-space item. WSFORMAT's
/// own text: "[.SR] The increments... which the carriage is to roll up OR DOWN for
/// subscript and superscript printing" — ONE symmetric amount, so a real `.sr` corrects
/// BOTH the sup rise (the old hardcoded +3 happened to already look plausible) and the sub
/// rise (the old -2 was never spec-derived at all).
func sized(_ styles: Style, _ size: Int, rollPt: Double? = nil) -> (points: Int, rise: Int) {
    if styles.contains(.sup) {
        return (max(1, roundHalfToEven(Double(size * 2) / 3.0)),
                rollPt.map { roundHalfToEven($0) } ?? 3)
    }
    if styles.contains(.sub) {
        return (max(1, roundHalfToEven(Double(size * 2) / 3.0)),
                rollPt.map { roundHalfToEven(-$0) } ?? -2)
    }
    return (size, 0)
}

/// Underline / strikethrough as stroked paths (PDF has no text attribute for either), for a
/// span occupying `w` points from `x`. Port of `pdf._rules`.
///
/// `continuous` (Jon's ruling 2026-08-20, REVERSING b24 round 17b's default —
/// RULINGS-LEDGER row 5/6, register C21): the DEFAULT is now continuous, spaces included.
/// Real WS7 LaserJet output (ws7-prints/v1; Jon's physical M479fdw print of those captures)
/// underlines the gaps: WS7 emits one UL-ON..UL-OFF span per `^PS` phrase with ESC&aH
/// cursor moves between words, and PCL underlines ALL horizontal movement while enabled.
/// None of those documents carries any `.ul`, so the measured no-`.ul` default is
/// continuous — the WS3.3 manual's "^PS does not underline blank spaces" clause (round
/// 17b's basis) describes a surface this driver demonstrably does not share. Jon: "With
/// Printed we are making a best attempt to match what you would get straight from WS with
/// no additional software." An EXPLICIT `.ul off` is still the file's own request for
/// characters-only underline and stays honored (`.ul` support ruled 2026-08-17) — the
/// parser records `underlineBlanks` only when the command is present, so `nil` (absent) and
/// `false` (`.ul off`) are distinguishable. Modern's own call site never passes this (stays
/// `true`, its prior and only behavior).
func rules(_ styles: Style, _ text: String, x: Double, y: Double, w: Double,
          continuous: Bool = true) -> [[UInt8]] {
    // A rule under a run of pure whitespace would be a stray dash, so Python guards both
    // with `text.strip()` — non-empty after stripping, i.e. the run has ink.
    guard text.contains(where: { !$0.isWhitespace }) else { return [] }
    var ops: [[UInt8]] = []
    if styles.contains(.strike) { ops.append(rule(xFrom: x, xTo: x + w, y: y + 3)) }
    guard styles.contains(.underline) else { return ops }
    if continuous || !text.contains(" ") {
        ops.append(rule(xFrom: x, xTo: x + w, y: y - 1.5))
        return ops
    }
    // Break the rule at each run of space characters — approximated by character-count
    // proportion of `w` (WordStar printed text is fixed-pitch or near-uniform within one
    // styled run; sub-point imprecision at a word boundary is not visible on paper).
    let chars = Array(text)
    let n = chars.count
    let perChar = w / Double(n)
    var i = 0
    while i < n {
        if chars[i] == " " { i += 1; continue }
        var j = i
        while j < n, chars[j] != " " { j += 1 }
        ops.append(rule(xFrom: x + Double(i) * perChar, xTo: x + Double(j) * perChar, y: y - 1.5))
        i = j
    }
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
/// arithmetic, and therefore its bytes, untouched. A FIXED-PITCH font block is never flagged
/// either: its space advances at its own pitch on the printer, full stop — a fixed-pitch
/// face's leading spaces measured in 10-CPI document columns instead shoves a border/box out
/// of alignment with its own sides (LJ6DTP's PC-8 chart, drawn in 11.9-CPI COURIER PC 12).
/// For 10-CPI Courier the two measures are the same number, so nothing else moves. The
/// document-column rule is for PROPORTIONAL runs only, where WordStar re-stamps tab/margin
/// positioning as 10-CPI machine spaces.
private func splitIndent(_ segs: [LineSegment]) -> [LineSegment] {
    var out: [LineSegment] = []
    var leading = true
    for seg in segs {
        if !leading {
            out.append(seg)
            continue
        }
        let pad = seg.text.count - seg.text.drop(while: { $0 == " " }).count
        if let entry = seg.entry, entry.proportional, pad > 0 {
            if pad < seg.text.count {
                out.append(LineSegment(text: String(seg.text.prefix(pad)), styles: seg.styles,
                                       family: seg.family, size: seg.size, entry: seg.entry,
                                       indent: true, colour: seg.colour, pctlHMI: seg.pctlHMI,
                                       pcl: seg.pcl, tabHMI: seg.tabHMI,
                                       tabLeader: seg.tabLeader))
                out.append(LineSegment(text: String(seg.text.dropFirst(pad)),
                                       styles: seg.styles, family: seg.family, size: seg.size,
                                       entry: seg.entry, indent: false, colour: seg.colour,
                                       pctlHMI: seg.pctlHMI, pcl: seg.pcl,
                                       tabHMI: seg.tabHMI, tabLeader: seg.tabLeader))
                leading = false
            } else {
                out.append(LineSegment(text: seg.text, styles: seg.styles, family: seg.family,
                                       size: seg.size, entry: seg.entry, indent: true,
                                       colour: seg.colour, pctlHMI: seg.pctlHMI, pcl: seg.pcl,
                                       tabHMI: seg.tabHMI, tabLeader: seg.tabLeader))
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
/// One BT..ET op for a styled (bold and/or italic) Symbol-face run. Port of `pdf.py`'s
/// `_symbol_style_op` (Finding 1, b26-print-fidelity-2). Mirrors the plain-run op shape
/// (Tf, [Tz], Ts, position, Tj) exactly, adding only what styling requires: `2 Tr <w> w`
/// before Ts for bold (text render mode + stroke width; stroke colour is whatever fill
/// colour is already active — Symbol runs never carry LJ6DTP colour tags in the reference
/// corpus, so this is always black, matching the fill), and Tm instead of Td for italic
/// (the shear).
///
/// Symbol has ONE cut in the base-14 set — a bold/italic span routed there used to lose its
/// styling entirely, but real WS7 does not: the -SCREEN.WS Greek sample line prints all four
/// runs (plain/bold/italic/bold-italic) visibly distinct. Measured against -SCREEN.pcl's own
/// font-select bytes for that line (offset 2767, the four `ESC(s...T` groups): all four
/// select the SAME typeface, height and pitch — confirmed by the measured chunk x-positions
/// too, the SAME 108pt advance for 14 glyphs in every style — so the LaserJet's own font
/// engine applied weight and posture to the SAME glyph cell rather than substituting a
/// wider/narrower design. Synthetic styling here does the same: the run's advance is never
/// touched (see call sites), only how the glyph is painted.
///   bold   -> text render mode 2 (fill THEN stroke), stroke width a fraction of the point
///             size (faux-bold weight; there is no measured stroke width to derive this from
///             — a printer's bold is a font-engine decision, not a PDF one — so `0.04 * pt`
///             is the "visibly bolder, not blotted" faux-bold weight, a judgment call).
///   italic -> an oblique shear on the text matrix (Tm replaces Td), the standard ~12-degree
///             slant used industry-wide when a face has no real italic cut; nothing in the
///             measured evidence implies a different angle (WS7's italic Greek run has the
///             identical 108pt advance as plain/bold, so the printer wasn't shearing the
///             ADVANCE either — a pure per-glyph oblique, exactly what Tm's shear does here:
///             the run still lands at the same (x, y) the unstyled Td path would have used).
/// An unstyled Symbol run (no bold/italic) never reaches this function — every existing
/// byte-identical guarantee holds.
///
/// Finding 3 (b26 visual pass, a real WS7 capture's own paper check): Tr is PDF general
/// graphics state, not text state reset by BT — it survives an ET/BT pair. This function is
/// the ONLY writer of Tr anywhere in this module, so it used to write `2 Tr` before a bold
/// run and simply say nothing for a non-bold one, trusting the DEFAULT (0, fill only) was
/// still in effect. On the reference capture's own Greek sample line the four styled runs
/// print plain/bold/italic/bold-italic in that order on one content stream — the italic-only
/// run comes right after the bold run and, with no Tr op of its own, inherited the bold
/// run's `2 Tr` (fill AND stroke) instead of the plain fill the real printer actually used,
/// which is exactly why the synthesized italic read heavier than the real printer's: it was
/// quietly getting a bold stroke, not just a shear. (The same leak would have kept stroking
/// every later op on the page too, symbol-styled or not, until whatever next set Tr some
/// other way — nothing else in this module ever did.) Always writing Tr now, every call,
/// makes each styled run self-contained regardless of what the stream's state happened to be
/// coming in.
private let italicShear = "0.2126"       // round(tan(12 degrees), 4)
private let boldStrokeFrac = 0.04        // faux-bold weight

private func symbolStyleOp(
    font: String, pt: Int, rise: Int, want: Int, tzState: inout Int,
    x: Double, y: Double, textBytes: [UInt8], isBold: Bool, isItalic: Bool
) -> [UInt8] {
    var op = Array("BT /\(font) \(pt) Tf ".utf8)
    if want != tzState {
        op += Array("\(fixedTwoDecimal(hundredths: want)) Tz ".utf8)
        tzState = want
    }
    if isBold {
        let strokeW = hundredths(Double(pt) * boldStrokeFrac)
        op += Array("2 Tr \(fixedTwoDecimal(hundredths: strokeW)) w ".utf8)
    } else {
        op += Array("0 Tr ".utf8)
    }
    op += Array("\(rise) Ts ".utf8)
    if isItalic {
        op += Array("1 0 \(italicShear) 1 \(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Tm (".utf8)
    } else {
        op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
    }
    op += textBytes
    op += Array(") Tj ET".utf8)
    return op
}

private func lineOpsPrinted(
    _ segs: [LineSegment], left: Double, y: Double, size: Int, res: FontResources,
    tzState: inout Int, colState: inout PDFFill, darkenState: inout Bool,
    colourMap: [Int: Double] = [:],
    rollPt: Double? = nil, fi: Double? = nil, ulContinuous: Bool = true,
    pclPrograms: [[UInt8]] = [], pageHeight: Double = Double(PDFMetrics.pageHeight),
    kerning: Bool = true
) -> [[UInt8]] {
    var ops: [[UInt8]] = []
    // `colourMap` is non-empty exactly when the document declares driver LJ6DTP — the
    // same gate covers its character substitutions.
    let segs = colourMap.isEmpty ? segs : ljSubstitute(segs, kerning: kerning)
    let splitSegs = splitIndent(splitSymbolFallback(splitGraphics(segs)))
    // b24 round 17 (RULINGS-LEDGER row 5/7): `.pm`'s first-line indent, in points,
    // already resolved relative to `left` (li=0 baseline — see `printedPMFiPt`).
    //
    // Finding A (b26-print-fidelity-2, WARPRAYR.WS): that stacking is right ONLY when
    // the line's own text does NOT already carry a typed leading indent of its own --
    // `.pm` exists for the paragraph whose first line starts flush in the SOURCE and
    // relies on `.pm` alone for its visual indent. WARPRAYR's Quote style (`.pm 5`) is
    // the other case: every line is typed with its own real leading spaces (5 on a
    // continuation, 10 on a stanza's own first line -- the author's hanging-indent
    // convention), so `splitIndent` below ALREADY produces the block's first line's
    // full, correct indent from those typed spaces alone. Adding `fi` on top
    // double-counts it. Measured (WARPRAYR.pcl): the couplet's first line ('"God the
    // all-terrible!', 10 typed spaces) and the prayer's own first line ('"O Lord our
    // Father', 10 typed spaces) both belong at x=122.4 -- the SAME position a
    // MID-block stanza's own first line reaches ('"For our sakes', also 10 typed
    // spaces, not `fi`-eligible since it isn't the block's first physical line) purely
    // from its typed indent. `fi` stacked on top of it pushed the block's own first
    // line to 158.4, the +36pt (`.pm`'s own 5 cols) double-count this fixes. A line
    // with NO typed leading whitespace of its own (`indent` never fires) is unaffected
    // -- `fi` remains its only indent source, unchanged.
    var fi = fi
    if fi != nil, splitSegs.first?.indent == true {
        fi = nil
    }
    var x = left + (fi ?? 0.0)
    // A pctl span whose display string carries a graphic char (box-drawing, LJ6DTP's own
    // «...┌─│...» labels) gets fragmented by `splitGraphics` above into several pieces
    // that all still carry the same pctl/pcl values — `drawnPCL` guards against executing
    // the same control's PCL program once per fragment. Register C2.
    var drawnPCL: Set<Int> = []
    for seg in splitSegs {
        // A 0x0F user print control's display string is SCREEN-ONLY: on paper WordStar
        // sent the raw printer payload and advanced by the block's own HMI word (0 for
        // LJ6DTP's rule-drawing controls, whose payload draws with no character advance
        // at all). The facsimile does the same: no text, the declared width of empty
        // space — PLUS, when the control's raw PCL survived parsing
        // (`Document.pclPrograms`, `Span.pcl`), the rectangles that PCL actually draws
        // (register C2: LJ6DTP's page border and page 4's checkerboard).
        if let hmi = seg.pctlHMI {
            if let idx = seg.pcl, !drawnPCL.contains(idx), idx < pclPrograms.count {
                drawnPCL.insert(idx)
                let prog = parsePCLProgram(pclPrograms[idx])
                // A raw PCL fill always draws in plain DeviceGray (LJ6DTP's own program
                // bytes carry the gray directly), so the value to restore afterward is
                // whatever fill gray the running text was already using.
                // `colState` is a gray or an HP pattern (register C3); a raw PCL fill
                // always draws in plain DeviceGray (LJ6DTP's own program bytes carry the
                // gray directly, never a pattern), so the restore value is that gray --
                // and LJ6DTP.WS never puts an embedded PCL program on a line that also
                // carries an HP-pattern colour, so the 0.0 fallback for a live pattern is
                // never actually exercised, just a safe default if that ever changes.
                let restore: Double
                if case .gray(let g) = colState { restore = g } else { restore = 0.0 }
                // register b31 (E1's own resolved-anchor question): a RELATIVE-move
                // program (LJ6DTP's checkerboard -- `push` then signed moves throughout,
                // see `pclRectOps`'s own doc comment) inherits `x`/`y`, this engine's own
                // IR-computed running text position -- but that position is in
                // WordStar's own document-column frame, and the raw PCL this control
                // sends bypasses that frame entirely to address the PHYSICAL PAGE,
                // exactly like an ABSOLUTE move already does (whose own correction is
                // `pclAbsXOffsetUnits`/`pclAbsYOffsetUnits`, this same printer's own
                // measured unprintable-area registration). The two frames disagree by
                // that SAME constant regardless of which addressing mode a given PCL
                // move uses -- measured against gpcl6's LJ6DTP-p4.png: page 4's
                // checkerboard left/centre land at 2.750in/4.125in with this correction
                // (vs 2.500in/3.875in without it), matching gpcl6's own 2.750in/4.123in
                // board measurement to within rounding, board WIDTH identical either way
                // (2.75in) -- confirming a uniform anchor shift, not a stretched or
                // mis-sized grid. A no-op for the border's own 100%-absolute program: an
                // absolute move ignores the anchor outright.
                ops += pclRectOps(prog,
                                  anchorX: x + Double(pclAbsXOffsetUnits) * pclUnitPt,
                                  anchorY: y - Double(pclAbsYOffsetUnits) * pclUnitPt,
                                  pageHeight: pageHeight, restoreGray: restore)
            }
            x += Double(hmi) / hmiPerPoint
            continue
        }
        let (pt, rise) = sized(seg.styles, seg.size, rollPt: rollPt)
        let baseFont = base14(seg.family, bold: seg.styles.contains(.bold),
                              italic: seg.styles.contains(.italic))
        let font = res.ref(baseFont)
        // Driver-aware colour: a span tagged with a colour under a driver whose palette
        // we know renders at that palette's gray. Emitted only when the value CHANGES
        // (fill gray is graphics state, like Tz), so every all-black document — and
        // every driver we cannot read — writes not one extra byte. This is what makes
        // LJ6DTP's knockouts work: white (15) text overprinted onto a black bar punches
        // out of it exactly as the LaserJet printed it.
        if !colourMap.isEmpty {
            // Register C3: colour9-14 (HP1-HP6) fill with a tiling PATTERN instead of a
            // flat gray -- registered per-page in /Resources by `emitPDF`, same mechanism
            // as /Font and /XObject. Anything else (or no colour tag at all) keeps the
            // plain DeviceGray fill.
            let want: PDFFill
            var wantDarken = false
            if let idx = seg.colour, lj6dtpHPPatterns[idx] != nil {
                want = .pattern(idx)
            } else {
                want = .gray(seg.colour.flatMap { colourMap[$0] } ?? 0.0)
                // register b31 E2: colour1-7 fills draw with a Darken blend, not flat
                // opaque paint. LJ6DTP's masthead types "LJ6DTP" in black, sets
                // `.lh.05"`, and types "LJ6DTP" again in colour4 (0.75 gray) to
                // overprint a shadow 0.05in below-right -- two SEQUENTIAL lines, not
                // the bare-CR overprint mechanism (`Line.overprint`), so nothing
                // already re-orders their paint. Real halftone ink over already-inked
                // paper stays dark; this emitter painted file-order and opaque, so the
                // gray shadow REPLACED the black title outright (measured against
                // ws7-prints/gpcl6-renders/LJ6DTP-p1.png: black on top, gray peeking
                // below-right only -- the opposite of what shipped). Scoped to cidx
                // 1-7 only, per the settled colour1-7-stays-flat-gray ruling this
                // same `want` computation already encodes -- colour15 (white
                // knockouts) and the colourless default black NEVER get it: Darken is
                // a no-op on white paper regardless (nothing below a fresh page to
                // darken against), so p5's swatches and p6's knockouts are unchanged
                // BY CONSTRUCTION, not by a separate exemption this code has to
                // maintain.
                wantDarken = seg.colour.map { (1...7).contains($0) } ?? false
            }
            if want != colState {
                switch want {
                case .pattern(let idx):
                    ops.append(Array("/Pattern cs /P\(idx) scn".utf8))
                case .gray(let gray):
                    ops.append(Array("\(fixedTwoDecimals(gray)) g".utf8))
                }
                colState = want
            }
            if wantDarken != darkenState {
                ops.append(Array((wantDarken ? "/GS1 gs" : "/GS0 gs").utf8))
                darkenState = wantDarken
            }
        }
        // A tab-marked span carries its block's own ABSOLUTE target (`content[2:4]`, HMI
        // from the LEFT MARGIN -- see `StructuralMark.tab`) -- so the pen is SET, not
        // advanced, for every tab, not only a line's own leading one. MEASURED against
        // real WS7 PCL (LJ6DTP.pcl page 5): two table rows whose tabs fire at DIFFERENT
        // pen positions (one right after "Black", the other after a dot-leader run) both
        // carry the SAME `content[2:4]` (4680 HMI), and only reading it as
        // absolute-from-margin reproduces both rows' real bar position -- relative-from-pen
        // would put the second bar 0.43in further right than WS7 actually printed it.
        //
        // This never collides with `splitIndent` above: that function's pad-based split
        // only ever fires on a MIXED span (typed leading spaces followed by real text
        // merged into one run by `coalesce`), and `coalesce` merges strictly on equal
        // style/run fields -- this span's own unique tab target means it is never merged
        // with the text before or after it, so it always reaches here as a span of its own,
        // entirely padding, and `splitIndent` either flags it whole or not at all. It also
        // retires that function's REASON for existing for this case (the tab's true stop
        // no longer needs to be inferred from a leading run's own width) -- but not the
        // function itself: a typed indent with no type-9 block at all carries no mark and
        // still needs the pad-based measure.
        if let tabHMI = seg.tabHMI {
            let targetX = left + Double(tabHMI) / hmiPerPoint
            let leaderByte = seg.tabLeader ?? 0x20
            if targetX <= x {
                // Overrun guard, the standard degenerate tab case: the stop is at or
                // behind the pen already. Never move backward -- advance by a single
                // space width instead, the same document-column measure the fill branch
                // below uses.
                x += Double(size) * 0.6
            } else if leaderByte == 0x20 {
                // A PLAIN tab (hard/soft/decimal/center/right types all degrade to space
                // padding -- see `tabColumns`): WS7 prints NO ink here at all, only a
                // horizontal-position escape (MEASURED, the same page-5 capture's "Black"
                // row -- nothing between the two ESC&a..H moves). Jump the pen; draw
                // nothing, matching the real printer exactly.
                x = targetX
            } else {
                // A DOT-LEADER tab: WS7 DOES print the fill characters (MEASURED, the same
                // capture's "85%" row: literal '.....' between its two ESC&a..H moves) --
                // but it REPEATS the leader glyph at its own NATURAL advance to fill the
                // gap; it never stretches a fixed run to fit it. MEASURED against
                // LJ6DTP.pcl page 5 directly: the type-9 block's own declared run is 16
                // characters (`content[0:2]`'s HMI / the column unit, what `seg.text`
                // holds here), but the real printer output between ESC&a2066H and the
                // pattern fill that starts the row's bar (shared with the next row's
                // plain-tab target, 3168) is 27 literal periods at THEIR natural width --
                // WS7's own PCL never carries a horizontal-scale escape for a leader run
                // at all. So: count how many natural-width glyphs fit in the gap and draw
                // exactly that many, unscaled. Floored, not rounded, so the run stops
                // short of the target rather than landing on or past it -- the same
                // capture never shows a leader dot colliding with what follows. The pen
                // still jumps to the target EXACTLY afterward (every tab branch here does
                // that), so a short-by-a-fraction leader never mispositions the NEXT span
                // even though it does leave a sliver of unfilled gap immediately before
                // the target, exactly as a real dot leader looks.
                let wGap = targetX - x
                let leaderChar = Character(Unicode.Scalar(UInt8(leaderByte)))
                let charW = stringWidthPt(String(leaderChar), baseFont, pt)
                let count = charW > 0 ? Int(wGap / charW) : seg.text.count
                let runText = String(repeating: String(leaderChar), count: max(0, count))
                let symbolBold = seg.family == .symbol && seg.styles.contains(.bold)
                let symbolItalic = seg.family == .symbol && seg.styles.contains(.italic)
                if count == 0 {
                    // nothing fits: no ink, and the pen still lands on the stop below
                } else if symbolBold || symbolItalic {
                    ops.append(symbolStyleOp(
                        font: font, pt: pt, rise: rise, want: hundredths(tzDefault),
                        tzState: &tzState, x: x, y: y, textBytes: esc(runText),
                        isBold: symbolBold, isItalic: symbolItalic))
                } else if hundredths(tzDefault) == tzState {
                    var op = Array("BT /\(font) \(pt) Tf \(rise) Ts ".utf8)
                    op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
                    op += esc(runText)
                    op += Array(") Tj ET".utf8)
                    ops.append(op)
                } else {
                    var op = Array("BT /\(font) \(pt) Tf \(rise) Ts ".utf8)
                    op += Array("\(fixedTwoDecimal(hundredths: hundredths(tzDefault))) Tz ".utf8)
                    op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
                    op += esc(runText)
                    op += Array(") Tj ET".utf8)
                    ops.append(op)
                    tzState = hundredths(tzDefault)
                }
                if count != 0 {
                    ops += rules(seg.styles, runText, x: x, y: y,
                                 w: charW * Double(count), continuous: ulContinuous)
                }
                x = targetX
            }
            continue
        }
        // cp437 graphics (blocks, shades, box-drawing) draw as vectors at the span's own
        // advance. `splitGraphics` guarantees a span reaching here is either all-graphics
        // or has none. In a PROPORTIONAL face a block advances at the EM, not the face's
        // nominal average width (LJ6DTP's own two-part flush-right bar only closes at
        // 24 x em per segment); fixed-pitch blocks stay on the pitch. A span with NO font
        // block (every WS4 file) has no `.proportional` to ask — `spanPitch(nil, pt)`
        // already answers that case with the document's own Courier 0.6em column, the
        // same fontless pitch every other fontless span in this function is measured on.
        if seg.text.contains(where: { graphicChars.contains($0) }) {
            let pitch = (seg.entry?.proportional ?? false) ? Double(pt) : spanPitch(seg.entry, pt)
            ops += graphicOps(seg.text, x: x, y: y, pitch: pitch, pt: pt)
            x += Double(seg.text.width) * pitch
            continue
        }
        if let entry = seg.entry, entry.proportional, !seg.indent {
            // PROPORTIONAL runs advance at NATURAL widths, face-scaled. Every piece
            // (word or space run) occupies its own AFM width times the FACE-constant
            // Tz — the scale that lands the face's AVERAGE character on its HMI grid,
            // so a line's total comes out on the author's measure while every glyph and
            // every space keeps its true proportion. One op per word bounds a viewer's
            // substitute-metric drift to a single word; spaces advance with no operator
            // at all.
            let pitch = spanPitch(entry, pt)
            let want = hundredths(faceTz(baseFont, pitch, pt))
            let factor = Double(want) / 10000.0
            // Continuous underline (Jon's ruling 2026-08-20, see `rules`'s own docstring):
            // one-op-per-word pieces would break the rule at every space no matter what
            // `rules` decides — space pieces draw no text and never reach it with ink —
            // which is exactly the per-word look the ruling reverses, and exactly how
            // WS7's own PCL does NOT behave (one UL-ON..UL-OFF per phrase, cursor moves
            // between words). So underline is lifted out of the per-piece calls here and
            // drawn once, first inked piece to last inked piece, spaces between covered.
            // Explicit `.ul off` (`ulContinuous == false`) keeps the per-piece path.
            let spanUL = ulContinuous && seg.styles.contains(.underline)
            let pieceStyles = spanUL ? seg.styles.subtracting(.underline) : seg.styles
            let symbolBold = seg.family == .symbol && seg.styles.contains(.bold)
            let symbolItalic = seg.family == .symbol && seg.styles.contains(.italic)
            var ulX0: Double? = nil
            var ulX1 = 0.0
            for piece in splitKeepingSpaceRuns(seg.text) {
                let nat = stringWidthPt(piece, baseFont, pt)
                let pw = nat > 0 ? nat * factor : Double(piece.width) * pitch
                if piece.first != " " {
                    if symbolBold || symbolItalic {
                        ops.append(symbolStyleOp(
                            font: font, pt: pt, rise: rise, want: want, tzState: &tzState,
                            x: x, y: y, textBytes: esc(piece), isBold: symbolBold,
                            isItalic: symbolItalic))
                    } else {
                        var op = Array("BT /\(font) \(pt) Tf \(rise) Ts ".utf8)
                        if want != tzState {
                            op += Array("\(fixedTwoDecimal(hundredths: want)) Tz ".utf8)
                            tzState = want
                        }
                        op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
                        op += esc(piece)
                        op += Array(") Tj ET".utf8)
                        ops.append(op)
                    }
                    if ulX0 == nil { ulX0 = x }
                    ulX1 = x + pw
                }
                ops += rules(pieceStyles, piece, x: x, y: y, w: pw, continuous: ulContinuous)
                x += pw
            }
            if spanUL, let ulX0 {
                ops.append(rule(xFrom: ulX0, xTo: ulX1, y: y - 1.5))
            }
            continue
        }
        let scale: Double?
        let w: Double
        if seg.indent {
            scale = nil
            w = Double(seg.text.width) * Double(size) * 0.6      // document print columns
        } else {
            // Fixed-pitch (and metric-less) runs: width-matched onto the font block's
            // own HMI grid with Tz — for Courier the ratio is 100 by construction and no
            // operator is ever written, which is what keeps every fontless PDF
            // byte-identical.
            let target = spanTarget(seg.entry, pt, count: seg.text.width)
            (scale, w) = tzScale(seg.text, baseFont, pt, target)
        }
        let want = hundredths(scale ?? tzDefault)
        let symbolBold = seg.family == .symbol && seg.styles.contains(.bold)
        let symbolItalic = seg.family == .symbol && seg.styles.contains(.italic)
        if symbolBold || symbolItalic {
            ops.append(symbolStyleOp(
                font: font, pt: pt, rise: rise, want: want, tzState: &tzState,
                x: x, y: y, textBytes: esc(seg.text), isBold: symbolBold,
                isItalic: symbolItalic))
        } else {
            var op = Array("BT /\(font) \(pt) Tf \(rise) Ts ".utf8)
            if want != tzState {
                op += Array("\(fixedTwoDecimal(hundredths: want)) Tz ".utf8)
                tzState = want
            }
            op += Array("\(fixedOneDecimalDouble(x)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            op += esc(seg.text)
            op += Array(") Tj ET".utf8)
            ops.append(op)
        }
        ops += rules(seg.styles, seg.text, x: x, y: y, w: w, continuous: ulContinuous)
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
/// shadow is just a second, blurry banner.
///
/// The first line of a page takes its position from `top` and ITS OWN lead (not a flat
/// `size`, and not always the document default `lead` parameter) — b26 round 26 wave 3,
/// ctrl-kd's `fidelity_gate.py` Unit B. Measured 2026-08-20 against LYING.pcl: the title
/// block (`.lh` auto, vmi=-2, 16pt Times-Bold — `styleLeadPt` gives 1.2*16=19.2pt) has its
/// real WS7 baseline at PCL y=78.9pt; `top`=60pt (see `printedTop`) + this line's OWN lead
/// 19.2pt = 79.2pt, a 0.3pt residual — the same decipoint-rounding-sized gap as every
/// unstyled Courier document (where the line's own lead equals the document default 12pt,
/// which is also why using a flat `size` here never looked wrong before: for every
/// previously-measured doc, size and lead were both 12). Using the line's own `.lead` here
/// is the SAME rule every other line on the page already follows (`if n, !prevOverprint { y
/// -= line.lead ?? lead }`, just below) — unifying the first line with the rest rather than
/// special-casing it on a quantity (font size) no other line uses for vertical placement.
func pageStream(
    _ pagelines: Page, top: Int, pageHeight: Int = PDFMetrics.pageHeight,
    lead: Double = Double(PDFMetrics.lead), size: Int = PDFMetrics.size,
    left: Double = Double(PDFMetrics.margin),
    running: [[UInt8]] = [], fonts: [FontChange] = [], res: FontResources? = nil,
    colourMap: [Int: Double] = [:], rollPt: Double? = nil, ulContinuous: Bool = true,
    lineNoInterval: Int? = nil, pclPrograms: [[UInt8]] = []
) -> [UInt8] {
    let res = res ?? FontResources()
    var ops: [[UInt8]] = running
    // The baseline of the first line: down from the top of the paper by the margin, then by
    // that line's own height, because `Td` positions a baseline and not a line's top edge.
    let firstLead = pagelines.first?.lead ?? lead
    var y = Double(pageHeight - top) - firstLead
    // Horizontal scaling persists across text objects within a content stream; it starts at
    // PDF's own default on every page. See `lineOpsPrinted`.
    var tzState = hundredths(tzDefault)
    // Fill colour likewise: graphics state, reset per page -- a gray or an HP tiling
    // pattern, see `PDFFill` (register C3).
    var colState = PDFFill.gray(0.0)
    // register b31 E2: the Darken blend mode's own on/off state, tracked separately from
    // the fill colour itself -- two colour1-7 spans in a row change `colState` (a new
    // gray) without needing a second `gs` operator, but ENTERING or LEAVING the colour1-7
    // family always needs one. See `lineOpsPrinted`'s colour block.
    var darkenState = false
    var prevOverprint = false
    for (n, line) in pagelines.enumerated() {
        if n > 0, !prevOverprint {
            y -= line.lead ?? lead
        }
        prevOverprint = line.overprint
        // register b31: this line's own `.po` override (already resolved to points --
        // `PageLine.left`, see its own doc comment), or the document default `left`
        // parameter when the line never overrides it (`Double?`'s `??` already treats a
        // resolved left of 0.0 -- `.po 0` -- as present, not absent, so no explicit
        // `!= nil` check is needed the way a falsy-zero language would require).
        let leftHere = line.left ?? left
        // register b32-N10 (mirrored from ctrl-kd b48148c): this line's own `.sr` roll
        // (already resolved to points — `PageLine.roll`, see its own doc comment), or
        // the document default `rollPt` parameter when the line never overrides it. Same
        // `??` guard as `leftHere` above — a resolved roll of 0.0 (`.sr 0`, "do not
        // shift at all") is a real, present value, not an absent one.
        let rollHere = line.roll ?? rollPt
        // b24 round 19 (RULINGS-LEDGER PIX row): an image PageLine (see
        // `resolvePlainBody`) draws its XObject instead of text. `y` has already
        // advanced by this line's `.lead`, which since round 26 wave 3 (fidelity_gate.py
        // Finding A) is the RESERVED PLACEHOLDER block's height (`pixReservedAdvance`:
        // the tag line plus its contiguous following blanks), not the raster's own
        // continuous pixel height — so `y` now marks the BOTTOM of that reserved band,
        // not the image's own bottom edge. Measured 2026-08-20 against -README.pcl: WS7
        // draws the picture FLUSH WITH THE TOP of its reserved band (leaving any leftover
        // slack as blank space BELOW the image, before the next real content), not flush
        // with the band's bottom — shifting the drawn box up by `(reserved - heightPt)`
        // reproduces that: `imgY` is the band's top edge (`y + (reserved - heightPt)`)
        // minus the image's own height, i.e. flush with the band's top. `/Im<N>` is
        // registered in every page's `/XObject` resources by `emitPDF`, one entry per
        // embedded pix index, shared exactly like the `/Font` dict already is.
        if let img = line.image {
            let reserved = line.lead ?? img.heightPt
            let imgY = y + (reserved - img.heightPt)
            var op = Array("q \(fixedTwoDecimals(img.widthPt)) 0 0 \(fixedTwoDecimals(img.heightPt)) ".utf8)
            op += Array("\(fixedTwoDecimals(leftHere)) \(fixedTwoDecimals(imgY)) cm /Im\(img.pixIndex) Do Q".utf8)
            ops.append(op)
            continue
        }
        let coalesced = coalesce(line)
        // b24 round 17b (RULINGS-LEDGER row 5/6, register C11): `.l#`'s own gutter —
        // every Nth physical line on the page (1-based, N = the document's own `.l#`
        // interval, WordStar's own numbering convention — `.l# 5` numbers lines 5, 10,
        // 15...), right-aligned a few points left of the text margin. Blank lines are
        // never numbered (nothing to count on paper). The gutter draws in the margin
        // WordStar's own `.po`/`.lm` already reserved, same as a running head does —
        // register b31: that margin is THIS LINE's own (`leftHere`), not always the
        // document default, now that `.po` can override per line.
        if let interval = lineNoInterval, interval > 0, (n + 1) % interval == 0,
           coalesced.contains(where: { $0.text.contains { !$0.isWhitespace } }) {
            let label = String(n + 1)
            let gutterFont = res.ref("Courier")
            let gx = leftHere - 4.0 - Double(label.count) * Double(size) * 0.6
            var op = Array("BT /\(gutterFont) \(size) Tf 0 Ts ".utf8)
            op += Array("\(fixedOneDecimalDouble(gx)) \(fixedOneDecimalDouble(y)) Td (".utf8)
            op += esc(label)
            op += Array(") Tj ET".utf8)
            ops.append(op)
        }
        var segs: [LineSegment] = []
        // Coalesced FIRST (pdf.py:136): the wrapper leaves one segment per word and per
        // space-run, and each segment costs a text-showing operator. Merging runs that share
        // styles changes nothing on paper and divides the stream size by roughly ten.
        for span in coalesced {
            if span.text.isEmpty {
                continue                       // no operator, and no advance either
            }
            let rendered = spanRender(span.text, font: span.font, fonts: fonts, size: size)
            segs.append(LineSegment(text: rendered.text, styles: span.styles,
                                    family: rendered.family, size: rendered.size,
                                    entry: rendered.entry, indent: false,
                                    colour: span.colour, pctlHMI: span.pctlHMI,
                                    pcl: span.pcl, tabHMI: span.tabHMI,
                                    tabLeader: span.tabLeader))
        }
        ops += lineOpsPrinted(segs, left: leftHere, y: y, size: size, res: res, tzState: &tzState,
                             colState: &colState, darkenState: &darkenState,
                             colourMap: colourMap, rollPt: rollHere,
                             fi: line.fi, ulContinuous: ulContinuous,
                             pclPrograms: pclPrograms, pageHeight: Double(pageHeight),
                             kerning: line.kerning)
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
    var doc = doc
    // `options.pageSettings`: replacement geometry for everything the document does not
    // declare itself (a field is overridden only when its own resolved value is still
    // this project's built-in default — a document's own dot commands always win). This
    // exists because WordStar's stock defaults are not what a given machine printed:
    // WSCHANGE patches them per installation. Applied to a local COPY of `doc` — a value
    // type, so there is nothing to restore afterward, unlike Python's save/try/finally
    // dance around a shared mutable `doc.meta['page']`. Shared with the CLI's own
    // once-per-document application (`Run.swift`) via `effectivePage` (EmitOptions.swift).
    if let pageSettings = options.pageSettings, let page = doc.page {
        doc.page = effectivePage(page, settings: pageSettings)
    }
    let printed = mode == .printed || isPrinted(doc)
    // N9 (b33 field notes): mode-aware default, flag overrides either way.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: printed)
    // b24 round 17 (RULINGS-LEDGER row 2): `.pr or=l` — Printed only, same doctrine as
    // every other Printed-only geometry item. Applied AFTER `pageSettings` (matches
    // ctrl-kd: page-settings replacement geometry, then orientation swap on top of it).
    if printed, doc.formatting.orientation == .landscape, let page = doc.page {
        doc.page = landscapePage(page)
    }
    // THE STREAMS ARE WRITTEN FIRST: which base-14 fonts the document actually uses is only
    // known once every span has been laid out, and the resource table has to name them all.
    // `res` is a class (reference semantics), shared by every page, so `/Fn` numbering is
    // stable across the whole file whichever branch below fills it in.
    let res = FontResources()
    let streams: [[UInt8]]
    // Modern never touches driver-specific colour at all (see `colourMap`'s own use
    // below, inside the `printed` branch); this default just keeps the name bound for the
    // pattern-object step near the bottom, which runs on both paths and needs to know
    // "no patterns to build" on Modern's. Register C3.
    var colourMap: [Int: Double] = [:]
    // The SAME figure `printedCap` derives the line count from (PDFLayout.swift) — Python
    // computes it once in `emit_pdf` and uses it for both the MediaBox and the content
    // stream's Y-origin. A page that paginates at a custom `.pl`'s resolved capacity but
    // still declares a Letter-size MediaBox would be internally inconsistent: the right
    // number of lines, drawn on the wrong-size sheet of paper. Modern is always Letter
    // (`resolvedPageHeight` already returns the fixed height when `printed` is false), like
    // the Modern RTF's own page setup.
    let pageHeight = resolvedPageHeight(doc, printed: printed)
    // Width joined the page model 2026-08-06 ("the 3 main page sizes"): inferred from
    // the height -- A4-tall pages are 210mm wide, everything else is the 8.5in sheet --
    // so a default document stays exactly 612.
    let pageWidth = roundHalfToEven((doc.page?.pwIn ?? 8.5) * 72.0)
    if printed {
        let pages = docToPagelines(doc, printed: true, pixResults: options.pixResults,
                                   pictures: options.pictures, sentenceSpacing: ssOn)
        // ctrl-kd 1.3.0/2.0.0: per-document in Printed mode — `printedTop`/`printedLead`/
        // `printedSize`/`printedLeft` (PDFLayout.swift) read the file's own `.mt`/`.lh`/
        // `.cw`/`.po`, falling back to the same fixed figures a print stream (no page
        // geometry) always used. UNTOUCHED by the Modern-PDF rewrite (2026-08-05) — the
        // printed digests survive it byte-for-byte.
        let top = printedTop(doc)
        let lead = printedLead(doc)
        let size = printedSize(doc)
        let left = printedLeft(doc, size: size)
        // b24 round 17 (RULINGS-LEDGER row 3, register C22): `.sr` roll, printed only.
        let rollPt = printedRollPt(doc)
        // Jon's ruling 2026-08-20 (reverses b24 round 17b; RULINGS-LEDGER row 5/6,
        // register C21): default CONTINUOUS — measured WS7 LaserJet behavior, see
        // `rules`'s own docstring. Explicit `.ul off` still breaks at spaces (the parser
        // only records `underlineBlanks` when the command is present, so absent-vs-off
        // is distinguishable).
        let ulContinuous = doc.formatting.underlineBlanks ?? true
        // b24 round 17b (RULINGS-LEDGER row 5/6, register C11): `.l#`'s own interval,
        // flag-gated — default ON (same shape as `--headers`), but the FEATURE only
        // ever fires when the document itself declared `.l#` (`doc.lineNumbering` is
        // `nil` otherwise): the flag's job is letting a caller SUPPRESS what the file
        // asked for, not inventing numbering a silent file never requested.
        let lineNoInterval = options.lineNumbers ? doc.lineNumbering : nil
        // Font runs are a PRINTED-mode facsimile feature — WS4 documents and print
        // streams have no font blocks, so `doc.fonts` is empty for them and this is a
        // no-op either way.
        let fonts = doc.fonts
        // Colour is DRIVER-DEFINED: the palette indices a document records mean whatever
        // its printer description file says. LJ6DTP's table is known (recovered from the
        // driver file's own string table and confirmed against the document's sample
        // rows): 0 Black, 1-7 grays of decreasing ink, 15 White — the knockout that lets
        // white text punch out of a black bar. Any other driver: indices stay opaque,
        // nothing rendered. Printed-only: Modern has no colour ops at all.
        colourMap = doc.printerDriver == "LJ6DTP" ? colourGrayLJ6DTP : [:]
        // `.pn n` sets the number of the page it appears on, so a chapter file in a larger
        // manuscript numbers from where the previous one stopped. Printed-only: Modern has
        // no running heads at all, so there is nothing to number them for.
        let startNo = doc.page?.pnStart ?? 1
        // register b31-dot-command-sweep: `.pn` re-anchors mid-document too (see
        // `resolvePageNumbers`) -- one number per real page, replacing the flat
        // `startNo + pageIndex` below for the printed per-page loop.
        let pageNumbers = resolvePageNumbers(pnCheckpoints(doc), pages)
        // Register b31, E3 item 2 (ruled 2026-08-25, ctrl-kd 6f30157): `.auto` (default)
        // lets the document's own `.pn`/`.pg`/`.op` decide (see `pgnumCheckpoints`,
        // PDFLayout.swift) — byte-identical to every existing capture/oracle for the
        // overwhelming majority of documents that never touch any of those four
        // commands. `.on` forces WordStar's stock default numbering even on a document
        // that never asked for it; `.off` suppresses it unconditionally. Neither `.on`
        // nor `.off` touches an explicit `#` the author placed inside a real `.he`/`.fo`
        // — that is running-title content, substituted by `runningOps`'s own `render()`
        // regardless of this option.
        let pageNumbersMode = options.pageNumbers
        let pgnumCheckpointsList = pageNumbersMode == .auto ? pgnumCheckpoints(doc) : nil
        var built: [[UInt8]] = []
        for (i, page) in pages.enumerated() {
            // Per-page header/footer state, replayed from `doc.hfEvents` through
            // pagination (`Page.headers`/`.footers`) — populated for every page
            // regardless of which paginator built it (the notes-aware one stamps the
            // document's final state on every page instead, matching Python's `getattr`
            // fallback for a plain list).
            // b24 round 17 (RULINGS-LEDGER row 1): `options.headers` (default true) —
            // `runningOps` treats `nil` as "fall back to `doc.headers`/`doc.footers`",
            // the OPPOSITE of what the flag being off means, so the off path passes
            // `[:]` (falsy, not nil) instead, reusing `runningOps`'s own existing
            // early-return with zero new rendering logic.
            // Finding 3 (b26-print-fidelity-2): a page whose own `.mt`/`.mb`
            // (`Page.mtLines`/`mbLines`, set by `layoutPrintedPagesPlain` from
            // `mtMbCheckpoints`) differs from the document's global pair gets ITS OWN
            // top-margin/header-footer geometry — a local COPY of `doc` with `.page`
            // swapped (this file's own established idiom for "replacement geometry
            // just for this call", see `emitPDF`'s `pageSettings` handling above),
            // scoped to just this page's `printedTop`/`runningOps` calls. `nil`/`nil`
            // (every page of every document that never changes `.mt`/`.mb`
            // mid-document) skips the swap entirely: `pageTop` is the SAME `top` value
            // computed once above, byte-identical to before this fix.
            // register b31-dot-command-sweep: `.pl` alone (no `.mt`/`.mb` change) still
            // needs the swap below -- `runningOps`'s own footer-row placement reads
            // `plLines` too (WSFORMAT's "line pl-.mb+.fm" footer geometry), so a page
            // whose `.pl` changed but whose `.mt`/`.mb` did not would otherwise render its
            // footer at the WRONG row (the document's stale global `.pl`). `.hm`/`.fm` --
            // read by `printedTop` (the body's own top offset, gated on `mtSource`) and by
            // `runningOps` (the header/footer ROW itself) -- need the SAME per-page swap,
            // or a page whose `.hm`/`.fm` changed renders its running head/foot at the
            // document's stale global row.
            let pageTop: Int
            var pageDoc = doc
            if page.mtLines != nil || page.mbLines != nil || page.plLines != nil
                || page.hmLines != nil || page.fmLines != nil, var eff = doc.page {
                if let mt = page.mtLines { eff.mtLines = mt; eff.mtSource = .file }
                if let mb = page.mbLines { eff.mbLines = mb; eff.mbSource = .file }
                if let pl = page.plLines { eff.plLines = pl }
                if let hm = page.hmLines {
                    // `.file` only if THIS page's own resolved hm is a real override of
                    // WordStar's hardcoded default, not merely different from the
                    // document's (possibly WRONG, in the degenerate mid-document-only-
                    // occurrence case) global reading -- `runningOps`'s OR-gate treats
                    // hmSource == .file as "the author touched .hm", which must stay
                    // false for a page that sits BEFORE a document's only `.hm` ever
                    // fires, even though it still needs its own override (back to the
                    // true default) to correct `ParseWS.swift`'s global reading.
                    eff.hmLines = hm
                    eff.hmSource = hm != 2.0 ? .file : .default
                }
                if let fm = page.fmLines { eff.fmLines = fm; eff.fmSource = .file }
                pageDoc.page = eff
                pageTop = printedTop(pageDoc)
            } else {
                pageTop = top
            }
            // Register b31, E3 item 2: resolve THIS page's own automatic-number state.
            // `--headers off` already suppresses page numbers per its own documented
            // scope ("headers, footers, and page numbers"); `.on`/`.off` need no
            // page-level lookup at all, `.auto` resolves from the SAME block-index range
            // `resolvePageNumbers` uses.
            let autoPageNumber: Bool
            if !options.headers || pageNumbersMode == .off {
                autoPageNumber = false
            } else if pageNumbersMode == .on {
                autoPageNumber = true
            } else if let checkpoints = pgnumCheckpointsList, let pageMaxBi = page.compactMap(\.bi).max() {
                autoPageNumber = pgnumAt(checkpoints, pageMaxBi)
            } else {
                autoPageNumber = false
            }
            let running = runningOps(pageDoc, pageNo: pageNumbers[i], pageHeight: pageHeight,
                                     lead: lead, size: size, left: left, printed: true,
                                     headers: options.headers ? page.headers : [:],
                                     footers: options.headers ? page.footers : [:],
                                     res: res, autoPageNumber: autoPageNumber)
            built.append(pageStream(page, top: pageTop, pageHeight: pageHeight, lead: lead,
                                    size: size, left: left, running: running,
                                    fonts: fonts, res: res, colourMap: colourMap,
                                    rollPt: rollPt, ulContinuous: ulContinuous,
                                    lineNoInterval: lineNoInterval,
                                    pclPrograms: doc.pclPrograms))
        }
        // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index compiled as ADDITIONAL pages at
        // the document's own end (Jon: "It should probably export in all formats even
        // though non-paged ones couldn't be referenced"), TOC before Index. `--toc off`
        // (the ruled default) leaves the page count exactly as it always was. These extra
        // pages carry no running head/footer of their own -- a documented simplification,
        // not the document's own running content replayed past its last real page.
        if options.toc, !doc.tocEntries.isEmpty || !doc.indexEntries.isEmpty {
            let tocLines = tocIndexPagelines(doc, pageNumbers: tocPageNumbers(
                doc, pixResults: options.pixResults, pictures: options.pictures))
            let cap = max(1, printedCap(doc))
            var chunkStart = 0
            while chunkStart < tocLines.count {
                let chunk = Array(tocLines[chunkStart..<min(chunkStart + cap, tocLines.count)])
                let pageIndex = built.count
                let running = runningOps(doc, pageNo: startNo + pageIndex, pageHeight: pageHeight,
                                         lead: lead, size: size, left: left, printed: true,
                                         headers: [:], footers: [:], res: res)
                built.append(pageStream(Page(chunk), top: top, pageHeight: pageHeight, lead: lead,
                                        size: size, left: left, running: running,
                                        fonts: fonts, res: res, colourMap: colourMap,
                                        rollPt: rollPt, ulContinuous: ulContinuous,
                                        lineNoInterval: nil))
                chunkStart += cap
            }
        }
        streams = built
    } else {
        // Modern: the printed form of the Modern RTF (ruling 2026-08-05) — document fonts
        // carried, proportional reflow at the real measure, footnotes at the page bottom,
        // fontless body Times 14. Always US Letter, like the RTF's own page setup. No
        // running heads, no colour ops — both are Printed-only features.
        streams = modernStreams(doc, options: options, res: res)
    }

    // (number, body) — the body WITHOUT the `N 0 obj` wrapper, which the writer adds while
    // recording offsets.
    var objs: [(number: Int, body: [UInt8])] = []
    var nextNum = 3                                   // 1 and 2 are reserved, inserted below

    var fontNums: [(name: String, number: Int)] = []
    for font in res.fonts {
        fontNums.append((font.name, nextNum))
        // `/WinAnsiEncoding` on the ALPHABETIC faces: without a declared encoding a Type1
        // font falls back to its built-in StandardEncoding, where the cp1252 bytes `esc`
        // writes for curly quotes, dashes and © name the WRONG glyphs. Symbol and
        // ZapfDingbats keep their built-in encodings — their bytes are glyph indices by
        // design (`SymbolTranslit.swift`).
        if font.baseFont == "Symbol" || font.baseFont == "ZapfDingbats" {
            objs.append((nextNum, Array(
                "<< /Type /Font /Subtype /Type1 /BaseFont /\(font.baseFont) >>".utf8)))
        } else {
            objs.append((nextNum, Array(
                ("<< /Type /Font /Subtype /Type1 /BaseFont /\(font.baseFont)"
                + " /Encoding /WinAnsiEncoding >>").utf8)))
        }
        nextNum += 1
    }
    // Every page's /Resources names every font the DOCUMENT reached for, whether this page
    // used it or not — a handful of indirect references cost less than tracking which faces
    // a page turned out to contain, and a per-page table would renumber nothing but would
    // still have to be built twice.
    let fontDict = fontNums.map { "/\($0.name) \($0.number) 0 R" }.joined(separator: " ")

    // b24 round 19 (RULINGS-LEDGER PIX row): one Image XObject per embedded pix result,
    // built from `pixDecode`'s own RGB rows (NOT the PNG bytes RTF/HTML use -- PDF's
    // native image mechanism needs no PNG container at all, and this avoids writing a
    // PNG decoder just to re-read what pix.py already decoded once). Always
    // DeviceRGB/8bpc (even for a mono source) -- simpler and correct for every source
    // depth; a real size optimisation (1-bit for mono, mirroring `pixToPNG`'s own
    // choice) is left for later, noted rather than silently assumed. Shared across
    // every page exactly like `fontDict` already is -- an XObject unused on a given
    // page costs nothing per the PDF spec.
    // No longer printed-only: round 22 closed round 19's Modern scope cut, so
    // `modernStreams` places `/Im<N> Do` operators too and needs the same objects.
    var imageObjs: [Int: Int] = [:]                       // pix index -> obj num
    if options.pictures != .off, !options.pixResults.isEmpty {
        for r in options.pixResults {
            guard r.ok, let rawBytes = r.rawBytes,
                  let (gcols, grows, rgbRows) = try? pixDecode(rawBytes) else { continue }
            var raw: [UInt8] = []
            raw.reserveCapacity(gcols * grows * 3)
            for row in rgbRows {
                for px in row {
                    raw.append(px.r); raw.append(px.g); raw.append(px.b)
                }
            }
            // level 6: matches Python's own `_zlib.compress(bytes(raw), 6)` in
            // pdf.py's own XObject construction -- b24 round 21b, byte-exact
            // DEFLATE parity (zlib's own default level, explicit here since the
            // Swift call has no "no level given" shorthand worth relying on).
            let compressed = zlibCompress(raw, level: 6)
            var body = Array("""
            << /Type /XObject /Subtype /Image /Width \(gcols) /Height \(grows) \
            /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode \
            /Length \(compressed.count) >>\nstream\n
            """.utf8)
            body += compressed
            body += Array("\nendstream".utf8)
            objs.append((nextNum, body))
            imageObjs[r.index] = nextNum
            nextNum += 1
        }
    }
    let xobjectDict = imageObjs.isEmpty ? "" : " /XObject << "
        + imageObjs.sorted { $0.key < $1.key }.map { "/Im\($0.key) \($0.value) 0 R" }.joined(separator: " ")
        + " >>"

    // LJ6DTP's HP1-HP6 tiling patterns (`colourMap` is `colourGrayLJ6DTP`, non-empty,
    // exactly when the document declares that driver -- the same gate as everywhere else
    // this table is consulted). Shared across every page exactly like `fontDict`/
    // `xobjectDict`; a page whose own content never selects colour9-14 (every page but 5)
    // references a /Pattern resource dict it never uses, which costs nothing per the PDF
    // spec. Register C3.
    var patternObjs: [Int: Int] = [:]                     // colour index -> obj num
    if !colourMap.isEmpty {
        for idx in lj6dtpHPPatterns.keys.sorted() {
            let pattern = lj6dtpHPPatterns[idx]!
            let content = Array(pattern.content.utf8)
            var body = Array(("<< /Type /Pattern /PatternType 1 /PaintType 1"
                + " /TilingType 1 /BBox [0 0 \(pattern.w) \(pattern.h)]"
                + " /XStep \(pattern.w) /YStep \(pattern.h)"
                + " /Resources << >> /Length \(content.count) >>\nstream\n").utf8)
            body += content
            body += Array("\nendstream".utf8)
            objs.append((nextNum, body))
            patternObjs[idx] = nextNum
            nextNum += 1
        }
    }
    let patternDict = patternObjs.isEmpty ? "" : " /Pattern << "
        + patternObjs.sorted { $0.key < $1.key }.map { "/P\($0.key) \($0.value) 0 R" }
            .joined(separator: " ")
        + " >>"

    // register b31 E2: /GS0 (Normal) and /GS1 (Darken) ExtGStates, registered per-page
    // exactly like /Pattern just above -- same gate (`colourMap` non-empty, i.e. the
    // document declares the LJ6DTP driver), same "a page that never selects colour1-7
    // references a resource it never uses, costing nothing" reasoning. /GS0 exists so
    // leaving the colour1-7 family can SET Normal back explicitly (`gs` graphics state
    // persists across BT/ET and would otherwise still read Darken from an earlier span
    // on the same page) rather than relying on an assumed initial value once any `gs`
    // operator has ever been written.
    var extGStateObjs: [String: Int] = [:]
    if !colourMap.isEmpty {
        objs.append((nextNum, Array("<< /Type /ExtGState /BM /Normal >>".utf8)))
        extGStateObjs["GS0"] = nextNum
        nextNum += 1
        objs.append((nextNum, Array("<< /Type /ExtGState /BM /Darken >>".utf8)))
        extGStateObjs["GS1"] = nextNum
        nextNum += 1
    }
    let extGStateDict = extGStateObjs.isEmpty ? "" : " /ExtGState << "
        + extGStateObjs.sorted { $0.key < $1.key }.map { "/\($0.key) \($0.value) 0 R" }
            .joined(separator: " ")
        + " >>"

    var pageNums: [Int] = []
    var contentNums: [Int] = []
    for _ in streams {
        pageNums.append(nextNum); nextNum += 1
        contentNums.append(nextNum); nextNum += 1
    }

    let kids = pageNums.map { "\($0) 0 R" }.joined(separator: " ")
    objs.insert((1, Array("<< /Type /Catalog /Pages 2 0 R >>".utf8)), at: 0)
    objs.insert((2, Array(
        "<< /Type /Pages /Kids [\(kids)] /Count \(streams.count) >>".utf8)), at: 1)

    for (i, stream) in streams.enumerated() {
        objs.append((pageNums[i], Array("""
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) \
        \(pageHeight)] /Resources << /Font << \(fontDict) >>\(xobjectDict)\(patternDict)\(extGStateDict) >> \
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
