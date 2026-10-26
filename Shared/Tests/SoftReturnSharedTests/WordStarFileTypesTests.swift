import Foundation
import Testing
import TestSupport
@testable import SoftReturnShared

/// `WordStarFileTypes` is the one list of what Soft Return claims. The two apps declare the
/// same list to the system in build-time data that cannot call it; these tests fail when a
/// declaration drifts, so adding an extension in one place cannot be forgotten in another.
///
/// The Mac app's declaration is `macos/Info.plist`, and the Spotlight importer repeats the
/// document list in `macos/SoftReturnImporter/Info.plist`. The iPhone app's has no plist
/// file in the repo: Tuist generates it from the Swift dictionary in `ios/Project.swift`,
/// so that source is parsed here.
@Suite struct WordStarFileTypesTests {
    static var repoRoot: URL { RepoPaths.root }

    // MARK: Matching

    @Test func matchesCaseInsensitively() {
        #expect(WordStarFileTypes.isClaimed(name: "LETTER.WS"))
        #expect(WordStarFileTypes.isClaimed(name: "Old.Ws-BAK"))
        #expect(WordStarFileTypes.isClaimed(name: "TEMP.WS-$$$"))
        #expect(WordStarFileTypes.isClaimed(URL(fileURLWithPath: "/disk/CH1.WS7")))
        #expect(WordStarFileTypes.isPicture(name: "LOGO.PIX"))
        #expect(WordStarFileTypes.isPicture(URL(fileURLWithPath: "/disk/Logo.Pix")))
    }

    @Test func rejectsWhatIsNotClaimed() {
        for name in ["README", "notes.txt", "memo.doc", "x.ws10", "x.wsx", "ws", ".ws"] {
            #expect(!WordStarFileTypes.isClaimed(name: name), "\(name) must not be claimed")
        }
    }

    @Test func pictureIsNotADocument() {
        #expect(WordStarFileTypes.isPicture(name: "a.pix"))
        #expect(!WordStarFileTypes.isDocument(name: "a.pix"))
        #expect(WordStarFileTypes.isClaimed(name: "a.pix"))
        #expect(!WordStarFileTypes.isPicture(name: "a.ws"))
        #expect(WordStarFileTypes.isDocument(name: "a.ws"))
    }

    // MARK: Declarations

    /// Reads a plist from the repo as a dictionary.
    static func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The extensions a plist's `key` array (`UTExportedTypeDeclarations` or
    /// `UTImportedTypeDeclarations`) declares for `uti`. The build expands `$$` to one `$`
    /// in these files, so the same expansion is applied to what is read.
    static func declaredExtensions(in plist: [String: Any], key: String, uti: String) throws -> [String] {
        let declarations = try #require(plist[key] as? [[String: Any]], "no \(key)")
        let declaration = try #require(
            declarations.first { $0["UTTypeIdentifier"] as? String == uti }, "\(key) does not declare \(uti)")
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        let raw = try #require(tags["public.filename-extension"] as? [String])
        return raw.map { $0.replacingOccurrences(of: "$$", with: "$") }
    }

    /// Fails with the difference spelled out, and on duplicates.
    static func expectSame(_ declared: [String], as expected: Set<String>, source: String) {
        #expect(declared.count == Set(declared).count, "\(source) lists an extension twice: \(declared)")
        let set = Set(declared)
        #expect(set == expected,
                "\(source) differs from WordStarFileTypes: missing \(expected.subtracting(set).sorted()), extra \(set.subtracting(expected).sorted())")
    }

    @Test func macAppDeclaresTheClaimedTypes() throws {
        let info = try Self.plist("macos/Info.plist")
        Self.expectSame(
            try Self.declaredExtensions(in: info, key: "UTExportedTypeDeclarations", uti: WordStarFileTypes.documentUTI),
            as: WordStarFileTypes.documentExtensions, source: "macos/Info.plist document type")
        Self.expectSame(
            try Self.declaredExtensions(in: info, key: "UTExportedTypeDeclarations", uti: WordStarFileTypes.pictureUTI),
            as: [WordStarFileTypes.pictureExtension], source: "macos/Info.plist picture type")
    }

    /// The Spotlight importer declares the document type too (the build turns `$$` into `$` in
    /// its Info.plist, as in the app's).
    @Test func spotlightImporterDeclaresTheDocumentType() throws {
        let info = try Self.plist("macos/SoftReturnImporter/Info.plist")
        let declared = try Self.declaredExtensions(
            in: info, key: "UTImportedTypeDeclarations", uti: WordStarFileTypes.documentUTI)
        Self.expectSame(declared, as: WordStarFileTypes.documentExtensions,
                        source: "SoftReturnImporter/Info.plist document type")
    }

    /// The iPhone declaration lives in `ios/Project.swift` as Swift source. This reads the
    /// string literals of the `public.filename-extension` array that follows each UTI's
    /// identifier line, dropping `//` comments.
    static func iosDeclaredExtensions(uti: String) throws -> [String] {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("ios/Project.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let identifier = try #require(
            lines.firstIndex { $0.contains("\"UTTypeIdentifier\": \"\(uti)\"") },
            "ios/Project.swift has no UTTypeIdentifier \(uti)")
        let start = try #require(
            lines[identifier...].firstIndex { $0.contains("\"public.filename-extension\"") },
            "no public.filename-extension after \(uti)")
        var literals: [String] = []
        var index = start
        // The array runs from the `[` after the key to its closing `]`.
        var text = String(lines[start].drop { $0 != ":" }.dropFirst())
        while true {
            let code = text.components(separatedBy: "//")[0]
            for piece in code.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            where piece.offset % 2 == 1 {
                literals.append(String(piece.element))
            }
            if code.contains("]") { break }
            index += 1
            try #require(index < lines.count, "unterminated extension array for \(uti)")
            text = lines[index]
        }
        return literals.map { $0.replacingOccurrences(of: "$$", with: "$") }
    }

    @Test func iPhoneAppDeclaresTheClaimedTypes() throws {
        Self.expectSame(
            try Self.iosDeclaredExtensions(uti: WordStarFileTypes.documentUTI),
            as: WordStarFileTypes.documentExtensions, source: "ios/Project.swift document type")
        Self.expectSame(
            try Self.iosDeclaredExtensions(uti: WordStarFileTypes.pictureUTI),
            as: [WordStarFileTypes.pictureExtension], source: "ios/Project.swift picture type")
    }

    /// Guards against a vacuous pass from a parser that reads nothing.
    @Test func declarationReadersSeeTheRealLists() throws {
        let ios = try Self.iosDeclaredExtensions(uti: WordStarFileTypes.documentUTI)
        #expect(ios.contains("ws") && ios.contains("ws-$$$"), "read \(ios)")
    }
}
