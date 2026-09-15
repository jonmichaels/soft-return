import Foundation
import Testing
@testable import CtrlKD

/// Two mechanisms out of the ws7-prints/v4 set, 2026-09-12 — Swift port of ctrl-kd's
/// `tests/test_pcl_v4_column_geometry.py`, same synthetic cases, same expectations
/// (causes 7, 10's page count, 11 and 15 of that round's triage). Both are MEASURED
/// against real WordStar 7 (the PRISTINE.EXE captures in the private corpus); these
/// fixtures reproduce the same shapes so the rules stay covered with no corpus at all.
///
///   D. A PAGE'S BUDGET IS ITS REAL TEXT HEIGHT, NOT THAT HEIGHT ROUNDED DOWN TO WHOLE
///      DEFAULT LEADS, and every line — the first one included — spends its own lead
///      out of it. `printedCap` has to floor (it answers "how many DEFAULT-lead lines
///      fit"), and spending the floored count back out threw away up to one lead of
///      real paper. Four corpus documents pair a fractional-inch `.mt` with `.lh 14pt`
///      and open with two 12pt lines before that `.lh` takes effect, and every one of
///      them lost exactly one line per column: `REF/WINGDING.CHT` (WS7 2 + 45 lines,
///      engine 2 + 44), `REF/SYMBOL.CHT` (2 + 47 vs 2 + 46), `PRINTERS/fontcrib.ws`
///      and `PRINTER.PS` (2 + 51 vs 2 + 50). `LSRBOX/LSRBOX.WS` ran to 9 pages against
///      WS7's 7 for the same reason.
///
///   E. A COLUMN GROUP SHARES ONE TOP, AND ONE COLUMN WIDTH. Every column of a sheet
///      begins where the `.co n>1` REGION begins on that sheet, below whatever
///      non-columnar prefix the sheet opened with — WS7 opens WINGDING.CHT's columns
///      2-5 at 153.2pt, not at the sheet's own first text line (129.2pt), and gives
///      them the same 45 lines column 1's columnar part gets, not 46.
///      `MICKEE/MICKEE.WS` overprinted its own section heading for the want of this.
///      And `.rm` is stateful: documents move it INSIDE a live region, so the region's
///      own opening `.rm` fixes the grid for the whole region.

/// `[x: [(y, text)]]` for one page, walked exactly the way `pageStream` places
/// baselines — first line at `top` plus its own lead, a new column at `top` plus the
/// page's own `columnTopOffsetPt` plus its own lead, everything else one lead further
/// down.
private func rowsByColumn(_ doc: Document, _ page: Page) -> [Double: [(Double, String)]] {
    var byX: [Double: [(Double, String)]] = [:]
    let top = Double(printedTop(doc))
    let lead = printedLead(doc)
    let offset = page.columnTopOffsetPt ?? 0.0
    var y = 0.0
    var prevCol = page.lines.first?.col
    for (n, line) in page.lines.enumerated() {
        let own = line.lead ?? lead
        if n == 0 {
            y = top + own
        } else if let cur = line.col, cur != prevCol {
            y = top + offset + own
        } else {
            y += own
        }
        prevCol = line.col
        let text = line.spans.map { $0.text }.joined().trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let x = ((line.left ?? printedLeft(doc, size: printedSize(doc))) * 10).rounded() / 10
            byX[x, default: []].append(((y * 10).rounded() / 10, text))
        }
    }
    for k in byX.keys { byX[k]!.sort { $0.0 < $1.0 } }
    return byX
}

private func bodyLines(_ n: Int, prefix: String = "r") -> String {
    (1...n).map { String(format: "\(prefix)%03d\r\n", $0) }.joined()
}

// MARK: - mechanism D

@Test func aShortFirstLineDoesNotForfeitThePagesFractionalRemainder() {
    // WINGDING.CHT's own shape, with no corpus: `.mt 1.6"`/`.mb .3"` leaves 655.2pt of
    // text height, which is 46.8 lines at `.lh 14pt` — so the floored line count could
    // only ever spend 644pt of it. The sheet opens with two 12pt lines (they precede
    // the `.lh`), which leaves room for 45 fourteen-point lines, and that is what real
    // WS7 prints.
    let src = ".mt 1.6\"\r\n.mb .3\"\r\nTitle\r\n\r\n.lh 14pt\r\n" + bodyLines(119)
    let doc = parseWS(bytes(src))
    let cap = printedCap(doc)
    let lead = printedLead(doc)
    #expect(Double(cap) * lead < 655.2)
    #expect(abs(printedBudgetPt(doc, capacity: cap, defaultLead: lead) - 655.2) < 1e-6)
    let pages = docToPagelines(doc, printed: true)
    #expect(pages[0].lines.count == 47)          // 2 twelve-point + 45 fourteen-point
    // 127.0/769.0 rather than WS7's own 127.2/769.2: `printedTop` reports `.mt 1.6"` as
    // a whole 115pt, the documented sub-point measurement floor, well inside the gate's
    // own 1.0pt bar.
    let rows = rowsByColumn(doc, pages[0]).values.first!
    #expect(rows.first!.0 == 127.0)
    #expect(rows.last!.0 == 769.0)
}

@Test func aUniformLeadPageStillBreaksExactlyWhereTheLineCountSays() {
    // The byte-identity half: with one lead on the page, `n` lines fit iff
    // `n <= floor(height / lead)`, which IS `printedCap`.
    let doc = parseWS(bytes(bodyLines(199, prefix: "line")))
    #expect(printedCap(doc) == 55)               // .pl 66 - .mt 3 - .mb 8
    #expect(docToPagelines(doc, printed: true)[0].lines.count == 55)
}

// MARK: - mechanism E

private func columnsFixture(rows: Int = 200) -> Document {
    // WINGDING.CHT's own geometry: `.po .3"`, `.mt 1.6"`, `.mb .3"`, a title line and
    // its blank at the default 12pt lead, then `.rm .88"` / `.lh 14pt` / `.co5, .75"`.
    var src = ".po .3\"\r\n.mt 1.6\"\r\n.mb .3\"\r\nTitle\r\n\r\n"
    src += ".rm .88\"\r\n.lh 14pt\r\n.co5, .75\"\r\n"
    src += bodyLines(rows)
    return parseWS(bytes(src))
}

@Test func everyColumnOfAGroupStartsAtTheRegionsOwnTop() {
    let doc = columnsFixture()
    let page = docToPagelines(doc, printed: true)[0]
    #expect(page.columns == 5)
    #expect(page.columnTopOffsetPt == 24.0)      // the prefix is two 12pt lines
    let byX = rowsByColumn(doc, page)
    let xs = byX.keys.sorted()
    #expect(xs == [21.6, 139.0, 256.3, 373.7, 491.0])  // `.rm` + gutter = 63.36 + 54
    #expect(byX[xs[0]]!.first!.0 == 127.0)             // the title is unmoved
    for x in xs.dropFirst() {
        #expect(byX[x]!.first!.0 == 153.0)             // the region top, not the sheet top
    }
}

@Test func aLaterColumnHoldsNoMoreLinesThanTheFirstOnesBody() {
    // The same rule seen as room: the prefix comes out of EVERY column's budget, so
    // column 2 gets 45 lines like column 1's columnar part — WS7's own count. It used
    // to get the whole sheet's 46.
    let doc = columnsFixture()
    let byX = rowsByColumn(doc, docToPagelines(doc, printed: true)[0])
    let xs = byX.keys.sorted()
    #expect(byX[xs[0]]!.count == 46)             // the title plus 45 body lines
    for x in xs[1..<4] {
        #expect(byX[x]!.count == 45)
        #expect(byX[x]!.last!.0 == 769.0)        // and the same bottom
    }
}

@Test func aRegionThatOwnsItsSheetOutrightHasNoOffset() {
    // `REVIEW.DOC`'s shape — `.co2` on the document's very first line.
    let doc = parseWS(bytes(".rm 3.13\"\r\n.co2, .25\"\r\n" + bodyLines(119)))
    let page = docToPagelines(doc, printed: true)[0]
    #expect(page.columns == 2)
    #expect(page.columnTopOffsetPt == 0.0)
    let tops = Set(rowsByColumn(doc, page).values.map { $0.first!.0 })
    #expect(tops.count == 1)
}

private func midRegionRMFixture() -> Document {
    // fontcrib.ws / PRINTER.PS's own shape: a `.co5` region the author breaks with
    // `.pa` (absorbed inside a live region), restating `.rm 6.9i` right after it and
    // before restating `.rm .88"` and the `.co5`.
    func grp(_ start: Int) -> String {
        (start..<(start + 255)).map { String(format: "c%03d\r\n", $0) }.joined()
    }
    var src = ".po .3\"\r\n.mt .4\"\r\n.mb .3\"\r\n.rm 6.9i\r\nTitle\r\n\r\n"
    src += ".rm .88\"\r\n.lh 14pt\r\n.co5, .75\"\r\n"
    src += grp(1)
    src += ".pa\r\n.rm 6.9i\r\n.lh 12pt\r\nrestated\r\n"
    src += ".rm .88\"\r\n.lh 14pt\r\n.co5, .75\"\r\n"
    src += grp(300)
    return parseWS(bytes(src))
}

@Test func theRegionsOpeningRMFixesTheColumnGrid() {
    // A `.rm` inside a live region moves ordinary lines' right edge, as `.rm` always
    // does, and must not re-cut the columns: `.rm 6.9i` gives a 496.8pt column against
    // this region's real 63.36pt one.
    let doc = midRegionRMFixture()
    let wide = doc.blocks.indices.filter {
        (doc.blocks[$0].columns ?? 1) > 1 && doc.blocks[$0].rightMargin == 69.0
    }
    #expect(!wide.isEmpty)                       // the fixture really does restate it
    #expect(regionFirstBI(doc, wide[0]) == 1)    // the region's own opening block
    for page in docToPagelines(doc, printed: true) where page.columns != nil {
        #expect(abs(page.columnWidthPt! - 63.36) < 1e-9)
    }
}

@Test func theRegionWalkStepsOverPagebreakSentinels() {
    // `pagebreak`/`colbreak`/`condpage` blocks carry no columns state at all, and
    // fontcrib.ws's region is broken by a `.pa` every 51 blocks — treating one as the
    // region's edge is what made the mid-region `.rm` win.
    let doc = midRegionRMFixture()
    #expect(doc.blocks.contains { $0.kind != .para })
    let last = doc.blocks.indices.filter { (doc.blocks[$0].columns ?? 1) > 1 }.max()!
    #expect(regionFirstBI(doc, last) == 1)
}

@Test func aRealCo1DoesEndTheRegion() {
    // The walk stops at a genuine non-columnar block, so a second region gets its own
    // `.rm`.
    // `+=` statements, never a chained `+` across several terms (planning #253).
    var src = ".rm .88\"\r\n.co3, .5\"\r\n"
    src += bodyLines(29, prefix: "a")
    src += ".co1\r\nbetween\r\n"
    src += ".rm 2.0\"\r\n.co3, .5\"\r\n"
    src += bodyLines(29, prefix: "b")
    let doc = parseWS(bytes(src))
    let starts = Set(doc.blocks.indices
        .filter { doc.blocks[$0].kind == .para && (doc.blocks[$0].columns ?? 1) > 1 }
        .map { regionFirstBI(doc, $0) }).sorted()
    #expect(starts.count == 2)
    #expect(doc.blocks[starts[0]].rightMargin == 8.8)
    #expect(doc.blocks[starts[1]].rightMargin == 20.0)
}

@Test func theLayoutJSONPublishesTheColumnTopOffset() throws {
    // version 8 of the layout contract: a consumer that resets its vertical cursor on a
    // `col` change must reset it to `top + column_top_offset_pt`.
    let doc = columnsFixture()
    let json = try JSONSerialization.jsonObject(
        with: Data(Array(emitLayout(doc, mode: .printed).utf8))) as! [String: Any]
    #expect(json["version"] as? Int == 10)
    let pages = (json["printed"] as! [String: Any])["pages"] as! [[String: Any]]
    let columnar = pages.filter { $0["columns"] != nil }
    #expect(!columnar.isEmpty)
    #expect(columnar[0]["column_top_offset_pt"] as? Double == 24.0)
}

// MARK: - mechanism F: a running head's own print controls

/// A 0x0F USER PRINT CONTROL block, exactly WSFORMAT.TXT's own shape and
/// `sawyer/LSRBOX/LSRBOX.WS`'s: a word of HMIs, a byte of display-string length, the
/// display string itself, then the raw printer payload ("the remaining bytes ... will
/// be sent directly to the printer").
private func pctlControl(_ shown: [UInt8], _ payload: [UInt8], hmi: Int = 0) -> [UInt8] {
    var content: [UInt8] = [UInt8(hmi & 0xFF), UInt8((hmi >> 8) & 0xFF)]
    content.append(UInt8(shown.count))
    content += shown
    content += payload
    let count = content.count + 4
    var out: [UInt8] = [0x1D, UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), 0x0F]
    out += content
    out += [UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), 0x1D]
    return out
}

private let rulePCL = bytes("\u{1B}*p0062x0145Y\u{1B}*c0010a3000bg0P")

private func rectCount(_ stream: [UInt8]) -> Int {
    let text = latin1(stream)
    var n = 0
    var idx = text.startIndex
    while let r = text.range(of: " re", range: idx..<text.endIndex) {
        n += 1
        idx = r.upperBound
    }
    return n
}

@Test func aPrintControlsDisplayStringNeverReachesARunningHead() throws {
    // A 0x0F user print control's display string is SCREEN-ONLY -- on paper WordStar
    // sends the raw printer payload instead. The body path has done that since
    // register C2; a running head kept the string and PRINTED it. Measured on
    // `sawyer/LSRBOX/LSRBOX.WS`, whose `.h1` IS one such control (a full-page shaded
    // frame, HMI 0): real WS7 prints no header text on any of its 7 pages, and this
    // engine printed `«Shaded ...  0-dot-wide lines»` across the top of every one.
    var src = bytes(".h1")
    src += pctlControl(bytes("\u{AE}Shaded 00.500\"h\u{AF}"), rulePCL)
    src += bytes("\r\n")
    src += bytes(bodyLines(59, prefix: "body"))
    let doc = try parse(src)
    #expect(doc.headers[1] == "")
    #expect(doc.headerPcl[1] == [HFPrintControl(offset: 0, hmi: 0, pcl: 0)])
    #expect(doc.pclPrograms.count == 1)
    let out = emitPDF(doc, mode: .printed)
    #expect(!latin1(out).contains("Shaded"))
}

@Test func aRunningHeadsPrintControlDrawsItsOwnRectangles() throws {
    // ...and what WS7 actually sends is drawn. LSRBOX.WS's own later `.h1` carries two
    // rule controls beside its real text, and real WS7 puts 2 rectangles on every page
    // that head governs; this engine drew none.
    var src = bytes(".h1 Sawyer")
    src += pctlControl(bytes("\u{AE}VrtLin\u{AF}"), rulePCL)
    src += bytes("\r\n")
    src += bytes(bodyLines(129, prefix: "body"))
    let doc = try parse(src)
    #expect(doc.headers[1].map { $0.trimmingCharacters(in: .whitespaces) } == "Sawyer")
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count >= 2)
    for page in pages.prefix(2) {
        #expect(page.headerPcl[1]?.count == 1)
    }
}

@Test func aHeaderWithNoControlDrawsNothingNew() throws {
    // The negative: an ordinary running head is byte-identical to before this existed
    // -- no rectangle, no empty header line, no extra op.
    var src = bytes(".h1 Plain head\r\n")
    src += bytes(bodyLines(59, prefix: "body"))
    let doc = try parse(src)
    #expect((doc.headerPcl[1] ?? []).isEmpty)
    let out = emitPDF(doc, mode: .printed)
    #expect(rectCount(out) == 0)
}

@Test func aFillWithAnOmittedValueIsSolidBlack() {
    // HP's parameterized escapes are VALUE+LETTER pairs and an omitted value means
    // zero, so `...bg0P` is pattern 0, fill type 0 -- solid black. The parser required
    // a digit there and dropped 16 of LSRBOX.WS's own fills (its thin rules and
    // vertical lines) as unrecognised.
    #expect(parsePCLProgram(bytes("\u{1B}*c0010a3000bg0P")) == [.fill(w: 10, h: 3000, gray: 0.0)])
    // unchanged: the two shapes that already parsed
    #expect(parsePCLProgram(bytes("\u{1B}*c2250a0003b0P")) == [.fill(w: 2250, h: 3, gray: 0.0)])
    let shaded = parsePCLProgram(bytes("\u{1B}*c0075a3000b0015g2P"))
    guard case .fill(let w, let h, let gray)? = shaded.first else {
        Issue.record("shaded fill did not parse"); return
    }
    #expect(w == 75 && h == 3000 && abs(gray - 0.85) < 1e-9)
}

// MARK: - mechanism F
//
// `<0D 8C>` IS A COLUMN BREAK'S OWN TERMINATOR, NOT A BARE-CR OVERPRINT.
//
// WordStar records a column break by closing the line it happened on with a FLAGGED
// form feed — `<0D 8C>` in the file, de-flagged to `<0D 0C>` by the parser's own
// flagged-byte translate — exactly as it closes a soft-wrapped line with a flagged
// line feed. Counted in Robert J. Sawyer's own WS7 archive the tally is the
// column-break tally, document for document: REF/WINGDING.CHT 4 (one sheet, `.co5`),
// PRINTERS/fontcrib.ws 8 (two sheets), PRINTER.PS 12 (three), LSRBOX/LSRBOX.WS 1, and
// MICKEE.WS 6 / ARTICLES/FORMFEED.WS 1 each directly after an explicit `.cb`.
//
// Read as a BARE CR it is `^PM` Overprint Line instead, and the line in front of every
// column break spends no vertical room at all (the printed budget credits the line
// AFTER an overprint with a free lead). Measured on LSRBOX.WS page 7 against the
// ws7-prints/v4 PRISTINE.EXE capture: real WS7 ends column 1 after its tenth `.lh 1"`
// line — 720pt of a 766.8pt text height, the eleventh line's own 55.44pt lead not
// fitting — and this engine spent 0pt on the tenth, swallowed four more lines out of
// column 2, and printed two of them off the foot of the sheet at the left margin.

private let colbrk: [UInt8] = [0x0D, 0x8C]   // as it appears in a real WS7 file

@Test func aColumnBreakTerminatorIsNotAnOverprint() throws {
    // The mechanism, at its smallest: the line closed by `<0D 8C>` is an ordinary line.
    let doc = try parse(bytes("first") + colbrk + bytes("second\r\n"))
    let lines = doc.blocks.flatMap { $0.lines }
    #expect(lines.first?.spans.map { $0.text }.joined().contains("first") == true)
    #expect(lines.first?.overprint == false)
}

@Test func aGenuineBareCRStillOverprints() throws {
    // The negative that keeps `^PM` Overprint Line working: a `<0D>` with anything but
    // a form feed after it is unchanged. (The 0x8C in this fixture's own tail is what
    // makes `detect()` read it as a WS document, where `overprintCr` is on — the same
    // shape as the case above.)
    let doc = try parse(bytes("under\rover\r\ntail") + colbrk + bytes("end\r\n"))
    let lines = doc.blocks.flatMap { $0.lines }
    #expect(lines.first?.overprint == true)
}

@Test func aColumnBreaksLastLinePaysItsLead() {
    // LSRBOX.WS page 7's shape, synthetic: a `.co2` region whose column 1 is filled by
    // ten 72pt lines, the last of them closed by `<0D 8C>`, and whose next line's own
    // lead (`.lh .77"`, 55.44pt) does not fit in what the page has left. Column 1 must
    // hold exactly those ten lines — it held fourteen before this fix.
    var head = ".mt .35\"\r\n.mb 0\r\n.lh 1\"\r\n.rm 2.75\"\r\n.co2, 1.00\"\r\n"
    head += (1...9).map { String(format: "row %02d\r\n", $0) }.joined()
    head += "row 10"
    var tail = ".lh .77\"\r\n\r\n.lh 12pt\r\n\r\n"
    tail += (1...19).map { String(format: "col two line %02d\r\n", $0) }.joined()
    let doc = parseWS(bytes(head) + colbrk + bytes(tail))
    let page = docToPagelines(doc, printed: true)[0]
    let cols = page.lines.map { $0.col ?? 0 }
    let firstCol2 = cols.firstIndex(of: 1)
    #expect(firstCol2 == 10)
    let tenth = page.lines[9].spans.map { $0.text }.joined()
        .trimmingCharacters(in: .whitespaces)
    #expect(tenth == "row 10")
}
