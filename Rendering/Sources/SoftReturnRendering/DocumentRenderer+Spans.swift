#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Spans to attributed text

    /// The document's own 10-CPI print column, as a fraction of the type size — WordStar's
    /// grid and Courier's own advance are the same number, which is why a Courier run is how
    /// this file spends a column width.
    public static let nativeColumnEM: CGFloat = 0.6

    /// One span appended to `line`, threading the leading-indent gate the CALLER's whole
    /// line shares — extracted from `attributedLine`'s own per-span loop (job 256, Show
    /// Invisibles part 2/4: `renderNativeAnnotated` needed this same per-span logic
    /// available to call once per `.visible` `AnnotatedSpan`, interleaved with its own
    /// invisible-mark runs, rather than duplicating it). Pure extraction — every existing
    /// `attributedLine` caller's behavior is unchanged; `showInvisiblesOffStateByteIdentical`
    /// and the oracle/structural-parity gates are what verify that.
    static func appendSpan(
        _ span: Span, to line: NSMutableAttributedString, leading: inout Bool,
        font: NSFont, paragraph: NSParagraphStyle, fonts: [FontChange], defaultSize: Int,
        colourMap: [Int: Double], disableKerning: Bool, useCourierPrime: Bool = false,
        pixResults: [PixResult] = [], pixMeasureWidthPt: Double = 0,
        nativeSupSub: Bool = false, nativeFullScripts: Bool = false, nativeRoll: Double? = nil, nativePMActive: Bool? = nil,
        nativeKerning: Bool = true, modernPitchScale: Bool = false,
        modernPrintedPt: Int? = nil, modernFontlessFamily: CtrlKD.PDFFamily = .times
    ) {
        // Job 371 item 1 (PIX IN VIEWS): a resolved `.PIX` tag, INLINE — the shape Modern's
        // own reflow keeps `span.pix` in (unlike Printed, whose `docToPagelines` already
        // substituted a whole `PageLine.image` before any span reaches here — see
        // `lineAndTerminator`'s own doc comment). An unresolved tag (`ok == false`, or the
        // index missing from `pixResults` entirely — a caller that never resolved anything)
        // falls straight through to the plain-text branch below, which renders the span's
        // own literal "[image: NAME]" placeholder — "missing image = placeholder text,
        // never an error" (job 371's own brief, restating the 2026-08-17 ruling).
        //
        // `span.pix ?? Self.inferredPixIndex(...)`: `modernSemanticFlow`'s own `SemanticRun`
        // (`Layout.swift`, CtrlKD) carries no `pix` field at all — text/styles/font/colour/
        // ref only — so `modernParagraphContent`'s `Span(text:styles:font:colour:)`
        // reconstruction (this file) can never set `pix` for a Modern span, even though the
        // run's OWN text is still the exact same "[image: NAME]" placeholder the parser
        // wrote. Rather than porting a `pix` field onto `SemanticRun` in the engine repo
        // (no push access there — see `DocumentPictures.resolve`'s own header), this reads
        // the same NAME straight back out of the placeholder text `appendSpan` is about to
        // render anyway and matches it against `pixResults` by basename
        // (`pixBasename(rawPath)`, the identical string `SymmetricBlocks.swift`'s own
        // placeholder-building used to construct it) — the addressability the field would
        // have given directly, recovered from the one place it still exists.
        let pixIndex = span.pix ?? Self.inferredPixIndex(fromPlaceholderText: span.text, pixResults: pixResults)
        if let pixIndex, pixResults.indices.contains(pixIndex), pixResults[pixIndex].ok {
            let (wPt, hPt) = pixDimsPt(pixResults[pixIndex], measureWidthPt: pixMeasureWidthPt)
            line.append(Self.pixAttachmentString(
                pixResults, index: pixIndex, widthPt: wPt, heightPt: hPt, paragraph: paragraph))
            leading = false
            return
        }
        // M10, ported from `PDFWriter.lineOpsPrinted` (`PDFWriter.swift:466-475`): a
        // 0x0F user print control's display string is SCREEN-ONLY — on paper WordStar
        // sent the printer its raw control payload, never the human-readable string
        // (`Shaded Relative -00.250"...`, `Empty |00.300"hx...`) the parser decoded for
        // display. The engine draws nothing and advances by the block's own declared
        // HMI width; this is the FIRST check per span there, ahead of font/colour/
        // graphics handling, because a pctl span never carries any of those. Same
        // order here, same reason: this app was drawing the raw display string as
        // literal paper content instead of skipping it (Jon's b11 field evidence).
        if let hmi = span.pctlHMI {
            line.append(Self.pctlAdvanceAttachment(hmi: hmi, pcl: span.pcl, paragraph: paragraph))
            return
        }
        // Job 503 item 1: `Span.tabHMI` — a REAL WordStar tab stop (a type-9 block, parsed
        // straight off the file — `ParseWS.swift`'s own citation), carrying its ABSOLUTE
        // target in HMI (1/1800in) FROM THE LINE'S OWN LEFT MARGIN. Never consumed by this
        // renderer before this job — every "column" symptom job 490/491 chased (table rows
        // that don't line up, the LJ6DTP masthead's shadow sitting at the wrong offset, the
        // checkerboard's 18pt-in-the-engine cell pitch, the flush-right overprint bars) is
        // WordStar authoring its OWN real tab stops, not literal typed filler spaces —
        // confirmed directly against this fixture (`outbox/job503/scratch-title-dump.txt`,
        // since discarded): the masthead's two "leading space" spans measured
        // `tabHMI=2414`/`2502` — `2414/25=96.56pt`, `+50.4pt` margin `=146.96`, matching the
        // pinned engine's own PDF `Td` x `147.0` to within decipoint rounding — and the
        // checkerboard's 33 two-space separators are ALL `tabHMI`-marked at steps of 450
        // (`450/25=18.0pt`, the engine's own real cell pitch, not this app's previous
        // 14.4pt). `appendProportionalRun`'s space/period-run "10-CPI grid" heuristic
        // (job 490) approximated the same INTENT by counting literal characters — wrong
        // whenever the real target (this field) doesn't land on a whole grid multiple,
        // which is most of the time. Checked ahead of that heuristic (and of the
        // leading-indent special case just below, which this field's own presence already
        // supersedes) — same order `PDFWriter.swift`'s `lineOpsPrinted` checks it in,
        // right after `pctlHMI`.
        if let tabHMI = span.tabHMI {
            Self.appendTabRun(span, tabHMI: tabHMI, font: font, paragraph: paragraph, fonts: fonts,
                              defaultSize: defaultSize, colourMap: colourMap,
                              useCourierPrime: useCourierPrime, to: line)
            if span.text.contains(where: { !$0.isWhitespace }) {
                leading = false
            }
            return
        }
        // A PROPORTIONAL WS5+ font run's LEADING spaces are WordStar's own indent
        // positioning, re-stamped onto the document's fixed 10-CPI column grid rather
        // than the run's own (narrower) proportional advance — `PDFWriter.swift`'s own
        // doc comment on `splitIndent`: "WordStar re-stamps a left indent... as
        // machine spaces, and every one of those commands is specified in 10-CPI print
        // columns." `courier(size:)` at the document's base size already advances at
        // exactly that grid (10 CPI = `size * 0.6`pt/char, this file's own
        // `PDFMetrics`-matching convention), so rendering just the leading-space
        // PREFIX in `font` — the document's base Courier passed into this function,
        // not `resolvedFont`'s proportional face — reproduces the engine's
        // `Double(seg.text.width) * Double(size) * 0.6` indent width (`PDFWriter.swift:541`)
        // by construction, with no separate width arithmetic needed here. This is
        // Jon's field symptom (title/author/awards sitting left of the engine's
        // placement on `OLDTIMES.WS` p1) — the proportional font's own narrower space
        // advance was carrying the indent instead of the document's column grid.
        //
        // Gated the same way the engine gates it: only while `leading` (nothing real
        // has printed yet on this line) and only for a run with a PROPORTIONAL font
        // block. A fixed-pitch block's own space already sits on the document's grid
        // (`PDFWriter.swift`'s own note: "For 10-CPI Courier the two measures are the
        // same number"), and a fontless span's pitch already IS the document's — both
        // already correct under `resolvedFont`'s plain advance, so neither is split.
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        // MODERN NEVER RE-STAMPS. `splitIndent`'s Courier-grid re-stamp (job 202) and its
        // generalization to any column filler run (job 490, `appendProportionalRun` below)
        // are both facsimile rules: Printed and Native have to land on WordStar's own
        // character grid because the author typed a column position and the paper shows it.
        // `modernTokenWidth` has no counterpart — a space run is ordinary text there,
        // measured at the face's own advance and scaled by the same `faceTz` as everything
        // else around it. Measured on LYING.WS, whose body paragraphs open with five typed
        // spaces: the library indents its first line 15.70pt (5 x 3.0pt Times at 12pt,
        // x104.81%) and the app stamped 36.01pt (5 x 7.2pt columns), so every opening line
        // measured 20pt narrower here and the paragraph rewrapped from its first word on.
        if leading, !modernPitchScale, let entry, entry.proportional {
            let pad = span.text.prefix(while: { $0 == " " }).count
            if pad > 0 {
                // AT THE SPAN'S OWN SIZE, not the document's base one. The engine's indent
                // advance is per-SEGMENT — the size its own font block asks for — while this
                // passed the document's base Courier throughout. The two agree on any document
                // whose font block happens to run at the body size, which is every fixture
                // this was built on; they do not agree on MARKUP.WS, whose Univers block is
                // far smaller. Its line 2 opens with four spaces and the app re-stamped them
                // at 7.2pt each, putting the line's first ink at 86.40 where the engine draws
                // it at 60.30.
                //
                // AND AT THE ENGINE'S OWN TWO MEASURES, which is a `.pm` question. `.pm`'s
                // document-column convention is the 10-CPI grid this comment block opens
                // with, and it is in force only while the line's own block declares a real
                // paragraph margin (`PageLine.pmActive`). Every OTHER typed leading run —
                // hand-typed centring, a table's leading gap — is what real WS7 drew with the
                // face's own space glyph, and the engine measures those at `typedIndentSpaceEM`
                // (`PDFLayout.swift`, planning #257: 0.336em, measured against real WS7's own
                // Univers 10pt space). MARKUP.WS declares no `.pm`, so its four spaces are
                // 4 x 2 x 0.336 = 2.69pt and the app was charging 4 x 2 x 0.6 = 4.80 — the
                // 2.10pt this line's first ink was still out by.
                //
                // COURIER IS THE WIDTH VEHICLE, not a claim about the face: this run draws no
                // ink at all, and Courier's own 0.6em advance is how the block above already
                // spends a width it has computed. Its size is therefore the width WANTED
                // divided by that 0.6, not the span's own size.
                let spanPt = resolvedFont(
                    for: span, fallback: font, fonts: fonts, defaultSize: defaultSize,
                    useCourierPrime: useCourierPrime).pointSize
                let perSpacePt = nativePMActive == true
                    ? CGFloat(defaultSize) * nativeColumnEM
                    : (nativePMActive == nil ? spanPt * nativeColumnEM
                                              : spanPt * CGFloat(CtrlKD.typedIndentSpaceEM))
                let indentFont = courier(size: perSpacePt / nativeColumnEM)
                var indentAttributes: [NSAttributedString.Key: Any] = [
                    .font: indentFont,
                    .paragraphStyle: paragraph,
                ]
                indentAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
                if disableKerning { indentAttributes[.kern] = nativeNoKerning }
                if disableKerning { indentAttributes[.ligature] = nativeNoLigatures }
                line.append(NSAttributedString(
                    string: String(span.text.prefix(pad)), attributes: indentAttributes))
                if pad == span.text.count {
                    // The WHOLE run was leading whitespace — still leading, exactly
                    // like `splitIndent`'s own `else` branch (a later span may carry
                    // more of the same line's indent before real content arrives).
                    return
                }
                let rest = Span(text: String(span.text.dropFirst(pad)), styles: span.styles,
                                font: span.font, colour: span.colour, pctlHMI: span.pctlHMI)
                Self.appendProportionalRun(
                    rest, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                    colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                    nativeKerning: nativeKerning, modernPitchScale: modernPitchScale,
                    modernPrintedPt: modernPrintedPt,
                    modernFontlessFamily: modernFontlessFamily, to: line)
                leading = false
                return
            }
        }
        if let entry, entry.proportional {
            Self.appendProportionalRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                nativeSupSub: nativeSupSub, nativeFullScripts: nativeFullScripts, nativeRoll: nativeRoll, nativeKerning: nativeKerning,
                modernPitchScale: modernPitchScale, modernPrintedPt: modernPrintedPt,
                modernFontlessFamily: modernFontlessFamily, to: line)
        } else {
            line.append(Self.attributedRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                nativeSupSub: nativeSupSub, nativeFullScripts: nativeFullScripts, nativeRoll: nativeRoll, nativeKerning: nativeKerning,
                modernPitchScale: modernPitchScale, modernPrintedPt: modernPrintedPt,
                modernFontlessFamily: modernFontlessFamily))
        }
        if span.text.contains(where: { !$0.isWhitespace }) {
            leading = false
        }
    }

    /// Job 490 item 2 (Jon: "Make sure that all columns in tables line up. They're all
    /// over the place right now" — confirmed against real WS7's `LJ6DTP-p3.png`: the
    /// reference has every column dead-aligned, ours drifts). WordStar authors a table by
    /// typing runs of literal spaces to reach the next column, on the file's own fixed
    /// 10-CPI character grid — under a PROPORTIONAL Mac font substitute, a run of N literal
    /// spaces measures narrower than the N grid CELLS the author actually counted, and by a
    /// DIFFERENT amount per row (the text preceding the run varies), so two rows whose
    /// author-typed column position was IDENTICAL drift apart on screen. `PDFWriter.swift`'s
    /// own `splitIndent` already re-stamps a LINE's LEADING space run onto the document's
    /// own Courier grid (`font`, this file's `size * 0.6`pt/char convention) instead of the
    /// proportional face's own advance (the `if leading, let entry, entry.proportional`
    /// block above, job 202) — this is that SAME re-stamp, generalized to any run of 2+
    /// consecutive column FILLER characters (`isColumnFillerChar`: a space, or — p5's
    /// dot-leader rows, `"Shading 85%................"` — a period) ANYWHERE in a
    /// proportional span, not just the line-initial one.
    ///
    /// A run of exactly ONE space is left untouched, laying out at the resolved font's own
    /// natural advance like ordinary prose — the MAC VIEWING RULING (job 240, `attributedRun`'s
    /// own doc comment) removed PER-WORD corrective kerning specifically so single-space-
    /// separated prose keeps reading naturally, and this does not reopen that: a genuine
    /// inter-word gap is one space, so it never qualifies. Two-or-more is the signal a human
    /// typed deliberate column padding, not a sentence — the same signal a monospace-authored
    /// document already gives a reader.
    ///
    /// Applies identically to Native and (this app's own on-screen/export) Printed, which
    /// share this function — see `resolvedFont`'s own doc comment ("Native only changes
    /// fonts. Otherwise it's the same as Printed", job 427's ruling). Measured directly
    /// (job 490): both currently show the IDENTICAL drift on `LJ6DTP.WS` p3/p5, since neither
    /// applied any re-stamping past the leading run — the true byte-exact reference PDF
    /// (`CtrlKD`'s own `PDFWriter.emitPDF`, a separate code path this app never renders
    /// through on screen) is what already gets this right; this app's own two AppKit
    /// renderers did not, equally.
    static func appendProportionalRun(
        _ span: Span, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double],
        disableKerning: Bool, useCourierPrime: Bool, nativeSupSub: Bool = false, nativeFullScripts: Bool = false,
        nativeRoll: Double? = nil, nativeKerning: Bool = true, modernPitchScale: Bool = false,
        modernPrintedPt: Int? = nil, modernFontlessFamily: CtrlKD.PDFFamily = .times,
        to line: NSMutableAttributedString
    ) {
        // Modern does not re-stamp a filler run either — see `appendSpan`'s own citation.
        let segments = modernPitchScale ? [] : Self.splitOnColumnSpaceRuns(span.text)
        guard segments.count > 1 || segments.first?.isGrid == true else {
            line.append(Self.attributedRun(
                span, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                nativeSupSub: nativeSupSub, nativeFullScripts: nativeFullScripts, nativeRoll: nativeRoll, nativeKerning: nativeKerning,
                modernPitchScale: modernPitchScale, modernPrintedPt: modernPrintedPt,
                modernFontlessFamily: modernFontlessFamily))
            return
        }
        // THE SPAN'S OWN CELL, not the document's.
        //
        // The grid this re-stamp puts a filler run on is `spanPitch`'s, and `spanPitch` reads
        // the FONT BLOCK's own declared width word (`.cw`, `FontChange.width1800`) when it has
        // one, falling back to the document's 10-CPI Courier column only when it does not.
        // Passing the caller's base Courier here was the fallback unconditionally — the same
        // answer the engine gives for a span with no font block at all, and the wrong one for
        // every span that has one.
        //
        // LJ6DTP.WS is the document it was written for and the document it was wrong on: its
        // Univers block declares 245/1800in, a 9.80pt cell, and this stamped every filler run
        // in it at the document's own 7.20pt. 2.6pt per cell, cumulative across a table row —
        // the column drift Jon reported, closed for the leading run and left open for every
        // other one.
        //
        // Courier is the width vehicle, as it is for the leading indent above: the run draws
        // no ink of its own, and a Courier face sized so its 0.6em IS the cell spends exactly
        // that width.
        //
        // PRINTED ONLY, gated on `disableKerning` the way every other engine-grid rule in this
        // file is. Modern is a reflowed reading view with no column grid of its own, and the
        // engine's Modern layout has no `spanPitch` anywhere in it; measured, giving Modern
        // the span's cell moved PREVIEW.WS's line breaks and nothing else's, which is drift
        // rather than fidelity. Modern keeps the document cell it always had.
        // AND NOT IN NATIVE EITHER. This was `disableKerning ? nativeSpanPitch(<the span's font
        // block>, <its point size>) : 0` — the span's OWN declared cell for every filler run the two
        // facsimile modes draw. It cost PREVIEW.WS six words of drift past the Native gate's
        // own tolerance (three Univers, three CG Times), measured against real WS7 paper, and
        // the paper is that gate's authority. The document's own cell — the caller's base
        // Courier, which is what this always used — stands until something measures the span
        // cell against the PAPER and finds it closer.
        let gridFont = font
        for segment in segments where !segment.text.isEmpty {
            if segment.isGrid {
                var gridAttributes: [NSAttributedString.Key: Any] = [
                    .font: gridFont,
                    .paragraphStyle: paragraph,
                ]
                gridAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
                if disableKerning { gridAttributes[.kern] = nativeNoKerning }
                if disableKerning { gridAttributes[.ligature] = nativeNoLigatures }
                line.append(NSAttributedString(string: segment.text, attributes: gridAttributes))
            } else {
                let piece = Span(text: segment.text, styles: span.styles, font: span.font,
                                 colour: span.colour, pctlHMI: span.pctlHMI)
                line.append(Self.attributedRun(
                    piece, font: font, paragraph: paragraph, fonts: fonts, defaultSize: defaultSize,
                    colourMap: colourMap, disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                    nativeSupSub: nativeSupSub, nativeFullScripts: nativeFullScripts, nativeRoll: nativeRoll))
            }
        }
    }

    /// A WordStar column filler character — a plain space, or (LJ6DTP p5's "Color Mappings"
    /// chart: `"Shading 85%................"`) a dot-leader period.
    static func isColumnFillerChar(_ c: Character) -> Bool { c == " " || c == "." }

    /// Splits `text` on every MAXIMAL run of 2+ consecutive occurrences of the SAME filler
    /// character (see `isColumnFillerChar`) — see `appendProportionalRun`'s own doc comment
    /// for why 2 is the threshold. A run never MIXES spaces and periods: ordinary prose
    /// punctuation (a sentence-ending period followed by the typewriter convention's own
    /// two spaces, `". "` × 2 — common throughout this proportional-font corpus) is one
    /// single, un-grid-stamped period immediately followed by its OWN 2-space grid run, not
    /// one merged three-character leader — merging them was tried and measured to visibly
    /// distort ordinary sentence punctuation across the whole document (the period itself
    /// landing at the Courier grid's width, not its own proportional face's), so runs are
    /// homogeneous by construction: `j` only extends while it keeps seeing the SAME
    /// character `chars[i]` started with. Order-preserving; a segment is never empty except
    /// possibly a leading/trailing one, which `appendProportionalRun`'s own
    /// `where !segment.text.isEmpty` filter skips.
    /// Internal rather than `private` (same rationale as `lineExceedsFragment`'s own doc
    /// comment) so `SoftReturnTests` can pin this splitter's exact segmenting behaviour
    /// directly, including the homogeneous-run regression guard described above.
    public static func splitOnColumnSpaceRuns(_ text: String) -> [(text: String, isGrid: Bool)] {
        var result: [(text: String, isGrid: Bool)] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if Self.isColumnFillerChar(chars[i]) {
                let filler = chars[i]
                var j = i
                while j < chars.count, chars[j] == filler { j += 1 }
                let runLength = j - i
                if runLength >= 2 {
                    if !current.isEmpty { result.append((current, false)); current = "" }
                    result.append((String(chars[i..<j]), true))
                } else {
                    current.append(chars[i])
                }
                i = j
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        if !current.isEmpty { result.append((current, false)) }
        return result
    }

    /// One laid-out line's spans as styled text.
    ///
    /// Internal rather than `private` so `SoftReturnTests` can exercise the mark-rendering
    /// fix below directly, against real `Span`/`Style` values, without round-tripping a
    /// footnote through the WS4 byte parser just to get one into a `Document`.
    public static func attributedLine(
        _ spans: [Span],
        font: NSFont,
        paragraph: NSParagraphStyle,
        fonts: [FontChange] = [],
        defaultSize: Int = 0,
        colourMap: [Int: Double] = [:],
        disableKerning: Bool = false,
        useCourierPrime: Bool = false,
        pixResults: [PixResult] = [],
        pixMeasureWidthPt: Double = 0,
        nativeSupSub: Bool = false,
        nativeFullScripts: Bool = false,
        nativeRoll: Double? = nil,
        nativePMActive: Bool? = nil,
        nativeKerning: Bool = true,
        nativeFace: PageLine.Face? = nil,
        modernPitchScale: Bool = false, modernPrintedPt: Int? = nil,
        modernFontlessFamily: CtrlKD.PDFFamily = .times
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        // Port of `splitIndent` (`PDFWriter.swift:389-421`): still true until the first
        // non-whitespace content on this line — see `appendSpan`'s own note below for what
        // it gates.
        var leading = true
        for span in spans {
            appendSpan(span, to: line, leading: &leading, font: font, paragraph: paragraph,
                      fonts: fonts, defaultSize: defaultSize, colourMap: colourMap,
                      disableKerning: disableKerning, useCourierPrime: useCourierPrime,
                      pixResults: pixResults, pixMeasureWidthPt: pixMeasureWidthPt,
                      nativeSupSub: nativeSupSub, nativeFullScripts: nativeFullScripts, nativeRoll: nativeRoll, nativePMActive: nativePMActive,
                      nativeKerning: nativeKerning, modernPitchScale: modernPitchScale,
                      modernPrintedPt: modernPrintedPt,
                      modernFontlessFamily: modernFontlessFamily)
        }
        // A line with no spans at all (a blank PageLine) would otherwise be represented
        // on screen by nothing but its OWN terminator newline — a control character, which
        // AppKit positions at the BOTTOM of its (fixed-height) line fragment rather than at
        // the font's normal ascent-based baseline, unlike every real glyph. A blank line's
        // baseline then lands off the grid a real character's never would, even though its
        // FRAGMENT height (and therefore pagination) is unaffected. One space — invisible on
        // paper, and trimmed away everywhere the text is compared — gives the layout manager
        // a real glyph to place instead of the bare terminator.
        //
        // CORRECTION (job 408, `NativeStructuralParityTests.swift`'s own Class 4 comment):
        // "so a blank line's baseline sits on the same grid a line of text would" is WRONG —
        // measured directly (`Oracle.lines`' `location(forGlyphAt:).y` vs `fragment.origin.y`
        // under this same pinned min==max paragraph style), a blank/space-filler line's
        // baseline offset does NOT match a real-text line's: they differ by ~1pt (Courier
        // 12pt). The space filler's own offset happens to match the ENGINE's assumed grid
        // (proven via a graphics-only PageLine, which renders the same all-whitespace way and
        // lands exactly on the engine's Y) — it is real TEXT lines that sit ~1pt off, a defect
        // this filler never touched and an isolated single-glyph AppKit probe cannot
        // reproduce (job 408's report). Left as-is: swapping this filler cannot fix the actual
        // gap, since the gap is on the other side of it.
        if line.length == 0 {
            line.append(NSAttributedString(string: " ", attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.black,
            ]))
        }
        // A WS4 `.PS ON` line under HPLJET is drawn in the face of WS4's width tables
        // (`PageLine.face`, the engine's `lineOpsPrinted(face:)`), its words then pinned to
        // the driver's positions by `nativePinJustifiedWords`: the run's own fixed-pitch
        // kerns go with the Courier they were set for.
        if let nativeFace {
            let whole = NSRange(location: 0, length: line.length)
            line.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let current = value as? NSFont else { return }
                let (bold0, italic) = nativeFontTraits(current)
                let bold = nativeFace.bold || bold0
                if let faced = nativeFaceMacFont(nativeFace, bold: bold, italic: italic) {
                    line.addAttribute(.font, value: faced, range: range)
                    line.addAttribute(.kern, value: 0.0, range: range)
                }
            }
        }
        return line
    }

    /// A zero-drawing spacer the exact width of a suppressed 0x0F print control's declared
    /// HMI block — an `NSTextAttachment` with an empty image, so it occupies horizontal
    /// space in the line without painting anything, the same way a real control payload
    /// occupies the platen without leaving a mark a reader can see. `widthPt` mirrors the
    /// engine's own conversion (`PDFWriter.swift:473`, `x += Double(hmi) / hmiPerPoint`;
    /// `hmiPerPoint = 1800.0 / 72.0`, `PDFFonts.swift:66` — 1800 HMI units per inch, 72pt
    /// per inch).
    /// - Parameter pcl: Register C2 (`span.pcl`) — the index into `Document.pclPrograms` of
    ///   this control's raw printer payload, or `nil`. Stashed as `.nativePCLProgram` so
    ///   `PageTextView.drawPCLGraphics` (`NativePCLGraphics.swift`) can find this attachment's
    ///   own glyph position later and execute the program there — see that file's top doc
    ///   comment for why this is a real feature (LJ6DTP's page border/checkerboard), not
    ///   decoration.
    static func pctlAdvanceAttachment(hmi: Int, pcl: Int? = nil, paragraph: NSParagraphStyle) -> NSAttributedString {
        let hmiPerPoint = 1800.0 / 72.0
        let widthPt = max(0, CGFloat(hmi) / hmiPerPoint)
        let attachment = NSTextAttachment()
        attachment.image = NSImage()
        attachment.bounds = CGRect(x: 0, y: 0, width: widthPt, height: 0)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if let pcl {
            result.addAttribute(.nativePCLProgram, value: pcl, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// Job 503 item 1: one real WordStar tab stop (`Span.tabHMI`/`.tabLeader`) — port of
    /// `PDFWriter.swift`'s `lineOpsPrinted` tab branch. `line`'s own accumulated NATURAL
    /// width (`line.size().width`) already IS the engine's pen position `x` measured from
    /// `left`: this function's caller (`attributedLine`) builds one `PageLine` per call into
    /// an initially-empty string, and that container's own paragraph style carries no head
    /// indent (`naturalParagraphStyle`/`paragraphStyle(lead:)`), so x=0 here already equals
    /// the engine's own `left`. `tabHMI`'s target is likewise declared relative to `left`
    /// alone (never `left + fi` — `PDFWriter.swift`'s own `let targetX = left + Double(tabHMI)
    /// / hmiPerPoint`), so no separate first-line-indent bookkeeping is needed here either.
    static func appendTabRun(
        _ span: Span, tabHMI: Int, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double],
        useCourierPrime: Bool, to line: NSMutableAttributedString
    ) {
        let hmiPerPoint = 1800.0 / 72.0
        let targetX = CGFloat(tabHMI) / CGFloat(hmiPerPoint)
        let currentX = line.size().width
        if targetX <= currentX {
            // The stop is at or behind the pen already: the tab takes no width at all, as the
            // engine collapses it (`PDFWriter.swift`'s tab branch, measured on a WS7 capture).
            // This used to add one document column, which put the rest of the line 7 pt right
            // (-LASERJE.FNT's "Scalable") and left the line one space where the engine's pieces
            // have the run, so it could not be pinned. The run's own characters stay, with no
            // advance.
            guard !span.text.isEmpty else { return }
            let resolvedTabFont = Self.resolvedFont(
                for: span, fallback: font, fonts: fonts, defaultSize: defaultSize, useCourierPrime: useCourierPrime)
            let natural = NSAttributedString(string: span.text, attributes: [.font: resolvedTabFont]).size().width
            line.append(NSAttributedString(string: span.text, attributes: [
                .font: resolvedTabFont,
                .paragraphStyle: paragraph,
                .kern: -natural / CGFloat(span.text.count),
            ]))
            return
        }
        if !span.text.isEmpty {
            // Render the span's OWN literal text (almost always the author's typed
            // spaces or dot-leader periods) rather than a content-free `NSTextAttachment`
            // spacer or a freshly-counted run of leader glyphs — this span's real
            // characters are content other readers of this rendered string depend on:
            // `NativeStructuralParityTests.structuralParity`'s own text-content class
            // reads the live `NSAttributedString` back against `EngineTruth`'s own text,
            // itself built from `docToPagelines`'s PRE-tab-expansion `PageLine.text` (the
            // author's ORIGINAL typed run, not `PDFWriter.swift`'s own recomputed
            // leader-glyph COUNT for the gap), and `PixelOracleAppEngineTests
            // .knockoutRunsClassifyTheSameWayTheEngineDoes` reads colour AT A CHARACTER
            // INDEX. Both regressed the moment this span's real characters were replaced
            // (confirmed: an attachment spacer cost -README.WS a literal space between
            // "■" and the word after it and shifted a knockout run's colour off by the
            // width of the swallowed characters; a freshly-counted dot-leader run cost
            // LJ6DTP.WS's own "Shading 85%..." row its real, shorter typed dot count).
            // A per-character `.kern` computed to land the total advance on `targetX`
            // keeps the real characters (and `colourMap`'s own word-colour attribute,
            // exactly as an ordinary span gets) while still landing the pen where the
            // engine's own real tab stop does — visually a stretched/compressed run of
            // the SAME glyphs instead of the engine's exact repeat-count, close enough
            // for a Mac-viewing facsimile of a fill run never meant to be read character
            // by character (dots, spaces) and never claimed byte-exact in the first place.
            let resolvedTabFont = Self.resolvedFont(
                for: span, fallback: font, fonts: fonts, defaultSize: defaultSize, useCourierPrime: useCourierPrime)
            var runAttributes: [NSAttributedString.Key: Any] = [
                .font: resolvedTabFont,
                .paragraphStyle: paragraph,
            ]
            runAttributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
            let natural = NSAttributedString(string: span.text, attributes: [.font: resolvedTabFont]).size().width
            let gap = targetX - currentX
            runAttributes[.kern] = (gap - natural) / CGFloat(span.text.count)
            line.append(NSAttributedString(string: span.text, attributes: runAttributes))
            return
        }
        // An empty-text tab (rare — a type-9 block with no filler characters typed at
        // all) has no real content to preserve; land on `targetX` with a zero-drawing
        // spacer instead (`pctlAdvanceAttachment`'s own technique).
        let remainder = targetX - currentX
        if remainder > 0 {
            let attachment = NSTextAttachment()
            attachment.image = NSImage()
            attachment.bounds = CGRect(x: 0, y: 0, width: remainder, height: 0)
            let spacer = NSMutableAttributedString(attachment: attachment)
            spacer.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: spacer.length))
            line.append(spacer)
        }
    }

    /// Job 371 item 1 (PIX IN VIEWS): a resolved `.PIX` tag's decoded image, drawn in-memory
    /// via `NSTextAttachment` (no PNG files, no export machinery on screen — the ruled
    /// design) at `widthPt`x`heightPt` — already the engine's own size for a Printed
    /// `PageLine.image`, or `pixDimsPt`'s own port of that same sizing for Modern's inline
    /// case. `index` out of range or unresolved never reaches here — `appendSpan`/
    /// `lineAndTerminator` both gate on `.ok` first — but the empty-image fallback keeps
    /// this total rather than force-unwrapping, matching every other "never raise, degrade"
    /// pix rule in this codebase.
    /// - Parameter reservedLeadPt: this line's own reserved-band height (job 438) — stashed
    ///   in `attachment.bounds.origin.y`, a field job 428 already confirmed `NSLayoutManager`
    ///   never consults for an attachment-only unbounded line's own placement (so this is a
    ///   pure side channel, never a layout input). `PagedDocumentView.drawOversizedSelfPasses`
    ///   reads it back to anchor an oversized image self-pass's TOP at the reserved band's own
    ///   top rather than at its tiny AppKit fragment's top — see that call site's own doc
    ///   comment. `0` for every OTHER caller (the ordinary inline/non-oversized picture case),
    ///   which never reaches that code path and so never looks at this value.
    /// MECHANISM Y's own term, named once so both Printed call sites and the test that pins
    /// them read the same number: the preceding line's DESCENT, which an embedded picture's
    /// top edge must clear. `0.25 * size`, the same baseline-to-cell-bottom fraction the
    /// engine's box-drawing cells already use, taken against the document's own default
    /// printed size exactly as `pageStream` does (a pix tag reserves blank PHYSICAL lines at
    /// that size, never a per-line override).
    public static func nativePixDescentPt(_ size: Int) -> Double { 0.25 * Double(size) }

    static func pixAttachmentString(
        _ pixResults: [PixResult], index: Int, widthPt: Double, heightPt: Double,
        paragraph: NSParagraphStyle, reservedLeadPt: Double = 0,
        descentClearancePt: Double = 0
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if pixResults.indices.contains(index), let png = pixResults[index].png,
           let image = NSImage(data: Data(png)) {
            attachment.image = image
        } else {
            attachment.image = NSImage()
        }
        // MECHANISM Y (engine commit c9fea86, mirroring ctrl-kd 9546ae6). `PDFWriter.swift`'s
        // `pageStream` image branch is now
        //
        //     let imgY = y + (reserved - img.heightPt) - 0.25 * Double(size)
        //
        // where `y` is the preceding line's own baseline. `reservedLeadPt` here is that same
        // `(reserved - img.heightPt)` band-slack term, and an `NSTextAttachment`'s
        // `bounds.origin.y` is its BOTTOM edge relative to the baseline — the same quantity
        // and the same sign convention as `imgY` — so the engine's new term subtracts here
        // exactly as it does there.
        //
        // Why it exists: WS7 does not start the raster flush with that baseline. Measured
        // against three independent PRISTINE.EXE captures (PREVIEW, -SCREEN, -README, all
        // embedding the same INSET/PIX/WORDSTAR.PIX), the picture's real top edge sits a
        // further `0.25 * size` — the preceding line's own DESCENT — below it, because the
        // picture cannot start until that line's full cell has cleared.
        //
        // Verified end to end rather than reasoned about: before this engine commit, the
        // Printed PDF placed PREVIEW.WS's picture at `... 57.60 286.10 cm /Im0 Do`; after it,
        // at `57.60 283.10` — three points lower, every other number identical, at this
        // document's 12pt size. That prediction was written down BEFORE the engine change
        // landed and then checked against it, which is what makes the sign here trustworthy:
        // a raised-versus-lowered mistake in an attachment's `bounds.origin.y` is easy to
        // make and looks plausible either way on screen.
        //
        // Printed only. Modern's inline `span.pix` call site passes no clearance, matching
        // the engine, whose own Modern layout has no equivalent term.
        attachment.bounds = CGRect(x: 0, y: reservedLeadPt - descentClearancePt,
                                   width: max(0, widthPt), height: max(0, heightPt))
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Fit-to-measure fallback for Modern's INLINE `span.pix` case — a port of the engine's
    /// own `imageDimsPt` (`PrintedBody.swift`'s `resolvePrintedBody`), which is Printed-only
    /// there (its own doc comment: "the caller never invokes this function for Modern").
    /// Same rule either way: the print-options record's own physical size when the `.PIX`
    /// file carried one, else fill the column measure at the image's own pixel aspect
    /// ratio; either way, capped to the measure so an oversized image never overflows the
    /// column it sits in.
    static func pixDimsPt(_ result: PixResult, measureWidthPt: Double) -> (w: Double, h: Double) {
        var wPt: Double
        var hPt: Double
        if let widthIn = result.widthIn, let heightIn = result.heightIn, widthIn != 0, heightIn != 0 {
            wPt = widthIn * 72.0
            hPt = heightIn * 72.0
        } else {
            wPt = measureWidthPt
            hPt = result.gcols.map { $0 != 0 ? wPt * (Double(result.grows ?? 0) / Double($0)) : 0.0 } ?? 0.0
        }
        if wPt > measureWidthPt, wPt > 0 {
            let scale = measureWidthPt / wPt
            wPt *= scale
            hPt *= scale
        }
        return (wPt, hPt)
    }

    /// Recover a `Document.graphics`/`pixResults` index from placeholder TEXT alone — see
    /// `appendSpan`'s own call-site comment for why Modern needs this. `text` must be
    /// EXACTLY one placeholder and nothing else (`"[image: NAME]"`, trimmed) — a span with
    /// extra real text around a placeholder never matches, same "never substitute when
    /// there is other real content" discipline the engine's own Printed-mode substitution
    /// keeps (`PrintedBody.swift`'s `resolvePrintedBody`: "If a hypothetical pix tag ever
    /// shares a line with OTHER real text, this deliberately does NOT substitute"). Matches
    /// the FIRST resolved (`.ok`) result whose own raw path's basename equals `NAME` — exact
    /// address recovery when basenames are unique (the confirmed real-corpus shape: one
    /// picture per document), a reasonable same-image degradation on the rarer case two
    /// tags share a bare filename.
    /// The resolved picture a Modern paragraph's spans refer to, if any — the same lookup
    /// `appendSpan` makes per span, asked of a whole line so its own paragraph style can
    /// reserve the picture's height before the line is built.
    static func modernPixIndex(of spans: [Span], pixResults: [PixResult]) -> Int? {
        for span in spans {
            let index = span.pix
                ?? inferredPixIndex(fromPlaceholderText: span.text, pixResults: pixResults)
            if let index, pixResults.indices.contains(index), pixResults[index].ok { return index }
        }
        return nil
    }

    static func inferredPixIndex(fromPlaceholderText text: String, pixResults: [PixResult]) -> Int? {
        // WITHOUT THE ZERO-WIDTH JOINERS. `modernNoBreakGraphicRuns` splices U+2060 between
        // every adjacent character of a token so AppKit cannot break inside one, and a
        // placeholder is a token like any other — "[image:" comes back with a joiner between
        // every letter, and a prefix test against "[image: " then fails. The joiner has no
        // glyph and no width and is not part of any name; removing it here is reading the
        // text the author actually wrote.
        let bare = text.replacingOccurrences(of: "\u{2060}", with: "")
        let trimmed = bare.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[image: "), trimmed.hasSuffix("]") else { return nil }
        let name = String(trimmed.dropFirst("[image: ".count).dropLast())
        return pixResults.first { $0.ok && pixBasename($0.rawPath) == name }?.index
    }

    /// One span, fully styled — the per-span body `attributedLine`'s own loop used to
    /// inline before the leading-indent port needed to call it from two places (the
    /// split-off "rest" of an indented run, and every ordinary span).
    static func attributedRun(
        _ span: Span, font: NSFont, paragraph: NSParagraphStyle,
        fonts: [FontChange], defaultSize: Int, colourMap: [Int: Double] = [:],
        disableKerning: Bool = false, useCourierPrime: Bool = false,
        nativeSupSub: Bool = false, nativeFullScripts: Bool = false, nativeRoll: Double? = nil, nativeKerning: Bool = true,
        modernPitchScale: Bool = false, modernPrintedPt: Int? = nil,
        modernFontlessFamily: CtrlKD.PDFFamily = .times
    ) -> NSAttributedString {
        // Job 226: same lookup `resolvedFont` already needs — shared here so the LJ6DTP
        // character substitution below gates on the SAME font entry, not a second lookup.
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        // Job 240 (b13, Part 1): the driver's own character substitution stays — LJ6DTP's
        // ☻->©/☼->…/etc. reflect the DRIVER's documented semantics (job 226 M7 ruling:
        // "an em dash is an em dash in any century"), document meaning rather than an
        // encoding-floor workaround, and Part 1 explicitly keeps it. The universal cp1252
        // esc-degradation that used to chain after it is gone — see `nativeEscDegrade`'s
        // removal doc comment above (MAC VIEWING RULING).
        var text = span.text
        if !colourMap.isEmpty {
            text = nativeLJ6DTPSubstitute(text, entry: entry, kerning: nativeKerning)
        }
        var spanFont = resolvedFont(for: span, fallback: font, fonts: fonts, defaultSize: defaultSize,
                                    useCourierPrime: useCourierPrime)
        // THE MEASUREMENT PIN (gate only) — `modernBase14MeasurementPin`'s own doc comment.
        // Modern only, so Printed and Native are untouched by construction; `modernPitchScale`
        // is true on exactly the three Modern call sites and nowhere else.
        // `entry` REQUIRED, never nil: `pdfFamily(nil)` answers `.courier`, which is Printed's
        // default and the opposite of Modern's own rule ("a token with NO font information
        // reads in Times at the sophisticated size, never Courier" — `modernTokFont`). A
        // fontless run keeps the reader's face, which this gate already pins through
        // `modernFontName`. Measured when this guard was missing: -README.WS's fontless body
        // went to Courier New and its distance went 204 to 1179.
        if modernPitchScale, Self.modernBase14MeasurementPin, let entry,
           let pinned = modernBase14MacFont(entry, size: spanFont.pointSize,
                                            bold: span.styles.contains(.bold),
                                            italic: span.styles.contains(.italic)) {
            spanFont = pinned
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: spanFont,
            .paragraphStyle: paragraph,
        ]
        // Ink on paper, so black by default — `textColor` inverts with the system
        // appearance and would go white on the white sheet drawn by
        // `PagedDocumentView`. A driver-colour run (LJ6DTP, job 210) overrides this to
        // its palette gray, or (job-489, C1) a real tiled HP pattern — see
        // `driverColourAttributes`'s own doc comment.
        attributes.merge(driverColourAttributes(span.colour, colourMap)) { _, new in new }
        // The face the cell arithmetic is asked about: the run's own DECLARED font, before
        // any sup/sub reduction below, since `spanPitch` is a property of the span's own
        // declared size.
        let spanFontForCells = attributes[.font] as? NSFont ?? font
        var supSubPitched = false
        // NEITHER SIDE KERNS, AND NEITHER LIGATES.
        //
        // The library measures a line by SUMMING AFM WIDTHS — one number per character, no
        // pair table and no ligature substitution anywhere in it — and this set `.kern` only
        // on the Printed path, so Modern let AppKit apply Times New Roman's own kern pairs.
        // That is where Modern's line breaks came from: measured directly, -README.WS's "The
        // full set of WordStar manuals as Adobe PDF Portable Document Format files is" is
        // 466.38pt kerned and 468.53 unkerned against a 468.00 column, so the library wraps
        // that last word and the app kept it. Every early -README and SCRIPT page was one
        // word at a line end, and it is this.
        //
        // NOT the faces disagreeing, which is what it looked like: macOS's own Times New
        // Roman matches the engine's AFM Times-Roman table to 0.24/1000 em at worst and
        // 0.08 on average across the printable ASCII range, measured glyph by glyph. The two
        // fonts agree; the two MEASUREMENTS did not.
        //
        // `nativeNoKerning` is 0 and `nativeNoLigatures` is 0 — the same values Modern
        // needs, so the Printed constants are reused rather than a second pair invented. A
        // later per-run corrective kern (the coverage split's own pitch match, mechanism G's
        // cell arithmetic) still overrides this, as it always did.
        attributes[.kern] = nativeNoKerning
        attributes[.ligature] = nativeNoLigatures
        if span.styles.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if span.styles.contains(.strike) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // `.superscript` (NSAttributedString's Cocoa-Text-System key) raises the glyph
        // WITHOUT shrinking it, which grows the run's ascent past the base font's own —
        // harmless in Printed (its paragraph style pins min==max line height to the
        // library's lead), but Modern sets neither, by design (it is a reading view,
        // not a facsimile). There, a `.fnref` mark — always `.sup`, `ParseWS.swift` —
        // made ITS line's fragment taller than its plain neighbours: the extra leading
        // in Jon's screenshot. `sized()` in the library's own `PDFWriter.swift` never
        // hits this because it sets sup/sub SMALLER (2/3), not just higher. Doing the
        // same here — scaled font plus a baseline offset measured against THAT font's
        // own ascender/descender — keeps a marked run inside the unmarked glyphs'
        // envelope, so the line fragment never grows on its account, in either style.
        //
        // Job 246 (p6-knockout): the baseline OFFSET half of this is TEXT-ONLY in the
        // library too — `lineOpsPrinted` (`PDFWriter.swift:476,501-505`) computes
        // `sized()`'s `(pt, rise)` for every span, but a graphic/cp437-block span takes
        // the `graphicOps` branch BEFORE `rise` is ever consumed, so a superscripted
        // block-character run (LJ6DTP's "PRETTY NEAT, HUH?" knockout: two `.overprint`-
        // chained rows of block(219) glyphs, the second one `.sup`-flagged per WordStar's
        // "superscript the second line" instruction) shrinks to 2/3 size in place, on the
        // SAME shared baseline as the row before it — never rises. Applying `.baselineOffset`
        // here regardless raised that row's vector-fill cell (`graphicCells` reads the
        // glyph's real AppKit position, offset included) off the shared baseline the
        // `.overprint` chain and the knockout text both still sit on, which is what made
        // the composited result overlap/garble. Gated the same way the library gates it:
        // `graphicChars` alone — matching `lineOpsPrinted`'s own `seg.text.contains(where:
        // graphicChars.contains)` check exactly (job 404: the ONLY gate `lineOpsPrinted`
        // ever applies to the graphics decision, font block or none — see `graphicCells`'
        // own doc comment, `NativeVectorGraphics.swift`).
        if span.styles.contains(.sup) || span.styles.contains(.sub) {
            let base = attributes[.font] as? NSFont ?? font
            let isGraphic = text.contains(where: { graphicChars.contains($0) })
            // Native sets the run at the size Printed does: the engine's per-face reduction
            // (`printedSupSubMetrics`: WS7's own X38 byte for the span's typestyle, floored to
            // the LaserJet's 1/4pt step — WS7 teardown 9.6), so 9.25pt Courier, 8.25pt
            // Helvetica, at a 12pt body. Modern keeps the flat Cocoa 2/3 (`nil`).
            let isCourier = nativeSupSub && nativeFamilyIsCourier(entry)
            // WS4's HPLJET keeps a script in the line's own font and cell, only moved by the
            // roll (`nativeFullScripts`; the engine's `lineOpsPrinted(fullScripts:)`), and so
            // does one of LJ6DTP's bitmap Couriers (the engine's `bitmap`).
            let fullScripts = nativeFullScripts || (!colourMap.isEmpty && lj6dtpBitmapFont(entry))
            let printedScript = nativeSupSub && !fullScripts
                ? printedSupSubMetrics(span.styles, size: Int(base.pointSize.rounded()), entry: entry)
                : nil
            let (scaled, offset) = scriptMetrics(
                for: base, raise: span.styles.contains(.sup),
                points: fullScripts ? Double(base.pointSize) : printedScript?.points)
            attributes[.font] = scaled
            if !isGraphic { attributes[.baselineOffset] = offset }
            // #271 M1: Printed moves the run by the `.sr` roll in force, exactly — `sizedPrinted()`'s
            // rise is the roll itself, +4.5 / −4.5 at the default 3/48in (WS7 report 14.8, run
            // fnmb0). Laying it out that far would grow its line fragment past the envelope fit
            // above and change pagination (batch 20: 13 GeometryOracle lines moved), so layout
            // keeps the fit and the difference is applied when the glyphs are drawn
            // (`ScriptRiseLayoutManager`). Native only; Modern keeps the fit.
            if nativeSupSub, let nativeRoll {
                let printedRise = CGFloat(span.styles.contains(.sup) ? nativeRoll : -nativeRoll)
                if isGraphic {
                    // A block rolls with the carriage as a letter does (the engine raises its
                    // cells); laid out on the shared baseline, drawn raised, and its vector
                    // cells follow (`graphicCells`).
                    attributes[.nativeScriptRise] = printedRise
                } else if printedRise != offset {
                    attributes[.nativeScriptRise] = printedRise - offset
                }
            }
            // MECHANISM G, the PITCH half. WS7 reselects a NARROWER fixed-pitch cell for the
            // span itself — the engine's `printedSupSubMetrics` cell: for Courier the driver's
            // own width, 23 dots = 5.52pt at a 9.25pt run; another fixed-pitch face's body
            // cell scaled by the size ratio — where AppKit would simply advance at the smaller
            // face's own natural 0.6em. The gap is small per character and CUMULATIVE, so
            // every glyph after the span lands progressively wrong without it. Closed with
            // `.kern`, the same attribute the rest of this renderer uses to put a run on
            // WordStar's grid rather than the font's.
            //
            // The size handed to the engine is the span's own UNREDUCED declared size —
            // `base.pointSize`, before the reduction — exactly what the engine passes
            // (`seg.size`). A proportional span has no cell (nil) and never reaches this
            // branch's kern anyway — it goes through `appendProportionalRun` — and the Mac
            // face must be fixed pitch too, since the kern assumes its 0.6em advance.
            if isCourier, let target = printedScript?.cell {
                attributes[.kern] = Float(target - Double(scaled.pointSize) * 0.6)
                supSubPitched = true
            }
        }
        // Job 399 (Class 6 gate-debt): a footnote reference used to get an app-invented
        // `NSColor.darkGray` tint here ("reads as a reference without inventing a glyph") —
        // but the engine's own `lineOpsPrinted`/`runningOps` never colour an `.fnref` span at
        // all (grep confirms: no `CtrlKD` emitter branches on `.fnref` for colour, only for
        // marker-text substitution — `PDFLayout.swift:709`, `Writer.swift:336`). That made the
        // tint a pure app decoration that broke Printed-mode byte parity with no engine
        // counterpart (`NativeStructuralParityTests`' Class 6 caught it on `DARKNESS.WS`: a
        // real `NSColor.foregroundColor` divergence unrelated to the LJ6DTP knockout residual
        // this class actually tracks). The reference is already visually distinct via its own
        // `.sup` styling (WordStar's own mark, not this renderer's addition) — removed rather
        // than gated, since no engine surface ever wanted it.
        // (Since planning #586 a line WS7's driver places is pinned to the engine's
        // `driverPieces` after this, in `nativePinJustifiedWords`: each word at the driver's
        // x, at its Mac face's natural width unless that is more than 3% off its paper width.
        // The history below is why no per-word kern is set HERE.)
        // Job 240 (b13, Part 2): job 229's word-anchored proportional placement (per-word
        // corrective `.kern` to an AFM×Tz target) is REMOVED — MAC VIEWING RULING. Words in
        // a proportional WS5+ run now lay out at the resolved Mac font's own NATURAL
        // advance, same as every other span; line breaks and page breaks stay
        // engine-authoritative (`docToPagelines`, untouched) — that IS structure. This also
        // resolves job 232's "class a" (LJ6DTP.WS p4: a bold word's corrective kern landing
        // entirely as trailing kern silently ate the following inter-word space) by removing
        // the corrective-kern mechanism that caused it, not by patching it.
        //
        // Job 447 (b27 item 7 part 2 — job 445's `nativeCoverageAwareResolvedMacFont` wired
        // in): everything above this line is UNCHANGED — `attributes[.font]` is still exactly
        // the font the rest of this function already decided (LJ6DTP substitution, sup/sub
        // scaling, traits, all done). The only new step is the one below: when `text` contains
        // NO `graphicChars`, return exactly as before (zero behaviour change for prose, which
        // is the entire corpus outside vector-graphics fixtures). When it does, hand off to
        // `coverageSplitAttributedString`, which is where the fix actually lives.
        // Planning #222 / Athena's ruling 2026-09-09: in Printed/Native every glyph of a
        // fixed-pitch run occupies exactly one engine cell, whatever face draws it. Applied
        // as a post-pass so the coverage split's own font decisions are already made.
        // `supSubPitched` is mechanism G's own cell arithmetic and owns those runs' advances.
        // MODERN HONOURS THE FILE'S DECLARED CHARACTER WIDTH, by stretching the type.
        //
        // The library's `modernTokenWidth` is three rules, not one:
        //
        //     if let entry, !entry.proportional { return count * spanPitch(entry, spt) }
        //     let natural = stringWidthPt(text, basefont, spt)
        //     if let entry { return natural * faceTz(basefont, spanPitch(entry, spt), spt) / 100 }
        //     return natural
        //
        // The app had only the third: every Modern run laid out at the Mac face's own
        // natural advance, whatever the file's font block declared. Measured on LJ6DTP.WS,
        // whose blocks declare a 137/1800in cell: the library stretches its 12pt Times by
        // 101.12% (`faceTz`, a PDF `Tz`), so its Modern measure of one prose line is ~1.1%
        // wider than the app's and it wraps a word earlier. Page 3's paragraphs each kept
        // one extra word here, and the line that fell off the bottom became a page break in
        // the wrong place. `MAC VIEWING RULING` (job 240, above) is untouched: it removed
        // PER-WORD corrective kerning from the PRINTED facsimile, where the engine's own x
        // is authoritative and the app merely draws to it. Modern has no engine x — the app
        // does its own wrapping — so the same run has to carry the same measure.
        //
        // `.expansion` is AppKit's `Tz`: the value is the LOG of the factor (measured
        // directly — 0.1 yields a 1.10508 ratio, and exp(0.1) = 1.10517).
        //
        // The reference average comes from the run's OWN resolved Mac font rather than the
        // library's base-14 name, for the reason the batch already measured: macOS's Times
        // New Roman matches the AFM Times-Roman table to 0.24/1000 em, so the two agree
        // wherever the faces are metric-matched — and where they are NOT, the declared cell
        // is still what the document asked for, which is the point of the stretch.
        // The library's own answer for this run's face, carried on the run — see
        // `NSAttributedString.Key.modernBase14`. Set here, where `attributes[.font]` is
        // final and `entry` is in hand; a run with no font block of its own reads in the
        // same default family `pdfFamily(nil)` gives the engine.
        if modernPitchScale {
            let bold = span.styles.contains(.bold)
            let italic = span.styles.contains(.italic)
            attributes[.modernBase14] = entry == nil
                ? base14Name(modernFontlessFamily, bold: bold, italic: italic)
                : modernBase14Name(entry, bold: bold, italic: italic)
        }
        if modernPitchScale, let entry {
            let cellFont = attributes[.font] as? NSFont ?? spanFontForCells
            let pitch = nativeSpanPitch(entry, Int(cellFont.pointSize.rounded()))
            if entry.proportional {
                // THE AVERAGE COMES FROM THE AFM TABLE, not from the Mac face. `faceTz`
                // rounds to HUNDREDTHS, so a difference far below any visible threshold
                // still decides which hundredth the stretch lands on — and the stretch then
                // multiplies a whole line. Measured on LJ6DTP.WS: its 137/1800in cell over
                // macOS Times New Roman's own mean advance (5.418619) gives 101.13, and over
                // the engine's AFM Times-Roman mean (5.419111) gives 101.12. One hundredth
                // of a percent is 0.046pt across that document's 460.80pt measure, and its
                // page 9 prose sits 0.02pt inside it: the library fits "set:" on the line
                // and the app did not, three lines of every such paragraph.
                //
                // `stringWidthPt` is the library's own AFM lookup (`AFM.swift`, public), so
                // the two sides now compute the same number from the same table.
                let average = stringWidthPt(Self.modernTzReference,
                                            modernBase14Name(entry,
                                                             bold: span.styles.contains(.bold),
                                                             italic: span.styles.contains(.italic)),
                                            Int(cellFont.pointSize.rounded()))
                    / Double(Self.modernTzReference.count)
                if average > 0, pitch > 0 {
                    // `faceTz`'s own rounding and clamp, so a metric-matched face lands on
                    // the same hundredth the library picked rather than a neighbouring one.
                    let raw = pitch / average * 100
                    let percent = min(250, max(40, (raw * 100).rounded(.toNearestOrEven) / 100))
                    if abs(percent - 100) > 0.001 {
                        attributes[.expansion] = log(percent / 100)
                    }
                }
            }
        }
        // A fixed-pitch Modern run spends one declared cell per character — the library's
        // FIRST rule above, and exactly what `nativePinToCells` already states for Printed.
        let modernFixedPitch = modernPitchScale && entry?.proportional == false
        // LJ6DTP's ©, in Native and Printed's facsimile only.
        let ljEntry = colourMap.isEmpty || modernPitchScale ? nil : entry
        guard text.contains(where: { graphicChars.contains($0) }) else {
            let plain = nativeLJ6DTPCopyright(NSAttributedString(string: text, attributes: attributes),
                                              entry: ljEntry)
            guard disableKerning || modernFixedPitch, !supSubPitched else { return plain }
            return nativePinToCells(plain, font: spanFontForCells, entry: entry)
        }
        // The graphic half of the library's own three-rule measure (`modernPinGraphicCells`).
        // Applied to the coverage split below, after its font decisions are made, and only in
        // Modern — Printed positions every span at the engine's own x and has its own
        // machinery for this (`nativePinGraphicCells`, from the model's placements).
        func modernCells(_ string: NSAttributedString) -> NSAttributedString {
            guard modernPitchScale, let printedPt = modernPrintedPt else { return string }
            return modernPinGraphicCells(string, entry: entry, pt: printedPt)
        }
        let split = nativeLJ6DTPCopyright(coverageSplitAttributedString(
            text, attributes: attributes, entry: entry, bold: span.styles.contains(.bold),
            italic: span.styles.contains(.italic), useCourierPrime: useCourierPrime,
            modernPitchScale: modernPitchScale), entry: ljEntry)
        guard disableKerning || modernFixedPitch, !supSubPitched else { return modernCells(split) }
        // The same cell pin as the plain path. In Printed this SUPERSEDES the split's own
        // per-run pitch kerns (job 512's space pinning, the graphic-pitch match): those
        // approximate a uniform column by matching a neighbour's advance, and this states
        // the engine's own column outright. Modern keeps them — it never sets
        // `disableKerning` — so that fix stays exactly as it was where it was found.
        return modernCells(nativePinToCells(split, font: spanFontForCells, entry: entry))
    }

    /// Job 447: splits `text` at every boundary between a `graphicChars` run and an ordinary
    /// one, so a span mixing box-drawing/symbol glyphs with real prose (job 442's own
    /// BOXES.WS/LJ6DTP.WS measurement: one span can carry both) resolves EACH kind
    /// separately. RUN-BOUNDARY RULE: a run is a maximal contiguous substring of `text` where
    /// every character's `graphicChars` membership agrees — i.e. exactly the same grouping
    /// `graphicCells` itself already walks character-by-character
    /// (`NativeVectorGraphics.swift`'s own `guard graphicChars.contains(ch) else { continue
    /// }` loop). A non-graphic run keeps `attributes` UNTOUCHED — the coverage-aware lookup
    /// never runs on prose, so a mixed span's own text portion can never end up on a
    /// different font than it already had (job 442's "Recommended fix" section explicitly
    /// rules out any whole-span substitution, since a general Courier-Prime-vs-Courier-New
    /// swap would visibly change how real prose looks). Only a graphic run's own `.font` is
    /// replaced, with `coverageAwareGraphicFont` below, checked against that run's OWN text —
    /// not the whole span's — so a font that covers this run's particular glyphs but not some
    /// other run's is still accepted.
    static func coverageSplitAttributedString(
        _ text: String, attributes: [NSAttributedString.Key: Any], entry: FontChange?,
        bold: Bool, italic: Bool, useCourierPrime: Bool, modernPitchScale: Bool = false
    ) -> NSAttributedString {
        guard let baseFont = attributes[.font] as? NSFont else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let size = baseFont.pointSize
        // Job 447 (found while proving this job's own full-corpus regression, CONVERT.WS/
        // STRENGTH.WS): a graphic run whose OWN font already covers it (the common case — a
        // single "│" side character in a proportional face that happens to carry cp437
        // box-drawing) needs no font override at all, but SPLITTING it into its own
        // `NSAttributedString` piece regardless still measurably moved neighbouring glyphs by
        // ~0.004pt in both fixtures — a real, if tiny, cross-run kerning artifact from the
        // run boundary itself, not from any font change. `runs` below collects (text,
        // isGraphic, font) for every run FIRST, without touching `result`; only when at least
        // one graphic run's own resolved font actually differs from `baseFont` does this
        // function build the split string — otherwise it returns EXACTLY the single, unsplit
        // string the pre-job-447 code already built, with no run boundary introduced at all.
        var runs: [(text: String, font: NSFont, isGraphic: Bool)] = []
        var runStart = text.startIndex
        var runIsGraphic = graphicChars.contains(text[runStart])
        var anyFontChanged = false
        func flush(upTo end: String.Index) {
            guard runStart < end else { return }
            let runText = String(text[runStart..<end])
            var runFont = baseFont
            if runIsGraphic {
                runFont = coverageAwareGraphicFont(
                    baseFont: baseFont, entry: entry, size: size, bold: bold, italic: italic,
                    useCourierPrime: useCourierPrime, coveringCharactersIn: runText)
                if runFont.fontName != baseFont.fontName { anyFontChanged = true }
            }
            runs.append((runText, runFont, runIsGraphic))
        }
        var index = text.startIndex
        while index < text.endIndex {
            let isGraphic = graphicChars.contains(text[index])
            if isGraphic != runIsGraphic {
                flush(upTo: index)
                runStart = index
                runIsGraphic = isGraphic
            }
            index = text.index(after: index)
        }
        flush(upTo: text.endIndex)
        // Job 512 (b32, Jon's field report — BOX.WS's Modern view: right side open, a
        // phantom vertical mid-box): a "filler" run — plain spaces (optionally interleaved
        // with `modernNoBreakGraphicRuns`'s own zero-width U+2060 joiners) sitting between
        // two graphic runs, e.g. a box row's `│    │` interior — renders at `baseFont`'s own
        // proportional SPACE advance, while the graphic runs flanking it render at that same
        // font's box-drawing-GLYPH advance. Neither font substitution (`anyFontChanged`,
        // above) nor `attributedRun`'s WS5+-only `appendProportionalRun` grid-restamp
        // (gated on `entry.proportional`, never true for a fontless WS4 document like
        // `BOX.WS`) touches this: the two advances are simply different numbers in the SAME
        // font (Georgia-14 measured: box glyph ≈9.9pt, space ≈3.4pt), so a row's interior
        // right border compounds that gap over every blank column and lands far short of
        // where the border rows' own box glyphs put the real right edge. Pins each SPACE in
        // such a run to the pitch of its own neighbouring graphic run's first character
        // (measured in THAT run's resolved font, the one actually painted beside it) via
        // `.kern`, so every column of a box/legend row — border, side, or blank — advances
        // by the same amount regardless of which characters happen to be spaces. A run of
        // exactly one bare space (never produced by `modernNoBreakGraphicRuns`, which only
        // ever joins WITHIN a run of 2+ — see its own doc comment) is not this case at all;
        // requiring 2+ real spaces keeps a single incidental gap (a legend line's "LL: └")
        // untouched, same MAC VIEWING RULING carve-out `appendProportionalRun` already
        // documents for ordinary prose.
        func graphicPitch(for font: NSFont, in runText: String) -> CGFloat? {
            guard let first = runText.first else { return nil }
            return (String(first) as NSString).size(withAttributes: [.font: font]).width
        }
        var needsFillerKern = false
        var pitches: [CGFloat?] = Array(repeating: nil, count: runs.count)
        // Scoped to a genuinely proportional BASE font — Printed's own callers always pass a
        // fixed-pitch Courier `font` (`renderNative`'s `attributedLine` call sites), under
        // which this correction would compute a near-zero kern anyway (Courier's own space
        // already matches its other glyphs' advance, by definition), but Printed's box
        // rendering is additionally the ACTUAL visible ink for these glyphs
        // (`PagedDocumentView.drawVectorGraphics`'s vector fills, gated `isPrintedStyle`) and
        // sits under a byte-exact Tier-1 gate (`OracleByteParityTests`, "NO '?' box corners,
        // ever," `docs/RUNBOOK.md`) — leaving it untouched entirely removes any risk to that
        // gate from even a sub-point nudge. Modern has no such vector overlay (`graphicChars`
        // glyphs stay live text there, this job's own root cause) and no byte-exact gate. The
        // pre-existing `anyFontChanged` split (Printed's own Courier -> Courier New coverage
        // substitution, job 447) is UNCHANGED either way — only this NEW filler-kern pass is
        // skipped for a fixed-pitch base.
        if !baseFont.isFixedPitch {
            for i in runs.indices where !runs[i].isGraphic {
                let spaceCount = runs[i].text.lazy.filter { $0 == " " }.count
                guard spaceCount >= 2 else { continue }
                // IN MODERN, A FILLER RUN IS NOTHING BUT FILLER. A box row's interior is
                // spaces and nothing else (plus `modernNoBreakGraphicRuns`' own zero-width
                // joiners); a bullet row's BODY is prose that merely happens to follow a
                // graphic marker, and it has as many spaces as it has words. The old test —
                // "two or more spaces, and a graphic neighbour on either side" — cannot tell
                // them apart, so a single leading marker pinned every space on the line after
                // it: measured on VERSIONS.WS's bullet rows, whose marker is the cp437 solid
                // square, every inter-word space in the sentence following it came out 8.46pt
                // (the marker's own advance) against the library's 3.50pt Times space, so
                // each line ran 4.96pt wider per word and lost its last word.
                //
                // Requiring a genuine INTERIOR — a graphic run on BOTH sides — was the first
                // fix and it is wrong: measured, it took BOXES.WS's own interior rows to
                // x=222.70 against a top border at x=165.60, because a box row reaches this
                // function one SPAN at a time and an interior's other border is often in the
                // next span. What separates the two cases is the run's own CONTENT.
                //
                // PRINTED AND NATIVE KEEP THE ORIGINAL READING. Job 512 was found and
                // measured there, and narrowing it for them is not this batch's to do:
                // measured, it took PREVIEW.WS's Univers and CG Times past the Native gate's
                // drift tolerance, against real WS7 paper.
                if modernPitchScale {
                    // Both zero-width marks this renderer inserts: the word joiners
                    // `modernNoBreakGraphicRuns` puts inside a graphic run, and the
                    // zero-width spaces `runBoundaryBreaks` puts where two runs meet.
                    let bare = runs[i].text
                        .replacingOccurrences(of: "\u{2060}", with: "")
                        .replacingOccurrences(of: "\u{200B}", with: "")
                    guard !bare.isEmpty, bare.allSatisfy({ $0 == " " }) else { continue }
                }
                let neighbour = (i > 0 && runs[i - 1].isGraphic) ? runs[i - 1]
                    : (i + 1 < runs.count && runs[i + 1].isGraphic ? runs[i + 1] : nil)
                guard let neighbour, let pitch = graphicPitch(for: neighbour.font, in: neighbour.text)
                else { continue }
                pitches[i] = pitch
                needsFillerKern = true
            }
        }
        guard anyFontChanged || needsFillerKern else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        for (i, run) in runs.enumerated() {
            var runAttributes = attributes
            runAttributes[.font] = run.font
            if let pitch = pitches[i] {
                let spaceAdvance = (" " as NSString).size(withAttributes: [.font: run.font]).width
                var spaceAttributes = runAttributes
                spaceAttributes[.kern] = pitch - spaceAdvance
                for ch in run.text {
                    if ch == " " {
                        result.append(NSAttributedString(string: " ", attributes: spaceAttributes))
                    } else {
                        result.append(NSAttributedString(string: String(ch), attributes: runAttributes))
                    }
                }
            } else {
                result.append(NSAttributedString(string: run.text, attributes: runAttributes))
            }
        }
        return result
    }

    /// One graphic run's own font (job 447): if `baseFont` — the font `attributedRun` would
    /// have used for this whole span before this job — already covers `text`, it is returned
    /// UNCHANGED (a graphic run whose primary font happens to cover it, e.g. a document
    /// already on a covering face, never gets rerouted). Otherwise tries the SAME alternate
    /// job 442 measured as near-canonical ("Courier New", 0.0012pt/glyph residual vs. the
    /// engine's exact pitch — `outbox/job442/report.md`'s own measurement table): via
    /// `nativeCoverageAwareResolvedMacFont` (job 445) when `entry` is a real WS5+ font
    /// block, or directly by name when it is not (`entry == nil`: a WS4/print-stream span,
    /// or a WS5+ span whose index didn't resolve — neither has a `FontChange` to look a
    /// `falt` up FROM, the same gap `courierPrime(size:)`'s own doc comment names). Never
    /// returns nil: falls back to `baseFont`, so an uncoverable run keeps exactly the font
    /// (and therefore exactly the pre-job-447 AppKit substitution) it already had.
    static func coverageAwareGraphicFont(
        baseFont: NSFont, entry: FontChange?, size: CGFloat, bold: Bool, italic: Bool,
        useCourierPrime: Bool, coveringCharactersIn text: String
    ) -> NSFont {
        if fontCoversAllCharacters(baseFont, in: text) { return baseFont }
        if let entry {
            return nativeCoverageAwareResolvedMacFont(
                entry, size: size, bold: bold, italic: italic, useCourierPrime: useCourierPrime,
                coveringCharactersIn: text) ?? baseFont
        }
        guard let alt = NSFont(name: "Courier New", size: size) else { return baseFont }
        let styledAlt = nativeApplyTraits(alt, bold: bold, italic: italic)
        return fontCoversAllCharacters(styledAlt, in: text) ? styledAlt : baseFont
    }

    /// `(scaled font, baseline offset)` for a superscript or subscript run set against
    /// `base`.
    ///
    /// Two thirds of `base`'s size — the same ratio `PDFWriter.sized()` uses — then a
    /// baseline shift measured from THAT smaller font's own ascender/descender so its
    /// raised (or lowered) glyph tops out exactly at `base`'s own ascender (or bottoms out
    /// at `base`'s own descender). Either edge, matched exactly rather than cleared with
    /// margin: the point is fitting inside a line built for `base`, not looking as large as
    /// possible while doing it.
    /// `points`: Native passes the engine's own reduced size for the span
    /// (`printedSupSubMetrics`, WS7's per-face rule, a quarter point at most), so the run is
    /// set exactly as Printed sets it. `nil` keeps this function's Cocoa arithmetic (flat 2/3,
    /// `.rounded()`), which is what Modern passes.
    public static func scriptMetrics(for base: NSFont, raise: Bool,
                              points: Double? = nil) -> (font: NSFont, offset: CGFloat) {
        let scaledSize: CGFloat = points.map { CGFloat($0) }
            ?? max(1, (base.pointSize * 2 / 3).rounded())
        let scaled = fontResized(base, to: scaledSize) ?? base
        let offset = raise
            ? base.ascender - scaled.ascender
            : base.descender - scaled.descender
        return (scaled, offset)
    }

    /// The face for one Native-style span — WS5+'s font runs, faithfully; WS4's and every
    /// print stream's Courier, unconditionally.
    ///
    /// `fonts` is `doc.fonts`: EMPTY for WS4 files and print streams (`PDFWriter.swift`'s own
    /// comment on `doc.fonts` — "a PRINTED-mode facsimile feature"). The guard below falls
    /// through to `fallback` whenever `fonts` is empty OR `span.font` doesn't index it, so a
    /// WS4 document never enters the WS5+ branch at all — there is no format check here
    /// because there is nothing left to check once the array is empty. This is the same trick
    /// `spanFontEntry`/`pdfFamily` use in the engine (`PDFFonts.swift`) to keep a fontless
    /// document on Courier by construction rather than by branching on a format flag.
    ///
    /// Job 240 (b13, Part 1): chooses the engine's `.mac` render-target family
    /// (`nativeMacFontName`/`nativeResolvedMacFont`, this file's own top-of-file doc
    /// comments) rather than the base-14 clamp job 186/210/226 built and this job removed —
    /// MAC VIEWING RULING (decision register 2026-08-11; skill registry #25). `FontChange`'s
    /// fields used here (`typestyleName`, `symbolMap`, `family`, `genericStyle`, `points`)
    /// are all `public`, so this port only reads data the engine already exposes; it does
    /// not re-derive anything from raw bytes.
    ///
    /// PARTIALLY ported (job 202): a proportional span's LEADING-INDENT whitespace is
    /// re-stamped onto the document's own column grid in `attributedLine`, matching
    /// `splitIndent`'s own carve-out — see that call site's doc comment. The REST of a
    /// proportional span (real text after the indent, and any interior run) lays out at
    /// this resolved font's own NATURAL advance (job 229's per-word AFM/Tz corrective-kern
    /// port, `NativeWordAnchor.swift`, is REMOVED this job — see `attributedRun`'s own doc
    /// comment on that removal).
    static func resolvedFont(
        for span: Span, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool = false
    ) -> NSFont {
        guard !fonts.isEmpty, let index = span.font, index >= 0, index < fonts.count else {
            return styled(fallback, with: span.styles)
        }
        return resolvedFont(for: fonts[index], styles: span.styles, fallback: fallback, defaultSize: defaultSize,
                            useCourierPrime: useCourierPrime)
    }

    /// The shared tail of `resolvedFont(for: Span...)` above, parameterized on an already-
    /// resolved `FontChange` rather than a `Span`+index lookup — job 256 (Show Invisibles
    /// part 2/4) needed this same Mac-font resolution for `AnnotatedSpan.font`, which
    /// already carries the `FontChange` directly (`AnnotatedLayout.swift`'s own doc comment:
    /// "so a viewer can size a mark... without re-deriving the surrounding run"), not an
    /// index into `Document.fonts`. Pure extraction — behavior for the `Span` overload above
    /// is unchanged.
    static func resolvedFont(
        for font: FontChange, styles: Style, fallback: NSFont, defaultSize: Int, useCourierPrime: Bool = false
    ) -> NSFont {
        // ROUND HALF TO EVEN, as the library does: `spanRender` resolves a font block's own
        // declared height with `roundHalfToEven(points)` (`PDFFonts.swift`), and Swift's
        // `.rounded()` is half-AWAY-from-zero, so a block declaring 14.5pt would become 15
        // here and 14 there. No fixture in either gate moves on it — recorded as the
        // correctness fix it is, not as a measured win.
        let size = font.points > 0
            ? max(1, CGFloat(CtrlKD.roundHalfToEven(font.points)))
            : CGFloat(defaultSize)
        return nativeResolvedMacFont(
            font, size: size, bold: styles.contains(.bold), italic: styles.contains(.italic),
            useCourierPrime: useCourierPrime
        ) ?? styled(fallback, with: styles)
    }

    /// Job 227: does this line's own tallest resolved glyph need more room than the
    /// fragment `advanceLead` is about to give it?
    ///
    /// LJ6DTP.WS's 72pt "LJ6DTP" banner title, immediately followed by its own `.lh .05"`
    /// (3.6pt) shadow copy — the reference archive document `PDFWriter.pageStream`'s own
    /// doc comment cites by name (PDFWriter.swift:576-584). A line's lead is only ever the
    /// space ABOVE it there; the engine never boxes a line's height to that gap, so an
    /// oversized glyph simply paints past it with nothing to clip. This fragment's
    /// `minimumLineHeight == maximumLineHeight` box has no such freedom: measured directly
    /// (a throwaway probe, since removed — see this job's report), the 72pt banner squeezed
    /// into its 3.6pt-tall real fragment got a baseline at y=-13.4 in a container that
    /// starts at y=0 — entirely above the visible page, which is why the banner was
    /// `missingInActual` in the oracle rather than merely clipped.
    ///
    /// Job 240 (b13, Part 3) — TRIED AND REVERTED: LJ6DTP.WS p5's "Color Mappings" heading
    /// (job 232 class c) resolves (post this job's Mac font mapping, Part 1) to 22pt
    /// Optima-Bold in a 14pt-tall fragment. Direct measurement confirmed real clipping —
    /// `natural` (`defaultLineHeight`) ≈26.7pt (under the ×2 cutoff of 28pt), and the
    /// curly-quote GLYPH's own ink bounding box (`CTFontGetBoundingRectsForGlyphs`) tops
    /// out at 15.6pt, 1.6pt above the fragment's 14pt ceiling. Replacing the ×2 multiplier
    /// with a small FIXED points tolerance (tried: 1.5pt) DOES catch this fixture, but a
    /// full-gate re-run (`OracleByteParityTests`/`NativeStructuralParityTests`/
    /// `OverprintCompositingTests`) showed it also reclassifies large amounts of ORDINARY
    /// body text (YOURWAY.WS and others) as oversized — `natural` for a plain 10-12pt
    /// Times/Helvetica run routinely exceeds a tight document `.lh` by more than 1.5pt on
    /// its own, so a small FIXED allowance (unlike the ×2 ratio, which shrinks toward zero
    /// alongside `assignedLead`) is not selective enough: real body lines went BLANK
    /// (routed through the empty-inline-fragment/oversized-pass path meant for rare titles).
    /// Reverted to the original ×2 margin that job — the real signal (confirmed by direct
    /// glyph-bbox measurement) is glyph INK bounds vs. fragment height, not metric
    /// `defaultLineHeight` vs. any multiple/margin of `assignedLead`; that job's own report
    /// asked a follow-up to measure per-glyph ink bounds directly instead of retuning this
    /// margin further.
    ///
    /// Job 242 (b13) — FIXED, doing exactly what job 240 asked for: `natural`
    /// (`NSLayoutManager.defaultLineHeight`, the font's METRICS-table ascent+descent+
    /// leading, present whether or not this line's own characters ever reach that far) is
    /// replaced with the line's REAL ink extent — `CTLineGetBoundsWithOptions
    /// (.useGlyphPathBounds)` on each span's actual text at its resolved font (`inkTop`
    /// below), unioned across every span on the line, compared directly against
    /// `assignedLead` with NO multiplier. A metric proxy needs a fudge margin (the ×2, or
    /// job 240's rejected 1.5pt) precisely because it overstates ordinary glyphs' real
    /// height; real ink doesn't, so none is needed. This is why it's selective where job
    /// 240's fixed tolerance wasn't: an ordinary 10-12pt Times/Helvetica body run's own
    /// glyphs ink out to roughly cap-height (~0.7em), comfortably under a same-size-ish
    /// `.lh` — job 240's YOURWAY.WS false-positive class was a METRIC artefact, not a real-
    /// ink one, so it does not reappear here. Optima-Bold's 22pt curly quote inks out to
    /// 15.6pt in a 14pt fragment either way — real clipping, correctly caught. Verified
    /// against the same full gate job 240 used to catch its own regression (see this job's
    /// report).
    ///
    /// Internal rather than `private` so `SoftReturnTests` can tell which `PageLine`s
    /// `renderNative` routes through `naturalPass` instead of an ordinary fragment —
    /// `OverprintCompositingTests` needs it to keep its own real-fragment/pass accounting
    /// exact now that a pass can come from an oversized base line as well as an
    /// `.overprint` chain continuation.
    public static func lineExceedsFragment(
        _ line: PageLine, assignedLead: Double, fallback: NSFont, fonts: [FontChange], defaultSize: Int,
        useCourierPrime: Bool = false
    ) -> Bool {
        // Job 426 (PREVIEW.WS PIX in Native): an image `PageLine` (`line.image`, `spans`
        // empty by construction — job 371's own citation) never reached this check before —
        // this function measured ONLY `line.spans`' glyph ink, so a 74pt logo pinned into
        // whatever ~12-14pt fragment `advanceLead` gave it, same defect class as an
        // unrecognized oversized title, just never taught the same lesson. The image's own
        // `heightPt` (the SAME box `pageStream`'s XObject `cm` matrix and this renderer's own
        // `pixAttachmentString` both already draw the picture at) is the ink-equivalent
        // figure here — no glyph-bounds measurement needed, the image's real size already IS
        // its own "ink."
        if let image = line.image {
            return CGFloat(image.heightPt) > CGFloat(assignedLead)
        }
        var inkTop: CGFloat = 0
        for span in line.spans {
            guard !span.text.isEmpty else { continue }
            let font = resolvedFont(for: span, fallback: fallback, fonts: fonts, defaultSize: defaultSize,
                                    useCourierPrime: useCourierPrime)
            // Job 422: `.useGlyphPathBounds`' tight per-glyph ink (`Self.inkTop`) is not the
            // only figure that decides where this line's real content lands once AppKit lays
            // it out — the layout manager positions a fragment's baseline from the font's own
            // ASCENDER (the same figure `oversizedClearanceBelowBaseline`'s own doc comment
            // already cites as "the same figure NSLayoutManager.defaultLineHeight builds a
            // normal line's height from"), which for a real, non-monospaced-cap-height font
            // can exceed the tight glyph-path measurement by several points. WARPRAYR.WS's
            // 20pt title measured 11.6pt of tight ink against a 12pt lead — just under this
            // function's old ink-only threshold, so it fell through to ordinary (non-oversized)
            // handling — but the real `NSLayoutManager` reserved room for CourierPrime-Bold's
            // own 15.6pt ascender, needing ~13pt more than the 12pt fragment had, with nowhere
            // for that overshoot to go on a page's own first line: real, visible top-clipping
            // (job 422's own probe: `ZZProbeJob422Layout`, `titleBoundingRect` measured 12.84pt
            // above the fragment's own top edge) that both the tight-ink check here AND
            // `TitleAscenderTests`' own independently-derived expectation (the SAME
            // `.useGlyphPathBounds` measurement, `expectedTopInkPt`) were blind to, since both
            // sides of that comparison shared the identical blind spot.
            inkTop = max(inkTop, Self.inkTop(for: span.text, font: font), font.ascender)
        }
        return inkTop > CGFloat(assignedLead)
    }

    /// Job 242: the real glyph ink extent of `text` set in `font`, measured ABOVE the
    /// baseline (`y = 0`) the same way `lineExceedsFragment` compares it against
    /// `assignedLead` — i.e. what a same-baseline, unbounded container would actually need
    /// above the line to avoid clipping this exact text, not what the font's metrics table
    /// promises some OTHER glyph in it might need. `.useGlyphPathBounds` asks CoreText for
    /// the drawn outline's own bounds (job 240's probe used the lower-level per-glyph
    /// `CTFontGetBoundingRectsForGlyphs`; this is the same measurement, taken once per span
    /// across its whole run — including real kerning/positioning — rather than unioning
    /// isolated per-glyph boxes by hand).
    static func inkTop(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return bounds.origin.y + bounds.height
    }

    /// Job 267 (Show Invisibles reflow, field bug 1): how much room below its own target
    /// baseline an OVERSIZED line's self-pass (`lineExceedsFragment`'s `naturalPass`/
    /// `drawOversizedSelfPasses`) needs to clear before the NEXT fragment can safely start.
    ///
    /// Deliberately the font's own METRIC descent (`-font.descender`, always >= 0, a fixed
    /// per-font figure — same family `NSLayoutManager.defaultLineHeight` draws from), not
    /// `inkTop`'s tight per-glyph `.useGlyphPathBounds` reading. A title with no literal
    /// descenders (`OLDTIMES.WS`'s "Just Like Old Times" — no g/j/p/q/y) inks exactly zero
    /// pixels below its own baseline, so the tight measurement was tried first and measured
    /// a real 0 — yet Jon's field screenshot shows the very next line (the reflow's own
    /// fabricated `.h1` mark) crowding directly against the title's own CAP-HEIGHT lettering
    /// with no visual air between them at all. A human reading "collision" is judging
    /// TYPOGRAPHIC clearance, the gap a normal line of this size would command, not whether
    /// individual glyph outlines technically touch — the same gap the font's own metrics
    /// table (and every ordinary `NSLayoutManager` line height) already encodes.
    public static func oversizedClearanceBelowBaseline(
        _ line: PageLine, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool = false
    ) -> CGFloat {
        var clearance: CGFloat = 0
        for span in line.spans {
            guard !span.text.isEmpty else { continue }
            let font = resolvedFont(for: span, fallback: fallback, fonts: fonts, defaultSize: defaultSize,
                                    useCourierPrime: useCourierPrime)
            // `-font.descender` alone (job 267's first attempt) still measured a visible
            // collision on OLDTIMES's own title: the font's cap-height/ascent, not just its
            // descender, is what pins the SELF-PASS's own baseline so close to its fragment's
            // top edge in the first place (`normalBaselineOffset` is a small BASE-FONT figure,
            // 9pt, used for every self-pass regardless of the oversized font's own size) — a
            // large font's ascent alone can already exceed a 12pt lead many times over, and
            // whatever of that doesn't fit above the baseline reads, to a human, as "sitting
            // low, crowding the next line" even where the glyph ink technically stays inside
            // its own box. `ascender - descender` (the font's FULL em advance — the same
            // figure `NSLayoutManager.defaultLineHeight` builds a normal line's height from)
            // is the conservative, guaranteed-enough figure: reserving a full ordinary line's
            // worth of THIS font's own natural height, not merely its descent.
            clearance = max(clearance, font.ascender - font.descender)
        }
        return clearance
    }

    /// Job 396 (391 root cause 5): `RenderedDocument.leadingHeadroom` — per page, how much
    /// blank canvas `PagedDocumentView` must reserve above that page's own nominal top so
    /// its FIRST fragment's oversized self-pass (`oversizedSelfPasses[page].first`, when
    /// non-nil) can bleed its full ascent without clipping.
    ///
    /// Measured exactly the way `lineExceedsFragment`/`inkTop` already measure a fragment's
    /// real ink — `CTLineGetBoundsWithOptions(.useGlyphPathBounds)` on the self-pass's own
    /// (already fully resolved/styled) `NSAttributedString`, not a font-metrics guess —
    /// against THIS PAGE's own real first-baseline (`firstBaselines[page]`, job 425 — see
    /// `perPageFirstBaselines`'s own citation in `renderNative`: `top + THIS line's own
    /// lead`, not a flat `top + size` shared by every page). A self-pass whose real ink
    /// already fits above that baseline (LJ6DTP.WS's banner may or may not, depending on its
    /// resolved font — not assumed either way, only measured) needs no extra room at all.
    /// Using each page's own REAL anchor (where `drawOversizedSelfPasses` actually draws it,
    /// via `pinnedBaselines`) rather than the nominal shared `textTop` anchor is deliberate:
    /// "does this ink bleed off the PHYSICAL page's top edge" is a question about where the
    /// ink is actually drawn, not about the screen container's own nominal position.
    ///
    /// The `+ 2` float-safety margin on a real deficit is bigger than this codebase's usual
    /// established convention for a measured-not-guessed figure
    /// (`PagedDocumentView.buildExplicitPages`'s `epsilon`, 0.5) — deliberately: the ink
    /// bounds a real glyph path reports are not perfectly reproduced by a second,
    /// independent AppKit drawing pass landing pixel-for-pixel on the same coordinate, so a
    /// razor-tight reservation would reintroduce a one-pixel version of the exact bug this
    /// fixes, and a wider margin also keeps a REGRESSION (headroom silently dropped again)
    /// unambiguously distinguishable from "working as intended" under a pixel-truth test's
    /// own antialiasing tolerance (`TitleAscenderTests`).
    public static func leadingHeadroom(
        _ oversizedSelfPasses: [[NSAttributedString?]], firstBaselines: [Double]
    ) -> [CGFloat] {
        oversizedSelfPasses.enumerated().map { pageIndex, page in
            guard let maybePass = page.first, let pass = maybePass, pass.length > 0 else { return 0 }
            guard firstBaselines.indices.contains(pageIndex) else { return 0 }
            let ctLine = CTLineCreateWithAttributedString(pass)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
            let inkTop = bounds.origin.y + bounds.height
            let deficit = inkTop - CGFloat(firstBaselines[pageIndex])
            return deficit > 0 ? deficit + 2 : 0
        }
    }

    /// Job 210: the foreground colour for one span — `colourMap[span.colour]` as a
    /// grayscale `NSColor` when the document's driver colour applies (`colourMap` is
    /// non-empty only for LJ6DTP, `nativeLJ6DTPColourGray`'s own doc comment), else the
    /// ordinary black ink every other document has always used. Port of the SAME gate the
    /// engine's `lineOpsPrinted` applies to its own `g` operator (`PDFWriter.swift:486-492`:
    /// "Emitted only when the value CHANGES... every all-black document... writes not one
    /// extra byte") — here there is no operator-diffing to do (AppKit attributes aren't a
    /// byte stream), so every run simply asks for its own resolved colour directly.
    static func driverColour(_ colour: Int?, _ colourMap: [Int: Double]) -> NSColor {
        guard let colour else { return .black }
        // job-489 (C1): `colourMap` empty means this document isn't LJ6DTP at all
        // (`renderNative`'s own gate) — the SAME condition every other driver-colour branch
        // here already checks, so a pattern index never applies to a non-LJ6DTP document's
        // own `span.colour` (if any) either.
        if !colourMap.isEmpty, lj6dtpHPPatternIndices.contains(colour) {
            return NSColor(patternImage: LJ6DTPPattern.tileImage(for: colour))
        }
        guard let gray = colourMap[colour] else { return .black }
        return NSColor(white: CGFloat(gray), alpha: 1)
    }

    /// job-489 (C1): `driverColour`'s own `.foregroundColor`, plus — only for an HP pattern
    /// index — the companion `.lj6dtpPatternIndex` attribute `graphicCells`
    /// (`NativeVectorGraphics.swift`) needs to recover which of the six hatches a colour-
    /// driven glyph FILL (not just plain text) wants. Both call sites that used to write
    /// `.foregroundColor: driverColour(...)` directly now merge this dictionary in instead.
    /// Register b31 (job 506, E2): also tags a colour1-7 run with `.lj6dtpDarkenColour` —
    /// see that key's own doc comment — so a self-pass drawing this text (LJ6DTP's masthead
    /// shadow) can ask the graphics context for a Darken blend the same way the engine's
    /// `lineOpsPrinted` now does. Colour15 (white knockouts) and plain colourless black text
    /// are excluded by the SAME `(1...7).contains(colour)` range check the engine uses.
    static func driverColourAttributes(
        _ colour: Int?, _ colourMap: [Int: Double]
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: driverColour(colour, colourMap)]
        if let colour, !colourMap.isEmpty, lj6dtpHPPatternIndices.contains(colour) {
            attrs[.lj6dtpPatternIndex] = colour
        }
        if let colour, !colourMap.isEmpty, (1...7).contains(colour) {
            attrs[.lj6dtpDarkenColour] = true
        }
        return attrs
    }

    /// Apply the IR's bold/italic to a base face. Native style asks for Courier, whose
    /// bold and oblique members are what the PDF emitter names; Modern asks for the user's
    /// font, whose traits AppKit synthesises where the family lacks them.
    static func styled(_ font: NSFont, with styles: Style) -> NSFont {
        var traits: NSFontTraitMask = []
        if styles.contains(.bold) { traits.insert(.boldFontMask) }
        if styles.contains(.italic) { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    /// Courier, the typescript face — the same family `emitPDF` names, so a page looks the
    /// same on screen as it does exported. Falls back to the system monospaced face if
    /// Courier is ever absent, which would change the look but never the metrics: both are
    /// asked for at the document's own `.cw`-derived size.
    static func courier(size: CGFloat) -> NSFont {
        NSFont(name: "Courier", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Job 437 (b27, Jon's font-fallback ruling): the NO-FONT-INDEX fallback for a span
    /// inside a document that DOES declare fonts elsewhere — the bundled face Native's own
    /// courier-class rows already resolve to (`nativeMacFontName`'s `useCourierPrime`
    /// branch, "Courier Prime" primary / "Courier New" `falt`), used here directly rather
    /// than through that WS5+-font-block-keyed lookup: a span with no font index has no
    /// `FontChange` to look a row up FROM in the first place — this is the same terminal
    /// substitute those rows resolve TO, requested unconditionally. "Courier New" is the
    /// same defensive second choice `nativeMacFontName` already names for the identical
    /// reason (the bundled face failing to register); the system monospaced face is a third
    /// line only `courier(size:)` above has ever needed to reach for.
    static func courierPrime(size: CGFloat) -> NSFont {
        NSFont(name: "Courier Prime", size: size)
            ?? NSFont(name: "Courier New", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
