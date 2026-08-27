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
    let emitter = try lookUp(format, in: registry)
    let output = emitter.emit(try parse(data), mode, options)
    guard let text = output.asText else {
        throw EmitError.binaryFormat(name: emitter.name, ext: emitter.ext)
    }
    return text
}

/// The same conversion, as the bytes you would write to a file — for every format.
///
/// This is the front door for a caller that is saving rather than displaying, and the only
/// one that works whatever the format is: a text rendering comes back UTF-8 encoded, a PDF
/// comes back as itself. `convert` above stays the one that returns a `String`, because a
/// preview pane and a `--to markdown` pipe both want characters and neither should have to
/// decode. Ask `registry.getEmitter(format)?.ext` for what to name the file.
///
/// - Throws: `EmitError.unknownFormat` if `to` names nothing in `registry`, or
///   `ParseError.notConvertible` if the bytes aren't a convertible document. Notably NOT
///   `binaryFormat` — that error exists only where a `String` was promised.
public func convertData(
    _ data: [UInt8],
    to format: String = "markdown",
    mode: EmitMode = .modern,
    options: EmitOptions = EmitOptions(),
    registry: EmitterRegistry = .standard
) throws -> [UInt8] {
    try lookUp(format, in: registry).emit(try parse(data), mode, options).asBytes
}

private func lookUp(_ format: String, in registry: EmitterRegistry) throws -> Emitter {
    guard let emitter = registry.getEmitter(format) else {
        throw EmitError.unknownFormat(name: format, known: registry.formats())
    }
    return emitter
}
