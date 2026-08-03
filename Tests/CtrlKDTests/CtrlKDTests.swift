import Testing
@testable import CtrlKD

@Test func lineJoinsMultipleSpanTexts() {
    let line = Line(spans: [
        Span(text: "Hello, "),
        Span(text: "world", styles: [.bold]),
        Span(text: "!"),
    ])
    #expect(line.text() == "Hello, world!")
}

@Test func blockDefaultsToParaAndHeadingZero() {
    let block = Block()
    #expect(block.kind == .para)
    #expect(block.heading == 0)
}

// ------------------------------------------- Category C: formatting dot commands

@Test func ocCenteringIsStatefulAndStampsItsBlocks() {
    // C16. `.oc on`/`.oc off` bracket individual headings inside otherwise flush text —
    // 17 files in the WS7 archive do exactly this — so the state has to be stamped per
    // block, not resolved once per document the way page geometry is.
    let doc = parseWS(bytes("Normal.\r\n.oc on\r\nCentred heading\r\n.oc off\r\nNormal again.\r\n"))
    #expect(doc.blocks.map(\.align) == [.left, .center, .left])
}

@Test func ojTakesCAndRNotJustOnOff() {
    // C17. The manual leads with on/off; the archive really uses `.oj r` and `.oj c`.
    #expect(parseWS(bytes(".oj r\r\nText.\r\n")).blocks[0].align == .right)
    #expect(parseWS(bytes(".oj c\r\nText.\r\n")).blocks[0].align == .center)
    #expect(parseWS(bytes(".oj on\r\nText.\r\n")).blocks[0].align == .justify)
    #expect(parseWS(bytes(".oj off\r\nText.\r\n")).blocks[0].align == .left)
}

@Test func centeringWinsOverJustification() {
    // WordStar centres the line whatever the justification setting says — which is what
    // lets the archive's `.oc on`/`.oc off` pairs sit inside justified text.
    #expect(parseWS(bytes(".oj on\r\n.oc on\r\nCentred.\r\n")).blocks[0].align == .center)
}

@Test func awOffMarksABlockAsHandPlaced() {
    // C23. With word wrap off the author is positioning lines by hand, so a reflowing
    // consumer must not re-wrap them.
    #expect(parseWS(bytes(".aw off\r\nHand placed.\r\n")).blocks[0].wrap == false)
    #expect(parseWS(bytes("Ordinary.\r\n")).blocks[0].wrap == true)
}

@Test func prOrientationUsesTheSyntaxFilesActuallyUse() {
    // C18. `.pr or=l`, not a bare argument — 18 archive files set landscape this way,
    // and every one of them was rendering portrait with no diagnostic at all.
    #expect(parseWS(bytes(".pr or=l\r\nT.\r\n")).formatting.orientation == .landscape)
    #expect(parseWS(bytes(".pr or=p\r\nT.\r\n")).formatting.orientation == .portrait)
    // an unrelated `.pr` form must not invent an orientation
    #expect(parseWS(bytes(".pr profile-edit\r\nT.\r\n")).formatting.orientation == nil)
}

@Test func srRollReadsFractionsPointsAndBare48ths() {
    // C22. All four forms appear in the archive.
    func roll(_ arg: String) -> Double? {
        parseWS(bytes(".sr \(arg)\r\nT.\r\n")).formatting.subSuperRoll48
    }
    #expect(roll("3") == 3.0)                    // bare = 48ths, WordStar's own unit
    #expect(roll("3/48\"") == 3.0)
    #expect(roll("4/48i") == 4.0)
    #expect(roll("0") == 0.0)                    // a real value: do not shift at all
    #expect(abs((roll("6pt") ?? 0) - 4.0) < 1e-9)   // 6/72in = 4/48in
}

@Test func formattingRecordsOnlyWhatTheFileSet() {
    // Same provenance rule as the page geometry: a consumer must be able to tell "the
    // author asked for portrait" from "nobody said".
    #expect(parseWS(bytes("Just text.\r\n")).formatting.isEmpty)
    let f = parseWS(bytes(".ul on\r\n.ps off\r\n.kr on\r\n.sb on\r\nT.\r\n")).formatting
    #expect(f.underlineBlanks == true)
    #expect(f.proportional == false)
    #expect(f.kerning == true)
    #expect(f.suppressBlanks == true)
    #expect(f.orientation == nil)
}

@Test func alignmentActuallyRendersInEveryFormatThatCanShowIt() {
    // C16/C17 — the half that was missing. The dot commands were parsed and recorded and
    // then had no effect anywhere: a centred heading came out flush left in every format.
    var doc = parseWS(bytes(".oc on\r\nCentred.\r\n.oc off\r\n.oj on\r\nJustified body.\r\n"))
    doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 4,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: 60)

    let text = emitText(doc, mode: .modern)
    let centred = text.split(separator: "\n").first { $0.contains("Centred.") }
    #expect(centred?.hasPrefix(" ") == true, "centred line was not indented")
    #expect(centred.map { String($0).trimmed() } == "Centred.")

    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains(#"<p style="text-align:center">"#))
    #expect(html.contains(#"<p style="text-align:justify">"#))

    let rtf = emitRTF(doc, mode: .modern)
    #expect(rtf.contains(#"\qc "#))
    #expect(rtf.contains(#"\qj "#))
}

@Test func leftAlignedDocumentsAreByteIdenticalToBefore() {
    // WordStar's default is flush left, so a document that never touches `.oc`/`.oj`
    // must emit exactly what it always did — no stray attribute, no stray control.
    let doc = parseWS(bytes("Just ordinary text.\r\n"))
    #expect(!emitHTML(doc, mode: .modern).contains("text-align"))
    #expect(!emitRTF(doc, mode: .modern).contains(#"\qc"#))
    #expect(!emitRTF(doc, mode: .modern).contains(#"\ql"#))
}

@Test func marginsArePerBlockStateNotFirstOccurrence() {
    // C9. `.lm`/`.rm`/`.pm` are stateful, and emphatically not first-occurrence the way
    // page geometry is — one archive file sets `.pm` seven hundred times.
    let doc = parseWS(bytes(".lm 5\r\n.rm 60\r\nIndented.\r\n.pm 4\r\nPara margin.\r\n"))
    #expect(doc.blocks.map { [$0.leftMargin, $0.rightMargin, $0.paraMargin] }
            == [[5.0, 60.0, nil], [5.0, 60.0, 4.0]])
    // never set -> nil, so a consumer applies its own default rather than a fabricated one
    let plain = parseWS(bytes("Plain.\r\n")).blocks[0]
    #expect(plain.leftMargin == nil && plain.rightMargin == nil && plain.paraMargin == nil)
}

@Test func marginsAcceptColumnsAndInches() {
    // The archive writes both `.rm 65` and `.rm 6.5"`.
    #expect(parseWS(bytes(".rm 65\r\nT.\r\n")).blocks[0].rightMargin == 65.0)
    #expect(parseWS(bytes(".rm 6.5\"\r\nT.\r\n")).blocks[0].rightMargin == 65.0)
}

@Test func centeringMeasuresAgainstTheDocumentsOwnMargins() {
    // A centred line sits between `.lm` and `.rm`, not inside a hardcoded width — so
    // narrowing the margin moves the centre.
    func indent(_ src: String) -> Int {
        var doc = parseWS(bytes(src))
        doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 3,
                                  highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0,
                                  size: 40)
        let line = emitText(doc, mode: .modern).split(separator: "\n")
            .first { !String($0).trimmed().isEmpty } ?? ""
        return line.count - String(line).trimmed().count
    }
    let narrow = indent(".rm 40\r\n.oc on\r\nCentre me.\r\n")
    let wide = indent(".rm 70\r\n.oc on\r\nCentre me.\r\n")
    #expect(narrow < wide)
    // `.lm` shifts the centre too: WordStar centres BETWEEN the margins
    #expect(indent(".lm 10\r\n.rm 40\r\n.oc on\r\nCentre me.\r\n") > narrow)
}
