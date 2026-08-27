import AppKit
import CtrlKD
import PDFKit
import UniformTypeIdentifiers

/// Turning a document into files.
///
/// Shared by the Export As sheet and the Batch window so the two cannot drift: one
/// document, one set of formats, one naming rule, one place where "Modern PDF is the
/// exception" is written down.
@MainActor
enum ExportEngine {

    /// What one export produced.
    struct Product {
        let format: ExportFormat
        let bytes: [UInt8]
    }

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
    /// just under `RenderStyle.printed`'s facsimile pass instead of Modern's reflow. This is
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
    ) throws -> [Product] {
        var products: [Product] = []
        // "Export what you see": Native and Printed both mean a Printed-FAMILY export (job
        // 265 — Native has no export FORMAT of its own for RTF/HTML/MD/text), Modern maps
        // straight across. See `ViewStyle.renderStyle`. PDF alone also consults `viewStyle`
        // below, for the native-view print-path carve-out (job 313A).
        let effectiveStyle = style ?? state.style.value.renderStyle
        let mode = effectiveStyle.emitMode
        // The footer's Page Settings choice (job 203), threaded the same way `sr
        // --page-settings` and `DocumentOperations.convert` already do: `EmitOptions
        // .pageSettings` is read by `emitPDF` alone, so carrying it into every format's
        // options is harmless for the four that ignore it and is exactly what makes a
        // Printed-mode PDF export match the on-screen page (`DocumentRenderer.renderPrinted`
        // applies the SAME preset before laying anything out).
        //
        // `title` goes straight into `EmitOptions.title` (`<title>` in HTML) — job 270:
        // every caller here previously left it at the bare `""` default, unlike
        // `DocumentOperations.convert`'s other two real call sites (`ConvertCommand`,
        // `WSDocument+Scripting`, the Convert intent), which already pass the file's own
        // basename. The oracle (`sr`'s own `Run.swift`) always titles with the file's own
        // stem, so a titleless export silently diverged from it — invisibly, since only HTML
        // renders `title` into its bytes.
        var options = notes.emitOptions(title: title, pageSettings: state.pageSettingsPreset.value?.settings)
        options.headers = headers
        options.toc = toc
        options.inlineStyling = inlineStyling
        options.pictures = pictures
        options.pageNumbers = pageNumbers
        options.sentenceSpacing = sentenceSpacing
        // Resolved once per document, reused across every requested format — same
        // "resolve once, reuse" contract `DocumentOperations.convert` follows. See
        // `DocumentPictures.resolve`'s own doc comment for why this can't be the engine's
        // `resolveDocumentPictures` directly.
        options.pixResults = DocumentPictures.resolve(document, docPath: docPath)

        for format in formats {
            if format == .pdf && effectiveStyle == .modern {
                products.append(Product(format: .pdf,
                                        bytes: try appKitRenderedPDF(state: state, style: style, options: options)))
                continue
            }
            if format == .pdf && viewStyle == .native {
                // Not `style`/`nil` here — `effectiveStyle` is already known `.printed` (the
                // `.modern` case returned above), and the native-view carve-out always means
                // the FACSIMILE pass (`RenderStyle.printed`), the same one
                // `makePrintOperation` renders for a Native window.
                products.append(Product(format: .pdf,
                                        bytes: try appKitRenderedPDF(state: state, style: .printed, options: options)))
                continue
            }
            let bytes = try convertData(
                state.data, to: format.libraryFormatName, mode: mode, options: options)
            products.append(Product(format: format, bytes: bytes))
        }
        return products
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
    /// and appending its pages, since neither `renderModern` nor `renderPrinted` has any TOC
    /// concept to gate. `inlineStyling` is a disclosed gap — see this function's own doc
    /// comment below.
    private static func appKitRenderedPDF(state: DocumentState, style: RenderStyle? = nil,
                                          options: EmitOptions = EmitOptions()) throws -> [UInt8] {
        let exportFlags = DocumentRenderer.ExportFlags(
            headers: options.headers, pictures: options.pictures != .off, inlineStyling: options.inlineStyling)
        let rendered = DocumentRenderer.render(state, style: style, exportFlags: exportFlags)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        let combined = PDFDocument()
        for index in 0..<max(1, view.pageCount) {
            let rect = view.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            try autoreleasepool {
                let onePageData = view.dataWithPDF(inside: rect)
                guard let onePagePDF = PDFDocument(data: onePageData), let page = onePagePDF.page(at: 0) else {
                    throw ExportError.pdfContextUnavailable
                }
                combined.insert(page, at: combined.pageCount)
            }
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
        let doc = state.document
        guard !doc.tocEntries.isEmpty || !doc.indexEntries.isEmpty else { return nil }
        let lines = plainTOCIndexLines(doc)
        guard !lines.isEmpty else { return nil }

        let bodyFont = NSFont(name: "Georgia", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let headingFont = NSFont(name: "Georgia-Bold", size: 14) ?? NSFont.boldSystemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 14 * 0.35
        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacing = 14 * 0.35
        headingParagraph.alignment = .center

        let output = NSMutableAttributedString()
        for line in lines {
            let isHeading = line == "TABLE OF CONTENTS" || line == "INDEX"
            let font = isHeading ? headingFont : bodyFont
            let style = isHeading ? headingParagraph : paragraph
            // PINNED PAPER MEANS PINNED INK (Jon's rule, 2026-08-24). This page is
            // drawn on the same pinned-white paper as the main content, so the ink
            // must be pinned too -- `NSColor.textColor` is not a colour, it is a
            // promise to be WHITE in Dark Mode, which is how b28 shipped with its
            // Modern notes invisible. tools/check-pinned-colors.sh enforces this.
            output.append(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
                .font: font, .paragraphStyle: style, .foregroundColor: NSColor.black,
            ]))
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: font, .paragraphStyle: style, .foregroundColor: NSColor.black,
            ]))
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }

        let rendered = RenderedDocument(
            text: output, pageSize: pageSize, textFrame: textFrame, pageCount: 1, clipsLines: false,
            softLineFlags: [], overprintPasses: [], oversizedSelfPasses: [], baselineOffset: 0,
            leadingHeadroom: [],
            runningLines: [], hfEvents: [], pageNumberStart: 1, realPageIndexByPage: [],
            // Job 412: a synthesized TOC/Index page, reflowed like Modern — not pinned.
            pinnedBaselines: [:],
            // Job 427: same flat, shared anchor as Modern's own construction — no per-page
            // margin concept for a synthesized page.
            perPageTextTop: [Double(textFrame.origin.y)], pinnedPageBottoms: [],
            // b28 note 11: a synthesized TOC/Index page has no screenplay-marker concept —
            // see `RenderedDocument.modernForcedPageBreakOffsets`'s own doc comment.
            modernForcedPageBreakOffsets: [],
            // Job 502: a synthesized TOC/Index page has no footnotes of its own either — see
            // `RenderedDocument.modernFootnoteEvents`'s own doc comment.
            modernFootnoteEvents: [],
            modernFootnoteSeparator: NSAttributedString(),
            // Job 490: a synthesized TOC/Index page has no `Document.pclPrograms` concept
            // either — see `RenderedDocument.pclPrograms`'s own doc comment.
            pclPrograms: [])
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()

        var pages: [PDFPage] = []
        for index in 0..<max(1, view.pageCount) {
            let rect = view.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            try autoreleasepool {
                let onePageData = view.dataWithPDF(inside: rect)
                guard let onePagePDF = PDFDocument(data: onePageData), let page = onePagePDF.page(at: 0) else {
                    throw ExportError.pdfContextUnavailable
                }
                pages.append(page)
            }
        }
        return pages
    }

    // MARK: - Writing

    /// Write exactly `url` — the ONE URL a save panel handed back.
    static func writeSingle(_ product: Product, to url: URL) throws {
        try Data(product.bytes).write(to: url, options: .atomic)
    }

    /// Write products beside each other in `directory`, under `basename`.
    ///
    /// Returns the URLs actually written, which may differ from the obvious ones: a
    /// collision is uniquified, never overwritten.
    @discardableResult
    static func write(_ products: [Product], to directory: URL, basename: String,
                      fileManager: FileManager = .default) throws -> [URL] {
        var written: [URL] = []
        for product in products {
            let name = uniqueName(
                basename: basename, extension: product.format.fileExtension,
                in: directory, fileManager: fileManager)
            let url = directory.appendingPathComponent(name)
            try Data(product.bytes).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    // MARK: - Naming

    /// Finder's own collision rule: "PAPER.md", then "PAPER 2.md", "PAPER 3.md" — a space
    /// and a number, never an overwrite. The spec fixes both the format and the
    /// never-overwrite guarantee.
    ///
    /// Pure but for the existence check, which is injected, so the rule can be tested
    /// without touching a disk.
    static func uniqueName(basename: String, extension ext: String, in directory: URL,
                           fileManager: FileManager = .default) -> String {
        uniqueName(basename: basename, extension: ext) { candidate in
            fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
    }

    /// The rule itself. `exists` answers whether a candidate name is taken.
    static func uniqueName(basename: String, extension ext: String,
                           exists: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let first = basename + suffix
        guard exists(first) else { return first }
        // Finder starts at 2 — the original is "1" by implication.
        var counter = 2
        while true {
            let candidate = "\(basename) \(counter)\(suffix)"
            if !exists(candidate) { return candidate }
            counter += 1
            // A directory holding this many collisions is pathological; give up rather
            // than spin, and let the write fail with a real error the user can see.
            if counter > 10_000 { return candidate }
        }
    }

    // MARK: - Save-panel extension enforcement (job 244 Leg 1)

    /// What to hand `NSSavePanel.allowedContentTypes` for the currently-checked formats: a
    /// single type when exactly one format is checked, so the OS appends/enforces THAT
    /// extension into the URL it grants back (`performSingleExport`/`writeSingle` then write
    /// exactly that URL — no reconstruction, per the sandbox-file-writes packet). Two or more
    /// formats route through the folder/`write(_:to:basename:)` path instead, whose own
    /// per-product extension already applies unconditionally — an empty array there means "no
    /// restriction," matching the panel's un-pinned default.
    static func singleFormatContentTypes(for formats: [ExportFormat]) -> [UTType] {
        guard formats.count == 1 else { return [] }
        return [formats[0].contentType]
    }
}

/// Which note kinds travel into the export.
///
/// Four checkboxes in the UI, one `Set<NoteKind>` to the library. The defaults are the
/// library's own `EmitOptions.defaultNotes` — footnotes, endnotes and annotations on,
/// comments off — because WordStar never printed a comment either. The batch window's
/// checkbox stack mirrors exactly this.
struct NoteSelection: Equatable {
    var footnotes = true
    var endnotes = true
    var annotations = true
    var comments = false

    /// The kinds as the library wants them.
    var kinds: Set<NoteKind> {
        var kinds: Set<NoteKind> = []
        if footnotes { kinds.insert(.footnote) }
        if endnotes { kinds.insert(.endnote) }
        if annotations { kinds.insert(.annotation) }
        if comments { kinds.insert(.comment) }
        return kinds
    }

    /// `fontsTarget` is pinned to `.mac` unconditionally (Jon's ruling 2026-08-11: "We are ON
    /// A MAC! There is only Mac mapping" — mistake-registry #24). The library's per-target
    /// tables exist for the CLI, whose caller chooses; every app-surface export call goes
    /// through here, so the app never surfaces the library's `.office` default (Univers →
    /// Arial) the way b12's RTF field evidence showed.
    func emitOptions(title: String = "", pageSettings: PageSettings? = nil) -> EmitOptions {
        EmitOptions(title: title, notes: kinds, fontsTarget: .mac, pageSettings: pageSettings)
    }
}

enum ExportError: LocalizedError {
    case pdfContextUnavailable

    var errorDescription: String? {
        switch self {
        case .pdfContextUnavailable:
            return "Couldn’t create a PDF for this document."
        }
    }
}
