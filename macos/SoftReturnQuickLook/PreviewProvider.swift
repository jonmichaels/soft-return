import AppKit
import CtrlKD
import Foundation
import PDFKit
// QuickLookUI, not QuickLook: on macOS the preview-extension types (QLPreviewProvider,
// QLPreviewReply, QLFilePreviewRequest) are vended by QuickLookUI. Importing QuickLook
// compiles the file and then fails to find any of them.
import QuickLookUI
import UniformTypeIdentifiers

/// Spacebar in the Finder shows the document, as a page.
///
/// Job 247 (b13, ql-native): renders through the SAME native pipeline the app's own document
/// window uses (`QuickLookNativeRenderer` -> `DocumentRenderer`/`PagedDocumentView` — see
/// that file's own doc comment for the ruling this satisfies and why it is the one shared
/// derivation, not two). Until this job, this method called straight through the library's
/// `emitPDF` instead — Jon's ruling (2026-08-11 register): "I never agreed to [QL = engine
/// PDF]." Engine PDF is CLI/export output only; every Mac viewing surface, spacebar preview
/// included, shows the Mac-font-mapped, vector-box-drawn, overprint/oversized-pass-composited
/// native rendering, exactly as the app's own window would show the same file.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    // Not `@MainActor`: the protocol requirement is isolation-agnostic, and its own
    // parameter/return types (`QLFilePreviewRequest`/`QLPreviewReply`) are non-Sendable, so
    // pinning the whole method to the main actor makes them uncrossable at the boundary the
    // conformance itself creates. `QuickLookNativeRenderer`'s calls are themselves
    // `@MainActor` (they build real AppKit views); `MainActor.run` below hops onto it for
    // exactly that work, then hops back to build the reply from plain `Data`/`CGSize`.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Spacebar-preview as an index trigger — job-151 Part B, same call and same
        // never-affects-the-result guarantee as `SoftReturnThumbnail/ThumbnailProvider.swift`.
        // Job 178: enqueues into the shared app-group container rather than requesting
        // indexing directly — see that file's updated comment for why.
        SpotlightIndexQueue.enqueue(path: request.fileURL.path, category: "index-on-view")

        // Detection is content-based — names and extensions lie about WordStar-era files,
        // which is the whole premise of this project.
        let bytes = [UInt8](try Data(contentsOf: request.fileURL))
        let docPath = request.fileURL.path

        // Job 374 (QL-PIX): try the standalone-image reading FIRST, same content-first
        // posture as the WordStar path below — `QLSupportedContentTypes` now offers both
        // UTIs (Info.plist), so a request here may be either kind, and a real `.PIX`'s own
        // index table either parses or it doesn't (`try?` swallows both "not a PIX at all"
        // and "a malformed/unsupported PIX" the same way; the latter falls through to the
        // WordStar parse below, which fails with ITS OWN, equally honest error). No
        // `MainActor` hop needed here at all — see `QuickLookPixRenderer`'s own doc comment.
        if let pix = try? QuickLookPixRenderer.renderedPix(fromFileBytes: bytes) {
            return QLPreviewReply(dataOfContentType: .png, contentSize: pix.sizeInPoints) { _ in
                pix.png
            }
        }

        let (pdf, pageSize) = try await MainActor.run { () throws -> (Data, CGSize) in
            let rendered = try QuickLookNativeRenderer.renderedDocument(
                fromFileBytes: bytes, docPath: docPath)
            let pdf = try QuickLookNativeRenderer.multiPagePDF(for: rendered)
            return (pdf, rendered.pageSize)
        }

        // `.zero` told QuickLookUI the preview has no intrinsic size to lay a window out
        // around, which is the prime suspect for the eternal spinner Jon saw: nothing was
        // ever a WRONG size, there was simply nothing for the previewing UI to size itself
        // to before content arrived. `pageSize` is the same page geometry `multiPagePDF`
        // just drew, not a value recomputed separately that could drift from what the reply
        // actually contains.
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: pageSize) { _ in
            pdf
        }
    }
}
