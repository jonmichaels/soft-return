# Soft Return

A macOS viewer for WordStar-era documents: open a file from 1987, read it as it
printed, export it to something this century can use.

**This repository is PRIVATE during development.** The app is half-formed; it
lives here so that unfinished app code never touches the working public library
repo. Nothing here is ready to be judged as shipped software.

## The engine lives somewhere else

All parsing, layout and conversion is **CtrlKD**, consumed as a Swift package
from the public library repo:

> https://github.com/jonmichaels/soft-return

This app is a viewer wrapped around that library. Detection, the WordStar
variants, pagination, and every emitter are the library's business — if a
document renders wrong, the bug is usually there, and the fix belongs there
where the CLI benefits from it too. This repo owns the window, the menus, the
page presentation, printing, and export panels.

## Mockups are the design intent — they are not the specification

There are mockups for this app, and they are worth reading: they carry the
intent, the mood, and the shape of the thing. **They do not outrank the build
spec, and neither of them outranks AppKit.**

The order is: **AppKit's platform behaviour beats the build spec, and the build
spec beats the mockups.** A mockup is a picture drawn without a compiler; where
it disagrees with the build spec (`soft-return-app-build-spec.md`, kept in the
private project vault, not in this repo), the build spec wins. Where the build
spec asks for something the platform does natively and better — document
lifecycle, Open Recent, Find, Speech, VoiceOver, the print panel, proxy icons —
the platform wins, and the spec marks those `[SYS]` precisely because they must
not be reimplemented. Reaching for a custom control to match a mockup pixel,
when a standard one carries accessibility and decades of muscle memory for free,
is the wrong trade every time.

## Building

Requires Xcode and [Tuist](https://tuist.io). The macOS app project lives under
`macos/`; generate the workspace from there, then build it from the repo root:

```
cd macos && tuist generate --no-open && cd ..
xcodebuild -workspace macos/SoftReturn.xcworkspace -scheme SoftReturn -configuration Debug build
```

The library resolves over the network as a Swift package dependency.

Bundle identifier `me.beforeti.softreturn`; the exported document type is
`me.beforeti.wordstar-document`.

## Layout

| Path | What |
|---|---|
| `macos/SoftReturn/` | app sources — Document, Rendering, UI, Settings, Export, Batch, Debug |
| `macos/SoftReturnTests/` | tests, and synthetic fixtures under `Fixtures/` |
| `macos/scripts/` | development tooling: capture one app window to a PNG, for looking at what the app actually drew |
| `macos/Info.plist`, `macos/SoftReturn.entitlements` | document types, UTIs, sandbox entitlements |

### Fixtures are synthetic, always

Test fixtures are invented documents with real byte structure — WordStar bit-7
line terminators, CRLF print streams, form-feed page breaks. No real document
belonging to anyone ever enters this repository, and the extensionless fixture
exists because that is the shape real files from the era usually arrive in.

## Debug tooling

Debug builds carry a `Debug` menu:

- **Show Accessibility Identifiers** — a HUD naming the control under the pointer.
- **Dump View Tree** — writes the live view hierarchy as JSON (frames, hidden,
  alpha, whether glyphs were actually laid out) plus an in-process render of the
  window. Built after a blank window survived a round of fixes because every
  test asked the model whether it was right and none asked the views what they
  actually were.

The app is sandboxed, so the dump lands in the app container's own tmp
directory; set `SOFT_RETURN_DUMP_VIEW_TREE=1` and the resolved path is logged.
