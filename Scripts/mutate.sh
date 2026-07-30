#!/usr/bin/env bash
#
# Mutation testing for CtrlKD: break the source on purpose, one edit at a time, and check
# that the suite notices. A test that passes against a deliberately wrong implementation is
# not testing that implementation.
#
# Usage:  Scripts/mutate.sh [mutants-file]        # default: Scripts/mutants/job-011.tsv
#
# Not part of any package product — SwiftPM ignores Scripts/. It needs a clean git tree
# (that is how it restores) and it will refuse to start without one.
#
# ---------------------------------------------------------------------------------------
# DOCTRINE — three rules, each of which exists because breaking it once produced a run
# that reported success while proving nothing:
#
#   1. EXIT CODES ONLY. The verdict for a mutant is `swift test`'s exit status: non-zero
#      means the suite caught it. NEVER grep the output for failure markers or count '✔'
#      lines. A build error, a crash, or a suite that never ran all look like "no failures
#      printed", so a grep-based harness scores every one of them as CAUGHT and a whole
#      broken run comes back green. (A mutant that fails to compile is still legitimately
#      caught — the compiler is part of the suite — but it has to be the exit code saying so.)
#
#   2. EACH ANCHOR MUST MATCH EXACTLY ONCE. Before applying, the anchor string is counted in
#      its file. Zero matches means the mutant is stale — the source moved on — and a
#      harness that silently skips it reports a mutant it never ran as caught. More than one
#      match means the edit is not the edit that was written down. Either is a hard error
#      for that mutant, reported as ERROR and counted against the run, not as a pass.
#
#   3. RESTORE, THEN PROVE THE TREE IS CLEAN. Every mutant is reverted with `git checkout`
#      immediately after its run, and at the end the harness asserts `git diff` is empty AND
#      re-runs the full suite green. Otherwise a crash mid-run leaves mutated source behind
#      and the next thing anyone does is debug a bug this script wrote.
# ---------------------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MUTANTS="${1:-Scripts/mutants/job-011.tsv}"
[ -f "$MUTANTS" ] || { echo "no mutants file: $MUTANTS"; exit 1; }

# Rule 3, up front: an unclean tree means `git checkout --` would destroy real work.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "REFUSING TO RUN: working tree is dirty. Commit or stash first."
    exit 1
fi

# A baseline that does not pass makes every verdict below meaningless.
echo "baseline: running the suite unmutated..."
if ! swift test >/dev/null 2>&1 </dev/null; then
    echo "REFUSING TO RUN: the suite fails before any mutation."
    exit 1
fi
echo "baseline green"
echo

caught=0; survived=0; errored=0
survivors=()

while IFS=$'\t' read -r label file anchor replacement; do
    case "${label:-}" in ''|'#'*) continue ;; esac

    # Rule 2: apply only if the anchor appears exactly once.
    python3 - "$file" "$anchor" "$replacement" <<'PY'
import sys
path, anchor, repl = sys.argv[1], sys.argv[2], sys.argv[3]
# A TSV row cannot hold a real newline or tab, so the file spells them \n and \t.
anchor = anchor.replace('\\n', '\n').replace('\\t', '\t')
repl = repl.replace('\\n', '\n').replace('\\t', '\t')
try:
    src = open(path).read()
except OSError:
    sys.exit(4)
n = src.count(anchor)
if n != 1:
    sys.exit(2 if n == 0 else 3)
open(path, 'w').write(src.replace(anchor, repl))
PY
    case $? in
        0) ;;
        2) echo "ERROR  $label — anchor not found in $file (stale mutant)"; errored=$((errored+1)); continue ;;
        3) echo "ERROR  $label — anchor matches more than once in $file"; errored=$((errored+1)); continue ;;
        *) echo "ERROR  $label — cannot read $file"; errored=$((errored+1)); continue ;;
    esac

    # Rule 1: the exit code is the verdict, and nothing else is consulted.
    swift test >/dev/null 2>&1 </dev/null
    if [ $? -ne 0 ]; then
        echo "caught    $label"
        caught=$((caught+1))
    else
        echo "SURVIVED  $label"
        survived=$((survived+1))
        survivors+=("$label")
    fi

    git checkout -- "$file" || { echo "FATAL: could not restore $file"; exit 1; }
done < "$MUTANTS"

echo
echo "$caught caught, $survived survived, $errored errored"
for s in "${survivors[@]:-}"; do [ -n "$s" ] && echo "  survivor: $s"; done

# Rule 3: prove the tree is back to where it started, and still green.
if ! git diff --quiet; then
    echo "FATAL: working tree still modified after the run — mutated source was left behind:"
    git diff --stat
    exit 1
fi
if ! swift test >/dev/null 2>&1 </dev/null; then
    echo "FATAL: suite does not pass after restore."
    exit 1
fi
echo "tree clean, suite green after restore"

[ "$survived" -eq 0 ] && [ "$errored" -eq 0 ]
