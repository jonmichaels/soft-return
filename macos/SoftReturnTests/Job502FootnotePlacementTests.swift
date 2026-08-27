import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// job-502 — hard placement assertions for Modern's page-foot footnote block (Jon's ruling:
/// footnotes sit at the page FOOT, dash-separated, like Printed — job 490 item 1 got the
/// right PAGE and the wrong PLACE). `Job502FootnotePlacementProbe.swift` is the evidence
/// capture (PNGs, looked at by eye per the job brief); this file is the geometry GATE, a hard
/// assertion a future regression would actually trip.
@Suite struct Job502FootnotePlacementTests {

    /// Builds a synthetic Modern `RenderedDocument` directly — bypassing `DocumentRenderer
    /// .renderModern`'s real WordStar parse entirely, the SAME "construct the struct by
    /// hand" technique `ExportEngine.tocIndexPages` already uses for its own synthesized
    /// TOC/Index page — so this test can pin an EXACT multi-footnote scenario (two footnotes
    /// both attached to the page's one paragraph) without depending on some real WS7 fixture
    /// happening to wrap two footnotes onto the same page.
    @MainActor
    private static func syntheticMultiFootnotePage() -> RenderedDocument {
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString(string:
            "A single short body paragraph, well clear of the page's own bottom margin, " +
            "with plenty of blank canvas below it for a footnote block to reserve.",
            attributes: [.font: bodyFont, .paragraphStyle: paragraph, .foregroundColor: NSColor.black])

        let noteFont = NSFont.systemFont(ofSize: 11)
        let noteParagraph = NSMutableParagraphStyle()
        func noteLine(_ string: String) -> NSAttributedString {
            let line = NSMutableAttributedString(string: string, attributes: [
                .font: noteFont, .paragraphStyle: noteParagraph, .foregroundColor: NSColor.black,
            ])
            line.append(NSAttributedString(string: "\n", attributes: [
                .font: noteFont, .paragraphStyle: noteParagraph,
            ]))
            return line
        }
        let separator = noteLine(String(repeating: "-", count: 20))
        let entries = [
            noteLine("1. The first footnote attached to this page's own paragraph."),
            noteLine("2. The second footnote, attached to the SAME paragraph."),
        ]

        let pageSize = CGSize(width: 612, height: 792)   // US Letter, matching Modern's own default
        let margin: CGFloat = 72
        let textFrame = CGRect(x: margin, y: margin,
                                width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        return RenderedDocument(
            text: text, pageSize: pageSize, textFrame: textFrame, pageCount: 1, clipsLines: false,
            softLineFlags: [], overprintPasses: [], oversizedSelfPasses: [], baselineOffset: 0,
            leadingHeadroom: [], runningLines: [], hfEvents: [], pageNumberStart: 1,
            realPageIndexByPage: [0], pinnedBaselines: [:], perPageTextTop: [Double(textFrame.origin.y)],
            pinnedPageBottoms: [], modernForcedPageBreakOffsets: [],
            // charOffset 0: this synthetic page's one paragraph is the whole document, so its
            // own first character is offset 0 — the SAME "paragraph's own first character"
            // anchor `renderModern` uses for real (`ModernFootnoteEvent`'s own doc comment).
            modernFootnoteEvents: [ModernFootnoteEvent(charOffset: 0, entries: entries)],
            modernFootnoteSeparator: separator, pclPrograms: []
        )
    }

    /// The placement assertion the job-502 brief itself asks for: a multi-footnote page's
    /// footnote block sits in the bottom region of the page, and BELOW the lowest real
    /// body-text line — never overlapping body ink, never floating near the top of a
    /// mostly-blank page.
    @Test @MainActor func multiFootnotePageDrawsBelowTheLowestBodyLineInTheBottomRegion() throws {
        let rendered = Self.syntheticMultiFootnotePage()
        let view = PagedDocumentView()
        view.setContent(rendered, display: .singlePage)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        #expect(view.pageCount == 1, "the synthetic body paragraph must fit on one page")
        let entries = view.footnoteBlock(atPageIndex: 0)
        #expect(entries.count == 2,
                "both footnotes attached to this page's own paragraph must reach its real footnoteBlock")

        guard let container = view.primaryTextView?.textContainer,
              let layoutManager = view.primaryTextView?.layoutManager else {
            Issue.record("no real text container for the synthetic page")
            return
        }
        var lowestBodyLineBottom: CGFloat = 0
        let glyphRange = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
            lowestBodyLineBottom = max(lowestBodyLineBottom, rect.maxY)
        }
        // `enumerateLineFragments`' own `rect` is CONTAINER-local; `textContainerBottom`
        // and `textFrame.origin.y` are both page-relative (`textTop(atPage:)`'s own doc
        // comment) — converted to the SAME page-relative frame before comparing.
        let lowestBodyLineBottomOnPage = rendered.textFrame.origin.y + lowestBodyLineBottom
        let footnoteBlockTop = view.textContainerBottom(atPageIndex: 0)
        let pageBottom = rendered.textFrame.origin.y + rendered.textFrame.size.height

        #expect(footnoteBlockTop < pageBottom,
                "reserving room for 2 footnotes must shrink the container below the page's own unreduced bottom")
        #expect(footnoteBlockTop >= lowestBodyLineBottomOnPage,
                "the footnote block must start at or below the lowest real body-text line, never overlapping it")
        // Bottom-region check: the reserved gap's own top edge must sit in the bottom third
        // of the page's own printable area — "somewhere before the page ends" alone would
        // also be satisfied by a reservation sitting just under a near-empty page's TOP.
        let bottomThird = rendered.textFrame.origin.y + rendered.textFrame.size.height * 2 / 3
        #expect(footnoteBlockTop >= bottomThird,
                "the footnote block's own top edge must sit in the bottom third of the page, not merely above its bottom edge")
    }
}
