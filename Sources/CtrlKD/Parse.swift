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
    /// Zero bytes: nothing to convert. Machine-readable kind `'empty'` in Python's
    /// ParseError (task #18: refusals explain themselves).
    case empty
    /// The content was classified as something the library cannot convert. Carries the
    /// refusal's WHY: `reason` is the evidence sentence `detect()` gathered (or Python's
    /// `'content statistics'` fallback when detection was overridden and gathered none),
    /// and `detection` the full evidence for callers (the app's error alert, the CLI
    /// message) that want to show it — Python's `ParseError.kind == 'binary'` with its
    /// `.detection` dict.
    case notConvertible(variant: Variant, reason: String, detection: Detection?)
}

/// Detect (unless told) and parse. `variant` overrides detection, matching Python's
/// optional `variant` argument.
///
/// Throws `ParseError` for content it cannot convert; the error carries the detection
/// evidence so callers can explain the refusal (task #18, ruled 2026-08-06: "whatever
/// error and debug handling we can wire in early, the better").
public func parse(_ data: [UInt8], variant: Variant? = nil) throws -> Document {
    if data.isEmpty {
        throw ParseError.empty
    }
    let detection = variant == nil ? detect(data) : nil
    let v = variant ?? detection!.variant
    switch v {
    case .ws4, .ws5plus:
        return parseWS(data)
    case .printstream, .text:
        return parsePrintstream(data)
    case .binary:
        throw ParseError.notConvertible(variant: v,
                                        reason: detection?.reason ?? "content statistics",
                                        detection: detection)
    }
}
