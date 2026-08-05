# Soft Return

```
   _____       ______     ____       __
  / ___/____  / __/ /_   / __ \___  / /___  ___________
  \__ \/ __ \/ /_/ __/  / /_/ / _ \/ __/ / / / ___/ __ \
 ___/ / /_/ / __/ /_   / _, _/  __/ /_/ /_/ / /  / / / /
/____/\____/_/  \__/  /_/ |_|\___/\__/\__,_/_/  /_/ /_/
```

Read WordStar files and turn them back into something you can open today.

WordStar 4 through 7, plus the "print to disk" streams those versions produced, converted
to plain text, Markdown, HTML, RTF, or PDF. No dependencies, no Foundation in the library,
and no network. Point it at a `.WS` file from 1989 and get its words back.

Soft Return is a Swift package with two faces: **`sr`**, a command-line converter, and the
**CtrlKD** library it is built on.

```
sr PAPER.WS                       # -> PAPER.md, modern reflow
sr PAPER.WS -t html -o out.html
sr --mode printed LETTER          # as it came off the printer
sr --diagnose MYSTERY.FIL         # what IS this file?
sr -t text -t html -d out/ *.WS   # batch, multiple formats
sr --comments MEMO.WS             # include the author's hidden comments
sr --no-notes PAPER.WS            # body text only, no notes
```

```swift
import CtrlKD

let data: [UInt8] = …                           // the bytes of a WordStar file
let markdown = try convert(data, to: "markdown")
let pdf      = try convertData(data, to: "pdf", mode: .printed)
```

The library takes and returns bytes and never touches the filesystem, so reading the file is
the caller's business — and its choice of framework, not this package's.

### Naming

Four names, because there are four things:

| Name | What it is |
| --- | --- |
| **Soft Return** | the project — this repository, and the Mac app it is heading toward |
| **`sr`** | the command-line converter |
| **CtrlKD** | the Swift library the CLI is built on (`import CtrlKD`) |
| **ctrl-kd** | the [Python implementation](https://github.com/jonmichaels/ctrl-kd) this is a port of |

## What it handles

WordStar did not store text the way anything does now, and most of this library is the
consequences of that:

- **Variant detection.** WS4 sets the high bit on the last character of every word (an
  artifact of microjustification); WS5+ wraps its extras in symmetric control blocks; a
  print-to-disk stream is a different animal again. `detect()` classifies the file and the
  parser follows.
- **Soft returns.** WordStar broke lines to fit the screen and marked those breaks
  differently from the ones you typed. Reflowing a paragraph means knowing which is which —
  and for files where the distinction was lost, a statistical wrap test recovers the
  margin the author was working at.
- **CP437.** The high-bit bytes are box-drawing characters and accented letters from the
  IBM-PC code page, not Latin-1 and not UTF-8.
- **Dot commands, footnotes, and styling** — `.pa` page breaks, ruler lines, endnotes
  stored out of line, and the control codes for bold, italic, underline, strikethrough,
  superscript and subscript.

Two output modes. `.modern` reflows to a clean text column, which is what you want for
reading. `.printed` reproduces the typescript line for line, which is what you want when the
layout was the point — the PDF emitter renders Courier at 10 CPI and 6 LPI on US Letter,
because that is the machine the file was written for.

Formats: `text`, `markdown`, `html`, `rtf`, `pdf`, plus `txt` and `md` as aliases.

## Installing `sr`

Three ways, in order of least effort:

**Direct download** — **[sr-1.3.0-macos-universal.zip](https://github.com/jonmichaels/soft-return/releases/download/v1.3.0/sr-1.3.0-macos-universal.zip)**
— **Universal Binary. macOS 15 and above.** Unzip, put `sr` on your PATH, done.

**Homebrew:**

```
brew install jonmichaels/tap/sr
```

**Build from source** — you need the Xcode Command Line Tools
(`xcode-select --install`) and nothing else:

```
git clone https://github.com/jonmichaels/soft-return.git
cd soft-return
swift build -c release
cp .build/release/sr /usr/local/bin/     # or anywhere on your PATH
```

The built binary has no dependencies — the Swift runtime ships with macOS. It also
builds and runs on Linux.

When the Soft Return app arrives it will offer an *Install Command-Line Tool* menu item
as a fourth path.

`sr --help` lists every option. A few notes on the surface: there is no `--encoding` flag,
because the high-bit bytes in a WordStar file are IBM-PC code page 437 and every other code
page mis-decodes them; `--no-notes` and `--comments` control which of WordStar's four note
kinds an emitter renders — footnotes, endnotes and annotations by default, comments only
when asked for (WordStar itself never printed them); and `--diagnose` prints what a file
actually is — variant, estimated margin, dot commands, unrecognized control codes, note
counts per kind (footnote/endnote/annotation/comment, reported separately so hidden
comments show up even in a plain-text conversion), resolved page geometry with provenance
(file vs. default), the producer when WordTsar's own dot commands are detected, and — for
print-to-disk captures — the COMMENT.BUG print-time damage signature when present — as
JSON, converting nothing.

## Using the CtrlKD library

Swift 5.9 or later. Zero dependencies.

```swift
// Package.swift — no release is tagged yet, so track the branch for now
.package(url: "https://github.com/jonmichaels/soft-return.git", branch: "main")
```

```
swift build
swift test
swift run sr --version
swift run ctrlkd-demo     # converts synthetic WordStar bytes, prints each stage
```

## Roadmap

- **2.0** — the Soft Return Mac app: open a file from a 1989 floppy, see it rendered,
  export it as something a person can read. Quick Look support, so the Finder can
  preview WordStar files directly, and an *Install Command-Line Tool* menu item.
- **3.0** — the iOS app: a full Files-app citizen, same engine.

## Credits

Jon Michaels, with Athena (Claude, by Anthropic) as co-author.

The reason this exists is a stack of WordStar files from 1987–1992 and the need to read them
again. See [ctrl-kd](https://github.com/jonmichaels/ctrl-kd) for the Python implementation this
port grew from, and for the fuller account of the format archaeology.

Standing on the shoulders of the tools and documentation that kept WordStar readable:
Yohanes Nugroho's WS-CON, Michael Petrie's English port, the `wsconvert` project, Robert J.
Sawyer's WordStar archive, and the WordStar format documentation community. Behaviors were
studied and reimplemented; no code was copied.

## License

MIT © 2026 Jon Michaels. See [LICENSE](LICENSE).
