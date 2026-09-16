import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 40 (M10, Jon: "There's big gaps between each page. It's VERY slow. A lot of seemingly random drawing bugs pop
/// up… a big black bar will pop up on some of the pages."). Four defects the diagnosis found in Continuous Scroll, and
/// the measurements Athena asked for:
/// - the pages view no longer overrides `scrollWheel(with:)`, which took the scroll view out of responsive scrolling;
///   Single Page's flip comes from the window's event monitor instead;
/// - a progressive layout turn marks its new pages' paper for display (their margins showed the desk until redrawn);
/// - a rebuild removes a page's later-column text views, which stayed behind as ghosts;
/// - the oversized-line overlay draws only the pages the dirty rect reaches.
/// Measured: the gap between pages on screen at Fit (`PagedDocumentView.pageGap` × the zoom), and the time to draw
/// each view of a scroll through -HOLYMAC.WS and LYING.WS; photographed at page boundaries in light and dark.
///
/// What this cannot show: a draw here is `cacheDisplay`, which draws the view fresh. Whether AppKit's layer tiles on
/// a real screen were stale is a matter for Jon's eyes; the tests check what would make them stale.
@Suite(.serialized)
@MainActor
struct ContinuousScrollTests {
    @Test func thePagesViewLeavesTheScrollWheelToAppKit() {
        let selector = #selector(NSResponder.scrollWheel(with:))
        let own = class_getMethodImplementation(PagedDocumentView.self, selector)
        let inherited = class_getMethodImplementation(NSView.self, selector)
        #expect(own == inherited, "PagedDocumentView overrides scrollWheel(with:), which turns responsive scrolling off")
        #expect(PagedDocumentView.isCompatibleWithResponsiveScrolling)
    }

    /// Single Page still turns pages for a scroll, through `flipPages(for:)`; Continuous Scroll leaves the event alone.
    @Test func singlePageStillFlipsAndContinuousScrollDoesNot() throws {
        let (state, name) = try Self.multiPageSample()
        let rendered = DocumentRenderer.render(state, style: .native)
        let view = PagedDocumentView(frame: .zero)
        view.setContent(rendered, display: .singlePage)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        #expect(view.flipsPagesOnScroll, "\(name): Single Page with \(view.pageCount) pages does not flip")
        let down = try #require(Self.scrollEvent(deltaY: -60), "no scroll event could be made")
        #expect(view.flipPages(for: down))
        #expect(view.currentPageIndex == 1, "\(name): a scroll of -60 left Single Page on page \(view.currentPageIndex + 1)")

        view.setContent(rendered, display: .continuousScroll)
        #expect(!view.flipsPagesOnScroll)
        #expect(!view.flipPages(for: down), "Continuous Scroll consumed a scroll event")
    }

    /// A progressive layout turn marks the new pages for display, and only them. (b40-m10 read the mark back with
    /// `needsToDraw(_:)`, which answers true for every rect on a view outside a window — page 1 read "marked" before
    /// the turn ran — so the view states the strip it marked.)
    @Test func newPagesAreMarkedForDisplay() throws {
        let (state, name) = try Self.multiPageSample(minimumPages: 3)
        let rendered = DocumentRenderer.render(state, style: .native)
        let view = PagedDocumentView(frame: .zero)
        view.setContent(rendered, display: .continuousScroll, firstPages: 1)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let firstNew = view.pageCount
        try #require(!view.isLaidOut, "\(name): laid out whole at once")
        #expect(view.lastMarkedForDisplay == nil)
        view.layOutMorePages(until: 0)
        try #require(view.pageCount > firstNew, "\(name): a layout turn added no page")
        let strip = try #require(view.lastMarkedForDisplay, "\(name): the turn marked nothing for display")
        let newPage = view.rect(ofPage: firstNew)
        let oldPage = view.rect(ofPage: 0)
        print("CONTINUOUS-MARK \(name): pages \(firstNew) → \(view.pageCount); marked \(strip); new page \(newPage); page 1 \(oldPage)")
        #expect(strip.contains(newPage), "\(name): the new page \(newPage) is not inside the marked strip \(strip)")
        #expect(!strip.intersects(oldPage), "\(name): the turn marked page 1 \(oldPage), already shown")
    }

    /// A rebuild leaves exactly one text view per page and one per later column, plus the overlay.
    @Test(.tags(.corpus), .enabled(if: NativeLandscapePageTests.booklet != nil, NativeLandscapePageTests.skipReason))
    func aRebuildLeavesNoColumnViewsBehind() throws {
        let url = try #require(NativeLandscapePageTests.booklet)
        let defaults = try #require(UserDefaults(suiteName: "ContinuousScrollColumns.\(UUID().uuidString)"))
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: SettingsStore(defaults: defaults),
                                      docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .native)
        let view = PagedDocumentView(frame: .zero)
        var counts: [String] = []
        for round in 1...3 {
            view.setContent(rendered, display: .continuousScroll)
            view.setFrameSize(view.intrinsicContentSize)
            view.layoutSubtreeIfNeeded()
            let textViews = view.subviews.filter { $0 is NSTextView }.count
            counts.append("round \(round): \(textViews) text views for \(view.pageCount) pages + \(view.columnViewCount) columns")
            #expect(textViews == view.pageCount + view.columnViewCount,
                    "round \(round): \(textViews) text views in the view, \(view.pageCount) pages and \(view.columnViewCount) columns")
        }
        print("CONTINUOUS-COLUMNS \(url.lastPathComponent): \(counts)")
    }

    /// -HOLYMAC.WS (302 pages) opened the app's progressive way in Native Continuous Scroll, and LYING.WS: the gap on
    /// screen at Fit, the draw time of each view through a scroll top to bottom, and page boundaries photographed in
    /// light and dark with the pages' margins white and the gap the desk.
    @Test(arguments: ["LYING.WS", "-HOLYMAC.WS"])
    func scrollingThroughTheDocument(document: String) throws {
        let source: URL
        if document == "LYING.WS" {
            source = try #require(HolymacTimingTests.bundledSample("LYING.WS"))
        } else {
            guard PrivateCorpusSupport.isArmed, let root = PrivateCorpusSupport.sawyerArchiveRoot else {
                print("CONTINUOUS-SCROLL \(document): skipped, \(PrivateCorpusSupport.skipReason)")
                return
            }
            source = root.appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
            try #require(FileManager.default.fileExists(atPath: source.path), "no -HOLYMAC.WS in the Sawyer archive")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuousScrollTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent(document)
        try FileManager.default.copyItem(at: source, to: url)

        let wsDocument = WSDocument()
        wsDocument.fileURL = url
        try wsDocument.read(from: try Data(contentsOf: url), ofType: "me.beforeti.wordstar-document")
        let state = try #require(wsDocument.state as DocumentState?)
        state.style.setManually(.native)
        let controller = DocumentWindowController(state: state, progressiveOpen: true)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.setDisplay(.continuousScroll)
        let monitor = HolymacTimingTests.BlockMonitor()
        wsDocument.startDeferredParse { _ in controller.documentDidFinishParsing() }
        let loaded = monitor.wait("load", limit: HolymacTimingTests.waitLimit) { !controller.isLoadingContent }
        try #require(loaded, "\(document): still loading")
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let pages = controller.pagedView
        let scrollView = try #require(pages.enclosingScrollView)
        let magnification = scrollView.magnification
        try #require(pages.pageCount >= 2, "\(document): \(pages.pageCount) page(s)")
        let modelGap = pages.rect(ofPage: 1).minY - pages.rect(ofPage: 0).maxY
        // Batch 41 (Jon, from a Preview screenshot: "The gap is small but not 0"): 10 page points, Preview's own
        // spacing, so 10 × the Fit scale on screen.
        #expect(PagedDocumentView.pageGap == 10, "pageGap is \(PagedDocumentView.pageGap)")
        #expect(abs(modelGap - 10) < 0.01, "\(document): the model's gap between pages 1 and 2 is \(modelGap) pt")
        let screenGap = Double(modelGap * magnification)
        #expect(abs(screenGap - 10 * Double(magnification)) < 0.01, "\(document): \(screenGap) pt on screen at Fit")
        print("CONTINUOUS-GAP \(document): \(pages.pageCount) pages, Fit at \(String(format: "%.4f", magnification)), pageGap \(PagedDocumentView.pageGap) pt → \(String(format: "%.2f", PagedDocumentView.pageGap * magnification)) pt on screen; page 1 → 2 gap in the model \(modelGap) pt → \(String(format: "%.2f", modelGap * magnification)) pt")
        #expect(pages.subviews.filter { $0 is NSTextView }.count == pages.pageCount + pages.columnViewCount,
                "\(document): text views left over")

        // A scroll top to bottom in 60 views: each view's visible rect drawn, timed.
        let clip = scrollView.contentView
        let travel = max(0, pages.bounds.height - clip.bounds.height)
        var milliseconds: [Double] = []
        for step in 0...60 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: travel * CGFloat(step) / 60))
            scrollView.reflectScrolledClipView(clip)
            let visible = pages.visibleRect
            guard !visible.isEmpty, let rep = pages.bitmapImageRepForCachingDisplay(in: visible) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            pages.cacheDisplay(in: visible, to: rep)
            milliseconds.append(HolymacTimingTests.milliseconds(since: start))
        }
        let sorted = milliseconds.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("CONTINUOUS-FRAMES \(document): \(milliseconds.count) views drawn, median \(String(format: "%.1f", median)) ms, p95 \(String(format: "%.1f", p95)) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms; all \(milliseconds.map { String(format: "%.1f", $0) })")
        #expect(!milliseconds.isEmpty)
        let textViews = pages.subviews.filter { $0 is NSTextView }
        let shown = textViews.filter { !$0.isHidden }.count
        print("CONTINUOUS-SHOWN \(document): \(shown) of \(textViews.count) text views shown at the end of the scroll")
        if document == "-HOLYMAC.WS" {
            // b40-m10: a median 482.5 ms, every page's text view shown; b40-m10b: 13.7 ms with the far ones hidden. The
            // bound leaves room for a slower machine (Athena).
            #expect(median < 50, "\(document): a view drew in a median \(median) ms")
            #expect(shown < textViews.count, "\(document): every page's text view stayed shown")
        }

        // A capture of page 1 from the end of the scroll still draws page 1's text.
        let firstPage = pages.rect(ofPage: 0)
        let firstRep = try #require(pages.bitmapImageRepForCachingDisplay(in: firstPage))
        pages.cacheDisplay(in: firstPage, to: firstRep)
        var ink = 0
        for y in stride(from: 0, to: firstRep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: firstRep.pixelsWide, by: 3)
            where (firstRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5 {
                ink += 1
            }
        }
        print("CONTINUOUS-FARCAPTURE \(document): page 1 captured from the end of the scroll, \(ink) dark samples")
        #expect(ink > 0, "\(document): page 1, captured from the end of the scroll, has no ink")

        // Page boundaries: page 1 → 2, the middle, and the last two pages, in light and in dark.
        let boundaries = Array(Set([0, pages.pageCount / 2 - 1, pages.pageCount - 2])).filter { $0 >= 0 }.sorted()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let dark = appearance == .darkAqua
            for index in boundaries {
                let upper = pages.rect(ofPage: index)
                let lower = pages.rect(ofPage: index + 1)
                let band = NSRect(x: 0, y: upper.maxY - 60, width: pages.bounds.width, height: lower.minY - upper.maxY + 120)
                let scale: CGFloat = 2
                let rep = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(band.width * scale), pixelsHigh: Int(band.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = band.size
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    pages.cacheDisplay(in: band, to: rep)
                }
                // The left and right margins of both sheets are white; the gap between them is the desk, never
                // white and never a page's ink.
                func luminance(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                    let colour = rep.colorAt(x: Int(x * scale), y: Int((y - band.minY) * scale))?.usingColorSpace(.deviceRGB)
                    return colour.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? -1
                }
                var marginRows = 0, darkMarginRows = 0
                for y in stride(from: band.minY + 1, to: band.maxY - 1, by: 1) where upper.contains(NSPoint(x: 1, y: y)) || lower.contains(NSPoint(x: 1, y: y)) {
                    for x in [CGFloat(3), pages.bounds.width - 3] {
                        marginRows += 1
                        if luminance(x, y) < 0.97 { darkMarginRows += 1 }
                    }
                }
                let gapMiddle = (upper.maxY + lower.minY) / 2
                let gap = luminance(pages.bounds.width / 2, gapMiddle)
                let desk = NSColor.softReturnCanvas.usingColorSpace(.deviceRGB).map {
                    0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent
                }
                print("CONTINUOUS-BOUNDARY \(document) \(dark ? "dark" : "light") pages \(index + 1)–\(index + 2): margin samples \(marginRows), not white \(darkMarginRows); gap luminance \(String(format: "%.3f", gap)) (desk \(String(describing: desk)))")
                #expect(darkMarginRows == 0, "\(document) \(dark ? "dark" : "light") pages \(index + 1)–\(index + 2): \(darkMarginRows) margin samples are not white")
                #expect(gap < 0.97, "\(document): the gap between pages \(index + 1) and \(index + 2) is white")
                if let png = rep.representation(using: .png, properties: [:]) {
                    let proofs = RenderProbeKit.resolveOutputDirectory(
                        preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
                        fallbackName: "soft-return-proofs")
                    let file = proofs.appendingPathComponent("m10-\(document.replacingOccurrences(of: ".", with: "-"))-p\(index + 1)-\(dark ? "dark" : "light").png")
                    try png.write(to: file)
                    print("PROOF: \(file.path)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// The first bundled sample with at least `minimumPages` Native pages.
    static func multiPageSample(minimumPages: Int = 2) throws -> (DocumentState, String) {
        for name in ["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"] {
            guard let url = HolymacTimingTests.bundledSample(name) else { continue }
            let defaults = try #require(UserDefaults(suiteName: "ContinuousScroll.\(UUID().uuidString)"))
            let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: SettingsStore(defaults: defaults),
                                          docPath: url.path)
            if DocumentRenderer.render(state, style: .native).pageCount >= minimumPages { return (state, name) }
        }
        throw SampleError.noneLongEnough(minimumPages)
    }

    enum SampleError: Error {
        case noneLongEnough(Int)
    }

    /// A pixel-unit scroll event of `deltaY`.
    static func scrollEvent(deltaY: Int32) -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:))
    }
}
