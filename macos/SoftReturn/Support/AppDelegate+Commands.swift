import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared
import Sparkle

/// The app menu's commands: opening, About, scripting help, the app's windows, updates and the tools.
extension AppDelegate {
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
        Alert.show("Using Soft Return with AppleScript", informative: """
        Soft Return is scriptable. Its dictionary (Script Editor ▸ File ▸ Open Dictionary ▸ \
        Soft Return) adds export, convert, diagnose, and import page settings commands to \
        the standard application/document vocabulary.

        If a script run from Terminal, Script Editor, Shortcuts, or another app fails with \
        “Not authorized to send Apple events” (-1743), macOS is blocking that SENDING app — \
        not Soft Return — from delivering the event. The first script normally shows a \
        permission prompt; if it was denied or dismissed, re-enable it in System Settings ▸ \
        Privacy & Security ▸ Automation by finding the sending app and turning on Soft Return.
        """, style: .informational, buttons: ["Open Automation Settings…", "OK"], in: nil) { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            else { return }
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
    /// here via the standard responder chain, exactly as before; only the body changed.
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

            switch repaired {
            case 0:
                Alert.show("Nothing needed repairing.", informative: "The files in that folder are already ready to open.",
                           style: .informational, in: nil)
            case 1:
                Alert.show("1 file is ready to open.", style: .informational, in: nil)
            default:
                Alert.show("\(repaired) files are ready to open.", style: .informational, in: nil)
            }
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

        Alert.show("Copied", style: .informational, in: nil)
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
    @MainActor
    var sparkleFeedURLForTesting: URL? { sparkleUpdaterController?.updater.feedURL }
    @MainActor
    var sparkleUpdaterExistsForTesting: Bool { sparkleUpdaterController != nil }
    @MainActor
    var sparkleCanCheckForUpdatesForTesting: Bool { sparkleUpdaterController?.updater.canCheckForUpdates ?? false }
    /// Job 537's `allowedChannels(for:)` test seam, kept to this same Foundation-typed shape:
    /// the real `SPUUpdater` argument is required by `SPUUpdaterDelegate`'s own signature but
    /// is unused by `allowedChannels(for:)` below, so this just calls through the real launch's
    /// controller and hands back the `Set<String>` result -- no `SPUUpdater` value ever crosses
    /// into `SoftReturnTests`, same reasoning as the three accessors above.
    @MainActor
    var allowedChannelsForTesting: Set<String>? {
        guard let updater = sparkleUpdaterController?.updater else { return nil }
        return allowedChannels(for: updater)
    }

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
