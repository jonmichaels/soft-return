# Testing the GitHub-releases checker without a public feed

Job 250 (b14 prep). Jon's ruling (2026-08-12): "I need to test current functionality. Not
hope it works." / "No private is public. No releases repo." — nothing about this feature may
depend on a hosted, public fixture. Both knobs below are `UserDefaults` keys in the app's own
domain (`me.beforeti.softreturn`), read by `GitHubUpdateFeed` (`macos/SoftReturn/Support/
UpdateChecker.swift`). Neither has any effect unless set.

**Job 532 update:** the app-wide **Soft Return ▸ Check for Updates…** menu item now goes
straight to Sparkle (see the internal release runbook (not part of this repo)'s "Sparkle public-feed cutover" section) — it no
longer touches `GitHubUpdateFeed` at all, and these two override knobs have no effect on it
any more. `GitHubUpdateFeed` itself was NOT removed: **App ▸ Command Line Tool…**'s own
"Installer Package" **Download** button (`CLIHelpWindowController`) still drives it directly,
using the same default `GitHubUpdateFeed()` (same `UserDefaults.standard` domain, same two
override keys) — every recipe below now exercises THAT button, not the menu item. A build with
neither override key written behaves exactly as it does today: that button queries the real
GitHub releases list for `installerPackageFilename` (`Soft-Return-CLI.pkg`).

There are two independent override knobs. **`SRUpdateFeedJSON` is the recommended one** — it
bypasses `URLSession` (and therefore the sandbox's network/file layer) entirely, so it has no
dependency on container paths or file-scheme response handling. `SRUpdateFeedURL` is also
covered below for testing the URL-fetch code path itself, including `file://`.

## Recipe A — `SRUpdateFeedJSON` (recommended: no file, no network)

### 1. Write the override

```
defaults write me.beforeti.softreturn SRUpdateFeedJSON -string '[
  {
    "tag_name": "9.9.9",
    "html_url": "https://example.com/9.9.9",
    "prerelease": false,
    "assets": [
      { "id": 1, "name": "Soft-Return-CLI.pkg", "size": 1 }
    ]
  }
]'
```

This is the GitHub `GET /repos/:owner/:repo/releases` LIST shape (job 250 moved off
`/releases/latest` so channel selection can see prereleases too) — an array, even for one
release. The `assets` entry is job 532's addition to this doc: `CLIHelpWindowController.
performDownload()` (unlike the old menu-action flow this doc originally documented) requires a
real `cliAsset` match or it shows "The latest release doesn't include Soft-Return-CLI.pkg."
instead of downloading anything. `prerelease: false` means this fixture satisfies BOTH
channels: the currently-shipping build (`4.0.0`, job 539's stable bump — no "b" in the version
string, so `UpdateChannel.forVersion` in `UpdateChecker.swift` now resolves it to the
**stable** channel rather than beta) offers this fixture via the non-prerelease check; a beta
build (version string containing "b") would see the same fixture via the **beta** channel,
which picks the newest release overall regardless of the `prerelease` flag.

### 2. Run the check

Launch Soft Return (any build with this job's changes). Choose **App ▸ Command Line Tool…**,
then click **Download** under "Installer Package".

**Expected result:** a download-progress window, then Finder opens showing the downloaded
`Soft-Return-CLI.pkg`-shaped file (the fixture's asset `id: 1` has no real bytes behind it on
GitHub's assets-download endpoint, so an attempt against the REAL API would 404 — use this
recipe's whole point, no live network, or swap in a real asset id from an actual release if you
need to test the download itself end to end).

### 3. Clean up

```
defaults delete me.beforeti.softreturn SRUpdateFeedJSON
```

Click **Download** again. **Expected result:** the app is back to querying the real GitHub
releases list over the network — either a real download or "Couldn't download the update." if
this machine has no network path to `api.github.com` right now. Either way, the override JSON
must play no further part — that's what "inert when unset" means, and it's covered by
`feedIsInertWhenNeitherOverrideKeyIsSet()` in `macos/SoftReturnTests/UpdateCheckerTests.swift`.

## Recipe B — `SRUpdateFeedURL` with a local `file://` fixture

This exercises the actual `URLSession` fetch path (including the file-scheme response handling
fix — a `file://` read never produces an `HTTPURLResponse`, so the 2xx-status check has to be
skipped for it, or every file-based override would incorrectly report `.checkFailed`). **Stale
since job 392** (un-sandboxed the app target, before this job): the container path below
predates that ruling and is no longer a real constraint — the app can now read a `file://`
fixture from anywhere this user account can, not just its own container. Left as originally
written (out of this job's Sparkle-integration scope to fully re-verify); the container path
still works too; it's just no longer the ONLY path that would.

```
~/Library/Containers/me.beforeti.softreturn/Data/Documents/
```

This is standard App Sandbox behavior (an app's own container needs no entitlement to read or
write) — flagged here rather than cited to a fetched Apple docs packet because this worker
session had no live network access to fetch one (see the job report's LESSONS), and this
session's Bash permission denied listing that exact container path directly, so the
`Documents` subfolder's presence could not be confirmed from here. If it doesn't already exist,
create it first.

### 1. Write the fixture file

```
mkdir -p ~/Library/Containers/me.beforeti.softreturn/Data/Documents
cat > ~/Library/Containers/me.beforeti.softreturn/Data/Documents/update-feed-test.json <<'EOF'
[
  {
    "tag_name": "9.9.9",
    "html_url": "https://example.com/9.9.9",
    "prerelease": false
  }
]
EOF
```

### 2. Point the override at it

```
defaults write me.beforeti.softreturn SRUpdateFeedURL -string "file://$HOME/Library/Containers/me.beforeti.softreturn/Data/Documents/update-feed-test.json"
```

### 3. Run the check

Choose **App ▸ Command Line Tool…**, then click **Download** under "Installer Package" (job
532: this recipe now exercises that button, not the "Check for Updates…" menu item — see this
doc's own header note).

**Expected result:** same download flow as Recipe A (the fixture needs the same `assets` entry
— see Recipe A step 1's note). A failure here that Recipe A does NOT reproduce points at the
file layer specifically (wrong path, file not actually readable, or a stale `SRUpdateFeedJSON`
key still set — that key takes priority over `SRUpdateFeedURL` when both are present).

### 4. Clean up

```
defaults delete me.beforeti.softreturn SRUpdateFeedURL
rm ~/Library/Containers/me.beforeti.softreturn/Data/Documents/update-feed-test.json
```

## What NOT to do

Do not point `SRUpdateFeedURL` at a file outside the app's own container (e.g. anywhere under
`~/Desktop` or `~/Documents`) — the sandbox denies that read, and the failure surfaces as the
generic "Couldn't check for updates." alert rather than a crash or a clear error. It will never
load without either a user-selected grant (not wired up for this test knob — it's a defaults
key, not something offered through an Open panel) or living in the container as above.

## Job 251: the real feed, against this app's own (private) repo

Jon's ruling (2026-08-12): "We have releases in the app repo. It checks against that. Cutover
will be to the public repo later." `GitHubUpdateFeed.releasesListURL`
(`macos/SoftReturn/Support/UpdateChecker.swift`) now points at
`https://api.github.com/repos/jonmichaels/soft-return-app/releases` — this app's own repo,
which is private. GitHub's Releases API returns HTTP 404 (not 401/403) for an unauthenticated
or wrongly-scoped request against a private repo, to avoid confirming the repo even exists to
someone without access — see `UpdateFeedError.notFound`'s doc comment. So without a token, this
is the NORMAL result of a beta build's automatic check, not an edge case; it surfaces as
"Couldn't check for updates." with the appended token-hint sentence (see below).

Recipes A and B above are unaffected and still take precedence over everything in this
section — either override knob is checked, and answered, before the token/default-URL path is
ever reached.

### Token scope: fine-grained PAT, repo-scoped, Contents: Read-only

Create the token at <https://github.com/settings/personal-access-tokens> (fine-grained, not a
classic PAT):

- **Repository access:** "Only select repositories" → `jonmichaels/soft-return-app`. Never
  "All repositories" — this token exists to let ONE app read ONE repo's release list, nothing
  else.
- **Repository permissions → Contents: Read-only.** The Releases list/get endpoints
  (`GET /repos/:owner/:repo/releases`) live under a fine-grained PAT's "Contents" permission,
  not a separate "Releases" permission — GitHub does not expose one. Read-only is sufficient;
  this app never creates, edits, or deletes a release. This is stated from platform knowledge,
  not a citation freshly fetched this session — this worker's `WebFetch`/`WebSearch` are not
  reliably live in this environment (see the job report's LESSONS) — so verify against GitHub's
  own fine-grained PAT permissions page if this ever needs re-confirming.
- Expiration: pick something short and plan to rotate it; this is a beta-tester convenience
  knob, not production infrastructure.

### Add the token to the keychain

```
security add-generic-password -a github -s "Soft Return Update Token" -w "<paste the PAT here>"
```

`-a`/`-s` must match `KeychainUpdateTokenProvider.account`/`.service` exactly
(`"github"` / `"Soft Return Update Token"`) — `UpdateChecker.swift` queries by both together.
If an item with this service/account already exists, add `-U` to update it in place instead of
failing with "SecKeychainItemCreateFromContent: already exists" (Update — `-a`/`-s` unchanged).

**About `-T` (trusted application list) — state this honestly, it changes the UX:**

- **Omit `-T` entirely (the command above; recommended for a beta tester):** the item's access
  control list trusts only the process that created it — the `security` command itself — not
  Soft Return.app. The FIRST time the app calls `SecItemCopyMatching` for this item (i.e. the
  first CLI-package download after adding the token), macOS shows the standard system prompt:
  **"Soft Return wants to use your confidential information stored in [keychain] in
  '`Soft Return Update Token`'."** with **Deny** / **Allow** / **Always Allow**. Clicking
  **Always Allow** adds Soft Return.app to that item's ACL permanently — every check after that
  is silent. This is the click test below, and per the brief this one-time prompt is acceptable
  beta-tester UX; it is standard Keychain Services behavior for ANY app (sandboxed or not)
  reading an item it did not itself create, not an App Sandbox restriction and not something
  `com.apple.security.keychain-access-groups` changes (see `KeychainUpdateTokenProvider`'s doc
  comment for why that entitlement is the wrong tool for this).
- **`-T "/Applications/Soft Return.app"` (silent, no prompt ever):** pre-authorizes that exact
  app bundle path, so the first check never prompts at all. Trades away the one visible consent
  moment for convenience — only worth it if the prompt itself is the friction being tested
  around, not the token/channel logic.
- **`-T ""` (empty string, rarely what you want):** explicitly trusts NO application — every
  future access from any app, including `security` itself reading it back, prompts. Do not use
  this for a token meant to be read automatically.

**What this job could and could not verify empirically:** a same-process test
(`sandboxedTestHostCanWriteAndReadItsOwnGenericPasswordItem()` in
`macos/SoftReturnTests/UpdateCheckerTests.swift`) confirmed that the sandboxed test host can
`SecItemAdd` and immediately `SecItemCopyMatching` its OWN generic-password item with zero
prompt and no `keychain-access-groups` entitlement — the brief's "not needed for the app's own
keychain items" claim, verified. The CROSS-process case this section describes (an item created
by the separate `security` CLI process, read by the app) could **not** be run in this session:
this worker's own tool policy has `Bash(security *)` on its explicit deny list (unlike
`osascript`, which was policy-denied in earlier jobs and later allowlisted — `security` shows no
such history here and the denial is unconditional, not TCC-flavored). The prompt behavior above
is therefore stated as documented Keychain Services ACL behavior, not as something this job
watched happen — flagged the same way as the platform-knowledge PAT-scope claim above, for the
same reason.

### Click test

1. Run the `security add-generic-password` command above with a real, correctly-scoped PAT.
2. Launch a build with this job's changes. Choose **App ▸ Command Line Tool…**, then click
   **Download** under "Installer Package" (job 532: this click test now exercises that button,
   not the "Check for Updates…" menu item — see this doc's own header note).
3. **Expected first run (no `-T`):** the confidential-information prompt described above.
   Click **Always Allow**.
4. **Expected result after Always Allow:** a real request reaches
   `api.github.com/repos/jonmichaels/soft-return-app/releases` with an `Authorization: Bearer
   <token>` header; the download proceeds if `Soft-Return-CLI.pkg` is present in whatever this
   repo's actual releases list says relative to the running build's version and channel (see
   `UpdateChannel.forVersion` — a version string containing "b" checks beta, everything else
   checks stable).
5. **Expected result with the token absent, expired, or scoped to the wrong repo:** "Couldn't
   download the update." with the extra sentence — "If this is a beta build, an update token
   may be required — see Help." — appended, since GitHub answers both cases with 401/404
   (`CLIHelpWindowController.presentDownloadFailure`).

### Clean up

```
security delete-generic-password -a github -s "Soft Return Update Token"
```

Click **Download** again — expect the no-token 404 path (step 5 above), confirming the token
was actually driving the earlier success rather than a coincidentally-cached result.
