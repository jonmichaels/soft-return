import Testing
@testable import CtrlKD

/// Swift-side mirror of ctrl-kd's `tests/test_pcl_v4_untriaged_fixes.py` — three
/// mechanisms traced out of the ws7-prints/v4 untriaged set, 2026-09-12. Every one is
/// MEASURED against real WordStar 7 (the PRISTINE.EXE captures), not inferred; the
/// synthetic fixtures here reproduce the same shapes so the rules stay covered without
/// the corpus. The two engines are also held together on all three by
/// `AnswerKeyParityTests` and `PCLFidelityTests`.
///
///   A. A `.fo` whose text is EMPTY still puts footers in use, and a footer in use
///      silences WordStar's automatic bottom-of-page number. Real WS7 prints no number
///      on any page of `sawyer/LSRBOX/LSRBOX.WS` (a bare `.fo`, no `.op`/`.pn`/`.pg`
///      anywhere) or of four HOLYMAC macro documents.
///
///   B. A document whose entire body is one note block — no body text, no line
///      terminator after the block — rendered as a completely BLANK page. All 19 of the
///      Sawyer archive's TAGS/ annotation files are that shape, and WS7 prints them.
///
///   C. A note's own hard returns print, and WordStar stores the note's marker INLINE in
///      that text: a note whose text opens with a return carries its marker on the
///      SECOND line (`sawyer/TAGS/WHEN`), not the first (`sawyer/TAGS/WHY`), and a note
///      ending in a blank line reserves that line (`sawyer/TAGS/SIMPLIFY`).

/// An annotation block shaped exactly like the TAGS/ files: a nested sequence carrying
/// the display tag, then the note's own text. With `leadBreak`, a hard return is stored
/// BEFORE the nested tag sequence — `sawyer/TAGS/WHEN`'s own shape.
private func ws7Annotation(text: [UInt8], tag: [UInt8], lineCount: Int,
                           leadBreak: Bool = false) -> [UInt8] {
    var innerPayload: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x05]
    innerPayload += tag
    let inner = ws7Block(0x05, payload: innerPayload)
    var body: [UInt8] = leadBreak ? HARD : []
    body += inner
    body += text
    var content: [UInt8] = [UInt8(lineCount & 0xFF), UInt8((lineCount >> 8) & 0xFF)]
    content += [0x09, 0x80, 0x05]                 // tag-word (high bit set) + conv flag
    content += body
    return ws7Block(0x05, payload: content)
}

private func manyLines(_ n: Int) -> [UInt8] {
    var out: [UInt8] = []
    for i in 1...n {
        if i > 1 { out += HARD }
        out += bytes("line \(i)")
    }
    return out
}

private func printedText(_ doc: Document) -> [String] {
    docToPagelines(doc, printed: true).flatMap { page in
        page.map { $0.map(\.text).joined().trimmed() }
    }
}

// ------------------------------------------------------------------- mechanism A
@Test func bareFoSilencesTheAutomaticPageNumber() {
    // The document with no `.fo` keeps WordStar's stock automatic number.
    let without = parseWS(manyLines(150))
    let withFo = parseWS(bytes(".fo") + HARD + manyLines(150))
    #expect(withFo.footers.count == 1 && withFo.footers.values.allSatisfy { $0.isEmpty },
            "a bare .fo is a footer with no text")
    let plain = docToPagelines(without, printed: true)
    #expect(plain.contains { $0.autoPageno != nil },
            "stock automatic page number should still print")
    let silenced = docToPagelines(withFo, printed: true)
    #expect(!silenced.contains { $0.autoPageno != nil },
            "a bare .fo must silence the automatic page number")
}

@Test func pnAfterOpDoesNotResurrectTheNumberThroughAFooter() {
    // The HOLYMAC shape: `.op`, then a bare `.fo`, then `.pn` — `.pn` is an "on"
    // checkpoint for the automatic number, but the footer is what decides here, and
    // real WS7 prints no number on any page of 4MAC2/4MAC3/7MAC2/7MAC3.
    var src = bytes(".op") + HARD
    src += bytes(".fo") + HARD
    src += bytes(".pn251") + HARD
    src += manyLines(150)
    let pages = docToPagelines(parseWS(src), printed: true)
    #expect(!pages.contains { $0.autoPageno != nil })
}

// ------------------------------------------------------------------- mechanism B
@Test func noteOnlyDocumentStillRenders() {
    // A file that is one annotation block and nothing after it — no body text, no
    // terminator. It used to produce zero blocks and a blank page.
    var noteText: [UInt8] = HARD
    noteText += bytes("Why?")
    noteText += HARD
    var data = ws7Annotation(text: noteText, tag: bytes("[Why?]"), lineCount: 2)
    data += [UInt8](repeating: 0x1A, count: 87)
    let doc = parseWS(data)
    #expect(doc.blocks.count == 1, "the note reference is the document body")
    #expect(doc.notes.count == 1 && doc.notes[0].kind == .annotation)
    let texts = printedText(doc)
    #expect(texts.contains { $0.contains("[Why?]") })
    #expect(texts.contains { $0.contains("Why?") })
}

@Test func trailingEofLineWithoutMarksIsStillDropped() {
    // The blank-tail rule this narrows, unchanged.
    var src = bytes("one") + HARD
    src += bytes("two") + HARD
    src += [UInt8](repeating: 0x1A, count: 40)
    let doc = parseWS(src)
    let texts = doc.blocks.flatMap { $0.lines.map { $0.spans.map(\.text).joined() } }
    #expect(texts == ["one", "two"], "got \(texts)")
}

// ------------------------------------------------------------------- mechanism C
@Test func noteKeepsItsOwnPhysicalLines() {
    // `sawyer/TAGS/SIMPLIFY`'s shape: text, then a blank line the author typed. Exactly
    // one trailing element — the block's own terminator — is dropped, so `textLines`
    // matches WordStar's stored `lineCount`.
    // Built with `+=`, never a chained `+` across four terms (planning #253).
    var noteText: [UInt8] = HARD
    noteText += bytes("Simplify")
    noteText += HARD
    noteText += HARD
    var data = ws7Annotation(text: noteText, tag: bytes("[Simplify]"), lineCount: 3)
    data += [0x1A]
    let note = parseWS(data).notes[0]
    #expect(note.textLines == ["", "Simplify", ""])
    #expect(note.textLines.count == note.lineCount)
    #expect(note.text == "Simplify", "the flowed form is unchanged")
    #expect(note.tagLine == 0)
}

@Test func noteMarkerSitsOnTheLineItIsStoredOn() {
    // `sawyer/TAGS/WHEN`'s shape: a hard return BEFORE the nested tag sequence, so the
    // tag prints on the note area's SECOND line.
    var noteText: [UInt8] = HARD
    noteText += bytes("When?")
    noteText += HARD
    var data = ws7Annotation(text: noteText, tag: bytes("[When?]"), lineCount: 3,
                             leadBreak: true)
    data += [0x1A]
    let note = parseWS(data).notes[0]
    #expect(note.textLines == ["", "", "When?"])
    #expect(note.tagLine == 1)
}

// ------------------------------------------------------------------- mechanism D
/// `.co` newspaper columns: `.rm` IS the column's own width, measured from the `.po`
/// origin — nothing is subtracted. MEASURED against real WS7 (ws7-prints/v4,
/// PRISTINE.EXE) on `sawyer/REF/WINGDING.CHT` (`.po .3"`, `.rm .88"`, `.co5, .75"`):
/// column origins 21.6 / 138.9 / 256.3 / 373.6 / 491.0 pt, a pitch of 63.36 + 54 =
/// 117.36pt. Subtracting `.po` gave 95.76 and printed every column after the first on
/// top of column 1. `sawyer/REF/SYMBOL.CHT`, the document planning #227's research
/// checked against, has `.po .0"` — both formulas agree there.
private func columnLefts(_ src: [UInt8]) -> [Double] {
    let pages = docToPagelines(parseWS(src), printed: true)
    var seen = Set<Double>()
    for page in pages {
        for line in page where line.left != nil {
            seen.insert((line.left! * 100).rounded() / 100)
        }
    }
    return seen.sorted()
}

private func manyWords(_ n: Int) -> [UInt8] {
    var out: [UInt8] = []
    for i in 1...n {
        if i > 1 { out += HARD }
        out += bytes("word\(i)")
    }
    return out
}

@Test func columnWidthIsTheRmItselfNotRmMinusPo() {
    var src = bytes(".po .3\"") + HARD
    src += bytes(".rm .88\"") + HARD
    src += bytes(".co5,  .75\"") + HARD
    src += manyWords(59)
    let lefts = columnLefts(src)
    #expect(lefts.count >= 2, "\(lefts)")
    for (i, left) in lefts.enumerated() {
        #expect(abs(left - (21.6 + Double(i) * 117.36)) < 0.05, "column \(i): \(lefts)")
    }
}

@Test func columnWidthIsUnchangedWhenPoIsZero() {
    var src = bytes(".po .0\"") + HARD
    src += bytes(".rm .78\"") + HARD
    src += bytes(".co5,  .4i") + HARD
    src += manyWords(59)
    let lefts = columnLefts(src)
    #expect(lefts.count >= 2, "\(lefts)")
    for (i, left) in lefts.enumerated() {
        #expect(abs(left - Double(i) * 84.96) < 0.05, "column \(i): \(lefts)")
    }
}

// -------------------------------- mechanism D (long tail, 2026-09-12): centring
/// A WS5+ type-9 TAB block — WordStar's own encoding of a centred line's leading
/// padding. `content[0:2]` is the run's width, `content[2:4]` the ABSOLUTE stop in
/// HMIs, `content[4]` the fill character.
private func centreTab(_ absHMI: Int) -> [UInt8] {
    let lo = UInt8(absHMI & 0xFF), hi = UInt8((absHMI >> 8) & 0xFF)
    return ws7Block(0x09, payload: [lo, hi, lo, hi, 0x20, 0x11])
}

private func centredLineCols(_ text: [UInt8], absHMI: Int) -> Double? {
    var src = bytes(".oc on") + HARD
    src += centreTab(absHMI) + text + HARD
    let pages = docToPagelines(parseWS(src), printed: true)
    for page in pages {
        for line in page where line.contains(where: { !$0.text.trimmed().isEmpty }) {
            if let hmi = line.first?.tabHMI { return Double(hmi) / 180.0 }
        }
    }
    return nil
}

/// A `.oc on` line is re-centred at PRINT time on its ink alone.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/PLAYBILL.DOC`,
/// whose 12 centred lines each carry their own type-9 centring tab. The three lines
/// whose stored text ends in blanks are exactly the three WS7 prints somewhere other
/// than the stored tab: `A gala opening night with the ` at column 18 (file: 17.5),
/// `City ... special season ` at 4.5 (file: 4), `for Theatre in the Park.  ` at 20.5
/// (file: 19.5). The editor counted the trailing blanks when it centred; the printer
/// does not. All 12 land on `(65 - ink) / 2`.
@Test func centredLineIgnoresItsOwnTrailingBlanks() {
    // 29 characters of ink, one trailing blank: (65 - 29) / 2 = 18.0
    #expect(centredLineCols(bytes("A gala opening night with the "), absHMI: 3150) == 18.0)
    // 24 characters of ink, two trailing blanks: (65 - 24) / 2 = 20.5
    #expect(centredLineCols(bytes("for Theatre in the Park.  "), absHMI: 3510) == 20.5)
}

/// The other nine PLAYBILL lines: the editor's own arithmetic already agrees with the
/// printer's, and nothing moves.
@Test func centredLineWithNoTrailingBlanksKeepsItsStoredTab() {
    #expect(centredLineCols(bytes("TENTH ANNIVERSARY SEASON"), absHMI: 3690) == 20.5)
    #expect(centredLineCols(bytes("THEATRE IN THE PARK"), absHMI: 4140) == 23.0)
}

/// A ^ONI index ENTRY (a type-0x0E symmetrical block) belongs to the index file, not to
/// the page.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/REF/-INDEX.HOW`,
/// whose own prose introduces two of them with "^ONI command — which creates a
/// symmetrical sequence such as these:". WS7 spends both rows (its "as these:" line
/// sits at 348.0pt and the next printed line, "Using .ix", at 408.0pt — five 12pt rows
/// apart, exactly the blank/entry/entry/blank the file stores) and puts NO INK on
/// either. This engine printed both phrases.
///
/// Printed only: the phrase stays in the IR, tagged `indexEntry`, so every
/// text/Markdown/HTML/RTF consumer keeps it.
@Test func oniIndexEntryPrintsNothingButKeepsItsRow() {
    var src = bytes("before") + HARD
    src += ws7Block(0x0E, payload: bytes("Sawyer\\, Robert J.")) + HARD
    src += bytes("after") + HARD
    let doc = parseWS(src)
    let tagged = doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }.filter(\.indexEntry)
    #expect(tagged.map(\.text) == ["Sawyer\\, Robert J."])
    let printed = docToPagelines(doc, printed: true)
    let drawn = printed.flatMap { $0.flatMap { $0.map(\.text) } }
    #expect(!drawn.contains("Sawyer\\, Robert J."), "\(drawn)")
    #expect(drawn.contains("before") && drawn.contains("after"), "\(drawn)")
    #expect(printed.flatMap { $0 }.count >= 3, "\(printed.flatMap { $0 }.count)")
    let modern = docToPagelines(doc, printed: false)
    let kept = modern.flatMap { $0.flatMap { $0.map(\.text) } }
    #expect(kept.contains { $0.contains("Sawyer") }, "\(kept)")
}

// --------------------------------------------- mechanism D (long tail, 2026-09-12)

/// A column group shares one top — in the NOTE-BEARING paginator too.
///
/// `docToPagelines`'s own main loop already charges a columnar group's shared
/// non-columnar PREFIX against every column of the group except the first;
/// `paginatePrintedNotes` — the paginator every document with a footnote/endnote/
/// annotation takes instead — did not, so a later column kept a whole page's capacity
/// while starting BELOW the page top and ran off the bottom of the sheet.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/PRINT.TST`
/// page 2 — `.co3, .20"` under a "Paragraph Styles" prefix. WS7 opens all three columns
/// at 288.0pt and, with a text bottom of 720.0pt (`.mt 1"`/`.mb 1"`/`.pl 11"`) at a 12pt
/// lead, gives each 36 rows: column 1 holds 15 and ends on its own `.cb`, column 2 holds
/// 21 and ends on `.cc 19`, column 3 holds 23. This engine gave column 2 the full 54-row
/// page, never reached the `.cc`, and placed 51 lines from y 286 down to y 884 — past the
/// text bottom, past the sheet (792), through the page number at 756 — leaving column 3
/// empty.
@Test func columnUnderAPrefixNeverOverflowsTheTextBottom() {
    var src = bytes(".mt 1\"") + HARD
    src += bytes(".mb 1\"") + HARD
    for i in 1...15 { src += bytes("prefix line \(i)") + HARD }
    src += bytes(".rm 2\"") + HARD
    src += bytes(".co3,  .2\"") + HARD
    src += manyWords(139) + HARD
    src += ws7Annotation(text: bytes("a note"), tag: bytes("[N]"), lineCount: 1) + HARD
    let doc = parseWS(src)
    let pages = docToPagelines(doc, printed: true)
    let columnar = pages.filter { ($0.columns ?? 1) > 1 }
    #expect(!columnar.isEmpty, "no columnar page: \(pages.map { $0.columns ?? 1 })")
    let lead = printedLead(doc)
    let budget = printedBudgetPt(doc, capacity: printedCap(doc), defaultLead: lead)
    for page in columnar {
        let top = page.columnTopOffsetPt ?? 0.0
        var byCol: [Int: [PageLine]] = [:]
        for line in page { byCol[line.col ?? 0, default: []].append(line) }
        for (ci, rows) in byCol where ci > 0 {
            let spent = rows.reduce(0.0) { $0 + ($1.lead ?? lead) }
            #expect(top + spent <= budget + lead,
                    "column \(ci): top \(top) + spent \(spent) > budget \(budget)")
        }
    }
}


// ------------------------------------- mechanisms E–H (long tail, round 2, 2026-09-12)

/// A `.pn` restarts the numbering at the page it appears on, always.
///
/// `pnCheckpoints` used to drop a checkpoint whose VALUE equalled the last one recorded
/// — a guard that compared against the previous checkpoint's number instead of against
/// the number this page would otherwise have taken, so every restart to an already-used
/// number was thrown away.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/REF/CTRL-K.H1`:
/// five pages numbered 1–5, then a mid-document `.pn1`, and WS7 numbers the remaining
/// sheets 6, 7, 8, 9 as pages 1, 2, 3, 4 — which is also the parity its own `^K`
/// even-page header rule reads.
@Test func pnReanchorsTheCountEvenWhenItsNumberRepeats() {
    var src: [UInt8] = []
    for piece in ["one", ".pa", "two", ".pa", "three", ".pn1", "four", ".pa", "five"] {
        src += bytes(piece) + HARD
    }
    let doc = parseWS(src)
    let cps = pnCheckpoints(doc)
    #expect(cps.count == 2, "\(cps)")
    #expect(cps[0].blockIndex == 0 && cps[0].pn == 1, "\(cps)")
    #expect(cps[1].pn == 1 && cps[1].blockIndex > 0, "\(cps)")
    let pages = docToPagelines(doc, printed: true)
    // the `.pn1` sits on the third page, which it re-anchors to 1
    #expect(resolvePageNumbers(cps, pages) == [1, 2, 1, 2],
            "\(resolvePageNumbers(cps, pages))")
}

/// `^K` in a `.h#`/`.f#` line kills the blanks after it — even pages only.
///
/// WordStar's own file-format document, quoted verbatim inside the corpus document that
/// tests it (`sawyer/REF/CTRL-K.H1`): "In a header or footer line, on even numbered
/// pages all blanks following the ^K are suppressed."
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on that document:
/// `.h1 ^K<55 blanks>Header / #` prints at x 453.6pt on an odd page (left margin 57.6 +
/// 55 columns) and at **64.8pt** on an even one — the left margin plus ONE column, so
/// exactly one column survives the run; the same pair for its `.f1`, and 482.4/64.8 for
/// its second, 59-blank `.h1`.
@Test func ctrlKSuppressesHeaderBlanksOnEvenPages() {
    let text = "\u{0B}" + String(repeating: " ", count: 55) + "Header / #"
    #expect(ctrlKEvenPage(text, 3) == text)
    #expect(ctrlKEvenPage(text, 2) == " Header / #")
    // a blank run NOT introduced by a ^K is untouched on either parity
    let plain = "A" + String(repeating: " ", count: 9) + "B"
    #expect(ctrlKEvenPage(plain, 2) == plain)
    // and the rule reaches the resolved header line the printed page draws
    var src = bytes(".h1 ") + [0x0b] + bytes(String(repeating: " ", count: 55))
    src += bytes("Header / #")
    src += HARD
    src += bytes("body")
    src += HARD
    src += bytes(".pa")
    src += HARD
    src += bytes("body")
    src += HARD
    let doc = parseWS(src)
    func headerText(_ pageNo: Int) -> String? {
        resolveHeadFootLines(doc, pageNo: pageNo, pageHeight: 792, lead: 12.0, size: 12,
                             left: 57.6, printed: true)?.headers.first?.text
    }
    // the 0x0B survives an odd page and costs nothing (`hfRuns` strips it with every
    // other control byte, as every view always has)
    #expect(headerText(1) == "\u{0B}" + String(repeating: " ", count: 55) + "Header / 1",
            "\(String(describing: headerText(1)))")
    #expect(headerText(2) == " Header / 2", "\(String(describing: headerText(2)))")
}

/// A note's own TAB positions its text; the hang column yields to it.
///
/// A note's text stream can carry a nested type-9 tab block — the same one a body line
/// uses, second word the absolute tab size in HMIs — and real WS7 starts the note's text
/// in that column. `parseNote` skipped every nested block that was not the internal tag,
/// so the number was thrown away and `notesMarkerPadCols`'s computed hang column (widest
/// marker + 2) positioned every note instead.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on `sawyer/REF/NOTES.TST`,
/// left margin 57.6pt: its footnotes tab to HMI 540 and WS7 prints "Footnote One." at
/// 79.2pt (column 3); its endnotes tab to HMI 900 and print "Endnote one." at 93.6pt
/// (column 5); its annotations tab nothing and print "Annotation One" at 86.4pt (column
/// 4) — tag "AC1" plus the marker's own single space. The engine put all three at column
/// 5. `-SCREEN.WS` and `DISPLAY.WS`, the documents the hang column was measured on, tab
/// BOTH their notes to column 5, so they render identically either way.
@Test func aNoteTabsItsOwnTextWhereTheDocumentSays() {
    let hmi: [UInt8] = [0x1c, 0x02]                       // 540 little-endian
    let tab = ws7Block(0x09, payload: hmi + hmi + [0x20, 0x01])
    var content: [UInt8] = [0x01, 0x00, 0x09, 0x80, 0x33]
    content += ws7Block(0x03, payload: [0x00, 0x00, 0x00, 0x00, 0x33])
    content += tab
    content += bytes("Footnote One.")
    content += HARD
    var src = bytes("body")
    src += ws7Block(0x03, payload: content)
    src += bytes(" more")
    src += HARD
    let doc = parseWS(src)
    let footnotes = doc.notes.filter { $0.kind == .footnote }
    #expect(footnotes.first?.textIndents == [3],
            "\(doc.notes.map { $0.textIndents })")
    func rendered(_ marker: String, _ indents: [Int]) -> String {
        let rows = noteWrapLines(marker: marker, texts: ["Footnote One."], width: 65,
                                 tagLine: 0, separateSpans: true, indents: indents)
        return rows.first.map { $0.spans.map(\.text).joined() } ?? ""
    }
    #expect(rendered("1.", [3]) == "1. Footnote One.")     // column 3
    #expect(rendered("(1)", [5]) == "(1)  Footnote One.")  // column 5
    // a tab at or left of where the marker already ends leaves no gap
    #expect(rendered("(1)", [2]) == "(1)Footnote One.")
    // and a note that tabs nothing keeps the previous join exactly
    #expect(rendered("1.", []) == "1.Footnote One.")
}

/// A `.fo` reaches the page it appears on; a `.he` does not.
///
/// A header is emitted at the TOP of a page, so a `.he`/`.h#` read after that page's
/// first line cannot reach it. A footer is emitted at the BOTTOM, so a `.fo`/`.f#` read
/// anywhere before the page ends still governs it. Both took the header's rule, which
/// put every footer change one page late.
///
/// MEASURED against real WS7 (ws7-prints/v4, PRISTINE.EXE) on
/// `sawyer/MACROS/HOLYMAC/8MAC`, which sets `.fo<31 blanks>#` after a blank line — so
/// page 1 has already begun — and clears it with a bare `.fo` immediately AFTER its
/// first page break. WS7 prints "286" at 280.8pt (column 31, exactly where the `#` sits)
/// at the foot of page 1 and NO footer on pages 2–10; from the same commands it prints
/// NO header on page 1 and "HOLY MACRO!  #" on 2–10.
@Test func aFooterGovernsThePageItIsReadOn() {
    var src: [UInt8] = HARD
    for piece in [".he HEAD #", ".fo FOOT #", "one", ".pa", ".fo", "two"] {
        src += bytes(piece) + HARD
    }
    let pages = docToPagelines(parseWS(src), printed: true)
    #expect(pages.count >= 2, "\(pages.count)")
    #expect(pages[0].footers[1] == "FOOT #", "\(pages[0].footers)")
    #expect(pages[0].headers.isEmpty, "\(pages[0].headers)")   // `.he` is one line late
    #expect(pages[1].footers.isEmpty, "\(pages[1].footers)")   // the bare `.fo` cleared it
    #expect(pages[1].headers[1] == "HEAD #", "\(pages[1].headers)")
}

// MARK: - planning #270 item 34 / triage Q4 — WordStar's auto-leading, measured
//
// Five probe documents authored, printed through ctrl-kd's own DOSBox-X harness against
// the PRISTINE.EXE install (`tools/wordstar_harness.sh ws7`) and decoded with
// `tools/pcl_text.py`, 2026-09-14. Jon's ruling 2026-09-13: "Probe is fine. It would be
// best to figure out the WordStar rule and match it."
//
//   advance(line N) = max( the size CARRIED OUT OF line N-1,
//                          every font size declared anywhere ON line N )
//
// and a line carries OUT its LAST span's font size when that font is PROPORTIONAL, the
// document default otherwise. The whole formula is gated on `.lh a` / `.lh auto` —
// auto-leading is a MODE a document turns on, not a state inferred from the presence of
// proportional fonts. Full derivation in `fontLeadPt`'s own doc comment and the triage
// doc. Ports of ctrl-kd's own tests in `tests/test_pcl_v4_untriaged_fixes.py`.

/// The printed baseline y of the first text op showing each word.
private func printedBaselines(_ data: [UInt8], _ words: [String]) -> [String: Double] {
    let spans = contentSpans(emitPDF(parseWS(data), mode: .printed,
                                     options: EmitOptions(pageNumbers: .off)))
    var out: [String: Double] = [:]
    for word in words {
        if let span = spans.first(where: { $0.text.hasPrefix(word) }), let y = span.y {
            out[word] = y
        }
    }
    return out
}

@Test func lhAutoIsAModeAndANumericLHSwitchesItOff() {
    // `.lha`, written with no space, needs its own repair: the shared dot-name scanner
    // takes up to THREE letters and was swallowing the argument into the name, so
    // `sawyer/DEFAULT/PRINT.TST` and `sawyer/PSPRINT.TST` — which both write it that
    // way — were not being read as asking for auto-leading at all.
    for spelling in [".lh a", ".lh auto", ".lha", ".LH AUTO"] {
        var src = ws7Block(0x00, payload: [])
        src += bytes(spelling)
        src += HARD
        src += bytes("Some ordinary prose for the detector.")
        src += HARD
        #expect(parseWS(src).blocks.last?.lhAuto == true, "\(spelling)")
    }
    var mixed = ws7Block(0x00, payload: [])
    for piece in [".lh a", "Before.", ".lh 8", "After."] {
        mixed += bytes(piece)
        mixed += HARD
    }
    let modes = parseWS(mixed).blocks.filter { $0.kind == .para }.map(\.lhAuto)
    #expect(modes == [true, false], "\(modes)")
}

@Test func noAutoLeadingWithoutLhAutoHoweverBigTheFont() {
    // The ERROR.WS shape, and the reason `fontLeadCapPt` is retired.
    // `sawyer/FONTS/PS/ERROR.WS` carries 72pt and 42pt proportional font blocks and no
    // `.lh` of any kind, and real WS7 prints it at a flat 12.0pt throughout. No ceiling
    // is needed to explain that — the document never asked for auto-leading.
    var data = ws7Block(0x00, payload: [])
    data += bytes("Prose padding so the detector reads this as a document.")
    data += HARD
    data += fontBlock(helvTypestyle(), points: 72.0, styleBits: 0x8000)
    data += bytes("Huge")
    data += HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
    data += bytes("Small")
    data += HARD
    let ys = printedBaselines(data, ["Huge", "Small"])
    #expect(ys["Huge"].flatMap { y in ys["Small"].map { y - $0 } } == 12.0, "\(ys)")
}

@Test func aLinesOwnFontRaisesItsOwnAdvance() {
    // Not the line after it. The probe ran the identical case twice, once with the
    // carried state virgin and once established, and got identical numbers — so the
    // VIRGIN/ESTABLISHED distinction the old model kept is gone with it.
    var data = ws7Block(0x00, payload: [])
    data += bytes(".lh a")
    data += HARD
    data += bytes("Prose padding so the detector reads this as a document.")
    data += HARD
    data += bytes("Base")
    data += HARD
    data += fontBlock(helvTypestyle(), points: 24.0, styleBits: 0x8000)
    data += bytes("Big")
    data += HARD
    let ys = printedBaselines(data, ["Base", "Big"])
    #expect(ys["Base"].flatMap { y in ys["Big"].map { y - $0 } } == 24.0, "\(ys)")
}

@Test func aProportionalSizeCarriesThroughABlankLine() {
    // A blank line has no spans, so it carries its predecessor's answer through
    // unchanged and advances by it: 24 for the blank, 24 again for the 12pt line after
    // it (whose own max is still the carried 24).
    var data = ws7Block(0x00, payload: [])
    data += bytes(".lh a")
    data += HARD
    data += bytes("Prose padding so the detector reads this as a document.")
    data += HARD
    data += fontBlock(helvTypestyle(), points: 24.0, styleBits: 0x8000)
    data += bytes("Big")
    data += HARD
    data += HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
    data += bytes("Small")
    data += HARD
    let ys = printedBaselines(data, ["Big", "Small"])
    #expect(ys["Big"].flatMap { y in ys["Small"].map { y - $0 } } == 48.0, "\(ys)")
}

@Test func aFixedPitchFontRaisesItsOwnLineButCarriesNothing() {
    // The half of the old rule that was right and the half that was wrong, in one
    // fixture. `PREVIEW.WS` is the oracle: its trailing Courier-20pt line is entered at
    // the carried 24 (its own 20 loses the max), and the six blank lines after it
    // advance at 12, not 20 — 84.0pt to the next real line, seven line-feeds at the
    // document default.
    var data = ws7Block(0x00, payload: [])
    data += bytes(".lh a")
    data += HARD
    data += bytes("Prose padding so the detector reads this as a document.")
    data += HARD
    data += bytes("Base")
    data += HARD
    data += fontBlock(courierTypestyle(), points: 20.0, width: 90)
    data += bytes("Fixed")
    data += HARD
    data += HARD
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
    data += bytes("After")
    data += HARD
    let ys = printedBaselines(data, ["Base", "Fixed", "After"])
    // its OWN line rises to 20 (entered from the plain 12pt default)
    #expect(ys["Base"].flatMap { y in ys["Fixed"].map { y - $0 } } == 20.0, "\(ys)")
    // and it carries NOTHING: blank 12 + line 12
    #expect(ys["Fixed"].flatMap { y in ys["After"].map { y - $0 } } == 24.0, "\(ys)")
}

@Test func theLargestFontOnALineGovernsItWhicheverEndItSitsAt() {
    // A line's own advance is the max of every font on it; what carries out is the font
    // in force at its END. The probe's mid-line cases pin both halves.
    func fixture(bigFirst: Bool) -> [UInt8] {
        var data = ws7Block(0x00, payload: [])
        data += bytes(".lh a")
        data += HARD
        data += bytes("Prose padding so the detector reads this as a document.")
        data += HARD
        data += bytes("Base")
        data += HARD
        data += fontBlock(helvTypestyle(), points: bigFirst ? 24.0 : 12.0,
                          styleBits: 0x8000)
        data += bytes("Alpha ")
        data += fontBlock(helvTypestyle(), points: bigFirst ? 12.0 : 24.0,
                          styleBits: 0x8000)
        data += bytes("omega")
        data += HARD
        data += bytes("Next")
        data += HARD
        return data
    }
    var ys = printedBaselines(fixture(bigFirst: true), ["Base", "Alpha", "Next"])
    #expect(ys["Base"].flatMap { y in ys["Alpha"].map { y - $0 } } == 24.0, "\(ys)")
    #expect(ys["Alpha"].flatMap { y in ys["Next"].map { y - $0 } } == 12.0, "\(ys)")
    ys = printedBaselines(fixture(bigFirst: false), ["Base", "Alpha", "Next"])
    #expect(ys["Base"].flatMap { y in ys["Alpha"].map { y - $0 } } == 24.0, "\(ys)")
    #expect(ys["Alpha"].flatMap { y in ys["Next"].map { y - $0 } } == 24.0, "\(ys)")
}
