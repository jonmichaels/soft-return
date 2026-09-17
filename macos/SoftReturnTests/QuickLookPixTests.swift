import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
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

/// Batch 47 (M28a, Jon: Quick Look on a `.PIX` showed a zoomed-in part of the picture): the preview is the whole picture,
/// fitted and centred, whatever size Quick Look makes the window — rendered at the picture's own size, at the old default
/// 612 × 792, and in a wide window — and it never asks Auto Layout for the picture's pixel size. Also the size the
/// pinned `NSImageView` it replaces asked for, which is what zoomed it. Renders: m28a-pix-<width>x<height>.png.
@Suite("Quick Look picture preview (M28a)", .serialized)
@MainActor
struct QuickLookPictureViewTests {
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func theWholePictureIsShownAtEverySize() throws {
        let bytes = try QuickLookPixTests.wordstarPixBytes
        let (view, size) = try #require(QuickLookPictureView.preview(fromFileBytes: bytes))
        let pixelImage = try #require(NSImage(data: try QuickLookPixRenderer.renderedPix(fromFileBytes: bytes).png))
        print("M28a: picture \(size) pt; decoded image \(pixelImage.size); a pinned NSImageView asks for \(NSImageView(image: pixelImage).intrinsicContentSize)")
        #expect(view.intrinsicContentSize == NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        for window in [size, CGSize(width: 612, height: 792), CGSize(width: 1400, height: 600)] {
            let container = NSView(frame: NSRect(origin: .zero, size: window))
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.layoutSubtreeIfNeeded()
            #expect(abs(view.frame.width - window.width) < 0.5 && abs(view.frame.height - window.height) < 0.5,
                    "the view is \(view.frame.size) in a \(window) window")
            let picture = view.pictureRect
            let aspect = size.width / size.height
            #expect(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(picture), "picture \(picture) outside \(view.bounds)")
            #expect(abs(picture.width / picture.height - aspect) < 0.01)
            #expect(abs(picture.width - window.width) < 0.5 || abs(picture.height - window.height) < 0.5,
                    "picture \(picture) does not fill \(window) on either axis")
            let png = proofs.appendingPathComponent("m28a-pix-\(Int(window.width))x\(Int(window.height)).png")
            #expect(try RenderProbeKit.renderPNG(view: container, appearance: NSAppearance(named: .aqua)!, to: png) > 0)
            print("M28a: window \(window), picture drawn at \(picture); PROOF: \(png.path)")
        }
    }
}

/// Batch 47 (M28b): Soft Return claims the WordStar picture on the Mac — a Viewer document type, rank Owner, for the
/// `.PIX` type the app exports, opened by `PixDocument` into a window showing the whole picture. And the WordStar
/// document type's `ws-$$$` extension survives the build's `$$` escape. Render: m28b-pix-window.png.
@Suite("The Mac claims .PIX (M28b)", .serialized)
@MainActor
struct PixDocumentTests {
    @Test func theAppOwnsThePixType() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let pix = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("me.beforeti.wordstar-pix") == true },
                               "no document type claims me.beforeti.wordstar-pix")
        #expect(pix["LSHandlerRank"] as? String == "Owner")
        #expect(pix["CFBundleTypeRole"] as? String == "Viewer")
        #expect(pix["NSDocumentClass"] as? String == "SoftReturn.PixDocument")
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let pixUTI = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "me.beforeti.wordstar-pix" })
        #expect(((pixUTI["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) == ["pix"])
        let wordstar = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "me.beforeti.wordstar-document" })
        let extensions = (wordstar["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? []
        #expect(extensions.contains("ws-$$$"), "the built plist lists \(extensions)")
        #expect(NSDocumentController.shared.documentClass(forType: "me.beforeti.wordstar-pix") == PixDocument.self)
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func aPixOpensInAWindowOfItsOwn() throws {
        let document = try PixDocument(contentsOf: QuickLookPixTests.wordstarPixURL, ofType: "me.beforeti.wordstar-pix")
        let picture = try #require(document.picture)
        document.makeWindowControllers()
        defer { document.close() }
        let window = try #require(document.windowControllers.first?.window)
        let view = try #require(window.contentView as? QuickLookPictureView)
        window.contentView?.layoutSubtreeIfNeeded()
        let content = window.contentRect(forFrameRect: window.frame).size
        print("M28b: picture \(picture.size), window content \(content), drawn at \(view.pictureRect)")
        #expect(abs(content.width / content.height - picture.size.width / picture.size.height) < 0.02)
        #expect(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.pictureRect))
        #expect(throws: (any Error).self) { try document.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("x.pix"), ofType: "me.beforeti.wordstar-pix") }
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let png = proofs.appendingPathComponent("m28b-pix-window.png")
        #expect(try RenderProbeKit.renderPNG(view: view, appearance: NSAppearance(named: .aqua)!, to: png) > 0)
        print("PROOF: \(png.path)")
    }
}
