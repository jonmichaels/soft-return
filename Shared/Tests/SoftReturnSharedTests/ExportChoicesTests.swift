import CtrlKD
import Testing
@testable import SoftReturnShared

/// Which options each format allows, and the words the choices go by.
@Suite struct ExportChoicesTests {
    @Test func pagedOptionsMeanSomethingOnlyForRTFAndPDF() {
        for option in [ExportOption.headers, .pageNumbers] {
            for format in ExportFormat.allCases {
                #expect(format.allows(option) == (format == .rtf || format == .pdf), "\(option) \(format)")
            }
        }
    }

    @Test func inlineStylingIsRTFAndHTMLOnly() {
        #expect(ExportFormat.allCases.filter { $0.allows(.inlineStyling) } == [.html, .rtf])
    }

    @Test func picturesApplyToEverythingButPlainText() {
        #expect(ExportFormat.allCases.filter { $0.allows(.pictures) } == [.markdown, .html, .rtf, .pdf])
    }

    @Test func contentsAndSentenceSpacingApplyToAllFive() {
        for option in [ExportOption.toc, .sentenceSpacing] {
            #expect(ExportFormat.allCases.allSatisfy { $0.allows(option) })
        }
    }

    @Test func aControlIsEnabledWhenAnyCheckedFormatUsesIt() {
        #expect(ExportOption.headers.isEnabled(forFormats: [ExportFormat.text, .pdf]))
        #expect(!ExportOption.headers.isEnabled(forFormats: [ExportFormat.text, .html, .markdown]))
        #expect(!ExportOption.inlineStyling.isEnabled(forFormats: [ExportFormat.pdf]))
        #expect(!ExportOption.pictures.isEnabled(forFormats: [ExportFormat.text]))
        // Nothing checked: the format-specific controls go quiet, the all-format ones stay on.
        #expect(!ExportOption.headers.isEnabled(forFormats: [ExportFormat]()))
        #expect(ExportOption.toc.isEnabled(forFormats: [ExportFormat]()))
        #expect(ExportOption.sentenceSpacing.isEnabled(forFormats: [ExportFormat]()))
    }

    @Test func optionTitlesAreTheSheetsRows() {
        #expect(ExportOption.allCases.map(\.title) == [
            "Headers/Footers", "Table of Contents", "Inline Styling", "Pictures", "Page Numbering", "Sentence Spacing",
        ])
    }

    @Test func choiceTitlesAreInMenuOrder() {
        #expect(EmitOptions.PixMode.choices.map(\.displayName) == ["Off", "Embed", "Export"])
        #expect(EmitOptions.PageNumberMode.choices.map(\.displayName) == ["Auto", "On", "Off"])
        #expect(EmitOptions.SentenceSpacingMode.choices.map(\.displayName) == ["Auto", "Keep as typed", "Single space"])
    }

    @Test func applyWritesAllSixChoicesIntoTheOptions() {
        var options = EmitOptions()
        ExportChoices(headers: false, toc: true, inlineStyling: false, pictures: .export,
                      pageNumbers: .off, sentenceSpacing: .keep).apply(to: &options)
        #expect(!options.headers && options.toc && !options.inlineStyling)
        #expect(options.pictures == .export && options.pageNumbers == .off && options.sentenceSpacing == .keep)
    }
}
