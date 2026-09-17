import Foundation
import Testing
@testable import SoftReturnShared

/// Batch 46 (Jon's option 2): a document's own quirk choices kept by the app, keyed to the file — following a rename or
/// a move on its volume, not carried by a copy, and never written into the document.
@Suite @MainActor struct QuirkOverrideStoreTests {
    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuirkOverrideStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func store() -> (QuirkOverrideStore, UserDefaults, String) {
        let suite = "QuirkOverrideStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (QuirkOverrideStore(defaults: defaults), defaults, suite)
    }

    @Test func choicesFollowTheFileThroughARenameAndAMoveButNotACopy() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, defaults, suite) = Self.store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = folder.appendingPathComponent("LJ6DTP.WS")
        let bytes = Data("WordStar bytes".utf8)
        try bytes.write(to: original)
        let key = try #require(QuirkOverrideStore.key(for: original))
        // An untracked file has no document identifier; its number on the volume keys it.
        #expect(key.hasPrefix("document:") || key.hasPrefix("file:"), "keyed by path: \(key)")

        store.setOverrides(["stray-style-strikeout": true], for: original)
        #expect(store.overrides(for: original) == ["stray-style-strikeout": true])
        // Never in the document.
        #expect(try Data(contentsOf: original) == bytes)

        let renamed = folder.appendingPathComponent("RENAMED.WS")
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(store.overrides(for: renamed) == ["stray-style-strikeout": true])
        let sub = folder.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("RENAMED.WS")
        try FileManager.default.moveItem(at: renamed, to: moved)
        #expect(store.overrides(for: moved) == ["stray-style-strikeout": true])

        let copy = folder.appendingPathComponent("COPY.WS")
        try FileManager.default.copyItem(at: moved, to: copy)
        #expect(store.overrides(for: copy).isEmpty)

        // A fresh store on the same defaults reads it back; no choices removes the entry.
        #expect(QuirkOverrideStore(defaults: defaults).overrides(for: moved) == ["stray-style-strikeout": true])
        store.setOverrides([:], for: moved)
        #expect(store.overrides(for: moved).isEmpty)
        #expect((defaults.dictionary(forKey: QuirkOverrideStore.storageKey) ?? [:]).isEmpty)
    }

    @Test func noFileNoChoices() {
        let (store, defaults, suite) = Self.store()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setOverrides(["driver-euro-sign": false], for: nil)
        store.setOverrides(["driver-euro-sign": false], for: URL(string: "https://example.com/A.WS")!)
        #expect(store.overrides(for: nil).isEmpty)
        #expect(defaults.dictionary(forKey: QuirkOverrideStore.storageKey) == nil)
        // A file that is not there has no identity to key by but its path; stale is tolerated, never an error.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).WS")
        #expect(QuirkOverrideStore.key(for: missing)?.hasPrefix("path:") == true)
    }
}
