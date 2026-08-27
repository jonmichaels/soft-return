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
/// `document-scroll-view` label, and `DocumentRenderer.renderPrinted`'s clipping note — and
/// `PagedDocumentViewAccessibilityTests` covers the same three defect classes headlessly, in
/// the target that actually runs on this console. This test's job now is to stay green
/// because those fixes hold, and to go red the moment something regresses one of them; a
/// test that can never fail is not a test, it is a log statement with extra steps. This test
/// still only runs where XCUITest can run at all (a real console — see the doc comment this
/// replaced); where it can't, it's absent from the run, same as before.
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

        var findings: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                findings.append("[\(issue.auditType)] \(issue.compactDescription)")
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
        XCTAssertTrue(findings.isEmpty,
                      "\(findings.count) accessibility finding(s):\n" + findings.joined(separator: "\n"))
    }
}
