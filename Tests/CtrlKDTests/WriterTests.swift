import Foundation
import Testing
@testable import CtrlKD

/// The native WordStar writer and its gauntlet (tasks #20/#21). Port of
/// `tests/test_writer.py`. Synthetic fixtures are built byte-by-byte; the corpus
/// gauntlet at the bottom runs only when the private archive is present and asserts
/// byte-identity on named, verified files plus a census floor a regression will trip.



/// WS4 sets bit 7 on the last character of each word (writer-local variant).
private func ws4Word(_ w: [UInt8]) -> [UInt8] {
    var out = w
    if let last = out.last { out[out.count - 1] = last | 0x80 }
    return out
}

private func ws4FlaggedText(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { ws4Word(bytes(String($0))) }
        .joined(separator: [0x20]).map { $0 }
}

/// End-of-page marker: two 0x1D framing bytes make detect() read the fixture as ws5+.
private let ws5Seed = ws7Block(0x0B, payload: [0, 0, 0, 0])

/// The whole contract in one call: emitWS(parseWS(x)), to compare with x.
private func rt(_ data: [UInt8]) throws -> [UInt8] {
    try emitWS(parseWS(data))
}

// ---------------------------------------------------------------- WS4

@Test func ws4ProseRoundtripsWithFlagBits() throws {
    // bit-7 word flags are masked at decode; Line.fixups restores each one
    let data = ws4FlaggedText("hello there friendly world this line wraps along")
        + SOFT + ws4FlaggedText("and continues here") + HARD
        + ws4FlaggedText("Second paragraph opens now.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func ws4HighbitToggleRoundtrips() throws {
    // a word ending at a style boundary flags the TOGGLE byte (0x93 = ^S|80)
    let data = bytes("plain ") + [0x93] + bytes("under") + [0x93] + bytes(" word")
        + HARD + [0x1A]
    #expect(try rt(data) == data)
}

// ---------------------------------------------------------------- WS5+

@Test func ws5ProseAndSoftReturns() throws {
    let data = bytes("This paragraph wraps at the usual column and keeps going")
        + SOFT + bytes("until the author presses Return.") + HARD + HARD
        + bytes("Second paragraph.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

@Test func ws5NoteBlockReserializedVerbatim() throws {
    let note = ws7Note(bytes("A footnote body."), cmd: 0x03)
    let data = bytes("Text before") + note + bytes(" and after.") + HARD + [0x1A]
    let doc = parseWS(data)
    #expect(doc.notes.first?.kind == .footnote)
    #expect(try emitWS(doc) == data)
}

@Test func ws5TabBlockAndExpansion() throws {
    // type 9 tab: 2 columns (360 HMI), hard tab type ' '
    let tab = ws7Block(0x09, payload: [0x68, 0x01, 0x68, 0x01] + bytes(" ") + [0x02])
    let data = ws5Seed + tab + bytes("indented text") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func ws5WrappedExtendedCharsAndBareHighByte() throws {
    // a real é as the wrapped triple, a chart glyph, a wrapped PRINTABLE (ASCIITAB
    // style), and a bare extended byte — four different escape economies, each of which
    // must come back in its own original form
    let data = ws5Seed + bytes("caf") + [0x1B, 0x82, 0x1C] + bytes(" glyph ")
        + [0x1B, 0x01, 0x1C] + HARD
        + bytes("wrapped ") + [0x1B] + bytes("A") + [0x1C] + bytes(" bare ") + [0xE1]
        + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func toggleAtLineEndStaysBeforeBreak() throws {
    // WordStar writes the toggle BEFORE the separator; the style lands on the next
    // line's spans. 40+ archive files diverged on exactly this.
    let data = ws5Seed + bytes("next line is bold") + [0x02] + HARD
        + bytes("bold on") + [0x02] + bytes(" then off") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func doublestrikeAndNetZeroTogglePair() throws {
    // ^D toggles the same bold tag as ^B (fixup restores the byte), and a <14 14>
    // on/off pair leaves no span behind at all
    let data = ws5Seed + [0x04] + bytes("double") + [0x04] + bytes(" and ")
        + [0x14, 0x14] + bytes(" nothing") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func toggleOrderIsPreservedAgainstCanonicalDiff() throws {
    // the writer's span diff emits sorted removals-then-additions; the file's own order
    // <19 02> must come back via the cluster fixup
    let data = ws5Seed + [0x19] + bytes("ital") + [0x02, 0x19] + bytes("bold") + [0x02]
        + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func bindingSpaceSoftHyphensAndDroppedControls() throws {
    let data = ws5Seed + bytes("bind") + [0x0F] + bytes("here soft") + [0x1F]
        + bytes("hyphen in") + [0x1E] + bytes("active") + HARD
        + bytes("phantom ") + [0x08] + bytes(" rubout ") + [0x00] + bytes(" fix")
        + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func softSpaceA0ComesBack() throws {
    let data = ws5Seed + bytes("five ") + [0xA0] + bytes("year mission") + SOFT
        + bytes("ends.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

// ------------------------------------------------------------ dot commands

@Test func dotLinesVerbatimIncludingMailmerge() throws {
    // mailmerge lines are PRESERVED bytes, never interpreted (permanent ruling);
    // trailing spaces and mixed case survive the rstrip/mask the IR's own dotCommands
    // view applies
    let data = bytes(".op\r\n")
        + bytes(".AV \"Name\", 30  \r\n")
        + bytes(".df DATA.LST\r\n")
        + bytes(".rv name, street \r\n")
        + bytes("Dear &name&,") + HARD + bytes(".pa\r\n")
        + bytes("Page two.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

@Test func dotLinesBetweenParagraphsKeepPosition() throws {
    let data = bytes("First paragraph.") + HARD + HARD
        + bytes(".lm 8\r\n.rm 65\r\n")
        + bytes("Indented paragraph.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

@Test func headerFooterCommentDotLines() throws {
    let data = bytes(".he Running head with #  \r\n")
        + bytes(".. a comment the printer never sees\r\n")
        + bytes(".ig another comment form\r\n")
        + bytes("Body text here.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

// ------------------------------------------------------- breaks and pages

@Test func formfeedPagebreakByteSurvives() throws {
    let data = ws5Seed + bytes("Page one.") + HARD + [0x0C] + bytes("Page two.")
        + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func blankLinesIncludingTrailingRunAndCtrlZTail() throws {
    // the trailing blank run is consumed by linesPass without ever being yielded
    // (the ledger's eofTail carries it); the ^Z padding after the EOF byte is the file
    // tail, verbatim
    let data = bytes("Text body line one here to make this look like prose ok")
        + SOFT + bytes("and its continuation.") + HARD + HARD + HARD
        + ws5Seed + [0x1A, 0x1A, 0x1A, 0x00]
    #expect(try rt(data) == data)
}

@Test func whitespaceOnlyLineSingleBreak() throws {
    // a spaces-only physical line parses to a content Line plus a phantom blank that
    // owns the separator; the writer merges them back to ONE line
    let data = ws5Seed + bytes("Above.") + HARD + bytes("   ") + HARD
        + bytes("Below.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func overprintBareCR() throws {
    let data = ws5Seed + bytes("BASE LINE") + [0x0D] + bytes("OVERPRINT") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

// ------------------------------------------------------------ the contract

@Test func editorMutationSurvivesASave() throws {
    // the reason the writer serializes from the IR: mutate a span, save, and the
    // mutation is in the bytes (guarded fixups degrade, never corrupt). This is the
    // anti-"keep a copy of the input" test.
    let data = ws5Seed + bytes("The quick brown fox.") + HARD + [0x1A]
    var doc = parseWS(data)
    let old = doc.blocks[0].lines[0].spans[0]
    doc.blocks[0].lines[0].spans[0] = Span(text: old.text.replacingAll("q", with: "q")
        .split(separator: " ").map { $0 == "quick" ? "sneaky" : String($0) }
        .joined(separator: " "), styles: old.styles)
    let out = try emitWS(doc)
    #expect(contains(out, bytes("sneaky")) && !contains(out, bytes("quick")))
    #expect(Array(out.suffix(3)) == HARD + [0x1A])
    // and the mutated file still parses to the mutated text
    #expect(parseWS(out).blocks[0].lines[0].text().contains("sneaky brown fox"))
}

@Test func syntheticDocumentWritesCanonicalBytes() throws {
    // no ledger at all: flags drive the breaks, output ends like a WordStar file, and
    // it parses back to the same text
    let doc = Document(blocks: [Block(kind: .para, lines: [
        Line(spans: [Span(text: "Hello "), Span(text: "bold", styles: [.bold])]),
        Line(spans: [Span(text: "second line")]),
    ])], era: "ws5+")
    // the span diff closes bold at the next span boundary — the head of line two —
    // because a ledger-less doc has no togEnd to say otherwise
    #expect(try emitWS(doc) == bytes("Hello ") + [0x02] + bytes("bold") + [0x0D, 0x0A]
        + [0x02] + bytes("second line") + [0x0D, 0x0A, 0x1A])
}

@Test func printstreamRefusedWithReason() throws {
    let doc = try parse(bytes("Line one of printed page\r\nLine two\r\nLine three\r\n"))
    #expect(throws: WriteError.self) { _ = try emitWS(doc) }
}

@Test func shiftJISDocumentRefused() throws {
    // 0x17 shift blocks rewrite the cleaned stream after the fact — the one parse
    // transform whose offsets cannot be replayed. Refusal, not corruption.
    let data = ws5Seed + bytes("Enough plain prose here for detection to call the "
        + "fixture a document. ") + ws7Block(0x17, payload: [0x01])
        + [0x93, 0x8A, 0x96, 0x7B] + ws7Block(0x17, payload: [0x00]) + bytes(" after")
        + HARD + [0x1A]
    let doc = parseWS(data)
    #expect(doc.roundtrip?.unsupported == "shift-jis")
    #expect(throws: WriteError.self) { _ = try emitWS(doc) }
}

// --------------------------------------------------------- corpus gauntlet

// Files VERIFIED byte-identical on 2026-08-06 — a deliberate spread: WS4-flagged
// prose, style libraries, notes, Symbol/Dingbats runs, pctl rule-drawing, mailmerge,
// wrapped control charts, a 526 KB macro doc. Paths relative to the WS archive root
// (`archiveWSPath`, the ONE place the private path lives).
private let gauntletFiles = [
    "OLDTIMES.WS",            // the review benchmark: notes, styles
    "LJ6DTP.WS",              // 41 print controls, colour, fonts
    "RTF-RJS/NOVEL.WS",       // style library + Symbol-font passages
    "REF/WSFORMAT.WS",        // the spec describing its own format
    "REF/ASCIITAB.WS",        // every control code wrapped as a chart
    "REF/BOOKLET.WS",         // A0 soft spaces, flagged form feeds
    "REF/PP.WS",              // trailing wrapped-control triples
    "REF/CODES.WS",           // overprint ^H composition
    "PRINTERS/fontcrib.ws",   // mid-line Symbol/Dingbats via styles
    "WS-CON/SAMPLE.WS",       // ^D doublestrike, interleaved toggles
    "LSRBOX/LSRBOXES.MRG",    // mailmerge + wrapped NULs
    "MACROS/HOLYMAC/-HOLYMAC.WS",   // 526 KB, net-zero toggle pairs
]

@Test func gauntletNamedFilesByteIdentical() throws {
    for rel in gauntletFiles {
        guard let d = FileManager.default.contents(atPath: archiveWSPath + "/" + rel)
        else { continue }             // not in this copy of the archive
        let data = [UInt8](d)
        #expect(try rt(data) == data, "\(rel)")
    }
}

@Test func gauntletWSCohortCensusFloor() throws {
    // Every .WS document in the archive, with a floor a regression trips. 83 of 83
    // were byte-identical when the Python census was written (2026-08-06); the same
    // floor here, so a writer/parser regression fails loudly. If the archive itself
    // grows a new pathological file, the failure message says which file so the census
    // can rule on it.
    guard FileManager.default.fileExists(atPath: archiveWSPath) else { return }
    guard let enumerator = FileManager.default.enumerator(atPath: archiveWSPath) else { return }
    var ok = 0
    var total = 0
    var bad: [String] = []
    var paths: [String] = []
    for case let rel as String in enumerator where rel.uppercased().hasSuffix(".WS") {
        paths.append(rel)
    }
    for rel in paths.sorted() {
        guard let d = FileManager.default.contents(atPath: archiveWSPath + "/" + rel),
              !d.isEmpty else { continue }
        let data = [UInt8](d)
        let variant = detect(data).variant
        guard variant == .ws4 || variant == .ws5plus else { continue }
        total += 1
        if let out = try? rt(data), out == data {
            ok += 1
        } else {
            bad.append(rel)
        }
    }
    #expect(total >= 80, "archive shrank? only \(total) .WS documents seen")
    #expect(ok >= 83 && bad.isEmpty, "\(ok) of \(total) identical; diverged: \(bad.prefix(10))")
}
