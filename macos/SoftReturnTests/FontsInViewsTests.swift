import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 371 item 2 (FONTS IN VIEWS, RULINGS-LEDGER item 12): SCRIPT.WS renders Courier-class
/// font runs in Native/Modern exactly as Printed/PDF does — i.e. a `FontChange` the shared
/// engine API (`resolveFont`, `CtrlKD/FontMap.swift`'s b24 round 21 item 5 architectural
/// deliverable) classifies as monospace must resolve to a monospace, Mac-native face in BOTH
/// on-screen views, matching the emitter's own classification rather than silently falling
/// back to whatever the Modern font-size control happens to be set to.
///
/// This mostly VERIFIES pre-existing behavior (job 240's `printedResolvedMacFont`, job 306's
/// Native Courier Prime substitution, job 312/b19's Modern parity ruling — all already wired
/// through the ONE shared `attributedLine`/`appendSpan` code path both `renderPrinted`
/// (Native) and `renderModern` call) rather than adding new resolution logic: `resolveFont`
/// deliberately does NOT replace the app's own `printedMacFontName` table (its own doc
/// comment: PDF's `pdfFamily` is "a genuinely different ALGORITHM SHAPE... unifying it here
/// would misrepresent what it actually does" — the app's Mac-native mapping is in the same
/// position). What was missing was the "view-vs-emitter font parity check" itself — this file.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct FontsInViewsTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    private static func scriptDocument() throws -> CtrlKD.Document {
        let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent("SCRIPT.WS")))
        return try parse(bytes, variant: nil)
    }

    /// A real, live `DocumentState` for one ws7 fixture — the SAME construction path
    /// (`DocumentState(data:settings:docPath:)`) `HeadersInViewsTests`/`PixInViewsTests`
    /// etc. already use to exercise `DocumentRenderer.render(_:style:)` for real, rather
    /// than calling `attributedLine` directly.
    @MainActor
    private static func documentState(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "FontsInViewsTests.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// `printedMacFontName`'s own row keys (`DocumentRenderer.swift`'s private
    /// `courierPrimeRowKeys`), mirrored here since the constant itself isn't testable
    /// directly — the family names job 306's brief names verbatim: "courier|pica|elite|
    /// lineprinter" and "prestige".
    private static let courierClassFamilyPrefixes = ["courier", "pica", "elite", "lineprinter", "prestige"]

    /// The first real `FontChange` across the WHOLE `ws7` corpus whose OWN typestyle family
    /// name is one of the courier-class rows — found by search rather than assumed to be on
    /// any one fixture, since a font run's `proportional` bit and its typestyle-name FAMILY
    /// are independent signals (`FontChange`'s own fields) and this file cares about the
    /// family-name row `printedMacFontName` keys off, not the bit `rtfFonts` keys off
    /// (`FontMap.swift`'s own `rtfFonts` doc comment — a SEPARATE algorithm, not this one).
    private static func firstCourierClassFontChange() throws -> FontChange {
        for fixture in try FileManager.default.contentsOfDirectory(atPath: Self.ws7Directory.path)
            where fixture.uppercased().hasSuffix(".WS") {
            let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent(fixture)))
            guard let doc = try? parse(bytes, variant: nil) else { continue }
            let lowerPrefixes = Self.courierClassFamilyPrefixes
            if let hit = doc.fonts.first(where: { entry in
                let family = entry.family.lowercased()
                return lowerPrefixes.contains { family.hasPrefix($0) }
            }) {
                return hit
            }
        }
        Issue.record("no ws7 fixture carries a courier-class (courier/pica/elite/lineprinter/prestige) font run")
        throw CocoaError(.fileReadUnknown)
    }

    /// The `.font` attribute at the start of `text` — every test here renders exactly one
    /// styled span, so the first character's attributes speak for the whole string.
    private static func firstFont(_ text: NSAttributedString) -> NSFont? {
        guard text.length > 0 else { return nil }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    // MARK: - job 394 (391 root cause 3): the actual bug condition, through the REAL
    // render(_:style:) path

    /// SCRIPT.WS's own typestyles 103/104 ("NPS SansSer Qual"/"NPS Serif Qual" — ctrl-kd's
    /// generic Non-PostScript categories, `Typestyles.swift` entries 103/104) are the exact
    /// job 391 root-cause-3 bug condition: `proportional == false`, and a family name
    /// ("NPS SansSer Qual"/"NPS Serif Qual") that appears in NEITHER `printedMacFontRows`
    /// NOR `printedMonoFamilies` — confirmed by direct inspection of `scriptDocument().fonts`
    /// (indices 0-3 alternate between these two typestyles, all four `proportional == false`).
    /// Before job 394's fix, `printedMacFontName` had no short-circuit ahead of the
    /// family-name table, so these fell through to `printedMacGenericPrimary`'s own
    /// sans/serif bucket and rendered a real PROPORTIONAL Mac face.
    ///
    /// This drives the ACTUAL live view path end to end — `DocumentRenderer.render(_:style:)`
    /// against a real `DocumentState` built from the real file — not `attributedLine` called
    /// directly (see `courierClassFontRunIsMonospaceInBothViews` below for that shallower
    /// check): job 391's own root cause was specifically that `render(_:style:)`'s call
    /// chain never reached the engine's `resolveFont` at all, so the assertion has to reach
    /// through the SAME entry point `DocumentWindowController.reloadContent()` uses.
    /// "WRITER'S OFFICE - DAY" is SCRIPT.WS's own screenplay slugline (page 9 of the real
    /// fixture), real body text set through font index 0 (typestyle 104, "NPS Serif Qual") —
    /// located by direct inspection of `docToPagelines(scriptDocument(), printed: true,
    /// pixResults: [], pictures: .off)`'s own span text, not assumed.
    @Test @MainActor func script103104TypestylesRenderMonospaceInRealRenderPath() throws {
        let state = try Self.documentState(fixture: "SCRIPT.WS")
        let needle = "WRITER'S OFFICE - DAY"

        for style: RenderStyle in [.printed, .modern] {
            let rendered = DocumentRenderer.render(state, style: style)
            let haystack = rendered.text.string as NSString
            let range = haystack.range(of: needle)
            #expect(range.location != NSNotFound, "\(style): \"\(needle)\" not found in rendered text")
            guard range.location != NSNotFound else { continue }
            let font = try #require(rendered.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            #expect(font.isFixedPitch,
                    "\(style): a proportional==false NPS typestyle run must render monospace in the REAL render(_:style:) path, not \(font.familyName ?? font.fontName)")
        }
    }

    // MARK: - A real courier-class run

    @Test @MainActor func courierClassFontRunIsMonospaceInBothViews() throws {
        let entry = try Self.firstCourierClassFontChange()
        let span = Span(text: "MONOSPACE", font: 0)
        let fallback = NSFont.systemFont(ofSize: 12)
        // Both Native (`renderPrinted`) and Modern (`renderModern`) call this SAME
        // `attributedLine` with `useCourierPrime: true` — see `printedMacFontName`'s own
        // doc comment (job 312/b19) for the ruling that made Modern match Native here.
        let nativeText = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
            defaultSize: 12, useCourierPrime: true)
        let modernText = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
            defaultSize: 12, useCourierPrime: true)

        let nativeFont = try #require(Self.firstFont(nativeText))
        let modernFont = try #require(Self.firstFont(modernText))
        #expect(nativeFont.isFixedPitch, "Native must resolve a courier-class run to a monospace face")
        #expect(modernFont.isFixedPitch, "Modern must resolve a courier-class run to a monospace face")
        #expect(nativeFont.familyName == modernFont.familyName,
                "Native and Modern must agree on the SAME face for the same font run")
        #expect(nativeFont.familyName == "Courier Prime",
                "job 306/312's ruled substitution: the on-screen views show Courier Prime, not raw Courier New")
    }

    // MARK: - Emitter callers stay off the substitution (job 306's own default: false)

    @Test @MainActor func emitterCallersNeverGetCourierPrimeSubstitution() throws {
        let entry = try Self.firstCourierClassFontChange()
        let span = Span(text: "MONOSPACE", font: 0)
        let fallback = NSFont.systemFont(ofSize: 12)
        // `useCourierPrime` defaults to `false` — every non-view caller (nothing in this
        // codebase renders app-facing output through `attributedLine` for RTF/HTML/PDF —
        // those go through the engine's own emitters — but `PagePreviewRenderer`'s
        // Get-Info-style callers and `QuickLookNativeRenderer`'s bare default matter too);
        // this pins the DEFAULT stays "Courier New family", not the bundled Prime face.
        let text = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry], defaultSize: 12)
        let font = try #require(Self.firstFont(text))
        #expect(font.isFixedPitch)
        #expect(font.familyName != "Courier Prime")
    }

    // MARK: - Regression guard: a genuinely proportional run is untouched

    @Test @MainActor func proportionalFontRunIsNeverForcedMonospace() throws {
        let doc = try Self.scriptDocument()
        guard let entry = doc.fonts.first(where: { $0.proportional }) else {
            // Not every real-corpus fixture carries a proportional run — SCRIPT.WS's own
            // graphic-run coalescing (job 8's own doc note) means this can legitimately be
            // empty; the courier-class test above is this file's real coverage either way.
            return
        }
        #expect(!resolveFont(entry).isMonospace)
        let span = Span(text: "PROPORTIONAL", font: 0)
        let fallback = NSFont.systemFont(ofSize: 12)
        let nativeText = DocumentRenderer.attributedLine(
            [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
            defaultSize: 12, useCourierPrime: true)
        let nativeFont = try #require(Self.firstFont(nativeText))
        #expect(!nativeFont.isFixedPitch, "a genuinely proportional run must never be forced monospace")
    }

    // MARK: - job 394: cross-consumer verdict parity (view vs. RTF emitter)

    /// The RTF emitter's OWN real output (unmodified engine code, no test-side
    /// reimplementation of `rtfFonts`) for SCRIPT.WS's real font table, `.mac` target —
    /// the same target `printedMacFontRows` ports. All four of `scriptDocument().fonts`
    /// (indices 0-3, typestyles 103/104) are `proportional == false`, so `rtfFonts`'s own
    /// decisive short-circuit (`FontMap.swift`: "routed through the SAME per-target
    /// 'courier' table entry... never a family-name or falt garnish") means RTF's
    /// `\fonttbl` must carry the `.mac` courier row's own primary ("Courier New",
    /// `targetFonts[.mac]["courier"]`) for these spans, not `printedMacGenericPrimary`'s
    /// sans/serif terminus ("Helvetica"/"Times New Roman") — the exact wrong answer the
    /// pre-fix view produced. This is the concrete grounding proof that the RTF side of
    /// this document was ALREADY correct (job 391 root cause 3 was a VIEW-only gap);
    /// `verdictParityAcrossWS7CorpusMatchesEngineResolveFont` below is the general
    /// per-entry oracle check the view now shares with it.
    ///
    /// Asserted as an EXACT whole-`\fonttbl`-entry match (`"{\f2 Courier New;}"`), not a
    /// bare substring check: `fontControlRTF`'s own dedup (`primaryToK`) means all four
    /// `doc.fonts` entries here share this ONE slot, `\f2` (`\f0`/`\f1` are the emitter's
    /// own body-default/Printed-Courier reservations, `EmitRTF.swift:660-662` — `\f0`'s
    /// entry is Modern's own no-font-declared body default, Georgia with a "Times New
    /// Roman" `falt`, wholly unrelated to these spans — a bare `!rtf.contains("Times New
    /// Roman")` check would false-positive on that unrelated `falt` and was removed).
    @Test func rtfEmitterAlreadyResolvesScript103104ToCourierClass() throws {
        let doc = try Self.scriptDocument()
        try #require(doc.fonts.allSatisfy { !$0.proportional },
                     "test fixture assumption changed: SCRIPT.WS's font table is no longer all proportional==false")
        let rtf = emitRTF(doc, options: EmitOptions(fontsTarget: .mac))
        #expect(rtf.contains("{\\f2 Courier New;}"),
                "RTF's own .mac-target fonttbl must name the courier row, in its own dedicated slot, for SCRIPT.WS's NPS typestyles")
    }

    /// Verdict parity across the WHOLE ws7 corpus, every real `FontChange` — the
    /// cross-consumer assertion job 391 said was missing: the face CLASS (monospace or
    /// not) the view's real render path resolves must equal `resolveFont`'s own verdict,
    /// which is the SAME decisive `proportional == false` bit `rtfFonts` short-circuits
    /// on (`FontMap.swift`'s own doc comment — the two are textually the identical test,
    /// by the shared-function architecture this job's brief calls for). Exercised via
    /// `attributedLine` with `useCourierPrime: true`, matching both real view callers
    /// (`renderPrinted`/`renderModern`) exactly.
    @Test @MainActor func verdictParityAcrossWS7CorpusMatchesEngineResolveFont() throws {
        var checked = 0
        for fixture in try FileManager.default.contentsOfDirectory(atPath: Self.ws7Directory.path)
            where fixture.uppercased().hasSuffix(".WS") {
            let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent(fixture)))
            guard let doc = try? parse(bytes, variant: nil) else { continue }
            for entry in doc.fonts {
                let expectedMono = resolveFont(entry).isMonospace
                let span = Span(text: "X", font: 0)
                let fallback = NSFont.systemFont(ofSize: 12)
                let text = DocumentRenderer.attributedLine(
                    [span], font: fallback, paragraph: NSParagraphStyle(), fonts: [entry],
                    defaultSize: 12, useCourierPrime: true)
                let font = try #require(Self.firstFont(text))
                #expect(font.isFixedPitch == expectedMono,
                        "\(fixture) family=\(entry.family) proportional=\(entry.proportional): view resolved isFixedPitch=\(font.isFixedPitch), engine resolveFont isMonospace=\(expectedMono)")
                checked += 1
            }
        }
        #expect(checked > 0, "no ws7 fixture carried any font-block entries to check")
    }
}
