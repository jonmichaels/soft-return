import Foundation

/// A value that `@Sendable` closures can update, for tests that collect what a
/// `CLIEnvironment` (whose closures are `@Sendable`) was asked to write. Every access goes
/// through `lock`, so sharing it across threads is sound.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
