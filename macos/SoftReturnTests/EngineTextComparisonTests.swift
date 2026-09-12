import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// TWO PDF ALPHABETS ARE NOT TWO PAGES.
///
/// `Oracle.EngineText` is what `theAppPaginatesExactlyLikeTheLibrary` compares its two sides
/// with, and every rule in it exists because a row of that oracle turned out to be the two
/// producers' ENCODINGS disagreeing about a mark both of them put on the paper. Pinned here
/// directly rather than through a rendered document, the same way `AppPDFWordsRiseTests` pins
/// the baseline-snapping rule: each case below names the fixture it came from.
///
/// The half that matters most is the NEGATIVE one — a rule loose enough to hide a real
/// difference is worse than the rows it silences — so every allowance has a paired test that
/// a genuine difference still fails.
@Suite struct EngineTextComparisonTests {

    /// The engine's own `escFallback`: six marks it deliberately writes as something else
    /// when it encodes cp1252. -README.WS and -MAKEDTP.WS between them cover four.
    @Test func theEnginesOwnSubstitutionsAreNotDifferences() {
        #expect(Oracle.EngineText.sameLine(app: "Clarify\u{2219}", library: "Clarify\u{00B7}"))
        #expect(Oracle.EngineText.sameLine(app: "here \u{20A7}, then", library: "here \u{20AC}, then"))
        #expect(Oracle.EngineText.sameLine(app: "\u{2502}10.000\"", library: "|10.000\""))
        #expect(Oracle.EngineText.sameLine(app: "\u{2500}00.250\"", library: "-00.250\""))
    }

    /// And a mark cp1252 has no slot for at all becomes `?`. ASCIITAB.WS page 1.
    @Test func aMarkTheEngineCannotEncodeReadsAsAQuestionMark() {
        #expect(Oracle.EngineText.sameLine(app: "15 \u{263C} \u{25BA}", library: "15 ? ?"))
    }

    /// A REAL `?` IS STILL A `?`. The rule above accepts a library `?` for any non-ASCII
    /// mark; an ASCII one on the app's side has to be matched by an ASCII one on the
    /// library's, or "Is it?" and "Is it." would compare equal.
    @Test func anAsciiQuestionMarkIsNotAWildcard() {
        #expect(!Oracle.EngineText.sameLine(app: "Is it.", library: "Is it?"))
        #expect(Oracle.EngineText.sameLine(app: "Is it?", library: "Is it?"))
    }

    /// One letter, two codepoints: Quartz draws a Greek mu through MacRoman, where 0xB5 is
    /// the MICRO SIGN. NOVEL.WS, nine pages of it.
    @Test func microSignAndGreekMuAreTheSameLetter() {
        #expect(Oracle.EngineText.sameLine(app: "\u{03C7}\u{03BF}\u{00B5}\u{00B5}\u{03B1}\u{03C3}",
                                           library: "\u{03C7}\u{03BF}\u{03BC}\u{03BC}\u{03B1}\u{03C3}"))
        // A DIFFERENT Greek letter is still different.
        #expect(!Oracle.EngineText.sameLine(app: "\u{03BD}", library: "\u{03BC}"))
    }

    /// A graphic character is drawn as GEOMETRY by the engine in body text and as an ASCII
    /// stand-in in a running head, and the line cannot say which — so it may match either,
    /// and only the whole line settles it. LJ6DTP.WS page 6's shadowed banner is where a
    /// greedy reader gets this wrong: the last block matches the library's own final `?`
    /// and leaves the app's real `?` with nothing to pair with.
    @Test func aBlockRunMayVanishOrDegradeAndTheWholeLineDecides() {
        #expect(Oracle.EngineText.sameLine(app: "\u{2588}\u{2588}P\u{2588}R\u{2588}H\u{2588}?",
                                           library: "PRH?"))
        #expect(Oracle.EngineText.sameLine(app: "\u{2591}015%", library: "?015%"))
    }

    /// A DROPPED WORD IS STILL A DROPPED WORD. The graphic-character allowance never lets
    /// ordinary text go missing from either side.
    @Test func realTextCannotGoMissing() {
        #expect(!Oracle.EngineText.sameLine(app: "the final frontier",
                                            library: "the final frontier, these are"))
        #expect(!Oracle.EngineText.sameLine(app: "smallest possible bit of time.",
                                            library: "smallest possible bit of time. And that unit,"))
    }

    /// A dot leader is filled by COUNT on the engine's side and by kerning the author's own
    /// typed characters on the app's — `appendTabRun` records that as a deliberate choice.
    /// MICKEE.WS page 25 is 59 dots against 58; LJ6DTP.WS page 5 is sixteen against
    /// forty-one.
    @Test func aFillRunIsElastic() {
        #expect(Oracle.EngineText.sameLine(app: "Highlights ......... 1",
                                           library: "Highlights ........ 1"))
        #expect(Oracle.EngineText.sameLine(app: "Shading 85%. . . . . . . . . . . . . . . .",
                                           library: "Shading 85%............................."))
    }

    /// AND ONLY A RUN IS. Two of a mark is not a fill run — a real hyphen at a line break
    /// has to stay a real difference — and a repeated LETTER is a word, never a fill.
    @Test func aPairIsNotAFillRunAndNeitherIsAWord() {
        #expect(!Oracle.EngineText.sameLine(app: "civili--", library: "civili-"))
        #expect(!Oracle.EngineText.sameLine(app: "aaaa", library: "aaa"))
    }

    /// macOS's Zapf Dingbats face does not carry the codepoints Unicode gave default emoji
    /// presentation, so the app draws those as a colour IMAGE and its PDF has no text for
    /// them at all. PS.TST's own ZapfDingbats line, four pages of it.
    @Test func aMarkTheAppDrawsAsARasterIsNotMissing() {
        #expect(Oracle.EngineText.sameLine(app: "\u{2724}\u{2749}\u{2747}",
                                           library: "\u{2724}\u{2749}\u{274E}\u{2747}\u{2753}"))
    }

    /// A dingbat the face DOES carry is ordinary text on both sides and still has to match.
    @Test func anOrdinaryDingbatIsNotAWildcard() {
        #expect(!Oracle.EngineText.sameLine(app: "\u{2724}\u{2749}", library: "\u{2724}\u{273A}\u{2749}"))
    }

    /// A mark the READER could not name — an Identity-H glyph id in a CJK-fallback subset
    /// with no `/ToUnicode`, which `AppPDFWordsFont` now reports as U+FFFD rather than
    /// inventing a scalar from the glyph id. FONTS.REF page 10's PC-Line specimen row is
    /// typed in cp437 box drawing that no Latin face carries.
    @Test func aMarkTheReaderCannotNameIsNotEvidence() {
        #expect(Oracle.EngineText.sameLine(app: "\u{FFFD}\u{FFFD}\u{FFFD} Scalable",
                                           library: "Scalable"))
    }

    /// A line that is nothing but marks the engine draws as geometry belongs to neither side.
    @Test func anAllGeometryLineIsNobodys() {
        #expect(Oracle.EngineText.isAllGeometry("\u{2550}\u{2550}\u{2550}\u{2550}"))
        #expect(Oracle.EngineText.isAllGeometry("   "))
        #expect(!Oracle.EngineText.isAllGeometry("\u{2550}\u{2550} Chapter One"))
    }
}
