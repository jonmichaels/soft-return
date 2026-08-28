import AppKit
import CtrlKD

/// The Export As sheet's accessory: a centered Style pulldown above three balanced checkbox
/// columns, Formats, Notes, and Options.
///
/// It rides in a real `NSSavePanel` — the panel, its filename field, its destination
/// browser and its overwrite handling are all AppKit's. This view is the only custom part,
/// and it exists because the standard panel has nowhere to say "these five formats and
/// these four note kinds".
///
/// Job 323 (b20, item 3 — Jon's ruling): the old Style `NSSegmentedControl` sat as a THIRD
/// column beside Formats/Notes (job 244 Leg 3). Jon's ruling replaces it with an
/// `NSPopUpButton` offering the window's full three-case view vocabulary (`ViewStyle` —
/// Native/Printed/Modern, not `RenderStyle`'s export-only two), sitting ABOVE the pair as its
/// own centered row — "like a format selector for an Open or Save dialog box" — with Formats
/// and Notes re-centered as a pair now that Style no longer shares their row.
///
/// Job 373 (b24 FLAG UI): a third "Options" column joins the pair — Headers/Footers, Table
/// of Contents, Inline Styling (checkboxes) and Pictures (a pulldown), the export-sheet half
/// of the b24 flag wave. Each control's ENABLED state tracks the currently checked formats
/// per the paged-surface doctrine — Headers/Footers is paged-formats-only (RTF/PDF), Inline
/// Styling is RTF/HTML-only, Pictures is every format but plain text, and Table of
/// Contents/Index applies to all five — updated by the same `onFormatsChanged` hook the
/// panel's own `allowedContentTypes` sync already uses, so both reactions to a format
/// checkbox flip live in one place. Initial state comes from `SettingsStore` (RULED
/// defaults: headers ON, TOC OFF, Pictures Embed, inline styling ON); a per-export change
/// here never writes back to Settings — the caller reads `selected*` once, at Export time.
///
/// Job 520 (N5, b33 page-numbering UI): a fifth Options-column control, Page Numbering (a
/// pulldown, same shape as Pictures) — the three-state `auto`/`on`/`off` WordStar automatic
/// page number the b33 engine pin's `--page-numbers` controls. Same paged-formats-only
/// (RTF/PDF) enable rule as Headers/Footers, per `SoftReturn.sdef`'s own `page numbers`
/// parameter description; same "initializes from Settings, never writes back" rule as the
/// rest of this column.
///
/// Job 521 (N9, b33 sentence-spacing UI): a sixth Options-column control, Sentence Spacing —
/// the three-state `auto`/`keep`/`single` typewriter-double-space collapse the b33 engine
/// pin's `--sentence-spacing` controls. Jon's ruling scopes this to the export surfaces and
/// AppleScript only, with NO Settings item — so unlike every other control in this column,
/// this one always starts at the plain literal `.auto`, never `settings.default*`, and
/// applies to every format (never paged-formats-only, per `EmitOptions.sentenceSpacing`'s own
/// doc comment: "Applies to body text and all four note kinds' text, in every format") — so
/// it is never disabled by `updateOptionAvailability` either.
///
/// Job 530 (Jon's ruling 2026-08-27, b34 work): rebuilt the Style/Pictures/Page Numbering/
/// Sentence Spacing popups the SETTINGS way — job 528 audited this file and found them real
/// `NSPopUpButton`s already, but each auto-sizing to its own intrinsic content width with no
/// shared width constraint, and the Formats/Notes/Options columns spaced with a `fillEqually`
/// distribution that stretched the two short columns to match the widest, leaving large blank
/// gaps. Both fixed here: one hard `widthAnchor` constant (`popupWidth`, same derivation as
/// `BatchWindowController`'s — `SettingsWindowController.popupWidth - 5`, per job 511's
/// ruling) on every popup, and the columns row switched to `.fill` distribution with tighter
/// spacing so each column sizes to its own content.
///
/// Job 536 (v4.0.0 UI notes, Part A2, Jon's ruling): two more changes on top of job 530's
/// layout. (a) Pictures/Page Numbering/Sentence Spacing don't need `popupWidth` — their titles
/// ("Off"/"Auto"/"Single space", ...) are far shorter than Formats/Notes checkbox labels, so
/// job 530's shared width just left a wide, empty-looking pulldown. `smallPopupWidth` (2/3 of
/// `popupWidth` — 185 * 2/3 = 123.3, rounded to a clean 120pt) is the constant Jon asked for,
/// "not exact pixels — pick a clean constant." (b) that trio (with their row labels) moves out
/// of the Options column into its OWN fourth column — Options keeps only the three checkboxes
/// (Headers/Footers, Table of Contents, Inline Styling); the popup grid gets a column to
/// itself so it's no longer squeezed under three unrelated checkboxes.
final class ExportAccessoryView: NSView {
    private var formatChecks: [ExportFormat: NSButton] = [:]
    private var noteChecks: [String: NSButton] = [:]
    private var notes: NoteSelection
    private var stylePopup: NSPopUpButton!
    private var headersCheck: NSButton!
    private var tocCheck: NSButton!
    private var inlineStylingCheck: NSButton!
    private var picturesPopup: NSPopUpButton!
    private var pageNumbersPopup: NSPopUpButton!
    private var sentenceSpacingPopup: NSPopUpButton!

    /// One width for every popup in this sheet, the same derivation job 528 used for
    /// `BatchWindowController`'s pulldowns (job 511's ruling: Settings' own 190, minus 5) —
    /// not `SettingsWindowController.popupWidth` directly, so this sheet's popups match
    /// Batch's width rather than Settings'.
    private static let popupWidth = SettingsWindowController.popupWidth - 5

    /// Job 536 (Part A2): ~2/3 of `popupWidth` (185 * 2/3 = 123.3), for the three short-title
    /// popups (Pictures/Page Numbering/Sentence Spacing) that never needed the full form-field
    /// width — a clean 120pt, not the exact fraction (Jon: "not exact pixels").
    private static let smallPopupWidth: CGFloat = 120

    /// Fires whenever a format checkbox flips — the panel keeps `allowedContentTypes` (and
    /// so the extension it will grant back) in sync with exactly-one-format-checked (job 244
    /// Leg 1), and (job 373) the Options column's controls in sync with which formats can
    /// actually use them.
    var onFormatsChanged: (() -> Void)?

    /// `style` is the exporting window's CURRENT view — Native, Printed, or Modern — which
    /// this pulldown defaults to (job 323): "export what you see" stays the default, still
    /// overridable per export. `settings` supplies the Options column's initial values (job
    /// 373); a test can inject an isolated store the same way `SettingsWindowController`
    /// already does, rather than touching the real shared one.
    init(formats: Set<ExportFormat>, notes: NoteSelection, style: ViewStyle,
        settings: SettingsStore = .shared) {
        self.notes = notes
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        setAccessibilityIdentifier("export-accessory")

        let popup = Self.makePopup(
            titles: ViewStyle.allCases.map(\.displayName),
            selectedIndex: ViewStyle.allCases.firstIndex(of: style) ?? 0,
            identifier: "export-style-popup", accessibilityLabel: "Style")
        stylePopup = popup
        let styleRow = NSStackView(views: [Self.makeLabel("Style:"), popup])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8

        let formatColumn = column(title: "Formats", views: ExportFormat.allCases.map { format in
            let check = NSButton(checkboxWithTitle: format.displayName, target: self,
                                 action: #selector(formatCheckChanged))
            check.state = formats.contains(format) ? .on : .off
            check.setAccessibilityIdentifier("export-format-\(format.rawValue)-checkbox")
            check.setAccessibilityLabel("Export as \(format.displayName)")
            formatChecks[format] = check
            return check
        })

        let noteRows: [(String, String, Bool)] = [
            ("Footnotes", "footnotes", notes.footnotes),
            ("Endnotes", "endnotes", notes.endnotes),
            ("Annotations", "annotations", notes.annotations),
            ("Comments", "comments", notes.comments),
        ]
        let noteColumn = column(title: "Notes", views: noteRows.map { title, key, on in
            let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            check.state = on ? .on : .off
            check.setAccessibilityIdentifier("export-notes-\(key)-checkbox")
            check.setAccessibilityLabel("Include \(title.lowercased())")
            noteChecks[key] = check
            return check
        })

        let headers = NSButton(checkboxWithTitle: "Headers/Footers", target: nil, action: nil)
        headers.state = settings.defaultHeaders ? .on : .off
        headers.setAccessibilityIdentifier("export-headers-checkbox")
        headers.setAccessibilityLabel("Include headers and footers")
        headersCheck = headers

        let toc = NSButton(checkboxWithTitle: "Table of Contents", target: nil, action: nil)
        toc.state = settings.defaultTOC ? .on : .off
        toc.setAccessibilityIdentifier("export-toc-checkbox")
        toc.setAccessibilityLabel("Include table of contents and index")
        tocCheck = toc

        let inlineStyling = NSButton(checkboxWithTitle: "Inline Styling", target: nil, action: nil)
        inlineStyling.state = settings.defaultInlineStyling ? .on : .off
        inlineStyling.setAccessibilityIdentifier("export-inline-styling-checkbox")
        inlineStyling.setAccessibilityLabel("Include the author's inline color and size styling")
        inlineStylingCheck = inlineStyling

        let picturesButton = Self.makePopup(
            titles: Self.pixModeTitles.map(\.1),
            selectedIndex: Self.pixModeTitles.firstIndex { $0.0 == settings.defaultPictures } ?? 1,
            identifier: "export-pictures-popup", accessibilityLabel: "Pictures",
            width: Self.smallPopupWidth)
        picturesPopup = picturesButton

        let pageNumbersButton = Self.makePopup(
            titles: Self.pageNumbersTitles.map(\.1),
            selectedIndex: Self.pageNumbersTitles.firstIndex { $0.0 == settings.defaultPageNumbers } ?? 0,
            identifier: "export-page-numbers-popup", accessibilityLabel: "Page Numbering",
            width: Self.smallPopupWidth)
        pageNumbersPopup = pageNumbersButton

        let sentenceSpacingButton = Self.makePopup(
            titles: Self.sentenceSpacingTitles.map(\.1), selectedIndex: 0,
            identifier: "export-sentence-spacing-popup", accessibilityLabel: "Sentence Spacing",
            width: Self.smallPopupWidth)
        sentenceSpacingPopup = sentenceSpacingButton

        // The Settings form idiom (`SettingsWindowController.style(_:)`): labels right-aligned
        // into a shared gutter, every popup starting at one left edge — rather than three rows
        // each independently sized around its own label's width.
        let popupGrid = NSGridView(views: [
            [Self.makeLabel("Pictures:"), picturesButton],
            [Self.makeLabel("Page Numbering:"), pageNumbersButton],
            [Self.makeLabel("Sentence Spacing:"), sentenceSpacingButton],
        ])
        popupGrid.translatesAutoresizingMaskIntoConstraints = false
        popupGrid.rowSpacing = 12
        popupGrid.columnSpacing = 10
        popupGrid.column(at: 0).xPlacement = .trailing
        popupGrid.column(at: 1).xPlacement = .leading
        for index in 0..<popupGrid.numberOfRows {
            popupGrid.row(at: index).yPlacement = .center
        }

        let optionsColumn = column(
            title: "Options",
            views: [headers, toc, inlineStyling])

        // Job 536 (Part A2): the popup trio gets its own column now, so it isn't squeezed
        // under three unrelated checkboxes. A blank (not omitted) heading keeps this column's
        // content starting at the same Y as the other three columns' first real row —
        // `column(title:views:)`'s heading is what reserves that line of vertical space.
        let popupsColumn = column(title: "", views: [popupGrid])

        // Re-centered as a pair (job 323) — Style no longer rides beside them as a third
        // column, so this row now balances Formats/Notes/Options/(popups). Job 530: `.fill`
        // (each column its own natural width) rather than `.fillEqually` (every column
        // stretched to match the widest), which was leaving large blank gaps in the short
        // columns — and tighter spacing now that the popup width fix stops the Options column
        // ballooning.
        let columns = NSStackView(views: [formatColumn, noteColumn, optionsColumn, popupsColumn])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 24

        let outer = NSStackView(views: [styleRow, columns])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            outer.centerXAnchor.constraint(equalTo: centerXAnchor),
            outer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])

        updateOptionAvailability()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func formatCheckChanged(_ sender: NSButton) {
        updateOptionAvailability()
        onFormatsChanged?()
    }

    /// Paged-surface doctrine, per format: Headers/Footers only means anything for the two
    /// paged emitters (RTF/PDF — `EmitOptions.headers`'s own doc comment); Inline Styling only
    /// for RTF/HTML (`EmitOptions.inlineStyling`'s own doc comment: "never gates a font's
    /// FAMILY switch... nor PDF"); Pictures for every format but plain text (`.PIX` has no
    /// flat-text representation at all); Table of Contents/Index applies to all five and so is
    /// never disabled. A disabled control keeps its last state rather than resetting, so
    /// re-checking a paged format restores what the person had chosen rather than a fresh
    /// default.
    private func updateOptionAvailability() {
        let formats = selectedFormats
        headersCheck.isEnabled = formats.contains(.rtf) || formats.contains(.pdf)
        inlineStylingCheck.isEnabled = formats.contains(.rtf) || formats.contains(.html)
        picturesPopup.isEnabled = formats.contains { $0 != .text }
        // Same paged-formats-only rule as Headers/Footers — `SoftReturn.sdef`'s own `page
        // numbers` parameter description: "(paged formats only — RTF/PDF)".
        pageNumbersPopup.isEnabled = formats.contains(.rtf) || formats.contains(.pdf)
    }

    private static let pixModeTitles: [(EmitOptions.PixMode, String)] = [
        (.off, "Off"), (.embed, "Embed"), (.export, "Export"),
    ]

    private static let pageNumbersTitles: [(EmitOptions.PageNumberMode, String)] = [
        (.auto, "Auto"), (.on, "On"), (.off, "Off"),
    ]

    private static let sentenceSpacingTitles: [(EmitOptions.SentenceSpacingMode, String)] = [
        (.auto, "Auto"), (.keep, "Keep as typed"), (.single, "Single space"),
    ]

    /// `FormControl.popUpButton` minus the target/action — this sheet's popups are read once
    /// at Export time (`selected*` below), never live-wired. (job 531: unified with
    /// `SettingsWindowController.popup(_:_:_:_:)` onto the shared `FormControl` helper — see
    /// its own doc comment.)
    private static func makePopup(
        titles: [String], selectedIndex: Int, identifier: String, accessibilityLabel: String,
        width: CGFloat = ExportAccessoryView.popupWidth
    ) -> NSPopUpButton {
        let button = FormControl.popUpButton(titles: titles, identifier: identifier,
                                              accessibilityLabel: accessibilityLabel,
                                              width: width)
        button.selectItem(at: selectedIndex)
        return button
    }

    /// job 531: unified with `SettingsWindowController.label(_:)` onto `FormControl` — see its
    /// own doc comment. Right-aligned, so a right-aligned grid column of these reads as one
    /// gutter regardless of each label's own text length.
    private static func makeLabel(_ text: String) -> NSTextField {
        FormControl.rightAlignedLabel(text)
    }

    private func column(title: String, views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    // MARK: - Results

    /// Chosen formats, in the spec's fixed order rather than click order — a batch that
    /// writes .txt before .pdf every time is easier to reason about than one that follows
    /// whichever box was ticked first.
    var selectedFormats: [ExportFormat] {
        ExportFormat.allCases.filter { formatChecks[$0]?.state == .on }
    }

    var noteSelection: NoteSelection {
        NoteSelection(
            footnotes: noteChecks["footnotes"]?.state == .on,
            endnotes: noteChecks["endnotes"]?.state == .on,
            annotations: noteChecks["annotations"]?.state == .on,
            comments: noteChecks["comments"]?.state == .on
        )
    }

    /// The pulldown's own chosen value — the CALLER's job (job 323) is to pass this straight
    /// through as `ExportEngine.render`'s `viewStyle` argument, not fall back to the window's
    /// ambient current style, so an explicit Printed choice on a Native window honestly
    /// exports engine bytes instead of silently re-deriving the print-path carve-out.
    var selectedStyle: ViewStyle {
        ViewStyle.allCases[safe: stylePopup.indexOfSelectedItem] ?? .native
    }

    // MARK: - Results (job 373, the Options column)

    var selectedHeaders: Bool { headersCheck.state == .on }
    var selectedTOC: Bool { tocCheck.state == .on }
    var selectedInlineStyling: Bool { inlineStylingCheck.state == .on }
    var selectedPictures: EmitOptions.PixMode {
        Self.pixModeTitles[safe: picturesPopup.indexOfSelectedItem]?.0 ?? .embed
    }
    var selectedPageNumbers: EmitOptions.PageNumberMode {
        Self.pageNumbersTitles[safe: pageNumbersPopup.indexOfSelectedItem]?.0 ?? .auto
    }
    var selectedSentenceSpacing: EmitOptions.SentenceSpacingMode {
        Self.sentenceSpacingTitles[safe: sentenceSpacingPopup.indexOfSelectedItem]?.0 ?? .auto
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
