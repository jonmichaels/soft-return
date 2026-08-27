import CtrlKD
import Foundation

/// How a document is exported/rendered through AppKit's own facsimile-layout algorithm.
/// This is the EXPORT-facing axis only (`ExportEngine.render`, the AppleScript `style`
/// property's underlying `EmitMode`, `DocumentRenderer.render`'s AppKit dispatch) — it
/// deliberately stays two cases, `printed`/`modern`, because export/convert has no "Native"
/// output (job 265 ruling: Native is a VIEW, not a format). See `ViewStyle` below for the
/// THREE-case axis the window itself shows, and that `ExportAccessoryView`'s and
/// `BatchModel`'s own Style pulldowns speak directly (job 323, b20 item 3) — each maps its
/// chosen `ViewStyle` down to `RenderStyle` via `.renderStyle` only where a format actually
/// needs the two-case axis.
enum RenderStyle: String, Hashable, CaseIterable, Sendable {
    /// Line-for-line typescript reproduction: Courier, the file's own page geometry.
    case printed
    /// Reflowed to a modern page: fixed 1in margins, the user's font and size.
    case modern

    var displayName: String {
        switch self {
        case .printed: return "Printed"
        case .modern:  return "Modern"
        }
    }

    /// The library's own mode enum, for handing to emitters.
    var emitMode: EmitMode {
        switch self {
        case .printed: return .printed
        case .modern:  return .modern
        }
    }

    /// This export style, projected onto the window's three-case view axis — the mapping
    /// `PagePreviewRenderer` uses to keep a batch preview's `DocumentState.style` honest
    /// about what it is a preview OF, even though a preview is never shown in Native.
    var viewStyle: ViewStyle {
        switch self {
        case .printed: return .native
        case .modern:  return .modern
        }
    }
}

/// How the DOCUMENT WINDOW currently shows the page — the vocabulary the View menu, the
/// bottom bar's Style popup, and Settings' Default Style all use (job 265, decision register
/// 2026-08-12). Three cases, not two: `RenderStyle` above (unchanged) is what export/convert
/// still speaks, because Native has no export meaning.
enum ViewStyle: String, Hashable, CaseIterable, Sendable {
    /// Today's on-screen renderer: AppKit, Mac-mapped fonts, selectable text, Show
    /// Invisibles' reflow. Was called "Printed" before job 265 — RENAMED, not changed in
    /// substance: it is still `DocumentRenderer.renderPrinted`'s facsimile layout, just
    /// under its honest name now that "Printed" means something more literal (below).
    case native
    /// The engine's own PDF (`emitPDF(doc, mode: .printed)`), shown in a `PDFView` — byte-
    /// for-byte what `sr --mode printed` writes. No AppKit rendering at all; no Show
    /// Invisibles (a baked PDF cannot reflow).
    case printed
    /// Reflowed for a modern audience — unchanged by this job.
    case modern

    var displayName: String {
        switch self {
        case .native:  return "Native"
        case .printed: return "Printed"
        case .modern:  return "Modern"
        }
    }

    /// What this view corresponds to for "export what you see": Native and Printed both mean
    /// the facsimile (one shows it via AppKit, the other via the engine's literal PDF, but
    /// exporting either one means a Printed-style export), Modern maps straight across.
    var renderStyle: RenderStyle {
        switch self {
        case .native, .printed: return .printed
        case .modern:            return .modern
        }
    }
}

/// Single Page or Continuous Scroll — how many pages are on screen at once.
enum PageDisplay: String, Hashable, CaseIterable, Sendable {
    case singlePage
    case continuousScroll

    var displayName: String {
        switch self {
        case .singlePage:       return "Single Page"
        case .continuousScroll: return "Continuous Scroll"
        }
    }
}

/// The zoom control's value. `fit` and `actual` are named states rather than percentages
/// because they must survive a window resize — "Fit" stays fit when the window changes
/// size, where a frozen 87% would not.
enum ZoomSetting: Hashable, Sendable {
    case fit
    case actual
    case percent(Int)

    /// The steps the bottom-bar menu and View ▸ Zoom In/Out walk through, per the spec's
    /// "50–200% steps".
    static let steps = [50, 75, 100, 125, 150, 175, 200]

    var displayName: String {
        switch self {
        case .fit:              return "Fit"
        case .actual:           return "Actual"
        case .percent(let pct): return "\(pct)%"
        }
    }

    /// The scale to draw at. `fit` asks how large a page would have to be to fill
    /// `fitScale`'s viewport; `actual` and every `percent` both scale RELATIVE TO
    /// `actualScale` — the display's own physical points-per-inch over PostScript's 72, i.e.
    /// true size against a ruler (see `ActualSizeMagnification`) — because Jon's spec makes
    /// "Actual Size" the 100% mark, not a screen that happens to run at exactly 72 real
    /// points per inch. `.actual` is exactly `.percent(100)`: one path, two labels.
    func scale(fitScale: Double, actualScale: Double = 1.0) -> Double {
        switch self {
        case .fit:              return fitScale
        case .actual:           return ZoomSetting.percent(100).scale(fitScale: fitScale, actualScale: actualScale)
        case .percent(let pct): return actualScale * Double(pct) / 100.0
        }
    }
}

/// A named paper size the app can snap a document to.
///
/// The library resolves page HEIGHT only — WordStar has no page-width dot command, so
/// every size it knows shares 8.5in (see `namedPageHeights`, ParseWS.swift). A4 is
/// therefore an app-level concept: it can be chosen in Settings as the fallback for
/// silent files, but no file can ever be *detected* as A4. See the job response's
/// library-change proposals.
enum NamedPageSize: String, Hashable, CaseIterable, Sendable {
    case usLetter
    case usLegal
    case a4

    var displayName: String {
        switch self {
        case .usLetter: return "US Letter"
        case .usLegal:  return "US Legal"
        case .a4:       return "A4"
        }
    }

    /// Short form for the bottom bar, where the spec's examples read "Legal (Detected)"
    /// and "Letter (Default)" — no "US".
    var shortName: String {
        switch self {
        case .usLetter: return "Letter"
        case .usLegal:  return "Legal"
        case .a4:       return "A4"
        }
    }

    /// Physical size in points.
    var sizeInPoints: CGSize {
        switch self {
        case .usLetter: return CGSize(width: 612, height: 792)
        case .usLegal:  return CGSize(width: 612, height: 1008)
        case .a4:       return CGSize(width: 595, height: 842)
        }
    }

    /// The Get-Info-style one-liner the batch window's info panel shows.
    var dimensionDescription: String {
        switch self {
        case .usLetter: return "US Letter (8.5 × 11 in)"
        case .usLegal:  return "US Legal (8.5 × 14 in)"
        case .a4:       return "A4 (210 × 297 mm)"
        }
    }

    /// Match a library-resolved page height to a named size. The library already snapped
    /// `.pl` to its own table ("Letter"/"Legal"/"Foolscap Folio"); this maps that name into
    /// the app's vocabulary and returns nil for anything with no app-side name — a
    /// Foolscap Folio document keeps its real geometry and simply has no named size to
    /// show, which is the honest answer.
    static func matching(libraryName: String) -> NamedPageSize? {
        switch libraryName {
        case "Letter": return .usLetter
        case "Legal":  return .usLegal
        default:       return nil
        }
    }
}

/// Everything about how ONE open document is currently being shown.
///
/// Deliberately separate from `WSDocument` (the NSDocument): the document owns bytes and
/// the parse; this owns the view state that a window shows them through. Keeping them
/// apart is what lets the batch window render a preview of a file nobody has opened, using
/// the same rendering path, without inventing a second model.
/// Plain `@MainActor` class, not `@Observable` (job 342: `@Observable` needs macOS 14, and
/// this app's floor is now 13.0) — every consumer (`DocumentWindowController`, `BottomBar`,
/// `DocumentInfoWindowController`, the renderers) already reads state via explicit
/// `update(from:)`/one-shot parameter passing, never SwiftUI's `@Bindable`/`@Environment`
/// reactive tracking, so dropping the macro changes no observable behavior.
@MainActor
final class DocumentState {
    /// The bytes as they arrived. Kept because changing the variant re-parses from scratch
    /// — WordStar variants are different enough that there is no cheap conversion between
    /// two parses of the same file.
    let data: [UInt8]

    /// What the detector said when the file was opened, before any override. Kept so the
    /// Variant control can offer "Auto" as a way back.
    let detection: Detection

    /// The parse currently on screen. Recomputed whenever `variant` changes.
    private(set) var document: CtrlKD.Document

    /// Job 371 item 1 (PIX IN VIEWS): the source document's own path, empty when there is
    /// none (bytes-only construction — a synthetic/test `DocumentState`, or a caller that
    /// never had a real file). Same role as `DocumentOperations.ConversionOptions.docPath` —
    /// see that field's own doc comment for why `.PIX` resolution needs it.
    let docPath: String
    /// `.PIX` tags resolved against `docPath`, once per parse — reused by every view
    /// (`DocumentRenderer`'s Printed/Native/Modern paths, `DocumentWindowController`'s
    /// `pdfView`) so decoding an image never repeats per render call. Recomputed alongside
    /// `document` whenever the variant changes (`setVariant`/`resetVariantToAuto`) — a
    /// different variant is a different parse, so `doc.graphics` is re-read from it, not
    /// assumed unchanged.
    private(set) var pixResults: [PixResult]

    /// Which parser produced `document`, and whether the user picked it.
    private(set) var variant: Resolved<Variant>

    var style: Resolved<ViewStyle>
    var zoom: Resolved<ZoomSetting>
    var display: Resolved<PageDisplay>

    /// The paper the document is shown on. Detected from the file's own geometry where it
    /// declared any; otherwise the Settings fallback.
    private(set) var pageSize: Resolved<NamedPageSize?>

    /// Printed-mode page-geometry override — the footer's Margins control (job 203).
    /// `nil` is "Embedded" (job 315: was "From Document"), the app's long-standing, unchanged
    /// default: whatever the
    /// file's own dot commands declared, filled in with WordStar's factory geometry for
    /// anything the file left unsaid. A non-nil preset flows through `effectivePage` in both
    /// `DocumentRenderer.renderPrinted` (screen) and `ExportEngine.render` (Printed-mode PDF
    /// export) — the SAME channel the CLI's own `--page-settings` flag uses, so a preset
    /// chosen here can never disagree with what `sr --page-settings <name>` would produce for
    /// the same file. Jon's ruling (2026-08-10): no corpus gets a hardcoded default of its
    /// own — a document with no set margins keeps showing WordStar standard unless a person
    /// picks something else, here, by hand.
    private(set) var pageSettingsPreset: Resolved<DocumentOperations.PageSettingsPreset?> = Resolved(nil, .default)

    /// View ▸ Show Invisibles. One switch for all of WordStar's own marks — the spec is
    /// explicit that there are no per-kind toggles.
    var showInvisibles: Bool = false

    /// Modern style's typeface, from Settings. Printed style ignores both (it is Courier
    /// at the file's own `.cw` size, by definition).
    var modernFontName: String
    var modernFontSize: Int

    /// - Throws: `ParseError.notConvertible` when the bytes aren't a document the library
    ///   can read — the app turns that into the standard "can't open" alert rather than
    ///   showing an empty window.
    init(data: [UInt8], settings: SettingsStore, docPath: String = "") throws {
        self.data = data
        self.docPath = docPath
        let detection = detect(data)
        self.detection = detection
        self.variant = Resolved(detection.variant, .detected)
        let parsed = try parse(data, variant: detection.variant)
        self.document = parsed
        self.pixResults = DocumentPictures.resolve(parsed, docPath: docPath)
        self.style = Resolved(settings.defaultStyle, .default)
        self.zoom = Resolved(settings.defaultZoom, .default)
        self.display = Resolved(settings.defaultDisplay, .default)
        self.modernFontName = settings.modernFontName
        self.modernFontSize = settings.modernFontSize

        // Page size: the file's own geometry wins; the Settings size is a fallback for
        // files that declared nothing. `sizeSource == .file` is exactly that distinction.
        if let page = parsed.page,
           page.sizeSource == .file,
           let named = NamedPageSize.matching(libraryName: page.sizeName) {
            self.pageSize = Resolved(named, .detected)
        } else {
            self.pageSize = Resolved(settings.defaultPageSize, .default)
        }
    }

    /// Job 459 (b28 note 11): construct directly from an already-built `CtrlKD.Document`,
    /// bypassing `parse(data:variant:)` entirely — the "documents built by hand (tests,
    /// fixtures)" provenance `Document.detection`'s own doc comment already names as a real,
    /// sanctioned shape (its `detection` field is `nil` for exactly this case). `internal`,
    /// not `private`, purely so `@testable import SoftReturn` can reach it — same "loosen to
    /// internal for test access" convention `DocumentRenderer.attributedLine`/
    /// `PagedDocumentView.runningLines(atPageIndex:)` already use elsewhere. No production
    /// call site: every real document
    /// still goes through `init(data:settings:docPath:)` above. Exists so a test proving
    /// Jon's screenplay-scope ruling ("only supposed to apply when our code detects a
    /// screenplay") can hand-build an ordinary document with no slugline anywhere, rather
    /// than fighting a real WordStar byte stream's own binary font/style blocks to get one.
    init(document: CtrlKD.Document, settings: SettingsStore, docPath: String = "") {
        self.data = []
        self.docPath = docPath
        self.detection = Detection(variant: .ws4)
        self.variant = Resolved(.ws4, .detected)
        self.document = document
        self.pixResults = DocumentPictures.resolve(document, docPath: docPath)
        self.style = Resolved(settings.defaultStyle, .default)
        self.zoom = Resolved(settings.defaultZoom, .default)
        self.display = Resolved(settings.defaultDisplay, .default)
        self.modernFontName = settings.modernFontName
        self.modernFontSize = settings.modernFontSize
        self.pageSize = Resolved(settings.defaultPageSize, .default)
    }

    /// Re-parse under a user-chosen variant. Everything downstream (pages, geometry, the
    /// page-size readout) derives from `document`, so this one call moves the whole view.
    ///
    /// A failed re-parse leaves the previous document on screen and reports the error: the
    /// user asked "show me this as WS4", and "that isn't WS4" is an answer, not a reason to
    /// blank the window they were already reading.
    @discardableResult
    func setVariant(_ newVariant: Variant) -> Error? {
        do {
            let reparsed = try parse(data, variant: newVariant)
            variant.setManually(newVariant)
            document = reparsed
            pixResults = DocumentPictures.resolve(reparsed, docPath: docPath)
            refreshPageSizeAfterReparse()
            return nil
        } catch {
            return error
        }
    }

    /// Return to the detector's own answer. Cannot fail: this parse already succeeded once,
    /// in `init`, or the document would never have opened.
    func resetVariantToAuto() {
        guard let reparsed = try? parse(data, variant: detection.variant) else { return }
        variant = Resolved(detection.variant, .detected)
        document = reparsed
        pixResults = DocumentPictures.resolve(reparsed, docPath: docPath)
        refreshPageSizeAfterReparse()
    }

    /// A different variant means different (or absent) dot commands, so the resolved page
    /// size can change under it. Only re-derive the DETECTED case: a user who set the page
    /// size by hand keeps it across a re-parse.
    private func refreshPageSizeAfterReparse() {
        guard pageSize.provenance != .manual else { return }
        if let page = document.page,
           page.sizeSource == .file,
           let named = NamedPageSize.matching(libraryName: page.sizeName) {
            pageSize = Resolved(named, .detected)
        }
    }

    func setPageSize(_ newSize: NamedPageSize) {
        pageSize.setManually(newSize)
    }

    /// `nil` returns to "Embedded" — the app's default, not a manual choice of "no
    /// override" (mirrors `resetVariantToAuto()`'s use of `.detected` rather than `.manual`
    /// for going back to the detector's own answer).
    func setPageSettingsPreset(_ preset: DocumentOperations.PageSettingsPreset?) {
        if let preset {
            pageSettingsPreset.setManually(preset)
        } else {
            pageSettingsPreset = Resolved(nil, .default)
        }
    }
}
