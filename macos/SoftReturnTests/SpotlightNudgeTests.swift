import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightNudge`'s once-per-(version, importer path) gate — job-138. Every test here
/// injects `FakeMDImportRunner` and never spawns a real `mdimport`: the point of the gate is
/// to keep a sandboxed launch that gets denied every time from retrying forever, and a test
/// that actually shelled out would be exercising the sandbox, not the gate.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SpotlightNudgeTests.\(UUID().uuidString)")!
}

private final class FakeMDImportRunner: MDImportRunning {
    private(set) var calls: [[String]] = []
    var result = SpotlightNudge.RunResult(exitCode: 0, output: "")

    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        calls.append(arguments)
        return result
    }
}

// MARK: - Pure gating decision

@Test func firstRunHasNoPriorStateAndShouldRun() {
    #expect(SpotlightNudge.shouldRun(state: nil, version: "7", importerPath: "/a"))
}

@Test func sameVersionAndPathDoesNotRunAgain() {
    let state = SpotlightNudge.State(version: "7", importerPath: "/a", ranAt: Date(),
                                     exitCode: 0, output: "")
    #expect(!SpotlightNudge.shouldRun(state: state, version: "7", importerPath: "/a"))
}

@Test func aFailedPriorRunAtTheSameVersionAndPathStillDoesNotRunAgain() {
    // Deliberate: a sandboxed denial that retried on every launch would just be noise. The
    // escape hatch for "try again now" is the unconditional Help-menu item, not automatic
    // retries.
    let state = SpotlightNudge.State(version: "7", importerPath: "/a", ranAt: Date(),
                                     exitCode: 1, output: "denied")
    #expect(!SpotlightNudge.shouldRun(state: state, version: "7", importerPath: "/a"))
}

@Test func aVersionBumpRunsAgain() {
    let state = SpotlightNudge.State(version: "7", importerPath: "/a", ranAt: Date(),
                                     exitCode: 0, output: "")
    #expect(SpotlightNudge.shouldRun(state: state, version: "8", importerPath: "/a"))
}

@Test func aRelocatedImporterPathRunsAgainEvenAtTheSameVersion() {
    let state = SpotlightNudge.State(version: "7", importerPath: "/a", ranAt: Date(),
                                     exitCode: 0, output: "")
    #expect(SpotlightNudge.shouldRun(state: state, version: "7", importerPath: "/b"))
}

// MARK: - runIfNeeded gating end to end (fake runner, synchronous queue)

@Test func runIfNeededSpawnsOnFirstLaunchForThisVersion() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    let bundle = Bundle(for: TestAnchor.self)

    SpotlightNudge.runIfNeeded(bundle: bundle, defaults: defaults, runner: runner, perform: { $0() })

    #expect(runner.calls.count == 1)
    #expect(runner.calls.first == ["-r", SpotlightNudge.importerPath(bundle: bundle)])
}

@Test func runIfNeededDoesNotSpawnASecondTimeForTheSameVersion() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    let bundle = Bundle(for: TestAnchor.self)

    SpotlightNudge.runIfNeeded(bundle: bundle, defaults: defaults, runner: runner, perform: { $0() })
    SpotlightNudge.runIfNeeded(bundle: bundle, defaults: defaults, runner: runner, perform: { $0() })

    #expect(runner.calls.count == 1)
}

@Test func runIfNeededRecordsTheOutcomeInUserDefaults() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    runner.result = SpotlightNudge.RunResult(exitCode: 0, output: "imported 1 item")
    let bundle = Bundle(for: TestAnchor.self)

    SpotlightNudge.runIfNeeded(bundle: bundle, defaults: defaults, runner: runner, perform: { $0() })

    let state = SpotlightNudge.readState(defaults: defaults)
    #expect(state?.version == SpotlightNudge.currentVersion(bundle: bundle))
    #expect(state?.importerPath == SpotlightNudge.importerPath(bundle: bundle))
    #expect(state?.exitCode == 0)
    #expect(state?.output == "imported 1 item")
}

@Test func runIfNeededRecordsAFailureRatherThanLeavingNoRecord() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    runner.result = SpotlightNudge.RunResult(exitCode: 1, output: "sandbox denied")

    SpotlightNudge.runIfNeeded(bundle: Bundle(for: TestAnchor.self), defaults: defaults,
                               runner: runner, perform: { $0() })

    let state = SpotlightNudge.readState(defaults: defaults)
    #expect(state?.exitCode == 1)
    #expect(state?.output == "sandbox denied")
}

// MARK: - runUnconditionally (the Help-menu action)

@Test func runUnconditionallyIgnoresTheGateAndAlwaysSpawns() {
    let defaults = throwawayDefaults()
    let runner = FakeMDImportRunner()
    let bundle = Bundle(for: TestAnchor.self)

    _ = SpotlightNudge.runUnconditionally(bundle: bundle, defaults: defaults, runner: runner)
    _ = SpotlightNudge.runUnconditionally(bundle: bundle, defaults: defaults, runner: runner)

    #expect(runner.calls.count == 2)
}

@Test func runUnconditionallyReturnsTheRunnersResultDirectly() {
    let runner = FakeMDImportRunner()
    runner.result = SpotlightNudge.RunResult(exitCode: 3, output: "boom")

    let result = SpotlightNudge.runUnconditionally(
        bundle: Bundle(for: TestAnchor.self), defaults: throwawayDefaults(), runner: runner)

    #expect(result == runner.result)
}

/// A class living in the `SoftReturnTests` bundle, purely so `Bundle(for:)` can hand
/// `SpotlightNudge` a real `Bundle` whose `bundleURL` and Info.plist are stable and
/// filesystem-backed — the same shape it gets from `Bundle.main` in the app, without needing
/// the app's own bundle identity or `CFBundleVersion`.
private final class TestAnchor {}
