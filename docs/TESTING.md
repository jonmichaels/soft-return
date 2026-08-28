# Testing this repo — the private-corpus gate

**Date:** 2026-08-27 (job 535).

## The short version

`TestDocs/` — a curated set of real WordStar documents (`ws4/`, `ws7/`,
`oracle/*.json` manifests) — ships in the PRIVATE canonical tree only
(`soft-return-app`). It is deliberately absent from this public tree (the
private-material strip, `41d858e`/`5d6b676`). Any test that reads it is
gated so that:

- **Unarmed** (no corpus available): the test **skips cleanly**. This is a
  documented, expected shape for a public checkout or a stranger's run —
  never a failure, never a silent pass either (see "Armed vs. unarmed"
  below for the failure-mode distinction).
- **Armed** (a corpus is available): the test **runs for real**, and a
  broken or partial corpus **fails loud**, exactly like any other assertion
  in this repo. A corpus that's present but wrong is a real bug, not
  something to wave through as a Skip.

The whole mechanism lives in one file:
`macos/SoftReturnTests/PrivateCorpusSupport.swift`.

## Arming it

Set `CTRLKD_PRIVATE_CORPUS` to a directory shaped like `TestDocs/` itself
(i.e. it contains `ws7/`, `ws4/`, and `oracle/` as its own subdirectories) —
for example, a copy of `TestDocs/` obtained out-of-band on a machine that
doesn't have it committed in-repo:

```
CTRLKD_PRIVATE_CORPUS=/path/to/a/TestDocs-shaped/directory xcodebuild test …
```

If the env var is unset, `PrivateCorpusSupport.testDocsRoot` falls back to
the in-repo `TestDocs/` directory if one exists — this is the PRIVATE
canonical tree's own shape, and it keeps running completely unchanged, with
no env var required, exactly as it always has.

This is the same env var name (`CTRLKD_PRIVATE_CORPUS`) the engine repo's
own private-corpus gate uses (`Tests/CtrlKDTests/WSChangeTests.swift`) and
this app's own pre-existing Tier-2 full-archive gate uses
(`OracleByteParityTests.corpusRoot`/`OutputParityTests.corpusRoot`) — one
variable arms every private-corpus gate at once. Note those Tier-2 gates
point at a DIFFERENT, much larger, never-committed-anywhere corpus (the
full Sawyer archive, 2,257+ files) than this one (the small, curated
`TestDocs/` tree) — same variable, differently-shaped target directory.

## How a test is gated

- **Parameterized tests** (`@Test(arguments: someFixtureList)`): the
  fixture-list property (e.g. `ws7Fixtures`) resolves through
  `PrivateCorpusSupport` and degrades to `[]` when unarmed via `try?` — an
  empty argument list means zero test cases, which Swift Testing reports as
  a clean Skip. No test body ever runs unarmed.
- **Fixed (non-parameterized) tests**: gated directly with the
  `.enabled(if:)` trait — `@Test(.enabled(if: PrivateCorpusSupport.isArmed,
  PrivateCorpusSupport.skipReason))`. When every test in a `@Suite` depends
  on the corpus, the trait is applied once at the `@Suite` level instead of
  repeating it on every method.
- **Armed-mode vacuity guard**: `PrivateCorpusArmedVacuityGuardTests` (in
  `PrivateCorpusSupport.swift`) is the one place that checks the raw
  `TestDocs/ws7`, `TestDocs/ws4`, and `TestDocs/oracle/*.json` directly and
  fails loud if armed produces nothing — the necessary counterpart to every
  other gate's `try?`-degrades-to-`[]` shape, which would otherwise also
  swallow a genuinely broken/partial corpus while armed into the same
  silent-empty shape a missing corpus produces.

## Restored helper surface (job 534/535, superseded — job 536)

The private-material strip deletes two shared test-infrastructure files
whole (`PixelOracleAppEngineTests.swift`, `MultipageMarginTests.swift`) in
any PUBLIC-only tree, each `TestDocs/`-dependent top to bottom. Job 535
restored a minimal `PixelOracleAppEngine`/`MultipageMargins` shim in
`PrivateCorpusSupport.swift` for that public tree specifically, since
several surviving public/sawyer-armed files still call those two types
(`TitleAscenderTests`, `PrintedStructuralParityTests`,
`MultipageMargins.testDocsDirectory`'s six callers). **This tree carries
that shim** — it is a public-only snapshot.

The private canonical tree does not need the shim: that strip never
happens there, so both full original files are present unmodified. Job
536 found the job-535 shim colliding with them when both were present in
the same tree (duplicate declarations of the same two types, a genuine
compile break) and deleted it there; `PixelOracleAppEngineTests.swift`'s
own enum is a superset of what the shim offered, and
`MultipageMarginTests.swift`'s `testDocsDirectory` forwards to
`PrivateCorpusSupport.testDocsDirectory` directly instead of duplicating
it (fixing a real bug along the way — its own standalone `#filePath` walk
never honored `CTRLKD_PRIVATE_CORPUS` at all). Any public-only snapshot
that needs the shim restores it from git history rather than carrying it
permanently in the private tree.

## Verifying this on a machine with the corpus

This gate's unarmed path (skip-cleanly) is verified by every CI/stranger
run of this repo. Its ARMED path was verified for real by job 536, on this
private-tree machine:

- **Explicit `CTRLKD_PRIVATE_CORPUS` pointed at the in-repo `TestDocs/`**
  (via the generated scheme's Test-action environment — command-line
  `VAR=x xcodebuild test` is blocked in that job's own sandbox) produced
  identical results to the unset/fallback path: gated tests RUN (never
  skip), the vacuity guards pass, `PixelOracleAppEngineTests` runs its
  full region-diff enumeration for real.
- **A deliberately incomplete corpus** (a scratch copy with exactly one
  `ws7/` file and empty `ws4/`/`oracle/` directories) FAILS LOUD, never
  skips the run as a whole: `PrivateCorpusArmedVacuityGuardTests` names
  exactly what's missing (`"vacuity guard: armed but TestDocs/ws4
  produced zero fixtures"`, `"...TestDocs/oracle/python-printed-
  manifest.json parsed to zero entries"`), and tests that read a specific
  missing file throw a real, named `NSCocoaErrorDomain Code=260` ("no such
  file") rather than swallowing it. One nuance worth knowing: a handful of
  *individual* `@Test(arguments:)` methods whose own argument list comes
  from the (now-empty) oracle manifest — e.g. `OracleByteParityTests
  .tier1BareByteParity` — still report "skipped: No test cases found" for
  themselves specifically, exactly the `try?`-degrades-to-`[]` shape this
  file's own doc comments already name as the reason
  `PrivateCorpusArmedVacuityGuardTests` has to exist as a separate,
  always-armed-checked suite: it is the one guaranteed to turn the overall
  run red when a corpus is present but broken, even though a few
  individual parameterized methods downstream of the SAME missing data
  degrade to a clean-looking skip on their own.
