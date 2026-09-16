import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (C): Modern draws WordStar's automatic page number where the engine's own Modern PDF draws it.
///
/// The engine reports it per page on the furniture (`ModernPageFurniture.autoPageNumber`) and decides FOR the app
/// whether a page carries one at all — `nil` when the document declares `.op`, when a footer is in use, or when page
/// numbers are off — so the app keeps no second copy of that rule and, just as importantly, never invents a number
/// the engine withheld. Placement is Modern's own (M15, Jon's ruling 2026-09-15): centred in Modern's measure on the
/// row a Modern footer line 1 rides, never Printed's `.pc` column or its `pl - mb + fm` row.
///
/// The number is its own `RunningLine.Kind` rather than a footer, because a document can carry a typed `.f#` that
/// reads "1" as well, and a test that matched on the text alone could not tell them apart.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct ModernAutoPageNumberFollowsTheEngineTests {
    /// The four documents the item was scoped to, plus the five landscape ones whose exclusion Athena lifted
    /// (2026-09-15) once Modern started laying pages on the engine's own sheet.
    /// `nonisolated`: the `@Test(arguments:)` macro reads this from OUTSIDE the actor, so a plain `static` on a
    /// `@MainActor` suite fails to build ("main actor-isolated static property cannot be accessed from outside").
    nonisolated static let documents = [
        "VERSIONS.WS", "RTF-RJS/NOVEL.WS", "ARTICLES/SCRIPT.WS", "DEFAULT/OPTIONS/ENVELOPE.LST",
        "REF/ADVANCE.DOT", "REF/GALLEYS.DOT", "REF/BOOKLET.RJS", "REF/-HOW-TO.RJS", "REF/BOOKLET.HOW",
    ]

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: documents)
    func theAutomaticNumberIsTheEnginesOwn(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let furniture = modernPageFurniture(state.document, options: DocumentRenderer.modernEngineOptions(state))
        let pages = ModernPageFurnitureProbe.pages(state)
        let numbered = furniture.filter { $0.autoPageNumber != nil }.count
        print("MODERN-AUTONO \(document): engine \(furniture.count) pages (\(numbered) numbered), view \(pages.count) pages")

        // A page count that disagrees is a NAMED residual, not a silent skip: the comparison below only covers
        // pages both sides laid, so the report has to say so out loud.
        if pages.count != furniture.count {
            print("MODERN-AUTONO-RESIDUAL \(document): the view lays \(pages.count) pages, the engine \(furniture.count) — numbers compared on the pages both laid")
        }

        var wrong: [String] = []
        for (index, sheet) in furniture.enumerated() {
            guard pages.indices.contains(index) else { continue }
            let drawn = pages[index].autoPageNumber
            guard let engine = sheet.autoPageNumber else {
                // The engine withheld a number for this page; the view must not draw one.
                if let drawn {
                    wrong.append("p\(index + 1): the view draws \"\(drawn.text)\" where the engine draws none")
                }
                continue
            }
            guard let drawn else {
                wrong.append("p\(index + 1): the view draws no number where the engine draws \"\(engine.text)\"")
                continue
            }
            if drawn.text != engine.text {
                wrong.append("p\(index + 1): text \"\(drawn.text)\", the engine \"\(engine.text)\"")
            }
            if abs(drawn.x - engine.x) >= 0.01 {
                wrong.append("p\(index + 1): x \(drawn.x), the engine \(engine.x)")
            }
            // The furniture's y is a baseline up from the sheet's foot; the view positions from the top.
            let wantBaseline = sheet.sheetHeight - engine.y
            if abs(drawn.baselineFromTop - wantBaseline) >= 0.01 {
                wrong.append("p\(index + 1): baseline \(drawn.baselineFromTop) from the top, the engine's \(wantBaseline)")
            }
            if index == 0 {
                print("MODERN-AUTONO \(document) p1: \"\(drawn.text)\" x \(drawn.x) baseline \(drawn.baselineFromTop) \(drawn.fontName) \(drawn.size)pt; the engine x \(engine.x) y \(engine.y)")
            }
        }
        #expect(wrong.isEmpty, "\(document): \(wrong.joined(separator: "; "))")
    }
}
