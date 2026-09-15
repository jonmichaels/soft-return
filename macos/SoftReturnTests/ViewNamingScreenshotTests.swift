import AppKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// #271 M11 (batch 30, ruled 2026-09-14): Native, Printed and Modern are VIEWS wherever a person reads them. The
/// Settings window's "Starting View:" reads "Open at Launch:" with the choices Document Viewer and Batch Exporter, and
/// "Default Style:" reads "Default View:"; the document window's bottom-bar menu is headed View.
///
/// Real pixels of the Settings window, light and dark: its content view drawn with `cacheDisplay` (no Screen Recording
/// permission), as `Job315ScreenshotTests` does, then laid over the window's own background colour in the same
/// appearance — the content view paints no background (the window does), so a dark capture of the view alone was white
/// text on transparency. Written into this process's temporary folder; each PNG's path prints as a
/// `VIEW-NAMING-SCREENSHOT` line. And the controls behind the labels: the Open at Launch popup
/// offers exactly the ruled choices, and both renamed popups say what they are to VoiceOver.
@Suite(.serialized)
@MainActor
struct ViewNamingScreenshotTests {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ViewNamingScreenshotTests", isDirectory: true)

    private func controller() -> SettingsWindowController {
        SettingsWindowController(
            settings: SettingsStore(defaults: UserDefaults(suiteName: "ViewNaming.settings.\(UUID().uuidString)")!),
            quickLookDefaultsOverride: UserDefaults(suiteName: "ViewNaming.ql.\(UUID().uuidString)")!)
    }

    private func popup(_ identifier: String, in view: NSView) -> NSPopUpButton? {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == identifier }
    }

    /// `view` drawn in `appearance`, over `NSColor.windowBackgroundColor` resolved in that appearance, as a PNG at `url`.
    static func renderOverWindowBackground(_ view: NSView, appearance: NSAppearance, to url: URL) throws -> Int {
        let bounds = view.bounds
        let capture = try #require(view.bitmapImageRepForCachingDisplay(in: bounds), "no bitmap for the view")
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: capture) }
        let opaque = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: capture.pixelsWide, pixelsHigh: capture.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0), "no bitmap to compose into")
        opaque.size = capture.size
        // The background as a concrete colour, resolved in `appearance` — a dynamic system colour set while some
        // other appearance is current would paint that one's.
        var background = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .black
        }
        let context = try #require(NSGraphicsContext(bitmapImageRep: opaque), "no graphics context")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(origin: .zero, size: capture.size).fill()
        // Source-over: `NSImageRep.draw(in:)` copies, which would put the capture's transparency back over the fill.
        capture.draw(in: NSRect(origin: .zero, size: capture.size), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        // A corner of the window is background: it must be opaque, or the picture is the view's transparency again.
        let corner = try #require(opaque.colorAt(x: 2, y: 2), "no corner pixel")
        #expect(corner.alphaComponent == 1, "the capture's corner is not opaque (alpha \(corner.alphaComponent))")
        let png = try #require(opaque.representation(using: .png, properties: [:]), "no PNG")
        try png.write(to: url)
        return png.count
    }

    @Test func settingsWindowSaysViewAndOpenAtLaunch() throws {
        let controller = controller()
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let openAtLaunch = try #require(popup("starting-view-control", in: content))
        #expect(openAtLaunch.itemTitles == ["Document Viewer", "Batch Exporter"])
        #expect(openAtLaunch.accessibilityLabel() == "Open at launch")
        let defaultView = try #require(popup("default-style-control", in: content))
        #expect(defaultView.itemTitles == ["Native", "Printed", "Modern"])
        #expect(defaultView.accessibilityLabel() == "Default view")
    }

    @Test(arguments: ["light", "dark"])
    func settingsWindowPNG(appearanceName: String) throws {
        let appearance = try #require(NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua))
        let controller = controller()
        controller.window?.appearance = appearance
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView, "settings window has no contentView")
        content.layoutSubtreeIfNeeded()

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("settings-view-naming-\(appearanceName).png")
        let pngSize = try Self.renderOverWindowBackground(content, appearance: appearance, to: url)
        #expect(pngSize > 0, "\(url.lastPathComponent) was written empty")
        print("VIEW-NAMING-SCREENSHOT \(url.path) \(pngSize) bytes")
    }
}
