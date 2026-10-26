import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared
import PDFKit
import UniformTypeIdentifiers

/// Turning a document into files.
///
/// Shared by the Export As sheet and the Batch window so the two cannot drift: one
/// document, one set of formats, one naming rule, one place where "Modern PDF is the
/// exception" is written down.
@MainActor
enum ExportEngine {

    // MARK: - Rendering

    /// Render `document` to every requested format, in `style` — defaulting to `state`'s own
    /// current style ("export what you see") but overridable (job 244 Leg 3's Export panel
    /// Style control) WITHOUT mutating `state` itself, since for the Export As sheet `state`
    /// is the live, on-screen window's document and a mutate-then-restore would flicker it.
    ///
    /// Four of the five go straight to the library's own emitters. **PDF is the documented
    /// divergence**: the library's zero-dependency PDF writer renders Courier only, which
    /// is right for a literal Printed export (a typescript facsimile IS Courier) and wrong
    /// for Modern (whose whole purpose is the user's chosen reading face) — so Modern PDF
    /// goes through the native macOS text stack instead, via `appKitRenderedPDF`.
    ///
    /// Job 313A (Jon's ruling 2026-08-14, "you would expect to get the same thing you are
    /// looking at"): PDF has a THIRD case, keyed off `viewStyle` rather than `style` — when
    /// the caller passes the document's actual on-screen/current-default `ViewStyle` and it
    /// is `.native`, PDF export reuses the exact same `appKitRenderedPDF` route as Modern
    /// (the print path — `DocumentWindowController.makePrintOperation`'s own render call),
    /// just under `RenderStyle.native`'s facsimile pass instead of Modern's reflow. This is
    /// deliberately separate from `style`: `style` still only ever carries `printed`/`modern`
    /// (RenderStyle stays two-case for every other format, per its own doc comment — Native
    /// truly has no export format of its own there), so a caller that does not know or care
    /// about "what view is this" (batch/scripting callers exporting a synthetic, never-shown
    /// `DocumentState`) simply omits `viewStyle` and gets the pre-313 behavior unchanged.
    /// Job 373 (b24 FLAG UI): `headers`/`toc`/`inlineStyling`/`pictures` are the four
    /// export-sheet per-export controls, defaulting to Settings' own values (RULED: headers
    /// ON, TOC OFF, inline styling ON, Pictures Embed) for callers that never chose otherwise
    /// (the Batch window, and every existing test) — the Export As sheet itself always passes
    /// explicit values straight from `ExportAccessoryView`'s controls, which THEMSELVES
    /// initialize from Settings, per the "initializes from Settings, never writes back" rule.
    /// Job 520 (N5, b33 page-numbering UI): `pageNumbers` joins them the same way, defaulting
    /// to `SettingsStore.shared.defaultPageNumbers`. Threaded into `options.pageNumbers`
    /// below, which only the library's own PDF emitter (`convertData`'s `format == .pdf`
    /// branch below) consults — `appKitRenderedPDF` (Modern/Native-view PDF) does not take
    /// it, the same disclosed gap `lineNumbers`/`styles`/`fontsTarget`/`noteRefs` already have
    /// (see that function's own doc comment).
    /// Job 521 (N9, b33 sentence-spacing UI): `sentenceSpacing` joins them too, but — per
    /// Jon's ruling (export surfaces + AppleScript, deliberately no Settings item) — defaults
    /// to the plain literal `.auto` rather than a `SettingsStore.shared` read, the same
    /// no-Settings-backing shape `lineNumbers`/`styles`/`fontsTarget` already have. Threaded
    /// into `options.sentenceSpacing` below, which every one of the library's own emitters
    /// consults (`EmitOptions.sentenceSpacing`'s own doc comment: "in every format") — but
    /// `appKitRenderedPDF` (Modern/Native-view PDF) does NOT take it, the same disclosed gap
    /// `pageNumbers`/`lineNumbers`/`styles`/`fontsTarget`/`noteRefs` already have: that route
    /// renders through `DocumentRenderer`/`ExportFlags`, the app's own on-screen text stack,
    /// which never calls into the library's `sentenceSpacingSpans`/`sentenceSpacingTexts` at
    /// all (see that function's own doc comment).
    static func render(
        document: CtrlKD.Document,
        state: DocumentState,
        formats: [ExportFormat],
        notes: NoteSelection,
        style: RenderStyle? = nil,
        viewStyle: ViewStyle? = nil,
        title: String = "",
        docPath: String = "",
        headers: Bool = SettingsStore.shared.defaultHeaders,
        toc: Bool = SettingsStore.shared.defaultTOC,
        inlineStyling: Bool = SettingsStore.shared.defaultInlineStyling,
        pictures: EmitOptions.PixMode = SettingsStore.shared.defaultPictures,
        pageNumbers: EmitOptions.PageNumberMode = SettingsStore.shared.defaultPageNumbers,
        sentenceSpacing: EmitOptions.SentenceSpacingMode = .auto
    ) throws -> [ExportProduct] {
        try ExportCore.render(
            document: document, state: state, formats: formats, notes: notes,
            style: style, viewStyle: viewStyle, title: title, docPath: docPath,
            choices: ExportChoices(
                headers: headers, toc: toc, inlineStyling: inlineStyling, pictures: pictures,
                pageNumbers: pageNumbers, sentenceSpacing: sentenceSpacing)
        ) { pdfStyle, options in
            try appKitRenderedPDF(state: state, style: pdfStyle, options: options)
        }
    }

    /// PDF through the native text stack rather than the library's own zero-dependency
    /// writer — `DocumentRenderer.render` + a throwaway `PagedDocumentView`, the SAME
    /// construction `DocumentWindowController.makePrintOperation` builds for Cmd-P, so a
    /// Modern or (job 313A) Native-view PDF export can never structurally disagree with what
    /// printing that same view produces. Modern needs this because the library's PDF writer
    /// renders Courier only, which is wrong for Modern's whole purpose (the user's chosen
    /// reading face); the native-view case needs it because a literal engine PDF is not what
    /// a Native window shows (Courier Prime substitution, title faces, etc. — see job 306).
    ///
    /// Job 322 (b20): rebuilt on `NSView.dataWithPDF(inside:)` per page, one `PDFPage` at a
    /// time folded into a combined `PDFDocument` — exactly `QuickLookNativeRenderer
    /// .multiPagePDF`'s own approach, which has rendered correct-orientation multi-page PDFs
    /// (QL preview) all along. The PREVIOUS version hand-rolled a `CGPDFContext` and manually
    /// composed a flip transform (`translateBy`/`scaleBy(y: -1)`) around
    /// `displayIgnoringOpacity(_:in:)` — but that call already performs the flip its own
    /// `isFlipped` view needs internally, so the manual transform was a second, canceling
    /// flip: every export this function ever produced was upside-down, never caught because
    /// job 313's own regression test (`ExportPDFPrintPathEvidence.printPathPDFBytes`)
    /// reimplemented the identical broken transform and compared it against itself. Never
    /// hand-roll this transform again — `dataWithPDF(inside:)` is the AppKit primitive that
    /// already gets a flipped view's page geometry right; reach for it before reaching for
    /// `CGPDFContext` directly.
    /// Job 375 item C2 (b24 completion): `options` — previously ignored entirely, so none of
    /// the four export-sheet flags (job 373) had any effect on a Modern or Native-view PDF
    /// export — now gates this path the same way the library's own emitters gate it.
    /// `headers`/`pictures` thread into `DocumentRenderer.render` via `ExportFlags`, which
    /// defaults every OTHER caller (the live document window, `makePrintOperation`,
    /// `QuickLookNativeRenderer`) to unchanged "everything on" behavior — only an export can
    /// ask for less. `toc` is handled entirely here, by rendering a second small document
    /// and appending its pages, since neither `renderModern` nor `renderNative` has any TOC
    /// concept to gate. `inlineStyling` is a disclosed gap — see this function's own doc
    /// comment below.
    private static func appKitRenderedPDF(state: DocumentState, style: RenderStyle? = nil,
                                          options: EmitOptions = EmitOptions()) throws -> [UInt8] {
        let exportFlags = DocumentRenderer.ExportFlags(
            headers: options.headers, pictures: options.pictures != .off, inlineStyling: options.inlineStyling)
        let rendered = DocumentRenderer.render(state, style: style, exportFlags: exportFlags)
        let view = PagedDocumentView.laidOut(rendered)
        let combined = PDFDocument()
        for page in try capturedPages(of: view) {
            combined.insert(page, at: combined.pageCount)
        }
        if options.toc, let tocPages = try tocIndexPages(state: state, pageSize: rendered.pageSize,
                                                         textFrame: rendered.textFrame) {
            for page in tocPages { combined.insert(page, at: combined.pageCount) }
        }
        guard combined.pageCount > 0, let data = combined.dataRepresentation() else {
            throw ExportError.pdfContextUnavailable
        }
        return [UInt8](data)
    }

    /// A compiled TOC/Index, rendered through the SAME `PagedDocumentView` machinery as the
    /// main content, at the SAME paper/text-frame geometry — `nil` when the document has no
    /// `.tc`/`.ix` entries at all (matching every other emitter's `!doc.tocEntries.isEmpty ||
    /// !doc.indexEntries.isEmpty` gate, e.g. `PDFWriter.swift`'s own). `plainTOCIndexLines`
    /// (`TOCIndex.swift`, made `public` for this) is the SAME compiler Text/Markdown/HTML/
    /// Modern RTF already share — `pageNumbers: nil`, honest text and ordering only: a real
    /// page number here would name a page against THIS export's own AppKit pagination, which
    /// no engine paginator can predict (Modern reflows to the reader's own font/size choice;
    /// even Printed's facsimile pagination is a SEPARATE model from `emitPDF`'s). Same
    /// no-page-numbers choice Modern RTF's own TOC already makes for the identical reason.
    private static func tocIndexPages(state: DocumentState, pageSize: CGSize, textFrame: CGRect) throws -> [PDFPage]? {
        guard let lines = TOCPageSpec.lines(for: state.document) else { return nil }

        let size = CGFloat(TOCPageSpec.fontSize)
        let bodyFont = NSFont(name: TOCPageSpec.bodyFontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let headingFont = NSFont(name: TOCPageSpec.headingFontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = CGFloat(TOCPageSpec.paragraphSpacing)
        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacing = CGFloat(TOCPageSpec.paragraphSpacing)
        headingParagraph.alignment = .center

        // PINNED PAPER MEANS PINNED INK (Jon's rule, 2026-08-24): `TOCPageSpec.ink`, never
        // `NSColor.textColor`, which is white in Dark Mode. macos/scripts/check-pinned-colors.sh
        // enforces this.
        let ink = NSColor(srgbRed: CGFloat(TOCPageSpec.ink.red), green: CGFloat(TOCPageSpec.ink.green),
                          blue: CGFloat(TOCPageSpec.ink.blue), alpha: 1)
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: line.isHeading ? headingFont : bodyFont,
                .paragraphStyle: line.isHeading ? headingParagraph : paragraph,
                .foregroundColor: ink,
            ]
            output.append(NSAttributedString(string: index == lines.count - 1 ? line.text : line.text + "\n",
                                             attributes: attributes))
        }

        let rendered = RenderedDocument(
            text: output, pageSize: pageSize, textFrame: textFrame, pageCount: 1, clipsLines: false,
            softLineFlags: [], overprintPasses: [], oversizedSelfPasses: [], baselineOffset: 0,
            leadingHeadroom: [],
            runningLines: [], hfEvents: [], pageNumberStart: 1, realPageIndexByPage: [],
            // Job 412: a synthesized TOC/Index page, reflowed like Modern — not pinned.
            pinnedBaselines: [:],
            // Job 427: same flat, shared anchor as Modern's own construction — no per-page
            // margin concept for a synthesized page.
            perPageTextTop: [Double(textFrame.origin.y)], pinnedPageBottoms: [], pinnedPageTops: [], flowTopAdjustment: 0, pageColumnFragmentCounts: [], lineNumberPasses: [], graphicCellRows: [],
            // b28 note 11: a synthesized TOC/Index page has no screenplay-marker concept —
            // see `RenderedDocument.modernForcedPageBreakOffsets`'s own doc comment.
            modernForcedPageBreakOffsets: [],
            // Job 502: a synthesized TOC/Index page has no footnotes of its own either — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            modernEndnoteAppendixStart: nil,
            // Job 490: a synthesized TOC/Index page has no `Document.pclPrograms` concept
            // either — see `RenderedDocument.pclPrograms`'s own doc comment.
            pclPrograms: [])
        return try capturedPages(of: PagedDocumentView.laidOut(rendered))
    }

    /// Every page of `view` with any area, as PDFKit pages; a page whose capture will not open fails the export.
    private static func capturedPages(of view: PagedDocumentView) throws -> [PDFPage] {
        try (0..<max(1, view.pageCount)).compactMap { index in
            guard let capture = view.pagePDF(at: index) else { return nil }
            guard let page = PDFDocument(data: capture.data)?.page(at: 0) else {
                throw ExportError.pdfContextUnavailable
            }
            return page
        }
    }

    // MARK: - Writing

    /// Write exactly `url` — the ONE URL a save panel handed back.
    static func writeSingle(_ product: ExportProduct, to url: URL) throws {
        try Data(product.bytes).write(to: url, options: .atomic)
    }

    // MARK: - Save-panel extension enforcement (job 244 Leg 1)

    /// What to hand `NSSavePanel.allowedContentTypes` for the currently-checked formats: a
    /// single type when exactly one format is checked, so the OS appends/enforces THAT
    /// extension into the URL it grants back (`performSingleExport`/`writeSingle` then write
    /// exactly that URL — no reconstruction, per the sandbox-file-writes packet). Two or more
    /// formats route through the folder/`ExportNaming.write(_:to:basename:)` path instead, whose own
    /// per-product extension already applies unconditionally — an empty array there means "no
    /// restriction," matching the panel's un-pinned default.
    static func singleFormatContentTypes(for formats: [ExportFormat]) -> [UTType] {
        guard formats.count == 1 else { return [] }
        return [formats[0].contentType]
    }
}
