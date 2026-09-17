import AppKit
import SoftReturnShared

/// Batch 47 (M28b, Jon: Soft Return claims the WordStar picture on the Mac, as it does on the iPhone): a standalone `.PIX`
/// opens in a window of its own, showing the whole picture fitted — the same view the spacebar preview draws it with
/// (`QuickLookPictureView`). A viewer, as every Soft Return document is: it never writes the file.
final class PixDocument: NSDocument {
    private(set) var picture: (image: NSImage, size: CGSize)?

    override class var autosavesInPlace: Bool { false }

    /// The window's content size: the picture at its own size, no larger than 80% of the screen's visible frame.
    static func windowSize(for picture: CGSize, screen: NSRect?) -> CGSize {
        let limit = screen.map { CGSize(width: $0.width * 0.8, height: $0.height * 0.8) } ?? CGSize(width: 1000, height: 800)
        let scale = min(1, limit.width / max(picture.width, 1), limit.height / max(picture.height, 1))
        return CGSize(width: (picture.width * scale).rounded(), height: (picture.height * scale).rounded())
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        try MainActor.assumeIsolated {
            guard let preview = QuickLookPictureView.preview(fromFileBytes: bytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            picture = (preview.view.image, preview.size)
        }
    }

    override func makeWindowControllers() {
        guard let picture else { return }
        let size = Self.windowSize(for: picture.size, screen: NSScreen.main?.visibleFrame)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = QuickLookPictureView(image: picture.image)
        window.contentAspectRatio = picture.size
        window.setAccessibilityIdentifier("pix-document-window")
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    /// A viewer never writes back over what it opened.
    override func write(to url: URL, ofType typeName: String) throws {
        throw CocoaError(.featureUnsupported)
    }
}
