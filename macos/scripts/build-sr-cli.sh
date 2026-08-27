#!/bin/bash
# Tuist pre-build script phase on the SoftReturn app target (job 248).
#
# Builds the `sr` CLI (universal arm64+x86_64, release) from the engine
# package this build's CtrlKD dependency resolves from, and drops it into
# the app bundle's Contents/MacOS/ so CommandLineToolInstaller can find it
# via Bundle.main.url(forAuxiliaryExecutable:) (which only looks there).
#
# Job 532 (monorepo birth, job-c36053d): the engine used to be a REMOTE SPM
# pin, which Xcode cloned into a disposable "SourcePackages/checkouts/
# soft-return" directory under DerivedData — this script used to derive that
# path from $BUILD_DIR (RUNBOOK "two SPM checkouts" trap) and build from
# there. The engine now lives IN-TREE at this repo's own root
# (`Project.swift`'s `.package(path: "../")`) — there is no checkout to find
# any more; the engine root IS `${SRCROOT}/..`, this same working tree.
set -euo pipefail

ENGINE_ROOT="$(cd "${SRCROOT}/.." && pwd)"
CHECKOUT="${ENGINE_ROOT}"

if [ ! -f "${CHECKOUT}/Package.swift" ]; then
    echo "error: sr CLI engine root not found at ${CHECKOUT}" >&2
    exit 1
fi

# --scratch-path keeps this OUT of the repo's own .build, which Xcode's
# native SPM integration may also use for the CtrlKD package dependency.
DERIVED_DATA_ROOT="${BUILD_DIR}/../.."
SCRATCH="${DERIVED_DATA_ROOT}/sr-cli-scratch"

# Dev stamp (Jon's ruling 2026-08-14, b19): between releases the sr banner
# carries the engine commit's date — `sr 3.1.0 (dev YYYY-MM-DD)` — with the
# hash under `--version --verbose`. The repo commits DevStamp.swift with
# nils (a real release cut builds it untouched and gets the clean string);
# THIS script is the only place real values exist, injected for the duration
# of the build and restored on exit no matter how the build ends (`trap ...
# EXIT`), so the file never stays dirty. Job 532: `${CHECKOUT}` is now this
# same working tree (see the file header) rather than a disposable SPM
# checkout — the restore-on-exit is what keeps this safe for a real repo
# clone instead of throwaway DerivedData content; a SIGKILL mid-build (not a
# normal failure — `trap EXIT` covers those) is the one case that could
# leave `DevStamp.swift` modified in a real working tree, same as any other
# script that edits a tracked file with a restore trap. The app only links
# CtrlKD as a package dependency — SoftReturnCLI sources are compiled solely
# by the `swift build` below, so the mutation can't leak into the app target.
DEVSTAMP="${CHECKOUT}/Sources/SoftReturnCLI/DevStamp.swift"
restore_devstamp() {
    if [ -n "${DEVSTAMP_BACKUP:-}" ] && [ -f "${DEVSTAMP_BACKUP}" ]; then
        mv "${DEVSTAMP_BACKUP}" "${DEVSTAMP}"
    fi
}
if [ -f "${DEVSTAMP}" ]; then
    ENGINE_DATE="$(git -C "${CHECKOUT}" log -1 --format=%cs 2>/dev/null || true)"
    ENGINE_HASH="$(git -C "${CHECKOUT}" rev-parse --short=7 HEAD 2>/dev/null || true)"
    if [ -n "${ENGINE_DATE}" ] && [ -n "${ENGINE_HASH}" ]; then
        DEVSTAMP_BACKUP="${DEVSTAMP}.release-original"
        cp "${DEVSTAMP}" "${DEVSTAMP_BACKUP}"
        trap restore_devstamp EXIT
        cat > "${DEVSTAMP}" <<STAMP
// Injected by build-sr-cli.sh for this build only — never committed.
// The committed file (all nils) lives in the sr repo; see it for the ruling.
public let srDevDate: String? = "${ENGINE_DATE}"
public let srDevHash: String? = "${ENGINE_HASH}"
STAMP
    else
        # No git metadata in the checkout: build proceeds with the committed
        # nils (clean banner). Loud, because between releases that shape is
        # wrong and the build job's banner verification should catch it.
        echo "warning: sr dev stamp NOT injected — no git info at ${CHECKOUT}" >&2
    fi
fi

# A Run Script phase inherits EVERY Xcode build setting as an env var. Left
# alone, that leaks Debug-scheme settings (Debug Dylib / Preview Injection —
# Xcode 16's fast-iteration feature) into this child `swift build`, which then
# tries to build a SECOND "Soft Return.app" debug/preview dylib pair inside
# the scratch dir and collides with itself ("Multiple commands produce ...
# Soft Return.app/Contents/MacOS/__preview.dylib" — seen first-hand, job 248).
# A minimal, explicit environment sidesteps the whole class of leakage.
swift_build_env=(PATH="${PATH}" HOME="${HOME}")
if [ -n "${DEVELOPER_DIR:-}" ]; then
    swift_build_env+=(DEVELOPER_DIR="${DEVELOPER_DIR}")
fi
env -i "${swift_build_env[@]}" swift build --package-path "${CHECKOUT}" --scratch-path "${SCRATCH}" \
    -c release --arch arm64 --arch x86_64 --product sr

BUILT_BINARY="${SCRATCH}/apple/Products/Release/sr"
if [ ! -f "${BUILT_BINARY}" ]; then
    echo "error: swift build did not produce ${BUILT_BINARY}" >&2
    exit 1
fi

DEST_DIR="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
mkdir -p "${DEST_DIR}"
cp "${BUILT_BINARY}" "${DEST_DIR}/sr"
chmod 755 "${DEST_DIR}/sr"

# job 310 (b18) found this binary shipping real worker build-machine paths
# (full local source-tree layout, incl. usernames) in shipped DMGs since at
# least b17, undetected by every prior job's strings-scan — SPM's `-c
# release` does not strip DWARF/STABS debug info the way Xcode's own Strip
# build phase (DEPLOYMENT_POSTPROCESSING=YES) does for the main app target,
# and this script never stripped it either. Must run BEFORE codesign: strip
# invalidates any existing signature. -Sx removes debug symbols and local
# symbols; fall back to -S alone if -x ever breaks the ad-hoc signing step
# below (e.g. by removing a symbol codesign or the loader depends on).
strip -Sx "${DEST_DIR}/sr"

# Xcode's own CodeSign phase for the app validates every nested Mach-O it finds
# already carries a valid signature — it does not sign nested content itself.
# Sign PLAIN here (no entitlements, same as the mdimporter: sr is a CLI tool
# launched from Terminal, never by the app itself), nested-first, using
# whatever identity this build is about to sign the outer app with.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
    IDENTITY="-"
fi
CODESIGN_ARGS=(--force --sign "${IDENTITY}" --options runtime)
if [ "${IDENTITY}" = "-" ]; then
    # Ad-hoc identities can't get a secure timestamp from Apple's server.
    CODESIGN_ARGS+=(--timestamp=none)
fi
codesign "${CODESIGN_ARGS[@]}" "${DEST_DIR}/sr"
