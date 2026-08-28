import AppKit
import CtrlKD

/// The Settings window: the classic Mac form idiom, fixed width.
///
/// Right-aligned "Label:" column, every control starting at one shared left edge, and ALL
/// popups the same width regardless of their content — the spec is specific about this,
/// and it is the difference between a form that reads as one object and a row of
/// independently-sized widgets. `NSGridView` is the tool that expresses it directly.
///
/// The eight settings the spec originally fixed, plus the ninth the window-restoration
/// ruling added, plus the tenth job 315 (b19 item 11) added: Quick Look Margins, plus job
/// 373's four (b24 FLAG UI) — Headers/Footers, Table of Contents, Inline Styling, and
/// Pictures — the Export As sheet's own Options column defaults. Unlike
/// the other nine, it does NOT live in `SettingsStore`/`UserDefaults.standard` — it reads
/// and writes `QuickLookPageSettingsPreference`'s own app-group container directly, the
/// SAME channel the bottom bar's now-removed "Use as Default for Quick Look" action item
/// used to write (job 203). That preference is shared with two extension processes
/// (`SoftReturnQuickLook`, `SoftReturnThumbnail`) that have no window of their own to host
/// a per-document choice, so it was never a per-document setting to begin with — this row
/// just gives it the one home a "closed list of preferences" app expects every setting to
/// have, instead of leaving it as a hidden footer action nobody could find twice.
///
/// Job 397 (Jon F10, verbatim ruling): row order fixed to a spec'd sequence, split by a
/// separator into a document-open-defaults group and a Modern-font/export group — see
/// `buildForm`.
///
/// Job 398 (Jon's correction to F10): Default Display belongs in that top group, directly
/// below Default Style and above Default Page Size — its omission from job 397's list was a
/// mistake, not a ruling. Restored verbatim (`displayPopup`/`displayChanged(_:)`);
/// `SettingsStore.defaultDisplay` was never touched by its removal either way.
///
/// Job 520 (N5, b33 page-numbering UI): a fifth row joins the b24 flag group — Page
/// Numbering (`pageNumbersPopup`/`pageNumbersChanged(_:)`), the same Auto/On/Off vocabulary
/// the export sheet and Batch window's own new pulldowns offer, following `picturesPopup`'s
/// own three-case-pulldown pattern exactly.
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    /// `nil` (production) means "let `QuickLookPageSettingsPreference` resolve its own
    /// container" — its `defaults:` parameter default already does that. A test injects an
    /// isolated suite here instead, the same discipline `PageSettingsPickerTests` already
    /// holds every other `QuickLookPageSettingsPreference` caller to: never the real
    /// `RC448RH3EN.softreturn` app-group container in a test process.
    private let quickLookDefaultsOverride: UserDefaults?

    /// One width for every popup in the form. Also the width the Batch Export window's
    /// pulldowns match, per ruling — one form idiom, one popup width, across both windows.
    static let popupWidth: CGFloat = 190
    private static let contentWidth: CGFloat = 420

    private var startingViewPopup: NSPopUpButton!
    private var zoomPopup: NSPopUpButton!
    private var stylePopup: NSPopUpButton!
    private var displayPopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var pageSizePopup: NSPopUpButton!
    private var quickLookMarginsPopup: NSPopUpButton!
    private var formatChecks: [ExportFormat: NSButton] = [:]
    private var restoreWindowsCheckbox: NSButton!
    private var headersCheckbox: NSButton!
    private var tocCheckbox: NSButton!
    private var inlineStylingCheckbox: NSButton!
    private var picturesPopup: NSPopUpButton!
    private var pageNumbersPopup: NSPopUpButton!
    /// Stored (not a `buildForm`-local `let`, unlike `topGrid`) because job 537's beta row
    /// needs to anchor to its bottom from outside `buildForm` — see `addBetaVersionsRow(to:)`.
    private var bottomGrid: NSGridView!

    /// Job 537 (rulings 20-21): the Option-revealed "Include beta versions" checkbox and its
    /// row, present in `window?.contentView` only while shown — see
    /// `updateBetaVersionsCheckboxVisibility()`. `nil` in both cases means "not currently
    /// built", not "hidden but present" — the row is added/removed from the hierarchy rather
    /// than toggling `isHidden`, so a hidden row costs the window zero height (plain
    /// `NSView.isHidden` does not collapse manually-constrained space the way an `NSStackView`
    /// arrangement would; add/remove sidesteps that entirely).
    private var betaVersionsRow: NSView?
    private var betaVersionsCheckbox: NSButton?
    /// Ties `bottomGrid`'s bottom to `content`'s bottom. Active whenever `betaVersionsRow` is
    /// absent (bottomGrid is the last thing in the form); deactivated in favor of a constraint
    /// from the beta row's bottom when it's present. Never both at once — that would
    /// over-constrain `content`'s height.
    private var bottomGridBottomConstraint: NSLayoutConstraint!

    /// `nil` (production) reads the real, current `⌥` state via `NSEvent.modifierFlags` at
    /// each `showWindow(_:)` call. A test injects a fixed value instead — the same seam
    /// `quickLookDefaultsOverride` already uses for the app-group container, because real
    /// modifier-key state isn't something a headless test process can drive.
    private let optionKeyHeldOverride: Bool?

    init(settings: SettingsStore = .shared, quickLookDefaultsOverride: UserDefaults? = nil,
         optionKeyHeldOverride: Bool? = nil) {
        self.settings = settings
        self.quickLookDefaultsOverride = quickLookDefaultsOverride
        self.optionKeyHeldOverride = optionKeyHeldOverride
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.contentWidth, height: 460),
            // Fixed width: no .resizable. A form with one right-aligned label column has
            // nothing to do with extra width, and letting it stretch only breaks the idiom.
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.setAccessibilityIdentifier("settings-window")
        super.init(window: window)
        buildForm()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Form

    private func buildForm() {
        guard let window else { return }

        restoreWindowsCheckbox = NSButton(checkboxWithTitle: "Restore windows on launch",
                                          target: self, action: #selector(restoreWindowsToggled(_:)))
        restoreWindowsCheckbox.setAccessibilityIdentifier("restore-windows-on-launch-checkbox")
        restoreWindowsCheckbox.setAccessibilityLabel("Restore windows on launch")

        startingViewPopup = popup(StartingView.allCases.map(\.displayName), "starting-view-control",
                                  "Starting view", #selector(startingViewChanged(_:)))
        zoomPopup = popup(["Fit", "Actual"], "default-zoom-control",
                          "Default zoom", #selector(zoomChanged(_:)))
        stylePopup = popup(ViewStyle.allCases.map(\.displayName), "default-style-control",
                           "Default style", #selector(styleChanged(_:)))
        displayPopup = popup(PageDisplay.allCases.map(\.displayName), "default-display-control",
                             "Default display", #selector(displayChanged(_:)))
        pageSizePopup = popup(NamedPageSize.allCases.map(\.displayName), "default-page-size-control",
                              "Default page size", #selector(pageSizeChanged(_:)))
        quickLookMarginsPopup = popup(DocumentOperations.PageSettingsPreset.marginsChoiceNames,
                                      "quick-look-margins-control", "Quick Look margins",
                                      #selector(quickLookMarginsChanged(_:)))

        fontPopup = fontPopupControl()
        sizePopup = popup(SettingsStore.fontSizes.map(String.init), "font-size-control",
                          "Modern font size", #selector(sizeChanged(_:)))

        headersCheckbox = NSButton(checkboxWithTitle: "Headers/Footers",
                                   target: self, action: #selector(headersToggled(_:)))
        headersCheckbox.setAccessibilityIdentifier("default-headers-checkbox")
        headersCheckbox.setAccessibilityLabel("Default: include headers and footers")

        tocCheckbox = NSButton(checkboxWithTitle: "Table of Contents",
                               target: self, action: #selector(tocToggled(_:)))
        tocCheckbox.setAccessibilityIdentifier("default-toc-checkbox")
        tocCheckbox.setAccessibilityLabel("Default: include table of contents and index")

        inlineStylingCheckbox = NSButton(checkboxWithTitle: "Inline Styling",
                                         target: self, action: #selector(inlineStylingToggled(_:)))
        inlineStylingCheckbox.setAccessibilityIdentifier("default-inline-styling-checkbox")
        inlineStylingCheckbox.setAccessibilityLabel("Default: include the author's inline color and size styling")

        picturesPopup = popup(["Off", "Embed", "Export"], "default-pictures-control",
                              "Default pictures", #selector(picturesChanged(_:)))
        pageNumbersPopup = popup(["Auto", "On", "Off"], "default-page-numbers-control",
                                 "Default page numbering", #selector(pageNumbersChanged(_:)))

        // Job 397 (Jon F10, verbatim ruling): two grids around a separator + caption, not
        // one — the ruling's order groups the document-open defaults first, then the Modern
        // font/export cluster second, with the caption sitting exactly where the spec puts
        // it (right after the separator, before Font). `style(_:)` applies the same column
        // placement to both, so the two sections still read as one continuous form.
        let topGrid = NSGridView(views: [
            [label("On Launch:"), restoreWindowsCheckbox],
            [label("Starting View:"), startingViewPopup],
            [label("Default Zoom:"), zoomPopup],
            [label("Default Style:"), stylePopup],
            [label("Default Display:"), displayPopup],
            [label("Default Page Size:"), pageSizePopup],
            [label("Quick Look Margins:"), quickLookMarginsPopup],
        ])
        style(topGrid)

        let separatorBox = NSBox()
        separatorBox.boxType = .separator
        separatorBox.translatesAutoresizingMaskIntoConstraints = false

        // Font and Size are Modern-style settings. They stay ACTIVE regardless of the
        // current style — the spec is explicit that these are preferences, not live state
        // (unlike the batch window, where the same two controls do grey out).
        let caption = NSTextField(wrappingLabelWithString:
            "Font and size apply to Modern style — and to its RTF and PDF exports.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.setAccessibilityIdentifier("settings-font-caption")
        caption.translatesAutoresizingMaskIntoConstraints = false

        bottomGrid = NSGridView(views: [
            [label("Font:"), fontPopup],
            [label("Size:"), sizePopup],
            [label("Default Export Formats:"), formatStack()],
            [label("Export Inline Styling:"), inlineStylingCheckbox],
            [label("Export Headers:"), headersCheckbox],
            [label("Export TOC:"), tocCheckbox],
            [label("Export Pictures:"), picturesPopup],
            [label("Page Numbering:"), pageNumbersPopup],
        ])
        style(bottomGrid)
        // Single-control rows centre against their label — a popup whose label sits at its
        // top reads as misaligned. Only the multi-row checkbox stack wants a top-aligned
        // label, so it is the exception rather than the rule `style(_:)` applies to everything.
        if let formatsRow = gridRowIndex(of: "Default Export Formats:", in: bottomGrid) {
            bottomGrid.row(at: formatsRow).yPlacement = .top
        }

        let content = NSView()
        content.addSubview(topGrid)
        content.addSubview(separatorBox)
        content.addSubview(caption)
        content.addSubview(bottomGrid)
        bottomGridBottomConstraint = bottomGrid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        NSLayoutConstraint.activate([
            topGrid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            topGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            topGrid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            separatorBox.topAnchor.constraint(equalTo: topGrid.bottomAnchor, constant: 16),
            separatorBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            separatorBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            caption.topAnchor.constraint(equalTo: separatorBox.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            bottomGrid.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
            bottomGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottomGrid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            bottomGridBottomConstraint,
        ])
        window.contentView = content
        loadCurrentValues()
        // Job 537: decides whether the beta-versions row is part of the form at all, before
        // the very first sizing pass below — see `updateBetaVersionsCheckboxVisibility()`.
        updateBetaVersionsCheckboxVisibility()

        // Job 397 (Jon F9): fixes the bottom-left-corner spawn — an unpositioned
        // `NSWindow(contentRect:)` takes (0, 0) as a literal screen-space origin, not "let
        // AppKit decide". Unlike the transient windows (About, CLI Help, …), this is a form a
        // user reopens repeatedly while working — frame autosave remembers where they left
        // it, with `center()` (the same upper-third placement as the Check for Updates
        // `NSAlert`) as the fallback the very first time, before anything has been saved.
        window.setFrameAutosaveName("SettingsWindow")
        if !window.setFrameUsingName("SettingsWindow") {
            window.center()
        }
    }

    /// Which grid row holds the given label, so alignment can be set by meaning rather than
    /// by a magic index that silently points at the wrong row when the form is reordered.
    private func gridRowIndex(of labelText: String, in grid: NSGridView) -> Int? {
        (0..<grid.numberOfRows).first { row in
            (grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?
                .stringValue == labelText
        }
    }

    /// The classic form idiom, shared by both of `buildForm`'s grids: labels right-aligned
    /// into a shared gutter, every control starting at one left edge, single-control rows
    /// centred against their label. Applied identically to both so the separator between
    /// them reads as a divider within one form, not two differently-styled ones.
    private func style(_ grid: NSGridView) {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
    }

    private func label(_ text: String) -> NSTextField {
        FormControl.rightAlignedLabel(text)
    }

    private func popup(_ titles: [String], _ identifier: String,
                       _ accessibilityLabel: String, _ action: Selector) -> NSPopUpButton {
        // One width for every popup in the form — see the class comment.
        FormControl.popUpButton(titles: titles, identifier: identifier,
                                 accessibilityLabel: accessibilityLabel, width: Self.popupWidth,
                                 target: self, action: action)
    }

    private func fontPopupControl() -> NSPopUpButton {
        // Text faces only: a monospaced-only or symbol font in a Modern reading view is a
        // trap, and the whole point of Modern is legibility.
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        let button = popup(families, "font-control", "Modern font", #selector(fontChanged(_:)))
        return button
    }

    private func formatStack() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for format in ExportFormat.allCases {
            let check = NSButton(checkboxWithTitle: format.displayName,
                                 target: self, action: #selector(formatToggled(_:)))
            check.setAccessibilityIdentifier("export-format-\(format.rawValue)-checkbox")
            check.setAccessibilityLabel("Default export format: \(format.displayName)")
            check.tag = ExportFormat.allCases.firstIndex(of: format) ?? 0
            formatChecks[format] = check
            stack.addArrangedSubview(check)
        }
        return stack
    }

    // MARK: - Beta versions (job 537, rulings 20-21)

    /// Re-checked every time the window is (re)shown, not just once at construction:
    /// `AppDelegate` keeps one `SettingsWindowController` alive and reuses it across opens
    /// (`showWindow(_:)` on the same instance), so a construction-time-only check would never
    /// see a later open held with `⌥` down. This IS one of the two AppKit-supported shapes the
    /// job brief names ("shown on open-with-Option") rather than a live `flagsChanged` monitor
    /// — chosen over the live alternative because it needs no event-monitor lifecycle
    /// (install on key, remove on resign-key/close) and no live window-resize-while-held
    /// animation, and it is trivially testable via `optionKeyHeldOverride` (real `⌥` state
    /// cannot be driven from a headless test process either way).
    override func showWindow(_ sender: Any?) {
        updateBetaVersionsCheckboxVisibility()
        super.showWindow(sender)
    }

    private func currentOptionHeld() -> Bool {
        optionKeyHeldOverride ?? NSEvent.modifierFlags.contains(.option)
    }

    /// Pure so it's testable without a real window: `⌥`-revealed while off, but if the
    /// preference is already ON the checkbox stays visible unconditionally — a beta opter-in
    /// should be able to find their way back off without knowing the trick that got them in.
    static func shouldShowBetaVersionsCheckbox(preferenceOn: Bool, optionHeld: Bool) -> Bool {
        preferenceOn || optionHeld
    }

    /// Adds or removes the beta-versions row from `content` to match
    /// `shouldShowBetaVersionsCheckbox`, then re-fits the window to whatever the form now
    /// contains. Add/remove rather than `isHidden`: a plain `NSView`'s manually-added
    /// constraints stay active even while it's hidden (unlike an `NSStackView`'s arranged
    /// subviews, which collapse automatically), so toggling `isHidden` alone would leave a
    /// permanent gap at the bottom of the window whether the row was showing or not.
    private func updateBetaVersionsCheckboxVisibility() {
        guard let window, let content = window.contentView else { return }
        let shouldShow = Self.shouldShowBetaVersionsCheckbox(
            preferenceOn: settings.includeBetaVersions, optionHeld: currentOptionHeld())

        switch (shouldShow, betaVersionsRow) {
        case (true, .none):
            addBetaVersionsRow(to: content)
        case (false, .some(let row)):
            removeBetaVersionsRow(row)
        case (true, .some):
            // Already built (a reopen with the same visibility outcome) — still resync the
            // checked state in case something wrote to `settings` while the row existed.
            betaVersionsCheckbox?.state = settings.includeBetaVersions ? .on : .off
        case (false, .none):
            break
        }
        resizeWindowToFitContent()
    }

    private func addBetaVersionsRow(to content: NSView) {
        let checkbox = NSButton(checkboxWithTitle: "Include beta versions",
                                target: self, action: #selector(includeBetaVersionsToggled(_:)))
        checkbox.setAccessibilityIdentifier("include-beta-versions-checkbox")
        checkbox.setAccessibilityLabel("Include beta versions when checking for updates")
        checkbox.state = settings.includeBetaVersions ? .on : .off
        betaVersionsCheckbox = checkbox

        let row = NSStackView(views: [label("Updates:"), checkbox])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        betaVersionsRow = row

        bottomGridBottomConstraint.isActive = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bottomGrid.bottomAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: 20),
        ])
    }

    private func removeBetaVersionsRow(_ row: NSView) {
        row.removeFromSuperview()
        betaVersionsRow = nil
        betaVersionsCheckbox = nil
        bottomGridBottomConstraint.isActive = true
    }

    /// Size the window to the form rather than guessing a height. Eight rows, one of them a
    /// five-checkbox stack, do not fit a hardcoded number — the content simply runs off the
    /// bottom. Fixed WIDTH is the spec's requirement; a fixed height was never asked for and
    /// was only ever going to clip. Re-run whenever the beta row is added/removed, not just
    /// once at construction.
    private func resizeWindowToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitted = content.fittingSize
        window.setContentSize(NSSize(width: Self.contentWidth, height: fitted.height))
    }

    @objc private func includeBetaVersionsToggled(_ sender: NSButton) {
        settings.includeBetaVersions = sender.state == .on
    }

    // MARK: - Loading and storing

    private func loadCurrentValues() {
        startingViewPopup.selectItem(withTitle: settings.startingView.displayName)
        zoomPopup.selectItem(withTitle: settings.defaultZoom == .actual ? "Actual" : "Fit")
        stylePopup.selectItem(withTitle: settings.defaultStyle.displayName)
        displayPopup.selectItem(withTitle: settings.defaultDisplay.displayName)
        fontPopup.selectItem(withTitle: settings.modernFontName)
        sizePopup.selectItem(withTitle: String(settings.modernFontSize))
        pageSizePopup.selectItem(withTitle: settings.defaultPageSize.displayName)
        // Reads the app-group container directly (not `settings`/`UserDefaults.standard`):
        // "Embedded" when unset is exactly `QuickLookPageSettingsPreference.resolvedDefault()
        // == nil` — the same "no override" contract QL's own read side already relies on.
        quickLookMarginsPopup.selectItem(withTitle:
            resolvedQuickLookMarginsDefault()?.displayName
                ?? DocumentOperations.PageSettingsPreset.embeddedChoiceName)
        for (format, check) in formatChecks {
            check.state = settings.defaultExportFormats.contains(format) ? .on : .off
        }
        restoreWindowsCheckbox.state = settings.restoreWindowsOnLaunch ? .on : .off
        headersCheckbox.state = settings.defaultHeaders ? .on : .off
        tocCheckbox.state = settings.defaultTOC ? .on : .off
        inlineStylingCheckbox.state = settings.defaultInlineStyling ? .on : .off
        picturesPopup.selectItem(at: Self.picturesTitles.firstIndex { $0.0 == settings.defaultPictures } ?? 1)
        pageNumbersPopup.selectItem(
            at: Self.pageNumbersTitles.firstIndex { $0.0 == settings.defaultPageNumbers } ?? 0)
    }

    private static let picturesTitles: [(EmitOptions.PixMode, String)] = [
        (.off, "Off"), (.embed, "Embed"), (.export, "Export"),
    ]

    private static let pageNumbersTitles: [(EmitOptions.PageNumberMode, String)] = [
        (.auto, "Auto"), (.on, "On"), (.off, "Off"),
    ]

    @objc private func startingViewChanged(_ sender: NSPopUpButton) {
        settings.startingView = StartingView.allCases
            .first { $0.displayName == sender.titleOfSelectedItem } ?? .document
    }

    @objc private func zoomChanged(_ sender: NSPopUpButton) {
        settings.defaultZoom = sender.titleOfSelectedItem == "Actual" ? .actual : .fit
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        settings.defaultStyle = ViewStyle.allCases
            .first { $0.displayName == sender.titleOfSelectedItem } ?? .native
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        settings.defaultDisplay = PageDisplay.allCases
            .first { $0.displayName == sender.titleOfSelectedItem } ?? .singlePage
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        settings.modernFontName = sender.titleOfSelectedItem ?? SettingsStore.defaultFontName
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        settings.modernFontSize = Int(sender.titleOfSelectedItem ?? "") ?? 14
    }

    @objc private func pageSizeChanged(_ sender: NSPopUpButton) {
        settings.defaultPageSize = NamedPageSize.allCases
            .first { $0.displayName == sender.titleOfSelectedItem } ?? .usLetter
    }

    private func resolvedQuickLookMarginsDefault() -> DocumentOperations.PageSettingsPreset? {
        if let quickLookDefaultsOverride {
            return QuickLookPageSettingsPreference.resolvedDefault(defaults: quickLookDefaultsOverride)
        }
        return QuickLookPageSettingsPreference.resolvedDefault()
    }

    /// Job 315 (b19 item 11): writes `QuickLookPageSettingsPreference` directly — the SAME
    /// app-group key the bottom bar's removed "Use as Default for Quick Look" action item
    /// used to write. "Embedded" matches no preset, so it resolves to `nil`, which clears
    /// the key exactly like choosing "Embedded" on that item used to (job 203's original
    /// "nil clears back to no override" contract, unchanged).
    @objc private func quickLookMarginsChanged(_ sender: NSPopUpButton) {
        let preset = DocumentOperations.PageSettingsPreset.allCases
            .first { $0.displayName == sender.titleOfSelectedItem }
        if let quickLookDefaultsOverride {
            QuickLookPageSettingsPreference.setDefault(preset, defaults: quickLookDefaultsOverride)
        } else {
            QuickLookPageSettingsPreference.setDefault(preset)
        }
    }

    @objc private func formatToggled(_ sender: NSButton) {
        var formats = settings.defaultExportFormats
        for (format, check) in formatChecks where check === sender {
            if check.state == .on { formats.insert(format) } else { formats.remove(format) }
        }
        settings.defaultExportFormats = formats
    }

    @objc private func restoreWindowsToggled(_ sender: NSButton) {
        settings.restoreWindowsOnLaunch = sender.state == .on
    }

    @objc private func headersToggled(_ sender: NSButton) {
        settings.defaultHeaders = sender.state == .on
    }

    @objc private func tocToggled(_ sender: NSButton) {
        settings.defaultTOC = sender.state == .on
    }

    @objc private func inlineStylingToggled(_ sender: NSButton) {
        settings.defaultInlineStyling = sender.state == .on
    }

    @objc private func picturesChanged(_ sender: NSPopUpButton) {
        settings.defaultPictures = Self.picturesTitles[safe: sender.indexOfSelectedItem]?.0 ?? .embed
    }

    @objc private func pageNumbersChanged(_ sender: NSPopUpButton) {
        settings.defaultPageNumbers = Self.pageNumbersTitles[safe: sender.indexOfSelectedItem]?.0 ?? .auto
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
