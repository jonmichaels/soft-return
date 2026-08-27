import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightTriggerBreadcrumbs` — job-173's field evidence trail for the index-on-open/
/// index-on-view triggers whose CODE job-172 already proved sound but which produce no
/// indexed files on Jon's machine. Every test uses a throwaway `UserDefaults` suite so runs
/// never collide and never leak into the real domain.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SpotlightTriggerBreadcrumbsTests.\(UUID().uuidString)")!
}

private final class FakeMDImportRunner: MDImportRunning {
    private(set) var calls: [[String]] = []
    var result = SpotlightNudge.RunResult(exitCode: 0, output: "")

    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        calls.append(arguments)
        return result
    }
}

// MARK: - SpotlightTriggerBreadcrumbs.record directly

@Test func recordAppendsAnEntryReadableBack() {
    let defaults = throwawayDefaults()

    SpotlightTriggerBreadcrumbs.record(category: "index-on-open", path: "/tmp/a.wsd",
                                       stage: "called", detail: "urlWasNil=false", defaults: defaults)

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.count == 1)
    #expect(entries[0].category == "index-on-open")
    #expect(entries[0].path == "/tmp/a.wsd")
    #expect(entries[0].stage == "called")
    #expect(entries[0].detail == "urlWasNil=false")
}

@Test func ringBufferDropsTheOldestEntryPastCapacity() {
    let defaults = throwawayDefaults()

    for i in 0..<41 {
        SpotlightTriggerBreadcrumbs.record(category: "index-on-open", path: "/tmp/\(i).wsd",
                                           stage: "called", detail: "", defaults: defaults)
    }

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.count == 40)
    #expect(entries.first?.path == "/tmp/1.wsd")
    #expect(entries.last?.path == "/tmp/40.wsd")
}

@Test func detailLongerThan500CharactersIsCapped() {
    let defaults = throwawayDefaults()

    SpotlightTriggerBreadcrumbs.record(category: "index-on-open", path: "/tmp/a.wsd",
                                       stage: "spawn", detail: String(repeating: "x", count: 1000),
                                       defaults: defaults)

    #expect(SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)[0].detail.count == 500)
}

// MARK: - Wired into SpotlightFileIndexer.requestIndex

@Test func requestIndexWritesCalledThenSpawnWithTheFakeRunnersResult() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    runner.result = SpotlightNudge.RunResult(exitCode: 0, output: "imported")
    let url = URL(fileURLWithPath: "/tmp/opened.wsd")

    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: SpotlightFileIndexer.DedupeWindow(), defaults: defaults,
                                      perform: { $0() })

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.map(\.stage) == ["called", "spawn"])
    #expect(entries[0].detail == "urlWasNil=false")
    #expect(entries[1].detail == "rc=0 imported")
}

@Test func dedupeSkipWritesCalledAndDedupeSkipButNoSpawn() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    let dedupe = SpotlightFileIndexer.DedupeWindow()
    let url = URL(fileURLWithPath: "/tmp/reopened.wsd")

    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: dedupe, defaults: defaults, perform: { $0() })
    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: dedupe, defaults: defaults, perform: { $0() })

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.map(\.stage) == ["called", "spawn", "called", "dedupe-skip"])
}

@Test func nilURLStillWritesACalledBreadcrumb() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()

    SpotlightFileIndexer.requestIndex(for: nil, category: "index-on-open", runner: runner,
                                      dedupe: SpotlightFileIndexer.DedupeWindow(), defaults: defaults,
                                      perform: { $0() })

    let entries = SpotlightTriggerBreadcrumbs.readEntries(defaults: defaults)
    #expect(entries.map(\.stage) == ["called"])
    #expect(entries[0].path == "")
    #expect(entries[0].detail == "urlWasNil=true")
    #expect(runner.calls.isEmpty)
}
