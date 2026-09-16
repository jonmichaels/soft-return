import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41: the Native view draws each running head and foot in the weight and slant the engine's Printed line carries.
/// The engine resolves a line's style-sheet baseline per page (`HeadFootLine.styleAttrs`, parity applied — REF/BOOKLET.WS's
/// "Header Odd"/"Header Even" styles are bold) and ORs it with whatever toggle bytes the line types (`hfLineOps`). Every
/// run the Native view draws carries at least the line's `styleAttrs`; a line with no toggle byte carries exactly them.
/// Heads draw no underline in Printed, so none is asked of Native. REF/BOOKLET.WS (bold), OLDTIMES.WS (plain) and every
/// Sawyer document with a head or foot. The top of BOOKLET.WS page 1, Native beside Printed:
/// b41-head-styles-booklet-native-vs-printed.png.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct NativeRunningLineStylesTests {
    /// One drawn run's weight and slant, read from its font's own traits.
    static func styles(of font: NSFont) -> Style {
        let traits = font.fontDescriptor.symbolicTraits
        var style: Style = []
        if traits.contains(.bold) { style.insert(.bold) }
        if traits.contains(.italic) { style.insert(.italic) }
        return style
    }

    /// Each run of `text` (by font) and the bold/italic it draws in.
    static func runStyles(_ text: NSAttributedString) -> [(text: String, style: Style)] {
        var runs: [(text: String, style: Style)] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let piece = (text.string as NSString).substring(with: range)
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            runs.append((piece, styles(of: font)))
        }
        return runs
    }

    /// Per page, the engine's head and foot lines with their resolved style, and the Native view's lines, paired by
    /// visible text (`NativeRunningLinesFollowTheEngineTests.Placement.key`). Returns the mismatches.
    static func mismatches(_ state: DocumentState) -> (checked: Int, styled: Int, failures: [String]) {
        let options = DocumentRenderer.nativeEngineOptions(state)
        let doc = printedDocument(state.document, options: options)
        let pages = docToPagelines(doc, printed: true, pixResults: options.pixResults, pictures: .embed)
        let rendered = DocumentRenderer.render(state, style: .native)
        var checked = 0
        var styled = 0
        var failures: [String] = []
        for (index, page) in pages.enumerated() {
            let engineLines: [HeadFootLine] = (page.headerLines ?? []) + (page.footerLines ?? [])
            var drawn: [RunningLine] = rendered.runningLines.indices.contains(index) ? rendered.runningLines[index] : []
            for line in engineLines {
                let key = NativeRunningLinesFollowTheEngineTests.Placement(text: line.text, x: 0, baselineFromTop: 0).key
                guard !key.isEmpty else { continue }
                guard let at = drawn.firstIndex(where: {
                    NativeRunningLinesFollowTheEngineTests.Placement(text: $0.text.string, x: 0, baselineFromTop: 0).key == key
                }) else {
                    failures.append("p\(index + 1) \"\(key)\": not drawn")
                    continue
                }
                let app = drawn.remove(at: at)
                let baseline = line.styleAttrs.intersection([.bold, .italic])
                let typesToggles = line.text.unicodeScalars.contains { $0.value < 0x20 }
                checked += 1
                if !baseline.isEmpty { styled += 1 }
                for run in runStyles(app.text) {
                    let missing = baseline.subtracting(run.style)
                    if !missing.isEmpty {
                        failures.append("p\(index + 1) \"\(run.text)\": draws \(run.style.rawValue), the engine's line \(baseline.rawValue)")
                    } else if !typesToggles, run.style != baseline {
                        failures.append("p\(index + 1) \"\(run.text)\": draws \(run.style.rawValue) with no toggle; the engine's line \(baseline.rawValue)")
                    }
                }
            }
        }
        return (checked, styled, failures)
    }

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: ["REF/BOOKLET.WS", "OLDTIMES.WS"])
    func headsAndFeetCarryTheEnginesStyle(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let result = Self.mismatches(state)
        print("NATIVE-HEAD-STYLES \(document): \(result.checked) lines, \(result.styled) with a style baseline; failures \(result.failures.prefix(6))")
        #expect(result.checked > 0, "\(document): no running line checked")
        switch document {
        case "REF/BOOKLET.WS": #expect(result.styled > 0, "BOOKLET.WS: the engine resolved no bold head")
        case "OLDTIMES.WS": #expect(result.styled == 0, "OLDTIMES.WS: the engine resolved a styled head")
        default: break
        }
        #expect(result.failures.isEmpty, "\(document): \(result.failures)")
        if document == "REF/BOOKLET.WS" {
            let rendered = DocumentRenderer.render(state, style: .native)
            try NativeSupSubRiseTests.writeComparison(state: state, rendered: rendered,
                                                      name: "b41-head-styles-booklet-native-vs-printed.png")
        }
    }

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason))
    func everySawyerHeadAndFootCarriesTheEnginesStyle() throws {
        let root = try #require(NativeRunningLinesFollowTheEngineTests.sawyer)
        var failures: [String] = []
        var lines = 0
        var styled = 0
        for url in try NativeRunningLinesFollowTheEngineTests.documentsWithHeadsOrFeet(under: root) {
            let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let state = try? NativeRunningLinesFollowTheEngineTests.state(url) else { continue }
            let result = Self.mismatches(state)
            lines += result.checked
            styled += result.styled
            print("NATIVE-HEAD-STYLES \(name): \(result.checked) lines, \(result.styled) styled, \(result.failures.count) failures")
            if !result.failures.isEmpty { failures.append("\(name): \(result.failures.prefix(3))") }
        }
        print("NATIVE-HEAD-STYLES: \(lines) lines, \(styled) with a style baseline")
        #expect(lines > 0)
        #expect(failures.isEmpty, "\(failures)")
    }
}
