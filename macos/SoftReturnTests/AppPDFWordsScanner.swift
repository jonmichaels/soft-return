import CoreGraphics
import CtrlKD
import Foundation

/// One page's content-stream scan: text state machine + word splitter.
///
/// Reads the operators a PDF actually contains rather than pattern-matching one emitter's
/// output, which is the whole reason this exists — see `AppPDFWords`'s header. The text
/// matrix gives the baseline exactly; font `/Widths` give the advance needed to split a
/// shown string into words. Nothing here approximates a coordinate.
///
/// WHAT IS DELIBERATELY NOT HANDLED, and why that is safe: a Form XObject's own nested
/// content stream is not recursed into. `CGPDFScanner` does not follow `Do` on its own, and
/// neither ctrl-kd's `pdf.py` nor AppKit's page rendering puts body text inside a form for
/// these documents. If that ever changes the words simply go missing, which the round-trip
/// proof against `--dump-engine-words` catches immediately — it is a loud failure, not a
/// silent shift.
final class PageScan {

    // MARK: - Output

    private(set) var rasters: [AppPDFWords.Raster] = []

    private let pageNumber: Int
    private let pageHeight: Double
    private let pageOrigin: (x: Double, y: Double)

    init(pageNumber: Int, pageHeight: Double, pageOrigin: (Double, Double)) {
        self.pageNumber = pageNumber
        self.pageHeight = pageHeight
        self.pageOrigin = (pageOrigin.0, pageOrigin.1)
    }

    // MARK: - Graphics + text state

    /// PDF matrices are [a b c d e f]; `CGAffineTransform` is the same six in the same order.
    private var ctm: CGAffineTransform = .identity
    private var ctmStack: [CGAffineTransform] = []

    private var textMatrix: CGAffineTransform = .identity
    private var lineMatrix: CGAffineTransform = .identity

    fileprivate var fontSize: Double = 0
    fileprivate var leading: Double = 0
    fileprivate var charSpacing: Double = 0
    fileprivate var wordSpacing: Double = 0
    /// `Tz` is a PERCENTAGE in the file and a factor in the arithmetic.
    fileprivate var horizontalScale: Double = 1
    fileprivate var rise: Double = 0
    private var currentFont: PDFFont?

    /// Fonts by resource name, resolved once per page and extended by each Form XObject's
    /// own resources as it is entered.
    private var fonts: [String: PDFFont] = [:]
    /// The resource dictionary in force — the page's, or a form's own while inside one.
    private var resources: CGPDFDictionaryRef?
    /// The content stream being scanned, needed as the PARENT when creating a form's.
    private var contentStream: CGPDFContentStreamRef?
    /// Depth guard: a malformed file can make forms refer to each other.
    private var formDepth = 0

    // MARK: - Running the scan

    func run(page: CGPDFPage) {
        if let pageDict = page.dictionary {
            var pageResources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDict, "Resources", &pageResources) {
                resources = pageResources
            }
        }
        loadFonts(from: resources)
        guard let table = CGPDFOperatorTableCreate() else { return }
        defer { CGPDFOperatorTableRelease(table) }
        Self.install(into: table)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        contentStream = stream
        let scanner = CGPDFScannerCreate(stream, table, context)
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    // MARK: - Font resolution

    private func loadFonts(from resources: CGPDFDictionaryRef?) {
        guard let resources else { return }
        var fontDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fontDict), let fontDict
        else { return }

        // `CGPDFDictionaryApplyFunction` is the only way to enumerate keys, and it takes a
        // C function pointer, so the box carries `self` across.
        let box = Unmanaged.passUnretained(self).toOpaque()
        CGPDFDictionaryApplyFunction(fontDict, { key, value, info in
            guard let info else { return }
            let scan = Unmanaged<PageScan>.fromOpaque(info).takeUnretainedValue()
            var dict: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &dict), let dict else { return }
            scan.fonts[String(cString: key)] = PDFFont(dictionary: dict)
        }, box)
    }

    // MARK: - Operator callbacks

    /// Installed from file-scope constants rather than closures written inline here.
    ///
    /// Writing all seventeen `@convention(c)` callbacks inside one function CRASHES
    /// swift-frontend — "While running pass #1261 SILFunctionTransform 'SendNonSendable' on
    /// SILFunction ... install(into:)", an assertion inside the region-based Sendable
    /// analysis, not a diagnosable error in this code. Splitting them into separate
    /// file-scope values gives the pass one small function each and compiles. Same family of
    /// Mac-toolchain limit as `SupSubFixedPitchTests`' own "build the byte fixtures in
    /// statements" note.
    private static func install(into table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q", pdfOpPushState)
        CGPDFOperatorTableSetCallback(table, "Q", pdfOpPopState)
        CGPDFOperatorTableSetCallback(table, "cm", pdfOpConcat)
        CGPDFOperatorTableSetCallback(table, "BT", pdfOpBeginText)
        CGPDFOperatorTableSetCallback(table, "ET", pdfOpEndText)
        CGPDFOperatorTableSetCallback(table, "Tf", pdfOpSetFont)
        CGPDFOperatorTableSetCallback(table, "TL", pdfOpSetLeading)
        CGPDFOperatorTableSetCallback(table, "Tc", pdfOpSetCharSpacing)
        CGPDFOperatorTableSetCallback(table, "Tw", pdfOpSetWordSpacing)
        CGPDFOperatorTableSetCallback(table, "Tz", pdfOpSetHorizontalScale)
        CGPDFOperatorTableSetCallback(table, "Ts", pdfOpSetRise)
        CGPDFOperatorTableSetCallback(table, "Td", pdfOpMoveLine)
        CGPDFOperatorTableSetCallback(table, "TD", pdfOpMoveLineSettingLeading)
        CGPDFOperatorTableSetCallback(table, "Tm", pdfOpSetTextMatrix)
        CGPDFOperatorTableSetCallback(table, "T*", pdfOpNextLine)
        CGPDFOperatorTableSetCallback(table, "Tj", pdfOpShow)
        CGPDFOperatorTableSetCallback(table, "'", pdfOpNextLineShow)
        CGPDFOperatorTableSetCallback(table, "\"", pdfOpNextLineShowSpaced)
        CGPDFOperatorTableSetCallback(table, "TJ", pdfOpShowAdjusted)
        CGPDFOperatorTableSetCallback(table, "Do", pdfOpDrawXObject)
        CGPDFOperatorTableSetCallback(table, "BI", pdfOpInlineImage)
    }

    // Everything below is called only from those callbacks, so it is `fileprivate` rather
    // than `private`.
    fileprivate func applyPushCTM() { pushCTM() }
    fileprivate func applyPopCTM() { popCTM() }
    fileprivate func applyConcatCTM(_ matrix: CGAffineTransform) { concatCTM(matrix) }
    fileprivate func applyBeginText() { beginText() }
    fileprivate func applyEndText() { endText() }
    fileprivate func applySetFont(name: String?, size: Double) { setFont(name: name, size: size) }
    fileprivate func applyMoveLine(dx: Double, dy: Double) { moveLine(dx: dx, dy: dy) }
    fileprivate func applySetTextMatrix(_ matrix: CGAffineTransform) { setTextMatrix(matrix) }
    fileprivate func applyNextLine() { nextLine() }
    fileprivate func applyShow(_ bytes: [UInt8]) { show(bytes) }
    fileprivate func applyAdvance(by tx: Double) { advance(by: tx) }
    fileprivate func applyDrawXObject(_ name: String) { drawNamedXObject(name) }
    fileprivate func applyInlineImage() { recordRaster() }
    fileprivate var currentFontSize: Double { fontSize }
    fileprivate var currentHorizontalScale: Double { horizontalScale }
    fileprivate func setLeadingValue(_ value: Double) { leading = value }
    fileprivate func setCharSpacingValue(_ value: Double) { charSpacing = value }
    fileprivate func setWordSpacingValue(_ value: Double) { wordSpacing = value }
    fileprivate func setHorizontalScaleValue(_ value: Double) { horizontalScale = value }
    fileprivate func setRiseValue(_ value: Double) { rise = value }

    fileprivate static func popNumber(_ scanner: CGPDFScannerRef) -> Double {
        var value: CGPDFReal = 0
        CGPDFScannerPopNumber(scanner, &value)
        return Double(value)
    }

    fileprivate static func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform {
        // Operands pop in reverse: f, e, d, c, b, a.
        let f = popNumber(scanner), e = popNumber(scanner)
        let d = popNumber(scanner), c = popNumber(scanner)
        let b = popNumber(scanner), a = popNumber(scanner)
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
    }

    fileprivate static func popString(_ scanner: CGPDFScannerRef) -> [UInt8]? {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else { return nil }
        return bytes(of: string)
    }

    fileprivate static func bytes(of string: CGPDFStringRef) -> [UInt8] {
        let length = CGPDFStringGetLength(string)
        guard length > 0, let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    // MARK: - State transitions

    fileprivate func pushCTM() { ctmStack.append(ctm) }
    fileprivate func popCTM() { if let last = ctmStack.popLast() { ctm = last } }
    fileprivate func concatCTM(_ matrix: CGAffineTransform) { ctm = matrix.concatenating(ctm) }

    fileprivate func beginText() {
        textMatrix = .identity
        lineMatrix = .identity
    }

    fileprivate func endText() { flushWord() }

    fileprivate func setFont(name: String?, size: Double) {
        fontSize = size
        currentFont = name.flatMap { fonts[$0] }
    }

    /// A REPOSITION IS NOT ALWAYS A WORD BREAK, and assuming it is over-splits every word a
    /// Quartz PDF kerns.
    ///
    /// ctrl-kd's emitter writes one `Td` per line and one `Tj` per word or run, so flushing
    /// on every positioning operator is correct for its output — which is why the engine-side
    /// round-trip proof passed with that rule. AppKit does not: it repositions with `Tm`
    /// mid-word to apply kerning, so the same rule chopped single words into several. It
    /// showed up as this extractor finding 53 more words than PDFKit on LYING page 1, and
    /// downstream it is indistinguishable from the app misplacing text — an over-split word
    /// cannot match its WS7 token, so it lands as `word-unmatched` and its neighbours as
    /// `line-start-shift`, which is exactly the shape LYING and WARPRAYR were reporting.
    ///
    /// So: a move to a different baseline ends the word. A move along the SAME baseline ends
    /// it only if the gap is wide enough to be a space — 0.2 em, comfortably under the
    /// narrowest real space and comfortably over any kern.
    private func reposition(to matrix: CGAffineTransform, isNewLine: Bool) {
        let before = penPosition
        let after = (CGAffineTransform.identity).concatenating(matrix).concatenating(ctm)
        let sameBaseline = abs(Double(after.ty) - before.y) < 0.01
        let gap = Double(after.tx) - before.x
        // A horizontal jump ends the word only if it is about as wide as a SPACE in this
        // font — that is what a space is. A flat fraction of the em is not: 0.2em split
        // `Per--against` and `[It` on LYING, because a kern around punctuation can exceed
        // it, while a proportional face's space is only ~0.25em to begin with. Asking the
        // font for its own space width is the same question the gap is trying to answer.
        let spaceWidth = (currentFont?.width(for: 0x20) ?? 500) / 1000.0 * fontSize
        if isNewLine || !sameBaseline || gap < 0 || gap > 0.7 * spaceWidth {
            flushWord()
        }
        textMatrix = matrix
    }

    fileprivate func setTextMatrix(_ matrix: CGAffineTransform) {
        reposition(to: matrix, isNewLine: false)
        lineMatrix = matrix
    }

    fileprivate func moveLine(dx: Double, dy: Double) {
        let moved = CGAffineTransform(translationX: dx, y: dy).concatenating(lineMatrix)
        reposition(to: moved, isNewLine: dy != 0)
        lineMatrix = moved
        textMatrix = moved
    }

    fileprivate func nextLine() { moveLine(dx: 0, dy: -leading) }

    fileprivate func advance(by tx: Double) {
        textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
    }

    // MARK: - Characters, and the segmentation ctrl-kd defines

    /// One drawn character, with the two numbers segmentation needs.
    struct Glyph {
        let text: Character
        let xStart: Double
        let xEnd: Double
        let baseline: Double
        let size: Double
        let font: String?
        let fontClass: String
        let isSpace: Bool
        /// This face's own space width AT THIS SIZE AND SCALE, capped — see `spaceWidth`.
        let spaceWidthPt: Double
    }

    /// Not private: `AppPDFWords.inkRunsByBaseline` reads these to describe what is on a
    /// baseline for a FAILURE message. Read-only from outside.
    private(set) var glyphs: [Glyph] = []

    /// ctrl-kd's `WORD_GAP_SLACK_PT`. Decipoint quantisation in WS7's own measurements.
    private static let wordGapSlackPt = 0.15
    /// ctrl-kd's `WORD_GAP_MAX_PT` and `SUBSTITUTED_PROPORTIONAL_GAP_MAX_PT`. A face's
    /// nominal space width is not a safe merge threshold in this corpus, and a
    /// font-SUBSTITUTED proportional face is worse still, so both are capped.
    private static let wordGapMaxPt = 1.5
    private static let substitutedProportionalGapMaxPt = 0.3

    /// The pen's position in PAGE space, which is where a baseline actually is.
    ///
    /// `Ts` RISE IS DELIBERATELY NOT APPLIED. ctrl-kd's own extractor parses the rise and
    /// then does not use it: `engine_page_tokens` computes `'y_top': mb_h - op['y']` from
    /// the raw `Td` y, and its docstring states the convention outright. So a superscript
    /// reports its LINE's baseline, not the raised glyph's, and the whole recorded manifest
    /// plus every WS7 comparison is in those terms. It is also right for this comparison:
    /// PCL's own `ESC&a#V` positions the text baseline per line.
    ///
    /// Applying the rise cost exactly one row in the round-trip proof — LYING p1's footnote
    /// marker `1`, ours 104.00 against ctrl-kd's 108.00, x identical to the hundredth.
    private var penPosition: (x: Double, y: Double) {
        let rendering = textMatrix.concatenating(ctm)
        return (Double(rendering.tx), Double(rendering.ty))
    }

    /// Text-space units to PAGE points. `Tf`'s size is NOT the whole story.
    ///
    /// ctrl-kd's emitter puts the real size in `Tf` and leaves the text matrix at identity,
    /// so text space and page points coincide and this is 1. QUARTZ DOES NOT: it emits a
    /// nominal `Tf` size and carries the real scale in the text matrix. Computing a glyph's
    /// width as `width/1000 * fontSize` alone therefore produced a value far too small on
    /// the app's own PDF — every character's `xEnd` fell short of the next character's
    /// `xStart`, every inter-character gap looked wider than a space, and mechanism Z split
    /// BOXES into 2095 one-character "words". The engine's PDF was unaffected, which is
    /// exactly why the round-trip proof passed while the tier reported `pdf=None` on all 18
    /// documents.
    private var textToPageScale: Double {
        Double(textMatrix.concatenating(ctm).a)
    }

    /// The face's own space width in PAGE POINTS, capped. The cap is a point value in
    /// ctrl-kd (`WORD_GAP_MAX_PT` 1.5, `SUBSTITUTED_PROPORTIONAL_GAP_MAX_PT` 0.3), so it is
    /// applied AFTER scaling into page space, not before.
    private func spaceWidth(for font: PDFFont, fontClass: String) -> Double {
        let natural = font.width(for: 0x20) / 1000.0 * fontSize * horizontalScale
            * textToPageScale
        let cap = (fontClass == "serif" || fontClass == "sans")
            ? Self.substitutedProportionalGapMaxPt : Self.wordGapMaxPt
        return min(abs(natural), cap)
    }

    fileprivate func show(_ bytes: [UInt8]) {
        guard let font = currentFont else { return }
        let fontClass = AppPDFWords.fontClass(for: font.baseFont)
        for code in font.codes(in: bytes) {
            let character = font.character(for: code.value)
            let space = spaceWidth(for: font, fontClass: fontClass)
            let start = penPosition
            // The glyph's own advance, in TEXT space; `advance(by:)` puts it through the
            // matrices, so reading the pen again is what converts it to page points.
            let ownWidth = font.width(for: code.value) / 1000.0 * fontSize * horizontalScale
            advance(by: ownWidth)
            let end = penPosition
            glyphs.append(Glyph(
                text: character, xStart: start.x, xEnd: end.x,
                // EFFECTIVE size in page points, not the raw `Tf` operand. Quartz emits a
                // nominal `Tf 1` and carries the real size in the text matrix, so the raw
                // value was reported as 1 for all 12,939 characters of the app's LYING —
                // against ctrl-kd's 16 for the same document. Downstream that is not
                // cosmetic: `char_space_width_pt` derives the word-boundary threshold from
                // this size, so a size of 1 shrinks a fixed face's threshold from 1.35pt to
                // 0.45pt and re-segments the whole document.
                baseline: start.y, size: fontSize * abs(textToPageScale), font: font.baseFont,
                fontClass: fontClass, isSpace: character == " ", spaceWidthPt: space))
            // Character and word spacing advance the pen but are not part of the glyph.
            let spacing = charSpacing + (code.isSingleByteSpace ? wordSpacing : 0)
            if spacing != 0 { advance(by: spacing * horizontalScale) }
        }
    }

    /// Retained so the positioning operators can still call it; segmentation no longer
    /// happens as characters arrive, so there is nothing to flush.
    fileprivate func flushWord() {}

    /// Every drawn character, in the engine-chars v2 shape. No segmentation, by design.
    func emittedChars() -> [AppPDFWords.Char] {
        glyphs.map { glyph in
            AppPDFWords.Char(
                text: String(glyph.text),
                x_pt: glyph.xStart - pageOrigin.x,
                x_end_pt: glyph.xEnd - pageOrigin.x,
                y_top_pt: pageHeight - (glyph.baseline - pageOrigin.y),
                size_pt: glyph.size, font: glyph.font, font_class: glyph.fontClass,
                page: pageNumber)
        }
    }

    /// The x of the leftmost PAINTED glyph on each baseline — whitespace skipped.
    ///
    /// Not derivable from the words: ctrl-kd's segmentation keeps a leading tab INSIDE its
    /// word (`is_space` is `raw_ch == ' '`, space only), so RNFOREST's first word is `\tThe`
    /// and its x is the TAB's position, 72.00, not the "T" at 79.20. That is right for
    /// matching words across the two sides and wrong for asking "where does this line's ink
    /// begin", because a tab paints nothing.
    ///
    /// Reading it off the glyph stream answers that exactly, with no assumption of fixed
    /// pitch and no second copy of the segmentation rule. The extractor's own words are left
    /// exactly as ctrl-kd would segment them.
    ///
    /// TEXT ink, so box-drawing and block characters are skipped alongside whitespace. Same
    /// rule and same reason as `GeometryOracleTests.inkOffset`: this feeds a comparison whose
    /// other side is the ENGINE's PDF, where `CtrlKD.graphicChars` are drawn as vector fills
    /// and so appear in no text operator at all. On the engine's own bytes the filter is a
    /// no-op — it writes no such glyph — so both sides answer the same question.
    ///
    /// This is the SECOND path the left-margin oracle reads first ink through, and it was
    /// missed when the first was fixed: `inkOffset` walks the app's LAYOUT, while this walks
    /// the app's own PDF for an oversized line, whose ink lives in the self-pass overlay
    /// rather than the text flow. Fixing one and not the other left LJ6DTP line 9 as the sole
    /// survivor of a cluster that went from 14 rows to 2 — a good illustration that "the
    /// cluster is one cause" and "one edit fixes the cluster" are different claims.
    func firstInkByBaseline() -> [Double: Double] {
        var out: [Double: Double] = [:]
        for glyph in glyphs
        where !glyph.text.isWhitespace && !CtrlKD.graphicChars.contains(glyph.text) {
            let key = (glyph.baseline * 100).rounded() / 100
            out[key] = min(out[key] ?? .greatestFiniteMagnitude, glyph.xStart)
        }
        return out
    }

    /// SEGMENTATION IS CTRL-KD'S, NOT MINE — a deliberate port of `segment_words_from_chars`
    /// (tools/fidelity_gate.py, mechanism Z), rule for rule.
    ///
    /// A space character always ends the current word and is itself dropped; otherwise a
    /// boundary falls wherever the gap since the previous character's own `xEnd` is at or
    /// past the SMALLER of the two characters' capped space widths, less the slack. **A
    /// font, size, style or rise change alone is NEVER a boundary** — only real horizontal
    /// distance is.
    ///
    /// This replaced my own rule, and the difference mattered: mine broke a word wherever
    /// the pen was repositioned onto a different baseline, so LYING's footnote marker came
    /// out as `Prize.` + `1` where ctrl-kd now reads `Prize.1`, and -SCREEN's cp437 Greek run
    /// fragmented at every Symbol/Courier switch. Two extractors that segment differently
    /// cannot be compared at all, whatever their coordinates say — and ctrl-kd's is the one
    /// the manifest and the WS7 side are both expressed in, so it is the one to match.
    func segmentedWords() -> [AppPDFWords.Word] {
        var byLine: [Double: [Glyph]] = [:]
        for glyph in glyphs {
            byLine[(glyph.baseline * 100).rounded() / 100, default: []].append(glyph)
        }
        var out: [AppPDFWords.Word] = []
        // DESCENDING, because `baseline` is raw PDF y and PDF space counts UP from the
        // bottom — so descending is READING ORDER, top of the page first. ctrl-kd's
        // engine_page_tokens says exactly this at its own loop: `for y in sorted(by_baseline,
        // reverse=True)  # reading order: top of page first`.
        //
        // Ascending emitted the page bottom-first, and the gate aligns a document's words
        // with difflib, so reversed line order destroyed the alignment while every
        // individual word stayed correct: BOXES came back with 'UL:' at ws7 y=276 paired
        // against the app's y=336 and the other 'UL:' the other way round, x agreeing to
        // 0.04pt. It read as 85 baseline-shifts and 85 unmatched words on a page whose text
        // was entirely right.
        //
        // The round-trip proof could not catch this: it compares as multisets keyed by
        // (page, text), which is deliberately order-insensitive, so word ORDER is exactly
        // the property it cannot see. Noted rather than fixed there — making that comparison
        // order-sensitive would reintroduce the pairing problem it was written to avoid.
        for baseline in byLine.keys.sorted(by: >) {
            let line = byLine[baseline]!.sorted { $0.xStart < $1.xStart }
            var current: [Glyph] = []
            func finish() {
                guard let first = current.first else { return }
                out.append(AppPDFWords.Word(
                    text: String(current.map(\.text)),
                    x_pt: first.xStart - pageOrigin.x,
                    y_top_pt: pageHeight - (first.baseline - pageOrigin.y),
                    size_pt: first.size, font: first.font, font_class: first.fontClass,
                    page: pageNumber))
                current = []
            }
            for glyph in line {
                if glyph.isSpace { finish(); continue }
                if let previous = current.last {
                    let gap = glyph.xStart - previous.xEnd
                    let threshold = min(previous.spaceWidthPt, glyph.spaceWidthPt)
                    if gap >= threshold - Self.wordGapSlackPt { finish() }
                }
                current.append(glyph)
            }
            finish()
        }
        return out
    }

    /// `Do` resolves the named XObject and either records an image or RECURSES INTO A FORM.
    ///
    /// Recursing is not optional, and assuming otherwise cost a whole round: AppKit draws an
    /// embedded picture inside a Form XObject, and `CGPDFScanner` does not follow `Do` on its
    /// own. Without this, every one of the app's rasters was recorded as the unit square
    /// under an identity CTM — the gate saw `pdf=[0, 791]` for PREVIEW's only picture and
    /// called it a `raster-position-shift` of dy=+356.30pt. That reads exactly like the app
    /// misplacing a picture, and it was this scanner never seeing the `cm` that places it.
    /// Text inside a form was invisible for the same reason.
    fileprivate func drawNamedXObject(_ name: String) {
        var xobjects: CGPDFDictionaryRef?
        guard let currentResources = resources,
              CGPDFDictionaryGetDictionary(currentResources, "XObject", &xobjects),
              let xobjects else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream else { return }

        let dictionary = CGPDFStreamGetDictionary(stream)
        var subtype: UnsafePointer<Int8>?
        var kind = ""
        if let dictionary, CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
           let subtype { kind = String(cString: subtype) }

        if kind == "Form" {
            enterForm(stream: stream, dictionary: dictionary)
        } else {
            recordRaster()
        }
    }

    /// An image draws the unit square through the CTM, so the CTM IS the placed box.
    fileprivate func recordRaster() {
        let width = Double(ctm.a), height = Double(ctm.d)
        guard width > 0, height > 0 else { return }
        rasters.append(AppPDFWords.Raster(
            x_pt: Double(ctm.tx) - pageOrigin.x,
            y_top_pt: pageHeight - (Double(ctm.ty) - pageOrigin.y) - height,
            w_pt: width, h_pt: height, page: pageNumber))
    }

    /// Scan a Form XObject's own content stream in the caller's graphics state, with the
    /// form's `/Matrix` applied and its own `/Resources` in force.
    private func enterForm(stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef?) {
        guard formDepth < 8, let parent = contentStream else { return }
        formDepth += 1
        defer { formDepth -= 1 }

        let savedCTM = ctm, savedStack = ctmStack, savedFonts = fonts
        let savedResources = resources, savedStream = contentStream
        let savedText = textMatrix, savedLine = lineMatrix
        defer {
            ctm = savedCTM; ctmStack = savedStack; fonts = savedFonts
            resources = savedResources; contentStream = savedStream
            textMatrix = savedText; lineMatrix = savedLine
        }

        if let dictionary {
            var matrixArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray,
               CGPDFArrayGetCount(matrixArray) == 6 {
                var values = [Double](repeating: 0, count: 6)
                for index in 0..<6 {
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(matrixArray, index, &value) {
                        values[index] = Double(value)
                    }
                }
                ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                        d: values[3], tx: values[4], ty: values[5])
                    .concatenating(ctm)
            }
            var formResources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources),
               let formResources {
                resources = formResources
                loadFonts(from: formResources)
            }
        }

        guard let table = CGPDFOperatorTableCreate() else { return }
        defer { CGPDFOperatorTableRelease(table) }
        Self.install(into: table)
        guard let streamDictionary = dictionary else { return }
        let nested = CGPDFContentStreamCreateWithStream(stream, streamDictionary, parent)
        defer { CGPDFContentStreamRelease(nested) }
        contentStream = nested
        let scanner = CGPDFScannerCreate(nested, table,
                                         Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        flushWord()
        CGPDFScannerScan(scanner)
        flushWord()
    }
}

// MARK: - The operator callbacks, one file-scope constant each

// These are deliberately NOT closures inside `PageScan.install(into:)`. Seventeen
// `@convention(c)` callbacks in one function body crashes swift-frontend in the
// `SendNonSendable` SIL pass (see `install(into:)`'s own note). One constant each keeps every
// SIL function small enough for that pass to complete, and reads no worse.

private func pdfScan(_ info: UnsafeMutableRawPointer?) -> PageScan? {
    info.map { Unmanaged<PageScan>.fromOpaque($0).takeUnretainedValue() }
}

private let pdfOpPushState: CGPDFOperatorCallback = { _, info in pdfScan(info)?.applyPushCTM() }
private let pdfOpPopState: CGPDFOperatorCallback = { _, info in pdfScan(info)?.applyPopCTM() }

private let pdfOpConcat: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.applyConcatCTM(PageScan.popMatrix(scanner))
}

private let pdfOpBeginText: CGPDFOperatorCallback = { _, info in pdfScan(info)?.applyBeginText() }
private let pdfOpEndText: CGPDFOperatorCallback = { _, info in pdfScan(info)?.applyEndText() }

private let pdfOpSetFont: CGPDFOperatorCallback = { scanner, info in
    var size: CGPDFReal = 0
    CGPDFScannerPopNumber(scanner, &size)
    var name: UnsafePointer<Int8>?
    CGPDFScannerPopName(scanner, &name)
    pdfScan(info)?.applySetFont(name: name.map { String(cString: $0) }, size: Double(size))
}

private let pdfOpSetLeading: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.setLeadingValue(PageScan.popNumber(scanner))
}
private let pdfOpSetCharSpacing: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.setCharSpacingValue(PageScan.popNumber(scanner))
}
private let pdfOpSetWordSpacing: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.setWordSpacingValue(PageScan.popNumber(scanner))
}
private let pdfOpSetHorizontalScale: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.setHorizontalScaleValue(PageScan.popNumber(scanner) / 100.0)
}
private let pdfOpSetRise: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.setRiseValue(PageScan.popNumber(scanner))
}

private let pdfOpMoveLine: CGPDFOperatorCallback = { scanner, info in
    let y = PageScan.popNumber(scanner), x = PageScan.popNumber(scanner)
    pdfScan(info)?.applyMoveLine(dx: x, dy: y)
}

private let pdfOpMoveLineSettingLeading: CGPDFOperatorCallback = { scanner, info in
    let y = PageScan.popNumber(scanner), x = PageScan.popNumber(scanner)
    guard let scan = pdfScan(info) else { return }
    scan.setLeadingValue(-y)
    scan.applyMoveLine(dx: x, dy: y)
}

private let pdfOpSetTextMatrix: CGPDFOperatorCallback = { scanner, info in
    pdfScan(info)?.applySetTextMatrix(PageScan.popMatrix(scanner))
}

private let pdfOpNextLine: CGPDFOperatorCallback = { _, info in pdfScan(info)?.applyNextLine() }

private let pdfOpShow: CGPDFOperatorCallback = { scanner, info in
    guard let bytes = PageScan.popString(scanner) else { return }
    pdfScan(info)?.applyShow(bytes)
}

private let pdfOpNextLineShow: CGPDFOperatorCallback = { scanner, info in
    guard let bytes = PageScan.popString(scanner), let scan = pdfScan(info) else { return }
    scan.applyNextLine()
    scan.applyShow(bytes)
}

private let pdfOpNextLineShowSpaced: CGPDFOperatorCallback = { scanner, info in
    guard let bytes = PageScan.popString(scanner) else { return }
    let charSp = PageScan.popNumber(scanner), wordSp = PageScan.popNumber(scanner)
    guard let scan = pdfScan(info) else { return }
    scan.setWordSpacingValue(wordSp)
    scan.setCharSpacingValue(charSp)
    scan.applyNextLine()
    scan.applyShow(bytes)
}

private let pdfOpShowAdjusted: CGPDFOperatorCallback = { scanner, info in
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array, let scan = pdfScan(info) else { return }
    for index in 0..<CGPDFArrayGetCount(array) {
        var string: CGPDFStringRef?
        if CGPDFArrayGetString(array, index, &string), let string {
            scan.applyShow(PageScan.bytes(of: string))
            continue
        }
        var number: CGPDFReal = 0
        if CGPDFArrayGetNumber(array, index, &number) {
            // A TJ adjustment is thousandths of text space and moves the pen LEFT when
            // positive.
            scan.applyAdvance(by: -Double(number) / 1000.0 * scan.currentFontSize
                              * scan.currentHorizontalScale)
        }
    }
}

private let pdfOpDrawXObject: CGPDFOperatorCallback = { scanner, info in
    var name: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    pdfScan(info)?.applyDrawXObject(String(cString: name))
}

private let pdfOpInlineImage: CGPDFOperatorCallback = { _, info in
    pdfScan(info)?.applyInlineImage()
}
