import AppKit
import CtrlKD
import UniformTypeIdentifiers

/// The View and File menu commands, and the Export As sheet.
///
/// Menu items validate through `validateMenuItem`, which is also where the checkmarks come
/// from — the spec asks for a checkmark on the current style and display, and AppKit's own
/// validation is the mechanism for that rather than a second source of truth updated by
/// hand.
extension DocumentWindowController: NSMenuItemValidation {

    // MARK: - View ▸ style

    @IBAction func showNativeStyle(_ sender: Any?) { setStyle(.native) }
    @IBAction func showPrintedStyle(_ sender: Any?) { setStyle(.printed) }
    @IBAction func showModernStyle(_ sender: Any?) { setStyle(.modern) }

    /// Job 257 (Show Invisibles part 3/4): reflow can change the page count out from under
    /// the reader, so this captures the REAL page (`PagedDocumentView.realPageIndex(at:)`)
    /// the current local page shows BEFORE re-rendering, then asks for whichever local page
    /// shows that real page's content again AFTER — same real page either way, since
    /// toggling never changes what `docToPagelines` itself decided, only how many local
    /// pages Show Invisibles spreads it across. Best-effort: this keeps the right PAGE in
    /// view, not the exact line — see the job's own report for why a line-exact anchor
    /// would need a document-position concept this view doesn't have.
    ///
    /// Job 265: unreachable while Printed (the new PDFKit mode) is active — the menu item is
    /// disabled by `validateMenuItem` below, and Printed has no bottom-bar affordance for it
    /// either (Show Invisibles has never had one — View menu only) — but guarded anyway
    /// rather than trusting menu validation alone, since `toggleInvisibles` could in
    /// principle be reached some other way (e.g. a future keyboard shortcut).
    @IBAction func toggleInvisibles(_ sender: Any?) {
        guard documentState.style.value != .printed else { return }
        let anchorRealPage = pagedView.realPageIndex(at: currentPage)
        documentState.showInvisibles.toggle()
        rerender()
        goToPage(index: pagedView.pageIndex(forRealPage: anchorRealPage))
    }

    // MARK: - View ▸ Show Document Info

    /// ⌘I. Toggles the per-window Inspector panel (job 314) — Show/Hide, macOS convention;
    /// the menu item's own title flips in `validateMenuItem` below, reading the panel's
    /// `isVisible` the same way everything else in this file reads `documentState` rather
    /// than keeping a second flag.
    @IBAction func toggleDocumentInfo(_ sender: Any?) {
        let controller = documentInfoWindowControllerCreatingIfNeeded()
        if controller.window?.isVisible == true {
            controller.close()
        } else {
            controller.refresh(from: self)
            controller.showWindow(sender)
        }
    }

    // MARK: - View ▸ Page Size / Margins (submenus, job 314)

    /// One selector per named size, the same pattern `showPrintedStyle`/`changeVariantToWS4`
    /// use — all three route through `setPageSize`, the SAME method the bottom bar's popup
    /// calls, so a menu choice and a popup choice of the same size do exactly the same thing.
    @IBAction func choosePageSizeUSLetter(_ sender: Any?) { setPageSize(.usLetter) }
    @IBAction func choosePageSizeUSLegal(_ sender: Any?) { setPageSize(.usLegal) }
    @IBAction func choosePageSizeA4(_ sender: Any?) { setPageSize(.a4) }

    /// One selector per margins choice — `nil` ("Embedded", job 315: was "From Document")
    /// plus the three named presets — all routing through `setPageSettingsPreset`, the SAME
    /// method the bottom bar's Margins popup calls.
    @IBAction func chooseMarginsFromDocument(_ sender: Any?) { setPageSettingsPreset(nil) }
    @IBAction func chooseMarginsFactory(_ sender: Any?) { setPageSettingsPreset(.default) }
    @IBAction func chooseMarginsSawyer(_ sender: Any?) { setPageSettingsPreset(.sawyer) }
    @IBAction func chooseMarginsModernDefaults(_ sender: Any?) { setPageSettingsPreset(.modern) }

    // MARK: - Edit ▸ Change Variant

    /// One selector per format, the same pattern `showPrintedStyle`/`showModernStyle` use —
    /// all four route through `setVariant`, the SAME method the bottom bar's popup calls, so
    /// a menu choice and a popup choice of the same format do exactly the same thing.
    @IBAction func changeVariantToWS4(_ sender: Any?) { setVariant(.ws4) }
    @IBAction func changeVariantToWS5Plus(_ sender: Any?) { setVariant(.ws5plus) }
    @IBAction func changeVariantToPrintstream(_ sender: Any?) { setVariant(.printstream) }
    @IBAction func changeVariantToText(_ sender: Any?) { setVariant(.text) }

    // MARK: - View ▸ display

    @IBAction func showContinuousScroll(_ sender: Any?) { setDisplay(.continuousScroll) }
    @IBAction func showSinglePage(_ sender: Any?) { setDisplay(.singlePage) }

    // MARK: - Go ▸ pages

    @IBAction func goUp(_ sender: Any?) { goToPage(index: currentPage - 1) }
    @IBAction func goDown(_ sender: Any?) { goToPage(index: currentPage + 1) }
    @IBAction func goFirstPage(_ sender: Any?) { goToPage(index: 0) }
    @IBAction func goLastPage(_ sender: Any?) { goToPage(index: pageTotal - 1) }

    /// Ask for a page by number. One field, one sheet, no ceremony — the page numbers a
    /// reader cares about are 1-based, so the sheet speaks 1-based and this converts.
    @IBAction func goToPage(_ sender: Any?) {
        guard let window, pageTotal > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Page number, 1 to \(pageTotal)."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        field.alignment = .right
        field.stringValue = "\(currentPage + 1)"
        field.setAccessibilityIdentifier("go-to-page-field")
        alert.accessoryView = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // A page number out of range is a typo, not a command. Clamp rather than refuse:
            // nobody wants an error sheet because they typed 99 in a 12-page document.
            if let wanted = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) {
                self.goToPage(index: wanted - 1)
            }
        }
    }

    /// Which page the user is on, in either display mode. Printed (job 265) reads `pdfView`'s
    /// own current page instead of `pagedView`'s — exactly one of the two ever has content.
    var currentPage: Int {
        guard documentState.style.value == .printed else { return pagedView.visiblePageIndex }
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }
    /// How many pages the document laid out.
    var pageTotal: Int {
        documentState.style.value == .printed ? (pdfView.document?.pageCount ?? 0) : pagedView.pageCount
    }

    /// Move to `index`, in whichever way the current display mode means it.
    ///
    /// Single Page swaps which page is shown — the page always fills the window, so there is
    /// nothing to scroll. Continuous Scroll really scrolls, so it scrolls TO the page instead
    /// of swapping anything. Same command, two honest meanings. Printed (job 265) delegates
    /// straight to `PDFView.go(to:)`, which already knows how to honor its own display mode.
    ///
    /// Internal, not private: the AppleScript `current page` property
    /// (`WSDocument+Scripting.swift`) drives the same navigation the Go menu does, so it
    /// needs this from outside the file.
    func goToPage(index: Int) {
        let clamped = max(0, min(index, pageTotal - 1))
        if documentState.style.value == .printed {
            guard let document = pdfView.document, let page = document.page(at: clamped) else { return }
            pdfView.go(to: page)
            // Job 454 (PART B): `pdfView`'s own `.PDFViewPageChanged` notification (observed in
            // `DocumentWindowController.buildContent()`) already covers navigation PDFKit drives
            // itself (arrow keys, trackpad swipe, scrolling) — called again here too so this
            // command path never depends on notification delivery timing.
            refreshPageIndicator()
            return
        }
        guard clamped != currentPage || documentState.display.value == .continuousScroll else { return }
        switch documentState.display.value {
        case .singlePage:
            pagedView.showPage(clamped)
        case .continuousScroll:
            let rect = pagedView.rect(ofPage: clamped)
            pagedView.scrollToVisible(CGRect(x: rect.origin.x, y: rect.origin.y,
                                             width: rect.width,
                                             height: pagedView.visibleRect.height))
        }
        // Job 450 (b6): the Go menu/AppleScript path changes the current page without
        // touching anything else `bottomBar.update(from:)` shows, so it needs its own call —
        // the scroll-gesture path (`pagedView.pageDidChange`) already has one.
        refreshPageIndicator()
    }

    // MARK: - View ▸ zoom

    @IBAction func zoomActual(_ sender: Any?) { setZoom(.actual) }
    @IBAction func zoomToFit(_ sender: Any?) { setZoom(.fit) }

    @IBAction func zoomIn(_ sender: Any?) { stepZoom(by: +1) }
    @IBAction func zoomOut(_ sender: Any?) { stepZoom(by: -1) }

    /// Walk the spec's 50–200% ladder. From Fit or Actual, start at the rung nearest what
    /// is currently on screen so the first press is a small change rather than a jump.
    private func stepZoom(by direction: Int) {
        let steps = ZoomSetting.steps
        let currentPercent: Int
        switch documentState.zoom.value {
        case .percent(let pct):
            currentPercent = pct
        case .actual:
            currentPercent = 100
        case .fit:
            // 100% now means `currentActualScale`, not a flat 1.0 (Actual Size = 100% = the
            // physical page, per `ZoomSetting.scale`) — so Fit's raw on-screen magnification
            // has to be measured against that SAME baseline to land on the right rung.
            currentPercent = Int((currentMagnification / currentActualScale * 100).rounded())
        }
        let nearest = steps.min { abs($0 - currentPercent) < abs($1 - currentPercent) } ?? 100
        var index = steps.firstIndex(of: nearest) ?? steps.firstIndex(of: 100) ?? 0
        // From Fit, the nearest rung may already be a change in the right direction; only
        // step past it when it is not.
        if case .percent = documentState.zoom.value {
            index += direction
        } else if (direction > 0 && nearest <= currentPercent) || (direction < 0 && nearest >= currentPercent) {
            index += direction
        }
        guard steps.indices.contains(index) else { return }
        setZoom(.percent(steps[index]))
    }

    // MARK: - File ▸ Export As…

    /// The STANDARD `NSSavePanel` with a checkbox accessory — not a panel we drew. A
    /// centered Style pulldown (job 323, b20 item 3 — Jon's ruling) sits above a pair of
    /// balanced columns, Formats (pre-checked from Settings) and Notes. Style defaults to
    /// the window's current view — "export what you see" stays the default, now overridable
    /// per export.
    ///
    /// Job 244 Leg 1: exactly one format checked pins `panel.allowedContentTypes` to that
    /// format, kept live via `onFormatsChanged` as checkboxes flip. That makes the OS itself
    /// grant back a `panel.url` that already carries the right extension, so
    /// `performSingleExport`/`writeSingle` can keep writing EXACTLY the granted URL (the
    /// sandbox contract `docs/reference/apple/sandbox-file-writes-packet.md` requires) while
    /// still guaranteeing "OLDTIMES" + RTF checked writes "OLDTIMES.rtf", never extensionless.
    ///
    /// ⚠️ PROVISIONAL, per the spec: multi-format-per-save has to survive real use. If
    /// picking three formats at once feels wrong in hand, this reverts to a single Format
    /// popup (Preview's pattern). Built multi first, as instructed — flagged for the first
    /// functional review.
    ///
    /// Presented with `begin(completionHandler:)`, not `beginSheetModal(for:)`: a sheet is
    /// pinned under the parent window's title bar by design and cannot be dragged by its
    /// top, which read as a bug (Jon's ruling, UI round 4b). `begin` gives it a normal
    /// title bar of its own, movable like any other window.
    @IBAction func exportAs(_ sender: Any?) {
        guard window != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export As"
        panel.prompt = "Export"
        panel.nameFieldStringValue = exportBasename
        panel.canCreateDirectories = true
        panel.setAccessibilityIdentifier("export-panel")

        let accessory = ExportAccessoryView(
            formats: SettingsStore.shared.defaultExportFormats,
            notes: NoteSelection(),
            style: documentState.style.value
        )
        panel.accessoryView = accessory
        panel.allowedContentTypes = ExportEngine.singleFormatContentTypes(for: accessory.selectedFormats)
        accessory.onFormatsChanged = { [weak panel, weak accessory] in
            guard let panel, let accessory else { return }
            panel.allowedContentTypes = ExportEngine.singleFormatContentTypes(for: accessory.selectedFormats)
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let chosen = accessory.selectedFormats
            guard !chosen.isEmpty else {
                self.presentNoFormatsChosen()
                return
            }
            // The pulldown's OWN chosen value (job 323) — not `documentState.style.value` —
            // reaches `ExportEngine.render` as both `style` (mapped down via `renderStyle`
            // for the four formats that only know printed/modern) and `viewStyle` (PDF's
            // native-view print-path carve-out). An explicit Printed pick on a Native window
            // must honestly export the engine's own bytes, not silently re-derive Native's
            // print-path render from the window's ambient style.
            let viewStyle = accessory.selectedStyle
            let style = viewStyle.renderStyle
            // One save panel grants exactly ONE url (packet: "What a user-selected grant
            // covers"). One chosen format writes straight to it; more than one format needs
            // a folder GRANT, which a save panel cannot provide — see
            // `performMultiFormatExport`.
            if chosen.count == 1 {
                self.performSingleExport(
                    format: chosen[0], notes: accessory.noteSelection, style: style,
                    viewStyle: viewStyle, headers: accessory.selectedHeaders,
                    toc: accessory.selectedTOC, inlineStyling: accessory.selectedInlineStyling,
                    pictures: accessory.selectedPictures, pageNumbers: accessory.selectedPageNumbers,
                    sentenceSpacing: accessory.selectedSentenceSpacing, to: url)
            } else {
                self.performMultiFormatExport(
                    formats: chosen, notes: accessory.noteSelection, style: style,
                    viewStyle: viewStyle, headers: accessory.selectedHeaders,
                    toc: accessory.selectedTOC, inlineStyling: accessory.selectedInlineStyling,
                    pictures: accessory.selectedPictures, pageNumbers: accessory.selectedPageNumbers,
                    sentenceSpacing: accessory.selectedSentenceSpacing,
                    basename: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    /// Exactly one format: `url` IS the grant — already carrying the right extension, since
    /// `exportAs` pins `panel.allowedContentTypes` before the panel ever returns it. Write
    /// it, and only it — no directory reconstruction.
    private func performSingleExport(format: ExportFormat, notes: NoteSelection,
                                     style: RenderStyle, viewStyle: ViewStyle, headers: Bool,
                                     toc: Bool, inlineStyling: Bool, pictures: EmitOptions.PixMode,
                                     pageNumbers: EmitOptions.PageNumberMode,
                                     sentenceSpacing: EmitOptions.SentenceSpacingMode, to url: URL) {
        do {
            let products = try ExportEngine.render(
                document: documentState.document, state: documentState,
                formats: [format], notes: notes, style: style, viewStyle: viewStyle,
                title: url.deletingPathExtension().lastPathComponent,
                docPath: document?.fileURL?.path ?? "",
                headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
                pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)
            guard let product = products.first else { return }
            try ExportEngine.writeSingle(product, to: url)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// More than one format from one action: no save panel grants sibling files (packet:
    /// "There is NO grant for files written BESIDE a granted file"), so this asks for a
    /// FOLDER instead — `NSOpenPanel(canChooseDirectories: true)`, whose grant recursively
    /// covers everything written inside it.
    private func performMultiFormatExport(formats: [ExportFormat], notes: NoteSelection,
                                          style: RenderStyle, viewStyle: ViewStyle, headers: Bool,
                                          toc: Bool, inlineStyling: Bool, pictures: EmitOptions.PixMode,
                                          pageNumbers: EmitOptions.PageNumberMode,
                                          sentenceSpacing: EmitOptions.SentenceSpacingMode, basename: String) {
        guard let window else { return }
        let folderPanel = NSOpenPanel()
        folderPanel.title = "Choose a Folder"
        folderPanel.message = "Choose a folder for the \(formats.count) exported files."
        folderPanel.prompt = "Export"
        folderPanel.canChooseFiles = false
        folderPanel.canChooseDirectories = true
        folderPanel.canCreateDirectories = true
        folderPanel.setAccessibilityIdentifier("export-multi-format-folder-panel")
        folderPanel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let directory = folderPanel.url else { return }
            do {
                let products = try ExportEngine.render(
                    document: self.documentState.document, state: self.documentState,
                    formats: formats, notes: notes, style: style, viewStyle: viewStyle,
                    title: basename, docPath: self.document?.fileURL?.path ?? "",
                    headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
                    pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)
                try ExportEngine.write(products, to: directory, basename: basename)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    private func presentNoFormatsChosen() {
        let alert = NSAlert()
        alert.messageText = "Choose at least one format."
        alert.informativeText = "Nothing was exported because no format was selected."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showNativeStyle(_:)):
            menuItem.state = documentState.style.value == .native ? .on : .off
        case #selector(showPrintedStyle(_:)):
            menuItem.state = documentState.style.value == .printed ? .on : .off
        case #selector(showModernStyle(_:)):
            menuItem.state = documentState.style.value == .modern ? .on : .off
        case #selector(showContinuousScroll(_:)):
            menuItem.state = documentState.display.value == .continuousScroll ? .on : .off
        case #selector(showSinglePage(_:)):
            menuItem.state = documentState.display.value == .singlePage ? .on : .off
        case #selector(toggleInvisibles(_:)):
            menuItem.state = documentState.showInvisibles ? .on : .off
            // Job 265: a baked PDF (Printed) cannot reflow, so Show Invisibles has no meaning
            // there — greyed out rather than left clickable-but-inert, so the menu itself
            // tells the person why nothing happens, instead of them guessing. Returned
            // directly (like the page-navigation cases below) because the switch's shared
            // `return true` at the bottom is what every OTHER case relies on to stay enabled.
            let isPrinted = documentState.style.value == .printed
            menuItem.toolTip = isPrinted
                ? "Show Invisibles is not available in Printed view."
                : nil
            return !isPrinted
        case #selector(zoomToFit(_:)):
            menuItem.state = documentState.zoom.value == .fit ? .on : .off
        case #selector(zoomActual(_:)):
            menuItem.state = documentState.zoom.value == .actual ? .on : .off
        case #selector(toggleDocumentInfo(_:)):
            let isVisible = documentInfoWindowController?.window?.isVisible == true
            menuItem.title = isVisible ? "Hide Document Info" : "Show Document Info"
        case #selector(choosePageSizeUSLetter(_:)):
            menuItem.state = documentState.pageSize.value == .usLetter ? .on : .off
        case #selector(choosePageSizeUSLegal(_:)):
            menuItem.state = documentState.pageSize.value == .usLegal ? .on : .off
        case #selector(choosePageSizeA4(_:)):
            menuItem.state = documentState.pageSize.value == .a4 ? .on : .off
        case #selector(chooseMarginsFromDocument(_:)):
            menuItem.state = documentState.pageSettingsPreset.value == nil ? .on : .off
        case #selector(chooseMarginsFactory(_:)):
            menuItem.state = documentState.pageSettingsPreset.value == .default ? .on : .off
        case #selector(chooseMarginsSawyer(_:)):
            menuItem.state = documentState.pageSettingsPreset.value == .sawyer ? .on : .off
        case #selector(chooseMarginsModernDefaults(_:)):
            menuItem.state = documentState.pageSettingsPreset.value == .modern ? .on : .off
        case #selector(changeVariantToWS4(_:)):
            menuItem.state = documentState.variant.value == .ws4 ? .on : .off
        case #selector(changeVariantToWS5Plus(_:)):
            menuItem.state = documentState.variant.value == .ws5plus ? .on : .off
        case #selector(changeVariantToPrintstream(_:)):
            menuItem.state = documentState.variant.value == .printstream ? .on : .off
        case #selector(changeVariantToText(_:)):
            menuItem.state = documentState.variant.value == .text ? .on : .off

        // Page navigation disables at the ends rather than wrapping — the spec is explicit,
        // and it matches Preview. A document with one page disables all four.
        case #selector(goUp(_:)), #selector(goFirstPage(_:)):
            return currentPage > 0
        case #selector(goDown(_:)), #selector(goLastPage(_:)):
            return currentPage < pageTotal - 1
        case #selector(goToPage(_:) as (Any?) -> Void):
            return pageTotal > 1

        default:
            break
        }
        return true
    }
}
