import AppKit
import Testing
@testable import SoftReturn

/// b27 item 8 — `BOXES.WS`'s box-drawing rows in Modern rendered "completely wrong":
/// open top-right corner, a stray interior vertical, missing right side, character-array
/// rows wrapping awkwardly. Root cause: `renderModern` never tokenized box-drawing rows
/// as a single unit at all — `DocumentRenderer.attributedLine` hands AppKit's own
/// word-wrap the row's raw text, and AppKit's line-breaker (a) treats any interior space
/// as an ordinary break opportunity, so an all-space interior between two borders tore
/// the row into pieces, and (b) will even force a break directly between two adjacent
/// box-drawing glyphs (confirmed empirically — see `modernNoBreakGraphicRuns`'s own doc
/// comment) when a wholly-graphic run is simply wider than the text measure. The b26
/// engine tokenizer fix (`modernTokenize`, `PDFModernLayout.swift`, ctrl-kd 8122706) fixed
/// the ENGINE's own Modern PDF; the app's Modern view is a separate AppKit consumer that
/// never received an equivalent.
///
/// Reproduced directly on `BOXES.WS` at Modern's real 468pt text width (`Oracle.layOut`,
/// the real multi-page `PagedDocumentView` path): a plain 80-column border row
/// (`┌────...────┐`, no space characters in it at all) split into 2 line fragments, and
/// two legend rows (mixing real words with short embedded box-drawing runs, e.g.
/// `"LC: └  ┘   Joins:  ├  ┬  ┴  ┤"`) split MID-RUN, tearing a join glyph away from its
/// own neighbors.
///
/// NOTE (per this job's brief): the "Georgia" font-record-timing theory for this item was
/// separately REFUTED and is not this file's concern — `doc.fonts` is parsed complete
/// before rendering, spans carry pre-resolved indices. This file tests the tokenization/
/// wrapping defect only, in Modern (the one view with any word-wrap at all — Native/
/// Printed clip rather than reflow, so this defect cannot occur there).
/// Job 535: every test in this suite reads `TestDocs/ws7` (`OracleByteParityTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ModernBoxRowTokenizationTests {

    /// One fixture-independent lookup: BOXES.WS's own first paragraph containing a run of
    /// 20+ consecutive `─` (U+2500) box-drawing characters with no interior space at all —
    /// the plain top/bottom border of its widest demonstrated box.
    @MainActor
    private static func longestPureBorderRow(in page: Oracle.LaidOutPage) -> (text: String, range: NSRange)? {
        let text = page.textView.string as NSString
        var best: (String, NSRange)?
        var paraStart = 0
        while paraStart < text.length {
            let paraRange = text.paragraphRange(for: NSRange(location: paraStart, length: 0))
            let snippet = text.substring(with: paraRange)
            let borderChars = snippet.filter { $0 != "\u{2060}" && !$0.isNewline }
            if borderChars.count > 20, borderChars.allSatisfy({ $0 == "\u{2500}" || $0 == "\u{250C}" || $0 == "\u{2510}"
                || $0 == "\u{2514}" || $0 == "\u{2518}" }) {
                if (best?.1.length ?? 0) < paraRange.length { best = (snippet, paraRange) }
            }
            paraStart = paraRange.location + max(paraRange.length, 1)
        }
        return best
    }

    /// Real Modern-style pages, laid out the same way `PagedDocumentView` lays out the
    /// live on-screen window — `Oracle.layOut` is PRINTED-only (it calls
    /// `state.style.setManually(.printed)` before rendering), so it cannot be reused here.
    @MainActor
    private static func modernPages(for state: DocumentState) -> [Oracle.LaidOutPage] {
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        return view.pageViews.compactMap { tv -> Oracle.LaidOutPage? in
            guard let m = tv.layoutManager, let c = tv.textContainer else { return nil }
            m.ensureLayout(for: c)
            return Oracle.LaidOutPage(textView: tv, manager: m, container: c, glyphs: m.glyphRange(for: c))
        }
    }

    @MainActor
    private static func fragmentCount(for range: NSRange, in page: Oracle.LaidOutPage) -> Int {
        var count = 0
        page.manager.enumerateLineFragments(
            forGlyphRange: page.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        ) { _, _, _, _, _ in count += 1 }
        return count
    }

    /// A pure box border row, wider than Modern's own text measure, must stay ONE line
    /// fragment (running past the measure, per the engine's own "stays one unbroken
    /// block" behavior) — never torn apart by AppKit's word-wrap.
    @Test @MainActor func pureBorderRowNeverSplitsInModern() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("BOXES.WS")
        let state = try Oracle.state(for: url)
        let pages = Self.modernPages(for: state)
        var found: (String, NSRange)?
        for page in pages {
            if let row = Self.longestPureBorderRow(in: page) {
                found = row
                let count = Self.fragmentCount(for: row.range, in: page)
                #expect(count == 1, """
                    BOXES.WS's \(row.text.count)-column pure border row split into \(count) \
                    line fragments in Modern instead of staying one unbroken block: \
                    "\(row.text.prefix(40))..."
                    """)
                break
            }
        }
        #expect(found != nil, "BOXES.WS no longer contains a pure box-border row of 20+ columns — fixture changed?")
    }

    /// A box-drawing "join" character embedded in a legend line (e.g. `├`/`┬`/`┴`/`┤`
    /// surrounded by single spaces, itself part of a short graphic run like `└  ┘`) must
    /// never land on a DIFFERENT visual line from its own immediate graphic-run
    /// neighbors — the row may still wrap at a REAL word boundary elsewhere (this is
    /// ordinary prose reflow, not the bug), but a line break may never fall strictly
    /// inside one contiguous graphic run.
    @Test @MainActor func graphicRunNeverSplitsMidRunInModern() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("BOXES.WS")
        let state = try Oracle.state(for: url)
        let pages = Self.modernPages(for: state)
        var checkedAnyGraphicRun = false
        for page in pages {
            let text = page.textView.string as NSString
            var paraStart = 0
            while paraStart < text.length {
                let paraRange = text.paragraphRange(for: NSRange(location: paraStart, length: 0))
                let snippet = text.substring(with: paraRange)
                let chars = Array(snippet)
                var i = 0
                while i < chars.count {
                    guard graphicChars.contains(chars[i]) else { i += 1; continue }
                    var j = i
                    var lastGraphic = i
                    while j < chars.count, graphicChars.contains(chars[j]) || chars[j] == " " || chars[j] == "\u{2060}" {
                        if graphicChars.contains(chars[j]) { lastGraphic = j }
                        j += 1
                    }
                    if lastGraphic > i {
                        checkedAnyGraphicRun = true
                        // Fragment boundaries strictly BETWEEN i and lastGraphic (in this
                        // paragraph's own character range) would mean AppKit broke inside
                        // this graphic run.
                        let runStart = paraRange.location + i
                        let runEnd = paraRange.location + lastGraphic
                        var breakInsideRun = false
                        page.manager.enumerateLineFragments(
                            forGlyphRange: page.manager.glyphRange(
                                forCharacterRange: NSRange(location: runStart, length: runEnd - runStart + 1),
                                actualCharacterRange: nil)
                        ) { _, _, _, glyphRange, _ in
                            let charRange = page.manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                            let fragEnd = charRange.location + charRange.length
                            // A fragment ending strictly before this run's own end (and this
                            // run's own start is inside the fragment we're scanning) means the
                            // NEXT fragment continues the SAME run — a mid-run break.
                            if charRange.location <= runStart, fragEnd <= runEnd, fragEnd > runStart {
                                breakInsideRun = true
                            }
                        }
                        #expect(!breakInsideRun, """
                            BOXES.WS graphic run "\(String(chars[i...lastGraphic]))" (paragraph: \
                            "\(snippet.prefix(60))") split across line fragments in Modern
                            """)
                    }
                    i = lastGraphic + 1
                }
                paraStart = paraRange.location + max(paraRange.length, 1)
            }
        }
        #expect(checkedAnyGraphicRun, "BOXES.WS no longer contains any multi-character graphic run to check")
    }
}
