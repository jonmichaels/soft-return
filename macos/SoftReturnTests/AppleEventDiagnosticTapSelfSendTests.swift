import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 174: does the raw `AEInstallEventHandler` tap actually see an event arrive, exercised
/// in-process?
///
/// The brief asked for a self-addressed `AESendMessage` probe (the only mechanism that
/// actually reaches our raw handler — `NSAppleEventManager.dispatchRawAppleEvent`, used by
/// `AppleEventVirginDispatchTests`/`AppleEventDispatchTests`, is a Cocoa-level shortcut that
/// "bypasses entirely" the OS's real Apple Event Manager dispatch path, per
/// `AppleEventSelfTest`'s doc comment). It was tried here first and REMOVED: `SoftReturnTests`
/// is a `.unitTests` bundle hosted inside `Soft Return.app` (see `Project.swift`'s
/// `testsTarget` — `dependencies: [.target(name: "SoftReturn")]`, loaded via
/// `-bundle_loader ".../Soft Return.app/..."`), so it runs under the SAME
/// `SoftReturn-Debug.entitlements` App Sandbox as the shipped app — it is NOT the unsandboxed
/// host this file originally assumed. A self-addressed `AESendMessage` there hit exactly the
/// failure mode `.claude/skills/macos-document-app/references/field-notes.md`'s 2026-08-09
/// "-1708 probe-class exhaustion" entry warns about ("Self-addressed AESendMessage from a
/// SANDBOXED app may test the sandbox's SEND policy, not receive dispatch") — except worse than
/// a graceful -1708: it crashed the host process (`Signal 11`, `xcresult` issue "Crash: Soft
/// Return at <external symbol>"), taking the whole test run down with it. Per the job-174
/// brief's own fallback ("if it does not [work], do not burn the job on it: assert install-time
/// records only... and say plainly in the report which assertions executed") and the
/// job-sizing policy (`docs/RUNBOOK.md`, ~30 min/job), this was not chased further — a crash is
/// itself evidence for the report, not something to spend the rest of the job symbolicating.
///
/// So: ONLY the install-time assertions below actually executed for this job. No arrival
/// assertion runs anywhere in this suite; the field verdict for "does an arrival ever get
/// recorded" rests entirely on `defaults read me.beforeti.softreturn aeDiagnostics.tap` against
/// the real, sandboxed, cross-process `osascript` case the tap exists to observe.
///
/// This test still installs a REAL raw handler for `('SRsu','conv')` via
/// `AppleEventDiagnosticTap.install` — genuine, process-wide Carbon AE Manager state — for the
/// remainder of this test-host process. Harmless: nothing else in this test target sends or
/// receives that event class/ID via the raw Apple Event Manager.
@Suite struct AppleEventDiagnosticTapSelfSendTests {
    @Test @MainActor func installRecordsInstalledAtAndPriorHandlerPresent() {
        let defaults = UserDefaults(suiteName: "AppleEventDiagnosticTapSelfSendTests.\(UUID().uuidString)")!

        AppleEventDiagnosticTap.install(defaults: defaults)

        let state = AppleEventDiagnosticTap.readState(defaults: defaults)
        #expect(state.installedAt != nil, "install-time record must always be written")
        #expect(state.arrivals.isEmpty, "no event has been sent in this test")
        // `priorHandlerPresent` itself is not asserted true/false: in this shared test-host
        // process it is a fact about whatever earlier tests in the same run already touched
        // `NSScriptSuiteRegistry`, not a property of this test — see the decision table in the
        // job-174 report for what each value means on the field machine, where launch order is
        // fixed and known.
    }
}
