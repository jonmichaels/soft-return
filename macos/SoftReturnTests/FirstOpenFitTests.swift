import AppKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// A document opens the way the app opens it — progressive, its first-open window sized from its page — zoomed to fit
/// with no desk showing: on every side of the content area the page's own white reaches the edge, in Native, Modern and
/// Printed (R-125). Measured on pixels in a band along each edge of the pages' area, where desk would show, never on
/// the window's own numbers: the window's content view drawn in-process, less the bottom bar.
@MainActor
@Suite(.serialized)
struct FirstOpenFitTests {
    static let samples = ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"]
    static let light = NSAppearance(named: .aqua)!

    @Test(arguments: [ViewStyle.native, .modern, .printed])
    func everySampleOpensFittedWithNoDesk(style: ViewStyle) async throws {
        let samples = try #require(Bundle.main.url(forResource: "SampleDocuments", withExtension: nil))
        for name in Self.samples {
            let url = samples.appendingPathComponent(name)
            let suite = "FirstOpenFit.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)
            settings.defaultStyle = style
            settings.defaultZoom = .fit
            let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: settings, docPath: url.path)
            let controller = DocumentWindowController(state: state, settings: settings, progressiveOpen: true)
            controller.window?.appearance = Self.light
            controller.showWindow(nil)
            defer { controller.close() }
            let window = try #require(controller.window)
            let deadline = Date().addingTimeInterval(20)
            while controller.isLoadingContent, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!controller.isLoadingContent, "\(name) \(style.displayName): still loading after 20 s")
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(400))

            let page = controller.currentPageSize()
            let viewport = controller.currentViewportSize()
            let fit = min(viewport.width / page.width, viewport.height / page.height)
            #expect(abs(controller.currentMagnification - min(fit, controller.currentActualScale)) < 0.002,
                    "\(name) \(style.displayName): magnification \(controller.currentMagnification), fit \(fit)")

            let desk = try await Self.deskPixels(controller)
            var detail = "\(name) \(style.displayName): \(desk.count) desk pixels of \(desk.total) in the content area"
            detail += " (\(desk.how), \(desk.box)), page \(page), viewport \(viewport), scale \(controller.currentMagnification)"
            #expect(desk.count == 0, "\(detail)")
            // The band is the page's own white margin: a view that drew nothing there would show no desk either.
            #expect(desk.white > 0.9, "\(name) \(style.displayName): only \(desk.white) of the edge band is page white")
            if let folder = ProcessInfo.processInfo.environment["FIRST_OPEN_FIT_PNGS"], let png = desk.png {
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(style.displayName).png"))
            }
        }
    }

    /// How much of the edge band of the pages' area is the desk's grey, drawn in-process.
    static func deskPixels(_ controller: DocumentWindowController) async throws -> (count: Int, total: Int, share: Double, how: String, box: String, white: Double, png: Data?) {
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        // The pages' area: the content view less the bottom bar, the same for the paged view and the PDF view.
        let area = NSRect(x: 0, y: BottomBar.barHeight, width: content.bounds.width,
                          height: content.bounds.height - BottomBar.barHeight)
        let pagesArea = content.isFlipped
            ? NSRect(x: 0, y: 0, width: area.width, height: area.height) : area
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: pagesArea))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: pagesArea, to: bitmap)
        }
        let rect = (x: 0 ..< bitmap.pixelsWide, y: 0 ..< bitmap.pixelsHigh)
        let how = "drawn"
        var count = 0
        var total = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var whites = 0
        // Desk showing reaches an edge of the content area; grey ink inside the page (LYING.WS has some) is not desk.
        let band = 8
        for y in rect.y {
            for x in rect.x {
                let nearEdge = x - rect.x.lowerBound < band || rect.x.upperBound - x <= band
                    || y - rect.y.lowerBound < band || rect.y.upperBound - y <= band
                guard nearEdge else { continue }
                total += 1
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 { whites += 1 }
                // Desk, or desk blended into the page's last pixel: anything along the edge that is not page white. A
                // page's margins are white well past this band, so ink never reaches it.
                if c.redComponent < 0.93 || c.greenComponent < 0.93 || c.blueComponent < 0.93 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let box = count == 0 ? "none" : "pixels x \(minX)...\(maxX), y \(minY)...\(maxY) of \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)"
        return (count, total, Double(count) / Double(max(total, 1)), how, box, Double(whites) / Double(max(total, 1)),
                bitmap.representation(using: .png, properties: [:]))
    }
}
