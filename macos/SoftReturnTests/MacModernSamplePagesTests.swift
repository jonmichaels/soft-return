import AppKit
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// iOS stage 5 (batch 10): the Mac Modern view's pages for the four bundled samples, as the
/// reference the iOS `ModernPageComparisonTests` compare against page for page — the Modern
/// counterpart of `MacNativeSamplePagesTests`.
///
/// The same capture as the pixel oracle's `PixelOracleAppEngine.renderApp`, with the window in
/// Modern: continuous scroll, magnification 1, each page drawn offscreen with `cacheDisplay` at
/// 2x. Settings come from a throwaway defaults suite, so Modern reads the factory Georgia 14 —
/// the same face the iOS side reads from its own fresh settings. No Screen Recording and no
/// private corpus.
///
/// Written to `ios/ScreenshotProofs/MacModern/` (ignored by git) as `<SAMPLE>-p<N>.png` with
/// `manifest.json`.
@Suite(.serialized) @MainActor
struct MacModernSamplePagesTests {
    static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoftReturnTests/
            .deletingLastPathComponent()  // macos/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("ios/ScreenshotProofs/MacModern", isDirectory: true)
    }

    @Test func modernPagesOfEveryBundledSample() throws {
        let items = SampleDocuments.items(bundle: .main)
        #expect(items.map(\.title) == ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"])

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacModernSamplePages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        var manifest: [String: [MacNativeSamplePagesTests.ManifestPage]] = [:]
        for item in items {
            let copy = try BundledSampleFixture.copy(item.url.lastPathComponent, into: scratch)
            let pages = try Self.renderModern(fixtureURL: copy)
            #expect(!pages.isEmpty, "\(item.title) captured no Modern pages")

            var written: [MacNativeSamplePagesTests.ManifestPage] = []
            for page in pages {
                let png = try #require(page.bitmap.representation(using: .png, properties: [:]),
                                       "\(item.title) \(page.label) did not encode")
                let file = "\(item.title)-\(page.label).png"
                try png.write(to: Self.outputDirectory.appendingPathComponent(file))
                written.append(.init(file: file, widthPoints: page.pointSize.width,
                                     heightPoints: page.pointSize.height))
            }
            manifest[item.title] = written
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: Self.outputDirectory.appendingPathComponent("manifest.json"))
    }

    /// `PixelOracleAppEngine.renderApp`, in Modern.
    static func renderModern(fixtureURL: URL) throws -> [PixelOracleKit.PageImage] {
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let suite = "MacModernSamplePages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults),
                                      docPath: fixtureURL.path)
        let controller = DocumentWindowController(state: state)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        controller.setStyle(.modern)
        controller.setDisplay(.continuousScroll)
        let content = try #require(controller.window?.contentView)
        let scrollView = try #require(RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }.first)
        scrollView.magnification = 1.0
        content.layoutSubtreeIfNeeded()

        let pagedView = controller.pagedView
        let scale = PixelOracleAppEngine.scale
        var images: [PixelOracleKit.PageImage] = []
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: max(1, Int((rect.width * scale).rounded())),
                pixelsHigh: max(1, Int((rect.height * scale).rounded())),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), "page \(index)")
            bitmap.size = rect.size
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                pagedView.cacheDisplay(in: rect, to: bitmap)
            }
            images.append(PixelOracleKit.PageImage(label: "p\(index + 1)", bitmap: bitmap, pointSize: rect.size))
        }
        controller.close()
        return images
    }
}
