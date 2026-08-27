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

## Restored helper surface (job 534/535)

The private-material strip deleted two shared test-infrastructure files
whole (`PixelOracleAppEngineTests.swift`, `MultipageMarginTests.swift`),
each `TestDocs/`-dependent top to bottom, breaking compilation for 8
surviving files that called into their enums. `PrivateCorpusSupport.swift`
restores ONLY the minimal surface those 8 files actually need
(`PixelOracleAppEngine.renderApp`/`renderEngine`/`rasterizePDF`,
`MultipageMargins.testDocsDirectory`) — not the deleted files' own test
methods, which either had hard (non-skippable) vacuity guards unsuited to
a public tree, or (for `MultipageMargins`) exercised its own multipage
pagination-budget oracle that no surviving file uses.

## Verifying this on a machine with the corpus

This gate's unarmed path (skip-cleanly) is verified by every CI/stranger
run of this repo. Its ARMED path — real reads succeeding, the vacuity
guards passing, every gated test actually exercising real documents — can
only be verified on a machine that has `TestDocs/` in-repo or a
`CTRLKD_PRIVATE_CORPUS` pointed at a real copy. It was not verified this
way as part of job 535 (no corpus was available in that job's environment)
and should be re-run once on a private-tree machine before this gate is
trusted long-term.
