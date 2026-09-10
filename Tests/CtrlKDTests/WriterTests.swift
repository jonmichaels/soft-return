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
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws4FlaggedText("hello there friendly world this line wraps along")
    data += SOFT + ws4FlaggedText("and continues here") + HARD
    data += ws4FlaggedText("Second paragraph opens now.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func ws4HighbitToggleRoundtrips() throws {
    // a word ending at a style boundary flags the TOGGLE byte (0x93 = ^S|80)
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes("plain ") + [0x93] + bytes("under") + [0x93] + bytes(" word")
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

// ---------------------------------------------------------------- WS5+

@Test func ws5ProseAndSoftReturns() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes("This paragraph wraps at the usual column and keeps going")
    data += SOFT + bytes("until the author presses Return.") + HARD + HARD
    data += bytes("Second paragraph.") + HARD + ws5Seed + [0x1A]
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

@Test func bare0x09TabByteSurvivesVerbatim() throws {
    // Planning #244 (found 2026-09-08 by the private round-trip gauntlet): a
    // bare 0x09 tab byte (as opposed to the `.tb`-ruler type-9 tab block the
    // test above covers) must come back as the SAME literal byte -- not the
    // modulus-8 spaces Printed-mode PDF rendering computes for it
    // (`expandBareTabsForPrintedLayout`, planning #244's own layout-time
    // relocation of that expansion, see that function's doc comment). Baking
    // the expansion into `decodeSpans` at PARSE time (the original planning
    // #202/#237 shape) made a computed space indistinguishable from one the
    // author actually typed, and this exact byte broke round-trip on three
    // real archive documents (sawyer/MACROS/HOLYMAC/-HOLYMAC.WS, sawyer/REF/
    // WINDOWS7.WS, sawyer/REF/wordstar-file-format.ws) before this fix --
    // this is the synthetic regression guard for that gap; the corpus
    // gauntlet below is the real-file coverage.
    let data = ws5Seed + bytes("From:\tWordStar") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func ws5WrappedExtendedCharsAndBareHighByte() throws {
    // a real é as the wrapped triple, a chart glyph, a wrapped PRINTABLE (ASCIITAB
    // style), and a bare extended byte — four different escape economies, each of which
    // must come back in its own original form
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("caf") + [0x1B, 0x82, 0x1C] + bytes(" glyph ")
    data += [0x1B, 0x01, 0x1C] + HARD
    data += bytes("wrapped ") + [0x1B] + bytes("A") + [0x1C]
    data += bytes(" bare ") + [0xE1]
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func toggleAtLineEndStaysBeforeBreak() throws {
    // WordStar writes the toggle BEFORE the separator; the style lands on the next
    // line's spans. 40+ archive files diverged on exactly this.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("next line is bold") + [0x02] + HARD
    data += bytes("bold on") + [0x02] + bytes(" then off") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func doublestrikeAndNetZeroTogglePair() throws {
    // ^D toggles the same bold tag as ^B (fixup restores the byte), and a <14 14>
    // on/off pair leaves no span behind at all
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + [0x04] + bytes("double") + [0x04] + bytes(" and ")
    data += [0x14, 0x14] + bytes(" nothing") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func toggleOrderIsPreservedAgainstCanonicalDiff() throws {
    // the writer's span diff emits sorted removals-then-additions; the file's own order
    // <19 02> must come back via the cluster fixup
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + [0x19] + bytes("ital") + [0x02, 0x19]
    data += bytes("bold") + [0x02]
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func bindingSpaceSoftHyphensAndDroppedControls() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("bind") + [0x0F] + bytes("here soft") + [0x1F]
    data += bytes("hyphen in") + [0x1E] + bytes("active") + HARD
    data += bytes("phantom ") + [0x08] + bytes(" rubout ") + [0x00] + bytes(" fix")
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func softSpaceA0ComesBack() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("five ") + [0xA0] + bytes("year mission") + SOFT
    data += bytes("ends.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

// ------------------------------------------------------------ dot commands

@Test func dotLinesVerbatimIncludingMailmerge() throws {
    // mailmerge lines are PRESERVED bytes, never interpreted (permanent ruling);
    // trailing spaces and mixed case survive the rstrip/mask the IR's own dotCommands
    // view applies
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes(".op\r\n")
    data += bytes(".AV \"Name\", 30  \r\n")
    data += bytes(".df DATA.LST\r\n")
    data += bytes(".rv name, street \r\n")
    data += bytes("Dear &name&,") + HARD + bytes(".pa\r\n")
    data += bytes("Page two.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

@Test func dotLinesBetweenParagraphsKeepPosition() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes("First paragraph.") + HARD + HARD
    data += bytes(".lm 8\r\n.rm 65\r\n")
    data += bytes("Indented paragraph.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

@Test func headerFooterCommentDotLines() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes(".he Running head with #  \r\n")
    data += bytes(".. a comment the printer never sees\r\n")
    data += bytes(".ig another comment form\r\n")
    data += bytes("Body text here.") + HARD + ws5Seed + [0x1A]
    #expect(try rt(data) == data)
}

// ------------------------------------------------------- breaks and pages

@Test func formfeedPagebreakByteSurvives() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("Page one.") + HARD + [0x0C] + bytes("Page two.")
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func dotCommandAfterFlaggedFormFeedRoundtrips() throws {
    // Planning #246 round-trip companion to
    // dotCommandAfterAFlaggedFormFeedIsNotPrintedAsText (ParseWSTests.swift): same byte
    // shape (an End-of-page block's overprint-CR break, a bare 0x0D, a flagged form feed
    // 0x8C, then a dot command with no space), now checked for exact reassembly.
    //
    // The FF byte and the dot line's own bytes both land in the round-trip ledger at that
    // point (a pagebreak Block plus a separate dot-line entry) — only the pagebreak's own
    // event owns the flagged byte (patched back from 0x0C to 0x8C by the file-level
    // offset-based `flaggedAt` un-translate); the dot line's own ledger entry must NOT
    // also carry it, or the byte doubles on write. This is exactly the bug this test
    // guards: the ledger append used to read the pre-mutation `physical.text` instead of
    // the locally peeled `raw`, serializing the flagged form feed twice (once from the
    // pagebreak event, once folded into the dot line) — found via
    // gauntletWSCohortCensusFloor diverging on LSRBOX.WS/MICKEE.WS once the parser fix
    // above started splitting this shape correctly.
    // staged: 6.2.4's type-checker times out on the one-expression form
    let endOfPage = ws7Block(0x0B, payload: [UInt8](repeating: 0, count: 28))
    var data = ws7Block(0x00)
    data += bytes("Set a paragraph margin to print in") + SOFT
    data += bytes("paragraph style.") + HARD
    data += bytes(".cc 19") + endOfPage
    data += [0x0d, 0x8c] + bytes(".pm1") + HARD
    data += bytes("Hanging Indentation") + HARD
    data += [0x1A]
    #expect(try rt(data) == data)
}

@Test func blankLinesIncludingTrailingRunAndCtrlZTail() throws {
    // the trailing blank run is consumed by linesPass without ever being yielded
    // (the ledger's eofTail carries it); the ^Z padding after the EOF byte is the file
    // tail, verbatim
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = bytes("Text body line one here to make this look like prose ok")
    data += SOFT + bytes("and its continuation.") + HARD + HARD + HARD
    data += ws5Seed + [0x1A, 0x1A, 0x1A, 0x00]
    #expect(try rt(data) == data)
}

@Test func whitespaceOnlyLineSingleBreak() throws {
    // a spaces-only physical line parses to a content Line plus a phantom blank that
    // owns the separator; the writer merges them back to ONE line
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("Above.") + HARD + bytes("   ") + HARD
    data += bytes("Below.") + HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func overprintBareCR() throws {
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed + bytes("BASE LINE") + [0x0D] + bytes("OVERPRINT")
    data += HARD + [0x1A]
    #expect(try rt(data) == data)
}

@Test func rrRulerImageOverprintTerminatorRoundtrips() throws {
    // Mirrors ctrl-kd's test_rr_ruler_image_overprint_terminator_roundtrips
    // (planning #249): the swallowed overprint-continuation entry is folded
    // into the ruler's own round-trip ledger (rtDots, same tally anchor)
    // rather than dropped -- its bytes (here, just the bare entry's own
    // CRLF; the entry's text is empty) must still come back.
    var data = ws5Seed + bytes("Line ending before the rulers.") + HARD + HARD
    data += bytes(".rr\rL----P----R") + [0x0D] + HARD
    data += bytes(".rr\rL----R") + HARD
    data += HARD
    data += bytes("Line after the rulers.") + HARD + [0x1A]
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
    // staged: 6.2.4's type-checker times out on the one-expression form
    var want = bytes("Hello ") + [0x02] + bytes("bold") + [0x0D, 0x0A]
    want += [0x02] + bytes("second line") + [0x0D, 0x0A, 0x1A]
    #expect(try emitWS(doc) == want)
}

@Test func printstreamRefusedWithReason() throws {
    let doc = try parse(bytes("Line one of printed page\r\nLine two\r\nLine three\r\n"))
    #expect(throws: WriteError.self) { _ = try emitWS(doc) }
}

@Test func shiftJISDocumentRefused() throws {
    // 0x17 shift blocks rewrite the cleaned stream after the fact — the one parse
    // transform whose offsets cannot be replayed. Refusal, not corruption.
    // staged: 6.2.4's type-checker times out on the one-expression form
    var data = ws5Seed
    data += bytes("Enough plain prose here for detection to call the fixture a document. ")
    data += ws7Block(0x17, payload: [0x01])
    data += [0x93, 0x8A, 0x96, 0x7B] + ws7Block(0x17, payload: [0x00]) + bytes(" after")
    data += HARD + [0x1A]
    let doc = parseWS(data)
    #expect(doc.roundtrip?.unsupported == "shift-jis")
    #expect(throws: WriteError.self) { _ = try emitWS(doc) }
}

// --------------------------------------------------------- corpus gauntlet

// Files VERIFIED byte-identical on 2026-08-06 — a deliberate spread: WS4-flagged
// prose, style libraries, notes, Symbol/Dingbats runs, pctl rule-drawing,
// wrapped control charts, a 526 KB macro doc. Paths relative to the Sawyer archive root
// (`sawyerArchivePath`, the ONE place the private path lives — `CTRLKD_SAWYER_ARCHIVE`).
//
// `LSRBOX/LSRBOXES.MRG` (mailmerge + wrapped NULs) dropped from this list, planning #192
// (2026-09-05): the vendored `private-corpus` this repo's `CTRLKD_SAWYER_ARCHIVE` is
// documented to point at is documents-only by Jon's ruling, and a `.MRG` mail-merge
// template is one of the named excluded categories — the file is gone permanently, not
// incompletely, so keeping it here would fail loud against the archive shape the repo
// itself now documents as the normal armed case. Arming against a full, untrimmed Sawyer
// download still has the file; this gauntlet just no longer names it.
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
    "MACROS/HOLYMAC/-HOLYMAC.WS",   // 526 KB, net-zero toggle pairs
]

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func gauntletNamedFilesByteIdentical() throws {
    for rel in gauntletFiles {
        let path = sawyerArchivePath + "/" + rel
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)   // armed but incomplete: fail loud
        }
        let data = [UInt8](d)
        #expect(try rt(data) == data, "\(rel)")
    }
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func gauntletWSCohortCensusFloor() throws {
    // Every .WS document in the archive, with a floor a regression trips. 83 of 83 were
    // byte-identical when the Python census was written (2026-08-06) against the FULL
    // unfiltered Sawyer archive. The corpus repo's vendored `sawyer/` (D3 migration,
    // 2026-09-04) is deliberately narrower — D2 vendors test DOCUMENTS only, dropping
    // `DOSBox-X/` and `vDosPlus/` (emulator config dirs) outright — which removes two
    // duplicate-named `DISPLAY.WS` copies (`DOSBox-X/DISPLAY.WS`, `vDosPlus/DISPLAY.WS`;
    // the root `DISPLAY.WS` they duplicate IS vendored) that the old count included.
    // 82 of 82 is 100% byte-identical against the vendored corpus — no regression, just a
    // smaller cohort (verified: the floor of 83 still holds unchanged against the full,
    // un-vendored archive at `CTRLKD_SAWYER_ARCHIVE=<full archive>`). The floor here
    // tracks the vendored corpus, since that's the shape `CTRLKD_SAWYER_ARCHIVE` names
    // under this repo's own contract. If the archive itself grows a new pathological
    // file, the failure message says which file so the census can rule on it.
    guard FileManager.default.fileExists(atPath: sawyerArchivePath) else {
        throw MissingSawyerFixture(path: sawyerArchivePath)   // armed but the dir isn't there
    }
    let enumerator = try #require(FileManager.default.enumerator(atPath: sawyerArchivePath))
    var ok = 0
    var total = 0
    var bad: [String] = []
    var paths: [String] = []
    for case let rel as String in enumerator where rel.uppercased().hasSuffix(".WS") {
        paths.append(rel)
    }
    for rel in paths.sorted() {
        guard let d = FileManager.default.contents(atPath: sawyerArchivePath + "/" + rel),
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
    #expect(ok >= 82 && bad.isEmpty, "\(ok) of \(total) identical; diverged: \(bad.prefix(10))")
}
