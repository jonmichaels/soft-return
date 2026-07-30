/// The emitter registry: the library's extension point. Direct port of emit.py:26-51 —
/// `_REGISTRY`, `_ALIASES`, `emitter()`, `get_emitter()`, `formats()`.
///
/// PLUGIN DISCOVERY IS NOT PORTED. Python's `load_plugins()` (emit.py:45-51) walks the
/// `ctrlkd.emitters` entry-point group so that `pip install ctrl-kd-docx` is all a user
/// needs. Swift has no runtime equivalent worth imitating: a statically linked package has
/// no installable third-party emitters to find, and the dynamic-loading story (`dlopen` a
/// bundle, trust its symbols) is a host-application decision about code signing and
/// sandboxing, not a library one. A GUI or CLI built on this package registers what it
/// wants at startup — `EmitterRegistry.standard.register(...)` — and that IS the extension
/// point here.

/// Why an emitter name isn't a format this registry knows.
public enum EmitError: Error, Hashable, Sendable {
    /// No emitter and no alias matched. Python raises `KeyError` from `get_emitter`'s bare
    /// subscript; `convert` surfaces it as this instead, and carries the name that failed
    /// plus what WAS available so a GUI can say something useful rather than "error".
    case unknownFormat(name: String, known: [String])
    /// The format renders to bytes, and the caller asked for a `String` — `convert(to: "pdf")`.
    /// Python has no such error because it has no such check: `emit_pdf` returns `bytes`,
    /// `convert` passes them through, and the mistake surfaces later as a `TypeError` from
    /// whatever tried to treat them as text. Use `convertData` instead; it serves both kinds.
    case binaryFormat(name: String, ext: String)
}

/// One registered output format: how to render it, and the extension it saves as.
public struct Emitter: Sendable {
    /// The canonical name, e.g. `"markdown"`. Aliases are the registry's business, not the
    /// emitter's — `getEmitter("md")` and `getEmitter("markdown")` both return this, whose
    /// `name` reads `"markdown"` either way.
    public let name: String
    /// Extension including the dot, e.g. `".md"` — for naming the output file. Python
    /// defaults it to `'.' + name` (emit.py:32); so does `init` below.
    public let ext: String
    /// The render function: Python's `(doc, mode='modern', **options) -> str | bytes`, with
    /// the defaults dropped because a stored closure can't carry them, and the union return
    /// spelled as `EmitOutput`. Every built-in emitter has this shape, which is what makes
    /// them interchangeable behind `convert(to:)`.
    public let emit: @Sendable (Document, EmitMode, EmitOptions) -> EmitOutput

    public init(
        name: String,
        ext: String? = nil,
        emit: @escaping @Sendable (Document, EmitMode, EmitOptions) -> EmitOutput
    ) {
        self.name = name
        self.ext = ext ?? "." + name
        self.emit = emit
    }

    /// A text emitter, wrapped. Four of the five built-ins take this path, and so will most
    /// emitters anyone else writes — `.text(...)` at every `return` in a renderer is noise
    /// that says nothing the format didn't already say once.
    public init(
        name: String,
        ext: String? = nil,
        text emit: @escaping @Sendable (Document, EmitMode, EmitOptions) -> String
    ) {
        self.init(name: name, ext: ext) { .text(emit($0, $1, $2)) }
    }
}

/// A set of known output formats, with Python's alias table.
///
/// VALUE SEMANTICS, DELIBERATELY. Python registers by mutating module-level dicts, so
/// importing `ctrlkd.pdf` anywhere changes what `formats()` returns everywhere, forever.
/// That is convenient for a decorator and hostile to everything else: two callers wanting
/// different format sets cannot have them, a test that registers an emitter leaks it into
/// every later test in the process (Python's own `test_custom_emitter_registration` leaves
/// `shout` registered for the rest of the run), and in Swift the direct translation — a
/// global mutable dictionary — is a data race that would need `@unchecked Sendable` and a
/// lock to paper over.
///
/// So this is a struct. `register` returns a NEW registry rather than mutating a shared one,
/// `.standard` is an immutable `let`, and a caller that wants extra formats holds onto its
/// own derived value. No global state, no locking, no `@unchecked` anything.
public struct EmitterRegistry: Sendable {
    /// Canonical name -> emitter. Python's `_REGISTRY`, minus the `{'fn':, 'ext':}` dict
    /// (that's `Emitter`).
    private var emitters: [String: Emitter]
    /// Alias -> canonical name. Python's `_ALIASES`.
    private var aliases: [String: String]

    private init(emitters: [String: Emitter], aliases: [String: String]) {
        self.emitters = emitters
        self.aliases = aliases
    }

    /// The five built-in formats and Python's seed alias table (emit.py:27, 238-241, and
    /// `pdf.py`'s `@emitter('pdf')`).
    ///
    /// `formats()` over this table returns Python's seven names exactly — five canonical plus
    /// the two aliases. The extensions are Python's, and note they do not follow the
    /// `'.' + name` default (`text` saves as `.txt`, `markdown` as `.md`).
    ///
    /// `pdf` is the one entry that cannot use the `text:` convenience: it renders to bytes,
    /// so it returns `.data` and needs the full `Emitter` initializer.
    public static let standard = EmitterRegistry(
        emitters: [
            "text": Emitter(name: "text", ext: ".txt", text: emitText),
            "markdown": Emitter(name: "markdown", ext: ".md", text: emitMarkdown),
            "html": Emitter(name: "html", ext: ".html", text: emitHTML),
            "rtf": Emitter(name: "rtf", ext: ".rtf", text: emitRTF),
            "pdf": Emitter(name: "pdf", ext: ".pdf") { .data(emitPDF($0, mode: $1, options: $2)) },
        ],
        aliases: ["txt": "text", "md": "markdown"]
    )

    /// Add a format, returning a new registry. Port of `emitter()` (emit.py:29-37), which is
    /// a decorator there and cannot be one here — Swift has no decorators, and a returned
    /// value is the point anyway.
    ///
    /// Registering a name that already exists replaces it, matching Python's plain dict
    /// assignment (`load_plugins` is the only path there that checks first). Aliases are
    /// applied after, so an alias may be re-pointed at a new canonical name the same way.
    public func register(
        _ name: String,
        ext: String? = nil,
        aliases newAliases: [String] = [],
        emit: @escaping @Sendable (Document, EmitMode, EmitOptions) -> EmitOutput
    ) -> EmitterRegistry {
        register(Emitter(name: name, ext: ext, emit: emit), aliases: newAliases)
    }

    /// The same, for an emitter that renders text — see `Emitter.init(name:ext:text:)`.
    /// Overloaded on the closure's return type rather than given a second verb, so that
    /// `register("shout") { ... "…" }` reads the same whichever kind of format it is.
    public func register(
        _ name: String,
        ext: String? = nil,
        aliases newAliases: [String] = [],
        text emit: @escaping @Sendable (Document, EmitMode, EmitOptions) -> String
    ) -> EmitterRegistry {
        register(Emitter(name: name, ext: ext, text: emit), aliases: newAliases)
    }

    /// The shared half of both overloads: install the emitter and point the aliases at it.
    public func register(_ emitter: Emitter, aliases newAliases: [String] = []) -> EmitterRegistry {
        var copy = self
        copy.emitters[emitter.name] = emitter
        for alias in newAliases {
            copy.aliases[alias] = emitter.name
        }
        return copy
    }

    /// Look up by canonical name or alias. Port of `get_emitter` (emit.py:39-40).
    ///
    /// Returns `nil` where Python raises `KeyError` off its bare subscript: an absent key is
    /// an ordinary outcome when the name came from a user (a `--to` flag, a GUI picker), and
    /// `if let` at the call site beats a thrown error for a lookup. `convert` is the one that
    /// turns the miss into `EmitError.unknownFormat`, because there the caller asked for
    /// output and there is none to give.
    public func getEmitter(_ name: String) -> Emitter? {
        emitters[aliases[name] ?? name]
    }

    /// Every name a caller may pass to `getEmitter` — canonical names AND aliases, sorted.
    /// Port of `formats()` (emit.py:42-43), for populating a CLI's choices or a GUI's format
    /// picker. Sorted for the same reason Python sorts: a stable menu order.
    public func formats() -> [String] {
        Array(Set(emitters.keys).union(aliases.keys)).sorted()
    }
}
