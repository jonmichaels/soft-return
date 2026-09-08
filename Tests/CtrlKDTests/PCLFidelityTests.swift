import Foundation
import Testing
@testable import CtrlKD
@testable import SoftReturnCLI

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
#endif

/// Engine-Test-Finalization-Plan-2026-09-05 (planning #197), Task 1, sr half: "The same
/// gate runs over sr's Printed PDF ... as a Swift-package test that shells to the tool" —
/// ctrl-kd's own font-class-tolerance, named-divergence gate (`tools/pcl_tolerance.py`,
/// the `pcl` pytest tier behind `tests/test_pcl_fidelity.py`) run against THIS engine's
/// own Printed-mode PDF for the same captured WS7 LaserJet documents, checked against the
/// SAME checked-in answer key ctrl-kd commits (`tests/pcl_fidelity_manifest.json`). This
/// file never re-implements the tolerance curves, the font-tier table, or the divergence
/// classification — every one of those numbers comes from ctrl-kd's own code, run
/// unmodified in a subprocess via `Support/run_pcl_fidelity_gate.py` (that script's own
/// header explains the one splice it performs: swapping the PDF `pcl_tolerance.doc_report`
/// compares in, nothing else).
///
/// ## What "pass" and "fail" mean here
/// Two independent things are checked per document, and they can (and today, do) diverge:
///
/// 1. **Zero non-font-substitution divergences** — ctrl-kd's own bar for "clean" PCL
///    fidelity. A document that fails this is failing for a REAL reason (a placement bug),
///    same as `pytest -m pcl` reports for ctrl-kd itself — this test fails BY NAME, printing
///    every divergence, exactly the finding a maintainer needs to chase (planning issue
///    #202 tracks the currently-known ones). A document passing ctrl-kd's own `pcl` tier
///    passes this one too, automatically — a clean ctrl-kd verdict has nothing left over.
/// 2. **sr's divergence set equals ctrl-kd's own recorded manifest entry for that
///    document** — the cross-engine check this suite actually exists to add. Since both
///    engines are meant to produce byte-identical Printed PDFs (`CorpusParityTests`'s own
///    byte-parity gate, over the public Sawyer/pd-samples corpus), sr's PCL-fidelity
///    numbers against the SAME WS7 captures should come out identical to ctrl-kd's too —
///    same counts, same named divergences. A mismatch here means the two engines'
///    Printed-PDF output has actually diverged for this document (a genuine cross-engine
///    bug, reported by name), not merely that WS7 fidelity is imperfect.
///
/// A document can fail check 1 while passing check 2 — that is the expected, current
/// shape: sr reproduces ctrl-kd's own known PCL-fidelity gaps exactly, because the two
/// PDFs are the same bytes. `swift test`'s overall exit status for `--filter PCLFidelity`
/// is therefore RED whenever any captured document has a live PCL-fidelity bug, by design
/// (per this file's own doctrine and `docs/TESTING.md`'s Tier-2/3 law: a skipped or
/// papered-over check is not a passing check) — the rest of the suite (`swift test` with
/// no filter) is unaffected by this tier's verdicts.
///
/// ## Engine construction
/// `PCLFidelityDriver.renderPrintedPDF` mirrors `tools/fidelity_gate.py`'s own
/// `render_engine_pdf` EXACTLY, not `CorpusParityTests.renderedPDF`'s fuller
/// construction: `core.parse(data)` with no page-settings override (no `sawyer` preset)
/// and no PIX resolution (`pdfmod.emit_pdf(doc, mode='printed')`, no other options) — the
/// ctrl-kd gate only ever renders ONE geometry, the document's own, per that file's own
/// docstring ("letter, default options ... nothing overridden"). The Swift side is
/// therefore `parse(bytes, variant: nil)` then `emitPDF(doc, mode: .printed)` with a bare
/// `EmitOptions()` — no `pagePresets["sawyer"]`, no `resolveDocumentPictures`.
///
/// ## Locating ctrl-kd and the corpus
/// `CTRLKD_SRC` / sibling-checkout fallback, and `CTRLKD_PRIVATE_CORPUS` /
/// `CTRLKD_SAWYER_ARCHIVE`: all documented in `Support/run_pcl_fidelity_gate.py`'s own
/// header and `docs/TESTING.md`. This file's own gate is `CTRLKD_PRIVATE_CORPUS` only
/// (Tier 3, same law `PrivateCorpusSupport.swift` follows on the app side) — an unset
/// `CTRLKD_SRC` is not a skip, it is a hard failure once armed (a missing TOOL, not a
/// missing CORPUS), reported by `PCLFidelityDriver.run`'s own thrown error.
///
/// ## Document list
/// `capturedDocs` mirrors `tools/pcl_tolerance.py`'s own `CAPTURED_DOCS` — a committed,
/// reviewed list, never a directory sweep, same convention that file's own header
/// documents. Whether any given name actually resolves to a real source in the CURRENT
/// corpus (some once needed `ws7-prints/v1/sources.json`, a capture->source index that
/// was still being completed as of this writing) is decided live, per document, by
/// `run_pcl_fidelity_gate.py report NAME` — never hardcoded here — so a name that starts
/// resolving after a corpus update starts running automatically, with no Swift change.
private let capturedDocs = [
    "BOXES", "DOCA", "DOCB", "DOCC", "DOCD", "LJ6DTP", "LYING", "OCAPTAIN",
    "DOCE", "PREVIEW", "-README", "SAWYER", "-SCREEN", "SCRIPT", "DOCF",
    "TWAINLET", "VERSIONS", "WARPRAYR",
]

let ctrlkdPrivateCorpusRoot = (ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"]
    .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) ?? ""

/// `true` exactly when `CTRLKD_PRIVATE_CORPUS` is set — every PCL-fidelity test in this
/// file cites this via `.enabled(if:)` so an unset var is a recorded Skip, not a pass or
/// a failure. Deliberately does NOT also check `CTRLKD_SAWYER_ARCHIVE`: some captured
/// documents resolve without it (see `run_pcl_fidelity_gate.py`'s own resolution
/// docstring), and the ones that still need it report their own per-document
/// `resolvable: false` from the driver rather than being pre-filtered out here.
let ctrlkdPrivateCorpusArmed = !ctrlkdPrivateCorpusRoot.isEmpty

let ctrlkdPrivateCorpusSkipReason: Comment =
    "private-corpus-gated: CTRLKD_PRIVATE_CORPUS unset — see docs/TESTING.md"

/// THE RACE (found 2026-09-06, `swift test` run in parallel with 18 `pclFidelity(doc:)`
/// cases in flight): every one of those cases' TWO subprocess calls (`resolve` then
/// `gate`) does a bare `import fidelity_gate`/`import pcl_tolerance` straight off
/// `$CTRLKD_SRC` — ctrl-kd's own LIVE, mutable checkout on disk — and `pcl_tolerance.py`
/// reads `tests/pcl_fidelity_manifest.json` fresh on every single call
/// (`load_manifest()`, no caching). ctrl-kd is a SEPARATE git repo that this machine
/// routinely has ANOTHER session iterating on at the same time (confirmed live during
/// this investigation: `git status` in `../ctrl-kd` showed `src/ctrlkd/pdf.py` and
/// `tests/pcl_fidelity_manifest.json` mid-edit, and the two runs that actually reproduced
/// spurious mismatches landed in the exact window bracketing a real ctrl-kd commit that
/// re-recorded that manifest). `pcl_tolerance.py`'s own `--record` path writes that file
/// with a bare `open(MANIFEST_PATH, 'w')` — truncate-then-write, not atomic — so a
/// `load_manifest()` call from one of THIS suite's subprocesses, landing mid-write, can
/// observe a truncated or half-old/half-new manifest, or read `pdf.py` mid-edit and get a
/// transiently different reference computation. None of that is a bug in this file's own
/// concurrency (isolated stress tests hammering the Swift renderer, the Python driver via
/// bare subprocesses, and Foundation's Process/Pipe layer directly — each with 150-240
/// concurrent invocations — reproduced ZERO mismatches); it is contamination from a
/// dependency this suite does not own and cannot assume is quiescent.
///
/// THE FIX: this repo still never WRITES to ctrl-kd (that rule is unchanged) — instead,
/// `PCLFidelitySnapshot` copies the exact slice of ctrl-kd this driver reads (`tools/`,
/// `src/`, `tests/pcl_fidelity_manifest.json`) into a private temp directory ONCE per
/// `swift test` process (a `static let`, so Swift's own thread-safe one-time
/// initialization is the lock — no custom synchronization to get wrong), and every
/// subprocess this file launches is pointed at that frozen copy via `$CTRLKD_SRC`,
/// never at the live checkout. The whole run then sees one consistent, self-agreeing
/// ctrl-kd snapshot regardless of what another session does to the real one meanwhile.
enum PCLFidelitySnapshot {
    struct SnapshotError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Mirrors `run_pcl_fidelity_gate.py`'s own `resolve_ctrlkd_root()` EXACTLY (same
    /// env var, same sibling-checkout fallback, same "fails loud naming both paths"
    /// rule) — duplicated here, not imported, because this runs from Swift before any
    /// subprocess exists yet; kept in lockstep by citing that function by name so a
    /// future change to one is a prompt to check the other.
    private static func resolveLiveCtrlKDRoot() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var tried: [String] = []
        if let env = ProcessInfo.processInfo.environment["CTRLKD_SRC"], !env.isEmpty {
            let trimmed = env.hasSuffix("/") ? String(env.dropLast()) : env
            let root = (trimmed as NSString).lastPathComponent == "src"
                ? (trimmed as NSString).deletingLastPathComponent : trimmed
            tried.append("\(root) (from $CTRLKD_SRC=\(trimmed))")
            if FileManager.default.fileExists(atPath: root + "/tools/fidelity_gate.py") {
                return root
            }
        } else {
            let sibling = repoRoot.deletingLastPathComponent().appendingPathComponent("ctrl-kd").path
            tried.append("\(sibling) (CTRLKD_SRC unset -- sibling-checkout fallback)")
            if FileManager.default.fileExists(atPath: sibling + "/tools/fidelity_gate.py") {
                return sibling
            }
        }
        throw SnapshotError(message: "PCLFidelitySnapshot: could not locate the ctrl-kd "
            + "checkout. Tried:\n" + tried.map { "  - \($0)" }.joined(separator: "\n"))
    }

    /// Copies `tools/`, `src/`, and `tests/pcl_fidelity_manifest.json` from `root` into
    /// a fresh temp directory, preserving their relative layout so ctrl-kd's own
    /// path arithmetic (`pcl_tolerance.MANIFEST_PATH` is computed relative to
    /// `tools/pcl_tolerance.py`'s own location) resolves unchanged. `cp -a` (not
    /// `FileManager.copyItem`) so mtimes survive the copy — a copied `.pyc` cache stays
    /// valid against its `.py`, no first-run recompile storm.
    ///
    /// Self-checked, with up to 3 attempts: ctrl-kd being mid-edit can make even THIS
    /// one-time copy land mid-write for the manifest (the file `--record` rewrites
    /// non-atomically — see this enum's own doc comment). A copy that lands mid-write
    /// fails the JSON-parse check below and is retried, never accepted silently — the
    /// same "never a silent skip, never a silent pass" rule the driver's own module
    /// docstring states for a missing ctrl-kd checkout.
    private static func copySnapshot(from root: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctrlkd-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lastError: String = "no attempt made"
        for attempt in 1...3 {
            for sub in ["tools", "src"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(sub))
                let cp = Process()
                cp.executableURL = URL(fileURLWithPath: "/bin/cp")
                cp.arguments = ["-a", "\(root)/\(sub)", dir.appendingPathComponent(sub).path]
                try cp.run()
                cp.waitUntilExit()
                guard cp.terminationStatus == 0 else {
                    throw SnapshotError(message: "PCLFidelitySnapshot: cp -a \(root)/\(sub) "
                        + "exited \(cp.terminationStatus)")
                }
            }
            let testsDir = dir.appendingPathComponent("tests")
            try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
            let manifestSrc = "\(root)/tests/pcl_fidelity_manifest.json"
            let manifestDst = testsDir.appendingPathComponent("pcl_fidelity_manifest.json").path
            let cpManifest = Process()
            cpManifest.executableURL = URL(fileURLWithPath: "/bin/cp")
            cpManifest.arguments = ["-a", manifestSrc, manifestDst]
            try cpManifest.run()
            cpManifest.waitUntilExit()
            guard cpManifest.terminationStatus == 0 else {
                throw SnapshotError(message: "PCLFidelitySnapshot: cp -a \(manifestSrc) exited "
                    + "\(cpManifest.terminationStatus)")
            }

            // Self-check 1: the manifest -- the one file this driver's own investigation
            // caught mid-write in the wild (ctrl-kd's own `--record` path truncates then
            // writes, non-atomically). A snapshot whose manifest doesn't even parse is
            // worse than no snapshot -- retry rather than hand a broken copy to 18 test
            // cases.
            var manifestOK = false
            if let data = FileManager.default.contents(atPath: manifestDst) {
                do {
                    _ = try JSONSerialization.jsonObject(with: data)
                    manifestOK = true
                } catch {
                    lastError = "attempt \(attempt): manifest copy did not parse as JSON "
                        + "(\(data.count) bytes) -- ctrl-kd was mid-write; \(error)"
                }
            } else {
                lastError = "attempt \(attempt): could not read copied manifest at \(manifestDst)"
            }

            // Self-check 2: the two Python modules this driver actually imports still
            // import cleanly from the copy -- catches a `.py` file caught mid-save (an
            // editor/tool truncating-then-rewriting a source file the same way the
            // manifest gets truncated-then-rewritten), which self-check 1 alone can't
            // see. A syntax error here means the SOURCE was torn, not that the tool is
            // broken -- retry, same as the manifest case.
            if manifestOK {
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                probe.arguments = ["python3", "-c",
                    "import sys; sys.path.insert(0, \(dir.appendingPathComponent("tools").path.debugDescription)); "
                    + "import fidelity_gate, pcl_tolerance"]
                let probePipe = Pipe()
                probe.standardOutput = probePipe
                probe.standardError = probePipe
                try probe.run()
                let probeOut = probePipe.fileHandleForReading.readDataToEndOfFile()
                probe.waitUntilExit()
                if probe.terminationStatus == 0 {
                    return dir.path  // good copy
                }
                let text = String(data: probeOut, encoding: .utf8) ?? "<undecodable>"
                lastError = "attempt \(attempt): copied tools/{fidelity_gate,pcl_tolerance}.py "
                    + "did not import cleanly -- ctrl-kd source was mid-write: \(text)"
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw SnapshotError(message: "PCLFidelitySnapshot: \(lastError) -- ctrl-kd's working "
            + "tree would not settle after 3 attempts; see this enum's own doc comment")
    }

    /// The frozen ctrl-kd root for this ENTIRE `swift test` process — computed exactly
    /// once (Swift's `static let` initializer is itself the thread-safe one-time-init
    /// this needs, no custom lock). `Result`, not a throwing `static let` (Swift doesn't
    /// allow the latter): every caller unwraps via `root()` below, so a snapshot failure
    /// surfaces as a normal thrown `SnapshotError` at first use, same shape as any other
    /// driver failure, not a crash at static-initialization time.
    private static let snapshotResult: Result<String, Error> = {
        // Force the `atexit` handler's own one-time registration (see
        // `atexit_cleanup_registered`'s doc comment) -- a global `let` nothing ever
        // reads would never actually run its initializer, since Swift globals are
        // lazily initialized on first access; this reference IS that first access.
        _ = atexit_cleanup_registered
        do {
            let live = try resolveLiveCtrlKDRoot()
            let copy = try copySnapshot(from: live)
            atexit_cleanup_paths.withLock { $0.append(copy) }
            return .success(copy)
        } catch {
            return .failure(error)
        }
    }()

    /// The snapshot's own root directory (holding `tools/`, `src/`, `tests/`) -- pass
    /// `"\(root())/src"` as the subprocess's `$CTRLKD_SRC` override.
    static func root() throws -> String {
        try snapshotResult.get()
    }
}

/// Snapshot directories registered for best-effort cleanup at process exit (never
/// relied upon for correctness -- `/tmp` housekeeping only). A plain global `var` guarded
/// by `NSLock` rather than an actor: `atexit`'s C callback cannot `await`.
///
/// `atexit_cleanup_registered` below is a global `let` purely for its SIDE EFFECT
/// (registering the handler); Swift globals initialize lazily on first access, so
/// `PCLFidelitySnapshot.snapshotResult`'s own initializer explicitly touches it
/// (`_ = atexit_cleanup_registered`) before doing anything else -- without that touch,
/// nothing would ever force this initializer to run and the handler would never
/// register.
private final class LockedArray<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()
    func withLock<R>(_ body: (inout [T]) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&items)
    }
}
private let atexit_cleanup_paths = LockedArray<String>()
private let atexit_cleanup_registered: Bool = {
    atexit {
        for path in atexit_cleanup_paths.withLock({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    return true
}()

enum PCLFidelityDriver {
    struct DriverError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// `Tests/CtrlKDTests/PCLFidelityTests.swift` -> `Support/run_pcl_fidelity_gate.py`
    /// sits directly alongside this file's own directory.
    static let scriptURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Support/run_pcl_fidelity_gate.py")

    /// Runs `run_pcl_fidelity_gate.py` with `args`, parsed stdout as a JSON object.
    /// stdout and stderr share ONE pipe (never two): a subprocess whose combined output
    /// exceeds the pipe buffer would otherwise risk the classic `Process`/`Pipe`
    /// deadlock (child blocks writing a full pipe while the parent blocks reading only
    /// the OTHER one) — some `report` payloads here (a document's full recorded
    /// manifest entry, capped at 40 divergences per reason) are large enough that this
    /// is a real risk, not a theoretical one. Draining that merged pipe fully BEFORE
    /// `waitUntilExit()` is itself required for the same reason.
    ///
    /// `$CTRLKD_SRC` is overridden (never inherited bare) to point at
    /// `PCLFidelitySnapshot`'s own frozen copy — see that enum's doc comment for why:
    /// the live ctrl-kd checkout this env var would otherwise name can be, and during
    /// this driver's own development WAS, mid-edit by another session at the same time
    /// this suite runs. `$CTRLKD_PRIVATE_CORPUS`/`$CTRLKD_SAWYER_ARCHIVE` are NOT
    /// overridden -- that corpus is read-only data no session writes to, unlike ctrl-kd's
    /// own working tree.
    static func run(_ args: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + args
        var env = ProcessInfo.processInfo.environment
        env["CTRLKD_SRC"] = "\(try PCLFidelitySnapshot.root())/src"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: outData, encoding: .utf8) ?? "<undecodable output>"
            // Distinguished from a mismatch below by KIND, not just message text: this
            // throws (a Swift Testing "error thrown" issue, reported separately from an
            // `Issue.record` call) whenever the GATE ITSELF failed to run or crashed --
            // never silently reinterpreted as "ran and differs".
            throw DriverError(message: """
                run_pcl_fidelity_gate.py \(args.joined(separator: " ")) exited \
                \(process.terminationStatus):
                \(text)
                """)
        }
        guard let obj = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            let text = String(data: outData, encoding: .utf8) ?? "<undecodable output>"
            throw DriverError(message: """
                run_pcl_fidelity_gate.py \(args.joined(separator: " ")) did not print a JSON \
                object:
                \(text)
                """)
        }
        return obj
    }

    /// Phase 1 — does `doc` resolve to a real `.WS`/`.WS4` source in the current corpus?
    /// `{"resolvable": true, "ws_path": "..."}` or `{"resolvable": false, "reason": "..."}`,
    /// either way alongside ctrl-kd's OWN recorded manifest entry for `doc` (verbatim,
    /// unsummarized — only used here for the `.enabled` sentinel's own sanity check).
    static func resolve(_ doc: String) throws -> [String: Any] {
        // `--doc=NAME`, not `report NAME` / `--doc NAME`: `-README`/`-SCREEN` are real
        // captured document names starting with a literal hyphen, which argparse (on the
        // Python side) would otherwise mistake for an unrecognized option — see
        // run_pcl_fidelity_gate.py's own `--doc` argument comment.
        try run(["report", "--doc=\(doc)"])
    }

    /// Phase 2 — splice `pdfPath` (this repo's own rendered Printed PDF for `doc`) into
    /// ctrl-kd's `pcl_tolerance.doc_report()` and report both the live (sr) result and
    /// ctrl-kd's recorded manifest entry, pre-summarized (`verdict`, `counts_by_reason`,
    /// `real_bug_count`, `divergence_lines`) plus `matches_recorded` — see
    /// `run_pcl_fidelity_gate.py`'s own `_summarize`/`cmd_report` for exactly what each
    /// field means and how the comparison is made (Python dict equality on ctrl-kd's own
    /// live-vs-recorded dicts, never re-derived here).
    static func gate(_ doc: String, pdfPath: String) throws -> [String: Any] {
        try run(["report", "--doc=\(doc)", "--pdf", pdfPath])
    }

    /// `core.parse(data)` -> resolve this document's own real `doc.graphics` references
    /// against its own on-disk path -> `pdf.emit_pdf(doc, mode='printed', pictures='embed',
    /// pix_results=...)` — the EXACT construction `tools/fidelity_gate.py`'s own
    /// `render_engine_pdf` uses as of ctrl-kd `98e03f9` (mechanism L revisited, planning
    /// #211): that function used to call `emit_pdf(doc, mode='printed')` with zero options,
    /// which defaults `pictures` to the LIBRARY default 'off' (the opposite of the CLI's
    /// own 'embed' default) — so a picture-bearing captured document (PREVIEW, -SCREEN,
    /// -README) was never actually exercised through this gate with its picture embedded.
    /// Swift mirror: `resolveDocumentPictures` (real filesystem access, same contract as
    /// ctrl-kd's `pictures.resolve_document_pictures`) against `wsPath` itself, then
    /// `emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults:
    /// ...))`. For a document with no picture reference this changes nothing (empty
    /// `pixResults`, `.embed` behaves identically to `.off`) — see this file's own header
    /// comment for why this is deliberately NOT `CorpusParityTests.renderedPDF`'s fuller
    /// construction (no `sawyer` page-settings preset here, picture resolution only).
    static func renderPrintedPDF(wsPath: String) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: wsPath) else {
            throw DriverError(message: "could not read \(wsPath) (resolved by ctrl-kd's own "
                + "fidelity_gate.resolve_doc_paths, but not readable from this process)")
        }
        let doc = try parse([UInt8](data), variant: nil)
        let pixResults = resolveDocumentPictures(doc, docPath: wsPath,
                                                  environment: answerKeyRealFilesystemEnvironment())
        return emitPDF(doc, mode: .printed, options: EmitOptions(pictures: .embed, pixResults: pixResults))
    }
}

@Suite struct PCLFidelityTests {

    // MARK: - Gate sentinel — the ONE named skip when unarmed

    @Test(.enabled(if: ctrlkdPrivateCorpusArmed, ctrlkdPrivateCorpusSkipReason))
    func pclFidelityGateIsArmed() throws {
        // A real armed run must at least be able to reach ctrl-kd and its manifest for
        // one known document — if this fails, every parameterized case below will fail
        // the same way, but this is the one test that names the SETUP problem instead of
        // 18 identical per-document tracebacks.
        let result = try PCLFidelityDriver.resolve("LYING")
        #expect(result["resolvable"] as? Bool == true,
                "expected LYING to resolve once CTRLKD_PRIVATE_CORPUS is armed: \(result)")
    }

    // MARK: - Per-document PCL fidelity, cross-checked against ctrl-kd's own manifest

    static var armedDocs: [String] {
        ctrlkdPrivateCorpusArmed ? capturedDocs : []
    }

    @Test(arguments: armedDocs)
    func pclFidelity(doc: String) throws {
        let resolution = try PCLFidelityDriver.resolve(doc)
        guard resolution["resolvable"] as? Bool == true else {
            // Mirrors ctrl-kd's OWN `test_pcl_fidelity.py`: a document whose live
            // `doc_report()` verdict is `source-missing` is `pytest.skip`ped there, not
            // failed — an unresolvable source is a corpus-completeness gap (which
            // document names resolve depends on `ws7-prints/v1/sources.json`, still being
            // completed as of this writing), not a placement bug. `CTRLKD_PRIVATE_CORPUS`
            // being armed at all is still checked hard, above.
            let reason = resolution["reason"] as? String ?? "not resolvable in this corpus"
            withKnownIssue("PCL fidelity, \(doc): source not available in this corpus — \(reason)") {
                Issue.record("\(doc): \(reason)")
            }
            return
        }
        guard let wsPath = resolution["ws_path"] as? String else {
            Issue.record("\(doc): resolvable but no ws_path in driver output: \(resolution)")
            return
        }

        let pdf = try PCLFidelityDriver.renderPrintedPDF(wsPath: wsPath)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcl-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pdfURL = tempDir.appendingPathComponent("\(doc)-sr-printed.pdf")
        try Data(pdf).write(to: pdfURL)

        let report = try PCLFidelityDriver.gate(doc, pdfPath: pdfURL.path)
        guard let live = report["live"] as? [String: Any] else {
            Issue.record("\(doc): driver returned no live report: \(report)")
            return
        }
        let recorded = report["recorded"] as? [String: Any]
        let matchesRecorded = report["matches_recorded"] as? Bool ?? false
        let realBugCount = live["real_bug_count"] as? Int ?? -1
        let liveCounts = live["counts_by_reason"] as? [String: Int] ?? [:]
        let divergenceLines = (live["divergence_lines"] as? [String]) ?? []

        // Check 2 first (cross-engine identity) — this is the one that should be
        // unconditionally true if sr's Printed PDF really is byte-identical to
        // ctrl-kd's for this document, and its failure message is the most actionable
        // if something regressed.
        if !matchesRecorded {
            let detail = report["mismatch_detail"] as? String ?? "no detail from driver"
            let recordedCounts = (recorded?["counts_by_reason"] as? [String: Int]) ?? [:]
            Issue.record("""
                \(doc): sr's PCL-fidelity divergence set does NOT match ctrl-kd's own \
                recorded manifest entry — a real cross-engine divergence, not merely an \
                unfixed WS7-fidelity gap. \(detail)
                  sr counts_by_reason:      \(liveCounts)
                  ctrl-kd counts_by_reason: \(recordedCounts)
                """)
        }

        // Check 1 (ctrl-kd's own "clean" bar). Expected, today, to fail for every
        // document ctrl-kd itself reports divergent for (planning issue #202) — that is
        // this test reporting a REAL, already-known bug by name, not a test bug.
        if realBugCount != 0 {
            let shown = divergenceLines.joined(separator: "\n  ")
            Issue.record("""
                \(doc): \(realBugCount) non-font-substitution PCL-fidelity divergence(s) \
                (counts_by_reason=\(liveCounts)) — see planning issue #202:
                  \(shown)
                """)
        }
    }
}
