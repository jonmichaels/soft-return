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
    0x03, 0x0B, 0x10, 0x11, 0x12, 0x15, 0x17, 0x1C,
]
// 0x01/0x0E left `wsDrop` 2026-08-04 (Jon: 'Store that ws4 font switch
// flag. Don't lose it.'): ^PA alternate font / ^PN normal -- the ONLY
// typeface signal a WS4 file can carry (the face itself lived in the
// printer: a daisy wheel, a cartridge). Carried as the `.altFont` span
// style; no emitter renders it yet.

/// Dot commands that force an UNCONDITIONAL page break (core.py:166), compared
/// uppercased.
private let dotPagebreak: Set<[UInt8]> = [Array("PA".utf8)]

/// `.CP n` is CONDITIONAL and cannot be decided here: it depends on how many lines are
/// left on the page, which only the pagination pass knows. It used to live in
/// `dotPagebreak` and so broke every time, inverting the author's intent — `.cp` exists
/// precisely so a heading does NOT get stranded, and firing it unconditionally inserts
/// the break it was there to prevent.
private let dotCondpage: [UInt8] = Array("CP".utf8)

/// `.ig` — the long-form comment syntax (`..` is the short form). Ruling 2026-08-06 M9.
private let dotIgnore: [UInt8] = Array("IG".utf8)

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
///
/// `fontAt` holds `(offset, fonts index)` for each font change falling in this line: a
/// change flushes the current span and swaps the active font, so every following span
/// carries its font until the next change. `activeFont` persists across lines exactly as
/// `active` does — in Python both live in the one `active` set.
private func decodeSpans(
    _ raw: [UInt8],
    stripHibit: Bool,
    active: inout Style,
    activeFont: inout Int?,
    unknown: inout [UInt8: Int],
    fnCounter: inout Int?,
    fnrefAt: [Int] = [],
    fontAt: [(offset: Int, index: Int)] = [],
    fonts: [FontChange] = [],
    activeColour: inout Int?,
    colourAt: [(offset: Int, colour: Int)] = [],
    pctlAt: [(offset: Int, hmi: Int, byteLen: Int, pcl: Int?)] = [],
    pixAt: [(offset: Int, index: Int, byteLen: Int)] = [],
    tabTargetAt: [(offset: Int, absHMI: Int, leader: UInt8, cols: Int)] = []
) -> [Span] {
    var spans: [Span] = []
    var buf: [UInt8] = []
    // `flush` needs to read the font/colour, but both are `inout` and a nested function
    // may not capture an `inout` parameter that outlives the call. Local mirrors,
    // written back before returning, are the idiom the rest of this file would use.
    var font = activeFont
    var colour = activeColour

    // core.py:175-178 — the span captures `active` as it stands right now; later
    // toggles must not retroactively restyle already-flushed text. `Style` is an
    // OptionSet (a value type), so the assignment below copies, matching Python's
    // explicit `frozenset(active)`.
    func flush() {
        if !buf.isEmpty {
            var text = decodeCP437(buf)
            // A byte set in Symbol/ZapfDingbats is a GLYPH INDEX, not styled text:
            // transliterate through the font's own encoding into real Unicode
            // (`SymbolTranslit.swift`), after which no font is required at all.
            if let index = font, index < fonts.count,
               let kind = fontTranslitKind(fonts[index]) {
                text = transliterate(text, kind)
            }
            spans.append(Span(text: text, styles: active, font: font, colour: colour))
            buf.removeAll()
        }
    }

    var pending = fnrefAt.sorted()
    var pendingFonts = fontAt.sorted { $0.offset < $1.offset }
    var pendingColours = colourAt.sorted { $0.offset < $1.offset }
    // 0x0F user print controls, as (offset, hmi, byte count): the display string is
    // decoded as ONE span carrying `pctlHMI`, bypassing the ordinary byte-by-byte decode
    // loop entirely for its bytes (they were already filtered to the printable/high
    // range when `symmetricBlocks` recorded them, so no control code can hide inside).
    var pendingPctl = pctlAt.sorted { $0.offset < $1.offset }
    // b24 round 19 (RULINGS-LEDGER PIX row): "[image: NAME]" placeholders, same
    // mechanism as pctl above -- the whole placeholder string is decoded as ONE span
    // carrying `pix`, bypassing the ordinary byte-by-byte loop for its bytes.
    var pendingPix = pixAt.sorted { $0.offset < $1.offset }
    // Tab targets, the same mechanism again: one span for the tab's own padding run
    // (already sitting in `raw` as `leader * cols`, see `symmetricBlocks`), carrying the
    // block's ABSOLUTE target so a Printed-mode PDF renderer can set the pen there
    // directly instead of trusting the placeholder's own character-count advance. The
    // leader byte rides along too, so that renderer can tell a dot-leader tab from a
    // plain one without re-deriving it from the (already-expanded) text.
    var pendingTab = tabTargetAt.sorted { $0.offset < $1.offset }
    var i = 0
    while i < raw.count || !pending.isEmpty || !pendingFonts.isEmpty || !pendingColours.isEmpty {
        // Drain EVERY mark-consuming queue at the CURRENT `i`, re-checking pctl again
        // after tab/pix/fonts/colours fire (and so on) until none apply any more -- not
        // just once per outer-loop pass. Two 0x1D-derived spans can now sit ZERO-GAP
        // adjacent (a tab's own padding ending exactly where the next print control's
        // display text begins -- LJ6DTP's racing-stripe checkerboard, tab-then-pctl
        // repeated with no literal byte between them, is the real corpus case this was
        // found on): a single pass through pctl-then-tab-then-pix-then-fonts-then-colours
        // advanced `i` past the tab and left it sitting exactly on the next control's own
        // start, but control had already moved on to the fnref check and the per-byte
        // dispatch below, which consumed ONE stray byte of that control's own text as
        // ordinary content before the outer loop finally looped back and re-checked
        // `pendingPctl` -- one byte late every time, so each subsequent adjacent control
        // was entered a further byte behind the last, drawing individual letters ('S',
        // 'h', 'a', 'd', ...) out of what should have been fully invisible screen-only
        // display text. Fonts/colours never consume bytes (their own state-change loops
        // don't advance `i`) so they cannot themselves feed this loop, but they still need
        // to fire in the SAME drain pass as pctl/tab/pix, not stranded a whole
        // outer-iteration behind them, if a font/colour change ever lands on the exact
        // offset a tab or control also ends on.
        while true {
            var advanced = false
            while !pendingPctl.isEmpty, pendingPctl[0].offset <= i, i < raw.count {
                let (_, hmi, count, pcl) = pendingPctl.removeFirst()
                flush()
                let end = Swift.min(i + count, raw.count)
                let text = decodeCP437(Array(raw[i..<end]))
                spans.append(Span(text: text, styles: active, font: font, colour: colour,
                                  pctlHMI: hmi, pcl: pcl))
                i = end
                advanced = true
            }
            while !pendingPix.isEmpty, pendingPix[0].offset <= i, i < raw.count {
                let (_, idx, count) = pendingPix.removeFirst()
                flush()
                let end = Swift.min(i + count, raw.count)
                let text = decodeCP437(Array(raw[i..<end]))
                spans.append(Span(text: text, styles: active, font: font, colour: colour,
                                  pix: idx))
                i = end
                advanced = true
            }
            while let first = pendingFonts.first, first.offset <= i {
                pendingFonts.removeFirst()
                flush()
                font = first.index
                advanced = true
            }
            while let first = pendingColours.first, first.offset <= i {
                pendingColours.removeFirst()
                flush()
                // Colour 0 (Black, the default) clears the active tag entirely rather
                // than being recorded as an explicit value — so a fontless document, and
                // every all-black document, is unaffected by colour ever having been
                // decoded.
                colour = first.colour != 0 ? first.colour : nil
                advanced = true
            }
            // The tab drains LAST, after the state-only font/colour queues, because it
            // CONSUMES bytes and they do not. WordStar's ordinary encoding for "this line
            // is set in face N and starts at stop M" puts the 0x02 font block and the
            // 0x09 tab block back to back, so both marks land on the SAME offset -- the
            // padding's own first byte. Drained before the fonts (as it was when this
            // queue was first added), the tab cut its padding span with the PREVIOUS
            // line's style state still active and the font change then landed after it.
            // That is not merely cosmetic: `fontLeadPt` sizes a line's leading to 1.2 x
            // the largest PROPORTIONAL font tagged anywhere on it and carries that size
            // forward through blank lines, so an 18pt title bleeding onto a tab-indented
            // 14pt byline added 1.2 x (18 - 14) = 4.8pt to that line AND 4.8pt again to
            // the blank after it -- 9.6pt cumulative, which cost OLDTIMES.WS (236 type-9
            // blocks, the corpus's worst case) a line off page 1. A tab is a HORIZONTAL
            // instruction and must never move a line vertically. Fonts and colours never
            // advance `i`, so putting them first cannot starve this loop.
            while !pendingTab.isEmpty, pendingTab[0].offset <= i, i < raw.count {
                let (_, absHMI, leader, cols) = pendingTab.removeFirst()
                flush()
                let end = Swift.min(i + cols, raw.count)
                let text = decodeCP437(Array(raw[i..<end]))
                spans.append(Span(text: text, styles: active, font: font, colour: colour,
                                  tabHMI: absHMI, tabLeader: Int(leader)))
                i = end
                advanced = true
            }
            if !advanced { break }
        }
        // A note reference sits BETWEEN bytes, so emit any that fall here before
        // decoding the byte at this offset.
        while let first = pending.first, first <= i {
            pending.removeFirst()
            if let current = fnCounter {
                flush()
                let n = current + 1
                fnCounter = n
                spans.append(Span(text: String(n), styles: active.union([.sup, .fnref]),
                                  font: font, colour: colour))
            }
        }
        if i >= raw.count { break }
        // core.py:182-185 — MASK BEFORE DISPATCH. WS4 sets bit 7 on the last character
        // of each word even when that character is a control toggle, so a word ending at
        // a style boundary arrives as e.g. 0x94 (= ^T | 0x80). Dispatching on the raw
        // byte instead leaks the toggle into the text and the style never closes —
        // that's the bug that turned whole paragraphs italic in production.
        let b: UInt8 = (stripHibit && raw[i] >= 0x80) ? (raw[i] & 0x7F) : raw[i]

        // core.py:186-187 — extended-character escape. Note it takes `raw[i + 1]`, the
        // UNMASKED byte: the escape exists precisely to smuggle a high byte past the
        // bit-7 stripping so it can decode as a cp437 extended character.
        if b == 0x1B && i + 1 < raw.count {
            // `<1B x 1C>`: x is a CHARACTER TO DISPLAY, any value 00h-FFh (WSFORMAT).
            // For x in the control range that means the cp437 GLYPH at that position —
            // the smiley/arrow/music graphics — never the control action: ASCIITAB.WS
            // wraps every control code to PRINT the chart, and emitting the raw byte put
            // literal tabs and CRs inside its table rows. `cp437Graphics` is keyed on
            // exactly 00h-1Fh and 7Fh, so a miss means "not control range".
            let x = raw[i + 1]
            if let glyph = cp437Graphics[x] {
                flush()
                spans.append(Span(text: glyph, styles: active, font: font, colour: colour))
            } else {
                buf.append(x)
            }
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
        } else if b == 0x01 {
            // ^PA: the printer's ALTERNATE font. Ahead of the control-range arm below,
            // as in Python, so it is neither dropped nor tallied as unknown.
            flush()
            active.insert(.altFont)
        } else if b == 0x0E {
            // ^PN: back to the normal font. `remove` on an OptionSet is Python's
            // `discard`, not `set.remove` — a ^PN with no ^PA before it is a no-op.
            flush()
            active.remove(.altFont)
        } else if b == 0x0F {
            buf.append(0x20)                    // binding space (core.py:196-197)
        } else if b == 0x1E {
            // inactive soft hyphen: dropped entirely (core.py:198-199)
        } else if b == 0x1F {
            buf.append(0x2D)                    // active soft hyphen -> '-' (core.py:200-201)
        } else if b == 0x09 {
            buf.append(b)                       // tab survives (core.py:202-203)
        } else if b == 0xA0 && !stripHibit {
            // WS5+ soft space: justification/alignment padding WordStar re-stamps at
            // print time (615 bare A0s across the corpus, all in layout contexts --
            // BOOKLET.WS alone has 296 rendering as 'á'). A REAL á is carried as the
            // wrapped triple <1B A0 1C>, which the escape branch above already decodes
            // through cp437. WS4 needs nothing: its soft spaces are 0x20|0x80 and the
            // bit-7 mask (applied above, before `b` is computed) already restored them.
            buf.append(0x20)
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
    activeFont = font
    activeColour = colour
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
    var styleSlots: [Int: StyleEntry] = [:]
    var tabAt: Set<Int> = []
    var wsMarks: [Int: [StructuralMark]] = [:]
    var pclPrograms: [[UInt8]] = []
    // Round-trip ledger scaffolding (tasks #20/#21).
    var rtFlagged: [RoundtripFlagged] = []
    var rtSym: [RoundtripSym] = []
    var rtShift = false
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
            for entry in styles { styleSlots[entry.slot] = entry }
        }
        tabAt = stripped.tabAt
        wsMarks = stripped.marks
        pclPrograms = stripped.pclPrograms
        rtSym = stripped.rtBlocks
        rtShift = stripped.rtShift
        // A bare high-bit byte whose low 7 bits are a CONTROL CODE is that control with
        // WordStar's soft/flag bit set, NOT a cp437 glyph. MEASURED on WordStar 7
        // (2026-08-04, two independent traces): a real document's 0x8A performed a line
        // advance in the printed PCL (zero glyphs — flagged ^J); an injected 0x94
        // toggled superscript (flagged ^T, the font size and baseline visibly changed).
        // Real extended characters travel as <1B xx 1C> triples — the corpus carries
        // 10,000+ of them — never as bare bytes.
        //
        // Masked by ALLOWLIST, not by range: a blanket 0x80-0x9F mask CREATES structural
        // bytes — 0x9A becomes 0x1A (EOF: `linesPass` truncated a whole novel at its
        // first occurrence), 0x9D becomes 0x1D (block framing). The list is every value
        // observed in real BODY text (pre-EOF, outside blocks and 1B..1C wrappers) plus
        // the oracle-measured 0x94; extend it as evidence arrives. 0x8D/0x8A stay
        // flagged: `linesPass` reads them as the soft-return pair. Translation is
        // LENGTH-PRESERVING, so recorded offsets (marks, tabAt) stay valid.
        //
        // ... and applied OUTSIDE `<1B x 1C>` wrapped extended characters: the middle
        // byte is a character to display (any value 00h-FFh), so masking it would corrupt
        // a wrapped character that happens to share a flagged value. Triples are opaque
        // three-byte units everywhere between the block walk and span decode.
        var masked: [UInt8] = []
        masked.reserveCapacity(body.count)
        var m = 0
        while m < body.count {
            if body[m] == 0x1B && m + 2 < body.count && body[m + 2] == 0x1C {
                masked.append(body[m]); masked.append(body[m + 1]); masked.append(body[m + 2])
                m += 3
                continue
            }
            let translated = flaggedControls[body[m]] ?? body[m]
            if translated != body[m] {
                // ledger: which bytes the translation rewrote (length-preserving, so
                // the offsets stay valid either side) — tasks #20/#21
                rtFlagged.append(RoundtripFlagged(offset: masked.count, original: body[m]))
            }
            masked.append(translated)
            m += 1
        }
        body = masked
        // footnotes/endnotes/annotations are all rendered the same way (a numbered
        // list at the end) and share one inline reference counter below, so
        // `footnotes` stays the flattened view the existing emitters already know how
        // to render; `notes` is what tells the four kinds apart. Comments are never
        // rendered inline — they only ever show up in `notes`.
        footnotes = notes
            .filter { $0.kind == .footnote || $0.kind == .endnote || $0.kind == .annotation }
            .map { [Span(text: $0.text)] }
    }

    // Every .he/.h1-.h5/.fo/.f1-.f5 IN DOCUMENT ORDER, always true for parseWS (a bare-CR
    // text file reaches parsePrintstream instead, which never enables it): WordStar
    // applies a running head/foot from the PAGE where it is defined -- see `Document.hfEvents`.
    let pass = linesPass(body, tabAt: tabAt, marks: wsMarks, softIsWrap: ws5, overprintCr: true)

    var active: Style = []
    /// The FONT RUN in force, index into `fonts`. Persists across lines and blocks just
    /// like `active` — a font change stays in effect until the next one.
    var activeFont: Int? = nil
    /// The COLOUR RUN in force (palette index), or `nil` for Black/no explicit colour.
    /// Persists across lines and blocks the same way `activeFont` does.
    var activeColour: Int? = nil
    var unknown: [UInt8: Int] = [:]
    var dots: [String] = []
    var dotPositions: [DotPosition] = []
    // Always live, not ws5-only: dot-line comments ('..'/'.ig') exist in WS4 files too
    // and now emit reference marks (ruling 2026-08-06 M9).
    var fnCounter: Int? = 0
    // Dot-line comment marks awaiting a content line — DEFERRED attachment: appending at
    // the dot line would let a following blank close a phantom line holding only the
    // mark, one extra printed line WordStar never had (M9).
    var pendingMarks: [Span] = []
    var ruler = false
    var page = PageAccumulator()
    var producer: String? = nil
    var spaceBeforeLines: Double? = nil
    var spaceAfterLines: Double? = nil
    var footnoteNumberStart: Int? = nil
    var endnoteNumberStart: Int? = nil
    var headers: [Int: String] = [:]
    var footers: [Int: String] = [:]
    // The `Document.fonts` index in force at each running head's/foot's own definition —
    // register C6, see `parseHeadFoot`.
    var headerFonts: [Int: Int] = [:]
    var footerFonts: [Int: Int] = [:]
    var hfEvents: [HFEvent] = []
    // Running FORMATTING state, stamped onto each block as it opens. Stateful, unlike
    // page geometry — see `Formatting2.swift`.
    var fmt = FormatState()
    var tocEntries: [TOCEntry] = []
    var indexEntries: [IndexEntry] = []
    var lineNumbering: Int? = nil

    // Formatting from the ACTIVE paragraph style. A 0x11 selection applies from its
    // paragraph ON, until the next selection — WordStar keeps the selected style in force,
    // and real documents switch back explicitly (NOVEL.WS re-selects 'MS Body Copy' after
    // every heading). Only fields the style's record sets non-inherited appear here;
    // everything else falls back to the running dot-command state.
    var styleFmt = StyleFormat()

    // A style record's font field is a full (width, height, typestyle) triple -- the
    // same three words as an inline type-2 Font block, and WordStar applies it the same
    // way: selecting the style CHANGES THE ACTIVE FONT. Left unapplied, the last inline
    // font block bleeds across every style-governed paragraph that follows. Styles that
    // carry no font (recordless, or the record's inherited sentinel) change nothing.
    var styleFontCache: [Int64: Int] = [:]
    func styleFontIndex(width w: Int, height h: Int, typestyle t: Int) -> Int {
        // w/h/t are all 16-bit fields (0...65535); packed into one Int64 key.
        let key = (Int64(w) << 32) | (Int64(h) << 16) | Int64(t)
        if let idx = styleFontCache[key] { return idx }
        if let idx = fonts.firstIndex(where: {
            $0.width1800 == w && $0.height1440 == h && $0.typestyle == t
        }) {
            styleFontCache[key] = idx
            return idx
        }
        // Not seen as an inline font block either: a NEW entry, offset -1 (Python's
        // `offset=None`) since it comes from the style library, not a position in the text.
        fonts.append(FontChange(offset: -1, width1800: w, height1440: h, typestyle: t))
        let idx = fonts.count - 1
        styleFontCache[key] = idx
        return idx
    }

    var blocks: [Block] = []
    func newBlock() -> Block {
        Block(kind: .para,
              heading: styleFmt.heading ?? 0,
              align: styleFmt.align ?? fmt.alignment,
              wrap: styleFmt.wrap ?? fmt.wrap ?? true,
              leftMargin: styleFmt.leftMargin ?? fmt.leftMargin,
              rightMargin: styleFmt.rightMargin ?? fmt.rightMargin,
              paraMargin: styleFmt.paraMargin ?? fmt.paraMargin,
              // Python typing provenance: a style's HMI margin is an int there
              // (`round(hmi / 180)`), a dot command's a float — the layout JSON
              // spells the number the same way (byte parity, 2026-08-18)
              leftMarginPyInt: styleFmt.leftMargin != nil,
              rightMarginPyInt: styleFmt.rightMargin != nil,
              tabStops: (fmt.tabStops?.isEmpty ?? true) ? nil : fmt.tabStops,
              columns: fmt.columns, columnGutter: fmt.columnGutter,
              styleID: styleFmt.styleID, styleName: styleFmt.styleName,
              styleAttrs: styleFmt.attrs,
              lineHeightVMI: styleFmt.lineHeightVMI, styleFontPt: styleFmt.styleFontPt,
              styleColour: styleFmt.styleColour)
    }
    var cur = newBlock()
    var curLine = Line()
    // Register b31 (E3 open items 2+3, 2026-08-25): has any BODY TEXT been committed
    // yet? Flips true the moment closeLine() below appends a Line that actually carries
    // spans -- the exact same "real content, not just a blank" test the rest of this
    // function already uses for its own position anchors (`pointsAt`/`hfAnchor` above:
    // `!cur.lines.isEmpty || !curLine.spans.isEmpty`). `parsePageDot` reads this (plus
    // the still-unclosed `curLine.spans`, for a dot line that follows text on the SAME
    // physical line's remainder -- doesn't happen in practice since dot lines are
    // always their own physical line, but cheap to be exact) to decide whether a
    // page-geometry command still gets to move the document's own default (before body
    // text: yes, last one standing wins) or must leave it alone (after body text
    // starts: the value is frozen, and any further change belongs solely to the
    // per-page checkpoint machinery in PDFLayout.swift). Direct port of core.py's
    // `_rt_body_seen` (ctrl-kd 5f3a102).
    var bodySeen = false

    /// LJ6DTP parity C1: modal marks rescued from CONSUMED lines (dot commands),
    /// replayed at offset 0 of the next line that actually decodes spans.
    var carriedMarks: [StructuralMark] = []

    // Round-trip ledger (tasks #20/#21): a running count of EVENTS in emission order —
    // Lines appended anywhere plus form-feed pagebreak blocks — and a locator for the
    // last Line appended, so each physical entry's raw separator can be stamped onto
    // the Line that actually closed it. Python holds the Line OBJECT (`_rt_last`);
    // value semantics need a location instead: `bi == nil` means "in `cur`", rebased to
    // the pushed block index when `closeBlock` moves `cur` into `blocks`. Dot lines are
    // anchored by this same counter: "this dot line sits before event N", which
    // survives every block split/drop that makes (block, line) anchors unstable.
    var rtTally = 0
    var rtContent = 0                    // Lines with spans specifically: fixups/togEnd
    var rtLast: (bi: Int?, li: Int)? = nil
    var rtLastC: (bi: Int?, li: Int)? = nil
    var rtDots: [RoundtripDot] = []
    func rtGetLine(_ ref: (bi: Int?, li: Int)) -> Line {
        if let bi = ref.bi { return blocks[bi].lines[ref.li] }
        return cur.lines[ref.li]
    }
    func rtSetLine(_ ref: (bi: Int?, li: Int), _ mutate: (inout Line) -> Void) {
        if let bi = ref.bi { mutate(&blocks[bi].lines[ref.li]) } else { mutate(&cur.lines[ref.li]) }
    }

    // core.py:275-286 — empty lines and empty blocks are never appended.
    func closeLine() {
        if !curLine.spans.isEmpty {
            // The `.lh` in force AS THIS LINE ENDS — a dot command sits on its own line, so
            // `fmt` cannot change part-way through a text line. Absolute here (WordStar's
            // own 8/48 until the file says otherwise); normalised against the document
            // default once that is known, below.
            curLine.lead48 = fmt.lead48 ?? defaultLh48
            // Register C7: `.KR` is STATEFUL, exactly like `.lh` above -- a dot command
            // sits on its own line, so it cannot change part-way through a text line.
            curLine.kerning = fmt.kerning ?? true
            // Register b31: `.po` gets the SAME absolute-then-back-dated treatment as
            // `.lh` above, for the same reason -- see `Line.poCols`.
            curLine.poCols = fmt.poCols ?? defaultPoCols
            // Register b32-N10 (mirrored from ctrl-kd b48148c): the `.sr` roll in force
            // as this line ends -- same "read the running state at close time" capture as
            // lead48/poCols/kerning just above. Never back-dated -- see `Line.roll48`.
            curLine.roll48 = fmt.subSuperRoll48 ?? defaultSr48
            cur.lines.append(curLine)
            rtTally += 1
            rtLast = (nil, cur.lines.count - 1)
            rtContent += 1
            rtLastC = (nil, cur.lines.count - 1)
            bodySeen = true
        }
        curLine = Line()
    }
    func closeBlock() {
        closeLine()
        if !cur.lines.isEmpty {
            blocks.append(cur)
            // rebase ledger locators that pointed into `cur` — see rtLast above
            if rtLast != nil, rtLast!.bi == nil { rtLast!.bi = blocks.count - 1 }
            if rtLastC != nil, rtLastC!.bi == nil { rtLastC!.bi = blocks.count - 1 }
        }
        cur = newBlock()
    }

    for (rtIdx, physical) in pass.lines.enumerated() {
        var raw = physical.text
        // this entry's raw separator bytes, and the event count before it — tasks
        // #20/#21, stamped onto whichever Line closes the entry below
        let rtBrk: [UInt8]? = rtIdx < pass.rawBreaks.count ? pass.rawBreaks[rtIdx] : nil
        let rtN0 = rtTally
        let rtC0 = rtContent
        let rtRaw0 = physical.text       // the FF branch consumes `raw`; capture first
        let rtAct0 = active.intersection(rtTogglable)
        // the transliteration (if any) of the font in force at line start — the same
        // lookup decodeSpans makes at flush time
        let rtKind0: SymbolTranslit? = activeFont.flatMap {
            $0 < fonts.count ? fontTranslitKind(fonts[$0]) : nil
        }
        // core.py:289 — masked unconditionally, NOT gated on stripHibit: a ws5+ dot line
        // is still recognized, and a ws4 dot whose '.' carries bit 7 (0xAE) still is too.
        let stripped = raw.map { $0 & 0x7F }

        // A line that BEGINS with a 0x0F print control's display string is content, not
        // a dot command -- but its first character is often « (0xAE), which the bit-7
        // masking above turns into '.' (0x2E), swallowing the whole line as an unknown
        // dot command.
        let pctlLeads = physical.marks.contains { rel, mark in
            guard rel == 0 else { return false }
            if case .pctl = mark { return true }
            return false
        }
        if stripped.first == 0x2E && !pctlLeads {             // '.' — dot command line
            // core.py:290-298 — captured as metadata; the line itself never becomes text.
            let cmd = rstrippingASCIIWhitespace(stripped)
            dots.append(decodeCP437(cmd))
            // Round-trip ledger (tasks #20/#21): the line's UNMASKED, UNSTRIPPED bytes
            // and its own separator, anchored to the event counter. `cmd` above is
            // bit-7-masked and rstripped — fine for interpretation, lossy for a
            // writer — and mailmerge lines (.av/.dm/.df/.rv...) must come back
            // byte-exact, never re-serialized from an interpretation (permanent
            // ruling).
            rtDots.append(RoundtripDot(anchor: rtTally, raw: physical.text,
                                       brk: rtBrk ?? []))
            // Where in the document this command sat: the coarsest anchor that is
            // actually stable (it survives reflow, which a byte offset does not).
            dotPositions.append(DotPosition(blockIndex: blocks.count,
                                            lineIndex: cur.lines.count,
                                            text: decodeCP437(cmd)))
            let head2 = Array(cmd.dropFirst().prefix(2)).map(asciiUppercased)
            // '..' and '.ig' are COMMENT lines (ruling 2026-08-06 M9): both WordStar
            // comment syntaxes unify into Note(kind: .comment), each emitting a
            // reference mark at its own position — the text is kept verbatim after the
            // syntax (a commented-out `..rm 60` is still a comment; `origin` says which
            // syntax carried it). `notes` must stay in reference-emission order, so the
            // note is INSERTED at the count of marks already numbered.
            if cmd.count >= 2, cmd[1] == 0x2E || head2 == dotIgnore {
                let isDotDot = cmd[1] == 0x2E
                let body = Array(cmd.dropFirst(isDotDot ? 2 : 3))
                let note = Note(kind: .comment,
                                text: decodeCP437(body).trimmed(),
                                origin: isDotDot ? .dotDot : .dotIG)
                notes.insert(note, at: fnCounter ?? 0)
                fnCounter = (fnCounter ?? 0) + 1
                pendingMarks.append(Span(text: String(fnCounter ?? 0),
                                         styles: [.sup, .fnref]))
            }
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
            // The block this event applies to: the one still open (if it has content)
            // or the next one to open. Same convention as `pointsAt` just below --
            // WordStar applies a running head/foot from the page where it is defined.
            let hfAnchor = blocks.count + ((!cur.lines.isEmpty || !curLine.spans.isEmpty) ? 1 : 0)
            // Header/footer TEXT is content, not command syntax: hand it the UNMASKED
            // line for WS5+. The bit-7 mask that protects WS4 command letters corrupts
            // 8-bit argument text -- LJ6DTP's `.h1` carries a wrapped <1B F9 1C> middle
            // dot whose F9 masked to 0x79, printing a 'y' beside every page number. WS4
            // (stripHibit) keeps the mask: its flag bits really do ride on argument
            // letters.
            // Register C6: a `.h1`/`.f1` argument can open with its own type-2 Font
            // block (LJ6DTP's does -- Antique Olive, proportional), the same mark
            // `decodeSpans`'s `fontAt` reads for body text. It contributes no bytes of
            // its own, so this line's OWN marks are the only place left to find it.
            var hfFontIdx: Int? = nil
            for (_, mark) in physical.marks {
                if case .font(let index) = mark { hfFontIdx = index; break }
            }
            parseHeadFoot(stripHibit ? cmd : rstrippingASCIIWhitespace(raw),
                         headers: &headers, footers: &footers,
                         headerFonts: &headerFonts, footerFonts: &footerFonts,
                         hfEvents: &hfEvents, anchor: hfAnchor, fontIdx: hfFontIdx)
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
                // origin .fi: fabricated placeholder, no source bytes of its own (the
                // `.fi` dot line carries them) — the round-trip writer skips it
                // without counting (tasks #20/#21)
                blocks.append(Block(kind: .para, lines: [
                    Line(spans: [Span(text: "[insert: \(inserted)]")])],
                    origin: .fi))
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
                spaceBeforeLines: &spaceBeforeLines,
                spaceAfterLines: &spaceAfterLines,
                footnoteNumberStart: &footnoteNumberStart,
                endnoteNumberStart: &endnoteNumberStart,
                hasText: bodySeen || !curLine.spans.isEmpty
            )
            // LJ6DTP parity C1: a dot-command line is CONSUMED here — it never reaches
            // `decodeSpans`, so any mark that landed on it dies with it. That silently
            // dropped LJ6DTP's colour RESTORE: the document sets colour 15 (White) for
            // its knockout bar, then restores colour 0 (Black) immediately after, and
            // that restore's own offset falls on the `.sr 3/48"` line that follows — so
            // every paragraph after it kept painting white on white and two full
            // paragraphs of page 6 vanished. The document itself warns about exactly
            // this hazard in its prose ("otherwise the rest of your text will be
            // invisible -- white letters on a white background"), and real WS7 prints
            // them black, so the restore IS in the file and we were losing it.
            //
            // Only FORWARD-LOOKING STATE carries: `.colour` and `.font` are modal and
            // belong to whatever text comes next. `.fnref` is a BACKWARD-looking anchor
            // (see its own placement rule in `linesPass`) and must never be moved
            // forward; neither must one-shot positional marks. Carried marks re-enter at
            // offset 0 of the next content line, which is where the state change
            // actually takes effect.
            for (_, mark) in physical.marks {
                switch mark {
                case .colour, .font: carriedMarks.append(mark)
                default: break
                }
            }
            continue
        }

        // A LITERAL form feed is a page break, in any variant. WSFORMAT.TXT: "0Ch ^L
        // Form Feed.  At print time causes page to be ejected.  No footer lines are
        // printed." `parsePrintstream` has always honoured it; `parseWS` did not, so a
        // WS document carrying ^L had its two pages run together into one paragraph and
        // the only trace was an "unknown code 0x0c" line in --diagnose.
        //
        // EVERY part is decoded HERE, the trailing one included, and `raw` is then empty
        // for the rest of the loop — core.py's `raw = b''`. This port used to keep the
        // last part back and let it fall through to the ordinary decode below, which put
        // it AFTER the structural-mark loop instead of before it. The two orders agree
        // until a line carries both a 0x0C and a mark: a paragraph-style selection at the
        // end of such a line then closed a block that Python had already filled, and the
        // document gained a boundary Python does not have (a blank line in text/modern, a
        // split `<pre>`/`\par` in html/rtf, and every following line shifted).
        //
        // Latent until 2026-08-04: the gate is `0x0C in raw` in both engines, and a
        // wrapped `<1B 0C 1C>` satisfies it, so the branch has always run for a line whose
        // only 0x0C is a triple middle. While that middle byte still SPLIT the line, both
        // engines were wrong in the same way and matched; once the split stopped, the
        // divergence in what happens to the trailing part became visible — one archive
        // document, a table whose rows carry a wrapped 0x0C and a style selection.
        if raw.contains(0x0C) {
            var segment: [UInt8] = []
            var k = 0
            func decodeSegment() {
                if !segment.isEmpty {
                    let spans = decodeSpans(segment, stripHibit: stripHibit,
                                            active: &active, activeFont: &activeFont,
                                            unknown: &unknown,
                                            fnCounter: &fnCounter,
                                            activeColour: &activeColour)
                    if !pendingMarks.isEmpty, !spans.isEmpty {
                        curLine.spans += pendingMarks
                        pendingMarks = []
                    }
                    curLine.spans += spans
                    segment = []
                }
            }
            while k < raw.count {
                // Split on BARE form feeds only — a wrapped `<1B 0C 1C>` is the cp437
                // glyph at 0x0C (the chart cell in ASCIITAB.WS), never a page eject.
                // `_split_bare_ff` in core.py.
                if raw[k] == 0x1B && k + 2 < raw.count && raw[k + 2] == 0x1C {
                    segment.append(raw[k]); segment.append(raw[k + 1]); segment.append(raw[k + 2])
                    k += 3
                    continue
                }
                if raw[k] == 0x0C {
                    decodeSegment()
                    // EVERY bare form feed ejects, the one that opens the document
                    // included — core.py's `if n:` over the split parts, with no
                    // is-anything-open guard. A leading ^L is a deliberate blank first
                    // page; suppressing it dropped a page the author asked for.
                    closeBlock()
                    // origin .ff: this break IS a byte (0x0C), unlike a `.pa` pagebreak
                    // whose bytes are its dot line. It also counts as an EVENT so dot
                    // lines on either side of it keep their order (tasks #20/#21).
                    blocks.append(Block(kind: .pagebreak, origin: .ff))
                    rtTally += 1
                } else {
                    segment.append(raw[k])
                }
                k += 1
            }
            decodeSegment()
            raw = []
        }

        // Structural marks, carried as OFFSETS rather than injected bytes — every byte
        // the old sentinels used (0x00 ^@, 0x0B ^K, 0x11 ^Q) is a real WordStar control
        // code that occurs in real documents, so a literal one was read as a page break,
        // a heading, or a note reference the author never wrote. See `StructuralMark`.
        var fnrefAt: [Int] = []
        var fontAt: [(offset: Int, index: Int)] = []
        var colourAt: [(offset: Int, colour: Int)] = []
        var pctlAt: [(offset: Int, hmi: Int, byteLen: Int, pcl: Int?)] = []
        var pixAt: [(offset: Int, index: Int, byteLen: Int)] = []
        var tabTargetAt: [(offset: Int, absHMI: Int, leader: UInt8, cols: Int)] = []
        // see the dot-command branch above
        var lineMarks = physical.marks
        if !carriedMarks.isEmpty {
            lineMarks = carriedMarks.map { (0, $0) } + lineMarks
            carriedMarks = []
        }
        for (rel, mark) in lineMarks {
            switch mark {
            case .softpage:
                // NOT a block, NOT a break: the editor drops these wherever the page
                // currently ends, including mid-paragraph, so closing the block here
                // severed real paragraphs. See the 0x0B parse site for the measurement.
                curLine.softpage = true
            case .style(let w0):
                // Resolve the handle against the file's own library. Pool tag 0x02 =
                // this file; anything else (0x03xx editing temps) is unresolvable BY
                // DESIGN and left unstyled rather than guessed. Heading level comes from
                // the RESOLVED NAME — the corpus proved slot numbers carry none (see the
                // 0x11 parse site). Register C1.
                //
                // The selection PERSISTS: `styleFmt` stays in force for every following
                // block until the next 0x11. A recordless entry (the inherit-everything
                // base, e.g. 'WordStar Defaults') resets formatting to the dot-command
                // state BY CONSTRUCTION, since it contributes no record fields.
                if (w0 >> 8) == 0x02 {
                    let slot = w0 & 0xFF
                    styleFmt = StyleFormat()
                    styleFmt.styleID = slot
                    if let entry = styleSlots[slot] {
                        styleFmt.styleName = entry.name
                        styleFmt.heading = styleHeadingLevel(entry.name)
                        if let record = entry.record {
                            // `.left` means EXPLICIT no-justification — it overrides a
                            // running `.oj`, so it must occupy the align slot rather than
                            // fall through.
                            styleFmt.align = record.justification
                            styleFmt.wrap = record.wordWrap
                            // HMI 1/1800in -> print columns at 10 CPI, the unit
                            // `.lm`/`.rm` already use (180 = 1 col).
                            styleFmt.leftMargin = record.leftMarginHMI.map(hmiToColumns)
                            styleFmt.rightMargin = record.rightMarginHMI.map(hmiToColumns)
                            styleFmt.paraMargin = record.paraMarginHMI.map(hmiToColumns)
                            styleFmt.attrs = record.attrs
                            // line_height_vmi: -2 = auto (the only value the measured
                            // oracle carries), a positive count = explicit VMI
                            // (WSFORMAT.WS: same 1/1440in unit as a font's own height
                            // word). `StyleRecord.lineHeightVMI` already folded -1
                            // (inherit) to `nil` at parse time, so a bare `if let` is the
                            // right test here -- 'inherit' never reaches this branch.
                            if let lh = record.lineHeightVMI {
                                styleFmt.lineHeightVMI = lh
                            }
                            // Register C5: the style's own declared colour index. A
                            // present-but-0 value is a real, explicit "Black", distinct
                            // from "the style never set one" -- `StyleRecord.colour`
                            // already folded the -1 inherit sentinel to `nil` at parse
                            // time, so a bare `if let` is the right test, exactly as it
                            // is for `lineHeightVMI` just above.
                            if let colour = record.colour {
                                styleFmt.styleColour = colour
                            }
                            // The style's font field is the SAME (width, height,
                            // typestyle) triple as an inline type-2 Font block, and
                            // selecting the style CHANGES THE ACTIVE FONT the same way.
                            // An all-zero triple records NO font (distinct from the
                            // inherit sentinel, which leaves `record.font` `nil` --
                            // never having been set at all), so it changes nothing.
                            if let font = record.font,
                               font.width != 0 || font.height != 0 || font.typestyle != 0 {
                                let idx = styleFontIndex(width: font.width, height: font.height,
                                                         typestyle: font.typestyle)
                                fontAt.append((offset: rel, index: idx))
                                // The style's own declared size, in points -- captured on
                                // the BLOCK (not just the span-level `fontAt` mark) so a
                                // spanless blank line, which carries no font tag of its
                                // own, can still resolve its style's auto/explicit
                                // leading.
                                styleFmt.styleFontPt = Double(font.height) / 20.0
                            }
                        }
                    }
                }
                // `styleFmt` is updated BEFORE this close: the previous block keeps its
                // old style, the fresh block picks the new one up from `newBlock()`. A
                // 0x03xx temp-pool handle is unresolvable by design, but a selection is
                // still a block boundary in the file, so this runs either way.
                closeBlock()
            case .fnref:
                fnrefAt.append(rel)
            case .font(let index):
                fontAt.append((offset: rel, index: index))
            case .colour(let index):
                colourAt.append((offset: rel, colour: index))
            case .pctl(let hmi, let byteLen, let pcl):
                pctlAt.append((offset: rel, hmi: hmi, byteLen: byteLen, pcl: pcl))
            case .pix(let index, let byteLen):
                pixAt.append((offset: rel, index: index, byteLen: byteLen))
            case .tab(let absHMI, let leader, let cols):
                tabTargetAt.append((offset: rel, absHMI: absHMI, leader: leader, cols: cols))
            }
        }

        let spans = decodeSpans(
            raw,
            stripHibit: stripHibit,
            active: &active,
            activeFont: &activeFont,
            unknown: &unknown,
            fnCounter: &fnCounter,
            fnrefAt: fnrefAt,
            fontAt: fontAt,
            fonts: fonts,
            activeColour: &activeColour,
            colourAt: colourAt,
            pctlAt: pctlAt,
            pixAt: pixAt,
            tabTargetAt: tabTargetAt
        )
        if !pendingMarks.isEmpty, !spans.isEmpty {
            // a content line arrived: deferred dot-comment marks land at its head, the
            // position the comment line occupied (M9)
            curLine.spans.append(contentsOf: pendingMarks)
            pendingMarks = []
        }
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
        case .over:
            // A bare-CR overprint separator: the NEXT line prints at THIS line's own
            // baseline (LJ6DTP's white-on-black knockouts; strikeover composites).
            curLine.overprint = true
            closeLine()
        case .blankSoft, .blankHard:
            // A blank physical line. It is CONTENT in printed mode (it occupied a
            // line on paper) and it does NOT close the block — the text line before
            // it already carried `.para` if this run was a paragraph boundary.
            // `soft` records which kind it was: `.ls` filler versus the author's own
            // return.
            //
            // `curLine` can ALREADY carry real spans here — not just invisible toggle
            // bytes, but genuine printable characters (round 26 wave 3, fidelity_gate.py
            // -README pg1 residual): `linesPass` classifies a physical line as blank by
            // its VISIBLE text after stripping, which is also true of a line that is
            // nothing but literal SPACE characters — e.g. a WS5+ TAB block (cmd 0x09,
            // `SymmetricBlocks.swift`) expanded to N literal spaces with nothing typed
            // after it (measured 2026-08-20, -README.WS: a right-aligned tab alone on
            // its own line, between "sawyer@sfwriter.com" and "Version 1.4" — WS7 prints
            // one 24pt blank-line gap there; the engine printed two, 36pt). This used to
            // call `closeLine()` FIRST, which committed that non-empty `curLine` as an
            // ordinary TEXT line, and THEN built a second, always-empty `blank` Line and
            // appended it on top — one source physical line became TWO Line objects,
            // doubling its printed vertical space (and cascading a uniform +1-line shift
            // through everything below it on the page). `curLine` itself — whitespace
            // spans or none — IS the one blank Line this physical entry always was;
            // reusing it (instead of committing it separately, then allocating a second,
            // empty Line) keeps both cases — truly empty and whitespace-only alike — to
            // exactly one Line each, matching `linesPass`'s own one-entry-per-physical-
            // line contract. Port of Python's `parse_ws` blank-branch fix.
            var blank = curLine
            blank.soft = physical.separator == .blankSoft
            blank.lead48 = fmt.lead48 ?? defaultLh48
            // Register b31: same treatment as `lead48` just above -- see `Line.poCols`.
            blank.poCols = fmt.poCols ?? defaultPoCols
            // Register b32-N10: same treatment as `lead48`/`poCols` just above -- see
            // `Line.roll48`.
            blank.roll48 = fmt.subSuperRoll48 ?? defaultSr48
            curLine = Line()
            let hasContent = !blank.spans.isEmpty
            let blankRef: (bi: Int?, li: Int)
            if cur.lines.isEmpty, let last = blocks.indices.last,
               blocks[last].kind == .para {
                // The text line before this one carried `.para` and already closed
                // its block, so `cur` is empty. On paper this blank FOLLOWS that
                // paragraph — attach it there, so a paragraph block still starts
                // with text and the linear order is unchanged.
                blocks[last].lines.append(blank)
                blankRef = (last, blocks[last].lines.count - 1)
            } else {
                cur.lines.append(blank)
                blankRef = (nil, cur.lines.count - 1)
            }
            rtTally += 1
            rtLast = blankRef
            if hasContent {                       // same content-ledger bookkeeping
                rtContent += 1                     // closeLine() would have done for
                rtLastC = blankRef                 // a non-empty line
            }
        case .para, .eof:
            closeBlock()
        }
        // Stamp this entry's raw separator on the Line that closed it (tasks #20/#21).
        // Entries that appended no Line (a toggles-only invisible line whose softness
        // folded into its predecessor) stamp nothing: their bytes are a known,
        // census-counted loss, and overwriting the predecessor's own separator would
        // corrupt a good one.
        if rtTally > rtN0, let ref = rtLast, let brk = rtBrk {
            rtSetLine(ref) { $0.brkRaw = brk }
        }
        // ... and the entry's lossy-decode record on the Line holding its TEXT (a
        // phantom blank may follow it and own the separator), or on the blank Line
        // itself for an invisible entry whose only bytes are controls (a lone ^P
        // before a break was vanishing entirely). A form-feed-split entry anchors
        // against its LAST part — the one whose Line closed last — because that is the
        // offset space the last Line's bytes actually live in; earlier parts' losses
        // are a census-counted tail.
        var rtTarget: (bi: Int?, li: Int)? = nil
        if rtContent > rtC0, let contentRef = rtLastC {
            rtTarget = contentRef
        } else if rtTally > rtN0, let anyRef = rtLast, rtGetLine(anyRef).spans.isEmpty {
            rtTarget = anyRef
        }
        if let target = rtTarget {
            var rtSrc = rtRaw0
            var rtTrAt: [(Int, SymbolTranslit?)] = []
            if rtRaw0.contains(0x0C) {
                rtSrc = rtSplitBareFF(rtRaw0).last ?? []
            } else {
                // mid-line font changes move the transliteration boundary —
                // fontcrib.ws switches to Symbol partway through a line, via a type-2
                // Font block on one page and via a paragraph-style selection whose
                // record carries a font on another. Both are replayed; a style with no
                // font of its own changes nothing ('inherit' keeps what is in force).
                // Offsets are entry-relative, so FF-split entries keep only line-start
                // state.
                for (rel, mark) in physical.markPairs {
                    switch mark {
                    case .font(let idx) where idx < fonts.count:
                        rtTrAt.append((rel, fontTranslitKind(fonts[idx])))
                    case .style(let handle) where (handle >> 8) == 0x02:
                        if let entry = styleSlots[handle & 0xFF],
                           let font = entry.record?.font,
                           font.width != 0 || font.height != 0 || font.typestyle != 0 {
                            rtTrAt.append((rel, fontTranslitKind(FontChange(
                                offset: -1, width1800: font.width,
                                height1440: font.height, typestyle: font.typestyle))))
                        }
                    default:
                        break
                    }
                }
            }
            let capture = rtLineCapture(rtSrc, stripHibit: stripHibit, ws5: ws5,
                                        active0: rtAct0, translit0: rtKind0,
                                        translitAt: rtTrAt)
            if !capture.togEnd.isEmpty {
                rtSetLine(target) { $0.togEnd = capture.togEnd }
            }
            if !capture.fixups.isEmpty {
                rtSetLine(target) { $0.fixups = capture.fixups }
            }
        }
    }
    closeBlock()

    if !pendingMarks.isEmpty {
        // trailing dot comments with no content line after them: the marks attach to the
        // END of the last content line (never a phantom line). A comment-only document
        // has no line to anchor to; the notes exist in doc.notes regardless, marks are
        // dropped. (M9)
        outer: for bi in blocks.indices.reversed() {
            if blocks[bi].kind == .para, let li = blocks[bi].lines.indices.last,
               !blocks[bi].lines[li].spans.isEmpty {
                blocks[bi].lines[li].spans.append(contentsOf: pendingMarks)
                break outer
            }
        }
        pendingMarks = []
    }

    // Exposed per the IR contract: a consumer must be able to distinguish "Legal
    // (from file)" from "Letter (default)" — provenance lives alongside every
    // resolved figure, not just the page size. Computed regardless of variant: page
    // geometry is a dot-command concern, not a symmetric-block (ws5+-only) one.
    let plLines = page.plLines ?? defaultPlLines
    let (heightIn, sizeName, pwIn) = resolvePageSize(plLines)
    let mtLines = page.mtLines ?? defaultMtLines
    let mbLines = page.mbLines ?? defaultMbLines
    let lh48 = page.lh48 ?? defaultLh48
    // Register b31: same "resolved document default, reused by the back-dating pass
    // below" shape as `lh48` just above -- see `Line.poCols`.
    let poColsDoc = page.poCols ?? defaultPoCols
    var pageGeometry = PageGeometry(
        plLines: plLines,
        heightIn: heightIn,
        sizeName: sizeName,
        pwIn: pwIn,
        sizeSource: page.plLines != nil ? .file : .default,
        mtLines: mtLines,
        mtSource: page.mtLines != nil ? .file : .default,
        mbLines: mbLines,
        mbSource: page.mbLines != nil ? .file : .default,
        poCols: poColsDoc,
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

    // `Line.lead48` was recorded ABSOLUTELY; now that the document default is known, every
    // line that simply agrees with it goes back to nil. The field then means what it says —
    // "this line's lead DIFFERS" — so the common case (one `.lh`, or none) leaves the whole
    // document clean and an emitter can test one optional instead of comparing floats on
    // every line.
    //
    // Note the asymmetry this deliberately preserves: the default is the FIRST `.lh` in the
    // file, so lines BEFORE it keep an explicit 8.0 (WordStar's own 6 LPI, which is what
    // they really printed at) rather than being back-dated to a setting that had not
    // happened yet.
    var lhVaries = false
    // Register b31: `Line.poCols` gets the SAME absolute-then-back-dated treatment as
    // `lead48` in this same loop, for the same reason -- see `Line.poCols`'s own comment.
    var poVaries = false
    for b in blocks.indices {
        for l in blocks[b].lines.indices {
            if blocks[b].lines[l].lead48 == lh48 {
                blocks[b].lines[l].lead48 = nil
            } else if blocks[b].lines[l].lead48 != nil {
                lhVaries = true
            }
            if blocks[b].lines[l].poCols == poColsDoc {
                blocks[b].lines[l].poCols = nil
            } else if blocks[b].lines[l].poCols != nil {
                poVaries = true
            }
        }
    }
    // One flag so a consumer (and the diagnostics) can say "this document changes its
    // leading" without walking every line.
    pageGeometry.lhVaries = lhVaries
    pageGeometry.poVaries = poVaries

    // ---------------- round-trip ledger (tasks #20/#21) ----------------
    // `body` here is the stream linesPass consumed (cleaned+translated for WS5+, the
    // raw file for WS4), so this recomputes the same EOF cut it used. The tail is
    // sliced from the ORIGINAL file: for WS5+ the cleaned cut is mapped back to a file
    // offset by re-adding what each consumed block's raw bytes displaced (blocks copy
    // nothing 1:1; everything else, wrapped triples included, does). Everything after
    // that offset — the ^Z itself, DOS padding, the style library the header points
    // into — comes back verbatim, which is also why blocks consumed BEYOND the cut are
    // excluded from `sym`: their bytes already live inside the tail.
    let rtCut = bareEOF(body)
    let rtSpliceable = rtSym.filter {
        rtCut == nil || $0.offset + max($0.expansion, 0) <= rtCut!
    }
    var rtTail: [UInt8] = []
    if ws5 {
        if let cut = rtCut {
            let fileCut = cut + rtSpliceable.reduce(0) { $0 + ($1.raw.count - $1.expansion) }
            rtTail = Array(data[min(fileCut, data.count)...])
        }
    } else if let cut = rtCut {
        rtTail = Array(data[min(cut, data.count)...])
    }
    let roundtrip = RoundtripLedger(
        era: era.name, encoding: "cp437", dots: rtDots, sym: rtSpliceable,
        flaggedAt: rtFlagged, eofTail: pass.eofTail, tail: rtTail,
        unsupported: rtShift ? "shift-jis" : nil)

    var doc = Document(
        blocks: blocks,
        footnotes: footnotes,
        detection: detection,
        marginEstimate: pass.margin,
        dotCommands: dots,
        dotPositions: dotPositions,
        unknownCodes: unknown,
        // Ruler lines mean "fixed-width table" only in the pre-symseq eras: a WS4 tab
        // table's alignment exists solely in monospace. In WS5+ a `.rr` ruler is just the
        // editor's tab settings and rides along in practically every styled document —
        // treating it as columnar forced NOVEL.WS and LJ6DTP.WS (both fully reflowable
        // prose) into physical-line rendering in EVERY modern emitter, which is where
        // Jon's "line wrapping isn't working" screenshots actually came from (the wrap
        // classifier itself was correct).
        columnar: ruler && !ws5,
        notes: notes,
        unknownBlocks: unknownBlocks,
        page: pageGeometry,
        producer: producer,
        spaceBeforeLines: spaceBeforeLines,
        spaceAfterLines: spaceAfterLines,
        footnoteNumberStart: footnoteNumberStart,
        endnoteNumberStart: endnoteNumberStart,
        era: era.name,
        headers: headers,
        footers: footers,
        hfEvents: hfEvents,
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
    doc.roundtrip = roundtrip
    // Register C6: which doc.fonts entry each running head/foot opened with.
    doc.headerFonts = headerFonts
    doc.footerFonts = footerFonts
    // Register C2: raw PCL printer payloads, indexed by a span's own `pcl`.
    doc.pclPrograms = pclPrograms
    return doc
}

/// Split raw line bytes on BARE form feeds only — a wrapped `<1B 0C 1C>` is the cp437
/// glyph at 0x0C, never a page eject. Port of `_split_bare_ff`, for the round-trip
/// capture (the inline FF branch above applies the same rule while decoding).
func rtSplitBareFF(_ raw: [UInt8]) -> [[UInt8]] {
    var parts: [[UInt8]] = []
    var cur: [UInt8] = []
    var k = 0
    while k < raw.count {
        if raw[k] == 0x1B, k + 2 < raw.count, raw[k + 2] == 0x1C {
            cur.append(raw[k]); cur.append(raw[k + 1]); cur.append(raw[k + 2])
            k += 3
            continue
        }
        if raw[k] == 0x0C {
            parts.append(cur)
            cur = []
            k += 1
            continue
        }
        cur.append(raw[k])
        k += 1
    }
    parts.append(cur)
    return parts
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
// NOT private (Finding 3, b26-print-fidelity-2): `PDFLayout.swift`'s `mtMbCheckpoints`
// needs it too, for the SAME `.mt`/`.mb` command-name case-folding the parser uses.
func asciiUppercased(_ b: UInt8) -> UInt8 {
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

/// Accumulates the page-geometry commands seen so far under a PRE-TEXT-LAST-WINS rule
/// (register b31, E3 open items 2+3, ruled 2026-08-25, ctrl-kd 5f3a102): while no body
/// text has been committed yet, each occurrence OVERWRITES the last (an author's own
/// immediate correction resolves to the LAST value — MICKEE.WS: `.hm 0.22"` then
/// `.hm3`, back-to-back, nothing between them; real WS7 prints at the SECOND value's
/// row). Once body text has begun, `parsePageDot` leaves every field here alone — a
/// repeat mid-document is the document's own STATEFUL behaviour, the domain of the
/// per-page checkpoint machinery in `PDFLayout.swift` (`plCheckpoints`/`hmFmCheckpoints`/
/// `mtMbCheckpoints`/`pnCheckpoints`), never this accumulator. `hmLines`/`fmLines`/
/// `lh48`/`ls` (ctrl-kd 1.3.0) follow the same rule; a REJECTED argument (see
/// `resolveLhArg`/`resolveLsArg`) leaves its field unchanged, exactly as if the dot
/// command had never been seen at that occurrence, so whatever stood before it stands.
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
/// lines/14in Legal, 81 lines/13.5in Foolscap Folio (the pre-ISO UK long sheet), and
/// A4 (297mm = 11.693in, ~70 lines -- ruled into the model 2026-08-06: "the 3 main
/// page sizes" are Letter, Legal, A4). There is no dot command for physical page
/// WIDTH, so width rides on the height inference: a page tall enough to be A4 is
/// 210mm wide, everything else is the 8.5in American sheet -- and a Custom height
/// keeps 8.5in, the only honest default the format allows.
private let namedPageSizes: [(name: String, heightIn: Double, widthIn: Double)] = [
    ("Letter", 11.0, 8.5), ("Legal", 14.0, 8.5), ("Foolscap Folio", 13.5, 8.5),
    ("A4", 11.693, 8.268),
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
let defaultSr48 = 3.0       // WSFORMAT.TXT: "[.SR] ... Default is 3." (1/48in units) --
                             // the same figure PDFLayout.swift/EmitRTF.swift already
                             // hardcode for their own `.sr`-absent fallback; named here
                             // so Line.roll48's per-line resolution (register b32-N10,
                             // mirrored from ctrl-kd b48148c) shares the one constant.
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
    parseDotNumberConsuming(arg).map { ($0.value, $0.unit) }
}

/// Like `parseDotNumber`, but also reports how far the match consumed —
/// Python's `m.end()`: leading spaces + number + trailing spaces + the
/// optional unit. `.co`'s gutter parse needs it: the gutter follows the
/// column count after separators that may be a comma OR just spaces
/// (`.co 2  1.00"` is real), so "scan for a comma" loses space-separated
/// gutters. Found 2026-08-04 when the archive cross-check flagged one
/// document: BOOKLET's two-column gutter vanished from the Swift HTML.
func parseDotNumberConsuming(_ arg: [UInt8]) -> (value: Double, unit: [UInt8]?, end: Int)? {
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
    var end = j                                     // `\s*` consumed either way,
                                                     // matching the regex's m.end()
    if j < arg.count {
        if arg[j] == 0x22 {                         // '"'
            unit = [arg[j]]
            end = j + 1
        } else if isASCIILetter(arg[j]) {
            var k = j + 1
            if k < arg.count && isASCIILetter(arg[k]) { k += 1 }   // up to 2 letters
            unit = Array(arg[j..<k])
            end = k
        }
    }
    return (value, unit, end)
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
// NOT private (Finding 3, b26-print-fidelity-2): `PDFLayout.swift`'s `mtMbCheckpoints`
// needs the SAME `.mt`/`.mb` unit resolution the parser itself uses, so a mid-document
// `.mt`/`.mb` checkpoint value matches byte-for-byte what parsing that same command at
// document-open would have produced.
func resolveLinesArg(_ value: Double, _ unit: [UInt8]?) -> Double {
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
func resolveLhArg(_ value: Double, _ unit: [UInt8]?) -> Double? {
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
/// `fontIdx` (register C6) is the `Document.fonts` index the caller found on THIS
/// physical line's own marks — a `.h1`/`.f1` argument can open with a type-2 Font block
/// exactly like body text can (LJ6DTP's does: Antique Olive, proportional, 13pt), and
/// that block contributes no bytes of its own to the cleaned stream, so nothing but the
/// caller's own marks lookup can recover it once we are down here working on bytes.
/// PRINTED mode used to fall back to a hardcoded Courier for every running head because
/// nothing captured it. `nil` (every document that never opens a `.h#`/`.f#` with a font
/// block) leaves the line's entry absent, which is what `runningOps` reads as "no font".
func parseHeadFoot(_ cmd: [UInt8], headers: inout [Int: String], footers: inout [Int: String],
                   headerFonts: inout [Int: Int], footerFonts: inout [Int: Int],
                   hfEvents: inout [HFEvent], anchor: Int, fontIdx: Int? = nil) {
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
    // Wrapped extended characters `<1B x 1C>` appear in header text exactly as in the
    // body (LJ6DTP separates its title from the `#` page number with a wrapped middle
    // dot): decode them through the same cp437 rule the body uses -- control-range
    // middles are chart glyphs, the rest are the byte's own cp437 character. Decode
    // FIRST, then trim: the byte-level rstrip this used to do ran before any of that,
    // which is fine when there's no wrapped triple in play (the common case) but
    // matches ctrl-kd's own ordering only this way round.
    let text = decodeHeadFootText(rest).trimmedTrailing()
    let kind: HFKind = first == 0x48 ? .header : .footer
    if kind == .header {
        headers[line] = text
        // FINAL STATE, the same limitation `headers` itself has: a document that
        // redefines a running head's FONT (not just its text) mid-file keeps only the
        // last one seen. Python assigns `None` here; an absent key says the same thing.
        headerFonts[line] = fontIdx
        if fontIdx == nil { headerFonts.removeValue(forKey: line) }
    } else {
        footers[line] = text
        footerFonts[line] = fontIdx
        if fontIdx == nil { footerFonts.removeValue(forKey: line) }
    }
    hfEvents.append(HFEvent(kind: kind, line: line, text: text, blockAnchor: anchor))
}

/// Decode header/footer TEXT, expanding `<1B x 1C>` wrapped characters: the middle byte
/// is "a character to display" for ANY value 00h-FFh (WSFORMAT), so a control-range
/// middle (x < 0x20 or x == 0x7F) is the cp437 GLYPH at that position — the smiley/arrow/
/// box-drawing graphics `decodeSpans` already renders for the body — never the control
/// action; anything else is the byte's own ordinary cp437 character. Direct port of the
/// wrapped-triple loop `_parse_head_foot` runs over its text argument.
private func decodeHeadFootText(_ raw: [UInt8]) -> String {
    var parts: [String] = []
    var pos = 0
    var i = 0
    while i < raw.count {
        if raw[i] == 0x1B, i + 2 < raw.count, raw[i + 2] == 0x1C {
            if i > pos { parts.append(decodeCP437(Array(raw[pos..<i]))) }
            let x = raw[i + 1]
            parts.append(cp437Graphics[x] ?? decodeCP437([x]))
            i += 3
            pos = i
            continue
        }
        i += 1
    }
    if pos < raw.count { parts.append(decodeCP437(Array(raw[pos...]))) }
    return parts.joined()
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

/// `pl_lines` -> (height_in, size_name, width_in). Snaps to a named size when close;
/// otherwise reports the raw geometry under "Custom" (at the 8.5in width -- see
/// `namedPageSizes`) rather than forcing a label that doesn't fit. Direct port of
/// `_resolve_page_size`. Not private since `effectivePage`'s size override recomputes
/// the trio through it (EmitOptions.swift).
func resolvePageSize(_ plLines: Double) -> (heightIn: Double, sizeName: String, widthIn: Double) {
    let heightIn = plLines / 6.0
    var best = namedPageSizes[0]
    var bestDiff = abs(best.heightIn - heightIn)
    for candidate in namedPageSizes.dropFirst() {
        let diff = abs(candidate.heightIn - heightIn)
        if diff < bestDiff {
            best = candidate
            bestDiff = diff
        }
    }
    if bestDiff <= pageSizeSnapIn {
        return (best.heightIn, best.name, best.widthIn)
    }
    return (heightIn, "Custom", 8.5)
}

/// Try to interpret one dot-command line as page geometry (`.pl`/`.po`/`.mt`/`.mb`/
/// `.hm`/`.fm`/`.lh`/`.ls`, ctrl-kd 1.3.0 added the last four) or a WordTsar-invented
/// command (`.PT`/`.PSA`/`.PSB` -- "not a Wordstar command" per WordTsar's own source,
/// so their mere presence is a producer signal). The line is
/// ALWAYS also kept verbatim in `Document.dotCommands` by the caller, recognised or
/// not — including `.PT`'s own raw argument, so no separate field is needed for that
/// here. Direct port of `_parse_page_dot`.
///
/// `hasText` (register b31, E3 open items 2+3, ruled 2026-08-25, ctrl-kd 5f3a102): true
/// once real body text has been committed to the document — see `parseWS`'s `bodySeen`.
/// Every command in `page`'s PRE-TEXT-LAST-WINS set (`.pl`/`.mt`/`.mb`/`.po`/`.hm`/
/// `.fm`/`.lh`/`.ls`/`.cw`/`.pn`/`.pc`) is a no-op here once `hasText` is true — a
/// mid-document repeat is the document's own stateful behaviour (per-page checkpoint
/// machinery in `PDFLayout.swift`), never this accumulator's concern. `.F#`/`.E#`
/// (footnote/endnote start numbers, into `footnoteNumberStart`/`endnoteNumberStart`)
/// and `.PT`/`.PSA`/`.PSB` (producer signal, spacing) keep their own pre-existing
/// first-occurrence-wins behaviour, untouched by `hasText` — they are not part of
/// `page` and outside this ruling's scope.
///
/// `.F#`/`.E#` (same spec) set the footnote/endnote starting numbering value -- the
/// two-character command NAME itself ends in the literal '#' (like `.L#`
/// line-numbering), which the generic `[A-Za-z]{1,3}` matcher below can't match, so
/// it's handled directly first.
private func parsePageDot(
    _ cmd: [UInt8],
    page: inout PageAccumulator,
    producer: inout String?,
    spaceBeforeLines: inout Double?,
    spaceAfterLines: inout Double?,
    footnoteNumberStart: inout Int?,
    endnoteNumberStart: inout Int?,
    hasText: Bool = false
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
    // Register b31 (E3 open items 2+3, ruled 2026-08-25, ctrl-kd 5f3a102):
    // PRE-TEXT-LAST-WINS, not first-occurrence-wins. Python's dispatch is generic
    // (`_PAGE_DOT_RESOLVERS.get(key, _resolve_lines_arg)` followed by "store only if
    // the resolver didn't return None, unless hasText") because a Python dict can hold
    // one resolver function per key; a Swift `switch` over named struct fields has no
    // equivalent indirection, so the same RULE is applied per case instead: bail out
    // untouched once `hasText` (a mid-document repeat is the per-page checkpoint
    // machinery's concern, not this accumulator's), else OVERWRITE unconditionally (no
    // `== nil` guard — the last pre-text occurrence wins), and a rejected value leaves
    // the accumulator exactly as it was so whatever stood before it stands.
    // `.pl`/`.mt`/`.mb`/`.hm`/`.fm`'s resolver (`resolveLinesArg`) and `.po`'s
    // (`resolveColsArg`, pre-existing) never reject, so a direct assignment is
    // behaviorally identical to Python's "store only if resolved" for all five —
    // unchanged from before ctrl-kd 1.3.0. `.lh`/`.ls` (1.3.0) and `.cw` (2.0.0) CAN
    // reject — `resolveLhArg`/`resolveLsArg`/`resolveCwArg` return `nil` for a
    // non-positive height/width or an out-of-range spacing — so those three guard the
    // store behind `if let`.
    case "PL":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.plLines = resolveLinesArg(value, unit)
    case "MT":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.mtLines = resolveLinesArg(value, unit)
    case "MB":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.mbLines = resolveLinesArg(value, unit)
    case "PO":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.poCols = resolveColsArg(value, unit)
    case "HM":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.hmLines = resolveLinesArg(value, unit)
    case "FM":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        page.fmLines = resolveLinesArg(value, unit)
    case "LH":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveLhArg(value, unit) { page.lh48 = resolved }
    case "LS":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveLsArg(value, unit) { page.ls = resolved }
    case "CW":
        if hasText { return }
        guard let (value, unit) = parseDotNumber(arg) else { return }
        if let resolved = resolveCwArg(value, unit) { page.cw120 = resolved }
    case "PN":
        // `.pn n` sets the number of the page it appears on, so the document does not
        // have to start at 1 — a chapter file in a larger manuscript starts wherever
        // the previous one stopped. MEASURED on WordStar 4 (2026-08-03): `.pn 7`
        // numbers the pages 7, 8, 9 in both the header's `#` and the footer's.
        if hasText { return }
        guard let (value, _) = parseDotNumber(arg) else { return }
        page.pnStart = value
    case "PC":
        // `.pc n` is the column of the AUTOMATIC page number — the one WordStar prints
        // on its own. Measured: it does NOT move a `#` placed inside a header or
        // footer, which prints where the author put it. Two separate mechanisms.
        if hasText { return }
        guard let (value, _) = parseDotNumber(arg) else { return }
        page.pcCol = value
    case "PT", "PSA", "PSB":
        // WordTsar's own invented dot commands (its source calls them "not a Wordstar
        // command"). A real WordStar file never contains these -- their presence IS
        // the producer signal. `detection.variant` stays what it is (the ENCODING,
        // still WS5+/7); this is provenance, not format.
        producer = "wordtsar"
        if nameString == "PSA" || nameString == "PSB" {
            // First occurrence wins, same rule as every other page-dot field --
            // `parseDotNumber` returns nil for a junk (non-numeric) argument, in
            // which case there is nothing to record (matches Python: `value =
            // ... if num and num.group(1) else None`, then only stored `if
            // value is not None`).
            if let (value, _) = parseDotNumber(arg) {
                if nameString == "PSA", spaceAfterLines == nil {
                    spaceAfterLines = value
                } else if nameString == "PSB", spaceBeforeLines == nil {
                    spaceBeforeLines = value
                }
            }
        }
    default:
        break
    }
}

/// Bare high-bit bytes that are a flagged CONTROL CODE, and the control they mask to.
///
///     0x82  flagged ^B bold toggle   (27x in 4 documents)
///     0x8C  flagged ^L form feed     (20x in 5 documents)
///     0x94  flagged ^T sup toggle    (oracle-measured)
///
/// See `parseWS` for why this is an allowlist and never a range.
private let flaggedControls: [UInt8: UInt8] = [0x82: 0x02, 0x8C: 0x0C, 0x94: 0x14]

/// Formatting the ACTIVE paragraph style contributes, if any. Every field is `nil`/empty
/// when the style's record inherits it, which is exactly when the running dot-command
/// state should show through instead — see `parseWS`'s `newBlock`.
private struct StyleFormat {
    var styleID: Int? = nil
    var styleName: String? = nil
    var heading: Int? = nil
    var align: Alignment? = nil
    var wrap: Bool? = nil
    var leftMargin: Double? = nil
    var rightMargin: Double? = nil
    var paraMargin: Double? = nil
    var attrs: Style = []
    /// The style's own `line_height_vmi` (-2 auto or an explicit positive VMI count) —
    /// `nil` alongside an inherited/absent field, in which case a consumer's `.lh`/
    /// default leading is unchanged. See `Block.lineHeightVMI`.
    var lineHeightVMI: Int? = nil
    /// The style's own declared font size in points, captured alongside `fontAt` since a
    /// blank physical line carries no span/font tag of its own to read a size off. See
    /// `Block.styleFontPt`.
    var styleFontPt: Double? = nil
    /// The style's own declared colour index (0-15, WSFORMAT's fixed CGA/EGA palette --
    /// the same space as an inline type-1 colour change). See `Block.styleColour`.
    var styleColour: Int? = nil
}

/// HMI (1/1800in) -> print columns at 10 CPI, round-half-to-even like Python's `round()`.
/// Margins can be negative in principle, so this is not the integer-only helper
/// `SymmetricBlocks.swift` uses for tab widths.
private func hmiToColumns(_ hmi: Int) -> Double {
    Double(roundHalfToEven(Double(hmi) / 180.0))
}
