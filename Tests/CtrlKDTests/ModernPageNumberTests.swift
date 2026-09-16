/// M15 (Jon's ruling 2026-09-15): MODERN SHOWS WORDSTAR'S AUTOMATIC PAGE NUMBER.
///
/// Jon: "I think it should in Modern View. Maybe I said something different previously.
/// But I'm now finding that it looks weird that it suddenly goes away. Now on Export
/// that's different. There's a flag if people want Page Number or not, that can be
/// selected."
///
/// So the Modern VIEW shows the automatic number wherever Printed does, and Modern
/// EXPORTS obey `--page-numbers` auto/on/off exactly as Printed does — the same sentence
/// twice, because the app's Modern view IS this engine's `auto` Modern PDF. Modern RTF
/// has carried the number since the running-head round (a `\footer` group of `\chpgn`);
/// Modern PDF was the one paged surface still dropping it, so switching the app from
/// Printed to Modern made a document's numbering vanish.
///
/// WHETHER IT SHOWS IS THE DOCUMENT'S ANSWER, and the three silencers are measured, not
/// assumed — research/2026-09-15_ws7-missing-auto-page-number.md, 308 real WS7 captures,
/// zero counter-examples:
///
///   1. `.op`, with `.pn`/`.pg` turning it back on from where THEY sit.
///   2. ANY footer command, with text, bare, or only invisible characters — the footer
///      REPLACES the number.
///   3. `.mb 0` — no footer row on the sheet, so nowhere to put one.
///
/// WHERE IT SHOWS IS MODERN'S ANSWER ("placed the Modern way"): the row a Modern footer
/// line 1 rides, centred in Modern's own measure, in the face and size Modern's running
/// feet already use. Never Printed's `.pc` column, and never Printed's `pl - mb + fm` row.
///
/// Port of ctrl-kd's `tests/test_modern_page_number.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private let CR = "\r\n"

/// The row Modern's own footer line 1 rides.
private let modernFootY = 44.0

private func pageNumberDocument(_ body: String, dots: String = "") -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var data: [UInt8] = [0x1D]
    data += le
    data += [0x00, 0x70]
    data += [UInt8](repeating: 0, count: 15)
    data += le
    data += [0x1D]
    data += [UInt8](dots.utf8)
    data += [UInt8](body.utf8)
    return parseWS(data)
}

private let numberParagraph =
    "The quick brown fox jumps over the lazy dog and keeps running "
    + "until the line has to wrap somewhere sensible." + CR

/// A body long enough to fill several Modern pages.
private func longBody() -> String {
    var out = ""
    for _ in 0..<60 { out += numberParagraph }
    return out
}

/// A document declaring nothing but the given dot commands.
private func numbered(_ dots: String) -> Document {
    pageNumberDocument(longBody(), dots: dots)
}

private func contentStreams(_ pdf: [UInt8]) -> [String] {
    let text = String(decoding: pdf, as: UTF8.self)
    return text.components(separatedBy: ">>\nstream\n").dropFirst().map {
        $0.components(separatedBy: "\nendstream")[0]
    }
}

/// Every drawn (x, text) on Modern's own footer row.
private func footRow(_ stream: String) -> [(x: Double, text: String)] {
    var out: [(x: Double, text: String)] = []
    var search = stream.startIndex..<stream.endIndex
    let pattern = #"Ts ([\d.]+) ([\d.]+) Td \(([^)]*)\) Tj"#
    while let range = stream.range(of: pattern, options: .regularExpression,
                                   range: search) {
        let body = stream[range]
        let fields = body.components(separatedBy: " ")
        if fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]),
           abs(y - modernFootY) < 0.05 {
            let open = body.range(of: "(")!
            let close = body.range(of: ") Tj")!
            out.append((x: x, text: String(body[open.upperBound..<close.lowerBound])))
        }
        search = range.upperBound..<stream.endIndex
    }
    return out
}

/// The automatic page number drawn on each Modern page, or nil — a LONE digits-only op
/// on the footer row, centred in Modern's measure.
private func numbers(_ doc: Document, pageNumbers: EmitOptions.PageNumberMode = .auto,
                     headers: Bool = true)
    -> [String?] {
    var options = EmitOptions()
    options.pageNumbers = pageNumbers
    options.headers = headers
    let (margl, _, _, width) = modernGeometry(doc)
    let centre = margl + width / 2.0
    return contentStreams(emitPDF(doc, mode: .modern, options: options)).map { stream in
        let row = footRow(stream)
        guard row.count == 1, !row[0].text.isEmpty,
              row[0].text.allSatisfy({ $0.isNumber }),
              abs(row[0].x - centre) < 10.0 else { return nil }
        return row[0].text
    }
}

// MARK: - the stock behaviour

@Test func aPlainDocumentNumbersEveryModernPage() {
    let nums = numbers(pageNumberDocument(longBody()))
    #expect(nums.count > 1)
    // staged rather than one expression: the `Array<String?> == Array<String>` form
    // crossed the type-checker's own budget (planning #253).
    var wanted: [String?] = []
    for i in 1...nums.count { wanted.append(String(i)) }
    #expect(nums == wanted)
}

@Test func theNumberSitsOnModernsOwnFooterRowCentred() throws {
    let doc = pageNumberDocument(longBody())
    let (margl, _, _, width) = modernGeometry(doc)
    let row = footRow(try #require(contentStreams(emitPDF(doc, mode: .modern)).first))
    #expect(row.count == 1)
    #expect(row.first?.text == "1")
    let centre = margl + width / 2.0
    let drawn = row.first?.x ?? 0
    #expect(abs(drawn - centre) < 10.0)
}

@Test func theNumberIsNotAtPrintedsOwnColumn() throws {
    // Printed anchors it at `.po + .pc` columns (`autoPageNumberXPt`); Modern centres it
    // in its own measure. The two only coincide by accident, and this document is not
    // that accident.
    let doc = numbered(".po 20" + CR)
    let row = footRow(try #require(contentStreams(emitPDF(doc, mode: .modern)).first))
    #expect(row.count == 1)
    let printedX = autoPageNumberXPt(doc)
    let modernX = row.first?.x ?? 0
    #expect(abs(modernX - printedX) > 10.0)
}

@Test func theNumberStartsWherePnSays() {
    let nums = numbers(numbered(".pn 7" + CR))
    #expect(nums.first ?? nil == "7")
    #expect(nums.count > 1 && nums[1] == "8")
}

// MARK: - silencer 1: `.op`/`.pn`

@Test func opSilencesTheModernNumber() {
    #expect(numbers(numbered(".op" + CR)).allSatisfy { $0 == nil })
}

@Test func pnAfterOpTurnsItBackOn() {
    var body = "Opening."
    body += CR
    body += ".pn 3"
    body += CR
    body += longBody()
    let doc = pageNumberDocument(body, dots: ".op" + CR)
    #expect(numbers(doc).contains { $0 != nil })
}

// MARK: - silencer 2: the footer

@Test func aBareFoSilencesTheModernNumber() {
    // "That holds whether the footer has text, is bare, or contains only invisible
    // characters" — research 2026-09-15, rule 2.
    #expect(numbers(numbered(".fo" + CR)).allSatisfy { $0 == nil })
}

@Test func aFooterWithTextSilencesTheModernNumber() {
    #expect(numbers(numbered(".fo Chapter one" + CR)).allSatisfy { $0 == nil })
}

@Test func aFooterTypedAfterTheLastBlockStillSilencesIt() {
    // `sawyer/REF/BUGS.WS`'s own shape: a `.fo` anchored past the document's last block.
    // It never reaches the Modern FLOW at all (`modernFlow` walks `doc.blocks`), so the
    // page's own `curF` snapshot cannot see it — the decision reads the event's anchor
    // directly for exactly this case.
    var body = "Body text."
    body += CR
    body += ".fo"
    body += CR
    let doc = pageNumberDocument(body)
    #expect(!doc.hfEvents.isEmpty)
    #expect(numbers(doc).allSatisfy { $0 == nil })
}

// MARK: - silencer 3: `.mb 0`

@Test func mbZeroSilencesTheModernNumber() {
    // "No bottom margin — there is no footer line on the sheet at all, so there is
    // nowhere to put a number" (research, rule 3). In the archive that is the
    // label/Rolodex/mail-merge stock.
    #expect(numbers(numbered(".mb 0" + CR)).allSatisfy { $0 == nil })
}

@Test func theRowTestIsTheOnePrintedUses() {
    // One definition, two readers: Printed draws at this y, Modern only asks whether it
    // is nil.
    #expect(autoPagenoRowY(pageHeight: 792, pl: 66, mb: 8, fm: 2, size: 12) == 60.0)
    #expect(autoPagenoRowY(pageHeight: 72, pl: 6, mb: 0, fm: 0, size: 12) == nil)
}

@Test func theRowStepsByAPageLineNotTheDocumentsLH() {
    // Planning #274: `.pl`/`.mb`/`.fm` count PAGE lines — WordStar's fixed 6-LPI grid —
    // and the row used to be multiplied by the document's own `.lh` instead. Identical
    // whenever `.lh` is the default 12pt, which is why it went unseen; a document that
    // sets `.lh` higher had the row pushed down by (lh - 12) x ~60 lines and lost its
    // number. `sawyer/REF/SUB-SUPE.TST` (`.lh` 24pt, `.pl 66 .mb 8 .fm 2`) is the case:
    // real WS7 prints its number 732pt from the top of the sheet, the row this
    // arithmetic gives at 6 LPI and nowhere near the 1452pt a 24pt step would.
    let want: Double = 792.0 - 60.0 * 12.0 - 12.0
    let got = autoPagenoRowY(pageHeight: 792, pl: 66, mb: 8, fm: 2, size: 12)
    #expect(got == want)
}

@Test func theRowKeepsFractionalPageLines() {
    // `.mb 1.8`/`.fm 1.14` are ordinary corpus values and truncating them to integers
    // moved the row by most of an inch.
    let want: Double = 792.0 - 66.2 * 12.0 - 12.0
    let got = autoPagenoRowY(pageHeight: 792, pl: 66.0, mb: 1.8, fm: 2.0, size: 12) ?? 0
    #expect(abs(got - want) < 1e-9)
}

@Test func theRowIsReturnedEvenWhenItFallsPastThePaper() {
    // Real WS7 does not clamp: with `.mb 1.8 .fm 2` on a 66-line page it commands the
    // number 806.4pt from the top of a 792pt sheet — 14.4pt past the bottom edge — and
    // the printer clips it. The engine does the same and lets the page clip it. A
    // blanket "must be on the paper" guard used to do the dropping, and it was standing
    // in for the `.mb 0` rule below.
    let y = autoPagenoRowY(pageHeight: 792, pl: 66.0, mb: 1.8, fm: 2.0, size: 12)
    #expect(y != nil)
    #expect((y ?? 0) < 0)
}

@Test func noBottomMarginMeansNoRowAtAll() {
    // Research 2026-09-15 rule 3, 24 captures and no counter-example: no bottom margin
    // means there is no footer line on the sheet, so there is nowhere to put a number.
    #expect(autoPagenoRowY(pageHeight: 72, pl: 6, mb: 0, fm: 0, size: 12) == nil)
    #expect(autoPagenoRowY(pageHeight: 792, pl: 0, mb: 0, fm: 2, size: 12) == nil)
}

@Test func aBodilessDocumentIsNumberedFromItsOpeningState() {
    // Galley and manuscript TEMPLATES: one page each, nothing but dot commands and a
    // pair of `.h1o`/`.h1e` running heads, not one body line. A page with no block of
    // its own used to answer a hard `false`, which is not a fallback but a different
    // rule — the number vanished even though nothing in the document ever asked for
    // `.op`, while real WS7 stamps one.
    #expect(pgnumForBodilessPage([PgnumCheckpoint(blockIndex: 0, lineIndex: 0, on: true)],
                                 fallbackBi: nil, bodilessDoc: true))
    #expect(!pgnumForBodilessPage([PgnumCheckpoint(blockIndex: 0, lineIndex: 0, on: false)],
                                  fallbackBi: nil, bodilessDoc: true))
    // The other half, and the reason the test is a WHOLE-DOCUMENT one: a page that
    // merely came out empty inside a document that does have blocks keeps the old
    // answer — reading checkpoint 0 there would ignore every command since.
    #expect(!pgnumForBodilessPage([PgnumCheckpoint(blockIndex: 0, lineIndex: 0, on: true)],
                                  fallbackBi: nil, bodilessDoc: false))
    // Planning #228 is untouched: `explicitBreakBI` wins wherever it exists.
    let cps = [PgnumCheckpoint(blockIndex: 0, lineIndex: 0, on: true),
               PgnumCheckpoint(blockIndex: 5, lineIndex: 0, on: false)]
    #expect(!pgnumForBodilessPage(cps, fallbackBi: 5, bodilessDoc: false))
}

// MARK: - the flag

@Test func pageNumbersOffSilencesANumberingDocument() {
    #expect(numbers(pageNumberDocument(longBody()), pageNumbers: .off)
        .allSatisfy { $0 == nil })
}

@Test func pageNumbersOnForcesItOverOp() {
    #expect(numbers(numbered(".op" + CR), pageNumbers: .on).first ?? nil == "1")
}

@Test func pageNumbersOnCannotConjureARowThatIsNotThere() {
    // `on` overrides the DOCUMENT'S CHOICE (`.op`). It does not override what WordStar
    // itself does: a sheet with no footer row has nowhere to put a number, and a footer
    // already occupies the row.
    #expect(numbers(numbered(".mb 0" + CR), pageNumbers: .on).allSatisfy { $0 == nil })
    #expect(numbers(numbered(".fo" + CR), pageNumbers: .on).allSatisfy { $0 == nil })
}

// MARK: - Modern PDF and Modern RTF agree again

/// True when the RTF carries WordStar's AUTOMATIC number — a `\footer` group whose whole
/// content is `\chpgn`. A `#` the author typed into a real head or foot also renders as
/// `\chpgn`, so a bare substring test would answer a different question.
private func rtfAutoFooter(_ rtf: String) -> Bool {
    rtf.range(of: #"\\footer [^{}]*\{\\chpgn \}\\par\}"#,
              options: .regularExpression) != nil
}

@Test func modernRTFAndModernPDFAgreeAboutNumbering() {
    // The 2026-08-05 ruling: Modern PDF is the printed form of the Modern RTF. The RTF
    // said `\chpgn` while the PDF drew nothing — that is the defect M15 closes, stated
    // as an equality.
    for (dots, isNumbered) in [("", true), (".op" + CR, false), (".fo" + CR, false)] {
        let doc = pageNumberDocument(longBody(), dots: dots)
        #expect(rtfAutoFooter(emitRTF(doc, mode: .modern)) == isNumbered, "\(dots)")
        #expect(((numbers(doc).first ?? nil) != nil) == isNumbered, "\(dots)")
    }
}

@Test func aBareFoSilencesTheRTFNumberInBothModes() {
    // M15 follow-up, and the same rule the PDF's own 2026-09-12 triage fixed: "any footer
    // command — with text, bare, or carrying only invisible characters" silences the
    // automatic number. `hfSlots` drops an event with no text at all, so a document whose
    // ONLY footer is a bare `.fo` used to read as "no footer in use" and RTF printed a
    // number both PDFs did not. Five archive documents are that shape and their
    // `rtf.printed` and `rtf.modern` move with this.
    let bare = numbered(".fo" + CR)
    for mode in [EmitMode.printed, .modern] {
        #expect(!rtfAutoFooter(emitRTF(bare, mode: mode)), "\(mode)")
    }
    let plain = pageNumberDocument(longBody())
    for mode in [EmitMode.printed, .modern] {
        #expect(rtfAutoFooter(emitRTF(plain, mode: mode)), "\(mode)")
    }
}

@Test func anInvisibleOnlyFooterSilencesItToo() {
    // LJ6DTP.WS's own `.f1` is two print-control bytes and renders nothing visible; it
    // was already read as "in use" because it carries text. Pinned so the fix above
    // cannot be narrowed back to it.
    let doc = numbered(".fo \u{0f}\u{0f}" + CR)
    #expect(!rtfAutoFooter(emitRTF(doc, mode: .modern)))
    #expect((numbers(doc).first ?? nil) == nil)
}

// MARK: - `--headers off` reaches Modern
//
// `--headers` governs the RUNNING HEADS AND FEET on every paged surface (register, "Flag
// UI + defaults"; ruled again 2026-09-14, planning #264 R7). Printed PDF and both RTF
// modes have honoured it since ctrl-kd `722b877`/sr `4f673db`; Modern PDF was the one
// paged surface still drawing its heads under `off`, so `sr -t pdf --mode modern
// --headers off` on `REF/BOOKLET.WS` kept all three of that document's running heads. M5
// ("Modern keeps running heads", ruled 2026-08-06) is the DEFAULT this flag turns off,
// never a refusal of the flag.
//
// Port of ctrl-kd's `test_modern_page_number.py` tail, same fixtures.

/// Sequential `+=` rather than a chained `+` expression: planning #253, the shape the
/// macOS type-checker abandons.
private let headAndFoot: String = {
    var out = ".h1 Running Head"
    out += CR
    out += ".f1 Running Foot"
    out += CR
    return out
}()

/// Every string Modern's first page draws, in the order it draws it.
private func drawnStrings(_ doc: Document, headers: Bool) -> [String] {
    var options = EmitOptions()
    options.headers = headers
    let streams = contentStreams(emitPDF(doc, mode: .modern, options: options))
    guard let stream = streams.first else { return [] }
    var out: [String] = []
    var search = stream.startIndex..<stream.endIndex
    let pattern = #"Td \(([^)]*)\) Tj"#
    while let range = stream.range(of: pattern, options: .regularExpression,
                                   range: search) {
        let body = stream[range]
        let open = body.range(of: "(")!
        let close = body.range(of: ") Tj")!
        out.append(String(body[open.upperBound..<close.lowerBound]))
        search = range.upperBound..<stream.endIndex
    }
    return out
}

@Test func headersOffDropsModernsRunningHeadsAndFeet() {
    let doc = numbered(headAndFoot)
    let on = drawnStrings(doc, headers: true)
    #expect(on.contains("Head"))
    #expect(on.contains("Foot"))
    let off = drawnStrings(doc, headers: false)
    #expect(!off.contains("Head"))
    #expect(!off.contains("Foot"))
}

@Test func headersOffNeverTouchesModernsBody() {
    // The flag reaches the margin zones and nothing else.
    let doc = numbered(headAndFoot)
    let furniture = ["Running", "Head", "Foot"]
    let bodyOn = drawnStrings(doc, headers: true).filter { !furniture.contains($0) }
    let bodyOff = drawnStrings(doc, headers: false).filter { $0 != "Running" }
    #expect(bodyOff == bodyOn)
    #expect(Array(bodyOn.prefix(3)) == ["The", "quick", "brown"])
}

@Test func headersOffKeepsModernsAutomaticNumber() {
    // Two flags, two subjects: `--page-numbers` governs WordStar's own automatic number
    // ALONE, so it survives `--headers off` exactly as it does in Printed.
    let doc = numbered(".h1 Running Head" + CR)
    for headers in [true, false] {
        #expect((numbers(doc, headers: headers).first ?? nil) == "1", "\(headers)")
        let off = numbers(doc, pageNumbers: .off, headers: headers)
        #expect((off.first ?? nil) == nil, "\(headers)")
    }
    #expect(!drawnStrings(doc, headers: false).contains("Head"))
}

@Test func aDeclaredFooterStillPreEmptsModernsNumberWithHeadersOff() {
    // "In use" is a property of the DOCUMENT, not of the flag — the same hazard
    // `4f673db` pinned on the Printed side. Suppressing a footer's DRAWING must not
    // conjure a number the document never had.
    for dots in [".fo" + CR, ".f1 Running Foot" + CR] {
        let doc = numbered(dots)
        for headers in [true, false] {
            let nums = numbers(doc, headers: headers)
            #expect((nums.first ?? nil) == nil, "\(dots) \(headers)")
        }
    }
}

@Test func theModernFooterRowKeepsTheNumberWhenItsHeadIsSuppressed() throws {
    // The number rides Modern's own footer row. A document with a head and no footer
    // declared keeps that row's number under `--headers off`, centred where it was.
    let doc = numbered(".h1 Running Head" + CR)
    let (margl, _, _, width) = modernGeometry(doc)
    var options = EmitOptions()
    options.headers = false
    let streams = contentStreams(emitPDF(doc, mode: .modern, options: options))
    let row = footRow(try #require(streams.first))
    #expect(row.count == 1)
    #expect(row.first?.text == "1")
    let centre = margl + width / 2.0
    let drawn = row.first?.x ?? 0
    #expect(abs(drawn - centre) < 10.0)
}

@Test func modernPageFurnitureReportsNoHeadsOrFeetUnderHeadersOff() {
    // `modernPageFurniture` records from the SAME ops this loop builds, so the accessor
    // the Mac and iOS apps read must go quiet with the drawing — and must still report
    // the automatic number, which `--page-numbers` alone governs.
    var dots = ".h1 Running Head"
    dots += CR
    dots += ".f2 Running Foot"
    dots += CR
    let doc = numbered(dots)
    var on = EmitOptions()
    on.headers = true
    let drawnFurniture = modernPageFurniture(doc, options: on)
    #expect(drawnFurniture.contains { !$0.headers.isEmpty })
    #expect(drawnFurniture.contains { !$0.footers.isEmpty })
    var off = EmitOptions()
    off.headers = false
    let quiet = modernPageFurniture(doc, options: off)
    #expect(quiet.count == drawnFurniture.count)
    #expect(quiet.allSatisfy { $0.headers.isEmpty })
    #expect(quiet.allSatisfy { $0.footers.isEmpty })
    // `.f2` is a footer command, so this document's automatic number is off in BOTH —
    // the document's own answer, unchanged by the flag.
    #expect(quiet.allSatisfy { $0.autoPageNumber == nil })
    var numbersOff = EmitOptions()
    numbersOff.headers = false
    let bare = numbered(".h1 Running Head" + CR)
    let kept = modernPageFurniture(bare, options: numbersOff)
    #expect(kept.allSatisfy { $0.headers.isEmpty })
    #expect(kept.allSatisfy { $0.autoPageNumber != nil })
}
