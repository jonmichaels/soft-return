import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// PAGE SETTINGS PICKER — job 203 (b10 leg 4).
///
/// Jon's ruling (2026-08-10): a footer control lets a person choose a named `--page-settings`
/// preset for one open document — re-rendering the screen AND flowing into that document's own
/// Printed-mode PDF export — plus a way to make the current choice Quick Look's own default for
/// documents that declare no margins of their own. No corpus gets a hardcoded default baked
/// into the app; the picker (and the QL preference it feeds) are the only way a preset ever
/// applies. This file is the executed-path evidence job 200 asked a future job to close: job
/// 200 (see [[soft-return-job200-ql-cli-parity]]) measured that `OLDTIMES.WS`'s page-2 running
/// head sits at PDF y=780.0 with no preset and y=756.2 under `--page-settings sawyer` — this
/// gate reproduces both figures directly from `emitPDF`'s own content stream, and checks the
/// app's own `DocumentRenderer` agrees with whichever one it rendered.
///
/// Job 425 (b26 wave-2 pin, `machineDefault` preset-provenance fix — engine commit 45b9726):
/// job 200's own figures moved to y=756.0 (bare) and y=732.2 (sawyer) — re-measured directly
/// from THIS PIN's real `emitPDF`, never copied from the app's own AppKit rendering (see
/// `emitPDFPage2RunningHeadYBareVsSawyer`'s own `bareY`/`sawyerY`, which already compute this
/// fresh every run; only the constants they were CHECKED against were stale). The 24pt shift
/// is uniform across bare/sawyer/every call site below — consistent with a single shared
/// margin-provenance fix, not a divergence between them.
@Suite struct PageSettingsPickerTests {

    @MainActor
    static var oldTimesURL: URL {
        MultipageMargins.testDocsDirectory.appendingPathComponent("ws7/OLDTIMES.WS")
    }

    /// PDF content streams in this library are plain ASCII operators, not compressed (see
    /// `QLCLIByteParityTests`'s own doc comment, which quotes one directly) — a lossy Latin-1
    /// decode is enough to regex the operators back out, the same technique job 200's own
    /// investigation used by hand.
    static func page2RunningHeadY(in pdfBytes: [UInt8]) throws -> Double {
        let text = String(bytes: pdfBytes, encoding: .isoLatin1) ?? ""
        let pattern = #"([0-9.]+) ([0-9.]+) Td \(Sawyer / Old Times / 2\) Tj"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let match = try #require(regex.firstMatch(in: text, range: range),
            "no page-2 running head operator found in the emitted PDF")
        let yRange = try #require(Range(match.range(at: 2), in: text))
        return try #require(Double(text[yRange]))
    }

    // MARK: - emitPDF: bare vs sawyer

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func emitPDFPage2RunningHeadYBareVsSawyer() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.oldTimesURL))
        let document = try parse(bytes)

        let barePDF = emitPDF(document, mode: .printed)
        let bareY = try Self.page2RunningHeadY(in: barePDF)
        #expect(abs(bareY - 756.0) < 0.5,
                "bare OLDTIMES.WS page-2 running head is at y=\(bareY), job 425 (b26 wave-2 pin) measured 756.0")

        var sawyerDoc = document
        if let page = sawyerDoc.page {
            sawyerDoc.page = effectivePage(page, settings: DocumentOperations.PageSettingsPreset.sawyer.settings)
        }
        let sawyerPDF = emitPDF(sawyerDoc, mode: .printed)
        let sawyerY = try Self.page2RunningHeadY(in: sawyerPDF)
        #expect(abs(sawyerY - 732.2) < 0.5,
                "sawyer-preset OLDTIMES.WS page-2 running head is at y=\(sawyerY), job 425 (b26 wave-2 pin) measured 732.2")

        // PDF y runs bottom-up (y=792 is the page's TOP edge on this Letter page), so a
        // SMALLER Td y means the head sits FARTHER from the top edge — Sawyer's machine
        // widens the top margin, which pushes the head down the page and shrinks its y.
        #expect(sawyerY < bareY, "the sawyer preset should widen the top margin (smaller PDF y), not shrink it")
    }

    // MARK: - DocumentRenderer: the footer's own selection reaches the same numbers

    /// `DocumentRenderer.renderPrinted`'s `RunningLine.baselineFromTop` is in the app's own
    /// top-down convention (distance from the paper's TOP edge); `emitPDF`'s `Td` is PDF's
    /// bottom-up convention. `pageHeight - baselineFromTop` converts one into the other — the
    /// two must agree, because both are built from the SAME `effectivePage`-adjusted `doc.page`
    /// (see `renderPrinted`'s own doc comment on why job 203 threads it through that way).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func footerPageSettingsSelectionMovesTheOnScreenRunningHeadToMatchEmitPDF() throws {
        let state = try Oracle.state(for: Self.oldTimesURL)

        let bareRendered = DocumentRenderer.render(state)
        let bareHeader = try #require(
            bareRendered.runningLines[safe: 1]?.first { $0.kind == .header },
            "OLDTIMES.WS page 2 has no rendered running head at the bare preset")
        let barePDFY = bareRendered.pageSize.height - bareHeader.baselineFromTop
        #expect(abs(barePDFY - 756.0) < 0.5,
                "on-screen bare page-2 head converts to PDF y=\(barePDFY), job 425 (b26 wave-2 pin) measured 756.0")

        state.setPageSettingsPreset(.sawyer)
        let sawyerRendered = DocumentRenderer.render(state)
        let sawyerHeader = try #require(
            sawyerRendered.runningLines[safe: 1]?.first { $0.kind == .header },
            "OLDTIMES.WS page 2 has no rendered running head under the sawyer preset")
        let sawyerPDFY = sawyerRendered.pageSize.height - sawyerHeader.baselineFromTop
        #expect(abs(sawyerPDFY - 732.2) < 0.5,
                "on-screen sawyer-preset page-2 head converts to PDF y=\(sawyerPDFY), job 425 (b26 wave-2 pin) measured 732.2")
    }

    // MARK: - Printed-mode PDF export carries the same preset

    /// `ExportEngine.render`'s Printed-mode PDF path (`convertData` → the registry's "pdf"
    /// emitter → `emitPDF`) must move by the SAME figure a bare `emitPDF` call with the preset
    /// applied by hand does — this is the "flows into Printed-mode PDF export" half of the
    /// brief, exercised through the real export entry point rather than reconstructed.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func printedModeExportCarriesTheFooterSPageSettingsChoice() throws {
        let state = try Oracle.state(for: Self.oldTimesURL)
        state.style.setManually(.printed)
        state.setPageSettingsPreset(.sawyer)

        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection())
        let product = try #require(products.first { $0.format == .pdf })
        let exportedY = try Self.page2RunningHeadY(in: product.bytes)
        #expect(abs(exportedY - 732.2) < 0.5,
                "Printed-mode PDF export with Sawyer selected put the page-2 head at y=\(exportedY), expected ~732.2")
    }

    // MARK: - QuickLookPageSettingsPreference (the app-group channel, job 203)

    /// An isolated, uniquely-named `UserDefaults` domain per test — never the real
    /// `RC448RH3EN.softreturn` app-group container, so these tests can never read stale state
    /// left by another job/session, and never leave any of their own behind (matches
    /// `Oracle.state(for:)`'s own isolation reasoning).
    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "QuickLookPageSettingsPreferenceTests.\(UUID().uuidString)")!
    }

    @Test func settingAndReadingBackARealPresetRoundTrips() {
        let defaults = Self.isolatedDefaults()
        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == nil,
                "a fresh domain should read back as no override")

        QuickLookPageSettingsPreference.setDefault(.sawyer, defaults: defaults)
        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == .sawyer)

        QuickLookPageSettingsPreference.setDefault(nil, defaults: defaults)
        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == nil,
                "choosing Embedded again must clear the stored default, not merely leave it stale")
    }

    /// A missing app-group container (extension launched before the entitlement was granted,
    /// or simply `nil` injected directly) must read back exactly like "nothing was ever set" —
    /// this is the failure-proofing the brief requires: a bad/missing key can never break a
    /// Quick Look render.
    @Test func aMissingContainerResolvesToNoOverride() {
        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: nil) == nil)
    }

    /// A name this build doesn't recognize (an OLDER extension binary reading a key a NEWER
    /// app wrote, or vice versa) must fall back clean rather than crash or throw — the exact
    /// "unknown preset name falls back clean" case the brief asks for.
    @Test func anUnrecognizedPresetNameFallsBackToNoOverride() {
        let defaults = Self.isolatedDefaults()
        defaults.set("some-future-preset-this-build-does-not-know", forKey: "pageSettingsDefaultPreset")
        #expect(QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults) == nil)
    }

    /// Job 247 (ql-native): the QL provider path now IS `QuickLookNativeRenderer` — not a
    /// reconstruction of it, the real shared function `PreviewProvider`/`ThumbnailProvider`
    /// both call — so this exercises it directly rather than re-deriving its body. Honors an
    /// INJECTED group default (resolved from an isolated container, then passed explicitly —
    /// `renderedDocument`'s own default parameter expression reads the REAL container, exactly
    /// what a live Finder preview needs; a test that wants a specific, isolated value passes
    /// it in, the same seam `PreviewProvider`'s real call site relies on for production
    /// behavior) — the "QL path honors an injected group-default" case job 203's brief asked
    /// for. Checked against job 425's own re-measured figure (732.2, b26 wave-2 pin — see this
    /// file's top doc comment), not a value invented here.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func quickLookNativeRendererHonorsAnInjectedGroupDefault() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.oldTimesURL))
        let defaults = Self.isolatedDefaults()
        QuickLookPageSettingsPreference.setDefault(.sawyer, defaults: defaults)
        let preset = QuickLookPageSettingsPreference.resolvedDefault(defaults: defaults)

        let rendered = try QuickLookNativeRenderer.renderedDocument(
            fromFileBytes: bytes, pageSettingsPreset: preset)
        let header = try #require(
            rendered.runningLines[safe: 1]?.first { $0.kind == .header },
            "OLDTIMES.WS page 2 has no rendered running head under an injected sawyer default")
        let y = rendered.pageSize.height - header.baselineFromTop
        #expect(abs(y - 732.2) < 0.5,
                "QuickLookNativeRenderer with an injected sawyer default put the page-2 head at y=\(y), expected ~732.2")
    }

    /// `QuickLookNativeRenderer.renderedDocument(fromFileBytes:pageSettingsPreset:)`, given an
    /// EXPLICIT `nil` preset, must render bare regardless of what the REAL shared app-group
    /// container on this machine happens to hold — pinned here directly rather than only
    /// trusted by inspection (this is the exact seam `QLCLIByteParityTests`' own permanent
    /// parity gate depends on for a deterministic, environment-independent comparison), since
    /// a silent regression here would defeat the whole point of job 200's original ruling and
    /// job 247's gate alike.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func quickLookNativeRendererIgnoresTheRealContainerWhenGivenNilPreset() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.oldTimesURL))
        let rendered = try QuickLookNativeRenderer.renderedDocument(
            fromFileBytes: bytes, pageSettingsPreset: nil)
        let header = try #require(
            rendered.runningLines[safe: 1]?.first { $0.kind == .header },
            "OLDTIMES.WS page 2 has no rendered running head at an explicit nil preset")
        let y = rendered.pageSize.height - header.baselineFromTop
        #expect(abs(y - 756.0) < 0.5,
                "QuickLookNativeRenderer with an explicit nil preset put the page-2 head at y=\(y), expected the bare ~756.0 regardless of the real app-group container")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
