import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 456 (b28 notes 9/10): live-runtime coverage for the Modern box/legend fixes in
/// `DocumentRenderer.swift`, using `BOXES.WS` — the same fixture Jon's own screenshot (circled
/// in red) reproduced both defects against. Follows `Job439ModernAppendixLiveTests`'s own
/// convention: assert against the REAL, laid-out `PagedDocumentView`/`NSLayoutManager`
/// geometry, never against `RenderProbeKit` (which composites off-screen and proves nothing
/// about what a person actually sees on screen).
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct Job456ModernBoxAndLegendTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    @MainActor
    private static func state(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Job456ModernBoxAndLegend.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// Modern, laid out for real through `PagedDocumentView` — same construction
    /// `Job439ModernAppendixLiveTests.pagedModernView` uses.
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

    /// The real line fragment rect (`NSLayoutManager`) for the line containing `needle`'s first
    /// character, searching from `from` onward so a repeated needle can be found more than once.
    @MainActor
    private static func lineFragmentRect(
        containing needle: String, from: String.Index? = nil, in view: PagedDocumentView, text: String
    ) throws -> (rect: CGRect, end: String.Index) {
        let lm = try #require(view.primaryTextView?.layoutManager)
        let searchRange = (from ?? text.startIndex)..<text.endIndex
        let range = try #require(text.range(of: needle, range: searchRange),
                                  "'\(needle)' must appear in the rendered Modern text")
        let nsRange = NSRange(range, in: text)
        var rect = CGRect.zero
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: nsRange.location, length: 1)) { fragmentRect, _, _, _, _ in
            rect = fragmentRect
        }
        return (rect, range.upperBound)
    }

    /// The number of DISTINCT line fragments the row starting at `needle` occupies — from
    /// `needle`'s first character through the next hard-return `"\n"` (`lineTerminator`'s own
    /// per-paragraph separator).
    @MainActor
    private static func lineFragmentCount(forRowContaining needle: String, in view: PagedDocumentView, text: String) throws -> Int {
        let lm = try #require(view.primaryTextView?.layoutManager)
        let startRange = try #require(text.range(of: needle), "'\(needle)' must appear in the rendered Modern text")
        let terminatorRange = text.range(of: "\n", range: startRange.lowerBound..<text.endIndex)
        let rowEnd = terminatorRange?.lowerBound ?? text.endIndex
        let rowNSRange = NSRange(startRange.lowerBound..<rowEnd, in: text)
        guard rowNSRange.length > 0 else { return 0 }
        var origins: Set<String> = []
        lm.enumerateLineFragments(forGlyphRange: rowNSRange) { fragmentRect, _, _, _, _ in
            origins.insert("\(fragmentRect.origin.y)")
        }
        return origins.count
    }

    // MARK: - Note 9: consecutive box rows must sit with NO added inter-paragraph gap.
    //
    // TWO independent mechanisms turned out to contribute to the dashed appearance (verified
    // live building this fix, not assumed from the recon alone):
    //
    // 1. `modernParagraphStyle` set `paragraphSpacing = size * 0.35` UNCONDITIONALLY for every
    //    Modern paragraph (the recon's own citation) — each box row is its own hard-returned
    //    paragraph, so every row got that extra gap below it.
    // 2. BOXES.WS's rows are classified `isVerse` by the engine's own consecutive-short-lines
    //    heuristic (a box reads exactly like a stanza's shape) — that makes every row `tight`
    //    (`modernParagraphStyle`'s `tight: align == .center || isVerse`), and a tight row whose
    //    real glyph ink rises above the compressed line box independently triggers job 434's
    //    own leading-spacer headroom mechanism (`modernLeadingSpacer`/`modernAscentDeficit`),
    //    inserting an extra ~5pt invisible line between rows regardless of `paragraphSpacing`.
    //    Fixing only (1) left a real, measured 5pt gap between rows — still a visible dash.
    //
    // A line fragment's own origin-to-origin delta between two consecutive rows equals the
    // natural single-line advance ONLY when neither extra mechanism fires — this is what
    // actually distinguishes "fixed" from "still dashed" (a plain height check can't, since
    // AppKit bakes trailing `paragraphSpacing` into the reported fragment height).

    @Test @MainActor func boxesWSConsecutiveBoxRowsHaveNoAddedGap() throws {
        let state = try Self.state(fixture: "BOXES.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let modern = rendered.text.string

        // The first box: 5 identical rows, each just a "│" on the left, a "│" on the right,
        // and spaces between (the box Jon's own screenshot shows with visibly dashed sides).
        // Search for the bare "│" character rather than a multi-character literal:
        // `modernNoBreakGraphicRuns` splices U+2060 WORD JOINER between every adjacent
        // character pair inside the row's own graphic run (job 456's own note 10 fix widens
        // that run to span the whole row here), so the row's real text is NOT the plain
        // "│                     │" a naive literal would expect.
        let row1Start = try #require(modern.firstIndex(of: "│"), "BOXES.WS's first box row must reach the Modern render")
        let (row1, row1End) = try Self.lineFragmentRect(containing: "│", from: row1Start, in: view, text: modern)
        let row1LineEnd = try #require(modern.range(of: "\n", range: row1End..<modern.endIndex)).upperBound
        let row2Start = try #require(modern[row1LineEnd...].firstIndex(of: "│"), "BOXES.WS's second box row must follow the first")
        let (row2, row2End) = try Self.lineFragmentRect(containing: "│", from: row2Start, in: view, text: modern)
        let gap12 = row2.origin.y - row1.origin.y
        #expect(gap12 > 0, "sanity: the two box rows must actually be on different lines")

        // A third row, to prove this holds across more than one adjacent pair.
        let row2LineEnd = try #require(modern.range(of: "\n", range: row2End..<modern.endIndex)).upperBound
        let row3Start = try #require(modern[row2LineEnd...].firstIndex(of: "│"), "BOXES.WS's third box row must follow the second")
        let (row3, _) = try Self.lineFragmentRect(containing: "│", from: row3Start, in: view, text: modern)
        let gap23 = row3.origin.y - row2.origin.y

        #expect(abs(gap12 - row1.height) < 0.5,
                "row1->row2 gap must equal the natural single-line advance, no added paragraphSpacing or leading-spacer headroom (gap \(gap12)pt, natural height \(row1.height)pt)")
        #expect(abs(gap23 - row2.height) < 0.5,
                "row2->row3 gap must equal the natural single-line advance too (gap \(gap23)pt, natural height \(row2.height)pt)")
    }

    // MARK: - Note 10: a mixed label+glyph legend row must not wrap mid-row.
    //
    // `isWhollyGraphicRow` correctly leaves a MIXED row (real prose label + box-drawing
    // glyphs, e.g. "LL: ∟ LR: ┘ LC: ∟ ┘ Joins: ├ ┬ ┴ ┤ Mixed: ├ ┬ ┴ ┤") on ordinary word-wrap,
    // which folds it at the label/glyph boundary once it exceeds Modern's text measure (Jon:
    // "I don't understand what happened in Modern. They have line returns in the middle").

    @Test @MainActor func boxesWSMixedLegendRowStaysOnOneLine() throws {
        let state = try Self.state(fixture: "BOXES.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let modern = rendered.text.string
        #expect(modern.contains("Joins:"), "BOXES.WS's Joins/Mixed legend row must reach the Modern render")

        let fragmentCount = try Self.lineFragmentCount(forRowContaining: "LL: ", in: view, text: modern)
        #expect(fragmentCount == 1,
                "the 'LL: ... Joins: ... Mixed: ...' legend row must occupy exactly ONE line fragment, not wrap mid-row (found \(fragmentCount))")
    }

    @Test @MainActor func boxesWSSingleGlyphLegendRowsStayOnOneLine() throws {
        let state = try Self.state(fixture: "BOXES.WS")
        let (view, rendered) = Self.pagedModernView(for: state)
        let modern = rendered.text.string

        let vCount = try Self.lineFragmentCount(forRowContaining: "V:", in: view, text: modern)
        #expect(vCount == 1, "the 'V:' legend row must occupy exactly ONE line fragment (found \(vCount))")
    }
}
