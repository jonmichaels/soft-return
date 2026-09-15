import AppKit
import CryptoKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Planning #262, item 4: a render cache for the corpus oracles. full8 spent 642 of its 2,204
/// timed seconds in the two pixel gates, and nearly all of that is rendering the same documents
/// the same way every run. An unchanged document, rendered by an unchanged renderer, in the same
/// view, skips the render and gets its pages back from disk.
///
/// THE KEY: the document's SHA-256; the renderer version — the committed trees of the sources a
/// render reads plus a digest of their uncommitted changes, so a commit touching none of them
/// keeps every entry (`scripts/render-cache-stamp.sh`, stamped into this bundle at build time);
/// the view; the scale; a digest of the pictures the document resolves (a picture
/// can change without its document changing); and the macOS build (installed fonts render).
/// Change any of them and the lookup misses and renders again; `RenderCacheTests` proves both
/// halves, including that a cached page is pixel for pixel the page it replaced.
///
/// WHERE: `<Caches>/SoftReturnTestRenderCache/<renderer version>/<key>/` — the test host's own
/// caches folder (inside the app's container when the host is sandboxed), never the checkout or
/// the corpus. Entries for other renderer versions are removed the first time the cache is used.
///
/// OFF: no stamp (no git at build time), or `SR_RENDER_CACHE=off`. Every lookup prints one
/// `RENDER-CACHE hit|miss|off <view> <document>` line.
struct RenderCache {
    /// Where entries live; nil turns the cache off.
    let root: URL?
    /// The renderer version; nil or empty turns the cache off.
    let stamp: String?

    @MainActor static let shared: RenderCache = {
        let environment = ProcessInfo.processInfo.environment
        let switchedOff = (environment["SR_RENDER_CACHE"] ?? environment["TEST_RUNNER_SR_RENDER_CACHE"])?
            .lowercased() == "off"
        let stamp = Bundle(for: RenderCacheBundleToken.self)
            .url(forResource: "RenderCacheStamp", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0)?["stamp"] as? String }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cache = RenderCache(root: switchedOff ? nil : caches?.appendingPathComponent("SoftReturnTestRenderCache"),
                                stamp: stamp)
        cache.pruneOtherVersions()
        return cache
    }()

    var isOn: Bool { root != nil && !(stamp ?? "").isEmpty }

    /// The pages of `document` in `view`: from the cache when the key matches, otherwise from
    /// `render`, which is then stored.
    @MainActor
    func pages(of document: URL, view: String, scale: CGFloat,
               render: () throws -> [PixelOracleKit.PageImage]) throws -> [PixelOracleKit.PageImage] {
        guard isOn, let entry = try entryDirectory(document: document, view: view, scale: scale) else {
            print("RENDER-CACHE off \(view) \(document.lastPathComponent)")
            return try render()
        }
        if let cached = load(entry) {
            print("RENDER-CACHE hit \(view) \(document.lastPathComponent)")
            return cached
        }
        print("RENDER-CACHE miss \(view) \(document.lastPathComponent)")
        let pages = try render()
        store(pages, at: entry)
        return pages
    }

    // MARK: - Key

    func entryDirectory(document: URL, view: String, scale: CGFloat) throws -> URL? {
        guard let root, let stamp, !stamp.isEmpty else { return nil }
        let bytes = try Data(contentsOf: document)
        var key = "document=\(Self.sha256(bytes))\n"
        key += "view=\(view)\nscale=\(scale)\n"
        key += "pictures=\(Self.picturesDigest(bytes: [UInt8](bytes), docPath: document.path))\n"
        key += "os=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        return root
            .appendingPathComponent(Self.sha256(Data(stamp.utf8)).prefix(24).description, isDirectory: true)
            .appendingPathComponent(Self.sha256(Data(key.utf8)), isDirectory: true)
    }

    /// Every picture the document resolves, by its bytes, so replacing a `.PIX` file beside an
    /// unchanged document still misses.
    static func picturesDigest(bytes: [UInt8], docPath: String) -> String {
        guard let document = try? parse(bytes, variant: nil) else { return "unparsed" }
        let lines = DocumentPictures.resolve(document, docPath: docPath).map { result in
            "\(result.index)|\(result.rawPath)|\(result.error?.rawValue ?? "ok")|"
                + (result.rawBytes.map { sha256(Data($0)) } ?? "-")
        }
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Storage

    private struct Manifest: Codable {
        struct Page: Codable {
            let label: String
            let width: Double
            let height: Double
        }
        let pages: [Page]
    }

    func load(_ entry: URL) -> [PixelOracleKit.PageImage]? {
        guard let data = try? Data(contentsOf: entry.appendingPathComponent("pages.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        var pages: [PixelOracleKit.PageImage] = []
        for (index, page) in manifest.pages.enumerated() {
            guard let png = try? Data(contentsOf: entry.appendingPathComponent("\(index).png")),
                  let bitmap = NSBitmapImageRep(data: png)
            else { return nil }
            let size = CGSize(width: page.width, height: page.height)
            bitmap.size = size
            pages.append(PixelOracleKit.PageImage(label: page.label, bitmap: bitmap, pointSize: size))
        }
        return pages
    }

    /// Written to a sibling folder and moved into place, so a run that stops half way never
    /// leaves an entry a later run would read as complete.
    func store(_ pages: [PixelOracleKit.PageImage], at entry: URL) {
        let fileManager = FileManager.default
        let staging = entry.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, page) in pages.enumerated() {
                guard let png = page.bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: staging.appendingPathComponent("\(index).png"))
            }
            let manifest = Manifest(pages: pages.map {
                .init(label: $0.label, width: Double($0.pointSize.width), height: Double($0.pointSize.height))
            })
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("pages.json"))
            try? fileManager.removeItem(at: entry)
            try fileManager.moveItem(at: staging, to: entry)
        } catch {
            try? fileManager.removeItem(at: staging)
        }
    }

    /// Removes every renderer version's folder but this one.
    func pruneOtherVersions() {
        guard let root, let stamp, !stamp.isEmpty else { return }
        let current = Self.sha256(Data(stamp.utf8)).prefix(24).description
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions where version != current {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(version))
        }
    }
}

/// Only here so `Bundle(for:)` can find this test bundle and its `RenderCacheStamp.plist`.
private final class RenderCacheBundleToken {}

@Suite(.serialized) @MainActor
struct RenderCacheTests {
    /// The safety half of the cache: the same key hits without rendering, and a stale key — a
    /// different renderer version, or a changed document — misses and renders again, returning
    /// the new render rather than the old entry.
    @Test func anUnchangedKeyHitsAndAStaleKeyMissesAndRenders() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let document = scratch.appendingPathComponent("LYING.WS")
        try Self.sampleBytes("LYING.WS").write(to: document)
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        var renders = 0
        let render: () -> [PixelOracleKit.PageImage] = {
            renders += 1
            return [Self.solidPage(shade: renders)]
        }

        let versionA = RenderCache(root: root, stamp: "commitA-digest")
        let first = try versionA.pages(of: document, view: "probe", scale: 2, render: render)
        #expect(renders == 1, "a cold cache renders")
        let again = try versionA.pages(of: document, view: "probe", scale: 2, render: render)
        #expect(renders == 1, "an unchanged document at an unchanged renderer must not render again")
        #expect(Self.rgba(again[0].bitmap) == Self.rgba(first[0].bitmap))
        #expect(again[0].label == first[0].label && again[0].pointSize == first[0].pointSize)

        let versionB = RenderCache(root: root, stamp: "commitB-digest")
        let stale = try versionB.pages(of: document, view: "probe", scale: 2, render: render)
        #expect(renders == 2, "a new renderer version is a stale key: it must render again")
        #expect(Self.rgba(stale[0].bitmap) == Self.rgba(Self.solidPage(shade: 2).bitmap),
                "a stale key must return the new render, never the old entry")

        let otherView = try versionA.pages(of: document, view: "another-view", scale: 2, render: render)
        #expect(renders == 3, "another view is another key")
        _ = otherView

        try (Self.sampleBytes("LYING.WS") + Data([0x1A])).write(to: document)
        _ = try versionA.pages(of: document, view: "probe", scale: 2, render: render)
        #expect(renders == 4, "a changed document is a stale key: it must render again")
    }

    /// A page from the cache is pixel for pixel the page it replaced: the engine's own Printed PDF
    /// of LYING.WS, rasterized as the pixel gate rasterizes it, stored and read back.
    @Test func aCachedPageIsPixelForPixelTheRender() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let document = scratch.appendingPathComponent("LYING.WS")
        try Self.sampleBytes("LYING.WS").write(to: document)
        let cache = RenderCache(root: scratch.appendingPathComponent("cache"), stamp: "commit-digest")
        let fresh = try PixelOracleAppEngine.renderEngine(fixtureURL: document)
        #expect(!fresh.isEmpty)

        var renders = 0
        _ = try cache.pages(of: document, view: "engine-printed-pdf", scale: PixelOracleAppEngine.scale) {
            renders += 1
            return fresh
        }
        let cached = try cache.pages(of: document, view: "engine-printed-pdf", scale: PixelOracleAppEngine.scale) {
            renders += 1
            return []
        }
        #expect(renders == 1)
        #expect(cached.count == fresh.count)
        for (stored, original) in zip(cached, fresh) {
            #expect(stored.label == original.label)
            #expect(stored.pointSize == original.pointSize)
            #expect(stored.bitmap.pixelsWide == original.bitmap.pixelsWide
                    && stored.bitmap.pixelsHigh == original.bitmap.pixelsHigh)
            #expect(Self.rgba(stored.bitmap) == Self.rgba(original.bitmap), "\(original.label) differs after the cache")
        }
    }

    /// With no renderer version there is nothing safe to key on: every call renders, nothing is
    /// written.
    @Test func withNoStampEveryCallRendersAndNothingIsStored() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let document = scratch.appendingPathComponent("LYING.WS")
        try Self.sampleBytes("LYING.WS").write(to: document)
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        for stamp in [nil, ""] as [String?] {
            let cache = RenderCache(root: root, stamp: stamp)
            var renders = 0
            for _ in 0..<2 {
                _ = try cache.pages(of: document, view: "probe", scale: 2) {
                    renders += 1
                    return [Self.solidPage(shade: 1)]
                }
            }
            #expect(renders == 2)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// Renderer versions other than the current one are removed.
    @Test func otherRendererVersionsArePruned() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        let old = root.appendingPathComponent("0123456789abcdef01234567", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let cache = RenderCache(root: root, stamp: "current-digest")
        let current = try #require(try? cache.entryDirectory(
            document: Self.writeSample(into: scratch), view: "probe", scale: 2)?.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        cache.pruneOtherVersions()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    // MARK: - Helpers

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sampleBytes(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SoftReturn/Resources/SampleDocuments/\(name)")
        return try Data(contentsOf: url)
    }

    static func writeSample(into folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("LYING.WS")
        try sampleBytes("LYING.WS").write(to: url)
        return url
    }

    static func solidPage(shade: Int) -> PixelOracleKit.PageImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let value = CGFloat(shade % 6) / 5
        for x in 0..<8 {
            for y in 0..<8 {
                bitmap.setColor(NSColor(deviceRed: value, green: 1 - value, blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        bitmap.size = CGSize(width: 4, height: 4)
        return PixelOracleKit.PageImage(label: "p1", bitmap: bitmap, pointSize: CGSize(width: 4, height: 4))
    }

    /// The pixels as the gate reads them: drawn into one 8-bit RGBA buffer.
    static func rgba(_ bitmap: NSBitmapImageRep) -> Data {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = bitmap.cgImage
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}
