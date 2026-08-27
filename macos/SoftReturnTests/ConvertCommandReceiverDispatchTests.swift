import AppKit
import Carbon
import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 185 (-1708, continuing 143-148/174/181). `AppleEventDispatchTests` proves a hand-built
/// `convert` event succeeds end-to-end through `dispatchRawAppleEvent` — but it is a MINIMAL
/// event: `NSAppleEventDescriptor.currentProcess()` as both sender and target, no `keySubjectAttr`,
/// no `keyAddressAttr`. Real `tell application "Soft Return" to convert ...` scripts sent by
/// `osascript` differ from that minimal shape in ways nothing in jobs 143-181 ever varied, because
/// every prior probe (143/144/147/148/174/181) either hand-built the same minimal event or only
/// instrumented the *presence* of a handler/registry entry, never the *content* of a real event.
///
/// This suite isolates each candidate difference one at a time — subject attribute, address
/// attributes, and (deepest layer reachable in-process, see the removed test documented at the
/// bottom of this file) bypassing `dispatchRawAppleEvent` entirely to call the exact Carbon
/// handler `AEInstallEventHandler` has installed for `('SRsu','conv')` directly, via
/// `AEGetEventHandler` + a bare C function call (no `AESend`/Mach IPC/TCC — registry mistake #16:
/// a self-addressed `AESendMessage` in this hosted test bundle SIGSEGVs; this sidesteps that
/// entirely since nothing is ever *sent*).
///
/// RESULT: every variant below succeeds. Content variation (subject attribute, address
/// attributes, both) and dispatch-layer depth (Cocoa's internal `dispatchRawAppleEvent` table,
/// and — in isolation, see the removed test's doc comment for why it isn't kept here — the raw
/// installed Carbon handler itself, called directly) both come back clean. This is a genuine,
/// reportable NEGATIVE result, not an inconclusive one: it means nothing prior jobs or this one
/// could vary or reach from within this process reproduces -1708. Per jobs 143-148's own unclosed
/// gap, the only remaining, still-untested explanation is TCC/Automation permission gating on a
/// REAL external sender — which by definition cannot be exercised by any self-addressed probe,
/// however deep, since self-addressed events are TCC-exempt. See the job 185 report for the full
/// conclusion; these tests stand as the evidence, not a claim to build a fix on.
@Suite struct ConvertCommandReceiverDispatchTests {

    struct DispatchResult {
        let status: OSErr
        let errorNumber: Int32?
        let errorString: String?
    }

    /// Job 207 (-1708, continuing 143-199). Every prior job's `DispatchResult` reads only
    /// the REPLY's `keyErrorNumber`/`keyErrorString` — never `keyAEResult`, the param that
    /// actually carries the command's return value back to a real sender. Field breadcrumbs
    /// (job 199's instrument, read on the real machine before this job) show the command
    /// itself runs clean end-to-end (constructed → executeCommand-entered → pdi-entered →
    /// executeCommand-returned, `scriptErrorNumber=none`) while the real sender still
    /// receives -1708 — so this job inspects what actually lands in the reply's result slot,
    /// not just whether dispatch itself reported success.
    struct ReplyInspection {
        let status: OSErr
        let errorNumber: Int32?
        let errorString: String?
        /// `keyAEResult` ('----') on the reply descriptor — present only when Cocoa
        /// successfully packaged whatever `performDefaultImplementation()` returned.
        let resultDescriptor: NSAppleEventDescriptor?
    }

    /// Builds the same `convert {POSIX file "..."} as RTF` event `AppleEventDispatchTests` uses,
    /// with optional extra attributes layered on for each experiment. Split out from
    /// `buildAndDispatch` (job 188) so a test can capture/serialize the built event itself,
    /// independent of whether dispatching it also happens to invoke some other in-process handler.
    @MainActor
    private static func buildEvent(
        target: NSAppleEventDescriptor = .currentProcess(),
        subjectSpecifier: NSAppleEventDescriptor? = nil,
        addressAttr: NSAppleEventDescriptor? = nil,
        tempDir: URL, source: URL
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode("SRsu"),
            eventID: ScriptingCodes.fourCharCode("conv"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(boolean: true), forKeyword: keyReplyRequestedAttr)
        if let subjectSpecifier {
            event.setAttribute(subjectSpecifier, forKeyword: AEKeyword(keySubjectAttr))
        }
        if let addressAttr {
            event.setAttribute(addressAttr, forKeyword: keyAddressAttr)
            event.setAttribute(addressAttr, forKeyword: AEKeyword(keyOriginalAddressAttr))
        }

        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: source), at: 0)
        event.setParam(fileList, forKeyword: keyDirectObject)

        let formatList = NSAppleEventDescriptor.list()
        formatList.insert(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr")), at: 0)
        event.setParam(formatList, forKeyword: ScriptingCodes.fourCharCode("SRcy"))

        event.setParam(NSAppleEventDescriptor(fileURL: tempDir), forKeyword: ScriptingCodes.fourCharCode("SRcf"))
        return event
    }

    @MainActor
    private static func buildAndDispatch(
        target: NSAppleEventDescriptor = .currentProcess(),
        subjectSpecifier: NSAppleEventDescriptor? = nil,
        addressAttr: NSAppleEventDescriptor? = nil,
        tempDir: URL, source: URL
    ) -> DispatchResult {
        let event = buildEvent(
            target: target, subjectSpecifier: subjectSpecifier, addressAttr: addressAttr,
            tempDir: tempDir, source: source)

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = NSAppleEventManager.shared().dispatchRawAppleEvent(
            event.aeDesc!, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)

        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let errorString = replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue
        return DispatchResult(status: status, errorNumber: errorNumber, errorString: errorString)
    }

    /// Job 207: same as `buildAndDispatch`, but also reads `keyAEResult` off the reply —
    /// the field carrying the command's actual return value, which no prior job's harness
    /// ever inspected.
    @MainActor
    private static func buildAndDispatchInspectingReply(
        target: NSAppleEventDescriptor = .currentProcess(),
        tempDir: URL, source: URL
    ) -> ReplyInspection {
        let event = Self.buildEvent(target: target, tempDir: tempDir, source: source)

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = NSAppleEventManager.shared().dispatchRawAppleEvent(
            event.aeDesc!, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(bitPattern: 1)!)

        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        return ReplyInspection(
            status: status,
            errorNumber: replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
            errorString: replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue,
            resultDescriptor: replyDescriptor.paramDescriptor(forKeyword: keyAEResult))
    }

    /// A best-effort "whole application" object specifier: a record with the 4 keys an
    /// `NSScriptObjectSpecifier` decodes (`keyAEDesiredClass`='capp', `keyAEKeyForm`=formName,
    /// `keyAEKeyData`=this app's own scripting name, `keyAEContainer`=null, i.e. top-level),
    /// reinterpreted as `typeObjectSpecifier` — object specifiers are structurally records, so a
    /// `typeAERecord` with the right keys coerces cleanly. `NSApp.objectSpecifier` (AppKit's own
    /// supposed source for this) returned nil when tried directly — see
    /// `applicationObjectSpecifierIsNil` below — so this is hand-built instead. Best-effort and
    /// UNVERIFIED against Apple's own AppleScript compiler output (no network access to confirm
    /// the exact encoding `tell application "X" to Y` produces) — a result either way from the
    /// test that uses this is reported as exploratory, not conclusive.
    private static func wholeApplicationSpecifier() -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: ScriptingCodes.fourCharCode("capp")),
                              forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("name")),
                              forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(string: "Soft Return"),
                              forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return NSAppleEventDescriptor(descriptorType: DescType(typeObjectSpecifier), data: record.data)!
    }

    /// Control: identical to `AppleEventDispatchTests.inProcessConvertAppleEventProducesAnRTFFile`.
    /// Expected/known to pass — establishes this file's harness reproduces the existing green
    /// baseline before varying anything.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func withoutAnyExtraAttributesSucceeds() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "control")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = Self.buildAndDispatch(tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: control OSStatus=\(result.status)")
        #expect(result.status == noErr)
    }

    /// Job 207 leg 1 found this reproduction at Layer A (`dispatchRawAppleEvent`): dispatch
    /// status was `noErr` (matches field breadcrumbs — the command runs clean) but the
    /// reply's `keyAEResult` came back completely ABSENT — `ConvertCommand
    /// .performDefaultImplementation()` used to return a plain `NSDictionary`, which Cocoa
    /// has no automatic coercion from into the sdef's custom `SRrc` record type.
    ///
    /// Leg 3 fixed the TYPE (`ConvertCommand.replyDescriptor(for:)`, via the shared
    /// `ScriptingRecordBuilder` — see `ConvertCommandTests.replyDescriptorEncodesAllThreeFields`
    /// for proof the descriptor itself is well-formed and decodable). But re-running THIS
    /// test after the fix produced a NEW, deeper finding, not the expected green: the reply's
    /// `keyAEResult` is STILL absent — identical to before the fix. A temporary diagnostic
    /// added directly inside `performDefaultImplementation` (since removed) confirmed
    /// `execute()`'s own return value IS the correctly-typed, correctly-decodable descriptor,
    /// and `NSScriptCommand.current() === self` was `true` throughout — Cocoa's own
    /// documented criterion for "a command is being executed... by Cocoa Scripting's
    /// built-in Apple event handling" (`NSScriptCommand.h`) — yet `NSAppleEventManager
    /// .shared().currentReplyAppleEvent` still read back `typeNull` (`NSAppleEventManager.h`:
    /// "it should not be touched if the event sender has not requested a reply, which is
    /// indicated by [replyEvent descriptorType]==typeNull"), even for THIS test's own
    /// hand-built event, which explicitly sets `keyReplyRequestedAttr=true`.
    ///
    /// Conclusion: whatever Cocoa mechanism actually writes `execute()`'s return value into
    /// `keyAEResult` is a FOURTH dispatch-adjacent layer this investigation has now found —
    /// after (1) `NSScriptSuiteRegistry` sdef loading, (2) the raw `AEInstallEventHandler`
    /// table job 174/185 mapped, and (3) job 188's proof that `dispatchRawAppleEvent` never
    /// reaches that raw table — and it is unreachable from EITHER `dispatchRawAppleEvent`
    /// (this test) or a direct call to the fetched raw handler (Layer 2, see
    /// `replyResultDescriptorAtLayer2DecodesTheConversionResultRecord` below), regardless of
    /// what the command returns. This is a standing NEGATIVE result, kept as a permanent
    /// regression check (matching job 188's `dispatchRawAppleEventDoesNotReachTheInstalledTap`
    /// pattern) rather than deleted — if this ever starts passing, in-process reply-packaging
    /// verification has finally become possible and this whole file's "unverifiable" framing
    /// should be revisited.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func replyResultDescriptorRemainsAbsentEvenAfterTheTypeFix() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "reply-inspect-layerA")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reply = Self.buildAndDispatchInspectingReply(tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: reply-inspect-layerA OSStatus=\(reply.status) "
              + "errorNumber=\(String(describing: reply.errorNumber)) "
              + "resultDescriptor=\(String(describing: reply.resultDescriptor)) "
              + "resultDescriptorType=\(String(describing: reply.resultDescriptor?.descriptorType))")
        #expect(reply.status == noErr, "dispatch status itself is clean, matching field breadcrumbs")
        #expect(reply.resultDescriptor == nil,
                "recording current behavior — see this test's own doc comment for the full finding")
    }

    /// Job 216 (ae-result-shape): `ConvertCommand.performDefaultImplementation()` at the time
    /// this test was written returned a native `[NSURL]` (job 216's file-list result shape)
    /// instead of a hand-built custom-record `NSAppleEventDescriptor` (job 207's `SRrc`). The
    /// two prior findings above (`replyResultDescriptorRemainsAbsentEvenAfterTheTypeFix`/its
    /// Layer 2 sibling) were specific to that hand-built RECORD descriptor — this test checked
    /// whether a native array return fared any differently at the SAME in-process
    /// reply-inspection layer (`dispatchRawAppleEvent`, job 188/239b: NOT the same layer as a
    /// real `AESendMessage`'s own reply-packaging trampoline). It did not: `keyAEResult` was
    /// absent here too. Job 241 later proved WHY at the real trampoline layer — any LIST-shaped
    /// return value fails there regardless of shape, and moved `convert`'s result to text (see
    /// `ConvertCommand`'s own doc comment) — but this test's own finding, at THIS layer, was
    /// already shape-independent before that: `dispatchRawAppleEvent` never sees a populated
    /// reply for ANY return shape, so it stays exactly as informative run against the current
    /// (text) return value as it was against the old `[NSURL]` one. Left un-renamed on purpose;
    /// the name records what shape was under test historically, and the assertion is
    /// shape-agnostic by construction (`buildAndDispatchInspectingReply` dispatches whatever
    /// `ConvertCommand` currently returns, not a fixed value).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func replyResultDescriptorForTheNativeFileListReturnValueAlsoRemainsAbsent() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "reply-inspect-filelist")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reply = Self.buildAndDispatchInspectingReply(tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: reply-inspect-filelist OSStatus=\(reply.status) "
              + "errorNumber=\(String(describing: reply.errorNumber)) "
              + "resultDescriptor=\(String(describing: reply.resultDescriptor)) "
              + "resultDescriptorType=\(String(describing: reply.resultDescriptor?.descriptorType))")
        #expect(reply.status == noErr, "dispatch status itself is clean, matching field breadcrumbs")

        // The conversion side effect itself must still have happened — this is the one
        // channel job 216's own AppleEventLifecycleBreadcrumbs/field notes confirm IS
        // observable in-process even though the AE reply channel is not.
        let outputs = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        #expect(outputs.contains { $0.pathExtension == "rtf" },
                "the produced file itself should exist on disk even though keyAEResult is unreachable")

        #expect(reply.resultDescriptor == nil,
                "recording current behavior — convert's current (text) return fares no differently than job 207's hand-built record or job 216's old [NSURL] at this reply-inspection layer; see this test's own doc comment")
    }

    /// AppKit's documented (`NSObject(NSScriptObjectSpecifiers)`) mechanism for "an object that
    /// can provide a fully specified object specifier to itself" returning nil for `NSApp` is
    /// itself a fact worth recording regardless of the -1708 investigation: it means this app's
    /// `NSApplication` cannot represent itself as a specifier through the public, documented path
    /// AppKit provides for exactly this purpose (used e.g. answering "get application" or
    /// building a reply that itself contains a reference to the app).
    @Test @MainActor func applicationObjectSpecifierIsNil() {
        #expect(NSApp.objectSpecifier == nil,
                "recording current behavior — if this ever becomes non-nil, re-evaluate the hand-built specifier below")
    }

    /// Experiment 1: `keySubjectAttr` set to the best-effort whole-application specifier above.
    /// If this reproduces -1708 where the control does not, subject-attribute-driven receiver
    /// evaluation is implicated — but see the specifier's own doc comment on how unverified its
    /// encoding is.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func withHandBuiltSubjectAttribute() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "subject")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = Self.buildAndDispatch(
            subjectSpecifier: Self.wholeApplicationSpecifier(), tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: subject-attr OSStatus=\(result.status) "
              + "errorNumber=\(String(describing: result.errorNumber)) errorString=\(String(describing: result.errorString))")
        #expect(result.status == noErr,
                "a subject attribute (even this best-effort, unverified encoding) does not by itself derail dispatch")
    }

    /// Experiment 2: `keyAddressAttr`/`keyOriginalAddressAttr` set to a real bundle-identifier
    /// address descriptor (what a genuine cross-process `AESend` carries) instead of leaving them
    /// unset, as every prior in-process probe (143-181) has. `dispatchRawAppleEvent`'s own header
    /// doc says it "does not send events to other applications" — it is Cocoa's internal
    /// dispatch-table lookup, not the full central Apple Event Manager receive path — so this
    /// cannot prove what a REAL delivered event's attributes look like, only whether Cocoa's
    /// dispatch logic branches on their presence at all.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func withRealAddressAttributes() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "address")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let address = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let result = Self.buildAndDispatch(
            target: address, addressAttr: address, tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: address-attr OSStatus=\(result.status) "
              + "errorNumber=\(String(describing: result.errorNumber)) errorString=\(String(describing: result.errorString))")
        #expect(result.status == noErr,
                "a real bundle-ID address attribute does not by itself derail dispatch")
    }

    /// Experiment 3: both of the above together.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func withSubjectAndAddressAttributesTogether() throws {
        _ = NSScriptSuiteRegistry.shared()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "both")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let address = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let result = Self.buildAndDispatch(
            target: address, subjectSpecifier: Self.wholeApplicationSpecifier(), addressAttr: address,
            tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: subject+address OSStatus=\(result.status) "
              + "errorNumber=\(String(describing: result.errorNumber)) errorString=\(String(describing: result.errorString))")
        #expect(result.status == noErr,
                "subject + address attributes together do not by themselves derail dispatch")
    }

    /// Job 188: verifies the tap's descriptor-capture machinery (`AppleEventDiagnosticTap.
    /// safeDescription(of:)`/`safeFlattenedBase64(of:)`/`recordEventCapture`) against a REAL,
    /// non-trivial `convert` event — the exact same event shape `buildAndDispatch` sends through
    /// Cocoa's dispatch table above — not a synthetic minimal descriptor.
    ///
    /// This does NOT drive the capture through the installed raw `AEInstallEventHandler` tap
    /// itself: an earlier version of this test did exactly that (dispatched via
    /// `buildAndDispatch` and then asserted on `AppleEventDiagnosticTap.readState()`), and it
    /// empirically proved `dispatchRawAppleEvent` never reaches that tap at all — `lastForward
    /// Result`/`lastEventDescription` stayed at whatever a PRIOR real arrival had left them
    /// (`arrivals` unchanged by the dispatch), even though the dispatch itself returned `noErr`
    /// and produced a real `.rtf`. That is new, reportable evidence for the -1708 investigation
    /// (`dispatchRawAppleEvent` and the raw Carbon handler table are corroborated as genuinely
    /// separate dispatch layers, not just theorized as such — see this file's own header doc and
    /// the job 188 report), but it means this file cannot exercise the tap's REAL end-to-end path
    /// safely: the only in-process way to reach the raw handler directly is `AEGetEventHandler` +
    /// a bare C call, which job 185 removed after it crashed the full suite (self-reinstall
    /// recursion — see this file's trailing comment block) and this job's own brief says not to
    /// resurrect. So this test calls the same serialization functions the tap's handler body
    /// calls, directly, against a real built event — the part of job 188 that is actually new and
    /// risk-bearing (the `AEDuplicateDesc`/`AEFlattenDesc` arithmetic) — via a throwaway defaults
    /// suite, never touching real Carbon handler-table state.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func tapSerializationCapturesARealConvertEventDescriptor() throws {
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "tap-serialize")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let event = Self.buildEvent(tempDir: tempDir, source: source)

        let description = AppleEventDiagnosticTap.safeDescription(of: event.aeDesc)
        let flattened = AppleEventDiagnosticTap.safeFlattenedBase64(of: event.aeDesc)
        print("ConvertCommandReceiverDispatchTests: tap-serialize description=\(description)")

        let defaults = UserDefaults(suiteName: "ConvertCommandReceiverDispatchTests.\(UUID().uuidString)")!
        AppleEventDiagnosticTap.recordEventCapture(description: description, flattenedBase64: flattened, defaults: defaults)

        let state = AppleEventDiagnosticTap.readState(defaults: defaults)
        let capturedDescription = try #require(state.lastEventDescription)
        let capturedFlattened = try #require(state.lastEventFlattened)
        #expect(!capturedDescription.isEmpty)
        #expect(capturedDescription.contains("SRsu") || capturedDescription.contains("conv"),
                "expected the real event class/ID to show up in its own description: \(capturedDescription)")
        #expect(!capturedFlattened.isEmpty)
        #expect(Data(base64Encoded: capturedFlattened) != nil, "lastEventFlattened must be valid base64")
    }

    /// Job 188 companion: the earlier version of the test above, which drove the capture through
    /// `dispatchRawAppleEvent` and the ALREADY-installed real tap (`AppDelegate.
    /// applicationWillFinishLaunching`'s `AppleEventDiagnosticTap.install()`), asserting on
    /// `AppleEventDiagnosticTap.readState()` (the real `UserDefaults.standard` domain) — kept here
    /// as a standing NEGATIVE-result regression check, not removed, since "dispatchRawAppleEvent
    /// does not reach the raw handler" is itself the finding this job needs on record. Does NOT
    /// call `AppleEventDiagnosticTap.install(...)` again (job 185's recursion finding).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func dispatchRawAppleEventDoesNotReachTheInstalledTap() throws {
        _ = NSScriptSuiteRegistry.shared()
        let before = AppleEventDiagnosticTap.readState()
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "tap-negative")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = Self.buildAndDispatch(tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: tap-negative OSStatus=\(result.status)")
        #expect(result.status == noErr)

        let after = AppleEventDiagnosticTap.readState()
        #expect(after.arrivals.count == before.arrivals.count,
                "dispatchRawAppleEvent recorded a NEW tap arrival — if this ever fails, the two dispatch layers are no longer separate and the test above should be revisited to assert through the real tap instead")
    }

    @MainActor
    private static func freshTempDirAndSource(label: String) throws -> (tempDir: URL, source: URL) {
        let source = MultipageMargins.testDocsDirectory.appendingPathComponent("ws4/INDIAN.ws")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertCommandReceiverDispatchTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, source)
    }

    // MARK: - Layer 2: bypass dispatchRawAppleEvent entirely, call the installed Carbon handler
    //
    // A test here (`directlyInvokingTheInstalledHandlerReproducesTheFieldFailure`, since
    // removed) fetched whatever is CURRENTLY installed for `('SRsu','conv')` via
    // `AEGetEventHandler` and called it as a bare C function — no `AESend`, no transport, so
    // registry mistake #16 (self-addressed `AESendMessage` SIGSEGVs in this hosted test bundle)
    // does not apply to it directly. Run alone (`-only-testing` scoped to just this suite), it
    // returned `noErr` — one more layer, still no -1708 reproduction. Run as part of the FULL
    // suite, it CRASHED the host process ("Crash: Soft Return at <external symbol>", i.e. a
    // Signal 11 with no Swift-level stack trace, consistent with unbounded recursion inside a C
    // function called through a UPP).
    //
    // Root cause, traced (not fixed — out of this job's scope, and `AppleEventDiagnosticTap.swift`
    // belongs to job 174): `AppleEventDiagnosticTapSelfSendTests.installRecordsInstalledAtAndPriorHandlerPresent`
    // calls `AppleEventDiagnosticTap.install(defaults:)` a SECOND time in the same process (the
    // app's own `AppDelegate` already called it once at launch). `install()` keeps its captured
    // `priorHandler`/`priorRefcon` in `nonisolated(unsafe) static var`s shared by the WHOLE type,
    // not per-installation. On that second call, `AEGetEventHandler` fetches "whatever is
    // currently installed" — which, by then, IS the tap's own `tapHandler` closure from the FIRST
    // install — and saves `tapHandler` as its own `priorHandler`. The static var now points to
    // itself. The next time anything actually INVOKES the installed handler (nothing did, before
    // this job — `AppleEventDiagnosticTapSelfSendTests`'s own doc comment explains it deliberately
    // stops at install-time assertions and never sends a real event), `tapHandler` calls itself
    // through `prior(...)` forever, unwinding the stack until the process dies.
    //
    // This is a real, latent bug (self-reinstallation makes `AppleEventDiagnosticTap` recurse
    // infinitely on the next real arrival) but is orthogonal to the -1708 investigation itself —
    // it only reproduces because of test-host state shared across two independently-written test
    // files, not because of anything a real single-launch app process does. Recorded here and in
    // the job report rather than fixed, per this job's scope (ConvertCommand dispatch +
    // ScriptingFileArgument hardening only); flagged for whoever next touches
    // `AppleEventDiagnosticTap.swift`.
    //
    // UPDATE, job 198: no longer latent — this job needs to invoke the installed handler
    // directly, permanently, as a regression fixture that runs under the full suite (which
    // still includes `AppleEventDiagnosticTapSelfSendTests`'s independent `install()` call), so
    // leaving this recursion possible was no longer acceptable. Fixed at the root in
    // `AppleEventDiagnosticTap.install()` itself (a re-entrancy guard: only the FIRST call in a
    // process may touch Carbon AE Manager state), not by avoiding the call pattern here.
}

// MARK: - Layer 3 (job 198): replay the REAL field-captured event bytes

/// Job 198 (b10 leg 1, continuing 143-188). b9's tap (job 188) finally captured the ACTUAL
/// bytes of a real `osascript`-sent `convert` event that fails with -1708 on Jon's field
/// machine — committed at `Fixtures/real-convert-event-b9.base64` (`AEFlattenDesc` format).
/// Every event jobs 143-185 ever hand-built, at every reachable dispatch layer, SUCCEEDED —
/// the working hypothesis going in was that the poison would be in what differs between a
/// hand-built event and this real one (`subj`=null, `csig`, `shas`, real `addr`/`from`, `SRcy`
/// as a scalar). This extension decodes the real bytes and replays them through Layer 2's
/// exact mechanism (`AEGetEventHandler` + a bare call — never `install()` again). RESULT: the
/// real bytes ALSO come back `noErr`, same as every hand-built event before them — no
/// bisection follows, because there is nothing to bisect when the baseline itself doesn't
/// fail. See this job's report for what that means for the standing investigation.
extension ConvertCommandReceiverDispatchTests {
    /// `SoftReturnTests/Fixtures/real-convert-event-b9.base64` — read from the SOURCE tree via
    /// `#filePath`, same convention as `Oracle.fixturesDirectory`/
    /// `MultipageMargins.testDocsDirectory`: this project's synchronized file group does not
    /// copy arbitrary data files into the test bundle.
    private static var realFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/real-convert-event-b9.base64")
    }

    /// Decodes the committed base64 fixture into an `NSAppleEventDescriptor` that owns the
    /// underlying `AEDesc` (via `aeDescNoCopy:`, which takes ownership and disposes at
    /// deinit — see `AppleEventDiagnosticTap.safeDescription`'s own doc comment on this).
    /// `AEUnflattenDescFromBytes`, not the older `AEUnflattenDesc`, which `AEDataModel.h` marks
    /// `API_DEPRECATED_WITH_REPLACEMENT` as of macOS 11 — confirmed against the actual header,
    /// not assumed (00-METHOD).
    private static func loadRealFixtureDescriptor() throws -> NSAppleEventDescriptor {
        let base64 = try String(contentsOf: realFixtureURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = try #require(Data(base64Encoded: base64), "fixture is not valid base64")
        var result = AEDesc()
        let status = bytes.withUnsafeBytes { raw in
            AEUnflattenDescFromBytes(raw.baseAddress, raw.count, &result)
        }
        #expect(status == noErr, "AEUnflattenDescFromBytes failed: OSStatus \(status)")
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }

    /// Fetches whatever is CURRENTLY installed for `('SRsu','conv')` (in this process that's
    /// the job-174 tap, installed once by `AppDelegate` at real launch, forwarding faithfully
    /// to Cocoa's own captured handler) and invokes it directly with `event` — no `AESend`, no
    /// transport, so registry mistake #16 (self-addressed `AESendMessage` SIGSEGVs) does not
    /// apply. Never calls `install()` itself.
    @MainActor
    private static func invokeInstalledHandler(with event: NSAppleEventDescriptor) throws -> DispatchResult {
        let eventClass = ScriptingCodes.fourCharCode("SRsu")
        let eventID = ScriptingCodes.fourCharCode("conv")
        var handler: AEEventHandlerUPP?
        var handlerRefcon: UnsafeMutableRawPointer?
        let getStatus = AEGetEventHandler(eventClass, eventID, &handler, &handlerRefcon, false)
        let installedHandler = try #require(
            getStatus == noErr ? handler : nil,
            "no handler installed for ('SRsu','conv') — AEGetEventHandler status \(getStatus)")

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = installedHandler(event.aeDesc!, &reply, handlerRefcon)
        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let errorString = replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue
        return DispatchResult(status: status, errorNumber: errorNumber, errorString: errorString)
    }

    /// Job 207: Layer 2 equivalent of `buildAndDispatchInspectingReply` — invokes whatever is
    /// CURRENTLY installed for `('SRsu','conv')` directly (no `AESend`, no transport) and
    /// reads `keyAEResult` off the reply this call itself fills in. This is the layer closest
    /// to what a real cross-process delivery's own reply-packaging path runs, since
    /// `dispatchRawAppleEvent`'s own header doc disclaims sending/replying to other
    /// applications.
    @MainActor
    private static func invokeInstalledHandlerInspectingReply(
        tempDir: URL, source: URL
    ) throws -> ReplyInspection {
        let event = Self.buildEvent(tempDir: tempDir, source: source)
        let eventClass = ScriptingCodes.fourCharCode("SRsu")
        let eventID = ScriptingCodes.fourCharCode("conv")
        var handler: AEEventHandlerUPP?
        var handlerRefcon: UnsafeMutableRawPointer?
        let getStatus = AEGetEventHandler(eventClass, eventID, &handler, &handlerRefcon, false)
        let installedHandler = try #require(
            getStatus == noErr ? handler : nil,
            "no handler installed for ('SRsu','conv') — AEGetEventHandler status \(getStatus)")

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = installedHandler(event.aeDesc!, &reply, handlerRefcon)
        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        return ReplyInspection(
            status: status,
            errorNumber: replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
            errorString: replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue,
            resultDescriptor: replyDescriptor.paramDescriptor(forKeyword: keyAEResult))
    }

    /// Positive control (field-notes' "an instrument that has only ever returned one answer is
    /// untested" rule): before trusting any handler-invocation result below, prove the decode
    /// itself is real — the unflattened descriptor's own event class/ID must read back as
    /// `'SRsu'`/`'conv'`, matching this job's brief verbatim.
    @Test func realFixtureDecodesToTheRealConvertEvent() throws {
        let event = try Self.loadRealFixtureDescriptor()
        #expect(event.eventClass == ScriptingCodes.fourCharCode("SRsu"))
        #expect(event.eventID == ScriptingCodes.fourCharCode("conv"))
    }

    /// Job 207 leg 3: `NSAppleEventManager.h`'s own doc comment says the reply passed to a
    /// Cocoa-dispatched handler "should not be touched if the event sender has not requested
    /// a reply, which is indicated by [replyEvent descriptorType]==typeNull" — and Layer 2's
    /// `currentReplyAppleEvent` came back exactly `typeNull` even for this real fixture. This
    /// rules out the obvious explanation: the real captured event DOES carry
    /// `keyReplyRequestedAttr=true` (confirmed here), same as every hand-built event in this
    /// file (`buildEvent` sets it explicitly) — and both show the identical `typeNull` reply
    /// in-process regardless. Whatever decides `currentReplyAppleEvent`'s type is not simply
    /// reading this attribute the way the header's prose might suggest at a glance.
    @Test func realFixtureReplyRequestedAttribute() throws {
        let event = try Self.loadRealFixtureDescriptor()
        let replyRequested = event.attributeDescriptor(forKeyword: AEKeyword(keyReplyRequestedAttr))
        print("ConvertCommandReceiverDispatchTests: real fixture keyReplyRequestedAttr="
              + "\(String(describing: replyRequested)) boolValue=\(String(describing: replyRequested?.booleanValue))")
        #expect(replyRequested?.booleanValue == true, "the real field machine's own event did request a reply")
    }

    /// Stronger positive control, field-notes' "prove the instrument can produce a positive
    /// result before trusting a negative" rule: `AEUnflattenDescFromBytes`'s contract is a
    /// full-fidelity round trip of what `AEFlattenDesc` produced, but that is the API's claim,
    /// not yet this job's own verification — confirm the ATTRIBUTES the brief calls out by name
    /// (subj/csig/shas), not just event class/ID, actually survive the decode before trusting
    /// any handler-invocation result (reproduction OR bisection) built on top of it.
    @Test func realFixtureAttributesSurviveTheUnflatten() throws {
        let event = try Self.loadRealFixtureDescriptor()
        let subj = event.attributeDescriptor(forKeyword: AEKeyword(keySubjectAttr))
        #expect(subj?.descriptorType == typeNull, "expected subj attribute present as typeNull, got \(String(describing: subj))")

        // `.data` reflects HOST byte order for scalar numeric types (confirmed empirically: the
        // wire bytes are big-endian 00 01 00 00, `.data` here returned little-endian-reordered
        // 00 00 01 00 — same value, 65536, different byte layout) — compare the decoded value
        // via `.int32Value`, not raw bytes.
        let csig = event.attributeDescriptor(forKeyword: ScriptingCodes.fourCharCode("csig"))
        #expect(csig?.descriptorType == ScriptingCodes.fourCharCode("magn"))
        #expect(csig?.int32Value == 65536, "expected csig magnitude 65536, got \(String(describing: csig?.int32Value))")

        let shas = event.attributeDescriptor(forKeyword: ScriptingCodes.fourCharCode("shas"))
        #expect(shas?.descriptorType == typeAEList, "expected shas present as a list, got \(String(describing: shas))")
        let sbhs = shas?.atIndex(1)
        #expect(sbhs?.descriptorType == ScriptingCodes.fourCharCode("sbhs"))
        let sbhsString = sbhs.flatMap { String(data: $0.data, encoding: .utf8) }
        #expect(sbhsString?.lowercased().contains("indian2.ws") == true, "expected the sandbox-hash-string to name the real field file, got \(String(describing: sbhsString))")
    }

    /// THE reproduction attempt — and, empirically, a NEW negative result, not a positive one.
    /// Job 174/181's field tap showed the REAL captured event, forwarded to Cocoa's own
    /// captured handler, returns -1708 on the field machine — but only as inferred from a
    /// `defaults read` there, never replayed and asserted in a harness before this job. This
    /// does that, and the literal captured bytes — verified intact by
    /// `realFixtureAttributesSurviveTheUnflatten` above, so this is not a decode artifact —
    /// come back `noErr` at Layer 2 (`AEGetEventHandler` + a direct call), every time, in this
    /// process. This EXTENDS (does not merely repeat) job 185's conclusion: it was already
    /// known that no HAND-BUILT event reproduces -1708 at any in-process layer; this job shows
    /// the literal FIELD-CAPTURED bytes don't either, at the deepest layer reachable in-process.
    /// See this job's own report for the standing-investigation update — no bisection follows
    /// because there is nothing here to bisect: the baseline itself does not fail.
    @Test @MainActor func realFieldEventDoesNotReproduceTheFieldFailureAtLayer2() throws {
        let event = try Self.loadRealFixtureDescriptor()
        let result = try Self.invokeInstalledHandler(with: event)
        print("ConvertCommandReceiverDispatchTests: real-field-event OSStatus=\(result.status) "
              + "errorNumber=\(String(describing: result.errorNumber)) errorString=\(String(describing: result.errorString))")
        #expect(result.status == noErr,
                "the real field bytes, replayed through the installed handler, returned OSStatus \(result.status) — if this ever fails, in-process reproduction has finally been achieved and this test should be inverted into the permanent regression fixture")
    }

    /// Corroborating check, NOT a bisection (there is nothing to bisect when the baseline
    /// itself doesn't fail — see the test above): does a hand-BUILT mimic replicating every
    /// attribute this job's brief named as a candidate poison (`subj`=null, `csig`=magnitude
    /// 65536, `shas`=sandbox-hash-string list, real `addr`/`from` PSNs, `SRcy` as a bare scalar
    /// enum rather than a list — the real bytes carry `SRcyenum....SRfr`, not a list) ALSO
    /// succeed at Layer 2? If it did NOT (i.e. reconstruction failed where the real bytes
    /// succeeded, or vice versa), that divergence would itself be informative. It does — one
    /// more convergent data point that nothing constructible in-process, byte-exact or
    /// hand-built, reproduces this bug.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func realisticMimicOfEveryNamedAttributeAlsoDoesNotReproduce() throws {
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "full-mimic")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode("SRsu"),
            eventID: ScriptingCodes.fourCharCode("conv"),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(boolean: true), forKeyword: keyReplyRequestedAttr)
        event.setAttribute(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keySubjectAttr))

        let csig = NSAppleEventDescriptor(
            descriptorType: ScriptingCodes.fourCharCode("magn"), data: Data([0x00, 0x01, 0x00, 0x00]))!
        event.setAttribute(csig, forKeyword: ScriptingCodes.fourCharCode("csig"))

        let realSandboxHashString =
            "bff9caff83d106e1086bf740627709bf22c4a47384e45a86daf38bed75db9970;00;00000000;00000000;"
            + "00000000;0000000000000020;com.apple.app-sandbox.read-write;01;01000011;"
            + "0000000005af26e4;01;/users/jon/dropbox/projects_writing/jmwork1-ws-floppy/work/indian2.ws"
        let sbhs = NSAppleEventDescriptor(
            descriptorType: ScriptingCodes.fourCharCode("sbhs"), data: Data(realSandboxHashString.utf8))!
        let shasList = NSAppleEventDescriptor.list()
        shasList.insert(sbhs, at: 0)
        event.setAttribute(shasList, forKeyword: ScriptingCodes.fourCharCode("shas"))

        // Real fixture's `addr`/`from` bytes verbatim: `psn `, high=1 low=0x135B.
        let psn = NSAppleEventDescriptor(
            descriptorType: ScriptingCodes.fourCharCode("psn "),
            data: Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x13, 0x5b]))!
        event.setAttribute(psn, forKeyword: keyAddressAttr)
        event.setAttribute(psn, forKeyword: AEKeyword(keyOriginalAddressAttr))

        let fileList = NSAppleEventDescriptor.list()
        fileList.insert(NSAppleEventDescriptor(fileURL: source), at: 0)
        event.setParam(fileList, forKeyword: keyDirectObject)

        // Bare scalar, not a list — the real bytes carry `SRcyenum....SRfr` directly.
        event.setParam(NSAppleEventDescriptor(enumCode: ScriptingCodes.fourCharCode("SRfr")),
                        forKeyword: ScriptingCodes.fourCharCode("SRcy"))
        event.setParam(NSAppleEventDescriptor(fileURL: tempDir), forKeyword: ScriptingCodes.fourCharCode("SRcf"))

        let result = try Self.invokeInstalledHandler(with: event)
        print("ConvertCommandReceiverDispatchTests: full-mimic OSStatus=\(result.status) "
              + "errorNumber=\(String(describing: result.errorNumber)) errorString=\(String(describing: result.errorString))")
        #expect(result.status == noErr,
                "a hand-built mimic of every named candidate attribute returned OSStatus \(result.status) instead of noErr — this WOULD be the bisection's starting point if it ever happens")
    }

    /// Job 207 leg 1 found this reproduction at Layer 2 (`AEGetEventHandler` + a direct
    /// call) — the layer closest to what a real cross-process delivery's own
    /// reply-packaging path runs, since `dispatchRawAppleEvent`'s own header doc disclaims
    /// sending/replying to other applications. Same finding as `replyResultDescriptorRemains
    /// AbsentEvenAfterTheTypeFix` above, one layer deeper: still absent after the type fix —
    /// see that test's doc comment for the full standing-investigation conclusion
    /// (`NSScriptCommand.current() === self` proven `true` here too, `currentReplyAppleEvent`
    /// still `typeNull`).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func replyResultDescriptorAtLayer2RemainsAbsentEvenAfterTheTypeFix() throws {
        let (tempDir, source) = try Self.freshTempDirAndSource(label: "reply-inspect-layer2")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reply = try Self.invokeInstalledHandlerInspectingReply(tempDir: tempDir, source: source)
        print("ConvertCommandReceiverDispatchTests: reply-inspect-layer2 OSStatus=\(reply.status) "
              + "errorNumber=\(String(describing: reply.errorNumber)) "
              + "errorString=\(String(describing: reply.errorString)) "
              + "resultDescriptor=\(String(describing: reply.resultDescriptor)) "
              + "resultDescriptorType=\(String(describing: reply.resultDescriptor?.descriptorType))")
        #expect(reply.status == noErr, "dispatch status itself is clean, matching field breadcrumbs")
        #expect(reply.resultDescriptor == nil,
                "recording current behavior — see replyResultDescriptorRemainsAbsentEvenAfterTheTypeFix's doc comment")
    }

    /// Job 207: the REAL field-captured event bytes (job 188/198's fixture), replayed through
    /// Layer 2 with the reply's `keyAEResult` inspected — the closest this investigation can
    /// get, in-process, to what the real field machine's reply actually contained the moment
    /// it told `osascript` -1708. Same standing finding as the two tests above: `keyAEResult`
    /// is absent even after the type fix, even for the literal real bytes.
    @Test @MainActor func realFieldEventReplyResultDescriptorRemainsAbsentEvenAfterTheTypeFix() throws {
        let event = try Self.loadRealFixtureDescriptor()
        let eventClass = ScriptingCodes.fourCharCode("SRsu")
        let eventID = ScriptingCodes.fourCharCode("conv")
        var handler: AEEventHandlerUPP?
        var handlerRefcon: UnsafeMutableRawPointer?
        let getStatus = AEGetEventHandler(eventClass, eventID, &handler, &handlerRefcon, false)
        let installedHandler = try #require(
            getStatus == noErr ? handler : nil,
            "no handler installed for ('SRsu','conv') — AEGetEventHandler status \(getStatus)")

        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = installedHandler(event.aeDesc!, &reply, handlerRefcon)
        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let resultDescriptor = replyDescriptor.paramDescriptor(forKeyword: keyAEResult)
        print("ConvertCommandReceiverDispatchTests: real-field-event reply-inspect OSStatus=\(status) "
              + "errorNumber=\(String(describing: errorNumber)) "
              + "resultDescriptor=\(String(describing: resultDescriptor)) "
              + "resultDescriptorType=\(String(describing: resultDescriptor?.descriptorType))")
        #expect(status == noErr, "dispatch status itself is clean, matching field breadcrumbs")
        #expect(resultDescriptor == nil,
                "recording current behavior — see replyResultDescriptorRemainsAbsentEvenAfterTheTypeFix's doc comment")
    }
}
