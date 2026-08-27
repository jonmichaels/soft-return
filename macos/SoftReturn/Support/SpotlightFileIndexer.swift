import Foundation
import os

/// Requests a per-file Spotlight reindex for a document as soon as something looks at it —
/// opening it in the app (job-145 Part A), showing its thumbnail, or QuickLooking it (Part B).
///
/// This is deliberately NOT `SpotlightNudge`'s `-r` bulk reimport: `-r` is a request the
/// metadata server may defer indefinitely (job-138's battery-throttled regression), while
/// `mdimport <path>` on a single file processes in seconds (empirically verified twice on
/// taco). Fire-and-forget: a failure here must never surface to the caller, so every path
/// swallows its own errors after an `os_log`.
enum SpotlightFileIndexer {
    static let subsystem = "me.beforeti.softreturn"

    /// Requests indexing of `url`, deduped against `dedupe` so rapid re-opens or repeated
    /// thumbnail/preview requests for the same file don't spawn a new `mdimport` every time —
    /// this is politeness, not correctness, so an in-memory window is enough. `category` names
    /// the caller in the log ("index-on-open", "index-on-view") per job-145.
    static func requestIndex(for url: URL?, category: String,
                             runner: MDImportRunning = ProcessMDImportRunner(),
                             dedupe: DedupeWindow = .shared,
                             defaults: UserDefaults = .standard,
                             perform: @escaping (@escaping () -> Void) -> Void =
                                 { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        // job-173: recorded synchronously, before the dedupe guard and before `perform`, so a
        // hook that fires but dies later (the field symptom this exists to diagnose) still
        // leaves a trace of having been called at all.
        SpotlightTriggerBreadcrumbs.record(category: category, path: url?.path, stage: "called",
                                           detail: "urlWasNil=\(url == nil)", defaults: defaults)
        guard let url else { return }
        let path = url.path
        let logger = Logger(subsystem: subsystem, category: category)
        guard dedupe.shouldRequest(path) else {
            logger.debug("skipping \(path, privacy: .public): requested within the dedupe window")
            SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "dedupe-skip",
                                               detail: "requested within the dedupe window", defaults: defaults)
            return
        }
        perform {
            let result = runner.run(arguments: [path])
            if result.exitCode == 0 {
                logger.info("mdimport \(path, privacy: .public) rc=0")
            } else {
                logger.error("mdimport \(path, privacy: .public) failed rc=\(result.exitCode, privacy: .public): \(result.output, privacy: .public)")
            }
            SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "spawn",
                                               detail: "rc=\(result.exitCode) \(result.output.suffix(200))",
                                               defaults: defaults)
        }
    }

    /// Tracks "requested in the last hour" per path. A plain dictionary behind a lock is
    /// enough — this only needs to survive one app session, not a relaunch.
    final class DedupeWindow: @unchecked Sendable {
        static let shared = DedupeWindow()

        private var lastRequested: [String: Date] = [:]
        private let lock = NSLock()
        private let window: TimeInterval

        init(window: TimeInterval = 3600) {
            self.window = window
        }

        func shouldRequest(_ path: String, now: Date = Date()) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let last = lastRequested[path], now.timeIntervalSince(last) < window {
                return false
            }
            lastRequested[path] = now
            return true
        }
    }
}
