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
    // Register b31, E3 open items 2+3 (ruled 2026-08-25, ctrl-kd 5f3a102): the document
    // default is WordStar's own hardcoded 8/48 here, NOT the file's only `.lh`, because
    // that `.lh 16` sits AFTER real body text has already begun — a mid-document
    // occurrence is the domain of the per-line stateful mechanism (`Line.lead48`,
    // unaffected by this change), not the document-wide default `parsePageDot`
    // resolves. The FIRST prose line therefore matches the (correct) 8.0 default and
    // back-dates to `nil`; the SECOND line is the one that explicitly deviates.
    //
    // (Before this fix, PRE-TEXT-LAST-WINS did not exist and the parser's own
    // "first occurrence anywhere" reading retroactively promoted this single
    // mid-document `.lh 16` to the document's own global default, which back-dated the
    // FIRST line instead — backwards, since that line printed before `.lh 16` was
    // ever reached.)
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes(".lh 16") + HARD
    data += bytes("A second line, now at sixteen forty-eighths of an inch of lead.") + HARD
    let doc = parseWS(data)
    let lines = doc.blocks.flatMap(\.lines)
    #expect(doc.page?.lh48 == 8.0)                // WordStar's own default: no pre-text
                                                    // `.lh` occurrence
    #expect(lines.map(\.lead48) == [nil, 16.0])   // 16.0 is stated (it deviates); 8.0
                                                    // now matches the default
}

// MARK: - register b31, E3 open items 2+3 (2026-08-25, ctrl-kd 5f3a102): `parsePageDot`
// pre-text-last-wins -- a back-to-back correction before any body text resolves to the
// LAST value (MICKEE.WS: `.hm 0.22"` then `.hm3`, nothing between them, header row
// measured moving to the SECOND value); a repeat once body text has begun is left to the
// per-page/per-line stateful machinery instead, and no longer retroactively becomes the
// document's own opening default.

@Test func pretextBackToBackHmLastWinsMickeeShape() {
    // MICKEE.WS's own real shape (Sawyer archive): `.hm 0.22"` immediately followed by
    // `.hm3`, both before a single character of body text. Real WS7 prints the header
    // at the SECOND value's row (measured, register b31-dot-command-sweep) --
    // `doc.page?.hmLines` must resolve to 3.0 (the LAST one), not 1.32 (0.22in * 6 LPI,
    // the first).
    var data = ws7Block(0x00)
    data += bytes(".hm 0.22\"") + HARD
    data += bytes(".hm3") + HARD
    for i in 1...10 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.hmLines == 3.0)
    #expect(doc.page?.hmSource == .file)
}

@Test func pretextBackToBackPlLastWinsGeneralizesPastHm() {
    // The pre-text-last-wins rule is a property of the whole page-geometry pass
    // (`parsePageDot`'s `_PAGE_DOT_KEYS`-equivalent switch), not a special case for
    // `.hm` alone -- pin it against `.pl` too, two settings back to back before any
    // text.
    var data = ws7Block(0x00)
    data += bytes(".pl30") + HARD
    data += bytes(".pl45") + HARD
    for i in 1...10 { data += bytes("Body line \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.plLines == 45.0)
    #expect(doc.page?.sizeSource == .file)
}

@Test func midDocumentRepeatNoLongerRetroactivelyBecomesTheDefault() {
    // The other half of the same fix: a command whose ONLY occurrence sits AFTER real
    // body text has begun must NOT retroactively become the document's own opening
    // default (the exact bug `hmFmCheckpoints`'s doc comment already worked around for
    // the render path -- this pins the fix at the SOURCE, `doc.page` itself). `.mb`
    // here only ever appears once, well after the opening prose -- the document's
    // global `mbLines` must stay at WordStar's own hardcoded default (8.0), not the
    // mid-document 2.0.
    var data = ws7Block(0x00)
    data += bytes("Opening prose, well before any page-geometry command.") + HARD
    for i in 1...10 { data += bytes("More opening prose \(i).") + HARD }
    data += bytes(".mb2") + HARD
    for i in 1...10 { data += bytes("Later prose \(i).") + HARD }
    let doc = parseWS(data)
    #expect(doc.page?.mbLines == 8.0)
    #expect(doc.page?.mbSource == .default)
    // ...while the per-page checkpoint machinery still sees it, exactly as it always
    // did -- this fix narrows `doc.page`, it does not touch the stateful mid-document
    // mechanism at all.
    let checkpoints = mtMbCheckpoints(doc)
    let last = checkpoints[checkpoints.count - 1]
    #expect(last.mt == 3.0 && last.mb == 2.0)
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
    // A genuinely proportional font block (ctrl-kd round 9: proportional=true is what
    // puts a span on this path at all -- see `pdfFamily`) is scaled by a FACE-CONSTANT
    // Tz: one percentage per (face, pitch, size), chosen so the face's AVERAGE lowercase
    // character lands on the document's own HMI grid (`faceTz`) -- not a per-span exact
    // match, which would crush a short, wide-glyphed span. The percentage is computed,
    // never tabulated here.
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    // 0x8000: the proportional bit -- a real 'Helv' record IS proportional, and that
    // flag now decides Helvetica vs Courier (see `pdfFamily`).
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 12.0, styleBits: 0x8000, width: 180) + bytes("AAAA") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let spans = contentSpans(emitPDF(doc, mode: .printed))
    let span = try! #require(spans.first { $0.text == "AAAA" })
    let expected = faceTz("Helvetica", 180.0 / 25.0, 12)     // 180 HMI = 7.2pt pitch
    #expect(span.tz == expected)
    // Helvetica's AVERAGE lowercase glyph is NARROWER than WordStar's 10-CPI cell, so
    // the constant STRETCHES it to the grid, not squeezes it (contrast a single "AAAA"
    // span's own wide caps, irrelevant here -- the scale is the face's, not the span's).
    let tz = try! #require(span.tz)
    #expect(tz > 100.0 && tz < 250.0)
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
    // disagree pathologically -- a typestyle we can only approximate, a printer pitch
    // with nothing to do with the face it resolved to. Scaling to obey it would produce
    // glyphs stretched past legibility in the name of fidelity, so the span keeps its
    // natural advance instead and the following span moves with it.
    //
    // ctrl-kd round 9: this is `tzScale`'s OWN per-span clamp, exercised through the
    // real PDF pipeline via a record with proportional=false (styleBits left at the
    // default 0 -- unlike the other Tz tests, this one deliberately does NOT set
    // 0x8000). A genuinely proportional record (Helv with the bit set) never reaches
    // `tzScale` at all any more -- see `lineOpsPrinted`'s own proportional branch, which
    // routes to the face-constant `faceTz` instead and has no natural-advance fallback
    // of its own (it clamps to a constant scale, it does not give up). The still-real,
    // still-reachable mismatch this test demonstrates is a proportional=false record
    // (typestyle number irrelevant -- the name plays no part once the bit says false)
    // whose OWN declared HMI is absurd relative to Courier's real metrics, e.g. a
    // 1-inch-per-character pitch: even Courier's arithmetic disagrees with that
    // pathologically.
    let natural = stringWidthPt("AA", "Helvetica", 12)
    #expect(tzScale("AA", "Helvetica", 12, 40.0).scale != nil)      // in range -> scaled
    #expect(tzScale("AA", "Helvetica", 12, 400.0).scale == nil)     // out of range -> natural
    #expect(tzScale("AA", "Helvetica", 12, 400.0).width == natural)
    #expect(tzScale("AA", "Helvetica", 12, 0.1).scale == nil)
    #expect(tzScale("AA", "Helvetica", 12, 0.1).width == natural)
    #expect(tzMin == 40.0 && tzMax == 250.0)

    // 1800 HMI at 12pt asks for 72pt per character where Courier sets ~7.2 -- a 900%
    // stretch. The span is left alone and the next one follows it at its NATURAL width,
    // not on the abandoned grid. `helv`'s typestyle NUMBER is reused only for
    // convenience (it exists in the table); the proportional bit is what matters, and
    // it is false here (the default), so `pdfFamily` selects Courier regardless of the
    // "Helv" name.
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
    let courierNatural = stringWidthPt("AA", "Courier", 12)
    #expect(aa.tz == nil)                                    // no scaling written
    #expect(b.x == tenth(left + courierNatural))
}

@Test func tzIsWrittenOnlyWhenItChangesBecauseItIsTextState() {
    // Tz survives ET: it is text state, not a property of one text object. An 85 set on a
    // banner would silently scale every following span in the same content stream, so the
    // operator is written on CHANGE only -- which is also why a document that never needs it
    // emits none (see the byte-identity digests).
    //
    // ctrl-kd round 9: for a genuinely proportional record, Tz is FACE-CONSTANT (`faceTz`,
    // keyed on face+pitch+size) -- two spans in the SAME font block get the identical
    // value regardless of which characters they hold (unlike the old per-span `tzScale`
    // model this test originally exercised, where a caps-heavy span and a lowercase span
    // could differ). "Changes" now genuinely means the (face, pitch, size) key changed --
    // demonstrated here with a second font block at a DIFFERENT declared pitch, still
    // Helv, still proportional.
    let helv = helvTypestyle()
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 12.0, styleBits: 0x8000, width: 180) + bytes("Wide")
    data += fontBlock(helv, points: 12.0, styleBits: 0x8000, width: 180) + bytes("Wide") + HARD
    data += fontBlock(helv, points: 12.0, styleBits: 0x8000, width: 240) + bytes("Different") + HARD
    let spans = contentSpans(emitPDF(parseWS(data), mode: .printed))
    let scaled = spans.filter { $0.text == "Wide" }
    #expect(scaled.count == 2)
    #expect(scaled.first?.tz != nil)              // first sets the scaling
    #expect(scaled.last?.tz == nil)               // same (face, pitch, size) key: nothing to say
    // ...and the next span at a DIFFERENT declared pitch (240 vs 180 HMI) gets its own
    // face-constant Tz, written out rather than inherited.
    let different = try! #require(spans.first { $0.text == "Different" })
    #expect(different.tz != nil)
    #expect(different.tz != scaled.first?.tz)
}

@Test func leadingTabIndentMeasuresInPrintColumnsNotTheFont() {
    // WordStar expands a tab to its stop in 10-CPI PRINT COLUMNS (`.tb` and `.lm` are
    // specified there, and the tab expander converts the tab's HMI size to columns before
    // emitting the padding). Run that padding at a 72pt display font's own advance instead
    // and a one-column offset becomes a six-inch one -- which is exactly how the archive's
    // banner document, which tabs to 1.39in and then 1.4in to print a word twice with a
    // 0.1in shadow, threw its second copy off the right edge of the paper.
    //
    // UPDATED (the real-tab-position fix, ctrl-kd 8bbad81's own update to this same
    // test): the target is now `content[2:4]`, the block's own "absolute tab size in
    // HMIs" (ABSOLUTE from the left margin -- MEASURED against real WS7 PCL, LJ6DTP.pcl
    // page 5), read directly and divided by `hmiPerPoint` (25) -- not `tabColumns`'s
    // `content[0:2]` rounded to the nearest 10-CPI column and then re-multiplied by a
    // display size. Both words here carry 2502 in EITHER field (`le16(2502)` twice), so
    // this fixture cannot by itself distinguish the two reads; what changed is which one
    // now governs and that no column-rounding step sits between the file's own HMI value
    // and the point position: 2502/25 = 100.08pt exactly, vs the old
    // round(2502/180) = 14 columns x 12 x 0.6 = 100.8pt -- a 0.72pt difference from the
    // rounding step alone.
    let helv = helvTypestyle()
    let tab = ws7Block(0x09, payload: le16(2502) + le16(2502) + bytes(" \r"))    // 1.39in
    // 0x8000: the proportional bit -- the evidence font (the archive banner's Antique
    // Olive) is proportional, and the document-column indent rule is scoped to
    // proportional runs (a fixed-pitch font's spaces advance at its own pitch instead:
    // LJ6DTP's PC-8 chart border).
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 72.0, styleBits: 0x8000, width: 1064) + tab
        + bytes("X") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let left = printedLeft(doc, size: 12)
    let x = try! #require(contentSpans(emitPDF(doc, mode: .printed))
        .first { $0.text == "X" }?.x)
    // The tab's own absolute HMI target -- not 14 x the 72pt font's 42.6pt, and not a
    // column-rounded approximation of the target either.
    #expect(x == tenth(left + 2502.0 / hmiPerPoint))
}

@Test func proportionalFontKeepsItsOwnHMIGridViaTz() {
    // Every font run is width-matched onto ITS OWN font block's HMI grid with Tz --
    // proportional faces included. PS.TST's faces declare distinct per-character HMIs
    // (Helv Narrow 4.80pt, Univ. Roman 10.08pt): the grid is what preserves each face's
    // true measure and keeps text registered with tabs, rules and vector graphics (Jon's
    // review, 2026-08-05, after a natural-width detour flattened them all to the
    // substitute's uniform average). Words are placed ONE OP EACH (word-anchored
    // natural widths, face-scaled Tz), so the text appears word by word, never as a
    // single phrase.
    let univers = ws7Block(0x02, payload: le16(155) + le16(240) + le16(49710)
        + [UInt8](repeating: 0, count: 6))
    let body = ws7Block(0x00) + univers
        + bytes("iiii mmmm a proportional line of prose.") + HARD
    let pdf = emitPDF(parseWS(body), mode: .printed)
    #expect(contains(pdf, bytes(" Tz ")))               // scaled onto the face's grid
    #expect(contains(pdf, bytes("(proportional)")))
    #expect(contains(pdf, bytes("(prose.)")))
}

@Test func printControlDisplayStringIsScreenOnlyInPrintedPDF() {
    // 0x0F user print control: the display string is what WordStar SHOWS on screen; on
    // paper it sends the raw printer payload and advances by the block's own HMI word (0
    // for LJ6DTP's rule-drawing controls). Reading modes keep the string -- it is the
    // only human-visible trace of what the control does -- but the printed facsimile
    // drops it, exactly as the printout did.
    let note = bytes("EMPTY 3-dot rule")
    let ctl = ws7Block(0x0F, payload: le16(0) + [UInt8(note.count)] + note
        + [0x1B] + bytes("*c2370a0003b0P"))
    let body = ws7Block(0x00) + bytes("Heading before the control") + ctl + HARD
        + bytes("Plain paragraph of ordinary prose padding for detection.") + HARD
    let doc = parseWS(body)
    // Round 3 (2026-08-06, M10): display strings are SCREEN-ONLY everywhere --
    // Modern shows nothing (command codes are invisible; M4 extended)
    #expect(!emitText(doc, mode: .modern).contains("EMPTY 3-dot rule"))
    #expect(!emitRTF(doc, mode: .modern).contains("EMPTY 3-dot rule"))
    let pdf = emitPDF(doc, mode: .printed)
    #expect(!contains(pdf, bytes("EMPTY 3-dot rule")))
    #expect(contains(pdf, bytes("Heading before the control")))
    // Printed RTF drops the same screen-only span (padded to round(hmi/180) spaces --
    // 0 here, LJ6DTP's own rule-drawing HMI).
    #expect(!emitRTF(doc, mode: .printed).contains("EMPTY 3-dot rule"))
    #expect(emitRTF(doc, mode: .printed).contains("Heading before the control"))
}
