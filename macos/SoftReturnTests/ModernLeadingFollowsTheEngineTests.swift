import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 41 (leading): Modern sets a document at the engine's own line-to-line advance.
///
/// Both sides already agree on the RULE — the app pins `size * modernLibraryLineFactor` (1.2) as an absolute
/// min == max leading, the engine advances `modernLine * pt` (also 1.2) — and neither reads `.lh` in Modern, as the
/// paged-surface doctrine requires (vertical space is Printed only). Measured from the engine's own Modern PDF, by
/// walking its content stream and tracking the type size in force at each positioning operator:
///
///   REF/BOOKLET.WS  16.8pt steps on 14pt text   (1.2 x 14), one 13.2 step on 11pt (1.2 x 11)
///   REF/BOOKLET.RJS 14.4pt steps on 12pt text   (1.2 x 12)
///   PRINT.TST       14.4pt steps                (1.2 x 12)
///
/// So where the view's advance differs, the difference is in the BODY SIZE it chose, not in the leading rule. This
/// holds the view's real baseline step to the engine's and prints the body size beside it, which is what says which
/// of the two is adrift. It is the item that has to land BEFORE the columns commit: a column whose lines are taller
/// than the engine's cannot hold what the engine's own column ranges put in it, whatever the mapping says.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct ModernLeadingFollowsTheEngineTests {
    /// The engine's own Modern baseline step, measured from its Modern PDF (see the suite's note).
    static let engineSteps: [String: Double] = [
        "REF/BOOKLET.WS": 16.8, "REF/BOOKLET.RJS": 14.4, "PRINT.TST": 14.4,
    ]

    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason),
          arguments: ["REF/BOOKLET.WS", "REF/BOOKLET.RJS", "PRINT.TST"])
    func modernAdvancesTheLineAsTheEngineDoes(document: String) throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent(document)
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let host = PagedDocumentView()
        host.setContent(rendered, display: .continuousScroll)
        host.setFrameSize(host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()

        // Page 1's first column, line fragment by line fragment: the step between consecutive fragment tops IS the
        // advance, because Modern pins minimumLineHeight == maximumLineHeight.
        let container = try #require(host.containers.first, "\(document): the view laid out no container")
        let glyphs = host.layoutManager.glyphRange(for: container)
        var tops: [CGFloat] = []
        host.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            tops.append(used.minY)
        }
        // A COLLAPSED BLANK IS NOT A LINE ADVANCE. `RenderedDocument.modernBlankLineRanges` gives a blank at a
        // page top a hairline's height (0.01pt), and on REF/BOOKLET.RJS there are more hairlines than body lines
        // on page 1 — 17 of them against 3 real advances — so the commonest step is a hairline and comparing it
        // to the engine's 14.4 would fail a document that in fact agrees exactly. Sub-point steps are dropped.
        let steps = zip(tops, tops.dropFirst()).map { Double(($1 - $0).rounded(toPlaces: 2)) }.filter { $0 > 1 }
        let common = Dictionary(grouping: steps, by: { $0 }).mapValues(\.count)
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }

        // The body size the view actually set, by the commonest point size over the first stretch of body text.
        var sizes: [Double: Int] = [:]
        let scan = NSRange(location: 0, length: min(4000, rendered.text.length))
        rendered.text.enumerateAttribute(.font, in: scan, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizes[Double(font.pointSize), default: 0] += range.length
        }
        let bodySize = sizes.sorted { $0.value > $1.value }.first?.key ?? 0
        let engine = Self.engineSteps[document] ?? 0
        print("MODERN-LEADING \(document): view step \(common.prefix(4).map { "\($0.key)x\($0.value)" }.joined(separator: " ")); view body \(bodySize)pt; the engine's step \(engine) (its rule and the view's are both 1.2x, so a difference here is a BODY SIZE difference: the engine's implied size is \(engine / 1.2))")

        let step = try #require(common.first?.key, "\(document): the view laid out no line steps")
        #expect(abs(step - engine) < 0.05,
                "\(document): the view advances \(step)pt a line where the engine advances \(engine)pt — the view's body is \(bodySize)pt against the engine's implied \(engine / 1.2)pt")
    }

    /// Batch 41: WHY a Modern column holds less than the engine puts in it — measured, not reasoned about.
    ///
    /// The leading and the body size are settled (the test above): both sides advance 16.8pt a line on a 14pt
    /// body for REF/BOOKLET.WS, and the column width already matches the engine's 345.6pt. So a column that took
    /// 872 characters where the engine's range ends at 1675 differs by neither. What is left is the container's
    /// own HEIGHT, and what the view does with it: this prints each column container's real height beside the
    /// engine's text height for that page, the lines each container actually placed against what its height
    /// could hold, and whether a later column starts from the frame's top or inherits the first column's fill.
    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason))
    func aColumnsContainerIsTheEnginesTextHeight() throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent("REF/BOOKLET.WS")
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let host = PagedDocumentView()
        host.setContent(rendered, display: .continuousScroll)
        host.setFrameSize(host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()

        let furniture = modernPageFurniture(state.document, options: DocumentRenderer.modernEngineOptions(state))
        let sheet = try #require(furniture.first, "BOOKLET.WS: the engine lays no Modern page")
        let engineTextHeight = sheet.sheetHeight - sheet.marginTop - sheet.marginBottom
        let step = 16.8
        print("MODERN-COLHEIGHT BOOKLET.WS: engine sheet \(sheet.sheetHeight) top \(sheet.marginTop) bottom \(sheet.marginBottom) -> text height \(engineTextHeight), capacity \(engineTextHeight / step) lines at \(step)pt")
        print("MODERN-COLHEIGHT BOOKLET.WS: the view's own textFrame height \(rendered.textFrame.height), pageSize \(NSStringFromSize(rendered.pageSize))")

        for slot in host.containers.indices where host.containerPage.indices.contains(slot) && host.containerPage[slot] == 0 {
            let container = host.containers[slot]
            let glyphs = host.layoutManager.glyphRange(for: container)
            let chars = host.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var placed = 0
            var firstTop: CGFloat = -1
            var lastBottom: CGFloat = -1
            host.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                if firstTop < 0 { firstTop = used.minY }
                lastBottom = used.maxY
                placed += 1
            }
            let column = host.containerColumn.indices.contains(slot) ? host.containerColumn[slot] : -1
            print("MODERN-COLHEIGHT BOOKLET.WS p1 column \(column): container height \(container.size.height) (capacity \(Double(container.size.height) / step) lines), placed \(placed) lines, chars \(chars.location)..<\(NSMaxRange(chars)), fragments from \(firstTop) to \(lastBottom)")
        }
        #expect(abs(Double(rendered.textFrame.height) - engineTextHeight) < 0.01,
                "BOOKLET.WS: the view's text frame is \(rendered.textFrame.height)pt where the engine's is \(engineTextHeight)pt")
    }

    /// Batch 41: WHICH RULE closes a column short. Measured on the tree that carries the engine's ranges.
    ///
    /// The container is the right height (the test above: 482.4pt, 28.7 lines' capacity) and stops after 13.
    /// Something forces it. There are four candidates and this names the one that fires, rather than assuming:
    ///
    ///   * the pending forced break (`modernForcedPageBreakOffsets` → `chain.pendingBreaks`), which is the
    ///     stored form feed — measured at 1091 on the old path, and the one the engine ABSORBS inside `.co`;
    ///   * a `.cp` (`modernConditionalBreaks`) whose requested lines do not fit;
    ///   * the blank collapse at a page top (`modernBlankLineRanges`);
    ///   * and the one easy to overlook: `BreakingTextContainer` refuses layout at
    ///     `characterIndex >= forcedBreakOffset`, so a container given ANY break offset truncates hard there —
    ///     if the engine's own boundary is set and the container still stops earlier, the cause is upstream of
    ///     all three rules.
    ///
    /// It also states whether the engine-range path is the one deciding at all: `modernColumnBreaks` must be
    /// non-empty for this document, or the view is still paginating for itself and every number below is about
    /// the old path.
    @Test(.enabled(if: NativeRunningLinesFollowTheEngineTests.sawyer != nil, NativeRunningLinesFollowTheEngineTests.skipReason))
    func whichRuleClosesAColumnShort() throws {
        let url = try #require(NativeRunningLinesFollowTheEngineTests.sawyer).appendingPathComponent("REF/BOOKLET.WS")
        let state = try NativeRunningLinesFollowTheEngineTests.state(url)
        let rendered = DocumentRenderer.render(state, style: .modern)

        print("MODERN-WHYSHORT BOOKLET.WS: modernColumnBreaks pages \(rendered.modernColumnBreaks.count) — \(rendered.modernColumnBreaks.isEmpty ? "EMPTY, so the view is still paginating for itself" : "the engine-range path is live")")
        for (page, breaks) in rendered.modernColumnBreaks.prefix(3).enumerated() {
            print("MODERN-WHYSHORT BOOKLET.WS p\(page + 1) engine boundaries: \(breaks.map { "col \($0.column) -> \($0.end.map(String.init) ?? "end")" }.joined(separator: " | "))")
        }
        print("MODERN-WHYSHORT BOOKLET.WS rules in play: forcedPageBreaks \(rendered.modernForcedPageBreakOffsets), conditionalBreaks \(rendered.modernConditionalBreaks.map(\.charOffset)), blankRanges \(rendered.modernBlankLineRanges.map(\.location).prefix(8))")

        let host = PagedDocumentView()
        host.setContent(rendered, display: .continuousScroll)
        host.setFrameSize(host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()
        for slot in host.containers.indices.prefix(4) {
            let container = host.containers[slot]
            let glyphs = host.layoutManager.glyphRange(for: container)
            let chars = host.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // `BreakingTextContainer` is file-private to `PagedDocumentView.swift`, so a test cannot name the
            // type. Read the offset reflectively rather than widen production access for a diagnostic.
            let forced = Mirror(reflecting: container).children
                .first { $0.label == "forcedBreakOffset" }
                .flatMap { $0.value as? Int }
            let page = host.containerPage.indices.contains(slot) ? host.containerPage[slot] : -1
            let column = host.containerColumn.indices.contains(slot) ? host.containerColumn[slot] : -1
            // Lines and extent, not just characters: a container that stops EARLY and one that is nearly FULL
            // but sets fewer characters per line look identical in a character range and are different faults.
            // The engine puts ~1675 characters in this column; the view puts ~872. If the view's fragments fill
            // the 482.4pt box, the difference is characters PER LINE (width, justification, the measure the
            // text is set to) and not the column stopping short at all.
            var placed = 0
            var firstTop: CGFloat = -1
            var lastBottom: CGFloat = -1
            host.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                if firstTop < 0 { firstTop = used.minY }
                lastBottom = used.maxY
                placed += 1
            }
            let charsPerLine = placed > 0 ? Double(chars.length) / Double(placed) : 0
            print("MODERN-WHYSHORT container \(slot) (p\(page + 1) col \(column)): width \(container.size.width), height \(container.size.height), forcedBreakOffset \(forced.map(String.init) ?? "nil"), chars \(chars.location)..<\(NSMaxRange(chars)), lines \(placed), extent \(firstTop)..\(lastBottom) of \(container.size.height), chars/line \(String(format: "%.1f", charsPerLine))")
        }
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10.0, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
