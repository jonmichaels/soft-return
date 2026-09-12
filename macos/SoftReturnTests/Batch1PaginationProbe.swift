import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// A DIAGNOSTIC, not a gate: the two line lists, side by side, for every row the pagination
/// oracle is currently reporting.
///
/// `theAppPaginatesExactlyLikeTheLibrary` says WHICH line differs and prints 40 characters of
/// each side. That is enough to see a row and never enough to see its CAUSE — the cause is
/// always in the lines AROUND it (a line the app has and the engine does not shifts every
/// ordinal after it, and the 40-character window then shows two unrelated lines). Reading
/// both whole pages beside each other turns a row into a diagnosis in one look, which is what
/// this writes out.
///
/// It also dumps the engine's own `PageLine` model beside the app's laid-out FRAGMENTS for a
/// named handful of documents, because the grid oracles compare those two and a mismatch
/// between them (a picture's reserved band that one side counts as lines and the other does
/// not) cannot be read from either alone.
///
/// Writes into the drop box directory, the one place both sides of the fence can reach.
/// Asserts nothing, so it cannot fail a run.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Batch1PaginationProbe {

    static var dumpDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/coder-apptest/batch1",
                                    isDirectory: true)
    }

    /// The documents whose model-vs-fragment listing is dumped in full. Named rather than
    /// derived: this half of the probe is for a question already asked about a specific
    /// document, and dumping every fixture's fragments would write tens of megabytes.
    static let modelDocuments: [(name: String, page: Int)] = [
        ("MICKEE.WS", 14), ("MARKUP.WS", 0), ("PRINTER.PS", 0),
    ]

    @Test @MainActor func dumpPaginationRowsWithBothPagesInFull() throws {
        let directory = Self.dumpDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rows: [String] = []
        var report = ""
        for url in Oracle.fixtureURLs {
            guard let state = try? Oracle.state(for: url) else { continue }
            let enginePDF = emitPDF(state.document, mode: .printed,
                                    options: EmitOptions(pixResults: DocumentPictures.resolve(
                                        state.document, docPath: url.path)))
            guard let appPDF = try? Oracle.appNativePDF(for: url, state: state),
                  let engineLines = try? AppModernFidelityTests.lines(of: enginePDF),
                  let appLines = try? AppModernFidelityTests.lines(of: appPDF)
            else { continue }

            let name = url.lastPathComponent
            if appLines.count != engineLines.count {
                rows.append("\(name): app \(appLines.count) page(s), library \(engineLines.count)")
                report += "\n### \(name) — PAGE COUNT app=\(appLines.count) "
                    + "library=\(engineLines.count)\n"
                continue
            }
            for (index, wantedPageRaw) in engineLines.enumerated() {
                if Oracle.isFontChart(name, page: index + 1) { continue }
                let wantedPage = wantedPageRaw.filter { !Oracle.EngineText.isAllGeometry($0) }
                let gotPage = appLines[index].filter { !Oracle.EngineText.isAllGeometry($0) }
                var pageRows: [String] = []
                for (n, wanted) in wantedPage.enumerated() where n < gotPage.count {
                    if !Oracle.EngineText.sameLine(app: gotPage[n], library: wanted) {
                        pageRows.append("line \(n)")
                        break
                    }
                }
                if gotPage.count != wantedPage.count {
                    pageRows.append("app \(gotPage.count) line(s), library \(wantedPage.count)")
                }
                guard !pageRows.isEmpty else { continue }
                rows.append("\(name) page \(index + 1): \(pageRows.joined(separator: "; "))")
                // BOTH PAGES IN FULL, numbered, so an inserted or dropped line is visible as
                // the shift it is rather than as one mismatched ordinal.
                report += "\n### \(name) page \(index + 1) — \(pageRows.joined(separator: "; "))\n"
                report += "    (\(url.deletingLastPathComponent().lastPathComponent)/)\n"
                for n in 0..<max(gotPage.count, wantedPage.count) {
                    let got = n < gotPage.count ? gotPage[n] : "<none>"
                    let wanted = n < wantedPage.count ? wantedPage[n] : "<none>"
                    let flag = Oracle.EngineText.sameLine(app: got, library: wanted) ? "  " : "!!"
                    report += String(format: "%@ %3d app  %@\n", flag, n, got.debugDescription)
                    report += String(format: "%@ %3d lib  %@\n", flag, n, wanted.debugDescription)
                }
            }
        }

        let header = "\(rows.count) row(s)\n" + rows.joined(separator: "\n") + "\n"
        try (header + report).write(to: directory.appendingPathComponent("rows.txt"),
                                    atomically: true, encoding: .utf8)
    }

    /// The engine's `PageLine` model beside the app's laid-out fragments, page 1.
    ///
    /// The grid oracles index one by the other's ordinal, so what this answers is whether the
    /// two lists are the same length and in the same order — which is exactly what a picture's
    /// reserved band, an overprint chain and a newspaper column each break in a different way.
    @Test @MainActor func dumpModelBesideFragments() throws {
        let directory = Self.dumpDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var report = ""
        for url in Oracle.fixtureURLs
        where Self.modelDocuments.contains(where: { $0.name == url.lastPathComponent }) {
            let wantedPage = Self.modelDocuments.first { $0.name == url.lastPathComponent }?.page ?? 0
            let state = try Oracle.state(for: url)
            let metrics = printedMetrics(state.document)
            let withPix = Oracle.pagelines(of: state)
            let withoutPix = docToPagelines(state.document, printed: true)
            let (rendered, view, pages) = Oracle.layOut(state)

            report += "\n=== \(url.lastPathComponent)  (\(url.deletingLastPathComponent().lastPathComponent)/)\n"
            report += "    top=\(metrics.top) lead=\(metrics.lead) size=\(metrics.size) "
                + "capacity=\(metrics.capacity) textFrame.y=\(rendered.textFrame.origin.y)\n"
            report += "    pixResults=\(state.pixResults.count) resolved="
                + "\(state.pixResults.filter(\.ok).count) "
                + "pages: model(pix)=\(withPix.count) model(no pix)=\(withoutPix.count) "
                + "app=\(pages.count)\n"

            let modelLines = withPix.indices.contains(wantedPage) ? withPix[wantedPage].lines : []
            let plainLines = withoutPix.indices.contains(wantedPage) ? withoutPix[wantedPage].lines : []
            report += "  -- engine model page \(wantedPage + 1), WITH pictures (\(modelLines.count) lines) --\n"
            for (index, line) in modelLines.enumerated() {
                let text = line.spans.map(\.text).joined()
                report += String(format: "  m%3d lead=%@ image=%@ overprint=%@ %@\n", index,
                                 line.lead.map { String(format: "%.2f", $0) } ?? "nil",
                                 line.image.map { String(format: "%.2fx%.2f", $0.widthPt, $0.heightPt) } ?? "-",
                                 line.overprint ? "Y" : "n", text.prefix(56).debugDescription)
            }
            report += "  -- engine model page \(wantedPage + 1), WITHOUT pictures (\(plainLines.count) lines) --\n"
            for (index, line) in plainLines.prefix(12).enumerated() {
                let text = line.spans.map(\.text).joined()
                report += String(format: "  p%3d lead=%@ %@\n", index,
                                 line.lead.map { String(format: "%.2f", $0) } ?? "nil",
                                 text.prefix(56).debugDescription)
            }
            // THE BYTES THEMSELVES, both sides, so a font/encoding question can be read
            // straight out of the content streams instead of inferred from what the word
            // reader made of them.
            let stem = url.lastPathComponent.replacingOccurrences(of: ".", with: "_")
                + "-" + url.deletingLastPathComponent().lastPathComponent
            if let appPDF = try? Oracle.appNativePDF(for: url, state: state) {
                try? Data(appPDF).write(to: directory.appendingPathComponent("\(stem)-app.pdf"))
            }
            let enginePDF = emitPDF(state.document, mode: .printed,
                                    options: EmitOptions(pixResults: DocumentPictures.resolve(
                                        state.document, docPath: url.path)))
            try? Data(enginePDF).write(to: directory.appendingPathComponent("\(stem)-engine.pdf"))

            // EVERY COLUMN OF THE PAGE, with the height each container was given and the
            // model's own answer for how many fragments it should hold. A page's second and
            // later columns are their own containers, and a container too short for its own
            // column simply loses the tail of it.
            report += "    model column counts: "
                + "\(rendered.pageColumnFragmentCounts.indices.contains(wantedPage) ? rendered.pageColumnFragmentCounts[wantedPage] : [])"
                + "  pinned bottoms: "
                + "\(rendered.pinnedPageBottoms.indices.contains(wantedPage) ? rendered.pinnedPageBottoms[wantedPage] : [])\n"
            var columnViews: [NSTextView] = []
            if view.pageViews.indices.contains(wantedPage) { columnViews.append(view.pageViews[wantedPage]) }
            columnViews.append(contentsOf: view.columnTextViews(atPage: wantedPage))
            for (column, textView) in columnViews.enumerated() {
                guard let manager = textView.layoutManager, let container = textView.textContainer
                else { continue }
                manager.ensureLayout(for: container)
                let laid = Oracle.LaidOutPage(textView: textView, manager: manager,
                                              container: container,
                                              glyphs: manager.glyphRange(for: container))
                let own = Oracle.lines(of: laid, textFrame: rendered.textFrame)
                report += String(format: "  column %d: container %.2f x %.2f, %d fragment(s)"
                                 + ", first baseline %.2f, last %.2f\n",
                                 column, Double(container.size.width), Double(container.size.height),
                                 own.count, Double(own.first?.baseline ?? -1),
                                 Double(own.last?.baseline ?? -1))
            }
            // AND THE SAME PAGE THROUGH THE EXPORT'S OWN VIEW, which is where the rows are.
            // `ExportEngine.appKitRenderedPDF` builds its own `PagedDocumentView` and then
            // does two things `Oracle.layOut` never does — `setFrameSize(intrinsicContentSize)`
            // and `layoutSubtreeIfNeeded()` — so its containers and its subview frames are
            // the ones a capture actually sees.
            let exportRendered = DocumentRenderer.render(state, style: .native)
            let exportView = PagedDocumentView()
            exportView.setContent(exportRendered, display: .continuousScroll)
            exportView.setFrameSize(exportView.intrinsicContentSize)
            exportView.layoutSubtreeIfNeeded()
            report += String(format: "  EXPORT view: frame %.2f x %.2f, page rect %@\n",
                             Double(exportView.frame.width), Double(exportView.frame.height),
                             NSStringFromRect(exportView.rect(ofPage: wantedPage)))
            var exportColumns: [NSTextView] = []
            if exportView.pageViews.indices.contains(wantedPage) {
                exportColumns.append(exportView.pageViews[wantedPage])
            }
            exportColumns.append(contentsOf: exportView.columnTextViews(atPage: wantedPage))
            for (column, textView) in exportColumns.enumerated() {
                guard let manager = textView.layoutManager, let container = textView.textContainer
                else { continue }
                manager.ensureLayout(for: container)
                let laid = Oracle.LaidOutPage(textView: textView, manager: manager,
                                              container: container,
                                              glyphs: manager.glyphRange(for: container))
                let own = Oracle.lines(of: laid, textFrame: exportRendered.textFrame)
                report += String(format: "  EXPORT column %d: view frame %@, container %.2f x %.2f"
                                 + ", %d fragment(s), last baseline %.2f\n",
                                 column, NSStringFromRect(textView.frame),
                                 Double(container.size.width), Double(container.size.height),
                                 own.count, Double(own.last?.baseline ?? -1))
            }

            if pages.indices.contains(wantedPage) {
                let first = pages[wantedPage]
                let lines = Oracle.lines(of: first, textFrame: rendered.textFrame)
                report += "  -- app fragments page \(wantedPage + 1) (\(lines.count)), "
                    + "container height \(first.container.size.height) --\n"
                for line in lines {
                    report += String(format: "  a%3d top=%.2f baseline=%.2f hasText=%@ %@\n",
                                     line.index, Double(line.top), Double(line.baseline),
                                     line.hasText ? "Y" : "n",
                                     Oracle.lineText(of: first, glyphs: line.glyphs, limit: 56)
                                         .debugDescription)
                }
            }
        }
        try report.write(to: directory.appendingPathComponent("model-vs-fragments.txt"),
                         atomically: true, encoding: .utf8)
    }
}
