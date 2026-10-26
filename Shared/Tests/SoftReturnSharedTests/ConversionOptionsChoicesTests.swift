import CtrlKD
import Testing
@testable import SoftReturnShared

/// The conversion options carry the six per-export choices as one value, and the two ways of
/// building them agree.
@Suite struct ConversionOptionsChoicesTests {
    @Test func fieldByFieldAndAsOneValueBuildTheSameOptions() {
        let choices = ExportChoices(headers: false, toc: true, inlineStyling: false,
                                    pictures: .export, pageNumbers: .on, sentenceSpacing: .single)
        let single = DocumentOperations.ConversionOptions(
            formats: ["rtf"], headers: false, toc: true, inlineStyling: false, pictures: .export,
            pageNumbers: .on, sentenceSpacing: .single)
        let whole = DocumentOperations.ConversionOptions(formats: ["rtf"], choices: choices)
        #expect(single.choices == choices)
        #expect(whole.choices == choices)
        #expect(whole.headers == false && whole.toc && !whole.inlineStyling)
        #expect(whole.pictures == .export && whole.pageNumbers == .on && whole.sentenceSpacing == .single)
    }

    @Test func settingAFieldChangesTheChoices() {
        var options = DocumentOperations.ConversionOptions(formats: ["text"])
        #expect(options.choices == ExportChoices())
        options.toc = true
        options.pageNumbers = .off
        #expect(options.choices == ExportChoices(toc: true, pageNumbers: .off))
    }

    @Test func theChoicesReachTheEmittersOfAConversion() throws {
        let bytes = Array("Hello world.\r\n".utf8)
        let plain = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["text", "rtf"], choices: ExportChoices()))
        #expect(plain.map(\.format) == ["text", "rtf"])
        #expect(plain.allSatisfy { !$0.bytes.isEmpty })
        // The same bytes the choice-free defaults give: ExportChoices() is the old default.
        let bare = try DocumentOperations.convert(data: bytes, options: .init(formats: ["text", "rtf"]))
        #expect(plain.map(\.bytes) == bare.map(\.bytes))
    }
}
