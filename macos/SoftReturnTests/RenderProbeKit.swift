import AppKit
import Foundation
import ScreenCaptureKit

/// Generic view-inspection mechanics for the hosted tests: walking a view tree, resolving a
/// colour under an appearance, scanning rendered pixels for where ink starts, capturing a live
/// window, and drawing a view to PNG bytes in memory.
///
/// Nothing here knows about any particular app's windows, documents, or fixtures, and nothing
/// writes a file: a test that wants a picture asserts on it in memory.
@MainActor
public enum RenderProbeKit {
    public struct WindowSize: Sendable {
        public let width: CGFloat
        public let height: CGFloat
        public init(width: CGFloat, height: CGFloat) {
            self.width = width
            self.height = height
        }
        public var label: String { "\(Int(width))x\(Int(height))" }
    }

    public enum RenderProbeError: Error {
        case cannotCreateBitmap
        case cannotEncodePNG
    }

    // MARK: - JSON shapes

    public struct ColorJSON: Codable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
    }

    // MARK: - View tree

    public static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    // MARK: - Geometry

    /// `color`, resolved to concrete sRGB components under `appearance` — the mechanism a
    /// dynamic `NSColor` needs to report what it actually draws in a given appearance,
    /// independent of which color or which app defines it.
    public static func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> ColorJSON {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? resolved
        }
        return ColorJSON(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }

    // MARK: - Pixel truth

    /// Ink margins measured by SCANNING RENDERED PIXELS — the only measurement in this repo
    /// that cannot be fooled by a layout-manager or PDF-string query returning something
    /// AppKit never actually painted (a text container's own inset, `lineFragmentPadding`, a
    /// subview offset — anything invisible to a query that stops at the model layer).
    public struct InkMarginsPt: Sendable {
        public let left: Double
        public let top: Double
        public let right: Double
        public let bottom: Double
    }

    /// Scans `bitmap` inward from each of its four edges for the first pixel that is not
    /// `background` (within `tolerance`, to absorb antialiasing fringe on the page's own
    /// white) — the PIXEL TRUTH of where ink starts, converted back to points via the
    /// bitmap's actual pixel-per-point scale (2x on a Retina capture, 1x otherwise), not
    /// assumed.
    ///
    /// Early-exits each of the four scans as soon as a hit lands, rather than sweeping the
    /// whole bitmap four times over — the difference between a probe that finishes in this
    /// suite's run and one that does not.
    ///
    /// `compositeOverBackground`: judge each pixel as it looks laid over `background` — its colour
    /// weighted by its alpha — rather than by its colour alone. A capture taken at a fractional
    /// pixel scale (`cacheDisplay` at the window's backing scale times its magnification, 3.013 or
    /// 1.669 once Fit is capped at Actual Size, ruling M3) leaves the paper's own top pixel row
    /// only partly covered: the grey desk behind the page shows through at 23% alpha, which the
    /// colour-only test reads as ink at 0pt. Off by default, so every other caller measures
    /// exactly as before.
    public static func inkMargins(in bitmap: NSBitmapImageRep, background: NSColor,
                                   viewSize: CGSize, tolerance: CGFloat = 0.06,
                                   compositeOverBackground: Bool = false) -> InkMarginsPt? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let bg = background.usingColorSpace(.deviceRGB) else { return nil }
        let bgR = bg.redComponent, bgG = bg.greenComponent, bgB = bg.blueComponent

        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let alpha = compositeOverBackground ? c.alphaComponent : 1
            let r = c.redComponent * alpha + bgR * (1 - alpha)
            let g = c.greenComponent * alpha + bgG * (1 - alpha)
            let b = c.blueComponent * alpha + bgB * (1 - alpha)
            return abs(r - bgR) > tolerance
                || abs(g - bgG) > tolerance
                || abs(b - bgB) > tolerance
        }

        var minX: Int?
        columnScan: for x in 0..<width {
            for y in 0..<height where isInk(x, y) { minX = x; break columnScan }
        }
        var maxX: Int?
        columnScanR: for x in stride(from: width - 1, through: 0, by: -1) {
            for y in 0..<height where isInk(x, y) { maxX = x; break columnScanR }
        }
        var minY: Int?
        rowScan: for y in 0..<height {
            for x in 0..<width where isInk(x, y) { minY = y; break rowScan }
        }
        var maxY: Int?
        rowScanB: for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width where isInk(x, y) { maxY = y; break rowScanB }
        }
        guard let left = minX, let right = maxX, let top = minY, let bottom = maxY else { return nil }

        let scaleX = Double(width) / Double(viewSize.width)
        let scaleY = Double(height) / Double(viewSize.height)
        // Bitmap row 0 is the top of the image as rendered from a FLIPPED view (isFlipped
        // == true puts y=0 at the top already), so row index maps straight to "distance from
        // the top" with no inversion needed — verified against the renderer-level
        // (NSLayoutManager) figures for the same fixture, which land within a point.
        return InkMarginsPt(
            left: Double(left) / scaleX,
            top: Double(top) / scaleY,
            right: Double(width - 1 - right) / scaleX,
            bottom: Double(height - 1 - bottom) / scaleY
        )
    }

    // MARK: - A view as drawn

    /// A view drawn once to a bitmap and read back in its own points. SwiftUI on macOS 26 draws
    /// text, push buttons and images inside its hosting view, with no subview of their own, so
    /// what a person sees there is only in the pixels. Pixels nothing drew are transparent, and
    /// SwiftUI draws grey text as part-transparent black, so each pixel is judged laid over white
    /// (a light window's background, which the window draws and this view does not).
    @MainActor public struct Drawing {
        public let bounds: CGRect
        private let bitmap: NSBitmapImageRep
        private let scale: CGFloat
        private let flipped: Bool

        public init(_ view: NSView) throws {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw RenderProbeError.cannotCreateBitmap
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            self.bitmap = bitmap
            bounds = view.bounds
            scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            flipped = view.isFlipped
        }

        /// Every pixel position in `rect`, in points, one per pixel.
        public func points(in rect: CGRect) -> [CGPoint] {
            let rect = rect.intersection(bounds)
            guard !rect.isNull else { return [] }
            let xs = stride(from: rect.minX, to: rect.maxX, by: 1 / scale)
            return stride(from: rect.minY, to: rect.maxY, by: 1 / scale)
                .flatMap { y in xs.map { CGPoint(x: $0, y: y) } }
        }

        /// The colour drawn at `point`, or nil where nothing was drawn.
        public func color(at point: CGPoint) -> NSColor? {
            let y = flipped ? point.y : bounds.height - point.y
            let row = min(bitmap.pixelsHigh - 1, Int(y * scale))
            let column = min(bitmap.pixelsWide - 1, Int(point.x * scale))
            guard row >= 0, column >= 0,
                  let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
                  color.alphaComponent > 0.05 else { return nil }
            return color
        }

        /// 0 for black to 1 for white, laid over white; nil where nothing was drawn.
        public func luminance(at point: CGPoint) -> CGFloat? {
            color(at: point).map { color in
                let own = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                return own * color.alphaComponent + (1 - color.alphaComponent)
            }
        }

        /// Dark drawing: label text, as against the light fills behind it.
        public func isInk(at point: CGPoint) -> Bool {
            (luminance(at: point) ?? 1) < 0.5
        }

        /// The smallest rectangle holding every ink pixel in `rect`, or nil if it has none.
        public func inkBounds(in rect: CGRect) -> CGRect? {
            extent(of: points(in: rect).filter(isInk))
        }

        /// The smallest rectangle holding everything drawn in `rect`, or nil if nothing was.
        public func drawnBounds(in rect: CGRect) -> CGRect? {
            extent(of: points(in: rect).filter { color(at: $0) != nil })
        }

        private func extent(of pixels: [CGPoint]) -> CGRect? {
            guard let minX = pixels.map(\.x).min(), let maxX = pixels.map(\.x).max(),
                  let minY = pixels.map(\.y).min(), let maxY = pixels.map(\.y).max() else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1 / scale, height: maxY - minY + 1 / scale)
        }
    }

    // MARK: - Live window capture

    /// What `dataWithPDF(inside:)` and `cacheDisplay(in:to:)` cannot see: the WINDOW SERVER's
    /// own composited pixels — overlay scrollers (which animate in via a layer the offscreen
    /// PDF-context renderers never drive), a live scroll view's own chrome, anything that is
    /// downstream of an actual screen buffer rather than a view re-drawing itself into an
    /// offscreen context on request. Job 278 shipped a `dataWithPDF`-based screenshot test that
    /// PASSED while Jon's field screenshots showed real scrollbars and a grey band — this is
    /// the capture path that can actually fail when that bug is present.
    public enum LiveCaptureError: Error {
        /// `CGPreflightScreenCaptureAccess()` was false — this process has no Screen Recording
        /// grant, so no live capture in this run can be trusted as a negative result.
        case notPermitted
        case windowNotFound(CGWindowID)
    }

    /// Captures `window` exactly as the window server has it composited right now. Callers
    /// must force a layout/display pass and give the compositor a moment to catch up
    /// (`window.displayIfNeeded()`, then a short `Task.sleep`) before calling this — a capture
    /// taken mid-animation is a flaky test, not a stricter one.
    ///
    /// Job 342 (b23 floor drop): `SCScreenshotManager.captureImage` is macOS 14+ only — this
    /// is test-only infrastructure (never shipped in the app), so the honest gate is
    /// `@available`, same as `AccessibilityAuditUITests`; every caller is gated the same way.
    @available(macOS 14, *)
    @MainActor
    public static func captureWindowLive(_ window: NSWindow) async throws -> NSBitmapImageRep {
        guard CGPreflightScreenCaptureAccess() else { throw LiveCaptureError.notPermitted }
        let windowID = CGWindowID(window.windowNumber)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw LiveCaptureError.windowNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // Native pixel resolution, not points — a Retina capture at 1x would smear the exact
        // edge pixels this probe's colour comparisons depend on.
        let scale = window.backingScaleFactor
        config.width = max(1, Int((scWindow.frame.width * scale).rounded()))
        config.height = max(1, Int((scWindow.frame.height * scale).rounded()))
        config.showsCursor = false
        // EXCLUDE THE WINDOW'S SHADOW. `SCContentFilter(desktopIndependentWindow:)` includes
        // it by default, and it is not a small border: it is a wide dark gradient on every
        // side, composited into a buffer sized to the window's own frame, so the window's
        // content sits INSET within the returned image and the outer columns are shadow.
        //
        // Measured 2026-09-07: LivePrintedFramingTests reported a "foreign" pixel — neither
        // desk (0.588 grey) nor page (white) — at 0.439216 grey on the left edge, in BOTH
        // Native and Printed, and insetting the scan chased it exactly: column 0, then 2,
        // then 4, always landing on whatever the new first column was. That is not an edge
        // artifact of a particular width; it is a gradient with no edge to clear. With the
        // shadow excluded the capture is the window and nothing else, which is what every
        // colour comparison in that suite assumes it is looking at.
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSBitmapImageRep(cgImage: image)
    }

    // MARK: - PNG

    /// The PNG bytes of `view` drawn under `appearance`, for a test that compares or inspects
    /// the picture in memory and never needs a file.
    public static func pngData(view: NSView, appearance: NSAppearance) throws -> Data {
        try pngData(view: view, rect: view.bounds, appearance: appearance)
    }

    /// Same as `pngData(view:appearance:)`, but caches only `rect` (in `view`'s own
    /// coordinates) rather than the whole of `view.bounds`. `cacheDisplay(in:to:)` renders
    /// the receiver AND ITS SUBVIEWS clipped to `rect`, in real z-order — the one capture
    /// shape that reproduces a composited page (background paper + text subview + overlay
    /// subview all drawn by DIFFERENT views) rather than any single view's own drawing
    /// alone. A bare page `NSTextView` capture undercounts what a page actually shows: it has
    /// no paper/margins (painted by `PagedDocumentView.draw(_:)`), no running heads/feet
    /// (same), and nothing painted by `OversizedPassOverlayView` (a separate subview, added
    /// topmost).
    public static func pngData(view: NSView, rect: NSRect, appearance: NSAppearance) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw RenderProbeError.cannotCreateBitmap
        }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: rect, to: bitmap)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderProbeError.cannotEncodePNG
        }
        return data
    }
}
