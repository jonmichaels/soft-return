import Foundation
import Testing
@testable import CtrlKD

/// planning #264 items 2, 3 and 4 — the three RTF paged-surface defects the review packet
/// named, all of them facts the parser already carried and only the PDF ever read.
///
/// ITEM 2 (packet row A10) — NO TRAILING BLANK PAGE. Both RTF modes wrote `\page` for the
/// document's own last block and then closed the file, so every `.pa`-ending document
/// opened a permanently blank final page. Real WS7 opens the page after a forced break
/// only when at least one more real line of content was typed after it before EOF
/// (planning #228, eleven harness probes). RTF reads the SAME already-parsed fact the PDF
/// reads — `Document.paEofBlankAfter` — rather than carrying a second rule.
///
/// ITEM 3 (packet rows A1+A2) — PAGE NUMBERS. A document that declares no header or footer
/// still gets a centred page number at the foot of every PDF page, stock WordStar 7's own
/// factory default. The RTF had none, in either mode, and `--page-numbers` was accepted by
/// the command line and swallowed by the emitter. The number is a `\footer` group carrying
/// `\chpgn`; `.pn`'s start value is `\pgnstart`.
///
/// ITEM 4 (packet rows A3-A6) — FACING PAGES. The corpus's galley template sets one head on
/// right-hand pages and another on left-hand ones; the RTF printed the first on every page
/// and the second on none. `hfEventsParity` (planning #250) drives `\facingp` plus
/// `\headerr`/`\headerl`; `headerAlign` (planning #255) drives `\qr`/`\qc`; `.mt`/`.hm`/
/// `.pl`/`.mb`/`.fm` drive `\headery`/`\footery` by the PDF's own formula; `.poe`/`.poo`
/// drive `\margmirror`.
///
/// A5 and A6 are PRINTED ONLY: Modern's page is its own fixed Letter and Modern carries
/// none of our vertical space (ruling 2026-08-17, "never Modern"; packet row D9).
///
/// Port of ctrl-kd's `tests/test_rtf_trailing_pa_page.py`,
/// `tests/test_rtf_page_numbers.py` and `tests/test_rtf_facing_pages.py`.
@Suite struct RTFPagedSurfaceTests {
    static let footerNum = #"{\footer \pard\plain \qc\f0\fs22 {\chpgn }\par}"#

    /// A one-paragraph document, with `dots` recorded the way the parser records them for
    /// `pgnumCheckpoints`/`poeOrPooCheckpoints` to read.
    static func doc(dots: [String] = [], trailingBreak: Bool = false,
                    paEofBlankAfter: Bool = false,
                    footers: [Int: String] = [:],
                    headEvents: [(HFKind, Int, String, HFParity?)] = []) -> Document {
        var d = Document()
        d.blocks = [Block(kind: .para, lines: [Line(spans: [Span(text: "body")])])]
        if trailingBreak { d.blocks.append(Block(kind: .pagebreak)) }
        d.paEofBlankAfter = paEofBlankAfter
        d.dotPositions = dots.map { DotPosition(blockIndex: 0, lineIndex: 0, text: $0) }
        for (line, text) in footers {
            d.footers[line] = text
            d.hfEvents.append(HFEvent(kind: .footer, line: line, text: text, blockAnchor: 0))
            d.hfEventsParity.append(nil)
        }
        for (kind, line, text, parity) in headEvents {
            d.hfEvents.append(HFEvent(kind: kind, line: line, text: text, blockAnchor: 0))
            d.hfEventsParity.append(parity)
            if kind == .header { d.headers[line] = text } else { d.footers[line] = text }
        }
        return d
    }

    // MARK: item 2 — the trailing `.pa`

    @Test(arguments: [EmitMode.printed, .modern])
    func aBareTrailingPaOpensNoRTFPage(mode: EmitMode) {
        let out = emitRTF(Self.doc(trailingBreak: true, paEofBlankAfter: false), mode: mode)
        #expect(!out.contains(#"\page"#))
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func aTrailingPaWithASavedBlankParagraphStillOpensOne(mode: EmitMode) {
        let out = emitRTF(Self.doc(trailingBreak: true, paEofBlankAfter: true), mode: mode)
        #expect(out.contains(#"\page"#))
    }

    @Test func aPagebreakThatIsNotTheLastBlockIsUntouched() {
        var d = Self.doc()
        d.blocks.append(Block(kind: .pagebreak))
        d.blocks.append(Block(kind: .para, lines: [Line(spans: [Span(text: "after")])]))
        let out = emitRTF(d, mode: .printed)
        #expect(out.components(separatedBy: #"\page"#).count - 1 == 1)
    }

    // MARK: item 3 — page numbers

    @Test(arguments: [EmitMode.printed, .modern])
    func aSilentDocumentGetsACentredPageNumber(mode: EmitMode) {
        // Stock WordStar 7 numbers a document that says nothing at all.
        #expect(emitRTF(Self.doc(), mode: mode).contains(Self.footerNum))
    }

    @Test func opTurnsTheNumberOffAndPgTurnsItBackOn() {
        #expect(!emitRTF(Self.doc(dots: [".op"])).contains(Self.footerNum))
        #expect(emitRTF(Self.doc(dots: [".op", ".pg"])).contains(Self.footerNum))
    }

    @Test func theFlagReachesTheEmitterAtAll() {
        // The named defect: `--page-numbers` used to be swallowed by the emitter.
        var off = EmitOptions()
        off.pageNumbers = .off
        #expect(!emitRTF(Self.doc(), options: off).contains(Self.footerNum))
        var on = EmitOptions()
        on.pageNumbers = .on
        #expect(emitRTF(Self.doc(dots: [".op"]), options: on).contains(Self.footerNum))
    }

    // MARK: the two flags (planning #264 R7, ruled 2026-09-14)
    //
    // Jon, ruling on the review round: "Page numbers and headers can be different. A
    // header or footer that contains a page number is controlled by header flag but a
    // page number on its own is controlled by the page number flag. RTF should work the
    // same way."
    //
    // So `--headers` reaches the running heads and feet — a `#` the author typed inside
    // one goes with its head, because it IS that head's text — and `--page-numbers`
    // reaches WordStar's own automatic number and nothing else. The first RTF batch had
    // `--headers off` swallow the automatic number too; that is what these rows revert.

    @Test(arguments: [EmitMode.printed, .modern],
          [(true, EmitOptions.PageNumberMode.on, true), (true, .off, false),
           (false, .on, true), (false, .off, false)])
    func theFourFlagCombinations(mode: EmitMode,
                                 combo: (headers: Bool, pageNumbers: EmitOptions.PageNumberMode,
                                         expected: Bool)) {
        // The automatic number answers to `--page-numbers` ALONE, in both RTF modes,
        // whichever way `--headers` is set.
        var options = EmitOptions()
        options.headers = combo.headers
        options.pageNumbers = combo.pageNumbers
        let out = emitRTF(Self.doc(dots: [".op"]), mode: mode, options: options)
        #expect(out.contains(Self.footerNum) == combo.expected)
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func autoIsTheDocumentsOwnStateUnderEitherHeadersFlag(mode: EmitMode) {
        // `auto` reads `.pn`/`.pg`/`.op`, and `--headers` does not enter into it — the
        // same answer with heads drawn and with heads suppressed.
        for headers in [true, false] {
            var options = EmitOptions()
            options.headers = headers
            #expect(emitRTF(Self.doc(), mode: mode, options: options)
                .contains(Self.footerNum))
            #expect(!emitRTF(Self.doc(dots: [".op"]), mode: mode, options: options)
                .contains(Self.footerNum))
        }
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func aHashInsideAHeadGoesWithItsHead(mode: EmitMode) {
        // The other half of the ruling: a `#` the author typed into a real `.fo` is that
        // footer's own text, so `--headers off` takes it away — and it was never the
        // automatic number, so `--page-numbers` does not reach it.
        let d = Self.doc(footers: [1: "Page #"])
        var drawn = EmitOptions()
        drawn.headers = true
        drawn.pageNumbers = .off
        let on = emitRTF(d, mode: mode, options: drawn)
        #expect(on.contains(#"{\chpgn }"#))
        #expect(on.contains("Page"))
        var hidden = EmitOptions()
        hidden.headers = false
        hidden.pageNumbers = .on
        let off = emitRTF(d, mode: mode, options: hidden)
        #expect(!off.contains(#"\chpgn"#))
        #expect(!off.contains("Page"))
    }

    @Test func aDeclaredFooterPreEmptsTheAutomaticNumber() {
        let out = emitRTF(Self.doc(footers: [1: "Chapter One"]))
        #expect(!out.contains(Self.footerNum))
        #expect(out.contains(#"{\footer "#))              // the real footer is there
    }

    @Test func aFooterThatRendersNothingStillPreEmptsIt() {
        // The corpus's LJ6DTP document declares an `.f1` of two 0x0F bytes: declared,
        // invisible, and enough to keep WordStar's automatic number off.
        let out = emitRTF(Self.doc(footers: [1: "\u{0F}\u{0F}"]))
        #expect(!out.contains(Self.footerNum))
        #expect(!out.contains(#"{\footer "#))             // nothing visible to draw
    }

    @Test func autoPageNumberResolvesAtTheDocumentsFirstBlock() {
        #expect(rtfAutoPageNumber(Self.doc(), .auto))
        #expect(!rtfAutoPageNumber(Self.doc(dots: [".op"]), .auto))
        #expect(rtfAutoPageNumber(Self.doc(dots: [".op"]), .on))
        #expect(!rtfAutoPageNumber(Self.doc(), .off))
    }

    // MARK: item 4 — facing pages, alignment, gaps, mirror

    @Test(arguments: [EmitMode.printed, .modern])
    func parityHeadsBecomeHeaderlAndHeaderr(mode: EmitMode) {
        let d = Self.doc(headEvents: [(.header, 1, "TITLE", .odd),
                                      (.header, 1, "AUTHOR", .even)])
        let out = emitRTF(d, mode: mode)
        #expect(out.contains(#"\facingp"#))
        #expect(out.contains(#"{\headerr "#) && out.contains("TITLE"))
        #expect(out.contains(#"{\headerl "#) && out.contains("AUTHOR"))
    }

    @Test func oddIsTheRightHandPage() {
        // WordStar's odd page is the right-hand one, which is `\headerr`.
        let d = Self.doc(headEvents: [(.header, 1, "ODD", .odd), (.header, 1, "EVEN", .even)])
        let out = emitRTF(d)
        let right = out.range(of: #"{\headerr "#)!
        let left = out.range(of: #"{\headerl "#)!
        #expect(out[right.lowerBound..<left.lowerBound].contains("ODD"))
        #expect(out[left.lowerBound...].contains("EVEN"))
    }

    @Test func aHeadDeclaredForOneParityOnlyPrintsOnThatSide() {
        let out = emitRTF(Self.doc(headEvents: [(.header, 1, "ODD ONLY", .odd)]))
        #expect(out.contains(#"{\headerr "#))
        #expect(!out.contains(#"{\headerl "#))
    }

    @Test func aPlainHeadAppliesToBothSides() {
        // A document with no parity variant keeps the single `\header` group it always
        // had — and no `\facingp`.
        let out = emitRTF(Self.doc(headEvents: [(.header, 1, "BOTH", nil)]))
        #expect(out.contains(#"{\header "#))
        #expect(!out.contains(#"\facingp"#))
        #expect(!out.contains(#"\headerl"#))
    }

    @Test func footersTakeTheSameTreatment() {
        let d = Self.doc(headEvents: [(.footer, 1, "ODD FOOT", .odd),
                                      (.footer, 1, "EVEN FOOT", .even)])
        let out = emitRTF(d)
        #expect(out.contains(#"{\footerr "#) && out.contains(#"{\footerl "#))
    }

    @Test func aParityThatNamesNoAlignmentDoesNotInheritTheOthers() {
        // The corpus's booklet templates declare flush right on the ODD head's own style
        // and nothing on the even one; the flat last-in-source-order value must not leak
        // across the sheet.
        let plain: [Int: Alignment] = [1: .right]
        let byParity: [Int: [HFParity: Alignment]] = [1: [.odd: .right]]
        #expect(hfAttr(plain, byParity, .odd) == [1: .right])
        #expect(hfAttr(plain, byParity, .even) == [:])
        #expect(hfAttr(plain, byParity, nil) == [1: .right])
    }

    @Test func headeryAndFooteryFollowThePDFsOwnFormula() {
        // `.mt 7 .hm 3` with one head line: headBase = 7 - 3 - 1 = 3 lines (720 twips).
        // `.pl 66 .mb 8 .fm 2`: 8 - 2 - 1 = 5 lines (1200 twips) under the footer.
        let page = PageGeometry(plLines: 66, heightIn: 11, sizeName: "Letter", sizeSource: .file,
                                mtLines: 7, mtSource: .file, mbLines: 8, mbSource: .file,
                                poCols: 8, poSource: .default, hmLines: 3, hmSource: .file,
                                fmLines: 2, fmSource: .file, lh48: 8, lhSource: .default,
                                ls: 1, lsSource: .default, cw120: 12, cwSource: .default,
                                textLines: 55)
        let (headery, footery) = rtfHeadFootDistance(page, headSlots: [1], printed: true)
        #expect(headery == 720)
        #expect(footery == 1200)
    }

    @Test func modernCarriesNoHeadFootDistance() {
        // Ruling 2026-08-17: Modern's page is its own; the reader's gap stands, exactly
        // as the reader's leading does.
        let (headery, footery) = rtfHeadFootDistance(nil, headSlots: [1], printed: false)
        #expect(headery == nil && footery == nil)
    }

    @Test func theDistanceNeverGoesNegative() {
        let page = PageGeometry(plLines: 66, heightIn: 11, sizeName: "Letter", sizeSource: .file,
                                mtLines: 1, mtSource: .file, mbLines: 1, mbSource: .file,
                                poCols: 8, poSource: .default, hmLines: 3, hmSource: .file,
                                fmLines: 3, fmSource: .file, lh48: 8, lhSource: .default,
                                ls: 1, lsSource: .default, cw120: 12, cwSource: .default,
                                textLines: 55)
        let (headery, footery) = rtfHeadFootDistance(page, headSlots: [1], printed: true)
        #expect(headery == 0 && footery == 0)
    }

    @Test func poeAndPooMirrorTheMargins() {
        // `.poo` is the odd (right-hand) page's own left offset, which under
        // `\margmirror` is `\margl`; `.poe` is the even page's, `\margr`.
        let out = emitRTF(Self.doc(dots: [".poe 1.35i", ".poo 5.8125i"]), mode: .printed)
        #expect(out.contains(#"\facingp"#) && out.contains(#"\margmirror"#))
        #expect(out.contains(#"\margl8370"#))             // 58.125 cols * 144
        #expect(out.contains(#"\margr1944"#))             // 13.5 cols * 144
    }

    @Test func modernKeepsItsOwnFixedPage() {
        let out = emitRTF(Self.doc(dots: [".poe 1.35i", ".poo 5.8125i"]), mode: .modern)
        #expect(!out.contains(#"\margmirror"#))
    }

    @Test func aDocumentWithoutPoePooIsUnmirrored() {
        #expect(!emitRTF(Self.doc(), mode: .printed).contains(#"\margmirror"#))
    }

    // MARK: the real corpus

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
          arguments: [EmitMode.printed, .modern])
    func theGalleyTemplatePrintsBothOfItsHeads(mode: EmitMode) throws {
        let path = sawyerArchivePath + "/REF/GALLEYS.DOT"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let out = emitRTF(try parse([UInt8](data)), mode: mode)
        #expect(out.contains(#"\facingp"#))
        #expect(out.contains(#"{\headerr \pard\plain \qr"#) && out.contains("TITLE"))
        #expect(out.contains(#"{\headerl "#) && out.contains("SAWYER"))
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func theGalleyTemplatesGeometry() throws {
        // `.mt 1.25i` (7.5 lines) `.hm .20i` (1.2) one head line -> 5.3 lines;
        // `.mb 1.50i` (9.0) `.fm .19i` (1.14) -> 6.86 lines. `.poo 5.8125i` /
        // `.poe 1.35i` mirror.
        let path = sawyerArchivePath + "/REF/GALLEYS.DOT"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let out = emitRTF(try parse([UInt8](data)), mode: .printed)
        #expect(out.contains(#"\headery1272"#) && out.contains(#"\footery1646"#))
        #expect(out.contains(#"\margl8370\margr1944"#))
        #expect(out.contains(#"\margmirror"#))
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
          arguments: [EmitMode.printed, .modern])
    func aBareTrailingPaDocumentLosesItsBlankPage(mode: EmitMode) throws {
        let path = sawyerArchivePath + "/STRENGTH.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](data))
        #expect(!doc.paEofBlankAfter)
        let out = emitRTF(doc, mode: mode)
        #expect(!out.trimmed().hasSuffix(#"\page \n}"#))
        #expect(out.contains(Self.footerNum))             // and it gains its number
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
          arguments: [EmitMode.printed, .modern])
    func theOneDocumentThatReallyOpensAPageKeepsIt(mode: EmitMode) throws {
        let path = sawyerArchivePath + "/REF/PAGESIZE.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](data))
        #expect(doc.paEofBlankAfter)
        #expect(emitRTF(doc, mode: mode).contains(#"\page"#))
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func aRealPnDocumentStartsWhereItSays() throws {
        let path = sawyerArchivePath + "/MACROS/HOLYMAC/4MAC1"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](data))
        #expect(doc.page?.pnStart == 22)
        #expect(emitRTF(doc, mode: .printed).contains(#"\pgnstart22"#))
    }
}
