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
private func rtfReferenceMarker(_ note: Note, label: String, markOverride: String? = nil) -> String {
    if let markOverride {
        // the `prefixed` scheme's literal custom mark in place of \chftn (M8)
        return "{\\super " + rtfEscape(markOverride) + "}"
    }
    switch note.kind {
    case .footnote, .endnote: return #"{\chftn}"#
    case .annotation: return "{\\super " + rtfEscape(label) + "}"
    case .comment: return ""   // unreached: comments never get an inline sentinel
    }
}

/// A valid, included reference's DESTINATION: the `{\*\footnote …}` group `\chftn` (or the
/// tag) points at. Endnotes and annotations both use `\footnote\ftnalt` — RTF has no
/// separate endnote-destination construct — differing only in what appears inside the
/// leading `{\super …}` (the generic `\chftn` mark for an endnote, the literal tag for an
/// annotation).
/// `markOverride` is the `prefixed` scheme's label (e1/a1) standing in for `\chftn` on
/// any kind — the mechanism annotations already used (ruling 2026-08-06 M8). Port of
/// `_rtf_note_dest`'s `mark_override`.
private func rtfDestination(_ note: Note, label: String, markOverride: String? = nil) -> String {
    let text = rtfEscape(note.text)
    let flag = note.kind == .footnote ? "" : #"\ftnalt"#
    if note.kind == .annotation || markOverride != nil {
        let markText = rtfEscape(markOverride ?? label)
        return #"{\*\footnote"# + flag + #" \pard\plain\fs24 {\super "# + markText + #" }"#
            + text + "}"
    }
    switch note.kind {
    case .footnote:
        return #"{\*\footnote \pard\plain\fs24 {\super\chftn }"# + text + "}"
    case .endnote:
        return #"{\*\footnote\ftnalt \pard\plain\fs24 {\super\chftn }"# + text + "}"
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
private func rtfBodySpan(_ span: Span, refNotes: [Note], doc: Document, options: EmitOptions,
                         fontControl: [Int: String] = [:], printed: Bool = false,
                         shownMap: [Int: String]? = nil) -> String {
    // A 0x0F print control's display string is SCREEN-ONLY: on paper WordStar sent the
    // raw printer payload and advanced by the block's HMI word. The printed facsimile
    // does the same -- the declared width of blank space (0 for LJ6DTP's rule-drawing
    // controls), in the 10-CPI print columns the rest of printed layout uses.
    if printed, let hmi = span.pctlHMI {
        let pad = roundHalfToEven(Double(hmi) / 180.0)
        return pad > 0 ? "{" + String(repeating: " ", count: pad) + "}" : ""
    }
    // The font control follows the style control words: Python joins `_RTF_ON` over the
    // sorted style codes (a `fontN` contributes nothing there) and only then appends the
    // font's own `\fK\fsN`.
    let controls = rtfStyleControls(span.styles) + (span.font.flatMap { fontControl[$0] } ?? "")
    guard span.styles.contains(.fnref) else {
        return "{" + controls + rtfEscape(span.text) + "}"
    }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label, let index):
        if note.kind == .comment {
            // Printed is a facsimile: WordStar printed nothing for a comment, so
            // neither do we (the CLI explains on stderr). Modern anchors a real Word
            // margin comment at the TRUE position (the end-of-document dump this
            // replaces lost it); `prefixed` adds the visible c-mark, `word` stays
            // markless — Word's own convention is a bubble, not a superscript. (M9)
            if printed { return "" }
            let mark = shownMap.flatMap { $0[index] }.map { "{\\super " + rtfEscape($0) + "}" } ?? ""
            return mark + rtfComment(note)
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
            + rtfDestination(note, label: label, markOverride: override)
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
func fontControlRTF(_ doc: Document,
                    target: FontsTarget = .office) -> (fontTable: String, control: [Int: String]) {
    var extra = ""
    var control: [Int: String] = [:]
    var primaryToK: [String: Int] = [:]
    var nextK = 2
    for (index, font) in doc.fonts.enumerated() {
        var parts = ""
        let (primary, falt) = rtfFonts(font.family, generic: font.genericStyle, target: target)
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
        if font.points != 0 {
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
private func rtfComment(_ note: Note) -> String {
    #"{\chatn}{\*\atnid ctrl-kd}{\*\annotation \pard\plain\fs24 "# + rtfEscape(note.text) + "}"
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
        let body = lines.keys.sorted().map { n in
            rtfEscape(lines[n]!).replacingAll("#", with: #"{\chpgn }"#)
        }.joined(separator: #"\line "#)
        return #"{\\#(name) \pard\plain \f0\fs22 \#(body)\par}"#
    }

    var out = group("header", hdr) + group("footer", ftr)
    if let anchor = firstAnchor, anchor > 0 {
        out = #"\titlepg{\headerf \pard\plain\par}"# + out
    }
    return out
}

public func emitRTF(_ doc: Document, mode: EmitMode = .modern,
                    options: EmitOptions = EmitOptions()) -> String {
    let printed = mode == .printed || isPrinted(doc)
    var options = options
    if printed {
        // printed is always silent about comments (ruling 2026-08-06 M9)
        options.notes.remove(.comment)
    }
    // \f0 Times, \f1 Courier — a printed document's alignment only survives in a
    // fixed-width font (emit.py:210).
    let font = printed ? #"\f1"# : #"\f0"#
    let refNotes = inlineReferenceNotes(doc)
    // `prefixed` note references (ruling 2026-08-06 M8) — never printed: the facsimile
    // shows what WordStar printed.
    let shownMap: [Int: String]? = (options.noteRefs == .prefixed && !printed)
        ? noteRefLabels(refNotes, doc: doc, scheme: .prefixed) : nil
    var rtfAlign: Alignment = .left      // RTF alignment persists across \par
    var parts: [String] = []
    let stylesheet = options.styles ? rtfStylesheet(doc) : ""
    let fontTable = options.styles
        ? fontControlRTF(doc, target: options.fontsTarget)
        : (fontTable: "", control: [:])
    let styledSlots: Set<Int> = options.styles
        ? Set(doc.styles.filter { $0.record != nil }.map(\.slot))
        : []

    for block in doc.blocks {
        if block.kind == .pagebreak {
            parts.append(pageControl)
            continue
        }

        // Each span becomes its own group, so its control words expire at the closing brace
        // and no style leaks into the next span (emit.py:222-223).
        //
        // printed: physical lines (\line at every printed break, soft or hard); modern:
        // logical lines only (`mergedLines`, ctrl-kd 2.0.0).
        var lines = (printed ? block.lines : mergedLines(block)).map { line in
            var spans = line.spans
            if !printed, block.align == .center || block.align == .right, !spans.isEmpty {
                // editor-time alignment: the spaces implemented the tag; keeping both
                // aligns twice (ruling 2026-08-06)
                spans = stripAlignSpaces(spans)
            }
            return spans
                .map { rtfBodySpan($0, refNotes: refNotes, doc: doc, options: options,
                                   fontControl: fontTable.control, printed: printed,
                                   shownMap: shownMap) }
                .joined()
        }
        if block.heading != 0 {
            // emit.py:226 — bold at 14pt (\fs is half-points), wrapping the whole line group.
            lines = lines.map { #"{\b\fs28 "# + $0 + "}" }
        }
        // emit.py:227 computes this joiner from `printed` with both arms equal — there is one
        // line break control in RTF and both modes use it. Written as the constant it is.
        let para = lines.joined(separator: #"\line "#)

        if !para.trimmed().isEmpty || printed {
            // C16/C17. RTF alignment PERSISTS across \par, so a block emits its control
            // whenever the alignment differs from the one still in force — including
            // \ql to return to flush left, or the previous block's centring would leak
            // into this one. Tracking the running value keeps a document that never
            // aligns anything byte-identical to before.
            if block.align != rtfAlign {
                parts.append(rtfAlignControl(block.align))
                rtfAlign = block.align
            }
            if let slot = block.styleID, styledSlots.contains(slot) {
                // Style pass-through: tag the paragraph with its `\sN` so a consumer can
                // act on the named style. The visible formatting is still carried inline,
                // as RTF readers expect.
                parts.append(#"\s"# + String(slot + 1) + " ")
            }
            parts.append(para + #"\par "#)
        }
        if !printed {
            // Only the author's own blank lines make space (ruling 2026-08-06): a block
            // boundary is often just a dot command, and command codes are invisible.
            parts.append(contentsOf: Array(repeating: #"\par "#,
                                           count: trailingBlankLines(block)))
        }
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
    let page = doc.page
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
        paperh = 15840
    }
    let pageSetup = #"\paperw12240\paperh\#(paperh)\margl\#(margl)\margr\#(margl)"#
        + #"\margt\#(margt)\margb\#(margb)"#

    let running = printed ? "" : rtfRunningHeads(doc)
    var out = #"{\rtf1\ansi\deff0{\fonttbl"# + f0Entry + #"{\f1 Courier New;}"#
    out += fontTable.fontTable + "}"
    out += stylesheet
    out += pageSetup
    out += running
    out += "\n" + font + bodyFontSize + " " + "\n"
    out += body
    out += "\n}\n"
    return out
}

/// A hard page break, for the `pagebreak` branch (emit.py:218).
private let pageControl = #"\page "#

/// An RTF `\stylesheet` group derived from the style records — the same pass-through rule
/// as the HTML CSS: properties come from the file's own data, names are carried verbatim,
/// nothing is hardwired. `\sN` numbers are slot+1, since RTF style 0 is reserved for
/// Normal.
func rtfStylesheet(_ doc: Document) -> String {
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
        // Twips: HMI/1800 inches, 1440 twips to the inch.
        if let lm = record.leftMarginHMI, lm != 0 {
            props += #"\li"# + String(roundHalfToEven(Double(lm) / 1800.0 * 1440.0))
        }
        if let rm = record.rightMarginHMI, rm != 0 {
            props += #"\ri"# + String(roundHalfToEven(Double(rm) / 1800.0 * 1440.0))
        }
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
