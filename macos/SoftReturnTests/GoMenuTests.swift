import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Page navigation — the Go menu.
///
/// A test enters where the user enters. These drive the menu items' own selectors through the
/// controller, not `PagedDocumentView.showPage` directly, because the defect that made this
/// phase necessary was precisely that `showPage` existed and NOTHING CALLED IT. A test that
/// called it directly would have passed the whole time the feature was unreachable.

@MainActor
private func makeMultiPageController() throws -> DocumentWindowController {
    let url = Oracle.fixturesDirectory.appendingPathComponent("report.ps")
    let state = try Oracle.state(for: url)
    let controller = DocumentWindowController(state: state)
    controller.showWindow(nil)
    return controller
}

/// Every Go menu item reaches something that implements it.
///
/// `#selector` literals compile against a method that may be renamed later; the menu item then
/// looks fine and does nothing. This walks the built menu rather than listing selectors by
/// hand, so items added after this test still get covered.
@Test @MainActor func everyGoMenuItemResolvesToAResponder() throws {
    let menu = MainMenu.build()
    let go = try #require(menu.items.first(where: { $0.title == "Go" })?.submenu,
                          "no Go menu — page navigation is unreachable")

    let responders: [AnyClass] = [
        DocumentWindowController.self, WSDocument.self, AppDelegate.self,
        NSWindow.self, NSWindowController.self, NSDocument.self, NSResponder.self,
    ]
    var dead: [String] = []
    for item in go.items where !item.isSeparatorItem {
        guard let action = item.action else {
            dead.append("\(item.title): no action at all")
            continue
        }
        if !responders.contains(where: { $0.instancesRespond(to: action) }) {
            dead.append("\(item.title) -> \(NSStringFromSelector(action))")
        }
    }
    #expect(dead.isEmpty, "Go menu items nothing implements: \(dead.joined(separator: ", "))")
}

/// The Go menu sits between View and Window, as the spec and Preview both place it.
@Test @MainActor func theGoMenuIsWhereMacUsersExpectIt() {
    let titles = MainMenu.build().items.map(\.title)
    guard let go = titles.firstIndex(of: "Go"),
          let view = titles.firstIndex(of: "View"),
          let window = titles.firstIndex(of: "Window") else {
        Issue.record("missing one of View / Go / Window: \(titles)")
        return
    }
    #expect(view < go && go < window, "Go is at \(go), between View \(view) and Window \(window)")
}

/// Navigation moves through the document and STOPS at both ends — no wrap, per spec.
@Test @MainActor func pageNavigationIsBoundedAtBothEnds() throws {
    let controller = try makeMultiPageController()
    try #require(controller.pageTotal > 1,
                 "fixture laid out \(controller.pageTotal) page(s) — this test needs several")

    controller.goFirstPage(nil)
    #expect(controller.currentPage == 0)

    // Walking up from the first page must not wrap to the last.
    controller.goUp(nil)
    #expect(controller.currentPage == 0, "Up wrapped past the first page")

    controller.goLastPage(nil)
    #expect(controller.currentPage == controller.pageTotal - 1)

    controller.goDown(nil)
    #expect(controller.currentPage == controller.pageTotal - 1, "Down wrapped past the last page")

    controller.goFirstPage(nil)
    controller.goDown(nil)
    #expect(controller.currentPage == 1, "Down from page 1 did not reach page 2")
}

/// The menu items disable at the ends rather than sitting live and doing nothing.
@Test @MainActor func theGoMenuDisablesItselfAtTheEnds() throws {
    let controller = try makeMultiPageController()
    try #require(controller.pageTotal > 1)

    let up = NSMenuItem(title: "Up", action: #selector(DocumentWindowController.goUp(_:)), keyEquivalent: "")
    let down = NSMenuItem(title: "Down", action: #selector(DocumentWindowController.goDown(_:)), keyEquivalent: "")

    controller.goFirstPage(nil)
    #expect(controller.validateMenuItem(up) == false, "Up is enabled on the first page")
    #expect(controller.validateMenuItem(down) == true, "Down is disabled with pages below")

    controller.goLastPage(nil)
    #expect(controller.validateMenuItem(up) == true, "Up is disabled with pages above")
    #expect(controller.validateMenuItem(down) == false, "Down is enabled on the last page")
}
