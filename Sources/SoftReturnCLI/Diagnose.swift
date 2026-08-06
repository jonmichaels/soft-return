import CtrlKD

/// `--diagnose`: CLI face of the library's `documentInfo` (moved to `CtrlKD/Info.swift`,
/// task #17 — the app's Document Info window consumes the same value). This wrapper only
/// converts the library's JSON-safe tree into this CLI's rendering type; the report's
/// content and shapes are documented on `documentInfo` itself.
///
/// Ruled EQUIVALENT-not-byte-identical to Python's output: the same keys carrying the same
/// values, rendered in this CLI's documented shape (sorted keys, two-space indent).
public func diagnose(path: String, data: [UInt8]) -> JSONValue {
    render(documentInfo(data, path: path))
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
