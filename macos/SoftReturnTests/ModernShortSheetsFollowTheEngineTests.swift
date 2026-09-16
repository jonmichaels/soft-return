import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (B): a document that declares a short sheet is laid on it in the Modern view. MAILLIST/ENVELOPE.LST and
/// DEFAULT/OPTIONS/ENVELOPE.LST declare a 4.17in page (`.pl`, the engine's RTF `\paperh6005`): the engine's Modern page
/// is 612x300 with a 167.8pt top margin and a 36pt bottom one (`modernPageFurniture`), where the view laid them on a
/// full Letter sheet. Sheet, text frame and page count, view against engine; page 1 of each, Modern:
/// b41-b-<document>-modern-p1.png.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct ModernShortSheetsFollowTheEngineTests {
    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: ["MAILLIST/ENVELOPE.LST", "DEFAULT/OPTIONS/ENVELOPE.LST"])
    func aShortSheetIsTheEnginesShortSheet(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let furniture = modernPageFurniture(state.document)
        let engine = try #require(furniture.first, "\(document): the engine lays no Modern page")
        let rendered = DocumentRenderer.render(state, style: .modern)
        let pages = ModernPageFurnitureProbe.pages(state)
        let page = try #require(pages.first, "\(document): the Modern view laid out no page")
        print("MODERN-SHORT \(document): engine \(furniture.count) pages sheet \(engine.sheetWidth)x\(engine.sheetHeight) top \(engine.marginTop) bottom \(engine.marginBottom) width \(engine.textWidth); view \(pages.count) pages, sheet \(NSStringFromSize(rendered.pageSize)) frame \(NSStringFromRect(rendered.textFrame))")
        #expect(engine.sheetHeight < 400, "\(document): the engine's sheet is \(engine.sheetHeight)pt tall — not the short sheet this test is about")
        #expect(abs(Double(page.sheet.width) - engine.sheetWidth) < 0.01, "\(document): sheet width \(page.sheet.width)")
        #expect(abs(Double(page.sheet.height) - engine.sheetHeight) < 0.01, "\(document): sheet height \(page.sheet.height)")
        #expect(abs(Double(rendered.textFrame.minX) - engine.marginLeft) < 0.01, "\(document): text frame x \(rendered.textFrame.minX)")
        #expect(abs(Double(rendered.textFrame.minY) - engine.marginTop) < 0.01, "\(document): text frame y \(rendered.textFrame.minY)")
        #expect(abs(Double(rendered.textFrame.width) - engine.textWidth) < 0.01, "\(document): text frame width \(rendered.textFrame.width)")
        let wantHeight = engine.sheetHeight - engine.marginTop - engine.marginBottom
        #expect(abs(Double(rendered.textFrame.height) - wantHeight) < 0.01, "\(document): text frame height \(rendered.textFrame.height), the engine's \(wantHeight)")
        let stem = document.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        try InvisiblesDesignPassTests.photograph(rendered: rendered, page: 0, name: "b41-b-\(stem)-modern-p1.png")
    }
}
