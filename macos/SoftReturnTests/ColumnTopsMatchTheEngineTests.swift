import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// A LATER NEWSPAPER COLUMN STARTS WHERE THE ENGINE STARTS IT (layout version 8).
///
/// Every column of a sheet begins where the `.co` region begins on that sheet, under whatever
/// title and blank the sheet opened with. The engine states that height as
/// `Page.columnTopOffsetPt`, and its own writer lowers every column reset by it (`pageStream`).
/// The Native renderer restarted each later column at the page's top, so on a sheet with a
/// prefix those columns sat the prefix's whole height too high.
///
/// The documents are the columnar ones the engine's port of that rule names, and PRINT.TST, whose
/// page 2 opens three columns under two paragraphs of prose.
@Suite(.tags(.corpus), .serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ColumnTopsMatchTheEngineTests {
    static let documents = ["WINGDING.CHT", "SYMBOL.CHT", "PRINTER.PS", "MICKEE.WS", "LSRBOX.WS", "PRINT.TST"]

    @MainActor
    static func fixture(_ name: String) throws -> URL {
        try #require(Oracle.allFixtureURLs.first { $0.lastPathComponent == name },
                     "\(name) is not in the fixture set")
    }

    /// Where the evidence goes: the app-test drop box when the host can write there, as the
    /// pixel oracle's own report does, and the test's temporary directory otherwise.
    @MainActor
    static var evidenceDirectory: URL {
        RenderProbeKit.resolveOutputDirectory(
            preferred: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/coder-apptest/column-tops",
                                        isDirectory: true),
            fallbackName: "column-tops")
    }

    /// EVERY LATER COLUMN'S FIRST BASELINE IS THE ENGINE PDF'S, on every columnar page.
    ///
    /// Both sides are asked for the column's first line of TEXT ink. The engine draws box and
    /// block characters as vector fills, so a column opening with one has no text operator
    /// there, and `Oracle.Line.hasTextInk` skips the same lines on the app's side. The engine's
    /// column is the band from its lines' own `left` across `columnWidthPt`.
    @Test(arguments: documents) @MainActor
    func laterColumnsStartOnTheEnginesBaseline(doc: String) throws {
        let url = try Self.fixture(doc)
        let state = try Oracle.state(for: url)
        let model = Oracle.pagelines(of: state)
        let (rendered, view, _) = Oracle.layOut(state)
        let enginePDF = try AppAnswerKeyParityTests.documentOperationsBytes(
            fixture: url, format: "pdf", mode: .printed,
            title: "", fontsTarget: .office, pictures: .embed)

        var measured: [String] = []
        var wrong: [String] = []
        for (index, page) in model.enumerated() where (page.columns ?? 1) > 1 && index < view.pageCount {
            let runs = AppPDFWords.inkRunsByBaseline(from: enginePDF, page: index + 1)
            let columnViews = view.columnTextViews(atPage: index)
            let offset = page.columnTopOffsetPt ?? 0
            // The region's own top on this sheet: the page's top, from its own `.mt` as the
            // renderer takes it, plus the offset. Ink above it belongs to no column: a running
            // head, or the title and blank the sheet opened with, which crosses the column bands
            // (WINGDING.CHT's title reads in column 2's band, MICKEE.WS's running head in all).
            let pageDoc = page.mtLines != nil || page.mbLines != nil
                ? DocumentRenderer.effectivePageDoc(state.document, for: page) : state.document
            let regionTop = printedMetrics(pageDoc).top + offset
            for column in 1..<(page.columns ?? 1) {
                let place = "page \(index + 1) column \(column + 1)"
                guard let left = page.lines.filter({ $0.col == column }).compactMap(\.left).min()
                else { continue }
                guard columnViews.indices.contains(column - 1) else {
                    wrong.append("\(place): the app laid out no text view for it")
                    continue
                }
                let right = left + (page.columnWidthPt ?? 0)
                let engineTop = runs
                    .filter { $0.key > regionTop && $0.value.contains { $0.x >= left - 0.5 && $0.x < right } }
                    .keys.min()
                let textView = columnViews[column - 1]
                guard let manager = textView.layoutManager, let container = textView.textContainer
                else { continue }
                manager.ensureLayout(for: container)
                let laidOut = Oracle.LaidOutPage(textView: textView, manager: manager,
                                                 container: container,
                                                 glyphs: manager.glyphRange(for: container))
                // The baseline where the view actually DRAWS it: the glyph's location through
                // the column's own text view into the page's rectangle. `Oracle.Line.baseline`
                // adds the document's text frame instead, which is the page's top only on a
                // page with no `.mt` of its own (LSRBOX.WS page 7 sets `.mt .35"`).
                let pageRect = view.rect(ofPage: index)
                let appTop = Oracle.lines(of: laidOut, textFrame: rendered.textFrame)
                    .first { $0.hasTextInk }
                    .map { line -> Double in
                        let fragment = manager.lineFragmentRect(forGlyphAt: line.glyphs.location,
                                                                effectiveRange: nil)
                        let glyph = manager.location(forGlyphAt: line.glyphs.location)
                        let origin = textView.textContainerOrigin
                        let inView = view.convert(
                            NSPoint(x: origin.x + fragment.minX + glyph.x,
                                    y: origin.y + fragment.minY + glyph.y),
                            from: textView)
                        return Double(view.isFlipped ? inView.y - pageRect.minY : pageRect.maxY - inView.y)
                    }
                guard let engineTop, let appTop else {
                    wrong.append("\(place): nothing to compare, engine \(engineTop.map { "\($0)" } ?? "no text ink"), "
                                 + "app \(appTop.map { "\($0)" } ?? "no text ink")")
                    continue
                }
                let row = "\(place): app \(String(format: "%.2f", appTop)), "
                    + "engine \(String(format: "%.2f", engineTop)), region offset \(offset), "
                    + "region top \(String(format: "%.2f", regionTop))"
                measured.append(row)
                if abs(appTop - engineTop) > 0.5 { wrong.append(row) }
            }
        }
        print("COLUMN TOPS \(doc): \(measured.count) later column(s) compared\n  "
              + measured.joined(separator: "\n  "))
        #expect(!measured.isEmpty, """
            \(doc): no later column was compared. The engine's model has no columnar page the \
            app laid out, so this measured nothing.
            """)
        #expect(wrong.isEmpty, """
            \(doc): \(wrong.count) later column(s) do not start on the engine PDF's baseline:
              \(wrong.prefix(12).joined(separator: "\n  "))
            """)
    }

    /// DIAGNOSTIC, asserts only that both sides have the same pages: the Native view's pixel
    /// regions against the engine's PDF, per page, printed so that a render change can be
    /// compared before and after (the pixel oracle's own method and calibration).
    @Test(arguments: documents) @MainActor
    func nativePixelRegionsAgainstTheEngine(doc: String) throws {
        let url = try Self.fixture(doc)
        let actual = try PixelOracleAppEngine.renderApp(fixtureURL: url)
        let reference = try PixelOracleAppEngine.renderEngine(fixtureURL: url)
        try #require(actual.count == reference.count,
                     "\(doc): the app has \(actual.count) page(s), the engine \(reference.count)")
        let output = Self.evidenceDirectory.appendingPathComponent("regions-\(doc)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report = try PixelOracleKit.compareFixture(
            fixture: doc, actual: actual, reference: reference, outputDirectory: output, attach: false)
        let perPage = report.pages.map { "\($0.page)=\($0.findings.count)" }.joined(separator: " ")
        let byClass = Dictionary(grouping: report.findings, by: \.regionClass)
            .map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", ")
        print("NATIVE REGIONS \(doc): \(report.findings.count) region(s) over \(report.pages.count) "
              + "page(s) [\(byClass)] — \(perPage)")
    }

    /// DIAGNOSTIC, asserts nothing: PRINT.TST pages 2 and 3, every baseline of the engine's
    /// Printed PDF beside the app's Native PDF, with the first x and the text on it. These are the
    /// two PDFs `theAppPaginatesExactlyLikeTheLibrary` reads its lines from.
    @Test @MainActor func printTstBaselinesDiagnostic() throws {
        let url = try Self.fixture("PRINT.TST")
        let state = try Oracle.state(for: url)
        let model = Oracle.pagelines(of: state)
        let enginePDF = emitPDF(state.document, mode: .printed,
                                options: EmitOptions(pixResults: DocumentPictures.resolve(
                                    state.document, docPath: url.path)))
        let appPDF = try Oracle.appNativePDF(for: url, state: state)
        func show(_ runs: [(x: Double, text: Character)]?) -> String {
            guard let runs, let first = runs.first else { return "-" }
            return "x\(String(format: "%.1f", first.x)) \(String(String(runs.map(\.text)).prefix(60)))"
        }
        for page in [2, 3] where page <= model.count {
            let sheet = model[page - 1]
            let perColumn = (0..<max(1, sheet.columns ?? 1)).map { column in
                sheet.lines.filter { ($0.col ?? 0) == column }.count
            }
            print("PRINTTST page \(page): columns \(sheet.columns ?? 1), offset "
                  + "\(sheet.columnTopOffsetPt ?? 0), lines per column \(perColumn)")
            let engine = AppPDFWords.inkRunsByBaseline(from: enginePDF, page: page)
            let app = AppPDFWords.inkRunsByBaseline(from: appPDF, page: page)
            for y in Set(engine.keys).union(app.keys).sorted() {
                print("PRINTTST p\(page) y\(String(format: "%6.1f", y)) | engine \(show(engine[y])) | app \(show(app[y]))")
            }
        }
    }

    /// EVIDENCE, asserts only that it wrote: WINGDING.CHT page 1 from the top of the sheet
    /// through its title and the first rows of the columns, across columns 1 and 2, from the
    /// Native view and from the engine's PDF, and the two side by side (Native left).
    @Test @MainActor func wingdingPageOneColumnTwoCrop() throws {
        let url = try Self.fixture("WINGDING.CHT")
        let state = try Oracle.state(for: url)
        let first = try #require(Oracle.pagelines(of: state).first, "WINGDING.CHT laid out no pages")
        try #require((first.columns ?? 1) >= 2, "WINGDING.CHT page 1 has no second column")
        let lefts = [0, 1].compactMap { column in
            first.lines.filter { $0.col == column }.compactMap(\.left).min()
        }
        try #require(lefts.count == 2, "WINGDING.CHT page 1 states no left for its first two columns")
        let metrics = printedMetrics(state.document)
        let x = max(0, lefts[0] - 12)
        let cropPt = CGRect(x: x, y: 0,
                            width: lefts[1] + (first.columnWidthPt ?? 72) + 12 - x,
                            height: metrics.top + (first.columnTopOffsetPt ?? 0) + 200)

        let app = try #require(try PixelOracleAppEngine.renderApp(fixtureURL: url).first)
        let engine = try #require(try PixelOracleAppEngine.renderEngine(fixtureURL: url).first)
        let crops = try [app, engine].map { image -> CGImage in
            let cg = try #require(image.bitmap.cgImage, "\(image.label) has no CGImage")
            let scale = CGFloat(cg.width) / image.pointSize.width
            let pixels = CGRect(x: cropPt.minX * scale, y: cropPt.minY * scale,
                                width: cropPt.width * scale, height: cropPt.height * scale).integral
            return try #require(cg.cropping(to: pixels), "\(image.label) did not crop to \(pixels)")
        }

        let directory = Self.evidenceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (crop, name) in zip(crops, ["native", "engine"]) {
            let png = try #require(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("WINGDING-p1-col2-\(name).png"))
        }

        let gap = 16
        let width = crops[0].width + gap + crops[1].width
        let height = max(crops[0].height, crops[1].height)
        let canvas = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: canvas)?.cgContext)
        context.setFillColor(NSColor.systemGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(crops[0], in: CGRect(x: 0, y: height - crops[0].height,
                                          width: crops[0].width, height: crops[0].height))
        context.draw(crops[1], in: CGRect(x: crops[0].width + gap, y: height - crops[1].height,
                                          width: crops[1].width, height: crops[1].height))
        let sideBySide = try #require(canvas.representation(using: .png, properties: [:]))
        let target = directory.appendingPathComponent("WINGDING-p1-col2-side-by-side.png")
        try sideBySide.write(to: target)
        print("COLUMN CROP WINGDING.CHT page 1: \(cropPt) pt, offset \(first.columnTopOffsetPt ?? 0), written to \(directory.lastPathComponent)/")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
