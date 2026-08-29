import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 373 (b24 FLAG UI): `ExportAccessoryView`'s new "Options" column — Headers/Footers,
/// Table of Contents, Inline Styling (checkboxes) and Pictures (a pulldown). These tests
/// exercise the REAL view tree (`WiringTests`' own "does it actually work, not does it
/// compile" discipline), not just the `selected*` accessors `FlagUIPlumbingTests` already
/// covers at the options-struct level.
@Suite @MainActor struct ExportSheetOptionsTests {

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func checkbox(_ accessory: ExportAccessoryView, _ identifier: String) throws -> NSButton {
        try #require(
            descendants(accessory).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no \(identifier) NSButton found in the accessory's view tree")
    }

    private static func popup(_ accessory: ExportAccessoryView, _ identifier: String) throws -> NSPopUpButton {
        try #require(
            descendants(accessory).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no \(identifier) NSPopUpButton found in the accessory's view tree")
    }

    private static func isolatedSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "ExportSheetOptionsTests.\(UUID().uuidString)")!)
    }

    // MARK: - Controls exist, are labelled, and default from Settings

    @Test func allFourControlsExistWithAccessibilityIdentifiersAndLabels() throws {
        let settings = Self.isolatedSettings()
        let accessory = ExportAccessoryView(
            formats: [.rtf, .html], notes: NoteSelection(), style: .native, settings: settings)
        accessory.layoutSubtreeIfNeeded()

        let headers = try Self.checkbox(accessory, "export-headers-checkbox")
        let toc = try Self.checkbox(accessory, "export-toc-checkbox")
        let inlineStyling = try Self.checkbox(accessory, "export-inline-styling-checkbox")
        let pictures = try Self.popup(accessory, "export-pictures-popup")
        let pageNumbers = try Self.popup(accessory, "export-page-numbers-popup")
        let sentenceSpacing = try Self.popup(accessory, "export-sentence-spacing-popup")

        for control in [headers, toc, inlineStyling] as [NSButton] {
            #expect(!(control.accessibilityLabel() ?? "").isEmpty)
        }
        #expect(!(pictures.accessibilityLabel() ?? "").isEmpty)
        #expect(pictures.itemTitles == ["Off", "Embed", "Export"])
        #expect(!(pageNumbers.accessibilityLabel() ?? "").isEmpty)
        #expect(pageNumbers.itemTitles == ["Auto", "On", "Off"])
        #expect(!(sentenceSpacing.accessibilityLabel() ?? "").isEmpty)
        #expect(sentenceSpacing.itemTitles == ["Auto", "Keep as typed", "Single space"])
    }

    @Test func controlsInitializeFromSettingsNotHardcodedDefaults() throws {
        let settings = Self.isolatedSettings()
        settings.defaultHeaders = false
        settings.defaultTOC = true
        settings.defaultInlineStyling = false
        settings.defaultPictures = .off
        settings.defaultPageNumbers = .off

        let accessory = ExportAccessoryView(
            formats: [.rtf], notes: NoteSelection(), style: .native, settings: settings)
        #expect(accessory.selectedHeaders == false)
        #expect(accessory.selectedTOC == true)
        #expect(accessory.selectedInlineStyling == false)
        #expect(accessory.selectedPictures == .off)
        #expect(accessory.selectedPageNumbers == .off)
    }

    /// The RULED defaults themselves (brief item 2): headers ON, TOC OFF, Pictures Embed,
    /// inline styling ON — a fresh `SettingsStore` (nothing ever written) must read back
    /// exactly these, and so must a freshly-opened sheet.
    @Test func freshSettingsAndFreshSheetBothStartAtTheRuledDefaults() throws {
        let settings = Self.isolatedSettings()
        #expect(settings.defaultHeaders == true)
        #expect(settings.defaultTOC == false)
        #expect(settings.defaultInlineStyling == true)
        #expect(settings.defaultPictures == .embed)
        #expect(settings.defaultPageNumbers == .auto)

        let accessory = ExportAccessoryView(
            formats: [.rtf], notes: NoteSelection(), style: .native, settings: settings)
        #expect(accessory.selectedHeaders == true)
        #expect(accessory.selectedTOC == false)
        #expect(accessory.selectedInlineStyling == true)
        #expect(accessory.selectedPictures == .embed)
        #expect(accessory.selectedPageNumbers == .auto)
    }

    /// Job 521 (N9): unlike every other Options-column control, Sentence Spacing has NO
    /// Settings item at all (Jon's ruling) — it must always start at the plain literal
    /// `.auto`, regardless of what `settings` reports for anything else, and there is no
    /// `settings.defaultSentenceSpacing` to even attempt setting.
    @Test func sentenceSpacingAlwaysStartsAtAutoRegardlessOfSettings() throws {
        let settings = Self.isolatedSettings()
        settings.defaultHeaders = false
        settings.defaultPageNumbers = .off

        let accessory = ExportAccessoryView(
            formats: [.rtf], notes: NoteSelection(), style: .native, settings: settings)
        #expect(accessory.selectedSentenceSpacing == .auto)
    }

    /// "per-export override never writes back" (item 2): flipping a checkbox in the sheet
    /// must never mutate the Settings store it was initialized from.
    @Test func perExportOverrideNeverWritesBackToSettings() throws {
        let settings = Self.isolatedSettings()
        let accessory = ExportAccessoryView(
            formats: [.rtf], notes: NoteSelection(), style: .native, settings: settings)
        accessory.layoutSubtreeIfNeeded()

        let headers = try Self.checkbox(accessory, "export-headers-checkbox")
        headers.state = .off
        let toc = try Self.checkbox(accessory, "export-toc-checkbox")
        toc.state = .on

        #expect(accessory.selectedHeaders == false, "the sheet's own control should reflect the click")
        #expect(settings.defaultHeaders == true, "Settings' own default must be untouched")
        #expect(accessory.selectedTOC == true)
        #expect(settings.defaultTOC == false, "Settings' own default must be untouched")

        let pageNumbers = try Self.popup(accessory, "export-page-numbers-popup")
        pageNumbers.selectItem(withTitle: "On")
        #expect(accessory.selectedPageNumbers == .on, "the sheet's own control should reflect the pick")
        #expect(settings.defaultPageNumbers == .auto, "Settings' own default must be untouched")

        // Job 521 (N9): there is no Settings field to leave untouched here at all — just the
        // sheet's own control reflecting the pick.
        let sentenceSpacing = try Self.popup(accessory, "export-sentence-spacing-popup")
        sentenceSpacing.selectItem(withTitle: "Single space")
        #expect(accessory.selectedSentenceSpacing == .single, "the sheet's own control should reflect the pick")
    }

    // MARK: - Enable/disable per the paged-surface doctrine, per checked format

    /// Headers/Footers: paged formats only (RTF/PDF).
    @Test func headersControlEnabledOnlyForPagedFormats() throws {
        let flatOnly = ExportAccessoryView(
            formats: [.text, .markdown, .html], notes: NoteSelection(), style: .native)
        flatOnly.layoutSubtreeIfNeeded()
        #expect(try !Self.checkbox(flatOnly, "export-headers-checkbox").isEnabled)

        let withRTF = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        withRTF.layoutSubtreeIfNeeded()
        #expect(try Self.checkbox(withRTF, "export-headers-checkbox").isEnabled)

        let withPDF = ExportAccessoryView(formats: [.pdf], notes: NoteSelection(), style: .native)
        withPDF.layoutSubtreeIfNeeded()
        #expect(try Self.checkbox(withPDF, "export-headers-checkbox").isEnabled)
    }

    /// Inline Styling: RTF/HTML only.
    @Test func inlineStylingControlEnabledOnlyForRTFOrHTML() throws {
        let neither = ExportAccessoryView(
            formats: [.text, .markdown, .pdf], notes: NoteSelection(), style: .native)
        neither.layoutSubtreeIfNeeded()
        #expect(try !Self.checkbox(neither, "export-inline-styling-checkbox").isEnabled)

        let withHTML = ExportAccessoryView(formats: [.html], notes: NoteSelection(), style: .native)
        withHTML.layoutSubtreeIfNeeded()
        #expect(try Self.checkbox(withHTML, "export-inline-styling-checkbox").isEnabled)
    }

    /// Pictures: every format but plain text.
    @Test func picturesControlDisabledOnlyWhenTextIsTheOnlyFormat() throws {
        let textOnly = ExportAccessoryView(formats: [.text], notes: NoteSelection(), style: .native)
        textOnly.layoutSubtreeIfNeeded()
        #expect(try !Self.popup(textOnly, "export-pictures-popup").isEnabled)

        let textPlusHTML = ExportAccessoryView(
            formats: [.text, .html], notes: NoteSelection(), style: .native)
        textPlusHTML.layoutSubtreeIfNeeded()
        #expect(try Self.popup(textPlusHTML, "export-pictures-popup").isEnabled)
    }

    /// Page Numbering (job 520): paged formats only (RTF/PDF), same rule as Headers/Footers.
    @Test func pageNumbersControlEnabledOnlyForPagedFormats() throws {
        let flatOnly = ExportAccessoryView(
            formats: [.text, .markdown, .html], notes: NoteSelection(), style: .native)
        flatOnly.layoutSubtreeIfNeeded()
        #expect(try !Self.popup(flatOnly, "export-page-numbers-popup").isEnabled)

        let withRTF = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        withRTF.layoutSubtreeIfNeeded()
        #expect(try Self.popup(withRTF, "export-page-numbers-popup").isEnabled)

        let withPDF = ExportAccessoryView(formats: [.pdf], notes: NoteSelection(), style: .native)
        withPDF.layoutSubtreeIfNeeded()
        #expect(try Self.popup(withPDF, "export-page-numbers-popup").isEnabled)
    }

    /// Table of Contents/Index: never disabled — applies to all five formats.
    @Test func tocControlNeverDisabled() throws {
        let textOnly = ExportAccessoryView(formats: [.text], notes: NoteSelection(), style: .native)
        textOnly.layoutSubtreeIfNeeded()
        #expect(try Self.checkbox(textOnly, "export-toc-checkbox").isEnabled)
    }

    /// Sentence Spacing (job 521): also never disabled — unlike Headers/Footers/Page
    /// Numbering, `EmitOptions.sentenceSpacing`'s own doc comment says it applies "in every
    /// format", not paged-formats-only, so a plain-text-only selection must still leave it
    /// enabled.
    @Test func sentenceSpacingControlNeverDisabled() throws {
        let textOnly = ExportAccessoryView(formats: [.text], notes: NoteSelection(), style: .native)
        textOnly.layoutSubtreeIfNeeded()
        #expect(try Self.popup(textOnly, "export-sentence-spacing-popup").isEnabled)
    }

    /// Toggling a format checkbox re-evaluates availability live, the same
    /// `onFormatsChanged` moment the panel's own `allowedContentTypes` sync already uses.
    @Test func togglingAFormatCheckboxLiveUpdatesOptionAvailability() throws {
        let accessory = ExportAccessoryView(formats: [.text], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()
        let headers = try Self.checkbox(accessory, "export-headers-checkbox")
        #expect(!headers.isEnabled)

        let rtfCheck = try #require(
            Self.descendants(accessory).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "export-format-rtf-checkbox" })
        rtfCheck.state = .on
        rtfCheck.sendAction(rtfCheck.action, to: rtfCheck.target)
        #expect(headers.isEnabled, "checking RTF should enable Headers/Footers immediately")
    }

    // MARK: - Job 536 (Part A2): popup width + fourth column

    /// Jon's ruling: Pictures/Page Numbering/Sentence Spacing get ~2/3 of `popupWidth`
    /// (185 * 2/3 = 123.3, rounded to a clean 120pt) — narrower than every OTHER popup/
    /// checkbox-column control in the sheet, which still uses the full `popupWidth`.
    @Test func theThreeShortPopupsAreNarrowerThanTheStandardPopupWidth() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()
        for identifier in ["export-pictures-popup", "export-page-numbers-popup", "export-sentence-spacing-popup"] {
            let popup = try Self.popup(accessory, identifier)
            let widthConstraint = try #require(
                popup.constraints.first { $0.firstAttribute == .width },
                "\(identifier) has no explicit width constraint")
            #expect(widthConstraint.constant == 120, "\(identifier) must be the ~2/3-width constant, not the full popup width")
        }
    }

    /// Jon's ruling: the trio (with their row labels) lives in its own fourth column now,
    /// never inside the Options checkbox column — asserted by walking the actual view tree
    /// rather than re-deriving the layout, same discipline every other test in this file uses.
    @Test func theThreePopupsSitOutsideTheOptionsCheckboxColumn() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()

        let optionsHeading = try #require(
            Self.descendants(accessory).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "Options" },
            "no 'Options' column heading found")
        let optionsColumn = try #require(optionsHeading.superview as? NSStackView,
                                         "'Options' heading is not the first row of its own column stack")
        let optionsColumnControls = optionsColumn.arrangedSubviews
        #expect(!optionsColumnControls.contains { $0.accessibilityIdentifier() == "export-pictures-popup" })
        #expect(!optionsColumnControls.contains { $0.accessibilityIdentifier() == "export-page-numbers-popup" })
        #expect(!optionsColumnControls.contains { $0.accessibilityIdentifier() == "export-sentence-spacing-popup" })

        // The Options column keeps exactly its three checkboxes plus its own heading now.
        #expect(optionsColumnControls.count == 4,
                "Options column must be heading + Headers/Footers + Table of Contents + Inline Styling only")

        // And the three popups must still exist SOMEWHERE in the tree — moved, not dropped.
        #expect(try Self.popup(accessory, "export-pictures-popup").superview != nil)
        #expect(try Self.popup(accessory, "export-page-numbers-popup").superview != nil)
        #expect(try Self.popup(accessory, "export-sentence-spacing-popup").superview != nil)
    }

    /// The sheet as a whole must show four top-level columns now (Formats, Notes, Options,
    /// popups), not the pre-job-536 three.
    @Test func theSheetShowsFourTopLevelColumns() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()

        let headings = ["Formats", "Notes", "Options"]
        let headingFields = headings.map { heading in
            Self.descendants(accessory).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == heading }
        }
        #expect(headingFields.allSatisfy { $0 != nil }, "missing one of the three named column headings")

        let columnStacks = Set(headingFields.compactMap { $0?.superview as? NSStackView }.map(ObjectIdentifier.init))
        #expect(columnStacks.count == 3, "Formats/Notes/Options must each be their own column stack")

        let columnsRow = try #require(
            headingFields.compactMap { $0?.superview as? NSStackView }.first?.superview as? NSStackView,
            "the three named columns must share one parent row stack")
        #expect(columnsRow.arrangedSubviews.count == 4,
                "the columns row must hold four columns (Formats, Notes, Options, and the new popups column)")
    }

    // MARK: - Job 545 (R2): popup-grid row spacing and top alignment

    private static func columnStack(_ accessory: ExportAccessoryView, headingText: String) throws -> NSStackView {
        let heading = try #require(
            Self.descendants(accessory).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == headingText },
            "no '\(headingText)' column heading found")
        return try #require(heading.superview as? NSStackView,
                             "'\(headingText)' heading is not the first row of its own column stack")
    }

    private static func grid(_ accessory: ExportAccessoryView) throws -> NSGridView {
        try #require(Self.descendants(accessory).compactMap { $0 as? NSGridView }.first,
                     "no NSGridView found in the accessory's view tree")
    }

    /// Jon's ruling (macOS 26 screenshot): the popup grid's row spacing must be the SAME
    /// value the checkbox columns use, not a second, larger literal.
    @Test func popupGridRowSpacingMatchesTheCheckboxColumnsOwnSpacing() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()

        let formatsColumn = try Self.columnStack(accessory, headingText: "Formats")
        let grid = try Self.grid(accessory)
        let message = "the popup grid's row spacing (\(grid.rowSpacing)) must match the checkbox "
            + "columns' own row spacing (\(formatsColumn.spacing))"
        #expect(grid.rowSpacing == formatsColumn.spacing, "\(message)")
    }

    /// Jon's ruling: the popups column must start at the same Y as the other three columns'
    /// first row, not float lower — checked against each control's own ALIGNMENT rect (not
    /// its raw frame), converted into one shared coordinate space. Job511BatchLayoutTests'
    /// own precedent comment names the reason: a bordered/bezeled `NSPopUpButton`'s raw
    /// `.frame` carries several points of bezel chrome an `NSButton` checkbox's frame doesn't
    /// (`alignmentRectInsets`, "a universal AppKit property of this control style") — Auto
    /// Layout and `NSStackView`/`NSGridView` position views by their alignment rect for
    /// exactly this reason, so comparing raw frames here would flag a chrome difference as a
    /// layout bug it isn't.
    @Test func picturesPopupTopAlignsWithTheChecklistColumnsFirstRow() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()

        let firstFormatCheckbox = try Self.checkbox(
            accessory, "export-format-\(ExportFormat.allCases[0].rawValue)-checkbox")
        let picturesPopup = try Self.popup(accessory, "export-pictures-popup")

        func alignmentTop(_ view: NSView) throws -> CGFloat {
            let superview = try #require(view.superview, "\(view) has no superview to convert from")
            let alignmentRect = view.alignmentRect(forFrame: view.frame)
            return superview.convert(NSPoint(x: 0, y: alignmentRect.maxY), to: accessory).y
        }

        let checkboxTop = try alignmentTop(firstFormatCheckbox)
        let popupTop = try alignmentTop(picturesPopup)
        let message = "Pictures row (alignment top \(popupTop)) must align with the first "
            + "checkbox's row (alignment top \(checkboxTop))"
        #expect(abs(checkboxTop - popupTop) < 1.0, "\(message)")
    }
}
