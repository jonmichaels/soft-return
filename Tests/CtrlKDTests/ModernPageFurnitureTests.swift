/// `modernPageFurniture` — the public accessor the Mac and iOS apps read Modern's own
/// page furniture from (planning #276, 2026-09-15).
///
/// THE POINT OF THIS FILE, in one sentence: the accessor must be an answer ABOUT the
/// drawn page, never a second opinion about it. So every assertion below reads the
/// Modern PDF back apart and checks that what the accessor SAYS is drawn is what the
/// content stream actually draws — same text, same x, same y, page by page. An accessor
/// that merely agreed with its own arithmetic would pass a test that never opened the
/// PDF, which is exactly the failure mode the apps had before it existed.
@testable import CtrlKD
@testable import SoftReturnCLI   // `pagePresets["sawyer"]` — the real `--page-settings` preset
import Testing
import Foundation

/// Every page's content stream, in order -- split on the RAW bytes, never on a decoded
/// String: a running head carrying a cp437 bullet is not valid UTF-8 and a round trip
/// through `String` replaces it, which would make this test lie about the text it
/// compares.
private func modernPageStreams(_ pdf: [UInt8]) -> [[UInt8]] {
    let open = Array(">>\nstream\n".utf8)
    let close = Array("\nendstream".utf8)
    func find(_ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= pdf.count else { return nil }
        var i = from
        while i + needle.count <= pdf.count {
            if Array(pdf[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
    var out: [[UInt8]] = []
    var i = 0
    while let start = find(open, from: i) {
        let body = start + open.count
        guard let end = find(close, from: body) else { break }
        out.append(Array(pdf[body..<end]))
        i = end + close.count
    }
    return out
}

/// The text-showing operators of one page, decoded.
private func spans(ofPage stream: [UInt8]) -> [ShownSpan] {
    contentSpans(stream)
}

/// Text compared as LETTERS AND DIGITS only. Two things in a running head are real and
/// are not a text-showing operator's literal: the gaps between words (`modernLineOps`
/// writes one operator per token and the spacing lives in each token's own x advance),
/// and a cp437 GRAPHIC character, which this engine draws as vectors (`graphicOps`) --
/// `RTF-RJS/NOVEL.WS`'s running head carries a bullet, and there is no literal for it
/// anywhere in the stream. What this still catches is every wrong, missing or extra
/// word, which is what the accessor could plausibly get wrong.
private func inkOnly(_ text: String) -> String {
    String(text.filter { $0.isLetter || $0.isNumber })
}

/// The spans drawn on one baseline row, left to right.
private func row(_ spans: [ShownSpan], y: Double) -> [ShownSpan] {
    spans.filter { $0.y != nil && abs($0.y! - y) < 0.05 }
}

/// Assert one furniture line is drawn exactly where the accessor says it is.
private func expectDrawn(_ line: ModernHeadFootLine, on pageSpans: [ShownSpan],
                         _ label: String) {
    let drawn = row(pageSpans, y: line.y)
    #expect(!drawn.isEmpty, "\(label): nothing drawn at this line's y")
    guard let first = drawn.first else { return }
    // The accessor reports the UNROUNDED x; the emitter writes it at the one decimal
    // every coordinate in this file is written at. Comparing the rounded value is the
    // honest form of "the same number" -- an accessor that handed back the rounded one
    // would be throwing away precision the app re-lays text with.
    let wantX = roundToOneDecimal(line.x)
    #expect(first.x == wantX, "\(label): x")
    let drawnText = inkOnly(drawn.map(\.text).joined())
    let wantText = inkOnly(line.text)
    #expect(drawnText == wantText, "\(label): text")
    #expect(first.size == line.pt, "\(label): furniture size")
}

private func archiveDoc(_ name: String) throws -> Document {
    let path = sawyerArchivePath + "/" + name
    guard let d = FileManager.default.contents(atPath: path) else {
        throw MissingSawyerFixture(path: path)
    }
    return parseWS([UInt8](d))
}

// The five the coder named: a two-column landscape booklet with styled running heads
// (BOOKLET.WS), an ordinary numbered document (VERSIONS.WS), a long one with notes
// (NOVEL.WS), a screenplay (SCRIPT.WS), and a short-sheet envelope template whose
// MediaBox is not Letter (MAILLIST/ENVELOPE.LST).
private let furnitureDocs = ["REF/BOOKLET.WS", "VERSIONS.WS", "RTF-RJS/NOVEL.WS",
                             "ARTICLES/SCRIPT.WS", "MAILLIST/ENVELOPE.LST"]

/// MAILLIST/ENVELOPE.LST is in the set for its SHEET (a short, non-Letter MediaBox --
/// the M18 class) and its column geometry, not its furniture: a mail-merge envelope
/// template declares no running head or foot and `.mb 0` leaves it unnumbered, so it
/// legitimately draws none. Named here rather than left to be discovered as a silently
/// empty check.
private let noFurnitureExpected: Set<String> = ["MAILLIST/ENVELOPE.LST"]

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: furnitureDocs)
func modernFurnitureMatchesWhatTheModernPDFDraws(_ name: String) throws {
    let doc = try archiveDoc(name)
    let furniture = modernPageFurniture(doc)
    let pages = modernPageStreams(emitPDF(doc, mode: .modern))

    #expect(furniture.count == pages.count,
            "\(name): \(furniture.count) furniture pages, \(pages.count) PDF pages")
    guard furniture.count == pages.count else { return }

    var checked = 0
    for (i, page) in furniture.enumerated() {
        let pageSpans = spans(ofPage: pages[i])
        #expect(page.pageIndex == i)
        for line in page.headers {
            expectDrawn(line, on: pageSpans, "\(name) p\(i + 1) head \(line.line)")
            checked += 1
        }
        for line in page.footers {
            expectDrawn(line, on: pageSpans, "\(name) p\(i + 1) foot \(line.line)")
            checked += 1
        }
        if let auto = page.autoPageNumber {
            let drawn = row(pageSpans, y: auto.y)
            #expect(drawn.map(\.text).joined() == auto.text,
                    "\(name): automatic number text")
            #expect(drawn.first?.x == roundToOneDecimal(auto.x),
                    "\(name): automatic number x")
            checked += 1
        }
    }
    // A test that checked nothing would pass silently.
    if noFurnitureExpected.contains(name) {
        #expect(checked == 0, "\(name): expected no furniture — see noFurnitureExpected")
    } else {
        #expect(checked > 0, "\(name): no furniture to check — the fixture has changed")
    }
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: furnitureDocs)
func modernFurnitureReportsTheSheetAndColumnsItComposedOn(_ name: String) throws {
    let doc = try archiveDoc(name)
    let furniture = modernPageFurniture(doc)
    // The sheet and frame are the document's, resolved once — every page agrees, and
    // agrees with the functions `emitPDF` writes the MediaBox and composes from.
    let prepared = resolvedGeometryDocument(doc, printed: false, options: EmitOptions())
    let (margl, margt, margb, width) = modernGeometry(prepared)
    let sheetH = modernSheetH(prepared)
    let sheetW = Double(roundHalfToEven((modernPageDict(prepared)?.pwIn ?? 8.5) * 72.0))
    for page in furniture {
        #expect(page.sheetHeight == sheetH, "\(name): sheet height")
        #expect(page.sheetWidth == sheetW, "\(name): sheet width")
        #expect(page.marginLeft == margl && page.marginTop == margt
                && page.marginBottom == margb && page.textWidth == width,
                "\(name): text frame")
        #expect(page.columns >= 1)
        // `modernColumnWidth` is the one definition of both.
        let (colW, gutter) = modernColumnWidth(width, cols: page.columns,
                                               gutter: page.columns > 1
                                                   ? page.columnGutter / pdfPtPerCol : nil)
        #expect(page.columnWidth == colW, "\(name): column width")
        #expect(page.columnGutter == gutter, "\(name): gutter")
        // Modern restarts every column at the text frame's own top — unlike Printed,
        // whose columns begin below the sheet's non-columnar prefix.
        #expect(page.columnTopOffset == 0.0)
    }
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func modernFurnitureNumbersTheSamePagesTheModernPDFNumbers() throws {
    // `--page-numbers off` removes the number from both the accessor and the PDF; `on`
    // forces it onto both. The accessor is not allowed to have its own opinion about a
    // flag the emitter reads.
    let doc = try archiveDoc("VERSIONS.WS")
    for mode in [EmitOptions.PageNumberMode.off, .on, .auto] {
        var options = EmitOptions()
        options.pageNumbers = mode
        let furniture = modernPageFurniture(doc, pageNumbers: mode)
        let pages = modernPageStreams(emitPDF(doc, mode: .modern, options: options))
        #expect(furniture.count == pages.count)
        for (i, page) in furniture.enumerated() where i < pages.count {
            let pageSpans = spans(ofPage: pages[i])
            if let auto = page.autoPageNumber {
                #expect(row(pageSpans, y: auto.y).map(\.text).joined() == auto.text,
                        "\(mode) p\(i + 1): the accessor claims a number the PDF draws")
            }
        }
        if mode == .off {
            #expect(furniture.allSatisfy { $0.autoPageNumber == nil },
                    "--page-numbers off leaves no automatic number anywhere")
        }
    }
}

// MARK: - The whole option set: `--page-settings` reaches the accessor

/// A two-column landscape booklet with styled running heads (REF/BOOKLET.WS), the
/// printer test document (PRINT.TST), and an ordinary numbered document (VERSIONS.WS).
///
/// WHICH OF THEM THE PRESET ACTUALLY MOVES, measured 2026-09-15: only VERSIONS.WS.
/// `sawyer` replaces `.mt`/`.mb`/`.po` and only where the DOCUMENT declared none
/// (`effectivePage`'s `== .default` gates); BOOKLET.WS declares all three and PRINT.TST
/// carries `.mb`/`.po` with a `.mt` its parse already sources to the file, so for those
/// two the preset Modern PDF is byte-identical to the plain one. VERSIONS.WS declares
/// none of the three, so it is the document that can fail if the preset stops reaching
/// the accessor — without it every assertion here would pass on the bug too.
private let presetFurnitureDocs = ["REF/BOOKLET.WS", "PRINT.TST", "VERSIONS.WS"]

/// The subset of `presetFurnitureDocs` whose Modern frame the `sawyer` preset moves —
/// asserted BOTH ways below, so this stays a measurement rather than a belief.
private let presetMovesTheFrame: Set<String> = ["VERSIONS.WS"]

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: presetFurnitureDocs)
func modernFurnitureFollowsThePageSettingsPreset(_ name: String) throws {
    // The bug this exists to catch: the `pageNumbers:` spelling built its own
    // `EmitOptions()`, so `--page-settings sawyer` never reached the accessor. It
    // answered about the UNPRESET page while the app exported the preset one — the
    // wrong top margin, the wrong left edge, running heads reported where nothing is
    // drawn. So this compares the accessor to the drawn ops of the SAME export.
    let doc = try archiveDoc(name)
    let sawyer = try #require(pagePresets["sawyer"],
                              "pagePresets[\"sawyer\"] missing — Arguments.swift changed?")
    var options = EmitOptions()
    options.pageSettings = sawyer

    let furniture = modernPageFurniture(doc, options: options)
    let pages = modernPageStreams(emitPDF(doc, mode: .modern, options: options))
    #expect(furniture.count == pages.count,
            "\(name): \(furniture.count) furniture pages, \(pages.count) PDF pages")
    guard furniture.count == pages.count else { return }

    // The sheet and frame the PRESET document composes on — the same two helpers
    // `emitPDF` writes the MediaBox and composes from, over the same folded document.
    let prepared = resolvedGeometryDocument(doc, printed: false, options: options)
    let (margl, margt, margb, width) = modernGeometry(prepared)
    let sheetH = modernSheetH(prepared)
    let sheetW = Double(roundHalfToEven((modernPageDict(prepared)?.pwIn ?? 8.5) * 72.0))

    var checked = 0
    for (i, page) in furniture.enumerated() {
        let pageSpans = spans(ofPage: pages[i])
        #expect(page.pageIndex == i)
        #expect(page.sheetHeight == sheetH, "\(name): preset sheet height")
        #expect(page.sheetWidth == sheetW, "\(name): preset sheet width")
        #expect(page.marginLeft == margl, "\(name): preset left margin")
        #expect(page.marginTop == margt, "\(name): preset top margin")
        #expect(page.marginBottom == margb, "\(name): preset bottom margin")
        #expect(page.textWidth == width, "\(name): preset text width")
        let (colW, gutter) = modernColumnWidth(width, cols: page.columns,
                                               gutter: page.columns > 1
                                                   ? page.columnGutter / pdfPtPerCol : nil)
        #expect(page.columnWidth == colW, "\(name): preset column width")
        #expect(page.columnGutter == gutter, "\(name): preset gutter")
        for line in page.headers {
            expectDrawn(line, on: pageSpans, "\(name) preset p\(i + 1) head \(line.line)")
            checked += 1
        }
        for line in page.footers {
            expectDrawn(line, on: pageSpans, "\(name) preset p\(i + 1) foot \(line.line)")
            checked += 1
        }
        if let auto = page.autoPageNumber {
            let drawn = row(pageSpans, y: auto.y)
            #expect(drawn.map(\.text).joined() == auto.text,
                    "\(name): preset automatic number text")
            #expect(drawn.first?.x == roundToOneDecimal(auto.x),
                    "\(name): preset automatic number x")
            checked += 1
        }
    }
    #expect(checked > 0, "\(name): no furniture to check — the fixture has changed")

    // Whether the preset moves this document's frame at all — stated per document, and
    // checked in both directions. The bug this test exists to catch is only VISIBLE on a
    // document the preset moves; a set that quietly went empty would leave a test that
    // could never fail.
    let unpreset = modernPageFurniture(doc, options: EmitOptions())
    let presetFrame = furniture.first.map { [$0.marginLeft, $0.marginTop, $0.marginBottom] }
    let plainFrame = unpreset.first.map { [$0.marginLeft, $0.marginTop, $0.marginBottom] }
    let moved = presetFrame != plainFrame
    #expect(moved == presetMovesTheFrame.contains(name), """
        \(name): the sawyer preset \(moved ? "moves" : "does not move") this Modern \
        frame (\(plainFrame.map(String.init(describing:)) ?? "nil") -> \
        \(presetFrame.map(String.init(describing:)) ?? "nil")) — see presetMovesTheFrame
        """)
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: furnitureDocs)
func modernFurnitureOptionsOverloadMatchesThePageNumbersSpelling(_ name: String) throws {
    // The old signature is now a convenience spelling of the new one; under default
    // options, and under each page-number mode, it answers exactly what it always did.
    let doc = try archiveDoc(name)
    #expect(modernPageFurniture(doc, options: EmitOptions()) == modernPageFurniture(doc),
            "\(name): default options")
    for mode in [EmitOptions.PageNumberMode.off, .on, .auto] {
        let viaOptions = modernPageFurniture(doc, options: EmitOptions(pageNumbers: mode))
        let viaFlag = modernPageFurniture(doc, pageNumbers: mode)
        #expect(viaOptions == viaFlag, "\(name): --page-numbers \(mode)")
    }
}

// MARK: - `HeadFootLine.styleAttrs` and the layout JSON's `style` (version 11)

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func printedHeadFootLinesCarryTheSelectedStylesOwnAttrs() throws {
    // A running head can be BOLD with no toggle byte anywhere in its text -- the weight
    // comes from the `.h#` argument's own 0x11 style select, which `resolveHeadFootLines`
    // resolves into `styleAttrs` and `hfLineOps` ORs into every run before drawing. The
    // MODEL used to drop it, so the Mac and iOS apps drew REF/BOOKLET.WS's two heads
    // light. `style` in the JSON is a sorted tag list and is always present.
    let booklet = try archiveDoc("REF/BOOKLET.WS")
    let pages = docToPagelines(resolvedGeometryDocument(booklet, printed: true,
                                                        options: EmitOptions()),
                               printed: true)
    let heads = pages.first?.headerLines ?? []
    #expect(!heads.isEmpty, "REF/BOOKLET.WS has running heads")
    #expect(heads.allSatisfy { $0.styleAttrs.contains(.bold) },
            "REF/BOOKLET.WS's heads are bold from their own style select")
    // The JSON is pretty-printed, so the tag list spans lines -- match the tag inside
    // a `style` array rather than a one-line spelling of it.
    #expect(emitLayout(booklet, mode: .printed).contains("\"style\": [\n       \"b\"\n      ]"))

    // And the other end: a document whose head selects no style reads `[]`.
    let oldtimes = try archiveDoc("OLDTIMES.WS")
    let otPages = docToPagelines(resolvedGeometryDocument(oldtimes, printed: true,
                                                          options: EmitOptions()),
                                 printed: true)
    let otHeads = otPages.compactMap { $0.headerLines }.flatMap { $0 }
    #expect(!otHeads.isEmpty, "OLDTIMES.WS has running heads")
    #expect(otHeads.allSatisfy { $0.styleAttrs.isEmpty })
    #expect(emitLayout(oldtimes, mode: .printed).contains("\"style\": []"))
    #expect(!emitLayout(oldtimes, mode: .printed).contains("\"style\": [\n"))
}

// MARK: - `.pl 0` and the RTF paper size

@Test func rtfPaperHeightFallsBackToLetterForPLZero() {
    // `.pl 0` is WordStar's "page breaks off", not a zero-inch sheet. The PDF page box
    // has fallen back to Letter since `resolvedPageHeight` was written (and Modern PDF
    // since M18); RTF wrote the arithmetic straight through as `\paperh0`, which
    // LibreOffice refuses to open. Both RTF modes, and a real height is untouched.
    var body: [UInt8] = []
    for i in 1...9 {
        body += bytes("PLZERO-\(String(format: "%03d", i))")
        body += HARD
    }
    var zeroData = bytes(".pl 0")
    zeroData += HARD
    zeroData += body
    var tallData = bytes(".pl 14\"")
    tallData += HARD
    tallData += body
    let zero = parseWS(zeroData)
    let tall = parseWS(tallData)
    for mode in [EmitMode.printed, .modern] {
        let zeroRTF = emitRTF(zero, mode: mode)
        #expect(zeroRTF.contains("\\paperh15840"))
        #expect(!zeroRTF.contains("\\paperh0"))
        #expect(emitRTF(tall, mode: mode).contains("\\paperh20160"))
    }
}

// MARK: - `columnRanges` and `footnoteRows` (planning #276 follow-up, 2026-09-15)
//
// THE POINT OF THIS SECTION, in one sentence: the app's Modern view must fill its columns
// exactly as the engine's Modern pagination does — one source of layout truth, the app
// never re-deriving — and `sawyer/REF/BOOKLET.WS` is the measured proof it could not,
// because it stores four form feeds mid-paragraph that the engine ABSORBS under its
// `.co 2` (three pages) and the app broke on (nine). So the assertions below are about the
// DRAWN page again: a range's split point is checked against the text op that actually
// opens that column, not against the accessor's own arithmetic.

/// A synthetic WS7 document — the same header shape `ModernColumnsTests` builds, so a
/// `.co`/`.cb`/`.pa` fixture here is the same kind of document those tests measure.
private func rangeDocument(_ body: [UInt8], dots: String = "") -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var data: [UInt8] = [0x1D]
    data += le
    data += [0x00, 0x70]
    data += [UInt8](repeating: 0, count: 15)
    data += le
    data += [0x1D]
    data += [UInt8](dots.utf8)
    data += body
    return parseWS(data)
}

private let rangeCR = "\r\n"

/// Every range of every page, flattened in page-then-column order — the partition the
/// contiguity rule is stated over.
private func allRanges(_ furniture: [ModernPageFurniture]) -> [ModernColumnRange] {
    furniture.flatMap(\.columnRanges)
}

/// The ranges are ONE contiguous partition of the flow: they start at the first item, each
/// one ends where the next begins, and the last ends past the last item at offset 0.
private func expectContiguous(_ furniture: [ModernPageFurniture], itemCount: Int,
                              _ label: String) {
    let ranges = allRanges(furniture)
    #expect(!ranges.isEmpty, "\(label): no column ranges at all")
    guard let first = ranges.first, let last = ranges.last else { return }
    #expect(first.startItem == 0 && first.startOffset == 0,
            "\(label): first range starts at (\(first.startItem), \(first.startOffset)), not (0, 0)")
    #expect(last.endItem == itemCount && last.endOffset == 0,
            "\(label): last range ends at (\(last.endItem), \(last.endOffset)), not (\(itemCount), 0)")
    for (i, range) in ranges.enumerated().dropFirst() {
        let prev = ranges[i - 1]
        #expect(prev.endItem == range.startItem && prev.endOffset == range.startOffset,
                "\(label): range \(i) starts at (\(range.startItem), \(range.startOffset)) but the one before it ended at (\(prev.endItem), \(prev.endOffset))")
    }
    for page in furniture {
        #expect(page.columnRanges.map(\.column) == page.columnRanges.map(\.column).sorted(),
                "\(label) p\(page.pageIndex + 1): columns are not ascending")
        for range in page.columnRanges {
            #expect(range.column >= 0 && range.column < page.columns,
                    "\(label) p\(page.pageIndex + 1): column \(range.column) of \(page.columns)")
        }
    }
}

/// The spans one column of one page draws inside Modern's own text frame — the running
/// heads (above the frame), the running feet and the automatic page number (below the
/// bottom margin) all excluded, so what is left is body.
private func bodySpans(_ pageSpans: [ShownSpan], _ page: ModernPageFurniture,
                       column: Int) -> [ShownSpan] {
    let left = page.marginLeft + Double(column) * (page.columnWidth + page.columnGutter)
    return pageSpans.filter { span in
        guard let x = span.x, let y = span.y else { return false }
        return x >= left - 0.5 && x < left + page.columnWidth + 1.0
            && y >= page.marginBottom - 0.05 && y < page.sheetHeight - page.marginTop
    }
}

/// `sem.items[index]`'s own `runs.map(\.text).joined()` — the string `startOffset` and
/// `endOffset` index, stated here once so the assertions read it the same way the doc
/// comment on `ModernColumnRange` says they should.
private func joinedRunText(_ flow: SemanticFlow, _ index: Int) -> String? {
    guard flow.items.indices.contains(index),
          case .para(_, _, _, let runs, _, _, _, _) = flow.items[index] else { return nil }
    return runs.map(\.text).joined()
}

private func utf16Tail(_ text: String, from offset: Int) -> String {
    let units = Array(text.utf16)
    guard offset >= 0, offset <= units.count else { return "" }
    return String(decoding: Array(units[offset...]), as: UTF16.self)
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func bookletFillsThreeTwoColumnPagesAndAbsorbsItsFourFormFeeds() throws {
    let doc = try archiveDoc("REF/BOOKLET.WS")
    let sem = modernSemanticFlow(doc)
    let furniture = modernPageFurniture(doc)

    // The engine's own answer, and the one the app disagreed with: three pages of two
    // columns, not nine pages broken on the stored form feeds.
    #expect(furniture.count == 3, "BOOKLET.WS is 3 Modern pages, not \(furniture.count)")
    for page in furniture {
        #expect(page.columns == 2, "p\(page.pageIndex + 1): \(page.columns) columns")
        #expect(page.columnRanges.count == 2,
                "p\(page.pageIndex + 1): \(page.columnRanges.count) column ranges")
    }
    expectContiguous(furniture, itemCount: sem.items.count, "BOOKLET.WS")

    // Nothing here ended for any reason but running out of room: the four form feeds are
    // absorbed, and the document simply stops.
    for range in allRanges(furniture) {
        #expect(range.ended == .overflow,
                "BOOKLET.WS column \(range.column): ended \(range.ended.rawValue)")
    }

    // THE FOUR ABSORBED FORM FEEDS (flow items 8, 20, 29 and 45). An absorbed break is
    // one the column simply carried, so each one must sit STRICTLY inside a range — never
    // at a boundary, which is what a break the engine had honoured would look like.
    let breaks = sem.items.indices.filter {
        if case .pageBreak = sem.items[$0] { return true }
        return false
    }
    #expect(breaks == [8, 20, 29, 45], "BOOKLET.WS's stored form feeds: \(breaks)")
    for bi in breaks {
        let holder = allRanges(furniture).first { $0.startItem < bi && bi < $0.endItem }
        #expect(holder != nil,
                "form feed at item \(bi) sits on a column boundary, so it was not absorbed")
    }
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func aMidItemSplitIsWhereTheColumnActuallyStartsDrawing() throws {
    // THE OFFSET CONVENTION, checked against the ops rather than asserted: a column that
    // opens in the middle of a paragraph reports the UTF-16 offset of the first character
    // of the first VISUAL LINE placed in it, so the text op at the top of that column
    // begins with the run text at exactly that offset.
    let doc = try archiveDoc("REF/BOOKLET.WS")
    let sem = modernSemanticFlow(doc)
    let furniture = modernPageFurniture(doc)
    let pages = modernPageStreams(emitPDF(doc, mode: .modern))
    #expect(furniture.count == pages.count)
    guard furniture.count == pages.count else { return }

    // Page 1 column 2 by name -- the case the round was measured on -- and then every
    // other mid-item split in the document by the same rule.
    let pageOneColumnTwo = try #require(furniture.first?.columnRanges.first { $0.column == 1 })
    #expect(pageOneColumnTwo.startOffset > 0,
            "BOOKLET.WS p1 column 2 opens mid-paragraph; it reported offset 0")

    var checked = 0
    for (pi, page) in furniture.enumerated() {
        let pageSpans = spans(ofPage: pages[pi])
        for range in page.columnRanges where range.startOffset > 0 {
            let label = "BOOKLET.WS p\(pi + 1) column \(range.column + 1)"
            let joined = try #require(joinedRunText(sem, range.startItem),
                                      "\(label): item \(range.startItem) is not a paragraph")
            let tail = utf16Tail(joined, from: range.startOffset)
            let drawn = bodySpans(pageSpans, page, column: range.column)
            let topY = try #require(drawn.compactMap(\.y).max(), "\(label): nothing drawn")
            let top = drawn.filter { abs(($0.y ?? 0) - topY) < 0.05 }
            let firstOp = try #require(top.first?.text, "\(label): no text op at the top")
            #expect(tail.hasPrefix(firstOp),
                    "\(label): the column opens with \(firstOp.debugDescription) but the reported offset \(range.startOffset) points at \(tail.prefix(firstOp.count).debugDescription)")
            // And the whole first line, not just its first word.
            #expect(inkOnly(tail).hasPrefix(inkOnly(top.map(\.text).joined())),
                    "\(label): the column's first line is not the text at that offset")
            checked += 1
        }
    }
    #expect(checked == 5, "BOOKLET.WS has five mid-item splits; checked \(checked)")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func versionsIsOneRangePerPageEndingOnOverflow() throws {
    // The ordinary one-column case: no `.co`, no `.cb`, no `.pa` -- every page ends
    // because the next line did not fit, and the ranges still partition the whole flow.
    let doc = try archiveDoc("VERSIONS.WS")
    let sem = modernSemanticFlow(doc)
    let furniture = modernPageFurniture(doc)
    for page in furniture {
        #expect(page.columns == 1, "p\(page.pageIndex + 1): \(page.columns) columns")
        #expect(page.columnRanges.count == 1,
                "p\(page.pageIndex + 1): \(page.columnRanges.count) ranges on a one-column page")
        #expect(page.columnRanges.first?.column == 0)
        #expect(page.columnRanges.first?.ended == .overflow,
                "p\(page.pageIndex + 1): ended \(page.columnRanges.first?.ended.rawValue ?? "none")")
    }
    expectContiguous(furniture, itemCount: sem.items.count, "VERSIONS.WS")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func printTstReportsItsColumnBreakAndItsRegimeChangeApart() throws {
    // PRINT.TST is the real document carrying all three endings at once: `.pa` page
    // breaks, a `.cb` inside a live `.co 3` region, and the `.co` regime change that ends
    // that region's last column.
    let doc = try archiveDoc("PRINT.TST")
    let sem = modernSemanticFlow(doc)
    let furniture = modernPageFurniture(doc)
    expectContiguous(furniture, itemCount: sem.items.count, "PRINT.TST")

    let columnar = try #require(furniture.first { $0.columns > 1 },
                                "PRINT.TST declares a `.co` region")
    #expect(columnar.columns == 3)
    #expect(columnar.columnRanges.count == 3)
    #expect(columnar.columnRanges.first?.ended == .columnBreak,
            "the `.cb` ends column 1, not \(columnar.columnRanges.first?.ended.rawValue ?? "none")")
    #expect(columnar.columnRanges.last?.ended == .pageBreak,
            "the `.co` regime change ends the sheet")
    #expect(furniture.contains { page in
        page.columns == 1 && page.columnRanges.contains { $0.ended == .pageBreak }
    }, "PRINT.TST's `.pa` breaks are reported as page breaks")
}

@Test func aColumnBreakIsReportedAsOne() throws {
    var body = "First."
    body += rangeCR
    body += ".cb"
    body += rangeCR
    body += "Second."
    body += rangeCR
    let doc = rangeDocument([UInt8](body.utf8), dots: ".co 2, 10" + rangeCR)
    let furniture = modernPageFurniture(doc)
    #expect(furniture.count == 1)
    let ranges = try #require(furniture.first?.columnRanges)
    #expect(ranges.count == 2, "one `.cb` fills two columns, not \(ranges.count)")
    #expect(ranges.first?.ended == .columnBreak)
    #expect(ranges.last?.ended == .overflow, "the document simply ends in column 2")
    expectContiguous(furniture, itemCount: modernSemanticFlow(doc).items.count, ".cb fixture")
}

@Test func aColumnRegimeChangeIsReportedAsAPageBreak() throws {
    var body = "Columnar text."
    body += rangeCR
    body += ".co 1"
    body += rangeCR
    body += "Back to one column."
    body += rangeCR
    let doc = rangeDocument([UInt8](body.utf8), dots: ".co 2, 10" + rangeCR)
    let furniture = modernPageFurniture(doc)
    #expect(furniture.count == 2)
    #expect(furniture.first?.columnRanges.last?.ended == .pageBreak,
            "a change of column regime starts its own sheet")
    #expect(furniture.last?.columns == 1)
    expectContiguous(furniture, itemCount: modernSemanticFlow(doc).items.count, ".co change fixture")
}

@Test func aPageBreakOutsideAColumnarRegionIsReportedAsOne() throws {
    var body = "First."
    body += rangeCR
    body += ".pa"
    body += rangeCR
    body += "Second."
    body += rangeCR
    let doc = rangeDocument([UInt8](body.utf8))
    let furniture = modernPageFurniture(doc)
    #expect(furniture.count == 2)
    #expect(furniture.first?.columnRanges.first?.ended == .pageBreak)
    #expect(furniture.last?.columnRanges.first?.ended == .overflow)
    expectContiguous(furniture, itemCount: modernSemanticFlow(doc).items.count, ".pa fixture")
}

/// The note entries one page's own FOOT BLOCK draws, as ink-only text.
///
/// Identified by geometry, which is the only thing that separates it from the end-matter
/// appendix -- both open with the same twenty-dash rule, but the foot block's rule is
/// drawn at the BOTTOM of the frame (`margb + noteLead * (n)`) and the appendix's sits
/// wherever the body flow reached. So: the LOWEST twenty-dash rule on the page, and
/// everything below it that is still inside the frame (the running feet and the automatic
/// page number ride below `marginBottom` and are excluded).
private func footBlockInk(_ pageSpans: [ShownSpan], _ page: ModernPageFurniture) -> String {
    let rule = String(repeating: "-", count: 20)
    guard let sepY = pageSpans.filter({ $0.text == rule }).compactMap(\.y).min() else { return "" }
    return inkOnly(pageSpans.filter { span in
        guard let y = span.y else { return false }
        return y < sepY - 0.05 && y >= page.marginBottom - 0.05
    }.map(\.text).joined())
}

/// `footnoteRows` names exactly the note rows the page's own foot block draws -- checked
/// both ways, so a row reported on the wrong page fails as loudly as a row left out.
private func expectFootnoteRowsMatchTheDrawnBlock(_ doc: Document, _ label: String) {
    let sem = modernSemanticFlow(doc)
    let furniture = modernPageFurniture(doc)
    let pages = modernPageStreams(emitPDF(doc, mode: .modern))
    #expect(furniture.count == pages.count, "\(label): page counts")
    guard furniture.count == pages.count else { return }
    var drawnSomewhere = 0
    for (pi, page) in furniture.enumerated() {
        let foot = footBlockInk(spans(ofPage: pages[pi]), page)
        for (ni, note) in sem.notes.enumerated() where note.kind == .footnote {
            let want = page.footnoteRows.contains(ni)
            let ink = inkOnly(note.text)
            guard !ink.isEmpty else { continue }
            let how = want ? "reported but not drawn" : "drawn but not reported"
            #expect(foot.contains(ink) == want,
                    "\(label) p\(pi + 1): note row \(ni) is \(how)")
        }
        drawnSomewhere += page.footnoteRows.count
    }
    #expect(drawnSomewhere > 0, "\(label): no footnote rows reported anywhere")
    // A note is committed to exactly one page.
    let all = furniture.flatMap(\.footnoteRows)
    #expect(Set(all).count == all.count, "\(label): a note row is reported on two pages")
}

@Test func footnoteRowsNameTheNotesTheFootBlockDraws() throws {
    var body: [UInt8] = bytes("Before the first mark")
    body += ws7Note(bytes("The first footnote entry."), cmd: 0x03, number: 0)
    body += bytes(" and then a second mark")
    body += ws7Note(bytes("The second footnote entry."), cmd: 0x03, number: 1)
    body += bytes(" and the line ends here.")
    body += HARD
    expectFootnoteRowsMatchTheDrawnBlock(rangeDocument(body), "footnote fixture")
}

@Test(.enabled(if: ctrlkdPrivateCorpusArmed, ctrlkdPrivateCorpusSkipReason))
func lyingReportsItsOwnFootnoteRows() throws {
    // The real authored document behind the sup/sub and printed-notes rounds. Read from
    // the samples directory when that corpus is present; the synthetic fixture above is
    // the unarmed answer to the same question.
    let path = ctrlkdPrivateCorpusRoot + "/pd-samples/authored/LYING.WS"
    guard let data = FileManager.default.contents(atPath: path) else {
        Issue.record("LYING.WS missing from the corpus at \(path)")
        return
    }
    expectFootnoteRowsMatchTheDrawnBlock(parseWS([UInt8](data)), "LYING.WS")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: furnitureDocs + ["PRINT.TST"])
func everyDocumentsColumnRangesPartitionItsWholeFlow(_ name: String) throws {
    // The rule stated over the whole set rather than one document at a time: a screenplay
    // (ARTICLES/SCRIPT.WS, whose page markers force their own breaks), a document with
    // notes and an end-matter appendix (RTF-RJS/NOVEL.WS, whose endnote block forces
    // another), an envelope template on a short sheet, and the three columnar/ordinary
    // cases above. Every one of them must still hand the app one contiguous partition of
    // the flow -- no holes, no overlaps, nothing dropped at a forced break.
    let doc = try archiveDoc(name)
    expectContiguous(modernPageFurniture(doc),
                     itemCount: modernSemanticFlow(doc).items.count, name)
}
