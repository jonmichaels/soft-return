import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 371 item 5 (VERSE SPACING IN VIEWS, RULINGS-LEDGER item 4): Modern's on-screen render
/// tightens a centered/verse-classified paragraph's own internal line spacing — the SAME
/// condition's centered half `EmitRTF`/`EmitHTML` already apply (`isVerse || block.align ==
/// .center`). b24 completion (C1): the non-centered `looksLikeVerse` half is no longer a gap
/// — `modernSemanticFlow`'s own `isVerse` verdict (`SemanticItem.para`, `Layout.swift`) now
/// threads through `modernParagraphContent`.
///
/// Job 395 (391 root cause 4): job 371's ORIGINAL fix applied `NSParagraphStyle.
/// lineHeightMultiple` UNCHANGED from HTML's own 1.15 literal, which reads tight only
/// relative to HTML's own loose ambient — AppKit's baseline has no such ambient, so the
/// same 1.15 made verse render TALLER than prose (Jon's field report: OLDTIMES's award
/// blocks/stanzas "aren't any tighter"). `DocumentRenderer.
/// modernVerseTightLineHeightMultiple`'s own doc comment has the full derivation,
/// including two absolute-geometry alternatives measured and rejected along the way.
/// These tests assert LAWS — direction and magnitude against real laid-out geometry
/// (`NSLayoutManager` line fragment rects), never a bare "does the style property hold
/// some literal" check — exactly the class of test that let the inverted job 371 bug ship
/// green.
@Suite struct VerseSpacingInViewsTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    @MainActor
    private static func modernRender(fixture: String) throws -> NSAttributedString {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "VerseSpacingInViewsTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.modern)
        return DocumentRenderer.render(state, style: .modern).text
    }

    /// b24 completion (C1) — same synthetic fixture shape `VerseSpacingTests.swift`'s own
    /// `rtfVerseUnitGetsPositiveSl`/`htmlVerseUnitGetsTightLineHeight` use in the engine repo:
    /// two short, non-centered lines joined by a soft return (0x8D) so `assembleParagraphUnits`
    /// reads them as one multi-line "run candidate" and `looksLikeVerse` calls it a stanza.
    @MainActor
    private static func modernRender(synthetic wsBytes: [UInt8]) throws -> NSAttributedString {
        let defaults = UserDefaults(suiteName: "VerseSpacingInViewsTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: wsBytes, settings: SettingsStore(defaults: defaults))
        state.style.setManually(.modern)
        return DocumentRenderer.render(state, style: .modern).text
    }

    // MARK: - Real-geometry measurement (never the style property alone)

    /// The full range one `paragraphStyle` VALUE governs around `location` —
    /// `longestEffectiveRange` matches on attribute EQUALITY, not `\n` boundaries, so it
    /// correctly spans a multi-line verse/stanza unit whose internal lines are joined by a
    /// soft return rather than a hard paragraph break (unlike `NSString.paragraphRange`,
    /// which would cut the range at the first embedded `\n` and miss the rest of the unit).
    @MainActor
    private static func paragraphAttributeRange(at location: Int, in text: NSAttributedString) -> NSRange {
        var range = NSRange()
        _ = text.attribute(.paragraphStyle, at: location, longestEffectiveRange: &range,
                            in: NSRange(location: 0, length: text.length))
        return range
    }

    /// Real laid-out line fragment heights (`NSLayoutManager`'s own `usedRect`, not the
    /// `NSParagraphStyle` property) across `range`. `width` defaults to a wide, unbounded
    /// container so no line wraps mid-sentence — a single line fragment's height reflects
    /// that line's font/style geometry regardless of how much text shares it, valid for
    /// both a one-line prose paragraph and a multi-line verse unit alike. Job 437 (b27 item
    /// 10) passes the real Modern measure (468pt, `ModernBoxRowTokenizationTests`/
    /// `UIRound4ARulingTests`' own established literal for Letter-page-size default) when a
    /// test needs to observe an ACTUAL AppKit word-wrap, which the wide default container
    /// deliberately suppresses.
    @MainActor
    private static func lineFragmentHeights(in text: NSAttributedString, range: NSRange, width: CGFloat = 4000) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.ensureLayout(forGlyphRange: glyphRange)
        var heights: [CGFloat] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            heights.append(usedRect.height)
        }
        return heights
    }

    private static func average(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / CGFloat(values.count)
    }

    /// Verse (synthetic, non-centered, isVerse-classified) vs. an ordinary one-line prose
    /// paragraph — SAME render pipeline, SAME default Settings body font/size (Georgia 14,
    /// `SettingsStore.defaultFontName`/`modernFontSize`), so any height difference comes
    /// only from `tight`, not from a font/size mismatch.
    @MainActor
    private static func verseAndProseLineHeights() throws -> (verseAvg: CGFloat, proseAvg: CGFloat) {
        let soft: [UInt8] = [0x8D, 0x0A]
        let hard: [UInt8] = [0x0D, 0x0A]
        let poem = Array("     line one here --".utf8) + soft + Array("     line two here --".utf8) + hard
        let prose = Array("An ordinary sentence of body prose, long enough to form one full line.".utf8) + hard

        let verseText = try Self.modernRender(synthetic: poem)
        let proseText = try Self.modernRender(synthetic: prose)

        let verseFound = (verseText.string as NSString).range(of: "line one here")
        let proseFound = (proseText.string as NSString).range(of: "ordinary sentence")
        #expect(verseFound.location != NSNotFound, "expected the synthetic poem's own text in its Modern render")
        #expect(proseFound.location != NSNotFound, "expected the synthetic prose's own text in its Modern render")

        let verseRange = Self.paragraphAttributeRange(at: verseFound.location, in: verseText)
        let proseRange = Self.paragraphAttributeRange(at: proseFound.location, in: proseText)

        let verseHeights = Self.lineFragmentHeights(in: verseText, range: verseRange)
        let proseHeights = Self.lineFragmentHeights(in: proseText, range: proseRange)
        #expect(!verseHeights.isEmpty, "expected real line fragments for the synthetic verse unit")
        #expect(!proseHeights.isEmpty, "expected real line fragments for the synthetic prose paragraph")

        return (Self.average(verseHeights), Self.average(proseHeights))
    }

    // MARK: - Law 1: DIRECTION

    /// The core regression this job exists for: a verse-classified unit's OWN rendered
    /// lines (real laid-out rects, not the style property) must be SHORTER than an ordinary
    /// prose paragraph's, at the identical font/size. Job 371's inverted fix would fail this
    /// (verse ~15% TALLER).
    @Test @MainActor func verseRendersTighterThanProseSameFontSize() throws {
        let (verseAvg, proseAvg) = try Self.verseAndProseLineHeights()
        #expect(verseAvg < proseAvg,
                "a verse-classified Modern paragraph must render its own lines TIGHTER than an ordinary prose paragraph at the same font/size — got verse \(verseAvg)pt vs prose \(proseAvg)pt")
    }

    // MARK: - Law 2: MAGNITUDE (cross-consumer)

    /// The verse/prose ratio this view actually renders must match the cross-format tight
    /// ratio CtrlKD's own HTML emitter encodes explicitly in two literal constants:
    /// `verseLineHeight`(1.15, `FontMap.swift`) against the body's own ambient
    /// `line-height:1.6` (`htmlCSS`, `EmitHTML.swift`) — 1.15/1.6 = 0.71875, ported
    /// verbatim as `DocumentRenderer.modernVerseTightLineHeightMultiple`. FontMap.swift's
    /// own comment states this is the SAME ratio RTF's `\sl`-derived tightening targets
    /// ("RTF style/reader default is comparably loose" to HTML's 1.6) — the cross-consumer
    /// law this test checks against AppKit's real rendered geometry, not just "some"
    /// directional tightening (Law 1's job).
    @Test @MainActor func verseProseRatioMatchesCrossFormatTightRatio() throws {
        let (verseAvg, proseAvg) = try Self.verseAndProseLineHeights()
        let specRatio = DocumentRenderer.modernVerseTightLineHeightMultiple
        let measuredRatio = verseAvg / proseAvg
        #expect(abs(measuredRatio - specRatio) < 0.05,
                "the verse/prose line-height ratio actually rendered (\(measuredRatio)) must match CtrlKD's own cross-format tight ratio (\(specRatio) = verseLineHeight(1.15)/htmlAmbient(1.6))")
    }

    // MARK: - Law 3: OLDTIMES fixture (award block + poem stanza + centered regression guard)

    /// Sawyer's OLDTIMES.WS carries two real, non-synthetic tight cases: the "Winner of the
    /// Aurora Award" citation block (centered — the b24-shipped case job 371 already
    /// covered) and the Mikado poem-stanza quote ("My object all sublime...", `.cp4` in the
    /// source, a non-centered multi-line verse unit — job 391's own reported symptom).
    /// Both must measure tighter than the story's own body-prose baseline, and the
    /// already-shipped centered case must not have its own direction flipped by this fix.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func oldtimesAwardAndPoemStanzaBothTightenBelowBodyBaseline() throws {
        let text = try Self.modernRender(fixture: "OLDTIMES.WS")
        let ns = text.string as NSString

        func measure(near substring: String) throws -> (heights: [CGFloat], style: NSParagraphStyle) {
            let found = ns.range(of: substring)
            #expect(found.location != NSNotFound,
                    "expected to find \"\(substring)\" in OLDTIMES.WS's Modern render")
            let paraRange = Self.paragraphAttributeRange(at: found.location, in: text)
            let style = text.attribute(.paragraphStyle, at: found.location, effectiveRange: nil) as! NSParagraphStyle
            return (Self.lineFragmentHeights(in: text, range: paraRange), style)
        }

        let award = try measure(near: "Winner of the Aurora Award")
        let poem = try measure(near: "object all sublime")
        let body = try measure(near: "transference went smoothly")

        let awardAvg = Self.average(award.heights)
        let poemAvg = Self.average(poem.heights)
        let bodyAvg = Self.average(body.heights)

        #expect(!award.heights.isEmpty, "expected real line fragments for the award-citation block")
        #expect(!poem.heights.isEmpty, "expected real line fragments for the Mikado poem stanza")
        #expect(!body.heights.isEmpty, "expected real line fragments for the body-prose baseline")

        #expect(awardAvg < bodyAvg,
                "OLDTIMES's award-citation block must render tighter than the body baseline, got award \(awardAvg)pt vs body \(bodyAvg)pt")
        #expect(poemAvg < bodyAvg,
                "OLDTIMES's Mikado poem-stanza quote must render tighter than the body baseline, got poem \(poemAvg)pt vs body \(bodyAvg)pt")

        // Regression guard: the award block is the b24-shipped CENTERED case — job 395 must
        // not flip its own direction while fixing the non-centered verse half.
        #expect(award.style.alignment == .center,
                "the award-citation block is expected to remain a centered Modern paragraph")
    }

    // MARK: - Law 4: WRAPPED CONTINUATION LINES (job 437, b27 item 10)

    /// Jon's ruling is broader than the original verse-classification bug: no paragraph
    /// class may render a SOFT-WRAPPED CONTINUATION line at sub-normal leading — tight
    /// spacing, where legitimate at all, belongs strictly BETWEEN hard-returned lines.
    /// POWERUSE.WS's own TTO #2 caption is the field-reported repro: its source joins
    /// several short print lines with WordStar soft returns (`0x8D`), so
    /// `modernSemanticFlow` reflows them into ONE long verse-classified paragraph that then
    /// genuinely word-wraps in Modern's own proportional body font — exactly the case
    /// `renderModern`'s old, unconditional `tight` application over-compressed (Jon's field
    /// report: "the wrapped continuation lines under the TTO number 2 and number 3
    /// captions are too tight").
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func verseParagraphWrapKeepsNormalLeadingOnContinuationLines() throws {
        let text = try Self.modernRender(fixture: "POWERUSE.WS")
        let ns = text.string as NSString

        let captionFound = ns.range(of: "This technique is documented")
        #expect(captionFound.location != NSNotFound,
                "expected TTO #2's reflowed caption text in POWERUSE.WS's Modern render")
        let bodyFound = ns.range(of: "With the release of updated versions")
        #expect(bodyFound.location != NSNotFound,
                "expected the article's own opening body-prose paragraph in POWERUSE.WS's Modern render")

        let captionRange = Self.paragraphAttributeRange(at: captionFound.location, in: text)
        let bodyRange = Self.paragraphAttributeRange(at: bodyFound.location, in: text)
        let captionHeights = Self.lineFragmentHeights(in: text, range: captionRange, width: 468)
        let bodyHeights = Self.lineFragmentHeights(in: text, range: bodyRange, width: 468)

        // Guard the test itself against going vacuous: if either paragraph stopped
        // wrapping (a future width/font default change), this isn't exercising the
        // continuation-line case at all, and a silent pass would be worthless.
        #expect(captionHeights.count > 1,
                "expected TTO #2's caption to actually word-wrap in Modern")
        #expect(bodyHeights.count > 1,
                "expected the opening body-prose paragraph to word-wrap in Modern, as the normal-leading baseline")

        let bodyAvg = Self.average(bodyHeights)
        for height in captionHeights {
            #expect(abs(height - bodyAvg) < 0.5,
                    "every line fragment of a wrapped verse paragraph must render at normal body leading (matching an ordinary wrapped prose paragraph), got \(height)pt vs body baseline \(bodyAvg)pt")
        }
    }

    /// Regression guard, same fixture: TTO #1's caption ("`WordStar 4 has the annoying
    /// habit of spliting equations over two lines.`") is short enough that it does NOT
    /// wrap — a genuine hard-returned-only verse paragraph — and job 437's fix must leave
    /// THAT case exactly as job 395 left it: still tightened below the body baseline.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func nonWrappingVerseParagraphStaysTight() throws {
        let text = try Self.modernRender(fixture: "POWERUSE.WS")
        let ns = text.string as NSString

        let captionFound = ns.range(of: "WordStar 4 has the")
        #expect(captionFound.location != NSNotFound,
                "expected TTO #1's caption text in POWERUSE.WS's Modern render")
        let bodyFound = ns.range(of: "With the release of updated versions")
        #expect(bodyFound.location != NSNotFound,
                "expected the article's own opening body-prose paragraph in POWERUSE.WS's Modern render")

        let captionRange = Self.paragraphAttributeRange(at: captionFound.location, in: text)
        let bodyRange = Self.paragraphAttributeRange(at: bodyFound.location, in: text)
        let captionHeights = Self.lineFragmentHeights(in: text, range: captionRange, width: 468)
        let bodyHeights = Self.lineFragmentHeights(in: text, range: bodyRange, width: 468)

        #expect(captionHeights.count == 1,
                "expected TTO #1's caption to stay on ONE line fragment in Modern -- otherwise this isn't testing the non-wrapping case")
        let captionAvg = Self.average(captionHeights)
        let bodyAvg = Self.average(bodyHeights)
        #expect(captionAvg < bodyAvg,
                "a non-wrapping verse-classified paragraph must still render tighter than body prose, got caption \(captionAvg)pt vs body \(bodyAvg)pt")
    }

    // MARK: - Style-property guards (cheap, direct — the property job 395 actually sets)

    @Test @MainActor func nonCenteredVerseStanzaMultipliesToVerseTightLineHeight() throws {
        let soft: [UInt8] = [0x8D, 0x0A]
        let hard: [UInt8] = [0x0D, 0x0A]
        let poem = Array("     line one --".utf8) + soft + Array("     line two --".utf8) + hard
        let text = try Self.modernRender(synthetic: poem)
        var foundLeft = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle, style.alignment == .left else { return }
            foundLeft = true
            #expect(style.lineHeightMultiple == DocumentRenderer.modernVerseTightLineHeightMultiple,
                    "a non-centered verse-classified Modern paragraph must use the tight verse line height multiple, got \(style.lineHeightMultiple)")
            stop.pointee = true
        }
        #expect(foundLeft, "the synthetic poem should render as a left-aligned Modern paragraph")
    }

    /// STRENGTH.WS's own title/byline/email block — `modernParagraphContent`'s own doc
    /// comment names it directly as undeclared (spaces-padded) centered content.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func centeredParagraphMultipliesToVerseTightLineHeight() throws {
        let text = try Self.modernRender(fixture: "STRENGTH.WS")
        var foundCentered = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle, style.alignment == .center else { return }
            foundCentered = true
            #expect(style.lineHeightMultiple == DocumentRenderer.modernVerseTightLineHeightMultiple,
                    "a centered Modern paragraph must use the tight verse line height multiple, got \(style.lineHeightMultiple)")
            stop.pointee = true
        }
        #expect(foundCentered, "STRENGTH.WS should render at least one centered paragraph in Modern")
    }

    /// Regression guard: an ordinary LEFT-aligned paragraph must keep the reading view's
    /// normal (untightened, no multiplier at all) spacing — `tight` must never leak onto
    /// plain prose.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func ordinaryLeftAlignedParagraphKeepsNormalSpacing() throws {
        let text = try Self.modernRender(fixture: "OLDTIMES.WS")
        var foundLeft = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle, style.alignment == .left else { return }
            foundLeft = true
            #expect(style.lineHeightMultiple == 0,
                    "an ordinary left-aligned Modern paragraph must NOT be tightened, got \(style.lineHeightMultiple)")
            stop.pointee = true
        }
        #expect(foundLeft, "OLDTIMES.WS should render at least one ordinary left-aligned paragraph in Modern")
    }
}
