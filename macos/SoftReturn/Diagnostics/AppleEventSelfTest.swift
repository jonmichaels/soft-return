#if DEBUG
import CoreServices
import Foundation

/// Job 144, experiment B. `AppleEventVirginDispatchTests` (SoftReturnTests) proved that a
/// virgin-process dispatch of `NSAppleEventManager.dispatchRawAppleEvent` fails with -1708
/// unless something has already forced `NSScriptSuiteRegistry.shared()` to load first — but
/// that test runs in-process, unsandboxed, inside a test host. This is the same experiment run
/// for real: inside the actual sandboxed Release app binary, using the real `AESendMessage`
/// (not the registry-adjacent-but-synthetic `dispatchRawAppleEvent`), self-addressed at
/// `{ typeProcessSerialNumber, kCurrentProcess }`. Per `AEMach.h`'s doc comment on
/// `AESendMessage`, a self-addressed event "is dispatched directly to the appropriate event
/// handler in your process and not serialized" — which is also why it needs no
/// Automation/TCC permission the way a real cross-app `osascript` send does — but it still goes
/// through the OS's real Apple Event Manager and the app's real (lazy, sandboxed)
/// `NSScriptSuiteRegistry` load, which `dispatchRawAppleEvent` bypasses entirely.
///
/// Writes its one-line verdict to `UserDefaults` key `aeSelfTest.result` so it can be read back
/// with `defaults read me.beforeti.softreturn aeSelfTest.result` after the app quits, without a
/// debugger attached.
///
/// Job 219 (`SoftReturnDiagnostics`, finding B9): moved into the diagnostics module, `#if DEBUG`
/// (compiled out of Release entirely, so "inside the actual sandboxed Release app binary" above
/// is now historical — the value of running inside a real, non-Debug-only build is why this
/// stays in the module rather than the test target, unlike `SpotlightBackfillSelfTest`; a Debug
/// build is still the real sandboxed app, just not the customer-facing Release one). The old
/// dedicated `SR_AE_SELFTEST` environment flag is gone — this now checks the one module-wide
/// `SRDiagnosticsGate` instead, per Jon's ruling against per-tool flags.
enum AppleEventSelfTest {
    static let resultDefaultsKey = "aeSelfTest.result"

    /// The fixture this test converts. Provisioned externally, at
    /// `<sandbox container>/Data/tmp/AESelfTestFixture/INDIAN.ws`, before the app is launched:
    /// the sandboxed app can read its OWN container freely, but `SoftReturn.entitlements`
    /// grants no access to an arbitrary path outside it, so the fixture cannot be read from the
    /// source tree the way the unit tests (hosted, unsandboxed, inside the test runner) do.
    private static var fixtureURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfTestFixture", isDirectory: true)
            .appendingPathComponent("INDIAN.ws")
    }

    /// Job 144 debug aid: `UserDefaults`/`cfprefsd` proved unreliable to read back from outside
    /// the sandbox in this environment (a KNOWN pre-existing key round-tripped as "does not
    /// exist" via `defaults read` even though it was present on disk), so the result is ALSO
    /// dropped as a plain file in the container's own tmp dir, which needs no daemon to read.
    private static var debugMarkerURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aeSelfTest.result.txt")
    }

    static func runIfRequested() {
        guard SRDiagnosticsGate.isEnabled() else { return }
        record("started")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let result = "\(registryDump()) | \(perform())"
            NSLog("[SoftReturn] aeSelfTest.result = %@", result)
            record(result)
        }
    }

    /// Job 147: does `NSScriptSuiteRegistry` actually have "Soft Return Suite" registered by
    /// the time the self-test fires — command descriptions present, not just the suite name —
    /// independent of whether the self-addressed `AESendMessage` below gets handled. Job 144's
    /// eager `loadSuites(from:)` call in `applicationWillFinishLaunching` runs before this, so
    /// this is a post-eager-load snapshot; the point is proving whether the OLD xi:include sdef
    /// (job 147's hypothesis: the runtime loader chokes on it, unlike `sdp`/`osacompile`, and
    /// silently drops registration for the WHOLE file, not just the included fragment) actually
    /// prevented "Soft Return Suite" itself from registering, or whether it registered fine and
    /// the -1708 lives somewhere else in Apple Event delivery entirely.
    @MainActor
    private static func registryDump() -> String {
        let registry = NSScriptSuiteRegistry.shared()
        let suiteNames = registry.suiteNames.sorted()
        let softReturnCommands = (registry.commandDescriptions(inSuite: "Soft Return Suite")?.keys)
            .map { $0.sorted() } ?? []
        return "registry: suites=\(suiteNames) softReturnSuitePresent=\(suiteNames.contains("Soft Return Suite")) softReturnCommands=\(softReturnCommands)"
    }

    private static func record(_ result: String) {
        UserDefaults.standard.set(result, forKey: resultDefaultsKey)
        try? result.write(to: debugMarkerURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func perform() -> String {
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return "unhandled: fixture missing at \(fixtureURL.path)"
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AESelfTestOutput-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return "unhandled: could not create output dir: \(error)"
        }

        let event = NSAppleEventDescriptor(
            eventClass: ScriptingCodes.fourCharCode("SRsu"),
            eventID: ScriptingCodes.fourCharCode("conv"),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
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

        guard let eventDesc = event.aeDesc else {
            return "unhandled: could not build AEDesc"
        }
        var reply = AEDesc()
        AECreateDesc(typeNull, nil, 0, &reply)
        defer { AEDisposeDesc(&reply) }

        let status = AESendMessage(eventDesc, &reply, AESendMode(kAEWaitReply), Int(kAEDefaultTimeout))

        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let errorString = replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue

        if status != noErr {
            return "unhandled: AESendMessage OSStatus=\(status) errorNumber=\(String(describing: errorNumber)) errorString=\(String(describing: errorString))"
        }
        if let errorNumber, errorNumber != 0 {
            return "handled-with-error: errorNumber=\(errorNumber) errorString=\(String(describing: errorString))"
        }

        let outputs = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        if let rtf = outputs.first(where: { $0.pathExtension == "rtf" }),
           let data = try? Data(contentsOf: rtf), data.prefix(6) == Data(#"{\rtf1"#.utf8) {
            return "handled: rtf written at \(rtf.path)"
        }
        return "handled-no-rtf: status=\(status) outputs=\(outputs.map(\.lastPathComponent))"
    }
}
#endif
