#if DEBUG
import CoreServices
import Foundation

/// Job 174 (b7 Phase 2, `ae-diagnostic-tap`): a raw `AEInstallEventHandler` tap on this
/// suite's own `convert` event — `'SRsu'`/`'conv'`, verbatim from `SoftReturn.sdef:500`'s
/// `code="SRsuconv"`.
///
/// Jobs 143-148 exhausted every theory that lives ABOVE Cocoa Scripting (xi:include sdef
/// parsing, `NSScriptSuiteRegistry`'s lazy load, eager preload, `NSApplicationMain` bootstrap
/// ordering) and all four converged on identical -1708 with a perfect registry dump — see
/// `.claude/skills/macos-document-app/references/field-notes.md`'s 2026-08-09 "-1708
/// probe-class exhaustion" entry: "convergence means stop varying the app and test
/// cross-process from a real console, or instrument `AEInstallEventHandler` directly." This is
/// that instrumentation: it answers, on the field machine, whether the event arrives in-process
/// at all, and whether Cocoa has a handler registered for it when it does — which alone
/// distinguishes "Cocoa never installed a handler for this command" from "installed but the
/// event never reaches it."
///
/// Job 219 (`SoftReturnDiagnostics`, finding B6): this tap sat unconditionally in the AE
/// delivery path of every RELEASE build since b7 — the opposite of what a shipping app should
/// do (Jon's ruling: "the shipping app must run APPLE'S native paths"). It is now `#if DEBUG`
/// (compiled out of Release entirely — verified by a `strings` check on the Release binary for
/// this type's name) AND only installed when the caller checks `SRDiagnosticsGate.isEnabled()`
/// first (see `AppDelegate.applicationWillFinishLaunching`) — `install()` itself no longer
/// self-gates, so tests can still call it directly regardless of the gate (`AppleEventDiagnosticTapSelfSendTests`).
///
/// Passive by design even when active: it only records and forwards the reply a prior handler
/// (or `errAEEventNotHandled`, unchanged) would have produced anyway, so activating it carries
/// none of the risk a real behavior change would.
///
/// See `AppDelegate.applicationWillFinishLaunching` for why `install()` is called where it is —
/// the ordering is load-bearing, not incidental.
enum AppleEventDiagnosticTap {
    static let eventClass: AEEventClass = ScriptingCodes.fourCharCode("SRsu")
    static let eventID: AEEventID = ScriptingCodes.fourCharCode("conv")

    static let defaultsKey = "aeDiagnostics.tap"
    private static let arrivalsCap = 20
    private static let lock = NSLock()

    /// The handler (if any) already installed for `(eventClass, eventID)` when `install` ran,
    /// saved so the tap can forward to it faithfully instead of swallowing the event. Read only
    /// by `tapHandler` below, which cannot capture anything (it is a bare C function pointer),
    /// so this — and `priorRefcon`, and `defaults` — are the static seam that closure routes
    /// through instead.
    fileprivate nonisolated(unsafe) static var priorHandler: AEEventHandlerUPP?
    fileprivate nonisolated(unsafe) static var priorRefcon: UnsafeMutableRawPointer?
    fileprivate nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Job 198: guards against re-entrant `install()` calls in the SAME process. Job 185 traced
    /// a latent crash (documented in `ConvertCommandReceiverDispatchTests.swift`'s trailing
    /// comment) to exactly this: a second `install()` call (e.g.
    /// `AppleEventDiagnosticTapSelfSendTests`, which runs alongside `AppDelegate`'s own launch-time
    /// call in the same hosted-test process) probes `AEGetEventHandler` again, which by then
    /// returns THIS type's own `tapHandler` (installed by the first call) — so it captures
    /// `priorHandler = tapHandler`, a self-reference. The next real invocation of the installed
    /// handler recurses through `prior(...)` forever. Job 198 needs to safely invoke the installed
    /// handler directly (`AEGetEventHandler` + a bare call, replaying a real captured event) as a
    /// PERMANENT regression fixture that must survive the full suite, so this can no longer be
    /// left latent — only the FIRST call in a process may touch Carbon AE Manager state; later
    /// calls still record an install-time defaults entry (existing callers assert on it) but never
    /// re-probe or re-install.
    fileprivate nonisolated(unsafe) static var didInstall = false

    /// Job 239b (`ae-layer-probe`): per-invocation layer-table data, in-memory only (unlike
    /// `arrivals`/`lastForwardResult` above, which persist to `UserDefaults` for cross-process
    /// field reads). This exists to be read back within the SAME process, right after a self-send
    /// returns (see `AppleEventSelfSendProbe`), same as `AppleEventDispatchSwizzle.recordedCalls()`
    /// — the layer directly above this one. `monotonic` uses `ProcessInfo.processInfo.systemUptime`,
    /// the same clock every other timeline instrument in this investigation (jobs 236-238) already
    /// standardized on, so a report can merge both layers into one ordered table without comparing
    /// wall-clock `Date`s recorded on different threads.
    struct Call: Equatable {
        let monotonic: Double
        let originalReturn: Int32
    }
    fileprivate nonisolated(unsafe) static var calls: [Call] = []
    private static let callsLock = NSLock()

    fileprivate static func recordCall(_ call: Call) {
        callsLock.lock()
        defer { callsLock.unlock() }
        calls.append(call)
    }

    static func recordedCalls() -> [Call] {
        callsLock.lock()
        defer { callsLock.unlock() }
        return calls
    }

    /// Test-only reset, same rationale as `SuiteRegistrationProbe.resetLog()`.
    static func resetCallLog() {
        callsLock.lock()
        defer { callsLock.unlock() }
        calls.removeAll()
    }

    /// Call once, from `AppDelegate.applicationWillFinishLaunching`, AFTER
    /// `NSScriptSuiteRegistry.shared().loadSuites(from:)` — see that file for the ordering
    /// rationale. Carbon AE APIs are available to sandboxed apps per Apple's docs, but if
    /// either call below is denied at runtime under sandbox, that denial is itself recorded
    /// (`installError`) rather than crashing or silently no-opping.
    ///
    /// Job 219: no longer self-gated — the caller decides (`SRDiagnosticsGate.isEnabled()`)
    /// whether to call this at all. Kept unconditional here so tests can install the tap
    /// directly without needing to flip the gate first (test-target linkage).
    static func install(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        guard !didInstall else {
            recordInstall(priorHandlerPresent: priorHandler != nil, defaults: defaults)
            return
        }
        didInstall = true

        var existingHandler: AEEventHandlerUPP?
        var existingRefcon: UnsafeMutableRawPointer?
        let getStatus = AEGetEventHandler(eventClass, eventID, &existingHandler, &existingRefcon, false)
        let priorPresent = getStatus == noErr && existingHandler != nil
        if priorPresent {
            priorHandler = existingHandler
            priorRefcon = existingRefcon
        }

        let installStatus = AEInstallEventHandler(eventClass, eventID, tapHandler, nil, false)
        recordInstall(priorHandlerPresent: priorPresent,
                      installError: installStatus == noErr ? nil : Int(installStatus),
                      defaults: defaults)
    }

    // MARK: - Recording (internal, not fileprivate, so tests can drive it with an injected suite)

    static func recordInstall(priorHandlerPresent: Bool, installError: Int? = nil, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        var state = readRaw(defaults: defaults)
        state["installedAt"] = Date()
        state["priorHandlerPresent"] = priorHandlerPresent
        state["arrivals"] = state["arrivals"] as? [Date] ?? []
        state["lastForwardResult"] = state["lastForwardResult"] as? Int ?? 0
        if let installError {
            state["installError"] = installError
        }
        defaults.set(state, forKey: defaultsKey)
    }

    static func recordArrival(defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        var state = readRaw(defaults: defaults)
        var arrivals = state["arrivals"] as? [Date] ?? []
        arrivals.append(Date())
        if arrivals.count > arrivalsCap {
            arrivals.removeFirst(arrivals.count - arrivalsCap)
        }
        state["arrivals"] = arrivals
        defaults.set(state, forKey: defaultsKey)
    }

    static func recordForwardResult(_ result: Int, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        var state = readRaw(defaults: defaults)
        state["lastForwardResult"] = result
        defaults.set(state, forKey: defaultsKey)
    }

    /// Job 188: the incoming event's own content, captured verbatim (before forwarding) so a
    /// field-machine `defaults read` can be diffed against a hand-built harness replay — see this
    /// file's header doc and the job 188 report for why the descriptor CONTENT, not just arrival
    /// counts, was the only unexamined variable left after jobs 143-185.
    static func recordEventCapture(description: String, flattenedBase64: String, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        var state = readRaw(defaults: defaults)
        state["lastEventDescription"] = description
        state["lastEventFlattened"] = flattenedBase64
        defaults.set(state, forKey: defaultsKey)
    }

    /// The reply descriptor's state after `prior(...)` has run — recorded separately from
    /// `recordEventCapture` because it is only meaningful once forwarding has actually populated it.
    static func recordReplyCapture(description: String, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        var state = readRaw(defaults: defaults)
        state["lastReplyDescription"] = description
        defaults.set(state, forKey: defaultsKey)
    }

    private static func readRaw(defaults: UserDefaults) -> [String: Any] {
        defaults.dictionary(forKey: defaultsKey) ?? [:]
    }

    // MARK: - Read-back (tests + report tooling; the field round trip is `defaults read` directly)

    struct State: Equatable {
        let installedAt: Date?
        let priorHandlerPresent: Bool
        let arrivals: [Date]
        let lastForwardResult: Int
        let installError: Int?
        let lastEventDescription: String?
        let lastEventFlattened: String?
        let lastReplyDescription: String?
    }

    static func readState(defaults: UserDefaults = .standard) -> State {
        let raw = readRaw(defaults: defaults)
        return State(
            installedAt: raw["installedAt"] as? Date,
            priorHandlerPresent: raw["priorHandlerPresent"] as? Bool ?? false,
            arrivals: raw["arrivals"] as? [Date] ?? [],
            lastForwardResult: raw["lastForwardResult"] as? Int ?? 0,
            installError: raw["installError"] as? Int,
            lastEventDescription: raw["lastEventDescription"] as? String,
            lastEventFlattened: raw["lastEventFlattened"] as? String,
            lastReplyDescription: raw["lastReplyDescription"] as? String)
    }

    // MARK: - Descriptor serialization (job 188; internal not fileprivate/private, both so
    // `tapHandler` below — a bare C function pointer at file scope, not a member of this enum,
    // see that value's own doc comment on why — can reach these, AND so tests can drive them
    // directly against a hand-built descriptor without going through a real `AEInstallEventHandler`
    // dispatch, which would risk job 185's documented self-reinstall recursion (see
    // `ConvertCommandReceiverDispatchTests.swift`).
    //
    // Both take an `UnsafePointer<AEDesc>?` and NEVER mutate or dispose the pointee: `AEDuplicateDesc`
    // and `AEFlattenDesc` only ever READ from `theAEDesc`, so calling either on the live `event`/`reply`
    // Carbon hands the handler cannot alter what gets forwarded — required by this job's "forwarding
    // behavior must remain byte-identical" constraint. Every failure path (nil pointer, non-noErr
    // status) returns a descriptive placeholder string instead of throwing/crashing, per the same
    // "failure-proof" constraint.

    static let maxCapturedBytes = 16 * 1024

    static func safeDescription(of desc: UnsafePointer<AEDesc>?) -> String {
        guard let desc else { return "<nil descriptor>" }
        var duplicate = AEDesc()
        let status = AEDuplicateDesc(desc, &duplicate)
        guard status == noErr else {
            return "<AEDuplicateDesc failed: OSStatus \(status)>"
        }
        // NSAppleEventDescriptor(aeDescNoCopy:) takes ownership of `duplicate` and disposes it at
        // deinit — nothing else here may touch or dispose `duplicate` again.
        let wrapped = NSAppleEventDescriptor(aeDescNoCopy: &duplicate)
        return capped(wrapped.description)
    }

    static func safeFlattenedBase64(of desc: UnsafePointer<AEDesc>?) -> String {
        guard let desc else { return "" }
        // `actualSize`'s type is inferred from `AESizeOfFlattenedDesc`'s return rather than
        // spelled out (as `Size`) — that Carbon typedef name isn't visible in this module's
        // imported scope on this SDK, even though the functions that use it underneath are.
        let actualSize = AESizeOfFlattenedDesc(desc)
        guard actualSize > 0 else {
            return "<AESizeOfFlattenedDesc returned 0>"
        }
        var buffer = [UInt8](repeating: 0, count: Int(actualSize))
        var writtenSize = actualSize
        let flattenStatus = buffer.withUnsafeMutableBytes { rawBuffer in
            AEFlattenDesc(desc, rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), actualSize, &writtenSize)
        }
        guard flattenStatus == noErr else {
            return "<AEFlattenDesc failed: OSStatus \(flattenStatus)>"
        }
        let bytes = buffer.prefix(min(Int(writtenSize), maxCapturedBytes))
        return Data(bytes).base64EncodedString()
    }

    private static func capped(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxCapturedBytes else { return text }
        return String(decoding: utf8.prefix(maxCapturedBytes), as: UTF8.self) + "…<truncated>"
    }
}

/// No captures — Carbon invokes this as a bare C function pointer, so every fact it needs
/// (the prior handler, its refcon, which `UserDefaults` to write to) comes from
/// `AppleEventDiagnosticTap`'s static state rather than a closure capture.
///
/// Forwards faithfully: a prior handler's return value is passed straight back, and its
/// absence reproduces the exact unhandled result (`errAEEventNotHandled`, -1708) this app
/// already returns today, so installing this tap changes nothing about observed behavior.
private let tapHandler: AEEventHandlerUPP = { event, reply, refcon in
    let defaults = AppleEventDiagnosticTap.defaults
    AppleEventDiagnosticTap.recordArrival(defaults: defaults)
    AppleEventDiagnosticTap.recordEventCapture(
        description: AppleEventDiagnosticTap.safeDescription(of: event),
        flattenedBase64: AppleEventDiagnosticTap.safeFlattenedBase64(of: event),
        defaults: defaults)

    guard let prior = AppleEventDiagnosticTap.priorHandler else {
        let result = OSErr(errAEEventNotHandled)
        AppleEventDiagnosticTap.recordForwardResult(Int(result), defaults: defaults)
        AppleEventDiagnosticTap.recordReplyCapture(
            description: AppleEventDiagnosticTap.safeDescription(of: reply), defaults: defaults)
        AppleEventDiagnosticTap.recordCall(AppleEventDiagnosticTap.Call(
            monotonic: ProcessInfo.processInfo.systemUptime, originalReturn: Int32(result)))
        return result
    }
    let result = prior(event, reply, AppleEventDiagnosticTap.priorRefcon)
    AppleEventDiagnosticTap.recordForwardResult(Int(result), defaults: defaults)
    AppleEventDiagnosticTap.recordReplyCapture(
        description: AppleEventDiagnosticTap.safeDescription(of: reply), defaults: defaults)
    AppleEventDiagnosticTap.recordCall(AppleEventDiagnosticTap.Call(
        monotonic: ProcessInfo.processInfo.systemUptime, originalReturn: Int32(result)))
    return result
}
#endif
