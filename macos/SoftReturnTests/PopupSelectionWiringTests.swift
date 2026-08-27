import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// POPUP SELECTION WIRING — the real path, not a stand-in for it.
///
/// Jon's round 3 finding: choosing an item from a bottom-bar popup did NOTHING in the
/// running app, despite a wiring test that dispatched `NSApp.sendAction(action, to:
/// item.target, from: styleButton)` — passing the BUTTON as `from:` by hand. No real menu
/// click ever assembles that triple. A real click is `NSMenu` choosing an item and sending
/// ITS OWN idea of target/action/sender, whatever that happens to be wired to; the old test
/// substituted its own idea instead, and stayed green through the entire regression.
///
/// `NSMenu.performActionForItem(at:)` is the fix: "as if the user had chosen it" — the
/// genuine dispatch, using whatever target/action AppKit actually has on that item right
/// now. This is exactly the call that hung the app when `BottomBar`'s items still carried
/// their own `target`/`action` (see `BottomBar.init`'s comment on the fix): the real click
/// path routed straight into a handler typed for `NSPopUpButton`, fed an `NSMenuItem`.
@MainActor
private final class CapturingBottomBarDelegate: BottomBarDelegate {
    var variantCalls: [Variant?] = []
    var styleCalls: [ViewStyle] = []
    var zoomCalls: [ZoomSetting] = []
    var pageCalls: [NamedPageSize] = []
    var pageSettingsCalls: [DocumentOperations.PageSettingsPreset?] = []

    func bottomBarDidChooseVariant(_ variant: Variant?) { variantCalls.append(variant) }
    func bottomBarDidChooseStyle(_ style: ViewStyle) { styleCalls.append(style) }
    func bottomBarDidChooseZoom(_ zoom: ZoomSetting) { zoomCalls.append(zoom) }
    func bottomBarDidChoosePageSize(_ size: NamedPageSize) { pageCalls.append(size) }
    func bottomBarDidChoosePageSettings(_ preset: DocumentOperations.PageSettingsPreset?) {
        pageSettingsCalls.append(preset)
    }
}

@MainActor
private func popup(_ identifier: String, in bar: BottomBar) throws -> NSPopUpButton {
    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    return try #require(
        descendants(bar).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == identifier },
        "no popup with identifier \(identifier)")
}

/// Chooses `title` in `popup` the way `NSMenu` itself does when a person clicks an item:
/// looks up its index and asks the menu to perform that item's action, whatever target and
/// action are actually attached to it right now. This is deliberately NOT
/// `NSApp.sendAction(_:to:from:)` called with a hand-picked sender — that was the old
/// test's shortcut, and it is exactly what let the real break through.
@MainActor
private func chooseByTitle(_ title: String, in popup: NSPopUpButton) throws {
    let menu = try #require(popup.menu, "popup has no menu")
    let index = try #require(menu.items.firstIndex { $0.title == title },
                             "no item titled '\(title)'")
    menu.performActionForItem(at: index)
}

@Test @MainActor func choosingAStyleThroughTheRealMenuReachesTheDelegate() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    let bar = BottomBar()
    let delegate = CapturingBottomBarDelegate()
    bar.delegate = delegate
    bar.update(from: state)

    let styleButton = try popup("style-control", in: bar)
    try chooseByTitle(ViewStyle.modern.displayName, in: styleButton)

    #expect(delegate.styleCalls == [.modern],
            "a real click on the style popup did not reach BottomBarDelegate")
}

@Test @MainActor func choosingAVariantThroughTheRealMenuReachesTheDelegate() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    let bar = BottomBar()
    let delegate = CapturingBottomBarDelegate()
    bar.delegate = delegate
    bar.update(from: state)

    let variantButton = try popup("variant-control", in: bar)
    // WS4 is what `dropped-chapter.ws4` already detects as, so Printstream is a genuine
    // change of value, not a same-value no-op that could pass by accident.
    try chooseByTitle("Printstream", in: variantButton)

    #expect(delegate.variantCalls == [.printstream],
            "a real click on the variant popup did not reach BottomBarDelegate")
}

@Test @MainActor func choosingAZoomThroughTheRealMenuReachesTheDelegate() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    let bar = BottomBar()
    let delegate = CapturingBottomBarDelegate()
    bar.delegate = delegate
    bar.update(from: state)

    let zoomButton = try popup("zoom-control", in: bar)
    try chooseByTitle("Actual", in: zoomButton)

    #expect(delegate.zoomCalls == [.actual],
            "a real click on the zoom popup did not reach BottomBarDelegate")
}

@Test @MainActor func choosingAPageSizeThroughTheRealMenuReachesTheDelegate() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    let bar = BottomBar()
    let delegate = CapturingBottomBarDelegate()
    bar.delegate = delegate
    bar.update(from: state)

    let pageButton = try popup("page-size-control", in: bar)
    let target = try #require(NamedPageSize.allCases.first { $0 != state.pageSize.value })
    try chooseByTitle(target.displayName, in: pageButton)

    #expect(delegate.pageCalls == [target],
            "a real click on the page size popup did not reach BottomBarDelegate")
}

@Test @MainActor func choosingAPageSettingsPresetThroughTheRealMenuReachesTheDelegate() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    let bar = BottomBar()
    let delegate = CapturingBottomBarDelegate()
    bar.delegate = delegate
    bar.update(from: state)

    let pageSettingsButton = try popup("page-settings-control", in: bar)
    try chooseByTitle("Sawyer", in: pageSettingsButton)

    #expect(delegate.pageSettingsCalls == [.sawyer],
            "a real click on the page settings popup did not reach BottomBarDelegate")
}

/// Job 315 (b19 item 10): "Use as Default for Quick Look" is gone from this popup — its
/// function moved to Settings' own "Quick Look Margins" pulldown. Regression guard: the
/// item must not be findable in the real menu at all, not merely unreachable by click.
@Test @MainActor func useAsDefaultForQuickLookIsNoLongerInTheMarginsPopup() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
    let state = try Oracle.state(for: url)
    state.setPageSettingsPreset(.modern)
    let bar = BottomBar()
    bar.update(from: state)

    let pageSettingsButton = try popup("page-settings-control", in: bar)
    let titles = pageSettingsButton.menu?.items.map(\.title) ?? []
    #expect(!titles.contains("Use as Default for Quick Look"))
}
