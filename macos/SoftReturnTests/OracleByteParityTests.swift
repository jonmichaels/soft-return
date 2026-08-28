import CryptoKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 209 (b11 leg 2): the full-corpus Python-oracle byte-parity gate — registry #18's law
/// applied to Printed PDF output. `TestDocs/oracle/python-printed-manifest.json` (committed
/// `ecb0b41`) is the EXTERNAL oracle: sha256 of the real Python `ctrl-kd` engine's `emitPDF`
/// output, `bare` (no `--page-settings`) and `sawyer` (`--page-settings sawyer`) geometries,
/// for 2,257 real WordStar-format files out of the full Sawyer archive tree (the other 1,308
/// manifest entries are non-WordStar archive members the oracle itself skipped — `"skipped"`
/// key, no `sha256`, excluded from both tiers below).
///
/// Registry #18 (`mistake-registry.md`): a gate whose both sides ship in the same commit (job
/// 200's QL<->CLI parity, which only proved internal self-consistency while the engine itself
/// had drifted from this same Python reference) verifies nothing about correctness. This gate's
/// oracle is frozen data captured from a SEPARATE process (the Python engine) at a named
/// instant, not re-derived from `CtrlKD` itself.
///
/// ## Construction — mirrors `QLCLIByteParityTests.cliPathPDF`'s own citations
/// - `bare`: `parse(bytes, variant: nil)` (manifest's `"source"`: "engine detection decides")
///   then `emitPDF(doc, mode: .printed)` — no page-settings step, matching a bare `sr --mode
///   printed` invocation (`Run.swift:158-160`'s `--page-settings` no-op path).
/// - `sawyer`: the same parse, then `doc.page = effectivePage(page, settings:
///   DocumentOperations.PageSettingsPreset.sawyer.settings)` before `emitPDF` — the CLI's own
///   `--page-settings sawyer` resolution (`Run.swift:158-160` again, this time the settings
///   non-nil), reusing the named preset already shipped in `DocumentOperations.swift` rather
///   than hand-building the margins a second time.
/// - `EmitOptions`' other fields (`notes`/`styles`/`fontsTarget`/`noteRefs`) are never read by
///   `emitPDF`'s Printed path (confirmed by reading `PDFWriter.swift`/`PDFLayout.swift`: no
///   `options.notes`/`options.noteRefs`/`options.styles`/`options.fontsTarget` reference
///   anywhere in either file) — a plain `EmitOptions()` default carries no risk of silently
///   diverging from what the oracle used.
///
/// `structure_sha256`/`pages` in the manifest are diagnostic aids for investigating a mismatch
/// (e.g. via `PrintedStructuralParityTests`'s `EngineTruth`), never the pass criterion — only
/// `sha256` (byte-exact `emitPDF` output) gates this suite, per this job's brief.
enum OracleManifest {
    struct GeometryEntry {
        let sha256: String?
        let bytes: Int?
        let skipped: String?
    }

    /// One `.PIX` reference the oracle's own document carries, and whether the Python
    /// engine resolved it against the real archive tree at manifest-generation time — item
    /// 0 (Jon, 2026-08-22): WordStar never embeds images, only an absolute DOS path a
    /// renderer tail-matches against the document's own directory and ancestors, and a MISS
    /// is ruled to report-and-placeholder, never fail. A render done from the wrong location
    /// therefore produces plausible-looking output whose only tell is the hash — this is the
    /// per-entry record the full-archive manifest refresh adds so the app side can assert
    /// resolution STATE directly instead of leaving a silent placeholder to surface only as
    /// an uninterpretable byte mismatch.
    struct PixManifestEntry {
        let tag: String
        let resolved: Bool
    }

    struct FileEntry {
        let bare: GeometryEntry
        let sawyer: GeometryEntry
        let pix: [PixManifestEntry]
    }

    /// Job 535: routes through `PrivateCorpusSupport` so `CTRLKD_PRIVATE_CORPUS` arms this
    /// manifest too, not just the in-repo `TestDocs/` copy — `files` below already degrades
    /// to `[:]` (and every consumer already treats that as "no tier-1 fixtures", not a
    /// failure) when unarmed, so no other change is needed here.
    static var url: URL {
        PrivateCorpusSupport.oracleDirectory.appendingPathComponent("python-printed-manifest.json")
    }

    /// Parsed once per process. `JSONSerialization` (not `Codable`) because a geometry entry
    /// is one of two disjoint shapes (`{sha256,bytes,pages,structure_sha256}` or
    /// `{skipped}`) — heterogeneous enough that a `Codable` type would need the same manual
    /// per-key extraction anyway.
    static let files: [String: FileEntry] = {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFiles = json["files"] as? [String: Any] else {
            return [:]
        }
        func geometry(_ raw: Any?) -> GeometryEntry {
            guard let dict = raw as? [String: Any] else {
                return GeometryEntry(sha256: nil, bytes: nil, skipped: "manifest entry missing")
            }
            return GeometryEntry(sha256: dict["sha256"] as? String,
                                  bytes: dict["bytes"] as? Int,
                                  skipped: dict["skipped"] as? String)
        }
        func pixList(_ raw: Any?) -> [PixManifestEntry] {
            guard let entries = raw as? [[String: Any]] else { return [] }
            return entries.compactMap { entry in
                guard let tag = entry["tag"] as? String, let resolved = entry["resolved"] as? Bool
                else { return nil }
                return PixManifestEntry(tag: tag, resolved: resolved)
            }
        }
        var result: [String: FileEntry] = [:]
        result.reserveCapacity(rawFiles.count)
        for (name, geoms) in rawFiles {
            guard let g = geoms as? [String: Any] else { continue }
            result[name] = FileEntry(bare: geometry(g["bare"]), sawyer: geometry(g["sawyer"]),
                                      pix: pixList(g["pix"]))
        }
        return result
    }()
}

@Suite struct OracleByteParityTests {

    enum LookupError: Error, CustomStringConvertible {
        case noManifestEntry(String, candidates: [String])
        var description: String {
            switch self {
            case .noManifestEntry(let name, let candidates):
                return "expected exactly one manifest entry named \(name), found \(candidates.count): \(candidates)"
            }
        }
    }

    // MARK: - Shared construction (both tiers)

    /// Real Printed PDF bytes for `bytes`, per this file's own doc comment. `docPath`
    /// (job 371 item 0, PICTURE WIRING): resolved once here too, the same "app can't call the
    /// engine's Foundation-needing `resolveDocumentPictures` directly" situation
    /// `DocumentPictures.resolve`'s own header explains — this oracle gate reaches real
    /// `.PIX` tags (PREVIEW.WS) the Python reference resolves against the real corpus tree,
    /// so a bare `emitPDF` with no `pixResults` can never match it for those fixtures.
    static func renderedPDF(bytes: [UInt8], sawyer: Bool, docPath: String = "") throws
        -> (pdf: [UInt8], pixResults: [PixResult]) {
        var doc = try parse(bytes, variant: nil)
        if sawyer, let page = doc.page {
            doc.page = effectivePage(page, settings: DocumentOperations.PageSettingsPreset.sawyer.settings)
        }
        let pixResults = DocumentPictures.resolve(doc, docPath: docPath)
        let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pixResults: pixResults))
        return (pdf, pixResults)
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Item 0 (Jon, 2026-08-22): compares the REAL render's own per-image resolution state
    /// (`PixResult.ok`, `pixBasename(rawPath)`) against the manifest's recorded state,
    /// pairing entries by position — `doc.graphics`/`pixResults` and the manifest's own
    /// `pix` list are both built by walking the SAME document's image tags in document
    /// order. Pure (no `#expect`) so both `assertByteParity` and this file's own
    /// `imageResolutionMismatch...` test can drive it — a mismatch here means either a real
    /// resolution regression, or (item 0's own false-alarm citation) a render done from the
    /// wrong location, and either way must be a SPECIFIC, named failure, not a byte hash
    /// nobody can interpret.
    static func pixResolutionMismatches(
        pixResults: [PixResult], manifestPix: [OracleManifest.PixManifestEntry]
    ) -> [String] {
        guard !manifestPix.isEmpty else { return [] }
        guard pixResults.count == manifestPix.count else {
            return ["""
                \(pixResults.count) real pix result(s) vs \(manifestPix.count) manifest \
                pix entries — image references drifted between this render and the \
                oracle's own document.
                """]
        }
        var mismatches: [String] = []
        for (i, manifestEntry) in manifestPix.enumerated() {
            let result = pixResults[i]
            let tag = pixBasename(result.rawPath)
            if tag != manifestEntry.tag {
                mismatches.append("pix[\(i)]: tag \"\(tag)\" != manifest tag \"\(manifestEntry.tag)\"")
                continue
            }
            if result.ok != manifestEntry.resolved {
                mismatches.append("""
                    pix[\(i)] "\(manifestEntry.tag)": real render resolved=\(result.ok) but \
                    manifest says resolved=\(manifestEntry.resolved) — a document render from \
                    the wrong location silently placeholders instead of failing; this would \
                    otherwise only show up as an uninterpretable byte-hash mismatch.
                    """)
            }
        }
        return mismatches
    }

    /// Renders `fileURL`, hashes it, and compares against `manifestKey`'s `bare`/`sawyer`
    /// entry — the one assertion both tiers share. Also asserts image RESOLUTION state
    /// (item 0) before the byte comparison, so a placeholder-caused mismatch names itself
    /// instead of surfacing only as an opaque sha diff.
    static func assertByteParity(fileURL: URL, manifestKey: String, sawyer: Bool) throws {
        let bytes = [UInt8](try Data(contentsOf: fileURL))
        let entry = try #require(OracleManifest.files[manifestKey],
                                  "no manifest entry for \(manifestKey)")
        let geom = sawyer ? entry.sawyer : entry.bare
        let expectedSHA = try #require(geom.sha256, """
            \(manifestKey) (\(sawyer ? "sawyer" : "bare")): manifest entry has no sha256 \
            (skipped: \(geom.skipped ?? "?")) — not a WordStar-format oracle entry, should \
            never have been selected for this gate.
            """)
        let rendered = try renderedPDF(bytes: bytes, sawyer: sawyer, docPath: fileURL.path)
        let mismatches = Self.pixResolutionMismatches(pixResults: rendered.pixResults, manifestPix: entry.pix)
        #expect(mismatches.isEmpty, """
            \(manifestKey) (\(sawyer ? "sawyer" : "bare")) image resolution: \
            \(mismatches.joined(separator: "; "))
            """)
        let actualSHA = sha256Hex(rendered.pdf)
        #expect(actualSHA == expectedSHA, """
            \(manifestKey) (\(sawyer ? "sawyer" : "bare")): Swift emitPDF sha \(actualSHA) \
            (\(rendered.pdf.count) bytes) != Python oracle sha \(expectedSHA) \
            (\(geom.bytes.map(String.init) ?? "?") bytes)
            """)
    }

    // MARK: - Tier 1 — TestDocs/ws7, runs everywhere

    /// Job 535: routes through `PrivateCorpusSupport` (env var or in-repo `TestDocs/`) rather
    /// than its own `#filePath` walk — this property is the chokepoint several OTHER files
    /// (`TitleAscenderTests`, `SquareBulletPortTests`, `PrintedStructuralParityTests`, etc.)
    /// call directly as `OracleByteParityTests.ws7Directory`, so fixing it here fixes all of
    /// them too. `ws7Fixtures` below already degrades to `[]` (try?) when the directory is
    /// absent — every `@Test(arguments:)` built from it collapses to a clean Skip; any FIXED
    /// (non-parameterized) caller must gate itself with `.enabled(if: PrivateCorpusSupport
    /// .isArmed)`, since a bare `URL` here can't fail on its own.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ws7Directory.path)) ?? []
        return names.filter { $0.uppercased().hasSuffix(".WS") }.sorted()
    }

    /// `ws7Fixtures` filtered to the ones this file's own EXTERNAL oracle
    /// (`python-printed-manifest.json`, a frozen capture of the real Python engine's output
    /// over the 2,257-file Sawyer archive tree — this file's own top doc comment) actually
    /// has a basename entry for. Mirrors `OutputParityTests.ws7FixturesInManifest`'s own
    /// precedent for a DIFFERENT external manifest (`output-manifest-v9.json`) — same
    /// reasoning, different oracle: a `TestDocs/ws7` fixture authored directly for this app
    /// (job 396's WARPRAYR.WS, `SoftReturn/Resources/SampleDocuments/`; DARKNESS.WS was the
    /// same case until job 498 removed it as a fixture) was never
    /// part of the archive tree the Python reference ran over, so it has nothing here to
    /// compare against — that is a fixture-provenance fact, not a parity regression, and
    /// fabricating a manifest entry for it would violate this suite's own registry #18 law
    /// ("a gate whose both sides ship in the same commit verifies nothing"). Such a fixture
    /// still exercises every OTHER `ws7Fixtures`-driven test in this repo; only these two
    /// sha256-oracle cells, which have nothing to compare against, skip it.
    static var ws7FixturesInManifest: [String] {
        ws7Fixtures.filter { fixtureName in
            OracleManifest.files.keys.contains { ($0 as NSString).lastPathComponent == fixtureName }
        }
    }

    /// Job 434 (b27 item 0): WP0's `-README.WS` (`TestDocs/ws7`) shares its basename with
    /// SIX other archive paths (`APP/`, `APP/vDosPlus/`, `DICT/`, `MACROS/HOLYMAC/`,
    /// `RTF-RJS/`, `TAGS/-README.WS`) — `OracleManifest.files` is keyed over the FULL
    /// Sawyer archive tree, not just the `ws7` basenames, so a basename lookup for this one
    /// fixture is genuinely ambiguous (7 candidates), not merely unverified. The document
    /// bundled at `TestDocs/ws7/-README.WS` is the ARCHIVE-ROOT copy, whose manifest key
    /// carries no directory prefix at all — the same string as the basename, by construction
    /// (a root-level file has no `dir/` component to prepend). This table makes that mapping
    /// EXPLICIT and reviewable rather than resolved by an implicit "pick the first/shortest
    /// match" rule, which would have silently chosen one of the seven with no real ground to
    /// prefer it over the others (`manifestKey(forWS7Fixture:)`'s own unique-basename-match
    /// path, unchanged below, still THROWS — never silently picks — for any fixture NOT
    /// listed here that a future archive re-sync gives a collision to).
    static let ws7ExplicitManifestKeys: [String: String] = [
        "-README.WS": "-README.WS",
    ]

    /// `TestDocs/ws7` fixtures carry no directory prefix, but the manifest's keys are full
    /// corpus-relative paths (e.g. `ARTICLES/YOURWAY.WS`, not `YOURWAY.WS`) — looked up by
    /// full relative path for the fixtures listed in `ws7ExplicitManifestKeys` above (real,
    /// known basename collisions), else by basename and required unique (checked job 209:
    /// unique across the manifest for every OTHER `ws7` fixture) rather than assumed, so a
    /// future archive re-sync that introduces a NEW basename collision fails loudly here
    /// instead of silently comparing against the wrong file.
    static func manifestKey(forWS7Fixture fixtureName: String) throws -> String {
        if let explicit = ws7ExplicitManifestKeys[fixtureName] {
            guard OracleManifest.files[explicit] != nil else {
                throw LookupError.noManifestEntry(fixtureName, candidates: [])
            }
            return explicit
        }
        let matches = OracleManifest.files.keys.filter {
            ($0 as NSString).lastPathComponent == fixtureName
        }
        guard matches.count == 1 else {
            throw LookupError.noManifestEntry(fixtureName, candidates: Array(matches))
        }
        return matches[0]
    }

    /// Job 434 (b27 item 0): proves the collision this fixture actually has in the manifest
    /// (7 candidates, not a hypothetical) AND that the explicit table resolves it to the
    /// archive-root entry — the SAME basename, since a root file carries no `dir/` prefix.
    /// Before `ws7ExplicitManifestKeys` existed, `manifestKey(forWS7Fixture:)` threw
    /// `LookupError.noManifestEntry` for `-README.WS` (`count == 7`, guard fails) — this
    /// test would have failed with that thrown error; it now resolves cleanly.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func readmeBasenameCollisionResolvesToArchiveRoot() throws {
        let rawMatches = OracleManifest.files.keys.filter {
            ($0 as NSString).lastPathComponent == "-README.WS"
        }
        #expect(rawMatches.count > 1, """
            expected a real basename collision in the manifest for -README.WS (the case \
            `ws7ExplicitManifestKeys` exists to resolve) — found \(rawMatches.count) match(es).
            """)
        let key = try Self.manifestKey(forWS7Fixture: "-README.WS")
        #expect(key == "-README.WS", """
            the bundled -README.WS fixture is the archive-root copy, whose manifest key \
            carries no directory prefix — resolved to \(key) instead.
            """)
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

    /// The GATE's own sensitivity, not just `resolve()`'s: feed `pixResolutionMismatches`
    /// the SAME real "empty docPath -> unresolved" results above against `-README.WS`'s
    /// real manifest entry (`resolved: true`, the archive tree's own ground truth) and
    /// require a NAMED mismatch, not a clean pass. This is what stands between a render
    /// done from the wrong location and a byte-hash diff nobody can interpret (item 0's own
    /// brief) — `assertByteParity` calls this exact function before its hash comparison.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func imageResolutionMismatchIsReportedNotSilentlyPassed() throws {
        let url = Self.ws7Directory.appendingPathComponent("-README.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let doc = try parse(bytes, variant: nil)
        let unresolvedResults = DocumentPictures.resolve(doc, docPath: "")

        let key = try Self.manifestKey(forWS7Fixture: "-README.WS")
        let entry = try #require(OracleManifest.files[key])
        #expect(entry.pix.contains { $0.tag == "WORDSTAR.PIX" && $0.resolved }, """
            expected -README.WS's manifest entry to record WORDSTAR.PIX as resolved (the \
            real archive tree's own ground truth) — found \(entry.pix); this test's own \
            premise (a real resolved-vs-unresolved disagreement to detect) depends on it.
            """)

        let mismatches = Self.pixResolutionMismatches(pixResults: unresolvedResults, manifestPix: entry.pix)
        #expect(!mismatches.isEmpty, """
            expected a resolved(manifest)-vs-unresolved(render) disagreement to be reported \
            — got a clean pass instead, which means a wrong-location render would silently \
            placeholder here too.
            """)

        // Sanity: the REAL docPath (correct location) reports zero mismatches — proves the
        // check above fails because of the deliberately-empty docPath, not a broken match.
        let realResults = DocumentPictures.resolve(doc, docPath: url.path)
        let realMismatches = Self.pixResolutionMismatches(pixResults: realResults, manifestPix: entry.pix)
        #expect(realMismatches.isEmpty, """
            -README.WS rendered from its real location should match the manifest's own \
            resolution state — got \(realMismatches).
            """)
    }

    @Test(arguments: ws7FixturesInManifest) func tier1BareByteParity(fixtureName: String) throws {
        let key = try Self.manifestKey(forWS7Fixture: fixtureName)
        try Self.assertByteParity(
            fileURL: Self.ws7Directory.appendingPathComponent(fixtureName),
            manifestKey: key, sawyer: false)
    }

    @Test(arguments: ws7FixturesInManifest) func tier1SawyerByteParity(fixtureName: String) throws {
        let key = try Self.manifestKey(forWS7Fixture: fixtureName)
        try Self.assertByteParity(
            fileURL: Self.ws7Directory.appendingPathComponent(fixtureName),
            manifestKey: key, sawyer: true)
    }

    // MARK: - Tier 2 — full corpus (2,257 files), env-gated

    /// `CTRLKD_PRIVATE_CORPUS` — job 531 unified this app's env-gate onto the SAME name the
    /// engine repo's own gate already uses (`soft-return/CLAUDE.md`: "skip cleanly when
    /// unset") instead of carrying its own separate `SOFTRETURN_ORACLE_CORPUS` name (and
    /// `GeometryOracleTests.swift`'s `SOFT_RETURN_EXTRA_FIXTURES` — a third name for the same
    /// signal). The corpus tree itself is never committed here (`CLAUDE.md`: "TestDocs never
    /// leave this private repo" — and this corpus isn't even this repo's TestDocs, it's the
    /// far larger Sawyer archive the manifest was built from).
    static var corpusRoot: URL? {
        ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"].map(URL.init(fileURLWithPath:))
    }

    /// Every manifest key with a real (non-skipped) sha256 on BOTH geometries — the
    /// 2,257-file WordStar-format subset the brief names. Empty (zero test cases, clean
    /// skip) whenever `corpusRoot` is nil, so this tier never fails a run that simply lacks
    /// the corpus.
    ///
    /// Jon's ruling, 2026-08-19 ("Go with A"), a dated delegation of division of labor: the
    /// full-corpus truth is the full-archive engine sweep (1236/1236 byte-exact, run outside this
    /// repo), not this in-repo gate; this repo's own truth is the Tier-1 120-cell subset
    /// (`OutputParityTests.tier1Cells`). `tier2BareByteParity`/`tier2SawyerByteParity` staying a
    /// clean env-gated no-op here is the RULED shape of that division, not undone coverage debt.
    static var tier2Keys: [String] {
        guard corpusRoot != nil else { return [] }
        return OracleManifest.files
            .filter { $0.value.bare.sha256 != nil && $0.value.sawyer.sha256 != nil }
            .map(\.key)
            .sorted()
    }

    @Test(arguments: tier2Keys) func tier2BareByteParity(manifestKey: String) throws {
        guard let root = Self.corpusRoot else { return }
        try Self.assertByteParity(
            fileURL: root.appendingPathComponent(manifestKey), manifestKey: manifestKey, sawyer: false)
    }

    @Test(arguments: tier2Keys) func tier2SawyerByteParity(manifestKey: String) throws {
        guard let root = Self.corpusRoot else { return }
        try Self.assertByteParity(
            fileURL: root.appendingPathComponent(manifestKey), manifestKey: manifestKey, sawyer: true)
    }
}
