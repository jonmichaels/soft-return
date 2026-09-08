import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 209 (b11 leg 2): originally the full-corpus Python-oracle byte-parity gate —
/// registry #18's law applied to Printed PDF output — over `TestDocs/oracle/
/// python-printed-manifest.json`. Planning #205 Task 2 (2026-09-06) RETIRED that manifest
/// package-wide: ctrl-kd's shared answer key (`tests/answer_key.json`) grew to cover the
/// FULL public Sawyer corpus (385 convertible + 4 samples + 10 known-nonconvertible + 1
/// non-document asset), which made the manifest's `bare` geometry (`EmitOptions()`
/// defaults, no page-settings override, no real `.PIX` resolution) a strict subset of the
/// answer key's own `pdf.printed` cell — the condition this file's own prior header once
/// said had NOT been met (see git history for that 2026-09-06 investigation). The
/// manifest's other geometry (`sawyer` preset + real pix resolution) has a new,
/// self-recorded replacement at the PACKAGE level:
/// `Tests/CtrlKDTests/CorpusParityTests.swift`, reading `TestDocs/oracle/
/// sawyer_preset_pdf_sr.json` — see that file's own header for the full account.
///
/// Every test in this file that depended on `OracleManifest`/`python-printed-manifest.json`
/// (the `OracleManifest` enum itself, `renderedPDF`/`assertByteParity`/
/// `pixResolutionMismatches`, `ws7ExplicitManifestKeys`/`manifestKey(forWS7Fixture:)`/
/// `ws7FixturesInManifest`, and the tests `readmeBasenameCollisionResolvesToArchiveRoot`,
/// `imageResolutionMismatchIsReportedNotSilentlyPassed`, `tier1BareByteParity`,
/// `tier1SawyerByteParity`) was REMOVED in the same commit that retired the manifest file —
/// not left to silently degrade to zero collected cases (this repo's own registry law:
/// "a gate whose both sides ship in the same commit verifies nothing" applies just as much
/// to "a gate that can never again collect a case" as to a same-commit gate). The full-
/// corpus, pure-engine sweep this file's Tier 2 used to duplicate already lives at the
/// package level (`CorpusParityTests`/`AnswerKeyParityTests`, `swift test`); this file's own
/// former Tier 1 (`TestDocs/ws7` bundled fixtures vs. the SAME retired manifest) had nothing
/// left to compare against once it was gone, and is not something this app target needs to
/// re-derive — the package-level suites already cover every one of those bundled fixtures
/// as part of covering the FULL corpus.
///
/// `unresolvableImageIsDetectedAsUnresolved`, below, is UNCHANGED and stays: it exercises
/// `DocumentPictures.resolve`'s own contract directly (an empty `docPath` leaves every pix
/// tag `.unresolved`) and never reads the retired manifest at all.
@Suite struct OracleByteParityTests {
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ws7Directory.path)) ?? []
        return names.filter { $0.uppercased().hasSuffix(".WS") }.sorted()
    }

    // MARK: - Item 0 (image-resolution gate)

    /// `-README.WS`'s own real `WORDSTAR.PIX` reference (`TestDocs/ws7/INSET/PIX/`),
    /// resolved for real (`DocumentPictures.resolve`, no manifest involved) with an EMPTY
    /// `docPath` — `resolve`'s own documented contract ("a docPath with nothing to search
    /// from... reports every tag `.unresolved`"), the same "wrong location" condition item
    /// 0's brief names, constructed deliberately rather than by accident. Proves the
    /// MECHANISM: a document whose image cannot resolve is detected as such
    /// (`PixResult.ok == false`, `.error == .unresolved`), not silently treated as success.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func unresolvableImageIsDetectedAsUnresolved() throws {
        let url = Self.ws7Directory.appendingPathComponent("-README.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let doc = try parse(bytes, variant: nil)
        #expect(!doc.graphics.isEmpty, "-README.WS should carry at least one .PIX reference")

        let results = DocumentPictures.resolve(doc, docPath: "")
        #expect(!results.isEmpty)
        for result in results {
            #expect(!result.ok, "expected an empty docPath to leave every pix tag unresolved")
            #expect(result.error == .unresolved, "expected .unresolved, got \(String(describing: result.error))")
        }
    }
}
