#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Modern

    /// Reflow for reading: fixed 1in margins on the app's page, the user's font and size —
    /// but the document's OWN font identity and paragraph structure, not one flat body font
    /// (job 263, Jon's field report: OLDTIMES's title/author/citations were all falling
    /// back to plain body text with only char-level bold/italic surviving).
    ///
    /// Modern deliberately does NOT reproduce the original page — that is Printed's job.
    /// AppKit does the wrapping here (that is the point), so lines are logical, not
    /// physical: `modernSemanticFlow` (`CtrlKD/Layout.swift`) has ALREADY undone WordStar's
    /// own word wrap, editor-time alignment spaces and `.lm`/`.rm` margin stamping — it is
    /// the engine's own words "the single implementation of the M-rules", the SAME model
    /// `PDFModernLayout.swift` (PDF), `EmitRTF.swift`, and `EmitHTML.swift` measure into
    /// their own surfaces. This function is the app's fourth consumer: convert the shared
    /// semantic items straight to AppKit paragraph/font attributes, never re-derive
    /// alignment/indent/style structure from `doc.blocks` by hand the way the flat
    /// `mergedLines`-only version this replaced did.
    ///
    /// ## Font identity, size hierarchy, and the body/heading reconciliation rule
    ///
    /// A run carrying a WS5+ font block (`SemanticRun.font`, non-`nil`) resolves through
    /// `resolvedFont`/`nativeResolvedMacFont` below — the SAME MAC-target mapping table
    /// (`nativeMacFontRows`, mistake-registry #24, job 240's MAC VIEWING RULING) Printed
    /// already uses, e.g. OLDTIMES's Aachen title resolves to Rockwell, Univers to Helvetica
    /// Neue — at THAT run's own declared point size (`FontChange.points`), which is exactly
    /// the field `fontControlRTF` reads for the RTF stylesheet's `\fsNN`, so a styled run's
    /// size here matches the RTF export's by construction, not by copying a number. A run
    /// with NO font block (plain body prose) falls through `resolvedFont`'s own existing
    /// fallback to `bodyFont` — the user's Settings "Modern font/size"
    /// (`SettingsStore.defaultFontName`/`.fontSizes`, the Georgia-14-body ruling).
    ///
    /// The reconciliation: body copy renders in the user's chosen face/size; the document's
    /// own styled runs (title/byline/citation/quote/etc.) keep their ABSOLUTE face and size
    /// from the file's own structure — bold/larger/centered exactly as the RTF stylesheet
    /// has them — rather than being rescaled relative to whatever face the user picked for
    /// body text. This is `resolvedFont`'s pre-existing architecture (job 202/240, Printed)
    /// applied unchanged to Modern, not a new rule invented for this job.
    /// `.lm`/`.rm` block margins arrive as WordStar print COLUMNS (`SemanticItem.para`'s
    /// own contract); a modern column is the document's own `.cw` (default 12, 10 CPI)
    /// at 0.6pt/char — the SAME conversion `PDFModernLayout.modernFlow`'s `colPt` uses
    /// for the PDF Modern path, ported here since the module docstring's own contract is
    /// "each consumer converts with its own metrics" (columns are deliberately unitless
    /// in the shared model).
    static func modernColPt(_ doc: Document) -> Double {
        (doc.page?.cw120 ?? 12.0) * 0.6
    }

    /// b28 note 7 (Jon's ruling, verbatim): "The look of our notes in Modern: 1. Footnoote.
    /// and i. Endnote. No brackets. No superscript... The note marker in the text should
    /// still be superscript." This only reformats the trailing APPENDIX entry
    /// (`appendNoteLine`'s callers) — the in-text reference marker is a separate `SemanticRun`
    /// carrying its own `.sup` style bit, set upstream and rendered through `attributedLine`'s
    /// span processing, never touched here. `label`/`row.shown` (`shownLabels`,
    /// `Layout.swift`) are already bare (`"1"`, `"i"` via `endnoteRomanLabel`, `"c1"` for
    /// comments) with no trailing punctuation — the `hasSuffix` guard is defensive, so a
    /// future label scheme that already carries its own period never doubles it into `"1.."`.
    static func modernNoteEntryLabel(_ label: String) -> String {
        label.hasSuffix(".") ? label : label + "."
    }

    /// `hangCols`, when given, opens a HANGING indent (M-rules addendum, structure rows
    /// only): the first line sits at `indentCols`, every WRAPPED line at
    /// `indentCols + hangCols` — a def-list label or bullet marker is only ever on line
    /// one, so its continuation hangs under the body text instead of repeating under the
    /// marker. `nil` (every pre-existing caller) keeps first-line and wrapped lines at
    /// the SAME column, unchanged from before job 299.
    ///
    /// `hangPt`, when given, opens the SAME hanging indent but measured in real points
    /// past `indentCols` rather than WordStar print columns — job 329/b21, Jon's field
    /// note on VERSIONS.WS's Sawyer-customizations bullets: "the line wrap doesn't line
    /// up with the first line after the • bullet." `hangCols`' column-based math assumes
    /// a monospace cell (`colPt`, the document's own `.cw`), but a bullet's "• " marker
    /// renders in Modern's own PROPORTIONAL body font — its real advance width almost
    /// never lands on a whole number of `colPt`-wide cells, so the fixed `hangCols: 2`
    /// this used to pass drifted from the actual glyph. `hangPt` takes precedence over
    /// `hangCols` when both are given (no caller passes both).
    ///
    /// Shared by `renderModern` and `renderModernAnnotated` (job 300) — Show Invisibles
    /// must never compute its own paragraph geometry, or the two views can drift the way
    /// Jon's b16 field report caught (centering lost, ladder collapsed, when ON).
    /// Job 371 item 5 (VERSE SPACING IN VIEWS, RULINGS-LEDGER item 4): `EmitRTF`/`EmitHTML`
    /// both tighten a centered/verse-classified unit's own internal line spacing — "poetry
    /// and centered material... conventionally sets SINGLE-spaced internally regardless of
    /// the surrounding prose's own spacing" (`FontMap.swift`'s own citation).
    ///
    /// Job 395 (391 root cause 4) — THE FIX: job 371's predecessor here
    /// (`modernVerseLineHeight`, 1.15) was applied as `NSParagraphStyle.lineHeightMultiple`
    /// UNCHANGED from `EmitHTML.swift`'s own `line-height:1.15` — but that HTML number only
    /// reads as tight relative to CSS's own explicit, loose ambient (`htmlCSS`'s body
    /// shorthand `"14pt/1.6 Georgia..."` — 1.15 is tighter than THAT page's own 1.6
    /// default). AppKit's plain (non-tight) paragraph here sets NO line-height override at
    /// all (see below) — its own "1.0" baseline is already the tight, natural font-metric
    /// height, not a loose ambient the way HTML's page default is — so multiplying that
    /// ALREADY-tight AppKit baseline by 1.15 unchanged made verse ~15% TALLER than prose,
    /// precisely inverted (Jon's field report on 391: OLDTIMES's award blocks/stanzas
    /// "aren't any tighter"). Two absolute-geometry alternatives were tried and rejected
    /// empirically before this one: `NSParagraphStyle.minimumLineHeight` (RTF's own
    /// `\sl`-positive convention, `rtfVerseTightSlTwips`'s doc comment) is a FLOOR — it
    /// can only ever raise an already-small line, never tighten a bigger one, so it would
    /// be silently inert for ordinary body text. A fixed absolute `maximumLineHeight` PORT
    /// of `rtfVerseTightSlTwips()`'s own points (`verseLineHeight`(1.15) *
    /// `modernBodySize`(14) = 16.1pt, `FontMap.swift`/`EmitRTF.swift`) was ALSO measured
    /// inert: AppKit's own natural single-line height for the app's default Modern body
    /// font (Georgia 14, `SettingsStore.defaultFontName`/`.modernFontSize`) is ~16.0pt via
    /// `NSLayoutManager`'s real laid-out line fragments — already AT that ceiling, so it
    /// never engaged (measured directly building this fix; see
    /// `VerseSpacingInViewsTests.verseRendersTighterThanProseSameFontSize`, which is what
    /// caught it). The only mechanism that reliably tightens ANY font's line height below
    /// its own natural metric, unconditionally, is a RELATIVE multiplier below 1.0 — the
    /// SAME property (`lineHeightMultiple`) the predecessor fix already used, just with the
    /// CORRECT number: `EmitHTML.swift`'s own two explicit literals, ported as a RATIO
    /// rather than as HTML's absolute 1.15 alone — `verseLineHeight`(1.15) /
    /// htmlAmbientLineHeight(1.6) = 0.71875 — the cross-format law FontMap.swift's own
    /// comment already states ("HTML body: 1.6; RTF style/reader default is comparably
    /// loose"): verse reads tighter than the surrounding ambient by THIS ratio, in every
    /// consumer. AppKit's own natural (no-override) baseline plays HTML's "1.0-before-1.6"
    /// role here, so applying the SAME ratio directly against AppKit's own natural is the
    /// faithful translation — not a re-guess, both source numbers are pinned literal ports
    /// (same situation `DocumentPictures.resolve`'s own header explains for PIX resolution
    /// — CtrlKD's own constants are `internal`, no product to import them from).
    public static let modernVerseTightLineHeightMultiple: CGFloat = 0.71875

    /// The library's own Modern line-to-line advance as a multiple of type size —
    /// `PDFModernLayout.swift`'s `modernLine`, vendored because it is `internal` to CtrlKD,
    /// the same situation `DocumentPictures`' header explains for the pix constants. A pinned
    /// literal there, not derived arithmetic.
    /// WHICH MODERN ROWS REFUSE TO WRAP.
    ///
    /// A row of box-drawing or block characters is a picture, not a sentence: broken across
    /// two visual lines it stops being the thing it draws. That is why these rows clip.
    ///
    /// It used to be "wholly graphic OR carrying more than one graphic character", and the
    /// second half is too wide. The library wraps a MIXED row like any other — `modernWrap`
    /// has no clipping concept at all, and its tokens break at spaces exactly where AppKit's
    /// word wrapping would. Measured on LJ6DTP.WS's PDF character-substitution tables
    /// (pages 9-11), whose rows are `║Albertus Ital║ ... │4716│5529║` — real labels and real
    /// numbers between the rules, far wider than the measure: the library sets each of them
    /// as two lines and the app clipped each to one, so the app lost 26 lines and a whole
    /// page (10 against the library's 11).
    ///
    /// A WHOLLY graphic row still clips, and nothing about it changes: it has no space to
    /// break at, so the two readings were always the same answer for those rows.
    public static func modernClipsRow(_ spans: [Span]) -> Bool {
        if isWhollyGraphicRow(spans) { return true }
        // A ROW CARRYING MORE THAN ONE GRAPHIC CHARACTER, which is job 456's own rule and
        // Jon's own field report on it ("I don't understand what happened in Modern. They
        // have line returns in the middle"). I narrowed this to wholly-graphic rows while
        // chasing LJ6DTP.WS's character-substitution tables, which the library DOES wrap —
        // and that took BOXES.WS's "LL: └ LR: ┘ ... Joins: ... Mixed: ..." legend row to two
        // line fragments, which is the exact thing job 456 exists to prevent.
        //
        // The library's own wrapping of a table row and Jon's rule for a legend row disagree,
        // and the ruling stands: the app does not wrap either. LJ6DTP's tables are a #210
        // item ("LJ6DTP needs special attention because it's an interesting doc that pushes
        // the boundaries"), not a reason to drop a rule Jon asked for.
        // Stood down for the gate's run, like the ladder and the tightening before it — this
        // is the sixth app-only Modern rule the library has not been given. `modernWrap` has
        // no clipping concept at all and breaks LJ6DTP.WS's character-substitution tables at
        // their spaces; measured, the app's own rule is 3 rows of BOXES.WS and 74 of
        // LJ6DTP.WS against the library, and none of it is a defect in either.
        if hasMultipleGraphicChars(spans) { return true }
        // AND A ROW WITH NOWHERE TO BREAK. `modernWrap` breaks BETWEEN tokens and never
        // inside one, so a single token wider than the measure simply overflows it in the
        // library. AppKit's word wrapping has no such floor: asked to fit a word that cannot
        // fit, it breaks the word. Measured on SAWYER.WS, whose section rules are runs of
        // `=` a few characters wider than the measure — the app set each as a full line plus
        // a stub ("======" alone), four of them, and the library sets each as one line.
        let text = spans.map(\.text).joined()
        return !text.isEmpty && !text.contains(" ")
    }

    /// MEASURE A DECLARED FACE THE WAY THE LIBRARY MUST — a comparison pin, never a product
    /// behaviour, and off in every path but the one gate that sets it.
    ///
    /// Jon's ruling 2026-09-11: the app KEEPS drawing a document's own declared typeface in
    /// Modern (a font block naming Garamond reads in Hoefler Text, the nearest Mac face), and
    /// the engines will NOT embed fonts — their Modern PDF can only set base-14. Neither
    /// product changes. What has to change is the COMPARISON: two renderers setting the same
    /// paragraph in two different faces break their lines in different places for a reason
    /// that is nobody's defect, and every other rule in `AppModernFidelityTests` was being
    /// judged through that noise.
    ///
    /// Measured on one LYING.WS line, which declares Garamond: the library sets it in
    /// Times-Roman stretched to 104.81% and reaches 425.76pt; the app sets it in Hoefler Text
    /// at 101.43% and reaches 434.05pt, so the app wraps a word earlier — on every line of
    /// LYING.WS and WARPRAYR.WS, 429 of the twelve documents' remaining distance.
    ///
    /// With the pin on, a run whose font block names a face resolves to the Mac face that is
    /// metric-compatible with the base-14 family `pdfFamily` would select for it
    /// (`modernBase14MacFont`). Everything else — the stretch, the cell, the leading, the
    /// wrap — is unchanged, so what the gate then measures is those rules and not the faces.
    ///
    /// `AppModernFidelityTests` is the only writer, its suite is `.serialized`, and it clears
    /// the flag when it is done.
    @MainActor public static var modernBase14MeasurementPin = false

    /// LAY MODERN OUT THE WAY TODAY'S ENGINES DO — the second comparison pin, and like the
    /// face pin above it is a measurement device, never a product behaviour.
    ///
    /// Jon ruled 2026-09-11 that Modern's verse/centre line-height tightening AND its def-row
    /// hanging label and indent ladder both STAY in the app, and that both get backported to
    /// the two engines. Until the engines carry them, a gate comparing the app's Modern PDF
    /// to the library's is measuring two features the library has not been given yet — and
    /// every OTHER rule in that comparison is invisible behind them. Measured: the tightening
    /// alone is 213 of the twelve documents' distance and the ladder most of VERSIONS' 239.
    ///
    /// With this set, and only with it set, the three mechanisms named in the ruling stand
    /// down for the duration of a gate run:
    ///   - the tightening, at BOTH its call sites (a centred structured row's own
    ///     unconditional `tight: true`, and the plain paragraph's
    ///     `tight: align == .center || isVerse`);
    ///   - job 434's leading spacer, which exists only because a tightened line's ink rises
    ///     above its compressed box and therefore has nothing to do once nothing is tightened;
    ///   - the ladder and the hang, so a def/bullet row takes the row's OWN declared indent
    ///     and no hanging indent at all, which is what `modernFlow` does today.
    ///
    /// It comes out the day both engines carry the two features. Written only by
    /// `AppModernFidelityTests`, whose suite is `.serialized` and which clears it on the way
    /// out; nothing in the app's own rendering ever sets it.

    /// The library's own Modern body size, `modernBodyPt` — `internal` to CtrlKD, vendored
    /// the way `AppModernFidelityTests` vendors it and for the same reason: a pinned literal,
    /// not derived arithmetic. `.cp` asks for room in units of it.
    public static let modernLibraryBodyPt: CGFloat = 14

    public static let modernLibraryLineFactor: CGFloat = 1.2

    /// `faceTz`'s own reference string (`PDFDriverLJ6DTP.swift`, `private` there): the
    /// lowercase alphabet plus a space, whose mean advance in the face stands for "how wide
    /// this face naturally sets" when a font block's declared cell is compared against it.
    /// Copied rather than imported for the reason `AppModernFidelityTests` copies
    /// `modernBodyPt` — it is a pinned literal, not derived arithmetic, so it carries no
    /// drift risk.
    public static let modernTzReference = "abcdefghijklmnopqrstuvwxyz "

    /// What both Modern renders, plain and Show Invisibles, take from the document and the reader's Modern settings,
    /// the same way.
    struct ModernBasis {
        let size: CGFloat
        let bodyFont: NSFont
        let fallbackFont: NSFont
        let fontlessFamily: CtrlKD.PDFFamily
        let colPt: Double
        let printedPt: Int
        let noteFont: NSFont
        let noteParagraph: NSParagraphStyle
    }

    static func modernBasis(_ state: DocumentState) -> ModernBasis {
        let doc = state.document
        let size = CGFloat(state.modernFontSize)
        let bodyFont = NSFont(name: state.modernFontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        // WHAT A RUN NO FONT BLOCK COVERS READS IN — Jon's ruling, 2026-09-09.
        //
        // "A document that declares fonts but does not have a font block AND doesn't
        // declare font proportionality, is Times in Modern in ctrl-kd and sr, and Georgia
        // 14 (or whatever is set in Settings). There's a setting in WS where it can declare
        // that fonts are not proportional. If that's the case, and no font block exists,
        // then it becomes Courier (or Courier Prime in macOS)."
        //
        // So the question is not whether the document declares fonts SOMEWHERE — job 437
        // read it that way, and any file carrying a single WS5+ font block then put every
        // uncovered run into Courier. That is the opposite of what the library does with
        // the same run: `PDFModernLayout`'s own rule is "a token with NO font information
        // reads in Times at the sophisticated size, never Courier — the typescript
        // aesthetic lives only in Printed now". Measured against the library's own Modern
        // PDF, job 437's reading was 1182 of the app's remaining distance in a single line.
        //
        // The question is whether the document declares its type NON-PROPORTIONAL. That is
        // `.ps off` (`Formatting.proportional`, WordStar's own document-level proportional-
        // spacing switch) — a positive statement about the type, not the absence of one,
        // and the only case where a typescript face is what the author asked for. The
        // engine takes the same reading (issue #252).
        //
        // `proportional == nil` — the file never mentioned it — is the no-information case
        // and keeps the reader's own face, which is what `ModernViewerStyleTests
        // .fontlessDocumentUsesTheUsersModernSettings` pins. A run a font block DOES cover
        // is untouched by any of this: it reads in its own declared face, including the
        // Courier a block flagged fixed-pitch asks for
        // (`fixedPitchDeclarationRendersCourierPrimeInModern`).
        let modernFallbackFont = doc.formatting.proportional == false
            ? Self.courierPrime(size: size) : bodyFont
        // THE FACE THE LIBRARY MEASURES A FONTLESS MODERN RUN IN — `modernTokFont`'s own
        // rule, which is NOT `pdfFamily`'s: `pdfFamily(nil)` is Courier, the PRINTED
        // emitter's answer for a document that never declared a font, while Modern reads a
        // token with no font block of its own in TIMES (its default body face) unless the
        // document turned proportional printing off, in which case Courier. Carried to
        // `attributedRun`, which stamps each run with the base-14 name the leading spacer
        // then measures — see `NSAttributedString.Key.modernBase14`. Getting this wrong is
        // not cosmetic: measured on -README.WS, a wholly fontless file, every title line was
        // measured in Courier's ink extents against a Times line box and reserved 2.2pt of
        // headroom where the library reserved 3.6.
        let modernFontlessFamily: CtrlKD.PDFFamily =
            doc.formatting.proportional == false ? .courier : .times
        let colPt = Self.modernColPt(doc)
        // E10 (engine 8b4862f): note text is furniture — the body's fontless face at the body size less 2 pt
        // (`modernNotePt = modernBodyPt - 2`), Courier Prime under `.ps off` as the body is.
        let noteSize = max(1, size - 2)
        let noteFont = fontResized(modernFallbackFont, to: noteSize)
            ?? NSFont.systemFont(ofSize: noteSize)
        let noteParagraph = Self.modernParagraphStyle(
            colPt: colPt, size: noteSize, align: .left, indentCols: 0, cutCols: 0)
        return ModernBasis(size: size, bodyFont: bodyFont, fallbackFont: modernFallbackFont,
                           fontlessFamily: modernFontlessFamily, colPt: colPt, printedPt: printedSize(doc),
                           noteFont: noteFont, noteParagraph: noteParagraph)
    }

    /// b34 N1 (job 529): note and footnote text collapsed the way the engine's `modernFlow` collapses it
    /// (`PDFModernLayout.swift`, `sentenceSpacingTexts([text])[0]`). Every note row both Modern renders read comes
    /// from `flow.notes`, so changing it once, here, keeps them all in step.
    static func modernCollapseNoteSpacing(_ flow: inout SemanticFlow) {
        flow.notes = flow.notes.map { row in
            var row = row
            row.text = sentenceSpacingTexts([row.text])[0]
            return row
        }
    }

    /// One line of the notes appendix or of a page-foot footnote block, with its own terminator. Black: the page is
    /// always white paper (job 478 — `.textColor` went white, and invisible, in Dark Mode).
    static func modernNoteLine(_ text: String, font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.black,
        ])
        result.append(lineTerminator(font: font, paragraph: paragraph))
        return result
    }

    static func modernParagraphStyle(
        colPt: Double, size: CGFloat, align: Alignment, indentCols: Double, cutCols: Double,
        hangCols: Double? = nil, hangPt: Double? = nil, tight: Bool = false,
        tightFamily: CtrlKD.PDFFamily = .times
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // NO PARAGRAPH AIR (planning #222 (a), Jon's option B). This used to add
        // `size * 0.35` between paragraphs — a constant that was this app's own, never the
        // library's: neither the engine's RTF stylesheet nor its semantic flow defines a
        // space-before figure, and `PDFModernLayout`'s own paginator advances by
        // `modernLine * pt` and nothing else.
        //
        // It was defensible while Modern was only ever a reading view answerable to nobody.
        // Option B makes the Modern VIEW answerable to the library's Modern PDF, and air the
        // library does not add is exactly the kind of thing that fills a page early and moves
        // every page break after it. `AppModernFidelityTests` is what now measures that.
        paragraph.alignment = modernNSAlignment(align)
        // `tight`: the SAME condition's centered half `EmitRTF.swift`/`EmitHTML.swift`
        // check (`isVerse || block.align == .center`) — every centered paragraph (a
        // detected/tagged centered row, OR an explicit `.oc` block) tightens here.
        // b24 completion (C1): the non-centered "verse" half is no longer a gap —
        // `modernSemanticFlow`'s `SemanticItem.para` now carries the engine's own
        // `isVerse` verdict per line (`Layout.swift`, computed with the SAME
        // `assembleParagraphUnits`/`looksLikeVerse` formula `EmitRTF`/`EmitHTML` use),
        // so this function's plain-paragraph caller passes it straight through instead
        // of re-deriving paragraph units itself — the shared-API discipline
        // `resolveFont` already established, not a reimplementation.
        // A plain (non-tight) paragraph sets no override at all here — its baseline IS
        // AppKit's own natural font-metric line height, not a silent guess. `tight`
        // multiplies THAT baseline down (never up — see `modernVerseTightLineHeightMultiple`'s
        // own doc comment for why a floor/ceiling against an absolute point value can't
        // reliably tighten here the way a relative multiplier does).
        if tight {
            paragraph.lineHeightMultiple = modernVerseTightLineHeightMultiple
            // AND PINNED, for the reason the `else` branch below already states about
            // ordinary leading: a multiplier is relative to whatever AppKit reports as the
            // face's natural metric, and the library's figure is absolute. When that comment
            // was written the library had no tightened line to match ("the library's Modern
            // PDF has no verse variation of its own to match"); since planning #263 it has
            // one, `modernTightHeight` — the same `modernVerseTight` ratio against the same
            // natural-height table — so the two producers now pin to one number instead of
            // agreeing by luck.
            //
            // Measured on -README.WS before this: AppKit's own natural height for Times New
            // Roman 14 is 16.0pt with the face's external leading and 15.0 without it, and
            // Modern turns that leading OFF (`PagedDocumentView`: `usesFontLeading =
            // clipsLines`). So every tightened line here measured 10.78pt against the
            // library's 11.50 — 0.72pt a line, which by page 4 of that file was a whole
            // line's worth of drift and a page break in the wrong place. The multiple is
            // KEPT alongside the clamp: it is what everything downstream reads as "this
            // paragraph is tight" (`modernLeadingSpacer`, `modernLineWraps`' job 437
            // back-off, `VerseSpacingInViewsTests`), and it states the ratio.
            let tightLeading = CGFloat(CtrlKD.modernTightHeight(tightFamily,
                                                                Int(size.rounded())))
            paragraph.minimumLineHeight = tightLeading
            paragraph.maximumLineHeight = tightLeading
        } else {
            // LEADING IS THE LIBRARY'S, NOT AppKit's (planning #222 (b), Jon's option B).
            // `PDFModernLayout`'s own advance is `modernLine * pt` — 1.2x the line's type
            // size — and it says so outright ("Modern's own line-to-line advance is exactly
            // modernLine * pt"). AppKit's natural line height for a face is its own metric,
            // near 1.14x for Times at 14pt, so the app fitted MORE lines on a page than the
            // library does and its page breaks fell late.
            //
            // Pinned as an absolute min == max rather than a multiplier, for the reason
            // `modernVerseTightLineHeightMultiple`'s own doc comment records at length: a
            // multiplier is relative to whatever the face's natural metric happens to be, so
            // the same number means different leading in different fonts, and the library's
            // is an absolute figure derived from the type size alone.
            //
            // `tight` is deliberately untouched. Verse tightening is a separate ruling
            // (b24 C1) about how verse READS, not part of option B's list, and the library's
            // Modern PDF has no verse variation of its own to match — so reversing it here
            // would be a silent change to something nobody asked about.
            let leading = size * modernLibraryLineFactor
            paragraph.minimumLineHeight = leading
            paragraph.maximumLineHeight = leading
        }
        let firstIndent = indentCols * colPt
        let hangIndent: Double
        if let hangPt {
            hangIndent = firstIndent + hangPt
        } else {
            hangIndent = hangCols.map { (indentCols + $0) * colPt } ?? firstIndent
        }
        if firstIndent > 0 || hangIndent > 0 {
            // Applies to every wrapped line of the paragraph, not just its first —
            // WordStar's `.lm` indents the whole block uniformly (the double-indent
            // quote styles this job's brief names), unlike a prose first-line indent.
            paragraph.firstLineHeadIndent = firstIndent
            paragraph.headIndent = hangIndent
        }
        let cut = cutCols * colPt
        if cut > 0 { paragraph.tailIndent = -cut }
        return paragraph
    }

    /// b27 item 8: a box-drawing/cp437-graphic row must never offer AppKit's word-wrap a
    /// break INSIDE it, or the row's borders tear onto separate visual lines (Jon's field
    /// report on `BOXES.WS`'s first box in Modern — "open top-right corner, a stray
    /// interior vertical, missing right side"). Reproduced directly: at Modern's real
    /// 468pt text width, `BOXES.WS`'s plain 80-column border row (`┌────...────┐`, NO
    /// space characters anywhere in it) still split into 2 line fragments — AppKit's own
    /// line-breaker allows a break directly BETWEEN two adjacent box-drawing glyphs, not
    /// only at whitespace (confirmed empirically: swapping interior spaces alone, the
    /// first fix tried here, left this exact row still splitting).
    ///
    /// Port of the engine's own fix (`modernTokenize`/`_MODERN_TOK_RE`,
    /// `PDFModernLayout.swift`, b26-modern item 2, ctrl-kd 8122706) — same graphic-run
    /// boundary shape `graphicRunRanges` already names (a maximal run starting AND ending
    /// on a graphic char, with only graphic-chars-or-spaces in between). The engine hand-
    /// rolls a full tokenizer because its own PDF emitter lays out every token by hand;
    /// AppKit already has a real line-breaker, so the equivalent fix here is narrower:
    /// splice a U+2060 WORD JOINER (zero-width, explicitly a non-break per Unicode's own
    /// line-breaking algorithm) between EVERY adjacent character pair strictly inside a
    /// graphic run — the run becomes one unbreakable unit exactly as `modernTokenize`
    /// makes it one token, without a second hand-rolled layout pass, and without adding
    /// any visible glyph or width (U+2060 has no glyph and no advance in any real font).
    /// Scattered single graphic chars amid ordinary prose (a legend line like "LL: └")
    /// are unaffected for the same reason `graphicRunRanges` itself is safe there: the
    /// run must CLOSE on another graphic char, so it can never cross real letters — a
    /// lone graphic char has no adjacent pair inside its own (zero-length) run at all.
    /// EVERY TOKEN, not only a graphic run — `modernTokenize`'s own `else` branch scans to
    /// the next SPACE, so a maximal run of non-space characters is one token and the engine
    /// never breaks inside one. AppKit's line breaker is Unicode UAX#14 and breaks in plenty
    /// of places a space is not: after a colon, before a backslash, after a hyphen.
    ///
    /// Measured on -README.WS's own Modern pages, where it is a large share of the
    /// difference: the app wrote "documented in the file C:" and then
    /// "\WS\REF\WSFORMAT.TXT." on the next line, where the engine keeps
    /// "C:\WS\REF\WSFORMAT.TXT." whole and breaks before it; and "as full-text-" /
    /// "searchable" against "as" / "full-text-searchable". Both are one rule.
    ///
    /// The graphic-run shape stays as its own branch because it is genuinely different —
    /// a graphic run may contain interior SPACES and still be one token (a box border with
    /// a hollow middle), which no ordinary token can.
    static func modernNoBreakGraphicRuns(_ text: String) -> String {
        let chars = Array(text)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)
        /// The span `chars[from...through]` as one unbreakable unit.
        func appendJoined(_ from: Int, _ through: Int) {
            for k in from...through {
                out.append(chars[k])
                if k < through { out.append("\u{2060}") }
            }
        }
        var i = 0
        while i < n {
            if graphicChars.contains(chars[i]) {
                var j = i
                var lastGraphic = i
                while j < n, graphicChars.contains(chars[j]) || chars[j] == " " {
                    if graphicChars.contains(chars[j]) { lastGraphic = j }
                    j += 1
                }
                appendJoined(i, lastGraphic)
                i = lastGraphic + 1
            } else if chars[i] == " " {
                out.append(chars[i])
                i += 1
            } else {
                // AN ORDINARY WORD IS LEFT ALONE. This used to join every token's own
                // characters as well, which put a U+2060 between every pair of letters in
                // the document — and bought nothing: `.byWordWrapping` already refuses to
                // break inside a word unless the word cannot fit the measure at all, and the
                // one case where it does (a rule wider than the measure) is answered by
                // `modernClipsRow`, not by joiners (`BOXES.WS`'s own citation below: word-
                // joining alone did not stop a 90-column border row breaking).
                //
                // What it DID buy was a document whose text is not its text. Every literal
                // needle in the suite stopped matching — ModernScreenplayTests' slugline,
                // ModernViewerStyleTests' "Copyright 1993" and "VIEWING THIS FILE" — and the
                // same joiners sit in what a reader copies, searches and hears.
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// A row that is ENTIRELY graphic content (a plain box border like `┌────...────┐`,
    /// no real prose at all) can still be wider than Modern's own text measure — AppKit's
    /// word-wrap will force a break through even a `modernNoBreakGraphicRuns`-protected
    /// run when the whole unbreakable unit exceeds the container's width (confirmed
    /// empirically: word-joining alone did not stop `BOXES.WS`'s 90-column border row
    /// from still splitting in 2). The engine's own fix keeps a graphic row as ONE
    /// unbroken block regardless — matched here by suppressing wrap ENTIRELY for a row
    /// this is true of (`.byClipping`: the row runs past the measure rather than
    /// reflowing), rather than trying to force AppKit past its own word-wrap contract.
    /// A MIXED row (real prose plus a shorter embedded graphic run, e.g. a "LL: └ LR: ┘"
    /// legend line) is untouched — it still wraps normally at its own real word
    /// boundaries, which `modernNoBreakGraphicRuns` alone already protects correctly.
    static func isWhollyGraphicRow(_ spans: [Span]) -> Bool {
        let combined = spans.map(\.text).joined()
        guard combined.contains(where: { graphicChars.contains($0) }) else { return false }
        return combined.allSatisfy { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{2060}" || graphicChars.contains($0) }
    }

    /// b28 note 10 (Jon's field report: "line returns in the middle" on `BOXES.WS`'s legend
    /// rows — `V:   ┃`, `H:  ─`, `Mixed:  ╗  ╝`). A MIXED row (a real prose label plus one or
    /// more separate box-drawing/shade/symbol glyphs) is not WHOLLY graphic
    /// (`isWhollyGraphicRow` correctly returns false for it), so it never got `.byClipping`
    /// and stayed on the default word-wrap — which folds the row at the ordinary legal wrap
    /// point between the label and its glyph once the row exceeds `modernTextWidthPt`.
    /// `modernNoBreakGraphicRuns` only protects the space BETWEEN two adjacent graphic chars,
    /// never the space between a label and a graphic run, so it cannot fix this alone.
    ///
    /// Narrowed to "more than one graphic char" rather than "any at all"
    /// (`modernNoBreakGraphicRuns`'s own guard uses "any") specifically to avoid clipping
    /// ordinary prose that merely contains ONE incidental symbol — e.g. a Sawyer-README
    /// bullet row's own single `■` marker (`partBlocks`' own citation, "Sawyer's -README list
    /// markers") — where suppressing wrap entirely would truncate real, legitimately-wrapping
    /// content instead of fixing a legend row. Every legend row this note names carries 2+
    /// distinct graphic glyphs (or is already short enough never to wrap on its own), so this
    /// threshold catches the real defect without touching a normal bulleted paragraph.
    static func hasMultipleGraphicChars(_ spans: [Span]) -> Bool {
        let combined = spans.map(\.text).joined()
        return combined.lazy.filter { graphicChars.contains($0) }.count > 1
    }

    /// b28 note 9 (Jon, screenshot circled in red: "THE BOXES ARE NOT CORRECT! The sides are
    /// dashed lines!"). Whether a `SemanticItem.para` payload's own runs contain at least one
    /// `graphicChars` glyph — used ONLY to detect a graphic row immediately followed by
    /// another graphic row (see the `paragraphSpacing` suppression at both `renderModern` and
    /// `renderModernAnnotated`'s call sites), never to reclassify or restyle the row itself.
    static func paraContainsGraphicChar(_ item: SemanticItem) -> Bool {
        guard case .para(_, _, _, let runs, _, _, _, _) = item else { return false }
        return runs.contains { run in run.text.contains { graphicChars.contains($0) } }
    }

    /// The structure classification (centered / def-list / bullet ladder / plain) for one
    /// `SemanticItem.para` payload, and the paragraph style it renders under — the SAME
    /// decision either Modern view (`renderModern`, `renderModernAnnotated`) makes for the
    /// SAME item, so Show Invisibles can only ever ADD marks, never recompute layout (job
    /// 300, Jon's b16 field report: invisibles ON silently lost centering and the def-list
    /// ladder because the old `renderModernAnnotated` walked the raw `annotatedLayout`
    /// stream instead of this same classified flow).
    static func modernParagraphContent(
        align: Alignment, indentCols: Double, cutCols: Double, runs: [SemanticRun],
        structure: RowStructure?, colPt: Double, size: CGFloat, font: NSFont, blockHangCols: Double? = nil,
        isVerse: Bool = false, fonts: [FontChange] = [], printedPt: Int = 12,
        tightFamily: CtrlKD.PDFFamily = .times
    ) -> (spans: [Span], paragraph: NSMutableParagraphStyle) {
        // b34 N1 (Jon's ruling, job 529): Modern's VIEW never applied the N9 sentence-
        // spacing collapse `PDFModernLayout.swift`'s own `modernFlow` adapter applies to
        // Modern's PDF/export output (that file's own doc comment: "a consumer [...] the
        // app's native text stack) applies sentence-spacing on top, same as every other
        // `modernFlow` option that never reaches the semantic items" — this app never
        // did, so the on-screen view kept typed double spaces after a sentence-ending
        // `.`/`?`/`!` while export collapsed them to one. `resolveSentenceSpacing` isn't
        // consulted here: Modern is never "printed" (that resolves to Printed's own
        // `renderNative`, a different function entirely), so `.auto`'s mode-aware
        // default always resolves to single-space on screen, unconditionally, matching
        // every other view-only option this job's own family (job 520/521) already
        // leaves without a Settings override. `sentenceSpacingSpans` (Block.swift,
        // CtrlKD) is the engine's own port of `sentence_spacing_spans` — called here, not
        // reimplemented, so any future rule change (e.g. narrowing to bare `.`) lands in
        // both the view and every emitter at once. Shared by BOTH `renderModern` and
        // `renderModernAnnotated` (Show Invisibles), which both call this function for
        // their own paragraph body text.
        //
        // Applied to each branch's own FINAL rendered content below, never to this
        // `spans` array itself: `structuredPrefixAndBody` (the bullet/def branch) slices
        // its `body`/`label` by CHARACTER OFFSET, cross-referencing `structure.body`/
        // `.label`'s own COUNT — lengths the ENGINE computed from the untransformed text.
        // Collapsing a space in `spans` before that slice runs shortens the concatenated
        // text by one character without shortening `structure.body.count` to match,
        // shifting `sliceSpans`'s start left by one and pulling an extra leading
        // character (the marker/body gap space) into `body` — a real regression this job
        // hit and fixed: VERSIONS.WS's Sawyer bullet ("...can be shown.  This...", the
        // exact double space this rule targets) started rendering "•  Modifying" (two
        // spaces) instead of "• Modifying", breaking `ModernIndentLadderTests`'s own
        // wrapped-line alignment law. `centerStrippedSpans` has no such precomputed-length
        // dependency (it counts padding directly off whatever text it receives), so it is
        // unaffected either way, but the transform is still applied to its OUTPUT below
        // for the same "never feed transformed text into structural slicing" discipline.
        // NEVER FEED TRANSFORMED TEXT INTO STRUCTURAL SLICING — the same discipline the
        // paragraph above states for the sentence-spacing collapse, for the same reason and
        // with a bigger blast radius. `modernNoBreakGraphicRuns` splices a zero-width U+2060
        // between every adjacent character of a token, and `structuredPrefixAndBody` slices
        // `label`/`body` by CHARACTER OFFSET against lengths the ENGINE computed from the
        // untransformed text: with joiners in, `raw.count` is inflated by roughly the token
        // length, so `raw.count - bodyLen` lands far to the right of the real body and
        // `lead + labelLen` far to the left of the real label — and everything between them
        // is DROPPED, because that gap is exactly what this slice discards.
        //
        // Measured on VERSIONS.WS, whose def rows are the case: its first row rendered as
        // "WS.E" + "nus, in addition to the classic WordStar control-key interface" against
        // the library's "WS.EXE: a mostly default installation but with minor customizations
        // made by Robert J. Sawyer, the person who compiled this WordStar archive. This is
        // the version you should try first. The help level is set to 4, meaning you'll have
        // access to full CUA-compliant Windows-style pulldown menus, in addition to..." —
        // 280 characters of the app's own text storage simply absent, in the app's own PDF,
        // not a reading artefact.
        //
        // So the joiners go on each branch's own FINAL content, exactly like the collapse.
        let spans = runs.map {
            Span(text: $0.text, styles: $0.styles, font: $0.font, colour: $0.colour)
        }
        // THE PIN COVERS UNDECLARED CENTRING TOO — a fourth app-only Modern rule, named here
        // rather than folded in silently. A row centred by TYPED PADDING (no `.oc`, no align
        // tag) is detected here, stripped of its padding and centred; `modernFlow` does no
        // such thing — it leaves the spaces in the row's tokens, so they count toward the
        // wrap and the row breaks on them. Measured on VERSIONS.WS: its "DEFAULT VERSION AND
        // COMPLETELY FRESH INSTALLATIONS:" heading is seven typed spaces plus the text; the
        // library wraps "INSTALLATIONS:" because those spaces spend 24.5pt of its 468pt
        // measure, and the app, having removed them, fits the line. Jon's own rule (b17,
        // STRENGTH.WS's title/byline/email) and it stays in the app.
        if let structure, structure.centered {
            // Undeclared (spaces-padded) or tag-declared centering (M-rules
            // addendum): strip the padding off the STYLED spans, same as the
            // engine's own `htmlCenteredRow` — a no-op for a real `align=center`
            // tag row (`modernSemanticFlow` already stripped that padding
            // upstream, M3), so the only real effect is on undeclared
            // spaces-only centering, which previously rendered as an ordinary
            // left-aligned paragraph with the padding baked into a proportional
            // font (STRENGTH.WS's title/byline/email).
            let renderSpans = Self.noBreakTokens(
                sentenceSpacingSpans(Self.centerStrippedSpans(spans)))
            let paragraph = Self.modernParagraphStyle(
                colPt: colPt, size: size, align: .center,
                indentCols: indentCols, cutCols: cutCols, tight: true,
                tightFamily: tightFamily)
            if Self.modernClipsRow(renderSpans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (renderSpans, paragraph)
        } else if let structure, let kind = structure.kind {
            // Def-list / bullet rows (job 299, the indent LADDER): `structure.col`
            // is the document's own absolute WordStar column — the block's `.lm`
            // plus this row's own residual indent — which is source-file trivia,
            // not a screen position. Two blocks in the SAME document can open a
            // top-level (`level == 1`) list at wildly different raw columns (job
            // 299's VERSIONS.WS: `.lm 15`, `.lm 2`, and `.lm 0` def/bullet blocks
            // all in the same file), so rendering `structure.col` directly put
            // level-1 labels at three different distances from the margin instead
            // of together at it — Jon's field report "the whole block floats far
            // right of it". `structure.level` (nesting depth, 1 = outermost) is
            // the ladder's real input: level 1 sits AT the 1in margin, and every
            // deeper level steps in by the same `levelStepCols`, regardless of
            // what raw column the source happened to use.
            let ladderIndentCols = Double(max(structure.level - 1, 0)) * Self.levelStepCols
            // The hang — where a WRAPPED continuation line lands.
            //
            // Bullet rows (job 329/b21, Jon's field note): the marker+gap
            // (`structuredPrefixAndBody`'s `"\u{2022} "`) renders in Modern's own
            // PROPORTIONAL body font, so its real advance width is measured directly
            // (`bulletMarkerWidthPt`) rather than assumed to land on a whole number of
            // `colPt`-wide monospace cells — the old fixed `hangCols: 2` drifted from
            // the actual glyph, which is what put wrapped lines slightly deeper than
            // the first line's own text start. This is a POINTS hang (`hangPt`), not a
            // columns one, precisely because it must match a real glyph, not a print
            // column.
            //
            // Def-list labels are untouched (job 322's own 2in-from-page-edge rule):
            // a label used to be measured PER ROW (job 299: `label.count + 2`), but
            // Jon's b17 field report on VERSIONS.WS caught the consequence — every row
            // in the same block wraps at a DIFFERENT column, "each line wrap seems to
            // have its own place." Job 307's fix: `defListBlockHangCols` (below)
            // precomputes ONE hang for the whole block (every def row sharing this
            // item's own contiguous run at this same nesting level), passed in as
            // `blockHangCols` — never derived from this row alone. A def-list nested
            // inside a bullet keeps this same def rule at its own deeper level.
            let hangCols: Double? = kind == .def
                ? (blockHangCols ?? Double((structure.label?.count ?? 0) + 2))
                : nil
            let (prefix, body) = Self.structuredPrefixAndBody(kind: kind, structure: structure, spans: spans)
            // The hang is measured from the marker the row ACTUALLY carries, now that
            // `structuredPrefixAndBody` keeps the author's own (see its doc comment) —
            // job 329/b21's rule is unchanged, only its input is no longer a fixed "• ".
            let hangPt: Double? = kind == .bullet
                ? Self.bulletMarkerWidthPt(prefix.map(\.text).joined(), font: font,
                                           entry: prefix.first?.font.flatMap {
                                               fonts.indices.contains($0) ? fonts[$0] : nil
                                           },
                                           printedPt: printedPt)
                : nil
            // N9 collapse applied to `body` ONLY, after slicing — the def case's own
            // literal `"  "` gap is a deliberate TWO-space structural separator
            // (`structuredPrefixAndBody`'s own doc comment) that must survive even when a
            // label happens to end in a sentence-ending character, and a bullet's marker is
            // the author's own text, sliced rather than reflowed.
            let renderSpans = Self.noBreakTokens(prefix + sentenceSpacingSpans(body))
            let paragraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                       indentCols: ladderIndentCols, cutCols: cutCols,
                                                       hangCols: hangCols, hangPt: hangPt)
            if Self.modernClipsRow(renderSpans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (renderSpans, paragraph)
        } else {
            // Plain (non-structure) paragraph. Jon's b17 field report on VERSIONS.WS:
            // its intro paragraph ("In folder C:\WS, ...") sat at an arbitrary indent —
            // the document's own `.lm 16`, still active from a dot command upstream,
            // carried straight into `indentCols` even though this paragraph is no def-
            // list/bullet/quote styling, just source-file trivia (same trap as job
            // 299's `structure.col`, one level up: a WHOLE PARAGRAPH's margin instead
            // of one row's indent). Ruling: an ordinary paragraph starts at Modern's own
            // 1in margin, period — UNLESS it's a genuine two-sided block-quote style
            // (BOTH `.lm` and `.rm` narrow the measure, e.g. OLDTIMES's Copyright block,
            // `\s14` "Double-Indented Quote", job 263's own `copyrightBlockIsDouble
            // Indented` test), which keeps its declared indent on both sides. A single
            // one-sided margin with no matching cut is never a deliberate style in this
            // corpus — only a residual `.lm` left open from an earlier block.
            //
            // THAT RULING IS ABOUT `.lm`, AND ONLY `.lm`. Its whole argument is that a left
            // margin left open upstream carries into paragraphs nobody styled; a NARROWED
            // RIGHT margin has no such failure mode, because `.rm` is what sets the measure
            // every wrapped line is broken at. Suppressing it does not restore Modern's own
            // margin — it WIDENS the paragraph past the one the author asked for, and every
            // line in the block then breaks somewhere the library does not break it.
            //
            // SCRIPT.WS is the case, and it is most of that document's distance on the
            // Modern gate: `.rm28` opens its pull-quote blocks, so the library wraps them at
            // 28 columns (201.6pt of measure, right edge 273.6pt) while the app wrapped them
            // at Modern's full 468pt. "`You have to type a few bits of" against "`You have
            // to type a few bits of information at the" — one library line against most of
            // two app ones, for every line of every quote in the article.
            //
            // So the cut is honoured whenever the author set one; the indent keeps the
            // double-sided condition exactly as Jon ruled it.
            // The pin covers this too. Job 299/b17 suppressing a one-sided `.lm` is the THIRD
            // app-only Modern layout decision the library does not have (`modernFlow` simply
            // honours `indentCols`), and it is the same class as the ladder and the hang:
            // an indent the app decides and the engine does not. Measured on VERSIONS.WS,
            // whose intro paragraph the library sets at x=180.00 and the app at x=72.00 —
            // with the ladder pinned and this left alone, that one paragraph was all that
            // stood between VERSIONS and zero. Named here rather than folded in silently:
            // Jon's ruling names the ladder and the hang, and this is the same mechanism one
            // branch over.
            let isDoubleIndentQuote = indentCols > 0 && cutCols > 0
            let paragraph = Self.modernParagraphStyle(
                colPt: colPt, size: size, align: align,
                indentCols: isDoubleIndentQuote ? indentCols : 0,
                cutCols: cutCols,
                tight: align == .center || isVerse,
                tightFamily: tightFamily)
            if Self.modernClipsRow(spans) {
                paragraph.lineBreakMode = .byClipping
            }
            return (Self.noBreakTokens(sentenceSpacingSpans(spans)), paragraph)
        }
    }

    /// A TOKEN TOO WIDE FOR THE MEASURE OVERFLOWS IT; IT DOES NOT BREAK.
    ///
    /// `modernWrap` breaks BETWEEN tokens and never inside one, so a token wider than the
    /// whole measure is placed on its own line and simply runs past the right edge. AppKit's
    /// `.byWordWrapping` has no such floor: asked to fit a word that cannot fit, it breaks
    /// the word, and the row becomes two lines the library never had.
    ///
    /// Word joiners are the only attribute that says "not here" to AppKit, so this stitches
    /// exactly the tokens that need it and leaves every other character alone. That
    /// narrowness is the point: `modernNoBreakGraphicRuns` was briefly generalized to join
    /// EVERY token's characters, which put a U+2060 between every pair of letters in the
    /// document — invisible on the page and very much present in what a reader copies,
    /// searches and hears, and in every literal needle the test suite matches on.
    ///
    /// Measured: TWAINLET.WS and OCAPTAIN.WS go to zero with this and read 16 and 4 without
    /// it, on tokens (a long URL, a run of underscores) a few points past the measure.
    /// The characters AppKit will break a line AFTER even though they sit inside a token —
    /// UAX #14's own break opportunities for a hyphen (class HY), the dashes (BA), and a
    /// solidus (SY). `modernWrap` has none of these: its token boundary is a space run and
    /// nothing else, so "anesthesia to surgery-practice, whereby" moves whole in the library
    /// and split at the hyphen here (TWAINLET.WS, every paragraph of it).
    ///
    /// A backslash is here for the same measured reason as the hyphen, not on principle:
    /// AppKit broke VERSIONS.WS's "C:\\WS\\MANUALS.)" where the library moves it whole. A
    /// COLON went in beside it and came straight back out — measured, "C:WSMANUALS.)" does
    /// not break at all, so the colon was never the opportunity, and joining every token
    /// that carries one put a word joiner through "An endnote: i", "LL: " and every other
    /// label in the suite's own needles.
    ///
    /// A full stop is deliberately not in this list: UAX #14 gives it class IS, which is not
    /// a break opportunity, so "INT." and "J." stay whole text — as does any run of letters
    /// or digits. That matters beyond tidiness: these are the tokens the suite's own literal
    /// needles are made of.
    /// The characters UAX #14 forbids a line break BEFORE — closing punctuation (CL), infix
    /// separators (IS), exclamation/interrogation (EX) and non-starters (NS). `modernWrap`
    /// has no such notion: its break opportunity is a space, wherever the space is.
    nonisolated private static func refusesABreakBefore(_ character: Character) -> Bool {
        ".,;:!?)]}%".contains(character)
            || character == "\u{2019}" || character == "\u{201D}"
            || character == "\"" || character == "'"
    }

    nonisolated private static func breaksInsideAToken(_ character: Character) -> Bool {
        character == "-" || character == "/" || character == "\\"
            || character == "\u{00AD}"
            || character == "\u{2010}" || character == "\u{2011}"
            || character == "\u{2012}" || character == "\u{2013}" || character == "\u{2014}"
    }

    /// A RUN BOUNDARY IS A TOKEN BOUNDARY, and a token boundary is somewhere the line may
    /// break.
    ///
    /// `modernFlow` tokenizes PER RUN — `for piece in modernTokenize(run.text)` — so two
    /// styled runs that meet mid-word are two tokens, and `modernWrap` may break between
    /// them. AppKit sees one uninterrupted string of characters and looks only at UAX #14,
    /// which has no break opportunity between `>` and `-`. SCRIPT.WS is the case: the
    /// library sets "...hit the appropriate <Esc>" and begins the next line "-plus-letter
    /// combination", where the app moves the pair whole and wraps a word early on every line
    /// after it.
    ///
    /// A zero-width space is the break opportunity, inserted only where AppKit would not
    /// already have one: between two runs that meet with no space on either side. The
    /// narrowness is the same discipline `joinOversizedTokens` below states — a boundary
    /// beside a space already breaks, and needs nothing.
    static func runBoundaryBreaks(_ spans: [Span]) -> [Span] {
        guard spans.count > 1 else { return spans }
        var out: [Span] = []
        out.reserveCapacity(spans.count)
        var previousTail: Character?
        for span in spans {
            guard let head = span.text.first else { out.append(span); continue }
            let needsBreak = previousTail.map { !$0.isWhitespace && !head.isWhitespace } ?? false
            previousTail = span.text.last
            guard needsBreak else { out.append(span); continue }
            out.append(Span(text: "\u{200B}" + span.text, styles: span.styles, font: span.font,
                            colour: span.colour, pctlHMI: span.pctlHMI))
        }
        return out
    }

    static func joinOversizedTokens(
        _ spans: [Span], font: NSFont, fonts: [FontChange], defaultSize: Int, measurePt: Double
    ) -> [Span] {
        guard measurePt > 0 else { return spans }
        // `previousWasSpace` carries ACROSS spans, because a style change can fall between a
        // space and the token after it — measured on -README.WS, whose ".BAK)" is its own run,
        // so a per-span reset never saw the space before it and the break opportunity below
        // was never inserted.
        var previousWasSpace = false
        return spans.map { span in
            defer { previousWasSpace = span.text.last.map { $0 == " " } ?? previousWasSpace }
            guard span.text.contains(where: { !$0.isWhitespace }) else { return span }
            let spanFont = resolvedFont(for: span, fallback: font, fonts: fonts,
                                        defaultSize: defaultSize, useCourierPrime: true)
            var out = ""
            var token = ""
            func flushToken() {
                guard !token.isEmpty else { return }
                let width = NSAttributedString(
                    string: token, attributes: [.font: spanFont]).size().width
                if Double(width) > measurePt || token.contains(where: { Self.breaksInsideAToken($0) }) {
                    out += token.map(String.init).joined(separator: "\u{2060}")
                } else {
                    out += token
                }
                token = ""
            }
            for character in span.text {
                if character == " " {
                    flushToken()
                    out.append(character)
                    previousWasSpace = true
                } else {
                    // A BREAK OPPORTUNITY AppKit REFUSES TO SEE. `modernWrap` may break at
                    // EVERY space; AppKit consults UAX #14, which forbids a break BEFORE a
                    // closing or infix character — a full stop, a comma, a bracket, a closing
                    // quote — so it keeps the space, that token and the one before it
                    // together as one unbreakable unit. Measured on -README.WS: the library
                    // sets "...(which are given the extension" and starts the next line
                    // ".BAK) hidden...", while AppKit held "extension .BAK)" together at
                    // 491pt against a 468pt measure and moved BOTH words down, one line's
                    // drift that then reported on six more pages.
                    //
                    // A zero-width space is class ZW — break opportunity AFTER — so one
                    // placed at the start of such a token gives back exactly the break the
                    // library has, and nothing else.
                    if token.isEmpty, previousWasSpace, Self.refusesABreakBefore(character) {
                        out.append("\u{200B}")
                    }
                    token.append(character)
                    previousWasSpace = false
                }
            }
            flushToken()
            guard out != span.text else { return span }
            return Span(text: out, styles: span.styles, font: span.font,
                        colour: span.colour, pctlHMI: span.pctlHMI)
        }
    }

    /// `modernNoBreakGraphicRuns` over a whole span list — applied to a branch's own FINAL
    /// content, never to the spans a structural slice still has to measure.
    static func noBreakTokens(_ spans: [Span]) -> [Span] {
        spans.map {
            Span(text: modernNoBreakGraphicRuns($0.text), styles: $0.styles,
                 font: $0.font, colour: $0.colour, pctlHMI: $0.pctlHMI)
        }
    }

    /// THE LINE'S FACE — the library's own `modernLineFace`, over a paragraph's runs: the
    /// SIZE is the largest on the line, and the FAMILY is that same run's, ties going to the
    /// last one (`spt >= best.pt`). Both answers come out of one walk so they can never name
    /// different runs.
    ///
    /// The size half was inline in `renderModern` before the leading spacer needed the family
    /// too, and its measurements are worth keeping stated. The engine's own figure is
    /// `let sizes = vline.map { sized($0.styles, $0.pt).points }`, `h = modernLine *
    /// sizes.max()`. This renderer used to pass the DOCUMENT's body size for every paragraph,
    /// so a 72pt banner advanced 16.80pt instead of 86.40 — LJ6DTP.WS's two title lines sit
    /// 172.80 apart in the library and sat 33.60 apart here, and the page then held 20 lines
    /// against the library's 11.
    ///
    /// Per PARAGRAPH rather than per wrapped line, which is as fine as an AppKit paragraph
    /// style can express it: identical wherever a paragraph is one size (every case in this
    /// corpus that moved), and it over-leads rather than under-leads a wrapped mixed-size
    /// paragraph, which is the safe direction — the engine's own figure is the max on the
    /// line.
    ///
    /// EVERY run counts, including one with no font block of its own: the library's `sizes`
    /// is `vline.map { sized($0.styles, $0.pt).points }` and `$0.pt` for a fontless token is
    /// `modernBodyPt` — the document size — not an absence. Skipping those (`compactMap` to
    /// `nil`, which this did) let a paragraph whose only LETTERED run sat in a 12pt Courier
    /// block lead at 14.40 while the library, counting the fontless space token beside it at
    /// 14, led at 16.80. Measured on -README.WS: one such row per file-name block, 2.4pt
    /// each, and the page then held a line the library's did not.
    static func modernParagraphFace(
        runs: [SemanticRun], fonts: [FontChange], size: CGFloat,
        fontlessFamily: CtrlKD.PDFFamily
    ) -> (family: CtrlKD.PDFFamily, pt: Int) {
        var best: (pt: CGFloat, entry: FontChange?)?
        for run in runs {
            let entry = run.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
            let points = entry.map(\.points) ?? 0
            // Same rounding as `resolvedFont`'s, and for the same reason.
            let pt = points > 0 ? max(1, CGFloat(CtrlKD.roundHalfToEven(points))) : size
            if best == nil || pt >= best!.pt { best = (pt, entry) }
        }
        guard let best else { return (fontlessFamily, Int(size.rounded())) }
        // Modern's own rule for a token with no font block, never `pdfFamily(nil)` — see
        // `renderModern`'s `modernFontlessFamily`.
        return (best.entry.map(pdfFamily) ?? fontlessFamily, Int(best.pt.rounded()))
    }

    /// Job 434 (b27 items 1/9): Modern's own counterpart to Native's `oversizedSelfPasses`/
    /// `leadingHeadroom` (`DocumentRenderer.swift:903-1263`, `PagedDocumentView.swift:37`) —
    /// Jon's b26 field review found a WS4 title's ascenders clipped at the top in MODERN
    /// (and separately, LJ6DTP's shadow-title first line still top-clipped in MODERN); Native
    /// had already fixed the SAME class of bug (job 396/422) but `renderModern` was always a
    /// THIRD implementation with no headroom mechanism at all — `oversizedSelfPasses: []`/
    /// `leadingHeadroom: []` below are literals, never populated.
    ///
    /// Root cause: `modernParagraphStyle`'s "tight" line-height (`modernVerseTightLineHeightMultiple`,
    /// a RELATIVE multiplier on AppKit's own NATURAL line height, applied to every centered/
    /// verse paragraph) compresses the line box below a big title font's own real ascender.
    /// For the very first line of Modern's one continuous flow there is no earlier content
    /// for the excess ascent to bleed into — it clips against the text container's own top
    /// edge; for any OTHER line it instead crowds the line above it (a real defect too, not
    /// merely cosmetic — `oversizedClearanceBelowBaseline`'s own citation on why "the glyph
    /// technically stays inside its own box" is not the bar).
    ///
    /// This is NOT a port of Native's own self-pass/overlay mechanism (Jon's ruling): Modern
    /// has no `PageLine`s, no overprint/self-pass compositing, and no page boundaries known at
    /// render time (`RenderedDocument.hfEvents`'s own doc comment — AppKit decides where a
    /// Modern page breaks, never this function). Instead the reserved room is baked directly
    /// into the FLOWING TEXT, as an invisible SPACER PARAGRAPH inserted immediately before the
    /// affected one — NOT as `paragraphSpacingBefore` on that paragraph itself, which was the
    /// first thing tried here and empirically does NOT work for the exact case that matters
    /// most: AppKit suppresses `paragraphSpacingBefore` entirely for whichever paragraph is
    /// the very first one in a text container (confirmed empirically building this fix — the
    /// deficit value landed correctly in the attribute, but the real first-fragment's own
    /// container-relative position never moved). A preceding spacer paragraph sidesteps that
    /// suppression rule entirely: its own fixed `minimumLineHeight`/`maximumLineHeight` is
    /// ordinary line STACKING, not spacing-relative-to-a-predecessor, so it reserves the same
    /// room whether the paragraph it precedes is the document's very first line (a hard
    /// container-top clip) or an ordinary mid-flow line AppKit's own later pagination happens
    /// to start a page on — `PagedDocumentView.buildPages` already respects ordinary paragraph
    /// stacking the same way for everything else in this file, no separate headroom/overlay
    /// bookkeeping to keep in sync with it.
    ///
    /// The RULE lives here only: "if this paragraph's real ink rises above where the
    /// tight-compressed box puts its baseline, reserve the difference plus a float-safety
    /// margin" — `CtrlKD.modernSpacerPad`, which is the same `+ 2` convention
    /// `leadingHeadroom` already uses, for the same reason (a second, independent drawing
    /// pass does not land pixel-for-pixel identical to the one that measured it), now named
    /// once in the library so neither producer can drift off it. `modernAscentDeficit` below
    /// is the METRICS seam: it answers out of the library's own AFM tables (Jon: "Do it in
    /// the engine. Adopt it in Soft Return."), so the room reserved here and the room the
    /// library's own Modern PDF reserves are the same number by construction.
    static func modernLeadingSpacer(
        for line: NSAttributedString, paragraph: NSParagraphStyle, bodyFont: NSFont,
        face: (family: CtrlKD.PDFFamily, pt: Int)
    ) -> NSAttributedString? {
        // Only a TIGHT (compressed-below-natural) paragraph can ever need this — a plain
        // paragraph sets no line-height override at all (`modernParagraphStyle`'s own doc
        // comment: "its baseline IS AppKit's own natural font-metric line height"), so
        // AppKit's default placement already reserves a font's own real ascender above its
        // baseline, the same way it does for every ordinary (non-tight) line in this file.
        guard paragraph.lineHeightMultiple > 0, paragraph.lineHeightMultiple < 1 else { return nil }
        let deficit = Self.modernAscentDeficit(for: line, face: face)
        guard deficit > 0 else { return nil }
        let height = deficit + CGFloat(CtrlKD.modernSpacerPad)
        let spacerParagraph = NSMutableParagraphStyle()
        spacerParagraph.minimumLineHeight = height
        spacerParagraph.maximumLineHeight = height
        let spacer = NSMutableAttributedString()
        spacer.append(attributedLine([], font: bodyFont, paragraph: spacerParagraph))
        spacer.append(lineTerminator(font: bodyFont, paragraph: spacerParagraph))
        // Planning #222: say what this is, rather than leaving readers to infer it from its
        // line-height shape — see `NSAttributedString.Key.modernLeadingSpacer`.
        spacer.addAttribute(.modernLeadingSpacer, value: true,
                            range: NSRange(location: 0, length: spacer.length))
        return spacer
    }

    /// METRICS, FROM THE LIBRARY'S OWN TABLES. Jon, on the leading spacer: "Do it in the
    /// engine. Adopt it in Soft Return." The engine's `modernLeadingSpacer` is
    /// `modernInkAboveBaseline(toks) - modernTightBaseline(family, pt)`, and this is that
    /// same subtraction over the same numbers — `inkTopPt`'s AFM ink extents above,
    /// `CtrlKD.modernTightBaseline` below — so the two producers cannot disagree about how
    /// much room a tightened line needs. A positive result means the ink rises above where
    /// the tightened box puts the baseline; zero or negative means it already fits.
    ///
    /// This REPLACED a measurement of the app's own drawing: AppKit's real first-fragment
    /// baseline (`NSLayoutManager.location(forGlyphAt:)`) against the line's real glyph ink
    /// (`CTLineGetBoundsWithOptions(.useGlyphPathBounds)`). That was honest about what this
    /// renderer actually paints and it could not be reconciled by construction, because a
    /// Mac face's glyph PATHS are not the design bounding boxes the AFM publishes for the
    /// metric-compatible base-14 row — the engine's own `modernFaceAscent` doc comment
    /// records the residual it could not close from its side ("What is left sits in the
    /// INK"). Measured on -README.WS, whose centred title block classifies as verse: the app
    /// reserved 3.94pt where the library reserved 3.60, on every such line.
    ///
    /// The per-run readings are the engine's, exactly:
    ///
    ///   * a whitespace-only run contributes nothing;
    ///   * a run carrying cp437 box/block/shade characters takes its ink from the VECTOR
    ///     CELL's own top edge, `(modernLine - 0.25) * pt` above the baseline — the same
    ///     geometry that draws it, never the `?` cp1252 would substitute — and then measures
    ///     whatever ordinary text is left beside it;
    ///   * everything else is `inkTopPt(text, base14, pt)`, raised by the run's own
    ///     `.baselineOffset` (the engine's `sized()` rise).
    static func modernAscentDeficit(
        for line: NSAttributedString, face: (family: CtrlKD.PDFFamily, pt: Int)
    ) -> CGFloat {
        guard line.length > 0 else { return 0 }
        var inkAboveBaseline = 0.0
        let whole = NSRange(location: 0, length: line.length)
        line.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            var text = (line.string as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let pt = Int(((attributes[.font] as? NSFont)?.pointSize
                          ?? CGFloat(face.pt)).rounded())
            let rise = (attributes[.baselineOffset] as? CGFloat).map(Double.init) ?? 0
            if text.contains(where: { graphicChars.contains($0) }) {
                inkAboveBaseline = max(inkAboveBaseline,
                                       rise + (Double(Self.modernLibraryLineFactor) - 0.25) * Double(pt))
                text = String(text.filter { !graphicChars.contains($0) })
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            }
            // A run this renderer laid out without the Modern gate (the invisible
            // `lineTerminator`, say) carries no face of its own; the engine reads a token
            // with no font block in its own default family, which is what `pdfFamily(nil)`
            // names and what `modernBase14Name(nil, ...)` spells.
            let base14 = attributes[.modernBase14] as? String ?? "Times-Roman"
            inkAboveBaseline = max(inkAboveBaseline, rise + inkTopPt(text, base14, pt))
        }
        return CGFloat(inkAboveBaseline - CtrlKD.modernTightBaseline(face.family, face.pt))
    }

    /// Job 450 (b27, revert of job 439's marker-override): job 439 substituted Native/
    /// Printed's plain-arabic endnote label into Modern, believing it matched a b26 intake
    /// ruling. It did not — Jon ruled on 2026-08-20, having already weighed the paper
    /// evidence, that Modern KEEPS the Word-standard lowercase-roman endnote convention
    /// (`modernSemanticFlow`'s own `shownLabels` under its `.word` scheme, MS-OI29500
    /// §17.11.17: "In Word, the default value for endnote numbering format is lowerRoman"):
    /// "Since the point is to be Modern, I think we should keep it at the Word standard we
    /// are using. For now." Doctrine going forward: paper scans adjudicate Native/Printed;
    /// Modern diverges from paper BY DESIGN to match Word/modern conventions, and a scan
    /// must never be cited against it. So this file no longer substitutes anything —
    /// `renderModern`/`renderModernAnnotated` render `flow.notes`/`SemanticRun.text` exactly
    /// as `modernSemanticFlow` (the engine) already romanizes them.

    /// Job 437 (b27 item 10, Jon's ruling): `NSParagraphStyle.lineHeightMultiple` is a
    /// PARAGRAPH-level attribute — it compresses EVERY AppKit line fragment of a hard-
    /// returned line uniformly, including any fragment produced by AppKit's own word-wrap
    /// INSIDE that same hard-returned line (`modernSemanticFlow` already reflows a
    /// WordStar-source soft return away, so a `.para` item's text is real prose that gets
    /// re-wrapped fresh at Modern's own proportional-font width — job field report:
    /// POWERUSE.WS's TTO #2/#3 captions, `TTO #2`'s own source using WordStar soft returns
    /// (`0x8D`) between short print lines, reflow into ONE long paragraph that then wraps
    /// in Modern). Jon's ruling: tight leading is only ever legitimate BETWEEN hard-
    /// returned lines — never on a soft-wrapped CONTINUATION of one — "no paragraph class
    /// justifies sub-normal leading" there, verse or not. AppKit has no attribute that
    /// tightens only the inter-paragraph gap while leaving a paragraph's own internal wrap
    /// spacing alone, so the fix backs `tight` off ENTIRELY for a paragraph occurrence that
    /// actually wraps — both fragments render at ordinary body leading, the closest
    /// available approximation to "hard-returns only" AppKit's own model supports.
    ///
    /// Whether a hard-returned line actually wraps depends on real AppKit layout at the
    /// real render width (mixed per-run fonts, PIX widths, indent geometry already baked
    /// into `paragraph`) — the same "measure real layout, never guess" rule
    /// `modernAscentDeficit` above already established, so this measures the ACTUAL built
    /// `line` rather than estimating from a character count. (Horizontal word-wrap is a
    /// width-only decision — `lineHeightMultiple` is a vertical metric that plays no part
    /// in WHERE AppKit breaks a line — so measuring the wrap on the tight-styled `line` is
    /// exactly as accurate as measuring it on a hypothetical untight one.)
    static func modernLineWraps(_ line: NSAttributedString, width: CGFloat) -> Bool {
        guard line.length > 0 else { return false }
        let storage = NSTextStorage(attributedString: line)
        let layoutManager = softReturnLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var fragments = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
            fragments += 1
        }
        return fragments > 1
    }

    /// One hang column per def-list BLOCK, not per row (job 307, Jon's b17 field
    /// report round 2 on VERSIONS.WS/CONVERT.WS: job 299's per-row `label.count + 2`
    /// hang made every row in the same block wrap at its own column). Rule: 2in
    /// (144pt) from the PAGE EDGE past the block's own level start, i.e. 72pt past
    /// Modern's own 1in (72pt) margin — a Modern screen measure, independent of the
    /// document's own column width, and now (job 322/b20, Jon's field ruling
    /// 2026-08-15: "I don't like the 2.5-inch wrap... it needs to be 2 inches")
    /// FIXED — never widened, no matter how long a block's longest label is.
    ///
    /// Job 312/b19 (2026-08-14, Jon's field report, corrects job 307's own spec error):
    /// `renderModern`'s `textFrame` origin already sits at the 1in margin, so a
    /// paragraph's `headIndent` of 144pt (job 307's original figure) landed the column
    /// at margin(72pt) + 144pt = 216pt from the page edge — 3in total, "indented too
    /// much... 1 inch off margin" per Jon. The base fixed offset is 72pt (one inch
    /// PAST the margin, so margin(72pt) + 72pt = 144pt/2in from the page edge, matching
    /// the field spec) — the per-level ladder stepping for nested blocks below is
    /// unchanged from job 307.
    ///
    /// Job 322/b20: job 312's own longest-label override — widening the column past
    /// 144pt for a block whose longest label wouldn't fit — is GONE. Jon rejected the
    /// look it produced (b19's VERSIONS.WS block, with `RJSMACRO.EXE:` in it, wrapped
    /// its whole block at 2.5in). The column never moves now: a label longer than it
    /// simply overlaps — its description starts right after the label + gap on the
    /// label's own line (no paragraph-geometry trick needed for this: `modernParagraph
    /// Style`'s `firstLineHeadIndent` only ever governs where LINE ONE starts, never
    /// where it ends, so a long label already ran past `headIndent` on line one before
    /// this job — only wrapped lines ever obeyed `headIndent`/`hangCols`), and every
    /// WRAPPED line still snaps to the fixed 144pt column like every other row's.
    ///
    /// A "block" is a maximal contiguous run of list rows (bullet/def/plain rows
    /// embedded inside one, e.g. VERSIONS.WS's unlabelled continuation line) that
    /// never dips shallower than a given nesting level — CONVERT.WS's nested level-2
    /// def rows (WSASC.COM etc., nested inside a level-1 bullet run) form their OWN
    /// block at their OWN level, stepped in with the rest of the ladder (job 299),
    /// never sharing the outer block's column. Returns the item's ARRAY INDEX (not
    /// identity — `SemanticItem` rows can repeat) mapped to its block's hang, for
    /// every row with `structure.level >= 1`; callers look this up per index while
    /// walking the same `items` array. Job 322 leaves this block-grouping machinery in
    /// place even though every block now resolves to the SAME fixed column regardless
    /// of its content — the machinery is what job 312c's blank-line coalescing (below)
    /// still needs, and re-deriving block boundaries a second, simpler way risks the
    /// two drifting apart the way `renderModern`/`renderModernAnnotated` sharing this
    /// one function is specifically designed to prevent.
    ///
    /// Job 312c/b19 (2026-08-14, Jon's ruling): a blank source line between two def
    /// entries is vertical spacing WITHIN the visual list, not a boundary — his own
    /// complaint ("each line wrap seems to have its own place") is about the whole
    /// list Jon looks at, and VERSIONS.WS's entries are blank-line separated. A blank
    /// row therefore does NOT close a block when the next non-blank row continues the
    /// list (a non-centered row with `structure.level >= 1`); the block only closes on
    /// a genuine non-list row (prose/heading), or at end of items. Nesting dipping
    /// shallower is still handled the moment that shallower row actually arrives — the
    /// existing `closeLevels(atLeast: level + 1)` call below already closes only the
    /// levels deeper than it, so a blank line ahead of a same-or-shallower list row
    /// needs no special-casing of its own.
    static func defListBlockHangCols(
        items: [SemanticItem], colPt: Double
    ) -> [Int: Double] {
        let fixedCols = 72.0 / colPt
        var openIndices: [Int: [Int]] = [:]
        var result: [Int: Double] = [:]

        func closeLevels(atLeast level: Int) {
            for l in openIndices.keys.filter({ $0 >= level }) {
                for idx in openIndices[l] ?? [] { result[idx] = fixedCols }
                openIndices[l] = nil
            }
        }

        func isListRow(_ item: SemanticItem) -> Bool {
            guard case let .para(_, _, _, _, _, structureOpt, _, _) = item,
                  let structure = structureOpt, !structure.centered, structure.level >= 1
            else { return false }
            return true
        }

        func nextNonBlankContinuesList(after i: Int) -> Bool {
            var j = i + 1
            while j < items.count, case .blank = items[j] { j += 1 }
            guard j < items.count else { return false }
            return isListRow(items[j])
        }

        for (i, item) in items.enumerated() {
            if case .blank = item {
                if nextNonBlankContinuesList(after: i) { continue }
                closeLevels(atLeast: 1)
                continue
            }
            guard case let .para(_, _, _, _, _, structureOpt, _, _) = item,
                  let structure = structureOpt, !structure.centered, structure.level >= 1
            else {
                closeLevels(atLeast: 1)
                continue
            }
            let level = structure.level
            closeLevels(atLeast: level + 1)
            openIndices[level, default: []].append(i)
        }
        closeLevels(atLeast: 1)
        return result
    }

    /// MODERN'S PAGE BOX — the document's declared geometry, falling back to the modern
    /// page (1in margins) when the file says nothing.
    ///
    /// This used to be a flat `72` on all four sides, with a doc comment arguing that
    /// "Modern's page is the app's own, not the file's". That argument was answering a
    /// DIFFERENT question — the one Jon's asymmetric-margin measurement actually caught,
    /// which was a back-solve that aimed the first BASELINE at `margin + modernMetrics(doc)
    /// .size`, mixing the library's Courier 12 into a frame built for the user's own face.
    /// Dropping the back-solve was right; flattening the margins to a constant went one
    /// step further than that evidence, and past the library's own stated rule
    /// (`modernGeometry`: "the document's declared geometry wins (governing principle);
    /// silence is the modern page: 1in margins on Letter").
    ///
    /// Measured against the library's own Modern PDF (2026-09-11): a document that declares
    /// `.mt` got a top margin 7.2pt (LJ6DTP.WS, `.mt 6.6`) to 12.0pt (SCRIPT.WS, `.mt 7`)
    /// off the library's on EVERY page — and `.mb` moved with it, so a different number of
    /// lines fitted each page, which is exactly what the page-break gate reads.
    ///
    /// `modernGeometry` is the library's own function, now `public`. The PAPER stays the
    /// app's (the bottom bar's Page control), so the user's choice still governs the sheet;
    /// only the margins inside it come from the file.
    public static func modernTextFrame(_ doc: Document, paper: CGSize) -> CGRect {
        let geometry = modernGeometry(doc)
        // Batch 41: the engine's own measure — its right margin mirrors the left (engine f596f82),
        // no longer a flat 1in.
        let width = max(1, CGFloat(geometry.width))
        let height = max(1, paper.height - CGFloat(geometry.top) - CGFloat(geometry.bottom))
        return CGRect(x: CGFloat(geometry.left), y: CGFloat(geometry.top),
                      width: width, height: height)
    }

    /// Batch 41 (A): Modern's page — the sheet, the text frame on it, and the measure a paragraph wraps at.
    public struct ModernPage: Sendable {
        public let paper: CGSize
        public let textFrame: CGRect
        /// One column's width on a page the engine lays in newspaper columns, else the frame's.
        public let measure: CGFloat
    }

    /// Batch 41 (A): Modern's page as the engine's own Modern PDF lays it (`modernPageFurniture`'s first page): its
    /// sheet — the document's declared page, `.pr or=l` applied, which put REF/BOOKLET.WS on a portrait Letter sheet
    /// until now — and the text frame and columns on it. A hand-picked Page size in the bottom bar still wins for the
    /// sheet, exactly as Native's does (Athena, 2026-09-15), and the text keeps the engine's frame on it. A document the
    /// engine lays no Modern page for keeps the paper the bottom bar reports.
    public static func modernPage(_ state: DocumentState, furniture: [ModernPageFurniture]) -> ModernPage {
        let doc = state.document
        let manual = state.pageSize.provenance == .manual ? state.pageSize.value?.sizeInPoints : nil
        guard let first = furniture.first else {
            let paper = state.pageSize.value?.sizeInPoints
                ?? CGSize(width: modernMetrics(doc).pageWidth, height: modernMetrics(doc).pageHeight)
            let frame = modernTextFrame(doc, paper: paper)
            return ModernPage(paper: paper, textFrame: frame, measure: frame.width)
        }
        let paper = manual ?? CGSize(width: first.sheetWidth, height: first.sheetHeight)
        let frame = CGRect(x: first.marginLeft, y: first.marginTop, width: max(1, first.textWidth),
                           height: max(1, paper.height - first.marginTop - first.marginBottom))
        // The whole frame: newspaper columns wait on the engine's own column ranges (`modernColumnCount`).
        return ModernPage(paper: paper, textFrame: frame, measure: frame.width)
    }

    /// Batch 41 (columns): the engine's own column partition, resolved against the text this render built.
    ///
    /// `ModernColumnRange` (engine 63fab84) names each column's end as a flow-item index and a UTF-16 offset into that
    /// item's own `runs.map(\.text).joined()`. `endItem` is EXCLUSIVE and the ranges are contiguous across columns and
    /// pages, so a column's end is the next one's start and the last ends at `items.count`. An offset of `0` means a
    /// whole-item boundary — this item begins the next column — and a non-zero offset means the item was split at a
    /// visual line, the offset being where the line on the far side begins.
    ///
    /// A whole-item boundary resolves to that item's own start in the view's text (`itemStarts`, recorded as the text
    /// was built). A SPLIT resolves by looking for the engine's own text at that offset inside the view's copy of that
    /// item: the view's text is not the flow's joined run text (sentence spacing collapsed, markers and tabs inserted),
    /// so an arithmetic offset would drift. The search runs in a window around where the offset would fall if nothing
    /// had changed, because a document like REF/BOOKLET.WS repeats the same sentence inside one item and a
    /// whole-item search could match the wrong copy.
    public static func modernColumnBreaks(furniture: [ModernPageFurniture], items: [SemanticItem],
                                   itemStarts: [Int], text: String) -> [[ModernColumnBreak]] {
        guard !furniture.isEmpty, !itemStarts.isEmpty else { return [] }
        let whole = text as NSString

        /// The first item at or after `index` that put something in the view's text, and where it began.
        func start(atOrAfter index: Int) -> Int? {
            var cursor = max(0, index)
            while cursor < itemStarts.count {
                if itemStarts[cursor] >= 0 { return itemStarts[cursor] }
                cursor += 1
            }
            return nil
        }

        /// The text with every run of whitespace squeezed to one space and every invisible dropped, plus a map from
        /// each kept character back to where it came from. The two texts differ INSIDE an item — measured on
        /// REF/BOOKLET.WS, the engine's paragraph is 238 characters where the view's is 250, and the extra twelve sit
        /// at different places in the line — so a boundary is found by comparing what the characters SAY, with the
        /// map giving back the real offset.
        func normalised(_ text: NSString, from: Int, to: Int) -> (text: String, map: [Int]) {
            var scalars: [Character] = []
            var map: [Int] = []
            var lastWasSpace = false
            var index = from
            while index < to {
                let unit = text.character(at: index)
                // The view inserts WORD JOINERs of its own, and neither side's spacing is the other's.
                if unit == 0x2060 || unit == 0xFEFF { index += 1; continue }
                let scalar = Character(UnicodeScalar(unit) ?? " ")
                if scalar.isWhitespace {
                    if !lastWasSpace { scalars.append(" "); map.append(index); lastWasSpace = true }
                } else {
                    scalars.append(scalar); map.append(index); lastWasSpace = false
                }
                index += 1
            }
            return (String(scalars), map)
        }

        /// One engine boundary in the view's own text, or `nil` for "the end of the document". A boundary this cannot
        /// place returns `nil` rather than an arithmetic guess: `itemStart + offset` is WRONG — the two texts run to
        /// different lengths inside an item — and a wrong offset that looks plausible is worse than none, because the
        /// column silently fills to its own capacity instead and nothing says why.
        func viewOffset(item: Int, offset: Int) -> Int? {
            guard item < itemStarts.count else { return nil }
            guard let itemStart = start(atOrAfter: item) else { return nil }
            guard offset > 0, itemStarts.indices.contains(item), itemStarts[item] == itemStart,
                  case .para(_, _, _, let runs, _, _, _, _) = items[item]
            else { return itemStart }
            let engineText = runs.map(\.text).joined() as NSString
            guard offset < engineText.length else { return itemStart }
            let itemEnd = start(atOrAfter: item + 1) ?? whole.length
            guard itemEnd > itemStart else { return itemStart }

            // What the engine's line SAYS at the boundary, normalised, and the same for the view's copy of the item.
            //
            // SEARCHED IN A WINDOW, NOT ACROSS THE WHOLE ITEM. REF/BOOKLET.WS repeats one paragraph over and over
            // — its boundary phrase occurs 37 times in the flow, at 139, 359, 579 … 1459, 1679 — so a whole-item
            // search takes whichever copy comes first and can land a boundary hundreds of characters past the
            // right one. (That is exactly what it did: 1679 next door to the 1675 this used to return.)
            //
            // The window is measured in the NORMALISED space on BOTH sides, which is what the earlier windowed
            // version got wrong: it positioned the window with `itemStart + offset`, an arithmetic estimate in
            // RAW characters, and the two texts do not run to the same length inside an item. Normalising first
            // puts both in the same units, so the engine's own normalised distance from the item's start is a
            // sound estimate of the view's, and a tolerance around it only has to absorb the small differences
            // that remain.
            let engineItem = normalised(engineText, from: 0, to: engineText.length)
            let engineBoundary = engineItem.map.firstIndex { $0 >= offset } ?? engineItem.text.count
            let engineTail = normalised(engineText, from: offset, to: engineText.length).text
            guard !engineTail.isEmpty else { return itemStart }
            let needle = String(engineTail.prefix(24))
            let view = normalised(whole, from: itemStart, to: itemEnd)
            let slack = 48
            let lower = max(0, engineBoundary - slack)
            let upper = min(view.text.count, engineBoundary + slack + needle.count)
            var found: Range<String.Index>?
            if upper > lower {
                let from = view.text.index(view.text.startIndex, offsetBy: lower)
                let to = view.text.index(view.text.startIndex, offsetBy: upper)
                found = view.text.range(of: needle, range: from..<to)
            }
            // No whole-item fallback: on a repeating document that is the very thing that mis-placed the
            // boundary. A boundary this window cannot place is reported as unplaceable and fails loudly.
            guard let found else { return nil }
            let position = view.text.distance(from: view.text.startIndex, to: found.lowerBound)
            guard view.map.indices.contains(position) else { return nil }
            return view.map[position]
        }

        return furniture.map { page in
            page.columnRanges.sorted { $0.column < $1.column }.map { range in
                ModernColumnBreak(column: range.column,
                                  end: viewOffset(item: range.endItem, offset: range.endOffset))
            }
        }
    }

    static func renderModern(_ state: DocumentState,
                                     exportFlags: ExportFlags = .allOn) -> RenderedDocument {
        let session = modernRenderSession(state, exportFlags: exportFlags)
        session.renderAll()
        return session.finish()
    }

    /// Batch 26 (#271 M7): `renderModern`'s work, held open item by item, the way `NativeRenderSession`
    /// holds Native's page by page. The engine's half — `modernSemanticFlow` and the graphic cells —
    /// comes first (`ModernEngineWork`, which a window makes off the main thread); each flow item's
    /// attributed text is then built in order, as many as a turn of the run loop has room for; `finish()`
    /// builds the document once the last is done. Rendering every item then finishing IS `renderModern`:
    /// Modern's pages are AppKit's to find, so a partial Modern render is never shown.
    @MainActor
    public final class ModernRenderSession {
        /// How many flow items the document has.
        public let itemCount: Int
        /// How many of them are rendered so far, from the first.
        public private(set) var renderedItems = 0
        private let renderItem: @MainActor (Int) -> Void
        private let currentTextLength: @MainActor () -> Int
        private let makeDocument: @MainActor (Bool) -> RenderedDocument
        private var finished = false

        public init(itemCount: Int, renderItem: @escaping @MainActor (Int) -> Void,
             textLength: @escaping @MainActor () -> Int,
             document: @escaping @MainActor (Bool) -> RenderedDocument) {
            self.itemCount = itemCount
            self.renderItem = renderItem
            self.currentTextLength = textLength
            self.makeDocument = document
        }

        /// Batch 27: how much text the items rendered so far have built.
        public var textLength: Int { currentTextLength() }

        /// Batch 27: the items rendered so far, as a document — a copy, so rendering goes on. Its first pages are
        /// the whole render's own while the text runs well past them (`DocumentWindowController`'s Modern preview);
        /// its last are not.
        public func snapshot() -> RenderedDocument {
            precondition(!finished, "ModernRenderSession: snapshot after finishing")
            return makeDocument(false)
        }

        public var isComplete: Bool { renderedItems >= itemCount }

        public func renderAll() {
            while !isComplete {
                renderItem(renderedItems)
                renderedItems += 1
            }
        }

        /// Renders items until `deadline` (`DispatchTime` uptime nanoseconds) passes — at least one.
        public func renderNext(until deadline: UInt64) {
            guard !isComplete else { return }
            repeat {
                renderItem(renderedItems)
                renderedItems += 1
            } while !isComplete && DispatchTime.now().uptimeNanoseconds < deadline
        }

        /// The rendered document, once every item is rendered. Once only.
        public func finish() -> RenderedDocument {
            precondition(isComplete, "ModernRenderSession: finished before the last item")
            precondition(!finished, "ModernRenderSession: finished twice")
            finished = true
            return makeDocument(true)
        }
    }

    /// Batch 27: a render held open in slices — its work as PHASES run in order, each a count of steps, the
    /// count read when the phase begins (a later phase's count can depend on an earlier phase's result), and a
    /// finish once every step has run. The Show Invisibles renders use it (`nativeAnnotatedRender`,
    /// `modernAnnotatedRender`); running every step then finishing IS the synchronous render.
    @MainActor
    public final class SlicedRender {
        public struct Phase: Sendable {
            public let count: @MainActor () -> Int
            public let step: @MainActor (Int) -> Void
        }

        private let phases: [Phase]
        private let makeDocument: @MainActor () -> RenderedDocument
        private var phaseIndex = 0
        private var stepIndex = 0
        private var phaseCount: Int?
        private var finished = false

        public init(phases: [Phase], finish: @escaping @MainActor () -> RenderedDocument) {
            self.phases = phases
            self.makeDocument = finish
        }

        public var isComplete: Bool {
            advancePastSpentPhases()
            return phaseIndex >= phases.count
        }

        private func advancePastSpentPhases() {
            while phaseIndex < phases.count {
                let count = phaseCount ?? phases[phaseIndex].count()
                phaseCount = count
                if stepIndex < count { return }
                phaseIndex += 1
                stepIndex = 0
                phaseCount = nil
            }
        }

        private func runOneStep() {
            phases[phaseIndex].step(stepIndex)
            stepIndex += 1
        }

        public func renderAll() {
            while !isComplete { runOneStep() }
        }

        /// Runs steps until `deadline` (`DispatchTime` uptime nanoseconds) passes — at least one.
        public func renderNext(until deadline: UInt64) {
            guard !isComplete else { return }
            repeat {
                runOneStep()
            } while !isComplete && DispatchTime.now().uptimeNanoseconds < deadline
        }

        /// The rendered document, once every step has run. Once only.
        public func finish() -> RenderedDocument {
            precondition(isComplete, "SlicedRender: finished before the last step")
            precondition(!finished, "SlicedRender: finished twice")
            finished = true
            return makeDocument()
        }
    }

    /// `engine`: the engine's half made already, off the main thread, for `state` as it is now; nil makes it here.
    public static func modernRenderSession(_ state: DocumentState, exportFlags: ExportFlags = .allOn,
                                    engine: ModernEngineWork? = nil) -> ModernRenderSession {
        let doc = state.document
        let basis = Self.modernBasis(state)
        let size = basis.size
        let bodyFont = basis.bodyFont
        let modernFallbackFont = basis.fallbackFont
        let modernFontlessFamily = basis.fontlessFamily
        let colPt = basis.colPt
        // A GRAPHIC CELL IS SIZED BY THE PRINTED TYPE, not the Modern type. The library's
        // `modernTokenWidth` graphic branch is `spanPitch(entry, printedPt)` — the document's
        // own fixed-pitch size (`printedSize`, its `.cw`), never the Modern point size the
        // prose beside it is set in. Measured on VERSIONS.WS's bullet rows: its marker cell
        // is 7.20pt in the library (12 x 0.6) and was 8.40 here (14 x 0.6), so every one of
        // those rows started 1.20pt right of the library's and lost its last word.
        let modernPrintedPt = basis.printedPt
        // Batch 42: asked with THIS render's own flags — see `modernEngineOptions`.
        let work = engine ?? ModernEngineWork.make(
            document: doc, options: Self.modernEngineOptions(state, exportFlags: exportFlags))
        var flow = work.flow
        // b34 N1 (job 529): same collapse `modernParagraphContent`'s own citation
        // explains, applied to note/footnote text — `PDFModernLayout.swift`'s
        // `modernFlow` collapses `.note`/footnote text the identical way
        // (`sentenceSpacingTexts([text])[0]`, its own local idiom, ported verbatim
        // here), and this view's `.note`/`.noteSeparator`-driven footnote appendix reads
        // `flow.notes[...].text` at every one of its own call sites below — mutating it
        // once, here, keeps all of them in lockstep rather than needing the same call
        // repeated at each site.
        Self.modernCollapseNoteSpacing(&flow)
        let items = flow.items
        // Planning #251(c), Modern's half: the engine's own graphic-cell placements for
        // Modern, keyed by `flow.items` index — the same index the loop below enumerates.
        // Same note defaults as the `modernSemanticFlow` call above, so the two describe the
        // same flow (`ModernEngineWork.make` places them on that very flow).
        let modernGraphicCells = work.graphicCells
        let blockHangCols = Self.defListBlockHangCols(items: items, colPt: colPt)
        // Job 423 (view item d): the ACTUAL available text width, not `colPt` (one
        // monospace COLUMN's width, e.g. ~7pt — a single character cell, `modernColPt`'s
        // own doc comment). `pixDimsPt`'s "cap to the measure so an oversized image never
        // overflows" only makes sense against the real column MEASURE an image sits in;
        // passing a single character's width as that cap scaled every inline Modern image
        // down by roughly the same ratio as its real width to one column (PREVIEW.WS's
        // WORDSTAR.PIX: ~468pt wide native, capped to ~7pt — the "dash placeholder" field
        // report, intake items 15/23). Same paper/margin this function computes at its own
        // end for `textFrame` — hoisted here since it does not depend on anything the item
        // loop below produces. Batch 41 (A): the engine's page, and one COLUMN's width on a
        // columnar page, since that is the measure a paragraph and its picture sit in.
        let modernPage = Self.modernPage(state, furniture: work.furniture)
        let modernTextWidthPt: Double = max(1, Double(modernPage.measure))
        // b27 item 11: computed once, not per-line — `ModernScreenplay.detectBlocks` already
        // walks the whole document itself (same discipline the engine's own `modernFlow`
        // uses for its own `screenplayBlocks`/`screenplayMarkerBis`).
        let screenplayBlocks = ModernScreenplay.detectBlocks(doc)
        let screenplayMarkerBis = ModernScreenplay.markerCandidateBlocks(
            screenplayBlocks, blockCount: doc.blocks.count)

        let output = NSMutableAttributedString()
        var hfEvents: [HFEvent] = []
        var modernFootnoteEvents: [ModernFootnoteEvent] = []
        let blankParagraph = Self.modernParagraphStyle(colPt: colPt, size: size, align: .left,
                                                        indentCols: 0, cutCols: 0)
        // A BLANK ADVANCES BY THE LINE IT FOLLOWS, not by the document default — the
        // library's own rule, stated in `PDFModernLayout`'s paginator: `case .blank` takes
        // `let h = lastH`, where `lastH` is "the most recently placed line's own `h`,
        // falling back to the 14pt default only when nothing has been placed yet". Its own
        // comment records the measurement that produced it (PREVIEW.WS, where a blank
        // between two 24pt lines advanced by the same fixed 16.8pt a blank between a 24pt
        // and an 8pt line would).
        //
        // The app had only the fixed half. Measured on LJ6DTP.WS, whose body is 12pt: every
        // inter-paragraph gap read 14.40 + 16.80 = 31.20pt against the library's 14.40 +
        // 14.40 = 28.80 — 2.4pt of extra air per paragraph, accumulating down the page until
        // a line that fits in the library does not fit here.
        //
        // `blankParagraph` above stays as the FALLBACK (nothing placed yet, so the document
        // default is all there is) and as the annotated view's own; this tracks the rest.
        var lastParagraphPt: CGFloat = size
        // Job 423 (view item a, intake item 6): shared by the `.noteSeparator`/`.note` case
        // below AND the footnote appendix after the loop — one paragraph of note-appendix
        // text, mirroring the engine's OWN Modern renderer's convention exactly
        // (`PDFModernLayout.swift`'s `modernFlow`: Times-Roman at `modernNotePt`, 11/14 of
        // `modernBodyPt`'s 14). This app's Modern view already diverges from the engine's
        // fixed Times-Roman body font by design (the user's own chosen `modernFontName`,
        // per this file's own header on `ExportEngine`'s "documented AppKit divergence") —
        // notes keep that SAME app font, just at the engine's own relative size ratio,
        // rather than forcing Times where the body never is.
        let noteFont = basis.noteFont
        let noteParagraph = basis.noteParagraph
        // Job 502: factored out of `appendNoteLine` below so the page-foot footnote block
        // (`ModernFootnoteEvent.entries`, built in the `.para` case further down) can share
        // the identical styling without `PagedDocumentView` ever needing a copy of it —
        // includes its own trailing terminator so a caller can concatenate several of these
        // and get correctly separated lines with no further attribute bookkeeping.
        func noteLineAttributedString(_ text: String) -> NSAttributedString {
            Self.modernNoteLine(text, font: noteFont, paragraph: noteParagraph)
        }
        func appendNoteLine(_ text: String) {
            output.append(noteLineAttributedString(text))
        }
        // Job 502: the SAME 20-dash rule the `.noteSeparator` case below draws for the real
        // end-of-document appendix, built once here so a page-foot footnote block
        // (`PagedDocumentView.drawFootnoteBlock`) never has its own copy of either the text
        // or the styling.
        let modernFootnoteSeparator = noteLineAttributedString(String(repeating: "-", count: 20))
        // b28 note 11 (Jon's ruling): character offset into `output`, ascending, of every
        // screenplay page-number-marker paragraph's own first character — the render-side
        // half of rule (a) (`ModernScreenplay`'s own doc comment: "Modern has no page-break
        // counterpart... noted, not silently dropped" — this is that gap closed). Captured
        // HERE, gated by the exact SAME `screenplayBlocks`/`screenplayMarkerBis` membership
        // test rule (b) already uses below, per Jon's own ruling on scope ("only supposed to
        // apply when our code detects a screenplay") — never widened to every bare numbered
        // line. `PagedDocumentView.buildPages` is the sole consumer: it forces AppKit's own
        // container chain to end just before each offset, so the marker paragraph becomes the
        // FIRST content of a new page instead of merely holding the right margin on whichever
        // page it happened to reflow onto.
        // Planning #221: the offset of the end-matter appendix's own first character, so
        // `PagedDocumentView.buildPages` can apply Jon's endnote rule against real pages.
        // `modernSemanticFlow` emits exactly one `.noteSeparator` per document, always
        // immediately before the first end-matter note, so this is written at most once —
        // the same "exactly one" guarantee the engine's own `endNotesStart` flag rests on.
        var modernEndnoteAppendixStart: Int?
        var modernForcedPageBreakOffsets: [Int] = []
        var modernBlankLineRanges: [NSRange] = []
        var modernConditionalBreaks: [ModernConditionalBreak] = []
        // Batch 41 (columns): where each flow item's own text begins in `output` — the map the engine's column
        // boundaries (`ModernColumnRange`: an item index and a UTF-16 offset into that item's own run text) are
        // resolved against once the whole text exists. `-1` for an item that contributed nothing to the view.
        var modernItemStarts = [Int](repeating: -1, count: items.count)
        // Batch 26: one flow item's work — the loop body it always was, run in order by `ModernRenderSession`.
        func renderItem(_ i: Int) {
            let item = items[i]
            // Batch 41 (columns): where this item's own text begins, whatever kind it is — the anchor every engine
            // column boundary inside it is resolved from.
            if modernItemStarts.indices.contains(i) { modernItemStarts[i] = output.length }
            switch item {
            case .para(let align, let indentCols, let cutCols, let runs, let paraFootnotes, let structure, let isVerse, let bi):
                // b27 item 11: Jon's screenplay ruling, Modern's own port (see
                // `ModernScreenplay`'s own doc comment for the rule and the
                // internal-to-CtrlKD reason this can't just call the engine's detector).
                // b28 note 11: rule (a) (a page-number marker starts a new PAGE) DOES now
                // have a Modern counterpart — `modernForcedPageBreakOffsets` below records
                // where, and `PagedDocumentView.buildPages` is what actually forces AppKit's
                // container chain to break there (this loop itself still makes no page
                // decision; it only tells the view WHERE one belongs).
                var effectiveAlign = align
                var isScreenplaySceneNumberLine = false
                var isScreenplayPageMarkerLine = false
                if screenplayBlocks.contains(bi) || screenplayMarkerBis.contains(bi) {
                    let visible = runs.filter { $0.ref == nil }.map(\.text).joined()
                    if ModernScreenplay.matchesPageMarker(visible) {
                        // Rule (b): the page-number marker renders flush against the
                        // right margin, not left-aligned.
                        effectiveAlign = .right
                        // b28 note 11, rule (a): this SAME line also starts a new Modern
                        // page — captured below, at the point this paragraph's own first
                        // character actually lands in `output` (after any leading spacer).
                        isScreenplayPageMarkerLine = true
                    } else if screenplayBlocks.contains(bi),
                              ModernScreenplay.matchesSlugline(visible),
                              ModernScreenplay.matchesTrailingSceneNumber(visible) {
                        // Rule (c): a slugline carrying its own right-hand scene number
                        // must never wrap that number onto its own line.
                        isScreenplaySceneNumberLine = true
                    }
                }
                // THE LINE'S OWN TYPE SIZE SETS ITS OWN LEADING, which is what the engine
                // does: `let sizes = vline.map { sized($0.styles, $0.pt).points }` and
                // `h = modernLine * sizes.max()`. This passed the DOCUMENT's body size for
                // every paragraph, so a 72pt banner advanced 16.80pt instead of 86.40 —
                // LJ6DTP.WS's two title lines sit 172.80 apart in the library and sat 33.60
                // apart here, and the page then held 20 lines against the library's 11.
                //
                // Per PARAGRAPH rather than per wrapped line, which is as fine as an AppKit
                // paragraph style can express it: identical wherever a paragraph is one size
                // (every case in this corpus that moved), and it over-leads rather than
                // under-leads a wrapped mixed-size paragraph, which is the safe direction —
                // the engine's own figure is the max on the line.
                //
                // EVERY run counts, including one with no font block of its own: the
                // library's `sizes` is `vline.map { sized($0.styles, $0.pt).points }` and
                // `$0.pt` for a fontless token is `modernBodyPt` — the document size — not
                // an absence. Skipping those (`compactMap` to `nil`, which this did) let a
                // paragraph whose only LETTERED run sat in a 12pt Courier block lead at
                // 14.40 while the library, counting the fontless space token beside it at
                // 14, led at 16.80. Measured on -README.WS: one such row per file-name
                // block, 2.4pt each, and the page then held a line the library's did not.
                let paragraphFace = Self.modernParagraphFace(
                    runs: runs, fonts: doc.fonts, size: size,
                    fontlessFamily: modernFontlessFamily)
                let paragraphPt = CGFloat(paragraphFace.pt)
                let (paragraphSpans, paragraph) = Self.modernParagraphContent(
                    align: effectiveAlign, indentCols: indentCols.value, cutCols: cutCols.value,
                    runs: runs,
                    structure: structure, colPt: colPt, size: paragraphPt, font: bodyFont,
                    blockHangCols: blockHangCols[i], isVerse: isVerse,
                    fonts: doc.fonts, printedPt: modernPrintedPt,
                    tightFamily: paragraphFace.family)
                // b28 note 9: a graphic (box-drawing) row immediately followed by ANOTHER
                // graphic row must sit at its natural line advance, no inter-paragraph gap —
                // see `modernParagraphStyle`'s own `paragraphSpacing` comment for the bug this
                // closes (every Modern paragraph got the SAME 0.35em space-after unconditionally,
                // which turns a box's continuous vertical rule into a dashed line, one dash per
                // row). `paragraphSpacing` is a space-AFTER property, so the row ABOVE a
                // boundary owns that boundary's gap: an ordinary prose paragraph immediately
                // above or below a box is untouched by this check and keeps its own normal
                // spacing — the box's leading gap (owned by the prose above it) and its
                // trailing gap (owned by the box's OWN last row, since that row's next
                // neighbour isn't graphic) both survive; only a graphic-to-graphic pair loses
                // its gap.
                if Self.paraContainsGraphicChar(item), i + 1 < items.count, Self.paraContainsGraphicChar(items[i + 1]) {
                    paragraph.paragraphSpacing = 0
                }
                let measureWidthPt = max(1, modernTextWidthPt - indentCols.value * colPt - cutCols.value * colPt)
                let renderSpans = Self.joinOversizedTokens(
                    Self.runBoundaryBreaks(
                        isScreenplaySceneNumberLine
                            ? ModernScreenplay.collapseSceneNumberGap(paragraphSpans)
                            : paragraphSpans),
                    font: modernFallbackFont, fonts: doc.fonts, defaultSize: Int(size),
                    measurePt: measureWidthPt)
                if isScreenplaySceneNumberLine {
                    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: CGFloat(measureWidthPt))]
                }
                // Planning #251(c)/#254, Modern's half: `attachGraphicCellsModern` states
                // this item's own cp437 cells with the widths the library gives them, and
                // pinning each character's advance to its own is what stops the app measuring
                // a rule in the reading face's advances.
                //
                // -README is the case. Its 65-character `═` rule measures 644.73pt in Mac
                // Times against a 468pt column; on the document's own fixed-pitch cell it is
                // 65 columns ending flush at the measure, which is where the library draws
                // it. (The engine had to be fixed first: before #254 Modern advanced a
                // graphic cell by the READING size, putting that rule's last cell's right
                // edge at 982.00 on a 612pt sheet — the model was faithful to a writer that
                // was drawing off the page.)
                // A PICTURE IS A PAGE-SPACE COST, NOT A LEADING.
                //
                // Every other Modern line is clamped to the library's own `modernLine * pt`
                // (`modernParagraphStyle`), and a picture's line inherited that clamp: the
                // attachment is 73.90pt tall on -README.WS and its fragment was 16.80, so the
                // image overflowed its own line and the page gained the difference — page 1
                // held 17 lines against the library's 14, and `PDFModernLayout` says the rule
                // outright ("the image's own height is a page-space cost, not a leading").
                //
                // The clamp is replaced rather than lifted: an unclamped fragment would take
                // AppKit's own idea of the attachment's line height, and the figure that has
                // to match is the library's own `pixDimsPt` height.
                if exportFlags.pictures,
                   let pixIndex = Self.modernPixIndex(of: renderSpans, pixResults: state.pixResults) {
                    let (_, pixHeightPt) = pixDimsPt(state.pixResults[pixIndex],
                                                     measureWidthPt: measureWidthPt)
                    if pixHeightPt > 0 {
                        paragraph.lineHeightMultiple = 0
                        paragraph.minimumLineHeight = CGFloat(pixHeightPt)
                        paragraph.maximumLineHeight = CGFloat(pixHeightPt)
                    }
                }
                var line = nativePinGraphicCells(
                    attributedLine(
                        coalesce(PageLine(renderSpans)).spans,
                        font: modernFallbackFont,
                        paragraph: paragraph,
                        fonts: doc.fonts,
                        defaultSize: Int(size),
                        useCourierPrime: true,
                        pixResults: exportFlags.pictures ? state.pixResults : [],
                        pixMeasureWidthPt: measureWidthPt,
                        modernPitchScale: true, modernPrintedPt: modernPrintedPt,
                        modernFontlessFamily: modernFontlessFamily
                    ),
                    placements: modernGraphicCells[i] ?? [])
                // Job 437 (b27 item 10): a tight (verse/centered) paragraph that actually
                // word-wraps must render at NORMAL leading throughout — see
                // `modernLineWraps`'s own doc comment. `paragraph` still needs to carry the
                // correction going forward (`modernLeadingSpacer`/`lineTerminator` below
                // both read it), and `line` must be rebuilt: `NSAttributedString` copies an
                // `NSParagraphStyle` attribute value at set-time, so mutating `paragraph`
                // after `line` already exists would NOT change `line`'s own baked-in style.
                if paragraph.lineHeightMultiple > 0,
                   Self.modernLineWraps(line, width: CGFloat(measureWidthPt)) {
                    // Planning #222 (b): backing `tight` off has to RESTORE THE BODY'S
                    // leading, not merely remove the compression. Clearing the multiple used
                    // to be enough because the body's own leading was AppKit's natural
                    // metric, so "no attribute" and "normal body leading" were the same
                    // thing. They are not any more: the body is pinned to the library's
                    // 1.2x, and a bare `= 0` left this paragraph at AppKit's natural 16.0
                    // against a 16.8 body — job 437's ruling read literally as the number it
                    // happened to produce, instead of as the RELATION it states (a
                    // soft-wrapped continuation gets the body's leading, whatever that is).
                    paragraph.lineHeightMultiple = 0
                    let restored = paragraphPt * Self.modernLibraryLineFactor
                    paragraph.minimumLineHeight = restored
                    paragraph.maximumLineHeight = restored
                    line = attributedLine(
                        coalesce(PageLine(renderSpans)).spans,
                        font: modernFallbackFont,
                        paragraph: paragraph,
                        fonts: doc.fonts,
                        defaultSize: Int(size),
                        useCourierPrime: true,
                        pixResults: exportFlags.pictures ? state.pixResults : [],
                        pixMeasureWidthPt: measureWidthPt,
                        modernPitchScale: true, modernPrintedPt: modernPrintedPt,
                        modernFontlessFamily: modernFontlessFamily
                    )
                }
                // b28 note 9 (part 2, found verifying the recon): BOXES.WS's rows are
                // classified `isVerse` (the engine's own consecutive-short-lines heuristic —
                // a box reads exactly like a stanza's shape), which makes EVERY row `tight`
                // (`modernParagraphStyle`'s `tight: align == .center || isVerse`) — and a tight
                // row whose real glyph ink rises above the compressed line box triggers job
                // 434's own leading-spacer headroom mechanism (`modernLeadingSpacer`,
                // `modernAscentDeficit`), independently of `paragraphSpacing`. Measured directly
                // building this fix: box-drawing glyphs DO report a positive ascent deficit
                // against the tight line height, so the spacer fires between every row even
                // after the `paragraphSpacing` suppression above — closing only the
                // `paragraphSpacing` half left a real, measured ~5pt gap between rows, still a
                // visible dash, not the continuous rule Jon asked for. `modernLeadingSpacer`'s
                // own headroom purpose (reserving room for an oversized TITLE's ascender) does
                // not apply to box-drawing content the same way, so the same "preceded by
                // another graphic row" test used above suppresses it here too.
                let precededByGraphicRow = i > 0
                    && Self.paraContainsGraphicChar(items[i - 1]) && Self.paraContainsGraphicChar(item)
                // b28 note 11: recorded BEFORE the leading spacer (if any) — the spacer, when
                // present, is this SAME paragraph's own headroom and must move to the new page
                // with it, not stay stranded as trailing blank canvas on the page before. Job
                // 502: `modernFootnoteEvents` (below) uses this SAME offset for the SAME reason
                // — a footnote attached to this paragraph belongs on whichever real page this
                // paragraph's own leading canvas lands on, not on some later page a mid-
                // paragraph marker glyph happens to wrap onto.
                let paragraphCharOffset = output.length
                if isScreenplayPageMarkerLine,
                   output.length > 0, modernForcedPageBreakOffsets.last != output.length {
                    // The SAME guard the `.pageBreak` case below carries, and the same one
                    // the engine states outright: `if pageMarker, !body.isEmpty { close() }`
                    // — "a marker that is already the first thing on a fresh page (an
                    // explicit `.pa` DID precede it, SCRIPT.WS's own shape) costs nothing
                    // extra; `close()` on an empty page would just insert a spurious blank
                    // one". Without it SCRIPT.WS's own `.pa`-then-marker pair recorded TWO
                    // breaks at the same offset: the `.pa` opened the page, the marker broke
                    // it again, and the marker sat alone on a page of its own — measured, a
                    // 16th page against the library's 15, with one line on it.
                    modernForcedPageBreakOffsets.append(output.length)
                }
                if !precededByGraphicRow, let spacer = Self.modernLeadingSpacer(
                    for: line, paragraph: paragraph, bodyFont: bodyFont, face: paragraphFace) {
                    // A SPACER TRAVELS WITH THE LINE IT RESERVES ROOM FOR. The library
                    // spends it as part of the first visual line's own advance (`h += spacer`
                    // before the page-fit test), so a paragraph pushed to the next page takes
                    // its headroom with it. Here it is a paragraph of its own, and AppKit will
                    // happily end a page on it: measured on -README.WS page 19, whose "FOR
                    // MORE INFORMATION" heading needs 3.70pt of headroom — the spacer fitted
                    // at the foot of page 18, the heading did not, and page 19 then opened
                    // 3.70pt high and held a line the library's page did not.
                    //
                    // Expressed as the `.cp` machinery's own conditional break, which is
                    // exactly the engine's test read at a real page: unless the room left
                    // below the spacer holds BOTH the spacer and the line, the page breaks
                    // before the spacer.
                    let spacerHeight = (spacer.attribute(.paragraphStyle, at: 0,
                                                         effectiveRange: nil)
                                        as? NSParagraphStyle)?.maximumLineHeight ?? 0
                    modernConditionalBreaks.append(
                        ModernConditionalBreak(
                            charOffset: output.length,
                            needPt: Double(spacerHeight + paragraph.maximumLineHeight)))
                    output.append(spacer)
                }
                output.append(Self.modernBulletGapCell(line, structure: structure))
                output.append(lineTerminator(font: bodyFont, paragraph: paragraph))
                // The leading a following `.blank` inherits (see `lastParagraphPt`'s own
                // comment). Recorded here, where a real text line has actually been placed —
                // the engine writes its own `lastH` at exactly the same point, and
                // deliberately NOT in its `.image` case, because an image's height is a
                // page-space cost and not a leading.
                lastParagraphPt = paragraphPt
                // Job 502 (Jon's ruling, 2026-08-25: footnotes sit at the page FOOT, dash-
                // separated, like Printed — job 490 item 1 got the right PAGE and the wrong
                // PLACE). This paragraph's own footnote text no longer joins `output` inline —
                // `PagedDocumentView.buildPages` is the one place Modern's REAL pages exist
                // (AppKit decides where they break, this function's own top doc comment), so
                // it is the one place that can reserve room for a footnote block at a real
                // page's own foot and draw it there, mirroring the engine's own `modernStreams`
                // reservation (`PDFModernLayout.swift`'s `noteBlockH`/`sepH`, read at the pinned
                // engine commit 7e8ffdb — see this job's own report). `paragraphCharOffset`
                // carries job 490's still-correct "the marker's own paragraph" placement rule
                // forward to that later consumer.
                let footnoteEntries: [NSAttributedString] = paraFootnotes.compactMap { footnote in
                    guard flow.notes.indices.contains(footnote.index) else { return nil }
                    let row = flow.notes[footnote.index]
                    return noteLineAttributedString("\(Self.modernNoteEntryLabel(row.shown)) \(row.text)")
                }
                if !footnoteEntries.isEmpty {
                    modernFootnoteEvents.append(ModernFootnoteEvent(
                        charOffset: paragraphCharOffset, entries: footnoteEntries))
                }
            case .blank:
                // The author's own blank line (M4) — `attributedLine([], ...)` supplies the
                // single invisible space `lineTerminator`'s own doc comment explains blank
                // lines need to stay on the baseline grid. Its height is the last placed
                // line's own leading (`lastParagraphPt`, above).
                let thisBlank = lastParagraphPt == size
                    ? blankParagraph
                    : Self.modernParagraphStyle(colPt: colPt, size: lastParagraphPt,
                                                align: .left, indentCols: 0, cutCols: 0)
                let blankStart = output.length
                output.append(attributedLine([], font: bodyFont, paragraph: thisBlank))
                output.append(lineTerminator(font: bodyFont, paragraph: thisBlank))
                // Where this blank is, so a page that OPENS on it can drop it — see
                // `RenderedDocument.modernBlankLineRanges`.
                modernBlankLineRanges.append(
                    NSRange(location: blankStart, length: output.length - blankStart))
            case .hf(let which, let line, let text):
                // Job 393 (391 root cause 2): job 371 item 3's own comment here used to argue
                // Modern couldn't honour per-page replay because "Modern's own reflow has no
                // page-break DECISION until AppKit lays it out" — true, but that only means
                // the REPLAY has to happen later, against AppKit's own real pages, not that it
                // can't happen at all. The engine's own Modern PDF already replays every `.hf`
                // per real page (`PDFModernLayout.swift`'s `modernStreams`, ruling 2026-08-06
                // M5: "Modern keeps headers") — showing the text inline, once, additively, is
                // what actually produced job 391's bug: OLDTIMES's `.h1` sits AFTER page 1's
                // own title text, so the OLD inline placement put it on page 1 (WordStar's own
                // rule says it should apply from page 2), and POWERUSE's header never repeated
                // past whichever single page it happened to flow onto.
                //
                // No suppression logic lives here any more: this case ONLY records WHERE
                // (character offset) and WHAT changed, exactly the shape `Page.headers`/
                // `.footers`' own engine replay consumes (`curHeaders[line] = text`,
                // unconditionally, even empty — `RenderedDocument.hfEvents`'s own doc comment
                // on why an empty `text` still needs an event, not a skip). Turning this log
                // into real per-page `RunningLine`s is entirely `DocumentRenderer
                // .modernRunningLines`/`PagedDocumentView`'s job now — "consume the engine's
                // verdict," not re-derive it here.
                guard exportFlags.headers else { return }
                hfEvents.append(HFEvent(kind: which == .header ? .header : .footer,
                                        line: line, text: text, charOffset: output.length))
            case .pageBreak:
                // `.pa` BREAKS A MODERN PAGE TOO. The engine's own Modern paginator closes
                // the page on this item outright (`PDFModernLayout`'s flow loop: `case
                // .pageBreak: close()`), and this used to drop it as "a Printed-only
                // pagination decision" — true of the on-screen view before Modern was
                // answerable to the library's own Modern PDF, and false since.
                //
                // SCRIPT.WS is the case: its manuscript header block ends with an explicit
                // `.pa`, so the library's Modern page 1 closes after 21 lines with its last
                // baseline at 554.40 and a third of the sheet still empty, while the app ran
                // on to 713.80 and 28 lines — and every page after it then diffed against
                // the wrong one.
                //
                // Recorded the same way the screenplay page marker already is, at the
                // paragraph's own first character — and NOT recorded when it would open an
                // empty page. The engine guards its own marker break with `!body.isEmpty`
                // for exactly this reason: a `.pa` at the very start, or a second `.pa` with
                // nothing between it and the first, breaks a page that has nothing on it.
                // LJ6DTP.WS is the case — honouring every one of them took it from 8 pages
                // to 12 against the library's 11.
                if output.length > 0, modernForcedPageBreakOffsets.last != output.length {
                    modernForcedPageBreakOffsets.append(output.length)
                }
            case .cond(let lines):
                // `.cp` BREAKS A MODERN PAGE TOO, when the room left is less than it asks
                // for. The engine's rule is one line — `let need = Double(n) * modernLine *
                // Double(modernBodyPt); if !body.isEmpty, y - (margb + noteBlockH()) < need
                // { close() }` — and the reason this used to say "a measure this list of
                // fixed offsets cannot express" is that the measure belongs to the VIEW: only
                // `PagedDocumentView.buildPages`, laying out a real page, knows how much room
                // is left at a given character. So the offset and the requirement are
                // recorded here and the test is made there, the same division of labour
                // `modernFootnoteEvents` already uses.
                //
                // Measured on -README.WS: its "Configuration options for vDosPlus are set in
                // these two files:" paragraph asks for room its page does not have, and the
                // library moves it whole to page 8 while the app started it at 690.60 on
                // page 7 — one line's drift that then showed on every page to 21.
                guard output.length > 0 else { return }
                modernConditionalBreaks.append(
                    ModernConditionalBreak(
                        charOffset: output.length,
                        needPt: Double(lines) * Double(Self.modernLibraryLineFactor)
                            * Double(Self.modernLibraryBodyPt)))
            case .tabs:
                // Editor-time state with no rendered consequence on either side — the
                // engine's own `modernFlow` says so.
                return
            case .noteSeparator:
                // Job 423 (view item a, intake item 6): the endnote/annotation/comment
                // appendix was absent from the on-screen Modern view since job 263 (scope
                // was font identity/paragraph fidelity, not this) — closed here. Job 490
                // item 1: footnotes no longer join this appendix — they emit inline, right
                // after their own marker's paragraph, in the `.para` case above (see that
                // case's own citation). This separator/loop now serves ONLY real endnotes/
                // annotations/comments, which stay a true end-of-document appendix by
                // WordStar's own convention (`modernSemanticFlow`'s own `endRows` doc
                // comment: "flowing, not bottom-anchored").
                // Planning #221: recorded BEFORE appending — this is the appendix's own
                // first character, the same anchor `modernFootnoteEvents` and
                // `modernForcedPageBreakOffsets` both use (a paragraph's own first
                // character, never the offset after it).
                modernEndnoteAppendixStart = output.length
                appendNoteLine(String(repeating: "-", count: 20))
            case .note(_, _, let label, let text):
                // b34 N1 (job 529): unlike the footnote path above, `text` here is
                // `SemanticItem.note`'s OWN snapshot (`Layout.swift`'s `modernSemanticFlow`
                // copies `noteRows[ni].text` in at item-construction time, before this
                // function ever sees `flow`) — mutating `flow.notes` above never reaches
                // it, so the same collapse is applied again, right here, at the one place
                // this specific copy is read.
                appendNoteLine("\(Self.modernNoteEntryLabel(label)) \(sentenceSpacingTexts([text])[0])")
            }
        }

        // Batch 26: everything after the last item, run once by `ModernRenderSession.finish()` (`final`) — and,
        // batch 27, on a copy of the text so far for `snapshot()`.
        func document(final: Bool) -> RenderedDocument {
        let flowText = final ? output : NSMutableAttributedString(attributedString: output)
        markModernSquareBullets(flowText)
        if flowText.length > 0 { flowText.deleteCharacters(in: NSRange(location: flowText.length - 1, length: 1)) }

        // The PAPER is the app's own — whatever the bottom bar's Page control reports; the
        // MARGINS inside it are the file's (`modernTextFrame`, which carries the whole
        // reasoning including the back-solve this replaced). Unlike Printed there is no
        // independent PDF baseline to check against: Modern's own PDF export
        // (`ExportEngine.modernPDF`) draws this SAME `textFrame` through the native text
        // stack, so screen and export can only ever agree or disagree together.
        // Batch 41 (A): the engine's own sheet and frame (`modernPage`), a hand-picked Page size aside.
        let paper = modernPage.paper
        let textFrame = modernPage.textFrame

        var document = RenderedDocument(
            text: flowText,
            pageSize: paper,
            // Page count is AppKit's to decide once it has flowed the text; the view layer
            // grows containers until the text is consumed and reports the real number. One
            // is the floor so an empty document still shows a blank page.
            textFrame: textFrame,
            pageCount: 1,
            clipsLines: false,
            // Modern's `modernSemanticFlow` already reflowed WordStar's own wrap away — no
            // physical soft-return left to mark, and this plain path never runs while Show
            // Invisibles is on anyway (`renderWithInvisibles` calls `renderModernAnnotated`
            // instead, job 294).
            softLineFlags: [],
            // Overprint is Printed-only too — Modern has no `PageLine`s at all, so there is
            // no `.overprint` flag to chain.
            overprintPasses: [],
            oversizedSelfPasses: [],
            // No passes to align in Modern style — see `RenderedDocument.baselineOffset`'s
            // own doc comment.
            baselineOffset: 0,
            // No oversized self-passes to reserve room for either (job 396) — same reason.
            leadingHeadroom: [],
            // Empty here, not Printed-only any more (job 393): Modern's real per-page running
            // lines can't be built until AppKit has laid the flow out — `hfEvents` below is
            // what carries the replay log to the caller that CAN, `PagedDocumentView`.
            runningLines: [],
            hfEvents: hfEvents,
            pageNumberStart: doc.page?.pnStart ?? 1,
            // Modern has one AppKit-grown page, no library pagination to anchor against.
            realPageIndexByPage: [0],
            // Job 412 (Jon's ruling): Modern is reflowed by design — explicitly NOT pinned.
            pinnedBaselines: [:],
            // Job 427: Modern has no per-page margin concept (Jon's own ruling scopes
            // geometry unification to Printed/Native only — Modern is the app's own page,
            // not the file's, see this function's own doc comment above) — one flat, shared
            // anchor. `PagedDocumentView.textTop(atPage:)` falls back to this same value for
            // every page beyond this array's single placeholder entry (Modern's real page
            // count isn't known until AppKit lays the flow out).
            perPageTextTop: [Double(textFrame.origin.y)],
            pinnedPageBottoms: [], pinnedPageTops: [], flowTopAdjustment: 0, pageColumnFragmentCounts: [], lineNumberPasses: [], graphicCellRows: [],
            // b28 note 11: the ascending list this loop just built above — the sole
            // non-empty producer of this field (see `RenderedDocument
            // .modernForcedPageBreakOffsets`'s own doc comment).
            modernForcedPageBreakOffsets: modernForcedPageBreakOffsets,
            // Job 502: the per-paragraph footnote log this loop just built above — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: modernFootnoteEvents,
            modernFootnoteSeparator: modernFootnoteSeparator,
            modernEndnoteAppendixStart: modernEndnoteAppendixStart,
            // Modern has no `PageLine`/paper-facsimile concept — see `RenderedDocument
            // .pclPrograms`'s own doc comment.
            pclPrograms: []
        )
        // `var`, so it is assigned rather than passed — see its own doc comment.
        document.modernBlankLineRanges = modernBlankLineRanges
        document.modernConditionalBreaks = modernConditionalBreaks
        document.modernFurniture = work.furniture
        let furnitureFonts = Self.modernFurnitureFonts(doc, bodyFallback: modernFallbackFont, bodySize: size)
        document.modernFurnitureFont = furnitureFonts.font
        document.modernHeaderFonts = furnitureFonts.headers
        document.modernFooterFonts = furnitureFonts.footers
        // The flags this render was asked for, carried so the view can honour them where the furniture's
        // running lines are drawn — see `RenderedDocument.exportFlags`.
        document.exportFlags = exportFlags
        document.modernItemStarts = modernItemStarts
        document.modernColumnBreaks = Self.modernColumnBreaks(
            furniture: work.furniture, items: items, itemStarts: modernItemStarts, text: flowText.string)
        return document
        }
        return ModernRenderSession(itemCount: items.count, renderItem: renderItem,
                                   textLength: { output.length }, document: document)
    }
}
