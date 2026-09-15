import Foundation
import Testing
@testable import CtrlKD

/// planning #264 item 1 (packet rows B1+B2): the driver's character substitutions and
/// the driver-keyed euro reach RTF, HTML, Markdown and plain text.
///
/// THE DEFECT, measured 2026-09-12 on the real corpus. Jon ruled the LJ6DTP driver's
/// character substitutions CONTENT on 2026-08-06 (M7: "an em dash is an em dash in any
/// century") and the cp437-158 euro driver-keyed on 2026-09-11 ("anyone using Sawyer's
/// trick gets the Euro"). Both rules reached the PDF views and NOTHING else: Printed RTF,
/// Modern RTF, both HTML modes and the text export of the corpus's LJ6DTP document all
/// kept 7 smiley faces where a © belongs, 4 suns where an ellipsis belongs, 11 `«` and 11
/// `»` where curly double quotes belong, 4 `≡` where an en dash belongs and the four card
/// suits where the box corners belong — zero copyright signs, zero curly double quotes,
/// zero em dashes in any of the four. The archive read-me, which declares one of the three
/// patched drivers, emitted a peseta where the euro belongs in every one of them.
///
/// THE FIX. `driverSubstituted` applies both rules ONCE, to the Document, at each
/// emitter's entry — so every later pass (paragraph assembly, structure classification,
/// sentence spacing) sees the characters the document actually printed.
///
/// WHICH TABLE. Deliberately the SEMANTIC flow's own (`ljSubstituteText`, which already
/// carries `ljSubstUniversSemantic`'s square box corners for exactly this reason), not the
/// Printed PDF's `ljSubstitute`: every mapping here is one character for one character, so
/// a facsimile keeps its columns.
///
/// FACE RULES, from the document's own chart and unchanged: only spans in a PROPORTIONAL
/// face are substituted (a fixed-pitch face was never patched — which is why that
/// document's own substitution chart, typed in Courier, still shows the raw characters
/// beside their printed forms), and the box corners only in Univers. The euro is keyed on
/// the driver name alone and applies to every span.
///
/// Port of ctrl-kd's `tests/test_driver_substitutions_exports.py`.
@Suite struct DriverSubstitutionExportTests {
    /// `typestyle`'s own documented bit fields: 0x8000 is PROPORTIONAL, the low nine
    /// bits are the spec's typestyle NUMBER (`typestyleNames`) — 46 "Univers (also
    /// Zurich)", 31 "Times", 3 "Courier".
    static let univers = FontChange(offset: 0, width1800: 0, height1440: 280,
                                    typestyle: 0x8000 | 46)
    static let times = FontChange(offset: 0, width1800: 0, height1440: 280,
                                  typestyle: 0x8000 | 31)
    static let courier = FontChange(offset: 0, width1800: 180, height1440: 240,
                                    typestyle: 3)

    static let fonts = [times, univers, courier]
    static let prop = 0, uni = 1, fixed = 2

    static let sample = "\u{263B} \u{263C} \u{00AB}x\u{00BB} \u{2261} "
        + "\u{2665}\u{2666}\u{2663}\u{2660} don't _ \u{20A7}"
    static let substituted = "\u{00A9} \u{2026} \u{201C}x\u{201D} \u{2013} "
        + "\u{250C}\u{2510}\u{2514}\u{2518} don\u{2019}t \u{2014} \u{20AC}"

    /// A Document declaring `driver` as its last-used printer, with one block whose single
    /// line carries `text` in the font at `fontIndex`.
    static func doc(_ driver: String?, _ text: String, font fontIndex: Int?) -> Document {
        var d = Document()
        d.printerDriver = driver
        d.fonts = fonts
        d.blocks = [Block(kind: .para,
                          lines: [Line(spans: [Span(text: text, font: fontIndex)])])]
        return d
    }

    /// Every export surface this item covers.
    static func exports(_ d: Document) -> [String: String] {
        [
            "rtf.printed": emitRTF(d, mode: .printed),
            "rtf.modern": emitRTF(d, mode: .modern),
            "html.printed": emitHTML(d, mode: .printed),
            "html.modern": emitHTML(d, mode: .modern),
            "text.printed": emitText(d, mode: .printed),
            "text.modern": emitText(d, mode: .modern),
            "markdown.printed": emitMarkdown(d, mode: .printed),
            "markdown.modern": emitMarkdown(d, mode: .modern),
        ]
    }

    /// RTF escapes every non-ASCII character as `\uNNNN?`.
    static func shows(_ name: String, _ out: String, _ ch: Character) -> Bool {
        guard name.hasPrefix("rtf") else { return out.contains(ch) }
        let scalar = ch.unicodeScalars.first!.value
        return out.contains("\\u\(scalar)?")
    }

    // MARK: the substitutions arrive

    @Test func everyExportCarriesTheSubstitutedCharacters() {
        let out = Self.exports(Self.doc("LJ6DTP", Self.sample, font: Self.uni))
        for ch in "\u{00A9}\u{2026}\u{201C}\u{201D}\u{2013}\u{250C}\u{2510}\u{2514}\u{2518}\u{2014}\u{2019}" {
            for (name, text) in out {
                #expect(Self.shows(name, text, ch), "\(name) lost \(ch)")
            }
        }
    }

    @Test func noExportStillShowsTheRawTypedCharacter() {
        let out = Self.exports(Self.doc("LJ6DTP", Self.sample, font: Self.uni))
        for ch in "\u{263B}\u{263C}\u{00AB}\u{00BB}\u{2261}\u{2665}\u{2666}\u{2663}\u{2660}" {
            for (name, text) in out {
                #expect(!Self.shows(name, text, ch), "\(name) kept raw \(ch)")
            }
        }
    }

    @Test func theSubstituterIsTheSemanticFlowsOwnTable() throws {
        let subst = try #require(driverSubstituter(Self.doc("LJ6DTP", "", font: nil)))
        #expect(subst(Self.sample, Self.uni) == Self.substituted)
    }

    // MARK: face rules

    @Test func aFixedPitchFaceIsNeverSubstituted() {
        // The corpus document's own substitution CHART is typed in Courier: it shows the
        // raw character beside its printed form, and must keep doing so.
        let out = Self.exports(Self.doc("LJ6DTP", Self.sample, font: Self.fixed))
        for (name, text) in out {
            #expect(Self.shows(name, text, "\u{263B}"), "\(name) substituted fixed pitch")
            #expect(!Self.shows(name, text, "\u{00A9}"), "\(name) substituted fixed pitch")
        }
    }

    @Test func boxCornersAreUniversOnly() {
        let out = Self.exports(Self.doc("LJ6DTP", Self.sample, font: Self.prop))
        for (name, text) in out {
            #expect(Self.shows(name, text, "\u{00A9}"), "\(name): Times run not substituted")
            #expect(Self.shows(name, text, "\u{2665}"), "\(name): corners outside Univers")
            #expect(!Self.shows(name, text, "\u{250C}"), "\(name): corners outside Univers")
        }
    }

    @Test func anotherDriverSubstitutesNothing() {
        let out = Self.exports(Self.doc("EPSONFX", Self.sample, font: Self.uni))
        for (name, text) in out {
            #expect(Self.shows(name, text, "\u{263B}"), "\(name) substituted a non-LJ6DTP doc")
            #expect(!Self.shows(name, text, "\u{00A9}"), "\(name) substituted a non-LJ6DTP doc")
        }
    }

    // MARK: the euro (B2 / planning #266)

    @Test(arguments: ["LASERJET", "LJ6DTP", "HP4"])
    func aPatchedDriverPrintsTheEuroInEveryExport(driver: String) {
        let out = Self.exports(Self.doc(driver, "Costs \u{20A7} 100", font: Self.fixed))
        for (name, text) in out {
            #expect(Self.shows(name, text, "\u{20AC}"), "\(name) kept the peseta")
            #expect(!Self.shows(name, text, "\u{20A7}"), "\(name) kept the peseta")
        }
    }

    @Test func anUnpatchedDriverKeepsThePesetaInEveryExport() {
        // Jon's ruling: "Any other old docs which actually use a Peseta in them, see it
        // as intended."
        let out = Self.exports(Self.doc("EPSONFX", "Costs \u{20A7} 100", font: Self.fixed))
        for (name, text) in out {
            #expect(Self.shows(name, text, "\u{20A7}"), "\(name) lost the peseta")
            #expect(!Self.shows(name, text, "\u{20AC}"), "\(name) invented a euro")
        }
    }

    @Test func theEuroAppliesToAFixedPitchRunToo() throws {
        // The euro is keyed on the DRIVER, never on the face — unlike the chart above.
        let subst = try #require(driverSubstituter(Self.doc("HP4", "", font: nil)))
        #expect(subst("\u{20A7}", Self.fixed) == "\u{20AC}")
    }

    // MARK: hygiene

    @Test func aDocumentWithNoPatchedDriverIsNotTouched() {
        let d = Self.doc("EPSONFX", "plain text", font: Self.prop)
        #expect(driverSubstituter(d) == nil)
        #expect(driverSubstituted(d).blocks == d.blocks)
    }

    @Test func aMarkerSpanKeepsItsOwnText() {
        // `_` -> em dash would rewrite a real file name: a pix/pcl/pctl span's text is a
        // MARKER, not prose, and is exempt — as is an `fnref` label.
        #expect(substExempt(Span(text: "[image: MY_FIG.PIX]", font: 0, pix: 3)))
        #expect(substExempt(Span(text: "1", styles: [.fnref])))
        #expect(!substExempt(Span(text: "ordinary", styles: [.bold], font: 0)))
    }

    // MARK: the real corpus

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func theArchivesLJ6DTPExportsCarryTheSubstitutions() throws {
        let path = sawyerArchivePath + "/LJ6DTP.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let d = try parse([UInt8](data))
        for (name, out) in Self.exports(d) {
            for ch in "\u{00A9}\u{201C}\u{201D}\u{2014}\u{2026}\u{2013}" {
                #expect(Self.shows(name, out, ch), "\(name): no \(ch)")
            }
        }
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func theArchiveReadMeExportsCarryTheEuro() throws {
        let path = sawyerArchivePath + "/-README.WS"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MissingSawyerFixture(path: path)
        }
        let d = try parse([UInt8](data))
        for (name, out) in Self.exports(d) {
            #expect(Self.shows(name, out, "\u{20AC}"), "\(name): no euro")
            #expect(!Self.shows(name, out, "\u{20A7}"), "\(name): still a peseta")
        }
    }
}
