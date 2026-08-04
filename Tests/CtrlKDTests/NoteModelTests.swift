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

@Test func lengthFieldLargerThanDataDoesNotCrash() {
    // A symmetric block whose declared length claims far more bytes than actually
    // follow it in the stream — `blockEnd = min(i + 3 + jump, data.count)` must clamp
    // this, both at the top-level `symmetricBlocks` scan and inside `parseNote`'s walk
    // over a note's own content.
    let data: [UInt8] = [0x1d, 0xff, 0xff, 0x03, 0x01, 0x00, 0x00, 0x00, 0x30] + bytes("hi")
    let result = symmetricBlocks(data)
    #expect(result.notes.count == 1)
    #expect(result.notes[0].kind == .footnote)

    // And through the full parseWS pipeline (paired with a second, well-formed block
    // so detect() has enough 0x1d evidence to route this as ws5+). The oversized
    // block's clamped `blockEnd` reaches all the way to the end of the document, so
    // it swallows everything after it (including " trailing." and the closing hard
    // return) into its own note text/content — that's expected of a deliberately
    // malformed length field, not a bug; what matters is that parsing completes.
    let full = ws7Block(0x00) + data + bytes(" trailing.") + HARD
    let doc = parseWS(full)
    #expect(doc.notes.count == 1)
    #expect(doc.notes[0].kind == .footnote)
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

@Test func headingBlockTooShortForItsLevelByteIsPreservedAsUnknown() {
    // cmd 0x11 (paragraph style) truncated before its level byte even arrives (the
    // block's declared length leaves only the length-field-plus-cmd, no room for a
    // level byte at all) can't be interpreted as a heading — Python's
    // `_symmetric_blocks` falls through to the catch-all `unknown_blocks` branch for
    // exactly this shape (`len(block) > 3` is false), rather than silently dropping
    // it. Built from raw bytes, not `ws7Block`, since that helper always appends a
    // trailing closer that makes `block.count >= 6` — this specific gap only shows up
    // in a genuinely truncated block.
    let data: [UInt8] = [0x1d, 0x01, 0x00, 0x11]   // jump=1: block = [len,len,cmd] only
    let result = symmetricBlocks(data)
    #expect(result.unknownBlocks.contains { $0.cmd == 0x11 })
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
    let body: [UInt8] = [0x70] + bytes("LASERJET") + [0x00] + [0x00, 0x00]
        + [0x34, 0x12] + [0x01, 0x00]
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
    #expect(emitText(withDisplay, mode: .printed).contains("[LOGO]"))
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
    // C1. Three style IDs were mapped to heading levels and EVERY OTHER STYLE WAS
    // DROPPED — silently. The archive uses at least twelve distinct IDs, and 0x06
    // alone appears 60 times: more often than two of the three that WERE mapped.
    func styled(_ id: UInt8) -> Block {
        parseWS(wsBlock(cmd: 0x11, content: [id, 2, 1, 2, 2, 3, 1, 2])
                + bytes("Styled text.\r\n")).blocks[0]
    }
    #expect(styled(0x05).heading == 1)
    #expect(styled(0x05).styleID == 5)
    for id: UInt8 in [0x06, 0x0F, 0x19] {
        let b = styled(id)
        #expect(b.heading == 0, "not one of the three known headings")
        #expect(b.styleID == Int(id), "but WHICH style must still be known")
        #expect(b.lines[0].text() == "Styled text.")
    }
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
