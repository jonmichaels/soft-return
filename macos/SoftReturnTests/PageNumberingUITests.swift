import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 520 (N5, b33 page-numbering UI): `ExportEngine.render`'s new `pageNumbers` parameter
/// — the "per-export override reaching the engine call" half of the brief's own test list.
/// `AppKitRenderedPDFHonorsEmitOptionsTests` already covers headers/toc/pictures at this same
/// `ExportEngine.render` layer; `pageNumbers` is NOT covered there because that file exercises
/// `appKitRenderedPDF` (the Modern/Native-view PDF route), a documented gap this parameter
/// does not reach (see `ExportEngine.render`'s own doc comment) — it only reaches the
/// library's own literal-engine PDF writer, via `style: .printed` with no native `viewStyle`.
/// These tests drive `render` that way instead.
@Suite struct PageNumberingUITests {

    /// A synthetic WS4 document with page geometry but NO page-numbering dot command of its
    /// own — same shape as `AppKitRenderedPDFHonorsEmitOptionsTests`' own fixtures, duplicated
    /// here (file-local, per this codebase's own convention) rather than shared. Per the b33
    /// ruling ("auto: the document's own dot commands decide; if the document has no
    /// page-numbering dot command at all, numbering is OFF"), `.auto` and `.on` must
    /// therefore disagree on this fixture.
    private static func noDotCommandFixtureBytes() -> [UInt8] {
        func highBitWords(_ text: String) -> [UInt8] {
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
        let hard: [UInt8] = [0x0D, 0x0A]
        var doc: [UInt8] = []
        for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12"] {
            doc += Array(dot.utf8) + hard
        }
        doc += highBitWords("Body prose paragraph for content that runs on for a good while so "
            + "the text percentage and high bit density both clear detect's own thresholds safely.") + hard
        doc += [0x1A]
        return doc
    }

    @MainActor
    private static func noDotCommandState() throws -> DocumentState {
        let defaults = UserDefaults(suiteName: "PageNumberingUITests.\(UUID().uuidString)")!
        return try DocumentState(data: noDotCommandFixtureBytes(), settings: SettingsStore(defaults: defaults))
    }

    // MARK: - ExportEngine.render honors an explicit pageNumbers override

    @Test @MainActor func printedPDFPageNumbersOnDiffersFromAutoOnADocumentWithNoDotCommand() throws {
        let state = try Self.noDotCommandState()
        let on = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                         notes: NoteSelection(), style: .printed, pageNumbers: .on)
        let auto = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                           notes: NoteSelection(), style: .printed, pageNumbers: .auto)
        let message = "forcing page numbers ON on a document with no page-numbering dot command must "
            + "change the printed PDF's own bytes (per the b33 ruling: auto + no dot command == off)"
        #expect(try #require(on.first).bytes != (try #require(auto.first).bytes), "\(message)")
    }

    @Test @MainActor func printedPDFPageNumbersOffMatchesAutoOnADocumentWithNoDotCommand() throws {
        let state = try Self.noDotCommandState()
        let off = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                          notes: NoteSelection(), style: .printed, pageNumbers: .off)
        let auto = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                           notes: NoteSelection(), style: .printed, pageNumbers: .auto)
        let message = "per the b33 ruling, auto on a document with no page-numbering dot command must "
            + "behave identically to an explicit off"
        #expect(try #require(off.first).bytes == (try #require(auto.first).bytes), "\(message)")
    }

    // MARK: - Omitting pageNumbers falls back to Settings' own current default

    /// Same "omit everything, compare to `SettingsStore.shared`'s own current value" shape
    /// `AppKitRenderedPDFHonorsEmitOptionsTests.omittingEveryFlagMatchesWhateverSettingsCurrentlyReports`
    /// already established for headers/toc/inlineStyling/pictures — pinned here for
    /// `pageNumbers` specifically. Both calls omit every OTHER flag too, so this holds
    /// regardless of what `SettingsStore.shared`'s current values happen to be.
    @Test @MainActor func omittingPageNumbersMatchesWhateverSettingsCurrentlyReports() throws {
        let state = try Self.noDotCommandState()
        let implicit = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                               notes: NoteSelection(), style: .printed)
        let explicitFromSettings = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(), style: .printed,
            pageNumbers: SettingsStore.shared.defaultPageNumbers)
        #expect(try #require(implicit.first).bytes == (try #require(explicitFromSettings.first).bytes),
                "an export with pageNumbers omitted must match SettingsStore.shared's own current value")
    }

    @Test @MainActor func freshSettingsStoreDefaultsToAutoPageNumbers() throws {
        let defaults = UserDefaults(suiteName: "PageNumberingUITests.\(UUID().uuidString)")!
        let fresh = SettingsStore(defaults: defaults)
        #expect(fresh.defaultPageNumbers == .auto, "ruled default: Page Numbering Auto")
    }
}
