import Foundation
import os

/// Job 178 (b8): the view-extension index triggers (`SoftReturnQuickLook`/`SoftReturnThumbnail`)
/// proved on the b7 console that their hooks FIRE but the spawn dies — `rc=-1 launch failed:
/// The file "mdimport" doesn't exist (NSFilePath=/usr/bin/mdimport)`. The extension sandbox has
/// no `/usr/bin/mdimport` to spawn at all; the app-side spawn is proven (rc=0, same night). So
/// extensions can no longer request indexing directly — they enqueue a {path, category, ts}
/// record into this file, in the shared app-group container, and the app (which CAN spawn
/// `mdimport`) drains it through the existing, proven `SpotlightFileIndexer`.
///
/// **Why NSFileCoordinator, not a lock file**: this queue file is written from at least three
/// separate OS processes (the app draining, and each of the QuickLook/Thumbnail extensions
/// enqueuing — Finder can spin up either extension multiple times concurrently for a folder of
/// documents). A bespoke lock file would have to reimplement exactly what `NSFileCoordinator`
/// already does for this precise case; per `Foundation/NSFileCoordinator.h` (SDK header, tier 1):
/// coordinated reads/writes from coordinators with distinct purpose identifiers — the default,
/// one per instance — genuinely serialize against each other "even if they exist in different
/// processes." That is the exact cross-process safety this queue needs, so each call below
/// creates its own coordinator (no shared purpose id) and lets the OS do the serialization.
enum SpotlightIndexQueue {
    struct Entry: Equatable {
        let path: String
        let category: String
        let ts: Date
    }

    static let subsystem = "me.beforeti.softreturn"

    /// Team-ID-prefixed per the job brief. Doc-citation gap, reported loudly rather than
    /// invented: the SDK header (`NSFileManager.h`,
    /// `containerURLForSecurityApplicationGroupIdentifier:`) confirms the API and mechanism,
    /// but the naming CONVENTION for the identifier string itself (team-ID prefix required by
    /// the App Groups provisioning capability) lives in Apple's App Groups capability /
    /// Entitlement Key Reference pages, which this worker has no network path to fetch (see
    /// `.claude/skills/macos-document-app/references/apple-docs-access.md` — WebFetch to
    /// sosumi.ai was denied by this session's own permission model, confirming the "worker has
    /// no network" description empirically, not just by that doc's say-so). See the job report.
    static let groupIdentifier = "RC448RH3EN.softreturn"

    /// Cap chosen by the brief, not derived — matches `SpotlightTriggerBreadcrumbs`' capacity
    /// being a similarly-fixed round number for the same reason: bounded growth of a
    /// perpetually-appended file with no natural retention policy of its own.
    static let capacity = 500

    private static let fileName = "spotlight-index-queue.plist"

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    static func fileURL(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(fileName)
    }

    /// Appends one entry, deduped by path (a path already queued is left exactly where it is —
    /// re-enqueuing an already-pending file is a no-op, not a reorder) and capped at `capacity`
    /// (oldest entries dropped first, same FIFO-eviction shape as
    /// `SpotlightTriggerBreadcrumbs`'s ring buffer). Failure-proof like `SpotlightFileIndexer`:
    /// no throwing call reaches the caller — a missing container (entitlement not granted/not
    /// yet provisioned) or a coordination failure both resolve to a breadcrumb, never a crash or
    /// a propagated error. `perform` defaults to a background queue so extension call sites
    /// (`provideThumbnail`/`providePreview`) are never blocked by the coordinated disk write;
    /// tests inject a synchronous `perform` to assert the result immediately.
    static func enqueue(path: String?, category: String,
                        containerURL: URL? = SpotlightIndexQueue.containerURL(),
                        defaults: UserDefaults = .standard,
                        now: Date = Date(),
                        perform: @escaping (@escaping () -> Void) -> Void =
                            { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "enqueue-called",
                                           detail: "pathWasNil=\(path == nil)", defaults: defaults)
        guard let path, !path.isEmpty else { return }
        let logger = Logger(subsystem: subsystem, category: category)
        guard let containerURL else {
            logger.error("enqueue skipped \(path, privacy: .public): no app-group container (entitlement missing?)")
            SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "queue-failed",
                                               detail: "no app-group container", defaults: defaults)
            return
        }
        perform {
            let fileURL = fileURL(in: containerURL)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
                var entries = readEntries(at: coordinatedURL)
                guard !entries.contains(where: { $0.path == path }) else { return }
                entries.append(Entry(path: path, category: category, ts: now))
                if entries.count > capacity {
                    entries.removeFirst(entries.count - capacity)
                }
                writeEntries(entries, to: coordinatedURL)
            }
            if let coordinationError {
                logger.error("enqueue coordination failed \(path, privacy: .public): \(coordinationError.localizedDescription, privacy: .public)")
                SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "queue-failed",
                                                   detail: coordinationError.localizedDescription, defaults: defaults)
                return
            }
            SpotlightTriggerBreadcrumbs.record(category: category, path: path, stage: "queued",
                                               detail: "", defaults: defaults)
        }
    }

    /// A coordinated snapshot of every currently-queued entry, oldest first. Used by both the
    /// app's drain loop and tests; never mutates the file.
    static func peekAll(containerURL: URL? = SpotlightIndexQueue.containerURL()) -> [Entry] {
        guard let containerURL else { return [] }
        let fileURL = fileURL(in: containerURL)
        var result: [Entry] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
            result = readEntries(at: coordinatedURL)
        }
        return result
    }

    /// Removes exactly one entry by path. Called by the drain loop AFTER that entry's index
    /// spawn attempt, never before — see `drainAll`'s doc comment for why that ordering is what
    /// makes the drain crash-safe.
    static func remove(path: String, containerURL: URL? = SpotlightIndexQueue.containerURL()) {
        guard let containerURL else { return }
        let fileURL = fileURL(in: containerURL)
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
            var entries = readEntries(at: coordinatedURL)
            entries.removeAll { $0.path == path }
            writeEntries(entries, to: coordinatedURL)
        }
    }

    /// The app-side drain: on launch and on `applicationDidBecomeActive`, feeds every queued
    /// entry through the EXISTING, proven `SpotlightFileIndexer.requestIndex` (per-file,
    /// breadcrumbed, deduped) under category "index-on-view-drained" — this is the one place in
    /// the whole feature that ever actually calls `mdimport`, because only the app's own sandbox
    /// has it.
    ///
    /// **Crash-safety, at-least-once**: each entry is removed from the queue file only AFTER its
    /// own spawn attempt completes, one entry at a time — never as a single "clear everything"
    /// step before or during the loop. If the app is killed mid-drain, whatever hasn't been
    /// removed yet is still on disk for the next launch/activation to pick up. Reprocessing an
    /// already-indexed file is harmless: `SpotlightFileIndexer`'s own `DedupeWindow` absorbs the
    /// redundant request, so at-least-once costs nothing extra in the common case.
    ///
    /// `perform` (outer) backgrounds the whole drain so callers on the main thread
    /// (`applicationDidFinishLaunching`, `applicationDidBecomeActive`) never block; the inner
    /// `SpotlightFileIndexer.requestIndex` calls run synchronously WITHIN that background work
    /// (not their own separate async hop) so each entry's spawn-then-remove stays strictly
    /// ordered instead of racing the next entry's spawn.
    static func drainAll(containerURL: URL? = SpotlightIndexQueue.containerURL(),
                         runner: MDImportRunning = ProcessMDImportRunner(),
                         dedupe: SpotlightFileIndexer.DedupeWindow = .shared,
                         defaults: UserDefaults = .standard,
                         perform: @escaping (@escaping () -> Void) -> Void =
                             { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        perform {
            for entry in peekAll(containerURL: containerURL) {
                SpotlightFileIndexer.requestIndex(for: URL(fileURLWithPath: entry.path),
                                                  category: "index-on-view-drained",
                                                  runner: runner, dedupe: dedupe, defaults: defaults,
                                                  perform: { $0() })
                remove(path: entry.path, containerURL: containerURL)
            }
        }
    }

    // MARK: - plist I/O

    /// Plain property-list values (not `Codable`'s own plist encoding), same reasoning as
    /// `SpotlightTriggerBreadcrumbs`: the file must be directly readable with `plutil -p` on the
    /// user's own console with no decoder to hand — that IS the field-observability point of
    /// this whole feature.
    private static func readEntries(at url: URL) -> [Entry] {
        // Cache/queue file, best-effort: this queue's own `drainAll` doc comment already
        // establishes at-least-once via `SpotlightFileIndexer`'s dedupe, so a missing or
        // corrupt queue file just means "nothing queued yet" — the worst case is a Spotlight
        // reindex that a later nudge/backfill pass picks up anyway, never a user-visible
        // failure.
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { dict in
            guard let path = dict["path"] as? String,
                  let category = dict["category"] as? String,
                  let ts = dict["ts"] as? Date
            else { return nil }
            return Entry(path: path, category: category, ts: ts)
        }
    }

    private static func writeEntries(_ entries: [Entry], to url: URL) {
        // Same best-effort contract as `readEntries` above: a dropped write here costs one
        // queued reindex request, silently recovered by the next nudge/backfill pass.
        let raw: [[String: Any]] = entries.map { ["path": $0.path, "category": $0.category, "ts": $0.ts] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
