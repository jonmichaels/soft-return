/// Between-releases build metadata (Jon's ruling 2026-08-14: the banner shows
/// `sr 4.0.0 (dev YYYY-MM-DD)` on builds cut between releases, with the exact engine
/// commit only under `--version --verbose`; a real release cut shows the clean version
/// string — the absence of the suffix IS the release marker).
///
/// Both values are nil in this repo, always. The Soft Return app's build script
/// overwrites this file in its dependency checkout with the pinned engine commit's
/// date and hash before `swift build`, then restores it — real values are injected
/// at build time, never committed.
public let srDevDate: String? = nil
public let srDevHash: String? = nil
