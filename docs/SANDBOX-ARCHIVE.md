# Sandbox archive — the MAS-restoration map

Job 392 (2026-08-19), Jon's ruling: indie (Developer-ID) releases are NOT
sandboxed. App Sandbox was never explicitly ruled on for Soft Return
(mistake-registry #27, `.claude/skills/macos-document-app/references/mistake-registry.md`)
— it was a Mac App Store admission requirement, unmet (this app never shipped
through MAS), presented as if required, and it cost months of workarounds:
the Downloads-write saga, the Copy-to-Downloads button, beside-source convert
permission machinery, security-scoped bookmark plumbing, and finally a real
field bug (b24's PIX sibling-file reads silently denied under real sandbox
enforcement — tests stayed green because `xcodebuild test` runs unsandboxed).

This is the **restoration map**: everything this job archived or removed to
un-sandbox the app target, so a future MAS build variant (which WOULD need
App Sandbox again — Apple requires it for MAS, no exceptions) can restore it
without re-deriving any of this from scratch.

**Full pre-removal state**: tag `sandbox-archive` on `origin`, commit
`f3c8df9e3374f67ca2f5c93ff48cf13bad25a9ee` — the complete last-sandboxed
tree. `git diff sandbox-archive main -- <path>` shows exactly what changed
for any file; `git checkout sandbox-archive -- <path>` restores it verbatim.
**Do not move this tag.**

Two targets stay sandboxed regardless (Apple-mandatory, unaffected by this
job): `SoftReturnQuickLook` and `SoftReturnThumbnail` (app extensions).
`SoftReturnImporter` (the classic mdimporter, a `.bundle` CFPlugIn, not an
app extension) was already unsandboxed before this job.

## Entitlements

| What | Removed from | Restore |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | `SoftReturn.entitlements`, `SoftReturn-Debug.entitlements` | `git checkout sandbox-archive -- SoftReturn.entitlements SoftReturn-Debug.entitlements`, or copy from `archive/sandbox/*.pre-sandbox-flip.plist` in this repo |
| `com.apple.security.files.user-selected.read-write` | same two files | same |
| `com.apple.security.files.bookmarks.app-scope` | same two files | same |
| `com.apple.security.files.downloads.read-write` | same two files | same |
| `com.apple.security.network.client` | same two files | same |
| `com.apple.security.print` | same two files | same |
| `com.apple.security.temporary-exception.files.absolute-path.read-write` | `SoftReturn-Debug.entitlements` only (DEBUG probe-harness paths) | same |
| `com.apple.security.application-groups` | **KEPT** — see below | n/a |

`archive/sandbox/SoftReturn.entitlements.pre-sandbox-flip.plist` and
`archive/sandbox/SoftReturn-Debug.entitlements.pre-sandbox-flip.plist` in
this repo are verbatim copies of the two live entitlements files as they
stood at the `sandbox-archive` tag, kept alongside the code for a reader who
doesn't want to `git checkout` a tag just to see the shape.

**`application-groups` was evaluated and kept, not archived.** Evidence:
`SpotlightIndexQueue` (app-side queue drain) and
`QuickLookPageSettingsPreference` (shared QL default-preset pref) both read/
write the `RC448RH3EN.softreturn` group container that `SoftReturnQuickLook`/
`SoftReturnThumbnail` — still sandboxed — write into. Application-group
container access works for a non-sandboxed process too (it is not gated on
`app-sandbox`), so the app keeps the entitlement to keep reading what the
still-sandboxed extensions write there.

Removal commit: `70a4e004` — "Job 392 item 1: un-sandbox the app target
(entitlements flip)".

## Workaround piles removed

Each row names the file(s), what the removed code did, and the commit that
removed it. Every piece is fully recoverable from `sandbox-archive` even
without this table (`git show sandbox-archive:<path>`); the table exists so
a reader doesn't have to go hunting.

| Cluster | File(s) | What it did | Commit |
| --- | --- | --- | --- |
| Security-scoped bookmark plumbing | `ScriptingFileArgument.swift` (`withSecurityScopedAccess`), `ConvertCommand.swift`, `ExportEngine.swift` (`writeSingle`/`write`), `WSDocument+Scripting.swift`, `DocumentRestorationStore.swift` (bookmark persist/resolve/refresh), `ScriptingFileAccessSandboxTests.swift` (bookmark sanity test) | Bracketed every scripting read/write and the Open-Recent-across-relaunch persistence with `start`/`stopAccessingSecurityScopedResource()`, and stored `DocumentRestorationStore`'s remembered documents as security-scoped bookmark `Data` (with stale-bookmark refresh) instead of plain URLs — the mechanism sandboxed apps need to re-reach a file across a relaunch or a cross-process AppleEvent grant. | `c9ce813a` — "Job 392 item 3: remove security-scoped bookmark plumbing" |
| Beside-source convert permission machinery | `BatchModel.swift` (`FallbackDestinationPrompting`/`NoFallbackDestinationPrompt`, `grantedFolders`/`recordGrantedFolder`/`grantingFolder`, `BatchError.noWritableDestination`), `BatchWindowController.swift` (`BatchFallbackDestinationPrompt`), `BesideSourceWriter.swift` (`NSFilePresenter`/`NSFileCoordinator` coordinated write), `BatchModelGrantAwarenessTests.swift` (deleted, replaced by `BatchModelOptionsTests.swift`) | Tracked which folders a batch run had a live sandbox grant for, prompted once for a fallback destination folder when a row's source folder wasn't covered, and reached a beside-source sibling write through a coordinated `NSFilePresenter`/`NSFileCoordinator` write (the one documented mechanism that might extend a single-file grant to a sibling). Un-sandboxed, every readable file's sibling is a plain writable path — no grant to track, no fallback to prompt for. | `ee1c7543` — "Job 392 item 3b: remove beside-source convert permission machinery" |
| In-app updater Downloads dance | `CLIHelpWindowController.swift` (the "Copy to Downloads & Reveal" button, `revealBundledTool`, `presentRevealFailure`), `UpdateDownloadDestination.swift` (`copyStableNamed`, `DestinationError.copyFailed`) | The CLI Help window's Manual section copied the bundled `sr` binary out to `~/Downloads` and revealed it in Finder — a workaround for Finder refusing to navigate into the app's own opaque `.app` package (not itself a sandbox issue, but Jon's F1 ruling removes it regardless: the Download button + Reveal in the Installer Package section, and AppDelegate's own Check-for-Updates DMG flow, already cover "get a file into Downloads and see it"). | `2bdf6e95` — "Job 392 item 3c: simplify the in-app updater Downloads dance" |
| The 6 access-denial tests | `ScriptingFileAccessSandboxTests.swift` (deleted — `canConstructAccessDenial()` and 3 tests), plus one `.enabled(if:)` test each in `ConvertCommandTests.swift`, `SandboxWriteTests.swift`, `WiringTests.swift` | Gated every access-DENIAL-dependent test on a runtime probe (`canConstructAccessDenial()`) because this specific worker machine's permissive inherited temp-directory ACL made a real POSIX `chmod 0o000` denial unconstructible here — every one of the 6 always reported SKIPPED, never actually ran, on this host. Two of the six surfaces already had ungated, nonexistent-path coverage; the other three got one direct chmod-free replacement each (see commit body for the three new test names). | `81ae7775` — "Job 392 item 4: delete the 6 access-denial tests, replace with honest error-path coverage" |
| AppDelegate/ExecutableBitRepair sandbox-only affordances | `ExecutableBitRepair.swift` (header comment's security-scoped-URL justification), `AppDelegate.swift` (two DEBUG-only harness comments citing sandbox-container path restrictions) | Explained why an action was legal, or why a debug env var might fail, by appeal to sandbox rules (a user-chosen file's security scope; a harness path landing inside the container). Neither claim holds un-sandboxed — no functional behavior changed, only stale reasoning. `openDocument`/`prepareFiles`/`browseForFiles`/`chooseDestination`'s own `NSOpenPanel` settings needed no change: they're functional choices (what kind of input a feature needs), not grant affordances — the actual grant-tracking machinery those panels fed into was `BatchModel`'s, already removed. | `69293b93` — "Job 392 item 3e: simplify AppDelegate/ExecutableBitRepair sandbox-only affordances" |

## Real-build entitlements verification (item 10)

`xcodebuild build -configuration Release` (SoftReturn scheme, ad-hoc signed)
produced a real signed app + 2 appexes + mdimporter + `sr`, probed directly
with `macos/scripts/entitlements_probe.py` against the actual Mach-O binaries —
not asserted from Project.swift alone:

| Binary | Probe | Result |
| --- | --- | --- |
| `Soft Return.app/Contents/MacOS/Soft Return` | `--forbid com.apple.security.app-sandbox` | exit 0 — entitlements present: `application-groups` only |
| `SoftReturnQuickLook.appex` | `--require com.apple.security.app-sandbox` | exit 0 — carries `app-sandbox` + `application-groups` |
| `SoftReturnThumbnail.appex` | `--require com.apple.security.app-sandbox` | exit 0 — carries `app-sandbox` + `application-groups` |
| `SoftReturnImporter.mdimporter` | (no flags) | signature present, NO entitlement blobs |
| `Soft Return.app/Contents/MacOS/sr` | (no flags) | signature present, NO entitlement blobs |

This is the exact four-shape gate item 6 describes, confirmed against a
real build, not just read off the entitlements plists.

## Chain-impact regression found and fixed by the full gate

Not an archived/removed piece — a real bug the un-sandboxing exposed, fixed
in the same job. `ScriptingFileArgumentTests`' four `typeAlias`-descriptor
tests compared a decoded URL's path against a temp file's own unresolved
path; `NSAppleEventDescriptor`'s `typeAlias` coercion round-trips through
the OS's Alias Manager, which fully resolves symlinks (`/var` ->
`/private/var`) — sandboxed, this process's `NSTemporaryDirectory()` was
already an unambiguous, symlink-free path inside the test host's own
container, so the mismatch had nothing to show. Un-sandboxed,
`NSTemporaryDirectory()` is the plain per-user `/var/folders/.../T` darwin
temp dir, and the resolution difference surfaced as 4 real test failures.
Fixed by resolving the test's own temp-file path through POSIX `realpath(3)`
(`URL.resolvingSymlinksInPath()` does NOT do this — Foundation deliberately
leaves `/tmp`/`/var`/`/etc` unresolved). Commit `40c2f9e9` — "Job 392 item 7:
fix a real chain-impact regression — typeAlias temp-file path resolution".
