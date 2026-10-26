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

    /// MECHANISMS Q and X (engine commits 6d12d7e and 53d3114, mirroring ctrl-kd 605e27b /
    /// 1017391 / e989028): re-evaluate a `.h#`/`.f#` line's own right-align tab against THIS
    /// page's actual page-number width.
    ///
    /// A right/center/decimal-align tab typed into a running-head argument has its padding
    /// BAKED to literal spaces at parse time, sized for whatever the `#` substitution was
    /// assumed to be wide when the file was last saved — always one column, because
    /// WordStar's own screen shows the literal `#` token, never the eventual number. Real
    /// WS7 re-evaluates the tab at PRINT time instead: measured on -README.WS pages 9->10,
    /// the header's "WordStar" moves 7.2pt LEFT the instant the page number grows a second
    /// digit, while the number's own right edge — the tab's real target column — never moves.
    ///
    /// `absHMI` is where the BAKED padding ends, in 1/1800in units from the document's own
    /// left reference, so it already encodes `targetCol - savedSuffixWidth` at the saved
    /// (1-digit) width. Adding the stored suffix's own width back recovers `targetCol`;
    /// subtracting THIS page's actual substituted suffix width gives the padding to use now.
    ///
    /// MECHANISM X is the `- 1` that is NOT here. That bias was fit against the 2-digit case
    /// while -README's header was still 24pt too low (mechanism W's own bug), which masked
    /// every horizontal residual behind a much larger vertical one. With W fixed, the
    /// pristine capture showed both digit-width buckets uniformly one column left of the
    /// biased formula: WS7's suffix-final print column is INCLUSIVE of the tab's target.
    ///
    /// Fixed-pitch only (`entry == nil`), exactly like the engine: a proportional header face
    /// has no single column width to divide the HMI target by, and no oracle in the corpus
    /// combines the two, so that case keeps its baked padding untouched.
    static func nativeHFRetab(_ text: String, tabRec: HFTabMark?,
                                       substituting render: (String) -> String) -> String {
        guard let tabRec else { return text }
        let chars = Array(text)
        let charIdx = tabRec.charIdx
        let cols = tabRec.cols
        guard charIdx >= 0, charIdx + cols <= chars.count else { return text }
        let suffix = String(chars[(charIdx + cols)...])
        let strippedSuffix = String(String.UnicodeScalarView(
            suffix.unicodeScalars.filter { $0.value >= 0x20 }))
        // `tabHMIPerCol` is 180 (`SymmetricBlocks.swift`) — a WordStar file-format constant,
        // vendored like this function's other spec literals. Banker's rounding matches the
        // engine's own `roundHalfToEven` at the exact .5 cases this division produces.
        let savedTargetCol = nativeRoundHalfToEven(Double(tabRec.absHMI) / 180.0)
            + strippedSuffix.count
        let newCols = max(0, savedTargetCol - render(strippedSuffix).count)
        return String(chars[0..<charIdx]) + String(repeating: " ", count: newCols) + suffix
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
        // `∙` IS A BULLET HERE TOO — the PRINTED twin of the Modern substitution. The
        // engine's `runningOps` does it unconditionally on a running head's own text
        // ("`∙` (U+2219 BULLET OPERATOR) -> `•` (U+2022 BULLET), because cp1252 carries a real
        // BULLET"), and this path applied `nativeStripControlChars` alone. Measured on
        // LJ6DTP.WS, whose `.h1` carries the extended character 0xF9: the app drew the
        // narrower BULLET OPERATOR, so everything after it in the head sat left of the
        // engine's — a region-diff row on the head band of all eight pages, and the page
        // number's own cell empty where the engine has ink.
        func rendered(_ text: String) -> String {
            nativeStripControlChars(text)
        }
        let font = courier(size: CGFloat(metrics.size))
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
        func styledLine(_ rawText: String, entry: FontChange, lineStyle: Style) -> (text: NSAttributedString, leadingOffset: Double, drawOriginOffset: Double)? {
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
                                           defaultSize: metrics.size, useCourierPrime: true)
                result.append(NSAttributedString(string: text, attributes: [
                    .font: runFont, .foregroundColor: NSColor.black,
                    .kern: nativeNoKerning,
                    .ligature: nativeNoLigatures,
                ]))
            }
            guard result.length > 0 else { return nil }
            let resolvedBase = resolvedFont(for: entry, styles: [], fallback: font,
                                            defaultSize: metrics.size, useCourierPrime: true)
            let originOffset = Double(firstBaselineOffset(
                font: resolvedBase, paragraph: NSParagraphStyle(),
                width: max(1, metrics.pageWidth - metrics.left)))
            return (result, leadingOffset, originOffset)
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
            if let entry, let styled = styledLine(text, entry: entry, lineStyle: lineStyle) {
                return RunningLine(text: styled.text, baselineFromTop: baseline,
                                   drawOriginOffset: styled.drawOriginOffset, kind: kind,
                                   leadingOffset: styled.leadingOffset,
                                   pageLeftOffset: pageLeftOffset)
            }
            // Mechanisms Q/X — see `nativeHFRetab`. Gated on `entry == nil` to mirror the
            // engine exactly: a line that HAS a font block keeps its baked padding even when
            // its styled path declined to build (the engine never reaches its retab branch
            // for such a line either).
            // Mechanisms Q/X — `nativeHFRetab`'s own realignment is BAKED INTO
            // `HeadFootLine.text` by `resolveHeadFootLines`, so there is nothing left to do
            // here and no second copy of the rule to keep in step.
            let retabbed = text
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
            if entry == nil, retabbed.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                let substituted = retabbed.replacingOccurrences(of: "#", with: String(pageNo))
                let runs = nativeHeadFootRuns(substituted)
                let result = NSMutableAttributedString()
                for run in runs {
                    let runText = nativeStripControlChars(run.text)
                    guard !runText.isEmpty else { continue }
                    let runFont = Self.styled(font, with: run.styles.union(lineStyle))
                    result.append(NSAttributedString(string: runText, attributes: [
                        .font: runFont,
                        .foregroundColor: NSColor.black,
                        .kern: nativeNoKerning,
                        .ligature: nativeNoLigatures,
                    ]))
                }
                if result.length > 0 {
                    return RunningLine(text: result, baselineFromTop: baseline,
                                       drawOriginOffset: drawOriginOffset, kind: kind,
                                       pageLeftOffset: pageLeftOffset)
                }
                // Nothing left once the toggles are consumed (LJ6DTP.WS's own footer is two
                // rule-drawing control bytes and no visible text at all) — a running line
                // with nothing to show is exactly one that should not exist.
                return nil
            }
            let degraded = rendered(retabbed)
            guard !degraded.isEmpty else { return nil }
            // No `.paragraphStyle` attribute — matches `drawOriginOffset`'s own measurement,
            // which uses the same absence (`NSParagraphStyle()`, unconstrained) rather than
            // the body text's lead-pinned style; a running line is drawn at its own natural
            // single-line height, never clamped to the document's `.lead` grid.
            // Batch 41: a styled line leaves the engine's fast path for its run path, in the same
            // Courier with the line's own bold/italic — the face `Self.styled` gives here.
            let attributed = NSAttributedString(string: degraded, attributes: [
                .font: lineStyle.isEmpty ? font : Self.styled(font, with: lineStyle),
                .foregroundColor: NSColor.black,
                .kern: nativeNoKerning,
                .ligature: nativeNoLigatures,
            ])
            return RunningLine(text: attributed, baselineFromTop: baseline,
                               drawOriginOffset: drawOriginOffset, kind: kind,
                               pageLeftOffset: pageLeftOffset)
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
                let attributed = NSAttributedString(string: auto.text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .kern: nativeNoKerning,
                    .ligature: nativeNoLigatures,
                ])
                out.append(RunningLine(
                    text: attributed, baselineFromTop: baseline,
                    drawOriginOffset: drawOriginOffset, kind: .footer,
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

        // `∙` IS A BULLET IN MODERN. The library's writer substitutes it outright —
        // `esc(txt.replacingAll("\u{2219}", with: "\u{2022}"))` (`PDFWriter.swift`, Register
        // C9: "'•' (U+2022 BULLET — WordStar's own cp437 0x07 list marker)"), "because cp1252
        // carries a real BULLET" where it has no BULLET OPERATOR at all. Measured on
        // LJ6DTP.WS, whose `.h1` carries the extended character 0xF9: the library's running
        // head reads "LJ6DTP Desktop-Publishing PDF • 9" and the app's read "… · 9", on all
        // eleven pages.
        func rendered(_ text: String) -> String {
            nativeStripControlChars(
                text.replacingOccurrences(of: "#", with: String(pageNo))
                    .replacingOccurrences(of: "\u{2219}", with: "\u{2022}"))
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
