import AppKit
import SoftReturnShared

/// Batch 47 (M28a, Jon: Quick Look on a `.PIX` showed a zoomed-in part of the picture): the spacebar preview of a WordStar
/// picture — the whole image, fitted to the view and centred, at every size Quick Look gives the view.
///
/// It was an `NSImageView` pinned edge to edge: an image view's intrinsic content size is its image's, which for a
/// decoded `.PIX` (its pixels at 72 dpi) is far larger than the preview, and Auto Layout sized to that instead of the
/// window. This view has no intrinsic size and draws the picture aspect-fit into its own bounds.
/// Compiled into the app (for its tests) and the Quick Look extension.
final class QuickLookPictureView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var isFlipped: Bool { true }

    /// Where the picture is drawn: its whole shape, as large as fits in `bounds`, centred.
    var pictureRect: NSRect { Self.fitted(image.size, in: bounds) }

    static func fitted(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        image.draw(in: pictureRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    /// The preview for a `.PIX`'s bytes — the view and the size Quick Look should open its window at — or nil when the
    /// bytes are not a picture.
    static func preview(fromFileBytes bytes: [UInt8]) -> (view: QuickLookPictureView, size: CGSize)? {
        guard let pix = try? QuickLookPixRenderer.renderedPix(fromFileBytes: bytes), let image = NSImage(data: pix.png)
        else { return nil }
        image.size = pix.sizeInPoints
        return (QuickLookPictureView(image: image), pix.sizeInPoints)
    }
}
