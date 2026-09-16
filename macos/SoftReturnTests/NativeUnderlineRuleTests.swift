import AppKit
import CtrlKD
import Foundation
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Batch 40 (M12, Jon: "the Native underline is REALLY fat. It's pushing the lower line down a bit."). Native's
/// single underline is Printed's rule: 0.6 pt thick, centred 1.5 pt below the baseline (`PDFWriter.rule`,
/// `0.6 w … y - 1.5`), whatever the face — it was the face's own, system Courier Bold's 1.10 pt at 1.73 pt down on
/// -ATTRIB.TST's "Bold Underline". A decoration never changes line advance: the fragments are the same with and
/// without it.
@Suite(.serialized)
@MainActor
struct NativeUnderlineRuleTests {
    static let scale: CGFloat = 8

    /// "Bold Underline" over a second line, in Courier Bold 12 pt, drawn at 8x: the rule under the space between the
    /// words (no glyph ink there), its thickness and its centre below the baseline; and the two lines' fragments with
    /// the underline and without.
    @Test func theRuleIsPrintedsAndTheLinesDoNotMove() throws {
        let font = try #require(NSFont(name: "Courier-Bold", size: 12) ?? NSFont(name: "Courier", size: 12))
        func layout(underlined: Bool) -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
            let storage = NSTextStorage(string: "Bold Underline\nNext line", attributes: [.font: font, .foregroundColor: NSColor.black])
            if underlined {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 14))
            }
            let manager = softReturnLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 300, height: 100))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            return (manager, container, storage)
        }
        let (plain, plainContainer, plainStorage) = layout(underlined: false)
        let (manager, container, storage) = layout(underlined: true)
        _ = (plainContainer, plainStorage, storage)
        let lineOne = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let lineTwo = manager.lineFragmentRect(forGlyphAt: 16, effectiveRange: nil)
        #expect(lineOne == plain.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    && lineTwo == plain.lineFragmentRect(forGlyphAt: 16, effectiveRange: nil),
                "the underline moved a line: \(lineOne), \(lineTwo)")

        let origin = CGPoint(x: 10, y: 10)
        let canvas = UnderlineCanvas(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let glyphs = manager.glyphRange(for: container)
        canvas.paint = {
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * Self.scale), pixelsHigh: Int(canvas.bounds.height * Self.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        // The space between "Bold" and "Underline": glyph 4.
        let space = manager.location(forGlyphAt: 4)
        let spaceWidth = manager.location(forGlyphAt: 5).x - space.x
        let x = origin.x + space.x + spaceWidth / 2
        let baseline = origin.y + lineOne.minY + space.y
        var inkRows: [Int] = []
        for row in Int((baseline - 1) * Self.scale)..<Int((baseline + 5) * Self.scale) {
            let colour = rep.colorAt(x: Int(x * Self.scale), y: row)?.usingColorSpace(.deviceRGB)
            if (colour?.redComponent ?? 1) < 0.5 { inkRows.append(row) }
        }
        let thickness = CGFloat(inkRows.count) / Self.scale
        let centre = inkRows.isEmpty ? 0 : (CGFloat(inkRows.first! + inkRows.last! + 1) / 2) / Self.scale - baseline
        print("UNDERLINE-RULE: baseline \(baseline) pt; rule under the space \(String(format: "%.3f", thickness)) pt thick, centred \(String(format: "%.3f", centre)) pt below the baseline; Printed's is \(ScriptRiseLayoutManager.underlineThickness) pt at \(ScriptRiseLayoutManager.underlineDrop) pt; face's own: thickness \(font.underlineThickness) pt, position \(font.underlinePosition) pt")
        #expect(!inkRows.isEmpty, "no underline drawn under the space")
        #expect(abs(thickness - ScriptRiseLayoutManager.underlineThickness) <= 2 / Self.scale, "the rule is \(thickness) pt thick")
        #expect(abs(centre - ScriptRiseLayoutManager.underlineDrop) <= 1.5 / Self.scale, "the rule is centred \(centre) pt below the baseline")
    }

    /// -ATTRIB.TST in the Native view: the underlined line's baseline and the next line's are one engine lead apart, as
    /// every other pair of lines on the page, and the top of page 1 is written beside Printed:
    /// m12-attrib-native-vs-printed.png.
    @Test(.tags(.corpus), .enabled(if: NativeSupSubRiseTests.attrib != nil, NativeSupSubRiseTests.skipReason))
    func attribUnderlineKeepsTheLinePitch() throws {
        let url = try #require(NativeSupSubRiseTests.attrib)
        let defaults = try #require(UserDefaults(suiteName: "NativeUnderlineRule.\(UUID().uuidString)"))
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: SettingsStore(defaults: defaults),
                                      docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .native)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .singlePage)
        view.frame = CGRect(origin: .zero, size: rendered.pageSize)
        view.layoutSubtreeIfNeeded()
        let textView = try #require(view.primaryTextView)
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let storage = try #require(textView.textStorage)
        var baselines: [(y: CGFloat, underlined: Bool)] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var underlined = false
            storage.enumerateAttribute(.underlineStyle, in: characters) { value, _, _ in
                if ((value as? NSNumber)?.intValue ?? 0) != 0 { underlined = true }
            }
            baselines.append((rect.minY + manager.location(forGlyphAt: glyphs.location).y, underlined))
        }
        let pitches: [CGFloat] = zip(baselines, baselines.dropFirst()).map { pair in pair.1.y - pair.0.y }
        let underlinedIndex = try #require(baselines.firstIndex { $0.underlined }, "no underlined line in -ATTRIB.TST")
        // One step at a time: as one expression this does not type-check in reasonable time (b40-m12).
        let roundedPitches: [CGFloat] = pitches.map { pitch in (pitch * 100).rounded() / 100 }
        let groups: [CGFloat: [CGFloat]] = Dictionary(grouping: roundedPitches, by: { pitch in pitch })
        let largest = groups.max { first, second in first.value.count < second.value.count }
        let common: CGFloat = largest?.key ?? 0
        let neighbours: [Int] = [underlinedIndex - 1, underlinedIndex].filter { pitches.indices.contains($0) }
        let around: [CGFloat] = neighbours.map { pitches[$0] }
        print("UNDERLINE-PITCH -ATTRIB.TST: \(baselines.count) lines; the usual pitch \(common) pt; into and out of the underlined line (\(underlinedIndex + 1)): \(around)")
        #expect(around.allSatisfy { abs($0 - common) < 0.01 }, "the underlined line changes the pitch: \(around) against \(common)")
        try NativeSupSubRiseTests.writeComparison(state: state, rendered: rendered, name: "m12-attrib-native-vs-printed.png")
    }

    /// Batch 40 (M20, Jon: "Fix it"): the rule starts at the run's first inked glyph and ends where its last inked glyph
    /// ends — a leading space, a trailing space and the line's own break, all underlined, carry none of it. The layout
    /// manager is the same one Native and Modern draw with. " Bold Underline \n" in Courier Bold 12 pt at 8x.
    @Test func theRuleEndsAtTheLastInkedGlyph() throws {
        let font = try #require(NSFont(name: "Courier-Bold", size: 12) ?? NSFont(name: "Courier", size: 12))
        let text = " Bold Underline \nNext line"
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 17))
        let manager = softReturnLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 100))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let origin = CGPoint(x: 10, y: 10)
        let canvas = UnderlineCanvas(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let glyphs = manager.glyphRange(for: container)
        canvas.paint = {
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * Self.scale), pixelsHigh: Int(canvas.bounds.height * Self.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        let line = manager.lineFragmentRect(forGlyphAt: 1, effectiveRange: nil)
        let baseline = origin.y + line.minY + manager.location(forGlyphAt: 1).y
        let row = Int((baseline + ScriptRiseLayoutManager.underlineDrop) * Self.scale)
        let dark = (0..<rep.pixelsWide).filter { (rep.colorAt(x: $0, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5 }
        let first = try #require(dark.first, "no rule drawn")
        let last = try #require(dark.last)
        let ruleLeft = CGFloat(first) / Self.scale
        let ruleRight = CGFloat(last + 1) / Self.scale
        let letterLeft = origin.x + manager.location(forGlyphAt: 1).x      // "B"
        let letterRight = origin.x + manager.location(forGlyphAt: 15).x    // where "e" ends: the trailing space's start
        print("UNDERLINE-EXTENT: rule \(ruleLeft)–\(ruleRight) pt; the letters \(letterLeft)–\(letterRight) pt; a space is \(manager.location(forGlyphAt: 2).x - manager.location(forGlyphAt: 1).x) pt")
        #expect(abs(ruleLeft - letterLeft) <= 2 / Self.scale, "the rule starts at \(ruleLeft), the first letter at \(letterLeft)")
        #expect(abs(ruleRight - letterRight) <= 2 / Self.scale, "the rule ends at \(ruleRight), the last letter at \(letterRight)")
        // A run of nothing but spaces gets no rule.
        #expect(manager is ScriptRiseLayoutManager)
        let spaces = try #require(manager as? ScriptRiseLayoutManager)
        #expect(spaces.inkedGlyphRange(NSRange(location: 15, length: 2)) == nil, "the trailing space and break were inked")
    }

    /// Batch 40 (M20): -ATTRIB.TST's "Bold Underline" in the Native view and in Printed's PDF, both at 8x: the rule's
    /// left and right ends on the page. Written as m20-attrib-underline-8x.png (Native above, Printed below).
    @Test(.tags(.corpus), .enabled(if: NativeSupSubRiseTests.attrib != nil, NativeSupSubRiseTests.skipReason))
    func attribUnderlineEndsWherePrintedsDoes() throws {
        let url = try #require(NativeSupSubRiseTests.attrib)
        let defaults = try #require(UserDefaults(suiteName: "NativeUnderlineExtent.\(UUID().uuidString)"))
        let state = try DocumentState(data: [UInt8](try Data(contentsOf: url)), settings: SettingsStore(defaults: defaults),
                                      docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .native)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .singlePage)
        view.frame = CGRect(origin: .zero, size: rendered.pageSize)
        view.layoutSubtreeIfNeeded()
        let textView = try #require(view.primaryTextView)
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let storage = try #require(textView.textStorage)
        var ruleY: CGFloat?
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, stop in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var underlined = false
            storage.enumerateAttribute(.underlineStyle, in: characters) { value, _, _ in
                if ((value as? NSNumber)?.intValue ?? 0) != 0 { underlined = true }
            }
            guard underlined else { return }
            ruleY = textView.frame.minY + rect.minY + manager.location(forGlyphAt: glyphs.location).y + ScriptRiseLayoutManager.underlineDrop
            // What the line holds at the underline's end, for the record: each of the last characters under the
            // underline attribute and the one after, its kern, where its glyph is set and its bounding box.
            var underlinedEnd = characters.location
            storage.enumerateAttribute(.underlineStyle, in: characters) { value, range, _ in
                if ((value as? NSNumber)?.intValue ?? 0) != 0 { underlinedEnd = NSMaxRange(range) }
            }
            let string = storage.string as NSString
            var described: [String] = []
            for index in max(characters.location, underlinedEnd - 3)..<min(NSMaxRange(characters), underlinedEnd + 1) {
                let glyph = manager.glyphIndexForCharacter(at: index)
                let scalar = string.character(at: index)
                let kern = (storage.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                described.append("U+\(String(format: "%04X", scalar)) kern \(kern) at x \(rect.minX + manager.location(forGlyphAt: glyph).x) box \(box.minX)–\(box.maxX)")
            }
            print("M20-UNDERLINE-END -ATTRIB.TST: underline attribute ends at character \(underlinedEnd) of the line \(characters); \(described)")
            stop.pointee = true
        }
        let y = try #require(ruleY, "no underlined line in -ATTRIB.TST")
        let scale: CGFloat = 8
        let band = CGRect(x: 0, y: (y - 12).rounded(.down), width: rendered.pageSize.width, height: 24)

        let nativeRep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(band.width * scale), pixelsHigh: Int(band.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        nativeRep.size = band.size
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: band, to: nativeRep) }
        let native = try #require(nativeRep.cgImage)

        let pdf = try emitPDF(state.document, mode: .printed, options: state.printedOptions)
        let provider = try #require(CGDataProvider(data: Data(pdf) as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let context = try #require(CGContext(
            data: nil, width: Int(band.width * scale), height: Int(band.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: band.width * scale, height: band.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -(box.height - band.maxY) - box.minY)
        context.drawPDFPage(page)
        let printed = try #require(context.makeImage())

        let nativeRule = try #require(Self.longestRule(native), "no rule found in Native's band")
        let printedRule = try #require(Self.longestRule(printed), "no rule found in Printed's band")
        let nativeEnds = (left: CGFloat(nativeRule.left) / scale, right: CGFloat(nativeRule.right) / scale)
        let printedEnds = (left: CGFloat(printedRule.left) / scale, right: CGFloat(printedRule.right) / scale)
        print("M20-UNDERLINE -ATTRIB.TST at 8x: Native's rule \(nativeEnds.left)–\(nativeEnds.right) pt (row \(nativeRule.row)), Printed's \(printedEnds.left)–\(printedEnds.right) pt (row \(printedRule.row)); right ends differ by \(nativeEnds.right - printedEnds.right) pt, left by \(nativeEnds.left - printedEnds.left) pt")
        #expect(abs(nativeEnds.right - printedEnds.right) <= 0.25, "Native's rule ends at \(nativeEnds.right) pt, Printed's at \(printedEnds.right) pt")
        #expect(abs(nativeEnds.left - printedEnds.left) <= 0.25, "Native's rule starts at \(nativeEnds.left) pt, Printed's at \(printedEnds.left) pt")

        // The two bands, Native above Printed, for the record.
        let gap = 16
        let out = try #require(CGContext(
            data: nil, width: native.width, height: native.height + gap + printed.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(gray: 0.85, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: out.width, height: out.height))
        out.draw(printed, in: CGRect(x: 0, y: 0, width: printed.width, height: printed.height))
        out.draw(native, in: CGRect(x: 0, y: printed.height + gap, width: native.width, height: native.height))
        let composed = try #require(out.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]))
        let proofs = RenderProbeKit.resolveOutputDirectory(
            preferred: FileManager.default.temporaryDirectory.appendingPathComponent("soft-return-proofs", isDirectory: true),
            fallbackName: "soft-return-proofs")
        let file = proofs.appendingPathComponent("m20-attrib-underline-8x.png")
        try png.write(to: file)
        print("PROOF: \(file.path)")
    }

    /// The row of `image` holding its longest horizontal run of dark pixels (gaps of one pixel bridged), and that run's
    /// first and one-past-last column — an underline rule, in a band cut around one.
    static func longestRule(_ image: CGImage) -> (row: Int, left: Int, right: Int)? {
        let rep = NSBitmapImageRep(cgImage: image)
        var best: (row: Int, left: Int, right: Int)?
        for row in 0..<rep.pixelsHigh {
            var start: Int?
            var lastDark = -2
            for x in 0..<rep.pixelsWide {
                let dark = (rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
                guard dark else { continue }
                if start == nil || x - lastDark > 2 { start = x }
                lastDark = x
                if let start, (best.map { $0.right - $0.left } ?? 0) < x + 1 - start {
                    best = (row, start, x + 1)
                }
            }
        }
        return best
    }
}

/// A flipped white view that runs `paint` to draw, as a page text view draws its glyphs.
private final class UnderlineCanvas: NSView {
    var paint: (() -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        paint?()
    }
}
