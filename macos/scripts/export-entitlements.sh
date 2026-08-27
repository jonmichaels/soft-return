#!/bin/bash
# Extract the BUILD-TIME entitlements actually baked into a signed .app and its two
# appexes, strip `get-task-allow`, and write each as its own XML plist.
#
#   macos/scripts/export-entitlements.sh <path/to/Foo.app> <output-dir>
#
# Why this exists: Quick Look failing on Jon's dev-g console traced to dev builds being
# re-signed WITHOUT entitlements — a sandboxed appex with none at all refuses to load.
# These three plists are the staging artifact for that signing chain: proof, read
# straight off a real build, that each carries the entitlements it's supposed to and
# nothing a distributable build should ship with (get-task-allow, which marks a binary
# as debugger-attachable and has no business outside a dev signature). Job 392: the app
# and the two appexes are no longer the same shape — QuickLook/Thumbnail stay sandboxed
# (app-sandbox present, Apple-mandatory for extensions), the app itself does NOT carry
# app-sandbox anymore (Jon's un-sandboxing ruling) and keeps only application-groups.
# `scripts/entitlements_probe.py` is the gate that gets to assert the difference
# (--require on the appexes, --forbid on the app); this script just extracts.
#
# Writes ent-app.plist, ent-quicklook.plist, ent-thumbnail.plist into <output-dir>.

set -euo pipefail

APP_PATH="${1:?usage: export-entitlements.sh <path/to/Foo.app> <output-dir>}"
OUT_DIR="${2:?usage: export-entitlements.sh <path/to/Foo.app> <output-dir>}"

[[ -d "$APP_PATH" ]] || { echo "export-entitlements: no such app bundle: $APP_PATH" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# `codesign -d --entitlements -` writes the entitlements to stdout; `--xml` forces XML
# plist output regardless of whether the signature stores them as XML or DER (the format
# Apple has used since the Big Sur-era codesign) — without it, a DER-stored blob comes
# out as bytes `plutil`/`plistlib` cannot parse.
extract_entitlements() {
    local binary="$1" out_file="$2"
    local raw
    raw="$(xcrun codesign -d --entitlements - --xml "$binary" 2>/dev/null)" || {
        echo "export-entitlements: codesign found no entitlements on $binary" >&2
        return 1
    }
    printf '%s' "$raw" | python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
plist = plistlib.loads(data)
# Strip get-task-allow: it marks the binary as debugger-attachable, a dev-signature-only
# concern that has no place in a plist meant to stand in for a distributable signature.
plist.pop("com.apple.security.get-task-allow", None)
sys.stdout.buffer.write(plistlib.dumps(plist, fmt=plistlib.FMT_XML))
' > "$out_file"
    echo "  wrote $out_file"
}

# The executable inside a bundle is named by CFBundleExecutable, not assumed from the
# bundle's own name — Contents/MacOS holds exactly one binary either way, so globbing it
# is the same fact read a simpler way.
executable_in() {
    local bundle="$1"
    local bin
    bin="$(find "$bundle/Contents/MacOS" -maxdepth 1 -type f | head -n 1)"
    [[ -n "$bin" ]] || { echo "export-entitlements: no executable under $bundle/Contents/MacOS" >&2; exit 1; }
    printf '%s' "$bin"
}

APP_BIN="$(executable_in "$APP_PATH")"
extract_entitlements "$APP_BIN" "$OUT_DIR/ent-app.plist"

QUICKLOOK_APPEX="$(find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -iname '*quicklook*.appex' | head -n 1)"
[[ -n "$QUICKLOOK_APPEX" ]] || { echo "export-entitlements: no QuickLook appex under $APP_PATH/Contents/PlugIns" >&2; exit 1; }
extract_entitlements "$(executable_in "$QUICKLOOK_APPEX")" "$OUT_DIR/ent-quicklook.plist"

THUMBNAIL_APPEX="$(find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -iname '*thumbnail*.appex' | head -n 1)"
[[ -n "$THUMBNAIL_APPEX" ]] || { echo "export-entitlements: no Thumbnail appex under $APP_PATH/Contents/PlugIns" >&2; exit 1; }
extract_entitlements "$(executable_in "$THUMBNAIL_APPEX")" "$OUT_DIR/ent-thumbnail.plist"

echo "export-entitlements: done — $OUT_DIR/ent-app.plist, ent-quicklook.plist, ent-thumbnail.plist"
