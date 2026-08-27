#!/bin/bash
# Capture one app's window to a PNG, so a claim about what the app LOOKS like
# can ship with the picture that proves it.
#
#   macos/scripts/screenshot-window.sh "Soft Return" /path/out.png [index]
#
# Matches on the window's owning application name and layer 0 (ordinary app
# windows), never on the title — see the note in window-list.swift for why
# titles are unreadable here. When an app has several windows, `index` picks
# one (default 0) and the script prints the full list first so you can see
# what you chose from.
#
# Requires Screen Recording for the process running this. Without it
# `screencapture` yields a plausible-looking but empty rectangle rather than
# failing outright — which is exactly why the rule around here is that whoever
# runs this OPENS the resulting PNG and looks at it. The script reports the
# window it chose and the file it wrote; it does not certify the contents.

set -euo pipefail

APP="${1:?usage: screenshot-window.sh <app-name> <out.png> [index]}"
OUT="${2:?usage: screenshot-window.sh <app-name> <out.png> [index]}"
INDEX="${3:-0}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISTER="$REPO/.build/tools/window-list"

if [[ ! -x "$LISTER" || "$REPO/scripts/window-list.swift" -nt "$LISTER" ]]; then
    mkdir -p "$REPO/.build/tools"
    swiftc -O "$REPO/scripts/window-list.swift" -o "$LISTER"
fi

CHOICE="$("$LISTER" "$APP" | python3 "$REPO/scripts/pick-window.py" "$INDEX" "$APP")"
WINDOW_ID="${CHOICE%% *}"
GEOMETRY="${CHOICE##* }"

# Who actually owns this window. A window ID belonging to a previous or already-dead
# process captures happily and looks completely plausible, so the owner and its start
# time get printed rather than assumed. If the PID predates a build you just made, the
# picture is of the OLD app.
OWNER_PID="$("$LISTER" "$APP" | python3 -c '
import json, sys
windows = [w for w in json.load(sys.stdin) if w["layer"] == 0]
print(windows[int(sys.argv[1])]["ownerPID"] if windows else "")
' "$INDEX" 2>/dev/null || true)"
if [[ -n "$OWNER_PID" ]]; then
    echo "  window $WINDOW_ID owned by pid $OWNER_PID, started $(ps -o lstart= -p "$OWNER_PID" 2>/dev/null | xargs || echo '?')"
fi

# The moment the capture was asked for. Anything older than this is a stale file that
# screencapture failed to replace, and reading it would be reading the past.
BEFORE="$(date +%s)"
rm -f "$OUT"

# -x silences the shutter, -o drops the drop shadow so the image is just the window.
screencapture -x -o -l"$WINDOW_ID" "$OUT"

if [[ ! -s "$OUT" ]]; then
    echo "screenshot-window: screencapture wrote nothing to $OUT" >&2
    exit 1
fi

# Refuse to hand back a PNG that predates the request. This is the cheap guard against
# the whole class of failure where the instrument returns the same answer every time —
# which is indistinguishable from "the app never changed" until you check.
WRITTEN="$(stat -f %m "$OUT")"
if (( WRITTEN < BEFORE )); then
    echo "screenshot-window: $OUT is older than this capture (written $WRITTEN, asked $BEFORE) — STALE, refusing" >&2
    exit 1
fi

PIXELS="$(sips -g pixelWidth -g pixelHeight "$OUT" | awk '/pixel/ {printf "%s ", $2}')"
echo "  wrote $OUT (${PIXELS}pixels, window id $WINDOW_ID, $GEOMETRY points)"
echo "  now LOOK at it — this script does not certify what is in the image."
