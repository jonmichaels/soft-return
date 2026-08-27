import CtrlKD
import Foundation

/// Turns `DocumentOperations.DiagnosisResult` into the `diagnosis` record
/// `SoftReturn.sdef` promises — the same translation
/// `DiagnoseWordStarDocumentIntent`/`WordStarDiagnosis` already does for Shortcuts, one
/// level further: "comments present" and "margins" read `DiagnosisResult.info` the same
/// way `documentInfo`'s own doc comment describes its `notes`/`page` fields (Info.swift),
/// rather than re-deriving them from the parsed document — `diagnose` never re-parses,
/// it only re-shapes what `DocumentOperations.diagnose` already computed.
enum DiagnosisScripting {
    static func record(from result: DocumentOperations.DiagnosisResult) -> [String: Any] {
        var record: [String: Any] = [
            "dotCommands": result.dotCommands,
            "unknownCodes": result.unknownCodeCount,
            "commentsPresent": commentsPresent(in: result.info),
        ]
        // `.binary` has no enumerator in the ruled `variant` enumeration (ws4/ws5plus/
        // printstream/text only — forcing "not convertible" was never offered even by
        // the CLI's own `--variant`) — the field is simply absent (AppleScript's
        // `missing value`) rather than carrying a made-up code.
        if let code = ScriptingEnumCoding.code(for: result.variant) {
            record["variant"] = NSNumber(value: code)
        }
        if let pages = result.pageCount {
            record["pages"] = pages
        }
        if let margins = margins(in: result.info) {
            record["margins"] = PageSettingsScripting.record(from: margins)
        }
        return record
    }

    /// The reply-packagable form: `SoftReturn.sdef`'s `diagnosis` record-type (code `SRrd`,
    /// lines 395-416) — `variant`/`SRd1` (enum, absent for `.binary`), `pages`/`SRd2`
    /// (integer, absent only when the bytes didn't parse at all), `dot commands`/`SRd3` (text
    /// list, file order), `unknown codes`/`SRd4` (integer), `comments present`/`SRd5`
    /// (boolean), `margins`/`SRd6` (nested `page settings` record, absent when the info has
    /// none). Job 207: `record(from:)` above stays a plain `[String: Any]`; see
    /// `ScriptingRecordBuilder`'s own doc comment for why a command's reply needs an actual
    /// typed descriptor instead.
    static func descriptor(from result: DocumentOperations.DiagnosisResult) -> NSAppleEventDescriptor {
        var properties: [(code: String, value: NSAppleEventDescriptor)] = [
            (code: "SRd3", value: ScriptingRecordBuilder.list(result.dotCommands.map { NSAppleEventDescriptor(string: $0) })),
            (code: "SRd4", value: NSAppleEventDescriptor(int32: Int32(result.unknownCodeCount))),
            (code: "SRd5", value: NSAppleEventDescriptor(boolean: commentsPresent(in: result.info))),
        ]
        if let code = ScriptingEnumCoding.code(for: result.variant) {
            properties.append((code: "SRd1", value: NSAppleEventDescriptor(enumCode: code)))
        }
        if let pages = result.pageCount {
            properties.append((code: "SRd2", value: NSAppleEventDescriptor(int32: Int32(pages))))
        }
        if let margins = margins(in: result.info) {
            properties.append((code: "SRd6", value: PageSettingsScripting.descriptor(from: margins)))
        }
        return ScriptingRecordBuilder.record(code: "SRrd", properties: properties)
    }

    private static func commentsPresent(in info: InfoValue) -> Bool {
        guard case .object(let fields) = info,
              case .object(let notes)? = fields["notes"],
              case .int(let count)? = notes["comment"]
        else { return false }
        return count > 0
    }

    private static func margins(in info: InfoValue) -> PageSettings? {
        guard case .object(let fields) = info, case .object(let page)? = fields["page"] else {
            return nil
        }
        func double(_ key: String) -> Double? {
            guard case .double(let v)? = page[key] else { return nil }
            return v
        }
        return PageSettings(
            mtLines: double("mt_lines"), mbLines: double("mb_lines"),
            poCols: double("po_cols"), hmLines: double("hm_lines"),
            fmLines: double("fm_lines"), plLines: double("pl_lines"))
    }
}
