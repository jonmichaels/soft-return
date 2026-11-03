#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Running heads and feet

    /// Port of `runningOps`'s GEOMETRY (`CtrlKD/PDFWriter.swift:177-238`) — not its PDF byte
    /// emission, which stays engine-only. `runningOps` itself is `internal`, so this reads the
    /// same public inputs it does (`Page.headers`/`.footers`, `Document.page`'s `mtLines`/
    /// `hmLines`/`plLines`/`mbLines`/`fmLines`) and reproduces its two placement formulas:
    ///
    /// - Header: anchored to the BODY, not the paper edge — its last line sits `.hm` lines
    ///   above the first body line, inside `.mt` (`PDFWriter.swift:216-226`).
    ///   `headBase = max(0, mt - hm - topHead)`, `topHead` = the highest header line number
    ///   in use.
    /// - Footer: `.fm` lines below the body, at `footLine = pl - mb + fm`
    ///   (`PDFWriter.swift:233`).
    ///
    /// Both then place line `n` at `n * lead + size` points below the paper's top edge — the
    /// app's own top-down convention, converted from the engine's bottom-up
    /// `y = pageHeight - line*lead - size` (`PDFWriter.swift:207`) via `pageHeight - y`.
    ///
    /// `#` -> page number, same token `runningOps`'s own `render(_:)` substitutes
    /// (`PDFWriter.swift:198-205`).
    ///
    /// The three WordStar-spec fallback constants (66/8/2 lines) are the SAME literals
    /// `runningOps` falls back to for a bare print stream with no `Document.page`
    /// (`defaultPlLines`/`defaultMbLines` in `ParseWS.swift`, and `doc.page?.fmLines ?? 2`
    /// in `PDFWriter.swift:194`) — spec constants, not derived engine arithmetic, so vendoring
    /// them here carries none of the `spanPitch`/`tzScale` drift risk this file's other doc
    /// comments warn about.
    /// WordStar's own AUTOMATIC page number: whether it is switched ON for `page`.
    ///
    /// PAGE NUMBERING IS ON BY DEFAULT (engine commit 5756263, mirroring ctrl-kd b6d5d03 —
    /// `ws7-prints/v3` finding #2). A genuinely stock WS7 install numbers a document even
    /// when it never touches `.pn`/`.pg`/`.op`/`.pc`; the older "silent by default" reading
    /// was measured against Robert J. Sawyer's own WSCHANGE-customized install, the same
    /// contamination family as mechanisms S/T/U/W. So `checkpoints` seeds ON.
    ///
    /// Port of the engine's `pgnumTimeline`/`Timeline.at` (`PDFLayout.swift`, both
    /// `internal`) against the public `Document.dotPositions`. `.pn`/`.pg` switch it on,
    /// `.op` off, and the LAST checkpoint at or before this page's own highest block index
    /// wins — the same "checkpoint at or before this block" contract `Timeline.at` use.
    /// A page carrying no block index at all resolves OFF, matching the engine's own final
    /// `else` branch rather than inheriting a neighbouring page's state.
    ///
    /// The dot-command name scan is the engine's: the 1-3 ASCII letters after the dot, no
    /// word boundary required, because a real WS7 file overwhelmingly writes `.pn0`/`.pg`
    /// with no space before a following digit.
    public nonisolated static func nativeAutoPageNumberOn(page: Page, doc: Document) -> Bool {
        guard let pageMaxBi = page.compactMap(\.bi).max() else { return false }
        var on = true
        for dp in doc.dotPositions {
            var scalars = Array(dp.text.unicodeScalars)
            guard scalars.first == "." else { continue }
            scalars.removeFirst()
            let letters = scalars.prefix(while: { CharacterSet.letters.contains($0) })
            guard (1...3).contains(letters.count) else { continue }
            let name = String(String.UnicodeScalarView(letters)).uppercased()
            let value: Bool
            switch name {
            case "PN", "PG": value = true
            case "OP": value = false
            default: continue
            }
            if dp.blockIndex <= pageMaxBi { on = value }
        }
        return on
    }

    /// Left edge (points) of the automatic page number's text, from `.po`/`.pc`. Port of the
    /// engine's `autoPageNumberXPt` (`PDFLayout.swift`, `internal`).
    ///
    /// Measured, not derived from the manual: the number is LEFT-anchored at column
    /// `(poCols + pcCol - 1)` in the same 10-CPI frame `.po` uses, regardless of how many
    /// digits it has. `.pc 0` and `.pc` never declared at all are the SAME internal state
    /// and both resolve to the fixed measured column 33.5 — the manual's "centered between
    /// the margins" wording does not hold as measured. `8.0` is the WS7 manual's own default
    /// `.po`, matching the engine's own fallback in this function.
    public nonisolated static func nativeAutoPageNumberXPt(_ doc: Document) -> Double {
        let po = doc.page?.poCols ?? 8.0
        let pcRaw = doc.page?.pcCol
        let pc = (pcRaw != nil && pcRaw != 0) ? Double(pcRaw!) : 33.5
        return (po + pc - 1) * 7.2
    }

    /// `leftAnchor` is the x `PagedDocumentView.drawRunningLines` will actually start from —
    /// `RenderedDocument.textFrame.origin.x`, which is the document's LEFTMOST line, not
    /// necessarily its default `.po` (see `printedLeftAnchor` in `renderNative`). Every
    /// offset this function records is measured from it, so a document whose body reaches
    /// left of its own default does not drag its running heads left with it.
    static func runningLines(
        for page: Page, pageNo: Int, doc: Document, metrics: PrintedPageMetrics,
        leftAnchor: Double, sheetHeight: Double? = nil
    ) -> [RunningLine] {
        // Batch 47 (M31-app): the engine flips a page's running lines against THAT page's sheet (07b040c).
        let pageHeight = sheetHeight ?? metrics.pageHeight
        // THE MODEL SAYS WHAT GOES ON THIS PAGE AND WHERE — planning #251(d).
        //
        // `Page.headerLines`/`footerLines`/`autoPageno` arrive from
        // `attachHeadFootLinesPrinted`, which calls the SAME `resolveHeadFootLines` the PDF
        // writer calls to render: `#` already substituted, a fontless line's right-tab
        // realignment already baked, and each line's own x, y and font index attached. So
        // everything this function used to re-derive goes with it — which side pre-empts
        // which, `headBase` out of `.mt`/`.hm`/the top header line, `footLine` out of
        // `.pl`/`.mb`/`.fm`, and the whole `.po`/`.poe`/`.poo` question.
        //
        // That last one is worth naming, because it was the subtlest thing in this file. A
        // page's `.po` snapshot can be a body-only margin excursion that merely happened to
        // be in force when the page opened, and letting one of those move a running head is
        // what the engine's own `pageGeomChanged` test exists to prevent; `.poe`/`.poo` are
        // the exception, since an even/odd page offset IS a page-layout decision. That rule
        // was ported here field for field and had to be kept in step by hand. It is the
        // engine's answer alone now — `HeadFootLine.x` already carries it.
        //
        // `y` is the engine's own PDF coordinate, measured up from the paper's bottom, so a
        // baseline from the top is `pageHeight - y`; the writer's own `guard y >= 0` is the
        // same test as `baseline <= pageHeight`.
        let headerLines = page.headerLines ?? []
        let footerLines = page.footerLines ?? []
        guard !headerLines.isEmpty || !footerLines.isEmpty || page.autoPageno != nil else {
            return []
        }

        // Job 240 (b13, Part 1): the cp1252 esc-degradation this used to chain
        // (`nativeEscDegrade`) is gone — MAC VIEWING RULING, see that removal's own doc
        // comment above. `nativeStripControlChars` stays: that is a genuine control-byte
        // display fix (job 226), unrelated to font-encoding floors.
        // `∙` IS A MIDDLE DOT HERE TOO. The engine's `runningOps` maps it unconditionally on a
        // running head's own text (`∙` U+2219 BULLET OPERATOR -> `·` U+00B7 MIDDLE DOT, the
        // small dot the LaserJet prints for 0xF9), and this path once drew it as is. Measured on
        // LJ6DTP.WS, whose `.h1` carries the extended character 0xF9: the app drew the
        // narrower BULLET OPERATOR, so everything after it in the head sat left of the
        // engine's — a region-diff row on the head band of all eight pages, and the page
        // number's own cell empty where the engine has ink.
        func rendered(_ text: String) -> String {
            nativeStripControlChars(text)
        }
        let font = courierPrime(size: CGFloat(metrics.size))
        // Job 228: the AppKit-measured distance from a `draw(at:)` origin to that call's
        // actual first baseline, for exactly the font and (absent — see `line` below)
        // paragraph style a running line is built with. `RunningLine.drawOriginOffset`'s own
        // doc comment has the citation; measured once per page since it depends only on
        // `font`, not on any one header/footer's text.
        let drawOriginOffset = Double(firstBaselineOffset(
            font: font, paragraph: NSParagraphStyle(),
            width: max(1, metrics.pageWidth - metrics.left)))
        // Job 226: `nil` when the SOURCE text was entirely print-control bytes (LJ6DTP.WS's
        // own footer, `"\u{0F}\u{0F}"` — two rule-drawing controls, no visible content at
        // all) — `nativeStripControlChars` degrades that to `""`, and `PagedDocumentView
        // .drawRunningLines` reads `.attribute(.font, at: 0, ...)` unconditionally, which
        // traps on a zero-length attributed string. A running line with nothing left to
        // show is exactly a running line that should not exist, matching the engine's own
        // behaviour (`runningOps`'s `op(_:line:)` still emits a — invisible — `Tj` for it,
        // but an empty string here is the same "draws nothing" outcome without the trap).
        // Job 429 (`NativeVsEngineGeometryTests`' own margin gate, YOURWAY.WS's proving
        // failure — `.lh 18` is the fixture's whole point): `lineLead` used to be
        // `metrics.lead` (the document's own `.lh`-derived BODY lead) unconditionally for
        // both kinds. The engine's own `runningOps` (`PDFWriter.swift:301-330`) uses a
        // DIFFERENT unit per kind: the header's `op(txt, line:lead:)` call passes the FIXED
        // `PDFMetrics.lead` (12pt, 6 LPI — `.mt`/`.hm` are LINE-COUNT dot commands "always at
        // the FIXED 6 LPI (12pt) baseline... a SEPARATE unit from `.lh`", that citation's own
        // words), while the footer's call passes the real `lead` parameter (the document's
        // own body lead) — an intentional, documented asymmetry, not an oversight. This
        // function's own header call site duplicated the WRONG half of that split (the real
        // `.lh`-derived lead, matching the engine's FOOTER unit) — invisible on every fixture
        // whose `.lh` happens to already be 12pt (`PDFMetrics.lead`'s own value), exactly the
        // condition the engine's own citation names as why this bug class hides "until
        // [a fixture] whose own `.lh` is customized" surfaces it. Confirmed against real
        // `emitPDF` bytes (`EngineTruth.structuralPages`, `NativeStructuralParityTests.swift`)
        // via `NativeVsEngineGeometryTests.marginsMatchTheEngine`: YOURWAY.WS's own header
        // (`.lh 18`, `headBase` 2 lines) sat exactly `2 * (18 - 12) = 12.0pt` too low on every
        // page but the first.
        // Job 489 (b29 adoption, register C6): the resolved face for a `.h#`/`.f#` line
        // that opened with its own WS5+ font block — mirrors the engine's `hfLineOps`
        // (`PDFWriter.swift`): toggle-byte-interpreted runs, a PROPORTIONAL font's leading
        // whitespace re-stamped onto the document's own Courier column grid (never drawn
        // in the proportional face, exactly `appendSpan`'s own body-text indent carve-out),
        // and every other run drawn in the resolved face with that run's own bold/italic.
        // Returns `nil` for a line with nothing left to draw once toggles are consumed
        // (`nativeHeadFootRuns`' own empty-runs case).
        // Batch 41: `lineStyle` is the engine's own resolved style for the whole line
        // (`HeadFootLine.styleAttrs` — a `.h#`/`.f#` style sheet's bold, say), ORed with each
        // run's toggles exactly as `hfLineOps` does.
        // Planning #549: `font`/`size` are the line's own (`HeadFootLine.size`, a WS4 head in the `.CW` it was read
        // under), the page's otherwise: the face a fontless run and a size-less record print in.
        func styledLine(_ rawText: String, entry: FontChange, lineStyle: Style, font: NSFont, size: Int)
            -> (text: NSAttributedString, leadingOffset: Double, drawOriginOffset: Double)? {
            let runs = nativeHeadFootRuns(rawText)
            guard !runs.isEmpty else { return nil }
            let result = NSMutableAttributedString()
            var leadingOffset: Double = 0
            var stillLeading = true
            for run in runs {
                let text = nativeStripControlChars(run.text)
                guard !text.isEmpty else { continue }
                if stillLeading, entry.proportional, text.trimmingCharacters(in: .whitespaces).isEmpty {
                    leadingOffset += NSAttributedString(string: text, attributes: [.font: font]).size().width
                    continue
                }
                stillLeading = false
                let runFont = resolvedFont(for: entry, styles: run.styles.union(lineStyle), fallback: font,
                                           defaultSize: size, useCourierPrime: true)
                result.append(NSAttributedString(string: text, attributes: [
                    .font: runFont, .foregroundColor: NSColor.black,
                    .kern: nativeCourierPitchKern(runFont),
                    .ligature: nativeNoLigatures,
                ]))
            }
            guard result.length > 0 else { return nil }
            let resolvedBase = resolvedFont(for: entry, styles: [], fallback: font,
                                            defaultSize: size, useCourierPrime: true)
            let originOffset = Double(firstBaselineOffset(
                font: resolvedBase, paragraph: NSParagraphStyle(),
                width: max(1, metrics.pageWidth - metrics.left)))
            return (result, leadingOffset, originOffset)
        }

        // Planning #549 (WS7 teardown 3.15): a line that changes face after its opening, in its pieces
        // (`HeadFootLine.pieces`), drawn as Printed's `hfPiecesOps` draws it: each piece in its own face (a fontless one
        // in Courier at the line's size), WordStar's toggle bytes running on from piece to piece, the first run's blanks
        // under a proportional face skipped on the column grid, and a piece with an `x` (a tab's text: a tab is
        // absolute) starting at that x. A following piece follows on in the Mac face, as a one-face line's runs do. The
        // x is reached by kerning the character before it to there, so the line stays one string.
        func piecedLine(_ pieces: [HeadFootPiece], lineX: Double, lineStyle: Style, font: NSFont, size: Int)
            -> (text: NSAttributedString, leadingOffset: Double)? {
            // `hfPieceRuns`: the runs of all the pieces, with one toggle state across them
            var runs: [(text: String, styles: Style, font: Int?, x: Double?)] = []
            var active: Style = []
            var buffer = ""
            var face: Int?
            var x: Double?
            func flush() {
                guard !buffer.isEmpty else { return }
                runs.append((buffer, active, face, x))
                buffer = ""
                x = nil
            }
            for piece in pieces {
                flush()
                face = piece.font
                x = piece.x
                for scalar in piece.text.unicodeScalars {
                    if scalar.value == 0x2219 {
                        buffer.unicodeScalars.append(Unicode.Scalar(0x00B7)!)
                        continue
                    }
                    if let toggle = nativeHFToggles[scalar.value] {
                        flush()
                        active.formSymmetricDifference(toggle)
                        continue
                    }
                    if scalar.value < 0x20 { continue }
                    buffer.unicodeScalars.append(scalar)
                }
            }
            flush()
            guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            let result = NSMutableAttributedString()
            var leadingOffset: Double = 0
            for (i, run) in runs.enumerated() {
                if let target = run.x {
                    // The blanks before a tab's text print nothing, and the text system does not move the pen by a
                    // kern on a blank: they go, and the last character drawn carries the move.
                    while let last = result.string.last, last == " " || last == "\u{00A0}" {
                        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                    }
                    if result.length == 0 {
                        leadingOffset = target - lineX
                    } else {
                        // the pen to `target`: the last character's own advance, kern included, carries the gap
                        let width = Double(CTLineGetTypographicBounds(
                            CTLineCreateWithAttributedString(result as CFAttributedString), nil, nil, nil))
                        let last = result.length - 1
                        let kern = (result.attribute(.kern, at: last, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                        result.addAttribute(.kern, value: kern + (target - lineX - leadingOffset) - width,
                                            range: NSRange(location: last, length: 1))
                    }
                }
                let text = nativeStripControlChars(run.text)
                guard !text.isEmpty else { continue }
                let entry = run.font.flatMap { doc.fonts.indices.contains($0) ? doc.fonts[$0] : nil }
                if i == 0, let entry, entry.proportional, text.trimmingCharacters(in: .whitespaces).isEmpty {
                    // a column each, 10 CPI whatever the size (the engine's `pdfPtPerCol`)
                    leadingOffset += Double(text.count) * 7.2
                    continue
                }
                let styles = run.styles.union(lineStyle)
                let runFont = entry.map {
                    resolvedFont(for: $0, styles: styles, fallback: font, defaultSize: size, useCourierPrime: true)
                } ?? Self.styled(font, with: styles)
                result.append(NSAttributedString(string: text, attributes: [
                    .font: runFont, .foregroundColor: NSColor.black,
                    .kern: nativeCourierPitchKern(runFont),
                    .ligature: nativeNoLigatures,
                ]))
            }
            return result.length > 0 ? (result, leadingOffset) : nil
        }

        // Job 489/490 tried a matching `baseline <= metrics.pageHeight` guard here (mirroring
        // the engine's own `runningOps`, `PDFWriter.swift`, `guard y >= 0 else { continue }` —
        // a running line whose baseline would land past the bottom of the sheet never gets a
        // `Tj` at all) and reverted it: measured against `NativeStructuralParityTests`'
        // `EngineTruth` at the time, it "fixed 6 of LJ6DTP's own known divergent slots but
        // silently introduced 2 NEW ones (pages 7/8's own footer, previously agreeing, now
        // wrongly suppressed)".
        //
        // Job 491 root-caused THAT measurement itself as corrupted: `EngineTruth
        // .contentStreams` (`NativeStructuralParityTests.swift`) assumed only page-content
        // objects carry a `stream`/`endstream` pair, which is false for any LJ6DTP-driver
        // fixture — the driver's own 6 HP1-HP6 tiling patterns (`PDFWriter.swift`'s
        // `patternObjs`, register C3) ALSO carry one, at LOWER object numbers than any page,
        // so they sorted first in the real PDF and silently shifted job-489/490's "page 7/8"
        // reads to genuinely page 1/2's own content. With that harness bug fixed, the
        // engine's real per-page running-head X/Y (parsed straight from the real, correctly
        // page-aligned `emitPDF` bytes) is IDENTICAL to what this function already computes
        // on every page of LJ6DTP.WS — `NativeVsEngineGeometryTests.marginsMatchTheEngine`
        // went from 1 failure to 0 (46/46) from the harness fix ALONE, no production code
        // changed. The guard below is reintroduced NOW, against that corrected baseline, and
        // the full suite (see this job's report) shows it introduces no new divergence.
        func line(_ resolved: HeadFootLine, kind: RunningLine.Kind) -> RunningLine? {
            // E11 (engine b86d214): a row the engine flags off the sheet is never drawn — the PDF still writes it and
            // the paper clips it; a view has no paper. The flag is `hfOffSheet(y)`, this guard's own test.
            guard !resolved.offSheet else { return nil }
            let text = resolved.text
            let baseline = pageHeight - resolved.y
            let pageLeftOffset = resolved.x - leftAnchor
            let entry = resolved.font.flatMap { doc.fonts.indices.contains($0) ? doc.fonts[$0] : nil }
            // Batch 41: the weight and slant the engine resolved for this line (its style sheet's
            // own attrs, parity applied). Printed draws no underline on a running line, so only
            // bold and italic are taken.
            let lineStyle = resolved.styleAttrs.intersection([.bold, .italic])
            // Planning #549 (WS4 teardown 4 §15.3): a line printed at a size of its own (`HeadFootLine.size`, a WS4
            // head in the `.CW` it was read under) is drawn at it, as Printed's `hfLineOps` draws it.
            let lineSize = resolved.size ?? metrics.size
            let lineFont = resolved.size.map { courierPrime(size: CGFloat($0)) } ?? font
            let lineOriginOffset = resolved.size == nil ? drawOriginOffset : Double(firstBaselineOffset(
                font: lineFont, paragraph: NSParagraphStyle(), width: max(1, metrics.pageWidth - metrics.left)))
            if let pieces = resolved.pieces, !pieces.isEmpty {
                guard let pieced = piecedLine(pieces, lineX: resolved.x, lineStyle: lineStyle,
                                              font: lineFont, size: lineSize) else { return nil }
                // Measured on the line itself, as a toggled line is: its faces and sizes are mixed.
                return RunningLine(text: pieced.text, baselineFromTop: baseline,
                                   drawOriginOffset: Self.isolatedFragmentK(
                                       pieced.text, width: max(1, metrics.pageWidth - metrics.left)),
                                   kind: kind, leadingOffset: pieced.leadingOffset,
                                   pageLeftOffset: pageLeftOffset)
            }
            if let entry, let styled = styledLine(text, entry: entry, lineStyle: lineStyle,
                                                  font: lineFont, size: lineSize) {
                return RunningLine(text: styled.text, baselineFromTop: baseline,
                                   drawOriginOffset: styled.drawOriginOffset, kind: kind,
                                   leadingOffset: styled.leadingOffset,
                                   pageLeftOffset: pageLeftOffset)
            }
            // A head's tabs are already placed: `resolveHeadFootLines` re-tabs `HeadFootLine.text`
            // for this page before the model carries it, so the text is drawn as it stands, with
            // no second copy of the engine's tab rule here to fall out of step.
            //
            // MECHANISM M (engine commit f79ff29, mirroring ctrl-kd 74acc60): a FONTLESS
            // `.h#`/`.f#` line whose own text carries an inline style toggle (a `^Y` italic,
            // say) must have that toggle INTERPRETED, not dropped. The engine's `hfLineOps`
            // takes its run-by-run path "whenever the line carries a control byte, not only
            // when a font block is present" — before that fix the byte leaked into the PDF
            // as a literal, phantom-advancing every word after it.
            //
            // This renderer had the mirrored half of the same bug from the other direction:
            // `styledLine` (job 489) is reached ONLY when the line has a font block, so a
            // fontless toggled line fell through to the plain path below, where
            // `nativeStripControlChars` deleted the toggle byte and nothing ever applied
            // the style it announced — the words were right, the italics were missing.
            //
            // Plain Courier with the run's own bold/italic, matching the engine's own
            // fallback face for a line with no `.h#`/`.f#` font block of its own. A line with
            // no control byte at all stays on the exact prior single-run path, byte for byte.
            if entry == nil, text.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                let substituted = text.replacingOccurrences(of: "#", with: String(pageNo))
                let runs = nativeHeadFootRuns(substituted)
                let result = NSMutableAttributedString()
                for run in runs {
                    let runText = nativeStripControlChars(run.text)
                    guard !runText.isEmpty else { continue }
                    let runFont = Self.styled(lineFont, with: run.styles.union(lineStyle))
                    result.append(NSAttributedString(string: runText, attributes: [
                        .font: runFont,
                        .foregroundColor: NSColor.black,
                        .kern: nativeCourierPitchKern(runFont),
                        .ligature: nativeNoLigatures,
                    ]))
                }
                if result.length > 0 {
                    // Measured on the line itself: an italic or bold Courier Prime sets its
                    // first baseline lower in a `draw(at:)` than the roman face does, and the
                    // roman measure put -README's italic head 2 pt below the engine's.
                    return RunningLine(text: result, baselineFromTop: baseline,
                                       drawOriginOffset: Self.isolatedFragmentK(
                                           result, width: max(1, metrics.pageWidth - metrics.left)),
                                       kind: kind, pageLeftOffset: pageLeftOffset)
                }
                // Nothing left once the toggles are consumed (LJ6DTP.WS's own footer is two
                // rule-drawing control bytes and no visible text at all) — a running line
                // with nothing to show is exactly one that should not exist.
                return nil
            }
            let degraded = rendered(text)
            guard !degraded.isEmpty else { return nil }
            // No `.paragraphStyle` attribute — matches `drawOriginOffset`'s own measurement,
            // which uses the same absence (`NSParagraphStyle()`, unconstrained) rather than
            // the body text's lead-pinned style; a running line is drawn at its own natural
            // single-line height, never clamped to the document's `.lead` grid.
            // Batch 41: a styled line leaves the engine's fast path for its run path, in the same
            // Courier with the line's own bold/italic — the face `Self.styled` gives here.
            let attributed = NSAttributedString(string: degraded, attributes: [
                .font: lineStyle.isEmpty ? lineFont : Self.styled(lineFont, with: lineStyle),
                .foregroundColor: NSColor.black,
                .kern: nativeCourierPitchKern(lineStyle.isEmpty ? lineFont : Self.styled(lineFont, with: lineStyle)),
                .ligature: nativeNoLigatures,
            ])
            return RunningLine(text: attributed, baselineFromTop: baseline,
                               drawOriginOffset: lineStyle.isEmpty ? lineOriginOffset : Self.isolatedFragmentK(
                                   attributed, width: max(1, metrics.pageWidth - metrics.left)),
                               kind: kind, pageLeftOffset: pageLeftOffset)
        }

        var out: [RunningLine] = []
        for resolved in headerLines {
            if let built = line(resolved, kind: .header) { out.append(built) }
        }
        for resolved in footerLines {
            if let built = line(resolved, kind: .footer) { out.append(built) }
        }
        if let auto = page.autoPageno {
            // Plain Courier, no font lookup — the engine emits the automatic number with its
            // own `FONTS[(False, False)]` fallback face rather than any `.f#` font block. Its
            // x is anchored ABSOLUTELY from the paper's left edge (`.po` plus `.pc`), not at
            // the text column every other running line starts from, which is exactly why the
            // model carries it per line rather than per page.
            let baseline = pageHeight - auto.y
            // E11: never a flagged row.
            if !auto.offSheet {
                // Planning #549 (WS4 teardown 4 §15.3): WS4's plain number prints in the install's normal width
                // whatever `.CW` says (`AutoPageNumber.size`), as Printed draws it.
                let autoFont = auto.size.map { courierPrime(size: CGFloat($0)) } ?? font
                let attributed = NSAttributedString(string: auto.text, attributes: [
                    .font: autoFont,
                    .foregroundColor: NSColor.black,
                    .kern: nativeCourierPitchKern(autoFont),
                    .ligature: nativeNoLigatures,
                ])
                out.append(RunningLine(
                    text: attributed, baselineFromTop: baseline,
                    drawOriginOffset: auto.size == nil ? drawOriginOffset : Double(firstBaselineOffset(
                        font: autoFont, paragraph: NSParagraphStyle(),
                        width: max(1, metrics.pageWidth - metrics.left))),
                    kind: .footer,
                    pageLeftOffset: auto.x - leftAnchor))
            }
        }
        return out
    }

    /// Modern's own per-page running head/foot geometry (job 393, 391 root cause 2) — the
    /// app-side analog of `runningLines(for:pageNo:doc:metrics:)` above, but resolved from
    /// `HFEvent`s replayed against a REAL AppKit page boundary rather than an engine `Page`,
    /// because Modern's own page breaks are not known until `PagedDocumentView` lays the flow
    /// out (`RenderedDocument.hfEvents`'s own doc comment). `PagedDocumentView` calls this
    /// once per real page, passing that page's own first character offset — everything before
    /// it (`event.charOffset <= offset`) is "in force," mirroring `modernStreams`'s own
    /// `openPage()`: the state a page opens with is whatever was true when it took its first
    /// content, and a later `.hf` on that SAME page (after `offset`) does not apply until the
    /// next one.
    ///
    /// Placement matches `PDFModernLayout.swift`'s own `modernStreams` exactly: Times at its
    /// `modernNotePt` (11 — internal to the engine module, so vendored here as a literal, same
    /// "cite the source line, don't import the constant" discipline `runningLines` above
    /// already follows for its own Printed literals), header lines walking down from 44pt off
    /// the top edge, footer lines up from 44pt off the bottom (floored at 8pt so a document
    /// with many footer lines can't push one off the page) — `PDFModernLayout.swift:518-532`.
    /// Batch 41 (C): WordStar's automatic page number as the engine's Modern PDF draws it on this page
    /// (`ModernPageFurniture.autoPageNumber`) — `nil` when the page is not numbered at all, which the engine
    /// already decides for the app (`.op`, a footer in use, or page numbers off), so there is no second copy of
    /// that rule here.
    ///
    /// Placed the MODERN way, per M15 (Jon's ruling 2026-09-15), which the engine states on the accessor itself:
    /// "centred in Modern's own measure on the row a Modern footer line 1 rides, never Printed's `.pc` column or
    /// its `pl - mb + fm` row". So the x is the engine's own, carried as a `pageLeftOffset` from the text frame's
    /// left edge exactly as `drawRunningLines` expects, and nothing is re-derived here.
    ///
    /// Times at the engine's own `modernNotePt` (11, `PDFModernLayout.swift:20` — vendored as a literal, the same
    /// "cite the source line, don't import the constant" discipline the replay below already follows). `.kern` and
    /// `.ligature` off, matching the Printed automatic number's own attributes.
    /// Batch 41 (F): the running heads and feet the engine's Modern PDF draws on this page, taken from its own
    /// furniture instead of replayed from `HFEvent`s against a guessed row.
    ///
    /// Each line arrives placed — `x` with its alignment ALREADY applied (`modernPlaceLine`), `y` a baseline up
    /// from the sheet's foot — so nothing here re-derives a column or a row, and a centred head needs no second
    /// copy of the centring rule. The face and size come off the line too (`family`, `pt`): the engine writes
    /// Times at `modernNotePt` today and says so outright, but it reports both per line "so a caller never has to
    /// know that", and taking them is what keeps this right if it ever varies.
    ///
    /// WordStar's inline toggle bytes are still in `text`, exactly as the Printed side keeps them, so the line is
    /// split into runs and each run styled — the same treatment `runningLines(for:pageNo:doc:metrics:)` gives a
    /// fontless toggled line.
    ///
    /// AN INK-LESS LINE IS NEVER REPORTED. The engine drops a head or foot whose tokens come out empty
    /// (`toks.isEmpty` → `nil`), so a `.f1` that is nothing but print-control bytes stops drawing the blank
    /// `"  "` the replay used to put on every page of REF/BOOKLET.WS. That judgement is the engine's now, not a
    /// rule this file keeps its own copy of.
    /// Batch 48 (E10): the furniture face for a Modern render — `bodyFallback` (the face a fontless body run reads in)
    /// at `bodySize` less 2 pt, the engine's `modernNotePt = modernBodyPt - 2` — and the font records the document's head
    /// and foot lines open.
    public static func modernFurnitureFonts(_ doc: Document, bodyFallback: NSFont, bodySize: CGFloat)
        -> (font: NSFont, headers: [Int: FontChange], footers: [Int: FontChange]) {
        let size = max(1, bodySize - 2)
        let font = fontResized(bodyFallback, to: size) ?? bodyFallback
        func records(_ table: [Int: Int]) -> [Int: FontChange] {
            table.compactMapValues { doc.fonts.indices.contains($0) ? doc.fonts[$0] : nil }
        }
        return (font, records(doc.headerFonts), records(doc.footerFonts))
    }

    public static func modernFurnitureRunningLines(
        furniture: ModernPageFurniture, textLeft: Double, rendered: RenderedDocument? = nil
    ) -> [RunningLine] {
        func built(_ line: ModernHeadFootLine, kind: RunningLine.Kind) -> RunningLine? {
            let size = CGFloat(line.pt)
            var base: NSFont
            switch line.family {
            case .courier: base = NSFont(name: "Courier New", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case .helvetica: base = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
            default: base = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
            }
            // E10: the line's own declared font when its `.h#`/`.f#` opens one, else the body's fontless face at the
            // body size less 2 pt — the chain a body run takes, as the engine now resolves it (`family`/`pt`).
            if let rendered, let furnitureFont = rendered.modernFurnitureFont {
                let records = kind == .header ? rendered.modernHeaderFonts : rendered.modernFooterFonts
                if let entry = records[line.line] {
                    base = Self.resolvedFont(for: entry, styles: [], fallback: furnitureFont,
                                             defaultSize: Int(furnitureFont.pointSize.rounded()), useCourierPrime: true)
                } else {
                    base = furnitureFont
                }
            }
            let result = NSMutableAttributedString()
            for run in nativeHeadFootRuns(line.text) {
                let visible = nativeStripControlChars(run.text)
                guard !visible.isEmpty else { continue }
                result.append(NSAttributedString(string: visible, attributes: [
                    .font: run.styles.isEmpty ? base : Self.styled(base, with: run.styles),
                    .foregroundColor: NSColor.black,
                    .kern: nativeNoKerning,
                    .ligature: nativeNoLigatures,
                ]))
            }
            guard result.length > 0 else { return nil }
            let drawOriginOffset = Double(firstBaselineOffset(
                font: base, paragraph: NSParagraphStyle(), width: 500))
            return RunningLine(text: result, baselineFromTop: furniture.sheetHeight - line.y,
                               drawOriginOffset: drawOriginOffset, kind: kind,
                               pageLeftOffset: line.x - textLeft)
        }
        var out: [RunningLine] = []
        for head in furniture.headers {
            if let line = built(head, kind: .header) { out.append(line) }
        }
        for foot in furniture.footers {
            if let line = built(foot, kind: .footer) { out.append(line) }
        }
        return out
    }

    public static func modernAutoPageNumberLine(
        furniture: ModernPageFurniture, textLeft: Double, rendered: RenderedDocument? = nil
    ) -> RunningLine? {
        guard let auto = furniture.autoPageNumber else { return nil }
        // E10: the body's fontless face at the body size less 2 pt, as the engine's Modern number now is.
        let font = rendered?.modernFurnitureFont
            ?? NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let text = nativeStripControlChars(auto.text)
        guard !text.isEmpty else { return nil }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: nativeNoKerning,
            .ligature: nativeNoLigatures,
        ])
        let drawOriginOffset = Double(firstBaselineOffset(
            font: font, paragraph: NSParagraphStyle(), width: 500))
        // The furniture's `y` is a baseline up from the sheet's foot; a `RunningLine` is positioned from its top.
        return RunningLine(text: attributed, baselineFromTop: furniture.sheetHeight - auto.y,
                           drawOriginOffset: drawOriginOffset, kind: .autoPageNumber,
                           pageLeftOffset: auto.x - textLeft)
    }

    public static func modernRunningLines(
        events: [HFEvent], upToOffset offset: Int, pageNo: Int, pageHeight: Double, font furnitureFont: NSFont? = nil
    ) -> [RunningLine] {
        var headers: [Int: String] = [:]
        var footers: [Int: String] = [:]
        for event in events where event.charOffset <= offset {
            if event.kind == .header { headers[event.line] = event.text } else { footers[event.line] = event.text }
        }
        guard !(headers.isEmpty && footers.isEmpty) else { return [] }

        // E10: the body's fontless face at the body size less 2 pt when the render says so.
        let font = furnitureFont ?? NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let size = font.pointSize
        let noteLead = 1.2 * Double(size)
        let drawOriginOffset = Double(firstBaselineOffset(
            font: font, paragraph: NSParagraphStyle(), width: 500))

        // `∙` IS A MIDDLE DOT IN A RUNNING HEAD. The library's writer substitutes it outright —
        // `esc(txt.replacingAll("\u{2219}", with: "\u{00B7}"))` (`PDFWriter.swift`): cp1252 has no
        // BULLET OPERATOR, and the middle dot is the small dot the printer prints for the
        // document's F9 (LJ6DTP.WS's `.h1`, on the LaserJet scan and in WS7's capture), so the
        // app's head reads as the library's does on every page.
        func rendered(_ text: String) -> String {
            nativeStripControlChars(
                text.replacingOccurrences(of: "#", with: String(pageNo))
                    .replacingOccurrences(of: "\u{2219}", with: "\u{00B7}"))
        }
        func line(_ text: String, baselineFromTop: Double, kind: RunningLine.Kind) -> RunningLine? {
            let degraded = rendered(text)
            guard !degraded.isEmpty else { return nil }
            let attributed = NSAttributedString(string: degraded, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
            return RunningLine(text: attributed, baselineFromTop: baselineFromTop,
                               drawOriginOffset: drawOriginOffset, kind: kind)
        }

        var out: [RunningLine] = []
        for n in headers.keys.sorted() {
            guard let text = headers[n] else { continue }
            if let built = line(text, baselineFromTop: 44.0 + Double(n - 1) * noteLead, kind: .header) {
                out.append(built)
            }
        }
        for n in footers.keys.sorted() {
            guard let text = footers[n] else { continue }
            let fromBottom = max(8.0, 44.0 - Double(n - 1) * noteLead)
            if let built = line(text, baselineFromTop: pageHeight - fromBottom, kind: .footer) {
                out.append(built)
            }
        }
        return out
    }
}
