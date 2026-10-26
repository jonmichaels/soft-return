#!/bin/bash
# Usage: fix-icon-composer-file-type.sh <path to project.pbxproj>
#
# Tuist's `.folderReference(path:)` emits a PBXFileReference for IconAssets/SoftReturn.icon
# with NO file-type attribute at all (`isa = PBXFileReference; path = SoftReturn.icon;
# sourceTree = "<group>";` — not even a plain "folder" type). Xcode 26's icon-composer
# pipeline requires `lastKnownFileType = folder.iconcomposer.icon;` on that reference
# (Ghostty's own shipping project, verified against its public pbxproj) or the bundle is
# treated as an ordinary opaque resource folder rather than an icon source: the glass-rendering
# path never activates on the Mac, and the asset compiler never builds an app icon on the
# iPhone. Both apps use the same icon file (the iPhone project references the Mac app's
# `macos/IconAssets/SoftReturn.icon`).
#
# `tuist generate` re-emits the bare reference on every run, so run this after every
# `tuist generate`, once per project:
#   macos/scripts/fix-icon-composer-file-type.sh macos/SoftReturn.xcodeproj/project.pbxproj
#   macos/scripts/fix-icon-composer-file-type.sh ios/SoftReturnIOS.xcodeproj/project.pbxproj
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: fix-icon-composer-file-type.sh <path to project.pbxproj>" >&2
    exit 2
fi
PBXPROJ="$1"

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
