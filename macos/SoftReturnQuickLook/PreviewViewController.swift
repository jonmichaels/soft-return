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
/// page 1 on screen as an image, its top at the view's top, with the thumbnail column beside it, and appends each later
/// page and its thumbnail as it is drawn, without moving or redrawing anything shown (batch 45, M24). Quick Look is told
/// the preview is ready once page 1 is in. A `.PIX` picture shows as its image.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var preview: QuickLookProgressivePreview?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        // Batch 47 (M29): a Letter page beside the thumbnail column, so a window opened from this frame shows one page.
        view = NSView(frame: NSRect(origin: .zero, size: QuickLookProgressivePreview.defaultContentSize))
        preferredContentSize = QuickLookProgressivePreview.defaultContentSize
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
        // Batch 47 (M28a): the whole picture, fitted (`QuickLookPictureView`).
        if let picture = QuickLookPictureView.preview(fromFileBytes: bytes) {
            pin(picture.view)
            preferredContentSize = picture.size
            handler(nil)
            return
        }
        let preview = QuickLookProgressivePreview()
        self.preview = preview
        pin(preview.view)
        preview.load(bytes: bytes, docPath: url.path,
                     pageSettingsPreset: QuickLookPageSettingsPreference.resolvedDefault(),
                     quirks: QuickLookPageSettingsPreference.resolvedQuirkDefaults()) { [weak self] error in
            if error == nil, let size = self?.preview?.preferredContentSize, size != .zero {
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
