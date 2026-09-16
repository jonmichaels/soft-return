import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41: the Native view draws every newspaper column the engine's page lines put on a sheet. A page's later columns
/// are text views of their own, over the page's view and at its frame; they shared the layout manager's
/// `drawsBackground`, so each painted the sheet white over the column before it, and REF/BOOKLET.WS showed only its
/// second column — in the window, in page thumbnails, in any capture. Each half of pages 1 and 2 must carry ink in every
/// place the app holds the view: no window (thumbnails), no window Continuous Scroll (print, Quick Look), Native PDF
/// export's own one-page capture, and a window's scroll view in Single Page and Continuous Scroll. The top of page 1,
/// Native beside Printed: b41-columns-booklet-native-vs-printed.png.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct NativeColumnsDrawTests {
    typealias Ink = (left: Int, right: Int)

    /// Dark, opaque pixels in the left and right halves of `rep`, between 160 and 450 pt down — below the heads, above
    /// the foot, the same band whichever way the rep is flipped on a 612 pt sheet.
    static func ink(_ rep: NSBitmapImageRep, pageWidth: CGFloat) -> Ink {
        let scaleX = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1, rep.size.height)
        let y0 = Int(160 * scaleY)
        let y1 = min(rep.pixelsHigh, Int(450 * scaleY))
        let mid = Int(pageWidth / 2 * scaleX)
        let maxX = min(rep.pixelsWide, Int(pageWidth * scaleX))
        var left = 0
        var right = 0
        guard y0 < y1 else { return (0, 0) }
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: 0, to: maxX, by: 2) {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                      let rgb = color.usingColorSpace(.deviceRGB), rgb.redComponent < 0.5 else { continue }
                if x < mid { left += 1 } else { right += 1 }
            }
        }
        return (left, right)
    }

    static func capture(_ view: NSView, rect: NSRect) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: rect, to: rep)
        }
        return rep
    }

    /// Page 1 of a PDF rasterised at 1x on white, and its ink per half.
    static func pdfInk(_ data: Data) throws -> Ink {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let page = try #require(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(box.width), pixelsHigh: Int(box.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = box.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let cg = context.cgContext
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: box.size))
        cg.translateBy(x: -box.minX, y: -box.minY)
        cg.drawPDFPage(page)
        return ink(rep, pageWidth: box.width)
    }

    /// The ink on page `index` of `host`, its page view's frame captured whole.
    static func pageInk(_ host: PagedDocumentView, page index: Int, pageWidth: CGFloat) throws -> Ink {
        let view = try #require(host.pageViews.indices.contains(index) ? host.pageViews[index] : nil, "no page view \(index + 1)")
        return ink(try capture(host, rect: view.frame), pageWidth: pageWidth)
    }

    /// Every text view `host` holds that is not a page's own view — its later columns — and whether any is opaque.
    static func opaqueColumnViews(_ host: PagedDocumentView) -> Int {
        host.subviews.compactMap { $0 as? NSTextView }
            .filter { view in !host.pageViews.contains { $0 === view } }
            .filter(\.isOpaque).count
    }

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason))
    func bookletDrawsBothColumnsEverywhereTheViewIsHeld() throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent("REF/BOOKLET.WS")
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let rendered = DocumentRenderer.render(state, style: .native)
        let width = rendered.pageSize.width
        let columns: [Int] = rendered.pageColumnFragmentCounts.first ?? []
        try #require(columns.count == 2, "BOOKLET.WS page 1 is not two columns: \(columns)")
        var failures: [String] = []
        func check(_ label: String, _ inked: Ink) {
            print("NATIVE-COLUMNS \(label): ink left \(inked.left), right \(inked.right)")
            if inked.left == 0 || inked.right == 0 { failures.append("\(label) \(inked)") }
        }

        // Page thumbnails (`PagePreviewRenderer`): no window, Single Page.
        let bare = PagedDocumentView()
        bare.setContent(rendered, display: .singlePage)
        bare.frame = CGRect(origin: .zero, size: rendered.pageSize)
        bare.layoutSubtreeIfNeeded()
        check("no window, Single Page, page 1", try Self.pageInk(bare, page: 0, pageWidth: width))
        #expect(Self.opaqueColumnViews(bare) == 0, "a column view is opaque (no window, Single Page)")

        // Print and Quick Look: no window, Continuous Scroll.
        let bareScroll = PagedDocumentView()
        bareScroll.setContent(rendered, display: .continuousScroll)
        bareScroll.setFrameSize(bareScroll.intrinsicContentSize)
        bareScroll.layoutSubtreeIfNeeded()
        for page in 0..<2 {
            check("no window, Continuous Scroll, page \(page + 1)", try Self.pageInk(bareScroll, page: page, pageWidth: width))
        }
        #expect(Self.opaqueColumnViews(bareScroll) == 0, "a column view is opaque (no window, Continuous Scroll)")

        // Native PDF export's own capture (`ExportEngine.appKitRenderedPDF`).
        bareScroll.capturingPageIndex = 0
        let pdfData = bareScroll.dataWithPDF(inside: bareScroll.rect(ofPage: 0))
        bareScroll.capturingPageIndex = nil
        check("Native PDF export, page 1", try Self.pdfInk(pdfData))

        // The document window's scroll view, never ordered on screen.
        for display in [PageDisplay.singlePage, .continuousScroll] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 60, height: 760),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width + 60, height: 760))
            scroll.hasVerticalScroller = true
            let host = PagedDocumentView()
            scroll.documentView = host
            window.contentView = scroll
            host.setContent(rendered, display: display)
            host.layoutSubtreeIfNeeded()
            let until = Date().addingTimeInterval(1.5)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
            host.layoutSubtreeIfNeeded()
            let name = display == .singlePage ? "Single Page" : "Continuous Scroll"
            check("window, \(name), page 1", try Self.pageInk(host, page: 0, pageWidth: width))
            #expect(Self.opaqueColumnViews(host) == 0, "a column view is opaque (window, \(name))")
        }

        #expect(failures.isEmpty, "a column drew no ink: \(failures)")
        try NativeSupSubRiseTests.writeComparison(state: state, rendered: rendered,
                                                  name: "b41-columns-booklet-native-vs-printed.png")
    }
}
