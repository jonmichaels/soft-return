import AppKit
import CtrlKD
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 40 (M11, Jon: ">5 seconds… blank window… then the first page and all thumbnails appear at once."): the
/// spacebar preview's pages as `PreviewViewController` shows them — `QuickLookProgressivePreview`, run in-process in a
/// window, because a test cannot load the extension (see `QuickLookExtensionTests`).
///
/// Batch 44 (M21, Jon on 4.3.0's preview: "Completely unusable"; "The USER gets to choose which page to display. Not
/// us."): the first paint now comes after the first `batchPages` pages are made (the whole document when it is
/// shorter), with the thumbnail strip on the trailing edge and showing, and the rest are appended `batchPages` at a
/// time. So the timing is from `load` to that first paint — batch 40's "page 1 shown" measured page 1 alone, and is
/// gone — and to every page in; Athena's -HOLYMAC.WS target of under 1.5 s now applies to the first paint. The view
/// must never move on its own: it stays on page 1 through every append, and on the page the person went to when
/// they move mid-load, with the thumbnail strip's selection on that page too.
///
/// Documents: LYING.WS (bundled, 4 pages — shown whole at the first paint); a long document made here from plain
/// WordStar text (`longDocument`, dozens of pages — several appends, always run); -HOLYMAC.WS (302 pages) when the
/// private corpus is armed.
@Suite(.serialized)
@MainActor
struct QuickLookProgressivePreviewTests {
    static let longDocumentName = "LONG (made here)"

    @Test(arguments: ["LYING.WS", "LONG (made here)", "-HOLYMAC.WS"])
    func firstPagesThenTheRest(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview

        let monitor = HolymacTimingTests.BlockMonitor()
        let painted = monitor.wait("first paint", limit: 60) { run.firstPaint.done }
        try #require(painted, "\(document): the first pages never showed")
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
        let expectedAtFirstPaint = min(QuickLookProgressivePreview.batchPages, wholePDF.pageCount)
        var line = "QL-PROGRESSIVE \(document): first paint after \(String(format: "%.1f", firstPaintMs)) ms"
        line += " with \(run.firstPaint.pages) page(s) in, thumbnails showing \(run.firstPaint.thumbnailsShowing)"
        line += " on the trailing edge \(run.firstPaint.thumbnailsTrailing); every page (\(preview.document.pageCount))"
        line += " after \(String(format: "%.1f", allPagesMs)) ms in \(run.appends.count) append(s); longest main-thread"
        line += " stretch after the first paint \(String(format: "%.1f", longestAfter?.milliseconds ?? 0)) ms"
        line += " (\(longestAfter?.what ?? "none")); the whole preview has \(wholePDF.pageCount) pages"
        print(line)

        #expect(run.firstPaint.pages == expectedAtFirstPaint,
                "\(document): \(run.firstPaint.pages) pages in at the first paint, not \(expectedAtFirstPaint)")
        #expect(run.firstPaint.pageIndex == 0, "\(document): the first paint showed page \((run.firstPaint.pageIndex ?? -2) + 1)")
        #expect(run.firstPaint.thumbnailsShowing, "\(document): the thumbnails were not showing at the first paint")
        #expect(run.firstPaint.thumbnailsTrailing, "\(document): the thumbnails were not on the trailing edge at the first paint")
        #expect(run.firstPaint.thumbnailsWidth == QuickLookProgressivePreview.thumbnailWidth,
                "\(document): the thumbnail strip was \(run.firstPaint.thumbnailsWidth) pt wide at the first paint")
        #expect(preview.pdfView.document === preview.document)
        #expect(run.appends.allSatisfy { $0.added <= QuickLookProgressivePreview.batchPages },
                "\(document): appends of \(run.appends.map(\.added)) pages")
        #expect(preview.document.pageCount == wholePDF.pageCount,
                "\(document): \(preview.document.pageCount) pages in, the whole preview has \(wholePDF.pageCount)")
        // Batch 44 (M21b): each captured page came from its own one-page PDF, and every thumbnail read "1".
        let labels = (0..<preview.document.pageCount).map { preview.document.page(at: $0)?.label ?? "nil" }
        var misnumbered: [String] = []
        for (index, label) in labels.enumerated() where label != String(index + 1) {
            misnumbered.append("page \(index + 1) = \(label)")
        }
        let firstMisnumbered = Array(misnumbered.prefix(5))
        #expect(misnumbered.isEmpty, "\(document): \(misnumbered.count) page label(s) are not their page's number, first \(firstMisnumbered)")
        // The first paint's pages come from the text's first pages alone; they must be the whole render's.
        let checked = Set(Array(0..<expectedAtFirstPaint) + [wholePDF.pageCount / 2, wholePDF.pageCount - 1])
        for index in checked.sorted() where index < preview.document.pageCount {
            let shown = preview.document.page(at: index)
            let reference = wholePDF.page(at: index)
            #expect(shown?.bounds(for: .mediaBox).size == reference?.bounds(for: .mediaBox).size,
                    "\(document): page \(index + 1)'s size differs from the whole preview's")
            #expect(Self.characters(shown) == Self.characters(reference),
                    "\(document): page \(index + 1)'s text differs from the whole preview's")
        }
        if document == "-HOLYMAC.WS" {
            #expect(firstPaintMs < 1500, "-HOLYMAC.WS: the first paint came after \(firstPaintMs) ms, not under 1.5 s")
        }
    }

    /// Opened on page 1, the view stays there through every append and at completion — never ridden to the newest page.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func staysOnPageOneThroughEveryAppend(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview

        let monitor = HolymacTimingTests.BlockMonitor()
        var sampled: [Int] = []
        let finished = monitor.wait("every page", limit: HolymacTimingTests.waitLimit) {
            if let index = run.currentIndex { sampled.append(index) }
            return preview.isComplete
        }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let appendsAfterFirstPaint = run.appends.dropFirst()
        print("QL-STAYS-ON-PAGE-1 \(document): \(preview.document.pageCount) pages, \(run.appends.count) append(s); pages seen at appends \(Set(run.appends.compactMap(\.pageIndex)).sorted().map { $0 + 1 }), sampled \(Set(sampled).sorted().map { $0 + 1 }); selections \(Set(run.appends.compactMap(\.selectedIndex)).sorted().map { $0 + 1 })")

        #expect(appendsAfterFirstPaint.count >= 2, "\(document): only \(run.appends.count) append(s) — too short to show anything")
        #expect(run.appends.allSatisfy { $0.pageIndex == 0 },
                "\(document): the view left page 1 at an append — pages \(run.appends.map { ($0.pageIndex ?? -2) + 1 })")
        #expect(sampled.allSatisfy { $0 == 0 }, "\(document): the view left page 1 between appends — pages \(Set(sampled).sorted().map { $0 + 1 })")
        #expect(run.currentIndex == 0, "\(document): at completion the view is on page \((run.currentIndex ?? -2) + 1)")
        #expect(run.appends.allSatisfy { $0.selectedIndex == 0 },
                "\(document): the thumbnail selection left page 1 — \(run.appends.map { ($0.selectedIndex ?? -2) + 1 })")
        #expect(run.selectedIndex == 0, "\(document): at completion the thumbnail selection is page \((run.selectedIndex ?? -2) + 1)")
    }

    /// Moved to a page while pages are still coming, the view stays on that page through every later append.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func staysWhereItWasMovedMidLoad(document: String) throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview
        let batch = QuickLookProgressivePreview.batchPages

        let monitor = HolymacTimingTests.BlockMonitor()
        let twoBatches = monitor.wait("two batches", limit: HolymacTimingTests.waitLimit) {
            preview.document.pageCount >= 2 * batch || preview.isComplete
        }
        try #require(twoBatches, "\(document): \(preview.document.pageCount) pages after \(Int(HolymacTimingTests.waitLimit)) s")
        try #require(!preview.isComplete, "\(document): every page was in before the move — too short to show anything")
        let target = batch + batch / 2 - 1   // page 15: in the second batch, with more batches still to come
        let targetPage = try #require(preview.document.page(at: target))
        preview.pdfView.go(to: targetPage)
        let appendsBeforeMove = run.appends.count
        try #require(run.currentIndex == target, "\(document): go(to:) page \(target + 1) left the view on page \((run.currentIndex ?? -2) + 1)")
        let movedTo = preview.pdfView.currentDestination?.point ?? .zero

        var sampled: [Int] = []
        let finished = monitor.wait("the rest", limit: HolymacTimingTests.waitLimit) {
            if let index = run.currentIndex { sampled.append(index) }
            return preview.isComplete
        }
        try #require(finished, "\(document): pages still loading after \(Int(HolymacTimingTests.waitLimit)) s")
        let later = run.appends.dropFirst(appendsBeforeMove)
        let endedAt = preview.pdfView.currentDestination?.point ?? .zero
        print("QL-STAYS-WHERE-MOVED \(document): moved to page \(target + 1) with \(appendsBeforeMove) append(s) in; \(later.count) later append(s); pages seen at them \(Set(later.compactMap(\.pageIndex)).sorted().map { $0 + 1 }), sampled \(Set(sampled).sorted().map { $0 + 1 }); destination point \(movedTo) → \(endedAt) at completion")

        #expect(later.count >= 1, "\(document): no append after the move")
        #expect(later.allSatisfy { $0.pageIndex == target },
                "\(document): the view left page \(target + 1) at an append — pages \(later.map { ($0.pageIndex ?? -2) + 1 })")
        #expect(sampled.allSatisfy { $0 == target },
                "\(document): the view left page \(target + 1) between appends — pages \(Set(sampled).sorted().map { $0 + 1 })")
        #expect(run.currentIndex == target, "\(document): at completion the view is on page \((run.currentIndex ?? -2) + 1)")
        #expect(later.allSatisfy { $0.selectedIndex == target },
                "\(document): the thumbnail selection left page \(target + 1) — \(later.map { ($0.selectedIndex ?? -2) + 1 })")
        #expect(run.selectedIndex == target, "\(document): at completion the thumbnail selection is page \((run.selectedIndex ?? -2) + 1)")
    }

    /// Batch 44 (M21b): what the first paint SHOWS, rendered. The view set with its document drew nothing until it was
    /// sent to a page (b44-render4: page 1 blank in its own layers, on screen, a second on), and every thumbnail read
    /// "1". Rendered here once the first paint is in: page 1's text has ink, the strip's first thumbnail holds an
    /// image with its page's white paper where the placeholder is solid grey, and the labels run 1, 2, 3…
    ///
    /// Async on purpose: the strip's thumbnails are made off the main thread and handed back on the main queue, which
    /// a test waiting by spinning the run loop from inside its own main-queue job never lets run (b44-render6: no
    /// image after 5 s). Sleeping lets it.
    @Test(arguments: ["LONG (made here)", "-HOLYMAC.WS"])
    func firstPaintShowsPageOneAndItsThumbnails(document: String) async throws {
        guard let source = try Self.source(document) else { return }
        let run = Run(bytes: source.bytes, docPath: source.path)
        defer { run.preview.cancel() }
        let preview = run.preview
        for _ in 0..<600 where !run.firstPaint.done {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(run.firstPaint.done, "\(document): the first pages never showed")
        let firstPaintPages = preview.document.pageCount
        var imageViews: [NSImageView] = []
        for _ in 0..<50 {
            imageViews = Self.visibleThumbnailImageViews(in: preview)
            if let top = imageViews.first, top.image != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let withImages = imageViews.filter { $0.image != nil }.count
        run.window.contentView?.layoutSubtreeIfNeeded()

        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let slug = document == "-HOLYMAC.WS" ? "holymac" : "long"
        let png = proofs.appendingPathComponent("m21-ql-\(slug)-first-paint.png")
        try RenderProbeKit.renderPNG(view: preview.view, appearance: NSAppearance(named: .aqua)!, to: png)
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
        let pageInk = Self.count(in: rep, of: preview.view, rect: preview.pdfView.frame) { $0 < 0.35 }
        let firstThumbnail = imageViews.first.map { preview.view.convert($0.bounds, from: $0) } ?? .zero
        let thumbnailPaper = Self.count(in: rep, of: preview.view, rect: firstThumbnail) { $0 > 0.95 }
        let thumbnailArea = Int(firstThumbnail.width * firstThumbnail.height)
        let labels = (0..<preview.document.pageCount).map { preview.document.page(at: $0)?.label ?? "nil" }
        print("QL-FIRST-PAINT-RENDER \(document): \(png.path); \(firstPaintPages) pages at the first paint; page-area ink \(pageInk) pt²; \(withImages) of \(imageViews.count) visible thumbnails hold an image; first thumbnail \(firstThumbnail) white \(thumbnailPaper) of \(thumbnailArea) pt²; labels \(labels.prefix(12))")

        let shownPage = (run.currentIndex ?? -2) + 1
        #expect(shownPage == 1, "\(document): the first paint is on page \(shownPage)")
        #expect(pageInk > 50, "\(document): page 1 drew \(pageInk) pt² of ink at the first paint — blank")
        #expect(imageViews.first?.image != nil, "\(document): the first thumbnail holds no image 5 s after the first paint")
        #expect(thumbnailPaper > thumbnailArea / 4,
                "\(document): the first thumbnail shows \(thumbnailPaper) of \(thumbnailArea) pt² of white paper — a placeholder")
        let numbers: [String] = (0..<labels.count).map { String($0 + 1) }
        let firstLabels = Array(labels.prefix(12))
        #expect(labels == numbers, "\(document): thumbnail labels \(firstLabels)…, not 1, 2, 3…")
    }

    /// The strip's thumbnail image views on screen, top first. PDFThumbnailView's items are its own; what they hold
    /// is AppKit's NSImageView.
    static func visibleThumbnailImageViews(in preview: QuickLookProgressivePreview) -> [NSImageView] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let strip = preview.view.convert(preview.thumbnails.bounds, from: preview.thumbnails)
        return descendants(preview.thumbnails).compactMap { $0 as? NSImageView }
            .map { (view: $0, frame: preview.view.convert($0.bounds, from: $0)) }
            .filter { $0.frame.height > 0 && strip.contains($0.frame) }
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .map(\.view)
    }

    /// Points of `rect` (in `view`'s coordinates) whose brightness in `rep`, `view`'s render, satisfies `test`.
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

    // MARK: - Support

    /// The preview in a window the size batch 40 timed it in, loading `bytes`, with what it showed at its first paint
    /// and at every append.
    @MainActor
    final class Run {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let preview = QuickLookProgressivePreview()
        let firstPaint = FirstPaint()
        private(set) var appends: [Append] = []

        struct Append {
            let pages: Int
            let added: Int
            let pageIndex: Int?
            let selectedIndex: Int?
        }

        init(bytes: [UInt8], docPath: String) {
            let content = window.contentView!
            content.addSubview(preview.view)
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                preview.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                preview.view.topAnchor.constraint(equalTo: content.topAnchor),
                preview.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            preview.onAppend = { [unowned self] pages in
                appends.append(Append(pages: pages, added: pages - (appends.last?.pages ?? 0),
                                      pageIndex: currentIndex, selectedIndex: selectedIndex))
            }
            preview.load(bytes: bytes, docPath: docPath, pageSettingsPreset: nil) { [unowned self] error in
                window.contentView?.layoutSubtreeIfNeeded()
                let strip = preview.thumbnails.frame
                firstPaint.done = true
                firstPaint.error = error
                firstPaint.pages = preview.document.pageCount
                firstPaint.pageIndex = currentIndex
                firstPaint.thumbnailsShowing = !preview.thumbnails.isHiddenOrHasHiddenAncestor && strip.width > 0
                    && preview.thumbnails.pdfView === preview.pdfView && preview.pdfView.document === preview.document
                firstPaint.thumbnailsTrailing = strip.minX >= preview.pdfView.frame.maxX - 0.5
                    && abs(strip.maxX - preview.view.bounds.maxX) < 0.5
                firstPaint.thumbnailsWidth = strip.width
            }
        }

        var currentIndex: Int? {
            preview.pdfView.currentPage.map { preview.document.index(for: $0) }
        }

        var selectedIndex: Int? {
            guard let selected = preview.thumbnails.selectedPages, selected.count == 1 else { return nil }
            return preview.document.index(for: selected[0])
        }
    }

    @MainActor
    final class FirstPaint {
        var done = false
        var error: Error?
        var pages = 0
        var pageIndex: Int?
        var thumbnailsShowing = false
        var thumbnailsTrailing = false
        var thumbnailsWidth: CGFloat = 0
    }

    /// A page's text with its whitespace taken out. The two captures space text differently in PDFKit's extraction:
    /// b44-r1 saw a space in one where the other had a newline, and b44-r3 saw -HOLYMAC.WS's letter-spaced title as
    /// "Ho ly" in one and "H o l y" in the other. The characters and their order are what must match.
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
    /// page — dozens of pages, so the preview makes several appends after its first paint.
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
