import AppKit

/// About ▸ License (job 323, b20 item 6) — the simplest viewer the brief allows: the bundled
/// `LICENSE` file's text in a small, read-only, monospaced window. Not a Help Book entry and
/// not a browser hand-off — this app can render its own bundled text with no network
/// dependency, the same reasoning `CLIHelpWindowController`'s header gives for its own
/// in-app-not-web page.
///
/// DEAD CODE as of job 335 (b22): Jon's ruling removed the About window's License button
/// (GitHub + Releases only now) — nothing constructs this controller anymore. Left in place
/// rather than deleted per the same posture job 323 used for `AboutInfo`'s dead easter-egg
/// path; the bundled `LICENSE` file itself stays (Project.swift resource), it just has no
/// in-app viewer pointed at it right now.
final class LicenseWindowController: NSWindowController {
    init(licenseText: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "License"
        window.setAccessibilityIdentifier("license-window")
        // Job 397 (Jon F9): see `BatchWindowController.init`'s comment on the same pair of
        // calls. Kept in step even though this controller is dead code (nothing constructs
        // it as of job 335) so it isn't a live placement bug the day something reconnects it.
        window.setFrameAutosaveName("LicenseWindow")
        if !window.setFrameUsingName("LicenseWindow") {
            window.center()
        }
        super.init(window: window)

        let textView = NSTextView()
        textView.string = licenseText
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("license-text")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        window.contentView = scrollView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
