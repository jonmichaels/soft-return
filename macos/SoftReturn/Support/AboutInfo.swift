import AppKit

/// The About panel's version line, and the string the unit tests check.
///
/// "8D0A" is WordStar's own soft-return byte pair (0x8D 0x0A) — the app's namesake, and its
/// easter egg here. The FULL `MARKETING_VERSION` (e.g. "4.0.0b1") shows here, not a truncated
/// major.minor — that is the point of the beta version scheme: Jon needs to tell one dev
/// build apart from the next, which "4.0" alone cannot do.
enum AboutInfo {
    static let softReturnByte = "8D0A"

    /// The raw `MARKETING_VERSION`, e.g. "4.0.0b1" — never truncated.
    static var fullMarketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.0b1"
    }

    /// What to actually show next to the app name: the version as-is when it already carries
    /// a `bN` beta marker (spelling out "beta" too would be redundant), otherwise the version
    /// with " beta" appended, same as before this scheme existed.
    static func displayVersion(for marketingVersion: String) -> String {
        hasBetaSuffix(marketingVersion) ? marketingVersion : "\(marketingVersion) beta"
    }

    /// Matched case-insensitively against the trailing `bN` — "4.0.0b1" and "4.0.0B1" both
    /// count.
    private static func hasBetaSuffix(_ version: String) -> Bool {
        version.range(of: "b[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Soft Return 4.0.0b1 (8D0A)" — what the About panel's version line reads as a whole.
    static var versionString: String {
        "Soft Return \(displayVersion(for: fullMarketingVersion)) (\(softReturnByte))"
    }

    /// Options for `NSApplication.orderFrontStandardAboutPanel(options:)`. The standard panel
    /// renders these as "Version <applicationVersion> (<version>)", which is what turns into
    /// "Version 4.0.0b1 (8D0A)" under the app name and icon.
    static var standardAboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationVersion: displayVersion(for: fullMarketingVersion),
            .version: softReturnByte,
        ]
    }
}
