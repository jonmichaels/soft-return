import XCTest

/// Batch 32 item 2 (Jon, via Athena): the live accessibility pass on the Mac, driven through XCUITest. It covers the
/// document window, its bottom bar, Settings and the Export As panel's accessory. On each, every control VoiceOver can
/// land on is read from one accessibility snapshot, in accessibility order, and checked:
/// - it has a spoken name: its label, or its title (a checkbox's or a button's text);
/// - it is reachable: on screen, inside the window it belongs to;
/// - the accessibility order follows the layout: rows top to bottom and left to right within a row; or, for a surface
///   laid out in columns (the Export As accessory), its top row, then each column top to bottom, left to right.
/// The bottom bar is also held to its five pulldowns' order.
///
/// A gap fails the test and is printed as `SR-LIVE GAP`. The surface's picture is kept in the result bundle. AppKit's
/// own window buttons (`_XCUI:` identifiers) are listed, not judged: batch 32 item 1 found AppKit's chrome, not the
/// app, behind the audit's findings. The save panel's own controls are AppKit's too, so the Export As check covers the
/// app's accessory only.
final class LiveAccessibilityUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private static let controlTypes: Set<XCUIElement.ElementType> = [
        .button, .popUpButton, .checkBox, .radioButton, .slider, .textField, .menuButton, .segmentedControl,
        .comboBox, .stepper, .link, .disclosureTriangle, .toggle, .switch,
    ]

    private struct Control {
        let type: XCUIElement.ElementType
        let identifier: String
        let spoken: String
        let frame: CGRect
        let enabled: Bool

        var name: String { identifier.isEmpty ? "\"\(spoken)\"" : identifier }
    }

    @MainActor
    func testDocumentWindowAndBottomBar() throws {
        let app = launchWithDocument()
        let window = app.windows["document-window"]
        // The bar's own container (`document-bottom-bar`, "Document status") is not an element XCUI or VoiceOver
        // reaches (b32-i2-mac: the window's children were two unnamed groups), so its five pulldowns are held to their
        // order within the window.
        try check("document window and bottom bar", scope: window, window: window,
                  expectedOrder: ["variant-control", "style-control", "zoom-control", "page-size-control",
                                  "page-settings-control"])
    }

    @MainActor
    func testSettingsWindow() throws {
        let app = launchWithDocument()
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier == 'settings-window' OR title == 'Settings'"))
            .firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings did not open")
        Thread.sleep(forTimeInterval: 1)
        try check("Settings", scope: settings, window: settings)
    }

    @MainActor
    func testExportAsAccessory() throws {
        let app = launchWithDocument()
        app.menuBarItems["File"].click()
        app.menuItems["Export As…"].click()
        // b32-i2-mac: the panel arrives as AppKit's own window, `save-panel` (not an element carrying the app's
        // `export-panel`), and the accessory's container, `export-accessory`, is no element either. Its controls are
        // what VoiceOver lands on, so the panel is read whole and the app's `export-` controls are judged.
        let panel = app.windows["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the Export As panel did not appear")
        Thread.sleep(forTimeInterval: 1)
        func accessoryControls() throws -> [Control] {
            Self.controls(in: try panel.snapshot()).filter { $0.identifier.hasPrefix("export-") }
        }
        let expand = panel.disclosureTriangles["NS_OPEN_SAVE_DISCLOSURE_TRIANGLE"]
        if try accessoryControls().isEmpty, expand.exists, (expand.value as? Int ?? 1) == 0 {
            print("SR-LIVE Export As accessory: no export- control in the compact panel; expanding it")
            expand.click()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(try accessoryControls().isEmpty, "no export- control reachable in the Export As panel")
        try check("Export As accessory", scope: panel, window: panel, appOwned: { $0.hasPrefix("export-") })
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - The pass

    @MainActor
    private func launchWithDocument() -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoftReturnTests/Fixtures/report.ps")
        let app = XCUIApplication()
        app.launchArguments = ["-SoftReturnOpenDocument", fixture.path]
        app.launch()
        XCTAssertTrue(app.windows["document-window"].waitForExistence(timeout: 20), "no document window")
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    @MainActor
    private func check(_ surface: String, scope: XCUIElement, window: XCUIElement, expectedOrder: [String]? = nil,
                       appOwned: (String) -> Bool = { _ in true }) throws {
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "\(surface): not on screen")
        let all = Self.controls(in: try scope.snapshot())
        let judged = all.filter { !$0.identifier.hasPrefix("_XCUI:") && appOwned($0.identifier) }
        let appKit = all.filter { !$0.identifier.hasPrefix("_XCUI:") && !appOwned($0.identifier) }
        if !appKit.isEmpty { print("SR-LIVE \(surface): AppKit's own, not judged: \(appKit.map(\.name))") }
        let windowFrame = window.frame
        var gaps: [String] = []

        print("SR-LIVE \(surface): \(judged.count) controls, \(all.count - judged.count - appKit.count) AppKit window buttons not judged")
        for (index, control) in judged.enumerated() {
            print("SR-LIVE   \(index + 1). type \(control.type.rawValue) \(control.name) spoken \"\(control.spoken)\" "
                  + "\(control.frame)\(control.enabled ? "" : " disabled")")
            if control.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                gaps.append("\(control.name) (type \(control.type.rawValue)) at \(control.frame) has no spoken name")
            }
            if control.frame.isEmpty || !windowFrame.intersects(control.frame) {
                gaps.append("\(control.name) at \(control.frame) is not on screen in its window \(windowFrame)")
            }
        }

        let rows = Self.layoutOrder(judged)
        let columns = Self.columnOrder(judged)
        if rows != Array(judged.indices) && columns != Array(judged.indices) {
            gaps.append("accessibility order \(judged.map(\.name)) follows neither the layout's rows \(rows.map { judged[$0].name }) "
                        + "nor its columns \(columns.map { judged[$0].name })")
        }
        if let expectedOrder {
            let found = judged.map(\.identifier).filter { expectedOrder.contains($0) }
            if found != expectedOrder { gaps.append("pulldowns in the order \(found), expected \(expectedOrder)") }
        }

        let picture = XCTAttachment(screenshot: window.screenshot())
        picture.name = "SR-LIVE \(surface)"
        picture.lifetime = .keepAlways
        add(picture)
        for gap in gaps { print("SR-LIVE GAP \(surface): \(gap)") }
        XCTAssertTrue(gaps.isEmpty, "\(surface): \(gaps.count) gap(s):\n" + gaps.joined(separator: "\n"))
    }

    /// Every control under `snapshot`, in accessibility order (the snapshot tree's own order, depth first).
    @MainActor
    private static func controls(in snapshot: XCUIElementSnapshot) -> [Control] {
        var found: [Control] = []
        func walk(_ node: XCUIElementSnapshot) {
            if controlTypes.contains(node.elementType) {
                found.append(Control(type: node.elementType, identifier: node.identifier,
                                     spoken: node.label.isEmpty ? node.title : node.label,
                                     frame: node.frame, enabled: node.isEnabled))
            }
            for child in node.children { walk(child) }
        }
        walk(snapshot)
        return found
    }

    /// The indices of `controls` read as a top row, then columns: the controls in the topmost row, left to right, then
    /// the rest clustered by left edge (within 6 pt), columns left to right, each top to bottom. b32-i2-mac2 found the
    /// Export As accessory read this way: Mode, then Formats, Notes, the option checkboxes and the option pulldowns.
    private static func columnOrder(_ controls: [Control]) -> [Int] {
        guard let firstRow = rowsOf(controls).first else { return [] }
        let rest = controls.indices.filter { !firstRow.contains($0) }
        var columns: [[Int]] = []
        for index in rest.sorted(by: { controls[$0].frame.minX < controls[$1].frame.minX }) {
            if let previous = columns.last?.last, abs(controls[previous].frame.minX - controls[index].frame.minX) < 6 {
                columns[columns.count - 1].append(index)
            } else {
                columns.append([index])
            }
        }
        return firstRow.sorted { controls[$0].frame.minX < controls[$1].frame.minX }
            + columns.flatMap { column in column.sorted { controls[$0].frame.midY < controls[$1].frame.midY } }
    }

    /// The indices of `controls` in layout order: rows by vertical centre (within 6 pt of the row's previous control),
    /// top to bottom — XCUI frames grow downward — and left to right within a row.
    private static func layoutOrder(_ controls: [Control]) -> [Int] {
        rowsOf(controls).flatMap { row in row.sorted { controls[$0].frame.minX < controls[$1].frame.minX } }
    }

    /// `controls`' indices grouped into rows, top to bottom: a control joins the row above when its vertical centre is
    /// within 6 pt of that row's last control.
    private static func rowsOf(_ controls: [Control]) -> [[Int]] {
        let byHeight = controls.indices.sorted { controls[$0].frame.midY < controls[$1].frame.midY }
        var rows: [[Int]] = []
        for index in byHeight {
            if let previous = rows.last?.last, abs(controls[previous].frame.midY - controls[index].frame.midY) < 6 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        return rows
    }
}
