import Foundation
import Testing
@testable import CtrlKD

/// Hand-written coverage for the ctrl-kd 1.2.0 delta that `notes-vectors-1.2.0.json`
/// doesn't (or can't) exercise: the undocumented right-tab type, malformed/truncated
/// symmetric blocks, unknown-block preservation, and page-geometry edge cases (a `.pl`
/// of 0, an explicit unit suffix). Every test here is built from bytes by hand, the
/// same way the existing `ParseWSTests.swift`/`DetectTests.swift` suites are.

// MARK: - Tab type ']' (item 10) — Python's `_ws7_tab` test helper, ported

/// One symmetrical-sequence type-9 (tab) block: Word tab size in HMIs, Word absolute
/// tab size in HMIs (repeated — this project only reads the first), Byte tab type,
/// Byte tab size in tenths. Mirrors Python's `_ws7_tab` test helper.
private func ws7Tab(sizeHMI: Int, tabType: UInt8, tenths: UInt8 = 0) -> [UInt8] {
    let sizeBytes: [UInt8] = [UInt8(sizeHMI & 0xFF), UInt8((sizeHMI >> 8) & 0xFF)]
    let content = sizeBytes + sizeBytes + [tabType, tenths]
    return ws7Block(0x09, payload: content)
}

@Test func tabUndocumentedRightAlignType() {
    // ']' is an undocumented right-align tab variant WordTsar's author found testing
    // MicroPro's own PRINT.TST; a real type-9 block there carries tab type ']' with size
    // 4500 HMI. An HMI is 1/1800in (HORTAB.TXT), so 4500 HMI = 2.5in = 25 ten-CPI
    // columns. (The old expectation of 31 came from dividing by 144 — VMI's 1/1440in
    // unit misapplied to the horizontal axis; every archive tab block's own tenths-byte
    // says /180.)
    let data = ws7Block(0x00) + ws7Tab(sizeHMI: 4500, tabType: UInt8(ascii: "]")) + bytes("Indented.") + HARD
    let doc = parseWS(data)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.hasPrefix(String(repeating: " ", count: 25)))
    #expect(text.trimmed() == "Indented.")
}

@Test func tabDotLeaderRepeatsLeaderCharacter() {
    // spec: "Other character such as '.' or '*' are used for dot leaders."
    // 720 HMI = 0.4in = 4 columns.
    let data = ws7Block(0x00) + bytes("Row") + ws7Tab(sizeHMI: 720, tabType: UInt8(ascii: ".")) +
               bytes("Contents") + HARD
    let doc = parseWS(data)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains(String(repeating: ".", count: 4)))
    #expect(text.hasPrefix("Row") && text.hasSuffix("Contents"))
}

@Test func tabMalformedBlockDoesNotCrashAndDegradesToFourSpaces() {
    let data = ws7Block(0x00) + ws7Block(0x09) + bytes("Still here.") + HARD   // empty content
    let doc = parseWS(data)
    #expect(doc.blocks[0].lines[0].text().hasSuffix("Still here."))
}

// MARK: - Adversarial inputs: malformed/truncated must never crash or hang

@Test func truncatedNoteBlockDoesNotCrash() {
    // A footnote block whose content is only 2 bytes — short of the 5 the line-count/
    // tag-word/conversion-flag header needs. `parseNote`'s `content.count >= 5` guard
    // must catch this and return a mostly-empty Note, not read past the array.
    let data = ws7Block(0x00) + bytes("Body ") + ws7Block(0x03, payload: [0x01, 0x00]) +
               bytes(" end.") + HARD
    let doc = parseWS(data)
    #expect(doc.notes.count == 1)
    #expect(doc.notes[0].kind == .footnote)
    #expect(doc.notes[0].text == "")
    #expect(doc.notes[0].number == nil)
}

@Test func lengthFieldLargerThanDataIsNotABlockAtAll() {
    // A symmetric block whose declared length claims far more bytes than actually follow
    // it. Until 2026-08-04 the walker took the marker on faith and clamped
    // (`blockEnd = min(i + 3 + jump, data.count)`), so an overrunning jump SWALLOWED the
    // rest of the document into one note — 3.5 KB of ASCIITAB.WS in the case that found
    // this. The framing check now rejects it before any clamping: the count does not echo
    // and no closing 0x1D sits where the jump points, so this is a bare 0x1D, which the
    // spec says "should not appear in files". The byte is dropped and everything after it
    // stays in the document as text.
    let data: [UInt8] = [0x1d, 0xff, 0xff, 0x03, 0x01, 0x00, 0x00, 0x00, 0x30] + bytes("hi")
    let result = symmetricBlocks(data)
    #expect(result.notes.isEmpty)
    #expect(result.bytes == Array(data.dropFirst()))     // only the false marker is gone

    // And through the full parseWS pipeline (paired with a well-formed block so detect()
    // has enough 0x1d evidence to route this as ws5+): the trailing text is KEPT, which
    // is the whole point of rejecting the false block. WordStar itself truncates the file
    // when fooled by one (engineering note 650); we keep the document.
    let full = ws7Block(0x00) + data + bytes(" trailing.") + HARD
    let doc = parseWS(full)
    #expect(doc.notes.isEmpty)
    #expect(doc.blocks[0].lines[0].text().hasSuffix("hi trailing."))
}

@Test func nestedSequenceInsideNoteWithHugeJumpDoesNotHang() {
    // A note whose text contains a nested `0x1D` sequence claiming a huge jump (far
    // exceeding the remaining bytes) — `parseNote`'s inner walk must clamp the same
    // way the outer scan does, and must terminate (the loop index only ever
    // increases), not loop forever or crash.
    let nestedHuge: [UInt8] = [0x1d, 0xff, 0xff, 0x03, 0x00, 0x00]   // claims 0xffff more bytes
    let noteContent: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x30] + bytes("before ") + nestedHuge
    let data = ws7Block(0x00) + bytes("Ref ") + ws7Block(0x03, payload: noteContent) +
               bytes(" end.") + HARD
    let doc = parseWS(data)
    #expect(doc.notes.count == 1)
    #expect(doc.notes[0].kind == .footnote)
    // text up to the (clamped, swallowed) nested sequence survives
    #expect(doc.notes[0].text == "before")
}

@Test func pageLengthOfZeroDoesNotCrashAndReportsCustom() {
    let doc = parseWS(bytes(".PL 0") + HARD + bytes("Body.") + HARD)
    let page = try! #require(doc.page)
    #expect(page.plLines == 0.0)
    #expect(page.heightIn == 0.0)
    #expect(page.sizeName == "Custom")
    #expect(page.sizeSource == .file)
}

@Test func plZeroTurnsPageBreaksOff() {
    // MicroPro bug 12284 (engineering note 649): '.pl0' at the start of PRVIEW output
    // exists so "displayed page breaks are thus avoided" — `.pl 0` means NO page breaks
    // in 7.0 document mode. The old page model computed a 0-height page, floored to a
    // 4-line cap: maximal breakage, the exact opposite. 60 lines must stay on one
    // printed page, and the PDF page box falls back to Letter since an unbounded page is
    // not expressible in PDF.
    var body: [UInt8] = []
    for i in 0..<60 { body += bytes("Line \(i) of the continuous document.") + HARD }
    let doc = parseWS(bytes(".pl 0") + HARD + body)
    #expect(docToPagelines(doc, printed: true).count == 1)
    #expect(resolvedPageHeight(doc, printed: true) == PDFMetrics.pageHeight)
}

@Test func malformedPLArgumentDoesNotCrashAndDefaults() {
    // A `.PL` with no numeric argument at all must degrade to the default, never raise.
    let doc = parseWS(bytes(".PL") + HARD + bytes("Body.") + HARD)
    let page = try! #require(doc.page)
    #expect(page.plLines == 66.0)
    #expect(page.sizeSource == .default)
}

// MARK: - Page geometry: explicit unit suffix (the trap's converse)

@Test func pageLengthExplicitInchUnitConverts() {
    // NOT the trap case (a bare number is lines) -- WordStar 5.0+ DOES allow an
    // explicit unit suffix, and it must still convert: 11" -> 66 lines -> Letter.
    let doc = parseWS(bytes(".PL 11\"") + HARD + bytes("Body.") + HARD)
    let page = try! #require(doc.page)
    #expect(page.plLines == 66.0)
    #expect(page.sizeName == "Letter")
    #expect(page.sizeSource == .file)
}

// MARK: - Unknown symmetric blocks preserved, not dropped (item 7)

@Test func unrecognizedBlockTypePreservedAsUnknownBlock() {
    let data = ws7Block(0xFE, payload: [0x01, 0x02, 0x03]) + bytes("Body.") + HARD
    let result = symmetricBlocks(data)
    #expect(result.unknownBlocks.count == 1)
    #expect(result.unknownBlocks[0].cmd == 0xFE)
    #expect(result.unknownBlocks[0].offset == 0)
}

@Test func emptyWrapperBlockIsAlsoPreservedAsUnknown() {
    // The `ws7Block(0x00)` wrapper this project's own fixtures use pervasively is
    // itself an unrecognised type from the parser's point of view — it must show up
    // in `unknownBlocks`, not vanish silently.
    let data = ws7Block(0x00) + bytes("Body.") + HARD
    let result = symmetricBlocks(data)
    #expect(result.unknownBlocks.count == 1)
    #expect(result.unknownBlocks[0].cmd == 0)
}

@Test func styleBlockOfTheWrongWidthIsPreservedAsUnknown() {
    // A 0x11 block is four LE16 handles — 8 content bytes, in all 1,727 archive blocks.
    // Anything else cannot be joined against the library, and Python's
    // `_symmetric_blocks` reports it rather than dropping it.
    let wrongWidth = ws7Block(0x11, payload: [0x02])    // the invented 1-byte form
    #expect(symmetricBlocks(wrongWidth).unknownBlocks.contains { $0.cmd == 0x11 })

    // A jump of 1 leaves no room for the count echo and the closing bracket that every
    // real sequence carries (minimum 4: cmd + echo + bracket), so this never reaches the
    // 0x11 handler at all — it is a bare 0x1D, rejected as framing that does not close,
    // and reporting it as an unknown BLOCK would claim a structure that isn't there.
    let truncated: [UInt8] = [0x1d, 0x01, 0x00, 0x11]   // jump=1: [len,len,cmd] only
    let rejected = symmetricBlocks(truncated)
    #expect(rejected.unknownBlocks.isEmpty)
    #expect(rejected.bytes == [0x01, 0x00, 0x11])
}

// MARK: - NBSP-stripping in note text (replaces the pre-1.2.0-shaped job-006 coverage
// retired in VectorTests.swift — see the comment there)

@Test func noteTextStripsNBSPAndDotCommands() {
    // NBSP (CP437 byte 0xFF) is real WordStar body content (word-spacing), and a
    // note's own text is cleaned the same way the body's text always was: an NBSP
    // pair bracketing a note whose own text also carries a dot-command line.
    let noteBody = bytes(".rr----!----R") + [0x0d, 0x0a] +
                   [UInt8(0xFF)] + bytes("Hello there") + [UInt8(0xFF)]
    let data = ws7Block(0x00) + bytes("Ref ") + ws7Note(noteBody, cmd: 0x04) + bytes(" end.") + HARD
    let doc = parseWS(data)
    #expect(doc.notes.count == 1)
    #expect(doc.notes[0].kind == .endnote)
    #expect(doc.notes[0].text == "Hello there")
    #expect(doc.notes[0].dotCommands == [".rr----!----R"])
}

// ------------------------------------------- outline numbers and indexed phrases

/// A 0x0D block body per WSFORMAT.TXT: two level-move bytes, a 1-BASED level byte, then
/// eight 0-BASED level counters as words, then a 31-byte format string. Binary
/// throughout — there is no rendered number in it.
private func paranum(level: UInt8, _ counters: Int...) -> [UInt8] {
    var body: [UInt8] = [0, 0, level]
    for n in 0..<8 {
        let v = n < counters.count ? counters[n] : 0
        body += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
    return body + [UInt8](repeating: 0, count: 31)
}

@Test func paragraphNumberIsComputedFromItsLevelCounters() {
    // WordStar's AUTOMATIC outline/legal numbering (`.p#`), and the block is BINARY.
    //
    // This test used to feed the block `"2.1.3"` as literal text and assert that text
    // came back — the same misunderstanding the code had, so it passed against an
    // implementation that scanned for printable bytes. What that scan actually
    // extracted was the 31-byte FORMAT TEMPLATE, so real archive documents printed
    // "1.1.1.1.1.1.1.1" for every paragraph: plausible enough to pass unnoticed and
    // completely wrong. Level 3 with counters 1, 0, 2 renders "2.1.3".
    let doc = parseWS(wsBlock(cmd: 0x0D, content: paranum(level: 3, 1, 0, 2))
                      + bytes(" The clause text, with enough ordinary prose that "
                              + "detection is not in doubt.\r\n"))
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains("2.1.3"), "got: \(text)")
    #expect(doc.unknownBlocks.isEmpty)
}

@Test func indexedPhrasesKeepTheirVisibleText() {
    // An inline indexed PHRASE: WordStar prints the phrase in the body, and the index
    // ENTRY is the non-printing part. Dropping the block loses text outright whenever
    // the phrase is not duplicated in the visible stream.
    let indexed = wsBlock(cmd: 0x0E, content: Array("Treaty of 1868".utf8))
    let doc = parseWS(bytes("See ") + indexed + bytes(" for detail.\r\n"))
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains("Treaty of 1868"), "the indexed phrase was dropped: \(text)")
    #expect(doc.unknownBlocks.isEmpty)
}

@Test func insetGraphicsAreRecordedAndPlaceheld() {
    // C10. An INSET picture's block content IS its path, and the whole block was being
    // dropped — so a document with figures rendered as if it had none, with no
    // indication anything was missing. Six real pictures in the archive vanished this
    // way. A converter cannot render a 1987 .PIX, but it must not go quiet about one.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let doc = parseWS(bytes("Before. ") + block + bytes(" After.\r\n"))
    #expect(doc.graphics == [#"C:\PIX\FIGURE1.PIX"#])
    let text = doc.blocks[0].lines.map { $0.text() }.joined()
    #expect(text.contains("[image: FIGURE1.PIX]"), "got: \(text)")
    #expect(text.contains("Before.") && text.contains("After."))
    #expect(doc.unknownBlocks.isEmpty, "the graphic should no longer be an unknown block")
}

@Test func insetGraphicPlaceholderCarriesAPixSpanTag() {
    // b24 round 19 (RULINGS-LEDGER PIX row): an emitter that wants to replace the
    // placeholder with a real embedded image needs to find both the span AND the
    // resolved index into doc.graphics -- the placeholder text alone (identical across
    // documents that reuse a filename) can't disambiguate which occurrence it is.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let doc = parseWS(bytes("Before. ") + block + bytes(" After.\r\n"))
    let tagged = doc.blocks.flatMap(\.lines).flatMap(\.spans).filter { $0.pix != nil }
    #expect(tagged.count == 1, "\(tagged)")
    #expect(tagged.first?.text == "[image: FIGURE1.PIX]")
    #expect(tagged.first?.pix == 0)
}

@Test func twoInsetGraphicsGetDistinctPixIndices() {
    let block1 = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\ONE.PIX"#.utf8))
    let block2 = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\TWO.PIX"#.utf8))
    let doc = parseWS(bytes("A. ") + block1 + bytes(" B. ") + block2 + bytes(" C.\r\n"))
    #expect(doc.graphics == [#"C:\PIX\ONE.PIX"#, #"C:\PIX\TWO.PIX"#])
    let idxs = doc.blocks.flatMap(\.lines).flatMap(\.spans).compactMap(\.pix).sorted()
    #expect(idxs == [0, 1])
}

// ------------------------------------------- Category C: passes 2 and 3

@Test func tocAndIndexEntriesAreCollectedWithAPosition() {
    // C6/C7. A document that asked for a table of contents produced none and said
    // nothing about it. The block index resolves an entry to a PAGE after pagination —
    // the text alone cannot, since two chapters can share a title. It points FORWARD.
    let doc = parseWS(bytes(".tc Chapter One\r\nBody.\r\n.tc2 A Section\r\nMore.\r\n"
                            + ".ix wordstar\r\nEnd.\r\n"))
    #expect(doc.tocEntries.map { [$0.level, $0.blockIndex] } == [[1, 0], [2, 1]])
    #expect(doc.tocEntries.map(\.text) == ["Chapter One", "A Section"])
    #expect(doc.indexEntries.map(\.text) == ["wordstar"])
}

@Test func lineNumberingIntervalIsReadAndZeroTurnsItOff() {
    #expect(parseWS(bytes(".l# 5\r\nT.\r\n")).lineNumbering == 5)      // C11
    #expect(parseWS(bytes(".l# 0\r\nT.\r\n")).lineNumbering == nil)
}

@Test func pHashCcTbAreRecordedNotLost() {
    // All three have ZERO users in the archive, so they are RECORDED deliberately rather
    // than modelled: `.p#`'s format alphabet is documented in Sawyer's PARAGRAP.NUM ('1'
    // numerals, 'Z'/'z' letters, 'I' roman); `.cc` is `.cp`'s column partner (we don't
    // simulate column filling); `.tb` sets ASCII-tab stops (spec default is modulus 8,
    // unchanged).
    //
    // `.p#` needs its own special case: '#' is not a letter, so the shared dot-command
    // name scanner stops at 'P' and leaves '#' at the head of the argument.
    let doc = parseWS(bytes(".p# Z.1\r\n.cc 5\r\n.tb 8 16 2.5\"\r\n")
                      + bytes("Ordinary body text follows the dot commands here.\r\n"))
    let f = doc.formatting
    #expect(f.paranumFormat == "Z.1")
    #expect(f.condCol == ["5"])
    #expect(f.tabStops == [8, 16, 25])
    #expect(emitText(doc, mode: .modern).contains("Ordinary body text"))
}

@Test func peAndCvAreRecordedRatherThanSilentlyDropped() {
    // C4/C13. `.pe` asks for endnotes HERE, not at the document end; `.cv` retypes
    // notes mid-document. Acting on either is a further pass — not pretending the
    // command was absent is this one.
    let f = parseWS(bytes(".pe\r\n.cv 3 4\r\nT.\r\n")).formatting
    #expect(f.endnotesHere == true)
    #expect(f.convertNotes == ["3 4"])
}

@Test func columnsArePerBlockAndRenderInHTML() {
    // C5. The archive writes `.co2, 0.3"`, `.CO3,  .20"` and `.co1` (one column = off).
    var doc = parseWS(bytes(".co2, 0.3\"\r\nTwo columns.\r\n.co1\r\nBack to one.\r\n"))
    #expect(doc.blocks.map { [$0.columns.map(Double.init), $0.columnGutter] }
            == [[2.0, 3.0], [1.0, 3.0]])
    doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 4,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: 50)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("column-count:2"))
    #expect(html.contains("column-gap:0.30in"))
}

@Test func printedPagelinesCarryColumnGeometryAndOverflowToARealPage() {
    // Planning #227 follow-up (2026-09-09): `applyColumns`'s own column placement was
    // real in the PDF bytes but invisible to every OTHER consumer of `docToPagelines` --
    // this is the regression test for the fix, a synthetic 2-column document sized to
    // overflow one physical page. `printedCap` for a silent (default Letter/margins)
    // document is 55 lines/page (port of ctrl-kd's `_printed_cap`), so 130 one-line
    // `.co2` paragraphs need 130/2 = 65 lines per column, more than one page's own
    // 55-line column can hold: WordStar fills column 1 top-to-bottom, then column 2, so
    // overflow opens page 2 (110 lines -- 55+55 -- fit on page 1; the remaining 20 open
    // page 2, starting fresh at column 0 -- "no balancing", matching ctrl-kd's own
    // identical Python regression test and `applyColumns`'s own doc comment).
    let body = String(repeating: "Body line here now.\r\n", count: 130)
    let doc = parseWS(bytes(".co2, 0.3\"\r\n" + body +
                            ".co1\r\nBack to one column now, past the columns.\r\n"))
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 3)
    let page1 = pages[0], page2 = pages[1], page3 = pages[2]
    #expect(page1.lines.count == 110 && page2.lines.count == 20 && page3.lines.count == 1)
    #expect(page1.lines.map { $0.col } == Array(repeating: 0, count: 55) +
                                          Array(repeating: 1, count: 55))
    let col0Lefts = Set(page1.lines.filter { $0.col == 0 }.compactMap { $0.left })
    let col1Lefts = Set(page1.lines.filter { $0.col == 1 }.compactMap { $0.left })
    #expect(col0Lefts.count == 1 && col1Lefts.count == 1)
    #expect(col0Lefts != col1Lefts)
    let left0 = col0Lefts.first!, left1 = col1Lefts.first!
    #expect(left1 - left0 == page1.columnGutterPt! + page1.columnWidthPt!)
    #expect(page1.columns == 2)
    // the OVERFLOW page: both of page 1's columns filled completely, so the remaining
    // 20 lines open a NEW physical page and start filling IT from column 0 again.
    #expect(Set(page2.lines.map { $0.col }) == [0])
    #expect(Set(page2.lines.compactMap { $0.left }) == col0Lefts)
    #expect(page2.columns == 2)
    // the page AFTER `.co1` is ordinary, single-column -- no column opinion.
    #expect(page3.lines[0].col == nil && page3.columns == nil)

    // The SAME geometry, end to end, through the public `layout` JSON a renderer in any
    // language reads (planning #227's own bug report: the app's Native view was drawing
    // all of page 1 down ONE column because this JSON never surfaced `left`/`col` at
    // all).
    let data = Array(emitLayout(doc).utf8)
    let json = try! JSONSerialization.jsonObject(with: Data(data)) as! [String: Any]
    #expect(json["version"] as? Int == 5)
    let jpages = (json["printed"] as! [String: Any])["pages"] as! [[String: Any]]
    #expect(jpages.count == 3)
    let jp1 = jpages[0]
    #expect(jp1["columns"] as? Int == 2)
    #expect(jp1["column_gutter_pt"] as? Double == page1.columnGutterPt!)
    #expect(jp1["column_width_pt"] as? Double == page1.columnWidthPt!)
    let jlines1 = jp1["lines"] as! [[String: Any]]
    let jcols = jlines1.map { $0["col"] as? Int }
    #expect(jcols == Array(repeating: 0, count: 55) + Array(repeating: 1, count: 55))
    let jlefts = Set(jlines1.compactMap { $0["left"] as? Double })
    #expect(jlefts == col0Lefts.union(col1Lefts))
    let jp3 = jpages[2]
    #expect(jp3["columns"] == nil)
    let jlines3 = jp3["lines"] as! [[String: Any]]
    #expect(jlines3[0]["col"] == nil)
}

@Test func columnarBlockParagraphGetsFullAssemblyIndentAndVerseTreatment() {
    // Round 16 regression (found via the v7 corpus parity sweep against PRINT.TST/
    // PSPRINT.TST/REVIEW.DOC): a columnar block used to be its OWN early HTML branch --
    // a flat mergedLines+<br> join with no paragraph assembly at all, silently losing
    // BOTH the typed-indent-as-text-indent treatment every other paragraph gets AND the
    // verse-vs-prose join decision (two ordinary hard-terminated prose lines forced
    // apart with a literal <br> instead of flowing as one paragraph). Python's own
    // emit_html has no separate branch: a columnar block's lines are excluded from
    // STRUCTURE classification only (bullets/def-lists/centered rows), never from
    // paragraph ASSEMBLY -- they run through the exact same flushPlain()/
    // assembleParagraphUnits pipeline as an ordinary block, and only the already
    // fully-rendered <p> gets wrapped in the column <div> afterward.
    var doc = parseWS(bytes(".co3\r\n"
        + "     A typed indent opens this ordinary columnar paragraph, right here.\r\n"
        + "A second hard-terminated line of plain prose continues the very same thought.\r\n"))
    doc.detection = Detection(variant: .ws4, softReturns: 0, hardReturns: 4,
                              highBitBytes: 0, textPct: 100, symmetricBlocks1D: 0, size: 50)
    let html = emitHTML(doc, mode: .modern)
    #expect(html.contains("column-count:3"))
    // the typed indent survives as a CSS property, not literal leading spaces
    #expect(html.contains("text-indent:5ch"))
    // two ordinary (non-verse) hard lines flow as ONE paragraph, not forced apart
    #expect(!html.contains("<br>"))
}

@Test func colourAndFontChangesAreRecorded() {
    // C2/C3. Neither risked losing TEXT, but both were invisible: a document that
    // coloured a passage or set 12pt type rendered identically to one that did not.
    let colour = wsBlock(cmd: 0x01, content: [0x08, 0x04])      // colour 8, previous 4
    // WSFORMAT.TXT type 2: width HMI (1/1800in), height VMI (1/1440in), typestyle, then
    // the previous triple. WIDTH FIRST — this was read swapped until 2026-08-04, and
    // survived because 1/1440in IS 1/20pt (1440/72 = 20), so the WIDTH word read as
    // 20ths-of-a-point gave plausible sizes off the wrong field.
    let font = wsBlock(cmd: 0x02, content: [180, 0,             // width  180/1800in = 10 CPI
                                            240, 0,             // height 240/1440in = 12pt
                                            0x00, 0x84]         // proportional, serif
                                           + [UInt8](repeating: 0, count: 6))
    let doc = parseWS(bytes("Plain ") + colour + bytes("coloured ") + font + bytes("sized.\r\n"))
    #expect(doc.colours.map { [$0.colour, $0.previous] } == [[8, 4]])
    let f = doc.fonts[0]
    #expect(f.points == 12.0)
    #expect(f.cpi == 10.0)
    #expect(f.proportional)
    #expect(f.genericStyle == .serif)
    #expect(f.symbolMap == .cp437)
}

@Test func fontBlockReadsWidthBeforeHeight() {
    // The trap that hid a swapped field for a day: 1/1440in IS 1/20 point exactly
    // (1440/72 = 20), so reading the WIDTH word as 20ths-of-a-point yields sizes that
    // look like real type — 9pt, 8pt, 11pt across 862 archive blocks. Those numbers were
    // cited as confirming the reading. They were the right arithmetic on the wrong word.
    //
    // Read correctly the same corpus gives 12pt for 749 of those blocks, with 10 CPI,
    // which is what a 1992 document actually looks like.
    let font = wsBlock(cmd: 0x02, content: [180, 0, 240, 0, 0, 0]
                                           + [UInt8](repeating: 0, count: 6))
    let f = parseWS(bytes("Text ") + font + bytes(" more text here for detection.\r\n")).fonts[0]
    #expect(f.width1800 == 180 && f.cpi == 10.0)
    #expect(f.height1440 == 240 && f.points == 12.0)
}

@Test func headerSequenceStatesTheReleaseInsteadOfGuessingIt() {
    // WSFORMAT.TXT, type 0 Header: "Byte: version number in BCD (50h for Release 5.0,
    // 55h for Release 5.5, 60h for Release 6.0)", then a 9-byte driver name, 2 reserved,
    // and a 32-bit pointer to the file's style library.
    //
    // This block was read as nothing but a driver name. The version byte is the more
    // valuable field: `detect` INFERS ws4-vs-ws5+ from byte statistics, and the file says
    // its release outright. 78 archive documents declare 7.0 and 3 declare 6.0. The
    // style-library pointer is what C1 proper needs.
    // Built from typed sub-expressions, not one long `+` chain: the compiler's own
    // type checker times out on that shape once enough other array-literal-concatenation
    // expressions share this file (seen on the macOS toolchain specifically, planning
    // #227 follow-up CI run) -- breaking it up here removes the ambiguity, not the intent.
    var body: [UInt8] = [0x70]
    body += bytes("LASERJET")
    body += [0x00, 0x00, 0x00]
    body += [0x34, 0x12, 0x01, 0x00]
    let doc = parseWS(wsBlock(cmd: 0x00, content: body)
                      + bytes("Body text, with enough ordinary prose to detect.\r\n"))
    #expect(doc.wsHeader?.release == "7.0")
    #expect(doc.wsHeader?.styleLibraryOffset == 0x00011234)
}

@Test func printFileIncludesKeepTheirFilename() {
    // The reference lives INSIDE the printer payload — after the HMI word and the
    // display-character count, which is zero here.
    let doc = parseWS(bytes("Before ")
                      + wsBlock(cmd: 0x0F, content: [0, 0, 0] + Array(#"%F"PLEAD.PS""#.utf8))
                      + bytes(" after.\r\n"))
    #expect(doc.includes == ["PLEAD.PS"])
    #expect(doc.blocks[0].lines.map { $0.text() }.joined().contains("[include: PLEAD.PS]"))
}

@Test func userPrintControlIsParsedNotScanned() {
    // WSFORMAT.TXT, "0Fh User print control":
    //
    //     Word:  number of hmis this sequence uses on the printed page
    //     Byte:  number of characters used for screen display
    //     Text:  the display string itself
    //     "The remaining bytes … will be sent directly to the printer."
    //
    // This block used to be scanned for printable bytes looking for `%F"NAME"`,
    // ignoring the structure. The DISPLAY STRING is real content — what WordStar shows
    // on screen where the control sits — and three archive blocks carry 70 characters of
    // it. The file reference is one thing INSIDE the printer payload, not the payload.

    // a display string, no file reference
    let withDisplay = parseWS(bytes("Before ")
                              + wsBlock(cmd: 0x0F,
                                        content: [0, 0, 7] + bytes("[LOGO] ")
                                                 + [0x1B] + bytes("*p0002x"))
                              + bytes(" after.\r\n"))
    // Round 3 (2026-08-06, M10): the paper never showed the display string --
    // printed pads the control's declared HMI width instead (here 0)
    #expect(!emitText(withDisplay, mode: .printed).contains("[LOGO]"))
    #expect(emitText(withDisplay, mode: .printed).contains("Before  after."))
    #expect(withDisplay.includes.isEmpty)

    // neither: pure printer bytes stay a REPORTED unknown
    let opaque = parseWS(bytes("T ")
                         + wsBlock(cmd: 0x0F, content: [0, 0, 0] + [0x1B] + bytes("*c2370a"))
                         + bytes(" more text here.\r\n"))
    #expect(opaque.unknownBlocks.map(\.cmd) == [0x0F])
    #expect(opaque.includes.isEmpty)
}

@Test func aPrintBlockWithNoFilenameStaysAReportedUnknown() {
    // Consuming it silently would be WORSE than the bug being fixed: it turns a
    // reported unknown into an unreported one. 108 of the archive's 110 such blocks
    // are PostScript preambles with no `%F` at all — and no display string either, so
    // the documented-layout parse still reports them.
    let doc = parseWS(bytes("T ")
                      + wsBlock(cmd: 0x0F, content: [0, 0, 0] + Array("/bw 7 inch def".utf8))
                      + bytes(".\r\n"))
    #expect(doc.includes.isEmpty)
    #expect(doc.unknownBlocks.map(\.cmd) == [0x0F])
}

@Test func printerDriverNameIsReportedWithoutItsRecordTag() {
    let doc = parseWS(wsBlock(cmd: 0x00, content: Array("pLASERJET".utf8) + [0, 0, 0, 0x80])
                      + bytes("T.\r\n"))
    #expect(doc.printerDriver == "LASERJET")
}

@Test func everyParagraphStyleSurvivesNotJustTheThreeHeadings() {
    // C1. A 0x11 block is four LE16 handles; word 0's low byte is the 0-based library
    // SLOT (deleted slots counted), its high byte the 0x02 pool tag. Slot numbers carry
    // no heading semantics — the corpus's own NOVEL.WS has real H1/H2/H3 styles at slots
    // 4/10/8 while the old {0x05,0x02,0x03} map promoted its footer style to a heading.
    // Without a resolvable library the slot is still recorded; heading requires the
    // resolved NAME.
    func styled(_ slot: UInt8) -> Block {
        parseWS(wsBlock(cmd: 0x11, content: [slot, 2, 1, 2, 2, 3, 1, 2])
                + bytes("Styled text.\r\n")).blocks[0]
    }
    for slot: UInt8 in [0x05, 0x06, 0x0F, 0x19] {
        let b = styled(slot)
        #expect(b.heading == 0, "no library to resolve against => no heading")
        #expect(b.styleID == Int(slot), "but WHICH slot must still be known")
        #expect(b.lines[0].text() == "Styled text.")
    }
    // A 0x03xx handle names an editing-temp style that was never written to the file —
    // unresolvable BY DESIGN, must stay unstyled, never guessed.
    let temp = parseWS(wsBlock(cmd: 0x11, content: [5, 3, 1, 2, 2, 3, 1, 2])
                       + bytes("Styled text.\r\n")).blocks[0]
    #expect(temp.styleID == nil && temp.heading == 0)
}

@Test func shiftJISIsAModeToggleNotATextContainer() {
    // C15, corrected against WSFORMAT.TXT: "Byte: Shift-In (to Japanese) = 1,
    // Shift-Out (Back to Normal) = 0." A one-byte TOGGLE — the Japanese bytes live in
    // the ordinary stream BETWEEN the two markers.
    let jp: [UInt8] = [0x82, 0xA0, 0x82, 0xA2]
    let doc = parseWS(bytes("Before ") + wsBlock(cmd: 0x17, content: [1]) + jp
                      + wsBlock(cmd: 0x17, content: [0]) + bytes(" after.\r\n"))
    #expect(doc.shiftRuns.map(\.bytes) == [jp])
    #expect(doc.blocks[0].lines[0].text() == "Before [shift-jis: 4 bytes] after.")
}

@Test func theEscapeByteCannotFireInsideAJapaneseRun() {
    // The spec: "When shifted in, WordStar no longer uses the 1Bh/1Ch wrap characters".
    // `decodeSpans` treats 1Bh as the extended-character escape UNCONDITIONALLY, so a
    // 1Bh inside a Japanese run would swallow the byte after it. Lifting the run out
    // before decoding is what makes that impossible — a correctness property.
    let jp: [UInt8] = [0x1B, 0x41, 0x82, 0xA0]
    let doc = parseWS(bytes("Some ordinary English text here. ")
                      + wsBlock(cmd: 0x17, content: [1]) + jp
                      + wsBlock(cmd: 0x17, content: [0]) + bytes(" tail.\r\n"))
    #expect(doc.shiftRuns.map(\.bytes) == [jp])
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains("[shift-jis: 4 bytes]"))
    #expect(text.hasSuffix(" tail."), "got: \(text)")   // nothing swallowed past the run
}

@Test func fiFileInsertLeavesATrace() {
    // WSFORMAT.TXT: ".FI  File insert.  Prints the specified file at that point in the
    // document." A whole file the document composes itself from, rendering as NOTHING.
    // Three archive documents use it. Same class as inset graphics and `%F"NAME"`
    // includes — missed twice because it is a dot command, not a block.
    let doc = parseWS(bytes("Body one.\r\n.fi CHAPTER2.WS\r\nBody two.\r\n"))
    #expect(doc.includes == ["CHAPTER2.WS"])
    // and it lands BETWEEN the paragraphs, not at the front of the document
    #expect(emitText(doc, mode: .printed)
            == "Body one.\n[insert: CHAPTER2.WS]\nBody two.\n")
}

@Test func igAndDoubleDotCommentsNeverPrint() {
    // WSFORMAT.TXT: ".IG or..  Ignore.  The text on the remainder of the line is
    // treated as an unprinted comment." Verified rather than assumed.
    for src in ["One.\r\n.ig hidden note\r\nTwo.\r\n", "One.\r\n.. hidden note\r\nTwo.\r\n"] {
        let text = emitText(parseWS(bytes(src)), mode: .printed)
        #expect(!text.contains("hidden"), "got: \(text)")
        #expect(text.contains("One.") && text.contains("Two."))
    }
}

@Test func fontBlocksCarryTheirTypestyleName() {
    // The spec's own 245-entry typestyle-number -> typeface-name table (WSFORMAT.TXT,
    // "Typestyles are defined by a word..."; public copy: sfwriter.com/wsformat.txt),
    // kept verbatim including alternate names. Pass-through: the table never picks a
    // font, it reports what the file said. The number is the low 9 bits of the typestyle
    // word, so the high bits (proportional, letter-quality, symbol map, generic style)
    // must not disturb the lookup.
    func typestyle(_ word: Int) -> FontChange {
        parseWS(bytes("Text ")
                + wsBlock(cmd: 0x02, content: [180, 0, 240, 0,
                                               UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF)]
                                              + [UInt8](repeating: 0, count: 6))
                + bytes(" more text here for detection.\r\n")).fonts[0]
    }
    #expect(typestyle(3).typestyleName == "Courier")
    #expect(typestyle(0x8400 | 5).typestyleName == "Tms Rmn (also CG Times, Times Roman and Dutch)")
    #expect(typestyle(244).typestyleName == "Greek (PS (Universal Greek))")
    #expect(typestyle(245).typestyleName == nil)          // past the table's last entry
}
