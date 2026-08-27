import XCTest

/// THE TEST THAT WOULD HAVE CAUGHT THE BLANK WINDOW.
///
/// Every unit test in this project passed for three sessions while the document window showed
/// nothing at all. They asserted the view tree was healthy — frames set, subviews present,
/// glyphs laid out — and every one of those assertions was TRUE. The page really was drawing;
/// the bottom bar was painting over it afterwards. Nothing in-process could see that.
///
/// This one launches the actual app and asks the accessibility layer whether the document's
/// text is ON SCREEN. It is the only test here that answers the question a reader would ask.
///
/// It is also the only kind that could have caught the print entitlement: building an
/// NSPrintOperation succeeds with or without `com.apple.security.print`, and only a launched
/// app discovers the print system refusing the job.
final class DocumentVisibleUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launch, open a fixture, and assert its text is visible.
    ///
    /// The fixture path is handed to the app as a launch argument rather than driven through
    /// an open panel: the panel is AppKit's, this test is about the DOCUMENT being visible,
    /// and driving a file chooser would make the test fail for reasons that have nothing to
    /// do with what it is named for.
    @MainActor
    func testAnOpenedDocumentIsActuallyVisible() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // SoftReturnUITests
            .deletingLastPathComponent()          // macos (job 531: SoftReturnTests moved here
                                                   // too, still a 2-delete sibling reach)
            .appendingPathComponent("SoftReturnTests/Fixtures/report.ps")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path),
                      "fixture missing at \(fixture.path) — this test would pass vacuously")

        let app = XCUIApplication()
        app.launchArguments = ["-SoftReturnOpenDocument", fixture.path]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20),
                      "no document window appeared")

        // LOOK AT THE PIXELS.
        //
        // The first version of this test asked the accessibility tree whether the document's
        // text existed, and it PASSED with the blank window deliberately reintroduced —
        // because the text does exist. An NSTextView holds its string whether or not another
        // view paints over it. That is the exact mistake every earlier test in this project
        // made: asserting the model and calling it the screen.
        //
        // So this screenshots the window and counts dark pixels in the page area. A page of
        // 1980s typescript has thousands; a covered page has none. Nothing short of reading
        // the rendered image can tell those apart.
        let shot = window.screenshot()
        guard let image = NSBitmapImageRep(data: shot.pngRepresentation) else {
            return XCTFail("could not read the window screenshot")
        }
        let w = image.pixelsWide, h = image.pixelsHigh
        XCTAssertGreaterThan(w, 100); XCTAssertGreaterThan(h, 100)

        // Skip the title bar and the bottom bar — this is about the PAGE.
        let topInset = Int(Double(h) * 0.08), bottomInset = Int(Double(h) * 0.94)
        var ink = 0, sampled = 0
        for y in stride(from: topInset, to: bottomInset, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                guard let c = image.colorAt(x: x, y: y) else { continue }
                sampled += 1
                let b = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if b < 0.5 { ink += 1 }
            }
        }
        let inkFraction = Double(ink) / Double(max(1, sampled))
        // A full page of Courier runs a few percent ink. Anything at or near zero means the
        // page is not on screen, whatever the view hierarchy says about it.
        XCTAssertGreaterThan(inkFraction, 0.005,
            String(format: "the page area is blank — %.4f%% ink over %d sampled pixels. The document's text may exist in the view tree and still not be on screen.",
                   inkFraction * 100, sampled))
    }
}
