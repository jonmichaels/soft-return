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
private func rtfReferenceMarker(_ note: Note, label: String) -> String {
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
private func rtfDestination(_ note: Note, label: String) -> String {
    let text = rtfEscape(note.text)
    switch note.kind {
    case .footnote:
        return #"{\*\footnote \pard\plain\fs24 {\super\chftn }"# + text + "}"
    case .endnote:
        return #"{\*\footnote\ftnalt \pard\plain\fs24 {\super\chftn }"# + text + "}"
    case .annotation:
        return #"{\*\footnote\ftnalt \pard\plain\fs24 {\super "# + rtfEscape(label) + #" }"# + text + "}"
    case .comment:
        return ""   // comments render as their own trailing block — see emitRTF below
    }
}

/// One span, RTF: an ordinary span keeps today's plain `{styles}{text}` group; a valid,
/// included `fnref` becomes its marker immediately followed by its destination group; an
/// excluded kind's reference vanishes (no group at all — not even an empty one, matching
/// the `no_notes` vectors); an invalid one (task item 3) falls back to the ordinary group,
/// which already renders a stray sentinel as `{\super 1}` (fnref contributes no control
/// word of its own, only whatever `sup` it also carries).
private func rtfBodySpan(_ span: Span, refNotes: [Note], doc: Document, options: EmitOptions,
                         fontControl: [Int: String] = [:]) -> String {
    // The font control follows the style control words: Python joins `_RTF_ON` over the
    // sorted style codes (a `fontN` contributes nothing there) and only then appends the
    // font's own `\fK\fsN`.
    let controls = rtfStyleControls(span.styles) + (span.font.flatMap { fontControl[$0] } ?? "")
    guard span.styles.contains(.fnref) else {
        return "{" + controls + rtfEscape(span.text) + "}"
    }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label):
        return rtfReferenceMarker(note, label: label) + rtfDestination(note, label: label)
    case .excluded:
        return ""
    case .invalid:
        return "{" + controls + rtfEscape(span.text) + "}"
    }
}

/// The `\fonttbl` entries and the per-run control words for a document's font runs:
/// one `\fK` per DISTINCT named family (numbering starts at 2, after the emitter's own
/// `\f0` Times and `\f1` Courier), plus `\fsN` from the block's own height word. A run
/// whose typestyle number the spec's table doesn't name still carries its size.
/// Python's `_font_ctl_rtf` (emit.py).
func fontControlRTF(_ doc: Document) -> (fontTable: String, control: [Int: String]) {
    var extra = ""
    var control: [Int: String] = [:]
    var familyToK: [String: Int] = [:]
    var nextK = 2
    for (index, font) in doc.fonts.enumerated() {
        var parts = ""
        let family = font.family
        if !family.isEmpty {
            if familyToK[family] == nil {
                familyToK[family] = nextK
                // The three characters that would break out of the group, removed —
                // not `rtfEscape`, since a font name is a name (as in `rtfStylesheet`).
                var safe = ""
                for character in family where character != "\\" && character != "{" && character != "}" {
                    safe.append(character)
                }
                extra += "{\\f\(nextK) \(safe);}"
                nextK += 1
            }
            parts += "\\f\(familyToK[family]!)"
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

public func emitRTF(_ doc: Document, mode: EmitMode = .modern,
                    options: EmitOptions = EmitOptions()) -> String {
    let printed = mode == .printed || isPrinted(doc)
    // \f0 Times, \f1 Courier — a printed document's alignment only survives in a
    // fixed-width font (emit.py:210).
    let font = printed ? #"\f1"# : #"\f0"#
    let refNotes = inlineReferenceNotes(doc)
    var rtfAlign: Alignment = .left      // RTF alignment persists across \par
    var parts: [String] = []
    let stylesheet = options.styles ? rtfStylesheet(doc) : ""
    let fontTable = options.styles ? fontControlRTF(doc) : (fontTable: "", control: [:])
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
            line.spans
                .map { rtfBodySpan($0, refNotes: refNotes, doc: doc, options: options,
                                   fontControl: fontTable.control) }
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
            // emit.py:231-232 — modern mode puts a blank paragraph between paragraphs, and
            // does so unconditionally: an empty block that contributed no `\par` above still
            // gets this one, and the last block still gets a trailing blank. Faithful to
            // Python, quirk included; the vectors pin both.
            parts.append(#"\par "#)
        }
    }

    // Comments (opt-in) trail the whole document as their own top-level groups, one per
    // comment, in document order — never inline, since they have no reference to attach to.
    if options.notes.contains(.comment) {
        parts.append(contentsOf: doc.notes.filter { $0.kind == .comment }.map(rtfComment))
    }

    let body = parts.joined(separator: "\n")
    var out = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}{\f1 Courier New;}"#
    out += fontTable.fontTable + "}"
    out += stylesheet
    out += "\n" + font + #"\fs24 "# + "\n"
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
