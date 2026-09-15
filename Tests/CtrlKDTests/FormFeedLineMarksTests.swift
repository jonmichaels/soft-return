import Foundation
import Testing
@testable import CtrlKD

/// A form feed on a physical line no longer throws that line's marks away (planning #270,
/// triage round 2026-09-14, item 2 — the real answer to Q8). sr half of ctrl-kd's
/// `tests/test_form_feed_line_marks.py`.
///
/// Q8 asked which of a font block's "two records" governs the text after it. There are no
/// two records: WSFORMAT.TXT's type-2 Font is six words — the CURRENT width/height/
/// typestyle and then the PREVIOUS three, which is why the CLOSING block of a pair carries
/// the same pair reversed. Both engines have always read the first three.
///
/// What was actually wrong is one level up. `sawyer/PRINT.TST`'s "Paragraph Indentation"
/// heading is `.cb` + a bare form feed + `^B` + its own font block (Helv 11pt, HMI 138),
/// and `linesPass`'s form-feed branch decoded the pieces with NO marks at all — so the
/// font block never reached the text and the heading was measured in the Courier carried
/// over from the previous line. Real WS7 sets it in Helv: 54.4pt for "Paragraph " on the
/// v4 PRISTINE capture, page 2 y=288.0pt.
///
/// Type 15h (Alternate/Normal font change) is the same family: WSFORMAT gives it a state
/// flag before the font triples, and both engines read the flag bytes as a width.
///
/// Fixtures are built with sequential `+=`, never a chained `+` expression (planning
/// #253: the macOS type-checker abandons those).
@Suite struct FormFeedLineMarksTests {

    static let FF: [UInt8] = [0x0C]

    static func ws7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
        let count = UInt16(content.count + 4)
        let lo = UInt8(count & 0xFF), hi = UInt8(count >> 8)
        var out: [UInt8] = [0x1D, lo, hi, cmd]
        out += content
        out += [lo, hi, 0x1D]
        return out
    }

    static func word(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// The six little-endian words of a type-2 Font block: the CURRENT width (HMI),
    /// height (VMI) and typestyle, then the PREVIOUS three — here the Courier 12 every
    /// block in the corpus restores to.
    static func fontBlock(_ w: Int, _ h: Int, _ style: Int) -> [UInt8] {
        var payload = word(w)
        payload += word(h)
        payload += word(style)
        payload += word(180)
        payload += word(240)
        payload += word(17411)
        return ws7Block(0x02, payload)
    }

    /// Type 15h: "Byte: Normal = 0, Alternate = 1", paired new-then-previous exactly as
    /// the font triples that follow it are.
    static func altFontBlock(_ w: Int, _ h: Int, _ style: Int) -> [UInt8] {
        var payload: [UInt8] = [1, 0]
        payload += word(w)
        payload += word(h)
        payload += word(style)
        payload += word(180)
        payload += word(240)
        payload += word(17411)
        return ws7Block(0x15, payload)
    }

    static let helv11 = (138, 220, 49156)          // PRINT.TST's own heading font
    static let linePrinter = (108, 170, 16384)     // CODES.WS's own 15h font

    static func build(_ body: [UInt8]) -> Document {
        var src = ws7Block(0x00)
        src += body
        return parseWS(src)
    }

    static func fontOf(_ doc: Document, _ text: String) -> FontChange? {
        for b in doc.blocks {
            for line in b.lines {
                for s in line.spans where s.text == text {
                    if let i = s.font { return doc.fonts[i] }
                }
            }
        }
        return nil
    }

    @Test func aFontBlockAfterAFormFeedReachesTheText() {
        var body = bytes("Body")
        body += HARD
        body += Self.FF
        body += Self.fontBlock(Self.helv11.0, Self.helv11.1, Self.helv11.2)
        body += bytes("Heading")
        body += HARD
        let f = Self.fontOf(Self.build(body), "Heading")
        #expect(f?.points == 11.0)
        #expect(f?.proportional == true)
    }

    @Test func aMarkBeforeTheFormFeedStaysOnItsOwnPiece() {
        // The bounds partition the line: a mark reaches one piece and one only, and the
        // form-feed byte itself belongs to the piece before it.
        var body = Self.fontBlock(Self.helv11.0, Self.helv11.1, Self.helv11.2)
        body += bytes("First")
        body += Self.FF
        body += bytes("Second")
        body += HARD
        let doc = Self.build(body)
        #expect(Self.fontOf(doc, "First")?.points == 11.0)
        #expect(Self.fontOf(doc, "Second")?.points == 11.0)   // modal: still in force
    }

    @Test func aTabTargetOnAFormFeedLineSurvives() {
        var payload = Self.word(0)
        payload += Self.word(900)
        payload += [0x20, 0x00]
        var body = bytes("Body")
        body += HARD
        body += Self.FF
        body += Self.ws7Block(0x09, payload)
        body += bytes("     Space:")
        body += HARD
        let doc = Self.build(body)
        let tabbed = doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }
            .filter { $0.tabHMI != nil }
        #expect(tabbed.first?.tabHMI == 900)
    }

    @Test func aNoteReferenceOnAFormFeedLineSurvives() {
        var payload = [UInt8](repeating: 0, count: 8)
        payload += bytes("the note")
        var body = bytes("Body")
        body += HARD
        body += Self.FF
        body += bytes("Tail")
        body += Self.ws7Block(0x03, payload)
        body += HARD
        let marks = Self.build(body).blocks.flatMap { $0.lines }.flatMap { $0.spans }
            .filter { $0.styles.contains(.fnref) }.map(\.text)
        #expect(marks == ["1"])
    }

    @Test func anAlternateFontBlockReadsPastItsTwoStateBytes() {
        var body = bytes("Body")
        body += Self.altFontBlock(Self.linePrinter.0, Self.linePrinter.1,
                                  Self.linePrinter.2)
        body += bytes("Alt")
        body += HARD
        let f = Self.fontOf(Self.build(body), "Alt")
        #expect(f?.width1800 == 108)
        #expect(f?.height1440 == 170)
        #expect(f?.points == 8.5)
    }

    // MARK: the measured documents

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
          arguments: ["PRINT.TST", "DEFAULT/PRINT.TST"])
    func printTSTSetsItsHeadingInHelvLikeWS7(_ rel: String) throws {
        let path = sawyerArchivePath + "/" + rel
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = parseWS([UInt8](data))
        let heading = doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }
            .first { $0.text.contains("Paragraph Indenta") }
        let idx = try #require(heading?.font)
        #expect(doc.fonts[idx].points == 11.0)
        #expect(doc.fonts[idx].proportional == true)
        // and with the heading measured in its real face, `.pf on` joins it to one line,
        // as WS7 prints it
        let lines = docToPagelines(doc, printed: true)
            .flatMap { $0.map { $0.map(\.text).joined() } }
        #expect(lines.contains { $0.contains("Paragraph Indentation") })
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func noFontBlockInPrintTSTIsLeftUnapplied() throws {
        // `fonts[0]` is the document's own header default and carries no mark of its
        // own, so it is the one entry legitimately never tagged.
        let path = sawyerArchivePath + "/PRINT.TST"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = parseWS([UInt8](data))
        let used = Set(doc.blocks.flatMap { $0.lines }.flatMap { $0.spans }
                        .compactMap(\.font))
        #expect(Set(1..<doc.fonts.count).subtracting(used).isEmpty)
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
          arguments: [("REF/CODES.WS", [[108, 170], [180, 240]]),
                      ("REF/-TOC-TAG.WS", [[180, 240], [108, 170], [180, 210], [180, 240]])])
    func theTwoArchiveDocumentsWith15hBlocksReadRealFonts(
        _ rel: String, _ expected: [[Int]]
    ) throws {
        let path = sawyerArchivePath + "/" + rel
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let doc = parseWS([UInt8](data))
        #expect(doc.fonts.map { [$0.width1800, $0.height1440] } == expected)
    }
}
