import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

/// Page-one thumbnails and the Get-Info rows for the batch window's preview column.
///
/// Goes through the same `DocumentRenderer` the document window uses, so a preview cannot
/// show something the real render would not — a preview that lies is worse than no preview
/// when the whole point is deciding whether a conversion looks right before running thirty
/// of them.
@MainActor
enum PagePreviewRenderer {

    /// Parsed state for a file, or nil if it cannot be read. Small enough to redo on
    /// selection changes; a cache would need invalidating on every settings change and is
    /// not worth it at preview sizes. A read/parse failure here is genuinely ignorable: the
    /// caller's `info(for:...)`/`firstPage(of:...)` both already degrade to placeholders
    /// ("Unreadable", "—", a nil image) instead of a wrong preview — this is informational,
    /// the actual per-item export failure surfaces separately through `BatchModel.run`.
    private static func state(for url: URL, style: RenderStyle, variant: Variant?) -> DocumentState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? DocumentState(data: [UInt8](data), settings: .shared, docPath: url.path)
        else { return nil }
        // A forced-variant failure here leaves `state.variant.value` at whatever DID parse
        // (never silently relabeled) — `info(for:...)` reads that same property, so the
        // preview stays self-consistent with what it is actually showing even when the
        // user's forced variant couldn't be honored.
        if let variant { state.setVariant(variant) }
        // `style` here is the export-facing axis (job 265's `RenderStyle`, unchanged); a
        // batch preview is never shown in Native, so this is a straight projection onto the
        // window's own three-case `ViewStyle` — see `RenderStyle.viewStyle`.
        state.style.setManually(style.viewStyle)
        return state
    }

    /// The first page, drawn at preview scale with the correct aspect.
    static func firstPage(of url: URL, style: RenderStyle, variant: Variant?) -> NSImage? {
        guard let state = state(for: url, style: style, variant: variant) else { return nil }
        let rendered = DocumentRenderer.render(state, style: style)

        return PagedDocumentView.laidOut(rendered).pageImage(at: 0)
    }

    /// The Get-Info-style rows, in the spec's fixed order: File Name / Kind / Size / Where /
    /// Created / Modified / Page Size / Pages.
    static func info(for url: URL, style: RenderStyle, variant: Variant?) -> [(String, String)] {
        info(for: url, state: state(for: url, style: style, variant: variant), style: style)
    }

    /// The same rows for a document already open, read from its window's own state — so its
    /// Margins choice is in the Page Size and Pages the rows report (#271 M9).
    static func info(for url: URL, state: DocumentState?, style: RenderStyle) -> [(String, String)] {
        // The unreadable case keeps every row, each honestly "—" (Kind says "Unreadable").
        let kind = state?.variant.value.kindName ?? "Unreadable"
        // The sheet Printed lays out, so a landscape document reads landscape (#271 M9).
        let pageSize = state?.pageSizeDescription ?? DocumentInfo.none
        let pages = state.map { "\(DocumentRenderer.render($0, style: style).pageCount)" } ?? DocumentInfo.none
        return DocumentInfo.fileRows(
            url: url, kind: kind, location: url.deletingLastPathComponent().path,
            pageSize: pageSize, pages: pages
        ).map { ($0.label, $0.value) }
    }
}
