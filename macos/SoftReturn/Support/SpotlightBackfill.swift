import Foundation
import os

/// Job 152 Part C: Help ▸ "Index All WordStar Documents…" — an aggressive backfill for files
/// that predate the app's install (or simply were never opened, thumbnailed, or QuickLooked)
/// and so never triggered `SpotlightFileIndexer`'s per-file nudge.
///
/// Candidates come from FILENAME metadata (`kMDItemFSName`), not content: per the spotlight
/// indexing packet, filename metadata exists for every file regardless of content-index state,
/// so this finds files Spotlight has never looked inside, not just ones it already indexed.
///
/// Two seams make the whole thing testable with no real `NSMetadataQuery` and no real
/// `mdimport` spawn: `MetadataQuerying` stands in for the query, `MDImportRunning` (already
/// used by `SpotlightFileIndexer`/`SpotlightNudge`) stands in for the spawn.
enum SpotlightBackfill {

    /// Jon's Tier-1 ruling (2026-08-08), copied verbatim from `Info.plist`'s
    /// `UTExportedTypeDeclarations` — that plist entry is the single source of truth for this
    /// list; this array exists only because the query predicate needs it as Swift values, and
    /// must be kept byte-for-byte identical to the plist, never edited independently of it.
    static let tier1Extensions: [String] = [
        "ws", "ws0", "ws1", "ws2", "ws3", "ws4", "ws5", "ws6", "ws7", "ws8", "ws9",
        "wsd", "wsm", "ws-bak", "ws-$$$",
    ]

    /// What the progress sheet shows: "found N, requested M, done".
    struct Snapshot: Equatable, Sendable {
        let found: Int
        let requested: Int
        let done: Bool
    }

    private static let logger = Logger(subsystem: SpotlightFileIndexer.subsystem, category: "index-all-backfill")

    /// Enumerate every Tier-1-extension file the metadata store can see, then request a
    /// per-file reindex for each in batches of `batchSize` with a pause between batches — the
    /// spec's "20 at a time, small pause" so a few hundred candidates don't spawn a few hundred
    /// `mdimport` processes all at once.
    ///
    /// `isCancelled` is polled BETWEEN batches, not between individual files within one: a
    /// batch of 20 spawns is short, so per-file polling would only save a couple of seconds at
    /// the cost of more surface for a race, for no real benefit.
    @discardableResult
    static func run(
        finder: MetadataQuerying,
        extensions: [String] = tier1Extensions,
        runner: MDImportRunning = ProcessMDImportRunner(),
        dedupe: SpotlightFileIndexer.DedupeWindow = SpotlightFileIndexer.DedupeWindow(),
        batchSize: Int = 20,
        pauseNanoseconds: UInt64 = 200_000_000,
        // `Task.sleep` only throws on cancellation, and a cancelled pause between batches
        // should let the (already separately polled) `isCancelled` check stop the run, not
        // propagate a cancellation error through an unrelated pacing delay.
        sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        // `async` (rather than plain `() -> Bool` / `(Snapshot) -> Void`) even though most
        // implementations — including the fakes in tests — never actually suspend: it lets a
        // `@MainActor`-isolated closure (the progress sheet's model, which is where a real
        // caller's `isCancelled`/`progress` live) convert to this parameter with an implicit
        // actor hop, instead of forcing every caller's state to be `Sendable`.
        isCancelled: @escaping () async -> Bool = { false },
        progress: @escaping (Snapshot) async -> Void = { _ in }
    ) async -> Snapshot {
        let candidates = await finder.candidates(extensions: extensions)
        logger.info("found \(candidates.count, privacy: .public) candidate(s)")
        await progress(Snapshot(found: candidates.count, requested: 0, done: false))

        var requested = 0
        for batch in candidates.sr_chunked(into: batchSize) {
            if await isCancelled() {
                logger.info("cancelled after \(requested, privacy: .public) request(s) of \(candidates.count, privacy: .public)")
                break
            }
            for url in batch {
                // `perform: { $0() }` — synchronous, on this already-background Task, so the
                // batch loop's own pause is what rate-limits, not a second, uncoordinated
                // dispatch queue racing it.
                SpotlightFileIndexer.requestIndex(for: url, category: "index-all-backfill",
                                                  runner: runner, dedupe: dedupe, perform: { $0() })
                requested += 1
            }
            await progress(Snapshot(found: candidates.count, requested: requested, done: false))
            if requested < candidates.count {
                await sleep(pauseNanoseconds)
            }
        }
        let final = Snapshot(found: candidates.count, requested: requested, done: true)
        logger.info("done: requested \(final.requested, privacy: .public) of \(final.found, privacy: .public)")
        await progress(final)
        return final
    }
}

/// Injection seam for candidate discovery — `NSMetadataQuery` in production
/// (`NSMetadataQueryCandidateFinder` below), a canned array in tests.
protocol MetadataQuerying: Sendable {
    /// Every file whose name ends in one of `extensions` (case-insensitive), deduped by path.
    /// Order is not part of the contract — callers that care (tests) sort before comparing.
    func candidates(extensions: [String]) async -> [URL]
}

/// The real search: `NSMetadataQuery` predicated on `kMDItemFSName`, which — per the spotlight
/// indexing packet — is populated for every file regardless of whether its CONTENT has been
/// indexed, so this finds files Spotlight has never looked inside yet.
///
/// `operationQueue` is set explicitly and results are read back once
/// `.NSMetadataQueryDidFinishGathering` fires on it — per the packet's own citation, "do not
/// assume main-runloop delivery" — so this needs no runloop-pumping thread of its own to be
/// awaitable, unlike a bare `query.start()` called from a plain background thread with nothing
/// pumping its runloop.
final class NSMetadataQueryCandidateFinder: MetadataQuerying, @unchecked Sendable {
    /// Built by PARSING a joined `" OR "` format string, NOT by composing one via
    /// `NSCompoundPredicate(orPredicateWithSubpredicates:)` — empirically (job 152, real
    /// sandboxed launch), handing `-[NSMetadataQuery setPredicate:]` the latter crashes inside
    /// its private `generateMetadataDescription` translator with `EXC_CRASH`/`SIGABRT`, even
    /// for a trivially single-subpredicate OR. Both forms report as `NSCompoundPredicate` at
    /// runtime (`is NSCompoundPredicate` cannot tell them apart — checked directly, do not
    /// reintroduce that as a regression test), so the CONSTRUCTION PATH is what matters here,
    /// not the resulting type: a joined format string is what Apple's own samples use, and
    /// what actually survives NSMetadataQuery's translator. Pulled out of
    /// `candidates(extensions:)` so a unit test can cover the matching behavior without ever
    /// touching a real `NSMetadataQuery`.
    static func predicate(forExtensions extensions: [String]) -> NSPredicate {
        let format = Array(repeating: "kMDItemFSName ENDSWITH[c] %@", count: extensions.count)
            .joined(separator: " OR ")
        return NSPredicate(format: format, argumentArray: extensions.map { ".\($0)" })
    }

    func candidates(extensions: [String]) async -> [URL] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            DispatchQueue.main.async {
                let query = NSMetadataQuery()
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
                query.predicate = Self.predicate(forExtensions: extensions)
                query.operationQueue = OperationQueue()

                var observer: NSObjectProtocol?
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query,
                    queue: query.operationQueue
                ) { _ in
                    query.disableUpdates()
                    query.stop()
                    let urls: [URL] = (0..<query.resultCount).compactMap { index in
                        guard let item = query.result(at: index) as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                        else { return nil }
                        return URL(fileURLWithPath: path)
                    }
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    continuation.resume(returning: urls)
                }
                query.start()
            }
        }
    }
}

extension Array {
    /// `stride`-based chunking, kept private to this file — the engine's own batching is the
    /// only caller, and it is deliberately not a general-purpose utility.
    fileprivate func sr_chunked(into size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
