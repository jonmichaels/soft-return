import Testing
@testable import CtrlKD

/// Planning #271 M7 (Jon's ruling 2026-09-13: "-HOLYMAC.WS is VERY slow to open").
/// The second of two perf changes in the `layout` path, both byte-identical:
/// `stringWidth1000` and `symbolFallbackSplit` stopped allocating per call --
/// a `[UInt8]` of the cp1252 bytes and a `[Character]` of the whole token,
/// respectively, on paths a novel-length document walks ~140,000 times per Modern
/// pass. These check the rewrites answer exactly what they always answered.
/// Twin of ctrl-kd's `tests/test_width_and_cp1252_memo.py` (which memoizes instead,
/// because Python's own cost there is the raised-and-caught `UnicodeEncodeError`).

@Test func stringWidthIsTheWidthItAlwaysWas() {
    // The pre-change body was `for byte in cp1252Encode(text) { total += table[byte] }`.
    // Same answer, computed without the array.
    for (text, font) in [("Chapter One", "Times-Roman"),
                         ("Chapter One", "Helvetica-Bold"),
                         ("", "Times-Roman"),
                         (" ", "Courier"),
                         ("fi\u{2014}\u{2019}", "Times-Italic"),
                         ("\u{0398}\u{03A9}", "Symbol")] {
        let table = afmWidths[font] ?? afmWidths["Courier"]!
        var expected = 0
        for byte in cp1252Encode(text) { expected += table[Int(byte)] }
        #expect(stringWidth1000(text, font) == expected)
    }
}

@Test func aCharacterOutsideCP1252StillMeasuresAsAQuestionMark() {
    // `cp1252Encode` substitutes 0x3F; the inlined walk must too.
    let table = afmWidths["Times-Roman"]!
    #expect(stringWidth1000("\u{2500}", "Times-Roman") == table[0x3F])
}

@Test func anUnknownFaceStillFallsBackToCourier() {
    #expect(stringWidth1000("abc", "No-Such-Face") == stringWidth1000("abc", "Courier"))
}

@Test func theFallbackSplitFastPathAnswersWhatItAlwaysAnswered() {
    // Fast path: nothing needs a fallback face, one piece back, text unchanged.
    let plain = symbolFallbackSplit("Chapter One", family: .times)
    #expect(plain.count == 1)
    #expect(plain[0].text == "Chapter One")
    // A graphic character is the fast path too -- splitGraphics owns those.
    let rule = symbolFallbackSplit("\u{2550}\u{2550}", family: .times)
    #expect(rule.count == 1)
    #expect(rule[0].text == "\u{2550}\u{2550}")
    // The empty string: one piece, unchanged.
    #expect(symbolFallbackSplit("", family: .times).count == 1)
    // And the slow path still peels a Greek run onto Symbol.
    let mixed = symbolFallbackSplit("a\u{0398}b", family: .times)
    #expect(mixed.count == 3)
    #expect(mixed[0].family == .times)
    #expect(mixed[1].family == .symbol)
    #expect(mixed[2].family == .times)
}
