/// Printed mode on the document's own layout grid. Port of the tests ctrl-kd added in
/// 473a39f.
///
/// Jon's ruling, 2026-08-05: "Printed that ignores fonts can't call itself Printed." A WS5+
/// printed PDF must honour the file's own layout arithmetic — `.lh` as running state
/// (vertical), the font blocks' HMI advances (horizontal), and `Tz` width-matching so a
/// proportional face lands on that horizontal grid.
import Testing
@testable import CtrlKD

@Test func lhIsStatefulEachLineKeepsTheLeadItWasSetAt() {
    // `.lh` applies from where it appears, like `.oc` and `.lm` -- it is not a
    // once-per-document page property. The page geometry still resolves the FIRST occurrence
    // (that is the document default, and what capacity is computed at); every line
    // additionally carries the lead in force where IT sat.
    //
    // Before this, a document that switched leading around its headings had all of it
    // collapsed onto one value, which is how 72pt banners came to be stacked on a 14pt lead.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes(".lh 8") + HARD
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes(".lh 16") + HARD
    data += bytes("A tall line that must sit on its own sixteen forty-eighths lead.") + HARD
    data += bytes(".lh 8") + HARD
    data += bytes("Back to six lines per inch for the rest of this small document.") + HARD
    let doc = parseWS(data)
    #expect(doc.detection?.variant == .ws5plus)
    let lines = doc.blocks.flatMap(\.lines)
    // First-wins page default is 8; only the line set at 16 carries a lead.
    #expect(doc.page?.lh48 == 8.0)
    #expect(doc.page?.lhVaries == true)
    #expect(lines.map(\.lead48) == [nil, 16.0, nil])

    // ...and the PDF advances by it. `.lh 16` = 16/48in = 24pt; the default `.lh 8` = 12pt.
    // A lead is the space ABOVE its own line (it is a printer VMI: the feed onto the line
    // uses the value set before it), so the gap from line 1 to line 2 is the TALL line's 24pt
    // and the gap from 2 to 3 is the 12pt the file went back to.
    let ys = contentSpans(emitPDF(doc, mode: .printed)).compactMap(\.y)
    #expect(ys.count >= 3)
    #expect(ys[0] - ys[1] == 24.0)
    #expect(ys[1] - ys[2] == 12.0)

    // PAGE CAPACITY deliberately stays on the document default -- 66-3-8 lines at .lh 8 = 55.
    // Whether WordStar recomputed lines-per-page as `.lh` changed is UNMEASURED (register
    // open question #15), and every way of guessing repaginates real documents on an
    // assumption. See `printedCap`.
    #expect(doc.page?.textLines == 55)
}

@Test func lhBeforeTheFirstOneIsWordStarsOwnDefaultNotTheFiles() {
    // The document default is the FIRST `.lh`, so a file that sets `.lh 16` after some text
    // does not back-date it: those earlier lines really printed at WordStar's own 8/48, and
    // they say so explicitly.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes(".lh 16") + HARD
    data += bytes("A second line, now at sixteen forty-eighths of an inch of lead.") + HARD
    let doc = parseWS(data)
    let lines = doc.blocks.flatMap(\.lines)
    #expect(doc.page?.lh48 == 16.0)               // first occurrence wins
    #expect(lines.map(\.lead48) == [8.0, nil])    // 8.0 is stated, not assumed
}

@Test func printedXComesFromWordStarsOwnHMIArithmetic() {
    // Each span starts where WordStar's own per-character advance puts it: the characters
    // before it, each at its run's HMI width (1/1800in). 1800 HMI is one inch is 72 points,
    // so a run declaring 1800 advances 72pt per character and the span after two of them
    // starts 144pt along.
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 72.0, width: 1800) + bytes("AA")
    data += fontBlock(helv, points: 12.0, width: 180) + bytes("B") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let left = printedLeft(doc, size: printedSize(doc))
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    let aa = try! #require(spans.first { $0.text == "AA" })
    let b = try! #require(spans.first { $0.text == "B" })
    #expect(aa.x == tenth(left))                  // first span at the margin
    #expect(b.x == tenth(left + 2 * 72.0))        // 2 chars x 1800 HMI
}

@Test func tzMatchesAProportionalSpanToTheHMIGrid() {
    // Times/Helvetica do not set a word in the width WordStar reserved for it, so each span
    // is scaled horizontally (Tz) until it does. The percentage is the ratio of WordStar's
    // own reserved width to the face's natural width from the AFM tables -- computed, never
    // tabulated here.
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 12.0, width: 180) + bytes("AAAA") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    let span = try! #require(spans.first { $0.text == "AAAA" })
    let target = 4.0 * 180.0 / 25.0                          // 180 HMI = 7.2pt per char
    let natural = stringWidthPt("AAAA", "Helvetica", 12)     // 4 x 667/1000 em
    #expect(span.tz == hundredth(target / natural * 100.0))
    // Helvetica's cap A (667/1000 em) is WIDER than WordStar's 10-CPI cell, so it is
    // squeezed onto the grid, not stretched.
    let tz = try! #require(span.tz)
    #expect(tz > 80.0 && tz < 100.0)
}

@Test func tzIs100ForCourierByArithmeticNotBySpecialCase() {
    // Courier is 600/1000 em and the fontless pitch is 0.6 em by derivation from `.cw`, so
    // the ratio comes out exactly 100 and NO Tz operator is written at all. Nothing in the
    // emitter tests for Courier to make this happen -- it falls out of the same arithmetic
    // every other face goes through, which is the point: if the metrics and the grid ever
    // disagreed for Courier we would want to see it, not hide it.
    let courier = typestyleNames.firstIndex { asciiLowercased($0).hasPrefix("courier") }!
    let scaled = tzScale("Hello", "Courier", 12, 5 * 180 / 25.0)
    #expect(scaled.scale == nil)
    #expect(scaled.width == 5 * 7.2)
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(courier, points: 12.0, width: 180) + bytes("Typescript.") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    #expect(!contains(emitPDF(parseWS(data), mode: .printed), bytes(" Tz")))
}

@Test func tzClampFallsBackToTheNaturalAdvance() {
    // A ratio outside [40, 250] means the file's HMI and the substituted base-14 face
    // disagree pathologically -- a typestyle we can only approximate, a printer pitch with
    // nothing to do with Helvetica. Scaling to obey it would produce glyphs stretched past
    // legibility in the name of fidelity, so the span keeps its natural advance instead and
    // the following span moves with it.
    let natural = stringWidthPt("AA", "Helvetica", 12)
    #expect(tzScale("AA", "Helvetica", 12, 40.0).scale != nil)      // in range -> scaled
    #expect(tzScale("AA", "Helvetica", 12, 400.0).scale == nil)     // out of range -> natural
    #expect(tzScale("AA", "Helvetica", 12, 400.0).width == natural)
    #expect(tzScale("AA", "Helvetica", 12, 0.1).scale == nil)
    #expect(tzScale("AA", "Helvetica", 12, 0.1).width == natural)
    #expect(tzMin == 40.0 && tzMax == 250.0)

    // 1800 HMI at 12pt asks for 72pt per character where Helvetica sets 8 -- a 900% stretch.
    // The span is left alone and the next one follows it at its NATURAL width, not on the
    // abandoned grid.
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 12.0, width: 1800) + bytes("AA")
    data += fontBlock(helv, points: 12.0, width: 180) + bytes("B") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let left = printedLeft(doc, size: 12)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    let aa = try! #require(spans.first { $0.text == "AA" })
    let b = try! #require(spans.first { $0.text == "B" })
    #expect(aa.tz == nil)                                    // no scaling written
    #expect(b.x == tenth(left + natural))
}

@Test func tzIsWrittenOnlyWhenItChangesBecauseItIsTextState() {
    // Tz survives ET: it is text state, not a property of one text object. An 85 set on a
    // banner would silently scale every following span in the same content stream, so the
    // operator is written on CHANGE only -- which is also why a document that never needs it
    // emits none (see the byte-identity digests).
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 12.0, width: 180) + bytes("Wide")
    data += fontBlock(helv, points: 12.0, width: 180) + bytes("Wide") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let spans = contentSpans(emitPDF(parseWS(data), mode: .printed))
    let scaled = spans.filter { $0.text == "Wide" }
    #expect(scaled.count == 2)
    #expect(scaled.first?.tz != nil)              // first sets the scaling
    #expect(scaled.last?.tz == nil)               // same value: nothing to say
    // ...and the next span that needs a DIFFERENT scaling states it again -- lowercase
    // Helvetica is narrower than caps, so the closing line's ratio is not the banner's and is
    // written out rather than inherited.
    let closing = try! #require(spans.first { $0.text.hasPrefix("A closing") })
    #expect(closing.tz != nil)
    #expect(closing.tz != scaled.first?.tz)
}

@Test func leadingTabIndentMeasuresInPrintColumnsNotTheFont() {
    // WordStar expands a tab to its stop in 10-CPI PRINT COLUMNS (`.tb` and `.lm` are
    // specified there, and the tab expander converts the tab's HMI size to columns before
    // emitting the padding). Run that padding at a 72pt display font's own advance instead
    // and a one-column offset becomes a six-inch one -- which is exactly how the archive's
    // banner document, which tabs to 1.39in and then 1.4in to print a word twice with a
    // 0.1in shadow, threw its second copy off the right edge of the paper.
    let helv = helvTypestyle()
    let tab = ws7Block(0x09, payload: le16(2502) + le16(2502) + bytes(" \r"))    // 1.39in
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 72.0, width: 1064) + tab + bytes("X") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let left = printedLeft(doc, size: 12)
    let x = try! #require(contentSpans(emitPDF(doc, mode: .printed))
        .first { $0.text == "X" }?.x)
    // 14 columns at 10 CPI, not 14 x the 72pt font's 42.6pt.
    #expect(x == tenth(left + 14 * 12 * 0.6))
}
