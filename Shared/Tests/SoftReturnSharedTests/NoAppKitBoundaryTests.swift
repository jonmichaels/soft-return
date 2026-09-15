import Foundation
import Testing

/// The boundary this package exists for: nothing in `Sources/` may import AppKit or UIKit
/// (or Cocoa, which is AppKit under another name). The iOS app's build would reject an
/// AppKit import eventually, but only when someone builds for iOS; this catches it on the
/// first `swift test` on a Mac, where AppKit compiles without complaint.
///
/// Reads the package's own sources from disk, found from this file's location, so there is
/// nothing to keep in sync when files are added or moved.
@Suite struct NoAppKitBoundaryTests {
    /// Any import form of the three modules: plain, `@testable`/`@preconcurrency` and other
    /// attributes, an access-level import (`public import`), and a scoped
    /// `import class AppKit.NSView`.
    static var forbiddenImport: Regex<AnyRegexOutput> {
        try! Regex(#"^\s*(@\w+(\([^)]*\))?\s+)*((public|package|internal|fileprivate|private)\s+)?import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?(AppKit|UIKit|Cocoa)\b"#)
    }

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoftReturnSharedTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Shared/
            .appendingPathComponent("Sources")
    }

    static func swiftSources() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourcesDirectory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Guards against the vacuous pass: a wrong path would find no files and report nothing.
    @Test func sourcesAreFound() throws {
        let sources = try Self.swiftSources()
        #expect(!sources.isEmpty, "no .swift files under \(Self.sourcesDirectory.path)")
    }

    @Test func noSourceImportsAppKitOrUIKit() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(Self.forbiddenImport) {
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line)")
            }
        }
        #expect(offenders.isEmpty, "Shared/ must not import AppKit or UIKit:\n\(offenders.joined(separator: "\n"))")
    }
}
