# Console round — the checks only Jon can run

**Run this every release.** It exists because the commands previously lived
only inside the last release's GitHub notes, so each round they were
reconstructed from the round before — or forgotten. Jon, 2026-08-24: "What are
the AppleScript checks I'm supposed to do?"

Full command blocks every time. Never a reference to an earlier message.

---

## 1. AppleScript self-send probe matrix

**Why this is Jon's and not the machine's:** the app is team-signed and carries
a `com.apple.security.application-groups` entitlement, which needs interactive
group-container provisioning. Headless launches fail with LocalAuthentication
-1004. Do not burn a worker job re-attempting it.

**Both flags must be ENVIRONMENT VARIABLES.** `SRSelfSendProbe` is read from the
environment only — `defaults write` will not turn it on. (`SRDiagnostics` accepts
either, but set both the same way and there is nothing to remember.)

In Terminal:

```
SRDiagnostics=1 SRSelfSendProbe=1 "/Applications/Soft Return.app/Contents/MacOS/Soft Return"
```

The app launches in the foreground. The probe waits 2 seconds for launch to
settle, sends the Apple Events to itself, and writes one verdict file per leg.
Quit the app normally, then — **in the same Terminal window**, because `$TMPDIR`
is per-session and the app inherited it:

```
cat "$TMPDIR/aeSelfSendProbe.result.txt"
cat "$TMPDIR/aeSelfSendProbe.diagnose.result.txt"
cat "$TMPDIR/aeSelfSendProbe.export.result.txt"
cat "$TMPDIR/aeSelfSendProbe.exportNativeStyle.result.txt"
cat "$TMPDIR/aeSelfSendProbe.importPageSettings.result.txt"
```

Each reads `<leg>: PASS — <side effect verified>` or `<leg>: FAIL — <reason>`.
PASS requires all three: a real subject was found, the send returned 0, AND the
claimed side effect was verified on disk. No fixture needs hand-placing — the
probe resolves `LYING.WS` from the bundled samples.

`exportNativeStyle` is the one worth reading closely:
`divergesFromLiteralPrintedPDF=true` is what proves `using style native` takes a
different path instead of silently collapsing to Printed.

### Known hole — `bareDestination`

It needs `SRSelfSendOutsideFixture` pointing at a file OUTSIDE the app's own
space, and when the fixture is absent it logs a line with NO PASS and NO FAIL.
That is the old silent-pass shape. **It must be made to fail loudly** — same
rule as every other suppressed check. Open, on the b30 list.

### b29 result (2026-08-24) — 5 of 5 runnable legs PASS

    diagnose            PASS  reply parsed as JSON, 1277 chars
    importPageSettings  PASS  all 6 synthetic .PAT fields present
    convert             PASS  RTF 14,197 bytes, valid header
    export              PASS  RTF 16,576 bytes, valid header
    exportNativeStyle   PASS  PDF 226,457 bytes, diverges from Printed
    bareDestination     DID NOT RUN (fixturePresent=false) — see above

---

## 1b. THE REAL AppleScript verdict — the five external scripts

**The self-send probe above is the app talking to ITSELF. It does not prove a
real script works.** An external script needs the Automation grant, which only a
human can give — `docs/AUDIT-findings.md`: "grant Automation (System Settings >
Privacy > Automation > Soft Return) then run osascript convert = the only real
AppleScript verdict."

**These are the commands Jon has actually been given before** (verbatim from
4.0.0b26's release notes, the last build that carried them). Five legs, matching
the five probe legs.

Once per machine: System Settings > Privacy & Security > Automation > Terminal
> allow Soft Return. macOS prompts on first run; error -1743 with no prompt
means the grant is missing.

Get the fixture into /tmp (b29 bundles the samples, so this is now one line —
earlier builds needed Help > Open Sample Document > LYING, then Save a copy):

```
cp /Applications/Soft\ Return.app/Contents/Resources/SampleDocuments/LYING.WS /tmp/
```

Then:

```
open -a "Soft Return"

osascript -e 'tell application "Soft Return" to convert POSIX file "/tmp/LYING.WS" to POSIX file "/tmp/LYING.rtf"'

osascript -e 'tell application "Soft Return" to diagnose POSIX file "/tmp/LYING.WS"'

osascript -e 'tell application "Soft Return" to import page settings POSIX file "/tmp/LYING.WS"'

osascript -e 'tell application "Soft Return" to export POSIX file "/tmp/LYING.WS" to POSIX file "/tmp/LYING.pdf"'

osascript -e 'tell application "Soft Return" to export POSIX file "/tmp/LYING.WS" to POSIX file "/tmp/LYING-native.pdf" using style native'
```

### Worth adding for b30, since Modern is where b29 broke

The five above never exercise Modern. `export ... using style modern` to a PDF,
then OPEN IT and check the footnote sits at the bottom of page 1 — per
`ws7-prints/NOTE-PLACEMENT-2026-08-23.md`. On b29 it lands on page 4. Propose to
Jon before adding it to the standing list rather than quietly extending his
round.

### Also in the dictionary — the acceptance bar

`docs/AppleScript-Dictionary.md` names "Three scripts that must feel natural":
the shoebox (a folder to RTF via `choose folder`), the facsimile (`using style
printed page settings sawyer`), and the sorter (branch on `variant of
(diagnose f)`). Those are an ERGONOMICS bar — does scripting the app feel
natural — not the release verdict. Do not confuse them with the five above.

---

## 2. Check for Updates, without a public feed

Full recipe: `docs/check-for-updates-testing.md`. Two `UserDefaults` override
knobs in `me.beforeti.softreturn`; `SRUpdateFeedJSON` is the recommended one
because it bypasses URLSession entirely.

---

## 3. The visual round

Whatever this build changed, opened and looked at. Build-specific, so it goes in
the release notes rather than here — but the standing rule is:

**Check the thing that changed, in the view it changed in, against the ruling
that defines correct.** b29 shipped Modern footnotes at the end of the document
instead of the bottom of their page while the suite was green, because presence
was tested and placement never was.

For anything layout-related, these two exports settle engine-vs-app in one step
and need neither a screenshot nor Jon:

```
# engine, on the engine host
.venv/bin/ctrl-kd <doc> -t pdf --mode modern --fonts mac -o out.pdf --force

# app's own view, on the macOS dev host — ExportEngine.render -> appKitRenderedPDF
```
