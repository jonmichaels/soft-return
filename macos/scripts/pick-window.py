"""Pick one window out of window-list.swift's JSON.

    window-list "Soft Return" | pick-window.py <index> <app-name>

Prints `<windowID> <width>x<height>` on stdout; prints the candidate list on
stderr so a human reviewing the log can see what was chosen from. Considers
only layer 0 — ordinary application windows, not menu-bar extras or panels.
"""

import json
import sys


def main() -> int:
    index = int(sys.argv[1])
    app = sys.argv[2]

    windows = [w for w in json.load(sys.stdin) if w["layer"] == 0]
    if not windows:
        print(f"pick-window: no layer-0 window owned by {app!r} is on screen", file=sys.stderr)
        return 1

    print("  candidates:", file=sys.stderr)
    for i, w in enumerate(windows):
        mark = "*" if i == index else " "
        size = f'{int(w["width"])}x{int(w["height"])}'
        at = f'({int(w["x"])},{int(w["y"])})'
        print(f'   {mark}[{i}] id={w["windowID"]} {size} at {at}', file=sys.stderr)

    if index >= len(windows):
        print(f"pick-window: index {index} out of range ({len(windows)} windows)", file=sys.stderr)
        return 1

    chosen = windows[index]
    print(f'{chosen["windowID"]} {int(chosen["width"])}x{int(chosen["height"])}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
