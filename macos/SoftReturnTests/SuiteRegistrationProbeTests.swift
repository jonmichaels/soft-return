#if DEBUG
import Foundation
import Testing
@testable import SoftReturn

/// Job 236 (-1708 dedup-dispatch investigation). Verifies the swizzle actually counts calls to
/// `NSScriptSuiteRegistry.loadSuites(from:)` — the instrument this job's A/B decision rests on —
/// rather than trusting it silently. `install()`'s swizzle is process-global and permanent by
/// design (see that type's header), so this suite only ever calls `install()` once, guarded the
/// same way the production code path is; every other test resets the LOG, not the swizzle.
@Suite struct SuiteRegistrationProbeTests {
    @Test func recordsOneCallPerLoadSuitesInvocation() {
        SuiteRegistrationProbe.install()
        SuiteRegistrationProbe.resetLog()

        let before = SuiteRegistrationProbe.callCount()
        NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
        let afterOne = SuiteRegistrationProbe.callCount()
        NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
        let afterTwo = SuiteRegistrationProbe.callCount()

        #expect(before == 0)
        #expect(afterOne == 1)
        #expect(afterTwo == 2)
    }

    @Test func resetLogClearsRecordedCalls() {
        SuiteRegistrationProbe.install()
        NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)
        #expect(SuiteRegistrationProbe.callCount() > 0)

        SuiteRegistrationProbe.resetLog()
        #expect(SuiteRegistrationProbe.callCount() == 0)
    }

    @Test func recordedCallCapturesACallerSymbol() {
        SuiteRegistrationProbe.install()
        SuiteRegistrationProbe.resetLog()
        NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)

        let calls = SuiteRegistrationProbe.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.callerSymbol.isEmpty == false)
    }
}
#endif
