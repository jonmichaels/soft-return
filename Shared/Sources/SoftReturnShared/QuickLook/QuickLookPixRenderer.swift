import CoreGraphics
import CtrlKD
import Foundation

/// Job 374 (QL-PIX): standalone `.PIX` images, for the Quick Look extensions. Batch 29 (#272 I12): moved here
/// from `macos/SoftReturn/Rendering/QuickLookNativeRenderer.swift` so the iPhone's extensions draw a `.PIX` the
/// way the Mac's do — it needs only the engine and Core Graphics. Deliberately its OWN enum, not folded into
/// `QuickLookNativeRenderer`: a `.PIX` is a raw raster image, not a `DocumentState`/
/// `PagedDocumentView` document, so it has no `RenderedDocument` to produce and needs no
/// `@MainActor` at all — `CtrlKD.pixDecode`/`pixToPNG` are plain, Foundation-free, actor-
/// agnostic functions (see `Pix.swift`'s own header), and `CGImage`/`CGContext` construction
/// below needs no AppKit view or window. That absence of any actor hop is itself how this
/// type "minds job 369's SE-0420 lesson": there is no dispatched/MainActor closure for a
/// reply to end up nested inside in the first place.
public enum QuickLookPixRenderer {
    public enum RenderError: Error {
        case emptyImage
    }

    /// The Preview extension's shape: PNG bytes (`CtrlKD.pixToPNG`, already validated against
    /// real Inset renders — see `Pix.swift`) plus the size QuickLookUI should lay its preview
    /// window out around. Physical size (`pixPhysicalSizeIn`'s decipoints-derived inches, *72
    /// for points) when the file's own print-options record carries one — the same size
    /// `DocumentPictures`/`ExportAccessoryView` already trust for an EMBEDDED `.PIX`'s point
    /// size — falling back to the raw pixel dimensions 1:1 when it doesn't (no worse a
    /// default than what an untagged image would get anywhere else).
    public struct RenderedPix: Sendable {
        public let png: Data
        public let sizeInPoints: CGSize
    }

    public static func renderedPix(fromFileBytes bytes: [UInt8]) throws -> RenderedPix {
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
    public static func thumbnailImage(
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
