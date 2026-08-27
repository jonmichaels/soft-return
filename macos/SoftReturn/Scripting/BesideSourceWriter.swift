import Foundation

/// Writes convert/export output beside its source file, under the source's own base name
/// with a new extension.
///
/// Jon's ruling (2026-08-12, field proof: bare convert of a Dropbox file silently landed in
/// `~/Library/Containers/.../Documents/`, back when this app was sandboxed and beside-source
/// writes needed `NSFilePresenter`/`NSFileCoordinator` to reach a sibling at all): a silent
/// divert somewhere else on collision is never acceptable.
///
/// **Superseded, job 504 (2026-08-25), Jon's ruling verbatim: "AppleScript overwrite should
/// handle it like a Mac would: add a ' 2' to the end of the filename (before extension)."**
/// Job 261 (`related-items-write`) had ruled a collision here must be a clean, honest FAILURE
/// instead — never a uniqued name — because `Info.plist`'s `NSIsRelatedItemType` entries only
/// match the exact base-name-plus-extension shape, so a uniqued sibling like `OLDTIMES 2.rtf`
/// silently stops being recognized as related to its source. Job 504's ruling is explicit and
/// later: a collision now writes the Finder-style uniqued name instead of failing. The
/// job-261 tradeoff still applies to that renamed file specifically (only the FIRST
/// export/convert of a given source is Quick Look-related; a re-run that collides produces a
/// numbered sibling that Quick Look's Related Items will not associate with its source) — an
/// accepted, known consequence of this ruling, not an oversight.
enum BesideSourceWriter {
    enum WriteError: Error, LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let detail): return detail
            }
        }
    }

    /// Job 261 (`related-items-write`): the sibling's URL, derived the same way
    /// `Info.plist`'s `NSIsRelatedItemType` entries expect it —
    /// `source.deletingPathExtension().appendingPathExtension(ext)`, same base name, new
    /// extension. Still the FIRST name tried — see the type's own doc comment for what
    /// happens on collision now.
    static func relatedItemURL(besideSource source: URL, extension ext: String) -> URL {
        source.deletingPathExtension().appendingPathExtension(ext)
    }

    /// Writes `data` beside `source`, preferring the exact related-item name
    /// (`relatedItemURL(besideSource:extension:)`); job 504: on collision, reuses
    /// `DocumentOperations.uniqueFileName`'s Finder-style " 2"/" 3"/... counter instead of
    /// failing (see the type's own doc comment for the ruling this supersedes). Throws
    /// `.writeFailed` when the disk write itself fails (out of space, a permissions error,
    /// a parent directory that doesn't exist).
    @discardableResult
    static func write(_ data: Data, besideSource source: URL, extension ext: String) throws -> URL {
        let related = relatedItemURL(besideSource: source, extension: ext)
        let destination: URL
        if FileManager.default.fileExists(atPath: related.path) {
            let directory = related.deletingLastPathComponent()
            let basename = related.deletingPathExtension().lastPathComponent
            let name = DocumentOperations.uniqueFileName(basename: basename, extension: ext) { candidate in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
            }
            destination = directory.appendingPathComponent(name)
        } else {
            destination = related
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
        return destination
    }
}
