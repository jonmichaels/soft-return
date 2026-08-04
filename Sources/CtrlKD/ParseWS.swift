/// WordStar document parsing: inline control-code decoding plus the block/line
/// assembly loop. Direct port of `_decode_spans` (core.py:168-215) and `parse_ws`
/// (core.py:255-325).
///
/// This is the most bug-prone code in the project alongside `linesPass`. The comments
/// below mark the places where the ordering or the guard IS the behavior — several of
/// them shipped as production bugs in the Python implementation before being fixed.

/// WordStar inline control codes — the same core set from WS4 through WS7
/// (core.py:161-163). Note `0x02` and `0x04` both map to bold: `^D` doublestrike
/// renders as bold, and because Python toggles a *set*, hitting one after the other
/// closes the same style rather than nesting.
private let wsToggles: [UInt8: Style] = [
    0x02: .bold,
    0x13: .underline,
    0x19: .italic,
    0x14: .sup,
    0x16: .sub,
    0x18: .strike,
    0x04: .bold,
]

/// Codes discarded without comment (core.py:164).
///
/// `0x08` (^H overprint) was here until 2026-08-03 and is deliberately NOT any more:
/// WordStar-era authors used backspace-and-overtype to compose accented letters and
/// ad-hoc symbols, so dropping it SILENTLY loses content with no trace. It now falls
/// through to the `unknown` tally, which `--diagnose` reports — the project's own rule
/// is never to go quiet. Composing the overprinted pair properly is a separate job;
/// being able to SEE that a document contains overprints is the prerequisite for it.
private let wsDrop: Set<UInt8> = [
    0x01, 0x03, 0x0B, 0x0E, 0x10, 0x11, 0x12, 0x15, 0x17, 0x1C,
]

/// Dot commands that force an UNCONDITIONAL page break (core.py:166), compared
/// uppercased.
private let dotPagebreak: Set<[UInt8]> = [Array("PA".utf8)]

/// `.CP n` is CONDITIONAL and cannot be decided here: it depends on how many lines are
/// left on the page, which only the pagination pass knows. It used to live in
/// `dotPagebreak` and so broke every time, inverting the author's intent — `.cp` exists
/// precisely so a heading does NOT get stranded, and firing it unconditionally inserts
/// the break it was there to prevent.
private let dotCondpage: [UInt8] = Array("CP".utf8)

/// One physical line of bytes -> `[Span]`. `active` persists across lines (WordStar
/// styles span line breaks) and `unknown` accumulates for the whole document, so both
/// are `inout`. `fnCounter` is non-nil only for ws5+ documents, where it numbers the
/// note references.
///
/// `fnrefAt` holds the OFFSETS within this line at which a note reference belongs. They
/// used to be an in-band sentinel byte, but every byte available for one is a real
/// WordStar control code — `SENT_FNREF` sat on `0x00`, which the spec assigns to ^@
/// "fix the print position" and which occurs 2328 times in five archive documents. A
/// literal one was read as a reference to a note that does not exist.
private func decodeSpans(
    _ raw: [UInt8],
    stripHibit: Bool,
    active: inout Style,
    unknown: inout [UInt8: Int],
    fnCounter: inout Int?,
    fnrefAt: [Int] = []
) -> [Span] {
    var spans: [Span] = []
    var buf: [UInt8] = []

    // core.py:175-178 — the span captures `active` as it stands right now; later
    // toggles must not retroactively restyle already-flushed text. `Style` is an
    // OptionSet (a value type), so the assignment below copies, matching Python's
    // explicit `frozenset(active)`.
    func flush() {
        if !buf.isEmpty {
            spans.append(Span(text: decodeCP437(buf), styles: active))
            buf.removeAll()
        }
    }

    var pending = fnrefAt.sorted()
    var i = 0
    while i < raw.count || !pending.isEmpty {
        // A note reference sits BETWEEN bytes, so emit any that fall here before
        // decoding the byte at this offset.
        while let first = pending.first, first <= i {
            pending.removeFirst()
            if let current = fnCounter {
                flush()
                let n = current + 1
                fnCounter = n
                spans.append(Span(text: String(n), styles: active.union([.sup, .fnref])))
            }
        }
        if i >= raw.count { break }
        // core.py:182-185 — MASK BEFORE DISPATCH. WS4 sets bit 7 on the last character
        // of each word even when that character is a control toggle, so a word ending at
        // a style boundary arrives as e.g. 0x94 (= ^T | 0x80). Dispatching on the raw
        // byte instead leaks the toggle into the text and the style never closes —
        // that's the bug that turned whole paragraphs italic in production.
        let b: UInt8 = (stripHibit && raw[i] >= 0x80) ? (raw[i] & 0x7F) : raw[i]

        // core.py:186-187 — extended-character escape. Note it appends `raw[i + 1]`,
        // the UNMASKED byte: the escape exists precisely to smuggle a high byte past
        // the bit-7 stripping so it can decode as a cp437 extended character.
        if b == 0x1B && i + 1 < raw.count {
            buf.append(raw[i + 1])
            i += 2
            continue
        }

        if let style = wsToggles[b] {
            // core.py:192-195
            flush()
            if active.contains(style) {
                active.remove(style)
            } else {
                active.insert(style)
            }
        } else if b == 0x0F {
            buf.append(0x20)                    // binding space (core.py:196-197)
        } else if b == 0x1E {
            // inactive soft hyphen: dropped entirely (core.py:198-199)
        } else if b == 0x1F {
            buf.append(0x2D)                    // active soft hyphen -> '-' (core.py:200-201)
        } else if b == 0x09 {
            buf.append(b)                       // tab survives (core.py:202-203)
        } else if b < 0x20 || b == 0x7F {
            // core.py:204-206 — everything else in control range is either known-noise
            // or a diagnostic we want to surface.
            if !wsDrop.contains(b) {
                unknown[b, default: 0] += 1
            }
        } else {
            buf.append(b)
        }
        i += 1
    }
    flush()
    return spans
}

/// Parse a WordStar document (WS4 or WS5+) into the IR. core.py:255-325.
public func parseWS(_ data: [UInt8]) -> Document {
    let detection = detect(data)
    // Behaviour comes from the era table, never from a `variant ==` test — see
    // `Era.swift`. An unknown variant resolves to the WS5+ entry, which does not
    // strip high bits: the least destructive guess.
    let era = eraFor(detection.variant)
    let stripHibit = era.highBitWordwrap
    let ws5 = era.symmetricBlocks

    // core.py:261-264 — the ws5+ gate is CORRECTNESS, not an optimization:
    // `symmetricBlocks` treats every 0x1D as a block-start marker, so running it on a
    // ws4 document would reinterpret a stray 0x1D that `wsDrop` should just discard.
    var body = data
    var footnotes: [[Span]] = []
    var notes: [Note] = []
    var unknownBlocks: [UnknownBlock] = []
    var graphics: [String] = []
    var colours: [ColourChange] = []
    var fonts: [FontChange] = []
    var includes: [String] = []
    var shiftRuns: [ShiftRun] = []
    var printerDriver: String? = nil
    var wsHeader: WSHeader? = nil
    var styles: [StyleEntry] = []
    var tabAt: Set<Int> = []
    var wsMarks: [Int: StructuralMark] = [:]
    if ws5 {
        let stripped = symmetricBlocks(data)
        body = stripped.bytes
        notes = stripped.notes
        unknownBlocks = stripped.unknownBlocks
        graphics = stripped.graphics
        colours = stripped.colours
        fonts = stripped.fonts
        includes = stripped.includes
        shiftRuns = stripped.shiftRuns
        printerDriver = stripped.printerDriver
        wsHeader = stripped.header
        // The style-library pointer is FILE-ABSOLUTE, so it indexes `data` -- the bytes
        // as they arrived -- not the block-stripped `body`.
        if let ptr = stripped.header?.styleLibraryOffset {
            styles = parseStyleLibrary(data, base: ptr)
        }
        tabAt = stripped.tabAt
        wsMarks = stripped.marks
        // footnotes/endnotes/annotations are all rendered the same way (a numbered
        // list at the end) and share one inline reference counter below, so
        // `footnotes` stays the flattened view the existing emitters already know how
        // to render; `notes` is what tells the four kinds apart. Comments are never
        // rendered inline — they only ever show up in `notes`.
        footnotes = notes
            .filter { $0.kind == .footnote || $0.kind == .endnote || $0.kind == .annotation }
            .map { [Span(text: $0.text)] }
    }

    let pass = linesPass(body, tabAt: tabAt, marks: wsMarks)

    var active: Style = []
    var unknown: [UInt8: Int] = [:]
    var dots: [String] = []
    var fnCounter: Int? = ws5 ? 0 : nil
    var ruler = false
    var page = PageAccumulator()
    var producer: String? = nil
    var footnoteNumberStart: Int? = nil
    var endnoteNumberStart: Int? = nil
    var headers: [Int: String] = [:]
    var footers: [Int: String] = [:]
    // Running FORMATTING state, stamped onto each block as it opens. Stateful, unlike
    // page geometry — see `Formatting2.swift`.
    var fmt = FormatState()
    var tocEntries: [TOCEntry] = []
    var indexEntries: [IndexEntry] = []
    var lineNumbering: Int? = nil

    var blocks: [Block] = []
    var cur = Block(kind: .para, align: fmt.alignment, wrap: fmt.wrap ?? true,
                      leftMargin: fmt.leftMargin, rightMargin: fmt.rightMargin,
                      paraMargin: fmt.paraMargin, columns: fmt.columns,
                      columnGutter: fmt.columnGutter)
    var curLine = Line()

    // core.py:275-286 — empty lines and empty blocks are never appended.
    func closeLine() {
        if !curLine.spans.isEmpty {
            cur.lines.append(curLine)
        }
        curLine = Line()
    }
    func closeBlock() {
        closeLine()
        if !cur.lines.isEmpty {
            blocks.append(cur)
        }
        cur = Block(kind: .para, align: fmt.alignment, wrap: fmt.wrap ?? true,
                      leftMargin: fmt.leftMargin, rightMargin: fmt.rightMargin,
                      paraMargin: fmt.paraMargin, columns: fmt.columns,
                      columnGutter: fmt.columnGutter)
    }

    for physical in pass.lines {
        var raw = physical.text
        // core.py:289 — masked unconditionally, NOT gated on stripHibit: a ws5+ dot line
        // is still recognized, and a ws4 dot whose '.' carries bit 7 (0xAE) still is too.
        let stripped = raw.map { $0 & 0x7F }

        if stripped.first == 0x2E {                          // '.' — dot command line
            // core.py:290-298 — captured as metadata; the line itself never becomes text.
            let cmd = rstrippingASCIIWhitespace(stripped)
            dots.append(decodeCP437(cmd))
            let head2 = Array(cmd.dropFirst().prefix(2)).map(asciiUppercased)
            if dotPagebreak.contains(head2) {
                closeBlock()
                blocks.append(Block(kind: .pagebreak))
            } else if head2 == dotCondpage {
                // Carry the requested line count to the paginator. Measured on WordStar 4
                // (2026-08-03): it breaks only when the lines REMAINING on the page are
                // strictly fewer than n — exactly n remaining is enough room and does not
                // break.
                closeBlock()
                blocks.append(Block(kind: .condpage, heading: cpLines(cmd)))
            }
            if Array(cmd.dropFirst().prefix(1)).map(asciiLowercased) == [0x72],  // 'r'
               cmd.contains(0x21) {                                             // '!'
                ruler = true
            }
            parseHeadFoot(cmd, headers: &headers, footers: &footers)
            // The index of the block this entry POINTS AT — the one that follows it,
            // which is the block still open (if it has content) or the next to open.
            // "This heading is in the table of contents" refers forward, not back.
            let pointsAt = blocks.count + ((!cur.lines.isEmpty || !curLine.spans.isEmpty) ? 1 : 0)
            if let inserted = parseCollectDot(cmd, toc: &tocEntries, index: &indexEntries,
                                              lineNumbering: &lineNumbering,
                                              blockIndex: pointsAt) {
                // `.fi` sits BETWEEN paragraphs in the printed result, so the text
                // before it has to be closed out first or the marker jumps to the front
                // of the document.
                includes.append(inserted)
                closeBlock()
                blocks.append(Block(kind: .para, lines: [
                    Line(spans: [Span(text: "[insert: \(inserted)]")])]))
            }
            // A formatting change starts a NEW block: `.oc on` mid-paragraph means the
            // lines after it are centred and the ones before it are not, and a single
            // block cannot hold both.
            let beforeFmt = fmt.blockFormat
            applyFormatDot(cmd, &fmt)
            if fmt.blockFormat != beforeFmt {
                closeBlock()
            }
            parsePageDot(
                cmd,
                page: &page,
                producer: &producer,
                footnoteNumberStart: &footnoteNumberStart,
                endnoteNumberStart: &endnoteNumberStart
            )
            continue
        }

        // A LITERAL form feed is a page break, in any variant. WSFORMAT.TXT: "0Ch ^L
        // Form Feed.  At print time causes page to be ejected.  No footer lines are
        // printed." `parsePrintstream` has always honoured it; `parseWS` did not, so a
        // WS document carrying ^L had its two pages run together into one paragraph and
        // the only trace was an "unknown code 0x0c" line in --diagnose.
        if raw.contains(0x0C) {
            var segment: [UInt8] = []
            var first = true
            for byte in raw {
                if byte == 0x0C {
                    if !segment.isEmpty {
                        curLine.spans += decodeSpans(segment, stripHibit: stripHibit,
                                                     active: &active, unknown: &unknown,
                                                     fnCounter: &fnCounter)
                        segment = []
                    }
                    if !first || !curLine.spans.isEmpty || !cur.lines.isEmpty {
                        closeBlock()
                        blocks.append(Block(kind: .pagebreak))
                    }
                    first = false
                } else {
                    segment.append(byte)
                }
            }
            raw = segment
        }

        // Structural marks, carried as OFFSETS rather than injected bytes — every byte
        // the old sentinels used (0x00 ^@, 0x0B ^K, 0x11 ^Q) is a real WordStar control
        // code that occurs in real documents, so a literal one was read as a page break,
        // a heading, or a note reference the author never wrote. See `StructuralMark`.
        var fnrefAt: [Int] = []
        for (rel, mark) in physical.marks {
            switch mark {
            case .softpage:
                // NOT a block, NOT a break: the editor drops these wherever the page
                // currently ends, including mid-paragraph, so closing the block here
                // severed real paragraphs. See the 0x0B parse site for the measurement.
                curLine.softpage = true
            case .heading(let level, let styleID):
                closeBlock()
                // Level 0 means "a style, but not one of the three this parser gives a
                // heading meaning to" — the block is still marked with WHICH style, so
                // a consumer can act on it. Register C1.
                cur.heading = level
                cur.styleID = styleID
            case .fnref:
                fnrefAt.append(rel)
            }
        }

        let spans = decodeSpans(
            raw,
            stripHibit: stripHibit,
            active: &active,
            unknown: &unknown,
            fnCounter: &fnCounter,
            fnrefAt: fnrefAt
        )
        curLine.spans.append(contentsOf: spans)

        switch physical.separator {
        case .wrap:
            // core.py:250-264 (ctrl-kd 2.0.0) — A soft return: a REAL line break on
            // paper (printed mode renders it), just word wrap for reflow
            // (`mergedLines` joins it back with the space rule that used to live right
            // here). 2.0.0: physical lines are stored; merging is the consumer's
            // choice now.
            if !curLine.spans.isEmpty {
                curLine.soft = true
                closeLine()
            } else if !cur.lines.isEmpty {
                cur.lines[cur.lines.count - 1].soft = true   // invisible (toggles-only)
                                                              // line: its softness binds
                                                              // the previous printed
                                                              // line, as the old merge did
            }
        case .line:
            closeLine()
        case .blankSoft, .blankHard:
            // A blank physical line. It is CONTENT in printed mode (it occupied a
            // line on paper) and it does NOT close the block — the text line before
            // it already carried `.para` if this run was a paragraph boundary.
            // `soft` records which kind it was: `.ls` filler versus the author's own
            // return.
            closeLine()
            let blank = Line(spans: [], soft: physical.separator == .blankSoft)
            if cur.lines.isEmpty, let last = blocks.indices.last,
               blocks[last].kind == .para {
                // The text line before this one carried `.para` and already closed
                // its block, so `cur` is empty. On paper this blank FOLLOWS that
                // paragraph — attach it there, so a paragraph block still starts
                // with text and the linear order is unchanged.
                blocks[last].lines.append(blank)
            } else {
                cur.lines.append(blank)
            }
        case .para, .eof:
            closeBlock()
        }
    }
    closeBlock()

    // Exposed per the IR contract: a consumer must be able to distinguish "Legal
    // (from file)" from "Letter (default)" — provenance lives alongside every
    // resolved figure, not just the page size. Computed regardless of variant: page
    // geometry is a dot-command concern, not a symmetric-block (ws5+-only) one.
    let plLines = page.plLines ?? defaultPlLines
    let (heightIn, sizeName) = resolvePageSize(plLines)
    let mtLines = page.mtLines ?? defaultMtLines
    let mbLines = page.mbLines ?? defaultMbLines
    let lh48 = page.lh48 ?? defaultLh48
    var pageGeometry = PageGeometry(
        plLines: plLines,
        heightIn: heightIn,
        sizeName: sizeName,
        sizeSource: page.plLines != nil ? .file : .default,
        mtLines: mtLines,
        mtSource: page.mtLines != nil ? .file : .default,
        mbLines: mbLines,
        mbSource: page.mbLines != nil ? .file : .default,
        poCols: page.poCols ?? defaultPoCols,
        poSource: page.poCols != nil ? .file : .default,
        hmLines: page.hmLines ?? defaultHmLines,
        hmSource: page.hmLines != nil ? .file : .default,
        fmLines: page.fmLines ?? defaultFmLines,
        fmSource: page.fmLines != nil ? .file : .default,
        lh48: lh48,
        lhSource: page.lh48 != nil ? .file : .default,
        ls: page.ls ?? defaultLs,
        lsSource: page.ls != nil ? .file : .default,
        cw120: page.cw120 ?? defaultCw120,
        cwSource: page.cw120 != nil ? .file : .default,
        // Placeholder: the real figure needs the rest of the struct assembled first
        // (mirrors Python setting `doc.meta['page']['text_lines']` as a second step,
        // after building the page dict) — overwritten immediately below.
        textLines: 1,
        pnStart: page.pnStart.map { Int($0) } ?? 1,
        pnSource: page.pnStart != nil ? .file : .default,
        pcCol: page.pcCol.map { Int($0) },
        pcSource: page.pcCol != nil ? .file : .default
    )
    // The one derived figure consumers actually need: printed text lines per page, from
    // WordStar's own vertical model (see `textLinesPerPage` for the formula and the
    // deliberate exclusions). Defaults -> 55, NOT the 60 a naive 1in-margin Letter
    // computation gives.
    pageGeometry.textLines = textLinesPerPage(pl: plLines, mt: mtLines, mb: mbLines, lh48: lh48)

    return Document(
        blocks: blocks,
        footnotes: footnotes,
        detection: detection,
        marginEstimate: pass.margin,
        dotCommands: dots,
        unknownCodes: unknown,
        columnar: ruler,
        notes: notes,
        unknownBlocks: unknownBlocks,
        page: pageGeometry,
        producer: producer,
        footnoteNumberStart: footnoteNumberStart,
        endnoteNumberStart: endnoteNumberStart,
        era: era.name,
        headers: headers,
        footers: footers,
        formatting: Formatting(
            underlineBlanks: fmt.underlineBlanks, suppressBlanks: fmt.suppressBlanks,
            proportional: fmt.proportional, kerning: fmt.kerning,
            orientation: fmt.orientation, subSuperRoll48: fmt.subSuperRoll48,
            endnotesHere: fmt.endnotesHere, convertNotes: fmt.convertNotes,
            autoPageNumbers: fmt.autoPageNumbers, paranumFormat: fmt.paranumFormat,
            condCol: fmt.condCol, tabStops: fmt.tabStops),
        graphics: graphics, colours: colours, fonts: fonts, includes: includes,
        shiftRuns: shiftRuns, printerDriver: printerDriver, wsHeader: wsHeader, styles: styles,
        tocEntries: tocEntries, indexEntries: indexEntries, lineNumbering: lineNumbering
    )
}

// ---------------------------------------------------------------- internals

/// Python `bytes.rstrip()` with no argument strips this exact set. Unlike job-003's
/// space-only helper, the full set is needed here: the input is masked raw bytes, so
/// e.g. a 0x8D soft return masks to 0x0D and must still be trimmed.
private let asciiWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]

private func rstrippingASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
    var end = bytes.count
    while end > 0 && asciiWhitespace.contains(bytes[end - 1]) { end -= 1 }
    return Array(bytes[..<end])
}

/// ASCII-only case folding, matching `bytes.upper()`/`bytes.lower()` — which, unlike
/// `String` case mapping, never touches non-ASCII bytes.
private func asciiUppercased(_ b: UInt8) -> UInt8 {
    (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b
}

private func asciiLowercased(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
}

// ------------------------------------------------------------ page geometry
//
// .pl (page length), .po (page offset), .mt (top margin), .mb (bottom margin), .hm
// (header margin), .fm (footer margin) -- WordStar 7.0 file format spec (WordStar
// International, 1992). The trap: a UNIT-LESS numeric argument to .pl/.mt/.mb/.hm/.fm
// is LINES, and to .po is print COLUMNS -- never inches. (The only other modern
// implementation, WordTsar, admits via its own @todo that it falls back to inches when
// no unit is given; that is exactly the bug this avoids.) WordStar 5.0+ also allows an
// explicit unit suffix on these arguments -- '"'/I/IN for inches, C/CM for
// centimetres, P/PM for points, case-insensitive -- which this DOES convert, since at
// that point the file is telling us the unit rather than leaving it to the
// trap-default.
//
// .lh (line height) is its OWN unit-less default: 1/48in, not lines -- see
// `resolveLhArg`. .ls (line spacing) is a small integer count (1-9), never a measure
// at all -- see `resolveLsArg`.
//
// Everything below assumes the fixed 6 LPI / 10 CPI baseline this project already
// uses elsewhere (PDFLayout's Courier metrics; margin_estimate's WS4 default) for
// every command except `.lh` itself, which is what lets a document override that
// baseline's vertical half (see `textLinesPerPage`). WordStar itself lets CPI vary too
// (.cw), but tracking that is well beyond what a page-geometry pass needs. Direct port
// of core.py's page-geometry section (Python ctrl-kd 1.3.0; the vertical model --
// `.hm`/`.fm`/`.lh`/`.ls` and the derived `text_lines` -- shipped in 1.3.0).

/// Accumulates the FIRST occurrence of each page dot command seen so far — WordStar
/// dot commands are stateful and could recur mid-document, but one resolved answer per
/// document is what a consumer needs (matches `_parse_page_dot`'s "first occurrence
/// wins" rule). `hmLines`/`fmLines`/`lh48`/`ls` (ctrl-kd 1.3.0) follow the same rule;
/// a REJECTED argument (see `resolveLhArg`/`resolveLsArg`) leaves its field `nil` here,
/// exactly as if the dot command had never been seen, so the default stands.
private struct PageAccumulator {
    var plLines: Double?
    var mtLines: Double?
    var mbLines: Double?
    var poCols: Double?
    var hmLines: Double?
    var fmLines: Double?
    var lh48: Double?
    var ls: Double?
    var cw120: Double?
    var pnStart: Double?
    var pcCol: Double?
}

/// Named page sizes at 6 LPI (WordStar 7.0 file format spec: ".PL ... assuming 6
/// lines per inch. An eleven inch page contains 66 lines."): 66 lines/11in Letter, 84
/// lines/14in Legal, 81 lines/13.5in Foolscap Folio (the pre-ISO UK long sheet). All
/// three share the same 8.5in width, so only page HEIGHT is resolved here -- there is
/// no dot command for physical page width.
private let namedPageHeights: [(name: String, heightIn: Double)] = [
    ("Letter", 11.0), ("Legal", 14.0), ("Foolscap Folio", 13.5),
]
/// "Close" isn't spec-given -- a judgment call, not a reading. 0.25in is a bit over a
/// line and a half at 6 LPI: near enough to call it the named size; farther out,
/// honour the raw geometry instead of forcing a label onto it.
private let pageSizeSnapIn = 0.25

let defaultPlLines = 66.0   // WordStar's own default: 66 lines = 11in = US Letter
let defaultMtLines = 3.0    // spec: ".MT ... Default value is 3 lines."
let defaultMbLines = 8.0    // spec: ".MB ... The default value is 8 lines."
private let defaultPoCols = 8.0     // WS7 manual, "Page Layout": "The default page offset
                                    // is .8 inch" -- 8 print columns at the default 10 CPI.
                                    // (Through ctrl-kd 1.3.0 this was 0, "least
                                    // presumptuous", from the file-format spec stating
                                    // none; the manual DOES state one, and 2.0.0 actually
                                    // renders the offset, so the manual's figure governs.)
private let defaultHmLines = 2.0    // spec: ".HM ... Default is 2." (header sits INSIDE .mt)
private let defaultFmLines = 2.0    // spec: ".FM ... Default is 2." (footer sits INSIDE .mb)
let defaultLh48 = 8.0       // spec: ".LH ... The default is 8/48 or 6 lines per inch."
private let defaultLs = 1.0         // single spacing (WS7 manual, "Line Spacing")
private let defaultCw120 = 12.0     // spec: ".CW ... The default is 12 (12/120ths is 10
                                    // characters per inch)."

private func isASCIILetter(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

/// Python bytes-regex `\s` — ASCII whitespace only, distinct from `asciiWhitespace`
/// above only in that this file keeps the two call sites (dot-command splitting vs.
/// numeric-argument scanning) each named after the Python they port.
private func isDotSpace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
}

private func isASCIIDigit(_ b: UInt8) -> Bool {
    b >= 0x30 && b <= 0x39
}

/// `_DOT_CMD_RE = re.compile(rb'^\.([A-Za-z]{1,3})\s*(.*)$')`. `cmd` is the
/// already-rstripped, hibit-masked dot-command line (starts with '.'). Greedy 1-3
/// leading letters right after the dot never need to backtrack here (`\s*(.*)$` can
/// always match zero characters), so a plain greedy scan reproduces the regex exactly.
func dotCommandNameAndArg(_ cmd: [UInt8]) -> (name: [UInt8], arg: [UInt8])? {
    guard cmd.count > 1 else { return nil }
    var nameEnd = 1
    while nameEnd < cmd.count && nameEnd < 4 && isASCIILetter(cmd[nameEnd]) {
        nameEnd += 1
    }
    guard nameEnd > 1 else { return nil }        // at least one letter required
    let name = Array(cmd[1..<nameEnd])
    var argStart = nameEnd
    while argStart < cmd.count && isDotSpace(cmd[argStart]) {
        argStart += 1
    }
    return (name, Array(cmd[argStart...]))
}

/// `_DOT_NUM_RE = re.compile(rb'^\s*([0-9]*\.?[0-9]+)\s*("|[A-Za-z]{1,2})?')`. Standard
/// float-token scanning: greedily consume leading digits, then a dot IS consumed only
/// if at least one digit follows it (otherwise the regex's `[0-9]+` backtracks past an
/// empty match and leaves the dot itself unconsumed) — e.g. "5." matches value 5 with
/// the trailing dot left dangling, unconsumed, not an error.
func parseDotNumber(_ arg: [UInt8]) -> (value: Double, unit: [UInt8]?)? {
    var i = 0
    while i < arg.count && isDotSpace(arg[i]) { i += 1 }

    let numStart = i
    while i < arg.count && isASCIIDigit(arg[i]) { i += 1 }
    let leadingDigitsEnd = i

    if i < arg.count && arg[i] == 0x2e {
        let dotPos = i
        var j = i + 1
        while j < arg.count && isASCIIDigit(arg[j]) { j += 1 }
        if j > dotPos + 1 {
            i = j                                  // dot + at least one digit: include both
        } else {
            i = leadingDigitsEnd                    // dot with no digits after: don't consume it
        }
    }
    guard i > numStart else { return nil }          // matched nothing at all

    // A dot command from a 35-year-old file can carry an arbitrarily long numeral, and
    // `Double("999...9")` happily returns +infinity. That flowed unguarded into the page
    // geometry and trapped in `Int(x)` during printed-PDF layout — a crash, not a hang.
    // Reject anything that isn't a finite number: a page length of 10^308 lines is not a
    // measurement, it is damage, and the caller's default is the right answer.
    guard let value = Double(String(decoding: arg[numStart..<i], as: UTF8.self)),
          value.isFinite else {
        return nil
    }

    var j = i
    while j < arg.count && isDotSpace(arg[j]) { j += 1 }
    var unit: [UInt8]? = nil
    if j < arg.count {
        if arg[j] == 0x22 {                         // '"'
            unit = [arg[j]]
        } else if isASCIILetter(arg[j]) {
            var k = j + 1
            if k < arg.count && isASCIILetter(arg[k]) { k += 1 }   // up to 2 letters
            unit = Array(arg[j..<k])
        }
    }
    return (value, unit)
}

/// Convert a dot-command argument's optional unit suffix to inches. Returns `nil` for
/// no unit (caller applies the lines/columns default) or an unrecognised unit (treated
/// the same as no unit -- defensive, not a crash). Direct port of `_dot_arg_inches`.
func dotArgInches(_ value: Double, _ unit: [UInt8]?) -> Double? {
    guard let unit, !unit.isEmpty else { return nil }
    let upper = String(decoding: unit.map(asciiUppercased), as: UTF8.self)
    switch upper {
    case "\"", "I", "IN": return value
    case "C", "CM": return value / 2.54
    case "P", "PM", "PT":
        // `PT` is not in the file-format spec's list (which gives P and PM), but real
        // files write it: the WS7 archive uses `.sr 5pt` and `.sr 3pt`. It can only mean
        // points, and without it those arguments fell through to the unit-less default
        // and were read as 48ths — silently, and wrong by 1.5x.
        return value / 72.0
    default: return nil
    }
}

/// `.pl`/`.mt`/`.mb` argument -> lines, at 6 LPI. Unit-less IS lines already (see
/// module note above); a unit suffix is inches/cm/points via 6 LPI.
private func resolveLinesArg(_ value: Double, _ unit: [UInt8]?) -> Double {
    guard let inches = dotArgInches(value, unit) else { return value }
    return inches * 6.0
}

/// `.po` argument -> print columns, at 10 CPI. Unit-less IS columns.
func resolveColsArg(_ value: Double, _ unit: [UInt8]?) -> Double {
    guard let inches = dotArgInches(value, unit) else { return value }
    return inches * 10.0
}

/// `.lh` argument -> line height in 1/48in units. Unit-less IS 48ths (WS7 manual: "You
/// can also type the dot command in 48ths of an inch. For example, .lh 8 is 8/48 inch,
/// or the standard 6 lines per inch"); an explicit unit suffix converts. `.lh a`
/// (auto-leading) never reaches here — the numeric matcher (`parseDotNumber`) won't
/// match it, so it stays default + verbatim (in `Document.dotCommands`). A non-positive
/// height is meaningless: rejected (`nil`), default stands. Direct port of
/// `_resolve_lh_arg`.
private func resolveLhArg(_ value: Double, _ unit: [UInt8]?) -> Double? {
    let resolved = dotArgInches(value, unit).map { $0 * 48.0 } ?? value
    return resolved > 0 ? resolved : nil
}

/// `.ls` argument -> line spacing. "A line spacing of between 1 and 9" (WS7 file format
/// spec); anything else is junk, rejected (`nil`). Any unit suffix is likewise junk —
/// spacing is a count, not a measure. Direct port of `_resolve_ls_arg`.
private func resolveLsArg(_ value: Double, _ unit: [UInt8]?) -> Double? {
    guard unit == nil, value >= 1, value <= 9 else { return nil }
    return value
}

/// `.cw` argument -> character width in 1/120in units. Unit-less IS 120ths (spec: ".CW
/// ... the width of the characters in 1/120 inch increments. ... The default is 12
/// (12/120ths is 10 characters per inch)"); an explicit unit suffix converts. A
/// non-positive width is meaningless: rejected (`nil`), default stands. Direct port of
/// `_resolve_cw_arg`.
private func resolveCwArg(_ value: Double, _ unit: [UInt8]?) -> Double? {
    let resolved = dotArgInches(value, unit).map { $0 * 120.0 } ?? value
    return resolved > 0 ? resolved : nil
}

/// Printed text lines per page — WordStar's own vertical model (WS7 manual, "Page
/// Layout"): "The top and bottom margins define the space between the text and the top
/// and bottom of the paper. On an 8.5 x 11-inch page, if the top margin is .33 inches
/// and the bottom margin is 1.33 inches, the space left for text is 9.33 inches." Lines
/// available is that text height divided by the line height (`.lh`, 1/48in units):
/// "Changing the line height affects the number of lines that can be printed on a page."
/// WordStar's own defaults (`.pl 66 .mt 3 .mb 8 .lh 8`) give 55.
///
/// Deliberately NOT in the formula:
/// - `.hm`/`.fm` — the header prints WITHIN `.mt` and the footer WITHIN `.mb` (".MT ...
///   The header is printed within this margin"; ".MB ... The footer or page number is
///   printed within this margin"), so they position header/footer inside space already
///   subtracted, never reserve more.
/// - `.ls` — line-spacing blanks are literal lines in the file ("when you use line
///   spacing, the blank lines become part of the file", WS7 manual, "Line Spacing"), so
///   the body text already carries them; dividing capacity by `.ls` would double-count.
///
/// Unit-less `.mt`/`.mb` are lines at the fixed 6 LPI baseline (the module-note
/// assumption); `.lh` at parse time is resolved once per document (first occurrence
/// wins), not tracked per-line. Non-finite inputs (a malformed or absurd dot-command
/// argument that slipped past the earlier `isFinite` guard some other way) guard to 1
/// rather than propagating NaN/infinity into pagination. Direct port of
/// `_text_lines_per_page`.
func textLinesPerPage(pl: Double, mt: Double, mb: Double, lh48: Double) -> Int {
    if pl == 0 {
        // `.pl 0` turns page breaks OFF entirely in 7.0 document mode — MicroPro bug
        // 12284 (engineering note 649): DRIVERA.OVR inserts ".pl0" at the start of
        // PRVIEW output precisely so "displayed page breaks are thus avoided" (bare
        // ".pl" stopped meaning this in 7.0). Modelled as a page TOO TALL TO FILL rather
        // than a zero-height page — the old arithmetic produced 1 text line, i.e.
        // MAXIMAL breakage, the exact opposite of what the command asks.
        return 1_000_000_000
    }
    let usable = pl - mt - mb                          // lines at 6 LPI
    guard usable.isFinite, lh48.isFinite, lh48 > 0 else { return 1 }
    return max(1, Int(usable * 8.0 / lh48))
}

/// Record `.he`/`.h1`-`.h5` and `.fo`/`.f1`-`.f5` text on the document.
///
/// `.HE` and `.FO` are line 1; the numbered forms select their own line, so a document
/// can carry up to five of each. An empty argument CLEARS that line, which is how
/// WordStar turns a running head off part-way through — so an empty value is STORED as
/// `""` and not skipped.
///
/// The text is kept verbatim, `#` included: the page-number substitution depends on
/// which page it lands on and belongs to the emitter, not here. Direct port of
/// `_parse_head_foot` (Python regex `^\.(H[E1-5]|F[O1-5])\s?(.*)$`, case-insensitive).
func parseHeadFoot(_ cmd: [UInt8], headers: inout [Int: String], footers: inout [Int: String]) {
    guard cmd.count >= 3 else { return }
    let first = asciiUppercased(cmd[1])
    let second = asciiUppercased(cmd[2])
    guard first == 0x48 || first == 0x46 else { return }          // 'H' or 'F'
    let line: Int
    if (first == 0x48 && second == 0x45) || (first == 0x46 && second == 0x4F) {
        line = 1                                                   // .HE / .FO
    } else if second >= 0x31 && second <= 0x35 {
        line = Int(second - 0x30)                                  // .H1-.H5 / .F1-.F5
    } else {
        return
    }
    // Python's `\s?` consumes at most ONE space after the command, so a deliberately
    // indented running head keeps the rest of its leading spaces.
    var rest = Array(cmd.dropFirst(3))
    if rest.first == 0x20 { rest.removeFirst() }
    let text = decodeCP437(rstrippingASCIIWhitespace(rest))
    if first == 0x48 {
        headers[line] = text
    } else {
        footers[line] = text
    }
}

/// The n of a `.cp n`, defaulting to 1 (a bare `.cp` asks for one line).
///
/// Stored on the block so the paginator can apply the rule measured on WordStar 4 on
/// 2026-08-03: break only when the lines REMAINING are strictly fewer than n. Exactly n
/// remaining is enough room and does not break. Direct port of `_cp_lines`.
func cpLines(_ cmd: [UInt8]) -> Int {
    guard cmd.count > 3, let (value, _) = parseDotNumber(Array(cmd[3...])) else { return 1 }
    // `.cp 1e9` is damage, not a request; `Int(value)` on a huge Double traps. Clamp to
    // a page's worth of lines at most — anything beyond that means "always break", which
    // is what the clamped value does anyway.
    // `Int(someHugeDouble)` TRAPS in Swift where Python's `int()` just returns a big int,
    // so the value is clamped before conversion. 100_000 lines is far past "always break",
    // which is what any larger figure would mean anyway — the only divergence from Python
    // is for arguments that are damage rather than a request. `Int(_:)` truncates toward
    // zero, matching Python's `int(float(...))`.
    guard value.isFinite else { return 1 }
    let bounded = Swift.min(Swift.max(value, 1.0), 100_000.0)
    return Swift.max(1, Int(bounded))
}

/// `pl_lines` -> (height_in, size_name). Snaps to a named size when close; otherwise
/// reports the raw geometry under "Custom" rather than forcing a label that doesn't
/// fit. Direct port of `_resolve_page_size`.
private func resolvePageSize(_ plLines: Double) -> (heightIn: Double, sizeName: String) {
    let heightIn = plLines / 6.0
    var best = namedPageHeights[0]
    var bestDiff = abs(best.heightIn - heightIn)
    for candidate in namedPageHeights.dropFirst() {
        let diff = abs(candidate.heightIn - heightIn)
        if diff < bestDiff {
            best = candidate
            bestDiff = diff
        }
    }
    if bestDiff <= pageSizeSnapIn {
        return (best.heightIn, best.name)
    }
    return (heightIn, "Custom")
}

/// Try to interpret one dot-command line as page geometry (`.pl`/`.po`/`.mt`/`.mb`/
/// `.hm`/`.fm`/`.lh`/`.ls`, ctrl-kd 1.3.0 added the last four) or a WordTsar-invented
/// command (`.PT`/`.PSA`/`.PSB` -- "not a Wordstar command" per WordTsar's own source,
/// so their mere presence is a producer signal). The line is
/// ALWAYS also kept verbatim in `Document.dotCommands` by the caller, recognised or
/// not — including `.PT`'s own raw argument, so no separate field is needed for that
/// here. Direct port of `_parse_page_dot`.
///
/// `.F#`/`.E#` (same spec) set the footnote/endnote starting numbering value -- the
/// two-character command NAME itself ends in the literal '#' (like `.L#`
/// line-numbering), which the generic `[A-Za-z]{1,3}` matcher below can't match, so
/// it's handled directly first.
private func parsePageDot(
    _ cmd: [UInt8],
    page: inout PageAccumulator,
    producer: inout String?,
    footnoteNumberStart: inout Int?,
    endnoteNumberStart: inout Int?
) {
    if cmd.count >= 3 {
        let head = String(decoding: [asciiUppercased(cmd[1]), asciiUppercased(cmd[2])], as: UTF8.self)
        if head == "F#" || head == "E#" {
            let isFootnote = head == "F#"
            let alreadySet = isFootnote ? footnoteNumberStart != nil : endnoteNumberStart != nil
            if !alreadySet, let (value, _) = parseDotNumber(Array(cmd[3...])) {
                if isFootnote {
                    footnoteNumberStart = Int(value)
                } else {
                    endnoteNumberStart = Int(value)
                }
            }
            return
        }
    }
    guard let (name, arg) = dotCommandNameAndArg(cmd) else { return }
    let nameString = String(decoding: name.map(asciiUppercased), as: UTF8.self)
    switch nameString {
    // Python's dispatch is generic (`_PAGE_DOT_RESOLVERS.get(key, _resolve_lines_arg)`
    // followed by "store only if the resolver didn't return None") because a Python dict
    // can hold one resolver function per key; a Swift `switch` over named struct fields
    // has no equivalent indirection, so the same RULE is applied per case instead: first
    // occurrence wins (the `== nil` guard), and a rejected value leaves the accumulator
    // `nil` so the default stands. `.pl`/`.mt`/`.mb`/`.hm`/`.fm`'s resolver
    // (`resolveLinesArg`) and `.po`'s (`resolveColsArg`, pre-existing) never reject, so a
    // direct assignment is behaviorally identical to Python's "store only if resolved" for
    // all five — unchanged from before ctrl-kd 1.3.0. `.lh`/`.ls` (1.3.0) and `.cw`
    // (2.0.0) CAN reject — `resolveLhArg`/`resolveLsArg`/`resolveCwArg` return `nil` for
    // a non-positive height/width or an out-of-range spacing — so those three guard the
    // store behind `if let`.
    case "PL":
        guard page.plLines == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.plLines = resolveLinesArg(value, unit)
    case "MT":
        guard page.mtLines == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.mtLines = resolveLinesArg(value, unit)
    case "MB":
        guard page.mbLines == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.mbLines = resolveLinesArg(value, unit)
    case "PO":
        guard page.poCols == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.poCols = resolveColsArg(value, unit)
    case "HM":
        guard page.hmLines == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.hmLines = resolveLinesArg(value, unit)
    case "FM":
        guard page.fmLines == nil, let (value, unit) = parseDotNumber(arg) else { return }
        page.fmLines = resolveLinesArg(value, unit)
    case "LH":
        guard page.lh48 == nil, let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveLhArg(value, unit) { page.lh48 = resolved }
    case "LS":
        guard page.ls == nil, let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveLsArg(value, unit) { page.ls = resolved }
    case "CW":
        guard page.cw120 == nil, let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveCwArg(value, unit) { page.cw120 = resolved }
    case "PN":
        // `.pn n` sets the number of the page it appears on, so the document does not
        // have to start at 1 — a chapter file in a larger manuscript starts wherever
        // the previous one stopped. MEASURED on WordStar 4 (2026-08-03): `.pn 7`
        // numbers the pages 7, 8, 9 in both the header's `#` and the footer's.
        guard page.pnStart == nil, let (value, _) = parseDotNumber(arg) else { return }
        page.pnStart = value
    case "PC":
        // `.pc n` is the column of the AUTOMATIC page number — the one WordStar prints
        // on its own. Measured: it does NOT move a `#` placed inside a header or
        // footer, which prints where the author put it. Two separate mechanisms.
        guard page.pcCol == nil, let (value, _) = parseDotNumber(arg) else { return }
        page.pcCol = value
    case "PT", "PSA", "PSB":
        // WordTsar's own invented dot commands (its source calls them "not a Wordstar
        // command"). A real WordStar file never contains these -- their presence IS
        // the producer signal. `detection.variant` stays what it is (the ENCODING,
        // still WS5+/7); this is provenance, not format.
        producer = "wordtsar"
    default:
        break
    }
}
