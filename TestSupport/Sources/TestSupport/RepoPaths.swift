import Foundation

/// Where the repo is, computed from this file's own location.
public enum RepoPaths {
    /// The repo root: `TestSupport/Sources/TestSupport/RepoPaths.swift` is four levels down.
    public static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TestSupport/ (target)
        .deletingLastPathComponent()  // Sources/
        .deletingLastPathComponent()  // TestSupport/ (package)
        .deletingLastPathComponent()  // repo root

    /// A path inside the repo, e.g. `RepoPaths.url("TestDocs/oracle/answer_key_private.json")`.
    public static func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }
}
