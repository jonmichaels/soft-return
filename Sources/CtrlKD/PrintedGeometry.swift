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
/// Pair it with `docToPagelines(doc, printed: true)` (already public), which supplies the
/// laid-out lines this describes the geometry for.
public struct PrintedPageMetrics: Hashable, Sendable {
    /// Paper width. Constant at 612pt (8.5in): WordStar has no page-WIDTH dot command, so
    /// every named size the library resolves shares 8.5in — see `namedPageHeights`
    /// (ParseWS.swift). Exposed anyway so callers size a page from one struct rather than
    /// reaching for `PDFMetrics.pageWidth` separately and assuming they match.
    public let pageWidth: Double
    /// Paper height, from the file's `.pl` (via `heightIn`), or 11in when it declared none.
    public let pageHeight: Double
    /// Distance from the TOP of the paper down to the first text baseline, from `.mt`.
    public let top: Double
    /// Baseline-to-baseline distance, from `.lh`.
    public let lead: Double
    /// Type size in whole points, from `.cw`. Courier advances 0.6em, so the character
    /// pitch this implies is `Double(size) * 0.6` — the figure a monospace grid needs.
    public let size: Int
    /// Left edge of the text column, from `.po`.
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

/// The Printed-mode geometry `emitPDF` would use for this document.
///
/// Every value delegates to the emitter's own helper — see the type's doc comment for why
/// this file recomputes nothing.
public func printedMetrics(_ doc: Document) -> PrintedPageMetrics {
    let typeSize = printedSize(doc)
    return PrintedPageMetrics(
        pageWidth: Double(PDFMetrics.pageWidth),
        pageHeight: Double(resolvedPageHeight(doc, printed: true)),
        top: Double(printedTop(doc)),
        lead: printedLead(doc),
        size: typeSize,
        left: printedLeft(doc, size: typeSize),
        capacity: printedCap(doc)
    )
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
