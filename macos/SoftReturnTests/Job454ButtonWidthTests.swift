import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 454, Part C. Jon, live on b27: "the bar is getting too wide now for the beginning width
/// of the window on my laptop. So the bottom bar buttons all need to lose a few pixels in
/// width. 5? I don't know how wide they are so I don't know what's appropriate. I don't want to
/// clip any words in the button title. Same amount lost on each. 'Embedded' is the longest.
/// That's the one that will be effected first."
///
/// Real numbers, not a guess (`ZZProbeJob454ButtonWidths.swift`'s own run, against every bare
/// title a button can ever show — the provenance suffix never reaches the button face, only
/// the dropdown, per `BottomBar`'s own doc comment):
///
///   control                 width  widest bare title      title width   slack
///   variant-control          109    "Printstream"            60.56       48.44   <- tightest
///   page-settings-control    106    "Embedded"                56.24       49.76   (2nd, Jon's guess)
///   style-control             94    "Modern"                  40.26       53.74
///   page-size-control         94    "Custom"                  40.37       53.63
///   zoom-control               88    "Actual"                  33.01       54.99
///
/// Jon's "Embedded" is the second-tightest, not the tightest — `variant-control`'s
/// "Printstream" edges it out by about 1.3pt. Both, and everything else, carry 48pt+ of slack,
/// so his own guessed 5pt is comfortably safe: it leaves >43pt of real padding on the tightest
/// button, nowhere near clipping. `BottomBar.buttonWidthReduction` applies exactly 5pt, equally,
/// to all five `fixedWidth(candidates:)` results.
@Suite struct Job454ButtonWidthTests {

    @MainActor
    private static func popup(_ identifier: String, in bar: BottomBar) throws -> NSPopUpButton {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return try #require(
            descendants(bar).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == identifier },
            "no popup with identifier \(identifier)")
    }

    @MainActor
    private static func makeBar() throws -> BottomBar {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let state = try Oracle.state(for: url)
        let bar = BottomBar()
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: BottomBar.barHeight)
        bar.update(from: state)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private static func titleWidth(_ title: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: title, attributes: [.font: font]).size().width
    }

    /// Every bare title a button can ever actually display — the same lists the measurement
    /// probe used, kept here (not imported from `BottomBar`'s own private candidate arrays,
    /// which carry the provenance suffix the button itself never shows) so this test's claim
    /// is independent of that type's internals.
    private static let candidatesByControl: [(identifier: String, titles: [String])] = [
        ("variant-control", ["WS4", "WS5+", "Printstream", "Text"]),
        ("style-control", ViewStyle.allCases.map(\.displayName)),
        ("zoom-control", ["Fit", "Actual"] + ZoomSetting.steps.map { "\($0)%" }),
        ("page-size-control", NamedPageSize.allCases.map(\.shortName) + ["Custom"]),
        ("page-settings-control",
         [DocumentOperations.PageSettingsPreset.embeddedChoiceName]
            + DocumentOperations.PageSettingsPreset.allCases.map(\.displayName)),
    ]

    // MARK: - The reduction actually applied: each button is exactly 5pt narrower than before

    /// Pinned to the pre-job-454 widths themselves (109/94/88/94/106 — this suite's own
    /// measurement, taken before `buttonWidthReduction` existed) so this fails if the
    /// reduction ever drifts from Jon's "same amount lost on each, 5pt."
    @Test @MainActor func everyButtonLostExactlyFivePointsUniformly() throws {
        let bar = try Self.makeBar()
        let beforeWidths: [String: CGFloat] = [
            "variant-control": 109, "style-control": 94, "zoom-control": 88,
            "page-size-control": 94, "page-settings-control": 106,
        ]
        for (identifier, before) in beforeWidths.sorted(by: { $0.key < $1.key }) {
            let button = try Self.popup(identifier, in: bar)
            #expect(button.frame.width == before - 5,
                    "\(identifier) is \(button.frame.width)pt wide, expected \(before - 5) (was \(before), job 454 takes exactly 5pt off every button)")
        }
    }

    // MARK: - The permanent guard: no reachable title can ever clip

    /// The one that matters going forward. Not a snapshot of today's candidates — this walks
    /// the SAME live enumerations `BottomBar`'s own menu-building code draws from
    /// (`ViewStyle.allCases`, `ZoomSetting.steps`, `NamedPageSize.allCases`,
    /// `DocumentOperations.PageSettingsPreset.allCases`), so a new case added to any of them
    /// is automatically exercised here too. `minimumPadding` (43pt) sits just under this run's
    /// own measured floor (43.4pt, `variant-control`/"Printstream") — comfortably inside today's
    /// real number, but tight enough that a future title eating into that padding trips this
    /// before it ever reaches a shipped build.
    @Test @MainActor func noReachableTitleClipsItsButton() throws {
        let bar = try Self.makeBar()
        let minimumPadding: CGFloat = 43

        for (identifier, titles) in Self.candidatesByControl {
            let button = try Self.popup(identifier, in: bar)
            let font = button.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
            for title in titles {
                let width = Self.titleWidth(title, font: font)
                #expect(width + minimumPadding <= button.frame.width,
                        "\(identifier)'s title \"\(title)\" (rendered \(width)pt) plus the \(minimumPadding)pt minimum padding would exceed its \(button.frame.width)pt width — this title would clip")
            }
        }
    }

    // MARK: - Does the saving actually solve Jon's problem: does the bar fit the window?

    /// Jon's actual complaint was that the bar is "too wide for the beginning width of the
    /// window on my laptop" — the button reduction only matters if it narrows the bar enough
    /// to fit the window's own real first-open width. `applyFirstOpenGeometry()`
    /// (`DocumentWindowController.swift`) sizes that width from the document's OWN page size
    /// (scaled to fit the screen, capped at 92% of it, falling back to a synthetic 1440x900
    /// screen when there is no real display — this test's own environment), not a fixed
    /// constant — so this measures both sides for the same representative document (BOTHNOTE.WS,
    /// one US Letter page, no scaling needed on any screen wider than ~665pt) rather than
    /// asserting against a guessed number for either.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func barContentWidthFitsTheWindowsFirstOpenWidth() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("BOTHNOTE.WS")
        let state = try Oracle.state(for: url)
        let controller = DocumentWindowController(state: state)
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let windowContentWidth = try #require(controller.window?.contentView?.frame.width)

        let bar = controller.bottomBar
        let ids = ["variant-control", "style-control", "zoom-control", "page-size-control", "page-settings-control"]
        var buttonWidthSum: CGFloat = 0
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        for id in ids {
            let view = try #require(descendants(bar).first { $0.accessibilityIdentifier() == id },
                                     "no view with identifier \(id)")
            buttonWidthSum += view.frame.width
        }
        // 4 gaps between the 5 buttons (`BottomBar`'s own `stack.spacing`) plus the stack's
        // own leading/trailing edge insets (`stack.edgeInsets`) — the page indicator (job 454
        // Part A) sits after the 5th button but is excluded here: Jon's complaint and this
        // reduction are both about the BUTTONS specifically, and the indicator's own width
        // varies with the current page count rather than being part of "the bar getting wide."
        let interItemSpacing: CGFloat = 16 * 4
        let edgeInsets: CGFloat = 20
        let barButtonsWidth = buttonWidthSum + interItemSpacing + edgeInsets

        #expect(barButtonsWidth <= windowContentWidth,
                "the 5 buttons need \(barButtonsWidth)pt but the window's first-open content width is only \(windowContentWidth)pt — job 454's 5pt-per-button reduction is not enough on its own")
    }
}
