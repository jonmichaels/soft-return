#!/usr/bin/env bash
# PINNED PAPER MEANS PINNED INK.
#
# Jon's rule, 2026-08-24: "Text colors must be pinned if the background color
# is pinned."
#
# WHY THIS EXISTS. b28 shipped with Modern footnotes and endnotes INVISIBLE.
# The paper is pinned white (`PagedDocumentView`: `view.backgroundColor =
# .white // paper, not a UI surface`), but the text used `NSColor.textColor`,
# which is not a colour -- it is a promise to be black in Light Mode and WHITE
# in Dark Mode. Jon works in Dark Mode in the early morning and late evening,
# so he saw a blank page; anyone checking at midday saw nothing wrong.
#
# THE TESTS CANNOT CATCH THIS. The headless Mac composites in Light Mode, so
# three rounds of rendering tests passed while the bug was live. That is why
# this is a SOURCE rule and not a rendering comparison -- no image test on that
# host can see it.
#
# Colours that follow the system theme belong on UI chrome (toolbars, the
# canvas *around* the paper). They must never be used for anything drawn ON
# the paper, or exported.
set -uo pipefail
cd "$(dirname "$0")/.."

# Semantic AppKit colours: these RESOLVE DIFFERENTLY per theme.
DYNAMIC='NSColor\.(textColor|labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|controlTextColor|selectedTextColor|selectedControlTextColor|placeholderTextColor|headerTextColor|textBackgroundColor|controlBackgroundColor|separatorColor|gridColor|linkColor|shadowColor)\b'

# Where paper is drawn or exported. UI chrome is deliberately NOT scanned.
SCAN_DIRS=(macos/SoftReturn/Rendering macos/SoftReturn/Export)

# Legitimate exceptions, each with a stated reason. Add here only when the
# colour genuinely paints a UI surface rather than paper.
#   CanvasColor.swift — the canvas AROUND the paper is a window surface and
#   SHOULD follow the theme; the paper it frames is pinned separately.
EXCLUDE='macos/SoftReturn/Rendering/CanvasColor\.swift'

# Comment lines are skipped: the fix's own explanation names the banned colour,
# and a scanner that flags the note explaining the rule is a scanner nobody
# keeps. Matched on the line's own leading text, so trailing `// ...` after real
# code is still scanned.
COMMENT='^[^:]+:[0-9]+: *(//|\*|/\*)'

hits=$(grep -rnE "$DYNAMIC" "${SCAN_DIRS[@]}" 2>/dev/null \
       | grep -vE "$EXCLUDE" | grep -vE "$COMMENT")

if [ -n "$hits" ]; then
    echo "PINNED-PAPER VIOLATION: theme-dependent colour drawn on pinned paper"
    echo "$hits"
    echo ""
    echo "These resolve to WHITE in Dark Mode. The paper is pinned white, so the"
    echo "result is invisible text -- exactly the b28 notes bug."
    echo "Use an explicit colour (NSColor.black, or the document's own colour)."
    echo "If this genuinely paints UI chrome and not paper, add it to EXCLUDE"
    echo "above WITH A REASON."
    exit 1
fi

# Positive control: a scanner that has never matched has not been tested.
if ! grep -rqE 'NSColor\.' "${SCAN_DIRS[@]}" 2>/dev/null; then
    echo "SCANNER IS NOT READING FILES -- its 'clean' result is meaningless"
    exit 1
fi

echo "pinned-paper check clean: no theme-dependent colour drawn on paper"
exit 0
