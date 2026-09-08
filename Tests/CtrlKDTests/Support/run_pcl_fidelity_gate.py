#!/usr/bin/env python3
"""Driver for `PCLFidelityTests.swift` (planning #197, Engine-Test-Finalization-Plan
Task 1, sr half): runs ctrl-kd's OWN `tools/pcl_tolerance.py` (the font-class-tolerance,
named-divergence gate behind ctrl-kd's `pcl` pytest tier) against a Printed PDF that a
DIFFERENT engine (sr, this repo's own Swift/`CtrlKD`) rendered for the same document —
never re-implementing the tolerance model or the divergence classification here. This
file only does two things ctrl-kd's own tools don't already do: (1) tell the Swift side
which document names resolve to a real `.WS`/`.WS4` source in the current corpus, so it
knows what to render, and (2) splice a caller-supplied PDF into ctrl-kd's own
`pcl_tolerance.doc_report()` in place of the PDF that function would otherwise render
with ctrl-kd's own (Python) engine.

WHY A SPLICE, NOT A NEW TOOL. `tools/fidelity_gate.py` already documents this exact use
("the Swift/sr side reuses this tool without a second implementation of the whole gate",
see its own `--pdf` flag) for the RAW coordinate comparison. But the font-class
tolerances, the checked-in named-divergence manifest, and the exact "clean" vs
"divergent" verdict this test needs to compare against
(`tests/pcl_fidelity_manifest.json`) all live one layer up, in `tools/pcl_tolerance.py`'s
`doc_report()` — which does not (yet) take a `--pdf` flag of its own. `doc_report()`
calls `fidelity_gate.render_engine_pdf(ws_path)` through the `fidelity_gate` MODULE
OBJECT (`fg.render_engine_pdf(...)`, not a locally-bound reference), so replacing that
one attribute before calling `doc_report()` is enough to make every tolerance/manifest
computation downstream run over the substituted PDF's own bytes — the same tolerance
curves, the same font-tier table, the same divergence reasons ctrl-kd's own `pcl`
pytest tier uses, unmodified and unforked. Neither ctrl-kd file is edited to make this
work (this repo does not touch ctrl-kd at all, per this repo's own CLAUDE.md) — the
splice happens entirely on this side of the process boundary, inside a subprocess this
script owns.

WHY `--engine-words`, NOT JUST `--pdf`, FOR THE APP. ctrl-kd's own PDF-parsing splice
above only works when the supplied PDF's content streams are something `tools/
fidelity_gate.py`'s own `parse_text_ops` can read at all. As of ctrl-kd's mechanism Z
(2026-09-07, `tools/PCL-DIVERGENCE-TRIAGE.md`), that function is a small content-stream
STATE MACHINE (`Tf`/`Tz`/`Ts`/`Tr`/`w`/`Td`/`TD`/`Tm`/`T*`/`Tj`/`TJ`/`'`/`"`, any operand
order — it replaced an earlier regex, `_TEXT_OP_RE`, keyed to one fixed order), not a
general PDF interpreter: it still has no notion of a subset/CID font's own glyph-index
string bytes. The app's Printed view is AppKit/Quartz (`ExportEngine.render(...
viewStyle: .native)`, the Cmd-P facsimile pass, deliberately NOT the library path — see
`AppPCLFidelityTests.swift`'s own header for why re-measuring the engine would defeat
the whole point of that suite), which positions text with `Tm` and draws it with `TJ`
arrays over embedded SUBSET fonts whose string bytes are glyph indices, not characters
— `parse_text_ops` cannot turn those back into words at all, so every WS7 word
extracts as "no corresponding word anywhere in the engine output" and the tier reports
thousands of false rendering defects (see `docs/KNOWN-ISSUES-REGISTER.md`'s "Gate 2"
entry, and the `AppPCLFidelityTests.swift` `Issue.record` this replaces). Jon's ruling
(planning task, 2026-09-07): ctrl-kd gained a documented, PRE-EXTRACTED "engine-words" JSON schema
(`tools/fidelity_gate.py`'s own "engine-words (JSON)" comment block, above
`dump_engine_words()`) plus `pcl_tolerance.doc_report(doc_name, engine_words=...)` —
so this script can hand ctrl-kd ALREADY-EXTRACTED word positions instead of PDF bytes,
skipping the incompatible-parser step entirely, with the tolerance model/reason
vocabulary/manifest comparison unmodified either way. This is a STRAIGHT CALL
(`pt.doc_report(doc_name, engine_words=data)`), not a splice — `doc_report()` takes the
parameter directly, no monkeypatch needed.

THE APP-SIDE SCHEMA (what the Swift side must produce). One JSON object:

    {
      "schema_version": 1,
      "n_pages": <int>,             # total page count, INCLUDING blank/image-only pages
      "words": [ <word>, ... ],
      "rasters": [ <raster>, ... ] # [] if the document has no picture
    }

Each <word>:

    {
      "text": <str>,        # the word's own literal text, no surrounding whitespace,
                             # punctuation left attached exactly as PDFKit's own word
                             # selection would give it (WS7's own chunking never splits
                             # on punctuation either — see ctrl-kd's `_TOKEN_RE`)
      "x_pt": <float>,      # LEFT edge of the word's first glyph, PAGE-LOCAL points,
                             # origin at the page's own TOP-LEFT, x rightward
      "y_top_pt": <float>,  # the word's own BASELINE, PAGE-LOCAL points, measured DOWN
                             # from the page's own TOP edge (y increases DOWNWARD)
      "size_pt": <float>,   # nominal font size in points
      "font": <str|null>,   # the word's own font/BaseFont name, unresolved (a PDF
                             # subset name like "ABCDEF+Helvetica" is fine as-is)
      "font_class": <str>,  # REQUIRED, one of "serif"/"sans"/"fixed"/"symbol"/"unknown"
                             # — NOT derived by ctrl-kd's loader (a subset/system font
                             # name can't be reliably reclassified by its own base-14
                             # prefix heuristic), so THIS SIDE must supply it directly:
                             # Courier/any monospace face -> "fixed", Times/a serif body
                             # face -> "serif", Helvetica/Arial/a sans face -> "sans",
                             # Symbol/ZapfDingbats/Wingdings -> "symbol"
      "page": <int>         # 1-indexed page number this word is on
    }

Each <raster> (an embedded picture's own drawn box, if this document has one):

    {
      "x_pt": <float>, "y_top_pt": <float>,  # box's own LEFT/TOP edge, page-local points
      "w_pt": <float>, "h_pt": <float>,      # drawn width/height, points
      "page": <int>
    }

GETTING TO THIS FROM PDFKIT. `PDFPage.selection(for:)`/word-level `PDFSelection` API
gives word bounds as `PDFSelection.bounds(for: page)`, a `CGRect` in PDFKit's PAGE
SPACE — points, origin at the page's own BOTTOM-LEFT (PDF's native convention, same as
raw PDF `Td`/`Tm` y). Converting to this schema's own top-down convention, for a page
of height `pageHeightPt`:

    y_top_pt = pageHeightPt - selectionBounds.origin.y   // BASELINE, not the box's own
                                                          // bottom edge -- see below
    x_pt     = selectionBounds.origin.x

`PDFSelection`'s own bounds are the glyph BOX (ascent+descent), not the baseline — ctrl-kd's
own convention (`fg.engine_page_tokens`'s `y_top`, matching WS7's own PCL cursor
position) is the BASELINE specifically. Use `CGPDFScanner`/`CGPDFContentStream` (Core
Graphics, not PDFKit's selection API) to read the actual `Tm`/`TJ` operands directly if
sub-point baseline accuracy matters more than PDFKit selection's own descent
approximation — worth checking against a document with a KNOWN WS7 baseline (any
already-clean document, e.g. BOXES) before trusting either path at the tolerances this
gate enforces (`tools/pcl_tolerance.py`'s `BASELINE_EPS_PT`/`EXACT_EPS_PT`, sub-1pt).

WHY --engine-chars, NOT WORD-SPLITTING ON THE APP SIDE. `--engine-words` (above) still
asks the app to decide WHERE one word ends and the next begins before it ever reaches
ctrl-kd — and the app's first attempt at that (AppPDFWordsScanner's own re-implementation
of mechanism Z's own word-boundary rule, against Quartz's real /Widths-derived glyph
advances over subset fonts) regressed. Jon's ruling, 2026-09-07: an external PDF reader
hands ctrl-kd raw CHARACTERS, and ctrl-kd does the word segmentation itself, in ONE
place, for both sides of the fidelity gate — so this repo's own extractor should stop
trying to find word boundaries at all. ctrl-kd gained a documented, PRE-EXTRACTED
"engine-chars" JSON schema, one level lower than "engine-words" (`tools/fidelity_gate.py`'s
own "engine-chars (JSON)" comment block, above `dump_engine_chars()`) plus
`pcl_tolerance.doc_report(doc_name, engine_chars=...)` — this script's own `--engine-chars`
flag (below) is a straight pass-through to it, same shape as `--engine-words`.

THE APP-SIDE CHARS SCHEMA (what the Swift side should produce instead, going forward):
one JSON object, `chars` in place of `words`:

    {
      "schema_version": 2,
      "n_pages": <int>,
      "chars": [ <char>, ... ],
      "rasters": [ <raster>, ... ]   // IDENTICAL shape to the words schema's own raster
    }

Each <char> — exactly ONE glyph, no segmentation decision at all:

    {
      "text": <str>,        // exactly one Unicode scalar (a literal space " " is a real
                             // character here, not omitted — ctrl-kd treats it as the
                             // word-boundary signal it always was)
      "x_pt": <float>,      // this glyph's own advance START, page-local points, origin
                             // at the page's own TOP-LEFT, x rightward (same convention
                             // as the words schema's own x_pt)
      "x_end_pt": <float>,  // this glyph's own advance END — x_pt PLUS however far this
                             // ONE character actually moved the pen. MUST be the ADVANCE
                             // end (the font's own /Widths or /W entry for the glyph
                             // Quartz actually drew, i.e. CGPDFScanner's own Tj/TJ
                             // operand math, or PDFKit's per-glyph advance if it exposes
                             // one), NEVER the glyph's ink/bounding-box end — ctrl-kd
                             // measures the GAP since the previous character's own
                             // x_end_pt to decide where a word boundary falls, so a
                             // glyph-box width (which can overshoot or undershoot the
                             // true advance) can flip that decision either way.
      "y_top_pt": <float>,  // this glyph's own BASELINE, page-local points, down from the
                             // page's own top edge — same convention as the words
                             // schema's own y_top_pt. NO Ts-equivalent rise applied: a
                             // superscript/subscript character reports its own TRUE
                             // baseline, not a lifted one.
      "size_pt": <float>,   // nominal font size in points
      "font": <str|null>,   // same meaning as the words schema's own "font" — nullable;
                             // word-boundary math never needs it once font_class (below)
                             // is given
      "font_class": <str>,  // REQUIRED, same vocabulary as the words schema's own
                             // font_class ("serif"/"sans"/"fixed"/"symbol"/"unknown") —
                             // still supplied by THIS side, never re-derived by ctrl-kd
      "page": <int>         // 1-indexed page number
    }

No "tz"/horizontal-scale field: ctrl-kd's own `load_engine_chars()` applies its
word-boundary caps directly in page points, on the assumption that `x_pt`/`x_end_pt`
already carry whatever scale Quartz applied to produce them — see that function's own
TOLERANCE note in `tools/fidelity_gate.py` for the exact reasoning and the corpus-wide
evidence backing it.

WHAT THIS BUYS THE APP SIDE. No word-boundary logic at all: walk every glyph run
CGPDFScanner/CGPDFContentStream hands back, emit one <char> per glyph with its own
real advance and baseline, and let ctrl-kd's own `segment_words_from_chars` (the SAME
function the ops-based/engine-words paths already call) decide where the words are.
This is strictly less work than `--engine-words` (no font-substitution-aware space-glyph
cap, no zero-gap cross-font merge, no superscript-in-a-word rule to reimplement) and
cannot drift from ctrl-kd's own rule, because it never re-derives it.

LOCATING CTRL-KD. `CTRLKD_SRC` (an env var this repo's other Python helper scripts
already use — see `macos/scripts/test_populate_oracle_pix_field.py`) names ctrl-kd's own
`src/` directory (the one holding the `ctrlkd` package); ctrl-kd's checkout root is that
directory's parent, and `tools/`, `tests/` sit alongside `src/` at that root. If
`CTRLKD_SRC` is unset, this script falls back to a sibling checkout, `../ctrl-kd`
relative to THIS repo's own root (the layout every machine that runs this suite is
documented to use — this repo and ctrl-kd sit side by side under the same parent
directory). Neither found: fails loud, naming both paths it tried — never a silent
skip, because a missing tool is an environment problem, not a "corpus not armed" one.

CORPUS ENV VARS. `CTRLKD_PRIVATE_CORPUS` / `CTRLKD_SAWYER_ARCHIVE` are read by ctrl-kd's
own `tools/fidelity_gate.py` / `tools/pcl_tolerance.py` at import time, straight from the
process environment — this script does not read, validate, or forward them itself; it
just imports those modules and lets them do what they already do. Unset: `report`
returns `resolvable: false` for every document (ctrl-kd's own resolution fails the same
way it would for a bare `pytest -m pcl` run) — the Swift caller turns that into a named
skip.

USAGE (see PCLFidelityTests.swift for the actual call sites)
-------------------------------------------------------------
    # Phase 1 -- ask whether NAME resolves to a real source in the current corpus, and
    # fetch ctrl-kd's own recorded manifest entry for it (no PDF needed yet). `--doc`,
    # never a bare positional -- some captured names (-README, -SCREEN) start with a
    # literal hyphen, so `=` is required: `--doc -README` would be parsed as two options.
    python3 run_pcl_fidelity_gate.py report --doc=NAME

    # Phase 2 -- splice IN a PDF (sr's own Printed-mode render for the same NAME) and
    # get ctrl-kd's live tolerance-classified report for it, plus the comparison against
    # the recorded manifest entry ctrl-kd committed:
    python3 run_pcl_fidelity_gate.py report --doc=NAME --pdf /tmp/sr-NAME-printed.pdf

    # Phase 2, engine-words variant -- for a renderer whose PDF ctrl-kd's own parser
    # cannot read at all (the app's AppKit/Quartz Printed view; see "WHY --engine-words,
    # NOT JUST --pdf" above): pass a PRE-EXTRACTED words JSON (this file's own schema,
    # documented above) instead of a PDF. Same report shape either way.
    python3 run_pcl_fidelity_gate.py report --doc=NAME --engine-words /tmp/app-NAME-words.json

    # Phase 2, engine-chars variant -- one level lower than --engine-words: pass
    # PRE-EXTRACTED CHARACTERS (this file's own chars schema, documented above under
    # "WHY --engine-chars") instead of already-segmented words, so ctrl-kd does mechanism
    # Z's own word-boundary decision itself. Same report shape either way.
    python3 run_pcl_fidelity_gate.py report --doc=NAME --engine-chars /tmp/app-NAME-chars.json

`--pdf`, `--engine-words`, and `--engine-chars` are pairwise mutually exclusive. All
phases print one JSON object to stdout; nothing is ever written back into ctrl-kd's own
tree (`tests/pcl_fidelity_manifest.json` is read, never regenerated, from here).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Tests/CtrlKDTests/Support/run_pcl_fidelity_gate.py -> repo root is three levels up --
# same arithmetic CorpusParityManifest.url (CorpusParityTests.swift) uses for the same
# reason: a fixed, documented path within THIS repo's own checkout.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


class CtrlKDNotFound(SystemExit):
    def __init__(self, tried):
        lines = '\n'.join(f'  - {p}' for p in tried)
        super().__init__(
            'run_pcl_fidelity_gate: could not locate the ctrl-kd checkout. Set '
            'CTRLKD_SRC to ctrl-kd\'s own src/ directory (same variable '
            'macos/scripts/test_populate_oracle_pix_field.py already uses), or check '
            'out ctrl-kd as a sibling of this repo (../ctrl-kd). Tried:\n' + lines)


def resolve_ctrlkd_root() -> str:
    """ctrl-kd's checkout root -- the directory holding `tools/`, `tests/`, `src/` --
    via CTRLKD_SRC (ctrl-kd's src/ dir; root is its parent) or, if unset, the documented
    sibling-checkout fallback `../ctrl-kd`. Fails loud, naming every path tried, if
    neither holds a real ctrl-kd checkout (probed by `tools/fidelity_gate.py`'s
    presence -- the one file every phase of this driver needs)."""
    tried = []
    env = os.environ.get('CTRLKD_SRC')
    if env:
        env = env.rstrip('/')
        root = os.path.dirname(env) if os.path.basename(env) == 'src' else env
        tried.append(f'{root} (from $CTRLKD_SRC={env})')
        if os.path.isfile(os.path.join(root, 'tools', 'fidelity_gate.py')):
            return root
    else:
        sibling = os.path.normpath(os.path.join(REPO_ROOT, '..', 'ctrl-kd'))
        tried.append(f'{sibling} (CTRLKD_SRC unset -- sibling-checkout fallback)')
        if os.path.isfile(os.path.join(sibling, 'tools', 'fidelity_gate.py')):
            return sibling
    raise CtrlKDNotFound(tried)


def _load_ctrlkd_modules():
    root = resolve_ctrlkd_root()
    tools_dir = os.path.join(root, 'tools')
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    import fidelity_gate as fg  # noqa
    import pcl_tolerance as pt  # noqa
    return fg, pt


# `font-substitution` is the one reason `pcl_tolerance.doc_report()`'s own docstring
# names as accepted-by-rule (see that file's module docstring and `test_pcl_fidelity.py`'s
# `real_bugs` filter) -- no `add(...)` call site in ctrl-kd currently uses that literal
# string, so today this filters nothing out, but the check is kept here, matching
# ctrl-kd's own test, so this driver and ctrl-kd's `pcl` pytest tier read a fixed set of
# divergences as "real" the same way if that ever changes.
ACCEPTED_REASON = 'font-substitution'


def _divergence_line(d: dict) -> str:
    # Verbatim format of tests/test_pcl_fidelity.py's own failure-message line, so a
    # human reading a Swift test failure and a `pytest -m pcl` failure for the same
    # document sees the same shape.
    return (f"[{d['reason']}] page {d['page']} words={d['words']} "
            f"ws7={d['ws7_pos']} pdf={d['pdf_pos']} font_class={d['font_class']} -- "
            f"{d['detail']}")


def _summarize(report: dict) -> dict:
    counts = report.get('counts_by_reason', {})
    # `real_bug_count` MUST come from `counts_by_reason` (ctrl-kd's own exact per-reason
    # totals), never from `len(divergences)` -- `doc_report()` caps the `divergences`
    # LIST at MAX_LISTED_PER_REASON (40) entries per reason so the checked-in manifest
    # stays reviewable, but `counts_by_reason` always carries the true total (see that
    # function's own docstring). A document with more than 40 divergences for one reason
    # (DOCC's 83 `exact-drift` entries, seen while developing this driver) would
    # otherwise silently under-report by the amount the cap trimmed.
    real_bug_count = sum(v for reason, v in counts.items() if reason != ACCEPTED_REASON)
    divergences = report.get('divergences', [])
    real = [d for d in divergences if d['reason'] != ACCEPTED_REASON]
    lines = [_divergence_line(d) for d in real[:15]]
    if real_bug_count > len(lines):
        lines.append(f'... and {real_bug_count - len(lines)} more '
                     f'(see tests/pcl_fidelity_manifest.json)')
    return {
        'verdict': report.get('verdict'),
        'counts_by_reason': counts,
        'real_bug_count': real_bug_count,
        'divergence_lines': lines,
    }


def cmd_report(doc_name: str, pdf_path: str | None, engine_words_path: str | None = None,
               engine_chars_path: str | None = None) -> dict:
    fg, pt = _load_ctrlkd_modules()
    recorded = pt.load_manifest()['documents'].get(doc_name)

    # Resolvability is decided ENTIRELY by ctrl-kd's own `fg.resolve_doc_paths` (the
    # same function `pcl_tolerance.doc_report()` calls first) -- no separate
    # "known missing" table is duplicated here on purpose: which documents resolve is
    # a fact about the corpus (ws7-prints/v1/sources.json, or the older group-search
    # fallback fidelity_gate.py keeps for a corpus without that index yet), not
    # something this driver should hardcode and risk drifting from ctrl-kd's own
    # resolution as that corpus index gains entries.
    ws_path, _measurements_path, _pcl_path = fg.resolve_doc_paths(doc_name)
    if ws_path is None:
        return {'doc': doc_name, 'resolvable': False,
                'reason': f'${fg.ARCHIVE_ENV} unset (Sawyer-archive-only document)',
                'recorded': recorded}
    if not os.path.exists(ws_path):
        return {'doc': doc_name, 'resolvable': False,
                'reason': f'source not found at {ws_path}', 'recorded': recorded}

    if pdf_path is None and engine_words_path is None and engine_chars_path is None:
        # Phase 1: resolvable, but nothing to compare yet -- the caller renders its own
        # engine's PDF (or extracts its own words/chars JSON) for `ws_path` next, then
        # calls again with --pdf, --engine-words, or --engine-chars.
        return {'doc': doc_name, 'resolvable': True, 'ws_path': ws_path, 'recorded': recorded}

    if engine_chars_path is not None:
        # No splice needed here -- doc_report() takes pre-extracted characters directly
        # (see "WHY --engine-chars" above). Ctrl-kd validates the JSON shape itself
        # (fg.load_engine_chars); a malformed file surfaces as that function's own
        # KeyError/ValueError, uncaught here on purpose -- same discipline as
        # --engine-words, below.
        engine_chars = json.load(open(engine_chars_path))
        live = pt.doc_report(doc_name, engine_chars=engine_chars)
    elif engine_words_path is not None:
        # No splice needed here -- doc_report() takes pre-extracted words directly (see
        # "WHY --engine-words, NOT JUST --pdf" above). Ctrl-kd validates the JSON shape
        # itself (fg.load_engine_words); a malformed file surfaces as that function's own
        # KeyError/ValueError, uncaught here on purpose -- a schema mismatch on the app
        # side should fail loud, not be swallowed into a false "0 divergences."
        engine_words = json.load(open(engine_words_path))
        live = pt.doc_report(doc_name, engine_words=engine_words)
    else:
        pdf_bytes = open(pdf_path, 'rb').read()
        fg.render_engine_pdf = lambda _ws_path: pdf_bytes  # the splice -- see module docstring
        live = pt.doc_report(doc_name)

    matches_recorded = recorded is not None and live == recorded
    result = {
        'doc': doc_name, 'resolvable': True, 'ws_path': ws_path,
        'live': _summarize(live), 'recorded': _summarize(recorded) if recorded else None,
        'matches_recorded': matches_recorded,
    }
    if not matches_recorded:
        result['mismatch_detail'] = (
            'no recorded manifest entry for this document' if recorded is None
            else f"live counts_by_reason {live['counts_by_reason']} != "
                 f"recorded counts_by_reason {recorded['counts_by_reason']}")
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    rep = sub.add_parser('report')
    # `--doc`, never a bare positional: several captured document names start with a
    # literal hyphen (`-README`, `-SCREEN` -- real ctrl-kd/Sawyer-archive names, not a
    # typo), which argparse would otherwise parse as an unrecognized OPTION rather than
    # the positional's value. `--doc=-README` (an explicit `=`, required for an argparse
    # option value that itself starts with `-`) sidesteps that; `--doc -README` does not.
    rep.add_argument('--doc', required=True)
    rep.add_argument('--pdf')
    rep.add_argument('--engine-words', help='pre-extracted engine-words JSON (this file\'s '
                     'own schema, documented above) instead of a PDF -- for a renderer '
                     '(e.g. the app\'s AppKit/Quartz Printed view) whose PDF ctrl-kd\'s own '
                     'parse_text_ops cannot read at all. Mutually exclusive with --pdf/'
                     '--engine-chars.')
    rep.add_argument('--engine-chars', help='pre-extracted engine-chars JSON (this file\'s '
                     'own schema, documented above under "WHY --engine-chars") -- raw '
                     'characters, one level lower than --engine-words, so ctrl-kd does '
                     'mechanism Z\'s own word-boundary decision itself instead of the '
                     'producer re-implementing it. Mutually exclusive with --pdf/'
                     '--engine-words.')
    a = ap.parse_args(argv)

    if a.cmd == 'report':
        if sum(bool(x) for x in (a.pdf, a.engine_words, a.engine_chars)) > 1:
            ap.error('--pdf, --engine-words, and --engine-chars are mutually exclusive')
        print(json.dumps(cmd_report(a.doc, a.pdf, a.engine_words, a.engine_chars), indent=2))
        return 0
    ap.error(f'unknown command {a.cmd!r}')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
