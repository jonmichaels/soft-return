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

public func emitRTF(_ doc: Document, mode: EmitMode = .modern) -> String {
    let printed = mode == .printed || isPrinted(doc)
    // \f0 Times, \f1 Courier — a printed document's alignment only survives in a
    // fixed-width font (emit.py:210).
    let font = printed ? #"\f1"# : #"\f0"#
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
        var lines = block.lines.map { line in
            line.spans
                .map { span in "{" + rtfStyleControls(span.styles) + rtfEscape(span.text) + "}" }
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

    let body = parts.joined(separator: "\n")
    var out = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}{\f1 Courier New;}}"#
    out += "\n" + font + #"\fs24 "# + "\n"
    out += body
    out += "\n}\n"
    return out
}

/// A hard page break, shared by the `softpage` and `pagebreak` branches (emit.py:215, 218).
private let pageControl = #"\page "#
