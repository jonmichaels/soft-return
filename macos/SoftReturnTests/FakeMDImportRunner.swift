import Foundation
@testable import SoftReturn

/// The `mdimport` spawn the Spotlight tests stand in for: it records each call's arguments and hands back `result`.
/// The code under test runs it on a background queue, so every access goes through `lock`.
final class FakeMDImportRunner: MDImportRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var storedResult = SpotlightNudge.RunResult(exitCode: 0, output: "")

    var calls: [[String]] { lock.withLock { recordedCalls } }

    var result: SpotlightNudge.RunResult {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    func run(arguments: [String]) -> SpotlightNudge.RunResult {
        lock.withLock {
            recordedCalls.append(arguments)
            return storedResult
        }
    }
}
