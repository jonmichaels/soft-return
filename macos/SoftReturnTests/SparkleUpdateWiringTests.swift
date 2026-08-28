import AppKit
import Foundation
import Testing
@testable import SoftReturn

/// Job 532 (Jon's ruling: Sparkle IS in b34) — supersedes job 285's `SparkleInertnessTests.swift`,
/// which proved Sparkle was wired but permanently dormant. Sparkle is live now: `Info.plist`
/// carries a real `SUFeedURL`/`SUPublicEDKey`, and `AppDelegate.checkForUpdates(_:)` forwards
/// straight to `SPUStandardUpdaterController.checkForUpdates(_:)`. Two things still need proof:
/// 1. The exact plist values Jon specified are present, byte-for-byte — a silent edit here
///    would point every update check at the wrong feed or make signature verification fail.
/// 2. The real app launch actually built a controller that resolved that SAME feed URL from
///    Info.plist (not just that the key exists) — and that under THIS test host specifically it
///    stayed un-started (`AppDelegate`'s own `isTestHost` gate), so no test run ever risks
///    Sparkle's first-launch automatic-checks permission prompt (a real, blocking `NSAlert`) or
///    touches the network. Deliberately does NOT invoke `checkForUpdates(_:)` itself — same
///    restraint job 285's file used for the old GitHub-based IBAction, which "ends in
///    `NSAlert.runModal()` and would hang the test": calling into Sparkle's real menu action from
///    a test host is exactly the same category of risk and untested here for the same reason.

// MARK: - 1. Info.plist: the exact values, verbatim

@Test func infoPlistDeclaresTheExactSparkleFeedAndKey() {
    // v4-assembly merge (job 537, rulings 20-21): ONE public appcast on the public repo's
    // `main` branch, not a separate per-branch feed -- beta releases live in the same appcast,
    // tagged <sparkle:channel>beta</sparkle:channel>, admitted via AppDelegate's
    // allowedChannels(for:) delegate. Was `.../beta/appcast.xml` under job 532 alone.
    #expect(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ==
        "https://raw.githubusercontent.com/jonmichaels/soft-return/main/appcast.xml")
    #expect(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ==
        "kr6g0tYp6dxnphj1ALl88fhaVn2VWho+OAZpK239GB4=")
}

// MARK: - 2. State: the real launch built a controller wired to that same feed, dormant under test

@Test @MainActor func sparkleUpdaterResolvesTheDeclaredFeedButStaysDormantUnderTest() throws {
    let delegate = try #require(
        NSApp.delegate as? AppDelegate,
        "NSApp.delegate is not the real AppDelegate -- this test must run hosted inside the real app launch to mean anything")
    #expect(delegate.sparkleUpdaterExistsForTesting,
            "AppDelegate's real launch never constructed the Sparkle updater controller")
    #expect(delegate.sparkleFeedURLForTesting ==
        URL(string: "https://raw.githubusercontent.com/jonmichaels/soft-return/main/appcast.xml"),
            "the updater's own feedURL must resolve from Info.plist's SUFeedURL, not just exist there")
    // `XCTestConfigurationFilePath` is set for this very process, so `AppDelegate`'s own
    // `isTestHost` check must have kept `startingUpdater: false` here -- an unstarted updater
    // never reports itself checkable, regardless of how a real (non-test) launch would behave.
    #expect(!delegate.sparkleCanCheckForUpdatesForTesting,
            "an unstarted-under-test updater should not report itself checkable")
}
