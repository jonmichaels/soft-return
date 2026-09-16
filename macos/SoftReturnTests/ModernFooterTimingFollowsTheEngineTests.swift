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
