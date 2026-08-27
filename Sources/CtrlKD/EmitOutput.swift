/// What an emitter produced: characters, or bytes.
///
/// Python needs no such type. `emit_text` returns `str` and `emit_pdf` returns `bytes`, the
/// registry stores both in the same dict, and nothing checks — `convert` hands back whatever
/// came out and a caller that writes it to a file opened in the wrong mode finds out at
/// runtime. Swift will not store two return types in one `Emitter`, and papering over that
/// with `Any` would move the same failure to the same place, minus the type checker.
///
/// So the return type names both possibilities. Every emitter declares which one it is by
/// which case it returns, `convert` can refuse a binary format at the point where a `String`
/// was asked for, and a GUI can decide between showing text in a pane and writing bytes to
/// disk without a table of which formats are which.
public enum EmitOutput: Hashable, Sendable {
    /// A text format's rendering — markdown, HTML, RTF, plain text.
    case text(String)
    /// A binary format's rendering — PDF, and whatever else arrives later.
    case data([UInt8])

    /// The string, or `nil` for a binary format. For the "I know this one is text" call site;
    /// `convert` uses it to decide whether it can honor its `-> String` signature.
    public var asText: String? {
        switch self {
        case .text(let s): return s
        case .data: return nil
        }
    }

    /// The bytes to write to a file, either way — a text rendering is UTF-8 encoded.
    ///
    /// UTF-8 and not CP437: the input encoding is a WordStar fact (job-004), the output
    /// encoding is a modern-file fact. Python's `emit_*` return `str` and leave the encoding
    /// to whoever opens the file, which in its own CLI is `encoding='utf-8'`.
    public var asBytes: [UInt8] {
        switch self {
        case .text(let s): return Array(s.utf8)
        case .data(let d): return d
        }
    }

    /// Whether this is a binary rendering — for a caller choosing a code path before it has
    /// the output in hand (a save panel picking text vs binary, say).
    public var isBinary: Bool {
        asText == nil
    }
}
