import AppKit
import Testing
@testable import SoftReturn

/// Job 537 (rulings 20-21): the Sparkle 2 channel opt-in. `SparkleChannelPolicy` is the pure
/// mapping from the one preference to the set Sparkle's own `allowedChannelsForUpdater:`
/// contract expects; `AppDelegate.allowedChannels(for:)` is the thin delegate wiring on top of
/// it, exercised here against the REAL launch's updater the same way `SparkleInertnessTests`
/// already does (a reconstructed `AppDelegate` never received the real launch's Sparkle setup).
@Suite("Sparkle channel policy (job 537)")
struct SparkleChannelPolicyTests {

    // MARK: - Pure policy

    @Test func emptySetWhenBetaVersionsExcluded() {
        #expect(SparkleChannelPolicy.allowedChannels(includeBetaVersions: false).isEmpty)
    }

    @Test func betaChannelOnlyWhenBetaVersionsIncluded() {
        #expect(SparkleChannelPolicy.allowedChannels(includeBetaVersions: true) == ["beta"])
    }

    // MARK: - Delegate wiring, against the real launch's updater

    @MainActor
    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "SparkleChannelPolicyTests.\(UUID().uuidString)")!)
    }

    @Test @MainActor func appDelegateAllowedChannelsReflectsThePreferenceOff() throws {
        let delegate = try #require(
            NSApp.delegate as? AppDelegate,
            "NSApp.delegate is not the real AppDelegate -- this test must run hosted inside the real app launch")

        let original = SettingsStore.shared.includeBetaVersions
        defer { SettingsStore.shared.includeBetaVersions = original }

        SettingsStore.shared.includeBetaVersions = false
        #expect(try #require(delegate.allowedChannelsForTesting).isEmpty)
    }

    @Test @MainActor func appDelegateAllowedChannelsReflectsThePreferenceOn() throws {
        let delegate = try #require(
            NSApp.delegate as? AppDelegate,
            "NSApp.delegate is not the real AppDelegate -- this test must run hosted inside the real app launch")

        let original = SettingsStore.shared.includeBetaVersions
        defer { SettingsStore.shared.includeBetaVersions = original }

        SettingsStore.shared.includeBetaVersions = true
        #expect(try #require(delegate.allowedChannelsForTesting) == ["beta"])
    }
}
