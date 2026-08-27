import CoreServices
import Foundation
import Testing
@testable import SoftReturn

/// Job 144, experiment A. `AppleEventDispatchTests.inProcessConvertAppleEventProducesAnRTFFile`
/// forces `NSScriptSuiteRegistry.shared()` to load *before* dispatching, which matches a
/// long-running app (the registry is loaded once at launch and stays warm for every event after
/// that) but does NOT match the very first Apple Event a freshly-launched process ever receives,
/// which is the case that matters for a script that fires the instant the app finishes
/// launching. If Cocoa Scripting lazily loads the registry lazily on first dispatch and that
/// lazy load has some ordering bug (e.g. it isn't synchronous, or dispatch runs before
/// `applicationDidFinishLaunching` wires something up), the eager-load call in the other test
/// would mask it.
///
/// This file is a SEPARATE suite so it can be run alone via `-only-testing`, in an
/// otherwise-fresh test invocation, guaranteeing no other scripting test has already touched
/// `NSScriptSuiteRegistry` first.
/// Job 535: this suite's one test reads `MultipageMargins.testDocsDirectory` (`ws4/INDIAN.ws`)
/// — gated at the suite level so a bare stranger run skips cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct AppleEventVirginDispatchTests {

    /// Same event construction as `AppleEventDispatchTests`, but with NO prior call to
    /// `NSScriptSuiteRegistry.shared()` anywhere in this suite. Run in isolation:
    /// `xcodebuild test -only-testing:SoftReturnTests/AppleEventVirginDispatchTests`.
    @Test @MainActor func virginProcessConvertAppleEventProducesAnRTFFile() throws {
        let source = MultipageMargins.testDocsDirectory.appendingPathComponent("ws4/INDIAN.ws")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleEventVirginDispatchTests-\(UUID().uuidString)")
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
        print("AppleEventVirginDispatchTests: dispatchRawAppleEvent OSStatus=\(status) replyErrorNumber=\(String(describing: errorNumber)) replyErrorString=\(String(describing: errorString))")

        #expect(status == noErr, "dispatchRawAppleEvent returned OSStatus \(status) (errAEEventNotHandled == -1708)")
        #expect(errorNumber == nil, "reply carried scriptErrorNumber \(String(describing: errorNumber)): \(String(describing: errorString))")

        let outputs = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let rtf = outputs.first { $0.pathExtension == "rtf" }
        let unwrapped = try #require(rtf, "no .rtf landed in \(tempDir.path); contents: \(outputs)")
        let data = try Data(contentsOf: unwrapped)
        #expect(data.prefix(6) == Data(#"{\rtf1"#.utf8))
    }
}
