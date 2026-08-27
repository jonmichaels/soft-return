import Foundation
import Testing
@testable import SoftReturn

// MARK: - Real, unsandboxed filesystem behavior (job 392: verify the win empirically, don't assume)

/// Job 392: un-sandboxed, `downloadsFolderURL()` resolves directly to the real, Finder-visible
/// `~/Downloads` — no container, no symlink, no entitlement. Before this job (job 276/280),
/// this same probe resolved a sandbox container path and needed a symlink-grant entitlement
/// just to reach the real folder at all (`EPERM` without it) — see git history for that shape.
/// This checks the plain, unsandboxed reality: the resolved URL IS the real `~/Downloads`
/// (never a `Containers` path, no symlink indirection to resolve), and a plain write there
/// succeeds with no bookmark, no security scope, no entitlement in play.
@Test func downloadsFolderResolvesToTheRealDownloadsAndIsPlainlyWritable() throws {
    let resolved = UpdateDownloadDestination.downloadsFolderURL()
    #expect(!resolved.path.contains("/Library/Containers/"),
            "un-sandboxed, this must be the real Downloads, never a container path")
    #expect(resolved.path.hasSuffix("/Downloads"))

    let probeURL = resolved.appendingPathComponent("SoftReturnTests-DownloadsProbe-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: probeURL) }

    try Data("probe".utf8).write(to: probeURL)
    #expect(FileManager.default.fileExists(atPath: probeURL.path))
}
