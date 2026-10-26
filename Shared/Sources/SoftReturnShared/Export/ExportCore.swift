import CtrlKD
import Foundation

/// What one export produced.
public struct ExportProduct: Sendable {
    public let format: ExportFormat
    public let bytes: [UInt8]

    public init(format: ExportFormat, bytes: [UInt8]) {
        self.format = format
        self.bytes = bytes
    }
}

public enum ExportError: LocalizedError {
    case pdfContextUnavailable

    public var errorDescription: String? {
        switch self {
        case .pdfContextUnavailable:
            return "Couldn’t create a PDF for this document."
        }
    }
}

/// Which note kinds travel into the export.
///
/// Four checkboxes in the UI, one `Set<NoteKind>` to the library. The defaults are the
/// library's own `EmitOptions.defaultNotes` — footnotes, endnotes and annotations on, comments
/// off — because WordStar never printed a comment either.
public struct NoteSelection: Equatable, Sendable {
    public var footnotes = true
    public var endnotes = true
    public var annotations = true
    public var comments = false

    public init(footnotes: Bool = true, endnotes: Bool = true, annotations: Bool = true, comments: Bool = false) {
        self.footnotes = footnotes
        self.endnotes = endnotes
        self.annotations = annotations
        self.comments = comments
    }

    /// The kinds as the library wants them.
    public var kinds: Set<NoteKind> {
        var kinds: Set<NoteKind> = []
        if footnotes { kinds.insert(.footnote) }
        if endnotes { kinds.insert(.endnote) }
        if annotations { kinds.insert(.annotation) }
        if comments { kinds.insert(.comment) }
        return kinds
    }

    /// `fontsTarget` is the Mac's, as it is for every app export (Jon's ruling, 2026-08-11).
    ///
    /// Batch 31 (Jon, 2026-09-14, asked whether the Native export mode should differ): "It's a
    /// Mac app. It uses Mac fonts." Every export keeps `.mac` in every mode, so a Native RTF or
    /// HTML export is the Printed one by design — `NativeExportCLIParityTests` holds both to
    /// `sr -t rtf|html --mode printed --fonts mac`.
    public func emitOptions(title: String = "", pageSettings: PageSettings? = nil) -> EmitOptions {
        EmitOptions(title: title, notes: kinds, fontsTarget: .mac, pageSettings: pageSettings)
    }
}

/// The one export loop for both apps: a document, the formats asked for, and the bytes of each.
public enum ExportCore {
    /// Renders `document` to every format in `formats`: the document as it is shown, under its variant and quirks.
    ///
    /// Four of the five go straight to the library's own emitters. PDF is the documented
    /// divergence, so it is supplied by the platform as `pagesPDF`: the library's PDF writer is
    /// Courier-only, right for a literal Printed export and wrong for Modern, whose purpose is
    /// the reader's own face. `pagesPDF` is asked for in two cases, and given the style to
    /// render with (`nil` means the document's own current style) and the finished options
    /// (headers, pictures, inline styling and `toc` decide the pages it draws):
    ///
    /// - the export style is Modern: it gets `style` as passed;
    /// - the on-screen view is Native (`viewStyle`): it gets `.native`, the facsimile pass.
    ///
    /// `style` defaults to the document's own ("export what you see") but is overridable
    /// without touching `state`, which for the Export As sheet is the live on-screen document.
    /// A caller exporting a synthetic, never-shown state omits `viewStyle`.
    ///
    /// `pageNumbers` and `sentenceSpacing` reach the library's emitters only; the platform PDF
    /// route renders through the app's own text stack and does not take them (a disclosed gap).
    @MainActor
    public static func render(
        document: CtrlKD.Document,
        state: DocumentState,
        formats: [ExportFormat],
        notes: NoteSelection,
        style: RenderStyle? = nil,
        viewStyle: ViewStyle? = nil,
        title: String = "",
        docPath: String = "",
        choices: ExportChoices,
        pagesPDF: @MainActor (_ style: RenderStyle?, _ options: EmitOptions) throws -> [UInt8]
    ) throws -> [ExportProduct] {
        // Native and Printed both mean a Printed-family export (Native has no format of its
        // own for RTF/HTML/Markdown/text); Modern maps straight across.
        let effectiveStyle = style ?? state.style.value.renderStyle
        let mode = effectiveStyle.emitMode
        // The footer's Page Settings choice rides into every format's options: only the PDF
        // emitter reads it, and it is what makes a Printed PDF match the on-screen page.
        // `title` is `<title>` in HTML; `sr` titles with the file's own stem, so callers pass it.
        var options = notes.emitOptions(title: title, pageSettings: state.pageSettingsPreset.value?.settings)
        choices.apply(to: &options)
        // Resolved once per document, reused across every requested format.
        options.pixResults = DocumentPictures.resolve(document, docPath: docPath)

        var products: [ExportProduct] = []
        for format in formats {
            if format == .pdf && effectiveStyle == .modern {
                products.append(ExportProduct(format: .pdf, bytes: try pagesPDF(style, options)))
            } else if format == .pdf && viewStyle == .native {
                products.append(ExportProduct(format: .pdf, bytes: try pagesPDF(.native, options)))
            } else {
                // `document` as the window shows it: parsed under the variant in force (forced or detected) with the
                // quirks in force, never the file's bytes re-parsed with neither (planning #573).
                guard let emitter = EmitterRegistry.standard.getEmitter(format.libraryFormatName) else {
                    throw EmitError.unknownFormat(name: format.libraryFormatName, known: EmitterRegistry.standard.formats())
                }
                products.append(ExportProduct(format: format, bytes: emitter.emit(document, mode, options).asBytes))
            }
        }
        return products
    }
}
