import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (G): a running head or foot appears on the page the ENGINE first draws it on, not a page earlier or
/// later.
///
/// This is a test and not a change. The app used to replay `HFEvent`s against each real page boundary and work the
/// timing out for itself — "everything before this page's first character is in force" — which is a second copy of a
/// rule the engine already applies. Item F retired that: each page's heads and feet now come from that page's own
/// furniture record, so the timing IS the engine's, page for page, with nothing left to drift.
///
/// RTF-RJS/NOVEL.WS is the document that shows it: the engine draws no header at all on page 1 and one from page 2
/// onward, so a view that started the header a page early — or carried it a page late — differs here and nowhere
/// else. The comparison runs over every page, not just the transition, because an off-by-one that happens to be
/// right at the boundary and wrong afterwards is exactly what a single-page check would miss.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct ModernFooterTimingFollowsTheEngineTests {
    nonisolated static let documents = ["RTF-RJS/NOVEL.WS", "REF/BOOKLET.WS", "PRINT.TST"]

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: documents)
    func headsAndFeetStartOnTheEnginesOwnPage(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let furniture = modernPageFurniture(state.document, options: DocumentRenderer.modernEngineOptions(state))
        let pages = ModernPageFurnitureProbe.pages(state)

        // The engine's own timing, stated up front so the report reads without the log: which pages carry heads
        // and which carry feet, as counts, for the first stretch of the document.
        let engineShape = furniture.prefix(6).enumerated()
            .map { "p\($0.offset + 1) h\($0.element.headers.count)/f\($0.element.footers.count)" }
            .joined(separator: " ")
        print("MODERN-TIMING \(document): engine \(furniture.count) pages, view \(pages.count); engine \(engineShape)")

        if pages.count != furniture.count {
            print("MODERN-TIMING-RESIDUAL \(document): the view lays \(pages.count) pages, the engine \(furniture.count) — timing compared on the pages both laid")
        }

        var wrong: [String] = []
        for (index, sheet) in furniture.enumerated() {
            guard pages.indices.contains(index) else { continue }
            // THE AUTOMATIC PAGE NUMBER IS NOT A FOOT. It rides a footer's row and item C appends it to the same
            // list, but the engine reports it separately (`autoPageNumber`, not `footers`) and so does this view
            // (`RunningLine.Kind.autoPageNumber`, which exists for exactly this distinction). Counting it as a
            // foot made PRINT.TST read "1 feet drawn, the engine draws 0" on every page — the engine's furniture
            // says h1/f0 there and the only thing at the foot is the number.
            let drawn = pages[index].runningLines
            let drawnHeads = drawn.filter(\.isHeader).count
            let drawnFeet = drawn.filter { !$0.isHeader }.count
            // An ink-less line is never reported by the engine, so the counts are of lines that really draw —
            // which is the point: a `.f#` of nothing but print-control bytes must not show up as a blank foot.
            if drawnHeads != sheet.headers.count {
                wrong.append("p\(index + 1): \(drawnHeads) heads drawn, the engine draws \(sheet.headers.count)")
            }
            if drawnFeet != sheet.footers.count {
                wrong.append("p\(index + 1): \(drawnFeet) feet drawn, the engine draws \(sheet.footers.count)")
            }
            // And the text itself, in the engine's own order, so a page with the right COUNT but the wrong line
            // is named too.
            let drawnHeadLines = drawn.filter(\.isHeader)
            for (slot, head) in sheet.headers.enumerated() where drawnHeadLines.indices.contains(slot) {
                let mine = Self.comparable(drawnHeadLines[slot].text)
                let theirs = Self.comparable(head.text)
                if mine != theirs {
                    wrong.append("p\(index + 1) head \(slot + 1): \"\(mine)\", the engine \"\(theirs)\"")
                }
            }
        }
        #expect(wrong.isEmpty, "\(document): \(wrong.joined(separator: "; "))")
    }

    /// Batch 42 (3): how many body lines the VIEW lays on each page, beside how many the engine lays.
    ///
    /// A measurement, not an assertion — it prints and expects nothing, because what the right answer IS depends
    /// on a ruling that has not been made.
    ///
    /// RTF-RJS/NOVEL.WS is 43 view pages against the engine's 44, and it is the only document that runs that way:
    /// the font-substitution exception's own list is BOOKLET.WS 9 against 3, PRINT.TST 8 against 6, BOOKLET.HOW 12
    /// against 10 — view HIGH every time, which is what a wider face predicts. A wider face cannot make the view
    /// fit MORE, so NOVEL is not that exception and needs its own measurement.
    ///
    /// The engine's side is already measured, off its own Modern PDF: a full NOVEL page carries 45 body lines,
    /// first baseline 707.50, last 73.90, advance 14.4 — and 707.50 - 44 x 14.4 = 73.90 exactly. The text block's
    /// floor is y 72, so the last line sits 1.9pt inside it and the engine reserves NOTHING at the foot for the
    /// typed footer, whose row is at y 44, out in the margin where the furniture already reports it. That killed
    /// the reservation theory, which leaves the first baseline's own offset (the engine's is 12.5 below the frame
    /// top, an ascent figure a different face moves) and the bottom fit test. This prints the view's three
    /// figures in the same terms so the two columns can be read against each other.
    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: documents)
    func bodyLinesPerPageBesideTheEngines(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let furniture = modernPageFurniture(state.document, options: DocumentRenderer.modernEngineOptions(state))
        let rendered = DocumentRenderer.render(state, style: .modern)
        let host = PagedDocumentView()
        host.setContent(rendered, display: .continuousScroll)
        host.setFrameSize(host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()
        print("MODERN-BODY \(document): view \(host.pageCount) pages, engine \(furniture.count)")
        // Batch 42 (3): HOW LONG IS EACH SIDE'S TEXT, and where does the view put each COMMANDED break?
        //
        // NOVEL's view reaches the `.pa` at flow item 247 having laid 44 fewer body lines than the engine, and
        // stays a page ahead from there. A wider face cannot do that — it needs MORE lines — so the suspicion was
        // the view's own text being shorter (the mapper's note: sentence spacing collapsed, markers inserted).
        // Counting killed that: the engine's flow carries 57472 characters with only 956 second-space runs, about
        // 22 lines' worth document-wide and ~5 before the break, against a 44-line shortfall. So the lengths
        // themselves have to be compared rather than reasoned about, and the commanded breaks named, because a
        // view that honours every one of them (this one does — it opens a page on item 250, "Praise for The
        // Oppenheimer Alternative", exactly as the engine does) can still arrive at them a page early.
        let flow = modernSemanticFlow(state.document)
        var engineChars = 0
        for item in flow.items {
            if case .para(_, _, _, let runs, _, _, _, _) = item { engineChars += runs.map(\.text).joined().count }
        }
        let commanded = flow.items.indices.filter { String(describing: flow.items[$0]).hasPrefix("pageBreak") }
        // COUNTED WITHOUT WHITESPACE, and that is not fussiness — it is the only comparable basis.
        //
        // The engine's DRAWN text (Athena, 2026-09-16: its Modern PDF has 0 double spaces on page 2, so the
        // emitter collapses sentence spacing exactly as this view does) carries no newlines at all: a PDF draws
        // rows, it does not store line ends. This view's string carries a newline per line and word joiners of
        // its own (U+2060, visible in the column-boundary scalar dumps). Comparing raw lengths would therefore
        // measure the two representations, not the two texts. `engineChars` below is the RAW flow — kept only to
        // show how much the collapse accounts for — and is NOT the figure to compare against.
        var viewInk = 0
        var joiners = 0
        let viewString = rendered.text.string as NSString
        for index in 0..<viewString.length {
            let unit = viewString.character(at: index)
            if unit == 0x2060 || unit == 0xFEFF { joiners += 1; continue }
            guard let scalar = Unicode.Scalar(unit) else { continue }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { viewInk += 1 }
        }
        print("MODERN-TEXTLEN \(document): view \(rendered.text.length) characters, \(viewInk) non-whitespace, "
              + "\(joiners) joiners; engine RAW flow \(engineChars) (pre-collapse, not the comparison); "
              + "commanded breaks at items \(commanded.prefix(14))")
        for item in commanded.prefix(6) where rendered.modernItemStarts.indices.contains(item) {
            print("MODERN-BREAKAT \(document): commanded break at item \(item) -> view offset \(rendered.modernItemStarts[item])")
        }
        let textViews = host.subviews.compactMap { $0 as? NSTextView }
        let whole = rendered.text.string as NSString
        for index in 0..<host.pageCount {
            let sheet = host.rect(ofPage: index)
            var baselines: [Double] = []
            var pageInk = 0
            for textView in textViews where textView.frame.intersects(sheet) {
                guard let manager = textView.layoutManager, let container = textView.textContainer else { continue }
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(for: container)
                guard glyphs.length > 0 else { continue }
                // Batch 42 (3): this page's own INK, counted the way the engine's DRAWN text has to be counted.
                //
                // The engine's Modern PDF holds no space characters at all — 50273 drawn characters, all 50273
                // non-whitespace — because spacing there is positioning (`Td`/`TJ` offsets), not glyphs. So
                // whitespace cannot take part in the comparison from either side, and what remains is the ink.
                // Per page rather than per document, because a single total would say the two texts differ
                // without saying where, and the engine's own per-page ink is already known:
                // [302, 369, 1318, 1199, 1145, 1145, 1691, 1531, 1437, 1407, 106, 1863] for p1-p12.
                let pageRange = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let upper = min(whole.length, pageRange.location + pageRange.length)
                if pageRange.location < upper {
                    for index in pageRange.location..<upper {
                        let unit = whole.character(at: index)
                        if unit == 0x2060 || unit == 0xFEFF { continue }
                        if let scalar = Unicode.Scalar(unit),
                           !CharacterSet.whitespacesAndNewlines.contains(scalar) { pageInk += 1 }
                    }
                }
                // A FRAGMENT WITH REAL INK ONLY. A blank line is a fragment like any other, and counting it would
                // make the two sides differ for a reason neither renderer decided.
                manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
                    let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                    guard characters.location + characters.length <= whole.length else { return }
                    let text = whole.substring(with: characters)
                    guard text.contains(where: { !$0.isWhitespace }) else { return }
                    // The baseline the view actually DRAWS at, through this column's own text view into the
                    // page's rectangle — the same conversion `ColumnTopsMatchTheEngineTests` measures tops with.
                    let glyph = manager.location(forGlyphAt: glyphRange.location)
                    let origin = textView.textContainerOrigin
                    let inHost = host.convert(NSPoint(x: origin.x + fragment.minX + glyph.x,
                                                      y: origin.y + fragment.minY + glyph.y),
                                              from: textView)
                    baselines.append(Double(host.isFlipped ? inHost.y - sheet.minY : sheet.maxY - inHost.y))
                }
            }
            guard !baselines.isEmpty else {
                print("MODERN-BODY \(document) p\(index + 1): no body ink")
                continue
            }
            let sorted = baselines.sorted()
            let advance = sorted.count > 1 ? sorted[1] - sorted[0] : 0
            print(String(format: "MODERN-BODY %@ p%d: %d body lines, %d ink, first %.2f from top, last %.2f from top, advance %.2f",
                         document, index + 1, sorted.count, pageInk, sorted[0], sorted[sorted.count - 1], advance))
            // Batch 42 (3): WHAT THIS PAGE OPENS WITH.
            //
            // Line counts cannot say where a page goes missing. NOVEL lays 44 engine pages against the view's 43,
            // and from page 30 onward the view's page N holds exactly what the engine's page N+1 holds (45, 45,
            // 45, 45, 45, 10, 39, 45, 45, 45, 45, 45, 12 — matching the engine's p31 through p44 exactly), so the
            // view is a page behind by then and never recovers. The page is lost somewhere earlier, where the
            // counts are too close together to read. The opening text says which page that is.
            if let opening = pageOpening(textViews: textViews, sheet: sheet, whole: whole) {
                print("MODERN-PAGESTART \(document) p\(index + 1): \"\(opening)\"")
            }
        }
    }

    /// Batch 42 (3): the first characters this page's text actually opens with.
    ///
    /// The page's own containers, lowest character location first — a multi-column page has several and they are
    /// not laid out left to right in `subviews` order, so the opening is the earliest CHARACTER, not the leftmost
    /// view. Whitespace is skipped and newlines are shown as `\n`, because a page that opens on a blank line would
    /// otherwise print as nothing and compare equal to every other such page.
    @MainActor
    private func pageOpening(textViews: [NSTextView], sheet: NSRect, whole: NSString) -> String? {
        var earliest: Int?
        for textView in textViews where textView.frame.intersects(sheet) {
            guard let manager = textView.layoutManager, let container = textView.textContainer else { continue }
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            earliest = min(earliest ?? characters.location, characters.location)
        }
        guard var start = earliest, start < whole.length else { return nil }
        while start < whole.length,
              let scalar = Unicode.Scalar(whole.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }
        guard start < whole.length else { return nil }
        let opening = whole.substring(with: NSRange(location: start, length: min(48, whole.length - start)))
        return opening.replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Both sides reduced to the same basis before comparing. The engine keeps WordStar's inline toggle bytes in a
    /// head's text and the view strips them once styled, so control characters go from both. The bullet is folded
    /// too: `∙` (U+2219, WordStar's cp437 list marker) becomes `•` down Modern's own path and `·` down Printed's,
    /// and THIS TEST IS ABOUT TIMING — which page a line first appears on — not about which bullet a renderer
    /// spells it with. Comparing across two different substitution rules would invent mismatches that are not
    /// what the item is holding.
    nonisolated static func comparable(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar.value {
            case 0x2219, 0x2022, 0x00B7: return "\u{2022}"
            case 0..<0x20, 0x7F: return nil
            default: return Character(scalar)
            }
        })
    }
}
