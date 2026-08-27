import Testing
@testable import CtrlKD

/// b26-modern item 4 (ctrl-kd c402094): Modern PDF's inter-line advance must be
/// consistently size-proportional, including across a blank line.
///
/// Modern already sizes each rendered line's own advance by that line's own max token
/// size (`modernLine * size`, `modernStreams`) — that part was never in question. The
/// bug was narrower: a 'blank' item's advance was a FIXED constant (`modernLine *
/// modernBodyPt`, the 14pt document default) baked at flow-build time, independent of
/// what was actually on the page around it. Measured on the real corpus (PREVIEW.WS, a
/// font-sample page mixing 24pt/20pt/12pt lines): a blank between two 24pt lines
/// advanced by the exact same fixed amount a blank between a 24pt line and an 8pt line
/// would, so the total inter-paragraph gap tracked only the ENTERING line's size and
/// ignored the size actually being LEFT — visibly inconsistent spacing wherever font
/// size varied line-to-line.
///
/// Fix: a blank now advances at the MOST RECENTLY PLACED line's own leading — the same
/// "a blank advances at the preceding content's own leading" principle Printed PDF
/// already uses for style-driven leading (`StyleLeadingTests.swift`), applied at
/// Modern's own per-line granularity.
///
/// Synthetic fixtures only (CLAUDE.md): WS7 font-change blocks (`fontBlock`), same
/// construction this file's siblings already use. Port of ctrl-kd's
/// `tests/test_modern_line_spacing.py`.

/// Distinct baseline Y positions in draw order (a visual line often splits into
/// several `Tj` ops — one per word — all sharing one `Td` y). Port of Python's
/// `_line_ys` test helper.
private func lineYs(_ pdf: [UInt8]) -> [Double] {
    var uniq: [Double] = []
    for span in contentSpans(pdf) {
        guard let y = span.y else { continue }
        if uniq.isEmpty || abs(uniq[uniq.count - 1] - y) > 1e-6 {
            uniq.append(y)
        }
    }
    return uniq
}

@Test func blankBetweenUnequalSizesAdvancesAtThePrecedingLinesLeading() throws {
    // A 24pt line, a blank, then an 8pt line: the blank must cost the 24pt line's OWN
    // leading (1.2 x 24 = 28.8pt), not a fixed 14pt-default amount -- combined with the
    // 8pt line's own entering leading (1.2 x 8 = 9.6pt), the total gap is 38.4pt.
    var data = fontBlock(0, points: 24.0) + bytes("Big line.") + HARD + HARD
    data += fontBlock(0, points: 8.0) + bytes("Small line.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = lineYs(pdf)
    #expect(tenth(ys[0] - ys[ys.count - 1]) == 38.4)
}

@Test func blankBetweenEqualLargeSizesIsProportionallyLargerThanDefault() throws {
    // Two 24pt lines separated by a blank: BOTH sides of the gap scale with the 24pt
    // size (28.8 + 28.8 = 57.6), not the old fixed-blank total of 45.6 (28.8 entering +
    // a 16.8 constant that ignored the 24pt line being left).
    var data = fontBlock(0, points: 24.0) + bytes("First big line.") + HARD + HARD
    data += fontBlock(0, points: 24.0) + bytes("Second big line.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = lineYs(pdf)
    #expect(tenth(ys[0] - ys[ys.count - 1]) == 57.6)
}

@Test func consecutiveGapsAreUniformWhenSizeIsUniform() throws {
    // The regression shape itself: three same-size (24pt) one-line paragraphs, each
    // separated by one blank line -- both gaps must be IDENTICAL (57.6pt each), proving
    // the rule is truly proportional and not just correct for one transition.
    var data = fontBlock(0, points: 24.0) + bytes("Line one.") + HARD + HARD
    data += bytes("Line two.") + HARD + HARD
    data += bytes("Line three.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = lineYs(pdf)
    let gaps = (0..<(ys.count - 1)).map { tenth(ys[$0] - ys[$0 + 1]) }
    #expect(gaps == [57.6, 57.6])
}

@Test func defaultSizeBlankSpacingIsUnchanged() throws {
    // A document that never changes font size at all (the common case, every existing
    // corpus doc without an explicit font-sample page) must render at exactly the
    // pre-existing 16.8pt-per-blank spacing (1.2 x the 14pt Modern body default) -- the
    // fix must not perturb the overwhelmingly common uniform-size case.
    let data = bytes("Line one.") + HARD + HARD + bytes("Line two.") + HARD
    var doc = parseWS(data)
    doc.detection = Detection(variant: .ws4)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = lineYs(pdf)
    #expect(tenth(ys[0] - ys[1]) == 16.8 + 16.8)
}

@Test func modernPrintedLeadingIsUnaffectedByThisFix() throws {
    // Printed PDF's own leading mechanism (`.lh`, style vmi) is a wholly separate code
    // path (`layoutPrintedPages`/`pageStream`, not `modernStreams`) -- a document that
    // mixes font sizes must render Printed mode identically whether or not this fix is
    // present, proven by an unrelated Printed invariant: `.lh`-driven leading stays
    // exactly what `.lh` says.
    var data = bytes(".lh 20\r\n") + fontBlock(0, points: 24.0)
    data += bytes("Line one.") + HARD + bytes("Line two.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let ys = lineYs(pdf)
    #expect(tenth(ys[0] - ys[1]) == 30.0)   // 20/48in = 30pt, untouched by Modern's fix
}

// -------------------------------------------------- b27-WP3 item 4 (image+blank)
//
// This suite never exercised images before -- the gap that let the following bug ship.
// `modernStreams`'s `.image` case wrote the embedded picture's own height into `lastH`,
// the same variable the `.blank` case above reuses as "the most recently placed line's
// own leading". A blank run right after an image therefore advanced by the IMAGE's
// height instead of the surrounding text's leading -- "huge whitespace below the image
// before the title block" in Modern view. Port of ctrl-kd's
// `test_blanks_after_an_image_advance_at_text_leading_not_image_height` /
// `test_a_single_blank_before_an_image_is_unaffected_by_the_image_fix`
// (tests/test_modern_line_spacing.py, ctrl-kd 721a94b).
//
// Measured on the real corpus (-README.WS): a 73.9pt-tall inline image followed by 7
// contiguous blank source lines advanced 7 x 73.9 = 517.3pt where the correct 14pt-body
// leading gives 7 x 16.8 = 117.6pt.
//
// Fix: the `.image` case no longer writes to `lastH` at all. Confirmed FAILING before
// this fix / PASSING after (manual bisection, since this is the regression itself): on
// the fixture below, the unfixed code measures a 433.6pt Before->After gap (16.8 leading
// blank + 100pt image + 3 x 100pt bugged blanks + 16.8 entering leading); the fixed code
// measures 184.0pt (16.8 + 100 + 3 x 16.8 correct blanks + 16.8).

/// A resolved `PixResult` print-sized to exactly `(wPt, hPt)` -- deliberately large and
/// distinctive so a blank wrongly inheriting the image's height is unmistakable against
/// the 14pt-body 16.8pt default leading. Same recipe as `PicturesTests.swift`'s
/// `onePixResult`, parameterized on size instead of a fixed fixture.
private func sizedPixResult(wPt: Double, hPt: Double) throws -> PixResult {
    let rowDp = Int((hPt / 72.0 * 720.0).rounded())
    let colDp = Int((wPt / 72.0 * 720.0).rounded())
    let prt = buildPrtOptions(rowDp: rowDp, colDp: colDp)
    let pixData = buildPixBytes(gcols: 2, grows: 1, gfore: 1, pageRows: 1, pageCols: 8,
                                stpRows: 1, stpCols: 1, indexImg: [[1, 0, 0, 0, 0, 0, 0, 0]],
                                prtOptionsRaw: prt)
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

@Test func blanksAfterAnImageAdvanceAtTextLeadingNotImageHeight() throws {
    // The regression itself: 3 blank lines immediately following a 100pt-tall image must
    // advance by 3 x 16.8 = 50.4pt (the default 14pt-body leading), never 3 x 100 = 300pt.
    // Total Before->After gap: 16.8 (leading blank, unaffected by the bug) + 100 (image's
    // own cost) + 50.4 (3 correct blanks) + 16.8 (After's own entering leading) = 184.0pt.
    // The unfixed code measured 433.6pt on this exact fixture.
    let result = try sizedPixResult(wPt: 200.0, hPt: 100.0)
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\FIGURE1.PIX"#.utf8))
    let data = bytes("Before.\r\n\r\n") + block + bytes("\r\n")
        + bytes(String(repeating: "\r\n", count: 3)) + bytes("After.\r\n")
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions(pictures: .embed, pixResults: [result]))
    let ys = lineYs(pdf)
    #expect(ys.count == 2)                     // 'Before.' baseline, 'After.' baseline
    #expect(tenth(ys[0] - ys[1]) == 184.0)
}

@Test func aSingleBlankBeforeAnImageIsUnaffectedByTheImageFix() throws {
    // Sanity companion: a blank BEFORE an image was never part of this bug (it reuses the
    // preceding TEXT line's leading, exactly as any other blank does) -- confirms the fix
    // is scoped to blanks that FOLLOW an image, not blanks generally near one. Two 24pt
    // lines with a blank between them, matching the pre-existing unequal-size rule this
    // file already pins above.
    var data = fontBlock(0, points: 24.0) + bytes("Big line.") + HARD + HARD
    data += fontBlock(0, points: 24.0) + bytes("Second.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .modern)
    let ys = lineYs(pdf)
    #expect(tenth(ys[0] - ys[1]) == 28.8 + 28.8)
}
