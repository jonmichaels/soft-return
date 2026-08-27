import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 373 (b24 FLAG UI): `DocumentOperations.ConversionOptions`/`ExportEngine.render` gained
/// four new fields (`headers`/`toc`/`inlineStyling`/`pictures`) mirroring `EmitOptions`' own
/// b24 rounds 17-19 flags. These tests prove the WIRING — that a value set on the app-side
/// options struct actually reaches the emitted bytes — not the engine's own flag behavior
/// (that is `EmitOptions`' own test suite's job).
@Suite struct FlagUIPlumbingTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    // MARK: - Defaults match EmitOptions' own ruled defaults exactly

    @Test func conversionOptionsDefaultsMatchEmitOptionsRuledDefaults() {
        let options = DocumentOperations.ConversionOptions(formats: ["rtf"])
        let bare = EmitOptions()
        #expect(options.headers == bare.headers)
        #expect(options.toc == bare.toc)
        #expect(options.inlineStyling == bare.inlineStyling)
        #expect(options.pictures == bare.pictures)
    }

    // MARK: - Headers: POWERUSE.WS's own real running head (job 371's HeadersInViewsTests fixture)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func headersFlagGatesTheDeclaredRunningHeadInRTF() throws {
        let data = try Data(contentsOf: Self.ws7Directory.appendingPathComponent("POWERUSE.WS"))
        let bytes = [UInt8](data)
        let doc = try DocumentOperations.open(data: bytes).document
        let headerText = try #require(
            doc.hfEvents.first { $0.kind == .header && !$0.text.isEmpty }?.text,
            "POWERUSE.WS should declare at least one non-empty running head")

        let on = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["rtf"], headers: true)
        ).first?.bytes ?? []
        let off = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["rtf"], headers: false)
        ).first?.bytes ?? []

        #expect(String(decoding: on, as: UTF8.self).contains(headerText),
                "headers: true must carry the declared running head into RTF")
        #expect(!String(decoding: off, as: UTF8.self).contains(headerText),
                "headers: false must suppress the declared running head from RTF")
    }

    // MARK: - TOC/Index: a synthetic .tc/.ix fixture (plain dot commands, no binary block needed)

    /// `.tc`/`.ix` are collected but never emitted into body text on their own (`parseCollectDot`
    /// swallows the whole line) — so the compiled entry's text appears in the OUTPUT at all
    /// only when `toc: true` compiles it into the document's own trailing TOC/Index section.
    @Test func tocFlagGatesTheCompiledTableOfContentsAndIndex() throws {
        let bytes = Self.tocFixtureBytes()

        let on = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["text"], toc: true)
        ).first?.bytes ?? []
        let off = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["text"], toc: false)
        ).first?.bytes ?? []

        let onText = String(decoding: on, as: UTF8.self)
        let offText = String(decoding: off, as: UTF8.self)
        #expect(onText.contains("Chapter One"), "toc: true should compile the .tc entry's own text in: \(onText)")
        #expect(onText.contains("Keyword"), "toc: true should compile the .ix entry's own text in: \(onText)")
        #expect(!offText.contains("Chapter One"), "toc: false (the ruled default) must produce no TOC section")
        #expect(!offText.contains("Keyword"), "toc: false (the ruled default) must produce no Index section")
    }

    // MARK: - Pictures: PREVIEW.WS's own real, resolvable .PIX tag (job 371's own fixture)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func picturesFlagGatesWhetherHTMLEmbedsOrLeavesThePlaceholder() throws {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))

        let off = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["html"], docPath: url.path, pictures: .off)
        ).first?.bytes ?? []
        let embed = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["html"], docPath: url.path, pictures: .embed)
        ).first?.bytes ?? []

        let offText = String(decoding: off, as: UTF8.self)
        let embedText = String(decoding: embed, as: UTF8.self)
        #expect(offText.contains("[image:"), "pictures: .off must leave the plain placeholder text: \(offText)")
        #expect(!embedText.contains("[image:"),
                "pictures: .embed must replace the placeholder with a real data URI: \(embedText)")
    }

    // MARK: - Inline styling: a genuinely inline (offset >= 0) font-size change

    @Test func inlineStylingFlagGatesAnAuthoredInlineSizeChangeInRTF() throws {
        let bytes = Self.inlineSizeFixtureBytes()

        let on = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["rtf"], inlineStyling: true)
        ).first?.bytes ?? []
        let off = try DocumentOperations.convert(
            data: bytes, options: .init(formats: ["rtf"], inlineStyling: false)
        ).first?.bytes ?? []

        // The inline block's own declared size (18pt = RTF half-points 36, "\fs36") is the
        // signal: `inlineStyling: true` should carry it into the RTF; `false` must not.
        #expect(String(decoding: on, as: UTF8.self).contains("\\fs36"),
                "inlineStyling: true should carry the authored inline size change into RTF")
        #expect(!String(decoding: off, as: UTF8.self).contains("\\fs36"),
                "inlineStyling: false must suppress the authored inline size change")
    }

    // MARK: - ExportEngine's own path (the Export As sheet), not just DocumentOperations.convert

    @MainActor
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func exportEngineRenderThreadsTheSameFourFlags() throws {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "FlagUIPlumbingTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)

        let off = try ExportEngine.render(
            document: state.document, state: state, formats: [.html], notes: NoteSelection(),
            docPath: url.path, pictures: .off
        ).first?.bytes ?? []
        let embed = try ExportEngine.render(
            document: state.document, state: state, formats: [.html], notes: NoteSelection(),
            docPath: url.path, pictures: .embed
        ).first?.bytes ?? []

        #expect(String(decoding: off, as: UTF8.self).contains("[image:"))
        #expect(!String(decoding: embed, as: UTF8.self).contains("[image:"))
    }

    // MARK: - Fixtures

    private static let HARD: [UInt8] = [0x0d, 0x0a]
    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// One WS5+/WS7 symmetric block — mirrors `ExportPanelFixesTests.ws7Block` exactly (a
    /// `\x1d`, a little-endian 16-bit jump, the command byte, the payload, then the SAME jump
    /// repeated and a closing `\x1d`).
    private static func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let count = UInt16(payload.count + 4)
        let countBytes: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
        var block: [UInt8] = [0x1d]
        block += countBytes
        block += [cmd]
        block += payload
        block += countBytes
        block += [0x1d]
        return block
    }

    /// A detectable ws5+ document (the anchoring `ws7Block(0x00)`, per `ExportPanelFixesTests
    /// .universDocumentBytes`) with a `.tc`/`.ix` line each — plain ASCII dot commands, no
    /// binary block needed (`parseCollectDot`'s own syntax).
    private static func tocFixtureBytes() -> [UInt8] {
        var data = ws7Block(0x00)
        data += bytes("Prose padding for detection, a perfectly ordinary sentence.") + HARD
        data += bytes(".tc Chapter One") + HARD
        data += bytes(".ix Keyword") + HARD
        data += bytes("Closing prose line keeps the byte ratio looking like text.") + HARD
        return data
    }

    /// A genuinely INLINE (mid-text, `offset >= 0`) font-size block — an 18pt WS7 font block
    /// dropped directly into the byte stream rather than riding a style declaration, mirroring
    /// `ExportPanelFixesTests.universDocumentBytes`'s own inline `fontBlock` placement exactly
    /// (that placement is what makes the resulting `FontChange.offset` `>= 0` — "genuinely
    /// inline" per `EmitOptions.inlineStyling`'s own doc comment).
    private static func inlineSizeFixtureBytes() -> [UInt8] {
        let typestyle = 3 | 0x8000  // Courier (mistake-registry's own anchor), proportional bit set
        var payload = le16(180) + le16(Int(18.0 * 20))
        payload += le16(typestyle) + [UInt8](repeating: 0, count: 6)
        let fontBlock = ws7Block(0x02, payload: payload)

        var data = ws7Block(0x00)
        data += bytes("Prose padding for detection, a perfectly ordinary sentence.") + HARD
        data += fontBlock + bytes("Enlarged inline text.") + HARD
        data += bytes("Closing prose line keeps the byte ratio looking like text.") + HARD
        return data
    }
}
