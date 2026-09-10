import Testing
@testable import CtrlKD

/// Planning #255: a `.h#`/`.f#` argument's own embedded paragraph-style-sheet reference
/// (0x11 selection, WSFORMAT's "Header Odd"/"Header Even" style sheets, real corpus
/// shape sawyer/REF/GALLEYS.DOT/ADVANCE.DOT's `.h1o`/`.h1e`) resolves its style's own
/// RIGHT/CENTER justification, font, and span attrs into the header/footer model --
/// never modeled before this (both engines always left-aligned, regardless of what the
/// selected style asked for). Swift port of ctrl-kd's own new unit tests (tests/
/// test_ctrlkd.py's `test_head_foot_style_select_*` cases).

/// A minimal WS5+ document whose header line `tag` opens with a 0x11 style-select
/// referencing a library style at `slot` -- the same shape `styleRef`/`documentWithStyleLibrary`
/// already build for body-text style tests, here on a `.h#`/`.f#` argument instead (real
/// corpus shape: GALLEYS.DOT/ADVANCE.DOT's `.h1o`/`.h1e`). `just` is the raw signed
/// justification byte (`StyleRecord.justificationRaw`'s own vocabulary: 0 left, 1
/// justify, -2 center, -3 right).
private func hfStyleDoc(just: Int, slot: Int = 2, attrsOn: Int = 0,
                        font: (width: Int, height: Int, typestyle: Int) = (142, 220, 49710),
                        tag: String = ".h1o") -> [UInt8] {
    var entries: [(name: String?, record: [UInt8]?)] = [
        (name: "WordStar Defaults", record: nil),
        (name: "WordStar Defaults", record: nil),
    ]
    entries += Array(repeating: (name: "unused", record: nil), count: max(0, slot - 2))
    entries.append((name: "Header Style",
                    record: styleRecord(just: just, attrsOn: attrsOn, font: font)))
    let lib = styleLibrary(entries)
    let style = styleRef(slot)
    var body = bytes("\(tag) ")
    body += style
    body += bytes("TITLE #")
    body += HARD
    body += bytes("Body text follows.")
    body += HARD
    return documentWithStyleLibrary(body: body, library: lib)
}

@Test func headFootStyleSelectResolvesRightAlignment() {
    // The core defect: a `.h#`/`.f#` argument's own 0x11 style-select resolves its
    // style's 'flush right' justification into `Document.headerAlign`/`headerAlignParity`
    // -- never modeled before planning #255 (both engines always left-aligned,
    // regardless of what the selected style asked for).
    let doc = parseWS(hfStyleDoc(just: -3))     // -3: flush right
    #expect(doc.headerAlignParity == [1: [.odd: .right]])
    // The flat, parity-unaware projection every `.h#`/`.f#` command also writes
    // (Modern/RTF/plain-text's own legacy fallback, #250's own carve-out) gets the
    // SAME last-in-source-order value.
    #expect(doc.headerAlign == [1: .right])
}

@Test func headFootStyleSelectCenterAndLeftAndJustifyNeverAlign() {
    // WSFORMAT documents right/center as the header/footer alignment axis; 'left'
    // (explicit no-justification) and 'justify' (full justification, a body-paragraph-
    // only concept) both fall through to absent -- WordStar's own ordinary left-aligned
    // placement, exactly as before this mechanism existed.
    #expect(parseWS(hfStyleDoc(just: -2)).headerAlign == [1: .center])
    #expect(parseWS(hfStyleDoc(just: 0)).headerAlign == [:])
    #expect(parseWS(hfStyleDoc(just: 1)).headerAlign == [:])
}

@Test func headFootStyleSelectCarriesItsOwnFontAndAttrs() {
    // Real WS7 capture (ADVANCE.DOT): "Header Odd"/"Header Even" both declare a
    // non-default proportional font AND bold -- a style selection changes the ACTIVE
    // FONT for header/footer text exactly as it does for body text (`styleFontIndex`,
    // the SAME cache/cross-reference body spans use), and its span attrs become this
    // line's own baseline styling (`Document.headerStyleAttrsParity`), unioned with
    // (never replacing) any inline toggle bytes typed in the argument text itself.
    let doc = parseWS(hfStyleDoc(just: -3, attrsOn: 0b1000000))   // bold
    let fontIdx = doc.headerFontsParity[1]?[.odd]
    #expect(fontIdx != nil)
    let entry = doc.fonts[fontIdx!]
    #expect(entry.proportional == true)
    #expect(pdfFamily(entry) == .helvetica)
    #expect(entry.points == 11.0)
    #expect(doc.headerStyleAttrsParity == [1: [.odd: [.bold]]])
}

@Test func headFootStyleSelectFooterMirrorsHeader() {
    // `.f#`'s own mirror of the header mechanism above -- no corpus document exercises
    // a style-selected FOOTER, but WSFORMAT documents `.FO`/`.F1` symmetrically with
    // `.HE`/`.H1`, and both engines implement the family uniformly.
    let doc = parseWS(hfStyleDoc(just: -3, tag: ".f1o"))
    #expect(doc.footerAlignParity == [1: [.odd: .right]])
    #expect(doc.footerAlign == [1: .right])
    #expect(doc.headerAlign == [:])                 // untouched -- no `.h#` at all
}

@Test func headFootStyleSelectShiftsThePrintedXRight() {
    // End-to-end: the resolved 'right' alignment actually MOVES the Printed model's
    // own `x` -- `hfAlignX`'s own formula, pinned against the SAME `hfNaturalWidthPt`
    // a consumer would compute, rather than a hardcoded point value that would
    // silently stop meaning anything the moment an AFM table changes. The right edge
    // here is the document's own UNCHANGED defaults (`.po`'s document default, the
    // 65-column `.rm` default) -- this fixture sets neither, proving the mechanism
    // needs no special-cased page geometry to work.
    let doc = parseWS(hfStyleDoc(just: -3))
    let pages = docToPagelines(doc, printed: true)
    let hl = pages[0].headerLines
    #expect(hl?.first?.text == "TITLE 1")
    let size = printedSize(doc)
    let left = printedLeft(doc, size: size)
    let rightEdge = printedHfRight(doc, left: left)
    let fontIdx = doc.headerFontsParity[1]?[.odd]
    let styleAttrs = doc.headerStyleAttrsParity[1]?[.odd] ?? []
    let width = hfNaturalWidthPt("TITLE 1", fontIdx: fontIdx, doc: doc, size: size,
                                 styleAttrs: styleAttrs)
    #expect(abs((hl?.first?.x ?? 0) - ((rightEdge ?? 0) - width)) < 0.05)
    // Sanity: well clear of the plain left margin -- a real shift, not a rounding no-op.
    #expect((hl?.first?.x ?? 0) > left + 50)
}

@Test func headFootNoStyleSelectIsUnchanged() {
    // A plain `.h1` with no 0x11 selection at all resolves `headerAlign` to absent and
    // renders at the ordinary left margin -- byte-identical to every document before
    // planning #255 existed.
    let data = bytes(".h1 PLAIN HEADER #\r\n") + bytes("Body text follows.") + HARD
    let doc = parseWS(data)
    #expect(doc.headerAlign == [:])
    let pages = docToPagelines(doc, printed: true)
    let hl = pages[0].headerLines
    let size = printedSize(doc)
    let left = printedLeft(doc, size: size)
    #expect(hl?.first?.x == left)
}
