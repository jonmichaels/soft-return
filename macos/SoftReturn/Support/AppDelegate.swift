import AppKit
import CtrlKD
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
    private var settingsWindowController: SettingsWindowController?
    private var batchWindowController: BatchWindowController?
    private var backfillWindowController: SpotlightBackfillWindowController?
    private var cliHelpWindowController: CLIHelpWindowController?
    private var downloadProgressWindowController: DownloadProgressWindowController?
    private var aboutWindowController: AboutWindowController?

    /// Job 532 (Jon's ruling: Sparkle IS in b34) — live: `Info.plist` carries a real
    /// `SUFeedURL`/`SUPublicEDKey` (see that file's own comment) and `checkForUpdates(_:)`
    /// below forwards straight to this controller. Started with `startingUpdater: !isTestHost`
    /// (`isTestHost` in `applicationWillFinishLaunching`) rather than unconditionally `true`:
    /// starting a real `SPUUpdater` runs Sparkle's own first-launch automatic-checks
    /// permission prompt (a real, blocking `NSAlert`) the moment nothing has yet decided
    /// `SUEnableAutomaticChecks` — exactly the scenario every fresh test-host launch is in,
    /// since none of them ever click through it. `SparkleUpdateWiringTests.swift` is hosted
    /// inside a real launch (same reasoning `SparkleInertnessTests.swift`, job 285's version
    /// of this file, already used) and needs the controller to EXIST either way, so detecting
    /// the test host rather than gating on `#if DEBUG` keeps a real Debug build's manual
    /// testing fully live while every automated suite run stays exactly as network- and
    /// alert-silent as job 285's dormant wiring always was.
    private var sparkleUpdaterController: SPUStandardUpdaterController?

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

        // Job 236 (-1708 dedup-dispatch investigation): install BEFORE the manual `loadSuites`
        // call two lines below, so that call itself — and any automatic load Cocoa might issue
        // later, on first Apple Event — are both counted. See `SuiteRegistrationProbe`'s header
        // for why a swizzle, and why `#if DEBUG` + gated rather than the read-only posture most
        // of this module uses.
        #if DEBUG
        if SRDiagnosticsGate.isEnabled() {
            SuiteRegistrationProbe.install()
            // Job 239b (ae-layer-probe): installed alongside SuiteRegistrationProbe, as early
            // as possible — before any code, ours or Cocoa's, might route a raw Apple Event
            // through -[NSAppleEventManager dispatchRawAppleEvent:withRawReply:handlerRefCon:].
            // See AppleEventDispatchSwizzle's header for why this is the layer ABOVE
            // AppleEventDiagnosticTap's raw-proc tap, not a replacement for it.
            AppleEventDispatchSwizzle.install()
        }
        #endif

        // Job 144 (-1708): Cocoa Scripting loads `NSScriptSuiteRegistry` lazily, on first
        // dispatch. An Apple Event that arrives before anything else has forced that load is
        // not yet in the dispatch table and comes back errAEEventNotHandled (-1708, "doesn't
        // understand the X message"), even though the exact same event succeeds once the
        // registry is warm — see `AppleEventVirginDispatchTests` (SoftReturnTests), which
        // reproduces exactly this ordering with `NSAppleEventManager.dispatchRawAppleEvent`.
        // Forcing the load here closes that specific window.
        //
        // Job 236 (-1708 dedup-dispatch): `SuiteRegistrationProbe`'s swizzle, measured on real
        // hardware (Debug, cold launch), caught `loadSuites(from:)` firing TWICE per launch —
        // and named both calls precisely. Call 1: `+[NSScriptSuiteRegistry
        // sharedScriptSuiteRegistry]` -> `-init` -> `-_loadSuitesForAlreadyLoadedBundles`. Cocoa
        // Scripting does not wait for "first dispatch" as job 144's comment (and this file's
        // prior text) assumed — `NSScriptSuiteRegistry`'s OWN designated initializer loads
        // suites for every already-loaded bundle (this app's main bundle among them) the instant
        // `.shared()` is accessed anywhere in the process, for any reason. Call 2 was this exact
        // line, one statement later, on the SAME now-already-loaded singleton: a fully redundant
        // second load of the identical bundle. Job 235 witnessed `ConvertCommand` constructed
        // 2-3x per single `AESendMessage` with the sender's own status still -1708 despite a
        // real, successful execution — two loads of one suite is the direct, measured mechanism
        // that redundancy needs, not a guess. Fix: touch `.shared()` alone. That access is what
        // triggers Cocoa's own automatic load per the call-1 stack above, so the job-144 window
        // stays closed with the singleton created eagerly here, same as before — but the suite
        // is now loaded exactly once instead of twice.
        _ = NSScriptSuiteRegistry.shared()

        // Job 174 (-1708, Phase 2 of b7): AFTER the forced load above (job 236: now a bare
        // `.shared()` touch, not `loadSuites(from:)` — same forcing effect, see that job's
        // comment), not before. The cocoa-
        // event-handling docs packet (`docs/reference/apple/
        // cocoa-event-handling-appkit-default-handlers.md`) is explicit that "the Application
        // Kit automatically installs event handlers" ONLY covers the REQUIRED suite (open
        // application, reopen, open/print documents, quit) — a custom sdef command like
        // `convert` instead goes through "the script command mechanism... [which] automatically
        // installs handlers based on information in the application's sdef file", and per job
        // 144's finding (see the `loadSuites` comment above) that mechanism is driven by
        // `NSScriptSuiteRegistry`'s load, which is LAZY unless forced. `loadSuites` is that
        // force. Installing the tap before it would only prove "nothing is registered yet",
        // which job 144 already established and is not news — and worse, if `loadSuites` DOES
        // install its own raw handler for `('SRsu','conv')` as part of that forced load,
        // `AEInstallEventHandler` for the same class/ID pair simply replaces whatever was there
        // (there is no chaining), so installing first would mean Cocoa's own install silently
        // detaches this tap moments later and it would sit dark for the rest of the run,
        // recording nothing while looking installed. Installing AFTER means: (a) our handler is
        // the one left standing when a real, later `osascript` event arrives, so it will
        // actually see it; (b) `priorHandlerPresent` at this install point is a direct read of
        // whether the job-144 forced load actually causes Cocoa to register a raw handler for
        // this exact command — the discriminator the brief asks for between "Cocoa never
        // registered" and "registered but unrouted".
        //
        // Job 219 (finding B6): the RELEASE app must run Apple's own AE delivery/reply
        // machinery untouched, so this raw interceptor is `#if DEBUG` (absent from Release
        // entirely — see `AppleEventDiagnosticTap`'s header) and, even in Debug, only installs
        // when `SRDiagnosticsGate` is explicitly on.
        #if DEBUG
        if SRDiagnosticsGate.isEnabled() {
            AppleEventDiagnosticTap.install()
        }
        #endif

        // Job 532: instantiate the Sparkle updater controller — started for a real launch,
        // left dormant for a test-host launch. See the property's own doc comment for why.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        sparkleUpdaterController = SPUStandardUpdaterController(
            startingUpdater: !isTestHost,
            updaterDelegate: nil,
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
        // Job 181 Part 1 (-1708): passive record of what `NSScriptSuiteRegistry` actually
        // holds by launch time — see `ScriptingRegistryProbe`'s doc comment for why this runs
        // here (after `applicationWillFinishLaunching`'s forced `loadSuites`, same ordering
        // rationale as `AppleEventDiagnosticTap.install()` above it).
        //
        // Job 219 (findings B6-B9): all three calls below are `SoftReturnDiagnostics` module
        // members, `#if DEBUG` (absent from Release entirely) — the shipping app runs none of
        // this. `AppleEventSelfTest`/`SpotlightBackfillSelfTest` still self-gate on
        // `SRDiagnosticsGate` internally (their own `runIfRequested`, same as before, just
        // reading the one shared gate instead of a dedicated env var each), so the calls here
        // stay unconditional; `ScriptingRegistryProbe` never self-gated, so it needs the
        // explicit check here, matching the tap above.
        //
        // Job 264 (`cli-marked-method`) removed the fourth call that used to sit here,
        // `CLIInstallHelperProbe.runIfRequested()` — the SMAppService helper it probed is gone,
        // ruled dead by design (Jon, 2026-08-12: "CLI install RULED: the Marked method").
        #if DEBUG
        if SRDiagnosticsGate.isEnabled() {
            ScriptingRegistryProbe.run()
        }

        // Job 144, experiment B.
        AppleEventSelfTest.runIfRequested()

        // Job 152 Part C, step 12.
        SpotlightBackfillSelfTest.runIfRequested()
        #endif

        // Job 235 (-1708 cross-process repro): deliberately OUTSIDE the `#if DEBUG` block above —
        // unlike the three probes inside it, this one must also run against the RELEASE
        // configuration binary (the shipping dispatch path). It is still fully inert by default:
        // gated on `SRDiagnosticsGate` AND its own narrower `SRSelfSendProbe` environment flag —
        // see `AppleEventSelfSendProbe`'s header for why a second, explicit opt-in on top of the
        // shared switch.
        AppleEventSelfSendProbe.runIfRequested()
        // Job 252 (`ae-all-verbs`): export/diagnose/import page settings, same gate, same
        // "must also run RELEASE" rationale as the call above.
        AppleEventSelfSendProbe.runOtherVerbsIfRequested()
        // Job 253 (`convert-destination`): the bare-destination arbiter, against a fixture
        // staged OUTSIDE this app's own container (unlike the other probes' fixtures) — see
        // `AppleEventSelfSendProbe.outsideFixtureURL`'s own doc comment for why that
        // distinction is the entire point of this probe. Same gate, same rationale.
        AppleEventSelfSendProbe.runBareDestinationProbeIfRequested()

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
        // `SpotlightNudge`.
        SpotlightNudge.runIfNeeded()

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
            // Same as the menu-dump delay above: `Task.sleep` only throws on cancellation,
            // which nothing here does; a skipped pause would just race AppKit's own
            // restoration slightly closer, not fail the reopen.
            try? await Task.sleep(for: .seconds(1))
            DocumentRestorationStore.reopenIfNeeded(settings: SettingsStore.shared)
        }

        #if DEBUG
        // Job 276 evidence: set SR_JOB276_SHOW_DOWNLOAD_PROGRESS=<directory> and the app shows
        // the download-progress window and renders it to <directory>/download-progress.png via
        // `ViewTreeDump.writeRender` — same technique as `SOFT_RETURN_DUMP_VIEW_TREE` below, own
        // destination rather than sharing that one's hardcoded temp path. Never reads real
        // network/keychain state; the asset name is a fixture literal.
        if let dir = ProcessInfo.processInfo.environment["SR_JOB276_SHOW_DOWNLOAD_PROGRESS"] {
            let controller = DownloadProgressWindowController(assetName: "Soft-Return-4.0.0b16.dmg")
            downloadProgressWindowController = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                ViewTreeDump.writeRender(
                    window: controller.window,
                    to: URL(fileURLWithPath: dir).appendingPathComponent("download-progress.png"))
            }
        }

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
        let urls = NSDocumentController.shared.documents.compactMap { ($0 as? NSDocument)?.fileURL }
        DocumentRestorationStore.persist(urls: urls, settings: SettingsStore.shared)
    }

    // MARK: - Opening

    /// ⌘O with the Variant accessory. The panel itself is AppKit's — this only adds the
    /// accessory view and the type filtering the spec asks for: all files visible,
    /// convertibles selectable, everything else disabled.
    @IBAction func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.setAccessibilityIdentifier("open-panel")

        let accessory = OpenPanelAccessory()
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        accessory.onChange = { [weak panel] in panel?.validateVisibleColumns() }
        panel.delegate = accessory

        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        }
    }

    /// Job 374 (SAMPLES IN-APP): Help ▸ Open Sample Document ▸ <title>. `sender` is one of
    /// `SampleDocuments.buildMenuItem()`'s own submenu items — see that type's doc comment
    /// for the copy-on-open mechanics. `@MainActor`: `SampleDocuments.open` needs it
    /// (`NSDocumentController`), and AppKit always sends a menu action on the main thread
    /// anyway — same pattern as this file's other `@MainActor` actions.
    @MainActor
    @IBAction func openSampleDocument(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SampleDocuments.Item else { return }
        SampleDocuments.open(item)
    }

    // MARK: - About

    /// Job 323 (b20 item 6, Jon's ruling: option A, "cooler") — a custom Ghostty-style card
    /// (`AboutWindowController`) entirely REPLACES the default `NSApplication` about panel;
    /// this no longer calls `orderFrontStandardAboutPanel` at all.
    @IBAction func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(sender)
        aboutWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - AppleScript & Automation

    /// Help ▸ Using AppleScript & Automation… (job 234). `-1743` ("Not authorized to send
    /// Apple events") is TCC refusing the SENDING app's request before the event reaches
    /// Soft Return at all — the job-AE-E2E finding proved there is no in-process breadcrumb
    /// to react to, so this app can never intercept or explain that failure itself. The only
    /// honest fix is making the explanation discoverable from the Help menu, where a scripter
    /// hitting the error is likely to look. Command names below are `SoftReturn.sdef`'s
    /// "Soft Return Suite" (see `docs/AppleScript-Dictionary.md`) — kept in sync by hand
    /// since sdef text can't be interpolated into an alert string.
    @IBAction func showAutomationHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Using Soft Return with AppleScript"
        alert.informativeText = """
        Soft Return is scriptable. Its dictionary (Script Editor ▸ File ▸ Open Dictionary ▸ \
        Soft Return) adds export, convert, diagnose, and import page settings commands to \
        the standard application/document vocabulary.

        If a script run from Terminal, Script Editor, Shortcuts, or another app fails with \
        “Not authorized to send Apple events” (-1743), macOS is blocking that SENDING app — \
        not Soft Return — from delivering the event. The first script normally shows a \
        permission prompt; if it was denied or dismissed, re-enable it in System Settings ▸ \
        Privacy & Security ▸ Automation by finding the sending app and turning on Soft Return.
        """
        alert.addButton(withTitle: "Open Automation Settings…")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Windows

    @IBAction func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Check for Updates

    /// Job 532: forwards straight to Sparkle's own controller (`SPUStandardUpdaterController.
    /// checkForUpdates(_:)`, Sparkle 2's documented non-InterfaceBuilder wiring) — the menu
    /// item itself (`MainMenu.swift`) still targets this selector with a nil target, routed
    /// here via the standard responder chain, exactly as before; only the body changed. The
    /// GitHub-releases flow this replaced (job 251/276/280) is not deleted — `UpdateChecker`/
    /// `GitHubUpdateFeed`/`GitHubAssetDownloader` remain, still driving
    /// `CLIHelpWindowController`'s own, separate installer-package download button.
    @IBAction func checkForUpdates(_ sender: Any?) {
        sparkleUpdaterController?.checkForUpdates(sender)
    }

    @IBAction func showBatchWindow(_ sender: Any?) {
        if batchWindowController == nil {
            batchWindowController = BatchWindowController()
        }
        batchWindowController?.showWindow(sender)
        batchWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Repair Permissions

    /// "I have a folder of old files and I want to look at them."
    ///
    /// Point it at a folder and every extensionless file inside becomes openable. This is the
    /// batch form of the repair that `WSDocument.read(from:ofType:)` does per file, and it
    /// exists because the real shape of the problem is a floppy dump, not one document.
    ///
    /// Deliberately NOT a per-file prompt, and deliberately no explanation of Gatekeeper or
    /// permission bits. The user's model is "this app opens my old files"; the sheet reports
    /// a count and stops talking.
    @IBAction func prepareFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Repair"
        panel.message = "Choose a folder of old documents to repair permissions."
        panel.setAccessibilityIdentifier("prepare-files-panel")

        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let repaired = ExecutableBitRepair.repairFolder(at: folder)

            let alert = NSAlert()
            alert.alertStyle = .informational
            switch repaired {
            case 0:
                alert.messageText = "Nothing needed repairing."
                alert.informativeText = "The files in that folder are already ready to open."
            case 1:
                alert.messageText = "1 file is ready to open."
            default:
                alert.messageText = "\(repaired) files are ready to open."
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Display Diagnostics

    /// Beta tool: every attached screen's ground truth, copied as text so Jon can paste it
    /// into a report from ANY Mac — the alternative to a screenshot and a guess about which
    /// display a bug happened on. `DisplayDiagnostics.report(entries:)` does the actual
    /// formatting and is unit-tested directly; this only gathers the real `NSScreen` data it
    /// needs.
    @IBAction func copyDisplayDiagnostics(_ sender: Any?) {
        let frontDocumentScreen = NSApp.orderedWindows.first {
            $0.isVisible && $0.identifier == NSUserInterfaceItemIdentifier("document-window")
        }?.screen

        let entries = NSScreen.screens.map { screen -> DisplayDiagnosticEntry in
            let metrics = DisplayPhysicalMetrics.live(for: screen)
            return DisplayDiagnosticEntry(
                localizedName: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: Double(screen.backingScaleFactor),
                widthMM: metrics?.widthMM ?? 0,
                heightMM: metrics?.heightMM ?? 0,
                pointsPerInch: ActualSizeMagnification.pointsPerInch(from: metrics),
                actualSizeMagnification: ActualSizeMagnification.compute(from: metrics),
                isFrontDocumentScreen: screen == frontDocumentScreen
            )
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DisplayDiagnostics.report(entries: entries), forType: .string)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Copied"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Command Line Tool

    /// App ▸ Command Line Tool… (job 264, `cli-marked-method`). Replaces job 259's (b14)
    /// privileged SMAppService helper, ruled dead by design (Jon, 2026-08-12: "CLI install
    /// RULED: the Marked method") — opens an in-app page offering the three ways to get `sr`
    /// on PATH instead of attempting a privileged install of any kind. See
    /// `CLIHelpWindowController`.
    @IBAction func showCommandLineToolHelp(_ sender: Any?) {
        if cliHelpWindowController == nil {
            cliHelpWindowController = CLIHelpWindowController()
        }
        cliHelpWindowController?.showWindow(sender)
        cliHelpWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Index All WordStar Documents

    /// Help ▸ Index All WordStar Documents… (job 152 Part C). Replaces job-138's plain
    /// re-index item: rather than one bulk `mdimport -r` request the metadata server may defer
    /// indefinitely, this enumerates every Tier-1-extension file it can see and requests each
    /// one individually — see `SpotlightBackfill`.
    @IBAction func indexAllWordStarDocuments(_ sender: Any?) {
        let controller = SpotlightBackfillWindowController()
        backfillWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        controller.start()
    }

    // MARK: - Debug

    #if DEBUG
    /// Test seam for `SparkleUpdateWiringTests.swift`. Reads the REAL controller this process's
    /// actual app launch instantiated (see `main.swift`) — not a reconstructed one — so the
    /// test is evidence about what this build actually did, not about what a fresh throwaway
    /// instance would do. Plain Foundation-typed (`URL?`/`Bool`), not the raw
    /// `SPUStandardUpdaterController` itself, so the test target never needs `import Sparkle` —
    /// the Sparkle package product is linked on the app target only (job 532).
    var sparkleFeedURLForTesting: URL? { sparkleUpdaterController?.updater.feedURL }
    var sparkleUpdaterExistsForTesting: Bool { sparkleUpdaterController != nil }
    var sparkleCanCheckForUpdatesForTesting: Bool { sparkleUpdaterController?.updater.canCheckForUpdates ?? false }

    @IBAction func sendInterfaceNote(_ sender: Any?) {
        InterfaceNoteSender.presentComposer()
    }

    @IBAction func toggleIdentifierHUD(_ sender: Any?) {
        IdentifierHUD.shared.toggle()
    }

    /// Write the current view hierarchy to a file. See `ViewTreeDump` for why this exists at
    /// all: it answers "what frame did that view actually get", which no screenshot can.
    @IBAction func dumpViewTree(_ sender: Any?) {
        let url = ViewTreeDump.write(window: NSApp.keyWindow)
        NSLog("[SoftReturn] view tree: %@", url.path)
    }
    #endif
}
