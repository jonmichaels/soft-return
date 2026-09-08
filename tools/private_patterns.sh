#!/usr/bin/env bash
# THE deny pattern for this private repo. One definition, sourced by
# tools/audit_private.sh and by every hook in tools/githooks/, so the three
# can never drift apart from each other the way three hand-copied lists did
# before (private-info-git-guard ruling, 2026-08-24).
#
# WHY THIS FILE EXISTS. A denylist of yesterday's leaked literals can only
# ever catch the leak that already happened. The rule is about SHAPE, not
# vocabulary: no filesystem path to anybody's machine, ever, in any encoding.
#
# 2026-09-07 addition (planning private-leak fix): a real Dropbox path
# survived in this repo, live on this repo's public snapshot, for eleven
# days -- because it was base64-encoded inside a recorded AppleEvent fixture
# and every existing scanner here only ever grepped raw file bytes as text.
# The shape rule was already broad enough to catch it (a POSIX "/Users/name"
# path and a distinctive project-folder name were both present in the
# decoded bytes); base64 just hid them from a plain-text grep. See
# tools/audit_private.sh's base64 pass, which exists because of exactly
# this.
#
# 2026-09-07, second pass (making the guard mechanical): wiring this into
# real hooks surfaced two problems the design hadn't hit yet, because it had
# never been run over a docs-heavy tree before:
#   (a) PAT_SHAPE's old `~/[A-Za-z]` alternative matched ANY tilde path,
#       including the generic macOS folder examples this repo's own docs are
#       full of (`~/Desktop`, `~/Library`, `~/Downloads`, `~/projects`...).
#       None of those name a real person -- `~` alone is resolved by the
#       shell to whoever is running it and never appears with a username in
#       it. Only `~name` (no slash -- shell tilde-user expansion) actually
#       encodes an identity. Narrowed accordingly; see note at PAT_SHAPE.
#   (b) A few of PAT_HOSTS's real-word entries collide with ordinary
#       English inside this repo's own prose. See PAT_SAFE_COLLOCATIONS.
#
# Sensitive literals are written with bracketed single-char classes -- they
# match identically while keeping this file from carrying the strings it
# exists to reject. Files that legitimately contain the patterns (this one
# and the audit) are excluded by the scanners, not by weakening the pattern.
# This same bracket technique already ships in the PUBLIC ctrl-kd repo's own
# copy of this file (tools/private_patterns.sh there) -- precedent for
# putting this file in a public tree without it itself becoming a leak.

# 1. Named private things specific to this repo's own leak history. Grows
#    only after a leak, and only for identifiers that are NOT already a
#    legitimate, pervasively-used category label elsewhere in this repo
#    (e.g. the private corpus group name is not listed here -- it is an
#    accepted, already-public convention, not a leak by itself; what leaked
#    was the REAL machine path around a document from that corpus).
#    Includes this private repo's own name -- it must never appear in
#    anything that could cross into the public tree.
PAT_NAMES='(Dropb[o]x[:/]Proj[e]cts_Writing|jmw[o]rk1-ws-fl[o]ppy|s[o]ft-return-testing)'

# 2. The SHAPE of every leak so far: a filesystem location on somebody's
#    machine, in either POSIX or classic-Mac (colon-delimited) form -- a
#    private repo does not need either; corpus roots come from the
#    environment (`CTRLKD_PRIVATE_CORPUS`). Anchored to a following name
#    char so a bare "~" or a stray "/Users" fragment is not a hit.
#    The colon form was added 2026-09-07: the AppleEvent-fixture leak this
#    guard is being extended for carried the SAME real path a second time
#    in classic Mac form (`Users:name:...`), which the slash-only shape
#    from 2026-08-24 would not have caught on its own.
#
#    The tilde alternative matches ONLY the two real usernames that have
#    ever appeared this way (shell tilde-user expansion, no slash -- see
#    PAT_SHAPE below for the literal forms), not `~[A-Za-z]` generally.
#    A generic `~<letter>` shape
#    turned out to match far more than personal paths: `~/Desktop` and
#    every other bare `~/<folder>` example in this repo's own docs, AND
#    (found when this pattern was wired into a real hook for the first
#    time) Swift's bitwise-NOT operator (`~len`, `~UInt16(0o111)`),
#    Markdown strikethrough (`~~text~~`), and "approximately" in ordinary
#    prose (`~col 30`, `~390 files`) -- none of which name anybody. Scoped
#    to the two real names instead, the same way PAT_NAMES/PAT_HOSTS are
#    named lists rather than shapes; grows only after a new real username
#    shows up in this form.
PAT_SHAPE='(~j[o]n\b|~w[o]rker\b|/home/[A-Za-z]|/Users/[A-Za-z]|Users:[A-Za-z][A-Za-z0-9_]*:|/mnt/[A-Za-z]|/root/[A-Za-z])'

# 3. Machine names, including in commit author/committer fields -- a
#    hostname in metadata is exactly as public as one in a file.
#    One entry (a common English/Spanish word, unlike the other five) gets
#    an explicit word boundary so it isn't matched as a substring of
#    something longer.
PAT_HOSTS='(hum[u]ng\.us|chon[k]y|borg[c]ube|noi[s]y|hea[r]th|grogn[a]rd|\btac[o]\b)'

# 4. Private-network addresses: Tailscale's CGNAT range (100.64.0.0/10) and
#    the three RFC1918 LAN ranges. Zero hits in this repo today (checked
#    2026-09-07) -- added prospectively, the same "shape not vocabulary"
#    reasoning as everything else here, since a LAN/Tailscale IP identifies
#    Jon's home network as surely as a hostname does. FOUR dotted octets
#    required, always -- the first attempt at this pattern required only
#    three and matched a source-comment date ("Created by ... on 10.07.07",
#    day.month.year) as if it were a `10.x.x` address; macOS/Xcode version
#    strings like `10.15.7` are also 3 octets and would collide the same
#    way. Real IPv4 is always 4.
PAT_NET='\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})\b'

PAT="($PAT_NAMES|$PAT_SHAPE|$PAT_HOSTS|$PAT_NET)"

# Known, reviewed, NON-hostname English usages of the real-word names in
# category 3. A raw PAT hit inside one of these phrases is a false positive,
# not a leak -- filtered out by the scanners (grep -v) after the PAT match,
# never by weakening PAT_HOSTS itself (that would stop catching the actual
# hostname). Grows the same way PAT_NAMES does: only after a real collision
# is found, never speculatively beyond a few obvious everyday phrases for
# words newly added to PAT_HOSTS this pass. Written with the same bracketed
# single-char-class technique as the patterns above, for the same reason:
# these are ordinary English words, but writing them out in full would put
# the literal grep-able strings in this file for no functional reason.
PAT_SAFE_COLLOCATIONS='(not just noi[s]y|too noi[s]y|very noi[s]y|noi[s]y (neighbou?r|signal|data|background|environment|channel)|(warm|cozy|by the|kitchen) hea[r]th|tac[o] (tuesday|truck|bell|bar|night))'

# Known generic PLACEHOLDER names -- deliberately allowed by the brief this
# guard was built against ("/Users/yourname", "/Users/user"): a placeholder
# names nobody, same reasoning as the tilde narrowing above. Filtered the
# same way as PAT_SAFE_COLLOCATIONS (grep -v after the PAT match), so it
# only needs listing once and can't drift from what actually gets used.
#    NOTE: does not include "exampleuser" -- tools/test_audit_private.sh's
#    own positive control deliberately uses `/Users/exampleuser/...` as its
#    synthetic stand-in for a real personal path (it must still be caught,
#    or the test proves nothing).
PAT_SAFE_PLACEHOLDERS='(/Users/(yourname|user|username|USERNAME|someone|anonymous)\b|Users:(yourname|user|username|USERNAME|someone)[A-Za-z0-9_]*:|/Users/ConsoleUser\b)'

# Files that carry the patterns by definition, or that exist to TEST the
# guard with synthetic (non-real) matches, or whose own user-facing text
# names the shapes being rejected (the pre-commit hook's BLOCKED message).
# Scanners must skip these rather than the pattern being softened to
# accommodate them.
PAT_SELF_EXCLUDE='^tools/(private_patterns|audit_private|test_audit_private)\.sh$|^tools/githooks/pre-commit$'

# Directories that are 100% never part of any public snapshot -- confirmed
# 2026-09-07 by diffing this repo's tracked set against the live public
# soft-return repo (every file below is absent there): internal job
# reports/acceptance evidence, agent configuration, the private WS7/WS4
# corpus and its private test target, and frozen pre-sandbox archive
# material. Real hostnames and worker paths are expected and unremarkable
# throughout these -- this repo's own operational documentation legitimately
# names the machines it runs on. Scanning them serves no privacy purpose
# (nothing here can leak, because nothing here ever crosses) and would only
# block ordinary private-repo work. Hook scripts must pathspec-exclude these
# from any blocking check; tools/audit_private.sh must not scan them either.
PAT_NEVER_CROSS_DIRS=(outbox evidence archive .claude ctrlkd-private-tests TestDocs)

# Individual files that are also 100% private-only despite living outside
# the directories above (same 2026-09-07 diff). The `docs/` ones are this
# repo's own operational runbooks/checklists/audit trail -- never
# published. `tools/answer_key_private.py` is private by its own name and
# purpose (reads the private corpus's answer key). The `macos/` block is
# the 44 SoftReturnTests + 2 SoftReturnUITests + 1 macos/scripts files that
# the app-suite tiering (private planning doc, "stays-in-private-repo"
# tier) already keeps out of the public snapshot, confirmed by the same
# diff, exact-name match. They hardcode a real worker-machine
# `/Users/worker/worker/...` filesystem layout (some also field-report a
# real hostname in a doc comment) -- none of that can leak because none of
# these files ever cross. If one of these 47 is ever promoted to the
# public tier (open question in that planning doc), remove it from this
# list FIRST, as part of that promotion review, not as an afterthought --
# that is the point of listing them individually instead of pattern-
# matching a job-number naming convention.
PAT_NEVER_CROSS_FILES=(
    CLAUDE.md
    docs/AUDIT-findings.md
    docs/CONSOLE-ROUND.md
    docs/RELEASE-CHECKLIST.md
    docs/RUNBOOK.md
    docs/SANDBOX-ARCHIVE.md
    docs/ui-audit-b13.md
    tools/answer_key_private.py
    macos/SoftReturnTests/CLIHelpWindowControllerTests.swift
    macos/SoftReturnTests/DocumentInfoInspectorTests.swift
    macos/SoftReturnTests/DocumentOpenTriggerExecutedPathTests.swift
    macos/SoftReturnTests/ExportPanelFixesTests.swift
    macos/SoftReturnTests/IntegrationGauntletTests.swift
    macos/SoftReturnTests/InteractionProbeTests.swift
    macos/SoftReturnTests/InvisiblesModernLayoutTests.swift
    macos/SoftReturnTests/InvisiblesStylingEvidenceTests.swift
    macos/SoftReturnTests/Job267InvisiblesProbe.swift
    macos/SoftReturnTests/Job269LJ6DTPProbe.swift
    macos/SoftReturnTests/Job276DownloadProgressRenderTests.swift
    macos/SoftReturnTests/Job294VerificationEvidenceTests.swift
    macos/SoftReturnTests/Job306OldtimesFontProbe.swift
    macos/SoftReturnTests/Job306ScreenshotProbe.swift
    macos/SoftReturnTests/Job315ScreenshotTests.swift
    macos/SoftReturnTests/Job428CompositeEvidenceTests.swift
    macos/SoftReturnTests/Job446AcceptanceEvidenceTests.swift
    macos/SoftReturnTests/Job491ChoerkerboardProbe.swift
    macos/SoftReturnTests/Job502FootnotePlacementProbe.swift
    macos/SoftReturnTests/Job503LJ6DTPNativeEvidence.swift
    macos/SoftReturnTests/Job505HPPatternEvidence.swift
    macos/SoftReturnTests/Job506PinVerification.swift
    macos/SoftReturnTests/Job511BatchLayoutEvidenceTests.swift
    macos/SoftReturnTests/Job512ModernBoxEvidence.swift
    macos/SoftReturnTests/Job517BatchFootnoteRTFProbe.swift
    macos/SoftReturnTests/Job522BatchPulldownSizeSweepEvidenceTests.swift
    macos/SoftReturnTests/LivePrintedFramingTests.swift
    macos/SoftReturnTests/MDImporterExecutedPathTests.swift
    macos/SoftReturnTests/ModernIndentLadderTests.swift
    macos/SoftReturnTests/MultipageMarginTests.swift
    macos/SoftReturnTests/NativeFidelityEvidenceTests.swift
    macos/SoftReturnTests/NativeImagePlacementTests.swift
    macos/SoftReturnTests/NativeVsEngineGeometryTests.swift
    macos/SoftReturnTests/PixelOracleAppEngineTests.swift
    macos/SoftReturnTests/PixelOracleModernExportViewerTests.swift
    macos/SoftReturnTests/PixelTruthMarginTests.swift
    macos/SoftReturnTests/PixInViewsTests.swift
    macos/SoftReturnTests/PrintedViewFramingTests.swift
    macos/SoftReturnTests/QLCLIByteParityTests.swift
    macos/SoftReturnTests/QuickLookPreviewPathProbeTests.swift
    macos/SoftReturnTests/RenderProbeTests.swift
    macos/SoftReturnTests/UIRound4ARulingTests.swift
    macos/SoftReturnTests/UIRound4BRulingTests.swift
    macos/SoftReturnTests/ViewRestructureJob265Tests.swift
    macos/SoftReturnUITests/Job276DownloadProgressScreenshotUITests.swift
    macos/SoftReturnUITests/Job314MenuAndInspectorScreenshotUITests.swift
    macos/scripts/round3-handshake.sh
)

# Build a git pathspec array (":(exclude)path" entries) for
# PAT_NEVER_CROSS_DIRS + PAT_NEVER_CROSS_FILES, for scripts that need to
# hand pathspecs to `git diff`/`git log -p`/`git ls-files`. Usage:
#   never_cross_pathspecs; git diff --cached -- . "${NEVER_CROSS_PATHSPECS[@]}"
never_cross_pathspecs() {
    NEVER_CROSS_PATHSPECS=()
    local d f
    for d in "${PAT_NEVER_CROSS_DIRS[@]}"; do
        NEVER_CROSS_PATHSPECS+=(":(exclude)${d}/")
    done
    for f in "${PAT_NEVER_CROSS_FILES[@]}"; do
        NEVER_CROSS_PATHSPECS+=(":(exclude)${f}")
    done
}
