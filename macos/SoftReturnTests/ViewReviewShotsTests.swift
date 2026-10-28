import AppKit
import CtrlKD
import SoftReturnShared
import Foundation
import Testing
@testable import SoftReturn
@testable import SoftReturnRendering

/// Printed and Native, side by side, for a person to look at: each document's window drawn in
/// both views and attached to the result bundle (`xcresulttool export attachments`). The
/// documents carry WS7's LaserJet driver at work: Garamond and Times placed by the driver's
/// widths and kerning (the samples), Univers and Aachen (PREVIEW.WS), and Sawyer's LJ6DTP
/// with its tucked quote pairs (LJ6DTP.WS); and fixed-width WS4 documents printed by WS4
/// (OCAPTAIN.WS, TWAINLET.WS, RUSSIA.WS4, ESSAY1.WS4). The test proves each render drew ink and
/// that the two views differ; the pictures are for the eye.
@Suite(.serialized) struct ViewReviewShotsTests {
    private static let size = NSSize(width: 1100, height: 1400)

    /// Fixed-width documents: Native draws every lettered run in Courier Prime and nothing else.
    /// A box-drawing character may take a face that covers it.
    private static let fixedWidth: Set<String> = ["OCAPTAIN.WS", "TWAINLET.WS", "RUSSIA.WS4", "ESSAY1.WS4"]

    @MainActor
    private static func windowPNG(of url: URL, style: ViewStyle) throws -> Data {
        let appearance = NSAppearance(named: .aqua)!
        let docState = try Oracle.state(for: url)
        docState.style.setManually(style)
        let controller = DocumentWindowController(state: docState)
        controller.window?.appearance = appearance
        controller.showWindow(nil)
        controller.window?.setContentSize(size)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        defer { controller.close() }
        // PDFKit paints its pages in tiles a cached display never draws, so Printed is the first
        // page of the very PDF its view shows, rasterised.
        if style == .printed {
            let pdf = try #require(controller.pdfView.document?.dataRepresentation(),
                                   "the Printed view has no PDF")
            let image = try NativeLandscapePageTests.pageImage([UInt8](pdf), page: 1, scale: 2)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            return data
        }
        let content = try #require(controller.window?.contentView, "window has no contentView")
        return try RenderProbeKit.pngData(view: content, appearance: appearance)
    }

    @MainActor
    private static func shoot(_ name: String, at url: URL) throws {
        let printed = try windowPNG(of: url, style: .printed)
        let native = try windowPNG(of: url, style: .native)
        #expect(!printed.isEmpty && !native.isEmpty, "\(name): a render was empty")
        #expect(printed != native, "\(name): Printed and Native drew the same picture")
        Attachment.record(printed, named: "\(name)-printed.png")
        Attachment.record(native, named: "\(name)-native.png")
    }

    /// Every page of LJ6DTP.WS in both views: Native page by page off the window's own paged
    /// view at 2x, Printed from the PDF its view shows.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func lj6dtpEveryPage() throws {
        let url = try #require(Oracle.allFixtureURLs.first { $0.lastPathComponent == "LJ6DTP.WS" })
        let appearance = NSAppearance(named: .aqua)!
        let printedState = try Oracle.state(for: url)
        printedState.style.setManually(.printed)
        let printed = DocumentWindowController(state: printedState)
        printed.showWindow(nil)
        let pdf = try #require(printed.pdfView.document?.dataRepresentation(), "the Printed view has no PDF")
        printed.close()
        let pageCount = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages)
        for page in 1...pageCount {
            let image = try NativeLandscapePageTests.pageImage([UInt8](pdf), page: page, scale: 2)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            Attachment.record(png, named: "LJ6DTP-printed-p\(page).png")
        }

        let nativeState = try Oracle.state(for: url)
        let controller = DocumentWindowController(state: nativeState)
        controller.window?.appearance = appearance
        controller.showWindow(nil)
        defer { controller.close() }
        controller.setStyle(.native)
        controller.setDisplay(.continuousScroll)
        let content = try #require(controller.window?.contentView)
        let scrollView = try #require(RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }.first)
        scrollView.magnification = 1.0
        content.layoutSubtreeIfNeeded()
        let pagedView = controller.pagedView
        #expect(pagedView.pageCount == pageCount, "Native has \(pagedView.pageCount) pages, Printed \(pageCount)")
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), "page \(index + 1)")
            bitmap.size = rect.size
            appearance.performAsCurrentDrawingAppearance { pagedView.cacheDisplay(in: rect, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(png, named: "LJ6DTP-native-p\(index + 1).png")
        }
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason),
          arguments: ["WARPRAYR.WS", "LYING.WS", "PREVIEW.WS", "LJ6DTP.WS", "YOURWAY.WS", "BOXES.WS",
                      "OCAPTAIN.WS", "TWAINLET.WS", "RUSSIA.WS4", "ESSAY1.WS4"])
    @MainActor func printedAndNative(document: String) throws {
        let url = try #require(Oracle.allFixtureURLs.first { $0.lastPathComponent == document },
                               "\(document) is not in the fixture set")
        try Self.shoot(document, at: url)
        guard Self.fixedWidth.contains(document) else { return }
        let text = DocumentRenderer.render(try Oracle.state(for: url), style: .native).text
        var faces: Set<String> = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let run = (text.string as NSString).substring(with: range)
            guard run.contains(where: { $0.isLetter || $0.isNumber }),
                  let font = value as? NSFont, font.familyName != "Courier Prime" else { return }
            faces.insert(font.fontName)
        }
        #expect(faces.isEmpty, "\(document): Native draws text in \(faces.sorted()), not Courier Prime")
    }
}
