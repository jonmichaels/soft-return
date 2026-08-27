#!/usr/bin/env python3
"""Generate the DMG's .DS_Store so every build ships the SAME Finder layout.

Jon's rulings (2026-08-08): fixed layout every build; Soft Return.app on the
LEFT, Applications on the RIGHT (drag flows left-to-right); arrow art comes
later as a background image (backgroundType 2 + alias blob, next iteration).

Record recipe is dmgbuild's (the tool the Mac indie world uses): plain dicts
handed to ds_store (it serializes them itself — pre-serializing to bplist
was v1's bug, Finder discarded those records and fell back to defaults),
plus the icvl record selecting icon view, which v1 omitted. Verified against
dmgbuild/core.py lines 273-316, 417, 784-794.

Two modes:
  make-dmg-dsstore.py <staging-dir>
      Plain white background (the dev-o/dev-p layout). Runs anywhere.
  make-dmg-dsstore.py --volume <mounted-volume-root>
      Arrow background (backgroundType 2 + alias blob, dmgbuild's flow):
      expects .background/background.tiff already copied onto the volume,
      builds a mac_alias Alias for it, writes .DS_Store at the volume root.
      Must run ON macOS against the MOUNTED UDRW image — the alias records
      real volume metadata, which is the whole reason for the
      mount-write-detach flow. Verified against dmgbuild/core.py 273-316
      (icvp recipe) and 417 (backgroundImageAlias as binary plist data).

Imports resolve from scripts/vendor/ (ds_store, mac_alias vendored there —
the worker cannot pip-install), falling back to any system install.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))

from ds_store import DSStore

APP_NAME = "Soft Return.app"
APPLICATIONS = "Applications"

WINDOW_BOUNDS = "{{200, 200}, {640, 420}}"  # x, y, w, h

BWSP = {
    "ShowStatusBar": False,
    "WindowBounds": WINDOW_BOUNDS,
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
    "SidebarWidth": 0,
    "ShowTabView": False,
    "ShowToolbar": False,
    "ShowPathbar": False,
    "ShowSidebar": False,
}

ICVP = {
    "viewOptionsVersion": 1,
    "backgroundType": 0,  # plain; 2 = picture when the arrow art lands
    "backgroundColorRed": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorBlue": 1.0,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "arrangeBy": "none",
    "showIconPreview": True,
    "showItemInfo": False,
    "labelOnBottom": True,
    "textSize": 12.0,
    "iconSize": 128.0,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
}

ICON_POSITIONS = {
    APP_NAME: (160, 200),      # LEFT — the thing being installed
    APPLICATIONS: (480, 200),  # RIGHT — where it goes
}


BACKGROUND_REL = ".background/background.tiff"


def make(staging: Path, background: Path | None = None) -> Path:
    icvp = dict(ICVP)
    if background is not None:
        from mac_alias import Alias

        # plistlib.FMT_BINARY (ds_store 1.3.3's serializer) writes plain
        # `bytes` as <data>, which is exactly what Finder expects here.
        icvp["backgroundType"] = 2
        icvp["backgroundImageAlias"] = Alias.for_file(str(background)).to_bytes()

    out = staging / ".DS_Store"
    if out.exists():
        out.unlink()
    with DSStore.open(str(out), "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = BWSP
        d["."]["icvp"] = icvp
        d["."]["icvl"] = (b"type", "icnv")  # icon view — v1's missing record
        for name, pos in ICON_POSITIONS.items():
            d[name]["Iloc"] = pos
    return out


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--volume":
        volume = Path(sys.argv[2])
        background = volume / BACKGROUND_REL
        if not background.is_file():
            sys.exit(f"missing background art on volume: {background}")
        out = make(volume, background=background)
    elif len(sys.argv) == 2:
        staging = Path(sys.argv[1])
        if not staging.is_dir():
            sys.exit(f"not a directory: {staging}")
        out = make(staging)
    else:
        sys.exit(__doc__)
    print(f"wrote {out} ({out.stat().st_size} bytes)")
