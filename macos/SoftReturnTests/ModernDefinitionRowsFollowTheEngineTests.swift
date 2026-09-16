import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (E): the Modern view hangs exactly the rows the engine calls definition-list rows. Engine c7bd094 and 591068d:
/// a `word:  description` row is a def row only when another row in the same block starts its own label at the same
/// column, and at least two different labels appear at that column in the run. REF/BOOKLET.WS's 37 "Space:" paragraphs
/// are therefore ordinary prose; VERSIONS.WS (13 rows) and CONVERT.WS (3) keep theirs. The row structure is the engine's
/// own (`modernSemanticFlow` → `classifyRows`); this holds the app's rendering of it. Page 1 of each, Modern:
/// b41-e-<document>-modern-p1.png.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct ModernDefinitionRowsFollowTheEngineTests {
    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: ["REF/BOOKLET.WS", "VERSIONS.WS", "CONVERT.WS"])
    func hangingRowsAreTheEnginesDefinitionRows(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)

        // The engine's def rows: each one's own label, colon included (`RowStructure.label`).
        var labels: [String] = []
        for item in modernSemanticFlow(state.document).items {
            guard case .para(_, _, _, _, _, let structure, _, _) = item,
                  let structure, structure.kind == .def else { continue }
            let label: String = (structure.label ?? "").trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { labels.append(label) }
        }

        let rendered = DocumentRenderer.render(state, style: .modern)
        let string = rendered.text.string as NSString
        func hang(at location: Int) -> CGFloat {
            guard let style = rendered.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            else { return 0 }
            return style.headIndent - style.firstLineHeadIndent
        }

        // The view holds a token together across its backslashes with U+2060 WORD JOINER, which has no glyph
        // (`DocumentRenderer.modernNoBreakGraphicRuns`: "C:\WS\DEFAULT:" stays whole, as in the engine), so labels are
        // looked for in the text without it and mapped back to the view's own index.
        var visibleUnits: [unichar] = []
        var viewIndex: [Int] = []
        for index in 0..<string.length where string.character(at: index) != 0x2060 {
            visibleUnits.append(string.character(at: index))
            viewIndex.append(index)
        }
        let visible = String(utf16CodeUnits: visibleUnits, count: visibleUnits.count) as NSString

        var unhungDefRows: [String] = []
        var searchFrom = 0
        for label in labels {
            let range = visible.range(of: label, range: NSRange(location: searchFrom, length: visible.length - searchFrom))
            guard range.location != NSNotFound else {
                unhungDefRows.append("\(label) (not found in the view)")
                continue
            }
            searchFrom = NSMaxRange(range)
            if hang(at: viewIndex[range.location]) <= 1 { unhungDefRows.append(label) }
        }

        // Every paragraph opening "Space:" — BOOKLET.WS's filler — and whether the view hangs it.
        var spaceParagraphs = 0
        var hungSpaceParagraphs = 0
        var cursor = 0
        while cursor < string.length {
            let range = string.range(of: "Space:", range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound else { break }
            let paragraph = string.paragraphRange(for: range)
            let opening = string.substring(with: NSRange(location: paragraph.location,
                                                         length: max(0, range.location - paragraph.location)))
            if opening.trimmingCharacters(in: .whitespaces).isEmpty {
                spaceParagraphs += 1
                if hang(at: range.location) > 1 { hungSpaceParagraphs += 1 }
            }
            cursor = NSMaxRange(range)
        }

        print("MODERN-DEFROWS \(document): the engine's def rows \(labels.count) \(Array(labels.prefix(4))); unhung in the view \(unhungDefRows); \"Space:\" paragraphs \(spaceParagraphs), hung \(hungSpaceParagraphs)")
        switch document {
        case "REF/BOOKLET.WS":
            #expect(labels.isEmpty, "the engine reads def rows in BOOKLET.WS: \(labels)")
            #expect(spaceParagraphs >= 37, "only \(spaceParagraphs) \"Space:\" paragraphs found in the Modern view")
            #expect(hungSpaceParagraphs == 0, "\(hungSpaceParagraphs) \"Space:\" paragraphs hang in the Modern view")
        case "VERSIONS.WS":
            #expect(labels.count == 13, "the engine reads \(labels.count) def rows in VERSIONS.WS")
        case "CONVERT.WS":
            #expect(labels.count == 3, "the engine reads \(labels.count) def rows in CONVERT.WS")
        default:
            break
        }
        #expect(unhungDefRows.isEmpty, "\(document): def rows the Modern view does not hang: \(unhungDefRows)")
        try InvisiblesDesignPassTests.photograph(
            rendered: rendered, page: 0,
            name: "b41-e-\(document.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-"))-modern-p1.png")
    }
}
