import Foundation

/// Job-173 (b7 Phase 1): job-172 proved the index-on-open/index-on-view trigger CODE is sound,
/// yet on the field machine the triggers produce no indexed files while Help ▸ Index All — the
/// byte-identical call path — works. That failure could not be reproduced in this harness, so
/// instead of another in-process fix this ships an evidence trail: every `requestIndex` call
/// leaves a breadcrumb in `UserDefaults`, readable on the field machine after the fact.
///
/// Modeled on `SpotlightNudge`'s record (see that file) — plain property-list values so
/// `defaults read` shows it directly — but an append-only ring buffer instead of a single
/// overwritten dict, since the point here is the SEQUENCE of stages a call reaches, not just
/// the latest one. Deliberately has no `os_log` dependency: os_log is the observation channel
/// that failed to explain the field symptom, so `UserDefaults` is the replacement, not a
/// second copy of the same channel.
enum SpotlightTriggerBreadcrumbs {
    struct Entry: Equatable {
        let ts: Date
        let category: String
        let path: String
        let stage: String
        let detail: String
    }

    private static let defaultsKey = "spotlightTrigger.breadcrumbs"
    private static let capacity = 40
    private static let detailCap = 500
    private static let lock = NSLock()

    /// Appends one breadcrumb, dropping the oldest once the ring buffer is at `capacity`.
    /// Failure-proof like `SpotlightFileIndexer` itself: no throwing call in here, and the only
    /// blocking is the lock guarding the read-modify-write, since calls arrive from arbitrary
    /// queues (background `perform` blocks, appex extension queues, main-thread document opens).
    static func record(category: String, path: String?, stage: String, detail: String,
                       defaults: UserDefaults = .standard) {
        let entry: [String: Any] = [
            "ts": Date(),
            "category": category,
            "path": path ?? "",
            "stage": stage,
            "detail": String(detail.prefix(detailCap)),
        ]
        lock.lock()
        defer { lock.unlock() }
        var entries = defaults.array(forKey: defaultsKey) as? [[String: Any]] ?? []
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        defaults.set(entries, forKey: defaultsKey)
    }

    /// Read-back for tests and for inspecting a live domain from Swift; the field round trip is
    /// `defaults read`/`plutil -p` directly on the array, not this.
    static func readEntries(defaults: UserDefaults = .standard) -> [Entry] {
        let raw = defaults.array(forKey: defaultsKey) as? [[String: Any]] ?? []
        return raw.compactMap { dict in
            guard let ts = dict["ts"] as? Date,
                  let category = dict["category"] as? String,
                  let path = dict["path"] as? String,
                  let stage = dict["stage"] as? String,
                  let detail = dict["detail"] as? String
            else { return nil }
            return Entry(ts: ts, category: category, path: path, stage: stage, detail: detail)
        }
    }
}
