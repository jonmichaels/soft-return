/// The footnote / annotation / endnote half of Printed mode: the page-bottom note area, its
/// continuation across pages, and the endnotes at the end of the document. The printed
/// paginator (`layoutPrintedPages`) runs this for a document that has notes; a document
/// without them lays out through the same paginator with the note area never opened.

// MARK: - Printed mode: the period-authentic footnote/endnote/annotation layout
//
// The WordStar 5 manual: "Footnotes are separated from the text by a line of 20 dashes. If
// a footnote doesn't fit at the bottom of the page, the continued text is printed in the
// footnote area at the bottom of the next page." What WS7 does, from the teardown (WS7
// report 11.11, 14.8, 14.15, 15.1; runs fn1, fn2, fnfit52, fnlong2, fnr0-fnr99, fnbig,
// fnhuge, fnlong120, ann52), room counted in lines from the reference line down to the
// bottom margin:
// 1. A note that fits whole prints under its reference with its last line one line above
//    the bottom margin line (the reserve in `printedNotesReservePt`).
// 2. A note that does not fit and finds under `fnrun` note lines of room (factory 8,
//    `footnoteRunFactory`) moves to the next page together with its reference line.
// 3. Otherwise the note RUNS: its first part prints under the reference (the room after
//    the reference line less four lines: the area's three and one WS7 keeps), the area
//    ends ON the bottom margin line, and the page takes no more body lines. The rest
//    continues on the next page under a separator with `...Continued...` directly below
//    it, then a blank line.
// 4. There is no floor of body lines: a carried-over note takes as much of its page as it
//    needs, a whole page when it is long enough (run fnlong120: note-only pages).
// 5. After the last page of body text, whatever is still queued prints on fresh pages.
//
// Annotations share the footnote area (their `tag` is the marker); endnotes never appear
// there at all — they collect at the true end of the document with no heading, per the
// spec. Comments never print. Footnote/endnote numbering is independent: the shown number is
// each `Note.number` (0-based, with the `.f#`/`.e#` start already folded in by WS7) plus one.

/// WS7's "footnote run" setting, in note lines (WS7 report 14.15, root:1A12): below this
/// much room a note moves to the next page with its reference line instead of running over.
/// `Document.footnoteRunLines` overrides it.
let footnoteRunFactory = 8

/// A note-only page's area sits 16 decipoints (1.6 pt) below the grid (WS7 report 15.1,
/// runs fnlong120, fnch175, fnch250, fnch250mb).
let noteOnlyDropPt = 1.6

/// A footnote/annotation waiting in the page-bottom queue. `remaining` shrinks as pages
/// consume it; `needsContinuedMarker` is set the moment a page takes only part of it, so the
/// NEXT page that resumes it prepends the literal continuation line first.
internal struct QueuedNote {   // internal: the progress invariant is unit-tested
    var remaining: [PageLine]
    var needsContinuedMarker: Bool
}

let footerContinuedLine = "...Continued..."

/// Reserved marker-field width, in character columns, for this document's
/// footnote/endnote/annotation area — Finding 4 (b26 visual pass, a real WS7 capture
/// pairing a "1." footnote with a "(1)" endnote on the same page). WS7's own capture
/// hangs a note's text to a COMMON column when the document's own markers are not all
/// the same width: both entries' TEXT starts at the identical x — measured 864
/// decipoints, column 5 from the note area's own left margin (504 decipoints): the
/// widest marker's own natural width ("(1)", 3 columns) plus 2 columns of padding.
/// Every other note-bearing document measured so far uses markers of ONE width
/// throughout (a single-footnote document: "1.Did", ONE space, no hang), so this
/// returns `nil` there — meaning "leave `footerEntryLines`/`endnoteEntryLines`'s plain
/// single-space join alone", exactly the previous behaviour, byte-identical.
///
/// Computed DOCUMENT-WIDE, not per page or per note-kind: a short document's footnotes
/// and endnotes can land on the very SAME rendered page (`layoutPrintedPages`
/// continuing the footnote/annotation area's last page into the endnote section when
/// there's room), so one document-global number is what lets both agree without new
/// cross-call plumbing — this port already folds both sections into ONE function, so a
/// single local computation covers both call sites. A comment's reference has no
/// note-area entry of its own (`keepSpanOnPageline`) and never reaches here. Port of
/// Python's `_notes_marker_pad_cols`.
///
/// 2026-09-12 (`sawyer/REF/NOTES.TST`): a note that carries its OWN tab
/// (`Note.textIndents`, a nested type-9 block in the note's own text stream) states
/// where its text goes and is left out of this vote entirely — WS7 obeys the document,
/// not a hang column derived from the other notes. The two documents this finding was
/// measured on turn out to tab BOTH their notes to column 5, exactly the number this
/// function returned for them, so they render identically either way; NOTES.TST tabs
/// its footnotes to 3 and its endnotes to 5, and only its (untabbed) annotations still
/// ask this question — of one marker width, so the answer is `nil` and their own
/// single-space join stands, which is what WS7 prints.
func notesMarkerPadCols(_ doc: Document) -> Int? {
    var widths = Set<Int>()
    for (i, note) in doc.notes.enumerated() {
        if note.textIndents.contains(where: { $0 != 0 }) { continue }
        switch note.kind {
        case .footnote: widths.insert("\(noteLabel(note, doc: doc, index: i, printed: true))." .width)
        case .endnote: widths.insert("(\(noteLabel(note, doc: doc, index: i, printed: true)))".width)
        case .annotation: widths.insert(noteLabel(note, doc: doc, index: i, printed: true).width)
        case .comment: continue
        }
    }
    if widths.count <= 1 { return nil }
    return (widths.max() ?? 0) + 2
}

/// `base` left-justified to `padCols` columns when given (matching Python's
/// `str.ljust` — a `base` already at or past that width is returned unchanged, never
/// truncated), or `base` plus a single trailing space when `padCols` is `nil` — the
/// pre-Finding-4 behaviour every single-marker-width document still gets. Port of the
/// shared tail of Python's `_note_marker`/`_endnote_marker`.
func padMarker(_ base: String, padCols: Int?) -> String {
    guard let padCols else { return base + " " }
    let n = base.width
    guard n < padCols else { return base }
    return base + String(repeating: " ", count: padCols - n)
}

/// The marker text a `fnref` span (or a footer/endnote entry) displays for one note.
///
/// Delegates to `noteLabel` and must keep doing so. This used to reimplement the same
/// rule and drifted from it: where `noteLabel` falls back to the note's position when
/// `Note.number` is nil (a real outcome — the tag word's high bit means the file never
/// resolved a number), this used `?? 0`, so EVERY unnumbered note of a kind rendered with
/// the SAME marker. Two different footnotes both showed "1", inline and in the footer.
/// The flat emitters were correct; only this lane was wrong, and no vector caught it
/// because none exercises a nil number in printed mode.
///
/// `printed` is false only for the legacy Modern notes dump (`docToPagelines(printed: false)`),
/// whose labels are never lettered by `.f#`/`.e#`.
func noteMarker(_ note: Note, doc: Document, index: Int, printed: Bool = true) -> String {
    noteLabel(note, doc: doc, index: index, printed: printed)
}

/// The footer entry for one footnote/annotation, wrapped to `width` — factory-default
/// marks: `1.` (trailing period) for a footnote, the bare tag for an annotation.
///
/// `padCols` (Finding 4, b26 visual pass): see `notesMarkerPadCols`. `nil` for a
/// FOOTNOTE (the overwhelming common case -- any document whose notes all share one
/// marker width) means WS7's own capture carries NO padding and NO separating space at
/// all between the marker and the note text -- measured directly (planning #202
/// residuals round, ctrl-kd 1017391, LYING.pcl's own single footnote: `"1.Did"`, ONE
/// literal chunk, zero characters between the period and the capital D). A prior round's
/// own comment here read that exact same measurement as "ONE space" and left the join
/// unchanged rather than acting on it; it was misread -- the PCL evidence has never had
/// a space in it. Every OTHER footnote-bearing document measured so far also uses
/// markers of ONE width throughout, so this is the path they all take too; none of them
/// has its own WS7 capture to confirm or contradict the join, so the single confirmed
/// reading (no separator) is what now governs all of them, not a guess independent of
/// it. ANNOTATIONS keep the original space: their marker is a free-text tag with no
/// trailing punctuation of its own (unlike a footnote's period), and no corpus capture
/// has ever measured one -- widening the fix to a kind with no evidence either way is
/// exactly the guess this fix itself replaces.
///
/// `separateSpans` (planning #202 residuals round, ctrl-kd 1017391): the REAL Printed
/// footer/endnote area wraps the marker and the note's own text as TWO SEPARATE spans
/// (Python's `_note_wrap(marker, text, width)`, called `_wrap_line([(marker, ...),
/// (text, ...)], width)` -- each span is word-tokenized on its OWN, before the two
/// token streams are concatenated, so the marker's own last token and the note text's
/// own first word stay separate SEGMENTS even with zero characters between them, same
/// as before this fix's marker join lost its trailing space). This call site's own
/// legacy Modern notes-dump caller (`docToPagelines(doc, printed: false)`, ctrl-kd
/// pdf.py:3389) pre-joins `marker + note_text` into ONE span instead -- unaffected by
/// this fix, and the only caller that still wants `false` here: at THAT joint, `false`
/// keeps this call byte-identical to before this parameter existed. Invisible to a
/// flattened text/PDF comparison either way (a PDF Tj string carries no segment
/// boundaries), so this only matters where the segment STRUCTURE is itself observed --
/// `layout.json`'s `printed.pages[].lines[].segments` (planning #202 residuals round,
/// AnswerKeyParityTests' `LYING.WS.layout.*` divergence, LYING's own "1.Did" case).
/// One note's own PHYSICAL text lines (`Note.textLines`), with the sentence-spacing and
/// euro-table passes already applied -- what the page-bottom and endnote areas actually
/// print.
///
/// WordStar stores a note as the author typed it and prints it the same way: a hard
/// return inside the note text is a hard return on paper. MEASURED (ws7-prints/v4,
/// PRISTINE.EXE): each of the 19 TAGS/ annotations in the Sawyer archive stores a
/// LEADING EMPTY line, and real WS7 prints the tag alone on the note area's first line
/// with the text on the next -- `sawyer/TAGS/WHY` puts "[Why?]" at 672.0pt and "Why?"
/// at 684.0pt. Flowing the note's lines into one string put both on a single line and
/// lifted the whole (bottom-anchored) area a line.
///
/// A note with no `textLines` at all -- a dot-line comment, a synthetic fixture built by
/// hand -- falls back to its flowed `text` as one line, byte-identical to this
/// function's predecessor. Port of Python's `pdf._note_texts`.
func noteTexts(_ note: Note, doc: Document, sentenceSpacing: Bool) -> [String] {
    let raw = note.textLines.isEmpty ? [note.text] : note.textLines
    let spaced = sentenceSpacing ? sentenceSpacingTexts(raw) : raw
    let euro = pesetaMeansEuro(doc)
    return spaced.map { euroText($0, euro) }
}

/// One note's rendered lines, the marker joining the line it is STORED on. Port of
/// Python's `pdf._note_wrap(marker, texts, width, tag_line)`.
///
/// `indents` (`Note.textIndents`, 2026-09-12) is the note's own TAB per physical line —
/// an ABSOLUTE column from the note area's left margin, 0 for a line that tabs nothing.
/// A tab MOVES RIGHT only: WordStar cannot pull text back over a marker already
/// printed, so a column at or left of where the line already stands is spent and leaves
/// no gap (the same reading a body tab gets). MEASURED against real WS7 (ws7-prints/v4,
/// PRISTINE.EXE) on `sawyer/REF/NOTES.TST`: footnote marker "1." at 57.6pt with its
/// text tabbed to HMI 540 prints "Footnote One." at 79.2pt (column 3); endnote "(1)"
/// with HMI 900 prints "Endnote one." at 93.6pt (column 5).
func noteWrapLines(marker: String, texts: [String], width: Int,
                           tagLine: Int, separateSpans: Bool,
                           indents: [Int] = []) -> [PageLine] {
    let texts = texts.isEmpty ? [""] : texts
    let tagLine = Swift.min(Swift.max(0, tagLine), texts.count - 1)
    var out: [PageLine] = []
    for (n, line) in texts.enumerated() {
        let col = n < indents.count ? indents[n] : 0
        if n == tagLine {
            let head = col > marker.width
                ? marker + String(repeating: " ", count: col - marker.width)
                : marker
            out.append(contentsOf: separateSpans
                ? wrapLine([Span(text: head), Span(text: line)], width: width)
                : wrapLine([Span(text: "\(head)\(line)")], width: width))
        } else if col > 0 {
            let pad = String(repeating: " ", count: col)
            out.append(contentsOf: separateSpans
                ? wrapLine([Span(text: pad), Span(text: line)], width: width)
                : wrapLine([Span(text: "\(pad)\(line)")], width: width))
        } else {
            out.append(contentsOf: wrapLine([Span(text: line)], width: width))
        }
    }
    return out
}

func footerEntryLines(_ note: Note, doc: Document, index: Int,
                              width: Int, padCols: Int? = nil,
                              sentenceSpacing: Bool = false,
                              separateSpans: Bool = true,
                              printed: Bool = true) -> [PageLine] {
    // N9 (b33 field notes): applied to the note's own text before the marker is
    // prepended -- the marker itself (a bare number/tag) carries no sentence-ending
    // punctuation of its own to interact with.
    // planning #266: the driver-keyed cp437-158 rule (`pesetaMeansEuro`) -- a note is part
    // of the document, and this path reads `note.text` straight off it.
    let noteTextLines = noteTexts(note, doc: doc, sentenceSpacing: sentenceSpacing)
    let marker: String
    switch note.kind {
    case .footnote:
        let base = "\(noteMarker(note, doc: doc, index: index, printed: printed))."
        marker = padCols != nil ? padMarker(base, padCols: padCols) : base
    case .annotation:
        let label = noteMarker(note, doc: doc, index: index, printed: printed)
        // an untagged annotation: WS7 prints its text at the margin
        marker = label.isEmpty ? "" : padMarker(label, padCols: padCols)
    default:
        // unreached: endnotes/comments never queue here
        return wrapLine([Span(text: noteTextLines.joined(separator: " "))], width: width)
    }
    return noteWrapLines(marker: marker, texts: noteTextLines, width: width,
                         tagLine: note.tagLine, separateSpans: separateSpans,
                         indents: note.textIndents)
}

/// The true-end-of-document entry for one endnote — factory-default mark `(1)`.
/// `padCols`/`separateSpans`: see `footerEntryLines` (Python's own true-end-of-document
/// listing, pdf.py:2765, is the SAME `_note_wrap(marker, text, width)` shape).
func endnoteEntryLines(_ note: Note, doc: Document, index: Int,
                               width: Int, padCols: Int? = nil,
                               sentenceSpacing: Bool = false,
                               separateSpans: Bool = true,
                               printed: Bool = true) -> [PageLine] {
    let marker = padMarker("(\(noteMarker(note, doc: doc, index: index, printed: printed)))",
                           padCols: padCols)
    // planning #266: see `footerEntryLines`.
    return noteWrapLines(marker: marker,
                         texts: noteTexts(note, doc: doc, sentenceSpacing: sentenceSpacing),
                         width: width, tagLine: note.tagLine, separateSpans: separateSpans,
                         indents: note.textIndents)
}

/// The fewest text lines a page's geometry may leave (pdf.py's `FOOTNOTE_FLOOR`): the floor
/// Python applies to the page height and capacity themselves — see `_resolved_page_height`/
/// `_printed_cap`. WS7 keeps no body-line floor against a note area (WS7 report 15.1).
///
/// `internal` since M18 (2026-09-15): `modernSheetH` applies the same floor to Modern's
/// own sheet, for the same reason, and must read the same constant rather than a second
/// copy of it.
let footnoteFloor = 3

/// Total lines the footnote area occupies FOR PAGE-CAPACITY PURPOSES (how many body lines
/// this paginator admits onto a page before the footnote area needs room, and this area's
/// own share of the page's room): the fixed 3-line header (blank / 20-dash
/// separator / blank — VMI 240 = one blank line at 6 LPI) plus each entry's own lines plus
/// one blank line between entries (VMI 240 "between notes"). 0 when there's nothing to
/// show at all. Port of Python's `_area_size`.
///
/// DELIBERATELY NOT the same count `renderArea` visually draws (mechanism U, ctrl-kd
/// `PCL-DIVERGENCE-TRIAGE.md`, `ws7-prints/v3` PRISTINE.EXE round, commit 26169cd) — see
/// that function's own doc comment for why the RENDERED area is 2 lines, not 3. Reducing
/// this function to 2 as well breaks LYING's own page break (real WS7, both installs, ends
/// page 1 at the same line this engine already does at every count from 3 up; reducing to
/// 2 lets one MORE body line fit before the cap, which real WS7 does not do) — so the
/// capacity/pagination budget for this header is 3 lines even though only 2 of them are
/// literally drawn. Empirically necessary, not fully explained.
func areaSize(_ entries: [[PageLine]]) -> Int {
    guard !entries.isEmpty else { return 0 }
    return 3 + entries.reduce(0) { $0 + $1.count } + (entries.count - 1)
}

/// True for a note chunk that opens with the `...Continued...` line.
func isContinuationChunk(_ chunk: [PageLine]) -> Bool {
    guard let first = chunk.first else { return false }
    return first.count == 1 && first[0].text == footerContinuedLine
}

/// The admitted area as page lines: separator / blank, then the entries with one blank
/// between. A carried-over note puts `...Continued...` directly under the separator, then
/// the blank (WS7 report 14.15, runs fnr0, fnbig: separator, Continued, blank, note lines).
/// Port of Python's `_render_area`.
///
/// The header this function draws is 2 lines, not 3 — but `areaSize`'s own page-CAPACITY
/// cost stays 3 (see that function's own doc comment): the rendered and budgeted line
/// counts DELIBERATELY diverge (mechanism U, ctrl-kd `PCL-DIVERGENCE-TRIAGE.md`).
///
/// `extraBlank`: the page where a chain of note-only pages ends prints one blank row more
/// under `...Continued...` (WS7 report 15.1, runs fnlong120, fnch175, fnch250).
func renderArea(_ entries: [[PageLine]], extraBlank: Bool = false) -> [PageLine] {
    guard let firstEntry = entries.first else { return [] }
    let sep: PageLine = [Span(text: String(repeating: "-", count: 20))]
    var out: [PageLine]
    if isContinuationChunk(firstEntry) {
        out = [sep, firstEntry[0], []]
        if extraBlank { out.append([]) }
        out.append(contentsOf: firstEntry.dropFirst())
    } else {
        out = [sep, []]
        out.append(contentsOf: firstEntry)
    }
    for e in entries.dropFirst() {
        out.append([])
        out.append(contentsOf: e)
    }
    return out
}

/// Move whole/partial note-chunks from the FRONT of `queue` into `entries` (mutating both)
/// until the footnote area would exceed `ceiling` lines. A chunk that only partly fits is
/// split: the part that fits joins `entries`, and the remainder stays queued behind a
/// `...Continued...` marker, ready to resume on a later page's area — this is the only
/// place a note's text is ever cut. Port of Python's `_admit_footnotes`, including its
/// hang guard: a chunk already carrying the continuation line only advances when at least
/// 2 lines fit (at one it would admit the marker and add it straight back); a NEW note's
/// first line is progress. When the page cannot manage that AND the area is still empty,
/// two lines are forced through — a page that overflows slightly beats a hang or lost text.
///
/// `freshSlack`: lines a NEW note's first part leaves unused when it is split under its
/// reference (WS7 report 14.15: the room after the reference line less four, the area's
/// own three being counted in `ceiling`); a carried-over chunk uses every line it is
/// given. Returns true when a chunk was split, i.e. the area ends in a running note; a
/// chunk with no room at all just stays queued.
// internal (not private): the progress invariant is unit-tested.
@discardableResult
internal func admitFootnotes(
    _ entries: inout [[PageLine]], _ queue: inout [QueuedNote], ceiling: Int,
    freshSlack: Int = 0
) -> Bool {
    while !queue.isEmpty {
        var chunk: [PageLine] = []
        if queue[0].needsContinuedMarker {
            chunk.append([Span(text: footerContinuedLine)])
        }
        chunk.append(contentsOf: queue[0].remaining)
        let overhead = entries.isEmpty ? 3 : 1      // inter-note blank, or the area's
                                                    // header if it's empty so far
        let room = ceiling - areaSize(entries) - overhead
        if room >= chunk.count {
            entries.append(chunk)
            queue.removeFirst()
            continue
        }
        let carried = queue[0].needsContinuedMarker
        let avail = room - (carried ? 0 : freshSlack)
        let split: Int
        if avail >= (carried ? 2 : 1) {
            split = avail
        } else if entries.isEmpty {
            split = Swift.min(chunk.count, 2)       // forced progress, per the doc above
        } else {
            return false                            // defer: next page starts empty
        }
        entries.append(Array(chunk.prefix(split)))
        // However many of `split` came from the synthetic `...Continued...` line (at most
        // one, always first) don't count against the note's own remaining text.
        let markerTaken = queue[0].needsContinuedMarker ? Swift.min(split, 1) : 0
        queue[0].remaining.removeFirst(Swift.min(split - markerTaken, queue[0].remaining.count))
        if queue[0].remaining.isEmpty {
            queue.removeFirst()
        } else {
            queue[0].needsContinuedMarker = true
        }
        return true
    }
    return false
}

/// The note area of the page being filled, and the notes still waiting for one: the whole
/// footnote/annotation half of the printed paginator, as one value the paginator
/// (`layoutPrintedPages`) consults at a handful of points. A document with no
/// footnote/annotation reference never queues anything, so every hook is then a no-op and the
/// page is exactly the plain page.
///
/// The area is whole LINES at the document's default lead (`areaSize`) -- its own text
/// carries no per-style leading -- while the body it sits under is spent in points; the
/// paginator converts at that one boundary (`heightPt`, `roomLines`).
struct NoteArea {
    /// Notes whose reference has been read but whose text has not yet been admitted to a
    /// page's area, in document order.
    var queue: [QueuedNote] = []
    /// The chunks admitted to the OPEN page's area.
    var entries: [[PageLine]] = []
    /// The open page's area ends in a note that runs on (a split first part, or a
    /// carried-over part), which WS7 anchors on the bottom margin line instead of one line
    /// above it.
    var running = false
    /// A note was split under its reference on this page, so the page takes no more body
    /// lines (the rest of it is the running note's).
    var sealed = false
    /// Finding 4 (b26 visual pass): see `notesMarkerPadCols` -- computed ONCE, shared by the
    /// footnote/annotation area and the endnote section, so a document whose footnotes and
    /// endnotes land on the same page agree on one column.
    let padCols: Int?
    let doc: Document
    let defaultLead: Double
    let sentenceSpacing: Bool
    /// A note that runs over several pages (WS7 report 15.1): whether the open page follows
    /// a note-only page, or a page whose block had to print under its text; and what the
    /// page being closed was.
    var afterNoteOnly = false
    var afterUnderText = false
    var closedNoteOnly = false
    var closedUnderText = false

    init(_ doc: Document, defaultLead: Double, sentenceSpacing: Bool) {
        self.doc = doc
        self.defaultLead = defaultLead
        self.sentenceSpacing = sentenceSpacing
        padCols = notesMarkerPadCols(doc)
    }

    /// The open page's area, in points.
    var heightPt: Double { Double(capacityLines) * defaultLead }

    /// The open page is where a long note's chain resumes its text: it follows a note-only
    /// page (or the page whose block printed under its text), and its area is that note's
    /// remainder alone, whole.
    var isChainPage: Bool {
        (afterNoteOnly || afterUnderText) && entries.count == 1
            && isContinuationChunk(entries[0]) && !(queue.first?.needsContinuedMarker ?? false)
    }

    /// Lines the open page's area takes from its body. On a chain page the editor keeps one
    /// row less than the printed header needs: it leaves 55 - 47 - 3 = 5 rows of text for a
    /// 47-line remainder where a two-page split would leave 4 (WS7 report 15.1, run fnch250
    /// p6: text lines 51-55).
    var capacityLines: Int {
        let size = areaSize(entries)
        return isChainPage ? size - 1 : size
    }

    /// A page opens with an empty area; whatever an earlier page could not hold is admitted
    /// by `admit` before any new reference queues behind it.
    mutating func beginPage() {
        entries = []
        running = false
        sealed = false
        afterNoteOnly = closedNoteOnly
        afterUnderText = closedUnderText
        closedNoteOnly = false
        closedUnderText = false
    }

    /// The notes referenced on a body line just placed, in order.
    mutating func enqueue(_ due: [(note: Note, index: Int)], width: Int) {
        for ref in due {
            queue.append(QueuedNote(
                remaining: footerEntryLines(ref.note, doc: doc, index: ref.index,
                                            width: width, padCols: padCols,
                                            sentenceSpacing: sentenceSpacing),
                needsContinuedMarker: false))
        }
    }

    /// Admit queued notes while the area fits `roomLines` of the open page.
    /// `freshSlack` is the line a new note's first part leaves unused when it runs
    /// (`admitFootnotes`); the carry-over a page opens with takes every line it can.
    mutating func admit(roomLines: Int, freshSlack: Int = 1) {
        if let first = queue.first, first.needsContinuedMarker { running = true }
        if admitFootnotes(&entries, &queue, ceiling: roomLines, freshSlack: freshSlack) {
            running = true
            if freshSlack > 0 { sealed = true }
        }
    }

    /// Whether queueing the notes of `due` now would leave one of them running or deferred,
    /// and how many lines the open page's area would take. Leaves the area untouched.
    func runWouldSplit(_ due: [(note: Note, index: Int)], width: Int,
                       roomLines: Int) -> (split: Bool, taken: Int) {
        var trial = self
        let before = trial.entries.reduce(0) { $0 + $1.count }
        trial.enqueue(due, width: width)
        let split = admitFootnotes(&trial.entries, &trial.queue, ceiling: roomLines,
                                   freshSlack: 1)
        let taken = trial.entries.reduce(0) { $0 + $1.count } - before
        return (split || !trial.queue.isEmpty, taken)
    }

    /// The area as page lines, bottom-anchored on its page.
    ///
    /// Finding 2 bottom-anchor geometry (see `printedNotesReservePt`): the area's FIRST line
    /// (the header's leading blank) gets an overridden `.lead` that lands it exactly
    /// `reserve` above the page bottom, counting up through the area's own remaining lines --
    /// rather than wherever the body's sequential flow happened to leave off. `bodyY` is the
    /// body's own last baseline (top-down points): the points the body already spent below
    /// the page's text top. `geometry` is the document as THIS page is drawn (its own
    /// stamped `.mt`/`.mb`/`.pl`, see `pageGeometryDocument`), so the anchor lands where the
    /// writer will put the page's bottom, not where the document's first page has it.
    ///
    /// APPLIED whenever it pushes the area DOWN AT ALL (`override > 0`) -- NOT gated on
    /// exceeding one whole `defaultLead` gap (planning #202 residuals round, ctrl-kd
    /// 1017391): that gate's own rationale -- "a full page (LYING.WS) already lands within a
    /// line of the target on its own, so this is a no-op there, byte-identical" -- assumed
    /// the flow path's own ordinary single-blank-line gap could only ever UNDERSHOOT the
    /// target when `override` came out under one lead. LYING is a full page and its own real
    /// WS7 capture (LYING.pcl) measures its footnote line at y=708pt, but the flow path's
    /// plain `defaultLead` gap OVERSHOOTS the anchor by 4.8pt (natural 676.8pt vs the
    /// anchor's own 672.0pt target, `override` a genuine 7.2pt -- less than one 12pt lead,
    /// so the old `> defaultLead` gate skipped it and left the 4.8pt overshoot standing) --
    /// the assumption held for every oracle it was checked against, but was never actually
    /// correct for a SMALL positive override, only ever coincidentally close enough not to
    /// be caught. A negative or zero override (the body's own flow already reached or passed
    /// the target) is still left alone -- "never move backward into the body" is unchanged.
    mutating func anchoredArea(in geometry: Document, bodyY: Double,
                               bodyEmpty: Bool = false) -> [PageLine] {
        var area = renderArea(entries)
        guard !area.isEmpty else { return area }
        let pageH = Double(resolvedPageHeight(geometry, printed: true))
        var reserve = printedNotesReservePt(geometry)
        if running { reserve -= defaultLead }       // ends ON the bottom margin line
        var targetFirst = pageH - reserve - Double(area.count - 1) * defaultLead
        if bodyEmpty {
            // A note-only page sits `noteOnlyDropPt` below the grid: the separator at 616,
            // the last line at BB + 16 decipoints, at either margin (WS7 report 15.1, runs
            // fnlong120, fnch175, fnch250, fnch250mb; the cause is not established).
            targetFirst += noteOnlyDropPt
            closedNoteOnly = true
        } else if isChainPage {
            let chain = chainArea(bottomY: pageH - reserve, bodyY: bodyY,
                                  targetFirst: targetFirst, area: area)
            area = chain.area
            targetFirst = chain.first
        }
        let override = targetFirst - bodyY
        if override > 0 {
            area[0].lead = override
        }
        return area
    }

    /// The remainder of a long note on the page where its chain resumes the text (WS7 report
    /// 15.1; runs fnlong120 p4, fnch175 p5, fnch250 p6-p7, fnch250mb p7). `bottomY` is the
    /// bottom margin line, BB. Port of Python's `_NoteArea._chain_area`.
    ///
    /// The block is placed with the header counted twice and one blank row more under
    /// `...Continued...`: P = BB - R*LH - 2H, the last note line three rows above BB. Where
    /// that would put the separator above the place under the text (the last text baseline
    /// + 3 rows), the block prints directly under the text instead, with no extra row, fills
    /// to BB, and the rest of the note carries on; the page after that prints its remainder
    /// under the text again, with the extra row. Returns the area and the first line's y.
    private mutating func chainArea(bottomY: Double, bodyY: Double, targetFirst: Double,
                                    area: [PageLine]) -> (area: [PageLine], first: Double) {
        let lead = defaultLead
        let notes = entries[0].count - 1
        let under = bodyY + 3 * lead
        if !afterUnderText {
            let first = bottomY - 3 * lead - Double(notes + 3) * lead
            if first >= under {
                return (renderArea(entries, extraBlank: true), first)
            }
        }
        let extra = afterUnderText ? 1 : 0
        let firstNote = under + Double(3 + extra) * lead
        // Floored by hand, as `roomLines` does (this engine does not link `floor`).
        let rows = (bottomY - firstNote) / lead + 1e-9
        let whole = Int(rows)
        let room = (Double(whole) > rows ? whole - 1 : whole) + 1
        if room < 1 { return (area, targetFirst) }
        if room < notes {
            let chunk = entries[0]
            queue.insert(QueuedNote(remaining: Array(chunk.dropFirst(1 + room)),
                                    needsContinuedMarker: true), at: 0)
            entries[0] = Array(chunk.prefix(1 + room))
            running = true
        }
        closedUnderText = true
        return (renderArea(entries, extraBlank: extra == 1), under)
    }

    /// Lines still queued, for the post-loop progress guard.
    var queuedLineCount: Int { queue.reduce(0) { $0 + $1.remaining.count } }
}

/// The true-end-of-document endnote listing, no heading, no separator: one blank line between
/// entries (the same vertical rhythm as the footnote area), nothing before the first. The
/// paginator places it after the last page (`layoutPrintedPages`). `[]` for a document with
/// no endnotes. Port of Python's `_endnote_lines`.
func endnoteSectionLines(_ doc: Document, padCols: Int?, width: Int,
                         sentenceSpacing: Bool) -> [PageLine] {
    var lines: [PageLine] = []
    let endnotes = doc.notes.enumerated().filter { $0.element.kind == .endnote }
    for (i, entry) in endnotes.enumerated() {
        if i > 0 { lines.append([]) }
        lines.append(contentsOf: endnoteEntryLines(entry.element, doc: doc,
                                                   index: entry.offset, width: width,
                                                   padCols: padCols,
                                                   sentenceSpacing: sentenceSpacing))
    }
    return lines
}
