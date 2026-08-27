import AppKit
import CtrlKD
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
    /// pipeline the app's own document window renders — Printed style (per the spec: "a
    /// preview should look like the paper"), with job 203's app-group Page Settings default
    /// applied the same one-shot way the footer's own control applies it
    /// (`DocumentState.setPageSettingsPreset` -> `DocumentRenderer.renderPrinted`'s own
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
        return DocumentRenderer.render(state, style: .printed)
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
    /// `emitPDF`. Serializes one page at a time (`dataWithPDF(inside:)` for that page's own
    /// rect alone, immediately folded into `combined` and discarded via `autoreleasepool`)
    /// rather than holding every page's rendering live at once — the appex memory ceiling
    /// this job's brief calls out. The page CHAIN itself (`layoutPagedView`'s `NSTextView`s)
    /// still builds every page up front — an inherent property of the one-`NSTextStorage`
    /// cross-page-selection architecture `PagedDocumentView`'s own doc comment explains, not
    /// something this function can avoid without a second, divergent renderer — but that
    /// object graph is far cheaper than N rasterized/PDF-serialized pages, which is the
    /// actual memory cost this function avoids paying all at once.
    static func multiPagePDF(for rendered: RenderedDocument) throws -> Data {
        let pagedView = layoutPagedView(rendered)
        guard pagedView.pageCount > 0 else { throw RenderError.emptyDocument }

        let combined = PDFDocument()
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            autoreleasepool {
                let onePageData = pagedView.dataWithPDF(inside: rect)
                if let onePagePDF = PDFDocument(data: onePageData), let page = onePagePDF.page(at: 0) {
                    combined.insert(page, at: combined.pageCount)
                }
            }
        }
        guard combined.pageCount > 0, let data = combined.dataRepresentation() else {
            throw RenderError.emptyDocument
        }
        return data
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
}

/// Job 374 (QL-PIX): standalone `.PIX` images, mirrored into the same three targets as
/// `QuickLookNativeRenderer` above (Project.swift's `sources` list — see that type's own
/// doc comment for the mirroring mechanism). Deliberately its OWN enum, not folded into
/// `QuickLookNativeRenderer`: a `.PIX` is a raw raster image, not a `DocumentState`/
/// `PagedDocumentView` document, so it has no `RenderedDocument` to produce and needs no
/// `@MainActor` at all — `CtrlKD.pixDecode`/`pixToPNG` are plain, Foundation-free, actor-
/// agnostic functions (see `Pix.swift`'s own header), and `CGImage`/`CGContext` construction
/// below needs no AppKit view or window. That absence of any actor hop is itself how this
/// type "minds job 369's SE-0420 lesson": there is no dispatched/MainActor closure for a
/// reply to end up nested inside in the first place.
enum QuickLookPixRenderer {
    enum RenderError: Error {
        case emptyImage
    }

    /// The Preview extension's shape: PNG bytes (`CtrlKD.pixToPNG`, already validated against
    /// real Inset renders — see `Pix.swift`) plus the size QuickLookUI should lay its preview
    /// window out around. Physical size (`pixPhysicalSizeIn`'s decipoints-derived inches, *72
    /// for points) when the file's own print-options record carries one — the same size
    /// `DocumentPictures`/`ExportAccessoryView` already trust for an EMBEDDED `.PIX`'s point
    /// size — falling back to the raw pixel dimensions 1:1 when it doesn't (no worse a
    /// default than what an untagged image would get anywhere else).
    struct RenderedPix {
        let png: Data
        let sizeInPoints: CGSize
    }

    static func renderedPix(fromFileBytes bytes: [UInt8]) throws -> RenderedPix {
        let (width, height, _) = try pixDecode(bytes)
        guard width > 0, height > 0 else { throw RenderError.emptyImage }
        let png = try Data(pixToPNG(bytes))
        let sizeInPoints: CGSize
        if let physical = pixPhysicalSizeIn(bytes) {
            sizeInPoints = CGSize(width: physical.widthIn * 72, height: physical.heightIn * 72)
        } else {
            sizeInPoints = CGSize(width: width, height: height)
        }
        return RenderedPix(png: png, sizeInPoints: sizeInPoints)
    }

    /// The Thumbnail extension's shape: a `CGImage` already scaled to fit `maximumSize` (never
    /// past `maxDimension`, same reasoning and same cap `ThumbnailProvider`'s WordStar path
    /// already applies to its own `PDFPage`) plus that scaled size, ready to hand straight to
    /// `QLThumbnailReply`'s `contextSize`/`drawing:`.
    static func thumbnailImage(
        fromFileBytes bytes: [UInt8], maximumSize: CGSize, maxDimension: CGFloat = 1024
    ) throws -> (image: CGImage, size: CGSize) {
        let (width, height, rgbRows) = try pixDecode(bytes)
        guard width > 0, height > 0 else { throw RenderError.emptyImage }
        guard let source = cgImage(width: width, height: height, rgbRows: rgbRows) else {
            throw RenderError.emptyImage
        }

        let requestedSize = CGSize(
            width: min(maximumSize.width, maxDimension),
            height: min(maximumSize.height, maxDimension))
        let scale = min(requestedSize.width / CGFloat(width), requestedSize.height / CGFloat(height))
        let thumbnailSize = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)

        guard let context = CGContext(
            data: nil,
            width: max(1, Int(thumbnailSize.width.rounded(.up))),
            height: max(1, Int(thumbnailSize.height.rounded(.up))),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.emptyImage
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: thumbnailSize))
        guard let image = context.makeImage() else { throw RenderError.emptyImage }
        return (image, thumbnailSize)
    }

    /// `pixDecode`'s row-major `(r,g,b)` triples -> a real `CGImage`, opaque (alpha 255
    /// throughout — a decoded `.PIX` has no transparency concept, same as the WordStar
    /// thumbnail path's own "paper is white" full-coverage assumption).
    private static func cgImage(
        width: Int, height: Int, rgbRows: [[(r: UInt8, g: UInt8, b: UInt8)]]
    ) -> CGImage? {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = rgbRows[y]
            for x in 0..<width {
                let pixel = row[x]
                let offset = (y * width + x) * 4
                raw[offset] = pixel.r
                raw[offset + 1] = pixel.g
                raw[offset + 2] = pixel.b
                raw[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
