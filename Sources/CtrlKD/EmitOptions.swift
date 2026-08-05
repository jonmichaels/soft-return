/// Caller-supplied emitter options — the Swift answer to Python's `**options`
/// (emit.py:58, 108, 156, 208).
///
/// Python lets a caller pass any keyword to any emitter: `emit_html` reads `title`, and the
/// other three swallow everything into `**_options` and ignore it. That is what lets a
/// third-party emitter take options the library has never heard of, and it costs the
/// built-ins nothing — an unknown keyword is silently accepted, which is exactly what
/// `test_emitters_accept_unknown_options` pins.
///
/// Swift has no `**kwargs`, and both obvious substitutes are worse than a struct: a
/// `[String: Any]` dictionary discards the type of every value and would put a hole in the
/// library's `Sendable` story, while a per-emitter options protocol forces the caller to
/// pick a concrete type before it knows which emitter it is calling — precisely the thing
/// `convert(to:)` exists to avoid. So: one struct, handed to every emitter, each emitter
/// reading the fields that mean something to it and ignoring the rest.
///
/// What this deliberately drops is Python's *unknown* keyword: a Swift caller cannot pass
/// `frob: 1` to `emitText`, and shouldn't want to. An emitter needing options of its own
/// closes over them at registration time (see `EmitterRegistry.register`) rather than
/// smuggling them through here.
public struct EmitOptions: Hashable, Sendable {
    /// Goes in `<title>`, escaped. Read by `emitHTML`; the other three built-ins ignore it,
    /// exactly as in Python (emit.py:156 takes `title=''`, its three siblings do not).
    public var title: String

    /// Which of the four WordStar note kinds (footnote/endnote/annotation/comment) a flat
    /// emitter should render — both the trailing note-list entry AND its inline reference
    /// marker (ctrl-kd 1.2.0's `notes=` parameter, mirrored here as a `Set` rather than a
    /// Python-style iterable of strings because `NoteKind` is already the closed, typed
    /// vocabulary a set naturally expresses).
    ///
    /// Excluding a kind removes its inline marker too, not just the trailing entry — a
    /// caller opting out of comments (the default) never sees a `[^c1]`/`<sup>` for one
    /// either. `defaultNotes`/`allNotes`/`noNotes` below are the three settings the vectors
    /// exercise; nothing stops a caller passing any other subset (`[.footnote]` alone, say).
    public var notes: Set<NoteKind>

    /// Footnotes, endnotes, and annotations — never comments. WordStar itself never
    /// printed a comment (they're editorial, author-facing), so this is what a plain
    /// `EmitOptions()` gets.
    public static let defaultNotes: Set<NoteKind> = [.footnote, .endnote, .annotation]
    /// All four kinds, comments included — the opt-in.
    public static let allNotes: Set<NoteKind> = [.footnote, .endnote, .annotation, .comment]
    /// No notes at all: every inline marker and every trailing entry disappears.
    public static let noNotes: Set<NoteKind> = []

    /// Whether to pass the document's own paragraph styles through to formats that can
    /// carry them: HTML gets a `.ws-<slot>-<slug>` class per styled block plus generated
    /// CSS, RTF gets a real `\stylesheet` group and `\sN` on styled paragraphs (ctrl-kd's
    /// `styles=` parameter and `--no-styles`). Default on.
    ///
    /// The rule behind it (Jon, 2026-08-04): never hardwire a style NAME to a font or a
    /// size. Every property emitted comes from the entry's own 102-byte record, so a
    /// consumer can attach its own typography downstream.
    public var styles: Bool

    /// Which importer the RTF `\fonttbl` names are chosen for (ctrl-kd's `fonts_target=`
    /// and `--fonts`). Read by `emitRTF` alone: the HTML stack carries the era name and
    /// every alternate, so it needs no target, and the flat formats carry no font at all.
    ///
    /// Default `.office` because it is the widest single answer — Word AND Google Docs
    /// both resolve the Microsoft names (Jon's ruling, 2026-08-04 night).
    public var fontsTarget: FontsTarget

    public init(title: String = "", notes: Set<NoteKind> = EmitOptions.defaultNotes,
                styles: Bool = true, fontsTarget: FontsTarget = .office) {
        self.title = title
        self.notes = notes
        self.styles = styles
        self.fontsTarget = fontsTarget
    }
}
