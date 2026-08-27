import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 439 (b27 item 6): live-runtime coverage for the Modern footnote/endnote/comment
/// appendix, replacing job 423's own static-string-only check
/// (`SampleDocumentsTests.lyingWSBundledFootnoteReachesDocumentInfoAndThePrintedPage`,
/// `modern.text.string.contains(...)`) with an assertion against the REAL, laid-out
/// `PagedDocumentView` — the thing AppKit actually places, which is what a person looking
/// at the screen actually sees. Jon reported the appendix MISSING on `-SCREEN.WS`; a live
/// instrumented repro (this job) found the render layer innocent: `modernSemanticFlow`
/// DOES emit `.noteSeparator`/`.note` items for both fixtures below, `DocumentRenderer
/// .render(_:style:.modern)`'s own static string DOES carry the note text, and
/// `PagedDocumentView`'s real `NSLayoutManager` DOES place every glyph of it — confirmed by
/// summing each container's own `characterRange(forGlyphRange:)`, not by reading the shared
/// `NSTextStorage` (which is identical across every container and proves nothing about
/// which PAGE actually holds a given character). `-SCREEN.WS`'s own image (absent from
/// `BOTHNOTE.WS`, the isolation control) pushes the whole document to 2 Modern pages, and
/// the entire note appendix lands on page 2 — `PagedDocumentView`'s own `display` defaults
/// to `.singlePage` (`SettingsStore.swift:40`) with NO on-screen page-count affordance for a
/// sighted user (`DocumentWindowController+Actions.swift`'s `pageTotal`/`currentPage` only
/// ever feed menu-item enablement and the "Go to Page" dialog's own placeholder text — no
/// visible label anywhere carries it; only `PagedDocumentView.applyPageAccessibilityLabels`'s
/// "Page N of M" exists, and that is VoiceOver-only). That is a real, live, reproducible bug
/// — but a DIFFERENT one than "the render drops the appendix," and a broader one (any
/// Modern document that overflows one page is equally invisible past page 1) than this job's
/// own brief scoped to notes specifically — reported, not fixed here, per this round's own
/// scope-discipline rule ("if the brief turns out to be wrong about a root cause, STOP and
/// report rather than improvising a workaround").
///
/// These tests assert the render/layout layer is innocent (regression coverage that would
/// have caught a REAL drop, which job 423's static check could not).
///
/// Job 450 (b27) REVERTED this job's own marker fix: `wordStandardLabel`/`wordStandardRuns`
/// (`DocumentRenderer.swift`) substituted Native/Printed's plain-arabic endnote label into
/// Modern, believing it matched a b26 intake ruling. It did not — Jon ruled on 2026-08-20,
/// having already weighed the paper evidence, that Modern KEEPS the Word-standard lowercase-
/// roman endnote convention (a real, cited Word-OOXML convention — MS-OI29500 §17.11.17, "In
/// Word, the default value for endnote numbering format is lowerRoman"): "Since the point is
/// to be Modern, I think we should keep it at the Word standard we are using. For now." The
/// marker tests below are inverted accordingly: Modern's endnote marker asserts lowercase
/// roman ("An endnote: i" / "i. Endnote"), footnotes are unaffected and stay arabic.
/// Doctrine going forward: paper scans adjudicate Native/Printed; Modern diverges from paper
/// BY DESIGN to match Word/modern conventions — never cite a scan against Modern.
///
/// b28 note 7 (Jon's ruling): the appendix entry's own bracket convention (`"[i] Endnote"`,
/// `"[1] Footnote"`) is GONE — `"i. Endnote"` / `"1. Footnote"`, no brackets, no superscript
/// on the label. The literal strings this file asserts on were updated accordingly; the
/// roman-vs-arabic and footnote-precedes-endnote DECISIONS this file otherwise pins are
/// unchanged.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job439ModernAppendixLiveTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    @MainActor
    private static func state(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job439ModernAppendixLive.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// Modern, laid out for real through `PagedDocumentView` — same construction
    /// `HeadersInViewsTests.pagedModernView` uses.
    @MainActor
    private static func pagedModernView(for state: DocumentState) -> (view: PagedDocumentView, rendered: RenderedDocument) {
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        return (view, rendered)
    }

    /// The text AppKit ACTUALLY placed, concatenated across every real container in
    /// document order — unlike `pageViews[i].textStorage.string` (the SAME shared storage
    /// for every page, proving nothing), `characterRange(forGlyphRange:)` per container is
    /// the real "what's on this page" answer, the one a live repro needs.
    @MainActor
    private static func reallyPlacedText(_ view: PagedDocumentView, rendered: RenderedDocument) -> String {
        guard let lm = view.primaryTextView?.layoutManager else { return "" }
        let ns = rendered.text.string as NSString
        var out = ""
        for container in view.pageViews.map(\.textContainer) {
            guard let container else { continue }
            let glyphRange = lm.glyphRange(for: container)
            let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location != NSNotFound, charRange.length > 0 else { continue }
            out += ns.substring(with: charRange)
        }
        return out
    }

    // MARK: - Appendix reaches the real, laid-out screen (both fixtures)

    @Test @MainActor func screenWSAppendixReachesRealAppKitLayout() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let placed = Self.reallyPlacedText(view, rendered: rendered)

        // Job 502: a footnote's own text no longer joins the flat flow `reallyPlacedText`
        // reads at all — it lands in `PagedDocumentView`'s own per-page `footnoteBlock`
        // instead (see that accessor's own doc comment). Endnotes are unaffected.
        let footnoteReached = (0..<view.pageCount).contains {
            view.footnoteBlock(atPageIndex: $0).contains { $0.string.contains("Footnote") }
        }
        #expect(footnoteReached, "-SCREEN.WS's footnote text must reach a REAL laid-out Modern page's own foot")
        #expect(placed.contains("Endnote"), "-SCREEN.WS's endnote text must reach a REAL laid-out Modern page")
        #expect(view.pageCount == 2,
                "-SCREEN.WS's own image pushes Modern to 2 AppKit pages (unlike BOTHNOTE.WS's 1) — the difference this job's own brief asked to be reported, pinned as a regression guard")
    }

    /// Job 490 item 1 (Jon's field report, `LYING.WS`: marker on page 1, note lands on page
    /// 4): the footnote's own text must land on the SAME real AppKit page as the paragraph
    /// carrying its marker, not wherever the old end-of-document appendix happened to fall.
    /// `LYING.WS` carries no endnote/annotation/comment (`endRows` empty,
    /// `Layout.swift`'s own citation), so before job 490 `renderModern`'s footnote-only
    /// fallback pass appended the note at the absolute end of `output` regardless of where
    /// the marker's own paragraph — near the START of this multi-page essay — landed.
    ///
    /// Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like Printed)
    /// changed WHERE on that page the footnote draws — no longer inline right after the
    /// marker's paragraph, now reserved space at the bottom of that SAME page instead — but
    /// left this test's own invariant (same PAGE as the marker) unchanged; only the
    /// MECHANISM for finding the footnote's own page moved, from a text search over
    /// `rendered.text` (the footnote no longer lives there — `ModernFootnoteEvent`'s own doc
    /// comment) to `PagedDocumentView.footnoteBlock(atPageIndex:)`, this job's own accessor
    /// onto the view's real per-page resolution.
    @Test @MainActor func lyingWSFootnoteLandsOnTheSameRealPageAsItsMarker() throws {
        let state = try Self.state(fixture: "LYING.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let lm = try #require(view.primaryTextView?.layoutManager)
        let containers = view.pageViews.compactMap(\.textContainer)

        func realPage(containing needle: String) throws -> Int {
            let range = try #require(rendered.text.string.range(of: needle),
                                      "\"\(needle)\" not found in the rendered Modern text at all")
            let location = NSRange(range, in: rendered.text.string).location
            for (index, container) in containers.enumerated() {
                let glyphRange = lm.glyphRange(for: container)
                let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                if NSLocationInRange(location, charRange) { return index }
            }
            Issue.record("\"\(needle)\" at offset \(location) was not placed on any real AppKit page")
            return -1
        }
        func realFootnotePage(containing needle: String) -> Int {
            for index in 0..<view.pageCount
            where view.footnoteBlock(atPageIndex: index).contains(where: { $0.string.contains(needle) }) {
                return index
            }
            Issue.record("\"\(needle)\" was not in any real page's own footnote block")
            return -1
        }

        // "Thirty-Dollar Prize" sits in the essay's own subtitle line, immediately before
        // the footnote's own reference mark — the marker's real paragraph.
        let markerPage = try realPage(containing: "Thirty-Dollar Prize")
        // The footnote's own body text, now read from its real page-foot block rather than
        // the flat flow.
        let notePage = realFootnotePage(containing: "Did not take the prize")

        #expect(view.pageCount > 1,
                "LYING.WS must span multiple real Modern pages for this regression to be meaningful")
        #expect(markerPage == notePage,
                "the footnote text (real page \(notePage)) must land on the SAME real page as its marker (real page \(markerPage))")
    }

    @Test @MainActor func bothnoteWSAppendixReachesRealAppKitLayout() throws {
        let state = try Self.state(fixture: "BOTHNOTE.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let placed = Self.reallyPlacedText(view, rendered: rendered)

        // Job 502: same redirect as `screenWSAppendixReachesRealAppKitLayout` above — the
        // footnote's own text now lands in a real page's own `footnoteBlock`, not the flat
        // flow.
        let footnoteReached = (0..<view.pageCount).contains {
            view.footnoteBlock(atPageIndex: $0).contains { $0.string.contains("A footnote, tied to its own line") }
        }
        #expect(footnoteReached, "BOTHNOTE.WS's footnote text must reach a REAL laid-out Modern page's own foot")
        #expect(placed.contains("An endnote, collected instead"),
                "BOTHNOTE.WS's endnote text must reach a REAL laid-out Modern page")
        #expect(view.pageCount == 1,
                "BOTHNOTE.WS (no image, the isolation control) fits on ONE Modern page — the appendix is on the same page as the body, unlike -SCREEN.WS")
    }

    // MARK: - Word-standard endnote marker (lowercase roman) — job 439's fix REVERTED by
    // job 450 per Jon's 2026-08-20 ruling ("Since the point is to be Modern, I think we
    // should keep it at the Word standard we are using. For now.") and MS-OI29500 §17.11.17
    // ("In Word, the default value for endnote numbering format is lowerRoman").

    @Test @MainActor func screenWSEndnoteMarkerIsWordStandardRomanNotArabic() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let modern = DocumentRenderer.render(state, style: .modern).text.string
        #expect(modern.contains("An endnote: i"),
                "Modern's inline endnote reference must read \"i\" (Word-standard lowerRoman, MS-OI29500 §17.11.17), not arabic \"1\"")
        #expect(!modern.contains("An endnote: 1"), "the arabic endnote marker must not appear in Modern")
        #expect(modern.contains("i. Endnote"), "the Modern appendix's own endnote entry must carry the roman label (b28 note 7: no brackets)")
        #expect(!modern.contains("1. Endnote"), "the Modern appendix must not carry the arabic label")
        #expect(!modern.contains("[i] Endnote"), "the bracket convention must be gone (b28 note 7)")

        // Native/Printed are unaffected by this revert — regression guard, always arabic.
        let printed = DocumentRenderer.render(state, style: .printed).text.string
        #expect(printed.contains("An endnote: 1"), "Printed's own inline endnote reference (ground truth)")
        #expect(printed.contains("(1)  Endnote"), "Printed's own trailing endnote entry (paper ground truth, m479-scan-doc87.pdf p6)")
    }

    @Test @MainActor func screenWSEndnoteMarkerIsWordStandardWithInvisiblesOn() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let annotated = DocumentRenderer.renderWithInvisibles(state).text.string
        #expect(annotated.contains("An endnote: i"),
                "Show Invisibles ON must show the SAME word-standard marker as OFF (job 300's own ruling)")
        #expect(!annotated.contains("An endnote: 1"))
        #expect(annotated.contains("i. Endnote"))
        #expect(!annotated.contains("1. Endnote"))
        #expect(!annotated.contains("[i] Endnote"))
    }

    @Test @MainActor func bothnoteWSEndnoteMarkerIsWordStandardRomanNotArabic() throws {
        let state = try Self.state(fixture: "BOTHNOTE.WS")
        state.style.setManually(.modern)
        let modern = DocumentRenderer.render(state, style: .modern).text.string
        #expect(modern.contains("i. An endnote, collected instead"),
                "BOTHNOTE.WS's Modern appendix endnote entry must carry the roman label (b28 note 7: no brackets)")
        #expect(!modern.contains("1. An endnote, collected instead"))
        #expect(!modern.contains("[i] An endnote, collected instead"))
    }

    // MARK: - Footnote label is unaffected (was already arabic; regression guard only)

    @Test @MainActor func footnoteMarkerUnaffectedByTheEndnoteFix() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        #expect(modern.contains("A footnote: 1"))
        // Job 502: the appendix entry itself ("1. Footnote") no longer joins `modern` at
        // all — it lives in `modernFootnoteEvents` instead (`ModernFootnoteEvent`'s own doc
        // comment), pre-styled for its page-foot block.
        #expect(rendered.modernFootnoteEvents.flatMap(\.entries).contains { $0.string.contains("1. Footnote") })
        #expect(!modern.contains("[1] Footnote"))
    }

    // MARK: - Job 452: the Modern appendix must list Footnotes before Endnotes
    //
    // The engine's own section order (`noteKindOrder` in `EmitNotes.swift`:
    // `[.footnote, .endnote, .annotation, .comment]`, the same array `EmitText`'s headed
    // "Footnotes:"/"Endnotes:" sections walk) puts footnotes first. The app's Modern
    // appendix has no headings (WordStar never printed one — the `.noteSeparator` case's own
    // citation), so "order" here means the footnote LINES must precede the endnote LINES
    // under that one shared separator, not that a heading needs to appear.
    //
    // Root cause: `modernSemanticFlow` (`Layout.swift`) folds endnotes/annotations/comments
    // straight into `items` as trailing `.noteSeparator`/`.note` entries (via `endRows`), but
    // deliberately keeps footnote TEXT out of `items` entirely (`SemanticItem.para`'s
    // `footnotes:` field is only an anchor — see `renderModern`'s own citation on why).
    // `DocumentRenderer.renderModern`/`.renderModernAnnotated` used to always finish
    // rendering the `.noteSeparator`/`.note` items INSIDE the main loop, then append
    // footnotes in a SEPARATE pass after the whole loop finished — correct only when there
    // is no endnote/annotation/comment appendix for that separate pass to land after. This
    // was a deterministic reversal (`endRows` is built in stable document-reference order,
    // not a Set/Dictionary), not a randomized/unstable order — but reversed regardless.
    // Fixed by emitting footnotes at the `.noteSeparator` item itself, ahead of the `.note`
    // items that immediately follow it in the same flow.

    /// Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like Printed):
    /// this test used to assert footnote-before-endnote ORDER inside one shared end-of-
    /// document appendix string. That premise is gone in the PLAIN Modern path — a
    /// footnote's own entry no longer joins `modern` at all (`renderModern`'s `.para` case
    /// hands it to `modernFootnoteEvents` instead), so there is no longer a shared order to
    /// violate or preserve there. Reworded to what is actually still true: the footnote
    /// entry is ABSENT from `modern` (it now lives at its own page's foot), the endnote
    /// entry is UNCHANGED (still a real end-of-document appendix line), and the footnote
    /// text is exactly where job 502 put it. Show Invisibles' own Modern path
    /// (`WithInvisiblesOn`, below) is OUT OF SCOPE for job 502 (never ported job 490's per-
    /// marker placement either — `RenderedDocument.modernFootnoteEvents`'s own doc comment)
    /// and keeps the original footnote-precedes-endnote assertion unmodified.
    @Test @MainActor func screenWSFootnoteMovesToItsPageFootInsteadOfPrecedingEndnotesInModern() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        #expect(!modern.contains("1. Footnote"),
                "job 502: the footnote entry must no longer join the flat Modern flow at all")
        #expect(modern.contains("i. Endnote"),
                "the endnote entry is unaffected by job 502 and stays a real end-of-document appendix line")
        #expect(rendered.modernFootnoteEvents.flatMap(\.entries).contains { $0.string.contains("1. Footnote") },
                "the footnote entry must instead be present in modernFootnoteEvents, pre-styled for its page-foot block")
    }

    @Test @MainActor func bothnoteWSFootnoteMovesToItsPageFootInsteadOfPrecedingEndnotesInModern() throws {
        let state = try Self.state(fixture: "BOTHNOTE.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        #expect(!modern.contains("1. A footnote, tied to its own line"),
                "job 502: the footnote entry must no longer join the flat Modern flow at all")
        #expect(modern.contains("i. An endnote, collected instead"),
                "the endnote entry is unaffected by job 502 and stays a real end-of-document appendix line")
        #expect(rendered.modernFootnoteEvents.flatMap(\.entries)
                    .contains { $0.string.contains("1. A footnote, tied to its own line") },
                "the footnote entry must instead be present in modernFootnoteEvents, pre-styled for its page-foot block")
    }

    @Test @MainActor func screenWSFootnotesPrecedeEndnotesInModernWithInvisiblesOn() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let annotated = DocumentRenderer.renderWithInvisibles(state).text.string
        let footnoteRange = try #require(annotated.range(of: "1. Footnote"))
        let endnoteRange = try #require(annotated.range(of: "i. Endnote"))
        #expect(footnoteRange.lowerBound < endnoteRange.lowerBound,
                "Show Invisibles ON must show the SAME order as OFF (job 300's own ruling)")
    }

    @Test @MainActor func bothnoteWSFootnotesPrecedeEndnotesInModernWithInvisiblesOn() throws {
        let state = try Self.state(fixture: "BOTHNOTE.WS")
        state.style.setManually(.modern)
        let annotated = DocumentRenderer.renderWithInvisibles(state).text.string
        let footnoteRange = try #require(annotated.range(of: "1. A footnote, tied to its own line"))
        let endnoteRange = try #require(annotated.range(of: "i. An endnote, collected instead"))
        #expect(footnoteRange.lowerBound < endnoteRange.lowerBound,
                "Show Invisibles ON must show the SAME order as OFF (job 300's own ruling)")
    }

    // Markers stay exactly as job 439/450 left them (roman endnote, arabic footnote) — this
    // is the SECOND time this appendix has been touched; a future job flipping the marker
    // back would now trip both this test and job 439's own marker tests above.
    @Test @MainActor func screenWSMarkersUnaffectedByTheOrderFix() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        #expect(modern.contains("An endnote: i"), "endnote marker stays lowercase roman")
        #expect(modern.contains("i. Endnote"), "endnote appendix label stays lowercase roman")
        #expect(modern.contains("A footnote: 1"), "footnote marker stays arabic")
        // Job 502: the footnote appendix label lives in `modernFootnoteEvents` now, not `modern`.
        #expect(rendered.modernFootnoteEvents.flatMap(\.entries).contains { $0.string.contains("1. Footnote") },
                "footnote appendix label stays arabic")
        #expect(!modern.contains("An endnote: 1"))
        #expect(!modern.contains("1. Endnote"))
        #expect(!modern.contains("1. Footnote"), "job 502: the footnote label must not also linger in the flat flow")
    }

    @Test @MainActor func bothnoteWSMarkersUnaffectedByTheOrderFix() throws {
        let state = try Self.state(fixture: "BOTHNOTE.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        #expect(modern.contains("i. An endnote, collected instead"), "endnote appendix label stays lowercase roman")
        // Job 502: same redirect as `screenWSMarkersUnaffectedByTheOrderFix` above.
        #expect(rendered.modernFootnoteEvents.flatMap(\.entries)
                    .contains { $0.string.contains("1. A footnote, tied to its own line") },
                "footnote appendix label stays arabic")
        #expect(!modern.contains("1. An endnote, collected instead"))
        #expect(!modern.contains("1. A footnote, tied to its own line"),
                "job 502: the footnote label must not also linger in the flat flow")
    }

    // MARK: - b28 note 7 (Jon's ruling): brackets are gone, entry label carries no superscript,
    // the in-text reference marker is untouched (still superscript, still arabic/roman).
    //
    // This codebase has no `.superscript` NSAttributedString key at all (`attributedLine`'s
    // own citation at its `.sup`/`.sub` branch): a superscripted run is a SCALED-DOWN font
    // (`scriptMetrics`: 2/3 point size) plus a raising `.baselineOffset` — so "no superscript
    // on the label" means the appendix entry's own font/offset, and "still superscript" for
    // the in-text marker means THAT run's font is smaller than the surrounding body text with
    // a non-zero `.baselineOffset`.

    @Test @MainActor func screenWSAppendixEntriesCarryNoBracketsAndNoSuperscriptOnTheLabel() throws {
        let state = try Self.state(fixture: "-SCREEN.WS")
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let modern = rendered.text.string
        // Job 502: the footnote entry lives in `modernFootnoteEvents` now (`noteLineAttributedString`,
        // the SAME styling helper `appendNoteLine`'s endnote entry below still shares) — see
        // `ModernFootnoteEvent`'s own doc comment.
        let footnoteEntry = try #require(
            rendered.modernFootnoteEvents.flatMap(\.entries).first { $0.string.contains("1. Footnote") },
            "footnote entry: arabic label, period, space, text — no brackets")
        #expect(modern.contains("i. Endnote"), "endnote entry: roman label, period, space, text — no brackets")
        #expect(!footnoteEntry.string.contains("[1]"), "no bracketed footnote label anywhere in its own entry")
        #expect(!modern.contains("[i]"), "no bracketed endnote label anywhere in the Modern appendix")
        #expect(!modern.contains("[1]"), "no bracketed footnote label lingering in the flat flow either")

        // The appendix entry (`noteLineAttributedString`) is built as ONE run with a single,
        // plain note-paragraph font/attributes dictionary — its own label character carries
        // no baseline offset at all.
        let footnoteLabelAttrs = footnoteEntry.attributes(at: 0, effectiveRange: nil)
        #expect(footnoteLabelAttrs[.baselineOffset] == nil,
                "the appendix entry's own label must carry no raising baseline offset (no superscript)")

        // The in-text reference marker is a SEPARATE run (`"A footnote: 1"`) — untouched by
        // this fix. It must still be smaller and raised relative to the surrounding body text.
        let markerRange = try #require(modern.range(of: "A footnote: 1"))
        let markerNSRange = NSRange(markerRange, in: modern)
        let markerDigitLoc = markerNSRange.location + markerNSRange.length - 1
        let markerAttrs = rendered.text.attributes(at: markerDigitLoc, effectiveRange: nil)
        let markerFont = try #require(markerAttrs[.font] as? NSFont)
        let bodyFont = try #require(
            rendered.text.attributes(at: markerNSRange.location, effectiveRange: nil)[.font] as? NSFont)
        #expect(markerFont.pointSize < bodyFont.pointSize,
                "the in-text footnote reference marker must still render at a scaled-down size (b28 note 7: unchanged)")
        let offset = try #require(markerAttrs[.baselineOffset] as? NSNumber)
        #expect(offset.doubleValue > 0, "the in-text footnote reference marker must still be raised above the baseline")
    }
}
