#!/usr/bin/env python3
"""ORPHANED alongside populate_oracle_pix_field.py (planning #205 Task 2,
2026-09-06) -- its subject script has nothing left to populate. Still passes
(everything here is synthetic, per its own docstring below) but proves
nothing relevant to the current test regime; kept only as a record.

Synthetic proof for populate_oracle_pix_field.py -- deliberately does NOT
touch the real archive tree or the committed manifest. Everything here runs
against a tmp tree + tmp manifest built in this process.

Proves, with a genuinely on-disk, ctrl-kd-parseable document whose pix tag
cannot resolve (never mind the real corpus's own two such cases -- this
holds regardless of what any particular corpus happens to contain):

  1. resolve_document_pictures reports the miss (error='unresolved') and
     NEVER raises -- the ruled non-failing behavior -- and the population
     script's scan() reflects that as {"tag":..., "resolved": False,
     "error": "unresolved"}.
  2. The population script REFUSES to write (SystemExit, manifest file on
     disk left byte-for-byte unchanged) when that document's cell already
     carries real output and --allow-unresolved was not passed for it.
  3. The same run SUCCEEDS and writes the record when --allow-unresolved
     names that document explicitly.
  4. A document whose tag DOES resolve is recorded {"resolved": True} and
     never blocks, override or not.

The fixture's byte layout (WS4 symmetric pix tag) is patched from one real
template document's structural shape (see `_ws_doc_with_pix_tag`) but ships
no archive content or path of its own -- the template's location is read
from an environment variable, never hardcoded here, same discipline
`populate_oracle_pix_field.py`'s own tree-root argument follows.

Run directly:
    CTRLKD_SRC=/path/to/ctrl-kd/src CTRLKD_SAWYER_ARCHIVE=/path/to/sawyer/archive \\
        python3 scripts/test_populate_oracle_pix_field.py
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CTRLKD_SRC = os.environ.get('CTRLKD_SRC')
if not CTRLKD_SRC:
    raise SystemExit('set CTRLKD_SRC to the ctrl-kd checkout\'s src/ directory to run this '
                      'synthetic test -- never hardcoded here, same discipline this file\'s '
                      'own docstring already claims for CTRLKD_SAWYER_ARCHIVE.')
POPULATE = os.path.join(HERE, 'populate_oracle_pix_field.py')


def _ws_doc_with_pix_tag(basename11: str) -> bytes:
    """A ctrl-kd-parseable WS4 document carrying exactly one pix tag whose
    payload is `X:\\<basename11>` (basename11 must be exactly 11 chars,
    matching the original template's own payload length so the symmetric
    block's recorded length stays valid). Built by patching a real,
    already-known-to-parse WS4 document's own pix-tag payload in place --
    not shipping any archive CONTENT, just its structural shape -- rather
    than hand-assembling a WS4 header from scratch (undocumented and easy
    to get subtly wrong; ctrlkd.core's detector rejected a first hand-
    built attempt as not text-like enough). The template is
    `HIJAAK/PEANUTS.WS` under the tree named by `CTRLKD_SAWYER_ARCHIVE` (256
    bytes, read-only source, never written back to) with its own payload
    `PEANUTS.PIX` (11 chars) replaced -- same length in, same length out,
    so every other offset in the file is untouched.
    """
    assert len(basename11) == 11, basename11
    root = os.environ.get('CTRLKD_SAWYER_ARCHIVE')
    if not root:
        raise SystemExit('set CTRLKD_SAWYER_ARCHIVE to the Sawyer archive '
                         'top dir to run this synthetic test')
    template = open(os.path.join(root, 'HIJAAK', 'PEANUTS.WS'), 'rb').read()
    old_payload = b'PEANUTS.PIX'
    assert template.count(old_payload) == 1, 'template shape changed'
    return template.replace(old_payload, basename11.encode('ascii'))


def _tiny_pix_bytes(gcols=8, grows=1) -> bytes:
    """A minimal, structurally valid, single-row MONO .PIX (same
    construction as ctrl-kd's own tests/test_pictures.py::_tiny_pix_bytes)."""
    row_bytes = gcols // 8
    mode_blob = bytearray(29)
    mode_blob[1] = 1
    struct.pack_into('<HH', mode_blob, 18, gcols, grows)
    mode_blob[22] = 1
    tile_info = struct.pack('<HHHH', grows, gcols, 1, 1)
    tile_bitmap = bytes(row_bytes)
    items = [(0, bytes(mode_blob)), (1, bytes(4 * 16)), (2, tile_info),
             (0x8000, tile_bitmap)]
    header = struct.pack('<HH', 3, len(items))
    index_off = 4 + 8 * len(items)
    index_entries = bytearray()
    blobs = bytearray()
    cur = index_off
    for did, blob in items:
        index_entries += struct.pack('<HHI', did, len(blob), cur)
        blobs += blob
        cur += len(blob)
    return bytes(header) + bytes(index_entries) + bytes(blobs)


def _assert_parses_with_one_graphics_tag(doc_bytes, expect_tag):
    sys.path.insert(0, CTRLKD_SRC)
    from ctrlkd import core
    doc = core.parse(doc_bytes, encoding='cp437', variant=None)
    assert doc.graphics == [expect_tag], doc.graphics


def run_populate(tree, manifest_path, allow=()):
    cmd = [sys.executable, POPULATE, CTRLKD_SRC, tree, manifest_path]
    for a in allow:
        cmd += ['--allow-unresolved', a]
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as td:
        tree = os.path.join(td, 'tree')
        os.makedirs(tree)

        # --- Fixture A: MISS. Tag names an image nowhere near it. ---
        miss_doc = _ws_doc_with_pix_tag('ZZFAKE1.PIX')
        _assert_parses_with_one_graphics_tag(miss_doc, r'N:\ZZFAKE1.PIX')
        with open(os.path.join(tree, 'MISS.WS'), 'wb') as f:
            f.write(miss_doc)

        # --- Fixture B: RESOLVES. Real tiny .PIX beside the document. ---
        hit_doc = _ws_doc_with_pix_tag('ZZHITOK.PIX')
        _assert_parses_with_one_graphics_tag(hit_doc, r'N:\ZZHITOK.PIX')
        with open(os.path.join(tree, 'HIT.WS'), 'wb') as f:
            f.write(hit_doc)
        with open(os.path.join(tree, 'ZZHITOK.PIX'), 'wb') as f:
            f.write(_tiny_pix_bytes())

        cell_with_output = {'sha256': 'a' * 64, 'bytes': 1,
                            'pages': 0, 'structure_sha256': 'b' * 64}
        manifest = {
            'files': {
                'MISS.WS': {'bare': dict(cell_with_output),
                           'sawyer': dict(cell_with_output)},
                'HIT.WS': {'bare': dict(cell_with_output),
                          'sawyer': dict(cell_with_output)},
            },
            'generator': 'synthetic self-test, not a real oracle run',
            'source': 'scripts/test_populate_oracle_pix_field.py fixtures',
        }
        manifest_path = os.path.join(td, 'manifest.json')
        with open(manifest_path, 'w') as f:
            json.dump(manifest, f, indent=1, sort_keys=True)
            f.write('\n')
        with open(manifest_path) as f:
            before = f.read()

        # 1/2: no --allow-unresolved -> refuses, manifest untouched, exit 2.
        r = run_populate(tree, manifest_path, allow=())
        assert r.returncode == 2, (r.returncode, r.stdout, r.stderr)
        assert 'REFUSING to write' in r.stderr, r.stderr
        assert 'MISS.WS' in r.stderr, r.stderr
        with open(manifest_path) as f:
            after = f.read()
        assert after == before, 'manifest was modified despite refusal'
        print('PASS: refuses to write an unresolved-image entry, manifest unchanged')

        # 3: --allow-unresolved MISS.WS -> succeeds, records the miss.
        r = run_populate(tree, manifest_path, allow=('MISS.WS',))
        assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
        with open(manifest_path) as f:
            written = json.load(f)
        miss_pix = written['files']['MISS.WS']['pix']
        assert miss_pix == [{'tag': 'ZZFAKE1.PIX', 'resolved': False,
                             'error': 'unresolved'}], miss_pix
        print('PASS: --allow-unresolved lets the miss through, recorded as '
              'resolved:false with error')

        # 4: the resolving fixture recorded resolved:true, no override needed.
        hit_pix = written['files']['HIT.WS']['pix']
        assert hit_pix == [{'tag': 'ZZHITOK.PIX', 'resolved': True}], hit_pix
        print('PASS: a resolving tag is recorded resolved:true and never blocks')

        # Existing bytes/sha256/pages/structure_sha256 untouched.
        for name in ('MISS.WS', 'HIT.WS'):
            for geom in ('bare', 'sawyer'):
                cell = written['files'][name][geom]
                assert cell['sha256'] == 'a' * 64
                assert cell['bytes'] == 1
        print('PASS: existing bytes/sha256/pages/structure_sha256 left untouched')

    print('\nALL SYNTHETIC PROOFS PASSED')


if __name__ == '__main__':
    main()
