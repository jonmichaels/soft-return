# Apple docs packet — file grants for a scriptable sandboxed app

Fetched 2026-08-12 (sosumi mirror of developer.apple.com "Accessing
files from the macOS App Sandbox" + "App Sandbox"). Verbatim quotes;
where the docs are SILENT that silence is itself the finding.

## Folder grant = recursive
> "When the URL your app receives from a standard user interface
> interaction represents a folder, the operating system extends your
> app's sandbox to items within that folder, and recursively in nested
> folders."
→ A `to folder` destination that the user picked (or a granted folder)
covers every file convert writes inside it. This is the blessed path
(job 218 already uses it).

## Single user-selected file = that file only
> user-selected entitlements grant "read-only/read-write access to
> files the user has selected using an Open or Save dialog."
→ A single-file grant is the file, not its directory. No documented
extension to siblings.

## Adjacent files need NSFilePresenter (the ONLY sanctioned path)
> "create an object that conforms to `NSFilePresenter`. For a given
> document file, set that object's `primaryPresentedItemURL` to the
> document's URL, and the `presentedItemURL` to the supporting file's
> URL." — the system then extends access to that supporting file.
→ Writing `OLDTIMES.rtf` beside a granted `OLDTIMES.WS` is a
"supporting file" write. The documented mechanism is NSFilePresenter
with the source as primary and the output as presented item — NOT an
assumption that the source's grant covers the sibling.

## Cross-process extensions travel by BOOKMARK, not implicitly
> "Your app can pass that bookmark to another process… The receiving
> process automatically attempts to extend its sandbox to include the
> bookmarked resource."
→ AppleScript delivers a file value; whether that carries a usable
sandbox extension for the FILE is real (we captured a `shas` attribute
on the live event, b7 tap), but the docs describe NO implicit extension
to the file's DIRECTORY. Sibling-write is not documented as free.

## SILENCE (state honestly, do not fabricate)
The docs do NOT say an Apple-Event-delivered file parameter grants
write access to its containing directory. Absent a documented grant,
the design must NOT assume one.

## Design conclusion for `convert` bare destination (no `to folder`)
1. Attempt the beside-source write via the NSFilePresenter related-item
   mechanism (source = primaryPresentedItemURL, output = presentedItem)
   — the one documented path that might make it legal.
2. If that write fails (grant genuinely doesn't reach the sibling),
   return a CLEAR script error: convert needs `to folder` here.
   NEVER silently divert into the app container (Jon 2026-08-12:
   container output is "absolutely no good").
3. A machine test (self-send convert of a container-external file with
   NO `to folder`) is the arbiter of whether step 1 ever succeeds —
   evidence, not this packet's inference, decides the shipped behavior.
