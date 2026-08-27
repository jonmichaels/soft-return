# Documentation packet — Spotlight indexing features (job 145)
Fetched via sosumi.ai (renders developer.apple.com verbatim) 2026-08-09.
Per the docs-packet rule: quoted content + source + local-header pointers.

## NSMetadataQuery (Foundation) — for Help ▸ Index All enumeration
Source: https://developer.apple.com/documentation/foundation/nsmetadataquery
- "A query that you perform against Spotlight metadata."
- "You must set a predicate with the predicate property before starting a
  query."
- "By default, the receiver has no limitation on its search scope. Use the
  searchScopes property to customize."
- Two phases: "the initial gathering phase that collects all currently
  matching results and a second live-update phase." Completion signal:
  NSMetadataQueryDidFinishGathering notification.
- `operationQueue`: "The queue on which query result notifications are
  posted" — set it explicitly; do not assume main-runloop delivery.
- For filename/extension enumeration (content not yet indexed), predicate
  on kMDItemFSName (e.g. LIKE[c] patterns per extension) — filename
  metadata exists for ALL files regardless of content-index state
  (empirically verified on taco 2026-08-09: mdfind kMDItemFSName == '*.ws4'
  returned files whose content was unindexed).

## Process spawning from sandbox — for per-file mdimport requests
- Apple `Process` docs: "In a sandboxed app, child processes you create
  with this class inherit the sandbox of the parent app."
  (developer.apple.com/documentation/foundation/process)
- Apple DTS (forums thread 661272): sandboxed apps may NSTask/Process
  fixed-path system binaries (e.g. /usr/bin/mdimport); the restriction is
  on executing binaries the app itself creates/downloads.
- Empirical (this repo, job 138): sandboxed Release app spawned
  /usr/bin/mdimport -r successfully, rc=0, sandbox intact.

## mdimport semantics — worker-local man page
- Worker path: MacOSX.sdk/usr/share/man/man1/mdimport.1 (resolve with
  `man -w mdimport` — bare name, no .1 suffix).
- `-r`: "Ask the server to reimport files for UTIs claimed by the listed
  plugin" — a REQUEST the server schedules (may defer indefinitely on
  battery); per-file `mdimport <path>` requests process in seconds
  (verified taco ×2). NEVER call -r automatically (registry #7).

## SDK headers the worker reads directly (no packet needed)
- Metadata.framework/Headers/MDImporter.h — interface UUIDs/ABI.
- QuickLookUI headers (32 files) — for the index-on-view leg.
