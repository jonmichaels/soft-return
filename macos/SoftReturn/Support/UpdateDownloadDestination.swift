import Foundation

/// Job 276: where the downloaded DMG ends up, and under what name. Split from
/// `GitHubAssetDownloader` (which only ever answers "here are the bytes, at this temp path") so
/// the naming rule is unit testable with no filesystem access at all, the same split
/// `BesideSourceWriter` and `DocumentOperations.uniqueFileName` already use elsewhere in this
/// app. Job 532: the version-named DMG path (`fileName(for:)`/`move`) served the in-app "Check
/// for Updates" download flow, retired in favor of Sparkle — removed as dead code alongside it.
/// `moveStableNamed`/`downloadsFolderURL` remain: `CLIHelpWindowController`'s installer-package
/// download (job-530's interim GitHub-releases checker) still uses both.
enum UpdateDownloadDestination {
    enum DestinationError: Error, LocalizedError {
        case downloadsFolderUnreachable(String)
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadsFolderUnreachable(let detail): return detail
            case .moveFailed(let detail): return detail
            }
        }
    }

    /// Job 313C: for an asset whose own name IS the stable identity (`Soft-Return-CLI.pkg` —
    /// unlike the DMG, a brew/curl recipe or a support instruction references this exact
    /// filename literally, so it must not be renamed per-version the way `fileName(for:)`
    /// renames the DMG). Same Finder-style "(2)" collision counter as the DMG path, just
    /// keyed off the asset's own name instead of a version string.
    @discardableResult
    static func moveStableNamed(
        _ tempURL: URL, assetName: String, downloadsFolder: URL = downloadsFolderURL()
    ) throws -> URL {
        let fileManager = FileManager.default
        let basename = (assetName as NSString).deletingPathExtension
        let ext = (assetName as NSString).pathExtension
        let name = DocumentOperations.uniqueFileName(basename: basename, extension: ext) { candidate in
            fileManager.fileExists(atPath: downloadsFolder.appendingPathComponent(candidate).path)
        }
        return try performMove(tempURL, to: downloadsFolder.appendingPathComponent(name))
    }

    private static func performMove(_ tempURL: URL, to destination: URL) throws -> URL {
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            throw DestinationError.moveFailed(error.localizedDescription)
        }
        return destination
    }

    /// Job 392: un-sandboxed, `FileManager.urls(for:in:)` with `.downloadsDirectory` resolves
    /// straight to the real, Finder-visible `~/Downloads` — no container, no symlink, no
    /// entitlement needed (job 152's container-redirect finding and job 280's symlink-grant
    /// entitlement both applied only to the sandboxed shape this app no longer has). The
    /// `homeDirectoryForCurrentUser` fallback below is unreachable in practice (the search-path
    /// API always resolves) — kept only because `.first` on an empty array is a real, if
    /// theoretical, possibility the type system doesn't rule out.
    static func downloadsFolderURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
