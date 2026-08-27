import AppKit

/// App ▸ About Soft Return (job 323, b20 item 6, Jon's ruling: option A, "cooler"; job 329,
/// b21, Jon's field-notes polish pass; job 335, b22, Jon's Ghostty-match round 2; job 341,
/// b23, Jon's Ghostty-match round 3) — a custom Ghostty-style card replacing the default
/// `NSApplication` about panel entirely. An untitled title bar (traffic lights only, no
/// text), icon, name, the "8D0A" easter egg directly under the name, a two-line tagline, then
/// aligned info rows (Version/Build/Engine/Commit — labels in the regular system font, values
/// in the monospaced system font, both sized up to Ghostty's own proportions, the whole row
/// block centered in the window while the label/value axis inside it stays right/left
/// aligned), then a single GitHub button. No trailing MIT text line, no License button, no
/// Releases button, and no Parity row — the bundled `LICENSE` file itself is the only MIT
/// surface now.
final class AboutWindowController: NSWindowController {
    private static let contentWidth: CGFloat = 340

    private let engineProbe: EngineVersionProbing
    private let urlOpener: AboutURLOpening
    private let bundle: Bundle
    private var engineInfo: EngineVersionInfo?

    init(
        engineProbe: EngineVersionProbing = ProcessEngineVersionProbe(),
        urlOpener: AboutURLOpening = SystemAboutURLOpener(),
        bundle: Bundle = .main
    ) {
        self.engineProbe = engineProbe
        self.urlOpener = urlOpener
        self.bundle = bundle

        let window = AboutWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        // Jon's ruling (job 335): match Ghostty's untitled title bar — traffic lights stay
        // (`.titled` keeps the title-bar area, and with it `.closable`'s red button), but no
        // title text.
        window.title = ""
        window.setAccessibilityIdentifier("about-window")
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    private func buildContent() {
        guard let window else { return }
        // Job 323's ruling: run at About-open time — the child inherits the sandbox, reads
        // no files, and (being a `--version` request) returns immediately, so a synchronous
        // call here never visibly blocks opening the window.
        let info = engineProbe.currentInfo()
        engineInfo = info

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityIdentifier("about-icon")
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = NSTextField(labelWithString: "Soft Return")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 7)
        title.setAccessibilityIdentifier("about-title")

        // Jon's ruling (job 329, sized up job 335): the "8D0A" easter egg sits directly under
        // the app name, dimmed — the same protected byte pair `AboutInfo` already carries for
        // the Version row, surfaced here as its own row too. Job 335: visibly bigger than the
        // tagline (it's a feature, not fine print) while staying well under the bold app-name
        // weight — system font throughout, just dimmed by color, never bold.
        let byteLine = NSTextField(labelWithString: AboutInfo.softReturnByte)
        byteLine.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        byteLine.textColor = .secondaryLabelColor
        byteLine.alignment = .center
        byteLine.setAccessibilityIdentifier("about-byte-line")

        // Jon's ruling: an explicit break after "and" — not a wrap-dependent line break.
        let tagline = NSTextField(wrappingLabelWithString:
            "A WordStar document viewer and\nconverter for the Mac")
        tagline.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.preferredMaxLayoutWidth = Self.contentWidth - 40
        tagline.setAccessibilityIdentifier("about-tagline")

        let grid = infoGrid(info: info)

        // Jon's ruling (job 341): the Releases button is gone — GitHub only.
        let buttons = NSStackView(views: [
            button(title: "GitHub", action: #selector(openGitHub), identifier: "about-github-button"),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, title, byteLine, tagline, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        // Jon's ruling (job 335): 8D0A sits TIGHT under the name (no gap reduction here — the
        // gap after byteLine reverts to the stack's own base spacing, no longer the extra
        // blank-line gap b21 added). Breathing room before the info rows (after the tagline)
        // is unchanged; a NEW blank-line gap goes before the buttons row instead.
        let blankLineGap = stack.spacing + Self.lineHeight(for: byteLine.font!)
        stack.setCustomSpacing(blankLineGap, after: tagline)
        stack.setCustomSpacing(blankLineGap, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
        window.contentView = content

        content.layoutSubtreeIfNeeded()
        let fitted = content.fittingSize
        window.setContentSize(NSSize(width: Self.contentWidth, height: fitted.height))
        // Job 397 (Jon F9): an unpositioned `NSWindow(contentRect:)` takes its contentRect's
        // origin literally as a SCREEN-space frame — (0, 0) is the screen's bottom-left
        // corner, not "let AppKit decide". A transient, non-resizable window like this one
        // (opened fresh each time, never repositioned by a user the way a form they keep
        // reopening would be) gets `center()` every time rather than a remembered frame —
        // the same shape `NSApp.orderFrontStandardAboutPanel` and the Check for Updates
        // `NSAlert` both already have.
        window.center()
    }

    /// The Ghostty-style aligned rows: Version and Build always; Engine only when the probe
    /// returned something (`ProcessEngineVersionProbe` returns `nil` if the bundled `sr` is
    /// absent or the spawn itself failed — the row logic degrades to "no engine info" rather
    /// than showing broken text); Commit only when a stamp exists — no stamp, no hash, no row,
    /// per the ruling ("don't show a dash"). Jon's ruling (job 341, round 3): the Parity row
    /// is gone entirely — row set is Version/Build/Engine/Commit.
    private func infoGrid(info: EngineVersionInfo?) -> NSGridView {
        var rows: [[NSView]] = [
            [rowLabel("Version"), rowValue(versionRowText)],
            [rowLabel("Build"), rowValue(buildRowText)],
        ]
        if let info {
            rows.append([rowLabel("Engine"), rowValue(info.engineRowText, multiline: info.devDate != nil)])
            if let commitHash = info.commitHash, let url = info.commitURL() {
                rows.append([rowLabel("Commit"), rowLinkValue(commitHash, url: url)])
            }
        }

        // Jon's ruling (job 341): the label/value axis inside the grid stays right/left
        // aligned per column, but the grid itself hugs its own content width — the outer
        // stack's `.centerX` alignment (see `buildContent`) then centers that whole block in
        // the window, Ghostty's exact arrangement.
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.setAccessibilityIdentifier("about-info-grid")
        return grid
    }

    /// "4.0.0b22" — `CFBundleShortVersionString`, live from `Info.plist`, never a literal
    /// (mistake-registry precedent: `AboutInfoTests`' own doc comment notes a hardcoded
    /// version broke on the very first bump this app ever made). Job 335: the parenthetical
    /// build number moves to its own Build row, Ghostty-style.
    private var versionRowText: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// `CFBundleVersion` — always read live off the bundle, never hardcoded, same discipline
    /// as `versionRowText`.
    private var buildRowText: String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// A single blank line's height at `font`'s size — used to space out the byte-line and
    /// tagline breathing room per Jon's ruling, rather than a guessed constant.
    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// Job 335: Ghostty's own row treatment — labels in the regular system font (dimmed),
    /// values in the monospaced system font. Supersedes b20/b21's bundled Courier Prime rows.
    /// Job 341 (round 3): sizes bumped from `smallSystemFontSize` (~11pt) to Ghostty's own
    /// proportions — value text reads comfortably at ~13pt, labels match.
    private static let rowFontSize: CGFloat = 13

    private func rowLabelFont(size: CGFloat = AboutWindowController.rowFontSize) -> NSFont {
        .systemFont(ofSize: size)
    }

    private func rowValueFont(size: CGFloat = AboutWindowController.rowFontSize) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = rowLabelFont()
        field.textColor = .secondaryLabelColor
        return field
    }

    /// `multiline` handles the Engine row's dev shape (job 341): "sr 3.1.0" on the first
    /// line, "(dev 2026-08-14)" on its own line below — the literal "\n" `EngineVersionInfo`
    /// embeds in `engineRowText` needs `maximumNumberOfLines` raised past the default single
    /// line for it to render as two lines instead of being clipped/truncated.
    private func rowValue(_ text: String, multiline: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = rowValueFont()
        field.isSelectable = true
        if multiline {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
        }
        return field
    }

    /// The Commit row's value — CLICKABLE, opens the engine repo's commit page. A borderless,
    /// link-tinted, underlined `NSButton` rather than a plain label: target/action makes the
    /// click testable (`AboutWindowControllerTests` calls `openCommit(_:)` directly) without
    /// depending on `NSTextField`'s own link-attribute click handling.
    private func rowLinkValue(_ hash: String, url: URL) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(openCommit))
        button.isBordered = false
        button.bezelStyle = .inline
        button.attributedTitle = NSAttributedString(string: hash, attributes: [
            .font: rowValueFont(),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        button.setAccessibilityIdentifier("about-commit-link")
        button.setAccessibilityLabel("Open commit \(hash) on GitHub")
        return button
    }

    private func button(title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    // MARK: - Actions

    @objc private func openGitHub(_ sender: Any?) {
        urlOpener.open(GitHubUpdateFeed.repoPageURL)
    }

    @objc private func openCommit(_ sender: Any?) {
        guard let url = engineInfo?.commitURL() else { return }
        urlOpener.open(url)
    }
}

/// A plain, non-resizable `NSWindow` that closes on Esc — `cancelOperation(_:)` is what
/// AppKit's default `DefaultKeyBinding.dict` "cancel:" binding (Escape) reaches when no
/// subview claims it first, and this window has no editable field to intercept it.
private final class AboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Seam over `NSWorkspace.shared.open(_:)` so `AboutWindowControllerTests` can assert on
/// which URL a button/link asked to open, without a real browser launch — the same
/// seam-not-inheritance shape `CLIHelpWorkspace` already uses.
@MainActor
protocol AboutURLOpening {
    func open(_ url: URL)
}

struct SystemAboutURLOpener: AboutURLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
