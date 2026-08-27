import Testing
import Foundation
@testable import SoftReturn

/// The About panel's version line carries WordStar's soft-return byte pair (8D0A) as a
/// deliberate easter egg — this pins the display string so a future version bump can't drop it
/// by accident.
///
/// The expected version comes from the test host's OWN Info.plist, never a literal: Jon's
/// versioning rule bumps MARKETING_VERSION on every published build, and a hardcoded "4.0.0b1"
/// broke on the very first bump (b2, 2026-08-08). These tests pin the SHAPE and the wiring,
/// not the number.

private var hostMarketingVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}

@Test func aboutVersionStringCarriesMarketingVersionAndSoftReturnByte() {
    #expect(AboutInfo.versionString.contains(hostMarketingVersion))
    #expect(AboutInfo.versionString.contains("8D0A"))
    #expect(AboutInfo.versionString == "Soft Return \(AboutInfo.displayVersion(for: hostMarketingVersion)) (8D0A)")
}

@Test func standardAboutPanelOptionsCarryTheSameVersionAndByte() {
    let options = AboutInfo.standardAboutPanelOptions
    #expect(options[.applicationVersion] as? String == AboutInfo.displayVersion(for: hostMarketingVersion))
    #expect(options[.version] as? String == "8D0A")
}

@Test func displayVersionDropsTheBetaWordWhenTheVersionAlreadyCarriesABetaSuffix() {
    #expect(AboutInfo.displayVersion(for: "4.0.0b1") == "4.0.0b1")
    #expect(AboutInfo.displayVersion(for: "4.0.0B3") == "4.0.0B3")
    // The bN suffix already says "beta" — spelling it out too would be redundant.
    #expect(!AboutInfo.displayVersion(for: "4.0.0b7").contains("beta"))
}

@Test func displayVersionAppendsTheBetaWordWhenTheVersionHasNoBetaSuffix() {
    #expect(AboutInfo.displayVersion(for: "4.0.0") == "4.0.0 beta")
    #expect(AboutInfo.displayVersion(for: "4.1.2") == "4.1.2 beta")
}
