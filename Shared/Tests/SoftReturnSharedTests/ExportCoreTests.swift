import CtrlKD
import Foundation
import Testing
@testable import SoftReturnShared

/// The export loop both apps run: which formats reach the library's emitters, which reach the
/// platform's PDF, and what options each is given.
@Suite @MainActor struct ExportCoreTests {
    static func state(_ text: String = "Hello world.  Second sentence.\r\n") throws -> (DocumentState, UserDefaults, String) {
        let suite = "ExportCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = try DocumentState(data: Array(text.utf8), settings: SettingsStore(defaults: defaults))
        return (state, defaults, suite)
    }

    /// Records every call the platform PDF closure receives.
    final class PDFProbe {
        var calls: [(style: RenderStyle?, options: EmitOptions)] = []
        func callAsFunction(_ style: RenderStyle?, _ options: EmitOptions) -> [UInt8] {
            calls.append((style, options))
            return Array("%PDF-probe".utf8)
        }
    }

    @Test func fourFormatsGoToTheLibraryAndNeverAskThePlatformForPDF() throws {
        let (state, defaults, suite) = try Self.state()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = PDFProbe()
        let products = try ExportCore.render(
            document: state.document, state: state, formats: [.text, .markdown, .html, .rtf],
            notes: NoteSelection(), choices: ExportChoices(), pagesPDF: { try probe($0, $1) })
        #expect(products.map(\.format) == [.text, .markdown, .html, .rtf])
        #expect(products.allSatisfy { !$0.bytes.isEmpty })
        #expect(probe.calls.isEmpty)
        let text = String(decoding: try #require(products.first).bytes, as: UTF8.self)
        #expect(text.contains("Hello world."))
    }

    /// The document as the window shows it is what exports (planning #573): a variant forced in the window reaches
    /// the file, where re-parsing the bytes would detect the variant again. The quirks in force ride the same
    /// document (`DocumentState.document` is the parse with them applied).
    @Test func aForcedVariantReachesTheExport() throws {
        var bytes = Array("Hell".utf8)
        bytes.append(0xEF)
        bytes += Array(" world.\r\n".utf8)
        let suite = "ExportCoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        let detected = state.variant.value
        let forced: Variant = detected == .text ? .ws4 : .text
        #expect(state.setVariant(forced) == nil)

        let products = try ExportCore.render(
            document: state.document, state: state, formats: [.text], notes: NoteSelection(),
            choices: ExportChoices(), pagesPDF: { _, _ in [] })
        let exported = try #require(products.first).bytes
        let mode = state.style.value.renderStyle.emitMode
        let options = NoteSelection().emitOptions(pageSettings: state.pageSettingsPreset.value?.settings)
        let asShown = try #require(EmitterRegistry.standard.getEmitter("text")).emit(state.document, mode, options).asBytes
        let reparsed = try convertData(bytes, to: "text", mode: mode, options: options)
        #expect(asShown != reparsed, "the test bytes read the same as \(detected) and \(forced)")
        #expect(exported == asShown)
    }

    @Test func aModernPDFIsThePlatformsAndGetsTheStyleAsPassed() throws {
        let (state, defaults, suite) = try Self.state()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = PDFProbe()
        let products = try ExportCore.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .modern, choices: ExportChoices(), pagesPDF: { try probe($0, $1) })
        #expect(products.first?.bytes == Array("%PDF-probe".utf8))
        #expect(probe.calls.map(\.style) == [.modern])
    }

    @Test func aPrintedPDFIsTheLibrarysUnlessTheViewIsNative() throws {
        let (state, defaults, suite) = try Self.state()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = PDFProbe()
        let library = try ExportCore.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .native, choices: ExportChoices(), pagesPDF: { try probe($0, $1) })
        #expect(probe.calls.isEmpty)
        #expect(String(decoding: try #require(library.first).bytes.prefix(5), as: UTF8.self) == "%PDF-")

        _ = try ExportCore.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .native, viewStyle: .native, choices: ExportChoices(), pagesPDF: { try probe($0, $1) })
        #expect(probe.calls.map(\.style) == [.native])
    }

    @Test func theChoicesReachThePlatformPDFAndTheNotesAndTitleRideAlong() throws {
        let (state, defaults, suite) = try Self.state()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = PDFProbe()
        let choices = ExportChoices(headers: false, toc: true, inlineStyling: false,
                                    pictures: .off, pageNumbers: .on, sentenceSpacing: .single)
        _ = try ExportCore.render(
            document: state.document, state: state, formats: [.pdf],
            notes: NoteSelection(comments: true), style: .modern, title: "PAPER",
            choices: choices, pagesPDF: { try probe($0, $1) })
        let options = try #require(probe.calls.first).options
        #expect(options.headers == false)
        #expect(options.toc == true)
        #expect(options.inlineStyling == false)
        #expect(options.pictures == .off)
        #expect(options.pageNumbers == .on)
        #expect(options.sentenceSpacing == .single)
        #expect(options.title == "PAPER")
        #expect(options.notes.contains(.comment))
        #expect(options.fontsTarget == .mac)
    }

    @Test func aFailingPlatformPDFFailsTheExport() throws {
        let (state, defaults, suite) = try Self.state()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(throws: ExportError.self) {
            try ExportCore.render(
                document: state.document, state: state, formats: [.text, .pdf], notes: NoteSelection(),
                style: .modern, choices: ExportChoices(), pagesPDF: { _, _ in throw ExportError.pdfContextUnavailable })
        }
    }

    @Test func noteSelectionNamesTheKindsAndStartsWithTheLibrarysDefaults() {
        #expect(NoteSelection().kinds == EmitOptions.defaultNotes)
        #expect(NoteSelection(footnotes: false, endnotes: false, annotations: false, comments: true).kinds == [.comment])
        #expect(NoteSelection().emitOptions().fontsTarget == .mac)
    }

    @Test func choicesStartAtTheRuledDefaultsAndFollowSettings() throws {
        #expect(ExportChoices() == ExportChoices(headers: true, toc: false, inlineStyling: true,
                                                 pictures: .embed, pageNumbers: .auto, sentenceSpacing: .auto))
        let suite = "ExportCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.defaultHeaders = false
        settings.defaultTOC = true
        settings.defaultPictures = .export
        settings.defaultPageNumbers = .off
        let choices = ExportChoices(settings: settings)
        #expect(choices == ExportChoices(headers: false, toc: true, inlineStyling: true,
                                         pictures: .export, pageNumbers: .off, sentenceSpacing: .auto))
    }

    @Test func errorsReadInPlainWords() {
        #expect(ExportError.pdfContextUnavailable.errorDescription == "Couldn’t create a PDF for this document.")
    }
}
