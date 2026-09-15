import Foundation
import Testing
@testable import CtrlKD

/// planning #264 item 5 (packet rows C3+C4): Modern RTF catches up with the app.
///
/// C3 — DEFINITION AND BULLET ROWS HANG. Modern RTF rendered both as plain paragraphs, so
/// the wrapped part of a definition returned to the left margin instead of hanging under
/// its own text. They are hanging paragraphs now (`\li` plus a negative `\fi`) on the SAME
/// ladder the Modern PDF lays — `modernLevelStepCols` (4 print columns per nesting level,
/// level 1 at the margin) and `modernDefHangPt` (a fixed 72pt body column), the app
/// behaviour Jon ruled back into the engines on 2026-09-11 ("Definitely backport. We spent
/// a long time getting that looking nice."). A bullet's hang is its own marker's advance
/// instead, measured.
///
/// The HTML half of C3 is the stylesheet: `ul`/`dl`/`dt`/`dd` geometry read from those
/// same two constants, replacing the browser's defaults.
///
/// C4 — LINES THE AUTHOR CENTRED BY TYPING SPACES. Modern RTF rendered the typed padding
/// literally, so the row sat off centre AND wrapped early (the padding spends measure).
/// The classifier has identified these rows for a long time and HTML has used its verdict
/// just as long; Modern RTF now strips the padding and centres with `\qc`.
///
/// Both rules run off ONE document-wide classification (`classifyModernBlocks`) — the same
/// call, and therefore the same verdicts, emitHTML makes. Printed RTF is untouched: a
/// facsimile's rows are already where the author put them.
///
/// Port of ctrl-kd's `tests/test_modern_rtf_structure_rows.py`.
@Suite struct ModernRTFStructureRowTests {
    static func doc(_ texts: [String]) -> Document {
        var d = Document()
        d.blocks = [Block(kind: .para,
                          lines: texts.map { Line(spans: [Span(text: $0)]) })]
        return d
    }

    static func liValues(_ out: String) -> [Int] {
        var values: [Int] = []
        var rest = Substring(out)
        while let r = rest.range(of: #"\li"#) {
            let digits = rest[r.upperBound...].prefix(while: { $0.isNumber })
            if let v = Int(digits) { values.append(v) }
            rest = rest[r.upperBound...]
        }
        return Array(Set(values)).sorted()
    }

    // MARK: C3 — hanging rows

    @Test func aDefinitionRowHangsAtTheRuledBodyColumn() {
        // 72pt = 1440 twips: `\li1440` with `\fi-1440`.
        let out = emitRTF(Self.doc(["WS.EXE:  the program itself",
                                    "WSMSGS.OVR:  its message overlay"]), mode: .modern)
        #expect(out.contains(#"\fi-1440 "#) && out.contains(#"\li1440 "#))
    }

    @Test func aDefinitionRowIsRewrittenLabelGapBody() {
        // The author's own column padding goes; a two-space gap replaces it —
        // `modernDefRuns`' rule, and what HTML's <dt>/<dd> already does.
        let out = emitRTF(Self.doc(["WS.EXE:        the program",
                                    "WSMSGS.OVR:    its overlay"]), mode: .modern)
        #expect(out.contains("{WS.EXE:}  {the program}"))
        #expect(!out.contains("WS.EXE:        "))
    }

    @Test func theLadderStepsFourColumnsPerLevel() {
        // Level 1 sits AT the margin; level 2 is 4 print columns (576 twips) past it, on
        // top of the hang.
        let out = emitRTF(Self.doc(["* one", "* two", "    * nested a", "    * nested b"]),
                          mode: .modern)
        let values = Self.liValues(out)
        #expect(values.count >= 2)
        #expect(values[1] - values[0] == 576)
    }

    @Test func aBulletRowHangsByItsOwnMarker() {
        // Not a column count: the marker's own measured advance.
        let out = emitRTF(Self.doc(["* one", "* two"]), mode: .modern)
        let want = roundHalfToEven(stringWidthPt("* ", "Times-Roman", modernBodyPt) * 20.0)
        #expect(out.contains(#"\fi-\#(want) "#) && out.contains(#"\li\#(want) "#))
    }

    @Test func aBulletRowKeepsItsMarker() {
        // The marker is what hangs, so it stays in the text (unlike HTML, which hands the
        // bullet itself to `<ul>`).
        #expect(emitRTF(Self.doc(["* one", "* two"]), mode: .modern).contains("{* one}"))
    }

    @Test func printedRTFIsUntouched() {
        let out = emitRTF(Self.doc(["WS.EXE:  the program",
                                    "WSMSGS.OVR:  its overlay"]), mode: .printed)
        #expect(!out.contains(#"\fi-1440"#))
        #expect(out.contains("WS.EXE:  the program"))
    }

    // MARK: C4 — typed centring

    static let centredRows = [String(repeating: "x", count: 60),
                              String(repeating: "y", count: 60),
                              String(repeating: "z", count: 60),
                              String(repeating: " ", count: 25) + "A Centred Title",
                              String(repeating: "w", count: 60)]

    @Test func aSpacesCentredRowIsCentredAndStripped() {
        let out = emitRTF(Self.doc(Self.centredRows), mode: .modern)
        #expect(out.contains(#"\qc "#))
        #expect(out.contains("{A Centred Title}"))
        #expect(!out.contains("   A Centred Title"))
    }

    @Test func aSpacesCentredRowGetsTheTightLine() {
        // Same "wrapped centered unit" spacing the tag-centred rows already take (b24
        // round 20, slate item 4) — one rule, both paths. R3 (2026-09-14): the value is
        // the EXACT form carrying the row's own tightened leading, so this asserts the
        // shape and the arithmetic rather than a shared constant that no longer exists.
        let doc = Self.doc(Self.centredRows)
        let out = emitRTF(doc, mode: .modern)
        var vals: [Int] = []
        var rest = Substring(out)
        while let r = rest.range(of: #"\sl"#) {
            rest = rest[r.upperBound...]
            let digits = rest.prefix { $0 == "-" || $0.isNumber }
            if rest.dropFirst(digits.count).hasPrefix(#"\slmult0 "#), let v = Int(digits) {
                vals.append(v)
            }
        }
        #expect(vals.contains { $0 < 0 })
        // the centred row, with its own padding stripped — what `\qc` centres
        let line = doc.blocks.flatMap(\.lines)
            .first { $0.spans.map(\.text).joined().contains("A Centred Title") }!
        let raw = Array(line.spans.map(\.text).joined())
        var lead = 0
        while lead < raw.count, raw[lead] == " " { lead += 1 }
        var end = raw.count
        while end > lead, raw[end - 1] == " " { end -= 1 }
        let want = -roundHalfToEven(modernTightLineAdvancePt(
            sliceSpans(line.spans, start: lead, end: end), fonts: doc.fonts) * 20.0)
        #expect(vals.contains(want), "\(want) not in \(vals)")
    }

    @Test func anOrdinaryIndentedParagraphIsNotCentred() {
        // The document's own routine first-line indent is excluded by the classifier
        // (`bodyIndent`), and must stay a paragraph indent.
        let rows = (0..<4).map { _ in "     " + String(repeating: "x", count: 55) }
        #expect(!emitRTF(Self.doc(rows), mode: .modern).contains(#"\qc "#))
    }

    // MARK: the HTML half

    @Test func theStylesheetCarriesTheSameLadder() {
        let out = emitHTML(Self.doc(["* one", "* two"]), mode: .modern)
        #expect(out.contains("ul{margin:0 0 1em;padding-left:0.40in}"))
        #expect(out.contains("dd{margin:0 0 0 1.00in}"))
    }

    @Test func aDocumentWithNoListPaysNoCSSForOne() {
        let out = emitHTML(Self.doc(["just a plain paragraph of prose"]), mode: .modern)
        #expect(!out.contains("dd{margin"))
    }

    @Test func theCSSReadsTheEnginesOwnConstants() {
        let css = listCSS()
        #expect(css.contains("padding-left:0.\(modernLevelStepCols)0in"))
        #expect(css.contains("margin:0 0 0 \(Int(modernDefHangPt / 72.0)).00in"))
    }

    // MARK: the real corpus

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func theStrengthsDocumentCentresItsTitleBylineAndEmail() throws {
        // The packet's worked example: "three rows that have never sat where their author
        // put them". Before, the title carried `\fi3456` and the byline `\fi3312` with a
        // literal 23-space run before the email address.
        let path = sawyerArchivePath + "/STRENGTH.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let out = emitRTF(try parse([UInt8](data)), mode: .modern)
        #expect(out.contains(#"\qc "#))
        #expect(!out.contains(#"\fi3456"#) && !out.contains(#"\fi3312"#))
        #expect(!out.contains("{                       }"))
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func theArchiveReadMesDefinitionRowsHang() throws {
        let path = sawyerArchivePath + "/-README.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let out = emitRTF(try parse([UInt8](data)), mode: .modern)
        #expect(out.contains(#"\fi-1440 "#) && out.contains(#"\li1440 "#))
    }
}
