# Known-Issues Register

**Date:** 2026-08-22 (job 440). **Repo state audited:** `soft-return-app` at
`e1276e8` (this tree's only commit — see "Provenance limits" below).

**The rule this register exists to enforce (Jon's standing ruling):** a
`withKnownIssue`/skip/disabled marker is never a pass. Every suppressed test
must be named individually, adjudicated, and re-checked before anyone quotes
a pass count for this suite. "805/805 passing, 103 known issues" is not an
honest summary of this suite and must not be quoted again in that form.

**Reconciled total: 31 suppressed test-runs** (28 recorded as Expected
Failure + 3 recorded as Skipped), out of **1,588 total test-runs** (1,557
clean passes), via `SoftReturnTests` only (`SoftReturnUITests` did not run
this session at all — see the dedicated section near the end). These 31
runs trace to **10 distinct suppression call-sites** in 8 files. One of the
31 (`regionDiffEnumeration`) is itself a hand-rolled loop hiding 80 further
named sub-cases — the same masking pattern this job exists to catch, one
layer deeper than `withKnownIssue`/`@Test(arguments:)` can express it. See
"The regionDiffEnumeration problem" below.

---

## Why the counts disagree (reconciliation)

Every job this round quoted a real number from a real run. They disagree
because **three different metrics were quoted under the same words "tests"
and "known issues," and none of the jobs that used the smallest one
(method-level) realized it was hiding argument-level suppressions.**
Confirmed by generating a fresh `.xcresult` this session
(`xcodebuild test -workspace SoftReturn.xcworkspace -scheme SoftReturn
-destination 'platform=macOS' -only-testing:SoftReturnTests`, current HEAD)
and reading it three ways:

1. **Method/test-identifier level** — the console's own top line
   (`Test run with 829 tests in 72 suites passed ... with 107 known
   issues.`) and `xcrun xcresulttool get test-results summary`'s top-level
   fields (`totalTestCount: 829`, `expectedFailures: 6`, `passedTests: 820`,
   `skippedTests: 3`). Swift Testing rolls a parameterized `@Test` up to
   **one** identifier; it reports "Passed" for the whole thing as long as
   nothing hard-fails, **even if some arguments individually recorded a
   known issue**. This is what jobs 436 (805 tests), 437 (809), 438 (812)
   and 439 (818) quoted — the tests-count grew each job as new tests were
   added, but the "103 known issues" figure they carried alongside it was
   never a method count at all (see #3). At method level only **6** methods
   ever show as known-issue: the 3 `LivePrintedFramingTests` methods, 1
   `IntegrationGauntletTests` method, 1 `OutputParityTests` scope statement,
   1 `PixelOracleAppEngineTests.regionDiffEnumeration`.
   `PrintedStructuralParityTests.structuralParity` (19 of 22 fixture
   arguments individually failing) and `QLCLIByteParityTests
   .qlMatchesAppNativeRendering` (3 of 22 arguments individually failing)
   **both roll up to "Passed" and vanish from this view entirely** — this is
   job 435's finding, reconfirmed against current HEAD.

2. **Run/argument level** — `xcrun xcresulttool get test-results summary`'s
   **`devicesAndConfigurations[0]`** block: `passedTests: 1557,
   expectedFailures: 28, skippedTests: 3` (1,588 total test-runs; the
   summary's own `statistics` field explains the gap from #1: "10 tests ran
   with dynamic parameters" → "769 test runs"). This counts each
   parameterized argument as its own run — a test with 19 suppressed
   arguments is 19 entries here, matching this round's evidence law
   exactly. **This is the only one of the three that should ever be quoted
   as this suite's pass/fail summary.** Job 441 alone used this metric
   (`1547 passed / 28 known / 3 skipped` = 1,578 runs); the +10 runs between
   441 and now are new tests added by jobs 442-450, with the identical 28/3
   split — no new suppression landed in that window.

3. **Event level** — the console's live "*N* known issues" tally is neither
   a test count nor a run count: it is the number of individual `#expect`
   failures **recorded** inside `withKnownIssue` closures, summed across the
   whole run. A single run that internally loops and fails many times
   (`regionDiffEnumeration`, one test, 80 internally-recorded rows this
   session) contributes 80 to this number and only **1** to metric #2.
   Verified exactly: `3 (LivePrintedFraming ×3) + 1 (IntegrationGauntlet) +
   1 (OutputParity scope) + 80 (regionDiffEnumeration rows) + 19
   (structuralParity Class-2 fixtures) + 3 (QL renderQL-gap fixtures) + 0
   (QL titleHinting, not firing this run) = 107` — the exact figure the
   live console printed this session. The "103" jobs 436-439 quoted is the
   same metric at an earlier point in the corpus (+3 for job 441's new
   renderQL-gap known issue since then, +1 unaccounted for — most likely a
   ±1 drift in `regionDiffEnumeration`'s own row count from ordinary
   rendering changes in jobs 442-450; not investigated further, out of this
   audit's scope).

**Ruling for this register and going forward:** quote metric **#2**
(`xcrun xcresulttool get test-results summary`'s `devicesAndConfigurations`
block, cross-referenced against `xcrun xcresulttool get test-results tests`
for names/messages) as the suite's denominator. Never again quote the
console's top-line "*N* tests ... *M* known issues" as a pass/fail summary —
both of its numbers are the wrong granularity.

### Provenance limits
This tree is a **shallow clone (depth 1)** — `git log`/`git blame` return
only this one commit (`e1276e8`); `git log -S` cannot recover history, and
`git fetch`/`clone` are unavailable by this session's own policy. Every
"introduced" date/commit below is therefore taken from the entry's **own
inline citation** (a job number, and — where the code itself quotes one — an
explicit ISO date from a decision-register ruling), not from git history.
This is the only provenance actually available in this environment.

### Scope note — throwaway probe files
Job 531 (2026-08-27) deleted every `*.swift.unused` file in the tree (Jon's
ruling — recoverable in git history if ever needed). Historically,
`SoftReturnTests/ZZProbe*.swift.unused`, `ZZScreenshot*.swift.unused`,
`ZZUIAudit*.swift.unused` (37 files as of removal) were **not** suppressed
tests: the `.unused` extension meant Xcode's target membership never
compiled them at all (the documented convention for one-shot measurement
probes, e.g. job 402's own report). They carried zero weight in any of the
three metrics above and were not adjudicated as register entries.

---

## REAL DEFECT WEARING A MARKER

None confirmed this pass. The closest candidate is examined immediately
below under UNDETERMINED — it wears a `withKnownIssue` marker but I could
not, within this job's time budget, tell whether it hides a real distinct
defect or is entirely downstream of an already-disclosed permanent one.

## UNDETERMINED

### 1. `PixelOracleAppEngineTests.regionDiffEnumeration()` — 80 named (fixture, page, region-class) rows, un-triaged
- **File:line:** `macos/SoftReturnTests/PixelOracleAppEngineTests.swift:297` (the
  `withKnownIssue(Comment(rawValue: detail))` call inside the row loop,
  lines 283-300).
- **Mechanism:** one `@Test` (not parameterized), internally looping over
  every `(fixture, page, region-class)` group with a non-empty pixel diff
  and wrapping each in its own `withKnownIssue` — so a fixed class flips its
  own row green with no code edit, and a regression turns it red again.
  Explicitly excludes rows whose page already hard-fails
  `PrintedStructuralParityTests`' Class 4 (vertical-origin) bound (job 410's
  ruling) so that defect isn't double-counted.
- **Stated reason (quoted from the doc comment, lines 183-187):** "THE
  ENUMERATION GATE. Per this job's brief: 'This enumeration is the
  deliverable even if zero fixes land this job.'"
- **View:** Printed (this table compares the app's Printed-style render
  pipeline against the engine's real PDF; see `PixelOracleAppEngine
  .renderApp`/`.renderEngine`).
- **Introduced:** file header cites Job 223, Jon's directive, 2026-08-11
  ("Find all the problems and fix them. Really and truly.") as the pixel-
  oracle mechanism's origin; the exact job that added this specific
  known-issue table is not independently citable from the file (see
  provenance-limits note).
- **Current breakdown (this session's run), by fixture:**

  | Fixture | Rows | By class (extraInActual / contentDiffers / missingInActual) |
  |---|---|---|
  | OLDTIMES.WS | 31 | largest concentration |
  | LJ6DTP.WS | 21 | second largest |
  | LYING.WS | 11 | |
  | WARPRAYR.WS | 6 | |
  | DARKNESS.WS | 5 | |
  | PREVIEW.WS | 3 | |
  | -SCREEN.WS | 2 | |
  | SCRIPT.WS | 1 | |

  Totals across all 8 fixtures: `extraInActual` 19, `contentDiffers` 33,
  `missingInActual` 28.
- **Why UNDETERMINED, not adjudicated further:** the code already
  cross-references each row's `(fixture, page)` against
  `PrintedStructuralParityTests`' hard-bounded **Class 4** (vertical)
  divergence to avoid re-hiding that defect — but it does **not**
  cross-reference against Class 2 (proportional-font horizontal placement,
  permanently accepted by the 2026-08-11 MAC VIEWING RULING, entry below).
  Every one of this table's 8 fixtures also carries a Class-2 divergence in
  `structuralParity`. It is plausible some/most of these 80 pixel rows are
  simply the visual shadow of the already-ruled-permanent Class-2
  divergence, not a distinct defect — but the correlation is not clean
  (`WARPRAYR.WS`/`DARKNESS.WS` have tiny Class-2 counts, 1 each, yet 6/5
  region-diff rows), so I am not willing to assert that as fact.
- **What would settle it:** extend the existing Class-4 cross-reference
  code to also exclude rows whose `(fixture, page)` has a Class-2
  divergence, re-run, and see how many of the 80 rows that additionally
  explains. Whatever remains after that is the real, un-explained residual
  and deserves individual visual inspection (start with `OLDTIMES.WS`'s 31
  and `LJ6DTP.WS`'s 21 — the two largest, and both already known to be the
  heaviest `.overprint`/proportional-font fixtures in the corpus).

### 2. `QLCLIByteParityTests` title-hinting known issue — currently firing on 0 of its 2 eligible fixtures
- **File:line:** `macos/SoftReturnTests/QLCLIByteParityTests.swift:201-209` (first
  `withKnownIssue` block in `qlMatchesAppNativeRendering(fixtureName:)`).
- **Mechanism:** `withKnownIssue(..., isIntermittent: true)`, gated to
  `fixtureName == "DARKNESS.WS" || fixtureName == "WARPRAYR.WS"` and
  `$0.page == "p1"`.
- **Stated reason (quoted, lines 201-206):** "page 1's own bold title:
  individual glyph cells render with a hair different ink between windowed
  and windowless AppKit PDF generation — CONFIRMED (job 413) this is not a
  placement/determinism gap... Accepted as a judgment call, **not a dated
  Jon ruling — pending Jon ratification**, ready-report v3."
- **View:** Modern/QuickLook-native-rendering comparison (this test compares
  QuickLook's simulated render against the app's own on-screen native
  rendering).
- **Introduced:** cites job 412 (hypothesis), job 413 (partial fix/
  determinism), and an explicit date — "Jon accepted the pre-job-413...
  explanation... on 2026-08-19" (the file's own doc comment, lines 138-139)
  — for the *predecessor* SCRIPT.WS p10 case that job 413 then closed; this
  title-hinting case is its still-open sibling, not independently dated.
- **Why UNDETERMINED:** in this session's full run, **this block recorded
  zero known issues** — neither `DARKNESS.WS` nor `WARPRAYR.WS` triggered
  it (both argument-runs for `qlMatchesAppNativeRendering` show 0 for this
  check; only the separate renderQL-gap block below fired, and only for the
  3 `.PIX`-tagged fixtures). Because the block is declared
  `isIntermittent: true`, a silent argument is by design *not* an error —
  but that is indistinguishable, from this one run alone, between "the
  underlying rendering variance genuinely didn't reproduce this time" (the
  comment's own claimed shape) and "this has quietly gone stale." The
  comment itself flags this as **not yet a dated ruling**, which is exactly
  the ambiguity a register should surface, not silently roll forward.
- **What would settle it:** re-run `qlMatchesAppNativeRendering` for
  `DARKNESS.WS`/`WARPRAYR.WS` several times (or with the `withKnownIssue`
  temporarily removed) across independent invocations. If it never fires,
  it is STALE and should convert to a hard assertion; if it fires on some
  runs, LEGITIMATE TEMPORARY stands and the ratification the comment itself
  asks for should happen. I did not do this myself — a single before/after
  pair on one run is not enough evidence for a genuinely intermittent
  claim, and repeated reruns risked this job's time ceiling.

---

## LEGITIMATE, TEMPORARY

### 3. `QLCLIByteParityTests` renderQL `docPath` gap — 3 fixtures (`-README.WS`, `-SCREEN.WS`, `PREVIEW.WS`)
- **File:line:** `macos/SoftReturnTests/QLCLIByteParityTests.swift:211-220`.
- **Mechanism:** `withKnownIssue(..., isIntermittent: true)`.
- **Stated reason (quoted, lines 211-216):** "this test's own `renderQL`
  helper never passes `docPath:` into `QuickLookNativeRenderer
  .renderedDocument`, so its `.PIX` tag reports unresolved on the QL side
  only — job 441's discovery, a test-harness gap in THIS file, not a real
  QuickLook rendering defect (the real `PreviewProvider` passes a real
  `docPath` and is unaffected)."
- **View:** QuickLook/Modern (the test-harness's own QL simulation only —
  confirmed NOT to affect the real `PreviewProvider.providePreview`, which
  passes a real `docPath`).
- **Introduced:** job 441 (2026-08-22, this round), explicitly cited as
  "a second, still-unfixed instance" of the same test-harness image-
  blindness bug class job 441 fixed in `PixelOracleAppEngine` itself.
- **Retirement condition (named exactly, per this job's brief calling this
  one out as legitimate):** pass a real `docPath:` argument into
  `QuickLookNativeRenderer.renderedDocument` inside `renderQL`, matching
  what `PreviewProvider.providePreview` already does. Explicitly out of job
  441's own scope ("fix what the brief names... report, do not fix").
  Confirmed test-only (does not affect shipped QuickLook behavior).

### 4. `LivePrintedFramingTests` — 3 methods, no Screen Recording grant
- **File:line:** `macos/SoftReturnTests/LivePrintedFramingTests.swift:150`,
  `:213`, `:240` (`livePrintedFramingMatchesNativeAtFit`,
  `livePrintedFramingMatchesNativeAt100Percent`,
  `livePrintedFramingSurvivesWindowResize`).
- **Mechanism:** `withKnownIssue(...)`, guarding on
  `CGPreflightScreenCaptureAccess()`.
- **Stated reason:** "no Screen Recording grant in this session — cannot
  take a live capture — task #65 (session-bound dispatch environment)."
- **View:** Printed vs. Native (the tests compare a live on-screen capture
  of the two styles).
- **Introduced:** job 342 (b23 floor drop) gated these `@available(macOS
  14, *)`; task #65 is this suite's standing umbrella citation (per
  `IntegrationGauntletTests.swift:363-368`) for every session-bound
  dispatch-environment gap.
- **Retirement condition:** this headless dispatch host is granted Screen
  Recording access (a host/session property, not a code fix). Named
  explicitly per-view above; not testable in this or any other headless
  session without that grant.

### 5. `IntegrationGauntletTests.launchWithDocumentQuitRelaunchReopensTheDocument()`
- **File:line:** `macos/SoftReturnTests/IntegrationGauntletTests.swift:373, 397,
  403, 427, 433` — 5 separate `withKnownIssue` guards in one test body (only
  one fires per run; this session it was line 373).
- **Mechanism:** `withKnownIssue(...)`, guarding respectively on: no
  Release build present, `NSWorkspace` launch failure, launch resolving to
  the test's own host process, relaunch failure, relaunch resolving to the
  test's own host process.
- **Stated reason (this session, line 373's guard fired):** "no Release
  build at `<worker-machine build tree>/build-dd/Build/Products
  /Release/Soft Return.app` — build it first (build-dd); task #65
  (session-bound dispatch environment)."
- **View:** Native/Printed (exercises document reopen across a real app
  quit/relaunch cycle; not view-specific beyond "the app", both styles
  reachable from the reopened window).
- **Introduced:** cites task #65 umbrella (see entry 4); the anti-coalescing
  guards themselves cite a real past incident ("an earlier version of this
  test terminated what turned out to be its own host and took the whole
  test run down with it").
- **Retirement condition:** a session that (a) has already run a Release
  build at the pinned `build-dd` path, and (b) can launch it as a distinct
  process without `NSWorkspace` coalescing it into the test's own host.
  Named per-guard above rather than bucketed.

### 6. `OracleByteParityTests.tier2BareByteParity`/`tier2SawyerByteParity` — env-gated, zero arguments
- **File:line:** `macos/SoftReturnTests/OracleByteParityTests.swift:411`, `:417`
  (test funcs); `:389-409` (`corpusRoot`/`tier2Keys`, the actual gate).
- **Mechanism:** `@Test(arguments: tier2Keys)` where `tier2Keys` returns
  `[]` whenever `CTRLKD_PRIVATE_CORPUS` is unset (job 531: unified from the
  app's own former `SOFTRETURN_ORACLE_CORPUS` name onto the engine repo's
  gate name) — no explicit
  `XCTSkip`/`.disabled`; Swift Testing reports the resulting zero-argument
  parameterized test as `Skipped`.
- **Stated reason (quoted, lines 398-402):** "Jon's ruling, 2026-08-19 ('Go
  with A')... the full-corpus truth is the full-archive engine sweep (1236/1236
  byte-exact, run outside this repo), not this in-repo gate... staying a
  clean env-gated no-op here is the RULED shape of that division, not
  undone coverage debt."
- **View:** engine-only (byte parity of emitted PDFs; not view-specific).
- **Introduced:** Jon's ruling, explicit date **2026-08-19**.
- **Retirement condition:** none intended — by design, this repo never
  carries the corpus ("TestDocs never leave this private
  repo"); the full-archive sweep is the permanent home for this coverage.
  Filed as TEMPORARY rather than PERMANENT only because it is contingent on
  a standing ruling (division of labor) rather than a hard external
  constraint like an OS API gate — the ruling could in principle be
  revisited, unlike e.g. entry 9 below.

### 7. `OutputParityTests.tier2DocumentOperationsMatchesOracle(cell:)` — same shape as #6
- **File:line:** `macos/SoftReturnTests/OutputParityTests.swift:518-548`.
- **Mechanism/reason/view:** identical to entry 6, same
  `CTRLKD_PRIVATE_CORPUS` gate, same 2026-08-19 ruling, engine-only.
- **Retirement condition:** same as entry 6.

---

## LEGITIMATE, PERMANENT

### 8. `PrintedStructuralParityTests.structuralParity(fixtureName:)` Class 2 — 19 of 22 fixtures
- **File:line:** `macos/SoftReturnTests/PrintedStructuralParityTests.swift:1249`
  (single call site, applied per-fixture via `@Test(arguments:)`).
- **Mechanism:** `withKnownIssue(..., isIntermittent: true)`.
- **Stated reason (quoted, lines 1249-1254):** "WS5+ proportional-font BODY
  TEXT placement diverges from the engine's PDF grid by design... job 240,
  b13 Part 2, MAC VIEWING RULING (decision register **2026-08-11**; skill
  registry #25): natural Mac-font advance, not an AFM/Tz-scaled
  reproduction of it. PERMANENTLY expected, not a gap to close."
- **View:** Printed (this gate compares Printed/AppKit layout geometry
  against the engine's PDF).
- **Introduced:** job 240 (b13 Part 2), ruling dated **2026-08-11**.
- **Currently firing, this session (19 of 22 fixture arguments; divergence
  counts from each argument's own recorded message):**

  | Fixture | Divergences | Fixture | Divergences |
  |---|---|---|---|
  | -README.WS | 33 | POWERUSE.WS | 105 |
  | -SCREEN.WS | 3 | PREVIEW.WS | 2 |
  | CONVERT.WS | 23 | SCRIPT.WS | 120 |
  | DARKNESS.WS | 1 | STRENGTH.WS | 35 |
  | FORMFEED.WS | 41 | TWAINLET.WS | 5 |
  | LAYOUT.WS | 34 | VERSIONS.WS | 155 |
  | LJ6DTP.WS | 21 | WARPRAYR.WS | 1 |
  | LYING.WS | 1 | WORDSTAR.WS | 86 |
  | OCAPTAIN.WS | 12 | YOURWAY.WS | 154 |
  | OLDTIMES.WS | 197 | | |

  The other 3 (`BOTHNOTE.WS`, `BOX.WS`, `BOXES.WS`) pass clean — Courier/
  fixed-width-only fixtures with no proportional run to diverge on.
- **Constraint (why permanent):** a Mac AppKit font's own natural glyph
  advance will never bit-for-bit match the engine's base-14/HMI-grid PDF
  positions — this is a font-identity difference between two real,
  correct rendering paths, not a bug in either one. Explicitly out of this
  gate's scope per the file's own header doc comment.

### 9. `AccessibilityAuditUITests.testDocumentWindowAccessibilityAudit()` — macOS 14+ gate
- **File:line:** `macos/SoftReturnUITests/AccessibilityAuditUITests.swift:32`.
- **Mechanism:** `throw XCTSkip(...)`, guarded by
  `#available(macOS 14, *)`.
- **Stated reason (quoted):** "performAccessibilityAudit requires macOS
  14+."
- **View:** Native (document window accessibility audit).
- **Introduced:** job 342 (b23 floor drop) — the app's deployment floor
  dropped to macOS 13.0, but `performAccessibilityAudit` itself has no
  pre-14 form.
- **Constraint (why permanent):** a real Apple API availability floor, not
  a workaround. Also currently **dormant**: this session's host is macOS
  15.7.4 (well above the gate) but never reaches this line at all, because
  the entire `SoftReturnUITests` target was excluded from every run this
  round — see next section. Coverage is not lost: the file's own header
  states `PagedDocumentViewAccessibilityTests` (in `SoftReturnTests`,
  headless) covers the same three defect classes and does run.

### 10. `OutputParityTests.fullDenominatorLawStatesThisSuitesRealScopeAgainstTheFullManifestCorpus()` — deliberate report side-channel, REMOVED job 497
- **File:line (as it stood before removal):** `macos/SoftReturnTests/OutputParityTests.swift:385-399`.
- **Mechanism (historical):** `withKnownIssue(..., isIntermittent: true)` wrapping a bare
  `Issue.record(...)` — the three real `#expect`s in this same test
  (pinning 228/19/228) are ordinary hard assertions and all pass; only the
  informational statement itself was wrapped, purely to force a "known
  issue" entry into the test report.
- **Stated reason (historical, quoted):** "scope statement recorded above for
  report visibility, per the internal runbook's documented pattern" — Swift Testing
  swallows `print()` output on a passing test, so this was used as a way to
  get diagnostic text into a green run's report.
- **View:** engine-only (manifest/export-surface scope statement, not
  render-specific).
- **Introduced:** job 426 (v11 rescope); cited job 381's ruling,
  **2026-08-18** (layout un-exclusion).
- **REMOVED 2026-08-24, job 497, by Jon's direct ruling.** Told this case
  was a deliberately recorded fake failure whose only purpose was making a
  scope statement visible in the report, Jon said: "That's a terrible idea.
  Lose it." The `withKnownIssue`/`Issue.record` block was deleted outright;
  the test's three real `#expect` assertions are untouched and still pass.
  The scope prose is not re-homed anywhere — it already exists verbatim in
  the test's own doc comment, and job reports are required to state the
  suite's denominator themselves. the internal release runbook (not part of this repo)'s "Worker notes" was
  rewritten in the same job to say a fake failure is never an acceptable
  way to get text into a report, because it plants a permanent phantom in
  the suppressed-test count.

---

## `SoftReturnUITests` — entirely excluded this session, named per evidence law

None of the following 5 tests ran this session (invocation used
`-only-testing:SoftReturnTests`, matching every job this round back to
job 409's own root-cause finding):

- `Job276DownloadProgressScreenshotUITests.testDownloadProgressWindowAppearsForScreenshot()`
- `Job314MenuAndInspectorScreenshotUITests.testViewMenuOpenWithMarginsSubmenuVisible()`
- `Job314MenuAndInspectorScreenshotUITests.testInspectorPanelOnOldtimes()`
- `AccessibilityAuditUITests.testDocumentWindowAccessibilityAudit()` (its own
  XCTSkip is entry 9 above; irrelevant here since the whole target never runs)
- `DocumentVisibleUITests.testAnOpenedDocumentIsActuallyVisible()`

**Root cause (job 409):** `LocalAuthentication -1004` in XCUITest's own
runner handshake, off-console — a property of this headless host, not app
code. **Adjudication: LEGITIMATE, TEMPORARY for this specific headless
dispatch environment** (would very likely run on a real console with a
logged-in session) — **not counted in either the 829/1,588 denominators
above**, named here explicitly rather than silently absent, per this
round's evidence law.

---

## Register completeness

**All 10 named suppression call-sites were reached and adjudicated: 0
remain unadjudicated.** Category counts: 0 REAL DEFECT (confirmed), 2
UNDETERMINED (regionDiffEnumeration's 80-row bucket; the QL title-hinting
0-fire anomaly), 5 LEGITIMATE TEMPORARY, 3 LEGITIMATE PERMANENT (including
the dormant UI-target XCTSkip). **0 STALE suppressions were proven** — none
of the 10 sites could be shown, within this job's evidence standard (remove
the wrapper, show a hard pass, ideally across more than one run), to be
hiding an already-fixed defect. No code was removed as a result of this
audit; see the job report for why (the closest candidate, entry 2, needed
multiple reruns to distinguish "stale" from "genuinely intermittent," which
this job's time budget did not allow doing responsibly).
