import Foundation
import Testing
@testable import CtrlKD

/// Style-driven leading in Printed PDF — WS7 paragraph styles carry their own line height
/// (`StyleRecord.lineHeightVMI`, `StyleLibrary.swift`'s style-record parse, field offset
/// 88), but nothing consumed it: Printed PDF's y-advance only ever read `.lh` dot-command
/// state (`Line.lead48`), so every style-governed document rendered at the document's
/// uniform default leading regardless of its own styles' font sizes.
///
/// MEASURED ORACLE (real WordStar 7, captured via dosbox-x's LaserJet driver, 2026-08-20 —
/// decoded with `ctrl-kd`'s `tools/pcl_text.py` PCL decipoint grammar; kept out of this repo
/// per the synthetic-fixtures-only rule, so every test below re-encodes the SAME behavior as
/// constructed WS7 style-library bytes via `Fixtures.swift`'s `styleRecord`/`styleLibrary`/
/// `styleRef`): a Title/Author style at 16pt and a Body style at 12pt, both
/// `line_height_vmi == -2` ("auto", the only value either style ever carried) produced PDF
/// baseline gaps of exactly 19.2pt (16pt line to 16pt line), 14.4pt (12pt line to 12pt
/// line), and 33.6pt across a blank line sitting between a 16pt block and the following
/// 12pt block (19.2 + 14.4 — the blank line advances at the PRECEDING block's own leading,
/// not the next block's).
///
/// UPDATE (mechanism T, ctrl-kd `tools/PCL-DIVERGENCE-TRIAGE.md`, ported at 21e6d94): the
/// 2026-08-20 oracle above was captured through Robert J. Sawyer's own WSCHANGE-customized
/// `WS.EXE` (`ws7-prints/v1`) — the same install mechanism S already found to have
/// contaminated `.po`. WSCHANGE's own settings chart ("Installing and Customizing (WordStar
/// 7)", "Changing WordStar Settings in WSCHANGE") names this exact feature: "Automatic
/// leading, 120% of text size", path BCL, factory DEFAULT OFF. A `PRISTINE.EXE` (factory,
/// no WSCHANGE) recapture of the SAME documents (`ws7-prints/v3`) shows every one of these
/// numbers at exactly 1/1.2 of the value above — 16.0pt, 12.0pt, and 28.0pt (16.0 + 12.0)
/// respectively, with zero exceptions across LYING/WARPRAYR/-SCREEN/PREVIEW. Stock WS7's
/// real "auto" factor is 1.0 (`autoLeadFactor`, `PDFLayout.swift`); every test below now
/// pins the STOCK numbers — see `autoLeadFactor`'s own doc comment for the full v1-vs-v3
/// evidence table.
///
/// Unit for -2 ("auto"): `autoLeadFactor` (1.0, stock) x the style's own font size — NOT
/// this codebase's `modernLine` (`PDFModernLayout.swift`, = 1.2), which is a deliberate,
/// separate Modern/Word convention (CLAUDE.md: "Modern diverges from paper BY DESIGN") and
/// stays at 1.2 regardless of this fix.
///
/// Unit for an explicit positive vmi: WSFORMAT.WS's own format-spec text ("Word: Font
/// height in VMIs (1/1440ths)") documents VMI as the SAME 1/1440in unit a font's own
/// height word uses, so vmi/20.0 is points — the identical conversion a font's height word
/// already gets. Corroborated independently by two archive documents (DARKNESS.WS,
/// WARPRAYR.WS) where vmi=240 recurs UNCHANGED across styles of differing font size (16pt
/// and 12pt) — an absolute count, not a per-font multiplier. UNCONFIRMED against a real WS7
/// print, though: no oracle exists for a document that actually uses an explicit vmi
/// (flagged in `styleLeadPt`'s own doc comment).
///
/// Direct port of `tests/test_style_leading.py` (ctrl-kd, commit 9e87a7a; mechanism T
/// numbers re-ported at 21e6d94) — same pinned numbers, same case names (Swift-cased),
/// same fixture shapes.

/// Distinct baseline Y positions, in the order they were drawn — one entry per `Td`
/// operator in the content stream (the several `BT..ET` blocks a single `PageLine` can
/// split into for a font/colour change reissue the SAME y, deduplicated here exactly as
/// Python's `_line_ys` test helper does). Port of `_line_ys`.
private func lineYs(_ pdf: [UInt8]) -> [Double] {
    var out: [Double] = []
    for y in contentSpans(pdf).compactMap(\.y) {
        if let last = out.last, abs(last - y) <= 1e-6 { continue }
        out.append(y)
    }
    return out
}

/// Baseline-to-baseline gaps between consecutive drawn lines, in points, rounded to 4
/// decimals (float subtraction noise only — the writer itself prints one decimal). Port
/// of `_gaps`.
///
/// `pageNumbers: .off`: this module measures LEADING, not page numbers — the stock
/// automatic number (`.auto`, the real default since 2026-09-07, ws7-prints/v3 finding
/// #2, ported from ctrl-kd b6d5d03) would otherwise inject its own `Td` span into
/// `lineYs`' sequence and corrupt the very first gap measured.
private func gaps(_ doc: Document, mode: EmitMode = .printed) -> [Double] {
    let pdf = emitPDF(doc, mode: mode, options: EmitOptions(pageNumbers: .off))
    let ys = lineYs(pdf)
    guard ys.count > 1 else { return [] }
    var out: [Double] = []
    for i in 1..<ys.count {
        let diff: Double = ys[i - 1] - ys[i]
        let rounded: Double = (diff * 10000).rounded() / 10000
        out.append(rounded)
    }
    return out
}

// 16pt / 12pt styles, both auto (-2) — the ONLY vmi value LYING.WS's real styles ever
// carry.
private let auto16pt = styleRecord(font: (width: 180, height: 320, typestyle: 0), vmi: -2)
private let auto12pt = styleRecord(font: (width: 180, height: 240, typestyle: 0), vmi: -2)

@Test func autoVMILeadingMatchesMeasuredLyingGapProfile() {
    // Two consecutive lines under the SAME auto-leading style: 16pt style -> 16.0pt gap,
    // 12pt style -> 12.0pt gap (stock autoLeadFactor=1.0). Pins the ws7-prints/v3
    // (PRISTINE.EXE) oracle's own numbers (LYING.pcl: Title->Author 160 decipoints,
    // Body-to-Body 120 decipoints — 1/1.2 of the v1/Sawyer-install numbers this test
    // pinned before mechanism T).
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Big", record: auto16pt), (name: "Body", record: auto12pt),
    ])
    let body = styleRef(2) + bytes("First big line.") + HARD + bytes("Second big line.") + HARD
        + styleRef(3) + bytes("First body line.") + HARD + bytes("Second body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.blocks[0].lineHeightVMI == -2)
    #expect(doc.blocks[0].styleFontPt == 16.0)
    let g = gaps(doc)
    #expect(g.first == 16.0)                        // within the 16pt block
    #expect(g.last == 12.0)                         // within the 12pt block
}

@Test func blankLineBetweenStylesAdvancesAtItsOwnBlocksLeading() {
    // The exact structural shape of LYING.WS itself: a style-ref, one text line, a BLANK
    // line, then a style switch to a smaller style and its own text line. The blank line
    // attaches to the OLD (16pt) block, so it advances by 16.0pt, not the new block's
    // 12.0pt — the combined gap across the blank line is 16.0 + 12.0 = 28.0pt, exactly
    // LYING.pcl's ws7-prints/v3 measured 280-decipoint gap ("by Mark Twain" to "Essay,
    // For Discussion...").
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Big", record: auto16pt), (name: "Body", record: auto12pt),
    ])
    let body = styleRef(2) + bytes("Last big line.") + HARD + HARD
        + styleRef(3) + bytes("First body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    // the blank Line landed on the OLD (16pt) block, confirming which style the measured
    // 16.0+12.0 split is attributed to
    #expect(doc.blocks[0].styleName == "Big")
    #expect(doc.blocks[0].lines.count == 2)          // text line + blank
    #expect(doc.blocks[0].lines[1].spans.isEmpty)
    #expect(gaps(doc) == [28.0])
}

// 16pt / 12pt styles with an EXPLICIT (not auto) vmi=240 -- WARPRAYR.WS's real
// Author/Body style records (240/20 = 12.0pt: too small for the 16pt style, exactly
// right for the 12pt one).
private let exp240At16pt = styleRecord(font: (width: 180, height: 320, typestyle: 0), vmi: 240)
private let exp240At12pt = styleRecord(font: (width: 180, height: 240, typestyle: 0), vmi: 240)

@Test func enteringLineAfterTooSmallVMIStyleUsesRawNotFallback() {
    // Fix C (b26-print-fidelity-2, WARPRAYR.WS): the SAME structural shape as the
    // sibling LYING-shaped test above (a style-ref, one text line, a BLANK line, a
    // style switch, the next style's own text line), but the OUTGOING style has an
    // EXPLICIT vmi too small for its own font (WARPRAYR's Author: vmi=240=12pt on a
    // 16pt font -- Finding B's fallback makes ITS OWN first line's entry gap 19.2pt).
    // Its trailing BLANK line does NOT also take that 19.2pt fallback (nothing to
    // clip, see `styleLeadPt`'s `raw` parameter): it advances at the RAW, unfallen-
    // back vmi/20 (12.0pt) -- and the entering Body line (vmi=240=12pt, fits its OWN
    // font, no fallback needed either) advances at its own 12.0pt too, no floor needed
    // (12.0 >= 12.0 already). Combined: 12.0 + 12.0 = 24.0pt -- WARPRAYR.pcl's
    // measured gap ("by Mark Twain" to "It was a time...", 240 decipoints), NOT
    // 19.2 + 12.0 = 31.2 (the pre-Fix-C bug, treating Finding B's fallback as
    // block-wide).
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Author", record: exp240At16pt), (name: "Body", record: exp240At12pt),
    ])
    let body = styleRef(2) + bytes("The byline itself.") + HARD + HARD
        + styleRef(3) + bytes("First body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.blocks[0].lineHeightVMI == 240)
    #expect(doc.blocks[0].lines.count == 2)          // text line + blank
    #expect(gaps(doc) == [24.0])
}

@Test func enteringLineAfterAutoStyleIsFlooredAtTheAutoLead() {
    // Fix C's OTHER direction, WARPRAYR's Quote -> Body (a genuinely AUTO style,
    // vmi=-2, into an EXPLICIT vmi=240=12pt style that fits its own font): the
    // entering Body line's own 12.0pt gap is FLOORED at the outgoing Quote block's
    // own 12.0pt (autoLeadFactor=1.0 x its 12pt font, stock) -- an EXPLICIT style's
    // first line never sits closer to what preceded it than that content's own
    // natural lead was (a no-op at stock's factor, since both sides already land on
    // 12.0 -- the floor's existence is proven by the Sawyer/v1 numbers instead, see
    // below). Quote's trailing blank advances at its own unambiguous 12.0pt (auto
    // has no raw-vs-fallback distinction). Combined: 12.0 + 12.0 = 24.0pt --
    // WARPRAYR.pcl's ws7-prints/v3 measured gap ('Thunder thy clarion...' to 'Then
    // came the "long" prayer...', 240 decipoints; was 28.8pt = 14.4 + 14.4 under
    // Sawyer's install/v1, NOT 14.4 + 12.0 = 26.4, the pre-Fix-C bug: Body's own
    // entering gap, un-floored).
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Quote", record: auto12pt), (name: "Body", record: exp240At12pt),
    ])
    let body = styleRef(2) + bytes("Last quote line.") + HARD + HARD
        + styleRef(3) + bytes("First body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(gaps(doc) == [24.0])
}

@Test func enteringAnAutoStyleIsNeverFloored() {
    // The negative case the floor must NOT fire for: WARPRAYR's Body -> Quote (an
    // EXPLICIT vmi=240=12pt style into a genuinely AUTO one) -- `enteringLeadPt`'s own
    // guard only floors a block being entered that HAS an explicit vmi; Quote (auto)
    // is entered at its own natural 12.0pt (stock), never floored up against Body's
    // own outgoing 12.0pt (which wouldn't raise it anyway) or down. Body's trailing
    // blank advances at its own 12.0pt (vmi=240 fits its 12pt font -- no raw-vs-fallback
    // distinction possible here either). Combined: 12.0 + 12.0 = 24.0pt --
    // WARPRAYR.pcl's ws7-prints/v3 measured gap ('...that tremendous invocation--' to
    // '"God the all-terrible!...', 240 decipoints; was 26.4pt = 12.0 + 14.4 under
    // Sawyer's install/v1), unchanged by Fix C.
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Body", record: exp240At12pt), (name: "Quote", record: auto12pt),
    ])
    let body = styleRef(2) + bytes("Last body line.") + HARD + HARD
        + styleRef(3) + bytes("First quote line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(gaps(doc) == [24.0])
}

@Test func explicitVMIIsAbsolutePointsUnlessTooSmallForItsFont() {
    // vmi=240 (WSFORMAT.WS: same 1/1440in unit as a font's own height word, so 240/20.0 =
    // 12.0pt) recurs unchanged in DARKNESS.WS/WARPRAYR.WS's real style records at 12pt
    // fonts (WARPRAYR's Body, DARKNESS's Manuscript/Quotation) -- the value does not scale
    // with the font the way -2/auto does, AS LONG AS it is not smaller than the font
    // itself. Finding B (b26-print-fidelity-2, WARPRAYR.pcl): the SAME 240 at a 16pt font
    // (WARPRAYR's Author/byline) measures 16.0pt on real stock WS7 (mechanism T:
    // autoLeadFactor=1.0 x 16; was 19.2pt/1.2x16 under Sawyer's install, ws7-prints/v1) --
    // the SAME auto formula an unset vmi gets on that line, because 12pt leading cannot
    // hold 16pt type. Absolute ONLY when it fits; a fallback, not a scaling rule, so a
    // vmi genuinely larger than its font (never measured, but not this rule's business to
    // invent a ceiling for) would stay absolute too -- see `styleLeadPt`'s own doc comment
    // for the full evidence trail, including the reverted vmi==240-always-auto
    // over-generalisation this fix replaces with a narrower, font-relative one.
    let exp16 = styleRecord(font: (width: 180, height: 320, typestyle: 0), vmi: 240)
    let exp12 = styleRecord(font: (width: 180, height: 240, typestyle: 0), vmi: 240)
    let body = styleRef(2) + bytes("Line one.") + HARD + bytes("Line two.") + HARD
    for (rec, want) in [(exp16, 16.0), (exp12, 12.0)] {
        let lib = styleLibrary([
            (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
            (name: "Exp", record: rec),
        ])
        let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
        #expect(doc.blocks[0].lineHeightVMI == 240)
        #expect(gaps(doc) == [want])
    }
}

@Test func styleAutoWithNoFontOfItsOwnFallsBackToDocumentSize() {
    // A style can set lineHeightVMI=-2 (auto) while declaring no font of its own
    // (font=nil -> the parser's f0==-1 'inherit' sentinel, so Block.styleFontPt stays
    // nil) -- `styleLeadPt` falls back to the document's own printed SIZE (the .cw-derived
    // default, 12pt here) rather than crashing or silently picking an arbitrary size.
    let rec = styleRecord(vmi: -2)
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "AutoNoFont", record: rec),
    ])
    let body = styleRef(2) + bytes("Line one.") + HARD + bytes("Line two.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.blocks[0].styleFontPt == nil)
    #expect(gaps(doc) == [12.0])                     // autoLeadFactor (1.0) x document default 12pt
}

@Test func styleAutoLeadingOutranksAnActiveLhDotCommand() {
    // RESOLVED (planning #256, sawyer/REF/-HOW-TO.RJS) -- this test used to be named
    // `lhDotCommandOverridesStyleAutoLeading` and pinned the OPPOSITE result, on the
    // stated reasoning "no corpus evidence exists for how real WS7 arbitrates a style's
    // own vmi against an ACTIVE `.lh` dot command". -HOW-TO.RJS IS that evidence now
    // (see `styleLeadPt`'s own doc comment, PDFLayout.swift): a paragraph style's own
    // leading governs OUTRIGHT once the block carries one -- `.lh 20` (30pt) no longer
    // wins over the 16pt style's own 16.0pt auto leading (stock autoLeadFactor = 1.0).
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Big", record: auto16pt),
    ])
    let body = bytes(".lh 20") + HARD
        + styleRef(2) + bytes("Line one.") + HARD + bytes("Line two.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.page?.lhSource == .file)
    #expect(gaps(doc) == [16.0])
}

@Test func stylelessDocLeadingIsUnchanged() {
    // A document with no style library at all (WS4, or a WS7 file that never selected a
    // style) must render at exactly the pre-existing document-default leading -- 12.0pt
    // (`.lh` default 8/48in x 1.5) -- UNCHANGED by this fix.
    let doc = parseWS(
        ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
            + bytes("Line one.") + HARD + bytes("Line two.") + HARD + bytes("Line three.") + HARD)
    #expect(doc.blocks[0].lineHeightVMI == nil)
    #expect(gaps(doc) == [12.0, 12.0])
}

@Test func styleAutoLeadingNeverReachesModernPDF() {
    // Modern PDF already spaces lines by their own font size (a wholly separate,
    // pre-existing mechanism keyed off each span's font tag, not `Block.lineHeightVMI`) --
    // so it is not enough to check for a particular number; two documents that share
    // EVERY byte except `lineHeightVMI` (-2 'auto' vs an EXPLICIT vmi, which printed mode
    // renders at two different leadings, proven below) must render to BYTE-IDENTICAL
    // Modern PDF output, because Modern never reads that field at all.
    //
    // Mechanism T note: at stock autoLeadFactor=1.0, a 12pt font's auto leading (12.0pt)
    // now numerically COINCIDES with vmi=240 (=12.0pt, exactly fitting a 12pt font) --
    // using that combination here would no longer prove printed reads the field at all
    // (both paths would produce 12.0pt regardless of a bug). So this test uses an
    // explicit vmi that FITS its font but is not equal to it (vmi=300=15.0pt on the same
    // 12pt font -- 15.0 >= 12.0, no too-small fallback, stays absolute), which stays
    // genuinely distinct from the auto value at any factor.
    func docWithVMI(_ vmi: Int) -> Document {
        let rec = styleRecord(font: (width: 180, height: 240, typestyle: 0), vmi: vmi)
        let lib = styleLibrary([
            (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
            (name: "Big", record: rec),
        ])
        let body = styleRef(2) + bytes("Line one.") + HARD + bytes("Line two.") + HARD
        return parseWS(documentWithStyleLibrary(body: body, library: lib))
    }

    let autoDoc = docWithVMI(-2)            // -2, auto -> 12.0pt (stock)
    let explicitDoc = docWithVMI(300)       // explicit 15.0pt, fits its 12pt font

    #expect(gaps(autoDoc, mode: .printed) == [12.0])
    #expect(gaps(explicitDoc, mode: .printed) == [15.0])
    #expect(emitPDF(autoDoc, mode: .modern) == emitPDF(explicitDoc, mode: .modern))
}

// ============================================================================
// Ruling 2026-08-26 (mirrored from ctrl-kd ebc2939, register row, b33 field notes N2):
// Printed/Native RTF's own `\sl` used to read ONLY `.lh` dot-state (`rtfBlockLead48`,
// pre-fix), never this file's own style-driven leading -- every document above rendered
// ONE flat `\sl` for its whole body in RTF even though its Printed PDF (same document,
// same functions) already varied it correctly. `rtfBlockLead48` now delegates to
// `resolvedPrintedLeads48`, which recomputes the SAME per-line precedence (`leadPt`/
// `styleLeadPt`/`enteringLeadPt`/`fontLeadPt`) `docToPagelines` uses for the PDF page,
// collapsed to each block's own first real line -- these tests pin that RTF now agrees
// with the PDF gaps already proven above, in twips (1/48in unit * 30 twips/48in-unit,
// negative/EXACT per `rtfSlTwips`).

/// Every `\sl` VALUE that actually appears as a direct token in `r`, in document order --
/// the persistence optimisation (`rtfEmitPara`) means a paragraph whose own resolved
/// lead is UNCHANGED from the one still in force emits no new token at all, so this is
/// "every point the lead changed", not "one entry per paragraph". Port of
/// `_rtf_sl_sequence`.
private func rtfSlSequence(_ r: String) -> [Int] {
    let pattern = #"\\sl(-?\d+)\\slmult0 "#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = r as NSString
    return re.matches(in: r, range: NSRange(location: 0, length: ns.length)).compactMap {
        Int(ns.substring(with: $0.range(at: 1)))
    }
}

@Test func autoVMILeadingReachesPrintedRTFAsTwoDistinctSlValues() {
    // The exact fixture behind `blankLineBetweenStylesAdvancesAtItsOwnBlocksLeading`
    // (16pt Title/Author style, 12pt Body style, both auto/-2, a blank line between them
    // -- LYING.WS's own real shape) -- the real LYING.WS/WARPRAYR.WS b33 clipping case: a
    // 16pt title on a document whose OWN plain default is 12pt. Pre-fix this was a single
    // `\sl-240\slmult0` throughout (12pt, clipping the 16pt title in Word/TextEdit); now
    // two distinct values.
    //
    // FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): the original comment
    // justified the twip values by pointing at "the PDF gaps already proven above"
    // (another test's own literal, times 20) -- independently re-derived here instead,
    // straight from real WS7: LYING.pcl's ws7-prints/v3 (stock, mechanism T) measured 160
    // decipoints (Title->Author) and 120 decipoints (Body-to-Body) -- decipoints are
    // PCL's own 1/10-point unit, so that IS 16.0pt/12.0pt, not a re-derivation of this
    // codebase's own arithmetic. RTF's twip (1/1440in, i.e. 20/pt) is external to this
    // codebase too: 16.0 * 20 = 320, 12.0 * 20 = 240.
    //
    // UPDATE 2026-09-08 (#236): this fixture used to butt "Second big line." directly
    // against "First body line." with NO blank line between the two blocks. #236
    // (INTERVU.WS's title block, measured directly against WS7's own capture) proved
    // `enteringLeadPt`'s floor must ALSO engage for an auto (-2) entering block when the
    // line above is REAL and no blank line already provided separation -- exactly this
    // fixture's old shape, which floored Body's entering gap up to Big's own 16.0pt.
    // RTF's `\sl` is collapsed to one value per BLOCK (`rtfBlockLead48`, the ceiling of
    // what RTF's paragraph-only leading can express), so that floored entering value
    // became the WHOLE Body block's `\sl`, legitimately collapsing both values to -320
    // and defeating this test's own "two distinct values" proof. A blank line between
    // the two blocks (added below, matching LYING.WS's real shape and the sibling PDF
    // test's own fixture) sits BEFORE the floor's real-adjacency condition, so it is
    // unaffected by it and still demonstrates genuine per-block differentiation. Direct
    // port of ctrl-kd's own identical fixture update, `test_auto_vmi_leading_reaches_
    // printed_rtf_as_two_distinct_sl_values` (commit f274d9b).
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Big", record: auto16pt), (name: "Body", record: auto12pt),
    ])
    let body = styleRef(2) + bytes("First big line.") + HARD + bytes("Second big line.") + HARD + HARD
        + styleRef(3) + bytes("First body line.") + HARD + bytes("Second body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    let r = emitRTF(doc, mode: .printed)
    // Two DISTINCT values is the proof (the pre-fix bug emitted ONE flat \sl throughout)
    // -- mechanism T note: at stock autoLeadFactor=1.0 the Body style's own correct
    // 12.0pt legitimately coincides with the NUMBER the old pre-fix bug also used (both
    // are -240 twips), so checking for that string's absence would no longer distinguish
    // "still broken" from "correctly differentiated" -- the sequence check below is the
    // real assertion.
    #expect(rtfSlSequence(r) == [-320, -240])        // 16.0pt, 12.0pt in twips
}

@Test func explicitVMITooSmallForFontReachesPrintedRTFToo() {
    // WARPRAYR.WS's real shape: an EXPLICIT vmi (240=12pt) too small for its own 16pt
    // font falls back to the SAME auto formula (Finding B), 16.0pt at stock (mechanism T;
    // was 19.2pt under Sawyer's install) -- confirmed at PDF level by
    // `enteringLineAfterTooSmallVMIStyleUsesRawNotFallback`'s sibling
    // `explicitVMIIsAbsolutePointsUnlessTooSmallForItsFont`.
    //
    // FIX (planning #199, Test-Truth-Audit-2026-09-05 section 2(i)): independently
    // re-derived rather than "pins the identical value" from that sibling test. VMI is
    // WordStar's own 1/1440in unit (external fact, not this codebase's invention): the
    // 16pt style's font height1440 is 320 (320/1440in * 72pt/in = 16pt); its EXPLICIT
    // vmi=240 is 240/1440in*72 = 12pt, smaller than its own 16pt font, so Finding B's
    // documented auto-fallback applies -- 16 * autoLeadFactor (1.0, stock) = 16.0pt,
    // RTF's twip (20/pt, external to this codebase) makes that -320. The 12pt style's
    // explicit vmi=240 IS its own font height (240/1440*72 = 12pt = its own font1440
    // 240), so no fallback: 12 * 20 = -240 directly, no `* autoLeadFactor` involved.
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Author", record: exp240At16pt), (name: "Body", record: exp240At12pt),
    ])
    let body = styleRef(2) + bytes("The byline itself.") + HARD
        + styleRef(3) + bytes("First body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    let r = emitRTF(doc, mode: .printed)
    #expect(rtfSlSequence(r) == [-320, -240])         // 16.0pt fallback, 12.0pt fits
}

@Test func styleAutoLeadingOutranksAnActiveLhDotCommandInRTFToo() {
    // RTF's own leading must match the PDF one exactly (same shared mechanism --
    // planning #256, see `styleAutoLeadingOutranksAnActiveLhDotCommand` at the PDF
    // layer for the evidence): `.lh 20` (30pt) no longer wins over the 16pt style's own
    // 16.0pt auto leading.
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Big", record: auto16pt),
    ])
    let body = bytes(".lh 20") + HARD
        + styleRef(2) + bytes("Line one.") + HARD + bytes("Line two.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.page?.lhSource == .file)
    let r = emitRTF(doc, mode: .printed)
    #expect(rtfSlSequence(r) == [-320])               // 16.0pt autoLeadFactor x 16pt
}

@Test func midDocumentLhChangeProducesTwoDistinctRTFSlValues() {
    // A styleless document (no style library at all -- WS4/plain WS7 shape) whose OWN
    // `.lh` dot command changes MID-DOCUMENT (after body text has already begun, so
    // `doc.page?.lhSource` -- which parseWS resolves from only a PRE-TEXT `.lh` --
    // stays `.default`; the per-LINE override this test actually exercises is
    // `Line.lead48`, a separate, genuinely stateful mechanism): RTF's `\sl` is a
    // paragraph property, so each paragraph's own first line's `.lh` state must be
    // reflected, same "ceiling of what RTF can express per paragraph" doctrine as the
    // style-driven case above. Pre-fix this was already meant to work (the original
    // `rtfBlockLead48` read `Line.lead48` directly) -- pinned here explicitly because
    // this fix replaces that function's entire body and must not regress the case it
    // already handled.
    let body = bytes("First paragraph at the document default.") + HARD + HARD
        + bytes(".lh 16") + HARD
        + bytes("Second paragraph after the .lh change.") + HARD
    let doc = parseWS(
        ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body)
    #expect(doc.blocks.count == 2)                    // a real block boundary
    #expect(doc.blocks.last?.lines.first?.lead48 == 16.0)  // the stateful override landed
    let r = emitRTF(doc, mode: .printed)
    // default .lh 8 = 12pt = -240 twips; changed .lh 16 = 24pt = -480 twips
    #expect(rtfSlSequence(r) == [-240, -480])
}

// planning #256 (sawyer/REF/-HOW-TO.RJS): a 14pt style-governed heading whose style vmi
// (240=12pt) is too small for its own font (Finding B fallback -> 14pt) immediately
// followed by a 10pt style-governed body paragraph whose SAME-shaped vmi (240=12pt) DOES
// fit its own font (direct, no fallback -> 12pt) -- both AFTER a plain, unstyled `.lh 16`
// (24pt) sets `Line.lead48` stateful per-line leading. Measured against the real
// capture: the heading prints at 14.0pt and the body at 12.0pt -- NEITHER ever uses the
// stale 24.0pt `.lh` value, even though `Line.lead48` for both blocks' lines carries it.
// Before this fix, `ownLead = styleLead` in every PDF page-line builder only fired when
// `line.lead48 == nil || line.lead48 == defaultLh48` -- a line carrying ANY other
// explicit `.lh` value (stale or not) locked out its own block's style entirely,
// silently reproducing exactly this document's real bug (140+ compounding
// baseline-shift divergences and an extra, wrongly-paginated 13th page against WS7's
// real 12 -- see planning #256's own before/after).
private let howtoHeading14pt = styleRecord(font: (width: 180, height: 280, typestyle: 0), vmi: 240)   // 14pt font
private let howtoBody10pt = styleRecord(font: (width: 180, height: 200, typestyle: 0), vmi: 240)      // 10pt font

@Test func staleLhNeverOutranksALaterBlocksOwnStyleVMI() {
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil), (name: "WordStar Defaults", record: nil),
        (name: "Heading", record: howtoHeading14pt), (name: "Body", record: howtoBody10pt),
    ])
    var body = bytes("Padding prose so the detector reads this as a document.") + HARD
    body += bytes(".lh 16") + HARD                     // stateful lead48 = 16 (24pt)
    body += styleRef(2) + bytes("First heading line.") + HARD
    body += bytes("Second heading line.") + HARD
    body += styleRef(3) + bytes("First body line.") + HARD
    body += bytes("Second body line.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    // the document's OWN default stays untouched (matches -HOW-TO.RJS's own shape: this
    // `.lh` sits after real text) -- this fix does NOT depend on `lhSource`; a stale
    // `Line.lead48` blocked the style regardless of it.
    #expect(doc.page?.lhSource == .default)
    let g = gaps(doc)
    // heading line 1 -> line 2 (NOT first-line-of-block, plain styleLeadPt): too-small
    // vmi (12) for a 14pt font falls back to 14.0, never the stale 24.0.
    #expect(g.contains(14.0))
    // body line 1 -> line 2 (NOT first-line-of-block): vmi 12 fits a 10pt font directly,
    // never the stale 24.0.
    #expect(g.contains(12.0))
    #expect(!g.contains(24.0))
}
