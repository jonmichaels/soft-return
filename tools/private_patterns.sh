#!/usr/bin/env bash
# THE deny pattern. One definition, sourced by tools/audit_private.sh and by
# the repository's pre-commit / pre-push hooks, so they can never drift apart
# from each other the way three hand-copied lists did before.
#
# WHY THIS FILE EXISTS. A denylist of yesterday's leaked literals can only
# ever catch the leak that already happened. The rule is about SHAPE, not
# vocabulary: no filesystem path to anybody's machine, ever, in any encoding.
# A guard built from a word list passed a brand-new path shape straight
# through once; a guard built from shapes does not have that failure mode.
#
# Encodings matter too: a real personal path once survived here for eleven
# days because it was base64-encoded inside a recorded event fixture and
# every scanner only ever grepped raw file bytes as text. See
# tools/audit_private.sh's base64 pass, which exists because of that.
#
# Two refinements this list needed once it was run over a documentation-heavy
# tree for the first time:
#   (a) PAT_SHAPE's old `~/[A-Za-z]` alternative matched ANY tilde path,
#       including the generic folder examples this repo's own docs are full of
#       (`~/Desktop`, `~/Library`, `~/Downloads`, `~/projects`, `~/Dropbox`).
#       None of those name a real person -- `~` alone is resolved by the shell
#       to whoever is running it and never carries a username. Only `~name`
#       (no slash -- shell tilde-user expansion) actually encodes an identity.
#       Narrowed accordingly; see the note at PAT_SHAPE.
#   (b) A few of PAT_HOSTS's entries are also ordinary English words. See
#       PAT_SAFE_COLLOCATIONS.
#
# NOTE ON THIS FILE'S OWN CONTENT. Every pattern below is written with a
# single-character bracket class inside the word (`hea[r]th`, not `hearth`).
# grep -E matches them identically, and it keeps this file from carrying, in
# plain text, the very strings it exists to reject -- which is what lets a
# guard like this live in a public tree at all.

# 1. Named private things. Historical; grows only after a real leak, and only
#    for identifiers that are NOT already a legitimate, pervasively-used
#    category label elsewhere in this project. The private corpus group name
#    is deliberately NOT listed: it is an accepted, already-public naming
#    convention, and what leaked was never the label -- it was the real
#    machine path around a document carrying it.
PAT_NAMES='(Dropb[o]x[:/]Proj[e]cts_Writing|jmw[o]rk1-ws-fl[o]ppy|s[o]ft-return-testing)'

# 2. The real shape rule: an absolute path into a named user's home on any
#    machine, in either POSIX or classic-Mac (colon-delimited) form. Corpus
#    roots come from the environment (`CTRLKD_PRIVATE_CORPUS`), never from a
#    literal. Anchored to a following name char so a bare "~" or a stray
#    "/Users" fragment is not a hit. The colon form is not optional: one real
#    leak carried the SAME path a second time in classic Mac form
#    (`Users:name:...`), which a slash-only shape would not have caught.
#
#    The tilde alternative matches ONLY tilde-user expansion (`~name`, no
#    slash). A generic `~<letter>` shape matched far more than personal paths:
#    every bare `~/<folder>` example in the docs, Swift's bitwise-NOT operator
#    (`~len`, `~UInt16(0o111)`), Markdown strikethrough (`~~text~~`), and
#    "approximately" in ordinary prose (`~col 30`, `~390 files`) -- none of
#    which name anybody.
PAT_SHAPE='(~j[o]n\b|~w[o]rker\b|/home/[A-Za-z]|/Users/[A-Za-z]|Users:[A-Za-z][A-Za-z0-9_]*:|/mnt/[A-Za-z]|/root/[A-Za-z])'

# 3. Machine names, including in commit author/committer fields -- a hostname
#    in metadata is exactly as public as one in a file (learned the hard way,
#    after `worker@<host>` sat in 319 commits unnoticed). Two entries are
#    common English words, so they get explicit word boundaries and the
#    collocation filter below.
PAT_HOSTS='(hum[u]ng\.us|chon[k]y|borg[c]ube|noi[s]y|hea[r]th|grogn[a]rd|\btac[o]\b)'

# 4. Private-network addresses: Tailscale's CGNAT range (100.64.0.0/10) and
#    the three RFC1918 LAN ranges -- a LAN or tailnet address identifies a
#    home network as surely as a hostname does. FOUR dotted octets required,
#    always: a three-octet pattern matched a source-comment date
#    ("Created by ... on 10.07.07") and macOS version strings like `10.15.7`
#    as if they were addresses. Real IPv4 is always 4.
PAT_NET='\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})\b'

# 5. Private document aliases, and the private-corpus-group alias SHAPE, so a
#    re-introduction of either trips this guard immediately rather than
#    needing rediscovery. \b-anchored and uppercase-only (no -i flag on the
#    scanners here) because two of the aliases are ordinary lowercase English
#    words too -- it must never fire on "their"/"depart"/"partway" prose.
PAT_DOCNAMES='\b(G[A]Y|H[E]R|IN[D]IAN|I[W]W|PA[R]T|SU[D]AN)\b'
PAT_PRIVGROUP='(j[o]n-floppies|w[s]7-private|fixtures-w[s]5)-v4-[0-9]'

PAT="($PAT_NAMES|$PAT_SHAPE|$PAT_HOSTS|$PAT_NET|$PAT_DOCNAMES|$PAT_PRIVGROUP)"

# Known, reviewed, NON-hostname English usages of the real-word names in
# category 3, and of the uppercase aliases in category 5. A raw PAT hit inside
# one of these phrases is a false positive, not a leak -- filtered out by the
# scanners (grep -v) AFTER the PAT match, never by weakening PAT_HOSTS itself
# (that would stop catching the actual hostname). Grows only after a real
# collision is found, never speculatively.
PAT_SAFE_COLLOCATIONS='(not just noi[s]y|too noi[s]y|very noi[s]y|noi[s]y (neighbou?r|signal|data|background|environment|channel)|(warm|cozy|by the|kitchen) hea[r]th|tac[o] (tuesday|truck|bell|bar|night)|PA[R]T [AB]\b|clips PA[R]T of|PA[R]T of the)'

# Known generic PLACEHOLDER names -- a placeholder names nobody, the same
# reasoning as the tilde narrowing above. Filtered the same way as
# PAT_SAFE_COLLOCATIONS, so it only needs listing once and cannot drift from
# what actually gets used.
#    NOTE: does not include "exampleuser" -- tools/test_audit_private.sh's own
#    positive control deliberately uses `/Users/exampleuser/...` as its
#    synthetic stand-in for a real personal path. It must still be caught, or
#    that test proves nothing.
PAT_SAFE_PLACEHOLDERS='(/Users/(yourname|user|username|USERNAME|someone|anonymous)\b|Users:(yourname|user|username|USERNAME|someone)[A-Za-z0-9_]*:|/Users/ConsoleUser\b)'

# Files that carry the patterns by definition, or that exist to TEST the guard
# with synthetic (non-real) matches. Scanners must skip these rather than the
# pattern being softened to accommodate them.
PAT_SELF_EXCLUDE='^tools/(private_patterns|audit_private|test_audit_private)\.sh$'

# Paths the scanners skip entirely. Empty in this repo: every tracked file
# here is published, so there is nothing whose content "cannot leak". The
# arrays and the helper below exist so tools/audit_private.sh is one script
# shared with the development tree, where they are not empty.
PAT_NEVER_CROSS_DIRS=()
PAT_NEVER_CROSS_FILES=()

# Build a git pathspec array (":(exclude)path" entries) for
# PAT_NEVER_CROSS_DIRS + PAT_NEVER_CROSS_FILES, for scripts that need to hand
# pathspecs to `git diff`/`git log -p`/`git ls-files`. Usage:
#   never_cross_pathspecs; git diff --cached -- . "${NEVER_CROSS_PATHSPECS[@]}"
never_cross_pathspecs() {
    NEVER_CROSS_PATHSPECS=()
    local d f
    for d in "${PAT_NEVER_CROSS_DIRS[@]-}"; do
        [ -n "$d" ] && NEVER_CROSS_PATHSPECS+=(":(exclude)${d}/")
    done
    for f in "${PAT_NEVER_CROSS_FILES[@]-}"; do
        [ -n "$f" ] && NEVER_CROSS_PATHSPECS+=(":(exclude)${f}")
    done
}
