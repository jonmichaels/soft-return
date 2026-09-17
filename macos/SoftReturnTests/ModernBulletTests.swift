import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 47 (M27, Jon: Modern's ■ bullets render far larger than Native's and Printed's, and the text after them sits too
/// close): on -README.WS (Sawyer's list markers) the ■ drawn in Modern is Native's square — the same ink width and
/// height — and it is still the character ■ in the text. The next word sits Native's distance past it (E8, engine ac9ddd6). Measured from the drawn page: the first
/// three bullets' ink columns in a 70 pt strip. Before: Native 5.0 pt of ink and 9.0 pt to the next word; Modern 8.5 pt
/// and 2.5 pt (b47-m27-probe). Renders: m27-readme-<Native|Modern>-bullet<n>.png.
@Suite("Modern's square bullets (M27)", .serialized)
@MainActor
struct ModernBulletTests {
    struct Bullet { let width: CGFloat; let height: CGFloat; let gap: CGFloat }

    static func bullets(_ style: ViewStyle, url: URL) throws -> [Bullet] {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ModernBulletTests.\(UUID().uuidString)")!)
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: settings, docPath: url.path)
        state.style.setManually(style)
        let rendered = DocumentRenderer.render(state, style: style.renderStyle)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let string = rendered.text.string as NSString
        var bullets: [Bullet] = []
        var search = NSRange(location: 0, length: string.length)
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        while bullets.count < 3 {
            let found = string.range(of: "\u{25A0}", options: [], range: search)
            guard found.location != NSNotFound else { break }
            search = NSRange(location: found.location + 1, length: string.length - found.location - 1)
            guard let page = view.pageViews.first(where: { tv in
                guard let m = tv.layoutManager, let c = tv.textContainer else { return false }
                return NSLocationInRange(m.glyphIndexForCharacter(at: found.location), m.glyphRange(for: c))
            }), let manager = page.layoutManager, let container = page.textContainer else { continue }
            let glyph = manager.glyphIndexForCharacter(at: found.location)
            let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                .offsetBy(dx: page.frame.minX, dy: page.frame.minY)
            let region = NSRect(x: box.minX - 4, y: box.minY - 6, width: 70, height: box.height + 12)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: region))
            view.cacheDisplay(in: region, to: rep)
            let scale = CGFloat(rep.pixelsWide) / region.width
            var inkColumns: [Int] = []
            var squareRows = (Int.max, -1)
            for x in 0..<rep.pixelsWide {
                var dark = false
                for y in 0..<rep.pixelsHigh {
                    if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5, color.brightnessComponent < 0.5 { dark = true }
                }
                if dark { inkColumns.append(x) }
            }
            var runs: [(Int, Int)] = []
            for x in inkColumns { if let last = runs.last, x == last.1 + 1 { runs[runs.count - 1].1 = x } else { runs.append((x, x)) } }
            guard runs.count >= 2 else { continue }
            for x in runs[0].0...runs[0].1 {
                for y in 0..<rep.pixelsHigh {
                    if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5, color.brightnessComponent < 0.5 {
                        squareRows = (min(squareRows.0, y), max(squareRows.1, y))
                    }
                }
            }
            let bullet = Bullet(width: CGFloat(runs[0].1 - runs[0].0 + 1) / scale,
                                height: CGFloat(squareRows.1 - squareRows.0 + 1) / scale,
                                gap: CGFloat(runs[1].0 - runs[0].1 - 1) / scale)
            bullets.append(bullet)
            let png = proofs.appendingPathComponent("m27-readme-\(style.displayName)-bullet\(bullets.count).png")
            _ = try RenderProbeKit.renderPNG(view: view, rect: region, appearance: NSAppearance(named: .aqua)!, to: png)
            // Still the character.
            #expect((rendered.text.string as NSString).substring(with: found) == "\u{25A0}")
        }
        return bullets
    }

    @Test(.enabled(if: PrivateCorpusSupport.sawyerArchiveRoot != nil, "needs the Sawyer archive (CTRLKD_SAWYER_ARCHIVE)"))
    func modernBulletsAreNativesSquares() throws {
        let url = try #require(PrivateCorpusSupport.sawyerArchiveRoot).appendingPathComponent("-README.WS")
        let native = try Self.bullets(.native, url: url)
        let modern = try Self.bullets(.modern, url: url)
        print("M27 Native: \(native.map { "ink \($0.width)×\($0.height) gap \($0.gap)" })")
        print("M27 Modern: \(modern.map { "ink \($0.width)×\($0.height) gap \($0.gap)" })")
        try #require(native.count == 3 && modern.count == 3)
        for (n, m) in zip(native, modern) {
            #expect(abs(m.width - n.width) <= 0.6, "Modern's square is \(m.width) pt wide, Native's \(n.width)")
            #expect(abs(m.height - n.height) <= 0.6, "Modern's square is \(m.height) pt tall, Native's \(n.height)")
            // E8 (engine ac9ddd6): the space after a list's ■ is one cell in the library's Modern layout, so the next word
            // sits where Native puts it.
            #expect(abs(m.gap - n.gap) <= 1.0, "Modern's next word is \(m.gap) pt from the square, Native's \(n.gap)")
        }
    }
}
