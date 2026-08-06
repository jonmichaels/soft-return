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
/// Replacement page geometry for everything a document does not declare itself — a field
/// is overridden only when the document's own resolved value came from THIS project's
/// built-in default (`Provenance.default`), never when the document's own dot commands
/// set it. Read by `emitPDF` alone (ctrl-kd's `--page-settings`/`page_settings=`; renamed
/// from "page defaults" at every layer, ruling 2026-08-05 — "Page Settings" everywhere,
/// CLI flag, API kwarg, this type, its property on `EmitOptions`, help text, docs).
///
/// This exists because WordStar's stock defaults are not what a given machine printed:
/// WSCHANGE patches them per installation, and a machine's own default-geometry manuscripts
/// print on whatever page ITS patched defaults describe, not WordStar's factory ones. The
/// CLI's `--page-settings` also offers named presets (`default`/`sawyer`/`modern`) that
/// resolve to one of these before it's applied — see `Arguments.swift`'s `pagePresets`.
public struct PageSettings: Hashable, Sendable {
    /// `.mt` replacement, in LINES (6 LPI).
    public var mtLines: Double?
    /// `.mb` replacement, in LINES (6 LPI).
    public var mbLines: Double?
    /// `.po` replacement, in print COLUMNS (10 CPI).
    public var poCols: Double?
    /// `.hm` replacement, in LINES (6 LPI).
    public var hmLines: Double?
    /// `.fm` replacement, in LINES (6 LPI).
    public var fmLines: Double?

    public init(mtLines: Double? = nil, mbLines: Double? = nil, poCols: Double? = nil,
               hmLines: Double? = nil, fmLines: Double? = nil) {
        self.mtLines = mtLines
        self.mbLines = mbLines
        self.poCols = poCols
        self.hmLines = hmLines
        self.fmLines = fmLines
    }
}

/// Note reference-mark display scheme in Modern output (ctrl-kd's `--note-refs`, ruling
/// 2026-08-06 M8). `word` (the default) is the Word standard — arabic footnotes,
/// lowercase-roman endnotes (MS-OI29500 §17.11.17, Word's own documented default),
/// WordStar tags for annotations. `prefixed` shows the Markdown emitter's own labels
/// (footnotes bare 1 2 3, endnotes e1 e2, annotations a1 a2), matched across PDF, RTF,
/// and HTML. Printed output is a facsimile and ignores this.
public enum NoteRefs: String, Hashable, Sendable {
    case word
    case prefixed
}

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

    /// Read by `emitPDF` alone (ctrl-kd's `--page-settings`/`page_settings=`) — see
    /// `PageSettings`. `nil` (the default) applies no override at all.
    public var pageSettings: PageSettings?

    /// Note reference-mark display scheme — see `NoteRefs` (ctrl-kd's `note_refs=`).
    /// Read by the Modern paths of PDF, RTF, and HTML; the flat formats and printed
    /// mode ignore it, exactly as in Python.
    public var noteRefs: NoteRefs

    public init(title: String = "", notes: Set<NoteKind> = EmitOptions.defaultNotes,
                styles: Bool = true, fontsTarget: FontsTarget = .office,
                pageSettings: PageSettings? = nil, noteRefs: NoteRefs = .word) {
        self.title = title
        self.notes = notes
        self.styles = styles
        self.fontsTarget = fontsTarget
        self.pageSettings = pageSettings
        self.noteRefs = noteRefs
    }
}

/// A copy of a document's resolved page geometry with `settings` applied to every field
/// the DOCUMENT did not declare itself (its own `*Source` is `.default`) — the machine
/// layer of the page model: document dot commands > these settings > WordStar factory.
/// Shared by `emitPDF`'s `pageSettings` option and the CLI's `--page-settings` flag (which
/// applies this ONCE to `doc.page`, so every emitter — RTF's page setup included — sees
/// the same effective page). Port of Python's `core.effective_page`.
///
/// Marks each overridden field's source `.file` rather than inventing a third
/// `Provenance` case for "machine-supplied": nothing downstream (this batch's RTF/PDF
/// page-setup gates, nor `--diagnose`) ever needs to tell "the document's own dot
/// command" apart from "a --page-settings override" — both mean "not the built-in
/// default" to every consumer that reads `*Source`, which is the only thing this
/// distinction is FOR. Python's own third string ('machine-default') is never observed by
/// any test either.
public func effectivePage(_ page: PageGeometry, settings: PageSettings) -> PageGeometry {
    var eff = page
    if let mt = settings.mtLines, eff.mtSource == .default {
        eff.mtLines = mt
        eff.mtSource = .file
    }
    if let mb = settings.mbLines, eff.mbSource == .default {
        eff.mbLines = mb
        eff.mbSource = .file
    }
    if let po = settings.poCols, eff.poSource == .default {
        eff.poCols = po
        eff.poSource = .file
    }
    if let hm = settings.hmLines, eff.hmSource == .default {
        eff.hmLines = hm
        eff.hmSource = .file
    }
    if let fm = settings.fmLines, eff.fmSource == .default {
        eff.fmLines = fm
        eff.fmSource = .file
    }
    eff.textLines = textLinesPerPage(pl: eff.plLines, mt: eff.mtLines, mb: eff.mbLines,
                                     lh48: eff.lh48)
    return eff
}
