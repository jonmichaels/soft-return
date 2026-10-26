import Foundation

/// A unique directory under the temporary directory that removes itself.
///
/// Swift Testing: `try TestScratch.with { dir in ... }`, or keep one in a suite's stored
/// property and let `deinit` remove it. XCTest: `let scratch = try TestScratch();
/// addTeardownBlock { scratch.remove() }`. `remove()` may be called more than once.
///
/// A local `let` is not kept alive to the end of its scope (Swift may release it after its
/// last use, which runs `deinit`): when a test holds one in a local and keeps using `url`,
/// add `defer { scratch.remove() }` right after creating it.
public final class TestScratch: @unchecked Sendable {
    public let url: URL

    /// Creates the directory. `prefix` makes a leftover recognisable by the test that made it.
    public init(prefix: String = "scratch") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { remove() }

    /// A path inside the directory.
    public func url(for name: String) -> URL { url.appendingPathComponent(name) }

    /// Removes the directory and everything in it. A subdirectory a test made read-only is
    /// made writable first, so a permission test cannot strand its own scratch.
    public func remove() {
        Self.removeDirectory(at: url)
    }

    private static func removeDirectory(at url: URL) {
        let fileManager = FileManager.default
        if let walker = fileManager.enumerator(atPath: url.path) {
            for case let relative as String in walker {
                let path = url.appendingPathComponent(relative).path
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                }
            }
        }
        try? fileManager.removeItem(at: url)
    }

    // MARK: Process-wide scratch

    /// A scratch directory for something built once per process and shared by every test (a
    /// materialized corpus, say): nothing owns it, so no `deinit` ever runs. It is removed when
    /// the process exits normally. A process that is killed leaves it behind; the next call with
    /// the same `prefix` removes such leftovers once they are `staleAfter` seconds old (a day by
    /// default, so a run in another process at the same time is never touched).
    public static func processWide(prefix: String, staleAfter: TimeInterval = 24 * 60 * 60) throws -> TestScratch {
        removeStale(prefix: prefix, olderThan: staleAfter)
        let scratch = try TestScratch(prefix: prefix)
        ProcessScratches.shared.keep(scratch)
        return scratch
    }

    /// Removes directories named `<prefix>-<id>` in the temporary directory that were last
    /// modified more than `age` seconds ago: what a killed test run left behind.
    public static func removeStale(prefix: String, olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix(prefix + "-") {
            let url = temporary.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff { removeDirectory(at: url) }
        }
    }

    /// Runs `body` with a fresh directory and removes it afterwards, also when `body` throws.
    public static func with<Result>(
        prefix: String = "scratch", _ body: (URL) throws -> Result
    ) throws -> Result {
        let scratch = try TestScratch(prefix: prefix)
        defer { scratch.remove() }
        return try body(scratch.url)
    }

    public static func with<Result>(
        prefix: String = "scratch", _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let scratch = try TestScratch(prefix: prefix)
        defer { scratch.remove() }
        return try await body(scratch.url)
    }
}

/// The scratch directories `TestScratch.processWide` made, removed once at normal exit.
private final class ProcessScratches: @unchecked Sendable {
    static let shared = ProcessScratches()

    private let lock = NSLock()
    private var scratches: [TestScratch] = []
    private var registered = false

    func keep(_ scratch: TestScratch) {
        lock.lock()
        defer { lock.unlock() }
        scratches.append(scratch)
        if !registered {
            registered = true
            atexit { ProcessScratches.shared.removeAll() }
        }
    }

    private func removeAll() {
        lock.lock()
        let all = scratches
        scratches = []
        lock.unlock()
        for scratch in all { scratch.remove() }
    }
}
