#!/usr/bin/env python3
"""ORPHANED (planning #205 Task 2, 2026-09-06): its sole target,
TestDocs/oracle/python-printed-manifest.json, was retired the same commit --
this script has nothing left to populate. Kept only as a record of how that
manifest's "pix" field was generated; never run it against a real tree again.

Populate TestDocs/oracle/python-printed-manifest.json's per-document "pix"
record: for every document, which .PIX tags it carries (doc.graphics) and
whether each resolved against the real archive tree at generation time.

WHY THIS EXISTS (2026-08-22): the manifest records bytes/sha256/pages/
structure_sha256 per document per geometry cell, but nothing about whether
that document's images actually resolved when those bytes were produced.
A regeneration run detached from the document's real directory (a relocated
copy, a different CWD) makes ctrl-kd/sr silently render the ruled
placeholder instead of the real image -- correct, non-failing behavior per
the register -- and the resulting bytes look perfectly plausible. Frozen
into the oracle, that placeholder becomes "ground truth" forever, and any
future CORRECT run (image really resolves) would then read as a diff
against the oracle instead of the fix it is. This already produced one
false alarm during a same-day oracle refresh (job bf6408e): a control
fixture rendered from a detached copy came back with a placeholder, and an
agent briefly read that as evidence the whole oracle was stale.

One "pix" key is added PER FILE ENTRY (a sibling of "bare"/"sawyer", not
nested under either): image resolution depends only on the document's own
directory, never on which page-settings geometry rendered it, so recording
it once per document (not once per cell) avoids two copies of the same
fact drifting apart. `OracleByteParityTests.swift`'s own `FileEntry` type
(soft-return-app) only reads `g["bare"]`/`g["sawyer"]` via
`JSONSerialization` dictionary lookups (never an exhaustive-keys decode),
so an added sibling key is inert there -- confirmed by reading that file,
no Swift change needed or made.

Shape (per document): a list, one entry per pix tag in document order,
matching ctrl-kd's own --diagnose "pix" entry shape (ctrlkd/info.py) minus
the path/width/height fields the oracle has no use for and which would
otherwise require care not to leak an absolute source-tree path into a
committed file:
    {"tag": "<basename>", "resolved": true|false, ["error": "<reason>"]}
A document with no pix tags at all gets an explicit "pix": [] -- absence
of the key would be ambiguous (never scanned? genuinely none?); an empty
list is not.

REFUSAL (so this cannot silently recur): by default, this script refuses
to WRITE any change if the scan finds an unresolved tag on a document
whose manifest cell(s) already carry real output (sha256) -- exactly the
placeholder-frozen-as-truth scenario above. Pass --allow-unresolved
<relpath> (repeatable) to explicitly accept a specific document's
unresolved tag(s) as legitimate (e.g. a source image genuinely lost to
time, confirmed absent from the whole tree by direct inspection, not a
location bug) and let population proceed for it anyway. Never a blanket
bypass -- each document must be named.

Usage:
    populate_oracle_pix_field.py <ctrl-kd-src-dir> <tree-root> <manifest.json> \\
        [--allow-unresolved RELPATH ...] [--dry-run]

<ctrl-kd-src-dir>: path whose ctrlkd/ package this imports (e.g.
/path/to/ctrl-kd/src). <tree-root>: the real directory the
manifest's file keys are relative paths into (resolution needs the real
directory to search near -- deliberately NOT a hardcoded default, so this
script never carries a filesystem path in its own source).
"""
import argparse
import json
import os
import sys


def _basename(raw_path):
    return raw_path.replace('\\', '/').rsplit('/', 1)[-1] or raw_path


def scan(tree_root, manifest_files, ctrlkd_src):
    """-> {relpath: [{"tag", "resolved", ["error"]}, ...]} for every key in
    manifest_files, plus a parallel {relpath: [unresolved tag names]} map
    for entries that have at least one unresolved tag AND at least one
    geometry cell with real output (the refusal condition)."""
    sys.path.insert(0, ctrlkd_src)
    from ctrlkd import core, pictures  # noqa: E402  (import after sys.path edit)

    pix_by_doc = {}
    blocking = {}
    for relpath, cells in sorted(manifest_files.items()):
        path = os.path.join(tree_root, relpath)
        has_output = any('sha256' in (cells.get(g) or {}) for g in ('bare', 'sawyer'))
        try:
            data = open(path, 'rb').read()
        except OSError as e:
            raise SystemExit(f'cannot read {relpath} from tree root: {e}')
        try:
            doc = core.parse(data, encoding='cp437', variant=None)
        except ValueError:
            pix_by_doc[relpath] = []
            continue
        if not doc.graphics:
            pix_by_doc[relpath] = []
            continue
        results = pictures.resolve_document_pictures(doc, path)
        entries = []
        unresolved_tags = []
        for r in results:
            e = {'tag': _basename(r.raw_path), 'resolved': bool(r.ok)}
            if not r.ok:
                e['error'] = r.error
                unresolved_tags.append(e['tag'])
            entries.append(e)
        pix_by_doc[relpath] = entries
        if unresolved_tags and has_output:
            blocking[relpath] = unresolved_tags
    return pix_by_doc, blocking


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('ctrlkd_src')
    ap.add_argument('tree_root')
    ap.add_argument('manifest')
    ap.add_argument('--allow-unresolved', action='append', default=[],
                    metavar='RELPATH', help='accept this document having an '
                    'unresolved tag despite the cell already having real '
                    'output (repeatable) -- confirm it is a genuinely lost '
                    'source image, not a location bug, before passing this')
    ap.add_argument('--dry-run', action='store_true',
                    help='scan and report, write nothing')
    a = ap.parse_args(argv)

    with open(a.manifest) as f:
        manifest = json.load(f)
    files = manifest['files']

    pix_by_doc, blocking = scan(a.tree_root, files, a.ctrlkd_src)

    allowed = set(a.allow_unresolved)
    unaccepted = {k: v for k, v in blocking.items() if k not in allowed}
    if unaccepted:
        print('REFUSING to write: the following documents have an unresolved '
              'pix tag AND already carry real (non-skipped) output in the '
              'manifest -- writing "pix" for them as-is would freeze a '
              'placeholder-captured entry as oracle truth. If each one is '
              'confirmed genuinely lost (not a location/CWD bug -- verify by '
              'searching the whole tree), re-run with --allow-unresolved '
              '<relpath> for each:', file=sys.stderr)
        for relpath, tags in sorted(unaccepted.items()):
            print(f'  {relpath}: unresolved {tags}', file=sys.stderr)
        raise SystemExit(2)

    for relpath in allowed:
        if relpath in blocking:
            print(f'proceeding on explicit --allow-unresolved for {relpath} '
                  f'(unresolved: {blocking[relpath]})', file=sys.stderr)

    changed = 0
    for relpath, entries in pix_by_doc.items():
        if files[relpath].get('pix') != entries:
            files[relpath]['pix'] = entries
            changed += 1

    print(f'{changed} entr{"y" if changed == 1 else "ies"} gained/updated a '
          f'"pix" field ({sum(1 for e in pix_by_doc.values() if e)} with '
          f'actual pix tags, {sum(1 for e in pix_by_doc.values() if not e)} '
          f'explicit empty)', file=sys.stderr)

    if a.dry_run:
        print('--dry-run: manifest not written', file=sys.stderr)
        return 0

    with open(a.manifest, 'w') as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
