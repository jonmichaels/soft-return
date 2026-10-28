// The whole-document facts every emitter resolves ONCE before it walks the blocks.
//
// Text, Markdown, HTML, RTF, the Modern semantic flow and the Modern PDF flow each
// opened with the same prelude (`inlineReferenceNotes`, `docMargin`,
// `paragraphLayoutContext`, `detectScreenplayBlocks`, `resolveSentenceSpacing`, and the
// `.ps off` fallback predicate). It lives here now, so a new fact is added in one place
// and a format cannot quietly resolve it differently from its neighbours.

/// Which numbering a format shows for footnotes and endnotes.
enum NoteLabelScheme {
    /// WordStar's own per-page numbers exactly as stored (`annotatedNoteLabels`): the
    /// formats with real pages, and RTF (Word numbers with `\chftn`; it never renumbers).
    case annotated
    /// Continuously renumbered wherever the per-page numbers collide
    /// (`pagelessNoteLabels`): the page-less formats.
    case pageless
}

struct RenderContext {
    /// The Printed facsimile (a physical-line view with real pages) rather than Modern.
    let printed: Bool
    /// Reference notes in document order (`inlineReferenceNotes`).
    let refNotes: [Note]
    /// The document's own left margin in columns.
    let margin: Double
    let conventionIndent: Int
    let headPosition: [Int: Bool]
    /// Screenplay-detected regions. Always empty in Printed: a facsimile already
    /// preserves every line's own position, so detection only matters to Modern reflow.
    let screenplayBlocks: Set<Int>
    /// `resolveSentenceSpacing` for this render, `true` = "single". Only meaningful when
    /// the caller passed the options' mode; a structural user (the semantic flow, which
    /// has no options) gets the Modern default and never reads it.
    let sentenceSpacing: Bool
    /// `.ps off` on a document that declares fonts: Modern body and furniture fall back
    /// to Courier instead of Times. Never in Printed, which keeps its Courier-body
    /// doctrine.
    let nonpropFallback: Bool

    /// The caller's `--note-refs` scheme, nil when none was given (Modern labels then follow
    /// the document's `.f#`/`.e#`).
    let noteRefs: NoteRefs?

    let doc: Document

    init(_ doc: Document, printed: Bool,
         sentenceSpacing mode: EmitOptions.SentenceSpacingMode = .auto,
         noteRefs: NoteRefs? = nil) {
        self.doc = doc
        self.noteRefs = noteRefs
        self.printed = printed
        refNotes = inlineReferenceNotes(doc)
        margin = docMargin(doc)
        (conventionIndent, headPosition) = paragraphLayoutContext(doc)
        screenplayBlocks = printed ? [] : detectScreenplayBlocks(doc)
        sentenceSpacing = resolveSentenceSpacing(mode, printed: printed)
        nonpropFallback = !printed && !doc.fonts.isEmpty && doc.formatting.proportional == false
    }

    /// Every note's display label. The scheme is the FORMAT's choice, passed explicitly
    /// at each site: RTF `.annotated`, HTML and Markdown `.pageless`, text `.annotated`
    /// when printed and `.pageless` otherwise.
    func noteLabels(_ scheme: NoteLabelScheme) -> [String] {
        switch scheme {
        case .annotated: return annotatedNoteLabels(doc, printed: printed, noteRefs: noteRefs)
        case .pageless: return pagelessNoteLabels(doc, printed: printed, noteRefs: noteRefs)
        }
    }
}
