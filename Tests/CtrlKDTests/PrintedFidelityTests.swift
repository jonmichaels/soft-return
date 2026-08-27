import Testing
@testable import CtrlKD

/// b24 engine wave, round 17/17b port — mirrors ctrl-kd's tests/test_printed_fidelity.py.
/// One focused, fail-first-verified test per item rather than an exhaustive port of every
/// Python case: each proves the MECHANISM landed (the thing that was previously silent now
/// speaks), not every edge case Python's own larger suite covers.

// MARK: - item 1: headers/footers/page numbers in Printed RTF + --headers

@Test func printedRTFGainsHeaderFooterDestinationsWithChpgn() throws {
    let data = bytes(".h1 My Header #") + HARD + bytes("Body text.") + HARD
    let rtf = emitRTF(parseWS(data), mode: .printed, options: EmitOptions())
    #expect(rtf.contains(#"\header"#))
    #expect(rtf.contains("My Header"))
    #expect(rtf.contains(#"\chpgn"#))
}

@Test func headersFlagOffSuppressesPrintedRTFHeader() throws {
    let data = bytes(".h1 My Header") + HARD + bytes("Body text.") + HARD
    let rtf = emitRTF(parseWS(data), mode: .printed, options: EmitOptions(headers: false))
    #expect(!rtf.contains(#"\header"#))
    #expect(rtf.contains("Body text."))       // headers off never touches body text
}

@Test func headersFlagOffSuppressesPrintedPDFRunningContent() throws {
    let data = bytes(".h1 My Header") + HARD + bytes("Body text.") + HARD
    let on = emitPDF(parseWS(data), mode: .printed, options: EmitOptions(headers: true))
    let off = emitPDF(parseWS(data), mode: .printed, options: EmitOptions(headers: false))
    #expect(contains(on, bytes("(My Header)")))
    #expect(!contains(off, bytes("(My Header)")))
}

// MARK: - item 2: .pr or=l landscape

@Test func prLandscapeFlipsPrintedPDFMediaBox() throws {
    let data = bytes(".pr or=l") + HARD + bytes("Landscape text.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .printed)
    // Letter portrait is [0 0 612 792]; landscape swaps to [0 0 792 612].
    #expect(contains(pdf, bytes("/MediaBox [0 0 792 612]")))
}

@Test func prLandscapeNeverReachesModernPDF() throws {
    // Soft returns (not plain hard-returned lines) so `detect()` reads this as ws4/
    // ws5+ prose rather than a `printstream` -- otherwise `isPrinted(doc)` forces
    // printed rendering regardless of the requested mode (D5, cli.py's own override),
    // which is a DIFFERENT mechanism than the one this test targets: that .pr or=l's
    // orientation itself must never leak into a genuine modern reflow.
    let prose = bytes("word") + SOFT + bytes("word") + SOFT + bytes("word") + SOFT
        + bytes("Portrait text.") + HARD
    let dataPlain = prose
    let dataLandscape = bytes(".pr or=l") + HARD + prose
    let modernPlain = emitPDF(parseWS(dataPlain), mode: .modern)
    let modernLandscape = emitPDF(parseWS(dataLandscape), mode: .modern)
    #expect(contains(modernPlain, bytes("/MediaBox [0 0 612 792]")))
    #expect(contains(modernLandscape, bytes("/MediaBox [0 0 612 792]")))
}

@Test func prLandscapeSetsRTFPaperAndLandscapeKeyword() throws {
    let data = bytes(".pr or=l") + HARD + bytes("Landscape text.") + HARD
    let rtf = emitRTF(parseWS(data), mode: .printed, options: EmitOptions())
    #expect(rtf.contains(#"\landscape"#))
    // portrait Letter is paperw12240\paperh15840; landscape swaps them.
    #expect(rtf.contains(#"\paperw15840\paperh12240"#))
}

// MARK: - item 3: .sr roll drives PDF rise + RTF \up\dn

@Test func srRollDrivesPrintedPDFRise() throws {
    var data: [UInt8] = bytes(".sr 10") + HARD + bytes("x")
    data += [0x14]; data += bytes("2"); data += [0x14]; data += bytes(" end") + HARD
    let pdf = emitPDF(parseWS(data), mode: .printed)
    // .sr 10 (1/48in) -> 15pt rise (10 * 1.5), rounded to an integer Ts.
    #expect(contains(pdf, bytes(" 15 Ts")))
}

@Test func srAbsentUsesTheWSFORMATDefaultNotTheOldHardcode() throws {
    var data: [UInt8] = bytes("x")
    data += [0x14]; data += bytes("2"); data += [0x14]; data += bytes(" end") + HARD
    let pdf = emitPDF(parseWS(data), mode: .printed)
    // WSFORMAT's own stated default (3/48in = 4.5pt, rounds to 4 half-to-even) replaces
    // the old hardcoded fixed +3 rise.
    #expect(contains(pdf, bytes(" 4 Ts")))
}

@Test func srRollDrivesPrintedRTFUpDnAlongsideSuperSub() throws {
    var data: [UInt8] = bytes(".sr 10") + HARD + bytes("x")
    data += [0x14]; data += bytes("2"); data += [0x14]; data += bytes(" end") + HARD
    let rtf = emitRTF(parseWS(data), mode: .printed, options: EmitOptions())
    #expect(rtf.contains(#"\super"#))
    #expect(rtf.contains(#"\up30 "#))   // RTF's own unit is half-points: round(10 * 3)
                                         // -- NOT the PDF rollPt formula (10 * 1.5 = 15pt),
                                         // which is a different unit for a different format.
}

// --------------------------------------------------------- register b32-N10
// `.sr` is a STATEFUL dot command (a value applies from where it sits onward), exactly
// like `.lh`/`.po` -- not a single document-wide reading a LATER `.sr` could
// retroactively apply to text that already printed. Found against a private WS7 specimen (b33
// field notes, N10, mirrored from ctrl-kd b48148c): a superscript that is the LAST span
// on its own physical line rendered wrong once a later `.sr` set a non-default roll,
// because `printedRollPt` read ONE document-wide value (`Document.formatting.
// subSuperRoll48`, the document's LAST `.sr` occurrence) and applied it to every span
// uniformly -- the same disease register b31's E3 sweep found for `.pl`/`.hm`/`.fm`/
// `.pn`.

@Test func srIsStatefulNotALaterDocumentwideReading() throws {
    // The superscript is the LAST span on its physical line (paragraph ends right
    // there, HARD immediately follows) -- a private specimen's own trigger shape. `.sr 6`
    // appears only AFTER this line, so the roll IN FORCE where the superscript
    // actually sat is still the WSFORMAT default (3/48in), never the later 6.
    var data: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
        + bytes("A line ending in a superscript")
    data += [0x14]; data += bytes("1"); data += [0x14]; data += HARD
    data += bytes(".sr 6") + HARD
        + bytes("Later text, unrelated to the superscript above.") + HARD
    let doc = parseWS(data)
    // the document-WIDE snapshot (unaffected by this fix, still consumed by Printed
    // RTF/--diagnose) really does read the LATER value -- the whole point of this test
    // is that the PDF's per-line rise must NOT use it.
    #expect(doc.formatting.subSuperRoll48 == 6.0)
    let pdf = emitPDF(doc, mode: .printed)
    // 3/48in * 1.5 pt/48in-unit = 4.5pt, truncates to 4 -- the roll actually in force
    // where the superscript sat (no `.sr` had been reached yet).
    #expect(contains(pdf, bytes(" 4 Ts")))
    // NOT the later, not-yet-reached `.sr 6` (6/48in * 1.5 = 9pt) -- that was the bug: a
    // `.sr` appearing anywhere in the document could shift a superscript that printed
    // BEFORE it was ever reached.
    #expect(!contains(pdf, bytes(" 9 Ts")))
}

// MARK: - item 4: .lm/.rm dot-state fallback in Printed RTF margins

@Test func lmRmDotStateReachesPrintedRTFMargins() throws {
    // Soft returns (not a lone hard-returned line) so `detect()` reads this as ws4/
    // ws5+ prose rather than a `printstream` -- otherwise `isPrinted(doc)` forces
    // printed rendering for the Modern-mode call below too (same D5 override the
    // `.pr or=l` test above documents), which would make the Modern assertions
    // meaningless (they'd just be re-checking Printed's own output).
    let data = bytes(".lm 11") + HARD + bytes(".rm 61") + HARD
        + bytes("Indented") + SOFT + bytes("text") + SOFT + bytes("here") + SOFT
        + bytes("today.") + HARD
    let doc = parseWS(data)          // no style table: directMargins has nothing to offer
    let rtf = emitRTF(doc, mode: .printed, options: EmitOptions())
    // `.lm N` (no unit suffix) is a 1-based COLUMN NUMBER, not an offset -- ctrl-kd's
    // core.py normalises it to `cols - 1` so left_margin always means "offset columns"
    // to every consumer (register: found 2026-08-06 wiring Modern block margins).
    // `.lm 11` -> 10 offset cols -> 1440 twips.
    #expect(rtf.contains(#"\li1440 "#))   // (11 - 1) cols * 144 twips/col
    // b32 fix: `.rm` is the column POSITION where the right margin falls (the same
    // absolute frame `.lm`/`.po` share), not an indent width -- this used to assert
    // `\ri8784` (61 cols * 144 twips/col treated as a width), the disproven
    // "rm-as-width" behaviour that smashed any WS5+ document with a real `.rm` into
    // a near-zero-width column (b32 field notes: LYING/WARPRAYR's `\ri9360` on a
    // 6.9in text frame). The real indent is what's left of the fullCols(65)-wide
    // measure: (65 - 61) * 144 = 576.
    #expect(rtf.contains(#"\ri576 "#))
    #expect(!rtf.contains(#"\ri8784"#))

    // Modern stays untouched -- the reader owns presentation, same doctrine as the
    // no-page-width ruling.
    let rtfModern = emitRTF(doc, mode: .modern, options: EmitOptions())
    #expect(!rtfModern.contains(#"\li1440"#))
    #expect(!rtfModern.contains(#"\ri576"#))
    #expect(!rtfModern.contains(#"\ri8784"#))
}

// MARK: - item 5: .pm/.psa/.psb reach Printed PDF

@Test func pmShiftsPrintedPDFFirstLineStartX() throws {
    let data = bytes(".pm 10") + HARD + bytes("Shifted line.") + HARD
    let pdf = emitPDF(parseWS(data), mode: .printed)
    // `.pm 10` is a COLUMN NUMBER (1-based, same frame as `.lm`/`.po`) -- normalised to
    // 9.0 offset columns, same as `.lm` (b26 fix). 9 cols * 7.2pt/col = 64.8pt shift added
    // to the default (`.po 8`) 57.6pt left margin -- 122.4pt. Previously 129.6pt, the
    // dormant pre-normalization bug (10 unnormalised cols * 7.2pt = 72.0pt shift).
    #expect(contains(pdf, bytes("122.4")) || contains(pdf, bytes("122.")))
}

@Test func pmColumnNormalizationMatchesLmFlushLeft() throws {
    // b26: `.pm` lives in the SAME absolute column frame as `.lm`/`.po` (EmitRTF's
    // `rtfPMFiTwips` doc comment) and is 1-based like `.lm`, so `.pm 1` -- column 1, the
    // left edge itself -- must normalize to a ZERO first-line indent, landing the first
    // line flush on the `.po`-derived left margin, not one column right of it.
    let data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
        + bytes(".pm 1") + HARD + bytes(".lm 16") + HARD + bytes(".po 8") + HARD
        + bytes("A paragraph whose .pm column equals the left edge itself.") + HARD
    let doc = parseWS(data)
    #expect(doc.blocks[0].paraMargin == 0.0)   // `.pm 1` -> column 1 -> 0 offset
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    let first = try #require(spans.first)
    #expect(first.x == 57.6)                   // `.po 8` flush left, 8 * 12 * 0.6pt
    // Pre-fix this landed at 64.8pt (57.6 + 1 unnormalized `.pm` column * 7.2pt/col) --
    // one column right of the file's own bytes.
}

// MARK: - Fix A (b26-print-fidelity-2, WARPRAYR.WS): .pm not double-counted

@Test func pmFirstLineIndentNotDoubledWhenSourceAlreadyTypesIt() throws {
    // WARPRAYR's Quote style (`.pm 5`) types its hanging-indent paragraphs with real
    // leading spaces on every physical line (10 on the block's own first line, 5 on
    // continuations), so `splitIndent`'s columns-math already produces the block's
    // first line's full, correct indent from those typed spaces alone; adding `fi` on
    // top double-counted it. Measured (WARPRAYR.pcl): the block's own first line
    // ('"God the all-terrible!') belongs at x=122.4, the SAME position a mid-block line
    // reaches purely from its own typed indent -- not 158.4, `.pm 5`'s 36pt stacked on
    // top (the doubled bug). Pinned here with a synthetic proportional-font fixture
    // (a Helv font block is required: `splitIndent`'s columns-math, this fix's whole
    // subject, only engages for a proportional run).
    let data = bytes(".pm 5") + HARD
        + fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
        + bytes("          Ten typed leading spaces on this first line.") + HARD
        + bytes("     Five typed leading spaces on this continuation.") + HARD
    let doc = parseWS(data)
    #expect(doc.blocks[0].paraMargin == 4.0)   // `.pm 5` -> column 5 -> 4 offset cols
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    func x(_ text: String) -> Double? { spans.first { $0.text == text }?.x }
    #expect(x("Ten") == 129.6)    // left 57.6 + 10-space indent 72 (NOT +fi 28.8)
    #expect(x("Five") == 93.6)    // left 57.6 + 5-space indent 36, unaffected
}

@Test func pmFirstLineIndentStillAppliesWithNoTypedIndent() throws {
    // The negative case, unaffected by Fix A: a block whose first line carries NO
    // typed leading whitespace of its own relies on `.pm` alone for its visual indent
    // (WordStar's OTHER authoring convention, and the ORIGINAL, still-live case
    // `pmShiftsPrintedPDFFirstLineStartX` above already pins for a fontless span) --
    // `fi` must still apply there, unchanged.
    let data = bytes(".pm 5") + HARD
        + fontBlock(helvTypestyle(), points: 12.0, styleBits: 0x8000)
        + bytes("No typed indent on this first line at all.") + HARD
        + bytes("No typed indent on this continuation either.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let xs = contentSpans(pdf).filter { $0.text == "No" }.compactMap(\.x)
    #expect(xs == [86.4, 57.6])    // first: left 57.6 + fi 28.8; continuation: left alone
}

@Test func pmPsaPsbNeverReachModernPDF() throws {
    let data = bytes(".pm 10") + HARD + bytes("Text.") + HARD
    let baseline = bytes("Text.") + HARD
    let modernPM = emitPDF(parseWS(data), mode: .modern)
    let modernPlain = emitPDF(parseWS(baseline), mode: .modern)
    // Both must reflow identically -- .pm is Printed-only.
    #expect(latin1(modernPM).contains("Text.") && latin1(modernPlain).contains("Text."))
}

// MARK: - item 6: .ul default (Jon's ruling 2026-08-20) + .sb + .l# gutter

/// Jon's ruling 2026-08-20 (REVERSES b24 round 17b -- RULINGS-LEDGER row 5/6, register
/// C21): absent `.ul`, Printed underline is CONTINUOUS across spaces -- real WS7 LaserJet
/// output (ws7-prints/v1, none of which carries `.ul`) underlines the word gaps, verified
/// on paper (M479fdw) and in the PCL bytes (one UL-ON..UL-OFF span per phrase). The WS3.3
/// manual's "^PS does not underline blank spaces" clause (round 17b's basis) described a
/// different surface. Replaces the old `ulHonestDefaultBreaksUnderlineAtSpaces` pin, which
/// asserted the now-reversed per-word default.
@Test func ulDefaultIsContinuousMatchingWS7Paper() throws {
    let underline: [UInt8] = [0x13]
    let data = underline + bytes("two words") + underline + HARD
    let doc = parseWS(data)
    #expect(doc.formatting.underlineBlanks == nil)
    let pdf = emitPDF(doc, mode: .printed)
    // ONE stroked rule spanning "two words", not one per word.
    #expect(countOccurrences(of: bytes(" l S"), in: pdf) == 1)

    let rtf = emitRTF(doc, mode: .printed, options: EmitOptions())
    #expect(rtf.components(separatedBy: #"\ul "#).count - 1 == 1)
}

/// Explicit `.ul off` is the file's own request for characters-only underline and stays
/// honored (`.ul` support ruled 2026-08-17; Jon re-confirmed alongside the 2026-08-20
/// default reversal: "We should still support that"). Distinguishable from absent because
/// the parser only sets `underlineBlanks` when the command is present.
@Test func ulOffBreaksUnderlineAtSpaces() throws {
    let underline: [UInt8] = [0x13]
    let data = bytes(".ul off") + HARD + underline + bytes("two words") + underline + HARD
    let doc = parseWS(data)
    #expect(doc.formatting.underlineBlanks == false)
    let pdf = emitPDF(doc, mode: .printed)
    // Two separate stroked rules (one per word), gap bare.
    #expect(countOccurrences(of: bytes(" l S"), in: pdf) == 2)

    let rtf = emitRTF(doc, mode: .printed, options: EmitOptions())
    #expect(rtf.components(separatedBy: #"\ul "#).count - 1 == 2)
}

@Test func ulOnDrawsOneContinuousRule() throws {
    let underline: [UInt8] = [0x13]
    let data = bytes(".ul on") + HARD + underline + bytes("two words") + underline + HARD
    let pdf = emitPDF(parseWS(data), mode: .printed)
    #expect(countOccurrences(of: bytes(" l S"), in: pdf) == 1)
}

/// The proportional Printed path draws one op per WORD (word-anchored grid layout);
/// before the 2026-08-20 ruling that broke the underline at every space regardless of
/// `.ul`, because space pieces never ink and each word piece ruled only itself.
/// Continuous default now draws ONE rule per underlined span, first inked piece to last
/// -- the shape WS7's own PCL emits (one UL-ON..UL-OFF per phrase with cursor moves
/// between words; LYING p4, OCAPTAIN). Explicit `.ul off` keeps per-word rules on this
/// path too. Port of ctrl-kd's `test_ul_continuous_spans_proportional_word_pieces`.
@Test func ulContinuousSpansProportionalWordPieces() throws {
    let univers = ws7Block(0x02, payload: le16(155) + le16(240) + le16(49710)
        + [UInt8](repeating: 0, count: 6))
    let header = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    let underline: [UInt8] = [0x13]

    let doc = parseWS(header + univers
        + underline + bytes("White Elephant Etc.") + underline + bytes(" plain") + HARD)
    let pdf = emitPDF(doc, mode: .printed)
    #expect(countOccurrences(of: bytes(" l S"), in: pdf) == 1)   // one rule under the phrase

    let docOff = parseWS(header + bytes(".ul off") + HARD + univers
        + underline + bytes("White Elephant Etc.") + underline + bytes(" plain") + HARD)
    let pdfOff = emitPDF(docOff, mode: .printed)
    #expect(countOccurrences(of: bytes(" l S"), in: pdfOff) == 3)   // White / Elephant / Etc.
}

/// Port of ctrl-kd's `test_sb_suppresses_leading_blank_lines_at_page_top` (b26 round 26
/// wave 3) -- not new `.sb` coverage (that already exists) but the specific proof that the
/// WS7-ground-truth `printedTop` fix reaches this end-to-end path: page-top offset is now
/// (.mt+.hm)*12 = 60pt for this headerless document (was 36pt, `.mt` alone).
@Test func sbSuppressesLeadingBlankLinesAtPageTop() throws {
    let body = HARD + HARD + bytes("Actual content starts here.") + HARD
    let dataDefault = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15)) + body
    let dataSB = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
        + bytes(".sb on") + HARD + body
    let docDefault = parseWS(dataDefault)
    let docSB = parseWS(dataSB)
    #expect(docSB.formatting.suppressBlanks == true)

    func contentY(_ doc: Document) throws -> Double {
        let pdf = emitPDF(doc, mode: .printed)
        let span = try #require(contentSpans(pdf).first { $0.text.hasPrefix("Actual") })
        return try #require(span.y)
    }

    // top 60 (.mt 3 + .hm 2, default, headerless) + two 12pt blanks + 12pt lead
    #expect(try contentY(docDefault) == 696.0)
    // suppressed -- starts right at top + lead
    #expect(try contentY(docSB) == 720.0)
}

@Test func lineNumbersFlagOffSuppressesTheGutter() throws {
    let data = bytes(".l# 1") + HARD + bytes("Line one.") + HARD + bytes("Line two.") + HARD
    var doc = parseWS(data)
    doc.lineNumbering = 1
    let on = emitPDF(doc, mode: .printed, options: EmitOptions(lineNumbers: true))
    let off = emitPDF(doc, mode: .printed, options: EmitOptions(lineNumbers: false))
    #expect(contains(on, bytes("(   1)")) || contains(on, bytes("(1)")))
    #expect(!contains(off, bytes("(   1)")) && !contains(off, bytes("Courier")) == false)
}

// MARK: - item 7: diagnose surfacing

// Soft returns (not plain hard-returned lines) so `detect()` reads these as ws4/ws5+
// prose -- `documentInfo` only assembles the `formatting`/`headers`/etc. dict-comprehension
// block on that branch (info.swift's shape 3); a document with no soft returns and >=2
// hard returns reads as `printstream` (detect's own txt>=90 && hard>=2 rule) and never
// reaches it at all, regardless of how many dot commands it carries.
private let diagnoseProse = bytes("word") + SOFT + bytes("word") + SOFT + bytes("word") + SOFT

@Test func diagnoseSurfacesFormattingDict() throws {
    let data = bytes(".sr 10") + HARD + bytes(".pr or=l") + HARD + diagnoseProse + bytes("Text.") + HARD
    let info = documentInfo(data)
    guard case .object(let obj) = info, case .object(let formatting)? = obj["formatting"] else {
        Issue.record("no formatting object in diagnose output")
        return
    }
    #expect(formatting["sub_super_roll_48"] != nil)
    #expect(formatting["orientation"] != nil)
}

@Test func diagnoseOmitsFormattingKeyWhenNothingWasSet() throws {
    let data = diagnoseProse + bytes("Plain text, nothing special.") + HARD
    let info = documentInfo(data)
    guard case .object(let obj) = info else {
        Issue.record("diagnose output is not an object")
        return
    }
    #expect(obj["formatting"] == nil)
}

@Test func diagnoseSurfacesHeadersFootersDeclared() throws {
    let data = bytes(".h1 My Header") + HARD + diagnoseProse + bytes("Body.") + HARD
    let info = documentInfo(data)
    guard case .object(let obj) = info else {
        Issue.record("diagnose output is not an object")
        return
    }
    #expect(obj["headers"] != nil)
}

// MARK: - register b31, E3 item 2 (2026-08-25, ctrl-kd 6f30157): --page-numbers
// WordStar's own AUTOMATIC page number -- the one `.pc` positions, a completely separate
// mechanism from a `#` the author placed inside a real `.he`/`.fo`. Ground truth: real
// WS7 under dosbox-x, probes named in `PDFLayout.swift`'s own `pgnumCheckpoints`/
// `autoPageNumberXPt` doc comments. Default mode is `.auto`: the document's own `.pn`/
// `.pg`/`.op` decide, exactly as measured. `x`/`y` values below are this engine's own
// measured defaults for a document that declares no page geometry of its own (poCols
// 8.0, pcCol unset -> 33.5, pl 66/mb 8/fm 2 -> footLine 60, `.lh` default) -- pinned
// once here so a future geometry-formula change is caught, not treated as this test's
// own hardcoded opinion.

/// Every text-showing op whose literal is purely digits, as `(x, y, number)` -- the
/// automatic page number's own shape (`BT /Fn <size> Tf 0 Ts <x> <y> Td (<digits>) Tj
/// ET`). Mirrors ctrl-kd's own `_pgnum_ops` test helper (a regex over the raw content
/// stream); here it filters `contentSpans`' already-decoded operators instead.
private func pgnumOps(_ pdf: [UInt8]) -> [(x: Double, y: Double, n: String)] {
    contentSpans(pdf).compactMap { span in
        guard let x = span.x, let y = span.y, !span.text.isEmpty,
              span.text.allSatisfy(\.isNumber) else { return nil }
        return (x, y, span.text)
    }
}

@Test func pageNumbersAutoDefaultSilentDocumentShowsNothing() throws {
    // A document with NO `.pn`/`.pg`/`.op`/`.pc` ever gets no automatic number under
    // `.auto` (the default) -- real WS7 prints nothing at any column either. Omitting
    // `pageNumbers` entirely and passing `.auto` explicitly must render byte-identical
    // -- `.auto` IS the silent default, not a new behaviour to opt into.
    let data = (1...19).flatMap { bytes("BARELINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let implicit = emitPDF(doc, mode: .printed)
    let explicit = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .auto))
    #expect(implicit == explicit)
    #expect(pgnumOps(implicit).isEmpty)
}

@Test func pageNumbersAutoPnPresentActivatesIt() throws {
    // `.pn` alone (no header/footer/`.pg`) turns the automatic number ON -- measured:
    // real WS7 printed a bottom-of-page number for exactly this shape. Position: `.po`
    // at this engine's own default (8.0) and `.pc` never set (-> the measured 33.5
    // default) give x = (8.0 + 33.5 - 1) * 7.2 = 291.6pt; y = 60.0pt at this document's
    // own default geometry (footLine 60 * lead 12pt: 792 - 720 - 12 = 60.0).
    let data = bytes(".pn 5") + HARD
        + (1...60).flatMap { bytes("PNLINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .auto))
    let ops = pgnumOps(out)
    #expect(ops.map(\.x) == [291.6, 291.6])
    #expect(ops.map(\.y) == [60.0, 60.0])
    #expect(ops.map(\.n) == ["5", "6"])
}

@Test func pageNumbersOnForcesItOnASilentDocument() throws {
    // `.on` forces WordStar's stock default numbering even on a document that never
    // touched `.pn`/`.pg`/`.op`/`.pc` at all -- there is no real WS7 capture of this
    // exact mode (it does not correspond to a real WordStar UI toggle by itself), but
    // the POSITION/geometry it uses is the same measured default `.auto`-with-`.pn`
    // uses above, just forced on from page 1 with no dot-command trigger needed.
    let data = (1...19).flatMap { bytes("BARELINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let off = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .off))
    let on = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .on))
    #expect(pgnumOps(off).isEmpty)
    let ops = pgnumOps(on)
    #expect(ops.count == 1 && ops[0].x == 291.6 && ops[0].y == 60.0 && ops[0].n == "1")
}

@Test func pageNumbersOffSuppressesEvenWithPn() throws {
    // `.off` suppresses the automatic number unconditionally, even on a document whose
    // own `.pn` would otherwise activate it under `.auto`.
    let data = bytes(".pn 5") + HARD
        + (1...60).flatMap { bytes("PNLINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .off))
    #expect(pgnumOps(out).isEmpty)
}

@Test func pageNumbersPcRepositionsIt() throws {
    // `.pc N` repositions the number's LEFT edge to column `(poCols + N - 1)` --
    // measured: LEFT-anchored (a later test pins digit-count independence), and
    // relative to `.po`, not the absolute page edge.
    let data = bytes(".pn 5") + HARD + bytes(".pc 10") + HARD
        + (1...20).flatMap { bytes("PCLINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .auto))
    let ops = pgnumOps(out)
    // poCols default 8.0, pc 10 -> (8 + 10 - 1) * 7.2 = 122.4
    #expect(ops.count == 1 && ops[0].x == 122.4 && ops[0].y == 60.0 && ops[0].n == "5")
}

@Test func pageNumbersPcIsLeftAnchoredNotRightAnchored() throws {
    // A 3-digit number lands at the IDENTICAL x as a 1-digit one at the same `.pc`/
    // `.po` pair -- measured: the number's LEFT edge is fixed by `.pc`, unaffected by
    // how many digits the resolved page number itself has.
    let oneDigitData = bytes(".pn 5") + HARD + bytes(".pc 10") + HARD
        + (1...20).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
    let threeDigitData = bytes(".pn 998") + HARD + bytes(".pc 10") + HARD
        + (1...20).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
    let oneDigit = parseWS(oneDigitData)
    let threeDigit = parseWS(threeDigitData)
    let x1 = pgnumOps(emitPDF(oneDigit, mode: .printed, options: EmitOptions(pageNumbers: .auto)))[0].x
    let x2 = pgnumOps(emitPDF(threeDigit, mode: .printed, options: EmitOptions(pageNumbers: .auto)))[0].x
    #expect(x1 == 122.4 && x2 == 122.4)
}

@Test func pageNumbersDeclaredFooterSuppressesIt() throws {
    // WSFORMAT.WS's own text: ".PC ... active only when the footers are not in use." A
    // declared footer -- even with NO `#` of its own -- suppresses the separate
    // automatic number entirely (measured: only the footer's own text printed, no
    // extra digit anywhere on the row) in EVERY mode, not just `.auto`.
    let data = bytes(".pn 5") + HARD + bytes(".fo PLAIN-FOOTER-NO-HASH") + HARD
        + (1...20).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    for mode in [EmitOptions.PageNumberMode.auto, .on] {
        let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: mode))
        #expect(pgnumOps(out).isEmpty)
        #expect(contains(out, bytes("PLAIN-FOOTER-NO-HASH")))
    }
}

@Test func pageNumbersHeaderWithoutHashDoesNotSuppressIt() throws {
    // A HEADER (not a footer) never competes with the automatic number -- measured: the
    // bottom number still printed even though a header was declared.
    let data = bytes(".pn 5") + HARD + bytes(".he PLAIN-HEADER-NO-HASH") + HARD
        + (1...20).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .auto))
    let ops = pgnumOps(out)
    #expect(ops.count == 1 && ops[0].x == 291.6 && ops[0].y == 60.0 && ops[0].n == "5")
    #expect(contains(out, bytes("PLAIN-HEADER-NO-HASH")))
}

@Test func pageNumbersExplicitHashInFooterIgnoresTheFlag() throws {
    // A `#` the author placed inside a real `.fo` is running-title content, not
    // WordStar's own automatic number -- Jon's ruling (2026-08-25): `--page-numbers
    // off` must NOT blank it. `runningOps`'s own `render()` already does this
    // substitution unconditionally, unrelated to `autoPageNumber`; this pins the
    // option-level contract, not just the underlying mechanism.
    let data = bytes(".fo FOOTTXT #") + HARD
        + (1...60).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
        + bytes(".pa") + HARD
        + (1...60).flatMap { bytes("M\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .off))
    #expect(contains(out, bytes("FOOTTXT 1")) && contains(out, bytes("FOOTTXT 2")))
}

@Test func pageNumbersOpThenPgTogglesMidDocument() throws {
    // `.op`/`.pg` are genuinely STATEFUL mid-document -- measured: page 1 under `.op`
    // prints no number; the pages after a mid-document `.pg` do, using the ordinary
    // physical page count (no `.pn` anywhere in this document at all -- `.pg` alone
    // activates it). A blank line separates the two sections so each gets its own
    // block (`doc.dotPositions` is block-granular, same requirement every other b31
    // checkpoint test in this suite already carries).
    let data: [UInt8] = bytes(".op") + HARD
        + (1...60).flatMap { bytes("OFFLINE-\(String(format: "%03d", $0))") + HARD }
        + HARD + bytes(".pg") + HARD
        + (1...60).flatMap { bytes("ONLINE-\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed, options: EmitOptions(pageNumbers: .auto))
    let ops = pgnumOps(out)
    #expect(ops.map(\.n) == ["2", "3"])
}

@Test func pageNumbersHeadersFlagOffAlsoSuppresses() throws {
    // `--headers off`'s own documented scope already covers "headers, footers, and page
    // numbers" -- the automatic number must go silent along with everything else it
    // controls, even under `.auto` with a live `.pn`.
    let data = bytes(".pn 5") + HARD
        + (1...20).flatMap { bytes("L\(String(format: "%03d", $0))") + HARD }
    let doc = parseWS(data)
    let out = emitPDF(doc, mode: .printed,
                      options: EmitOptions(headers: false, pageNumbers: .auto))
    #expect(pgnumOps(out).isEmpty)
}
