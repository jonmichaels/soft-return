import CtrlKD
import Foundation

/// Bridges `CtrlKD.PageSettings` to and from AppleScript's `page settings` record, and
/// resolves the polymorphic `page settings` parameter `export`/`convert` share (a named
/// `settings preset` enumerator OR a `page settings` record — `SoftReturn.sdef`'s
/// alternating `<type>` declarations on that parameter) into one `PageSettings`.
///
/// Pure, `DocumentOperations`-free translation: the actual preset VALUES
/// (`DocumentOperations.PageSettingsPreset.settings`) and the `.PAT` interpreter
/// (`CtrlKD.parsePAT`/`patPageSettings`) already live in the shared layer / the library —
/// this only decides which of those a given Apple Event argument means.
enum PageSettingsScripting {

    // MARK: - PageSettings <-> record

    /// Only non-`nil` fields appear — an absent key in a `page settings` record means "the
    /// document's own dot command wins," exactly as an absent field in `PageSettings` does.
    static func record(from settings: PageSettings) -> [String: Any] {
        var record: [String: Any] = [:]
        if let v = settings.mtLines { record["marginTop"] = v }
        if let v = settings.mbLines { record["marginBottom"] = v }
        if let v = settings.poCols { record["pageOffset"] = v }
        if let v = settings.hmLines { record["headerMargin"] = v }
        if let v = settings.fmLines { record["footerMargin"] = v }
        if let v = settings.plLines { record["pageLength"] = v }
        return record
    }

    /// The reply-packagable form: `SoftReturn.sdef`'s `page settings` record-type (code
    /// `SRrp`, lines 360-380) — `margin top`/`SRr1`, `margin bottom`/`SRr2`, `page offset`/
    /// `SRr3`, `header margin`/`SRr4`, `footer margin`/`SRr5`, `page length`/`SRr6`, all
    /// `real`. Job 207: `diagnosis`'s nested `margins` property needs this (the outer
    /// `diagnosis` record was itself replaced by job 216 — see `DiagnoseCommand`'s own doc
    /// comment — but the record-type declaration stays in the sdef, and `margins` there is
    /// only ever read via `forKeyword`, in-process, by `DiagnoseAndImportPageSettingsCommandTests`
    /// and `DiagnosisScriptingTests`, never packaged as a top-level command reply); see
    /// `ScriptingRecordBuilder`'s own doc comment for why a top-level reply needs an actual
    /// typed descriptor instead of a plain dictionary. `import page settings`'s OWN reply no
    /// longer uses this — see `infoValue(from:)` below.
    static func descriptor(from settings: PageSettings) -> NSAppleEventDescriptor {
        var properties: [(code: String, value: NSAppleEventDescriptor)] = []
        if let v = settings.mtLines { properties.append((code: "SRr1", value: NSAppleEventDescriptor(double: v))) }
        if let v = settings.mbLines { properties.append((code: "SRr2", value: NSAppleEventDescriptor(double: v))) }
        if let v = settings.poCols { properties.append((code: "SRr3", value: NSAppleEventDescriptor(double: v))) }
        if let v = settings.hmLines { properties.append((code: "SRr4", value: NSAppleEventDescriptor(double: v))) }
        if let v = settings.fmLines { properties.append((code: "SRr5", value: NSAppleEventDescriptor(double: v))) }
        if let v = settings.plLines { properties.append((code: "SRr6", value: NSAppleEventDescriptor(double: v))) }
        return ScriptingRecordBuilder.record(code: "SRrp", properties: properties)
    }

    /// Job 216: `import page settings`'s reply shape — `SoftReturn.sdef`'s `import page
    /// settings` command now declares `<result type="text">` (was the custom `page
    /// settings` record; see `DiagnoseCommand`'s doc comment for why). The same field names
    /// `DiagnosisScripting.margins(in:)` reads out of a diagnose `InfoValue` tree
    /// (`mt_lines`/`mb_lines`/`po_cols`/`hm_lines`/`fm_lines`/`pl_lines`) — reusing them here
    /// keeps one vocabulary for "page geometry as JSON" across both commands. Only present
    /// fields appear, same "absent key = untouched" contract `record(from:)`/`descriptor(from:)`
    /// already keep — JSON key omission is what "absent" looks like here.
    ///
    /// **Compositional regression, flagged for Jon's ruling (see the job report):** the OLD
    /// `page settings` record result could be fed straight back into `export`/`convert`'s own
    /// `page settings` parameter (`{margin top: ..., ...}` inline, or a variable holding this
    /// command's result — the sdef's own `page settings` parameter description says exactly
    /// that: "e.g. from import page settings"). A text/JSON result cannot be fed back the
    /// same way; a script would need to parse it (`run script` a hand-built AppleScript
    /// `{...}` literal string, or similar) to reconstruct a record before passing it on. No
    /// Cocoa-provable shape considered (custom record: banned by job 207/216's own finding;
    /// a fixed-position `real` list: loses field names AND still can't feed the `page
    /// settings` parameter directly; a specifier: no addressable scripting object exists for
    /// page geometry to specify) preserves the old direct-feed ergonomic — this is a real
    /// product-level tradeoff, not an implementation detail.
    static func infoValue(from settings: PageSettings) -> InfoValue {
        var fields: [String: InfoValue] = [:]
        if let v = settings.mtLines { fields["mt_lines"] = .double(v) }
        if let v = settings.mbLines { fields["mb_lines"] = .double(v) }
        if let v = settings.poCols { fields["po_cols"] = .double(v) }
        if let v = settings.hmLines { fields["hm_lines"] = .double(v) }
        if let v = settings.fmLines { fields["fm_lines"] = .double(v) }
        if let v = settings.plLines { fields["pl_lines"] = .double(v) }
        return .object(fields)
    }

    /// Job 504: `--page-settings size=letter|legal|a4` (`Arguments.swift`'s `sizes` dict,
    /// SoftReturnCLI — a different SPM module the app cannot import) in lines at 6 LPI.
    /// Copied verbatim rather than re-derived: `letter`/`legal` match `namedPageSizes`'
    /// (`ParseWS.swift`, private to CtrlKD) own `heightIn * 6` exactly, and `a4`'s 11.693in
    /// is the library's own snapped constant, not a value this file invented. Same
    /// literal-duplication shape `DocumentOperations.PageSettingsPreset.settings` already
    /// uses for the `sawyer`/`modern` presets, for the identical reason (no shared module
    /// between the CLI target and this app to hang a single source of truth off of).
    static let paperSizePlLines: [NamedPageSize: Double] = [
        .usLetter: 66.0, .usLegal: 84.0, .a4: 11.693 * 6,
    ]

    /// Reads whichever of the seven keys are present; a `page settings` record built by
    /// hand in a script may set only one or two. Job 504: `paperSize` sets `plLines` via
    /// `paperSizePlLines` — an explicit `pageLength` in the same record wins if both are
    /// given (sdef precedence rule), so `paperSize` is resolved first and then
    /// unconditionally overwritten when `pageLength` is also present.
    static func pageSettings(fromRecord record: [String: Any]) -> PageSettings {
        func double(_ key: String) -> Double? {
            (record[key] as? NSNumber)?.doubleValue
        }
        var plLines: Double?
        if let paperSizeNumber = record["paperSize"] as? NSNumber,
           let named = ScriptingEnumCoding.pageSize(forCode: paperSizeNumber.uint32Value) {
            plLines = paperSizePlLines[named]
        }
        if let explicit = double("pageLength") {
            plLines = explicit
        }
        return PageSettings(
            mtLines: double("marginTop"), mbLines: double("marginBottom"),
            poCols: double("pageOffset"), hmLines: double("headerMargin"),
            fmLines: double("footerMargin"), plLines: plLines)
    }

    // MARK: - The `page settings` parameter (preset code, record, or absent)

    /// `raw` is whatever Cocoa Scripting handed the command for the `page settings`
    /// argument: an `NSNumber` wrapping a `settings preset` enumerator's four-char code,
    /// an `NSDictionary`/`[String: Any]` record (a literal in the script, or the result of
    /// `import page settings`), or `nil` when the parameter was omitted.
    static func resolve(_ raw: Any?) -> PageSettings? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber,
           let preset = ScriptingEnumCoding.settingsPreset(forCode: number.uint32Value) {
            return preset.settings
        }
        if let dict = raw as? [String: Any] {
            return pageSettings(fromRecord: dict)
        }
        if let dict = raw as? NSDictionary {
            var converted: [String: Any] = [:]
            for (key, value) in dict {
                if let key = key as? String { converted[key] = value }
            }
            return pageSettings(fromRecord: converted)
        }
        return nil
    }

    // MARK: - `import page settings from ...`

    enum ImportError: Error, LocalizedError {
        case notAPATFile(String)

        var errorDescription: String? {
            switch self {
            case .notAPATFile(let message):
                return "Not a WSCHANGE .PAT file: \(message)"
            }
        }
    }

    /// `patPageSettings`'s keys (`mt_lines`/`mb_lines`/`pl_lines`/`hm_lines`/`fm_lines`/
    /// `po_cols`) reassembled into `PageSettings` — a dump with no `INIEDT` label returns
    /// `[:]`, which becomes an all-`nil` `PageSettings` ("this machine says nothing about
    /// page geometry"), not an error.
    static func importPageSettings(from data: [UInt8]) throws -> PageSettings {
        let pat: [String: [UInt8]]
        do {
            pat = try parsePAT(data)
        } catch let error as PATError {
            throw ImportError.notAPATFile(error.message)
        }
        let fields = patPageSettings(pat)
        return PageSettings(
            mtLines: fields["mt_lines"], mbLines: fields["mb_lines"],
            poCols: fields["po_cols"], hmLines: fields["hm_lines"],
            fmLines: fields["fm_lines"], plLines: fields["pl_lines"])
    }
}
