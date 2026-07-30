/// The library's main entry point. Direct port of `parse` (core.py:385-392).

/// Why a file could not be parsed.
///
/// Python raises `ValueError('not a convertible file (detected: …)')`. Ported as a thrown
/// Swift error rather than a `Result`: `throws` is what Swift callers expect from a
/// fallible operation, it composes with `try`/`try?`, and a caller that genuinely wants a
/// value can wrap it (`Result { try parse(data) }`) — whereas a `Result` return forces
/// every caller to unwrap even when they'd rather propagate. The `variant` is carried on
/// the error so a GUI can say *why* a file was refused, not just that it was.
public enum ParseError: Error, Hashable, Sendable {
    /// The content was classified as something the library cannot convert — `binary`, or
    /// an empty/`^Z`-led file.
    case notConvertible(variant: Variant)
}

/// Detect (unless told) and parse. `variant` overrides detection, matching Python's
/// optional `variant` argument.
public func parse(_ data: [UInt8], variant: Variant? = nil) throws -> Document {
    let v = variant ?? detect(data).variant
    switch v {
    case .ws4, .ws5plus:
        return parseWS(data)
    case .printstream, .text:
        return parsePrintstream(data)
    case .binary:
        throw ParseError.notConvertible(variant: v)
    }
}
