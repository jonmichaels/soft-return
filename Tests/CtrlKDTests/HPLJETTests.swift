import Testing
@testable import CtrlKD

/// WS4's HPLJET driver: where it puts a WS4 file's lines and words. Port of ctrl-kd's
/// `tests/test_hpljet.py`.
///
/// The rules are the WS4 teardown's (`wordstar4-dos/4-formatting-printing.md` 15); ctrl-kd's
/// teardowns tier checks them against WordStar 4's own captures. These pin the arithmetic on
/// small hand-made lines. Fixtures are built with sequential `+=` (planning #253).
@Suite struct HPLJETTests {

    static func ws4(_ body: [UInt8]) -> Document {
        parseWS(body, variant: .ws4)
    }

    static func shows(_ doc: Document) -> [ShownSpan] {
        contentSpans(emitPDF(doc, mode: .printed))
    }

    static func y(_ shows: [ShownSpan], _ text: String) -> Double? {
        shows.first { $0.text.trimmed() == text }?.y
    }

    static func x(_ shows: [ShownSpan], _ text: String) -> Double? {
        shows.first { $0.text.trimmed() == text }?.x
    }

    static func xs(_ chars: [HPLJET.Char], po: Int, poCW: Int, ps: Bool, uj: String,
                   soft: Bool) -> [Int]? {
        HPLJET.placeLine(chars, po: po, poCW: poCW, ps: ps, uj: uj, soft: soft)?.map(\.x)
    }

    @Test func lineOneSitsTheVbiasBelowTheTopMarginWhateverLh() throws {
        // V = (MT·8 + 16)·15 decipoints: 600 at the factory .MT 3 (60pt from the top),
        // still 600 under .LH 12 (run hj-lh12top)
        for dots in [[], bytes(".LH 12") + HARD] {
            var body = dots
            body += bytes("one")
            body += HARD
            body += bytes("two")
            body += HARD
            let one = try #require(Self.y(Self.shows(Self.ws4(body)), "one"))
            #expect(abs(792 - one - 60.0) < 1e-9)
        }
    }

    @Test func eachLineStepsByTheLhOfTheLineAbove() throws {
        // a .LH changes the step below the next text line (run hj-lhmix)
        var body = bytes("one")
        body += HARD
        body += bytes(".LH 16")
        body += HARD
        body += bytes("two")
        body += HARD
        body += bytes("three")
        body += HARD
        let shows = Self.shows(Self.ws4(body))
        let one = try #require(Self.y(shows, "one"))
        let two = try #require(Self.y(shows, "two"))
        let three = try #require(Self.y(shows, "three"))
        #expect(abs(one - two - 12.0) < 1e-9)       // LH 8 in force on 'one'
        #expect(abs(two - three - 24.0) < 1e-9)     // LH 16 in force on 'two'
    }

    @Test func ws7PrintingAWS4FileKeepsWS7sOrigin() throws {
        var body = bytes("one")
        body += HARD
        let doc = parseWS(body, variant: .ws4, printedBy: .ws7)
        let one = try #require(Self.y(Self.shows(doc), "one"))
        #expect(abs(792 - one - 48.0) < 1e-9)
    }

    @Test func theSlackOfTheEditorsSoftSpacesIsReSpread() {
        // 'ab' + 20h + A0h + 'cd', b and d flagged, soft return, .CW 12: the nominal width
        // is 6 cells (72), the device width 5 (60, the A0 has none), so S = 12/120"; S per
        // blank 12 > THR 8, so each letter but the last takes one unit (3), and the blank
        // the other 9 (M5-M11)
        let chars = [HPLJET.Char(code: 0x61), HPLJET.Char(code: 0x62, hib: true),
                     HPLJET.Char(code: 0x20), HPLJET.Char(code: 0xA0),
                     HPLJET.Char(code: 0x63), HPLJET.Char(code: 0x64, hib: true)]
        #expect(Self.xs(chars, po: 0, poCW: 12, ps: false, uj: "dis", soft: true)
                == [0, 78, 156, 282, 282, 360])
        // a hard return, or .UJ off: the editor's cells
        for (uj, soft) in [("dis", false), ("off", true)] {
            #expect(Self.xs(chars, po: 0, poCW: 12, ps: false, uj: uj, soft: soft)
                    == [0, 72, 144, 216, 288, 360])
        }
    }

    @Test func textBeforeTheFirstFlaggedWordKeepsItsCells() {
        // M4: nothing flagged, nothing justified (run mj-nobit)
        var chars = bytes("ab").map { HPLJET.Char(code: Int($0)) }
        chars += [HPLJET.Char(code: 0x20), HPLJET.Char(code: 0xA0)]
        chars += bytes("cd").map { HPLJET.Char(code: Int($0)) }
        #expect(Self.xs(chars, po: 0, poCW: 12, ps: false, uj: "dis", soft: true)
                == [0, 72, 144, 216, 288, 360])
    }

    @Test func proportionalWordsAdvanceByPS14B() throws {
        // §14: 'The ' is 252 units of 1/600" in PS14B; from x 576 (480 units) the next word
        // is at floor(732 x 1.2) = 878 decipoints
        let chars = bytes("The quick").map { HPLJET.Char(code: Int($0)) }
        let xs = try #require(Self.xs(chars, po: 8, poCW: 12, ps: true, uj: "dis",
                                      soft: false))
        #expect(xs[0] == 576)
        #expect(xs[4] == 878)
    }

    @Test func aJustifiedWS4LineIsDrawnWordByWord() throws {
        var body = bytes("a")
        body += [UInt8(ascii: "b") | 0x80]
        body += bytes(" ")
        body += [0xA0]
        body += bytes("c")
        body += [UInt8(ascii: "d") | 0x80]
        body += bytes(" ")
        body += bytes("ef")
        body += [UInt8(ascii: "g") | 0x80]
        body += SOFT
        body += bytes("end")
        body += HARD
        let doc = Self.ws4(body)
        #expect(doc.blocks[0].lines[0].hibit == [1, 3, 5, 9])
        // 'cd' leaves the 72 dp grid (it would sit at 57.6 + 4 x 7.2)
        let cd = try #require(Self.x(Self.shows(doc), "cd"))
        #expect(abs(cd - (57.6 + 4 * 7.2)) > 1e-6)
    }

    @Test func psTextIsDrawnInTheCartridgeFace() throws {
        var body = bytes(".PS ON")
        body += HARD
        body += bytes("The quick")
        body += HARD
        let pdf = emitPDF(Self.ws4(body), mode: .printed)
        #expect(latin1(pdf).contains("/BaseFont /Helvetica-Bold"))
        let quick = try #require(Self.x(contentSpans(pdf), "quick"))
        #expect(abs(quick - (57.6 + Double(878 - 576) / 10.0)) < 1e-9)
    }

    @Test func composPrintsBoxDrawingAsASCIIAndOverstrikesACross() {
        let body: [UInt8] = [0x1B, 0xDA, 0x1C, 0x1B, 0xC4, 0x1C, 0x1B, 0xC5, 0x1C] + HARD
        let texts = Self.shows(Self.ws4(body)).map(\.text)
        #expect(texts.contains("/--"))                 // ┌ ─ ┼ as / - -
        #expect(texts.contains("|"))                   // ┼'s second pass
        // WS7 printing the same file keeps the box glyphs (drawn as vector cells)
        let ws7 = Self.shows(parseWS(body, variant: .ws4, printedBy: .ws7)).map(\.text)
        #expect(!ws7.contains("/--"))
    }

    /// WS4's HPLJET moves a sub/superscript `.SR` x 15 decipoints and prints it in the line's
    /// own font and cell (WS4 teardown 4 15.2, run hj-sr). Port of ctrl-kd's
    /// `test_hpljet_prints_a_script_full_size_on_its_own_cell`.
    @Test func hpljetPrintsAScriptFullSizeOnItsOwnCell() throws {
        var data: [UInt8] = bytes("cd.")
        data += [0x14]
        data += bytes("1")
        data += [UInt8(0x14 | 0x80)]
        data += bytes("  ef")
        data += HARD
        var byText: [String: ShownSpan] = [:]
        for span in contentSpans(emitPDF(parseWS(data), mode: .printed)) {
            byText[span.text] = span
        }
        let sup = try #require(byText["1"])
        #expect(sup.size == 12)
        let tail = try #require(byText["  ef"])
        #expect(abs(tail.x! - (sup.x! + 7.2)) < 1e-6)
    }

    /// Port of ctrl-kd's `_hpljet_checkpoints` pattern: `\b` after the name, so `.PSON` is
    /// no `.PS`; a bare or bad `.PO` is 0 and takes the `.CW` in force.
    @Test func checkpointsReadTheDriversFourCommands() {
        var body = bytes(".PSON")
        body += HARD
        body += bytes(".cw 10")
        body += HARD
        body += bytes(".po x")
        body += HARD
        body += bytes(".uj maybe")
        body += HARD
        body += bytes("text")
        body += HARD
        let last = hpljetCheckpoints(Self.ws4(body)).last!.settings
        #expect(last == HPLJETSettings(ps: false, uj: "dis", cw: 10, po: 0, poCW: 10))
    }
}
