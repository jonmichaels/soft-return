/// The PDF emitter's layout half: IR -> pages of styled, wrapped lines. Port of `pdf.py`'s
/// `_wrap_line`, `_coalesce` and `_doc_to_pagelines` (pdf.py:18-30, 36-122).
///
/// Everything here is pure and independent of PDF syntax — it decides what goes on which
/// page and where the line breaks fall, in characters and line counts, not points. The byte
/// writer (`_page_stream`, `emit_pdf`) attaches to the `[Page]` this produces and is the
/// only part that needs to know what a PDF looks like.
///
/// A WordStar document rendered as the typescript it was: Courier at 10 CPI and 6 LPI on
/// US Letter, which is why a 65-column line is exactly the 6.5 inches between the margins.

/// The page metrics, in PostScript points. Taken verbatim from the Python constants.
///
/// `linesModern` and `maxCols` are DERIVED in Python (pdf.py:23-25) and literal here, per
/// the job spec. `MAX_COLS` is the reason: it reads `int((612 - 144) / (12 * 0.6))`, which
/// is `int(468 / 7.199999999999999)` = `int(65.0000…)` = 65 — the answer survives the float
/// only because the truncation lands on the right side of it. Recomputing that in Swift
/// would be reproducing an accident, so the accident's result is written down instead and
/// the vectors pin it. (Printed mode's own equivalent, `LINES_PRINTED`, existed at Python
/// 1.2.0 but was deleted in 1.3.0 along with the fixed-margin assumption it was derived
/// from — see `printedCap` below.)
public enum PDFMetrics {
    /// US Letter, points.
    public static let pageWidth = 612
    public static let pageHeight = 792
    /// 1 inch.
    public static let margin = 72
    /// 12pt type on 12pt leading — 10 CPI pica by 6 LPI, the dot-matrix standard.
    public static let size = 12
    public static let lead = 12
    /// Top margin. A print stream carries its own top-margin blanks, so it gets the smaller
    /// one and its blanks supply the rest (see the machine-margin rule in `docToPagelines`).
    /// `topPrinted` is also the FIXED fallback `printedTop(_:)` uses for a document with no
    /// page geometry (a bare print-stream capture) — a real WS document's printed top comes
    /// from its own `.mt` instead (default `.mt 3` resolves to exactly this same 36pt).
    public static let topModern = 72
    public static let topPrinted = 36
    /// Lines per page: `(pageHeight - 2 * top) / lead`.
    public static let linesModern = 54
    // Printed-mode capacity is per-document now (`printedCap`, ctrl-kd 1.3.0): WordStar's
    // own vertical model, `.pl - .mt - .mb` at the `.lh` line height — 55 for WordStar's own
    // defaults, not a fixed line count. Python deleted the equivalent `LINES_PRINTED`
    // constant (pdf.py) for the same reason: a single number can no longer stand in for
    // every document's printed page, since the model now reads `.mt`/`.mb`/`.lh` from the
    // file instead of assuming a fixed 72pt printed-mode margin.
    /// Text-column width in characters — WordStar's own margin, arrived at independently.
    public static let maxCols = 65
}

/// One laid-out line: styled segments, wrapped and ready to place, plus the line's own LEAD.
///
/// Spans are the IR's text-plus-styles pair and are exactly what a segment is, so the
/// segments ARE `Span`s and not a second type — the difference is only that a `PageLine`'s
/// spans have been through the wrapper and never contain a line break. This was a plain
/// `[Span]` until the stateful-`.lh` work; it is a collection OF spans now, for the same
/// reason Python's `PageLine` is a `list` subclass rather than a list: the line needs one
/// attribute of its own and every existing use of it is still a use of the sequence.
///
/// `lead` (2026-08-05) is this line's baseline-to-baseline advance in POINTS, or `nil` for
/// "the document's default". It is `Line.lead48` — the `.lh` in force where the line sat —
/// converted once, at the layout boundary, so the writer's loop never has to know about
/// 48ths. Lines this emitter MAKES rather than reads (footnote areas, wrapped Modern text,
/// blank fillers) leave it `nil` by construction: they are the emitter's own furniture and
/// belong on the document's default lead.
public struct PageLine: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
                        ExpressibleByArrayLiteral, Hashable, Sendable {
    public var spans: [Span]
    public var lead: Double?
    /// Bare-CR `^PM` Overprint Line: the NEXT `PageLine` prints at THIS one's own
    /// baseline. `false` by construction for every line this emitter MAKES (footnote
    /// areas, wrapped Modern text, blank fillers) — only a printed-mode body line
    /// carries WordStar's own flag.
    public var overprint: Bool
    /// `Line.soft` carried into the paginated representation (Python `PageLine.soft`,
    /// added 2026-08-03 there; closed here with the layout facade): a soft return is
    /// WordStar's own word wrap — or the filler `.ls > 1` materialises — where a hard
    /// one is the author pressing Return. What Soft Return.app's Show Invisibles needs,
    /// and part of the `layout` JSON contract.
    public var soft: Bool
    /// b24 round 17 (RULINGS-LEDGER row 5/7): this line's own first-line-indent
    /// override in POINTS, or `nil` — `.pm`'s effect (mirrors RTF's `\fi`, round 6), set
    /// ONLY on a `.para` block's own first content line. `.psa`/`.psb` reuse `lead`
    /// itself rather than a new field — WordTsar's space-before/after is exactly one
    /// MORE baseline-to-baseline distance to spend before a line prints, the same
    /// quantity `lead` already carries.
    public var fi: Double?

    /// b24 round 18 (RULINGS-LEDGER row 4): the source Block's own index in
    /// `doc.blocks`, for `tocPageNumbers` to resolve which page a `.tc`/`.ix` entry's
    /// own block landed on — the REAL paginator's answer, not an estimate. `nil` for a
    /// line this emitter MAKES rather than reads (matches `lead`'s own "furniture"
    /// convention). Port of Python's `PageLine.bi`.
    public var bi: Int?

    /// `PageLine.image`'s payload — a named struct rather than a bare tuple because
    /// `PageLine` is `Hashable` and Swift tuples are not.
    public struct ImageRef: Hashable, Sendable {
        public var pixIndex: Int
        public var widthPt: Double
        public var heightPt: Double
        public init(pixIndex: Int, widthPt: Double, heightPt: Double) {
            self.pixIndex = pixIndex
            self.widthPt = widthPt
            self.heightPt = heightPt
        }
    }

    /// b24 round 19 (RULINGS-LEDGER PIX row): set when this PageLine IS a resolved,
    /// embedded picture rather than text — `spans` is empty by construction and
    /// `pageStream` draws the XObject instead of running text ops. `lead` is set to
    /// `heightPt` (+ any `.psb`/`.psa` spacing, same as an ordinary line) so the
    /// existing budget/cost model accounts for the image's vertical footprint with no
    /// change of its own — reusing exactly the mechanism round 17 built for
    /// `.psa`/`.psb`. Port of Python's `PageLine.image`.
    public var image: ImageRef?

    /// `true` for a blank `PageLine` that `ws4SpacingBlankIndices` classified as this
    /// WS4 document's OWN double-spacing idiom rather than authored content — Finding
    /// 1 (b26 visual pass). See that function's doc comment, and
    /// `layoutPrintedPagesPlain`'s own use of this flag for why it matters: a blank
    /// flagged this way never forces a page break BY ITSELF; an authored blank (flag
    /// `false`, every non-WS4 document's blanks included) is untouched, exactly the
    /// previous behaviour. `false` by construction for every line this emitter MAKES
    /// (footnote areas, wrapped Modern text, blank fillers, matching `lead`'s "furniture"
    /// convention) — only a plain-path printed body line ever sets it. Port of Python's
    /// `PageLine.ws4_spacing`.
    public var ws4Spacing: Bool

    /// `Line.kerning`, the `.KR` state in force where this line sat — `true` (WordStar's
    /// own default) for every line this emitter MAKES rather than reads, the same
    /// "furniture" convention `lead`/`bi` follow. Consumed by `ljSubstitute`. Register C7.
    public var kerning: Bool

    /// `left` (register b31): this line's own left-edge override in POINTS, already
    /// resolved (`resolveLeftPt`), or `nil` for "the document's default" — `Line.poCols`
    /// carried through the same `.lh`-shaped stateful contract `lead` above documents for
    /// `.lh`, just for `.po`. Converted here (not at render time) for the same reason
    /// `lead` is: `pageStream`'s layout loop never has to know about print columns. `nil`
    /// by construction for every line this emitter MAKES rather than reads (footnote
    /// areas, wrapped Modern text, blank fillers), the same "furniture" convention `lead`/
    /// `bi` follow.
    public var left: Double?

    /// `roll` (register b32-N10, mirrored from ctrl-kd b48148c): this line's own `.sr`
    /// sub/superscript roll in POINTS, already resolved, or `nil` for "the document's
    /// default" — `Line.roll48` carried through the SAME `.lh`-shaped stateful contract
    /// `lead`/`left` above document, just for `.sr`. Unlike `lead`/`left`, `Line.roll48`
    /// is never itself `nil` (see its own doc comment: no style/font precedence chain to
    /// defer to), so `roll` is `nil` only for a PageLine this emitter MAKES rather than
    /// reads — `pageStream` falls back to the document-wide `rollPt` parameter for those,
    /// exactly as it already does for `left`.
    public var roll: Double?

    public init() {
        spans = []
        lead = nil
        overprint = false
        soft = false
        fi = nil
        bi = nil
        image = nil
        ws4Spacing = false
        kerning = true
        left = nil
        roll = nil
    }

    public init(_ spans: [Span], soft: Bool = false, lead: Double? = nil,
                overprint: Bool = false, fi: Double? = nil, bi: Int? = nil,
                image: ImageRef? = nil, ws4Spacing: Bool = false, kerning: Bool = true,
                left: Double? = nil, roll: Double? = nil) {
        self.spans = spans
        self.soft = soft
        self.lead = lead
        self.overprint = overprint
        self.fi = fi
        self.bi = bi
        self.image = image
        self.ws4Spacing = ws4Spacing
        self.kerning = kerning
        self.left = left
        self.roll = roll
    }

    public init(arrayLiteral elements: Span...) {
        self.init(elements)
    }

    public var startIndex: Int { spans.startIndex }
    public var endIndex: Int { spans.endIndex }

    public subscript(position: Int) -> Span {
        get { spans[position] }
        set { spans[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection>(
        _ subrange: Range<Int>, with newElements: C
    ) where C.Element == Span {
        spans.replaceSubrange(subrange, with: newElements)
    }
}

/// One `.lh` value (1/48in units) as points: a point is 1/72in, so `lh * 1.5`. `nil` or
/// non-positive -> `nil`, meaning "no answer here, use the document's default". Port of
/// `pdf._lead_pt`.
func leadPt(_ lh48: Double?) -> Double? {
    guard let lh48, lh48 > 0 else { return nil }
    return lh48 * 1.5
}

/// The baseline-to-baseline leading a WS7 paragraph STYLE dictates for every physical
/// line in `block` (`Block.lineHeightVMI`/`styleFontPt`, set from the style record's own
/// font/line-height fields — `parseWS`'s style-selection parse). `nil` when no style
/// governs this block, or the style set no line height of its own: the caller falls back
/// to the pre-existing `.lh`/document-default leading UNCHANGED, so a WS4 or otherwise
/// styleless document never shifts.
///
/// vmi == -2 ("auto" — the ONLY value seen on every style in the measured oracle,
/// LYING.WS/LYING.pcl): real WS7 leading is 1.2x the style's own font size, not the
/// document's fixed default — measured 2026-08-20 from PCL decipoint baseline gaps:
/// Title/Author (16pt style) 192 decipoints (19.2pt) apart, Body (12pt) 144 decipoints
/// (14.4pt) apart, and a blank line between a 16pt block and the next 12pt block
/// contributing its OWN 19.2pt of the two lines' combined 336-decipoint (33.6pt) gap — a
/// blank line advances at ITS block's leading, which `styleFontPt` already gives it
/// (block-level, not read off the line's own spans, precisely because a blank line
/// carries no spans/font tag of its own — see `Block.styleFontPt`). Falls back to the
/// document's own printed SIZE (`printedSize`) if the style declared no font of its own
/// (an all-zero/recordless font triple).
///
/// vmi > 0: an EXPLICIT count, in the same 1/1440in VMI unit WSFORMAT.WS documents for a
/// font's own height word ("Font height in VMIs (1/1440ths)") — so vmi/20.0 is points,
/// the identical conversion a font's height word already gets. Evidenced from the format
/// spec's own text, not guessed.
///
/// UPDATE 2026-08-20 (b26 round 26 wave 3, ctrl-kd's `fidelity_gate.py` Unit A): a WS7
/// oracle for a vmi>0 style now DOES exist — WARPRAYR.pcl (ws7-prints/v1), which this
/// docstring previously (wrongly) said was never printed on real WS7. WARPRAYR carries
/// vmi=240 on both its byline (16pt) and its entire body (12pt). The vmi/20.0=12pt formula
/// above is CONFIRMED, not contradicted, for the body: WARPRAYR.pcl's own baseline_gaps_pt
/// run 12.0pt for ~20 consecutive body-paragraph lines, exactly vmi/20 at 12pt font, with
/// zero drift. The ONE anomaly is the byline's OWN baseline, 19.2pt below the title's
/// (78.9 -> 98.1), not the 12pt vmi/20 (or the document default, also 12pt) predicts.
///
/// An EARLIER version of this comment special-cased vmi==240 to behave like -2/auto
/// everywhere (reasoning from the byline anomaly alone, plus 240 being suspiciously
/// identical to WSCHANGE's own "VMI units for line height" factory default, Installing
/// and Customizing p.2-47, DBA2H). That over-generalised: applied to the BODY it made
/// every body line 14.4pt instead of the CONFIRMED 12pt, which does get WARPRAYR to the
/// WS7 page count (3) but at the cost of a much larger positional residual within the
/// page (median jumped from ~2.5pt to 24pt) — fitting the one number the task asked for
/// by breaking twenty it didn't. Reverted, and a margin-COLLAPSING hypothesis (the
/// byline's OWN entry gap borrows the outgoing title block's larger lead, CSS-style) was
/// reported instead of acted on — correctly: it isn't margin collapsing.
///
/// FIX B (b26-print-fidelity-2), the evidence-backed resolution: the byline's vmi
/// (240 = 12pt) is simply too SMALL for its own 16pt font — 12pt leading on 16pt type
/// overlaps ascender-to-descender, so WS7 falls back to the SAME auto formula (1.2x the
/// style's own size, 19.2pt) an unset vmi already gets. The body's vmi=240 on its OWN
/// 12pt font is the negative case that PROVES this doesn't regress: 240/20 = 12.0 >=
/// 12.0, no fallback, the already-CONFIRMED 12.0pt stands untouched. Cross-checked
/// against every OTHER styled document in the corpus before landing: LYING's four
/// styles are all vmi=-2/auto (never reach this branch); OCAPTAIN/TWAINLET carry no
/// paragraph styles at all.
///
/// RESOLVED by Fix C's full block-transition inventory (below, and `enteringLeadPt`):
/// this doc comment's own UPDATE section originally read the byline's 19.2pt as a
/// property of the WHOLE Author block (so this fallback was applied uniformly, per
/// block, to every line). That was ALSO wrong, just less visibly — Author's own
/// trailing BLANK line (the one line inside it besides the byline itself) measures its
/// OWN space at 12.0pt, the UNFALLEN-BACK vmi/20, not 19.2pt. The fallback protects
/// against a REAL line's ascender/descender clipping into the line above — a blank line
/// has no glyphs to clip, so it never needs it: `raw: true` (every BLANK line, and the
/// value a block hands to `enteringLeadPt` as the NEXT block's "outgoing" reference)
/// always returns the unfallen-back vmi/20, regardless of position in the block.
/// `raw: false` (the default, every REAL line, first or not — every EXISTING call site
/// before Fix C only ever rendered a block's OWN first line through this function, so
/// this is the identical behaviour there) keeps the fallback.
///
/// Document-level guard: if the file EVER used a real `.lh` dot command
/// (`doc.page?.lhSource == .file`), a style's own leading is NOT applied at all, even
/// where a line's own `.lh` state happens to equal the document default and so
/// normalises to `nil` — indistinguishable, at the per-line level, from a line that never
/// saw `.lh` in the first place. No corpus evidence exists for how real WS7 arbitrates a
/// style's vmi against an ACTIVE `.lh`, so this stays conservative: an `.lh`-bearing
/// document's leading is left exactly as the pre-existing mechanism computed it,
/// unconditionally. Port of Python's `pdf._style_lead_pt`.
func styleLeadPt(_ block: Block, _ doc: Document, raw: Bool = false) -> Double? {
    guard let vmi = block.lineHeightVMI else { return nil }
    if doc.page?.lhSource == .file { return nil }
    if vmi == -2 {
        // Python: `if not size: size = _printed_size(doc)` -- falsy catches both `None`
        // and a literal 0.0, not just the sentinel's absence.
        var size = block.styleFontPt ?? 0
        if size == 0 { size = Double(printedSize(doc)) }
        return size * 1.2
    }
    if vmi > 0 {
        // Finding B (b26-print-fidelity-2): an explicit vmi too SMALL for the style's
        // own font falls back to the SAME auto formula (1.2x the style's own size) an
        // unset vmi already gets — WARPRAYR's Author style (vmi=240=12pt on a 16pt
        // font; 12pt lead on 16pt type would overlap ascender-to-descender) measures
        // 19.2pt (1.2x16) for its byline's OWN entry gap. The Body style's vmi=240 on
        // its OWN 12pt font is the negative case PROVING vmi/20 remains correct when it
        // fits (240/20 = 12.0 >= 12.0, no fallback) — the already-CONFIRMED 12.0pt body
        // leading (~20 consecutive lines, zero drift), unmoved by this fix.
        //
        // `raw` (Fix C, b26-print-fidelity-2): the fallback above protects a REAL
        // line's ascender/descender from clipping into the line above — a BLANK line
        // has no glyphs to clip, so it never needs it. `raw: true` skips the fallback
        // and returns the unfallen-back vmi/20 always — see `enteringLeadPt`, which is
        // the ONLY caller that ever passes `raw: true` (for the block being LEFT, never
        // the one being entered), and the direct blank-line call sites in
        // `resolvePlainBody`/`resolvePrintedBody`. `raw: false` (the default) is every
        // EXISTING call site's own behaviour, unchanged.
        let pt = Double(vmi) / 20.0
        if let size = block.styleFontPt, !raw, size > 0, pt < size {
            return size * 1.2
        }
        return pt
    }
    return nil
}

/// A block's own FIRST REAL (non-blank) physical line's lead: `styleLeadPt`'s
/// font-relative fallback (Finding B), floored against the block being ENTERED's own
/// natural minimum — Fix C (b26-print-fidelity-2, WARPRAYR.WS). An EXPLICIT (vmi>0)
/// style's first line never sits CLOSER to the preceding content than that content's
/// own RAW lead was — i.e. entering an explicitly, tightly-leaded block never crowds
/// whatever was above it.
///
/// Full block-transition inventory (WARPRAYR.pcl, WS7 frame, blank-line +
/// entering-line combined gaps — a blank line carries no glyph, so only the PAIR is
/// independently measurable):
///     Author(auto,19.2)   -> Body(vmi 240=12, fits)   24.0 = 12.0 + 12.0
///     Body(vmi 240=12)    -> Quote(auto,14.4)  x2      26.4 = 12.0 + 14.4
///     Quote(auto,14.4)    -> Body(vmi 240=12)  x2      28.8 = 14.4 + 14.4
/// Only the Quote -> Body pairs need MORE than `styleLeadPt` alone gives (26.4, Body's
/// own 12.0 entering gap) — WS7 floors Body's own entering gap at Quote's own 14.4
/// instead. Author -> Body does NOT need this floor once Finding B's fallback is
/// correctly scoped to REAL lines only (`raw: true` for Author's OWN blank line,
/// above): Author's raw/exported lead is 12.0 (not its 19.2pt entry fallback), so
/// Body's own entering gap (12.0) is ALREADY >= it, no floor needed — matching the
/// measured 24.0 exactly with no special case.
///
/// Cross-checked against LYING.WS, which is entirely auto styles (no vmi>0 block
/// exists there to test the floor itself) but DOES cover the discriminating case this
/// floor must NOT fire for: Author(auto, 19.2) -> Subtitle(auto, 14.4) measures 33.6 =
/// 19.2 + 14.4 — Subtitle's OWN entering gap, NOT floored up to Author's outgoing 19.2
/// (which would give 38.4, wrong). The floor therefore only applies when the block
/// being ENTERED has an EXPLICIT vmi (this function's own `vmi > 0` guard below) — a
/// genuinely auto style already computes generously relative to its own font and needs
/// no protection against the block before it; this is the ONE rule shape that fits
/// every transition in both measured styled documents, in both directions, with no
/// unexplained gap.
///
/// NOT independently confirmed: a SECOND real (non-blank) line inside a too-small-vmi
/// style also getting the fallback rather than the raw value — no such line exists in
/// the corpus (WARPRAYR's Author block has exactly one real line). Reasoned from the
/// SAME clipping rationale Finding B's own fallback rests on (a real line's
/// ascender/descender doesn't stop clipping just because it isn't the block's first),
/// not from a second measurement. Port of Python's `pdf._entering_lead_pt`.
func enteringLeadPt(_ block: Block, _ doc: Document, prevBlock: Block?) -> Double? {
    guard let own = styleLeadPt(block, doc, raw: false) else { return nil }
    guard let vmi = block.lineHeightVMI, vmi > 0, let prevBlock else { return own }
    guard let prevRaw = styleLeadPt(prevBlock, doc, raw: true) else { return own }
    return max(own, prevRaw)
}

/// This physical line's own baseline-to-baseline lead in points, for a WS5+ FONT-BLOCK
/// document with no paragraph style governing the line (`styleLeadPt` returns `nil` for
/// every line here — PREVIEW.WS, the oracle behind this rule, carries no styles at all).
///
/// CALLER'S GATE, not this function's: only consulted (own lead stays `nil` otherwise)
/// when `doc.fonts` contains at least one PROPORTIONAL entry — a document-WIDE mode switch,
/// not a per-line one. -README.WS is the negative oracle for this: it carries exactly one
/// font-block record, a 12pt FIXED-PITCH Courier entry (likely the installation's own
/// default-face declaration, not an author's deliberate `.fp` insertion), and its WS7
/// capture prints flat 12pt leading throughout (baseline_gaps_pt: 12.0 between consecutive
/// body lines) — NOT the 14.4 (1.2x12) this function would compute if consulted for every
/// one of its Courier-tagged lines. PREVIEW.WS's own 12pt sections (its 3-line Courier
/// intro, BEFORE any font tag has even appeared in the stream) measure 14.4 despite being
/// just as fontless-looking at that exact point — the only document-level difference is
/// that PREVIEW contains real proportional font blocks (Times/Univers/Aachen) elsewhere and
/// -README never does. So a document with no proportional font block anywhere — SAWYER,
/// VERSIONS, TWAINLET, OCAPTAIN, every fontless doc in the corpus, AND -README's
/// single-fixed-font case — must stay on the byte-identical 12pt grid throughout, full stop.
///
/// `state` is `inout`, owned and threaded by the CALLER across every physical line of the
/// document in source order (mirrors `pendingSa`'s cross-block carry): a blank line (no
/// font tag of its own) inherits whatever `state` already holds, exactly as a real
/// printer's VMI-select state would survive an empty line with no command bytes to change
/// it.
///
/// RULE (measured 2026-08-20 against PREVIEW.WS/PREVIEW.pcl, `fidelity_gate.py` Finding B —
/// every gap on the page decomposes to 0.3pt residual under it): 1.2x the largest
/// PROPORTIONAL font size (`FontChange.proportional == true`) active anywhere on the line,
/// carried forward through blank lines. A FIXED-PITCH font block (Courier, any declared
/// point size) NEVER raises the governing size above the document default and, as the LAST
/// font tag active on a line, RESETS the carried state — WS5+ Courier font blocks change
/// PITCH (historically elite/pica variants of the one typewriter face), not real vertical
/// measure, so a 20pt Courier block's own line and every blank line after it print at the
/// plain 1.2x12=14.4pt default, not 1.2x20. Confirmed on PREVIEW's OWN 12pt intro (no font
/// tag at all yet — 14.4pt gaps) and its trailing Courier-20pt block (6 blank continuation
/// lines, all 14.4pt, not 24.0pt) alike — both land on the SAME formula via `state`, not a
/// special case. A line whose OWN leading spaces still carry the OUTGOING tag before a
/// mid-line font change (WordStar's own encoding: the change lands after the characters it
/// precedes, not at line start) takes the LARGER of every proportional size found on the
/// line, matching a real printer sizing the line to its tallest glyph.
///
/// NOT APPLIED when the document ever used a real `.lh` (guarded by the same
/// `lhSource == .file` check `styleLeadPt` uses) — no corpus evidence exists for how real
/// WS7 arbitrates a font block's own size against an ACTIVE `.lh`, so that combination is
/// left to the pre-existing `.lh`-based mechanism, unconditionally, same doctrine as
/// `styleLeadPt`'s own guard. Port of Python's `_font_lead_pt`.
func fontLeadPt(_ line: Line, fonts: [FontChange], baseSize: Double, state: inout Double?)
    -> Double
{
    var propSizesHere: [Double] = []
    var lastTagProportional: Bool? = nil
    for s in line.spans {
        guard let fidx = s.font, fidx >= 0, fidx < fonts.count else { continue }
        let entry = fonts[fidx]
        if entry.proportional {
            propSizesHere.append(entry.points)
            lastTagProportional = true
        } else {
            lastTagProportional = false
        }
    }
    let governing = propSizesHere.max() ?? state
    if lastTagProportional == false {
        state = nil
    } else if !propSizesHere.isEmpty {
        state = propSizesHere.max()
    }
    // Python's `governing if governing else base_size` — a falsy (nil OR 0.0) governing
    // size falls back to the document's own printed size, not just a nil one.
    let effective = (governing != nil && governing != 0) ? governing! : baseSize
    return effective * 1.2
}

/// One paginated page: a collection of `PageLine`s, plus the running head and foot IN
/// FORCE when this page printed (replayed from `Document.hfEvents`). Port of Python's
/// `Page(list)`.
///
/// A struct that behaves as a collection of `PageLine` for the same reason `PageLine`
/// itself is one: every existing consumer iterates a page as a sequence of lines and
/// keeps working untouched, while new code can ask for `.headers`/`.footers`.
public struct Page: RandomAccessCollection, MutableCollection, RangeReplaceableCollection,
                    ExpressibleByArrayLiteral, Hashable, Sendable {
    public var lines: [PageLine]
    /// Running head/foot text by line number (1-5), IN FORCE when this page printed —
    /// only non-empty entries (an empty string CLEARS a line, so it never renders).
    /// Empty on every page from a layout path that doesn't replay `hfEvents` (the
    /// footnote/annotation/endnote-aware paginator, unchanged since before this port):
    /// those pages carry the DOCUMENT'S final-state `headers`/`footers` instead, which
    /// is the fallback `runningOps` applies when a page's own dict is empty — matching
    /// Python's `getattr(pl, 'headers', None)` on a plain list (no attribute at all).
    public var headers: [Int: String]
    public var footers: [Int: String]
    /// The `.mt`/`.mb` IN FORCE when this page's own pagination started (Finding 3,
    /// b26-print-fidelity-2) — `nil` for "the document's global (first-occurrence)
    /// value", which is every page of every document that never changes `.mt`/`.mb`
    /// mid-document (see `mtMbCheckpoints`). Threading the SAME resolved pair from
    /// pagination-time (which already had to know it, to size the page's own capacity)
    /// through to render-time (`emitPDF`'s per-page loop) keeps the two in agreement by
    /// construction, rather than re-deriving the same answer twice from
    /// `Document.dotPositions`. Set only by `layoutPrintedPagesPlain` — the
    /// footnote/annotation/endnote-aware paginator (`layoutPrintedPages`) never touches
    /// these, matching Python's `_paginate_printed_notes` (unchanged by Finding 3).
    public var mtLines: Double?
    public var mbLines: Double?
    /// `.pl` in force when this page's own pagination started (register b31-dot-command-
    /// sweep, `plCheckpoints`) -- `nil` for "the document's global (first-occurrence)
    /// value", the same contract as `mtLines`/`mbLines` above.
    public var plLines: Double?
    /// `.hm`/`.fm` in force when this page's own pagination started (register b31-dot-
    /// command-sweep, `hmFmCheckpoints`) -- same `nil`/"document global" contract again.
    public var hmLines: Double?
    public var fmLines: Double?

    public init() {
        lines = []
        headers = [:]
        footers = [:]
        mtLines = nil
        mbLines = nil
        plLines = nil
        hmLines = nil
        fmLines = nil
    }

    public init(_ lines: [PageLine], headers: [Int: String] = [:], footers: [Int: String] = [:],
               mtLines: Double? = nil, mbLines: Double? = nil, plLines: Double? = nil,
               hmLines: Double? = nil, fmLines: Double? = nil) {
        self.lines = lines
        self.headers = headers
        self.footers = footers
        self.mtLines = mtLines
        self.mbLines = mbLines
        self.plLines = plLines
        self.hmLines = hmLines
        self.fmLines = fmLines
    }

    public init(arrayLiteral elements: PageLine...) {
        self.init(elements)
    }

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }

    public subscript(position: Int) -> PageLine {
        get { lines[position] }
        set { lines[position] = newValue }
    }

    public mutating func replaceSubrange<C: Collection>(
        _ subrange: Range<Int>, with newElements: C
    ) where C.Element == PageLine {
        lines.replaceSubrange(subrange, with: newElements)
    }
}

/// Whether the document has any note that gets a PLACE on the printed page (a footnote
/// or annotation footer entry, or an endnote's end-of-document entry) — comments never
/// print. Port of Python's `_has_placeable_notes`. Documents with none of these go
/// through the plain points-based paginator (`layoutPrintedPagesPlain`); documents WITH
/// them keep the dedicated footnote/annotation-area paginator (`layoutPrintedPages`,
/// unchanged by this port) that grows a page-bottom area and floors body at 3 lines —
/// exactly the split Python's own `_doc_to_pagelines` makes.
func hasPlaceableNotes(_ doc: Document) -> Bool {
    doc.notes.contains { $0.kind == .footnote || $0.kind == .endnote || $0.kind == .annotation }
}

/// A comment's reference mark is POSITION, not ink — it renders nowhere on this path
/// (printed facsimile, or the plain line layer). Port of `_doc_to_pagelines`'s
/// `_keep_span` (ruling 2026-08-06 M9).
func keepSpanOnPageline(_ span: Span, refNotes: [Note]) -> Bool {
    if span.styles.contains(.fnref), let k = Int(span.text),
       k >= 1, k <= refNotes.count, refNotes[k - 1].kind == .comment {
        return false
    }
    return true
}

/// Wrap one IR line's spans to `width` columns, preserving styles. Port of `_wrap_line`
/// (pdf.py:36-55).
///
/// Greedy first-fit over words and space-runs, which is what a typewriter would have done.
/// A word longer than `width` overflows rather than being broken — `col &&` in the Python
/// guard means a token placed at column 0 is always placed.
///
/// Returns at least one line, empty if the input was: a blank IR line is a blank page line,
/// not nothing at all, and `docToPagelines` counts on that for its paragraph spacing.
public func wrapLine(_ spans: [Span], width: Int) -> [PageLine] {
    // Words and space-runs, each carrying the styles of the span it came from. Python splits
    // on `( +)` — a capture group, so the separators are kept — and drops the empty strings
    // that fall out at the edges.
    var tokens: [Span] = []
    for span in spans {
        for piece in splitKeepingSpaceRuns(span.text) {
            tokens.append(Span(text: piece, styles: span.styles, font: span.font))
        }
    }

    var lines: [PageLine] = []
    var line: PageLine = []
    var col = 0
    for token in tokens {
        if !isSpaceRun(token.text), col > 0, col + token.text.width > width {
            while let last = line.last, isSpaceRun(last.text) {   // no trailing spaces
                col -= last.text.width
                line.removeLast()
            }
            lines.append(line)
            line = []
            col = 0
        }
        line.append(token)
        col += token.text.width
    }
    while let last = line.last, isSpaceRun(last.text) {
        line.removeLast()
    }
    if !line.isEmpty || lines.isEmpty {
        lines.append(line)
    }
    return lines
}

/// Merge adjacent same-style segments into single text runs. Port of `_coalesce`
/// (pdf.py:114-122).
///
/// The wrapper leaves one segment per word and one per space-run; the byte writer emits a
/// text-showing operator per segment. Merging first is the difference between a page of a
/// few hundred operators and a page of a few thousand, and changes nothing on paper because
/// Courier's advance width is the same either way.
///
/// THE FONT RUN IS PART OF THE MERGE TEST, added with printed-mode base-14 fonts
/// (`PDFFonts.swift`): two adjacent spans set in different faces are not the same run, and
/// merging them would set the second one in the first one's font. Python gets this free —
/// its font index rides in the same `frozenset` as the style codes, so its `styles ==
/// styles` covers both — and this comparison is that equality written out. A document with
/// no font runs has `nil` on every span and is unaffected, which is why no fontless byte
/// changed.
public func coalesce(_ line: PageLine) -> PageLine {
    var out = PageLine([], lead: line.lead)     // the merge changes segments, never the lead
    for span in line {
        // `pix` is part of the merge test for the same reason the font run is: Python's
        // `pix<N>` tag rides in the styles frozenset, so its `styles == styles` keeps a
        // pix placeholder its own span (layout byte parity, 2026-08-18).
        // `pcl` joins the test for the same reason (register C2): Python tags a print
        // control's raw-PCL payload as its own `pcl<N>` style string, so two ADJACENT
        // controls -- LJ6DTP's checkerboard row is a long run of them, every one
        // declaring the same 0 HMI width -- never merge into a single span there. Merged
        // here, the second control's program was silently lost and the page border
        // stopped drawing on the pages where two controls sit side by side.
        // `tabHMI`/`tabLeader` likewise (the tab-positioning fix): Python's
        // `tabhmi<N>`/`tableader<N>` tags are unique to a tab's own padding span, so
        // `_coalesce` there never merges it with the real text before or after it. That
        // uniqueness is what lets the PDF layer see a tab as a span of its own -- pad
        // equals 0 or the whole length, never a mixed split.
        if let last = out.last, last.styles == span.styles, last.font == span.font,
           last.colour == span.colour, last.pctlHMI == span.pctlHMI, last.pix == span.pix,
           last.pcl == span.pcl, last.tabHMI == span.tabHMI,
           last.tabLeader == span.tabLeader {
            out[out.count - 1].text += span.text
        } else {
            out.append(span)
        }
    }
    return out
}

/// IR -> pages of laid-out lines. Port of `_doc_to_pagelines` (pdf.py:57-112) for Modern
/// mode; Printed mode is this project's own addition (job — period-authentic footnote
/// layout), since Python's `pdf.py` never modeled WordStar's real page-bottom footnote
/// area — it ran the same "collect at the end" logic in both modes. See
/// `layoutPrintedPages` below for that half.
///
/// - Parameters:
///   - doc: the parsed document.
///   - printed: line-for-line facsimile (`true`) or reflowed to the text column (`false`).
///     The emitter decides this from the mode and `isPrinted(doc)`; it is a parameter here
///     so the layout can be tested both ways against one document.
///   - sentenceSpacing: N9 (b33 field notes), pre-resolved bool (`true` = 'single') —
///     `false` is the correct default for every internal re-pagination caller
///     (`tocPageNumbers`), since Printed's physical lines never wrap, so collapsing an
///     interior double space never changes line/page counts and this parameter cannot
///     affect where anything lands; only the real render call (`emitPDF`) needs to pass
///     the resolved value through.
/// - Returns: at least one page, possibly a single empty one.
public func docToPagelines(
    _ doc: Document, printed: Bool, pixResults: [PixResult] = [],
    pictures: EmitOptions.PixMode = .off, sentenceSpacing: Bool = false
) -> [Page] {
    let isPrintStream = doc.detection?.variant == .printstream
    if printed {
        if hasPlaceableNotes(doc) {
            // b24 round 19 (RULINGS-LEDGER PIX row) left this path as a documented
            // scope cut; round 22 closed it — the notes-aware paginator embeds too,
            // through the same shared substitution/sizing helpers.
            //
            // `stripBlanks: false` (layout byte parity, 2026-08-18): Python's notes
            // path returns its pages RAW — `_doc_to_pagelines` pops trailing EMPTY
            // pages but never strips a page's own leading/trailing blank lines on
            // this branch, so a notes-path page ending in an authorial blank keeps
            // it. The blank paints nothing, so PDF ink is identical either way.
            return finalizePages(layoutPrintedPages(doc, pixResults: pixResults,
                                                    pictures: pictures,
                                                    sentenceSpacing: sentenceSpacing),
                                 printed: true, isPrintStream: isPrintStream,
                                 stripBlanks: false,
                                 fallbackHeaders: doc.headers, fallbackFooters: doc.footers)
        }
        return finalizePages(layoutPrintedPagesPlain(doc, pixResults: pixResults,
                                                      pictures: pictures,
                                                      sentenceSpacing: sentenceSpacing),
                             printed: true, isPrintStream: isPrintStream,
                             fallbackHeaders: doc.headers, fallbackFooters: doc.footers)
    }
    // Modern PDF's own real pipeline is `modernStreams` (PDFModernLayout.swift), which
    // embeds since round 22; this legacy Modern layout is not an emitter path for it,
    // so `pixResults`/`pictures` are simply unused on this branch. Modern never calls
    // `runningOps` (`printed` guard), so a fallback header/footer here would be inert —
    // omitted rather than passed for no reason.
    return finalizePages(layoutModernPages(doc), printed: false, isPrintStream: isPrintStream)
}

/// `{blockIndex: pageNumber}` — the REAL paginator's own answer for which page each
/// block's FIRST printed line landed on (b24 round 18, RULINGS-LEDGER row 4). `startNo`
/// matches whatever page number actually prints in the corner (`emitPDF`'s own
/// convention). A `.tc`/`.ix` entry whose own block never reached a printed page (a stray
/// or malformed dot line, or an empty block) simply gets no entry here — `compileTOC`/
/// `compileIndex` treat a missing key as "no page number available", not a crash.
/// Re-runs the SAME `docToPagelines` pass `emitPDF`'s own printed branch uses — one extra
/// pagination pass, paid once per TOC/Index-enabled conversion, not per entry. Port of
/// `_toc_page_numbers`.
///
/// Per-page numbers come from `resolvePageNumbers`/`pnCheckpoints` (register b31-dot-
/// command-sweep) rather than a flat `startNo + pageIndex` -- a document whose `.pn`
/// re-anchors mid-document would otherwise give a TOC entry the WRONG page number past
/// that point.
public func tocPageNumbers(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off
) -> [Int: Int] {
    // b24 round 19 (RULINGS-LEDGER PIX row): threaded through so an embedded picture's
    // own vertical footprint shifts these page numbers exactly the way it shifts the
    // real render -- without this, TOC page numbers could disagree with where the real
    // PDF put things.
    let pages = docToPagelines(doc, printed: true, pixResults: pixResults, pictures: pictures)
    let pageNumbers = resolvePageNumbers(pnCheckpoints(doc), pages)
    var resolved: [Int: Int] = [:]
    for (pageIndex, page) in pages.enumerated() {
        for line in page.lines {
            if let bi = line.bi, resolved[bi] == nil {
                resolved[bi] = pageNumbers[pageIndex]
            }
        }
    }
    return resolved
}

/// Plain PageLines for the compiled TOC/Index section — TOC before Index (b24 round 18,
/// RULINGS-LEDGER row 4), each clearly headed, a TOC entry indented two columns per level
/// (`.tc`/`.tc1`-`.tc9`, WSFORMAT's own outline levels). Port of `_toc_index_pagelines`.
func tocIndexPagelines(_ doc: Document, pageNumbers: [Int: Int]?) -> [PageLine] {
    var lines: [PageLine] = []
    let toc = compileTOC(doc, pageNumbers: pageNumbers)
    if !toc.isEmpty {
        lines.append(PageLine([Span(text: "TABLE OF CONTENTS", styles: .bold)]))
        lines.append(PageLine([]))
        for entry in toc {
            lines.append(PageLine([Span(text: String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text)]))
        }
        lines.append(PageLine([]))
    }
    let idx = compileIndex(doc, pageNumbers: pageNumbers)
    if !idx.isEmpty {
        lines.append(PageLine([Span(text: "INDEX", styles: .bold)]))
        lines.append(PageLine([]))
        for text in idx {
            lines.append(PageLine([Span(text: text)]))
        }
    }
    return lines
}

/// Modern mode: otherwise unchanged from the original Python-parity port (b26 notes wave,
/// port of ctrl-kd 5da154b, touched only the trailing note-list's per-kind labels — see
/// below). Reflows every line to `maxCols` and collects footnotes/endnotes/annotations at
/// the very end under one 20-dash rule — the shape this project shipped before the
/// period-authentic Printed layout existed, and which Printed mode below no longer shares.
private func layoutModernPages(_ doc: Document) -> [Page] {
    enum LayoutItem {
        case line(PageLine)
        case pageBreak
        /// `.cp n` — resolved by the page-filling loop below, the only thing that knows
        /// how full the page is.
        case condPage(Int)
    }

    let refNotes = inlineReferenceNotes(doc)
    var items: [LayoutItem] = []
    for block in doc.blocks {
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        // Reflowed: logical lines, soft wraps joined back (`mergedLines`, ctrl-kd 2.0.0) —
        // Modern mode wraps to `maxCols` anyway, so a soft break here is redundant with the
        // wrapper's own decision, not a break the reader should see twice.
        for line in mergedLines(block) {
            // The module docstring's "headings bold" promise, unimplemented until Python
            // 1.1.5 (found by this port, job-011). Bold is added to EVERY span in a heading
            // block, not substituted: a span already italic stays italic and becomes
            // bold-italic, which is why this is a union and not an assignment. The active
            // paragraph style's own attributes merge the same way.
            let spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes) }
                .map { sp -> Span in
                    let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                    let colour = effectiveSpanColour(sp, block: block)       // register C5
                    return styles == sp.styles && colour == sp.colour ? sp
                        : Span(text: sp.text, styles: styles, font: sp.font, colour: colour)
                }
            items.append(contentsOf: wrapLine(spans, width: PDFMetrics.maxCols)
                .map { LayoutItem.line(PageLine($0.spans, soft: line.soft)) })
        }
        if !block.lines.isEmpty {
            items.append(.line([]))                           // blank line between paragraphs
        }
    }

    // Footnotes/endnotes/annotations collect at the end under a 20-dash rule. b26 notes
    // wave (port of ctrl-kd 5da154b): this dump used to renumber every kept note through
    // ONE shared sequential index regardless of kind (`doc.footnotes` is the flattened,
    // kind-blind view the module doc above describes), so a footnote #1 and an endnote #1
    // both printed "[1]"/"[2]" -- silently disagreeing with the one label every real
    // emitter (and this same file's own Printed-mode area, `footerEntryLines`/
    // `endnoteEntryLines`) agrees on. Per-kind now, reusing those exact helpers: "1." for
    // footnotes/annotations, "(1)" for endnotes -- oracle-verified (-SCREEN.WS: "1.
    // Footnote" / "(1)  Endnote").
    let placeable = doc.notes.enumerated().filter {
        $0.element.kind == .footnote || $0.element.kind == .endnote
            || $0.element.kind == .annotation
    }
    if !placeable.isEmpty {
        items.append(.line([]))
        items.append(.line([Span(text: String(repeating: "-", count: 20))]))
        items.append(.line([]))
        for (i, note) in placeable {
            let entryLines = note.kind == .endnote
                ? endnoteEntryLines(note, doc: doc, index: i, width: PDFMetrics.maxCols)
                : footerEntryLines(note, doc: doc, index: i, width: PDFMetrics.maxCols)
            items.append(contentsOf: entryLines.map(LayoutItem.line))
        }
    }

    var pages: [Page] = []
    var page: Page = []
    for item in items {
        switch item {
        case .pageBreak:
            pages.append(page)
            page = []
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            if PDFMetrics.linesModern - page.count < n, !page.isEmpty {
                pages.append(page)
                page = []
            }
        case .line(let line):
            if page.count >= PDFMetrics.linesModern {
                pages.append(page)
                page = []
            }
            page.append(line)
        }
    }
    if !page.isEmpty {
        pages.append(page)
    }
    return pages
}

/// We supply the paper margins, so WordStar's own margin blanks in a print stream would
/// double up. But deliberate spacing (a chapter-drop on page 1) must survive: the MACHINE
/// margin is uniform on every page, so strip only the minimum leading-blank count seen on
/// pages 2+ — anything beyond it on any page is the author's layout. Trailing blanks are
/// always machine.
///
/// ...but ONLY for a PRINT STREAM (`isPrintStream`). This repair was written for
/// print-to-disk output, where WordStar physically emitted its top margin as blank
/// lines. A WS4/WS5+ DOCUMENT has no machine margin in it at all — `.mt` is a dot
/// command the emitter applies as paper margin — so every leading blank in one is the
/// author's. Running the stripper on a document deletes an author's chapter drop
/// outright, and on any SINGLE-page document it deletes every leading blank, because the
/// `len(pages) > 1` fallback measures the only page against itself.
///
/// Shared by both modes' page-building functions; Modern's own layout (`!printed`) always
/// strips each page's own leading blanks (it never faithfulness-matches machine margin at
/// all), matching Python's own three-way branch in `_doc_to_pagelines` exactly.
///
/// `fallbackHeaders`/`fallbackFooters` are ONLY consulted for the `pages.isEmpty` branch
/// below — the "this document produced literally zero pages" case (`layoutPrintedPagesPlain`
/// never appended a single `PageLine`, e.g. a content-free template like REF/ADVANCE.DOT).
/// Python's `pages or [[]]` there substitutes a bare LIST, which has no `.headers`
/// attribute at all, so `_running_ops`'s `getattr(pl, 'headers', None)` returns `None` and
/// falls back to `doc.headers`/`doc.footers` (the document's own final running-head
/// state) — the ONLY per-document geometry that would otherwise show up on a page with no
/// body text at all (its position is still driven by the document's own `.mt`/`.mb`/`.fm`,
/// see `runningOps`'s `footLine`). `Page.headers`/`.footers` are a concrete (non-optional)
/// `[Int: String]`, so there is no `nil` to fall back FROM at the call site — passing the
/// document's final state directly here reproduces the same end state Python reaches via
/// its attribute trick, without needing an `Optional`/sentinel of our own. A page that DID
/// go through real pagination (`closePage()`) always supplies its own concrete (possibly
/// legitimately empty, e.g. before the document's first `.h1`) headers/footers instead —
/// this parameter never overrides those, only the synthetic empty-document fallback below.
private func finalizePages(_ rawPages: [Page], printed: Bool, isPrintStream: Bool,
                           stripBlanks: Bool = true, fallbackHeaders: [Int: String] = [:],
                           fallbackFooters: [Int: String] = [:]) -> [Page] {
    var pages = rawPages
    if pages.isEmpty {
        // Python's `pages or [[]]`, with the running-head fallback ported alongside it —
        // see this function's own doc comment.
        return [Page([], headers: fallbackHeaders, footers: fallbackFooters)]
    }

    func leading(_ page: Page) -> Int {
        var n = 0
        while n < page.count, isBlank(page[n]) {
            n += 1
        }
        return n
    }

    if stripBlanks, printed, isPrintStream {
        // `min` runs over pages 2+, falling back to page 1's own count when there is no
        // page 2: Python's `if len(pages) > 1 else`.
        let machine = pages.dropFirst().map(leading).min() ?? leading(pages[0])
        for i in pages.indices {
            pages[i].removeFirst(min(machine, leading(pages[i])))
        }
    } else if stripBlanks, !printed {
        for i in pages.indices {
            pages[i].removeFirst(leading(pages[i]))
        }
    }
    // else (printed, a DOCUMENT not a print stream): keep every leading blank -- it is
    // authorial, not the machine's -- and fall straight through to the trailing strip.
    if stripBlanks {
        for i in pages.indices {
            while let last = pages[i].last, isBlank(last) {
                pages[i].removeLast()
            }
        }
    }

    // A trailing empty page is a blank sheet. Two things can produce one: content that
    // exactly fills a page pushes the next page's structural blank out of the loop above, and
    // a trailing `.pa .pa` appends a page with nothing in it.
    //
    // This pop must run AFTER the stripping loop, because stripping is what empties the first
    // kind: a final page holding nothing but blank lines has a positive line count until the
    // strip hollows it out, so a pop placed earlier looks at a non-empty page and skips it.
    // Python 1.1.5 popped before stripping and the blank sheet survived — found by this port
    // in job-012 and fixed in 1.1.6 (pdf.py:115-120), which is the position reproduced here.
    //
    // Explicit interior blanks from `.pa .pa` between content are preserved: only the LAST
    // page is popped, and only while there is more than one.
    while pages.count > 1, pages[pages.count - 1].isEmpty {
        pages.removeLast()
    }
    return pages
}

// MARK: - Printed mode: the period-authentic footnote/endnote/annotation layout
//
// The WordStar 5 manual, verbatim: "Footnotes are separated from the text by a line of 20
// dashes. If a footnote doesn't fit at the bottom of the page, the continued text is
// printed in the footnote area at the bottom of the next page (except after the last page
// of regular text, where footnotes are printed at the top of the page). A minimum of three
// lines of regular text are printed on a page regardless of the size of the footnote area
// except on the last page of the document."
//
// Rules this implements, in the same numbering the job brief used:
// 1. The reference never moves — a `Note` is never reserved-and-pushed; it renders exactly
//    where `resolvePrintedBody` finds its `fnref` span, and the footer for it appears
//    whenever the PAGE holding that reference closes.
// 2. The footer area grows to hold what's due, eating into the page's body allotment.
// 3. Floor: the first three lines of body on a page are placed unconditionally, before the
//    footer's size is ever allowed to compete for room.
// 4. Overflow splits across pages; a continuation chunk is preceded by one literal
//    `...Continued...` line.
// 5. On the true last page of body text, the floor no longer matters (there is no next body
//    page to defer to) and any footer overflow prints at the TOP of a fresh page instead of
//    the bottom of one.
//
// Annotations share the footnote area (their `tag` is the marker); endnotes never appear
// there at all — they collect at the true end of the document with no heading, per the
// spec. Comments never print. Footnote/endnote numbering is independent, driven by
// `doc.footnoteNumberStart`/`endnoteNumberStart` (default 1) plus each `Note.number`
// (0-based).

/// One body item, printed-mode's own shape: an explicit break, or a verbatim line plus the
/// footnote/annotation notes whose `fnref` reference falls on it (endnotes are collected
/// separately below — they never compete for page-bottom room).
private enum PrintedBodyItem {
    case pageBreak
    /// `due` pairs each note with its index in `doc.notes` — the identity `noteLabel`
    /// needs (Python threads the precomputed label itself through its stream refs).
    case line(PageLine, due: [(note: Note, index: Int)])
    /// `.cp n` — resolved in `layoutPrintedPages`, the only place that knows how full the
    /// page is.
    case condPage(Int)
}

/// A footnote/annotation waiting in the page-bottom queue. `remaining` shrinks as pages
/// consume it; `needsContinuedMarker` is set the moment a page takes only part of it, so the
/// NEXT page that resumes it prepends the literal continuation line first.
internal struct QueuedNote {   // internal: the progress invariant is unit-tested
    var remaining: [PageLine]
    var needsContinuedMarker: Bool
}

private let footerContinuedLine = "...Continued..."

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
private func notesMarkerPadCols(_ doc: Document) -> Int? {
    var widths = Set<Int>()
    for (i, note) in doc.notes.enumerated() {
        switch note.kind {
        case .footnote: widths.insert("\(noteLabel(note, doc: doc, index: i))." .width)
        case .endnote: widths.insert("(\(noteLabel(note, doc: doc, index: i)))".width)
        case .annotation: widths.insert(noteLabel(note, doc: doc, index: i).width)
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
private func padMarker(_ base: String, padCols: Int?) -> String {
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
private func noteMarker(_ note: Note, doc: Document, index: Int) -> String {
    noteLabel(note, doc: doc, index: index)
}

/// The footer entry for one footnote/annotation, wrapped to `width` — factory-default
/// marks: `1.` (trailing period) for a footnote, the bare tag for an annotation.
///
/// `padCols` (Finding 4, b26 visual pass): see `notesMarkerPadCols`. `nil` (the
/// overwhelming common case — any document whose notes all share one marker width)
/// keeps the original plain single-space join, byte-identical.
private func footerEntryLines(_ note: Note, doc: Document, index: Int,
                              width: Int, padCols: Int? = nil,
                              sentenceSpacing: Bool = false) -> [PageLine] {
    // N9 (b33 field notes): applied to the note's own text before the marker is
    // prepended -- the marker itself (a bare number/tag) carries no sentence-ending
    // punctuation of its own to interact with.
    let noteText = sentenceSpacing ? sentenceSpacingTexts([note.text])[0] : note.text
    let text: String
    switch note.kind {
    case .footnote:
        let marker = padMarker("\(noteMarker(note, doc: doc, index: index)).", padCols: padCols)
        text = "\(marker)\(noteText)"
    case .annotation:
        let marker = padMarker(noteMarker(note, doc: doc, index: index), padCols: padCols)
        text = "\(marker)\(noteText)"
    default: text = noteText                 // unreached: endnotes/comments never queue here
    }
    return wrapLine([Span(text: text)], width: width)
}

/// The true-end-of-document entry for one endnote — factory-default mark `(1)`.
/// `padCols`: see `footerEntryLines`.
private func endnoteEntryLines(_ note: Note, doc: Document, index: Int,
                               width: Int, padCols: Int? = nil,
                               sentenceSpacing: Bool = false) -> [PageLine] {
    let marker = padMarker("(\(noteMarker(note, doc: doc, index: index)))", padCols: padCols)
    let noteText = sentenceSpacing ? sentenceSpacingTexts([note.text])[0] : note.text
    return wrapLine([Span(text: "\(marker)\(noteText)")], width: width)
}

/// Blocks -> printed body items, fixing up every `fnref` span's displayed text along the
/// way. The parser numbers EVERY `fnref` sentinel (footnote, endnote, and annotation alike,
/// in document order — comments never get one) with one shared counter, so a span's raw
/// text is only a position, not a display value: the n-th `fnref` span corresponds to the
/// n-th non-comment `Note`, and that correspondence — not the span's own text — is what
/// decides what actually prints. A `fnref` with no corresponding note (more sentinels than
/// notes — malformed input, or a stray control byte the parser mistook for one) is left as
/// found rather than crashing or dropping it; `stray_sentinel` is exactly this case.
///
/// `pixResults`/`pictures` (b24 round 22, closing round 19's documented scope cut): the
/// same single-pix-placeholder substitution `resolvePlainBody` performs on the plain
/// path — a physical line whose only real content is one resolved, decoded pix tag
/// becomes an image PageLine (empty segments, `.image` set, `.lead` = the RESERVED
/// PLACEHOLDER block's height — round 26 wave 3, `pixReservedAdvance` — not the raster's
/// own continuous pixel height). Port of the round-22 half of Python's `_body_stream_printed`,
/// updated for round 26 wave 3 (`fidelity_gate.py` Findings A/B).
private func resolvePrintedBody(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [PrintedBodyItem] {
    // ALL kinds are numbered by the parser's shared counter since M9 (comments
    // included), so the cursor walks all of `doc.notes`; a comment consumes its
    // position and renders NOTHING — never printed: no ink, no ref.
    let referenced = inlineReferenceNotes(doc)
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    let textWidthPt = embedImages ? printedTextWidthPt(doc) : 0.0
    let defaultLeadPt = printedLead(doc)
    // Register b31: this line's own `.po` override needs the printed type size for the
    // same edge-of-page clamp `printedLeft` already applies (`resolveLeftPt`).
    let sizeForLeft = printedSize(doc)
    // round 26 wave 3 (fidelity_gate.py Finding B): same carried-governing-size mechanism
    // as `resolvePlainBody` — see `fontLeadPt`.
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.fonts.contains { $0.proportional } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    var cursor = 0
    var items: [PrintedBodyItem] = []

    for (bi, block) in doc.blocks.enumerated() {
        // An explicit `.pa` is honored verbatim in a facsimile. WordStar's own 0x0B
        // end-of-page marks are NOT breaks -- see `Line.softpage`.
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        // Fix C (b26-print-fidelity-2): same per-block lookup as `resolvePlainBody` —
        // see its own comment and `enteringLeadPt`.
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        var firstLineOfBlock = true
        // Indexed (not a plain `for`) so an embedded pix substitution below can look
        // ahead and CONSUME the blank placeholder lines WordStar reserved for it — see
        // `pixReservedAdvance`.
        var li = 0
        while li < block.lines.count {
            let line = block.lines[li]
            li += 1
            let baseSpans = line.spans.map { sp -> Span in
                let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                // `pix` rides along even when the styles changed (round 22 — the
                // substitution below needs it); Python's tag-based styles carry it
                // implicitly. `pcl` likewise (register C2): a HEADING block is exactly
                // where `effectiveSpanStyles` DOES change the styles (headingBold), and
                // LJ6DTP puts the page-border print control on a heading line on four of
                // its eight pages -- dropping the field there stopped the border drawing
                // on precisely those pages. Other structural fields keep this path's
                // existing shape.
                let colour = effectiveSpanColour(sp, block: block)       // register C5
                return styles == sp.styles && colour == sp.colour ? sp
                    : Span(text: sp.text, styles: styles, font: sp.font, colour: colour,
                           pix: sp.pix, pcl: sp.pcl, tabHMI: sp.tabHMI,
                           tabLeader: sp.tabLeader)
            }

            var outSpans: [Span] = []
            var due: [(note: Note, index: Int)] = []
            for span in baseSpans {
                guard span.styles.contains(.fnref), cursor < referenced.count else {
                    outSpans.append(span)
                    continue
                }
                let noteIndex = cursor
                let note = referenced[cursor]
                cursor += 1
                if note.kind == .comment {
                    continue                     // never printed: no ink, no ref (M9)
                }
                outSpans.append(Span(text: noteMarker(note, doc: doc, index: noteIndex),
                                     styles: span.styles, font: span.font))
                if note.kind == .footnote || note.kind == .annotation {
                    due.append((note: note, index: noteIndex))
                }
            }
            // Same style-over-default precedence as the plain path (`resolvePlainBody`) —
            // see `styleLeadPt`. Computed BEFORE the pix check (round 26, Finding A) since
            // the image's own reserved-placeholder advance now needs it too.
            var ownLead = leadPt(line.lead48)
            // Register b31: this line's own `.po` override, same "absolute here, `nil`
            // means agrees with the document default" contract `line.lead48` above
            // already has (`ParseWS.swift`'s back-dating pass).
            let ownLeft = line.poCols.map { resolveLeftPt($0, size: sizeForLeft) }
            // Fix C (b26-print-fidelity-2): same blank/entering-line split as
            // `resolvePlainBody` — see its own comment, `styleLeadPt`'s `raw` parameter,
            // and `enteringLeadPt`.
            let isBlank = !outSpans.contains { $0.text.contains { !$0.isWhitespace } }
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            if !isBlank {
                firstLineOfBlock = false
            }
            if let styleLead, line.lead48 == nil || line.lead48 == defaultLh48 {
                ownLead = styleLead
            }
            // round 26 wave 3 (fidelity_gate.py Finding B): a WS5+ FONT-BLOCK document
            // with no style governing this line (ownLead still nil) gets its lead from
            // the font block actually in force. See `fontLeadPt`.
            if ownLead == nil, fontLeadOk {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            // Round 22: exactly one resolved pix tag, no other real text on this
            // physical line -> an image PageLine (same substitution, sizing and
            // never-drop-text rule as `resolvePlainBody`). `due` still travels: a
            // comment reference sharing the line contributes no text and queues
            // nothing, so nothing is lost; a footnote/annotation reference leaves its
            // marker text behind, which blocks the substitution — anchors are never
            // silently dropped. `.lead` is the RESERVED PLACEHOLDER block's height
            // (round 26, Finding A/C — `pixReservedAdvance`), not the raster's own
            // continuous pixel height.
            if embedImages,
               let sub = spansPixSubstitution(outSpans.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                let (reserved, nBlank) = pixReservedAdvance(
                    block.lines, startIdx: li, ownLeadPt: ownLead ?? defaultLeadPt)
                li += nBlank
                items.append(.line(PageLine([], soft: line.soft, lead: reserved,
                                            overprint: line.overprint, bi: bi,
                                            image: .init(pixIndex: sub.pixIndex,
                                                         widthPt: sub.wPt, heightPt: sub.hPt),
                                            left: ownLeft),
                                   due: due))
                continue
            }
            // N9 (b33 field notes): applied to the FINAL body spans -- markers and
            // prose alike, since they render adjacently on the same physical line --
            // AFTER the pix-substitution check above, which needs the raw, untouched
            // text to match its structural placeholder.
            if sentenceSpacing { outSpans = sentenceSpacingSpans(outSpans) }
            // A PageLine, not a bare list of spans, so the line's own `.lh` survives the
            // footnote paginator too — body lines keep their lead whether or not the
            // document has notes.
            items.append(.line(PageLine(outSpans, soft: line.soft, lead: ownLead,
                                        overprint: line.overprint, bi: bi,
                                        kerning: line.kerning, left: ownLeft), due: due))
        }
    }
    return items
}

/// WordStar's minimum-body-line guarantee (pdf.py's `FOOTNOTE_FLOOR`): "a minimum of three
/// lines of regular text are printed on a page regardless of the size of the footnote
/// area." Used here only for the same floor Python applies to the page height and capacity
/// themselves, before any footnote ever enters the picture — see `_resolved_page_height`/
/// `_printed_cap` (pdf.py:37-60). The unrelated literal `3` a little further down (the
/// "first three lines of body are unconditional" rule in `layoutPrintedPages`) is the same
/// WordStar constant but is left as-is here to keep this fix's diff to the actual bug.
private let footnoteFloor = 3

/// Port of Python's `round()` (round-half-to-even / banker's rounding), which differs from
/// Swift's `FloatingPoint.rounded()` default (round-half-away-from-zero) — and `.rounded()`
/// itself needs libm symbols this Foundation-free Linux build can't link. `x` is always
/// non-negative here (a resolved page height in points), so `Int(x)` (truncation, which
/// equals floor for non-negatives) plus plain comparison reproduces `round()` exactly,
/// including its `.5` tie case, with no floating-point library call at all. Same technique
/// as `SymmetricBlocks.swift`'s `roundHalfToEven`, which works in pure integer arithmetic;
/// this one takes a `Double` because a page height in inches isn't always a whole number of
/// `.pl` lines (custom/converted geometry), unlike that function's HMI fields.
///
/// Not `private`: `PDFWriter.swift`'s `pageStream` needs the same banker's-rounding (ctrl-kd
/// 2.0.0's `supSize = round(size * 2 / 3)`, mirroring Python's `round()` exactly).
func roundHalfToEven(_ x: Double) -> Int {
    let whole = Int(x)
    let fraction = x - Double(whole)
    if fraction < 0.5 { return whole }
    if fraction > 0.5 { return whole + 1 }
    return whole % 2 == 0 ? whole : whole + 1
}

/// A copy of `page` with `heightIn`/`pwIn` SWAPPED — `.pr or=l` (b24 round 17,
/// RULINGS-LEDGER row 2, register C18, Paged-surface doctrine point 2: "honor .pr or=l
/// landscape in all paged surfaces"). Port of Python's `_landscape_page`. Swapping at this
/// single source lets every existing `heightIn`/`pwIn` consumer (pagination capacity, top
/// margin, the MediaBox itself, RTF's `\paperh`/`\paperw`) cascade correctly with no
/// per-site change — a landscape page is genuinely SHORTER top-to-bottom (fewer text
/// lines fit) as well as wider, exactly what real landscape printing does. `.mt`/`.mb`/
/// `.po`-derived margins are left untouched — still top/bottom/left relative to the text,
/// same as WordStar's own driver-level rotation never re-interpreted them either.
func landscapePage(_ page: PageGeometry) -> PageGeometry {
    var eff = page
    eff.heightIn = page.pwIn
    eff.pwIn = page.heightIn
    return eff
}

/// Resolved page height, in points, for THIS document — the general form of Python's
/// `_resolved_page_height(doc, printed)` (pdf.py:42-53). `PDFWriter.swift`'s `emitPDF` needs
/// this too (the MediaBox and the content stream's Y-origin must agree with the capacity
/// this same figure drives, or a custom-geometry page paginates correctly but still gets
/// drawn on/labeled as a Letter-size sheet) so this is `internal`, not `private`.
///
/// Modern renders on the document's declared sheet (Letter/Legal/A4 -- ruled
/// 2026-08-06); silence is Letter, exactly as before.
func resolvedPageHeight(_ doc: Document, printed: Bool) -> Int {
    printed ? resolvedPrintedPageHeight(doc)
        : roundHalfToEven((doc.page?.heightIn ?? 11.0) * 72.0)
}

/// Resolved PRINTED-page height, in points. Port of `_resolved_page_height(doc, printed:
/// True)` (pdf.py:42-53) — the printed-mode branch of `resolvedPageHeight` above.
///
/// Honours the file's own `.pl`-derived `heightIn` where the document has one (every
/// `parseWS` document does, resolved with a default when the file never set `.pl`);
/// defaults to 11in (`doc.meta.get('page', {}).get('height_in', 11.0)` in Python) for a bare
/// print-stream capture, which carries no dot commands to resolve page geometry from at
/// all. Clamped to at least `LEAD * (footnoteFloor + 1)` points so a degenerate tiny/absent
/// page can never send the capacity below the floor `_printed_cap` itself also enforces.
private func resolvedPrintedPageHeight(_ doc: Document) -> Int {
    let heightIn = doc.page?.heightIn ?? 11.0
    if heightIn == 0 {
        // `.pl 0` = page breaks off (bug 12284; see `textLinesPerPage`). The text model
        // already never breaks; the PDF page box itself falls back to Letter — a truly
        // unbounded page is not expressible in PDF.
        return PDFMetrics.pageHeight
    }
    let floorPoints = PDFMetrics.lead * (footnoteFloor + 1)
    return max(floorPoints, roundHalfToEven(heightIn * 72))
}

/// Printed-mode page capacity, in lines. Port of Python's `_printed_cap` (pdf.py, ctrl-kd
/// 1.3.0) — WordStar's own vertical model, not the fixed-margin arithmetic this used before:
///
/// WS documents (`doc.page` non-nil) get WordStar's own vertical model
/// (`textLinesPerPage`/Python's `_text_lines_per_page`: `.pl - .mt - .mb` at the `.lh` line
/// height — 55 for WordStar's own defaults, NOT the 60 a naive 1in-margin computation gave
/// before this fix). Print streams (`ParsePrintstream.swift`'s `parsePrintstream` — no `page`
/// meta at all) get the SAME model, from WordStar's documented defaults — see the body for
/// why the previous "their margin blanks travel in-band, so give them the full 66" reasoning
/// was retracted.
///
/// Clamped to at least `footnoteFloor + 1` lines either way, so a degenerate/tiny page can
/// never divide the page-bottom math by, or loop over, too little room.
///
/// SECOND KNOWN LIMIT, added with stateful `.lh` (2026-08-05). Capacity is computed at the
/// DOCUMENT-DEFAULT line height — `textLinesPerPage` on `page.lh48`, the file's first `.lh`.
/// A document that changes leading mid-page therefore paginates at a fixed lines-per-page
/// while its lines advance at their own leads, so a page of tightly-led text ends early and a
/// page of banners can run long. Whether WordStar RECOMPUTED lines-per-page as `.lh` changed
/// is UNMEASURED — register open question #15 — and the honest options (recompute per line,
/// or accumulate points until the text height is used up) are different answers to a question
/// no manual page settles. Guessing here would silently repaginate every multi-`.lh` document
/// on an assumption; leaving capacity where the evidence is keeps the change to what was
/// ruled: leads, not pagination.
func printedCap(_ doc: Document) -> Int {
    if let page = doc.page {
        return max(footnoteFloor + 1, page.textLines)
    }
    // PRINT STREAMS GET THE SAME MODEL. Corrected 2026-08-03 (Jon's ruling: "print
    // streams need to follow WordStar standards, not our falsely invented ones").
    // This used to hand a print stream the FULL page height — 66 lines on Letter —
    // justified by the claim that "their margin blanks travel in-band". That claim
    // was checked against raw bytes and is FALSE for real print-to-disk output: such
    // a stream carries no form feeds, and no top margin after its first page. It is
    // not a stack of whole physical pages; it is a run of printed lines. Paginating
    // it at 66 invented a page size WordStar does not document and no evidence
    // supports.
    //
    // So a stream with no page metadata falls back to WordStar's documented defaults,
    // the same as a document that declares none: .pl 66 - .mt 3 - .mb 8 = 55 lines.
    // That is what WordStar 4 itself produces when run (its live output shows 11-line
    // inter-page gaps = .mb 8 + .mt 3, on a 66-line pitch), and it makes the three
    // renderings of one document — the WS4 source, its print stream, and the live
    // program — finally agree at 9 pages, which none of them did before.
    //
    // KNOWN LIMIT, recorded rather than papered over: a print stream that DOES carry
    // its margins in band (WordStar 4's live output does) now gets margin on top of
    // margin. Distinguishing the two cases needs evidence we do not have, and
    // inventing a detector is exactly what this change undoes.
    return max(footnoteFloor + 1,
               textLinesPerPage(pl: defaultPlLines, mt: defaultMtLines,
                                mb: defaultMbLines, lh48: defaultLh48))
}

/// `printedCap`, but for an EXPLICIT (mt, mb) pair instead of the document's global
/// first-occurrence values — Finding 3 (b26-print-fidelity-2)'s per-page capacity; see
/// `mtMbCheckpoints`. Port of Python's `_printed_cap_for`.
///
/// `doc.page?.textLines` is a value CACHED at parse time from the document's global
/// mt/mb (`ParseWS.swift`'s own `textLinesPerPage` call) — calling that same function
/// directly here, rather than reading the cache, is what makes a page whose (mt, mb)
/// MATCHES the global pair come out byte-identical (same formula, same inputs) while a
/// page that changes them gets its own true capacity.
///
/// NEVER BELOW the document's own global capacity (b26-mtmb-general, LJ6DTP.WS): a
/// mid-document margin change may LOOSEN a page (more room than the document's own
/// declared default) but WS7 does not let one TIGHTEN it. Reconciled from two real WS7
/// captures whose mid-document `.mt`/`.mb` changes point opposite directions:
///   SCRIPT.WS block 64 (`.mt1`/`.mb0`, Figure 1's own tiny margins): local cap 65 >
///     global cap 53 (pl 66 - mt 7 - mb 6, its own `.MT 7`/`.MB 6`) — HONORED. WS7 fits
///     the whole figure on one page (measured: SCRIPT.pcl page count 11, matching only
///     when this local cap is used).
///   LJ6DTP.WS block 12 (`.mt1"`/`.mb1"`, right after the SAME kind of `.pa`-then-
///     margin-restate SCRIPT's own figures use): local cap 46 (pl 66 - mt 6.0 - mb 6.0)
///     < global cap 48 (pl 66 - mt 6.6 - mb 3.0, its own `.mt 1.1"`/`.mb .5"`) — NOT
///     honored. WS7's "Proportional Spacing Tables" section (measured: LJ6DTP.pcl, page
///     7 of 8) prints on ONE page; using the tighter local cap splits it across two, one
///     page too many (9 engine vs WS7's 8).
/// Both obey `cap = max(local, global)` with no exception — the ONE rule shape that
/// fits both real captures pointing opposite ways. Applying the SAME clamp per-field
/// (e.g. only to `.mb`, treating `.mt` differently) was considered and rejected:
/// LJ6DTP's own `.mt` change (6.6 -> 6.0, negligible) can't discriminate between "mb
/// never applies mid-document" and "mb is clamped" from this evidence alone, but "mb
/// never applies" independently FAILS SCRIPT (whose `.mb0` must be honored) while the
/// whole-cap max does not — so the max is the narrower, non-file-specific reading of
/// what's actually measured. The RENDERED override (`Page.mtLines`/`mbLines`, used for
/// the per-page printed-top/running-ops geometry swap) is untouched — only pagination
/// CAPACITY clamps; a document's own declared margin still renders where it says.
/// `plLines` (register b31-dot-command-sweep, `plCheckpoints`): `.pl` is STATEFUL exactly
/// like `.mt`/`.mb` -- measured against real WS7 (PL_PROBE, dosbox-x): a document holding
/// `.mt`/`.mb` fixed and setting `.pl 20` then `.pl 40` mid-document printed 18 lines on
/// page 1 (cap = 20-1-1) and 38 on page 2 (cap = 40-1-1) -- the SECOND value, not the
/// first, governs the page that follows it. `nil` means "no page-specific override", i.e.
/// use the document's own global first-occurrence `.pl` (every document that never
/// repeats `.pl` mid-document). Port of Python's `_printed_cap_for`.
func printedCapFor(_ doc: Document, mtLines: Double, mbLines: Double, plLines: Double? = nil) -> Int {
    let pl = plLines ?? (doc.page?.plLines ?? defaultPlLines)
    let lh = doc.page?.lh48 ?? defaultLh48
    let local = max(footnoteFloor + 1, textLinesPerPage(pl: pl, mt: mtLines, mb: mbLines, lh48: lh))
    return max(local, printedCap(doc))
}

/// `[(blockIndex, mtLines, mbLines), ...]` in ascending block order — the `.mt`/`.mb`
/// pair IN FORCE from that block onward, at BLOCK granularity (the coarsest anchor
/// `Document.dotPositions` gives — the same mechanism Soft Return.app's Show Invisibles
/// and `tocPageNumbers`/`AnnotatedLayout.swift` already read). Mirrors how `.lh` already
/// tracks per-LINE state (`Line.lead48`/`styleLeadPt`) — one level coarser, because
/// `.mt`/`.mb` only take visible effect at the next page start, never mid-line. Port of
/// Python's `_mt_mb_checkpoints`.
///
/// The FIRST checkpoint (block 0) is the document's own global mtLines/mbLines
/// (`ParseWS.swift`'s "first occurrence wins" page dict) — a document that never
/// touches `.mt`/`.mb` again after its own opening geometry gets exactly ONE checkpoint,
/// so every page's lookup returns the SAME pair the document-global functions already
/// gave it: no behaviour change for any document but the ones this exists for.
///
/// Finding 3: SCRIPT.WS changes both mid-document, around its embedded worked-example
/// figures — measured (ARTICLES/SCRIPT.WS's own dot-command bytes, via
/// `doc.dotPositions`): block 64 sets `.mt1`/`.mb0` (Figure 1's near-zero margins),
/// block 75 sets `.mt1"`/`.mb1"` (Figure 2's own, different margins).
func mtMbCheckpoints(_ doc: Document) -> [(blockIndex: Int, mt: Double, mb: Double)] {
    var mt = doc.page?.mtLines ?? defaultMtLines
    var mb = doc.page?.mbLines ?? defaultMbLines
    var checkpoints: [(blockIndex: Int, mt: Double, mb: Double)] = [(0, mt, mb)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "MT" || upperName == "MB" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if upperName == "MT" { mt = resolved } else { mb = resolved }
        if mt != checkpoints[checkpoints.count - 1].mt
            || mb != checkpoints[checkpoints.count - 1].mb {
            checkpoints.append((dp.blockIndex, mt, mb))
        }
    }
    return checkpoints
}

/// `(mtLines, mbLines)` in force at block index `bi`, per `checkpoints` (ascending, from
/// `mtMbCheckpoints`) — the LAST checkpoint at or before `bi`. Port of Python's
/// `_mt_mb_at`.
func mtMbAt(_ checkpoints: [(blockIndex: Int, mt: Double, mb: Double)], _ bi: Int) -> (mt: Double, mb: Double) {
    var mt = checkpoints[0].mt
    var mb = checkpoints[0].mb
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        mt = cp.mt
        mb = cp.mb
    }
    return (mt, mb)
}

/// `[(blockIndex, plLines), ...]` in ascending block order -- the `.pl` IN FORCE from that
/// block onward. Mirrors `mtMbCheckpoints`'s mechanism (same `dotPositions` anchor) but NOT
/// its block-0 seed: kept as its OWN function/list rather than folded in because `.pl` was
/// found and fixed separately (register b31-dot-command-sweep), on its own oracle evidence.
/// Port of Python's `_pl_checkpoints`.
///
/// Real WS7 evidence (PL_PROBE, dosbox-x): a document that holds `.mt`/`.mb` fixed at 1
/// line each and sets `.pl 20` then, after exactly one page's worth of body, `.pl 40`,
/// printed 18 lines on page 1 (cap = pl 20 - mt 1 - mb 1) and 38 on page 2 (cap = pl 40 -
/// mt 1 - mb 1) -- the page AFTER the second `.pl` uses ITS value, not the document's
/// first.
///
/// Seeded at WordStar's own HARDCODED default (`defaultPlLines`), NEVER at
/// `doc.page?.plLines` (`ParseWS.swift`'s first-occurrence reading) -- those are the SAME
/// number for a document that declares `.pl` right at its own start (the overwhelming
/// common case), but NOT for one whose only `.pl` sits mid-document with nothing before
/// it: `ParseWS.swift`'s "first occurrence wins" would read THAT single occurrence as the
/// document's global default and hand it back for block 0 too, retroactively applying the
/// mid-document value to pages that printed before the command was ever reached (caught
/// building `hmFmCheckpoints` below against a probe whose only `.hm`/`.fm` are
/// mid-document -- `.pl` shares the exact same construction, fixed here too).
///
/// If `dotPositions` carries no `.pl` entry AT ALL, the hardcoded seed is replaced with
/// `doc.page?.plLines` after the walk -- a document with no dot-command evidence for `.pl`
/// anywhere (every hand-built `Document(..., page:)` fixture that sets page geometry
/// directly rather than through `parseWS`, plus any real document that truly never sets
/// `.pl`) has no mid-document-only-occurrence to protect against, so its own declared page
/// value is trusted as-is -- exactly `mtMbCheckpoints`'s own seed. A document WITH at
/// least one `.pl` occurrence anywhere (mid-document or at its own true start, register
/// b31's actual target) is untouched by this fallback.
func plCheckpoints(_ doc: Document) -> [(blockIndex: Int, pl: Double)] {
    var pl = defaultPlLines
    var checkpoints: [(blockIndex: Int, pl: Double)] = [(0, pl)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PL" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if resolved != checkpoints[checkpoints.count - 1].pl {
            pl = resolved
            checkpoints.append((dp.blockIndex, pl))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].pl = doc.page?.plLines ?? defaultPlLines
    }
    return checkpoints
}

/// `plLines` in force at block index `bi`, per `checkpoints` (ascending, from
/// `plCheckpoints`) -- the LAST checkpoint at or before `bi`. Port of Python's `_pl_at`.
func plAt(_ checkpoints: [(blockIndex: Int, pl: Double)], _ bi: Int) -> Double {
    var pl = checkpoints[0].pl
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        pl = cp.pl
    }
    return pl
}

/// `[(blockIndex, hmLines, fmLines), ...]` in ascending block order -- the `.hm`/`.fm` pair
/// IN FORCE from that block onward. Mirrors `mtMbCheckpoints` (same anchor, same "pair"
/// shape -- `.hm`'s own effect on the header row is gated jointly with `.mt`, see
/// `runningOps`). Port of Python's `_hm_fm_checkpoints`.
///
/// Real WS7 evidence (HMFM_PROBE, dosbox-x, register b31-dot-command-sweep): a document
/// that never touches `.mt` (stays at the factory default throughout) but sets `.hm 6`/
/// `.fm 6` mid-document (factory default is `.hm 2`/`.fm 2`) printed its header/footer at
/// TWO different PCL rows -- 35.7pt/75.6pt on the pages before the change, 12.0pt/80.4pt on
/// the pages after it -- even though `.mt` itself never moved.
///
/// Seeded at WordStar's own hardcoded defaults (2.0/2.0, WSFORMAT's own `.hm`/`.fm`
/// defaults), NOT `doc.page?.hmLines`/`fmLines` (`ParseWS.swift`'s first-occurrence
/// reading) -- HMFM_PROBE is exactly the degenerate case that distinguishes them: its
/// `.hm`/`.fm` appear only ONCE, mid-document, so "first occurrence wins" reads that single
/// occurrence as the document's global default and would otherwise hand it back for block 0
/// too, retroactively applying the mid-document value to the pages that printed before the
/// command was ever reached. See `plCheckpoints`'s doc comment -- same fix, same reason.
///
/// Same hand-built-fixture fallback as `plCheckpoints`: no `.hm`/`.fm` entry anywhere in
/// `dotPositions` reseeds from `doc.page?.hmLines`/`fmLines` after the walk.
func hmFmCheckpoints(_ doc: Document) -> [(blockIndex: Int, hm: Double, fm: Double)] {
    var hm = 2.0    // WSFORMAT's own hardcoded default: ".HM ... Default is 2."
    var fm = 2.0    // WSFORMAT's own hardcoded default: ".FM ... Default is 2."
    var checkpoints: [(blockIndex: Int, hm: Double, fm: Double)] = [(0, hm, fm)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "HM" || upperName == "FM" else { continue }
        guard let (value, unit) = parseDotNumber(arg) else { continue }
        let resolved = resolveLinesArg(value, unit)
        if upperName == "HM" { hm = resolved } else { fm = resolved }
        if hm != checkpoints[checkpoints.count - 1].hm || fm != checkpoints[checkpoints.count - 1].fm {
            checkpoints.append((dp.blockIndex, hm, fm))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].hm = doc.page?.hmLines ?? 2.0
        checkpoints[0].fm = doc.page?.fmLines ?? 2.0
    }
    return checkpoints
}

/// `(hmLines, fmLines)` in force at block index `bi`, per `checkpoints` (ascending, from
/// `hmFmCheckpoints`) -- the LAST checkpoint at or before `bi`. Port of Python's
/// `_hm_fm_at`.
func hmFmAt(_ checkpoints: [(blockIndex: Int, hm: Double, fm: Double)], _ bi: Int) -> (hm: Double, fm: Double) {
    var hm = checkpoints[0].hm
    var fm = checkpoints[0].fm
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        hm = cp.hm
        fm = cp.fm
    }
    return (hm, fm)
}

/// `[(blockIndex, pnValue), ...]` in ascending block order -- a `.pn` RE-ANCHORS the
/// automatic page-number sequence starting on the page it appears on (WSFORMAT: ".PN ...
/// Sets the starting page number"), it does not merely set the document's own opening
/// number once. Port of Python's `_pn_checkpoints`.
///
/// Real WS7 evidence (PN_PROBE, dosbox-x, register b31-dot-command-sweep): printed page 1
/// as "10", page 2 as "11" (a `.pn 10` up front, incrementing normally), then page 3 as
/// "500" and page 4 as "501" once a mid-document `.pn 500` was reached -- the SECOND value
/// re-anchors the count from the page it lands on, exactly like the first.
///
/// Seeded at 1 (WordStar's own hardcoded starting number), same reason `plCheckpoints`/
/// `hmFmCheckpoints` seed at the hardcoded default rather than `doc.page?.pnStart` -- see
/// their doc comments. Same hand-built-fixture fallback too: no `.pn` entry anywhere in
/// `dotPositions` reseeds from `doc.page?.pnStart`.
func pnCheckpoints(_ doc: Document) -> [(blockIndex: Int, pn: Int)] {
    var checkpoints: [(blockIndex: Int, pn: Int)] = [(0, 1)]
    for dp in doc.dotPositions {
        guard let (name, arg) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        guard upperName == "PN" else { continue }
        guard let (value, _) = parseDotNumber(arg) else { continue }
        let intValue = Int(value)
        if intValue != checkpoints[checkpoints.count - 1].pn {
            checkpoints.append((dp.blockIndex, intValue))
        }
    }
    if checkpoints.count == 1 {
        checkpoints[0].pn = doc.page?.pnStart ?? 1
    }
    return checkpoints
}

/// `[pageNumber, ...]`, one per `pages` (ascending, from `docToPagelines`) -- walks the
/// pages in order, re-anchoring to a `.pn` checkpoint's own value on whichever page its
/// block index first lands on (WordStar's own "sets the number of the page it appears
/// on"), otherwise continuing the previous page's number by one. A page with no
/// `bi`-carrying line at all (should not happen for real content, but a synthetic/
/// degenerate page is handled rather than crashed on) just continues the count. Port of
/// Python's `_resolve_page_numbers`.
///
/// A checkpoint is consumed (matched to a page) at most once, by the FIRST page whose own
/// block range reaches it -- `appliedBi` tracks the highest checkpoint block index already
/// used, so a checkpoint sitting mid-page is applied to THAT page (not the next one) and
/// never re-applied to a later page that also happens to satisfy `cp.blockIndex <=
/// pageMaxBi`.
func resolvePageNumbers(_ checkpoints: [(blockIndex: Int, pn: Int)], _ pages: [Page]) -> [Int] {
    var numbers: [Int] = []
    var current: Int?
    var appliedBi = -1
    for pg in pages {
        let pageMaxBi = pg.compactMap(\.bi).max()
        var candidate: (blockIndex: Int, pn: Int)?
        if let pageMaxBi {
            for cp in checkpoints where appliedBi < cp.blockIndex && cp.blockIndex <= pageMaxBi {
                candidate = cp     // last match in range wins
            }
        }
        if let candidate {
            appliedBi = candidate.blockIndex
            current = candidate.pn
        } else if current == nil {
            current = checkpoints[0].pn
        } else {
            current! += 1
        }
        numbers.append(current!)
    }
    return numbers
}

/// `[(blockIndex, enabled), ...]` ascending -- whether WordStar's AUTOMATIC page number
/// (the one `.pc` positions; WSFORMAT.WS's own text: ".PC ... active only when the
/// footers are not in use and page numbering is turned on") is ON from that block
/// onward. Mirrors `pnCheckpoints`'s shape exactly (same `dotPositions` anchor, "last
/// checkpoint at or before this block wins" contract, via `pgnumAt` below). Port of
/// ctrl-kd's `_pgnum_checkpoints` (pdf.py, register b31, E3 item 2, 2026-08-25).
///
/// Seeded OFF -- WordStar's own default state, MEASURED (dosbox-x, 16 probes): a
/// document that never touches `.pn`/`.pg`/`.op`/`.pc` at all prints NO automatic
/// number, at any column (`.pc` alone does not turn it on either). `.pn` (ANY
/// occurrence -- WSFORMAT: "sets the starting page number"; measured: a bare `.pn 5`
/// with no header/footer/`.pg` at all still printed a bottom-of-page number) and `.pg`
/// (WSFORMAT's own documented re-enable after `.op`) both turn it ON; `.op` turns it
/// OFF. Genuinely stateful mid-document (measured: page 1 under `.op` silent, pages
/// after a mid-document `.pg` numbered, no `.pn` anywhere in that probe at all -- `.pg`
/// alone activates it).
///
/// This is the engine for `EmitOptions.PageNumberMode.auto` (the default): the
/// document's own dot commands decide, byte-identical to every existing capture/oracle
/// for the overwhelming majority of documents that never touch any of these four
/// commands. `.on`/`.off` bypass this entirely -- see `emitPDF`'s own call site
/// (PDFWriter.swift).
func pgnumCheckpoints(_ doc: Document) -> [(blockIndex: Int, on: Bool)] {
    var checkpoints: [(blockIndex: Int, on: Bool)] = [(0, false)]
    for dp in doc.dotPositions {
        // No word-boundary check: a real WS7 file overwhelmingly writes `.pn0`/`.pn22`/
        // `.pg` with NO space before a following digit, and `dotCommandNameAndArg`'s own
        // 1-3-ASCII-letter scan (the same one every other checkpoint walk in this file
        // uses) already stops at the first non-letter, so `.PN0` correctly yields name
        // "PN" -- no `\b`-style trap to avoid here the way ctrl-kd's regex port had to
        // name explicitly.
        guard let (name, _) = dotCommandNameAndArg(Array(dp.text.utf8)) else { continue }
        let upperName = String(decoding: name.map(asciiUppercased), as: UTF8.self)
        let value: Bool
        if upperName == "PN" || upperName == "PG" {
            value = true
        } else if upperName == "OP" {
            value = false
        } else {
            continue
        }
        if value != checkpoints[checkpoints.count - 1].on {
            checkpoints.append((dp.blockIndex, value))
        }
    }
    return checkpoints
}

/// Whether the automatic page number is ON at block index `bi`, per `checkpoints`
/// (ascending, from `pgnumCheckpoints`) -- the LAST checkpoint at or before `bi`,
/// mirroring `plAt`/`hmFmAt`. Port of ctrl-kd's `_pgnum_at`.
func pgnumAt(_ checkpoints: [(blockIndex: Int, on: Bool)], _ bi: Int) -> Bool {
    var on = checkpoints[0].on
    for cp in checkpoints {
        if cp.blockIndex > bi { break }
        on = cp.on
    }
    return on
}

/// Measured (dosbox-x, register b31, E3 item 2, 2026-08-25): the automatic page
/// number's LEFT edge sits at column `(poCols + pcCol - 1)` in the SAME 10-CPI frame
/// `.po`/`.lm`/`.rm`/`.pm` share (`pdfPtPerCol`), regardless of how many digits the
/// number itself has (a 3-digit number landed at the IDENTICAL x as a 1-digit one at
/// the same `.pc`/`.po` pair -- LEFT-anchored, not right-anchored or centred on the
/// string itself). Confirmed relative to `.po`, not absolute from the page edge: two
/// independent `.po` values both fit the SAME formula exactly once `.po` is added in; a
/// plain `N * 7.2pt` (ignoring `.po`) does not.
///
/// `.pc 0` (WSFORMAT.WS's own text: "If the column specified is 0, then the page
/// number is centered between the margins in effect") and `.pc` NEVER DECLARED AT ALL
/// produced the IDENTICAL position in every probe -- "unset" and "0" are the SAME
/// internal state. But the manual's own "centered between the margins" claim does NOT
/// hold in this install/driver as measured: `.rm 40` with `.pc 0` landed at the
/// IDENTICAL x as `.pc 0` at this install's own default `.rm` -- no dependency on `.rm`
/// at all, twice confirmed. Measured bytes beat manual prose (`printedLeft`'s own
/// precedent, same doctrine): the "0/unset" case resolves to this FIXED measured
/// column instead of a dynamically computed lm/rm midpoint. Fit from two independent
/// `.po` values (7.0 exactly, 20.0 exactly) with zero decipoint residual either way --
/// not a guess, and not (yet) traced to a WSCHANGE factory constant, so it may be THIS
/// install's own customisation the same way its `.po` 7.0 (vs the manual's 8.0) is;
/// flagged, not hidden. Port of ctrl-kd's `_AUTO_PAGENO_DEFAULT_COL`.
let autoPagenoDefaultCol = 33.5

/// Left edge (points) of the automatic page number's text, from `.po`/`.pc` -- see
/// `autoPagenoDefaultCol`'s doc comment for the formula's own measurement. `pcCol` 0 or
/// unset (both measured identical) uses the fixed default; an explicit non-zero `.pc N`
/// overrides it. Port of ctrl-kd's `_auto_pageno_x_pt`.
func autoPageNumberXPt(_ doc: Document) -> Double {
    let po = doc.page?.poCols ?? 8.0    // WS7 manual's own default page offset --
                                        // `ParseWS.swift`'s `defaultPoCols`, private there
    let pcRaw = doc.page?.pcCol
    let pc = (pcRaw != nil && pcRaw != 0) ? Double(pcRaw!) : autoPagenoDefaultCol
    return (po + pc - 1) * pdfPtPerCol
}

/// Top-of-text offset in points for printed mode: the bottom edge of WS7's reserved
/// TOP-MARGIN-PLUS-HEADER-MARGIN zone (lines at 6 LPI -> 12pt each; the defaults `.mt 3` +
/// `.hm 2` = 5 lines = 60pt). Print streams (no `page` meta) keep the fixed 36pt — their own
/// top-margin blanks are in the data (minus the machine-margin strip in `docToPagelines`).
/// Clamped inside the page so garbage `.mt`/`.hm` from a misdetected binary degrades to an
/// ugly page, never an absurd coordinate space. Deliberately measured against the FIXED
/// `PDFMetrics.lead` (not `printedLead(doc)`) — this is a page-geometry clamp, not a
/// line-spacing one.
///
/// NO LONGER SPECIAL-CASED FOR HEADERED DOCUMENTS (round 26 wave 3, ctrl-kd's
/// `fidelity_gate.py` Finding A — reversing the headerless scoping this function used to
/// carry). A genuine WS7 capture WITH a real `.h1` header (-README, ws7-prints/v1) contradicts
/// the WS4-era reading this function's SCOPED TO HEADERLESS DOCUMENTS reasoning rested on:
/// -README's OWN header prints starting page 2 (page 1 has none — WordStar suppresses a
/// running head on the document's first page) at PCL baseline y=35.7pt (`.mt` alone, matching
/// `runningOps`'s OWN placement, unaffected by this function), but the BODY text on those SAME
/// headered pages starts at y=71.7pt — byte-for-byte the SAME offset the headerless corpus
/// measures ((.mt 3 + .hm 2)*12 + 12pt baseline = 72pt, 0.3pt residual). `.hm` is reserved
/// before the body whether or not a header actually prints on that page — the header's OWN row
/// (`runningOps`, computed independently from `.mt`/`.hm`/the header's own line count) and the
/// body's start offset (this function) are two separate quantities the old headers/footers
/// branch conflated.
///
/// `.hm` ONLY ADDS WHEN `.mt` IS THE DOCUMENT DEFAULT (`mtSource == .default`, `ParseWS.swift`'s
/// own file-vs-default provenance tag — the SAME field `styleLeadPt`'s `.lh` guard already
/// reads for a parallel reason). PREVIEW.WS (ws7-prints/v1) is the negative oracle: it declares
/// its OWN `.mt` explicitly (`mtSource == .file`, 4.98 lines — a WSFORMAT-style non-integer
/// `.mt`, likely typed as a decimal inch value), and its WS7 capture's first body baseline
/// (88.5pt) matches `.mt` ALONE (round(4.98*12)=60, +14.4+14.4 for this headerless document's
/// own two leading blank lines = 88.8pt, 0.3pt residual) — NOT `.mt`+`.hm` (83.76 -> 84, which
/// would land at 112.8, over 24pt off). Every oracle behind the unconditional `.mt`+`.hm`
/// finding above (the whole headerless corpus, plus -README's own headered pages) has
/// `mtSource == .default` — an author who never touched `.mt` gets the print driver's own
/// factory PAIR (`.mt 3` shipped together with `.hm 2`, WSCHANGE's factory-defaults table),
/// but one who explicitly set their own top margin does not also inherit that pairing's second
/// half.
///
/// WSCHANGE's factory-defaults table (Installing and Customizing, WS7 manual, p.2-46/2-45)
/// independently confirms both defaults used here: "Top margin ... 0.50"" and "Header margin
/// ... 0.33"" (0.33in = 23.76pt = 1.98 ~ 2 lines, matching the default `hmLines` already
/// coded). Port of Python's `_printed_top` (pdf.py, ctrl-kd 2.0.0/round 26 wave 3, refined
/// same day on PREVIEW.WS evidence).
func printedTop(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.topPrinted }
    let pageHeight = resolvedPrintedPageHeight(doc)
    var reserve = page.mtLines
    if page.mtSource == .default {
        reserve += page.hmLines
    }
    return max(0, min(roundHalfToEven(reserve * 12), pageHeight - PDFMetrics.lead))
}

/// Bottom-of-page reserve for `layoutPrintedPages`'s FOOTNOTE area (never the endnote
/// continuation — endnotes are never queued through this function's own pagination, they
/// simply continue this area's sequential flow and inherit its position for free), in
/// points — Finding 2 (b26-print-fidelity-2). Port of Python's `_printed_notes_reserve_pt`.
///
/// The area used to be flow-appended right after the body (whatever y the body happened to
/// end at), correct only when the body already fills the page (LYING.WS, every page) — on a
/// short page (-SCREEN.WS, a 1-page doc whose body ends mid-page) that put the area
/// mid-page, colliding with the WORDSTAR.PIX image; real WS7 prints it at the physical
/// bottom.
///
/// Measured against TWO independent WS7 captures (ws7-prints/v1), both at every
/// page-geometry default (`.mb` 8 lines): -SCREEN.pcl's footnote line "1. Footnote" at
/// y=708pt (dash rule at 684pt) and LYING.pcl's "1.Did not take the prize." also at y=708pt
/// (dash rule also 684pt — LYING's page is full, so its flow-appended position and this
/// anchor coincide). Both land on the exact same reserve — 792 - 708 = 84pt — with ZERO
/// decipoint residual. 84pt is (`.mb` - 1) * 12 = 7 lines, ONE LINE inside the raw `.mb`
/// reserve (8 lines = 96pt would put the footnote line 12pt too high, at 696pt) — the same
/// "one line's own lead" adjustment `printedTop` applies at the OTHER end of the page (a
/// baseline sits one line's lead INSIDE its margin reserve, not flush with its outer edge),
/// mirrored here for the last line instead of the first.
///
/// JUDGMENT CALL, recorded rather than hidden: ws7-prints/v1 has no document with an
/// EXPLICIT non-default `.mb` to confirm the `- 1` line scales correctly rather than being
/// a fixed offset; both measured documents share the same default. Scaling with `.mb`
/// (rather than a flat 84pt constant) is the more defensible read of a page-layout engine's
/// intent, but is not independently confirmed — if a future capture contradicts it, that is
/// where to look first.
func printedNotesReservePt(_ doc: Document) -> Double {
    guard let page = doc.page else { return 84.0 }   // print streams: no `.mb` to read;
                                                      // the measured default constant
    return max(0.0, (page.mbLines - 1) * 12.0)
}

/// Baseline-to-baseline distance in points for printed mode. Port of Python's
/// `_printed_lead` (pdf.py, ctrl-kd 1.3.0): `.lh` is 1/48in units, a point is 1/72in ->
/// `lh48 * 1.5`. Default `.lh 8` IS the 12pt lead this emitter always used. Print streams
/// (no `page` meta) keep the fixed lead.
/// Only the DEFAULT: `.lh` is stateful and a line that was set at a different leading carries
/// its own (`Line.lead48` -> `PageLine.lead`), which `pageStream` honours per line. This is
/// what a line WITHOUT one falls back to, and what page CAPACITY is still computed at (see
/// `printedCap`).
func printedLead(_ doc: Document) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.lead) }
    return leadPt(page.lh48) ?? Double(PDFMetrics.lead)
}

/// `[block index in doc.blocks: lead48]` for every printed content block (`.para` kind,
/// headings included — `.pagebreak`/`.condpage` sentinels carry no lines and are
/// skipped), giving RTF's own per-paragraph `\sl` (`rtfBlockLead48`) the SAME resolved
/// leading this file's own PDF page-building already uses per PHYSICAL line
/// (`docToPagelines`'s printed branch: `.lh` override, else a paragraph STYLE's own
/// `lineHeightVMI`-derived leading via `styleLeadPt`/`enteringLeadPt`, else a WS5+
/// font-block's own proportional size via `fontLeadPt`, else the document default).
/// Ruling 2026-08-26 (mirrored from ctrl-kd ebc2939, register row, b33 field notes N2):
/// Printed/Native RTF previously emitted ONE flat `\sl` for the whole document — a 16pt
/// Title/Author style (WS7 style vmi -2/auto, real leading 1.2x16=19.2pt) was squeezed
/// onto the document's plain 12pt body lead, clipping in Word/TextEdit. This ports the
/// READ side of that same per-line algorithm to block granularity — RTF's `\sl` is a
/// PARAGRAPH property with no per-line control word, so a block collapses to its own
/// FIRST REAL (non-blank) physical line's resolved value, exactly the "ceiling of what
/// RTF can express per paragraph" `rtfBlockLead48`'s own doc comment already named (a
/// `.lh` change strictly mid-paragraph was already out of scope there, unchanged here).
/// `fontLeadState` is still threaded across EVERY physical line of the WHOLE document in
/// source order, blank lines and non-first real lines included, even though only one
/// resolved value per block is kept — an inline font-block change inside a later line
/// must still update the carried state exactly as `docToPagelines` computes it, or a
/// LATER block's own first line would resolve against a stale governing size. No
/// existing PDF consumer of `leadPt`/`styleLeadPt`/`enteringLeadPt`/`fontLeadPt` is
/// touched — this only calls them, read-only, in the same per-line order and under the
/// same gates they already use. Port of `pdf.resolved_printed_leads_48`.
func resolvedPrintedLeads48(_ doc: Document) -> [Int: Double] {
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.fonts.contains { $0.proportional } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    let defaultLeadPt = printedLead(doc)
    var out: [Int: Double] = [:]
    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak || block.kind == .condpage { continue }
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        var firstLineOfBlock = true
        var resolvedPt: Double? = nil
        for line in block.lines {
            let isBlank = !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
            var ownLead = leadPt(line.lead48)
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            if !isBlank { firstLineOfBlock = false }
            if let styleLead, line.lead48 == nil || line.lead48 == defaultLh48 {
                ownLead = styleLead
            }
            if ownLead == nil, fontLeadOk {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            if resolvedPt == nil, !isBlank {
                resolvedPt = ownLead ?? defaultLeadPt
            }
        }
        if resolvedPt == nil {
            // every line in this block is blank (a pure spacer block) — no REAL line
            // ever set resolvedPt above. Fall back to the block's own first line, raw
            // (no entering-floor: there is no real glyph here to protect from clipping
            // into whatever came before), same `raw: true` doctrine as a blank line
            // mid-block.
            if let line = block.lines.first {
                var ownLead = leadPt(line.lead48)
                let styleLead = styleLeadPt(block, doc, raw: true)
                if let styleLead, line.lead48 == nil || line.lead48 == defaultLh48 {
                    ownLead = styleLead
                }
                if ownLead == nil, fontLeadOk {
                    ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                         state: &fontLeadState)
                }
                resolvedPt = ownLead ?? defaultLeadPt
            } else {
                resolvedPt = defaultLeadPt
            }
        }
        out[bi] = resolvedPt! / 1.5      // points -> 1/48in, inverse of leadPt
    }
    return out
}

/// The `.sr` sub/superscript roll for printed mode, in points — ONE document-wide value
/// (b24 round 17, RULINGS-LEDGER row 3, register C22). Port of Python's `_printed_roll_pt`.
/// Not stateful per-line like `.lh`: `.sr` re-selects mid-document have no evidence behind
/// per-position tracking the way `.lh`'s own archive banner example does — the ruling
/// itself only asks that the file's OWN roll finally be read at all (previously byte-
/// identical across `.sr 0`/`.sr 40`/absent). Default 3 (WSFORMAT's own stated `.sr`
/// default, 3/48in) whenever the file never sets it, converted the same way every other
/// 1/48in value is (round 6: 1/48in = 1.5pt).
func printedRollPt(_ doc: Document) -> Double {
    (doc.formatting.subSuperRoll48 ?? 3.0) * 1.5
}

/// Print columns (10 CPI) -> points: 72pt/in / 10 col/in = 7.2pt/col — the SAME unit
/// `.lm`/`.rm`/`.pm`/`.po` all share, and the exact value `MAX_COLS`'s own line-wrap math
/// already derives from (size 12 * 0.6 == 7.2 at the default size).
let pdfPtPerCol = 7.2

/// First-line indent in points from `.pm` — b24 round 17 (RULINGS-LEDGER row 5/7), mirrors
/// `rtfPMFiTwips` (round 6), relative to li=0: Printed PDF has no per-block `.lm`/`.rm`
/// margin of its own yet (that gap is Printed RTF's own ledger row 8, a SEPARATE item),
/// so the baseline this indent sits against is the document's own left edge — the same
/// li=0 an unstyled/WS4 Printed RTF paragraph already gets from the SAME round 6 code.
/// `nil` when the block never set `.pm`. Port of Python's `_printed_pm_fi_pt`.
func printedPMFiPt(_ block: Block) -> Double? {
    block.paraMargin.map { $0 * pdfPtPerCol }
}

/// `(sb, sa)` in points from WordTsar's own `.psa`/`.psb` extensions — b24 round 17
/// (RULINGS-LEDGER row 5/7), mirrors `rtfDocSpacingTwips` (round 6) exactly, converted to
/// points via the document's own DEFAULT leading (the same quantity `PageLine.lead`
/// already carries) instead of twips. `(nil, nil)` when neither command was ever seen.
/// Port of Python's `_printed_doc_spacing_pt`.
func printedDocSpacingPt(_ doc: Document) -> (sb: Double?, sa: Double?) {
    guard doc.spaceBeforeLines != nil || doc.spaceAfterLines != nil else { return (nil, nil) }
    let leadPt = printedLead(doc)
    let sb = doc.spaceBeforeLines.map { $0 * leadPt }
    let sa = doc.spaceAfterLines.map { $0 * leadPt }
    return (sb, sa)
}

/// Type size in points for printed mode, from `.cw`: character width in 1/120in units,
/// and Courier advances 0.6em, so a pitch of cw/120in per character IS a
/// `(cw*72/120)/0.6 = cw*1.0` point font. The default `.cw 12` (10 CPI pica) IS the 12pt
/// this emitter always used; `.cw 10` is 12 CPI elite at 10pt. Rounded to whole points
/// (the `Tf` operator is written as an integer, as it always has been), floored at 1.
/// Print streams keep the fixed `SIZE`. Port of Python's `_printed_size` (pdf.py, ctrl-kd
/// 2.0.0).
func printedSize(_ doc: Document) -> Int {
    guard let page = doc.page else { return PDFMetrics.size }
    let cw = page.cw120
    return cw > 0 ? max(1, roundHalfToEven(cw)) : PDFMetrics.size
}

/// Left edge of text in points for printed mode, from `.po`: "the number of print
/// columns from the left edge of the paper to the left margin of text. The current
/// setting of character width (.CW) determines the actual amount of indentation" — but
/// real WS7 output contradicts that clause: PCL captures keep `.po` at a FIXED
/// 7.2pt/column at BOTH 10cpi and 12cpi (dx experiment 2026-08-20: ESC&aH = 576dp for
/// `.po 8` at either pitch), matching `pdfPtPerCol` exactly as `.lm`/`.rm`/`.pm` already
/// do. Measured bytes beat manual prose. The default `.po 8` (the WS7 manual's ".8 inch"
/// at 10 CPI) lands at 57.6pt — NOT the old fixed 72pt `MARGIN`, which was this emitter's
/// guess, not WordStar's. Print streams keep `MARGIN`: their offset spaces, where a
/// driver emitted them, are in-band. Clamped inside the page for garbage `.po` from
/// misdetected binaries. Port of Python's `_printed_left` (pdf.py, ctrl-kd 2.0.0).
///
/// This is the DOCUMENT DEFAULT — the file's first `.po`, exactly like `printedLead`'s
/// document default. A line whose own `.po` differs (`Line.poCols`, register b31 —
/// LJ6DTP.WS moves `.po` to 2.5" for its page-4 checkerboard) overrides this at layout
/// time in `resolvePrintedBody`/`resolvePlainBody` (`PageLine.left`), the same `.lh`-
/// stateful shape `PageLine.lead` already carries.
func printedLeft(_ doc: Document, size: Int) -> Double {
    guard let page = doc.page else { return Double(PDFMetrics.margin) }
    return resolveLeftPt(page.poCols, size: size)
}

/// `.po` print columns -> left edge in points, clamped inside the page — the conversion
/// `printedLeft` (the document DEFAULT) and a line's own override (`Line.poCols`, stateful
/// like `.lh`; register b31) both need, factored out so a line that never overrides `.po`
/// resolves IDENTICALLY to the document default it would otherwise have inherited. Port of
/// Python's `_resolve_left_pt`.
func resolveLeftPt(_ poCols: Double, size: Int) -> Double {
    let left = poCols * pdfPtPerCol
    return max(0.0, min(left, Double(PDFMetrics.pageWidth) - Double(size) * 0.6))
}

/// Total lines the footnote area occupies: the fixed 3-line header (blank / 20-dash
/// separator / blank — VMI 240 = one blank line at 6 LPI) plus each entry's own lines plus
/// one blank line between entries (VMI 240 "between notes"). 0 when there's nothing to
/// show at all. Port of Python's `_area_size`.
private func areaSize(_ entries: [[PageLine]]) -> Int {
    guard !entries.isEmpty else { return 0 }
    return 3 + entries.reduce(0) { $0 + $1.count } + (entries.count - 1)
}

/// The admitted area as page lines: blank / separator / blank, then the entries with one
/// blank between. Port of Python's `_render_area` — the same line sequence `fitFooter`'s
/// bottom-of-page path produced (blank, rule, then a blank ahead of each note).
private func renderArea(_ entries: [[PageLine]]) -> [PageLine] {
    guard !entries.isEmpty else { return [] }
    var out: [PageLine] = [[], [Span(text: String(repeating: "-", count: 20))], []]
    for (k, e) in entries.enumerated() {
        if k > 0 { out.append([]) }
        out.append(contentsOf: e)
    }
    return out
}

/// Max lines the footnote area may occupy on a page where `bodyLen` line units are already
/// committed. Always bounded by the room actually left on the page (`cap - bodyLen`) —
/// entries can never push the total past cap. Additionally bounded by
/// `cap - footnoteFloor` on every page EXCEPT the one holding the document's last line of
/// regular text, where the floor's protection lifts (the WS5 manual's stated exception).
///
/// `bodyLen` (b26 round 26 wave 3, ctrl-kd's `fidelity_gate.py` Unit A) can now be
/// FRACTIONAL — a styled body line costs its own lead as a fraction of the document
/// default, see `layoutPrintedPages`'s `lineCost` — but the footnote AREA itself is still
/// whole LINES (its own text carries no per-style leading; `areaSize`/`admitFootnotes`
/// count it that way). Floored, never rounded, so a fractional line of room already spent
/// by the body never gets credited as a whole line the footnote area can use. The tiny
/// epsilon guards against float accumulation (many fractional per-line costs summed)
/// landing just under a whole number that should round up, not down. Port of Python's
/// `_footnote_ceiling`.
private func footnoteCeiling(cap: Int, bodyLen: Double, isTerminal: Bool) -> Int {
    let room = Int(Double(cap) - bodyLen + 1e-9)
    return isTerminal ? room : min(room, cap - footnoteFloor)
}

/// Move whole/partial note-chunks from the FRONT of `queue` into `entries` (mutating both)
/// until the footnote area would exceed `ceiling` lines. A chunk that only partly fits is
/// split: the part that fits joins `entries`, and the remainder stays queued behind a
/// `...Continued...` marker, ready to resume on a later page's area — this is the only
/// place a note's text is ever cut. Port of Python's `_admit_footnotes`, including its
/// hang guard: splitting costs the NEXT page one `...Continued...` line, so a split only
/// makes net progress when at least 2 lines fit; when the page cannot even manage that AND
/// the area is still empty, two lines are forced through — a page that overflows slightly
/// beats a hang or lost text.
// internal (not private): the progress invariant is unit-tested.
internal func admitFootnotes(
    _ entries: inout [[PageLine]], _ queue: inout [QueuedNote], ceiling: Int
) {
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
        let split: Int
        if room >= 2 {
            split = room
        } else if entries.isEmpty {
            split = min(chunk.count, 2)             // forced progress, per the doc above
        } else {
            break                                   // defer: next page starts empty
        }
        entries.append(Array(chunk.prefix(split)))
        // However many of `split` came from the synthetic `...Continued...` line (at most
        // one, always first) don't count against the note's own remaining text.
        let markerTaken = queue[0].needsContinuedMarker ? min(split, 1) : 0
        queue[0].remaining.removeFirst(min(split - markerTaken, queue[0].remaining.count))
        if queue[0].remaining.isEmpty {
            queue.removeFirst()
        } else {
            queue[0].needsContinuedMarker = true
        }
        break
    }
}

/// IR -> pages, WordStar's own way: verbatim body lines, a page-bottom footer for footnotes
/// and annotations that grows to fit (splitting across pages when it can't, per
/// `admitFootnotes`), and endnotes collected with no heading at the very end. See the
/// section comment above for the rule numbering this follows.
private func layoutPrintedPages(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [Page] {
    let items = resolvePrintedBody(doc, pixResults: pixResults, pictures: pictures,
                                   sentenceSpacing: sentenceSpacing)
    let width = PDFMetrics.maxCols
    let capacity = printedCap(doc)
    // b24 round 22 (closing round 19's documented scope cut): an embedded image
    // PageLine (built by `resolvePrintedBody`) costs its own height in
    // default-lead-sized lines against this paginator's line-count budget — the
    // image's vertical footprint enters the page-capacity model the same way `.lh`
    // does in `resolvePlainBody`'s points model, just quantised to this algorithm's
    // own line unit. Port of Python's `_line_cost` (ceil(h_pt / default_lead)).
    //
    // This algorithm's whole budget (`capacity`, `areaSize`, the footnote ceiling) is
    // denominated in LINE units at the document's DEFAULT lead — correct for the
    // footnote area itself (its own text carries no per-style leading), wrong for BODY
    // text once a WS7 paragraph STYLE governs a line's real leading (b26 round 26 wave
    // 3, ctrl-kd's `fidelity_gate.py` Unit A). A body line now costs its OWN lead as a
    // FRACTION of the default lead — 1.0 for a line at the document default
    // (byte-identical pagination for every document that never varies leading, which is
    // every document this algorithm's fixed-`1` cost was ever measured against), more
    // or less than 1.0 for a line whose style set a bigger or smaller lead — the same
    // `own_lead / default_lead` conversion `resolvePlainBody`'s already point-based main
    // loop uses (its points budget is the identical quantity in points; this keeps that
    // page's true physical capacity while staying in this function's existing line
    // unit, so `areaSize`/`admitFootnotes`/`footnoteCeiling` need no change of their
    // own). MEASURED against LYING.pcl: this document undercounted every page (55
    // nominal lines actually spending 777.6pt of a 648pt budget — 129.6pt, 10.8
    // default-lead lines, of real overflow per page) before this fix; the gate went
    // from 3 engine pages (WS7: 4) to matching.
    //
    // An image PageLine's `.lead` (round 26 wave 3, fidelity_gate.py Finding A/C) is
    // ALREADY the RESERVED PLACEHOLDER block's height in points — `pixReservedAdvance`,
    // computed once at `resolvePrintedBody` build time — not the raster's own continuous
    // pixel height, so it takes the identical `ownLead / defaultLead` conversion every
    // other line here does; a prior version of this function re-derived a cost from the
    // raster's raw height directly (`ceil(heightPt / defaultLead)`), double-guessing a
    // number `resolvePrintedBody` had already resolved correctly and, for a pix tag with
    // few or no reserved blank lines, wildly OVER-costing the page-capacity budget
    // relative to what `pageStream` actually spends drawing it — the leading suspect
    // behind -SCREEN's spurious page-2 overflow before this fix.
    let defaultLead = printedLead(doc)
    func lineCost(_ line: PageLine) -> Double {
        let ownLead = line.lead ?? defaultLead
        return ownLead / defaultLead
    }
    // Finding 2 bottom-anchor geometry (see `printedNotesReservePt`): constant for the
    // whole document, computed once.
    let notesTop = Double(printedTop(doc))
    let notesPageH = Double(resolvedPageHeight(doc, printed: true))
    let notesReserve = printedNotesReservePt(doc)
    // Finding 4 (b26 visual pass): see `notesMarkerPadCols` — computed ONCE for the
    // footnote/annotation area below AND the endnote section at the end of this
    // function, so a document whose footnotes and endnotes land on the same page
    // agree on one shared column.
    let padCols = notesMarkerPadCols(doc)

    var queue: [QueuedNote] = []
    var pages: [Page] = []
    var idx = 0
    // round 26 wave 3 (fidelity_gate.py Finding C): the LAST page built below, and how
    // many `capacity`-units of it are already spent — Python's `_paginate_printed_notes`
    // return value, threaded here instead since this port folds that helper and
    // `_endnote_pages` into one function. Consulted only by the endnote section at the
    // very end; every page-append site below keeps it current. Initialised to `capacity`
    // (Python's `last_page_cost = cap`) so an empty `items` stream (no `pages` at all)
    // reports "no room", matching `pages.last == nil` deciding the same thing either way.
    var lastPageCost = Double(capacity)
    // round 27 (b28 note 6): whether the LAST page appended below ends with a footnote
    // AREA or with plain BODY text. The endnote section at the end needs the distinction
    // to decide whether a blank line precedes the first endnote — see its own comment for
    // the WS7 measurements. Python's `_paginate_printed_notes` third return value.
    var lastPageHasArea = false

    // Python's `last_idx`: the last stream item carrying real ink (an image, or any
    // non-blank text). The page that admits it holds the document's last line of regular
    // text, so `footnoteCeiling`'s floor protection lifts there (the WS5 manual's stated
    // exception) and the area may grow to the whole remaining page.
    var lastIdx = -1
    for (i, item) in items.enumerated() {
        if case .line(let line, _) = item,
           line.image != nil
               || line.spans.contains(where: { !$0.text.allSatisfy { $0 == " " || $0 == "\t" } }) {
            lastIdx = i
        }
    }

    while idx < items.count {
        var body: [PageLine] = []
        var bodyLen = 0.0                        // in line units, images may cost > 1;
                                                  // a styled body line may cost a fraction
        var entries: [[PageLine]] = []           // note chunks ADMITTED to this page's area
        var isTerminal = false
        // Carry-over first: whatever a previous page's area couldn't hold gets this
        // page's area before any new reference queues behind it.
        admitFootnotes(&entries, &queue,
                       ceiling: footnoteCeiling(cap: capacity, bodyLen: bodyLen,
                                                isTerminal: isTerminal))
        bodyLoop: while idx < items.count {
            switch items[idx] {
            case .pageBreak:
                idx += 1
                break bodyLoop
            case .condPage(let n):
                // `.cp n` — break ONLY if fewer than n lines remain. Measured on WordStar 4
                // (2026-08-03): exactly n remaining is enough room and does NOT break, so
                // the test is strictly `remaining < n`. An empty page never breaks: that
                // would emit a blank sheet, which is what `.cp` exists to avoid.
                idx += 1
                if Double(capacity) - bodyLen < Double(n), !body.isEmpty {
                    break bodyLoop
                }
            case .line(let line, let due):
                let cost = lineCost(line)
                // Port of Python's `if body and body_len + cost + _area_size(entries) >
                // cap` admission: a body line is admitted while it fits ABOVE the area
                // already committed — which `admitFootnotes` grew incrementally, splitting
                // notes when they couldn't finish, so a reference line whose notes only
                // PARTLY fit is still admitted and its overflow continues on the next
                // page's area (rule 4). The old projected-full-footer check here demanded
                // the whole outstanding queue fit unsplit and pushed such a line to the
                // next page — its first counterexample was a 20-annotation document
                // (2026-08-18). The 3-line body floor needs no arm of its own: the
                // non-terminal ceiling caps the area at `capacity - footnoteFloor`, so the
                // first three line units always fit. The `body.isEmpty` arm is round 22's
                // over-tall admit guard: an image taller than the whole page must still be
                // admitted somewhere or this loop would never advance — a slightly
                // overflowing page beats a hang or lost content (the same doctrine
                // `fitFooter` documents).
                if !body.isEmpty, bodyLen + cost + Double(areaSize(entries)) > Double(capacity) {
                    break bodyLoop
                }
                body.append(line)
                bodyLen += cost
                if idx == lastIdx { isTerminal = true }
                idx += 1
                for ref in due {
                    queue.append(QueuedNote(
                        remaining: footerEntryLines(ref.note, doc: doc, index: ref.index,
                                                    width: width, padCols: padCols,
                                                    sentenceSpacing: sentenceSpacing),
                        needsContinuedMarker: false))
                }
                admitFootnotes(&entries, &queue,
                               ceiling: footnoteCeiling(cap: capacity, bodyLen: bodyLen,
                                                        isTerminal: isTerminal))
            }
        }

        // This paginator never replays `hfEvents` (unchanged since before this port,
        // matching Python's dedicated `_paginate_printed_notes`, also untouched): every
        // page instead carries the document's FINAL-state headers/footers, the same
        // fallback `runningOps` applies when a page's own dict is empty.
        var area = renderArea(entries)
        if !entries.isEmpty {
            // Bottom-anchor (Finding 2): the area's FIRST line (the 3-line header's
            // leading blank) gets an overridden `.lead` that lands it exactly
            // `notesReserve` above the page bottom, counting up through the area's own
            // remaining lines — rather than wherever the body's sequential flow happened
            // to leave off. `bodyY` is the body's own last baseline (top-down points):
            // `lineCost` makes `ownLead / defaultLead` exact, so `bodyLen * defaultLead`
            // is the TRUE point advance the body already spent, not an approximation.
            // Only APPLIED when it pushes the area DOWN (`override > defaultLead`, more
            // than the ordinary single-blank-line gap the flow path would use) — a full
            // page (LYING.WS) already lands within a line of the target on its own, so
            // this is a no-op there (byte-identical), and a page that somehow overflows
            // the anchor never moves backward into the body.
            let bodyY = notesTop + bodyLen * defaultLead
            let targetFirst = notesPageH - notesReserve - Double(area.count - 1) * defaultLead
            let override = targetFirst - bodyY
            if override > defaultLead {
                area[0].lead = override
            }
        }
        pages.append(Page(body + area, headers: doc.headers, footers: doc.footers))
        lastPageCost = bodyLen + Double(areaSize(entries))
        lastPageHasArea = !entries.isEmpty
    }

    // Rule 5: whatever the last body page's bottom footer couldn't hold prints at the TOP
    // of its own fresh page(s) instead of waiting for a "next page" that doesn't exist.
    // Rendered through the SAME `admitFootnotes`/`renderArea` pair as the in-page area
    // (Python renders every area through `_render_area`), so the header here is the same
    // 3 lines — blank / 20-dash rule / blank — not the 1-line separator the retired
    // `fitFooter(leadingBlank: false)` path used to emit (shape divergence from the
    // oracle, closed 2026-08-18). The ceiling is the whole page: bodyLen 0, and terminal
    // — these pages ARE the manual's stated exception.
    //
    // PROGRESS GUARD. This loop's termination used to depend entirely on its helper
    // consuming at least one queued line per call, with nothing checking that it did. On
    // 2026-07-31 a regression in the helper made it consume nothing at `capacity == 3`;
    // this loop then appended a page per pass forever, reached 15.7 GB, and stalled the
    // whole machine for 2h40m -- no crash, no OOM kill, just unbounded growth.
    //
    // A layout loop whose exit depends on a helper making progress must verify that the
    // progress happened. Two invariants, in priority order: no text is ever lost, and the
    // layout always terminates. So when a pass consumes nothing, flush everything still
    // queued onto one page and stop -- that page overflows, which is strictly better than
    // dropping text or hanging.
    while !queue.isEmpty {
        let linesBefore = queue.reduce(0) { $0 + $1.remaining.count }
        var entries: [[PageLine]] = []
        admitFootnotes(&entries, &queue,
                       ceiling: footnoteCeiling(cap: capacity, bodyLen: 0, isTerminal: true))
        let page = renderArea(entries)
        let linesAfter = queue.reduce(0) { $0 + $1.remaining.count }

        if linesAfter >= linesBefore {
            // No progress. Emit the page we just built, then flush the rest verbatim so
            // nothing is lost, and leave the loop. No Python oracle covers this
            // Swift-only safety branch (see the PROGRESS GUARD comment above); treating
            // it as "no room" (`lastPageCost = capacity`) is a deliberate, conservative
            // judgment call so endnotes never try to continue onto a page that just
            // absorbed a raw overflow dump.
            if !page.isEmpty { pages.append(Page(page, headers: doc.headers, footers: doc.footers)) }
            var flushed: [PageLine] = []
            for entry in queue {
                if !flushed.isEmpty { flushed.append([]) }
                flushed.append(contentsOf: entry.remaining)
            }
            queue.removeAll()
            if !flushed.isEmpty {
                pages.append(Page(flushed, headers: doc.headers, footers: doc.footers))
            }
            lastPageCost = Double(capacity)
            lastPageHasArea = true
            break
        }
        pages.append(Page(page, headers: doc.headers, footers: doc.footers))
        lastPageCost = Double(areaSize(entries))
        lastPageHasArea = true
    }

    // Endnotes: the true end of the document, no heading, no separator — plain pagination,
    // one blank line between entries (the same vertical rhythm as the footer area), nothing
    // before the first.
    //
    // CONTINUES the last body/footnote page when it has room (round 26 wave 3,
    // fidelity_gate.py Finding C), instead of always forcing a fresh one — not a fresh
    // 3-line area header, since this is one more entry in the SAME note area, not a new
    // section. The previous unconditional-fresh-page version put "(1) Endnote" alone on an
    // otherwise-near-empty page 2, the actual cause of -SCREEN's 2-page overflow (WS7: 1).
    // A page with NO room left (`lastPageCost >= capacity`, the overwhelmingly common
    // multi-page case) is untouched: endnotes start fresh exactly as before.
    //
    // `lastPageHasArea` (round 27, b28 note 6) decides whether a blank line precedes the
    // FIRST endnote, and it is NOT unconditional. WS7's note face is 12-point, so ONE note
    // line advances 120 decipoints — the 2026-08-20 measurement that put a blank line here
    // read the natural 240dp two-line advance as "24pt, one blank line" and generalised it.
    // Re-measured 2026-08-23 against both WS7 captures (the reference vault's WordStar/ws7-prints/v1/):
    //
    //   -SCREEN.pcl  "1. Footnote" V=7080 -> "(1) Endnote"  V=7320 = 240dp
    //                = ONE BLANK LINE, endnotes joining a FOOTNOTE AREA.
    //   TESTING.pcl  last body line     V=3765 -> "(1)This..." V=3885 = 120dp
    //                = NO BLANK LINE, endnotes following BODY TEXT.
    //   TESTING.pcl  endnote (1) V=3885 -> (2) V=4125 = 240dp = one blank line BETWEEN
    //                entries (the `if i > 0` gap below, unchanged).
    //
    // So the leading gap belongs only when the last page ends with a footnote area — it is
    // one more entry joining that area. Following plain body text the endnotes butt
    // straight up against it, which is what Jon reported in the b27 review. Port of
    // Python's `_endnote_pages` plus its `_doc_to_pagelines` call site (which page this
    // replaces vs. appends).
    let endnotes = doc.notes.enumerated().filter { $0.element.kind == .endnote }
    if !endnotes.isEmpty {
        var lines: [PageLine] = []
        for (i, entry) in endnotes.enumerated() {
            if i > 0 { lines.append([]) }
            lines.append(contentsOf: endnoteEntryLines(entry.element, doc: doc,
                                                       index: entry.offset, width: width,
                                                       padCols: padCols,
                                                       sentenceSpacing: sentenceSpacing))
        }
        // Python's `last_page and last_page_cost < cap`: `last_page` must be a REAL,
        // non-empty page (an empty Python list is falsy) as well as under-capacity.
        let canContinue = lastPageCost < Double(capacity)
            && (pages.last.map { !$0.isEmpty } ?? false)
        var page: Page
        var room: Double
        if canContinue, let last = pages.last {
            page = last
            room = Double(capacity) - lastPageCost
            if lastPageHasArea {            // see the WS7 measurements above
                lines = [[]] + lines
            }
        } else {
            page = Page([], headers: doc.headers, footers: doc.footers)
            room = Double(capacity)
        }
        var endPages: [Page] = []
        for line in lines {
            if room < 1 {
                endPages.append(page)
                page = Page([], headers: doc.headers, footers: doc.footers)
                room = Double(capacity)
            }
            page.append(line)
            room -= 1
        }
        if !page.isEmpty {
            endPages.append(page)
        }
        if canContinue, !endPages.isEmpty {
            pages.removeLast()
            pages.append(contentsOf: endPages)
        } else {
            pages.append(contentsOf: endPages)
        }
    }

    return pages
}

/// An embedded pix image's `(widthPt, heightPt)` — the ONE sizing rule every PDF path
/// shares (b24 round 22 factored it out of `resolvePlainBody` so the Modern and
/// notes-pagination paths size identically to the plain Printed path): the print-options
/// record's physical size when the `.PIX` file carries one, else fit-to-text-measure at
/// the source aspect ratio; either way capped at `maxWPt` (the requesting path's own
/// text measure). Port of Python's `_pix_dims_pt`.
func pixDimsPt(_ r: PixResult, maxWPt: Double) -> (w: Double, h: Double) {
    var wPt: Double
    var hPt: Double
    if let widthIn = r.widthIn, let heightIn = r.heightIn, widthIn != 0, heightIn != 0 {
        wPt = widthIn * 72.0
        hPt = heightIn * 72.0
    } else {
        wPt = maxWPt
        hPt = r.gcols.map { $0 != 0 ? wPt * (Double(r.grows ?? 0) / Double($0)) : 0.0 } ?? 0.0
    }
    if wPt > maxWPt, wPt > 0 {
        let scale = maxWPt / wPt
        wPt *= scale
        hPt *= scale
    }
    return (wPt, hPt)
}

/// `(reservedLeadPt, nBlankConsumed)` for an embedded pix tag whose own physical line
/// already ended at `blkLines[startIdx - 1]`.
///
/// WordStar's own INSET convention: the author reserves the picture's print-time footprint
/// as blank PHYSICAL LINES in the source (the tag's own line plus however many blank lines
/// follow it, contiguously, in the same block) — print time overlays the picture on exactly
/// that reserved block, which is why the block's LINE COUNT governs the vertical advance,
/// not the picture's own continuous pixel height (the two rarely match to the point;
/// INSET's editor-time placeholder was drawn by eye).
///
/// Measured 2026-08-20 against -README.WS/-README.pcl (`fidelity_gate.py` Finding A): the
/// `.PIX` tag is followed by 7 contiguous blank lines before "COMPLETE WORDSTAR..." — 8
/// lines * 12pt = 96pt reserved. WS7's own first-body baseline (167.7pt) matches
/// `printedTop`'s 60pt + 96pt + this line's own 12pt lead to a 0.3pt residual, the same
/// decipoint-rounding-sized gap as the rest of the confirmed corpus. Using the raster's raw
/// height instead (73.9pt, from the print-options record) under-reserves by >20pt here and
/// cascades into every following line's position. The SAME `ceil(hPt/lead)` raw-height cost
/// also fed the notes paginator's page-capacity budget before this fix (round 26, Finding
/// A/C) — `layoutPrintedPages`'s `lineCost` now reads this same reserved `.lead` instead.
/// Port of Python's `_pix_reserved_advance`.
func pixReservedAdvance(_ blkLines: [Line], startIdx: Int, ownLeadPt: Double)
    -> (reserved: Double, nBlank: Int)
{
    var n = 0
    while startIdx + n < blkLines.count, blkLines[startIdx + n].text().trimmed().isEmpty {
        n += 1
    }
    return (Double(1 + n) * ownLeadPt, n)
}

/// `(pixIndex, wPt, hPt)` when `spans` is exactly ONE resolved, decoded pix placeholder
/// and nothing else with real text — the round-19 substitution rule, shared verbatim by
/// every PDF path since b24 round 22: text content is never silently dropped, so a
/// (hypothetical) pix tag sharing its line with other prose renders as the ordinary
/// placeholder text instead. `nil` when no substitution applies (off / miss / shared
/// line); the caller keeps the placeholder text unchanged. Port of Python's
/// `_spans_pix_substitution` (which reads the `pixN` style tag; the Swift IR carries the
/// same value structurally as `Span.pix`/`SemanticRun.pix`, hence the tuple shape here).
func spansPixSubstitution(_ spans: [(text: String, pix: Int?)],
                          pixMap: [Int: PixResult], maxWPt: Double)
    -> (pixIndex: Int, wPt: Double, hPt: Double)?
{
    var pixIdx: Int?
    for sp in spans {
        if let tag = sp.pix {
            if pixIdx != nil { return nil }        // >1 tag on one line: bail
            pixIdx = tag
        } else if !sp.text.trimmed().isEmpty {
            return nil                             // real prose shares the line
        }
    }
    guard let pixIdx, let r = pixMap[pixIdx], r.ok else { return nil }
    let (wPt, hPt) = pixDimsPt(r, maxWPt: maxWPt)
    return (pixIdx, wPt, hPt)
}

/// The Printed text measure in points, for pix fit/cap sizing: Printed PDF has no
/// per-block `.rm` resolved in points anywhere in this emitter (physical lines are
/// pre-wrapped by the parser at authoring time), so the right inset is mirrored from the
/// left one — a disclosed approximation (round 19), same class as RTF's borrowed TOC
/// page numbers. Port of Python's `_printed_text_width_pt` (round 22 factored it out,
/// shared with the notes-pagination path).
func printedTextWidthPt(_ doc: Document) -> Double {
    let size = printedSize(doc)
    let left = printedLeft(doc, size: size)
    let pageWPt = (doc.page?.pwIn ?? 8.5) * 72.0
    return max(72.0, pageWPt - 2 * left)
}

/// A physical `Line` with no non-whitespace span text — the same test
/// `resolvePlainBody`'s own per-line loop already applies inline (its `isBlank`),
/// factored out here so `ws4SpacingBlankIndices` can classify a whole block's lines
/// before that loop runs. Port of Python's `_is_blank_line`.
private func isBlankLine(_ line: Line) -> Bool {
    !line.spans.contains { $0.text.contains { !$0.isWhitespace } }
}

/// Finding 1 (b26 visual pass, a private WS4 paper corpus, never entering this repo):
/// `[blockIndex: Set(line indices into that block's own .lines)]` — every blank
/// `Line` that is this document's OWN double-spacing idiom, not authored content.
/// ONLY CALLED for a `variant == .ws4` document — see the call site's own comment for
/// why this never even runs for anything else.
///
/// WordStar's OWN manual gives this a physical story, already quoted elsewhere in
/// this module (`ParseWS.swift`'s `defaultLs`/`enteringLeadPt`): "when you use line
/// spacing, the blank lines become part of the file" (WS7 manual, "Line Spacing") —
/// `.LS`'s blank lines are not computed at print time, they are literal `Line`s the
/// file itself carries. A classified blank stays exactly that: a literal `Line`, its
/// own ordinary `PageLine` at its own natural (single) lead — `resolvePlainBody` does
/// NOT fold it into a neighbour's lead. An early version of this fix DID fold
/// (collapsing a double-spaced pair into one `PageLine` at 2x lead) and it broke on
/// irregular paragraph lengths: real WS7's own page-top baseline cycles through THREE
/// distinct phases 12pt apart (measured: a WS4 source with long, regular paragraphs
/// holds one phase for every interior page, 71.7pt; a WS4 source built mostly from
/// short dialogue paragraphs cycles 71.7/83.7/95.7pt depending on whether the page
/// break happened to land on odd or even raw-line parity) — collapsing every pair
/// into a single 2x-lead unit can only ever reproduce ONE of those phases, because it
/// throws away exactly the raw single-line parity information a page break's real
/// position depends on. Classifying which blanks are spacing (this function) but
/// leaving them as literal RAW `PageLine`s preserves that parity; only their
/// ELIGIBILITY to force a page break changes (`layoutPrintedPagesPlain`'s own
/// pagination loop, via each `PageLine`'s own `ws4Spacing` flag).
///
/// Classified PER BLOCK first (a block is WordStar's own paragraph unit), because a
/// WS4 fiction manuscript mixes double-spaced narrative with single-spaced inserts
/// (verse quoted verbatim, a bibliography) at exactly that granularity, not
/// document-wide — a block whose own lines are `T,T,...` (two real lines with no
/// blank between them) or start with a leading blank never counts, regardless of
/// anything nearby. Neither measured WS4 source sets `.LS` at all (checked their own
/// raw dot-command bytes directly): WS4 predates `.LS` even being a documented dot
/// command, so there is usually no stateful signal to key off and this has to read
/// the rhythm off the pattern itself — `lsConfirmed` (true only when the file's own
/// `.LS` dot-command positively declares spacing > 1, `doc.page?.lsSource == .file`)
/// trusts direct file evidence over the inferred pattern when it exists.
///
/// A block whose shape is a clean alternation (T,B,T,B,... with no two adjacent
/// same-kind lines, ignoring a possible TRAILING blank run at its very end — see
/// below) is COMPATIBLE with the rhythm; one that also has >= threshold interior
/// blanks (an interior blank is real text on BOTH sides, within the same block) on
/// its own is CONFIRMED. `threshold` is 1 under `lsConfirmed`, else 2 — 2 because a
/// real document can carry a single, genuinely authored blank line in the middle of
/// an ordinary paragraph (measured: a real corpus document's own block, one isolated
/// interior blank, never repeated anywhere else in that block) — that is authored
/// spacing, not a rhythm, and one occurrence alone must never count it. (That
/// document is `ws5+`, so the WS4 gate alone already keeps it untouched — the
/// threshold is the SECOND independent reason, for a future WS4 capture that turns
/// out to carry the same kind of aside.)
///
/// STATE, carried across blocks in document order like any other WordStar
/// dot-command state: a CONFIRMED block turns spacing mode on; a
/// COMPATIBLE-but-unconfirmed block counts too WHILE mode is already on (this is
/// what a lone short line of dialogue — too short to confirm 2 interior repeats by
/// itself — needs: measured against a real WS4 source, several consecutive short
/// dialogue paragraphs sit between longer confirmed ones, and their own 24pt gaps to
/// their neighbours check out against that source's own baselines exactly like the
/// confirmed ones'). An INCOMPATIBLE block (leading blank, or two real lines back to
/// back) turns the mode back OFF — the one hard stop, so a verse quotation or a
/// bibliography section breaks the chain exactly where the document's own shape says
/// it should, not where a document-wide guess would. A COMPATIBLE-but-unconfirmed
/// block seen BEFORE the first CONFIRMED one (mode still off) is left alone — there
/// is no evidence yet to count it against.
///
/// TRAILING RUN: a block that counts at all (confirmed, or compatible while mode is
/// on) counts its OWN trailing blanks too — from its last real line to its own end —
/// even though a trailing run is never "interior" (there is no following real line
/// left within THIS block for it to sit between). WordStar's "blank lines become
/// part of the file" is a property of `.LS`, not of which physical line happens to
/// be a paragraph's last — measured: a WS4 source's paragraph boundaries carry a 2-3
/// blank RUN, not the single blank its own within-paragraph rhythm uses (the
/// paragraph's last line still owes its own spacing filler; the author's own
/// blank-line gap between paragraphs, typed under the same `.LS`, owes its own
/// filler too), and the resulting larger gap (measured: 48pt across a 3-blank
/// boundary, exactly 2x a normal 24pt gap) checks out against the source's own
/// baselines too.
///
/// SCOPING RULING (Jon, b26 visual pass): an earlier version of this fix collapsed
/// spacing pairs and was scoped only by block-level pattern; it un-matched -README
/// and VERSIONS (both `ws5+`, both previously matching their own WS7 captures
/// EXACTLY) to fix two WS4 sources — "a rule that un-matches exact documents to fix
/// others is not WS7's real rule... fix the broken thing without breaking anything
/// else." Rebuilt gated on the POSITIVELY DETECTED `variant == .ws4` condition per
/// Jon's follow-up mandate, and every WS4 capture behind this fix (the two sources
/// it was built from, plus three out-of-sample captures checked afterward) is
/// modelled with the SAME rule as every other WS4 document — no per-source carve-out.
/// Port of Python's `_ws4_spacing_blank_indices`.
private func ws4SpacingBlankIndices(_ doc: Document, lsConfirmed: Bool) -> [Int: Set<Int>] {
    let threshold = lsConfirmed ? 1 : 2
    var spacingMap: [Int: Set<Int>] = [:]
    var spacingMode = false
    for (bi, b) in doc.blocks.enumerated() {
        guard b.kind == .para else { continue }     // sentinels never reset the state
        let flags = b.lines.map { !isBlankLine($0) }
        guard let first = flags.first, first else {
            spacingMode = false                      // empty, or opens on a blank
            continue
        }
        let lastReal = flags.lastIndex(of: true)!
        let core = Array(flags[0...lastReal])
        let compatible = core.count < 2
            || (0..<(core.count - 1)).allSatisfy { core[$0] != core[$0 + 1] }
        if !compatible {
            spacingMode = false
            continue
        }
        let interior: [Int] = flags.count > 2
            ? (1..<(flags.count - 1)).filter { flags[$0 - 1] && !flags[$0] && flags[$0 + 1] }
            : []
        let confirmed = interior.count >= threshold
        if confirmed || spacingMode {
            var spacing = Set(interior)
            if lastReal + 1 < flags.count {
                spacing.formUnion((lastReal + 1)..<flags.count)
            }
            spacingMap[bi] = spacing
            spacingMode = true
        }
        // else: compatible, but neither confirmed itself nor inheriting an already-on
        // mode -- no evidence yet; leave uncounted, mode stays off
    }
    return spacingMap
}

/// One body item for the PLAIN (no placeable notes) printed paginator.
private enum PlainBodyItem {
    case pageBreak
    /// `.cp n` — resolved by the pagination loop below, the only thing that knows how
    /// full the page is.
    case condPage(Int)
    case line(PageLine)
    /// A `.he`/`.h1`-`.h5`/`.fo`/`.f1`-`.f5` occurrence, replayed at the block it precedes.
    case hf(kind: HFKind, line: Int, text: String)
}

/// Blocks -> plain body items, with `doc.hfEvents` replayed at the block each one
/// precedes. Port of the printed-mode half of Python's `_doc_to_pagelines` block walk —
/// used only when `hasPlaceableNotes(doc)` is false (the notes-aware paginator above
/// handles the other case, and never replays `hfEvents` — see `Page`).
private func resolvePlainBody(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [PlainBodyItem] {
    let refNotes = inlineReferenceNotes(doc)
    var hfByBlock: [Int: [(HFKind, Int, String)]] = [:]
    for event in doc.hfEvents {
        hfByBlock[event.blockAnchor, default: []].append((event.kind, event.line, event.text))
    }
    // b24 round 19 (RULINGS-LEDGER PIX row); round 22 closed the round-19 scope cuts --
    // `layoutPrintedPages` (the notes-aware paginator) and Modern's `modernStreams`
    // substitute too, through the same shared helpers.
    let embedImages = pictures != .off && !pixResults.isEmpty
    let pixMap: [Int: PixResult] = embedImages
        ? Dictionary(uniqueKeysWithValues: pixResults.map { ($0.index, $0) }) : [:]
    // "Fit to text measure" (ruled fallback/cap) sizing lives in
    // `pixDimsPt`/`printedTextWidthPt` (round 22 factored them out, shared with the
    // notes-pagination and Modern paths).
    let textWidthPt = embedImages ? printedTextWidthPt(doc) : 0.0
    // b24 round 17 (RULINGS-LEDGER row 5/7): `.pm`/`.psa`/`.psb` extend round 6's RTF
    // vertical-space model to Printed PDF, same relative-computation rules. `pendingSa`
    // carries a block's own `sa` forward to whatever PageLine gets appended NEXT (which
    // may be several items away across an intervening `.hf`/pagebreak/condpage entry) —
    // applied the moment a real PageLine is built, regardless of source. Port of
    // Python's own `_doc_to_pagelines` block walk (this same function, its Printed half).
    let (docSb, docSa) = printedDocSpacingPt(doc)
    var pendingSa: Double? = nil
    let defaultLeadPt = printedLead(doc)
    // Register b31: this line's own `.po` override needs the printed type size for the
    // same edge-of-page clamp `printedLeft` already applies (`resolveLeftPt`).
    let sizeForLeft = printedSize(doc)
    // round 26 wave 3 (fidelity_gate.py Finding B): `fontLeadPt`'s carried-governing-size
    // state, threaded across every physical line of the document in source order, same
    // cross-block carry as `pendingSa`. `lhSource == .file` guard mirrors `styleLeadPt`'s
    // own — see `fontLeadPt`'s docstring.
    var fontLeadState: Double? = nil
    let fontLeadOk = doc.fonts.contains { $0.proportional } && doc.page?.lhSource != .file
    let fontLeadBase = fontLeadOk ? Double(printedSize(doc)) : 0.0
    // Finding 1 (b26 visual pass): scoped, per Jon's binding ruling, to a
    // POSITIVELY-DETECTED condition -- `variant == .ws4` -- rather than trusting the
    // block-pattern detector alone to stay harmless everywhere else. `-README`/
    // `VERSIONS` (both `ws5+`) picked up real cross-page drift the FIRST time this
    // fix shipped scoped only by pattern -- both had matched their own WS7 captures
    // EXACTLY before that, so "a rule that un-matches exact documents to fix others
    // is not WS7's real rule" (Jon). `ws4Spacing` being `false` makes `spacingMap`
    // the literal empty dictionary below for every non-WS4 document --
    // `ws4SpacingBlankIndices` is never even CALLED -- so every non-WS4 document's
    // own code path is identical to before this fix, by construction, not by
    // trusting the pattern to happen not to fire. Widening this gate past `ws4`
    // needs its own oracle evidence, not an assumption that the mechanism
    // generalises.
    let ws4Spacing = doc.detection?.variant == .ws4
    // Prefer the file's OWN `.LS` dot-state when it exists (WS7 manual, "Line
    // Spacing": see `ws4SpacingBlankIndices`); neither WS4 source measured for this
    // finding sets `.LS` at all (WS4 predates the dot command), so this is `false`
    // for them and the structural fallback in `ws4SpacingBlankIndices` carries the
    // detection instead -- but a future WS4 capture that DOES carry an explicit
    // `.LS 2`+ should be trusted over the pattern, not re-inferred from it.
    let lsConfirmed = ws4Spacing && doc.page?.lsSource == .file && (doc.page?.ls ?? 1) > 1
    let spacingMap = ws4Spacing ? ws4SpacingBlankIndices(doc, lsConfirmed: lsConfirmed) : [:]
    var items: [PlainBodyItem] = []
    for (bi, block) in doc.blocks.enumerated() {
        // Finding 1: see `ws4Spacing`'s own comment above -- `spacingMap` is the
        // literal empty dictionary for every non-WS4 document, so this lookup always
        // returns the empty set there and nothing below can touch one.
        let spacingBlanks = spacingMap[bi] ?? []
        for (kind, line, text) in hfByBlock[bi] ?? [] {
            items.append(.hf(kind: kind, line: line, text: text))
        }
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.condPage(max(1, block.heading)))
            continue
        }
        let fiPt = printedPMFiPt(block)
        var firstLineOfBlock = true
        // Fix C (b26-print-fidelity-2): the nearest earlier REAL (`.para`) block,
        // skipping pagebreak/condpage sentinels — `enteringLeadPt`'s own "outgoing"
        // reference for this block's first line, computed once per block since it
        // never changes within one.
        let prevParaBlock = doc.blocks[0..<bi].last { $0.kind == .para }
        // Printed mode renders PHYSICAL lines verbatim — a soft return broke the line on
        // paper, so it stays broken here. Indexed (not a plain `for`) so an embedded pix
        // substitution below can look ahead and CONSUME the blank placeholder lines
        // WordStar reserved for it — see `pixReservedAdvance`.
        var li = 0
        while li < block.lines.count {
            let lineIdx = li
            let line = block.lines[li]
            li += 1
            var spans = line.spans
                .filter { keepSpanOnPageline($0, refNotes: refNotes) }
                .map { sp -> Span in
                    let styles = effectiveSpanStyles(sp, block: block, headingBold: true)
                    // Register C5: the block's own paragraph-style colour is a default
                    // for every span it governs, so it can move a span that carries no
                    // attribute change at all -- the styles-unchanged fast path has to
                    // ask about it too.
                    let colour = effectiveSpanColour(sp, block: block)
                    return styles == sp.styles && colour == sp.colour ? sp
                        : Span(text: sp.text, styles: styles, font: sp.font,
                               colour: colour, pctlHMI: sp.pctlHMI, pix: sp.pix,
                               pcl: sp.pcl, tabHMI: sp.tabHMI, tabLeader: sp.tabLeader)
                }
            var ownLead = leadPt(line.lead48)
            // Register b31: this line's own `.po` override, same "absolute here, `nil`
            // means agrees with the document default" contract `line.lead48` above
            // already has (`ParseWS.swift`'s back-dating pass).
            let ownLeft = line.poCols.map { resolveLeftPt($0, size: sizeForLeft) }
            // Register b32-N10 (mirrored from ctrl-kd b48148c): this line's own `.sr`
            // roll, already resolved — `Line.roll48` is never `nil` on a real parsed line
            // (its own doc comment), so this is simply the 1/48in -> points conversion
            // `printedRollPt` already uses for the document-wide fallback, applied per
            // line.
            let ownRoll = line.roll48.map { $0 * 1.5 }
            // A WS7 paragraph STYLE's own line height (`Block.lineHeightVMI`) governs
            // OVER the generic `.lh`/document default — same precedence `newBlock` already
            // gives a style's align/margins/wrap over the running dot-command state.
            // `styleLeadPt` itself withholds an answer (`nil`) for any document that ever
            // used a real `.lh` at all (its own doc comment), so this line's own `lead48`
            // only matters as a belt-and-braces check for a genuinely per-line override.
            //
            // Fix C (b26-print-fidelity-2): a BLANK line (no real text — nothing to
            // clip, so Finding B's fallback never applies to it, see `styleLeadPt`'s
            // `raw` parameter) always gets the raw, unfallen-back value. A block's own
            // FIRST REAL line is the one `enteringLeadPt` may floor against the
            // PRECEDING block's own raw lead (its own doc comment); any other real line
            // keeps the plain fallback-eligible value, unchanged from every call site
            // before this fix.
            let isBlank = !spans.contains { $0.text.contains { !$0.isWhitespace } }
            let styleLead: Double?
            if isBlank {
                styleLead = styleLeadPt(block, doc, raw: true)
            } else if firstLineOfBlock {
                styleLead = enteringLeadPt(block, doc, prevBlock: prevParaBlock)
            } else {
                styleLead = styleLeadPt(block, doc)
            }
            if let styleLead, line.lead48 == nil || line.lead48 == defaultLh48 {
                ownLead = styleLead
            }
            // round 26 wave 3 (fidelity_gate.py Finding B): a WS5+ FONT-BLOCK document
            // with no style governing this line (ownLead still nil) gets its lead from
            // the font block actually in force. See `fontLeadPt`.
            if ownLead == nil, fontLeadOk {
                ownLead = fontLeadPt(line, fonts: doc.fonts, baseSize: fontLeadBase,
                                     state: &fontLeadState)
            }
            // Finding 1: this blank IS the block's own double-spacing (see
            // `ws4SpacingBlankIndices`) -- it still becomes its own literal PageLine,
            // at its own natural (unextended) lead, EXACTLY as any other blank always
            // has; only its `ws4Spacing` flag differs, which the pagination loop
            // below reads to decide whether this blank alone may force a page break
            // (see that loop's own comment for why collapsing it into a neighbour's
            // lead, an earlier version of this fix, broke on irregular paragraph
            // lengths).
            let ws4SpacingLine = isBlank && spacingBlanks.contains(lineIdx)
            var extra = 0.0
            if let sa = pendingSa {
                extra += sa
                pendingSa = nil
            }
            // no space-before on the document's own opening paragraph — nothing above
            // it to space away from.
            if firstLineOfBlock, let sb = docSb, bi > 0 {
                extra += sb
            }
            if extra != 0.0 {
                ownLead = (ownLead ?? defaultLeadPt) + extra
            }
            // b24 round 19 (RULINGS-LEDGER PIX row): exactly one pix tag, no other real
            // text on this physical line (the confirmed real-corpus shape: every
            // acceptance document's picture reference stands alone on its own
            // paragraph) -> an image PageLine instead of a text one. If a hypothetical
            // pix tag ever shares a line with OTHER real text, this deliberately does
            // NOT substitute -- text content is never silently dropped. (Round 22: the
            // detection/sizing rule is `spansPixSubstitution`, shared with the notes
            // and Modern paths.) `.lead` is the RESERVED PLACEHOLDER block's height
            // (round 26, Finding A/C — `pixReservedAdvance`), not the raster's own
            // continuous pixel height, + whatever `.psb`/`.psa` extra was already
            // computed above.
            var substituted = false
            if embedImages,
               let sub = spansPixSubstitution(spans.map { (text: $0.text, pix: $0.pix) },
                                              pixMap: pixMap, maxWPt: textWidthPt) {
                let (reserved, nBlank) = pixReservedAdvance(
                    block.lines, startIdx: li, ownLeadPt: ownLead ?? defaultLeadPt)
                li += nBlank
                items.append(.line(PageLine([], soft: line.soft, lead: reserved + extra,
                                            overprint: line.overprint, bi: bi,
                                            image: .init(pixIndex: sub.pixIndex,
                                                         widthPt: sub.wPt, heightPt: sub.hPt),
                                            left: ownLeft)))
                firstLineOfBlock = false
                substituted = true
            }
            if !substituted {
                // N9 (b33 field notes): applied to the FINAL body spans, AFTER the
                // pix-substitution check above (which needs the raw, untouched text to
                // match its structural placeholder) -- state carries across every span
                // on this physical line, matching ctrl-kd's own `_doc_to_pagelines`
                // choke point exactly.
                if sentenceSpacing { spans = sentenceSpacingSpans(spans) }
                items.append(.line(PageLine(spans, soft: line.soft, lead: ownLead,
                                            overprint: line.overprint,
                                            fi: firstLineOfBlock ? fiPt : nil, bi: bi,
                                            ws4Spacing: ws4SpacingLine,
                                            kerning: line.kerning, left: ownLeft, roll: ownRoll)))
                firstLineOfBlock = false
            }
        }
        // `!firstLineOfBlock`: this block actually appended at least one real PageLine
        // (an empty-text block leaves it true, nothing to space away from). Carried to
        // whatever PageLine comes next, however many items away that is.
        if let sa = docSa, !block.lines.isEmpty, !firstLineOfBlock {
            pendingSa = sa
        }
    }
    return items
}

/// Points-based printed pagination for documents with NO placeable notes — the plain
/// half of Python's `_doc_to_pagelines`. Port of ctrl-kd 17e4ea0/8b902ff.
///
/// Paper is physical: WordStar advances each line by the `.lh` in force and starts a
/// new page when the next advance would leave the text area, so a document that varies
/// its leading fits more or fewer lines than the default-lead COUNT says. The budget is
/// `(cap - 1)` leads at the document default — the first line sits at the top, each
/// following line spends its own lead — which makes a uniform-lead document paginate
/// EXACTLY as the old line-count did, so no fontless byte moves. Overprint lines spend
/// no lead at all, on paper and here.
///
/// The running head/foot IN FORCE on a page is replayed from `doc.hfEvents` rather than
/// read from the document's final state: WordStar applies a running head from the page
/// where it is defined — on that page itself only if no text has printed there yet,
/// else from the next page.
// NOT private (job 255, additive): `AnnotatedLayout.swift`'s natural page-break
// detection needs the real paginator, not a re-derived guess — "the engine is the
// single source of truth." Pure visibility widening, zero behavior change: every
// call site, every line of the body, is untouched.
func layoutPrintedPagesPlain(
    _ doc: Document, pixResults: [PixResult] = [], pictures: EmitOptions.PixMode = .off,
    sentenceSpacing: Bool = false
) -> [Page] {
    let items = resolvePlainBody(doc, pixResults: pixResults, pictures: pictures,
                                 sentenceSpacing: sentenceSpacing)
    var capacity = printedCap(doc)
    let defaultLead = printedLead(doc)
    var budget = Double(capacity - 1) * defaultLead
    // b24 round 17b (RULINGS-LEDGER row 5/6, register C8): `.sb` suppresses blank lines
    // specifically at the TOP of a page — WordStar's own pagination concern, not a
    // text-content one, so it belongs in THIS loop (the only place that knows a page
    // just started) rather than `resolvePlainBody`'s line-building pass above.
    let suppressBlanks = doc.formatting.suppressBlanks ?? false
    // Finding 3 (b26-print-fidelity-2): a fresh page picks up whatever `.mt`/`.mb` was
    // in force at its OWN first block, not the document's global first-occurrence pair
    // — see `mtMbCheckpoints`. `globalMt`/`globalMb` are what `printedCap(doc)` itself
    // already used above; a page whose own checkpoint matches them leaves
    // `Page.mtLines`/`mbLines` at their `nil` default (render side: "use the document
    // global", untouched).
    let mtMbCheckpointsList = mtMbCheckpoints(doc)
    let globalMt = mtMbCheckpointsList[0].mt
    let globalMb = mtMbCheckpointsList[0].mb
    var curMt = globalMt
    var curMb = globalMb
    // register b31-dot-command-sweep: `.pl`/`.hm`/`.fm` are stateful too, same mechanism
    // as `.mt`/`.mb` above -- see `plCheckpoints`/`hmFmCheckpoints`. `plAt(.., 0)`/
    // `hmFmAt(.., 0)`, NOT a raw index-0 read: block 0's seed is WordStar's hardcoded
    // default, which a document that declares `.pl`/`.hm`/`.fm` right at its own start
    // immediately supersedes with another (bi=0) checkpoint -- the `At` helpers resolve
    // that correctly, a raw index-0 read would not.
    let plCheckpointsList = plCheckpoints(doc)
    let globalPl = plAt(plCheckpointsList, 0)
    var curPl = globalPl
    let hmFmCheckpointsList = hmFmCheckpoints(doc)
    let (globalHm, globalFm) = hmFmAt(hmFmCheckpointsList, 0)
    var curHm = globalHm
    var curFm = globalFm
    // `closePage`'s "does this page need its own render-time override" test can NOT
    // compare against `globalPl`/`globalHm`/`globalFm` above: those are seeded at
    // WordStar's hardcoded default (correct for BEFORE any real occurrence), but the
    // render loop's fallback ("Page.* left nil means use doc.page AS IS") reads
    // `ParseWS.swift`'s own first-occurrence value, which -- in the exact degenerate case
    // the seed fix above exists for (a command whose ONLY occurrence sits mid-document) --
    // is that SAME later value, wrongly, for every page. Comparing against the RAW
    // `doc.page` reading instead makes a page whose resolved value happens to DIFFER from
    // it get its own override even when that resolved value equals the (correct)
    // checkpoint global, which is exactly the pages BEFORE such a command's first real
    // occurrence.
    let docPl = doc.page?.plLines ?? defaultPlLines
    let docHm = doc.page?.hmLines ?? 2.0    // WSFORMAT's own hardcoded ".HM" default
    let docFm = doc.page?.fmLines ?? 2.0    // WSFORMAT's own hardcoded ".FM" default
    /// (mt, mb, pl, hm, fm) in force at block `bi`, for the page about to start there --
    /// shared by BOTH places a fresh page begins: the explicit-break path below (`page`
    /// already empty by the time the next `.line` case's top-of-switch check runs), and
    /// the ORGANIC-overflow close (where `page` is NOT yet empty at the top of THIS
    /// iteration -- the line that overflows IS the new page's own first line, and must use
    /// ITS block's geometry, not the closing page's). Missed until register b31-dot-
    /// command-sweep: `.pl`'s own oracle (PL_PROBE) has no explicit break at all -- an
    /// ordinary organic page break -- and real WS7 still used the new `.pl` starting the
    /// very next page, which only the organic-close recompute site can reproduce. This
    /// also strengthens `.mt`/`.mb` for organic breaks (previously recomputed only at the
    /// explicit-break site).
    func recomputeGeom(_ bi: Int) -> (mt: Double, mb: Double, pl: Double, hm: Double, fm: Double) {
        let (mt, mb) = mtMbAt(mtMbCheckpointsList, bi)
        let pl = plAt(plCheckpointsList, bi)
        let (hm, fm) = hmFmAt(hmFmCheckpointsList, bi)
        return (mt, mb, pl, hm, fm)
    }

    var pages: [Page] = []
    var page: [PageLine] = []
    var spent = 0.0
    var curHeaders: [Int: String] = [:]
    var curFooters: [Int: String] = [:]
    var pageHeaders: [Int: String] = [:]     // state at the OPEN page's start
    var pageFooters: [Int: String] = [:]

    func cost(_ line: PageLine) -> Double {
        let lead = line.lead ?? defaultLead
        guard let last = page.last else {
            // b26-mtmb-general (pictures-mode pagination parity, -README.WS): an
            // embedded image's `.lead` is a RESERVED-BAND total (the pix tag's own line
            // plus its contiguous following blanks — `pixReservedAdvance`), not one
            // physical line's advance. The "first line is free" rule below assumes the
            // opposite — that `.lead` represents exactly the ONE source line `budget`'s
            // own `(cap - 1)` already accounts for (see this function's own doc comment
            // above) — so crediting the WHOLE reserved band when the image happens to
            // land as a page's first line freed 7 extra lines' worth of budget (96pt
            // reserved band, 84pt of which should have stayed charged) that the
            // `pictures = .off` path, where the SAME tag line and blanks are ordinary
            // PageLines and only the tag line's own one-line advance is ever free, never
            // received — off matches WS7's real page break exactly, embed ran several
            // lines longer before this fix. Only the amount ABOVE one line's own advance
            // is charged even at a page's own start, so embed's image-band cost matches
            // off's natural per-line accumulation exactly, regardless of where either
            // mode's break happens to fall.
            if line.image != nil {
                return max(0.0, lead - defaultLead)
            }
            return 0.0                                      // first line on page is free
        }
        if last.overprint { return 0.0 }                   // this line shares a baseline
        return lead
    }
    func closePage() {
        var pg = Page(page,
                      headers: pageHeaders.filter { !$0.value.isEmpty },
                      footers: pageFooters.filter { !$0.value.isEmpty })
        if curMt != globalMt || curMb != globalMb {
            pg.mtLines = curMt
            pg.mbLines = curMb
        }
        if curPl != docPl {
            pg.plLines = curPl
        }
        if curHm != docHm || curFm != docFm {
            pg.hmLines = curHm
            pg.fmLines = curFm
        }
        pages.append(pg)
    }
    func openNewPage() {
        page = []
        spent = 0.0
        pageHeaders = curHeaders
        pageFooters = curFooters
    }

    for item in items {
        switch item {
        case .hf(let kind, let line, let text):
            if kind == .header { curHeaders[line] = text } else { curFooters[line] = text }
            if page.isEmpty {          // nothing printed on this page yet
                pageHeaders = curHeaders
                pageFooters = curFooters
            }
        case .condPage(let n):
            // Strictly fewer than n lines left -> break; exactly n is enough room.
            let room = (budget - spent) / defaultLead
            if room < Double(n), !page.isEmpty {
                closePage()
                openNewPage()
            }
        case .pageBreak:
            // Always closes -- even an empty page, which IS a blank sheet (`.pa .pa`).
            closePage()
            openNewPage()
        case .line(let line):
            // Finding 3: a line about to start a FRESH page picks up the `.mt`/`.mb`
            // in force at ITS OWN block — recomputing `capacity`/`budget` for THIS
            // page only, so a page whose geometry never changes never recomputes to a
            // different number (see `printedCapFor`'s docstring).
            if page.isEmpty, let bi = line.bi {
                let (mt, mb, pl, hm, fm) = recomputeGeom(bi)
                curMt = mt
                curMb = mb
                curPl = pl
                curHm = hm
                curFm = fm
                capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                budget = Double(capacity - 1) * defaultLead
            }
            let overflow = spent + cost(line) > budget + 1e-6
            // Finding 1 (b26 visual pass): the FIRST `ws4Spacing` blank (see
            // `ws4SpacingBlankIndices`) to overflow a page's budget never triggers
            // the break by itself -- a physical blank-line paper advance right at
            // the bottom margin doesn't need a fresh sheet, and giving it its OWN
            // page-break decision was this finding's original bug (a page break
            // landing mid text/blank pair silently spent one line of the NEXT
            // page's budget on ink-free paper, growing a cumulative real-line
            // deficit every other page). ONLY a PageLine `ws4SpacingBlankIndices`
            // positively classified gets this exemption -- an ordinary blank
            // (every non-WS4 document's blanks, and a WS4 document's own authored
            // ones, chapter-drops included) still forces the break exactly as
            // before this fix, since `ws4Spacing` defaults `false` and nothing here
            // changes that default. `alreadyOver` denies the exemption to a SECOND
            // consecutive over-budget spacing blank (a paragraph boundary's own 2-3
            // blank run): forgiving every blank in a run over-admits a whole extra
            // real line one measured source's own WS7 capture didn't have.
            let alreadyOver = spent > budget + 1e-6
            let full = overflow && !(line.ws4Spacing && !alreadyOver)
            if full, !page.isEmpty {
                closePage()
                openNewPage()
                // organic overflow (see `recomputeGeom`'s doc comment): `line` itself is
                // the new page's first line and never reaches the top-of-case
                // `page.isEmpty` gate above, since `page` is not empty until closePage/
                // openNewPage runs right here, mid-iteration.
                if let bi = line.bi {
                    let (mt, mb, pl, hm, fm) = recomputeGeom(bi)
                    curMt = mt
                    curMb = mb
                    curPl = pl
                    curHm = hm
                    curFm = fm
                    capacity = printedCapFor(doc, mtLines: mt, mbLines: mb, plLines: pl)
                    budget = Double(capacity - 1) * defaultLead
                }
            }
            // `.sb`: a blank line at the top of a page doesn't print.
            if suppressBlanks, page.isEmpty, isBlank(line) {
                continue
            }
            spent += cost(line)
            page.append(line)
        }
    }
    if !page.isEmpty {
        closePage()
    }
    return pages
}

/// Whether a page line has nothing on it — no segments, or only whitespace. b24 round
/// 19 (RULINGS-LEDGER PIX row): an image PageLine has no text segments (`[]`, by
/// construction — see `resolvePlainBody`'s substitution), so `.image` must be checked
/// FIRST or an embedded picture sitting last in a short document (the real-corpus
/// shape: every acceptance document's own pix tag is its own final content) reads as a
/// trailing machine blank and gets silently popped off the page it was just placed on
/// (the PREVIEW.WS root-cause fix). Port of `_is_blank`.
private func isBlank(_ line: PageLine) -> Bool {
    line.image == nil && !line.contains { $0.text.contains { !$0.isWhitespace } }
}

/// Python's `str.isspace()`: non-empty and entirely whitespace. Note this is broader than
/// the split below, which is spaces only — a lone tab is a token the wrapper treats as
/// trailing whitespace but never split on. That asymmetry is Python's and is preserved.
private func isSpaceRun(_ text: String) -> Bool {
    // Swift's `Character.isWhitespace` follows Unicode White_Space, which EXCLUDES the
    // ASCII information separators 0x1C-0x1F; Python's `str.isspace()` includes them, and
    // they can reach a span via the 0x1B extended-character escape. Use the shared
    // Python-equivalent test so `_wrap_line`'s trailing-token pop trims the same tokens
    // Python's does.
    !text.isEmpty && text.isPythonSpaceOnly
}

/// Split into alternating runs of spaces and non-spaces, keeping both. Python's
/// `re.split(r'( +)', text)` minus the empty strings its edges produce.
///
/// Literal spaces only, matching the regex: a tab is part of the word it sits in, and gets
/// counted as one column like every other character.
func splitKeepingSpaceRuns(_ text: String) -> [String] {
    var pieces: [String] = []
    var run = ""
    var runIsSpace = false
    for char in text {
        let isSpace = char == " "
        if run.isEmpty {
            run.append(char)
            runIsSpace = isSpace
        } else if isSpace == runIsSpace {
            run.append(char)
        } else {
            pieces.append(run)
            run = String(char)
            runIsSpace = isSpace
        }
    }
    if !run.isEmpty {
        pieces.append(run)
    }
    return pieces
}

extension String {
    /// Column count for layout: Unicode scalars, which is what Python's `len` counts on the
    /// `str` this text was decoded into. Not `count` (grapheme clusters) — the two agree for
    /// everything CP437 can produce, and where they wouldn't, Python's answer is the one the
    /// vectors were generated with.
    ///
    /// Shared with the writer, which needs the same count for its x-advance (`len(text) *
    /// size * 0.6`, pdf.py:145). Python uses one `len` for both jobs and so should this —
    /// a wrapper that counted columns differently from the advance would lay out text to one
    /// width and paint it at another.
    var width: Int {
        unicodeScalars.count
    }
}
