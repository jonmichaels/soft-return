import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 48b (E11, engine b86d214): a running head, foot or automatic page number whose resolved baseline is below the
/// sheet is published flagged (`HeadFootLine.offSheet`, `AutoPageNumber.offSheet`). The engine's PDF still writes it
/// there — WordStar 7 commands it and the paper clips it — and a view, which has no paper, must not draw it. Three
/// documents carry one: FORMFEED.WS page 5's automatic number (y −144 on its landscape sheet), PAGE.RND page 1's
/// (y −21.6), and MICKEE.WS page 23's footer (y −7.2). For each: the engine flags that row; Native's page has no line of
/// that kind drawn below its sheet and none for the flagged row; and Native's PDF page reads exactly the lines the
/// engine's PDF puts on the sheet. Renders e11-<doc>-p<n>-foot.png.
@Suite(.serialized)
@MainActor
struct NativeOffSheetRowsTests {
    struct Case: Sendable, CustomStringConvertible {
        let path: String
        let page: Int
        let number: Bool
        var description: String { "\(path) p\(page)" }
    }

    nonisolated static let cases = [
        Case(path: "ARTICLES/FORMFEED.WS", page: 5, number: true),
        Case(path: "LSRBOX/PAGE.RND", page: 1, number: true),
        Case(path: "MICKEE/MICKEE.WS", page: 23, number: false),
    ]

    @Test(.enabled(if: PrivateCorpusSupport.sawyerArchiveRoot != nil, "needs the Sawyer archive (CTRLKD_SAWYER_ARCHIVE)"),
          arguments: cases)
    func aRowOffTheSheetIsNotDrawn(_ fixture: Case) throws {
        let url = try #require(PrivateCorpusSupport.sawyerArchiveRoot).appendingPathComponent(fixture.path)
        let defaults = try #require(UserDefaults(suiteName: "NativeOffSheetRows.\(UUID().uuidString)"))
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)),
                                      settings: SettingsStore(defaults: defaults), docPath: url.path)
        let options = DocumentRenderer.nativeEngineOptions(state)
        let pages = docToPagelines(printedDocument(state.document, options: options), printed: true)
        try #require(pages.count >= fixture.page)
        let page = pages[fixture.page - 1]
        let flaggedNumber = page.autoPageno?.offSheet == true
        let flaggedFeet = (page.footerLines ?? []).filter(\.offSheet)
        let flagged = Oracle.offSheetRows(state.document, options: options)
        print("E11 \(fixture): engine flags number \(flaggedNumber), feet \(flaggedFeet.map { ($0.text, $0.y) }); pages with flagged rows \(flagged)")
        if fixture.number {
            #expect(flaggedNumber, "the engine does not flag \(fixture)'s page number")
        } else {
            #expect(!flaggedFeet.isEmpty, "the engine does not flag a foot on \(fixture)")
        }

        let rendered = DocumentRenderer.render(state, style: .native)
        try #require(rendered.runningLines.count >= fixture.page)
        let sheet = rendered.pageSize(atPage: fixture.page - 1)
        let drawn = rendered.runningLines[fixture.page - 1]
        print("E11 \(fixture): Native draws \(drawn.map { "\($0.kind) \($0.text.string.debugDescription) at \($0.baselineFromTop)" }) on a \(sheet) sheet")
        #expect(drawn.allSatisfy { $0.baselineFromTop <= Double(sheet.height) }, "a running line is drawn below the sheet")
        if fixture.number {
            #expect(!drawn.contains { $0.kind == .autoPageNumber }, "the flagged page number is drawn")
        } else {
            let onSheetFeet = (page.footerLines ?? []).filter { !$0.offSheet }.count
            #expect(drawn.filter { $0.kind == .footer }.count <= onSheetFeet, "a flagged foot is drawn")
        }

        let printed = emitPDF(state.document, mode: .printed, options: options)
        let native = try #require(try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .native, viewStyle: .native, title: url.lastPathComponent, docPath: url.path).first?.bytes)
        let engineLines = try AppModernFidelityTests.lines(of: printed, offSheet: flagged)
        let engineAll = try AppModernFidelityTests.lines(of: printed)
        let appLines = try AppModernFidelityTests.lines(of: native)
        try #require(engineLines.count >= fixture.page && appLines.count >= fixture.page)
        let want = engineLines[fixture.page - 1].filter { !Oracle.EngineText.isAllGeometry($0) }
        let got = appLines[fixture.page - 1].filter { !Oracle.EngineText.isAllGeometry($0) }
        print("E11 \(fixture): engine PDF \(engineAll[fixture.page - 1].count) lines, \(engineLines[fixture.page - 1].count) on the sheet; Native \(appLines[fixture.page - 1].count)")
        #expect(got.count == want.count, "\(fixture): Native draws \(got.count) lines, the engine \(want.count) on the sheet")

        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let rect = view.rect(ofPage: fixture.page - 1)
        let foot = NSRect(x: rect.minX, y: rect.maxY - 90, width: rect.width, height: 90)
        let name = (url.lastPathComponent as NSString).deletingPathExtension.lowercased()
        let png = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs").appendingPathComponent("e11-\(name)-p\(fixture.page)-foot.png")
        #expect(try RenderProbeKit.renderPNG(view: view, rect: foot, appearance: NSAppearance(named: .aqua)!, to: png) > 0)
        print("PROOF: \(png.path)")
    }
}
