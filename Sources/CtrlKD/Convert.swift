/// The one-call front door. Direct port of `convert` (`__init__.py:11-14`).

/// Bytes in, converted string out: detect, parse, and render in one call.
///
/// - Parameters:
///   - data: the raw file contents, as they sit on disk.
///   - to: a format name or alias — anything `registry.formats()` lists.
///   - mode: `.modern` reflows for reading, `.printed` reproduces the page. Note that a
///     print capture or columnar document renders line-for-line either way; the emitters
///     decide that themselves via `isPrinted` (emit.py:53-54).
///   - options: passed through to the emitter, which reads what it understands.
///   - registry: which formats exist. Defaults to the four built-ins; pass a derived
///     registry to reach an emitter you registered yourself.
/// - Throws: `EmitError.unknownFormat` if `to` names nothing in `registry`, or
///   `ParseError.notConvertible` if the bytes aren't a convertible document.
///
/// Python's `encoding='cp437'` parameter has no counterpart because the Swift `parse` has
/// none: the decoder is CP437, decided in job-004. Python's parameter is nearly as
/// theoretical — it forwards to `parse`, and every codec other than cp437 mis-decodes the
/// high-bit bytes that WordStar files are made of. When a real second encoding shows up it
/// belongs on `parse` first, and this signature follows it.
public func convert(
    _ data: [UInt8],
    to format: String = "markdown",
    mode: EmitMode = .modern,
    options: EmitOptions = EmitOptions(),
    registry: EmitterRegistry = .standard
) throws -> String {
    guard let emitter = registry.getEmitter(format) else {
        throw EmitError.unknownFormat(name: format, known: registry.formats())
    }
    return emitter.emit(try parse(data), mode, options)
}
