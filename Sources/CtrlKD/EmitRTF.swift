/// RTF emitter. Direct port of `_rtf_escape` (emit.py:197-206) and `emit_rtf`
/// (emit.py:208-235), with the `_RTF_ON` table (emit.py:194-195).

/// `_RTF_ON` (emit.py:194-195), in the order Python's `sorted(s.styles)` yields the style
/// codes: `b, i, strike, sub, sup, u`. Here the styles are CONCATENATED rather than nested,
/// so the order is directly visible in the output (`{\b \i text}`) — reordering this table
/// changes the bytes.
///
/// `fnref` is absent, and Python's `.get(s, '')` makes that a silent no-op: a footnote
/// reference contributes no control word of its own and rides on the `sup` it carries.
/// The trailing space in each control word is RTF's control-word terminator, not padding.
private let rtfControlWords: [(style: Style, control: String)] = [
    (.bold, #"\b "#),
    (.italic, #"\i "#),
    (.strike, #"\strike "#),
    (.sub, #"\sub "#),
    (.sup, #"\super "#),
    (.underline, #"\ul "#),
]

/// emit.py:197-206. Three cases: RTF's own metacharacters get a backslash, plain ASCII
/// passes through, and anything else becomes `\uN?` — N the DECIMAL code point, `?` the
/// literal fallback character an RTF reader too old to understand `\u` shows instead.
///
/// Iterates unicode scalars, not `Character`, because Python iterates code points: a
/// combining sequence must escape per code point or the numbers come out wrong.
func rtfEscape(_ text: String) -> String {
    var out = String()
    out.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        if scalar == "\\" || scalar == "{" || scalar == "}" {
            out.append("\\")
            out.unicodeScalars.append(scalar)
        } else if scalar == mergePagenoMarkScalar {
            // planning #270 item 42: WordStar's MailMerge page-number variable, put here
            // by `mergePagenoMarked` and resolved to the reader's OWN current-page
            // field — the identical mechanism a `#` inside a running head uses. Never
            // present unless `emitRTF` put it there, and unreachable in a real document
            // (U+E000 is a private-use code point; cp437 and cp1252 decode nowhere near
            // it).
            out += #"{\chpgn }"#
        } else if scalar.value < 128 {
            out.unicodeScalars.append(scalar)
        } else {
            out += "\\u\(scalar.value)?"
        }
    }
    return out
}

/// The `_RTF_ON` control words for a span, in Python's sorted-style order.
private func rtfStyleControls(_ styles: Style) -> String {
    var out = String()
    for entry in rtfControlWords where styles.contains(entry.style) {
        out += entry.control
    }
    return out
}

/// A valid, included reference's INLINE marker. Footnotes and endnotes share the generic
/// `\chftn` — RTF auto-numbers footnote/endnote marks at render time, so WordStar's own
/// display number (task item 2) isn't representable here and isn't attempted; only the
/// destination's `\footnote` vs `\footnote\ftnalt` distinguishes the two kinds. An
/// annotation has no auto-number to hook, so it carries its literal tag instead.
///
/// A TAGGED footnote/endnote (`note.tag != nil`, ruling 2026-08-24 item 4) is the same
/// honesty case as an annotation: `\chftn` is Word's AUTOMATIC counter, and a note
/// carrying its own user MARK is not automatically numbered by WordStar either. `label`
/// is already that mark by the time it reaches here (`noteLabel` resolves tag-over-
/// number), so this only needs to route it through the same custom-mark branch
/// annotations use rather than reaching for `\chftn`. UNTESTED AGAINST A REAL DOCUMENT —
/// no archive specimen carries a footnote/endnote tag.
private func rtfReferenceMarker(_ note: Note, label: String, markOverride: String? = nil) -> String {
    if let markOverride {
        // the `prefixed` scheme's literal custom mark in place of \chftn (M8)
        return "{\\super " + rtfEscape(markOverride) + "}"
    }
    if note.tag != nil, note.kind != .comment {
        return "{\\super " + rtfEscape(label) + "}"
    }
    switch note.kind {
    case .footnote, .endnote: return #"{\chftn}"#
    case .annotation: return "{\\super " + rtfEscape(label) + "}"
    case .comment: return ""   // unreached: comments never get an inline sentinel
    }
}

/// A valid, included reference's DESTINATION: the `{\footnote …}` group `\chftn` (or the
/// tag) points at. Endnotes and annotations both use `\footnote\ftnalt` — RTF has no
/// separate endnote-destination construct — differing only in what appears inside the
/// leading `{\super …}` (the generic `\chftn` mark for an endnote, the literal tag for an
/// annotation).
/// `markOverride` is the `prefixed` scheme's label (e1/a1) standing in for `\chftn` on
/// any kind — the mechanism annotations already used (ruling 2026-08-06 M8). Port of
/// `_rtf_note_dest`'s `mark_override`.
///
/// A TAGGED footnote/endnote (ruling 2026-08-24 item 4 — `note.tag` set) is the same
/// honesty case as an annotation, for the same reason `rtfReferenceMarker` above routes
/// it through the custom-mark branch. UNTESTED AGAINST A REAL DOCUMENT.
///
/// Deliberately UNSTARRED (ruling 2026-08-26, mirrored from ctrl-kd 47b7049: "skip the
/// backslash * on notes"): the RTF spec's leading `\*` on a destination means "a reader
/// that doesn't recognise this control word should skip it entirely," the wrong failure
/// mode for note text — an unknown reader would silently drop the footnote/endnote/
/// annotation body instead of showing it. Without the star, an unknown reader falls back
/// to RTF's generic "unrecognised control word" rule and dumps the destination's TEXT
/// inline instead of losing it; a `\footnote`-aware reader (Word, Pages, LibreOffice) is
/// unaffected either way — it keys off the `\footnote` control word itself, not the flag.
private func rtfDestination(_ note: Note, label: String, markOverride: String? = nil,
                            sentenceSpacing: Bool = false) -> String {
    let noteText = sentenceSpacing ? sentenceSpacingTexts([note.text])[0] : note.text
    let text = rtfEscape(noteText)
    let flag = note.kind == .footnote ? "" : #"\ftnalt"#
    if note.kind == .annotation || note.tag != nil || markOverride != nil {
        let markText = rtfEscape(markOverride ?? label)
        return #"{\footnote"# + flag + #" \pard\plain\fs24 {\super "# + markText + #" }"#
            + text + "}"
    }
    switch note.kind {
    case .footnote:
        return #"{\footnote \pard\plain\fs24 {\super\chftn }"# + text + "}"
    case .endnote:
        return #"{\footnote\ftnalt \pard\plain\fs24 {\super\chftn }"# + text + "}"
    case .annotation, .comment:
        return ""   // annotation handled above; comments render elsewhere
    }
}

/// One span, RTF: an ordinary span keeps today's plain `{styles}{text}` group; a valid,
/// included `fnref` becomes its marker immediately followed by its destination group; an
/// excluded kind's reference vanishes (no group at all — not even an empty one, matching
/// the `no_notes` vectors); an invalid one (task item 3) falls back to the ordinary group,
/// which already renders a stray sentinel as `{\super 1}` (fnref contributes no control
/// word of its own, only whatever `sup` it also carries).
private func rtfBodySpan(_ span: Span, refNotes: [Note], labels: [String], options: EmitOptions,
                         fontControl: [Int: String] = [:], printed: Bool = false,
                         shownMap: [Int: String]? = nil, rollHalfPt: Int? = nil,
                         ulContinuous: Bool = true, inlineStyling: Bool = true,
                         sentenceSpacing: Bool = false, nonpropFallback: Bool = false) -> String {
    // A 0x0F print control's display string is SCREEN-ONLY: on paper WordStar sent the
    // raw printer payload and advanced by the block's HMI word. Printed pads that width
    // (10-CPI print columns); Modern shows NOTHING -- the string is an editor-screen
    // artifact, and command codes are invisible (M4, extended to print controls, ruling
    // 2026-08-06 round 3 / M10).
    if let hmi = span.pctlHMI {
        guard printed else { return "" }
        let pad = roundHalfToEven(Double(hmi) / 180.0)
        return pad > 0 ? "{" + String(repeating: " ", count: pad) + "}" : ""
    }
    // b24 round 19 (RULINGS-LEDGER PIX row, "PIX images RULED IN"): a pix placeholder
    // span becomes a native RTF picture destination when the flag is live and the tag
    // actually resolved to a real, decoded image; otherwise (off, or a miss) it falls
    // straight through to the unchanged placeholder text below -- "off: today's
    // placeholder behavior exactly" (ruled) and "never fail, placeholder kept" on a
    // miss (ruled) both fall out of doing nothing special here.
    if let pixIndex = span.pix, options.pictures != .off,
       let result = options.pixResults.first(where: { $0.index == pixIndex }), result.ok,
       let png = result.png {
        // RTF/PDF always embed regardless of embed/export (ruled: "no portable
        // reference mechanism a recipient could resolve portably") -- export
        // ADDITIONALLY writes the PNG to disk, a side effect the caller (not this
        // renderer) handles.
        let goalW: Int
        let goalH: Int
        if let widthIn = result.widthIn, let heightIn = result.heightIn {
            goalW = roundHalfToEven(widthIn * 1440.0)      // inches -> twips
            goalH = roundHalfToEven(heightIn * 1440.0)
        } else {
            // No authoritative print-options size: render at the common 96dpi screen
            // reference (1440 twips/in / 96 = 15 twips/px) rather than force a
            // page-fit measure RTF has no single geometry for outside Printed.
            goalW = (result.gcols ?? 1) * 15
            goalH = (result.grows ?? 1) * 15
        }
        let hex = png.map { hex2(Int($0)) }.joined()
        return #"{\pict\pngblip\picw\#(result.gcols ?? 1)\pich\#(result.grows ?? 1)"#
            + #"\picwgoal\#(goalW)\pichgoal\#(goalH) \#(hex)}"#
    }
    // The font control follows the style control words: Python joins `_RTF_ON` over the
    // sorted style codes (a `fontN` contributes nothing there) and only then appends the
    // font's own `\fK\fsN`. Factored into a closure (b24 round 17b) so it can be called
    // TWICE — with and without `.underline` — for the honest `.ul` default's space-run
    // split below.
    func buildCtl(_ theseStyles: Style) -> String {
        var c = rtfStyleControls(theseStyles)
        // b24 round 17 (RULINGS-LEDGER row 3, register C22): explicit DIRECT override of
        // whatever rise a reader's own default \super/\sub metrics would otherwise pick —
        // WordStar's `.sr` is a real, page-declared value, not a suggestion. `\super`/
        // `\sub` above still carry the SEMANTIC tag (reflow/accessibility); `\up`/`\dn`
        // is the direct-formatting doctrine's own answer for the exact rise amount, same
        // relationship `\fi` has with `.pm`. Printed only.
        if printed, let rollHalfPt {
            if theseStyles.contains(.sup) { c += #"\up\#(rollHalfPt) "# }
            else if theseStyles.contains(.sub) { c += #"\dn\#(rollHalfPt) "# }
        }
        c += span.font.flatMap { fontControl[$0] } ?? ""
        // planning #252 (Jon's ruling 2026-09-09): a run no WS5+ font block covers
        // (`span.font == nil`, the same test `fontControlRTF`/pdf.py's
        // `modernTokFont` use) gets Courier instead of the inherited `\f0` body
        // default, but ONLY in a document that declares fonts elsewhere AND
        // declares itself non-proportional (`.ps off` -- `nonpropFallback`,
        // resolved once per document in `emitRTF`, Modern only). `\f1` is always
        // Courier New in this emitter's own `\fonttbl` (see the graphic-text
        // override just below and `emitRTF`'s literal `{\f1 Courier New;}`) --
        // reusing that slot rather than adding a target-varying one, same face
        // either way. Ported from ctrl-kd emit.py's identical addition.
        if nonpropFallback, span.font == nil { c += #"\f1 "# }
        if inlineStyling, let colour = span.colour {
            // b24 round 18 (RULINGS-LEDGER row 10): WordStar's own inline colour
            // (symmetric type 1) -- direct `\cfN` against the fixed 16-colour CGA table
            // (`rtfColourTable`/`rtfColourNum`), the same "the author's own styling
            // shows by default" doctrine as inline font-size above. `--inline-styling
            // off` strips this AND the font-size half of `fontControl` (see
            // `fontControlRTF`'s own gate) but never the font FAMILY switch, which is
            // document rendering, not an author styling CHOICE.
            c += #"\cf\#(rtfColourNum(colour)) "#
        }
        // `\f1` (Courier New) is ALWAYS in the font table regardless of the document's
        // own fonts (see the `\fonttbl` literal in `emitRTF`), appended last so it wins
        // the font-table reference while any `\fs` size already chosen above is left
        // alone. Same reasoning as HTML's `ws-graphic` override. Port of round 8
        // (SCRIPT.WS).
        if isGraphicText(span.text) { c += #"\f1 "# }
        return c
    }
    let controls = buildCtl(span.styles)
    guard span.styles.contains(.fnref) else {
        // Jon's ruling 2026-08-20 (reverses b24 round 17b; RULINGS-LEDGER row 5/6,
        // register C21) flipped the DEFAULT to continuous — see `rules`'s own docstring
        // (PDFWriter.swift) for the evidence. This per-piece split only still fires when
        // `.ul off` is explicit (`ulContinuous == false`): splits the span at each run of
        // space characters, wrapping ONLY the non-space runs in `\ul` (via `buildCtl`
        // on the style set minus `.underline`) — every OTHER attribute (bold, font,
        // roll) still applies uniformly across the whole span.
        if span.styles.contains(.underline), !ulContinuous,
           span.text.contains(where: { !$0.isWhitespace }), span.text.contains(" ") {
            let ctlNoU = buildCtl(span.styles.subtracting(.underline))
            var parts: [String] = []
            let chars = Array(span.text)
            var i = 0
            let n = chars.count
            while i < n {
                var j = i
                if chars[i] == " " {
                    while j < n, chars[j] == " " { j += 1 }
                    parts.append("{" + ctlNoU + rtfEscape(String(chars[i..<j])) + "}")
                } else {
                    while j < n, chars[j] != " " { j += 1 }
                    parts.append("{" + controls + rtfEscape(String(chars[i..<j])) + "}")
                }
                i = j
            }
            return parts.joined()
        }
        return "{" + controls + rtfEscape(span.text) + "}"
    }
    switch resolveReference(span, refNotes: refNotes, labels: labels, options: options) {
    case .note(let note, let label, let index):
        if note.kind == .comment {
            // Printed is a facsimile: WordStar printed nothing for a comment, so
            // neither do we (the CLI explains on stderr). Modern anchors a real Word
            // margin comment at the TRUE position (the end-of-document dump this
            // replaces lost it); `prefixed` adds the visible c-mark, `word` stays
            // markless — Word's own convention is a bubble, not a superscript. (M9)
            if printed { return "" }
            let mark = shownMap.flatMap { $0[index] }.map { "{\\super " + rtfEscape($0) + "}" } ?? ""
            return mark + rtfComment(note, sentenceSpacing: sentenceSpacing)
        }
        // `prefixed` (M8): endnotes/annotations anchor with literal e1/a1 custom marks
        // in place of \chftn/tags — the Markdown emitter's own labels, matched across
        // formats. Never printed: the facsimile shows what WordStar printed.
        let override: String?
        if let shownMap, note.kind == .endnote || note.kind == .annotation {
            override = shownMap[index]
        } else {
            override = nil
        }
        return rtfReferenceMarker(note, label: label, markOverride: override)
            + rtfDestination(note, label: label, markOverride: override, sentenceSpacing: sentenceSpacing)
    case .excluded:
        return ""
    case .invalid:
        return "{" + controls + rtfEscape(span.text) + "}"
    }
}

/// The `\fonttbl` entries and the per-run control words for a document's font runs:
/// one `\fK` per DISTINCT RESOLVED PRIMARY (numbering starts at 2, after the emitter's
/// own `\f0` Times and `\f1` Courier), plus `\fsN` from the block's own height word.
///
/// Primary + falt come from `rtfFonts` for the chosen render TARGET (office/mac/google —
/// Jon's ruling, 2026-08-04 night): the primary is the target's best available name, the
/// falt the next-best MODERN name — never the era name, which nothing modern resolves
/// ('PS SansSer Qual'). Unmapped and even UNNAMED fonts land on the target's generic
/// primary from the font block's own style bits, so every run gets a usable face. The
/// verbatim era name stays first-class in `Document.fonts` and leads the HTML stacks,
/// where CSS fallback works properly.
///
/// Dedupe is by PRIMARY, not by era family: two era names that resolve to the same face
/// share one `\fK`, which is what the file is actually asking the renderer for.
/// Python's `_font_ctl_rtf` (emit.py).
func fontControlRTF(_ doc: Document, target: FontsTarget = .office,
                    inlineStyling: Bool = true) -> (fontTable: String, control: [Int: String]) {
    var extra = ""
    var control: [Int: String] = [:]
    var primaryToK: [String: Int] = [:]
    var nextK = 2
    for (index, font) in doc.fonts.enumerated() {
        var parts = ""
        let (primary, falt) = rtfFonts(font.family, generic: font.genericStyle, target: target,
                                       proportional: font.proportional)
        if let primary {
            if primaryToK[primary] == nil {
                primaryToK[primary] = nextK
                // The three characters that would break out of the group, removed —
                // not `rtfEscape`, since a font name is a name (as in `rtfStylesheet`).
                var safe = ""
                for character in primary where character != "\\" && character != "{" && character != "}" {
                    safe.append(character)
                }
                if let falt, falt != primary {
                    extra += "{\\f\(nextK) \(safe){\\*\\falt \(falt)};}"
                } else {
                    extra += "{\\f\(nextK) \(safe);}"
                }
                nextK += 1
            }
            parts += "\\f\(primaryToK[primary]!)"
        }
        // Python tests the float's own truthiness: a zero height is not a size.
        // b24 round 18 (RULINGS-LEDGER row 10): gated ONLY for a genuinely INLINE
        // (mid-text) font change -- `font.offset` is the byte position of a REAL
        // symmetric type-2 block, -1 (Python's `None`) for a font that came from a
        // paragraph STYLE's own record instead. A style's declared size is document
        // formatting, not "the author's own inline styling", and stays unconditional --
        // `--inline-styling off` never touches it.
        if font.points != 0, inlineStyling || font.offset < 0 {
            parts += "\\fs\(roundHalfToEven(font.points * 2.0))"
        }
        if !parts.isEmpty {
            control[index] = parts + " "
        }
    }
    return (fontTable: extra, control: control)
}

/// A comment (opt-in only): WordStar's own annotation construct, `\chatn`/`\*\atnid`/
/// `\*\annotation` — unlike footnote/endnote/annotation these render as their own trailing
/// block after every paragraph, not inline (comments have no inline reference to attach
/// to). `ctrl-kd` is the literal author id Python's emitter writes; there's no per-note
/// identity to carry since a comment has neither a number nor a tag.
private func rtfComment(_ note: Note, sentenceSpacing: Bool = false) -> String {
    let noteText = sentenceSpacing ? sentenceSpacingTexts([note.text])[0] : note.text
    return #"{\chatn}{\*\atnid ctrl-kd}{\*\annotation \pard\plain\fs24 "# + rtfEscape(noteText) + "}"
}

/// - Parameter options: `options.notes` decides which note kinds get an inline reference
///   (footnote/endnote/annotation) or a trailing comment block; `options.title` is
///   ignored, as in Python (emit.py:208).
@Sendable
/// RTF paragraph-alignment control. `\ql` is the default and is emitted only to CLOSE a
/// previous alignment, since RTF alignment persists across `\par`.
func rtfAlignControl(_ align: Alignment) -> String {
    switch align {
    case .left: return #"\ql "#
    case .center: return #"\qc "#
    case .right: return #"\qr "#
    case .justify: return #"\qj "#
    }
}

/// Spans minus leading/trailing spaces — for center/right blocks under Modern.
/// WordStar 5+ aligned at EDITOR time, so the file carries BOTH the alignment tag and
/// the spaces that implemented it; emitting both aligns twice (ruling 2026-08-06).
/// The tag does the work now. Port of `_strip_align_spaces`.
func stripAlignSpaces(_ spans: [Span]) -> [Span] {
    var out = spans
    while let first = out.first {
        let t = String(first.text.drop(while: { $0 == " " }))
        if !t.isEmpty {
            if t != first.text {
                var span = first
                span.text = t
                out[0] = span
            }
            break
        }
        out.removeFirst()
    }
    while let last = out.last {
        var t = last.text
        while t.hasSuffix(" ") { t.removeLast() }
        if !t.isEmpty {
            if t != last.text {
                var span = last
                span.text = t
                out[out.count - 1] = span
            }
            break
        }
        out.removeLast()
    }
    return out
}

/// WordStar print-toggle bytes that legitimately appear inside header/footer TEXT (a
/// `.h1` line carries them raw — LJ6DTP's is `^B^BLJ6DTP ... ^B`). Interpreted minimally
/// here: toggles flip a style, every other control byte is stripped (0x0F print-control
/// lead-ins included). U+2219 maps to the cp1252-friendly bullet so PDF measurement and
/// drawing agree; one glyph, consistent across formats. Port of `_HF_TOGGLES`.
private let hfToggles: [UInt32: Style] = [
    0x02: .bold, 0x19: .italic, 0x13: .underline,
    0x14: .sup, 0x16: .sub, 0x18: .strike,
]

/// A running-head string -> [(text, styles)] with WordStar's own toggle bytes interpreted
/// and remaining control bytes stripped. Returns [] for a head that is nothing but
/// control bytes (LJ6DTP's `.f1` is two 0x0F bytes) — callers skip those instead of
/// rendering junk. Port of `hf_runs` (M10).
func hfRuns(_ txt: String) -> [(text: String, styles: Style)] {
    var runs: [(text: String, styles: Style)] = []
    var buf = ""
    var active: Style = []
    func flush() {
        if !buf.isEmpty {
            runs.append((buf, active))
            buf = ""
        }
    }
    for scalar in txt.replacingAll("\u{2219}", with: "\u{2022}").unicodeScalars {
        if let toggle = hfToggles[scalar.value] {
            flush()
            active.formSymmetricDifference(toggle)
            continue
        }
        if scalar.value < 0x20 { continue }
        buf.unicodeScalars.append(scalar)
    }
    flush()
    // whitespace runs SURVIVE (a head positions its parts with baked spaces); only a
    // head with no visible text at all empties out
    if !runs.contains(where: { !$0.text.trimmed().isEmpty }) {
        return []
    }
    return runs
}

/// `{slot: {parity: text}}` for one head/foot family — every `.he`/`.h1`-`.h5`/`.fo`/
/// `.f1`-`.f5` the document declared, keyed by line slot and then by PAGE PARITY: `.odd`
/// for `.h1o`/`.f1o` (the right-hand page), `.even` for `.h1e`/`.f1e`, `nil` for a plain
/// definition that applies to both. `hfEventsParity` is INDEX-ALIGNED with `hfEvents`
/// (planning #250); first definition of each (slot, parity) wins, exactly as the flat
/// reading did before parity existed. Port of `_hf_slots`.
func hfSlots(_ doc: Document, _ which: HFKind) -> (slots: [Int: [HFParity?: String]],
                                                   firstAnchor: Int?) {
    var slots: [Int: [HFParity?: String]] = [:]
    var firstAnchor: Int? = nil
    for (i, event) in doc.hfEvents.enumerated() {
        guard event.kind == which, !event.text.isEmpty else { continue }
        let parity: HFParity? = i < doc.hfEventsParity.count ? doc.hfEventsParity[i] : nil
        var byParity = slots[event.line] ?? [:]
        if byParity[parity] == nil {
            byParity[parity] = event.text
            slots[event.line] = byParity
            if firstAnchor == nil || event.blockAnchor < firstAnchor! {
                firstAnchor = event.blockAnchor
            }
        }
    }
    return (slots, firstAnchor)
}

/// `{slot: {parity: text}}` for one head/foot family AS IT STOOD at block `anchor` — the
/// LAST definition of each (slot, parity) declared at or before that block, which is
/// WordStar's own reading: a `.he`/`.fo` replaces the one before it from where it is
/// typed onward.
///
/// The document-wide `hfSlots` keeps the FIRST definition instead, because RTF carried
/// one header per file and had to pick one. This is the per-SECTION answer the spine
/// needs (planning #264 R1, packet row A13) and it deliberately does not replace the
/// other: section 1 is still written from `hfSlots`, so every document that defines each
/// slot exactly once — almost all of them — emits the bytes it always did. Port of
/// `_rtf_hf_slots_at`.
func rtfHFSlotsAt(_ doc: Document, _ which: HFKind, anchor: Int) -> [Int: [HFParity?: String]] {
    var slots: [Int: [HFParity?: String]] = [:]
    for (i, event) in doc.hfEvents.enumerated() {
        guard event.kind == which, !event.text.isEmpty, event.blockAnchor <= anchor
        else { continue }
        let parity: HFParity? = i < doc.hfEventsParity.count ? doc.hfEventsParity[i] : nil
        var byParity = slots[event.line] ?? [:]
        byParity[parity] = event.text
        slots[event.line] = byParity
    }
    return slots
}

/// Block anchors at which a running head or foot is REDEFINED — a second or later
/// definition of the same (kind, slot, parity) whose text differs from the one already in
/// force (packet row A13).
///
/// A slot defined once, however late, is not a redefinition: that is the ordinary "this
/// document has a running head" case, which section 1 already carries (with `\titlepg`
/// when it starts after page 1). Port of `_rtf_hf_redefinitions`.
func rtfHFRedefinitions(_ doc: Document) -> Set<Int> {
    struct Key: Hashable {
        let kind: HFKind
        let line: Int
        let parity: HFParity?
    }
    var inForce: [Key: String] = [:]
    var anchors: Set<Int> = []
    for (i, event) in doc.hfEvents.enumerated() {
        guard !event.text.isEmpty else { continue }
        let parity: HFParity? = i < doc.hfEventsParity.count ? doc.hfEventsParity[i] : nil
        let key = Key(kind: event.kind, line: event.line, parity: parity)
        if let previous = inForce[key], previous != event.text, event.blockAnchor > 0 {
            anchors.insert(event.blockAnchor)
        }
        inForce[key] = event.text
    }
    return anchors
}

/// One `(columns, gutter)` pair per block — the newspaper-column regime in force at each.
///
/// A document begins outside any columnar region, so the state before the first `.co` is
/// one column. A block with no columns opinion (`nil`: the sentinel `pagebreak`/
/// `colbreak`/`condpage`/`condcolumn` blocks, and everything before the first `.co`)
/// INHERITS the state around it rather than reading as one column — the same "real blocks
/// only" rule `docToPagelines`' own `prevCols` tracker follows. `.co1` (columns OFF)
/// normalises to `(1, nil)` whatever gutter it carries, so turning columns off and on
/// again with a different gutter opens one section, not two. Port of
/// `_rtf_columns_state`.
func rtfColumnsState(_ doc: Document) -> [(cols: Int, gutter: Double?)] {
    var out: [(cols: Int, gutter: Double?)] = []
    var current: (cols: Int, gutter: Double?) = (1, nil)
    for block in doc.blocks {
        if let cols = block.columns {
            current = cols > 1 ? (cols, block.columnGutter) : (1, nil)
        }
        out.append(current)
    }
    return out
}

/// 10-CPI print column -> twips, for a `.co` gutter.
let rtfTwipsPerColGutter = 144.0

/// `\cols`/`\colsx` for one section, or "" for a single column.
///
/// `.co n, gutter` (packet row A7): the gutter is print columns at 10 CPI, the same unit
/// `.po` uses, so it converts at 144 twips a column. WordStar's own default gap when the
/// author names none is one print column. Port of `_rtf_cols_control`.
func rtfColsControl(_ cols: Int, _ gutter: Double?) -> String {
    guard cols > 1 else { return "" }
    let gap = Int(roundHalfToEven((gutter ?? 1) * rtfTwipsPerColGutter))
    return #"\cols\#(cols)\colsx\#(gap)"#
}

/// `[blockIndex: (keep, keepn)]` — the paragraphs `.cp n`/`.cc n` asked to be kept
/// together (planning #264 R2, packet row A8, ruled 2026-09-14 "Yes add it").
///
/// WHAT WORDSTAR ASKED FOR. `.cp n` says "break to a new page unless at least n lines
/// still fit here", and `.cc n` says the same of a column. The author's purpose is never
/// the break: it is that the n lines AFTER the command arrive together — `.cp` exists
/// precisely so a heading is not stranded at the foot of a page.
///
/// WHAT RTF CAN SAY. Not "break here" — R6 declined imposed page positions outright, and
/// a reader paginating with its own fonts would fight one anyway. It can say `\keepn`
/// (keep this paragraph with the next) and `\keep` (do not split this paragraph across a
/// page), which are CONSTRAINTS the reader honours while paginating rather than positions
/// imposed on it. That is the packet's own reason this row works where A12's did not.
///
/// THE MAPPING. After a `.cp n`/`.cc n`, the following `para` blocks are walked until
/// their combined stored-line count first reaches n. Every paragraph in that run gets
/// `\keep`; every one but the LAST also gets `\keepn`. A run of one paragraph — the
/// common case in Printed RTF, where a whole WordStar block is one `\par` with `\line`
/// separators — gets `\keep` alone, because the n lines the author asked for are already
/// inside it. The line count is the document's OWN stored lines, the same number the
/// printed paginator counts, in both modes: `n` is a fact about the file, not about a
/// reader's measure. Port of `_rtf_keep_plan`.
func rtfKeepPlan(_ doc: Document) -> [Int: (keep: Bool, keepn: Bool)] {
    var plan: [Int: (keep: Bool, keepn: Bool)] = [:]
    for (bi, block) in doc.blocks.enumerated() {
        guard block.kind == .condpage || block.kind == .condcolumn else { continue }
        let want = max(1, block.heading)
        var run: [Int] = []
        var counted = 0
        var k = bi + 1
        while k < doc.blocks.count {
            let next = doc.blocks[k]
            if next.kind == .condpage || next.kind == .condcolumn {
                k += 1
                continue                      // a sentinel spends no lines
            }
            if next.kind != .para { break }   // a real break ends the run
            let lines = mergedLines(next).count
            if lines == 0 {
                k += 1
                continue
            }
            run.append(k)
            counted += lines
            if counted >= want { break }
            k += 1
        }
        for (j, index) in run.enumerated() {
            let existing = plan[index] ?? (false, false)
            plan[index] = (true, existing.keepn || j < run.count - 1)
        }
    }
    return plan
}

/// One entry per section AFTER the first — THE SECTION SPINE (planning #264 R1, ruled
/// 2026-09-14; packet section 3's recommendation and rows A7/A9/A13).
///
/// The first section is the one the document's own page setup and `rtfRunningHeads`
/// already write. A section opens where the document's own geometry changes, and nowhere
/// else — no imposed page positions (R6 declined those outright), so an RTF reader still
/// paginates inside every section exactly as it does today.
///
/// TWO things open one:
///
///   A7  a change of newspaper-column regime (`.co n, gutter`). BOTH MODES since M17b
///       (2026-09-15). R1 made this Printed-only on the stated grounds that "Modern PDF
///       has no column model at all, and the 2026-08-05 ruling is that Modern PDF needs
///       to be the printed version of the Modern RTF — so a columnar Modern RTF would be
///       a Modern RTF its own PDF could not render". Modern PDF has a column model now
///       (M17, `modernColumnWidth`), so the same ruling read the same way now says the
///       opposite: a ONE-column Modern RTF is the one its own PDF cannot render.
///       (Modern HTML's `column-count` is a separate, older surface and is untouched.)
///   A13 a running head or foot REDEFINED mid-document. The new section carries its own
///       `\header`/`\footer` groups.
///
/// `.cb` (row A9) is NOT a section break: it is `\column`, a break to the next column
/// INSIDE a section, written by the body loop.
///
/// Deliberately not here, and not ruled here: a mid-document `.pn` re-anchor
/// (`\pgnrestart\pgnstarts`), and a mid-document `.po`/margin change. R1 names A7, A9
/// and A13; those are the three built. Port of `_rtf_section_breaks`.
struct RTFSection {
    let cols: Int
    let gutter: Double?
    let headerSlots: [Int: [HFParity?: String]]
    let footerSlots: [Int: [HFParity?: String]]
}

func rtfSectionBreaks(_ doc: Document) -> [Int: RTFSection] {
    var anchors = rtfHFRedefinitions(doc)
    let state = rtfColumnsState(doc)
    for (bi, block) in doc.blocks.enumerated() {
        // Only a REAL block opens a column regime: a sentinel inherits the state
        // around it and must not read as a change.
        guard block.columns != nil, bi > 0 else { continue }
        if state[bi] != state[bi - 1] { anchors.insert(bi) }
    }
    var out: [Int: RTFSection] = [:]
    for bi in anchors where bi > 0 && bi < doc.blocks.count {
        let pair: (cols: Int, gutter: Double?) = state[bi]
        out[bi] = RTFSection(cols: pair.cols, gutter: pair.gutter,
                             headerSlots: rtfHFSlotsAt(doc, .header, anchor: bi),
                             footerSlots: rtfHFSlotsAt(doc, .footer, anchor: bi))
    }
    return out
}

/// `{slot: text}` for one side of the sheet. A slot defined only for the OTHER parity
/// prints nothing on this side — which is the whole point of `.h1o`/`.h1e` — while a
/// plain definition applies to both. Port of `_hf_variant`.
func hfVariant(_ slots: [Int: [HFParity?: String]], _ parity: HFParity?) -> [Int: String] {
    var out: [Int: String] = [:]
    for (line, byParity) in slots {
        if let text = byParity[parity] ?? byParity[HFParity?.none] ?? nil, !text.isEmpty {
            out[line] = text
        }
    }
    return out
}

/// One per-line head/foot attribute for one page parity, with the same "parity wins,
/// plain is the fallback" rule `hfVariant` applies to the text. Port of `_hf_attr`.
func hfAttr<T>(_ plain: [Int: T], _ byParity: [Int: [HFParity: T]],
               _ parity: HFParity?) -> [Int: T] {
    guard let parity else { return plain }
    var out = plain
    for (line, per) in byParity {
        // A slot that declares ANY parity variant answers PER PARITY, and a parity that
        // names no value has none -- assigning `nil` removes the key, so the flat
        // last-in-source-order fallback never leaks across sides. Python records that
        // case as an explicit `None` inside the parity dict ("Header Even" selects a
        // style that declares no alignment while "Header Odd" declares flush right, the
        // corpus's own booklet templates); a Swift dictionary cannot hold a nil value,
        // so an ABSENT key means the same thing here.
        out[line] = per[parity]
    }
    return out
}

/// `(\headery, \footery)` in twips, or `(nil, nil)` for Modern (planning #264 item 4,
/// packet row A5).
///
/// WordStar anchors the header block to the BODY, not to the paper edge: its last line
/// sits `.hm` lines above the first body line, inside `.mt`. The PDF resolves that as
/// `headBase = max(0, mt - hm - topHead)` whole 12pt lines from the top of the sheet
/// (`resolveHeadFootLines`, mechanism W — `hm` participates unconditionally, confirmed
/// against the PRISTINE.EXE recapture), and the footer as line `pl - mb + fm`, which
/// leaves `mb - fm - 1` lines under it. `\headery`/`\footery` are exactly those two
/// distances, so RTF's own gap matches the page the PDF draws instead of the reader's
/// default.
///
/// PRINTED ONLY. Modern's page is its own fixed Letter and Modern carries no vertical
/// space of ours (ruling 2026-08-17, "never Modern"; packet row D9) — a Modern reader
/// keeps its own head/foot gap, the same way it keeps its own leading. Port of
/// `_rtf_head_foot_distance`.
func rtfHeadFootDistance(_ page: PageGeometry?, headSlots: [Int],
                         printed: Bool) -> (headery: Int?, footery: Int?) {
    guard printed else { return (nil, nil) }
    let line = 240.0                                 // one line at 6 LPI
    let mt = page?.mtLines ?? 3.0
    let hm = page?.hmLines ?? 2.0
    let topHead = Double(headSlots.max() ?? 1)
    let mb = page?.mbLines ?? 8.0
    let fm = page?.fmLines ?? 2.0
    return (roundHalfToEven(max(0.0, mt - hm - topHead) * line),
            roundHalfToEven(max(0.0, mb - fm - 1.0) * line))
}

/// `(.poe, .poo)` in print columns, or `(nil, nil)` — the document's own even/odd page
/// offsets (planning #231), resolved AT BLOCK 0.
///
/// The same `poeOrPooCheckpoints`/`poAt` machinery `closePage` and `resolveHeadFootLines`
/// already use, called at block 0 because RTF has one section: whatever is in force where
/// the document opens is the only answer this format can carry. Block 0 is also the only
/// anchor a `.DOT` TEMPLATE has at all — the corpus's galley and advance templates declare
/// `.poe`/`.poo` (and their `.h1o`/`.h1e` pair) before any block would ever open, and have
/// no body lines for the per-line `Line.poeCols`/`pooCols` state to ride on. Port of
/// `_rtf_po_parity`.
func rtfPoParity(_ doc: Document) -> (poe: Double?, poo: Double?) {
    let poeList = poeOrPooCheckpoints(doc, dotName: "POE")
    let pooList = poeOrPooCheckpoints(doc, dotName: "POO")
    return (poeList.isEmpty ? nil : poAt(poeList, 0),
            pooList.isEmpty ? nil : poAt(pooList, 0))
}

/// The alignment control a head/foot group's own paragraph carries (planning #264 item 4,
/// packet row A4): the `.h#`/`.f#` argument's embedded style-sheet reference, resolved by
/// the parser into `headerAlign`/`footerAlign` (planning #255).
private let rtfHFAlign: [Alignment: String] = [.right: #"\qr"#, .center: #"\qc"#]

/// Whether WordStar's own AUTOMATIC page number — the one `.pc` positions, never a `#`
/// the author typed into a real `.he`/`.fo` — is on for this document (planning #264 item
/// 3, packet row A1).
///
/// `.auto` (the default) asks the document's own `.pn`/`.pg`/`.op` state, the same
/// `pgnumCheckpoints` the PDF reads, resolved AT THE DOCUMENT'S FIRST BLOCK: RTF has one
/// section and one footer, so a document that turns numbering off half-way through cannot
/// be expressed here (that needs the section spine, packet section 3, deliberately not
/// built). `.on`/`.off` force it either way, exactly as for the PDF. Port of
/// `_rtf_auto_page_number`.
/// Is a FOOTER declared at all — with text, bare, or carrying only invisible characters?
/// Port of `_rtf_footer_in_use`.
///
/// The question WordStar's automatic page number turns on ("active only when the footers
/// are not in use", WSFORMAT.WS), and deliberately NOT the same question as "is there
/// footer text to draw". `hfSlots` is the drawing answer and drops an event with no text;
/// this is the declaration answer and counts it, matching `closePage`'s own
/// `footerInUse = !pageFtrs.isEmpty` taken before the empty slots are dropped.
///
/// `slots` is `rtfRunningHeads`' own argument: nil for the document (section 1, which is
/// the whole document for every file that opens no later section), or a resolved
/// head/foot pair for a later section — in which case that section's own already-resolved
/// footer slots are the answer, because `rtfHFSlotsAt` is what decided them.
func rtfFooterInUse(_ doc: Document,
                    slots: (header: [Int: [HFParity?: String]],
                            footer: [Int: [HFParity?: String]])?) -> Bool {
    if let slots { return !slots.footer.isEmpty }
    return doc.hfEvents.contains { $0.kind == .footer }
}

func rtfAutoPageNumber(_ doc: Document, _ mode: EmitOptions.PageNumberMode) -> Bool {
    switch mode {
    case .off: return false
    case .on: return true
    case .auto: return pgnumAt(pgnumCheckpoints(doc), 0)
    }
}

/// RTF `\header`/`\footer` groups from the document's own running heads (ruling
/// 2026-08-06: Modern keeps headers).
///
/// Planning #264 item 3 (packet row A1): a document that declares no footer of its own
/// still gets WordStar's automatic page number, centred at the foot of every page — a
/// `\footer` group carrying `\chpgn`, the reader's own current-page field. The PDF's
/// rule, unchanged here: the automatic number appears only when no `.fo` is IN USE
/// (WSFORMAT.WS, "active only when the footers are not in use") — a declared footer
/// pre-empts it, and a `#` inside that footer is already rendered as `\chpgn` below.
/// "In use" is a property of the DOCUMENT, not of what we end up drawing: the corpus's
/// LJ6DTP document declares an `.f1` of two 0x0F bytes that renders nothing visible, and
/// its automatic number still stays off — exactly what `closePage` records
/// (`footerInUse = !pageFtrs.isEmpty`, before the empty slots are dropped). `headers`
/// gates the running heads and feet this function writes, and NOT the automatic number:
/// planning #264 R7 (ruled 2026-09-14) separates the two flags — "a header or footer
/// that contains a page number is controlled by header flag but a page number on its own
/// is controlled by the page number flag" — so a `#` the author typed into a real
/// `.he`/`.fo` goes with its head, and WordStar's own automatic number answers to
/// `--page-numbers` alone.
///
/// Planning #264 item 5: the head's OWN print attributes (`headerStyleAttrs`/
/// `footerStyleAttrs`, the same style-sheet reference the alignment is read from,
/// planning #255) join every run on their line, exactly as a body paragraph's
/// `styleAttrs` do — so a head whose bold comes from its style, not from an inline
/// toggle byte, prints bold here as it already does in the PDF. Per line and per parity,
/// so a two-sided template's two variants can differ.
///
/// RTF carries ONE header per section; a document that redefines its head mid-file keeps
/// the FIRST definition of each line slot (the common case — OLDTIMES — defines each
/// exactly once). WordStar's `#` token becomes `\chpgn`, Word's own page-number field. A
/// head first defined after the opening block gets `\titlepg` with an empty first-page
/// header: the manuscript convention (no running head on page 1), and exactly what
/// WordStar itself printed when `.h1` follows page 1's title. Port of
/// `_rtf_running_heads`.
private func rtfRunningHeads(_ doc: Document, headers: Bool = true,
                             autoPageNumber: Bool = false,
                             printed: Bool = true,
                             slots: (header: [Int: [HFParity?: String]],
                                     footer: [Int: [HFParity?: String]])? = nil)
    -> (groups: String, facingPages: Bool, headery: Int?, footery: Int?) {
    // planning #264 R1 (packet row A13): `slots`, when given, is a LATER section's own
    // head/foot state, resolved by `rtfHFSlotsAt`. The `\titlepg` rule below is the
    // document's first page and belongs to section 1 alone, so a section handed its slots
    // never asks for one.
    let hdrAll = slots?.header ?? hfSlots(doc, .header).slots
    let ftrAll = slots?.footer ?? hfSlots(doc, .footer).slots
    let firstAnchor: Int? = slots == nil
        ? [hfSlots(doc, .header).firstAnchor, hfSlots(doc, .footer).firstAnchor]
            .compactMap { $0 }.min()
        : nil
    // "In use" is a property of the DOCUMENT, not of what we end up drawing, and not of
    // the `headers` flag — see this function's own doc comment. Planning #264 R7 (ruled
    // 2026-09-14): `headers` no longer enters into it at all. The first RTF batch made
    // `--headers off` swallow the automatic number too; that is reverted here, on both
    // surfaces.
    //
    // M15 FOLLOW-UP (2026-09-15): that is what the paragraph above says, and `ftrAll` was
    // not it. `hfSlots` drops an event with NO text at all, so a document whose only
    // footer command is a BARE `.fo` read as "no footer in use" and RTF printed the
    // automatic number on it — while both PDFs, reading `footerInUse` off the un-dropped
    // slots, printed none. Real WS7 prints none: "That holds whether the footer has text,
    // is bare, or contains only invisible characters"
    // (research/2026-09-15_ws7-missing-auto-page-number.md, rule 2; the same rule the
    // PDF's own triage cause 1 fixed on 2026-09-12). Five documents in the public archive
    // are that shape — MACROS/HOLYMAC/4MAC2, 4MAC3, 7MAC2, 7MAC3 and LSRBOX/LSRBOX.WS,
    // four of them named in that research as WS7 printing no number on any of their
    // 41/53/35/35 pages — and their `rtf.printed` and `rtf.modern` both move with it.
    let showAutoNum = autoPageNumber && !rtfFooterInUse(doc, slots: slots)
    let hdrSlots = headers ? hdrAll : [:]
    let ftrSlots = headers ? ftrAll : [:]
    let (headery, footery) = rtfHeadFootDistance(doc.page,
                                                 headSlots: Array(hdrSlots.keys),
                                                 printed: printed)
    if hdrSlots.isEmpty, ftrSlots.isEmpty, !showAutoNum {
        // Nothing is drawn in either margin, so there is no gap to state.
        return ("", false, nil, nil)
    }
    // planning #264 item 1: a running head is the document's own text and takes the
    // driver's substitutions like any other (`emitRTF`'s own document-wide pass cannot
    // reach it — a head lives in `hfEvents`, not in a block). The head's FACE is
    // `headerFonts`/`footerFonts`' own `doc.fonts` index (register C6), handed to the
    // substituter exactly as a body span's `font` is, so the same
    // proportional-only/Univers-only face rules apply.
    let subst = driverSubstituter(doc)

    func group(_ name: String, _ lines: [Int: String], _ faces: [Int: Int],
               _ aligns: [Int: Alignment], _ attrs: [Int: Style]) -> String {
        if lines.isEmpty { return "" }
        var rendered: [String] = []
        var lineAligns: [String] = []
        for n in lines.keys.sorted() {
            let text = subst.map { $0(lines[n]!, faces[n]) } ?? lines[n]!
            let runs = hfRuns(text)
            if runs.isEmpty { continue }                 // control-bytes-only head (M10)
            lineAligns.append(aligns[n].flatMap { rtfHFAlign[$0] } ?? "")
            // planning #264 item 5 (planning #255's `headerStyleAttrs`): the print
            // attributes the head's OWN style turns on. A `.h#`/`.f#` argument can name
            // a style-sheet entry, and that entry's bold/italic/underline belong to
            // every run on the line exactly as a body paragraph's `styleAttrs` do --
            // core parses them, the PDF has drawn them since #255
            // (`hfNaturalWidthPt`'s own `styles.union(styleAttrs)`), and RTF read only
            // the line's inline toggle bytes, so a head whose weight came from its
            // style printed light. The corpus's galley template is the case: its
            // `.h1o`/`.h1e` both declare a bold style and carry no toggle byte at all.
            let lineAttrs = attrs[n] ?? []
            rendered.append(runs.map { run in
                "{" + rtfStyleControls(run.styles.union(lineAttrs))
                    + rtfEscape(run.text).replacingAll("#", with: #"{\chpgn }"#) + "}"
            }.joined())
        }
        if rendered.isEmpty { return "" }
        // ONE PARAGRAPH while every rendered line agrees on its alignment — which is
        // every head and foot in the corpus but one, so this is byte-identical to the
        // single-paragraph group RTF has always written. Planning #264 item 4 (row A4)
        // applied the FIRST line's alignment to the whole group on the stated grounds
        // that "no corpus document declares two head lines with different alignments";
        // `sawyer/REF/BOOKLET.WS` does (a right-aligned "Header Odd" over a left-aligned
        // "Header Even"), and the group right-aligned both. `\line` is a break INSIDE a
        // paragraph and cannot carry a second alignment, so the lines that disagree get
        // a paragraph each — the only form RTF has for this — and the reader lays them
        // out exactly as Modern PDF now draws them (2026-08-05: Modern PDF is the
        // printed form of the Modern RTF).
        if Set(lineAligns).count <= 1 {
            let body = rendered.joined(separator: #"\line "#)
            return #"{\\#(name) \pard\plain \#(lineAligns[0])\f0\fs22 \#(body)\par}"#
        }
        let paras = zip(lineAligns, rendered)
            .map { #"\pard\plain \#($0)\f0\fs22 \#($1)\par"# }
            .joined()
        return #"{\\#(name) \#(paras)}"#
    }

    /// One head/foot family, as `\headerl`/`\headerr` when the document declares a parity
    /// variant anywhere in it, else the plain single group it always was.
    func sided(_ name: String, _ slots: [Int: [HFParity?: String]],
               _ plainFonts: [Int: Int], _ parityFonts: [Int: [HFParity: Int]],
               _ plainAligns: [Int: Alignment],
               _ parityAligns: [Int: [HFParity: Alignment]],
               _ plainAttrs: [Int: Style],
               _ parityAttrs: [Int: [HFParity: Style]]) -> (String, Bool) {
        let hasParity = slots.values.contains { $0.keys.contains { $0 != nil } }
        if !hasParity {
            return (group(name, hfVariant(slots, nil), plainFonts, plainAligns,
                          plainAttrs), false)
        }
        var out = ""
        for (parity, side) in [(HFParity.odd, name + "r"), (HFParity.even, name + "l")] {
            out += group(side, hfVariant(slots, parity),
                         hfAttr(plainFonts, parityFonts, parity),
                         hfAttr(plainAligns, parityAligns, parity),
                         hfAttr(plainAttrs, parityAttrs, parity))
        }
        return (out, !out.isEmpty)
    }

    let (headGroup, headFacing) = sided("header", hdrSlots, doc.headerFonts,
                                        doc.headerFontsParity, doc.headerAlign,
                                        doc.headerAlignParity, doc.headerStyleAttrs,
                                        doc.headerStyleAttrsParity)
    var (footGroup, footFacing) = sided("footer", ftrSlots, doc.footerFonts,
                                        doc.footerFontsParity, doc.footerAlign,
                                        doc.footerAlignParity, doc.footerStyleAttrs,
                                        doc.footerStyleAttrsParity)
    if showAutoNum {
        // WordStar's stock automatic number: bottom of the page, centred. `.pc`
        // repositions it on the printed page; RTF's footer is a paragraph, so the
        // position it can honestly carry is its ALIGNMENT, and centred is both
        // WordStar's own default and what the PDF draws for a document that never sets
        // `.pc`. Centred is the same on both sides of a sheet, so this stays the plain
        // `\footer` group even under `\facingp`.
        footGroup = #"{\footer \pard\plain \qc\f0\fs22 {\chpgn }\par}"#
        footFacing = false
    }
    var out = headGroup + footGroup
    if let anchor = firstAnchor, anchor > 0 {
        out = #"\titlepg{\headerf \pard\plain\par}"# + out
    }
    return (out, headFacing || footFacing, headery, footery)
}

/// A fixed symmetric inset (0.5in each side) MODERN mode gives a quote-classified style,
/// replacing whatever margin — however large or lopsided — the source's own style record
/// carries. Port of `_RTF_MODERN_QUOTE_INSET`.
private let rtfModernQuoteInset = 720

/// (li, ri) twips for ONE style-table entry — the single source of truth both
/// `rtfStylesheet`'s own definition AND every body paragraph's DIRECT formatting read.
/// PRINTED keeps the WS4-absolute geometry verbatim; MODERN drops it for ordinary body
/// styles (full measure) and replaces a quote-classified style's own with the small fixed
/// symmetric inset. Port of `_rtf_style_margins`.
func rtfStyleMargins(_ entry: StyleEntry, printed: Bool) -> (li: Int, ri: Int) {
    guard let record = entry.record else { return (0, 0) }
    if printed {
        let li = (record.leftMarginHMI ?? 0) != 0
            ? roundHalfToEven(Double(record.leftMarginHMI!) / 1800.0 * 1440.0) : 0
        var ri = 0
        if let rm = record.rightMarginHMI, rm != 0 {
            // b32: same fix as `styleCSS`'s HTML twin -- the hmi is a column
            // POSITION (`.rm`'s own frame), not a width -- convert to columns,
            // then to the real indent, before scaling to twips.
            let rmCols = Double(roundHalfToEven(Double(rm) / 180.0))
            ri = Int(rmIndentCols(rmCols) * rtfTwipsPerCol)
        }
        return (li, ri)
    }
    if isQuoteName(entry.name) {
        return (rtfModernQuoteInset, rtfModernQuoteInset)
    }
    return (0, 0)
}

/// {slot: (li, ri)} for every real style-table entry — computed once per `emitRTF` call so
/// every paragraph referencing a style can carry its li/ri as DIRECT formatting, not only
/// via the `\sN` stylesheet reference. Port of `_rtf_direct_margins`.
func rtfDirectMargins(_ doc: Document, printed: Bool) -> [Int: (li: Int, ri: Int)] {
    var out: [Int: (li: Int, ri: Int)] = [:]
    for entry in doc.styles where entry.record != nil {
        out[entry.slot] = rtfStyleMargins(entry, printed: printed)
    }
    return out
}

// ------------------------------------------------------- printed vertical space
//
// Jon's ruling (round 6): line spacing/leading, `.pm` (paragraph margin), and
// `.psa`/`.psb` (WordTsar's paragraph spacing before/after) "need to be handled on
// Printed and Native RTF. The other formats TXT, MD, and HTML probably shouldn't deal
// with line spacing." Modern RTF stays out too — the reader owns presentation there,
// same doctrine as the no-page-width ruling (round 3). Scoped entirely to `emitRTF`'s
// PRINTED branch, which serves both the app's Printed and Native styles through one
// code path.

/// 1/48in -> twips: 1 inch is 1440 twips, so 1/48in is 1440/48 = 30 twips. PDF's own
/// `leadPt` (the reference behavior this ports) computes the SAME unit as points
/// (lead48 * 1.5, since 1/48in = 1.5pt); 1.5pt * 20 twips/pt is the identical 30 — both
/// routes agree.
private let rtfLeadTwipsPer48 = 30.0

/// Print columns (10 CPI) -> twips: 1440 twips/in / 10 cols/in = 144/col. The same
/// constant `rtfEmitPara`'s own `\fi` (from Modern's indentCols) already uses inline;
/// named here too since `.pm` shares the unit.
private let rtfTwipsPerCol = 144.0

/// The 1/48in leading in force for block `b`'s own printed lines.
///
/// UPDATED (ruling 2026-08-26, mirrored from ctrl-kd ebc2939, register row, b33 field
/// notes N2): this used to read ONLY `.lh` dot-state (`Line.lead48`), which never
/// consulted a WS7 paragraph STYLE's own `lineHeightVMI` — a 16pt Title/Author style
/// (vmi -2/auto, real leading 1.2x16=19.2pt) got the document's flat 12pt body default
/// instead, clipping in Word/TextEdit. Now backed by `resolvedPrintedLeads48`, which
/// recomputes the SAME per-line precedence `docToPagelines`'s printed branch already
/// uses for the PDF page (`.lh` override, else a paragraph style's own vmi-derived
/// leading via `styleLeadPt`/`enteringLeadPt`, else a WS5+ font-block's own proportional
/// size via `fontLeadPt`, else the document default) — collapsed to each block's own
/// FIRST REAL line, the ceiling of what RTF's paragraph-only `\sl` can express (a `.lh`
/// change strictly mid-paragraph was already out of scope before this fix, and stays
/// so). `bi` is the block's own index into `doc.blocks` (a struct has no identity of its
/// own the way ctrl-kd's Python object does, so the resolved map is keyed by index
/// instead). `resolved`, when given, is that whole-document map computed ONCE by the
/// caller (`emitRTF`'s own printed branch) — avoids recomputing it per block; omitted
/// (the lint gate's own direct call, and any other caller), it is computed fresh here
/// instead, at the cost of doing the whole-document walk again for one block. Port of
/// `_rtf_block_lead_48`.
func rtfBlockLead48(_ doc: Document, _ block: Block, bi: Int,
                    resolved: [Int: Double]? = nil) -> Double {
    let map = resolved ?? resolvedPrintedLeads48(doc)
    if let v = map[bi] { return v }
    return doc.page?.lh48 ?? defaultLh48
}

/// `\sl` value (signed twips) for one `.lh`-derived leading. NEGATIVE, per the RTF
/// spec's own distinction: a positive `\sl` is a MINIMUM (the reader may expand it for a
/// taller font); negative is EXACT, unconditionally. WordStar's own printed page is the
/// latter — the physical Y advance per line is the `.lh` VMI, full stop, regardless of
/// what font is set — so `\slmult0` (a literal twip count, not a multiple of single-
/// spacing) with a negative value is the faithful translation. Port of `_rtf_sl_twips`.
func rtfSlTwips(_ lead48: Double) -> Int {
    -roundHalfToEven(lead48 * rtfLeadTwipsPer48)
}

/// `\sl` for a Modern verse/centered unit — NEGATIVE, so EXACT, and carrying this
/// block's OWN tightened leading (planning #264 R3, Jon's ruling 2026-09-14; Athena's
/// call on the form, taken under it).
///
/// WHAT IT USED TO BE and why that was wrong. Round 20 emitted one fixed POSITIVE
/// `\sl322` for every tightened unit in every document: 1.15 (HTML's own verse
/// line-height) times Modern's 14pt body. Two faults, one measured and one arithmetic.
///
///   A positive `\sl` is a MINIMUM, and 16.10pt is what LibreOffice already gives a
///   14pt Times line by itself, so the control asked for nothing it was not already
///   going to get. Measured 2026-09-14 (research/2026-09-14_rtf-html-libreoffice-
///   check.md section 2): `\sl280` and no `\sl` at all both lay 16.10pt; only
///   `\sl-280` laid 14.00pt. The same probe settles the caveat that made round 20
///   choose the minimum form — an exact height at the face's own size loses no ink in
///   LibreOffice (14118 ink pixels either way, every accent and ascender drawn; the
///   lines merely overlap). Pages and Word are still unmeasured.
///
///   And 1.15 × body was never the number Modern uses. Modern's tightening is
///   `modernVerseTight` (0.71875) against the FACE's own natural line height, plus job
///   434's leading spacer — see `modernTightLineAdvancePt`, which is the one place that
///   arithmetic lives now, so RTF cannot drift from the page it describes. A document
///   whose title block is set at 72pt (LJ6DTP.WS) got the same 322 twips as one set at
///   14pt.
///
/// So: per block, exact, and the same figure the Modern PDF advances by — 15.1pt on
/// STRENGTH.WS's title block, which is `\sl-302\slmult0`.
///
/// THE C2 BOUNDARY is not in this number. The author's blank line after a tightened
/// block is a paragraph break and belongs to the body's ordinary leading, exactly as
/// `modernStreams` spends its untightened `lastH` there — so Modern RTF resets `\sl` to
/// 0 before a run of blank `\par`s rather than letting the compression leak past the
/// block that earned it. With the old positive form that reset was invisible (the reader
/// ignored the control either way); with an exact one it is the difference between a
/// title block closing at the body's 16.80pt and closing at 15.10pt.
/// Port of `_rtf_verse_tight_sl_twips`.
func rtfVerseTightSlTwips(_ spans: [Span], _ doc: Document,
                          nonpropFallback: Bool = false) -> Int {
    -roundHalfToEven(modernTightLineAdvancePt(spans, fonts: doc.fonts,
                                              nonpropFallback: nonpropFallback) * 20.0)
}

/// `\fi` (RTF's first-line indent, relative to `\li`) from `.pm` — `block.paraMargin`.
/// WSFORMAT semantics: ".pm is the PARAGRAPH margin — the first line's own indent," a
/// column position in the SAME absolute frame `.lm`/`.po` use, not a delta against
/// `.lm`. RTF reads `\fi` as relative to `\li`, so the direct token is the DIFFERENCE
/// between the indent's own absolute column (in twips) and wherever `\li` (the block's
/// own style margin, round 4) already places the body — `\li + \fi` then lands exactly
/// on it, whether that's deeper (an ordinary indent) or shallower (a hanging indent)
/// than the body. `nil` (the block never set `.pm`) leaves `\fi` untouched — no override
/// where there is no evidence. Port of `_rtf_pm_fi_twips`.
///
/// WHICH COLUMN (planning #264 item 2, packet row B6): `pmFirstLineIndentCols`
/// (EmitterRules.swift), the same function the Printed PDF calls, not `.pm`'s raw value.
/// Printed RTF renders PHYSICAL lines, so a first line that already types its own
/// leading spaces carries them into the output as real characters; adding `.pm`'s full
/// column on top of that is the same double-count the PDF stopped making in planning
/// #202, and it is why such a paragraph indented too far here. The resolved column is
/// `max(0, .pm - already typed)`, so `\li + \fi + the typed spaces` now lands where the
/// PDF puts the same line — and the clamp at zero is planning #257's half of it, which
/// keeps a `.pm 0"` block from pulling its first line LEFT of the column its author
/// typed.
func rtfPMFiTwips(_ block: Block, liTwips: Int) -> Int? {
    guard let cols = pmFirstLineIndentCols(block) else { return nil }
    return roundHalfToEven(cols * rtfTwipsPerCol) - liTwips
}

/// `(sb, sa)` in twips from WordTsar's own `.psa`/`.psb` extensions
/// (`doc.spaceBeforeLines`/`spaceAfterLines` — "not a WordStar command" per WordTsar's
/// own source, so their presence is a producer signal; a real WordStar 4/5/7 file never
/// carries them). MINIMAL MODEL: both are ONE document-wide value each (first
/// occurrence wins), applied uniformly to every printed paragraph rather than inventing
/// per-block granularity no evidence supports. Lines convert to twips via the
/// document's own DEFAULT leading — the same unit `\sl` itself uses — consistent with
/// "N lines of space" meaning N times this document's own line advance. `(nil, nil)`
/// when neither command was ever seen. Port of `_rtf_doc_spacing_twips`.
func rtfDocSpacingTwips(_ doc: Document) -> (sb: Int?, sa: Int?) {
    guard doc.spaceBeforeLines != nil || doc.spaceAfterLines != nil else { return (nil, nil) }
    let defaultLead48 = doc.page?.lh48 ?? defaultLh48
    let leadTwips = roundHalfToEven(defaultLead48 * rtfLeadTwipsPer48)
    let sb = doc.spaceBeforeLines.map { roundHalfToEven($0 * Double(leadTwips)) }
    let sa = doc.spaceAfterLines.map { roundHalfToEven($0 * Double(leadTwips)) }
    return (sb, sa)
}

/// RTF paragraph properties that PERSIST across `\par` — alignment, first-line indent,
/// left/right inset, line spacing, and paragraph spacing before/after alike — so all
/// seven (plus which style slots exist to tag) thread through a single `emitRTF` call.
/// `sb`/`sa` (round 6) stay Printed-only: only Printed/Native paragraphs ever pass a
/// nonzero value for either ("the other formats probably shouldn't deal with line
/// spacing", Modern RTF included). `sl` gained ONE scoped Modern exception (round 20,
/// slate item 4): a verse-classified or centered Modern unit passes a nonzero, POSITIVE
/// `sl` (`rtfVerseTightSlTwips`) for its own tighter internal spacing — every OTHER
/// Modern paragraph still passes 0, and every paragraph (Printed or Modern) still needs
/// the chance to reset any of these back to 0 when it doesn't apply. Port of
/// `rtf_state`.
struct RTFParaState {
    var align: Alignment = .left
    /// planning #264 R2 (packet row A8): the two keep properties, tracked like the six
    /// below because they PERSIST across `\par` exactly as those do.
    var keep: Bool = false
    var keepn: Bool = false
    var fi: Int = 0
    var li: Int = 0
    var ri: Int = 0
    var sl: Int = 0
    var sb: Int = 0
    var sa: Int = 0
    var styledSlots: Set<Int> = []
}

/// Appends one `\par`-terminated paragraph to `parts`. Alignment, `\fi`, `\li`/`\ri`, and
/// (round 6) `\sl`/`\sb`/`\sa` are each re-emitted only when they differ from what `state`
/// says is still in force — which is also what keeps a run of consecutive quote
/// paragraphs reading as one continuous inset block with no reset in between.
///
/// `fiTwips`, when given, OVERRIDES `fiCols` with an exact twip value computed elsewhere
/// (`.pm`'s own `rtfPMFiTwips`, round 6) — `fiCols * 144` would round-trip a twip value
/// that was never actually columns through a lossy columns-shaped parameter twice.
/// Port of `_rtf_emit_para`.
func rtfEmitPara(_ parts: inout [String], _ state: inout RTFParaState, _ block: Block,
                 _ lines: [String], fiCols: Int = 0, force: Bool = false, li: Int = 0, ri: Int = 0,
                 sl: Int = 0, sb: Int = 0, sa: Int = 0, fiTwips: Int? = nil,
                 keep: Bool = false, keepn: Bool = false) {
    let para = lines.joined(separator: #"\line "#)
    guard !para.trimmed().isEmpty || force else { return }
    if block.align != state.align {
        parts.append(rtfAlignControl(block.align))
        state.align = block.align
    }
    let fi = fiTwips ?? fiCols * 144          // 10 CPI: 1440 twips/in / 10 = 144/col
    if fi != state.fi {
        parts.append(#"\fi\#(fi) "#)
        state.fi = fi
    }
    if li != state.li {
        parts.append(#"\li\#(li) "#)
        state.li = li
    }
    if ri != state.ri {
        parts.append(#"\ri\#(ri) "#)
        state.ri = ri
    }
    if sl != state.sl {
        // \slmult0: the value is a literal twip count, not a multiple of single-line
        // spacing — see `rtfSlTwips` for why it's signed.
        parts.append(#"\sl\#(sl)\slmult0 "#)
        state.sl = sl
    }
    if sb != state.sb {
        parts.append(#"\sb\#(sb) "#)
        state.sb = sb
    }
    if sa != state.sa {
        parts.append(#"\sa\#(sa) "#)
        state.sa = sa
    }
    // planning #264 R2 (packet row A8, ruled 2026-09-14 "Yes add it"): `.cp n`/`.cc n`'s
    // own request, in the only vocabulary a reflowing reader has for it. `\keep` = do not
    // split this paragraph across a page; `\keepn` = keep it with the one after. Both
    // PERSIST across `\par` exactly as the six above do, so both are tracked and reset.
    // And note WHY this row works where imposed page positions do not (the packet's own
    // remark on A8): it is a CONSTRAINT the reader honours while paginating, not a
    // position we impose on it.
    if keep != state.keep {
        parts.append(keep ? #"\keep "# : #"\keep0 "#)
        state.keep = keep
    }
    if keepn != state.keepn {
        parts.append(keepn ? #"\keepn "# : #"\keepn0 "#)
        state.keepn = keepn
    }
    if let slot = block.styleID, state.styledSlots.contains(slot) {
        // style pass-through: tag the paragraph with its \sN so a consumer can act on
        // the named style — the visible formatting above is now ALSO direct, so a reader
        // that ignores \sN entirely still renders correctly.
        parts.append(#"\s\#(slot + 1) "#)
    }
    parts.append(para + #"\par "#)
}

/// `(li, fi)` in twips for one structured def/bullet row — planning #264 item 5 (packet
/// row C3), the SAME ladder the Modern PDF already lays
/// (`modernStructureIndentHang`, backported from the app by Jon's ruling 2026-09-11:
/// "Definitely backport. We spent a long time getting that looking nice.").
///
/// THE LADDER: `max(level - 1, 0)` steps of `modernLevelStepCols` past the margin, level 1
/// sitting AT the margin. The row's own declared column is deliberately unused.
///
/// THE HANG, where a wrapped continuation lands:
///   - def: a fixed `modernDefHangPt` past the margin, shared by every row of the list.
///   - bullet: the marker's own advance. The PDF measures it in the face that draws it;
///     RTF cannot know the reader's face, so it measures the same two characters in the
///     same base-14 Times at the same Modern body size the PDF's own fontless Modern token
///     uses — one number both engines compute identically, and far closer than a whole-
///     column count (the PDF rejected a column-count hang precisely because a marker and
///     its gap never land on a whole monospace cell in a proportional face).
///
/// RTF expresses a hanging indent as `\li` (where the wrapped lines sit) with a NEGATIVE
/// `\fi` of the same size (pulling the first line, which carries the label or marker, back
/// out to the ladder position). Port of `_rtf_structure_indent_hang`.
func rtfStructureIndentHang(_ structure: RowStructure, _ doc: Document,
                            markerText: String) -> (li: Int, fi: Int) {
    // `cw120` is 1/120in units; 0.6pt each (the PDF's own `colPt`), and 20 twips to the
    // point — 12 twips per unit, 144 for the default 12.
    let colTwips = (doc.page?.cw120 ?? 12.0) * 12.0
    let indent = Double(max(structure.level - 1, 0) * modernLevelStepCols) * colTwips
    let hang: Double = structure.kind == .def
        ? modernDefHangPt * 20.0
        : stringWidthPt(markerText, "Times-Roman", modernBodyPt) * 20.0
    return (roundHalfToEven(indent + hang), -roundHalfToEven(hang))
}

/// One definition or bullet row as a hanging paragraph (planning #264 item 5, packet row
/// C3). Modern RTF used to render both as plain paragraphs, so a wrapped definition
/// returned to the left margin instead of hanging under its own text.
///
/// A def row is rewritten LABEL + a two-space gap + body rather than the author's own raw
/// column padding — `modernDefRuns`' rule, and the same thing HTML's `<dt>`/`<dd>` pair
/// already does. The slice offsets are character counts the classifier took from this
/// row's own text, so the spans are sliced (never re-joined from strings) and every style
/// crossing the boundary survives. A bullet row keeps its marker: the marker IS what
/// hangs. Port of `_rtf_structure_row`.
func rtfStructureRow(_ parts: inout [String], _ state: inout RTFParaState, _ block: Block,
                     _ structure: RowStructure, _ line: Line, doc: Document,
                     li: Int, ri: Int, keep: Bool = false, keepn: Bool = false,
                     render: ([Span]) -> String) {
    let raw = Array(line.spans.map(\.text).joined())
    var lead = 0
    while lead < raw.count, raw[lead] == " " { lead += 1 }
    let labelLen = (structure.label ?? "").count
    let bodyLen = (structure.body ?? "").count
    var seg: String
    var marker = ""
    if structure.kind == .def, labelLen > 0, bodyLen > 0,
       lead + labelLen <= raw.count - bodyLen {
        seg = render(sliceSpans(line.spans, start: lead, end: lead + labelLen))
        seg += "  "
        seg += render(sliceSpans(line.spans, start: raw.count - bodyLen))
    } else {
        // a bullet row, or a def row whose own label/body offsets do not line up (the PDF
        // declines the rewrite in exactly that case too)
        seg = render(sliceSpans(line.spans, start: lead))
        marker = String(raw[lead..<min(lead + 2, raw.count)])
    }
    guard !seg.trimmed().isEmpty else { return }
    let (liTwips, fiTwips) = rtfStructureIndentHang(structure, doc, markerText: marker)
    rtfEmitPara(&parts, &state, block, [seg], li: li + liTwips, ri: ri, fiTwips: fiTwips,
                keep: keep, keepn: keepn)
}

public func emitRTF(_ doc: Document, mode: EmitMode = .modern,
                    options: EmitOptions = EmitOptions()) -> String {
    // planning #264 item 1: see emitText's identical call.
    // planning #270 item 42 (ruled 2026-09-14): both RTF modes are PAGED surfaces, so
    // WordStar's MailMerge page-number variable is substituted rather than shown as
    // typed — with `{\chpgn }`, the reader's own current-page field, because an RTF's
    // pages are the reader's (see `mergePagenoMarked`). `--page-numbers off` removes it
    // instead, the same flag governing it that governs the automatic number.
    let doc = options.pageNumbers == .off
        ? mergePagenoDropped(driverSubstituted(doc))
        : mergePagenoMarked(driverSubstituted(doc))
    let printed = mode == .printed || isPrinted(doc)
    var options = options
    if printed {
        // printed is always silent about comments (ruling 2026-08-06 M9)
        options.notes.remove(.comment)
    }
    // N9 (b33 field notes): mode-aware default, flag overrides either way.
    let ssOn = resolveSentenceSpacing(options.sentenceSpacing, printed: printed)
    // \f0 Times, \f1 Courier — a printed document's alignment only survives in a
    // fixed-width font (emit.py:210).
    let font = printed ? #"\f1"# : #"\f0"#
    let refNotes = inlineReferenceNotes(doc)
    // RTF must NEVER renumber (ruling 2026-08-24 item 1) -- it already sidesteps the
    // page-less-collision problem entirely by emitting `\chftn` auto-numbers with
    // `\ftnalt`, letting Word number them; a tagged note's own mark is what shows
    // instead (item 4, `rtfReferenceMarker`/`rtfDestination` below).
    let labels = annotatedNoteLabels(doc)
    // `prefixed` note references (ruling 2026-08-06 M8) — never printed: the facsimile
    // shows what WordStar printed.
    let shownMap: [Int: String]? = (options.noteRefs == .prefixed && !printed)
        ? noteRefLabels(refNotes, labels: labels, scheme: .prefixed) : nil
    // b24 round 20b (slate item 13): see emitText's identical comment for the doctrine.
    let screenplayBlocks = printed ? [] : detectScreenplayBlocks(doc)
    var parts: [String] = []
    let stylesheet = options.styles ? rtfStylesheet(doc, printed: printed) : ""
    let fontTable = options.styles
        ? fontControlRTF(doc, target: options.fontsTarget, inlineStyling: options.inlineStyling)
        : (fontTable: "", control: [:])
    let styledSlots: Set<Int> = options.styles
        ? Set(doc.styles.filter { $0.record != nil }.map(\.slot))
        : []
    var rtfState = RTFParaState(styledSlots: styledSlots)
    let margin = docMargin(doc)
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    // round 4: li/ri per style, looked up per paragraph so they can ride along as DIRECT
    // formatting — see `rtfDirectMargins`.
    let directMargins = options.styles ? rtfDirectMargins(doc, printed: printed) : [:]
    // round 6: .psa/.psb are ONE document-wide value each (see `rtfDocSpacingTwips`) --
    // resolved once, not per block. Only ever non-(nil,nil) for a WordTsar-produced file
    // (a real WordStar 4/5/7 document never carries these). Applied in PRINTED mode
    // only (below); Modern never reads docSb/docSa at all.
    let (docSb, docSa): (Int?, Int?) = printed ? rtfDocSpacingTwips(doc) : (nil, nil)
    // ruling 2026-08-26 (mirrored from ctrl-kd ebc2939): per-block `\sl` now needs a
    // whole-document pass (`resolvedPrintedLeads48` — see `rtfBlockLead48`) — computed
    // ONCE here, same "resolved once, not per block" doctrine as docSb/docSa just above,
    // rather than re-walking every block's own leading precedence again for every OTHER
    // block in the document.
    let resolvedLeads48: [Int: Double]? = printed ? resolvedPrintedLeads48(doc) : nil
    // Quote-group first-line indent (mirrors emitHTML): computed once from the group's own
    // first paragraph, reused for every paragraph in a run of CONSECUTIVE quote-classified
    // blocks — the source's own typed indent is NOT reliable per paragraph. Grouped by
    // "quote-classified at all", not the exact style name.
    var quoteOpen = false
    var quoteFiCols: Int? = nil

    // b24 round 17 (RULINGS-LEDGER row 3, register C22): `.sr`'s roll, in half-points —
    // Printed only (`\super`/`\sub` alone, unchanged, still carry Modern's sup/sub
    // semantics; a reader's own default rise is exactly the "reader owns presentation"
    // doctrine every other Printed-only vertical-space item already follows). 1/48in ->
    // half-points: 1/48in is 1.5pt (round 6's own conversion), half-points are 2x points,
    // so 1/48in-units * 3 = half-points. WSFORMAT's own default (3, absent `.sr`) applies
    // exactly like every other page-dot default.
    let rollHalfPt: Int? = printed
        ? roundHalfToEven((doc.formatting.subSuperRoll48 ?? 3.0) * 3.0) : nil
    // Jon's ruling 2026-08-20 (reverses b24 round 17b; RULINGS-LEDGER row 5/6, register
    // C21): default CONTINUOUS, matching measured WS7 LaserJet output — see
    // `rules`'s docstring (PDFWriter.swift) for the evidence. Explicit `.ul off` (key
    // present and `false`) still breaks at spaces. Printed only, same doctrine as `.sr`.
    let ulContinuous = printed ? (doc.formatting.underlineBlanks ?? true) : true
    // planning #252 (Jon's ruling 2026-09-09): resolved ONCE per document, same rule
    // and reasoning as `modernFlow`'s own `nonpropFallback` (`PDFModernLayout.swift`)
    // -- Printed keeps its own Courier-body doctrine untouched (`.ps` never governed
    // it and still doesn't), so this is Modern-only. Ported from ctrl-kd emit.py.
    let nonpropFallback = !printed && !doc.fonts.isEmpty && doc.formatting.proportional == false

    // round 5: DIRECT FORMATTING IS THE ONLY RENDERING MECHANISM IN RTF. Every run's
    // effective attributes — its own toggles merged with whatever the containing Block's
    // paragraph STYLE declares — are merged in BEFORE rendering, here, so every call site
    // gets it free. `coalesceSpans` runs again after the merge, which also correctly
    // re-joins runs that only differed because one carried a redundant inline toggle the
    // style already covered. Port of `rtf_seg`.
    func rtfSeg(_ spans: [Span], _ block: Block) -> String {
        // N9 (b33 field notes): applied to the RAW incoming spans, before the
        // effective-style merge -- `rtfSeg` is the single choke point every RTF render
        // path (printed physical lines, headings, Modern paragraphs alike) funnels
        // through, so one application here covers all of them.
        let spans = ssOn ? sentenceSpacingSpans(spans) : spans
        let merged = spans.map { sp in
            Span(text: sp.text, styles: effectiveSpanStyles(sp, block: block),
                 font: sp.font, colour: effectiveSpanColour(sp, block: block),
                 pctlHMI: sp.pctlHMI, pix: sp.pix, pcl: sp.pcl,
                 tabHMI: sp.tabHMI, tabLeader: sp.tabLeader)
        }
        // Graphic runs split out AFTER coalescing, same ordering reason as HTML's
        // identical step: splitting first would just get re-glued back onto the prose
        // beside it the moment both share a style.
        return splitGraphicSpans(coalesceSpans(merged))
            .map { rtfBodySpan($0, refNotes: refNotes, labels: labels, options: options,
                               fontControl: fontTable.control, printed: printed,
                               shownMap: shownMap, rollHalfPt: rollHalfPt,
                               ulContinuous: ulContinuous, inlineStyling: options.inlineStyling,
                               sentenceSpacing: ssOn, nonpropFallback: nonpropFallback) }
            .joined()
    }

    // b24 round 17b (RULINGS-LEDGER row 5/6, register C11), corrected by planning #247:
    // `.l#`'s own gutter for Printed RTF — flag-gated (default ON, same shape as
    // `headers`; fires only when the document itself declared `.l#`). RTF has no page
    // object of its own to reset a per-page count against (unlike PDF's separate Page
    // streams), so numbering runs from the DOCUMENT'S start, a deliberate, simpler
    // choice for this continuous-text format — a true per-page reset would need RTF's
    // own pagination model, which this format doesn't have and isn't being built here.
    //
    // `lineNoCheckpoints` (`lineNumberingCheckpoints`) replaces a single flat
    // `doc.lineNumbering` read, which is the LAST `.l#` in the whole document -- both
    // real oracles (sawyer/PRINT.TST, sawyer/DEFAULT/PRINT.TST) turn numbering back OFF
    // right after their demonstration section, so the flat reading was always off,
    // everywhere, planning #247. `numbered()` now resolves the interval IN FORCE at each
    // line's own block (`bi`), same mechanism PDF's per-page checkpoint uses, just
    // walked per-block instead of per-page.
    //
    // `lineNoState` (mirrors `PDFWriter.swift`'s `pageStream`'s own `lineNoState`
    // exactly): `.interval` is the interval most recently resolved, `.k` is a 0-based
    // count of physical lines since it last changed value. Labels are a SEQUENTIAL
    // COUNT of numbered lines (1, 2, 3, ...), counted from whenever `.l#` last turned on
    // (or changed interval), NOT from the document's own start -- see
    // `PDFMetrics.lineNoRightPt`'s own doc comment for the real-capture evidence (labels
    // run 1, 2, 3... starting the instant `.l#2` activates, never continuing some large
    // running total). Blank physical lines are numbered exactly like text-bearing ones
    // (measured; the previous `hasText` guard here was unverified).
    // planning #264 item 5 (packet rows C3+C4): ONE document-wide structure
    // classification, the same call (and therefore the same verdicts) emitHTML makes --
    // bullet-marker discovery and nesting both need the whole row order, not one block in
    // isolation.
    let blockRows = printed ? [:] : classifyModernBlocks(doc)
    let lineNoCheckpoints: [(blockIndex: Int, interval: Int?)]? =
        printed ? lineNumberingCheckpoints(doc) : nil
    let lineNumbersEnabled = printed && options.lineNumbers
    var lineNoState: (interval: Int?, k: Int) = (nil, 0)
    func numbered(_ renderedLine: String, bi: Int) -> String {
        let interval: Int? = (lineNumbersEnabled ? lineNoCheckpoints.flatMap {
            lineNumberingAt($0, bi)
        } : nil)
        if interval != lineNoState.interval {
            lineNoState = (interval, 0)
        }
        let k = lineNoState.k
        lineNoState.k += 1
        if let interval, interval > 0, k % interval == 0 {
            let label = String(k / interval + 1)
            let padded = String(repeating: " ", count: max(0, 4 - label.count)) + label
            return "{" + rtfEscape(padded) + #"\tab }"# + renderedLine
        }
        return renderedLine
    }

    // planning #264 item 2 (packet row A10): a trailing `.pa` opens no page unless the
    // document earned one. The reading moved to `trailingPASkipIndex`
    // (EmitterRules.swift) when item 4 gave the other emitters the same rule -- same
    // fact, same answer, one place.
    let skipPA = trailingPASkipIndex(doc)
    // planning #264 R1 (ruled 2026-09-14): THE SECTION SPINE. See `rtfSectionBreaks` for
    // what opens a section and what deliberately does not. A document whose geometry
    // never changes gets an empty dictionary here and emits exactly the bytes it always
    // did.
    let sectionBreaks = rtfSectionBreaks(doc)
    let columnsState: [(cols: Int, gutter: Double?)]? = rtfColumnsState(doc)
    // planning #264 R2 (packet row A8): `.cp n`/`.cc n` -> `\keep`/`\keepn` on the
    // paragraphs they asked to hold together. See `rtfKeepPlan`.
    let keepPlan = rtfKeepPlan(doc)
    for (bi, block) in doc.blocks.enumerated() {
        if let section = sectionBreaks[bi] {
            let sectionHeads = rtfRunningHeads(
                doc, headers: options.headers,
                autoPageNumber: rtfAutoPageNumber(doc, options.pageNumbers),
                printed: printed,
                slots: (header: section.headerSlots, footer: section.footerSlots))
            // `\sectd` resets EVERY section property to the document's own defaults, so
            // this section restates the ones it needs: `\headery`/`\footery` (section
            // properties in the RTF spec, written into the page setup for section 1) and
            // its own column regime. `\facingp`, `\margmirror` and the paper size are
            // DOCUMENT properties and survive untouched.
            var opener = #"\sect\sectd"#
            if let headery = sectionHeads.headery, let footery = sectionHeads.footery {
                opener += #"\headery\#(headery)\footery\#(footery)"#
            }
            opener += rtfColsControl(section.cols, section.gutter)
            parts.append(opener + " " + sectionHeads.groups + "\n")
            // Section properties reset the paragraph state the running text was
            // carrying, so the next paragraph restates its own.
            rtfState.align = .left
            rtfState.fi = 0
            rtfState.li = 0
            rtfState.ri = 0
            rtfState.sl = 0
            rtfState.sb = 0
            rtfState.sa = 0
            rtfState.keep = false
            rtfState.keepn = false
            quoteOpen = false
            quoteFiCols = nil
        }
        if block.kind == .colbreak {
            // planning #264 R1 (packet row A9): `.cb` breaks to the next column — the
            // reader's own `\column`. Inside a columnar region only; outside one the
            // control would mean a break a reader could still take, which is not what
            // WordStar did with it either, so nothing is written. BOTH MODES since
            // M17b: Modern PDF's own column cursor takes `.cb` to the next column
            // (`modernStreams`), so its RTF says the same.
            quoteOpen = false
            quoteFiCols = nil
            if let state = columnsState, state[bi].cols > 1 {
                parts.append(#"\column "#)
            }
            continue
        }
        if block.kind == .pagebreak {
            quoteOpen = false
            quoteFiCols = nil
            if bi == skipPA { continue }
            // planning #264 R1: a bare `.pa` INSIDE an active `.co n>1` region is
            // absorbed, not honoured — the identical reading the Printed PDF has carried
            // since planning #227, measured against WINGDING.CHT's own WS7 capture.
            // Modern PDF absorbs it on the same evidence since M17, so Modern RTF does
            // too.
            if let state = columnsState, state[bi].cols > 1 { continue }
            parts.append(pageControl)
            continue
        }
        let keepFlags = keepPlan[bi] ?? (keep: false, keepn: false)
        var (li, ri) = block.styleID.flatMap { directMargins[$0] } ?? (0, 0)
        if printed {
            // PRINTED CARRIES ITS INDENT ONCE (planning #264, the LibreOffice check's
            // section 3, 2026-09-14). Printed RTF emits a block as ONE paragraph whose
            // stored lines are joined by `\line`. A `\line` does not start a new
            // paragraph, so `\li` lands on every line after the first — on top of the
            // leading spaces those physical lines already carry, because carrying them
            // is what Printed MEANS. WSFORMAT.WS asked for a 2.5in hanging indent AND
            // typed 28 leading spaces on the same rows, and `\ri` took 4 more columns
            // off the measure on top of that: the file-format reference's own
            // line-for-line tables wrapped, and LibreOffice paginated 26 engine pages
            // into 50.
            //
            // THE PRINTED PDF SETTLES WHICH COPY IS THE REAL ONE. Its physical lines
            // start at `.po` plus the line's OWN typed columns and nothing else —
            // measured on WSFORMAT.WS: a row with 28 leading spaces under `.po 8` draws
            // at x = 259.2pt = (8 + 28) × 7.2, with no `.lm` added anywhere. So the
            // spaces are the geometry, and `\li`/`\ri` here are a second copy of a fact
            // already in the characters.
            //
            // Nothing replaces them. `directMargins` and round 17's own style/dot-state
            // resolution stay exactly as they are for Modern, which reflows and
            // therefore genuinely needs paragraph properties; round 17 was right about
            // WHAT the document says and wrong about Printed needing to say it twice.
            //
            // MEASURED AFTER (LibreOffice 24.2.7.2): WSFORMAT.WS reproduces all 1279 of
            // the engine's own printed lines exactly — zero wrapped lines, against 121
            // before — and 50 pages become 32. The remaining 6 against the engine's 26
            // are not wrapping: WordStar absorbs blank lines that fall at a page
            // boundary and no RTF reader does, the same ordinary repagination drift
            // LYING.WS shows (3 engine pages, 6 in LibreOffice) with no indents at all.
            li = 0
            ri = 0
            // physical lines: \line at every printed break, soft or hard.
            // planning #264 item 1 (packet row B3): a bare 0x09 expands to WordStar's
            // own modulus-8 stop first -- Printed RTF is Courier, so a column IS a
            // character and the expansion is exact. See
            // `expandBareTabsForPrintedLayout` (EmitterRules.swift); Modern (below)
            // never calls it.
            // planning #270 item 37: `.pf on`'s print-time re-wrap -- Printed RTF
            // renders the same physical lines the Printed PDF does.
            var lines = pfRewrappedLines(doc, block).map {
                numbered(rtfSeg(expandBareTabsForPrintedLayout($0.spans), block), bi: bi)
            }
            if block.heading != 0 {
                lines = lines.map { #"{\b\fs28 "# + $0 + "}" }
            }
            // round 6: line spacing/.pm/.psa+.psb -- Printed and Native RTF's own
            // domain (this IS that one shared code path -- see the module-level
            // ruling above `rtfBlockLead48`).
            let sl = rtfSlTwips(rtfBlockLead48(doc, block, bi: bi, resolved: resolvedLeads48))
            // `.pm`'s `\fi` STAYS, and the same measurement is why: the Printed PDF
            // DOES move a first line for `.pm`, so `\fi` is a fact the characters do
            // NOT carry — and being a FIRST-LINE property it is the one thing a `\line`
            // continuation never inherits. It was never part of this defect.
            //
            // It is asked through the PDF's OWN gate (`printedPMFiPt`) rather than
            // `rtfPMFiTwips` directly: WordStar auto-indents a first line when it
            // REFLOWS the paragraph at print time, so the PDF applies the indent only
            // under `.pf on` (measured on -HOLYMAC.WS against real WS7 — pages
            // 223/258/293 open at the plain left edge, `.pm4` and no `.pf` anywhere in
            // the file). Printed RTF asked unconditionally, so on a `.pf`-less document
            // it moved a first line the PDF leaves alone: WSFORMAT.WS's `0Bh ^K` row
            // draws at x 129.6pt in the engine PDF (`.po 8` + its own 10 typed columns)
            // and landed at 201.7pt through LibreOffice, ten columns further right.
            // One gate, both surfaces. `\li` is 0 now, so the `\fi` RTF reads RELATIVE
            // to it is simply its own resolved column.
            let pmFi = printedPMFiPt(block).map { roundHalfToEven($0 * 20.0) } ?? 0
            rtfEmitPara(&parts, &rtfState, block, lines, force: true, li: 0, ri: 0,
                        sl: sl, sb: docSb ?? 0, sa: docSa ?? 0, fiTwips: pmFi,
                        keep: keepFlags.keep, keepn: keepFlags.keepn)
            continue
        }
        if block.heading != 0 {
            quoteOpen = false
            quoteFiCols = nil
            // a heading is a logical unit, not reflowed prose — unaffected by paragraph
            // assembly, same as before. Alignment stripping goes through the shared
            // helper explicitly (it used to inherit the fix only by accident of loop
            // order).
            var lines = mergedLines(block).map { rtfSeg(maybeStripAlign(block, $0.spans), block) }
            lines = lines.map { #"{\b\fs28 "# + $0 + "}" }
            rtfEmitPara(&parts, &rtfState, block, lines, li: li, ri: ri,
                        keep: keepFlags.keep, keepn: keepFlags.keepn)
            parts.append(contentsOf: Array(repeating: #"\par "#,
                                           count: trailingBlankLines(block)))
            continue
        }
        let quote = isQuoteStyle(block)
        if quote {
            quoteOpen = true
        } else {
            quoteOpen = false
            quoteFiCols = nil
        }
        // Modern body: one \par per PARAGRAPH UNIT. A unit's own first line loses its
        // typed/machine indent to a real \fi; every other line in the unit keeps its
        // literal leading spaces UNLESS the unit never got verse-verified, in which case
        // it flows as one line instead (round 3b: \line is reserved for a REAL deliberate
        // break — a verified verse/stanza unit).
        let dominant = blockDominantStyles(mergedLines(block))
        // planning #264 item 5 (packet rows C3+C4): the structure rules pull definition,
        // bullet and spaces-centred rows out of the flow FIRST -- the identical verdicts
        // emitHTML has consumed since the modern-structure-rules round
        // (`classifyModernBlocks`, one document-wide classification) -- and everything
        // left over assembles into paragraph units exactly as it always did. Same shape
        // as emitHTML's own Modern branch, down to `plainRunIsBlockStart`.
        let rows: [(line: Line, structure: RowStructure?)] =
            blockRows[bi] ?? mergedLines(block).map { (line: $0, structure: nil) }
        var plainRunLines: [Line] = []
        var plainRunIsBlockStart = true

        func flushPlainRun() {
            guard !plainRunLines.isEmpty else { return }
            let units = assembleParagraphUnits(
                plainRunLines, margin: margin,
                headPosition: plainRunIsBlockStart ? (headPosition[bi] ?? false) : false,
                conventionIndent: plainRunIsBlockStart ? conventionIndent : nil,
                wrap: block.wrap)
            plainRunLines.removeAll()
            for unit in units {
                var (indentCols, first) = splitLeadingIndent(maybeStripAlign(block, unit[0].spans))
                if quote {
                    // the quote GROUP's own first paragraph sets \\fi for every paragraph
                    // in the group, not each one's own raw column count.
                    if quoteFiCols == nil { quoteFiCols = indentCols }
                    indentCols = quoteFiCols!
                }
                // round 7 (Register C23): a wrap=off block's unit is ALWAYS verse --
                // without this guard a non-verse multi-line unit still flows into one
                // run-on line.
                let isVerse = unit.count > 1 && (!block.wrap || looksLikeVerse(unit, dominantStyles: dominant)
                                                 || screenplayBlocks.contains(bi))
                var rendered = [rtfSeg(first, block)]
                for line in unit.dropFirst() {
                    var spans = maybeStripAlign(block, line.spans)
                    if !isVerse {
                        (_, spans) = splitLeadingIndent(spans)
                    }
                    rendered.append(rtfSeg(spans, block))
                }
                let lines: [String]
                if unit.count > 1 && !isVerse {
                    lines = [rendered.filter { !$0.trimmed().isEmpty }.joined(separator: " ")]
                } else {
                    lines = rendered
                }
                // b24 round 20 (slate item 4): verse-classified units and centered units
                // (which may themselves wrap in the reader, "wrapped centered units") get
                // tighter internal spacing -- a deliberate, scoped exception to round 6's
                // "Modern RTF doesn't do line spacing" rule, exactly as disclosed there.
                // R3 (2026-09-14): the figure is now this UNIT's own, off its first
                // line -- the same line the Modern PDF measures the block's first
                // advance from, and the same "collapsed to the block's own first real
                // line" ceiling `rtfBlockLead48` already accepts as what a
                // paragraph-only `\sl` can express.
                let tightSl = (isVerse || block.align == .center)
                    ? rtfVerseTightSlTwips(first, doc, nonpropFallback: nonpropFallback) : 0
                rtfEmitPara(&parts, &rtfState, block, lines, fiCols: indentCols, li: li, ri: ri,
                           sl: tightSl, keep: keepFlags.keep, keepn: keepFlags.keepn)
            }
        }

        for row in rows {
            if row.structure?.kind == nil {
                if let structure = row.structure, structure.centered,
                   structure.centerVia == .spaces {
                    // C4: the author centred this line by TYPING spaces. Modern RTF
                    // rendered the padding literally, so the row sat off centre AND
                    // wrapped early (the padding spends measure). Strip it and let
                    // `\\qc` do the work -- the same M3 rule a real `.oc` tag has always
                    // followed, on the classifier verdict HTML has used all along.
                    flushPlainRun()
                    plainRunIsBlockStart = false
                    let raw = Array(row.line.spans.map(\.text).joined())
                    var lead = 0
                    while lead < raw.count, raw[lead] == " " { lead += 1 }
                    var end = raw.count
                    while end > lead, raw[end - 1] == " " { end -= 1 }
                    let seg = rtfSeg(sliceSpans(row.line.spans, start: lead, end: end), block)
                    if !seg.trimmed().isEmpty {
                        var centred = block
                        centred.align = .center
                        rtfEmitPara(&parts, &rtfState, centred, [seg], li: li, ri: ri,
                                    sl: rtfVerseTightSlTwips(
                                        sliceSpans(row.line.spans, start: lead, end: end),
                                        doc, nonpropFallback: nonpropFallback),
                                    keep: keepFlags.keep, keepn: keepFlags.keepn)
                    }
                } else {
                    plainRunLines.append(row.line)
                }
                continue
            }
            // C3: a definition or bullet row is a HANGING paragraph.
            flushPlainRun()
            plainRunIsBlockStart = false
            rtfStructureRow(&parts, &rtfState, block, row.structure!, row.line,
                            doc: doc, li: li, ri: ri,
                            keep: keepFlags.keep, keepn: keepFlags.keepn,
                            render: { rtfSeg($0, block) })
        }
        flushPlainRun()
        // Only the author's own blank lines make space (ruling 2026-08-06): a block
        // boundary is often just a dot command, and command codes are invisible.
        //
        // C2 (R3, 2026-09-14): and they make the BODY's space. A tightened block's
        // compression is about how its own lines read against each other; the author's
        // blank line after it is the paragraph break, and that gap belongs to the
        // document's ordinary leading -- which is exactly what `modernStreams` does with
        // its untightened `lastH`. Left in force, an EXACT `\sl` would close a title
        // block tighter than the identical block closes with no tightening at all.
        let blanks = trailingBlankLines(block)
        if blanks > 0, rtfState.sl != 0 {
            parts.append(#"\sl0\slmult0 "#)
            rtfState.sl = 0
        }
        parts.append(contentsOf: Array(repeating: #"\par "#, count: blanks))
    }

    let body = parts.joined(separator: "\n")

    // The sophisticated body (ruling 2026-08-05): text with no font information reads in
    // Georgia 14 under Modern — "like reading a cozy book" — one font for every target,
    // the per-target variation riding in the falt (RTF's own no-Georgia safety net).
    // Printed keeps the historical Times New Roman f0 / Courier f1 / \fs24 UNTOUCHED: a
    // fontless document on the era's fixed grid IS a typescript, and Printed gap-fills
    // with 1990, never with today's conventions.
    let bodyFonts = modernBodyFonts[options.fontsTarget] ?? modernBodyFonts[.office]!
    var f0Entry = #"{\f0 \#(bodyFonts.primary){\*\falt \#(bodyFonts.falt)};}"#
    var bodyFontSize = #"\fs\#(modernBodySize * 2)"#
    if printed {
        f0Entry = #"{\f0 Times New Roman;}"#
        bodyFontSize = #"\fs24"#
    }

    // Page setup, emitted EXPLICITLY: without \paperw/\margl the opening app's locale
    // decides the paper (A4 in most of the world), and the "Modern page settings" ruling
    // would be fiction. Geometry follows the governing principle: the document's own
    // declared values win; silence is filled by the MODE's own page — Modern's is 1in
    // margins on Letter, Printed's is the era page already resolved onto `doc.page` (which
    // carries WordStar's own factory defaults when the file declared nothing).
    // b24 round 17 (RULINGS-LEDGER row 2, register C18, Paged-surface doctrine point 2):
    // `.pr or=l` swaps the PAPER dimensions only (heightIn/pwIn, which is all `paperh`/
    // `paperw` below read) — `.mt`/`.mb`/`.po`-derived margins are left exactly as
    // declared, only the CANVAS they sit against changes shape. BOTH MODES since M17b
    // (2026-09-15): this used to be Printed-only, on the reading that "Modern's page is
    // its own fixed Letter". M17 retired that reading for Modern PDF — a landscape
    // document's Modern MediaBox is 792x612 now — and Modern PDF is the printed form of
    // THIS file (ruled 2026-08-05), so a square 8.5x8.5 Modern RTF would be an RTF its
    // own PDF does not print. It is also the paged-surface doctrine's point 2 read
    // literally: "honor `.pr or=l` in ALL paged surfaces", and Modern RTF is one. A
    // local copy — no `doc` mutation needed, unlike Python's save/restore dance around
    // a shared dict.
    let landscape = doc.formatting.orientation == .landscape
    let page = (landscape ? doc.page.map(landscapePage) : doc.page)
    func twipsLines(_ value: Double?, default defaultLines: Double) -> Int {
        roundHalfToEven((value ?? defaultLines) * 240.0)     // 1 line at 6 LPI = 240 twips
    }
    /// A declared sheet height in inches -> `\paperh` twips, with `.pl 0` falling back
    /// to Letter.
    ///
    /// `.pl 0` IS NOT A SHEET. It is WordStar's "page breaks off" (bug 12284,
    /// `textLinesPerPage`), and this emitter's text model already never breaks, so the
    /// PAGE BOX falls back to Letter -- the rule Printed PDF has carried since
    /// `resolvedPageHeight` was written and Modern PDF adopted in M18
    /// (`modernSheetH`), quoted here rather than re-decided.
    ///
    /// RTF was the surface still writing the arithmetic straight through: `\paperh0`,
    /// which LibreOffice refuses to open at all. Five documents:
    /// `LSRBOX/LSRBOXES.MRG`, `LSRBOX/LSRLINES.MRG`, `RTF-RJS/1-5LINES.WS`,
    /// `RTF-RJS/1-SINGLE.WS`, `RTF-RJS/2-DOUBLE.WS`, plus `REF/-PATCHES.WS`. A document
    /// that declares any real height is untouched.
    func paperTwips(_ heightIn: Double?) -> Int {
        let twips = roundHalfToEven((heightIn ?? 11.0) * 1440.0)
        return twips > 0 ? twips : 15840
    }
    let margt: Int
    let margb: Int
    let margl: Int
    let paperh: Int
    if printed {
        margt = twipsLines(page?.mtLines, default: 3.0)
        margb = twipsLines(page?.mbLines, default: 8.0)
        margl = roundHalfToEven((page?.poCols ?? 8.0) * 144.0)
        paperh = paperTwips(page?.heightIn)
    } else {
        // Modern mode only trusts a field the document (or a --page-settings override,
        // which is applied as though it were the document's own — see `effectivePage`)
        // actually DECLARED; an undeclared field falls back to Modern's own fixed 1in
        // page rather than whatever WordStar factory number `doc.page` already carries.
        let mtDeclared = (page?.mtSource ?? .default) != .default
        let mbDeclared = (page?.mbSource ?? .default) != .default
        let poDeclared = (page?.poSource ?? .default) != .default
        margt = mtDeclared ? twipsLines(page?.mtLines, default: 6.0) : 1440
        margb = mbDeclared ? twipsLines(page?.mbLines, default: 6.0) : 1440
        margl = poDeclared ? roundHalfToEven((page?.poCols ?? 10.0) * 144.0) : 1440
        // A LANDSCAPE sheet is a declared sheet whatever `.pl` says, so it is never the
        // 11in default: `page` above is already the swapped, orientation-aware pair (a
        // `.pl 8.5"` resolves to 8.5 tall x 11 wide, not to the un-landscape-aware
        // 8.5x8.5 SQUARE the portrait resolution gives). Modern PDF composes on exactly
        // that height (`modernSheetHeight`), which is what makes the two agree.
        paperh = (landscape || (page?.sizeSource ?? .default) != .default)
            ? paperTwips(page?.heightIn) : 15840
    }
    // width joined the page model 2026-08-06: A4-tall documents get the 210mm sheet;
    // everything else (and every default) stays 12240 twips
    let paperw = roundHalfToEven((page?.pwIn ?? 8.5) * 1440.0)
    // planning #264 item 4 (packet row A6): `.poe`/`.poo` — a wider margin on the binding
    // side — become `\margmirror` under `\facingp`, which is RTF's own inside/outside
    // reading of `\margl`/`\margr`: on an odd (right-hand) page the left margin is
    // `\margl`, on an even one it is `\margr`. WordStar's `.poo` is the odd page's own
    // offset and `.poe` the even one's, so they land in that order. The pair is all the
    // geometry RTF has for this, which is why the right margin stops mirroring the left
    // here — a document that declares `.poe`/`.poo` is asking for exactly that
    // alternation. Printed only: Modern's page is its own fixed Letter (packet row D9).
    let (poeCols, pooCols) = printed ? rtfPoParity(doc) : (nil, nil)
    let mirrorMargins = poeCols != nil || pooCols != nil
    var leftMargin = margl
    var rightMargin = margl
    if mirrorMargins {
        let inside = pooCols ?? page?.poCols ?? 8.0
        let outside = poeCols ?? page?.poCols ?? 8.0
        leftMargin = roundHalfToEven(inside * 144.0)
        rightMargin = roundHalfToEven(outside * 144.0)
    }
    // planning #264 item 3/4: the running heads are resolved BEFORE the page setup —
    // `\facingp`, `\headery` and `\footery` are page properties the head/foot groups
    // themselves decide.
    let runningHeads = rtfRunningHeads(
        doc, headers: options.headers,
        autoPageNumber: rtfAutoPageNumber(doc, options.pageNumbers),
        printed: printed)
    var pageSetup = #"\paperw\#(paperw)\paperh\#(paperh)\margl\#(leftMargin)\margr\#(rightMargin)"#
        + #"\margt\#(margt)\margb\#(margb)"#
    if runningHeads.facingPages || mirrorMargins { pageSetup += #"\facingp"# }
    if mirrorMargins { pageSetup += #"\margmirror"# }
    if let headery = runningHeads.headery, let footery = runningHeads.footery {
        pageSetup += #"\headery\#(headery)\footery\#(footery)"#
    }
    // planning #264 item 3 (packet row A2): `.pn` sets the number of the page it appears
    // on, so a document that says "start numbering at 7" must not start at 1.
    // `\pgnstart` is the document-level beginning page number; only ever written when
    // the document actually asked for one (a mid-document `.pn` re-anchor needs the
    // section spine and is out of scope — see `rtfAutoPageNumber`).
    let pnStart = page?.pnStart ?? 1
    if pnStart != 1 { pageSetup += #"\pgnstart\#(pnStart)"# }
    if landscape { pageSetup += #"\landscape"# }
    // planning #264 R1 (packet row A7): the FIRST section's own column regime. `\cols`
    // is a section property and the page setup is section 1's; a document that opens
    // outside a columnar region (all but a handful) resolves to one column and writes
    // nothing, so its bytes do not move. BOTH MODES since M17b — see
    // `rtfSectionBreaks`.
    if let first = rtfColumnsState(doc).first {
        pageSetup += rtfColsControl(first.cols, first.gutter)
    }

    // b24 round 17 (RULINGS-LEDGER row 1): `rtfRunningHeads` has no printed-specific
    // behavior to add — it was simply never called for `printed` before this round.
    // `options.headers` (default true) now gates BOTH modes uniformly.
    // planning #264 item 3 (packet rows A1/A2): `--page-numbers` was accepted by the
    // command line and swallowed by this emitter, a flag that silently did nothing.
    let running = runningHeads.groups
    // b24 round 18 (RULINGS-LEDGER row 10): the colour table only needs to exist when a
    // span will actually reference it -- an unconditional \colortbl on every RTF this
    // project has ever produced would be a silent, permanent byte-shape change to files
    // with no inline colour at all. `--inline-styling off` also skips it (nothing will
    // emit \cfN either way).
    let colourtbl = (options.inlineStyling && !coloursUsed(doc).isEmpty) ? rtfColourTable : ""
    // b24 round 18 (RULINGS-LEDGER row 4): TOC/Index at the document's own end, gated by
    // `--toc` (default off, the ruled default).
    let tocIndex = options.toc ? rtfTOCIndex(doc, printed: printed) : ""
    var out = #"{\rtf1\ansi\deff0{\fonttbl"# + f0Entry + #"{\f1 Courier New;}"#
    out += fontTable.fontTable + "}"
    out += colourtbl
    out += stylesheet
    out += pageSetup
    out += running
    out += "\n" + font + bodyFontSize + " " + "\n"
    out += body
    out += tocIndex
    out += "\n}\n"
    return out
}

/// A `\page`-separated TOC/Index section at the document's own end (b24 round 18,
/// RULINGS-LEDGER row 4) — TOC before Index, each clearly headed, an entry indented
/// `\li` per `.tc` level. Printed RTF borrows PDF's own REAL paginator
/// (`tocPageNumbers`) for page numbers: RTF itself has no page-fitting model of its own
/// (a reader's own margins/fonts decide where pages actually fall), so this is a
/// borrowed APPROXIMATION, not a second independent paginator — the same page numbers
/// Printed PDF's own TOC would show for the identical document. Modern RTF gets entries
/// with no page reference at all (`pageNumbers: nil`), same as every other non-paged
/// format. Port of `_rtf_toc_index`.
private func rtfTOCIndex(_ doc: Document, printed: Bool) -> String {
    let pageNumbers: [Int: Int]? = printed ? tocPageNumbers(doc) : nil
    let toc = compileTOC(doc, pageNumbers: pageNumbers)
    let idx = compileIndex(doc, pageNumbers: pageNumbers)
    guard !toc.isEmpty || !idx.isEmpty else { return "" }
    var parts = [#"\page "#]
    if !toc.isEmpty {
        parts.append(#"{\pard\plain\qc\b\fs28 TABLE OF CONTENTS\par}"#)
        for entry in toc {
            let li = max(0, entry.level - 1) * 360
            parts.append("{\\pard\\li\(li) " + rtfEscape(entry.text) + #"\par}"#)
        }
    }
    if !idx.isEmpty {
        if !toc.isEmpty { parts.append(#"\page "#) }
        parts.append(#"{\pard\plain\qc\b\fs28 INDEX\par}"#)
        for text in idx {
            parts.append("{\\pard " + rtfEscape(text) + #"\par}"#)
        }
    }
    return parts.joined()
}

/// A hard page break, for the `pagebreak` branch (emit.py:218).
private let pageControl = #"\page "#

/// An RTF `\stylesheet` group derived from the style records — the same pass-through rule
/// as the HTML CSS: properties come from the file's own data, names are carried verbatim,
/// nothing is hardwired. `\sN` numbers are slot+1, since RTF style 0 is reserved for
/// Normal.
func rtfStylesheet(_ doc: Document, printed: Bool = true) -> String {
    var entries: [String] = []
    for entry in doc.styles {
        guard let record = entry.record else { continue }   // recordless base entry
        var props = ""
        switch record.justification {
        case .center: props += #"\qc"#
        case .right: props += #"\qr"#
        case .justify: props += #"\qj"#
        default: break                                       // `.left`/inherited: nothing
        }
        // Kept for WORD'S benefit: named, editable styles. Every property that must
        // actually RENDER is ALSO emitted as direct formatting on each referencing
        // paragraph (`rtfEmitPara`'s own li/ri, sourced from `rtfDirectMargins`) — this
        // definition is no longer the only place li/ri exists (round 4).
        let (li, ri) = rtfStyleMargins(entry, printed: printed)
        if li != 0 { props += #"\li"# + String(li) }
        if ri != 0 { props += #"\ri"# + String(ri) }
        let attrs = record.attrs
        if attrs.contains(.bold) { props += #"\b"# }
        if attrs.contains(.italic) { props += #"\i"# }
        if attrs.contains(.underline) { props += #"\ul"# }
        if attrs.contains(.strike) { props += #"\strike"# }
        if let font = record.font, font.height != 0 {
            props += #"\fs"# + String(roundHalfToEven(Double(font.height) / 20.0 * 2.0))
        }
        // The name is carried VERBATIM apart from the three characters that would break
        // out of the group. Not the usual `rtfEscape`: a style name is a name, and
        // hex-escaping it would change what a consumer reads back.
        var name = ""
        for character in entry.name where character != "\\" && character != "{" && character != "}" {
            name.append(character)
        }
        entries.append(#"{\s"# + String(entry.slot + 1) + props + " " + name + ";}")
    }
    guard !entries.isEmpty else { return "" }
    return #"{\stylesheet{\s0 Normal;}"# + entries.joined() + "}"
}
