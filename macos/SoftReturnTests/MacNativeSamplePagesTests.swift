import AppKit
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// iOS stage 4 (batch 9): the Mac Native view's pages for the four bundled samples, as the
/// reference the iOS `NativeScreenshotTests` compare against page for page.
///
/// Captured through the pixel oracle's own path — `PixelOracleAppEngine.renderApp`: the real
/// document window in Native, continuous scroll, magnification 1, each page drawn offscreen with
/// `cacheDisplay` at 2x. No Screen Recording and no private corpus: the samples are the app's
/// bundled public-domain documents, copied into a scratch folder first.
///
/// Written to `ios/ScreenshotProofs/MacNative/` (ignored by git, so the tree stays clean) as
/// `<SAMPLE>-p<N>.png`, with `manifest.json` giving each page's size in points — where the iOS
/// test, reading through its own `#filePath`, finds them.
@Suite(.serialized) @MainActor
struct MacNativeSamplePagesTests {
    static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoftReturnTests/
            .deletingLastPathComponent()  // macos/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("ios/ScreenshotProofs/MacNative", isDirectory: true)
    }

    struct ManifestPage: Codable {
        let file: String
        let widthPoints: Double
        let heightPoints: Double
    }

    @Test func nativePagesOfEveryBundledSample() throws {
        let items = SampleDocuments.items(bundle: .main)
        #expect(items.map(\.title) == ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"])

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacNativeSamplePages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        var manifest: [String: [ManifestPage]] = [:]
        for item in items {
            let copy = try BundledSampleFixture.copy(item.url.lastPathComponent, into: scratch)
            let pages = try PixelOracleAppEngine.renderApp(fixtureURL: copy)
            // The Native view paginates as the engine does: one captured page per engine page.
            let bytes = [UInt8](try Data(contentsOf: copy))
            #expect(pages.count == (try DocumentOperations.pageCount(data: bytes)), "\(item.title)")

            var written: [ManifestPage] = []
            for page in pages {
                let png = try #require(page.bitmap.representation(using: .png, properties: [:]),
                                       "\(item.title) \(page.label) did not encode")
                let file = "\(item.title)-\(page.label).png"
                try png.write(to: Self.outputDirectory.appendingPathComponent(file))
                written.append(ManifestPage(file: file, widthPoints: page.pointSize.width,
                                            heightPoints: page.pointSize.height))
            }
            manifest[item.title] = written
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: Self.outputDirectory.appendingPathComponent("manifest.json"))
    }
}
