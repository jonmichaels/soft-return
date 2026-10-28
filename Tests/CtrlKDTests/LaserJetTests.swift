import Testing
@testable import CtrlKD

/// WS7's LASERJET driver: which of its fonts a document's font prints in, and where each piece
/// of a proportional line goes. Port of ctrl-kd's `tests/test_laserjet.py`.
///
/// The rules are the WS7 teardown's (report 11.17); the PCL tier (`PCLFidelityTests`) checks
/// them against WS7's own captures. These pin the arithmetic on small cases.
@Suite struct LaserJetTests {

    static func fontIndex(_ name: String) -> Int {
        LaserJetTables.fonts.firstIndex { $0.name == name }!
    }

    static func block(_ name: String, variant: Int = 0) -> LaserJetTables.Block {
        LaserJetTables.blocks[LaserJetTables.fonts[fontIndex(name)].blocks[variant]]!
    }

    @Test func aFontRecordPrintsInTheDriverFontMatchPicks() {
        // (HMI, twips, typestyle word) as real documents record them
        #expect(LaserJet.match(137, 240, 0xC605) == Self.fontIndex("Times PC ..."))
        #expect(LaserJet.match(138, 220, 0xC004) == Self.fontIndex("Univer PC ..."))      // Helv
        #expect(LaserJet.match(162, 240, 0xD234) == Self.fontIndex("Univer PC ..."))      // Avant Garde
        #expect(LaserJet.match(120, 240, 0xD25B) == Self.fontIndex("UniverC PC ..."))     // Helv Narrow
        #expect(LaserJet.match(153, 240, 0xD64A) == Self.fontIndex("Garamo PC ..."))      // Palatino 12
        #expect(LaserJet.match(142, 240, 0xC612) == Self.fontIndex("Garamo PC ..."))
    }

    @Test func aCharacterIsRoundedToWholeDotsOnItsOwn() {
        // Times PC 12pt: 'W' is 8294 units, 8294 x 100 x 240 x 300 /
        // (20 x 8782 x 7231) = 47.0 dots; HP's point is 1/72.31 inch
        let times = Self.block("Times PC ...")
        #expect(LaserJet.charDots(times, 240, Int(UInt8(ascii: "W"))) == 47)
        #expect(LaserJet.widthDots("WWW", times, 240, kerning: false) == 3 * 47)
    }

    @Test func aTrueTypeFaceRoundsPixelsPerEmFirst() {
        let tnr = Self.block("TNRmn PC ...")
        let ppem = (240 * 300 + 720) / 1440                      // 50
        let w = tnr.widths[Int(UInt8(ascii: "a"))]
        #expect(LaserJet.charDots(tnr, 240, Int(UInt8(ascii: "a"))) == (w * ppem + 1024) / 2048)
    }

    @Test func aKerningPairSplitsTheWordAndMovesTheRest() {
        // A-V is -26/128 em in Times PC; at 12pt the size is floor(240 x 300 / 1440) = 50
        // dots, so the pair moves V floor(26 x 50 / 128) = 10 dots in
        let times = Self.block("Times PC ...")
        let a = Int(UInt8(ascii: "A")), v = Int(UInt8(ascii: "V"))
        #expect(LaserJet.kernDots(times, 240, a, v) == -10)
        let aw = LaserJet.charDots(times, 240, a)
        let got = LaserJet.pieces("AV", times, 240)
        #expect(got.map(\.text) == ["A", "V"])
        #expect(got.map(\.x) == [0, aw - 10])
        #expect(got.map(\.width) == [aw, LaserJet.charDots(times, 240, v)])
        // .KR OFF: one piece, no move
        #expect(LaserJet.pieces("AV", times, 240, kerning: false).map(\.text) == ["AV"])
    }

    @Test func noPairAcrossABlankAndABlankRunIsOnePiece() {
        let times = Self.block("Times PC ...")
        let got = LaserJet.pieces("A  V", times, 240)
        #expect(got.map(\.text) == ["A", "  ", "V"])
        #expect(got[2].x == got[1].x + 2 * LaserJet.charDots(times, 240, 32))
    }

    @Test func aScriptIsMeasuredAtTheBlocksOwnScriptSize() {
        // Times 12 -> floor(240 x 175 / 256) = 164, floored to 5 twips: 8pt
        let times = Self.block("Times PC ...")
        #expect(LaserJet.twips(times, 12, script: true) == 160)
        #expect(LaserJet.twips(times, 12) == 240)
    }

    // MARK: Sawyer's LJ6DTP, run by the same rules (planning #210)

    @Test func aDefaultCourierRecordMatchesLJ6DTPsBitmapCouriers() {
        func name(_ w: Int, _ h: Int, _ k: Int) -> String {
            LJ6DTPTables.fonts[LaserJet.match(w, h, k, driver: .lj6dtp)!].name
        }
        #expect(name(180, 240, 0x4603) == "COURIER PC 10")
        #expect(name(150, 199, 0x4603) == "COURIER PC 12")
        #expect(name(150, 240, 0x4603) == "COURIER PC 12")
        #expect(name(137, 240, 0xC605) == "Times PC ...")
        #expect(name(138, 220, 0xC004) == "Arial PC ...")
        let courier = FontChange(offset: 0, width1800: 180, height1440: 240, typestyle: 0x4603)
        #expect(LaserJet.isBitmap(courier, driver: .lj6dtp))
        #expect(!LaserJet.isBitmap(courier))
    }

    @Test func zapfDingbatsBlockKeepsItsUnusualScaleRecord() throws {
        // em 1000, 1383/100000 inch to the point: the one block whose scale is not
        // 100/7231 or 1/72.
        let zapf = try #require(LJ6DTPTables.blocks["0a1e"])
        #expect(zapf.em == 1000 && zapf.num == 1383 && zapf.den == 100000)
        #expect(LaserJet.charDots(zapf, 240, 65) == 39)
    }

    @Test func theEuroAndTheControlGlyphsHaveTheirDocumentCodes() {
        #expect(LaserJet.code("€") == 0x9E)
        #expect(LaserJet.code("☺") == 1)
        #expect(LaserJet.code("⌂") == 0x7F)
        #expect(LaserJet.code("•") == 7)
        #expect(LaserJet.code("∙") == 249)     // the F9 a running head's bullet stands for
        #expect(LaserJet.code("©") == 0)       // no code in the page: the table's default
    }
}

@Test func aRecordWiderThanAnyProportionalFacePrintsInCourier() {
    // Port of test_a_record_wider_than_any_proportional_face_prints_in_courier.
    let entry = FontChange(offset: 0, width1800: 298, height1440: 360, typestyle: 0xCE15)
    #expect(LaserJet.font(for: entry)?.name == "Courier PC ...")
    #expect(LaserJet.fixedPitch1800(entry) == 270)
    let times = FontChange(offset: 0, width1800: 137, height1440: 240, typestyle: 0xC605)
    #expect(LaserJet.fixedPitch1800(times) == nil)
}

@Test func aFixedRecordAdvancesAtTheDriverPitchNotItsOwnWidth() {
    // Port of test_a_fixed_record_advances_at_the_driver_pitch_not_its_own_width: Sawyer's
    // LJ6DTP.WS page-7 Courier (151, 201, 4603h) prints in the scalable Courier at 200 twips,
    // 25 dots = 6.0pt (12 cpi); the record's 151 only picks the font. Another printer keeps it.
    let entry = FontChange(offset: 0, width1800: 151, height1440: 201, typestyle: 0x4603)
    for driver in ["LASERJET", "LJ6DTP", "HP4"] {
        let f = laserjetFonts([entry], driver: driver)[0]
        #expect(f.width1800 == 151)
        #expect(spanPitch(f, 10) == 6.0)
        #expect(laserjetFixedPitches([entry], driver: driver)[0].pitch1800 == 150)
    }
    #expect(spanPitch(laserjetFonts([entry], driver: "EPSONLQ")[0], 10) == 151.0 / 25.0)
}
