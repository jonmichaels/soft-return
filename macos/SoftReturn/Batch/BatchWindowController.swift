import AppKit
import CtrlKD
import SwiftUI

/// The Batch Export window (⌥⌘E).
///
/// SwiftUI content in an AppKit window: the three-column layout, the form and the file
/// table are exactly what SwiftUI is good at, and the parts that must be system components
/// — the folder picker, the open panel, the save sheet — are real AppKit panels called from
/// the view, not drawn by it.
///
/// Job 528 (b34 intake N2, Jon's ruling — "That's the Settings window from Soft Return. That
/// one is correct. Have the worker do it the same way."): the controls column's seven
/// pulldowns (Variant/Style/Font/Size/Pictures/Page #/Spacing) were a SwiftUI `Picker` wrapped
/// in `.frame(width:)` — a width SwiftUI's own private macOS Picker backing silently ignores
/// outside a headless test host, sizing to its widest menu item and floating centered in the
/// slot instead (the root cause of jobs 511/518/522 never reproducing what Jon actually saw).
/// `BatchPopUpButton` below is the fix: a real `NSPopUpButton`, exactly the way
/// `SettingsWindowController.popup(_:_:_:_:)` builds its own —
/// `translatesAutoresizingMaskIntoConstraints = false` plus a hard `widthAnchor` constraint on
/// the CONTROL ITSELF, which AutoLayout enforces regardless of session — bridged into this
/// SwiftUI column via `NSViewRepresentable` rather than hoisting the whole column to AppKit,
/// the smaller diff of the two options the brief allowed.
final class BatchWindowController: NSWindowController {
    private let model = BatchModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Batch Export"
        window.setAccessibilityIdentifier("batch-window")
        // Job 397 (Jon F9): `setFrameAutosaveName` alone only SAVES future moves/resizes — it
        // does not restore a prior frame, so the very first open (and any host with no saved
        // defaults) fell straight through to the literal (0, 0) screen-origin `contentRect`
        // above, the bottom-left-corner spawn bug. `setFrameUsingName` restores that saved
        // frame if one exists; `center()` (matching the Check for Updates `NSAlert`'s own
        // upper-third placement) is the fallback the first time there's nothing to restore.
        window.setFrameAutosaveName("BatchWindow")
        if !window.setFrameUsingName("BatchWindow") {
            window.center()
        }
        super.init(window: window)

        let root = BatchView(model: model, window: window)
        window.contentView = NSHostingView(rootView: root)
        window.registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - A real NSPopUpButton, bridged into the SwiftUI column

/// Job 528: the SETTINGS way, bridged rather than hoisted — see the class doc comment above.
/// `titles` pairs each pulldown item's underlying value with its display string, in menu
/// order; `selection` is a plain `Binding` to the bound `@Published` model property, the same
/// contract a `Picker`'s own `selection:` argument offers. The width constraint lives on the
/// `NSPopUpButton` itself, never on a SwiftUI `.frame(width:)` wrapping it — that is the one
/// property this type exists to guarantee.
private struct BatchPopUpButton<Tag: Hashable>: NSViewRepresentable {
    let titles: [(Tag, String)]
    @Binding var selection: Tag
    let width: CGFloat
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles.map(\.1))
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        // The fix, in one line: a hard width constraint on the CONTROL, not an ignorable
        // frame offered to a SwiftUI wrapper around it. See the class doc comment.
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if let index = titles.firstIndex(where: { $0.0 == selection }),
           button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        // SwiftUI's `.disabled(_:)` sets `\.isEnabled` in the environment; it does not reach
        // across the `NSViewRepresentable` boundary on its own the way it would for a native
        // SwiftUI control, so Font/Size's grey-out (`model.style != .modern`) has to be
        // applied by hand here, same as every other `updateNSView` bridging a stateful AppKit
        // control.
        button.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: BatchPopUpButton
        init(_ parent: BatchPopUpButton) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let tag = parent.titles[safe: sender.indexOfSelectedItem]?.0 else { return }
            parent.selection = tag
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - The window's content

private struct BatchView: View {
    @ObservedObject var model: BatchModel
    let window: NSWindow

    @State private var includeSubfolders = false
    @State private var selection = Set<BatchItem.ID>()
    @State private var isTargetedForDrop = false

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
                .frame(width: 300)
            Divider()
            previewColumn
                .frame(width: 300)
                .padding(16)
            Divider()
            fileListColumn
                .padding(16)
                // The list is the column that should absorb extra width — the other two are
                // a form and a fixed-aspect page, and neither improves by being wider.
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Controls

    /// The controls column is boxed `GroupBox`es, not `Form`/`Section` — `Form`'s grouped
    /// style is a `List` under the hood, and a `List` on macOS insists on its own row
    /// separators and inter-section spacing (`listSectionSpacing` is flatly unavailable on
    /// macOS). Jon's ruling wants rows sitting close together with NO separators inside a
    /// box that stays — the opposite of what `List` defaults to — so a `Grid` for the
    /// label/control alignment (the SwiftUI counterpart of the `NSGridView` Settings uses)
    /// inside a plain `VStack` gives that directly, with no fighting a list style for
    /// something it was never going to offer.
    ///
    /// Pulldowns in this form match the Settings window's popup width — one form idiom
    /// shared by both windows, per ruling.
    ///
    /// Job 511 (Jon, verbatim): "Font is currently the longest. That should be 5 pixels
    /// shorter for the extra room the text labels need. Then all the other pulldown menus can
    /// be the same length as Font." Settings' own 190pt is untouched — only Batch's copy
    /// takes the 5pt off. Job 528 keeps this exact value (185, not unified to 190) — it is
    /// still the number every `BatchPopUpButton` below pins its `widthAnchor` to, so the
    /// job 511 ruling stays honest under the rebuild, not just under the old SwiftUI frame.
    private static let popupWidth = SettingsWindowController.popupWidth - 5
    /// One width for every label in this column, shared across `detailsBox`'s Grid AND
    /// `optionsBox`'s separate Pictures row, so every pulldown's right edge lines up as one
    /// column no matter which box it lives in — a `Grid` only syncs columns within itself.
    /// Sized to "Pictures:", the longest of the five labels, measured at this form's 13pt
    /// system font (53.3pt via `NSAttributedString.size()`) plus a few points of slack;
    /// `.fixedSize` on each label backs that up so nothing wraps even if a label's measured
    /// width was ever a hair off.
    private static let labelColumnWidth: CGFloat = 58

    // Job 518 (N4, Jon verbatim): "get FORMATS and NOTES sections in that left column
    // side-by-side in two columns... shrink the length so that all options in the left
    // column display without a scrollbar." Formats and Notes now share one row (each
    // `.frame(maxWidth: .infinity)`, splitting the row evenly) instead of stacking, which
    // saves the shorter box's own full height — enough that the whole column now fits the
    // window's default 620pt height, so the `ScrollView` this used to need is gone outright
    // rather than merely making the scrollbar rarer.
    private var controlsColumn: some View {
        // Job 521 (N9): tightened from job 518's original 12pt to 8pt, alongside
        // `optionsBox`'s own tightened spacing — measured margin against the real hosted
        // window at the window's declared 560pt minimum height (see `optionsBox`'s own
        // comment for why this box needed the room).
        VStack(alignment: .leading, spacing: 8) {
            detailsBox
            HStack(alignment: .top, spacing: 12) {
                formatsBox
                notesBox
            }
            optionsBox
            destinationBox
        }
        .padding(16)
    }

    private var detailsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text("Variant:")
                            .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                        BatchPopUpButton(
                            titles: [
                                (Variant?.none, "Auto"),
                                (Variant?.some(.ws4), "WordStar 4"),
                                (Variant?.some(.ws5plus), "WordStar 5+"),
                                (Variant?.some(.printstream), "Print Stream"),
                                (Variant?.some(.text), "Plain Text"),
                            ],
                            selection: $model.variant, width: Self.popupWidth,
                            accessibilityIdentifier: "batch-variant-control",
                            accessibilityLabel: "Variant")
                    }
                    GridRow {
                        Text("Style:")
                            .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                        BatchPopUpButton(
                            titles: ViewStyle.allCases.map { ($0, $0.displayName) },
                            selection: $model.style, width: Self.popupWidth,
                            accessibilityIdentifier: "batch-style-control",
                            accessibilityLabel: "Style")
                    }
                    // Font and Size are LIVE STATE here, unlike Settings: they grey out
                    // unless Style is Modern, because neither a literal typescript facsimile
                    // (Printed) nor the Mac-mapped facsimile (Native) has a font for the user
                    // to choose — only Modern's reflow uses `fontName`/`fontSize` at all. The
                    // spec draws the Printed distinction explicitly; Native shares its reason
                    // (job 323, extending job 265's Native/Printed split to this control).
                    GridRow {
                        Text("Font:")
                            .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                        BatchPopUpButton(
                            titles: NSFontManager.shared.availableFontFamilies.sorted().map { ($0, $0) },
                            selection: $model.fontName, width: Self.popupWidth,
                            accessibilityIdentifier: "batch-font-control",
                            accessibilityLabel: "Font")
                        .disabled(model.style != .modern)
                    }
                    GridRow {
                        Text("Size:")
                            .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                        BatchPopUpButton(
                            titles: SettingsStore.fontSizes.map { ($0, "\($0)") },
                            selection: $model.fontSize, width: Self.popupWidth,
                            accessibilityIdentifier: "batch-font-size-control",
                            accessibilityLabel: "Size")
                        .disabled(model.style != .modern)
                    }
                }
                Text("Font and size apply to Modern style — RTF and PDF exports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("batch-font-caption")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formatsBox: some View {
        GroupBox("Formats") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Toggle(format.displayName, isOn: Binding(
                        get: { model.formats.contains(format) },
                        set: { on in
                            if on { model.formats.insert(format) } else { model.formats.remove(format) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-format-\(format.rawValue)-checkbox")
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var notesBox: some View {
        GroupBox("Notes") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Footnotes", isOn: $model.notes.footnotes)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-notes-footnotes-checkbox")
                Toggle("Endnotes", isOn: $model.notes.endnotes)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-notes-endnotes-checkbox")
                Toggle("Annotations", isOn: $model.notes.annotations)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-notes-annotations-checkbox")
                Toggle("Comments", isOn: $model.notes.comments)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-notes-comments-checkbox")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// Job 375 item C4 (b24 completion): the same Options column `ExportAccessoryView` (the
    /// Export As sheet's own accessory) gained in job 373 — identical labels and identical
    /// enable-disable rules (that view's own `updateOptionAvailability` doc comment: Headers/
    /// Footers is paged-formats-only (RTF/PDF), Inline Styling is RTF/HTML-only, Pictures is
    /// every format but plain text, Table of Contents/Index applies to all five). A disabled
    /// control here keeps its last value rather than resetting, same as the sheet's own
    /// `NSButton.isEnabled` (SwiftUI's `.disabled` has the identical "keeps state" behavior
    /// for a `Toggle`/`Picker` bound to persistent `@Published` state).
    private var optionsBox: some View {
        GroupBox("Options") {
            // Job 521 (N9): tightened from job 375's original 6pt to fit the Sentence
            // Spacing row this job adds within the window's declared 560pt minimum height
            // (Jon, same wording as job 518's own ask: "shrink the length so that all
            // options in the left column display without a scrollbar") — measured against
            // the real hosted window (`Job518BatchLayoutTests
            // .leftColumnContentFitsWithoutScrollingAtMinimumWindowSize`), not guessed.
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Headers/Footers", isOn: $model.headers)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-headers-checkbox")
                    .disabled(!(model.formats.contains(.rtf) || model.formats.contains(.pdf)))
                Toggle("Table of Contents", isOn: $model.toc)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-toc-checkbox")
                Toggle("Inline Styling", isOn: $model.inlineStyling)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("batch-inline-styling-checkbox")
                    .disabled(!(model.formats.contains(.rtf) || model.formats.contains(.html)))
                HStack(spacing: 8) {
                    Text("Pictures:")
                        .frame(width: Self.labelColumnWidth, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                    BatchPopUpButton(
                        titles: [
                            (EmitOptions.PixMode.off, "Off"),
                            (EmitOptions.PixMode.embed, "Embed"),
                            (EmitOptions.PixMode.export, "Export"),
                        ],
                        selection: $model.pictures, width: Self.popupWidth,
                        accessibilityIdentifier: "batch-pictures-popup",
                        accessibilityLabel: "Pictures")
                }
                // Job 518 (N3 hardening): `.fixedSize` on the whole row, not just its two
                // children individually — an HStack (unlike detailsBox's `Grid`) has no column
                // system of its own to hold a shared width steady, so if EITHER the row or a
                // narrowed ancestor (a legacy, width-reserving scrollbar; a user-shrunk window)
                // ever squeezes it, the row must refuse to compress rather than silently drift
                // off the label+popup column the other four pulldowns (`detailsBox`'s Grid,
                // hardened the same way above) share.
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.formats.isEmpty || model.formats == [.text])
                // Job 520 (N5, b33 page-numbering UI): same row pattern as Pictures directly
                // above — label + right-aligned pulldown, same shared label/popup widths, same
                // `.fixedSize` hardening. Same paged-formats-only (RTF/PDF) enable rule as
                // Headers/Footers, per `SoftReturn.sdef`'s own `page numbers` parameter.
                HStack(spacing: 8) {
                    Text("Page #:")
                        .frame(width: Self.labelColumnWidth, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                    BatchPopUpButton(
                        titles: [
                            (EmitOptions.PageNumberMode.auto, "Auto"),
                            (EmitOptions.PageNumberMode.on, "On"),
                            (EmitOptions.PageNumberMode.off, "Off"),
                        ],
                        selection: $model.pageNumbers, width: Self.popupWidth,
                        accessibilityIdentifier: "batch-page-numbers-popup",
                        accessibilityLabel: "Page Numbering")
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!(model.formats.contains(.rtf) || model.formats.contains(.pdf)))
                // Job 521 (N9, b33 sentence-spacing UI): same row pattern as Page Numbering
                // directly above, but never `.disabled` — per `EmitOptions.sentenceSpacing`'s
                // own doc comment this applies to every format, not paged-formats-only, and
                // per Jon's ruling there is no Settings item behind it (see `BatchModel
                // .sentenceSpacing`'s own doc comment).
                HStack(spacing: 8) {
                    Text("Spacing:")
                        .frame(width: Self.labelColumnWidth, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                    BatchPopUpButton(
                        titles: [
                            (EmitOptions.SentenceSpacingMode.auto, "Auto"),
                            (EmitOptions.SentenceSpacingMode.keep, "Keep as typed"),
                            (EmitOptions.SentenceSpacingMode.single, "Single space"),
                        ],
                        selection: $model.sentenceSpacing, width: Self.popupWidth,
                        accessibilityIdentifier: "batch-sentence-spacing-popup",
                        accessibilityLabel: "Sentence Spacing")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationBox: some View {
        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 8) {
                // "Same as source" is the default and needs no control of its own — the
                // spec ruled out a batch-destination setting, so this is per-run state.
                LabeledContent("Write to:") {
                    Text(model.destination?.lastPathComponent ?? "Same as source")
                        .foregroundStyle(model.destination == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.destination?.path ?? "Each file is written beside its source.")
                }
                HStack {
                    Button("Choose…") { chooseDestination() }
                        .accessibilityIdentifier("batch-destination-button")
                    // Always present, never appearing/disappearing — just greyed out when
                    // there is nothing to reset, per ruling.
                    Button("Same as Source") { model.setDestination(nil) }
                        .disabled(model.destination == nil)
                        .accessibilityIdentifier("batch-destination-reset-button")
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .center, spacing: 12) {
            if let item = model.items.first(where: { selection.contains($0.id) }) ?? model.items.first {
                BatchPreview(item: item, style: model.style, variant: model.variant)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .overlay {
                        Text("No file selected")
                            .foregroundStyle(.secondary)
                    }
                    // Job 511 (2a): the column has room for a bigger page than 240pt tall was
                    // using — 400pt lets a US Letter page (8.5:11) reach this column's full
                    // ~300pt width instead of sitting well short of it.
                    .frame(maxHeight: 400)
            }
            Spacer()
        }
        // Job 511 (2a): centered, not leading — both the preview and the info block below it
        // read as one object sitting in the middle of the column.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: File list

    private var fileListColumn: some View {
        VStack(spacing: 10) {
            Table(model.items, selection: $selection) {
                TableColumn("Name") { item in
                    Text(item.name)
                        .foregroundStyle(item.isConvertible ? .primary : .secondary)
                }
                TableColumn("Type") { item in
                    Text(item.typeDescription)
                        .foregroundStyle(item.isConvertible ? .primary : .secondary)
                }
                TableColumn("Status") { item in
                    // Left-justified status text, per the spec.
                    Text(item.statusText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TableColumn("") { item in
                    Image(systemName: item.symbolName)
                        .foregroundStyle(Color(nsColor: item.symbolColor))
                        .accessibilityLabel(item.statusText)
                }
                .width(24)
            }
            .accessibilityIdentifier("batch-file-list")

            HStack {
                Text(model.summaryText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("batch-summary")
                Spacer()
            }

            // Import controls live together: Browse and Include subfolders adjacent, per
            // the spec's note that they are one thought.
            HStack {
                Text("Add:")
                Button("Browse…") { browseForFiles() }
                    .accessibilityIdentifier("batch-browse-button")
                Toggle("Include subfolders", isOn: $includeSubfolders)
                    .accessibilityIdentifier("batch-include-subfolders-checkbox")
                Spacer()
                Button("Remove") { model.remove(ids: selection); selection = [] }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("batch-remove-button")
                Button("Remove All") { model.removeAll(); selection = [] }
                    .disabled(model.items.isEmpty)
                    .accessibilityIdentifier("batch-remove-all-button")
            }

            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Export") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.items.isEmpty || model.formats.isEmpty || model.isRunning)
                    .accessibilityIdentifier("batch-export-button")
            }
        }
    }

    // MARK: Panels — all real AppKit

    private func browseForFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.setAccessibilityIdentifier("batch-open-panel")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let result = model.add(urls: panel.urls, includeSubfolders: includeSubfolders)
            reportUnreadableFolders(result.unreadableFolders)
        }
    }

    /// Job 220 (finding C): a folder `add(urls:)` couldn't even list used to add zero rows
    /// with nothing telling the user why — indistinguishable from "an empty folder".
    private func reportUnreadableFolders(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = folders.count == 1
            ? "Couldn't read a folder"
            : "Couldn't read \(folders.count) folders"
        alert.informativeText = folders.map(\.path).joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.setAccessibilityIdentifier("batch-destination-panel")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            model.setDestination(panel.url)
        }
    }

    /// Export opens a save sheet confirming the destination — rows keep their own
    /// basenames, and the multi-format fan-out is spelled out so nobody is surprised by
    /// three files per source.
    private func startExport() {
        let sheet = NSAlert()
        sheet.messageText = "Export \(model.items.filter(\.isConvertible).count) files?"
        let formatList = ExportFormat.allCases
            .filter { model.formats.contains($0) }
            .map(\.displayName).joined(separator: ", ")
        let where_ = model.destination?.path ?? "each file’s own folder"
        sheet.informativeText = "Each file keeps its own name and is written to \(where_) as: "
            + "\(formatList).\n\nExisting files are never overwritten — a number is added "
            + "instead, the way Finder does it."
        sheet.addButton(withTitle: "Export")
        sheet.addButton(withTitle: "Cancel")
        sheet.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                await model.run(progress: {})
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let result = model.add(urls: urls, includeSubfolders: includeSubfolders)
            reportUnreadableFolders(result.unreadableFolders)
        }
        return true
    }
}

// MARK: - Preview pane

/// A tiny full page of the selected file, in the chosen style, plus the Get-Info-style
/// panel underneath.
private struct BatchPreview: View {
    let item: BatchItem
    let style: ViewStyle
    let variant: Variant?

    /// Native and Printed render IDENTICAL pixels for this thumbnail purpose — the on-screen
    /// difference between them is only in how a PDF EXPORT's bytes get produced
    /// (`ExportEngine`'s print-path carve-out), never in `PagePreviewRenderer`'s own facsimile
    /// layout, so both map to `RenderStyle.printed` here exactly as `ViewStyle.renderStyle`
    /// already documents for "export what you see" (job 265/323).
    private var previewStyle: RenderStyle { style.renderStyle }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if let image = PagePreviewRenderer.firstPage(of: item.url, style: previewStyle, variant: variant) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .border(Color(nsColor: .separatorColor))
                    // Job 511 (2a): see `previewColumn` — 400pt lets this reach the column's
                    // full width instead of the old 240pt cap leaving most of it empty.
                    .frame(maxHeight: 400)
                    .accessibilityIdentifier("batch-preview-page")
                    .accessibilityLabel("Preview of \(item.name)")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .overlay { Text("No preview").foregroundStyle(.secondary) }
                    .frame(maxHeight: 400)
            }

            // Get-Info-style panel: the spec fixes these rows and their order. Job 511 (2a):
            // centered as a block under the (now full-width) preview above, rather than
            // pinned to the leading edge — the Grid's own label/value columns stay
            // trailing/leading relative to EACH OTHER, only the whole block moves.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(PagePreviewRenderer.info(for: item.url, style: previewStyle, variant: variant), id: \.0) { row in
                    GridRow {
                        Text(row.0 + ":")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
            .accessibilityIdentifier("batch-info-panel")
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
