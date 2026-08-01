import CtrlKD

/// Two lowercase hex digits, Foundation-free (String(format:) would pull it in).
private func hexByte(_ v: Int) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[(v >> 4) & 0xF], digits[v & 0xF]])
}

/// `--diagnose`: what IS this file? Port of `diagnose` (cli.py:12-22).
///
/// Ruled EQUIVALENT-not-byte-identical to Python's output: the same keys carrying the same
/// values, rendered in this CLI's documented shape (sorted keys, two-space indent). Python's
/// output is a dict literal in insertion order; nothing should depend on that, and the
/// vectors assert information, not bytes.
///
/// Python's dict has three shapes and so does this, for the same reasons:
///
/// 1. **Empty, or `^Z` at byte 0** — `variant` and `reason` only. `detect()` returns before
///    it counts anything (core.py:61-62), so there is no evidence to report.
/// 2. **Detected, not WordStar** — plus the six evidence counts.
/// 3. **`ws4` / `ws5+`** — plus what `parse_ws` learned: the margin it estimated, the dot
///    commands it saw, the control codes it did not recognize, whether a ruler line made the
///    document columnar, the paragraph and footnote counts, per-kind note counts
///    (`footnote`/`endnote`/`annotation`/`comment`, ctrl-kd 1.2.0), resolved page geometry
///    with provenance, and `producer` when WordTsar's own dot commands were seen.
///
/// A fourth case rides alongside shape 2 rather than replacing it: a `printstream` file
/// additionally gets `comment_bug` when WordStar's own COMMENT.BUG print-time damage
/// signature is present (ctrl-kd 1.2.0) — framed as period damage, not a parse failure.
///
/// Note that this ignores any `--variant` override, exactly as Python does: diagnose reports
/// what the bytes say, and an override would only report the answer back to whoever typed it.
public func diagnose(path: String, data: [UInt8]) -> JSONValue {
    let detection = detect(data)
    var info: [String: JSONValue] = [
        "file": .string(path),
        "variant": .string(detection.variant.rawValue),
    ]
    if let reason = detection.reason {
        info["reason"] = .string(reason)
    }

    // Shape 1 vs 2. `size` is the discriminator because it is `core.count` on every path
    // that computes evidence, and `core` is non-empty on all of them — so `size == 0` happens
    // only on the early return, and only there are the other counts meaningless rather than
    // merely zero. (Swift's `Detection` always carries the fields; Python's dict omits them.)
    if detection.size > 0 {
        info["soft_returns"] = .int(detection.softReturns)
        info["hard_returns"] = .int(detection.hardReturns)
        info["high_bit_bytes"] = .int(detection.highBitBytes)
        info["text_pct"] = .int(detection.textPct)
        info["symmetric_blocks_1d"] = .int(detection.symmetricBlocks1D)
        info["size"] = .int(detection.size)
    }

    // Shape 3.
    if detection.variant == .ws4 || detection.variant == .ws5plus {
        let doc = parseWS(data)
        // `marginEstimate` is optional on `Document` because `parsePrintstream` never sets
        // it; `parseWS` always does, so the `.null` arm is unreachable through this path and
        // exists so the shape stays honest if that ever changes.
        info["margin_estimate"] = doc.marginEstimate.map(JSONValue.int) ?? .null
        info["dot_commands"] = .array(doc.dotCommands.map(JSONValue.string))
        info["unknown_codes"] = .object(
            Dictionary(uniqueKeysWithValues: doc.unknownCodes.map {
                ("0x" + JSONValue.hex2($0.key), JSONValue.int($0.value))
            }))
        info["columnar"] = .bool(doc.columnar)
        info["paragraphs"] = .int(doc.blocks.filter { $0.kind == .para }.count)
        // NOTE: no "footnotes" key. ctrl-kd 1.2.0 dropped it in favour of the
        // per-kind `notes` object below -- a flat count could not distinguish a
        // footnote from an endnote from an annotation, which is the whole point.
        // Unrecognised symmetrical-sequence types: preserved, not silently dropped,
        // so --diagnose can report them instead of going quiet.
        info["unknown_blocks"] = .array(doc.unknownBlocks.map { u in
            .object([
                "type": .string(u.cmd >= 0 ? "0x" + hexByte(u.cmd) : "malformed"),
                "offset": .int(u.offset),
                "length": .int(u.bytes.count),
            ])
        })

        // ctrl-kd 1.2.0: note kinds, counted separately rather than flattened, so a
        // rescue tool can say a file contains hidden comments even when this run is
        // only converting to plain text (cli.py's `diagnose`).
        info["notes"] = .object([
            "footnote": .int(doc.notes.filter { $0.kind == .footnote }.count),
            "endnote": .int(doc.notes.filter { $0.kind == .endnote }.count),
            "annotation": .int(doc.notes.filter { $0.kind == .annotation }.count),
            "comment": .int(doc.notes.filter { $0.kind == .comment }.count),
        ])

        // Page geometry from the file's own dot commands, with provenance -- a caller
        // must be able to say "Legal (from file)" vs "Letter (from default)". `parseWS`
        // resolves this regardless of variant, so `doc.page` is non-nil here in
        // practice; the `if let` is defensive rather than an expected-nil path.
        if let page = doc.page {
            info["page"] = .object([
                "size_name": .string(page.sizeName),
                "size_source": .string(page.sizeSource.rawValue),
                "height_in": .double(page.heightIn),
                "pl_lines": .double(page.plLines),
                "mt_lines": .double(page.mtLines),
                "mt_source": .string(page.mtSource.rawValue),
                "mb_lines": .double(page.mbLines),
                "mb_source": .string(page.mbSource.rawValue),
                "po_cols": .double(page.poCols),
                "po_source": .string(page.poSource.rawValue),
                // ctrl-kd 1.3.0: WordStar's own vertical model (`.hm`/`.fm` recorded for
                // diagnosis only, never reserving space; `.lh`/`.ls` per `PageGeometry`'s
                // doc comment) plus the one derived figure a caller actually needs —
                // printed text lines per page, from the rest of this same object.
                "hm_lines": .double(page.hmLines),
                "hm_source": .string(page.hmSource.rawValue),
                "fm_lines": .double(page.fmLines),
                "fm_source": .string(page.fmSource.rawValue),
                "lh_48": .double(page.lh48),
                "lh_source": .string(page.lhSource.rawValue),
                "ls": .double(page.ls),
                "ls_source": .string(page.lsSource.rawValue),
                "text_lines": .int(page.textLines),
            ])
        }

        // `.PT`/`.PSA`/`.PSB` are WordTsar's own invented dot commands, never written by
        // real WordStar, so their mere presence is a producer signal -- provenance (who
        // wrote this file), not format (`variant` above stays whatever the actual
        // encoding is). Present only when detected.
        if let producer = doc.producer {
            info["producer"] = .string(producer)
        }
    } else if detection.variant == .printstream {
        // COMMENT.BUG: WordStar's own documented print-time truncation damage --
        // comments, and the ASCII/ASC256/PRVIEW/WS4 drivers, deleted everything after a
        // comment on that line -- not a parse failure, so it's reported as a signature
        // (1990s damage) rather than going quiet or reading as this tool's mistake.
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
