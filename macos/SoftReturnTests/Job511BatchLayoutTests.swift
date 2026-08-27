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
/// Job 528 (b34 intake N2): jobs 511/518/522 above never reproduced Jon's real-session bug
/// because none of them could — a SwiftUI `Picker` + `.frame(width:)` on macOS silently
/// ignores that offered frame outside a headless test host (Jon's own ruling: rebuild it the
/// way `SettingsWindowController` does, a genuine `NSPopUpButton` with a hard `widthAnchor`
/// constraint). The pulldown-geometry tests below now query the real `NSPopUpButton`s
/// directly and assert their width BY CONSTRAINT CONSTANT, not by re-measuring a rendered
/// frame this headless session's negotiation happens to produce — see each test's own comment
/// and job 528's report for the HONESTY CONSTRAINT this suite still operates under.
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

    // MARK: - Job 528: real NSPopUpButtons, one shared width constraint, 5pt narrower than Settings

    /// Job 528 rebuilt these 7 pulldowns as genuine `NSPopUpButton`s (`BatchPopUpButton`,
    /// `BatchWindowController.swift`) — the same way `SettingsWindowController.popup(_:_:_:_:)`
    /// builds its own — because the SwiftUI `Picker` + `.frame(width:)` this suite originally
    /// measured (192.0pt: 185pt offered plus ~7pt of SwiftUI's own chrome) is exactly the
    /// pattern Jon's b34 intake N2 ruling traced to a real-Aqua-session bug this headless suite
    /// could never see: that offered frame is silently ignored outside a headless test host,
    /// where each popup instead sizes to its widest menu item. This test asserts the fix BY
    /// CONSTRAINT — every button's own active `widthAnchor` constraint constant — never by
    /// re-measuring a rendered frame and hoping this session's negotiation matches Jon's.
    @Test @MainActor func batchPopupWidthIsPinnedByAHardWidthConstraintOnEachControl() async throws {
        let (_, content) = try await Self.makeWindow(withFile: false)
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
        // Job 520 (N5): Page Numbering is a 6th pulldown, same shared width as the other five.
        // Job 521 (N9): Sentence Spacing is a 7th, same shared width as the other six.
        #expect(buttons.count == 7,
                "expected 7 NSPopUpButtons (Variant/Style/Font/Size/Pictures/Page Numbering/Sentence Spacing), found \(buttons.count)")

        let widthConstants: [CGFloat] = buttons.compactMap { button in
            button.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil && $0.isActive }?.constant
        }
        #expect(widthConstants.count == buttons.count,
                "every pulldown must carry its own active width constraint directly on the NSPopUpButton, found \(widthConstants.count) of \(buttons.count)")

        let uniqueWidths = Set(widthConstants)
        #expect(uniqueWidths.count == 1, "all 7 pulldowns' width constraints must share one constant: \(uniqueWidths)")
        #expect(uniqueWidths.first == 185,
                "batch pulldown width constraint is \(uniqueWidths.first ?? -1)pt, expected 185pt (Settings' 190pt minus job 511's 5pt — BatchWindowController.popupWidth, unchanged by job 528)")
    }

    // MARK: - 2b + 2c: no label wraps, every pulldown right-aligned as one column

    /// Measures each `NSPopUpButton`'s own frame (no wrapping SwiftUI host to walk through
    /// anymore — job 528 made these real controls), converted to the window content view's own
    /// coordinate space. This is self-consistency data only, per job 528's HONESTY CONSTRAINT:
    /// it proves the 7 hard-coded constants (label width, spacing, popup width) compose to one
    /// shared column in THIS process — it is not, and cannot be, a claim about what a real Aqua
    /// session renders. That said, unlike the old SwiftUI-frame measurement, this number is now
    /// backed by an actual `NSLayoutConstraint` AutoLayout enforces the same way in every
    /// session, not a cross-boundary size negotiation a real session was free to ignore.
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

        // `ZZProbeJob528Diag.swift.unused` measured this directly: a bordered, rounded-bezel
        // `NSPopUpButton`'s `.frame` is 7pt WIDER than its own `widthAnchor` constraint constant
        // on BOTH windows (`alignmentRectInsets` — left 3 + right 4 — a universal AppKit
        // property of this control style, not something job 528 introduced): Settings' own
        // 190pt-constrained popup measures 197pt; Batch's 185pt-constrained popup measures
        // 192pt. Auto Layout constrains the ALIGNMENT rect, not the raw frame, so 192 (not
        // 185) is the CORRECT frame reading here — the same relationship Settings' own control
        // has always had, not a regression this job introduced.
        let widths = Set(absoluteFrames.map { $0.width.rounded() })
        #expect(widths.count == 1 && widths.first == 192,
                "measured frame widths (\(widths)) should be 192pt (185pt widthAnchor constant + 7pt alignment-rect inset, same relationship Settings' own NSPopUpButton has)")

        let leftEdges = Set(absoluteFrames.map { $0.minX.rounded() })
        let rightEdges = Set(absoluteFrames.map { $0.maxX.rounded() })
        #expect(leftEdges.count == 1,
                "all 7 pulldowns must start at the same x (right-aligned as a column): \(leftEdges)")
        #expect(rightEdges.count == 1,
                "all 7 pulldowns must end at the same x (right-aligned as a column): \(rightEdges)")
    }

    /// No label may wrap (Jon: "Variant" was wrapping its colon, "Pictures:" was wrapping as
    /// "s:"). A wrapped `Text` renders as a TALLER `CGDrawingView` (two lines instead of one)
    /// sitting where the label should be — so this finds each of the 7 pulldowns' own row
    /// label BY POSITION (the nearest `CGDrawingView` immediately to that pulldown's left, at
    /// the same row height) rather than guessing at glyph widths, which the window's OTHER
    /// text (checkbox titles, GroupBox section headers, the file list's own labels) would also
    /// match.
    @Test @MainActor func noLabelInTheLeftColumnWrapsToASecondLine() async throws {
        let (_, content) = try await Self.makeWindow(withFile: false)
        let buttons = RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
        // Job 520 (N5): Page Numbering is a 6th pulldown. Job 521 (N9): Sentence Spacing is a 7th.
        let countMessage = "expected 7 pulldowns (Variant/Style/Font/Size/Pictures/Page "
            + "Numbering/Sentence Spacing), found \(buttons.count)"
        #expect(buttons.count == 7, "\(countMessage)")

        let allLabels = RenderProbeKit.descendants(content)
            .filter { String(describing: type(of: $0)) == "CGDrawingView" }
            .compactMap { view -> CGRect? in
                guard let superview = view.superview else { return nil }
                return superview.convert(view.frame, to: content)
            }

        var matchedLabels: [CGRect] = []
        for button in buttons {
            guard let superview = button.superview else { continue }
            let buttonFrame = superview.convert(button.frame, to: content)
            let sameRow = allLabels.filter { abs($0.midY - buttonFrame.midY) <= 3 && $0.maxX <= buttonFrame.minX }
            let label = try #require(sameRow.max { $0.maxX < $1.maxX },
                                      "no label found to the left of a pulldown at \(buttonFrame)")
            matchedLabels.append(label)
        }

        #expect(matchedLabels.count == 7)
        for label in matchedLabels {
            #expect(label.height <= 16,
                    "a label glyph is \(label.height)pt tall — taller than one line (16pt), suggesting it wrapped")
        }
    }

    // MARK: - 2a: preview fills the column and is centered with its info block

    /// The preview page's own bordered image view (`_NSShapeHitTestingView`, the probe's own
    /// finding for what `.border(_:)` backs on macOS) must reach close to the previewColumn's
    /// real width (300pt, `BatchView.previewColumn`'s own `.frame(width: 300)`) rather than the
    /// old 240pt-tall cap that left it around 185pt wide — "bigger... there's room in the
    /// column" (Jon).
    @Test @MainActor func previewImageFillsTheColumnWidth() async throws {
        let (_, content) = try await Self.makeWindow(withFile: true)
        let shapeViews = RenderProbeKit.descendants(content)
            .filter { String(describing: type(of: $0)) == "_NSShapeHitTestingView" }
        let preview = try #require(shapeViews.max { $0.frame.width < $1.frame.width },
                                    "no bordered preview shape view found")
        #expect(preview.frame.width >= 280,
                "preview image is only \(preview.frame.width)pt wide — expected close to the column's 300pt")
    }

    /// The Get-Info-style block beneath the preview must be centered UNDER the (now full-
    /// width) preview, not pinned to the column's leading edge. Measured as: the block's own
    /// bounding box (leftmost label start to rightmost value end, converted to the content
    /// view's coordinate space) sits within a few points of the preview image's own midpoint —
    /// exactly what the probe's real capture showed (block centre 467.25pt vs image centre
    /// 467pt, both against the previewColumn's own 300pt span).
    @Test @MainActor func infoBlockIsCenteredUnderThePreview() async throws {
        let (_, content) = try await Self.makeWindow(withFile: true)
        let shapeViews = RenderProbeKit.descendants(content)
            .filter { String(describing: type(of: $0)) == "_NSShapeHitTestingView" }
        let preview = try #require(shapeViews.max { $0.frame.width < $1.frame.width })
        let previewMidX = preview.frame.midX

        // The info panel's rows are plain `CGDrawingView`s below the preview image — narrow
        // (label) and wider (value) glyphs both included, so the block's bounding box is
        // "everything below the preview's bottom edge". Also constrained to the preview
        // column's own x-range: the controls column (a separate, unrelated set of GroupBoxes)
        // shares this same absolute y-range and would otherwise get swept in too.
        let belowPreview = RenderProbeKit.descendants(content)
            .filter { String(describing: type(of: $0)) == "CGDrawingView" }
            .compactMap { view -> CGRect? in
                guard let superview = view.superview else { return nil }
                return superview.convert(view.frame, to: content)
            }
            .filter { $0.minY >= preview.frame.maxY }
            .filter { $0.minX >= preview.frame.minX - 30 && $0.maxX <= preview.frame.maxX + 30 }
        #expect(belowPreview.count >= 8, "expected at least 8 info-panel label/value glyphs below the preview, found \(belowPreview.count)")

        let blockMinX = belowPreview.map(\.minX).min() ?? 0
        let blockMaxX = belowPreview.map(\.maxX).max() ?? 0
        let blockMidX = (blockMinX + blockMaxX) / 2
        #expect(abs(blockMidX - previewMidX) <= 4,
                "info block's own centre (\(blockMidX)) is more than 4pt from the preview image's centre (\(previewMidX)) — not centered under it")
    }
}
