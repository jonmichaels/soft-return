import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightIndexQueue` — job 178's app-group hand-off queue: the QuickLook/Thumbnail
/// extensions enqueue instead of spawning `mdimport` directly (their sandbox has no
/// `/usr/bin/mdimport` — see the type's own doc comment), and the app drains through the
/// existing `SpotlightFileIndexer`.
///
/// Every test uses a throwaway temp directory standing in for the app-group container, injected
/// via `containerURL:` — the REAL app-group container needs the `com.apple.security.
/// application-groups` entitlement provisioned, which this headless test host cannot be assumed
/// to have (see the job report for what ran here vs. what needs console verification). This is
/// the same reasoning `QuickLookExtensionTests` already established for this repo: Tuist's graph
/// linter refuses `SoftReturnTests` importing an app-extension target at all, so the extension
/// call sites (`ThumbnailProvider`/`PreviewProvider`) are exercised here at the ONE call they
/// both actually make — `SpotlightIndexQueue.enqueue(path:category:)` — not through the
/// extension modules themselves.
private func throwawayContainer() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotlightIndexQueueTests.\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SpotlightIndexQueueTests.\(UUID().uuidString)")!
}

private final class FakeMDImportRunner: MDImportRunning {
    private(set) var calls: [[String]] = []
    var result = SpotlightNudge.RunResult(exitCode: 0, output: "")

    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        calls.append(arguments)
        return result
    }
}

// MARK: - enqueue: append / dedupe / cap

@Test func enqueueAppendsAnEntryReadableBackViaPeekAll() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()

    SpotlightIndexQueue.enqueue(path: "/tmp/a.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    let entries = SpotlightIndexQueue.peekAll(containerURL: container)
    #expect(entries.count == 1)
    #expect(entries[0].path == "/tmp/a.wsd")
    #expect(entries[0].category == "index-on-view")
}

@Test func enqueueDedupesTheSamePathInsteadOfDuplicatingIt() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()

    SpotlightIndexQueue.enqueue(path: "/tmp/reopened.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })
    SpotlightIndexQueue.enqueue(path: "/tmp/reopened.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    #expect(SpotlightIndexQueue.peekAll(containerURL: container).count == 1)
}

@Test func enqueueOfDifferentPathsNeverDedupesAgainstEachOther() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()

    SpotlightIndexQueue.enqueue(path: "/tmp/a.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })
    SpotlightIndexQueue.enqueue(path: "/tmp/b.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    #expect(SpotlightIndexQueue.peekAll(containerURL: container).count == 2)
}

@Test func enqueuePastCapacityDropsTheOldestEntriesFirst() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()

    for i in 0..<(SpotlightIndexQueue.capacity + 1) {
        SpotlightIndexQueue.enqueue(path: "/tmp/\(i).wsd", category: "index-on-view",
                                    containerURL: container, defaults: defaults, perform: { $0() })
    }

    let entries = SpotlightIndexQueue.peekAll(containerURL: container)
    #expect(entries.count == SpotlightIndexQueue.capacity)
    #expect(entries.first?.path == "/tmp/1.wsd", "entry 0 should have been evicted as the oldest")
    #expect(entries.last?.path == "/tmp/\(SpotlightIndexQueue.capacity).wsd")
}

@Test func enqueueWithNoContainerRecordsAQueueFailedBreadcrumbAndNeverThrows() {
    let defaults = throwawayDefaults()

    SpotlightIndexQueue.enqueue(path: "/tmp/a.wsd", category: "index-on-view",
                                containerURL: nil, defaults: defaults, perform: { $0() })

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.map(\.stage) == ["enqueue-called", "queue-failed"])
}

@Test func enqueueWithNilOrEmptyPathIsANoOp() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()

    SpotlightIndexQueue.enqueue(path: nil, category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })
    SpotlightIndexQueue.enqueue(path: "", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    #expect(SpotlightIndexQueue.peekAll(containerURL: container).isEmpty)
    #expect(SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults).map(\.stage) ==
            ["enqueue-called", "enqueue-called"])
}

// MARK: - enqueue: concurrent-append

/// The whole reason this uses `NSFileCoordinator` instead of an in-process lock: multiple OS
/// processes write this file. The closest an in-process test can get to proving that
/// coordination actually holds is real concurrent writers on real background queues (the
/// DEFAULT `perform`, not the synchronous `{ $0() }` every other test injects) racing for the
/// same file — if coordination were absent or broken, this drops entries under contention.
@Test func concurrentEnqueuesFromDistinctPathsAllSurvive() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()
    let count = 25
    let group = DispatchGroup()

    for i in 0..<count {
        group.enter()
        SpotlightIndexQueue.enqueue(path: "/tmp/concurrent-\(i).wsd", category: "index-on-view",
                                    containerURL: container, defaults: defaults,
                                    perform: { work in
                                        DispatchQueue.global().async {
                                            work()
                                            group.leave()
                                        }
                                    })
    }

    #expect(group.wait(timeout: .now() + 10) == .success, "concurrent enqueues did not all complete in time")
    let entries = SpotlightIndexQueue.peekAll(containerURL: container)
    #expect(entries.count == count, "expected all \(count) concurrent enqueues to survive, got \(entries.count)")
}

// MARK: - drain

@Test func drainAllFeedsEveryQueuedEntryThroughTheRunnerUnderTheDrainedCategory() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    SpotlightIndexQueue.enqueue(path: "/tmp/one.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })
    SpotlightIndexQueue.enqueue(path: "/tmp/two.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    SpotlightIndexQueue.drainAll(containerURL: container, runner: runner,
                                 dedupe: SpotlightFileIndexer.DedupeWindow(), defaults: defaults,
                                 perform: { $0() })

    #expect(Set(runner.calls.flatMap { $0 }) == ["/tmp/one.wsd", "/tmp/two.wsd"])
    let breadcrumbs = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(breadcrumbs.contains { $0.category == "index-on-view-drained" && $0.stage == "spawn" })
}

@Test func drainAllClearsTheQueueAfterDraining() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    SpotlightIndexQueue.enqueue(path: "/tmp/one.wsd", category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    SpotlightIndexQueue.drainAll(containerURL: container, runner: runner,
                                 dedupe: SpotlightFileIndexer.DedupeWindow(), defaults: defaults,
                                 perform: { $0() })

    #expect(SpotlightIndexQueue.peekAll(containerURL: container).isEmpty)
}

@Test func drainAllOnAnEmptyQueueCallsTheRunnerZeroTimes() {
    let container = throwawayContainer()
    let runner = FakeMDImportRunner()

    SpotlightIndexQueue.drainAll(containerURL: container, runner: runner,
                                 dedupe: SpotlightFileIndexer.DedupeWindow(), perform: { $0() })

    #expect(runner.calls.isEmpty)
}

@Test func drainAllWithNoContainerIsANoOp() {
    let runner = FakeMDImportRunner()

    SpotlightIndexQueue.drainAll(containerURL: nil, runner: runner,
                                 dedupe: SpotlightFileIndexer.DedupeWindow(), perform: { $0() })

    #expect(runner.calls.isEmpty)
}

// MARK: - extension call sites (see this file's own doc comment on why this, not an import)

/// `ThumbnailProvider.provideThumbnail(for:_:)` and `PreviewProvider.providePreview(for:)` both
/// now read, verbatim: `SpotlightIndexQueue.enqueue(path: request.fileURL.path, category:
/// "index-on-view")`. This is that exact call, proving the shared code path both extensions
/// delegate to actually queues under the category they actually pass.
@Test func theCallBothViewExtensionsMakeEnqueuesUnderIndexOnView() {
    let container = throwawayContainer()
    let defaults = throwawayDefaults()
    let requestFileURL = URL(fileURLWithPath: "/tmp/viewed-in-finder.wsd")

    SpotlightIndexQueue.enqueue(path: requestFileURL.path, category: "index-on-view",
                                containerURL: container, defaults: defaults, perform: { $0() })

    let entries = SpotlightIndexQueue.peekAll(containerURL: container)
    #expect(entries.map(\.path) == [requestFileURL.path])
    #expect(entries.map(\.category) == ["index-on-view"])
}
