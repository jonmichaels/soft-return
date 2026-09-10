import Testing
@testable import CtrlKD

/// planning #251 follow-up (2026-09-10, app coder job 348): `graphicCellOps` exports
/// drawing-grade geometry (`PDFDriverLJ6DTP.swift`'s own doc comment on that function has
/// the full derivation) so a consumer stops reconstructing an arcCorner join from
/// `graphicCellRects`' two bounding rects -- the change that turned LJ6DTP.WS page 3's
/// real 35 vector ops into the app's own 51. This file is the promised proof: for every
/// arcCorner character, `graphicCellOps`' `.strokePath` replays into the EXACT same raw
/// PDF operator KIND sequence (w, m, l, c, l, S) the engine's own `graphicOps` emits for
/// that character -- count and kind, not just visual similarity.

/// Every op array joined into one newline-separated string, same convention
/// `GlyphAspectTests.swift`'s own `joinedOps` uses.
private func joinedOps(_ ops: [[UInt8]]) -> String {
    ops.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
}

/// The trailing PDF operator token(s) of one `graphicOps` op string -- "w"/"m"/"l"/"c"/"S"
/// are single trailing tokens; a filled rect ("X Y W H re f") and a filled poly's closing
/// segment ("X Y l" ... "h f") are the two-token exceptions, folded to "re f"/"h f" so a
/// caller can tell them apart from a bare "f" (a disc's own closing fill).
private func opKind(_ line: Substring) -> String {
    let parts = line.split(separator: " ")
    guard let last = parts.last else { return "" }
    if last == "f", parts.count >= 2 {
        let prev = parts[parts.count - 2]
        if prev == "re" { return "re f" }
        if prev == "h" { return "h f" }
    }
    return String(last)
}

private func opKinds(_ ops: String) -> [String] {
    ops.split(separator: "\n").map(opKind)
}

/// `graphicCellOps`' own `.strokePath` segments, replayed into the same op-kind vocabulary
/// `opKinds` extracts from a real `graphicOps` stream: a leading state-set ("w"), then one
/// token per `PathSegment` case (`moveTo` -> "m", `lineTo` -> "l", `curveTo` -> "c"), and a
/// trailing "S" (stroke) -- exactly the shape `graphicOps`' own arcCorners branch writes.
private func replayedKinds(_ ops: [GraphicCellOp]) -> [String] {
    var out: [String] = []
    for op in ops {
        guard case .strokePath(let segments, _) = op else { continue }
        out.append("w")
        for seg in segments {
            switch seg {
            case .moveTo: out.append("m")
            case .lineTo: out.append("l")
            case .curveTo: out.append("c")
            }
        }
        out.append("S")
    }
    return out
}

@Test func arcCornersOpsMatchEngineOpKindSequenceExactly() {
    // A concrete, arbitrary pitch/pt -- op KIND never depends on either (only the
    // magnitudes embedded in each token do), so any value proves the same thing.
    for (char, _) in arcCorners {
        let real = joinedOps(graphicOps(String(char), x: 0.0, y: 100.0, pitch: 12.0, pt: 12))
        let realKinds = opKinds(real)
        let mine = graphicCellOps(char)
        #expect(mine.count == 1, "expected exactly one op for arcCorner \(char)")
        let mineKinds = replayedKinds(mine)
        #expect(mineKinds == realKinds,
               "arcCorner \(char): op kinds \(mineKinds) != engine's own \(realKinds)")
        // The engine's own real sequence is exactly six tokens (w, m, l, c, l, S) -- pin
        // it directly so a future change to `graphicOps`' arcCorners branch that silently
        // adds/removes a step fails HERE too, not only against `graphicCellOps`' own copy.
        #expect(realKinds == ["w", "m", "l", "c", "l", "S"])
    }
}

/// The same op-KIND parity, for the five table-driven categories `graphicCellOps` already
/// shared 1:1 with `graphicCellRects` (rect-for-rect) before this round -- confirms the new
/// function didn't regress what already worked while adding arcCorners' fix.
@Test func boxArmsOpsMatchEngineFillRectCount() {
    for (char, arms) in boxArms {
        let real = joinedOps(graphicOps(String(char), x: 0.0, y: 100.0, pitch: 12.0, pt: 12))
        let realRectCount = real.split(separator: "\n").filter { $0.hasSuffix(" re f") }.count
        let mine = graphicCellOps(char)
        #expect(mine.count == realRectCount,
               "boxArms \(char) (\(arms)): \(mine.count) ops vs engine's \(realRectCount) rects")
        #expect(mine.allSatisfy {
            if case .fillRect(_, _, _, _, let gray) = $0 { return gray == nil }
            return false
        })
    }
}

@Test func fullBlockAndShadeGrayOpsAreOneFillRectEach() {
    #expect(graphicCellOps(fullBlock) == [.fillRect(x: 0, y: 0, w: 1, h: 1, gray: nil)])
    for (char, gray) in shadeGray {
        #expect(graphicCellOps(char) == [.fillRect(x: 0, y: 0, w: 1, h: 1, gray: gray)])
    }
}

@Test func symbolShapesOpsSkipWhiteKnockoutsSameAsRects() {
    for (char, shapes) in symbolShapes {
        let positiveCount = shapes.filter {
            if case .white = $0 { return false }
            return true
        }.count
        #expect(graphicCellOps(char).count == positiveCount)
    }
}

@Test func nonGraphicCharacterHasNoOps() {
    #expect(graphicCellOps("A").isEmpty)
    #expect(graphicCellOps(" ").isEmpty)
}
