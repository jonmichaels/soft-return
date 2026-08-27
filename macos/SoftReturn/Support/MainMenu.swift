import AppKit

/// The menu bar, built in code.
///
/// Every item marked ▸ in the build spec gets its STANDARD contents — Services, Open
/// Recent, Find, Speech and the Window submenus are AppKit's, handed over by setting the
/// application's corresponding property or by using the system's own action selectors.
/// Rebuilding any of them would be a defect even if it looked identical: they carry
/// behaviour (recent-document tracking, service discovery, the find bar's state) that a
/// lookalike does not.
///
/// Items with no explicit target go to the first responder, which is how a document window
/// gets Copy and Select All for free from the text view, and how they correctly grey out
/// when no document is open.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(goMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        #if DEBUG
        main.addItem(debugMenu())
        #endif
        return main
    }

    // MARK: - App

    /// NOTE on titles: every top-level item below is created with an explicit title.
    /// `NSMenuItem()` does NOT produce an untitled item — it produces one titled literally
    /// "NSMenuItem", which is what the menu bar then displays.
    private static func appMenu() -> NSMenuItem {
        // AppKit substitutes the bundle name for the first item's title; it still must not
        // be the "NSMenuItem" that a bare init() would leave behind.
        let item = NSMenuItem(title: "Soft Return", action: nil, keyEquivalent: "")
        let menu = NSMenu()

        menu.addItem(withTitle: "About Soft Return",
                     action: #selector(AppDelegate.showAbout(_:)),
                     keyEquivalent: "")
        add(to: menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), "")
        menu.addItem(.separator())
        add(to: menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        add(to: menu, "Command Line Tool…",
            #selector(AppDelegate.showCommandLineToolHelp(_:)), "")
        menu.addItem(.separator())

        // Services ▸ — AppKit fills this once it is handed over.
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        add(to: menu, "Hide Soft Return", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = add(to: menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add(to: menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        menu.addItem(.separator())
        add(to: menu, "Quit Soft Return", #selector(NSApplication.terminate(_:)), "q")

        item.submenu = menu
        return item
    }

    // MARK: - File

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "File")

        add(to: menu, "Open…", #selector(AppDelegate.openDocument(_:)), "o")

        // Open Recent ▸ is deliberately NOT built here. AppKit inserts and manages its own
        // for a document-based app, immediately after the Open item — building one too
        // produced literally two "Open Recent" menus side by side. Its contents, its Clear
        // Menu item and its persistence are all AppKit's, which is exactly what [SYS] means.

        menu.addItem(.separator())
        add(to: menu, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())

        add(to: menu, "Repair Permissions…", #selector(AppDelegate.prepareFiles(_:)), "")
        menu.addItem(.separator())
        let exportAs = add(to: menu, "Export As…", #selector(DocumentWindowController.exportAs(_:)), "e")
        exportAs.keyEquivalentModifierMask = [.command, .shift]

        let batch = add(to: menu, "Batch Export…", #selector(AppDelegate.showBatchWindow(_:)), "e")
        batch.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(.separator())
        add(to: menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        // NO Page Setup — deliberate, per the spec.

        item.submenu = menu
        return item
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")

        // A viewer: no Undo, Cut, Paste or Delete. Copy and Select All go to the first
        // responder, so the text view answers them and they grey out with no document.
        add(to: menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(to: menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())

        // Change Variant ▸ — the four formats the bottom bar's own menu offers (Auto is a
        // bottom-bar-only affordance; the menu re-parses under an explicit format, always).
        // Each item's action goes to the responder chain, exactly like View's Printed/
        // Modern, so `DocumentWindowController.validateMenuItem` can put a checkmark on the
        // current one and `changeVariant…` always forces a re-parse — see that method.
        let variant = NSMenuItem(title: "Change Variant", action: nil, keyEquivalent: "")
        let variantMenu = NSMenu(title: "Change Variant")
        variantMenu.identifier = NSUserInterfaceItemIdentifier("variant-menu")
        add(to: variantMenu, "WS4", #selector(DocumentWindowController.changeVariantToWS4(_:)), "")
        add(to: variantMenu, "WS5+", #selector(DocumentWindowController.changeVariantToWS5Plus(_:)), "")
        add(to: variantMenu, "Printstream", #selector(DocumentWindowController.changeVariantToPrintstream(_:)), "")
        add(to: variantMenu, "Text", #selector(DocumentWindowController.changeVariantToText(_:)), "")
        variant.submenu = variantMenu
        menu.addItem(variant)
        menu.addItem(.separator())

        // Find ▸ — the standard NSTextFinder set. Read-only viewer, so no Find & Replace.
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findItem(findMenu, "Find…", tag: NSTextFinder.Action.showFindInterface.rawValue, key: "f")
        findItem(findMenu, "Find Next", tag: NSTextFinder.Action.nextMatch.rawValue, key: "g")
        let previous = findItem(findMenu, "Find Previous",
                                tag: NSTextFinder.Action.previousMatch.rawValue, key: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        findItem(findMenu, "Use Selection for Find",
                 tag: NSTextFinder.Action.setSearchString.rawValue, key: "e")
        add(to: findMenu, "Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
        find.submenu = findMenu
        menu.addItem(find)

        // Speech ▸ — AppKit's own.
        let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let speechMenu = NSMenu(title: "Speech")
        add(to: speechMenu, "Start Speaking", #selector(NSTextView.startSpeaking(_:)), "")
        add(to: speechMenu, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)), "")
        speech.submenu = speechMenu
        menu.addItem(speech)

        item.submenu = menu
        return item
    }

    @discardableResult
    private static func findItem(_ menu: NSMenu, _ title: String, tag: Int, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(NSTextView.performTextFinderAction(_:)),
                              keyEquivalent: key)
        item.tag = tag
        menu.addItem(item)
        return item
    }

    // MARK: - Go

    /// Page navigation. Modelled on Preview's own Go menu, read off this Mac 2026-08-03:
    /// Up and Down are PLAIN arrows with no command modifier, and Go to Page… is ⌥⌘G.
    ///
    /// Two deliberate differences from Preview, both reported:
    /// - Preview has no First/Last Page in Go at all. The build spec asks for them, and an
    ///   omission is not a disagreement, so they are here — without key equivalents, so they
    ///   cannot collide with Home/End inside a text view.
    /// - Preview's Back/Forward (⌘[ / ⌘]) walk document history. This app has no history, so
    ///   they are omitted rather than added dead.
    private static func goMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Go")
        menu.identifier = NSUserInterfaceItemIdentifier("go-menu")

        let up = add(to: menu, "Up", #selector(DocumentWindowController.goUp(_:)),
                     String(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = []
        let down = add(to: menu, "Down", #selector(DocumentWindowController.goDown(_:)),
                       String(UnicodeScalar(NSDownArrowFunctionKey)!))
        down.keyEquivalentModifierMask = []

        menu.addItem(.separator())
        add(to: menu, "First Page", #selector(DocumentWindowController.goFirstPage(_:)), "")
        add(to: menu, "Last Page", #selector(DocumentWindowController.goLastPage(_:)), "")

        menu.addItem(.separator())
        add(to: menu, "Go to Page…", #selector(DocumentWindowController.goToPage(_:)), "g")
            .keyEquivalentModifierMask = [.command, .option]

        item.submenu = menu
        return item
    }

    // MARK: - View

    /// Job 314 (b19): Jon's ruling, Preview's sidebar pattern — ⌥⌘1/2/3 for the three
    /// styles, ⇧⌘I for Show Invisibles, ⌘I for Show Document Info (the "Show" group, right
    /// after Show Invisibles). Page Size ▸ / Margins ▸ join as submenus after Zoom, before
    /// Enter Full Screen — the same choices the bottom bar's own popups offer, kept in sync
    /// through `validateMenuItem` reading the SAME `documentState` properties, never a
    /// second source of truth.
    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")
        menu.identifier = NSUserInterfaceItemIdentifier("view-menu")

        add(to: menu, "Native", #selector(DocumentWindowController.showNativeStyle(_:)), "1")
            .keyEquivalentModifierMask = [.command, .option]
        add(to: menu, "Printed", #selector(DocumentWindowController.showPrintedStyle(_:)), "2")
            .keyEquivalentModifierMask = [.command, .option]
        add(to: menu, "Modern", #selector(DocumentWindowController.showModernStyle(_:)), "3")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        add(to: menu, "Show Invisibles", #selector(DocumentWindowController.toggleInvisibles(_:)), "i")
            .keyEquivalentModifierMask = [.command, .shift]
        add(to: menu, "Show Document Info", #selector(DocumentWindowController.toggleDocumentInfo(_:)), "i")
        menu.addItem(.separator())
        add(to: menu, "Continuous Scroll", #selector(DocumentWindowController.showContinuousScroll(_:)), "1")
        add(to: menu, "Single Page", #selector(DocumentWindowController.showSinglePage(_:)), "2")
        menu.addItem(.separator())
        add(to: menu, "Actual Size", #selector(DocumentWindowController.zoomActual(_:)), "0")
        add(to: menu, "Zoom to Fit", #selector(DocumentWindowController.zoomToFit(_:)), "9")
        add(to: menu, "Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+")
        add(to: menu, "Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-")
        menu.addItem(.separator())
        let pageSize = NSMenuItem(title: "Page Size", action: nil, keyEquivalent: "")
        pageSize.submenu = pageSizeMenu()
        menu.addItem(pageSize)
        let margins = NSMenuItem(title: "Margins", action: nil, keyEquivalent: "")
        margins.submenu = marginsMenu()
        menu.addItem(margins)
        menu.addItem(.separator())
        add(to: menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
            .keyEquivalentModifierMask = [.command, .control]

        item.submenu = menu
        return item
    }

    /// The bottom bar's Page Size popup, as a submenu — same three named sizes, same
    /// `NamedPageSize` titles, so nothing here can drift from what the footer offers.
    private static func pageSizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Page Size")
        menu.identifier = NSUserInterfaceItemIdentifier("page-size-menu")
        add(to: menu, NamedPageSize.usLetter.displayName,
            #selector(DocumentWindowController.choosePageSizeUSLetter(_:)), "")
        add(to: menu, NamedPageSize.usLegal.displayName,
            #selector(DocumentWindowController.choosePageSizeUSLegal(_:)), "")
        add(to: menu, NamedPageSize.a4.displayName,
            #selector(DocumentWindowController.choosePageSizeA4(_:)), "")
        return menu
    }

    /// The bottom bar's Margins popup, as a submenu — "Embedded" (job 315: was "From
    /// Document") plus the three named presets, in the footer's own order. Deliberately NOT
    /// "Use as Default for Quick Look": that action item was removed from every margins
    /// surface by job 315 (its function moved to Settings' own "Quick Look Margins"
    /// pulldown), so this submenu offers only the preset choices.
    private static func marginsMenu() -> NSMenu {
        let menu = NSMenu(title: "Margins")
        menu.identifier = NSUserInterfaceItemIdentifier("margins-menu")
        add(to: menu, DocumentOperations.PageSettingsPreset.embeddedChoiceName,
            #selector(DocumentWindowController.chooseMarginsFromDocument(_:)), "")
        add(to: menu, DocumentOperations.PageSettingsPreset.default.displayName,
            #selector(DocumentWindowController.chooseMarginsFactory(_:)), "")
        add(to: menu, DocumentOperations.PageSettingsPreset.sawyer.displayName,
            #selector(DocumentWindowController.chooseMarginsSawyer(_:)), "")
        add(to: menu, DocumentOperations.PageSettingsPreset.modern.displayName,
            #selector(DocumentWindowController.chooseMarginsModernDefaults(_:)), "")
        return menu
    }

    // MARK: - Window and Help

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")
        add(to: menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(to: menu, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        menu.addItem(.separator())
        add(to: menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        item.submenu = menu
        // Handing it over is what makes AppKit list the open documents in it.
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Help")
        add(to: menu, "Soft Return Help", #selector(NSApplication.showHelp(_:)), "?")
        // Job 374 (SAMPLES IN-APP): placement call, not a ruling (brief's own words) — an
        // onboarding surface reads naturally right under the help item proper, above the
        // troubleshooting/admin items below it. Trivially movable: `buildMenuItem()` is the
        // ONLY call this needs and returns `nil` (nothing added, no dangling separator) when
        // the bundle carries no samples yet — see that type's own doc comment.
        if let sampleDocuments = SampleDocuments.buildMenuItem() {
            menu.addItem(.separator())
            menu.addItem(sampleDocuments)
        }
        menu.addItem(.separator())
        // Job 234: -1743 ("Not authorized to send Apple events") is a TCC decision made
        // before the event ever reaches this app — nothing in-process can catch or explain
        // it (see the job-AE-E2E finding). This is the discoverable fix-it surface instead.
        add(to: menu, "Using AppleScript & Automation…",
            #selector(AppDelegate.showAutomationHelp(_:)), "")
        menu.addItem(.separator())
        // Beta tool: how Jon reports ground truth about a display bug from ANY machine.
        add(to: menu, "Copy Display Diagnostics", #selector(AppDelegate.copyDisplayDiagnostics(_:)), "")
        menu.addItem(.separator())
        // Job 152 Part C: the aggressive backfill, replacing job-138's plain re-index item —
        // see `SpotlightBackfill`.
        add(to: menu, "Index All WordStar Documents…", #selector(AppDelegate.indexAllWordStarDocuments(_:)), "")
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    #if DEBUG
    /// DEBUG builds only, per the spec: the interface-notes loop back to the design site.
    private static func debugMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Debug")
        let note = add(to: menu, "Send Note…", #selector(AppDelegate.sendInterfaceNote(_:)), "")
        // No endpoint configured (the normal state — it is local-only config) means the
        // item is present but dead, and its tooltip says how to configure it.
        if InterfaceNoteSender.endpoint == nil {
            note.action = nil
            note.isEnabled = false
            note.toolTip = InterfaceNoteSender.unconfiguredReason
        }
        add(to: menu, "Show Accessibility Identifiers",
            #selector(AppDelegate.toggleIdentifierHUD(_:)), "")
        add(to: menu, "Dump View Tree",
            #selector(AppDelegate.dumpViewTree(_:)), "")
        item.submenu = menu
        return item
    }
    #endif

    // MARK: -

    @discardableResult
    private static func add(to menu: NSMenu, _ title: String,
                            _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menu.addItem(item)
        return item
    }
}
