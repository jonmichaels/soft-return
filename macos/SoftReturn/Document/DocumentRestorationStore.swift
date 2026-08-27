import AppKit
import Foundation

/// The one sliver of `NSDocumentController` `DocumentRestorationStore` actually needs —
/// narrow enough that a test can fake it without opening a real document or a real window.
/// `@MainActor`: both members it mirrors (`NSDocumentController.documents`/`openDocument`)
/// are main-actor-isolated in AppKit, so the conformance has to be too.
@MainActor
protocol DocumentOpening: AnyObject {
    var documents: [NSDocument] { get }
    func openDocument(withContentsOf url: URL, display: Bool,
                      completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void)
}

extension NSDocumentController: DocumentOpening {}

/// Persists the set of open document URLs at quit and reopens whichever of them the system
/// did not, at the next launch.
///
/// AppKit's own secure state restoration (`NSDocumentController`, unlocked by
/// `applicationSupportsSecureRestorableState` in `AppDelegate`) only fires when the SYSTEM
/// setting "Close windows when quitting applications" (General ▸ Desktop & Dock) is OFF —
/// with it ON, macOS discards saved window state at quit and every app launches clean,
/// regardless of what this app's OWN "Restore windows on launch" preference promises the
/// user. `WindowRestorableState`/`WindowRestorationCoding` are the per-window VIEW state
/// (style, zoom, scroll position) riding on top of that system mechanism — they have nothing
/// to restore if the system never reopens the window at all.
///
/// This store is the fallback that makes the preference true unconditionally: plain file
/// URLs for every open document, written at quit (gated on the SAME preference the
/// window-state gate already reads), and reopened at the next launch — but ONLY when nothing
/// is open yet, so a launch the system itself already restored (or one started with a
/// document on the command line) does not open every document twice.
///
/// Job 392: this used to persist security-scoped bookmarks (sandbox's mechanism for
/// re-reaching a file across a relaunch). Un-sandboxed, a plain URL is enough — this process
/// has ordinary filesystem access, the same as any other app, so there is no scope to start
/// or a bookmark to keep fresh. A document moved or renamed between quit and the next launch
/// simply fails to reopen (the same outcome a bare `Finder alias` would have without help),
/// rather than silently drifting onto whatever a stale bookmark happened to resolve to.
@MainActor
enum DocumentRestorationStore {
    private static let key = "settings.restorableDocumentURLs"

    /// Called at quit. Overwrites the stored list every time, never appends: a document
    /// closed since the last quit must not come back, and turning the preference off must
    /// stop this store from remembering anything at all — the same all-or-nothing gate
    /// `window(_:willEncodeRestorableState:)` applies to the per-window blob.
    static func persist(urls: [URL], settings: SettingsStore, defaults: UserDefaults = .standard) {
        guard settings.restoreWindowsOnLaunch else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(urls.map(\.absoluteString), forKey: key)
    }

    /// Recomputes and persists the full open-document list from `documentController`,
    /// optionally leaving one document out. This is the EAGER half of persistence — called on
    /// every document open and close, not only at quit — because `NSSupportsSuddenTermination`
    /// / `NSSupportsAutomaticTermination` (a deliberate viewer-app choice, see `Info.plist`)
    /// let macOS skip `applicationWillTerminate` on a sudden-termination quit, which is exactly
    /// what left `persist` never called at all on a Cmd-Q.
    ///
    /// `excluding` exists for the close path: at the moment a document must persist the "what
    /// is left open" list, it is still in `documentController.documents` (removal happens
    /// inside `NSDocument.close()`, which has not run yet) — so leaving it out is how the
    /// closing document avoids resurrecting itself next launch.
    static func persistOpenDocuments(excluding: NSDocument? = nil, settings: SettingsStore,
                                     defaults: UserDefaults = .standard,
                                     documentController: any DocumentOpening = NSDocumentController.shared) {
        let urls = documentController.documents
            .filter { $0 !== excluding }
            .compactMap(\.fileURL)
        persist(urls: urls, settings: settings, defaults: defaults)
    }

    /// The URLs currently on record. Never opens a document or touches `NSDocumentController`
    /// — a test can inspect intent without also exercising it.
    static func resolvedURLs(defaults: UserDefaults = .standard) -> [URL] {
        guard let strings = defaults.array(forKey: key) as? [String] else { return [] }
        return strings.compactMap { URL(string: $0) }
    }

    /// Called at launch, after giving the system's own restoration a beat to run (see
    /// `AppDelegate`). Reopens only when the preference is on AND no document is open yet —
    /// the system already restoring (setting OFF) or a document handed in on the command
    /// line both leave nothing for this fallback to do, which is what keeps it from ever
    /// opening the same document twice.
    @MainActor
    static func reopenIfNeeded(settings: SettingsStore, defaults: UserDefaults = .standard,
                               documentController: any DocumentOpening = NSDocumentController.shared) {
        guard settings.restoreWindowsOnLaunch, documentController.documents.isEmpty else { return }
        for url in resolvedURLs(defaults: defaults) {
            documentController.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    NSLog("[SoftReturn] restoration reopen failed for %@: %@",
                          url.path, String(describing: error))
                }
            }
        }
    }
}
