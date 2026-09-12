import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// A document opened by a RELATIVE path must still find its sibling `.PIX`.
///
/// `DocumentPictures` is the app's copy of `sr`'s picture resolver, kept in lockstep on
/// purpose (see that file's own header), and it carried the bug sr fixed in 0a082bd: a
/// relative document path with no directory component at all — `DOC.WS`, which is exactly
/// what opening a document from its own directory produces — has `dirname() == ""`, and `""`
/// is not a directory anything can list. So the sibling image was never found, while the
/// SAME document opened by its absolute path resolved fine.
///
/// The suite is serialized and restores the working directory because a relative path only
/// means anything against one, and that is process-global state.
@Suite(.serialized) struct DocumentPicturesRelativePathTests {

    /// A document carrying one `.PIX` reference, built by parsing an ordinary document and
    /// then naming the graphic directly — the resolver takes `doc.graphics` as its input, so
    /// this exercises exactly what it reads without needing a real embedded pix tag's bytes.
    private static func document(referencing image: String) -> CtrlKD.Document {
        var doc = parseWS(Array("A document with one picture in it.\r\n".utf8))
        doc.graphics = [image]
        return doc
    }

    /// The image itself is deliberately not a valid PIX: resolution and decoding are separate
    /// steps, and this test is about the first one. A resolved-but-undecodable file reports
    /// `.formatError` with `resolvedPath` set; an unfound one reports `.unresolved` with no
    /// path at all, which is the bug's signature.
    private static func write(_ directory: URL, _ name: String) throws {
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: directory.appendingPathComponent(name))
    }

    @Test func aBareFilenameFindsItsSiblingImage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixrel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory, "PIC.PIX")
        try Data("A document with one picture in it.\r\n".utf8)
            .write(to: directory.appendingPathComponent("DOC.WS"))

        let saved = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(saved) }
        try #require(FileManager.default.changeCurrentDirectoryPath(directory.path),
                     "could not enter the temporary directory")

        // The whole point: a BARE filename, no directory component, exactly as opening a
        // document from its own directory produces.
        let results = DocumentPictures.resolve(Self.document(referencing: "PIC.PIX"),
                                               docPath: "DOC.WS")
        let result = try #require(results.first, "the resolver returned no result at all")
        #expect(result.error != .unresolved, """
            a document opened as "DOC.WS" did not find its sibling PIC.PIX — this is the \
            empty-dirname bug: "" is not a listable directory, so the sibling was never \
            searched
            """)
        let path = try #require(result.resolvedPath, "no resolved path for PIC.PIX")
        #expect(path.hasSuffix("PIC.PIX"), "resolved to \(path), which is not the sibling image")
    }

    /// One directory component, still relative — the case sr's `ancestors` fix covers: the
    /// walk must reach the working directory above `subdir`, not stop one level short.
    @Test func aRelativePathWithOneDirectoryComponentWalksUpToTheWorkingDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixrel-\(UUID().uuidString)", isDirectory: true)
        let subdirectory = root.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The image sits ABOVE the document, so only an ancestor walk that reaches the
        // working directory finds it.
        try Self.write(root, "PIC.PIX")
        try Data("A document with one picture in it.\r\n".utf8)
            .write(to: subdirectory.appendingPathComponent("DOC.WS"))

        let saved = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(saved) }
        try #require(FileManager.default.changeCurrentDirectoryPath(root.path),
                     "could not enter the temporary directory")

        let results = DocumentPictures.resolve(Self.document(referencing: "PIC.PIX"),
                                               docPath: "subdir/DOC.WS")
        let result = try #require(results.first, "the resolver returned no result at all")
        #expect(result.error != .unresolved, """
            "subdir/DOC.WS" did not find PIC.PIX one level up — the ancestor walk stopped \
            before the working directory
            """)
    }

    /// The control: an ABSOLUTE path has never been affected, because an absolute path's
    /// dirname is never empty. If this ever fails, the fix broke the case that already
    /// worked.
    @Test func anAbsolutePathStillFindsItsSiblingImage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixrel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.write(directory, "PIC.PIX")
        let document = directory.appendingPathComponent("DOC.WS")
        try Data("A document with one picture in it.\r\n".utf8).write(to: document)

        let results = DocumentPictures.resolve(Self.document(referencing: "PIC.PIX"),
                                               docPath: document.path)
        let result = try #require(results.first, "the resolver returned no result at all")
        #expect(result.error != .unresolved, "an absolute path must still find its sibling image")
    }
}
