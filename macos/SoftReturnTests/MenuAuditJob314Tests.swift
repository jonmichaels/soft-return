import AppKit
import Testing
@testable import SoftReturn

/// Job 314 (b19) — the PERMANENT menu audit ("Part of your uniqueness test should include a
/// full audit" — Jon), plus verification that this job's own shortcut wiring and View menu
/// restructuring landed. The two audit tests below are the regression gate that outlives this
/// job: any future menu item that collides with an existing shortcut fails
/// `theBuiltMenuTreeHasNoDuplicateKeyboardShortcuts` immediately, and
/// `menuAuditReportsEveryItemWithNoShortcut` gives a standing, non-failing surface of what
/// still has none.
@MainActor
private enum MenuAudit {
    /// Every item in `menu`, depth-first, submenus included — the WHOLE built tree in one
    /// pass. `GoMenuTests.everyGoMenuItemResolvesToAResponder` walked one submenu; this
    /// generalizes that shape to the entire bar, per the brief.
    static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for item in menu.items {
            out.append(item)
            if let submenu = item.submenu {
                out += allItems(in: submenu)
            }
        }
        return out
    }
}

// MARK: - 1. FAILS on any duplicate keyEquivalent+modifierMask pair

@Test @MainActor func theBuiltMenuTreeHasNoDuplicateKeyboardShortcuts() throws {
    let items = MenuAudit.allItems(in: MainMenu.build())
    var byShortcut: [String: [String]] = [:]
    for item in items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
        // Case-insensitive on the key itself (AppKit treats Shift as a MODIFIER, not an
        // uppercase letter, in every shortcut this app builds — see MainMenu's own "i"/"I"
        // pairs for Show Invisibles vs Show Document Info) plus the resolved modifier mask,
        // which is `.command` even for items that never set it explicitly (NSMenuItem's own
        // default), so two items differing only by an unset vs. explicit `.command` still
        // collide correctly.
        let key = "\(item.keyEquivalent.lowercased())#\(item.keyEquivalentModifierMask.rawValue)"
        byShortcut[key, default: []].append(item.title)
    }
    let collisions = byShortcut.filter { $0.value.count > 1 }
    #expect(collisions.isEmpty, "duplicate keyEquivalent+modifierMask pairs: \(collisions)")
}

// MARK: - 2. Informational report of every item with NO shortcut

/// Not a failure — an audit surface. Leaf items only (a submenu-carrying item like "File" or
/// "Page Size" has no shortcut of its own by design; listing those would just be noise).
@Test @MainActor func menuAuditReportsEveryItemWithNoShortcut() throws {
    let items = MenuAudit.allItems(in: MainMenu.build())
    let unshortcut = items
        .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.keyEquivalent.isEmpty }
        .map(\.title)
        .sorted()
    let report = "Menu items with no keyboard shortcut (\(unshortcut.count)):\n"
        + unshortcut.joined(separator: "\n")
    Attachment.record(Data(report.utf8), named: "job314-menu-items-without-shortcuts.txt")
    print(report)
}

// MARK: - Job 314's own shortcuts, verified individually

@Test @MainActor func viewStyleItemsCarryOptionCommandDigitShortcuts() throws {
    let view = try #require(MainMenu.build().items.first(where: { $0.title == "View" })?.submenu)
    let expectations: [(String, String)] = [("Native", "1"), ("Printed", "2"), ("Modern", "3")]
    for (title, key) in expectations {
        let item = try #require(view.items.first { $0.title == title }, "missing View ▸ \(title)")
        #expect(item.keyEquivalent == key)
        #expect(item.keyEquivalentModifierMask == [.command, .option], "\(title) must be ⌥⌘\(key)")
    }
}

@Test @MainActor func showInvisiblesIsShiftCommandI() throws {
    let view = try #require(MainMenu.build().items.first(where: { $0.title == "View" })?.submenu)
    let item = try #require(view.items.first { $0.title == "Show Invisibles" })
    #expect(item.keyEquivalent == "i")
    #expect(item.keyEquivalentModifierMask == [.command, .shift])
}

@Test @MainActor func showDocumentInfoIsCommandIAndFollowsShowInvisiblesInTheShowGroup() throws {
    let view = try #require(MainMenu.build().items.first(where: { $0.title == "View" })?.submenu)
    let titles = view.items.map(\.title)
    let invisiblesIndex = try #require(titles.firstIndex(of: "Show Invisibles"))
    let infoIndex = try #require(titles.firstIndex(of: "Show Document Info"))
    #expect(infoIndex == invisiblesIndex + 1,
            "Show Document Info must directly follow Show Invisibles (the \"Show\" group)")

    let item = try #require(view.items.first { $0.title == "Show Document Info" })
    #expect(item.keyEquivalent == "i")
    #expect(item.keyEquivalentModifierMask == [.command])
    #expect(item.action == #selector(DocumentWindowController.toggleDocumentInfo(_:)))
}

// MARK: - View menu structure: Page Size / Margins submenus

@Test @MainActor func pageSizeAndMarginsAreSubmenusBetweenZoomAndFullScreen() throws {
    let view = try #require(MainMenu.build().items.first(where: { $0.title == "View" })?.submenu)
    let titles = view.items.map(\.title)
    let zoomOutIndex = try #require(titles.firstIndex(of: "Zoom Out"))
    let pageSizeIndex = try #require(titles.firstIndex(of: "Page Size"))
    let marginsIndex = try #require(titles.firstIndex(of: "Margins"))
    let fullScreenIndex = try #require(titles.firstIndex(of: "Enter Full Screen"))
    #expect(zoomOutIndex < pageSizeIndex, "Page Size must come after Zoom")
    #expect(pageSizeIndex < marginsIndex, "Margins must come after Page Size")
    #expect(marginsIndex < fullScreenIndex, "Enter Full Screen must stay last")

    let pageSizeSubmenu = try #require(view.items.first { $0.title == "Page Size" }?.submenu)
    #expect(pageSizeSubmenu.items.map(\.title) == ["US Letter", "US Legal", "A4"])

    let marginsSubmenu = try #require(view.items.first { $0.title == "Margins" }?.submenu)
    #expect(marginsSubmenu.items.map(\.title) == ["Embedded", "Factory", "Sawyer", "Modern"])
    #expect(!marginsSubmenu.items.map(\.title).contains("Use as Default for Quick Look"),
            "Margins submenu must not replicate Use as Default for Quick Look (removed per the brief)")
}

// MARK: - Submenu checkmarks and shared apply path

@MainActor
private func makeController(fixture: String = "report.ps") throws -> DocumentWindowController {
    let url = Oracle.fixturesDirectory.appendingPathComponent(fixture)
    let state = try Oracle.state(for: url)
    return DocumentWindowController(state: state)
}

@Test @MainActor func pageSizeSubmenuChecksTheCurrentSelectionAndAppliesThroughTheSharedPath() throws {
    let controller = try makeController()
    let letterItem = NSMenuItem(
        title: "US Letter", action: #selector(DocumentWindowController.choosePageSizeUSLetter(_:)), keyEquivalent: "")
    let legalItem = NSMenuItem(
        title: "US Legal", action: #selector(DocumentWindowController.choosePageSizeUSLegal(_:)), keyEquivalent: "")

    controller.choosePageSizeUSLegal(nil)
    #expect(controller.documentState.pageSize.value == .usLegal,
            "the menu action must drive setPageSize, the SAME method the bottom bar's popup calls")
    _ = controller.validateMenuItem(legalItem)
    #expect(legalItem.state == .on)
    _ = controller.validateMenuItem(letterItem)
    #expect(letterItem.state == .off)
}

@Test @MainActor func marginsSubmenuChecksTheCurrentSelectionAndAppliesThroughTheSharedPath() throws {
    let controller = try makeController()
    let sawyerItem = NSMenuItem(
        title: "Sawyer", action: #selector(DocumentWindowController.chooseMarginsSawyer(_:)), keyEquivalent: "")
    let fromDocItem = NSMenuItem(
        title: "Embedded", action: #selector(DocumentWindowController.chooseMarginsFromDocument(_:)), keyEquivalent: "")

    controller.chooseMarginsSawyer(nil)
    #expect(controller.documentState.pageSettingsPreset.value == .sawyer)
    _ = controller.validateMenuItem(sawyerItem)
    #expect(sawyerItem.state == .on)
    _ = controller.validateMenuItem(fromDocItem)
    #expect(fromDocItem.state == .off)

    controller.chooseMarginsFromDocument(nil)
    #expect(controller.documentState.pageSettingsPreset.value == nil)
    _ = controller.validateMenuItem(fromDocItem)
    #expect(fromDocItem.state == .on)
}

@Test @MainActor func showDocumentInfoMenuItemTitleTogglesWithThePanel() throws {
    let controller = try makeController()
    controller.showWindow(nil)
    let item = NSMenuItem(
        title: "Show Document Info", action: #selector(DocumentWindowController.toggleDocumentInfo(_:)), keyEquivalent: "")

    _ = controller.validateMenuItem(item)
    #expect(item.title == "Show Document Info")

    controller.toggleDocumentInfo(nil)
    _ = controller.validateMenuItem(item)
    #expect(item.title == "Hide Document Info")

    controller.toggleDocumentInfo(nil)
    _ = controller.validateMenuItem(item)
    #expect(item.title == "Show Document Info")
}
