import Foundation
import os

/// Injection seam for spawning `mdimport` — the ONLY thing standing between
/// `SpotlightNudge`'s gating logic and a real subprocess launch, so unit tests can exercise
/// "once per (version, importer path)" without ever spawning `mdimport` for real. See
/// `SpotlightNudgeTests`.
protocol MDImportRunning {
    func run(arguments: [String]) -> SpotlightNudge.RunResult
}

/// The self-nudge that makes "download → drag to /Applications → launch once" enough for
/// Spotlight to find pre-existing WordStar files: a user cannot be asked to run
/// `mdimport -r <importer>` themselves (job-138), so the app runs it for them.
///
/// Gated to once per (`CFBundleVersion`, importer path) pair, tracked in `UserDefaults` — a
/// version bump or a relocated `.app` both count as "new" and get one more attempt; a rerun
/// of the exact same build does not, whether or not the earlier attempt actually succeeded.
/// That last part is deliberate: a sandboxed launch that gets denied every time would
/// otherwise retry on every single launch forever, which is noise, not progress — the escape
/// hatch for "I want to try again right now" is `runUnconditionally` below, not automatic
/// retries.
enum SpotlightNudge {
    struct RunResult: Equatable {
        let exitCode: Int32
        let output: String
    }

    struct State: Equatable {
        let version: String
        let importerPath: String
        let ranAt: Date
        let exitCode: Int32
        let output: String
    }

    static let subsystem = "me.beforeti.softreturn"
    private static let logger = Logger(subsystem: subsystem, category: "spotlight-nudge")
    private static let defaultsKey = "spotlightNudge.lastRun"

    /// The classic `.mdimporter`'s installed location. Fixed and derivable, not discovered:
    /// `Project.swift`'s "Embed Spotlight Importer" copy phase always lands the
    /// `SoftReturnImporter` bundle product at exactly this path inside the app, because a
    /// `.bundle` product (unlike `.appExtension`) has no auto-embed destination of its own.
    static func importerPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Library/Spotlight/SoftReturnImporter.mdimporter")
            .path
    }

    static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Pure gating decision, split out from `runIfNeeded` so it is testable with no `Bundle`,
    /// no `UserDefaults`, and no process spawn in sight.
    static func shouldRun(state: State?, version: String, importerPath: String) -> Bool {
        guard let state else { return true }
        return state.version != version || state.importerPath != importerPath
    }

    /// Called once at launch. `perform` hands the actual run to a background queue by
    /// default — a slow Spotlight metadata-store lock must not delay the menu bar appearing
    /// — so this returns before the record in `readState` reflects the outcome; the job-138
    /// empirical proof polls `readState` after a short delay instead of awaiting this. Tests
    /// inject a synchronous `perform` (`{ $0() }`) so they can assert on the outcome
    /// immediately with no timing dependency at all.
    static func runIfNeeded(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                            runner: MDImportRunning = ProcessMDImportRunner(),
                            perform: @escaping (@escaping () -> Void) -> Void =
                                { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        let version = currentVersion(bundle: bundle)
        let path = importerPath(bundle: bundle)
        guard shouldRun(state: readState(defaults: defaults), version: version, importerPath: path) else {
            logger.info("skipping: already ran for this version and importer path")
            return
        }
        perform {
            runAndRecord(version: version, importerPath: path, defaults: defaults, runner: runner)
        }
    }

    /// The same call as `runIfNeeded`, but unconditional and synchronous — the gate above
    /// exists to stop automatic launches from retrying forever, not to stop a deliberate
    /// re-run. No longer wired to the Help menu (job 152 Part C replaced that item with
    /// `SpotlightBackfill`'s per-file enumeration); kept as a standalone, tested escape hatch
    /// for the bulk `-r` request.
    @discardableResult
    static func runUnconditionally(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                                   runner: MDImportRunning = ProcessMDImportRunner()) -> RunResult {
        runAndRecord(version: currentVersion(bundle: bundle), importerPath: importerPath(bundle: bundle),
                    defaults: defaults, runner: runner)
    }

    @discardableResult
    private static func runAndRecord(version: String, importerPath: String, defaults: UserDefaults,
                                     runner: MDImportRunning) -> RunResult {
        let result = runner.run(arguments: ["-r", importerPath])
        if result.exitCode == 0 {
            logger.info("mdimport -r succeeded")
        } else {
            logger.error("mdimport -r failed rc=\(result.exitCode, privacy: .public): \(result.output, privacy: .public)")
        }
        writeState(State(version: version, importerPath: importerPath, ranAt: Date(),
                         exitCode: result.exitCode, output: result.output), defaults: defaults)
        return result
    }

    // MARK: - UserDefaults record

    /// Stored as a plain dictionary of property-list values, not an encoded blob — so
    /// `defaults read me.beforeti.softreturn` (or a container-plist read via `plistlib`)
    /// shows the record directly, which is what job-138's empirical sandbox proof reads back.
    static func readState(defaults: UserDefaults = .standard) -> State? {
        guard let dict = defaults.dictionary(forKey: defaultsKey),
              let version = dict["version"] as? String,
              let importerPath = dict["importerPath"] as? String,
              let ranAt = dict["ranAt"] as? Date,
              let exitCode = dict["exitCode"] as? Int
        else { return nil }
        return State(version: version, importerPath: importerPath, ranAt: ranAt,
                    exitCode: Int32(exitCode), output: dict["output"] as? String ?? "")
    }

    private static func writeState(_ state: State, defaults: UserDefaults) {
        defaults.set([
            "version": state.version,
            "importerPath": state.importerPath,
            "ranAt": state.ranAt,
            "exitCode": Int(state.exitCode),
            // Capped: mdimport's own diagnostic output is not unbounded, but there is no
            // reason to let a UserDefaults record grow without one either.
            "output": String(state.output.suffix(4000)),
        ], forKey: defaultsKey)
    }
}

/// The real spawn: `/usr/bin/mdimport -r <path>`. Under App Sandbox this is expected — see
/// job-138's empirical proof — to have `process.run()` throw before the process ever starts;
/// that failure is reported as `RunResult(exitCode: -1, ...)` rather than propagated, because
/// every caller of `MDImportRunning` already has to handle a nonzero exit code and a second
/// error path would only be more to test.
struct ProcessMDImportRunner: MDImportRunning {
    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return SpotlightNudge.RunResult(exitCode: -1, output: "launch failed: \(error)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return SpotlightNudge.RunResult(exitCode: process.terminationStatus,
                                        output: String(data: data, encoding: .utf8) ?? "")
    }
}
