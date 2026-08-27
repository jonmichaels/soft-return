#if DEBUG
import Foundation

/// Job 181 Part 1 (-1708 investigation, continuing jobs 143-148/174/b7). The diagnostic tap
/// (`AppleEventDiagnosticTap`) proved the convert Apple event ARRIVES in-process, that a handler
/// IS registered for `('SRsu','conv')` (`priorHandlerPresent=1`), and that the handler still
/// returns -1708 — so the break sits INSIDE Cocoa Scripting's own dispatch, past the point every
/// prior probe could see. This records what `NSScriptSuiteRegistry` itself actually holds at
/// that same moment, so the failing link can be named instead of guessed at again: is our suite
/// there at all, is `convert` described within it, and does the class name the registry names
/// actually resolve to a live Swift type.
///
/// Called once, from `AppDelegate.applicationDidFinishLaunching`, strictly AFTER
/// `NSScriptSuiteRegistry.shared().loadSuites(from:)` runs in `applicationWillFinishLaunching`
/// (`AppDelegate.swift:44`) — same ordering rationale as `AppleEventDiagnosticTap.install()`
/// (`AppDelegate.swift:46-66`): probing before the forced load only proves "nothing is loaded
/// yet", which job 144 already established. `applicationDidFinishLaunching` runs strictly after
/// `applicationWillFinishLaunching` completes, so the ordering holds regardless of which of the
/// two methods does the calling.
///
/// Read-only Cocoa Scripting introspection (`suiteNames`, `commandDescriptions(inSuite:)`,
/// `NSClassFromString`) — none of it is documented to raise an `NSException` the way arbitrary
/// KVC key access can, so this follows `AppleEventDiagnosticTap`'s existing posture in this file
/// (check results, never crash by construction) rather than adding an Objective-C `@try`/`@catch`
/// shim: the app target is pure Swift today (no bridging header), and introducing one is a build-
/// system change out of proportion to a diagnostic read. `exception` is still part of the record
/// below as a forward-compatible field — every probing step is guarded so a missing suite, a
/// missing command, or an empty class name degrades to `false`/`nil` fields rather than a trap.
///
/// Job 219 (`SoftReturnDiagnostics`, finding B7): moved into the diagnostics module, `#if DEBUG`
/// (compiled out of Release entirely), and the `AppDelegate` call site now checks
/// `SRDiagnosticsGate.isEnabled()` first — the shipping app never runs this.
enum ScriptingRegistryProbe {
    static let defaultsKey = "scriptingRegistry.probe"

    /// Verified against `SoftReturn.sdef:297` (`<suite name="Soft Return Suite" code="SRsu">`),
    /// not assumed from the product/module name "SoftReturn" — the brief for this job is
    /// explicit that the two are not the same string.
    static let suiteName = "Soft Return Suite"
    static let commandName = "convert"

    struct State: Equatable {
        let recordedAt: Date
        let suiteNames: [String]
        let ourSuitePresent: Bool
        let convertCommandPresent: Bool
        let convertCommandClassName: String?
        let convertCommandClassResolves: Bool
        let moduleQualifiedClassResolves: Bool
        let bareClassResolves: Bool
        let exception: String?
    }

    static func run(registry: NSScriptSuiteRegistry = .shared(), defaults: UserDefaults = .standard) {
        let suiteNames = registry.suiteNames
        let ourSuitePresent = suiteNames.contains(suiteName)

        var convertCommandPresent = false
        var convertCommandClassName: String?
        var convertCommandClassResolves = false
        // The brief for this probe names `commandDescription(inSuite:withName:)`, but Foundation
        // has no such method on `NSScriptSuiteRegistry` — verified against the SDK by a failed
        // build, not assumed. `commandDescriptions(inSuite:)` (plural, a `[String:
        // NSScriptCommandDescription]`) is the real API for "what's in this suite by name", and
        // is already in use elsewhere in this file's own investigation (`AppleEventSelfTest.
        // registryDump()`); indexing it by `commandName` answers the identical question.
        if let description = registry.commandDescriptions(inSuite: suiteName)?[commandName] {
            convertCommandPresent = true
            let className = description.commandClassName
            convertCommandClassName = className
            convertCommandClassResolves = !className.isEmpty && NSClassFromString(className) != nil
        }

        let state = State(
            recordedAt: Date(),
            suiteNames: suiteNames,
            ourSuitePresent: ourSuitePresent,
            convertCommandPresent: convertCommandPresent,
            convertCommandClassName: convertCommandClassName,
            convertCommandClassResolves: convertCommandClassResolves,
            moduleQualifiedClassResolves: NSClassFromString("SoftReturn.ConvertCommand") != nil,
            bareClassResolves: NSClassFromString("ConvertCommand") != nil,
            exception: nil
        )
        write(state, defaults: defaults)
    }

    // MARK: - UserDefaults record (plain plist values — the SpotlightNudge pattern)

    private static func write(_ state: State, defaults: UserDefaults) {
        var dict: [String: Any] = [
            "recordedAt": state.recordedAt,
            "suiteNames": state.suiteNames,
            "ourSuitePresent": state.ourSuitePresent,
            "convertCommandPresent": state.convertCommandPresent,
            "convertCommandClassResolves": state.convertCommandClassResolves,
            "moduleQualifiedClassResolves": state.moduleQualifiedClassResolves,
            "bareClassResolves": state.bareClassResolves,
        ]
        if let name = state.convertCommandClassName { dict["convertCommandClassName"] = name }
        if let exception = state.exception { dict["exception"] = exception }
        defaults.set(dict, forKey: defaultsKey)
    }

    static func readState(defaults: UserDefaults = .standard) -> State? {
        guard let dict = defaults.dictionary(forKey: defaultsKey),
              let recordedAt = dict["recordedAt"] as? Date,
              let suiteNames = dict["suiteNames"] as? [String],
              let ourSuitePresent = dict["ourSuitePresent"] as? Bool,
              let convertCommandPresent = dict["convertCommandPresent"] as? Bool,
              let convertCommandClassResolves = dict["convertCommandClassResolves"] as? Bool,
              let moduleQualifiedClassResolves = dict["moduleQualifiedClassResolves"] as? Bool,
              let bareClassResolves = dict["bareClassResolves"] as? Bool
        else { return nil }
        return State(
            recordedAt: recordedAt,
            suiteNames: suiteNames,
            ourSuitePresent: ourSuitePresent,
            convertCommandPresent: convertCommandPresent,
            convertCommandClassName: dict["convertCommandClassName"] as? String,
            convertCommandClassResolves: convertCommandClassResolves,
            moduleQualifiedClassResolves: moduleQualifiedClassResolves,
            bareClassResolves: bareClassResolves,
            exception: dict["exception"] as? String
        )
    }
}
#endif
