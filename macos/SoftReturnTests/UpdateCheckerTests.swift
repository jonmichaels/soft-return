import Foundation
import Security
import Testing
@testable import SoftReturn

/// Check for Updates: fixture JSON drives `GitHubUpdateFeed.selectRelease` and a fake
/// `UpdateFeed` drives `UpdateChecker.check` — no live network reaches this file at all, per
/// the brief. Job 250 adds the `SRUpdateFeedURL`/`SRUpdateFeedJSON` override knobs and channel
/// selection; both get their own section below. Job 251 adds the app-repo cutover, the
/// `UpdateTokenProvider` seam (a fake provider throughout — this file never touches the real
/// keychain via that seam, per the brief), and 401/404 → `authHint` handling. The one
/// deliberate exception is `sandboxedTestHostCanWriteAndReadItsOwnGenericPasswordItem` below,
/// which exists specifically to touch the REAL keychain (see its doc comment for why).

// MARK: - Fixture JSON

/// The shape GitHub's `GET /repos/:owner/:repo/releases` actually returns (a LIST — job 250
/// moves off `/releases/latest` so channel selection can see prereleases too), trimmed to the
/// three fields this app reads. Real GitHub payloads carry dozens more per item; decoding must
/// ignore them rather than fail on them, which is exercised by NOT declaring them here.
private let fixtureReleaseListJSON = """
[
  {
    "tag_name": "v9.9.9",
    "html_url": "https://github.com/jonmichaels/soft-return/releases/tag/v9.9.9",
    "name": "9.9.9",
    "draft": false,
    "prerelease": false
  }
]
""".data(using: .utf8)!

private let fixtureMalformedJSON = "{ not json at all".data(using: .utf8)!

/// A stable release, a beta ahead of it, and a beta ahead of that — the exact shape job 250's
/// brief asks the comparator to be exercised against (4.0.0b13 vs 3.1.0, 4.0.0b13 vs 4.0.0b14,
/// 4.0.0 vs 4.0.0b14).
private func channelFixtureJSON(vPrefixed: Bool) -> Data {
    func tag(_ v: String) -> String { vPrefixed ? "v\(v)" : v }
    let payload = """
    [
      { "tag_name": "\(tag("3.1.0"))", "html_url": "https://example.com/3.1.0", "prerelease": false },
      { "tag_name": "\(tag("4.0.0b13"))", "html_url": "https://example.com/4.0.0b13", "prerelease": true },
      { "tag_name": "\(tag("4.0.0b14"))", "html_url": "https://example.com/4.0.0b14", "prerelease": true }
    ]
    """
    return payload.data(using: .utf8)!
}

// MARK: - Parsing

@Test func gitHubUpdateFeedSelectsTagNameAndReleasePageURL() throws {
    let release = try GitHubUpdateFeed.selectRelease(from: fixtureReleaseListJSON, channel: .stable)
    #expect(release.version == "v9.9.9")
    #expect(release.downloadURL == URL(string: "https://github.com/jonmichaels/soft-return/releases/tag/v9.9.9"))
}

@Test func gitHubUpdateFeedRejectsMalformedJSON() {
    #expect(throws: (any Error).self) {
        try GitHubUpdateFeed.selectRelease(from: fixtureMalformedJSON, channel: .stable)
    }
}

// MARK: - Release DMG asset (job 276)

@Test func gitHubUpdateFeedRejectsFixturesFromBeforeAssetsExisted() throws {
    // job 250/251's fixtures carry no "assets" key at all — decoding must not regress on them.
    let release = try GitHubUpdateFeed.selectRelease(from: fixtureReleaseListJSON, channel: .stable)
    #expect(release.dmgAsset == nil)
}

@Test func gitHubUpdateFeedPicksTheDMGAssetOverPkgAndZip() throws {
    let json = """
    [
      {
        "tag_name": "v9.9.9",
        "html_url": "https://example.com/9.9.9",
        "prerelease": false,
        "assets": [
          { "id": 1, "name": "Soft-Return-4.0.0b20.pkg", "size": 111 },
          { "id": 2, "name": "Soft-Return-4.0.0b20.zip", "size": 222 },
          { "id": 3, "name": "Soft-Return-4.0.0b20.dmg", "size": 333 }
        ]
      }
    ]
    """.data(using: .utf8)!
    let release = try GitHubUpdateFeed.selectRelease(from: json, channel: .stable)
    #expect(release.dmgAsset == UpdateFeedAsset(id: 3, name: "Soft-Return-4.0.0b20.dmg", size: 333))
}

@Test func gitHubUpdateFeedDMGAssetComesFromTheNewestReleasePerChannel() throws {
    // Two releases, each with its own DMG — the selected asset must belong to the SAME
    // release `selectRelease` picked as newest, not just "any DMG anywhere in the list".
    let json = """
    [
      {
        "tag_name": "4.0.0b13", "html_url": "https://example.com/b13", "prerelease": true,
        "assets": [ { "id": 1, "name": "Soft-Return-4.0.0b13.dmg", "size": 100 } ]
      },
      {
        "tag_name": "4.0.0b14", "html_url": "https://example.com/b14", "prerelease": true,
        "assets": [ { "id": 2, "name": "Soft-Return-4.0.0b14.dmg", "size": 200 } ]
      }
    ]
    """.data(using: .utf8)!
    let release = try GitHubUpdateFeed.selectRelease(from: json, channel: .beta)
    #expect(release.version == "4.0.0b14")
    #expect(release.dmgAsset == UpdateFeedAsset(id: 2, name: "Soft-Return-4.0.0b14.dmg", size: 200))
}

@Test func gitHubUpdateFeedLeavesDMGAssetNilWhenTheReleaseHasNoDMG() throws {
    let json = """
    [
      {
        "tag_name": "v9.9.9", "html_url": "https://example.com/9.9.9", "prerelease": false,
        "assets": [ { "id": 1, "name": "source.zip", "size": 1 } ]
      }
    ]
    """.data(using: .utf8)!
    let release = try GitHubUpdateFeed.selectRelease(from: json, channel: .stable)
    #expect(release.dmgAsset == nil)
}

// MARK: - CLI installer package asset (job 313C)

@Test func gitHubUpdateFeedPicksTheStableNamedCLIPackageAssetOverEverythingElse() throws {
    let json = """
    [
      {
        "tag_name": "v9.9.9",
        "html_url": "https://example.com/9.9.9",
        "prerelease": false,
        "assets": [
          { "id": 1, "name": "Soft-Return-4.0.0b20.dmg", "size": 111 },
          { "id": 2, "name": "Soft-Return-4.0.0b20.zip", "size": 222 },
          { "id": 3, "name": "Soft-Return-CLI.pkg", "size": 333 }
        ]
      }
    ]
    """.data(using: .utf8)!
    let release = try GitHubUpdateFeed.selectRelease(from: json, channel: .stable)
    #expect(release.cliAsset == UpdateFeedAsset(id: 3, name: "Soft-Return-CLI.pkg", size: 333))
}

@Test func gitHubUpdateFeedLeavesCLIAssetNilWhenTheReleaseHasNone() throws {
    let json = """
    [
      {
        "tag_name": "v9.9.9", "html_url": "https://example.com/9.9.9", "prerelease": false,
        "assets": [ { "id": 1, "name": "Soft-Return-4.0.0b20.dmg", "size": 1 } ]
      }
    ]
    """.data(using: .utf8)!
    let release = try GitHubUpdateFeed.selectRelease(from: json, channel: .stable)
    #expect(release.cliAsset == nil)
}

@Test func assetDownloadURLIsTheGitHubAssetsEndpoint() {
    #expect(GitHubUpdateFeed.assetDownloadURL(id: 42) ==
        URL(string: "https://api.github.com/repos/jonmichaels/soft-return/releases/assets/42")!)
}

// MARK: - Download action decision (job 276: browser fallback when there's no DMG)

@Test func updateDownloadActionDownloadsTheAssetWhenOneExists() {
    let asset = UpdateFeedAsset(id: 1, name: "Soft-Return-4.0.0b20.dmg", size: 100)
    let action = UpdateDownloadAction.decide(dmgAsset: asset, downloadURL: URL(string: "https://example.com")!)
    #expect(action == .downloadAsset(asset))
}

@Test func updateDownloadActionFallsBackToTheBrowserWhenThereIsNoDMGAsset() {
    let url = URL(string: "https://example.com/releases/tag/v9.9.9")!
    let action = UpdateDownloadAction.decide(dmgAsset: nil, downloadURL: url)
    #expect(action == .openBrowser(url))
}

@Test func gitHubUpdateFeedThrowsWhenChannelHasNoEligibleRelease() {
    // Stable channel, list containing ONLY a prerelease: nothing eligible.
    let onlyBeta = """
    [ { "tag_name": "4.0.0b1", "html_url": "https://example.com/4.0.0b1", "prerelease": true } ]
    """.data(using: .utf8)!
    #expect(throws: UpdateFeedError.noReleaseForChannel) {
        try GitHubUpdateFeed.selectRelease(from: onlyBeta, channel: .stable)
    }
}

// MARK: - Channel selection (job 250)

@Test func updateChannelIsBetaWhenVersionContainsB() {
    #expect(UpdateChannel.forVersion("4.0.0b13") == .beta)
    #expect(UpdateChannel.forVersion("v4.0.0b13") == .beta)
    #expect(UpdateChannel.forVersion("4.0.0B13") == .beta)
}

@Test func updateChannelIsStableWhenVersionHasNoB() {
    #expect(UpdateChannel.forVersion("4.0.0") == .stable)
    #expect(UpdateChannel.forVersion("v3.1.0") == .stable)
}

@Test func betaChannelSelectsNewestOverallIncludingBetas() throws {
    // 4.0.0b13 vs 4.0.0b14: beta channel must pick the newer beta, not the stable 3.1.0.
    let release = try GitHubUpdateFeed.selectRelease(from: channelFixtureJSON(vPrefixed: false), channel: .beta)
    #expect(release.version == "4.0.0b14")
}

@Test func betaChannelBeatsAnOlderStableTooWhenABetaIsNewest() throws {
    // 4.0.0b13 vs 3.1.0: a beta build's channel is still "newest overall", so it sees 4.0.0b14
    // ahead of the older stable 3.1.0 as well — not just ahead of other betas.
    let release = try GitHubUpdateFeed.selectRelease(from: channelFixtureJSON(vPrefixed: false), channel: .beta)
    #expect(UpdateChecker.isNewer(release.version, than: "3.1.0"))
}

@Test func stableChannelNeverOffersABeta() throws {
    // 4.0.0 vs 4.0.0b14: stable must NOT offer a beta even though 4.0.0b14 outranks 4.0.0 —
    // the newest NON-prerelease in this fixture is 3.1.0, which is OLDER than 4.0.0, so a
    // stable-channel check from 4.0.0 must come back with nothing newer to offer.
    let release = try GitHubUpdateFeed.selectRelease(from: channelFixtureJSON(vPrefixed: false), channel: .stable)
    #expect(release.version == "3.1.0")
    #expect(!UpdateChecker.isNewer(UpdateChecker.normalize(release.version), than: "4.0.0"))
}

@Test func channelSelectionHandlesVPrefixedTags() throws {
    let release = try GitHubUpdateFeed.selectRelease(from: channelFixtureJSON(vPrefixed: true), channel: .beta)
    #expect(release.version == "v4.0.0b14")

    let stable = try GitHubUpdateFeed.selectRelease(from: channelFixtureJSON(vPrefixed: true), channel: .stable)
    #expect(stable.version == "v3.1.0")
}

// MARK: - Rolling non-version tags (job 278)

/// The release repo will soon carry a rolling `beta` tag whose assets are always newest — not
/// a version at all, so it must never enter the version comparison, only be skipped for it.
private func rollingTagFixtureJSON() -> Data {
    """
    [
      { "tag_name": "beta", "html_url": "https://example.com/beta", "prerelease": true },
      { "tag_name": "3.1.0", "html_url": "https://example.com/3.1.0", "prerelease": false },
      { "tag_name": "4.0.0b13", "html_url": "https://example.com/4.0.0b13", "prerelease": true },
      { "tag_name": "4.0.0b14", "html_url": "https://example.com/4.0.0b14", "prerelease": true }
    ]
    """.data(using: .utf8)!
}

@Test func isVersionLikeAcceptsPlainAndBetaVersionTags() {
    #expect(UpdateChecker.isVersionLike("4.0.0"))
    #expect(UpdateChecker.isVersionLike("v4.0.0"))
    #expect(UpdateChecker.isVersionLike("4.0.0b13"))
    #expect(UpdateChecker.isVersionLike("4.0.0B13"))
    #expect(UpdateChecker.isVersionLike("1.2"))
}

@Test func isVersionLikeRejectsRollingAndOtherNonVersionTags() {
    #expect(!UpdateChecker.isVersionLike("beta"))
    #expect(!UpdateChecker.isVersionLike("latest"))
    #expect(!UpdateChecker.isVersionLike("nightly"))
    #expect(!UpdateChecker.isVersionLike(""))
    #expect(!UpdateChecker.isVersionLike("4.0.0."))
    #expect(!UpdateChecker.isVersionLike("4.x.0"))
}

@Test func rollingBetaTagIsSkippedNotMisrankedForBetaChannel() throws {
    // A "beta" rolling tag alongside real versioned prereleases: the newest REAL version must
    // still win — "beta" must not sort as the lowest possible version and lose by luck, or as
    // the highest and win by accident (a bogus win).
    let release = try GitHubUpdateFeed.selectRelease(from: rollingTagFixtureJSON(), channel: .beta)
    #expect(release.version == "4.0.0b14")
}

@Test func rollingBetaTagIsSkippedForStableChannelToo() throws {
    let release = try GitHubUpdateFeed.selectRelease(from: rollingTagFixtureJSON(), channel: .stable)
    #expect(release.version == "3.1.0")
}

@Test func rollingTagOnlyListThrowsNoReleaseForChannelNotACrashOrABogusWin() {
    let onlyRolling = """
    [ { "tag_name": "beta", "html_url": "https://example.com/beta", "prerelease": true } ]
    """.data(using: .utf8)!
    #expect(throws: UpdateFeedError.noReleaseForChannel) {
        try GitHubUpdateFeed.selectRelease(from: onlyRolling, channel: .beta)
    }
    #expect(throws: UpdateFeedError.noReleaseForChannel) {
        try GitHubUpdateFeed.selectRelease(from: onlyRolling, channel: .stable)
    }
}

/// Job 280: the DOWNLOAD path (`dmgAsset`) must never pick the rolling tag's own asset either —
/// job 278's `isVersionLike` guard already keeps "beta" out of the VERSION comparison, but that
/// says nothing on its own about which release's `assets` array `selectRelease` reads the DMG
/// from. Every release here carries an asset literally named "Soft-Return.dmg" (the stable name
/// this job's brief says releases are moving to) so the assertion can only pass by picking the
/// right RELEASE, never by the asset's name happening to differ.
private func rollingTagFixtureJSONWithDownloadAssets() -> Data {
    """
    [
      { "tag_name": "beta", "html_url": "https://example.com/beta", "prerelease": true,
        "assets": [ { "id": 99, "name": "Soft-Return.dmg", "size": 999 } ] },
      { "tag_name": "3.1.0", "html_url": "https://example.com/3.1.0", "prerelease": false,
        "assets": [ { "id": 1, "name": "Soft-Return.dmg", "size": 111 } ] },
      { "tag_name": "4.0.0b13", "html_url": "https://example.com/4.0.0b13", "prerelease": true,
        "assets": [ { "id": 2, "name": "Soft-Return.dmg", "size": 222 } ] },
      { "tag_name": "4.0.0b14", "html_url": "https://example.com/4.0.0b14", "prerelease": true,
        "assets": [ { "id": 3, "name": "Soft-Return.dmg", "size": 333 } ] }
    ]
    """.data(using: .utf8)!
}

@Test func downloadAssetIsFromTheVersionSelectedReleaseNeverTheRollingTagForBetaChannel() throws {
    let release = try GitHubUpdateFeed.selectRelease(from: rollingTagFixtureJSONWithDownloadAssets(), channel: .beta)
    #expect(release.version == "4.0.0b14")
    #expect(release.dmgAsset == UpdateFeedAsset(id: 3, name: "Soft-Return.dmg", size: 333))
}

@Test func downloadAssetIsFromTheVersionSelectedReleaseNeverTheRollingTagForStableChannel() throws {
    let release = try GitHubUpdateFeed.selectRelease(from: rollingTagFixtureJSONWithDownloadAssets(), channel: .stable)
    #expect(release.version == "3.1.0")
    #expect(release.dmgAsset == UpdateFeedAsset(id: 1, name: "Soft-Return.dmg", size: 111))
}

// MARK: - Version comparison

@Test func normalizeStripsALeadingV() {
    #expect(UpdateChecker.normalize("v1.2.3") == "1.2.3")
    #expect(UpdateChecker.normalize("V1.2.3") == "1.2.3")
    #expect(UpdateChecker.normalize("1.2.3") == "1.2.3")
}

@Test func isNewerComparesComponentWise() {
    #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
    #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
    #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2.0"))
    #expect(!UpdateChecker.isNewer("1.1.0", than: "1.2.0"))
    // Missing trailing components count as zero: "1.2" == "1.2.0".
    #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
    #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
}

@Test func isNewerOrdersBetaBuildsAgainstEachOtherAndAgainstTheRelease() {
    // 4.0.0b1 < 4.0.0b2 < 4.0.0 < 4.0.1
    #expect(UpdateChecker.isNewer("4.0.0b2", than: "4.0.0b1"))
    #expect(!UpdateChecker.isNewer("4.0.0b1", than: "4.0.0b2"))
    #expect(UpdateChecker.isNewer("4.0.0", than: "4.0.0b2"))
    #expect(!UpdateChecker.isNewer("4.0.0b2", than: "4.0.0"))
    #expect(UpdateChecker.isNewer("4.0.0", than: "4.0.0b1"))
    #expect(UpdateChecker.isNewer("4.0.1", than: "4.0.0b1"))
    #expect(!UpdateChecker.isNewer("4.0.0b1", than: "4.0.1"))

    // A beta compares equal to itself.
    #expect(!UpdateChecker.isNewer("4.0.0b1", than: "4.0.0b1"))

    // Case-insensitive.
    #expect(UpdateChecker.isNewer("4.0.0B2", than: "4.0.0b1"))
    #expect(!UpdateChecker.isNewer("4.0.0b2", than: "4.0.0B2"))
}

@Test func evaluateReportsUpdateAvailableWhenServerIsNewer() {
    let release = UpdateFeedRelease(version: "v9.9.9", downloadURL: URL(string: "https://example.com/9.9.9")!)
    let result = UpdateChecker.evaluate(current: "0.1.0", latest: release)
    #expect(result == .updateAvailable(version: "9.9.9", downloadURL: release.downloadURL, dmgAsset: nil))
}

@Test func evaluateReportsUpToDateWhenServerIsSameOrOlder() {
    let same = UpdateFeedRelease(version: "v0.1.0", downloadURL: URL(string: "https://example.com/0.1.0")!)
    #expect(UpdateChecker.evaluate(current: "0.1.0", latest: same) == .upToDate)

    let older = UpdateFeedRelease(version: "v0.0.9", downloadURL: URL(string: "https://example.com/0.0.9")!)
    #expect(UpdateChecker.evaluate(current: "0.1.0", latest: older) == .upToDate)
}

// MARK: - The injected protocol, end to end, with no network

private struct FixtureFeed: UpdateFeed {
    let release: UpdateFeedRelease
    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease { release }
}

private struct FailingFeed: UpdateFeed {
    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease {
        throw UpdateFeedError.badResponse
    }
}

/// Records which channel `UpdateChecker.check` actually asked for, so the "beta build asks for
/// beta / stable build asks for stable" wiring is provable, not just assumed.
private final class ChannelRecordingFeed: UpdateFeed, @unchecked Sendable {
    private(set) var requestedChannel: UpdateChannel?
    let release: UpdateFeedRelease

    init(release: UpdateFeedRelease) { self.release = release }

    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease {
        requestedChannel = channel
        return release
    }
}

@Test func checkReturnsUpdateAvailableThroughTheProtocol() async {
    let feed = FixtureFeed(release: UpdateFeedRelease(
        version: "v9.9.9", downloadURL: URL(string: "https://example.com/9.9.9")!))
    let result = await UpdateChecker.check(currentVersion: "0.1.0", feed: feed)
    #expect(result == .updateAvailable(version: "9.9.9", downloadURL: feed.release.downloadURL, dmgAsset: nil))
}

@Test func checkReturnsUpToDateThroughTheProtocol() async {
    let feed = FixtureFeed(release: UpdateFeedRelease(
        version: "v0.1.0", downloadURL: URL(string: "https://example.com/0.1.0")!))
    let result = await UpdateChecker.check(currentVersion: "0.1.0", feed: feed)
    #expect(result == .upToDate)
}

/// The network-failure alert path: a feed that throws must become `.checkFailed`, never an
/// uncaught error and never mistaken for "no update" (which would tell a user on an airplane
/// that they are up to date when nobody actually checked). Also covers `noReleaseForChannel`
/// via the same `catch` — see `UpdateChecker.check`'s doc comment.
@Test func checkReturnsCheckFailedWhenTheFeedThrows() async {
    let result = await UpdateChecker.check(currentVersion: "0.1.0", feed: FailingFeed())
    #expect(result == .checkFailed(authHint: false))
}

/// Job 251: `.unauthorized`/`.notFound` are the two outcomes a missing or bad update token
/// actually produces against a private repo (see `UpdateFeedError.notFound`'s doc comment) —
/// both must set `authHint`, and nothing else should.
private struct ThrowingFeed: UpdateFeed {
    let error: any Error
    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease { throw error }
}

@Test func checkSetsAuthHintForUnauthorizedAndNotFound() async {
    let unauthorized = await UpdateChecker.check(
        currentVersion: "0.1.0", feed: ThrowingFeed(error: UpdateFeedError.unauthorized))
    #expect(unauthorized == .checkFailed(authHint: true))

    let notFound = await UpdateChecker.check(
        currentVersion: "0.1.0", feed: ThrowingFeed(error: UpdateFeedError.notFound))
    #expect(notFound == .checkFailed(authHint: true))
}

@Test func checkLeavesAuthHintFalseForOtherFeedErrors() async {
    let badResponse = await UpdateChecker.check(
        currentVersion: "0.1.0", feed: ThrowingFeed(error: UpdateFeedError.badResponse))
    #expect(badResponse == .checkFailed(authHint: false))

    let noRelease = await UpdateChecker.check(
        currentVersion: "0.1.0", feed: ThrowingFeed(error: UpdateFeedError.noReleaseForChannel))
    #expect(noRelease == .checkFailed(authHint: false))
}

@Test func checkAsksTheFeedForTheChannelMatchingTheCurrentBuild() async {
    let release = UpdateFeedRelease(version: "v0.1.0", downloadURL: URL(string: "https://example.com/0.1.0")!)

    let betaFeed = ChannelRecordingFeed(release: release)
    _ = await UpdateChecker.check(currentVersion: "4.0.0b13", feed: betaFeed)
    #expect(betaFeed.requestedChannel == .beta)

    let stableFeed = ChannelRecordingFeed(release: release)
    _ = await UpdateChecker.check(currentVersion: "4.0.0", feed: stableFeed)
    #expect(stableFeed.requestedChannel == .stable)
}

// MARK: - Feed override (job 250: SRUpdateFeedURL / SRUpdateFeedJSON)

/// A private, per-test `UserDefaults` suite — never touches the real `me.beforeti.softreturn`
/// domain a developer might have live keys in, and needs no save/restore teardown dance.
private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "UpdateCheckerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test func feedIsInertWhenNeitherOverrideKeyIsSet() async throws {
    let defaults = makeIsolatedDefaults()
    DefaultEndpointRecordingURLProtocol.stubData = fixtureReleaseListJSON
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DefaultEndpointRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let feed = GitHubUpdateFeed(session: session, defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    _ = try await feed.latestRelease(channel: .stable)
    #expect(DefaultEndpointRecordingURLProtocol.lastRequestedURL == GitHubUpdateFeed.releasesListURL)
}

/// Job 530 (Jon's ruling 2026-08-26, b34 work): the app's own repo was renamed off the private
/// `soft-return-app` slug onto the public `soft-return` repo — the same slug the CtrlKD engine
/// package already used (`EngineVersionInfo.commitURL`) — so this repo and the engine repo are
/// now, deliberately, the same URL. Pinned as its own assertion, not just inferred from the
/// test above, so a future accidental revert of `releasesListURL` fails loudly here even if
/// something upstream of it also changed.
@Test func defaultFeedURLIsTheAppRepoNowTheSamePublicSlugAsTheEngineRepo() {
    #expect(GitHubUpdateFeed.releasesListURL == URL(string: "https://api.github.com/repos/jonmichaels/soft-return/releases")!)
}

/// Job 264 (`cli-marked-method`): `CLIHelpWindowController`'s installer-package section links
/// here — pinned the same way `releasesListURL` is above, so the two can't silently drift onto
/// different repos.
@Test func releasesPageURLIsTheHumanFacingPageForTheSameRepoTheFeedQueries() {
    #expect(GitHubUpdateFeed.releasesPageURL == URL(string: "https://github.com/jonmichaels/soft-return/releases")!)
}

// MARK: - Update token (job 251: keychain-provisioned PAT for the now-private feed)

/// Stands in for `KeychainUpdateTokenProvider` in every test in this file — none of them may
/// touch the real keychain, per the brief. The one test that legitimately DOES touch the real
/// keychain (`sandboxedTestHostCanWriteAndReadItsOwnGenericPasswordItem`, below) uses
/// `SecItemAdd`/`SecItemCopyMatching` directly instead, not this type or `GitHubUpdateFeed` at
/// all — it is answering a different question (does the sandbox allow it) than these are
/// (does `GitHubUpdateFeed` use whatever the provider hands it correctly).
private struct FakeTokenProvider: UpdateTokenProvider {
    let value: String?
    func token() -> String? { value }
}

@Test func tokenIsAttachedAsABearerAuthorizationHeaderWhenTheProviderHasOne() async throws {
    TokenPresentRecordingURLProtocol.stubData = fixtureReleaseListJSON
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenPresentRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let feed = GitHubUpdateFeed(
        session: session, defaults: makeIsolatedDefaults(), tokenProvider: FakeTokenProvider(value: "abc123"))
    _ = try await feed.latestRelease(channel: .stable)
    #expect(TokenPresentRecordingURLProtocol.lastAuthorizationHeader == "Bearer abc123")
}

@Test func noAuthorizationHeaderIsSentWhenTheProviderHasNoToken() async throws {
    TokenAbsentRecordingURLProtocol.stubData = fixtureReleaseListJSON
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenAbsentRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let feed = GitHubUpdateFeed(
        session: session, defaults: makeIsolatedDefaults(), tokenProvider: FakeTokenProvider(value: nil))
    _ = try await feed.latestRelease(channel: .stable)
    #expect(TokenAbsentRecordingURLProtocol.lastAuthorizationHeader == nil)
}

/// `SRUpdateFeedJSON` (job 250) bypasses `URLSession` entirely — the token provider must never
/// even be consulted on that path, let alone attached to a request that's never built.
@Test func inlineJSONOverrideNeverConsultsTheTokenProvider() async throws {
    let defaults = makeIsolatedDefaults()
    defaults.set(
        String(data: channelFixtureJSON(vPrefixed: false), encoding: .utf8),
        forKey: GitHubUpdateFeed.feedJSONDefaultsKey)
    let poisonedConfig = URLSessionConfiguration.ephemeral
    poisonedConfig.protocolClasses = [AlwaysFailingURLProtocol.self]
    let session = URLSession(configuration: poisonedConfig)

    struct CrashingTokenProvider: UpdateTokenProvider {
        func token() -> String? { Issue.record("token provider must not be called for the inline-JSON path"); return nil }
    }
    let feed = GitHubUpdateFeed(session: session, defaults: defaults, tokenProvider: CrashingTokenProvider())
    let release = try await feed.latestRelease(channel: .beta)
    #expect(release.version == "4.0.0b14")
}

// MARK: - 401/404 → UpdateFeedError, and the authHint they carry through `check` (job 251)

@Test func gitHubUpdateFeedThrowsUnauthorizedOnHTTP401() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UnauthorizedRecordingURLProtocol.self]
    let session = URLSession(configuration: config)
    let feed = GitHubUpdateFeed(
        session: session, defaults: makeIsolatedDefaults(), tokenProvider: FakeTokenProvider(value: "expired"))

    await #expect(throws: UpdateFeedError.unauthorized) {
        try await feed.latestRelease(channel: .stable)
    }
}

@Test func gitHubUpdateFeedThrowsNotFoundOnHTTP404() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NotFoundRecordingURLProtocol.self]
    let session = URLSession(configuration: config)
    let feed = GitHubUpdateFeed(
        session: session, defaults: makeIsolatedDefaults(), tokenProvider: FakeTokenProvider(value: nil))

    await #expect(throws: UpdateFeedError.notFound) {
        try await feed.latestRelease(channel: .stable)
    }
}

/// End to end through the real `GitHubUpdateFeed`, not `ThrowingFeed` — proves the 401 →
/// `.unauthorized` → `authHint: true` chain holds all the way from an `HTTPURLResponse` to the
/// alert-facing `UpdateCheckResult`, not just at each link checked in isolation.
@Test func checkForUpdatesSetsAuthHintEndToEndOnAWrongOrExpiredToken() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EndToEndUnauthorizedRecordingURLProtocol.self]
    let session = URLSession(configuration: config)
    let feed = GitHubUpdateFeed(
        session: session, defaults: makeIsolatedDefaults(), tokenProvider: FakeTokenProvider(value: "expired"))

    let result = await UpdateChecker.check(currentVersion: "4.0.0b13", feed: feed)
    #expect(result == .checkFailed(authHint: true))
}

@Test func urlOverrideIsHonoredForAnHTTPSURL() async throws {
    let defaults = makeIsolatedDefaults()
    let overrideURL = URL(string: "https://example.com/custom-feed.json")!
    defaults.set(overrideURL.absoluteString, forKey: GitHubUpdateFeed.feedURLDefaultsKey)

    OverrideEndpointRecordingURLProtocol.stubData = channelFixtureJSON(vPrefixed: false)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OverrideEndpointRecordingURLProtocol.self]
    let session = URLSession(configuration: config)

    let feed = GitHubUpdateFeed(session: session, defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    let release = try await feed.latestRelease(channel: .beta)
    #expect(OverrideEndpointRecordingURLProtocol.lastRequestedURL == overrideURL)
    #expect(release.version == "4.0.0b14")
}

@Test func inlineJSONOverrideBypassesNetworkAndIsHonored() async throws {
    let defaults = makeIsolatedDefaults()
    defaults.set(String(data: channelFixtureJSON(vPrefixed: false), encoding: .utf8), forKey: GitHubUpdateFeed.feedJSONDefaultsKey)
    // A session that fails any request it's asked to run — if the inline-JSON path is honored,
    // this session must never be touched.
    let poisonedConfig = URLSessionConfiguration.ephemeral
    poisonedConfig.protocolClasses = [AlwaysFailingURLProtocol.self]
    let session = URLSession(configuration: poisonedConfig)

    let feed = GitHubUpdateFeed(session: session, defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    let release = try await feed.latestRelease(channel: .beta)
    #expect(release.version == "4.0.0b14")
}

@Test func inlineJSONOverrideTakesPriorityOverURLOverride() async throws {
    let defaults = makeIsolatedDefaults()
    defaults.set("file:///nonexistent/should-not-be-read.json", forKey: GitHubUpdateFeed.feedURLDefaultsKey)
    defaults.set(String(data: channelFixtureJSON(vPrefixed: false), encoding: .utf8), forKey: GitHubUpdateFeed.feedJSONDefaultsKey)

    let feed = GitHubUpdateFeed(defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    let release = try await feed.latestRelease(channel: .stable)
    #expect(release.version == "3.1.0")
}

@Test func urlOverrideIsHonoredForAFileURL() async throws {
    let defaults = makeIsolatedDefaults()
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCheckerTests-\(UUID().uuidString).json")
    try channelFixtureJSON(vPrefixed: false).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    defaults.set(tempFile.absoluteString, forKey: GitHubUpdateFeed.feedURLDefaultsKey)
    let feed = GitHubUpdateFeed(defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    let release = try await feed.latestRelease(channel: .beta)
    #expect(release.version == "4.0.0b14")
}

/// A `file://` response is never an `HTTPURLResponse` — proving `fetchListData`'s status check
/// is scheme-aware, not just "happens to work for this one fixture". Without the `if let
/// http = …` guard in `GitHubUpdateFeed.fetchListData`, this file read would throw
/// `badResponse` even though the read itself succeeded.
@Test func fileURLOverrideDoesNotFalsePositiveOnMissingHTTPStatus() async throws {
    let defaults = makeIsolatedDefaults()
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCheckerTests-status-\(UUID().uuidString).json")
    try fixtureReleaseListJSON.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    defaults.set(tempFile.absoluteString, forKey: GitHubUpdateFeed.feedURLDefaultsKey)
    let feed = GitHubUpdateFeed(defaults: defaults, tokenProvider: FakeTokenProvider(value: nil))
    let release = try await feed.latestRelease(channel: .stable)
    #expect(release.version == "v9.9.9")
}

/// `URLProtocol` stub that fails every request — stands in for "the network must not be
/// touched" in `inlineJSONOverrideBypassesNetworkAndIsHonored`.
private final class AlwaysFailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// `URLProtocol` stub that records which URL it was asked for and answers with canned JSON.
/// Swift Testing schedules `@Test` functions concurrently by default, so this base is never
/// registered directly — each call site below gets its OWN leaf subclass (distinct static
/// storage per type) to rule out one test's request stomping another's in-flight state.
private class RecordingURLProtocolBase: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
}

private final class DefaultEndpointRecordingURLProtocol: RecordingURLProtocolBase {
    nonisolated(unsafe) static var lastRequestedURL: URL?
    nonisolated(unsafe) static var stubData = Data()

    override func startLoading() {
        Self.lastRequestedURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class OverrideEndpointRecordingURLProtocol: RecordingURLProtocolBase {
    nonisolated(unsafe) static var lastRequestedURL: URL?
    nonisolated(unsafe) static var stubData = Data()

    override func startLoading() {
        Self.lastRequestedURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - job 251 URLProtocol stubs (Authorization header + status code)

/// Records the `Authorization` header the request actually carried (`nil` if none) and
/// answers 200 with canned JSON. Own leaf subclass per test, same reasoning as
/// `RecordingURLProtocolBase`'s doc comment above.
private final class TokenPresentRecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastAuthorizationHeader: String?
    nonisolated(unsafe) static var stubData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class TokenAbsentRecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastAuthorizationHeader: String?
    nonisolated(unsafe) static var stubData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers every request with a bare 401 — no body needed, `selectRelease` is never reached.
private final class UnauthorizedRecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers every request with a bare 404 — GitHub's actual private-repo-to-an-unauthorized-
/// caller response (see `UpdateFeedError.notFound`'s doc comment).
private final class NotFoundRecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A separate leaf type from `UnauthorizedRecordingURLProtocol` purely so the end-to-end
/// `check(currentVersion:feed:)` test can't race that test's own static state if Swift Testing
/// ever runs them concurrently on the same `URLProtocol` registration.
private final class EndToEndUnauthorizedRecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Real keychain: does the sandboxed test host need `keychain-access-groups`? (job 251)

/// Empirically answers the brief's sandbox note: "`keychain-access-groups` not needed for the
/// app's own keychain items." This is the ONE test in this file that touches the REAL
/// keychain, on purpose — it is not testing `GitHubUpdateFeed` or `KeychainUpdateTokenProvider`
/// at all, it is testing whether `SecItemAdd`/`SecItemCopyMatching` work at all from inside
/// this sandboxed test host for an item the host itself creates, with no
/// `com.apple.security.keychain-access-groups` entitlement present anywhere in this project
/// (confirmed absent in `SoftReturn.entitlements`/`SoftReturn-Debug.entitlements` — there is no
/// test-host entitlements file at all, which is itself part of what's being checked: the
/// default/no-entitlement case).
///
/// Uses a service name distinct from `KeychainUpdateTokenProvider.service` so this can never
/// collide with, mask, or delete a real provisioned update token sitting in the same keychain,
/// and cleans up its own item unconditionally (`defer`) whether the assertions pass or fail.
///
/// **What actually happened when this ran in this job's sandboxed `SoftReturnTests` host:**
/// `SecItemAdd` returned `errSecSuccess` and the immediate `SecItemCopyMatching` read back the
/// exact bytes written, with no ACL/authentication prompt of any kind — confirming the brief's
/// claim for the same-process, own-item case. See the job report's LESSONS for the (materially
/// different) cross-process case: an item created out-of-process via `security
/// add-generic-password`, which this test does not exercise.
@Test func sandboxedTestHostCanWriteAndReadItsOwnGenericPasswordItem() throws {
    let service = "SoftReturnTests-KeychainProbe-job251"
    let account = "probe"
    let secret = "job251-probe-\(UUID().uuidString)"

    let addQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecValueData: secret.data(using: .utf8)!,
    ]
    // Clear any stale item from a previous interrupted run before adding — SecItemAdd fails
    // with errSecDuplicateItem otherwise.
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    defer {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    #expect(addStatus == errSecSuccess)

    let readQuery: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
    #expect(readStatus == errSecSuccess)
    #expect((result as? Data).flatMap { String(data: $0, encoding: .utf8) } == secret)
}
