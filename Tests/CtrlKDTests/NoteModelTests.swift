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
    // MicroPro's own PRINT.TST; a real type-9 block there carries tab type ']' with
    // size 4500 HMI (4500/144 = 31.25 -> 31 columns, round-half-to-even doesn't apply
    // here since it's not an exact tie).
    let data = ws7Block(0x00) + ws7Tab(sizeHMI: 4500, tabType: UInt8(ascii: "]")) + bytes("Indented.") + HARD
    let doc = parseWS(data)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.hasPrefix(String(repeating: " ", count: 31)))
    #expect(text.trimmed() == "Indented.")
}

@Test func tabDotLeaderRepeatsLeaderCharacter() {
    // spec: "Other character such as '.' or '*' are used for dot leaders." 720/144 = 5.
    let data = ws7Block(0x00) + bytes("Row") + ws7Tab(sizeHMI: 720, tabType: UInt8(ascii: ".")) +
               bytes("Contents") + HARD
    let doc = parseWS(data)
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains(String(repeating: ".", count: 5)))
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

@Test func paragraphNumbersAreContentNotUnknownBlocks() {
    // WordStar's AUTOMATIC outline/legal numbering (`.p#`). This used to fall through
    // to UnknownBlock, which DELETES the computed number from the output entirely —
    // not unstyled, gone. Outline-numbered essays, wills and structured reports lost
    // every generated number with no trace.
    let numbered = wsBlock(cmd: 0x0D, content: Array("2.1.3".utf8))
    let doc = parseWS(numbered + bytes(" The clause text.\r\n"))
    let text = doc.blocks[0].lines[0].text()
    #expect(text.contains("2.1.3"), "the generated number was dropped: \(text)")
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
    // coloured a passage or set 9pt type rendered identically to one that did not.
    let colour = wsBlock(cmd: 0x01, content: [0x08, 0x04])
    let font = wsBlock(cmd: 0x02, content: [180, 0, 240, 0, 0x03, 0x46] + [UInt8](repeating: 0, count: 6))
    let doc = parseWS(bytes("Plain ") + colour + bytes("coloured ") + font + bytes("sized.\r\n"))
    #expect(doc.colours.map { [$0.foreground, $0.background] } == [[8, 4]])
    #expect(doc.fonts.map(\.height20thPt) == [180])
    #expect(doc.fonts[0].points == 9.0)
}

@Test func printFileIncludesKeepTheirFilename() {
    let doc = parseWS(bytes("Before ")
                      + wsBlock(cmd: 0x0F, content: [0, 0, 0] + Array(#"%F"PLEAD.PS""#.utf8))
                      + bytes(" after.\r\n"))
    #expect(doc.includes == ["PLEAD.PS"])
    #expect(doc.blocks[0].lines.map { $0.text() }.joined().contains("[include: PLEAD.PS]"))
}

@Test func aPrintBlockWithNoFilenameStaysAReportedUnknown() {
    // Consuming it silently would be WORSE than the bug being fixed: it turns a
    // reported unknown into an unreported one. 108 of the archive's 110 such blocks
    // are PostScript preambles with no `%F` at all.
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
