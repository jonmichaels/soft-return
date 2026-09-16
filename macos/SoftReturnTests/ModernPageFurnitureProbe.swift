import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
@testable import SoftReturn

/// Batch 41 scaffold (A, B, C, F, G): the Modern view's page furniture as the Mac draws it — each page's sheet, its text
/// columns, its running heads and feet, and its automatic page number — for the tests that hold it to the engine's
/// `modernPageFurniture`. Reads the laid-out view only; works nothing out for itself.
@MainActor
enum ModernPageFurnitureProbe {
    struct Column: CustomStringConvertible {
        let x: Double
        let width: Double
        let top: Double
        var description: String { String(format: "x %.1f w %.1f top %.1f", x, width, top) }
    }

    struct RunningLine: CustomStringConvertible {
        let text: String
        let x: Double
        let baselineFromTop: Double
        let fontName: String
        let size: Double
        let isHeader: Bool
        var description: String {
            String(format: "%@ \"%@\" x %.1f baseline %.1f %@ %.1f", isHeader ? "head" : "foot", text, x, baselineFromTop, fontName, size)
        }
    }

    struct Page: CustomStringConvertible {
        let index: Int
        let sheet: CGSize
        let columns: [Column]
        let runningLines: [RunningLine]
        /// The automatic page number the Modern view draws on this page — nil everywhere today (batch 41 C adds it).
        let autoPageNumber: RunningLine?
        var description: String {
            "p\(index + 1) sheet \(Int(sheet.width))x\(Int(sheet.height)) columns \(columns) lines \(runningLines)"
        }
    }

    /// `state` in the Modern view, laid out whole in Continuous Scroll (as print and export hold it), page by page.
    static func pages(_ state: DocumentState) -> [Page] {
        let rendered = DocumentRenderer.render(state, style: .modern)
        let host = PagedDocumentView()
        host.setContent(rendered, display: .continuousScroll)
        host.setFrameSize(host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()
        let textViews = host.subviews.compactMap { $0 as? NSTextView }
        let drawn = host.drawnRunningLines
        var pages: [Page] = []
        for index in 0..<host.pageCount {
            let sheet = host.rect(ofPage: index)
            let columns: [Column] = textViews
                .filter { $0.frame.intersects(sheet) && $0.textContainer != nil }
                .map { view in
                    Column(x: Double(view.frame.minX + view.textContainerOrigin.x - sheet.minX),
                           width: Double(view.textContainer?.size.width ?? 0),
                           top: Double(view.frame.minY + view.textContainerOrigin.y - sheet.minY))
                }
                .sorted { $0.x < $1.x }
            // HEADS AND FEET ONLY. The automatic page number rides a footer's row and item C appends it to the
            // same list, but the engine reports it apart from `footers` and so does the view
            // (`RunningLine.Kind.autoPageNumber`) — it is reported below in `autoPageNumber`, and counting it
            // here as well made PRINT.TST read "1 feet drawn, the engine draws 0" on every page.
            let lines: [RunningLine] = (drawn.indices.contains(index) ? drawn[index] : [])
                .filter { $0.kind != .autoPageNumber }
                .map { line in
                let font = line.text.length > 0 ? line.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                return RunningLine(text: line.text.string,
                                   x: Double(rendered.textFrame.origin.x) + line.leadingOffset + line.pageLeftOffset,
                                   baselineFromTop: line.baselineFromTop,
                                   fontName: font?.fontName ?? "?", size: Double(font?.pointSize ?? 0),
                                   isHeader: line.kind == .header)
            }
            // Batch 41 (C): the automatic page number is its own `RunningLine.Kind` now, so it is picked out by
            // what it IS rather than guessed at from its text — a document can carry a typed footer reading "1"
            // as well. The heads and feet above exclude it for the same reason.
            let auto = (drawn.indices.contains(index) ? drawn[index] : [])
                .first { $0.kind == .autoPageNumber }
                .map { line in
                    let font = line.text.length > 0 ? line.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                    return RunningLine(text: line.text.string,
                                       x: Double(rendered.textFrame.origin.x) + line.leadingOffset + line.pageLeftOffset,
                                       baselineFromTop: line.baselineFromTop,
                                       fontName: font?.fontName ?? "?", size: Double(font?.pointSize ?? 0),
                                       isHeader: false)
                }
            pages.append(Page(index: index, sheet: sheet.size, columns: columns, runningLines: lines, autoPageNumber: auto))
        }
        return pages
    }
}
