# Quirks — named, switchable departures from a literal reading

Jon's ruling, 2026-09-16: the engines stay faithful by default and never quietly
clean anything up. Where a departure from a literal reading of the bytes is
wanted, it gets a NAME, a one-line description a reader can understand, a reason
it applies to a particular document, and a switch.

This is the engine side, in both languages. The app surfaces (Settings ▸ Quirks
for the app-wide defaults, Document ▸ Quirks for the per-document overrides,
ruled the same day) read what is described here; they are not built yet.

## The two classes, and why the difference matters

| class | the evidence | default |
|---|---|---|
| **auto** | The document's own bytes point at the change — its WS7 header names the printer driver it was last printed through, and three of those drivers were modified so certain characters PRINT as something other than their code page says. Reproducing what the paper showed IS the faithful answer for such a file. | **on**, and switchable off |
| **opt-in** | Nothing in the file says the change is wanted; a person judged it from context. | **off** until asked for by name |

## What ships

| name | class | what it does (the engines' own description string, verbatim — Jon's wording, 2026-09-16) | applies when |
|---|---|---|---|
| `driver-euro-sign` | auto | Euro instead of peseta | the header names `LASERJET`, `LJ6DTP` or `HP4` |
| `lj6dtp-typography` | auto | Real dashes, curly quotes, ellipsis, © | the header names `LJ6DTP` |
| `lj6dtp-box-corners` | auto | Card suits as box corners (Univers) | the header names `LJ6DTP` |
| `lj6dtp-colour-as-gray` | auto | Screen colours as grey | the header names `LJ6DTP` |
| `lj6dtp-fill-patterns` | auto | Colours 9–14 as hatch patterns | the header names `LJ6DTP` |
| `stray-style-strikeout` | opt-in | Ignore a strikeout set only by a style | a paragraph style declares strikeout AND no span anywhere carries a strikeout the writer typed inline (`^PX`) |

The five auto quirks are the substitutions both engines already made, unchanged.
Naming them changes no output; what is new is that they can be seen, explained,
and switched off.

`stray-style-strikeout` is the one the faithful default deliberately leaves in
place: a style-declared strikeout runs until a later style clears it, as real
WordStar 7's printer does (Feature Decision Register, 2026-09-16). Seven
documents in the reference archive carry that stray bit; this quirk is how a
reader gets them without the line through every page.

## The flags — identical in both CLIs

```console
$ ctrl-kd --list-quirks            $ sr --list-quirks           # the catalogue
$ ctrl-kd --list-quirks FILE       $ sr --list-quirks FILE      # ... and this file's own rows
$ ctrl-kd --quirk NAME FILE        $ sr --quirk NAME FILE       # on   (repeatable)
$ ctrl-kd --no-quirk NAME FILE     $ sr --no-quirk NAME FILE    # off  (repeatable)
$ ctrl-kd --quirks off FILE        $ sr --quirks off FILE       # the literal bytes
$ ctrl-kd --quirks all FILE        $ sr --quirks all FILE       # everything this file trips
```

`--list-quirks` output is byte-identical between the two CLIs (both sort their
keys and both emit UTF-8 rather than `\uXXXX` escapes), so one script can read
either. Naming a quirk the document does not trip is a no-op — an app holds one
standing settings list and hands it to every file. Naming one that is not
registered is an error, because that is a typo or a missing plugin.

## The layout JSON

Format version 12 adds two top-level lists:

```json
"quirks_applicable": ["stray-style-strikeout"],
"quirks_applied": []
```

`quirks_applicable` is reported on a plain, faithful run, whether or not
anything was turned on — that is what lets an app OFFER a known quirk instead of
the reader having to already know one exists. `quirks_applied` is the subset in
force for that render. Both are omitted entirely (not `[]`) when the document
trips nothing, so such a document emits byte-identical JSON to version 11 apart
from the version number. The descriptions and the per-document reasons are NOT
in the JSON: they are properties of the build, not of the document, and an app
reads them from the API below.

## The API

Swift (`Sources/CtrlKD/Quirks.swift`):

```swift
let doc = try QuirkRegistry.standard.applyQuirks(
    to: parsed, enable: ["stray-style-strikeout"], disable: [], mode: .auto)

for row in QuirkRegistry.standard.list(for: doc) {
    // row.name, row.description, row.quirkClass, row.applicable, row.reason, row.enabled
}
```

`QuirkRegistry` is a value type with an immutable `.standard`, and `register`
returns a NEW registry — the same shape and the same reasoning as
`EmitterRegistry` (`Registry.swift`), including its refusal to port Python's
entry-point plugin discovery: a statically linked package has no installable
third-party quirks to find, and the dynamic-loading story is a host-application
decision about code signing and sandboxing, not a library one. A host registers
what it wants at startup.

Python (`src/ctrlkd/quirks.py`) has the same shape plus that plugin path —
`@ctrlkd.quirk(...)` and the `ctrlkd.quirks` entry-point group, documented for
outside contributors in ctrl-kd's own `EXTENDING.md`, "Adding a quirk".

A host resolves quirks ONCE, after parsing and before any emitter reads the
document; the decision is recorded on the document (`Document.quirks`) so every
later pass reads the same answer. A caller that never resolves anything gets the
defaults, which is byte-identical to the engines before quirks existed.

## Where the code lives, and why it did not move

The five driver quirks' substitutions stayed exactly where they were, threaded
through the renderers at the points that know when to apply them
(`Layout.swift`'s `pesetaMeansEuro`/`driverSubstituter`, `PDFDriverLJ6DTP.swift`,
`PDFWriter.swift`'s colour and pattern resources). Those call sites ask the
registry whether their quirk is in force; the registry supplies the name, the
reason, the reporting and the switch. Rewriting correct, ruled, tested code to
fit a reporting layer would have been pure risk — the quirks design note
(2026-09-16) settled it that way.

## Tests

`Tests/CtrlKDTests/QuirksTests.swift` (31 tests, synthetic fixtures only, no
corpus file read) mirrors ctrl-kd's `tests/test_quirks.py` case for case:
registry mechanics, the default decision per class, each auto quirk switched off
on its own, the stray-strikeout quirk's detect/apply in every format, the layout
JSON's own report, and the CLI surface.
