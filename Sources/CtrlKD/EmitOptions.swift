/// Caller-supplied emitter options — the Swift answer to Python's `**options`
/// (emit.py:58, 108, 156, 208).
///
/// Python lets a caller pass any keyword to any emitter: `emit_html` reads `title`, and the
/// other three swallow everything into `**_options` and ignore it. That is what lets a
/// third-party emitter take options the library has never heard of, and it costs the
/// built-ins nothing — an unknown keyword is silently accepted, which is exactly what
/// `test_emitters_accept_unknown_options` pins.
///
/// Swift has no `**kwargs`, and both obvious substitutes are worse than a struct: a
/// `[String: Any]` dictionary discards the type of every value and would put a hole in the
/// library's `Sendable` story, while a per-emitter options protocol forces the caller to
/// pick a concrete type before it knows which emitter it is calling — precisely the thing
/// `convert(to:)` exists to avoid. So: one struct, handed to every emitter, each emitter
/// reading the fields that mean something to it and ignoring the rest.
///
/// What this deliberately drops is Python's *unknown* keyword: a Swift caller cannot pass
/// `frob: 1` to `emitText`, and shouldn't want to. An emitter needing options of its own
/// closes over them at registration time (see `EmitterRegistry.register`) rather than
/// smuggling them through here.
public struct EmitOptions: Hashable, Sendable {
    /// Goes in `<title>`, escaped. Read by `emitHTML`; the other three built-ins ignore it,
    /// exactly as in Python (emit.py:156 takes `title=''`, its three siblings do not).
    public var title: String

    public init(title: String = "") {
        self.title = title
    }
}
