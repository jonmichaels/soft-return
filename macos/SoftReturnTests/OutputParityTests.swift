import CryptoKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 262 (b15, `output-parity`): Jon's directive after b12's office-vs-mac font bug —
/// "there needs to be a verification of ALL outputs... just like was done for sr vs
/// ctrl-kd." That job (`OracleByteParityTests`) proved the ENGINE's Printed PDF matches the
/// Python reference. This file proves the APP's three real conversion surfaces match it too,
/// across every format and mode, because b12 is the proof an app-level knob (there,
/// `fontsTarget`) can silently diverge from a correct engine underneath it.
///
/// ## The oracle
/// `TestDocs/oracle/output-manifest-v11.json` (`OutputManifest` below): sha256 of the real
/// Python `ctrl-kd`'s output, `--fonts mac`, for every (file, format, mode) cell — six
/// formats (`rtf`/`html`/`markdown`/`text`/`layout`/`pdf`) times two modes
/// (`modern`/`printed`). "`--fonts mac`" plus every other option left at the Python CLI's
/// own bare defaults is exactly `sr`'s own bare invocation too (`Arguments.swift`'s
/// `Options()`: `fontsTarget: .mac` — D7 ruling — `notes: .defaultNotes`, `styles: true`,
/// `pageSettings: nil`, `noteRefs: .word`), and `sr` itself titles every emit with the
/// file's own stem (`Run.swift`'s `EmitOptions(title: base, ...)`) — so the oracle's
/// reconstruction below passes `variant: nil` (auto-detect, "engine detection decides" per
/// the manifest's own `source` field) and otherwise touches only `formats`/`mode`. v9
/// (ctrl-kd 7fa1d5c / sr 599dc13, round 22 + LAYOUT BYTE PARITY) is generated against an
/// engine whose `layout` format is now byte-identical across implementations — the ruling
/// 2026-08-18 ONE-STRUCTURAL-GAP note below.
///
/// **v10 (job 423, PARTIAL REFRESH):** the b26 FIDELITY ROUND (13 engine fixes, pin
/// `d682f4956c55ef221ac45fa6adc4d06b6bc5fc9f`) legitimately moved Printed-mode geometry
/// (top/header margins, leading, per-page `.mt`/`.mb`), so v9's frozen hashes went stale for
/// this repo's own bundled subset — confirmed empirically (re-ran the local `ctrl-kd`
/// checkout, now at its own origin/main tip `3c5eb9f`, against `TestDocs/ws7` directly; every
/// new hash matched what the freshly-pinned Swift engine was ALREADY producing, i.e. an
/// engine-vs-stale-oracle gap, not an app-vs-engine bug). Only the 10 `ws7FixturesInManifest`
/// fixtures' cells were re-rendered — this environment has no access to the private Sawyer
/// corpus tree the other 141 v9 files need (`Scripts/generate_oracle_manifest.py`'s own
/// docstring: "Runs where ctrl-kd and the Sawyer tree live"). A full v10 (all 151
/// files) is a full-archive-host job.
///
/// **v11 (job 426, FULL RESCOPE):** generated on the full-archive host (`ctrl-kd b07a9c7`) directly against
/// this repo's OWN bundled `TestDocs/ws7` corpus — 19 files, 228 non-skipped cells — rather
/// than against the separate, much larger private Sawyer tree v9/v10 tracked (151 files, 1236
/// cells, of which only 10 files/120 cells were ever reachable from this repo). The corpus
/// SHAPE changed deliberately, not just cell content: `fullManifestNonSkippedCellCount`/
/// `bundledFixtures`/`bundledCells` below are now 228/19/228 — `full == bundled` because this
/// manifest's whole scope IS the bundled subset now. This makes the "full-denominator law" gap
/// `fullDenominatorLawStatesThisSuitesRealScopeAgainstTheFullManifestCorpus` was written to
/// track (job 374, "a gate covering less than its named full corpus must state its own
/// denominator") a non-issue for v11: 0 cells remain outside this suite's own reach, so Tier 2
/// (`CTRLKD_PRIVATE_CORPUS`-gated) and the full-archive sweep are no longer covering anything
/// this suite doesn't already — kept below only as still-valid infrastructure in case a future
/// manifest reverts to tracking a larger corpus than what's bundled.
///
/// **v12 (job 488, ENGINE REFRESH, scope unchanged):** v11 was captured at `ctrl-kd b07a9c7`;
/// the app now pins the Swift engine at `soft-return c1b622d`, whose Python counterpart is
/// `ctrl-kd 62082c9` (`lj6dtp-parity`) — the same pin job 486 regenerated
/// `python-printed-manifest.json` from. v12 is the SAME 19 fixtures and 228 cells re-rendered
/// from that Python oracle (`scripts/generate_oracle_manifest.py --keys-from` the v11 file, so
/// a refresh cannot silently become a rescope); every pinned count below is therefore
/// unchanged. 72 of 228 cells moved, all of it geometry and style ATTRIBUTION, none of it
/// content: `text.*` did not move at all (0/38), and every changed `html`/`markdown`/`rtf`
/// cell has character-identical visible text once markup is stripped — the tab work
/// (`8bbad81` real WordStar tab-stop positioning, `c3c35a5` tab queue drains after the
/// font/colour marks) turns what used to be pad spaces prefixed onto a text run into its own
/// absolutely-positioned span. The three content-level deltas are all named LJ6DTP fidelity
/// fixes: repeated dot leaders (`6a16bff`), a real bullet instead of a middle dot (`ccfe328`),
/// and the kerning demo's quote pairs collapsing (`ef795e8`).
///
/// **v12 addendum (job 498, FIXTURE REMOVAL, not an engine refresh):** Jon's ruling — Twain's
/// `DARKNESS.WS` (its title text uses a slur unacceptable to ship, even as a private test
/// fixture) is dropped from `TestDocs/ws7` entirely. Its 12 cells were removed from the
/// committed `output-manifest-v12.json` by direct, verified key deletion (every remaining
/// file's cells checked byte-identical before/after), NOT a re-run of
/// `generate_oracle_manifest.py`: this environment's `ctrl-kd` checkout has moved past the
/// `62082c9` pin v12 itself was captured at (real intervening engine changes — note-column
/// hang, Symbol Tr isolation, euro-158, WS4 spacing-blank pagination — none of which this job's
/// brief authorized taking on), and that exact commit is not reachable here to re-render
/// against. `fullManifestNonSkippedCellCount`/`bundledFixtures`/`bundledCells` move from
/// 228/19/228 to 216/18/216 as a result — see `fullDenominatorLawStatesThisSuitesRealScopeAgainstTheFullManifestCorpus`'s
/// updated pins below. A true regeneration against the CURRENT engine pin (which has also
/// drifted from `c1b622d` since job 488) is separate, larger, out-of-scope work for a
/// full-archive-host session with `ctrl-kd` and the exact pinned commit available.
///
/// SCOPE NOTE, flagged not buried: `TestDocs/ws7` has gained `BOTHNOTE.WS`, `-README.WS` and
/// `-SCREEN.WS` since v11 was captured, and v12 deliberately does NOT cover them — adding them
/// would move all three counts this file pins by name (228/19/228), which is a scope decision
/// to take on purpose, not under an engine refresh. `ws7FixturesInManifest` keeps them out of
/// the Tier-1 cells until then.
///
/// ## Three surfaces, one cell
/// - (a) `DocumentOperations.convert` — the shared layer every headless caller (Intents,
///   Spotlight, a future AppleScript dictionary) sits on.
/// - (b) `ConvertCommand.convert` — the actual AppleScript `convert` verb's static
///   implementation (`SoftReturn.sdef`'s batch command).
/// - (c) `ExportEngine.render` — the Export As sheet / Batch window's shared rendering path.
///
/// ONE structural gap is DOCUMENTED, not a bug, and excluded from the must-match cells
/// rather than silently skipped: `ExportFormat` has no `.layout` case, so surface (c) cannot
/// attempt 24 of the 144 cells at all (see `exportEngineHasNoLayoutRoute`) — layout is
/// otherwise byte-compared like every other format now (ruling 2026-08-18: the engine's
/// parsed-data carve-out for `layout` is abolished as of the doc-contract rewrite at pin
/// `599dc13`; see `LayoutJSONValue`'s rewritten doc comment in `soft-return/Sources/CtrlKD/
/// Layout.swift`). Surface (c) SEPARATELY cannot attempt PDF+Modern — it goes through AppKit
/// by design (`ExportEngine.render`'s own doc comment: "PDF is the documented divergence" —
/// the library's Courier-only PDF is wrong for Modern, so the app uses the native text stack
/// instead; `DocumentOperations.convert`'s own doc comment says the same from the other side:
/// "a headless caller gets the library's own PDF, which is a documented difference, not a
/// bug"). `exportEnginePDFModernIsADocumentedAppKitDivergence` below guards that the
/// divergence stays real rather than silently vanishing.
///
/// ## Scope, honestly stated (job 374, PARITY GATE EXPANSION, "full-denominator law")
/// This suite exercises every cell reachable from `TestDocs/ws7`'s bundled corpus subset —
/// NOT the full `output-manifest-v9.json` corpus (151 files, 103 fully convertible, 1236
/// non-skipped cells — unchanged from v8; only cell hashes moved, not the corpus shape). See
/// `fullDenominatorLawStatesThisSuitesRealScopeAgainstTheFullManifestCorpus` below for the
/// exact, pinned numbers and why this repo cannot bundle more of the corpus from this
/// environment. Tier 2 (env-gated, below) and the full-archive sweep are the full-matrix gate.
enum OutputManifest {
    struct CellEntry {
        let sha256: String?
        let bytes: Int?
        let skipped: String?
    }

    static let formats = ["rtf", "html", "markdown", "text", "layout", "pdf"]

    /// Job 535: routes through `PrivateCorpusSupport` (env var or in-repo `TestDocs/`) — see
    /// that file's own doc comment. `files` below already degrades to `[:]` when unarmed.
    static var url: URL {
        PrivateCorpusSupport.oracleDirectory.appendingPathComponent("output-manifest-v12.json")
    }

    /// `files[name][format + "." + mode]`. `JSONSerialization`, not `Codable`, for the same
    /// reason `OracleByteParityTests`' own manifest parser gives: a cell is one of two
    /// disjoint shapes (`{sha256,bytes}` or `{skipped}`).
    static let files: [String: [String: CellEntry]] = {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFiles = json["files"] as? [String: Any] else {
            return [:]
        }
        var result: [String: [String: CellEntry]] = [:]
        result.reserveCapacity(rawFiles.count)
        for (name, cellsRaw) in rawFiles {
            guard let cells = cellsRaw as? [String: Any] else { continue }
            var parsed: [String: CellEntry] = [:]
            parsed.reserveCapacity(cells.count)
            for (cellKey, raw) in cells {
                guard let dict = raw as? [String: Any] else { continue }
                parsed[cellKey] = CellEntry(sha256: dict["sha256"] as? String,
                                             bytes: dict["bytes"] as? Int,
                                             skipped: dict["skipped"] as? String)
            }
            result[name] = parsed
        }
        return result
    }()
}

@Suite struct OutputParityTests {

    enum LookupError: Error, CustomStringConvertible {
        case noManifestEntry(String, candidates: [String])
        case noCell(manifestKey: String, cellKey: String)
        case noSHA(manifestKey: String, cellKey: String, skipped: String?)
        case noBytesProduced(String)

        var description: String {
            switch self {
            case .noManifestEntry(let name, let candidates):
                return "expected exactly one manifest entry named \(name), found \(candidates.count): \(candidates)"
            case .noCell(let manifestKey, let cellKey):
                return "\(manifestKey): manifest has no \"\(cellKey)\" cell"
            case .noSHA(let manifestKey, let cellKey, let skipped):
                return "\(manifestKey) \(cellKey): manifest entry has no sha256 (skipped: \(skipped ?? "?"))"
            case .noBytesProduced(let detail):
                return "produced no output: \(detail)"
            }
        }
    }

    /// One Tier-1 matrix cell: a `TestDocs/ws7` fixture, one of the manifest's six formats,
    /// one of its two modes.
    struct Cell: Sendable, CustomStringConvertible {
        let fixture: String
        let format: String
        let mode: EmitMode
        var description: String { "\(fixture) \(format).\(mode.rawValue)" }
    }

    // MARK: - Fixtures / manifest lookup

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    static var ws7Fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ws7Directory.path)) ?? []
        return names.filter { $0.uppercased().hasSuffix(".WS") }.sorted()
    }

    /// `ws7Fixtures` filtered to the ones `output-manifest-v9.json` actually has an entry
    /// for. v7's own `source` field ("sawyer-ws7/WS full tree, engine detection decides")
    /// notwithstanding, FORMFEED.WS/POWERUSE.WS/SCRIPT.WS/YOURWAY.WS are absent from its 151
    /// files — verified directly against the committed manifest, not a lookup-code bug: zero
    /// matches by basename, no near-match by name or case. Not an app regression to chase —
    /// these four fixtures stay in `TestDocs/ws7` (POWERUSE.WS in particular is a job 294
    /// Show Invisibles verification fixture, unrelated to this gate) and keep exercising
    /// every OTHER `ws7Fixtures`-driven test; only the sha256-oracle Tier-1 cells, which have
    /// nothing to compare against, skip them.
    static var ws7FixturesInManifest: [String] {
        ws7Fixtures.filter { fixture in
            OutputManifest.files.keys.contains { ($0 as NSString).lastPathComponent == fixture }
        }
    }

    /// Same basename-lookup discipline as `OracleByteParityTests.manifestKey(forWS7Fixture:)`:
    /// `TestDocs/ws7` fixtures carry no directory prefix, the manifest's keys are full
    /// corpus-relative paths (`ARTICLES/YOURWAY.WS`), required unique rather than assumed.
    static func manifestKey(forWS7Fixture fixtureName: String) throws -> String {
        let matches = OutputManifest.files.keys.filter {
            ($0 as NSString).lastPathComponent == fixtureName
        }
        guard matches.count == 1 else {
            throw LookupError.noManifestEntry(fixtureName, candidates: Array(matches))
        }
        return matches[0]
    }

    static func expectedSHA(manifestKey: String, format: String, mode: EmitMode) throws -> String {
        let cellKey = "\(format).\(mode.rawValue)"
        guard let entry = OutputManifest.files[manifestKey] else {
            throw LookupError.noManifestEntry(manifestKey, candidates: [])
        }
        guard let cell = entry[cellKey] else {
            throw LookupError.noCell(manifestKey: manifestKey, cellKey: cellKey)
        }
        guard let sha = cell.sha256 else {
            throw LookupError.noSHA(manifestKey: manifestKey, cellKey: cellKey, skipped: cell.skipped)
        }
        return sha
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tier 1 cell lists

    static var tier1Cells: [Cell] {
        var result: [Cell] = []
        result.reserveCapacity(ws7FixturesInManifest.count * OutputManifest.formats.count * 2)
        for fixture in ws7FixturesInManifest {
            for format in OutputManifest.formats {
                for mode: EmitMode in [.modern, .printed] {
                    result.append(Cell(fixture: fixture, format: format, mode: mode))
                }
            }
        }
        return result
    }

    /// Ruling 2026-08-18: the engine's parsed-data carve-out for `layout` is abolished — its
    /// doc contract was rewritten at pin `599dc13` (`soft-return/Sources/CtrlKD/Layout.swift`,
    /// `LayoutJSONValue`) to guarantee byte-identical output, matching every other format.
    /// `layout` cells join the full sha256-oracle set for surfaces (a) and (b) below; surface
    /// (c) still cannot attempt them, but ONLY because `ExportFormat` has no `.layout` case at
    /// all (see `exportEngineHasNoLayoutRoute`), a wholly separate reason.
    static var tier1CellsForExportEngine: [Cell] {
        tier1Cells.filter { $0.format != "layout" && !($0.format == "pdf" && $0.mode == .modern) }
    }

    // MARK: - Surface (a): DocumentOperations.convert (the shared layer)

    /// `ConversionOptions(formats:mode:)` plus the one field every REAL caller of this layer
    /// already overrides — `title`. Job 270: this test used to leave `title` at the struct's
    /// bare `""` default, which is not "a caller who forgot to override everything" so much
    /// as a caller `DocumentOperations.convert` never actually has in production —
    /// `ConvertCommand`, `WSDocument+Scripting`, and the Convert intent all pass the file's
    /// own basename (`sr`'s own `Run.swift` convention, which is what generated the oracle
    /// manifest — see this file's own header comment). `title` is invisible everywhere except
    /// HTML's `<title>` tag, so the gap was silent until the full Tier-1 corpus was checked
    /// cell-by-cell instead of via `xcresulttool`'s truncated failure summary.
    @Test(arguments: tier1Cells) func documentOperationsMatchesOracle(cell: Cell) throws {
        let key = try Self.manifestKey(forWS7Fixture: cell.fixture)
        let expected = try Self.expectedSHA(manifestKey: key, format: cell.format, mode: cell.mode)
        let fixtureURL = Self.ws7Directory.appendingPathComponent(cell.fixture)
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let title = (cell.fixture as NSString).deletingPathExtension
        let options = DocumentOperations.ConversionOptions(
            formats: [cell.format], mode: cell.mode, title: title, docPath: fixtureURL.path)
        let produced = try DocumentOperations.convert(data: bytes, options: options)
        let actual = try #require(produced.first, "DocumentOperations.convert produced no result").bytes
        #expect(Self.sha256Hex(actual) == expected,
                "\(cell.description) [DocumentOperations.convert] diverged from the oracle (\(actual.count) bytes)")
    }

    // MARK: - Surface (b): ConvertCommand.convert (the AppleScript route)

    /// Copies the fixture into a scratch source directory and writes into a SEPARATE scratch
    /// destination directory (`to folder`) — never `TestDocs/ws7` itself, which
    /// `BesideSourceWriter`'s bare-destination path would otherwise write beside.
    ///
    /// Job 371 item 0 (PICTURE WIRING): also mirrors `ws7Directory`'s own `INSET/PIX/`
    /// subtree into the scratch source dir, when present — `DocumentPictures.resolve` walks
    /// ancestors from the REAL doc path looking for it (`ConvertCommand.convert` now passes
    /// `file.path`), so a fixture like PREVIEW.WS needs its sibling asset to travel with it
    /// into the scratch copy, exactly as it does in the real `TestDocs/ws7` tree, or
    /// resolution correctly (not a bug) reports the picture missing.
    static func convertCommandBytes(fixtureName: String, format: String, mode: EmitMode) throws -> [UInt8] {
        let sourceDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let outDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }
        let copy = sourceDir.appendingPathComponent(fixtureName)
        try FileManager.default.copyItem(at: Self.ws7Directory.appendingPathComponent(fixtureName), to: copy)
        let insetSource = Self.ws7Directory.appendingPathComponent("INSET")
        if FileManager.default.fileExists(atPath: insetSource.path) {
            try FileManager.default.copyItem(at: insetSource, to: sourceDir.appendingPathComponent("INSET"))
        }

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: outDir, formats: [format], mode: mode,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)
        guard let produced = result.produced.first else {
            throw LookupError.noBytesProduced(
                "\(fixtureName) \(format).\(mode.rawValue): skipped=\(result.skipped) failed=\(result.failed.count) "
                    + "destinationAccessError=\(result.destinationAccessError ?? "nil")")
        }
        return [UInt8](try Data(contentsOf: produced))
    }

    @Test(arguments: tier1Cells) func convertCommandMatchesOracle(cell: Cell) throws {
        let key = try Self.manifestKey(forWS7Fixture: cell.fixture)
        let expected = try Self.expectedSHA(manifestKey: key, format: cell.format, mode: cell.mode)
        let actual = try Self.convertCommandBytes(fixtureName: cell.fixture, format: cell.format, mode: cell.mode)
        #expect(Self.sha256Hex(actual) == expected,
                "\(cell.description) [ConvertCommand.convert] diverged from the oracle (\(actual.count) bytes)")
    }

    // MARK: - Surface (c): ExportEngine.render (the Export panel route)

    @MainActor
    static func exportEngineBytes(fixtureName: String, format: ExportFormat, mode: EmitMode) throws -> [UInt8] {
        let fixtureURL = Self.ws7Directory.appendingPathComponent(fixtureName)
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let defaults = UserDefaults(suiteName: "OutputParityTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        let style: RenderStyle = mode == .modern ? .modern : .printed
        let title = (fixtureName as NSString).deletingPathExtension
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [format], notes: NoteSelection(),
            style: style, title: title, docPath: fixtureURL.path)
        guard let product = products.first else {
            throw LookupError.noBytesProduced("\(fixtureName) \(format.rawValue).\(mode.rawValue): no product")
        }
        return product.bytes
    }

    @Test(arguments: tier1CellsForExportEngine) @MainActor func exportEngineMatchesOracle(cell: Cell) throws {
        let key = try Self.manifestKey(forWS7Fixture: cell.fixture)
        let expected = try Self.expectedSHA(manifestKey: key, format: cell.format, mode: cell.mode)
        let format = try #require(ExportFormat(rawValue: cell.format),
                                   "\(cell.format) has no ExportFormat case — should have been filtered out of tier1CellsForExportEngine")
        let actual = try Self.exportEngineBytes(fixtureName: cell.fixture, format: format, mode: cell.mode)
        #expect(Self.sha256Hex(actual) == expected,
                "\(cell.description) [ExportEngine.render] diverged from the oracle (\(actual.count) bytes)")
    }

    // MARK: - Full-denominator law (job 374, PARITY GATE EXPANSION; RESCOPED job 426)

    /// Every non-skipped cell across the WHOLE `output-manifest-v11.json` corpus, regardless
    /// of whether this repo bundles the file that cell belongs to. THE full denominator this
    /// suite's own scope is measured against. As of v11 (job 426) this corpus IS the bundled
    /// `TestDocs/ws7` subset — 18 files, 216 cells as of job 498's `DARKNESS.WS` removal (was
    /// 19/228) — see this file's own header comment for why that differs from v9/v10's
    /// separate, much larger private-corpus scope.
    static var fullManifestNonSkippedCellCount: Int {
        OutputManifest.files.values.reduce(0) { total, cells in
            total + cells.values.filter { $0.sha256 != nil }.count
        }
    }

    /// Job 374 (PARITY GATE EXPANSION, "309 → full") coined the "full-denominator law": a gate
    /// covering less than its named full corpus must state its own denominator in its own
    /// report, not just in source comments. Under v9/v10 that gap was real (120/1236 cells,
    /// `TestDocs/ws7` could not grow further from this environment — the private Sawyer corpus
    /// `output-manifest-v9.json` was generated against was not reachable here, same wall job
    /// 266's ground-truth attempt hit).
    ///
    /// Job 426 (v11 RESCOPE): the manifest itself was regenerated scoped to this repo's own
    /// bundled corpus (19 files, 228 cells) rather than the separate private tree — so
    /// `full == bundled` now and the gap this test exists to catch is currently zero. Tier 2
    /// (`tier2DocumentOperationsMatchesOracle`, `CTRLKD_PRIVATE_CORPUS`-gated) and the
    /// full-archive sweep remain wired but currently have nothing left to cover beyond this suite.
    ///
    /// Job 498 (`DARKNESS.WS` removed as a fixture, Jon's ruling): 18/216, both pins moving
    /// together, keeps `full == bundled` — see this file's own header comment's "v12 addendum".
    ///
    /// Three hard pins below (`fullManifestNonSkippedCellCount` 216, bundled fixtures 18,
    /// bundled cells 216) — any drifting deserves a deliberate look (a manifest regen, or a
    /// real corpus-subset expansion landing), not a report quietly going stale, per this test's
    /// own name. The scope STATEMENT itself is a `withKnownIssue`, per this repo's documented
    /// pattern for getting message text into a PASSING run's report (the internal release runbook (not part of this repo)'s
    /// "Worker notes": "passing Swift Testing cases swallow print()... diagnostic output only
    /// via a forced-fail probe or withKnownIssue message text").
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func fullDenominatorLawStatesThisSuitesRealScopeAgainstTheFullManifestCorpus() throws {
        let full = Self.fullManifestNonSkippedCellCount
        #expect(full == 216,
                "the full manifest-v11 corpus denominator changed (\(full)) — a manifest regen landed; update every pinned count in this test deliberately, don't just silence it")

        let bundledFixtures = Self.ws7FixturesInManifest.count
        let bundledCells = Self.tier1Cells.count
        #expect(bundledFixtures == 18,
                "TestDocs/ws7's manifest-matched fixture count changed (\(bundledFixtures)) — if this grew, expand tier1Cells' surface coverage to match; if it shrank, find out why")
        #expect(bundledCells == 216,
                "TestDocs/ws7's own reachable non-skipped cell count changed (\(bundledCells)) — update this pinned count deliberately")
    }

    // MARK: - Structural gaps (documented, not bugs — excluded from the cells above)

    /// If this ever starts failing, someone added `.layout` to `ExportFormat` — extend
    /// `tier1CellsForExportEngine` to cover it instead of leaving the 24 layout cells
    /// permanently unexercised on surface (c).
    @Test func exportEngineHasNoLayoutRoute() {
        #expect(ExportFormat(rawValue: "layout") == nil,
                "ExportFormat gained a .layout case — surface (c)'s Tier-1 coverage needs updating")
    }

    /// Guards that the accepted PDF+Modern divergence (`ExportEngine.render`'s own doc
    /// comment) stays real: AppKit-rendered, non-empty, and NOT byte-identical to the
    /// library's own oracle-matching PDF. If this starts matching, `modernPDF` may have
    /// silently regressed to the library emitter, which would be a real loss (Courier-only,
    /// not the user's chosen font) masquerading as a pass.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func exportEnginePDFModernIsADocumentedAppKitDivergence() throws {
        let fixtureName = "OLDTIMES.WS"
        let key = try Self.manifestKey(forWS7Fixture: fixtureName)
        let expected = try Self.expectedSHA(manifestKey: key, format: "pdf", mode: .modern)
        let actual = try Self.exportEngineBytes(fixtureName: fixtureName, format: .pdf, mode: .modern)
        #expect(!actual.isEmpty, "ExportEngine's Modern PDF export must not be empty")
        #expect(Self.sha256Hex(actual) != expected,
                "ExportEngine's Modern PDF unexpectedly matches the library oracle byte-for-byte — re-verify modernPDF is still routing through AppKit, not the library emitter")
    }

    // MARK: - Option axis spot-checks (rule 3: pin defaults to the oracle's bare-CLI
    // defaults — already what Tier 1 above exercises — then ONE non-default check per axis)

    /// A real `..`-syntax comment note (`Document.swift`'s `NoteOrigin.dotDot`), same
    /// construction UIRound4ARulingTests' `modernSuperscriptFixedPNGCapturesARealFnrefMark`
    /// uses for a real `fnref` mark — forced `.ws4` since plain-ASCII auto-detection is not
    /// guaranteed to land on the dot-command parser.
    private static let commentMarkerText = "a genuinely WordStar-native comment note"
    private static func commentNoteDocumentBytes() -> [UInt8] {
        let source = """
            A line before the mark, plain and unremarkable.
            ..This line plants \(commentMarkerText).
            A line after the mark.
            """
        return [UInt8](source.utf8)
    }

    private static func documentOperationsString(
        bytes: [UInt8], format: String, notes: Set<NoteKind> = EmitOptions.defaultNotes,
        noteRefs: NoteRefs = .word
    ) throws -> String {
        let options = DocumentOperations.ConversionOptions(
            formats: [format], mode: .modern, variant: .ws4, notes: notes, noteRefs: noteRefs)
        let result = try DocumentOperations.convert(data: bytes, options: options)
        return String(decoding: result.first?.bytes ?? [], as: UTF8.self)
    }

    /// Axis: notes on/off. CLI equivalence: bare `sr` resolves to `EmitOptions.defaultNotes`
    /// (footnote/endnote/annotation, never comment — WordStar itself never printed a
    /// comment); `sr --comments FILE` resolves to `.allNotes` (`Arguments.swift`'s
    /// `commentsRequested`/`parseArguments`'s `noNotes`/`comments` resolution). Tier 1 above
    /// already pins the DEFAULT (every oracle cell used the bare set); this is the ONE
    /// non-default spot-check, citing `EmitOptions.notes`'s own doc comment: "Excluding a
    /// kind removes its inline marker too, not just the trailing entry."
    @Test func notesAxisDefaultHidesACommentAllNotesShowsIt() throws {
        let bytes = Self.commentNoteDocumentBytes()
        let bareDefault = try Self.documentOperationsString(bytes: bytes, format: "text")
        let comments = try Self.documentOperationsString(bytes: bytes, format: "text", notes: EmitOptions.allNotes)
        #expect(!bareDefault.contains(Self.commentMarkerText),
                "bare sr (EmitOptions.defaultNotes) must never show a comment-kind note")
        #expect(comments.contains(Self.commentMarkerText),
                "sr --comments (.allNotes) must show it in the trailing Comments section")
    }

    /// Axis: `--note-refs`. `word` (Tier 1's default) and `prefixed` only differ where a
    /// format actually reads `EmitOptions.noteRefs` — `text`/`markdown` ignore it
    /// (`EmitOptions.noteRefs`'s own doc comment: "the flat formats... ignore it"), so this
    /// checks `html`, one of the Modern paths that reads it. `EmitHTML.swift`'s
    /// `htmlBodySpan`: a comment's inline anchor is entirely absent under `word` (M9 —
    /// "markless") and a visible `role="doc-noteref">c1<` anchor under `prefixed`
    /// (`noteRefLabels`'s `"c" + String(k)`, ruling 2026-08-06 M8) — `sr --note-refs
    /// prefixed`'s equivalent.
    @Test func noteRefsAxisWordSuppressesPrefixedShowsACommentAnchor() throws {
        let bytes = Self.commentNoteDocumentBytes()
        let word = try Self.documentOperationsString(bytes: bytes, format: "html", notes: EmitOptions.allNotes, noteRefs: .word)
        let prefixed = try Self.documentOperationsString(bytes: bytes, format: "html", notes: EmitOptions.allNotes, noteRefs: .prefixed)
        #expect(!word.contains("role=\"doc-noteref\""),
                "word scheme must show no inline anchor for a markless comment note")
        #expect(prefixed.contains("role=\"doc-noteref\">c1<"),
                "prefixed scheme must label the comment note's inline anchor \"c1\"")
    }

    /// Axis: `--page-settings`. Tier 1's bare `pageSettings: nil` is the oracle's own
    /// default; this is the CLI's own named `sawyer` preset (`Arguments.swift`'s
    /// `pagePresets`, `sr --page-settings sawyer LETTER` in its own `--help` examples),
    /// applied through the identical `DocumentOperations.PageSettingsPreset.sawyer` a real
    /// AppleScript `page settings` argument resolves to (`PageSettingsScripting.resolve`).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func pageSettingsAxisSawyerPresetChangesPrintedPDFGeometry() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent("OLDTIMES.WS")))
        let bare = try DocumentOperations.convert(
            data: bytes, options: DocumentOperations.ConversionOptions(formats: ["pdf"], mode: .printed))
        let sawyer = try DocumentOperations.convert(
            data: bytes, options: DocumentOperations.ConversionOptions(
                formats: ["pdf"], mode: .printed,
                pageSettings: DocumentOperations.PageSettingsPreset.sawyer.settings))
        #expect(bare.first?.bytes != sawyer.first?.bytes,
                "sr --page-settings sawyer must change the printed PDF's geometry vs. the oracle's bare default")
    }

    // MARK: - Tier 2 — full corpus, env-gated, DocumentOperations only (brief rule 2:
    // "report counts, don't run in the normal gate")

    /// Same env-gate shape as `OracleByteParityTests.corpusRoot` — `CTRLKD_PRIVATE_CORPUS`,
    /// unset in the normal gate, so this tier is a clean no-op there.
    ///
    /// Jon's ruling, 2026-08-19 ("Go with A"), a dated delegation of division of labor: the
    /// full-corpus truth is the full-archive engine sweep (1236/1236 byte-exact, run outside this
    /// repo), not this in-repo gate; this repo's own truth is the Tier-1 120-cell subset
    /// (`tier1Cells`, exercised by `documentOperationsMatchesOracle` above). This tier
    /// (`tier2DocumentOperationsMatchesOracle`) staying a clean env-gated no-op here is the
    /// RULED shape of that division, not undone coverage debt.
    static var corpusRoot: URL? {
        ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"].map(URL.init(fileURLWithPath:))
    }

    struct Tier2Cell: Sendable, CustomStringConvertible {
        let manifestKey: String
        let format: String
        let mode: EmitMode
        var description: String { "\(manifestKey) \(format).\(mode.rawValue)" }
    }

    /// Every (file, format.mode) cell with a real sha256 — empty (zero test cases, clean
    /// skip) whenever `corpusRoot` is nil, exactly like Tier 1's own Tier 2.
    static var tier2Cells: [Tier2Cell] {
        guard corpusRoot != nil else { return [] }
        var result: [Tier2Cell] = []
        for (fileKey, cells) in OutputManifest.files {
            for format in OutputManifest.formats {
                for mode: EmitMode in [.modern, .printed] {
                    let cellKey = "\(format).\(mode.rawValue)"
                    if cells[cellKey]?.sha256 != nil {
                        result.append(Tier2Cell(manifestKey: fileKey, format: format, mode: mode))
                    }
                }
            }
        }
        return result
    }

    @Test(arguments: tier2Cells) func tier2DocumentOperationsMatchesOracle(cell: Tier2Cell) throws {
        guard let root = Self.corpusRoot else { return }
        let expected = try Self.expectedSHA(manifestKey: cell.manifestKey, format: cell.format, mode: cell.mode)
        let cellURL = root.appendingPathComponent(cell.manifestKey)
        let bytes = [UInt8](try Data(contentsOf: cellURL))
        let options = DocumentOperations.ConversionOptions(
            formats: [cell.format], mode: cell.mode, docPath: cellURL.path)
        let produced = try DocumentOperations.convert(data: bytes, options: options)
        let actual = try #require(produced.first).bytes
        #expect(Self.sha256Hex(actual) == expected, "\(cell.description) diverged from the oracle")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputParityTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
