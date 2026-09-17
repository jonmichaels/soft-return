import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 47 (M30, Jon: Modern clips the top line on some pages — -HOLYMAC.WS Modern pages 3 and 4): no glyph of a Modern
/// page's first line rises above the page's content top, and the fix moves no page break. Measured on every page of
/// -HOLYMAC.WS in Modern through the window's own `PagedDocumentView`: where the page's text view sits below its content
/// top, plus the first line's baseline in it, against the tallest ascender of its fonts. Before the fix pages 3 and 4 set Courier Prime Bold 14 pt (ascender 10.94) on a 6.74 pt baseline in an
/// 11.74 pt line: 5.75 pt of ink above the content top (b47-m30-probe). Render: m30-holymac-modern-page3-top.png.
@Suite("Modern's top line (M30)", .serialized)
@MainActor
struct ModernTopLineTests {
    /// The 4.5.0 release run's own case (PixelTruthMarginTests): `dropped-chapter.ws4` opens on six blank lines, which
    /// Modern collapses to a sliver at the page's top. The rise is measured from the first line that DRAWS, so a blank
    /// line never moves the page: its first ink sits where the container's own text starts, not 19 pt lower.
    @Test @MainActor func leadingBlankLinesDoNotMoveThePage() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ModernTopLineTests.\(UUID().uuidString)")!)
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: settings, docPath: url.path)
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let textView = try #require(view.pageViews.first)
        let rise = textView.frame.minY - (view.rect(ofPage: 0).minY + rendered.textFrame.origin.y)
        print("M30/4.5.0 dropped-chapter.ws4: the page's text sits \(rise) pt below its content top")
        #expect(abs(rise) <= 1, "leading blank lines moved the page \(rise) pt down")
    }

    @Test(.enabled(if: PrivateCorpusSupport.sawyerArchiveRoot != nil, "needs the Sawyer archive (CTRLKD_SAWYER_ARCHIVE)"))
    func noPageSetsInkAboveItsContentTop() throws {
        let url = try #require(PrivateCorpusSupport.sawyerArchiveRoot).appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ModernTopLineTests.\(UUID().uuidString)")!)
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: settings, docPath: url.path)
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        var over: [String] = []
        var checked = 0
        for (index, textView) in view.pageViews.enumerated() {
            guard let manager = textView.layoutManager, let container = textView.textContainer else { continue }
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }
            var line = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &line)
            let characters = manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
            let text = (rendered.text.string as NSString).substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var ascender: CGFloat = 0
            rendered.text.enumerateAttribute(.font, in: characters) { value, _, _ in
                if let font = value as? NSFont { ascender = max(ascender, font.ascender) }
            }
            let baseline = fragment.minY + manager.location(forGlyphAt: line.location).y
            let contentTop = view.rect(ofPage: index).minY
                + (rendered.perPageTextTop.indices.contains(index) ? CGFloat(rendered.perPageTextTop[index]) : rendered.textFrame.origin.y)
            let below = textView.frame.minY - contentTop
            let inkTop = below + baseline - ascender
            checked += 1
            if index == 2 || index == 3 {
                print("M30 page \(index + 1): \"\(text.prefix(40))\" text view \(below) pt below the content top, baseline \(baseline), ascender \(ascender), ink top \(inkTop)")
            }
            if inkTop < -0.5 { over.append("page \(index + 1): \(inkTop) pt (\"\(text.prefix(30))\")") }
        }
        print("M30: \(checked) Modern pages with a first line checked; ink above the content top on \(over.count)")
        #expect(checked > 100)
        #expect(over.isEmpty, "ink above the content top: \(over.prefix(10))")

        // The top of page 3 as drawn.
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let page3 = view.pageViews[2].frame
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let png = proofs.appendingPathComponent("m30-holymac-modern-page3-top.png")
        let rect = NSRect(x: 0, y: page3.minY - 40, width: view.bounds.width, height: 120)
        #expect(try RenderProbeKit.renderPNG(view: view, rect: rect, appearance: NSAppearance(named: .aqua)!, to: png) > 0)
        print("PROOF: \(png.path)")
    }
}
