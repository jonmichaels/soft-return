import AppKit
import CtrlKD
import SoftReturnShared
import Testing
@testable import SoftReturn

/// RULING ASSERTIONS.
///
/// `RenderProbeTests` captures; this file is what actually holds the five rulings to
/// account. Round 1 shipped without anything like this file — geometry.json and a wall of
/// PNGs, and no assertion anywhere that any of it was RIGHT — and was reverted for it.
/// Verification is the harness, not vibes.
@MainActor
private func rulingState(_ fixture: String = "dropped-chapter.ws4") throws -> DocumentState {
    try Oracle.state(for: Oracle.fixturesDirectory.appendingPathComponent(fixture))
}

// MARK: - Ruling 1: the canvas colour

@Suite struct RulingAssertionTests {
    /// Light Mode canvas is sRGB 150/255 (0.588) gray, exactly — not the system
    /// `windowBackgroundColor` (~0.925) that made the page barely read against it.
    @Test @MainActor func lightCanvasIsExactlySRGB0588Gray() {
        let color = RenderProbeKit.resolvedColor(.softReturnCanvas, appearance: NSAppearance(named: .aqua)!)
        #expect(abs(color.red - 0.588) < 0.002, "red is \(color.red)")
        #expect(abs(color.green - 0.588) < 0.002, "green is \(color.green)")
        #expect(abs(color.blue - 0.588) < 0.002, "blue is \(color.blue)")
    }

    /// Dark Mode is UNCHANGED — the ruling named Light Mode only. Proven by comparing against
    /// the system colour directly, rather than a hardcoded figure that could just happen to
    /// match by coincidence.
    @Test @MainActor func darkCanvasStillMatchesTheSystemWindowBackground() {
        let dark = NSAppearance(named: .darkAqua)!
        let canvas = RenderProbeKit.resolvedColor(.softReturnCanvas, appearance: dark)
        let system = RenderProbeKit.resolvedColor(.windowBackgroundColor, appearance: dark)
        #expect(abs(canvas.red - system.red) < 0.002)
        #expect(abs(canvas.green - system.green) < 0.002)
        #expect(abs(canvas.blue - system.blue) < 0.002)
    }

    // MARK: - Ruling 2: centering

    /// Centred on any axis where the page is smaller than the viewport; top-pinned (not
    /// centred) on any axis where it is larger — the vertical behaviour the brief says is
    /// already correct and must survive this change.
    ///
    /// 700x500 leaves the 612x792 page NARROWER than the viewport (centre) but TALLER than it
    /// (top-pin). 1600x1100 leaves it smaller on both axes (centre both). Between them every
    /// branch of `CenteringClipView` runs.
    @Test @MainActor func pageCentersWhereSmallerAndTopPinsWhereLarger() throws {
        for size in [NSSize(width: 700, height: 500), NSSize(width: 1600, height: 1100)] {
            let state = try rulingState()
            let controller = DocumentWindowController(state: state)
            controller.showWindow(nil)
            controller.window?.setContentSize(size)
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            let content = try #require(controller.window?.contentView)
            let scrollView = try #require(
                RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }.first)
            let documentView = try #require(scrollView.documentView)
            let clip = scrollView.contentView.bounds
            let doc = documentView.frame

            // Both frames share the clip view's (always-flipped) coordinate space: smaller Y is
            // visually higher. `leftGap`/`topGap` are the room left on the near edge; `rightGap`/
            // `bottomGap` on the far edge.
            let leftGap = doc.minX - clip.minX
            let rightGap = clip.maxX - doc.maxX
            let topGap = doc.minY - clip.minY
            let bottomGap = clip.maxY - doc.maxY

            if clip.width > doc.width {
                #expect(abs(leftGap - rightGap) < 1.0,
                        "not centred horizontally at \(size): left \(leftGap), right \(rightGap)")
            }
            if clip.height > doc.height {
                #expect(abs(topGap - bottomGap) < 1.0,
                        "not centred vertically at \(size): top \(topGap), bottom \(bottomGap)")
            } else {
                #expect(abs(topGap) < 1.0,
                        "top-pin broken at \(size): the page's top edge is \(topGap)pt from the viewport's top")
            }
        }
    }

    // MARK: - Ruling 3: fixed-width popups

    /// Cycles every value each of the five bottom-bar controls can ever show and re-measures
    /// after each — none may ever resize. Widths are fixed at construction (see
    /// `BottomBar`'s width constants), so this is really asking "did `update(from:)` ever touch
    /// a width constraint", but it does so by observing the same frames the render probe and a
    /// screenshot would.
    @Test @MainActor func bottomBarPopupWidthsNeverChangeAcrossAnySelection() throws {
        let state = try rulingState()
        let bar = BottomBar()
        bar.update(from: state)
        bar.layoutSubtreeIfNeeded()

        func widths() -> [String: CGFloat] {
            Dictionary(uniqueKeysWithValues: RenderProbeKit.descendants(bar)
                .compactMap { $0 as? NSPopUpButton }
                .map { ($0.accessibilityIdentifier(), $0.frame.width) })
        }
        let initial = widths()
        #expect(initial.count == 5, "expected five popups, found \(initial.count)")

        func assertUnchanged(_ label: String) {
            bar.layoutSubtreeIfNeeded()
            for (id, width) in widths() {
                #expect(abs(width - (initial[id] ?? -1)) < 0.5,
                        "\(id) is \(width)pt after \(label) — was \(initial[id] ?? -1)pt")
            }
        }

        for variant: Variant? in [Variant.ws4, .ws5plus, .printstream, .text, nil] {
            if let variant { _ = state.setVariant(variant) } else { state.resetVariantToAuto() }
            bar.update(from: state)
            assertUnchanged("variant \(variant.map { "\($0)" } ?? "Auto")")
        }
        for style in ViewStyle.allCases {
            state.style.setManually(style)
            bar.update(from: state)
            assertUnchanged("style \(style)")
        }
        for percent in ZoomSetting.steps {
            state.zoom.setManually(.percent(percent))
            bar.update(from: state)
            assertUnchanged("zoom \(percent)%")
        }
        for zoom: ZoomSetting in [.fit, .actual] {
            state.zoom.setManually(zoom)
            bar.update(from: state)
            assertUnchanged("zoom \(zoom.displayName)")
        }
        for size in NamedPageSize.allCases {
            state.setPageSize(size)
            bar.update(from: state)
            assertUnchanged("page size \(size)")
        }
        for preset: DocumentOperations.PageSettingsPreset? in
            [nil] + DocumentOperations.PageSettingsPreset.allCases {
            state.setPageSettingsPreset(preset)
            bar.update(from: state)
            assertUnchanged("page settings \(preset.map { "\($0)" } ?? "Embedded")")
        }
    }

    // MARK: - Ruling 4: selections apply, and Fit fits

    /// Fit has to track the ACTUAL viewport across a resize, not the viewport it happened to
    /// measure once. This is the regression test for "Fit does not fit" (the page sat at 612pt
    /// regardless of window size): two different window sizes must produce two different
    /// magnifications, each matching what that size's own viewport wants.
    ///
    /// Jon's ruling M3 (#271, 2026-09-13): on the Mac, Fit never goes above Actual Size. So what a
    /// size's viewport wants is `min(fit-to-viewport, Actual Size)`, and Actual Size is a property of
    /// the display the window is on (`currentActualScale`): 1.507 on a 2560x1440 display at 2x,
    /// 0.835 on the display the v4.2.0 release run's window landed on. That is why the test's old
    /// uncapped expectation failed there. The two tracking sizes are small enough that Fit stays
    /// below any plausible Actual Size, so "Fit tracks the viewport" is still really checked on
    /// every display. The large size checks the cap itself.
    @Test @MainActor func zoomFitTracksTheViewportAcrossAResize() throws {
        let state = try rulingState()
        let controller = DocumentWindowController(state: state)
        let content = try #require(controller.window?.contentView)
        let scrollView = try #require(
            RenderProbeKit.descendants(content).compactMap { $0 as? NSScrollView }.first)
        // Legacy, pinned — overlay scrollers take 0pt and this would pass while measuring
        // nothing, the same trap `askingForFitTwiceGivesTheSameAnswer` (WiringTests) documents.
        scrollView.scrollerStyle = .legacy
        controller.showWindow(nil)
        controller.setZoom(.fit)

        let page = DocumentRenderer.render(state).pageSize

        /// The magnification Fit must produce at `size`: the viewport's fit, capped at Actual Size (M3).
        func settle(at size: NSSize) -> (magnification: CGFloat, wanted: CGFloat, fit: CGFloat, viewport: CGSize) {
            controller.window?.setContentSize(size)
            let viewport = scrollView.contentView.frame.size
            let fit = min(viewport.width / page.width, viewport.height / page.height)
            return (controller.currentMagnification, min(fit, controller.currentActualScale), fit, viewport)
        }

        let small = settle(at: NSSize(width: 600, height: 450))
        #expect(small.fit < controller.currentActualScale,
                "600x450 no longer fits below Actual Size (\(controller.currentActualScale)) — pick a smaller tracking size")
        #expect(abs(small.magnification - small.wanted) < 0.01,
                "at 600x450 Fit is \(small.magnification) but the viewport (\(small.viewport)) wants \(small.wanted)")

        let medium = settle(at: NSSize(width: 800, height: 600))
        #expect(medium.fit < controller.currentActualScale,
                "800x600 no longer fits below Actual Size (\(controller.currentActualScale)) — pick a smaller tracking size")
        #expect(abs(medium.magnification - medium.wanted) < 0.01,
                "at 800x600 Fit is \(medium.magnification) but the viewport (\(medium.viewport)) wants \(medium.wanted)")
        #expect(abs(small.magnification - medium.magnification) > 0.01,
                "Fit produced the same magnification at two different window sizes — the page is stuck at one scale")

        let large = settle(at: NSSize(width: 1400, height: 1000))
        #expect(abs(large.magnification - large.wanted) < 0.01,
                "at 1400x1000 Fit is \(large.magnification); the viewport's fit \(large.fit) capped at Actual Size \(controller.currentActualScale) (M3) is \(large.wanted)")
    }

    /// A manual Page Size choice must visibly change the page, even in Native style — the
    /// concrete case of "selections don't visibly take effect": the popup's label used to
    /// change while `DocumentRenderer` went on ignoring `state.pageSize` entirely.
    @Test @MainActor func manualPageSizeVisiblyChangesTheNativePage() throws {
        let state = try rulingState()
        let before = DocumentRenderer.render(state).pageSize
        state.setPageSize(.usLegal)
        let after = DocumentRenderer.render(state).pageSize
        #expect(after == NamedPageSize.usLegal.sizeInPoints,
                "choosing Legal did not change the printed page — was \(before), is \(after)")
        #expect(after != before)
    }

    /// The bottom bar's popup and the menu's equivalent command must produce the SAME result —
    /// the concrete regression for "same action path": both go through `setStyle`.
    @Test @MainActor func stylePopupAndMenuAgree() throws {
        let state = try rulingState()
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)

        controller.bottomBarDidChooseStyle(.modern)
        #expect(state.style.value == .modern)
        #expect(DocumentRenderer.render(state).clipsLines == false, "Modern style did not apply")

        controller.showPrintedStyle(nil)
        #expect(state.style.value == .printed)
        #expect(DocumentRenderer.render(state).clipsLines == true, "the menu's Printed command did not apply")
    }

    // MARK: - Ruling 5: Edit ▸ Change Variant

    /// Exactly the four formats, in order, each wired to a real re-parse — not merely present,
    /// but reaching `DocumentState.setVariant` when invoked, with a checkmark that follows the
    /// active one and no other.
    @Test @MainActor func changeVariantSubmenuIsExactAndWiredToAReparse() throws {
        let menu = MainMenu.build()
        let edit = try #require(menu.items.first(where: { $0.title == "Edit" })?.submenu,
                                "no Edit menu")
        let change = try #require(edit.items.first(where: { $0.title == "Change Variant" })?.submenu,
                                  "no Change Variant submenu")
        #expect(change.items.map(\.title) == ["WS4", "WS5+", "Printstream", "Text"])

        let state = try rulingState()
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)

        let variants: [Variant] = [.ws4, .ws5plus, .printstream, .text]
        for (title, variant) in zip(change.items.map(\.title), variants) {
            let item = try #require(change.items.first { $0.title == title })
            let action = try #require(item.action, "\(title) has no action — a dead menu item")
            #expect(DocumentWindowController.instancesRespond(to: action),
                    "\(title) -> \(NSStringFromSelector(action)) — nothing implements it")

            // Drive the REAL selector, not the model directly — the distinction GoMenuTests
            // draws: this proves the MENU reaches the controller, not just that the controller
            // can do the thing if asked some other way.
            controller.perform(action, with: nil)
            #expect(state.variant.value == variant, "\(title) did not re-parse to \(variant)")
            #expect(state.variant.provenance == .manual)

            for candidate in change.items {
                _ = controller.validateMenuItem(candidate)
                let shouldCheck = candidate === item
                #expect((candidate.state == .on) == shouldCheck,
                        "\(candidate.title) checkmark is wrong while \(title) is active")
            }
        }
    }

    /// Choosing an already-active variant must still go through the parse, not a short-circuit
    /// on "nothing changed" — `DocumentState.setVariant` has no such guard, and this is the
    /// test that would fail if one were added: selecting WS4 while WS4 is already active, twice
    /// in a row through the real menu selector, must leave the variant manual and the document
    /// re-derived consistently both times.
    @Test @MainActor func changeVariantForcesAReparseEvenWhenAlreadyActive() throws {
        let state = try rulingState()
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)

        controller.changeVariantToWS4(nil)
        #expect(state.variant.value == .ws4)
        #expect(state.variant.provenance == .manual)
        let firstPageCount = DocumentRenderer.render(state).pageCount

        controller.changeVariantToWS4(nil)
        #expect(state.variant.value == .ws4)
        #expect(state.variant.provenance == .manual)
        let secondPageCount = DocumentRenderer.render(state).pageCount

        #expect(firstPageCount == secondPageCount,
                "two parses of the same bytes under the same variant disagreed: \(firstPageCount) then \(secondPageCount)")
    }
}
