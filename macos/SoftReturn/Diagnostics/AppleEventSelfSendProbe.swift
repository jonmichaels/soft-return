import AppKit
import CoreServices
import CtrlKD
import Foundation

/// Job 235 (-1708 cross-process repro, continuing 143-234). Every prior probe in this module
/// either dispatches in-process via Cocoa's `NSAppleEventManager.dispatchRawAppleEvent` (a
/// shortcut that "bypasses entirely" the OS's real Apple Event Manager, per
/// `AppleEventSelfTest`'s own header) or is `#if DEBUG` and so cannot say anything about the
/// RELEASE binary's real dispatch path — see `docs/AppleScript-Dictionary.md` and
/// [[soft-return-job-ae-e2e]]'s own finding that a genuine cross-process `osascript` send never
/// even reaches the app (TCC -1743 first). This probe closes that gap with the one send shape
/// TCC does not gate: an `AESendMessage` addressed to this process's OWN pid via
/// `typeKernelProcessID` (`AEDataModel.h`: `typeKernelProcessID = 'kpid'`, "New addressing modes
/// for MacOS X"; built via `NSAppleEventDescriptor(processIdentifier:)`, which
/// `NSAppleEventDescriptor.h` documents as creating "an autoreleased application address
/// descriptor using... a pid" — the Foundation-level wrapper for that same addressing mode).
/// Per `AEMach.h`'s doc comment on `AESendMessage` (already cited in `AppleEventSelfTest`), a
/// self-addressed event is dispatched directly to this process's own handler table without
/// needing Automation/TCC authorization — but unlike `AppleEventSelfTest`'s
/// `NSAppleEventDescriptor.currentProcess()` (a `typeProcessSerialNumber`-flavored self-target),
/// `typeKernelProcessID` is the addressing mode a genuine cross-process sender would use to name
/// this app by pid, so this is the closest in-process approximation of the real field send that
/// does not require TCC authorization this environment cannot grant (see
/// [[soft-return-job233-tcc-headless]]).
///
/// **Why this file is NOT `#if DEBUG`, unlike `AppleEventSelfTest`/`ScriptingRegistryProbe`/
/// `AppleEventDiagnosticTap`:** the brief for this job is explicit that the RELEASE-configuration
/// binary's dispatch path is itself part of the question — the DEBUG-only probes above can only
/// ever answer "does this happen in a build with extra instrumentation compiled in", and job
/// 219's own ruling was never "no diagnostics may run in Release", it was "must run APPLE'S
/// native paths... unannounced" (see `SRDiagnosticsGate`'s header). This file follows
/// `AppleEventLifecycleBreadcrumbs`'s established exception shape instead (job 219 finding B7):
/// compiled into every configuration, completely inert by construction unless explicitly turned
/// on, so its mere presence changes nothing about Apple's own delivery/reply machinery. It
/// duplicates `ScriptingRegistryProbe`'s registry-snapshot fields locally (rather than calling
/// that type) for the same reason `AppleEventSelfTest` already duplicates them in its own
/// `registryDump()`: `ScriptingRegistryProbe` itself is `#if DEBUG` and unreachable from here.
///
/// **Why the trigger is a SECOND, narrower gate on top of `SRDiagnosticsGate`, not just the
/// shared switch:** job 219's ruling against per-tool flags (`SRDiagnosticsGate`'s header) is
/// about redundant on/off switches for otherwise-equivalent-risk instruments. This one is not
/// equivalent risk — job 174 found that a self-addressed `AESendMessage` run inside the sandboxed
/// XCTest host crashed the entire test process outright (Signal 11), and that finding is why
/// `AppleEventSelfTest`'s in-suite self-send was removed rather than kept. Requiring the
/// `SRSelfSendProbe` environment flag IN ADDITION to `SRDiagnosticsGate` means turning on the
/// other, lower-risk probes in this module (the registry dump, the lifecycle ring buffer) can
/// never accidentally also trigger this one. Both must be explicit.
///
/// Called from `AppDelegate.applicationDidFinishLaunching`, after the `#if DEBUG` probe block —
/// see that file for why AFTER, not `applicationWillFinishLaunching` (same "registry must already
/// be warm" ordering rationale every prior probe in this investigation has followed).
/// Job 239b (`ae-layer-probe`): one merged layer-table row, always compiled (unlike the
/// `#if DEBUG` instruments it summarizes) so `AppleEventSelfSendProbe.State` — which must stay
/// available in Release, per this file's header — can hold the data without referencing a
/// DEBUG-only type directly. `replyErrorNumber`/`replyErrorString` are only ever populated for
/// `AppleEventDispatchSwizzle` rows (the reply is only meaningful once Cocoa's own dispatch has
/// returned); `AppleEventDiagnosticTap` rows leave both nil.
struct AppleEventLayerCall: Equatable {
    let monotonic: Double
    let originalReturn: Int32
    let replyErrorNumber: Int32?
    let replyErrorString: String?
}

enum AppleEventSelfSendProbe {
    static let defaultsKey = "aeDiagnostics.selfSendProbe"
    private static let environmentKey = "SRSelfSendProbe"

    /// Job 458 (b28 note 5, Jon's ruling): NO hand-placed file. Jon ran the probe on b27 and
    /// found the guard below silently reading a missing hand-placed fixture as PASS — his fix
    /// instruction was literal: "There are 4 embedded WS files in the app. Test those." This
    /// resolves the first bundled sample document (`SampleDocuments.items()`, alphabetical —
    /// `LYING.WS` as of job 407's bundle) so every leg that needs a real WordStar document
    /// runs unattended on a fresh install, in the real app AND in this test host (`Bundle.main`
    /// resolves to the app bundle in both — `SampleDocumentsTests
    /// .realAppBundleShipsTheBundledSamplesAndBuildsAMenuItem` already proves this). The old
    /// hand-placed path is kept only as a last-resort fallback for a build that somehow ships
    /// zero samples — the missing-fixture guard below now fails loudly in that case instead of
    /// reading as a pass.
    static var fixtureURL: URL {
        SampleDocuments.items().first?.url
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("AESelfSendProbeFixture", isDirectory: true)
                .appendingPathComponent("OLDTIMES.WS")
    }

    /// Same rationale as `AppleEventSelfTest.debugMarkerURL`: `defaults`/`cfprefsd` round trips
    /// have proven unreliable to read back from outside the sandbox in this environment, so the
    /// result is also dropped as a plain file needing no daemon. Job 458: this is now THE file
    /// a human reads — one line, `State.humanLine` verbatim, PASS or FAIL in words. Renamed from
    /// `debugMarkerURL` since it is no longer a debug dump; the debug dump moved to
    /// `internalDetailMarkerURL` below.
    static var resultMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.result.txt")
    }

    /// Job 458: the full internal diagnostic dump this file's original investigation (jobs
    /// 235-241) built — registry snapshot, handler pointers, dispatch-layer tables, breadcrumb
    /// flags — moved here, OUT of the human-facing `resultMarkerURL`, per Jon's ruling that a
    /// human should not have to interpret an integer or wade through fields "only your probe can
    /// see." Still written unconditionally (not gated behind a build flag) since these fields
    /// remain useful for chasing a real dispatch regression; just no longer the first thing read.
    static var internalDetailMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.internal.txt")
    }

    /// Job 241 (`ae-reply-type`): the reply `AEDesc`'s verbatim `-description` dump, written
    /// unconditionally (every build configuration) — same rationale as `resultMarkerURL` above,
    /// and deliberately a SEPARATE file rather than folded into that one-line summary, since a
    /// recursive AEDesc dump can run to many lines and the summary is meant to stay grep-able.
    static var replyDumpMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.replyDump.txt")
    }

    struct State: Equatable {
        let ranAt: Date
        let buildConfiguration: String
        let pid: Int32
        let fixturePresent: Bool
        let sendStatus: Int32
        let replyErrorNumber: Int32?
        let replyErrorString: String?
        let outputProduced: Bool
        let outputPath: String?
        /// Job 458: WHY `outputProduced` is what it is — human-readable, always non-nil once a
        /// send was actually attempted (the two early-exit States leave it nil, same as every
        /// other send-bracket field). `outputProduced` itself now means a VERIFIED RTF, not
        /// just "a file with a `.rtf` extension exists" — see `verifyRTFOutput(at:)`.
        let outputDetail: String?
        let constructedBreadcrumbFired: Bool
        let performDefaultImplementationBreadcrumbFired: Bool
        let registrySuiteNames: [String]
        let registrySoftReturnSuitePresent: Bool
        let registryConvertCommandPresent: Bool
        let registryConvertCommandClassResolves: Bool
        let registryModuleQualifiedClassResolves: Bool
        let registryBareClassResolves: Bool
        /// Job 236 (dedup-dispatch): read-only `AEGetEventHandler` checkpoints, safe in every
        /// configuration since reading never installs or replaces anything. If the handler
        /// pointer identity DIFFERS before vs. after the send, something reinstalled a handler
        /// for `('SRsu','conv')` during the send itself — direct evidence of a re-registration,
        /// not just a theory about one.
        let handlerInstalledBeforeSend: Bool
        let handlerPointerBeforeSend: String?
        let handlerInstalledAfterSend: Bool
        let handlerPointerAfterSend: String?
        /// Job 236: only ever non-nil in DEBUG (`SuiteRegistrationProbe` is `#if DEBUG`) — how
        /// many times `NSScriptSuiteRegistry.loadSuites(from:)` has been called, by ANYONE, up to
        /// the moment this send completed. Always nil in RELEASE, where the swizzle this counts
        /// on cannot exist at all (job 219's ruling).
        let loadSuitesCallCountAtSend: Int?
        /// Job 237 (ae-timeline): `ProcessInfo.processInfo.systemUptime` immediately before and
        /// after `AESendMessage` — the same monotonic clock `ConvertCommand.dispatchTimelineDetail`
        /// stamps every `constructed`/`pdi-entered` breadcrumb with, so a report can merge both
        /// sides into one ordered send -> [constructions] -> return timeline with real deltas
        /// instead of comparing wall-clock `Date`s recorded on different threads. Both nil in the
        /// two early-exit States below (fixture missing / `AEDesc` build failure) — no send is
        /// ever attempted on those paths, so there is nothing to bracket.
        let sendMonotonicUptime: Double?
        let returnMonotonicUptime: Double?
        /// Job 241 (`ae-reply-type`, the reply-packaging A/B matrix): the reply `AEDesc`'s own
        /// `-description` — Foundation's recursive, human-readable dump of every attribute and
        /// parameter it holds, verbatim, not a guess at which key to look at. Every matrix
        /// variant changes what the reply SHOULD contain (a file-list, text, nothing, a
        /// hand-built descriptor list); a fixed set of named-key extractors below would have to
        /// be re-guessed per variant, so the raw dump is the one representation that stays
        /// meaningful across all of them. `nil` only in the two early-exit States (fixture
        /// missing / `AEDesc` build failure), same as the send-bracket fields above.
        let replyDescriptorDump: String?
        /// `keyAEResult` ('ansr') is Cocoa Scripting's own reply key for a command's return
        /// value (`ScriptingRecordBuilder`'s header, job 207/216: this key came back absent for
        /// a custom record result even though dispatch was clean). Read explicitly, alongside
        /// the raw dump above, because "present but empty" and "absent entirely" are different
        /// findings the raw dump alone makes a reader re-derive by eye.
        let replyAEResultPresent: Bool
        let replyAEResultType: String?
        let replyAEResultStringValue: String?
        /// Job 239b (`ae-layer-probe`): the two-layer table this job exists to produce. Both
        /// nil outside DEBUG (`AppleEventDispatchSwizzle`/`AppleEventDiagnosticTap` don't exist
        /// in Release — job 219's ruling) and in the two early-exit States below, same rationale
        /// as `loadSuitesCallCountAtSend`/`sendMonotonicUptime` above. `dispatchLayerCalls` is
        /// `-[NSAppleEventManager dispatchRawAppleEvent:withRawReply:handlerRefCon:]`'s own
        /// return, the layer ABOVE Cocoa Scripting's raw-proc dispatch; `rawProcLayerCalls` is
        /// the raw `AEInstallEventHandler` proc's return, the layer BELOW it. The first of the
        /// two (in call order, not array order — merge on `monotonic`) whose return is -1708
        /// where a layer below it succeeded names the bug.
        let dispatchLayerCalls: [AppleEventLayerCall]?
        let rawProcLayerCalls: [AppleEventLayerCall]?

        /// Job 458: the ONE fact a human needs, replacing "check whether `sendStatus == 0`" —
        /// that check alone is exactly the bug Jon caught (a missing fixture also reports
        /// `sendStatus == 0`). PASS requires all three: a real subject was found, the send
        /// itself returned 0, AND the side effect (a verified RTF) actually landed.
        var passed: Bool { fixturePresent && sendStatus == 0 && outputProduced }

        /// The line written to the primary result marker file and read by a human — states
        /// PASS/FAIL in words and names the side effect, per job 458's brief. Internal-only
        /// diagnostic fields (registry snapshot, handler pointers, dispatch tables, breadcrumbs)
        /// are deliberately NOT here; they still go to NSLog and `internalDetailMarkerURL` for
        /// anyone who wants them, but never to this line.
        var humanLine: String {
            if !fixturePresent {
                return "convert: FAIL — \(replyErrorString ?? "no subject document found")"
            }
            if sendStatus != 0 {
                return "convert: FAIL — AppleEvent send returned \(sendStatus)"
                    + (replyErrorString.map { " (\($0))" } ?? "")
            }
            if !outputProduced {
                return "convert: FAIL — \(outputDetail ?? "no verified output produced")"
            }
            return "convert: PASS — \(outputDetail ?? "output verified")"
        }
    }

    /// Job 458: the `convert` leg's own side-effect verification — "a file exists" is not
    /// enough (brief: "a real RTF/PDF, not a zero-byte stub"). Checks existence, non-empty, and
    /// the RTF magic bytes (`{\rtf`), same three-part shape `verifyJSONReply`/
    /// `verifyPageSettingsJSONReply` already use for the other legs' reply-based side effects.
    private static func verifyRTFOutput(at url: URL?) -> (verified: Bool, detail: String) {
        guard let url else { return (false, "no .rtf file produced in the output directory") }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return (false, "output file at \(url.path) is missing or empty")
        }
        guard data.starts(with: Array("{\\rtf".utf8)) else {
            return (false, "output file at \(url.path) (\(data.count) bytes) does not start with the RTF magic bytes")
        }
        return (true, "RTF output verified: \(data.count) bytes, valid RTF header at \(url.path)")
    }

    /// Job 236: pure `AEGetEventHandler` read — installs nothing, replaces nothing, safe in
    /// every configuration including Release. Returns whether a handler is currently installed
    /// for `('SRsu','conv')` and, if so, a stable-but-opaque identity for it (the function
    /// pointer's bit pattern) so two reads can be compared for equality without exposing
    /// anything about what the pointer actually addresses.
    private static func describeInstalledHandler() -> (installed: Bool, pointer: String?) {
        var existingHandler: AEEventHandlerUPP?
        var existingRefcon: UnsafeMutableRawPointer?
        let status = AEGetEventHandler(
            ScriptingCodes.fourCharCode("SRsu"), ScriptingCodes.fourCharCode("conv"),
            &existingHandler, &existingRefcon, false)
        guard status == noErr, let handler = existingHandler else { return (false, nil) }
        return (true, String(format: "0x%016x", unsafeBitCast(handler, to: UInt.self)))
    }

    /// `defaults` is only used for the SYNCHRONOUS gate check below — not threaded into the
    /// `Task` that follows. `UserDefaults` is not `Sendable` under this project's strict
    /// concurrency checking, so capturing an injected instance across the `@MainActor` boundary
    /// is rejected at compile time (confirmed by a real build failure, not assumed); the async
    /// half of this probe always reads/writes `UserDefaults.standard` directly instead, same as
    /// `AppleEventSelfTest.runIfRequested`/`.record` already do for the identical reason.
    static func runIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard SRDiagnosticsGate.isEnabled(environment: environment, defaults: defaults) else { return }
        guard environment[environmentKey] == "1" else { return }
        Task { @MainActor in
            // Mirrors `AppleEventSelfTest`'s own delay: let launch (menu bar, AppKit's
            // post-launch menu injection, any Cocoa-side handler installation triggered by the
            // registry's forced load) settle before sending, so a failure means "the steady-state
            // dispatch table doesn't handle this", not "launch was still mid-flight".
            try? await Task.sleep(for: .seconds(2))
            let state = perform()
            record(state, defaults: .standard)
        }
    }

    @MainActor
    private static func perform() -> State {
        let defaults = UserDefaults.standard
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            // Job 458: this must be impossible to read as a pass. `sendStatus` is a distinct
            // non-zero sentinel (never 0, the value a naive check would treat as success), and
            // `passed`/`humanLine` below independently gate on `fixturePresent` too — belt and
            // suspenders, since this exact guard shape is the bug Jon caught on b27.
            return State(
                ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: false,
                sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "no bundled sample document available (SampleDocuments.items() was empty)",
                outputProduced: false, outputPath: nil, outputDetail: nil,
                constructedBreadcrumbFired: false, performDefaultImplementationBreadcrumbFired: false,
                registrySuiteNames: [], registrySoftReturnSuitePresent: false,
                registryConvertCommandPresent: false, registryConvertCommandClassResolves: false,
                registryModuleQualifiedClassResolves: false, registryBareClassResolves: false,
                handlerInstalledBeforeSend: false, handlerPointerBeforeSend: nil,
                handlerInstalledAfterSend: false, handlerPointerAfterSend: nil,
                loadSuitesCallCountAtSend: nil,
                sendMonotonicUptime: nil, returnMonotonicUptime: nil,
                replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                dispatchLayerCalls: nil, rawProcLayerCalls: nil)
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfSendProbeOutput-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // `typeKernelProcessID` addressing — see this type's header for why this, and not
        // `NSAppleEventDescriptor.currentProcess()`, is the addressing mode under test.
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode("SRsu"),
            eventID: ScriptingCodes.fourCharCode("conv"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(boolean: true), forKeyword: keyReplyRequestedAttr)

        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: fixtureURL), at: 0)
        event.setParam(fileList, forKeyword: keyDirectObject)

        let formatList = NSAppleEventDescriptor.list()
        formatList.insert(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr")), at: 0)
        event.setParam(formatList, forKeyword: ScriptingCodes.fourCharCode("SRcy"))

        event.setParam(NSAppleEventDescriptor(fileURL: outputDir), forKeyword: ScriptingCodes.fourCharCode("SRcf"))

        let breadcrumbMarker = Date()

        guard let eventDesc = event.aeDesc else {
            return State(
                ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: true,
                sendStatus: -1, replyErrorNumber: nil, replyErrorString: "could not build AEDesc",
                outputProduced: false, outputPath: nil, outputDetail: nil,
                constructedBreadcrumbFired: false, performDefaultImplementationBreadcrumbFired: false,
                registrySuiteNames: [], registrySoftReturnSuitePresent: false,
                registryConvertCommandPresent: false, registryConvertCommandClassResolves: false,
                registryModuleQualifiedClassResolves: false, registryBareClassResolves: false,
                handlerInstalledBeforeSend: false, handlerPointerBeforeSend: nil,
                handlerInstalledAfterSend: false, handlerPointerAfterSend: nil,
                loadSuitesCallCountAtSend: nil,
                sendMonotonicUptime: nil, returnMonotonicUptime: nil,
                replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                dispatchLayerCalls: nil, rawProcLayerCalls: nil)
        }

        let handlerBefore = describeInstalledHandler()

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        // Job 237: bracket the blocking call itself, as tightly as possible — anything recorded
        // outside this pair (registry snapshot, handler-after read, breadcrumb filtering below)
        // happens AFTER the sender already has its (-1708) status back, so it cannot explain
        // what the sender observed, only what the receiver's state looked like once it was over.
        let sendMonotonicUptime = ProcessInfo.processInfo.systemUptime
        let status = AESendMessage(eventDesc, &reply, AESendMode(kAEWaitReply), Int(kAEDefaultTimeout))
        let returnMonotonicUptime = ProcessInfo.processInfo.systemUptime

        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let errorString = replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue
        let replyDescriptorDump = replyDescriptor.description
        let resultDescriptor = replyDescriptor.paramDescriptor(forKeyword: keyAEResult)
        let replyAEResultPresent = resultDescriptor != nil
        let replyAEResultType = resultDescriptor.map { ScriptingCodes.string(fromFourCharCode: $0.descriptorType) }
        let replyAEResultStringValue = resultDescriptor?.stringValue

        let outputs = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        let rtf = outputs.first { $0.pathExtension.lowercased() == "rtf" }
        let (outputVerified, outputDetail) = verifyRTFOutput(at: rtf)

        let breadcrumbs = AppleEventLifecycleBreadcrumbs.readEntries(defaults: defaults)
            .filter { $0.ts >= breadcrumbMarker }
        let constructedFired = breadcrumbs.contains { $0.stage == "constructed" }
        let pdiFired = breadcrumbs.contains { $0.stage == "pdi-entered" }

        let registry = registrySnapshot()
        let handlerAfter = describeInstalledHandler()
        #if DEBUG
        let loadSuitesCallCountAtSend: Int? = SuiteRegistrationProbe.callCount()
        // Job 239b (ae-layer-probe): both layers' call logs are process-lifetime, so filter to
        // this send's own bracket (`>= sendMonotonicUptime`) rather than reading everything —
        // same "bracket future work" discipline job 237 established for breadcrumb filtering.
        let dispatchLayerCalls: [AppleEventLayerCall]? = AppleEventDispatchSwizzle.recordedCalls()
            .filter { $0.monotonic >= sendMonotonicUptime }
            .map { AppleEventLayerCall(monotonic: $0.monotonic, originalReturn: $0.originalReturn,
                                       replyErrorNumber: $0.replyErrorNumber, replyErrorString: $0.replyErrorString) }
        let rawProcLayerCalls: [AppleEventLayerCall]? = AppleEventDiagnosticTap.recordedCalls()
            .filter { $0.monotonic >= sendMonotonicUptime }
            .map { AppleEventLayerCall(monotonic: $0.monotonic, originalReturn: $0.originalReturn,
                                       replyErrorNumber: nil, replyErrorString: nil) }
        #else
        let loadSuitesCallCountAtSend: Int? = nil
        let dispatchLayerCalls: [AppleEventLayerCall]? = nil
        let rawProcLayerCalls: [AppleEventLayerCall]? = nil
        #endif

        return State(
            ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: true,
            sendStatus: status, replyErrorNumber: errorNumber, replyErrorString: errorString,
            outputProduced: outputVerified, outputPath: rtf?.path, outputDetail: outputDetail,
            constructedBreadcrumbFired: constructedFired,
            performDefaultImplementationBreadcrumbFired: pdiFired,
            registrySuiteNames: registry.suiteNames,
            registrySoftReturnSuitePresent: registry.softReturnSuitePresent,
            registryConvertCommandPresent: registry.convertCommandPresent,
            registryConvertCommandClassResolves: registry.convertCommandClassResolves,
            registryModuleQualifiedClassResolves: registry.moduleQualifiedClassResolves,
            registryBareClassResolves: registry.bareClassResolves,
            handlerInstalledBeforeSend: handlerBefore.installed, handlerPointerBeforeSend: handlerBefore.pointer,
            handlerInstalledAfterSend: handlerAfter.installed, handlerPointerAfterSend: handlerAfter.pointer,
            loadSuitesCallCountAtSend: loadSuitesCallCountAtSend,
            sendMonotonicUptime: sendMonotonicUptime, returnMonotonicUptime: returnMonotonicUptime,
            replyDescriptorDump: replyDescriptorDump,
            replyAEResultPresent: replyAEResultPresent, replyAEResultType: replyAEResultType,
            replyAEResultStringValue: replyAEResultStringValue,
            dispatchLayerCalls: dispatchLayerCalls, rawProcLayerCalls: rawProcLayerCalls)
    }

    // MARK: - Registry snapshot (duplicated from `ScriptingRegistryProbe`, which is `#if DEBUG`
    // and so unreachable from this always-compiled file — see this type's header).

    private static func registrySnapshot() -> (
        suiteNames: [String], softReturnSuitePresent: Bool, convertCommandPresent: Bool,
        convertCommandClassResolves: Bool, moduleQualifiedClassResolves: Bool, bareClassResolves: Bool
    ) {
        let registry = NSScriptSuiteRegistry.shared()
        let suiteNames = registry.suiteNames.sorted()
        let softReturnSuitePresent = suiteNames.contains("Soft Return Suite")
        var convertCommandPresent = false
        var convertCommandClassResolves = false
        if let description = registry.commandDescriptions(inSuite: "Soft Return Suite")?["convert"] {
            convertCommandPresent = true
            let className = description.commandClassName
            convertCommandClassResolves = !className.isEmpty && NSClassFromString(className) != nil
        }
        return (
            suiteNames, softReturnSuitePresent, convertCommandPresent, convertCommandClassResolves,
            NSClassFromString("SoftReturn.ConvertCommand") != nil,
            NSClassFromString("ConvertCommand") != nil)
    }

    // MARK: - Recording (plain plist values, the module's established shape). Internal, not
    // private, so tests can drive a round trip directly without a real `AESendMessage` — see
    // `AppleEventSelfSendProbeTests` and this type's header on why a real self-send is not
    // exercised in this test target (job 174's crash precedent).

    static func record(_ state: State, defaults: UserDefaults) {
        var dict: [String: Any] = [
            "ranAt": state.ranAt,
            "buildConfiguration": state.buildConfiguration,
            "pid": state.pid,
            "fixturePresent": state.fixturePresent,
            "sendStatus": state.sendStatus,
            "outputProduced": state.outputProduced,
            "constructedBreadcrumbFired": state.constructedBreadcrumbFired,
            "performDefaultImplementationBreadcrumbFired": state.performDefaultImplementationBreadcrumbFired,
            "registrySuiteNames": state.registrySuiteNames,
            "registrySoftReturnSuitePresent": state.registrySoftReturnSuitePresent,
            "registryConvertCommandPresent": state.registryConvertCommandPresent,
            "registryConvertCommandClassResolves": state.registryConvertCommandClassResolves,
            "registryModuleQualifiedClassResolves": state.registryModuleQualifiedClassResolves,
            "registryBareClassResolves": state.registryBareClassResolves,
            "handlerInstalledBeforeSend": state.handlerInstalledBeforeSend,
            "handlerInstalledAfterSend": state.handlerInstalledAfterSend,
        ]
        if let replyErrorNumber = state.replyErrorNumber { dict["replyErrorNumber"] = replyErrorNumber }
        if let replyErrorString = state.replyErrorString { dict["replyErrorString"] = replyErrorString }
        if let outputPath = state.outputPath { dict["outputPath"] = outputPath }
        if let outputDetail = state.outputDetail { dict["outputDetail"] = outputDetail }
        if let handlerPointerBeforeSend = state.handlerPointerBeforeSend { dict["handlerPointerBeforeSend"] = handlerPointerBeforeSend }
        if let handlerPointerAfterSend = state.handlerPointerAfterSend { dict["handlerPointerAfterSend"] = handlerPointerAfterSend }
        if let loadSuitesCallCountAtSend = state.loadSuitesCallCountAtSend { dict["loadSuitesCallCountAtSend"] = loadSuitesCallCountAtSend }
        if let sendMonotonicUptime = state.sendMonotonicUptime { dict["sendMonotonicUptime"] = sendMonotonicUptime }
        if let returnMonotonicUptime = state.returnMonotonicUptime { dict["returnMonotonicUptime"] = returnMonotonicUptime }
        if let dispatchLayerCalls = state.dispatchLayerCalls { dict["dispatchLayerCalls"] = Self.encode(dispatchLayerCalls) }
        if let rawProcLayerCalls = state.rawProcLayerCalls { dict["rawProcLayerCalls"] = Self.encode(rawProcLayerCalls) }
        dict["replyAEResultPresent"] = state.replyAEResultPresent
        if let replyDescriptorDump = state.replyDescriptorDump { dict["replyDescriptorDump"] = replyDescriptorDump }
        if let replyAEResultType = state.replyAEResultType { dict["replyAEResultType"] = replyAEResultType }
        if let replyAEResultStringValue = state.replyAEResultStringValue { dict["replyAEResultStringValue"] = replyAEResultStringValue }
        defaults.set(dict, forKey: defaultsKey)

        // Job 458: `summary` carries the internal diagnostic fields (registry snapshot, handler
        // pointers, dispatch tables, breadcrumbs) Jon ruled OUT of the human-facing marker —
        // still logged and written to `internalDetailMarkerURL` for anyone chasing a real
        // dispatch regression, but no longer the file a human reads for PASS/FAIL.
        let summary = "aeSelfSendProbe: config=\(state.buildConfiguration) pid=\(state.pid) " +
            "fixturePresent=\(state.fixturePresent) sendStatus=\(state.sendStatus) " +
            "replyErrorNumber=\(String(describing: state.replyErrorNumber)) " +
            "replyErrorString=\(String(describing: state.replyErrorString)) " +
            "outputProduced=\(state.outputProduced) outputDetail=\(state.outputDetail ?? "nil") " +
            "constructedFired=\(state.constructedBreadcrumbFired) pdiFired=\(state.performDefaultImplementationBreadcrumbFired) " +
            "registrySuitePresent=\(state.registrySoftReturnSuitePresent) " +
            "registryCommandPresent=\(state.registryConvertCommandPresent) " +
            "registryClassResolves=\(state.registryConvertCommandClassResolves) " +
            "handlerBefore=\(state.handlerInstalledBeforeSend):\(state.handlerPointerBeforeSend ?? "nil") " +
            "handlerAfter=\(state.handlerInstalledAfterSend):\(state.handlerPointerAfterSend ?? "nil") " +
            "loadSuitesCallCountAtSend=\(String(describing: state.loadSuitesCallCountAtSend)) " +
            "sendMonotonicUptime=\(String(describing: state.sendMonotonicUptime)) " +
            "returnMonotonicUptime=\(String(describing: state.returnMonotonicUptime)) " +
            "dispatchLayerCallCount=\(state.dispatchLayerCalls?.count.description ?? "nil") " +
            "rawProcLayerCallCount=\(state.rawProcLayerCalls?.count.description ?? "nil") " +
            "replyAEResultPresent=\(state.replyAEResultPresent) " +
            "replyAEResultType=\(state.replyAEResultType ?? "nil") " +
            "replyAEResultStringValue=\(state.replyAEResultStringValue ?? "nil")"
        NSLog("[SoftReturn] %@ | %@", state.humanLine, summary)
        // Guarded on identity, not unconditional like `AppleEventSelfTest.record`: this file's
        // OWN test suite calls `record(_:defaults:)` directly with a throwaway `UserDefaults`
        // suite to exercise the round trip (see `AppleEventSelfSendProbeTests`), and an
        // unconditional write here was caught overwriting the REAL shared container's marker
        // file with synthetic test data during this job — exactly the kind of contamination a
        // later real-launch readback must not have to second-guess. Only a call using the real
        // shared domain (the actual launch path, always `.standard`) touches the file meant to
        // be read from outside the sandbox.
        if defaults === UserDefaults.standard {
            try? state.humanLine.write(to: resultMarkerURL, atomically: true, encoding: .utf8)
            try? summary.write(to: internalDetailMarkerURL, atomically: true, encoding: .utf8)
            // Job 241 (`ae-reply-type`): the raw reply-descriptor dump, verbatim — NOT `#if
            // DEBUG` (matches this whole file's own not-DEBUG-only posture, header above),
            // because the matrix this job runs is required to test cold RELEASE too. Written
            // unconditionally alongside the summary marker; empty string is impossible here
            // (`replyDescriptorDump` is only nil on the two early-exit States, which return
            // before reaching this line at all — a real send always has SOME dump, even if
            // it is just an empty record `{}`).
            try? (state.replyDescriptorDump ?? "").write(to: replyDumpMarkerURL, atomically: true, encoding: .utf8)
            // Job 236: WHO called `loadSuites(from:)` is the fact the registration-count alone
            // can't say — dump the swizzle's own call log (timestamp + caller-stack symbol per
            // call) next to the existing marker, same plain-file-needs-no-daemon convention. Only
            // exists in DEBUG (`SuiteRegistrationProbe` is `#if DEBUG`); a Release run has nothing
            // to dump here, matching `loadSuitesCallCountAtSend` staying nil in that config.
            #if DEBUG
            let callers = SuiteRegistrationProbe.recordedCalls()
                .map { "\($0.at): \($0.callerSymbol)" }
                .joined(separator: "\n")
            try? callers.write(to: loadSuitesCallersMarkerURL, atomically: true, encoding: .utf8)

            // Job 239b (ae-layer-probe): the merged layer table itself, as a plain readable
            // file — same "defaults/cfprefsd round trips proven unreliable" rationale as
            // internalDetailMarkerURL's own header comment. Rows sorted by monotonic time across BOTH
            // layers so the report reads as one ordered timeline, not two separate lists.
            struct Row { let layer: String; let call: AppleEventLayerCall }
            var rows: [Row] = (state.dispatchLayerCalls ?? []).map { Row(layer: "dispatchRawAppleEvent", call: $0) }
            rows += (state.rawProcLayerCalls ?? []).map { Row(layer: "rawProc", call: $0) }
            rows.sort { $0.call.monotonic < $1.call.monotonic }
            let table = rows.map { row in
                "mono=\(row.call.monotonic) layer=\(row.layer) return=\(row.call.originalReturn) " +
                    "replyErrorNumber=\(String(describing: row.call.replyErrorNumber)) " +
                    "replyErrorString=\(String(describing: row.call.replyErrorString))"
            }.joined(separator: "\n")
            try? table.write(to: layerTableMarkerURL, atomically: true, encoding: .utf8)
            #endif
        }
    }

    #if DEBUG
    static var loadSuitesCallersMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.loadSuitesCallers.txt")
    }

    static var layerTableMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.layerTable.txt")
    }
    #endif

    private static func encode(_ calls: [AppleEventLayerCall]) -> [[String: Any]] {
        calls.map { call in
            var entry: [String: Any] = ["monotonic": call.monotonic, "originalReturn": call.originalReturn]
            if let replyErrorNumber = call.replyErrorNumber { entry["replyErrorNumber"] = replyErrorNumber }
            if let replyErrorString = call.replyErrorString { entry["replyErrorString"] = replyErrorString }
            return entry
        }
    }

    private static func decode(_ raw: [[String: Any]]) -> [AppleEventLayerCall] {
        raw.compactMap { entry in
            guard let monotonic = entry["monotonic"] as? Double,
                  let originalReturn = entry["originalReturn"] as? Int32
            else { return nil }
            return AppleEventLayerCall(
                monotonic: monotonic, originalReturn: originalReturn,
                replyErrorNumber: entry["replyErrorNumber"] as? Int32,
                replyErrorString: entry["replyErrorString"] as? String)
        }
    }

    // MARK: - Read-back (tests + report tooling; the field round trip is `defaults read`/the
    // plain-file marker directly, same as every other probe in this module)

    static func readState(defaults: UserDefaults = .standard) -> State? {
        guard let dict = defaults.dictionary(forKey: defaultsKey),
              let ranAt = dict["ranAt"] as? Date,
              let buildConfiguration = dict["buildConfiguration"] as? String,
              let pid = dict["pid"] as? Int32,
              let fixturePresent = dict["fixturePresent"] as? Bool,
              let sendStatus = dict["sendStatus"] as? Int32,
              let outputProduced = dict["outputProduced"] as? Bool,
              let constructedBreadcrumbFired = dict["constructedBreadcrumbFired"] as? Bool,
              let performDefaultImplementationBreadcrumbFired = dict["performDefaultImplementationBreadcrumbFired"] as? Bool,
              let registrySuiteNames = dict["registrySuiteNames"] as? [String],
              let registrySoftReturnSuitePresent = dict["registrySoftReturnSuitePresent"] as? Bool,
              let registryConvertCommandPresent = dict["registryConvertCommandPresent"] as? Bool,
              let registryConvertCommandClassResolves = dict["registryConvertCommandClassResolves"] as? Bool,
              let registryModuleQualifiedClassResolves = dict["registryModuleQualifiedClassResolves"] as? Bool,
              let registryBareClassResolves = dict["registryBareClassResolves"] as? Bool,
              let handlerInstalledBeforeSend = dict["handlerInstalledBeforeSend"] as? Bool,
              let handlerInstalledAfterSend = dict["handlerInstalledAfterSend"] as? Bool,
              let replyAEResultPresent = dict["replyAEResultPresent"] as? Bool
        else { return nil }
        return State(
            ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: fixturePresent,
            sendStatus: sendStatus,
            replyErrorNumber: dict["replyErrorNumber"] as? Int32,
            replyErrorString: dict["replyErrorString"] as? String,
            outputProduced: outputProduced, outputPath: dict["outputPath"] as? String,
            outputDetail: dict["outputDetail"] as? String,
            constructedBreadcrumbFired: constructedBreadcrumbFired,
            performDefaultImplementationBreadcrumbFired: performDefaultImplementationBreadcrumbFired,
            registrySuiteNames: registrySuiteNames,
            registrySoftReturnSuitePresent: registrySoftReturnSuitePresent,
            registryConvertCommandPresent: registryConvertCommandPresent,
            registryConvertCommandClassResolves: registryConvertCommandClassResolves,
            registryModuleQualifiedClassResolves: registryModuleQualifiedClassResolves,
            registryBareClassResolves: registryBareClassResolves,
            handlerInstalledBeforeSend: handlerInstalledBeforeSend,
            handlerPointerBeforeSend: dict["handlerPointerBeforeSend"] as? String,
            handlerInstalledAfterSend: handlerInstalledAfterSend,
            handlerPointerAfterSend: dict["handlerPointerAfterSend"] as? String,
            loadSuitesCallCountAtSend: dict["loadSuitesCallCountAtSend"] as? Int,
            sendMonotonicUptime: dict["sendMonotonicUptime"] as? Double,
            returnMonotonicUptime: dict["returnMonotonicUptime"] as? Double,
            replyDescriptorDump: dict["replyDescriptorDump"] as? String,
            replyAEResultPresent: replyAEResultPresent,
            replyAEResultType: dict["replyAEResultType"] as? String,
            replyAEResultStringValue: dict["replyAEResultStringValue"] as? String,
            dispatchLayerCalls: (dict["dispatchLayerCalls"] as? [[String: Any]]).map(Self.decode),
            rawProcLayerCalls: (dict["rawProcLayerCalls"] as? [[String: Any]]).map(Self.decode))
    }

    // MARK: - Job 252 (`ae-all-verbs`): export/diagnose/import page settings

    /// Job 241 proved `convert`'s -1708 fix and made this file's `perform()`/`State` above its
    /// permanent field-proof gate — but `export`/`diagnose`/`import page settings` shipped
    /// through the same job-207/216/241 reply-shape eras and have never run a single real
    /// cross-process (or even self-addressed) Apple Event. `VerbState` is the same
    /// send -> reply -> side-effect shape as `State` above, trimmed to what THIS job's brief
    /// asks each of these three verbs to prove (sendStatus, reply payload, one concrete side
    /// effect) rather than re-deriving the full -1708 dedup-dispatch instrumentation (registry
    /// snapshot, handler pointers, dispatch-layer tables) job 236/237/239b built — that
    /// machinery answered a question specific to `convert`'s own suite codes and is already
    /// closed (job 241's CONFIRMED LAW, `10-quicklook-applescript.md`).
    struct VerbState: Equatable {
        let verb: String
        let ranAt: Date
        let buildConfiguration: String
        let pid: Int32
        let fixturePresent: Bool
        let sendStatus: Int32
        let replyErrorNumber: Int32?
        let replyErrorString: String?
        let replyDescriptorDump: String?
        let replyAEResultPresent: Bool
        let replyAEResultType: String?
        let replyAEResultStringValue: String?
        /// `export`: the destination file exists and is non-empty. `diagnose`/`import page
        /// settings`: the reply text itself parses as JSON (import additionally checks all 6
        /// synthetic `.PAT` fields are present) — neither of those two verbs has a separate
        /// on-disk side effect, their whole "product" IS the reply.
        let sideEffectVerified: Bool
        let sideEffectDetail: String?

        /// Job 458: same three-part contract as `State.passed` — a real subject, a clean send,
        /// and a verified side effect, all three, ALWAYS (never `sendStatus == 0` alone).
        var passed: Bool { fixturePresent && sendStatus == 0 && sideEffectVerified }

        /// The line written to `verbMarkerURL(verb)` and read by a human — PASS/FAIL in words,
        /// the side effect named. No registry/handler/dispatch fields here (`VerbState` never
        /// carried those); this is already the whole story for these three-and-a-half legs.
        var humanLine: String {
            if !fixturePresent {
                return "\(verb): FAIL — no subject fixture available"
            }
            if sendStatus != 0 {
                return "\(verb): FAIL — AppleEvent send returned \(sendStatus)"
                    + (replyErrorString.map { " (\($0))" } ?? "")
            }
            if !sideEffectVerified {
                return "\(verb): FAIL — \(sideEffectDetail ?? "side effect not verified")"
            }
            return "\(verb): PASS — \(sideEffectDetail ?? "side effect verified")"
        }
    }

    /// A `.PAT` fixture for `import page settings`, synthesized here rather than externally
    /// provisioned (unlike `fixtureURL`'s real WordStar document, a 68-byte WSCHANGE `INIEDT`
    /// dump is fully deterministic — same layout `PageSettingsScriptingTests.syntheticPAT()`
    /// already proves round-trips through `PageSettingsScripting.importPageSettings`, just
    /// written to a real file instead of held in memory).
    static var patFixtureURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfSendProbeFixture", isDirectory: true)
            .appendingPathComponent("selfSendProbe.PAT")
    }

    private static func writeSyntheticPATFixture() {
        var block = [UInt8](repeating: 0, count: 68)
        func setLE16(_ offset: Int, _ value: Int) {
            block[offset] = UInt8(value & 0xFF)
            block[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        setLE16(0x14, 720)     // .mt  -> 3.0 lines
        setLE16(0x16, 1440)    // .mb  -> 6.0 lines
        setLE16(0x18, 2400)    // .pl  -> 10.0 lines
        setLE16(0x1F, 480)     // .hm  -> 2.0 lines
        setLE16(0x21, 960)     // .fm  -> 4.0 lines
        setLE16(0x24, 1260)    // .po  -> 7.0 columns
        let hex = block.map { String(format: "%02X", $0) }.joined(separator: ",")
        let text = "INIEDT=\(hex)\r\n"
        let dir = patFixtureURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: patFixtureURL, atomically: true, encoding: .utf8)
    }

    private static func verbDefaultsKey(_ verb: String) -> String { "\(defaultsKey).\(verb)" }

    private static func verbMarkerURL(_ verb: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.\(verb).result.txt")
    }

    private static func verbReplyDumpMarkerURL(_ verb: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.\(verb).replyDump.txt")
    }

    /// Same second, narrower opt-in as `runIfRequested()` above (this type's header explains
    /// why a self-send needs one on top of the shared `SRDiagnosticsGate`) — deliberately the
    /// SAME environment flag as `convert`'s probe, not a fourth one: all four verbs are one
    /// "send real self-addressed Apple Events" risk class, not four independent ones.
    static func runOtherVerbsIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard SRDiagnosticsGate.isEnabled(environment: environment, defaults: defaults) else { return }
        guard environment[environmentKey] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            record(performDiagnose(), defaults: .standard)
            writeSyntheticPATFixture()
            record(performImportPageSettings(), defaults: .standard)
            record(await performExport(), defaults: .standard)
            record(await performExportNativeStyle(), defaults: .standard)
        }
    }

    private struct SendOutcome {
        let sendStatus: Int32
        let replyErrorNumber: Int32?
        let replyErrorString: String?
        let replyDescriptorDump: String
        let replyAEResultPresent: Bool
        let replyAEResultType: String?
        let replyAEResultStringValue: String?
    }

    /// Shared self-send + reply-inspection core for the three verbs below — the same
    /// `typeKernelProcessID`/`AESendMessage`/`keyAEResult` shape `perform()` above hand-builds
    /// for `convert`, generalized over event class/ID/parameters. Returns `nil` only when the
    /// `NSAppleEventDescriptor` itself could not be built (mirrors `perform()`'s own early-exit
    /// State, never observed in practice).
    @MainActor
    private static func send(
        eventClass: String, eventID: String, pid: Int32,
        directParameter: NSAppleEventDescriptor?, namedParameters: [(String, NSAppleEventDescriptor)]
    ) -> SendOutcome? {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode(eventClass),
            eventID: ScriptingCodes.fourCharCode(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(boolean: true), forKeyword: keyReplyRequestedAttr)
        if let directParameter { event.setParam(directParameter, forKeyword: keyDirectObject) }
        for (code, value) in namedParameters {
            event.setParam(value, forKeyword: ScriptingCodes.fourCharCode(code))
        }
        guard let eventDesc = event.aeDesc else { return nil }

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }
        let status = AESendMessage(eventDesc, &reply, AESendMode(kAEWaitReply), Int(kAEDefaultTimeout))
        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let resultDescriptor = replyDescriptor.paramDescriptor(forKeyword: keyAEResult)
        return SendOutcome(
            sendStatus: status,
            replyErrorNumber: replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
            replyErrorString: replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue,
            replyDescriptorDump: replyDescriptor.description,
            replyAEResultPresent: resultDescriptor != nil,
            replyAEResultType: resultDescriptor.map { ScriptingCodes.string(fromFourCharCode: $0.descriptorType) },
            replyAEResultStringValue: resultDescriptor?.stringValue)
    }

    private static func verifyJSONReply(_ text: String?) -> (Bool, String?) {
        guard let text, !text.isEmpty else { return (false, "reply text absent/empty") }
        guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return (false, "reply text did not parse as JSON: \(text.prefix(200))")
        }
        return (true, "reply parsed as JSON, \(text.count) chars")
    }

    private static func verifyPageSettingsJSONReply(_ text: String?) -> (Bool, String?) {
        guard let text else { return (false, "reply text absent") }
        let expectedKeys = ["mt_lines", "mb_lines", "po_cols", "hm_lines", "fm_lines", "pl_lines"]
        let missing = expectedKeys.filter { !text.contains($0) }
        guard missing.isEmpty else { return (false, "reply missing keys \(missing): \(text.prefix(200))") }
        return (true, "reply contained all 6 synthetic .PAT fields")
    }

    /// `diagnose POSIX file "..."` — a single file, not a list (unlike `convert`'s
    /// direct-parameter), against the same `fixtureURL` `perform()` above already stages.
    @MainActor
    private static func performDiagnose() -> VerbState {
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return VerbState(
                verb: "diagnose", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: false, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "no bundled sample document available (SampleDocuments.items() was empty)",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }
        guard let outcome = send(
            eventClass: "SRsu", eventID: "diag", pid: pid,
            directParameter: NSAppleEventDescriptor(fileURL: fixtureURL), namedParameters: [])
        else {
            return VerbState(
                verb: "diagnose", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not build AEDesc", replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                sideEffectVerified: false, sideEffectDetail: nil)
        }
        let (verified, detail) = verifyJSONReply(outcome.replyAEResultStringValue)
        return VerbState(
            verb: "diagnose", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
            fixturePresent: true, sendStatus: outcome.sendStatus, replyErrorNumber: outcome.replyErrorNumber,
            replyErrorString: outcome.replyErrorString, replyDescriptorDump: outcome.replyDescriptorDump,
            replyAEResultPresent: outcome.replyAEResultPresent, replyAEResultType: outcome.replyAEResultType,
            replyAEResultStringValue: outcome.replyAEResultStringValue,
            sideEffectVerified: verified, sideEffectDetail: detail)
    }

    /// `import page settings from POSIX file "..."` — against `patFixtureURL`
    /// (`writeSyntheticPATFixture()` must have run first; `runOtherVerbsIfRequested` does this).
    @MainActor
    private static func performImportPageSettings() -> VerbState {
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()
        guard FileManager.default.fileExists(atPath: patFixtureURL.path) else {
            return VerbState(
                verb: "importPageSettings", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: false, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "synthetic .PAT fixture was not written (writeSyntheticPATFixture() failed)",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }
        guard let outcome = send(
            eventClass: "SRsu", eventID: "impg", pid: pid, directParameter: nil,
            namedParameters: [("SRpf", NSAppleEventDescriptor(fileURL: patFixtureURL))])
        else {
            return VerbState(
                verb: "importPageSettings", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not build AEDesc", replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                sideEffectVerified: false, sideEffectDetail: nil)
        }
        let (verified, detail) = verifyPageSettingsJSONReply(outcome.replyAEResultStringValue)
        return VerbState(
            verb: "importPageSettings", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
            fixturePresent: true, sendStatus: outcome.sendStatus, replyErrorNumber: outcome.replyErrorNumber,
            replyErrorString: outcome.replyErrorString, replyDescriptorDump: outcome.replyDescriptorDump,
            replyAEResultPresent: outcome.replyAEResultPresent, replyAEResultType: outcome.replyAEResultType,
            replyAEResultStringValue: outcome.replyAEResultStringValue,
            sideEffectVerified: verified, sideEffectDetail: detail)
    }

    /// A best-effort, hand-built `document 1` object specifier (`keyAEDesiredClass`='docu',
    /// `formAbsolutePosition`, index, null container) — the same "AppKit's own
    /// `objectSpecifier` mechanism is not trustworthy here" fallback
    /// `ConvertCommandReceiverDispatchTests.wholeApplicationSpecifier()` already established for
    /// `NSApp` (`applicationObjectSpecifierIsNil`). `performExport()` tries the REAL
    /// `NSDocument.objectSpecifier` first and only falls back to this when that is nil.
    /// UNVERIFIED against Apple's own AppleScript compiler output, same caveat as that
    /// precedent — the field matrix this job produces is the arbiter, not this comment.
    private static func handBuiltDocumentSpecifier(atIndex index: Int) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: ScriptingCodes.fourCharCode("docu")),
                              forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("indx")),
                              forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(int32: Int32(index)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return NSAppleEventDescriptor(descriptorType: DescType(typeObjectSpecifier), data: record.data)!
    }

    /// `export document 1 to file ... as RTF` — the one verb of the four that is
    /// document-targeted rather than file/app-level, so this stages a REAL open document first
    /// (`NSDocumentController.shared.openDocument`, the same production path
    /// `DocumentOpenTriggerExecutedPathTests` drives) via the scripting document class, then
    /// addresses IT as the direct parameter instead of a file.
    @MainActor
    private static func performExport() async -> VerbState {
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return VerbState(
                verb: "export", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: false, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "no bundled sample document available (SampleDocuments.items() was empty)",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }

        var openedDocument: NSDocument?
        var openError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: fixtureURL, display: false) { document, _, error in
                openedDocument = document
                openError = error
                continuation.resume()
            }
        }
        defer { openedDocument?.close() }

        guard let openedDocument, openError == nil else {
            return VerbState(
                verb: "export", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not open fixture document: \(String(describing: openError))",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfSendProbeExportOutput-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("selfSendProbe.rtf")

        // Job 252 follow-up: the FIRST field run reproduced -1708 here with an empty reply
        // (`{ errn: -1708 }`, no result, no error string) — identical shape to job 235's
        // pre-fix `convert` finding. Since `export`'s return value is already the ONE scalar
        // shape (`NSURL`) job 241 proved packages fine, and `diagnose`/`import page settings`
        // (no object-specifier direct parameter at all) both succeeded cleanly in the SAME run,
        // the live suspect is specifier RESOLUTION, not reply packaging — record which specifier
        // source was used and its own descriptor dump so a report doesn't have to guess.
        let usedRealObjectSpecifier = openedDocument.objectSpecifier.descriptor != nil
        let specifier = openedDocument.objectSpecifier.descriptor
            ?? handBuiltDocumentSpecifier(atIndex: NSDocumentController.shared.documents.count)
        let specifierSource = usedRealObjectSpecifier ? "NSDocument.objectSpecifier" : "hand-built index specifier"
        let specifierDump = specifier.description

        guard let outcome = send(
            eventClass: "SRsu", eventID: "expo", pid: pid, directParameter: specifier,
            namedParameters: [
                ("SRto", NSAppleEventDescriptor(fileURL: outputURL)),
                ("SRas", NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr"))),
            ])
        else {
            return VerbState(
                verb: "export", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not build AEDesc", replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                sideEffectVerified: false, sideEffectDetail: nil)
        }

        // Job 458: "a file exists" is not enough (brief: "a real RTF/PDF, not a zero-byte
        // stub") — check the RTF magic bytes too, same bar `verifyRTFOutput(at:)` sets for the
        // `convert` leg.
        let (rtfVerified, rtfDetail) = verifyRTFOutput(at: FileManager.default.fileExists(atPath: outputURL.path) ? outputURL : nil)
        let detail = rtfDetail + " | specifierSource=\(specifierSource) specifierDump=\(specifierDump)"

        return VerbState(
            verb: "export", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: true,
            sendStatus: outcome.sendStatus, replyErrorNumber: outcome.replyErrorNumber,
            replyErrorString: outcome.replyErrorString, replyDescriptorDump: outcome.replyDescriptorDump,
            replyAEResultPresent: outcome.replyAEResultPresent, replyAEResultType: outcome.replyAEResultType,
            replyAEResultStringValue: outcome.replyAEResultStringValue,
            sideEffectVerified: rtfVerified, sideEffectDetail: detail)
    }

    /// Job 313B: `export document 1 to file ... as PDF using style native` — the new
    /// enumerator (`SRsn`), proven over a REAL self-addressed Apple Event the same way
    /// `performExport()` above proves plain RTF export, not just through
    /// `ExportCommandTests`' pure-decode fakes. The side effect this checks is stronger than
    /// "a file exists": job 313A's whole point is that `native` produces DIFFERENT bytes
    /// from a literal Printed PDF, so this also emits a literal-printed PDF of the same
    /// fixture (in-process, no second Apple Event) and confirms the two are not
    /// byte-identical — the same divergence `nativeViewPDFExportIsNoLongerTheLiteralEngineBytes`
    /// (`Job313ExportPDFTests.swift`) proves at the `ExportEngine` level, here proven to
    /// survive the full Apple Event round trip.
    @MainActor
    private static func performExportNativeStyle() async -> VerbState {
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return VerbState(
                verb: "exportNativeStyle", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: false, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "no bundled sample document available (SampleDocuments.items() was empty)",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }

        var openedDocument: NSDocument?
        var openError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: fixtureURL, display: false) { document, _, error in
                openedDocument = document
                openError = error
                continuation.resume()
            }
        }
        defer { openedDocument?.close() }

        guard let openedDocument, openError == nil else {
            return VerbState(
                verb: "exportNativeStyle", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not open fixture document: \(String(describing: openError))",
                replyDescriptorDump: nil, replyAEResultPresent: false, replyAEResultType: nil,
                replyAEResultStringValue: nil, sideEffectVerified: false, sideEffectDetail: nil)
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfSendProbeExportNativeOutput-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("selfSendProbe.pdf")

        let specifier = openedDocument.objectSpecifier.descriptor
            ?? handBuiltDocumentSpecifier(atIndex: NSDocumentController.shared.documents.count)

        guard let outcome = send(
            eventClass: "SRsu", eventID: "expo", pid: pid, directParameter: specifier,
            namedParameters: [
                ("SRto", NSAppleEventDescriptor(fileURL: outputURL)),
                ("SRas", NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfp"))),
                ("SRus", NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRsn"))),
            ])
        else {
            return VerbState(
                verb: "exportNativeStyle", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
                fixturePresent: true, sendStatus: -1, replyErrorNumber: nil,
                replyErrorString: "could not build AEDesc", replyDescriptorDump: nil,
                replyAEResultPresent: false, replyAEResultType: nil, replyAEResultStringValue: nil,
                sideEffectVerified: false, sideEffectDetail: nil)
        }

        let exists = FileManager.default.fileExists(atPath: outputURL.path)
        let producedBytes = (try? Data(contentsOf: outputURL)) ?? Data()
        let isPDF = producedBytes.prefix(4).elementsEqual(Array("%PDF".utf8))
        // In-process comparison, not a second Apple Event — the literal engine PDF for the
        // SAME fixture bytes this send just exported natively.
        let sourceBytes = (try? Data(contentsOf: fixtureURL)) ?? Data()
        let documentState = try? DocumentState(data: [UInt8](sourceBytes), settings: .shared)
        let literalPrintedBytes = documentState.map { Data(emitPDF($0.document, mode: .printed, options: EmitOptions())) }
        let divergesFromLiteralPrinted = literalPrintedBytes.map { producedBytes != $0 } ?? false
        let verified = exists && isPDF && divergesFromLiteralPrinted
        let detail = "exists=\(exists) size=\(producedBytes.count) isPDF=\(isPDF) "
            + "divergesFromLiteralPrintedPDF=\(divergesFromLiteralPrinted) at \(outputURL.path)"

        return VerbState(
            verb: "exportNativeStyle", ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
            fixturePresent: true,
            sendStatus: outcome.sendStatus, replyErrorNumber: outcome.replyErrorNumber,
            replyErrorString: outcome.replyErrorString, replyDescriptorDump: outcome.replyDescriptorDump,
            replyAEResultPresent: outcome.replyAEResultPresent, replyAEResultType: outcome.replyAEResultType,
            replyAEResultStringValue: outcome.replyAEResultStringValue,
            sideEffectVerified: verified, sideEffectDetail: detail)
    }

    // MARK: - Job 253 (`convert-destination`): the bare-destination arbiter

    /// Every fixture above (`fixtureURL`, `patFixtureURL`) lives under
    /// `FileManager.default.temporaryDirectory` — inside a sandboxed process that resolves
    /// to THIS APP'S OWN CONTAINER (`~/Library/Containers/me.beforeti.softreturn/Data/tmp/`),
    /// a location the app already owns outright, no AE grant needed. Job 218's
    /// container-fallback bug, and Jon's ruling against it (2026-08-12: a bare convert of a
    /// real Dropbox file silently landed in that exact container path), are both about files
    /// OUTSIDE the container — a source this process has, at most, a single-file AE grant
    /// for. `outsideFixtureURL` deliberately never resolves to
    /// `FileManager.default.temporaryDirectory`, so this probe actually exercises the case
    /// the packet and the fix are about. Job 260: previously a HARDCODED worker-machine
    /// literal, which shipped as a plain `strings`-visible path in the Release binary — same
    /// class of leak `SpotlightBackfillSelfTest.probeURL` (job 152, finding B8) already fixed
    /// the same way, so this follows that precedent: read from the environment
    /// (`SRSelfSendOutsideFixture`) rather than a compiled-in literal, with no default outside
    /// the app's own container. An unset variable degrades to `nil`, which every call site
    /// below already treats the same as "fixture not present" (`fixturePresent == false`).
    static var outsideFixtureURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["SRSelfSendOutsideFixture"] else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var bareDestinationMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfSendProbe.bareDestination.result.txt")
    }

    /// The two possible honest outcomes named directly, not inferred from `sendStatus`/reply
    /// fields a report would otherwise have to cross-reference: `besideSourceOutputExists`
    /// (the `BesideSourceWriter` mechanism reached the sibling — the packet's "might make it
    /// legal" case) and `containerOutputExists` (the ONE outcome that must be impossible,
    /// checked directly at the exact path job 218's fallback used to write — `defaultFallbackDirectory()`
    /// no longer exists in source, but the path itself is cheap to recompute here so this
    /// probe keeps proving its absence even after the code that could have produced it is
    /// gone).
    struct BareDestinationState: Equatable {
        let ranAt: Date
        let buildConfiguration: String
        let pid: Int32
        let fixturePresent: Bool
        let sendStatus: Int32
        let replyErrorNumber: Int32?
        let replyErrorString: String?
        let replyDescriptorDump: String?
        let besideSourceOutputExists: Bool
        let besideSourceOutputPath: String
        let containerOutputExists: Bool
        let containerOutputPath: String

        /// Job 490 item 6: before this, an absent `SRSelfSendOutsideFixture` (the common
        /// case — job 260's own doc comment: no default outside the app's own container)
        /// produced a `record()` line that stated facts (`fixturePresent=false`,
        /// `sendStatus=0`, every `*Exists` flag false) with no PASS or FAIL anywhere in it —
        /// indistinguishable, to a human skimming logs, from a leg that legitimately ran and
        /// found nothing wrong. Same shape job 458's own `VerbState.humanLine`/`.passed` was
        /// built to close for this file's OTHER probes (Jon: "silently reading a missing
        /// hand-placed fixture as PASS"); this gives `bareDestination` the identical
        /// PASS/FAIL-in-words contract. `containerOutputExists` staying `false` is this
        /// probe's own documented critical invariant (`BareDestinationState`'s own doc
        /// comment: "the ONE outcome that must be impossible") — a real completed run that
        /// violates it is the loudest possible FAIL this probe can report.
        var passed: Bool { fixturePresent && sendStatus == 0 && !containerOutputExists }

        var humanLine: String {
            guard fixturePresent else {
                return "bareDestination: FAIL — SRSelfSendOutsideFixture is not set, or names a " +
                    "file that does not exist; this leg did not run at all, not a clean result"
            }
            if sendStatus != 0 {
                return "bareDestination: FAIL — AppleEvent send returned \(sendStatus)"
                    + (replyErrorString.map { " (\($0))" } ?? "")
            }
            if containerOutputExists {
                return "bareDestination: FAIL — output landed in the app's own container " +
                    "fallback (\(containerOutputPath)) — the one outcome this probe exists to rule out"
            }
            return "bareDestination: PASS — no container fallback" +
                (besideSourceOutputExists ? "; output beside the source (\(besideSourceOutputPath))" : "")
        }
    }

    /// Same second, narrower opt-in as the other probes in this file (`SRSelfSendProbe`, on
    /// top of the shared `SRDiagnosticsGate`) — one "send real self-addressed Apple Events"
    /// risk class, not a new one for this fifth send shape.
    static func runBareDestinationProbeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard SRDiagnosticsGate.isEnabled(environment: environment, defaults: defaults) else { return }
        guard environment[environmentKey] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            record(performBareDestination(), defaults: .standard)
        }
    }

    /// `convert {POSIX file "..."} as {RTF}` — the direct parameter and `SRcy` (formats)
    /// named parameter only, deliberately WITHOUT `SRcf` (destination folder). This is the
    /// exact bare-destination shape job 253's ruling is about; `send(...)`'s own signature
    /// only ever sets the named parameters it is handed, so simply omitting `SRcf` here is
    /// the whole of "no `to folder`" — no separate code path to maintain.
    @MainActor
    private static func performBareDestination() -> BareDestinationState {
        let ranAt = Date()
        #if DEBUG
        let buildConfiguration = "DEBUG"
        #else
        let buildConfiguration = "RELEASE"
        #endif
        let pid = getpid()
        let containerOutputPath = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OLDTIMES.rtf").path ?? ""
        let besideSourceOutputPath = outsideFixtureURL?.deletingPathExtension()
            .appendingPathExtension("rtf").path ?? ""

        guard let outsideFixtureURL, FileManager.default.fileExists(atPath: outsideFixtureURL.path) else {
            return BareDestinationState(
                ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: false,
                sendStatus: 0, replyErrorNumber: nil, replyErrorString: nil, replyDescriptorDump: nil,
                besideSourceOutputExists: false, besideSourceOutputPath: besideSourceOutputPath,
                containerOutputExists: false, containerOutputPath: containerOutputPath)
        }

        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: outsideFixtureURL), at: 0)
        let formatList = NSAppleEventDescriptor.list()
        formatList.insert(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr")), at: 0)

        guard let outcome = send(
            eventClass: "SRsu", eventID: "conv", pid: pid,
            directParameter: fileList,
            namedParameters: [("SRcy", formatList)])
        else {
            return BareDestinationState(
                ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: true,
                sendStatus: -1, replyErrorNumber: nil, replyErrorString: "could not build AEDesc",
                replyDescriptorDump: nil,
                besideSourceOutputExists: false, besideSourceOutputPath: besideSourceOutputPath,
                containerOutputExists: false, containerOutputPath: containerOutputPath)
        }

        let besideExists = FileManager.default.fileExists(atPath: besideSourceOutputPath)
        let containerExists = !containerOutputPath.isEmpty
            && FileManager.default.fileExists(atPath: containerOutputPath)

        return BareDestinationState(
            ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: true,
            sendStatus: outcome.sendStatus, replyErrorNumber: outcome.replyErrorNumber,
            replyErrorString: outcome.replyErrorString, replyDescriptorDump: outcome.replyDescriptorDump,
            besideSourceOutputExists: besideExists, besideSourceOutputPath: besideSourceOutputPath,
            containerOutputExists: containerExists, containerOutputPath: containerOutputPath)
    }

    static func record(_ state: BareDestinationState, defaults: UserDefaults) {
        var dict: [String: Any] = [
            "ranAt": state.ranAt,
            "buildConfiguration": state.buildConfiguration,
            "pid": state.pid,
            "fixturePresent": state.fixturePresent,
            "sendStatus": state.sendStatus,
            "besideSourceOutputExists": state.besideSourceOutputExists,
            "besideSourceOutputPath": state.besideSourceOutputPath,
            "containerOutputExists": state.containerOutputExists,
            "containerOutputPath": state.containerOutputPath,
        ]
        if let v = state.replyErrorNumber { dict["replyErrorNumber"] = v }
        if let v = state.replyErrorString { dict["replyErrorString"] = v }
        if let v = state.replyDescriptorDump { dict["replyDescriptorDump"] = v }
        defaults.set(dict, forKey: "\(defaultsKey).bareDestination")

        let summary = "aeSelfSendProbe[bareDestination]: config=\(state.buildConfiguration) pid=\(state.pid) " +
            "fixturePresent=\(state.fixturePresent) sendStatus=\(state.sendStatus) " +
            "replyErrorNumber=\(String(describing: state.replyErrorNumber)) " +
            "replyErrorString=\(String(describing: state.replyErrorString)) " +
            "besideSourceOutputExists=\(state.besideSourceOutputExists) besideSourceOutputPath=\(state.besideSourceOutputPath) " +
            "containerOutputExists=\(state.containerOutputExists) containerOutputPath=\(state.containerOutputPath)"
        // Job 490 item 6: `humanLine` (PASS/FAIL in words, `BareDestinationState`'s own doc
        // comment) leads the log line and is what gets written to the marker file a human
        // reads — same "primary marker is the human line" contract job 458 already gave
        // this file's other probes. `summary` (the neutral fact dump) still follows it in
        // the SAME NSLog call for anyone who wants the raw fields, exactly as before.
        NSLog("[SoftReturn] %@ | %@", state.humanLine, summary)
        if defaults === UserDefaults.standard {
            try? state.humanLine.write(to: bareDestinationMarkerURL, atomically: true, encoding: .utf8)
        }
    }

    static func readBareDestinationState(defaults: UserDefaults = .standard) -> BareDestinationState? {
        guard let dict = defaults.dictionary(forKey: "\(defaultsKey).bareDestination"),
              let ranAt = dict["ranAt"] as? Date,
              let buildConfiguration = dict["buildConfiguration"] as? String,
              let pid = dict["pid"] as? Int32,
              let fixturePresent = dict["fixturePresent"] as? Bool,
              let sendStatus = dict["sendStatus"] as? Int32,
              let besideSourceOutputExists = dict["besideSourceOutputExists"] as? Bool,
              let besideSourceOutputPath = dict["besideSourceOutputPath"] as? String,
              let containerOutputExists = dict["containerOutputExists"] as? Bool,
              let containerOutputPath = dict["containerOutputPath"] as? String
        else { return nil }
        return BareDestinationState(
            ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid, fixturePresent: fixturePresent,
            sendStatus: sendStatus,
            replyErrorNumber: dict["replyErrorNumber"] as? Int32,
            replyErrorString: dict["replyErrorString"] as? String,
            replyDescriptorDump: dict["replyDescriptorDump"] as? String,
            besideSourceOutputExists: besideSourceOutputExists, besideSourceOutputPath: besideSourceOutputPath,
            containerOutputExists: containerOutputExists, containerOutputPath: containerOutputPath)
    }

    // MARK: - Recording/read-back (plain plist values, mirrors `record(_:defaults:)` above)

    static func record(_ state: VerbState, defaults: UserDefaults) {
        var dict: [String: Any] = [
            "verb": state.verb,
            "ranAt": state.ranAt,
            "buildConfiguration": state.buildConfiguration,
            "pid": state.pid,
            "fixturePresent": state.fixturePresent,
            "sendStatus": state.sendStatus,
            "replyAEResultPresent": state.replyAEResultPresent,
            "sideEffectVerified": state.sideEffectVerified,
        ]
        if let v = state.replyErrorNumber { dict["replyErrorNumber"] = v }
        if let v = state.replyErrorString { dict["replyErrorString"] = v }
        if let v = state.replyDescriptorDump { dict["replyDescriptorDump"] = v }
        if let v = state.replyAEResultType { dict["replyAEResultType"] = v }
        if let v = state.replyAEResultStringValue { dict["replyAEResultStringValue"] = v }
        if let v = state.sideEffectDetail { dict["sideEffectDetail"] = v }
        defaults.set(dict, forKey: verbDefaultsKey(state.verb))

        let summary = "aeSelfSendProbe[\(state.verb)]: config=\(state.buildConfiguration) pid=\(state.pid) " +
            "fixturePresent=\(state.fixturePresent) sendStatus=\(state.sendStatus) " +
            "replyErrorNumber=\(String(describing: state.replyErrorNumber)) " +
            "replyErrorString=\(String(describing: state.replyErrorString)) " +
            "replyAEResultPresent=\(state.replyAEResultPresent) " +
            "replyAEResultType=\(state.replyAEResultType ?? "nil") " +
            "replyAEResultStringValue=\(state.replyAEResultStringValue ?? "nil") " +
            "sideEffectVerified=\(state.sideEffectVerified) sideEffectDetail=\(state.sideEffectDetail ?? "nil")"
        NSLog("[SoftReturn] %@ | %@", state.humanLine, summary)
        if defaults === UserDefaults.standard {
            // Job 458: the primary marker is now `humanLine` — PASS/FAIL in words, the side
            // effect named. The raw reply-descriptor dump stays in its own file, unchanged.
            try? state.humanLine.write(to: verbMarkerURL(state.verb), atomically: true, encoding: .utf8)
            try? (state.replyDescriptorDump ?? "").write(
                to: verbReplyDumpMarkerURL(state.verb), atomically: true, encoding: .utf8)
        }
    }

    static func readState(verb: String, defaults: UserDefaults = .standard) -> VerbState? {
        guard let dict = defaults.dictionary(forKey: verbDefaultsKey(verb)),
              let readVerb = dict["verb"] as? String,
              let ranAt = dict["ranAt"] as? Date,
              let buildConfiguration = dict["buildConfiguration"] as? String,
              let pid = dict["pid"] as? Int32,
              let fixturePresent = dict["fixturePresent"] as? Bool,
              let sendStatus = dict["sendStatus"] as? Int32,
              let replyAEResultPresent = dict["replyAEResultPresent"] as? Bool,
              let sideEffectVerified = dict["sideEffectVerified"] as? Bool
        else { return nil }
        return VerbState(
            verb: readVerb, ranAt: ranAt, buildConfiguration: buildConfiguration, pid: pid,
            fixturePresent: fixturePresent, sendStatus: sendStatus,
            replyErrorNumber: dict["replyErrorNumber"] as? Int32,
            replyErrorString: dict["replyErrorString"] as? String,
            replyDescriptorDump: dict["replyDescriptorDump"] as? String,
            replyAEResultPresent: replyAEResultPresent,
            replyAEResultType: dict["replyAEResultType"] as? String,
            replyAEResultStringValue: dict["replyAEResultStringValue"] as? String,
            sideEffectVerified: sideEffectVerified,
            sideEffectDetail: dict["sideEffectDetail"] as? String)
    }
}
