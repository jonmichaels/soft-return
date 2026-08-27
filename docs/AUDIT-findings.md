# Soft Return b12 — audit + fix STATE (2026-08-11, near-ship)

## HEADLINE (all evidence-backed, on main; NOT my word)
CONFIRMED-FIXED & merged: A file writes (5 sites + batch), B diagnostic
scaffolding out of release (strings-proven), C ~50 error-swallow sites
(+2 latent batch bugs found), D1 stale bookmark, E harness generalized
(reusable PixelOracleKit), F scripting command shape (otool-proven).
AppleScript: command+reply shapes fixed to working-exemplar spec;
end-to-end -1743 diagnosed = TCC/Automation grant (NOT a code bug),
UNVERIFIABLE headlessly (job 233) — needs Jon's one-time Automation
grant on taco or a local console. -1743 help UX added (job 234).
Renderer: banner, running heads, page counts, overprint, driver
substitution, word-anchor — all landed & oracle-verified. Oracle
CALIBRATED w/ positive-control proof: ledger 231 noise rows -> 56 real.
56 -> characterized into 3 real classes (job 232, need deliberate
surgery) + noise floor. 6/12 fixtures fully clean.

## PENDING (Jon)
1. SHIP b12 (Athena recommends) vs keep grinding 3 survivor classes.
2. After b12 on taco: grant Automation (System Settings > Privacy >
   Automation > Soft Return) then run osascript convert = the only real
   AppleScript verdict.
3. Cut sr 3.2.0 / ctrl-kd 4.1.0 releases (deferred, task #44).

## 3 survivor classes (post-ship surgery, job 232 evidence)
- bold-word kern eats trailing space (PrintedWordAnchor last-glyph kern)
- FORMFEED whole-paragraph 1-line vertical shift (AppKit line-pin residual)
- LJ6DTP p5 curly quotes rendered-but-clipped (fragment cap-height)


---

# Soft Return — full audit findings (living document)

Jon's directive (2026-08-11): "I care about functioning software. I care
about coders who know what they are doing." This is the every-surface
audit (task #40), not the narrow file-write sweep. Orchestrator does
static discovery on the orchestrator's local checkout + fetches Apple docs; the
worker verifies each against SDK headers / committed doc packets and
fixes. NOTHING here is called "fixed" until the failing behavior is
observed passing.

Status key: FOUND (static) · VERIFYING (worker, doc-cited) · FIXED
(behavior observed) · WONTFIX (ruled).

## A. File writes — sandbox grant discarded (job 218, in flight)
1. ExportEngine.write:119 · reconstructs paths, discards panel.url · FOUND
2. CommandLineToolInstaller:27,34 · writes /usr/local/bin (impossible in
   sandbox) — root cause of task #40's "Install CLI does nothing" · FOUND.
   Job 259 (b14) tried a privileged `SMAppService` LaunchDaemon helper
   instead of a direct sandboxed write — RULED DEAD (Jon, 2026-08-12):
   every real registration attempt failed with `SMAppServiceErrorDomain`
   22, traced to macOS 14.2 sandbox-parity (a sandboxed app's helper is
   held to the same container restrictions as the app). No in-sandbox
   install path exists at all. FIXED (job 264, `cli-marked-method`) by
   not attempting one: the menu item now opens an in-app page offering
   Homebrew / a signed installer pkg / manual copy — the three paths
   that don't need this app to write outside its own container.
3. ConvertCommand:135 · write beside source, no folder grant · FOUND
4. ExportCommand:66 · writes granted url's PARENT dir · FOUND
5. ConvertWordStarDocumentIntent:58 · reconstruct-beside-source · FOUND
   Doc packet: docs/reference/apple/sandbox-file-writes-packet.md

## B. Diagnostic scaffolding shipping in the RELEASE build
6. AppleEventDiagnosticTap — a raw AEInstallEventHandler intercepting
   EVERY convert event, installed unconditionally at launch since b7.
   Sits IN the delivery path we're debugging. · FIXED (job 219) — moved
   to `SoftReturn/Diagnostics/`, `#if DEBUG` (absent from Release
   entirely), install only when `SRDiagnosticsGate` is on. Observed: a
   Release build's `strings` output has zero hits for
   `AppleEventDiagnosticTap`; the same string appears in the Debug
   build's `.debug.dylib` (positive control, confirms the check itself
   works).
7. AppleEventLifecycleBreadcrumbs / ScriptingRegistryProbe — same:
   instrumentation running in release. · FIXED (job 219) —
   `ScriptingRegistryProbe` moved + `#if DEBUG`, gated call site;
   `AppleEventLifecycleBreadcrumbs` stays compiled in every config
   (its `record` calls are reached from `ConvertCommand`, which ships)
   but `record` itself no-ops unless `SRDiagnosticsGate` is on — a
   Release build now produces zero new breadcrumbs by default, observed
   via a real convert dispatch against the Release-configuration test
   run.
8. SpotlightBackfillSelfTest:30 — hardcoded a developer-workstation absolute
   path ("sr152-selftest-probe.wsd", a WORKER-machine path) compiled into the
   shipping app. Inert unless SR_BACKFILL_SELFTEST=1, but worker-machine
   paths must not ship. · FIXED (job 219) — literal replaced with the
   `SR_BACKFILL_SELFTEST_PATH` environment variable (no compiled-in
   fallback outside the sandbox), file moved into the `#if DEBUG`
   diagnostics module. Observed: neither the Release binary nor the
   Debug `.debug.dylib` contains `sr152-selftest-probe` or a
   developer-workstation path anywhere.
9. AppleEventSelfTest — env-gated (SR_AE_SELFTEST) but also shipping
   scaffolding. · FIXED (job 219) — moved to the diagnostics module,
   `#if DEBUG`, `SR_AE_SELFTEST` folded into the one `SRDiagnosticsGate`
   (`SRDiagnostics=1`-style, per finding 10's "not per-tool flags").

## C. Error handling — FIXED (job 220, 2026-08-11)
Every non-test try?/catch verdicted: 5 real bugs surfaced (incl. 2
NOT in the suspect list — batch silent folder-skip + silent
wrong-variant export), 16 genuinely-ignorable annotated. D1 stale
bookmark: FIXED (recreate-on-stale). Original notes:
- 34 `try?` + 16 `catch` sites outside tests. Export failing SILENTLY
  for the whole beta series is the cost of swallowed write errors. Each
  user-facing operation's failure MUST surface (alert / script error),
  never be swallowed. · FOUND — worker triages each: user-facing → must
  report; genuinely-ignorable (dedupe, cleanup) → annotate why.
- 8 fatalError/preconditionFailure in prod — verify each is truly
  unreachable-by-user (init(coder:) etc.) vs a user-triggerable crash.

## D. Remaining-surface sweep — RESULTS (done 2026-08-11)
D1. READ paths / restoration bookmarks (DocumentRestorationStore) —
    CLEAN: .withSecurityScope create+resolve, start/stop BALANCED, reads
    fully on open (viewer, not editor) so scope lifetime is correct.
    MINOR: bookmarkDataIsStale is checked into `stale` then IGNORED —
    a moved/renamed file's bookmark is never recreated, so restoration
    silently drops it. · FOUND (low) — recreate-on-stale.
D2. Concurrency — CLEAN: the 4 DispatchQueue.global sites
    (SpotlightFileIndexer/Nudge/IndexQueue) run only mdimport spawns +
    logging, NO UI. NSMetadataQuery (SpotlightBackfill) correctly hops
    to main + explicit operationQueue; progress closures are
    @MainActor. No off-main UI mutation found.
D3. App-group queue (SpotlightIndexQueue) — CLEAN + EXEMPLARY:
    NSFileCoordinator with distinct purpose identifiers, cited to the
    SDK header; multi-process writes coordinated correctly. This is what
    the WHOLE app should look like.
D4. Other READ paths — CLEAN: Bundle.main reads (version, sdef, bundled
    `sr`) are always-granted bundle resources. ExecutableBitRepair reads
    a directory it owns. No arbitrary-path read defect outside the
    scripting commands job 208 already handled.
D5. Sudden-termination save — CLEAN + well-reasoned: persistOpenDocuments
    runs on every open/close (not just applicationWillTerminate), with a
    documented comment on why sudden-termination skips the terminate
    callback. Ordering (persist-before-super.close) is deliberate to
    keep scoped access live for bookmarking.

Verdict: section D is mostly CLEAN — the app's Spotlight/restoration/
concurrency substrate is competent. The rot is concentrated in file
WRITES (A), shipped diagnostic scaffolding (B), error-swallowing (C),
and the native RENDERER (pixel oracle, separate). One new low finding
(D1 stale bookmark). Recording clean results is part of the audit —
"no bug here, and here's why" is a finding.


## E. Harness generalization (Jon's ruling 2026-08-11 — "MUST be
## generalized... actively sabotaging the help that Apple offers")
10. The instrumentation pattern itself: bespoke in-app gadgets (tap,
    probes, self-tests) instead of Apple's test machinery. · VERIFYING
    — the `SoftReturnDiagnostics` module leg is done (job 219): findings
    B6-B9 fixed via ONE gate, `SRDiagnostics=1`, no per-tool flags;
    `SpotlightTriggerBreadcrumbs` audited against the same "no
    interceptors, no paths, capped" bar and found already clean (it
    observes `requestIndex` calls, never intercepts, 40-entry ring +
    500-char detail cap, no hardcoded paths — left as-is). Remaining
    for finding 10 to read FIXED: all future verification through
    Swift Testing / XCUITest / XCTAttachment (ongoing practice, not a
    one-time fix); pixel oracle built as a REUSABLE package (any
    page-producer × any reference-producer), macOS+iOS portable — job
    222, not started.

## Fix queue (no-stop, 2026-08-11): 218 writes (done) → 219 clean app +
## gated module (done, findings B6-B9 FIXED, E's module leg done) →
## 220 all error-swallow sites → 221 remaining sweep (read-paths/
## concurrency/coordination/restoration) + fixes → 222 pixel-oracle
## package + rendering classes → 223 behavioral UI sweep → b12 chain
## only when every finding reads FIXED.

This list GROWS. It is the institution Jon asked for: errors enumerated
as artifacts, verified against Apple's own docs, fixed and observed —
never declared fixed on a proxy.

## F. Scripting-command shape vs working exemplars (audit vs NetNewsWire
## source + Skim, 2026-08-11 — Jon: "audit our code against the learnings")
11. **ConvertCommand overrides execute(), receiversSpecifier (get+set),
    and suspendExecution() — entry points NO working scriptable app
    touches.** NetNewsWire (Ranchero, real Swift source) and Skim
    override ONLY performDefaultImplementation(); they let Cocoa's own
    execute() run (it is what packages the result into the reply) and
    return Cocoa-packagable primitives / object specifiers, or use
    suspend/resume for async. Our execute() override — intercepting the
    reply-packaging method itself — SHIPS IN RELEASE (job 219 no-op'd the
    breadcrumb bodies but left the overrides in ConvertCommand.swift, not
    the DEBUG-only diagnostics module). This is a live, never-tested
    candidate for the empty-reply field -1708. · FOUND (HIGH) — fix:
    strip all scripting commands back to overriding ONLY
    performDefaultImplementation, matching the exemplars byte-for-byte;
    move any diagnostic override into a DEBUG-only subclass. UNVERIFIED
    as the -1708 cause until a real field/GUI-session osascript run.
    Exemplar source: scratchpad/nnw/Mac/Scripting/*.swift
    (AppDelegate+Scriptability.swift:187 returns `false as NSNumber`;
    Feed+Scriptability.swift:129 suspend/resume). Commit a docs packet
    from these exemplars for the fix job.
