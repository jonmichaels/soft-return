import Testing
@testable import CtrlKD

/// b24 engine wave, round 20 item 2 (slate item 4) — mirrors ctrl-kd's
/// tests/test_verse_spacing.py. Verse-classified units and wrapped centered units get
/// tighter internal line spacing in Modern outputs than the surrounding prose's own
/// (looser) default -- HTML `line-height` on the unit's own `<p>`, RTF `\sl`/
/// `\slmult0` within. These tests pin the MECHANISM (the right units get tighter
/// spacing, the right units don't, resets happen cleanly), not the exact 1.15 number
/// (Jon's own framing: "single-spaced default BUT parameterize it").

@Test func htmlVerseUnitGetsTightLineHeight() throws {
    let poem = bytes("     line one --") + SOFT + bytes("     line two --") + HARD
    let html = emitHTML(parseWS(poem), mode: .modern)
    #expect(html.contains("line-height:\(verseLineHeight)"))
    #expect(html.contains("<br>"))
}

@Test func htmlOrdinaryProseIsUnaffected() throws {
    let data = bytes("An ordinary sentence that ends with terminal punctuation.\r\n")
    let html = emitHTML(parseWS(data), mode: .modern)
    #expect(!html.contains("line-height:"))
}

@Test func htmlCenteredUnitGetsTightLineHeight() throws {
    let title = "A Centered Title"
    let pad = (65 - title.count) / 2
    let data = bytes(String(repeating: " ", count: pad) + title) + HARD
    let html = emitHTML(parseWS(data), mode: .modern)
    #expect(html.contains("text-align:center;line-height:\(verseLineHeight)"))
}

@Test func htmlDotCommandCenteredParagraphGetsTightLineHeightButNotItsNeighbour() throws {
    let data = bytes(".oc on\r\nCentred.\r\n.oc off\r\nOrdinary.\r\n")
    // Four hard returns, no soft ones -- detect() would otherwise read this as a
    // `printstream` (txt>=90 && hard>=2) and force printed rendering regardless of the
    // requested mode (D5 override). Force ws4 classification directly, mirroring
    // Python's own `_modern()` test helper (`doc.meta['variant'] = 'ws4'`).
    var doc = parseWS(data)
    doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 4,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: data.count)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("text-align:center;line-height:\(verseLineHeight)"))
    // the ordinary paragraph right after must NOT inherit it -- find ITS OWN <p ...>
    // opening tag specifically, not the preceding one's.
    guard let idx = html.range(of: "Ordinary.") else {
        Issue.record("fixture text not found")
        return
    }
    let before = html[html.startIndex..<idx.lowerBound]
    guard let tagStart = before.range(of: "<p", options: .backwards) else {
        Issue.record("no <p opening tag found before Ordinary.")
        return
    }
    #expect(!html[tagStart.lowerBound..<idx.lowerBound].contains("line-height"))
}

@Test func rtfVerseUnitGetsPositiveSl() throws {
    let poem = bytes("     line one --") + SOFT + bytes("     line two --") + HARD
    let rtf = emitRTF(parseWS(poem), mode: .modern)
    #expect(rtf.contains(#"\sl"#))
    let value = try #require(firstSlValue(rtf), "\(rtf)")
    #expect(value > 0, "Modern verse spacing must be a MINIMUM (positive), not EXACT")
}

@Test func rtfResetsSlToZeroAfterAVerseUnit() throws {
    let data = bytes("     line one --") + SOFT + bytes("     line two --") + HARD + HARD
        + bytes("Ordinary prose paragraph right after the verse.") + HARD
    // Three hard returns against one soft: same printstream-misdetection risk as
    // above -- force ws4 classification directly.
    var doc = parseWS(data)
    doc.detection = Detection(variant: .ws4, softReturns: 1, hardReturns: 3,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: data.count)
    let rtf = emitRTF(doc, mode: .modern)
    let values = allSlValues(rtf)
    #expect((values.first ?? 0) > 0)
    #expect(values.last == 0, "the ordinary paragraph after verse must reset \\sl to 0")
}

@Test func rtfOrdinaryProseNeverGetsSl() throws {
    let data = bytes("An ordinary sentence that ends with terminal punctuation.\r\n")
    let rtf = emitRTF(parseWS(data), mode: .modern)
    #expect(!rtf.contains(#"\sl"#))
}

/// b24 completion (C1): `modernSemanticFlow`'s own `isVerse` per-line flag — the shared
/// verdict a measuring consumer (the app's Modern views) reads instead of re-deriving
/// paragraph units itself. Same fixtures as the RTF/HTML mechanism tests above, so a
/// flag flip here pins the SAME classification, not an independently-invented one.
private func flowParaIsVerseFlags(_ doc: Document) -> [Bool] {
    modernSemanticFlow(doc).items.compactMap { item in
        if case .para(_, _, _, _, _, _, let isVerse, _) = item { return isVerse }
        return nil
    }
}

@Test func modernFlowLeftAlignedVerseUnitIsFlaggedIsVerse() throws {
    let poem = bytes("     line one --") + SOFT + bytes("     line two --") + HARD
    let flags = flowParaIsVerseFlags(parseWS(poem))
    #expect(flags.contains(true), "\(flags)")
}

@Test func modernFlowOrdinaryProseIsNotFlaggedIsVerse() throws {
    let data = bytes("An ordinary sentence that ends with terminal punctuation.\r\n")
    let flags = flowParaIsVerseFlags(parseWS(data))
    #expect(!flags.contains(true), "\(flags)")
}

@Test func modernFlowSingleLineCenteredUnitIsNotItselfFlaggedIsVerse() throws {
    // Regression guard for the centered path (job 371 item 5): a lone centered line is
    // `unit.count == 1`, so `isVerse` stays false here -- centered tightening comes from
    // `align == .center` at the render layer, unconditionally, same as `EmitRTF`'s own
    // `isVerse || block.align == .center`. This only pins that the NEW flag doesn't
    // misfire true and duplicate/contradict that existing mechanism.
    let title = "A Centered Title"
    let pad = (65 - title.count) / 2
    let data = bytes(String(repeating: " ", count: pad) + title) + HARD
    let flags = flowParaIsVerseFlags(parseWS(data))
    #expect(!flags.contains(true), "\(flags)")
}

@Test func printedRTFLineSpacingUnaffectedByTheModernVerseMechanism() throws {
    // round 6's own Printed .lh-derived \sl (rtfSlTwips, negative/EXACT) must stay
    // completely independent of the new Modern-only mechanism.
    let data = bytes(".lh 16\r\nSome printed text.\r\n")
    let rtf = emitRTF(parseWS(data), mode: .printed)
    let value = try #require(firstSlValue(rtf), "\(rtf)")
    #expect(value < 0, "Printed .lh spacing must stay EXACT (negative)")
}

/// The first `\slN\slmult0` value in `rtf`, Foundation-free (no NSRegularExpression).
private func firstSlValue(_ rtf: String) -> Int? {
    allSlValues(rtf).first
}

/// Every `\slN\slmult0` value in `rtf`, in order — a small hand-rolled scanner standing
/// in for Python's `re.finditer(r'\\sl(-?\d+)\\slmult0')`.
private func allSlValues(_ rtf: String) -> [Int] {
    var out: [Int] = []
    let marker = Array(#"\sl"#)
    let chars = Array(rtf)
    var i = 0
    while i + marker.count <= chars.count {
        if Array(chars[i..<(i + marker.count)]) == marker {
            var j = i + marker.count
            var numStr = ""
            if j < chars.count, chars[j] == "-" { numStr.append("-"); j += 1 }
            while j < chars.count, chars[j].isNumber { numStr.append(chars[j]); j += 1 }
            if !numStr.isEmpty, j + #"\slmult0"#.count <= chars.count,
               String(chars[j..<(j + 8)]) == #"\slmult0"#, let v = Int(numStr) {
                out.append(v)
                i = j + 8
                continue
            }
        }
        i += 1
    }
    return out
}
