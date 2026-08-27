import Foundation

/// Job 199 (b10 leg 1b, continuing 143-198): every in-process reproduction layer for the
/// field -1708 is now exhausted, including a byte-exact replay of the real captured event
/// (job 198) — see `ConvertCommandReceiverDispatchTests.swift`'s trailing extension. The
/// failure provably requires a REAL cross-process delivery, which only happens on the field
/// machine. This is not another in-process probe: it is an evidence trail, left inside
/// `ConvertCommand`'s own Cocoa dispatch lifecycle, that survives to be read back after a
/// real field failure — which override points Cocoa's real delivery reaches before dying
/// -1708 is itself the diagnostic payload.
///
/// Modeled directly on `SpotlightTriggerBreadcrumbs` (see that file) — plain property-list
/// values in an append-only `UserDefaults` ring buffer, readable via `defaults read` with no
/// extra tooling, same rationale: the point is the SEQUENCE of stages a real dispatch reaches,
/// not just the latest one.
///
/// Job 219 (`SoftReturnDiagnostics`, finding B7): the ONE exception in this module that stays
/// compiled into every configuration, including Release — `record` is called unconditionally
/// from `ConvertCommand`'s override points, which ship in Release. Wrapping this file in
/// `#if DEBUG` (like the rest of the module) would mean deleting those call sites too, and the
/// brief is explicit: keep the recording functions available to the module, make the CALLS
/// inert in release instead. That happens here, not at each call site — `record` no-ops unless
/// `SRDiagnosticsGate.isEnabled()`, so `ConvertCommand` needs no changes at all; its hooks are
/// unconditional in source but produce nothing by default in a shipping build.
enum AppleEventLifecycleBreadcrumbs {
    struct Entry: Equatable {
        let ts: Date
        let stage: String
        let detail: String
    }

    static let defaultsKey = "aeDiagnostics.lifecycle"
    private static let capacity = 40
    /// Job 237 (ae-timeline): raised from 500 — a detail string that now carries an 8-frame
    /// `Thread.callStackSymbols` summary alongside the timestamp/AE-identity fields easily runs
    /// past the old cap (symbol lines run 100-150 chars each), and a silently truncated stack is
    /// worse than no stack: it would look complete while dropping exactly the frames a caller
    /// classification needs. 40 entries at this cap is still a few hundred KB at most, well
    /// inside `UserDefaults`/property-list limits.
    private static let detailCap = 2500
    private static let lock = NSLock()

    /// Appends one breadcrumb, dropping the oldest once the ring buffer is at `capacity`. A
    /// no-op unless `SRDiagnosticsGate.isEnabled()` — see this type's header. Otherwise
    /// failure-proof: no throwing call in here, only the lock guarding the read-modify-write —
    /// Cocoa can invoke these override points on whatever thread delivers the Apple Event.
    static func record(stage: String, detail: String = "", defaults: UserDefaults = .standard) {
        guard SRDiagnosticsGate.isEnabled(defaults: defaults) else { return }
        let entry: [String: Any] = [
            "ts": Date(),
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

    /// Read-back for tests and report tooling; the field round trip is `defaults read`/
    /// `plutil -p` directly on the array, not this.
    static func readEntries(defaults: UserDefaults = .standard) -> [Entry] {
        let raw = defaults.array(forKey: defaultsKey) as? [[String: Any]] ?? []
        return raw.compactMap { dict in
            guard let ts = dict["ts"] as? Date,
                  let stage = dict["stage"] as? String,
                  let detail = dict["detail"] as? String
            else { return nil }
            return Entry(ts: ts, stage: stage, detail: detail)
        }
    }
}
