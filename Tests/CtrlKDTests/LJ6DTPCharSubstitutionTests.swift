import Foundation
import Testing
@testable import CtrlKD

/// planning #260: three real, byte-verified spots in the real LJ6DTP.WS (offsets
/// confirmed by direct hex inspection, 2026-09-10, alongside the matching real WS7
/// LaserJet PCL capture ws7-prints/v1/LJ6DTP.pcl and Jon's own paper scan of that
/// printout). Port of ctrl-kd's `tests/test_lj6dtp_char_substitution.py`'s own
/// cited-offset regression pins, same evidence, same three phenomena.
///
/// `ljSubst`/`ljSubstitute` (PDFDriverLJ6DTP.swift) ALREADY handled all three correctly
/// before planning #260 -- these tests LOCK that in against the exact cited bytes/
/// offsets ("sr = ctrl-kd cell-for-cell"), they do not fix a new bug here. The bug
/// planning #260 actually found was in ctrl-kd's PCL ground-truth decoder
/// (tools/pcl_text.py / pcl_render.py), which has no Swift port to mirror (this
/// engine's PCL-side fidelity gate, PCLFidelityTests.swift, shells to ctrl-kd's own
/// Python tool rather than re-implementing it).
///
/// Byte fixtures below are built with `+=` (never chained `+`) per this repo's own
/// pre-push fixture rule (planning #253).
@Suite struct LJ6DTPCharSubstitutionTests {
    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func colorHeadingQuotesAtOffset0x4859() throws {
        let path = sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let data = [UInt8](d)
        // 0x4859: <ESC><AE><FS>Color<ESC><AF><FS> -- the extended-character triples
        // bracketing "Color" in the page-5 "Color Mappings" heading. `ljSubst` maps
        // cp437 '\u{00AB}'(AE)/'\u{00BB}'(AF) -> curly double quotes; this heading is
        // Univers (proportional), so the substitution must fire. Matches the real WS7
        // LaserJet capture (ESC(7J<B0>/<B1> bracketing "Color") and the paper scan.
        var expectedTriple: [UInt8] = [0x1b, 0xae, 0x1c]
        expectedTriple += Array("Color".utf8)
        expectedTriple += [0x1b, 0xaf, 0x1c]
        let start = 0x4859 - 3
        let slice = Array(data[start..<(start + 11)])
        #expect(slice == expectedTriple, "fixture offset moved -- re-locate before trusting this test")

        let doc = parseWS(data)
        let out = emitPDF(doc, mode: .printed)
        // cp1252 0x93/0x94 = curly double open/close (/WinAnsiEncoding).
        var needle: [UInt8] = [0x28, 0x93]
        needle += Array("Color".utf8)
        needle += [0x94, 0x29, 0x20, 0x54, 0x6a]
        #expect(contains(out, needle), "expected (\\x93Color\\x94) Tj in the printed PDF content stream")
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func copyrightClusterAtOffset0x3da() throws {
        let path = sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let data = [UInt8](d)
        // 0x3da+: "Copyright " then (after a font-change block) <ESC>\x02<FS> -- the
        // extended-character triple wrapping cp437 0x02 (a smiley, WordStar's own PC-8
        // screen glyph for this slot). `ljSubst` maps it -> (c). This is the title
        // bar's SANS copyright (Univers, matching the real capture's ESC(5M<E3> sans-
        // serif slot -- see tools/pcl_symbol_sets.py's "5M's 0xE3 CORRECTION" in the
        // ctrl-kd repo); the body-text serif occurrences (ESC(5M<D3>) go through the
        // same substitution.
        #expect(Array(data[0x3da..<(0x3da + 9)]) == Array("Copyright".utf8),
                "fixture offset moved -- re-locate before trusting this test")
        let triple: [UInt8] = [0x1b, 0x02, 0x1c]
        var foundNear = false
        var i = 0x3da
        while i + 3 <= data.count && i < 0x3da + 40 {
            if Array(data[i..<(i + 3)]) == triple { foundNear = true; break }
            i += 1
        }
        #expect(foundNear, "the (c) triple should follow \"Copyright \" closely")

        let doc = parseWS(data)
        let out = emitPDF(doc, mode: .printed)
        // cp1252 0xa9 == Latin-1 == (c), U+00A9. "(\xa9) Tj"
        let needle: [UInt8] = [0x28, 0xa9, 0x29, 0x20, 0x54, 0x6a]
        #expect(contains(out, needle), "expected (\\xa9) Tj in the printed PDF content stream")
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func wordStarsApostropheCurlyOnProportionalFace() throws {
        let path = sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let data = [UInt8](d)
        // "WordStar's" (plain typed apostrophe, 0x27) on a PROPORTIONAL face (Times/
        // Univers body text) prints curly -- matching the real WS7 capture, where the
        // driver brackets that one byte with ESC(7J<27> between two ESC(10U runs
        // (curly per the DeskTop symbol set's own $27 slot) rather than leaving it
        // under plain PC-8 (straight). `ljSubst` maps plain "'" -> U+2019 for any
        // proportional entry, matching this without per-symbol-set tracking on the
        // .WS side.
        let doc = parseWS(data)
        let out = emitPDF(doc, mode: .printed)
        // cp1252 0x92 == U+2019 RIGHT SINGLE QUOTATION MARK. "(WordStar\x92s)"
        var needle: [UInt8] = [0x28]
        needle += Array("WordStar".utf8)
        needle += [0x92, 0x73, 0x29]
        #expect(contains(out, needle))
    }
}
