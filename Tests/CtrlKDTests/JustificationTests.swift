import Testing
@testable import CtrlKD

/// Planning #238: `.oj on` full justification in Printed mode — Swift port of ctrl-kd's
/// `tests/test_justification.py` (aeb34ad/7276894), same 6 synthetic byte-exact cases.
///
/// Rule (measured against real WS7 captures — full writeup, before/after numbers, and
/// the open sub-decipoint question: the maintainer's own private research notes,
/// `2026-09-08_justification-rule.md`, WordStar research vault — PRIVATE corpus
/// paths/findings stay out of even this private repo's tests, only the RULE and
/// synthetic fixtures do, same doctrine ctrl-kd's own port note states):
///
///   1. Every line of a `.oj on` (`align == .justify`) paragraph EXCEPT ITS OWN LAST
///      physical line is stretched so its last character lands exactly on the block's
///      resolved right margin (`.rm`, in print columns, measured from the same `.po`
///      origin as the left edge). The last line of the paragraph is left ragged.
///   2. The slack is shared the way WS7's own driver does it (WS7 report 11.7.3,
///      `wordstar-dos/11-print-engine.md`): in dots (1/300 in), every run of blanks between
///      the first word and the last takes `floor(w * S_rem / W_rem)` of the slack still
///      left, w being that run's own width -- so a double blank takes twice a single one's
///      share, the remainders fall to the later runs, and a word lands at
///      `floor(x_dots * 720 / 300)` decipoints. Leading blanks and the blanks before the
///      soft return are not a gap. The six rows measured on earlier WS7 captures are
///      reproduced exactly (`theMeasuredGapRows`).
///   3. The rule runs over the whole line, whatever its spans: a styled word mid-sentence,
///      or a proportional face, is spread with each item's own width (report 14.15, runs
///      mixj1-mixj4).
///   4. WS5+ soft spaces (bare 0xA0) are ignored: the driver spreads the line itself
///      (report 14.6).
///   5. Modern mode is untouched.
///
/// Fixed-pitch WS4-shaped fontless documents throughout (no font block — `spanPitch`
/// falls back to `pt * 0.6` = 7.2pt/char at the 12pt default), so every width below is
/// exact arithmetic, not a font-metric approximation — same construction Python's own
/// fixture set uses.

/// The `Td` x immediately preceding `(word) Tj` in the emitted PDF's own content
/// streams, or `nil` if the word never appears as its own Tj operand — Swift's content
/// streams are never Flate-compressed (unlike ctrl-kd's, see `HorizontalVectorTests
/// .pdfOpsTriples`), so no decompression step is needed here. Port of Python's
/// `_word_x`.
private func wordX(_ pdf: [UInt8], _ word: String) -> Double? {
    let needle = "(\(word)) Tj"
    for line in latin1(pdf).split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: needle) else { continue }
        let prefix = line[line.startIndex..<r.lowerBound]
        guard prefix.hasSuffix("Td ") else { continue }
        let fields = prefix.dropLast(3).split(separator: " ")
        guard fields.count >= 2 else { continue }
        return Double(fields[fields.count - 2])
    }
    return nil
}

private func justifyDoc(_ src: [UInt8]) -> Document {
    parseWS(bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n") + src)
}

/// `.po 0"` / `.lm 0` / `.rm 20` (144pt) -- "AA BB CC" is 8 chars (57.6pt) natural, 2
/// single-blank gaps, needing 86.4pt of slack split evenly (43.2pt/gap, `base` below):
/// AA@0, BB@AA(14.4)+gap(7.2+43.2)=64.8, CC@BB_end(64.8+14.4)+gap(7.2+43.2)=129.6,
/// ending at 129.6+14.4=144.0 -- the one confirmed-solid part of the rule (every
/// justified line in the corpus lands its last character exactly on the margin); the
/// per-gap SPLIT that gets it there is this pass's own documented approximation (rule
/// 2 above), not a WS7 byte-for-byte match.
@Test func justifiedLineReachesTheResolvedRightMargin() throws {
    var justifyDocArg63: [UInt8] = bytes(".oj on\r\n")
    justifyDocArg63 += bytes("AA BB CC")
    justifyDocArg63 += SOFT
    justifyDocArg63 += bytes("DD.")
    justifyDocArg63 += HARD
    let doc = justifyDoc(justifyDocArg63)
    let b = doc.blocks[0]
    #expect(b.align == .justify)
    #expect(b.lines.count == 2)
    let pdf = emitPDF(doc, mode: .printed)
    let xAA = try #require(wordX(pdf, "AA"))
    let xBB = try #require(wordX(pdf, "BB"))
    let xCC = try #require(wordX(pdf, "CC"))
    #expect(xAA == 0.0)
    let base = (144.0 - 8 * 7.2) / 2       // 43.2pt of slack per elastic gap
    let xBBExpected = 2 * 7.2 + (7.2 + base)
    let xCCExpected = xBBExpected + 2 * 7.2 + (7.2 + base)
    #expect(xBB == (xBBExpected * 10).rounded() / 10)
    #expect(xCC == (xCCExpected * 10).rounded() / 10)
    // The confirmed-solid part of the rule: CC's own right edge lands exactly on the
    // margin, not just "somewhere further right".
    #expect(xCC + 2 * 7.2 == 144.0)
}

/// WS7 never justifies a paragraph's own trailing line (measured directly against a
/// real WS7 capture, per this file's own header) -- "DD." here is the second (last)
/// physical line of the SAME block and must render at its natural, un-stretched
/// position.
@Test func lastLineOfJustifiedParagraphIsNotStretched() throws {
    var justifyDocArg87: [UInt8] = bytes(".oj on\r\n")
    justifyDocArg87 += bytes("AA BB CC")
    justifyDocArg87 += SOFT
    justifyDocArg87 += bytes("DD.")
    justifyDocArg87 += HARD
    let doc = justifyDoc(justifyDocArg87)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(wordX(pdf, "DD.") == 0.0)
}

/// WS4 stores a justified line's blanks at wrap time and ends only a wrapped line in a
/// soft return (WS4 report 2.7, 7.7): a line the author ended with Return stays ragged in
/// a WS4 document too, and a stored soft return that Modern reflow keeps as a break
/// (`keepBreak`) is still a soft line, so it is justified. Port of Python's
/// `test_a_hard_returned_line_of_a_ws4_block_is_not_stretched`, whose fixture detects as a
/// print stream there and is printed by WS7's rule: here it is read as WS4 and printed by
/// WS7 (`printedBy: .ws7`). WS4's own HPLJET justifies only from flagged words
/// (`HPLJETTests`), and these carry no bit 7.
@Test func aHardReturnedLineOfAWS4BlockIsNotStretched() throws {
    var src: [UInt8] = bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n.oj on\r\n")
    src += bytes("AA BB CC") + HARD
    src += bytes("DD EE FF") + SOFT
    src += bytes("GG HH II") + HARD
    src += bytes("JJ.") + HARD
    let doc = parseWS(src, variant: .ws4, printedBy: .ws7)
    let lines = doc.blocks[0].lines
    #expect(lines.map(\.soft) == [false, true, false, false])
    #expect(lines.map(\.keepBreak) == [false, true, false, false])
    let pdf = emitPDF(doc, mode: .printed)
    // a stretched line is drawn word by word; a ragged one in a single Tj
    #expect(wordX(pdf, "BB") == nil)
    #expect(wordX(pdf, "EE") != nil)
    #expect(wordX(pdf, "HH") == nil)
}

/// `AA BB  CC` at `.rm 20`: 330 dots of slack over a 30-dot and a 60-dot run of blanks --
/// floor(30*330/90) = 110 dots, then the rest (220) to the double blank. WS7 report 11.7.3
/// (a typed double blank DOES stretch).
@Test func aDoubleBlankTakesTwiceASingleBlanksShare() throws {
    var src: [UInt8] = bytes(".oj on\r\n")
    src += bytes("AA BB  CC")
    src += SOFT
    src += bytes("DD.")
    src += HARD
    let doc = justifyDoc(src)
    #expect(doc.blocks[0].lines[0].text() == "AA BB  CC")
    let pdf = emitPDF(doc, mode: .printed)
    // AA ends at 60 dots; BB starts 30 + 110 dots later, CC 60 + 220 after BB ends
    #expect(wordX(pdf, "AA") == 0.0)
    #expect(wordX(pdf, "BB") == Double((60 + 30 + 110) * 12 / 5) / 10)
    #expect(wordX(pdf, "CC") == Double([200, 60, 60, 220].reduce(0, +) * 12 / 5) / 10)
    #expect(try #require(wordX(pdf, "CC")) + 2 * 7.2 == 144.0)
}

/// WS7 report 11.7.3: trailing blanks are not items. `AA BB CC ` + soft return gives the
/// same line as without the trailing blank.
@Test func theBlankBeforeTheSoftReturnIsNotAGap() {
    var plain: [UInt8] = bytes(".oj on\r\nAA BB CC")
    plain += SOFT + bytes("DD.") + HARD
    var trailing: [UInt8] = bytes(".oj on\r\nAA BB CC ")
    trailing += SOFT + bytes("DD.") + HARD
    let a = docToPagelines(justifyDoc(plain), printed: true)[0][0].justifyWordX ?? []
    let b = docToPagelines(justifyDoc(trailing), printed: true)[0][0].justifyWordX ?? []
    #expect(a.count == 5 && b.count == 6)
    #expect(Array(b.prefix(5)).map { [$0.text, "\($0.x)"] } == a.map { [$0.text, "\($0.x)"] })
    #expect(b[5].text == " ")
    #expect(b[4].x + b[4].width == 144.0)         // CC still ends on the margin
}

/// A paragraph's indent is not stretched (report 11.7.3): AA, BB, CC share the slack in
/// their two gaps only.
@Test func leadingBlanksAreNotAGap() throws {
    var src: [UInt8] = bytes(".oj on\r\n  AA BB CC")
    src += SOFT + bytes("DD.") + HARD
    let pieces = try #require(docToPagelines(justifyDoc(src), printed: true)[0][0].justifyWordX)
    #expect(pieces[0].text == "  " && pieces[0].x == 0.0)
    #expect(pieces[1].x == 14.4)                      // AA right after the indent
    let end = pieces[pieces.count - 1].x + pieces[pieces.count - 1].width
    #expect(roundToOneDecimal(end) == 144.0)
}

/// The six rows measured on earlier WS7 captures (report 11.7.3): per-gap stretch in
/// decipoints for a slack of N/1800 in over G single gaps.
@Test func theMeasuredGapRows() throws {
    let measured: [(slack: Int, gaps: Int, want: [Int])] = [
        (180, 8, [7, 7, 10, 9, 10, 9, 10, 10]),
        (180, 9, [7, 7, 7, 7, 8, 7, 9, 10, 10]),
        (125, 5, [9, 10, 9, 10, 12]),
        (225, 5, [16, 17, 19, 20, 19]),
        (225, 8, [9, 10, 12, 12, 12, 12, 12, 12]),
        (225, 9, [9, 10, 9, 10, 10, 9, 10, 12, 12]),
    ]
    for row in measured {
        var isSpace: [Bool] = []
        var widths: [Double] = []
        for i in 0...row.gaps {
            isSpace.append(false); widths.append(21.6)
            if i < row.gaps { isSpace.append(true); widths.append(7.2) }
        }
        let right = widths.reduce(0, +) + Double(row.slack) / 25
        let xs = try #require(justifyXPrinted(isSpace: isSpace, widths: widths, x0: 0.0,
                                              justifyRightX: right))
        let words = stride(from: 0, to: xs.count, by: 2).map { xs[$0] }
        let natural = (0...row.gaps).map { $0 * 120 * 12 / 5 }
        let extra = zip(words, natural).map { $0 - $1 }
        #expect(zip(extra, extra.dropFirst()).map { $1 - $0 } == row.want)
    }
}

/// A narrow blank gets a proportionally smaller share (report 14.15, run mixj4): widths 30
/// and 15 dots, 45 dots of slack -> 30 and 15.
@Test func blanksShareByTheirOwnWidth() throws {
    let parts: [Double] = [24 * 3, 7.2, 3.6, 45 * 0.24]
    let xs = try #require(justifyXPrinted(
        isSpace: [false, true, false, true, false],
        widths: [24.0, 7.2, 24.0, 3.6, 24.0], x0: 0.0,
        justifyRightX: parts.reduce(0, +)))
    #expect(xs == [0, 240, 384, 624, 696])
}

/// Negative slack (report 11.7.3): the same loop with the sign reversed, the amount capped
/// at half the total width of the blanks. Two 100pt words and a 7.2pt blank (30 dots) end
/// 60/1800 in (10 dots) past the margin: the blank gives up 10 dots, the second word moves
/// 10 dots left.
@Test func aLineThatIsSlightlyTooLongIsSqueezed() {
    let xs = justifyXPrinted(isSpace: [false, true, false], widths: [100.0, 7.2, 100.0],
                             x0: 0.0, justifyRightX: 204.96)
    #expect(xs == [0, 417 * 12 / 5, (417 + 30 - 10) * 12 / 5])
}

/// Past the cap WS7's own wrap could not have produced the line: the margin is not this
/// line's, so it keeps its natural widths.
@Test func aLineTooLongToSqueezeIsLeftAlone() {
    #expect(justifyXPrinted(isSpace: [false, true, false], widths: [100.0, 7.2, 100.0],
                            x0: 0.0, justifyRightX: 150.0) == nil)
}

/// WS5+ soft spaces (0xA0 after a typed blank, report 11.7.3/14.6) are not part of the
/// gap: `AA`, one typed blank + three soft ones, `BB`.
@Test func softSpacesAreIgnoredByTheDriver() throws {
    var src: [UInt8] = wsBlock(cmd: 0x00, content: Array("pLASERJET".utf8) + [0, 0, 0, 0x80])
    src += bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n.oj on\r\nAA ")
    src += [0xA0, 0xA0, 0xA0] + bytes("BB CC ")
    src += SOFT + bytes("DD.") + HARD
    let doc = parseWS(src)
    let pieces = try #require(docToPagelines(doc, printed: true)[0][0].justifyWordX)
    #expect(pieces.map(\.text) == ["AA", "    ", "BB", " ", "CC", " "])
    // two equal one-blank gaps: 144 - 8*7.2 = 86.4pt = 360 dots -> 180 each
    #expect(pieces[2].x == Double((60 + 30 + 180) * 12 / 5) / 10)
    #expect(roundToOneDecimal(pieces[4].x + pieces[4].width) == 144.0)
}

/// Report 11.7.1: only a line that ends in a soft return is spread. In a WS5+ block, a
/// hard-returned line that is not the block's last is ragged.
@Test func aHardReturnLineInAJustifiedBlockStaysRaggedInWS5() {
    var src: [UInt8] = wsBlock(cmd: 0x00, content: Array("pLASERJET".utf8) + [0, 0, 0, 0x80])
    src += bytes(".po 0\"\r\n.lm 0\r\n.rm 20\r\n.oj on\r\nAA BB CC\r\nDD EE FF")
    src += SOFT + bytes("GG.") + HARD
    let lines = docToPagelines(parseWS(src), printed: true)[0]
    #expect(lines.prefix(2).map { $0.justifyWordX != nil } == [false, true])
}

/// The default (no `.oj on` anywhere) must render exactly as it did before this
/// feature existed: one whole-line Tj (`justifyEligible` never fires, so the line is
/// never split into per-word pieces), the line's own single, exact, un-stretched text.
@Test func ojOffIsUnaffected() throws {
    var justifyDocArg121: [UInt8] = bytes("AA BB CC")
    justifyDocArg121 += SOFT
    justifyDocArg121 += bytes("DD.")
    justifyDocArg121 += HARD
    let doc = justifyDoc(justifyDocArg121)
    #expect(doc.blocks[0].align == .left)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(wordX(pdf, "AA BB CC") == 0.0)
    #expect(wordX(pdf, "BB") == nil)     // never its OWN Tj -- not split
}

@Test func ojOnThenOffMidDocumentOnlyJustifiesTheOnBlock() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB CC") + SOFT + bytes("DD.") + HARD
        + bytes(".oj off\r\n") + bytes("EE FF GG") + SOFT + bytes("HH.") + HARD)
    #expect(doc.blocks.map { $0.align } == [.justify, .left])
    let pdf = emitPDF(doc, mode: .printed)
    let xBB = try #require(wordX(pdf, "BB"))       // justified block -- split, stretched
    #expect(xBB > 2 * 7.2 + 7.2)
    #expect(wordX(pdf, "EE FF GG") == 0.0)          // .oj off block -- one whole-line Tj
    #expect(wordX(pdf, "FF") == nil)                // never split into pieces
}

/// A line that carries more than one styled span (a bold word mid-sentence) resolves to
/// more than one seg; the slack is shared over the whole line anyway (report 14.15): `AA BB
/// CC` at `.rm 40` -- two equal gaps of 480 dots (115.2pt) each.
@Test func styledMixedLineIsJustifiedAcrossItsSpans() throws {
    let bold: [UInt8] = [0x02]
    var src: [UInt8] = bytes(".po 0\"\r\n.lm 0\r\n.rm 40\r\n.oj on\r\n")
    src += bytes("AA ")
    src += bold
    src += bytes("BB")
    src += bold
    src += bytes(" CC")
    src += SOFT
    src += bytes("DD.") + HARD
    let doc = parseWS(src)
    let b = doc.blocks[0]
    #expect(b.align == .justify)
    #expect(b.lines[0].spans.count > 1)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(wordX(pdf, "BB") == 136.8)
    #expect(wordX(pdf, "CC") == 273.6)
}

// -------------------- notes-paginator scope gap (planning #238, cause 1) --------------------

/// Planning #238 scope gap, ctrl-kd port (aeb34ad's sibling fix, same commit as this
/// file): a document carrying a REAL footnote/endnote/annotation anywhere routes its
/// ENTIRE Printed body through `resolvePrintedBody(withNotes: true)` (`hasPlaceableNotes`
/// gates `layoutPrintedPages` to it) -- at the time a SEPARATE
/// PageLine-building walk that, before this fix, never set `justifyRightX` at all, so
/// `.oj on` silently stopped stretching ANY line in such a document, not just a line
/// that itself carries the footnote reference. Two-line `.oj on` block here carries no
/// note reference of its own; the real footnote sits in a second, unrelated paragraph
/// purely to route the whole document through the notes paginator and prove the FIRST
/// paragraph is still justified once it does. Port of ctrl-kd's
/// `test_justification_still_applies_when_the_document_has_a_real_footnote`.
@Test func justificationStillAppliesWhenTheDocumentHasARealFootnote() throws {
    let doc = justifyDoc(bytes(".oj on\r\n") + bytes("AA BB CC") + SOFT + bytes("DD.") + HARD
        + bytes("\r\nElsewhere.") + ws7Note(bytes("A note.")) + HARD)
    #expect(!doc.notes.isEmpty && doc.notes[0].kind == .footnote)
    #expect(hasPlaceableNotes(doc), "fixture must route through resolvePrintedBody")
    let b = doc.blocks[0]
    #expect(b.align == .justify)
    let pdf = emitPDF(doc, mode: .printed)
    let xAA = try #require(wordX(pdf, "AA"))
    let xBB = try #require(wordX(pdf, "BB"))
    let xCC = try #require(wordX(pdf, "CC"))
    #expect(xAA == 0.0)
    let base = (144.0 - 8 * 7.2) / 2       // same arithmetic as the plain-path test above
    let xBBExpected = 2 * 7.2 + (7.2 + base)
    let xCCExpected = xBBExpected + 2 * 7.2 + (7.2 + base)
    #expect(xBB == (xBBExpected * 10).rounded() / 10)
    #expect(xCC == (xCCExpected * 10).rounded() / 10)
    #expect(xCC + 2 * 7.2 == 144.0)
    // The paragraph's own last line stays ragged here too (rule 1) -- unaffected by
    // which pagination path built it.
    #expect(wordX(pdf, "DD.") == 0.0)
}
