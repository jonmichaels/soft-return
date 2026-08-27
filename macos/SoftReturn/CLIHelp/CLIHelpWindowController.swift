import AppKit

/// App ▸ Command Line Tool… (job 264, `cli-marked-method`). The Marked-shaped page that
/// replaced job 259's (b14) privileged `SMAppService` install — see
/// `CommandLineToolInstaller`'s header for the ruling and why no in-sandbox install is
/// attempted at all anymore. Offline, in-app, and NOT a Help Book: a Help Book entry is
/// deferred (this content is written to fold into one later without a rewrite), and a web
/// page is wrong on principle for something this app can render itself with no network
/// dependency.
///
/// Three sections, ranked the way developer tools normally document "how do I get this CLI":
/// Homebrew first, a signed installer package second, manual copy last as the fallback that
/// needs neither.
final class CLIHelpWindowController: NSWindowController {
    /// The exact line documented in the job brief — `CLIHelpWindowControllerTests` pins this
    /// string, and the Copy button below never derives it from anywhere else.
    static let homebrewCommand = "brew install jonmichaels/tap/sr"

    /// The pkg the release chain must produce for the button below to resolve to something
    /// real once that chain exists (job 264 explicitly scopes building the pkg itself OUT —
    /// see the job report). Named here, not just in prose, so a future release-chain job greps
    /// for one literal instead of re-deriving the filename from the ticket text.
    ///
    /// Job 278 (Jon ruling): no spaces — a stable, versionless asset name a release-chain
    /// script or a `curl`/`brew` recipe can reference literally, the same reasoning that keeps
    /// `defaultDestinationPath` and every Tier-1 extension a bare, unquoted token.
    /// `nonisolated`: an immutable `String` literal, safe to read from any isolation domain —
    /// needed because `CLIPackageDownloadError.errorDescription` (below, `LocalizedError`'s
    /// nonisolated requirement) references it.
    nonisolated static let installerPackageFilename = "Soft-Return-CLI.pkg"

    private static let contentWidth: CGFloat = 460

    private let workspace: CLIHelpWorkspace
    private let bundledExecutableURL: URL?
    private let feed: UpdateFeed
    private let downloader: UpdateAssetDownloading
    /// Job 342 (addendum): the real `~/Downloads` by default, but an injectable seam —
    /// `UpdateDownloadDestination.moveStableNamed` already takes a `downloadsFolder:`
    /// parameter for exactly this. `CLIHelpWindowControllerTests`' download test points this
    /// at a private temp directory so it never touches (or collides with) whatever the real
    /// `~/Downloads` happens to hold on the host running the test.
    private let downloadsFolder: URL

    private var downloadButton: NSButton!
    /// Kept alive for the duration of a download, same reasoning as `AppDelegate
    /// .downloadProgressWindowController` — an `NSWindowController` with nothing else
    /// retaining it would deallocate (and its window close) the moment this property's own
    /// local scope ended.
    private var downloadProgressWindowController: DownloadProgressWindowController?

    init(
        workspace: CLIHelpWorkspace = SystemCLIHelpWorkspace(),
        bundledExecutableURL: URL? = CommandLineToolInstaller.bundledExecutableURL(),
        feed: UpdateFeed = GitHubUpdateFeed(),
        downloader: UpdateAssetDownloading = GitHubAssetDownloader(),
        downloadsFolder: URL = UpdateDownloadDestination.downloadsFolderURL()
    ) {
        self.workspace = workspace
        self.bundledExecutableURL = bundledExecutableURL
        self.feed = feed
        self.downloader = downloader
        self.downloadsFolder = downloadsFolder

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Command Line Tool"
        window.setAccessibilityIdentifier("cli-help-window")
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    private func buildContent() {
        guard let window else { return }

        let stack = NSStackView(views: [
            homebrewSection(),
            separator(),
            installerPackageSection(),
            separator(),
            manualSection(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content

        content.layoutSubtreeIfNeeded()
        let fitted = content.fittingSize
        window.setContentSize(NSSize(width: Self.contentWidth, height: fitted.height))
        // Job 397 (Jon F9): see `AboutWindowController.buildContent`'s comment on the same
        // call — a transient help window, centered fresh each time rather than remembered.
        window.center()
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        return line
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func body(_ text: String, identifier: String? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = Self.contentWidth - 40
        field.textColor = .secondaryLabelColor
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        return field
    }

    /// Wraps at the same measure `body(_:)` wraps prose at — job 278 (Jon field note): a long
    /// command must wrap the code block itself, never force the window wider to keep one line
    /// unbroken. `wrappingLabelWithString` (not `labelWithString`, which truncates instead of
    /// wrapping) also respects the Manual command's own embedded `\n` line breaks, so a
    /// backslash-continued shell command renders as the same multi-line shape it copies as.
    private func codeField(_ text: String, identifier: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = Self.contentWidth - 40
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    // MARK: - Section 1: Homebrew

    private func homebrewSection() -> NSView {
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyHomebrewCommand(_:)))
        copy.setAccessibilityIdentifier("cli-help-homebrew-copy-button")

        let commandRow = NSStackView(views: [
            codeField(Self.homebrewCommand, identifier: "cli-help-homebrew-command"),
            copy,
        ])
        commandRow.orientation = .horizontal
        commandRow.spacing = 8

        let section = NSStackView(views: [
            heading("Homebrew (Recommended)"),
            body("Install sr and keep it up to date alongside your other command line tools."),
            commandRow,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        return section
    }

    @objc func copyHomebrewCommand(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.homebrewCommand, forType: .string)
    }

    // MARK: - Section 2: Installer package

    private func installerPackageSection() -> NSView {
        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadCLIPackage(_:)))
        downloadButton.setAccessibilityIdentifier("cli-help-download-button")

        let section = NSStackView(views: [
            heading("Installer Package"),
            body("Download \(Self.installerPackageFilename) and run it — the standard macOS "
                + "installer places sr in /usr/local/bin."),
            downloadButton,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        return section
    }

    /// Job 313C (Jon: "The CLI PKG option here should be 'Download', not 'View Releases'"):
    /// fetches the latest release from the same `GitHubUpdateFeed`/`UpdateChannel.forVersion`
    /// channel logic `UpdateChecker.swift` defines, then downloads `installerPackageFilename`
    /// through the exact in-app downloader shape (`UpdateAssetDownloading`/
    /// `DownloadProgressWindowController`/`UpdateDownloadDestination`) — no browser fallback,
    /// per the ruling: a missing asset or a network failure surfaces this window's own
    /// plain-English alert (`presentDownloadFailure` below), never a re-route to the releases
    /// page. Job 532: this is now the ONLY user-facing surface driving the GitHub-releases
    /// checker directly — the app-wide "Check for Updates…" menu moved to Sparkle.
    @objc func downloadCLIPackage(_ sender: Any?) {
        Task { @MainActor in await performDownload() }
    }

    @MainActor
    private func performDownload() async {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let channel = UpdateChannel.forVersion(current)
        do {
            let release = try await feed.latestRelease(channel: channel)
            guard let asset = release.cliAsset else {
                presentDownloadFailure(CLIPackageDownloadError.assetNotFound)
                return
            }
            await downloadAsset(asset)
        } catch {
            presentDownloadFailure(error)
        }
    }

    /// A fresh progress window, a cancellable `Task`, move-then-reveal on success. Reveals
    /// through `workspace` rather than `NSWorkspace` directly, so this stays testable without
    /// opening a real Finder window.
    @MainActor
    private func downloadAsset(_ asset: UpdateFeedAsset) async {
        let progressController = DownloadProgressWindowController(assetName: asset.name)
        downloadProgressWindowController = progressController
        progressController.showWindow(nil)
        progressController.window?.makeKeyAndOrderFront(nil)

        let downloadTask = Task { @MainActor in
            try await downloader.download(asset: asset) { _ in }
        }
        progressController.onCancel = { downloadTask.cancel() }

        do {
            let tempURL = try await downloadTask.value
            progressController.close()
            downloadProgressWindowController = nil
            let destination = try UpdateDownloadDestination.moveStableNamed(
                tempURL, assetName: asset.name, downloadsFolder: downloadsFolder)
            workspace.reveal([destination])
        } catch {
            progressController.close()
            downloadProgressWindowController = nil
            // A user-initiated Cancel surfaces as `URLError(.cancelled)` via
            // `GitHubAssetDownloader`'s `withTaskCancellationHandler` — not a failure worth
            // alerting about.
            if (error as? URLError)?.code == .cancelled { return }
            presentDownloadFailure(error)
        }
    }

    /// Job 251's `authHint` extra sentence for a missing/bad update token — same copy this
    /// window's alert has always used for a GitHub-releases download failure.
    @MainActor
    private func presentDownloadFailure(_ error: Error) {
        var authHint = false
        if let feedError = error as? UpdateFeedError {
            switch feedError {
            case .unauthorized, .notFound: authHint = true
            case .badResponse, .noReleaseForChannel: authHint = false
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t download \(Self.installerPackageFilename)."
        var informativeText = "Soft Return couldn’t download it. Check your connection and try again."
        if authHint {
            informativeText += " If this is a beta build, an update token may be required — see Help."
        }
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Section 3: Manual

    private func manualSection() -> NSView {
        let command = bundledExecutableURL.map {
            CommandLineToolInstaller.installCommand(bundledPath: $0.path)
        } ?? "This build doesn\u{2019}t include the bundled sr binary."

        let copy = NSButton(title: "Copy Command", target: self, action: #selector(copyManualCommand(_:)))
        copy.setAccessibilityIdentifier("cli-help-manual-copy-button")
        copy.isEnabled = bundledExecutableURL != nil

        // Vertical, not a side-by-side row: a row would give the code block less than the
        // full `contentWidth - 40` measure (the button's own width eating into it), which is
        // exactly the "forcing window width" trap job 278's brief warns off — the code block
        // needs the SAME measure `body(_:)` wraps prose at, full width, button underneath.
        let commandColumn = NSStackView(views: [
            codeField(command, identifier: "cli-help-manual-command"),
            copy,
        ])
        commandColumn.orientation = .vertical
        commandColumn.alignment = .leading
        commandColumn.spacing = 8

        let section = NSStackView(views: [
            heading("Manual"),
            body("No Homebrew, no package — copy this command into Terminal and run it there "
                + "to install the sr bundled inside Soft Return into /usr/local/bin.",
                identifier: "cli-help-manual-body"),
            commandColumn,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        return section
    }

    @objc func copyManualCommand(_ sender: Any?) {
        guard let bundledExecutableURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CommandLineToolInstaller.installCommand(bundledPath: bundledExecutableURL.path),
                             forType: .string)
    }
}

/// The one failure `presentDownloadFailure` needs a message for that isn't already a
/// `UpdateFeedError`/`URLError` — the latest release simply did not carry
/// `installerPackageFilename` as one of its assets.
enum CLIPackageDownloadError: LocalizedError {
    case assetNotFound

    var errorDescription: String? {
        "The latest release doesn’t include \(CLIHelpWindowController.installerPackageFilename)."
    }
}

/// Narrow seam over `NSWorkspace` so `CLIHelpWindowControllerTests` can assert on "reveal the
/// bundled sr" / "reveal the downloaded CLI package" without actually opening Finder from a
/// test host — the same seam-not-inheritance rationale `CLIInstallHelperService` used for
/// `SMAppService` before job 264 removed it. Job 313C removed `open(_:)`: the Installer
/// Package section no longer opens a browser at all (the ruling this job implements is
/// explicit that there is no browser fallback to re-route around), so the one remaining
/// caller of this protocol is `reveal(_:)`.
@MainActor
protocol CLIHelpWorkspace {
    func reveal(_ urls: [URL])
}

struct SystemCLIHelpWorkspace: CLIHelpWorkspace {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
