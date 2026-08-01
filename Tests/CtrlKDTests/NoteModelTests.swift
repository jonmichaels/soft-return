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
