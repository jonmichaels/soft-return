#!/usr/bin/env python3
"""Job 374 (RELEASE-ASSET COMPLETENESS GATE): assert a published release carries every
asset this app's own code depends on, BEFORE the release chain undrafts it.

The requirement list here must stay in lockstep with
`SoftReturn/Support/ReleaseAssets.swift` — that is the app-code side of the SAME two rules
(`ReleaseAssetCompletenessTests.swift` pins the literal cross-check). Two rules, not a
config file: this app has exactly two release-asset dependencies today, and a third one
appearing should be a loud, deliberate edit to BOTH files, not a silent config change either
side of the pair could miss (the b23 CLI-pkg-leg omission — this job's own brief — was
exactly this class of gap: real, needed, but never written down anywhere the chain runs).

Usage:
    verify-release-assets.py <repo> <tag>

Fetches the release's asset list via `gh release view <tag> --repo <repo> --json assets`
(the same `gh` the rest of the release chain already depends on — see docs/RUNBOOK.md) and
checks:
    1. an asset named exactly "Soft-Return-CLI.pkg" (case-insensitive) exists
    2. at least one asset whose name ends in ".dmg" exists

Exit codes: 0 ok, 1 one or more requirements unmet, 2 usage/gh/parse error.
"""
import json
import subprocess
import sys

INSTALLER_PACKAGE_FILENAME = "Soft-Return-CLI.pkg"
DMG_SUFFIX = ".dmg"


def fetch_asset_names(repo, tag):
    result = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo, "--json", "assets"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"gh release view failed (rc={result.returncode}): {result.stderr.strip()}")
    payload = json.loads(result.stdout)
    return [asset["name"] for asset in payload.get("assets", [])]


def missing_requirements(asset_names):
    missing = []
    if not any(name.lower() == INSTALLER_PACKAGE_FILENAME.lower() for name in asset_names):
        missing.append(INSTALLER_PACKAGE_FILENAME)
    if not any(name.lower().endswith(DMG_SUFFIX) for name in asset_names):
        missing.append(f"an asset ending in \"{DMG_SUFFIX}\"")
    return missing


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    repo, tag = sys.argv[1], sys.argv[2]
    try:
        asset_names = fetch_asset_names(repo, tag)
    except (RuntimeError, json.JSONDecodeError) as e:
        print(f"error: {e}")
        return 2

    missing = missing_requirements(asset_names)
    if missing:
        print(f"INCOMPLETE release {tag} ({repo}) — missing: {', '.join(missing)}")
        print(f"present assets: {', '.join(asset_names) or '(none)'}")
        return 1

    print(f"release {tag} ({repo}) carries every required asset: {', '.join(asset_names)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
