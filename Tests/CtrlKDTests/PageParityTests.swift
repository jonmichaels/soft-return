import Testing
@testable import CtrlKD

/// Planning #231: `.poe`/`.poo` even/odd page offset in Printed mode — Swift port of
/// ctrl-kd's `tests/test_page_parity.py`, same 5 synthetic byte-exact cases.
///
/// WSFORMAT.WS: ".PO can optionally specify even or odd number page offsets" —
/// `.poe`/`.poo` are real, distinct 3-letter dot commands, but nothing in this engine's
/// pagination model tracked a page's own odd/even PARITY, so they parsed as ordinary
/// unrecognized dot commands. Brief's own rule: "odd pages use .poo (or .po), even
/// pages .poe (or .po)."
///
/// Implementation mirrors ctrl-kd's own two new axes:
///
///   1. `Formatting2.swift`/`Line.swift`: `.poe`/`.poo` are independently STATEFUL
///      (same family as `.po`), carried per line as `Line.poeCols`/`pooCols`.
///   2. `PDFLayout.swift`: `resolvePlainBody`/`resolvePrintedBody` record a candidate
///      `ParityLeft(even:odd:)` pair on `PageLine.parityLeft` for any line `.poe`/
///      `.poo` governs; `layoutPrintedPagesPlain`'s own `closePage` — the one place
///      that knows a page's own number once it closes — resolves the pair. The same
///      parity feeds `Page.poCols` (header/footer LEFT edge) via new
///      `poeOrPooCheckpoints`/`leftForParity`.
///
/// A document that never uses `.poe`/`.poo` costs nothing — every new field stays
/// `nil` throughout, `parityLeft` is never set, `leftForParity` always falls back to
/// the ordinary `.po` resolution.

private func pdfWordX(_ stream: [UInt8], _ word: String) -> Double? {
    let needle = "(\(word)) Tj"
    for line in latin1(stream).split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: needle) else { continue }
        let prefix = line[line.startIndex..<r.lowerBound]
        guard prefix.hasSuffix("Td ") else { continue }
        let fields = prefix.dropLast(3).split(separator: " ")
        guard fields.count >= 2 else { continue }
        return Double(fields[fields.count - 2])
    }
    return nil
}

private func parityDoc(_ src: [UInt8]) -> Document {
    parseWS(src)
}

@Test func poePooParsedAndCarriedStatefulPerLine() throws {
    let doc = parityDoc(bytes(".poe 1\"\r\n.poo 2\"\r\nAA") + HARD
        + bytes(".po 3\"\r\nBB") + HARD)
    let b = doc.blocks[0]
    #expect(b.lines[0].poeCols == 10.0)   // 1in = 10 print columns
    #expect(b.lines[0].pooCols == 20.0)   // 2in = 20 print columns
    // `.po` afterward does not clear the parity overrides -- independently stateful,
    // same family as every other dot command here (module doc comment point 1; no
    // corpus evidence either way, conservative reading stands).
    #expect(b.lines[1].poeCols == 10.0)
    #expect(b.lines[1].pooCols == 20.0)
    #expect(b.lines[1].poCols == 30.0)
}

@Test func poePooAcceptWordStarArithmetic() throws {
    // WS4.0+'s own documented dot-command math -- the one real corpus document that
    // depends on `.poe`/`.poo` (sawyer/REF/-HOW-TO.RJS) writes both as arithmetic
    // expressions, never a bare number: `.poe 0.50-0.20"`, `.poo 0.50+4.50+1.00-0.20"`.
    let doc = parityDoc(bytes(".poe 0.50-0.20\"\r\n.poo 0.50+4.50+1.00-0.20\"\r\nAA") + HARD)
    let b = doc.blocks[0]
    #expect(b.lines[0].poeCols == 3.0)     // 0.30in = 3 cols
    #expect(b.lines[0].pooCols == 58.0)    // 5.80in = 58 cols
}

@Test func oddPagesUsePooEvenPagesUsePoe() throws {
    // Brief's own rule: odd pages use `.poo`, even pages use `.poe`. Three forced
    // (`.pa`) one-line pages -- page 1 odd, page 2 even, page 3 odd again -- confirms
    // the alternation, not just a single override.
    let doc = parityDoc(bytes(".po 0\"\r\n.poe 1\"\r\n.poo 2\"\r\n")
        + bytes("PAGE1") + HARD + bytes(".pa\r\n")
        + bytes("PAGE2") + HARD + bytes(".pa\r\n")
        + bytes("PAGE3") + HARD)
    let out = emitPDF(doc, mode: .printed)
    let streams = pdfContentStreams(out)
    #expect(streams.count == 3)
    #expect(pdfWordX(streams[0], "PAGE1") == 144.0)   // odd -> .poo (2in)
    #expect(pdfWordX(streams[1], "PAGE2") == 72.0)    // even -> .poe (1in)
    #expect(pdfWordX(streams[2], "PAGE3") == 144.0)   // odd -> .poo again
}

@Test func poeOrPooAloneFallsBackToPoForTheOtherParity() throws {
    // Brief's own rule, parenthetical: "odd pages use .poo (OR .po), even pages .poe
    // (or .po)" -- only `.poe` set here, so ODD pages (never overridden) fall back to
    // the plain `.po` in force, not WordStar's hardcoded 8-column default.
    let doc = parityDoc(bytes(".po 3\"\r\n.poe 1\"\r\n")
        + bytes("PAGE1") + HARD + bytes(".pa\r\n")
        + bytes("PAGE2") + HARD)
    let out = emitPDF(doc, mode: .printed)
    let streams = pdfContentStreams(out)
    #expect(pdfWordX(streams[0], "PAGE1") == 216.0)   // odd, no .poo -> .po (3in)
    #expect(pdfWordX(streams[1], "PAGE2") == 72.0)    // even -> .poe (1in)
}

@Test func documentWithoutPoePooIsUnaffected() throws {
    // A document that never uses `.poe`/`.poo` costs nothing -- every line's own
    // `parityLeft` stays `nil`, `closePage` never touches `.left`, byte-identical to
    // before this feature existed.
    let doc = parityDoc(bytes(".po 2\"\r\nPAGE1") + HARD + bytes(".pa\r\nPAGE2") + HARD)
    let out = emitPDF(doc, mode: .printed)
    let streams = pdfContentStreams(out)
    #expect(pdfWordX(streams[0], "PAGE1") == 144.0)
    #expect(pdfWordX(streams[1], "PAGE2") == 144.0)   // SAME on every page -- no
                                                       // alternation triggered
}
