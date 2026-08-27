# Icon source art — Jon Michaels, final set delivered 2026-08-16

- app-icon-1024.png — the app icon: full-bleed square, transparency,
  NO baked platform shape (the OS applies its own mask). Feeds the
  AppIcon asset catalog for all sizes.
- doc-icon-1024.png — the .WS document icon (dog-eared page + star).
- SoftReturn.icon — Icon Composer bundle (Liquid Glass layers, Jon's
  2026-08-16 19:20 save: grin=glass/no-translucency, echo pair
  specular, background glass+specular+25% translucency). For the
  macOS/iOS 26+ glass rendering path; flat PNGs are the fallback and
  the doc icon. Renamed from Soft-Return-App-LG.icon (job 341, b23):
  `ASSETCATALOG_COMPILER_APPICON_NAME` must equal the bundle's own
  base name, and "SoftReturn" is the clean value Project.swift wires.
Authoritative source: the maintainer's private design vault (not distributed here).
CHECKSUMS.txt pins this delivery; regenerate it if Jon ships new art.
