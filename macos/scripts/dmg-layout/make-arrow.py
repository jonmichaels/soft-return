#!/usr/bin/env python3
"""Generate the DMG background art: a soft gray arrow from the app (left) to
/Applications (right), per Jon's mockup (2026-08-09; "red isn't a good color").

Geometry is tied to make-dmg-dsstore.py's fixed layout: 640x420 window, icons
centered at (160,200) and (480,200), 128px icons. The arrow occupies the gap
between the two icons, pointing left-to-right (the drag direction).

Renders at 4x and downsamples for clean edges. Writes background.png (640x420)
and background@2x.png (1280x840); the DMG job combines them into a HiDPI TIFF
with `tiffutil -cathidpicheck` on the Mac side.

Requires: Pillow. Usage: make-arrow.py [outdir]  (default: this script's dir)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 640, 420
SS = 4  # supersample factor

ARROW = (185, 188, 192, 255)   # soft neutral gray, slight cool bias
BG = (255, 255, 255, 255)      # matches the plain-white icvp background

# 1x geometry (icon gap spans x=224..416; icon centers y=200)
SHAFT_Y = 190
SHAFT_X0, SHAFT_X1 = 248, 366
SHAFT_HALF = 7                 # 14px-thick shaft
HEAD_LEN, HEAD_HALF = 44, 26   # arrowhead 44 long, 52 tall


def render(scale: int) -> Image.Image:
    s = SS * scale
    img = Image.new("RGBA", (W * s, H * s), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(
        [SHAFT_X0 * s, (SHAFT_Y - SHAFT_HALF) * s,
         SHAFT_X1 * s, (SHAFT_Y + SHAFT_HALF) * s],
        radius=SHAFT_HALF * s, fill=ARROW)
    d.polygon(
        [(SHAFT_X1 * s, (SHAFT_Y - HEAD_HALF) * s),
         ((SHAFT_X1 + HEAD_LEN) * s, SHAFT_Y * s),
         (SHAFT_X1 * s, (SHAFT_Y + HEAD_HALF) * s)],
        fill=ARROW)
    return img.resize((W * scale, H * scale), Image.LANCZOS)


def main(outdir: Path) -> None:
    render(1).save(outdir / "background.png")
    render(2).save(outdir / "background@2x.png")
    for name in ("background.png", "background@2x.png"):
        p = outdir / name
        print(f"wrote {p} ({p.stat().st_size} bytes)")


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent
    main(out)
