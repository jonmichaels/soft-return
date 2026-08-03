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
private func rtfBodySpan(_ span: Span, refNotes: [Note], doc: Document, options: EmitOptions) -> String {
    guard span.styles.contains(.fnref) else {
        return "{" + rtfStyleControls(span.styles) + rtfEscape(span.text) + "}"
    }
    switch resolveReference(span, refNotes: refNotes, doc: doc, options: options) {
    case .note(let note, let label):
        return rtfReferenceMarker(note, label: label) + rtfDestination(note, label: label)
    case .excluded:
        return ""
    case .invalid:
        return "{" + rtfStyleControls(span.styles) + rtfEscape(span.text) + "}"
    }
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

    for block in doc.blocks {
        if block.kind == .softpage {
            if printed { parts.append(pageControl) }
            continue
        }
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
                .map { rtfBodySpan($0, refNotes: refNotes, doc: doc, options: options) }
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
    var out = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}{\f1 Courier New;}}"#
    out += "\n" + font + #"\fs24 "# + "\n"
    out += body
    out += "\n}\n"
    return out
}

/// A hard page break, shared by the `softpage` and `pagebreak` branches (emit.py:215, 218).
private let pageControl = #"\page "#
