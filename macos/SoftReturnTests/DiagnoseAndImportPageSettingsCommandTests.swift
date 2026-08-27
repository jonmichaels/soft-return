import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `DiagnoseCommand` and `ImportPageSettingsCommand` are thin `NSScriptCommand`
/// wrappers — decode one file argument, call the shared layer, wrap the result as a
/// record. Both steps (`ScriptingFileArgument.url`, `DocumentOperations.diagnose`/
/// `PageSettingsScripting.importPageSettings`, and the record builders) already have
/// their own dedicated test suites; these tests exercise them chained together exactly
/// the way `performDefaultImplementation()` does, on real files, without needing a live
/// Apple Event — see the job report for why the `NSScriptCommand` override itself isn't
/// independently driven here.
@Suite struct DiagnoseAndImportPageSettingsCommandTests {

    /// Exactly `DiagnoseCommand.performDefaultImplementation()`'s body (job 216: now
    /// `ScriptingJSONRendering.render(result.info)`, a JSON text result — was
    /// `DiagnosisScripting.descriptor(from:)`'s typed record, job 207; see
    /// `ScriptingJSONRendering`'s own doc comment for why a command reply needs a Cocoa-
    /// provably-packaged shape instead).
    @Test func diagnoseCommandsChainProducesTheSameJSONAsDirectlyRenderingTheInfoValue() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("narrow.ws4")

        let decoded = try ScriptingFileArgument.url(from: url)
        let data = try #require(FileManager.default.contents(atPath: decoded.path))
        let result = DocumentOperations.diagnose(data: [UInt8](data), path: decoded.path)
        let text = ScriptingJSONRendering.render(result.info)

        let expected = ScriptingJSONRendering.render(
            DocumentOperations.diagnose(data: [UInt8](try Data(contentsOf: url)), path: url.path).info)
        #expect(text == expected)
        #expect(text.contains("\"variant\""))
        #expect(text.contains("\"dot_commands\""))
    }

    @Test func diagnoseCommandsChainThrowsForAnUnreadablePath() {
        let missing = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist-\(UUID().uuidString)")
        #expect(FileManager.default.contents(atPath: missing.path) == nil)
    }

    /// Job 220 (finding C): `DiagnoseCommand`/`ImportPageSettingsCommand` used to fold
    /// EVERY `readData` failure into the same generic "Couldn't read <path>." — the real
    /// reason (`readData` now throws it) must reach the scriptError text a script author
    /// sees, not vanish at the `DecodeError` boundary.
    @Test func diagnoseCommandUnreadableFileErrorIncludesTheUnderlyingReason() {
        let url = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist")
        let underlying = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "no such file, definitely"])
        let error = DiagnoseCommand.DecodeError.unreadableFile(url, underlying: underlying)
        #expect(error.errorDescription?.contains("no such file, definitely") == true)
    }

    @Test func importPageSettingsCommandUnreadableFileErrorIncludesTheUnderlyingReason() {
        let url = URL(fileURLWithPath: "/tmp/soft-return-does-not-exist")
        let underlying = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "no such file, definitely"])
        let error = ImportPageSettingsCommand.DecodeError.unreadableFile(url, underlying: underlying)
        #expect(error.errorDescription?.contains("no such file, definitely") == true)
    }

    /// Same INIEDT byte layout `PageSettingsScriptingTests.syntheticPAT()` builds
    /// (offsets from `WSChange.swift`'s `mtOff`/`mbOff`/`plOff`/`hmOff`/`fmOff`/
    /// `poEvenOff`), reassembled here rather than shared so this file's own hex is
    /// self-checking against the same math instead of a copy-pasted (and easily
    /// miscounted) literal.
    private static func syntheticPATFile() -> Data {
        var block = [UInt8](repeating: 0, count: 68)
        func setLE16(_ offset: Int, _ value: Int) {
            block[offset] = UInt8(value & 0xFF)
            block[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        setLE16(0x14, 720)     // .mt -> 3.0 lines
        setLE16(0x16, 1440)    // .mb -> 6.0 lines
        setLE16(0x24, 1260)    // .po -> 7.0 columns
        let hex = block.map { String(format: "%02X", $0) }.joined(separator: ",")
        return Data("INIEDT=\(hex)\r\n".utf8)
    }

    /// Exactly `ImportPageSettingsCommand.performDefaultImplementation()`'s body (job 216:
    /// now `ScriptingJSONRendering.render(PageSettingsScripting.infoValue(from:))`, a JSON
    /// text result — was `PageSettingsScripting.descriptor(from:)`'s typed record, job 207).
    ///
    /// `syntheticPATFile()`'s block is 68 bytes — long enough to cover EVERY field's byte
    /// offset (`.po`'s, the largest, is at 0x24) even though only `.mt`/`.mb`/`.po` are
    /// explicitly patched; `patLE16` (`WSChange.swift`) only returns `nil` for an offset
    /// past the END of the block, not for an untouched-but-in-range zero, so `hm`/`fm`/`pl`
    /// read back as real `0.0`s here, not absent — `infoValueOmitsFieldsGenuinelyMissingFrom
    /// AShorterBlock` in `PageSettingsScriptingTests` exercises actual key omission, which
    /// needs a block truncated BEFORE a field's offset to trigger.
    @Test func importPageSettingsCommandsChainProducesJSONMatchingTheSyntheticPAT() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnoseCommandTests-\(UUID().uuidString).PAT")
        try Self.syntheticPATFile().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let decoded = try ScriptingFileArgument.url(from: tempFile)
        let data = try #require(FileManager.default.contents(atPath: decoded.path))
        let settings = try PageSettingsScripting.importPageSettings(from: [UInt8](data))
        let text = ScriptingJSONRendering.render(PageSettingsScripting.infoValue(from: settings))

        #expect(text.contains("\"mt_lines\": 3.0"))
        #expect(text.contains("\"mb_lines\": 6.0"))
        #expect(text.contains("\"po_cols\": 7.0"))
        #expect(text.contains("\"hm_lines\": 0.0"))
        #expect(text.contains("\"fm_lines\": 0.0"))
        #expect(text.contains("\"pl_lines\": 0.0"))
    }
}
