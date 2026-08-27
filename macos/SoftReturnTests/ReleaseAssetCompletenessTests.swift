import Foundation
import Testing
@testable import SoftReturn

/// Job 374 (b24, RELEASE-ASSET COMPLETENESS GATE). `ReleaseAssets` is the Swift-side half —
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

    @Test func matchingIsCaseInsensitiveJustLikeGitHubUpdateFeedsOwnMatch() throws {
        let missing = ReleaseAssets.missingRequirements(
            assetNames: ["soft-return-4.0.0b24.DMG", "SOFT-RETURN-CLI.PKG"])
        #expect(missing.isEmpty)
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
