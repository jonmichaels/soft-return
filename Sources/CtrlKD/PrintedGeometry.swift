/// Printed-mode page metrics, in PostScript points, as a public value.
///
/// WHY THIS FILE EXISTS: the figures below already existed as `printedTop`/`printedLead`/
/// `printedSize`/`printedLeft`/`printedCap`/`resolvedPageHeight` (PDFLayout.swift), but
/// internal to this module — they were written as the PDF emitter's private arithmetic.
/// Soft Return.app renders the same Printed page to the SCREEN and must place text at
/// exactly the coordinates `emitPDF` would, or a document looks one way on screen and
/// another way exported. A second copy of `.mt`/`.lh`/`.cw`/`.po` semantics in the app is
/// the failure mode this avoids: two derivations of WordStar's dot commands that can
/// silently drift apart.
///
/// So this is a FAÇADE, deliberately: it computes nothing itself, it only calls the
/// existing helpers and names the result. Every formula still lives in exactly one place
/// (PDFLayout.swift). Nothing in this file is modified when the emitter's arithmetic
/// changes — it re-exports whatever the emitter now says.
///
/// Pair it with `docToPagelines(printedDocument(doc, options: options), printed: true)`
/// (both public), which supplies the laid-out lines this describes the geometry for —
/// `printedDocument` because a `.pr or=l` document is laid out on its ROTATED page, and
/// handing `docToPagelines` the raw `doc` anchors its running content to the wrong sheet.
public struct PrintedPageMetrics: Hashable, Sendable {
    /// Paper width, in points — the file's own `.pl`-derived `pwIn`, which is 612 (8.5in)
    /// for every PORTRAIT document, because WordStar has no page-WIDTH dot command and
    /// every named size it resolves shares an 8.5in width (see `namedPageSizes`,
    /// ParseWS.swift).
    ///
    /// ⚠️ NOT a constant. A document that declares `.pr or=l` is rotated for Printed
    /// (`landscapePage`, PDFLayout.swift): sawyer/REF/BOOKLET.RJS (`.pr or=l`, `.pl 8.5"`)
    /// is a 792x612 page, and its `pageHeight`/`capacity` are the SHORT edge's. This field
    /// hard-coded `PDFMetrics.pageWidth` until planning #271 M2 (2026-09-13) and the app's
    /// Native view drew every landscape document on a portrait sheet because of it.
    public let pageWidth: Double
    /// Paper height, from the file's `.pl` (via `heightIn`), or 11in when it declared none.
    public let pageHeight: Double
    /// Distance from the TOP of the paper down to the TOP OF THE FIRST LINE, from `.mt`.
    ///
    /// ⚠️ NOT the first baseline. `emitPDF` places the first baseline at `top + size`
    /// (`PDFWriter.swift`: `var y = Double(pageHeight - top - size)`) because PDF's `Td`
    /// positions a baseline, not a line's top edge. A caller that treats this as a baseline
    /// puts every line one type-size too high.
    ///
    /// Corrected 2026-08-03. The previous wording said "first text baseline" and was wrong;
    /// Soft Return.app was written from it and placed Printed text a full 12pt line high,
    /// and the app's own geometry oracle was written from the same sentence, so it AGREED
    /// with the bug and could not see it. Two independent things wrong from one comment.
    public let top: Double
    /// Baseline-to-baseline distance, from `.lh` — the document DEFAULT, which is the file's
    /// FIRST `.lh` and what page capacity is computed at.
    ///
    /// ⚠️ `.lh` is stateful (2026-08-05). A line set at a different leading carries its own
    /// in `Line.lead48`, and `emitPDF` advances by that instead; `PageGeometry.lhVaries` is
    /// true when any line does. A caller laying out pages itself must read the per-line value
    /// or a multi-`.lh` document will render as it did before the fix — 72pt banners stacked
    /// on a 14pt lead. A LEAD IS THE SPACE ABOVE ITS LINE, not below it.
    public let lead: Double
    /// Type size in whole points, from `.cw`. Courier advances 0.6em, so the character
    /// pitch this implies is `Double(size) * 0.6` — the figure a monospace grid needs.
    public let size: Int
    /// Left edge of the text column, from `.po` — the DOCUMENT DEFAULT only (the file's
    /// first `.po`), exactly like `lead` above. It resolves `.po` alone and CANNOT carry a
    /// per-page `.poe`/`.poo` (even/odd offset, planning #231) or a line's own `.po`
    /// override (register b31) — both are stateful per-line/per-page facts this
    /// document-wide struct has no room for. A caller that needs the real per-page-or-line
    /// left edge (running heads split by page parity, a body line after a mid-document
    /// `.po`/`.poe`/`.poo`) must read it off the laid-out `PageLine.left` instead — this
    /// field is only the fallback a line without its own override inherits.
    public let left: Double
    /// Text lines per page — the capacity `docToPagelines` paginates against.
    public let capacity: Int

    public init(
        pageWidth: Double,
        pageHeight: Double,
        top: Double,
        lead: Double,
        size: Int,
        left: Double,
        capacity: Int
    ) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.top = top
        self.lead = lead
        self.size = size
        self.left = left
        self.capacity = capacity
    }

    /// Horizontal advance per character: Courier's 0.6em at this document's type size.
    /// The width of an N-column line is `charWidth * N`.
    public var charWidth: Double { Double(size) * 0.6 }
}

/// The document `emitPDF` lays out in Printed mode: `options.pageSettings` folded in, then
/// the `.pr or=l` landscape rotation on top of it — exactly the two steps, in exactly the
/// order, `emitPDF` opens with (they share one implementation, `resolvedGeometryDocument`
/// in PDFLayout.swift; neither this file nor the emitter writes that order down twice).
///
/// A caller that lays out pages itself must paginate THIS document, not the one it parsed:
/// `docToPagelines(printedDocument(doc), printed: true)`. Line CAPACITY does not move with
/// the rotation (it is `.pl` - `.mt` - `.mb`, a line count), but everything anchored off
/// the page's own HEIGHT does: the running head/foot and automatic page number
/// (`attachHeadFootLinesPrinted`), the note area's bottom-anchor arithmetic
/// (`layoutPrintedPages`), and the text measure a `.PIX` is fitted to (`printedTextWidthPt`,
/// off `pwIn`). Handing `docToPagelines` the parsed document instead puts those in the
/// wrong place — measurably, and in the same direction, for every landscape document.
///
/// `printedMetrics` below describes this same document's geometry; the two always agree
/// because both start here. Modern mode does not rotate (ruled 2026-08-06, "the page is the
/// document's declared size") — see `landscapePage`'s own comment — so there is no
/// `modernDocument` companion: Modern reads `doc` as parsed.
public func printedDocument(_ doc: Document,
                            options: EmitOptions = EmitOptions()) -> Document {
    resolvedGeometryDocument(doc, printed: true, options: options)
}

/// The Printed-mode geometry `emitPDF` would use for this document.
///
/// Every value delegates to the emitter's own helper, over `printedDocument(doc,
/// options:)` — the same rotated/overridden document the emitter lays out (planning #271
/// M2). See the type's doc comment for why this file recomputes nothing.
///
/// `options` defaults to `EmitOptions()`, so an existing call site that passes nothing
/// keeps the geometry it had for every document that declares no `.pr or=l`; pass the SAME
/// options the export will use, or a `--page-settings` preset moves the exported page out
/// from under the screen's.
public func printedMetrics(_ doc: Document,
                           options: EmitOptions = EmitOptions()) -> PrintedPageMetrics {
    let doc = printedDocument(doc, options: options)
    let typeSize = printedSize(doc)
    return PrintedPageMetrics(
        // `emitPDF`'s own MediaBox width, verbatim (PDFWriter.swift): the page's resolved
        // `pwIn`, which `landscapePage` has already swapped for a landscape document.
        pageWidth: Double(roundHalfToEven((doc.page?.pwIn ?? 8.5) * 72.0)),
        pageHeight: Double(resolvedPageHeight(doc, printed: true)),
        top: Double(printedTop(doc)),
        lead: printedLead(doc),
        size: typeSize,
        left: printedLeft(doc, size: typeSize),
        capacity: printedCap(doc)
    )
}

/// The same metrics for ONE PAGE of a document whose sheet changes mid-file (M31).
///
/// `printedMetrics` above answers for the DOCUMENT: its `pageWidth`/`pageHeight` are the
/// one sheet `doc.formatting.orientation` describes. Since M31 that is no longer the whole
/// answer — `.pr or=l`/`.pr or=p` is resolved PER PAGE (see `orCheckpoints`), and a page
/// whose own orientation differs from the document's prints on a different sheet, which is
/// exactly what `emitPDF` writes into that page's MediaBox.
///
/// So a caller drawing a specific page — the app's Printed and Native views, which place
/// text at the coordinates `emitPDF` would — must ask for THAT page's metrics, not the
/// document's, or a landscape page inside a portrait document is drawn on a portrait sheet
/// and clipped exactly as the exported PDF used to be. Pass the `Page` that
/// `docToPagelines(printedDocument(doc, options: options), printed: true)` handed back.
///
/// A page that never changes orientation (`Page.orientation == nil`, which is every page
/// of nearly every document) answers exactly what `printedMetrics(doc)` answers — the same
/// values, from the same helpers — so a caller may use this unconditionally. Nothing here
/// computes anything of its own: same façade rule as the rest of this file.
///
/// Only the SHEET moves. `top`/`lead`/`size`/`left`/`capacity` are `.mt`/`.lh`/`.cw`/`.po`
/// and are the document's, exactly as before — `landscapePage`'s own rule is that a
/// rotation changes the canvas and never re-interprets the margins, which is what real
/// WordStar's driver-level rotation did too.
public func printedMetrics(_ doc: Document, page: Page,
                           options: EmitOptions = EmitOptions()) -> PrintedPageMetrics {
    let base = printedMetrics(doc, options: options)
    guard let pageOr = page.orientation,
          let sheet = printedDocument(doc, options: options).page else { return base }
    let eff = pageGeometryFor(sheet, orientation: pageOr)
    return PrintedPageMetrics(
        pageWidth: Double(roundHalfToEven(eff.pwIn * 72.0)),
        pageHeight: Double(printedPageHeightPt(eff)),
        top: base.top, lead: base.lead, size: base.size,
        left: base.left, capacity: base.capacity)
}

/// The Modern-mode equivalent: the fixed page the reflowing layout targets.
///
/// Modern mode deliberately does NOT match the original page — 1in margins on US Letter,
/// always (see `PDFMetrics`, and `emitPDF`'s mode split). It is exposed in the same shape
/// so a caller can size a window from one type regardless of which style is showing.
/// `size`/`lead` here are the LIBRARY's Courier figures; the app substitutes the user's
/// chosen font and size for on-screen Modern and for its own native-text-stack PDF export,
/// which is the divergence the build spec calls out by design.
public func modernMetrics(_ doc: Document) -> PrintedPageMetrics {
    PrintedPageMetrics(
        pageWidth: Double(PDFMetrics.pageWidth),
        pageHeight: Double(resolvedPageHeight(doc, printed: false)),
        top: Double(PDFMetrics.topModern),
        lead: Double(PDFMetrics.lead),
        size: PDFMetrics.size,
        left: Double(PDFMetrics.margin),
        capacity: PDFMetrics.linesModern
    )
}
