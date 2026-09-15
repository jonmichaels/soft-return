#!/usr/bin/env bash
# Refuse to let personal-machine material sit in this repo's tracked set.
#
# This is a PRIVATE repo (real corpus paths, private-corpus manifests, and
# personal WS4 papers legitimately live here under `CTRLKD_PRIVATE_CORPUS`
# labels) -- the rule this guard enforces is narrower than "nothing
# personal": it is "no real path to anybody's machine, in any encoding".
# The private-corpus category labels themselves (e.g. the corpus group
# names used throughout TestDocs/ and the private test suites) are an
# accepted, already-public convention and are deliberately NOT patterns
# here -- see tools/private_patterns.sh's own comment on why.
#
# Scope: only the part of the tracked tree that can ever reach the public
# soft-return repo. tools/private_patterns.sh's PAT_NEVER_CROSS_DIRS/FILES
# (outbox/, evidence/, archive/, .claude/, ctrlkd-private-tests/, TestDocs/,
# this repo's own CLAUDE.md and operational docs/) are skipped entirely --
# scanning them would only block ordinary private-repo work over content
# that can never leak, since nothing there is ever part of a public
# snapshot (confirmed 2026-09-07 by diffing against the live public repo).
#
#   tools/audit_private.sh          # working tree (tracked files)
#   tools/audit_private.sh --log R  # also every commit message in range R
#
# Exit 0 = clean. Non-zero = do not publish / do not snapshot to the public
# repo.
set -uo pipefail
cd "$(dirname "$0")/.."

# The pattern lives in ONE place, shared with the git hooks.
. "$(dirname "$0")/private_patterns.sh"

fail=0

# Drop known-safe matches (ordinary-English collocations of a real-word
# hostname, and generic placeholder names like `/Users/yourname`), keep
# everything else. Reads stdin (grep -n output, possibly multi-line, one
# match per line so a line-level drop cannot hide an unrelated real match
# elsewhere on the same line).
drop_safe_collocations() {
    grep -viE "$PAT_SAFE_COLLOCATIONS" 2>/dev/null | grep -viE "$PAT_SAFE_PLACEHOLDERS" 2>/dev/null || true
}

# Audit what git TRACKS, not what happens to be on disk -- the question is
# "what would be published or snapshotted". Never-cross paths (dirs + the
# individually-listed files, see private_patterns.sh) are skipped entirely.
# Filenames are prefixed by hand (sed) because grep -nIE on a single file
# at a time omits its own name from the output.
hits=""
while IFS= read -r -d '' f; do
    printf '%s' "$f" | grep -qE "$PAT_SELF_EXCLUDE" && continue
    skip=0
    for d in "${PAT_NEVER_CROSS_DIRS[@]}"; do
        case "$f" in "$d"/*) skip=1; break ;; esac
    done
    [ "$skip" -eq 1 ] && continue
    for nf in "${PAT_NEVER_CROSS_FILES[@]}"; do
        [ "$f" = "$nf" ] && { skip=1; break; }
    done
    [ "$skip" -eq 1 ] && continue
    hit=$(grep -nIE "$PAT" "$f" 2>/dev/null | drop_safe_collocations | sed "s#^#$f:#")
    [ -n "$hit" ] && hits="$hits
$hit"
done < <(git ls-files -z)
hits="$(printf '%s' "$hits" | sed '/^$/d')"
if [ -n "$hits" ]; then
    echo "PRIVATE MATERIAL IN TRACKED FILES (crossing the public boundary):"
    echo "$hits"
    fail=1
fi

# base64-encoded fixtures: DECODE THEN SCAN. This is the fix for the
# 2026-09-07 incident -- a real Dropbox path survived in a recorded
# AppleEvent fixture (macos/SoftReturnTests/Fixtures/*.base64) for eleven
# days, live on this repo's public snapshot, because the plain-text pass
# above only ever sees the base64 alphabet, never the path it encodes. Any
# tracked *.base64 file is decoded and the DECODED bytes are scanned with
# the same pattern (binary bytes are printed by grep -a; that is fine, we
# only care whether it matches, not that the output is pretty).
# One narrow, named, hand-reviewed exemption: a recorded AppleEvent fixture
# whose bytes are a flattened macOS descriptor. Its "/Users/<fakename>/..."
# top-level shape is required realism (real macOS paths always start there;
# see planning's private-leak fix, which scrubbed this file byte-length-
# preservingly) -- PAT_SHAPE alone would flag that shape forever, on every
# run, with nothing left to fix. It still gets scanned for this repo's
# actual leaked names/hosts/nets (PAT_NAMES, PAT_HOSTS, PAT_NET): if a real
# identifier ever reappears here, this does not hide it. Exempting the
# pattern instead of the file would hide real leaks everywhere; this hides
# only the generic shape, only in this one reviewed file.
B64_SHAPE_EXEMPT='^macos/SoftReturnTests/Fixtures/real-convert-event-b9\.base64$'

b64_hits=""
while IFS= read -r -d '' f; do
    decoded="$(base64 -d "$f" 2>/dev/null)" || continue
    if printf '%s' "$f" | grep -qE "$B64_SHAPE_EXEMPT"; then
        pat_for_file="($PAT_NAMES|$PAT_HOSTS|$PAT_NET)"
    else
        pat_for_file="$PAT"
    fi
    hit=$(printf '%s' "$decoded" | grep -naE "$pat_for_file" | drop_safe_collocations)
    if [ -n "$hit" ]; then
        b64_hits="$b64_hits
$f (decoded):
$hit"
    fi
done < <(git ls-files -z -- '*.base64' '*.b64')
if [ -n "$b64_hits" ]; then
    echo "PRIVATE MATERIAL IN DECODED BASE64 FIXTURES:"; echo "$b64_hits"; fail=1
fi

if [ "${1:-}" = "--log" ] && [ -n "${2:-}" ]; then
    msgs=$(git log --format='%h %B' "$2" 2>/dev/null | grep -nIE "$PAT" | drop_safe_collocations)
    if [ -n "$msgs" ]; then
        echo "PRIVATE MATERIAL IN COMMIT MESSAGES:"; echo "$msgs"; fail=1
    fi
fi

# Positive control: a check that has never returned a hit has not been
# tested. If the scanner cannot find a string we KNOW is present, it is not
# reading the files and its "clean" result is meaningless.
if ! git ls-files -z | xargs -0r grep -qIE 'WordStar' 2>/dev/null; then
    echo "AUDIT IS NOT READING FILES -- its 'clean' result is meaningless"; fail=1
fi

[ "$fail" -eq 0 ] && echo "audit clean: no personal machine paths found crossing the public boundary (plain text or base64)"
exit "$fail"
