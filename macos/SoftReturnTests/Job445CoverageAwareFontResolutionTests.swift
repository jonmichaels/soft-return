import AppKit
import CoreText
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 445 (b27 item 7 part 1 — job 442's diagnosis, `outbox/job442/report.md`):
/// `printedCoverageAwareResolvedMacFont` (`DocumentRenderer.swift`) is the new coverage-aware
/// sibling of `printedResolvedMacFont`, built but NOT YET WIRED into any render path (wiring
/// is part 2, a separate job — `graphicCells`/`resolvedFont` still call the old function).
/// These tests exercise the new function directly and prove it does what job 442's diagnosis
/// asked for: advance past a font that CONSTRUCTS but doesn't COVER the glyphs actually being
/// set, while leaving the ordinary (fully-covered) path untouched.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job445CoverageAwareFontResolutionTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    /// Same technique `FontsInViewsTests.firstCourierClassFontChange()` already uses: a real
    /// `FontChange` from the live ws7 corpus whose typestyle family is one of the courier-class
    /// rows (`"courier|pica|elite|lineprinter|prestige"`) — the exact row job 442's diagnosis
    /// names (`useCourierPrime: true` -> primary "Courier Prime", falt "Courier New").
    private static func firstCourierClassFontChange() throws -> FontChange {
        let prefixes = ["courier", "pica", "elite", "lineprinter", "prestige"]
        for fixture in try FileManager.default.contentsOfDirectory(atPath: Self.ws7Directory.path)
            where fixture.uppercased().hasSuffix(".WS") {
            let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent(fixture)))
            guard let doc = try? parse(bytes, variant: nil) else { continue }
            if let hit = doc.fonts.first(where: { entry in
                let family = entry.family.lowercased()
                return prefixes.contains { family.hasPrefix($0) }
            }) {
                return hit
            }
        }
        Issue.record("no ws7 fixture carries a courier-class font run")
        throw CocoaError(.fileReadUnknown)
    }

    /// job 442's own proving character: U+250C, a box-drawing top-left corner — real member
    /// of `graphicChars` (`PrintedVectorGraphics.swift`), the exact set `graphicCells` gates
    /// vector-fill eligibility on, not an arbitrary pick.
    private static let boxCorner: Character = "\u{250C}"

    /// Whether `font` has a real glyph (not AppKit's own silent missing-glyph substitution)
    /// for every character in `text` — the SAME check `fontCoversAllCharacters` (private to
    /// `DocumentRenderer.swift`) makes, reproduced here at the test layer so the test can
    /// verify the resolver's OUTPUT independently of trusting its internals.
    private static func glyphsCoverAllCharacters(_ font: NSFont, _ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
    }

    // MARK: - Test 1: box-drawing run advances past Courier Prime

    @Test func boxDrawingRunAdvancesPastCourierPrimeToACoveringFont() throws {
        let entry = try Self.firstCourierClassFontChange()
        try #require(Self.boxCorner.unicodeScalars.first.map { graphicChars.contains(Character($0)) } == true,
                     "U+250C must be a real graphicChars member for this test to prove anything")

        // job 442's own measurement: "Courier Prime" CONSTRUCTS but does not COVER U+250C.
        let uncheckedPrimary = try #require(NSFont(name: "Courier Prime", size: 12))
        try #require(!Self.glyphsCoverAllCharacters(uncheckedPrimary, String(Self.boxCorner)),
                     "test assumption changed: Courier Prime now covers cp437 box-drawing on this machine")

        let text = "\u{250C}\u{2500}\u{2500}\u{2510}"
        let resolved = try #require(printedCoverageAwareResolvedMacFont(
            entry, size: 12, bold: false, italic: false, useCourierPrime: true,
            coveringCharactersIn: text))

        #expect(Self.glyphsCoverAllCharacters(resolved, text),
                "the coverage-aware resolver must return a font that actually covers every character requested")
        #expect(resolved.familyName == "Courier New",
                "job 442's own measurement: the already-declared falt (\"Courier New\") is the one that covers cp437 box-drawing")
    }

    // MARK: - Test 2: ordinary ASCII is untouched

    @Test func ordinaryAsciiStillResolvesToCourierPrime() throws {
        let entry = try Self.firstCourierClassFontChange()
        let text = "MONOSPACE"
        let resolved = try #require(printedCoverageAwareResolvedMacFont(
            entry, size: 12, bold: false, italic: false, useCourierPrime: true,
            coveringCharactersIn: text))

        #expect(Self.glyphsCoverAllCharacters(resolved, text))
        #expect(resolved.familyName == "Courier Prime",
                "coverage-awareness must not disturb the normal (fully-covered) path")
    }

    // MARK: - Test 3: resolved advance matches the engine's canonical grid; the CURRENT
    // (uncovered) resolution does not

    /// The engine's own canonical box-drawing pitch (job 442's citation:
    /// `PDFDriverLJ6DTP.graphicOps`, "12pt type on 12pt leading — 10 CPI" -> `0.6 * pt`).
    private static let engineCanonicalAdvanceAt12pt: Double = 0.6 * 12.0

    /// Two adjacent box-drawing glyphs' real, AppKit-measured horizontal advance under `font`
    /// — same technique job 442's own diagnosis and `graphicAdvance`
    /// (`PrintedVectorGraphics.swift:405-412`) use: lay the text out for real
    /// (`isolatedLineLayout`) and read the delta between consecutive glyph locations, rather
    /// than trusting any font's own advertised metrics (which is exactly what's unreliable
    /// once AppKit has silently substituted a different face for these characters).
    @MainActor
    private static func measuredAdvance(font: NSFont, text: String) throws -> Double {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let layout = try #require(isolatedLineLayout(attributed, width: 1000))
        let g0 = layout.manager.location(forGlyphAt: layout.glyphRange.location)
        let g1 = layout.manager.location(forGlyphAt: layout.glyphRange.location + 1)
        return Double(g1.x - g0.x)
    }

    @Test @MainActor func resolvedAdvanceMatchesEngineGridButCurrentResolutionDoesNot() throws {
        let entry = try Self.firstCourierClassFontChange()
        let text = String(repeating: Self.boxCorner, count: 2)

        // CURRENT resolution: what `printedResolvedMacFont` picks today for this run is
        // "Courier Prime" (constructs fine; job 442's diagnosis is that it never checks
        // coverage) — AppKit substitutes an unmanaged fallback under the hood when this gets
        // laid out for real, which is the defect this job's part 2 will fix.
        let currentFont = try #require(NSFont(name: "Courier Prime", size: 12))
        let currentAdvance = try Self.measuredAdvance(font: currentFont, text: text)

        // NEW coverage-aware resolution.
        let newFont = try #require(printedCoverageAwareResolvedMacFont(
            entry, size: 12, bold: false, italic: false, useCourierPrime: true,
            coveringCharactersIn: text))
        let newAdvance = try Self.measuredAdvance(font: newFont, text: text)

        // job 442's own measurement: Courier New's residual is ~0.0012pt/glyph; Menlo's
        // (today's uncovered-run AppKit substitution) is ~0.0246pt/glyph, ~20x larger. 0.01pt
        // sits strictly between the two, so this tolerance actually discriminates them rather
        // than being loose enough to pass either way.
        let tolerance = 0.01
        #expect(abs(newAdvance - Self.engineCanonicalAdvanceAt12pt) < tolerance,
                "coverage-aware resolution (\(newFont.familyName ?? newFont.fontName)) measured \(newAdvance)pt, engine canonical is \(Self.engineCanonicalAdvanceAt12pt)pt")
        #expect(abs(currentAdvance - Self.engineCanonicalAdvanceAt12pt) >= tolerance,
                "test assumption changed: today's uncovered resolution (Courier Prime, AppKit-substituted) now already matches the engine grid within \(tolerance)pt (measured \(currentAdvance)pt) — job 442's defect may no longer reproduce")
    }
}
