/// Shared plumbing the four flat emitters (text/markdown/html/rtf) build note rendering
/// on: the fixed section order, the inline-reference lookup and its out-of-range guard,
/// and 1-based per-kind display numbering. Direct port of the note-handling additions in
/// ctrl-kd 1.2.0's four `emit_*` functions — split into one file because the lookup is
/// exactly the same regardless of which format is asking, and four hand-copies is exactly
/// the kind of drift `notes-vectors-1.2.0.json` exists to catch.

/// The fixed order every note-list section renders in, regardless of the order the kinds
/// happen to appear in `doc.notes`: footnotes, then endnotes, then annotations, then
/// comments last (opt-in — WordStar itself never printed them).
let noteKindOrder: [NoteKind] = [.footnote, .endnote, .annotation, .comment]

/// `doc.notes`, in the exact order the parser's shared reference counter numbered them:
/// the Nth (1-based) `fnref`-styled span in document order names the Nth entry here.
/// ALL FOUR kinds emit reference marks since 2026-08-06 (M9) — comments included: the
/// mark is POSITION, not ink (WordStar printed nothing for a comment and printed mode
/// still renders nothing). This list must mirror exactly the kinds the parser numbers
/// with the shared counter, or every reference after a comment resolves to the wrong
/// note. Compute this ONCE per document rather than per span.
func inlineReferenceNotes(_ doc: Document) -> [Note] {
    doc.notes
}

/// What an `fnref`-styled span's sentinel names, resolved against both the document (does
/// a note actually exist at that position?) and the caller's `EmitOptions` (did they ask
/// to see it?).
enum NoteReference {
    /// A real reference to a note whose kind the caller wants rendered. `label` is already
    /// the resolved, 1-based-and-per-kind display string — see `noteLabel`. `index` is the
    /// note's position in `inlineReferenceNotes(doc)` — the stable per-note identity
    /// Python's `id(note)` provides (the `noteRefLabels` map is keyed by it).
    case note(Note, label: String, index: Int)
    /// A real reference, but to a note whose kind is NOT in `options.notes` — render
    /// nothing at all, not even a bare marker (task item 1).
    case excluded
    /// Not actually a reference: the sentinel's sequential count doesn't land inside
    /// `inlineReferenceNotes` — most often a literal `0x07` byte sitting in the body that
    /// was never a footnote sentinel to begin with (task item 3's `stray_sentinel` case).
    /// The caller degrades to plain styled text rather than crash or fabricate a note.
    case invalid
}

/// Resolve one `fnref` span. `refNotes` is `inlineReferenceNotes(doc)`, passed in rather
/// than recomputed per span so a document with many references doesn't refilter
/// `doc.notes` once per reference. `labels` is the document's already-resolved display
/// labels (`annotatedNoteLabels`/`pagelessNoteLabels`, indexed the same as `refNotes`) —
/// the caller decides which of those a format gets, since Printed/Modern PDF/RTF must
/// never renumber (ruling 2026-08-24 item 1) while TXT/MD/HTML do when a kind collides.
func resolveReference(
    _ span: Span, refNotes: [Note], labels: [String], options: EmitOptions
) -> NoteReference {
    guard let n = Int(span.text), n >= 1, n <= refNotes.count else { return .invalid }
    let note = refNotes[n - 1]
    guard options.notes.contains(note.kind) else { return .excluded }
    return .note(note, label: labels[n - 1], index: n - 1)
}

/// The `prefixed` note-reference display labels, keyed by the note's index in `refNotes`
/// (`inlineReferenceNotes(doc)`) — footnotes bare (1, 2, 3), endnotes e1 e2, annotations
/// a1 a2: the SAME labels the Markdown emitter has always written, so a document's
/// reference marks match across every Modern format (ruling 2026-08-06 M8). Under `word`
/// (the default) this returns the stored labels unchanged and each format applies its
/// own Word-standard display on top (arabic footnotes, roman endnotes in the PDF,
/// WordStar tags for annotations). `labels` are the already-resolved display labels
/// (see `resolveReference`'s doc comment) — `note_ref_labels` in Python takes the same
/// resolved `pairs`, not `doc.notes` directly, so a pageless-renumbered label is what a
/// `prefixed` HTML/MD reference shows too. Port of `note_ref_labels`.
func noteRefLabels(_ refNotes: [Note], labels: [String], scheme: NoteRefs) -> [Int: String] {
    var shown: [Int: String] = [:]
    var ords: [NoteKind: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        let k = (ords[note.kind] ?? 0) + 1
        ords[note.kind] = k
        let label = labels[i]
        if scheme == .prefixed {
            switch note.kind {
            case .endnote: shown[i] = "e" + label
            case .annotation: shown[i] = "a" + String(k)
            case .comment: shown[i] = "c" + String(k)
            case .footnote: shown[i] = label
            }
        } else {
            shown[i] = label
        }
    }
    return shown
}

/// This note's 1-based position among ALL of `doc.notes` sharing its `kind`, in document
/// order — the running per-kind counter Python's `_annotated_notes` keeps (`counters[n.kind]`,
/// incremented as it walks `doc.notes`). Used as: an annotation's label when it has no tag
/// (WordStar's tag field is nullable, so an untagged annotation is real input, not just a
/// malformed file — see `noteLabel`), a footnote/endnote's fallback when the file never
/// resolved a real `.number` for it, and a comment's only identity (comments carry neither a
/// number nor a tag).
///
/// Computed from `index` — the note's position in `doc.notes` — which every caller has
/// (a `fnref` span's sequential number, an enumeration of `doc.notes`, or the printed
/// body's own reference cursor). This USED to match the note back into `doc.notes` by
/// `offset`, which collapses under real input: dot-line comments all carry offset 0
/// (their anchor lives in `Document.dotPositions` instead), so every one of them
/// "matched" the first and took label 1 — HP-ENV.LST's own seven comments, found
/// 2026-08-18 chasing layout byte parity under `--comments`. Python's
/// `_annotated_notes` counts positionally (one enumeration pass, per-kind counters);
/// an index is the only identity a value type can carry, so it is threaded through.
private func notePosition(_ note: Note, doc: Document, index: Int) -> Int {
    var count = 0
    for i in 0..<min(index, doc.notes.count) where doc.notes[i].kind == note.kind {
        count += 1
    }
    return count + 1
}

/// The 1-based, per-kind display label (task item 2). Footnotes and endnotes number
/// independently (WordStar's separate `.f#`/`.e#`). The shown number is `Note.number` — the
/// file's own 0-based index, left unmutated — plus one: WS7 folds the `.f#`/`.e#` start value
/// and the per-page restart into the numbers it stores when it paginates and saves (WS7 report
/// 15.1, run fnnum5: a bare `.f# 5` stores 4, 5 on page 1 and 0, 1 on page 2, which print
/// 5., 6. / 1., 2.), so adding the start again numbered them 9., 10. / 5., 6. When the file
/// never resolved a real number for this specific note (`number == nil`; WordStar's tag-word
/// high bit marks that case, `SymmetricBlocks.swift` leaves `number` `nil` rather than
/// inventing one), it is this note's own 0-based rank among its kind plus the recorded start
/// (default 1). Port of `_display_number`.
///
/// A footnote/endnote carrying a user-supplied TAG (ruling 2026-08-24 item 4 — WSFORMAT.TXT's
/// high-bit-on-high-bit nested case, `SymmetricBlocks.swift`'s `parseNote`) displays that mark
/// instead and is never renumbered — the same treatment an annotation's tag already got.
/// UNTESTED AGAINST A REAL DOCUMENT: no archive specimen carries a footnote/endnote tag; this
/// is spec-faithful, synthetic-fixture-verified code only. A plain (untagged) footnote/endnote's
/// numeric label is ALWAYS arabic, whatever `Note.numberFormat` says: WordStar's format spec
/// documents a conversion-flag high nybble (symbols / upper / lower / numbers), but
/// `DISPLAY.WS` — a footnote at numberFormat=2 and an endnote at numberFormat=1 — printed
/// through real WordStar 7 shows plain `1.` and `(1)`. The field stays parsed (preserve what
/// you find) and is not consulted for display. What WS7 DOES follow is the `.f#`/`.e#` letter
/// argument at print time (`.f# a` prints a, b, c; `.f# A` prints A, B, C; WS7 report 15.10):
/// Printed always follows that format; Modern follows it only when no `--note-refs` scheme
/// was given (`noteRefs` nil), since a scheme the caller names wins over the document.
///
/// Annotations carry no number at all in the format; their tag stands in for a label
/// instead — but WordStar's tag field is itself nullable/empty, and Python falls back to the
/// running per-kind counter in exactly that case (`n.tag or str(counters[n.kind])`), not to a
/// blank label. Comments carry neither a number nor a tag and are never referenced inline, so
/// `resolveReference` never reaches that case in practice, but the running counter is still
/// the label a comment gets in its own trailing list (emit.py's uniform `else: str(counter)`).
func noteLabel(_ note: Note, doc: Document, index: Int, printed: Bool = false,
               noteRefs: NoteRefs? = nil) -> String {
    switch note.kind {
    case .footnote:
        if let tag = note.tag { return tag }
        let shown = note.number.map { $0 + 1 }
            ?? (notePosition(note, doc: doc, index: index) - 1 + (doc.footnoteNumberStart ?? 1))
        return formatNoteNumber(
            shown, style: noteNumberStyle(doc, note.kind, printed: printed, noteRefs: noteRefs))
    case .endnote:
        if let tag = note.tag { return tag }
        let shown = note.number.map { $0 + 1 }
            ?? (notePosition(note, doc: doc, index: index) - 1 + (doc.endnoteNumberStart ?? 1))
        return formatNoteNumber(
            shown, style: noteNumberStyle(doc, note.kind, printed: printed, noteRefs: noteRefs))
    case .annotation:
        if let tag = note.tag, !tag.isEmpty {
            return tag
        }
        // Untagged, WS7 prints no mark at all, in the text or before the note (the capture of
        // run ann52, WS7 report 15.1); the other outputs fall back to a running count.
        return printed ? "" : String(notePosition(note, doc: doc, index: index))
    case .comment:
        return String(notePosition(note, doc: doc, index: index))
    }
}

/// 1 -> a, 2 -> b, ..., 26 -> z, 27 -> aa, ... -- bijective base 26, the standard way to keep
/// counting past one alphabet's worth of labels. Port of `_alpha_label`.
func alphaLabel(_ n: Int, upper: Bool) -> String {
    var n = n
    var out: [Character] = []
    let letters = Array(upper ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "abcdefghijklmnopqrstuvwxyz")
    while n > 0 {
        let r = (n - 1) % 26
        out.insert(letters[r], at: 0)
        n = (n - 1) / 26
    }
    return String(out)
}

/// A footnote / endnote's display index: arabic, or letters when the document's `.f#`/`.e#`
/// asked for them and the output is Printed. `n` arrives 1-based. Port of
/// `_format_note_number`.
func formatNoteNumber(_ n: Int, style: NoteNumberStyle?) -> String {
    switch style {
    case .lower: return alphaLabel(n, upper: false)
    case .upper: return alphaLabel(n, upper: true)
    case nil: return String(n)
    }
}

/// The label format the document's `.f#`/`.e#` asked for. Printed always follows it; Modern
/// only when no `--note-refs` scheme was given (`noteRefs` nil). Port of `_note_style`.
func noteNumberStyle(_ doc: Document, _ kind: NoteKind, printed: Bool,
                     noteRefs: NoteRefs? = nil) -> NoteNumberStyle? {
    guard printed || noteRefs == nil else { return nil }
    switch kind {
    case .footnote: return doc.footnoteNumberFormat
    case .endnote: return doc.endnoteNumberFormat
    default: return nil
    }
}

/// Every note's display label, in `doc.notes` order, per WordStar's OWN numbering —
/// used by Printed, Modern PDF and RTF, none of which may ever renumber (ruling
/// 2026-08-24 item 1). The label half of Python's `_annotated_notes`; the pairing
/// itself stays implicit here since every caller already has `doc.notes`/`refNotes` in
/// this same order.
func annotatedNoteLabels(_ doc: Document, printed: Bool = false,
                         noteRefs: NoteRefs? = nil) -> [String] {
    doc.notes.enumerated().map { i, note in
        noteLabel(note, doc: doc, index: i, printed: printed, noteRefs: noteRefs)
    }
}

/// `annotatedNoteLabels(doc)`, with a kind's UNTAGGED footnote/endnote labels renumbered
/// CONTINUOUSLY across the whole document wherever WordStar's own per-page-reset numbers
/// actually COLLIDE (ruling 2026-08-24 item 1: "renumber ONLY when the stored numbers
/// actually collide"). TXT, MD and HTML have no pages — WS7's per-page footnote reset
/// can flatten two different notes onto the same displayed number in a page-less
/// rendering, which is invalid HTML (duplicate ids) and ambiguous prose (TXT/MD).
/// Collision is the trigger, NOT WordStar's own `.F#`/`.E#` "consecutive throughout the
/// document" dot command (REF/WSFORMAT.TXT) — a document already numbering consecutively
/// has no collision and is returned untouched, so `.F#` never needs to be parsed at all.
///
/// A TAGGED note (a user MARK, ruling item 4) never participates in collision detection
/// and is never renumbered, whether or not its own kind collides elsewhere in the
/// document — a mark has no numeric identity to collide or renumber.
///
/// Printed, Modern PDF, and RTF must call `annotatedNoteLabels` directly and NEVER this
/// function — they have real pages (or, for RTF, `\chftn` auto-numbering) and must keep
/// WordStar's own numbers exactly as stored. Port of `_pageless_notes`.
func pagelessNoteLabels(_ doc: Document, printed: Bool = false,
                        noteRefs: NoteRefs? = nil) -> [String] {
    var labels = annotatedNoteLabels(doc, printed: printed, noteRefs: noteRefs)
    for kind in [NoteKind.footnote, .endnote] {
        let members = doc.notes.enumerated().filter { $0.element.kind == kind && $0.element.tag == nil }
        let memberLabels = members.map { labels[$0.offset] }
        guard Set(memberLabels).count != memberLabels.count else { continue }   // no collision
        for (rank, m) in members.enumerated() {
            labels[m.offset] = formatNoteNumber(
                rank + 1, style: noteNumberStyle(doc, kind, printed: printed, noteRefs: noteRefs))
        }
    }
    return labels
}

/// One note as it appears in a kind's trailing list: the note itself, plus its resolved
/// display label — `labels[i]`, the caller's already-resolved per-note label
/// (`annotatedNoteLabels`/`pagelessNoteLabels`), indexed by this note's position in
/// `doc.notes`.
struct NoteListEntry {
    let note: Note
    let label: String
}

/// All notes of one kind, in document order, with their display labels attached — what
/// each emitter's trailing note-list section iterates over. `labels` is indexed exactly
/// like `doc.notes` (see `NoteListEntry`).
func noteListEntries(_ doc: Document, kind: NoteKind, labels: [String]) -> [NoteListEntry] {
    doc.notes.enumerated().filter { $0.element.kind == kind }.map { i, note in
        NoteListEntry(note: note, label: labels[i])
    }
}

/// Sanitize a note's display label (a number, or a WordStar annotation tag string like
/// `"AC1"` — or, from a real file, one containing punctuation the format doesn't forbid) into
/// characters safe as both a Markdown pandoc footnote-label token and an HTML id/URL-fragment.
/// Direct port of `_note_slug` (emit.py ~155-159):
/// `re.sub(r'[^A-Za-z0-9_.-]+', '-', label).strip('-') or '0'` — every maximal run of
/// characters outside `[A-Za-z0-9_.-]` collapses to one hyphen, then leading/trailing hyphens
/// (inserted or literal) are stripped, and an all-invalid/empty label falls back to `"0"`
/// rather than producing a blank id.
///
/// This must run at every point a label becomes an IDENTIFIER (a Markdown `[^key]` token, an
/// HTML `id`/`href` fragment) — never at the point it becomes DISPLAY TEXT, which keeps the
/// raw label (escaped for its own syntax, e.g. `htmlEscape`, but not slugged). Footnote/
/// endnote labels are already plain digits, so slugging is a no-op there; annotation tags are
/// the case that actually needs it — an unslugged tag containing `[`, `]`, `?`, or whitespace
/// breaks a Markdown reference key's own `[...]` syntax and produces an invalid HTML id/href.
func noteSlug(_ label: String) -> String {
    func isSlugSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "-":
            return true
        default:
            return false
        }
    }
    var out = String.UnicodeScalarView()
    var pendingHyphen = false
    for scalar in label.unicodeScalars {
        if isSlugSafe(scalar) {
            if pendingHyphen {
                out.append("-")
                pendingHyphen = false
            }
            out.append(scalar)
        } else {
            // Collapse the whole run to at most one hyphen, added only once a safe
            // character actually follows — a trailing invalid run never gets a hyphen
            // appended at all, which is equivalent to Python's `.strip('-')` removing one
            // it would have inserted at the very end.
            pendingHyphen = true
        }
    }
    var result = String(out)
    while result.hasPrefix("-") { result.removeFirst() }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "0" : result
}

/// The section heading text: "Footnotes", "Endnotes", "Annotations", "Comments". Shared by
/// the text emitter's `Kind:` header and the HTML emitter's `<h2>` (whose
/// `aria-labelledby`/`id` pair is `kind.rawValue + "s-label"` instead — lowercase, and
/// built directly from the enum case rather than from this string).
func noteSectionTitle(_ kind: NoteKind) -> String {
    switch kind {
    case .footnote: return "Footnotes"
    case .endnote: return "Endnotes"
    case .annotation: return "Annotations"
    case .comment: return "Comments"
    }
}
