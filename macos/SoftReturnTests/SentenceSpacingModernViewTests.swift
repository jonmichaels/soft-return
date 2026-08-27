import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// b34 N1 (job 529, Jon's ruling): the Modern app view must show the SAME N9
/// sentence-spacing collapse Modern's own EXPORT already applies (`SentenceSpacingUITests`
/// covers export, job 521). Before this job, `DocumentRenderer`'s Modern-view text assembly
/// (`modernParagraphContent`, shared by `renderModern`/`renderModernAnnotated`) never called
/// CtrlKD's own `sentenceSpacingSpans`/`sentenceSpacingTexts` at all, so a document with a
/// genuine typewriter double space after a sentence-ending `.`/`?`/`!` rendered doubled on
/// screen while its own Modern export collapsed it to one. Printed/Native stay exactly as
/// typed by design — they never reach `modernParagraphContent`/`modernSemanticFlow` at all
/// (`renderPrinted`'s own "Line-for-line typescript reproduction" doc comment), matching
/// `resolveSentenceSpacing`'s own `.auto` default (single on Modern, keep on Printed).
@Suite struct SentenceSpacingModernViewTests {

    // MARK: - Fixture (duplicated from `SentenceSpacingUITests.doubleSpaceFixtureBytes`,
    // per this codebase's own file-local-fixture convention, that file's own header comment)

    /// A synthetic WS4 document whose body carries a genuine typewriter double space after a
    /// sentence-ending period. The two literal ASCII spaces between "here." and "Second" are
    /// never touched by `highBitWords` (it only ever sets the high bit on a WORD character
    /// immediately before a non-word character, never on a space itself), so they survive
    /// into the parsed document's own span text unchanged.
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
        let defaults = UserDefaults(suiteName: "SentenceSpacingModernViewTests.\(UUID().uuidString)")!
        return try DocumentState(data: doubleSpaceFixtureBytes(), settings: SettingsStore(defaults: defaults))
    }

    // MARK: - Modern collapses, Printed/Native keep as typed

    @Test @MainActor func modernViewCollapsesTheDoubleSpaceToOne() throws {
        let state = try Self.doubleSpaceFixtureState()
        state.style.setManually(.modern)
        let text = DocumentRenderer.render(state).text.string
        #expect(text.contains("First sentence ends here. Second sentence"),
                "Modern's on-screen view must collapse the typed double space to one, matching Modern's own export")
        #expect(!text.contains("here.  Second"), "no double space should survive after the sentence-ending period")
    }

    @Test @MainActor func printedAndNativeViewsKeepTheDoubleSpaceAsTyped() throws {
        let state = try Self.doubleSpaceFixtureState()
        for viewStyle: ViewStyle in [.printed, .native] {
            state.style.setManually(viewStyle)
            let text = DocumentRenderer.render(state).text.string
            #expect(text.contains("here.  Second"),
                    "\(viewStyle) must keep the document exactly as typed, double space included")
        }
    }

    // MARK: - Verse/hard-broken content: the rule is scoped to AFTER a sentence-ender only

    /// A synthetic verse/hard-broken stanza (two short lines joined by a WordStar SOFT return,
    /// `0x8D` — the same `isVerse`-triggering shape `VerseSpacingInViewsTests`'s own
    /// `verseAndProseLineHeights` helper uses) whose own double space sits MID-LINE, between
    /// two ordinary words, never after a `.`/`?`/`!`. `sentenceSpacingTexts`'s own rule
    /// (Block.swift, CtrlKD) only ever collapses a space run that immediately follows a
    /// sentence-ending character — a deliberately narrow, "no cleverness" rule with no verse
    /// exception (the engine's own `PDFModernLayout.swift.modernFlow` applies the SAME
    /// collapse unconditionally to every Modern paragraph, verse included) — so this
    /// stanza-alignment gap, which never matches that pattern, must survive completely
    /// untouched. Proves the fix is scoped to its actual trigger, not "collapse every double
    /// space in Modern."
    @Test @MainActor func verseHardBrokenBlockWithNoSentenceEndingDoubleSpaceStaysUntouched() throws {
        let soft: [UInt8] = [0x8D, 0x0A]
        let hard: [UInt8] = [0x0D, 0x0A]
        let poem = Array("     line one  here --".utf8) + soft + Array("     line two  here --".utf8) + hard
        let defaults = UserDefaults(suiteName: "SentenceSpacingModernViewTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: poem, settings: SettingsStore(defaults: defaults))
        state.style.setManually(.modern)
        let text = DocumentRenderer.render(state).text.string
        #expect(text.contains("one  here"),
                "a verse/hard-broken block's own mid-line double space (not after a sentence-ender) must stay exactly as typed")
        #expect(text.contains("two  here"))
    }
}
