#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

/// Batch 26 (#271 M7): the engine's half of a Native render — the document `emitPDF` lays out, its
/// metrics, and `docToPagelines`' pages — with no AppKit in it, so a window can have it made off the
/// main thread and hand it to `DocumentRenderer.nativeRenderSession(_:exportFlags:engine:)`.
public struct NativeEngineWork: Sendable {
    public let doc: Document
    public let metrics: PrintedPageMetrics
    public let pages: [Page]
    /// Batch 47 (M31-app): each page's own sheet (`printedMetrics(_:page:options:)`).
    public var sheets: [CGSize] = []

    /// `options`: `DocumentRenderer.nativeEngineOptions`; `pictures`: the export flag of that name.
    public nonisolated static func make(document: Document, options: EmitOptions, pictures: Bool) -> NativeEngineWork {
        // Job 371 item 1 (PIX IN VIEWS): the pictures resolved when the document was opened ride in
        // `options`; with `.embed` `docToPagelines` substitutes a resolved `.PIX` tag's own `PageLine`,
        // sized exactly as `emitPDF`'s Printed PDF sizes it.
        var doc = printedDocument(document, options: options)
        var pages = docToPagelines(doc, printed: true, pixResults: pictures ? options.pixResults : [], pictures: .embed)
        doc.fonts = laserjetFixedPitches(doc.fonts, driver: doc.printerDriver)
        nativeResolveAlternateFont(&doc, &pages)
        return NativeEngineWork(doc: doc, metrics: printedMetrics(document, options: options), pages: pages,
                                sheets: nativeSheets(document, pages: pages, options: options))
    }
}

/// A ^PA span with no font run of its own prints in the printer's alternate font
/// (`printerAlternateFont`: Gothic PC 10 pt at 14.29 cpi on a WS7 LASERJET document), which is
/// not one of the document's own fonts. It joins Native's copy of the font list and those
/// spans point at it, so every Native path resolves it the way it resolves any font block.
nonisolated func nativeResolveAlternateFont(_ doc: inout Document, _ pages: inout [Page]) {
    guard let alt = printerAlternateFont(doc) else { return }
    let index = doc.fonts.count
    var used = false
    for p in pages.indices {
        for l in pages[p].lines.indices {
            for s in pages[p].lines[l].spans.indices
            where pages[p].lines[l].spans[s].styles.contains(.altFont) && pages[p].lines[l].spans[s].font == nil {
                pages[p].lines[l].spans[s].font = index
                used = true
            }
        }
    }
    if used { doc.fonts.append(alt) }
}

/// Batch 47 (M31-app): every page's own sheet, as `emitPDF` writes each page's MediaBox — `printedMetrics(_:page:options:)`
/// for the original document and the page `docToPagelines(printedDocument(...), printed: true)` gave.
public nonisolated func nativeSheets(_ document: Document, pages: [Page], options: EmitOptions) -> [CGSize] {
    pages.map { page in
        let metrics = printedMetrics(document, page: page, options: options)
        return CGSize(width: metrics.pageWidth, height: metrics.pageHeight)
    }
}

/// Batch 27: the engine's half of Native's Show Invisibles render — the printed document, its metrics, its
/// annotated layout and its pages — made off the main thread by a window and handed to
/// `DocumentRenderer.nativeAnnotatedRender(_:engine:)`.
public struct NativeAnnotatedEngineWork: Sendable {
    public let doc: Document
    public let metrics: PrintedPageMetrics
    public let annotated: AnnotatedDocument
    public let pages: [Page]
    public var sheets: [CGSize] = []

    public nonisolated static func make(document: Document, options: EmitOptions) -> NativeAnnotatedEngineWork {
        var doc = printedDocument(document, options: options)
        var pages = docToPagelines(doc, printed: true)
        doc.fonts = laserjetFixedPitches(doc.fonts, driver: doc.printerDriver)
        nativeResolveAlternateFont(&doc, &pages)
        return NativeAnnotatedEngineWork(doc: doc, metrics: printedMetrics(document, options: options),
                                         annotated: annotatedLayout(doc), pages: pages,
                                         sheets: nativeSheets(document, pages: pages, options: options))
    }
}

/// Batch 26 (#271 M7): the engine's half of a Modern render — `modernSemanticFlow` and the graphic cells
/// placed on it — made off the main thread by a window and handed to `DocumentRenderer.modernRenderSession`.
public struct ModernEngineWork: Sendable {
    public let flow: SemanticFlow
    public let graphicCells: [Int: [PageLine.GraphicCellPlacement]]
    /// Batch 41 (A): the engine's Modern page furniture — made here, off the main thread, because it runs the Modern
    /// emitter itself.
    public let furniture: [ModernPageFurniture]

    /// `options`: `DocumentRenderer.modernEngineOptions` — the page-settings preset and Page Numbers the Modern export
    /// uses, made on the main thread by the caller.
    public nonisolated static func make(document: Document, options: EmitOptions) -> ModernEngineWork {
        let flow = modernSemanticFlow(document)
        // The same notes and references the flow was made with, so the engine places the cells on this flow
        // instead of deriving it a second time (`semCached`).
        return ModernEngineWork(flow: flow, graphicCells: attachGraphicCellsModern(
            document, notes: EmitOptions.defaultNotes, noteRefs: .word, semCached: flow),
            furniture: modernPageFurniture(document, options: options))
    }
}

/// `font`'s face at `size`. AppKit's `NSFont(descriptor:size:)` can fail and UIKit's never does, so the callers' fallback
/// only ever applies on the Mac.
func fontResized(_ font: NSFont, to size: CGFloat) -> NSFont? {
    #if os(iOS)
    UIFont(descriptor: font.fontDescriptor, size: size)
    #else
    NSFont(descriptor: font.fontDescriptor, size: size)
    #endif
}
