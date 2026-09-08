import Foundation
import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

/// Planning #198/#195 (Engine-Test-Finalization-Plan Task 3, sr half): ctrl-kd replaced its
/// two self-recorded oracles (`samples_oracle.json`, `sawyer_oracle.json`) with ONE shared
/// answer key, `tests/answer_key.json` (`tools/answer_key.py`, `fadf377`) — every public
/// document (4 bundled samples + 385 Sawyer-archive convertible docs = 389 — every public
/// corpus document, planning #205a, not a hand-picked subset) x every
/// registered format x every mode, `<emitter>(doc, mode=mode)` with ZERO extra keyword
/// arguments (that engine's own library defaults), plus the 10 known-nonconvertible
/// documents (recorded refusal reason) and the one non-document asset (`WORDSTAR.PIX`,
/// source hash only). This suite is the Swift side of the SAME key: it reads ctrl-kd's
/// `tests/answer_key.json` directly (never a Swift-side copy — one key, no duplicates) and
/// asserts the Swift engine, called the SAME way (bare emitter call, default `EmitOptions()`,
/// no CLI, no `--fonts mac`), reproduces every cell byte-for-byte.
///
/// ## Format map — ctrl-kd <-> sr
///
/// | ctrl-kd (`ctrlkd.emit`/`ctrlkd.pdf`) | sr (`EmitterRegistry.standard`) | notes |
/// |---|---|---|
/// | `text`     | `emitText`     | alias `txt` both sides, not a separate cell |
/// | `markdown` | `emitMarkdown` | alias `md` both sides, not a separate cell |
/// | `html`     | `emitHTML`     | |
/// | `rtf`      | `emitRTF`      | |
/// | `pdf`      | `emitPDF`      | binary on both sides (`bytes`/`[UInt8]`); page count checked too |
/// | `layout`   | `emitLayout`   | JSON string; `mode` is ACCEPTED BUT IGNORED on both sides — the key's own `layout.printed`/`layout.modern` cells are byte-identical for every doc, by design (`tools/answer_key.py`'s own docstring), and this suite makes no special case for that: it just asserts both cells, same as any other, and they either both hold or both don't |
///
/// ctrl-kd formats sr LACKS: none. sr formats ctrl-kd LACKS: none — `EmitterRegistry
/// .standard` registers exactly these six canonical names (`Sources/CtrlKD/Registry.swift`),
/// nothing more. In particular there is no DOCX emitter anywhere in this repo (Sources/CtrlKD
/// or the macOS app) as of this suite — see `docs/TESTING.md` and
/// `TestDocs/oracle/answer_key_sr.json` for what that file is for and why it is currently
/// an empty grid.
///
/// ## Options — proven equal, not assumed
///
/// ctrl-kd's `_cell(doc, fmt, mode)` calls `get_emitter(fmt)['fn'](doc, mode=mode)` — no other
/// keyword. This suite calls every Swift emitter with a bare `EmitOptions()` for the exact
/// same reason, and the two are the SAME options, field by field (checked against
/// `src/ctrlkd/emit.py`/`pdf.py` signatures and `Sources/CtrlKD/EmitOptions.swift`'s `init`
/// defaults, 2026-09-06):
///   - `fontsTarget: .office` == python `fonts_target='office'` (RTF's only font-affecting
///     option; PDF never reads it at all — `--fonts mac`, used by this repo's OTHER two
///     oracles (`python-printed-manifest.json`, `output-manifest-vN.json`), is a CLI-only
///     default, never the library's, and is irrelevant to PDF regardless).
///   - `notes: .defaultNotes` (`[.footnote, .endnote, .annotation]`) == python
///     `DEFAULT_NOTE_KINDS = frozenset({'footnote', 'endnote', 'annotation'})`.
///   - `styles: true` == `styles=True`; `noteRefs: .word` == `note_refs='word'`; `headers:
///     true` == `headers=True`; `lineNumbers: true` == `line_numbers=True`; `toc: false` ==
///     `toc=False`; `inlineStyling: true` == `inline_styling=True`; `sentenceSpacing: .auto`
///     == `sentence_spacing='auto'`; `pageSettings: nil` == no `page_settings` kwarg (no
///     override applied either side).
///   - `pictures`: python defaults `pictures='off'` on every emitter that takes it (`emit_pdf`
///     included, via `options.get('pictures', 'off')`); Swift's `EmitOptions()` default is
///     `.embed`. This LOOKS like a divergence but is not one THAT MATTERS here: both sides
///     also default `pix_results`/`pixResults` to empty (`pix_results=None` / `[PixResult]()`),
///     and both engines gate embedding on having a resolved result for the tag (Swift:
///     `options.pixResults.first(where: …)`; Python: `pix_map.get(pix_idx)` against an empty
///     map) — so with no resolved pictures on either side, `.embed` and `off` produce the
///     IDENTICAL placeholder output. Verified, not just argued: this suite's own runs cover
///     `-README.WS`/`-SCREEN.WS` (the two convertible docs with a real `.PIX` reference) and
///     they pass. No pix resolution is performed here at all (unlike `CorpusParityTests`,
///     which deliberately DOES resolve — a different, PDF-only oracle over a different,
///     broader corpus; see that file's own header and `docs/TESTING.md`).
///
/// ## Gating
/// `CTRLKD_SAWYER_ARCHIVE` (`sawyerArchivePath`/`sawyerArchiveArmed`/`sawyerArchiveSkipReason`,
/// declared once in `WSChangeTests.swift`, reused here) — the 4 bundled samples need no
/// archive, but they are gated the same way as everything else in this suite so there is
/// exactly ONE arming knob and one documented skip, matching every sibling corpus suite.
/// Unarmed: `answerKeyGateIsArmed` below is the one named, recorded Skip; the bulk
/// parameterized tests collapse to zero collected cases (`AnswerKeyFixture.gridCaseIDs` etc.
/// return `[]` without ever touching the key file, so an unarmed run needs neither
/// `CTRLKD_SRC` nor a ctrl-kd checkout at all).
///
/// The key itself: `$CTRLKD_SRC/../tests/answer_key.json` — `CTRLKD_SRC` (this repo's own
/// armed environment variable, `docs/TESTING.md`) points at ctrl-kd's `src/`; the key is a
/// sibling of `src/` at that checkout's own `tests/answer_key.json`, not under `src/` itself.
/// Armed but that path unreadable or unparsable: FAILS LOUD, by design — `answerKeyGateIsArmed`
/// is the one test that requires the key to have loaded; a corpus that's armed but missing its
/// ground truth is a broken environment, not a skip (same doctrine `sawyerArchiveHasPATFixtures`
/// states for `.PAT` fixtures, applied here to the key file instead).
enum AnswerKeyFixture {
    struct Cell {
        let sha256: String
        let bytes: Int
        let pages: Int?
    }

    /// One convertible document: samples carry no `path` (bundled, not archive-relative);
    /// Sawyer entries do. `pictureBearing`/`cellsPicturesOff` — planning #211 (2026-09-06,
    /// ctrl-kd `98e03f9`): `cells` is now recorded with `pictures='embed'` and this
    /// document's own real, resolved pix results; a document that carries at least one
    /// `doc.graphics` entry (`pictureBearing == true`) additionally carries a
    /// `cellsPicturesOff` grid recording the `--pictures off` variant (`pix_results=nil`)
    /// — see `tools/answer_key.py`'s own `PICTURES_AXIS`/`_doc_entry` docstrings.
    struct DocEntry {
        let path: String?
        let sourceSHA256: String
        let cells: [String: Cell]
        let pictureBearing: Bool
        let cellsPicturesOff: [String: Cell]
    }

    struct NonConvertibleEntry {
        let path: String
        let sourceSHA256: String
        let reason: String
    }

    struct Key {
        let formats: [String]
        let modes: [String]
        let pictures: [String]
        let samplesDocs: [String: DocEntry]
        let sawyerConvertible: [String: DocEntry]
        let sawyerKnownNonConvertible: [String: NonConvertibleEntry]
        let sawyerNonDocumentAssets: [String: NonConvertibleEntry]
    }

    /// Documented path, per this file's header: ctrl-kd's own `tests/answer_key.json`, a
    /// sibling of `$CTRLKD_SRC`'s `src/`.
    static let path: String? = {
        guard let src = ProcessInfo.processInfo.environment["CTRLKD_SRC"], !src.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: src)
            .deletingLastPathComponent()
            .appendingPathComponent("tests/answer_key.json")
            .path
    }()

    /// `nil` load reason when everything worked; otherwise the LOUD, specific complaint
    /// `answerKeyGateIsArmed` reports. Computed once, lazily — never touched by an unarmed
    /// run (see `gridCaseIDs`/etc. below, which all check `sawyerArchiveArmed` FIRST).
    private static let loadResult: (key: Key?, failure: String?) = {
        guard let path else {
            return (nil, "CTRLKD_SRC is unset — cannot locate ctrl-kd's tests/answer_key.json " +
                    "(expected at $CTRLKD_SRC/../tests/answer_key.json)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (nil, "could not read \(path) — is the ctrl-kd checkout present and does " +
                    "it have a generated answer key (tools/answer_key.py --record)?")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "\(path) did not parse as a JSON object")
        }
        guard let key = parseKey(json) else {
            return (nil, "\(path) parsed as JSON but not in the expected answer-key shape " +
                    "(schema_version/axes/groups) — ctrl-kd's tools/answer_key.py may have " +
                    "changed its schema; update AnswerKeyFixture.parseKey to match")
        }
        return (key, nil)
    }()

    static var loaded: Key? { loadResult.key }
    static var loadFailure: String? { loadResult.failure }

    private static func cell(_ raw: Any?) -> Cell? {
        guard let dict = raw as? [String: Any],
              let sha256 = dict["sha256"] as? String,
              let bytes = dict["bytes"] as? Int else { return nil }
        return Cell(sha256: sha256, bytes: bytes, pages: dict["pages"] as? Int)
    }

    private static func docEntry(_ raw: Any?, hasPath: Bool) -> DocEntry? {
        guard let dict = raw as? [String: Any],
              let sourceSHA256 = dict["source_sha256"] as? String,
              let rawCells = dict["cells"] as? [String: Any] else { return nil }
        var cells: [String: Cell] = [:]
        for (k, v) in rawCells {
            guard let c = cell(v) else { return nil }
            cells[k] = c
        }
        // `picture_bearing` is a plain bool on every entry (planning #211); a legacy/
        // malformed entry missing it entirely is treated as non-picture-bearing rather
        // than failing the whole key to parse.
        let pictureBearing = dict["picture_bearing"] as? Bool ?? false
        var cellsPicturesOff: [String: Cell] = [:]
        if let rawOff = dict["cells_pictures_off"] as? [String: Any] {
            for (k, v) in rawOff {
                guard let c = cell(v) else { return nil }
                cellsPicturesOff[k] = c
            }
        }
        return DocEntry(path: dict["path"] as? String, sourceSHA256: sourceSHA256, cells: cells,
                        pictureBearing: pictureBearing, cellsPicturesOff: cellsPicturesOff)
    }

    private static func nonConvertibleEntry(_ raw: Any?) -> NonConvertibleEntry? {
        guard let dict = raw as? [String: Any],
              let path = dict["path"] as? String,
              let sourceSHA256 = dict["source_sha256"] as? String,
              let reason = dict["reason"] as? String else { return nil }
        return NonConvertibleEntry(path: path, sourceSHA256: sourceSHA256, reason: reason)
    }

    private static func parseKey(_ json: [String: Any]) -> Key? {
        guard let axes = json["axes"] as? [String: Any],
              let formats = axes["formats"] as? [String],
              let modes = axes["modes"] as? [String],
              let pictures = axes["pictures"] as? [String],
              let groups = json["groups"] as? [String: Any],
              let samples = groups["samples"] as? [String: Any],
              let samplesDocsRaw = samples["docs"] as? [String: Any],
              let sawyer = groups["sawyer"] as? [String: Any],
              let convertibleRaw = sawyer["convertible"] as? [String: Any],
              let knownNonConvertibleRaw = sawyer["known_nonconvertible"] as? [String: Any],
              let nonDocumentAssetsRaw = sawyer["non_document_assets"] as? [String: Any]
        else { return nil }

        var samplesDocs: [String: DocEntry] = [:]
        for (name, raw) in samplesDocsRaw {
            guard let e = docEntry(raw, hasPath: false) else { return nil }
            samplesDocs[name] = e
        }
        var convertible: [String: DocEntry] = [:]
        for (name, raw) in convertibleRaw {
            guard let e = docEntry(raw, hasPath: true) else { return nil }
            convertible[name] = e
        }
        var knownNonConvertible: [String: NonConvertibleEntry] = [:]
        for (name, raw) in knownNonConvertibleRaw {
            guard let e = nonConvertibleEntry(raw) else { return nil }
            knownNonConvertible[name] = e
        }
        var nonDocumentAssets: [String: NonConvertibleEntry] = [:]
        for (name, raw) in nonDocumentAssetsRaw {
            guard let e = nonConvertibleEntry(raw) else { return nil }
            nonDocumentAssets[name] = e
        }
        return Key(formats: formats, modes: modes, pictures: pictures, samplesDocs: samplesDocs,
                   sawyerConvertible: convertible,
                   sawyerKnownNonConvertible: knownNonConvertible,
                   sawyerNonDocumentAssets: nonDocumentAssets)
    }
}

/// One (doc, format, mode) grid cell to check. `bytes` is how to load the source document;
/// samples come from `sr`'s own bundled copies (`BundledSamples`), Sawyer docs from the real
/// archive tree.
enum AnswerKeyDocSource {
    case sample(baseName: String)
    case sawyer(relativePath: String)
    case privateCorpus(group: String, relativePath: String)

    func load() throws -> [UInt8] {
        switch self {
        case .sample(let baseName):
            return try BundledSamples.bytes(for: baseName)
        case .sawyer(let relativePath):
            let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(relativePath)
            return [UInt8](try Data(contentsOf: url))
        case .privateCorpus(let group, let relativePath):
            let url = URL(fileURLWithPath: ctrlkdPrivateCorpusRoot)
                .appendingPathComponent(group)
                .appendingPathComponent(relativePath)
            return [UInt8](try Data(contentsOf: url))
        }
    }

    /// The document's own real on-disk path — `resolveDocumentPictures` (planning #211)
    /// searches NEAR this path, mirroring ctrl-kd's `_doc_entry(doc, doc_path)` which
    /// resolves against the document's own real path (`samples/NAME.WS`,
    /// `$CTRLKD_SAWYER_ARCHIVE/<relative>`). A bundled sample has no real archive path;
    /// none of the 4 samples carry a `doc.graphics` reference (only Sawyer/private-corpus
    /// documents do, per this round's own mechanical sweep), so `resolveDocumentPictures`
    /// never actually touches the filesystem for one — the empty string here degrades
    /// exactly like ctrl-kd's own "no location to search from" case (every tag reports
    /// unresolved), never reached in practice.
    var docPath: String {
        switch self {
        case .sample:
            return ""
        case .sawyer(let relativePath):
            return URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(relativePath).path
        case .privateCorpus(let group, let relativePath):
            return URL(fileURLWithPath: ctrlkdPrivateCorpusRoot)
                .appendingPathComponent(group)
                .appendingPathComponent(relativePath)
                .path
        }
    }
}

/// `resolveDocumentPictures` needs real directory listing to walk the Sawyer/private-corpus
/// archive trees the same way the CLI/app do — `FileManager`-backed, same shape as
/// `CorpusParityTests.realFilesystemEnvironment()` (that one is `private` to its own file, so
/// this is its own copy rather than a cross-file reference).
private struct AnswerKeyRealFileReadError: Error, CustomStringConvertible {
    let path: String
    var description: String { "could not read \(path)" }
}

func answerKeyRealFilesystemEnvironment() -> CLIEnvironment {
    let fm = FileManager.default
    return CLIEnvironment(
        readFile: { path in
            guard let data = fm.contents(atPath: path) else { throw AnswerKeyRealFileReadError(path: path) }
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

struct AnswerKeyGridCase {
    let doc: String
    let format: String
    let mode: String
    let source: AnswerKeyDocSource
    let expected: AnswerKeyFixture.Cell
    /// `.embed` for the default grid (real resolved pix results against the document's own
    /// path); `.off` for the `cells_pictures_off` variant (planning #211) — only present for
    /// picture-bearing documents, always rendered with an empty `pixResults` (matching
    /// ctrl-kd's own `_grid(doc, pictures='off', pix_results=None)`).
    let pictures: EmitOptions.PixMode
}

/// PDF page count, read the same way `tools/answer_key.py`'s `_pdf_page_count` does: find the
/// page-tree object's own `/Kids [...] /Count N` (Swift's `PDFWriter.swift` emits it as the
/// single literal `"<< /Type /Pages /Kids [\(kids)] /Count \(streams.count) >>"`, so a plain
/// substring scan is exact — no regex needed for a shape this fixed).
enum PDFPageCountError: Error, CustomStringConvertible {
    case notFound
    var description: String {
        "could not find '/Kids [...] /Count N' in generated PDF — PDFWriter's page-tree " +
        "object shape changed; update AnswerKeyParityTests.pdfPageCount to match"
    }
}

func pdfPageCount(_ bytes: [UInt8]) throws -> Int {
    guard let text = String(bytes: bytes, encoding: .isoLatin1),
          let kidsRange = text.range(of: "/Kids ["),
          let countRange = text.range(of: "] /Count ", range: kidsRange.upperBound..<text.endIndex)
    else { throw PDFPageCountError.notFound }
    let digits = text[countRange.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
    guard let n = Int(digits) else { throw PDFPageCountError.notFound }
    return n
}

/// One rendered cell — sha256/bytes/(pdf page count). Every call site uses a bare
/// `EmitOptions()` apart from `pictures`/`pixResults` (planning #211 — see this file's
/// header for why passing those two uniformly to every format is always safe: text/layout
/// simply never consult them, same as ctrl-kd's own `emit.get_emitter(fmt)['fn'](doc,
/// mode=mode, pictures=pictures, pix_results=pix_results)`); every other option is
/// provably the SAME as `tools/answer_key.py` uses.
func renderAnswerKeyCell(doc: Document, format: String, mode: EmitMode,
                        pictures: EmitOptions.PixMode, pixResults: [PixResult]) throws -> AnswerKeyFixture.Cell {
    let options = EmitOptions(pictures: pictures, pixResults: pixResults)
    switch format {
    case "text":
        let d = Array(emitText(doc, mode: mode, options: options).utf8)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: nil)
    case "markdown":
        let d = Array(emitMarkdown(doc, mode: mode, options: options).utf8)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: nil)
    case "html":
        let d = Array(emitHTML(doc, mode: mode, options: options).utf8)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: nil)
    case "rtf":
        let d = Array(emitRTF(doc, mode: mode, options: options).utf8)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: nil)
    case "layout":
        let d = Array(emitLayout(doc, mode: mode, options: options).utf8)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: nil)
    case "pdf":
        let d = emitPDF(doc, mode: mode, options: options)
        return .init(sha256: sha256Hex(d), bytes: d.count, pages: try pdfPageCount(d))
    default:
        throw AnswerKeyUnknownFormat(name: format)
    }
}

struct AnswerKeyUnknownFormat: Error, CustomStringConvertible {
    let name: String
    var description: String {
        "answer key names format \(name), which AnswerKeyParityTests.renderAnswerKeyCell does " +
        "not know how to map to a Swift emitter — see this file's format-map table"
    }
}

@Suite struct AnswerKeyParityTests {

    // MARK: - Grid (samples + Sawyer convertible) x format x mode

    /// One doc entry's cases (embed grid, always; pictures-off grid, only when the entry is
    /// picture-bearing — planning #211) into `cases`, keyed the same way for both suites'
    /// consumers below. `off` cases get their own id suffix so they never collide with the
    /// default `embed` grid's id for the same (doc, format, mode).
    private static func addCases(_ cases: inout [String: AnswerKeyGridCase], name: String,
                                 entry: AnswerKeyFixture.DocEntry, formats: [String], modes: [String],
                                 source: AnswerKeyDocSource) {
        for format in formats {
            for mode in modes {
                if let expected = entry.cells["\(format).\(mode)"] {
                    let id = "\(name).\(format).\(mode)"
                    cases[id] = AnswerKeyGridCase(doc: name, format: format, mode: mode,
                                                  source: source, expected: expected, pictures: .embed)
                }
                if entry.pictureBearing, let expected = entry.cellsPicturesOff["\(format).\(mode)"] {
                    let id = "\(name).\(format).\(mode).pictures_off"
                    cases[id] = AnswerKeyGridCase(doc: name, format: format, mode: mode,
                                                  source: source, expected: expected, pictures: .off)
                }
            }
        }
    }

    /// Built once per process, only when armed — an unarmed run never touches the key file.
    static let gridCases: [String: AnswerKeyGridCase] = {
        guard sawyerArchiveArmed, let key = AnswerKeyFixture.loaded else { return [:] }
        var cases: [String: AnswerKeyGridCase] = [:]
        for (name, entry) in key.samplesDocs {
            let baseName = name.hasSuffix(".WS") ? String(name.dropLast(3)) : name
            addCases(&cases, name: name, entry: entry, formats: key.formats, modes: key.modes,
                    source: .sample(baseName: baseName))
        }
        for (name, entry) in key.sawyerConvertible {
            guard let relativePath = entry.path else { continue }
            addCases(&cases, name: name, entry: entry, formats: key.formats, modes: key.modes,
                    source: .sawyer(relativePath: relativePath))
        }
        return cases
    }()

    /// The 7 documents planning #211's mechanical archive walk found carrying at least one
    /// `doc.graphics` reference — asserted by name so a corpus/engine drift that silently
    /// changes this set (rather than merely a hash within it) fails loud and specific rather
    /// than as an opaque case-count difference. 3 of the 5 named in `pictures.py`'s own
    /// docstring (`-README.WS` root/APP/APP-vDosPlus copies) share one BASENAME but are
    /// distinct answer-key doc entries (Sawyer's own disambiguation for same-named files in
    /// different archive directories) — see `AnswerKeyFixture`'s own doc-naming convention.
    static var pictureBearingDocNames: [String] {
        guard sawyerArchiveArmed, let key = AnswerKeyFixture.loaded else { return [] }
        return key.sawyerConvertible.filter { $0.value.pictureBearing }.keys.sorted()
    }

    static var gridCaseIDs: [String] {
        guard sawyerArchiveArmed else { return [] }
        return gridCases.keys.sorted()
    }

    // MARK: - Known-nonconvertible negatives (10) + the one non-document asset

    static var knownNonConvertibleNames: [String] {
        guard sawyerArchiveArmed, let key = AnswerKeyFixture.loaded else { return [] }
        return key.sawyerKnownNonConvertible.keys.sorted()
    }

    /// The equivalence mapping between ctrl-kd's refusal message and Swift's structured
    /// error, stated once, here: Python raises `ParseError(f'not a convertible file
    /// (detected: {variant} -- {reason})')` (`core.py:4883`) where `variant` is `detect()`'s
    /// own string (`'binary'`, ...) and `reason` is the same evidence sentence
    /// (`'82% text but no structure'`, ...) both engines' detectors compute from the SAME
    /// text/structure heuristics. Swift's `ParseError.notConvertible(variant:reason:
    /// detection:)` carries the identical two pieces UNCOMPOSED — `variant.rawValue` is
    /// Python's `variant` string exactly (`Variant.binary.rawValue == "binary"`, matching
    /// `detect()`'s return), and `reason` is Python's `reason` sentence exactly. Composing
    /// them the same way Python's f-string does is therefore the whole equivalence check —
    /// not a looser "both raised something" pass.
    static func composedRefusalReason(variant: Variant, reason: String) -> String {
        "not a convertible file (detected: \(variant.rawValue) -- \(reason))"
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func answerKeyGateIsArmed() {
        let failureMessage = AnswerKeyFixture.loadFailure ??
            "expected ctrl-kd's tests/answer_key.json to load with real entries once armed"
        #expect(AnswerKeyFixture.loaded != nil, "\(failureMessage)")
        if let key = AnswerKeyFixture.loaded {
            #expect(Set(key.formats) == ["text", "markdown", "html", "rtf", "pdf", "layout"])
            #expect(Set(key.modes) == ["printed", "modern"])
            #expect(Set(key.pictures) == ["embed", "off"])
            #expect(!key.samplesDocs.isEmpty)
            #expect(!key.sawyerConvertible.isEmpty)
            #expect(key.sawyerKnownNonConvertible.count == 10)
            #expect(key.sawyerNonDocumentAssets.count == 1)
        }
    }

    /// Planning #211's own named 7 — the full archive walk's mechanical picture-bearing set,
    /// pinned by name so a corpus change that silently adds/drops one is a loud, specific
    /// failure rather than an opaque case-count drift buried in `gridCaseIDs`.
    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func pictureBearingDocsAreTheNamedSeven() {
        #expect(Set(Self.pictureBearingDocNames) == [
            "-README.WS (root)", "-README.WS (APP)", "-README.WS (APP/vDosPlus)",
            "PREVIEW.WS", "-SCREEN.WS", "HIJAAK/PEANUTS.WS", "REF/-TOC-TAG.WS",
        ])
    }

    @Test(arguments: gridCaseIDs) func answerKeyCellMatches(id: String) throws {
        let c = try #require(Self.gridCases[id], "no grid case for id \(id) — stale case list?")
        let bytes = try c.source.load()
        let doc = try parse(bytes, variant: nil)
        guard let mode = EmitMode(rawValue: c.mode) else {
            Issue.record("unknown mode \(c.mode) in answer key"); return
        }
        // planning #211: the default grid is rendered with sr's OWN resolved pix results
        // (`resolveDocumentPictures`, mirroring ctrl-kd's `pictures.resolve_document_pictures`
        // search-near-doc-path contract) against this document's own real on-disk path — for
        // the ~382 of 389 documents with no `doc.graphics` at all this resolves to `[]` and
        // costs one no-op directory-listing attempt; the `pictures_off` variant never resolves
        // anything at all, matching ctrl-kd's own `pix_results=None`.
        let pixResults: [PixResult] = c.pictures == .off ? [] :
            resolveDocumentPictures(doc, docPath: c.source.docPath, environment: answerKeyRealFilesystemEnvironment())
        let got = try renderAnswerKeyCell(doc: doc, format: c.format, mode: mode,
                                          pictures: c.pictures, pixResults: pixResults)
        #expect(got.bytes == c.expected.bytes, """
            \(id): output size \(got.bytes) != ctrl-kd's \(c.expected.bytes) — if this is a \
            deliberate engine change on either side, that is a real cross-engine divergence, \
            not something to paper over here.
            """)
        #expect(got.sha256 == c.expected.sha256, """
            \(id): sha256 \(got.sha256) != ctrl-kd's \(c.expected.sha256) (\(got.bytes) bytes \
            here vs \(c.expected.bytes) there)
            """)
        if let expectedPages = c.expected.pages {
            #expect(got.pages == expectedPages, """
                \(id): pdf page count \(got.pages.map(String.init) ?? "nil") != ctrl-kd's \
                \(expectedPages)
                """)
        }
    }

    @Test(arguments: knownNonConvertibleNames) func knownNonConvertibleRefusedAsRecorded(name: String) throws {
        guard let key = AnswerKeyFixture.loaded, let entry = key.sawyerKnownNonConvertible[name]
        else { Issue.record("no known-nonconvertible entry for \(name)"); return }
        let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(entry.path)
        let data = try Data(contentsOf: url)
        #expect(sha256Hex([UInt8](data)) == entry.sourceSHA256, """
            \(name): source bytes at \(entry.path) do not match the answer key's recorded \
            source_sha256 — corpus drifted since the key was generated.
            """)
        do {
            _ = try parse([UInt8](data), variant: nil)
            Issue.record("""
                \(name): answer key records this as known-nonconvertible \
                (\(entry.reason)), but parse(_:variant:) succeeded — either the key is stale \
                or the Swift engine's detection now accepts it (move it to the convertible \
                set, do not silently pass this test).
                """)
        } catch let error as ParseError {
            guard case .notConvertible(let variant, let reason, _) = error else {
                Issue.record("\(name): expected .notConvertible, got \(error)"); return
            }
            let composed = Self.composedRefusalReason(variant: variant, reason: reason)
            #expect(composed == entry.reason, """
                \(name): Swift refusal "\(composed)" != ctrl-kd's recorded reason \
                "\(entry.reason)" — same document, different refusal explanation between \
                engines.
                """)
        }
    }

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func wordstarPixIsSourceHashOnly() throws {
        let key = try #require(AnswerKeyFixture.loaded)
        let entry = try #require(key.sawyerNonDocumentAssets["WORDSTAR.PIX"],
                                  "WORDSTAR.PIX missing from answer key's non_document_assets")
        let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(entry.path)
        let data = try Data(contentsOf: url)
        #expect(sha256Hex([UInt8](data)) == entry.sourceSHA256, """
            WORDSTAR.PIX: source bytes at \(entry.path) do not match the answer key's \
            recorded source_sha256 — never run through parse()/emit(), by design (it is an \
            Inset image asset, not a WordStar document); this is the only check it gets.
            """)
    }
}

// MARK: - PRIVATE OVERLAY (planning #205, part b) — `TestDocs/oracle/answer_key_private.json`

/// The private-corpus counterpart to the shared public key above. ctrl-kd cannot carry this
/// key (it is a public repo; the private corpus must never appear there) — it is generated
/// and committed IN THIS repo instead, by `tools/answer_key_private.py`, which reuses
/// ctrl-kd's own `tools/answer_key.py` generator functions (`_grid`/`_cell`/`_sha256_file`,
/// imported live from `$CTRLKD_SRC/../tools`, never copied) over three private-corpus
/// groups: `ws7-private/` (2 hand-built fixtures), `jon-floppies/` (every `.WS4` document,
/// swept live — 64 as of this writing), and `fixtures-ws5/` (11 curated `.WS`/`.TST`
/// fixtures). See that tool's own module docstring for the full scope/classification/
/// provenance account, and `ctrlkd-private-tests/test_answer_key_private.py` for the
/// Python-side consumer of the SAME file.
///
/// Every file the generator names ends up in exactly one of three buckets, decided by
/// actually running `core.detect`/`core.parse` — never assumed from its extension:
/// `convertible` (full format x mode grid), `known_nonconvertible` (recorded refusal
/// reason, same composed-message equivalence as the public key's negatives, below), or
/// `non_document_assets` (source-hash only). As of this writing all 77 private-corpus
/// documents are convertible — `known_nonconvertible`/`non_document_assets` are empty for
/// every group, a real finding (not an assumption baked into the schema), which is why
/// `privateKnownNonConvertibleIDs`/`privateNonDocumentAssetIDs` below can legitimately
/// collect zero cases; the schema stays three-bucket regardless, so a future corpus
/// addition that DOES need either bucket needs no code change here.
///
/// Unlike the public key (a sibling of `$CTRLKD_SRC`'s `src/`, outside this repo), the
/// private key is committed IN this repo at a fixed path — no `CTRLKD_SRC` needed to find
/// it, only `CTRLKD_PRIVATE_CORPUS` to load the actual source documents it hashes.
/// Gated on `ctrlkdPrivateCorpusArmed`/`ctrlkdPrivateCorpusRoot`/`ctrlkdPrivateCorpusSkipReason`
/// (declared once in `PCLFidelityTests.swift`, reused here — one arming knob per corpus,
/// same convention `sawyerArchiveArmed` follows for the Sawyer-gated suites above). Armed
/// but the committed key file itself is missing or unparsable: FAILS LOUD (a broken repo
/// state, not a legitimate skip) — same doctrine as the public key's `answerKeyGateIsArmed`.
enum AnswerKeyPrivateFixture {
    /// `pictureBearing`/`cellsPicturesOff` mirror the public key's own planning #211 fields
    /// (`tools/answer_key_private.py`'s `_classify_and_grid` reuses ctrl-kd's `_doc_entry`
    /// verbatim) — mechanically found to be EMPTY for the whole private corpus as of this
    /// round (zero of the 77 documents carry a `doc.graphics` reference), so
    /// `cellsPicturesOff` is always `[:]` in practice today; the schema still carries both
    /// fields so a future private-corpus addition that DOES reference a picture needs no
    /// code change here, same doctrine as the empty known-nonconvertible/non-document-asset
    /// buckets this file's own header already documents.
    struct DocEntry {
        let path: String
        let sourceSHA256: String
        let detectedVariant: String
        let cells: [String: AnswerKeyFixture.Cell]
        let pictureBearing: Bool
        let cellsPicturesOff: [String: AnswerKeyFixture.Cell]
    }

    struct NonConvertibleEntry {
        let path: String
        let sourceSHA256: String
        let detectedVariant: String?
        let reason: String
    }

    struct Group {
        let convertible: [String: DocEntry]
        let knownNonConvertible: [String: NonConvertibleEntry]
        let nonDocumentAssets: [String: NonConvertibleEntry]
    }

    struct Key {
        let formats: [String]
        let modes: [String]
        let pictures: [String]
        let groups: [String: Group]
    }

    /// Committed in-repo: `Tests/CtrlKDTests/AnswerKeyParityTests.swift` -> repo root is
    /// three directories up (`Tests/CtrlKDTests` -> `Tests` -> repo root), then
    /// `TestDocs/oracle/answer_key_private.json`.
    static let path: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("TestDocs/oracle/answer_key_private.json")
        .path

    private static let loadResult: (key: Key?, failure: String?) = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (nil, "could not read \(path) — generate it with " +
                    "`tools/answer_key_private.py --record` (see docs/TESTING.md)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "\(path) did not parse as a JSON object")
        }
        guard let key = parseKey(json) else {
            return (nil, "\(path) parsed as JSON but not in the expected private-answer-key " +
                    "shape (schema_version/axes/groups) — tools/answer_key_private.py may " +
                    "have changed its schema; update AnswerKeyPrivateFixture.parseKey to match")
        }
        return (key, nil)
    }()

    static var loaded: Key? { loadResult.key }
    static var loadFailure: String? { loadResult.failure }

    private static func cell(_ raw: Any?) -> AnswerKeyFixture.Cell? {
        guard let dict = raw as? [String: Any],
              let sha256 = dict["sha256"] as? String,
              let bytes = dict["bytes"] as? Int else { return nil }
        return AnswerKeyFixture.Cell(sha256: sha256, bytes: bytes, pages: dict["pages"] as? Int)
    }

    private static func docEntry(_ raw: Any?) -> DocEntry? {
        guard let dict = raw as? [String: Any],
              let path = dict["path"] as? String,
              let sourceSHA256 = dict["source_sha256"] as? String,
              let detectedVariant = dict["detected_variant"] as? String,
              let rawCells = dict["cells"] as? [String: Any] else { return nil }
        var cells: [String: AnswerKeyFixture.Cell] = [:]
        for (k, v) in rawCells {
            guard let c = cell(v) else { return nil }
            cells[k] = c
        }
        let pictureBearing = dict["picture_bearing"] as? Bool ?? false
        var cellsPicturesOff: [String: AnswerKeyFixture.Cell] = [:]
        if let rawOff = dict["cells_pictures_off"] as? [String: Any] {
            for (k, v) in rawOff {
                guard let c = cell(v) else { return nil }
                cellsPicturesOff[k] = c
            }
        }
        return DocEntry(path: path, sourceSHA256: sourceSHA256, detectedVariant: detectedVariant,
                        cells: cells, pictureBearing: pictureBearing, cellsPicturesOff: cellsPicturesOff)
    }

    private static func nonConvertibleEntry(_ raw: Any?) -> NonConvertibleEntry? {
        guard let dict = raw as? [String: Any],
              let path = dict["path"] as? String,
              let sourceSHA256 = dict["source_sha256"] as? String,
              let reason = dict["reason"] as? String else { return nil }
        return NonConvertibleEntry(path: path, sourceSHA256: sourceSHA256,
                                    detectedVariant: dict["detected_variant"] as? String,
                                    reason: reason)
    }

    private static func group(_ raw: Any?) -> Group? {
        guard let dict = raw as? [String: Any],
              let convertibleRaw = dict["convertible"] as? [String: Any],
              let knownNonConvertibleRaw = dict["known_nonconvertible"] as? [String: Any],
              let nonDocumentAssetsRaw = dict["non_document_assets"] as? [String: Any]
        else { return nil }
        var convertible: [String: DocEntry] = [:]
        for (name, raw) in convertibleRaw {
            guard let e = docEntry(raw) else { return nil }
            convertible[name] = e
        }
        var knownNonConvertible: [String: NonConvertibleEntry] = [:]
        for (name, raw) in knownNonConvertibleRaw {
            guard let e = nonConvertibleEntry(raw) else { return nil }
            knownNonConvertible[name] = e
        }
        var nonDocumentAssets: [String: NonConvertibleEntry] = [:]
        for (name, raw) in nonDocumentAssetsRaw {
            guard let e = nonConvertibleEntry(raw) else { return nil }
            nonDocumentAssets[name] = e
        }
        return Group(convertible: convertible, knownNonConvertible: knownNonConvertible,
                    nonDocumentAssets: nonDocumentAssets)
    }

    private static func parseKey(_ json: [String: Any]) -> Key? {
        guard let axes = json["axes"] as? [String: Any],
              let formats = axes["formats"] as? [String],
              let modes = axes["modes"] as? [String],
              let pictures = axes["pictures"] as? [String],
              let groupsRaw = json["groups"] as? [String: Any]
        else { return nil }
        var groups: [String: Group] = [:]
        for (name, raw) in groupsRaw {
            guard let g = group(raw) else { return nil }
            groups[name] = g
        }
        return Key(formats: formats, modes: modes, pictures: pictures, groups: groups)
    }
}

@Suite struct AnswerKeyParityPrivateTests {

    // MARK: - Grid (all three groups' convertible docs) x format x mode

    /// Built once per process, only when armed — an unarmed run never touches the source
    /// documents (the key file itself is always readable, being in-repo, but its cells are
    /// only checked against real bytes once `CTRLKD_PRIVATE_CORPUS` is armed).
    static let gridCases: [String: AnswerKeyGridCase] = {
        guard ctrlkdPrivateCorpusArmed, let key = AnswerKeyPrivateFixture.loaded else { return [:] }
        var cases: [String: AnswerKeyGridCase] = [:]
        for (groupName, grp) in key.groups {
            for (name, entry) in grp.convertible {
                let docName = "\(groupName)/\(name)"
                let source = AnswerKeyDocSource.privateCorpus(group: groupName, relativePath: name)
                for format in key.formats {
                    for mode in key.modes {
                        if let expected = entry.cells["\(format).\(mode)"] {
                            let id = "\(docName).\(format).\(mode)"
                            cases[id] = AnswerKeyGridCase(doc: docName, format: format, mode: mode,
                                                          source: source, expected: expected, pictures: .embed)
                        }
                        // planning #211: none of the 77 private-corpus documents are
                        // picture-bearing as of this round (mechanically confirmed, see
                        // `AnswerKeyPrivateFixture.DocEntry`'s own doc comment) — this branch
                        // exists so a future addition that DOES reference a picture is picked
                        // up automatically, with no code change here.
                        if entry.pictureBearing, let expected = entry.cellsPicturesOff["\(format).\(mode)"] {
                            let id = "\(docName).\(format).\(mode).pictures_off"
                            cases[id] = AnswerKeyGridCase(doc: docName, format: format, mode: mode,
                                                          source: source, expected: expected, pictures: .off)
                        }
                    }
                }
            }
        }
        return cases
    }()

    static var gridCaseIDs: [String] {
        guard ctrlkdPrivateCorpusArmed else { return [] }
        return gridCases.keys.sorted()
    }

    /// (group, name) for every grid case — used to also verify `detect()` agrees with the
    /// key's recorded `detected_variant`, once per document rather than once per cell.
    static var detectedVariantCaseIDs: [String] {
        guard ctrlkdPrivateCorpusArmed, let key = AnswerKeyPrivateFixture.loaded else { return [] }
        var ids: [String] = []
        for (groupName, grp) in key.groups {
            for name in grp.convertible.keys {
                ids.append("\(groupName)/\(name)")
            }
        }
        return ids.sorted()
    }

    // MARK: - Known-nonconvertible / non-document-asset negatives (both empty as of this writing)

    static var knownNonConvertibleIDs: [String] {
        guard ctrlkdPrivateCorpusArmed, let key = AnswerKeyPrivateFixture.loaded else { return [] }
        var ids: [String] = []
        for (groupName, grp) in key.groups {
            for name in grp.knownNonConvertible.keys { ids.append("\(groupName)/\(name)") }
        }
        return ids.sorted()
    }

    static var nonDocumentAssetIDs: [String] {
        guard ctrlkdPrivateCorpusArmed, let key = AnswerKeyPrivateFixture.loaded else { return [] }
        var ids: [String] = []
        for (groupName, grp) in key.groups {
            for name in grp.nonDocumentAssets.keys { ids.append("\(groupName)/\(name)") }
        }
        return ids.sorted()
    }

    private static func splitGroupName(_ id: String) -> (group: String, name: String)? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        return (String(id[id.startIndex..<slash]), String(id[id.index(after: slash)...]))
    }

    @Test(.enabled(if: ctrlkdPrivateCorpusArmed, ctrlkdPrivateCorpusSkipReason))
    func privateAnswerKeyGateIsArmed() {
        let failureMessage = AnswerKeyPrivateFixture.loadFailure ??
            "expected TestDocs/oracle/answer_key_private.json to load with real entries once armed"
        #expect(AnswerKeyPrivateFixture.loaded != nil, "\(failureMessage)")
        if let key = AnswerKeyPrivateFixture.loaded {
            #expect(Set(key.formats) == ["text", "markdown", "html", "rtf", "pdf", "layout"])
            #expect(Set(key.modes) == ["printed", "modern"])
            #expect(Set(key.pictures) == ["embed", "off"])
            #expect(Set(key.groups.keys) == ["ws7-private", "jon-floppies", "fixtures-ws5"])
            #expect(key.groups["ws7-private"]?.convertible.count == 2)
            #expect(key.groups["jon-floppies"]?.convertible.isEmpty == false)
            #expect(key.groups["fixtures-ws5"]?.convertible.count == 11)
            // planning #211, mechanically confirmed (see this suite's own tools/
            // answer_key_private.py --record run): zero of the 77 private-corpus documents
            // carry a doc.graphics reference. A future addition that DOES reference one
            // needs no code change (gridCases already handles a true picture_bearing flag
            // mechanically) — but if this count ever moves, that is real corpus news worth
            // seeing here rather than silently, and PicturesTests/AnswerKeyParityTests'
            // own coverage of the mechanism stays proven by the PUBLIC key's 7 real cases.
            let pictureBearingCount = key.groups.values
                .flatMap(\.convertible.values).filter(\.pictureBearing).count
            #expect(pictureBearingCount == 0)
        }
    }

    @Test(arguments: gridCaseIDs) func privateAnswerKeyCellMatches(id: String) throws {
        let c = try #require(Self.gridCases[id], "no grid case for id \(id) — stale case list?")
        let bytes = try c.source.load()
        let doc = try parse(bytes, variant: nil)
        guard let mode = EmitMode(rawValue: c.mode) else {
            Issue.record("unknown mode \(c.mode) in private answer key"); return
        }
        let pixResults: [PixResult] = c.pictures == .off ? [] :
            resolveDocumentPictures(doc, docPath: c.source.docPath, environment: answerKeyRealFilesystemEnvironment())
        let got = try renderAnswerKeyCell(doc: doc, format: c.format, mode: mode,
                                          pictures: c.pictures, pixResults: pixResults)
        #expect(got.bytes == c.expected.bytes, """
            \(id): output size \(got.bytes) != recorded \(c.expected.bytes) — if this is a \
            deliberate engine change, that is real drift, not something to paper over here.
            """)
        #expect(got.sha256 == c.expected.sha256, """
            \(id): sha256 \(got.sha256) != recorded \(c.expected.sha256) (\(got.bytes) bytes \
            here vs \(c.expected.bytes) recorded)
            """)
        if let expectedPages = c.expected.pages {
            #expect(got.pages == expectedPages, """
                \(id): pdf page count \(got.pages.map(String.init) ?? "nil") != recorded \
                \(expectedPages)
                """)
        }
    }

    @Test(arguments: detectedVariantCaseIDs) func privateDetectedVariantMatches(id: String) throws {
        guard let (groupName, name) = Self.splitGroupName(id),
              let key = AnswerKeyPrivateFixture.loaded,
              let entry = key.groups[groupName]?.convertible[name]
        else { Issue.record("no convertible entry for \(id)"); return }
        let bytes = try AnswerKeyDocSource.privateCorpus(group: groupName, relativePath: name).load()
        let det = detect(bytes)
        #expect(det.variant.rawValue == entry.detectedVariant, """
            \(id): Swift detect() variant \(det.variant.rawValue) != recorded \
            \(entry.detectedVariant) — detection behavior diverged for this document.
            """)
    }

    @Test(arguments: knownNonConvertibleIDs) func privateKnownNonConvertibleRefusedAsRecorded(id: String) throws {
        guard let (groupName, name) = Self.splitGroupName(id),
              let key = AnswerKeyPrivateFixture.loaded,
              let entry = key.groups[groupName]?.knownNonConvertible[name]
        else { Issue.record("no known-nonconvertible entry for \(id)"); return }
        let bytes = try AnswerKeyDocSource.privateCorpus(group: groupName, relativePath: name).load()
        #expect(sha256Hex(bytes) == entry.sourceSHA256, """
            \(id): source bytes do not match the private answer key's recorded \
            source_sha256 — corpus drifted since the key was generated.
            """)
        do {
            _ = try parse(bytes, variant: nil)
            Issue.record("""
                \(id): private answer key records this as known-nonconvertible \
                (\(entry.reason)), but parse(_:variant:) succeeded — either the key is stale \
                or the Swift engine's detection now accepts it (regenerate and move it to \
                the convertible set, do not silently pass this test).
                """)
        } catch let error as ParseError {
            guard case .notConvertible(let variant, let reason, _) = error else {
                Issue.record("\(id): expected .notConvertible, got \(error)"); return
            }
            let composed = AnswerKeyParityTests.composedRefusalReason(variant: variant, reason: reason)
            #expect(composed == entry.reason, """
                \(id): Swift refusal "\(composed)" != ctrl-kd's recorded reason \
                "\(entry.reason)" — same document, different refusal explanation between \
                engines.
                """)
        }
    }

    @Test(arguments: nonDocumentAssetIDs) func privateNonDocumentAssetHashOnly(id: String) throws {
        guard let (groupName, name) = Self.splitGroupName(id),
              let key = AnswerKeyPrivateFixture.loaded,
              let entry = key.groups[groupName]?.nonDocumentAssets[name]
        else { Issue.record("no non-document-asset entry for \(id)"); return }
        let bytes = try AnswerKeyDocSource.privateCorpus(group: groupName, relativePath: name).load()
        #expect(sha256Hex(bytes) == entry.sourceSHA256, """
            \(id): source bytes do not match the private answer key's recorded \
            source_sha256 — never run through parse()/emit(), by design; this is the only \
            check it gets.
            """)
    }
}
