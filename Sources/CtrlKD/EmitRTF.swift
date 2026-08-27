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
                         sentenceSpacing: Bool = false) -> String {
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

/// Modern RTF `\header`/`\footer` groups from the document's own running heads (ruling
/// 2026-08-06: Modern keeps headers).
///
/// RTF carries ONE header per section; a document that redefines its head mid-file keeps
/// the FIRST definition of each line slot (the common case — OLDTIMES — defines each
/// exactly once). WordStar's `#` token becomes `\chpgn`, Word's own page-number field. A
/// head first defined after the opening block gets `\titlepg` with an empty first-page
/// header: the manuscript convention (no running head on page 1), and exactly what
/// WordStar itself printed when `.h1` follows page 1's title. Port of
/// `_rtf_running_heads`.
private func rtfRunningHeads(_ doc: Document) -> String {
    var hdr: [Int: String] = [:]
    var ftr: [Int: String] = [:]
    var firstAnchor: Int? = nil
    for event in doc.hfEvents {
        let isHeader = event.kind == .header
        let present = isHeader ? hdr[event.line] != nil : ftr[event.line] != nil
        if !present, !event.text.isEmpty {
            if isHeader { hdr[event.line] = event.text } else { ftr[event.line] = event.text }
            if firstAnchor == nil || event.blockAnchor < firstAnchor! {
                firstAnchor = event.blockAnchor
            }
        }
    }
    if hdr.isEmpty, ftr.isEmpty { return "" }

    func group(_ name: String, _ lines: [Int: String]) -> String {
        if lines.isEmpty { return "" }
        var rendered: [String] = []
        for n in lines.keys.sorted() {
            let runs = hfRuns(lines[n]!)
            if runs.isEmpty { continue }                 // control-bytes-only head (M10)
            rendered.append(runs.map { run in
                "{" + rtfStyleControls(run.styles)
                    + rtfEscape(run.text).replacingAll("#", with: #"{\chpgn }"#) + "}"
            }.joined())
        }
        if rendered.isEmpty { return "" }
        let body = rendered.joined(separator: #"\line "#)
        return #"{\\#(name) \pard\plain \f0\fs22 \#(body)\par}"#
    }

    var out = group("header", hdr) + group("footer", ftr)
    if let anchor = firstAnchor, anchor > 0 {
        out = #"\titlepg{\headerf \pard\plain\par}"# + out
    }
    return out
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

/// `\sl` for a Modern verse/centered unit (b24 round 20, slate item 4) — POSITIVE (a
/// MINIMUM, not the negative/EXACT convention `rtfSlTwips` uses for Printed's own
/// physical `.lh`): Modern is reflowed prose, not a fixed print position, so a taller
/// inline font mid-stanza should still get room to breathe rather than clip. Derived
/// from the SAME `verseLineHeight` constant HTML's own line-height reads, against
/// Modern's own fixed body size (`modernBodySize`, FontMap.swift) — one named
/// multiplier, both formats. Port of `_rtf_verse_tight_sl_twips`.
func rtfVerseTightSlTwips() -> Int {
    roundHalfToEven(verseLineHeight * Double(modernBodySize) * 20.0)   // 20 twips/pt
}

/// `\fi` (RTF's first-line indent, relative to `\li`) from `.pm` — `block.paraMargin`,
/// previously read by no emitter. WSFORMAT semantics: ".pm is the PARAGRAPH margin —
/// the first line's own indent," a column position in the SAME absolute frame `.lm`/
/// `.po` use, not a delta against `.lm`. RTF's own model reads `\fi` as relative to
/// `\li`, so the direct token is the DIFFERENCE between .pm's absolute column (in
/// twips) and wherever `\li` (the block's own style margin, round 4) is already placing
/// the body of the paragraph — `\li + \fi` then lands exactly on .pm's column, whether
/// that's deeper (an ordinary indent) or shallower (a hanging indent) than the body.
/// `nil` (the block never set `.pm`) leaves `\fi` untouched — no override where there
/// is no evidence. Port of `_rtf_pm_fi_twips`.
func rtfPMFiTwips(_ block: Block, liTwips: Int) -> Int? {
    guard let paraMargin = block.paraMargin else { return nil }
    return roundHalfToEven(paraMargin * rtfTwipsPerCol) - liTwips
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
                 sl: Int = 0, sb: Int = 0, sa: Int = 0, fiTwips: Int? = nil) {
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
    if let slot = block.styleID, state.styledSlots.contains(slot) {
        // style pass-through: tag the paragraph with its \sN so a consumer can act on
        // the named style — the visible formatting above is now ALSO direct, so a reader
        // that ignores \sN entirely still renders correctly.
        parts.append(#"\s\#(slot + 1) "#)
    }
    parts.append(para + #"\par "#)
}

public func emitRTF(_ doc: Document, mode: EmitMode = .modern,
                    options: EmitOptions = EmitOptions()) -> String {
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
                               sentenceSpacing: ssOn) }
            .joined()
    }

    // b24 round 17b (RULINGS-LEDGER row 5/6, register C11): `.l#`'s own gutter for
    // Printed RTF — flag-gated (default ON, same shape as `headers`; fires only when
    // the document itself declared `.l#`). RTF has no page object of its own to reset a
    // per-page count against (unlike PDF's separate Page streams), so numbering runs
    // from the DOCUMENT'S start, a deliberate, simpler choice for this continuous-text
    // format — a true per-page reset would need RTF's own pagination model, which this
    // format doesn't have and isn't being built here.
    let lineNoInterval: Int? = (printed && options.lineNumbers) ? doc.lineNumbering : nil
    var lineNo = 0
    func numbered(_ renderedLine: String, hasText: Bool) -> String {
        lineNo += 1
        if let interval = lineNoInterval, interval > 0, hasText, lineNo % interval == 0 {
            let label = String(lineNo)
            let padded = String(repeating: " ", count: max(0, 4 - label.count)) + label
            return "{" + rtfEscape(padded) + #"\tab }"# + renderedLine
        }
        return renderedLine
    }

    for (bi, block) in doc.blocks.enumerated() {
        if block.kind == .pagebreak {
            quoteOpen = false
            quoteFiCols = nil
            parts.append(pageControl)
            continue
        }
        var (li, ri) = block.styleID.flatMap { directMargins[$0] } ?? (0, 0)
        if printed {
            // b24 round 17 (RULINGS-LEDGER row 8, register C9b, point 8): `directMargins`
            // is keyed by STYLE SLOT only — a WS4 document (no style table at all) or a
            // WS5+ document setting bare `.lm`/`.rm` with no style selected got li=ri=0
            // in Printed RTF regardless of the running dot-state. Fallback to the
            // block's own fully-RESOLVED column value (style already won over dot-state
            // when the block was built, matching the SAME precedence Modern already
            // honors) — fires only when there's nothing more specific to prefer; an
            // explicit-zero style margin correctly never triggers it (`block.leftMargin`
            // is ALSO 0 in that case, by the same resolution chain). Printed only:
            // Modern reads `block.leftMargin`/`rightMargin` through its OWN separate
            // mechanism already (register C9, DONE) and must stay untouched here.
            if li == 0, let lm = block.leftMargin { li = roundHalfToEven(lm * rtfTwipsPerCol) }
            if ri == 0, let rm = block.rightMargin {
                // b32: `.rm` is the column POSITION where the right margin falls,
                // not an indent width -- see `rmIndentCols` (same fix as
                // `rtfStyleMargins`/`styleCSS`'s HTML twin).
                ri = Int(rmIndentCols(rm) * rtfTwipsPerCol)
            }
            // physical lines: \line at every printed break, soft or hard
            var lines = block.lines.map {
                numbered(rtfSeg($0.spans, block),
                        hasText: $0.spans.contains { !$0.text.trimmed().isEmpty })
            }
            if block.heading != 0 {
                lines = lines.map { #"{\b\fs28 "# + $0 + "}" }
            }
            // round 6: line spacing/.pm/.psa+.psb -- Printed and Native RTF's own
            // domain (this IS that one shared code path -- see the module-level
            // ruling above `rtfBlockLead48`).
            let sl = rtfSlTwips(rtfBlockLead48(doc, block, bi: bi, resolved: resolvedLeads48))
            let pmFi = rtfPMFiTwips(block, liTwips: li)
            rtfEmitPara(&parts, &rtfState, block, lines, force: true, li: li, ri: ri,
                       sl: sl, sb: docSb ?? 0, sa: docSa ?? 0, fiTwips: pmFi)
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
            rtfEmitPara(&parts, &rtfState, block, lines, li: li, ri: ri)
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
        for unit in assembleParagraphs(block, margin: margin,
                                       headPosition: headPosition[bi] ?? false,
                                       conventionIndent: conventionIndent) {
            var (indentCols, first) = splitLeadingIndent(maybeStripAlign(block, unit[0].spans))
            if quote {
                // the quote GROUP's own first paragraph sets \fi for every paragraph in
                // the group, not each one's own raw column count.
                if quoteFiCols == nil { quoteFiCols = indentCols }
                indentCols = quoteFiCols!
            }
            // round 7 (Register C23): a wrap=off block's unit is ALWAYS verse -- without
            // this guard a non-verse multi-line unit still flows into one run-on line.
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
            let tightSl = (isVerse || block.align == .center) ? rtfVerseTightSlTwips() : 0
            rtfEmitPara(&parts, &rtfState, block, lines, fiCols: indentCols, li: li, ri: ri,
                       sl: tightSl)
        }
        // Only the author's own blank lines make space (ruling 2026-08-06): a block
        // boundary is often just a dot command, and command codes are invisible.
        parts.append(contentsOf: Array(repeating: #"\par "#,
                                       count: trailingBlankLines(block)))
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
    // declared, only the CANVAS they sit against changes shape. Printed only: Modern's
    // page is its own fixed Letter regardless of the document's declared orientation
    // (same doctrine as every other Printed-only geometry item). A local copy — no `doc`
    // mutation needed, unlike Python's save/restore dance around a shared dict.
    let landscape = printed && doc.formatting.orientation == .landscape
    let page = (landscape ? doc.page.map(landscapePage) : doc.page)
    func twipsLines(_ value: Double?, default defaultLines: Double) -> Int {
        roundHalfToEven((value ?? defaultLines) * 240.0)     // 1 line at 6 LPI = 240 twips
    }
    let margt: Int
    let margb: Int
    let margl: Int
    let paperh: Int
    if printed {
        margt = twipsLines(page?.mtLines, default: 3.0)
        margb = twipsLines(page?.mbLines, default: 8.0)
        margl = roundHalfToEven((page?.poCols ?? 8.0) * 144.0)
        paperh = roundHalfToEven((page?.heightIn ?? 11.0) * 1440.0)
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
        paperh = (page?.sizeSource ?? .default) != .default
            ? roundHalfToEven((page?.heightIn ?? 11.0) * 1440.0) : 15840
    }
    // width joined the page model 2026-08-06: A4-tall documents get the 210mm sheet;
    // everything else (and every default) stays 12240 twips
    let paperw = roundHalfToEven((page?.pwIn ?? 8.5) * 1440.0)
    var pageSetup = #"\paperw\#(paperw)\paperh\#(paperh)\margl\#(margl)\margr\#(margl)"#
        + #"\margt\#(margt)\margb\#(margb)"#
    if landscape { pageSetup += #"\landscape"# }

    // b24 round 17 (RULINGS-LEDGER row 1): `rtfRunningHeads` has no printed-specific
    // behavior to add — it was simply never called for `printed` before this round.
    // `options.headers` (default true) now gates BOTH modes uniformly.
    let running = options.headers ? rtfRunningHeads(doc) : ""
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
