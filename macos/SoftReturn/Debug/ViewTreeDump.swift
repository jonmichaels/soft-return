#if DEBUG
import AppKit

/// A JSON snapshot of the real view hierarchy, written to a file.
///
/// This exists because of a specific failure: a document window that opened, titled itself
/// correctly, and populated its bottom bar from the parsed document — while the page area
/// stayed blank. Every test passed, because every test asked the model whether it was right
/// and never asked the views what they actually were. From outside the process the two are
/// indistinguishable; from in here, one `frame` tells you immediately.
///
/// So the dump records what a screenshot cannot: the frame each view ACTUALLY got, whether
/// it is hidden, whether it is in a window at all, and — for text views — whether the layout
/// manager placed any glyphs in it. A view with the right content and a zero frame looks
/// exactly like a view with no content, until you can see both numbers.
///
/// DEBUG-only and file-based on purpose: it is meant to be read after the fact, next to the
/// screenshot of the same moment, without a debugger attached to a GUI-session process.
@MainActor
enum ViewTreeDump {
    /// Where dumps land unless a caller says otherwise. `NSTemporaryDirectory` rather than a
    /// path in the repo — a dump is evidence about one run, not a build product.
    static func defaultURL(name: String = "view-tree") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("softreturn-\(name).json")
    }

    /// Dump every window, or one window if given.
    ///
    /// Returns the URL written so a caller (a test, or the menu item) can report it. Throws
    /// nothing: a diagnostic that can fail the thing it is diagnosing is worse than useless,
    /// so a write failure is logged and swallowed.
    @discardableResult
    static func write(window: NSWindow? = nil, to url: URL? = nil) -> URL {
        let destination = url ?? defaultURL()
        let windows = window.map { [$0] } ?? NSApp.windows

        let payload: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "windows": windows.map(describe(window:)),
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
            NSLog("[SoftReturn] view tree written to %@", destination.path)
        } catch {
            NSLog("[SoftReturn] view tree dump FAILED: %@", String(describing: error))
        }
        return destination
    }

    /// Render a window's content view to a PNG from inside the process.
    ///
    /// This answers a question a screenshot cannot: is the view hierarchy DRAWING and being
    /// hidden by something at the window/compositing level, or is it not drawing at all?
    /// `cacheDisplay` runs the same `draw(_:)` calls into an offscreen bitmap with no window
    /// server involved, so if this PNG has content and the screenshot does not, the bug is
    /// compositing; if both are blank, the bug is in the drawing code itself.
    @discardableResult
    static func writeRender(window: NSWindow?, to url: URL? = nil) -> URL? {
        guard let view = window?.contentView else {
            NSLog("[SoftReturn] render dump: no content view")
            return nil
        }
        let destination = url ?? defaultURL(name: "render").deletingPathExtension()
            .appendingPathExtension("png")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[SoftReturn] render dump: could not make a bitmap rep")
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("[SoftReturn] render dump: PNG encoding failed")
            return nil
        }
        do {
            try data.write(to: destination)
            NSLog("[SoftReturn] render written to %@ (%dx%d)",
                  destination.path, rep.pixelsWide, rep.pixelsHigh)
        } catch {
            NSLog("[SoftReturn] render dump FAILED: %@", String(describing: error))
            return nil
        }
        return destination
    }

    private static func describe(window: NSWindow) -> [String: Any] {
        var out: [String: Any] = [
            "title": window.title,
            "frame": rect(window.frame),
            "isVisible": window.isVisible,
            "isKey": window.isKeyWindow,
            "class": String(describing: type(of: window)),
        ]
        // A window whose contentView is nil is a different bug from one whose contentView is
        // empty, and the difference is invisible on screen.
        if let content = window.contentView {
            out["contentView"] = describe(view: content, depth: 0)
        } else {
            out["contentView"] = NSNull()
        }
        return out
    }

    /// One view and its subtree.
    ///
    /// `depth` is carried so a runaway hierarchy cannot produce an unbounded recursion in a
    /// diagnostic; 40 is far past any real AppKit tree.
    private static func describe(view: NSView, depth: Int) -> [String: Any] {
        var out: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": rect(view.frame),
            "bounds": rect(view.bounds),
            "hidden": view.isHidden,
            // The frame is meaningless if the view was never added to a window.
            "inWindow": view.window != nil,
            "alpha": view.alphaValue,
        ]
        let identifier = view.accessibilityIdentifier()
        if !identifier.isEmpty {
            out["identifier"] = identifier
        }
        // Zero-area views are the single most common cause of "it renders in the test and
        // not on screen", so flag them rather than making the reader do the arithmetic.
        if view.frame.width == 0 || view.frame.height == 0 {
            out["ZERO_SIZE"] = true
        }

        if let scroll = view as? NSScrollView {
            out["magnification"] = scroll.magnification
            out["documentVisibleRect"] = rect(scroll.documentVisibleRect)
            out["hasDocumentView"] = scroll.documentView != nil
        }
        if let text = view as? NSTextView {
            out["text"] = describe(textView: text)
        }

        if depth < 40, !view.subviews.isEmpty {
            out["subviews"] = view.subviews.map { describe(view: $0, depth: depth + 1) }
        }
        return out
    }

    /// What a text view is actually showing — the string it holds AND, separately, whether
    /// the layout manager put any glyphs into its container.
    ///
    /// The two are not the same, and the gap between them is a real failure mode: a text
    /// view can hold the whole document and still display nothing, because its container was
    /// sized to zero or the glyphs all went to a different container in the chain.
    private static func describe(textView view: NSTextView) -> [String: Any] {
        let full = view.string
        let prefix = String(full.prefix(80))
        var out: [String: Any] = [
            "characterCount": full.count,
            "first80": prefix,
        ]
        guard let manager = view.layoutManager, let container = view.textContainer else {
            out["layoutManager"] = NSNull()
            return out
        }
        let glyphs = manager.glyphRange(for: container)
        out["glyphRangeInContainer"] = ["location": glyphs.location, "length": glyphs.length]
        out["totalGlyphsInLayoutManager"] = manager.numberOfGlyphs
        out["containerSize"] = size(container.size)
        out["usedRect"] = rect(manager.usedRect(for: container))
        // The payoff line: laid out but invisible, or simply empty?
        out["RENDERS_NOTHING"] = glyphs.length == 0
        return out
    }

    // MARK: - Value formatting

    private static func rect(_ r: CGRect) -> [String: CGFloat] {
        ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
    }

    private static func size(_ s: CGSize) -> [String: CGFloat] {
        ["w": s.width, "h": s.height]
    }
}
#endif
