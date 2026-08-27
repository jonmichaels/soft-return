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
}
