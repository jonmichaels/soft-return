import Foundation

/// Job 537 (rulings 20-21): which Sparkle 2 channels this build is allowed to see updates in,
/// derived from the one user-facing preference (`SettingsStore.includeBetaVersions`) — kept as
/// a pure function, same reasoning `UpdateChecker`'s own decision points already follow, so the
/// mapping is testable without a real `SPUUpdater`/`AppDelegate` launch.
///
/// Sparkle's own contract (`SPUUpdaterDelegate.allowedChannelsForUpdater(_:)`): an empty set
/// means "default channel only" — untagged appcast items, i.e. stable. Returning `["beta"]`
/// additionally allows items the appcast tags `<sparkle:channel>beta</sparkle:channel>`; it
/// does not exclude the default channel, so a beta opt-in still sees stable releases too.
enum SparkleChannelPolicy {
    static let betaChannel = "beta"

    static func allowedChannels(includeBetaVersions: Bool) -> Set<String> {
        includeBetaVersions ? [betaChannel] : []
    }
}
