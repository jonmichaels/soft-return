import Foundation
import Testing
@testable import SoftReturn

/// `ScriptingRegistryProbe` — job 181 Part 1's -1708 investigation aid. Executed-path, like
/// `AppleEventDispatchTests`: `SoftReturnTests` is HOST-APP-hosted (`TEST_HOST` points at
/// `Soft Return.app`), so `NSScriptSuiteRegistry.shared()` here is the real, live registry the
/// app itself builds, not a fake. A throwaway `UserDefaults` suite keeps the write off the real
/// `me.beforeti.softreturn` domain, matching `AppleEventDiagnosticTapTests`'s isolation.
///
/// Deliberately does NOT assert `ourSuitePresent`/`convertCommandPresent`/the class-resolution
/// booleans one way or the other — those verdicts are exactly what this probe exists to surface
/// on the field machine; asserting a value here would bake in a guess about the very bug it is
/// meant to discover. What IS asserted: the probe runs to completion and writes a record, and
/// that record actually contains the registry's suite list — the minimum needed for the record
/// to be useful evidence at all.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ScriptingRegistryProbeTests.\(UUID().uuidString)")!
}

@Test func runWritesARecordContainingTheSuiteList() {
    NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
    let defaults = throwawayDefaults()

    ScriptingRegistryProbe.run(defaults: defaults)

    let state = ScriptingRegistryProbe.readState(defaults: defaults)
    #expect(state != nil)
    #expect((state?.suiteNames.isEmpty ?? true) == false)
    // "Standard Suite" registers via AppKit's own `<cocoa name="NSCoreSuite"/>` inclusion
    // regardless of the -1708 bug under investigation — a non-empty list that is missing even
    // this would mean the registry never loaded at all, a different and worse failure than the
    // one this probe is chasing.
    #expect(state?.suiteNames.contains("Standard Suite") == true)
    #expect(state?.recordedAt != nil)
}

@Test func readStateOnAnEmptySuiteReturnsNil() {
    let defaults = throwawayDefaults()

    #expect(ScriptingRegistryProbe.readState(defaults: defaults) == nil)
}

@Test func runIsSafeToCallTwiceAndTheSecondRecordOverwritesTheFirst() {
    NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
    let defaults = throwawayDefaults()

    ScriptingRegistryProbe.run(defaults: defaults)
    let first = ScriptingRegistryProbe.readState(defaults: defaults)
    ScriptingRegistryProbe.run(defaults: defaults)
    let second = ScriptingRegistryProbe.readState(defaults: defaults)

    #expect(first != nil)
    #expect(second != nil)
    #expect((second?.recordedAt ?? .distantPast) >= (first?.recordedAt ?? .distantPast))
}
