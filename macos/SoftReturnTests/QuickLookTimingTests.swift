import AppKit
import CtrlKD
import Darwin
import Foundation
import PDFKit
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 28 (#271 M10): what the Quick Look extensions cost, on a long document and a short one.
///
/// A test cannot load `SoftReturnQuickLook` or `SoftReturnThumbnail` (see `QuickLookExtensionTests`), so this runs the
/// providers' work in-process, through the functions both extensions call: `QuickLookNativeRenderer.thumbnail`
/// (Finder's icon, page 1) and `QuickLookNativeRenderer.previewPDF` (the spacebar preview, every page as one PDF).
/// Each request is timed from reading the file to the reply's bytes, with the process's peak physical footprint —
/// the figure the system's memory limits count — above where it started, sampled every millisecond on another
/// thread. A third pass, a replica of the same calls, splits the work into its stages: the parse, the engine's
/// pagination, the text, the page layout, page 1's PDF and bitmap, and every page's PDF.
///
/// Hosted in the app, so the fonts and frameworks an extension loads on its first request are loaded already:
/// "cold" is the first request for that document in this process, not an extension's first launch.
///
/// The figures print as one `QUICKLOOK-TIMING <json>` line and one `QUICKLOOK-TIMING-SUMMARY` line per
/// measurement; the test writes nothing to disk and reads both documents where they are.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct QuickLookTimingTests {
    struct Stage: Codable {
        let name: String
        let milliseconds: Double
    }

    struct Measurement: Codable {
        let document: String
        /// "thumbnail", "preview", or "stages" (the replica pass).
        let request: String
        /// "cold" or "warm"; "replica" for the stages.
        let pass: String
        let bytes: Int
        /// The pages in the reply: 1 for a thumbnail, the PDF's pages for a preview, the pages laid out for the stages.
        let pages: Int
        /// From reading the file to the reply's bytes.
        let milliseconds: Double
        /// The process's physical footprint when the request started.
        let footprintAtStartMegabytes: Double
        /// The highest footprint sampled while it ran, above the footprint at its start.
        let peakFootprintAboveStartMegabytes: Double
        /// The PDF's size, or the bitmap's (width × height × 4).
        let replyBytes: Int
        let stages: [Stage]
    }

    /// The size a thumbnail is asked for here; `QuickLookNativeRenderer.thumbnail` caps what it draws at 1024.
    static let thumbnailRequestSize = CGSize(width: 1024, height: 1024)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func quickLookRequestTimings() throws {
        let holymac = try #require(PrivateCorpusSupport.sawyerArchiveRoot)
            .appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        try #require(FileManager.default.fileExists(atPath: holymac.path), "no -HOLYMAC.WS in the Sawyer archive")
        let lying = Self.sampleDocumentsDirectory.appendingPathComponent("LYING.WS")
        try #require(FileManager.default.fileExists(atPath: lying.path), "no bundled LYING.WS")

        var measurements: [Measurement] = []
        let documents = CorpusDocumentFilter.apply([("LYING.WS", lying), ("-HOLYMAC.WS", holymac)], name: { $0.0 })
        for (name, url) in documents {
            for pass in ["cold", "warm"] {
                measurements.append(try Self.measureThumbnail(name, url, pass: pass))
                measurements.append(try Self.measurePreview(name, url, pass: pass))
            }
            measurements.append(try Self.measureStages(name, url))
        }
        for measurement in measurements {
            print("QUICKLOOK-TIMING-SUMMARY \(Self.summary(measurement))")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("QUICKLOOK-TIMING \(String(decoding: try encoder.encode(measurements), as: UTF8.self))")

        #expect(measurements.allSatisfy { $0.replyBytes > 0 }, "a request produced no reply")
        for measurement in measurements where measurement.document == "-HOLYMAC.WS" && measurement.request != "thumbnail" {
            #expect(measurement.pages > 250, "-HOLYMAC.WS \(measurement.request) \(measurement.pass): \(measurement.pages) pages")
        }
    }

    // MARK: - The requests

    static func measureThumbnail(_ name: String, _ url: URL, pass: String) throws -> Measurement {
        let sampler = QuickLookFootprintSampler()
        sampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let (bytes, thumbnail) = try autoreleasepool { () throws -> ([UInt8], (image: CGImage, size: CGSize)) in
            let bytes = [UInt8](try Data(contentsOf: url))
            // `pageSettingsPreset: nil`: this machine's app-group default, whatever it holds, does not decide the figure.
            return (bytes, try QuickLookNativeRenderer.thumbnail(fromFileBytes: bytes, docPath: url.path,
                                                                 maximumSize: thumbnailRequestSize,
                                                                 pageSettingsPreset: nil))
        }
        let milliseconds = Self.milliseconds(since: start)
        let footprint = sampler.stop()
        return Measurement(document: name, request: "thumbnail", pass: pass, bytes: bytes.count, pages: 1,
                           milliseconds: milliseconds, footprintAtStartMegabytes: footprint.start,
                           peakFootprintAboveStartMegabytes: footprint.peakAboveStart,
                           replyBytes: thumbnail.image.width * thumbnail.image.height * 4, stages: [])
    }

    static func measurePreview(_ name: String, _ url: URL, pass: String) throws -> Measurement {
        let sampler = QuickLookFootprintSampler()
        sampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let (bytes, preview) = try autoreleasepool { () throws -> ([UInt8], (pdf: Data, pageSize: CGSize)) in
            let bytes = [UInt8](try Data(contentsOf: url))
            return (bytes, try QuickLookNativeRenderer.previewPDF(fromFileBytes: bytes, docPath: url.path,
                                                                  pageSettingsPreset: nil))
        }
        let milliseconds = Self.milliseconds(since: start)
        let footprint = sampler.stop()
        let pages = PDFDocument(data: preview.pdf)?.pageCount ?? 0
        return Measurement(document: name, request: "preview", pass: pass, bytes: bytes.count, pages: pages,
                           milliseconds: milliseconds, footprintAtStartMegabytes: footprint.start,
                           peakFootprintAboveStartMegabytes: footprint.peakAboveStart,
                           replyBytes: preview.pdf.count, stages: [])
    }

    /// Both requests' work split into its stages: a replica of `renderedDocument` (whose `DocumentRenderer.render`
    /// is `nativeRenderSession` rendered whole), `firstPage` with `thumbnail`'s bitmap, and `multiPagePDF`, through
    /// the calls they make.
    static func measureStages(_ name: String, _ url: URL) throws -> Measurement {
        var stages: [Stage] = []
        let sampler = QuickLookFootprintSampler()
        sampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        var mark = start
        func lap(_ stage: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            stages.append(Stage(name: stage, milliseconds: Double(now - mark) / 1_000_000))
            mark = now
        }

        let bytes = [UInt8](try Data(contentsOf: url))
        lap("read")
        let defaults = UserDefaults(suiteName: "QuickLookTimingTests.\(UUID().uuidString)") ?? .standard
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.native)
        lap("parse")
        let work = NativeEngineWork.make(document: state.document, options: DocumentRenderer.nativeEngineOptions(state),
                                         pictures: true)
        lap("engine")
        let session = DocumentRenderer.nativeRenderSession(state, engine: work)
        session.renderAll()
        let rendered = session.snapshot(final: true)
        lap("text")
        let pagedView = PagedDocumentView(frame: .zero)
        pagedView.setContent(rendered, display: .continuousScroll)
        pagedView.setFrameSize(pagedView.intrinsicContentSize)
        pagedView.layoutSubtreeIfNeeded()
        lap("layout")

        var replyBytes = 0
        let firstRect = pagedView.rect(ofPage: 0)
        let firstPageData = pagedView.dataWithPDF(inside: firstRect)
        lap("page 1 PDF")
        if let page = PDFDocument(data: firstPageData)?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(thumbnailRequestSize.width / bounds.width, thumbnailRequestSize.height / bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let context = CGContext(data: nil, width: max(1, Int(size.width.rounded(.up))),
                                       height: max(1, Int(size.height.rounded(.up))), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                replyBytes = (context.makeImage().map { $0.width * $0.height * 4 }) ?? 0
            }
        }
        lap("page 1 bitmap")

        let combined = PDFDocument()
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            autoreleasepool {
                pagedView.capturingPageIndex = index
                let onePageData = pagedView.dataWithPDF(inside: rect)
                pagedView.capturingPageIndex = nil
                if let onePagePDF = PDFDocument(data: onePageData), let page = onePagePDF.page(at: 0) {
                    combined.insert(page, at: combined.pageCount)
                }
            }
        }
        lap("every page's PDF")
        let pdf = combined.dataRepresentation() ?? Data()
        lap("PDF written")

        let milliseconds = Self.milliseconds(since: start)
        let footprint = sampler.stop()
        return Measurement(document: name, request: "stages", pass: "replica", bytes: bytes.count,
                           pages: pagedView.pageCount, milliseconds: milliseconds,
                           footprintAtStartMegabytes: footprint.start,
                           peakFootprintAboveStartMegabytes: footprint.peakAboveStart,
                           replyBytes: replyBytes + pdf.count, stages: stages)
    }

    // MARK: - Support

    static func summary(_ measurement: Measurement) -> String {
        var line = "\(measurement.document) \(measurement.request) \(measurement.pass): \(measurement.bytes) bytes, "
        line += "\(measurement.pages) pages, \(Int(measurement.milliseconds.rounded())) ms, peak footprint "
        line += String(format: "+%.1f MB over %.1f MB", measurement.peakFootprintAboveStartMegabytes,
                       measurement.footprintAtStartMegabytes)
        line += ", reply \(measurement.replyBytes) bytes"
        if !measurement.stages.isEmpty {
            line += "; " + measurement.stages.map { "\($0.name) \(Int($0.milliseconds.rounded())) ms" }
                .joined(separator: ", ")
        }
        return line
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// The app's bundled sample documents, read in place.
    static var sampleDocumentsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("SoftReturn/Resources/SampleDocuments")
    }
}

/// Batch 28: the process's physical footprint, sampled every millisecond on its own thread while a request runs.
final class QuickLookFootprintSampler: @unchecked Sendable {
    struct Result {
        /// Megabytes when sampling started.
        let start: Double
        /// Megabytes above `start` at the highest sample.
        let peakAboveStart: Double
    }

    private let lock = NSLock()
    private var startFootprint: UInt64 = 0
    private var peak: UInt64 = 0
    private var running = false

    static func footprint() -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }

    func start() {
        let now = Self.footprint()
        lock.lock()
        startFootprint = now
        peak = now
        running = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            while sample() {
                usleep(1_000)
            }
        }
    }

    /// One sample; false once `stop` has been called.
    private func sample() -> Bool {
        let now = Self.footprint()
        lock.lock()
        defer { lock.unlock() }
        peak = max(peak, now)
        return running
    }

    func stop() -> Result {
        let now = Self.footprint()
        lock.lock()
        defer { lock.unlock() }
        running = false
        peak = max(peak, now)
        let megabyte = 1_048_576.0
        return Result(start: Double(startFootprint) / megabyte,
                      peakAboveStart: Double(peak - startFootprint) / megabyte)
    }
}
