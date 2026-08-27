#!/bin/bash
set -euo pipefail
SRC="IconAssets/app-icon-1024.png"
DEST="SoftReturn/Resources/Assets.xcassets/AppIcon.appiconset"

xcrun sips -z 16 16 "$SRC" --out "$DEST/icon_16x16.png"
xcrun sips -z 32 32 "$SRC" --out "$DEST/icon_16x16@2x.png"
xcrun sips -z 32 32 "$SRC" --out "$DEST/icon_32x32.png"
xcrun sips -z 64 64 "$SRC" --out "$DEST/icon_32x32@2x.png"
xcrun sips -z 128 128 "$SRC" --out "$DEST/icon_128x128.png"
xcrun sips -z 256 256 "$SRC" --out "$DEST/icon_128x128@2x.png"
xcrun sips -z 256 256 "$SRC" --out "$DEST/icon_256x256.png"
xcrun sips -z 512 512 "$SRC" --out "$DEST/icon_256x256@2x.png"
xcrun sips -z 512 512 "$SRC" --out "$DEST/icon_512x512.png"
xcrun sips -z 1024 1024 "$SRC" --out "$DEST/icon_512x512@2x.png"
