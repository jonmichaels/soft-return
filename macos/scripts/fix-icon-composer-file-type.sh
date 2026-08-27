#!/bin/bash
# Job 341 (b23, item D): Tuist's `.folderReference(path:)` emits a PBXFileReference for
# IconAssets/SoftReturn.icon with NO file-type attribute at all (`isa = PBXFileReference;
# path = SoftReturn.icon; sourceTree = "<group>";` — not even a plain "folder" type). Xcode
# 26's icon-composer pipeline requires `lastKnownFileType = folder.iconcomposer.icon;` on
# that reference (Ghostty's own shipping project, verified against its public pbxproj) or the
# bundle is treated as an ordinary opaque resource folder rather than an icon source, and the
# glass-rendering path never activates. `tuist generate` re-emits the bare reference on every
# run, so this script re-patches it every time — run it after every `tuist generate`.
set -euo pipefail
PBXPROJ="SoftReturn.xcodeproj/project.pbxproj"

if grep -q 'lastKnownFileType = folder.iconcomposer.icon; path = SoftReturn.icon;' "$PBXPROJ"; then
    echo "fix-icon-composer-file-type: already patched, nothing to do"
    exit 0
fi

if ! grep -q 'isa = PBXFileReference; path = SoftReturn.icon; sourceTree = "<group>";' "$PBXPROJ"; then
    echo "fix-icon-composer-file-type: expected bare PBXFileReference line not found — Tuist's own emission may have changed shape, needs a fresh look" >&2
    exit 1
fi

sed -i '' \
    's/isa = PBXFileReference; path = SoftReturn\.icon; sourceTree = "<group>";/isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = SoftReturn.icon; sourceTree = "<group>";/' \
    "$PBXPROJ"

echo "fix-icon-composer-file-type: patched"
