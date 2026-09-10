import Testing
@testable import CtrlKD

/// Planning #250: `.h1e`/`.h1o`/`.f1e`/`.f1o` parity-conditional header/footer TEXT.
/// Swift port of ctrl-kd's own new unit tests (`tests/test_ctrlkd.py`'s
/// `test_head_foot_parity_*` cases) -- cross-engine byte parity for the full 389-doc
/// public corpus is `AnswerKeyParityTests`'/`HeadFootModelPDFParityTests`' own job;
/// these are the narrower, synthetic, single-document checks.

/// A multi-page document (55 body lines/page at defaults, so `n=120` spans 3 pages)
/// whose header carries `.h1e`/`.h1o`. `only` (nil/.even/.odd) emits just one side of
/// the pair, for the "one of the pair set" fixtures -- no corpus document exercises
/// this, so the fallback reading (the un-set parity falls through to whatever plain
/// `.h1`/`.fo` is in force) needs its own synthetic coverage.
private func hfParityDoc(n: Int = 120, only: HFParity? = nil) -> [UInt8] {
    var src: [UInt8] = []
    if only == nil {
        src += bytes(".h1e EVEN-TEXT PAGE #\r\n.h1o ODD-TEXT PAGE #\r\n")
    } else if only == .even {
        src += bytes(".h1 PLAIN-TEXT PAGE #\r\n.h1e EVEN-TEXT PAGE #\r\n")
    } else if only == .odd {
        src += bytes(".h1 PLAIN-TEXT PAGE #\r\n.h1o ODD-TEXT PAGE #\r\n")
    }
    for i in 1...n {
        src += bytes(String(format: "LINE %03d ", i) + String(repeating: "-", count: 40))
        src += HARD
    }
    return src
}

/// [(pageNo, text), ...] this document's own resolved Printed header line 1, one entry
/// per page, via `docToPagelines`'s `headerLines` -- the same model both the writer and
/// `layout` JSON read.
private func printedHeaderTexts(_ doc: Document) -> [(Int, String?)] {
    let pages = docToPagelines(doc, printed: true)
    return pages.enumerated().map { (i, pg) in (i + 1, pg.headerLines?.first?.text) }
}

@Test func headFootParityOddEvenTextAlternatesByPage() {
    // `.h1e`/`.h1o` (WSFORMAT.TXT: only `.HE`/`.H1` and `.FO`/`.F1` "can optionally
    // specify even or odd numbered page" headers/footers) select a DIFFERENT text per
    // page, by that page's own parity -- measured against real WS7 (sawyer/REF/
    // BOOKLET.HOW: WS7's even pages print `.h1e`'s text, odd pages `.h1o`'s).
    let doc = parseWS(hfParityDoc())
    let texts = printedHeaderTexts(doc)
    #expect(texts.map(\.1) == ["ODD-TEXT PAGE 1", "EVEN-TEXT PAGE 2", "ODD-TEXT PAGE 3"])
    // The flat, parity-UNAWARE projection (`doc.headers`) still carries the
    // last-in-source-order value for every non-Printed/non-parity-aware consumer
    // (Modern, RTF, plain text) -- unchanged legacy fallback, reported not implemented
    // for those formats this round.
    #expect(doc.headers == [1: "ODD-TEXT PAGE #"])
}

@Test func headFootParityH1OnlyDocumentIsUnchanged() {
    // A document with only a plain `.h1` (no `.h1e`/`.h1o` at all) prints the SAME
    // text on every page, byte-identical to before this feature existed -- `closePage`'s
    // `parityHF` resolver returns `nil` immediately (`doc.headersParity` empty) and
    // never touches `pg.headers`.
    var src = bytes(".he HEADER-TEXT PAGE #\r\n.fo FOOTER-TEXT PAGE #\r\n")
    for i in 1...120 {
        src += bytes(String(format: "LINE %03d ", i) + String(repeating: "-", count: 40))
        src += HARD
    }
    let doc = parseWS(src)
    let texts = printedHeaderTexts(doc)
    #expect(texts.map(\.1) == ["HEADER-TEXT PAGE 1", "HEADER-TEXT PAGE 2", "HEADER-TEXT PAGE 3"])
    #expect(doc.headersParity.isEmpty)
}

@Test func headFootParityH1eWithoutH1oFallsBackToTheFlatValue() {
    // The brief's own open question -- "a fallback-semantics call for 'only one of
    // the pair set' (no corpus document exercises it)" -- ruled here (`closePage`'s
    // own `parityHF`, PDFLayout.swift): the un-set parity (odd pages, here) has no
    // override of its own and falls through to the FLAT dict (`doc.headers`), which
    // every `.h#`/`.f#` command -- parity-tagged or not -- ALSO writes into
    // unconditionally, exactly the legacy last-in-source-order-wins projection
    // Modern/RTF/plain-text already read. This fixture's `.h1e` fires AFTER the
    // plain `.h1`, so the flat value is the `.h1e` text by the time it settles --
    // EVEN pages get their own override (the same text, here); ODD pages fall
    // through to that SAME flat value, never blank and never a crash.
    let doc = parseWS(hfParityDoc(only: .even))
    let texts = printedHeaderTexts(doc)
    #expect(texts.map(\.1) == ["EVEN-TEXT PAGE 1", "EVEN-TEXT PAGE 2", "EVEN-TEXT PAGE 3"])
    #expect(doc.headers == [1: "EVEN-TEXT PAGE #"])
}

@Test func headFootParityH1oWithoutH1eFallsBackToTheFlatValue() {
    // Mirror of the `.h1e`-only case above, for `.h1o` alone.
    let doc = parseWS(hfParityDoc(only: .odd))
    let texts = printedHeaderTexts(doc)
    #expect(texts.map(\.1) == ["ODD-TEXT PAGE 1", "ODD-TEXT PAGE 2", "ODD-TEXT PAGE 3"])
    #expect(doc.headers == [1: "ODD-TEXT PAGE #"])
}

@Test func headFootParityAPlainH1AfterH1eUpdatesOnlyTheFlatFallback() {
    // The OTHER half of the "only one of the pair" ruling above, pinned directly: a
    // parity-specific override (`.h1e`) is independently stateful (the `.poe`/`.poo`
    // precedent) -- a LATER plain `.h1` updates the flat fallback (what odd pages,
    // which have no `.h1o` override of their own, read) but does NOT clear the
    // even-page override already in force.
    var src = bytes(".h1e EVEN-TEXT PAGE #\r\n.h1 PLAIN-TEXT PAGE #\r\n")
    for i in 1...120 {
        src += bytes(String(format: "LINE %03d ", i) + String(repeating: "-", count: 40))
        src += HARD
    }
    let doc = parseWS(src)
    let texts = printedHeaderTexts(doc)
    #expect(texts.map(\.1) == ["PLAIN-TEXT PAGE 1", "EVEN-TEXT PAGE 2", "PLAIN-TEXT PAGE 3"])
}

@Test func headFootParityFooterF1eF1oAlternatesByPage() {
    // `.f1e`/`.f1o` (planning #250) -- the footer's own mirror of the header test
    // above. Zero real corpus documents use this pair (only `.h1e`/`.h1o` occur in
    // the Sawyer archive), but WSFORMAT.TXT documents `.FO`/`.F1` as carrying the
    // identical even/odd option `.HE`/`.H1` does, and both engines implement it
    // symmetrically.
    var src = bytes(".f1e EVEN-FOOT PAGE #\r\n.f1o ODD-FOOT PAGE #\r\n")
    for i in 1...120 {
        src += bytes(String(format: "LINE %03d ", i) + String(repeating: "-", count: 40))
        src += HARD
    }
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    let texts = pages.enumerated().map { (i, pg) in (i + 1, pg.footerLines?.first?.text) }
    #expect(texts.map(\.1) == ["ODD-FOOT PAGE 1", "EVEN-FOOT PAGE 2", "ODD-FOOT PAGE 3"])
    #expect(doc.footers == [1: "ODD-FOOT PAGE #"])
}

@Test func headFootParityH1eH1oCarryTheirOwnFontAndTab() {
    // GALLEYS.DOT/ADVANCE.DOT's own real-corpus shape: `.h1e`/`.h1o` each open with a
    // DIFFERENT font-change block AND a different right-align tab -- `doc.
    // headerFontsParity`/`headerTabsParity` (planning #250) keep them separate per
    // parity, not folded to a single flat value the way `doc.headerFonts`/`headerTabs`
    // (pre-existing, single most-recent-wins) already are for every OTHER header line.
    let doc = parseWS(hfParityDoc())
    #expect(doc.headerFontsParity[1] == [:])
    #expect(doc.headerTabsParity[1] == [:])
    // Both parities present and independently addressable: `headersParity` itself
    // (unlike the font/tab dicts, which stay empty when neither line carries a
    // font/tab mark of its own) DOES carry both keys -- the SHAPE (a dict keyed by
    // parity, not a single flat scalar) is what this test pins; a font/tab-bearing
    // fixture is impractical to construct by hand at this layer (the binary type-2
    // Font block/type-9 tab sequence), so the real-corpus documents (GALLEYS.DOT/
    // ADVANCE.DOT, via `AnswerKeyParityTests`/the PCL-fidelity tier) are what a real
    // font/tab divergence would be caught by.
    #expect(Set(doc.headersParity[1]?.keys ?? [:].keys) == [.even, .odd])
}
