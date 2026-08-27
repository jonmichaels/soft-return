/// Document inspection — the library home of `--diagnose` (task #17). Port of `info.py`.
///
/// Moved out of the CLI (ruled 2026-08-06) because the report is not a command-line
/// nicety: it feeds Soft Return.app's Document Info window (⌘I), the batch window's
/// Get-Info panel, and error alerts that point at the Inspector — none of which link the
/// CLI target. The CLI's `--diagnose` flag is now a thin wrapper that renders this value.
///
/// Everything here is derived from one parse; the value is JSON-safe by construction
/// (the same discipline as `Layout.swift`'s contract).

/// A JSON-safe value tree, public so the app can walk the report without a JSON round
/// trip — Python's `document_info` returns a plain dict for the same reason. The CLI
/// converts this to its own rendering type; the app reads it directly.
public indirect enum InfoValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([InfoValue])
    case object([String: InfoValue])
}

/// Two lowercase hex digits, Foundation-free.
private func infoHexByte(_ v: Int) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[(v >> 4) & 0xF], digits[v & 0xF]])
}

/// What IS this file — variant detection, page geometry with provenance, note counts by
/// kind, unknown blocks, producer signals, print-time damage. `path` is echoed back as
/// `"file"` when given (the CLI passes it; an app passing bytes may not have one). Port
/// of `info.document_info`.
///
/// The report has the same three shapes Python's dict has:
///
/// 1. **Empty, or `^Z` at byte 0** — `variant` and `reason` only (`detect()` returns
///    before it counts anything, so there is no evidence to report).
/// 2. **Detected, not WordStar** — plus the six evidence counts.
/// 3. **`ws4` / `ws5+`** — plus what `parseWS` learned: margin estimate, dot commands,
///    unknown codes, columnar, paragraph count, per-kind note counts (comments cover
///    BOTH origins since M9 — `^ON` blocks and `..`/`.ig` dot lines), unknown blocks,
///    resolved page geometry with provenance, and `producer` when WordTsar's own dot
///    commands were seen.
///
/// A fourth case rides alongside shape 2: a `printstream` file additionally gets
/// `comment_bug` when WordStar's own COMMENT.BUG print-time damage signature is present
/// — framed as period damage, not a parse failure.
/// Everything before the last `/`, or `""` for a bare filename with none — this
/// module's own tiny mirror of `SoftReturnCLI/Paths.swift`'s `dirname` (a different
/// target this Foundation-free engine module cannot import).
private func dirnameOf(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    let head = String(path[..<slash])
    return head.isEmpty ? "/" : head
}

/// POSIX-style relative path from `base` (a directory) to `target` (a file or
/// directory), both absolute — Python's `os.path.relpath`, string math only (no
/// filesystem access, matching this module's own Foundation-free discipline). Returns
/// `target` unchanged when either path is not absolute or the two share no common root
/// component (Python's own ValueError case on Windows' different-drive letters has no
/// POSIX equivalent, but an unrelated pair of absolute paths still degrades honestly to
/// the absolute target rather than a nonsensical relative string).
func relativePath(from base: String, to target: String) -> String {
    guard base.hasPrefix("/"), target.hasPrefix("/") else { return target }
    let baseParts = base.split(separator: "/").map(String.init)
    let targetParts = target.split(separator: "/").map(String.init)
    var common = 0
    while common < baseParts.count, common < targetParts.count,
          baseParts[common] == targetParts[common] {
        common += 1
    }
    let ups = Array(repeating: "..", count: baseParts.count - common)
    let downs = Array(targetParts[common...])
    let parts = ups + downs
    return parts.isEmpty ? "." : parts.joined(separator: "/")
}

/// - Parameter pixResults: pre-resolved `Document.graphics` entries (round 19,
///   RULINGS-LEDGER PIX row) — the caller's own `resolveDocumentPictures` output
///   (SoftReturnCLI, which has real filesystem access; this Foundation-free engine
///   target never resolves anything itself). `nil` (a bytes-only caller, or one that
///   never bothered) reports every tag as unresolved rather than omitting the `pix`
///   key entirely — "this file HAS pix tags" is itself useful information, matching
///   ctrl-kd's own documented behavior for a `doc_path` of `None`.
public func documentInfo(_ data: [UInt8], path: String? = nil,
                         pixResults: [PixResult]? = nil) -> InfoValue {
    let detection = detect(data)
    var info: [String: InfoValue] = [
        "variant": .string(detection.variant.rawValue),
    ]
    if let path {
        info["file"] = .string(path)
    }
    if let reason = detection.reason {
        info["reason"] = .string(reason)
    }
    // Shape 1 vs 2. `size` is the discriminator because it is the byte count on every
    // path that computes evidence — `size == 0` happens only on the early return, and
    // only there are the other counts meaningless rather than merely zero.
    if detection.size > 0 {
        info["soft_returns"] = .int(detection.softReturns)
        info["hard_returns"] = .int(detection.hardReturns)
        info["high_bit_bytes"] = .int(detection.highBitBytes)
        info["text_pct"] = .int(detection.textPct)
        info["symmetric_blocks_1d"] = .int(detection.symmetricBlocks1D)
        info["size"] = .int(detection.size)
    }

    if detection.variant == .ws4 || detection.variant == .ws5plus {
        let doc = parseWS(data)
        info["margin_estimate"] = doc.marginEstimate.map(InfoValue.int) ?? .null
        info["dot_commands"] = .array(doc.dotCommands.map(InfoValue.string))
        info["unknown_codes"] = .object(
            Dictionary(uniqueKeysWithValues: doc.unknownCodes.map {
                ("0x" + infoHexByte(Int($0.key)), InfoValue.int($0.value))
            }))
        info["columnar"] = .bool(doc.columnar)
        info["paragraphs"] = .int(doc.blocks.filter { $0.kind == .para }.count)
        // Note kinds, counted separately (footnote/endnote/annotation/comment) rather
        // than flattened, so a rescue tool can tell a file has hidden comments even
        // when this run is only converting to plain text — and since M9 the comment
        // count covers BOTH origins ('block' ^ON notes and '..'/'.ig' dot lines).
        info["notes"] = .object([
            "footnote": .int(doc.notes.filter { $0.kind == .footnote }.count),
            "endnote": .int(doc.notes.filter { $0.kind == .endnote }.count),
            "annotation": .int(doc.notes.filter { $0.kind == .annotation }.count),
            "comment": .int(doc.notes.filter { $0.kind == .comment }.count),
        ])
        // Unrecognised symmetrical-sequence types: preserved, not silently dropped, so
        // the report can say so instead of going quiet.
        info["unknown_blocks"] = .array(doc.unknownBlocks.map { u in
            .object([
                "type": .string(u.cmd >= 0 ? "0x" + infoHexByte(u.cmd) : "malformed"),
                "offset": .int(u.offset),
                "length": .int(u.bytes.count),
            ])
        })
        // Page geometry from the file's own dot commands, with provenance — a caller
        // must be able to say "Legal (from file)" vs "Letter (default)".
        if let page = doc.page {
            info["page"] = .object([
                "size_name": .string(page.sizeName),
                "size_source": .string(page.sizeSource.rawValue),
                "height_in": .double(page.heightIn),
                // width is INFERRED from the height (task #16); its provenance is the
                // size's provenance
                "pw_in": .double(page.pwIn),
                "pl_lines": .double(page.plLines),
                "mt_lines": .double(page.mtLines),
                "mt_source": .string(page.mtSource.rawValue),
                "mb_lines": .double(page.mbLines),
                "mb_source": .string(page.mbSource.rawValue),
                "po_cols": .double(page.poCols),
                "po_source": .string(page.poSource.rawValue),
                "hm_lines": .double(page.hmLines),
                "hm_source": .string(page.hmSource.rawValue),
                "fm_lines": .double(page.fmLines),
                "fm_source": .string(page.fmSource.rawValue),
                "lh_48": .double(page.lh48),
                "lh_source": .string(page.lhSource.rawValue),
                "lh_varies": .bool(page.lhVaries),
                "ls": .double(page.ls),
                "ls_source": .string(page.lsSource.rawValue),
                "cw_120": .double(page.cw120),
                "cw_source": .string(page.cwSource.rawValue),
                "text_lines": .int(page.textLines),
                "pn_start": .int(page.pnStart),
                "pn_source": .string(page.pnSource.rawValue),
                "pc_col": page.pcCol.map(InfoValue.int) ?? .null,
                "pc_source": .string(page.pcSource.rawValue),
            ])
        }
        // `.PT`/`.PSA`/`.PSB` are WordTsar's inventions, not WordStar commands: their
        // presence identifies who WROTE the file, not how it is encoded.
        if let producer = doc.producer {
            info["producer"] = .string(producer)
        }
        // b24 round 17b (RULINGS-LEDGER row 6/7 DIAG column), port of ctrl-kd's own
        // CORRECTION commit (2855205): "formatting" surfaces the document-wide dot-
        // state (`.pr`/`.sr`/`.ul`/`.sb`/`.ps`/`.kr` etc) that previously rode on
        // `Document.formatting` internally but never reached `--diagnose` at all —
        // the standing discoverability rule ("everything these flags govern surfaces
        // in Info/Diagnose regardless of flag state"). Only keys the FILE actually
        // set appear (matching Python's `fmt.items()` dict comprehension); the exact
        // key SET mirrors ctrl-kd's own exclusion list (`_parse_format_dot`'s state
        // keys minus centering/justify/wrap/left_margin/right_margin/para_margin/
        // columns/column_gutter/lead_48 — those get dedicated homes elsewhere, or
        // (convertNotes/condCol) aren't part of `fmt` at all and are Swift-only
        // fields this diagnose surface does not carry either).
        var formatting: [String: InfoValue] = [:]
        if let v = doc.formatting.underlineBlanks { formatting["underline_blanks"] = .bool(v) }
        if let v = doc.formatting.suppressBlanks { formatting["suppress_blanks"] = .bool(v) }
        if let v = doc.formatting.proportional { formatting["proportional"] = .bool(v) }
        if let v = doc.formatting.kerning { formatting["kerning"] = .bool(v) }
        if let v = doc.formatting.orientation { formatting["orientation"] = .string(v.rawValue) }
        if let v = doc.formatting.subSuperRoll48 {
            formatting["sub_super_roll_48"] = .double(v)
        }
        if let v = doc.formatting.endnotesHere { formatting["endnotes_here"] = .bool(v) }
        if let v = doc.formatting.autoPageNumbers {
            formatting["auto_page_numbers"] = .bool(v)
        }
        if let v = doc.formatting.paranumFormat { formatting["paranum_format"] = .string(v) }
        if let v = doc.formatting.tabStops {
            formatting["tab_stops"] = .array(v.map(InfoValue.double))
        }
        if !formatting.isEmpty {
            info["formatting"] = .object(formatting)
        }
        // `.ps` (register row 6): parsed, deliberately NOT acted on — round 9's NLQ
        // ruling made the font block's own `proportional` bit the real, authoritative
        // source; `.ps` is a WS4-era toggle real font metadata has superseded. "No
        // rendering support" is a ruling, not a gap, but the file's own use of it
        // must still be VISIBLE.
        if doc.formatting.proportional != nil {
            info["ps_note"] = .string(
                ".ps (proportional spacing) is present but superseded by the font "
                + "block's own declared pitch (round 9 NLQ ruling) -- not separately honored")
        }
        // headers/footers/page numbers (ledger row 1): DECLARED content, regardless
        // of whether this call's own --headers flag would render them.
        if !doc.headers.isEmpty {
            info["headers"] = .object(Dictionary(
                uniqueKeysWithValues: doc.headers.map { (String($0.key), InfoValue.string($0.value)) }))
        }
        if !doc.footers.isEmpty {
            info["footers"] = .object(Dictionary(
                uniqueKeysWithValues: doc.footers.map { (String($0.key), InfoValue.string($0.value)) }))
        }
        // `.l#` (ledger row 5/6, register C11): the interval, or absent entirely when
        // the file never set it — matches `producer`'s own "only report what's
        // really there" shape.
        if let lineNumbering = doc.lineNumbering {
            info["line_numbering"] = .int(lineNumbering)
        }
        // `.psa`/`.psb` (ledger row 7, register): WordTsar's own inventions, tagged
        // as such explicitly here (not just via the document-wide `producer` field
        // above) so a caller reading vertical-spacing data alone still sees the
        // provenance without cross-referencing.
        if doc.spaceBeforeLines != nil || doc.spaceAfterLines != nil {
            info["vertical_spacing"] = .object([
                "space_before_lines": doc.spaceBeforeLines.map(InfoValue.double) ?? .null,
                "space_after_lines": doc.spaceAfterLines.map(InfoValue.double) ?? .null,
                "origin": .string("wordtsar"),   // never a real WordStar 4/5/7 command
            ])
        }
        // `.pm` (ledger row 5/7): a per-BLOCK field, aggregated to a count here —
        // diagnose reports document-shape facts, not a per-block dump (matching
        // `paragraphs`'s own aggregate shape above).
        let pmBlocks = doc.blocks.filter { $0.paraMargin != nil }.count
        if pmBlocks > 0 {
            info["pm_blocks"] = .int(pmBlocks)
        }
        // b24 round 18 item 4 (RULINGS-LEDGER row 4/10 DIAG): the standing
        // discoverability rule again -- "someone can say: there's a TOC here, I should
        // turn it on." Counts, not the entries themselves (matching `notes`'/
        // `pm_blocks`'s own aggregate shape): a document-shape fact, not a content dump.
        if !doc.tocEntries.isEmpty || !doc.indexEntries.isEmpty {
            info["toc_index"] = .object([
                "toc_entries": .int(doc.tocEntries.count),
                "index_entries": .int(doc.indexEntries.count),
            ])
        }
        // Inline colour (symmetric type 1) / size (a genuinely INLINE type-2 font block,
        // `offset >= 0` -- a style-declared font is document formatting, not authored
        // inline styling, and is not counted here, matching `--inline-styling`'s own
        // scope exactly).
        var colourSpans = 0
        var sizeSpans = 0
        for block in doc.blocks {
            for line in block.lines {
                for span in line.spans {
                    if span.colour != nil { colourSpans += 1 }
                    if let fi = span.font, fi < doc.fonts.count, doc.fonts[fi].offset >= 0 {
                        sizeSpans += 1
                    }
                }
            }
        }
        if colourSpans > 0 || sizeSpans > 0 {
            info["inline_styling"] = .object([
                "colour_spans": .int(colourSpans),
                "size_spans": .int(sizeSpans),
            ])
        }
        // b24 round 19 (RULINGS-LEDGER PIX row): pix tags, resolved-or-not, regardless
        // of the caller's own --pictures value -- the standing discoverability rule
        // again ("someone can say: there's a picture here, I should turn it on").
        if !doc.graphics.isEmpty {
            let results = pixResults ?? doc.graphics.enumerated().map { i, rawPath in
                PixResult(index: i, rawPath: rawPath, error: .unresolved)
            }
            let docDir = path.map(dirnameOf)
            let entries: [InfoValue] = results.map { r in
                let name = pixBasename(r.rawPath)
                if r.ok {
                    let rel = (docDir.map { d in r.resolvedPath.map { relativePath(from: d, to: $0) } } ?? nil)
                        ?? r.resolvedPath ?? r.rawPath
                    return .object([
                        "tag": .string(name), "resolved": .bool(true), "path": .string(rel),
                        "width": r.gcols.map(InfoValue.int) ?? .null,
                        "height": r.grows.map(InfoValue.int) ?? .null,
                    ])
                }
                return .object([
                    "tag": .string(name), "resolved": .bool(false),
                    "error": .string(r.error?.rawValue ?? "unresolved"),
                ])
            }
            info["pix"] = .array(entries)
        }
    } else if detection.variant == .printstream {
        // Damage WordStar itself introduced at print time (comments + the ASCII/
        // ASC256/PRVIEW/WS4 drivers truncated the rest of the line); reported so it
        // reads as a 1990s defect, not our parse failing.
        let doc = parsePrintstream(data)
        if let commentBug = doc.commentBug {
            info["comment_bug"] = .object([
                "count": .int(commentBug.count),
                "first_offset": .int(commentBug.firstOffset),
                "stray_ctrl_t": .bool(commentBug.strayControlT),
            ])
        }
    }
    return .object(info)
}
