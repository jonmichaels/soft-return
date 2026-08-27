import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 521 (N9, b33 sentence-spacing UI): `ExportEngine.render`'s new `sentenceSpacing`
/// parameter — the "per-export override reaching the engine call" half of the brief's own
/// test list, same shape as `PageNumberingUITests` for job 520's own `pageNumbers` parameter.
///
/// Unlike `pageNumbers`, there is deliberately NO Settings item behind this one (Jon's
/// ruling: export surfaces + AppleScript only) — so unlike `PageNumberingUITests`, this file
/// has no "omitting falls back to Settings' own current default" test; instead it pins that
/// omitting the parameter lands on the plain literal `.auto`.
///
/// `.text` format is used throughout rather than PDF — `EmitOptions.sentenceSpacing`'s own
/// doc comment says this option "applies to body text ... in every format", and unlike a PDF
/// byte comparison, the plain-text emitter's own bytes are directly UTF-8-decodable, so a
/// test can assert on the actual double-space-collapse behavior rather than just "the bytes
/// differ".
@Suite struct SentenceSpacingUITests {

    /// A synthetic WS4 document whose body carries a genuine typewriter double space after a
    /// sentence-ending period — same `highBitWords`-encoded-body shape
    /// `PageNumberingUITests.noDotCommandFixtureBytes` already established (duplicated here
    /// per this codebase's own file-local-fixture convention). The two literal ASCII spaces
    /// between "here." and "Second" are never touched by `highBitWords` (it only ever sets
    /// the high bit on a WORD character immediately before a non-word character, never on a
    /// space itself), so they survive into the parsed document's own span text unchanged.
    private static func doubleSpaceFixtureBytes() -> [UInt8] {
        func highBitWords(_ text: String) -> [UInt8] {
            var out: [UInt8] = []
            let chars = Array(text.unicodeScalars)
            for (index, scalar) in chars.enumerated() {
                var byte = UInt8(scalar.value & 0x7F)
                let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
                let isWordChar = CharacterSet.alphanumerics.contains(scalar)
                let nextIsWordChar = next.map { CharacterSet.alphanumerics.contains($0) } ?? false
                if isWordChar && !nextIsWordChar { byte |= 0x80 }
                out.append(byte)
            }
            return out
        }
        let hard: [UInt8] = [0x0D, 0x0A]
        var doc: [UInt8] = []
        for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12"] {
            doc += Array(dot.utf8) + hard
        }
        doc += highBitWords("First sentence ends here.") + Array("  ".utf8)
            + highBitWords("Second sentence follows for padding so detection thresholds clear safely.") + hard
        doc += [0x1A]
        return doc
    }

    @MainActor
    private static func doubleSpaceFixtureState() throws -> DocumentState {
        let defaults = UserDefaults(suiteName: "SentenceSpacingUITests.\(UUID().uuidString)")!
        return try DocumentState(data: doubleSpaceFixtureBytes(), settings: SettingsStore(defaults: defaults))
    }

    private static func text(_ products: [ExportEngine.Product]) throws -> String {
        String(decoding: try #require(products.first).bytes, as: UTF8.self)
    }

    // MARK: - .auto follows the effective printed-ness

    @Test @MainActor func autoCollapsesTheDoubleSpaceToOneOnModern() throws {
        let state = try Self.doubleSpaceFixtureState()
        let products = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .modern, sentenceSpacing: .auto)
        let text = try Self.text(products)
        #expect(!text.contains("  "), "Modern + auto must collapse the typewriter double space to one")
    }

    @Test @MainActor func autoKeepsTheDoubleSpaceOnPrinted() throws {
        let state = try Self.doubleSpaceFixtureState()
        let products = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .printed, sentenceSpacing: .auto)
        let text = try Self.text(products)
        #expect(text.contains("  "), "Printed + auto must keep the document exactly as authored")
    }

    // MARK: - .keep / .single force the choice regardless of style

    @Test @MainActor func keepPreservesTheDoubleSpaceEvenOnModern() throws {
        let state = try Self.doubleSpaceFixtureState()
        let products = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .modern, sentenceSpacing: .keep)
        let text = try Self.text(products)
        #expect(text.contains("  "), "an explicit keep override must preserve spacing even on Modern")
    }

    @Test @MainActor func singleForcesTheCollapseEvenOnPrinted() throws {
        let state = try Self.doubleSpaceFixtureState()
        let products = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .printed, sentenceSpacing: .single)
        let text = try Self.text(products)
        #expect(!text.contains("  "), "an explicit single override must collapse spacing even on Printed")
    }

    // MARK: - Omitting sentenceSpacing lands on the plain literal .auto (no Settings item)

    /// Unlike `pageNumbers`/`headers`/`toc`/`inlineStyling`/`pictures`, this parameter has NO
    /// Settings-backed default (Jon's ruling) — an omitted call must match an explicit
    /// `.auto`, never whatever `SettingsStore.shared` happens to report (there is no such
    /// property to report).
    @Test @MainActor func omittingSentenceSpacingMatchesAnExplicitAuto() throws {
        let state = try Self.doubleSpaceFixtureState()
        let implicit = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .modern)
        let explicit = try ExportEngine.render(document: state.document, state: state, formats: [.text],
                                               notes: NoteSelection(), style: .modern, sentenceSpacing: .auto)
        #expect(try #require(implicit.first).bytes == (try #require(explicit.first).bytes),
                "an export with sentenceSpacing omitted must match an explicit .auto")
    }
}
