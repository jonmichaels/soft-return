import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightFileIndexer` — job-145 Part A/B's per-file `mdimport <path>` request, fired when
/// a document is opened (Part A) or viewed via thumbnail/QuickLook (Part B). Every test injects
/// `FakeMDImportRunner` and a synchronous `perform` so nothing here spawns a real `mdimport` or
/// depends on timing.
private final class FakeMDImportRunner: MDImportRunning {
    private(set) var calls: [[String]] = []
    var result = SpotlightNudge.RunResult(exitCode: 0, output: "")

    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        calls.append(arguments)
        return result
    }
}

@Test func requestIndexSpawnsMdimportWithTheFilePathOnOpen() {
    let runner = FakeMDImportRunner()
    let url = URL(fileURLWithPath: "/tmp/some-document.wsd")

    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: SpotlightFileIndexer.DedupeWindow(), perform: { $0() })

    #expect(runner.calls == [[url.path]])
}

@Test func requestIndexNeverCalledForNilFileURL() {
    let runner = FakeMDImportRunner()

    SpotlightFileIndexer.requestIndex(for: nil, category: "index-on-open", runner: runner,
                                      dedupe: SpotlightFileIndexer.DedupeWindow(), perform: { $0() })

    #expect(runner.calls.isEmpty)
}

@Test func rapidReOpenOfTheSameFileIsDedupedWithinTheWindow() {
    let runner = FakeMDImportRunner()
    let url = URL(fileURLWithPath: "/tmp/reopened.wsd")
    let dedupe = SpotlightFileIndexer.DedupeWindow()

    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: dedupe, perform: { $0() })
    SpotlightFileIndexer.requestIndex(for: url, category: "index-on-open", runner: runner,
                                      dedupe: dedupe, perform: { $0() })

    #expect(runner.calls.count == 1)
}

@Test func differentFilesAreNeverDedupedAgainstEachOther() {
    let runner = FakeMDImportRunner()
    let dedupe = SpotlightFileIndexer.DedupeWindow()

    SpotlightFileIndexer.requestIndex(for: URL(fileURLWithPath: "/tmp/a.wsd"), category: "index-on-open",
                                      runner: runner, dedupe: dedupe, perform: { $0() })
    SpotlightFileIndexer.requestIndex(for: URL(fileURLWithPath: "/tmp/b.wsd"), category: "index-on-open",
                                      runner: runner, dedupe: dedupe, perform: { $0() })

    #expect(runner.calls.count == 2)
}

@Test func reopenAfterTheWindowElapsesRequestsAgain() {
    let dedupe = SpotlightFileIndexer.DedupeWindow(window: 60)
    let path = "/tmp/stale-reopen.wsd"
    let first = Date(timeIntervalSince1970: 1_000_000)

    #expect(dedupe.shouldRequest(path, now: first))
    #expect(!dedupe.shouldRequest(path, now: first.addingTimeInterval(30)))
    #expect(dedupe.shouldRequest(path, now: first.addingTimeInterval(61)))
}
