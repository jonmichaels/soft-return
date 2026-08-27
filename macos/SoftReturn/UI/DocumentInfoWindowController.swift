import AppKit
import CtrlKD

/// View ▸ Show Document Info, ⌘I (job 314) — the per-document Inspector.
///
/// Job 329/b21 (Jon's field notes: "window is WAY too long"): TWO TABS, Preview's own
/// General Info idiom (a segmented-control-style switcher at the top, one fixed-height
/// content area below it):
///
/// 1. "Document" — the Preview-style Get-Info vertical list (File Name / Kind / Size /
///    Where / Created / Modified / Page Size / Pages, `PagePreviewRenderer.info`'s eight
///    rows in its fixed order) plus the Document summary (word/character counts, declared
///    fonts, note counts, resolved margins) — no "Document" HEADER row inside the tab, since
///    the tab itself already carries that name. ONE shared label:colon alignment axis
///    across both groups (b20 gave each its own axis; Jon's ruling unifies them), with the
///    thin separator between the two groups kept.
/// 2. "Diagnose" — the engine's own `--diagnose` report (`DocumentOperations.diagnose`),
///    rendered as rows and small sub-headers, same as before — but now SCROLLABLE (job 324's
///    "no scroll box anywhere" ruling is superseded here: with the window's height now fixed
///    to the Document tab's own content, a long Diagnose report needs somewhere to go that
///    isn't the window itself). Its own label axis is unchanged from job 324/324-round-2 —
///    a nested nested-object report has field names of very different lengths than the flat
///    Document tab list, so it keeps its own, wider column rather than forcing job 329's
///    unified axis onto content the ruling never mentions.
///
/// The window's height is FIXED to the Document tab's own fitting content height — switching
/// to Diagnose never resizes the window; Diagnose's content scrolls within that same fixed
/// area. Title is the plain "Document Info", no "— FILENAME" suffix (Jon's ruling).
///
/// A floating `NSPanel`, styled like Preview's own Inspector (compact, its own title bar,
/// hovers above the document window rather than competing with it) — the one auxiliary
/// window in this app meant to sit beside what it describes rather than stand alone the way
/// Settings or the CLI help window do.
final class DocumentInfoWindowController: NSWindowController {
    private static let contentWidth: CGFloat = InspectorRows.contentWidth
    /// The ONE shared label:colon axis for the Document tab (file-info + summary rows) —
    /// job 329's unification of b20's two separate axes. Wide enough for "Character Count:",
    /// the longest label either group carries.
    private static let documentLabelWidth: CGFloat = 120
    /// The Diagnose tab's own axis — untouched by job 329's unification (see this file's own
    /// doc comment for why).
    private static let diagnoseLabelWidth: CGFloat = 150

    private let fileInfoStack = NSStackView()
    private let summaryStack = NSStackView()
    private let diagnoseStack = NSStackView()
    private let documentTabStack = NSStackView()
    private let diagnoseScrollView = NSScrollView()
    private let tabContainer = NSView()
    private let tabControl = NSSegmentedControl(
        labels: ["Document", "Diagnose"], trackingMode: .selectOne, target: nil, action: nil)
    private var tabHeightConstraint: NSLayoutConstraint!

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 460),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Document Info"
        // Floats above its owning document window without stealing key focus on click —
        // Preview's own Inspector behaviour, and why `.nonactivatingPanel` is in the style
        // mask above rather than plain `.titled, .closable`.
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilityIdentifier("document-info-panel")
        super.init(window: panel)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    private func buildContent() {
        guard let window else { return }

        fileInfoStack.orientation = .vertical
        fileInfoStack.alignment = .leading
        fileInfoStack.spacing = 4
        fileInfoStack.setAccessibilityIdentifier("document-info-file-list")

        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 4
        summaryStack.setAccessibilityIdentifier("document-info-summary-list")

        documentTabStack.orientation = .vertical
        documentTabStack.alignment = .leading
        documentTabStack.spacing = 10
        documentTabStack.translatesAutoresizingMaskIntoConstraints = false
        documentTabStack.setAccessibilityIdentifier("document-info-document-tab")
        for view in [fileInfoStack, separator(), summaryStack] {
            documentTabStack.addArrangedSubview(view)
        }

        diagnoseStack.orientation = .vertical
        diagnoseStack.alignment = .leading
        diagnoseStack.spacing = 4
        diagnoseStack.translatesAutoresizingMaskIntoConstraints = false
        diagnoseStack.setAccessibilityIdentifier("document-info-diagnose-list")

        // Job 329: SCROLLABLE — real AutoLayout constraints pin the stack's width to the
        // scroll view's content area and leave its height free, the fix for exactly the
        // class of bug job 324's own doc comment traces (a manually-framed `NSTextView` that
        // never actually sized itself). No frame math here for the same reason.
        diagnoseScrollView.hasVerticalScroller = true
        diagnoseScrollView.autohidesScrollers = true
        diagnoseScrollView.drawsBackground = false
        diagnoseScrollView.translatesAutoresizingMaskIntoConstraints = false
        diagnoseScrollView.documentView = diagnoseStack
        diagnoseScrollView.setAccessibilityIdentifier("document-info-diagnose-scroll")
        diagnoseScrollView.isHidden = true
        NSLayoutConstraint.activate([
            diagnoseStack.leadingAnchor.constraint(equalTo: diagnoseScrollView.contentView.leadingAnchor),
            diagnoseStack.trailingAnchor.constraint(equalTo: diagnoseScrollView.contentView.trailingAnchor),
            diagnoseStack.topAnchor.constraint(equalTo: diagnoseScrollView.contentView.topAnchor),
        ])

        tabControl.segmentStyle = .automatic
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.setAccessibilityIdentifier("document-info-tab-control")

        // Job 329: the window's height is fixed to the DOCUMENT tab's own content — this
        // container's height is a constraint `resizeToFitContent()` sets from
        // `documentTabStack.fittingSize`, never from whichever tab happens to be showing, so
        // switching to Diagnose can never resize the window (Diagnose scrolls within this
        // same fixed area instead).
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(documentTabStack)
        tabContainer.addSubview(diagnoseScrollView)
        tabHeightConstraint = tabContainer.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            tabHeightConstraint,
            documentTabStack.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            documentTabStack.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            documentTabStack.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            diagnoseScrollView.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            diagnoseScrollView.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            diagnoseScrollView.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            diagnoseScrollView.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        let content = NSView()
        content.addSubview(tabControl)
        content.addSubview(tabContainer)
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            tabContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12),
            tabContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        // Job 329: exactly "Document Info", no "— FILENAME" suffix — set once here, never
        // touched again (the old `refresh()` used to rewrite it from the document window's
        // own title on every refresh).
        window.title = "Document Info"
        window.setContentSize(NSSize(width: Self.contentWidth, height: 480))
        // Job 397 (Jon F9): see `SettingsWindowController.buildForm`'s comment on the same
        // pair of calls — a floating inspector a user positions beside their document and
        // expects to stay there gets frame autosave, with `center()` as the first-open
        // fallback (fixes the bottom-left-corner spawn either way).
        window.setFrameAutosaveName("DocumentInfoPanel")
        if !window.setFrameUsingName("DocumentInfoPanel") {
            window.center()
        }
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth - 32).isActive = true
        return line
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let showDiagnose = sender.selectedSegment == 1
        documentTabStack.isHidden = showDiagnose
        diagnoseScrollView.isHidden = !showDiagnose
    }

    // MARK: - Refresh

    /// Rebuild every section from `controller`'s CURRENT state, then resize the panel to fit
    /// the Document tab's own content — called on every toggle-open and, while the panel is
    /// already visible, after any state change (`DocumentWindowController.reloadContent()`)
    /// — so a variant, style or page-size change never leaves the Inspector showing stale
    /// numbers.
    @MainActor
    func refresh(from controller: DocumentWindowController) {
        Self.replace(fileInfoStack, with: Self.fileInfoRows(for: controller).map {
            InspectorRows.row(label: $0.0, value: $0.1, labelWidth: Self.documentLabelWidth)
        })

        let state = controller.documentState
        Self.replace(summaryStack, with: Self.summaryRows(for: state))

        let diagnosis = DocumentOperations.diagnose(
            data: state.data, path: (controller.document as? NSDocument)?.fileURL?.path,
            pixResults: state.pixResults)
        Self.replace(diagnoseStack, with: InspectorRows.rows(for: diagnosis.info, labelWidth: Self.diagnoseLabelWidth))

        resizeToFitContent()
    }

    private static func replace(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views { stack.addArrangedSubview(view) }
    }

    /// Grows or shrinks the panel to exactly fit the DOCUMENT TAB's own content — never
    /// Diagnose's, regardless of which tab is currently showing (job 329's ruling: switching
    /// tabs must never resize the window). Keeps the TOP edge fixed — the window grows
    /// downward, Preview Get-Info's own behaviour, rather than drifting off the top of the
    /// screen the way anchoring at the bottom would.
    private func resizeToFitContent() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        tabHeightConstraint.constant = documentTabStack.fittingSize.height
        window.contentView?.layoutSubtreeIfNeeded()

        let newContentHeight = 16 + tabControl.fittingSize.height + 12 + tabHeightConstraint.constant + 16
        var frame = window.frame
        let delta = newContentHeight - window.contentRect(forFrameRect: frame).height
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: window.isVisible)
    }

    /// The eight Get-Info rows, straight from `PagePreviewRenderer` — the one place that
    /// order is defined — against the document's own `fileURL`. A window with no `document`
    /// (a bare test harness controller, or the moment before `NSDocument` attaches one)
    /// still shows the section, with every row honestly "—" rather than omitting it.
    @MainActor
    private static func fileInfoRows(for controller: DocumentWindowController) -> [(String, String)] {
        guard let url = (controller.document as? NSDocument)?.fileURL else {
            return ["File Name", "Kind", "Size", "Where", "Created", "Modified", "Page Size", "Pages"]
                .map { ($0, "—") }
        }
        let style = controller.documentState.style.value.renderStyle
        return PagePreviewRenderer.info(for: url, style: style, variant: controller.documentState.variant.value)
    }

    /// Job 324's four new fields — word/character counts, declared fonts, note counts, and
    /// resolved margins — all read from `CtrlKD.Document`/`DocumentState`, none of it a new
    /// engine call.
    @MainActor
    private static func summaryRows(for state: DocumentState) -> [NSView] {
        [
            InspectorRows.row(label: "Word Count", value: "\(wordCount(for: state))", labelWidth: documentLabelWidth),
            InspectorRows.row(label: "Character Count", value: "\(characterCount(for: state))", labelWidth: documentLabelWidth),
            InspectorRows.row(label: "Fonts", value: declaredFonts(for: state), labelWidth: documentLabelWidth),
            InspectorRows.row(label: "Notes", value: noteCounts(for: state), labelWidth: documentLabelWidth),
            InspectorRows.row(label: "Margins", value: margins(for: state), labelWidth: documentLabelWidth),
        ]
    }

    /// The same text Copy (`PagedDocumentView.copy(_:)`) and Export both show: `emitText`
    /// under the document's own current `RenderStyle`, the exact call `ExportEngine.render`
    /// makes for a plain-text export of this document right now.
    @MainActor
    private static func documentText(for state: DocumentState) -> String {
        emitText(state.document, mode: state.style.value.renderStyle.emitMode)
    }

    @MainActor
    private static func wordCount(for state: DocumentState) -> Int {
        documentText(for: state).split(whereSeparator: \.isWhitespace).count
    }

    @MainActor
    private static func characterCount(for state: DocumentState) -> Int {
        documentText(for: state).count
    }

    /// The document's own font table (`FontChange.family`, WordStar's 245-entry typestyle
    /// name trimmed to its renderable family, e.g. "Helv"), deduplicated and sorted. Empty
    /// for WS4 files and print streams, which carry no font table — reported honestly as
    /// "—" rather than a made-up default.
    @MainActor
    private static func declaredFonts(for state: DocumentState) -> String {
        let names = Set(state.document.fonts.map { font -> String in
            font.family.isEmpty ? (font.typestyleName ?? "Unnamed") : font.family
        })
        return names.isEmpty ? "—" : names.sorted().joined(separator: ", ")
    }

    /// The four note kinds, zero included — the same `doc.notes` array
    /// `DocumentOperations.diagnose`'s own `notes` field counts, read directly rather than
    /// re-derived from its `InfoValue` tree.
    @MainActor
    private static func noteCounts(for state: DocumentState) -> String {
        let notes = state.document.notes
        func count(_ kind: NoteKind) -> Int { notes.filter { $0.kind == kind }.count }
        return "Footnotes \(count(.footnote)) · Endnotes \(count(.endnote)) · "
            + "Annotations \(count(.annotation)) · Comments \(count(.comment))"
    }

    /// Top/left from `printedMetrics`, the SAME façade `DocumentRenderer.renderPrinted`
    /// (screen) and `ExportEngine.render`'s Printed-mode PDF export already use — resolved
    /// through `effectivePage` against the Margins control's current preset first, exactly
    /// as `renderPrinted` does, so this can never disagree with what the page actually shows.
    /// Bottom comes from the same resolved geometry's `mbLines` (a line count) converted with
    /// `lh48` (WordStar's own 1/48-inch leading unit) — no re-derivation of `printedMetrics`'
    /// internal arithmetic, which the library keeps deliberately private. WordStar has no
    /// right-margin dot command (page width is always 8.5in), so there is no fourth figure to
    /// report.
    @MainActor
    private static func margins(for state: DocumentState) -> String {
        guard let declaredPage = state.document.page else { return "—" }
        let page = state.pageSettingsPreset.value.map { effectivePage(declaredPage, settings: $0.settings) } ?? declaredPage
        var doc = state.document
        doc.page = page
        let metrics = printedMetrics(doc)
        let topIn = metrics.top / 72.0
        let leftIn = metrics.left / 72.0
        let bottomIn = page.mbLines * page.lh48 / 48.0
        return String(format: "Top %.1fin  Bottom %.1fin  Left %.1fin", topIn, bottomIn, leftIn)
    }
}
