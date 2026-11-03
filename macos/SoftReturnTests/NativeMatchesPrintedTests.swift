import AppKit
import CtrlKD
import Foundation
@testable import SoftReturnRendering
import SoftReturnShared
import Testing
@testable import SoftReturn

/// Hand-built WS7 and WS4 lines rendered twice, by the engine's Printed PDF and by Native, and what each puts on the
/// page compared: the rules under a line, the characters printed over it, where its glyphs start. No corpus file: the
/// bytes are the engine's own test fixtures (planning #549), so a stranger's run exercises them too.
@MainActor
enum NativeVsPrinted {
    static let HARD: [UInt8] = [0x0D, 0x0A]
    static let SOFT: [UInt8] = [0x8D, 0x0A]

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// One WS5+ symmetric block, as CtrlKD's own `ws7Block` test helper builds it.
    static func ws7Block(_ cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let count = payload.count + 4
        let countBytes: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
        var block: [UInt8] = [0x1D]
        block += countBytes
        block += [cmd]
        block += payload
        block += countBytes
        block += [0x1D]
        return block
    }

    /// A WS7 header block (release byte 0x60) long enough for detection to take it, as CtrlKD's `ws7HeaderBlock`.
    static func header() -> [UInt8] {
        ws7Block(0x00, payload: [0x60] + [UInt8](repeating: 0, count: 20))
    }

    /// One WS5+ font block: width word (HMI), height word (points x 20), typestyle word (0x8000: proportional), six
    /// reserved bytes. Typestyle 5 is Tms Rmn.
    static func fontBlock(typestyle: Int, points: Double = 12, width: Int = 180) -> [UInt8] {
        var payload = le16(width)
        payload += le16(Int((points * 20).rounded()))
        payload += le16(typestyle)
        payload += [UInt8](repeating: 0, count: 6)
        return ws7Block(0x02, payload: payload)
    }

    static func state(_ document: Document) -> DocumentState {
        let defaults = UserDefaults(suiteName: "NativeVsPrinted.\(UUID().uuidString)")!
        return DocumentState(document: document, settings: SettingsStore(defaults: defaults))
    }

    /// The Printed PDF's content streams, in page order, as text.
    static func printedContent(_ state: DocumentState) -> String {
        printedStreams(state).joined(separator: "\n")
    }

    /// Each of the Printed PDF's streams, in order: one per page for a document with no embedded font or picture.
    static func printedStreams(_ state: DocumentState) -> [String] {
        let pdf = emitPDF(state.document, mode: .printed, options: state.printedOptions)
        let open = bytes("stream\n")
        let close = bytes("endstream")
        var streams: [String] = []
        var i = 0
        while i + open.count <= pdf.count {
            guard Array(pdf[i..<i + open.count]) == open else {
                i += 1
                continue
            }
            var j = i + open.count
            while j + close.count <= pdf.count, Array(pdf[j..<j + close.count]) != close { j += 1 }
            streams.append(String(decoding: pdf[(i + open.count)..<j], as: UTF8.self))
            i = j + close.count
        }
        return streams
    }

    /// Every `0.6 w x0 y m x1 y l S` rule in Printed's content: (x0, x1, y).
    static func printedRules(_ content: String) -> [(x0: Double, x1: Double, y: Double)] {
        content.components(separatedBy: "\n").compactMap { op in
            let p = op.split(separator: " ")
            guard p.count == 9, p[0] == "0.6", p[1] == "w", p[4] == "m", p[7] == "l", p[8] == "S",
                  let x0 = Double(p[2]), let y = Double(p[3]), let x1 = Double(p[5]) else { return nil }
            return (x0, x1, y)
        }
    }

    /// Printed's rules joined where one ends at or within a quarter point of the next's start: what a reader sees as
    /// one line on the paper.
    static func joined(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, span.0 <= last.1 + 0.25 {
                out[out.count - 1].1 = max(last.1, span.1)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// A Native render's text laid out by the layout manager its pages use, one container the text frame's width.
    /// Keep `storage` alive while using `manager`: a layout manager holds its storage weakly.
    struct Laid {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let rendered: RenderedDocument
    }

    static func laidOut(_ rendered: RenderedDocument) -> Laid {
        let storage = NSTextStorage(attributedString: rendered.text)
        let manager = softReturnLayoutManager()
        let container = NSTextContainer(size: CGSize(width: rendered.textFrame.width, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return Laid(storage: storage, manager: manager, container: container, rendered: rendered)
    }

    /// The baseline of the laid-out text's first line, in container coordinates.
    static func firstBaseline(_ laid: Laid) -> CGFloat {
        let glyphs = laid.manager.glyphRange(for: laid.container)
        var baseline: CGFloat = 0
        laid.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, stop in
            baseline = rect.minY + laid.manager.location(forGlyphAt: range.location).y
            stop.pointee = true
        }
        return baseline
    }

    /// `paint` run into a white, flipped bitmap `scale` times the size of `size`.
    static func raster(_ size: CGSize, scale: CGFloat, _ paint: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        paint()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Each run of dark pixels on `row`, as (left, right) in points.
    static func darkRuns(_ rep: NSBitmapImageRep, row: Int, scale: CGFloat) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var start: Int?
        for x in 0...rep.pixelsWide {
            let dark = x < rep.pixelsWide
                && (rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
            if dark, start == nil { start = x }
            if !dark, let s = start {
                out.append((Double(s) / Double(scale), Double(x) / Double(scale)))
                start = nil
            }
        }
        return out
    }

    /// The underline rules Native draws under the first line of `state`'s Native render, in the engine's page x:
    /// the text drawn invisible, the rules black, at 8x, read along the rule's row. The page's column passes' rules
    /// (`ColumnPass.bars`: an underlined dot leader's) are drawn with them, moved from the paper's frame into the
    /// text's as the page view moves them: x less the text's left anchor, y onto the line's own baseline.
    static func nativeRules(_ state: DocumentState) -> [(Double, Double)] {
        let laid = laidOut(DocumentRenderer.render(state, style: .native))
        let whole = NSRange(location: 0, length: laid.storage.length)
        laid.storage.addAttribute(.foregroundColor, value: NSColor.clear, range: whole)
        laid.storage.addAttribute(.underlineColor, value: NSColor.black, range: whole)
        let scale: CGFloat = 8
        let baseline = firstBaseline(laid)
        let glyphs = laid.manager.glyphRange(for: laid.container)
        let passes = laid.rendered.lineNumberPasses.first ?? []
        let rep = raster(CGSize(width: laid.rendered.textFrame.width, height: baseline + 20), scale: scale) {
            laid.manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            for pass in passes {
                for fill in pass.bars.flatMap(\.fills) {
                    fill.offsetBy(dx: -laid.rendered.engineLeftAnchor, dy: baseline - CGFloat(pass.baselineY)).fill()
                }
            }
        }
        let row = Int((baseline + ScriptRiseLayoutManager.underlineDrop) * scale)
        let anchor = Double(laid.rendered.engineLeftAnchor)
        return darkRuns(rep, row: row, scale: scale).map { ($0.0 + anchor, $0.1 + anchor) }
    }

    /// Whether two lists of (left, right) agree run for run within `tolerance` points.
    static func agree(_ a: [(Double, Double)], _ b: [(Double, Double)], within tolerance: Double) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.0 - $1.0) <= tolerance && abs($0.1 - $1.1) <= tolerance }
    }

    static func describe(_ runs: [(Double, Double)]) -> String {
        runs.map { String(format: "%.2f–%.2f", $0.0, $0.1) }.joined(separator: ", ")
    }
}

extension NativeVsPrinted {
    /// One text-showing op of Printed's content: its font size, the Tz in force (100 when none was set), its x and y
    /// and its text.
    struct Shown {
        let size: Double
        let tz: Double
        let x: Double
        let y: Double
        let text: String
    }

    /// Every `BT ... Tf ... [Tz] x y Td (text) Tj ET` op in `content`, in order, the Tz carried from op to op as PDF's
    /// text state carries it.
    static func shown(_ content: String) -> [Shown] {
        var tz = 100.0
        var out: [Shown] = []
        for op in content.components(separatedBy: "\n") where op.hasPrefix("BT ") && op.hasSuffix(" Tj ET") {
            guard let open = op.firstIndex(of: "("), let close = op.lastIndex(of: ")") else { continue }
            let words = op[..<open].split(separator: " ").map(String.init)
            if let at = words.firstIndex(of: "Tz"), at > 0, let value = Double(words[at - 1]) { tz = value }
            guard let tf = words.firstIndex(of: "Tf"), tf > 0, let size = Double(words[tf - 1]),
                  let td = words.firstIndex(of: "Td"), td > 1,
                  let x = Double(words[td - 2]), let y = Double(words[td - 1]) else { continue }
            out.append(Shown(size: size, tz: tz, x: x, y: y, text: String(op[op.index(after: open)..<close])))
        }
        return out
    }

    /// Where Native sets each character of its render's first line, in the engine's page x, blanks left out.
    static func nativeLetters(_ state: DocumentState) -> [(char: Character, x: Double)] {
        let laid = laidOut(DocumentRenderer.render(state, style: .native))
        let glyphs = laid.manager.glyphRange(for: laid.container)
        var first = NSRange()
        laid.manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, stop in
            first = range
            stop.pointee = true
        }
        let text = laid.storage.string as NSString
        let anchor = Double(laid.rendered.engineLeftAnchor)
        var out: [(char: Character, x: Double)] = []
        for glyph in first.location..<NSMaxRange(first) {
            let index = laid.manager.characterIndexForGlyph(at: glyph)
            guard let char = text.substring(with: NSRange(location: index, length: 1)).first,
                  !char.isWhitespace else { continue }
            let x = laid.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + laid.manager.location(forGlyphAt: glyph).x
            out.append((char, Double(x) + anchor))
        }
        return out
    }
}

/// Planning #549, WS4's HPLJET: a justified line's letter spacing. The driver adds whole 1/120" units after each
/// letter of the justified region (WS4 teardown 4 §15.5, `HPLJET.placeLine`); the engine keeps each word's start and
/// width (`attachHpljetPieces`), and Printed draws the word as one `Tj` scaled by `Tz` to that width, so its letters
/// spread evenly over it. Native drew the word at its natural width with the slack after its last letter: the word
/// began where Printed's does and its letters fell behind, 2.8 pt by the third W of a `.PS` "WWW".
@Suite(.serialized)
@MainActor
struct NativeHPLJETJustifiedTests {
    /// Each letter of a WS4 line's first-line words where Printed puts it: the word's `Td` x plus the advances before
    /// it, `width / 1000 × size × Tz / 100` each, from the stand-in face's AFM width (`widths`), against where Native
    /// sets it. Within 0.1 pt.
    func expectLettersMatch(_ name: String, _ body: [UInt8], widths: [Character: Double]) {
        let state = NativeVsPrinted.state(parseWS(body, variant: .ws4))
        let shown = NativeVsPrinted.shown(NativeVsPrinted.printedContent(state))
        let top = shown.map(\.y).max() ?? 0
        var printed: [(char: Character, x: Double)] = []
        for op in shown where op.y == top {
            var x = op.x
            for char in op.text {
                printed.append((char, x))
                x += (widths[char] ?? 0) / 1000 * op.size * op.tz / 100
            }
        }
        let native = NativeVsPrinted.nativeLetters(state)
        let describe = { (letters: [(char: Character, x: Double)]) in
            letters.map { String(format: "%@ %.2f", String($0.char), $0.x) }.joined(separator: ", ")
        }
        print("HPLJET-LETTERS \(name): Printed \(describe(printed)); Native \(describe(native))")
        #expect(shown.contains { $0.y == top && abs($0.tz - 100) > 1 }, "\(name): Printed no longer scales the words")
        #expect(native.count == printed.count && zip(native, printed).allSatisfy { $0.char == $1.char && abs($0.x - $1.x) <= 0.1 },
                "\(name): Native \(describe(native)) against Printed \(describe(printed))")
    }

    /// WS4 teardown 7.9, run w20-neg: a `.PS ON` line over the right margin; every gap shrinks, and each word is drawn
    /// in the PS14B stand-in (Helvetica Bold, AFM W 944, M 833) scaled to its width on the printer.
    @Test func psLettersLandWherePrintedPutsThem() {
        var body = NativeVsPrinted.bytes(".PS ON")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.bytes(".UJ ON")
        body += NativeVsPrinted.HARD
        body += [0x57, 0x57, 0xD7, 0x20, 0x4D, 0x4D, 0xCD, 0x20]
        body += [0x57, 0x57, 0xD7, 0x20, 0x4D, 0x4D, 0xCD, 0x20, 0x57, 0xD7]
        body += NativeVsPrinted.SOFT
        expectLettersMatch(".PS negative slack", body, widths: ["W": 944, "M": 833])
    }

    /// WS4 teardown 7.9, run w20-thr9: a one-line file at `.CW 9`, letter spaced (ESC&k10H); each word in Courier at
    /// 9 pt (AFM 600), scaled to the driver's wider letters.
    @Test func fixedPitchLetterSpacingLandsWherePrintedPutsIt() {
        var body = NativeVsPrinted.bytes(".CW 9")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.bytes(".UJ ON")
        body += NativeVsPrinted.HARD
        body += [0x61, 0x62, 0xE4, 0x20, 0xA0, 0x65, 0x66, 0xE7]
        body += NativeVsPrinted.SOFT
        expectLettersMatch(".CW 9 letter spacing", body,
                           widths: ["a": 600, "b": 600, "d": 600, "e": 600, "f": 600, "g": 600])
    }
}

/// Planning #549 (engine ac40a66d, WS7 teardown 9.5 and 11.6): Printed strikes a run out as WS7's LASERJET does, by
/// printing the strike character over it after the line, floor(span / width) copies and one more at the run's start
/// for a remainder, counted in 300-dpi dots; `.xx` sets the character, a bare `.xx` a blank, WS4 keeps `-`. Native drew
/// AppKit's line-through. It now draws the copies the engine recorded (`PageLine.strikeCopies`) at the same x, each the
/// width Printed gives it, and no line-through; Modern, which is not a facsimile, keeps its line-through.
@Suite(.serialized)
@MainActor
struct NativeStrikeOutTests {
    /// "plain ^Xstruck out^X end" after `dots` (each its own line), as the engine's xx25 tests build it.
    static func struckLine(_ dots: [String] = [], before: String = "plain ", struck: String = "struck out",
                           after: String = " end") -> [UInt8] {
        var body: [UInt8] = []
        for dot in dots {
            body += NativeVsPrinted.bytes(dot)
            body += NativeVsPrinted.HARD
        }
        body += NativeVsPrinted.bytes(before)
        body += [0x18]
        body += NativeVsPrinted.bytes(struck)
        body += [0x18]
        body += NativeVsPrinted.bytes(after)
        body += NativeVsPrinted.HARD
        return body
    }

    /// Where each copy of `char` lands: in Printed, from each op that prints nothing but `char`, its `Td` x plus the
    /// copies before it at `afm / 1000 × size × Tz / 100`; in Native, each glyph of each column pass of `char`s, laid
    /// out as the page view lays a pass out.
    func copies(_ state: DocumentState, char: Character, afm: Double) -> (printed: [Double], native: [Double]) {
        var printed: [Double] = []
        for op in NativeVsPrinted.shown(NativeVsPrinted.printedContent(state))
        where !op.text.isEmpty && op.text.allSatisfy({ $0 == char }) {
            for k in 0..<op.text.count { printed.append(op.x + Double(k) * afm / 1000 * op.size * op.tz / 100) }
        }
        let rendered = DocumentRenderer.render(state, style: .native)
        var native: [Double] = []
        for pass in rendered.lineNumberPasses.first ?? []
        where pass.text.length > 0 && pass.text.string.allSatisfy({ $0 == char }) {
            guard let isolated = isolatedLineLayout(pass.text, width: rendered.textFrame.width) else { continue }
            for glyph in isolated.glyphRange.location..<NSMaxRange(isolated.glyphRange) {
                // The page view draws the pass at `xPt - fragmentRect.minX`, and a glyph sits `location.x` into its
                // fragment: `xPt + location.x` on the paper.
                native.append(pass.xPt + Double(isolated.manager.location(forGlyphAt: glyph).x))
            }
        }
        return (printed, native)
    }

    static func lineThrough(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if ((value as? Int) ?? 0) != 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func expectCopiesMatch(_ name: String, _ document: Document, char: Character, afm: Double, count: Int) {
        let state = NativeVsPrinted.state(document)
        let (printed, native) = copies(state, char: char, afm: afm)
        let describe = { (xs: [Double]) in xs.map { String(format: "%.2f", $0) }.joined(separator: " ") }
        print("STRIKE-COPIES \(name): Printed \(describe(printed)); Native \(describe(native))")
        #expect(printed.count == count, "\(name): Printed printed \(printed.count) copies of \(char), not \(count)")
        #expect(native.count == printed.count && zip(native, printed).allSatisfy { abs($0 - $1) <= 0.1 },
                "\(name): Native's copies \(describe(native)) against Printed's \(describe(printed))")
        #expect(!Self.lineThrough(DocumentRenderer.render(state, style: .native).text),
                "\(name): Native still draws a line-through under the copies")
    }

    /// Run xx25: `.xx *` prints ten `*` over "struck out", from its x, in Courier (AFM 600) at 12 pt.
    @Test func xxStarCopiesLandWherePrintedPrintsThem() {
        expectCopiesMatch(".xx *", parseWS(Self.struckLine([".xx *"]), variant: .ws5plus), char: "*", afm: 600, count: 10)
    }

    /// No `.xx`: the factory `-`.
    @Test func defaultDashCopiesLandWherePrintedPrintsThem() {
        expectCopiesMatch("no .xx", parseWS(Self.struckLine(), variant: .ws5plus), char: "-", afm: 600, count: 10)
    }

    /// WS4 has no `.xx` (its strike character is an install byte, `-`): `.XX *` changes nothing.
    @Test func ws4StrikesWithDashWhatever() {
        expectCopiesMatch("WS4", parseWS(Self.struckLine([".XX *"], struck: "str"), variant: .ws4),
                          char: "-", afm: 600, count: 3)
    }

    /// Two struck runs on one line are two passes, each from its own run's x.
    @Test func twoStruckRunsAreStruckApart() {
        var body = Self.struckLine(before: "a ", struck: "one", after: " b ")
        body.removeLast(2)
        body += [0x18]
        body += NativeVsPrinted.bytes("two")
        body += [0x18]
        body += NativeVsPrinted.HARD
        expectCopiesMatch("two runs", parseWS(body, variant: .ws5plus), char: "-", afm: 600, count: 6)
    }

    /// A proportional Tms Rmn run whose width is no whole number of `-`: one copy at the run's start, the rest the
    /// remainder further on so the last ends flush, each `-` (AFM 333) at the width Printed gives it.
    @Test func aRemainderCopyLandsWherePrintedPrintsIt() {
        var body = NativeVsPrinted.header()
        body += NativeVsPrinted.fontBlock(typestyle: 5 | 0x8000, width: 150)
        body += Self.struckLine(struck: "struck out words")
        expectCopiesMatch("Tms Rmn remainder", parseWS(body, variant: .ws5plus), char: "-", afm: 333, count: 24)
    }

    /// A bare `.xx` strikes with blanks: nothing printed, in Printed or in Native, and no line-through either.
    @Test func aBareXXDrawsNothing() {
        let state = NativeVsPrinted.state(parseWS(Self.struckLine([".xx *", ".xx"]), variant: .ws5plus))
        let rendered = DocumentRenderer.render(state, style: .native)
        #expect((rendered.lineNumberPasses.first ?? []).isEmpty, "Native drew a strike-out pass for a blank strike character")
        #expect(!Self.lineThrough(rendered.text), "Native drew a line-through for a blank strike character")
        let content = NativeVsPrinted.printedContent(state)
        #expect(!content.contains("(**********)") && !content.contains(" l S"), "Printed printed a strike-out for a bare .xx")
    }

    /// Modern is a reading view, not the printer's page: it keeps the text system's line-through.
    @Test func modernKeepsItsLineThrough() {
        let state = NativeVsPrinted.state(parseWS(Self.struckLine([".xx *"]), variant: .ws5plus))
        #expect(Self.lineThrough(DocumentRenderer.render(state, style: .modern).text))
    }
}

extension NativeVsPrinted {
    /// One WS5+ record, `1D <count> <cmd> <content> <count> 1D`, as CtrlKD's `TeardownReaderTests.record` builds it.
    static func record(_ cmd: UInt8, _ content: [UInt8]) -> [UInt8] {
        ws7Block(cmd, payload: content)
    }

    /// WS7's 128-byte header naming `driver` (version byte 70h), as CtrlKD's `TeardownReaderTests.ws7Header`.
    static func ws7Header(driver: String = "LASERJET") -> [UInt8] {
        var inner: [UInt8] = [0x00, 0x70]
        inner += Array(driver.utf8)
        inner += [UInt8](repeating: 0, count: 122 - inner.count)
        var head: [UInt8] = [0x1D, 0x7D, 0x00]
        head += inner
        head += [0x7D, 0x00, 0x1D]
        return head
    }

    /// A WS5+ footnote (cmd 03) or endnote (04) record storing `number`, as CtrlKD's `ws7Note` test fixture.
    static func ws7Note(_ text: [UInt8], cmd: UInt8 = 0x03, number: Int) -> [UInt8] {
        var content: [UInt8] = [0x01, 0x00]
        content += [UInt8(number & 0xFF), UInt8((number >> 8) & 0xFF)]
        content += [0x30]
        content += text
        return ws7Block(cmd, payload: content)
    }

    /// Each row of a page's Printed text, top down: the `Tj` texts sharing one baseline, joined in x order, trailing
    /// blanks dropped.
    static func printedRows(_ content: String) -> [String] {
        var rows: [Double: [(x: Double, text: String)]] = [:]
        for op in shown(content) {
            // a PDF string's own escapes undone
            let text = op.text.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
            rows[op.y, default: []].append((op.x, text))
        }
        return rows.keys.sorted(by: >).map { y in
            var row = rows[y]!.sorted { $0.x < $1.x }.map(\.text).joined()
            while row.hasSuffix(" ") { row.removeLast() }
            return row
        }
    }

    /// Each row of Native's render, in reading order, trailing blanks dropped.
    static func nativeRows(_ state: DocumentState) -> [String] {
        let text = DocumentRenderer.render(state, style: .native).text.string
        return text.components(separatedBy: .newlines).map { row in
            var row = row
            while row.hasSuffix(" ") || row.hasSuffix("\u{00A0}") { row.removeLast() }
            return row
        }
    }

    /// One glyph a Native running line draws: its character, where it starts in the engine's page x, and its type size,
    /// weight and face.
    struct RunningGlyph {
        let char: Character
        let x: Double
        let size: Double
        let bold: Bool
        let family: String
    }

    /// Every running line Native draws on page `page`, its glyphs placed as `drawRunningLines` places the line: the
    /// engine x of the page's text frame, plus the line's own offsets, plus where the text system sets each glyph.
    static func nativeRunning(_ state: DocumentState, page: Int = 0) -> [(text: String, glyphs: [RunningGlyph])] {
        let rendered = DocumentRenderer.render(state, style: .native)
        guard rendered.runningLines.indices.contains(page) else { return [] }
        return rendered.runningLines[page].map { line in
            let origin = Double(rendered.engineLeftAnchor) + line.pageLeftOffset + line.leadingOffset
            guard let laid = isolatedLineLayout(line.text, width: 10_000) else { return (line.text.string, []) }
            let text = laid.storage.string as NSString
            var glyphs: [RunningGlyph] = []
            for glyph in laid.glyphRange.location..<NSMaxRange(laid.glyphRange) {
                let index = laid.manager.characterIndexForGlyph(at: glyph)
                guard let char = text.substring(with: NSRange(location: index, length: 1)).first,
                      !char.isWhitespace else { continue }
                let font = laid.storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                let x = laid.fragmentRect.minX + laid.manager.location(forGlyphAt: glyph).x
                glyphs.append(RunningGlyph(
                    char: char, x: origin + Double(x), size: Double(font?.pointSize ?? 0),
                    bold: font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                    family: font?.familyName ?? ""))
            }
            return (line.text.string, glyphs)
        }
    }
}

/// Planning #549 (engine 13ef0f41, WS7 teardown 3.15, run h24-allow): a running head whose text changes face after its
/// opening prints each part in its own face, and a tab's text from the tab's absolute x. The engine carries the parts as
/// `HeadFootLine.pieces`; Printed draws them with `hfPiecesOps`. Native drew the whole line in the face it opens with.
@Suite(.serialized)
@MainActor
struct NativeRunningHeadPiecesTests {
    /// `.he A<font>BCD<tab>EF`: `A` in Courier 12, the font record's 24 pt Tms Rmn from `B`, and `EF` from the tab's
    /// absolute x, 1800 HMI (one inch) past the margin. `toggle` wraps `B`…`F` in a bold toggle opened in the first
    /// piece and closed in the last.
    static func document(toggle: Bool) -> Document {
        let font = NativeVsPrinted.record(0x02, [0x13, 0x01, 0xE0, 0x01, 0x05, 0xC6, 0xB4, 0x00, 0xF0, 0x00, 0x00, 0x00])
        var head = NativeVsPrinted.bytes(".he A")
        if toggle { head += [0x02] }
        head += font
        head += NativeVsPrinted.bytes("BCD")
        head += NativeVsPrinted.record(0x09, [0x08, 0x07, 0x08, 0x07, 0x20, 0x0A])
        head += NativeVsPrinted.bytes("EF")
        if toggle { head += [0x02] }
        var data = NativeVsPrinted.ws7Header()
        data += head
        data += NativeVsPrinted.HARD
        for n in 1...3 {
            data += NativeVsPrinted.bytes("line 0\(n)")
            data += NativeVsPrinted.HARD
        }
        data += [UInt8](repeating: 0x1A, count: 8)
        return parseWS(data)
    }

    /// Each piece Printed draws on the head's row (the size it sets and the x it starts at) against the glyph Native
    /// draws that piece's first letter with: the same x within 0.1 pt and the same size. Every letter of a piece is
    /// drawn at its piece's size.
    func expectPiecesMatch(toggle: Bool) throws {
        let state = NativeVsPrinted.state(Self.document(toggle: toggle))
        let model = try #require(docToPagelines(state.document, printed: true).first?.headerLines?.first)
        #expect(model.pieces?.count == 3, "the engine no longer cuts the head into its three pieces")
        let shown = NativeVsPrinted.shown(NativeVsPrinted.printedContent(state))
        let row = shown.filter { op in ["A", "BCD", "EF"].contains(op.text.trimmingCharacters(in: .whitespaces)) }
        let head = try #require(NativeVsPrinted.nativeRunning(state).first { $0.text.contains("EF") })
        let describe = { (g: [NativeVsPrinted.RunningGlyph]) in
            g.map { String(format: "%@ %.2f @%.0f%@", String($0.char), $0.x, $0.size, $0.bold ? "b" : "") }
                .joined(separator: ", ")
        }
        print("HEAD-PIECES toggle \(toggle): Printed \(row.map { String(format: "%@ %.2f @%.0f", $0.text, $0.x, $0.size) }); "
              + "Native \(describe(head.glyphs))")
        #expect(row.map(\.text) == ["A", "BCD", "EF"], "Printed no longer draws the head in three pieces")
        for op in row {
            let letters = head.glyphs.filter { op.text.contains($0.char) }
            guard let first = letters.first(where: { $0.char == op.text.first }) else {
                Issue.record("Native draws no \(op.text.prefix(1)) in the head")
                continue
            }
            #expect(abs(first.x - op.x) <= 0.1, "\(op.text): Native starts it at \(first.x), Printed at \(op.x)")
            #expect(letters.allSatisfy { abs($0.size - op.size) < 0.01 },
                    "\(op.text): Native draws \(describe(letters)), Printed at \(op.size) pt")
        }
        if toggle {
            // the bold toggle opened in the first piece runs on into the tab's piece, and closes there
            let toggled = head.glyphs.filter { "BCDEF".contains($0.char) }
            #expect(!toggled.isEmpty && !toggled.contains { !$0.bold },
                    "the bold toggle does not run across the pieces: \(describe(head.glyphs))")
            #expect(head.glyphs.first { $0.char == "A" }?.bold == false)
        }
    }

    @Test func eachPieceIsDrawnInItsFaceAtItsX() throws {
        try expectPiecesMatch(toggle: false)
    }

    @Test func aToggleRunsAcrossThePieces() throws {
        try expectPiecesMatch(toggle: true)
    }
}

/// Planning #549 (engine c14356a3, WS4 teardown 4 §15.3): WS4 prints a `.FO`/`.HE` line in the `.CW` it was read under,
/// the plain page number in the install's normal width (12), and a body line under a `.CW` other than the page's in
/// Courier at that `.CW`, each character one cell of it. The engine carries the running line's size as
/// `HeadFootLine.size`/`AutoPageNumber.size` and the body line's face as `PageLine.face`; Native drew every running line at
/// the page's size.
@Suite(.serialized)
@MainActor
struct NativeWS4CharacterWidthTests {
    static func document(_ lines: [String]) -> Document {
        var body: [UInt8] = []
        for line in lines {
            body += NativeVsPrinted.bytes(line)
            body += NativeVsPrinted.HARD
        }
        return parseWS(body, variant: .ws4)
    }

    /// The running line (footer or page number) whose visible text is `text`: Printed's `Tj` for it against Native's
    /// glyphs, each letter at Printed's x (the op's x plus Courier's 600/1000 em per letter) within 0.1 pt, at Printed's
    /// size.
    func expectRunningLineMatches(_ name: String, _ lines: [String], text: String) throws {
        let state = NativeVsPrinted.state(Self.document(lines))
        let op = try #require(NativeVsPrinted.shown(NativeVsPrinted.printedContent(state)).first { $0.text == text },
                              "\(name): Printed draws no \(text)")
        let line = try #require(NativeVsPrinted.nativeRunning(state).first {
            $0.text.trimmingCharacters(in: .whitespaces) == text
        }, "\(name): Native draws no running line \(text)")
        var printed: [Double] = []
        for (k, char) in text.enumerated() where !char.isWhitespace {
            printed.append(op.x + Double(k) * 0.6 * op.size)
        }
        let native = line.glyphs
        print("WS4-CW \(name): Printed \(text) @\(op.size) at \(printed.map { String(format: "%.2f", $0) }); "
              + "Native @\(native.map(\.size)) at \(native.map { String(format: "%.2f", $0.x) })")
        #expect(native.allSatisfy { abs($0.size - op.size) < 0.01 },
                "\(name): Native draws \(text) at \(native.map(\.size)), Printed at \(op.size)")
        #expect(native.count == printed.count && zip(native, printed).allSatisfy { abs($0.x - $1) <= 0.1 },
                "\(name): Native's letters \(native.map(\.x)) against Printed's \(printed)")
    }

    /// Run cw30b-fo: `.CW 20` then `.FO page #`: the footer at 20.
    @Test func aFooterReadUnderACWPrintsInIt() throws {
        try expectRunningLineMatches("cw30b-fo", [".CW 20", ".FO page #", "line one"], text: "page 1")
    }

    /// Run cw30b-fo2: `.FO page #` then `.CW 20`: the footer keeps 12, the page is drawn at 20.
    @Test func aFooterReadBeforeTheCWKeepsTheWidthItWasReadUnder() throws {
        try expectRunningLineMatches("cw30b-fo2", [".FO page #", ".CW 20", "line one"], text: "page 1")
    }

    /// Runs cw30-pc, cw30-pc2: the plain page number prints in the install's normal width, 12, whatever `.CW` says.
    @Test func thePlainPageNumberPrintsInTheInstallWidth() throws {
        try expectRunningLineMatches("cw30-pc", [".PC 30", ".CW 20", "line one"], text: "1")
    }

    typealias Letter = (char: Character, x: Double, size: Double)

    static func describe(_ row: [Letter]) -> String {
        row.map { String(format: "%@ %.2f @%.0f", String($0.char), $0.x, $0.size) }.joined(separator: ", ")
    }

    /// Each body row Native draws on the first page, its letters in the engine's page x with their type size: a row's
    /// own glyphs, or, for a row too tall for its lead, the self-pass `drawOversizedSelfPasses` draws in its place,
    /// laid out as that draws it (at the row's fragment x).
    static func nativeBodyRows(_ state: DocumentState) -> [[Letter]] {
        let laid = NativeVsPrinted.laidOut(DocumentRenderer.render(state, style: .native))
        let anchor = Double(laid.rendered.engineLeftAnchor)
        let selfPasses = laid.rendered.oversizedSelfPasses.first ?? []
        func letters(_ storage: NSTextStorage, _ manager: NSLayoutManager, _ range: NSRange, x0: Double) -> [Letter] {
            var row: [Letter] = []
            for glyph in range.location..<NSMaxRange(range) {
                let index = manager.characterIndexForGlyph(at: glyph)
                guard let char = (storage.string as NSString).substring(with: NSRange(location: index, length: 1)).first,
                      !char.isWhitespace else { continue }
                let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                row.append((char, x0 + Double(manager.location(forGlyphAt: glyph).x), Double(font?.pointSize ?? 0)))
            }
            return row
        }
        var rows: [[Letter]] = []
        var index = 0
        let glyphs = laid.manager.glyphRange(for: laid.container)
        laid.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            defer { index += 1 }
            let x0 = Double(rect.minX) + anchor
            if index < selfPasses.count, let pass = selfPasses[index],
               let isolated = isolatedLineLayout(pass, width: laid.rendered.textFrame.width) {
                rows.append(letters(isolated.storage, isolated.manager, isolated.glyphRange, x0: x0))
            } else {
                rows.append(letters(laid.storage, laid.manager, range, x0: x0 + 0))
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    /// Each Printed body row's letters, top down, at the op's x plus Courier's 600/1000 em per letter, Tz applied: the
    /// rows whose text is in `texts`.
    static func printedBodyRows(_ state: DocumentState, _ texts: [String]) -> [[Letter]] {
        let shown = NativeVsPrinted.shown(NativeVsPrinted.printedContent(state))
        var ys: [Double] = []
        for op in shown where !ys.contains(op.y) && texts.contains(where: { $0.hasPrefix(op.text.trimmingCharacters(in: .whitespaces)) })
            && op.text.contains(where: { !$0.isWhitespace }) {
            ys.append(op.y)
        }
        return ys.sorted(by: >).map { y in
            var row: [Letter] = []
            for op in shown where op.y == y {
                var x = op.x
                for char in op.text {
                    if !char.isWhitespace { row.append((char, x, op.size)) }
                    x += 0.6 * op.size * op.tz / 100
                }
            }
            return row
        }
    }

    /// Every letter of every row where Printed puts it, within 0.1 pt, at Printed's size.
    func expectBodyMatches(_ name: String, _ document: Document, rows texts: [String]) {
        let state = NativeVsPrinted.state(document)
        let printed = Self.printedBodyRows(state, texts)
        let native = Self.nativeBodyRows(state)
        print("WS4-CW-BODY \(name): Printed \(printed.map(Self.describe)); Native \(native.map(Self.describe))")
        #expect(printed.count == texts.count, "\(name): Printed draws \(printed.count) rows, not \(texts.count)")
        #expect(native.count == printed.count, "\(name): Native draws \(native.count) rows, Printed \(printed.count)")
        for (n, (want, have)) in zip(printed, native).enumerated() {
            #expect(have.count == want.count && zip(have, want).allSatisfy {
                $0.char == $1.char && abs($0.x - $1.x) <= 0.1 && abs($0.size - $1.size) < 0.01
            }, "\(name) row \(n + 1): Native \(Self.describe(have)) against Printed \(Self.describe(want))")
        }
    }

    /// Run cw30-pc2: `.CW 10` before `line two` puts `two` at 576 + 5 × 60 dp, in Courier 10, on a page drawn at 20.
    @Test func aBodyLineUnderItsOwnCWIsDrawnInItsCells() {
        let document = Self.document([".PC 30", ".CW 20", "line one", ".CW 10", "line two"])
        #expect(docToPagelines(document, printed: true).first?[1].face
                == PageLine.Face(family: .courier, size: 10, bold: false),
                "the engine no longer draws line two in its own .CW")
        expectBodyMatches("cw30-pc2", document, rows: ["line one", "line two"])
    }

    /// WS4 teardown 7.9's letter spacing on a line under a `.CW` of its own, taller than the page's 12 pt lead: each word
    /// in Courier 20 scaled to the driver's wider letters, as Printed draws it.
    @Test func aTallLetterSpacedLineUnderItsOwnCWIsDrawnToItsWidths() {
        var body = NativeVsPrinted.bytes("line one")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.bytes(".CW 20")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.bytes(".UJ ON")
        body += NativeVsPrinted.HARD
        body += [0x61, 0x62, 0xE4, 0x20, 0xA0, 0x65, 0x66, 0xE7]
        body += NativeVsPrinted.SOFT
        let document = parseWS(body, variant: .ws4)
        #expect(docToPagelines(document, printed: true).first?[1].face
                == PageLine.Face(family: .courier, size: 20, bold: false),
                "the engine no longer draws the line in its own .CW")
        expectBodyMatches(".CW 20 letter spacing", document, rows: ["line one", "abd efg"])
    }
}

/// Planning #549: a line too tall for its lead is drawn by its own self-pass (`naturalPass`, drawn by
/// `drawOversizedSelfPasses`), and Printed starts it at its own left, `PageLine.left`, like any other line. Native set
/// the pass at the text frame's anchor, so after a `.po` that moves the text right the tall line stayed at the old margin.
@Suite(.serialized)
@MainActor
struct NativeOversizedLineLeftTests {
    /// `line one`, then `.po 16` and a 28 pt Courier font block over `BIG one`: Printed draws `BIG one` from 115.2, the
    /// new margin, and Native's self-pass draws every letter there too, at 28 pt.
    @Test func aTallLineStartsAtItsOwnLeft() {
        var body = NativeVsPrinted.header()
        body += NativeVsPrinted.bytes("line one")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.bytes(".po 16")
        body += NativeVsPrinted.HARD
        body += NativeVsPrinted.fontBlock(typestyle: 3, points: 28, width: 420)
        body += NativeVsPrinted.bytes("BIG one")
        body += NativeVsPrinted.HARD
        let document = parseWS(body, variant: .ws5plus)
        let state = NativeVsPrinted.state(document)
        #expect(docToPagelines(document, printed: true).first?[1].left == 115.2,
                "the engine no longer moves the tall line to the new margin")
        #expect(DocumentRenderer.render(state, style: .native).oversizedSelfPasses.first?.last??.string == "BIG one",
                "Native no longer draws the tall line as a self-pass")
        NativeWS4CharacterWidthTests().expectBodyMatches("tall line after .po", document, rows: ["line one", "BIG one"])
    }
}

/// Planning #549 (engine d5f00c16, WS7 teardown 21.10): Printed numbers footnotes and endnotes as WS7's printer does,
/// from the page each reference lands on, never from the number stored in the note record: factory footnotes restart
/// on each page, endnotes run on. Native lays its pages out from the same `docToPagelines`, so its reference marks and
/// note labels are Printed's; this holds it there.
@Suite(.serialized)
@MainActor
struct NativePrintTimeNoteNumbersTests {
    /// The runs' 100-line document: a note `<kind> for line NN` on each line in `at`, each record storing the number in
    /// `stored` (0-based, as WS7 saves it). CtrlKD's `TeardownNotesTests.numberedDoc`.
    static func document(_ kind: String, stored: [Int], at: [Int]) -> Document {
        var data = NativeVsPrinted.header()
        for i in 1...100 {
            let nn = i < 10 ? "0\(i)" : "\(i)"
            data += NativeVsPrinted.bytes("line " + nn)
            if let k = at.firstIndex(of: i) {
                data += NativeVsPrinted.ws7Note(NativeVsPrinted.bytes(kind + " for line " + nn),
                                                cmd: kind == "note" ? 0x03 : 0x04, number: stored[k])
            }
            data += NativeVsPrinted.HARD
        }
        return parseWS(data, variant: .ws5plus)
    }

    /// The rows that carry a note: each reference line (`line NN` and its mark) and each note's own line, in Printed's
    /// pages and in Native's flow, in order. They must be the same rows, and `want` must be among them.
    func expectNotesMatch(_ name: String, _ document: Document, at: [Int], want: [String]) {
        let state = NativeVsPrinted.state(document)
        let refs = at.map { $0 < 10 ? "line 0\($0)" : "line \($0)" }
        let keep = { (row: String) in
            row.contains(" for line ") || refs.contains { row.hasPrefix($0) && row != $0 }
        }
        let printed = NativeVsPrinted.printedStreams(state).flatMap(NativeVsPrinted.printedRows).filter(keep)
        let native = NativeVsPrinted.nativeRows(state).filter(keep)
        print("NOTE-NUMBERS \(name): Printed \(printed); Native \(native)")
        #expect(want.allSatisfy(printed.contains), "\(name): Printed's rows \(printed) lack \(want)")
        #expect(native == printed, "\(name): Native \(native) against Printed \(printed)")
    }

    /// Run tg61-stale: the records store 4, 3, 9, 8; the print numbers them 1, 2 on each of the two pages.
    @Test func footnotesAreNumberedPerPageAsPrintedNumbersThem() {
        let at = [5, 10, 60, 65]
        expectNotesMatch("footnotes", Self.document("note", stored: [3, 2, 8, 7], at: at), at: at,
                         want: ["line 051", "line 102", "line 601", "line 652", "1.note for line 05",
                                "2.note for line 10", "1.note for line 60", "2.note for line 65"])
    }

    /// Run tg61-en0: endnotes on lines 5 and 60, storing 7 and 3 (6 and 2 as saved), print `(1)` and `(2)` after the
    /// text.
    @Test func endnotesRunOnAsPrintedNumbersThem() {
        let at = [5, 60]
        expectNotesMatch("endnotes", Self.document("endnote", stored: [6, 2], at: at), at: at,
                         want: ["line 051", "line 602", "(1)endnote for line 05", "(2)endnote for line 60"])
    }
}

/// Planning #549 (engine b970ac0e, WS7 teardown 11.6): `.xx` typed with a `1B xx 1C` item strikes with that extended
/// character, and Printed draws a box-drawing or shading strike character as vector cells (`graphicOps`), one per copy,
/// as body text draws it. Native drew the copies as text in its face.
@Suite(.serialized)
@MainActor
struct NativeGraphicStrikeTests {
    /// Every `x y w h re f` fill in Printed's content: (x, y, w, h), PDF bottom-up.
    static func printedFills(_ content: String) -> [CGRect] {
        content.components(separatedBy: "\n").compactMap { op in
            let p = op.split(separator: " ")
            guard p.count == 6, p[4] == "re", p[5] == "f",
                  let x = Double(p[0]), let y = Double(p[1]), let w = Double(p[2]), let h = Double(p[3]) else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// `.xx <item>` over "plain ^Xstruck out^X end": Printed's fills against the fills of Native's strike pass, each in
    /// x, width, height and drop below its line's baseline within 0.1 pt, and no copy drawn as text. `bleed`: how far
    /// past each side Native draws a block or shade, as it draws one in body text (`graphicCell`), so a run's cells meet
    /// without a seam.
    func expectCellsMatch(_ name: String, item: UInt8, bleed: Double = 0) throws {
        var body = NativeVsPrinted.bytes(".xx ")
        body += [0x1B, item, 0x1C]
        body += NativeVsPrinted.HARD
        body += NativeStrikeOutTests.struckLine()
        let state = NativeVsPrinted.state(parseWS(body, variant: .ws5plus))
        let content = NativeVsPrinted.printedContent(state)
        let baseline = try #require(NativeVsPrinted.shown(content).first { $0.text.hasPrefix("plain") }?.y)
        // (x, width, height, top below the baseline), Printed's from PDF bottom-up
        let printed: [(Double, Double, Double, Double)] = Self.printedFills(content).map {
            (Double($0.minX) - bleed, Double($0.width) + 2 * bleed, Double($0.height), baseline - Double($0.maxY))
        }
        let rendered = DocumentRenderer.render(state, style: .native)
        let passes = rendered.lineNumberPasses.first ?? []
        let native: [(Double, Double, Double, Double)] = passes.flatMap { pass in
            pass.bars.flatMap(\.fills).map {
                (Double($0.frame.minX), Double($0.frame.width), Double($0.frame.height), Double($0.frame.minY) - pass.baselineY)
            }
        }
        let describe = { (r: [(Double, Double, Double, Double)]) in
            r.map { String(format: "x %.2f w %.2f h %.2f top %.2f", $0.0, $0.1, $0.2, $0.3) }.joined(separator: "; ")
        }
        print("GRAPHIC-STRIKE \(name): Printed \(describe(printed)); Native \(describe(native))")
        #expect(!printed.isEmpty, "\(name): Printed draws no cells for the strike")
        #expect(native.count == printed.count && zip(native, printed).allSatisfy {
            abs($0.0 - $1.0) <= 0.1 && abs($0.1 - $1.1) <= 0.1 && abs($0.2 - $1.2) <= 0.1 && abs($0.3 - $1.3) <= 0.1
        }, "\(name): Native \(describe(native)) against Printed \(describe(printed))")
        let scalar = Unicode.Scalar(UInt32(item == 0xB0 ? 0x2591 : 0x2500))!
        #expect(!passes.contains { $0.text.string.unicodeScalars.contains(scalar) },
                "\(name): Native still draws the strike character as text")
    }

    /// CP437 B0h, the light shade.
    @Test func aShadeStrikeIsDrawnAsCells() throws {
        try expectCellsMatch("shade B0", item: 0xB0, bleed: 0.5)
    }

    /// CP437 C4h, the single horizontal line.
    @Test func aBoxStrikeIsDrawnAsCells() throws {
        try expectCellsMatch("box C4", item: 0xC4)
    }

    /// An ordinary strike character stays text: `.xx *` still prints its copies as glyphs and no cells.
    @Test func anOrdinaryStrikeCharacterStaysText() {
        let state = NativeVsPrinted.state(parseWS(NativeStrikeOutTests.struckLine([".xx *"]), variant: .ws5plus))
        let passes = DocumentRenderer.render(state, style: .native).lineNumberPasses.first ?? []
        #expect(passes.contains { $0.text.string == "**********" } && passes.allSatisfy(\.bars.isEmpty))
    }
}
