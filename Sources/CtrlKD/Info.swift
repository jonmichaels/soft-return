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
public func documentInfo(_ data: [UInt8], path: String? = nil) -> InfoValue {
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
