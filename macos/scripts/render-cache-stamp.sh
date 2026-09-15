#!/bin/bash
# Planning #262, item 4: the renderer version the corpus oracles' render cache keys on
# (`SoftReturnTests/RenderCache.swift`). Writes RenderCacheStamp.plist into the test bundle on
# every build: a digest of the committed trees of the sources a render depends on, plus a digest
# of every uncommitted change — staged, unstaged and untracked — under the same sources. So a
# renderer edit made and tested before it is committed still changes the key, and its stale
# renders are never served.
#
# The committed half is those paths' tree hashes, not the commit (batch 16): keyed on the commit,
# a commit touching nothing a render reads — an outbox report — threw away every entry.
#
# No git, or not a checkout: the stamp is empty and the cache stays off (every render runs).
set -uo pipefail
out="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/RenderCacheStamp.plist"
repo="${SRCROOT}/.."
stamp=""
paths=(Package.swift Sources Shared macos/Project.swift macos/Tuist.swift macos/SoftReturn macos/SoftReturnTests macos/Vendor)
if trees=$(git -C "$repo" ls-tree HEAD -- "${paths[@]}" 2>/dev/null) && [ -n "$trees" ]; then
    committed=$(printf '%s\n' "$trees" | shasum -a 256 | cut -c1-24)
    digest=$(
        {
            git -C "$repo" diff HEAD --binary -- "${paths[@]}"
            git -C "$repo" ls-files --others --exclude-standard -z -- "${paths[@]}" \
                | (cd "$repo" && xargs -0 shasum -a 256 2>/dev/null)
        } | shasum -a 256 | cut -c1-16
    )
    stamp="tree-${committed}-${digest}"
fi
mkdir -p "$(dirname "$out")"
cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>stamp</key>
	<string>${stamp}</string>
</dict>
</plist>
PLIST
echo "render-cache-stamp: ${stamp:-(none: cache off)}"
