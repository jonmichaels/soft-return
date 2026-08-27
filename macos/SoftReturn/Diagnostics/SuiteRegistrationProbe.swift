#if DEBUG
import AppKit
import ObjectiveC

/// Job 236 (-1708 dedup-dispatch investigation, continuing 143-235). Job 235 witnessed
/// `ConvertCommand` constructed 2-3x per single `AESendMessage`, with the sender's own
/// `AESendMessage` status still -1708 despite a real, successful (if duplicated) execution.
/// The brief's hypothesis to TEST FIRST, not assume: `AppDelegate.applicationWillFinishLaunching`
/// calls `NSScriptSuiteRegistry.shared().loadSuites(from: Bundle.main)` (job 144) to close the
/// lazy-load window `AppleEventVirginDispatchTests` guards — but Cocoa Scripting is documented
/// to load suites automatically before dispatching the first Apple Event too, so the manual call
/// may be redundant with an automatic one Cocoa performs on its own, and TWO loads could mean
/// the registry ends up with the "Soft Return Suite" mapped more than once — which would explain
/// a single incoming event producing more than one `ConvertCommand` construction downstream.
///
/// This measures that directly rather than reasoning about undocumented internals: swizzle the
/// exact public method both this app and (per the hypothesis) Cocoa itself would call —
/// `NSScriptSuiteRegistry.loadSuites(from:)`, bridging to the Objective-C selector
/// `loadSuitesFromBundle:` — and count every invocation, ours and anyone else's, with a
/// timestamp and the call-stack symbol immediately above the swizzled trampoline so a second
/// call from OUTSIDE `AppDelegate` (i.e. not `AppDelegate.swift:44`) is distinguishable from a
/// duplicate call we ourselves issued.
///
/// `#if DEBUG` and gated behind `SRDiagnosticsGate`, matching this module's every other
/// interception-based instrument (`AppleEventDiagnosticTap`): a method swizzle is a change to
/// process-wide dispatch, the same class of risk job 219's ruling reserves for Debug-only,
/// explicitly-opted-in builds — never the shipping Release binary. Read-only registry/handler
/// introspection (`ScriptingRegistryProbe`, `AppleEventSelfSendProbe`'s own registry snapshot)
/// needs no such gate because it changes nothing; this does change something (still nothing
/// OBSERVABLE — the swizzle calls straight through to the original implementation, exactly the
/// "forwards faithfully" posture `AppleEventDiagnosticTap` already established), so it gets the
/// same guard anyway.
enum SuiteRegistrationProbe {
    struct Call: Equatable {
        let at: Date
        let callerSymbol: String
    }

    fileprivate nonisolated(unsafe) static var calls: [Call] = []
    private static let lock = NSLock()
    private nonisolated(unsafe) static var didSwizzle = false

    /// Call once, BEFORE any code in this process (ours or Cocoa's) might call
    /// `loadSuites(from:)` — from `AppDelegate.applicationWillFinishLaunching`, immediately
    /// ahead of job 144's own manual call, so that call itself is the first one counted.
    static func install() {
        guard !didSwizzle else { return }
        didSwizzle = true

        let cls = NSScriptSuiteRegistry.self
        let originalSelector = #selector(NSScriptSuiteRegistry.loadSuites(from:))
        let swizzledSelector = #selector(NSScriptSuiteRegistry.sr_probe_loadSuites(from:))

        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    fileprivate static func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        // The exact frame index of "the actual caller" depends on how many trampolines the
        // Swift/Objective-C bridge inserts around a swizzled `@objc` method (the native Swift
        // entry point AND its ObjC "To" thunk both appear before the real caller) — rather than
        // guess an index and risk silently recording the wrong frame (indistinguishable from a
        // right one without independently knowing the true caller), keep the first 6 frames
        // verbatim and let the report reader identify the real caller by name, matching this
        // module's "an instrument that has only ever returned one answer is untested" discipline.
        let callerSymbol = Thread.callStackSymbols.prefix(6).joined(separator: " <- ")
        calls.append(Call(at: Date(), callerSymbol: callerSymbol))
    }

    static func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    static func recordedCalls() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Test-only reset — `install()`'s swizzle is process-global and permanent by design (Carbon/
    /// AppKit give no way to un-swizzle safely once other code may already hold the exchanged
    /// IMP), but the call LOG itself must not leak between test cases in the same process.
    static func resetLog() {
        lock.lock()
        defer { lock.unlock() }
        calls.removeAll()
    }
}

extension NSScriptSuiteRegistry {
    /// Named after the swizzle, not the original — after `method_exchangeImplementations`, THIS
    /// implementation is what the ORIGINAL selector (`loadSuites(from:)`) invokes, and calling
    /// `self.sr_probe_loadSuites(from:)` from inside it dispatches to the real original
    /// implementation now living under this selector. Same trampoline shape as any Cocoa
    /// swizzle; the naming is confusing by construction, not by accident.
    @objc fileprivate func sr_probe_loadSuites(from bundle: Bundle) {
        SuiteRegistrationProbe.recordCall()
        self.sr_probe_loadSuites(from: bundle)
    }
}
#endif
