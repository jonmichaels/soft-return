import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightBackfill` — job-152 Part C's Help ▸ "Index All WordStar Documents…" engine. Every
/// test injects a fake `MetadataQuerying` (canned candidate list, no real `NSMetadataQuery`), a
/// fake `MDImportRunning` (no real `mdimport` spawn), a synchronous `sleep` (no real pause), so
/// the whole engine runs instantly and deterministically.
private struct FakeFinder: MetadataQuerying, Sendable {
    let urls: [URL]
    func candidates(extensions: [String]) async -> [URL] { urls }
}

private final class FakeMDImportRunner: MDImportRunning {
    private(set) var calls: [[String]] = []
    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        calls.append(arguments)
        return SpotlightNudge.RunResult(exitCode: 0, output: "")
    }
}

/// Records every `Snapshot` `progress` was called with, in order — the shape a caller (the
/// menu's progress sheet) actually observes.
private final class ProgressRecorder {
    private(set) var snapshots: [SpotlightBackfill.Snapshot] = []
    func record(_ snapshot: SpotlightBackfill.Snapshot) { snapshots.append(snapshot) }
}

// MARK: - Batching

@Test func batchesOfTheConfiguredSizeEachRequestBeforePausing() async {
    let urls = (0..<45).map { URL(fileURLWithPath: "/tmp/doc\($0).wsd") }
    let runner = FakeMDImportRunner()
    let recorder = ProgressRecorder()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), batchSize: 20,
        sleep: { _ in }, progress: recorder.record)

    #expect(runner.calls.count == 45)
    #expect(final == SpotlightBackfill.Snapshot(found: 45, requested: 45, done: true))
    // One "found" snapshot, then one per batch (20, 40, 45), then the final — batch boundaries
    // are visible in the progress stream, not just the end state.
    #expect(recorder.snapshots.map(\.requested) == [0, 20, 40, 45, 45])
}

@Test func aSingleShortBatchRequestsEverythingAtOnce() async {
    let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/short\($0).ws4") }
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), batchSize: 20, sleep: { _ in })

    #expect(runner.calls.count == 5)
    #expect(final.found == 5 && final.requested == 5 && final.done)
}

@Test func noCandidatesRequestsNothingAndStillReportsDone() async {
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: []), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), sleep: { _ in })

    #expect(runner.calls.isEmpty)
    #expect(final == SpotlightBackfill.Snapshot(found: 0, requested: 0, done: true))
}

// MARK: - Cancellation

@Test func cancellingAfterTheFirstBatchStopsBeforeTheSecond() async {
    let urls = (0..<45).map { URL(fileURLWithPath: "/tmp/cancel\($0).wsd") }
    let runner = FakeMDImportRunner()
    var batchesCompleted = 0

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), batchSize: 20, sleep: { _ in },
        isCancelled: {
            // Cancel is checked BEFORE each batch, so returning true only once one full batch
            // has already gone out reproduces "the user clicked Cancel mid-run".
            batchesCompleted >= 1
        },
        progress: { snapshot in
            if snapshot.requested > 0, !snapshot.done { batchesCompleted += 1 }
        })

    #expect(runner.calls.count == 20)
    #expect(final == SpotlightBackfill.Snapshot(found: 45, requested: 20, done: true))
}

@Test func cancellingBeforeTheFirstBatchRequestsNothing() async {
    let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/precancel\($0).wsd") }
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), sleep: { _ in }, isCancelled: { true })

    #expect(runner.calls.isEmpty)
    #expect(final == SpotlightBackfill.Snapshot(found: 10, requested: 0, done: true))
}

// MARK: - Dedupe

@Test func duplicateURLsFromTheQueryAreRequestedOnlyOnce() async {
    let duplicate = URL(fileURLWithPath: "/tmp/twice.wsd")
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: [duplicate, duplicate]), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), sleep: { _ in })

    // `found` still reports what the query actually returned — dedupe suppresses the redundant
    // *request*, it does not lie about what was discovered.
    #expect(final.found == 2)
    #expect(runner.calls == [[duplicate.path]])
}

@Test func duplicatesAcrossDifferentBatchesAreStillDedupedByTheSharedWindow() async {
    var urls = [URL(fileURLWithPath: "/tmp/repeat.wsd")]
    urls += (0..<19).map { URL(fileURLWithPath: "/tmp/filler\($0).wsd") } // fills batch 1 to 20
    urls.append(URL(fileURLWithPath: "/tmp/repeat.wsd"))                  // first of batch 2
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), batchSize: 20, sleep: { _ in })

    #expect(final.found == 21)
    let repeatCalls = runner.calls.filter { $0 == [URL(fileURLWithPath: "/tmp/repeat.wsd").path] }
    #expect(repeatCalls.count == 1)
}

@Test func distinctURLsAreNeverDedupedAgainstEachOther() async {
    let urls = [URL(fileURLWithPath: "/tmp/a.wsd"), URL(fileURLWithPath: "/tmp/b.wsd")]
    let runner = FakeMDImportRunner()

    let final = await SpotlightBackfill.run(
        finder: FakeFinder(urls: urls), runner: runner,
        dedupe: SpotlightFileIndexer.DedupeWindow(), sleep: { _ in })

    #expect(final.requested == 2)
    #expect(Set(runner.calls.map(\.first)) == Set(urls.map { $0.path }))
}

// MARK: - Tier-1 extension list

@Test func tier1ExtensionsMatchesTheInfoPlistRulingExactly() {
    // Info.plist's UTExportedTypeDeclarations ▸ public.filename-extension is the ruled source
    // of truth (Jon, 2026-08-08); this is the copy the query predicate actually uses. If they
    // ever drift, this test — not a human re-reading the plist — is what catches it.
    #expect(SpotlightBackfill.tier1Extensions == [
        "ws", "ws0", "ws1", "ws2", "ws3", "ws4", "ws5", "ws6", "ws7", "ws8", "ws9",
        "wsd", "wsm", "ws-bak", "ws-$$$",
    ])
}

// MARK: - NSMetadataQuery predicate shape (job 152's real-launch crash)

@Test func queryPredicateMatchesEveryTier1ExtensionAgainstAFilename() {
    // `NSPredicate.evaluate(with:)` doesn't consult Spotlight — it just runs the predicate
    // tree against a plain object — so this exercises the actual format string/argument
    // pairing (a `%@` per extension) without a real `NSMetadataQuery` in sight.
    let predicate = NSMetadataQueryCandidateFinder.predicate(forExtensions: SpotlightBackfill.tier1Extensions)
    for ext in SpotlightBackfill.tier1Extensions {
        let name = "manuscript.\(ext)"
        #expect(predicate.evaluate(with: ["kMDItemFSName": name]), "expected a match for \(name)")
    }
    #expect(!predicate.evaluate(with: ["kMDItemFSName": "manuscript.pdf"]))
}
