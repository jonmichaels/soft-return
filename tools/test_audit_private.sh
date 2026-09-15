#!/usr/bin/env bash
# Regression test for tools/audit_private.sh's base64 pass.
#
# WHY THIS EXISTS. A real Dropbox path sat in a base64-encoded AppleEvent
# fixture in this repo, live on this repo's public snapshot, for eleven
# days, because nothing ever decoded a *.base64 file before grepping it.
# This test proves the capability that closes that gap actually works, in
# both directions (a guard that blocks everything is as broken as one that
# blocks nothing -- private-info-git-guard ruling, 2026-08-24):
#
#   1. POSITIVE: a base64 fixture whose DECODED bytes carry a personal
#      machine path must be flagged, even though the raw base64 text
#      itself contains no such path in the base64 alphabet.
#   2. NEGATIVE: a base64 fixture whose decoded bytes carry only a
#      synthetic, non-personal path must pass clean -- the guard must not
#      cry wolf on every base64 blob just because it decodes to text.
#
# Runs in an isolated scratch git repo so it never touches this repo's own
# tracked set or history.
#
#   tools/test_audit_private.sh
#
# Exit 0 = both controls behaved as expected. Non-zero = the guard's base64
# pass is broken (in either direction) and must be fixed before trusting it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

setup_repo() {
    # $1 = repo dir to create
    mkdir -p "$1/tools"
    cp "$here/private_patterns.sh" "$1/tools/private_patterns.sh"
    cp "$here/audit_private.sh" "$1/tools/audit_private.sh"
    chmod +x "$1/tools/audit_private.sh"
    ( cd "$1" && git init -q && git config user.email t@example.invalid \
        && git config user.name test \
        && echo 'a WordStar test repo' > README.md \
        && git add -A && git commit -q -m init )
}

# --- Positive control -------------------------------------------------
pos="$scratch/pos-repo"
setup_repo "$pos"
mkdir -p "$pos/Fixtures"
# A generic personal-machine path (NOT this repo's real leaked names --
# this test only needs to prove the SHAPE-through-base64 mechanism, not
# re-embed any real identifier anywhere).
printf '/Users/exampleuser/Documents/PrivateFolder/data.ws' \
    | base64 > "$pos/Fixtures/leaky.base64"
( cd "$pos" && git add -A && git commit -q -m 'add leaky fixture' )

if ( cd "$pos" && ./tools/audit_private.sh >/tmp/audit_pos.out 2>&1 ); then
    echo "FAIL (positive control): audit_private.sh did NOT flag a base64" \
         "fixture whose decoded bytes carry a personal path"
    cat /tmp/audit_pos.out
    fail=1
elif ! grep -q "DECODED BASE64" /tmp/audit_pos.out; then
    echo "FAIL (positive control): audit_private.sh failed, but not for the" \
         "expected reason (no 'DECODED BASE64' hit reported)"
    cat /tmp/audit_pos.out
    fail=1
else
    echo "PASS (positive control): decoded base64 personal path was flagged"
fi

# --- Negative control ---------------------------------------------------
neg="$scratch/neg-repo"
setup_repo "$neg"
mkdir -p "$neg/Fixtures"
# A synthetic path with no personal-machine shape at all.
printf '/Volumes/PublicSamples/example-floppy-set/WORK/SAMPLE.ws' \
    | base64 > "$neg/Fixtures/clean.base64"
( cd "$neg" && git add -A && git commit -q -m 'add clean fixture' )

if ( cd "$neg" && ./tools/audit_private.sh >/tmp/audit_neg.out 2>&1 ); then
    echo "PASS (negative control): synthetic non-personal base64 fixture passed clean"
else
    echo "FAIL (negative control): audit_private.sh flagged a fixture with no" \
         "personal-machine shape -- it cries wolf on any base64 blob"
    cat /tmp/audit_neg.out
    fail=1
fi

# --- Plain-text leak still caught (not just base64) ---------------------
plain="$scratch/plain-repo"
setup_repo "$plain"
echo 'default output dir: /Users/exampleuser/Documents/scratch' > "$plain/NOTES.md"
( cd "$plain" && git add -A && git commit -q -m 'add plain leak' )
if ( cd "$plain" && ./tools/audit_private.sh >/tmp/audit_plain.out 2>&1 ); then
    echo "FAIL (plain-text control): a real personal path in plain text was not flagged"
    cat /tmp/audit_plain.out
    fail=1
else
    echo "PASS (plain-text control): plain-text personal path was flagged"
fi

# --- False-positive guards (2026-09-07 pattern-tuning pass) -------------
# The pattern was rewritten after being wired into a real hook for the
# first time and immediately flagging ~140 lines that were not leaks:
# generic macOS folder examples, Swift's `~` bitwise-NOT operator, and the
# ordinary English word "noisy". Each of these must stay clean, or the
# guard is back to being too noisy to keep armed.
fp="$scratch/fp-repo"
setup_repo "$fp"
cat > "$fp/EXAMPLES.md" <<'EOF'
Generic macOS folder examples: `~/Desktop`, `~/Library`, `~/Downloads`,
`~/projects`, `~/Dropbox`, and `$HOME` name nobody.
Placeholder paths: `/Users/yourname/file` and `/Users/user/file`.
Swift bitwise-NOT: `let cleared = perms & ~UInt16(0o111)`.
Markdown strikethrough: `~~deleted text~~`.
Approximate-value prose: measured `~col 30`, `~390 files`, `~59pt wider`.
Harness defects "were masking, not just noisy" -- ordinary English.
EOF
( cd "$fp" && git add -A && git commit -q -m 'add false-positive examples' )
if ( cd "$fp" && ./tools/audit_private.sh >/tmp/audit_fp.out 2>&1 ); then
    echo "PASS (false-positive guard): generic tilde paths, bitwise-NOT," \
         "strikethrough, approximate-value prose, and 'not just noisy' all passed clean"
else
    echo "FAIL (false-positive guard): the pattern is crying wolf again -- see" \
         "tools/private_patterns.sh PAT_SHAPE / PAT_SAFE_COLLOCATIONS / PAT_SAFE_PLACEHOLDERS"
    cat /tmp/audit_fp.out
    fail=1
fi

# A REAL tilde-username leak must still be caught even after the narrowing
# above -- the fix must not have thrown out the one shape it exists to keep.
tp="$scratch/tp-repo"
setup_repo "$tp"
echo 'scratch output under ~worker if writable' > "$tp/NOTES.md"
( cd "$tp" && git add -A && git commit -q -m 'add tilde-username leak' )
if ( cd "$tp" && ./tools/audit_private.sh >/tmp/audit_tp.out 2>&1 ); then
    echo "FAIL (tilde-username control): a real \`~worker\` shell path was not flagged"
    cat /tmp/audit_tp.out
    fail=1
else
    echo "PASS (tilde-username control): \`~worker\` shell-expansion path was flagged"
fi

# --- Never-cross exclusion: content that can never leak must not block --
# outbox/ is 100% absent from every public snapshot (verified 2026-09-07);
# scanning it would block ordinary private-repo work over paths that can
# never reach anyone. A real hostname sitting in outbox/ must NOT fail the
# audit -- but the exact same content in a file that DOES cross still must.
nc="$scratch/nevercross-repo"
setup_repo "$nc"
mkdir -p "$nc/outbox/job1"
echo 'internal run notes, worker path /Users/worker/worker/probe' \
    > "$nc/outbox/job1/report.md"
echo 'internal run notes, worker path /Users/worker/worker/probe' > "$nc/CROSSING.md"
( cd "$nc" && git add -A && git commit -q -m 'add never-cross content' )
out="$(cd "$nc" && ./tools/audit_private.sh 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL (never-cross guard): CROSSING.md's personal-machine path was not flagged" \
         "-- the audit is not scanning files that DO cross"
    echo "$out"
    fail=1
elif printf '%s' "$out" | grep -q "outbox/job1/report.md"; then
    echo "FAIL (never-cross guard): outbox/ was scanned and flagged -- it can never" \
         "cross into public and must be excluded, or ordinary private-repo work" \
         "in outbox/ would be permanently blocked"
    echo "$out"
    fail=1
elif printf '%s' "$out" | grep -q "CROSSING.md"; then
    echo "PASS (never-cross guard): outbox/ was skipped; the identical leak in a" \
         "crossing file was still caught"
else
    echo "FAIL (never-cross guard): audit failed, but not for the expected reason" \
         "(CROSSING.md's hit was not reported)"
    echo "$out"
    fail=1
fi

exit "$fail"
