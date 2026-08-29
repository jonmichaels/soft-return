import Foundation

/// Parses `sr --version --verbose`'s stdout into the pieces the About window's Engine and
/// Commit rows need (job 323, b20 item 6).
///
/// `--verbose` and the dev-date/commit stamp ARE real, wired by `Scripts/build-sr-cli.sh`
/// (Jon's ruling 2026-08-14, b19): before every build it injects the pinned SPM checkout's
/// own `git log`/`rev-parse` values into the engine's `DevStamp.swift` (restored after), so
/// `sr --version --verbose` reads `sr v4.0.0 (dev 2026-08-15)` then a line
/// `engine commit <hash>` on any build with real checkout git metadata — which is every
/// build this app produces. A release cut's `DevStamp.swift` stays committed as nils (the
/// script's own fallback when the checkout has no git info), giving the clean `sr v4.0.0`
/// banner with no commit line — THAT shape is what a real release build's About window
/// shows; this parser handles both, off literal fixtures in tests since a hosted dev build
/// can only ever produce the dev shape live (see
/// `AboutWindowControllerTests.realBundledSRSpawnSucceedsUnderSandboxAndParsesTheBanner`,
/// which drives the real binary and corrects an earlier, wrong assumption that `--verbose`
/// didn't exist yet — made off a stale standalone engine clone and an old prebuilt app's
/// `strings` output, neither of which reflected the checkout this build actually resolves).
///
/// The cross-product `(ctrl-kd parity X.Y.Z)` clause this parser used to require was REMOVED
/// from the banner itself (ruling 24, Jon 2026-08-28: it went stale the day ctrl-kd hit
/// 4.5.0) — this parser no longer looks for it.
struct EngineVersionInfo: Equatable {
    /// "4.0.0" — `sr`'s own `srVersion`.
    let srVersion: String
    /// "2026-08-15", or nil for a release-cut banner with no dev stamp.
    let devDate: String?
    /// The commit `sr` itself reports carrying, or nil. See `AboutWindowController`'s
    /// Commit-row rule: no stamp, no hash, no row — never a dash.
    let commitHash: String?

    /// The dev shape: `sr v4.0.0 (dev 2026-08-15)` followed by a line `engine commit <hash>`
    /// — what every build this app currently produces shows. The clean shape (`sr v4.0.0`,
    /// no dev suffix, no commit line) is what a real release cut's committed-nils
    /// `DevStamp.swift` produces. This parser accepts either, off the LAST `sr `-prefixed
    /// line (the FIGlet banner art above it never starts with that) and, only for the dev
    /// shape, the line immediately following it.
    static func parse(_ output: String) -> EngineVersionInfo? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let versionLineIndex = lines.lastIndex(where: { $0.hasPrefix("sr ") }) else { return nil }
        let versionLine = lines[versionLineIndex]
        guard let match = versionLine.wholeMatch(
            of: /sr v(\S+)(?: \(dev ([^)]+)\))?/)
        else { return nil }

        var commitHash: String?
        if match.output.2 != nil, versionLineIndex + 1 < lines.count {
            let next = lines[versionLineIndex + 1]
            if let commitMatch = next.wholeMatch(of: /engine commit (\S+)/) {
                commitHash = String(commitMatch.output.1)
            }
        }

        return EngineVersionInfo(
            srVersion: String(match.output.1),
            devDate: match.output.2.map(String.init),
            commitHash: commitHash
        )
    }

    /// The Engine row's own text — job 341 (b23, round 3): the dev parenthetical moves to its
    /// own line, so a dev build reads "sr v4.0.0\n(dev 2026-08-15)" (two lines in the About
    /// window's grid cell); a clean release cut (no dev stamp) shows the single-line
    /// "sr v4.0.0" with no second line at all. The leading "v" matches docs/RELEASE-CHECKLIST
    /// .md's rule that versions display with a leading v everywhere we control the text.
    var engineRowText: String {
        if let devDate { return "sr v\(srVersion)\n(dev \(devDate))" }
        return "sr v\(srVersion)"
    }

    /// The engine repo's commit page — job 323's ruling names this exact URL shape. Only
    /// meaningful when `commitHash` is non-nil; callers gate the Commit row on that, never
    /// call this with an empty hash.
    func commitURL() -> URL? {
        guard let commitHash, !commitHash.isEmpty else { return nil }
        return URL(string: "https://github.com/jonmichaels/soft-return/commit/\(commitHash)")
    }
}

/// Seam over the real `Process` spawn so `AboutWindowControllerTests` can inject a canned
/// answer — the same seam-not-inheritance shape `MDImportRunning`/`CLIHelpWorkspace` already
/// use in this app.
@MainActor
protocol EngineVersionProbing {
    func currentInfo() -> EngineVersionInfo?
}

/// The real probe: runs the bundled `sr --version --verbose` and parses its stdout. Per job
/// 323's ruling, this is the recommended route specifically BECAUSE it can never drift from
/// the truth the binary carries and needs zero new build infrastructure — the child inherits
/// the sandbox, reads no files, and (being a `--version` request) returns immediately.
struct ProcessEngineVersionProbe: EngineVersionProbing {
    var bundledExecutableURL: URL? = CommandLineToolInstaller.bundledExecutableURL()

    func currentInfo() -> EngineVersionInfo? {
        guard let bundledExecutableURL else { return nil }
        let process = Process()
        process.executableURL = bundledExecutableURL
        process.arguments = ["--version", "--verbose"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return EngineVersionInfo.parse(output)
    }
}
