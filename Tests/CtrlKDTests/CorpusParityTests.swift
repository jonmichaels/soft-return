import Foundation
import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

/// Planning #193 (Jon, 2026-09-05, verbatim): "Sr on its own needs to pass the same
/// tests." ctrl-kd's public Sawyer tier converts every entry of its manifest and checks
/// it against recorded answers (source hash, convert+match oracle, known-nonconvertible)
/// — 532 cases, run with a bare `pytest -m sawyer` against ctrl-kd itself, no app or Xcode
/// involved. This suite is the Swift engine's own equivalent for the ONE geometry that
/// still needs a dedicated check after planning #205 Task 2's retirement of
/// `TestDocs/oracle/python-printed-manifest.json`.
///
/// ## History — what changed 2026-09-06, and why
///
/// Before planning #205a (ctrl-kd `6741c10`, "answer key covers the full Sawyer corpus, not
/// a hand-picked subset"), ctrl-kd's shared answer key (`tests/answer_key.json`,
/// `AnswerKeyParityTests.swift`) named only 245 documents (4 samples + 241 curated Sawyer
/// "catalog" entries) — far short of `python-printed-manifest.json`'s then-308-entry
/// documents-only walk of the real archive tree, so retiring that manifest would have
/// silently dropped 133 real, convertible files from Printed-PDF coverage. That is WHY this
/// file's own header used to say the two oracles were "kept, not retired" (2026-09-06
/// investigation, preserved in git history — `git log -p` on this file for the full
/// account). Once the answer key grew to cover the FULL public Sawyer corpus (385
/// convertible + 4 samples + 10 known-nonconvertible + 1 non-document asset = every file
/// `python-printed-manifest.json` walked, and more), that condition was met:
/// `AnswerKeyParityTests`'s `pdf.printed` cell is now a strict superset of
/// `python-printed-manifest.json`'s `bare` geometry (both are `EmitOptions()` defaults, no
/// page-settings override, no real `.PIX` resolution — empty `pixResults` renders any
/// `.PIX` reference as an identical placeholder on both sides), so `bare` needed no
/// replacement at all: it is simply covered, and `corpusBareByteParity` was deleted here
/// along with the manifest and its generator
/// (`macos/scripts/generate_printed_oracle_manifest.py`).
///
/// ## What this suite still checks, and against what
///
/// The manifest's OTHER geometry, `sawyer` (`pagePresets["sawyer"]` applied — Robert J.
/// Sawyer's own WSCHANGE-recovered machine settings — PLUS real `resolveDocumentPictures`
/// against the live archive tree, so `.PIX` references actually embed instead of rendering
/// as a placeholder), has NO equivalent in the answer key: that key's own docs are explicit
/// it "never applies" a page-settings preset (`docs/TESTING.md`). Retiring the manifest
/// therefore left that ONE geometry with no recording anywhere, public or private. This
/// suite now checks it against `TestDocs/oracle/sawyer_preset_pdf_sr.json` — a NEW,
/// SELF-RECORDED file (`Sources/GenerateSawyerPresetDriftSR/main.swift`, `swift run
/// generate-sawyer-preset-drift-sr`), same honesty class as ctrl-kd's own answer key and
/// this repo's `answer_key_sr.json`: it records sr's OWN output for this geometry, over
/// EVERY document ctrl-kd's answer key names as Sawyer-convertible (385, "re-based on the
/// key's documents" — this generator reads `tests/answer_key.json` purely as a doc/path
/// LIST, the same list `AnswerKeyParityTests`/`generate-answer-key-sr` use, so the three
/// can never silently disagree about corpus scope). A mismatch here means sr's OWN
/// rendering of this geometry has drifted since the file was last (deliberately)
/// regenerated — it proves NOTHING about cross-engine correctness (that is
/// `AnswerKeyParityTests`, over the bare geometry, above); regenerating and reviewing the
/// diff is the correct response to an intentional change, never hand-editing a cell.
///
/// ## Gating
/// `CTRLKD_SAWYER_ARCHIVE` (`sawyerArchivePath`/`sawyerArchiveArmed`/`sawyerArchiveSkipReason`
/// — declared once in `WSChangeTests.swift`, reused verbatim here): the recorded file is
/// committed in-repo (no `CTRLKD_SRC` needed to find it — same shape as the private answer
/// key overlay) but its cells are only checked against real rendered bytes once the archive
/// is armed. Unarmed: `corpusParityGateIsArmed` below is the ONE named, recorded Skip; the
/// parameterized test collapses to zero collected cases rather than 385 individual skips.
/// Armed but the recorded file itself is missing or unparsable: FAILS LOUD (a broken repo
/// state, not a legitimate skip) — same doctrine as every other committed oracle in this
/// tier.
enum SawyerPresetDriftFixture {
    struct PixEntry {
        let tag: String
        let resolved: Bool
    }

    struct Cell {
        let sha256: String
        let bytes: Int
        let pix: [PixEntry]
    }

    struct DocEntry {
        let path: String
        let sourceSHA256: String
        let cell: Cell
    }

    /// `Tests/CtrlKDTests/CorpusParityTests.swift` -> repo root is three levels up — same
    /// arithmetic every other `#filePath`-relative lookup in this repo uses.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestDocs/oracle/sawyer_preset_pdf_sr.json")

    private static func pixList(_ raw: Any?) -> [PixEntry] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let tag = entry["tag"] as? String, let resolved = entry["resolved"] as? Bool
            else { return nil }
            return PixEntry(tag: tag, resolved: resolved)
        }
    }

    private static func docEntry(_ raw: Any?) -> DocEntry? {
        guard let dict = raw as? [String: Any],
              let path = dict["path"] as? String,
              let sourceSHA256 = dict["source_sha256"] as? String,
              let cells = dict["cells"] as? [String: Any],
              let cellDict = cells["pdf.sawyer_preset.printed"] as? [String: Any],
              let sha256 = cellDict["sha256"] as? String,
              let bytes = cellDict["bytes"] as? Int
        else { return nil }
        let cell = Cell(sha256: sha256, bytes: bytes, pix: pixList(cellDict["pix"]))
        return DocEntry(path: path, sourceSHA256: sourceSHA256, cell: cell)
    }

    private static let loadResult: (docs: [String: DocEntry]?, failure: String?) = {
        guard let data = try? Data(contentsOf: url) else {
            return (nil, "could not read \(url.path) — generate it with `swift run " +
                    "generate-sawyer-preset-drift-sr` (CTRLKD_SAWYER_ARCHIVE and CTRLKD_SRC " +
                    "both armed), see docs/TESTING.md")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDocs = json["docs"] as? [String: Any] else {
            return (nil, "\(url.path) did not parse as the expected self-recorded-drift shape")
        }
        var docs: [String: DocEntry] = [:]
        for (name, raw) in rawDocs {
            guard let e = docEntry(raw) else {
                return (nil, "\(url.path): entry \"\(name)\" did not parse in the expected shape")
            }
            docs[name] = e
        }
        return (docs, nil)
    }()

    static var loaded: [String: DocEntry]? { loadResult.docs }
    static var loadFailure: String? { loadResult.failure }
}

@Suite struct CorpusParityTests {

    // MARK: - Real-filesystem CLIEnvironment

    /// `resolveDocumentPictures` (`SoftReturnCLI/PixResolve.swift`) needs real directory
    /// listing to walk the archive tree the same way the CLI/app do — this is that
    /// environment, backed by `FileManager` directly rather than the in-memory
    /// dictionaries the rest of this test target prefers (`SRCLITests.swift`'s own
    /// `noFSEnvironment`-style helpers): those exist to test the CONVERSION LOOP without
    /// real disk I/O, but this suite's whole point is comparing against the real archive.
    private struct RealFileReadError: Error, CustomStringConvertible {
        let path: String
        var description: String { "could not read \(path)" }
    }

    static func realFilesystemEnvironment() -> CLIEnvironment {
        let fm = FileManager.default
        return CLIEnvironment(
            readFile: { path in
                guard let data = fm.contents(atPath: path) else { throw RealFileReadError(path: path) }
                return [UInt8](data)
            },
            writeFile: { _, _ in },
            createDirectory: { _ in },
            writeOut: { _ in },
            writeErr: { _ in },
            listDirectory: { path in try? fm.contentsOfDirectory(atPath: path) },
            isFile: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            }
        )
    }

    // MARK: - Rendering the one geometry this suite still checks

    static func renderedSawyerPresetPDF(fileURL: URL) throws -> (pdf: [UInt8], pixResults: [PixResult]) {
        let bytes = [UInt8](try Data(contentsOf: fileURL))
        var doc = try parse(bytes, variant: nil)
        if let page = doc.page, let sawyerSettings = pagePresets["sawyer"] {
            doc.page = effectivePage(page, settings: sawyerSettings)
        }
        let pixResults = resolveDocumentPictures(doc, docPath: fileURL.path,
                                                  environment: realFilesystemEnvironment())
        let pdf = emitPDF(doc, mode: .printed, options: EmitOptions(pixResults: pixResults))
        return (pdf, pixResults)
    }

    /// Same "resolution STATE, not just the byte hash" check the retired manifest-driven
    /// version of this suite performed, so a placeholder-caused hash mismatch names itself
    /// instead of surfacing as an opaque sha diff.
    static func pixMismatches(pixResults: [PixResult], recordedPix: [SawyerPresetDriftFixture.PixEntry]) -> [String] {
        guard !recordedPix.isEmpty else { return [] }
        guard pixResults.count == recordedPix.count else {
            return ["""
                \(pixResults.count) real pix result(s) vs \(recordedPix.count) recorded pix \
                entries — image references drifted between this render and the last \
                recording.
                """]
        }
        var mismatches: [String] = []
        for (i, entry) in recordedPix.enumerated() {
            let result = pixResults[i]
            let tag = pixBasename(result.rawPath)
            if tag != entry.tag {
                mismatches.append("pix[\(i)]: tag \"\(tag)\" != recorded tag \"\(entry.tag)\"")
                continue
            }
            if result.ok != entry.resolved {
                mismatches.append("""
                    pix[\(i)] "\(entry.tag)": real render resolved=\(result.ok) but \
                    recording says resolved=\(entry.resolved).
                    """)
            }
        }
        return mismatches
    }

    // MARK: - Gate sentinel — the ONE named skip when unarmed

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func corpusParityGateIsArmed() {
        let failureMessage = SawyerPresetDriftFixture.loadFailure ??
            "expected sawyer_preset_pdf_sr.json to parse with real entries once armed"
        #expect(SawyerPresetDriftFixture.loaded != nil, "\(failureMessage)")
        if let docs = SawyerPresetDriftFixture.loaded {
            #expect(!docs.isEmpty)
        }
    }

    // MARK: - Full-corpus byte parity against the self-recorded drift file

    static var docNames: [String] {
        guard sawyerArchiveArmed, let docs = SawyerPresetDriftFixture.loaded else { return [] }
        return docs.keys.sorted()
    }

    @Test(arguments: docNames) func corpusSawyerPresetPDFMatchesSelfRecorded(docName: String) throws {
        let entry = try #require(SawyerPresetDriftFixture.loaded?[docName],
                                  "no recorded entry for \(docName) — stale doc list?")
        let fileURL = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(entry.path)
        let sourceBytes = [UInt8](try Data(contentsOf: fileURL))
        #expect(sha256Hex(sourceBytes) == entry.sourceSHA256, """
            \(docName): source bytes at \(entry.path) do not match the recording's \
            source_sha256 — corpus drifted since the drift file was last generated.
            """)
        let rendered = try Self.renderedSawyerPresetPDF(fileURL: fileURL)
        let mismatches = Self.pixMismatches(pixResults: rendered.pixResults, recordedPix: entry.cell.pix)
        #expect(mismatches.isEmpty, """
            \(docName) (sawyer-preset image resolution): \(mismatches.joined(separator: "; "))
            """)
        let actualSHA = sha256Hex(rendered.pdf)
        #expect(actualSHA == entry.cell.sha256, """
            \(docName) (sawyer-preset): sr emitPDF sha \(actualSHA) (\(rendered.pdf.count) \
            bytes) != last-recorded sha \(entry.cell.sha256) (\(entry.cell.bytes) bytes) — \
            if this is a deliberate engine change, regenerate with `swift run \
            generate-sawyer-preset-drift-sr` and commit the reviewed diff; this is DRIFT \
            detection, not a cross-engine truth check.
            """)
        #expect(rendered.pdf.count == entry.cell.bytes, """
            \(docName) (sawyer-preset): byte count \(rendered.pdf.count) != last-recorded \
            \(entry.cell.bytes)
            """)
    }
}
