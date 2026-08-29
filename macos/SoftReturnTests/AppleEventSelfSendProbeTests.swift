import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 235. Unlike `AppleEventDiagnosticTapSelfSendTests`, this suite never triggers a real
/// `AESendMessage` — job 174 already found that a self-addressed send run inside this same
/// sandboxed test host crashes the process outright (Signal 11), which is exactly why
/// `AppleEventSelfSendProbe` requires two explicit, independent opt-ins
/// (`SRDiagnosticsGate` + its own `SRSelfSendProbe` environment flag) before it will ever call
/// `perform()`. These tests only exercise the gate logic (both must be true before anything
/// runs) and the `State`/`UserDefaults` round trip — the real send is verified on the field
/// machine, per this job's brief, not here.
@Suite struct AppleEventSelfSendProbeTests {
    @Test func doesNothingWhenGateDisabledEvenWithEnvFlagSet() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        AppleEventSelfSendProbe.runIfRequested(environment: ["SRSelfSendProbe": "1"], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readState(defaults: defaults) == nil)
    }

    @Test func doesNothingWhenGateEnabledButEnvFlagMissing() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: SRDiagnosticsGate.defaultsKey)
        AppleEventSelfSendProbe.runIfRequested(environment: [:], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readState(defaults: defaults) == nil)
    }

    @Test func doesNothingWhenBothGatesEnabledViaDefaultsOnlyWithoutEnvFlag() {
        // `SRDiagnosticsGate` itself can be satisfied via `UserDefaults` (a human's
        // `defaults write ... SRDiagnostics -bool YES`), but this probe's own flag is
        // environment-only by design — a defaults-only activation of the shared gate must not
        // be enough on its own to fire the higher-risk self-send.
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: SRDiagnosticsGate.defaultsKey)
        defaults.set(true, forKey: "SRSelfSendProbe")
        AppleEventSelfSendProbe.runIfRequested(environment: [:], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readState(defaults: defaults) == nil)
    }

    @Test func stateRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        let state = AppleEventSelfSendProbe.State(
            ranAt: Date(), buildConfiguration: "DEBUG", pid: 123, fixturePresent: false,
            sendStatus: -1708, replyErrorNumber: -1708, replyErrorString: "errAEEventNotHandled",
            outputProduced: false, outputPath: nil, outputDetail: nil,
            constructedBreadcrumbFired: false, performDefaultImplementationBreadcrumbFired: false,
            registrySuiteNames: ["Standard Suite", "Soft Return Suite"],
            registrySoftReturnSuitePresent: true, registryConvertCommandPresent: true,
            registryConvertCommandClassResolves: true, registryModuleQualifiedClassResolves: true,
            registryBareClassResolves: false,
            handlerInstalledBeforeSend: true, handlerPointerBeforeSend: "0x0000000100000000",
            handlerInstalledAfterSend: true, handlerPointerAfterSend: "0x0000000100000000",
            loadSuitesCallCountAtSend: 1,
            sendMonotonicUptime: 1000.5, returnMonotonicUptime: 1000.75,
            replyDescriptorDump: "aevt\nansr{ }\n",
            replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
            dispatchLayerCalls: [
                AppleEventLayerCall(monotonic: 1000.6, originalReturn: -1708, replyErrorNumber: -1708, replyErrorString: "errAEEventNotHandled"),
            ],
            rawProcLayerCalls: [
                AppleEventLayerCall(monotonic: 1000.55, originalReturn: 0, replyErrorNumber: nil, replyErrorString: nil),
            ])

        AppleEventSelfSendProbe.record(state, defaults: defaults)

        #expect(AppleEventSelfSendProbe.readState(defaults: defaults) == state)
    }

    @Test func readStateReturnsNilWhenNothingRecorded() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        #expect(AppleEventSelfSendProbe.readState(defaults: defaults) == nil)
    }

    // MARK: - Job 252 (`ae-all-verbs`): export/diagnose/import page settings

    /// Same rationale as `doesNothingWhenGateDisabledEvenWithEnvFlagSet` above — the real send
    /// is verified on the field machine (job 252's brief), this only exercises the gate.
    @Test func otherVerbsDoNothingWhenGateDisabledEvenWithEnvFlagSet() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        AppleEventSelfSendProbe.runOtherVerbsIfRequested(environment: ["SRSelfSendProbe": "1"], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readState(verb: "export", defaults: defaults) == nil)
        #expect(AppleEventSelfSendProbe.readState(verb: "diagnose", defaults: defaults) == nil)
        #expect(AppleEventSelfSendProbe.readState(verb: "importPageSettings", defaults: defaults) == nil)
    }

    @Test func otherVerbsDoNothingWhenGateEnabledButEnvFlagMissing() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: SRDiagnosticsGate.defaultsKey)
        AppleEventSelfSendProbe.runOtherVerbsIfRequested(environment: [:], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readState(verb: "export", defaults: defaults) == nil)
    }

    @Test func verbStateRoundTripsThroughDefaultsForEachVerb() {
        for verb in ["export", "diagnose", "importPageSettings"] {
            let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
            let state = AppleEventSelfSendProbe.VerbState(
                verb: verb, ranAt: Date(), buildConfiguration: "DEBUG", pid: 123, fixturePresent: true,
                sendStatus: 0, replyErrorNumber: nil, replyErrorString: nil,
                replyDescriptorDump: "aevt\nansr{ }\n",
                replyAEResultPresent: true, replyAEResultType: "TEXT", replyAEResultStringValue: "{}",
                sideEffectVerified: true, sideEffectDetail: "reply parsed as JSON, 2 chars")

            AppleEventSelfSendProbe.record(state, defaults: defaults)

            #expect(AppleEventSelfSendProbe.readState(verb: verb, defaults: defaults) == state)
        }
    }

    @Test func verbReadStateReturnsNilWhenNothingRecorded() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        #expect(AppleEventSelfSendProbe.readState(verb: "export", defaults: defaults) == nil)
    }

    // MARK: - Job 253 (`convert-destination`): the bare-destination arbiter

    /// Same rationale as `doesNothingWhenGateDisabledEvenWithEnvFlagSet` above — the real send
    /// (against a fixture staged OUTSIDE the container) is the field/console arbiter, this
    /// only exercises the gate.
    @Test func bareDestinationDoesNothingWhenGateDisabledEvenWithEnvFlagSet() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        AppleEventSelfSendProbe.runBareDestinationProbeIfRequested(environment: ["SRSelfSendProbe": "1"], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readBareDestinationState(defaults: defaults) == nil)
    }

    @Test func bareDestinationDoesNothingWhenGateEnabledButEnvFlagMissing() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: SRDiagnosticsGate.defaultsKey)
        AppleEventSelfSendProbe.runBareDestinationProbeIfRequested(environment: [:], defaults: defaults)
        #expect(AppleEventSelfSendProbe.readBareDestinationState(defaults: defaults) == nil)
    }

    @Test func bareDestinationStateRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        let state = AppleEventSelfSendProbe.BareDestinationState(
            ranAt: Date(), buildConfiguration: "DEBUG", pid: 123, fixturePresent: true,
            sendStatus: 0, replyErrorNumber: nil, replyErrorString: nil,
            replyDescriptorDump: "aevt\nansr{ }\n",
            besideSourceOutputExists: true, besideSourceOutputPath: "/tmp/AESelfSendProbeOutsideFixture/OLDTIMES.rtf",
            containerOutputExists: false, containerOutputPath: "/some/container/Documents/OLDTIMES.rtf")

        AppleEventSelfSendProbe.record(state, defaults: defaults)

        #expect(AppleEventSelfSendProbe.readBareDestinationState(defaults: defaults) == state)
    }

    @Test func bareDestinationReadStateReturnsNilWhenNothingRecorded() {
        let defaults = UserDefaults(suiteName: "AppleEventSelfSendProbeTests.\(UUID().uuidString)")!
        #expect(AppleEventSelfSendProbe.readBareDestinationState(defaults: defaults) == nil)
    }
}

/// Job 458 (b28 note 5, Jon's ruling): the PASS/FAIL contract itself. Jon ran the probe on b27
/// and found the missing-fixture guard returning `sendStatus: 0` — the exact value the OLD
/// RUNBOOK told a human to treat as success — so a leg with NO subject read as a pass. These
/// tests pin `State.passed`/`.humanLine` and `VerbState.passed`/`.humanLine` directly against
/// hand-built states (never a real `AESendMessage` — job 174's crash precedent, same rationale
/// as every other test in this file), because that computed contract, not the send itself, is
/// what this job rebuilt. `missingSubjectWithSendStatusZeroIsNeverAPass` is Jon's own bug
/// report reproduced as data: before this job, nothing in this file computed `passed` at all —
/// a caller had only `sendStatus`, and `sendStatus == 0` for a missing fixture is precisely the
/// silent-pass bug. Toggling `passed` back to that literal old contract (`sendStatus == 0`
/// alone) makes every test in this suite that asserts `== false` on a missing/unverified state
/// fail — that is the fail-before state this job's evidence law requires; restoring the real
/// three-part expression (`fixturePresent && sendStatus == 0 && <side effect verified>`) is
/// what makes them pass again.
@Suite struct AppleEventSelfSendProbePassFailContractTests {

    private func convertState(
        fixturePresent: Bool, sendStatus: Int32, outputProduced: Bool,
        outputDetail: String? = nil, replyErrorString: String? = nil
    ) -> AppleEventSelfSendProbe.State {
        AppleEventSelfSendProbe.State(
            ranAt: Date(), buildConfiguration: "DEBUG", pid: 1, fixturePresent: fixturePresent,
            sendStatus: sendStatus, replyErrorNumber: nil, replyErrorString: replyErrorString,
            outputProduced: outputProduced, outputPath: nil, outputDetail: outputDetail,
            constructedBreadcrumbFired: false, performDefaultImplementationBreadcrumbFired: false,
            registrySuiteNames: [], registrySoftReturnSuitePresent: false,
            registryConvertCommandPresent: false, registryConvertCommandClassResolves: false,
            registryModuleQualifiedClassResolves: false, registryBareClassResolves: false,
            handlerInstalledBeforeSend: false, handlerPointerBeforeSend: nil,
            handlerInstalledAfterSend: false, handlerPointerAfterSend: nil,
            loadSuitesCallCountAtSend: nil, sendMonotonicUptime: nil, returnMonotonicUptime: nil,
            replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
            replyAEResultStringValue: nil, dispatchLayerCalls: nil, rawProcLayerCalls: nil)
    }

    /// THE regression this job exists to close, reproduced as data. See this suite's own
    /// header for why toggling `State.passed` back to `sendStatus == 0` alone is what makes
    /// this specific test fail — that toggle IS the pre-fix state.
    @Test func missingSubjectWithSendStatusZeroIsNeverAPass() {
        let missing = convertState(fixturePresent: false, sendStatus: 0, outputProduced: false,
                                    replyErrorString: "no bundled sample document available")
        #expect(missing.passed == false,
                "a missing subject must never read PASS, even at sendStatus==0 — this is Jon's b27 bug reproduced")
        #expect(missing.humanLine.hasPrefix("convert: FAIL"))
        #expect(!missing.humanLine.contains("PASS"))
    }

    @Test func cleanSendWithUnverifiedSideEffectIsNotAPass() {
        let noSideEffect = convertState(fixturePresent: true, sendStatus: 0, outputProduced: false,
                                         outputDetail: "output file at /tmp/x.rtf is missing or empty")
        #expect(noSideEffect.passed == false)
        #expect(noSideEffect.humanLine == "convert: FAIL — output file at /tmp/x.rtf is missing or empty")
    }

    @Test func nonZeroSendStatusIsNotAPassEvenWithFixturePresent() {
        let sendFailed = convertState(fixturePresent: true, sendStatus: -1708, outputProduced: false,
                                       replyErrorString: "errAEEventNotHandled")
        #expect(sendFailed.passed == false)
        #expect(sendFailed.humanLine.hasPrefix("convert: FAIL"))
        #expect(sendFailed.humanLine.contains("-1708"))
    }

    @Test func allThreeConditionsTogetherIsTheOnlyPass() {
        let real = convertState(fixturePresent: true, sendStatus: 0, outputProduced: true,
                                 outputDetail: "RTF output verified: 512 bytes, valid RTF header at /tmp/x.rtf")
        #expect(real.passed == true)
        #expect(real.humanLine == "convert: PASS — RTF output verified: 512 bytes, valid RTF header at /tmp/x.rtf")
    }

    // MARK: - Same three-part contract for the diagnose/export/exportNativeStyle/importPageSettings legs

    private func verbState(
        verb: String, fixturePresent: Bool, sendStatus: Int32, sideEffectVerified: Bool,
        sideEffectDetail: String? = nil, replyErrorString: String? = nil
    ) -> AppleEventSelfSendProbe.VerbState {
        AppleEventSelfSendProbe.VerbState(
            verb: verb, ranAt: Date(), buildConfiguration: "DEBUG", pid: 1, fixturePresent: fixturePresent,
            sendStatus: sendStatus, replyErrorNumber: nil, replyErrorString: replyErrorString,
            replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
            replyAEResultStringValue: nil, sideEffectVerified: sideEffectVerified, sideEffectDetail: sideEffectDetail)
    }

    @Test func verbLegsMissingSubjectWithSendStatusZeroIsNeverAPass() {
        for verb in ["diagnose", "export", "exportNativeStyle", "importPageSettings"] {
            let missing = verbState(verb: verb, fixturePresent: false, sendStatus: 0, sideEffectVerified: false)
            #expect(missing.passed == false, "\(verb): missing subject must never read PASS")
            #expect(missing.humanLine.hasPrefix("\(verb): FAIL"), "\(verb): humanLine must lead with FAIL")
        }
    }

    @Test func verbLegsUnverifiedSideEffectIsNotAPass() {
        let unverified = verbState(verb: "export", fixturePresent: true, sendStatus: 0, sideEffectVerified: false,
                                    sideEffectDetail: "output file at /tmp/x.rtf is missing or empty")
        #expect(unverified.passed == false)
    }

    @Test func verbLegsNonZeroSendStatusIsNotAPass() {
        let sendFailed = verbState(verb: "diagnose", fixturePresent: true, sendStatus: -1708,
                                    sideEffectVerified: false, replyErrorString: "errAEEventNotHandled")
        #expect(sendFailed.passed == false)
        #expect(sendFailed.humanLine.hasPrefix("diagnose: FAIL"))
    }

    @Test func verbLegsAllThreeConditionsTogetherIsTheOnlyPass() {
        let real = verbState(verb: "diagnose", fixturePresent: true, sendStatus: 0, sideEffectVerified: true,
                              sideEffectDetail: "reply parsed as JSON, 42 chars")
        #expect(real.passed == true)
        #expect(real.humanLine == "diagnose: PASS — reply parsed as JSON, 42 chars")
    }

    // MARK: - fixtureURL is bundle-resolved — Jon: "There are 4 embedded WS files in the app.
    // Test those." No hand-placed file may be required for a fresh install to run this leg.

    @Test func fixtureURLResolvesToABundledSampleDocumentNotAHandPlacedPath() {
        let expected = SampleDocuments.items(bundle: .main).first?.url
        #expect(expected != nil, "the real app bundle must ship at least one sample document")
        #expect(AppleEventSelfSendProbe.fixtureURL == expected,
                "fixtureURL must resolve from the app's own bundle, never require a hand-placed file")
        #expect(!AppleEventSelfSendProbe.fixtureURL.path.contains("AESelfSendProbeFixture"),
                "must not fall back to the old hand-placed $TMPDIR path while the bundle has samples")
    }

    // MARK: - Job 490 item 6: bareDestination gets the SAME PASS/FAIL-in-words contract

    private func bareDestinationState(
        fixturePresent: Bool, sendStatus: Int32 = 0, replyErrorString: String? = nil,
        besideSourceOutputExists: Bool = false, besideSourceOutputPath: String = "",
        containerOutputExists: Bool = false, containerOutputPath: String = ""
    ) -> AppleEventSelfSendProbe.BareDestinationState {
        AppleEventSelfSendProbe.BareDestinationState(
            ranAt: Date(), buildConfiguration: "DEBUG", pid: 1, fixturePresent: fixturePresent,
            sendStatus: sendStatus, replyErrorNumber: nil, replyErrorString: replyErrorString,
            replyDescriptorDump: nil,
            besideSourceOutputExists: besideSourceOutputExists, besideSourceOutputPath: besideSourceOutputPath,
            containerOutputExists: containerOutputExists, containerOutputPath: containerOutputPath)
    }

    /// THE bug this job's brief names directly: "when `SRSelfSendOutsideFixture` is absent,
    /// the `bareDestination` leg logs a line with NO PASS and NO FAIL." Reproduced as data —
    /// before this job's fix, `BareDestinationState` had no `passed`/`humanLine` at all, so a
    /// caller had only the neutral fact dump (`fixturePresent=false`, every other field a
    /// blank/zero default) with no verdict anywhere in it.
    @Test func missingOutsideFixtureIsALoudFailNotASilentBlank() {
        let missing = bareDestinationState(fixturePresent: false, replyErrorString: nil)
        #expect(missing.passed == false)
        #expect(missing.humanLine.hasPrefix("bareDestination: FAIL"),
                "an absent SRSelfSendOutsideFixture must read FAIL, not a blank neutral line")
        #expect(missing.humanLine.contains("SRSelfSendOutsideFixture"),
                "the FAIL line must say WHAT is missing, per the brief's own wording")
        #expect(!missing.humanLine.contains("PASS"))
    }

    @Test func nonZeroSendStatusIsABareDestinationFail() {
        let sendFailed = bareDestinationState(fixturePresent: true, sendStatus: -1708,
                                               replyErrorString: "errAEEventNotHandled")
        #expect(sendFailed.passed == false)
        #expect(sendFailed.humanLine.hasPrefix("bareDestination: FAIL"))
        #expect(sendFailed.humanLine.contains("-1708"))
    }

    /// The probe's own documented critical invariant (`BareDestinationState`'s own doc
    /// comment: "the ONE outcome that must be impossible") — a completed run that violates
    /// it is a real bug, not a missing-fixture non-run, and must read FAIL just as loudly.
    @Test func outputLandingInTheContainerFallbackIsABareDestinationFailEvenAtSendStatusZero() {
        let regressed = bareDestinationState(
            fixturePresent: true, sendStatus: 0,
            containerOutputExists: true, containerOutputPath: "/some/container/Documents/OLDTIMES.rtf")
        #expect(regressed.passed == false)
        #expect(regressed.humanLine.hasPrefix("bareDestination: FAIL"))
        #expect(regressed.humanLine.contains("container"))
    }

    @Test func realCompletedRunWithNoContainerFallbackIsTheOnlyBareDestinationPass() {
        let real = bareDestinationState(
            fixturePresent: true, sendStatus: 0,
            besideSourceOutputExists: true, besideSourceOutputPath: "/tmp/AESelfSendProbeOutsideFixture/OLDTIMES.rtf",
            containerOutputExists: false)
        #expect(real.passed == true)
        #expect(real.humanLine.hasPrefix("bareDestination: PASS"))
    }
}
