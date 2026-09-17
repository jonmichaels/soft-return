import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 47 (M25, Jon: -HOLYMAC.WS switched to Continuous Scroll scrolls jerkily for about ten seconds, then smoothly):
/// the main thread's work in that window. -HOLYMAC.WS opens as the app opens it (progressively, in Native, Single Page);
/// once its first pages show it is switched to Continuous Scroll and scrolled at once, 50 pt a frame (3,000 pt/s) for
/// `scrollSeconds`, each frame moving the clip view and drawing the window, then yielding the rest of a 60 Hz frame.
/// Per second of scrolling: frames over the 16.7 ms budget, the longest frame, and the app's own timed intervals
/// (`PerformanceSignposts`) that ran in the slow frames. Every second keeps at least 45 frames, no frame takes two frames'
/// time, and the open still finishes while the reader scrolls.
@Suite("Continuous Scroll after the switch (M25)", .serialized)
@MainActor
struct ContinuousScrollAfterSwitchTests {
    static let scrollSeconds = 14
    static let stepPoints: CGFloat = 50
    static let budgetMs = 1000.0 / 60

    struct Second: CustomStringConvertible {
        var frames = 0
        var over = 0
        var longest = 0.0
        var busy = 0.0
        var intervals: [String: (count: Int, ms: Double)] = [:]
        var description: String {
            let top = intervals.sorted { $0.value.ms > $1.value.ms }.prefix(4)
                .map { "\($0.key) \($0.value.count)× \(String(format: "%.0f", $0.value.ms)) ms" }
            return "\(frames) frames, \(over) over budget, longest \(String(format: "%.1f", longest)) ms, main thread \(String(format: "%.0f", busy)) ms; slow frames ran: \(top)"
        }
    }

    @Test(.enabled(if: PrivateCorpusSupport.sawyerArchiveRoot != nil, "needs the Sawyer archive (CTRLKD_SAWYER_ARCHIVE)"))
    func scrollingRightAfterTheSwitch() throws {
        let holymac = try #require(PrivateCorpusSupport.sawyerArchiveRoot).appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("M25-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("-HOLYMAC.WS")
        try FileManager.default.copyItem(at: holymac, to: url)

        let document = WSDocument()
        document.fileURL = url
        try document.read(from: Data(contentsOf: url), ofType: "me.beforeti.wordstar-document")
        let state = try #require(document.state as DocumentState?)
        state.style.setManually(.native)
        state.display.setManually(.singlePage)
        let controller = DocumentWindowController(state: state, progressiveOpen: true)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 900, height: 1000))
        document.startDeferredParse { _ in controller.documentDidFinishParsing() }
        let monitor = HolymacTimingTests.BlockMonitor()
        _ = monitor.wait("first pages", limit: 120) { controller.pagedView.pageCount > 0 }

        controller.setDisplay(.continuousScroll)
        let pages = controller.pagedView
        let scroll = try #require(pages.enclosingScrollView)
        var seconds = Array(repeating: Second(), count: Self.scrollSeconds)
        let start = DispatchTime.now().uptimeNanoseconds
        var y: CGFloat = 0
        var laidOutAt: Double?
        while true {
            let elapsedMs = HolymacTimingTests.milliseconds(since: start)
            let second = Int(elapsedMs / 1000)
            guard second < Self.scrollSeconds else { break }
            if laidOutAt == nil, !controller.isLoadingContent { laidOutAt = elapsedMs }
            PerformanceSignposts.startRecording()
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let maxY = max(0, pages.frame.height - scroll.contentView.bounds.height)
            y = y + Self.stepPoints > maxY ? 0 : y + Self.stepPoints
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            controller.window?.displayIfNeeded()
            let work = HolymacTimingTests.milliseconds(since: frameStart)
            let rest = max(0.001, Self.budgetMs - work) / 1000
            RunLoop.main.run(until: Date().addingTimeInterval(rest))
            let frame = HolymacTimingTests.milliseconds(since: frameStart) - rest * 1000
            let intervals = PerformanceSignposts.stopRecording()
            seconds[second].frames += 1
            seconds[second].busy += frame
            seconds[second].longest = max(seconds[second].longest, frame)
            if frame > Self.budgetMs {
                seconds[second].over += 1
                for interval in intervals {
                    let sum = seconds[second].intervals[interval.name] ?? (0, 0)
                    seconds[second].intervals[interval.name] = (sum.count + 1, sum.ms + interval.milliseconds)
                }
            }
        }
        print("M25 -HOLYMAC.WS: \(pages.pageCount) pages; the open finished \(laidOutAt.map { String(format: "%.1f s", $0 / 1000) } ?? "after the scroll") into it")
        for (index, second) in seconds.enumerated() { print("M25 second \(index + 1): \(second)") }
        let jerky = seconds.filter { $0.over > 3 }.count
        print("M25: \(jerky) second(s) with more than 3 frames over budget")
        // Before (b47-m25-before): every frame of the first three seconds over budget, 20–21 frames a second, the longest
        // 48 ms. Now every second keeps at least 45 frames and no frame reaches two frames' time; the few frames still over
        // are the last pages' layout, one page (about 5 ms) being the least a layout turn can do.
        #expect(seconds.allSatisfy { $0.frames >= 45 }, "seconds under 45 frames: \(seconds.map(\.frames))")
        #expect(seconds.allSatisfy { $0.longest < 2 * Self.budgetMs }, "a frame of two frames' time: \(seconds.map(\.longest))")
        #expect(laidOutAt != nil, "the open did not finish in \(Self.scrollSeconds) s of scrolling")
    }
}
