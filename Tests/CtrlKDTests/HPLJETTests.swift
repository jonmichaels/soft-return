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

    /// `{text: x in decipoints from the logical page's left edge}` of a WS4 file's first body
    /// line, printed (57.6pt is the 576 dp left edge). Port of ctrl-kd's `_xs_dp`.
    static func xsDP(_ body: [UInt8]) -> [String: Int] {
        let shows = Self.shows(Self.ws4(body))
        let top = shows.compactMap(\.y).max() ?? 0
        var out: [String: Int] = [:]
        for s in shows where s.y == top {
            out[s.text.trimmed()] = Int(((s.x! - 57.6) * 10 + 576).rounded())
        }
        return out
    }

    /// WS4 teardown 7.9, run w20-thr9: a one-line file ending 8D 0A at .CW 9; S // blanks =
    /// 9 > THR 8, so letter spacing (ESC&k10H): 'abd' at 576, 'ef' at 834. The file's own
    /// last line keeps its soft return. Port of `test_a_files_last_line_stored_soft_is_justified`.
    @Test func aFilesLastLineStoredSoftIsJustified() {
        var body = bytes(".CW 9")
        body += HARD
        body += bytes(".UJ ON")
        body += HARD
        body += [0x61, 0x62, 0xE4, 0x20, 0xA0, 0x65, 0x66, 0xE7]
        body += SOFT
        #expect(Self.ws4(body).blocks.last?.lines.last?.soft == true)
        #expect(Self.xsDP(body) == ["abd": 576, "efg": 834])
    }

    /// WS4 teardown 7.9, run w20-neg: a line over the right margin under .PS .UJ ON; each gap
    /// shrinks 30 dp (M10, the pool capped by [1821] = 50h). Port of
    /// `test_a_negative_slack_shrinks_every_gap`.
    @Test func aNegativeSlackShrinksEveryGap() {
        var body = bytes(".PS ON")
        body += HARD
        body += bytes(".UJ ON")
        body += HARD
        body += [0x57, 0x57, 0xD7, 0x20, 0x4D, 0x4D, 0xCD, 0x20]
        body += [0x57, 0x57, 0xD7, 0x20, 0x4D, 0x4D, 0xCD, 0x20, 0x57, 0xD7]
        body += SOFT
        let xs = Self.shows(Self.ws4(body)).filter { ($0.y ?? 0) > 700 }
            .map { Int(((($0.x ?? 0) - 57.6) * 10 + 576).rounded()) }
        #expect(xs == [576, 1033, 1440, 1897, 2304])
    }

    /// WS4 teardown 7.9, runs w20-oj, w20-oj0: the two captures are the same bytes; every
    /// stored blank, 20h and A0h, is one PS14B blank (48 dp). Port of
    /// `test_oj_off_under_ps_prints_as_uj_off`.
    @Test func ojOffUnderPSPrintsAsUJOff() {
        var line: [UInt8] = [0x54, 0x68, 0xE5, 0x20, 0xA0]
        line += bytes("quic")
        line += [0xEB, 0x20, 0xA0]
        line += bytes("brow")
        line += [0xEE, 0x20, 0xA0, 0x66, 0x6F, 0xF8]
        line += SOFT
        for uj in [".UJ ON", ".UJ OFF"] {
            var body = bytes(".PS ON")
            body += HARD
            body += bytes(".OJ OFF")
            body += HARD
            body += bytes(uj)
            body += HARD
            body += line
            #expect(Self.xsDP(body) == ["The": 576, "quick": 926, "brown": 1368, "fox": 1874])
        }
        // .OJ off without .PS: the driver does not read it (M1)
        let chars = [HPLJET.Char(code: 0x61), HPLJET.Char(code: 0x62, hib: true),
                     HPLJET.Char(code: 0x20), HPLJET.Char(code: 0xA0),
                     HPLJET.Char(code: 0x63), HPLJET.Char(code: 0x64, hib: true)]
        #expect(HPLJET.placeLine(chars, po: 0, poCW: 12, ps: false, uj: "dis", soft: true,
                                 oj: false)?.map(\.x) == [0, 78, 156, 282, 282, 360])
    }

    /// WS4 teardown 7.9, run w22-a0: `abc` A0 A0 A0 `def`, only f flagged, soft return: no
    /// letter spacing (ESC&k12H), `def` at 1008 = 576 + 6 cells. Port of
    /// `test_soft_spaces_before_the_one_flagged_word_print_as_cells`.
    @Test func softSpacesBeforeTheOneFlaggedWordPrintAsCells() {
        var body = bytes(".UJ ON")
        body += HARD
        body += [0x61, 0x62, 0x63, 0xA0, 0xA0, 0xA0, 0x64, 0x65, 0xE6]
        body += SOFT
        let shown = Self.shows(Self.ws4(body)).filter { ($0.y ?? 0) > 700 }
        #expect(shown.map(\.text) == ["abc   def"])
        #expect(shown.map(\.x) == [57.6])
    }

    // MARK: - `.CW`, `.PO` and the page number
    // WS4 teardown 4 §15.3 (batch 33, runs cw30-*, cw30b-*): `.PO` is fixed in the `.CW` in
    // force when it is read; each character, margin column included, is one cell of the `.CW`
    // in force on its line; the plain page number sits at PO edge + (PC - 1) cells of the
    // install's normal width (factory 12) and prints in it; a `.FO`/`.HE` line prints in the
    // `.CW` it was read under.

    static func dots(_ lines: [String]) -> [UInt8] {
        var out: [UInt8] = []
        for line in lines {
            out += bytes(line)
            out += HARD
        }
        return out
    }

    static func at(_ shows: [ShownSpan], _ text: String) -> (size: Double, x: Double)? {
        shows.first { $0.text.trimmed() == text }.map { ($0.size, $0.x ?? -1) }
    }

    @Test func poIsFixedInTheCwInForceWhenRead() throws {
        // run cw30-po: `.CW 20 .PO 8 .PC 30` puts the left edge at 8 x 120 = 960 dp and the
        // number at 960 + 29 x 72 = 3048, ESC&k12H
        var shows = Self.shows(Self.ws4(Self.dots([".CW 20", ".PO 8", ".PC 30", "line one"])))
        let line = try #require(Self.at(shows, "line one"))
        #expect(line.size == 20 && abs(line.x - 96.0) < 1e-9)
        let number = try #require(Self.at(shows, "1"))
        #expect(number.size == 12 && abs(number.x - 304.8) < 1e-9)
        // run e5-hpl, cw-margins-typed: with `.PO` read at the factory width the edge stays
        // at 576 whatever `.CW` follows
        shows = Self.shows(Self.ws4(Self.dots([".PO 8", ".CW 20", "line one"])))
        #expect(abs((Self.at(shows, "line one")?.x ?? 0) - 57.6) < 1e-9)
    }

    @Test func thePlainPageNumberKeepsTheInstallWidth() throws {
        // runs cw30-pc, cw30-pc2: `.PC 30` then `.CW 20`, and a `.CW 10` before the page end:
        // the number at 576 + 29 x 72 = 2664 in 12 either way
        for tail in [[], [".CW 10", "line two"]] {
            let shows = Self.shows(Self.ws4(Self.dots([".PC 30", ".CW 20", "line one"] + tail)))
            let number = try #require(Self.at(shows, "1"))
            #expect(number.size == 12 && abs(number.x - 266.4) < 1e-9)
        }
        let doc = Self.ws4(Self.dots([".PC 30", ".CW 20", "line one"]))
        let auto = try #require(docToPagelines(doc, printed: true)[0].autoPageno)
        #expect(auto.size == 12 && abs(auto.x - 266.4) < 1e-9)
    }

    @Test func aMidPageCwSetsItsOwnLinesCells() throws {
        // run cw30-pc2: `.CW 10` before `line two` puts `two` at 576 + 5 x 60 = 876
        let doc = Self.ws4(Self.dots([".PC 30", ".CW 20", "line one", ".CW 10", "line two"]))
        let shows = Self.shows(doc)
        let two = try #require(Self.at(shows, "two"))
        #expect(two.size == 10 && abs(two.x - 87.6) < 1e-9)
        #expect(Self.at(shows, "line one")?.size == 20)
        let lineTwo = docToPagelines(doc, printed: true)[0][1]
        #expect(lineTwo.face == PageLine.Face(family: .courier, size: 10, bold: false))
    }

    @Test func aFooterPrintsInTheCwItWasReadUnder() throws {
        // run cw30b-fo: `.CW 20` then `.FO page #`: the footer at 20 (`1` at 576 + 5 x 120);
        // cw30b-fo2: `.FO` then `.CW 20` keeps 12 (576 + 5 x 72)
        for (lines, pt) in [([".CW 20", ".FO page #"], 20.0), ([".FO page #", ".CW 20"], 12.0)] {
            let doc = Self.ws4(Self.dots(lines + ["line one"]))
            let foot = try #require(Self.at(Self.shows(doc), "page 1"))
            #expect(foot.size == pt && abs(foot.x - 57.6) < 1e-9, "\(lines)")
            let model = try #require(docToPagelines(doc, printed: true)[0].footerLines?.first)
            #expect(Double(model.size ?? 20) == pt, "\(lines)")
        }
    }
}
