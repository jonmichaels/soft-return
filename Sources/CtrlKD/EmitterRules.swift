/// Rules that more than one emitter has to answer the same way.
///
/// Each of these used to live inside whichever renderer needed it first — the PDF
/// writer, the PDF's Modern layout — which is exactly why the RTF and HTML emitters
/// answered them differently or not at all (planning #264, the RTF/HTML review packet:
/// rows B3, B6, B4, A10). They are DOCUMENT rules, not one renderer's geometry, so they
/// live in one place now and every emitter calls them. ctrl-kd made the identical move
/// in the same round, into `core.py`.
///
/// The evidence for each rule is on the function itself; a call site says only which
/// surface it is answering for.

// MARK: - A bare 0x09 tab byte (packet row B3)

/// A bare 0x09 tab byte's print-time expansion target, in document columns —
/// WSFORMAT.WS's own file-format reference (WordStar's control-code table, byte 09h ^I):
/// "At print time the number of hard spaces required to reach a modulus 8 print position
/// is generated."
let tabModulusColumns = 8

/// One physical line's `Span`s, with every bare 0x09 tab byte expanded into the literal
/// spaces WordStar's print-time rule computes.
///
/// PRINTED ONLY, and only where the text is MONOSPACED: the Printed PDF (since planning
/// #244/#251), Printed RTF's physical lines and the fixed-pitch HTML block
/// (`p.ws-native`) — planning #264 item 1, packet row B3. There, a column IS a character,
/// so expanding a tab to spaces is exact and the columns land where WordStar put them.
/// Before that row, Printed RTF and HTML emitted the raw byte instead: measured
/// 2026-09-12 on the archive's own WordStar file-format reference, 62 surviving tab bytes
/// in each RTF and 103–107 in each HTML, where a browser usually collapses a tab to a
/// single space. MODERN IS DELIBERATELY EXCLUDED (the packet's own "not for Modern"): a
/// reflowed proportional document has no print columns for a tab to land on. Text and
/// Markdown keep the raw byte too — row B3 named two surfaces and those are not among
/// them.
///
/// The rule used to run at PARSE time (planning #202/#237), which was the right
/// structural rule in the wrong place: baking the expansion into the parsed `Span.text`
/// makes a computed space indistinguishable from one the author typed, so the native
/// WordStar writer's round-trip re-emitted spaces instead of the original 0x09 byte and
/// never reproduced the source file (planning #244). The document model keeps the literal
/// byte; a printed-mode renderer applies this on a transient copy.
///
/// COLUMN TRACKING: a running count across the WHOLE physical line (every span, in order,
/// regardless of style — a font or colour change never consumes a column), reset for each
/// call, so one call is one physical line.
///
/// Planning #237 remainder (probed 2026-09-09): a literal space (or a WS5+ soft space,
/// already collapsed to plain " " by decode) immediately preceding a bare 0x09 does NOT
/// just occupy its own column like any other character before the tab. WS7's LaserJet
/// driver computes the tab's modulus-8 stop from the column BEFORE that trailing run of
/// space(s) — as if it had not yet flushed them to its own column tracker — then adds the
/// run's length back on top of that stop. Eight probe documents printed through real WS7
/// confirm this exactly, including a trailing space run that itself lands EXACTLY on a
/// modulus-8 stop (probe `P4`: 7 characters then one space, column 8, already on a stop,
/// lands the next word at column 9, not the old same-column rule's answer of 16).
/// `spaceRun` tracks the length of the CONSECUTIVE run of literal spaces immediately
/// preceding the current position, across spans; on a bare tab the modulus lands on
/// `col - spaceRun`, falling back to plain `col` when there is no preceding space run —
/// the ORIGINAL rule, unchanged for every tab not preceded by a space.
///
/// Spans come back untouched when the line carries no tab.
func expandBareTabsForPrintedLayout(_ spans: [Span]) -> [Span] {
    guard spans.contains(where: { $0.text.contains("\t") }) else { return spans }
    var col = 0
    var spaceRun = 0
    return spans.map { span in
        guard span.text.contains("\t") else {
            col += span.text.count
            let trailing = span.text.reversed().prefix(while: { $0 == " " }).count
            spaceRun = trailing == span.text.count ? spaceRun + trailing : trailing
            return span
        }
        var out = ""
        out.reserveCapacity(span.text.count)
        for ch in span.text {
            if ch == "\t" {
                let base = col - spaceRun
                let needed = tabModulusColumns - (base % tabModulusColumns)
                out += String(repeating: " ", count: needed)
                col = base + needed + spaceRun
                spaceRun = 0
            } else if ch == " " {
                out.append(ch)
                col += 1
                spaceRun += 1
            } else {
                out.append(ch)
                col += 1
                spaceRun = 0
            }
        }
        var newSpan = span
        newSpan.text = out
        return newSpan
    }
}

// MARK: - `.pm`'s own first-line indent (packet row B6)

/// `.pm`'s first-line indent for one block, in document print columns, or `nil` when the
/// block never set `.pm` (`block.paraMargin`).
///
/// `.pm` is the PARAGRAPH margin: the column a paragraph's first line auto-indents to
/// when WordStar STARTS it under that margin. It is an absolute column in the same frame
/// `.lm`/`.po` use, NOT a delta against `.lm`, and NOT an amount added on top of whatever
/// the author already typed there by hand.
///
/// TYPED-INDENT OFFSET (planning #202, PCL tier, WARPRAYR.WS). That document's two
/// Quote-styled blocks (`paraMargin` 5, from the style record rather than a literal
/// `.pm`) open each stanza with 10 literal leading spaces the author typed. Real WS7
/// (ws7-prints/v1/WARPRAYR.pcl/.measurements.json, page 1 y=448.5 and page 2
/// y=326.1/369.6/513.3/556.5) prints those lines at exactly left-edge + 10 typed columns
/// (50.4 + 72.0 = 122.4pt) — the style's own 5-column indent contributes NOTHING once the
/// typed text already reaches column 10. Modelled as `max(0, pmCols - alreadyTypedCols)`:
/// a typed indent SHORTER than `.pm`'s column is still topped up to it, one that already
/// reaches or passes it adds nothing further.
///
/// NO `.pm`, NO CONVENTION (planning #257, sawyer/REF/-HOW-TO.RJS). The clamp at zero is
/// the other half: a block under `.pm 0"` that centres a banner with literal typed spaces
/// has no margin mechanism behind those spaces, so `.pm` must never pull its first line
/// back to the left of where the author typed it.
///
/// Both refinements reached the Printed PDF alone until planning #264 item 2 (packet row
/// B6) moved the rule here, so Printed RTF — which renders PHYSICAL lines and therefore
/// carries a typed indent into its output as real characters — stopped adding `.pm`'s
/// full column on top of it.
///
/// Blank leading lines are skipped: this reads the block's first REAL line, which is the
/// line the indent is ultimately applied to.
func pmFirstLineIndentCols(_ block: Block) -> Double? {
    guard let paraMargin = block.paraMargin else { return nil }
    var typedCols = 0.0
    if let firstReal = block.lines.first(where: { line in
        line.spans.contains { $0.text.contains { !$0.isWhitespace } }
    }) {
        let text = firstReal.spans.map { $0.text }.joined()
        typedCols = Double(text.prefix(while: { $0 == " " }).count)
    }
    return max(0.0, paraMargin - typedCols)
}

// MARK: - The rows that refuse to wrap (packet row B4)

/// WHICH ROWS REFUSE TO WRAP (job 456, and the app's own b28 follow-up on it — ported
/// from Soft Return, the app is the reference; moved here from `PDFModernLayout.swift` by
/// planning #264 item 3, packet row B4, so HTML asks the same question the Modern PDF
/// asks).
///
/// A row of box-drawing or block characters is a picture, not a sentence: broken across
/// two visual lines it stops being the thing it draws. Three shapes qualify, read off the
/// row's own final rendered text:
///
///   wholly graphic    at least one graphic character, and nothing else on the row but
///                     graphic characters and spaces (a box border, a rule).
///   2+ graphic chars  job 456's own rule and the field report behind it ("I don't
///                     understand what happened in Modern. They have line returns in the
///                     middle"). A MIXED row — a real prose label plus its glyphs — is the
///                     case: a legend row ("LL: └ LR: ┘ … Joins: … Mixed: …") or a
///                     substitution-table row, which ordinary word wrapping folds at the
///                     perfectly legal space between label and glyph. The threshold is
///                     TWO, not one, so an ordinary paragraph carrying a single incidental
///                     symbol (a list marker) still wraps like the prose it is.
///   nowhere to break  a row with no space in it at all. A greedy wrapper never breaks
///                     inside a token, so such a row already sets as one line; stated
///                     anyway, because it is part of the rule and a renderer that CAN
///                     break a word must not.
///
/// The caller decides what "does not wrap" means in its own medium: the PDF gives the row
/// an unbounded wrap width (the app's `.byClipping`), HTML gives it `white-space:nowrap`
/// and asks only the first two branches — a browser never breaks inside a word on its
/// own, so the third would be markup that changes nothing.
///
/// WHICH CHARACTERS COUNT is the caller's too, because the two surfaces genuinely mean
/// different sets and this module keeps them apart on purpose (see
/// `contentGraphicChars`' own note). `chars` defaults to `contentGraphicChars` — the
/// CONTENT classification, the same set `splitGraphicSpans`, `looksLikeVerse` and HTML's
/// `ws-graphic` rule read. `modernClipsRow` passes the PDF's `graphicChars` instead: the
/// union of the per-glyph DRAWING tables, which also holds the four arc corners (produced
/// only by the LJ6DTP Univers substitution at render time, never decoded from a file) and
/// `₧`, the peseta — drawn as geometry because no base-14 face carries it (planning #266)
/// but an ordinary currency character in prose rather than box art. Asking the drawing set
/// in HTML put a "this row is a picture" verdict on a price list: the archive's printer
/// character charts carry rows like `158  ₧ ₧`, which the drawing set reads as two graphic
/// characters and the content set reads as none. The cross-engine gate caught exactly that,
/// on eight cells across two documents.
/// Whether this row's MEANING IS ITS COLUMNS — a fixed-pitch table row — and if so, the
/// column its SECOND column starts at (measured from the start of `text`, so a caller adds
/// whatever indent it stripped off the front). `nil` when this row is not one.
///
/// Planning #264, the browser check (research/2026-09-14_html-browser-check.md, section
/// 2). `graphicRowClips` above already protects a row whose columns are drawn with box
/// characters; WSFORMAT.WS's own control-code table draws its columns with nothing but
/// SPACES, carried no such character, and folded at a 400px viewport in both views — 15
/// source lines rendering as 45, every continuation falling back to the body margin.
///
/// THE SIGNAL is an interior run of THREE OR MORE spaces between two visible characters:
/// a second column, positioned by padding. Three, not two, because two is WordStar-era
/// sentence spacing — an author who types "code.  All codes" after a full stop is writing
/// prose, not a table. Leading and trailing padding do not count: a first-line indent and
/// a centred line's own padding are both one column, not two.
///
/// Measured over the Sawyer archive: 7260 of 61640 lines (11.8%), and the documents at the
/// top of that list are FILELIST.TXT, CP00437.TXT, the `.PS` font cribs and WSFORMAT.WS,
/// which is exactly the population the rule is for.
///
/// The caller decides what to DO about it in its own medium, the same division of labour
/// `graphicRowClips` documents. Modern HTML gives such a row a real HANGING indent;
/// Printed HTML needs nothing extra, its whole block being `white-space:pre`.
/// Port of `core.fixed_pitch_column_body_col`.
func fixedPitchColumnBodyCol(_ text: String) -> Int? {
    let chars = Array(text)
    var i = 0
    // skip leading padding: a first-line indent is one column, not two
    while i < chars.count, chars[i] == " " { i += 1 }
    var seenVisible = false
    var run = 0
    var gapStart = 0
    while i < chars.count {
        if chars[i] == " " {
            if run == 0 { gapStart = i }
            run += 1
        } else {
            if seenVisible, run >= 3 { return gapStart + run }
            seenVisible = true
            run = 0
        }
        i += 1
    }
    return nil
}

func graphicRowClips(_ text: String, _ chars: Set<Character> = contentGraphicChars) -> Bool {
    let graphicCount = text.reduce(0) { $0 + (chars.contains($1) ? 1 : 0) }
    if graphicCount > 0,
       text.allSatisfy({ chars.contains($0) || $0 == " " || $0 == "\u{00a0}" || $0 == "\u{2060}" }) {
        return true
    }
    if graphicCount > 1 { return true }
    return !text.isEmpty && !text.contains(" ")
}

// MARK: - A trailing `.pa` that opened no page (packet row A10)

/// The index of a trailing `.pa` block that must draw NOTHING, or `nil`.
///
/// Planning #264 item 2 (packet row A10), extended to every emitter by item 4 of the same
/// round. A `.pa` that is the document's own LAST block only opens a page when at least
/// one more real line of content was typed after it before EOF — real WS7's rule, measured
/// over eleven harness probes (planning #228,
/// research/2026-09-08_trailing-pa-rule.md), and already parsed as `doc.paEofBlankAfter`.
/// The PDF has read that fact since #228 and the RTF since #264 item 2; HTML, text and
/// Markdown were still marking a break the document never earned — a dashed rule, a form
/// feed and a horizontal rule respectively, each of them the LAST thing in the file,
/// separating the document from nothing.
///
/// One fact, one reading, every emitter — not a second detector. A mid-document `.pa` is
/// untouched, and a document that never ends in one carries no `paEofBlankAfter` at all
/// and is unchanged.
func trailingPASkipIndex(_ doc: Document) -> Int? {
    guard let last = doc.blocks.last, last.kind == .pagebreak else { return nil }
    if doc.paEofBlankAfter { return nil }
    return doc.blocks.count - 1
}
