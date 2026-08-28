#if DEBUG
import Foundation

/// Job 152 Part C, step 12: the empirical sandbox question that decides the shipped UX for
/// Help ▸ "Index All WordStar Documents…". `Process` docs say a sandboxed app's child
/// processes "inherit the sandbox of the parent app" — so does `/usr/bin/mdimport <path>`,
/// spawned by THIS sandboxed Release app, actually succeed at reading and indexing a file the
/// app has never been granted access to (outside any user-selected scope, no security-scoped
/// bookmark, not inside the app's own container)? `mdfind`'s own return, done from OUTSIDE the
/// app afterwards, is a weaker signal than it looks — the system's own ambient `mdworker`
/// indexing runs independent of any one app's sandbox, so it can index a matching file on its
/// own regardless of what this app did; the mdimport SPAWN's own exit code/output, captured
/// here, is what is actually attributable to the app.
///
/// Writes its one-line verdict to `UserDefaults` key `backfillSelfTest.result` — and, per
/// `AppleEventSelfTest`'s doc comment on why `UserDefaults`/`cfprefsd` alone is not trusted in
/// this environment, also a plain-file marker.
///
/// Job 219 (`SoftReturnDiagnostics`, finding B8): moved into the diagnostics module and
/// `#if DEBUG` (compiled out of Release entirely). The probe path — previously a HARDCODED
/// worker-machine literal (a hardcoded absolute path to a developer's own scratch file)
/// compiled into the shipping binary — must not ship in ANY config, so it is now read from the environment
/// (`SR_BACKFILL_SELFTEST_PATH`) instead of a compiled-in literal; there is no default fallback
/// outside the app's own container, so an unset variable degrades to "not provided" rather than
/// silently pointing at a path that only ever existed on one developer's machine. The old
/// dedicated `SR_BACKFILL_SELFTEST` flag is gone — this now checks the one module-wide
/// `SRDiagnosticsGate` instead, per Jon's ruling against per-tool flags.
enum SpotlightBackfillSelfTest {
    static let resultDefaultsKey = "backfillSelfTest.result"

    /// Provisioned externally, before launch, at a path OUTSIDE this app's sandbox container
    /// and outside any path the app has ever been granted (no open-panel selection, no
    /// bookmark) — the job brief's own "outside any granted scope" fixture. Read from the
    /// environment rather than a compiled-in literal: whoever runs this self-test names the
    /// path themselves via `SR_BACKFILL_SELFTEST_PATH`, since the whole point of the experiment
    /// is a file the app was never granted, and no such path can be guessed at compile time
    /// without baking in one specific machine.
    private static var probeURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["SR_BACKFILL_SELFTEST_PATH"] else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static var debugMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("backfillSelfTest.result.txt")
    }

    static func runIfRequested() {
        guard SRDiagnosticsGate.isEnabled() else { return }
        record("started")
        Task { @MainActor in
            let direct = performDirectSpawn()
            let engine = await performRealEngine()
            let result = "\(direct) | \(engine)"
            NSLog("[SoftReturn] backfillSelfTest.result = %@", result)
            record(result)
        }
    }

    private static func record(_ result: String) {
        UserDefaults.standard.set(result, forKey: resultDefaultsKey)
        try? result.write(to: debugMarkerURL, atomically: true, encoding: .utf8)
    }

    /// The attributable signal: the exact `mdimport <path>` spawn the engine itself makes,
    /// called directly so its exit code/output cannot be confused with the system's own
    /// ambient `mdworker` indexing (which runs independent of this app's sandbox — see the
    /// type doc comment).
    private static func performDirectSpawn() -> String {
        guard let probeURL else {
            return "direct: unhandled, no path provided (set SR_BACKFILL_SELFTEST_PATH)"
        }
        guard FileManager.default.fileExists(atPath: probeURL.path) else {
            return "direct: unhandled, probe missing at \(probeURL.path)"
        }
        let runner = ProcessMDImportRunner()
        let result = runner.run(arguments: [probeURL.path])
        return "direct: mdimport path=\(probeURL.path) exitCode=\(result.exitCode) "
            + "output=\(result.output.isEmpty ? "<empty>" : result.output)"
    }

    /// The production entry point itself — `NSMetadataQuery`, not a canned candidate list —
    /// scoped to just `.wsd` so the whole-computer gather does not take longer than this
    /// self-test's own patience. Proves the query is genuinely awaitable in this sandboxed
    /// process (the packet's fallback-to-MDQuery contingency), not just that a fake finder
    /// satisfies the protocol in tests.
    @MainActor
    private static func performRealEngine() async -> String {
        let finder = NSMetadataQueryCandidateFinder()
        let final = await SpotlightBackfill.run(finder: finder, extensions: ["wsd"])
        return "engine: found=\(final.found) requested=\(final.requested) done=\(final.done)"
    }
}
#endif
