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
/// `doc.notes` once per reference.
func resolveReference(
    _ span: Span, refNotes: [Note], doc: Document, options: EmitOptions
) -> NoteReference {
    guard let n = Int(span.text), n >= 1, n <= refNotes.count else { return .invalid }
    let note = refNotes[n - 1]
    guard options.notes.contains(note.kind) else { return .excluded }
    return .note(note, label: noteLabel(note, doc: doc), index: n - 1)
}

/// The `prefixed` note-reference display labels, keyed by the note's index in `refNotes`
/// (`inlineReferenceNotes(doc)`) — footnotes bare (1, 2, 3), endnotes e1 e2, annotations
/// a1 a2: the SAME labels the Markdown emitter has always written, so a document's
/// reference marks match across every Modern format (ruling 2026-08-06 M8). Under `word`
/// (the default) this returns the stored labels unchanged and each format applies its
/// own Word-standard display on top (arabic footnotes, roman endnotes in the PDF,
/// WordStar tags for annotations). Port of `note_ref_labels`.
func noteRefLabels(_ refNotes: [Note], doc: Document, scheme: NoteRefs) -> [Int: String] {
    var shown: [Int: String] = [:]
    var ords: [NoteKind: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        let k = (ords[note.kind] ?? 0) + 1
        ords[note.kind] = k
        let label = noteLabel(note, doc: doc)
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
/// `note.offset` — the note's own source byte offset — disambiguates two notes that are
/// otherwise field-for-field identical (same kind/text/tag/number): position by CONTENT
/// equality would silently pick the wrong one, position by document ORDER can't.
private func notePosition(_ note: Note, doc: Document) -> Int {
    var count = 0
    for candidate in doc.notes where candidate.kind == note.kind {
        count += 1
        if candidate.offset == note.offset { return count }
    }
    return count   // unreached in practice: `note` always came from `doc.notes` itself
}

/// The 1-based, per-kind display label (task item 2). Footnotes and endnotes number
/// independently (WordStar's separate `.f#`/`.e#`), each against its own start value
/// (defaulting to 1 when the file never set one) plus `Note.number` — the file's own 0-based
/// index, left unmutated — OR, when the file never resolved a real number for this specific
/// note (`number == nil`; WordStar's tag-word high bit marks that case, `SymmetricBlocks.swift`
/// leaves `number` `nil` rather than inventing one), this note's own 0-based rank among its
/// kind. Direct port of `_display_number` (emit.py ~122-145): `index = note.number if
/// note.number is not None else position`, `position` there being this same 0-based rank.
///
/// Annotations carry no number at all in the format; their tag stands in for a label
/// instead — but WordStar's tag field is itself nullable/empty, and Python falls back to the
/// running per-kind counter in exactly that case (`n.tag or str(counters[n.kind])`), not to a
/// blank label. Comments carry neither a number nor a tag and are never referenced inline, so
/// `resolveReference` never reaches that case in practice, but the running counter is still
/// the label a comment gets in its own trailing list (emit.py's uniform `else: str(counter)`).
func noteLabel(_ note: Note, doc: Document) -> String {
    switch note.kind {
    case .footnote:
        let index = note.number ?? (notePosition(note, doc: doc) - 1)
        return String(index + (doc.footnoteNumberStart ?? 1))
    case .endnote:
        let index = note.number ?? (notePosition(note, doc: doc) - 1)
        return String(index + (doc.endnoteNumberStart ?? 1))
    case .annotation:
        if let tag = note.tag, !tag.isEmpty {
            return tag
        }
        return String(notePosition(note, doc: doc))
    case .comment:
        return String(notePosition(note, doc: doc))
    }
}

/// One note as it appears in a kind's trailing list: the note itself, plus its resolved
/// display label (`noteLabel`, uniformly — including a comment's, which `noteLabel` itself
/// now derives from the same per-kind position `NoteListEntry`'s own construction used to
/// compute by hand via `.enumerated()`).
struct NoteListEntry {
    let note: Note
    let label: String
}

/// All notes of one kind, in document order, with their display labels attached — what
/// each emitter's trailing note-list section iterates over.
func noteListEntries(_ doc: Document, kind: NoteKind) -> [NoteListEntry] {
    doc.notes.filter { $0.kind == kind }.map { note in
        NoteListEntry(note: note, label: noteLabel(note, doc: doc))
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
