import XCTest

/// `performAccessibilityAudit` on the document window.
///
/// It IS macOS-capable (macOS 14+, Xcode 16.3+); the "iOS-only" belief is folklore and was
/// checked. This runs it against a real open document.
///
/// FAILS ON FINDINGS (round 3 debt-clearing, was log-and-ignore under job-029's "report, do
/// not fix" rule). That rule made sense the first time this test ran: nobody had looked at
/// the six findings yet, and fixing them blind in the same pass that discovered them would
/// have shipped changes nobody evaluated. They have since been evaluated — see
/// `PagedDocumentView`'s and `BottomBar`'s accessibility setup, `DocumentWindowController`'s
/// `document-scroll-view` label, and `DocumentRenderer.renderNative`'s clipping note — and
/// `PagedDocumentViewAccessibilityTests` covers the same three defect classes headlessly, in
/// the target that actually runs on this console. This test's job now is to stay green
/// because those fixes hold, and to go red the moment something regresses one of them; a
/// test that can never fail is not a test, it is a log statement with extra steps. This test
/// still only runs where XCUITest can run at all (a real console — see the doc comment this
/// replaced); where it can't, it's absent from the run, same as before.
///
/// Batch 32 (b32-i1-ui3, the first time this ran since UI automation was authorised on this host): its four
/// findings were none of the app's. The kept element trees place them in AppKit's own window chrome:
/// - a group inside the title bar's full-screen button;
/// - the title bar's document icon, flagged twice (label not human-readable, potentially inaccessible text);
/// - AppKit's application-level Touch Bar element, on a Mac with no Touch Bar.
/// Those three exact shapes are printed and kept, and do not fail the test. Anything else still does.
final class AccessibilityAuditUITests: XCTestCase {

    @MainActor
    func testDocumentWindowAccessibilityAudit() throws {
        // Job 342 (b23 floor drop): `performAccessibilityAudit` really is macOS 14+ only —
        // this file's own header comment already established that, and there is no pre-14
        // form of it to fall back to. The app's floor is now 13.0, but this XCUITest is
        // supplementary coverage (see header comment: `PagedDocumentViewAccessibilityTests`
        // is the load-bearing, headless check for the same defect classes) — skipping it on
        // <14 loses nothing that isn't already covered elsewhere, so a skip is the honest
        // choice here, not a silent pass.
        guard #available(macOS 14, *) else {
            throw XCTSkip("performAccessibilityAudit requires macOS 14+")
        }

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoftReturnTests/Fixtures/report.ps")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path),
                      "fixture missing — the audit would run against an empty window")

        let app = XCUIApplication()
        app.launchArguments = ["-SoftReturnOpenDocument", fixture.path]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20),
                      "no document window to audit")
        Thread.sleep(forTimeInterval: 3)

        // AppKit's own chrome, by the shapes b32-i1-ui3 measured — not the app's controls.
        let window = app.windows.firstMatch
        let windowTitle = window.title
        let titleBar = CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: 28)
        let fullScreenButton = window.buttons["_XCUI:FullScreenWindow"]
        let fullScreenFrame = fullScreenButton.exists ? fullScreenButton.frame : CGRect.null
        func appKitChrome(_ element: XCUIElement) -> String? {
            switch element.elementType {
            case .touchBar:
                return "AppKit's application Touch Bar element"
            case .image where element.title == windowTitle && titleBar.contains(element.frame):
                return "the title bar's document icon"
            case .group where !fullScreenFrame.isNull && fullScreenFrame.contains(element.frame):
                return "a group inside the title bar's full-screen button"
            default:
                return nil
            }
        }

        var findings: [String] = []
        var systemChrome: [String] = []
        var flagged: [(number: Int, element: XCUIElement)] = []
        var issueNumber = 0
        do {
            try app.performAccessibilityAudit { issue in
                // THE ELEMENT, not just the type. The audit names a finding type and a
                // category; without the element that raised it, "which control is at fault"
                // is a guess — and two of the four findings on this window share
                // `rawValue: 8`, so a type alone cannot even tell you how many controls are
                // involved. `XCUIAccessibilityAuditIssue` carries `element`; printing it
                // turns the question into a measurement (register, 2026-09-07: print more
                // data before reading more code).
                let element = issue.element
                // `+=` statements, not one chained `+`: with a fifth term the chain was more than the
                // type-checker would take (b32-i1-ui2 did not build) — the repo's #253 rule, here too.
                var described = "element=<nil>"
                if let candidate = element {
                    described = "elementType=\(candidate.elementType.rawValue)"
                    described += " id=\(candidate.identifier.isEmpty ? "<none>" : candidate.identifier)"
                    described += " label=\(candidate.label.isEmpty ? "<none>" : candidate.label.debugDescription)"
                    described += " hittable=\(candidate.isHittable)"
                    described += " frame=\(candidate.frame)"
                }
                issueNumber += 1
                if let element { flagged.append((issueNumber, element)) }
                let line = "[\(issue.auditType)] \(issue.compactDescription) — \(described)"
                if let element, let chrome = appKitChrome(element) {
                    systemChrome.append("\(line) — \(chrome)")
                } else {
                    findings.append(line)
                }
                // "Handled" as far as XCTest's own per-issue failure goes — this test raises
                // ONE clear failure below instead, with every finding in its message, rather
                // than a separate opaque XCTIssue per finding.
                return true
            }
        } catch {
            XCTFail("the accessibility audit could not run: \(error)")
            return
        }

        if findings.isEmpty {
            print("SR-A11Y: no issues reported")
        } else {
            print("SR-A11Y: \(findings.count) issue(s)")
            for f in findings { print("SR-A11Y   \(f)") }
        }
        for chrome in systemChrome { print("SR-A11Y AppKit chrome, not failing: \(chrome)") }

        // Batch 32: a finding's type and a missing label do not say WHICH control it is (b32-i1-ui's four
        // findings named no identifier and no label at all). Keep the evidence in the result bundle, where it
        // can be read after the run: the window, and for each flagged element its accessibility subtree and,
        // where it is on screen, a picture of it. A Touch Bar element has no place on the display to capture.
        keep(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()), named: "SR-A11Y window")
        for (number, element) in flagged {
            keep(XCTAttachment(string: String(element.debugDescription.prefix(6000))),
                 named: "SR-A11Y finding \(number) element")
            if element.exists, element.isHittable, !element.frame.isEmpty, element.elementType != .touchBar {
                keep(XCTAttachment(screenshot: element.screenshot()), named: "SR-A11Y finding \(number)")
            }
        }
        XCTAssertTrue(findings.isEmpty,
                      "\(findings.count) accessibility finding(s):\n" + findings.joined(separator: "\n"))
    }

    private func keep(_ attachment: XCTAttachment, named name: String) {
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
