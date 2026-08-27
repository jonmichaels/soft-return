# Soft Return — AppleScript Dictionary Proposal (v1, for Jon's review)

*2026-08-07. Ruling on file: "Essentially everything that the CLI can do, I'd
like covered in AppleScript so that Mac scripters can feel at home." This is
the vocabulary design — the nouns and verbs a scripter will type — proposed
BEFORE implementation. Rule on the terminology; the code follows the ruling.*

**Design principles:** read like TextEdit/Pages scripting, not like a CLI
wearing a costume (`using style printed`, never `--mode printed`); every enum
a proper AppleScript enumeration; errors are real AppleScript errors carrying
the engine's ParseError detail; everything routes through the same operations
layer App Intents uses, so the three surfaces (CLI, Shortcuts, AppleScript)
can never drift apart.

## The classes

**application** — standard suite (open, quit, count documents, make is NOT
offered — we are a viewer; `open` is how documents come to exist).

**document** (subclass of the standard document)
| property | type | access | notes |
|---|---|---|---|
| `variant` | ws4 / ws5 plus / printstream / plain text | r/w | reading = detected/current; SETTING forces a re-parse (the CLI's `--force`) |
| `style` | native / printed / modern | r/w | the viewer's display mode (job 313B: `native` added — see "Job 313B" below) |
| `page count` | integer | r | |
| `current page` | integer | r/w | Go menu as a property |
| `zoom` | fit / actual size / percentage number | r/w | |
| `page size` | US letter / US legal / A4 | r/w | printed sheet override |
| `modern font` / `modern size` | text / real | r/w | Modern style only |
| `show invisibles` | boolean | r/w | |

## The verbs

**`export`** — one document, one output (the CLI's single-file conversion).
```applescript
export document 1 to file "Macintosh HD:Users:jon:Out:INDIAN.rtf" ¬
    as RTF using style modern ¬
    with footnotes and endnotes without comments ¬
    note references word style
```
- `as`: plain text / Markdown / HTML / RTF / PDF / layout JSON
- `using style`: native / printed / modern (omitted → the document's current style; job
  313B: `native` only changes PDF output — every other format is identical to printed)
- notes switches: `with/without footnotes, endnotes, annotations, comments`
  (defaults mirror the app: notes on, comments off)
- `note references`: word style / prefixed  (the CLI's `--note-refs`)
- `page settings`: see below
- `line numbers` (job 504): boolean, default on — the CLI's `--line-numbers`
- `styles` (job 504): boolean, default on; off is the CLI's `--no-styles`
- `fonts` (job 504): office / mac / google / linux, default mac — the CLI's `--fonts`
- `page numbers` (job 506, b31): auto / on / off, default auto — the CLI's
  `--page-numbers` (paged formats only — RTF/PDF)
- `sentence spacing` (job 521, b33 N9): auto / keep / single, default auto — the CLI's
  `--sentence-spacing` (every format; deliberately no Settings default, unlike every
  other parameter in this list)
- returns the file actually written; errors with the engine's reason on failure. Job
  504: never the requested name if it already existed on disk — see "Overwrite" below.

**`convert`** — batch, app-level, no windows (the CLI's `-d` batch mode).
```applescript
convert {POSIX file "/Users/yourname/shoebox"} ¬
    to folder POSIX file "/Users/yourname/Out" ¬
    as {RTF, PDF} using style printed with searching subfolders
```
- input: list of files and/or folders; `searching subfolders` recurses
- `to folder` omitted → each output lands beside its source (same as source)
- `forcing variant ws4` available for stubborn files
- notes switches, `line numbers`, `styles`, `fonts`, `page numbers`, `sentence spacing`
  (jobs 504/506/521): same names/defaults as `export`'s own — `convert` did not have
  the notes switches at all before job 504
- returns the output files' POSIX paths actually written as text, one per line (job
  216: was a `{converted, skipped, failed}` record; job 241: was briefly a `file list`
  — see "Job 241: no reply can be a list" below for why that could never
  work either). Nothing converting is a script error, not a silent empty
  result; a partial run returns just what it produced.

**Overwrite (job 504)**: neither verb ever clobbers a pre-existing file. A name
collision writes Finder's own convention instead — `NAME 2.ext`, then `NAME 3.ext`,
and so on (space before the number, before the extension). The command's own return
value is always the name actually written, never the one originally requested. This
is the scripted surface only; the CLI's own prompt/`--force` overwrite behavior is
unchanged.

**`diagnose`** — the CLI's `--diagnose`.
```applescript
diagnose POSIX file "/Users/yourname/shoebox/MYSTERY"
-- → "{\n  \"comments_present\": true,\n  \"pages\": 12,\n  ...\n}"
```
Returns the CLI's own `--diagnose` JSON, as text (job 216: was a record —
see "Job 216 shape change" below).

**`import page settings`** — the `.PAT` interpreter.
```applescript
import page settings from POSIX file "/Users/yourname/DEFAULT.PAT"
-- → "{\n  \"mt_lines\": 3.0,\n  \"mb_lines\": 6.0\n}" (JSON text; only the
--    fields the .PAT dump actually set appear)
```
Job 216: was a `page settings` record — see "Job 216 shape change" below;
this is the one with the sharpest tradeoff, since the OLD record result fed
straight into the `page settings` parameter below and the new text result
cannot.

Plus a `page settings` parameter on export/convert accepting either a preset
enumeration (`factory` / `sawyer` / `modern`) or a literal
`page settings` record written directly in the script — the CLI's
`--page-settings` in native clothes. (Job 216: no longer "or `import page
settings`'s result" — that result is text now, not a record; a script must
parse it and build the record literal itself to compose the two commands.)

The `page settings` record gained a `paper size` property (job 504: US letter /
US legal / A4 — the same enumeration `document`'s own `page size` property uses).
Setting it resolves `page length` via the library's own named-size table (the CLI's
`--page-settings size=letter|legal|a4`); an explicit `page length` in the same
record wins if both are given — e.g. `{paper size:US legal, page length:40}` still
resolves to 40 lines, not legal's 84.

## Enumerations (one authoritative set)
`variant`: ws4, ws5plus, printstream, plain text · `style`: native, printed, modern
(job 313B) · `export format`: plain text, Markdown, HTML, RTF, PDF, layout JSON ·
`note reference style`: word style, prefixed · `page size`: US letter,
US legal, A4 · `settings preset`: factory, sawyer, modern · `fonts` (job 504):
office, mac, google, linux · `page numbers mode` (job 506, b31): auto, on, off ·
`sentence spacing mode` (job 521, b33 N9): auto, keep, single

## Three scripts that must feel natural (the acceptance bar)
```applescript
-- 1. The shoebox: everything in a folder to RTF, next to the originals
tell application "Soft Return" to convert {choose folder} as RTF

-- 2. The facsimile: one file to printed PDF with Sawyer's machine settings
tell application "Soft Return"
    export (open POSIX file "/Users/yourname/LJ6DTP.WS") ¬
        to POSIX file "/Users/yourname/LJ6DTP.pdf" ¬
        as PDF using style printed page settings sawyer
end tell

-- 3. The sorter: triage unknown files by what diagnose says
repeat with f in theFiles
    if variant of (diagnose f) is printstream then ...
end repeat
```
**Job 216 (2026-08-11) shape change — PENDING JON'S RULING on the
`diagnose`/`import page settings` ergonomics tradeoff below; `convert`'s
own shape is no longer a taste question as of job 241, see that section:**
`convert`/`diagnose`/`import page settings` all used to return one of this
suite's own custom `<record-type>`s (`conversion result`/`diagnosis`/`page
settings`). Job 207 found a real Cocoa Scripting defect: there is no
automatic reply-packaging from a Swift value to a CUSTOM sdef record type —
`keyAEResult` comes back completely empty, silently, regardless of whether
the returned value is correctly typed. Job 216's exemplar survey (real,
fetched open-source sdefs) found no shipping app relies on that path either
— NetNewsWire's sdef has zero record-type command results at all; Skim
hand-builds descriptors instead of trusting automatic packaging. So job 216
moved all three commands off custom-record results onto shapes Cocoa
provably packages automatically: `convert` → a file list (job 241: this
turned out to be wrong too — see below), `diagnose`/`import page settings`
→ JSON text (the CLI's own `--diagnose` rendering shape, reused for both;
job 241 confirms this shape was right all along, for a reason job 216
couldn't yet see).

**This directly breaks script 3 above, verbatim**, and the `page settings`
composition note under `import page settings`. `variant of (diagnose f)` was
real AppleScript record-property access; `diagnose f` is now a JSON string,
and pure AppleScript has no built-in JSON parser — script 3 as written no
longer runs at all. A script would need `AppleScriptObjC`/`NSJSONSerialization`
(or an external `run script`/`osascript -l JavaScript` detour) to get
`variant` back out. This is the real, product-visible cost of the job-207
fix, not a hypothetical — Jon needs to either accept it (and this doc's
acceptance script 3 gets rewritten to the JSON-parsing form), ask for a
different result shape (none of the shapes Cocoa provably packages —
primitive, primitive list, text, specifier — can carry NAMED structured
fields the way a record could; a specifier has no addressable object to
point at here), or accept that `diagnose`/`import page settings` simply
cannot offer both "real record ergonomics" and "actually reaches the
caller" at the same time on this SDK. The `conversion result`/`diagnosis`/
`page settings` record-TYPE declarations stay in `SoftReturn.sdef` (the
`page settings` record is still very much alive as the `page settings`
PARAMETER type on `export`/`convert`, and nested inside `diagnosis`'s own
`margins` property) — only the three commands' own top-level `<result>`
declarations changed.

**Job 241 (2026-08-11): no reply can be a LIST, at all — not a ruling,
a Cocoa Scripting limit.** Jobs 143-239b chased the field `-1708` bug
through every dispatch layer this SDK exposes in-process and kept finding
the command itself ran cleanly while the sender still got
`errAEEventNotHandled` back with a genuinely empty reply. Job 241 finally
reproduced the real mechanism with a real cross-process-shaped self-send
and a verbatim reply-descriptor dump: Cocoa's own reply-packaging
trampoline — the step AFTER a command's `performDefaultImplementation()`
has already returned successfully — cannot coerce ANY list-shaped value
into the reply. Proven by elimination, not inference: a native `[NSURL]`
under `<result type="file" list="yes">` failed; a HAND-BUILT `typeAEList`
of `typeFileURL` descriptors under the same declared type failed
identically; the same hand-built list returned under a SCALAR-declared
`<result type="file">` (a deliberate sdef/value mismatch) *also* failed —
ruling out both "Cocoa's automatic bridging is the problem" and "the
sdef's declared type matters" as explanations. Every SCALAR shape tested
(plain text, a single file, and no result at all) succeeded cleanly. This
is why `convert`'s result is text, not a file list: it is the one shape
that both actually replies successfully AND still carries every produced
path for a batch of more than one — not a style preference, the only
option a multi-file batch command has left. `diagnose`/`import page
settings` were already scalar text, so job 216's shape choice for those
two needed no change — this job just explains WHY it was the right one.

## Deliberately NOT in the dictionary
Mailmerge anything (permanent ruling); write/save-as-WordStar (the native
writer's taps are off); repair permissions (Finder-context command, not a
scripting verb — revisit only if asked).

## Job 252 (`ae-all-verbs`, 2026-08-12): all four verbs field-proofed, not just `convert`

Job 241 fixed and proved `convert`'s reply shape with a real self-addressed `AESendMessage`
(`AppleEventSelfSendProbe`) — but `export`/`diagnose`/`import page settings` shipped through
the same job-207/216/241 reply-shape eras and had never run a single real cross-process (or
even self-addressed) Apple Event. This job audited all four commands' actual
`performDefaultImplementation()` return values against job 241's CONFIRMED LAW (no list-shaped
reply, ever) and extended the self-send probe to exercise the other three:

| verb | sdef `<result>` | Swift return value | scalar? |
|---|---|---|---|
| `convert` | `type="text"` | `result.produced.map(\.path).joined(separator: "\n") as NSString` | yes (job 241) |
| `export` | `type="file"` (no `list="yes"`) | `args.destination as NSURL` — a single `NSURL` | yes |
| `diagnose` | `type="text"` | `ScriptingJSONRendering.render(result.info)` — a `String` | yes |
| `import page settings` | `type="text"` | `ScriptingJSONRendering.render(...)` — a `String` | yes |

No offender found — all four already return scalar values, so no command code changed here.
`AppleEventSelfSendProbe.runOtherVerbsIfRequested()` (same `SRDiagnosticsGate` +
`SRSelfSendProbe` env-flag opt-in as `convert`'s own probe, called right after it from
`AppDelegate.applicationDidFinishLaunching`, unconditionally compiled — not `#if DEBUG` — so it
also runs against RELEASE) now sends real self-addressed events for all three:
- `export`: stages a real open document (`NSDocumentController.shared.openDocument`, the
  scripting `document` class) against the `convert` probe's own `OLDTIMES.WS` fixture, then
  exports it to RTF; side effect = the output file exists and is non-empty.
- `diagnose`: the same fixture file as a single (non-list) direct parameter; side effect = the
  reply text parses as JSON.
- `import page settings`: a synthesized 68-byte WSCHANGE `.PAT` fixture (same layout
  `PageSettingsScriptingTests.syntheticPAT()` proves decodes correctly), written at runtime, no
  external provisioning needed; side effect = the reply contains all 6 expected field names.

Results land in `UserDefaults` (`aeDiagnostics.selfSendProbe.<verb>`) and plain marker files
(`aeSelfSendProbe.<verb>.result.txt` / `.replyDump.txt` in the app's temp dir), same
no-daemon-round-trip convention as `convert`'s own markers.

### The 4×2 field matrix (cold Debug + cold Release, 2026-08-12, machine-verified)

| verb | Debug | Release |
|---|---|---|
| `convert` | `sendStatus=0`, reply = produced path | `sendStatus=0`, reply = produced path |
| `diagnose` | `sendStatus=0`, reply = full `--diagnose` JSON | `sendStatus=0`, reply = full `--diagnose` JSON |
| `import page settings` | `sendStatus=0`, reply = all 6 `.PAT` fields | `sendStatus=0`, reply = all 6 `.PAT` fields |
| `export` | **`sendStatus=-1708`**, reply = `{ errn: -1708 }` (empty) | **`sendStatus=-1708`**, reply = `{ errn: -1708 }` (empty) |

Three of four verbs are now field-proven end to end, identically in both configurations.
`export` is NOT — same reproducible -1708 both cold Debug and cold Release, immediately after
the fixture document was genuinely opened via `NSDocumentController.shared.openDocument` (the
real production open path).

**This is a different bug class from job 241's law, not a reply-shape violation**: `export`'s
own return value is already the one scalar shape (`args.destination as NSURL`) job 241 proved
packages fine — nothing here needed the task-1 fix. The suspect is narrower: `export` is the
ONLY one of the four verbs whose direct parameter is an OBJECT SPECIFIER (`document 1`/`document
named "..."`) rather than a file path or nothing — `diagnose`/`import page settings`/`convert`
all take files or no direct parameter at all and every one of them round-trips cleanly in the
SAME run. The probe captured the specifier actually sent, via the REAL
`NSDocument.objectSpecifier` (not the hand-built fallback — `openedDocument.objectSpecifier
.descriptor` was non-nil both runs): a well-formed `'obj '{ from:null(), want:'docu',
form:'name', seld:"OLDTIMES.WS" }`, i.e. exactly `document named "OLDTIMES.WS"`. A
structurally sound specifier still bounces with a completely empty reply (no `keyAEResult`, no
error string, just `errn:-1708`) — the same "genuinely empty reply" shape job 235 first found
for `convert` before job 241's fix, but here the return-value law is already satisfied, so
either Cocoa's specifier-to-object RESOLUTION against this app's `document` element (`orderedDocuments`)
is failing before `ExportCommand.performDefaultImplementation` is ever reached, or there is a
still-undiscovered FIFTH dispatch-adjacent layer specific to element-addressed (vs. app-level)
commands. **Not fixed here — out of this job's scope** (task 1 was reply-shape offenders only;
this is a new finding, not a re-run of an already-ruled defect) — needs its own job, the same
"prove before fixing" discipline as 235-241, likely starting with an in-process
`NSScriptObjectSpecifier.objectsByEvaluatingSpecifier` probe against the real running app to
learn whether resolution itself succeeds before any AE round trip is involved.

**FIXED, job 254 (`export-specifier`, 2026-08-12) — see below.**

## Job 254 (`export-specifier`, 2026-08-12): export's -1708 fixed — receiver dispatch, not reply shape

Job 252 left `export` as the one verb still returning `-1708` with a genuinely empty reply,
despite an already-scalar return value and a structurally sound `NSDocument.objectSpecifier`
(`document named "OLDTIMES.WS"`) — narrowing the suspect to specifier RESOLUTION rather than
reply packaging. Two candidates were tested against job 252's own field probe
(`AppleEventSelfSendProbe.performExport`), cold Debug and cold Release, per Jon's brief:

- **Candidate A — evaluate the specifier by hand inside `performDefaultImplementation()`**
  (`(directParameter as? NSScriptObjectSpecifier)?.objectsByEvaluatingSpecifier as? WSDocument`
  as a fallback alongside the existing `directParameter as? WSDocument` cast). **FALSIFIED**:
  identical `sendStatus=-1708`, empty reply, cold Debug. This proves the failure happens before
  `performDefaultImplementation()` ever runs (or with a `directParameter` this fallback can't
  rescue) — not a decode-step problem this command's own code could work around.
- **Candidate B — bind `export` to the `document` class via `<responds-to>`**, the same
  receiver-dispatch mechanism `close`/`print`/`save` already use successfully on this class
  (`docs/reference/apple/scriptcommand-exemplars-packet.md`). `SoftReturn.sdef`'s `export`
  command no longer has a `<cocoa class="...">` binding; its direct-parameter type changed from
  `document` to `specifier` (matching `close`/`save`'s own declaration); the `document`
  class-extension gained `<responds-to command="export"><cocoa method=
  "handleExportScriptCommand:"/></responds-to>`. The conversion logic itself moved from
  `ExportCommand.performDefaultImplementation()` to `WSDocument.handleExportScriptCommand(_:)`
  (`WSDocument+Scripting.swift`) — `ExportCommand` is now just the pure, still-independently-
  tested argument decoder (`ExportCommand.decode`). **CONFIRMED**: `sendStatus=0`,
  `replyAEResultPresent=true` (type `furl`), the exported `.rtf` exists on disk and is
  non-empty — cold Debug (×2) and cold Release, identically.

| run | config | sendStatus | reply | side effect |
|---|---|---|---|---|
| before (job 252) | Debug | `-1708` | empty | none |
| before (job 252) | Release | `-1708` | empty | none |
| Candidate A | Debug | `-1708` | empty | none |
| Candidate B | Debug (×2) | `0` | `furl` result, real file | file exists, 37951 bytes |
| Candidate B | Release | `0` | `furl` result, real file | file exists |

`diagnose`/`import page settings` re-ran clean alongside every export attempt above — no
regression from either candidate change.

**Why B and not A**: Candidate A only ever gets a chance to run if Cocoa calls
`performDefaultImplementation()` on the custom command object at all. The unchanged `-1708`
result under A means that call either never happens for an object-typed (`type="document")
direct parameter on a custom `NSScriptCommand` subclass, or happens with a `directParameter`
neither cast in A's fallback chain can resolve — either way, nothing inside the command object
itself can rescue it. `<responds-to>` sidesteps the question entirely: Cocoa resolves the
specifier chain to find the receiver (the document) BEFORE calling any handler, exactly the
mechanism `close`/`print`/`save` were already relying on for this same class. This also
distinguishes it from job 238's earlier (falsified) `<responds-to>` attempt on `convert`/
`diagnose`/`import page settings` — those three are *file-list*-shaped commands bound to the
`application` class, and their actual `-1708` cause (job 241's list-shaped-reply law) was
unrelated to receiver dispatch; `export`'s failure mode is different in kind (object-specifier
resolution, not reply packaging), so `<responds-to>` fixing it here does not reopen job 238's
finding for the other three.

## Terminology rulings (Jon, 2026-08-08)
1. **RULED: `ws5plus`** — one word (`+` is illegal in AppleScript terms;
   the compound token mirrors the CLI's `ws5+` and Jon prefers it).
   Enumeration: ws4, ws5plus, printstream, text.
2. **RULED: include `layout JSON`** in the format enum (Jon, 2026-08-08:
   full CLI parity, literally everything the CLI can emit).
3. **RULED: `sawyer` stays** as the public preset name.

## Job 313B (b19, 2026-08-14): `native` joins the `style` enumeration

Job 265 (b15) had ruled the `style` enumeration stays two-case — "Native is a VIEW, not
something a script can ask for, exactly like export/convert" — because the app's own
PDF export collapsed Native into a literal Printed PDF, so there was genuinely no
export-facing difference for a script to select between. Job 313A (same day, Jon: "When
you export, you would expect to get the same thing you are looking at") removed that
premise: PDF export for a Native-viewing document now reuses the print path (Cmd-P's own
render), which is NOT the same bytes as a literal Printed PDF. `native` therefore has a
real export meaning again, PDF only — every other format (`RTF`/`HTML`/`Markdown`/plain
text/`layout JSON`) stays identical between `native` and `printed`, since those formats
carry Mac-mapped fonts regardless of style and Native/Printed only ever differed in PDF.

- The `style` enumeration (`SoftReturn.sdef`) gained `native` (code `SRsn`).
- `document`'s `style` property: reading now reports exactly what the window shows,
  including `native` — the job 265 collapse-to-printed workaround is gone. Setting it to
  `native` switches the view, the same as choosing View ▸ Native.
- `export … using style native`: PDF export goes through the print path; every other
  format behaves exactly as `using style printed` would.
- `convert … using style native`: `convert` has no window and no print-path PDF route
  (it is a headless, no-`ExportEngine` batch path) — an explicit `native` there collapses
  to the same behavior as `printed`, for every format including PDF. Batch behavior is
  otherwise unchanged by this job (the app's OWN Batch window, a different code path from
  the `convert` scripting command, does gain the print-path PDF for items whose own
  current/default style is Native — see the job 313 report; that is a GUI-only distinction
  with no scripting-visible surface, since `convert`'s `using style` always wins).
- **Flagged for Jon, not unilaterally decided as final**: reading `style` honestly as
  `native` (rather than continuing to report `printed`, job 265's old behavior) is this
  job's own call, made because the enumerator gap that motivated the old behavior no
  longer exists. If this reads as too large a scripting-surface change on its own, the
  narrower alternative is: add `native` to the enumeration and to `export`/`convert`'s
  `using style` parameter (so PDF export can select it), but leave the `style` PROPERTY
  itself still collapsing native to printed on read. This job shipped the honest-reporting
  version.

## Job 315 (b19, 2026-08-14): margins renames reach the `settings preset` enumeration

Job 315's UI-side renaming ("From Document" -> "Embedded", "Modern Default(s)" -> "Modern",
applied everywhere: the bottom bar's Margins popup, the View ▸ Margins submenu, and the new
Settings ▸ Quick Look Margins pulldown) reaches the AppleScript dictionary too, since the
brief is explicit that user-visible strings must not disagree across surfaces, and the
Script Editor's own dictionary browser is one of those surfaces.

- `settings preset` enumeration (`SoftReturn.sdef`, code `SRpr`): the `modern defaults`
  enumerator (code `SRxm`, unchanged) is renamed `modern`. `factory`/`sawyer` are
  untouched (ruling 3 above still holds — "sawyer stays"). Enumeration is now:
  factory, sawyer, modern.
- No compat shim: a script written against the old `modern defaults` term fails to
  COMPILE (an unrecognized identifier), the normal AppleScript behavior for a renamed
  term — there is no runtime path where the old word could silently keep working.
- "Embedded" (the app's UI name for `page settings`'s `nil`/absent case) was never an
  AppleScript TERM — omitting the `page settings` parameter entirely is how a script
  already expresses "use the document's own geometry" (see the parameter description
  above), and that is unchanged. Nothing in the sdef needed renaming for it.
- `ScriptingEnumCoding.settingsPresetCodes` (`.default: "SRxf", .sawyer: "SRxs", .modern:
  "SRxm"`) is unchanged — codes are the wire format; only the dictionary WORD for `SRxm`
  moved. `PageSettingsScripting.resolve(_:)` decodes by code, not by name, so nothing in
  the resolution path needed to change.
- Round-trip probe (`osacompile` against the freshly rebuilt, freshly `lsregister`-ed Debug
  app, job 315 — literal output):
  ```
  $ osacompile -o probe_new.scpt probe_new.applescript   # ...page settings modern
  EXIT 0                                                  # compiles clean

  $ osacompile -o probe_old.scpt probe_old.applescript   # ...page settings modern defaults
  EXIT 1
  probe_old.applescript:1: error: A identifier can’t go after this application
  constant or consideration. (-2740)                      # the old term is genuinely gone

  $ osacompile -o probe_sawyer.scpt probe_sawyer.applescript   # ...page settings sawyer
  EXIT 0                                                        # unaffected

  $ osacompile -o probe_factory.scpt probe_factory.applescript # ...page settings factory
  EXIT 0                                                        # unaffected
  ```
  Confirms the old term fails to compile — a real AppleScript compiler error, not merely an
  undocumented word — while `modern`/`sawyer`/`factory` all compile clean.

## Job 504 (2026-08-25): the remaining CLI-parity gaps closed

Jon's ruling, verbatim: "A-E should all be added. AppleScript overwrite should handle
it like a Mac would: add a ' 2' to the end of the filename (before extension)."

- **A. `line numbers`** — new boolean on `export`/`convert`, default on, wired to
  `EmitOptions.lineNumbers`/the CLI's own `--line-numbers` default via a new
  `DocumentOperations.ConversionOptions.lineNumbers` field.
- **B. `styles`** — new boolean on `export`/`convert`, default on; false is the CLI's
  `--no-styles` (no HTML classes/CSS, no RTF `\stylesheet`).
  `ConversionOptions.styles` already threaded to `EmitOptions.styles` before this job
  (job 373's own construction already passed it); only the AppleScript-facing
  parameter and its decode step were missing.
- **C. Note booleans on `convert`** — `footnotes`/`endnotes`/`annotations`/`comments`,
  same names and defaults `export` already had (footnotes/endnotes/annotations on,
  comments off). `ConvertCommand.Arguments` had no notes field at all before this;
  `decode` reuses `export`'s own with/without-a-kind rule
  (`ExportCommand.setNote`, made `internal`) rather than re-deriving it.
- **D. `fonts` enum** — new enumeration (`office`/`mac`/`google`/`linux`,
  `CtrlKD.FontsTarget`) as an optional parameter on `export`/`convert`, default
  `mac`. Both scripted write sites (`WSDocument.handleExportScriptCommand`,
  `ConvertCommand.convert`) hardcoded `.mac` — mistake-registry #24's "a Mac app's
  RTF fonttbl defaults to the mac mapping" reasoning is unchanged, but it is now
  the parameter's default value, not a ceiling a script cannot override.
- **E. `paper size`** on the `page settings` record — reuses the existing `page
  size` enumeration (US letter/US legal/A4, the same three sizes `document`'s own
  `page size` property already offers) rather than a new, redundant enum. Resolves
  to `page length` via a literal copy of the CLI's own `--page-settings
  size=letter|legal|a4` table (`Arguments.swift`'s `sizes` dict —
  `PageSettingsScripting.paperSizePlLines`): 66 lines/US letter, 84/US legal,
  70.158/A4. **Not pulled from a single shared function**: the CLI's own table is
  private to the `SoftReturnCLI` SPM target (a different module from the one this
  app links, `CtrlKD`), and the underlying `namedPageSizes` geometry table inside
  `CtrlKD` itself (`ParseWS.swift`) is `private` to that file, not `public` — there
  is no engine API this app could call instead without an ENGINE change, which was
  out of this job's scope. This literal duplication is the SAME shape
  `DocumentOperations.PageSettingsPreset.settings` already uses for the
  `sawyer`/`modern` presets (also copied verbatim from `Arguments.swift`'s
  `pagePresets`), so it is not a new pattern — a test
  (`paperSizePlLinesMatchesTheCLIsOwnPageSettingsSizeTable`) pins the numbers so
  the two copies cannot silently drift apart undetected. An explicit `page length`
  in the same record wins over `paper size` if both are given.
- **F. Overwrite → Finder-style collision naming** — see "Overwrite" above.
  `WSDocument.handleExportScriptCommand` used to write `.atomic` straight to the
  requested destination, silently overwriting anything already there.
  `ConvertCommand`'s beside-source path (`BesideSourceWriter`) used to do the
  opposite: **hard-refuse** a collision (job 261's ruling, `related-items-write` —
  because `Info.plist`'s `NSIsRelatedItemType` entries only match the exact
  base-name-plus-extension shape, a uniqued sibling like `OLDTIMES 2.rtf` would
  silently stop being recognized as related to its source). Job 504's ruling
  explicitly supersedes job 261 for this scripted path: a collision now writes the
  Finder-style uniqued name instead of refusing. The job-261 tradeoff still applies
  to that renamed file specifically — only the FIRST export/convert of a given
  source is Quick Look-related; a re-run that collides produces a numbered sibling
  Quick Look's Related Items will not associate with its source — an accepted,
  known consequence of this ruling, not an oversight it missed. `convert`'s own
  `to folder` path already used `DocumentOperations.uniqueFileName` (unchanged);
  the new `ExportCommand.uniqueDestination(for:exists:)` gives `export` the same
  rule, pure and file-system-free so it is unit-testable without touching disk.
  The CLI's own prompt/`--force` overwrite behavior (a completely separate code
  path, the `sr` binary) is untouched — this ruling is scripted-surface only.

No item needed an ENGINE change (CtrlKD) — every field this job wired
(`EmitOptions.lineNumbers`/`.styles`/`.fontsTarget`, `FontsTarget`'s four cases)
already existed in the engine; this job only exposed them through AppleScript's
decode layer, which was the actual gap.

## Job 506 (2026-08-25, b31): `page numbers`

The b31 engine pin (`92bb9eae`) added `EmitOptions.pageNumbers`
(`EmitOptions.PageNumberMode`, `auto`/`on`/`off` — the CLI's own
`--page-numbers`, ruled 2026-08-25): WordStar's own AUTOMATIC page number, the
one `.pc` positions, a separate mechanism from a literal `#` typed inside a
`.he`/`.fo` header/footer (that always prints, unaffected). Printed PDF only —
Modern has no running heads at all.

- New `page numbers mode` enumeration (`auto`/`on`/`off`) and a `page numbers`
  optional parameter on both `export` and `convert`, default `auto` — same
  shape as job 504's own `fonts` enum, one parameter per command, both
  `cocoa key="scriptingPageNumbers"`.
- `DocumentOperations.ConversionOptions` gained a `pageNumbers:
  EmitOptions.PageNumberMode = .auto` field, threaded into the `EmitOptions(...)`
  construction inside `convert()` — same pattern as job 504's `lineNumbers`.
- No engine change needed: `EmitOptions.pageNumbers` already existed at the pin
  this job adopted; the gap was entirely in the AppleScript decode layer, same
  as every job-504 item.
- The `export` command's Native-style PDF branch (`ExportEngine.render`, the
  AppKit print-path used only for `using style native` PDF output) does not
  take this parameter — that branch already omits several other `EmitOptions`
  fields (`lineNumbers`/`styles`/`fontsTarget`/`noteRefs`) for the same reason:
  it renders through the app's own `DocumentRenderer`/AppKit pipeline, not the
  library's `emitPDF`/`pageStream`, which is the only place automatic page
  numbers are drawn. Not a new gap this job introduced.

## Job 520 (2026-08-26, b33): page-numbering UI (Settings + export surfaces)

The b33 engine pin's own ruling gives `--page-numbers` a third real
consumer beyond the CLI: a Settings-backed app-wide default, both GUI
export surfaces, and — closing the one gap job 506 left open —
`page numbers` omitted from a script command now falls back to
*Settings' own default* rather than a hardcoded `auto` literal.

- New `SettingsStore.defaultPageNumbers` (`EmitOptions.PageNumberMode`,
  ruled default `.auto`), a "Default Page Numbering" pulldown in
  `SettingsWindowController` (Auto/On/Off) — same three-case-pulldown
  shape as `defaultPictures`/`picturesPopup`.
- `ExportAccessoryView` (the Export As sheet) and `BatchWindowController`
  /`BatchModel` (the Batch window) each gained a matching Page Numbering
  pulldown, initialized from `SettingsStore.shared.defaultPageNumbers`,
  never writing back — same "initializes from Settings, per-export
  overridable" rule the four b24 flags already follow. Enabled only when
  RTF or PDF is among the checked formats, same paged-formats-only rule
  as Headers/Footers (this parameter's own sdef description already said
  "paged formats only — RTF/PDF"; the UI gating simply didn't exist yet).
- `ExportEngine.render` gained a `pageNumbers` parameter, defaulting to
  `SettingsStore.shared.defaultPageNumbers`, threaded into
  `options.pageNumbers` — reaches the library's own PDF emitter
  (`convertData`'s `format == .pdf` branch) exactly like the four
  existing flags. `appKitRenderedPDF` (Modern/Native-view PDF) still does
  not take it — unchanged, disclosed gap, see job 506's entry above.
- `ExportCommand.decode`/`ConvertCommand.decode` gained a
  `defaultPageNumbers` parameter (same shape as `defaultPictures`), and
  their own `page numbers` argument fallback changed from a literal
  `.auto` to that caller-supplied default — `WSDocument
  .handleExportScriptCommand`/`ConvertCommand.performDefaultImplementation`
  both now pass `SettingsStore.shared.defaultPageNumbers` through, the
  same shape those two methods already use for `defaultHeaders`/
  `defaultTOC`/`defaultInlineStyling`/`defaultPictures`. The sdef's own
  `page numbers` parameter description on both `export` and `convert`
  updated from "Default: auto" to "Omitted: Settings' own default" to
  match.
- No engine change needed: `EmitOptions.pageNumbers` already existed at
  the pin this job adopted (job 506); the gap was entirely in the UI and
  the AppleScript decode layer's own default source.

## Job 521 (2026-08-26, b33): sentence-spacing UI (export surfaces + AppleScript, no Settings item)

The b33 engine pin's field notes register (N9) added `EmitOptions.sentenceSpacing`
(`EmitOptions.SentenceSpacingMode`, `auto`/`keep`/`single` — the CLI's own
`--sentence-spacing`): the typewriter double space after a sentence-ending `.`/`?`/`!`.
`auto` collapses it to one space on Modern exports and keeps it verbatim on Printed/Native;
`keep`/`single` force that choice regardless of style. Unlike every b24/job-506/job-520
option before it, Jon's ruling scopes this one to the export surfaces and AppleScript
ONLY — deliberately no Settings item.

- New `sentence spacing mode` enumeration (`auto`/`keep`/`single`) and a `sentence
  spacing` optional parameter on both `export` and `convert`, default `auto` — same
  shape as `page numbers`, one parameter per command, both
  `cocoa key="scriptingSentenceSpacing"`.
- `ExportAccessoryView` (the Export As sheet) and `BatchWindowController`/`BatchModel`
  (the Batch window) each gained a matching Sentence Spacing pulldown — but UNLIKE
  Page Numbering/Pictures/Headers/etc., it always starts at the plain literal `.auto`,
  never a `SettingsStore.shared` read (there is no `defaultSentenceSpacing` property),
  and is never disabled by the paged-formats-only doctrine — `EmitOptions
  .sentenceSpacing`'s own doc comment says it applies "in every format."
- `ExportEngine.render` gained a `sentenceSpacing` parameter, defaulting to the plain
  literal `.auto`, threaded into `options.sentenceSpacing` — reaches every one of the
  library's own emitters (text/markdown/html/rtf/pdf via `convertData`), unlike
  `pageNumbers`' PDF-only reach. `appKitRenderedPDF` (Modern/Native-view PDF) still does
  not take it — same disclosed gap `pageNumbers` and the job-504 flags already have.
- `DocumentOperations.ConversionOptions` gained a `sentenceSpacing:
  EmitOptions.SentenceSpacingMode = .auto` field, threaded into the `EmitOptions(...)`
  construction inside `convert()` — same pattern as `pageNumbers`.
- `ExportCommand.decode`/`ConvertCommand.decode` read `scriptingSentenceSpacing` with a
  plain literal `.auto` fallback when omitted — UNLIKE `pageNumbers`, no caller-supplied
  `defaultSentenceSpacing` parameter exists, since there is no Settings default to pass
  through (the same no-Settings-backing shape job 504's `lineNumbers`/`styles` already
  have).
- No engine change needed: `EmitOptions.sentenceSpacing` already existed at the pin this
  job adopted (b33/d484905); the gap was entirely in the UI and the AppleScript decode
  layer.
