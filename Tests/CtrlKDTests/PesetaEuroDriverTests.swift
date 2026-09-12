import Foundation
import Testing
@testable import CtrlKD

/// planning #266: cp437 code 158 is driver-keyed, and the peseta draws.
///
/// THE BUG. `escFallback` (PDFWriter.swift) carried a blanket `₧` -> `€` entry: EVERY
/// document carrying cp437 code 158 got a euro on the page, whatever it meant by it. That
/// was right for exactly one family of documents and wrong for the rest.
///
/// THE RULE (Jon's ruling, 2026-09-11):
///
///     "driver keyed ... So anyone using Sawyer's trick gets the Euro. Any other old docs
///      which actually use a Peseta in them, see it as intended."
///
/// The trick is documented in Sawyer's own -README.WS, section "THE EURO CURRENCY SYMBOL":
/// WordStar was last updated in 1992, seven years before the euro was adopted, so he
/// patched three PRINTER DEFINITION FILES -- in this era a `.PDF` is WordStar's own printer
/// driver, nothing to do with Adobe -- LASERJET.PDF, LJ6DTP.PDF and HP4.PDF, so that PC-8
/// character 9E (the peseta slot) selects Roman-8 BA (the euro) on the printer. So:
///
///   * a document naming LASERJET, LJ6DTP or HP4 in its own WS7 header driver-name field
///     prints code 158 as a EURO;
///   * every other document prints it as the PESETA it really is, drawn as vector geometry
///     in the run's own cell (`symbolShapes`, Jon's 2026-08-11 cp437 ruling: a cp437 glyph
///     with no encoding slot is drawn as geometry) -- never as the `?` the text path used
///     to degrade it to.
///
/// Scope: the rule lives in `Layout.swift`, next to the semantic flow and the LJ6DTP
/// character substitutions it is a sibling of ("driver character substitutions are
/// content", ruling 2026-08-06 M7), so the semantic flow, the printed page-lines model and
/// both PDF views agree about what a document's code 158 says. What the RTF/HTML/text
/// emitters do with code 158 is planning #264's review and is untouched.
///
/// Port of ctrl-kd's `tests/test_peseta_euro_driver.py` (485603f, 1b1062e). Synthetic
/// fixtures throughout for the rule itself; the tier-2 tests at the bottom pin the real
/// corpus documents on both sides of the rule.
///
/// Byte fixtures below are built with `+=` (never chained `+`) per this repo's own
/// pre-push fixture rule (planning #253).
@Suite struct PesetaEuroDriverTests {
    static let peseta: UInt8 = 0x9E            // cp437 code 158
    static let euroCP1252: UInt8 = 0x80        // what a euro looks like inside a PDF string

    /// A WSFORMAT type-0 header block declaring `name` as the printer driver -- the leading
    /// byte is the record tag the parser strips (`pLASERJET`), and the trailing bytes are
    /// the reserved/style-pointer fields.
    static func driverHeader(_ name: String) -> [UInt8] {
        var content: [UInt8] = [0x70]          // 'p' -- the record tag
        content += Array(name.utf8)
        content += [0x00, 0x00, 0x00, 0x80]
        return wsBlock(cmd: 0x00, content: content)
    }

    static func body(_ text: String = "Costs \u{20A7} 100 today") -> [UInt8] {
        var out: [UInt8] = []
        for ch in text.unicodeScalars {
            out += ch == "\u{20A7}" ? [peseta] : Array(String(ch).utf8)
        }
        return out
    }

    static func doc(_ driver: String, _ text: String = "Costs \u{20A7} 100 today") -> Document {
        var data = driverHeader(driver)
        data += body(text)
        data += HARD
        return parseWS(data)
    }

    /// A WS5+ document that declares no driver at all -- `printerDriver` is nil, which is
    /// neither of the three patched names.
    static func headerlessDoc(_ text: String = "Costs \u{20A7} 100 today") -> Document {
        var data = wsBlock(cmd: 0x01, content: [0x00, 0x00])
        data += body(text)
        data += HARD
        return parseWS(data)
    }

    /// A synthetic document naming `driver` (or no driver at all, when `driver` is nil)
    /// whose `.h1`/`.f1` running head AND foot both carry `hfText` -- the running-head/
    /// foot counterpart of `doc(_:_:)`'s own body fixture. Port of ctrl-kd's
    /// `_doc_with_running_head` (test_peseta_euro_driver.py, f82a322).
    static func docWithRunningHead(_ driver: String?,
                                   _ hfText: String = "Report \u{20A7} Draft #") -> Document {
        var data = driver != nil ? driverHeader(driver!) : wsBlock(cmd: 0x01, content: [0x00, 0x00])
        data += bytes(".h1 ") + body(hfText) + HARD
        data += bytes(".f1 ") + body(hfText) + HARD
        data += bytes("Body text, plain and ordinary and long enough to be real.") + HARD
        return parseWS(data)
    }

    /// Every `(...)` literal handed to Tj in the whole file, as raw bytes.
    static func textStrings(_ out: [UInt8]) -> [[UInt8]] {
        var strings: [[UInt8]] = []
        var i = 0
        while i < out.count {
            guard out[i] == 0x28 else { i += 1; continue }          // '('
            var j = i + 1
            var current: [UInt8] = []
            while j < out.count {
                if out[j] == 0x5C, j + 1 < out.count {              // backslash escape
                    current.append(out[j + 1]); j += 2; continue
                }
                if out[j] == 0x29 { break }                         // ')'
                current.append(out[j]); j += 1
            }
            guard j + 4 <= out.count,
                  Array(out[(j + 1)..<(j + 4)]) == Array(" Tj".utf8) else { i += 1; continue }
            strings.append(current)
            i = j + 4
        }
        return strings
    }

    static func count(_ haystack: [UInt8], _ needle: [UInt8]) -> Int {
        countOccurrences(of: needle, in: haystack)
    }

    // MARK: - the table

    /// The bug, named directly: `₧` must not be a lookalike degradation at all any more --
    /// the driver decides, and the peseta draws.
    @Test func escFallbackNoLongerCarriesTheBlanketPesetaEntry() {
        var out: [UInt8] = []
        out += esc("\u{20A7}")
        #expect(out != [Self.euroCP1252], "₧ still degrades to a euro in esc()")
        // the rest of the table is untouched
        #expect(esc("\u{2219}") == [0xB7])
        #expect(esc("\u{203C}") == Array("!".utf8))
        #expect(esc("\u{2502}") == Array("|".utf8))
        #expect(esc("\u{2500}") == Array("-".utf8))
        #expect(esc("\u{2550}") == Array("=".utf8))
    }

    @Test func theThreePatchedDriversAreSawyersOwnThree() {
        #expect(euroPatchedDrivers == ["LASERJET", "LJ6DTP", "HP4"])
    }

    /// The parser extracts the header's 9-byte driver-name field as its leading
    /// upper-case/digit run, so a real document always arrives upper-case -- the rule is
    /// still stated case-insensitively so it cannot depend on that one parser detail.
    @Test func driverMatchIsCaseInsensitiveAndWhitespaceTolerant() {
        for name in ["LASERJET", "laserjet", " LJ6DTP ", "Hp4"] {
            #expect(pesetaMeansEuro(Document(blocks: [], printerDriver: name)), "\(name)")
        }
        for name in ["EPSONFX", "ACROBAT", "PRINTER", ""] {
            #expect(!pesetaMeansEuro(Document(blocks: [], printerDriver: name)), "\(name)")
        }
        #expect(!pesetaMeansEuro(Document(blocks: [], printerDriver: nil)))
    }

    // MARK: - the peseta geometry

    @Test func thePesetaIsADrawnGlyphNotAFallbackCharacter() {
        #expect(graphicChars.contains("\u{20A7}"))
        #expect(symbolShapes["\u{20A7}"] != nil)
        let rects = graphicCellRects("\u{20A7}")
        #expect(!rects.isEmpty)
        for r in rects {
            #expect(r.w > 0 && r.h > 0)
        }
        let ops = graphicCellOps("\u{20A7}")
        // the P's bowl is a disc, the stems/crossbar/foot are rects, and the two white
        // knockouts are omitted from both public accessors
        var discs = 0, fills = 0
        for op in ops {
            if case .fillDisc = op { discs += 1 }
            if case .fillRect = op { fills += 1 }
        }
        #expect(discs >= 1)
        #expect(fills >= 1)
        let drawn = (symbolShapes["\u{20A7}"] ?? []).filter { shape in
            if case .white = shape { return false }
            return true
        }
        #expect(ops.count == drawn.count)
    }

    /// The peseta is PDF drawing geometry, not a content-side box-drawing classifier: a
    /// currency character in prose must never be wrapped in HTML's forced-monospace
    /// `ws-graphic` span, given RTF's `\f1` override, or counted as a "this line is a
    /// picture" vote by `looksLikeVerse`. The two sets were the same until planning #266
    /// and this is the assertion that keeps them honestly apart.
    @Test func thePesetaIsNotAContentSideGraphicCharacter() {
        #expect(!contentGraphicChars.contains("\u{20A7}"))
        #expect(!isGraphicText("\u{20A7}"))
        // and the real box-drawing set is intact on both sides
        for ch in "█░▒▓▀▄▌▐■♦♥♠♣☻☼≡─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬" {
            #expect(contentGraphicChars.contains(ch), "\(ch)")
            #expect(graphicChars.contains(ch), "\(ch)")
        }
    }

    /// The model, not just the painted page: a consumer reading `modernSemanticFlow`
    /// (Soft Return.app's native text stack, the `layout` JSON) sees the character this
    /// document's own driver prints.
    @Test(arguments: [("LASERJET", "\u{20AC}", "\u{20A7}"), ("EPSONFX", "\u{20A7}", "\u{20AC}")])
    func theSemanticFlowCarriesTheResolvedCharacter(driver: String, shown: String, absent: String) {
        let flow = modernSemanticFlow(Self.doc(driver))
        var text = ""
        for item in flow.items {
            if case .para(let para) = item {
                for run in para.runs { text += run.text }
            }
        }
        #expect(text.contains(shown), "\(driver): expected \(shown) in the semantic flow")
        #expect(!text.contains(absent), "\(driver): \(absent) reached the semantic flow")
    }

    // MARK: - the euro's width

    /// `afmWidths` deliberately left 0x80 at 0 on the reasoning that the era's faces had no
    /// euro. They carry one, and `afmInkTops` was transcribed WITH it, so the two tables
    /// disagreed about whether the glyph exists -- harmless until planning #266 put euros
    /// on a page for the first time, at which point a drawn euro advanced NOTHING and
    /// Modern ran the next word into it ("here €,then you're", -README.WS page 16). The
    /// widths are the same URW base-35 AFMs every other number in that table came from.
    @Test func theEuroHasARealAdvanceInEveryBase14TextFace() {
        for face in ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"] {
            #expect(afmWidths[face]?[0x80] == 500, "\(face)")
        }
        for face in ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"] {
            #expect(afmWidths[face]?[0x80] == 556, "\(face)")
        }
        for face in ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"] {
            #expect(afmWidths[face]?[0x80] == 600, "\(face)")
        }
        // and the two tables now agree about the glyph existing at all
        for (face, widths) in afmWidths where widths[0x80] != 0 {
            if let inks = afmInkTops[face] {
                #expect(inks[0x80] > 0, "\(face)")
            }
        }
    }

    /// The visible defect, as a rule: the word after a euro starts a full space clear of it.
    @Test func aEuroAndItsCommaDoNotCollideUnderModern() throws {
        let doc = Self.doc("LASERJET", "Here \u{20A7}, then more words follow.")
        let out = emitPDF(doc, mode: .modern)
        let text = String(decoding: out, as: UTF8.self)
        var xs: [String: Double] = [:]
        // `<x> <y> Td (<string>) Tj`
        var scanner = text.startIndex
        while let tdRange = text.range(of: " Td (", range: scanner..<text.endIndex) {
            let head = text[..<tdRange.lowerBound]
            let coords = head.split(separator: " ").suffix(2).map(String.init)
            guard coords.count == 2, let x = Double(coords[0]) else {
                scanner = tdRange.upperBound; continue
            }
            guard let close = text.range(of: ") Tj", range: tdRange.upperBound..<text.endIndex) else {
                break
            }
            xs[String(text[tdRange.upperBound..<close.lowerBound])] = x
            scanner = close.upperBound
        }
        let euroComma = String(decoding: [Self.euroCP1252, 0x2C], as: UTF8.self)
        let euroCommaKey = xs.keys.first { $0.unicodeScalars.first?.value == 0x80 }
            ?? euroComma
        let xEuro = try #require(xs[euroCommaKey], "no euro+comma string found in the Modern PDF")
        let xThen = try #require(xs["then"], "no 'then' string found in the Modern PDF")
        #expect(xThen - xEuro
                > stringWidthPt("\u{20AC},", "Times-Roman", modernBodyPt),
                "the word after the euro overlaps it")
    }

    // MARK: - patched drivers: euro

    @Test(arguments: ["LASERJET", "LJ6DTP", "HP4"], [EmitMode.printed, EmitMode.modern])
    func aPatchedDriverPrintsTheEuro(driver: String, mode: EmitMode) {
        let doc = Self.doc(driver)
        #expect(doc.printerDriver == driver)
        let out = emitPDF(doc, mode: mode)
        #expect(Self.textStrings(out).contains { $0.contains(Self.euroCP1252) },
                "\(driver)/\(mode): no euro reached the content stream")
    }

    /// The euro is a real cp1252 character on every base-14 face, so it is ordinary TEXT --
    /// the vector path must not also fire for it.
    @Test(arguments: ["LASERJET", "LJ6DTP", "HP4"])
    func aPatchedDriverDrawsNoPesetaGeometry(driver: String) {
        let out = emitPDF(Self.doc(driver), mode: .printed)
        let plain = emitPDF(Self.doc(driver, "Costs 100 today"), mode: .printed)
        #expect(Self.count(out, Array(" re f".utf8)) == Self.count(plain, Array(" re f".utf8)))
    }

    // MARK: - other drivers: peseta

    @Test(arguments: [EmitMode.printed, EmitMode.modern])
    func anUnpatchedDriverDrawsThePeseta(mode: EmitMode) {
        let doc = Self.doc("EPSONFX")
        #expect(doc.printerDriver == "EPSONFX")
        let out = emitPDF(doc, mode: mode)
        #expect(!Self.textStrings(out).contains { $0.contains(Self.euroCP1252) },
                "\(mode): a euro reached a document no patched driver printed")
        // the Pt ligature: one Bezier disc (the P's bowl) plus filled rects
        let plain = emitPDF(Self.doc("EPSONFX", "Costs 100 today"), mode: mode)
        #expect(Self.count(out, Array(" re f".utf8)) > Self.count(plain, Array(" re f".utf8)))
        #expect(Self.count(out, Array(" c\n".utf8)) > Self.count(plain, Array(" c\n".utf8)))
    }

    @Test(arguments: [EmitMode.printed, EmitMode.modern])
    func aDocumentWithNoDriverAtAllDrawsThePeseta(mode: EmitMode) {
        let doc = Self.headerlessDoc()
        #expect(doc.printerDriver == nil)
        let out = emitPDF(doc, mode: mode)
        #expect(!Self.textStrings(out).contains { $0.contains(Self.euroCP1252) })
        #expect(contains(out, Array(" re f".utf8)))
    }

    /// The defect the vector path exists to close: before this, a non-patched document's
    /// code 158 had no cp1252 slot and no glyph, so it reached the page as a literal `?`.
    @Test(arguments: [EmitMode.printed, EmitMode.modern])
    func thePesetaNeverDegradesToAQuestionMark(mode: EmitMode) {
        let out = emitPDF(Self.doc("EPSONFX"), mode: mode)
        #expect(!Self.textStrings(out).contains { $0.contains(0x3F) },
                "\(mode): a \"?\" reached the content stream")
    }

    // MARK: - running heads/feet (planning #266 follow-up 2)

    /// THE LATENT GAP this fix closes: `runningOps` already bound `pesetaMeansEuro`
    /// (00b85ae, ported from ctrl-kd's f82a322) at the point it calls `hfLineOps`, but
    /// `modernStreams` never fed `modernHFOps` through `euroText` -- a Modern running
    /// head/foot carrying cp437 code 158 kept the pre-driver-rule degradation on a
    /// patched-driver document, the latent twin of the Printed gap that fix closed.
    /// Port of ctrl-kd's `test_a_patched_drivers_running_head_and_foot_print_the_euro`
    /// (test_peseta_euro_driver.py), extended to `.modern` here.
    @Test(arguments: ["LASERJET", "LJ6DTP", "HP4"], [EmitMode.printed, EmitMode.modern])
    func aPatchedDriversRunningHeadAndFootPrintTheEuro(driver: String, mode: EmitMode) {
        let doc = Self.docWithRunningHead(driver)
        #expect(doc.printerDriver == driver)
        let out = emitPDF(doc, mode: mode)
        switch mode {
        case .printed:
            // `hfLineOps` keeps a whole header/footer line as one `Tj` string, so the
            // euro lands inside the same string as "Report".
            let reportStrings = Self.textStrings(out).filter { line in
                contains(line, Array("Report".utf8))
            }
            #expect(!reportStrings.isEmpty,
                    "\(driver)/\(mode): the running head/foot text never reached the page")
            #expect(reportStrings.allSatisfy { $0.contains(Self.euroCP1252) },
                    "\(driver)/\(mode): no euro reached the running head/foot -- \(reportStrings)")
        case .modern:
            // `modernHFOps` tokenises a line word-by-word (`modernLineOps`'s one-op-per-
            // word rule), so the converted euro is its own standalone `Tj` string, never
            // merged with "Report"/"Draft". The fixture's body carries no peseta/euro of
            // its own, so any euro reaching the page at all must be this running
            // head/foot's.
            #expect(Self.textStrings(out).contains { $0.contains(Self.euroCP1252) },
                    "\(driver)/\(mode): no euro reached the running head/foot")
        }
    }

    /// The twin: a document naming no patched driver (or no driver at all) sees its
    /// running head/foot's own code 158 exactly as before this fix -- unchanged, not
    /// regressed, by the driver rule now reaching here, under either mode.
    ///
    /// The two modes were ALREADY different here, before this fix and after it alike:
    /// `hfLineOps` (printed) has no vector-drawing path of its own, so an unconverted
    /// peseta degrades through `esc`'s cp1252 fallback to a literal `?`, same as every
    /// other character `escFallback` does not cover. `modernHFOps` (modern) calls the
    /// SAME `modernLineOps` body text draws through, and that function's graphic-
    /// character branch does not know or care that its caller is a running line -- so an
    /// unconverted peseta there draws as the vector geometry `symbolShapes` defines,
    /// exactly as it would in a paragraph. Neither behavior moved when the euro table was
    /// wired in; this test pins both. Port of ctrl-kd's
    /// `test_an_unpatched_drivers_running_head_and_foot_keep_the_peseta_unconverted`.
    @Test(arguments: ["EPSONFX", nil], [EmitMode.printed, EmitMode.modern])
    func anUnpatchedDriversRunningHeadAndFootKeepThePesetaUnconverted(driver: String?, mode: EmitMode) {
        let driverDesc = String(describing: driver)
        let doc = Self.docWithRunningHead(driver)
        let plain = Self.docWithRunningHead(driver, "Report Draft #")
        #expect(doc.printerDriver == driver)
        let out = emitPDF(doc, mode: mode)
        #expect(!Self.textStrings(out).contains { $0.contains(Self.euroCP1252) },
                "\(driverDesc)/\(mode): a euro reached a running head/foot no patched driver printed")
        switch mode {
        case .printed:
            let reportStrings = Self.textStrings(out).filter { line in
                contains(line, Array("Report".utf8))
            }
            #expect(!reportStrings.isEmpty,
                    "\(driverDesc)/\(mode): the running head/foot text never reached the page")
            #expect(reportStrings.allSatisfy { $0.contains(0x3F) },
                    "\(driverDesc)/\(mode): expected the pre-existing \"?\" degradation, got \(reportStrings)")
        case .modern:
            // the vector twin of `anUnpatchedDriverDrawsThePeseta`: a peseta-bearing
            // running head/foot draws strictly more vector geometry than the same
            // fixture with the peseta simply removed, and no literal `?` reaches the page.
            let outPlain = emitPDF(plain, mode: mode)
            #expect(Self.count(out, Array(" re f".utf8)) > Self.count(outPlain, Array(" re f".utf8)))
            #expect(Self.count(out, Array(" c\n".utf8)) > Self.count(outPlain, Array(" c\n".utf8)))
            #expect(!Self.textStrings(out).contains { $0.contains(0x3F) },
                    "\(driverDesc)/\(mode): a \"?\" reached a running head/foot with its own vector path")
        }
    }

    // MARK: - tier 2 (the real corpus, gated)

    /// -README.WS is the document the euro trick was written FOR: it names LASERJET, and
    /// its own worked example inserts code 158 to prove the patched driver renders it.
    ///
    /// The Printed page is BYTE-IDENTICAL to what it was before planning #266 -- a
    /// patched-driver document was already getting the euro, just for the wrong reason.
    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func readmePrintsTheEuroWhereItAlwaysDid() throws {
        let path = sawyerArchivePath + "/-README.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](d))
        #expect(doc.printerDriver == "LASERJET")
        let out = emitPDF(doc, mode: .printed)
        var needle: [UInt8] = Array("BT /F1 12 Tf 0 Ts 57.6 564.0 Td (If you see the euro character right here ".utf8)
        needle += [Self.euroCP1252]
        needle += Array(", then you're all set ) Tj ET".utf8)
        #expect(contains(out, needle), "the euro line is not on the printed page where it was")
    }

    /// DISPLAY.WS is a bare cp437 code-to-glyph reference chart ("158 <glyph>") with no
    /// euro prose anywhere in it -- it used to be recorded as this rule's KNOWN LIMIT,
    /// resolved the same way as -README's own worked example for no reason of its own.
    /// Under the driver rule it is not a special case at all: it names LASERJET in its own
    /// header, so it is a patched-driver document and its chart entry shows the euro that
    /// driver actually put on paper.
    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func displayChartEntryFollowsItsOwnDriver() throws {
        let path = sawyerArchivePath + "/DISPLAY.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](d))
        #expect(doc.printerDriver == "LASERJET")
        let out = emitPDF(doc, mode: .printed)
        #expect(Self.textStrings(out).contains { $0.contains(Self.euroCP1252) })
    }

    /// A real corpus document on the OTHER side of the rule: REF/ASCIITAB.WS declares no
    /// patched driver, so its own code 158 stays the peseta and draws as geometry.
    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func asciitabKeepsItsPeseta() throws {
        let path = sawyerArchivePath + "/REF/ASCIITAB.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = try parse([UInt8](d))
        #expect(!euroPatchedDrivers.contains((doc.printerDriver ?? "").uppercased()))
        for mode in [EmitMode.printed, EmitMode.modern] {
            let out = emitPDF(doc, mode: mode)
            #expect(!Self.textStrings(out).contains { $0.contains(Self.euroCP1252) },
                    "\(mode): a euro reached an unpatched-driver corpus document")
        }
    }
}
