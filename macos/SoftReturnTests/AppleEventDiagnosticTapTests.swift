import Foundation
import Testing
@testable import SoftReturn

/// `AppleEventDiagnosticTap` — job 174's raw `AEInstallEventHandler` tap for the -1708
/// investigation. These cover the record/ring logic only, with a throwaway `UserDefaults`
/// suite (never the real `me.beforeti.softreturn` domain the field machine's `defaults read`
/// verdict comes from) — the real Carbon `AEGetEventHandler`/`AEInstallEventHandler` calls are
/// exercised separately by `AppleEventDiagnosticTapSelfSendTests`, in-process, since they touch
/// real OS-level Apple Event Manager state that must not leak across these isolated tests.
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "AppleEventDiagnosticTapTests.\(UUID().uuidString)")!
}

@Test func recordInstallWritesInstalledAtAndPriorHandlerPresent() {
    let defaults = throwawayDefaults()

    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: true, defaults: defaults)

    let state = AppleEventDiagnosticTap.readState(defaults: defaults)
    #expect(state.installedAt != nil)
    #expect(state.priorHandlerPresent == true)
    #expect(state.arrivals.isEmpty)
    #expect(state.lastForwardResult == 0)
    #expect(state.installError == nil)
}

@Test func recordInstallWithFalsePriorHandlerPresent() {
    let defaults = throwawayDefaults()

    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: false, defaults: defaults)

    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).priorHandlerPresent == false)
}

@Test func recordInstallWithInstallErrorRecordsIt() {
    let defaults = throwawayDefaults()

    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: false, installError: -54, defaults: defaults)

    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).installError == -54)
}

@Test func recordArrivalAppendsATimestampReadableBack() {
    let defaults = throwawayDefaults()
    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: false, defaults: defaults)

    AppleEventDiagnosticTap.recordArrival(defaults: defaults)

    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).arrivals.count == 1)
}

@Test func arrivalsRingBufferDropsTheOldestPastCapacityTwenty() {
    let defaults = throwawayDefaults()
    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: false, defaults: defaults)

    for _ in 0..<25 {
        AppleEventDiagnosticTap.recordArrival(defaults: defaults)
    }

    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).arrivals.count == 20)
}

@Test func recordForwardResultOverwritesTheLatestValue() {
    let defaults = throwawayDefaults()
    AppleEventDiagnosticTap.recordInstall(priorHandlerPresent: false, defaults: defaults)

    AppleEventDiagnosticTap.recordForwardResult(-1708, defaults: defaults)
    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).lastForwardResult == -1708)

    AppleEventDiagnosticTap.recordForwardResult(0, defaults: defaults)
    #expect(AppleEventDiagnosticTap.readState(defaults: defaults).lastForwardResult == 0)
}

@Test func readStateOnAnEmptySuiteReturnsDefaults() {
    let defaults = throwawayDefaults()

    let state = AppleEventDiagnosticTap.readState(defaults: defaults)

    #expect(state.installedAt == nil)
    #expect(state.priorHandlerPresent == false)
    #expect(state.arrivals.isEmpty)
    #expect(state.lastForwardResult == 0)
    #expect(state.installError == nil)
}
