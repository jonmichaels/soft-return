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
    /// `.pl` replacement, in LINES (6 LPI) — the `--page-settings size=letter|legal|a4`
    /// override for files that declare no page length (the document's own `.pl` always
    /// wins). A size override carries the whole trio: height, name, and width recompute
    /// from the new `.pl` (ruled 2026-08-06, "the 3 main page sizes").
    public var plLines: Double?

    public init(mtLines: Double? = nil, mbLines: Double? = nil, poCols: Double? = nil,
               hmLines: Double? = nil, fmLines: Double? = nil, plLines: Double? = nil) {
        self.mtLines = mtLines
        self.mbLines = mbLines
        self.poCols = poCols
        self.hmLines = hmLines
        self.fmLines = fmLines
        self.plLines = plLines
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

    /// b24 engine wave, round 17 (RULINGS-LEDGER row 1, register B1/B2 + Paged-surface
    /// doctrine point 1): headers, footers, and page numbers in the paged surfaces
    /// (Printed/Native PDF and RTF). Port of ctrl-kd's `--headers {on,off}`/`headers=`.
    /// Default true (ruled flag default, "headers/footers ON"). PDF already rendered
    /// these for Printed before this flag existed (`runningOps` itself is `guard printed`
    /// already) — this only adds the OFF path (pass `[:]`/`[:]`, not `nil`, since
    /// `runningOps` treats `nil` as "fall back to `doc.headers`/`doc.footers`", the
    /// OPPOSITE of what the flag being off means). RTF's `rtfRunningHeads` had no
    /// printed-specific behavior to add; it was simply never called for `printed` before
    /// this round — now called for both, gated by this flag alone.
    public var headers: Bool

    /// b24 engine wave, round 17 (RULINGS-LEDGER row 5/6, register C11): the document's
    /// own `.l#` line-number gutter in the paged surfaces (Printed/Native PDF and RTF).
    /// Port of ctrl-kd's `--line-numbers {on,off}`/`line_numbers=`. Default true — the
    /// flag's job is letting a caller SUPPRESS what the file asked for, not inventing
    /// numbering a silent file never requested (`doc.meta['line_numbering']`/Swift's
    /// equivalent stays `nil` unless the document itself declared `.l#`, regardless of
    /// this flag's value).
    public var lineNumbers: Bool

    /// b24 engine wave, round 18 item 1 (RULINGS-LEDGER row 4): compile the document's
    /// `.tc`/`.ix` entries into a Table of Contents / Index section at the document's own
    /// end, in every format. Port of ctrl-kd's `--toc {on,off}`/`toc=`. Default false (the
    /// ruled default) — a document with no entries produces byte-identical output either
    /// way, since there is nothing to compile.
    public var toc: Bool

    /// b24 engine wave, round 18 item 2 (RULINGS-LEDGER row 10): the author's own inline
    /// (mid-text) colour and font-size changes — WordStar's symmetric type-1 colour block
    /// and a genuinely inline type-2 font block (`FontChange.offset >= 0`, never a style's
    /// own declared size). Port of ctrl-kd's `--inline-styling {on,off}`/`inline_styling=`.
    /// Default true (ruled default — "the author's own styling shows; flag exists to
    /// strip"). Read by `emitRTF`/`emitHTML`; never gates a font's FAMILY switch (document
    /// rendering, not an authored styling choice) nor PDF (LJ6DTP-driver-gated colour only,
    /// with no generic PDF colour path to gate).
    public var inlineStyling: Bool

    /// b24 engine wave, round 19 (RULINGS-LEDGER PIX row, "PIX images RULED IN"): WS5+
    /// `.PIX` image references. Port of ctrl-kd's `--pictures {off,embed,export}`/
    /// `pictures=`. Default `.embed` (Jon's ruled default). `.off`: the plain
    /// `[image: NAME]` placeholder, as before this flag existed. `.embed`: RTF/PDF
    /// native embedding, HTML data URI, MD exports files + a one-line stderr note (MD
    /// has no true embed — the CLI's own job, not this struct's). `.export`: PNG files
    /// beside the output, relative links from HTML/MD; RTF/PDF still embed (no portable
    /// reference mechanism) AND the PNGs are also written.
    public enum PixMode: String, Hashable, Sendable {
        case off
        case embed
        case export
    }
    public var pictures: PixMode

    /// Register b31, E3 item 2 (ruled 2026-08-25, ctrl-kd 6f30157): WordStar's own
    /// AUTOMATIC page number -- the one `.pc` positions, a completely separate
    /// mechanism from a `#` the author placed inside a real `.he`/`.fo` (that always
    /// prints, unaffected by this option -- `runningOps`'s own `render()` substitution
    /// is unconditional). Printed PDF only; Modern has no running heads at all. Port of
    /// ctrl-kd's `--page-numbers {auto,on,off}`/`page_numbers=`.
    ///
    /// `.auto` (DEFAULT): the document's own dot commands decide -- `.pn` (ANY
    /// occurrence) or `.pg` turns it ON, `.op` turns it OFF, exactly like real WordStar
    /// (measured, dosbox-x, 16 probes -- see `pgnumCheckpoints`/`autoPageNumberXPt` in
    /// PDFLayout.swift/PDFWriter.swift for the full ground truth). A document that never
    /// touches any of the four gets no number, byte-identical to before this option
    /// existed (109/110 corpus documents; the ctrl-kd sweep). `.on` forces stock default
    /// numbering (bottom row a footer would use; `.pc` repositions it) even on a silent
    /// document. `.off` suppresses it unconditionally. A declared footer (even with no
    /// `#` of its own) always pre-empts it, in every mode (WSFORMAT.WS's own text:
    /// "active only when the footers are not in use") -- a header does not. `--headers
    /// off`'s own documented scope ("headers, footers, and page numbers") reaches this
    /// too.
    public enum PageNumberMode: String, Hashable, Sendable {
        case auto
        case on
        case off
    }
    public var pageNumbers: PageNumberMode

    /// b33 N9 (Jon's ruling, 2026-08-26, field notes register row, mirrored from
    /// ctrl-kd 0750948): the typewriter double space after a sentence-ending `.`, `?`,
    /// or `!`. Port of ctrl-kd's `--sentence-spacing {auto,keep,single}`/
    /// `sentence_spacing=`, same auto/on/off SHAPE as `pageNumbers` above.
    ///
    /// `.auto` (DEFAULT): follows the EFFECTIVE printed-ness (see
    /// `resolveSentenceSpacing`, Block.swift) — Modern converts a run of 2+ spaces
    /// after a sentence-ender down to exactly one space (the modern typographic
    /// convention); Printed/Native keeps the document exactly as authored (period
    /// fidelity — WordStar itself never touched the author's own spacing). `.keep`/
    /// `.single` force that choice regardless of mode. A deliberately SIMPLE textual
    /// rule, no abbreviation detection (Jon's ruling, "no cleverness"): `"e.g.  x"`
    /// collapses exactly like a genuine sentence end. Applies to body text and all
    /// four note kinds' text, in every format — see `sentenceSpacingTexts`/
    /// `sentenceSpacingSpans` (Block.swift) for the transform itself.
    ///
    /// Markdown has its OWN independent guard (never a trailing double space baked
    /// into a rendered line's own text — CommonMark's hard-break marker) that applies
    /// regardless of this option's value; see `EmitMarkdown.swift`.
    public enum SentenceSpacingMode: String, Hashable, Sendable {
        case auto
        case keep
        case single
    }
    public var sentenceSpacing: SentenceSpacingMode

    /// Resolved/decoded `Document.graphics` entries — the caller's own
    /// `resolveDocumentPictures` output (SoftReturnCLI, which has real filesystem
    /// access; this Foundation-free engine target never resolves anything itself),
    /// reused across every `-t` format for one document. Empty (the default)
    /// reproduces prior output byte-for-byte regardless of `pictures`'s own value —
    /// verified directly, matching ctrl-kd's own
    /// `test_rtf_off_mode_is_byte_identical_to_no_pix_results` pinning.
    public var pixResults: [PixResult]

    /// `{index: relative-path-string}` for `.export` mode's HTML/MD `<img src>`/
    /// `![alt](path)` links — built by the caller (only it knows the output file's own
    /// destination directory) via `writeExportImages`. `nil`/missing falls straight
    /// through to the unchanged placeholder text, never a link to a file that was never
    /// written. Port of ctrl-kd's `image_links=`.
    public var imageLinks: [Int: String]

    public init(title: String = "", notes: Set<NoteKind> = EmitOptions.defaultNotes,
                styles: Bool = true, fontsTarget: FontsTarget = .office,
                pageSettings: PageSettings? = nil, noteRefs: NoteRefs = .word,
                headers: Bool = true, lineNumbers: Bool = true, toc: Bool = false,
                inlineStyling: Bool = true, pictures: PixMode = .embed,
                pageNumbers: PageNumberMode = .auto,
                sentenceSpacing: SentenceSpacingMode = .auto,
                pixResults: [PixResult] = [], imageLinks: [Int: String] = [:]) {
        self.title = title
        self.notes = notes
        self.styles = styles
        self.fontsTarget = fontsTarget
        self.pageSettings = pageSettings
        self.noteRefs = noteRefs
        self.headers = headers
        self.lineNumbers = lineNumbers
        self.toc = toc
        self.inlineStyling = inlineStyling
        self.pictures = pictures
        self.pageNumbers = pageNumbers
        self.sentenceSpacing = sentenceSpacing
        self.pixResults = pixResults
        self.imageLinks = imageLinks
    }
}

/// A copy of a document's resolved page geometry with `settings` applied to every field
/// the DOCUMENT did not declare itself (its own `*Source` is `.default`) — the machine
/// layer of the page model: document dot commands > these settings > WordStar factory.
/// Shared by `emitPDF`'s `pageSettings` option and the CLI's `--page-settings` flag (which
/// applies this ONCE to `doc.page`, so every emitter — RTF's page setup included — sees
/// the same effective page). Port of Python's `core.effective_page`.
///
/// Marks each overridden field's source `.machineDefault` (Python's 'machine-default',
/// core.py:4287). The b26 header rework made the three-state distinction load-bearing:
/// PDFWriter's hm gate subtracts only for a document's OWN `.mt` (`== .file`,
/// pdf.py:2876), while every `!= .default` "declared?" gate still fires for presets —
/// collapsing to `.file` here made the sawyer preset steal the hm subtraction
/// (OLDTIMES page-2 running head 756.2 vs ctrl-kd's 732.2, b26 finding 1).
public func effectivePage(_ page: PageGeometry, settings: PageSettings) -> PageGeometry {
    var eff = page
    if let pl = settings.plLines, eff.sizeSource == .default {
        // a page-size override (--page-settings size=...) carries the whole trio:
        // height, name, width recompute from the new .pl (ruled 2026-08-06)
        eff.plLines = pl
        (eff.heightIn, eff.sizeName, eff.pwIn) = resolvePageSize(pl)
        eff.sizeSource = .machineDefault
    }
    if let mt = settings.mtLines, eff.mtSource == .default {
        eff.mtLines = mt
        eff.mtSource = .machineDefault
    }
    if let mb = settings.mbLines, eff.mbSource == .default {
        eff.mbLines = mb
        eff.mbSource = .machineDefault
    }
    if let po = settings.poCols, eff.poSource == .default {
        eff.poCols = po
        eff.poSource = .machineDefault
    }
    if let hm = settings.hmLines, eff.hmSource == .default {
        eff.hmLines = hm
        eff.hmSource = .machineDefault
    }
    if let fm = settings.fmLines, eff.fmSource == .default {
        eff.fmLines = fm
        eff.fmSource = .machineDefault
    }
    eff.textLines = textLinesPerPage(pl: eff.plLines, mt: eff.mtLines, mb: eff.mbLines,
                                     lh48: eff.lh48)
    return eff
}
