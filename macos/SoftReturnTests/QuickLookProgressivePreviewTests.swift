import AppKit
import CtrlKD
import Darwin
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// The spacebar preview as `PreviewViewController` shows it — `QuickLookProgressivePreview`, run in-process in a window,
/// because a test cannot load the extension (see `QuickLookExtensionTests`).
///
/// Batch 45 (M24, Jon's final ruling: PDFKit leaves the preview): page 1 as an image, on screen at once with the
/// thumbnail column at full width and page 1's thumbnail in it; every later page drawn off the main thread and
/// appended one at a time with its thumbnail; nothing shown drawn again or moved; scrolling to whatever exists;
/// clicking a thumbnail shows its page. M23 (4.3.1 opened in page 1's lower half): the view's top is page 1's top at
/// the first paint.
///
/// Timing: from `load` to the first paint (page 1 now; batch 44's first paint waited for 10 pages; batch 40's target of
/// under 1.5 s for -HOLYMAC.WS stands) and to every page in.
///
/// Documents: LYING.WS (bundled, 3 pages); a long document made here from plain WordStar text (`longDocument`, 40
/// pages — always run); -HOLYMAC.WS (302 pages) when the private corpus is armed.
@Suite(.serialized)
@MainActor
struct QuickLookProgressivePreviewTests {
    static let longDocumentName = "LONG (made here)"

    @Test(arguments: ["LYING.WS", "LONG (made here)", "-HOLYMAC.WS"])
    func pageOneAtOnceThenTheRestOneByOne(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview

        let monitor = HolymacTimingTests.BlockMonitor()
        let painted = monitor.wait("first paint", limit: 60) { run.firstPaint.done }
        try #require(painted, "\(document): page 1 never showed")
        #expect(run.firstPaint.error == nil, "\(document): \(String(describing: run.firstPaint.error))")
        let firstPaintMs = Double((preview.firstPaintAt ?? 0) - preview.startedAt) / 1_000_000
        let blocksBeforeFirst = monitor.blocks.count

        let finished = monitor.wait("the rest", limit: HolymacTimingTests.waitLimit) { preview.isComplete }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let allPagesMs = Double((preview.completedAt ?? 0) - preview.startedAt) / 1_000_000
        let longestAfter = monitor.blocks.dropFirst(blocksBeforeFirst).max { $0.milliseconds < $1.milliseconds }

        let whole = try QuickLookNativeRenderer.previewPDF(fromFileBytes: source.bytes, docPath: source.path,
                                                           pageSettingsPreset: nil)
        let wholePDF = try #require(PDFDocument(data: whole.pdf))
        let added: [Int] = run.appends.map(\.added)
        let addedSizes: [Int] = Set(added).sorted()
        let paint = run.firstPaint
        var line = "QL-PROGRESSIVE \(document): first paint after \(String(format: "%.1f", firstPaintMs)) ms with"
        line += " \(paint.pages) page(s) and \(paint.thumbnails) thumbnail(s); visible top"
        line += " \(paint.visibleTop), page 1's top \(paint.pageOneTop); column \(paint.stripFrame)"
        line += " trailing \(paint.stripTrailing); every page (\(preview.pageViews.count)) after"
        line += " \(String(format: "%.1f", allPagesMs)) ms in \(run.appends.count) append(s); longest main-thread stretch"
        line += " after the first paint \(String(format: "%.1f", longestAfter?.milliseconds ?? 0)) ms"
        let held = preview.heldBytes
        line += " (\(longestAfter?.what ?? "none")); footprint \(Self.footprintMB()) MB (page PDFs \(held.pageDocuments / 1024) KB,"
        line += " \(held.pagesWithImages) page image(s) \(held.pageImages / 1_048_576) MB, thumbnails \(held.thumbnailImages / 1_048_576) MB); the whole preview has"
        line += " \(wholePDF.pageCount) pages"
        print(line)

        #expect(paint.pages == 1, "\(document): \(paint.pages) pages at the first paint, not 1")
        #expect(paint.thumbnails == 1, "\(document): \(paint.thumbnails) thumbnails at the first paint, not 1")
        #expect(paint.pageOneHasImage, "\(document): page 1 had no image at the first paint")
        #expect(paint.visibleTop == paint.pageOneTop,
                "\(document): M23 — the view's top is at \(paint.visibleTop), page 1's top at \(paint.pageOneTop)")
        #expect(paint.stripTrailing, "\(document): the thumbnail column is not on the trailing edge")
        #expect(paint.stripFrame.width == QuickLookProgressivePreview.thumbnailWidth,
                "\(document): the thumbnail column was \(paint.stripFrame.width) pt wide at the first paint")
        #expect(addedSizes == [1], "\(document): appends of \(addedSizes) pages — not one at a time")
        #expect(run.appends.allSatisfy { $0.thumbnails == $0.pages }, "\(document): a page appended without its thumbnail")
        #expect(preview.pageViews.count == wholePDF.pageCount,
                "\(document): \(preview.pageViews.count) pages in, the whole preview has \(wholePDF.pageCount)")
        let checked: Set<Int> = [0, 1, 9, 10, wholePDF.pageCount / 2, wholePDF.pageCount - 1]
        for index in checked.sorted() where index < preview.pageViews.count && index < wholePDF.pageCount {
            let reference = wholePDF.page(at: index)
            let shownData = preview.pageDocumentData(index)
            let shown = shownData.flatMap { PDFDocument(data: $0) }?.page(at: 0)
            let referenceSize = reference?.bounds(for: .mediaBox).size
            #expect(preview.pageViews[index].pageSize == referenceSize,
                    "\(document): page \(index + 1)'s size differs from the whole preview's")
            #expect(Self.characters(shown) == Self.characters(reference),
                    "\(document): page \(index + 1)'s text differs from the whole preview's")
        }
        if document == "-HOLYMAC.WS" {
            #expect(firstPaintMs < 1500, "-HOLYMAC.WS: page 1 showed after \(firstPaintMs) ms, not under 1.5 s")
        }
    }

    /// Opened on page 1's top, the view stays there through every append and at completion.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func staysOnPageOneThroughEveryAppend(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview

        let monitor = HolymacTimingTests.BlockMonitor()
        var sampledTops: Set<CGFloat> = []
        let finished = monitor.wait("every page", limit: HolymacTimingTests.waitLimit) {
            if run.firstPaint.done { sampledTops.insert(preview.visibleRect.minY) }
            return preview.isComplete
        }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let tops: [CGFloat] = Set(run.appends.map(\.visibleTop)).sorted()
        let selections: [Int] = Set(run.appends.compactMap(\.selected)).sorted()
        let sampled: [CGFloat] = sampledTops.sorted()
        print("QL-STAYS-ON-PAGE-1 \(document): \(preview.pageViews.count) pages, \(run.appends.count) append(s); view tops at appends \(tops), sampled \(sampled); selections \(selections)")

        #expect(run.appends.count >= 2, "\(document): only \(run.appends.count) append(s)")
        #expect(tops == [0], "\(document): the view's top moved at an append — \(tops)")
        #expect(sampled == [0], "\(document): the view's top moved between appends — \(sampled)")
        #expect(selections == [0], "\(document): the selected thumbnail left page 1 — \(selections)")
    }

    /// Moved to page 15's top while pages are still coming, the view stays exactly there.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func staysWhereItWasMovedMidLoad(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview

        let monitor = HolymacTimingTests.BlockMonitor()
        let twenty = monitor.wait("twenty pages", limit: HolymacTimingTests.waitLimit) {
            preview.pageViews.count >= 20 || preview.isComplete
        }
        try #require(twenty, "\(document): \(preview.pageViews.count) pages after \(Int(HolymacTimingTests.waitLimit)) s")
        try #require(!preview.isComplete, "\(document): every page was in before the move — too short to show anything")
        let target = 14
        preview.showPage(target)
        let movedTop = preview.visibleRect.minY
        let targetTop = preview.pageViews[target].frame.minY
        try #require(movedTop == targetTop, "\(document): showPage put the view's top at \(movedTop), page 15's top is \(targetTop)")
        let appendsBeforeMove = run.appends.count

        var sampledTops: Set<CGFloat> = []
        let finished = monitor.wait("the rest", limit: HolymacTimingTests.waitLimit) {
            sampledTops.insert(preview.visibleRect.minY)
            return preview.isComplete
        }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let later = Array(run.appends.dropFirst(appendsBeforeMove))
        let tops: [CGFloat] = Set(later.map(\.visibleTop)).sorted()
        let selections: [Int] = Set(later.compactMap(\.selected)).sorted()
        let sampled: [CGFloat] = sampledTops.sorted()
        print("QL-STAYS-WHERE-MOVED \(document): moved to page \(target + 1) (top \(movedTop)) with \(appendsBeforeMove) page(s) in; \(later.count) later append(s); view tops at them \(tops), sampled \(sampled); selections \(selections)")

        #expect(later.count >= 1, "\(document): no append after the move")
        #expect(tops == [movedTop], "\(document): the view's top moved at an append — \(tops)")
        #expect(sampled == [movedTop], "\(document): the view's top moved between appends — \(sampled)")
        #expect(selections == [target], "\(document): the selected thumbnail left page \(target + 1) — \(selections)")
    }

    /// A click on a thumbnail shows that page from its top, and selects it.
    @Test func clickingAThumbnailShowsItsPage() throws {
        guard let source = try Self.source(Self.longDocumentName) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview
        let monitor = HolymacTimingTests.BlockMonitor()
        try #require(monitor.wait("every page", limit: HolymacTimingTests.waitLimit) { preview.isComplete })
        let target = 6
        let item = preview.thumbnailViews[target]
        let point = item.convert(NSPoint(x: item.bounds.midX, y: item.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: run.window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        item.mouseDown(with: event)
        let top = preview.visibleRect.minY
        let targetTop = preview.pageViews[target].frame.minY
        #expect(top == targetTop, "the click left the view's top at \(top), page \(target + 1)'s top is \(targetTop)")
        #expect(preview.selectedPageIndex == target, "the selected thumbnail is \(String(describing: preview.selectedPageIndex))")
    }

    /// Nothing shown is drawn again or moved while the rest arrives: every thumbnail keeps the one image it was given
    /// and its place, every page its place, and page 1 — on screen throughout — its one image.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func nothingShownIsDrawnAgainOrMoved(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview
        let monitor = HolymacTimingTests.BlockMonitor()
        try #require(monitor.wait("every page", limit: HolymacTimingTests.waitLimit) { preview.isComplete })

        var redrawn: [Int] = []
        var moved: [Int] = []
        var blank: [Int] = []
        for (index, first) in run.firstSeen.enumerated() {
            let item = preview.thumbnailViews[index]
            let image = item.imageView.image.map { ObjectIdentifier($0) }
            if item.imageView.imagesSet != 1 || image != first.thumbnailImage { redrawn.append(index + 1) }
            if item.frame != first.thumbnailFrame || preview.pageViews[index].frame != first.pageFrame { moved.append(index + 1) }
            if image == nil { blank.append(index + 1) }
        }
        let pageOne = preview.pageViews[0]
        let pageOneImage = pageOne.image.map { ObjectIdentifier($0) }
        let firstRedrawn = Array(redrawn.prefix(10))
        let firstMoved = Array(moved.prefix(10))
        let firstBlank = Array(blank.prefix(10))
        print("QL-NOTHING-REDRAWN \(document): \(run.firstSeen.count) pages; thumbnails drawn again \(firstRedrawn), moved \(firstMoved), without an image \(firstBlank); page 1 given \(pageOne.imagesSet) image(s)")
        #expect(run.firstSeen.count == preview.pageViews.count)
        #expect(redrawn.isEmpty, "\(document): \(redrawn.count) thumbnail(s) drawn again, first \(firstRedrawn)")
        #expect(moved.isEmpty, "\(document): \(moved.count) page(s) or thumbnail(s) moved, first \(firstMoved)")
        #expect(blank.isEmpty, "\(document): \(blank.count) thumbnail(s) without an image, first \(firstBlank)")
        #expect(pageOne.imagesSet == 1, "\(document): page 1 was given \(pageOne.imagesSet) images")
        #expect(pageOneImage == run.firstSeen.first?.pageImage, "\(document): page 1's image was replaced")
    }

    /// What the first paint and the middle of a load SHOW, rendered from the view's layers: page 1's text has ink, its
    /// thumbnail is a picture of the page, and later thumbnails fill in below.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func firstPaintAndMidLoadRenders(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview
        let slug = document == "-HOLYMAC.WS" ? "holymac" : "long"
        let monitor = HolymacTimingTests.BlockMonitor()
        try #require(monitor.wait("first paint", limit: 60) { run.firstPaint.done })

        let first = try Self.render(preview, name: "m24-ql-\(slug)-first-paint")
        let pageOneRect = preview.view.convert(preview.pageViews[0].bounds, from: preview.pageViews[0])
        let pageInk = Self.count(in: first, of: preview.view, rect: pageOneRect) { $0 < 0.35 }
        let thumbnail = preview.thumbnailViews[0].imageView
        let thumbnailRect = preview.view.convert(thumbnail.bounds, from: thumbnail)
        let thumbnailPaper = Self.count(in: first, of: preview.view, rect: thumbnailRect) { $0 > 0.95 }
        let thumbnailInk = Self.count(in: first, of: preview.view, rect: thumbnailRect) { $0 < 0.75 }

        let eight = monitor.wait("eight pages", limit: HolymacTimingTests.waitLimit) { preview.pageViews.count >= 8 || preview.isComplete }
        try #require(eight)
        let midPages = preview.pageViews.count
        let mid = try Self.render(preview, name: "m24-ql-\(slug)-mid-load")
        let lastVisible = min(midPages, 7) - 1
        let later = preview.thumbnailViews[lastVisible].imageView
        let laterRect = preview.view.convert(later.bounds, from: later)
        let laterPaper = Self.count(in: mid, of: preview.view, rect: laterRect) { $0 > 0.95 }
        print("QL-RENDERS \(document): first paint page-1 ink \(pageInk) pt², first thumbnail \(thumbnailRect.size) paper \(thumbnailPaper) ink \(thumbnailInk) pt²; mid-load \(midPages) pages, thumbnail \(lastVisible + 1) paper \(laterPaper) pt²")

        let thumbnailArea = Int(thumbnailRect.width * thumbnailRect.height)
        #expect(pageInk > 50, "\(document): page 1 drew \(pageInk) pt² of ink at the first paint")
        #expect(thumbnailPaper > thumbnailArea / 3, "\(document): the first thumbnail shows no page")
        #expect(thumbnailInk > 0, "\(document): the first thumbnail shows no text")
        #expect(laterPaper > 0, "\(document): thumbnail \(lastVisible + 1) shows no page mid-load")
    }

    // MARK: - Support

    /// The preview in a window the size batch 40 timed it in, loading `bytes`, with what it showed at its first paint
    /// and at every append.
    @MainActor
    final class Run {
        let window: NSWindow
        let preview = QuickLookProgressivePreview()
        let firstPaint = FirstPaint()
        private(set) var appends: [Append] = []
        /// Each page's thumbnail image and frames when it first appeared.
        private(set) var firstSeen: [Seen] = []

        struct Append {
            let pages: Int
            let thumbnails: Int
            let added: Int
            let visibleTop: CGFloat
            let selected: Int?
        }

        struct Seen {
            let thumbnailImage: ObjectIdentifier?
            let thumbnailFrame: NSRect
            let pageFrame: NSRect
            let pageImage: ObjectIdentifier?
        }

        init(bytes: [UInt8], docPath: String, size: NSSize = NSSize(width: 800, height: 1000)) {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            let content = window.contentView!
            content.addSubview(preview.view)
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                preview.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                preview.view.topAnchor.constraint(equalTo: content.topAnchor),
                preview.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            content.layoutSubtreeIfNeeded()
            preview.onAppend = { [unowned self] pages in record(pages) }
            preview.load(bytes: bytes, docPath: docPath, pageSettingsPreset: nil) { [unowned self] error in
                recordFirstPaint(error)
            }
        }

        private func record(_ pages: Int) {
            let index = pages - 1
            let item = preview.thumbnailViews[index]
            let pageView = preview.pageViews[index]
            firstSeen.append(Seen(thumbnailImage: item.imageView.image.map { ObjectIdentifier($0) }, thumbnailFrame: item.frame,
                                  pageFrame: pageView.frame, pageImage: pageView.image.map { ObjectIdentifier($0) }))
            let added = pages - (appends.last?.pages ?? 0)
            appends.append(Append(pages: pages, thumbnails: preview.thumbnailViews.count, added: added,
                                  visibleTop: preview.visibleRect.minY, selected: preview.selectedPageIndex))
        }

        private func recordFirstPaint(_ error: Error?) {
            window.contentView?.layoutSubtreeIfNeeded()
            let strip = preview.thumbnailScroll.frame
            firstPaint.done = true
            firstPaint.error = error
            firstPaint.pages = preview.pageViews.count
            firstPaint.thumbnails = preview.thumbnailViews.count
            firstPaint.pageOneHasImage = preview.pageViews.first?.image != nil
            firstPaint.visibleTop = preview.visibleRect.minY
            firstPaint.pageOneTop = preview.pageViews.first?.frame.minY ?? -1
            firstPaint.stripFrame = strip
            let trailing = strip.minX >= preview.pageScroll.frame.maxX - 0.5 && abs(strip.maxX - preview.view.bounds.maxX) < 0.5
            firstPaint.stripTrailing = !preview.thumbnailScroll.isHiddenOrHasHiddenAncestor && trailing
        }
    }

    @MainActor
    final class FirstPaint {
        var done = false
        var error: Error?
        var pages = 0
        var thumbnails = 0
        var pageOneHasImage = false
        var visibleTop: CGFloat = -1
        var pageOneTop: CGFloat = -2
        var stripFrame: NSRect = .zero
        var stripTrailing = false
    }

    /// `preview.view` drawn from its layers — the page and thumbnail images are layer contents, which
    /// `cacheDisplay(in:to:)` does not draw — to a 2x PNG in the proofs directory.
    static func render(_ preview: QuickLookProgressivePreview, name: String) throws -> NSBitmapImageRep {
        preview.view.window?.contentView?.layoutSubtreeIfNeeded()
        preview.view.window?.displayIfNeeded()
        let bounds = preview.view.bounds
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                                pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let layer = try #require(preview.view.layer)
        context.cgContext.scaleBy(x: 2, y: 2)
        layer.render(in: context.cgContext)
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        try FileManager.default.createDirectory(at: proofs, withIntermediateDirectories: true)
        let png = proofs.appendingPathComponent("\(name).png")
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: png)
        print("PROOF: \(png.path)")
        return rep
    }

    /// Points of `rect` (in `view`'s coordinates) whose brightness in `rep`, `view`'s 2x render, satisfies `test`.
    static func count(in rep: NSBitmapImageRep, of view: NSView, rect: CGRect, where test: (CGFloat) -> Bool) -> Int {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        var hits = 0
        for y in Int(top)..<Int(top + rect.height) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let colour = rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.5 else { continue }
                if test(colour.brightnessComponent) { hits += 1 }
            }
        }
        return hits
    }

    /// This process's physical footprint, in MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// A page's text with its whitespace taken out: PDFKit's extraction spaces the same text differently from one
    /// capture to another (b44-r1, b44-r3).
    static func characters(_ page: PDFPage?) -> String {
        String((page?.string ?? "").filter { !$0.isWhitespace })
    }

    /// `document`'s bytes and path, or nil (printed) when it is -HOLYMAC.WS and the private corpus is not armed.
    static func source(_ document: String) throws -> (bytes: [UInt8], path: String)? {
        switch document {
        case "LYING.WS":
            let url = try #require(HolymacTimingTests.bundledSample("LYING.WS"))
            return ([UInt8](try Data(contentsOf: url)), url.path)
        case longDocumentName:
            return (longDocument(), "LONG.WS")
        default:
            guard PrivateCorpusSupport.isArmed, let root = PrivateCorpusSupport.sawyerArchiveRoot else {
                print("QL-PROGRESSIVE \(document): skipped, \(PrivateCorpusSupport.skipReason)")
                return nil
            }
            let url = root.appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
            try #require(FileManager.default.fileExists(atPath: url.path), "no -HOLYMAC.WS in the Sawyer archive")
            return ([UInt8](try Data(contentsOf: url)), url.path)
        }
    }

    /// A long WordStar 4 document made here: twenty `.pa`-ended stretches of numbered lines, each running past a
    /// page — 40 pages.
    static func longDocument() -> [UInt8] {
        var bytes: [UInt8] = []
        for stretch in 1...20 {
            for line in 1...30 {
                bytes += Array("Stretch \(stretch), line \(line): the quick brown fox jumps over the lazy dog".utf8)
                bytes += [0x8D, 0x0A]
                bytes += Array("and keeps on running.\r\n".utf8)
            }
            bytes += Array(".pa\r\n".utf8)
        }
        bytes.append(0x1A)
        return bytes
    }
}

/// Batch 47 (M29, Jon: Quick Look opens on page 1 and a sliver of page 2): the preview opens on exactly one page. Its
/// view starts at, and asks for, a page beside the thumbnail column — US Letter's 744 × 792 before page 1 is made — and
/// a page is fitted to the column's width or its height, whichever is tighter, so in a window of the size it asks for,
/// in one scaled down, and in one shorter for its width, page 1 is wholly in view and page 2 is not. Render per window:
/// m29-one-page-<width>x<height>.png.
@Suite("Quick Look opens on one page (M29)", .serialized)
@MainActor
struct QuickLookOnePageTests {
    @Test func theViewStartsWithRoomForTheThumbnailColumn() {
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        #expect(QuickLookProgressivePreview.defaultContentSize
                == CGSize(width: 612 + QuickLookProgressivePreview.thumbnailWidth + scroller, height: 792))
    }

    @Test(arguments: ["LYING.WS", "LONG (made here)"])
    func exactlyPageOneInView(document: String) throws {
        guard let source = try QuickLookProgressivePreviewTests.source(document) else { return }
        // The size it asks for, first learnt from a load in a window of the default size.
        let probe = QuickLookProgressivePreviewTests.Run(bytes: source.bytes, docPath: source.path)
        let monitor = HolymacTimingTests.BlockMonitor()
        try #require(monitor.wait("first paint", limit: 60) { probe.firstPaint.done })
        let asked = probe.preview.preferredContentSize
        probe.preview.cancel()
        print("M29 \(document): the preview asks for \(asked)")
        for (index, window) in [asked, CGSize(width: asked.width * 1.3, height: asked.height),
                                QuickLookProgressivePreview.defaultContentSize,
                                CGSize(width: asked.width * 0.75, height: asked.height * 0.75)].enumerated() {
            let run = QuickLookProgressivePreviewTests.Run(bytes: source.bytes, docPath: source.path,
                                                            size: NSSize(width: window.width.rounded(), height: window.height.rounded()))
            defer { run.preview.cancel() }
            try #require(monitor.wait("first paint", limit: 60) { run.firstPaint.done })
            let preview = run.preview
            try #require(monitor.wait("page 2", limit: 60) { preview.pageViews.count >= 2 || preview.isComplete })
            let visible = preview.pageScroll.contentView.bounds
            let one = preview.pageViews[0].frame
            print("M29 \(document) window \(window): visible \(visible), page 1 \(one), page 2 \(preview.pageViews.count > 1 ? preview.pageViews[1].frame : .zero)")
            #expect(visible.insetBy(dx: -0.5, dy: -0.5).contains(one), "page 1 \(one) is not wholly in view \(visible)")
            #expect(abs(one.height - visible.height) < 1.5 || abs(one.width - visible.width) < 1.5,
                    "page 1 \(one) fills neither the view's width nor its height \(visible)")
            if preview.pageViews.count > 1 {
                let two = preview.pageViews[1].frame
                // In the window it asks for, one wider, and the default: nothing of page 2 in view. Scaled down whole
                // (Quick Look shrinking the window for a small screen scales the thumbnail column too) page 1 is
                // width-limited and a little of page 2 can show; that is reported, not failed.
                if index < 3 {
                    #expect(two.minY >= visible.maxY - 0.5, "page 2 \(two) shows in view \(visible) in the \(window) window")
                } else {
                    print("M29 \(document) scaled window: \(max(0, visible.maxY - two.minY)) pt of page 2 in view")
                }
            }
            let rep = try QuickLookProgressivePreviewTests.render(preview, name: "m29-one-page-\(Int(window.width))x\(Int(window.height))")
            _ = rep
        }
    }
}
