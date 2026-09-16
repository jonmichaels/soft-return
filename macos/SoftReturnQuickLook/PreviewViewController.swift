import AppKit
import CtrlKD
import Foundation
// QuickLookUI, not QuickLook: on macOS the preview-extension types are vended by QuickLookUI.
import QuickLookUI
import SoftReturnShared

/// Spacebar in the Finder shows the document, as pages (batch 40, M11: a view-based preview).
///
/// The pages are the NATIVE renderer's own drawing — the same pipeline the app's document window uses (job 247,
/// Jon's 2026-08-11 ruling: "I never agreed to [QL = engine PDF]") — shown by `QuickLookProgressivePreview`, which puts
/// page 1 on screen as soon as it is made and appends the rest. Quick Look is told the preview is ready once page 1
/// is in. A `.PIX` picture shows as its image.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var preview: QuickLookProgressivePreview?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable ((any Error)?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.prepare(url, handler: handler)
            }
        }
    }

    private func prepare(_ url: URL, handler: @escaping @Sendable ((any Error)?) -> Void) {
        // Spacebar-preview as an index trigger, as the thumbnail's (job-151 Part B; job 178's shared queue).
        SpotlightIndexQueue.enqueue(path: url.path, category: "index-on-view")
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            handler(error)
            return
        }
        // Detection is content-based — names and extensions lie about WordStar-era files. A real `.PIX` parses as a
        // picture; anything else goes to the WordStar reading, which fails with its own error.
        if let pix = try? QuickLookPixRenderer.renderedPix(fromFileBytes: bytes), let image = NSImage(data: pix.png) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            pin(imageView)
            preferredContentSize = pix.sizeInPoints
            handler(nil)
            return
        }
        let preview = QuickLookProgressivePreview()
        self.preview = preview
        pin(preview.view)
        preview.load(bytes: bytes, docPath: url.path,
                     pageSettingsPreset: QuickLookPageSettingsPreference.resolvedDefault()) { [weak self] error in
            if error == nil, let size = self?.preview?.pageSize, size != .zero {
                self?.preferredContentSize = size
            }
            handler(error)
        }
    }

    private func pin(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
