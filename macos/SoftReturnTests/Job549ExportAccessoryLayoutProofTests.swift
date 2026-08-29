import AppKit
import Testing
@testable import SoftReturn

/// Job 549: the real proof for Jon's verbatim ruling on the Export As sheet's 4th column
/// (Pictures/Page Numbering/Sentence Spacing) — against REAL, window-hosted frames via
/// `LayoutProof`, not the bare `layoutSubtreeIfNeeded()` (no window at all)
/// `ExportSheetOptionsTests` uses for its non-geometric assertions. Job 545's own equivalent
/// test ran the same way and still missed what Jon's real macOS 26 screenshot showed — this
/// suite exists specifically to close that gap, and also drops the job's required proof
/// artifacts (`export-accessory.png`, `frames.txt`) into `outbox/job549/` for Athena's eyeball
/// pass before anything reaches Jon.
@Suite @MainActor struct Job549ExportAccessoryLayoutProofTests {
    /// Repo root derived from this source file's own path (three parents up: this file,
    /// `SoftReturnTests`, `macos` — job 531's `macos/` restructure) — the same pattern
    /// `QLCLIByteParityTests.ws7Directory` already uses, so this stays correct on the CI host
    /// and on any stranger's checkout alike, never a hardcoded worker path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
    }

    private static var outputDirectory: URL {
        RenderProbeKit.resolveOutputDirectory(
            preferred: repoRoot.appendingPathComponent("outbox/job549", isDirectory: true),
            fallbackName: "job549-evidence")
    }

    private static func checkbox(_ root: NSView, _ identifier: String) throws -> NSButton {
        try #require(
            LayoutProof.descendants(root).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no \(identifier) NSButton found")
    }

    private static func popup(_ root: NSView, _ identifier: String) throws -> NSPopUpButton {
        try #require(
            LayoutProof.descendants(root).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no \(identifier) NSPopUpButton found")
    }

    private static func label(_ root: NSView, text: String) throws -> NSTextField {
        try #require(
            LayoutProof.descendants(root).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == text },
            "no NSTextField with text '\(text)' found")
    }

    private static func columnStack(_ root: NSView, headingText: String) throws -> NSStackView {
        let heading = try label(root, text: headingText)
        return try #require(heading.superview as? NSStackView,
                             "'\(headingText)' heading is not the first row of its own column stack")
    }

    /// The 4th, popups column — located structurally (the fourth arranged subview of the row
    /// stack the three NAMED columns share a parent through), never by guessing at a type or
    /// an identifier, since the column itself carries neither (job 549 made it a plain
    /// `NSView`, not an `NSStackView` — see `ExportAccessoryView.makePopupsColumn`).
    private static func popupsColumn(_ root: NSView) throws -> NSView {
        let optionsColumn = try columnStack(root, headingText: "Options")
        let columnsRow = try #require(optionsColumn.superview as? NSStackView,
                                       "'Options' column has no parent row stack")
        #expect(columnsRow.arrangedSubviews.count == 4,
                "expected 4 arranged subviews in the columns row, found \(columnsRow.arrangedSubviews.count)")
        return try #require(columnsRow.arrangedSubviews[safe: 3], "columns row has no 4th column")
    }

    /// Each view's own alignment rect (not raw frame) — `ExportSheetOptionsTests`' own
    /// precedent comment names why: an `NSPopUpButton`'s bezel chrome inset makes raw frames
    /// read a false misalignment Auto Layout itself does not see. Converted into `root`'s
    /// coordinate space so every measurement in this file is directly comparable.
    private static func alignmentFrame(_ view: NSView, in root: NSView) -> CGRect {
        guard let superview = view.superview else { return view.frame }
        let alignmentRect = view.alignmentRect(forFrame: view.frame)
        return superview.convert(alignmentRect, to: root)
    }

    /// The edge a flipped-or-not view calls "top" — resolved from `root` itself rather than
    /// assumed, so this stays correct even if some future view in this tree overrides
    /// `isFlipped` (none of today's do).
    private static func topY(_ frame: CGRect, in root: NSView) -> CGFloat {
        root.isFlipped ? frame.minY : frame.maxY
    }

    /// The real vertical GAP between two non-overlapping rects along Y — the lower one's near
    /// edge minus the higher one's near edge — flip-agnostic, unlike a plain `minY`/`maxY`
    /// difference, which silently assumes an orientation.
    private static func verticalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(a.minY, b.minY) - min(a.maxY, b.maxY)
    }

    /// Jon's ruling, verbatim (2026-08-29): "'Pictures' title text must exactly vertically
    /// align with 'Headers/Footers'. And it's pulldown menu with the same relative alignment
    /// to its title. 'Page Numbering' and 'Sentence Spacing' must keep the same horizontal
    /// alignment in relation to 'Pictures' but the vertical space between each pulldown menu
    /// must match the vertical space between checkboxes in one of the other columns. This does
    /// mean that 'Page Numbering' will NOT line up with 'Table of Contents'. The pulldown menu
    /// is taller than the checkbox." Plus job 549's own restated 4th-column top-pin
    /// requirement. Hosted for real (`LayoutProof.host`, a genuine offscreen window), not
    /// measured off a bare, unhosted view tree.
    @Test @MainActor func exportAccessoryFourthColumnMatchesJonsRuling() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "Job549.\(UUID().uuidString)")!)
        let accessory = ExportAccessoryView(
            formats: [.rtf, .pdf], notes: NoteSelection(), style: .native, settings: settings)
        accessory.layoutSubtreeIfNeeded()
        let sheetSize = accessory.fittingSize
        let window = await LayoutProof.host(accessory, size: sheetSize)
        let root = try #require(window.contentView)

        // Proof artifacts, dumped before any assertions run so a failing assertion still
        // leaves the evidence behind for Athena to eyeball.
        let frameTableText = try LayoutProof.writeFrameTable(
            root: root, to: Self.outputDirectory.appendingPathComponent("frames.txt"))
        #expect(!frameTableText.isEmpty, "frames.txt was written empty")
        let pngSize = try LayoutProof.renderPNG(
            view: root, to: Self.outputDirectory.appendingPathComponent("export-accessory.png"))
        #expect(pngSize > 0, "export-accessory.png was written empty")

        let headersCheck = try Self.checkbox(root, "export-headers-checkbox")
        let tocCheck = try Self.checkbox(root, "export-toc-checkbox")
        let picturesLabel = try Self.label(root, text: "Pictures:")
        let picturesPopup = try Self.popup(root, "export-pictures-popup")
        let pageNumbersPopup = try Self.popup(root, "export-page-numbers-popup")

        let headersFrame = Self.alignmentFrame(headersCheck, in: root)
        let tocFrame = Self.alignmentFrame(tocCheck, in: root)
        let picturesLabelFrame = Self.alignmentFrame(picturesLabel, in: root)
        let picturesPopupFrame = Self.alignmentFrame(picturesPopup, in: root)
        let pageNumbersPopupFrame = Self.alignmentFrame(pageNumbersPopup, in: root)

        // (1) "'Pictures' title text must exactly vertically align with 'Headers/Footers'."
        let labelAlignment = abs(picturesLabelFrame.midY - headersFrame.midY)
        #expect(labelAlignment <= 1, """
            Pictures label center Y (\(picturesLabelFrame.midY)) must align with Headers/Footers' \
            own center Y (\(headersFrame.midY)) — off by \(labelAlignment)pt
            """)

        // "...and it's pulldown menu with the same relative alignment to its title" — the
        // popup stays centered on its own label, the same shape every other row in this sheet
        // already uses.
        let popupToLabelAlignment = abs(picturesPopupFrame.midY - picturesLabelFrame.midY)
        #expect(popupToLabelAlignment <= 1, """
            Pictures popup center Y (\(picturesPopupFrame.midY)) must align with its own \
            label's center Y (\(picturesLabelFrame.midY)) — off by \(popupToLabelAlignment)pt
            """)

        // (2) "...the vertical space between each pulldown menu must match the vertical space
        // between checkboxes in one of the other columns" (measured here against Options'
        // own Headers/Footers -> Table of Contents gap).
        let checkboxGap = Self.verticalGap(headersFrame, tocFrame)
        let popupGap = Self.verticalGap(picturesPopupFrame, pageNumbersPopupFrame)
        let gapDelta = abs(checkboxGap - popupGap)
        #expect(gapDelta <= 1, """
            popup-to-popup gap (\(popupGap)) must match the Options column's own checkbox-to-\
            checkbox gap (\(checkboxGap)) — off by \(gapDelta)pt
            """)

        // (3) 4th column top-pinned — its first row's top (the blank heading `column(...)`
        // still opens every column with, popups included) matches the other three columns'
        // own first-row (heading) top.
        let popupsColumn = try Self.popupsColumn(root)
        let optionsColumn = try Self.columnStack(root, headingText: "Options")
        let popupsColumnFrame = popupsColumn.convert(popupsColumn.bounds, to: root)
        let optionsColumnFrame = optionsColumn.convert(optionsColumn.bounds, to: root)
        let popupsTop = Self.topY(popupsColumnFrame, in: root)
        let optionsTop = Self.topY(optionsColumnFrame, in: root)
        let topDelta = abs(popupsTop - optionsTop)
        #expect(topDelta <= 1, """
            popups column top (\(popupsTop)) must match the Options column's own top \
            (\(optionsTop)) — off by \(topDelta)pt
            """)

        // Consequence Jon called out explicitly, not a requirement to enforce either way: Page
        // Numbering (row 2 of the popups column) is NOT expected to land on Table of Contents'
        // row (row 2 of Options) — the popup is taller than the checkbox, so the two columns'
        // pitches diverge below row 1. Left unasserted deliberately; `frames.txt` carries the
        // real numbers for anyone who wants to check.
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
