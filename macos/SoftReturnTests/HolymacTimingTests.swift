import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// #271 M7: where opening -HOLYMAC.WS (the private corpus's Sawyer archive; 302 pages, 538 KB), turning its
/// pages and switching its view spend their time, against the bundled LYING.WS as the baseline.
///
/// Each document opens through the app's own path — `WSDocument.read`, a `DocumentWindowController` with the
/// app's progressive open, `showWindow`, the pages drawn — twice: cold (the first open of it in this process)
/// and warm (the second). The view is Native, set on the document before its window is built, whatever this
/// host's Default View says. The test times the open until the window is on screen, until the first pages are
/// drawn and until every page is laid out; then the Go menu's `goToPage(index:)` turns to page 2, the middle
/// page and the last page, each followed by a draw; then the window switches to Printed, Modern, Native,
/// Printed and Modern, timing each switch until it is laid out and drawn. `PerformanceSignposts` records every
/// interval the app marks along the way.
///
/// Batch 26: how long the MAIN THREAD stays busy in one stretch once the window is on screen (Athena's target:
/// no stretch over 100 ms). `BlockMonitor` times every call the test makes on the main thread whole, and every
/// turn of the run loop while it waits — a turn runs whatever the app queued for it, so a turn's length less
/// its idle wait is that work's length. Nothing is sampled; a stretch is either one call or one turn.
///
/// What the fixes promise, checked here:
/// - a long document's first pages are drawn before the rest are laid out;
/// - once laid out, the pages are exactly the synchronous render's;
/// - going back to a style already shown runs none of its whole-document passes again;
/// - no main-thread stretch after the window shows lasts 100 ms or more.
///
/// The figures print as one `HOLYMAC-TIMING <json>` line, plus one readable `HOLYMAC-TIMING-SUMMARY` line per
/// open; the test writes nothing to disk. Both documents are copied into a scratch folder and opened from
/// there, never in place.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct HolymacTimingTests {
    struct PageChange: Codable {
        let toPage: Int
        let untilDrawnMilliseconds: Double
        let intervals: [PerformanceSignposts.Interval]
    }

    struct StyleSwitch: Codable {
        let to: String
        /// Batch 27: from the switch to the first page of the new content drawn — a preview, a first page, or the
        /// whole content when it comes all at once.
        let untilFirstPageMilliseconds: Double
        let untilDrawnMilliseconds: Double
        let intervals: [PerformanceSignposts.Interval]
    }

    /// One step of the tour after the page changes: a style, or Show Invisibles turned on or off (batch 27).
    enum Step {
        case style(ViewStyle)
        case invisibles(Bool)

        var name: String {
            switch self {
            case .style(let style): return style.displayName
            case .invisibles(let on): return on ? "Show Invisibles on" : "Show Invisibles off"
            }
        }
    }

    /// One stretch the main thread spent busy: what the test was doing, and for how long.
    struct MainThreadBlock: Codable {
        let what: String
        let milliseconds: Double
    }

    struct Open: Codable {
        let document: String
        let pass: String
        let bytes: Int
        let pages: Int
        let view: String
        let display: String
        /// From reading the file to the window on screen.
        let untilWindowShownMilliseconds: Double
        /// From reading the file to the first pages drawn.
        let untilDrawnMilliseconds: Double
        /// From reading the file to every page laid out.
        let untilAllPagesMilliseconds: Double
        /// The longest single main-thread interval the app marks for its own load work after the first pages
        /// were shown: a slice of text rendered, a slice of pages laid out, the render finished (`loadIntervals`).
        let longestBlockAfterFirstPagesMilliseconds: Double
        /// The longest the main thread was busy in one stretch after the window was on screen — over the open,
        /// the page changes and the style switches — and what it was.
        let longestMainThreadBlock: MainThreadBlock
        /// Every stretch of 100 ms or more after the window was on screen, in order.
        let mainThreadBlocksOver100ms: [MainThreadBlock]
        let intervals: [PerformanceSignposts.Interval]
        let pageChanges: [PageChange]
        let styleSwitches: [StyleSwitch]
    }

    /// The intervals that are a whole-document pass: the engine's pagination or flow, the text built on it,
    /// or the Printed PDF.
    static let wholeDocumentPasses: Set<String> = ["render.content", "render.engine", "render.session", "render.firstPages",
                                                   "render.chunk", "render.finish", "printed.emit", "pages.probe"]
    /// The app's own main-thread intervals of a progressive load's work, after the first pages show.
    static let loadIntervals: Set<String> = ["render.session", "render.chunk", "render.firstPages", "render.finish",
                                             "pages.setContent", "pages.setContent.all", "pages.layOut", "printed.load",
                                             "pages.probe"]
    /// The tour after the page changes: Printed, Modern, Native, Printed and Modern (switches 3–5 go back to a style
    /// already shown), then — batch 27 — Native with Show Invisibles on, Modern with it on, and off again.
    static let steps: [Step] = [.style(.printed), .style(.modern), .style(.native), .style(.printed), .style(.modern),
                                .style(.native), .invisibles(true), .style(.modern), .invisibles(false)]
    /// The steps that go back to a style already shown, with nothing else changed.
    static let returnSteps = 2..<5
    static let waitLimit: TimeInterval = 180
    /// Athena's batch-26 target for the main thread once the window is on screen.
    static let blockTarget: Double = 100

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func openAndPageChangeTimings() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("HolymacTimingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let holymac = try #require(PrivateCorpusSupport.sawyerArchiveRoot)
            .appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        try #require(FileManager.default.fileExists(atPath: holymac.path), "no -HOLYMAC.WS in the Sawyer archive")
        let lying = try #require(Self.bundledSample("LYING.WS"), "no bundled LYING.WS")

        var opens: [Open] = []
        for (name, source) in [("LYING.WS", lying), ("-HOLYMAC.WS", holymac)] {
            let url = scratch.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: url)
            for pass in ["cold", "warm"] {
                let open = try Self.open(url, pass: pass)
                opens.append(open)
                print("HOLYMAC-TIMING-SUMMARY \(Self.summary(open))")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("HOLYMAC-TIMING \(String(decoding: try encoder.encode(opens), as: UTF8.self))")

        let holymacOpens = opens.filter { $0.document == "-HOLYMAC.WS" }
        #expect(holymacOpens.count == 2 && holymacOpens.allSatisfy { $0.pages > 250 },
                "HOLYMAC pages: \(holymacOpens.map(\.pages))")
        for open in holymacOpens {
            #expect(open.untilDrawnMilliseconds < open.untilAllPagesMilliseconds,
                    "-HOLYMAC.WS \(open.pass): the first pages were not drawn before the rest were laid out")
            // Batch 27 (item 3): Modern's first visit shows its first page before its whole text is built.
            let modern = open.styleSwitches[1]
            #expect(modern.untilFirstPageMilliseconds < modern.untilDrawnMilliseconds,
                    "-HOLYMAC.WS \(open.pass): Modern's first page came only with the whole render (\(modern.untilFirstPageMilliseconds) ms)")
        }
        for open in opens {
            #expect(open.intervals.contains { $0.name == "open.parse" }, "\(open.document) \(open.pass): no open.parse interval")
            #expect(open.intervals.contains { $0.name == "open.firstPageDrawn" },
                    "\(open.document) \(open.pass): the pages never drew")
            // Switches 3–5 go back to a style already shown (Native at the open, Printed and Modern in
            // switches 1–2): none of its whole-document passes may run again.
            for change in open.styleSwitches[Self.returnSteps] {
                let passes = change.intervals.map(\.name).filter { Self.wholeDocumentPasses.contains($0) }
                #expect(passes.isEmpty, "\(open.document) \(open.pass): back to \(change.to), \(passes) ran again")
            }
            let over = open.mainThreadBlocksOver100ms
                .map { "\($0.what) \(String(format: "%.1f", $0.milliseconds)) ms" }
            #expect(over.isEmpty,
                    "\(open.document) \(open.pass): \(over.count) main-thread stretch(es) of \(Int(Self.blockTarget)) ms or more after the window showed: \(over)")
        }
    }

    /// Opens `url` the way the app does, in Native; turns three pages; switches views; closes the window.
    static func open(_ url: URL, pass: String) throws -> Open {
        let data = try Data(contentsOf: url)
        PerformanceSignposts.startRecording()
        let start = DispatchTime.now().uptimeNanoseconds
        let document = WSDocument()
        document.fileURL = url
        try document.read(from: data, ofType: "me.beforeti.wordstar-document")
        let state = try #require(document.state as DocumentState?)
        if state.style.value != .native {
            state.style.setManually(.native)
        }
        // The app's own open (`WSDocument.makeWindowControllers`) is progressive.
        let controller = DocumentWindowController(state: state, progressiveOpen: true)
        controller.showWindow(nil)
        let untilShown = milliseconds(since: start)
        let monitor = BlockMonitor()
        // Batch 26: a long document's parse runs off the main thread once its window is up, as
        // `WSDocument.makeWindowControllers` starts it. This window is not the document's own, so the test
        // hears the parse end itself and tells the window, as the document would.
        let parse = ParseOutcome()
        document.startDeferredParse { error in
            parse.error = error
            controller.documentDidFinishParsing()
        }
        _ = monitor.wait("a run-loop turn while the first pages come", limit: waitLimit) {
            controller.pagedView.pageCount > 0 || !isStillLoading(controller)
        }
        #expect(parse.error == nil, "\(url.lastPathComponent): the parse failed: \(String(describing: parse.error))")
        monitor.time("draw the first pages") { drawPages(controller) }
        let untilDrawn = milliseconds(since: start)
        let finished = monitor.wait("a run-loop turn while the open finishes", limit: waitLimit) {
            !isStillLoading(controller)
        }
        let untilAllPages = milliseconds(since: start)
        let intervals = PerformanceSignposts.stopRecording()
        defer { controller.close() }
        #expect(finished, "\(url.lastPathComponent): pages still rendering after \(Int(waitLimit)) s")
        let longestBlock = intervals.filter { loadIntervals.contains($0.name) }.map(\.milliseconds).max() ?? 0

        // Every page, exactly as the synchronous render lays them out.
        let synchronous = DocumentRenderer.render(state, style: .native)
        #expect(controller.pagedView.pageCount == synchronous.pageCount,
                "\(url.lastPathComponent): \(controller.pagedView.pageCount) pages laid out, the synchronous render has \(synchronous.pageCount)")
        #expect(controller.pagedView.primaryTextView?.string == synchronous.text.string,
                "\(url.lastPathComponent): the laid-out text differs from the synchronous render's")

        let pages = controller.pageTotal
        var changes: [PageChange] = []
        for target in [1, pages / 2, pages - 1] where target > 0 && target < pages {
            PerformanceSignposts.startRecording()
            let turn = DispatchTime.now().uptimeNanoseconds
            monitor.time("go to page \(target + 1)") { controller.goToPage(index: target) }
            monitor.time("draw page \(target + 1)") { drawPages(controller) }
            let elapsed = milliseconds(since: turn)
            changes.append(PageChange(toPage: target + 1, untilDrawnMilliseconds: elapsed,
                                      intervals: PerformanceSignposts.stopRecording()))
            #expect(controller.currentPage == target,
                    "\(url.lastPathComponent): asked for page \(target + 1), on \(controller.currentPage + 1)")
        }

        var switches: [StyleSwitch] = []
        for step in Self.steps {
            PerformanceSignposts.startRecording()
            let begin = DispatchTime.now().uptimeNanoseconds
            let contentBefore = controller.shownContentVersion
            switch step {
            case .style(let style):
                monitor.time("switch to \(style.displayName)") { controller.setStyle(style) }
            case .invisibles(let on):
                if state.showInvisibles != on {
                    monitor.time(step.name) { controller.toggleInvisibles(nil) }
                }
            }
            let target = state.style.value
            // The first page of the new content: new content is on screen, and it has pages.
            _ = monitor.wait("a run-loop turn while \(step.name)'s first page comes", limit: waitLimit) {
                (controller.shownContentVersion != contentBefore
                    && (target == .printed || controller.pagedView.pageCount > 0))
                    || !isStillLoading(controller)
            }
            monitor.time("draw \(step.name)'s first page") { draw(controller, target) }
            let untilFirstPage = milliseconds(since: begin)
            _ = monitor.wait("a run-loop turn while \(step.name) finishes", limit: waitLimit) {
                !isStillLoading(controller)
            }
            monitor.time("draw \(step.name)") { draw(controller, target) }
            switches.append(StyleSwitch(to: step.name, untilFirstPageMilliseconds: untilFirstPage,
                                        untilDrawnMilliseconds: milliseconds(since: begin),
                                        intervals: PerformanceSignposts.stopRecording()))
        }
        if state.showInvisibles { controller.toggleInvisibles(nil) }
        return Open(document: url.lastPathComponent, pass: pass, bytes: data.count, pages: pages,
                    view: ViewStyle.native.displayName, display: "\(state.display.value)",
                    untilWindowShownMilliseconds: untilShown,
                    untilDrawnMilliseconds: untilDrawn, untilAllPagesMilliseconds: untilAllPages,
                    longestBlockAfterFirstPagesMilliseconds: longestBlock,
                    longestMainThreadBlock: monitor.longest ?? MainThreadBlock(what: "nothing", milliseconds: 0),
                    mainThreadBlocksOver100ms: monitor.blocks.filter { $0.milliseconds >= blockTarget },
                    intervals: intervals, pageChanges: changes, styleSwitches: switches)
    }

    /// Draws what `style` shows: the PDF view's window for Printed, the pages otherwise.
    static func draw(_ controller: DocumentWindowController, _ style: ViewStyle) {
        if style == .printed {
            controller.window?.display()
        } else {
            drawPages(controller)
        }
    }

    /// Whether the window is still parsing, rendering or laying out its content.
    static func isStillLoading(_ controller: DocumentWindowController) -> Bool {
        controller.isLoadingContent
    }

    /// How a deferred parse ended, as the test hears it.
    @MainActor
    final class ParseOutcome {
        var error: Error?
    }

    /// Draws the page on screen now, whether or not the test host's window is visible. `display()` and
    /// `displayIfNeeded()` never reached `PagedDocumentView.draw` here (b25-holymac-before and -after recorded
    /// no `open.firstPageDrawn`); `cacheDisplay` always does.
    static func drawPages(_ controller: DocumentWindowController) {
        let pages = controller.pagedView
        let rect = pages.rect(ofPage: pages.visiblePageIndex).intersection(pages.bounds)
        guard !rect.isEmpty, let bitmap = pages.bitmapImageRepForCachingDisplay(in: rect) else { return }
        pages.cacheDisplay(in: rect, to: bitmap)
    }

    /// How long the main thread stays busy in one stretch: each call timed whole, and each run-loop turn while
    /// the test waits, less the turn's own idle wait.
    @MainActor
    final class BlockMonitor {
        private(set) var blocks: [MainThreadBlock] = []
        /// The idle wait each run-loop turn is given; a turn with nothing to do returns after it.
        static let turnWait: TimeInterval = 0.001

        func time<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { blocks.append(MainThreadBlock(what: what, milliseconds: HolymacTimingTests.milliseconds(since: start))) }
            return try body()
        }

        /// Turns the main run loop until `done`, or `limit` passes; `done()` at the end.
        func wait(_ what: String, limit: TimeInterval, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while !done(), Date() < deadline {
                let start = DispatchTime.now().uptimeNanoseconds
                RunLoop.main.run(until: Date().addingTimeInterval(Self.turnWait))
                let busy = HolymacTimingTests.milliseconds(since: start) - Self.turnWait * 1000
                if busy >= 1 { blocks.append(MainThreadBlock(what: what, milliseconds: busy)) }
            }
            return done()
        }

        var longest: MainThreadBlock? { blocks.max { $0.milliseconds < $1.milliseconds } }
    }

    /// "-HOLYMAC.WS cold: 302 pages, Native, singlePage, window shown 50.0 ms, first pages drawn 120.0 ms,
    /// every page 4000.0 ms, longest block after 1300.0 ms, longest main-thread stretch 90.0 ms (…), 0 over
    /// 100 ms; open.parse 1 × 1000.0 ms, …; page 2 1.0 ms […]; to Printed 400.0 ms […]"
    static func summary(_ open: Open) -> String {
        func totals(_ intervals: [PerformanceSignposts.Interval]) -> String {
            var order: [String] = []
            var sums: [String: (count: Int, ms: Double)] = [:]
            for interval in intervals {
                if sums[interval.name] == nil { order.append(interval.name) }
                let sum = sums[interval.name] ?? (0, 0)
                sums[interval.name] = (sum.count + 1, sum.ms + interval.milliseconds)
            }
            return order.map { name in
                let sum = sums[name] ?? (0, 0)
                return "\(name) \(sum.count) × \(String(format: "%.1f", sum.ms)) ms"
            }.joined(separator: ", ")
        }
        let turns = open.pageChanges.map {
            "page \($0.toPage) \(String(format: "%.1f", $0.untilDrawnMilliseconds)) ms [\(totals($0.intervals))]"
        }
        let switches = open.styleSwitches.map {
            "to \($0.to) first page \(String(format: "%.1f", $0.untilFirstPageMilliseconds)) ms, "
                + "drawn \(String(format: "%.1f", $0.untilDrawnMilliseconds)) ms [\(totals($0.intervals))]"
        }
        var line = "\(open.document) \(open.pass): \(open.pages) pages, \(open.view), \(open.display), "
        line += "window shown \(String(format: "%.1f", open.untilWindowShownMilliseconds)) ms, "
        line += "first pages drawn \(String(format: "%.1f", open.untilDrawnMilliseconds)) ms, "
        line += "every page \(String(format: "%.1f", open.untilAllPagesMilliseconds)) ms, "
        line += "longest block after \(String(format: "%.1f", open.longestBlockAfterFirstPagesMilliseconds)) ms, "
        line += "longest main-thread stretch \(String(format: "%.1f", open.longestMainThreadBlock.milliseconds)) ms "
        line += "(\(open.longestMainThreadBlock.what)), \(open.mainThreadBlocksOver100ms.count) over 100 ms; "
        line += "\(totals(open.intervals)); "
        line += turns.joined(separator: "; ")
        line += "; "
        line += switches.joined(separator: "; ")
        return line
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// One of the app's bundled public-domain samples, from their source folder
    /// (`macos/SoftReturn/Resources/SampleDocuments/`, as `PrivateCorpusSupport` finds them).
    static func bundledSample(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("SoftReturn/Resources/SampleDocuments/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
