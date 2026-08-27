import AppKit
import CtrlKD
import Foundation
import PDFKit
// QuickLookThumbnailing vends QLThumbnailProvider/QLFileThumbnailRequest/QLThumbnailReply —
// the thumbnail-extension counterpart to QuickLookUI's preview types (see
// SoftReturnQuickLook/PreviewProvider.swift's doc comment on the same import trap for the
// preview extension point).
import QuickLookThumbnailing

/// The grid icon Finder shows before a person ever hits Space — a separate extension point
/// (`com.apple.quicklook.thumbnail`) from Quick Look's preview (`com.apple.quicklook.preview`,
/// `PreviewProvider.swift`), and the reason `QuickLookExtensionTests`' gauntlet thumbnail
/// check had nothing to resolve to before this target existed: without a registered thumbnail
/// provider, `QLThumbnailGenerator` falls back to a generic document glyph, which is not the
/// same defect as the preview spinner but reads the same way to a person looking at Finder.
///
/// Job 247 (b13, ql-native): draws page 1 of `QuickLookNativeRenderer`'s native rendering —
/// see that file's own doc comment for the ruling this satisfies. Same reasoning as
/// `PreviewProvider` (see that file's doc comment): one shared native derivation, so a
/// thumbnail can never disagree with what Quick Look's own preview, or the app's own window,
/// shows for the same file.
final class ThumbnailProvider: QLThumbnailProvider {
    enum ThumbnailError: Error {
        case noRenderablePage
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Browsing a folder in Finder's icon view asks every visible file for a thumbnail —
        // job-151 Part B's "browsing indexes the corpus" bet. Best-effort only, and fire-and-
        // forget on a background queue, so it cannot delay or fail this reply — same guarantee
        // as the old direct `SpotlightFileIndexer.requestIndex` call this replaces. Job 178:
        // this extension's sandbox has no `/usr/bin/mdimport` to spawn (proven on the b7
        // console), so it enqueues into the shared app-group container instead and lets the
        // app's own drain (which CAN spawn `mdimport`) do the actual indexing.
        SpotlightIndexQueue.enqueue(path: request.fileURL.path, category: "index-on-view")

        // `QuickLookNativeRenderer` is `@MainActor` (it builds real AppKit views); this
        // callback-based override is not `async`, so hop explicitly. Pulled out as plain
        // Sendable values (`URL`/`CGSize`) rather than capturing `request` itself, which
        // Swift 6 flags as unsafe to send into a main-actor-isolated closure.
        let fileURL = request.fileURL
        let maximumSize = request.maximumSize

        do {
            let bytes = [UInt8](try Data(contentsOf: fileURL))

            // Job 374 (QL-PIX): try the standalone-image reading FIRST — same content-first
            // dispatch and same `try?`-swallows-both-failure-kinds reasoning as
            // `PreviewProvider`'s own new branch (see that file's comment). No `MainActor`
            // hop, no `DispatchQueue.main.sync`: `QuickLookPixRenderer` never touches AppKit,
            // so there is no SE-0420 nesting trap (job 369) to mind in the first place — the
            // whole point of keeping this branch OUTSIDE the `DispatchQueue.main.sync` below.
            if let pix = try? QuickLookPixRenderer.thumbnailImage(
                fromFileBytes: bytes, maximumSize: maximumSize) {
                let reply = QLThumbnailReply(contextSize: pix.size) { context in
                    context.draw(pix.image, in: CGRect(origin: .zero, size: pix.size))
                    return true
                }
                handler(reply, nil)
                return
            }

            // Job 369: root cause of the spinner crash (job 367's crash-log trace —
            // `swift_task_isCurrentExecutorWithFlagsImpl` -> `dispatch_assert_queue_fail` on
            // QuickLookThumbnailing's own `connectionhandler.reply` queue, never main). Two
            // rounds of evidence, both via crash-report `slice_uuid` matched against this
            // build's own binary (`dwarfdump --uuid`) to rule out a stale registration:
            //   1. Original shape (`page.draw` inside the `drawing:` closure, itself nested
            //      inside `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`) —
            //      crashed at "closure #1 in closure #1 in closure #1 in provideThumbnail".
            //   2. First fix attempt: moved the `PDFPage` draw work out to a `CGImage`
            //      (`Sendable`) computed inside `assumeIsolated`, then built `QLThumbnailReply`
            //      AFTER that, but still lexically inside the SAME `DispatchQueue.main.async`
            //      closure — crashed identically ("closure #2 in closure #1"), proving the
            //      closure's inferred `@MainActor` isolation comes from LEXICAL NESTING inside
            //      that dispatched closure (SE-0420), not from what it captures.
            // Fix: `DispatchQueue.main.sync` (not `.async`) so the `CGImage`/`CGSize` result
            // returns synchronously into THIS function's own top-level, nonisolated stack frame
            // — the same frame QuickLookThumbnailing invoked `provideThumbnail` on. Building
            // `QLThumbnailReply` there, with no enclosing dispatched/MainActor closure at all,
            // is what actually breaks the inheritance chain. (Do not nest another bare
            // `assumeIsolated` inside `drawing:` itself — a documented spurious-trap bug on
            // dispatch-queue executors, swiftlang/swift#74626 — and don't rely on marking this
            // method `nonisolated` alone, per swiftlang/swift#75063's inference gaps; this
            // function is already nonisolated, called directly on QuickLookThumbnailing's own
            // background reply queue, which is what makes the `.sync` round-trip safe here.)
            let (image, thumbnailSize) = try DispatchQueue.main.sync {
                try MainActor.assumeIsolated { () throws -> (CGImage, CGSize) in
                    let rendered = try QuickLookNativeRenderer.renderedDocument(
                        fromFileBytes: bytes, docPath: fileURL.path)
                    let page = try QuickLookNativeRenderer.firstPage(for: rendered)
                    let pageBounds = page.bounds(for: .mediaBox)
                    guard pageBounds.width > 0, pageBounds.height > 0 else {
                        throw ThumbnailError.noRenderablePage
                    }

                    // Fit within the requested size, aspect preserved, but never past
                    // `maxDimension` regardless of how large `maximumSize` asks for — Finder
                    // never actually shows a THUMBNAIL representation anywhere near this
                    // large (the preview panel's own extension point, `.preview`/
                    // `SoftReturnQuickLook`, is what serves full-size views). Capping our OWN
                    // output is the documented, accepted pattern regardless of what a caller
                    // asks for: QuickLookUI scales a smaller-than-requested thumbnail up
                    // rather than showing nothing.
                    let maxDimension: CGFloat = 1024
                    let requestedSize = CGSize(
                        width: min(maximumSize.width, maxDimension),
                        height: min(maximumSize.height, maxDimension))
                    let scale = min(requestedSize.width / pageBounds.width,
                                    requestedSize.height / pageBounds.height)
                    let thumbnailSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

                    guard let bitmapContext = CGContext(
                        data: nil,
                        width: max(1, Int(thumbnailSize.width.rounded(.up))),
                        height: max(1, Int(thumbnailSize.height.rounded(.up))),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else {
                        throw ThumbnailError.noRenderablePage
                    }
                    // PAPER IS WHITE — same reasoning as `PagedDocumentView.draw(_:)`: a
                    // page with any transparent region must not pick up Finder's own
                    // background.
                    bitmapContext.setFillColor(NSColor.white.cgColor)
                    bitmapContext.fill(CGRect(origin: .zero, size: thumbnailSize))
                    bitmapContext.scaleBy(x: scale, y: scale)
                    // Our own bitmap context, origin bottom-left — the same convention
                    // `PDFPage.draw(with:to:)` expects, no extra flip.
                    page.draw(with: .mediaBox, to: bitmapContext)
                    guard let image = bitmapContext.makeImage() else {
                        throw ThumbnailError.noRenderablePage
                    }
                    return (image, thumbnailSize)
                }
            }

            // Built here, in `provideThumbnail`'s own top-level frame — no enclosing
            // `DispatchQueue`/`assumeIsolated` closure — so `drawing:`'s inferred isolation
            // stays nonisolated, matching the background queue QuickLookThumbnailing actually
            // calls it from.
            let reply = QLThumbnailReply(contextSize: thumbnailSize) { context in
                // `CGContext.draw(_:in:)` round-trips a bitmap-context-derived `CGImage`
                // correctly on its own — no manual axis flip needed.
                context.draw(image, in: CGRect(origin: .zero, size: thumbnailSize))
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
