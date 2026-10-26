import AppKit
import CtrlKD
import os
import SoftReturnShared
import SwiftUI

// MARK: - The window's content

struct BatchView: View {
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
        // The left column is a form that never scrolls, so the minimum height is what it needs:
        // 640 pt, the default. macOS 26 draws its controls taller than macOS 15 (at the old 575 pt
        // minimum the column ran 20 pt past the window), and the Font/Size note wraps to two lines.
        .frame(minWidth: 1040, minHeight: 640)
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
    /// Every pulldown in this window is one length. Job 511 (Jon): "Font is currently the longest. That should be 5
    /// pixels shorter for the extra room the text labels need. Then all the other pulldown menus can be the same
    /// length as Font." That made 185 pt; nothing ties it to the Settings window.
    private static let popupWidth: CGFloat = 185
    /// One width for every label in this column, shared across `detailsBox`'s Grid AND
    /// `optionsBox`'s separate Pictures row, so every pulldown's right edge lines up as one
    /// column no matter which box it lives in — a `Grid` only syncs columns within itself.
    /// Sized to "Pictures:", the longest of the five labels, measured at this form's 13pt
    /// system font (53.3pt via `NSAttributedString.size()`) plus a few points of slack;
    /// `.fixedSize` on each label backs that up so nothing wraps even if a label's measured
    /// width was ever a hair off.
    private static let labelColumnWidth: CGFloat = 58
    /// Job 545 (R3, Jon's ruling): `detailsBox`'s Grid rows (Variant/Style/Font/Size) had
    /// their own, larger, inter-row spacing (10) than `optionsBox`'s rows (6) — one shared
    /// constant now, used by both, so the whole controls column reads at one rhythm.
    private static let rowSpacing: CGFloat = 6

    // Job 518 (N4, Jon verbatim): "get FORMATS and NOTES sections in that left column
    // side-by-side in two columns... shrink the length so that all options in the left
    // column display without a scrollbar." Formats and Notes now share one row (each
    // `.frame(maxWidth: .infinity)`, splitting the row evenly) instead of stacking, which
    // saves the shorter box's own full height — enough that the whole column now fits the
    // window's default 640pt height, so the `ScrollView` this used to need is gone outright
    // rather than merely making the scrollbar rarer.
    private var controlsColumn: some View {
        // Job 521 (N9): tightened from job 518's original 12pt to 8pt, alongside
        // `optionsBox`'s own tightened spacing — measured margin against the real hosted
        // window at the window's declared minimum height (560, then 575, now 640 for macOS 26's taller controls)
        // (see `optionsBox`'s own comment for why this box needed the room).
        //
        // Job 536 (v4.0.0 UI notes, Part A3, Jon's ruling) tried centering this section
        // stack with `.frame(maxHeight: .infinity, alignment: .center)`; job 545 (R3, Jon's
        // ruling from a macOS 26/Tahoe screenshot) found that split the column's slack
        // unevenly on his Mac. `VerticallyCenteringHost` (below) replaces it with a real
        // AppKit `centerYAnchor` constraint, which is unambiguous by construction rather
        // than trusting a SwiftUI frame modifier this headless environment can't visually
        // confirm against Tahoe.
        VerticallyCenteringHost(content:
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
        )
        .frame(maxHeight: .infinity)
    }

    private var detailsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: Self.rowSpacing) {
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
                        Text(BatchWindowController.modeLabel)
                            .frame(width: Self.labelColumnWidth, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                        BatchPopUpButton(
                            titles: ViewStyle.allCases.map { ($0, $0.displayName) },
                            selection: $model.style, width: Self.popupWidth,
                            accessibilityIdentifier: "batch-style-control",
                            accessibilityLabel: "Mode")
                    }
                    // Font and Size are LIVE STATE here, unlike Settings: they grey out
                    // unless Mode is Modern, because neither a literal typescript facsimile
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
                Text(BatchWindowController.fontCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncating when the column is narrower than the line.
                    .fixedSize(horizontal: false, vertical: true)
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
            // Job 536 (Part A3, Jon's ruling): back to 6pt, matching `formatsBox`'s own
            // inter-row spacing — one spacing rhythm across every section in this column now,
            // superseding job 521's tightening (which had traded that match away to fit the
            // Sentence Spacing row within the window's old declared minimum height without a
            // scrollbar; `controlsColumn`'s new vertical centering is what absorbs the extra
            // height this restores). Job 545 (R3): `detailsBox`'s Grid now shares this same
            // `Self.rowSpacing` constant, so Variant/Style/Font/Size read at this rhythm too.
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
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
                        titles: EmitOptions.PixMode.choices.map { ($0, $0.displayName) },
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
                        titles: EmitOptions.PageNumberMode.choices.map { ($0, $0.displayName) },
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
                        titles: EmitOptions.SentenceSpacingMode.choices.map { ($0, $0.displayName) },
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
                Button("Remove") { model.remove(ids: selection); selection = [] }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("batch-remove-button")
                Button("Remove All") { model.removeAll(); selection = [] }
                    .disabled(model.items.isEmpty)
                    .accessibilityIdentifier("batch-remove-all-button")
            }

            // Import controls live together: Browse and Include subfolders adjacent, per
            // the spec's note that they are one thought — on their own row, so the checkbox's
            // title stays on one line.
            HStack {
                Text("Add:")
                Button("Browse…") { browseForFiles() }
                    .accessibilityIdentifier("batch-browse-button")
                Toggle("Include subfolders", isOn: $includeSubfolders)
                    .fixedSize()
                    .accessibilityIdentifier("batch-include-subfolders-checkbox")
                Spacer()
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
        Alert.show(folders.count == 1 ? "Couldn't read a folder" : "Couldn't read \(folders.count) folders",
                   informative: folders.map(\.path).joined(separator: "\n"), in: window)
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
        let formatList = ExportFormat.allCases
            .filter { model.formats.contains($0) }
            .map(\.displayName).joined(separator: ", ")
        let where_ = model.destination?.path ?? "each file’s own folder"
        Alert.show("Export \(model.items.filter(\.isConvertible).count) files?",
                   informative: "Each file keeps its own name and is written to \(where_) as: "
                       + "\(formatList).\n\nExisting files are never overwritten — a number is added "
                       + "instead, the way Finder does it.",
                   buttons: ["Export", "Cancel"], in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                await model.run(progress: {})
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // The providers call back on their own queues, so the list they fill is locked.
        let dropped = OSAllocatedUnfairLock(initialState: [URL]())
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { dropped.withLock { $0.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = dropped.withLock { $0 }
            let result = model.add(urls: urls, includeSubfolders: includeSubfolders)
            reportUnreadableFolders(result.unreadableFolders)
        }
        return true
    }
}
