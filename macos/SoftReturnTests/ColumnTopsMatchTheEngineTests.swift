import AppKit
import CtrlKD
import Foundation
@testable import SoftReturnRendering
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
}
