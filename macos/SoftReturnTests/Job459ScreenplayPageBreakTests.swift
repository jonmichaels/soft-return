import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 459 — b28 note 11 (Jon's ruling): SCRIPT.WS's Modern view shows proper screenplay
/// layout (job's own b27 item 11 — `ModernScreenplayTests`) but never breaks the page just
/// before the "1." marker that announces a new page. Two rulings are binding, both pinned by
/// the tests below:
///
///   - "This is also only supposed to apply when our code detects a screenplay." — the
///     existing `screenplayBlocks`/`screenplayMarkerBis` gate is untouched; an ordinary
///     document's own numbered paragraph must never gain a page break.
///   - "It must include the trailing period, right? ... Ok. Keep it your optional period." —
///     `ModernScreenplay.matchesPageMarker`'s pattern (any 1-4 digit number, optional `.`)
///     stays exactly as it was; not touched by this job.
///
/// Mechanism: `DocumentRenderer.renderModern` now records the character offset of each
/// screenplay page-marker paragraph on `RenderedDocument.modernForcedPageBreakOffsets`, and
/// `PagedDocumentView.buildPages` forces AppKit's own container chain to stop just short of
/// that offset (`BreakingTextContainer`, `lineFragmentRect(forProposedRect:...)` returning a
/// zero rect once layout reaches it) — the standard TextKit 1 technique for a forced break,
/// scoped ONLY to the recorded offsets: `.pa`/form-feed breaks are NOT wired to this
/// mechanism, even though it could trivially also serve them (left to Jon, per the brief).
///
/// Evidence law for this round: RenderProbeKit is NOT evidence (off-screen compositing).
/// Both tests below assert directly against the REAL, shared `NSLayoutManager` — container
/// indices and glyph/character ranges, not merely "the text is present somewhere."
@Suite struct Job459ScreenplayPageBreakTests {

    static var ws7Directory: URL { ModernScreenplayTests.ws7Directory }

    enum ProbeError: Error { case notFound }

    @MainActor
    private static func documentState(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job459ScreenplayPageBreak.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// Modern, laid out for real through `PagedDocumentView` — same construction
    /// `Job439ModernAppendixLiveTests.pagedModernView`/`HeadersInViewsTests.pagedModernView`
    /// use. Continuous Scroll so every container in the chain exists and is inspectable
    /// without navigating a `DocumentWindowController` page by page.
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

    /// Per real container, in document order: the character range AppKit actually placed
    /// there (`characterRange(forGlyphRange:)`, the same "ask the layout manager, don't
    /// derive it by hand" discipline every other geometry probe in this codebase uses).
    @MainActor
    private static func containerCharRanges(_ view: PagedDocumentView) -> [NSRange] {
        guard let lm = view.primaryTextView?.layoutManager else { return [] }
        return view.pageViews.compactMap { pageView in
            guard let container = pageView.textContainer else { return nil }
            let glyphRange = lm.glyphRange(for: container)
            return lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        }
    }

    // MARK: - The real bug: SCRIPT.WS's "1." marker must start a new Modern page

    /// SCRIPT.WS's own Figure 2 transcript embeds a bare "1." page-number-marker paragraph
    /// immediately before its first scene's slugline (`ModernScreenplayTests`' own citation
    /// for the exact fixture shape — the SAME marker rule (b) already right-aligns). This
    /// test additionally requires rule (a): that marker must be the FIRST content of its own
    /// Modern page, and the paragraph before it must have exhausted the PREVIOUS page's own
    /// container — not merely present somewhere in the flow.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func screenplayPageMarkerStartsNewModernPage() throws {
        let state = try Self.documentState(fixture: "SCRIPT.WS")
        let (view, rendered) = Self.pagedModernView(for: state)

        // Locate the marker paragraph's own character offset the SAME way
        // `ModernScreenplayTests.pageNumberMarkerHoldsRightMarginInModern` does: anchor on
        // the slugline (a unique needle in this fixture) and walk back to the nearest
        // non-blank preceding paragraph.
        let haystack = rendered.text.string as NSString
        let sluglineNeedle = "1     INT. WRITER'S OFFICE - DAY"
        let sluglineRange = haystack.range(of: sluglineNeedle)
        #expect(sluglineRange.location != NSNotFound, "slugline needle not found in Modern text")
        guard sluglineRange.location != NSNotFound else { return }

        let beforeSlugline = haystack.substring(to: sluglineRange.location) as NSString
        var cursor = beforeSlugline.length
        var markerLineRange = NSRange(location: 0, length: 0)
        var markerParagraph = ""
        while cursor > 0 {
            markerLineRange = beforeSlugline.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
            markerParagraph = beforeSlugline.substring(with: markerLineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !markerParagraph.isEmpty { break }
            cursor = markerLineRange.location
        }
        #expect(markerParagraph == "1.", "expected the paragraph before the slugline to be the bare marker \"1.\" — found \"\(markerParagraph)\"")
        guard markerParagraph == "1." else { return }
        let markerOffset = markerLineRange.location

        // The renderer must have recorded this exact offset as a forced break.
        #expect(rendered.modernForcedPageBreakOffsets.contains(markerOffset), """
            renderModern must record the "1." marker paragraph's own character offset \
            (\(markerOffset)) in modernForcedPageBreakOffsets \(rendered.modernForcedPageBreakOffsets) \
            — rule (a) of Jon's screenplay ruling.
            """)

        // The view must have honoured it: some container's real placed range starts EXACTLY
        // at the marker offset (it is the FIRST glyph placed there), the container before it
        // is a REAL earlier page (index > 0, a break actually happened), and that previous
        // container's own placed range ends EXACTLY where the marker's begins (the paragraph
        // before it exhausted the previous page, no bleed either direction).
        let ranges = Self.containerCharRanges(view)
        let markerContainerIndex = ranges.firstIndex(where: { $0.location == markerOffset })
        #expect(markerContainerIndex != nil, """
            no real AppKit container starts exactly at character offset \(markerOffset) — \
            container ranges: \(ranges)
            """)
        guard let idx = markerContainerIndex else { return }
        #expect(idx > 0, "the marker's own container must not be page 0 — no break happened before it")
        guard idx > 0 else { return }
        let previous = ranges[idx - 1]
        #expect(previous.location + previous.length == markerOffset, """
            the page before the marker must exhaust exactly at its offset (\(markerOffset)) — \
            instead ended at \(previous.location + previous.length)
            """)
    }

    // MARK: - Jon's ruling: an ordinary document's own numbered line must NOT break

    /// A hand-built `Document` (public `CtrlKD.Document`/`Block`/`Line`/`Span` initializers —
    /// the same "documents built by hand" provenance `Document.detection`'s own doc comment
    /// names) with ordinary prose paragraphs and a bare "1." paragraph in the middle, but NO
    /// slugline anywhere — so `ModernScreenplay.detectBlocks` finds no screenplay region at
    /// all. Sanity-checked directly below before trusting the render/view assertions built on
    /// top of it: this is the exact gate rule (b) already depends on, and rule (a) must
    /// respect it identically.
    @MainActor
    private static func ordinaryDocumentWithBareNumberedLine() -> Document {
        Document(blocks: [
            Block(lines: [Line(spans: [Span(text:
                "The committee reviewed the annual budget report during a long Tuesday morning meeting without much debate.")])]),
            Block(lines: [Line(spans: [])]),
            Block(lines: [Line(spans: [Span(text: "1.")])]),
            Block(lines: [Line(spans: [])]),
            Block(lines: [Line(spans: [Span(text:
                "The meeting continued long into the afternoon with further discussion of the figures relevant to the coming fiscal year.")])]),
        ])
    }

    @Test @MainActor func ordinaryNumberedLineDoesNotBreakModernPage() throws {
        let doc = Self.ordinaryDocumentWithBareNumberedLine()

        // Sanity: this document must genuinely carry NO screenplay region — otherwise this
        // test would prove nothing about the gate it exists to guard.
        let screenplayBlocks = ModernScreenplay.detectBlocks(doc)
        #expect(screenplayBlocks.isEmpty, "fixture must carry no detected screenplay region for this test to mean anything")
        let markerBis = ModernScreenplay.markerCandidateBlocks(screenplayBlocks, blockCount: doc.blocks.count)
        #expect(markerBis.isEmpty)

        let defaults = UserDefaults(suiteName: "Job459OrdinaryNumberedLine.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let state = DocumentState(document: doc, settings: settings)
        let (view, rendered) = Self.pagedModernView(for: state)

        // The render layer must not have recorded ANY forced break — the direct assertion on
        // the exact mechanism rule (a) uses.
        #expect(rendered.modernForcedPageBreakOffsets.isEmpty, """
            an ordinary document must never populate modernForcedPageBreakOffsets — got \
            \(rendered.modernForcedPageBreakOffsets)
            """)

        // And in practice: this whole tiny document must lay out as ONE Modern page (nothing
        // forced it to split), with the "1." paragraph sitting inside that single container
        // alongside the prose before and after it, not starting a page of its own.
        #expect(view.pageCount == 1, "an ordinary short document with no forced break must lay out to exactly one Modern page — got \(view.pageCount)")
        let ranges = Self.containerCharRanges(view)
        let haystack = rendered.text.string as NSString
        let markerRange = haystack.range(of: "1.")
        #expect(markerRange.location != NSNotFound)
        guard markerRange.location != NSNotFound, let onlyRange = ranges.first else { return }
        #expect(NSLocationInRange(markerRange.location, onlyRange) && markerRange.location != onlyRange.location, """
            the marker paragraph must NOT be the first glyph of its container (that would mean \
            a break was forced) — container range \(onlyRange), marker at \(markerRange.location)
            """)
    }
}
