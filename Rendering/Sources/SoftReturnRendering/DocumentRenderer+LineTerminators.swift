#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

extension DocumentRenderer {
    // MARK: - Line terminators and the first baseline

    /// A newline carrying the SAME font and paragraph style as the line it ends.
    ///
    /// An unattributed `"\n"` takes the system default font and default paragraph style. On
    /// a line that carries text this mostly does not show, because the run's own attributes
    /// govern the fragment. On a BLANK line the newline is the only character there is, so
    /// the whole line becomes system-height — roughly 15-17pt instead of the document's 12pt
    /// lead. Every blank line then pushes the rest of the page down, the baseline grid breaks
    /// at the first one, and a page consumes more than `capacity * lead` points.
    ///
    /// A document that opens with blank lines — the dropped-chapter shape — is the worst
    /// case, and `dropped-chapter.ws4` exists to hold this fixed.
    static func lineTerminator(font: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            // Job 478 audit: same white-paper/dynamic-colour class as the note-entry
            // defect this job fixes. A "\n" control character paints no visible glyph
            // regardless of colour, so this was never the VISIBLE bug — but it shares
            // every caller (renderNative and both Modern renderers) with attributed
            // runs that DO paint ink, so fixed here too rather than left as a dynamic
            // colour sitting on paper waiting for AppKit to someday give it ink.
            .foregroundColor: NSColor.black,
        ])
    }

    /// How far below a line fragment's top edge AppKit will put the first baseline, for this
    /// font and paragraph style.
    ///
    /// Measured by laying out one glyph and asking the layout manager, rather than computed
    /// from `ascent` or from the lead. With a fixed line height (min == max) the figure is a
    /// function of both the font and that height, and AppKit is the only authority on the
    /// result — deriving it by hand is what produced a 3pt error on every document.
    static func firstBaselineOffset(
        font: NSFont, paragraph: NSParagraphStyle, width: CGFloat
    ) -> CGFloat {
        let storage = NSTextStorage(string: "X", attributes: [
            .font: font, .paragraphStyle: paragraph,
        ])
        let manager = softReturnLayoutManager()
        manager.allowsNonContiguousLayout = false
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return font.ascender }
        return manager.location(forGlyphAt: 0).y
    }

    /// Job 412: `firstBaselineOffset`'s own technique (lay it out, ask the layout manager,
    /// never derive by hand), generalized to REAL content instead of a fixed "X" placeholder
    /// — the isolated baseline-from-fragment-top offset (`K`) for one specific fragment's
    /// own real text/paragraph style, used only by `RenderedDocument.pinnedPageBottoms` to
    /// size a page's real container correctly (see that field's own doc comment for why a
    /// page's last fragment needs its OWN measured `K`, not a shared/assumed one).
    static func isolatedFragmentK(_ content: NSAttributedString, width: CGFloat) -> Double {
        let storage = NSTextStorage(attributedString: content)
        let manager = softReturnLayoutManager()
        manager.allowsNonContiguousLayout = false
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return 0 }
        return Double(manager.location(forGlyphAt: 0).y)
    }

    /// Job 413: how far `Oracle.structuralBodyLines`' own sampled position for this line
    /// (`NativeStructuralParityTests.swift` — the FIRST non-whitespace glyph's real
    /// `location(forGlyphAt:)`) will be pulled off this line's own pinned grid target by
    /// that glyph's `.sup`/`.sub` visual raise, and therefore how much needs folding into
    /// `PinnedBaseline.y` (never into `engineY`'s own running per-page accumulator) to
    /// cancel it. 0 when the first non-whitespace span carries neither.
    ///
    /// Root cause (DARKNESS.WS's own footnote-marker residual, job 412's disclosed "not
    /// further diagnosed" gap): a fragment whose OWN first content is a raised run — e.g. a
    /// standalone `.fnref` marker line — has its ONE sampled glyph physically shifted by
    /// `attributedRun`'s own `scriptMetrics` call (a real `.baselineOffset` ATTRIBUTE on
    /// that glyph, distinct from the FRAGMENT-level `baselineOffset` OUT-PARAM `PagedDocument
    /// View`'s delegate controls). Pinning the fragment's own unraised reference exactly on
    /// the grid (job 412's original mechanism) is therefore not what lands the OBSERVED,
    /// raised glyph on the grid — it lands `scriptMetrics`'s own offset SHORT of it, every
    /// time, which is exactly the constant-looking residual job 412 measured and did not
    /// chase further.
    ///
    /// This is the SAME split the engine's own emitter already makes (the brief's own
    /// citation — see `PDFWriter.sized`, `CtrlKD` source): a raised/lowered span's `rise` is
    /// a `Ts` PDF operator applied WITHIN a line whose own `Td` (position) never moves for
    /// it — the LINE anchors to the grid, the GLYPH moves within it. Reusing `scriptMetrics`
    /// itself (rather than measuring the shift via a fresh isolated AppKit layout pass, the
    /// way `isolatedFragmentK` does elsewhere in this file) is deliberate: this value must
    /// equal EXACTLY what `attributedRun` bakes into the real glyph's own attribute — not a
    /// separately-measured approximation of it — for the two to cancel with no residual.
    /// `scriptMetrics` is pure font-metrics arithmetic (`NSFont.ascender`, no layout pass,
    /// no window), so both this figure and the value it cancels are already
    /// process-independent — computing it this way rather than asking AppKit to lay
    /// anything out is what makes it exact rather than merely close, unlike `isolatedFragmentK`'s
    /// own well-known ~1pt isolated-vs-in-context slop (job 408).
    static func firstGlyphRaiseCompensation(
        _ line: PageLine, fallback: NSFont, fonts: [FontChange], defaultSize: Int, useCourierPrime: Bool
    ) -> Double {
        // THE FIRST GLYPH'S OWN SPAN, whitespace included — this compensates for what a
        // raised or lowered FIRST GLYPH does to AppKit's own fragment placement, so a line
        // whose first glyph is an ordinary unraised space needs no compensation at all
        // whatever the run after it does.
        //
        // Skipping whitespace was the bug. SUB-SUPE.TST line 4 opens with five plain 12pt
        // spaces and then a 9pt `.sub` run: the first non-whitespace span is the lowered one,
        // so the whole fragment was shifted up by its 0.74pt offset, putting the line's own
        // baseline at 155.26 where the library puts it at 156.00 and its lowered ink at
        // 156.00 where the library draws it at 156.74. Nothing about that line's first glyph
        // was raised; only the run after it was.
        guard let span = line.spans.first(where: { !$0.text.isEmpty }),
              span.styles.contains(.sup) || span.styles.contains(.sub) else { return 0 }
        let font = resolvedFont(for: span, fallback: fallback, fonts: fonts,
                                defaultSize: defaultSize, useCourierPrime: useCourierPrime)
        // Mechanism G: this probe is Printed-only (its one caller is inside `renderNative`),
        // so it must measure the SAME reduced face the real run gets — otherwise the
        // compensation it folds into the line's own leading is computed off a 2/3 face while
        // the glyph is drawn at WordStar's ratio, and the raise it corrects for is wrong by
        // the difference.
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        let ratio = nativeFamilyIsCourier(entry)
            ? nativeSupSubCourierRatio : nativeSupSubDefaultRatio
        // #271 M1: the LAID-OUT offset only. The rest of Printed's roll is added when the glyphs
        // are drawn (`.nativeScriptRise`), which moves no fragment and so needs no compensation.
        return Double(scriptMetrics(for: font, raise: span.styles.contains(.sup),
                                    ratio: ratio).offset)
    }
}
