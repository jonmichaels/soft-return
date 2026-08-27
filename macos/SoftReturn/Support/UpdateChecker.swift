import AppKit
import Foundation
import Security

/// Where "is there a newer version" comes from — a protocol, not a direct GitHub call inline
/// in the menu action. Job 251 ruling (Jon, 2026-08-12): "We have releases in the app repo. It
/// checks against that. Cutover will be to the public repo later." This repo (`soft-return-app`)
/// is private, so `GitHubUpdateFeed` authenticates with a user-provisioned token (see
/// `KeychainUpdateTokenProvider` below) rather than hitting the endpoint anonymously. The
/// injection seam is what lets the endpoint be swapped for a future public releases channel
/// later without touching `AppDelegate` or the alert copy again — see
/// `GitHubUpdateFeed.releasesListURL`.
///
/// `channel` is threaded through here rather than read by the feed itself so a fixture feed in
/// tests can assert on exactly which channel `UpdateChecker.check` asked for.
protocol UpdateFeed: Sendable {
    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease
}

/// The one piece of a release this app cares about: what to call it, and where to send
/// someone who wants it. Deliberately not the raw GitHub JSON shape — that is
/// `GitHubUpdateFeed`'s business to parse and nobody else's to know about.
struct UpdateFeedRelease: Equatable, Sendable {
    /// As GitHub wrote it — may carry a leading "v"; `UpdateChecker.normalize` strips that,
    /// not this.
    let version: String
    let downloadURL: URL
    /// Job 276 (interim in-app download, ahead of a public Sparkle feed): the release's DMG,
    /// if it shipped one. `nil` for a release with no DMG asset — a stable-track fixture that
    /// only carries source archives, say — in which case the alert falls back to
    /// `downloadURL` (the releases page) exactly as it did before this job.
    let dmgAsset: UpdateFeedAsset?

    /// Job 313C: the CLI installer package, if this release shipped one — same shape as
    /// `dmgAsset`, matched by `CLIHelpWindowController.installerPackageFilename`'s stable
    /// name rather than a suffix (unlike the DMG, there is exactly one asset this could ever
    /// legitimately be, so an exact match is the honest check).
    let cliAsset: UpdateFeedAsset?

    /// Explicit, not the synthesized memberwise init: a stored property's own default value
    /// does NOT, on its own, make the compiler-generated memberwise initializer's matching
    /// parameter optional (confirmed by this job's own build — `UpdateFeedRelease(version:
    /// downloadURL:)` failed with "extra argument 'dmgAsset'" until this was added). Defaults
    /// here are what keep every pre-job-276/pre-job-313C call site compiling.
    init(version: String, downloadURL: URL, dmgAsset: UpdateFeedAsset? = nil, cliAsset: UpdateFeedAsset? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.dmgAsset = dmgAsset
        self.cliAsset = cliAsset
    }
}

/// One GitHub release asset this app might want to fetch directly — just enough to name the
/// `GET /repos/.../releases/assets/{id}` request and the destination file
/// (`UpdateDownloadDestination`). Not the raw GitHub JSON shape, same reasoning as
/// `UpdateFeedRelease`.
struct UpdateFeedAsset: Equatable, Sendable {
    let id: Int
    let name: String
    let size: Int
}

enum UpdateFeedError: Error {
    case badResponse
    /// The release list decoded fine but contained nothing eligible for the requested
    /// channel — e.g. a stable check against a list of nothing but prereleases. Distinct from
    /// `badResponse` so a job-250-style console test can tell "the feed is broken" apart from
    /// "the feed is fine, there's just nothing to offer this channel yet".
    case noReleaseForChannel
    /// HTTP 401 — a token was sent (or the endpoint otherwise required one) and it was
    /// rejected. Distinct from `badResponse` only so `UpdateChecker.check` can add the
    /// beta-update-token hint to `.checkFailed` (job 251); the alert copy is otherwise
    /// identical.
    case unauthorized
    /// HTTP 404 — GitHub's actual response for a private repo's releases endpoint when the
    /// request carries no token, or a token scoped to the wrong repo: private repos return
    /// 404 rather than 401/403 to an unauthorized caller, so this app's own repo being private
    /// (per job 251's ruling) makes 404 the COMMON case for "no usable token", not an edge
    /// case. Same `.checkFailed` treatment as `.unauthorized`.
    case notFound
}

/// Which release track a running build should be offered. Selection is entirely derived from
/// the build's OWN version string — there is no user-facing channel picker — per job 250's
/// ruling: "version strings containing 'b' (e.g. 4.0.0b13) check beta; others stable."
enum UpdateChannel: Equatable, Sendable {
    case stable
    case beta

    static func forVersion(_ version: String) -> UpdateChannel {
        UpdateChecker.normalize(version).lowercased().contains("b") ? .beta : .stable
    }
}

/// The GitHub Releases API, queried for THIS app's own (private) repo.
///
/// Job 251 ruling (Jon, 2026-08-12 — "We have releases in the app repo. It checks against
/// that. Cutover will be to the public repo later."): job 250 had this pointed at the public
/// CtrlKD engine repo, reasoning that this app had no release channel of its own yet; that
/// premise turned out to be wrong — the app repo's own GitHub releases ARE the source of
/// truth, today, private or not. `releasesListURL` below is the ONE seam that names a repo in
/// this file; cutover = replace that URL (and only that URL) when a public soft-return-app
/// releases channel exists.
///
/// Job 250 (testable Check for Updates, Jon's ruling 2026-08-12 — "I need to test current
/// functionality. Not hope it works." / "No private is public. No releases repo."): the feed
/// this queries is overridable from `UserDefaults`, in the app's own domain
/// (`me.beforeti.softreturn`), by two independent keys. Both are inert unless set, so a
/// production build with neither key written behaves exactly as before, and both TAKE
/// PRECEDENCE over the token/default-URL path below — a console test using either knob never
/// touches the keychain at all.
///
/// - `SRUpdateFeedURL` — a string URL. Replaces the default releases-list endpoint. Works for
///   `https://` unconditionally (the app already carries `com.apple.security.network.client`,
///   which is a blanket outbound-network grant, not a per-host allowlist — see
///   `SoftReturn.entitlements`). `file://` ALSO works, but only for a path the sandbox already
///   lets this app read without any extra entitlement or user-selected grant: the app's own
///   container, e.g. `~/Library/Containers/me.beforeti.softreturn/Data/Documents/`. A
///   `file://` URL outside that container is sandbox-denied at the `URLSession` layer — that
///   failure surfaces as `.checkFailed` in the UI, not a crash, but it will never load. This is
///   standard App Sandbox container behavior (an app's own container needs no entitlement to
///   read/write); this job had no live network access to attach a freshly-fetched Apple docs
///   citation for that specific claim, so it is flagged here rather than asserted as sourced —
///   see the job report's LESSONS.
/// - `SRUpdateFeedJSON` — the release-list JSON itself, inline, as a string. Takes priority
///   over `SRUpdateFeedURL` when both are set. Bypasses `URLSession` (and therefore the
///   sandbox's file/network layer) entirely, which makes it the more robust of the two knobs to
///   drive from a console recipe: nothing about it depends on container paths or file-scheme
///   response handling.
///
/// Job 251 adds `tokenProvider`: this app's own repo is private, so an unauthenticated request
/// to `releasesListURL` gets GitHub's private-repo 404 (not a 401 — see `UpdateFeedError`), not
/// the release list. `KeychainUpdateTokenProvider` reads a fine-grained, read-only, user-
/// provisioned PAT out of the keychain at check time; a beta build with no PAT set just sees
/// the same 404 it always would have, surfaced as `.checkFailed`.
struct GitHubUpdateFeed: UpdateFeed {
    /// The release LIST endpoint, not `/releases/latest` — channel selection (job 250) needs
    /// to see every recent release, prerelease or not, to pick the newest per channel.
    static let releasesListURL = URL(
        string: "https://api.github.com/repos/jonmichaels/soft-return/releases")!

    /// The human-facing releases page for the SAME repo `releasesListURL` queries via the API —
    /// job 264's CLI help page (`CLIHelpWindowController`) links here for the installer package.
    /// Derived from `releasesListURL` rather than a second repo-slug literal: the API and web
    /// paths for a GitHub repo's release list are identical past `/repos`
    /// (`/repos/{owner}/{repo}/releases` vs. `/{owner}/{repo}/releases`), so this can only drift
    /// from `releasesListURL` if that URL itself changes, not independently.
    static var releasesPageURL: URL {
        let webPath = releasesListURL.path.replacingOccurrences(of: "/repos/", with: "/")
        return URL(string: "https://github.com" + webPath)!
    }

    /// The repo's own front page — job 323's About window GitHub button. Derived from
    /// `releasesPageURL` the same non-drift way that URL is derived from `releasesListURL`:
    /// dropping the trailing `/releases` path component rather than a third repo-slug literal.
    static var repoPageURL: URL {
        releasesPageURL.deletingLastPathComponent()
    }

    /// Job 276: `GET /repos/{owner}/{repo}/releases/assets/{asset_id}` — the ONE endpoint that
    /// answers with the asset's actual bytes (redirected to a presigned storage URL) rather
    /// than a browser-facing HTML page. Built from `releasesListURL` the same way
    /// `releasesPageURL` is, so it can only drift if that URL itself changes.
    static func assetDownloadURL(id: Int) -> URL {
        releasesListURL.appendingPathComponent("assets").appendingPathComponent(String(id))
    }

    static let feedURLDefaultsKey = "SRUpdateFeedURL"
    static let feedJSONDefaultsKey = "SRUpdateFeedJSON"

    private let session: URLSession
    // UserDefaults is documented thread-safe but predates Sendable; Swift 6 strict concurrency
    // can't see that, so this is an `unsafe` annotation of a genuinely safe fact, not a real hole.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let tokenProvider: any UpdateTokenProvider

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        tokenProvider: any UpdateTokenProvider = KeychainUpdateTokenProvider()
    ) {
        self.session = session
        self.defaults = defaults
        self.tokenProvider = tokenProvider
    }

    func latestRelease(channel: UpdateChannel) async throws -> UpdateFeedRelease {
        try Self.selectRelease(from: try await fetchListData(), channel: channel)
    }

    private func fetchListData() async throws -> Data {
        // Inline JSON bypasses URLSession (and the sandbox layer beneath it) entirely — checked
        // first so it always wins when a console test sets both keys by accident. Neither
        // override knob ever needs a token: they don't touch the network path below at all.
        if let inline = defaults.string(forKey: Self.feedJSONDefaultsKey), !inline.isEmpty {
            guard let data = inline.data(using: .utf8) else { throw UpdateFeedError.badResponse }
            return data
        }

        let url = overrideURL() ?? Self.releasesListURL
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The token is never logged, never written to UserDefaults, never embedded in this
        // binary — it exists only as this one local `let`, read fresh from the keychain per
        // check, for the lifetime of building this one request.
        if let token = tokenProvider.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)

        // A `file://` request never produces an `HTTPURLResponse` — there is no HTTP status to
        // check — so only enforce the 2xx gate when the scheme actually has one. Absence of a
        // thrown error IS success for a file read; `selectRelease` below still rejects it if the
        // bytes aren't the expected JSON shape.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 401: throw UpdateFeedError.unauthorized
            case 404: throw UpdateFeedError.notFound
            default: throw UpdateFeedError.badResponse
            }
        }
        return data
    }

    /// `UserDefaults.url(forKey:)` is NOT what it sounds like here: given a plain string value
    /// it interprets it as a FILE PATH, not an arbitrary URL, so a stored `"https://…"` string
    /// would round-trip as a bogus file URL rather than the intended http one. Reading the raw
    /// string and parsing it with `URL(string:)` handles `https://` and `file://` alike, exactly
    /// as written by `defaults write … -string`.
    private func overrideURL() -> URL? {
        guard let raw = defaults.string(forKey: Self.feedURLDefaultsKey), !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    /// Split out from `fetchListData()` so the JSON shape can be exercised with fixture data and
    /// no network/UserDefaults at all — the whole point of testing this against a protocol.
    ///
    /// Explicit `CodingKeys`, not `.convertFromSnakeCase`: the automatic converter turns
    /// "html_url" into "htmlUrl", not "htmlURL" — it capitalizes each word after the first
    /// rather than recognizing an acronym, and a property named to match GitHub's own field
    /// would decode as nil against that.
    static func selectRelease(from data: Data, channel: UpdateChannel) throws -> UpdateFeedRelease {
        struct AssetItem: Decodable {
            let id: Int
            let name: String
            let size: Int
        }
        struct ListItem: Decodable {
            let tagName: String
            let htmlURL: URL
            let prerelease: Bool
            let assets: [AssetItem]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case prerelease
                case assets
            }

            // Job 276 adds `assets`; existing fixtures (job 250/251) predate that field and
            // carry no "assets" key at all — a plain synthesized decoder would throw
            // `keyNotFound` on every one of them. Treat an absent key the same as an empty
            // list rather than widen every existing fixture for a field they don't exercise.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tagName = try container.decode(String.self, forKey: .tagName)
                htmlURL = try container.decode(URL.self, forKey: .htmlURL)
                prerelease = try container.decode(Bool.self, forKey: .prerelease)
                assets = try container.decodeIfPresent([AssetItem].self, forKey: .assets) ?? []
            }
        }
        let items = try JSONDecoder().decode([ListItem].self, from: data)

        // Stable = newest non-prerelease; beta = newest overall, prerelease or not — a beta
        // build should still hear about a stable release that has since shipped. Job 278: a
        // rolling tag like "beta" (assets always newest, no version of its own) is filtered
        // out HERE, before comparison — not left to fall through `isNewer`'s parsing, which
        // would silently read "beta" as component {base: 0, beta: 0} and either lose every
        // real comparison by luck or (an empty/garbage-only list) win one it has no business
        // winning.
        let candidates = (channel == .stable ? items.filter { !$0.prerelease } : items)
            .filter { UpdateChecker.isVersionLike($0.tagName) }
        guard let newest = candidates.max(by: {
            UpdateChecker.isNewer(UpdateChecker.normalize($1.tagName), than: UpdateChecker.normalize($0.tagName))
        }) else {
            throw UpdateFeedError.noReleaseForChannel
        }

        // The release DMG, picked over any pkg/zip/source-archive asset the same release also
        // carries — the only shape this app knows how to hand to a user ("open the DMG and
        // drag to Applications"). `nil` when the release has none, which the alert treats as
        // "fall back to the releases page" rather than an error.
        let dmg = newest.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            .map { UpdateFeedAsset(id: $0.id, name: $0.name, size: $0.size) }
        // Job 313C: the CLI installer package, matched by its stable name exactly (case-
        // insensitively — GitHub's own asset listing is otherwise verbatim what was uploaded).
        let cli = newest.assets.first {
            $0.name.caseInsensitiveCompare(CLIHelpWindowController.installerPackageFilename) == .orderedSame
        }.map { UpdateFeedAsset(id: $0.id, name: $0.name, size: $0.size) }
        return UpdateFeedRelease(
            version: newest.tagName, downloadURL: newest.htmlURL, dmgAsset: dmg, cliAsset: cli)
    }
}

/// Job 251: where `GitHubUpdateFeed` gets the optional bearer token for its (now private,
/// per-repo) releases request. A protocol — not a bare function — purely so
/// `UpdateCheckerTests` can inject a fixed value and never touch the real keychain; production
/// has exactly one conformer, `KeychainUpdateTokenProvider`.
protocol UpdateTokenProvider: Sendable {
    /// `nil` means "no token available" — NOT an error. A beta tester who hasn't set one up
    /// yet should see the same 404-derived `.checkFailed` the endpoint would give anyway, not
    /// a crash or a different failure path.
    func token() -> String?
}

/// Reads a user-provisioned, fine-grained, read-only GitHub PAT out of the keychain — generic
/// password, service `"Soft Return Update Token"`, account `"github"`. This item is never
/// written by the app itself; a beta tester creates it once, per
/// `docs/check-for-updates-testing.md`, via `security add-generic-password` or Keychain
/// Access.app. The token is read fresh at check time via `SecItemCopyMatching` and is never
/// logged, never written to `UserDefaults`, and never appears anywhere in this app's source.
///
/// `com.apple.security.keychain-access-groups` is NOT in this app's entitlements and does not
/// need to be: that entitlement is for SHARING a keychain item across multiple apps/extensions
/// under one team, not for a single sandboxed app reading its own default access group, which
/// needs no extra entitlement at all. This job verified that claim empirically with a
/// same-process write+read test in `UpdateCheckerTests` (a sandboxed test host creating AND
/// reading its own generic-password item) rather than asserting it from the docs alone — see
/// that test's doc comment and the job report's LESSONS for the cross-process case (an item
/// created out-of-process by `security add-generic-password`), which is a materially different
/// keychain ACL question this same fact does not answer.
struct KeychainUpdateTokenProvider: UpdateTokenProvider {
    static let service = "Soft Return Update Token"
    static let account = "github"

    func token() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What "Check for Updates…" tells the user, and nothing about how it tells them — kept
/// separate from `NSAlert` so the comparison itself (the only part with real logic worth
/// getting wrong) is testable without presenting UI.
enum UpdateCheckResult: Equatable {
    case upToDate
    case updateAvailable(version: String, downloadURL: URL, dmgAsset: UpdateFeedAsset?)
    /// `authHint` is `true` when the feed failed with `.unauthorized`/`.notFound` specifically
    /// — the two outcomes a missing/bad/wrong-scope update token actually produces (job 251).
    /// `AppDelegate` uses it to append one extra sentence to the existing alert copy; every
    /// other failure (`badResponse`, `noReleaseForChannel`, a thrown `URLError`, …) leaves it
    /// `false` and the alert unchanged.
    case checkFailed(authHint: Bool)
}

/// Job 276: what tapping "Download" on an `.updateAvailable` alert actually does — kept as a
/// pure decision, same reasoning as `UpdateCheckResult` above, so "no DMG asset falls back to
/// the browser" is a testable fact rather than only observable by clicking the real alert.
enum UpdateDownloadAction: Equatable {
    case downloadAsset(UpdateFeedAsset)
    case openBrowser(URL)

    static func decide(dmgAsset: UpdateFeedAsset?, downloadURL: URL) -> UpdateDownloadAction {
        if let dmgAsset { return .downloadAsset(dmgAsset) }
        return .openBrowser(downloadURL)
    }
}

enum UpdateChecker {
    /// `CFBundleShortVersionString` vs. a fetched release: the whole comparison, pure and
    /// synchronous, so it is the thing unit tests exercise directly rather than only through
    /// `check(currentVersion:feed:)`'s network path.
    static func evaluate(current: String, latest: UpdateFeedRelease) -> UpdateCheckResult {
        let normalized = normalize(latest.version)
        return isNewer(normalized, than: normalize(current))
            ? .updateAvailable(version: normalized, downloadURL: latest.downloadURL, dmgAsset: latest.dmgAsset)
            : .upToDate
    }

    /// Strips a leading "v"/"V" — GitHub tags this repo's sibling as "v1.2.3"; the app's own
    /// `CFBundleShortVersionString` never carries one, and comparing "v1.2.3" against
    /// "1.2.3" as strings would call every release newer than the app forever.
    static func normalize(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    /// Job 278: does this tag actually parse as a version, in the exact grammar
    /// `VersionComponent` below understands — dot-separated components, each either all
    /// digits ("4", "0") or digits-b-digits ("13b2")? A rolling non-version tag like "beta"
    /// (the release repo's own "assets always newest" tag) must be skipped for version
    /// selection entirely rather than silently parsed: `VersionComponent`'s `Int(...) ?? 0`
    /// fallback would otherwise read "beta" as `{base: 0, beta: 0}` — a value, not an error —
    /// so nothing downstream would notice it was never a version at all.
    static func isVersionLike(_ tag: String) -> Bool {
        let parts = normalize(tag).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let lowered = part.lowercased()
            guard !lowered.isEmpty else { return false }
            if let bIndex = lowered.firstIndex(of: "b") {
                let base = lowered[lowered.startIndex..<bIndex]
                let beta = lowered[lowered.index(after: bIndex)...]
                return !base.isEmpty && base.allSatisfy(\.isNumber)
                    && !beta.isEmpty && beta.allSatisfy(\.isNumber)
            }
            return lowered.allSatisfy(\.isNumber)
        }
    }

    /// One dot-separated slice of a version string: a numeric base, and — for a beta build
    /// like "4.0.0b1" — the number after the `b`. `beta == nil` means a plain (release)
    /// component. Parsed case-insensitively so "4.0.0B1" and "4.0.0b1" compare identically.
    private struct VersionComponent {
        let base: Int
        let beta: Int?

        init(_ raw: Substring) {
            let lowered = raw.lowercased()
            if let bIndex = lowered.firstIndex(of: "b") {
                base = Int(lowered[lowered.startIndex..<bIndex]) ?? 0
                beta = Int(lowered[lowered.index(after: bIndex)...]) ?? 0
            } else {
                base = Int(lowered) ?? 0
                beta = nil
            }
        }

        private init(base: Int, beta: Int?) {
            self.base = base
            self.beta = beta
        }

        /// What a missing trailing component compares as — a plain "0", extending the
        /// existing "1.2" == "1.2.0" rule to beta components too.
        static let zero = VersionComponent(base: 0, beta: nil)
    }

    /// `nil` means the two components are equal; otherwise `true` means `x` is newer.
    /// Bases compare first; at equal bases a plain (release) component beats any beta one —
    /// "4.0.0" is newer than "4.0.0b1" — and between two betas at the same base the higher
    /// number wins — "4.0.0b2" is newer than "4.0.0b1".
    private static func isNewerComponent(_ x: VersionComponent, _ y: VersionComponent) -> Bool? {
        if x.base != y.base { return x.base > y.base }
        switch (x.beta, y.beta) {
        case (nil, nil): return nil
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(xBeta), .some(yBeta)): return xBeta == yBeta ? nil : xBeta > yBeta
        }
    }

    /// Component-wise comparison, missing trailing components treated as zero, so "1.2"
    /// counts as newer than "1.1.9" and "1.2.0" is equal to "1.2" — the two shapes a human
    /// actually writes for the same release. Each component may itself carry a beta suffix
    /// (see `VersionComponent`), so "4.0.0b1" and "4.0.0" compare honestly instead of the
    /// plain `Int()` parse that used to make them equal.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").map(VersionComponent.init)
        let bParts = b.split(separator: ".").map(VersionComponent.init)
        for index in 0..<max(aParts.count, bParts.count) {
            let x = index < aParts.count ? aParts[index] : .zero
            let y = index < bParts.count ? bParts[index] : .zero
            if let result = isNewerComponent(x, y) { return result }
        }
        return false
    }

    /// The one place a feed's network failure turns into `.checkFailed` rather than
    /// propagating — the menu command has nothing more specific to say about WHY the request
    /// failed, and the alert's copy is deliberately generic ("check your connection") rather
    /// than surfacing a `URLError` a 1987-document reader has no use for. A channel with
    /// nothing eligible (`noReleaseForChannel`) fails the same way — from the user's chair
    /// "the feed had nothing for me" and "the feed was unreachable" both mean "try again
    /// later", not "you're up to date". `.unauthorized`/`.notFound` (job 251: a missing or bad
    /// update token) are the one pair worth telling apart from the rest, via `authHint`.
    static func check(currentVersion: String, feed: UpdateFeed) async -> UpdateCheckResult {
        let channel = UpdateChannel.forVersion(currentVersion)
        do {
            let latest = try await feed.latestRelease(channel: channel)
            return evaluate(current: currentVersion, latest: latest)
        } catch UpdateFeedError.unauthorized, UpdateFeedError.notFound {
            return .checkFailed(authHint: true)
        } catch {
            return .checkFailed(authHint: false)
        }
    }
}
