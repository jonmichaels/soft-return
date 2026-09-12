import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 263 (b15, modern-viewer): the Modern on-screen render must present OLDTIMES's own
/// font identity and paragraph structure — title/byline/citation each keeping their own
/// WS5+ face, size, and alignment — rather than one flat body font (Jon's field report).
///
/// The REFERENCE for every assertion here (an engine output, not real WordStar 7) is the
/// engine's own Modern RTF for OLDTIMES.WS
/// (`emitRTF(doc, mode: .modern, options: EmitOptions(fontsTarget: .mac))`), read directly
/// off a probe run against this exact fixture, not invented numbers:
///   `{\qc \s3 {\b\fs28 {\f3\fs36 Just Like Old Times}}\par }`               — title
///   `{\qr \s17 {\f2\fs28 Robert J. Sawyer}\par }`                          — byline
///   `{\qc \s7 {\i \f2\fs24 Winner of the Aurora Award}...}`                — citation
///   `{\ql \s5 {\i \f4\fs24      The transference went smoothly...}`        — body copy
/// `\f2` = Univers -> Helvetica Neue, `\f3` = Aachen -> Rockwell, `\f4` = Courier ->
/// Courier New (the MAC target table, `nativeMacFontRows` in `DocumentRenderer.swift`,
/// mistake-registry #24) — this RTF reference is EMITTED output and stays Courier New
/// forever (`OutputParityTests`, the boundary job 306/312's Courier Prime ruling never
/// crosses). The on-screen Modern VIEW is a separate consumer of the same font-block data
/// and, per Jon's b19 ruling (2026-08-14), now resolves courier-class rows to the bundled
/// Courier Prime instead — see `bodyProseKeepsTheDocumentsOwnCourierNotTheUsersGeorgiaSetting`
/// below, which is the one assertion here where VIEW and RTF-reference font family diverge.
/// `\fs36`/`\fs28`/`\fs24` are half-points: 18/14/12pt.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ModernViewerStyleTests {
    @MainActor
    static func oldtimesModernText() throws -> NSAttributedString {
        // Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
        let dir = PrivateCorpusSupport.ws7Directory
        let bytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("OLDTIMES.WS")))
        let defaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        state.style.setManually(.modern)
        return DocumentRenderer.render(state).text
    }

    /// The paragraph attributes AppKit resolved at the first character of `substring`.
    static func attributes(of substring: String, in text: NSAttributedString) throws
        -> (align: NSTextAlignment, headIndent: CGFloat, font: NSFont)
    {
        let range = try #require((text.string as NSString).range(of: substring).location != NSNotFound
            ? (text.string as NSString).range(of: substring) : nil, "\"\(substring)\" not found in Modern render")
        let attrs = text.attributes(at: range.location, effectiveRange: nil)
        let paragraph = try #require(attrs[.paragraphStyle] as? NSParagraphStyle,
            "\"\(substring)\" carries no paragraph style")
        let font = try #require(attrs[.font] as? NSFont, "\"\(substring)\" carries no font")
        return (paragraph.alignment, paragraph.headIndent, font)
    }

    /// Title: centered, bold, Aachen -> Rockwell at 18pt (`\qc\b\fs36`) — not the user's
    /// body face, and not just character-level bold on the flat body font (job 263's bug).
    @Test @MainActor func titleIsCenteredBoldRockwell18pt() throws {
        let (align, _, font) = try Self.attributes(of: "Just Like Old Times", in: Self.oldtimesModernText())
        #expect(align == .center)
        #expect(font.familyName == "Rockwell", "title font family is \(font.familyName ?? "nil"), expected Rockwell (Aachen mapped via the MAC target)")
        #expect(font.pointSize == 18)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// Byline: right-aligned, Univers -> Helvetica Neue at 14pt (`\qr\fs28`, MS Byline style).
    @Test @MainActor func bylineIsRightAlignedHelveticaNeue14pt() throws {
        let (align, _, font) = try Self.attributes(of: "Robert J. Sawyer", in: Self.oldtimesModernText())
        #expect(align == .right)
        #expect(font.familyName == "Helvetica Neue", "byline font family is \(font.familyName ?? "nil"), expected Helvetica Neue (Univers mapped)")
        #expect(font.pointSize == 14)
    }

    /// Award citation: centered, italic, Univers -> Helvetica Neue at 12pt (`\qc\i\fs24`,
    /// Award Citation style) — `block.styleAttrs`' own italic merged onto the run (Block.swift:
    /// "the style's formatting is not a property of any one span, it applies to the
    /// paragraph"), the same mechanism heading-bold already used.
    @Test @MainActor func citationIsCenteredItalicHelveticaNeue12pt() throws {
        let (align, _, font) = try Self.attributes(of: "Winner of the Aurora Award", in: Self.oldtimesModernText())
        #expect(align == .center)
        #expect(font.familyName == "Helvetica Neue")
        #expect(font.pointSize == 12)
        #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    /// Body copy reconciliation rule (job 263 point 3): OLDTIMES's own "MS Body Copy" style
    /// declares a real WS5+ font run (Courier, `\s5\ri9360\fs24`) — the same font-block the RTF
    /// oracle resolves to Courier New (`\f4`) — so the file's own declared body face wins here
    /// too, exactly as `resolvedFont` already does for Printed. The user's Settings "Modern
    /// font/size" (Georgia 14, the Georgia-14-body ruling — `SettingsStore.swift`'s own doc
    /// comment) only governs spans that carry NO font block at all; it does not override a
    /// document's own declared body font. Left-aligned, unindented — no `.lm`/`.rm` on this
    /// block.
    ///
    /// Font FAMILY (`"Courier Prime"`, not `"Courier New"`): Jon's b19 ruling (2026-08-14,
    /// superseding job 306's Native-only scoping) — the Modern VIEW now renders courier-class
    /// rows in the bundled Courier Prime too, same as Native (`useCourierPrime: true` now
    /// threaded through `renderModern`/`renderModernAnnotated`'s own `attributedLine` calls,
    /// `DocumentRenderer.swift`). This is a VIEW-only change: `OutputParityTests` pins every
    /// EMITTED surface (RTF/HTML/MD/DOCX/CLI/QL text) to Courier New, unchanged — see this
    /// file's header comment.
    @Test @MainActor func bodyProseKeepsTheDocumentsOwnCourierNotTheUsersGeorgiaSetting() throws {
        let (align, headIndent, font) = try Self.attributes(
            of: "The transference went smoothly", in: Self.oldtimesModernText())
        #expect(align == .left)
        #expect(headIndent == 0)
        #expect(font.familyName == "Courier Prime", "body font family is \(font.familyName ?? "nil"), expected Courier Prime (Jon's b19 ruling 2026-08-14: Modern's VIEW now matches Native's bundled Courier Prime for courier-class rows; emitted RTF/HTML/MD/DOCX/CLI/QL-text output stays Courier New per OutputParityTests)")
        #expect(font.pointSize == 12)
    }

    /// The double-indent quote styles (job 263's brief): the Copyright/permissions block
    /// carries `.lm`/`.rm` (`\s14`, `Double-Indented Quote`) — both margins narrow the
    /// measure. Confirms `indentCols`/`cutCols` from `modernSemanticFlow` actually reach
    /// `NSParagraphStyle.headIndent`/`.tailIndent`, not just alignment/font.
    @Test @MainActor func copyrightBlockIsDoubleIndented() throws {
        let (_, headIndent, _) = try Self.attributes(of: "Copyright 1993", in: Self.oldtimesModernText())
        #expect(headIndent > 0, "the Copyright block's own .lm margin never reached NSParagraphStyle")
    }

    /// A genuinely fontless span DOES fall back to the user's own Settings font/size — the
    /// other half of the reconciliation rule, proven against a document this app already
    /// carries with no WS5+ font blocks at all (`doc.fonts.isEmpty`), so every run in it must
    /// take the `resolvedFont` fallback path.
    @Test @MainActor func fontlessDocumentUsesTheUsersModernSettings() throws {
        // Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
        let dir = PrivateCorpusSupport.ws7Directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found = false
        for name in names.filter({ $0.uppercased().hasSuffix(".WS") }) {
            let bytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent(name)))
            let doc = parseWS(bytes)
            guard doc.fonts.isEmpty, !doc.blocks.isEmpty else { continue }
            let defaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
            let settings = SettingsStore(defaults: defaults)
            settings.modernFontName = "Palatino"
            settings.modernFontSize = 16
            let state = try DocumentState(data: bytes, settings: settings)
            state.style.setManually(.modern)
            let text = DocumentRenderer.render(state).text
            guard text.length > 0 else { continue }
            let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.familyName == "Palatino", "\(name): fontless body took \(font.familyName ?? "nil") instead of the user's Settings font")
            #expect(font.pointSize == 16)
            found = true
            break
        }
        #expect(found, "no fontless ws7 fixture found to prove the user-settings fallback")
    }

    /// Jon's ruling, 2026-09-09: a run no font block covers keeps the READER'S face,
    /// unless the document declared its type non-proportional.
    ///
    /// In his words: "A document that declares fonts but does not have a font block AND
    /// doesn't declare font proportionality, is Times in Modern in ctrl-kd and sr, and
    /// Georgia 14 (or whatever is set in Settings). There's a setting in WS where it can
    /// declare that fonts are not proportional. If that's the case, and no font block
    /// exists, then it becomes Courier (or Courier Prime in macOS)."
    ///
    /// This replaces job 437's reading, which asked whether the document declared fonts
    /// ANYWHERE and put every uncovered run into Courier if it did. Measured against the
    /// library's own Modern PDF that was 1182 of the app's remaining distance across the
    /// twelve gate documents — `PDFModernLayout`'s own rule for the same run is "a token
    /// with NO font information reads in Times at the sophisticated size, never Courier".
    ///
    /// Both halves are asserted here, because the rule is a pair. `-README.WS` carries real
    /// WS5+ font blocks that cover only specific spans — "VIEWING THIS FILE" is body prose
    /// outside all of them — and says nothing about proportionality, so it reads in the
    /// reader's own face. A document that says `.ps off` reads in Courier Prime whether or
    /// not it declares fonts, which is what the second half builds directly rather than
    /// borrowing a corpus file for: twelve of the 512 fixtures declare `.ps` and every one
    /// of them turns it off, so a real file cannot show the two halves apart.
    @Test @MainActor func nilFontIndexSpanKeepsTheReadingFaceUnlessTheTypeIsDeclaredFixedPitch() throws {
        // Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
        let dir = PrivateCorpusSupport.ws7Directory
        let url = dir.appendingPathComponent("-README.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let doc = parseWS(bytes)
        try #require(!doc.fonts.isEmpty, "test fixture assumption changed: -README.WS no longer declares any WS5+ font blocks")
        try #require(doc.formatting.proportional == nil,
                     "test fixture assumption changed: -README.WS now declares .ps, which is the other half of this rule")

        let defaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.modernFontName = "Palatino"
        settings.modernFontSize = 16
        let state = try DocumentState(data: bytes, settings: settings, docPath: url.path)
        state.style.setManually(.modern)
        let text = DocumentRenderer.render(state).text

        // `#require`, not `#expect`: reading an attribute at `NSNotFound` throws an
        // NSRangeException, which takes the whole test HOST down rather than failing one
        // test — measured, 2026-09-11, when this needle stopped matching and the run died
        // mid-suite with no result file at all.
        let range = (text.string as NSString).range(of: "VIEWING THIS FILE")
        try #require(range.location != NSNotFound,
                     "expected \"VIEWING THIS FILE\" in -README.WS's Modern render")
        let font = try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Palatino",
                "a run no font block covers, in a document that says nothing about proportionality, must read in the reader's own face, got \(font.familyName ?? "nil")")

        // The other half: `.ps off` and nothing else.
        // Ordinary body prose, not one short line — a document whose only content is a
        // single line reads as a TITLE, and a title takes its face from a different rule.
        let source = Array((".ps off\r\n"
            + "The quick brown fox jumps over the lazy dog, and keeps right on going.\r\n"
            + "A second ordinary line, so this reads as a paragraph rather than a title.\r\n").utf8)
        let fixedDefaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
        let fixedSettings = SettingsStore(defaults: fixedDefaults)
        fixedSettings.modernFontName = "Palatino"
        fixedSettings.modernFontSize = 16
        let fixedDocument = parseWS(source)
        try #require(fixedDocument.formatting.proportional == false,
                     "the synthetic fixture no longer parses as a non-proportional declaration")
        // The document-taking initializer, not the byte one: `detect` reads a hand-built
        // ASCII stream as a print stream rather than a WordStar document, and a print
        // stream has no dot commands to declare anything. The bytes above are still the
        // subject — `parseWS` is the same parse a real file gets — this only skips the
        // format sniffing that a two-line fixture cannot satisfy.
        let fixedState = DocumentState(document: fixedDocument, settings: fixedSettings)
        fixedState.style.setManually(.modern)
        let fixedText = DocumentRenderer.render(fixedState).text
        let fixedRange = (fixedText.string as NSString).range(of: "quick brown fox")
        #expect(fixedRange.location != NSNotFound, "expected the synthetic document's own prose in its Modern render")
        let fixedFont = try #require(
            fixedText.attribute(.font, at: fixedRange.location, effectiveRange: nil) as? NSFont)
        #expect(fixedFont.familyName == "Courier Prime",
                "a document that declares its type non-proportional must read in Courier Prime, got \(fixedFont.familyName ?? "nil")")
    }

    /// Job 437: the other rule half — a fixed-pitch DECLARATION (`.ps` off / a font block
    /// flagged non-proportional) is font information too, and must render Courier Prime in
    /// Modern exactly as it already does in Native/Printed. `FontsInViewsTests
    /// .script103104TypestylesRenderMonospaceInRealRenderPath` already proves the general
    /// `isFixedPitch` verdict for both styles through the shared `resolveFont`/
    /// `nativeMacIsMonospace` short-circuit (job 394); this pins the exact Modern-side
    /// FAMILY name this job's ruling names explicitly, so a future regression that swapped
    /// in some other monospace face (still "fixed pitch", but not the ruled substitute)
    /// would be caught here.
    /// Job 478: footnote/endnote entries in Modern paint with `NSColor.textColor` — dynamic,
    /// black in Light Mode, WHITE in Dark Mode — onto a page whose background is hard-coded
    /// `.white` (`PagedDocumentView.swift:539`, "paper, not a UI surface"), never appearance-
    /// aware. Every prior test here (and every prior fix round, per Jon's field report) ran
    /// under the default Aqua appearance, where `.textColor` resolves to black — indistinguishable
    /// from correct. This test is what those were missing: it resolves the SAME attributed
    /// colour AppKit would actually use to paint, forced under `NSAppearance(named: .darkAqua)`
    /// via `performAsCurrentDrawingAppearance` — the identical mechanism `RenderProbeKit
    /// .resolvedColor` already uses for pixel-truth colour evidence elsewhere in this suite —
    /// and asserts the resolved colour is still dark. Before the fix this fails (white ~=
    /// white paper); after, it passes under BOTH appearances, closing the Light-Mode-only gap
    /// that let the bug ship three times.
    @Test @MainActor func footnoteAndEndnoteEntriesStayDarkOnWhitePaperInBothAppearances() throws {
        // Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
        let dir = PrivateCorpusSupport.ws7Directory
        let url = dir.appendingPathComponent("BOTHNOTE.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state)

        func assertDark(_ color: NSColor, needle: String) throws {
            for (appearanceName, appearance) in [("aqua", NSAppearance(named: .aqua)), ("darkAqua", NSAppearance(named: .darkAqua))] {
                let resolvedAppearance = try #require(appearance, "\(appearanceName) unavailable in this test host")
                var luminance: CGFloat = 1
                resolvedAppearance.performAsCurrentDrawingAppearance {
                    let rgb = (color.usingColorSpace(.sRGB) ?? color)
                    luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                }
                #expect(luminance < 0.5,
                    "\"\(needle)\" resolved to luminance \(luminance) under \(appearanceName) -- must be dark against the always-white Modern page (PagedDocumentView.swift's hard-coded .white background), not white-on-white")
            }
        }

        // The fixture's own synthetic endnote body (TestDocs/ws7/BOTHNOTE.WS, a plain-text
        // string baked in by tools/ws_fixture.py) -- real note TEXT, not the "-----" separator
        // or a numeral label, so this proves the entry itself, not just its punctuation.
        // Endnotes are unchanged by job 502 -- still a real end-of-document appendix inline in
        // `rendered.text` (`renderModern`'s `.note` case, `appendNoteLine`).
        let endnoteNeedle = "An endnote, collected instead"
        let endnoteRange = (rendered.text.string as NSString).range(of: endnoteNeedle)
        #expect(endnoteRange.location != NSNotFound, "expected \"\(endnoteNeedle)\" in BOTHNOTE.WS's Modern render")
        if endnoteRange.location != NSNotFound {
            let color = try #require(
                rendered.text.attribute(.foregroundColor, at: endnoteRange.location, effectiveRange: nil) as? NSColor,
                "\"\(endnoteNeedle)\" carries no foregroundColor")
            try assertDark(color, needle: endnoteNeedle)
        }

        // Job 502: a footnote's own entry no longer lives in `rendered.text` at all -- Jon's
        // ruling moved it to the page FOOT, dash-separated, so `renderModern` now hands it back
        // pre-styled in `modernFootnoteEvents` for `PagedDocumentView` to reserve room for and
        // draw later (see that field's own doc comment). This is the SAME dark-on-white rule
        // job 478 fixed, checked at its new home instead of the old inline one.
        let footnoteNeedle = "A footnote, tied to its own line"
        let footnoteEntry = rendered.modernFootnoteEvents
            .flatMap(\.entries)
            .first { $0.string.contains(footnoteNeedle) }
        let entry = try #require(footnoteEntry, "expected \"\(footnoteNeedle)\" in BOTHNOTE.WS's modernFootnoteEvents")
        let footnoteColor = try #require(
            entry.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            "\"\(footnoteNeedle)\" carries no foregroundColor")
        try assertDark(footnoteColor, needle: footnoteNeedle)
    }

    @Test @MainActor func fixedPitchDeclarationRendersCourierPrimeInModern() throws {
        // Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
        let dir = PrivateCorpusSupport.ws7Directory
        let url = dir.appendingPathComponent("SCRIPT.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ModernViewerStyle.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.modern)
        let text = DocumentRenderer.render(state, style: .modern).text

        let needle = "WRITER'S OFFICE - DAY"
        let range = (text.string as NSString).range(of: needle)
        #expect(range.location != NSNotFound, "expected \"\(needle)\" in SCRIPT.WS's Modern render")
        let font = try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Courier Prime",
                "a fixed-pitch-declared (proportional == false) run must render Courier Prime in Modern, got \(font.familyName ?? "nil")")
    }
}
