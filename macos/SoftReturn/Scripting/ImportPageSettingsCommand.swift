import CtrlKD
import Foundation

/// `import page settings from POSIX file "..."` — `SoftReturn.sdef`'s `import page
/// settings` command. The WSCHANGE `.PAT` interpreter (`CtrlKD.parsePAT`/
/// `patPageSettings`, library-only until now — "no CLI wiring until real import cases
/// appear") gets its first real caller here, wrapped by `PageSettingsScripting
/// .importPageSettings(from:)` rather than re-implemented.
final class ImportPageSettingsCommand: NSScriptCommand {
    enum DecodeError: Error, LocalizedError {
        case missingSource
        case unreadableFile(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .missingSource: return "import page settings needs a file (\"from\")."
            case .unreadableFile(let url, let underlying):
                return "Couldn't read \(url.path): \(underlying.localizedDescription)"
            }
        }
    }

    /// `SoftReturn.sdef`'s `import page settings` command now declares `<result type="text">`
    /// (job 216, was the custom `page settings` record — see `DiagnoseCommand`'s doc comment
    /// for the job-207 defect this also replaces, and `PageSettingsScripting.infoValue(from:)`
    /// for the compositional tradeoff this shape change carries, flagged for Jon's ruling).
    override func performDefaultImplementation() -> Any? {
        do {
            guard let raw = evaluatedArguments?["scriptingSource"] else {
                throw DecodeError.missingSource
            }
            let url = try ScriptingFileArgument.url(from: raw)
            let data: Data
            do {
                data = try ScriptingFileArgument.readData(at: url)
            } catch {
                throw DecodeError.unreadableFile(url, underlying: error)
            }
            let settings = try PageSettingsScripting.importPageSettings(from: [UInt8](data))
            return ScriptingJSONRendering.render(PageSettingsScripting.infoValue(from: settings))
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
