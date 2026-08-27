#if DEBUG
import AppKit
import CoreServices
import Foundation
import ObjectiveC

/// Job 239b (`ae-layer-probe`, rerun of self-killed 239, continuing 235-238). Jobs 235-238
/// proved the SAME event is dispatched TWICE (job 237's merged timeline), that Cocoa executes
/// `ConvertCommand`'s real dispatch (job 238: exactly once, post-`<responds-to>`), and that
/// `AESendMessage`'s own `OSStatus` is still -1708 with empty reply error params regardless.
/// `AppleEventDiagnosticTap` (job 174) already chain-wraps the raw `AEInstallEventHandler` proc
/// Cocoa Scripting installs for `('SRsu','conv')` and records that proc's own `OSStatus`
/// return — the layer BELOW this one. This file adds the layer ABOVE it:
/// `-[NSAppleEventManager dispatchRawAppleEvent:withRawReply:handlerRefCon:]`, Cocoa's own
/// internal AE-routing entry point (`NSAppleEventManager.h`: "primarily meant for Cocoa's
/// internal use... does not send events to other applications"). Whichever of these two layers
/// is the first to show -1708 above a layer that actually succeeded NAMES the bug — that is
/// this job's whole point, not a fix attempt.
///
/// Swizzled the same way `SuiteRegistrationProbe` (job 236) swizzles `loadSuites(from:)`:
/// exchange implementations via the ObjC runtime, call straight through, record what was
/// observed. Exact signature confirmed by compiling and running a throwaway probe against the
/// real SDK declaration (`type(of:)` on a bound method reference), not guessed: `(UnsafePointer
/// <AEDesc>, UnsafeMutablePointer<AEDesc>, UnsafeMutableRawPointer) -> Int16` — see the job
/// report for the probe transcript.
///
/// Filtered to `'SRsu'`-class events only, read via `AEDuplicateDesc` on a COPY of the raw
/// descriptor — never the original — the same "never touch what gets forwarded" discipline
/// `AppleEventDiagnosticTap.safeDescription`/`safeFlattenedBase64` already established, because
/// this method routes every Apple Event Cocoa dispatches this way (menu commands, window
/// handling, standard-suite verbs), not just this app's custom suite.
///
/// `#if DEBUG` + `SRDiagnosticsGate`, matching every other interception-based instrument in this
/// module (job 219's ruling): a method swizzle changes process-wide dispatch, so it stays out of
/// Release regardless of the fact that it calls straight through and changes no observable
/// behavior — the same posture `SuiteRegistrationProbe` already takes.
enum AppleEventDispatchSwizzle {
    struct Call: Equatable {
        let monotonic: Double
        let originalReturn: Int32
        let replyErrorNumber: Int32?
        let replyErrorString: String?
    }

    fileprivate nonisolated(unsafe) static var calls: [Call] = []
    private static let lock = NSLock()
    private nonisolated(unsafe) static var didSwizzle = false
    fileprivate static let watchedEventClass: AEEventClass = ScriptingCodes.fourCharCode("SRsu")

    /// Call as early as possible in the launch sequence — before any code, ours or Cocoa's,
    /// might route a raw Apple Event through this method — so no invocation is missed. Same
    /// ordering discipline as `SuiteRegistrationProbe.install()`, installed alongside it.
    static func install() {
        guard !didSwizzle else { return }
        didSwizzle = true

        let cls = NSAppleEventManager.self
        let originalSelector = #selector(NSAppleEventManager.dispatchRawAppleEvent(_:withRawReply:handlerRefCon:))
        let swizzledSelector = #selector(NSAppleEventManager.sr_probe_dispatchRawAppleEvent(_:withRawReply:handlerRefCon:))

        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    fileprivate static func recordCall(_ call: Call) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }

    static func recordedCalls() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Test-only reset — the swizzle itself is process-global and permanent by design (same
    /// rationale as `SuiteRegistrationProbe.resetLog()`), but the call LOG must not leak
    /// between test cases in the same process.
    static func resetLog() {
        lock.lock()
        defer { lock.unlock() }
        calls.removeAll()
    }

    fileprivate static func eventClass(of desc: UnsafePointer<AEDesc>) -> AEEventClass? {
        var duplicate = AEDesc()
        guard AEDuplicateDesc(desc, &duplicate) == noErr else { return nil }
        let wrapped = NSAppleEventDescriptor(aeDescNoCopy: &duplicate)
        return wrapped.attributeDescriptor(forKeyword: keyEventClassAttr)?.typeCodeValue
    }

    fileprivate static func replyError(of desc: UnsafePointer<AEDesc>) -> (number: Int32?, string: String?) {
        var duplicate = AEDesc()
        guard AEDuplicateDesc(desc, &duplicate) == noErr else { return (nil, nil) }
        let wrapped = NSAppleEventDescriptor(aeDescNoCopy: &duplicate)
        return (wrapped.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value,
                wrapped.paramDescriptor(forKeyword: keyErrorString)?.stringValue)
    }
}

extension NSAppleEventManager {
    /// Named after the swizzle, not the original — after `method_exchangeImplementations`, THIS
    /// implementation is what the ORIGINAL selector (`dispatchRawAppleEvent:withRawReply:
    /// handlerRefCon:`) invokes, and calling `self.sr_probe_dispatchRawAppleEvent(...)` from
    /// inside it dispatches to the real original implementation now living under this selector.
    /// Same trampoline shape as `SuiteRegistrationProbe.sr_probe_loadSuites(from:)`.
    @objc fileprivate func sr_probe_dispatchRawAppleEvent(
        _ theAppleEvent: UnsafePointer<AEDesc>, withRawReply theReply: UnsafeMutablePointer<AEDesc>,
        handlerRefCon: UnsafeMutableRawPointer
    ) -> Int16 {
        let isWatched = AppleEventDispatchSwizzle.eventClass(of: theAppleEvent) == AppleEventDispatchSwizzle.watchedEventClass
        let result = self.sr_probe_dispatchRawAppleEvent(theAppleEvent, withRawReply: theReply, handlerRefCon: handlerRefCon)
        if isWatched {
            let monotonic = ProcessInfo.processInfo.systemUptime
            let error = AppleEventDispatchSwizzle.replyError(of: theReply)
            AppleEventDispatchSwizzle.recordCall(AppleEventDispatchSwizzle.Call(
                monotonic: monotonic, originalReturn: Int32(result),
                replyErrorNumber: error.number, replyErrorString: error.string))
        }
        return result
    }
}
#endif
