# Testing this repo — corpus tiers

**Date:** 2026-09-06.

This project's tests are organized into three tiers, from "just works" to
"only the maintainer can run this."

## Privacy guard — one-time setup for every clone

This is the PRIVATE repo; nothing here may name a real machine, a real
home-directory path, or this repo's own name, because a squash snapshot of
(most of) this tree periodically becomes the PUBLIC soft-return repo. Run
once per clone:

```
tools/install-hooks.sh
```

This points `core.hooksPath` at the tracked `tools/githooks/` (pre-commit,
commit-msg, pre-push) so the privacy guard runs automatically on every
commit and push, rather than depending on someone remembering to run
`tools/audit_private.sh` by hand. The pattern itself lives in
`tools/private_patterns.sh` (shape-based -- see its own header comment);
`tools/audit_private.sh` runs the same pattern over the whole tracked
tree (decoding `*.base64`/`*.b64` fixtures first) and is what the release
checklist gates a public snapshot on. `tools/test_audit_private.sh` is
its regression test -- run it after touching either the pattern or the
audit script; it proves both a real leak still gets caught (plain text
AND base64) and that known-safe content (generic macOS folder examples,
placeholder paths, this repo's own private-only directories) does not.

## Tier 1 — bundled samples

Runs everywhere, no setup: `swift test` at the repo root exercises the
bundled samples and synthetic fixtures committed directly in this repo, and
`sr --samples DIR` writes the four bundled public-domain WordStar sample
documents into `DIR` for manual poking. Nothing here needs an environment
variable or an external download.

If your CI runner already runs under its own OS-level sandbox, `swift test`
can fail trying to nest a second one (SwiftPM sandboxes the subprocesses it
runs); pass `--disable-sandbox --cache-path <tmp> --config-path <tmp>
--security-path <tmp> --manifest-cache local` in that case.

## Tier 2 — the Sawyer WS7 archive

Robert J. Sawyer, the science fiction author, publishes his own WordStar 7
install tree as a historical/archival download:
<https://www.sfwriter.com/ws7.htm>. It is real, period WordStar content —
useful for validating parsing and round-tripping beyond what synthetic
fixtures can prove — and it is PUBLIC: filenames and paths from it may
appear directly in this repo's code, because the archive itself is a public
download, not personal material.

**Arming:**

```
CTRLKD_SAWYER_ARCHIVE=/path/to/the/archive swift test
```

`CTRLKD_SAWYER_ARCHIVE` names the archive's own top-level directory — the
one holding `CONVERT.WS`, `INSET/`, `ARTICLES/`, etc., directly (no wrapper
subdirectory) — exactly the directory you get by unzipping the archive
yourself. Nothing from it is copied into this repo.

**Verify your path before arming** — a one-liner that checks for the same
marker files the archive's own top level holds, and says which:

```
test -f "$CTRLKD_SAWYER_ARCHIVE/CONVERT.WS" \
  && test -d "$CTRLKD_SAWYER_ARCHIVE/INSET" \
  && test -d "$CTRLKD_SAWYER_ARCHIVE/ARTICLES" \
  && echo OK || echo "wrong directory -- point CTRLKD_SAWYER_ARCHIVE at the archive's own top level"
```

**Unarmed** (the variable is unset): every Tier-2 test reports a clean,
recorded Skip — never a silent pass, never a failure. This is the expected
shape for a normal checkout or a stranger's run.

**Armed**: every Tier-2 test runs for real, and a broken or incomplete copy
of the archive **fails loud**, naming the missing file — a corpus that's
present but wrong is a real bug, not something to wave through as a Skip.

The `macos/` app has its own Tier-2 gate (`OracleByteParityTests`,
`OutputParityTests`), armed the same way, run via `xcodebuild test`.

### `CorpusParityTests` — the engine's own full-corpus gate (planning #193, retired/rebuilt #205 Task 2)

Jon's ruling, planning #193, 2026-09-05, verbatim: "Sr on its own needs to
pass the same tests." ctrl-kd's public Sawyer tier (`pytest -m sawyer`, that
repo's own `tests/SAWYER-CORPUS.md`) converts every entry of its manifest and
checks it against recorded answers — source hash, convert+match oracle,
known-nonconvertible — with no app or Xcode involved. `Tests/CtrlKDTests/
CorpusParityTests.swift` is the Swift engine's equivalent, and it runs from
`swift test` alone.

**2026-09-06 (planning #205 Task 2): `TestDocs/oracle/python-printed-manifest.json`
and its generator, `macos/scripts/generate_printed_oracle_manifest.py`, are
RETIRED — deleted, not merely unreferenced.** That manifest walked the Sawyer
archive tree itself and recorded two PDF geometries (`bare`: no page-settings
override, no real `.PIX` resolution; `sawyer`: the `--page-settings sawyer`
preset plus real `.PIX` resolution) over a then-308-entry subset. Once
ctrl-kd's answer key grew to name the FULL public Sawyer corpus (planning
#205a — 385 convertible + 4 samples + 10 known-nonconvertible + 1
non-document asset, `AnswerKeyParityTests` below), its own `pdf.printed` cell
became a strict superset of the manifest's `bare` geometry (both are
`EmitOptions()` defaults; an empty `pixResults` renders any `.PIX` reference
as an identical placeholder on both sides) — so `bare` needed no replacement,
it is simply covered now, and `corpusBareByteParity` is gone. (An earlier,
2026-09-06 investigation — preserved in this file's git history — concluded
the OPPOSITE, because the answer key was 245 documents at the time; that
conclusion no longer holds once the key covers the full corpus.)

The `sawyer` geometry had no equivalent in the answer key (it never applies a
page-settings preset) and so had nowhere left to compare against once the
manifest was deleted. This suite now checks that ONE geometry against a NEW,
**self-recorded, not-truth** file instead:

- **`TestDocs/oracle/sawyer_preset_pdf_sr.json`** — generated by `swift run
  generate-sawyer-preset-drift-sr` (`Sources/GenerateSawyerPresetDriftSR/main.swift`),
  same honesty class as ctrl-kd's own answer key and this repo's
  `answer_key_sr.json` below: it records **sr's own** Printed-PDF output with
  `pagePresets["sawyer"]` applied and real `resolveDocumentPictures` against
  the live archive, over every document ctrl-kd's answer key names as
  Sawyer-convertible (385 — "re-based on the key's documents": the generator
  reads `tests/answer_key.json` purely as a doc/path list, the same list
  `AnswerKeyParityTests`/`generate-answer-key-sr` use, so the three files can
  never silently disagree about corpus scope). A mismatch here means **sr's
  own** rendering of this geometry has drifted since the file was last
  deliberately regenerated — it proves nothing about cross-engine
  correctness (that is `AnswerKeyParityTests`, over the bare geometry).
  Regenerate and review the diff for an intentional change; never hand-edit a
  cell.
- `corpusSawyerPresetPDFMatchesSelfRecorded(docName:)` — one test case per
  recorded document (385): checks the source file's sha256 against the
  recording (corpus drift), then re-renders and compares sha256 + byte count
  + per-image resolution STATE (not just the final hash — a placeholder
  substitution names itself instead of surfacing as an opaque sha diff).
- `pagePresets`/`resolveDocumentPictures` (`Sources/SoftReturnCLI/
  Arguments.swift`/`PixResolve.swift`) are `package`-visibility (not
  `internal`) specifically so this generator — a same-package, non-`@testable`
  executable target — can call them; still not part of the library's PUBLIC
  API.

Gated on `CTRLKD_SAWYER_ARCHIVE`, same as the rest of this tier — the
recorded file is committed in-repo (no `CTRLKD_SRC` needed to READ it), but
regenerating it needs `CTRLKD_SRC` too (to find ctrl-kd's answer key for the
doc list). Unarmed: `corpusParityGateIsArmed` is the one named, recorded Skip;
the parameterized test collapses to zero collected cases. Run just this
suite:

```
CTRLKD_SAWYER_ARCHIVE=/path/to/the/archive swift test --filter CorpusParity
```

Regenerate the self-recorded drift file after a deliberate engine change:

```
CTRLKD_SAWYER_ARCHIVE=/path/to/the/archive CTRLKD_SRC=/path/to/ctrl-kd/src \
  swift run generate-sawyer-preset-drift-sr
```

**macOS app side (2026-09-06):** `macos/SoftReturnTests/OracleByteParityTests.swift`
carried its own copy of the (now-deleted) manifest reader and a bundled-
`TestDocs/ws7`-scoped duplicate of this same check (`tier1BareByteParity`/
`tier1SawyerByteParity`), plus two tests asserting facts about that
manifest's own shape (`readmeBasenameCollisionResolvesToArchiveRoot`,
`imageResolutionMismatchIsReportedNotSilentlyPassed`) and a vacuity guard in
`PrivateCorpusSupport.swift` (`oracleManifestsAreNotEmptyWhenArmed`). All of
these were removed in the same commit that deleted the manifest — not left
to silently collapse to zero collected cases forever, which this repo
otherwise treats as a masked failure, not a legitimate skip. That file's
`unresolvableImageIsDetectedAsUnresolved` (exercises `DocumentPictures
.resolve`'s contract directly, never read the manifest) is unaffected.
`OutputParityTests` and its `output-manifest-v*.json` recordings were RETIRED
on 2026-09-07 (ONE answer key, Jon's ruling 2026-09-05): the app's export
bytes are asserted by `AppAnswerKeyParityTests` (macos/SoftReturnTests)
against ctrl-kd's `tests/answer_key.json` (via `CTRLKD_SRC`, drop-box key
`CTRLKD=1`) plus the private overlay — the same two files this package's
`AnswerKeyParityTests` use. A missing key or corpus is a NAMED skip, never a
pass.

### `AnswerKeyParityTests` — the ONE shared cross-engine answer key (planning #198/#195)

ctrl-kd replaced its two self-recorded oracles (`samples_oracle.json`, `sawyer_oracle.json`)
with a single shared answer key, `tests/answer_key.json` (`tools/answer_key.py`). As of
planning #205a (ctrl-kd `6741c10`, 2026-09-06, "the answer key covers the full Sawyer
corpus, not a hand-picked subset"): every public document — the 4 bundled samples + all 385
Sawyer-archive convertible documents, **389 total, the entire public corpus** — rendered
through EVERY registered format x EVERY mode (`<emitter>(doc, mode=mode)`, zero extra
keyword arguments, i.e. that engine's own library defaults), 12 cells/doc, **4668 cells
total**, plus the 10 known-nonconvertible documents (recorded refusal reason) and the one
non-document asset (`WORDSTAR.PIX`, source hash only) — `396` Sawyer-tree entries in all.
`Tests/CtrlKDTests/AnswerKeyParityTests.swift` is the Swift side of that SAME key — it reads
ctrl-kd's `tests/answer_key.json` directly (no Swift-side copy), reads its document lists
generically (no hardcoded count), and checks the Swift engine, called the identical way,
byte-for-byte over every one of the 4668 cells.

**Self-recorded, not truth (round 2026-09-07, the Modern-PDF-Symbol-fallback bug).**
This key detects DRIFT between the two engines and against ctrl-kd's own prior output --
it proves nothing about whether either engine is RIGHT. A rendering both engines agree on
is recorded once and compared forever after; if that rendering was wrong the day it was
recorded (as Modern PDF's `?`-for-Greek/Dingbats bug was, silently, until Jon read an
actual export), the key just enshrines the wrong answer -- both sides "pass" by matching
each other, not by being correct. Nothing in this suite, or in `tools/answer_key.py`, or
in the private overlay below, would ever have caught that bug on its own; it took a human
looking at a real PDF. The missing tier is a VIEWER-LEVEL check -- actually rendering a
cell and confirming what's on the page, not just hashing bytes against a prior hash of the
same engine's own bytes (planning #214, still open).

**Format map — ctrl-kd <-> sr** (both engines register EXACTLY these six; neither has a
format the other lacks, as of this writing — no DOCX emitter exists in this repo):

| ctrl-kd | sr | notes |
|---|---|---|
| `text` | `emitText` | alias `txt`, not a separate cell |
| `markdown` | `emitMarkdown` | alias `md`, not a separate cell |
| `html` | `emitHTML` | |
| `rtf` | `emitRTF` | |
| `pdf` | `emitPDF` | binary both sides; page count checked too |
| `layout` | `emitLayout` | `mode` accepted but ignored on both sides — `layout.printed`/`layout.modern` are byte-identical for every doc, by design |

**Options parity, proven not assumed:** every Swift emitter is called with a bare
`EmitOptions()`. Field-by-field, that is the SAME as ctrl-kd's zero-kwarg library defaults
(`fontsTarget: .office` == `fonts_target='office'`; `notes: .defaultNotes` ==
`DEFAULT_NOTE_KINDS`; `styles`/`noteRefs`/`headers`/`lineNumbers`/`toc`/`inlineStyling`/
`sentenceSpacing`/`pageSettings` all match) — see the test file's own header comment for the
full field-by-field account, including the one option (`pictures`) whose DEFAULT VALUE
differs between the two engines (`.embed` vs `'off'`) but whose OBSERVABLE BEHAVIOR is
identical here because neither side ever supplies a resolved picture result.

**Locating the key:** `$CTRLKD_SRC/../tests/answer_key.json` — `CTRLKD_SRC` (see
`PCLFidelityTests` above) names ctrl-kd's `src/`; the key is a sibling of `src/` at that
checkout's own `tests/`. Gated on `CTRLKD_SAWYER_ARCHIVE` like the rest of this tier
(the 4 samples need no archive, but are gated the same way for one uniform arming story).
Unarmed: `answerKeyGateIsArmed` is the one named Skip. Armed but the key file missing or
unparsable: **fails loud** — that is a broken environment, not a legitimate skip, same
doctrine as everywhere else in this tier. Run just this suite:

```
CTRLKD_SAWYER_ARCHIVE=/path/to/the/archive CTRLKD_SRC=/path/to/ctrl-kd/src \
  swift test --filter AnswerKeyParity
```

**Relationship to `CorpusParityTests`/`python-printed-manifest.json` — RETIRED 2026-09-06
(planning #205 Task 2), superseding the investigation below.** An earlier, 2026-09-06
investigation (preserved verbatim in this file's git history) concluded the two oracles
should be KEPT, not retired, because the answer key then covered only 245 documents against
the manifest's 308 — a real scope gap. Planning #205a closed that gap: the answer key now
covers the FULL public Sawyer corpus (389 convertible + 10 known-nonconvertible + 1
non-document asset = 396 entries), a strict superset of the manifest's old 308-entry,
documents-only scope. The manifest's `bare` geometry is therefore now fully covered by this
suite's own `pdf.printed` cell (both are `EmitOptions()` defaults, no page-settings, no real
pix resolution) and needed no replacement. Its `sawyer` geometry (a `page_settings` preset
this key never applies, plus real `.PIX` resolution) had nowhere left to compare against
once the manifest was deleted — `CorpusParityTests`'s own section, above, covers what
replaced it (a new self-recorded drift file, not a cross-engine truth check). See that
section for the full account; `python-printed-manifest.json` and
`macos/scripts/generate_printed_oracle_manifest.py` no longer exist in this repo.

### `TestDocs/oracle/answer_key_sr.json` — sr's own self-recorded oracle (drift only, not truth)

For a format sr registers that ctrl-kd does not (none as of this writing — DOCX is the named
future candidate), `AnswerKeyParityTests` has nothing to check against, since ctrl-kd's key
only covers formats ctrl-kd itself implements. `answer_key_sr.json` — generated by
`swift run generate-answer-key-sr` (`Sources/GenerateAnswerKeySR/main.swift`) — exists for
exactly that gap: SAME honesty class as ctrl-kd's own answer key (self-recorded, detects
THIS engine's own drift over time, never cross-engine truth), scoped to sr-only formats.
Currently `sr_only_formats` is `[]` and the file's `docs` grid is empty — a true, current
fact (sr has no format ctrl-kd lacks), not a stub. Regenerate after a sr-only format ships;
never hand-edit a cell.

## Tier 3 — maintainers-only private corpus

A separate, maintainers-only environment variable (`CTRLKD_PRIVATE_CORPUS`)
exists for the project author's own private corpus of real vintage
WordStar documents that cannot be redistributed. It has no effect unless
you are the maintainer with a copy of that corpus; everyone else can ignore
it entirely.

As of 2026-09-06 that corpus is a separate, private data repo (never named
here beyond this doc's own generic description) — `CTRLKD_PRIVATE_CORPUS`
points at its clone root, and its own README is the shape contract. This
repo's tests never read that clone in place: the maintainer-side test
target copies each fixture it needs into a temp directory first. Unarmed
(the variable unset, the normal shape for everyone reading this doc): every
Tier-3 test reports a clean, recorded Skip naming `CTRLKD_PRIVATE_CORPUS` —
never a failure. Armed: a broken or incomplete corpus fails loud, the same
law Tier 2 follows above.

### `PCLFidelityTests` — cross-checked against ctrl-kd's own PCL fidelity gate (planning #197)

Engine-Test-Finalization-Plan-2026-09-05, Task 1: ctrl-kd's `tools/pcl_tolerance.py` (the
font-class-tolerance, named-divergence gate behind ctrl-kd's own `pcl` pytest tier,
`tests/test_pcl_fidelity.py`) compares a Printed PDF against real WordStar 7 LaserJet
captures (`ws7-prints/v1/NAME.measurements.json`/`.pcl` under `CTRLKD_PRIVATE_CORPUS`) and
checks the result against a checked-in answer key, `tests/pcl_fidelity_manifest.json`, that
ctrl-kd itself commits. `Tests/CtrlKDTests/PCLFidelityTests.swift` runs that SAME gate over
THIS engine's own Printed PDF for every captured document, and checks two things per
document:

1. **Zero non-font-substitution divergences** — ctrl-kd's own bar for "clean" PCL
   fidelity. A document currently divergent for ctrl-kd fails here too, by name, printing
   every divergence line — this is a real, already-known bug (planning issue #202), not a
   test bug, and the test is meant to stay red for that document until the bug is fixed.
2. **sr's divergence set matches ctrl-kd's own recorded manifest entry for that document
   exactly** (same `counts_by_reason`, same named divergences). Since both engines are
   meant to produce byte-identical Printed PDFs (`CorpusParityTests`, above), this should
   always pass — a failure here means the two engines' Printed-PDF output has actually
   diverged for this document, a genuine cross-engine bug, not merely an unfixed
   WS7-fidelity gap.

**Tier size and inventory mode (planning #180 phase 2, "tests expanded", 2026-09-08).**
261 documents total: the original 18 (v1/v2/v3 captures, `capturedDocsV1V3` in the Swift
file) unchanged — both checks above apply exactly as written — plus 243 from ctrl-kd's
`ws7-prints/v4/` expansion (`capturedDocsV4`, 291 real captures minus 48 mail-merge files
that print empty by WordStar's own design). For the 243, check 1 is softened to
`withKnownIssue` (still runs, still names every divergence by document, does not fail the
filtered run) — untriaged, pending Jon's per-cause ruling, mirroring ctrl-kd's own
`pcl_tolerance.INVENTORY_MODE_DOCS`. **Check 2 is never softened, for any document** — a
cross-engine mismatch is the one thing this whole suite exists to catch. 64 of the 243 (the
private-corpus-group documents — jon-floppies/fixtures-ws5/ws7-private, named as
`<group>-v4-<NNN>` aliases) are committed in ctrl-kd's own PUBLIC manifest as content-free
`source-missing` placeholders (a real report can embed literal document text in
`divergences`, which must never enter that public repo) and are therefore skipped here too
(`withKnownIssue`, checked against `resolution["recorded"]["verdict"]` before ever running
check 2) — their real comparison only ever happens in this kind of locally-armed run,
never lands in ctrl-kd's committed file. First armed run against the full v4 corpus
(2026-09-08): 0 cross-engine (check 2) mismatches across all 261 documents — the two
engines still fully agree, including on the untriaged batch.

Neither this file nor its Python driver (`Tests/CtrlKDTests/Support/
run_pcl_fidelity_gate.py`) re-implements ctrl-kd's tolerance curves, font-tier table, or
divergence classification — every number comes from ctrl-kd's own `tools/pcl_tolerance.py`
and `tools/fidelity_gate.py`, run unmodified in a subprocess; the driver's own header
comment explains the one splice it performs (swapping in sr's PDF where
`pcl_tolerance.doc_report()` would otherwise render ctrl-kd's own).

**Locating ctrl-kd:** `CTRLKD_SRC` — the same variable `macos/scripts/
test_populate_oracle_pix_field.py` already uses, naming ctrl-kd's own `src/` directory
(its checkout root is that directory's parent) — or, if unset, a sibling checkout,
`../ctrl-kd` relative to this repo's own root. Neither found: the driver fails loud,
naming both paths tried, since a missing TOOL is an environment problem, distinct from an
unarmed corpus.

**Gating:** `CTRLKD_PRIVATE_CORPUS` only (same law as the rest of this tier) —
`pclFidelityGateIsArmed` is the one named, recorded Skip when it's unset. Armed, which
document names actually resolve to a real source is decided live by ctrl-kd's own
`fidelity_gate.resolve_doc_paths` (via `ws7-prints/v1/sources.json`, a capture->source
index in the corpus, still being completed as of this writing) — a document that doesn't
resolve yet reports a `withKnownIssue`, mirroring ctrl-kd's own `pytest.skip()` for a
`source-missing` verdict, never a hard failure. Run just this suite:

```
CTRLKD_PRIVATE_CORPUS=/path/to/the/corpus CTRLKD_SAWYER_ARCHIVE=/path/to/the/corpus/sawyer \
  CTRLKD_SRC=/path/to/ctrl-kd/src swift test --filter PCLFidelity
```

### `TestDocs/oracle/answer_key_private.json` — the PRIVATE answer-key overlay (planning #205b)

The private-corpus counterpart to `AnswerKeyParityTests`'s public `tests/answer_key.json`,
above. ctrl-kd cannot carry this key at all (it is a public repo; the private corpus must
never appear there) — it is generated and **committed in this repo instead**, at
`TestDocs/oracle/answer_key_private.json`, by `tools/answer_key_private.py`.

**Scope — three private-corpus groups** (`CTRLKD_PRIVATE_CORPUS`'s own layout, `docs/TESTING.md`
Tier 3 above):

- **`ws7-private/`** — 2 hand-built fixtures, `TESTING.WS` (ws5+) and `TESTING4.WS` (ws4).
  `README.md`/`TESTING4-README.md` are documentation about them, not corpus documents, and
  are excluded.
- **`jon-floppies/`** — every `.WS4` document, swept live (this directory grows as Jon adds
  floppy-derived papers; there is no committed manifest the way Sawyer has one) — 64 as of
  this writing. The `.TXT`/`.PRS`/`.BAK` siblings that directory's own README documents
  (copies, printstream captures, and genuine prior-revision backups) are excluded — they are
  not additional documents in this engine's sense. The engine detects each file's variant
  itself (`core.detect`/Swift `detect(_:)`, never forced): several of these `.WS4` files are
  structurally `printstream` (WS4 print-to-disk captures), not `ws4`, despite the shared
  extension — `detected_variant` is recorded per document specifically so this is visible,
  not papered over.
- **`fixtures-ws5/`** — the curated WS5+ fixture set: `.WS` (7) + `.TST` (4) = 11 files.
  `README.md`/`PROVENANCE.md` are documentation, excluded.

**Classification.** Every enumerated file gets exactly one of three buckets, decided by
actually running the engine (`core.detect` + `core.parse`), never assumed from its
extension: `convertible` (full 6-format x 2-mode cell grid, `sha256`/`bytes`/`pages`-for-pdf,
same shape as the public key), `known_nonconvertible` (the composed refusal message, same
equivalence ctrl-kd's own `KNOWN_NONCONVERTIBLE` values use), or `non_document_assets`
(source-hash only, reserved for a WORDSTAR.PIX-shaped case — none of the three groups
currently has one). As of this writing **all 77 private-corpus documents are convertible**
— `known_nonconvertible`/`non_document_assets` are empty for every group, a real finding
from actually running the engine, not an assumption baked into the schema.

**Reuse, not copy.** The cell-grid logic itself (`_grid`/`_cell`/`_sha256_file` — the actual
emit-and-hash work) is imported LIVE from ctrl-kd's own `tools/answer_key.py`
(`$CTRLKD_SRC/../tools/answer_key.py`), never duplicated. Everything else in
`tools/answer_key_private.py` (walking the three groups, classification, three-repo git
provenance) is new logic specific to this overlay.

**Determinism.** No wall-clock timestamps anywhere in the recorded JSON — provenance is
three repos' own `git rev-parse HEAD` / `git log -1 --format=%cI HEAD` (this repo, ctrl-kd,
and the private corpus, each scoped to the paths that actually matter for dirtiness
warnings). `--record` twice against the same tree produces byte-identical output (verified).

**Paths.** Every `path` field is relative to `CTRLKD_PRIVATE_CORPUS` itself (the corpus
root), e.g. `"jon-floppies/COLLEGE/CHART.WS4"`, `"ws7-private/TESTING.WS"` — this repo is
private, so committing these paths is fine (unlike anything destined for ctrl-kd or the
public `soft-return` repo).

**Two consumers of the same file:**

1. **`ctrlkd-private-tests/test_answer_key_private.py`** — ctrl-kd's own drift check: reads
   the committed JSON and re-renders every cell with the INSTALLED `ctrlkd` package (same
   import-path discipline as every other file in that directory), asserting byte-for-byte
   match plus a `detect()`-variant check and a live corpus re-walk that fails loud if a file
   has been added/removed since the key was last regenerated. Gated on `CTRLKD_PRIVATE_CORPUS`
   only (same fail-loud-when-unarmed law as the rest of that directory).
2. **`Tests/CtrlKDTests/AnswerKeyParityTests.swift`** — `AnswerKeyPrivateFixture` +
   `AnswerKeyParityPrivateTests`, appended to the same file as the public suite: sr checked
   against the SAME recorded cells (cross-engine parity on the private documents), plus the
   same known-nonconvertible/non-document-asset negative-checking shape as the public suite
   (both empty here, so those two parameterized tests report Swift Testing's own "no test
   cases found" — not a masked failure, just what a genuinely empty case list looks like).
   Gated on `ctrlkdPrivateCorpusArmed` (declared once in `PCLFidelityTests.swift`, reused
   here) — no `CTRLKD_SRC` needed to find the key itself (it's committed in-repo), only to
   locate a ctrl-kd checkout if you're regenerating it.

**Regenerating:**

```
CTRLKD_PRIVATE_CORPUS=/path/to/the/corpus CTRLKD_SRC=/path/to/ctrl-kd/src \
    python3 tools/answer_key_private.py --record   # rewrite the committed key
CTRLKD_PRIVATE_CORPUS=/path/to/the/corpus CTRLKD_SRC=/path/to/ctrl-kd/src \
    python3 tools/answer_key_private.py --check    # verify it's still current, no rewrite
```

## Test isolation guard (planning #191)

Planning issue #191: a real recorded Apple Event fixture, replayed through
the installed `convert` handler, carried a file alias to a real file under
the maintainer's home directory and no destination override — the app's own
"write beside the source" behavior then wrote an RTF beside that real file
on every full-suite run. Every test that used to read that fixture's
direct-object path unmodified, or read a private `ws4/` corpus
fixture as a convert/export source, now copies a bundled sample document
into a temp directory it owns first (`BundledSampleFixture.copy(_:into:)`
in `SoftReturnTests`) — see that type's own doc comment.

Two independent, redundant checks guard against this class of bug
recurring, neither of which depends on any one test's own fixture
discipline being right. Both watch only `~/Dropbox`, `~/projects`
(minus this repo's own checkout and build output), and non-hidden files
directly in `$HOME` — **not** `~/Documents`, `~/Desktop`, `~/Downloads`,
`~/Pictures`, `~/Movies`, or `~/Music`. Those six are TCC-protected on
macOS: first access to any of them from a non-interactive process pops a
permission dialog and blocks until a human clicks it. That dialog — not
disk I/O — was the entire 2889s (48 min) cost of the original guard's
whole-folder snapshot on the maintainer's real Mac (a second, warm pass
took 9.6s). A write landing in one of those six during a test run would
itself trigger that same blocking dialog, which *is* the alarm — a
silent stray write there isn't possible the way it is under Dropbox or
`~/projects`, so watching them added cost without adding coverage.
Neither guard snapshots a baseline anymore either: each records a single
time marker before the suite runs and, after, does one pass over the
watched roots comparing each file's modification/creation time against
that marker — cheap regardless of how much content sits under Dropbox.
Package/library bundles (`.photoslibrary`, `.app`, `.xcodeproj`, and
others — see the skip list in each implementation) are never descended
into, since Dropbox can hold these and their internal metadata is not a
place a stray document write would land.

A watched root that doesn't exist on the machine running the suite is
skipped, and named as skipped. A root that **exists but can't be
enumerated** (permissions, or anything else) is a **failure** naming that
root — neither guard is allowed to read "couldn't check" as "clean".
Both print, on every run, which roots were actually walked.

- **`HomeDirectoryWriteGuardTests.swift`** (in-process): a `.serialized`
  suite, run as part of the app test suite, over the roots described
  above.
- **`macos/scripts/test-isolation-gate.sh`** (external): wraps a
  test-running command and applies the same check to the same roots from
  outside the test process — catching a stray write from anything the
  wrapped command spawns as a subprocess, not just the test process
  itself. Usage:

  ```
  macos/scripts/test-isolation-gate.sh xcodebuild test \
    -workspace macos/SoftReturn.xcworkspace -scheme SoftReturn
  ```

  bash 3.2 / BSD `find` only (no associative arrays, no GNU-only flags) —
  it must run unmodified under the maintainer's real Mac shell.

`~/Dropbox` gets a narrower offender rule than `~/projects` and `$HOME`'s
top level, ruled 2026-09-05: the maintainer's own document edits on his
other devices sync into `~/Dropbox` *while a test run is in progress*, and
the old "any new non-hidden file" rule flagged that legitimate sync
traffic as a stray write. So under `~/Dropbox` only, a new or modified
file is an offender only when it has an extension this app's own
beside-source conversion output can carry (`rtf`, `pdf`, `txt`, `docx`,
`html`, `htm`, `md`, `odt`, case-insensitive) **and** a sibling file in
the same directory with the same name stem and extension `.ws` or `.WS`
— i.e. it looks like `BesideSourceWriter` just wrote a converted file
next to the WordStar document it came from, which is the app's actual
damage fingerprint for this bug class. A macOS duplicate-download name
like `report 2.rtf` still matches `report.ws`: a trailing space-and-digits
suffix is stripped from the stem before the sibling check. Both guards
implement this the same way — `test-isolation-gate.sh`'s
`is_dropbox_conversion_sibling`/`DROPBOX_CONVERTED_EXTS` and
`HomeDirectoryWriteGuardTests.swift`'s `isDropboxConversionSibling`/
`dropboxConvertedExtensions` — and must be kept in sync if either list
changes.
