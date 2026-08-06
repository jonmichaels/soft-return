import Testing
@testable import CtrlKD

/// Named-test ports for the registry and `convert()`, plus coverage for behavior the
/// job-010 vectors don't discriminate. Expected values that aren't in the vector file were
/// produced by running the Python reference (ctrl-kd 1.1.4) locally — same ground truth.

// MARK: - ports of the Python named tests

@Test func convertAPI() throws {
    // Mirrors test_convert_api.
    let out = try convert(makeProse(), to: "markdown")
    #expect(out.contains("Second paragraph."))

    // `markdown` is the default `to`, as in Python's signature — asserted on a STYLED input
    // rather than makeProse. That fixture carries no styles and no Markdown metacharacters,
    // so its text and markdown renderings are byte-identical and `convert(makeProse()) ==
    // convert(makeProse(), to: "markdown")` holds whatever the default is. Mutation testing
    // caught the vacuous version: flipping the default to "text" passed it.
    //
    // Built in steps, not one `+` chain: a chain of byte-array literals is the type-checker
    // trap earlier jobs hit ("unable to type-check this expression in reasonable time").
    let boldToggle: [UInt8] = [0x02]
    var styled: [UInt8] = boldToggle
    styled += ws4Text("Registry Test")
    styled += boldToggle
    styled += HARD
    styled += HARD
    styled += ws4Text("One paragraph is enough to prove wiring.")
    styled += HARD
    #expect(try convert(styled) == convert(styled, to: "markdown"))
    #expect(try convert(styled) != convert(styled, to: "text"))
    #expect(try convert(styled).hasPrefix("**Registry Test**"))
}

@Test func customEmitterRegistration() throws {
    // Mirrors test_custom_emitter_registration, allowing for the ratified divergence: the
    // Python decorator mutates module state, so its `convert` sees `shout` with no further
    // ceremony. Here the derived registry is the thing that knows, and it gets passed in.
    let registry = EmitterRegistry.standard
        .register("shout", ext: ".loud", aliases: ["yell"]) { doc, _, _ in
            doc.iterLines().map { $0.text() }.joined(separator: " ").uppercased()
        }

    #expect(registry.formats().contains("shout"))
    #expect(registry.formats().contains("yell"))
    let out = try convert(bytes("quiet words here.\r\n"), to: "yell", registry: registry)
    #expect(out.contains("QUIET WORDS HERE."))

    // The alias resolves to the canonical emitter, carrying the name and extension it was
    // registered with — `.loud`, not the `'.' + name` default.
    #expect(registry.getEmitter("yell")?.name == "shout")
    #expect(registry.getEmitter("yell")?.ext == ".loud")
    #expect(registry.getEmitter("shout")?.ext == ".loud")

    // The half Python cannot test, and the reason for the divergence: registering did NOT
    // reach into the shared registry. Python's own version of this test leaves `shout`
    // visible to every test that runs after it.
    #expect(!EmitterRegistry.standard.formats().contains("shout"))
    #expect(EmitterRegistry.standard.getEmitter("yell") == nil)
    #expect(throws: EmitError.self) {
        _ = try convert(bytes("quiet words here.\r\n"), to: "yell")
    }
}

@Test func everyBuiltInEmitterAcceptsEmitOptions() throws {
    // test_emitters_accept_unknown_options, reinterpreted per the job spec: Swift has no
    // `**options`, so the ported assertion is that an `EmitOptions` carrying a title goes to
    // every built-in emitter and only `html` acts on it. The Python test asserts merely that
    // the calls don't raise; this asserts what each one does with the option.
    let data = bytes("some words here.\r\n")
    let options = EmitOptions(title: "x")

    for format in ["text", "markdown", "html", "rtf"] {
        let withTitle = try convert(data, to: format, options: options)
        let withoutTitle = try convert(data, to: format)
        #expect(!withTitle.isEmpty, "\(format) produced nothing")
        if format == "html" {
            #expect(withTitle.contains("<title>x</title>"), "html must read options.title")
            #expect(withoutTitle.contains("<title></title>"), "html default title is empty")
        } else {
            #expect(withTitle == withoutTitle, "\(format) must ignore options.title")
        }
    }
}

// MARK: - gap-closing tests (not discriminated by the job-010 vectors)

@Test func standardRegistryFormatsAreExactlyTheEightNames() {
    // Pins the whole table in one assertion: six canonical names, Python's two seed aliases,
    // sorted. A dropped alias, an extra format, or an unsorted return all fail here.
    //
    // Eight is Python's own count since `layout` joined the table (task #15) — Python gets
    // `pdf` and `layout` by importing their modules (each `@emitter(...)` registers on the
    // way past), this gets them from literals.
    #expect(EmitterRegistry.standard.formats()
            == ["html", "layout", "markdown", "md", "pdf", "rtf", "text", "txt"])
}

@Test func bothSeedAliasesResolveToTheirCanonicalFormat() throws {
    // The convert vectors only exercise `md`. `txt` is in the same table and equally easy to
    // mis-wire — swapping the two values passes all five vectors, since `md` -> markdown
    // would still be right and `txt` is never looked up.
    let data = bytes("some words here.\r\n")
    #expect(try convert(data, to: "txt") == convert(data, to: "text"))
    #expect(try convert(data, to: "md") == convert(data, to: "markdown"))
    // ...and they are genuinely different renderings, so the assertions above can't both pass
    // by the two formats happening to agree on this input.
    #expect(try convert(data, to: "txt") != convert(data, to: "md"))

    #expect(EmitterRegistry.standard.getEmitter("txt")?.name == "text")
    #expect(EmitterRegistry.standard.getEmitter("md")?.name == "markdown")
}

@Test func builtInExtensionsAreTheOnesPythonRegistered() {
    // `text` -> `.txt` and `markdown` -> `.md` do NOT follow the `'.' + name` default
    // (emit.py:238-239), so they'd survive a mutation that dropped the explicit `ext:`
    // argument only if someone checks. A Save dialog will read these.
    let registry = EmitterRegistry.standard
    #expect(registry.getEmitter("text")?.ext == ".txt")
    #expect(registry.getEmitter("markdown")?.ext == ".md")
    #expect(registry.getEmitter("html")?.ext == ".html")
    #expect(registry.getEmitter("rtf")?.ext == ".rtf")
    // The default is still the default, for a format that doesn't override it.
    #expect(registry.register("latex") { _, _, _ in "" }.getEmitter("latex")?.ext == ".latex")
}

@Test func convertPassesModeThroughToTheEmitter() throws {
    // All five convert vectors are `modern`, so a `convert` that ignored its `mode` and
    // always passed `.modern` would pass every one of them. This input renders differently
    // in the two modes (form feed -> dashed rule vs a literal `\f`), which is what makes the
    // passthrough observable. (Long enough to detect as a print stream — a handful of bytes
    // with a control character in them classifies as `binary`, per tinyFileNotMisdetectedAsWS4.)
    let data = bytes("Some plain text here today.\r\n\u{0C}And a second page follows.\r\n")
    let doc = try parse(data)
    #expect(try convert(data, to: "text", mode: .printed) == emitText(doc, mode: .printed))
    #expect(try convert(data, to: "text", mode: .modern) == emitText(doc, mode: .modern))
    #expect(emitText(doc, mode: .printed) != emitText(doc, mode: .modern))
}

@Test func unknownFormatThrowsAndSaysWhatItKnows() throws {
    // Python raises a bare `KeyError('docx')` out of `get_emitter`'s subscript. The ported
    // error carries the available names as well, because the caller that hits this is a
    // `--to` flag or a GUI picker and "docx isn't one of: html, markdown, ..." is the whole
    // message it wants to show.
    #expect(EmitterRegistry.standard.getEmitter("docx") == nil)
    let error = #expect(throws: EmitError.self) {
        _ = try convert(bytes("some words here.\r\n"), to: "docx")
    }
    #expect(error == .unknownFormat(
        name: "docx", known: ["html", "layout", "markdown", "md", "pdf", "rtf", "text", "txt"]
    ))
    // An empty name is a miss like any other, not a crash or a default.
    #expect(EmitterRegistry.standard.getEmitter("") == nil)
}

@Test func registeringAnExistingNameReplacesIt() throws {
    // Python's `emitter()` assigns into `_REGISTRY` unconditionally, so re-registering a name
    // shadows the built-in. Kept, because a host app overriding `html` with its own template
    // is a legitimate use of the extension point — and because silently ignoring the second
    // registration would be the surprising behavior.
    let registry = EmitterRegistry.standard.register("text", ext: ".mine") { _, _, _ in "REPLACED" }
    #expect(try convert(bytes("some words here.\r\n"), to: "text", registry: registry) == "REPLACED")
    // Reached through the alias too: `txt` still points at `text`, which is now the new one.
    #expect(try convert(bytes("some words here.\r\n"), to: "txt", registry: registry) == "REPLACED")
    #expect(registry.getEmitter("text")?.ext == ".mine")
    // formats() is unchanged — a replacement adds no name.
    #expect(registry.formats() == EmitterRegistry.standard.formats())
}

@Test func registeringCanRepointAnExistingAlias() throws {
    // Same dict-assignment semantics on the alias side: `_ALIASES[a] = name` overwrites.
    // Unlikely, but it's the difference between "aliases are a mapping" and "aliases are
    // immutable once seeded", and only a test says which.
    let data = bytes("some words here.\r\n")
    let registry = EmitterRegistry.standard.register("html", aliases: ["md"]) { _, _, _ in "HI" }
    #expect(try convert(data, to: "md", registry: registry) == "HI")
    #expect(registry.getEmitter("md")?.name == "html")
    // The canonical name it used to point at is untouched.
    #expect(registry.getEmitter("markdown")?.name == "markdown")
}

@Test func convertRefusesBinaryTheSameWayParseDoes() throws {
    // `convert` calls `parse`, so a binary file must come back as ParseError, not as an empty
    // string or a partly-rendered document. Python propagates the same ValueError.
    var binary: [UInt8] = []
    for _ in 0..<4 { binary += (0...255).map { UInt8($0) } }
    #expect(throws: ParseError.notConvertible(variant: .binary)) {
        _ = try convert(binary)
    }
}

@Test func emitOptionsDefaultsToAnEmptyTitle() {
    // The default is what every convert vector's `<title></title>` depends on.
    #expect(EmitOptions().title == "")
    #expect(EmitOptions(title: "x") != EmitOptions())
}
