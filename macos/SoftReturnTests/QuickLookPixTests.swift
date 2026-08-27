import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 374 (QL-PIX): Finder previews standalone `.PIX` files. `QuickLookPixRenderer` (mirrored
/// into `SoftReturnQuickLook`/`SoftReturnThumbnail` the same way `QuickLookNativeRenderer` is —
/// see that type's own doc comment) is exercised directly here, the same "can't import the
/// appex module, so call the shared, mirrored code directly" workaround `QLCLIByteParityTests`/
/// `QuickLookExtensionTests` already use for the WordStar path.
@Suite struct QuickLookPixTests {

    /// job 531: `SoftReturnQuickLook/`, `SoftReturnThumbnail/`, and the app's own `Info.plist`
    /// all moved INTO `macos/` alongside this test file (siblings), so they resolve two
    /// levels up, not three like `TestDocs` (which stayed at the true repo root and did NOT
    /// move into `macos/`, and — job 535 — is resolved via `PrivateCorpusSupport` below).
    static var macosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
    }

    /// The real corpus fixture `PixInViewsTests`/`DocumentPictures` already resolve as an
    /// EMBEDDED `.PIX` reference from `PREVIEW.WS` — here it stands alone, exactly the shape a
    /// person would get handing Finder a bare `.PIX` off the same floppy image. Job 535:
    /// routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var wordstarPixURL: URL {
        PrivateCorpusSupport.ws7Directory.appendingPathComponent("INSET/PIX/WORDSTAR.PIX")
    }

    static var wordstarPixBytes: [UInt8] {
        get throws { [UInt8](try Data(contentsOf: wordstarPixURL)) }
    }

    // MARK: - Preview path (PreviewProvider's new branch)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func renderedPixProducesARealPNGForTheFixture() throws {
        let rendered = try QuickLookPixRenderer.renderedPix(fromFileBytes: Self.wordstarPixBytes)
        #expect(rendered.png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                "renderedPix's data must start with the PNG magic bytes")
        #expect(rendered.sizeInPoints.width > 0 && rendered.sizeInPoints.height > 0,
                "WORDSTAR.PIX carries a print-options size record; sizeInPoints must not be zero")
    }

    /// Cross-check against the same decode `DocumentPictures`/`PixInViewsTests` already trust
    /// for the EMBEDDED case — `pixToPNG`'s bytes must be identical regardless of whether the
    /// `.PIX` arrived as a standalone file or an in-document reference, since both paths call
    /// the exact same `CtrlKD.pixToPNG`.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func renderedPixMatchesDirectPixToPNG() throws {
        let bytes = try Self.wordstarPixBytes
        let rendered = try QuickLookPixRenderer.renderedPix(fromFileBytes: bytes)
        let direct = try Data(pixToPNG(bytes))
        #expect(rendered.png == direct)
    }

    // MARK: - Thumbnail path (ThumbnailProvider's new branch)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func thumbnailImageIsCappedAtMaxDimensionAndKeepsAspect() throws {
        let bytes = try Self.wordstarPixBytes
        let (width, height, _) = try pixDecode(bytes)
        let aspect = Double(width) / Double(height)

        let (image, size) = try QuickLookPixRenderer.thumbnailImage(
            fromFileBytes: bytes, maximumSize: CGSize(width: 4000, height: 4000), maxDimension: 512)
        #expect(size.width <= 512.0001 && size.height <= 512.0001,
                "thumbnailImage must never exceed maxDimension regardless of maximumSize: \(size)")
        #expect(image.width > 0 && image.height > 0)
        let gotAspect = Double(size.width) / Double(size.height)
        #expect(abs(gotAspect - aspect) < 0.01, "thumbnail must preserve the source aspect ratio")
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func thumbnailImageNeverExceedsARequestedSizeSmallerThanTheCap() throws {
        let bytes = try Self.wordstarPixBytes
        let requested = CGSize(width: 64, height: 64)
        let (_, size) = try QuickLookPixRenderer.thumbnailImage(
            fromFileBytes: bytes, maximumSize: requested)
        #expect(size.width <= 64.0001 && size.height <= 64.0001)
    }

    // MARK: - Content-based dispatch: a real WordStar file is not a PIX

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func aRealWordStarFixtureIsNotMistakenForAPIX() throws {
        let wsURL = PrivateCorpusSupport.ws7Directory.appendingPathComponent("OLDTIMES.WS")
        let bytes = [UInt8](try Data(contentsOf: wsURL))
        #expect(throws: (any Error).self) {
            try QuickLookPixRenderer.renderedPix(fromFileBytes: bytes)
        }
        #expect(throws: (any Error).self) {
            try QuickLookPixRenderer.thumbnailImage(
                fromFileBytes: bytes, maximumSize: CGSize(width: 256, height: 256))
        }
    }

    // MARK: - Bundle wiring: both extensions declare the PIX UTI

    @Test func quickLookInfoPlistDeclaresThePixUTI() throws {
        let url = Self.macosRoot.appendingPathComponent("SoftReturnQuickLook/Info.plist")
        let data = try #require(FileManager.default.contents(atPath: url.path))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ext = try #require(plist["NSExtension"] as? [String: Any])
        let attributes = try #require(ext["NSExtensionAttributes"] as? [String: Any])
        let types = try #require(attributes["QLSupportedContentTypes"] as? [String])
        #expect(types.contains("me.beforeti.wordstar-pix"))
    }

    @Test func thumbnailInfoPlistDeclaresThePixUTI() throws {
        let url = Self.macosRoot.appendingPathComponent("SoftReturnThumbnail/Info.plist")
        let data = try #require(FileManager.default.contents(atPath: url.path))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ext = try #require(plist["NSExtension"] as? [String: Any])
        let attributes = try #require(ext["NSExtensionAttributes"] as? [String: Any])
        let types = try #require(attributes["QLSupportedContentTypes"] as? [String])
        #expect(types.contains("me.beforeti.wordstar-pix"))
    }

    @Test func appInfoPlistExportsThePixUTI() throws {
        let url = Self.macosRoot.appendingPathComponent("Info.plist")
        let data = try #require(FileManager.default.contents(atPath: url.path))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let pix = try #require(exported.first { ($0["UTTypeIdentifier"] as? String) == "me.beforeti.wordstar-pix" },
                               "app Info.plist must export me.beforeti.wordstar-pix")
        let tagSpec = try #require(pix["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try #require(tagSpec["public.filename-extension"] as? [String])
        #expect(extensions == ["pix"])
    }
}
