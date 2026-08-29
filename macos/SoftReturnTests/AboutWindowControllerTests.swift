import AppKit
import Foundation
import Testing
@testable import SoftReturn

/// Job 323 (b20 item 6, Jon's ruling: option A, "cooler") — the custom About window that
/// replaces the default `NSApplication` about panel.
///
/// `FakeEngineVersionProbe`/`FakeAboutURLOpener` are the same seam-not-inheritance move
/// `FakeCLIHelpWorkspace` already uses for `CLIHelpWindowController` — they let the row logic
/// and the link/button actions be asserted on without a real `sr` spawn or a real browser
/// launch from this (headless) test host.
@MainActor
private final class FakeEngineVersionProbe: EngineVersionProbing {
    let result: EngineVersionInfo?
    init(result: EngineVersionInfo?) { self.result = result }
    func currentInfo() -> EngineVersionInfo? { result }
}

@MainActor
private final class FakeAboutURLOpener: AboutURLOpening {
    private(set) var openedURLs: [URL] = []
    func open(_ url: URL) { openedURLs.append(url) }
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

@MainActor
private func button(_ identifier: String, in controller: AboutWindowController) throws -> NSButton {
    let content = try #require(controller.window?.contentView)
    return try #require(
        descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier },
        "no button with identifier \(identifier)")
}

/// All views under `controller.window`'s content, in the order the (single, vertical) stack
/// lays them out — used to assert relative position (e.g. "byte line comes right after the
/// name") without hardcoding index arithmetic against unrelated subviews.
@MainActor
private func stackView(in controller: AboutWindowController) throws -> NSStackView {
    let content = try #require(controller.window?.contentView)
    return try #require(descendants(content).compactMap { $0 as? NSStackView }.first)
}

@MainActor
private func stackedViews(in controller: AboutWindowController) throws -> [NSView] {
    try stackView(in: controller).arrangedSubviews
}

@MainActor
private func textField(_ identifier: String, in controller: AboutWindowController) throws -> NSTextField {
    let content = try #require(controller.window?.contentView)
    return try #require(
        descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == identifier },
        "no text field with identifier \(identifier)")
}

@MainActor
private func infoGrid(in controller: AboutWindowController) throws -> NSGridView {
    let content = try #require(controller.window?.contentView)
    return try #require(
        descendants(content).compactMap { $0 as? NSGridView }
            .first { $0.accessibilityIdentifier() == "about-info-grid" })
}

/// Row `rowIndex`'s label column (0) text, read off the real `NSGridView` cell — the same
/// "read the real control, don't re-derive it" discipline `WiringTests`' popup-identifier
/// scan uses.
@MainActor
private func rowLabel(_ grid: NSGridView, _ rowIndex: Int) -> String? {
    (grid.cell(atColumnIndex: 0, rowIndex: rowIndex).contentView as? NSTextField)?.stringValue
}

@MainActor
private func rowValueText(_ grid: NSGridView, _ rowIndex: Int) -> String? {
    let view = grid.cell(atColumnIndex: 1, rowIndex: rowIndex).contentView
    if let field = view as? NSTextField { return field.stringValue }
    if let button = view as? NSButton { return button.attributedTitle.string }
    return nil
}

@Suite("EngineVersionInfo parsing")
struct EngineVersionInfoTests {

    // MARK: - Clean (release-cut) banner — the ONLY shape the real engine produces today

    /// `sr`'s actual current `--version` output (`slantBanner + "\n" + versionLine`,
    /// `Sources/SoftReturnCLI/Arguments.swift`). Ruling 24 (Jon, 2026-08-28) dropped the
    /// `(ctrl-kd parity X.Y.Z)` clause from the banner entirely — this parser no longer
    /// expects it.
    static let cleanBanner = """
           _____       ______     ____       __
          / ___/____  / __/ /_   / __ \\___  / /___  ___________
          \\__ \\/ __ \\/ /_/ __/  / /_/ / _ \\/ __/ / / / ___/ __ \\
         ___/ / /_/ / __/ /_   / _, _/  __/ /_/ /_/ / /  / / / /
        /____/\\____/_/  \\__/  /_/ |_|\\___/\\__/\\__,_/_/  /_/ /_/
        sr v4.0.0
        """

    @Test func cleanBannerParsesVersionWithNoDevDateAndNoCommit() throws {
        let info = try #require(EngineVersionInfo.parse(Self.cleanBanner))
        #expect(info.srVersion == "4.0.0")
        #expect(info.devDate == nil)
        #expect(info.commitHash == nil)
        #expect(info.engineRowText == "sr v4.0.0")
        #expect(info.commitURL() == nil)
    }

    // MARK: - Dev banner — documented, not yet real; exercised via a literal fixture

    static let devBanner = """
        sr v4.0.0 (dev 2026-08-15)
        engine commit 971b375d6a1fd625368b6368c982fcac938137ca
        """

    @Test func devBannerParsesDevDateAndCommitHash() throws {
        let info = try #require(EngineVersionInfo.parse(Self.devBanner))
        #expect(info.srVersion == "4.0.0")
        #expect(info.devDate == "2026-08-15")
        #expect(info.commitHash == "971b375d6a1fd625368b6368c982fcac938137ca")
        // Job 341 (round 3): the dev parenthetical moves to its own line.
        #expect(info.engineRowText == "sr v4.0.0\n(dev 2026-08-15)")
    }

    @Test func devBannerCommitURLPointsAtTheEngineRepoNotTheAppRepo() throws {
        let info = try #require(EngineVersionInfo.parse(Self.devBanner))
        let url = try #require(info.commitURL())
        #expect(url.absoluteString ==
            "https://github.com/jonmichaels/soft-return/commit/971b375d6a1fd625368b6368c982fcac938137ca")
    }

    /// A dev-DATE with no following `engine commit` line (e.g. a build that stamped a date
    /// but not a hash) must not fabricate a commit — no stamp, no hash.
    @Test func devDateWithNoCommitLineLeavesCommitHashNil() throws {
        let info = try #require(EngineVersionInfo.parse("sr v4.0.0 (dev 2026-08-15)"))
        #expect(info.devDate == "2026-08-15")
        #expect(info.commitHash == nil)
    }

    @Test func unparseableOutputReturnsNil() {
        #expect(EngineVersionInfo.parse("") == nil)
        #expect(EngineVersionInfo.parse("not a version banner at all") == nil)
    }

    /// A stray line shaped like `engine commit ...` after a CLEAN (no dev-date) version line
    /// must not be picked up — the commit line is only meaningful paired with a dev stamp,
    /// per the ruling's own "no stamp -> no hash" rule.
    @Test func commitLineAfterACleanVersionLineIsIgnored() throws {
        let info = try #require(EngineVersionInfo.parse(
            "sr v4.0.0\nengine commit deadbeef"))
        #expect(info.commitHash == nil)
    }
}

@Suite("AboutWindowController", .serialized)
@MainActor
struct AboutWindowControllerTests {

    // MARK: - Window structure

    @Test func windowOpensAndCarriesItsAccessibilityIdentifier() {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        controller.showWindow(nil)
        #expect(controller.window?.accessibilityIdentifier() == "about-window")
    }

    @Test func windowIsNotResizable() {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        #expect(controller.window?.styleMask.contains(.resizable) == false)
    }

    /// Jon's ruling (job 335): match Ghostty's About window — an untitled title bar. Traffic
    /// lights still show (`.titled` + `.closable` are unchanged), just no title text.
    @Test func titleBarHasNoText() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let window = try #require(controller.window)
        #expect(window.title == "")
        #expect(window.styleMask.contains(.titled), "title bar area (traffic lights) must stay")
        #expect(window.styleMask.contains(.closable), "red traffic light must stay")
    }

    /// Esc reaches `cancelOperation(_:)` (AppKit's own "cancel:" key binding for Escape) when
    /// no subview claims it first — this window has no editable field to intercept it, so the
    /// override closes the window directly. Driven via `cancelOperation(_:)` itself (not a
    /// real key event) — the same reasoning `UIRound4BRulingTests` gives for calling AppKit
    /// action methods directly in a headless test host rather than synthesizing NSEvents.
    @Test func escapeClosesTheWindow() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        controller.showWindow(nil)
        let window = try #require(controller.window)
        #expect(window.isVisible)
        window.cancelOperation(nil)
        #expect(!window.isVisible)
    }

    // MARK: - Job 329 (b21): card polish

    /// Jon's ruling: "8D0A" sits directly under the name, reusing `AboutInfo`'s own easter-egg
    /// byte pair rather than a re-typed literal.
    @Test func byteLineShowsTheAboutInfoEasterEggByte() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let byteLine = try textField("about-byte-line", in: controller)
        #expect(byteLine.stringValue == AboutInfo.softReturnByte)
    }

    /// Stack order proves "directly under the name" — the byte line is the very next
    /// arranged view after the title, ahead of the tagline.
    @Test func byteLineIsPositionedImmediatelyAfterTheName() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let views = try stackedViews(in: controller)
        let titleIndex = try #require(views.firstIndex { ($0 as? NSTextField)?.accessibilityIdentifier() == "about-title" })
        let byteLineIndex = try #require(views.firstIndex { ($0 as? NSTextField)?.accessibilityIdentifier() == "about-byte-line" })
        let taglineIndex = try #require(views.firstIndex { ($0 as? NSTextField)?.accessibilityIdentifier() == "about-tagline" })
        #expect(byteLineIndex == titleIndex + 1)
        #expect(taglineIndex == byteLineIndex + 1)
    }

    /// Jon's ruling: an explicit break after "and", not a wrap-dependent one.
    @Test func taglineBreaksAfterAndIntoTwoLines() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let tagline = try textField("about-tagline", in: controller)
        #expect(tagline.stringValue == "A WordStar document viewer and\nconverter for the Mac")
    }

    /// Jon's ruling: the trailing "MIT licensed" text line is still gone (job 329).
    @Test func mitTextLineIsGone() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let content = try #require(controller.window?.contentView)
        #expect(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "about-mit-line" } == nil)
    }

    // MARK: - Job 335 (b22): Ghostty-match round 2

    /// Jon's ruling: the License button is gone entirely. The bundled `LICENSE` file itself
    /// stays (Project.swift resource); it just has no in-app viewer pointed at it anymore.
    @Test func licenseButtonIsGone() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let content = try #require(controller.window?.contentView)
        #expect(descendants(content).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "about-license-button" } == nil)
    }

    // MARK: - Job 341 (b23): Ghostty-match round 3

    /// Jon's ruling: the Releases button is gone too — GitHub is now the only button.
    @Test func releasesButtonIsGone() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let content = try #require(controller.window?.contentView)
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        #expect(buttons.first { $0.accessibilityIdentifier() == "about-releases-button" } == nil)
        #expect(buttons.count == 1, "GitHub must be the only button left")
    }

    /// Jon's ruling: row label/value fonts are sized UP to match Ghostty's own proportions —
    /// ~13pt, bigger than b22's `smallSystemFontSize` (~11pt).
    @Test func rowFontsAreSizedUpToGhosttysProportions() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        let label = try #require(grid.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextField)
        let value = try #require(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField)
        #expect(label.font?.pointSize == 13)
        #expect(value.font?.pointSize == 13)
        #expect(label.font?.pointSize ?? 0 > NSFont.smallSystemFontSize)
    }

    /// Jon's ruling: the row-label/row-value axis inside the grid stays right/left aligned per
    /// column, but the grid AS A WHOLE is centered in the window, Ghostty's exact arrangement
    /// — this is `NSStackView`'s `.centerX` alignment centering the grid's own hugged content
    /// width, not the grid stretching to the stack's full width with columns spread apart.
    @Test func infoGridBlockIsHorizontallyCenteredInTheWindowAsAWhole() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let content = try #require(controller.window?.contentView)
        let stack = try stackView(in: controller)
        let grid = try infoGrid(in: controller)
        content.layoutSubtreeIfNeeded()
        let gridCenterInStack = stack.convert(NSPoint(x: grid.frame.midX, y: 0), from: grid).x
        #expect(abs(gridCenterInStack - stack.bounds.midX) < 1.0,
                "the info grid's own bounding box must be centered on the stack's centerX")
        // Still right/left aligned internally — the axis itself didn't change.
        #expect(grid.column(at: 0).xPlacement == .trailing)
        #expect(grid.column(at: 1).xPlacement == .leading)
    }

    /// Jon's ruling: the Engine row's dev shape wraps — "sr v4.0.0" on line 1, "(dev ...)" on
    /// its own line 2 below it, rather than one long single-line string.
    @Test func engineRowWrapsTheDevParentheticalOntoItsOwnLine() throws {
        let info = try #require(EngineVersionInfo.parse(EngineVersionInfoTests.devBanner))
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: info), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        #expect(rowValueText(grid, 2) == "sr v4.0.0\n(dev 2026-08-15)")
        let value = try #require(grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as? NSTextField)
        #expect(value.maximumNumberOfLines == 0, "the dev-shape value must allow more than one line")
    }

    /// A clean (release-cut) banner has no dev stamp — the Engine row's value must stay a
    /// single line, no trailing blank second line.
    @Test func engineRowStaysSingleLineOnACleanReleaseBanner() throws {
        let info = try #require(EngineVersionInfo.parse(EngineVersionInfoTests.cleanBanner))
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: info), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        #expect(rowValueText(grid, 2) == "sr v4.0.0")
        #expect(rowValueText(grid, 2)?.contains("\n") == false)
    }

    /// Jon's ruling: "8D0A" is visibly bigger than the tagline (it's a feature, not fine
    /// print) while staying well under the bold app-name's weight.
    @Test func byteLineFontIsBiggerThanTaglineButSmallerThanTheTitle() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let title = try textField("about-title", in: controller)
        let byteLine = try textField("about-byte-line", in: controller)
        let tagline = try textField("about-tagline", in: controller)
        let titleSize = try #require(title.font?.pointSize)
        let byteSize = try #require(byteLine.font?.pointSize)
        let taglineSize = try #require(tagline.font?.pointSize)
        #expect(byteSize > taglineSize)
        #expect(byteSize < titleSize)
    }

    /// Jon's ruling: 8D0A sits TIGHT under "Soft Return" — no extra gap after it (reverses
    /// b21's spacing, which added a blank-line gap here).
    @Test func noExtraGapAfterTheByteLine() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let stack = try stackView(in: controller)
        let byteLine = try textField("about-byte-line", in: controller)
        #expect(stack.customSpacing(after: byteLine) == NSStackView.useDefaultSpacing,
                "byte-line gap must revert to the stack's own default spacing, not a custom blank-line gap")
    }

    /// Jon's ruling: a blank line's worth of space goes BEFORE the buttons row now (new in
    /// this job) — bigger than the stack's own default spacing.
    @Test func blankLineGapSitsBeforeTheButtonsRow() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let stack = try stackView(in: controller)
        let grid = try infoGrid(in: controller)
        let gapBeforeButtons = stack.customSpacing(after: grid)
        #expect(gapBeforeButtons != NSStackView.useDefaultSpacing)
        #expect(gapBeforeButtons > stack.spacing)
    }

    /// Jon's ruling: row LABELS in the regular system font (dimmed secondary color) — Ghostty's
    /// own treatment, superseding b20/b21's bundled Courier Prime rows.
    @Test func rowLabelsUseTheRegularSystemFontInSecondaryColor() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        let label = try #require(grid.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextField)
        let expected = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        #expect(label.font?.fontName == expected.fontName)
        #expect(label.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
        #expect(label.textColor == .secondaryLabelColor)
    }

    /// Jon's ruling: row VALUES in the monospaced system font (SF Mono look), NOT Courier
    /// Prime.
    @Test func rowValuesUseTheMonospacedSystemFontNotCourierPrime() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        let value = try #require(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField)
        let expected = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        #expect(value.font?.fontName == expected.fontName)
        #expect(value.font?.familyName != "Courier Prime")
    }

    // MARK: - Row presence/absence

    /// Job 335: a "Build" row now sits between Version and Engine, always shown (like
    /// Version), regardless of whether the engine probe returned anything.
    @Test func noEngineInfoShowsOnlyVersionAndBuildRows() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        #expect(grid.numberOfRows == 2)
        #expect([rowLabel(grid, 0), rowLabel(grid, 1)] == ["Version", "Build"])
    }

    /// Job 341 (round 3): the Parity row is gone entirely — a clean banner shows just
    /// Version/Build/Engine.
    @Test func cleanBannerShowsVersionBuildEngineButOmitsTheCommitRow() throws {
        let info = try #require(EngineVersionInfo.parse(EngineVersionInfoTests.cleanBanner))
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: info), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        #expect(grid.numberOfRows == 3, "clean (no dev suffix) banner must not show a Commit row")
        #expect([rowLabel(grid, 0), rowLabel(grid, 1), rowLabel(grid, 2)]
            == ["Version", "Build", "Engine"])
        #expect(rowValueText(grid, 2) == "sr v4.0.0")
    }

    /// Job 341 (round 3): the row set is Version/Build/Engine/Commit — Parity is gone, and the
    /// Engine row's dev shape now wraps onto two lines.
    @Test func devBannerShowsAllFourRowsInOrderIncludingBuildAndCommit() throws {
        let info = try #require(EngineVersionInfo.parse(EngineVersionInfoTests.devBanner))
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: info), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        #expect(grid.numberOfRows == 4)
        #expect([rowLabel(grid, 0), rowLabel(grid, 1), rowLabel(grid, 2), rowLabel(grid, 3)]
            == ["Version", "Build", "Engine", "Commit"])
        #expect(rowValueText(grid, 2) == "sr v4.0.0\n(dev 2026-08-15)")
        #expect(rowValueText(grid, 3) == "971b375d6a1fd625368b6368c982fcac938137ca")
    }

    /// Job 335: the Version row drops its parenthetical "(N)" build number — the Build row
    /// replaces it.
    @Test func versionRowReadsTheLiveMarketingVersionAloneNeverALiteralAndNeverTheBuildParenthetical() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(rowValueText(grid, 0) == (marketing ?? "?"))
        #expect(rowValueText(grid, 0)?.contains("(") == false)
    }

    /// Job 335: the new Build row reads `CFBundleVersion` live off the bundle, never a
    /// literal (same discipline the Version row already had).
    @Test func buildRowReadsLiveInfoPlistValueNeverALiteral() throws {
        let controller = AboutWindowController(
            engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: FakeAboutURLOpener())
        let grid = try infoGrid(in: controller)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(rowValueText(grid, 1) == (build ?? "?"))
    }

    // MARK: - Links and buttons

    @Test func gitHubButtonOpensTheAppRepoPage() throws {
        let opener = FakeAboutURLOpener()
        let controller = AboutWindowController(engineProbe: FakeEngineVersionProbe(result: nil), urlOpener: opener)
        let gitHubButton = try button("about-github-button", in: controller)
        _ = gitHubButton.target?.perform(gitHubButton.action, with: gitHubButton)
        #expect(opener.openedURLs == [GitHubUpdateFeed.repoPageURL])
    }

    /// `URL.deletingLastPathComponent()` leaves a trailing slash (Foundation's own documented
    /// behaviour) — the repo page opens fine either way, so the test pins that real shape
    /// rather than a stripped one the implementation never produces.
    @Test func repoPageURLIsTheReleasesPageWithoutTheTrailingReleasesComponent() {
        #expect(GitHubUpdateFeed.repoPageURL.absoluteString == "https://github.com/jonmichaels/soft-return/")
        #expect(GitHubUpdateFeed.releasesPageURL.absoluteString
            == "https://github.com/jonmichaels/soft-return/releases")
    }

    @Test func commitLinkOpensTheEngineCommitPageWhenADevBannerIsPresent() throws {
        let info = try #require(EngineVersionInfo.parse(EngineVersionInfoTests.devBanner))
        let opener = FakeAboutURLOpener()
        let controller = AboutWindowController(engineProbe: FakeEngineVersionProbe(result: info), urlOpener: opener)
        let commitLink = try button("about-commit-link", in: controller)
        _ = commitLink.target?.perform(commitLink.action, with: commitLink)
        let expectedURL = try #require(info.commitURL())
        #expect(opener.openedURLs == [expectedURL])
    }

    // MARK: - Job 323's own "prove it, don't assume" — a REAL spawn of the bundled `sr`

    /// The recommended engine-value-sourcing route (job 323's ruling) is running the BUNDLED
    /// `sr` under `Process` — this drives the REAL `ProcessEngineVersionProbe` (no fake) in
    /// this hosted test process, which per job 248's own precedent runs with the SAME sandbox
    /// entitlements the shipping app does. A successful, non-nil, well-shaped result here is
    /// the empirical proof the ruling asks for, not an assumption: `sr`'s child process
    /// inherits the sandbox and reads no files, so if this ever regresses to `nil` it means a
    /// REAL sandbox-exec denial, not a parsing gap (parsing is covered exhaustively above by
    /// `EngineVersionInfoTests`, all off literal fixtures).
    ///
    /// CORRECTED finding, job 323: `--verbose` and the dev-date/commit stamp are NOT
    /// aspirational — `Scripts/build-sr-cli.sh` already injects them into `DevStamp.swift`
    /// for every configuration (Jon's ruling 2026-08-14, b19), reading straight off the
    /// pinned SPM checkout's own `git log`/`rev-parse`. This test's first draft assumed the
    /// opposite off a STALE standalone clone and an old prebuilt app's `strings` output
    /// neither of which reflect the checkout THIS build actually resolved — the real spawn
    /// caught the mistake, which is exactly what "prove it, don't assume" is for.
    ///
    /// CORRECTED again, job 545: `build-sr-cli.sh`'s own release switch (Jon's ruling
    /// 2026-08-14) drops to the clean, nil-stamped banner whenever `MARKETING_VERSION` is
    /// STABLE (no "b"), not only on a real release cut — this repo's `MARKETING_VERSION` has
    /// been stable (no "b" suffix) since the v4.0.0 release cut, so a hosted test build now
    /// produces the clean shape, not the dev one. This asserts shape-correctness of WHICHEVER shape actually comes
    /// back rather than assuming one, since which shape is live depends on the checked-out
    /// version, not on this test.
    @Test func realBundledSRSpawnSucceedsUnderSandboxAndParsesTheBanner() throws {
        let probe = ProcessEngineVersionProbe()
        let info = try #require(probe.currentInfo(), """
            spawning the bundled sr under Process returned nil — either the bundled binary \
            is missing from this test host, or the spawn was denied; see job 323's report
            """)
        // SHAPE only, never a literal — the engine bumps `srVersion` on its own release
        // cadence, and the dev date/hash change with every pinned commit and every build
        // (CLAUDE.md: no version literals in tests; `AboutInfoTests`' own header notes a
        // hardcoded version broke on this app's very first bump).
        #expect(info.srVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                "srVersion \(info.srVersion) is not a plain X.Y.Z")
        if let devDate = info.devDate {
            #expect(devDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                    "devDate \(devDate) is not a plain YYYY-MM-DD")
            let commitHash = try #require(info.commitHash, "expected an engine commit stamp alongside the dev date")
            #expect(commitHash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil,
                    "commitHash \(commitHash) is not plain lowercase hex")
            #expect(info.engineRowText == "sr v\(info.srVersion)\n(dev \(devDate))")
            #expect(info.commitURL()?.absoluteString
                == "https://github.com/jonmichaels/soft-return/commit/\(commitHash)")
        } else {
            // The clean (release-switch) shape: no dev stamp, no commit, single-line row.
            #expect(info.commitHash == nil)
            #expect(info.engineRowText == "sr v\(info.srVersion)")
            #expect(info.commitURL() == nil)
        }
    }
}
