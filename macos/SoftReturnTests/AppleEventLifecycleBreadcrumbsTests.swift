import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 199 (b10 leg 1b, continuing 143-198). Jobs 143-198 exhausted every in-process
/// reproduction of the field -1708, including a byte-exact replay of the real captured event
/// (job 198's `ConvertCommandReceiverDispatchTests` extension) — the failure provably requires
/// a real cross-process delivery. `ConvertCommand`'s new lifecycle breadcrumbs (this job) exist
/// to be read back on the FIELD machine after a real failure, not to reproduce anything here.
///
/// This test does not attempt reproduction. It drives the same known-good, in-process dispatch
/// path job 143/185 already established succeeds (`NSAppleEventManager.dispatchRawAppleEvent`,
/// see `AppleEventDispatchTests.inProcessConvertAppleEventProducesAnRTFFile`) and proves the
/// breadcrumb instrumentation itself fires, in the right order, for a dispatch that reaches
/// every override point cleanly — so that when the field machine's real delivery is read back
/// and stops SOMEWHERE SHORT of this same sequence, that's trustworthy signal, not an artifact
/// of the instrumentation itself being unreliable.
///
/// Job 219: `AppleEventLifecycleBreadcrumbs.record` is now a no-op unless `SRDiagnosticsGate`
/// is on (see that type's header) — this suite used to get breadcrumbs for free because the
/// instrumentation was always-on in every build. The test below now activates the gate
/// explicitly via `UserDefaults.standard` (the same domain `record`'s default parameter reads,
/// since — per the existing comment below — there is no per-test injection point for this
/// type) and restores it afterward, rather than depending on release/default behavior.
///
/// Job 222 (scriptcommand-exemplar-shape): `ConvertCommand` no longer overrides `execute()`,
/// so the `executeCommand-entered`/`executeCommand-returned` stages this suite used to check
/// are gone — only `constructed` (init) and `pdi-entered` (performDefaultImplementation, the
/// one exemplar-sanctioned override) remain. See `ConvertCommand`'s own doc comment and
/// `docs/reference/apple/scriptcommand-exemplars-packet.md`.
/// Job 535: this suite's one test reads `MultipageMargins.testDocsDirectory` (`ws4/INDIAN.ws`)
/// — gated at the suite level so a bare stranger run skips cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct AppleEventLifecycleBreadcrumbsTests {

    /// Subsequence check rather than strict equality: `AppleEventLifecycleBreadcrumbs` writes to
    /// the shared `UserDefaults.standard` domain (same as `ConvertCommand`'s real override
    /// points — there is no per-test injection point, unlike `AppleEventDiagnosticTap`'s
    /// `defaults:` parameter), so a full-suite run may interleave breadcrumbs from OTHER tests
    /// that also dispatch `convert` events (e.g. `ConvertCommandReceiverDispatchTests`)
    /// concurrently with this one. A subsequence check tolerates that interleaving while still
    /// requiring this test's own stages to appear in the right relative order.
    private static func containsInOrder(_ needle: [String], within haystack: [String]) -> Bool {
        var index = 0
        for stage in haystack {
            guard index < needle.count else { break }
            if stage == needle[index] { index += 1 }
        }
        return index == needle.count
    }

    @Test @MainActor func inProcessDispatchRecordsLifecycleBreadcrumbsInOrder() throws {
        // Job 219: `record` is inert unless this gate is on — see this suite's header.
        let gateWasEnabled = UserDefaults.standard.bool(forKey: SRDiagnosticsGate.defaultsKey)
        UserDefaults.standard.set(true, forKey: SRDiagnosticsGate.defaultsKey)
        defer { UserDefaults.standard.set(gateWasEnabled, forKey: SRDiagnosticsGate.defaultsKey) }

        _ = NSScriptSuiteRegistry.shared() // force sdef load before dispatch, same as the app would have by launch time

        let source = MultipageMargins.testDocsDirectory.appendingPathComponent("ws4/INDIAN.ws")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleEventLifecycleBreadcrumbsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let marker = Date()

        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode("SRsu"),
            eventID: ScriptingCodes.fourCharCode("conv"),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(boolean: true), forKeyword: keyReplyRequestedAttr)

        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: source), at: 0)
        event.setParam(fileList, forKeyword: keyDirectObject)

        let formatList = NSAppleEventDescriptor.list()
        formatList.insert(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr")), at: 0)
        event.setParam(formatList, forKeyword: ScriptingCodes.fourCharCode("SRcy"))

        event.setParam(NSAppleEventDescriptor(fileURL: tempDir), forKeyword: ScriptingCodes.fourCharCode("SRcf"))

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = NSAppleEventManager.shared().dispatchRawAppleEvent(
            event.aeDesc!, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)
        print("AppleEventLifecycleBreadcrumbsTests: control dispatch OSStatus=\(status)")
        #expect(status == noErr,
                "control dispatch itself must succeed for this test's ordering assertion to mean anything")

        let stages = AppleEventLifecycleBreadcrumbs.readEntries()
            .filter { $0.ts > marker }
            .map(\.stage)
        print("AppleEventLifecycleBreadcrumbsTests: stages since marker = \(stages)")

        // Job 222 (scriptcommand-exemplar-shape): `executeCommand-entered`/`executeCommand-returned`
        // stages are gone — `ConvertCommand` no longer overrides `execute()` at all (see that
        // class's own doc comment and docs/reference/apple/scriptcommand-exemplars-packet.md).
        // Only `constructed` (init) and `pdi-entered` (the one sanctioned override,
        // `performDefaultImplementation`) remain.
        let requiredOrder = ["constructed", "pdi-entered"]
        #expect(Self.containsInOrder(requiredOrder, within: stages),
                "expected lifecycle breadcrumbs in order \(requiredOrder), got \(stages)")
    }

    /// Job 222 (scriptcommand-exemplar-shape): the `executeCommand-returned`-detail instrument
    /// this test used to check (return-value runtime type, `NSScriptCommand.current() === self`,
    /// `currentReplyAppleEvent.descriptorType`) lived inside the now-removed `execute()`
    /// override — see `ConvertCommand`'s own doc comment on why that override is gone (it
    /// shipped in Release and is a live candidate for the empty-reply -1708 itself, per
    /// `docs/reference/apple/scriptcommand-exemplars-packet.md`). No replacement instrument was
    /// added in the shipping command: the packet's rule is performDefaultImplementation-only,
    /// and job 199-207's dispatch-clean / reply-packaging findings this instrument existed to
    /// gather are already on record ([[soft-return-1708-dispatch-investigation]]). If this kind
    /// of return-value/reply-state detail is needed again, it belongs in a DEBUG-only subclass
    /// or the `SoftReturnDiagnostics` module, not back in `ConvertCommand`.
}
