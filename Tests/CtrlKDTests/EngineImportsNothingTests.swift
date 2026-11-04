import Foundation
import Testing
import TestSupport

/// The engine's floor (Package.swift, Jon 2026-08-17): pure Swift stdlib — no Foundation, no
/// frameworks. Every source in `Sources/CtrlKD` builds without a single import, and an import
/// that slips in compiles without complaint on a Mac, so this reads the sources and fails on any.
/// Planning #596: `PDFLaserJet.swift` imported Foundation for one `CharacterSet` from 5.0.0b1 until
/// this caught it.
///
/// Reads the package's own sources from disk, found from the repo root, so there is nothing to
/// keep in sync when files are added or moved.
@Suite struct EngineImportsNothingTests {
    /// Whether `line` is an import in any form: plain, after `@testable`/`@preconcurrency` and other
    /// attributes or an access level (`public import`), and scoped (`import struct Foundation.Data`).
    /// By hand rather than a `Regex`, which needs macOS 13 where this package's floor is 10.15.
    static func isImport(_ line: Substring) -> Bool {
        let modifiers: Set<Substring> = ["public", "package", "internal", "fileprivate", "private"]
        for word in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if word == "import" { return true }
            guard word.hasPrefix("@") || modifiers.contains(word) else { return false }
        }
        return false
    }

    static var sourcesDirectory: URL { RepoPaths.url("Sources/CtrlKD") }

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

    @Test func noSourceImportsAnything() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.isImport(line) {
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line)")
            }
        }
        #expect(offenders.isEmpty, "Sources/CtrlKD must import nothing (stdlib only):\n\(offenders.joined(separator: "\n"))")
    }
}
