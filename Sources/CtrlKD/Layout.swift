/// The Modern layout model — the semantic flow every Modern renderer shares. Port of
/// `layout.py` (task #15), whose module docstring is the CONTRACT and is carried here
/// verbatim:
///
/// This module is the PUBLIC face of the M-rules (the 2026-08-06 Modern review rulings):
/// alignment tags strip the spaces that implemented them, block `.lm`/`.rm` margins
/// indent and narrow the measure, only the author's blank lines make space, running
/// heads replay, footnotes ride their lines while endnotes/annotations/comments collect
/// at the end, print-control display strings are screen-only, and driver character
/// substitutions are content.
///
/// Three consumers, one model (ruled 2026-08-06, "the point is not to reimplement
/// everything"):
///   - `PDFModernLayout.swift` measures these items into points and paints them;
///   - Soft Return.app measures them through the native macOS text stack;
///   - the `layout` emitter (below) serializes them as JSON so a viewer in ANY language
///     can render a WordStar file without linking either engine — and so the two
///     engines' layout output is parity-testable as data.
///
/// The items are deliberately plain (dicts, lists, strings, numbers): no class
/// instances, nothing that doesn't survive json.dumps. Measurements are absent by
/// design — a paragraph's `indent_cols` is in WordStar print columns, and each consumer
/// converts with its own metrics.
///
/// ## The item contract (format 1)
///
/// modern_flow() returns {'items': [...], 'notes': [...]}.
///
/// Each item is a dict with a 'kind':
///   para            a logical line to wrap: 'align' ('left'|'center'|'right'|
///                   'justify'), 'indent_cols'/'cut_cols' (the block's .lm and
///                   its .rm shortfall from the 65-column line, in columns),
///                   'runs' (below), 'footnotes' (list of [note_index, label]
///                   whose text belongs at the bottom of whatever page this
///                   line lands on)
///   blank           one blank line (the author's own)
///   break           a forced page break (.pa)
///   cond            conditional break: 'lines' remaining or break (.cp n)
///   hf              running-head change: 'which' ('H'|'F'), 'line' (1-based
///                   slot), 'text' (raw — consumers pass it through hf_runs
///                   for toggle bytes, and replace '#' with the page number)
///   note-separator  the 20-dash rule opening the end-notes section
///   note            one end-matter note: 'index' (into notes), 'label',
///                   'text' — endnotes/annotations/comments, document order
///
/// A run is {'text': str, 'styles': [sorted tags]}, or a reference mark
/// {'text': shown_label, 'styles': [...], 'ref': note_index}. Runs preserve
/// span boundaries; they never merge.
///
/// notes is [{'kind', 'label', 'shown', 'text', 'origin'}] for every note the
/// call kept, in document order — 'label' is the kind's own display number
/// (what a page-bottom footnote shows), 'shown' the reference-mark text under
/// the requested `note_refs` scheme.
///
/// In Swift the items are typed (`SemanticItem` et al.) rather than dictionaries — the
/// JSON emitter converts them to exactly the shapes above, and the styles list is
/// derived from `Style`/`font`/`colour` at serialization time so the tags match
/// Python's (`b`, `i`, `u`, `sup`, `sub`, `strike`, `fnref`, `altfont`, `fontN`,
/// `colourN`, `pctlN`).

/// The era line: 65 columns at 10 CPI is the full measure every `.rm` is read against
/// (same constant printed layout wraps at). Python's `layout.FULL_COLS`.
let fullCols = 65

/// One text run in a semantic para item. `ref` non-nil marks a note REFERENCE (its text
/// is the shown label); `styles`/`font`/`colour` carry the span's own state, from which
/// the JSON tag list derives.
public struct SemanticRun: Hashable, Sendable {
    public var text: String
    public var styles: Style
    public var font: Int?
    public var colour: Int?
    /// Index into the flow's `notes` rows when this run IS a reference mark.
    public var ref: Int?

    public init(text: String, styles: Style = [], font: Int? = nil, colour: Int? = nil,
                ref: Int? = nil) {
        self.text = text
        self.styles = styles
        self.font = font
        self.colour = colour
        self.ref = ref
    }
}

/// One [note_index, label] footnote attachment on a para item.
public struct SemanticFootnote: Hashable, Sendable {
    public var index: Int
    public var label: String

    public init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

/// One item of the semantic Modern flow — see the module docstring for the contract.
public enum SemanticItem: Hashable, Sendable {
    case para(align: Alignment, indentCols: Double, cutCols: Double,
              runs: [SemanticRun], footnotes: [SemanticFootnote])
    case blank
    case pageBreak
    case cond(lines: Int)
    case hf(which: HFKind, line: Int, text: String)
    case noteSeparator
    case note(index: Int, label: String, text: String)
}

/// One row of the flow's kept-notes list.
public struct SemanticNoteRow: Hashable, Sendable {
    public var kind: NoteKind
    public var label: String
    public var shown: String
    public var text: String
    public var origin: NoteOrigin

    public init(kind: NoteKind, label: String, shown: String, text: String,
                origin: NoteOrigin) {
        self.kind = kind
        self.label = label
        self.shown = shown
        self.text = text
        self.origin = origin
    }
}

/// What `modernSemanticFlow` returns — Python's `{'items': [...], 'notes': [...]}`.
public struct SemanticFlow: Hashable, Sendable {
    public var items: [SemanticItem]
    public var notes: [SemanticNoteRow]

    public init(items: [SemanticItem], notes: [SemanticNoteRow]) {
        self.items = items
        self.notes = notes
    }
}

/// Endnote display label under the `word` scheme: lowercase roman, Word's own default
/// for `\ftnalt` endnotes (MS-OI29500 §17.11.17: "In Word, the default value for
/// endnote numbering format is lowerRoman") — a page can carry footnote [1] and endnote
/// [i] without collision. Port of `layout.endnote_label`.
public func endnoteRomanLabel(_ label: String) -> String {
    guard let n = Int(label), n > 0 else { return label }
    var remaining = n
    var out = ""
    for (v, s) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                   (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                   (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
        while remaining >= v {
            out += s
            remaining -= v
        }
    }
    return out
}

/// `[refNotes index: reference-mark text]` under the requested scheme (M8). Port of
/// `layout._shown_labels`.
func shownLabels(_ refNotes: [Note], doc: Document, noteRefs: NoteRefs) -> [Int: String] {
    if noteRefs == .prefixed {
        return noteRefLabels(refNotes, doc: doc, scheme: .prefixed)
    }
    var shown: [Int: String] = [:]
    var ords: [NoteKind: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        let k = (ords[note.kind] ?? 0) + 1
        ords[note.kind] = k
        let label = noteLabel(note, doc: doc)
        switch note.kind {
        case .endnote:
            shown[i] = endnoteRomanLabel(label)
        case .comment:
            // self-identifying in the end list either scheme; under `word` there is no
            // inline mark to match anyway
            shown[i] = "c" + String(k)
        default:
            shown[i] = label
        }
    }
    return shown
}

/// The document as the semantic Modern flow — see the module docstring for the item
/// contract. This is the single implementation of the M-rules; measuring consumers
/// (`PDFModernLayout.swift`, the app) convert columns to their own units and wrap at
/// their own measure. Port of `layout.modern_flow`.
public func modernSemanticFlow(_ doc: Document, notes keep: Set<NoteKind> = EmitOptions.defaultNotes,
                               noteRefs: NoteRefs = .word) -> SemanticFlow {
    let refNotes = inlineReferenceNotes(doc)
    let shownByIndex = shownLabels(refNotes, doc: doc, noteRefs: noteRefs)

    // every kept note, in document order, with its indices stable for the
    // 'ref'/'footnotes'/'index' fields below
    var noteRows: [SemanticNoteRow] = []
    var rowIndexByRef: [Int: Int] = [:]
    for (i, note) in refNotes.enumerated() {
        guard keep.contains(note.kind) else { continue }
        rowIndexByRef[i] = noteRows.count
        noteRows.append(SemanticNoteRow(kind: note.kind, label: noteLabel(note, doc: doc),
                                        shown: shownByIndex[i] ?? "", text: note.text,
                                        origin: note.origin))
    }

    let lj = doc.printerDriver == "LJ6DTP"
    var hfByBlock: [Int: [(kind: HFKind, line: Int, text: String)]] = [:]
    for event in doc.hfEvents {
        hfByBlock[event.blockAnchor, default: []].append((event.kind, event.line, event.text))
    }

    var items: [SemanticItem] = []
    var endRows: [Int] = []                 // end-matter note indices, doc order
    var endSeen: Set<Int> = []
    for (bi, block) in doc.blocks.enumerated() {
        for event in hfByBlock[bi] ?? [] {
            items.append(.hf(which: event.kind, line: event.line, text: event.text))
        }
        if block.kind == .pagebreak {
            items.append(.pageBreak)
            continue
        }
        if block.kind == .condpage {
            items.append(.cond(lines: max(1, block.heading)))
            continue
        }
        let lm = block.leftMargin ?? 0
        let rm = block.rightMargin ?? 0
        // `.rm` narrows the measure from the document's full line; a block at the
        // default 65 cuts nothing
        let cut = rm != 0 ? max(0.0, Double(fullCols) - rm) : 0.0
        for line in mergedLines(block) {
            if line.spans.isEmpty {
                items.append(.blank)
                continue
            }
            var spans = line.spans
            if lm != 0 {
                // WordStar stamps `.lm` onto every line it writes; the indent is
                // carried by the item now, so the stamped spaces come off the front
                // (whatever indent remains past `.lm` is the author's own tab and stays)
                var drop = lm
                while drop > 0, !spans.isEmpty {
                    let chars = Array(spans[0].text)
                    var take = 0
                    while take < chars.count, Double(take) < drop, chars[take] == " " {
                        take += 1
                    }
                    if take == 0 { break }
                    drop -= Double(take)
                    if take < chars.count {
                        spans[0].text = String(chars[take...])
                        break
                    }
                    spans.removeFirst()
                }
            }
            var runs: [SemanticRun] = []
            var footnotes: [SemanticFootnote] = []
            for span in spans {
                if span.pctlHMI != nil {
                    // a 0x0F print control's display string is SCREEN-ONLY; the paper
                    // got the raw payload. Modern shows nothing — command codes are
                    // invisible (M4, extended M10)
                    continue
                }
                var styles = span.styles
                if block.heading != 0 { styles.insert(.bold) }
                styles.formUnion(block.styleAttrs)
                if span.styles.contains(.fnref) {
                    guard let n = Int(span.text), n >= 1, n <= refNotes.count else { continue }
                    let note = refNotes[n - 1]
                    guard keep.contains(note.kind), let ni = rowIndexByRef[n - 1] else { continue }
                    let shown = shownByIndex[n - 1] ?? ""
                    if note.kind != .comment || noteRefs == .prefixed {
                        // `word` comments are markless (Word's bubble convention);
                        // `prefixed` shows the c-mark (M9)
                        runs.append(SemanticRun(text: shown, styles: styles, ref: ni))
                    }
                    if note.kind == .footnote {
                        footnotes.append(SemanticFootnote(index: ni,
                                                          label: noteLabel(note, doc: doc)))
                    } else if !endSeen.contains(ni) {
                        endSeen.insert(ni)
                        endRows.append(ni)
                    }
                    continue
                }
                var text = span.text
                if lj, let fontIndex = span.font, fontIndex < doc.fonts.count {
                    // LJ6DTP substitutions are CONTENT, not layout (M7): an em dash is
                    // an em dash in any century, whichever renderer consumes these items
                    let entry = doc.fonts[fontIndex]
                    if entry.proportional {
                        text = ljSubstituteText(text, entry: entry)
                    }
                }
                if !text.isEmpty {
                    runs.append(SemanticRun(text: text, styles: styles, font: span.font,
                                            colour: span.colour))
                }
            }
            if block.align == .center || block.align == .right {
                // WordStar 5+ aligned at EDITOR time — the centering is already in the
                // file as spaces (the WS4 `.oj` DOSBox probe proved the same for
                // justification). The spaces come off and the tag does the work (M3 —
                // no per-document exceptions). Character-level, so a run like
                // '   Title' sheds its leading spaces without losing the word.
                while let first = runs.first, first.ref == nil {
                    let t = String(first.text.drop(while: { $0 == " " }))
                    if !t.isEmpty {
                        if t != first.text { runs[0].text = t }
                        break
                    }
                    runs.removeFirst()
                }
                while let last = runs.last, last.ref == nil {
                    var t = last.text
                    while t.hasSuffix(" ") { t.removeLast() }
                    if !t.isEmpty {
                        if t != last.text { runs[runs.count - 1].text = t }
                        break
                    }
                    runs.removeLast()
                }
            }
            items.append(.para(align: block.align, indentCols: lm, cutCols: cut,
                               runs: runs, footnotes: footnotes))
        }
        // Only the author's own blank lines make space (M4): a block boundary is often
        // just a dot command, and command codes are invisible. `mergedLines` buffered
        // these away; count them back.
        for _ in 0..<trailingBlankLines(block) {
            items.append(.blank)
        }
    }
    if !endRows.isEmpty {
        // Endnotes/annotations/comments at the true end, after the last body line —
        // flowing, not bottom-anchored — behind the same 20-dash separator the
        // page-bottom notes use. No heading: WordStar never printed one.
        items.append(.blank)
        items.append(.noteSeparator)
        for ni in endRows {
            items.append(.note(index: ni, label: noteRows[ni].shown,
                               text: noteRows[ni].text))
        }
    }
    return SemanticFlow(items: items, notes: noteRows)
}

// ---------------------------------------------------------------- JSON

/// A minimal JSON value tree + writer, local to the layout emitter — Foundation stays
/// out of this library, and the `layout` format is compared as PARSED data (key order
/// and float spelling may differ between engines; the gauntlet compares structures).
/// `json.dumps(..., ensure_ascii=False, indent=1)`-shaped output.
indirect enum LayoutJSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LayoutJSONValue])
    /// Ordered key-value pairs — dictionaries would shuffle keys per run.
    case object([(String, LayoutJSONValue)])
}

func jsonEscape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)   // ensure_ascii=False
            }
        }
    }
    return out
}

func jsonSerialize(_ value: LayoutJSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent + 1)
    let closePad = String(repeating: " ", count: indent)
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d):
        // `Int64(d)` truncates without libm; equality means d is a whole number.
        if d.magnitude < 1e15, Double(Int64(d)) == d {
            return "\(Int64(d)).0"                  // Python json prints 7.0, not 7
        }
        return "\(d)"
    case .string(let s): return "\"" + jsonEscape(s) + "\""
    case .array(let items):
        if items.isEmpty { return "[]" }
        let body = items.map { pad + jsonSerialize($0, indent: indent + 1) }
            .joined(separator: ",\n")
        return "[\n" + body + "\n" + closePad + "]"
    case .object(let pairs):
        if pairs.isEmpty { return "{}" }
        let body = pairs.map { pad + "\"" + jsonEscape($0.0) + "\": "
            + jsonSerialize($0.1, indent: indent + 1) }
            .joined(separator: ",\n")
        return "{\n" + body + "\n" + closePad + "}"
    }
}

/// The Python style-tag list for one span's state — `b`, `i`, `u`, `sup`, `sub`,
/// `strike`, `fnref`, `altfont`, plus `fontN`/`colourN`/`pctlN` for the run fields the
/// Swift IR carries structurally. Sorted, matching Python's `sorted(styles)`.
func pythonStyleTags(_ styles: Style, font: Int? = nil, colour: Int? = nil,
                     pctlHMI: Int? = nil) -> [String] {
    var tags: [String] = []
    if styles.contains(.bold) { tags.append("b") }
    if styles.contains(.italic) { tags.append("i") }
    if styles.contains(.underline) { tags.append("u") }
    if styles.contains(.sup) { tags.append("sup") }
    if styles.contains(.sub) { tags.append("sub") }
    if styles.contains(.strike) { tags.append("strike") }
    if styles.contains(.fnref) { tags.append("fnref") }
    if styles.contains(.altFont) { tags.append("altfont") }
    if let font { tags.append("font\(font)") }
    if let colour { tags.append("colour\(colour)") }
    if let pctlHMI { tags.append("pctl\(pctlHMI)") }
    return tags.sorted()
}

private func jsonOptString(_ value: String?) -> LayoutJSONValue {
    value.map { .string($0) } ?? .null
}

/// The provenance block of the layout document. Port of `layout._json_meta`.
private func jsonMeta(_ doc: Document) -> LayoutJSONValue {
    .object([
        ("variant", jsonOptString(doc.detection?.variant.rawValue)),
        ("producer", jsonOptString(doc.producer)),
        ("printer_driver", jsonOptString(doc.printerDriver)),
        ("columnar", .bool(doc.columnar)),
        ("encoding", .string("cp437")),
    ])
}

/// `doc.page` as Python's `meta['page']` dict (same keys, same units).
private func jsonPage(_ page: PageGeometry?) -> LayoutJSONValue {
    guard let p = page else { return .null }
    return .object([
        ("pl_lines", .double(p.plLines)),
        ("height_in", .double(p.heightIn)),
        ("size_name", .string(p.sizeName)),
        ("size_source", .string(p.sizeSource.rawValue)),
        ("mt_lines", .double(p.mtLines)),
        ("mt_source", .string(p.mtSource.rawValue)),
        ("mb_lines", .double(p.mbLines)),
        ("mb_source", .string(p.mbSource.rawValue)),
        ("po_cols", .double(p.poCols)),
        ("po_source", .string(p.poSource.rawValue)),
        ("hm_lines", .double(p.hmLines)),
        ("hm_source", .string(p.hmSource.rawValue)),
        ("fm_lines", .double(p.fmLines)),
        ("fm_source", .string(p.fmSource.rawValue)),
        ("lh_48", .double(p.lh48)),
        ("lh_source", .string(p.lhSource.rawValue)),
        ("ls", .double(p.ls)),
        ("ls_source", .string(p.lsSource.rawValue)),
        ("cw_120", .double(p.cw120)),
        ("cw_source", .string(p.cwSource.rawValue)),
        ("text_lines", .int(p.textLines)),
        ("pn_start", .int(p.pnStart)),
        ("pn_source", .string(p.pnSource.rawValue)),
        ("pc_col", p.pcCol.map { LayoutJSONValue.int($0) } ?? .null),
        ("pc_source", .string(p.pcSource.rawValue)),
        ("lh_varies", .bool(p.lhVaries)),
    ])
}

/// One `Document.fonts` entry as Python's `_font_entry` dict.
private func jsonFont(_ f: FontChange) -> LayoutJSONValue {
    .object([
        ("offset", f.offset >= 0 ? .int(f.offset) : .null),
        ("width_1800", .int(f.width1800)),
        ("height_1440", .int(f.height1440)),
        ("points", .double(f.points)),
        ("cpi", f.cpi.map { LayoutJSONValue.double($0) } ?? .null),
        ("typestyle", .int(f.typestyle)),
        ("proportional", .bool(f.proportional)),
        ("letter_quality", .bool(f.letterQuality)),
        ("symbol_map", .string(f.symbolMap.rawValue)),
        ("generic_style", .string(f.genericStyle.rawValue)),
        ("typestyle_number", .int(f.typestyleNumber)),
        ("typestyle_name", jsonOptString(f.typestyleName)),
    ])
}

private func jsonRun(_ run: SemanticRun) -> LayoutJSONValue {
    var pairs: [(String, LayoutJSONValue)] = [
        ("text", .string(run.text)),
        ("styles", .array(pythonStyleTags(run.styles, font: run.font, colour: run.colour)
            .map { .string($0) })),
    ]
    if let ref = run.ref {
        pairs.append(("ref", .int(ref)))
    }
    return .object(pairs)
}

private func jsonItem(_ item: SemanticItem) -> LayoutJSONValue {
    switch item {
    case .para(let align, let indentCols, let cutCols, let runs, let footnotes):
        return .object([
            ("kind", .string("para")),
            ("align", .string(align.rawValue)),
            ("indent_cols", .double(indentCols)),
            ("cut_cols", .double(cutCols)),
            ("runs", .array(runs.map(jsonRun))),
            ("footnotes", .array(footnotes.map {
                .array([.int($0.index), .string($0.label)])
            })),
        ])
    case .blank:
        return .object([("kind", .string("blank"))])
    case .pageBreak:
        return .object([("kind", .string("break"))])
    case .cond(let lines):
        return .object([("kind", .string("cond")), ("lines", .int(lines))])
    case .hf(let which, let line, let text):
        return .object([
            ("kind", .string("hf")),
            ("which", .string(which == .header ? "H" : "F")),
            ("line", .int(line)),
            ("text", .string(text)),
        ])
    case .noteSeparator:
        return .object([("kind", .string("note-separator"))])
    case .note(let index, let label, let text):
        return .object([
            ("kind", .string("note")),
            ("index", .int(index)),
            ("label", .string(label)),
            ("text", .string(text)),
        ])
    }
}

private func jsonNoteRow(_ row: SemanticNoteRow) -> LayoutJSONValue {
    .object([
        ("kind", .string(row.kind.rawValue)),
        ("label", .string(row.label)),
        ("shown", .string(row.shown)),
        ("text", .string(row.text)),
        ("origin", .string(row.origin.rawValue)),
    ])
}

private func jsonHFDict(_ dict: [Int: String]) -> LayoutJSONValue {
    .object(dict.keys.sorted().map { (String($0), .string(dict[$0]!)) })
}

/// The `layout` format: the full viewer contract as JSON — semantic Modern flow, printed
/// page-lines, page geometry with provenance, notes, and the invisible layer (dot
/// commands with anchors, running-head events) — so a renderer in any language can draw
/// a WordStar file without linking an engine, and both engines' layout is comparable as
/// data. Format version bumps only on breaking shape changes. Port of
/// `layout.emit_layout`.
@Sendable
public func emitLayout(_ doc: Document, mode: EmitMode = .modern,
                       options: EmitOptions = EmitOptions()) -> String {
    var printedPages: [LayoutJSONValue] = []
    for page in docToPagelines(doc, printed: true) {
        var lines: [LayoutJSONValue] = []
        for pl in page {
            lines.append(.object([
                ("segments", .array(pl.spans.map { span in
                    .object([
                        ("text", .string(span.text)),
                        ("styles", .array(pythonStyleTags(span.styles, font: span.font,
                                                          colour: span.colour,
                                                          pctlHMI: span.pctlHMI)
                            .map { .string($0) })),
                    ])
                })),
                ("soft", .bool(pl.soft)),
                ("overprint", .bool(pl.overprint)),
                ("lead", pl.lead.map { LayoutJSONValue.double($0) } ?? .null),
            ]))
        }
        printedPages.append(.object([
            ("lines", .array(lines)),
            ("headers", jsonHFDict(page.headers)),
            ("footers", jsonHFDict(page.footers)),
        ]))
    }

    let flow = modernSemanticFlow(doc, notes: options.notes, noteRefs: options.noteRefs)
    let out = LayoutJSONValue.object([
        ("format", .string("ctrl-kd-layout")),
        ("version", .int(1)),
        ("meta", jsonMeta(doc)),
        ("page", jsonPage(doc.page)),
        ("fonts", .array(doc.fonts.map(jsonFont))),
        ("modern", .object([
            ("items", .array(flow.items.map(jsonItem))),
            ("notes", .array(flow.notes.map(jsonNoteRow))),
        ])),
        ("printed", .object([("pages", .array(printedPages))])),
        ("invisibles", .object([
            ("dot_commands", .array(doc.dotCommands.map { .string($0) })),
            ("dot_positions", .array(doc.dotPositions.map {
                .array([.int($0.blockIndex), .int($0.lineIndex), .string($0.text)])
            })),
            ("hf_events", .array(doc.hfEvents.map {
                .array([.string($0.kind == .header ? "H" : "F"), .int($0.line),
                        .string($0.text), .int($0.blockAnchor)])
            })),
            ("notes", .array(doc.notes.map {
                .object([
                    ("kind", .string($0.kind.rawValue)),
                    ("text", .string($0.text)),
                    ("origin", .string($0.origin.rawValue)),
                    ("offset", .int($0.offset)),
                ])
            })),
        ])),
    ])
    return jsonSerialize(out) + "\n"
}
