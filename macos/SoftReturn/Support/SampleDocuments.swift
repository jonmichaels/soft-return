import AppKit
import Foundation
import SoftReturnShared

/// Job 374 (b24, SAMPLES IN-APP): Help ▸ Open Sample Document ▸ — bundled, pristine copies of
/// a handful of authored public-domain WordStar documents, so a person can see the app do
/// something real before ever finding a WordStar file of their own.
///
/// Data-driven, not a fixed list of four: `items()` reads whatever `.WS`-family files are
/// bundled under `SoftReturn/Resources/SampleDocuments/` (see that folder's own README) and
/// titles each by its filename. `pd-samples/authored/*.WS` (the private vault this job's
/// brief names) is Jon's own working set, refreshed by hand from time to time — a refresh is
/// a plain file swap in that bundled folder, never a code change, and zero files bundled is a
/// legitimate state (`buildMenuItem()` returns `nil`, so the submenu is simply absent) rather
/// than an error.
enum SampleDocuments {

    /// One bundled sample, ready to become a menu item. `Equatable` for tests only.
    struct Item: Equatable {
        let title: String
        let url: URL
    }

    /// Every `.WS`-family file bundled under `SampleDocuments/`, title-sorted. The title is
    /// the filename's own stem — WordStar-era manuscript names are already short and mean
    /// something ("PREFACE", "CHAPTER1"), so no separate title metadata is worth maintaining
    /// alongside the files themselves.
    static func items(bundle: Bundle = .main) -> [Item] {
        guard let directory = bundle.url(forResource: "SampleDocuments", withExtension: nil) else {
            return []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter(isWordStarFamily)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Item(title: ($0 as NSString).deletingPathExtension,
                        url: directory.appendingPathComponent($0)) }
    }

    /// The bundled samples carry the claimed extensions; this filters README/asset noise (a `.md`,
    /// a `.DS_Store`) out of the resource folder, not real file identity, which document opening
    /// decides by content.
    private static func isWordStarFamily(_ filename: String) -> Bool {
        WordStarFileTypes.isDocument(name: filename)
    }

    /// `Help ▸ Open Sample Document ▸`, or `nil` when the bundle carries no samples (a build
    /// made before the vault copy lands — see the resource folder's README). Trivially
    /// movable: this is the ONLY call site a caller needs — `MainMenu.helpMenu()` adds the
    /// returned item wherever it likes, or not at all. Deliberately NOT `@MainActor`: plain
    /// `NSMenuItem`/`NSMenu` construction needs no actor hop — see `open()` below for where
    /// this DOES need one (`NSDocumentController`).
    static func buildMenuItem(bundle: Bundle = .main) -> NSMenuItem? {
        let entries = items(bundle: bundle)
        guard !entries.isEmpty else { return nil }

        let item = NSMenuItem(title: "Open Sample Document", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open Sample Document")
        for entry in entries {
            let menuItem = NSMenuItem(
                title: entry.title,
                action: #selector(AppDelegate.openSampleDocument(_:)),
                keyEquivalent: "")
            menuItem.representedObject = entry
            submenu.addItem(menuItem)
        }
        item.submenu = submenu
        return item
    }

    enum OpenError: Error {
        case copyFailed
    }

    /// Copy `item`'s bundled bytes to a fresh temporary file — a new UUID'd directory per
    /// open, so opening the same sample twice (or two samples with the same basename, not
    /// that any currently collide) never collides on disk — then open THAT copy through the
    /// normal document-open path, exactly the call `AppDelegate.openDocument`'s panel-driven
    /// path already makes. The bundled original is never touched, so the app bundle stays
    /// pristine regardless of what a person does to the opened window afterward (Export, a
    /// future edit surface, whatever).
    @MainActor
    static func open(_ item: Item,
                     fileManager: FileManager = .default,
                     documentController: any DocumentOpening = NSDocumentController.shared) {
        do {
            let tempDirectory = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            let tempURL = tempDirectory.appendingPathComponent(item.url.lastPathComponent)
            try fileManager.copyItem(at: item.url, to: tempURL)
            documentController.openDocument(withContentsOf: tempURL, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}
