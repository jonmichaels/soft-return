#!/usr/bin/env python3
"""Generate the DMG's .DS_Store so every build ships the SAME Finder layout.

Jon's rulings (2026-08-08): fixed layout every build; Soft Return.app on the
LEFT, Applications on the RIGHT (drag flows left-to-right); arrow art comes
later as a background image (backgroundType 2 + alias blob, next iteration).

Record recipe is dmgbuild's (the tool the Mac indie world uses): plain dicts
handed to ds_store (it serializes them itself -- pre-serializing to bplist
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
      Must run ON macOS against the MOUNTED UDRW image -- the alias records
      real volume metadata, which is the whole reason for the
      mount-write-detach flow. Verified against dmgbuild/core.py 273-316
      (icvp recipe) and 417 (backgroundImageAlias as binary plist data).

THE ALIAS CARRIES NO BUILD-MACHINE PATH (planning #275 item 1, 2026-09-15)
-------------------------------------------------------------------------
v4.2.0 and v4.1.0 both shipped a DMG whose .DS_Store contained the build
account's mount point in plain text -- found by the v4.2.0 post-publish
user-eye audit, the one FAIL of 37 rows. The leak is structural, not ours
alone: dmgbuild does `Alias.for_file(os.path.join(mount_point, ".background"))`
and writes `alias.to_bytes()` with no scrubbing at all (checked against
dmgbuild main, 2026-09-15), so every dmgbuild-built DMG in the world carries
whatever path its builder mounted the image at. We deviate deliberately.

A version-2 alias record stores the target in FOUR redundant ways:

    volume name (28p, in the fixed header)       "Soft Return"
    target filename (64p, in the fixed header)   "background.tiff"
    TAG_CARBON_PATH (2)     volume-relative      "Soft Return:.background:..."
    TAG_POSIX_PATH (18)     volume-relative      "/.background/background.tiff"
    TAG_CNID_PATH (1)       volume-relative      inode numbers
    TAG_POSIX_PATH_TO_MOUNTPOINT (19)  ABSOLUTE  "/Users/<builder>/<mnt dir>"

Only the last one is absolute, and it is the only one that names the machine
that built the DMG. It is also the only one that is WRONG for every user who
ever opens the DMG: their copy mounts at /Volumes/<volume name>, never at the
builder's mount point, so nothing can usefully resolve through it. The other
five are all volume-relative and are what Finder actually resolves through
when it opens a .DS_Store that sits on the very volume the background lives
on. So `scrub_alias()` drops tag 19 (plus tags 20/21, which can also carry
host-side paths: a recursive alias of the disk image on the builder's disk,
and the length of the builder's home-directory prefix) and writes the rest
unchanged.

`assert_no_builder_paths()` then RE-READS the written file and refuses any
absolute POSIX path in it other than the one volume-relative background path,
and any `/Users/`-shaped or classic-Mac `Users:`-shaped string in any of the
three encodings the bytes could carry one in. A leak that is only prevented
and never checked is a leak waiting for the next refactor.

VERIFIED ON LINUX: the alias-bytes writer, the scrub, the assertion, and the
whole .DS_Store round-trip (tools/test_dmg_dsstore.py -- ds_store and
mac_alias serialization are pure Python). NEEDS A MAC, once per release:
that Finder still draws the arrow background from the scrubbed alias when the
built DMG is opened by double-click. That is a look check, not a byte check;
put it on the release checklist's DMG row.

Imports resolve from scripts/vendor/ (ds_store, mac_alias vendored there --
the worker cannot pip-install), falling back to any system install.
"""

from __future__ import annotations

import re
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
    APP_NAME: (160, 200),      # LEFT -- the thing being installed
    APPLICATIONS: (480, 200),  # RIGHT -- where it goes
}


BACKGROUND_REL = ".background/background.tiff"

# The one absolute-looking string the written file is allowed to contain: the
# alias's TAG_POSIX_PATH, which is relative to the DMG's own volume root and
# so begins with "/" without naming any machine.
ALLOWED_ABSOLUTE_PATHS = ("/" + BACKGROUND_REL,)

# mac_alias tag numbers for the three records that can carry a path on the
# BUILDING machine. Dropped before serialization; see the module docstring.
TAG_POSIX_PATH_TO_MOUNTPOINT = 19
TAG_RECURSIVE_ALIAS_OF_DISK_IMAGE = 20
TAG_USER_HOME_LENGTH_PREFIX = 21

# Shapes that are a leak wherever they appear, in any encoding. Deliberately
# the same shapes tools/private_patterns.sh rejects for the source tree -- a
# build artifact is exactly as public as a source file.
LEAK_SHAPES = (
    "/Users/",
    "/home/",
    "/root/",
    "/mnt/",
    "/private/",
    "/var/folders/",
    "/Volumes/",
    "Users:",
)

# An absolute POSIX path of at least two segments. One-segment runs ("/A")
# are ordinary binary coincidences in CNIDs and dates; a two-segment run is
# a path.
_PATH_RUN = re.compile(rb"(?:/[A-Za-z0-9._][A-Za-z0-9._ +\-]*){2,}")


class BuilderPathLeak(Exception):
    """A written artifact carries a path from the machine that built it."""


def scrub_alias(alias):
    """Drop every record that names the BUILDING machine, in place.

    Returns the same alias object so this reads as a pipeline step. What is
    left is volume-relative: volume name, filename, Carbon path, CNID path
    and the volume-relative POSIX path -- everything Finder resolves a
    same-volume background image through.
    """
    alias.volume.posix_path = None          # tag 19, the v4.2.0 leak
    alias.volume.disk_image_alias = None    # tag 20, an alias to the .dmg itself
    alias.extra = [(tag, value) for (tag, value) in getattr(alias, "extra", [])
                   if tag not in (TAG_POSIX_PATH_TO_MOUNTPOINT,
                                  TAG_RECURSIVE_ALIAS_OF_DISK_IMAGE,
                                  TAG_USER_HOME_LENGTH_PREFIX)]
    return alias


def background_alias_bytes(background: Path) -> bytes:
    """Serialized, scrubbed alias for a background file on a mounted volume.

    macOS only -- mac_alias.Alias.for_file() reads volume metadata through
    statfs/getattrlist. The bytes it produces are checked here before they
    can reach a .DS_Store, so a future mac_alias that adds another
    host-side record fails loudly instead of shipping.
    """
    from mac_alias import Alias

    alias = scrub_alias(Alias.for_file(str(background)))
    blob = alias.to_bytes()
    assert_no_builder_paths(blob, "the background-image alias")
    return blob


def assert_no_builder_paths(blob: bytes, what: str = "the written .DS_Store") -> None:
    """Refuse any build-machine path in `blob`. Raises BuilderPathLeak."""
    found = []

    for shape in LEAK_SHAPES:
        for encoding in ("utf-8", "utf-16-be", "utf-16-le"):
            if shape.encode(encoding) in blob:
                label = shape if encoding == "utf-8" else f"{shape} (as {encoding})"
                found.append(label)

    for match in _PATH_RUN.finditer(blob):
        run = match.group(0).decode("utf-8", "replace")
        if run not in ALLOWED_ABSOLUTE_PATHS:
            found.append(run)

    if found:
        raise BuilderPathLeak(
            f"{what} carries a path from the machine that built it: "
            + ", ".join(repr(f) for f in sorted(set(found)))
            + f"\nAllowed absolute strings: {', '.join(ALLOWED_ABSOLUTE_PATHS)}"
            + "\nSee this script's docstring (planning #275 item 1): the alias"
              " must be volume-relative."
        )


def make(staging: Path, background: Path | None = None,
         alias_bytes: bytes | None = None) -> Path:
    """Write staging/.DS_Store. `alias_bytes` is for tests off a Mac."""
    icvp = dict(ICVP)
    if background is not None or alias_bytes is not None:
        # plistlib.FMT_BINARY (ds_store 1.3.3's serializer) writes plain
        # `bytes` as <data>, which is exactly what Finder expects here.
        icvp["backgroundType"] = 2
        icvp["backgroundImageAlias"] = (alias_bytes if alias_bytes is not None
                                        else background_alias_bytes(background))

    out = staging / ".DS_Store"
    if out.exists():
        out.unlink()
    with DSStore.open(str(out), "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = BWSP
        d["."]["icvp"] = icvp
        d["."]["icvl"] = (b"type", "icnv")  # icon view -- v1's missing record
        for name, pos in ICON_POSITIONS.items():
            d[name]["Iloc"] = pos

    # READ BACK THE BYTES THAT WERE ACTUALLY WRITTEN. Asserting on the
    # in-memory dicts would prove the intent, not the file; the v4.2.0 audit
    # found the leak by reading the shipped file, and so does this.
    try:
        assert_no_builder_paths(out.read_bytes())
    except BuilderPathLeak:
        out.unlink()  # never leave a leaking .DS_Store behind to be picked up
        raise
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
    print("readback: no build-machine path in the .DS_Store")
