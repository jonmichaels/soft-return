![Soft Return icon: a red star with with a big eyed smiley face on a white background](docs/assets/sr-lg-128.png)
# Soft Return

A macOS viewer for WordStar for DOS documents: open a file from 1987, read it as it
printed, export it to something this century can use.
* Supports WordStar for DOS v4-v7
* Converts to plain text, markdown, HTML, RTF, and PDF
* QuickLook for WordStar documents, and PIX WordStar images
* Full AppleScript library
* `sr` Swift command line tool

Universal binary. Supports macOS 13 (Ventura) and higher. `sr` CLI supports macOS 10.15 (Catalina) and higher. 

## Viewer Style Modes

### Native
Native mode makes a best attempt at showing the WordStar document as it would have looked back in the day.
We have mapped WordStar v4 to Courier Prime and WordStar v5-v7 era fonts to fonts installed in macOS today.
### Printed
Printed mode matches the `printed` export mode in `sr` (and the original `ctrl-kd` python app). It too is an
an attempt to reproduce original WordStar documents as PDFs using only the base-14 fonts that ship with
the Adobe Portable Document Format, plus recreated Symbol and Zapf Dingbats fonts via Unicode.
### Modern
Modern attempts to show WordStar documents as they would look today. The two big changes are the removal of
soft returns for automatic line wrapping, and swapping the old two-space sentence spacing for the
the current one-space convention. WordStar 4 documents (and WS5+ with no font information) are presented in
Georgia 14. WordStar v5-v7 with specified fonts continue to use them.

## Download & Install

* macOS app (Universal Binary. macOS 13 or higher): [Latest Version](https://github.com/jonmichaels/soft-return/releases/latest/download/Soft-Return.dmg)
* `sr` Swift CLI (Universal Binary. macOS 10.15 or higher): [Latest Version](https://github.com/jonmichaels/soft-return/releases/latest/download/Soft-Return-CLI.pkg)
* macOS or Linux `sr` Swift CLI via homebrew: `brew install jonmichaels/tap/sr`
* **Experimental** Windows `sr` Swift CLI (x86_64; requires the [Swift runtime for Windows](https://www.swift.org/install/windows/)): [Latest Version](https://github.com/jonmichaels/soft-return/releases/latest/download/sr-windows-x86_64.zip)

## Siblings

[ctrl-kd](https://github.com/jonmichaels/ctrl-kd) -- Python converter for WordStar for DOS docs. The first 
app we made on this journey.

## Lineage

I wanted to be able to see the 70-some WordStar 4 files I had from junior high and high school. In about 
an hour and half my agent had my files looking pretty good. And then I fell down the research rabbit hole...

Soft Return wouldn't have been possible without the tools and documentation that kept WordStar readable: 
Yohanes Nugroho's WS-CON, Michael Petrie's English port, the `wsconvert` project, Robert J. Sawyer's WordStar 
archive, and the WordStar format documentation community.

My own test files are personal and are not distributed -- this repo's tests use synthetic fixtures and some
public domain docs I retyped in WordStar 4 and WordStar 7 in DOSBox-X.

## Credits

Written by Jon Michaels -- whose 1987–1992 WordStar files, and the need to read them again, are the reason 
this exists -- with Athena (Claude, Anthropic) as co-author.
