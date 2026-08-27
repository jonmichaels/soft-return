import CtrlKD
import Foundation

/// `diagnose POSIX file "..."` — `SoftReturn.sdef`'s `diagnose` command. The CLI's
/// `--diagnose`, as an AppleScript record instead of JSON; never throws for a bad file,
/// same as `DocumentOperations.diagnose` itself and `DiagnoseWordStarDocumentIntent` —
/// diagnosis is exactly the operation that must say something about a file `export`/
/// `convert` would refuse.
final class DiagnoseCommand: NSScriptCommand {
    enum DecodeError: Error, LocalizedError {
        case missingFile
        case unreadableFile(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .missingFile: return "diagnose needs a file."
            case .unreadableFile(let url, let underlying):
                return "Couldn't read \(url.path): \(underlying.localizedDescription)"
            }
        }
    }

    /// `SoftReturn.sdef`'s `diagnose` command now declares `<result type="text">` (job 216,
    /// was the custom `diagnosis` record — see `SoftReturn.sdef`'s comment on that
    /// record-type, and `ConvertCommand.performDefaultImplementation`'s doc comment, for the
    /// same job-207 defect this also replaces). `result.info` is exactly the `InfoValue`
    /// tree `sr --diagnose` renders — `ScriptingJSONRendering.render` reproduces that CLI's
    /// documented rendering shape (sorted keys, two-space indent) so this command's text
    /// result IS the CLI's own `--diagnose` output, not a new ad hoc shape.
    override func performDefaultImplementation() -> Any? {
        do {
            guard let raw = directParameter else { throw DecodeError.missingFile }
            let url = try ScriptingFileArgument.url(from: raw)
            let data: Data
            do {
                data = try ScriptingFileArgument.readData(at: url)
            } catch {
                throw DecodeError.unreadableFile(url, underlying: error)
            }
            let result = DocumentOperations.diagnose(data: [UInt8](data), path: url.path)
            return ScriptingJSONRendering.render(result.info)
        } catch {
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
