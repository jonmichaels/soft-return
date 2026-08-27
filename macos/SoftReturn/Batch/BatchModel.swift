import AppKit
import CtrlKD

/// One row in the batch list.
///
/// Status carries THREE signals in the UI, never colour alone (accessibility,
/// non-negotiable): a shape (hollow ring / spinner / filled disc / cross / dash), a colour,
/// and the status TEXT. `statusText` and `symbolName` below are two of those three; the
/// colour is the third, applied by the cell.
struct BatchItem: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case converting
        case done
        case failed(reason: String)
        case skipped(reason: String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .pending

    /// Whether this file is something the library can convert at all. Non-convertibles are
    /// listed but greyed and unselectable — the spec wants ALL files shown, so a user can
    /// see that the app noticed the file and decided, rather than wondering where it went.
    let isConvertible: Bool

    var name: String { url.lastPathComponent }

    /// "No extension" is spelled out in full, never abbreviated — the spec is explicit.
    var typeDescription: String {
        let ext = url.pathExtension
        return ext.isEmpty ? "No extension" : ext.uppercased()
    }

    var statusText: String {
        switch status {
        case .pending:              return "Pending"
        case .converting:           return "Converting…"
        case .done:                 return "Done"
        case .failed(let reason):   return "Failed: \(reason)"
        case .skipped(let reason):  return "Skipped: \(reason)"
        }
    }

    /// The shape signal.
    var symbolName: String {
        switch status {
        case .pending:    return "circle"
        case .converting: return "arrow.triangle.2.circlepath"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        case .skipped:    return "minus.circle"
        }
    }

    /// The colour signal.
    var symbolColor: NSColor {
        switch status {
        case .pending:    return .tertiaryLabelColor
        case .converting: return .controlAccentColor
        case .done:       return .systemGreen
        case .failed:     return .systemRed
        case .skipped:    return .secondaryLabelColor
        }
    }
}

/// The batch window's state: what is queued, what settings apply, and the run itself.
///
/// `ObservableObject`/`@Published` (Combine), not the `Observation` framework's `@Observable`
/// macro — `@Observable` requires macOS 14 (`Observable()`/`ObservationTracked()` are marked
/// `@available(macOS 14, *)` in the SDK), and this window's SwiftUI form (`BatchWindowController
/// .BatchView`, `@ObservedObject`/`$model.*` bindings below) is a real, advertised feature that
/// must keep working at the app's macOS 13.0 floor (job 342 ruling) — not something to gate
/// away or delete. `ObservableObject` has shipped since macOS 10.15 and drives the exact same
/// `$model.property` binding syntax, so this is a same-behavior swap, not a fallback.
@MainActor
final class BatchModel: ObservableObject {
    @Published private(set) var items: [BatchItem] = []
    @Published var selectedItemID: BatchItem.ID?

    // Conversion settings — the controls column.
    @Published var variant: Variant?          // nil == Auto
    /// Job 323 (b20 item 3): the SAME three-case pulldown vocabulary the Export As sheet's
    /// Style control gained (Native/Printed/Modern, `ViewStyle` — not the export-only
    /// two-case `RenderStyle`). Defaults to Settings' own Default Style: batch has no single
    /// open window to read a "current view" off of, so the app's own live default — what a
    /// freshly opened window would show right now — is the closest honest analog to the
    /// Export As sheet's "defaults to the exporting window's current view style" rule.
    @Published var style: ViewStyle = SettingsStore.shared.defaultStyle
    @Published var fontName: String = SettingsStore.shared.modernFontName
    @Published var fontSize: Int = SettingsStore.shared.modernFontSize
    @Published var formats: Set<ExportFormat> = SettingsStore.shared.defaultExportFormats
    @Published var notes = NoteSelection()
    /// Job 375 item C4 (b24 completion): the same four Options-column controls the Export As
    /// sheet gained in job 373 (`ExportAccessoryView`'s own `selectedHeaders`/`selectedTOC`/
    /// `selectedInlineStyling`/`selectedPictures`) — Batch previously read `ExportEngine
    /// .render`'s own Settings-backed PARAMETER DEFAULTS silently, with no way to override
    /// them for one run. Initialized from `SettingsStore.shared` exactly like `style`/
    /// `fontName`/`fontSize`/`formats` above; a per-run change here is plain `@Published`
    /// state, never written back to Settings — the same "initializes from, never writes
    /// back to" rule those four already follow.
    @Published var headers: Bool = SettingsStore.shared.defaultHeaders
    @Published var toc: Bool = SettingsStore.shared.defaultTOC
    @Published var inlineStyling: Bool = SettingsStore.shared.defaultInlineStyling
    @Published var pictures: EmitOptions.PixMode = SettingsStore.shared.defaultPictures
    /// Job 520 (N5, b33 page-numbering UI): the same "initializes from Settings, never
    /// writes back" pattern as `headers`/`toc`/`inlineStyling`/`pictures` above.
    @Published var pageNumbers: EmitOptions.PageNumberMode = SettingsStore.shared.defaultPageNumbers
    /// Job 521 (N9, b33 sentence-spacing UI): unlike every other Options-column property
    /// above, this one is NOT Settings-backed — Jon's ruling scopes Sentence Spacing to the
    /// export surfaces and AppleScript only, with no Settings item, so this always starts at
    /// the plain literal `.auto` rather than reading `SettingsStore.shared`.
    @Published var sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    /// nil == "Same as source", the spec's default. There is deliberately no Settings entry
    /// for this — it was ruled out.
    @Published private(set) var destination: URL?

    @Published private(set) var isRunning = false
    @Published private(set) var convertedCount = 0
    @Published private(set) var failedCount = 0

    /// Extensions worth trying. A file with NO extension is always worth trying — that is
    /// the normal shape of a 1987 floppy's contents.
    private static let convertibleExtensions: Set<String> = [
        "ws", "ws1", "ws2", "ws3", "ws4", "ws5", "ws6", "ws7", "ws8", "ws9",
        "txt", "doc", "asc", "prn",
    ]

    var selectedItem: BatchItem? {
        items.first { $0.id == selectedItemID }
    }

    /// `nil` clears back to "Same as Source" (the reset button).
    func setDestination(_ url: URL?) {
        destination = url
    }

    /// The summary line under the list: "38 converted, 2 failed".
    var summaryText: String {
        guard convertedCount > 0 || failedCount > 0 else {
            let count = items.count
            return count == 1 ? "1 file" : "\(count) files"
        }
        var parts = ["\(convertedCount) converted"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Building the list

    /// Job 220 (finding C): `add(urls:includeSubfolders:)` used to return just a count, so a
    /// folder that couldn't be enumerated at all (permission denied, vanished mid-drag) added
    /// zero rows with nothing telling the user why — indistinguishable from "an empty
    /// folder", the exact silent-nothing failure mode finding C exists to close. A single
    /// stray entry failing `resourceValues` mid-walk stays best-effort (that one entry is
    /// skipped, not the whole folder) — only "the folder itself couldn't be listed" is
    /// reported back.
    struct AddResult: Equatable {
        var added = 0
        var unreadableFolders: [URL] = []
    }

    /// Add files and folders. A folder contributes its FIRST LEVEL only unless
    /// `includeSubfolders`, matching the spec's drop behaviour.
    @discardableResult
    func add(urls: [URL], includeSubfolders: Bool) -> AddResult {
        var result = AddResult()
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                let (added, readable) = addFolder(url, includeSubfolders: includeSubfolders)
                result.added += added
                if !readable { result.unreadableFolders.append(url) }
            } else {
                if appendFile(url) { result.added += 1 }
            }
        }
        return result
    }

    private func addFolder(_ folder: URL, includeSubfolders: Bool) -> (added: Int, readable: Bool) {
        let manager = FileManager.default
        var added = 0
        if includeSubfolders {
            guard let walker = manager.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return (0, false) }
            for case let url as URL in walker {
                // Best-effort: one entry racing out from under the walk (rare — deleted or
                // renamed mid-enumeration) is skipped, not treated as the folder being
                // unreadable.
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    if appendFile(url) { added += 1 }
                }
            }
            return (added, true)
        } else {
            let contents: [URL]
            do {
                contents = try manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
            } catch {
                return (0, false)
            }
            for url in contents {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    if appendFile(url) { added += 1 }
                }
            }
            return (added, true)
        }
    }

    /// Returns false if the file was already listed — re-dropping a folder should not
    /// double every row.
    private func appendFile(_ url: URL) -> Bool {
        guard !items.contains(where: { $0.url == url }) else { return false }
        let ext = url.pathExtension.lowercased()
        let convertible = ext.isEmpty || Self.convertibleExtensions.contains(ext)
        var item = BatchItem(url: url, isConvertible: convertible)
        if !convertible { item.status = .skipped(reason: "Not convertible") }
        items.append(item)
        return true
    }

    func remove(ids: Set<BatchItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    func removeAll() {
        items.removeAll()
        convertedCount = 0
        failedCount = 0
    }

    // MARK: - Running

    /// Convert every convertible row, one at a time, updating status as it goes.
    ///
    /// Sequential is a deliberate choice for this milestone, not a limitation to apologise
    /// for: the status column is the product here — a user watching thirty files go by
    /// wants to see which one is being worked on, and parallel conversion would turn that
    /// into a flicker of simultaneous spinners for a saving nobody asked for.
    ///
    /// Job 392: un-sandboxed, "Same as Source" just writes beside `item.url` — this process
    /// has ordinary filesystem access to any file it could read in the first place, so there
    /// is no per-file-vs-per-folder grant distinction left to track, and no fallback-folder
    /// prompt needed for a row this can't legally reach (job 221's whole reason for existing).
    @MainActor
    func run(progress: @escaping () -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        convertedCount = 0
        failedCount = 0
        defer { isRunning = false }

        for index in items.indices {
            guard items[index].isConvertible else { continue }
            items[index].status = .converting
            progress()
            // Yield so the row's spinner actually appears before the work blocks the main
            // actor — without this the whole run paints once, at the end.
            await Task.yield()

            do {
                try convertOne(items[index])
                items[index].status = .done
                convertedCount += 1
            } catch {
                items[index].status = .failed(reason: Self.shortReason(error))
                failedCount += 1
            }
            progress()
            await Task.yield()
        }
    }

    private func convertOne(_ item: BatchItem) throws {
        let data = try Data(contentsOf: item.url)
        let bytes = [UInt8](data)
        let state = try DocumentState(data: bytes, settings: .shared, docPath: item.url.path)
        // Job 220 (finding C): a failed forced re-parse used to be discarded here, leaving
        // `state.document` on its auto-detected parse while the row still went on to render
        // and land as `.done` — reporting success for a file exported under a DIFFERENT
        // variant than the one the user forced for the whole batch. Throwing routes it
        // through the same `.failed(reason:)` path every other per-item failure already
        // takes (see `run(progress:)`'s catch), instead of silently exporting the wrong thing.
        if let variant, let error = state.setVariant(variant) { throw error }
        state.modernFontName = fontName
        state.modernFontSize = fontSize

        let basename = item.url.deletingPathExtension().lastPathComponent
        // `viewStyle` (job 313A, revised job 323): the batch window's OWN Style pulldown is
        // now the same three-case control the Export As sheet's is — an explicit choice for
        // the whole batch, not each item's own individually-seeded default — so it reaches
        // `ExportEngine.render` directly, the same "the chosen pulldown value, not the
        // ambient default" rule job 323 applies to the single-document sheet. An item never
        // opened as a window has no "current view" of its own to defer to; the batch control
        // IS that choice here.
        let products = try ExportEngine.render(
            document: state.document, state: state,
            formats: ExportFormat.allCases.filter { formats.contains($0) },
            notes: notes, style: style.renderStyle, viewStyle: style, title: basename,
            docPath: item.url.path,
            headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
            pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)

        // An explicit destination (the Choose… panel) always wins, exactly as before.
        if let destination {
            try ExportEngine.write(products, to: destination, basename: basename)
            return
        }

        // Same as Source: a plain write beside `item.url`.
        let directory = item.url.deletingLastPathComponent()
        try ExportEngine.write(products, to: directory, basename: basename)
    }

    /// A status cell has room for a phrase, not a stack trace.
    private static func shortReason(_ error: Error) -> String {
        if case ParseError.notConvertible = error { return "Not a readable document" }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoPermission {
            return "No permission to read"
        }
        return (error as NSError).localizedFailureReason ?? "Couldn’t convert"
    }
}
