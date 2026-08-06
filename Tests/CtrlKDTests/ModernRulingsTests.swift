import Testing
@testable import CtrlKD

/// The Modern layout rulings (2026-08-06) — Jon's second Modern review round, all six
/// rulings: endnotes to the document end, block margins honored, editor-time alignment
/// de-duplicated, only the author's blank lines make space, running heads kept, and
/// driver character substitutions are content. Ports of the tests under
/// `tests/test_ctrlkd.py`'s "Modern layout rulings" banner. The printed digests must
/// NOT move (pinned elsewhere).

/// The raw content streams of a PDF, in order — Python's
/// `re.findall(rb'stream\r?\n(.*?)endstream', pdf, re.S)`.
func pdfContentStreams(_ pdf: [UInt8]) -> [[UInt8]] {
    let open = bytes("stream\n")
    let close = bytes("endstream")
    var out: [[UInt8]] = []
    var i = 0
    while i + open.count <= pdf.count {
        if Array(pdf[i..<i + open.count]) == open {
            var j = i + open.count
            while j + close.count <= pdf.count, Array(pdf[j..<j + close.count]) != close {
                j += 1
            }
            out.append(Array(pdf[(i + open.count)..<j]))
            i = j + close.count
        } else {
            i += 1
        }
    }
    return out
}

@Test func modernPDFEndnotesCollectAtDocumentEnd() throws {
    // Ruling 1 (M1): Word sends \ftnalt notes to the back, and Modern PDF is the printed
    // Modern RTF — so endnotes flow after the last body line (never the page-bottom
    // footnote area), inline-marked in Word's own lowercase roman so footnote [1] and
    // endnote [i] cannot collide.
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("The referenced line")
    data += ws7Note(bytes("The endnote text itself."), cmd: 0x04, number: 0)
    data += bytes(" continues after.") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    let shown = contentSpans(pdf)
    #expect(shown.contains { $0.text == "i" })            // inline roman marker
    let labelY = try #require(shown.first { $0.text == "[i]" }?.y)
    let lastBodyY = try #require(shown.first { $0.text == "honest." }?.y)
    #expect(lastBodyY - labelY > 0 && lastBodyY - labelY < 80)   // flows just below body
    #expect(labelY > 300)                                        // not bottom-anchored
}

@Test func modernPDFBlockMarginsIndentAndNarrowTheMeasure() throws {
    // Ruling 2 (M2): a block's own .lm/.rm are the document's explicit choices and win
    // in Modern exactly as its fonts do. WordStar's stamped .lm spaces come off the
    // front so the indent isn't applied twice.
    var data = ws7Block(0x00)
    data += bytes("Full width prose before the quotation, ordinary and plain.") + HARD
    data += bytes(".lm 8") + HARD + bytes(".rm 58") + HARD
    data += bytes("       An indented quotation, with enough words in it that the "
        + "line has to wrap inside its own narrowed measure to pass.") + HARD
    data += bytes(".lm 1") + HARD + bytes(".rm 65") + HARD
    data += bytes("Back to the full measure after the quotation ends here.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    let shown = contentSpans(pdf)
    let xQuote = try #require(shown.first { $0.text == "An" }?.x)
    let xBack = try #require(shown.first { $0.text == "Back" }?.x)
    #expect(abs(xQuote - (72.0 + 7.0 * 7.2)) < 0.1)       // .lm 8 = 7 columns in
    #expect(abs(xBack - 72.0) < 0.1)
}

@Test func modernAlignmentTagStripsTheSpacesThatImplementedIt() throws {
    // Ruling 3 (M3): WordStar 5+ aligned at EDITOR time — the file carries both the tag
    // and the spaces that implemented it. The spaces come off and the tag does the work;
    // the visible text lands dead center of the measure.
    var data = ws7Block(0x00)
    data += bytes("Padding prose line one, entirely ordinary text, for balance.") + HARD
    data += bytes(".oc on") + HARD
    data += bytes("                    Centered Headline") + HARD
    data += bytes(".oc off") + HARD
    data += bytes("More plain prose to close the document, again fully ordinary.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    let x = try #require(contentSpans(pdf).first { $0.text == "Centered" }?.x)
    let w = stringWidthPt("Centered Headline", "Times-Roman", 14)
    #expect(abs(x - (72.0 + (468.0 - w) / 2)) < 0.5)
}

@Test func modernDotCommandBlockSplitInventsNoBlank() throws {
    // Ruling 4 (M4): command codes are invisible — a block boundary made by a dot
    // command adds no space; the author's own blank line still does.
    func gap(_ mid: [UInt8]) throws -> Double {
        var data = ws7Block(0x00)
        data += bytes("First paragraph line of plain prose, long enough to matter.") + HARD
        data += mid
        data += bytes("Second paragraph line of plain prose, also long enough.") + HARD
        let shown = contentSpans(emitPDF(parseWS(data), mode: .modern))
        let y1 = try #require(shown.first { $0.text == "First" }?.y)
        let y2 = try #require(shown.first { $0.text == "Second" }?.y)
        return y1 - y2
    }
    #expect(abs((try gap(bytes(".cp 4") + HARD)) - 16.8) < 0.1)   // dot command: one lead
    #expect(abs((try gap(HARD)) - 33.6) < 0.1)                    // author blank: two
}

@Test func modernRunningHeadsReplayWithPageNumbers() throws {
    // Ruling 5 (M5): Modern keeps headers. They replay per page (state in force when the
    // page takes content), live in the top margin zone, and WordStar's # token becomes
    // the page number.
    var data = ws7Block(0x00)
    data += bytes(".he Chapter / #") + HARD
    data += bytes("Page one prose, plain and ordinary, enough for the detector.") + HARD
    data += bytes(".pa") + HARD
    data += bytes("Page two prose, also plain and ordinary, and long enough too.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    let streams = pdfContentStreams(pdf)
    #expect(streams.count >= 2)
    for (pi, stream) in streams.prefix(2).enumerated() {
        let shown = contentSpans(stream)
        #expect(shown.contains { $0.text == "Chapter" && ($0.y ?? 0) > 720 })
        #expect(shown.contains { $0.text == String(pi + 1) && ($0.y ?? 0) > 720 })
    }
}

@Test func modernRTFCarriesRunningHeadsAndStripsAlignSpaces() {
    // Rulings 3 and 5 on the RTF side: a real \header destination with Word's own
    // \chpgn page number, and center/right paragraphs shed the spaces that implemented
    // their alignment.
    var data = ws7Block(0x00)
    data += bytes(".he Chapter / #") + HARD
    data += bytes(".oc on") + HARD
    data += bytes("          A Centered Title") + HARD
    data += bytes(".oc off") + HARD
    data += bytes("Plain closing prose, quite ordinary and long.") + HARD
    let rtf = emitRTF(parseWS(data), mode: .modern)
    #expect(rtf.contains(#"{\header \pard\plain \f0\fs22 {Chapter / {\chpgn }}\par}"#))
    #expect(rtf.contains("A Centered Title"))
    #expect(!rtf.contains("  A Centered Title"))          // the tag does the work
}

@Test func modernRTFDotCommandSplitInventsNoPar() throws {
    // Ruling 4 on the RTF side: \par count between paragraphs follows the author's
    // blank lines, never the block structure.
    func parCount(_ mid: [UInt8]) throws -> Int {
        var data = ws7Block(0x00)
        data += bytes("First paragraph line of plain prose, long enough to matter.") + HARD
        data += mid
        data += bytes("Second paragraph line of plain prose, also long enough.") + HARD
        let rtf = emitRTF(parseWS(data), mode: .modern)
        let from = try #require(rtf.range(of: "matter."))
        let to = try #require(rtf.range(of: "Second"))
        let seg = rtf[from.lowerBound..<to.lowerBound]
        return seg.components(separatedBy: #"\par"#).count - 1
    }
    #expect(try parCount(bytes(".cp 4") + HARD) == 1)
    #expect(try parCount(HARD) == 2)
}

@Test func modernAppliesLJ6DTPCharacterSubstitutions() {
    // Ruling 7 (M7): the driver's patched slots are CONTENT — an em dash is an em dash
    // in any century — so Modern applies them (proportional faces only, the driver's own
    // rule). The page art stays print-time.
    var data = ws7Block(0x00, payload: bytes("pLJ6DTP") + [0x00, 0x00, 0x00, 0x80])
    data += fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
    data += bytes("word_word") + HARD
    data += bytes("Plain padding prose, ordinary and long enough to balance it.") + HARD
    let doc = parseWS(data)
    #expect(doc.printerDriver == "LJ6DTP")
    let pdf = emitPDF(doc, mode: .modern)
    #expect(contains(pdf, bytes("word") + [0x97] + bytes("word")))   // '_' -> em dash (cp1252)
}

@Test func noteRefsPrefixedSchemeMatchesMarkdownLabels() {
    // Ruling 2026-08-06 (M8, round 2 follow-up): --note-refs prefixed shows the Markdown
    // emitter's own labels — footnotes bare, endnotes e1, annotations a1 — in PDF, RTF,
    // and HTML alike. `word` (the default) stays exactly what displayed before:
    // arabic/roman/tags. Ids and structure never move; only the visible mark text does.
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += bytes("One") + ws7Note(bytes("Foot text."), cmd: 0x03, number: 0)
    data += bytes(" two") + ws7Note(bytes("End text."), cmd: 0x04, number: 0)
    data += bytes(" three") + ws7Note(bytes("Anno text."), cmd: 0x05, number: 0)
    data += bytes(" done.") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)

    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(noteRefs: .prefixed))
    let texts = contentSpans(pdf).map(\.text)
    #expect(texts.contains("e1") && texts.contains("[e1]"))   // endnote, inline + end
    #expect(texts.contains("a1") && texts.contains("[a1]"))   // annotation likewise
    #expect(!texts.contains("i"))                             // no roman under prefixed

    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(noteRefs: .prefixed))
    #expect(rtf.contains(#"{\super e1}"#))                    // custom mark, not \chftn
    #expect(rtf.contains(#"{\super a1}"#))
    let word = emitRTF(doc, mode: .modern)
    #expect(!word.contains(#"{\super e1}"#))                  // default keeps \chftn

    let html = emitHTML(doc, mode: .modern, options: EmitOptions(noteRefs: .prefixed))
    #expect(html.contains(">e1</a></sup>"))
    #expect(html.contains("id=\"enref1\""))                   // ids stay structural
}

// ================= Comments become first-class (2026-08-06, M9) =================
//
// Both WordStar comment forms — ^ON note blocks and '..'/'.ig' dot lines — unify into
// Note(kind: .comment) with `origin` provenance, each emitting a reference mark at its
// position (position, not ink). --comments stays the visibility gate; printed is always
// silent about them.

@Test func bothCommentOriginsUnifyAndRefsStayAligned() {
    var data = ws7Block(0x00)
    data += bytes(".. a disabled command lives here") + HARD
    data += bytes("First line of prose, referencing")
    data += ws7Note(bytes("The footnote text."), cmd: 0x03, number: 0)
    data += bytes(" a note.") + HARD
    data += bytes(".ig the long-form comment syntax") + HARD
    data += bytes("Second line of prose to close the document, quite plainly.") + HARD
    let doc = parseWS(data)
    let comments = doc.notes.filter { $0.kind == .comment }
    #expect(comments.map(\.origin) == [.dotDot, .dotIG])
    #expect(comments.first?.text == "a disabled command lives here")
    // the mark BEFORE the footnote must not derail its resolution: the footnote still
    // renders as footnote 1 in every format
    let md = emitMarkdown(doc, mode: .modern)
    #expect(md.contains("[^1]") && md.contains("[^1]: The footnote text."))
    let texts = contentSpans(emitPDF(doc, mode: .modern)).map(\.text)
    #expect(texts.contains("[1]"))                    // page-bottom footnote
}

@Test func commentsHiddenByDefaultAndPrintedAlwaysSilent() {
    var data = ws7Block(0x00)
    data += bytes("Visible prose line one, plain and ordinary for the detector.") + HARD
    data += bytes(".. the hidden aside") + HARD
    data += bytes("Visible prose line two, also plain and entirely ordinary.") + HARD
    let doc = parseWS(data)
    for out in [emitText(doc, mode: .modern), emitMarkdown(doc, mode: .modern),
                emitHTML(doc, mode: .modern), emitRTF(doc, mode: .modern)] {
        #expect(!out.contains("hidden aside"))        // gate stays closed
    }
    let keep = EmitOptions(notes: EmitOptions.allNotes)
    for out in [emitText(doc, mode: .printed, options: keep),
                emitRTF(doc, mode: .printed, options: keep)] {
        #expect(!out.contains("hidden aside"))        // printed: never
    }
    #expect(!contains(emitPDF(doc, mode: .printed, options: keep), bytes("hidden aside")))
}

@Test func commentsOptedInRenderPositionedWithOrigin() throws {
    var data = ws7Block(0x00)
    data += bytes("Alpha prose line, plain and ordinary, before the comment.") + HARD
    data += bytes(".. the surfaced aside") + HARD
    data += bytes("Omega prose line, plain and ordinary, after the comment.") + HARD
    let doc = parseWS(data)
    let keep = EmitOptions(notes: EmitOptions.allNotes)
    var texts = contentSpans(emitPDF(doc, mode: .modern, options: keep)).map(\.text)
    #expect(texts.contains("[c1]"))                   // end block, c-labeled
    #expect(!texts.contains("c1"))                    // word scheme: markless
    let prefixed = EmitOptions(notes: EmitOptions.allNotes, noteRefs: .prefixed)
    texts = contentSpans(emitPDF(doc, mode: .modern, options: prefixed)).map(\.text)
    #expect(texts.contains("c1"))                     // prefixed: visible mark
    let md = emitMarkdown(doc, mode: .modern, options: keep)
    #expect(md.contains("[^c1]") && md.contains("[^c1]: the surfaced aside"))
    let rtf = emitRTF(doc, mode: .modern, options: keep)
    let alpha = try #require(rtf.range(of: "Alpha"))
    let aside = try #require(rtf.range(of: "the surfaced aside"))
    let omega = try #require(rtf.range(of: "Omega"))
    #expect(alpha.lowerBound < aside.lowerBound && aside.lowerBound < omega.lowerBound)
    let html = emitHTML(doc, mode: .modern, options: keep)
    #expect(html.contains("data-note-kind=\"comment\""))
}

@Test func dotCommentBeforeBlankCreatesNoPhantomLine() {
    // The mark defers to the next CONTENT line: a '..' line followed by the author's
    // blank must not close a phantom line holding only the mark — printed line structure
    // is identical with and without the comment.
    let withComment = parseWS(ws7Block(0x00)
        + bytes("First paragraph line of plain prose, long enough to matter.") + HARD
        + bytes(".. noise") + HARD + HARD
        + bytes("Second paragraph line of plain prose, also long enough.") + HARD)
    let without = parseWS(ws7Block(0x00)
        + bytes("First paragraph line of plain prose, long enough to matter.") + HARD + HARD
        + bytes("Second paragraph line of plain prose, also long enough.") + HARD)
    #expect(emitPDF(withComment, mode: .printed) == emitPDF(without, mode: .printed))
}

@Test func runningHeadToggleBytesBecomeStylesNotGlyphs() throws {
    // Round 3 (2026-08-06, M10): LJ6DTP's `.h1` carries raw ^B bold toggles and a U+2219
    // dot; measuring toggles as glyphs made header letters overlap. hfRuns interprets
    // them as styles, maps the dot to the cp1252 bullet, and a control-bytes-only head
    // (LJ6DTP's `.f1` = two 0x0F bytes) empties out entirely.
    let runs = hfRuns("  \u{02}\u{02}Title \u{2219} #\u{02} tail")
    #expect(runs.first?.text == "  " && runs.first?.styles == [])   // baked spaces survive
    let texts = runs.map(\.text).joined()
    #expect(!texts.contains("\u{02}") && !texts.contains("\u{2219}") && texts.contains("\u{2022}"))
    #expect(runs.contains { $0.styles.contains(.bold) })            // bold recognized
    #expect(hfRuns("\u{0F}\u{0F}").isEmpty)                         // junk head -> nothing
    // end-to-end: a doc with a toggle-carrying head renders overlap-free (words strictly
    // ordered, no negative advance) in the modern PDF
    var data = ws7Block(0x00)
    data += bytes(".he ") + [0x02] + bytes("Big Bold Header") + [0x02] + bytes(" / #") + HARD
    data += bytes("Page one prose, plain and ordinary and long enough.") + HARD
    data += bytes(".pa") + HARD
    data += bytes("Page two prose, also plain, ordinary, long enough.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    let first = try #require(pdfContentStreams(pdf).first)
    let hdr = contentSpans(first).filter { ($0.y ?? 0) > 720 }
    let words = hdr.map(\.text)
    #expect(words.contains("Big") && !words.contains("\u{02}Big"))
    let xs = hdr.compactMap(\.x)
    #expect(xs == xs.sorted())                                      // strictly left-to-right
}

@Test func modernDrawsFontlessCP437SquareBulletAsVector() {
    // Round 3 (2026-08-06, M11): -README's list bullets are cp437 0xFE black squares in
    // FONTLESS spans — no cp1252 slot, and the graphics vector path used to require a
    // font entry, so they rendered '?'. Modern now draws the geometry for fontless spans
    // too; printed keeps its fontless-untouched doctrine (digests prove it).
    var data = ws7Block(0x00)
    data += bytes("A paragraph of ordinary prose before the bulleted list here.") + HARD
    data += [0xFE] + bytes(" First item of the list, plain prose and clear.") + HARD
    data += bytes("A closing paragraph of ordinary prose after the list ends.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .modern)
    #expect(!contains(pdf, bytes("(?")))                  // no mangled bullet
    #expect(contains(pdf, bytes("re f")))                 // a filled vector rect
    #expect(contentSpans(pdf).contains { $0.text == "First" })   // text continues after it
}

// ================= The layout facade (task #15, 2026-08-06) =================

@Test func modernFlowIsThePublicSemanticContract() throws {
    // modernSemanticFlow is the single implementation of the M-rules, consumed by the
    // PDF's measuring adapter, the Mac app's text stack, and the `layout` JSON emitter.
    // Items carry columns, not points — consumers convert with their own metrics.
    var data = ws7Block(0x00)
    data += bytes(".oc on") + HARD
    data += bytes("     A Centered Heading") + HARD + bytes(".oc off") + HARD
    data += bytes(".lm 8") + HARD
    data += bytes("       An indented quotation line, plain prose and clear.") + HARD
    data += bytes(".lm 1") + HARD
    data += bytes("Body prose at the full measure")
    data += ws7Note(bytes("A footnote."), cmd: 0x03, number: 0)
    data += bytes(" continues.") + HARD
    let sem = modernSemanticFlow(parseWS(data))
    var paras: [(align: Alignment, indentCols: Double, runs: [SemanticRun],
                 footnotes: [SemanticFootnote])] = []
    for item in sem.items {
        if case .para(let align, let indentCols, _, let runs, let footnotes) = item {
            paras.append((align, indentCols, runs, footnotes))
        }
    }
    let centered = try #require(paras.first { $0.align == .center })
    #expect(centered.runs.first?.text.hasPrefix("A Centered") == true)   // M3 strip
    let quote = try #require(paras.first { $0.indentCols == 7 })         // M2 margins
    #expect(quote.runs.first?.text.hasPrefix("An indented") == true)     // lm stamp off
    let body = try #require(paras.first { $0.runs.contains { $0.ref != nil } })
    #expect(!body.footnotes.isEmpty)
    #expect(sem.notes[body.footnotes[0].index].text == "A footnote.")
}

@Test func layoutEmitterSerializesTheViewerContract() throws {
    // `-t layout`: format/version header, semantic modern flow, printed page-lines with
    // soft flags, and the invisible layer — enough for a renderer in any language, no
    // engine linked.
    var data = ws7Block(0x00)
    data += bytes(".. a hidden aside") + HARD
    data += bytes("First line of prose, plain and long enough here.") + HARD
    data += bytes("Second line of prose, also plain and long enough.") + HARD
    let doc = parseWS(data)
    let emitter = try #require(EmitterRegistry.standard.getEmitter("layout"))
    let out = try #require(emitter.emit(doc, .modern, EmitOptions()).asText)
    #expect(out.contains("\"format\": \"ctrl-kd-layout\""))
    #expect(out.contains("\"version\": 1"))
    #expect(out.contains("\"encoding\": \"cp437\""))
    #expect(out.contains("\"size_name\": \"Letter\""))
    #expect(out.contains("\"kind\": \"para\""))                 // semantic flow present
    #expect(out.contains("\"soft\""))                           // printed layer present
    #expect(out.contains("\"origin\": \"..\""))                 // dot-comment provenance
    #expect(out.contains("\"dot_positions\""))                  // Show Invisibles anchors
    #expect(EmitterRegistry.standard.formats().contains("layout"))   // CLI-reachable
    #expect(emitter.ext == ".json")
}
