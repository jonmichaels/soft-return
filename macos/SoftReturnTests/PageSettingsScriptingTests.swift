import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `PageSettingsScripting` — the `page settings` record's two-way bridge, the
/// `settings preset`/record disambiguation `export`/`convert`'s polymorphic `page
/// settings` parameter needs, and the `.PAT` importer's first real caller.
@Suite struct PageSettingsScriptingTests {

    // MARK: - record round trip

    @Test func recordOmitsFieldsThatAreNilInPageSettings() {
        let settings = PageSettings(mtLines: 3.0, poCols: 7.0)
        let record = PageSettingsScripting.record(from: settings)
        #expect(record["marginTop"] as? Double == 3.0)
        #expect(record["pageOffset"] as? Double == 7.0)
        #expect(record["marginBottom"] == nil)
        #expect(record["headerMargin"] == nil)
        #expect(record["footerMargin"] == nil)
        #expect(record["pageLength"] == nil)
    }

    @Test func recordRoundTripsEveryFieldOfASawyerLikeSettings() {
        let settings = PageSettings(
            mtLines: 1195.0 / 1440.0 * 6.0, mbLines: 6.0, poCols: 7.0,
            hmLines: 1.0, fmLines: 1.0, plLines: 66.0)
        let record = PageSettingsScripting.record(from: settings)
        let roundTripped = PageSettingsScripting.pageSettings(fromRecord: record)
        #expect(roundTripped == settings)
    }

    @Test func pageSettingsFromRecordIgnoresUnrelatedKeys() {
        let record: [String: Any] = ["marginTop": 5.0, "somethingElse": "ignored"]
        let settings = PageSettingsScripting.pageSettings(fromRecord: record)
        #expect(settings == PageSettings(mtLines: 5.0))
    }

    // MARK: - paper size (job 504)

    @Test func pageSettingsFromRecordResolvesPaperSizeToPageLengthForAllThreeNamedSizes() {
        let cases: [(String, Double)] = [
            ("SRpl", 66.0),           // US letter
            ("SRpg", 84.0),           // US legal
            ("SRp4", 11.693 * 6),     // A4
        ]
        for (code, expectedPlLines) in cases {
            let record: [String: Any] = ["paperSize": ScriptingCodes.nsNumber(code)]
            let settings = PageSettingsScripting.pageSettings(fromRecord: record)
            #expect(settings == PageSettings(plLines: expectedPlLines))
        }
    }

    @Test func pageSettingsFromRecordLetsAnExplicitPageLengthWinOverPaperSize() {
        let record: [String: Any] = [
            "paperSize": ScriptingCodes.nsNumber("SRpg"),   // US legal -> 84.0
            "pageLength": 40.0,
        ]
        let settings = PageSettingsScripting.pageSettings(fromRecord: record)
        #expect(settings == PageSettings(plLines: 40.0), "an explicit page length must win over paper size")
    }

    @Test func pageSettingsFromRecordIgnoresAnUnrecognizedPaperSizeCode() {
        let record: [String: Any] = ["paperSize": NSNumber(value: 12345), "marginTop": 3.0]
        let settings = PageSettingsScripting.pageSettings(fromRecord: record)
        #expect(settings == PageSettings(mtLines: 3.0))
    }

    @Test func paperSizePlLinesMatchesTheCLIsOwnPageSettingsSizeTable() {
        // Arguments.swift's `sizes` dict (SoftReturnCLI, --page-settings size=), copied
        // verbatim — not re-derived — so this pins the literal duplication stays honest.
        #expect(PageSettingsScripting.paperSizePlLines[.usLetter] == 66.0)
        #expect(PageSettingsScripting.paperSizePlLines[.usLegal] == 84.0)
        #expect(PageSettingsScripting.paperSizePlLines[.a4] == 11.693 * 6)
    }

    // MARK: - descriptor (job 207: the reply-packagable typed record)

    @Test func descriptorOmitsFieldsThatAreNilInPageSettings() {
        let settings = PageSettings(mtLines: 3.0, poCols: 7.0)
        let descriptor = PageSettingsScripting.descriptor(from: settings)
        #expect(descriptor.descriptorType == ScriptingCodes.fourCharCode("SRrp"))
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr1"))?.doubleValue == 3.0)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr3"))?.doubleValue == 7.0)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr2")) == nil)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr4")) == nil)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr5")) == nil)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr6")) == nil)
    }

    @Test func descriptorEncodesEveryFieldOfASawyerLikeSettings() {
        let settings = PageSettings(
            mtLines: 1195.0 / 1440.0 * 6.0, mbLines: 6.0, poCols: 7.0,
            hmLines: 1.0, fmLines: 1.0, plLines: 66.0)
        let descriptor = PageSettingsScripting.descriptor(from: settings)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr1"))?.doubleValue == settings.mtLines)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr2"))?.doubleValue == settings.mbLines)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr3"))?.doubleValue == settings.poCols)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr4"))?.doubleValue == settings.hmLines)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr5"))?.doubleValue == settings.fmLines)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRr6"))?.doubleValue == settings.plLines)
    }

    // MARK: - infoValue (job 216: import page settings' new JSON-text reply shape)

    @Test func infoValueOmitsFieldsThatAreNilInPageSettings() {
        let settings = PageSettings(mtLines: 3.0, poCols: 7.0)
        let text = ScriptingJSONRendering.render(PageSettingsScripting.infoValue(from: settings))
        #expect(text.contains("\"mt_lines\": 3.0"))
        #expect(text.contains("\"po_cols\": 7.0"))
        #expect(!text.contains("mb_lines"))
        #expect(!text.contains("hm_lines"))
        #expect(!text.contains("fm_lines"))
        #expect(!text.contains("pl_lines"))
    }

    /// Genuine full absence — no synthetic byte offsets needed: `importPageSettingsReturns
    /// AllNilForADumpWithNoINIEDTLabel` below already proves a `.PAT` dump with no `INIEDT`
    /// label produces an all-`nil` `PageSettings`; this is what `infoValue(from:)` does with
    /// that exact value.
    @Test func infoValueOfAllNilPageSettingsIsAnEmptyObject() {
        let text = ScriptingJSONRendering.render(PageSettingsScripting.infoValue(from: PageSettings()))
        #expect(text == "{}")
    }

    // MARK: - resolving the polymorphic `page settings` parameter

    @Test func resolveReturnsNilWhenTheArgumentIsAbsent() {
        #expect(PageSettingsScripting.resolve(nil) == nil)
    }

    @Test func resolveDecodesASettingsPresetEnumeratorCode() {
        let code = ScriptingCodes.nsNumber("SRxs")   // sawyer
        let resolved = PageSettingsScripting.resolve(code)
        #expect(resolved == DocumentOperations.PageSettingsPreset.sawyer.settings)
    }

    @Test func resolveDecodesAllThreePresetsToTheSameSettingsDocumentOperationsWouldGive() {
        let cases: [(String, DocumentOperations.PageSettingsPreset)] = [
            ("SRxf", .default), ("SRxs", .sawyer), ("SRxm", .modern),
        ]
        for (code, preset) in cases {
            let resolved = PageSettingsScripting.resolve(ScriptingCodes.nsNumber(code))
            #expect(resolved == preset.settings)
        }
    }

    @Test func resolveDecodesASwiftDictionaryRecordLiteral() {
        let record: [String: Any] = ["marginTop": 2.0, "pageOffset": 8.0]
        let resolved = PageSettingsScripting.resolve(record)
        #expect(resolved == PageSettings(mtLines: 2.0, poCols: 8.0))
    }

    @Test func resolveDecodesAnNSDictionaryRecordTheSameWay() {
        let dict = NSDictionary(dictionary: ["marginTop": 2.0, "pageOffset": 8.0])
        let resolved = PageSettingsScripting.resolve(dict)
        #expect(resolved == PageSettings(mtLines: 2.0, poCols: 8.0))
    }

    @Test func resolveReturnsNilForAnUnrecognizedNumberCode() {
        // A number that isn't one of the three preset codes — decode fails closed, not
        // to a wrong guess.
        #expect(PageSettingsScripting.resolve(NSNumber(value: 12345)) == nil)
    }

    // MARK: - `import page settings from ...` (the .PAT interpreter's first real caller)

    /// A minimal synthetic WSCHANGE `.PAT` dump: one `INIEDT=` line, 68 bytes (INISIZ),
    /// with `.mt`/`.mb`/`.pl`/`.hm`/`.fm`/`.po` set at the byte offsets `WSChange.swift`
    /// documents (`mtOff` 0x14, `mbOff` 0x16, `plOff` 0x18, `hmOff` 0x1F, `fmOff` 0x21,
    /// `poEvenOff` 0x24), each a little-endian 16-bit count — 1/1440in for every field
    /// except `.po` (1/1800in). Everything else zeroed.
    private static func syntheticPAT() -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 68)
        func setLE16(_ offset: Int, _ value: Int) {
            block[offset] = UInt8(value & 0xFF)
            block[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        setLE16(0x14, 720)     // .mt  -> 720/1440*6  = 3.0 lines
        setLE16(0x16, 1440)    // .mb  -> 1440/1440*6 = 6.0 lines
        setLE16(0x18, 2400)    // .pl  -> 2400/1440*6 = 10.0 lines
        setLE16(0x1F, 480)     // .hm  -> 480/1440*6  = 2.0 lines
        setLE16(0x21, 960)     // .fm  -> 960/1440*6  = 4.0 lines
        setLE16(0x24, 1260)    // .po  -> 1260/1800*10 = 7.0 columns

        let hex = block.map { String(format: "%02X", $0) }.joined(separator: ",")
        let text = "INIEDT=\(hex)\r\n"
        return [UInt8](text.utf8)
    }

    @Test func importPageSettingsReadsEveryFieldOfASyntheticPATDump() throws {
        let settings = try PageSettingsScripting.importPageSettings(from: Self.syntheticPAT())
        #expect(settings == PageSettings(
            mtLines: 3.0, mbLines: 6.0, poCols: 7.0, hmLines: 2.0, fmLines: 4.0, plLines: 10.0))
    }

    @Test func importPageSettingsReturnsAllNilForADumpWithNoINIEDTLabel() throws {
        let text = "NOTYPE=\"BAK\"\r\n"
        let settings = try PageSettingsScripting.importPageSettings(from: [UInt8](text.utf8))
        #expect(settings == PageSettings())
    }

    @Test func importPageSettingsThrowsForBytesThatAreNotAPATFileAtAll() {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03]   // no "=" on any line
        #expect(throws: PageSettingsScripting.ImportError.self) {
            _ = try PageSettingsScripting.importPageSettings(from: bytes)
        }
    }
}
