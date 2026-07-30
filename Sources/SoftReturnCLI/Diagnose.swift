import CtrlKD

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
///    document columnar, and the paragraph and footnote counts.
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
        info["footnotes"] = .int(doc.footnotes.count)
    }
    return .object(info)
}
