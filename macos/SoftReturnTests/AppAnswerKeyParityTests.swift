import CryptoKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// JOB 2(a): ONE ANSWER KEY.
///
/// The app's conversion surfaces are checked against the SAME answer key `sr`'s own
/// `AnswerKeyParityTests` uses — ctrl-kd's `tests/answer_key.json` for the public corpus,
/// with `TestDocs/oracle/answer_key_private.json` as the private overlay — rather than
/// against `TestDocs/oracle/output-manifest-v12.json`, a second, app-only recording of the
/// same quantity.
///
/// WHY THIS REPLACES THE MANIFEST AS THE ORACLE. The manifest was a snapshot of ctrl-kd's
/// output taken by this repo, on a build host, at a pin. That made it a THIRD artefact
/// tracking the same truth as ctrl-kd's own key and sr's own parity suite, and the failure
/// mode is the one job 423 and job 426 both actually hit: the manifest went stale against an
/// engine that had legitimately moved, and the suite then reported an engine-vs-stale-oracle
/// gap as an app defect. One key means the app is measured against the same bytes the engine
/// is, so a real cross-engine move shows up once, in one place, and an app-only divergence is
/// unambiguous when it appears.
///
/// The key is keyed by document and by `<format>.<mode>` cell, each carrying `bytes` and
/// `sha256` of the emitter's output with every option at its library default — see the key's
/// own `options` field, which states that contract.
///
/// WHERE THE KEY COMES FROM. `CTRLKD_SRC` (or `TEST_RUNNER_CTRLKD_SRC`, which is how
/// `xcodebuild` forwards an environment variable into the test host — it only passes
/// `TEST_RUNNER_`-prefixed names through) points at a ctrl-kd checkout;
/// `~/projects/ctrl-kd` is the default. When the file is not there this suite SKIPS BY NAME
/// with that exact reason. It never passes vacuously: a skip says which variable to set and
/// which path it looked at.
@Suite struct AppAnswerKeyParityTests {

    // MARK: - Locating the key

    /// The ctrl-kd checkout, from `CTRLKD_SRC` / `TEST_RUNNER_CTRLKD_SRC`, else the
    /// conventional clone location.
    /// `CTRLKD_SRC` names ctrl-kd's `src/` directory, not its root — see
    /// `PrivateCorpusSupport.ctrlkdCheckoutRoot(default:)`, which owns that rule.
    static var ctrlkdSourceRoot: URL {
        PrivateCorpusSupport.ctrlkdCheckoutRoot(
            default: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("projects/ctrl-kd", isDirectory: true))
    }

    static var publicKeyURL: URL { ctrlkdSourceRoot.appendingPathComponent("tests/answer_key.json") }

    static var privateKeyURL: URL {
        PrivateCorpusSupport.oracleDirectory.appendingPathComponent("answer_key_private.json")
    }

    static var hasKey: Bool { FileManager.default.fileExists(atPath: publicKeyURL.path) }

    /// BOTH halves are needed: the key says what the bytes should be, and the private corpus
    /// is where the documents to convert live. Gating on the key alone would turn a missing
    /// corpus into a pile of file-not-found FAILURES instead of a named skip.
    static var isArmed: Bool { hasKey && PrivateCorpusSupport.isArmed }

    static var skipReason: Comment {
        if !hasKey {
            return """
            no ctrl-kd answer key at \(publicKeyURL.path) — set CTRLKD_SRC (or \
            TEST_RUNNER_CTRLKD_SRC, which is how xcodebuild forwards a variable into the test \
            host) to a ctrl-kd checkout, or clone one to ~/projects/ctrl-kd. NOT a pass: \
            these cells were not checked.
            """
        }
        return """
        ctrl-kd's answer key is present, but the private corpus is not: set \
        CTRLKD_PRIVATE_CORPUS to a soft-return-corpus clone (see docs/TESTING.md). NOT a \
        pass: these cells were not checked.
        """
    }

    // MARK: - The key

    struct Cell: Decodable, Sendable { let bytes: Int; let sha256: String }

    /// Where a key entry's document actually lives. Mirrors `sr`'s own
    /// `AnswerKeyDocSource` exactly: bundled samples ship in the app, Sawyer documents are
    /// relative to `$CTRLKD_SAWYER_ARCHIVE`, and the private overlay's `path` is already
    /// relative to the corpus root (it carries its own group directory).
    enum DocSource: Sendable {
        case bundledSample(String)
        case sawyer(relativePath: String)
        case privateCorpus(relativePath: String)

        /// The document's real on-disk location. It is the load path AND the `docPath` the
        /// picture axis resolves `.PIX` siblings against — ctrl-kd's own `_doc_entry(doc,
        /// doc_path)` resolves against the document's real path, so anything else would
        /// silently record the unresolved placeholder for the 7 picture-bearing documents.
        var url: URL? {
            switch self {
            case .bundledSample(let name):
                return PrivateCorpusSupport.ws7Directory.appendingPathComponent(name)
            case .sawyer(let relative):
                return PrivateCorpusSupport.sawyerArchiveRoot?.appendingPathComponent(relative)
            case .privateCorpus(let relative):
                return PrivateCorpusSupport.privateCorpusRoot?.appendingPathComponent(relative)
            }
        }
    }

    /// One document in a key: its cells, and — for a picture-bearing document — the second
    /// grid recorded at `pictures=off`. `cellsPicturesOff` is empty for everything else,
    /// which is how the pictures axis stays a fact about the key rather than a list here.
    struct DocEntry: Sendable {
        let name: String
        let source: DocSource
        let cells: [String: Cell]
        let cellsPicturesOff: [String: Cell]
    }

    /// Parsed by hand rather than `Decodable`: the two keys put their documents under
    /// different group keys (`docs` for the public samples, `convertible` for Sawyer and for
    /// every private group) and carry `known_nonconvertible`/`non_document_assets` siblings
    /// that are NOT grid documents. A `Decodable` shape that tolerated all of that would be
    /// looser than the thing it is checking.
    static func documents(inKeyAt url: URL, privateOverlay: Bool) throws -> [DocEntry] {
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        guard let root = raw as? [String: Any], let groups = root["groups"] as? [String: Any]
        else { throw ExportProbeError.noProduct("\(url.path): not an answer key (no groups)") }

        var out: [DocEntry] = []
        for (groupName, rawGroup) in groups {
            guard let group = rawGroup as? [String: Any] else { continue }
            // `known_nonconvertible` and `non_document_assets` are deliberately skipped: they
            // carry no `cells` grid. `sr`'s own suite checks their source hashes and their
            // .notConvertible behaviour separately; this suite is the grid.
            for subKey in ["docs", "convertible"] {
                guard let entries = group[subKey] as? [String: Any] else { continue }
                for (name, rawEntry) in entries {
                    guard let entry = rawEntry as? [String: Any],
                          let cells = cellGrid(entry["cells"]) else { continue }
                    let source: DocSource
                    if let path = entry["path"] as? String {
                        source = privateOverlay ? .privateCorpus(relativePath: path)
                                                : .sawyer(relativePath: path)
                    } else {
                        // Only the public `samples` group omits `path` — those four ship
                        // with the app, so the key names the file directly.
                        guard groupName == "samples" else { continue }
                        source = .bundledSample(name)
                    }
                    out.append(DocEntry(name: name, source: source, cells: cells,
                                        cellsPicturesOff: cellGrid(entry["cells_pictures_off"]) ?? [:]))
                }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func cellGrid(_ raw: Any?) -> [String: Cell]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var out: [String: Cell] = [:]
        for (name, value) in dict {
            guard let cell = value as? [String: Any],
                  let bytes = cell["bytes"] as? Int,
                  let sha = cell["sha256"] as? String else { continue }
            out[name] = Cell(bytes: bytes, sha256: sha)
        }
        return out
    }

    // MARK: - The app's own bytes

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// One export through `ExportEngine` — the library path the app's own Export command
    /// uses, and the surface this gate is about.
    @MainActor
    static func exportBytes(fixture: URL, format: ExportFormat, mode: EmitMode) throws -> [UInt8] {
        let bytes = [UInt8](try Data(contentsOf: fixture))
        let defaults = UserDefaults(suiteName: "AppAnswerKeyParityTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        let title = fixture.deletingPathExtension().lastPathComponent
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [format],
            notes: NoteSelection(), style: mode == .modern ? .modern : .native,
            title: title, docPath: fixture.path)
        guard let product = products.first else {
            throw ExportProbeError.noProduct("\(fixture.lastPathComponent) \(format.rawValue).\(mode)")
        }
        return product.bytes
    }

    enum ExportProbeError: Error { case noProduct(String) }

    /// The app has THREE conversion surfaces, and the retired manifest suite checked all
    /// three. Losing two of them while retiring the oracle would have been a real reduction
    /// in coverage dressed up as a cleanup, so all three are still checked here — see the
    /// gate below for how: `documentOperations` carries the cross-engine answer-key claim
    /// (it is the only one that can be called the key's way), and the other two are pinned
    /// byte-for-byte to it under their own ruled options.
    ///
    /// They are genuinely different code paths, not wrappers: `DocumentOperations.convert`
    /// is the shared layer, `ConvertCommand` is the batch/AppleScript entry point that
    /// writes real files to a destination folder, and `ExportEngine.render` is what the
    /// Export menu drives. Job 262 exists because an app-level knob (there, `fontsTarget`)
    /// diverged from a correct engine underneath it on ONE of these and not the others.
    enum Surface: String, CaseIterable, Sendable {
        case documentOperations
        case convertCommand
        case exportEngine
    }

    /// `DocumentOperations.convert` — the shared layer, and the ONE surface that can be
    /// called the way the answer key was recorded, because it exposes both options that
    /// matter (`title`, `fontsTarget`) instead of pinning them.
    ///
    /// The caller supplies both deliberately. An earlier version of this file passed the
    /// file's stem as `title` on the claim that "the answer key was generated by `sr`, which
    /// does the same". That claim was wrong, and the first armed run proved it: 36 of 108
    /// cells failed, every HTML cell by exactly `len(stem)` bytes (OCAPTAIN/TWAINLET/
    /// WARPRAYR +8, LYING +5 — the width of `<title>STEM</title>` minus `<title></title>`).
    /// ctrl-kd's `tools/answer_key.py` records each cell as `<emitter>(doc, mode=mode,
    /// pictures=…, pix_results=…)` with ZERO other keyword arguments, which is a bare
    /// library call carrying no title at all — reproduced exactly here before this change.
    static func documentOperationsBytes(fixture: URL, format: String, mode: EmitMode,
                                        title: String, fontsTarget: FontsTarget,
                                        pictures: EmitOptions.PixMode) throws -> [UInt8] {
        let bytes = [UInt8](try Data(contentsOf: fixture))
        // `docPath` matters even though the four bundled samples carry no picture: the
        // answer key is recorded with pictures RESOLVED (planning #211), so a picture-bearing
        // document added to this suite later would silently diverge on this surface alone
        // without it. The other two surfaces already have a real path to resolve against.
        let options = DocumentOperations.ConversionOptions(
            formats: [format], mode: mode, title: title, fontsTarget: fontsTarget,
            docPath: fixture.path, pictures: pictures)
        let result = try DocumentOperations.convert(data: bytes, options: options)
        guard let first = result.first else {
            throw ExportProbeError.noProduct("\(fixture.lastPathComponent) \(format).\(mode)")
        }
        return first.bytes
    }

    /// `ConvertCommand` — the batch surface. Copies the document, and its `INSET/` sibling
    /// when there is one, into a temp directory and converts there, so pictures resolve the
    /// same way they do for a real user and nothing is written beside the corpus.
    @MainActor
    static func convertCommandBytes(fixture: URL, format: String, mode: EmitMode) throws -> [UInt8] {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppAnswerKeySource-\(UUID().uuidString)", isDirectory: true)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppAnswerKeyOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let copy = sourceDir.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let inset = fixture.deletingLastPathComponent().appendingPathComponent("INSET")
        if FileManager.default.fileExists(atPath: inset.path) {
            try FileManager.default.copyItem(at: inset, to: sourceDir.appendingPathComponent("INSET"))
        }

        let args = ConvertCommand.Arguments(
            inputs: [copy], destinationFolder: outDir, formats: [format], mode: mode,
            searchingSubfolders: false, forcingVariant: nil, pageSettings: nil)
        let result = ConvertCommand.convert(files: [copy], args: args)
        guard let produced = result.produced.first else {
            throw ExportProbeError.noProduct(
                "\(fixture.lastPathComponent) \(format).\(mode): skipped=\(result.skipped) "
                    + "failed=\(result.failed.count)")
        }
        return [UInt8](try Data(contentsOf: produced))
    }

    /// The four bundled public-domain samples, which need no private corpus and are named in
    /// the public key's own `samples` group.
    /// The four bundled public-domain samples, which need no private corpus and are named in
    /// the public key's own `samples` group.
    static let bundledSamples = ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"]

    struct ExportCell: CustomStringConvertible, Sendable {
        let document: String
        let source: DocSource
        let format: ExportFormat
        let mode: EmitMode
        let surface: Surface
        let pictures: EmitOptions.PixMode
        let expected: Cell
        var keyName: String { "\(format.rawValue).\(mode == .modern ? "modern" : "printed")" }
        var description: String {
            "\(document) \(keyName) [\(surface.rawValue)]"
                + (pictures == .off ? " (pictures off)" : "")
        }
    }

    /// The key's six formats against the app's five. `layout` is ctrl-kd's own inspection
    /// dump; the app registers no such export format (`ExportFormat` is text/markdown/html/
    /// rtf/pdf), so those cells are outside the app's surface by construction rather than by
    /// choice. Named here so the gap reads as an absence of surface, not a skipped test.
    static func appFormat(forKeyName name: String) -> ExportFormat? {
        ExportFormat.allCases.first { $0.rawValue == name }
    }

    /// EVERY cell of both keys that the app has a surface for, on `documentOperations`,
    /// plus the three-surface cross-check on the bundled samples.
    ///
    /// Scope, stated precisely because "the same tests" is the standard:
    ///   - public key: 389 documents (4 bundled samples + 385 Sawyer convertibles)
    ///   - private overlay: 77 documents (fixtures-ws5, jon-floppies, ws7-private)
    ///   - the pictures axis: the 7 picture-bearing documents' `cells_pictures_off` grid too
    ///   - MINUS `layout` (no app surface, see `appFormat`) and MINUS `pdf.modern` (ruled
    ///     AppKit divergence, owned by `ExportSurfaceTests
    ///     .exportEnginePDFModernIsADocumentedAppKitDivergence`)
    ///
    /// The two product surfaces stay on the bundled samples. Their job is to catch an app
    /// knob drifting between surfaces — job 262's actual bug — and they are pinned to the
    /// shared layer, not to the key, so walking 466 documents three times would multiply
    /// runtime without adding a claim the shared layer's own walk doesn't already make.
    static var allCells: [ExportCell] {
        guard isArmed else { return [] }
        var out: [ExportCell] = []
        var entries: [DocEntry] = (try? documents(inKeyAt: publicKeyURL, privateOverlay: false)) ?? []
        entries += (try? documents(inKeyAt: privateKeyURL, privateOverlay: true)) ?? []

        for entry in entries {
            let isBundledSample = bundledSamples.contains(entry.name)
            for (grid, pictures) in [(entry.cells, EmitOptions.PixMode.embed),
                                     (entry.cellsPicturesOff, EmitOptions.PixMode.off)] {
                for (keyName, expected) in grid {
                    let parts = keyName.split(separator: ".")
                    guard parts.count == 2, let format = appFormat(forKeyName: String(parts[0]))
                    else { continue }
                    let mode: EmitMode = parts[1] == "modern" ? .modern : .printed
                    if format == .pdf, mode == .modern { continue }

                    out.append(ExportCell(document: entry.name, source: entry.source,
                                          format: format, mode: mode,
                                          surface: .documentOperations, pictures: pictures,
                                          expected: expected))
                    guard isBundledSample, pictures == .embed else { continue }
                    for surface in [Surface.convertCommand, .exportEngine] {
                        out.append(ExportCell(document: entry.name, source: entry.source,
                                              format: format, mode: mode, surface: surface,
                                              pictures: pictures, expected: expected))
                    }
                }
            }
        }
        return out.sorted { $0.description < $1.description }
    }

    // MARK: - The gate

    @Test(.enabled(if: isArmed, skipReason), arguments: allCells)
    @MainActor func exportMatchesTheAnswerKey(cell: ExportCell) throws {
        let expected = cell.expected
        let fixture = try #require(cell.source.url,
                                   "\(cell): the corpus root for this document's group is not set")
        try #require(FileManager.default.fileExists(atPath: fixture.path),
                     "\(cell): the key names this document but it is not on disk at \(fixture.path)")
        let stem = fixture.deletingPathExtension().lastPathComponent

        switch cell.surface {
        case .documentOperations:
            // THE CROSS-ENGINE CHECK. Called exactly the way ctrl-kd recorded the key and
            // the way `sr`'s own `AnswerKeyParityTests` calls the engine — that suite's
            // header states the rule outright: "called the SAME way (bare emitter call,
            // default `EmitOptions()`, no CLI, no `--fonts mac`)". Holding the options equal
            // is what makes a byte comparison mean anything; a cell rendered with different
            // options and then compared byte-for-byte is not a stricter test, it is a test
            // of the options.
            let actual = try Self.documentOperationsBytes(
                fixture: fixture, format: cell.format.rawValue, mode: cell.mode,
                title: "", fontsTarget: .office, pictures: cell.pictures)
            #expect(actual.count == expected.bytes,
                    "\(cell): app produced \(actual.count) bytes, answer key says \(expected.bytes)")
            #expect(Self.sha256Hex(actual) == expected.sha256,
                    "\(cell): app bytes diverge from ctrl-kd's answer key")

        case .convertCommand, .exportEngine:
            // THE SURFACE CHECK. These two CANNOT be called the key's way, and that is ruled,
            // not accidental: `ConvertCommand` hardcodes `title: file.stem` (every real batch
            // caller wants it), and `ExportEngine` pins `fontsTarget: .mac` unconditionally
            // — Jon's ruling 2026-08-11, "We are ON the Mac", cited at its own call site.
            // `sr` defaults to `.mac` for the same stated reason, so this is the ENGINE's
            // behaviour too, not an app knob that drifted; ctrl-kd's library default is
            // `.office`, which is the only reason the key differs at all.
            //
            // So they are pinned to the shared layer rendered with THEIR ruled options. That
            // keeps all three surfaces checked — job 262 is exactly the bug where an app
            // knob diverged on one surface and not the others — while the cross-engine claim
            // rests on the surface that can honestly make it. Nothing is excluded and no
            // divergence is absorbed: a real difference on either surface still fails here.
            let actual = cell.surface == .convertCommand
                ? try Self.convertCommandBytes(fixture: fixture, format: cell.format.rawValue,
                                               mode: cell.mode)
                : try Self.exportBytes(fixture: fixture, format: cell.format, mode: cell.mode)
            let reference = try Self.documentOperationsBytes(
                fixture: fixture, format: cell.format.rawValue, mode: cell.mode,
                title: stem, fontsTarget: .mac, pictures: cell.pictures)
            #expect(actual == reference, """
                \(cell): this surface diverges from DocumentOperations rendered with the same \
                ruled options (title=\"\(stem)\", fonts=.mac) — \(actual.count) bytes here vs \
                \(reference.count) there. The shared layer's own answer-key cell is checked \
                separately, so a failure HERE is this surface's own wiring, not the engine.
                """)
        }
    }

    /// The private overlay is a real file in this repo, so its SHAPE can be checked even
    /// unarmed — a malformed or empty overlay is a silent hole in the private half of the
    /// same key, and this is what makes that loud.
    @Test func theKeysAreWellFormedAndNameRealDocuments() throws {
        let privateDocs = try Self.documents(inKeyAt: Self.privateKeyURL, privateOverlay: true)
        #expect(privateDocs.count == 77, """
            the private overlay at \(Self.privateKeyURL.path) names \(privateDocs.count) \
            documents, not the 77 its own counts block declares
            """)

        guard Self.hasKey else { return }
        let publicDocs = try Self.documents(inKeyAt: Self.publicKeyURL, privateOverlay: false)
        #expect(publicDocs.count == 389, """
            ctrl-kd's answer key names \(publicDocs.count) documents, not the 389 its own \
            counts block declares (4 samples + 385 Sawyer convertibles)
            """)
        for sample in Self.bundledSamples {
            #expect(publicDocs.contains { $0.name == sample },
                    "\(sample) is bundled with this app but absent from ctrl-kd's answer key")
        }
        #expect(publicDocs.filter { !$0.cellsPicturesOff.isEmpty }.count == 7,
                "the key's pictures axis should carry 7 picture-bearing documents")
    }

    /// The grid must not be allowed to go quietly empty. Every widening of this suite so far
    /// has been undone by something upstream — a mis-read environment variable, a key whose
    /// group shape moved — and a parametrized test with zero arguments PASSES. This asserts
    /// the size of what actually ran, so a collapse is a failure and not a green tick.
    @Test(.enabled(if: isArmed, skipReason)) func theGridCoversTheWholeKey() throws {
        let cells = Self.allCells
        let shared = cells.filter { $0.surface == .documentOperations }
        // 466 documents (389 public + 77 private) x 5 app formats x 2 modes, minus the ruled
        // pdf.modern cell for each = 466 x 9 = 4194, plus the 7 picture-bearing documents'
        // pictures-off grid at the same 9 = 63. `layout` has no app surface at all.
        #expect(shared.count == 4257, """
            the shared-layer grid holds \(shared.count) cells, expected 4257 \
            (466 documents x 9 checked cells + 63 pictures-off). If the key legitimately \
            grew, update this number in the same commit that proves the new cells pass.
            """)
        #expect(cells.count - shared.count == 72, """
            the surface cross-check holds \(cells.count - shared.count) cells, expected 72 \
            (4 bundled samples x 9 cells x 2 product surfaces)
            """)
    }
}
