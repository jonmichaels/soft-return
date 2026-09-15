import AppKit
import CtrlKD
import SoftReturnShared
import PDFKit

/// Job 247 (b13, ql-native) — MAC VIEWING RULING (decision register 2026-08-11, restated and
/// binding): "EVERY Mac viewing surface renders natively with the MAC font mapping." Jon on
/// the old design, which had QuickLook call straight through `emitPDF`: "I never agreed to
/// [QL = engine PDF]." Engine PDF (`emitPDF`) is CLI/export output ONLY from this job forward
/// — every Mac VIEWING surface, including Quick Look's spacebar preview and Finder's grid
/// thumbnail, goes through the SAME native pipeline the app's own document window uses
/// (`DocumentRenderer` -> `PagedDocumentView`/`PageTextView`), so a WS7 file with
/// Univers/Aachen-mapped fonts, real vector box-drawing, and jobs 224/227/240/246's own
/// overprint/oversized-pass compositing looks the SAME everywhere on this Mac — not degraded
/// to PDF's base-14 floor the moment a person leaves the app window (registry #25's own law:
/// a parity/oracle gate must never import the REFERENCE's rendering limitations into the
/// product; the old QL-via-`emitPDF` design did exactly that, silently, for five betas).
///
/// One file, mirrored VERBATIM into three targets (`Project.swift`'s `sources`, the same "an
/// appex can't import the app module, so Tuist compiles the same source path into every
/// target that needs it" pattern `SpotlightFileIndexer.swift`/`DocumentOperations.swift`
/// already use here): `SoftReturn` (covered by its own `SoftReturn/**` glob — the app itself
/// has no caller, but nothing stops it compiling there too), `SoftReturnQuickLook`,
/// `SoftReturnThumbnail`. This is deliberately the ONLY place either appex builds a
/// `DocumentState`/`PagedDocumentView` — see `PreviewProvider`/`ThumbnailProvider`'s own doc
/// comments for why two independent derivations of "what does this document look like" is
/// exactly the defect this job exists to remove (the OLD `PreviewProvider`'s own doc comment
/// made this same "one derivation" argument for calling `emitPDF` — the ruling changes WHICH
/// one derivation is correct, not whether there should be one).
///
/// ## Rendering without a window
/// `PagedDocumentView` is never added to an `NSWindow` here — proven safe first, not assumed
/// (`ZZProbeJob247QLRender.swift.unused`, kept as the positive-control record, field-notes'
/// "an instrument that has only ever returned one answer is untested" discipline): a
/// windowless, laid-out `PagedDocumentView` still produces real glyph content through
/// `NSView.dataWithPDF(inside:)` — the same AppKit primitive `NSPrintOperation`'s own PDF
/// output is built on, and the same "print/PDF representation" family (`bitmapImageRep
/// ForCachingDisplay`/`cacheDisplay(in:to:)`) every screenshot probe in this repo already
/// trusts for offscreen rendering, just never previously asked to work with no window at all.
/// An appex has no license to put a real window on screen anyway, and none is needed for
/// either the multi-page Preview PDF or a single-page thumbnail — both are pure offscreen
/// rendering, `layoutSubtreeIfNeeded()` plus a direct view-to-PDF call.
@MainActor
enum QuickLookNativeRenderer {
    enum RenderError: Error {
        case emptyDocument
    }

    /// Parse `bytes` and lay them out through the SAME `DocumentState`/`DocumentRenderer`
    /// pipeline the app's own document window renders — Native style (per the spec: "a
    /// preview should look like the paper"), with job 203's app-group Page Settings default
    /// applied the same one-shot way the footer's own control applies it
    /// (`DocumentState.setPageSettingsPreset` -> `DocumentRenderer.renderNative`'s own
    /// `effectivePage` channel), so a preview/thumbnail can never disagree with what the app's
    /// bottom-bar control would show for the same file under the same default.
    ///
    /// A fresh, isolated `SettingsStore` backed by an ephemeral defaults suite — an extension
    /// has no reason to read or write the app's own nine preferences, and a document-scoped
    /// render must not depend on whatever style/zoom/display a person last left the real app
    /// window in.
    ///
    /// `pageSettingsPreset` defaults to reading the real app-group container
    /// (`QuickLookPageSettingsPreference.resolvedDefault()`, evaluated fresh per call, exactly
    /// what `PreviewProvider`/`ThumbnailProvider`'s real call sites get) — a caller that needs
    /// a DETERMINISTIC render regardless of whatever this machine's real shared container
    /// happens to hold (`QLNativeParityTests`' own gate) passes `nil` explicitly, which means
    /// exactly what an absent/unrecognized container key already means: no override.
    static func renderedDocument(
        fromFileBytes bytes: [UInt8],
        docPath: String = "",
        pageSettingsPreset: DocumentOperations.PageSettingsPreset? = QuickLookPageSettingsPreference
            .resolvedDefault()
    ) throws -> RenderedDocument {
        // Job 306 (b18): this appex's own registration of the bundled Courier Prime faces —
        // see `CourierPrimeFontRegistration`'s own doc comment for why QL/Thumbnail each need
        // their own call, not just the host app's.
        CourierPrimeFontRegistration.registerIfNeeded()
        let ephemeralDefaults = UserDefaults(suiteName: "QuickLookNativeRenderer.\(UUID().uuidString)")
            ?? UserDefaults.standard
        let settings = SettingsStore(defaults: ephemeralDefaults)
        // Job 371 item 1 (PIX IN VIEWS): `docPath` so `.PIX` tags resolve against the real
        // file — a QL preview/thumbnail always has one (`request.fileURL`), unlike a
        // synthetic/test render.
        let state = try DocumentState(data: bytes, settings: settings, docPath: docPath)
        // Native, not the new Printed(PDFKit) meaning — job 265's own "QL stays native"
        // instruction: this appex keeps rendering through the SAME AppKit pipeline it always
        // has, per the mac-viewing ruling above, never the engine's `emitPDF` bytes.
        state.style.setManually(.native)
        if let pageSettingsPreset {
            state.setPageSettingsPreset(pageSettingsPreset)
        }
        return DocumentRenderer.render(state, style: .native)
    }

    /// A `PagedDocumentView` carrying `rendered`'s full page chain, laid out and ready to
    /// draw — Continuous Scroll, so every page has a real, addressable `rect(ofPage:)`
    /// (Single Page only positions the CURRENT page). Never added to a window — see this
    /// type's own doc comment.
    private static func layoutPagedView(_ rendered: RenderedDocument) -> PagedDocumentView {
        let pagedView = PagedDocumentView(frame: .zero)
        pagedView.setContent(rendered, display: .continuousScroll)
        pagedView.setFrameSize(pagedView.intrinsicContentSize)
        pagedView.layoutSubtreeIfNeeded()
        return pagedView
    }

    /// The multi-page Preview PDF — pages of the NATIVE renderer's own drawing, not
    /// `emitPDF`. Each page is captured on its own (`dataWithPDF(inside:)` for that page's rect
    /// alone, `capturingPageIndex` naming it) and written straight into ONE PDF context, then let
    /// go (`autoreleasepool`) — never every page's rendering live at once, the appex memory ceiling
    /// this job's brief calls out. The page CHAIN itself (`layoutPagedView`'s `NSTextView`s) still
    /// builds every page up front — an inherent property of the one-`NSTextStorage`
    /// cross-page-selection architecture `PagedDocumentView`'s own doc comment explains.
    ///
    /// Batch 28 (#271 M10): written into a `CGContext` PDF as each page is captured. Until then each
    /// page's PDF was opened by PDFKit and its page inserted into one `PDFDocument`, whose
    /// `dataRepresentation` wrote them out at the end: every one-page document stayed alive until
    /// then, and the join cost -HOLYMAC.WS 1.4 s and most of a 245 MB peak (b28-ql-measure).
    /// `QuickLookRequestIdentityTests` compares every page's pixels with that join.
    static func multiPagePDF(for rendered: RenderedDocument) throws -> Data {
        let pagedView = layoutPagedView(rendered)
        guard pagedView.pageCount > 0 else { throw RenderError.emptyDocument }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw RenderError.emptyDocument
        }
        var pagesWritten = 0
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            autoreleasepool {
                pagedView.capturingPageIndex = index
                let onePageData = pagedView.dataWithPDF(inside: rect)
                pagedView.capturingPageIndex = nil
                guard let provider = CGDataProvider(data: onePageData as CFData),
                      let onePage = CGPDFDocument(provider)?.page(at: 1) else { return }
                var mediaBox = onePage.getBoxRect(.mediaBox)
                context.beginPage(mediaBox: &mediaBox)
                context.drawPDFPage(onePage)
                context.endPage()
                pagesWritten += 1
            }
        }
        context.closePDF()
        guard pagesWritten > 0 else { throw RenderError.emptyDocument }
        return output as Data
    }

    /// Page 1 alone, as a `PDFPage` — the Thumbnail extension's own need (Finder's grid icon
    /// is always page 1, per the spec) and reusable by verification code to pixel-compare a
    /// single page without paying for the whole document's PDF assembly.
    static func firstPage(for rendered: RenderedDocument) throws -> PDFPage {
        let pagedView = layoutPagedView(rendered)
        guard pagedView.pageCount > 0 else { throw RenderError.emptyDocument }
        let rect = pagedView.rect(ofPage: 0)
        guard rect.width > 0, rect.height > 0 else { throw RenderError.emptyDocument }
        let data = pagedView.dataWithPDF(inside: rect)
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
            throw RenderError.emptyDocument
        }
        return page
    }

    // MARK: - The two extensions' requests (batch 28, #271 M10)

    /// `PreviewProvider`'s reply for a WordStar document: every page as one PDF, and the page size Quick Look lays
    /// its window out around. The engine's half is `work`, made before this is called — off the main thread, by the
    /// extension; the text, the layout and the PDF are made here.
    static func previewPDF(for work: QuickLookEngineWork) throws -> (pdf: Data, pageSize: CGSize) {
        let rendered = QuickLookRender.whole(for: work)
        return (try multiPagePDF(for: rendered), rendered.pageSize)
    }

    /// `previewPDF(for:)` with the engine's half made here too, on the caller's thread — one call for
    /// `QuickLookTimingTests` and `QuickLookRequestIdentityTests`.
    static func previewPDF(
        fromFileBytes bytes: [UInt8],
        docPath: String,
        pageSettingsPreset: DocumentOperations.PageSettingsPreset? = QuickLookPageSettingsPreference
            .resolvedDefault()
    ) throws -> (pdf: Data, pageSize: CGSize) {
        try previewPDF(for: try QuickLookEngineWork.make(bytes: bytes, docPath: docPath,
                                                         pageSettingsPreset: pageSettingsPreset))
    }

    /// `ThumbnailProvider`'s drawing for a WordStar document: page 1, fitted to `maximumSize` and never larger than
    /// `maxDimension`, on white.
    ///
    /// Page 1 ONLY. The engine paginated the whole document (`work`), but the session builds page 1's text and one
    /// page is laid out — a thumbnail never builds a long document's other pages (b28-ql-measure: -HOLYMAC.WS spent
    /// 2.0 s on the text and 0.7 s on the layout of 302 pages to draw one). `QuickLookRequestIdentityTests` compares
    /// every byte with the thumbnail of the whole render's page 1.
    static func thumbnail(for work: QuickLookEngineWork, maximumSize: CGSize) throws -> (image: CGImage, size: CGSize) {
        return try thumbnailImage(of: try firstPage(for: QuickLookRender.pageOne(for: work)), maximumSize: maximumSize)
    }

    /// `thumbnail(for:maximumSize:)` with the engine's half made here too — for the tests, as `previewPDF`'s.
    static func thumbnail(
        fromFileBytes bytes: [UInt8],
        docPath: String,
        maximumSize: CGSize,
        pageSettingsPreset: DocumentOperations.PageSettingsPreset? = QuickLookPageSettingsPreference
            .resolvedDefault()
    ) throws -> (image: CGImage, size: CGSize) {
        try thumbnail(for: try QuickLookEngineWork.make(bytes: bytes, docPath: docPath,
                                                        pageSettingsPreset: pageSettingsPreset),
                      maximumSize: maximumSize)
    }

    /// A page drawn as a thumbnail: fitted to `maximumSize`, capped at `maxDimension`, on white.
    static func thumbnailImage(of page: PDFPage, maximumSize: CGSize) throws -> (image: CGImage, size: CGSize) {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            throw RenderError.emptyDocument
        }

        // Fit within the requested size, aspect preserved, but never past `maxDimension`
        // regardless of how large `maximumSize` asks for — Finder never actually shows a
        // THUMBNAIL representation anywhere near this large (the preview panel's own extension
        // point, `.preview`/`SoftReturnQuickLook`, is what serves full-size views). Capping our
        // OWN output is the documented, accepted pattern regardless of what a caller asks for:
        // QuickLookUI scales a smaller-than-requested thumbnail up rather than showing nothing.
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
            throw RenderError.emptyDocument
        }
        // PAPER IS WHITE — same reasoning as `PagedDocumentView.draw(_:)`: a page with any
        // transparent region must not pick up Finder's own background.
        bitmapContext.setFillColor(NSColor.white.cgColor)
        bitmapContext.fill(CGRect(origin: .zero, size: thumbnailSize))
        bitmapContext.scaleBy(x: scale, y: scale)
        // Our own bitmap context, origin bottom-left — the same convention
        // `PDFPage.draw(with:to:)` expects, no extra flip.
        page.draw(with: .mediaBox, to: bitmapContext)
        guard let image = bitmapContext.makeImage() else {
            throw RenderError.emptyDocument
        }
        return (image, thumbnailSize)
    }
}
