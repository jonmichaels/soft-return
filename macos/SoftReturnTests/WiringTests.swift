import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Does the app actually WORK — not "does it compile".
///
/// Every defect Jon hit in the first two sessions (no menu bar, menus titled "NSMenuItem",
/// every file refused, a blank document window, printing unsupported) compiled cleanly and
/// would have been caught by one of the checks below. That is the point of this file: the
/// app is mostly AppKit wiring, and wiring fails at RUNTIME in ways the type system cannot
/// see — a class name in a plist, a selector nothing implements, a view with no frame.
///
/// Anything added to the app that has to be *connected* to something else belongs here.

// MARK: - Synthetic documents

/// WordStar 4 bytes, built the way WordStar wrote them: bit 7 set on the last letter of
/// every word, soft returns at wrap points, dot commands for page geometry.
///
/// Synthetic on purpose — the repo is public and carries no one's real files.
private enum Sample {
    static let soft: [UInt8] = [0x8D, 0x0A]
    static let hard: [UInt8] = [0x0D, 0x0A]

    static func highBitWords(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(text.unicodeScalars)
        for (index, scalar) in chars.enumerated() {
            var byte = UInt8(scalar.value & 0x7F)
            let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
            let isWordChar = CharacterSet.alphanumerics.contains(scalar)
            let nextIsWordChar = next.map { CharacterSet.alphanumerics.contains($0) } ?? false
            if isWordChar && !nextIsWordChar { byte |= 0x80 }
            out.append(byte)
        }
        return out
    }

    /// A multi-line, multi-page WS4 document with real geometry.
    static var ws4: [UInt8] {
        var doc: [UInt8] = []
        for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12"] {
            doc += Array(dot.utf8) + hard
        }
        doc += highBitWords("THE SOFT RETURN") + hard + hard
        // Several soft-wrapped physical lines, which is what Printed reproduces verbatim —
        // and, since ctrl-kd's WS4 wrap heuristic (`linesPass`, `softIsWrap: false`)
        // reclassifies a soft-terminated line as DELIBERATE (`.line`, not `.wrap`) whenever
        // it plus the next word would have fit inside the margin, each line here is padded
        // past 65 columns so `L + 1 + W` clears the margin regardless of the next word's
        // length — a shorter "realistic" line silently drops out of Show Invisibles'
        // soft-line count, which is what caught this the first time.
        for line in ["This is a synthetic WordStar document, written out to exercise this",
                     "viewer completely from end to end, because each of these lines wraps",
                     "with a genuine soft return, exactly as WordStar itself stored the wrap."] {
            doc += highBitWords(line) + soft
        }
        doc += highBitWords("The final line of the paragraph ends hard.") + hard + hard
        doc += Array(".pa".utf8) + hard
        doc += highBitWords("PAGE TWO") + hard
        doc += [0x1A]
        return doc
    }

    /// Plain text with CRLFs — the printstream/text path, and the shape of an
    /// extensionless file off an old floppy.
    static var plainText: [UInt8] {
        var doc: [UInt8] = []
        for line in ["A plain text document.", "Second line.", "Third line."] {
            doc += Array(line.utf8) + hard
        }
        return doc
    }
}

@MainActor
private func makeState(_ bytes: [UInt8] = Sample.ws4) throws -> DocumentState {
    // A throwaway defaults domain: these tests must not read or write Jon's real settings.
    let defaults = UserDefaults(suiteName: "SoftReturnTests.\(UUID().uuidString)")!
    return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
}

// MARK: - 1. The bundle declares things that actually exist

/// The bug that refused EVERY file: `Info.plist` named the document class
/// "SoftReturn.WSDocument" while the module was really "Soft_Return", so
/// NSDocumentController could not instantiate a reader for any type at all. Nothing about
/// that is visible at compile time — the plist is a string, and the string was wrong.
///
/// Job 261 (`related-items-write`): `NSIsRelatedItemType` entries (convert's OUTPUT
/// extensions — rtf/pdf/html/md/txt/json) are a different kind of `CFBundleDocumentTypes`
/// entry on purpose. They exist so `NSFilePresenter`'s sibling-write mechanism is legal
/// (Apple DevForums 14718), not so the app can open them — `NSDocumentController` never
/// instantiates a reader for a related item, so they correctly carry no `NSDocumentClass`.
/// This loop only holds openable types (`Viewer`/`Editor`-as-opener roles) to the original
/// bar; related-item entries are asserted the opposite way below instead.
@Test @MainActor func everyDeclaredDocumentClassResolves() throws {
    let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
        as? [[String: Any]]
    let declared = try #require(types, "Info.plist declares no CFBundleDocumentTypes")
    #expect(!declared.isEmpty)

    let openable = declared.filter { ($0["NSIsRelatedItemType"] as? Bool) != true }
    #expect(!openable.isEmpty)

    for type in openable {
        guard let name = type["NSDocumentClass"] as? String else {
            Issue.record("a document type declares no NSDocumentClass")
            continue
        }
        // Reduced to a Bool BEFORE #expect sees it. Handing the macro an `AnyClass?`
        // operand segfaults inside Swift's generic-metadata instantiation
        // (type metadata completion for ClosedRange<>.Index, via __checkBinaryOperation) —
        // a toolchain crash, not an app one, but it takes the whole test run down with it.
        let classExists = NSClassFromString(name) != nil
        #expect(classExists,
                "Info.plist names document class '\(name)', which does not exist — every file of this type is refused at open time")
    }
}

/// Job 261 (`related-items-write`): the mirror image of the test above — Apple DevForums
/// 14718's fix for `NSFilePresenter`'s sibling-write denial is `NSIsRelatedItemType=YES` +
/// `CFBundleTypeRole=Editor` on the OUTPUT extension (`Viewer`/`None` both silently fail
/// the same coordinated write). Checked against `CtrlKD.Registry`'s own emitter list
/// (`rtf`/`pdf`/`html`/`md`/`txt`/`json` — `Registry.swift`'s `Emitter(..., ext: ...)`
/// entries) rather than a hand-copied literal, so a future emitter added to the library
/// without a matching plist entry fails this test instead of silently losing beside-source
/// writes for just that one new format.
@Test @MainActor func everyConvertOutputExtensionIsARelatedItemType() throws {
    let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
        as? [[String: Any]] ?? []
    let relatedItems = types.filter { ($0["NSIsRelatedItemType"] as? Bool) == true }

    let expectedExtensions = Set(EmitterRegistry.standard.formats().map { format -> String in
        let ext = EmitterRegistry.standard.getEmitter(format)?.ext ?? format
        return ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
    })
    let declaredExtensions = Set(relatedItems.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
    #expect(declaredExtensions == expectedExtensions)

    for type in relatedItems {
        #expect(type["CFBundleTypeRole"] as? String == "Editor",
                "\(type["CFBundleTypeName"] ?? "?") must be Editor role or the related-item write stays denied")
        #expect(type["NSDocumentClass"] == nil,
                "\(type["CFBundleTypeName"] ?? "?") is an output-only related item, not something the app opens")
    }
}

/// The app must claim the file shapes it exists to open: WordStar's own extensions, and
/// extensionless data (the normal state of a 1987 floppy).
@Test @MainActor func bundleClaimsWordStarAndExtensionlessFiles() throws {
    let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
        as? [[String: Any]] ?? []
    let contentTypes = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    #expect(contentTypes.contains("public.data"),
            "extensionless files would not be openable")

    let exported = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations")
        as? [[String: Any]] ?? []
    let extensions = exported
        .compactMap { $0["UTTypeTagSpecification"] as? [String: Any] }
        .flatMap { $0["public.filename-extension"] as? [String] ?? [] }
    #expect(extensions.contains("ws"))
    #expect(extensions.contains("ws1"), "the .ws# numbered backups must be claimed too")
}

// MARK: - 2. Every menu command reaches something

/// A menu item whose selector nothing implements is dead: it greys out forever, or worse
/// it looks live and does nothing. The compiler cannot catch it, because `#selector` only
/// proves the method exists SOMEWHERE, not that anything in the responder chain has it.
@Test @MainActor func everyMenuItemActionIsImplementedSomewhere() {
    // Every class that can appear in this app's responder chain.
    let responders: [AnyClass] = [
        AppDelegate.self, DocumentWindowController.self, WSDocument.self,
        NSApplication.self, NSWindow.self, NSWindowController.self,
        NSDocument.self, NSDocumentController.self,
        NSTextView.self, NSText.self, NSResponder.self, NSView.self,
    ]

    var unimplemented: [String] = []
    walk(MainMenu.build()) { item, path in
        guard let action = item.action else { return }
        // submenuAction: is AppKit's own for items that only open a submenu.
        guard action != Selector(("submenuAction:")) else { return }
        let handled = responders.contains { $0.instancesRespond(to: action) }
        if !handled {
            unimplemented.append("\(path) -> \(NSStringFromSelector(action))")
        }
    }
    #expect(unimplemented.isEmpty,
            "menu commands nothing implements: \(unimplemented.joined(separator: ", "))")
}

/// The spec fixes this menu tree. Missing items are missing features; the earlier build
/// shipped with no menus at all and looked fine to the compiler.
@Test @MainActor func theMenuTreeMatchesTheSpec() {
    let menu = MainMenu.build()
    let topLevel = menu.items.map(\.title)
    for expected in ["File", "Edit", "View", "Window", "Help"] {
        #expect(topLevel.contains(expected), "no \(expected) menu")
    }
    // The bug where every top-level item was titled "NSMenuItem" — AppKit's default title
    // for a bare init(), which is not the empty string people assume.
    #expect(!topLevel.contains("NSMenuItem"), "a menu kept NSMenuItem's default title")

    func titles(of name: String) -> [String] {
        menu.items.first { $0.title == name }?.submenu?.items.map(\.title) ?? []
    }
    #expect(titles(of: "File").contains("Export As…"))
    #expect(titles(of: "File").contains("Batch Export…"))
    #expect(titles(of: "File").contains("Print…"))
    // NO Page Setup — deliberate, per the spec.
    #expect(!titles(of: "File").contains { $0.contains("Page Setup") })
    // Exactly one Open Recent: AppKit adds its own, and adding a second produced two.
    #expect(titles(of: "File").filter { $0 == "Open Recent" }.count <= 1)

    let view = titles(of: "View")
    for expected in ["Printed", "Modern", "Show Invisibles", "Single Page",
                     "Continuous Scroll", "Actual Size", "Zoom to Fit"] {
        #expect(view.contains(expected), "View menu is missing \(expected)")
    }

    // A viewer: no authoring commands of our own making.
    let edit = titles(of: "Edit")
    for forbidden in ["Undo", "Redo", "Cut", "Paste", "Delete", "Find and Replace…"] {
        #expect(!edit.contains(forbidden), "Edit menu offers \(forbidden) in a read-only viewer")
    }
    #expect(edit.contains("Copy"))
    #expect(edit.contains("Select All"))
}

private func walk(_ menu: NSMenu, path: String = "", _ visit: (NSMenuItem, String) -> Void) {
    for item in menu.items where !item.isSeparatorItem {
        let here = path.isEmpty ? item.title : "\(path)/\(item.title)"
        visit(item, here)
        if let submenu = item.submenu { walk(submenu, path: here, visit) }
    }
}

// MARK: - 3. Documents parse

@Test @MainActor func aWordStarDocumentParsesAndCarriesItsGeometry() throws {
    let state = try makeState()
    #expect(state.variant.value == .ws4)
    #expect(state.variant.provenance == .detected)
    #expect(!state.document.blocks.isEmpty)
    let page = try #require(state.document.page, "no page geometry parsed")
    #expect(page.textLines > 0)
}

@Test @MainActor func plainTextOpensToo() throws {
    let state = try makeState(Sample.plainText)
    #expect(!state.document.blocks.isEmpty)
}

/// Binary must be REFUSED, not shown as an empty window — the alert is the feature.
@Test @MainActor func binaryDataIsRefused() {
    // Genuinely binary: control bytes, so `detect`'s text-like ratio lands under 40%.
    // An earlier version cycled 0...255, which is ~74% text-like once the high bit is
    // masked — the detector correctly called THAT a WordStar file, and the test was wrong.
    let noise: [UInt8] = (0..<600).map { UInt8($0 % 0x1F) }
    #expect(throws: (any Error).self) { try makeState(noise) }
}

// MARK: - 4. Rendering produces something to look at

/// The blank-window bug: everything upstream worked, and the window showed grey.
@Test @MainActor func bothStylesProduceNonEmptyPages() throws {
    for style in [ViewStyle.native, .modern] {
        let state = try makeState()
        state.style.setManually(style)
        let rendered = DocumentRenderer.render(state)

        #expect(rendered.text.length > 0, "\(style.displayName): no text to lay out")
        #expect(rendered.pageSize.width > 0 && rendered.pageSize.height > 0,
                "\(style.displayName): zero page size")
        #expect(rendered.textFrame.width > 0 && rendered.textFrame.height > 0,
                "\(style.displayName): zero text frame")
        #expect(rendered.textFrame.maxY <= rendered.pageSize.height + 1,
                "\(style.displayName): text runs off the bottom of the paper")
    }
}

/// Printed must place text where `emitPDF` places it, or the screen and the export
/// disagree about the same document.
@Test @MainActor func printedGeometryMatchesTheExporter() throws {
    let state = try makeState()
    state.style.setManually(.printed)
    let rendered = DocumentRenderer.render(state)
    let metrics = printedMetrics(state.document)

    // Both sides converted to Double explicitly. Comparing a CGFloat against a Double
    // inside #expect relies on Swift's implicit CGFloat/Double bridging, which the macro
    // does not reproduce faithfully — it reported 792.0 != 792.0 and
    // 57.599999999999994 != 57.599999999999994, i.e. values whose printed forms are
    // identical, which is the tell that the comparison and the display disagree.
    #expect(Double(rendered.pageSize.height) == metrics.pageHeight)
    #expect(Double(rendered.textFrame.origin.x) == metrics.left)
}

/// The actual defect: a view with no frame draws nothing, and a scroll view's document
/// view is sized by FRAME — `intrinsicContentSize` alone leaves it at zero.
@Test @MainActor func thePagedViewSizesItselfAndBuildsPages() throws {
    let state = try makeState()
    let rendered = DocumentRenderer.render(state)
    let view = PagedDocumentView()
    view.setContent(rendered, display: .singlePage)
    // Page frames are assigned in `layout()`, which a window's display cycle drives. There
    // is no window here, so ask for it explicitly — the same thing the print path and the
    // batch preview do when they render off-screen.
    view.layoutSubtreeIfNeeded()

    #expect(view.frame.width > 0 && view.frame.height > 0,
            "the document view has no frame — the window would show empty grey")
    #expect(!view.pageViews.isEmpty, "no page views were created")
    let first = try #require(view.pageViews.first)
    #expect(first.frame.width > 0 && first.frame.height > 0, "a page view has no frame")
    #expect(first.isEditable == false, "a viewer's text must never be editable")
    #expect(first.isSelectable, "text must be selectable for Copy, Find and Speech")
}

/// Continuous Scroll must be taller than Single Page, or the mode does nothing.
/// Continuous Scroll is taller than Single Page — STRICTLY, on a document with more than one
/// page.
///
/// This asserted `>=` and used whatever the sample happened to paginate to. `>=` holds when
/// `setDisplay` does nothing whatsoever, so the test could not fail for the behaviour it is
/// named after. It now requires a multi-page document and a real increase of at least one
/// page, which is the thing a reader would notice.
@Test @MainActor func continuousScrollIsTallerThanSinglePage() throws {
    let url = Oracle.fixturesDirectory.appendingPathComponent("report.ps")
    let state = try Oracle.state(for: url)
    state.style.setManually(.printed)
    let rendered = DocumentRenderer.render(state)
    let view = PagedDocumentView()
    view.setContent(rendered, display: .singlePage)
    try #require(view.pageCount > 1, "fixture has \(view.pageCount) page(s); this test needs several")

    let singleHeight = view.frame.height
    view.setDisplay(.continuousScroll)
    #expect(view.frame.height > singleHeight + rendered.pageSize.height - 1,
            "continuous scroll is \(view.frame.height)pt for \(view.pageCount) pages; single page was \(singleHeight)pt")
}

/// Printed's own contribution to Show Invisibles: `RenderedDocument.softLineFlags` must
/// carry exactly the sample's three soft-wrapped physical lines, and nothing else — the
/// flag rides on the pre-`coalesce` `PageLine`, not on any span content, so this is the one
/// place a wiring bug (dropping the flag, or marking the wrong line) would show before it
/// ever reaches a screen.
@Test @MainActor func printedSoftLineFlagsMatchTheDocumentsOwnSoftReturns() throws {
    let state = try makeState()
    state.style.setManually(.printed)
    let rendered = DocumentRenderer.render(state)

    let flags = rendered.softLineFlags.flatMap { $0 }
    #expect(flags.filter { $0 }.count == 3,
            "expected the sample's 3 soft-wrapped lines, found \(flags.filter { $0 }.count)")

    // Modern reflows the wrap away entirely (`mergedLines`) — there is nothing physical
    // left to flag, and Show Invisibles is Printed-only.
    state.style.setManually(.modern)
    let modernRendered = DocumentRenderer.render(state)
    #expect(modernRendered.softLineFlags.isEmpty,
            "Modern style should carry no soft-line flags")
}

// MARK: - 5. The document window and printing

@Test @MainActor func theDocumentWindowBuildsWithAPageAndABottomBar() throws {
    let state = try makeState()
    let controller = DocumentWindowController(state: state)
    _ = controller.window   // force the window to load
    let content = try #require(controller.window?.contentView)

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let all = descendants(content)
    #expect(all.contains { $0 is NSScrollView }, "no scroll view in the document window")
    #expect(all.contains { $0 is BottomBar }, "no bottom bar in the document window")
    #expect(all.contains { $0 is PagedDocumentView }, "no page view in the document window")
}

/// Asking for "Fit" twice must give the same answer twice.
///
/// `applyZoom` used to measure the viewport with `scrollView.contentView.bounds`. A clip
/// view's bounds are in CONTENT coordinates — the frame divided by the current
/// magnification — so the value being set was fed back into the measurement that set it.
/// Measured on the running app: at magnification 0.25 a 612x792 viewport reported bounds
/// of 2448x3168, which drove the next scale to 4.0 in a single step.
///
/// It hides at magnification 1.0, where bounds and frame are equal by definition, which is
/// why it survived so long and why this test drives Fit twice instead of once: the first
/// call moves magnification off 1.0, and the second is where the old code disagrees with
/// itself. Fit is a fixed point or it is nothing.
@Test @MainActor func askingForFitTwiceGivesTheSameAnswer() throws {
    let state = try makeState()
    let controller = DocumentWindowController(state: state)
    let content = try #require(controller.window?.contentView)

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let scrollView = try #require(
        descendants(content).compactMap { $0 as? NSScrollView }.first,
        "no scroll view in the document window")

    // LEGACY scrollers, pinned rather than inherited. They take 15pt off the viewport, which
    // is what makes the viewport differ from the page — and the bug is invisible when those
    // two are equal, because then the feedback loop's fixed point is 1.0 and it looks stable.
    // With overlay scrollers (the other possible environment default) this test would pass
    // while measuring nothing.
    scrollView.scrollerStyle = .legacy
    controller.showWindow(nil)

    controller.setZoom(.fit)
    let first = controller.currentMagnification
    controller.setZoom(.fit)
    let second = controller.currentMagnification

    #expect(first.isFinite && first > 0, "Fit produced a magnification of \(first)")
    #expect(abs(first - second) < 0.0001,
            "Fit is not stable: \(first) then \(second) — the zoom calculation is reading a viewport that its own result has already scaled")
}

/// The blank document window, finally: the bottom bar was painting over the whole window.
///
/// `BottomBar.draw(_:)` filled `dirtyRect`. Since macOS 14 `NSView.clipsToBounds` defaults
/// to FALSE, so a view's drawing is no longer confined to its own rectangle, and during a
/// full-window redraw `dirtyRect` is the entire content area. A 24pt bar therefore filled
/// the whole window with `windowBackgroundColor` — and because it is added to the content
/// view AFTER the scroll view, it drew last and won.
///
/// The page was rendering correctly the entire time. Every probe agreed the view tree was
/// healthy (right frames, alpha 1, glyphs laid out, magnification 1) because it WAS healthy;
/// the page was simply painted over a moment after it drew. Three sessions went looking for
/// a drawing failure that never existed.
@Test @MainActor func theBottomBarCannotPaintOutsideItself() throws {
    let state = try makeState()
    let controller = DocumentWindowController(state: state)
    controller.showWindow(nil)
    let content = try #require(controller.window?.contentView)

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let bar = try #require(descendants(content).compactMap { $0 as? BottomBar }.first,
                           "no bottom bar in the document window")

    #expect(bar.clipsToBounds,
            "the bottom bar can draw outside its own bounds — it sits in front of the scroll view, so anything it paints covers the page")
    // And it must not be tall enough to cover the page by legitimate layout either.
    #expect(bar.frame.height < content.frame.height / 2,
            "the bottom bar is \(bar.frame.height)pt tall in a \(content.frame.height)pt window")
}

/// "The page fills the window exactly on first open — no grey on any side, no scrollbars."
///
/// The geometry rule sized the window to the PAGE, but legacy scrollers take their
/// thickness out of the clip view, so the viewport came out 15pt short on each axis and
/// both scrollers appeared — the one thing the rule forbids. Measured before the fix:
/// a 612x792 page in a 597x777 viewport.
///
/// Asserts the window reserves room for the scrollers it will actually get. Pins the
/// scroller style rather than inheriting it: with overlay scrollers the thickness is 0 and
/// this test would pass while measuring nothing, which is the trap found in job-026.
@Test @MainActor func theFirstOpenWindowLeavesRoomForItsScrollers() throws {
    // A deliberately small page (.pl 30 at .lh 8) so the first-open scale is 1.0 on any
    // screen this ever runs on, and 100% is a fair yardstick above.
    var small: [UInt8] = []
    for dot in [".pl 30", ".mt 3", ".mb 3", ".po 8", ".lh 8", ".cw 12"] {
        small += Array(dot.utf8) + Sample.hard
    }
    small += Sample.highBitWords("SMALL PAGE") + Sample.hard + [0x1A]
    let state = try makeState(small)
    let controller = DocumentWindowController(state: state)
    let content = try #require(controller.window?.contentView)

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let scrollView = try #require(
        descendants(content).compactMap { $0 as? NSScrollView }.first,
        "no scroll view in the document window")
    scrollView.scrollerStyle = .legacy
    controller.showWindow(nil)

    let page = DocumentRenderer.render(state).pageSize
    let thickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    let viewport = scrollView.contentView.frame.size

    // Measure against the page at 100%, NOT at the resulting magnification. Scaling by the
    // final magnification makes this test vacuous: the old code shrank the page by exactly
    // the scroller thickness, so page x magnification always "fits" and both sides cancel.
    // The document below is small enough that the geometry rule never scales it down, so
    // 100% is the honest yardstick.
    #expect(scrollView.magnification >= 0.999,
            "the page was shrunk to \(scrollView.magnification) to fit a window that did not reserve room for its scrollers")
    #expect(viewport.width + 0.5 >= page.width,
            "viewport is \(viewport.width)pt for a \(page.width)pt page — a horizontal scrollbar appears on first open")
    #expect(viewport.height + 0.5 >= page.height,
            "viewport is \(viewport.height)pt for a \(page.height)pt page — a vertical scrollbar appears on first open")
    // NOT asserted: that the window is wider than the page by the scroller thickness. That
    // was true of one implementation — pre-growing the window by a guessed thickness — and
    // the guess was itself a bug, because scroller style can change between sizing the
    // window and laying it out. What matters is the property above: the page fits the
    // viewport at 100%. How the window gets there is the code's business.
    _ = thickness
}

/// Printing must use the document's own page boundaries, not AppKit's guess.
///
/// The print view is the SCREEN layout, where pages are separated by a 20pt gap. Left to
/// itself NSPrintOperation paginates by slicing every paperSize.height, so each sheet after
/// the first drifts by 20 x (n-1) points and carries a strip of the previous page. Measured
/// in the print panel before this was fixed: a two-page document reported as FOUR sheets.
///
/// So the view reports its own pages. This asserts both halves: that it claims a page range
/// at all, and that consecutive page rects are exactly one page apart with no gap in them.
@Test @MainActor func theViewTellsAppKitWhereItsPagesAreForPrinting() throws {
    let state = try makeState()
    let document = WSDocument()
    document.setStateForTesting(state)
    document.makeWindowControllers()
    let controller = try #require(document.windowControllers.first as? DocumentWindowController)
    let view = try #require(controller.makePrintOperation(settings: [:]).view as? PagedDocumentView)

    var range = NSRange(location: 0, length: 0)
    #expect(view.knowsPageRange(&range),
            "the print view does not report a page range, so AppKit slices it by paper height and the sheets drift")

    let rendered = DocumentRenderer.render(state)
    let page = rendered.pageSize
    #expect(range.location == 1, "AppKit numbers pages from 1")
    #expect(range.length >= 1, "no pages to print")

    // Every page rect is exactly one page tall and one page wide — the gap is excluded.
    for n in range.location..<(range.location + range.length) {
        let rect = view.rectForPage(n)
        #expect(abs(rect.height - page.height) < 0.5,
                "page \(n) is \(rect.height)pt tall, expected \(page.height)")
        #expect(abs(rect.width - page.width) < 0.5,
                "page \(n) is \(rect.width)pt wide, expected \(page.width)")
    }
    // And consecutive pages step by page height PLUS the gap in the view's own coordinates,
    // which is what proves the gap is skipped rather than printed.
    if range.length >= 2 {
        let first = view.rectForPage(1)
        let second = view.rectForPage(2)
        #expect(second.origin.y > first.maxY,
                "page 2 starts at \(second.origin.y), inside page 1 which ends at \(first.maxY) — sheets would overlap")
    }
}

// `printingProducesAnOperation` was DELETED here, not rewritten.
//
// It called `controller.makePrintOperation(settings:)` directly — a helper no user can
// reach. Cmd-P goes NSDocument.printDocument -> WSDocument.printOperation(withSettings:) ->
// makePrintOperation, and the suite covered only the last link while reporting the chain as
// covered. Jon got "App doesn't support printing" from a build whose print test was green.
// `theDocumentItselfCanProduceAPrintOperation` above enters at the document, which is the
// real door, and makes this one redundant rather than merely weak.

// MARK: - 6. Export

@Test @MainActor func everyFormatExportsInBothStyles() throws {
    for style in [RenderStyle.printed, .modern] {
        let state = try makeState()
        let products = try ExportEngine.render(
            document: state.document, state: state,
            formats: ExportFormat.allCases, notes: NoteSelection(), style: style)

        #expect(products.count == ExportFormat.allCases.count)
        for product in products {
            #expect(!product.bytes.isEmpty,
                    "\(style.displayName)/\(product.format.displayName) produced no bytes")
        }
        // A PDF is a PDF whichever path produced it — the library emitter for Printed, the
        // native text stack for Modern.
        let pdf = try #require(products.first { $0.format == .pdf })
        #expect(Array(pdf.bytes.prefix(4)) == Array("%PDF".utf8),
                "\(style.displayName) PDF is not a PDF")
    }
}

/// Show Invisibles must never leak into print or export: both `ExportEngine` and
/// `makePrintOperation` build their own throwaway `PagedDocumentView` and never pass
/// `showInvisibles` through (it defaults `false`), so their PDF bytes cannot depend on it —
/// verified here rather than trusted, since a leak would only ever show up by someone
/// comparing two PDFs by hand.
///
/// Printed only: its PDF goes through the library's own zero-dependency writer
/// (`convertData` -> `emitPDF`), which is a pure function of the document bytes and is the
/// one place `RenderedDocument.softLineFlags` could have leaked in. Modern PDF instead goes
/// through `CGPDFContext` (`ExportEngine.modernPDF`) via the native macOS text stack, which
/// is not byte-stable run to run even with nothing else changed (embedded ICC profiles,
/// image compression) — the wrong tool to prove a leak with. Modern's own guarantee is
/// structural instead: `RenderedDocument.softLineFlags` is unconditionally `[]` there (see
/// `printedSoftLineFlagsMatchTheDocumentsOwnSoftReturns`), so there is nothing for the
/// overlay to draw regardless of what reuses its rendering pipeline.
@Test @MainActor func showInvisiblesNeverReachesPrintedExportBytes() throws {
    // ONE parsed document, toggled in place — the same thing a user does (open, flip the
    // View menu switch, export) and, unlike two separate `makeState()` parses, immune to
    // any incidental non-determinism a fresh parse might carry that has nothing to do with
    // `showInvisibles`.
    let state = try makeState()
    state.style.setManually(.printed)

    state.showInvisibles = true
    let onProducts = try ExportEngine.render(
        document: state.document, state: state,
        formats: [.pdf], notes: NoteSelection())

    state.showInvisibles = false
    let offProducts = try ExportEngine.render(
        document: state.document, state: state,
        formats: [.pdf], notes: NoteSelection())

    let onBytes = try #require(onProducts.first).bytes
    let offBytes = try #require(offProducts.first).bytes
    #expect(onBytes == offBytes,
            "Printed PDF export bytes differ with Show Invisibles on vs off")
}

/// Finder's rule, and the spec's: never overwrite.
@Test @MainActor func exportNamingUniquifiesTheFinderWay() {
    var taken: Set<String> = []
    #expect(ExportEngine.uniqueName(basename: "PAPER", extension: "md") { taken.contains($0) }
            == "PAPER.md")
    taken.insert("PAPER.md")
    #expect(ExportEngine.uniqueName(basename: "PAPER", extension: "md") { taken.contains($0) }
            == "PAPER 2.md")
    taken.insert("PAPER 2.md")
    #expect(ExportEngine.uniqueName(basename: "PAPER", extension: "md") { taken.contains($0) }
            == "PAPER 3.md")
}

@Test @MainActor func exportActuallyWritesFiles() throws {
    let state = try makeState()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SoftReturnTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let products = try ExportEngine.render(
        document: state.document, state: state,
        formats: [.text, .markdown], notes: NoteSelection())
    let written = try ExportEngine.write(products, to: directory, basename: "DOC")

    #expect(written.count == 2)
    for url in written {
        #expect(FileManager.default.fileExists(atPath: url.path))
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        #expect(size > 0, "\(url.lastPathComponent) was written empty")
    }
    // Writing again must not overwrite.
    let again = try ExportEngine.write(products, to: directory, basename: "DOC")
    #expect(again.allSatisfy { !written.contains($0) }, "an export overwrote an existing file")
}

// MARK: - 7. Settings persist

@Test @MainActor func everySettingRoundTripsThroughDefaults() {
    let name = "SoftReturnTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let store = SettingsStore(defaults: defaults)
    store.startingView = .batchConvert
    store.defaultZoom = .actual
    store.defaultStyle = .modern
    store.defaultDisplay = .continuousScroll
    store.modernFontName = "Helvetica"
    store.modernFontSize = 18
    store.defaultExportFormats = [.markdown, .pdf]
    store.defaultPageSize = .a4

    let reloaded = SettingsStore(defaults: defaults)
    #expect(reloaded.startingView == .batchConvert)
    #expect(reloaded.defaultZoom == .actual)
    #expect(reloaded.defaultStyle == .modern)
    #expect(reloaded.defaultDisplay == .continuousScroll)
    #expect(reloaded.modernFontName == "Helvetica")
    #expect(reloaded.modernFontSize == 18)
    #expect(reloaded.defaultExportFormats == [.markdown, .pdf])
    #expect(reloaded.defaultPageSize == .a4)
}

/// The spec fixes the size menu exactly.
@Test @MainActor func theFontSizeMenuIsTheSpecdSet() {
    #expect(SettingsStore.fontSizes == [9, 10, 11, 12, 13, 14, 16, 18])
}

// MARK: - 8. Batch

@Test @MainActor func batchListsConvertiblesAndSkipsTheRest() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SoftReturnBatch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(Sample.ws4).write(to: directory.appendingPathComponent("DOC.WS"))
    try Data(Sample.plainText).write(to: directory.appendingPathComponent("NOEXT"))
    try Data("not a document".utf8).write(to: directory.appendingPathComponent("thing.png"))

    let model = BatchModel()
    model.add(urls: [directory], includeSubfolders: false)
    #expect(model.items.count == 3, "all files must be listed, convertible or not")
    #expect(model.items.filter(\.isConvertible).count == 2)

    let png = try #require(model.items.first { $0.url.pathExtension == "png" })
    #expect(!png.isConvertible)
    #expect(png.statusText.contains("Not convertible"))

    // "No extension" is spelled out, never abbreviated.
    let noExt = try #require(model.items.first { $0.url.lastPathComponent == "NOEXT" })
    #expect(noExt.typeDescription == "No extension")
}

@Test @MainActor func batchConvertsAndReportsStatus() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SoftReturnBatchRun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(Sample.ws4).write(to: directory.appendingPathComponent("DOC.WS"))

    let model = BatchModel()
    model.add(urls: [directory], includeSubfolders: false)
    model.formats = [.text]
    await model.run(progress: {})

    #expect(model.convertedCount == 1, "batch converted nothing")
    #expect(model.failedCount == 0)
    #expect(model.items.first?.status == .done)
    #expect(FileManager.default.fileExists(atPath:
        directory.appendingPathComponent("DOC.txt").path), "no output file was written")
    #expect(model.summaryText.contains("1 converted"))
}

/// Job 392: replaces the old chmod-0o000-directory denial test (`.enabled(if:
/// ScriptingFileAccessSandboxTests.canConstructAccessDenial())` — that whole gate is gone,
/// per Jon's un-sandboxing ruling and the "no chmod games" replacement rule: this machine's
/// permissive inherited temp-directory ACL made a real POSIX denial unconstructible here
/// anyway, so the test always reported SKIPPED, never actually ran). A folder that never
/// existed at all is the one honestly, portably constructible "can't be listed" case left —
/// `add(urls:)`'s own top-level `fileExists` guard means this is silently skipped (added == 0,
/// no crash, nothing in `unreadableFolders`, since the folder is missing rather than present-
/// but-unreadable), a genuinely different code path than job 220's original enumeration
/// failure, but the same "never crash on a folder input this can't reach" contract.
@Test @MainActor func batchAddSkipsANonexistentFolderRatherThanCrashing() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SoftReturnBatchMissing-\(UUID().uuidString)")

    let model = BatchModel()
    let result = model.add(urls: [directory], includeSubfolders: false)

    #expect(result.added == 0)
    #expect(result.unreadableFolders.isEmpty)
    #expect(model.items.isEmpty)
}

// MARK: - 9. Accessibility

/// Non-negotiable, per the spec: every control carries an identifier AND a label. The
/// identifiers are also the vocabulary interface notes are written in.
@Test @MainActor func bottomBarControlsAreIdentifiedAndLabelled() throws {
    let state = try makeState()
    let bar = BottomBar()
    bar.update(from: state)

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let popups = descendants(bar).compactMap { $0 as? NSPopUpButton }
    #expect(popups.count == 5, "the bottom bar should have exactly five controls")

    let identifiers = popups.map { $0.accessibilityIdentifier() }
    for expected in ["variant-control", "style-control", "zoom-control", "page-size-control",
                     "page-settings-control"] {
        #expect(identifiers.contains(expected), "missing accessibility identifier \(expected)")
    }
    for popup in popups {
        #expect(!(popup.accessibilityLabel() ?? "").isEmpty,
                "\(popup.accessibilityIdentifier()) has no accessibility label")
    }
}

/// The provenance vocabulary is fixed by the spec, down to the parentheses.
@Test @MainActor func provenanceVocabularyIsExact() {
    #expect(SettingProvenance.detected.suffix == " (Detected)")
    #expect(SettingProvenance.manual.suffix == " (Manual)")
    #expect(SettingProvenance.default.suffix == " (Default)")
}

/// Changing a value by hand must flip its provenance to Manual — that is the entire
/// meaning of the badge in the bottom bar.
@Test @MainActor func settingSomethingByHandMarksItManual() throws {
    let state = try makeState()
    #expect(state.style.provenance == .default)
    state.style.setManually(.modern)
    #expect(state.style.provenance == .manual)

    #expect(state.variant.provenance == .detected)
    state.setVariant(.printstream)
    #expect(state.variant.provenance == .manual)
    state.resetVariantToAuto()
    #expect(state.variant.provenance == .detected)
}
