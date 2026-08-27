/// The Modern layout model — the semantic flow every Modern renderer shares. Port of
/// `layout.py` (task #15), whose module docstring is the CONTRACT and is carried here
/// verbatim:
///
/// This module is the PUBLIC face of the M-rules (the 2026-08-06 Modern review rulings):
/// alignment tags strip the spaces that implemented them, block `.lm`/`.rm` margins
/// indent and narrow the measure, only the author's blank lines make space, running
/// heads replay, footnotes ride their lines while endnotes/annotations/comments collect
/// at the end, print-control display strings are screen-only, and driver character
/// substitutions are content.
///
/// Three consumers, one model (ruled 2026-08-06, "the point is not to reimplement
/// everything"):
///   - `PDFModernLayout.swift` measures these items into points and paints them;
///   - Soft Return.app measures them through the native macOS text stack;
///   - the `layout` emitter (below) serializes them as JSON so a viewer in ANY language
///     can render a WordStar file without linking either engine — and so the two
///     engines' layout output is parity-testable as data.
///
/// The items are deliberately plain (dicts, lists, strings, numbers): no class
/// instances, nothing that doesn't survive json.dumps. Measurements are absent by
/// design — a paragraph's `indent_cols` is in WordStar print columns, and each consumer
/// converts with its own metrics.
///
/// ## The item contract (format 1)
///
/// modern_flow() returns {'items': [...], 'notes': [...]}.
///
/// Each item is a dict with a 'kind':
///   para            a logical line to wrap: 'align' ('left'|'center'|'right'|
///                   'justify'), 'indent_cols'/'cut_cols' (the block's .lm and
///                   its .rm shortfall from the 65-column line, in columns),
///                   'runs' (below), 'footnotes' (list of [note_index, label]
///                   whose text belongs at the bottom of whatever page this
///                   line lands on)
///   blank           one blank line (the author's own)
///   break           a forced page break (.pa)
///   cond            conditional break: 'lines' remaining or break (.cp n)
///   hf              running-head change: 'which' ('H'|'F'), 'line' (1-based
///                   slot), 'text' (raw — consumers pass it through hf_runs
///                   for toggle bytes, and replace '#' with the page number)
///   tabs            ruler tab stops changed: 'stops' (10-CPI columns). Tab
///                   stops are editor-time state (they bake type-9 positions
///                   at the keyboard) and change no rendered byte; carried for
///                   Show Invisibles and editors. Absent until the first
///                   change; None stops = back to the ruler default.
///   note-separator  the 20-dash rule opening the end-notes section
///   note            one end-matter note: 'index' (into notes), 'note_kind'
///                   ('endnote'|'annotation'|'comment' -- which kind this
///                   particular note is, needed by a consumer choosing an
///                   entry format per kind), 'label', 'text' — endnotes/
///                   annotations/comments, document order
///
/// A run is {'text': str, 'styles': [sorted tags]}, or a reference mark
/// {'text': shown_label, 'styles': [...], 'ref': note_index, 'note_kind':
/// kind}. Runs preserve span boundaries; they never merge. A reference mark
/// whose 'text' is '' (a kept comment under the default `word` scheme, round
/// 22) is a
/// ZERO-WIDTH ANCHOR: it renders no ink anywhere, but carries the note's
/// true inline position -- the same spot the RTF/HTML exports anchor their
/// comment destinations at -- for Show Invisibles and other position-aware
/// consumers.
///
/// 'note_kind' (register b32-P1, additive, no version bump, mirrored from ctrl-kd
/// 314580b) is the SAME value the referenced entry in `notes[ref]['kind']` already
/// carries -- redundant on purpose: the end-matter 'note' item (above) has always
/// carried its own 'note_kind' directly rather than making a consumer look it up by
/// 'index', and an inline reference mark used to be the one place in this contract that
/// broke that symmetry, forcing a `notes[ref]['kind']` indirection a viewer in another
/// language has to know to perform.
///
/// notes is [{'kind', 'label', 'shown', 'text', 'origin'}] for every note the
/// call kept, in document order — 'label' is the kind's own display number
/// (what a page-bottom footnote shows), 'shown' the reference-mark text under
/// the requested `note_refs` scheme.
///
/// In Swift the items are typed (`SemanticItem` et al.) rather than dictionaries — the
/// JSON emitter converts them to exactly the shapes above, and the styles list is
/// derived from `Style`/`font`/`colour` at serialization time so the tags match
/// Python's (`b`, `i`, `u`, `sup`, `sub`, `strike`, `fnref`, `altfont`, `fontN`,
/// `colourN`, `pctlN`).

/// The era line: 65 columns at 10 CPI is the full measure every `.rm` is read against
/// (same constant printed layout wraps at). Python's `layout.FULL_COLS`.
let fullCols = 65

/// A number as Python carries it — int or float — because the layout JSON's byte-parity
/// contract includes Python's own numeric spelling: a paragraph style's margin is an int
/// (`round(hmi / 180)`, prints "7"), a `.lm`/`.rm` dot command's is a float (parsed via
/// `float()`, prints "7.0"), and `b.left_margin or 0` collapses an absent or zero margin
/// to the int 0 ("0", never "0.0"). One Double value, one bit of Python typing.
public struct PyNumber: Hashable, Sendable {
    public var value: Double
    /// True = a Python float ("7.0"); false = a Python int ("7").
    public var isFloat: Bool

    public init(value: Double, isFloat: Bool) {
        self.value = value
        self.isFloat = isFloat
    }

    public static func int(_ v: Int) -> PyNumber { PyNumber(value: Double(v), isFloat: false) }
    public static func float(_ v: Double) -> PyNumber { PyNumber(value: v, isFloat: true) }
}

/// Python's `lm = b.left_margin or 0`, with the type each branch carries there: absent
/// or zero -> the int 0; a style-HMI margin -> int; a dot-command margin -> float.
func pyIndentCols(_ block: Block) -> PyNumber {
    guard let lm = block.leftMargin, lm != 0 else { return .int(0) }
    return block.leftMarginPyInt ? .int(Int(lm)) : .float(lm)
}

/// Right-indent WIDTH in columns for a WordStar `.rm` column position (or an equivalent
/// right-margin column count derived from a style table's own `rightMarginHMI`): `.rm`
/// records the column POSITION where the right margin FALLS -- the same absolute frame
/// `.lm`/`.po` share (`Block`'s own left-margin-normalization doctrine) -- not an indent
/// width. The indent actually visible on the page is whatever remains of the `fullCols`
/// -wide measure once that position is subtracted, floored at 0 so a wider-than-default
/// (or garbage >65) `.rm` never produces a NEGATIVE indent. `rm` 0 (no `.rm` ever seen)
/// means no indent at all. Port of `layout.rm_indent_cols` (register b32) -- the ONE
/// shared implementation so RTF/HTML's per-style and per-block right margin (`EmitRTF`,
/// `EmitHTML`) never reimplement the wrong (rm-as-width) assumption a second time.
func rmIndentCols(_ rm: Double) -> Double {
    rm != 0 ? max(0, Double(fullCols) - rm) : 0
}

/// Python's `cut = max(0, FULL_COLS - rm) if rm else 0`: an unset or zero `.rm` and a
/// full-or-wider measure both yield the INT 0 (Python's `max(0, ...)` keeps the first
/// argument on a tie); a real shortfall keeps the margin's own int/float type.
func pyCutCols(_ block: Block) -> PyNumber {
    guard let rm = block.rightMargin, rm != 0 else { return .int(0) }
    let cut = rmIndentCols(rm)
    if cut <= 0 { return .int(0) }
    return block.rightMarginPyInt ? .int(Int(cut)) : .float(cut)
}

// ---------------------------------------------------------- structure rules
//
// The three GENERIC Modern structure rules (Jon's field notes, 2026-08-13):
// def-list/hanging-indent, nested hierarchy (the same mechanism applied recursively),
// and centered lines -- detected from a paragraph's own column geometry, never keyed
// to a specific file (same "content-based, never extension-based" spirit as the
// parser's own format detection). Port of `layout.classify_rows` and its helpers.
//
// A definition-list label is a run's own first word glued to its description by 2+
// spaces -- WordStar has no def-list markup, so a human author signals "this word IS
// the label" the only way the era's plain text allows: padding it out to a shared
// description column with spaces. One label alone is already unambiguous
// (EXTENDING.md-style: `word.py: does the thing`); no repetition is required to trust
// it, unlike a bullet marker below.
//
// The label must itself end in a colon. Found the hard way against the Sawyer WS7
// archive's own prose corpus (OLDTIMES.WS): the era's own double-space-after-a-period
// typing convention means a short opening sentence -- dialogue like `"Right.  When the
// historical person...` -- is column-for-column indistinguishable from a real label if
// a bare gap is all that's required. A colon is the one punctuation mark whose job in
// English IS introducing a label (a dictionary entry, `key: value` in code); a
// period/`!`/`?` ends a SENTENCE instead, never a label, so requiring it filters out
// every prose false positive found while keeping every genuine label in both real
// fixtures (`WS.EXE:`, `C:\WS\DEFAULT:`).

/// 'bullet' | 'def' structure kind for one classified Modern row. Port of
/// `layout.classify_rows`' `r['kind']`.
public enum RowStructureKind: String, Hashable, Sendable {
    case bullet
    case def
}

/// 'tag' | 'spaces' -- how a centered row was detected. Port of `layout.classify_rows`'
/// `r['center_via']`.
public enum CenterVia: String, Hashable, Sendable {
    case tag
    case spaces
}

/// Structure classification for one row -- the additive subset `modern_flow` attaches
/// to a `para` item as `structure`, and the HTML emitter's own list builder consumes
/// directly. Port of `layout.classify_rows`' exposed per-row dict.
public struct RowStructure: Hashable, Sendable {
    /// The absolute column this row's visible text starts at (indent_cols + this row's
    /// own residual leading spaces). Python-typed: int + int stays int, a float
    /// indent_cols makes a float col — the layout JSON spells it the same way.
    public var col: PyNumber
    /// Nesting depth: 1 = an outermost list item; 0 = this row opens no container of
    /// its own, though it may still sit visually inside one.
    public var level: Int
    public var kind: RowStructureKind?
    /// The bullet glyph, `kind == .bullet` only.
    public var marker: String?
    /// The def-list label and its description, `kind == .def` only.
    public var label: String?
    public var body: String?
    /// True if this row reads as a centered line.
    public var centered: Bool
    public var centerVia: CenterVia?
    /// The line with alignment padding stripped, when centered.
    public var centerText: String?

    public init(col: PyNumber, level: Int, kind: RowStructureKind? = nil, marker: String? = nil,
               label: String? = nil, body: String? = nil, centered: Bool = false,
               centerVia: CenterVia? = nil, centerText: String? = nil) {
        self.col = col
        self.level = level
        self.kind = kind
        self.marker = marker
        self.label = label
        self.body = body
        self.centered = centered
        self.centerVia = centerVia
        self.centerText = centerText
    }
}

/// One row of `classifyRows`' input, in document order: a candidate paragraph row (its
/// column geometry and text), or a hard break that resets nesting (a heading, page
/// break, or multi-column block). Port of `layout.classify_rows`' `entries` tuples.
public enum StructureEntry: Hashable, Sendable {
    case para(indentCols: PyNumber, cutCols: PyNumber, align: Alignment, text: String)
    case hard
}

/// Matches Python's `_DEFLIST_RE = re.compile(r'^(\S+:)( {2,})(\S.*)$')`: the label is
/// the row's own FIRST whitespace-delimited word, and it must itself end in ':'. Since
/// `\S+` can only span that one contiguous word, the regex's backtracking reduces to a
/// simple rule: match iff the first word's OWN last character is ':', and it is
/// immediately followed by 2+ real spaces and then a non-space character. `\S+` still
/// needs its OWN 1+ characters distinct from the mandatory trailing ':' literal, so the
/// token must be 2+ characters long -- a bare single ':' (token length 1) can only
/// satisfy `\S+` by consuming the colon itself, leaving nothing left to match the
/// required literal ':' that follows, so the regex does NOT match it (confirmed against
/// CPython: `_DEFLIST_RE.match(':  x')` is `None`). REF/-PATCHES.WS has exactly this
/// shape and was misread as a def-list label before this `i > 1` fix (was `i > 0`).
private func deflistMatch(_ chars: [Character]) -> (label: String, body: String)? {
    var i = 0
    while i < chars.count, chars[i] != " " { i += 1 }
    guard i > 1, chars[i - 1] == ":" else { return nil }
    var j = i
    while j < chars.count, chars[j] == " " { j += 1 }
    guard j - i >= 2, j < chars.count, chars[j] != " " else { return nil }
    return (String(chars[0..<i]), String(chars[j...]))
}

/// Bullet markers are discovered, never assumed: a single leading non-alnum glyph
/// immediately followed by one space and real text, repeated at the SAME column at
/// least twice, is this document's own evidence that the glyph is a marker -- one
/// occurrence alone can't be told apart from ordinary punctuation starting a sentence.
/// The glyph must not recur later in its OWN body text either: an ASCII table's
/// box-drawing border (│) repeats down the left edge exactly like a bullet would, but
/// it also reappears as the column separator further into the same row -- a real
/// bullet is spent the moment it's used, never showing up again in its own item's text
/// (found against BOXES.WS's own box-table rows in the Sawyer WS7 archive). Port of
/// `layout.classify_rows`' `_marker_candidate`.
private func isMarkerCandidate(_ chars: [Character]) -> Bool {
    guard chars.count >= 3, chars[1] == " ", chars[2] != " " else { return false }
    let c0 = chars[0]
    guard c0 != " ", !(c0.isLetter || c0.isNumber) else { return false }
    return !chars[2...].contains(c0)
}

private struct ColMarkerKey: Hashable {
    var col: Double
    var ch: Character
}

/// Non-overlapping runs of 3+ spaces in `chars`, matching Python's
/// `len(re.findall(r' {3,}', content))`.
private func wideGapCount(_ chars: [Character]) -> Int {
    var count = 0
    var i = 0
    while i < chars.count {
        if chars[i] == " " {
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            if j - i >= 3 { count += 1 }
            i = j
        } else {
            i += 1
        }
    }
    return count
}

/// Python's `str.strip(' ')`: only the space character, both ends.
private func stripSpaces(_ chars: [Character]) -> [Character] {
    var start = 0
    while start < chars.count, chars[start] == " " { start += 1 }
    var end = chars.count
    while end > start, chars[end - 1] == " " { end -= 1 }
    return Array(chars[start..<end])
}

private struct WorkingRow {
    var indentCols: PyNumber
    var cutCols: PyNumber
    var align: Alignment
    var lead: Int
    var col: PyNumber
    var text: [Character]        // lead-stripped
    var raw: [Character]         // original, untouched
    var kind: RowStructureKind?
    var marker: String?
    var label: String?
    var body: String?
    var level: Int = 0
    var centered: Bool = false
    var centerVia: CenterVia?
    var centerText: String?
}

/// Structure classification for a sequence of rows, one call per document (bullet-marker
/// discovery and nesting both need the WHOLE row order, not one paragraph in isolation).
/// A row with no matching structure keeps `kind == nil`; callers render it exactly as
/// before (this function only ever ADDS classification, it never rejects or reshapes a
/// row that doesn't match one of the rules). Port of `layout.classify_rows`.
public func classifyRows(_ entries: [StructureEntry]) -> [RowStructure?] {
    var rows: [WorkingRow?] = entries.map { e in
        guard case .para(let indentCols, let cutCols, let align, let text) = e else {
            return nil
        }
        let chars = Array(text)
        var lead = 0
        while lead < chars.count, chars[lead] == " " { lead += 1 }
        // Python: `'col': indent_cols + lead` — int + int stays int, float propagates
        let col = PyNumber(value: indentCols.value + Double(lead),
                           isFloat: indentCols.isFloat)
        return WorkingRow(indentCols: indentCols, cutCols: cutCols, align: align, lead: lead,
                          col: col, text: Array(chars[lead...]), raw: chars,
                          kind: nil, marker: nil, label: nil, body: nil)
    }

    var counts: [ColMarkerKey: Int] = [:]
    for row in rows {
        guard let row, isMarkerCandidate(row.text) else { continue }
        // keyed by VALUE, matching Python's dict where the int 5 and the float 5.0
        // are the same key
        counts[ColMarkerKey(col: row.col.value, ch: row.text[0]), default: 0] += 1
    }
    let bulletCols = Set(counts.filter { $0.value >= 2 }.keys)

    for i in rows.indices {
        guard var row = rows[i] else { continue }
        let isBullet = isMarkerCandidate(row.text)
            && bulletCols.contains(ColMarkerKey(col: row.col.value, ch: row.text[0]))
        if isBullet {
            row.kind = .bullet
            row.marker = String(row.text[0])
            row.label = nil
            row.body = String(row.text[2...])
        } else if let m = deflistMatch(row.text) {
            row.kind = .def
            row.marker = nil
            row.label = m.label
            row.body = m.body
        } else {
            row.kind = nil
            row.marker = nil
            row.label = nil
            row.body = nil
        }
        rows[i] = row
    }

    // The document's own routine first-line paragraph indent (if it has one): whichever
    // `lead` value shows up on the most otherwise-plain rows. A real WS4-era author who
    // indents every paragraph 5 spaces produces dozens of SHORT paragraphs (dialogue,
    // essay sentences) whose particular length coincidentally lands that same 5-space
    // indent near the middle of THEIR OWN short line too -- found the hard way against
    // OLDTIMES.WS/KINGLEAR.ws and a private-corpus WS4 paper, where treating every symmetric-looking indent
    // as a centered line swept up dozens of ordinary paragraph openers. A deliberately
    // centered line's own padding varies with ITS length (there's no reason it would
    // match the paragraph-indent habit), so excluding the document's own most common
    // indent removes the routine convention while leaving actual per-line centering
    // (whose indent is evidence, not habit) alone. Ties broken by first-encountered,
    // matching Python's `Counter.most_common(1)` (insertion-ordered).
    var bodyIndentOrder: [Int] = []
    var bodyIndentCounts: [Int: Int] = [:]
    for row in rows {
        guard let row, row.kind == nil, row.lead >= 2, !row.text.isEmpty else { continue }
        if bodyIndentCounts[row.lead] == nil { bodyIndentOrder.append(row.lead) }
        bodyIndentCounts[row.lead, default: 0] += 1
    }
    var bodyIndent: Int?
    if let first = bodyIndentOrder.first {
        var best = first
        for lead in bodyIndentOrder where bodyIndentCounts[lead]! > bodyIndentCounts[best]! {
            best = lead
        }
        if bodyIndentCounts[best]! >= 3 { bodyIndent = best }
    }

    // Nesting: a column stack, one entry per open container. A row strictly shallower
    // than the top closes it (and anything shallower still); a row opening a container
    // at the current top's own column is a sibling, not a child. A non-list row never
    // pops OR pushes on its own -- it may sit inside an open container (a note between
    // bullets) without being one itself; only a real dedent, or a hard break, ever
    // closes one.
    var stack: [Double] = []
    for i in entries.indices {
        if case .hard = entries[i] {
            stack = []
            continue
        }
        guard var row = rows[i] else { continue }
        while let top = stack.last, row.col.value < top { stack.removeLast() }
        if row.kind != nil, stack.last != row.col.value {
            stack.append(row.col.value)
        }
        row.level = stack.count
        rows[i] = row
    }

    for i in rows.indices {
        guard var row = rows[i] else { continue }
        let content = stripSpaces(row.raw)
        if content.isEmpty {
            rows[i] = row
            continue
        }
        if row.align == .center {
            // WS5+ centred at editor time (M3): the tag AND the padding both made it
            // into the file. The tag already carries the decision; this just names the
            // mechanism for a caller that wants one uniform 'centered' signal for both.
            row.centered = true
            row.centerVia = .tag
            row.centerText = String(content)
        } else if row.align == .left, wideGapCount(content) < 2 {
            // Undeclared centering: no tag at all, just spaces padding the line so it
            // SITS centred within this row's own printable measure. Symmetric
            // leading/trailing padding (within a little rounding slack -- an odd
            // leftover column rounds toward the left in WordStar's own centering) is
            // the only honest signal; a merely-indented paragraph is never
            // trailing-padded to match, so this can't be confused with an ordinary
            // `.lm`.
            //
            // The wideGapCount guard above: a fixed-width reference table row
            // (YOURWAY.WS's own byte tables) has SEVERAL wide internal gaps from its
            // OWN column alignment, and enough of them coincidentally land close to
            // bisecting the line that this rule mis-fired across dozens of table rows
            // before this guard existed. A genuine centered line carries at most one
            // incidental wide gap (a sentence-ending double-space); 2+ is a column
            // layout, not prose.
            let width = Double(fullCols) - row.indentCols.value - row.cutCols.value
            let slack = width - Double(content.count)
            // A near-full measure leaves almost no room to be off-centre in the first
            // place -- real centering needs enough slack that landing near its middle
            // is actually evidence of intent, not an artifact of the line nearly
            // filling the width either way.
            if row.lead >= 2, row.lead != bodyIndent, slack >= 4 {
                let ideal = slack / 2.0
                if abs(Double(row.lead) - ideal) <= 1.5 {
                    row.centered = true
                    row.centerVia = .spaces
                    row.centerText = String(content)
                }
            }
        }
        rows[i] = row
    }

    return rows.map { row in
        guard let row else { return nil }
        return RowStructure(col: row.col, level: row.level, kind: row.kind, marker: row.marker,
                            label: row.label, body: row.body, centered: row.centered,
                            centerVia: row.centerVia, centerText: row.centerText)
    }
}

/// One text run in a semantic para item. `ref` non-nil marks a note REFERENCE (its text
/// is the shown label); `styles`/`font`/`colour` carry the span's own state, from which
/// the JSON tag list derives.
public struct SemanticRun: Hashable, Sendable {
    public var text: String
    public var styles: Style
    public var font: Int?
    public var colour: Int?
    /// Index into the flow's `notes` rows when this run IS a reference mark.
    public var ref: Int?
    /// The referenced note's own kind (register b32-P1, mirrored from ctrl-kd 314580b),
    /// set alongside `ref` on both the visible mark and the zero-width markless comment
    /// anchor — see the module doc comment's own `note_kind` paragraph. Always equal to
    /// `notes[ref].kind`; carried here too so a consumer never has to perform that
    /// lookup. `nil` whenever `ref` is `nil`.
    public var noteKind: NoteKind?
    /// The pix-placeholder index (`Span.pix`) when this run IS a `[image: NAME]`
    /// placeholder — b24 round 22, so Modern PDF's substitution rule
    /// (`spansPixSubstitution`) can see it. Python carries the same value as a `pixN`
    /// style tag, and `jsonRun` serializes it as exactly that tag (byte parity ruling,
    /// 2026-08-18 — round 22's "structural only, never serialized" stance is inverted).
    public var pix: Int?
    /// A type-9 tab's absolute target and leader byte (`Span.tabHMI`/`tabLeader`) when
    /// this run IS a tab's own padding. Python carries both as `tabhmi<N>`/`tableader<N>`
    /// style tags, which `effective_span_styles` passes straight through into a semantic
    /// run's own sorted style list -- so they belong in this JSON for the same byte-parity
    /// reason `pix` does.
    public var tabHMI: Int?
    public var tabLeader: Int?

    public init(text: String, styles: Style = [], font: Int? = nil, colour: Int? = nil,
                ref: Int? = nil, noteKind: NoteKind? = nil, pix: Int? = nil,
                tabHMI: Int? = nil, tabLeader: Int? = nil) {
        self.text = text
        self.styles = styles
        self.font = font
        self.colour = colour
        self.ref = ref
        self.noteKind = noteKind
        self.pix = pix
        self.tabHMI = tabHMI
        self.tabLeader = tabLeader
    }
}

/// One [note_index, label] footnote attachment on a para item.
public struct SemanticFootnote: Hashable, Sendable {
    public var index: Int
    public var label: String

    public init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

/// One item of the semantic Modern flow — see the module docstring for the contract.
public enum SemanticItem: Hashable, Sendable {
    /// `isVerse` (b24 completion, C1): the SAME classification `EmitRTF`/`EmitHTML`/
    /// `EmitText`/`EmitMarkdown` compute per paragraph unit via `assembleParagraphs`/
    /// `looksLikeVerse` — `unit.count > 1 && (!block.wrap || looksLikeVerse(unit, ...) ||
    /// screenplayBlocks.contains(bi))` — carried here per LINE (this flow's own item
    /// granularity, unchanged) so a measuring consumer can tighten a verse/stanza unit's
    /// internal line spacing WITHOUT re-deriving paragraph units itself (the shared-API
    /// discipline `resolveFont` already established). NOT serialized into the `layout`
    /// JSON emitter (`jsonItem` below) — layout is BYTE PARITY with the Python oracle
    /// (ruled 2026-08-18), and Python carries no such field; this field is
    /// Swift-consumer-only, exactly like measurements are absent from the JSON contract
    /// by design (this file's own module docstring).
    ///
    /// `bi` (b26-modern item 3, ctrl-kd c82b2ff): the source `doc.blocks` index this
    /// line came from -- lets a consumer re-check content-based whole-document
    /// detectors (`detectScreenplayBlocks` and similar) against a single line without
    /// re-deriving block boundaries itself. `PDFModernLayout.swift`'s `modernFlow` is
    /// the one consumer today (the screenplay page-marker/slugline-no-wrap ruling).
    /// Python's real `layout.py` carries this key additively in its own JSON dict
    /// (`'bi': bi`), and the JSON emitter dumps that dict — so the oracle EMITS it and
    /// `jsonItem` below serializes it at the same position (after `footnotes`); the
    /// layout-parity fixtures regenerated from the b26-modern oracle accordingly
    /// (regenerate from the oracle, never freeze the gate against a moved surface).
    case para(align: Alignment, indentCols: PyNumber, cutCols: PyNumber,
              runs: [SemanticRun], footnotes: [SemanticFootnote], structure: RowStructure?,
              isVerse: Bool, bi: Int)
    case blank
    /// b24 round 20 (slate items 5/11, engine half — Modern layout marks): `origin` is
    /// the SAME wire string `AnnotatedLayout.swift`'s own `InkKind.pageBreakOrigin`
    /// already produces (`"\u{0C}"` for a literal form-feed byte, `Block.origin ==
    /// .ff`; `".pa"` for an ordinary `.pa`/DOT_PAGEBREAK dot command) — so the two
    /// engines' layout JSON stays parity-testable as data, not just internally
    /// consistent within this one. `Block.origin` always had the answer (Native's own
    /// `doc.blocks`); `modernSemanticFlow`'s own break item had been dropping it, so a
    /// Modern-view Show Invisibles couldn't tell which kind of break this was.
    case pageBreak(origin: String)
    case cond(lines: Int)
    case hf(which: HFKind, line: Int, text: String)
    case tabs(stops: [Double]?)
    case noteSeparator
    /// `noteKind` (register 2026-08-25 schema-sync debt, closed alongside register
    /// b32-P1/ctrl-kd 314580b): the SAME value `notes[index].kind` already carries --
    /// redundant on purpose, so a consumer choosing an entry format per kind (e.g.
    /// Modern PDF's bracket-vs-parenthesis choice) can read it straight off this item
    /// instead of an `index` indirection. ctrl-kd's own `_modern_flow` (layout.py) has
    /// carried this since 5443c28 -- this port (62ff6f7) missed the field even though it
    /// mirrored the rest of that commit; caught by the layout byte-parity harness once
    /// the fixture was regenerated against ctrl-kd 314580b, which ALSO reads (via item
    /// 5's own inline-ref `note_kind`) from a HEAD carrying 5443c28. Port of Python's
    /// `'note_kind': row['kind']`.
    case note(index: Int, noteKind: NoteKind, label: String, text: String)
}

/// One row of the flow's kept-notes list.
public struct SemanticNoteRow: Hashable, Sendable {
    public var kind: NoteKind
    public var label: String
    public var shown: String
    public var text: String
    public var origin: NoteOrigin

    public init(kind: NoteKind, label: String, shown: String, text: String,
                origin: NoteOrigin) {
        self.kind = kind
        self.label = label
        self.shown = shown
        self.text = text
        self.origin = origin
    }
}

/// What `modernSemanticFlow` returns — Python's `{'items': [...], 'notes': [...]}`.
public struct SemanticFlow: Hashable, Sendable {
    public var items: [SemanticItem]
    public var notes: [SemanticNoteRow]

    public init(items: [SemanticItem], notes: [SemanticNoteRow]) {
        self.items = items
        self.notes = notes
    }
}

/// Endnote display label under the `word` scheme: lowercase roman, Word's own default
/// for `\ftnalt` endnotes (MS-OI29500 §17.11.17: "In Word, the default value for
/// endnote numbering format is lowerRoman") — a page can carry footnote [1] and endnote
/// [i] without collision. Port of `layout.endnote_label`.
public func endnoteRomanLabel(_ label: String) -> String {
    guard let n = Int(label), n > 0 else { return label }
    var remaining = n
    var out = ""
    for (v, s) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                   (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                   (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
        while remaining >= v {
            out += s
            remaining -= v
        }
    }
    return out
}

/// `[refNotes index: reference-mark text]` under the requested scheme (M8). Port of
/// `layout._shown_labels`.
func shownLabels(_ refNotes: [Note], doc: Document, noteRefs: NoteRefs) -> [Int: String] {
    // Modern PDF must NEVER renumber (ruling 2026-08-24 item 1) -- WordStar's own
    // per-page numbers stay exactly as stored here.
    if noteRefs == .prefixed {
        return noteRefLabels(refNotes, labels: annotatedNoteLabels(doc), scheme: .prefixed)
    }
    var shown: [Int: String] = [:]
    var ords: [NoteKind: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        let k = (ords[note.kind] ?? 0) + 1
        ords[note.kind] = k
        let label = noteLabel(note, doc: doc, index: i)
        switch note.kind {
        case .endnote:
            shown[i] = endnoteRomanLabel(label)
        case .comment:
            // self-identifying in the end list either scheme; under `word` there is no
            // inline mark to match anyway
            shown[i] = "c" + String(k)
        default:
            shown[i] = label
        }
    }
    return shown
}

/// The document as the semantic Modern flow — see the module docstring for the item
/// contract. This is the single implementation of the M-rules; measuring consumers
/// (`PDFModernLayout.swift`, the app) convert columns to their own units and wrap at
/// their own measure. Port of `layout.modern_flow`.
public func modernSemanticFlow(_ doc: Document, notes keep: Set<NoteKind> = EmitOptions.defaultNotes,
                               noteRefs: NoteRefs = .word) -> SemanticFlow {
    let refNotes = inlineReferenceNotes(doc)
    let shownByIndex = shownLabels(refNotes, doc: doc, noteRefs: noteRefs)

    // every kept note, in document order, with its indices stable for the
    // 'ref'/'footnotes'/'index' fields below
    var noteRows: [SemanticNoteRow] = []
    var rowIndexByRef: [Int: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        guard keep.contains(note.kind) else { continue }
        rowIndexByRef[i] = noteRows.count
        noteRows.append(SemanticNoteRow(kind: note.kind,
                                        label: noteLabel(note, doc: doc, index: i),
                                        shown: shownByIndex[i] ?? "", text: note.text,
                                        origin: note.origin))
    }

    let lj = doc.printerDriver == "LJ6DTP"
    // b24 completion (C1): the same whole-document context `EmitRTF`/`EmitHTML`/`EmitText`
    // compute for their own `assembleParagraphs`/`isVerse` calls — Modern is never
    // "printed", so `screenplayBlocks` is unconditional (matches those emitters' own
    // `printed ? [] : detectScreenplayBlocks(doc)` since this flow's `printed` is always
    // false).
    let modernMargin = docMargin(doc)
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    let screenplayBlocks = detectScreenplayBlocks(doc)
    var hfByBlock: [Int: [(kind: HFKind, line: Int, text: String)]] = [:]
    for event in doc.hfEvents {
        hfByBlock[event.blockAnchor, default: []].append((event.kind, event.line, event.text))
    }

    var items: [SemanticItem] = []
    var endRows: [Int] = []                 // end-matter note indices, doc order
    var endSeen: Set<Int> = []
    var curTabs: [Double]? = nil            // ruler default until a block differs
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .para, block.tabStops != curTabs {
            items.append(.tabs(stops: block.tabStops))
            curTabs = block.tabStops
        }
        for event in hfByBlock[bi] ?? [] {
            items.append(.hf(which: event.kind, line: event.line, text: event.text))
        }
        if block.kind == .pagebreak {
            // WS4 print-stream form-feed breaks deliberately left without a
            // distinguishing origin tag in the ORIGINAL ctrl-kd finding: a print
            // stream's page breaks are BY DEFINITION always form-feed-sourced, so the
            // field would be constant and non-distinguishing there, unlike the WS5+
            // document path where both a dot command AND a raw form-feed can occur in
            // the same file. This port carries the same wire convention regardless
            // (matches `AnnotatedLayout.swift`'s own `pageBreakOrigin`), since a
            // constant value is harmless where it's non-distinguishing.
            items.append(.pageBreak(origin: block.origin == .ff ? "\u{0C}" : ".pa"))
            continue
        }
        if block.kind == .condpage {
            items.append(.cond(lines: max(1, block.heading)))
            continue
        }
        let lm = pyIndentCols(block)
        // `.rm` narrows the measure from the document's full line; a block at the
        // default 65 cuts nothing
        let cut = pyCutCols(block)
        let mergedBlockLines = mergedLines(block)
        // b24 completion (C1): partition this block's own lines into paragraph units the
        // SAME way `assembleParagraphs(block, ...)` does (it partitions `mergedLines(block)`
        // into contiguous, order-preserving runs — calling the lower-level
        // `assembleParagraphUnits` entry point on the SAME `mergedBlockLines` array this
        // loop already computed avoids a second `mergedLines` pass), then tag each line
        // with its unit's `isVerse` verdict, verbatim `EmitRTF.swift`'s own formula.
        let blockDominant = blockDominantStyles(mergedBlockLines)
        let paragraphUnits = assembleParagraphUnits(mergedBlockLines, margin: modernMargin,
                                                     headPosition: headPosition[bi] ?? false,
                                                     conventionIndent: conventionIndent,
                                                     wrap: block.wrap)
        var lineIsVerse: [Bool] = []
        lineIsVerse.reserveCapacity(mergedBlockLines.count)
        for unit in paragraphUnits {
            let unitIsVerse = unit.count > 1 && (!block.wrap
                || looksLikeVerse(unit, dominantStyles: blockDominant)
                || screenplayBlocks.contains(bi))
            lineIsVerse.append(contentsOf: Array(repeating: unitIsVerse, count: unit.count))
        }
        for (li, line) in mergedBlockLines.enumerated() {
            if line.spans.isEmpty {
                items.append(.blank)
                continue
            }
            var spans = line.spans
            if lm.value != 0 {
                // WordStar stamps `.lm` onto every line it writes; the indent is
                // carried by the item now, so the stamped spaces come off the front
                // (whatever indent remains past `.lm` is the author's own tab and stays)
                var drop = lm.value
                while drop > 0, !spans.isEmpty {
                    let chars = Array(spans[0].text)
                    var take = 0
                    while take < chars.count, Double(take) < drop, chars[take] == " " {
                        take += 1
                    }
                    if take == 0 { break }
                    drop -= Double(take)
                    if take < chars.count {
                        spans[0].text = String(chars[take...])
                        break
                    }
                    spans.removeFirst()
                }
            }
            var runs: [SemanticRun] = []
            var footnotes: [SemanticFootnote] = []
            for span in spans {
                if span.pctlHMI != nil {
                    // a 0x0F print control's display string is SCREEN-ONLY; the paper
                    // got the raw payload. Modern shows nothing — command codes are
                    // invisible (M4, extended M10)
                    continue
                }
                let styles = effectiveSpanStyles(span, block: block, headingBold: true)
                // Register C5: a paragraph style's own declared colour is a default for
                // every span it governs -- Python merges it into the same frozenset the
                // style tags ride in, so it reaches this JSON's own styles list too.
                let colour = effectiveSpanColour(span, block: block)
                if span.styles.contains(.fnref) {
                    guard let n = Int(span.text), n >= 1, n <= refNotes.count else { continue }
                    let note = refNotes[n - 1]
                    guard keep.contains(note.kind), let ni = rowIndexByRef[n - 1] else { continue }
                    let shown = shownByIndex[n - 1] ?? ""
                    if note.kind != .comment || noteRefs == .prefixed {
                        // `word` comments are markless (Word's bubble convention);
                        // `prefixed` shows the c-mark (M9). The span's own font/colour
                        // ride along: Python's fnref span carries the active `fontN`/
                        // `colourN` tags in the same frozenset, so its layout JSON
                        // styles list includes them (byte parity, 2026-08-18).
                        runs.append(SemanticRun(text: shown, styles: styles,
                                                font: span.font, colour: colour,
                                                ref: ni, noteKind: note.kind))
                    } else {
                        // Round 22 (C5, closing the gap LayoutMarksTests documented
                        // round 20): a `word`-scheme comment stays MARKLESS -- but its
                        // inline POSITION is real data (the exports anchor RTF's
                        // \*\annotation / HTML's backlink at exactly this spot, and
                        // Show Invisibles needs a position to draw the comment icon
                        // at). A zero-width run (text: "") carries the anchor without
                        // adding ink: measuring consumers render nothing for it
                        // (PDFModernLayout's `modernFlow` skips empty ref runs
                        // explicitly, keeping Modern PDF bytes unchanged),
                        // position-aware consumers get the true anchor.
                        runs.append(SemanticRun(text: "", styles: styles,
                                                font: span.font, colour: colour,
                                                ref: ni, noteKind: note.kind))
                    }
                    if note.kind == .footnote {
                        footnotes.append(SemanticFootnote(index: ni,
                                                          label: noteLabel(note, doc: doc,
                                                                           index: n - 1)))
                    } else if !endSeen.contains(ni) {
                        endSeen.insert(ni)
                        endRows.append(ni)
                    }
                    continue
                }
                var text = span.text
                if lj, let fontIndex = span.font, fontIndex < doc.fonts.count {
                    // LJ6DTP substitutions are CONTENT, not layout (M7): an em dash is
                    // an em dash in any century, whichever renderer consumes these items
                    let entry = doc.fonts[fontIndex]
                    if entry.proportional {
                        text = ljSubstituteText(text, entry: entry)
                    }
                }
                if !text.isEmpty {
                    runs.append(SemanticRun(text: text, styles: styles, font: span.font,
                                            colour: colour, pix: span.pix,
                                            tabHMI: span.tabHMI,
                                            tabLeader: span.tabLeader))
                }
            }
            if block.align == .center || block.align == .right {
                // WordStar 5+ aligned at EDITOR time — the centering is already in the
                // file as spaces (the WS4 `.oj` DOSBox probe proved the same for
                // justification). The spaces come off and the tag does the work (M3 —
                // no per-document exceptions). Character-level, so a run like
                // '   Title' sheds its leading spaces without losing the word.
                while let first = runs.first, first.ref == nil {
                    let t = String(first.text.drop(while: { $0 == " " }))
                    if !t.isEmpty {
                        if t != first.text { runs[0].text = t }
                        break
                    }
                    runs.removeFirst()
                }
                while let last = runs.last, last.ref == nil {
                    var t = last.text
                    while t.hasSuffix(" ") { t.removeLast() }
                    if !t.isEmpty {
                        if t != last.text { runs[runs.count - 1].text = t }
                        break
                    }
                    runs.removeLast()
                }
            }
            items.append(.para(align: block.align, indentCols: lm, cutCols: cut,
                               runs: runs, footnotes: footnotes, structure: nil,
                               isVerse: lineIsVerse[li], bi: bi))
        }
        // Only the author's own blank lines make space (M4): a block boundary is often
        // just a dot command, and command codes are invisible. `mergedLines` buffered
        // these away; count them back.
        for _ in 0..<trailingBlankLines(block) {
            items.append(.blank)
        }
    }
    if !endRows.isEmpty {
        // Endnotes/annotations/comments at the true end, after the last body line —
        // flowing, not bottom-anchored — behind the same 20-dash separator the
        // page-bottom notes use. No heading: WordStar never printed one.
        items.append(.blank)
        items.append(.noteSeparator)
        for ni in endRows {
            items.append(.note(index: ni, noteKind: noteRows[ni].kind, label: noteRows[ni].shown,
                               text: noteRows[ni].text))
        }
    }

    // Structure classification (M-rules addendum, 2026-08-13): 'blank' and the other
    // carrier items (tabs/hf/note*) are soft -- they carry no column of their own and
    // never interrupt a list; page breaks/conditional breaks are the only genuine hard
    // resets this flow itself produces (headings here are just bold paragraphs, not a
    // distinct item kind).
    var structEntries: [StructureEntry] = []
    var structIdx: [Int] = []
    for (idx, it) in items.enumerated() {
        switch it {
        case .para(let align, let indentCols, let cutCols, let runs, _, _, _, _):
            let text = runs.map(\.text).joined()
            structEntries.append(.para(indentCols: indentCols, cutCols: cutCols, align: align,
                                       text: text))
            structIdx.append(idx)
        case .pageBreak, .cond:
            structEntries.append(.hard)
            structIdx.append(idx)
        default:
            break
        }
    }
    for (idx, s) in zip(structIdx, classifyRows(structEntries)) {
        guard let s else { continue }
        if case .para(let align, let indentCols, let cutCols, let runs, let footnotes, _, let isVerse, let bi) = items[idx] {
            items[idx] = .para(align: align, indentCols: indentCols, cutCols: cutCols, runs: runs,
                               footnotes: footnotes, structure: s, isVerse: isVerse, bi: bi)
        }
    }
    return SemanticFlow(items: items, notes: noteRows)
}

// ---------------------------------------------------------------- JSON

/// A minimal JSON value tree + writer, local to the layout emitter — Foundation stays
/// out of this library. The `layout` format is BYTE parity like every other format
/// (ruled 2026-08-18, "fix it all" — the old compared-as-parsed-data carve-out is
/// abolished): key order, Python's own int-vs-float spelling, `repr(float)` shortest
/// round-trip float spelling, and `json.dumps(..., ensure_ascii=False, indent=1)`'s
/// exact escaping and whitespace all match the Python oracle byte for byte.
indirect enum LayoutJSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LayoutJSONValue])
    /// Ordered key-value pairs — dictionaries would shuffle keys per run.
    case object([(String, LayoutJSONValue)])

    /// A `PyNumber` in its own Python spelling — `.int` prints "7", `.double` "7.0".
    static func py(_ n: PyNumber) -> LayoutJSONValue {
        n.isFloat ? .double(n.value) : .int(Int(n.value))
    }
}

/// Python's `repr(float)`: the shortest round-trip decimal, dressed with CPython's own
/// fixed/scientific switch — fixed notation iff the decimal point lands in (-4, 16]
/// (`repr(1e15)` is "1000000000000000.0" but `repr(1e16)` is "1e+16"; `repr(1e-4)` is
/// "0.0001" but `repr(1e-5)` is "1e-05"), else scientific with a signed 2+ digit
/// exponent and no ".0" on a single-digit mantissa. Swift's `description` computes the
/// same shortest digits but switches notation at different thresholds, so the digits
/// are parsed back out and re-dressed Python's way.
func pythonFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "NaN" }                       // json.dumps' own spellings
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    let neg = d < 0
    var s = String(d.magnitude)                       // shortest round-trip digits
    var exp = 0
    if let e = s.firstIndex(of: "e") {
        exp = Int(s[s.index(after: e)...]) ?? 0
        s = String(s[..<e])
    }
    var digits = s
    if let dot = s.firstIndex(of: ".") {
        exp -= s.distance(from: s.index(after: dot), to: s.endIndex)
        digits.remove(at: dot)
    }
    while digits.count > 1, digits.first == "0" { digits.removeFirst() }
    while digits.count > 1, digits.last == "0" { digits.removeLast(); exp += 1 }
    // value = 0.<digits> * 10^decpt
    let decpt = exp + digits.count
    var out: String
    if -4 < decpt, decpt <= 16 {
        if decpt <= 0 {
            out = "0." + String(repeating: "0", count: -decpt) + digits
        } else if decpt >= digits.count {
            out = digits + String(repeating: "0", count: decpt - digits.count) + ".0"
        } else {
            let idx = digits.index(digits.startIndex, offsetBy: decpt)
            out = String(digits[..<idx]) + "." + String(digits[idx...])
        }
    } else {
        let e = decpt - 1
        let mant = digits.count == 1
            ? digits : String(digits.first!) + "." + String(digits.dropFirst())
        let mag = String(abs(e))
        out = mant + "e" + (e < 0 ? "-" : "+") + (mag.count < 2 ? "0" + mag : mag)
    }
    return neg ? "-" + out : out
}

func jsonEscape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"                 // json.dumps' short escapes:
        case "\u{0C}": out += "\\f"                 // a form-feed break origin is "\f"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)   // ensure_ascii=False
            }
        }
    }
    return out
}

func jsonSerialize(_ value: LayoutJSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent + 1)
    let closePad = String(repeating: " ", count: indent)
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return pythonFloatRepr(d)
    case .string(let s): return "\"" + jsonEscape(s) + "\""
    case .array(let items):
        if items.isEmpty { return "[]" }
        let body = items.map { pad + jsonSerialize($0, indent: indent + 1) }
            .joined(separator: ",\n")
        return "[\n" + body + "\n" + closePad + "]"
    case .object(let pairs):
        if pairs.isEmpty { return "{}" }
        let body = pairs.map { pad + "\"" + jsonEscape($0.0) + "\": "
            + jsonSerialize($0.1, indent: indent + 1) }
            .joined(separator: ",\n")
        return "{\n" + body + "\n" + closePad + "}"
    }
}

/// The Python style-tag list for one span's state — `b`, `i`, `u`, `sup`, `sub`,
/// `strike`, `fnref`, `altfont`, plus `fontN`/`colourN`/`pctlN`/`pixN` for the run
/// fields the Swift IR carries structurally. Sorted, matching Python's `sorted(styles)`.
func pythonStyleTags(_ styles: Style, font: Int? = nil, colour: Int? = nil,
                     pctlHMI: Int? = nil, pix: Int? = nil, pcl: Int? = nil,
                     tabHMI: Int? = nil, tabLeader: Int? = nil) -> [String] {
    var tags: [String] = []
    if styles.contains(.bold) { tags.append("b") }
    if styles.contains(.italic) { tags.append("i") }
    if styles.contains(.underline) { tags.append("u") }
    if styles.contains(.sup) { tags.append("sup") }
    if styles.contains(.sub) { tags.append("sub") }
    if styles.contains(.strike) { tags.append("strike") }
    if styles.contains(.fnref) { tags.append("fnref") }
    if styles.contains(.altFont) { tags.append("altfont") }
    if let font { tags.append("font\(font)") }
    if let colour { tags.append("colour\(colour)") }
    if let pctlHMI { tags.append("pctl\(pctlHMI)") }
    if let pix { tags.append("pix\(pix)") }
    // Register C2: Python tags a print control's raw-PCL payload index in the same
    // frozenset as everything else, so it shows up in the layout JSON's own style list.
    if let pcl { tags.append("pcl\(pcl)") }
    // The tab-positioning fix tags a type-9 tab's own padding span the same way, so it
    // reaches this JSON's style list too -- and, deliberately, keeps that span distinct
    // from typed text it would otherwise coalesce with.
    if let tabHMI { tags.append("tabhmi\(tabHMI)") }
    if let tabLeader { tags.append("tableader\(tabLeader)") }
    return tags.sorted()
}

private func jsonOptString(_ value: String?) -> LayoutJSONValue {
    value.map { .string($0) } ?? .null
}

/// The provenance block of the layout document. Port of `layout._json_meta`.
private func jsonMeta(_ doc: Document) -> LayoutJSONValue {
    .object([
        ("variant", jsonOptString(doc.detection?.variant.rawValue)),
        ("producer", jsonOptString(doc.producer)),
        ("printer_driver", jsonOptString(doc.printerDriver)),
        ("columnar", .bool(doc.columnar)),
        ("encoding", .string("cp437")),
    ])
}

/// `doc.page` as Python's `meta['page']` dict (same keys, same units).
private func jsonPage(_ page: PageGeometry?) -> LayoutJSONValue {
    guard let p = page else { return .null }
    // Key order is Python's own dict insertion order in `core.py`'s `doc.meta['page']`
    // construction — pn/pc lead, text_lines and lh_varies land last (byte parity).
    return .object([
        ("pn_start", .int(p.pnStart)),
        ("pn_source", .string(p.pnSource.rawValue)),
        ("pc_col", p.pcCol.map { LayoutJSONValue.int($0) } ?? .null),
        ("pc_source", .string(p.pcSource.rawValue)),
        ("pl_lines", .double(p.plLines)),
        ("height_in", .double(p.heightIn)),
        ("size_name", .string(p.sizeName)),
        // width is INFERRED from the height (no dot command exists for it); its
        // provenance is therefore the size's provenance
        ("pw_in", .double(p.pwIn)),
        ("size_source", .string(p.sizeSource.rawValue)),
        ("mt_lines", .double(p.mtLines)),
        ("mt_source", .string(p.mtSource.rawValue)),
        ("mb_lines", .double(p.mbLines)),
        ("mb_source", .string(p.mbSource.rawValue)),
        ("po_cols", .double(p.poCols)),
        ("po_source", .string(p.poSource.rawValue)),
        ("hm_lines", .double(p.hmLines)),
        ("hm_source", .string(p.hmSource.rawValue)),
        ("fm_lines", .double(p.fmLines)),
        ("fm_source", .string(p.fmSource.rawValue)),
        ("lh_48", .double(p.lh48)),
        ("lh_source", .string(p.lhSource.rawValue)),
        ("ls", .double(p.ls)),
        ("ls_source", .string(p.lsSource.rawValue)),
        ("cw_120", .double(p.cw120)),
        ("cw_source", .string(p.cwSource.rawValue)),
        ("text_lines", .int(p.textLines)),
        ("lh_varies", .bool(p.lhVaries)),
    ])
}

/// One `Document.fonts` entry as Python's `_font_entry` dict.
private func jsonFont(_ f: FontChange) -> LayoutJSONValue {
    .object([
        ("offset", f.offset >= 0 ? .int(f.offset) : .null),
        ("width_1800", .int(f.width1800)),
        ("height_1440", .int(f.height1440)),
        ("points", .double(f.points)),
        ("cpi", f.cpi.map { LayoutJSONValue.double($0) } ?? .null),
        ("typestyle", .int(f.typestyle)),
        ("proportional", .bool(f.proportional)),
        ("letter_quality", .bool(f.letterQuality)),
        ("symbol_map", .string(f.symbolMap.rawValue)),
        ("generic_style", .string(f.genericStyle.rawValue)),
        ("typestyle_number", .int(f.typestyleNumber)),
        ("typestyle_name", jsonOptString(f.typestyleName)),
    ])
}

private func jsonRun(_ run: SemanticRun) -> LayoutJSONValue {
    var pairs: [(String, LayoutJSONValue)] = [
        ("text", .string(run.text)),
        ("styles", .array(pythonStyleTags(run.styles, font: run.font, colour: run.colour,
                                          pix: run.pix, tabHMI: run.tabHMI,
                                          tabLeader: run.tabLeader)
            .map { .string($0) })),
    ]
    if let ref = run.ref {
        pairs.append(("ref", .int(ref)))
        // register b32-P1 (mirrored from ctrl-kd 314580b): SAME value as
        // `notes[ref].kind`, redundant on purpose -- see `SemanticRun.noteKind`'s doc
        // comment. `run.noteKind` is always set alongside `ref` (`modernSemanticFlow`'s
        // own construction), so this is unconditional whenever `ref` is present.
        if let noteKind = run.noteKind {
            pairs.append(("note_kind", .string(noteKind.rawValue)))
        }
    }
    return .object(pairs)
}

/// The `structure` object attached to a `para` item (M-rules addendum, 2026-08-13) --
/// key order matches Python's, where it is assigned onto the item dict in a LATER pass
/// than the rest of the item's own keys.
private func jsonStructure(_ s: RowStructure) -> LayoutJSONValue {
    .object([
        ("col", .py(s.col)),
        ("level", .int(s.level)),
        ("kind", s.kind.map { LayoutJSONValue.string($0.rawValue) } ?? .null),
        ("marker", jsonOptString(s.marker)),
        ("label", jsonOptString(s.label)),
        ("body", jsonOptString(s.body)),
        ("centered", .bool(s.centered)),
        ("center_via", s.centerVia.map { LayoutJSONValue.string($0.rawValue) } ?? .null),
        ("center_text", jsonOptString(s.centerText)),
    ])
}

private func jsonItem(_ item: SemanticItem) -> LayoutJSONValue {
    switch item {
    case .para(let align, let indentCols, let cutCols, let runs, let footnotes, let structure, _, let bi):
        // `isVerse` (b24 completion, C1) is deliberately NOT a key here — Python's own
        // JSON emitter omits it too, so the ruled layout-JSON surface matches. `bi`
        // (b26-modern item 3, ctrl-kd c82b2ff) IS serialized: Python's layout.py:511
        // carries it in the item dict the JSON emitter dumps, so the oracle emits it —
        // layout is BYTE PARITY with the Python oracle (ruled 2026-08-18), and the
        // fixtures regenerate from the oracle whenever the oracle's surface moves,
        // never freeze against it (b26 port-review correction: an earlier draft
        // omitted `bi` to keep pre-wave fixtures green — that tracks the gate, not
        // the truth).
        var pairs: [(String, LayoutJSONValue)] = [
            ("kind", .string("para")),
            ("align", .string(align.rawValue)),
            ("indent_cols", .py(indentCols)),
            ("cut_cols", .py(cutCols)),
            ("runs", .array(runs.map(jsonRun))),
            ("footnotes", .array(footnotes.map {
                .array([.int($0.index), .string($0.label)])
            })),
            ("bi", .int(bi)),
        ]
        if let structure {
            pairs.append(("structure", jsonStructure(structure)))
        }
        return .object(pairs)
    case .blank:
        return .object([("kind", .string("blank"))])
    case .pageBreak(let origin):
        return .object([("kind", .string("break")), ("origin", .string(origin))])
    case .cond(let lines):
        return .object([("kind", .string("cond")), ("lines", .int(lines))])
    case .hf(let which, let line, let text):
        return .object([
            ("kind", .string("hf")),
            ("which", .string(which == .header ? "H" : "F")),
            ("line", .int(line)),
            ("text", .string(text)),
        ])
    case .tabs(let stops):
        return .object([
            ("kind", .string("tabs")),
            ("stops", stops.map { LayoutJSONValue.array($0.map { .double($0) }) } ?? .null),
        ])
    case .noteSeparator:
        return .object([("kind", .string("note-separator"))])
    case .note(let index, let noteKind, let label, let text):
        return .object([
            ("kind", .string("note")),
            ("index", .int(index)),
            ("note_kind", .string(noteKind.rawValue)),
            ("label", .string(label)),
            ("text", .string(text)),
        ])
    }
}

private func jsonNoteRow(_ row: SemanticNoteRow) -> LayoutJSONValue {
    .object([
        ("kind", .string(row.kind.rawValue)),
        ("label", .string(row.label)),
        ("shown", .string(row.shown)),
        ("text", .string(row.text)),
        ("origin", .string(row.origin.rawValue)),
    ])
}

/// A page's headers/footers dict, keys spelled and ORDERED as Python emits them:
/// `json.dumps` writes dict insertion order, and Python's per-page dict inherits
/// `cur_hdrs`' order — the order each line slot was FIRST set by an `.he`/`.fo` event
/// (later re-sets keep the original position). `order` is that first-set order from
/// `doc.hfEvents`; slots not covered (defensive) follow, sorted.
private func jsonHFDict(_ dict: [Int: String], order: [Int]) -> LayoutJSONValue {
    var keys = order.filter { dict[$0] != nil }
    keys += dict.keys.filter { !order.contains($0) }.sorted()
    return .object(keys.map { (String($0), .string(dict[$0]!)) })
}

/// The `layout` format: the full viewer contract as JSON — semantic Modern flow, printed
/// page-lines, page geometry with provenance, notes, and the invisible layer (dot
/// commands with anchors, running-head events) — so a renderer in any language can draw
/// a WordStar file without linking an engine, and both engines' layout is comparable as
/// data. Format version bumps only on breaking shape changes. Port of
/// `layout.emit_layout`.
@Sendable
public func emitLayout(_ doc: Document, mode: EmitMode = .modern,
                       options: EmitOptions = EmitOptions()) -> String {
    // Python's notes-aware printed paginator returns PLAIN page lists (no Page object),
    // so `getattr(page, 'headers', {})` yields {} for every page on that path — the
    // Swift Page's doc-final headers exist for the PDF driver, not for this JSON.
    let notesPath = hasPlaceableNotes(doc)
    // First-set order of header/footer line slots, for Python's dict insertion order.
    var headerOrder: [Int] = []
    var footerOrder: [Int] = []
    for event in doc.hfEvents {
        if event.kind == .header {
            if !headerOrder.contains(event.line) { headerOrder.append(event.line) }
        } else if !footerOrder.contains(event.line) {
            footerOrder.append(event.line)
        }
    }
    var printedPages: [LayoutJSONValue] = []
    for page in docToPagelines(doc, printed: true) {
        var lines: [LayoutJSONValue] = []
        for pl in page {
            lines.append(.object([
                ("segments", .array(pl.spans.map { span in
                    .object([
                        ("text", .string(span.text)),
                        ("styles", .array(pythonStyleTags(span.styles, font: span.font,
                                                          colour: span.colour,
                                                          pctlHMI: span.pctlHMI,
                                                          pix: span.pix, pcl: span.pcl,
                                                          tabHMI: span.tabHMI,
                                                          tabLeader: span.tabLeader)
                            .map { .string($0) })),
                    ])
                })),
                ("soft", .bool(pl.soft)),
                ("overprint", .bool(pl.overprint)),
                ("lead", pl.lead.map { LayoutJSONValue.double($0) } ?? .null),
            ]))
        }
        // b56040b (PDFLayout: content-free documents keep their own header/footer)
        // made `finalizePages`'s `pages.isEmpty` fallback synthesize a REAL Page whose
        // headers/footers carry the document's own running head — needed so the PDF
        // draws it. But ctrl-kd's OWN equivalent fallback (`pages or [[]]`, pdf.py)
        // returns a bare Python list with no `.headers` attribute at all, so
        // `emit_layout`'s `getattr(page, 'headers', {})` yields `{}` for that page —
        // the exact same duck-typing gap the PDF fix worked around, just unpatched on
        // ctrl-kd's JSON path. `layoutPrintedPagesPlain`'s only page-append site
        // (`closePage`) is gated on `!page.isEmpty`, so a REAL paginated page can never
        // reach here with zero lines — a zero-line page on this branch is therefore
        // always the isEmpty-fallback synthetic one, never a genuine paginated page,
        // and blanking it here (matching notesPath's existing precedent for the same
        // duck-typing gap on ITS branch) keeps this JSON contract byte-comparable to
        // ctrl-kd's, while the PDF driver keeps using the real fallback headers/footers
        // untouched.
        let blankHF = notesPath || page.isEmpty
        printedPages.append(.object([
            ("lines", .array(lines)),
            ("headers", blankHF ? .object([]) : jsonHFDict(page.headers,
                                                             order: headerOrder)),
            ("footers", blankHF ? .object([]) : jsonHFDict(page.footers,
                                                             order: footerOrder)),
        ]))
    }

    let flow = modernSemanticFlow(doc, notes: options.notes, noteRefs: options.noteRefs)
    let out = LayoutJSONValue.object([
        ("format", .string("ctrl-kd-layout")),
        ("version", .int(1)),
        ("meta", jsonMeta(doc)),
        ("page", jsonPage(doc.page)),
        ("fonts", .array(doc.fonts.map(jsonFont))),
        ("modern", .object([
            ("items", .array(flow.items.map(jsonItem))),
            ("notes", .array(flow.notes.map(jsonNoteRow))),
        ])),
        ("printed", .object([("pages", .array(printedPages))])),
        ("invisibles", .object([
            ("dot_commands", .array(doc.dotCommands.map { .string($0) })),
            ("dot_positions", .array(doc.dotPositions.map {
                .array([.int($0.blockIndex), .int($0.lineIndex), .string($0.text)])
            })),
            ("hf_events", .array(doc.hfEvents.map {
                .array([.string($0.kind == .header ? "H" : "F"), .int($0.line),
                        .string($0.text), .int($0.blockAnchor)])
            })),
            ("notes", .array(doc.notes.map {
                .object([
                    ("kind", .string($0.kind.rawValue)),
                    ("text", .string($0.text)),
                    ("origin", .string($0.origin.rawValue)),
                    ("offset", .int($0.offset)),
                ])
            })),
        ])),
    ])
    return jsonSerialize(out) + "\n"
}
