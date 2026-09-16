import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 40 (M14, Jon: "It moves text AND things overlap all over the place. Show invisibles is pretty ugly right
/// now."): Show Invisibles in Native and Modern on -README.WS and BOXES.WS, measured and photographed.
///
/// The rules (Athena): invisibles MAY reflow (Jon's register E3), but marks never overlap text or each other, and each
/// kind of mark has one glyph and one colour. Measured on every page, in each page's own coordinates:
/// - ink boxes (a run's advance across, its face's ascender to descender down) of mark runs against text runs and
///   against other mark runs, on neighbouring lines as well as the same line — any overlap of more than a quarter of a
///   square point counts;
/// - running heads and feet drawn over the page's text lines (Native);
/// - Native lines whose height is not the lead their paragraph pins (a taller line pushes everything after it down,
///   past where the page's budget put it);
/// - the colours and faces each kind of mark is drawn in.
/// Pages 1 and 2 of each are photographed as the screen draws them: m14-<document>-<view>-p<N>.png.
@Suite(.tags(.corpus), .serialized)
@MainActor
struct InvisiblesDesignPassTests {
    // Read by the @Test macro outside the main actor, so not isolated to it.
    nonisolated static let documents = ["-README.WS", "BOXES.WS"]

    /// One glyph's ink, and the attribute run it belongs to.
    struct Box {
        let rect: CGRect
        let mark: Bool
        let kind: String
        let run: Int
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason),
          arguments: documents, [ViewStyle.native, .modern])
    func marksNeverOverlapTextOrEachOther(document: String, view style: ViewStyle) throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent(document)
        let state = try Oracle.state(for: url)
        state.style.setManually(style)
        state.showInvisibles = true
        let rendered = DocumentRenderer.renderWithInvisibles(state)
        let pages = PagedDocumentView(frame: .zero)
        pages.setContent(rendered, display: .continuousScroll)
        pages.setFrameSize(pages.intrinsicContentSize)
        pages.layoutSubtreeIfNeeded()

        var markOverText = 0, markOverMark = 0, headOverText = 0, offLeadLines = 0, lines = 0
        var examples: [String] = []
        var palette: [String: Set<String>] = [:]
        for (pageIndex, textView) in pages.pageViews.enumerated() {
            guard let manager = textView.layoutManager, let container = textView.textContainer,
                  let storage = textView.textStorage else { continue }
            var boxes: [Box] = []
            var runCount = 0
            let glyphs = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                lines += 1
                let characters = manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                if style == .native, characters.length > 0,
                   let paragraph = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle,
                   paragraph.maximumLineHeight > 0, abs(fragment.height - paragraph.maximumLineHeight) > 0.5 {
                    offLeadLines += 1
                    if examples.count < 12 {
                        examples.append("p\(pageIndex + 1) line \(fragment.height) pt against lead \(paragraph.maximumLineHeight): \(Self.snippet(storage, characters))")
                    }
                }
                storage.enumerateAttributes(in: characters) { attributes, range, _ in
                    let text = (storage.string as NSString).substring(with: range)
                    guard text.contains(where: { !$0.isWhitespace && !$0.isNewline && $0 != "\u{200B}" && $0 != "\u{2060}" }) else { return }
                    let runGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
                    let mark = attributes[.invisibleMarkRun] as? Bool == true
                    // Each glyph's own ink. Not the run's `boundingRect(forGlyphRange:)` — b40-m14-after printed a single
                    // "¶" 20.11 pt wide against its 7.2 pt advance and a run's box starting 7.6 pt left of its first glyph,
                    // so every mark beside a word "overlapped" it (M20 found the same box ending 5.7 pt past a last letter);
                    // not the face's ascender to descender, which for Courier Prime is 14.32 pt against Native's 12 pt
                    // lead; and not the run's ink unioned into one rectangle, which b40-m14-after3 showed spanning a whole
                    // line at its deepest descender over a "¶" on the next row.
                    let inks = Self.inks(of: runGlyphs, manager: manager, font: font)
                    guard !inks.isEmpty else { return }
                    runCount += 1
                    let kind = mark ? Self.kind(of: text) : "text"
                    for ink in inks {
                        boxes.append(Box(rect: ink, mark: mark, kind: kind, run: runCount))
                    }
                    if mark {
                        let colour = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB)
                        let description = colour.map { String(format: "%.2f/%.2f/%.2f/%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "none"
                        palette[kind, default: []].insert("\(description) \(font.fontName) \(font.pointSize)")
                    }
                }
            }
            // Counted per mark run: a mark over any text glyph counts once, and so does a pair of marks touching.
            let textBoxes: [Box] = boxes.filter { !$0.mark }
            let markBoxes: [Box] = boxes.filter { $0.mark }
            let markRuns: [Int: [Box]] = Dictionary(grouping: markBoxes, by: { box in box.run })
            let markRunIDs: [Int] = markRuns.keys.sorted()
            for (position, id) in markRunIDs.enumerated() {
                let mine: [Box] = markRuns[id] ?? []
                if let touch = Self.firstOverlap(mine, textBoxes) {
                    markOverText += 1
                    if examples.count < 12 {
                        examples.append("p\(pageIndex + 1) \(touch.0.kind) \(touch.0.rect) over \(touch.1.kind) \(touch.1.rect)")
                    }
                }
                for other in markRunIDs[(position + 1)...] {
                    let theirs: [Box] = markRuns[other] ?? []
                    if let touch = Self.firstOverlap(mine, theirs) {
                        markOverMark += 1
                        if examples.count < 12 {
                            examples.append("p\(pageIndex + 1) \(touch.0.kind) \(touch.0.rect) over \(touch.1.kind) \(touch.1.rect)")
                        }
                    }
                }
            }
            // Running heads and feet, where `drawRunningLines` puts them, against the page's text lines.
            if rendered.runningLines.indices.contains(pageIndex) {
                let textTop = textView.frame.minY - pages.rect(ofPage: pageIndex).minY
                for line in rendered.runningLines[pageIndex] {
                    let height = max(1, line.text.size().height)
                    let head = CGRect(x: 0, y: line.baselineFromTop - line.drawOriginOffset, width: rendered.pageSize.width, height: height)
                    for box in boxes where !box.mark {
                        let onPage = box.rect.offsetBy(dx: textView.frame.minX, dy: textTop)
                        let overlap = onPage.intersection(head)
                        if !overlap.isNull, overlap.width * overlap.height > 0.25 { headOverText += 1 }
                    }
                }
            }
        }
        let paletteText = palette.keys.sorted().map { "\($0): \(palette[$0]!.sorted())" }.joined(separator: "; ")
        print("M14-INVISIBLES \(document) \(style.displayName): \(pages.pageCount) pages, \(lines) lines; marks over text \(markOverText), marks over marks \(markOverMark), running lines over text \(headOverText), Native lines off their lead \(offLeadLines); marks drawn as \(paletteText); e.g. \(examples)")
        for index in 0..<min(2, pages.pageCount) {
            try Self.photograph(rendered: rendered, page: index, name: "m14-\(document.replacingOccurrences(of: ".", with: "-"))-\(style.displayName.lowercased())-p\(index + 1).png")
        }

        #expect(markOverText == 0, "\(document) \(style.displayName): \(markOverText) marks over text")
        #expect(markOverMark == 0, "\(document) \(style.displayName): \(markOverMark) marks over marks")
        #expect(headOverText == 0, "\(document) \(style.displayName): \(headOverText) running lines over text")
        #expect(offLeadLines == 0, "\(document) \(style.displayName): \(offLeadLines) lines off their lead")
        #expect(palette.values.allSatisfy { $0.count == 1 }, "\(document) \(style.displayName): a kind of mark is drawn more than one way: \(paletteText)")
    }

    /// Each of `glyphs`' drawn bounds in `font`, placed where the glyph is set, in the container's coordinates; glyphs
    /// that draw nothing are left out.
    static func inks(of glyphs: NSRange, manager: NSLayoutManager, font: NSFont) -> [CGRect] {
        var rects: [CGRect] = []
        for glyph in glyphs.location..<NSMaxRange(glyphs) where !manager.notShownAttribute(forGlyphAt: glyph) {
            var cgGlyph = manager.cgGlyph(at: glyph)
            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &cgGlyph, &bounds, 1)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = manager.location(forGlyphAt: glyph)
            let glyphBaseline = line.minY + location.y
            rects.append(CGRect(x: line.minX + location.x + bounds.minX, y: glyphBaseline - bounds.maxY,
                                width: bounds.width, height: bounds.height))
        }
        return rects
    }

    /// The first pair, one glyph from each list, whose ink overlaps by more than a quarter of a square point.
    static func firstOverlap(_ these: [Box], _ those: [Box]) -> (Box, Box)? {
        for a in these {
            for b in those {
                let overlap = a.rect.intersection(b.rect)
                if !overlap.isNull, overlap.width * overlap.height > 0.25 { return (a, b) }
            }
        }
        return nil
    }

    /// A mark's kind, from its text.
    static func kind(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "¶": return "hard return"
        case "↵", "¬": return "soft return"
        default:
            if trimmed.hasPrefix("—") { return "page break" }
            if trimmed.hasPrefix(".") { return "dot command" }
            if trimmed.hasPrefix("^") { return "style toggle" }
            if trimmed.hasPrefix("[") { return "tag" }
            return "other"
        }
    }

    static func snippet(_ storage: NSTextStorage, _ range: NSRange) -> String {
        String((storage.string as NSString).substring(with: range).prefix(40))
    }

    /// One page as the screen draws it, Single Page, at 2x, to the temporary proofs folder.
    static func photograph(rendered: RenderedDocument, page: Int, name: String) throws {
        let view = PagedDocumentView()
        view.setContent(rendered, display: .singlePage)
        view.showPage(page)
        view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let file = proofs.appendingPathComponent(name)
        try png.write(to: file)
        print("PROOF: \(file.path)")
    }
}
