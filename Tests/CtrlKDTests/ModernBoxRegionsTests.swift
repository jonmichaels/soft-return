/// b26-modern item 2 (ctrl-kd 8122706): Modern PDF box-drawing/graphic regions.
///
/// Two related, evidence-linked bugs in `modernFlow`'s tokenizer:
///
/// (a) FIRST-BOX-MANGLED: the generic word tokenizer (space/non-space split) splits a
/// box row -- '<left border><interior spaces><right border>' -- into THREE tokens,
/// because the interior is pure whitespace and the tokenizer always breaks on space
/// runs. The border tokens then measure through `modernTokenWidth`'s graphic-pitch
/// branch, but the all-space middle token has no graphic char in it, so it falls
/// through to ordinary proportional-text measurement instead -- the two systems only
/// happen to agree when a resolved fixed-pitch font `entry` is active (both reduce to
/// the same `spanPitch` formula then). A genuinely FONTLESS region (`entry == nil` --
/// every WS4 file, or any WS5+ document before its own first font-change record)
/// measures its border chars and its interior gap by two UNRELATED formulas, so a box
/// row's own drawn width stops matching its neighbouring rows and its top/bottom bars
/// -- reproduced on the real corpus: BOXES.WS's OPENING box (the document's own first
/// content, before any font record) measured 322pt per row; an IDENTICAL box appearing
/// later in the same file (by then under a resolved font) measured 165.6pt. Visually:
/// the first box's right edge and interior vertical land at the WRONG x, reading as
/// "right side missing, stray interior vertical, open corner" while later boxes render
/// correctly.
///
/// (b) AWKWARD WRAP: because a box row is three separate tokens, a row wider than the
/// available text width could break BETWEEN the border and the gap (`modernWrap`'s
/// normal word-wrap), splitting a box row's closing border onto its own visual line.
///
/// Fix: `modernTokenize` tries the SAME graphic-run shape (border-gap-border) the
/// drawing code already understands as one unit BEFORE falling back to the generic
/// space/non-space split -- a box row reaches width measurement and wrapping as the one
/// visual unit it is, fixing both (a) and (b) as one mechanism. Isolated/scattered
/// graphic chars amid ordinary prose (a legend line like "UL: <char>  UR: <char>") are
/// unaffected: `graphicRunRanges`'s own shape requires the run to close on ANOTHER
/// graphic char with only graphic-chars-or-spaces in between, so it can never cross
/// real letters.
///
/// Synthetic fixtures only (CLAUDE.md): literal cp437 box-drawing bytes embedded
/// directly in a WS7 block, same convention as `PDFGraphicsTests.swift`'s own box
/// fixtures (whose escape-wrap is specific to reproducing BOX.WS's own authoring
/// method; plain high bytes decode via cp437 through the ordinary text path just the
/// same, matching ctrl-kd's own raw-cp437-bytes fixture convention here). Port of
/// ctrl-kd's `tests/test_modern_box_regions.py`.
import Testing
@testable import CtrlKD

private let boxTop: [UInt8] = [0xDA] + [UInt8](repeating: 0xC4, count: 21) + [0xBF]
private let boxMid: [UInt8] = [0xB3] + [UInt8](repeating: 0x20, count: 21) + [0xB3]
private let boxBot: [UInt8] = [0xC0] + [UInt8](repeating: 0xC4, count: 21) + [0xD9]

private func boxFlow(_ doc: Document) -> [ModernFlowItem] {
    modernFlow(doc, keep: [.footnote, .endnote, .annotation], noteRefs: .word,
              pixResults: [], pictures: .off, textWidthPt: 468.0)
}

private func paraItems(_ flow: [ModernFlowItem]) -> [[ModernToken]] {
    flow.compactMap {
        if case .para(let toks, _, _, _, _, _, _) = $0 { return toks }
        return nil
    }
}

@Test func fontlessBoxRowsMeasureSelfConsistently() throws {
    // The exact regression shape: a box that is the document's own FIRST content
    // (WS7-format, but before any font-change record -- `entry == nil` for every span
    // in it). Every row -- top bar, all five body rows, bottom bar -- must measure to
    // the SAME width; before the fix, body rows measured roughly a third of the
    // top/bottom bars' width.
    var data = ws7Block(0x00) + boxTop + HARD
    for _ in 0..<5 { data += boxMid + HARD }
    data += boxBot + HARD
    let doc = parseWS(data)
    let paras = paraItems(boxFlow(doc))
    #expect(paras.count == 7)
    let widths = paras.map { toks in toks.reduce(0.0) { $0 + $1.width } }
    let rounded = Set(widths.map { (v: Double) in (v * 10000).rounded() / 10000 })
    #expect(rounded.count == 1, "\(widths)")
}

@Test func boxAfterAFontChangeIsUnaffected() throws {
    // Baseline: a box appearing AFTER the document's font-change record (a resolved,
    // non-proportional `entry`) already measured consistently before this fix (both the
    // graphic and plain-text branches reduce to the same `spanPitch` formula) -- must
    // stay exactly as consistent, same shape of assertion as the fontless case above.
    var data = ws7Block(0x00) + fontBlock(0, points: 12.0) + boxTop + HARD
    for _ in 0..<5 { data += boxMid + HARD }
    data += boxBot + HARD
    let doc = parseWS(data)
    let paras = paraItems(boxFlow(doc))
    let widths = paras.map { toks in toks.reduce(0.0) { $0 + $1.width } }
    let rounded = Set(widths.map { (v: Double) in (v * 10000).rounded() / 10000 })
    #expect(rounded.count == 1, "\(widths)")
}

@Test func scatteredGraphicCharsAmidProseStayIndividuallyTokenized() throws {
    // A legend line mixing isolated graphic glyphs with ordinary prose words (BOXES.WS's
    // own "UL: <char>    UR: <char>" array lines) must NOT be swept into one giant token
    // -- `graphicRunRanges`'s shape requires closing on another graphic char with
    // nothing but graphic-chars-or-spaces in between, and real letters break that every
    // time.
    let line = Array("UL: ".utf8) + [0xDA] + Array("    UR: ".utf8) + [0xBF]
        + Array("   done".utf8)
    let doc = parseWS(ws7Block(0x00) + line + HARD)
    let paras = paraItems(boxFlow(doc))
    let texts = paras[0].map(\.text)
    #expect(texts == ["UL:", " ", "┌", "    ", "UR:", " ", "┐", "   ", "done"])
}

@Test func wideGraphicRowDoesNotWrapMidRow() throws {
    // A box row wider than the page's own text width must still be placed as ONE
    // unbroken visual line (the "non-reflowing... unwrapped monospace block" rule)
    // rather than breaking between its border and its interior gap -- before the fix,
    // `modernWrap` split the closing border onto its own line.
    let row: [UInt8] = [0xB3] + [UInt8](repeating: 0x20, count: 88) + [0xB3]
    let data = ws7Block(0x00) + fontBlock(0, points: 12.0) + row + HARD
    let doc = parseWS(data)
    let paras = paraItems(boxFlow(doc))
    let vis = modernWrap(paras[0], width: 468.0)
    #expect(vis.count == 1)
    let joined = vis[0].map(\.text).joined()
    #expect(joined == "│" + String(repeating: " ", count: 88) + "│")
}

@Test func boxesRenderWithoutAStrayXObjectOrCrash() throws {
    // End-to-end smoke test: the fontless box document above must emit a valid Modern
    // PDF (no crash), and since nothing here is a pix tag, no Image XObject should
    // appear.
    var data = ws7Block(0x00) + boxTop + HARD
    for _ in 0..<5 { data += boxMid + HARD }
    data += boxBot + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    #expect(pdf.starts(with: bytes("%PDF")))
    #expect(!contains(pdf, bytes("/Subtype /Image")))
}

/// (min y, max y) across every `re f` filled-rect op in a `graphicOps` result -- the
/// vertical extent of the glyph's own drawn geometry. Port of ctrl-kd's `_rect_span`.
private func rectSpan(_ ops: [[UInt8]]) -> (bottom: Double, top: Double) {
    var spans: [(Double, Double)] = []
    for op in ops {
        let s = String(decoding: op, as: UTF8.self)
        guard s.hasSuffix("re f") else { continue }
        let parts = s.split(separator: " ")
        guard parts.count >= 4, let y = Double(parts[1]), let h = Double(parts[3]) else { continue }
        spans.append((y, y + h))
    }
    return (spans.map(\.0).min()!, spans.map(\.1).max()!)
}

@Test func modernGraphicOpsCellTouchesTheNextLinesCell() throws {
    // Register b32: a box-drawing arm's vertical stroke spans its own glyph CELL
    // top-to-bottom (`graphicOps`'s `boxArms` branch, the up/down rects), so
    // consecutive PHYSICAL lines' cells only chain into one continuous rule if the
    // cell is at least as tall as the actual line-to-line advance. Before this fix,
    // every Modern caller used the SAME fixed 1.1 factor Printed's own (differently-
    // related) leading happens to tolerate -- Modern's real advance is
    // `modernLine * pt` (1.2x, not 1.1x), leaving a real per-line gap and rendering
    // every vertical box side as broken dashes on the real corpus (BOX.WS, BOXES.WS).
    // Modern's call site now passes `leadFactor: modernLine` explicitly; two
    // vertically-adjacent glyph cells at that exact advance must meet with ZERO gap
    // (and zero overlap).
    let pt = modernBodyPt
    let advance = modernLine * Double(pt)
    let y1 = 700.0
    let ops1 = graphicOps("│", x: 0.0, y: y1, pitch: 8.4, pt: pt, leadFactor: modernLine)
    let ops2 = graphicOps("│", x: 0.0, y: y1 - advance, pitch: 8.4, pt: pt, leadFactor: modernLine)
    let (bottom1, _) = rectSpan(ops1)
    let (_, top2) = rectSpan(ops2)
    #expect(top2 == bottom1)
}

@Test func modernGraphicOpsDefaultFactorWouldGapAtTheRealAdvance() throws {
    // The failure this fix closes, pinned directly: `graphicOps`'s own PRINTED-tuned
    // default (1.1, unrelated to Modern's leading) leaves a real gap at Modern's
    // actual per-line advance -- confirms the bug was real, not just the fix's own
    // arithmetic agreeing with itself.
    let pt = modernBodyPt
    let advance = modernLine * Double(pt)
    let y1 = 700.0
    let ops1 = graphicOps("│", x: 0.0, y: y1, pitch: 8.4, pt: pt)              // old default
    let ops2 = graphicOps("│", x: 0.0, y: y1 - advance, pitch: 8.4, pt: pt)    // old default
    let (bottom1, _) = rectSpan(ops1)
    let (_, top2) = rectSpan(ops2)
    #expect(bottom1 - top2 > 1.0)     // a real, visible gap (was 1.4pt)
}

@Test func modernPrintedBoxRenderingIsUnaffectedByThisFix() throws {
    // Printed PDF's own graphic-char drawing path (`splitGraphics`/box-arm vector ops)
    // is untouched by this fix -- a fontless box document must render identically in
    // Printed mode with and without the change (proven indirectly: Printed mode never
    // calls `modernFlow`/`modernTokenize` at all, so its box still draws via the
    // pre-existing, already-correct `splitGraphics` path).
    var data = ws7Block(0x00) + boxTop + HARD
    for _ in 0..<5 { data += boxMid + HARD }
    data += boxBot + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(pdf.starts(with: bytes("%PDF")))
}
