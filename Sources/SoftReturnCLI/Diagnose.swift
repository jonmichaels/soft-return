import CtrlKD

/// `--diagnose`: CLI face of the library's `documentInfo` (moved to `CtrlKD/Info.swift`,
/// task #17 — the app's Document Info window consumes the same value). This wrapper only
/// converts the library's JSON-safe tree into this CLI's rendering type; the report's
/// content and shapes are documented on `documentInfo` itself.
///
/// Ruled EQUIVALENT-not-byte-identical to Python's output: the same keys carrying the same
/// values, rendered in this CLI's documented shape (sorted keys, two-space indent).
public func diagnose(path: String, data: [UInt8], environment: CLIEnvironment) -> JSONValue {
    // b24 round 19 (RULINGS-LEDGER PIX row): resolved regardless of the caller's own
    // --pictures value -- diagnose's own standing discoverability rule ("someone can
    // say: there's a picture here, I should turn it on"). A second `parseWS` call
    // (documentInfo's own ws4/ws5+ branch parses again internally) is an accepted
    // redundancy for a one-shot diagnostic operation -- not on any conversion's own
    // hot path.
    let graphics = parseWS(data).graphics
    let pixResults = graphics.isEmpty ? nil : resolveDocumentPictures(
        Document(graphics: graphics), docPath: path, environment: environment)
    return render(documentInfo(data, path: path, pixResults: pixResults))
}

/// `CtrlKD.InfoValue` -> this CLI's `JSONValue`, mechanically.
private func render(_ value: InfoValue) -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .array(let items): return .array(items.map(render))
    case .object(let fields): return .object(fields.mapValues(render))
    }
}
