# Docs packet — App Sandbox file access (reads, writes, panels, bookmarks)

Fetched 2026-08-11 by the orchestrator per the docs-packet pipeline
(apple-docs-access.md). Sources, quoted not paraphrased:
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox (via sosumi.ai)
- https://developer.apple.com/documentation/appkit/nssavepanel (via sosumi.ai)

## Panel grants — what the OS actually extends (accessing-files page, verbatim)

> "The operating system displays open and save panels in a separate
> process, and extends your app's sandbox to include the selected URLs."

> "When the URL your app receives from a standard user interface
> interaction represents a folder, the operating system extends your
> app's sandbox to items within that folder, and recursively in nested
> folders."

NSSavePanel page, verbatim:

> "When the user saves the document, macOS adds the saved file to the
> app's sandbox (if necessary) so that the app can write to the file."

Operative consequences for THIS codebase:
- The grant is THE RETURNED URL (`panel.url`). Write that URL. A path
  string rebuilt from `