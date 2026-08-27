import AppKit
import CtrlKD

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

        let view = PagedDocumentView()
        view.setContent(rendered, display: .singlePage)
        view.frame = CGRect(origin: .zero, size: rendered.pageSize)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: rendered.pageSize)
        image.addRepresentation(rep)
        return image
    }

    /// The Get-Info-style rows, in the spec's fixed order: File Name / Kind / Size / Where /
    /// Created / Modified / Page Size / Pages.
    static func info(for url: URL, style: RenderStyle, variant: Variant?) -> [(String, String)] {
        // Best-effort metadata read with a sound default: `byteText`/`dateText` below both
        // render a nil value as "—" rather than failing the whole info panel over one
        // missing attribute.
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let state = state(for: url, style: style, variant: variant)

        let kind: String
        if let detected = state?.variant.value {
            kind = Self.variantKind(detected)
        } else {
            kind = "Unreadable"
        }

        let pageSizeText: String
        if let named = state?.pageSize.value {
            pageSizeText = named.dimensionDescription
        } else if let page = state?.document.page {
            // A real geometry with no app-side name: report the truth rather than force a
            // label onto it.
            pageSizeText = String(format: "%.2f in tall (custom)", page.heightIn)
        } else {
            pageSizeText = "—"
        }

        let pageCount: String
        if let state {
            pageCount = "\(DocumentRenderer.render(state, style: style).pageCount)"
        } else {
            pageCount = "—"
        }

        return [
            ("File Name", url.lastPathComponent),
            ("Kind", kind),
            ("Size", byteText(values?.fileSize)),
            ("Where", url.deletingLastPathComponent().path),
            ("Created", dateText(values?.creationDate)),
            ("Modified", dateText(values?.contentModificationDate)),
            ("Page Size", pageSizeText),
            ("Pages", pageCount),
        ]
    }

    private static func variantKind(_ variant: Variant) -> String {
        switch variant {
        case .ws4:         return "WordStar 4 document"
        case .ws5plus:     return "WordStar 5+ document"
        case .printstream: return "WordStar print stream"
        case .text:        return "Plain text"
        case .binary:      return "Not a document"
        }
    }

    private static func byteText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
