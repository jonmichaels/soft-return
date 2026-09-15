/// `.pf on` — WordStar's PRINT-TIME paragraph realignment (planning #270 item 37, Jon's
/// ruling 2026-09-13, triage Q5: "Yes, support it.").
///
/// MicroPro's own file-format reference (`WSFORMAT.TXT`, the `.PF` row): "When ON,
/// subsequent paragraphs are realigned as they are printed... using the left, right, and
/// paragraph margins currently in effect."
///
/// The reason a document can NEED it: WordStar's EDITOR is a character screen and wraps
/// at a COLUMN COUNT whatever face the text is set in; the printer wraps at the real
/// measure, in the real fonts, at print time. Two measured cases from the v4 PRISTINE
/// captures drive every rule here:
///
///   `sawyer/REF/REFORM.DOT` — Courier, `.rm 6.5"` printing but `.rm 5.0"` editing (its
///   own `.if 1=0` block). The file stores "...in editing, but" + soft return + "another
///   to occur during printing"; real WS7 prints ONE 63-character line ending "...another
///   to occur".
///
///   `sawyer/PRINT.TST` — every one of its 94 soft-wrapped lines prints EXACTLY as
///   stored, hyphens and all ("custom-"/"ized", "de-"/"fault", "docu-"/"ment",
///   "professional-"/"looking"), because nothing changed between edit time and print
///   time. That document is this mechanism's real regression test, and it is the reason
///   a discretionary hyphen has to be re-usable and a typed hyphen has to be a break
///   point.
///
/// Port of ctrl-kd's `tests/test_pf_print_reformat.py` (commit `4110671`), test for
/// test. Synthetic fixtures only; the numbers in them are the corpus's own.
import Foundation
import Testing
@testable import CtrlKD

private let pfHard: [UInt8] = [0x0D, 0x0A]
private let pfSoft: [UInt8] = [0x8D, 0x0A]

private func pfWS7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
    let count = UInt16(content.count + 4)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    // sequential `+=`, never one chained `+` expression -- planning #253
    // (`tools/check_typechecker_fixtures.py`)
    var out: [UInt8] = [0x1D]
    out += le
    out += [cmd]
    out += content
    out += le
    out += [0x1D]
    return out
}

/// One type-2 Font symmetric block — width (HMI), height (VMI), typestyle, three zeroed
/// "previous" words.
private func pfFontBlock(_ w: Int, _ h: Int, _ style: Int) -> [UInt8] {
    let le: (Int) -> [UInt8] = { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    var content = le(w)
    content += le(h)
    content += le(style)
    content += [UInt8](repeating: 0, count: 6)
    return pfWS7Block(0x02, content)
}

/// PRINT.TST's own real typestyle word for Helv: proportional bit set, typestyle 4.
private let pfPropSans = 49156

/// The document's dot-command prologue: `pf` ("`.pf on`", "`.pf off`", nil for a file
/// that never says) plus its right margin. Built with sequential `+=` rather than one
/// chained `+` expression, per planning #253 (`tools/check_typechecker_fixtures.py`).
private func pfDots(_ pf: String?, rm: String = ".rm 6.5\"") -> [UInt8] {
    var out: [UInt8] = []
    if let pf {
        out += [UInt8](pf.utf8)
        out += pfHard
    }
    out += [UInt8](rm.utf8)
    out += pfHard
    return out
}

private func pfBuild(_ body: [UInt8], dots: [UInt8] = pfDots(".pf on")) -> Document {
    var bytes = pfWS7Block(0x00)
    bytes += dots
    bytes += body
    return parseWS(bytes)
}

/// `REF/REFORM.DOT`'s own measured paragraph, stored exactly as WordStar wrote it.
private func reformDotBody() -> [UInt8] {
    var out = pfBytes("Dots to have one thing display in editing, but")
    out += pfSoft
    out += pfBytes("another to occur during printing")
    out += pfHard
    return out
}

/// `PRINT.TST`'s own heading: an active soft hyphen (0x1F) at the stored break.
private func headingBody() -> [UInt8] {
    var out = pfBytes("Paragraph Indenta")
    out += [0x1F]
    out += pfSoft
    out += pfBytes("tion")
    out += pfHard
    return out
}

/// Two short stored lines, for the narrow-measure cases.
private func narrowBody() -> [UInt8] {
    var out = pfBytes("aaaa bbbb")
    out += pfSoft
    out += pfBytes("cccc dddd")
    out += pfHard
    return out
}

private func pfBytes(_ s: String) -> [UInt8] { [UInt8](s.utf8) }

/// Every printed physical line of the document, in order, as text.
private func pfPrintedLines(_ doc: Document) -> [String] {
    docToPagelines(doc, printed: true).flatMap { page in
        page.lines.map { $0.map(\.text).joined() }
    }
}

// MARK: - the gate: `.pf` decides, and nothing else moves

@Test func pfOffKeepsTheStoredPhysicalLines() {
    let doc = pfBuild(reformDotBody(), dots: pfDots(".pf off"))
    #expect(pfRewrappedLines(doc, doc.blocks[0]) == doc.blocks[0].lines)
    #expect(Array(pfPrintedLines(doc).prefix(2))
            == ["Dots to have one thing display in editing, but",
                "another to occur during printing"])
}

@Test func pfNeverSaidKeepsTheStoredPhysicalLines() {
    let doc = pfBuild(reformDotBody(), dots: pfDots(nil))
    #expect(pfRewrappedLines(doc, doc.blocks[0]) == doc.blocks[0].lines)
}

@Test func pfDisIsNotOn() {
    let doc = pfBuild(reformDotBody(), dots: pfDots(".pf dis"))
    #expect(pfRewrappedLines(doc, doc.blocks[0]) == doc.blocks[0].lines)
}

// MARK: - the measure

@Test func pfOnPullsTheNextStoredLineUpToThePrintMargin() {
    let doc = pfBuild(reformDotBody())
    #expect(Array(pfPrintedLines(doc).prefix(2))
            == ["Dots to have one thing display in editing, but another to occur ",
                "during printing"])
}

@Test func aLineAlreadyAtTheMeasureReWrapsToItself() {
    let stored = ["WordStar is designed to take the best advantage of your printer's ",
                  "features.  This file (PRINT.TST) shows how the WordStar printing ",
                  "features work.  Print the file to see how the features work on ",
                  "your default printer."]
    var body: [UInt8] = []
    for (i, line) in stored.enumerated() {
        body += pfBytes(line)
        body += i == stored.count - 1 ? pfHard : pfSoft
    }
    #expect(Array(pfPrintedLines(pfBuild(body)).prefix(4)) == stored)
}

@Test func theTrailingSpaceStaysOnTheLineItEnded() {
    let doc = pfBuild(narrowBody(), dots: pfDots(".pf on", rm: ".rm 1.5\""))
    #expect(Array(pfPrintedLines(doc).prefix(2)) == ["aaaa bbbb cccc ", "dddd"])
}

// MARK: - hyphens

@Test func aDiscretionaryHyphenDisappearsWhenItsBreakDoes() {
    let doc = pfBuild(headingBody())
    #expect(pfPrintedLines(doc).first == "Paragraph Indentation")
}

@Test func aDiscretionaryHyphenIsReUsedWhenTheBreakIsStillNeeded() {
    var body = pfBytes("Choose fonts by name!  Press ^P= to see a menu of fonts custom")
    body += [0x1F]
    body += pfSoft
    body += pfBytes("ized for your default printer.")
    body += pfHard
    let doc = pfBuild(body)
    #expect(Array(pfPrintedLines(doc).prefix(2))
            == ["Choose fonts by name!  Press ^P= to see a menu of fonts custom-",
                "ized for your default printer."])
}

@Test func aTypedHyphenIsABreakPointAndSurvivesIt() {
    var body = pfBytes("create professional-")
    body += pfSoft
    body += pfBytes("looking newsletters and presentations.")
    body += pfHard
    let doc = pfBuild(body, dots: pfDots(".pf on", rm: ".rm 2.03\""))
    #expect(Array(pfPrintedLines(doc).prefix(3))
            == ["create professional-", "looking newsletters ", "and presentations."])
}

// MARK: - proportional text measures in points, not screen columns

@Test func aProportionalParagraphMeasuresInPointsNotColumns() {
    let dots = pfDots(".pf on", rm: ".rm 2.03\"")                    // 20.3 columns
    // 11pt proportional face, 138 HMI = 5.52pt per character: 21 characters is 115.9pt
    // against a 146.16pt measure, so the word joins.
    var propBody = pfFontBlock(138, 220, pfPropSans)
    propBody += headingBody()
    let prop = pfBuild(propBody, dots: dots)
    #expect(pfPrintedLines(prop).first == "Paragraph Indentation")
    // The SAME characters, the SAME measure, in the document's own 10-CPI Courier: 21
    // columns is 151.2pt, so the break stays — and so does the discretionary hyphen it
    // was activated for. The measure is the font's, never the screen's column grid.
    let mono = pfBuild(headingBody(), dots: dots)
    #expect(Array(pfPrintedLines(mono).prefix(2)) == ["Paragraph Indenta-", "tion"])
}

// MARK: - what realignment leaves alone

@Test func aParagraphCarryingAPrintControlIsLeftExactlyAsStored() {
    let shown = pfBytes("EMPTY 3-dot rule")
    var content: [UInt8] = [UInt8(900 & 0xFF), UInt8(900 >> 8)]
    content += [UInt8(shown.count)]
    content += shown
    content += pfBytes("\u{1B}*c2370a0003b0P")
    var body = pfBytes("aaaa bbbb")
    body += pfWS7Block(0x0F, content)
    body += pfSoft
    body += pfBytes("cccc dddd")
    body += pfHard
    let doc = pfBuild(body, dots: pfDots(".pf on", rm: ".rm 1.5\""))
    #expect(pfRewrappedLines(doc, doc.blocks[0]) == doc.blocks[0].lines)
}

@Test func wordWrapOffIsNeverReWrapped() {
    var dots = pfDots(".pf on", rm: ".rm 1.5\"")
    dots += pfBytes(".aw off")
    dots += pfHard
    let doc = pfBuild(narrowBody(), dots: dots)
    let block = doc.blocks.first { $0.kind == .para }!
    #expect(pfRewrappedLines(doc, block) == block.lines)
}

@Test func aSingleStoredLineIsLeftAlone() {
    var body = pfBytes("aaaa bbbb cccc dddd eeee")
    body += pfHard
    let doc = pfBuild(body, dots: pfDots(".pf on", rm: ".rm 1.5\""))
    #expect(pfPrintedLines(doc).first == "aaaa bbbb cccc dddd eeee")
}

// MARK: - justification: the paragraph is the unit

@Test func underPfOnOnlyAParagraphsLastLineIsRagged() {
    var body = pfBytes("aaaa bbbb")
    body += pfSoft
    body += pfBytes("cccc dddd eeee")
    body += pfHard
    body += pfBytes("This one is a whole paragraph.")
    body += pfHard
    var dots = pfDots(".pf on", rm: ".rm 1.5\"")
    dots += pfBytes(".oj on")
    dots += pfHard
    let doc = pfBuild(body, dots: dots)
    let page = docToPagelines(doc, printed: true)[0]
    let got = page.lines
        .map { ($0.map(\.text).joined(), $0.justifyRightX != nil) }
        .filter { !$0.0.trimmed().isEmpty }
    #expect(got.map(\.0) == ["aaaa bbbb cccc ", "dddd eeee",
                             "This one is a whole paragraph."])
    #expect(got.map(\.1) == [true, false, false])
}

// MARK: - every printed surface renders the same physical lines

@Test func everyPrintedExportFollowsTheSameWrap() {
    let doc = pfBuild(reformDotBody())
    let needle = "in editing, but another to occur"
    #expect(emitText(doc, mode: .printed).contains(needle))
    #expect(emitHTML(doc, mode: .printed).contains(needle))
    #expect(emitRTF(doc, mode: .printed).contains(needle))
}

@Test func aPfOffDocumentIsByteIdenticalAcrossEverySurface() {
    let doc = pfBuild(reformDotBody(), dots: pfDots(nil))
    let needle = "in editing, but another"
    #expect(!emitText(doc, mode: .printed).contains(needle))
    #expect(!emitHTML(doc, mode: .printed).contains(needle))
    #expect(!emitRTF(doc, mode: .printed).contains(needle))
}
