import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

/// b24 engine wave, round 19 (RTF/HTML/MD/PDF wiring + CLI resolve/report/export layer)
/// — mirrors ctrl-kd's tests/test_pictures.py. One focused, fail-first-verified test per
/// mechanism rather than an exhaustive port.

// MARK: - fixtures

/// A minimal, real 2x1 mono `.PIX` file (row 0 always stored raw — no vertical-RLE
/// machinery needed for a one-row image), plus a document whose sole content is a pix
/// tag referencing it (`.pix` field wired, round 19's own span-marking mechanism).
private func onePixDoc(prtOptionsRaw: [UInt8]? = nil) -> (doc: Document, pixData: [UInt8]) {
    let pixData = buildPixBytes(gcols: 2, grows: 1, gfore: 1, pageRows: 1, pageCols: 8,
                                stpRows: 1, stpCols: 1, indexImg: [[1, 0, 0, 0, 0, 0, 0, 0]],
                                prtOptionsRaw: prtOptionsRaw)
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    // The pix tag stands ALONE on its own physical line -- the confirmed real-corpus
    // shape (every acceptance document's picture reference is its own paragraph).
    // PDF's own substitution deliberately SKIPS an image whose line shares other real
    // text (never silently drop content) -- see `pdfSharedLineNeverEmbeds` below for
    // that exact case, tested on purpose rather than by fixture accident.
    let doc = parseWS(bytes("Caption before.\r\n") + block + bytes("\r\nCaption after.\r\n"))
    return (doc, pixData)
}

/// A resolved, decoded `PixResult` for index 0, matching `onePixDoc()`'s own tag.
private func onePixResult(prtOptionsRaw: [UInt8]? = nil) throws -> PixResult {
    let (_, pixData) = onePixDoc(prtOptionsRaw: prtOptionsRaw)
    let (gcols, grows, _) = try pixDecode(pixData)
    let png = try pixToPNG(pixData)
    var r = PixResult(index: 0, rawPath: #"C:\PIX\FIGURE1.PIX"#, resolvedPath: "/tmp/FIGURE1.PIX",
                      rawBytes: pixData, png: png, gcols: gcols, grows: grows)
    if let size = pixPhysicalSizeIn(pixData) {
        r.widthIn = size.widthIn
        r.heightIn = size.heightIn
    }
    return r
}

// MARK: - RTF

@Test func rtfEmbedRendersPictDestination() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(rtf.contains(#"\pict\pngblip"#))
    #expect(rtf.contains(#"\picw2\pich1"#))
    #expect(!rtf.contains("[image: FIGURE1.PIX]"))
}

@Test func rtfEmbedUsesPrintOptionsGoalSizeWhenPresent() throws {
    // 4680 dp = 6.5in -> 9360 twips; 1440 dp = 2.0in -> 2880 twips.
    let result = try onePixResult(prtOptionsRaw: buildPrtOptions(rowDp: 1440, colDp: 4680))
    let (doc, _) = onePixDoc(prtOptionsRaw: buildPrtOptions(rowDp: 1440, colDp: 4680))
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(rtf.contains(#"\picwgoal9360\pichgoal2880"#))
}

@Test func rtfEmbedFallsBackTo96DPIGoalSizeWithoutPrintOptions() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    #expect(result.widthIn == nil)
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    // 2px * 15 twips/px = 30; 1px * 15 = 15.
    #expect(rtf.contains(#"\picwgoal30\pichgoal15"#))
}

@Test func rtfOffModeIsByteIdenticalToNoPixResults() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let off = emitRTF(doc, mode: .modern, options: EmitOptions(pictures: .off, pixResults: [result]))
    let bare = emitRTF(doc, mode: .modern, options: EmitOptions())
    #expect(off == bare)
    #expect(off.contains("[image: FIGURE1.PIX]"))
}

@Test func rtfMissFallsThroughToPlaceholder() throws {
    let (doc, _) = onePixDoc()
    // pixResults present but for a DIFFERENT index -- a miss, not an empty list.
    var miss = PixResult(index: 0, rawPath: #"C:\PIX\FIGURE1.PIX"#)
    miss.error = .unresolved
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [miss]))
    #expect(rtf.contains("[image: FIGURE1.PIX]"))
    #expect(!rtf.contains(#"\pict"#))
}

// MARK: - HTML

@Test func htmlEmbedRendersDataURI() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let html = emitHTML(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(html.contains("data:image/png;base64,"))
    #expect(html.contains("alt=\"FIGURE1.PIX\""))
    #expect(!html.contains("[image: FIGURE1.PIX]"))
}

@Test func htmlExportRendersRelativeLink() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let html = emitHTML(doc, mode: .modern, options: EmitOptions(
        pictures: .export, pixResults: [result], imageLinks: [0: "doc-images/FIGURE1.png"]))
    #expect(html.contains(#"src="doc-images/FIGURE1.png""#))
    #expect(!html.contains("data:image/png"))
}

@Test func htmlEmbedIncludesExplicitSizeWhenPrintOptionsPresent() throws {
    let result = try onePixResult(prtOptionsRaw: buildPrtOptions(rowDp: 1440, colDp: 4680))
    let (doc, _) = onePixDoc(prtOptionsRaw: buildPrtOptions(rowDp: 1440, colDp: 4680))
    let html = emitHTML(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(html.contains("width:6.500in"))
    #expect(html.contains("height:2.000in"))
}

@Test func htmlOffModeIsByteIdenticalToNoPixResults() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let off = emitHTML(doc, mode: .modern, options: EmitOptions(pictures: .off, pixResults: [result]))
    let bare = emitHTML(doc, mode: .modern, options: EmitOptions())
    #expect(off == bare)
}

// MARK: - Markdown

@Test func markdownEmbedAndExportRenderTheSameLinkShape() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let links = [0: "doc-images/FIGURE1.png"]
    let embed = emitMarkdown(doc, mode: .modern,
                             options: EmitOptions(pictures: .embed, pixResults: [result], imageLinks: links))
    let export = emitMarkdown(doc, mode: .modern,
                              options: EmitOptions(pictures: .export, pixResults: [result], imageLinks: links))
    #expect(embed == export)
    #expect(embed.contains("![FIGURE1.PIX](doc-images/FIGURE1.png)"))
}

@Test func markdownWithoutImageLinksFallsThroughToPlaceholder() throws {
    // pictures live, result resolved, but the caller never wrote the file (no
    // imageLinks entry) -- never a link to a file that doesn't exist.
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let md = emitMarkdown(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(md.contains(#"\[image: FIGURE1.PIX\]"#) || md.contains("[image: FIGURE1.PIX]"))
    #expect(!md.contains("![FIGURE1.PIX]"))
}

@Test func markdownPrintedModeFenceIsUntouchedByPictures() throws {
    // Printed mode's own body is emit_text's fenced facsimile -- pix_map/pictures are
    // never consulted there at all (round 17b's own fence-scoping lesson).
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let links = [0: "doc-images/FIGURE1.png"]
    let printed = emitMarkdown(doc, mode: .printed,
                               options: EmitOptions(pictures: .embed, pixResults: [result], imageLinks: links))
    let bare = emitMarkdown(doc, mode: .printed, options: EmitOptions())
    #expect(printed == bare)
}

// MARK: - PDF

@Test func pdfPrintedEmbedsImageXObject() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("/Subtype /Image")))
    #expect(contains(pdf, bytes("/ColorSpace /DeviceRGB")))
    #expect(contains(pdf, bytes("/XObject")))
    #expect(contains(pdf, bytes("/Im0 Do")))
    #expect(!contains(pdf, bytes("(\\[image: FIGURE1.PIX\\])")))
}

@Test func pdfOffModeIsByteIdenticalToNoPixResults() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let off = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .off, pixResults: [result]))
    let bare = emitPDF(doc, mode: .printed, options: EmitOptions())
    #expect(off == bare)
}

@Test func pdfSharedLineNeverEmbeds() throws {
    // A pix tag sharing its physical line with OTHER real text: substitution is
    // deliberately SKIPPED (never silently drop content) -- it renders as the ordinary
    // placeholder text instead, still correct, just not embedded. The XObject itself
    // may still be REGISTERED (built once per pix_results entry regardless of whether
    // any page actually places it -- "an XObject unused on a given page costs nothing
    // per the PDF spec", matching ctrl-kd's own unconditional-build shape); what must
    // never appear is the content-stream `Do` operator that would actually DRAW it.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let doc = parseWS(bytes("Before. ") + block + bytes(" After.\r\n"))
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(!contains(pdf, bytes("/Im0 Do")))
    #expect(contains(pdf, bytes("FIGURE1.PIX")))
}

// MARK: - PDF Modern (b24 round 22 — round 19's documented Modern scope cut, closed)

@Test func pdfModernEmbedPlacesAnImageXObjectNoPlaceholder() throws {
    // Round 22: a resolvable pix tag renders the real decoded image in Modern PDF too,
    // and the placeholder text is gone.
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("/Subtype /Image")))
    #expect(contains(pdf, bytes("/Im0 Do")))
    #expect(!contains(pdf, bytes("FIGURE1.PIX")))
}

@Test func pdfModernOffIsByteIdenticalToNoPixResults() throws {
    let (doc, _) = onePixDoc()
    let result = try onePixResult()
    let without = emitPDF(doc, mode: .modern, options: EmitOptions())
    let off = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .off, pixResults: [result]))
    #expect(without == off)
    #expect(!contains(off, bytes("/Im0 Do")))
    #expect(contains(off, bytes("FIGURE1.PIX")))
}

@Test func pdfModernMissKeepsPlaceholderTextNoXObject() throws {
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\NOPE.PIX"#.utf8))
    let doc = parseWS(bytes("Before.\r\n") + block + bytes("\r\nAfter.\r\n"))
    var miss = PixResult(index: 0, rawPath: #"C:\PIX\NOPE.PIX"#)
    miss.error = .unresolved
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [miss]))
    #expect(!contains(pdf, bytes("/Im0 Do")))
    #expect(contains(pdf, bytes("NOPE.PIX")))
}

@Test func pdfModernEmbedScalesToPrintOptionsSize() throws {
    // same sizing rule as Printed (shared `pixDimsPt`): the print-options record wins
    // when present -- 0.4in x 0.2in -> 28.8pt x 14.4pt (720 decipoints/inch).
    let prt = buildPrtOptions(rowDp: 144, colDp: 288)
    let (doc, _) = onePixDoc(prtOptionsRaw: prt)
    let result = try onePixResult(prtOptionsRaw: prt)
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("28.80 0 0 14.40")))
}

@Test func pdfModernTextSharingTheParaPreventsSubstitution() throws {
    // same never-drop-text rule as Printed: a pix tag sharing its paragraph with prose
    // keeps the placeholder text instead.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let doc = parseWS(bytes("Caption text ") + block + bytes("\r\n"))
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(!contains(pdf, bytes("/Im0 Do")))
    #expect(contains(pdf, bytes("FIGURE1.PIX")))
    #expect(contains(pdf, bytes("Caption")))    // Modern draws one word per Tj op
}

// MARK: - PDF notes-pagination path (b24 round 22 — the other round-19 scope cut, closed)

/// A document with a real footnote (so PDF routes through `layoutPrintedPages` — the
/// round-19 scope-cut path) AND an isolated pix tag on its own paragraph.
private func footnoteAndIsolatedPixDoc() -> Document {
    let note = ws7Note(bytes("A footnote."), cmd: 0x03, number: 0)
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    return parseWS(bytes("Body with a note.") + note + bytes("\r\n\r\n")
                   + block + bytes("\r\n\r\nAfter.\r\n"))
}

@Test func pdfNotesPaginationEmbedPlacesAnImageXObject() throws {
    // Round 22: a document with placeable notes paginates through the notes-aware
    // paginator, which now embeds too (this was -SCREEN.WS's documented gap).
    let doc = footnoteAndIsolatedPixDoc()
    #expect(hasPlaceableNotes(doc), "fixture must route through the notes paginator")
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("/Subtype /Image")))
    #expect(contains(pdf, bytes("/Im0 Do")))
    #expect(!contains(pdf, bytes("FIGURE1.PIX")))
    #expect(contains(pdf, bytes("A footnote.")))    // the notes area still renders
}

@Test func pdfNotesPaginationOffIsByteIdentical() throws {
    let doc = footnoteAndIsolatedPixDoc()
    let result = try onePixResult()
    let without = emitPDF(doc, mode: .printed, options: EmitOptions())
    let off = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .off, pixResults: [result]))
    #expect(without == off)
    #expect(contains(off, bytes("FIGURE1.PIX")))
}

@Test func pdfNotesPaginationMissKeepsPlaceholder() throws {
    let note = ws7Note(bytes("A footnote."), cmd: 0x03, number: 0)
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\NOPE.PIX"#.utf8))
    let doc = parseWS(bytes("Body with a note.") + note + bytes("\r\n\r\n")
                      + block + bytes("\r\n\r\nAfter.\r\n"))
    var miss = PixResult(index: 0, rawPath: #"C:\PIX\NOPE.PIX"#)
    miss.error = .unresolved
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [miss]))
    #expect(!contains(pdf, bytes("/Im0 Do")))
    #expect(contains(pdf, bytes("NOPE.PIX")))
}

@Test func pdfNotesPaginationEmbedScalesToPrintOptionsSize() throws {
    let prt = buildPrtOptions(rowDp: 144, colDp: 288)
    let doc = footnoteAndIsolatedPixDoc()
    let result = try onePixResult(prtOptionsRaw: prt)
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("28.80 0 0 14.40")))
}

@Test func pdfModernEmbedsImageAndRendersFootnoteTextTogether() throws {
    // b26-modern item 1 (ctrl-kd eeb052b): re-verifies round 22's two round-19 scope
    // cuts (image-embed + placeable-notes) together in MODERN mode specifically --
    // existing coverage exercised them separately (this file's own
    // `pdfModernEmbedPlacesAnImageXObjectNoPlaceholder` for the image alone; PRINTED
    // mode's sibling test above, `pdfNotesPaginationEmbedPlacesAnImageXObject`, for
    // image+notes together) but nothing pinned image+footnote+endnote all landing on
    // one Modern PDF page at once, the real -SCREEN.WS shape. Investigated as a live
    // regression risk for this item (ctrl-kd found it already correct on its own main
    // when it ported this item, no production change there) and found already correct
    // on sr's own main too; formalized here so it stays that way. PDF draws one word
    // per Tj operation (not the substring-joined phrase), so the verification joins
    // words the same way `ModernLineSpacingTests.swift`'s siblings already read spans.
    let doc = footnoteAndIsolatedPixDoc()
    #expect(!doc.notes.isEmpty, "fixture must carry a real footnote")
    let result = try onePixResult()
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    #expect(contains(pdf, bytes("/Subtype /Image")))
    #expect(contains(pdf, bytes("/Im0 Do")))
    #expect(!contains(pdf, bytes("FIGURE1.PIX")))
    let joined = contentSpans(pdf).map(\.text).joined(separator: " ")
    #expect(joined.contains("A footnote."))
}

// MARK: - PDF: reserved-placeholder advance (round 26 wave 3, fidelity_gate.py Finding A)

@Test func pdfPixReservesTheTagLinePlusItsContiguousBlanksNotTheRasterHeight() throws {
    // WordStar's own INSET convention: the author reserves the picture's print-time
    // footprint as blank PHYSICAL LINES in the source -- the tag's own line plus however
    // many blank lines follow it, contiguously, in the same block. Two blank physical
    // lines follow the tag here (the two extra `\r\n` pairs below), so the reserved band
    // is (1 + 2) lines at the document's own 12pt default lead = 36pt -- NOT the 14.4pt
    // raster height a print-options record gives this fixture (`buildPrtOptions(rowDp:
    // 144, ...)`, port of ctrl-kd's `_pix_reserved_advance`).
    let prt = buildPrtOptions(rowDp: 144, colDp: 288)
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let doc = parseWS(bytes("Caption before.\r\n") + block + bytes("\r\n\r\n\r\nCaption after.\r\n"))
    let result = try onePixResult(prtOptionsRaw: prt)

    // The blank placeholder lines are CONSUMED, not emitted as their own PageLines: one
    // page, exactly THREE lines (caption / image / caption), not six.
    let pages = docToPagelines(doc, printed: true, pixResults: [result], pictures: .embed)
    #expect(pages.count == 1)
    #expect(pages[0].count == 3, "the two reserved blanks must be consumed, not re-emitted")
    let imageLine = pages[0][1]
    #expect(imageLine.image != nil)
    #expect(imageLine.lead == 36.0, "reserved band: (1 tag + 2 blanks) * 12pt default lead")

    // Drawn position: WS7 places the picture FLUSH WITH THE TOP of its reserved band
    // (leaving the leftover 36 - 14.4 = 21.6pt of slack as blank space BELOW the image,
    // before "Caption after."), not flush with the band's bottom. Top offset 60pt
    // (default `.mt`+`.hm`) + first line's own 12pt lead = 720 y for "Caption before.";
    // the image band spends 36pt more (y=684), and the raster itself draws 21.6pt
    // higher than that bottom edge (y=705.6) -- port of ctrl-kd's `_page_stream` fix.
    let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: [result]))
    let text = latin1(pdf)
    #expect(text.contains("57.6 720.0 Td"), "\"Caption before.\" baseline")
    #expect(text.contains("28.80 0 0 14.40 57.60 705.60 cm /Im0 Do"),
            "image flush with the reserved band's TOP, not its bottom")
    #expect(text.contains("57.6 672.0 Td"), "\"Caption after.\" baseline, band's bottom + its own lead")
}

@Test func pdfPrintedPaginationIsIdenticalOffVsEmbed() throws {
    // b26-mtmb-general (-README.WS): pictures mode must never change WHERE a page
    // breaks, only how the image band is DRAWN (the b24 PIX round's own ruled design).
    // It used to: with the pix tag as a page's own FIRST line (the real-corpus shape --
    // -README's WORDSTAR.PIX opens the document), `off` renders the tag and its 8
    // contiguous following blank lines as ordinary PageLines, so
    // `layoutPrintedPagesPlain`'s own "first line on a page is free" pagination rule
    // credits only the TAG line's one-line advance -- the other 7 blanks still cost
    // normally. `embed` bundles all 8 source lines into ONE image PageLine (`.lead` =
    // the RESERVED BAND total, `pixReservedAdvance`) and that same "first line free"
    // rule credited the WHOLE bundled total, freeing 7 extra lines' worth of budget
    // `off` never got -- measured on -README.WS: `off`'s page 1 ends exactly where WS7's
    // own paper break does ("read the online version here:"); `embed`'s ran ~4-5 lines
    // longer ("The file OLDTIMES.WS is a sample..."). Fixed: an image PageLine's cost is
    // only credited ONE line's worth even as a page's own first line (see `cost`'s own
    // b26-mtmb-general note in `layoutPrintedPagesPlain`), matching `off`'s natural
    // per-line accumulation exactly.
    //
    // Reproduced synthetically (`.pl 24`, the pix tag as the document's own first
    // content, 8 blank lines after it, then enough body lines to force a natural page
    // break): both modes must break in EXACTLY the same places, checked by the LAST
    // real line of every page, not just total page count (which stayed 14/14 for
    // -README even while this bug was live -- later section breaks re-synced, masking
    // the interior drift).
    let pixData = buildPixBytes(gcols: 8, grows: 1, gfore: 1, pageRows: 1, pageCols: 8,
                                stpRows: 1, stpCols: 1, indexImg: [[UInt8](repeating: 0, count: 8)])
    let (gcols, grows, _) = try pixDecode(pixData)
    let png = try pixToPNG(pixData)
    var result = PixResult(index: 0, rawPath: #"C:\PIX\FIGURE1.PIX"#, resolvedPath: "/tmp/FIGURE1.PIX",
                           rawBytes: pixData, png: png, gcols: gcols, grows: grows)
    if let size = pixPhysicalSizeIn(pixData) {
        result.widthIn = size.widthIn
        result.heightIn = size.heightIn
    }

    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    var body = bytes(".pl 24") + HARD + block
    for _ in 1...8 { body += HARD }
    for i in 1...19 { body += bytes("Body line \(i).") + HARD }
    let doc = parseWS(body)

    func breaks(_ mode: EmitOptions.PixMode, pixResults: [PixResult] = []) -> [String?] {
        let pages = docToPagelines(doc, printed: true, pixResults: pixResults, pictures: mode)
        return pages.map { page -> String? in
            var last: String? = nil
            for l in page {
                if l.image != nil {
                    last = "<image>"
                    continue
                }
                let t = l.spans.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { last = t }
            }
            return last
        }
    }

    let offBreaks = breaks(.off)
    let embedBreaks = breaks(.embed, pixResults: [result])
    let expected: [String?] = ["Body line 5.", "Body line 18.", "Body line 19."]
    #expect(offBreaks == expected)
    #expect(embedBreaks == expected)
}

@Test func cliPDFModernMissDegradesWithStderrNote() throws {
    // Round 22: Modern PDF now embeds -- confirm the degradation contract holds on this
    // path too: an unresolvable tag keeps the placeholder in the PDF and writes the one
    // stderr note, conversion never fails.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\WS\INSET\PIX\NOPE.PIX"#.utf8))
    let source = bytes("Before.\r\n\r\n") + block + bytes("\r\n\r\nAfter.\r\n")
    var written: [String: [UInt8]] = [:]
    var err: [String] = []
    let env = CLIEnvironment(
        readFile: { path in
            guard path == "/in/DOC.WS" else { throw TestFSError.notFound }
            return source
        },
        writeFile: { path, data in written[path] = data },
        createDirectory: { _ in }, writeOut: { _ in }, writeErr: { line in err.append(line) },
        listDirectory: { _ in nil }, isFile: { _ in false }
    )
    let status = run(["--mode", "modern", "-t", "pdf", "/in/DOC.WS"], environment: env)
    #expect(status == ExitStatus.ok)
    let pdf = try #require(written["/in/DOC.pdf"])
    #expect(!contains(pdf, bytes("/Im0 Do")))
    #expect(contains(pdf, bytes("NOPE.PIX")))
    #expect(err.contains { $0.contains("NOPE.PIX") && $0.contains("not found") })
    // This tool is `sr`, not `ctrl-kd` (the Python reference it ports from) -- its own
    // stderr notes must self-identify as such, not carry the Python tool's name over.
    #expect(err.contains { $0.hasPrefix("sr: ") })
    #expect(!err.contains { $0.contains("ctrl-kd:") })
}

// MARK: - CLI resolve layer (piximg.py/pictures.py)

/// An in-memory filesystem: `[path: [entryName]]` for directories, `[path: bytes]` for
/// files — enough to drive `resolvePix`'s own case-insensitive walk without touching a
/// real disk.
private func fakeFSEnvironment(dirs: [String: [String]], files: [String: [UInt8]]) -> CLIEnvironment {
    CLIEnvironment(
        readFile: { path in
            guard let data = files[path] else { throw TestFSError.notFound }
            return data
        },
        writeFile: { _, _ in }, createDirectory: { _ in }, writeOut: { _ in }, writeErr: { _ in },
        listDirectory: { path in dirs[path] },
        isFile: { path in files[path] != nil }
    )
}

private enum TestFSError: Error { case notFound }

@Test func resolvePixWalksTailSuffixesLongestFirst() throws {
    // Document at /doc/LETTER.WS; tag payload C:\WS\INSET\PIX\WORDSTAR.PIX; the real
    // file sits at /doc/INSET/PIX/WORDSTAR.PIX -- one hop, matching the real corpus
    // shape (root-level documents hit INSET/PIX one hop from their own directory).
    let env = fakeFSEnvironment(
        dirs: ["/doc": ["INSET"], "/doc/INSET": ["PIX"], "/doc/INSET/PIX": ["WORDSTAR.PIX"]],
        files: ["/doc/INSET/PIX/WORDSTAR.PIX": bytes("pix bytes")])
    let resolved = resolvePix(#"C:\WS\INSET\PIX\WORDSTAR.PIX"#, docPath: "/doc/LETTER.WS", environment: env)
    #expect(resolved == "/doc/INSET/PIX/WORDSTAR.PIX")
}

@Test func resolvePixIsCaseInsensitive() throws {
    let env = fakeFSEnvironment(dirs: ["/doc": ["figure1.pix"]],
                                files: ["/doc/figure1.pix": bytes("pix bytes")])
    let resolved = resolvePix(#"C:\PIX\FIGURE1.PIX"#, docPath: "/doc/LETTER.WS", environment: env)
    #expect(resolved == "/doc/figure1.pix")
}

@Test func resolvePixFallsBackToBasenameProbing() throws {
    // No INSET/PIX tail match anywhere -- falls back to the fixed basename probe list,
    // same-dir first.
    let env = fakeFSEnvironment(dirs: ["/doc": ["FIGURE1.PIX"]],
                                files: ["/doc/FIGURE1.PIX": bytes("pix bytes")])
    let resolved = resolvePix(#"C:\SOMEWHERE\ELSE\FIGURE1.PIX"#, docPath: "/doc/LETTER.WS", environment: env)
    #expect(resolved == "/doc/FIGURE1.PIX")
}

@Test func resolvePixReturnsNilWhenNothingMatches() throws {
    let env = fakeFSEnvironment(dirs: [:], files: [:])
    #expect(resolvePix(#"C:\PIX\MISSING.PIX"#, docPath: "/doc/LETTER.WS", environment: env) == nil)
}

@Test func resolveDocumentPicturesEndToEnd() throws {
    let (doc, pixData) = onePixDoc()
    let env = fakeFSEnvironment(dirs: ["/doc": ["FIGURE1.PIX"]],
                                files: ["/doc/FIGURE1.PIX": pixData])
    let results = resolveDocumentPictures(doc, docPath: "/doc/LETTER.WS", environment: env)
    #expect(results.count == 1)
    #expect(results[0].ok)
    #expect(results[0].gcols == 2 && results[0].grows == 1)
}

@Test func resolveDocumentPicturesReportsUnresolvedWithNoDocPath() throws {
    let (doc, _) = onePixDoc()
    let results = resolveDocumentPictures(doc, docPath: "", environment: fakeFSEnvironment(dirs: [:], files: [:]))
    #expect(results.count == 1)
    #expect(results[0].error == .unresolved)
}

@Test func reportPixMissesWritesProbedLocations() throws {
    var written: [String] = []
    let env = CLIEnvironment(readFile: { _ in [] }, writeFile: { _, _ in }, createDirectory: { _ in },
                             writeOut: { _ in }, writeErr: { line in written.append(line) },
                             listDirectory: { _ in nil }, isFile: { _ in false })
    var miss = PixResult(index: 0, rawPath: #"C:\PIX\FIGURE1.PIX"#)
    miss.error = .unresolved
    reportPixMisses([miss], pathLabel: "/doc/LETTER.WS", docPath: "/doc/LETTER.WS", environment: env)
    #expect(written.count == 1)
    #expect(written[0].contains("FIGURE1.PIX"))
    #expect(written[0].contains("not found"))
    #expect(written[0].contains("probed:"))
}

@Test func writeExportImagesDedupesSharedBasenames() throws {
    var writtenFiles: [String: [UInt8]] = [:]
    let env = CLIEnvironment(readFile: { _ in [] },
                             writeFile: { path, data in writtenFiles[path] = data },
                             createDirectory: { _ in }, writeOut: { _ in }, writeErr: { _ in })
    let r0 = PixResult(index: 0, rawPath: #"C:\A\FIG.PIX"#, png: bytes("png0"))
    let r1 = PixResult(index: 1, rawPath: #"C:\B\FIG.PIX"#, png: bytes("png1"))
    let written = writeExportImages([r0, r1], imagesDir: "/out/doc-images", environment: env)
    #expect(written[0] == "FIG.png")
    #expect(written[1] == "FIG-1.png")
    #expect(writtenFiles["/out/doc-images/FIG.png"] == bytes("png0"))
    #expect(writtenFiles["/out/doc-images/FIG-1.png"] == bytes("png1"))
}

// MARK: - diagnose

@Test func diagnoseSurfacesPixEntries() throws {
    let (doc, pixData) = onePixDoc()
    _ = doc
    let data = bytes("word") + SOFT + bytes("word") + SOFT + bytes("word") + SOFT
        + bytes(".pi ") + HARD    // placeholder to keep parseWS's own detect() happy
    _ = data
    let docBytes = bytes(".sr 1") + HARD + bytes("word") + SOFT + bytes("word") + SOFT
        + bytes("word") + SOFT + wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
        + bytes(" text.") + HARD
    let env = fakeFSEnvironment(dirs: ["/doc": ["FIGURE1.PIX"]], files: ["/doc/FIGURE1.PIX": pixData])
    let value = diagnose(path: "/doc/LETTER.WS", data: docBytes, environment: env)
    guard case .object(let obj) = value, case .array(let entries)? = obj["pix"] else {
        Issue.record("no pix array in diagnose output")
        return
    }
    #expect(entries.count == 1)
    guard case .object(let entry) = entries[0] else {
        Issue.record("pix entry is not an object")
        return
    }
    #expect(entry["resolved"] == .bool(true))
    #expect(entry["tag"] == .string("FIGURE1.PIX"))
    #expect(entry["width"] == .int(2))
}

@Test func diagnoseOmitsPixKeyWhenNoGraphics() throws {
    let data = bytes("word") + SOFT + bytes("word") + SOFT + bytes("word") + SOFT + bytes("Plain.") + HARD
    let value = diagnose(path: "/doc/LETTER.WS", data: data,
                         environment: fakeFSEnvironment(dirs: [:], files: [:]))
    guard case .object(let obj) = value else {
        Issue.record("diagnose output is not an object")
        return
    }
    #expect(obj["pix"] == nil)
}
