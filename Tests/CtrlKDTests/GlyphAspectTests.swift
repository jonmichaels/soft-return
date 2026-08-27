import Testing
@testable import CtrlKD

/// b24 engine wave, round 20 item 4 (slate item 8) — mirrors ctrl-kd's
/// tests/test_glyph_aspect.py. Squashed cp437 vector glyphs in Printed PDF: every
/// symbol/bullet shape's fractional coordinates were scaled by `pitch` (x) and `h` (y)
/// INDEPENDENTLY -- a 12pt Courier cell is ~7.2pt wide but ~13.2pt tall, so a shape
/// authored to look REGULAR came out visibly non-square. Fixed via `sq = min(pitch, h)`,
/// every shape positioned relative to the cell center and scaled by `sq` on both axes --
/// a strict generalization that reduces to the exact prior formula when `pitch == h`.
/// Real-corpus-gated Python tests (CONVERT.WS/LJ6DTP.WS specific pins) are not ported --
/// no private corpus ships with this repo.

/// Every op array joined into one newline-separated string — this project's own
/// `graphicOps` returns `[[UInt8]]`, one PDF content-stream operator per element.
private func joinedOps(_ ops: [[UInt8]]) -> String {
    ops.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
}

/// `[(x, y, w, h)]` from every `X Y W H re f` fill-rect op in the stream.
private func rectOps(_ ops: String) -> [(x: Double, y: Double, w: Double, h: Double)] {
    var out: [(Double, Double, Double, Double)] = []
    for line in ops.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count == 6, parts[4] == "re", parts[5] == "f",
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]) else { continue }
        out.append((x, y, w, h))
    }
    return out
}

/// Bounding box `(w, h)` of the FIRST closed path in a run of PDF path ops — only
/// lines shaped like `x y m`/`x y l`/`x1 y1 x2 y2 x3 y3 c` are point data (stops at the
/// first standalone `f` line, a disc's own closing fill — excludes any later sub-shape,
/// and never matches a rect's `re f` or a poly's `h f`, both multi-token). Good enough
/// for a disc/poly's own extent without a real curve-flattening implementation (a
/// circle Bezier's control points lie on or very near its true bounding box).
private func curveBBox(_ ops: String) -> (w: Double, h: Double)? {
    let lines = ops.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var firstFillIdx = lines.count
    for (i, line) in lines.enumerated() where line == "f" {
        firstFillIdx = i
        break
    }
    var xs: [Double] = []
    var ys: [Double] = []
    for line in lines[0..<firstFillIdx] {
        let parts = line.split(separator: " ").map(String.init)
        guard let last = parts.last, last == "m" || last == "l" || last == "c" else { continue }
        let nums = parts.dropLast().compactMap { Double($0) }
        for (i, v) in nums.enumerated() {
            if i % 2 == 0 { xs.append(v) } else { ys.append(v) }
        }
    }
    guard let xmin = xs.min(), let xmax = xs.max(), let ymin = ys.min(), let ymax = ys.max()
    else { return nil }
    return (xmax - xmin, ymax - ymin)
}

@Test func squarePartBlockBulletIsSquareOnANonSquareCell() throws {
    let ops = joinedOps(graphicOps("\u{25A0}", x: 0.0, y: 100.0, pitch: 7.2, pt: 12))
    let rects = rectOps(ops)
    #expect(rects.count == 1)
    let (_, _, w, h) = try #require(rects.first)
    #expect(abs(w - h) < 0.05, "\(w) vs \(h)")
}

@Test func partBlockHalfBlocksStayCellShapedNotForcedSquare() throws {
    // ▀▄▌▐ are genuinely meant to fill actual (non-square) cell fractions -- the fix
    // must NOT touch them.
    let cases: [(Character, (w: Double, h: Double))] = [
        ("\u{2580}", (7.2, 6.6)), ("\u{2584}", (7.2, 6.6)),
        ("\u{258C}", (3.6, 13.2)), ("\u{2590}", (3.6, 13.2)),
    ]
    for (ch, want) in cases {
        let ops = joinedOps(graphicOps(String(ch), x: 0.0, y: 100.0, pitch: 7.2, pt: 12))
        let (_, _, w, h) = try #require(rectOps(ops).first, "\(ch)")
        #expect(abs(w - want.w) < 0.05, "\(ch): w \(w) vs \(want.w)")
        #expect(abs(h - want.h) < 0.05, "\(ch): h \(h) vs \(want.h)")
    }
}

@Test func diamondSymbolIsRegularNotStretched() throws {
    let ops = joinedOps(graphicOps("\u{2666}", x: 0.0, y: 100.0, pitch: 7.2, pt: 12))
    let (w, h) = try #require(curveBBox(ops))
    #expect(abs(w - h) < 0.6, "\(w) vs \(h)")
}

@Test func discBasedSymbolsStayCircularOnANonSquareCell() throws {
    // disc() already used min(pitch, h) for its radius before this round -- this is a
    // non-regression pin, not a new fix.
    for ch: Character in ["\u{263B}", "\u{2665}", "\u{2663}", "\u{2660}", "\u{263C}"] {
        let ops = joinedOps(graphicOps(String(ch), x: 0.0, y: 100.0, pitch: 7.2, pt: 12))
        let (w, h) = try #require(curveBBox(ops), "\(ch)")
        #expect(abs(w - h) < 0.9, "\(ch): \(w) vs \(h)")
    }
}

@Test func squareCellReproducesThePriorFormulaExactly() throws {
    // When pitch == h the new cell-center-relative math must reduce algebraically to
    // the old `x0 + fx*pitch, yb + fy*h` formula -- the fix is a strict
    // generalization, not a behavior change for the square-cell case.
    // `pt: Int` (this port's own `graphicOps` signature) picks pt=10 -> h = 1.1*10 =
    // 11.0, matched exactly by pitch=11.0; tolerance covers the ops' own one-decimal
    // coordinate formatting, not a real precision claim.
    let ops = joinedOps(graphicOps("\u{25A0}", x: 0.0, y: 100.0, pitch: 11.0, pt: 10))
    let (x, _, w, h) = try #require(rectOps(ops).first)
    let frac = try #require(partBlocks["\u{25A0}"])
    #expect(abs(x - frac.x * 11.0) < 0.2)
    #expect(abs(w - frac.w * 11.0) < 0.2)
    #expect(abs(h - frac.h * 11.0) < 0.2)
}

@Test func convertWSBulletSquareEndToEnd() throws {
    // CONVERT.WS's own '■' bullet, through the real parse+emit pipeline (not a
    // synthetic graphicOps call) -- the exact document the round-20 brief named.
    let font = ws7Block(0x02, payload: le16(240) + le16(480) + le16(0) + [UInt8](repeating: 0, count: 6))
    let data = font + [0x1B, 0xFE, 0x1C] + bytes(" bullet line\r\n")
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed)
    let rects = rectOps(latin1(out))
    #expect(!rects.isEmpty, "no vector rect ops found")
    let (_, _, w, h) = try #require(rects.first)
    #expect(abs(w - h) < 0.15, "\(w) vs \(h)")
}
