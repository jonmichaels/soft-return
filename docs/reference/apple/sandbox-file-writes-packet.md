# App Sandbox — file writes, user-selected grants, security-scoped bookmarks

Docs packet for the b12 sandbox-write redesign (job 218). Fetched by the
orchestrator 2026-08-11 via sosumi.ai (Apple's own content).
Sources:
- https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- https://developer.apple.com/documentation/appkit/nssavepanel

Operative content (QUOTED, not paraphrased):

## What a user-selected grant covers
"The operating system displays open and save panels in a separate
process, and extends your app's sandbox to include the selected URLs."

"When the URL your app receives from a standard user interface
interaction represents a FOLDER, the operating system extends your app's
sandbox to items within that folder, and RECURSIVELY in nested folders."
  → A save panel grants the ONE returned file URL. A folder chosen via
    NSOpenPanel(canChooseDirectories) grants everything written inside
    it. There is NO grant for files written BESIDE a granted file.

NSSavePanel: "When the user saves the document, macOS adds the saved
file to the app's sandbox (if necessary) so that the app can write to
the file." The grant is the `url` property's exact value — write THAT,
not a reconstructed sibling path.

Drag-and-drop: URLs dragged to the app receive automatic security-scoped
access "as if you called startAccessingSecurityScopedResource()."

## Persistent access (re-export without re-prompting)
Security-scoped bookmark: bookmarkData(options:...) with
`.withSecurityScope` (add `.securityScopeAllowOnlyReadAccess` when write
isn't needed). Resolve with
init(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:) +
`.withSecurityScope`; check bookmarkDataIsStale; then
startAccessingSecurityScopedResource() → use → stop.
"You only need to create security-scoped bookmarks when your app might
try to access the bookmarked resource after it exits and re-launches."

## Adjacent / supporting files — the ONLY sanctioned path
NSFilePresenter: set primaryPresentedItemURL to the document's URL and
presentedItemURL to the supporting file's URL; "The operating system
automatically extends your app's sandbox to give your app access to the
supporting file." (This — not naive sibling write — is how a related
output file gets access.)

## Consequence for Soft Return (the 5 bug sites)
The "output lands beside the source" contract is UNWRITABLE by
construction: no user-selected grant covers sibling files. Fixes:
single-file export writes exactly panel.url (scoped); multi-format/batch
uses a folder grant (NSOpenPanel canChooseDirectories) + persisted
bookmark; AppleScript convert's `to folder` param carries its own grant.
