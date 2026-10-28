import Foundation
import Testing
import TestSupport
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
    @Test(.requiresSawyerArchive)
    func colorHeadingQuotesAtOffset0x4859() throws {
        let path = Corpus.sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw Corpus.missingSawyerFixture(path: path)
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

    @Test(.requiresSawyerArchive)
    func copyrightClusterAtOffset0x3da() throws {
        let path = Corpus.sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw Corpus.missingSawyerFixture(path: path)
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
        // Drawn from Symbol at the capture's own code: E3, copyrightsans, for Univers. "(\xe3) Tj"
        let needle: [UInt8] = [0x28, 0xe3, 0x29, 0x20, 0x54, 0x6a]
        #expect(contains(out, needle), "expected (\\xe3) Tj in the printed PDF content stream")
        #expect(contains(out, Array("/BaseFont /Symbol".utf8)), "expected the Symbol font")
    }

    @Test(.requiresSawyerArchive)
    func wordStarsApostropheCurlyOnProportionalFace() throws {
        let path = Corpus.sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw Corpus.missingSawyerFixture(path: path)
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
        // cp1252 0x92 == U+2019 RIGHT SINGLE QUOTATION MARK; LJ6DTP's own W-o pair prints
        // the word as 'W' + 'ordStar’s'.
        var needle: [UInt8] = [0x28]
        needle += Array("ordStar".utf8)
        needle += [0x92, 0x73, 0x29]
        #expect(contains(out, needle))
    }

    /// The `.kr off` / `.kr on` demo lines of LJ6DTP.WS. Port of ctrl-kd's
    /// `test_lj6dtp_document_kerning_lines_render_differently`'s PDF half.
    @Test(.requiresSawyerArchive)
    func kerningOnTucksTheQuotePairAsTwoPieces() throws {
        let path = Corpus.sawyerArchivePath + "/LJ6DTP.WS"
        guard let d = FileManager.default.contents(atPath: path) else {
            throw Corpus.missingSawyerFixture(path: path)
        }
        let out = emitPDF(parseWS([UInt8](d)), mode: .printed)
        // cp1252 single open quotes 0x91. Loose, `.kr off`: the pair prints whole, two
        // glyphs in one piece. Tight, `.kr on`: the driver's own 60 60 pair (WS7 teardown
        // 17.4) moves the second quote in, so it starts a piece of its own, tucked against
        // the first.
        #expect(contains(out, [0x28, 0x91, 0x91] + Array("These) Tj".utf8)))
        var latin1 = String.UnicodeScalarView()
        for b in out { latin1.append(Unicode.Scalar(b)) }
        let text = String(latin1)
        let shown = try Self.shownPieces(text)
        let at = try #require(shown.firstIndex { $0.text == "\u{91}But" })
        #expect(at > 0 && shown[at - 1].text == "\u{91}", "the tight pair is not two pieces")
        let gap = shown[at].x - shown[at - 1].x
        #expect(gap > 0 && gap < 3.0, "the tight pair is not tucked")
    }

    /// Every `x y Td (text) Tj` of the content, in order.
    private static func shownPieces(_ text: String) throws -> [(x: Double, text: String)] {
        let re = try NSRegularExpression(
            pattern: #"([\d.]+) [\d.]+ Td \(((?:[^()\\]|\\.)*)\) Tj"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (Double(ns.substring(with: $0.range(at: 1)))!, ns.substring(with: $0.range(at: 2)))
        }
    }
}
