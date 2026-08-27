import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 143 (-1708, "doesn't understand the convert message"). Job 137 verified the STATIC
/// wiring — the sdef parses, the `<cocoa class="...">` names match real Swift types, the
/// argument decoders round-trip. None of that proves a real Apple Event ever reaches
/// `ConvertCommand.performDefaultImplementation()` at runtime: every other scripting test in
/// this target calls `.decode(...)`/`.convert(...)` directly as pure functions, sidestepping
/// Cocoa Scripting's own dispatch path entirely (see the doc comments on
/// `ExportCommandTests.decodedArgumentsRouteThroughDocumentOperationsToARealRTFFile` and
/// `DiagnoseAndImportPageSettingsCommandTests`).
///
/// `-1708` is `errAEEventNotHandled` — the Apple Event Manager's own "nothing in the dispatch
/// table matched this (event class, event ID) pair" error, which is exactly the string
/// AppleScript surfaces as "doesn't understand the X message". Sending a live Apple Event
/// from this session is blocked by TCC (no Automation permission for a headless test run), so
/// this file builds the in-process equivalent: `SoftReturnTests` is HOST-APP-hosted (its
/// `TEST_HOST` build setting points at `Soft Return.app` — see `project.pbxproj`), so
/// `Bundle.main` here IS the real app bundle with the real `OSAScriptingDefinition`, and
/// `NSAppleEventManager.dispatchRawAppleEvent(_:withRawReply:handlerRefCon:)` runs an event
/// through Cocoa's real dispatch table without going anywhere near `AESend`/Mach IPC/TCC.
@Suite struct AppleEventDispatchTests {

    // MARK: - What's actually in the registry

    /// First assertion the job asked for: dump what `NSScriptSuiteRegistry` actually contains
    /// after forcing a load from `Bundle.main`, rather than assume the sdef made it in.
    @Test func suiteRegistryContainsOurSuiteAndConvertCommand() throws {
        UserDefaults.standard.set(2, forKey: "NSScriptingDebugLogLevel")
        defer { UserDefaults.standard.removeObject(forKey: "NSScriptingDebugLogLevel") }

        let registry = NSScriptSuiteRegistry.shared()
        registry.loadSuites(from: Bundle.main)

        let suiteNames = registry.suiteNames
        print("AppleEventDispatchTests: Bundle.main = \(Bundle.main.bundleURL.path)")
        print("AppleEventDispatchTests: OSAScriptingDefinition = \(String(describing: Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition")))")
        print("AppleEventDispatchTests: registered suite names = \(suiteNames)")

        let suiCode = ScriptingCodes.fourCharCode("SRsu")
        let convertDescription = registry.commandDescription(
            withAppleEventClass: suiCode, andAppleEventCode: ScriptingCodes.fourCharCode("conv"))
        let exportDescription = registry.commandDescription(
            withAppleEventClass: suiCode, andAppleEventCode: ScriptingCodes.fourCharCode("expo"))
        print("AppleEventDispatchTests: convert command description = \(String(describing: convertDescription)) class=\(convertDescription?.commandClassName ?? "nil")")
        print("AppleEventDispatchTests: export command description = \(String(describing: exportDescription)) class=\(exportDescription?.commandClassName ?? "nil")")

        if let commands = registry.commandDescriptions(inSuite: "Soft Return Suite") {
            print("AppleEventDispatchTests: commands in \"Soft Return Suite\" = \(commands.keys.sorted())")
        } else {
            print("AppleEventDispatchTests: \"Soft Return Suite\" is ABSENT from the registry")
        }

        #expect(suiteNames.contains("Soft Return Suite"))
        let convert = try #require(convertDescription)
        #expect(convert.commandClassName == "SoftReturn.ConvertCommand")
    }

    // MARK: - A real, in-process dispatch of the convert Apple event

    /// Builds the exact Apple Event `osascript` would send for
    /// `tell application "Soft Return" to convert {POSIX file "..."} as {RTF}`, then runs it
    /// through Cocoa Scripting's real dispatch table in-process. If dispatch fails, the
    /// failure itself — not a workaround — is the finding.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func inProcessConvertAppleEventProducesAnRTFFile() throws {
        _ = NSScriptSuiteRegistry.shared() // force sdef load before dispatch, same as the app would have by launch time

        let source = MultipageMargins.testDocsDirectory.appendingPathComponent("ws4/INDIAN.ws")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleEventDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

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

        let replyDescriptor = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        let errorNumber = replyDescriptor.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value
        let errorString = replyDescriptor.paramDescriptor(forKeyword: keyErrorString)?.stringValue
        print("AppleEventDispatchTests: dispatchRawAppleEvent OSStatus=\(status) replyErrorNumber=\(String(describing: errorNumber)) replyErrorString=\(String(describing: errorString))")

        #expect(status == noErr, "dispatchRawAppleEvent returned OSStatus \(status) (errAEEventNotHandled == -1708)")
        #expect(errorNumber == nil, "reply carried scriptErrorNumber \(String(describing: errorNumber)): \(String(describing: errorString))")

        let outputs = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let rtf = outputs.first { $0.pathExtension == "rtf" }
        let unwrapped = try #require(rtf, "no .rtf landed in \(tempDir.path); contents: \(outputs)")
        let data = try Data(contentsOf: unwrapped)
        #expect(data.prefix(6) == Data(#"{\rtf1"#.utf8))
    }
}
