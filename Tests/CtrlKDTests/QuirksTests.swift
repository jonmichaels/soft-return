import Foundation
import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

/// QUIRKS: named, individually switchable departures from a literal reading, Swift side.
/// Byte-for-byte the same behaviour ctrl-kd's `tests/test_quirks.py` pins, built from the
/// same synthetic fixtures. No corpus file is read here.
///
/// Jon's ruling, 2026-09-16: "Our engine needs to be faithful. We can't be arbitrarily
/// cleaning up 'mistakes' since there are plenty of reasons that someone might want things
/// a certain way. However, this is a mistake. ... So is there a way we can go into a
/// 'quirks' mode to fix this? Maybe a new flag and specific cases can be added to it. We
/// already have a way for users to extend ctrl-kd with new outputs. Maybe something similar
/// can exist."
///
/// TWO CLASSES, and this file pins the difference:
///
///   auto     the document's own bytes point at it -- its WS7 header names the printer
///            driver it was last printed through, and three of those drivers were patched
///            so certain characters PRINT as something else. On by default (that IS what
///            the paper showed), switchable off.
///   opt-in   a person judged it from context, with nothing in the file to say so. Off by
///            default. Today there is exactly one: the stray style-library strikeout bit
///            (register entry 2026-09-16, "Style-library strikeout runs until a style
///            clears it" -- the faithful default keeps the strike; this quirk is how a
///            reader gets the document without it).
///
/// THE ONE THING THIS QUIRK MUST NOT DO is take away a cross-out somebody meant. `detect`
/// is what guarantees that: it fires only when NO span anywhere in the document carries a
/// strikeout the typist toggled inline (WordStar's `^PX`, byte 0x18).
@Suite struct QuirksTests {

    // MARK: fixtures

    static let HARDRET: [UInt8] = [0x0D, 0x0A]
    static let STRIKE_BIT = 0x01
    static let BOLD_BIT = 0x40
    static let CLEARS_ALL_BUT_STRIKE = 0xFA
    static let PESETA = "\u{20A7}"

    static let STRUCK_TEXT = "A heading whose style turns strikeout on."
    static let AFTER_TEXT = "The paragraph that inherits the run, because nothing clears it."

    static func library() -> [UInt8] {
        styleLibrary([
            (name: "Editing Defaults",
             record: styleRecord(inheritTabs: true,
                                 attrsOn: STRIKE_BIT | BOLD_BIT,
                                 attrsOff: CLEARS_ALL_BUT_STRIKE & ~BOLD_BIT)),
        ])
    }

    /// A style turns strikeout on; the writing never types a cross-out.
    static func strayStrikeDoc() -> Document {
        var body = styleRef(0)
        body += bytes(STRUCK_TEXT)
        body += HARDRET + HARDRET
        body += bytes(AFTER_TEXT)
        body += HARDRET
        return parseWS(documentWithStyleLibrary(body: body, library: library()))
    }

    /// The SAME style-declared strike, but the writer ALSO typed a real inline cross-out
    /// (`^PX`, byte 0x18) -- the case that must be left completely alone even with the
    /// quirk on.
    static func typedStrikeDoc() -> Document {
        var body = styleRef(0)
        body += bytes(STRUCK_TEXT)
        body += HARDRET + HARDRET
        body += bytes("Struck on purpose: ") + [0x18]
        body += bytes("deleted words") + [0x18]
        body += bytes(" and on we go.")
        body += HARDRET
        return parseWS(documentWithStyleLibrary(body: body, library: library()))
    }

    /// No style strike, no driver -- trips nothing at all.
    static func plainDoc() -> Document {
        var body = styleRef(0)
        body += bytes("Nothing here trips any quirk.")
        body += HARDRET
        return parseWS(documentWithStyleLibrary(
            body: body,
            library: styleLibrary([(name: "Plain",
                                    record: styleRecord(inheritTabs: true))])))
    }

    /// A document declaring `driver` as its last-used printer.
    static func driverDoc(_ driver: String, text: String = "text") -> Document {
        var d = Document()
        d.printerDriver = driver
        d.blocks = [Block(kind: .para, lines: [Line(spans: [Span(text: text)])])]
        return d
    }

    static func blockFor(_ doc: Document, _ text: String) -> Block {
        let wanted = String(text.prefix(20))
        guard let block = doc.blocks.first(where: {
            $0.lines.map { $0.text() }.joined().contains(wanted)
        }) else {
            Issue.record("no block carrying \(wanted)")
            return doc.blocks[0]
        }
        return block
    }

    // MARK: registry mechanics

    /// A quirk with no plain-language description, or no class, or no detect, cannot be
    /// offered to a reader at all -- an app draws a checkbox from exactly these fields.
    @Test func everyRegisteredQuirkStatesAllFiveThings() {
        for name in QuirkRegistry.standard.names() {
            let q = QuirkRegistry.standard.quirk(name)
            #expect(q != nil, "\(name)")
            guard let q else { continue }
            #expect(q.name == name)
            #expect(q.name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }, "\(name)")
            // Jon's wording, 2026-09-16: a description is a short LABEL for a
            // checkbox, not a sentence — capitalised, no closing period. The
            // strings themselves are Jon's, verbatim; this only pins their shape.
            #expect(!q.description.isEmpty && !q.description.hasSuffix("."), "\(name)")
            #expect(q.description.first?.isUppercase == true, "\(name)")
        }
    }

    /// Plain-language reporting: the description is shown to a user as-is, so it may not
    /// lean on this project's own internal vocabulary.
    @Test func descriptionsCarryNoCodenames() {
        let banned = ["register", "planning #", "attrs_on", "0x01", "quirk", "emitter",
                      "span", "cp437"]
        for name in QuirkRegistry.standard.names() {
            let low = QuirkRegistry.standard.quirk(name)?.description.lowercased() ?? ""
            for word in banned {
                #expect(!low.contains(word), "\(name): \(word)")
            }
        }
    }

    /// The two engines ship the SAME six names, in the SAME order -- an app stores these
    /// as per-document settings and must get the same answer from either side.
    @Test func theSixNamesAreTheOnesCtrlKDShips() {
        #expect(QuirkRegistry.standard.names() == [
            "driver-euro-sign", "lj6dtp-typography", "lj6dtp-box-corners",
            "lj6dtp-colour-as-gray", "lj6dtp-fill-patterns", "stray-style-strikeout",
        ])
    }

    @Test func registeringTheSameNameReplacesItInPlace() {
        let replaced = QuirkRegistry.standard.register(
            Quirk(name: "stray-style-strikeout", description: "Replaced.",
                  quirkClass: .optIn, detect: { _ in nil }))
        #expect(replaced.quirk("stray-style-strikeout")?.description == "Replaced.")
        #expect(replaced.names() == QuirkRegistry.standard.names())
        // Value semantics: the shared `.standard` is untouched by anybody's registration.
        #expect(QuirkRegistry.standard.quirk("stray-style-strikeout")?.description != "Replaced.")
    }

    @Test func aNameThisBuildDoesNotKnowIsAnErrorNotAShrug() {
        #expect(throws: QuirkError.unknownQuirk(
            name: "no-such-quirk", known: QuirkRegistry.standard.names())) {
            _ = try QuirkRegistry.standard.applyQuirks(to: Self.plainDoc(),
                                                       enable: ["no-such-quirk"])
        }
    }

    /// A caller (an app's own settings list) holds one standing set of quirks and hands it
    /// to every document; a document that trips none of them must convert exactly as it
    /// would with no flags at all.
    @Test func namingAQuirkThisDocumentDoesNotTripIsANoOp() throws {
        let plain = emitRTF(try QuirkRegistry.standard.applyQuirks(to: Self.plainDoc()),
                            mode: .modern)
        let asked = emitRTF(try QuirkRegistry.standard.applyQuirks(
            to: Self.plainDoc(), enable: ["stray-style-strikeout", "driver-euro-sign"]),
                            mode: .modern)
        #expect(plain == asked)
    }

    /// The compatibility promise: every emitter still works on a bare parsed document and
    /// resolves the same decision `applyQuirks` would.
    @Test func aCallerThatNeverMentionsQuirksGetsTheDefaults() throws {
        let doc = Self.strayStrikeDoc()
        #expect(quirkEnabled(doc, "stray-style-strikeout") == false)
        #expect(emitRTF(doc, mode: .modern)
                == emitRTF(try QuirkRegistry.standard.applyQuirks(to: doc), mode: .modern))
    }

    // MARK: what each class does by default

    @Test func autoQuirksAreOnAndOptInOnesAreOff() throws {
        let doc = try QuirkRegistry.standard.applyQuirks(to: Self.driverDoc("LJ6DTP"))
        let decision = quirkDecision(doc)
        #expect(decision.applicableNames == ["driver-euro-sign", "lj6dtp-typography",
                                             "lj6dtp-box-corners", "lj6dtp-colour-as-gray",
                                             "lj6dtp-fill-patterns"])
        #expect(decision.applied == decision.applicableNames)

        let struck = try QuirkRegistry.standard.applyQuirks(to: Self.strayStrikeDoc())
        #expect(quirkDecision(struck).applicableNames == ["stray-style-strikeout"])
        #expect(quirkDecision(struck).applied.isEmpty)
    }

    @Test func everyAutoQuirkStatesTheDocumentsOwnEvidenceAsItsReason() {
        for row in QuirkRegistry.standard.applicable(to: Self.driverDoc("LJ6DTP")) {
            #expect(row.reason.hasPrefix("last printed on"), "\(row.name)")
            #expect(row.reason.contains("LJ6DTP"), "\(row.name)")
        }
    }

    /// `--quirks off` is the most literal reading of the bytes this converter can give:
    /// the peseta stays a peseta even on a patched-driver document.
    @Test func quirksOffTurnsOffEvenTheAutomaticOnes() throws {
        let src = Self.driverDoc("LASERJET", text: "Costs \(Self.PESETA) 100.")
        let on = emitText(try QuirkRegistry.standard.applyQuirks(to: src), mode: .modern)
        let off = emitText(try QuirkRegistry.standard.applyQuirks(to: src, mode: .off),
                           mode: .modern)
        #expect(on.contains("\u{20AC}") && !on.contains(Self.PESETA))
        #expect(off.contains(Self.PESETA) && !off.contains("\u{20AC}"))
    }

    @Test func quirksAllTurnsOnTheOptInOneToo() throws {
        let doc = try QuirkRegistry.standard.applyQuirks(to: Self.strayStrikeDoc(), mode: .all)
        #expect(quirkDecision(doc).applied == ["stray-style-strikeout"])
    }

    @Test(arguments: ["driver-euro-sign", "lj6dtp-typography", "lj6dtp-box-corners",
                      "lj6dtp-colour-as-gray", "lj6dtp-fill-patterns"])
    func noQuirkSwitchesOneAutomaticQuirkOffAndLeavesItsSiblings(_ name: String) throws {
        let doc = try QuirkRegistry.standard.applyQuirks(to: Self.driverDoc("LJ6DTP"),
                                                         disable: [name])
        let applied = quirkDecision(doc).applied
        #expect(!applied.contains(name))
        #expect(applied.count == 4)
    }

    @Test func switchingTheEuroOffShowsThePesetaTheBytesActuallyCarry() throws {
        let src = Self.driverDoc("LASERJET", text: "Costs \(Self.PESETA) 100.")
        let off = emitText(try QuirkRegistry.standard.applyQuirks(
            to: src, disable: ["driver-euro-sign"]), mode: .modern)
        #expect(off.contains(Self.PESETA) && !off.contains("\u{20AC}"))
    }

    /// The driver prints `_` as an em dash and the card suits as box corners. Those are two
    /// separate quirks, so each has to be able to go without the other -- which is why
    /// `ljSubstitute` takes them as two flags rather than one "is this the LJ6DTP driver"
    /// gate.
    @Test func theTwoLJ6DTPCharacterFamiliesSwitchIndependently() {
        let univers = FontChange(offset: 0, width1800: 0, height1440: 280,
                                 typestyle: 0x8000 | 46)
        let seg = LineSegment(text: "a_b \u{2665}", styles: [], family: .times,
                              size: 12, entry: univers, indent: false)
        func sub(_ typography: Bool, _ corners: Bool) -> String {
            ljSubstitute([seg], kerning: true, typography: typography, corners: corners)[0].text
        }
        // The PRINTED table's corners are the Unicode ARC glyphs (`arcCorners`, register
        // C7 -- real WS7 draws a quarter-circle join, not a square one); the semantic
        // flow's own table uses the plain box corners instead.
        #expect(sub(true, true) == "a\u{2014}b \u{256D}")
        #expect(sub(true, false) == "a\u{2014}b \u{2665}")
        #expect(sub(false, true) == "a_b \u{256D}")
        #expect(sub(false, false) == "a_b \u{2665}")
    }

    /// `driverSubstituter` returns nil -- no pass, nothing copied -- once nothing is left
    /// for it to do.
    @Test func theSemanticSubstitutionPassDisappearsWhenBothAreOff() throws {
        let doc = Self.driverDoc("LJ6DTP", text: "a_b")
        #expect(driverSubstituter(try QuirkRegistry.standard.applyQuirks(to: doc)) != nil)
        let allOff = try QuirkRegistry.standard.applyQuirks(
            to: doc, disable: ["lj6dtp-typography", "lj6dtp-box-corners", "driver-euro-sign"])
        #expect(driverSubstituter(allOff) == nil)
    }

    // MARK: the stray style-strikeout quirk

    @Test func itAppliesWhenAStyleStrikesAndTheWriterNeverDid() {
        let rows = QuirkRegistry.standard.applicable(to: Self.strayStrikeDoc())
        let stray = rows.first { $0.name == "stray-style-strikeout" }
        #expect(stray != nil)
        #expect(stray?.reason.contains("'Editing Defaults'") == true)
    }

    /// The case this quirk must never touch. A document that types `^PX` has made a
    /// deliberate cross-out; the style's own bit can no longer be read as an accident, so
    /// the quirk is not offered at all.
    @Test func itDoesNotApplyWhenTheWriterTypedARealCrossOut() {
        let names = QuirkRegistry.standard.applicable(to: Self.typedStrikeDoc()).map(\.name)
        #expect(!names.contains("stray-style-strikeout"))
    }

    @Test func applyingItDropsTheStrikeAndKeepsEveryOtherAttribute() throws {
        let doc = try QuirkRegistry.standard.applyQuirks(
            to: Self.strayStrikeDoc(), enable: ["stray-style-strikeout"])
        for text in [Self.STRUCK_TEXT, Self.AFTER_TEXT] {
            #expect(!Self.blockFor(doc, text).styleAttrs.contains(.strike), "\(text)")
        }
        #expect(Self.blockFor(doc, Self.STRUCK_TEXT).styleAttrs.contains(.bold),
                "the style declared bold as well and the quirk took it away")
    }

    @Test(arguments: [EmitMode.printed, .modern])
    func theStrikeDisappearsFromEveryFormatThatCanShowOne(_ mode: EmitMode) throws {
        let faithful = Self.strayStrikeDoc()
        let quirked = try QuirkRegistry.standard.applyQuirks(
            to: faithful, enable: ["stray-style-strikeout"])

        #expect(!emitRTF(quirked, mode: mode).contains("\\strike"))
        #expect(!emitHTML(quirked, mode: mode).contains("line-through"))
        #expect(!emitMarkdown(quirked, mode: .modern).contains("~~"))

        // Strikeout in PDF is a stroked rule over the run (`... m ... l S`).
        let on = Self.countStrokes(emitPDF(faithful, mode: mode))
        let off = Self.countStrokes(emitPDF(quirked, mode: mode))
        #expect(off < on, "\(mode): the PDF still strokes as many rules as the faithful render")
    }

    /// Strikeout in PDF is a stroked rule over the run. Both renders are produced with
    /// the SAME writer, so counting the ` l S` operator in the raw (uncompressed-by-this-
    /// writer) content streams compares like with like.
    static func countStrokes(_ pdf: [UInt8]) -> Int {
        pdfContentStreams(pdf).reduce(0) { total, stream in
            total + String(decoding: stream, as: UTF8.self)
                .components(separatedBy: " l S").count - 1
        }
    }

    /// Plain text has no way to show a strikeout in either direction, so this quirk changes
    /// nothing there -- named rather than left out of the list.
    @Test func plainTextIsUnaffectedAndStillCarriesTheWords() throws {
        let quirked = try QuirkRegistry.standard.applyQuirks(
            to: Self.strayStrikeDoc(), enable: ["stray-style-strikeout"])
        let body = emitText(quirked, mode: .printed)
        for sample in [Self.STRUCK_TEXT, Self.AFTER_TEXT] {
            #expect(body.contains(String(sample.prefix(20))))
        }
    }

    /// Asking for the quirk on a document `detect` did not flag is a no-op, not an override.
    @Test func aDocumentThatTypesItsOwnCrossOutIsUntouchedEvenWhenAsked() throws {
        let doc = Self.typedStrikeDoc()
        let asked = try QuirkRegistry.standard.applyQuirks(
            to: doc, enable: ["stray-style-strikeout"])
        #expect(emitRTF(asked, mode: .modern) == emitRTF(doc, mode: .modern))
    }

    // MARK: the layout JSON's report

    static func layoutJSON(_ doc: Document, _ mode: EmitMode = .modern) -> [String: Any] {
        let data = Data(emitLayout(doc, mode: mode).utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Omitted, not empty -- the same convention every other additive layout field uses, so
    /// a document with no quirk available emits byte-identical JSON to version 11.
    @Test func aDocumentThatTripsNothingSaysNothing() throws {
        let json = Self.layoutJSON(try QuirkRegistry.standard.applyQuirks(to: Self.plainDoc()))
        #expect(json["version"] as? Int == 12)
        #expect(json["quirks_applicable"] == nil)
        #expect(json["quirks_applied"] == nil)
    }

    /// The whole point: a reader must be able to be OFFERED the quirk without having had to
    /// turn it on to find out it exists.
    @Test func applicableIsReportedEvenOnAPlainFaithfulRun() throws {
        let json = Self.layoutJSON(
            try QuirkRegistry.standard.applyQuirks(to: Self.strayStrikeDoc()))
        #expect(json["quirks_applicable"] as? [String] == ["stray-style-strikeout"])
        #expect((json["quirks_applied"] as? [String])?.isEmpty == true)
    }

    @Test func appliedNamesTheSubsetActuallyInForce() throws {
        let json = Self.layoutJSON(try QuirkRegistry.standard.applyQuirks(
            to: Self.strayStrikeDoc(), enable: ["stray-style-strikeout"]))
        #expect(json["quirks_applicable"] as? [String] == ["stray-style-strikeout"])
        #expect(json["quirks_applied"] as? [String] == ["stray-style-strikeout"])
    }

    @Test func anAutomaticQuirkReportsItselfAsApplied() throws {
        let json = Self.layoutJSON(
            try QuirkRegistry.standard.applyQuirks(to: Self.driverDoc("LJ6DTP")), .printed)
        #expect(json["quirks_applied"] as? [String] == json["quirks_applicable"] as? [String])
        #expect((json["quirks_applied"] as? [String])?.contains("lj6dtp-typography") == true)
    }

    // MARK: the listing

    @Test func theListingWithoutADocumentIsTheBuildsOwnCatalogue() {
        let rows = QuirkRegistry.standard.list()
        #expect(rows.map(\.name) == QuirkRegistry.standard.names())
        #expect(rows.allSatisfy { $0.applicable == nil && $0.reason == nil && $0.enabled == nil })
    }

    @Test func theListingWithADocumentSaysApplicableWhyAndOn() {
        let rows = QuirkRegistry.standard.list(for: Self.strayStrikeDoc())
        let stray = rows.first { $0.name == "stray-style-strikeout" }
        #expect(stray?.applicable == true)
        #expect(stray?.enabled == false)
        #expect(stray?.reason?.isEmpty == false)
        let euro = rows.first { $0.name == "driver-euro-sign" }
        #expect(euro?.applicable == false)
        #expect(euro?.reason == nil)
    }

    // MARK: CLI

    /// An in-memory `CLIEnvironment`, the same shape the other CLI tests here use: no temp
    /// directory, no real filesystem, so these run anywhere.
    static func memoryEnvironment(_ files: [String: [UInt8]],
                                  written: @escaping @Sendable (String, [UInt8]) -> Void,
                                  out: @escaping @Sendable (String) -> Void,
                                  err: @escaping @Sendable (String) -> Void) -> CLIEnvironment {
        CLIEnvironment(
            readFile: { path in
                guard let data = files[path] else { throw QuirkTestFSError.notFound }
                return data
            },
            writeFile: { path, data in written(path, data) },
            createDirectory: { _ in }, writeOut: out, writeErr: err,
            listDirectory: { _ in nil }, isFile: { _ in false })
    }

    @Test func cliListsQuirksAsJSON() throws {
        let box = OutputBox()
        let env = Self.memoryEnvironment([:], written: { _, _ in },
                                         out: { box.appendOut($0) }, err: { box.appendErr($0) })
        #expect(run(["--list-quirks"], environment: env) == 0)
        let rows = try #require((try? JSONSerialization.jsonObject(
            with: Data(box.outText.utf8))) as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == QuirkRegistry.standard.names())
    }

    @Test func cliListsAQuirkThisDocumentTripsAndWhy() throws {
        var body = styleRef(0)
        body += bytes(Self.STRUCK_TEXT)
        body += Self.HARDRET
        let source = documentWithStyleLibrary(body: body, library: Self.library())
        let box = OutputBox()
        let env = Self.memoryEnvironment(["/in/STRUCK.WS": source], written: { _, _ in },
                                         out: { box.appendOut($0) }, err: { box.appendErr($0) })
        #expect(run(["--list-quirks", "/in/STRUCK.WS"], environment: env) == 0)
        let object = try #require((try? JSONSerialization.jsonObject(
            with: Data(box.outText.utf8))) as? [String: Any])
        #expect(object["file"] as? String == "STRUCK.WS")
        let rows = try #require(object["quirks"] as? [[String: Any]])
        let stray = try #require(rows.first { $0["name"] as? String == "stray-style-strikeout" })
        #expect(stray["applicable"] as? Bool == true)
        #expect(stray["enabled"] as? Bool == false)
        #expect((stray["reason"] as? String)?.isEmpty == false)
    }

    @Test func cliRejectsAnUnknownQuirkName() {
        let box = OutputBox()
        let env = Self.memoryEnvironment(["/in/X.WS": bytes("plain text\r\n")],
                                         written: { _, _ in },
                                         out: { box.appendOut($0) }, err: { box.appendErr($0) })
        #expect(run(["--quirk", "nope", "-t", "text", "-o", "/out/o.txt", "/in/X.WS"],
                    environment: env) == ExitStatus.usage)
        #expect(box.errText.contains("nope"))
        #expect(box.errText.contains("stray-style-strikeout"))   // says what IS available
    }

    @Test func cliQuirkFlagReachesTheConversion() throws {
        var body = styleRef(0)
        body += bytes(Self.STRUCK_TEXT)
        body += Self.HARDRET + Self.HARDRET
        body += bytes(Self.AFTER_TEXT)
        body += Self.HARDRET
        let source = documentWithStyleLibrary(body: body, library: Self.library())

        func convert(_ argv: [String]) throws -> String {
            let box = OutputBox()
            let env = Self.memoryEnvironment(["/in/STRUCK.WS": source],
                                             written: { box.write($0, $1) },
                                             out: { box.appendOut($0) },
                                             err: { box.appendErr($0) })
            #expect(run(argv, environment: env) == ExitStatus.ok)
            return String(decoding: try #require(box.file("/out/o.rtf")), as: UTF8.self)
        }
        let faithful = try convert(["-t", "rtf", "-o", "/out/o.rtf", "/in/STRUCK.WS"])
        let quirked = try convert(["--quirk", "stray-style-strikeout", "-t", "rtf",
                                   "-o", "/out/o.rtf", "/in/STRUCK.WS"])
        #expect(faithful.contains("\\strike"))
        #expect(!quirked.contains("\\strike"))
    }
}

private enum QuirkTestFSError: Error { case notFound }

/// Collects what the CLI wrote, across the `@Sendable` closure boundary `CLIEnvironment`
/// requires. A class with a lock rather than captured `var`s: the closures are `@Sendable`
/// and cannot capture mutable local state.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []
    private var files: [String: [UInt8]] = [:]

    func appendOut(_ line: String) { lock.lock(); outLines.append(line); lock.unlock() }
    func appendErr(_ line: String) { lock.lock(); errLines.append(line); lock.unlock() }
    func write(_ path: String, _ data: [UInt8]) {
        lock.lock(); files[path] = data; lock.unlock()
    }
    var outText: String { lock.lock(); defer { lock.unlock() }; return outLines.joined() }
    var errText: String { lock.lock(); defer { lock.unlock() }; return errLines.joined(separator: "\n") }
    func file(_ path: String) -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return files[path] }
}
