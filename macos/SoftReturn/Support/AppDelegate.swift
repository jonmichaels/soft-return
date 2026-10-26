import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared
import Sparkle

/// The app delegate.
///
/// NOT `@main`. `@main` on an `NSApplicationDelegate` resolves to AppKit's
/// `NSApplicationMain` with NO chance to set `NSApp.delegate` first — it expects the main
/// NIB to instantiate the delegate and wire it to the application. This app has no nib, so
/// under `@main` nothing set `NSApp.delegate`, so none of the callbacks below ever fired —
/// the app launched, appeared in ⌘-Tab, and sat there with a nil `mainMenu`: the app's name
/// in the menu bar, no menus, no key equivalents, not even ⌘Q. It looked like a
/// menu-construction bug and was not one.
///
/// `main.swift` does the wiring explicitly instead: it creates this delegate and assigns it
/// to `NSApplication.shared.delegate` itself, BEFORE calling `NSApplicationMain` (job 148) —
/// so the delegate is already attached by the time `NSApplicationMain` reaches
/// `applicationWillFinishLaunching`. Do not re-add `@main` here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var settingsWindowController: SettingsWindowController?
    var batchWindowController: BatchWindowController?
    var backfillWindowController: SpotlightBackfillWindowController?
    var cliHelpWindowController: CLIHelpWindowController?
    var aboutWindowController: AboutWindowController?

/// v4-assembly (jobs 532+537 merged): LIVE updater with channel policy. Started with
    /// `startingUpdater: !TestHost.isActive` (job 532): a real launch starts Sparkle (its own
    /// documented first-launch automatic-checks permission prompt included); every automated
    /// test-host launch stays network- and alert-silent, since Sparkle's prompt is a real
    /// blocking NSAlert no suite ever clicks through. `updaterDelegate: self` (job 537) wires
    /// `allowedChannelsForUpdater(_:)` so the Option-revealed "Include beta versions"
    /// preference admits channel-tagged beta items; Info.plist carries the real
    /// `SUFeedURL`/`SUPublicEDKey`. `SparkleUpdateWiringTests.swift` asserts this wiring from
    /// inside a test-host launch, where the controller exists but is unstarted.
    var sparkleUpdaterController: SPUStandardUpdaterController?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A document-based viewer is a regular, Dock-showing app. Set explicitly because
        // there is no `NSPrincipalClass`/nib wiring to infer it from. Moved here (job 148)
        // from `main.swift`, which now calls `NSApplicationMain` instead of setting this
        // directly on `NSApplication.shared` before `run()`.
        NSApp.setActivationPolicy(.regular)

        // Job 306 (b18): register the bundled Courier Prime faces (`.process` scope) before
        // any document render can ask `DocumentRenderer`'s Native courier-class mapping to
        // resolve "Courier Prime" — see `CourierPrimeFontRegistration`'s own doc comment.
        CourierPrimeFontRegistration.registerIfNeeded()

        // Cocoa Scripting loads `NSScriptSuiteRegistry` lazily. An Apple Event that arrives
        // before anything has forced that load is not in the dispatch table yet and comes back
        // errAEEventNotHandled (-1708, "doesn't understand the X message"), even though the same
        // event succeeds once the registry is warm — `AppleEventVirginDispatchTests` reproduces
        // exactly this ordering. Touching `.shared()` here closes that window: the registry's own
        // initializer loads the suites of every already-loaded bundle (this app's main bundle
        // among them), so one bare access loads the sdef exactly once. Do not follow it with an
        // explicit `loadSuites(from:)`; that would load the same suite a second time.
        _ = NSScriptSuiteRegistry.shared()

// v4-assembly: started for a real launch, dormant for a test host (job 532); delegate
        // wired for channel policy (job 537). See the property's doc comment.
        sparkleUpdaterController = SPUStandardUpdaterController(
            startingUpdater: !TestHost.isActive,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        suppressSystemEditingMenuItems()
        // Before `didFinishLaunching`, so the menu bar is in place for the first event and
        // AppKit's own submenus (Services, Open Recent) are adopted early enough to fill.
        let menu = MainMenu.build()
        NSApp.mainMenu = menu
        // The rest of the authoring commands are injected later and have no opt-out; they
        // get removed as the menu opens. See EditMenuGuard.
        EditMenuGuard.shared.attach(to: menu)
    }

    /// macOS injects text-AUTHORING commands into any menu titled "Edit", whether the app
    /// asked for them or not: Start Dictation, Emoji & Symbols, Writing Tools, AutoFill.
    /// Every one of them exists to put text INTO a document.
    ///
    /// This app cannot accept text into a document — it is a viewer, and its text views are
    /// `isEditable = false`. Leaving those commands in place offers the user operations that
    /// range from inert to nonsensical, which is worse than not offering them. They are not
    /// removable by omission (we never added them); each has its own opt-out, and they must
    /// be set before the menu bar is built.
    private func suppressSystemEditingMenuItems() {
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Batch 46: Quick Look draws with the app's default quirks, from the app group; keep its copy current.
        QuickLookPageSettingsPreference.keepQuirkDefaultsCurrent()
        #if DEBUG
        // Proof the menu bar actually got installed. A nil or empty `mainMenu` is invisible
        // from outside the process — the app still launches and still appears in ⌘-Tab, it
        // just does nothing — so the fact of it is worth one log line that can be read back
        // with `log show` when the UI is not in front of you.
        let titles = (NSApp.mainMenu?.items ?? []).map { item in
            item.title.isEmpty ? (item.submenu?.title ?? "?") : item.title
        }
        NSLog("[SoftReturn] main menu installed: %d items %@",
              titles.count, titles.joined(separator: "/"))

        // AppKit injects into menus AFTER launch (Open Recent management, the Edit-menu
        // authoring commands). Dump the two menus we care about once that has settled, so a
        // duplicate or an unwanted item is visible from `log show` rather than only on screen.
        Task { @MainActor in
            // `Task.sleep` only throws on cancellation; nothing cancels this task, and even a
            // skipped pause would just log the menu dump early rather than fail anything.
            try? await Task.sleep(for: .seconds(2))
            for name in ["File", "Edit"] {
                guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == name })?.submenu
                else { continue }
                let entries = menu.items.map { item -> String in
                    if item.isSeparatorItem { return "---" }
                    let identifier = item.identifier?.rawValue ?? "nil"
                    let action = item.action.map(NSStringFromSelector) ?? "nil"
                    return "\(item.title)[id=\(identifier) act=\(action)]"
                }
                NSLog("[SoftReturn] %@ menu: %@", name, entries.joined(separator: " | "))
            }
        }
        #endif

        // A document to open, handed over on the command line. This exists for the UI test,
        // which must get a document on screen WITHOUT driving an open panel — the panel is
        // AppKit's and a test that drove it would fail for reasons unrelated to what it
        // checks. Harmless in normal use: nobody passes this argument.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-SoftReturnOpenDocument"),
           flag + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSLog("[SoftReturn] launch-open failed: %@", String(describing: error)) }
            }
        }

        if SettingsStore.shared.startingView == .batchConvert {
            showBatchWindow(nil)
        }

        // "Download → drag to /Applications → launch once" must be enough for Spotlight to
        // find WordStar files that already existed before this app was installed — a user
        // cannot be asked to run `mdimport -r` themselves. Gated to once per build; see
        // `SpotlightNudge`. Not from a test host, whose build path is new on every checkout and whose record would
        // stand for the real app's (planning #572).
        if !TestHost.isActive {
            SpotlightNudge.runIfNeeded()
        }

        // Job 178: drain whatever the QuickLook/Thumbnail extensions queued while this app
        // wasn't running — see `SpotlightIndexQueue.drainAll`'s doc comment. Also drained on
        // `applicationDidBecomeActive` below, since a launch that starts backgrounded (e.g.
        // opened via a document that's still loading) and an already-running app both need a
        // chance to catch up on whatever queued in the meantime.
        SpotlightIndexQueue.drainAll()

        // The fallback half of window restoration (see `DocumentRestorationStore`): give
        // AppKit's own secure state restoration — which runs earlier in the launch sequence,
        // and only when the SYSTEM "Close windows when quitting applications" setting is
        // OFF — a beat to finish opening whatever it is going to open, then reopen anything
        // still missing. `documents.isEmpty` is what stops this from ever running twice: a
        // launch the system already restored, or one started with `-SoftReturnOpenDocument`
        // above, has nothing left for it to do.
        Task { @MainActor in
            // Workaround, kept (reviewed 2026-10-26, macOS 26.7): the second waits for two things that have no
            // shared completion signal — AppKit's restoration, which does (`didFinishRestoringWindowsNotification`),
            // and a document opened as the app launches (from Finder, or `-SoftReturnOpenDocument`), whose
            // `NSDocumentController` open is asynchronous and announces nothing. Reopening on the notification alone
            // would put last session's windows up beside a document the person just double-clicked. Re-test if a
            // launch-time open ever gets a completion the app can wait on. `Task.sleep` only throws on cancellation,
            // which nothing here does.
            try? await Task.sleep(for: .seconds(1))
            // Never under test: a test's windows are the test's own, and the list is the real app's (planning #581).
            guard !TestHost.isActive else { return }
            DocumentRestorationStore.reopenIfNeeded(settings: SettingsStore.shared)
        }

        #if DEBUG
        // Unattended view-tree capture, for the screenshot harness: set
        // SOFT_RETURN_DUMP_VIEW_TREE=<path> and the app dumps once the document it was
        // launched with has finished opening and laying out, then leaves the window up.
        // The delay is deliberate — dumping before layout would record zeroes that mean
        // "too early", not "broken", which is precisely the confusion this tool exists to
        // end.
        if let value = ProcessInfo.processInfo.environment["SOFT_RETURN_DUMP_VIEW_TREE"] {
            // "1" means "wherever you can write", and the app logs the resolved path.
            let destination = (value == "1" || value.isEmpty)
                ? ViewTreeDump.defaultURL()
                : URL(fileURLWithPath: value)
            Task { @MainActor in
                // `Task.sleep` only throws on cancellation; nothing cancels this task.
                try? await Task.sleep(for: .seconds(3))
                let window = NSApp.keyWindow ?? NSApp.windows.first
                ViewTreeDump.write(window: window, to: destination)
                ViewTreeDump.writeRender(window: window)
            }
        }
        #endif
    }

    /// "App opens with just the menu bar, NO file picker" — the spec is explicit. A
    /// one-afternoon user who launches with no document should not be interrogated.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Job 178: the other drain trigger, alongside launch above. `applicationDidBecomeActive`
    /// fires every time this already-running app regains focus — the moment a person is most
    /// likely to have just QuickLooked or thumbnail-browsed a folder of documents in Finder,
    /// i.e. exactly when the extensions' queue is most likely to have something in it worth
    /// draining without waiting for the next full relaunch.
    func applicationDidBecomeActive(_ notification: Notification) {
        SpotlightIndexQueue.drainAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// The write half of `DocumentRestorationStore` — see that type's doc comment for why a
    /// second, app-owned record of "what was open" exists alongside AppKit's own restorable
    /// state at all.
    func applicationWillTerminate(_ notification: Notification) {
        let urls = NSDocumentController.shared.documents.compactMap(\.fileURL)
        DocumentRestorationStore.persist(urls: urls, settings: SettingsStore.shared)
    }
}

// MARK: - SPUUpdaterDelegate (job 537)

extension AppDelegate: SPUUpdaterDelegate {
    /// The channel opt-in (rulings 20-21): all logic lives in `SparkleChannelPolicy`, a pure
    /// function of the one user preference, so it is testable without a real updater. Reads
    /// `SettingsStore.shared` fresh on every call rather than caching, matching Sparkle's own
    /// contract that this may be called more than once per check cycle.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        SparkleChannelPolicy.allowedChannels(includeBetaVersions: SettingsStore.shared.includeBetaVersions)
    }
}
