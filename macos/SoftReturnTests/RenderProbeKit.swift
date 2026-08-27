import AppKit
import Foundation
import ScreenCaptureKit

/// Generic render-probe mechanics: writing a deterministic PNG, resolving where captures
/// land, and the JSON shapes a geometry report is made of.
///
/// Nothing here knows about any particular app's windows, documents, or fixtures — that is
/// the ADAPTER's job (`RenderProbeTests.swift`, for this repo: which window to build, which
/// fixtures to feed it, which of its views count as "the popups" or "the canvas"). This
/// file is the reusable half: the part that would be identical for a render-probe harness
/// over a completely different AppKit app. Kept as one file with a generic API, per Jon's
/// standing ruling on probe utilities — no separate package yet, just a clean boundary.
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

    public struct RectJSON: Codable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public init(_ rect: CGRect) {
            x = Double(rect.origin.x)
            y = Double(rect.origin.y)
            width = Double(rect.width)
            height = Double(rect.height)
        }
    }

    public struct ColorJSON: Codable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
    }

    public struct PopupJSON: Codable, Sendable {
        public let identifier: String
        public let width: Double
        public let selectedTitle: String
        public init(identifier: String, width: Double, selectedTitle: String) {
            self.identifier = identifier
            self.width = width
            self.selectedTitle = selectedTitle
        }
    }

    /// How far a document view sits from each edge of the clip view that scrolls it — the
    /// evidence for whether it is centred, not an assertion that it is.
    public struct CenteringJSON: Codable, Sendable {
        public let insetLeft: Double
        public let insetRight: Double
        public let insetTop: Double
        public let insetBottom: Double
    }

    // MARK: - View tree

    public static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    // MARK: - Output directory

    /// `isWritableFile(atPath:)` checks POSIX permissions, not sandbox scope, so it can say
    /// yes to a path the sandbox will still refuse at the syscall level. An actual write
    /// attempt is the only check that agrees with what a later real write will be able to
    /// do.
    public static func canWrite(to directory: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return false }
        let probe = directory.appendingPathComponent(".render-probe-write-check-\(UUID().uuidString)")
        guard fm.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? fm.removeItem(at: probe)
        return true
    }

    /// `preferred` when this process can actually write there; otherwise a directory named
    /// `fallbackName` inside the sandbox's own temporary directory — the one writable
    /// location that is always available and deterministic given the bundle ID, so the
    /// suite stays green on a machine (or a Release build) with no scope granting the
    /// preferred path.
    public static func resolveOutputDirectory(preferred: URL, fallbackName: String) -> URL {
        canWrite(to: preferred) ? preferred
            : FileManager.default.temporaryDirectory.appendingPathComponent(fallbackName, isDirectory: true)
    }

    // MARK: - Geometry

    /// How far `documentFrame` sits from each edge of `clipBounds` — reusable regardless of
    /// which app's scroll view produced them.
    public static func centering(documentFrame: CGRect, clipBounds: CGRect) -> CenteringJSON {
        CenteringJSON(
            insetLeft: Double(documentFrame.minX - clipBounds.minX),
            insetRight: Double(clipBounds.maxX - documentFrame.maxX),
            insetTop: Double(clipBounds.maxY - documentFrame.maxY),
            insetBottom: Double(documentFrame.minY - clipBounds.minY)
        )
    }

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
    public static func inkMargins(in bitmap: NSBitmapImageRep, background: NSColor,
                                   viewSize: CGSize, tolerance: CGFloat = 0.06) -> InkMarginsPt? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let bg = background.usingColorSpace(.deviceRGB) else { return nil }
        let bgR = bg.redComponent, bgG = bg.greenComponent, bgB = bg.blueComponent

        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(c.redComponent - bgR) > tolerance
                || abs(c.greenComponent - bgG) > tolerance
                || abs(c.blueComponent - bgB) > tolerance
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
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSBitmapImageRep(cgImage: image)
    }

    // MARK: - PNG

    /// Writes the PNG and returns its size in bytes, so a geometry report can carry its own
    /// `ls -la`-equivalent even when it runs somewhere nothing outside the process can `ls`
    /// the result (a sandboxed host app, for instance).
    @discardableResult
    public static func renderPNG(view: NSView, appearance: NSAppearance, to url: URL) throws -> Int {
        try renderPNG(view: view, rect: view.bounds, appearance: appearance, to: url)
    }

    /// Same as `renderPNG(view:appearance:to:)`, but caches only `rect` (in `view`'s own
    /// coordinates) rather than the whole of `view.bounds`. `cacheDisplay(in:to:)` renders
    /// the receiver AND ITS SUBVIEWS clipped to `rect`, in real z-order — the one capture
    /// shape that reproduces a composited page (background paper + text subview + overlay
    /// subview all drawn by DIFFERENT views) rather than any single view's own drawing
    /// alone. See `NativeFidelityEvidenceTests` (job 425) for why a bare page `NSTextView`
    /// capture undercounts what a page actually shows: it has no paper/margins (painted by
    /// `PagedDocumentView.draw(_:)`), no running heads/feet (same), and nothing painted by
    /// `OversizedPassOverlayView` (a separate subview, added topmost).
    @discardableResult
    public static func renderPNG(view: NSView, rect: NSRect, appearance: NSAppearance, to url: URL) throws -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw RenderProbeError.cannotCreateBitmap
        }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: rect, to: bitmap)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderProbeError.cannotEncodePNG
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data.count
    }
}
