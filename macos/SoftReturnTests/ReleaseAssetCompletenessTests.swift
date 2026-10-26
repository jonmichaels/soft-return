import Foundation
import Testing
@testable import SoftReturn

/// What must exist on a published release for this app's own in-app download paths to work:
/// the CLI installer pkg (`CLIHelpWindowController.installerPackageFilename`) and the DMG.
/// Only this test reads it; the release chain's own copy of the two rules is
/// `scripts/verify-release-assets.py`, which `docs/RUNBOOK.md`'s release chain runs before
/// undraft, and the last test below pins the two against each other.
enum ReleaseAssets {
    /// A single release-asset requirement: either an EXACT filename (case-insensitive) or a filename
    /// SUFFIX/pattern (the DMG, whose real name always carries the version, so no exact literal exists to
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
                // Exact: GitHub asset download URLs are case-sensitive.
                return assetNames.contains(name)
            case .filenameSuffix(let suffix):
                return assetNames.contains { $0.lowercased().hasSuffix(suffix.lowercased()) }
            }
        }
    }

    /// Every asset a published release must carry. The CLI name is read off
    /// `CLIHelpWindowController.installerPackageFilename` rather than a second copy of the
    /// string, so this list cannot silently drift from what the app actually looks for.
    static let requirements: [Requirement] = [
        .exactFilename(CLIHelpWindowController.installerPackageFilename),
        .filenameSuffix(".dmg"),
    ]

    /// `requirements` not satisfied by `assetNames` (a release's real asset-name list), each as
    /// its own `describedRequirement` — empty means the release is complete. Pure and
    /// synchronous: fetching the real asset list (a GitHub API call) is the CALLER's job.
    static func missingRequirements(assetNames: [String]) -> [String] {
        requirements
            .filter { !$0.isSatisfied(by: assetNames) }
            .map(\.describedRequirement)
    }
}

/// Job 374 (b24, RELEASE-ASSET COMPLETENESS GATE). `ReleaseAssets` (above) is the Swift-side half —
/// pure logic, exercised directly here. `scripts/verify-release-assets.py` is the chain-side
/// half that actually queries a published release's real asset list (a `gh` call this test
/// environment has no business making — see that script's own doc comment); the LAST test
/// below instead reads the script's own source text and checks its literal requirement
/// constants against `ReleaseAssets`, so the two halves cannot silently drift apart the way
/// the b23 CLI-pkg-leg gap (this job's own brief) went unnoticed for a whole release.
@Suite struct ReleaseAssetCompletenessTests {

    // MARK: - missingRequirements()

    @Test func aCompleteReleaseHasNoMissingRequirements() throws {
        let missing = ReleaseAssets.missingRequirements(
            assetNames: ["Soft-Return-4.0.0b24.dmg", "Soft-Return-CLI.pkg"])
        #expect(missing.isEmpty)
    }

    @Test func theDMGSuffixIsCaseInsensitiveButThePkgNameIsExact() throws {
        #expect(ReleaseAssets.missingRequirements(
            assetNames: ["soft-return-4.0.0b24.DMG", "Soft-Return-CLI.pkg"]).isEmpty)
        #expect(ReleaseAssets.missingRequirements(
            assetNames: ["Soft-Return-4.0.0b24.dmg", "SOFT-RETURN-CLI.PKG"]) == ["Soft-Return-CLI.pkg"],
            "the app downloads the pkg by a case-sensitive fixed URL")
    }

    @Test func aReleaseMissingTheCLIPkgReportsExactlyThat() throws {
        let missing = ReleaseAssets.missingRequirements(assetNames: ["Soft-Return-4.0.0b24.dmg"])
        #expect(missing == ["Soft-Return-CLI.pkg"])
    }

    @Test func aReleaseMissingTheDMGReportsExactlyThat() throws {
        let missing = ReleaseAssets.missingRequirements(assetNames: ["Soft-Return-CLI.pkg"])
        #expect(missing == ["an asset ending in \".dmg\""])
    }

    @Test func anEmptyReleaseReportsBothRequirementsMissing() throws {
        let missing = ReleaseAssets.missingRequirements(assetNames: [])
        #expect(missing.count == 2)
    }

    @Test func aVersionedCLIPkgNameDoesNotSatisfyTheExactRequirement() throws {
        // `installerPackageFilename`'s own doc comment (job 278): deliberately versionless, a
        // stable name a `curl`/`brew` recipe references literally. A release that instead
        // uploaded a versioned name would silently break every in-app download button —
        // exactly what this gate exists to catch before undraft.
        let missing = ReleaseAssets.missingRequirements(
            assetNames: ["Soft-Return-4.0.0b24.dmg", "Soft-Return-CLI-4.0.0b24.pkg"])
        #expect(missing == ["Soft-Return-CLI.pkg"])
    }

    // MARK: - Same source of truth as the app's own real call sites

    @Test func theCLIRequirementIsLiterallyInstallerPackageFilenameNotACopy() throws {
        #expect(ReleaseAssets.requirements.contains(.exactFilename(CLIHelpWindowController.installerPackageFilename)))
    }

    // MARK: - Cross-language drift guard vs scripts/verify-release-assets.py

    @Test func theChainScriptsOwnConstantsMatchReleaseAssets() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos (job 531: scripts/ lives here now, alongside
                                            // SoftReturnTests -- moved together, still 2 deletes)
            .appendingPathComponent("scripts/verify-release-assets.py")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "scripts/verify-release-assets.py not found at \(url.path)")
        #expect(source.contains("INSTALLER_PACKAGE_FILENAME = \"\(CLIHelpWindowController.installerPackageFilename)\""),
                "the chain script's own CLI-pkg literal must match ReleaseAssets/installerPackageFilename")
        #expect(source.contains("DMG_SUFFIX = \".dmg\""),
                "the chain script's own DMG-suffix literal must match ReleaseAssets")
    }
}
