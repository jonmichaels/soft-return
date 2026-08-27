import Foundation

/// Job 374 (b24, RELEASE-ASSET COMPLETENESS GATE): the single source of truth for "what must
/// exist on a published release for this app's own in-app download paths to work" —
/// `CLIHelpWindowController`'s pkg download button and `UpdateChecker`'s DMG/CLI asset
/// matching (`GitHubUpdateFeed.parse`) both already encode these same two requirements
/// independently; this type exists so a THIRD place (the release-time completeness check,
/// `Scripts/verify-release-assets.py`) has one thing to read instead of re-deriving the rules
/// from those call sites by hand. `docs/RUNBOOK.md`'s release chain runs that script before
/// undraft — see its own "Release-asset completeness gate" step.
enum ReleaseAssets {
    /// A single release-asset requirement: either an EXACT filename (case-insensitive, same
    /// comparison `GitHubUpdateFeed.parse` already uses for the CLI pkg) or a filename
    /// SUFFIX/pattern (the DMG, whose real name always carries the version — see
    /// `UpdateChecker.swift`'s own `hasSuffix(".dmg")` match — so no exact literal exists to
    /// check against).
    enum Requirement: Equatable {
        case exactFilename(String)
        case filenameSuffix(String)

        /// A human-readable description of what's missing, for a failing gate's own error text.
        var describedRequirement: String {
            switch self {
            case .exactFilename(let name): return name
            case .filenameSuffix(let suffix): return "an asset ending in \"\(suffix)\""
            }
        }

        func isSatisfied(by assetNames: [String]) -> Bool {
            switch self {
            case .exactFilename(let name):
                return assetNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case .filenameSuffix(let suffix):
                return assetNames.contains { $0.lowercased().hasSuffix(suffix.lowercased()) }
            }
        }
    }

    /// Every asset a published release must carry. Read directly off the app's own real call
    /// sites — `CLIHelpWindowController.installerPackageFilename` — rather than a second copy
    /// of the string, so this list cannot silently drift from what the app actually looks for.
    static let requirements: [Requirement] = [
        .exactFilename(CLIHelpWindowController.installerPackageFilename),
        .filenameSuffix(".dmg"),
    ]

    /// `requirements` not satisfied by `assetNames` (a release's real asset-name list), each as
    /// its own `describedRequirement` — empty means the release is complete. Pure and
    /// synchronous: fetching the real asset list (a GitHub API call) is the CALLER's job, kept
    /// out of this type the same way `UpdateFeedError`/`GitHubUpdateFeed` already separate
    /// "decide" from "fetch" — see `UpdateChecker.swift`.
    static func missingRequirements(assetNames: [String]) -> [String] {
        requirements
            .filter { !$0.isSatisfied(by: assetNames) }
            .map(\.describedRequirement)
    }
}
