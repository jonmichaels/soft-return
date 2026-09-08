#!/bin/bash
# test-isolation-gate.sh — planning #191 (the macOS test suite, run as Jon,
# wrote RTFs into his real Dropbox). Wraps a test-running COMMAND and fails
# if anything in Jon's document areas changed while it ran.
#
# This used to sweep ~/Dropbox, ~/Documents, ~/Desktop, ~/Downloads,
# ~/Pictures, ~/Movies, and ~/Music. Documents/Desktop/Downloads/Pictures/
# Movies/Music are TCC-protected on macOS: first access to any of them
# from a non-interactive process pops a permission dialog and blocks
# until a human clicks it. On Jon's real Mac that dialog — not disk I/O —
# was the entire 2889s (48 min) cost of the old whole-folder snapshot in
# HomeDirectoryWriteGuardTests.swift. A write landing in one of those
# folders during a test run would itself trigger that same blocking
# dialog, which IS the alarm — a silent stray write there isn't possible
# the way it is under Dropbox or ~/projects. So this gate (and that
# in-process guard) now watches only ~/Dropbox (not TCC-protected),
# ~/projects (minus this checkout and build output), and non-hidden files
# directly in $HOME. See docs/TESTING.md.
#
# A watched root that doesn't exist on this machine is skipped, and named
# as skipped. A root that DOES exist but can't be enumerated (permissions,
# anything) is a FAILURE naming that root, never a silent "zero
# offenders" — this guard must never read "couldn't check" as "clean".
# Every run prints which roots were actually walked.
#
# This is an EXTERNAL, out-of-process check. It complements
# HomeDirectoryWriteGuardTests.swift (an in-process guard over the same
# roots, run from inside the test process) by also catching a stray write
# from anything the wrapped command spawns as a subprocess, not just the
# test process itself.
#
# bash 3.2 / BSD find only — this must run unmodified under Jon's real Mac
# shell (macOS ships bash 3.2; see the macos-scripts-bash-3-2 convention):
# no associative arrays, no mapfile, no `${var,,}`, no GNU-only find flags.
# `-newer`, `-path`, `-name`, `-prune`, and `-not` are all POSIX/BSD-safe.
#
# Usage: test-isolation-gate.sh <command> [args...]
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: test-isolation-gate.sh <command> [args...]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# macos/scripts -> macos -> repo root.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOME_DIR="${HOME:-$(cd ~ && pwd)}"
TMP_DIR="${TMPDIR:-/tmp}"

MARKER="$(mktemp "${TMP_DIR%/}/test-isolation-gate.XXXXXX")"
trap 'rm -f "${MARKER}"' EXIT

# Run the wrapped command. Its own exit status is preserved and reported
# after the isolation check below, so a genuine test failure is never
# masked by — or confused with — a stray-write finding, and a stray write
# is never hidden just because the tests themselves passed.
set +e
"$@"
COMMAND_STATUS=$?
set -e

OFFENDERS=""
COVERAGE=""

# Appends find output (if any) to OFFENDERS, one path per line.
add_offenders() {
    [ -n "$1" ] || return 0
    if [ -n "${OFFENDERS}" ]; then
        OFFENDERS="${OFFENDERS}
$1"
    else
        OFFENDERS="$1"
    fi
}

# Names a root as actually walked this run, for the coverage line printed below.
add_coverage() {
    if [ -n "${COVERAGE}" ]; then
        COVERAGE="${COVERAGE}, $1"
    else
        COVERAGE="$1"
    fi
}

# Prints (one per line) files under $1 newer than $MARKER, skipping hidden entries and
# package/library bundles. This bundle list matches
# HomeDirectoryWriteGuardTests.swift's skippedPackageExtensions — Dropbox can and does hold
# these (a Photos or Music library synced through it, an Xcode project, ...), and descending
# into one to stat every file inside is exactly the metadata-churn cost this guard exists to
# avoid; nothing this app writes lands inside one.
scan_root() {
    find "$1" \
        \( -name '*.photoslibrary' -o -name '*.musiclibrary' -o -name '*.tvlibrary' \
           -o -name '*.app' -o -name '*.framework' -o -name '*.xcodeproj' \
           -o -name '*.xcworkspace' -o -name '*.xcresult' -o -name '*.band' \
           -o -name '*.logicx' -o -name '*.imovielibrary' -o -name '*.fcpbundle' \) -prune \
        -o -newer "${MARKER}" -type f -not -path '*/.*' -print \
        2>/dev/null || true
}

# Same, plus pruning this repo's own checkout (a build/test run legitimately writes there)
# and any DerivedData directory under the root (Xcode's default build output — spelled out
# explicitly since, unlike .build/.git, it isn't dot-prefixed and so isn't covered by the
# hidden-file exclusion).
scan_projects_root() {
    find "$1" \
        \( -path "${REPO_ROOT}" -o -name '*.photoslibrary' -o -name '*.musiclibrary' \
           -o -name '*.tvlibrary' -o -name '*.app' -o -name '*.framework' \
           -o -name '*.xcodeproj' -o -name '*.xcworkspace' -o -name '*.xcresult' \
           -o -name '*.band' -o -name '*.logicx' -o -name '*.imovielibrary' \
           -o -name '*.fcpbundle' \) -prune \
        -o -newer "${MARKER}" -type f -not -path '*/.*' -not -path '*/DerivedData/*' -print \
        2>/dev/null || true
}

# Extensions this app's own beside-source conversion output (BesideSourceWriter) can produce
# next to a .ws/.WS source, matched case-insensitively. Kept in sync with
# HomeDirectoryWriteGuardTests.swift's dropboxConvertedExtensions.
DROPBOX_CONVERTED_EXTS="rtf pdf txt docx html htm md odt"

# True (exit 0) if $1 (an absolute path under ~/Dropbox) looks like this app's own
# beside-source conversion output landing next to a .ws/.WS document that synced in from
# another device during a run — Jon's own edits produce exactly this shape and must not be
# flagged. Requires BOTH: an extension in DROPBOX_CONVERTED_EXTS (case-insensitive), AND a
# sibling file in the same directory named the same stem plus .ws or .WS. Also matches
# macOS's "name 2.rtf" / "name 3.rtf" duplicate-file naming: a trailing " <digits>" is
# stripped from the stem before the sibling check.
is_dropbox_conversion_sibling() {
    local path="$1" dir base ext stem lower_ext e ext_ok
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    case "$base" in
        *.*) ext="${base##*.}"; stem="${base%.*}" ;;
        *) return 1 ;;  # no extension at all: never this app's conversion output
    esac
    lower_ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    ext_ok=0
    for e in ${DROPBOX_CONVERTED_EXTS}; do
        [ "$lower_ext" = "$e" ] && ext_ok=1 && break
    done
    [ "$ext_ok" -eq 1 ] || return 1
    if [[ "$stem" =~ ^(.*)\ [0-9]+$ ]]; then
        stem="${BASH_REMATCH[1]}"
    fi
    [ -e "${dir}/${stem}.ws" ] || [ -e "${dir}/${stem}.WS" ]
}

# Filters $1 (newline-separated candidate paths, possibly empty) down to only those that pass
# is_dropbox_conversion_sibling. Used to narrow ~/Dropbox candidates to the app's actual
# damage fingerprint — see docs/TESTING.md.
filter_dropbox_offenders() {
    local candidates="$1" line result=""
    [ -n "${candidates}" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if is_dropbox_conversion_sibling "$line"; then
            if [ -n "${result}" ]; then
                result="${result}
${line}"
            else
                result="${line}"
            fi
        fi
    done <<EOF
${candidates}
EOF
    printf '%s' "${result}"
}

# Checks one watched root: skips (and says so) if absent, fails naming the root if it exists
# but can't even be listed (never a silent "zero offenders"), otherwise records it as walked
# and scans it with the named scanner function ($2). If a filter function ($3) is given, raw
# candidates are narrowed through it before being counted as offenders (used for ~/Dropbox).
check_root() {
    local root="$1"
    local scanner="$2"
    local filter="${3:-}"
    local found
    if [ ! -e "${root}" ]; then
        echo "test-isolation-gate: skipping ${root} — does not exist on this machine" >&2
        return 0
    fi
    if ! find "${root}" -maxdepth 1 >/dev/null 2>&1; then
        add_offenders "guard coverage lost: ${root} exists but could not be enumerated"
        return 0
    fi
    add_coverage "${root}"
    found="$("${scanner}" "${root}")"
    if [ -n "${filter}" ]; then
        found="$("${filter}" "${found}")"
    fi
    add_offenders "${found}"
}

# Six TCC-protected content folders (Documents, Desktop, Downloads, Pictures, Movies, Music)
# are deliberately NOT watched here or in HomeDirectoryWriteGuardTests.swift — see the header
# comment above and docs/TESTING.md.
#
# ~/Dropbox gets a narrower offender rule than ~/projects and $HOME's top level (see
# filter_dropbox_offenders above): Jon's own edits on other devices sync into Dropbox during
# a run, and a blanket "any new file" rule would flag his own work. Only a new/modified file
# whose extension matches this app's conversion output AND has a same-stem .ws/.WS sibling
# counts — that shape is specific to BesideSourceWriter, not to Jon's own file sync.
check_root "${HOME_DIR}/Dropbox" scan_root filter_dropbox_offenders
check_root "${HOME_DIR}/projects" scan_projects_root

# Files directly in $HOME itself (maxdepth 1 — its subdirectories are either watched above or
# deliberately not part of the threat model), hidden files excluded.
if [ ! -e "${HOME_DIR}" ]; then
    echo "test-isolation-gate: skipping ${HOME_DIR} — does not exist on this machine" >&2
elif ! find "${HOME_DIR}" -maxdepth 1 >/dev/null 2>&1; then
    add_offenders "guard coverage lost: ${HOME_DIR} exists but could not be enumerated"
else
    add_coverage "${HOME_DIR} (top level only)"
    found="$(find "${HOME_DIR}" -maxdepth 1 -newer "${MARKER}" -type f -not -name '.*' 2>/dev/null || true)"
    add_offenders "${found}"
fi

echo "test-isolation-gate: watched roots this run: ${COVERAGE:-<none>}" >&2

if [ -n "${OFFENDERS}" ]; then
    echo "test-isolation-gate: isolation check failed:" >&2
    echo "${OFFENDERS}" >&2
    if [ "${COMMAND_STATUS}" -ne 0 ]; then
        echo "test-isolation-gate: the wrapped command also failed on its own (exit ${COMMAND_STATUS})" >&2
    fi
    exit 1
fi

exit "${COMMAND_STATUS}"
