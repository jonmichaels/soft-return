import AppKit
import Testing
@testable import SoftReturn

/// Job 511 (b32 notes 2a-2c): Jon's three Batch Export window fixes, verified against the
/// REAL hosted SwiftUI window, not a recomputation of what the layout should produce —
/// `ZZProbeJob511BatchLayout.swift.unused` is the probe that dumped this suite's real numbers
/// (`RenderProbeKit.descendants`, same technique `Job454ButtonWidthTests`/`UIRound4BRulingTests`
/// already use for this window).
///
/// Job 518 (N3): `makeWindow` now forces a REAL display pass (`NSApp.activate` +
/// `makeKeyAndOrderFront` + `displayIfNeeded` + a settle sleep — `LivePrintedFramingTests`'
/// own technique for the same "offscreen query missed something live" bug class, job 278/298)
/// rather than `layoutSubtreeIfNeeded()` alone, which is all job 511's original version of
/// this helper did. `ZZProbeJob518Diag.swift.unused` compared both techniques (plus a forced
/// `.legacy` scroller and a dark/narrowed window) side by side and found byte-identical
/// pulldown geometry in every condition tried — this job could not reproduce Jon's reported
/// b32 misalignment under any of them — but the live pass is a strictly more trustworthy
/// baseline going forward, and costs one settle sleep per test.
///
/// The pulldowns are genuine `NSPopUpButton`s (`BatchPopUpButton`), so the tests below query
/// them directly. Labels, the preview page and the info block are SwiftUI, which on macOS 26
/// draws them inside its hosting view with no subview of their own, so those tests read the
/// window as drawn (`RenderProbeKit.Drawing`). Each was checked against a broken layout (a
/// wrapped label, a 240 pt preview, an off-centre info block) and failed on it.
@Suite struct Job511BatchLayoutTests {

    @MainActor
    private static func makeWindow(withFile: Bool) async throws -> (controller: BatchWindowController, content: NSView) {
        let controller = BatchWindowController()
        controller.showWindow(nil)
        if withFile {
            let model = try #require(Mirror(reflecting: controller).children
                .first { $0.label == "model" }?.value as? BatchModel)
            _ = model.add(urls: [Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")],
                          includeSubfolders: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(controller.window?.contentView)
        return (controller, content)
    }

    // MARK: - 2b + 2c: no label wraps, every pulldown right-aligned as one column

    /// The seven pulldowns read as one column: the same width, the same left and right edge,
    /// all inside the window, and none narrower than its own widest menu item (a title that
    /// does not fit is clipped).
    @Test @MainActor func allSevenPulldownsShareOneRightAlignedColumn() async throws {
        let (_, content) = try await Self.makeWindow(withFile: false)
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
        // Job 520 (N5): Page Numbering is a 6th pulldown. Job 521 (N9): Sentence Spacing is a 7th.
        let countMessage = "expected 7 pulldowns (Variant/Style/Font/Size/Pictures/Page "
            + "Numbering/Sentence Spacing), found \(buttons.count)"
        #expect(buttons.count == 7, "\(countMessage)")

        let absoluteFrames = buttons.compactMap { button -> CGRect? in
            guard let superview = button.superview else { return nil }
            return superview.convert(button.frame, to: content)
        }
        #expect(absoluteFrames.count == buttons.count, "every pulldown must resolve an absolute frame")

        let widths = Set(absoluteFrames.map { $0.width.rounded() })
        #expect(widths.count == 1, "all 7 pulldowns must be the same width: \(widths)")

        for (button, frame) in zip(buttons, absoluteFrames) {
            #expect(frame.minX >= content.bounds.minX && frame.maxX <= content.bounds.maxX,
                    "a pulldown at \(frame) runs outside the window's \(content.bounds)")
            // The title on show fits: a pulldown holding only its selected title needs no more
            // than the frame. (A long font name in the Font menu is truncated when chosen, as
            // in Settings; the default choices must not be.)
            let probe = NSPopUpButton(frame: .zero, pullsDown: false)
            probe.font = button.font
            probe.addItem(withTitle: button.titleOfSelectedItem ?? "")
            #expect(probe.intrinsicContentSize.width <= button.frame.width + 0.5,
                    "'\(button.titleOfSelectedItem ?? "")' needs \(probe.intrinsicContentSize.width)pt in a \(button.frame.width)pt pulldown")
        }

        let leftEdges = Set(absoluteFrames.map { $0.minX.rounded() })
        let rightEdges = Set(absoluteFrames.map { $0.maxX.rounded() })
        #expect(leftEdges.count == 1,
                "all 7 pulldowns must start at the same x (right-aligned as a column): \(leftEdges)")
        #expect(rightEdges.count == 1,
                "all 7 pulldowns must end at the same x (right-aligned as a column): \(rightEdges)")
    }

    /// No label may wrap (Jon: "Variant" was wrapping its colon, "Pictures:" was wrapping as
    /// "s:"). SwiftUI on macOS 26 draws each label inside its hosting view, so this reads the
    /// drawing: a label's ink sits left of its pulldown, and a one-line label stays inside the
    /// pulldown's own height. A wrapped label is two lines tall, and its grid row centres the
    /// pulldown on it, so its ink runs past the pulldown's top and bottom.
    @Test @MainActor func noLabelInTheLeftColumnWrapsToASecondLine() async throws {
        let (controller, content) = try await Self.makeWindow(withFile: false)
        controller.window?.appearance = NSAppearance(named: .aqua)
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
        #expect(buttons.count == 7)
        let drawing = try RenderProbeKit.Drawing(content)
        for button in buttons {
            let pulldown = button.convert(button.bounds, to: content)
            let strip = CGRect(x: 0, y: pulldown.minY - 3, width: pulldown.minX - 2, height: pulldown.height + 6)
            let label = try #require(drawing.inkBounds(in: strip),
                                     "no label drawn to the left of the pulldown at \(pulldown)")
            #expect(label.minY >= pulldown.minY && label.maxY <= pulldown.maxY,
                    "the label of '\(button.titleOfSelectedItem ?? "")' is drawn at \(label), past its pulldown's \(pulldown): it wrapped")
        }
    }

    // MARK: - 2a: preview fills the column and is centered with its info block

    /// The preview page as drawn: the unbroken drawn run through the preview column's middle,
    /// down and then across (the page is white with a 1 pt border; the column around it is
    /// undrawn, apart from the faint dividers at its edges). The column lies between the 300 pt
    /// form and the file list.
    @MainActor
    private static func previewPage(in content: NSView, _ drawing: RenderProbeKit.Drawing) throws -> CGRect {
        let list = try #require(RenderProbeKit.descendants(content).compactMap { $0 as? NSTableView }.first?.enclosingScrollView,
                                "no file list")
        let midX = (300 + list.convert(list.bounds, to: content).minX) / 2
        func drawn(_ x: CGFloat, _ y: CGFloat) -> Bool { drawing.color(at: CGPoint(x: x, y: y)) != nil }
        // The tallest unbroken run straight down the middle is the page.
        var runs: [ClosedRange<CGFloat>] = []
        for point in drawing.points(in: CGRect(x: midX, y: 0, width: 0.1, height: content.bounds.height))
        where drawn(point.x, point.y) {
            if let last = runs.last, point.y - last.upperBound <= 1 {
                runs[runs.count - 1] = last.lowerBound...point.y
            } else {
                runs.append(point.y...point.y)
            }
        }
        let tall = try #require(runs.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound },
                                "nothing drawn down the preview column at x \(midX)")
        let midY = (tall.lowerBound + tall.upperBound) / 2
        var left = midX, right = midX
        while left > 0, drawn(left - 0.5, midY) { left -= 0.5 }
        while right < content.bounds.maxX, drawn(right + 0.5, midY) { right += 0.5 }
        return CGRect(x: left, y: tall.lowerBound, width: right - left + 0.5, height: tall.upperBound - tall.lowerBound)
    }

    /// The preview page fills the 300 pt preview column (Jon: "bigger... there's room in the
    /// column").
    @Test @MainActor func previewImageFillsTheColumnWidth() async throws {
        let (controller, content) = try await Self.makeWindow(withFile: true)
        controller.window?.appearance = NSAppearance(named: .aqua)
        let preview = try Self.previewPage(in: content, try RenderProbeKit.Drawing(content))
        #expect(preview.width >= 280,
                "the preview is drawn \(preview.width)pt wide at \(preview) — expected close to the column's 300pt")
    }

    /// The Get-Info block below the preview is centered under it: what is drawn below the page,
    /// within the page's own span (grey labels and black values alike), is as far from the
    /// page's left edge as from its right.
    @Test @MainActor func infoBlockIsCenteredUnderThePreview() async throws {
        let (controller, content) = try await Self.makeWindow(withFile: true)
        controller.window?.appearance = NSAppearance(named: .aqua)
        let drawing = try RenderProbeKit.Drawing(content)
        let preview = try Self.previewPage(in: content, drawing)
        let below = CGRect(x: preview.minX, y: preview.maxY + 2,
                           width: preview.width, height: content.bounds.height - preview.maxY - 2)
        let block = try #require(drawing.drawnBounds(in: below), "no info block drawn below the preview at \(preview)")
        #expect(block.height >= 100, "the info block below the preview is only \(block.height)pt tall: \(block)")
        #expect(abs(block.midX - preview.midX) <= 4,
                "the info block's centre (\(block.midX), \(block)) is not under the preview's (\(preview.midX), \(preview))")
    }
}
