import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// `ScriptingFileArgument` — decoding a `type="file"` sdef argument into a `URL`,
/// whatever shape Cocoa Scripting's own coercion handed back.
@Suite struct ScriptingFileArgumentTests {

    /// A real file on disk — `typeAlias` coercion (unlike `typeFileURL`) requires one to
    /// actually exist, since an alias record resolves to a filesystem object. `typeAlias`
    /// round-trips through the OS's Alias Manager, which fully resolves symlinks along the
    /// way, including `/var` -> `/private/var` — `URL.resolvingSymlinksInPath()` does NOT do
    /// this (Foundation special-cases `/tmp`, `/var`, and `/etc`, leaving them unresolved on
    /// purpose), so this shells out to POSIX `realpath(3)` instead, the same resolution the
    /// Alias Manager itself performs. Un-sandboxed (job 392), `NSTemporaryDirectory()` for this
    /// process is the plain per-user `/var/folders/.../T` darwin temp dir — sandboxed, it used
    /// to be an already-canonical path inside the test host's own container, with no symlink
    /// hop to expose this mismatch at all.
    private static func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptingFileArgumentTests-\(UUID().uuidString)")
        try Data().write(to: url)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    @Test func urlPassesThroughAPlainURL() throws {
        let url = URL(fileURLWithPath: "/tmp/paper.rtf")
        #expect(try ScriptingFileArgument.url(from: url) == url)
    }

    @Test func urlBridgesAnNSURL() throws {
        let nsurl = NSURL(fileURLWithPath: "/tmp/paper.rtf")
        #expect(try ScriptingFileArgument.url(from: nsurl).path == "/tmp/paper.rtf")
    }

    @Test func urlDecodesAPlainStringPath() throws {
        #expect(try ScriptingFileArgument.url(from: "/tmp/paper.rtf").path == "/tmp/paper.rtf")
    }

    @Test func urlThrowsForNil() {
        #expect(throws: ScriptingFileArgument.DecodeError.self) {
            _ = try ScriptingFileArgument.url(from: nil)
        }
    }

    @Test func urlThrowsForAnUnrelatedType() {
        #expect(throws: ScriptingFileArgument.DecodeError.self) {
            _ = try ScriptingFileArgument.url(from: NSNumber(value: 1))
        }
    }

    @Test func urlsDecodesASwiftArray() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        #expect(try ScriptingFileArgument.urls(from: urls) == urls)
    }

    @Test func urlsDecodesAnNSArray() throws {
        let array = NSArray(array: [NSURL(fileURLWithPath: "/tmp/a"), NSURL(fileURLWithPath: "/tmp/b")])
        let decoded = try ScriptingFileArgument.urls(from: array)
        #expect(decoded.map(\.path) == ["/tmp/a", "/tmp/b"])
    }

    @Test func urlsWrapsASingleValueIntoAOneElementList() throws {
        let decoded = try ScriptingFileArgument.urls(from: "/tmp/a")
        #expect(decoded == [URL(fileURLWithPath: "/tmp/a")])
    }

    @Test func urlsReturnsEmptyForNil() throws {
        #expect(try ScriptingFileArgument.urls(from: nil) == [])
    }

    // MARK: - Job 185 hardening: every raw `NSAppleEventDescriptor` shape Cocoa can hand back
    // for a `type="file"` / `type="file" list="yes"` argument, per shape: typeFileURL, typeAlias,
    // a list of either, a mixed list, and a single bare (unwrapped) item — osascript users
    // routinely omit the braces around a one-item list.

    @Test func urlDecodesATypeFileURLDescriptor() throws {
        let descriptor = NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/paper.rtf"))
        #expect(try ScriptingFileArgument.url(from: descriptor).path == "/tmp/paper.rtf")
    }

    @Test func urlDecodesATypeAliasDescriptor() throws {
        let file = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let fileURLDescriptor = NSAppleEventDescriptor(fileURL: file)
        let alias = try #require(fileURLDescriptor.coerce(toDescriptorType: typeAlias))
        #expect(alias.descriptorType == typeAlias)
        #expect(try ScriptingFileArgument.url(from: alias).path == file.path)
    }

    @Test func urlsDecodesAListOfTypeFileURLDescriptors() throws {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/a")), at: 0)
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/b")), at: 0)
        let decoded = try ScriptingFileArgument.urls(from: list)
        #expect(decoded.map(\.path).sorted() == ["/tmp/a", "/tmp/b"])
    }

    @Test func urlsDecodesAListOfTypeAliasDescriptors() throws {
        let fileA = try Self.makeTempFile()
        let fileB = try Self.makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: fileA)
            try? FileManager.default.removeItem(at: fileB)
        }

        let list = NSAppleEventDescriptor.list()
        list.insert(try #require(NSAppleEventDescriptor(fileURL: fileA).coerce(toDescriptorType: typeAlias)), at: 0)
        list.insert(try #require(NSAppleEventDescriptor(fileURL: fileB).coerce(toDescriptorType: typeAlias)), at: 0)
        let decoded = try ScriptingFileArgument.urls(from: list)
        #expect(Set(decoded.map(\.path)) == Set([fileA.path, fileB.path]))
    }

    /// The exact shape a script like `convert {POSIX file "...", (POSIX file "..." as alias)}`
    /// would produce: one list, mixed descriptor types.
    @Test func urlsDecodesAMixedListOfFileURLAndAliasDescriptors() throws {
        let file = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/a")), at: 0)
        list.insert(try #require(NSAppleEventDescriptor(fileURL: file).coerce(toDescriptorType: typeAlias)), at: 0)
        let decoded = try ScriptingFileArgument.urls(from: list)
        #expect(Set(decoded.map(\.path)) == Set(["/tmp/a", file.path]))
    }

    /// osascript users routinely omit the braces around a one-item list — `convert POSIX file
    /// "..." as RTF` sends a bare `typeFileURL` descriptor as the direct parameter, not a
    /// one-item `typeAEList`.
    @Test func urlsWrapsASingleBareAppleEventDescriptorIntoAOneElementList() throws {
        let descriptor = NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/a"))
        let decoded = try ScriptingFileArgument.urls(from: descriptor)
        #expect(decoded == [URL(fileURLWithPath: "/tmp/a")])
    }

    @Test func urlsWrapsASingleBareAliasDescriptorIntoAOneElementList() throws {
        let file = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let alias = try #require(NSAppleEventDescriptor(fileURL: file).coerce(toDescriptorType: typeAlias))
        let decoded = try ScriptingFileArgument.urls(from: alias)
        #expect(decoded == [file])
    }

    /// Job 220 (finding C): `readData` used to swallow every failure into `nil`, giving
    /// callers no way to say WHY a file was unreadable. A missing file reproduces everywhere
    /// (unlike a real access denial, which needs privilege games this suite doesn't play —
    /// job 392 removed the last of those), so this pins the throw directly.
    @Test func readDataThrowsForAMissingFileRatherThanReturningNil() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptingFileArgumentTests-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            _ = try ScriptingFileArgument.readData(at: missing)
        }
    }
}
